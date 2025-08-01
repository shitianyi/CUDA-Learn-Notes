#include "utils.h"

// Write FlashAttention-2 from scratch using Tensor Cores with MMA PTX
// instruction. The input is Q,K,V, 4D tensor with shape [batch_size, num_heads,
// seq_len, head_dim]. The output is O, a 4D tensor with shape [batch_size,
// num_heads, seq_len, head_dim].

// The FlashAttention-2 algorithm is described in the following paper:
// https://arxiv.org/pdf/2307.08691

// Q,K,V,O: [batch_size, num_heads, seq_len, head_dim], [B,H,N,d]
// each block processes Q_tile with shape [Br,d] and full K,V with shape [N,d]

// Split Q across MMA(Warps) and keep access KV for all MMA(Warps),
// in order to reduce the comm between warps via smem and warp shuffle.

// MMA = m16n8k16, Br=16x4=64, Bc=8x8=64, layout: 4 warps
// |   64x64   |      warp_KV 0       |
// | warp_QP 0 | MMA 0 ... MMA 0 (x8) |
// | warp_QP 1 | MMA 1 ... MMA 1 (x8) |
// | warp_QP 2 | MMA 2 ... MMA 2 (x8) |
// | warp_QP 3 | MMA 3 ... MMA 3 (x8) |

// MMA = m16n8k16, Br=16x8=128, Bc=8x16=128, layout: 8 warps
// |  128x128  |      warp_KV 0        |
// | warp_QP 0 | MMA 0 ... MMA 0 (x16) |
// | warp_QP 1 | MMA 1 ... MMA 1 (x16) |
// | warp_QP 2 | MMA 2 ... MMA 2 (x16) |
// | warp_QP 3 | MMA 3 ... MMA 3 (x16) |
// | warp_QP 4 | MMA 4 ... MMA 4 (x16) |
// | warp_QP 5 | MMA 5 ... MMA 5 (x16) |
// | warp_QP 6 | MMA 6 ... MMA 6 (x16) |
// | warp_QP 7 | MMA 7 ... MMA 7 (x16) |

// MMA = m16n8k16, Br=16x8=128, Bc=8x8=64, layout: 8 warps
// |  128x64  |      warp_KV 0        |
// | warp_QP 0 | MMA 0 ... MMA 0 (x8) |
// | warp_QP 1 | MMA 1 ... MMA 1 (x8) |
// | warp_QP 2 | MMA 2 ... MMA 2 (x8) |
// | warp_QP 3 | MMA 3 ... MMA 3 (x8) |
// | warp_QP 4 | MMA 4 ... MMA 4 (x8) |
// | warp_QP 5 | MMA 5 ... MMA 5 (x8) |
// | warp_QP 6 | MMA 6 ... MMA 6 (x8) |
// | warp_QP 7 | MMA 7 ... MMA 7 (x8) |

// Manually apply SMEM swizzling instead of padding in
// Split-Q kernels to reduce bank conflicts.

// i: row index; j: col index.
// e.g kColStride = 64, kStep = 8 -> load 8 half as 128 bits memory issue.
template <const int kColStride = 16, const int kStep = 8>
static __device__ __forceinline__ int swizzle_permuted_j(int i, int j) {
  // -------------------
  // --swizzle layout---
  // -col 0~16, step 8--
  // -------------------
  // | row 0  | (0, 8) |
  // | row 1  | (0, 8) |
  // | row 2  | (0, 8) |
  // | row 3  | (0, 8) |
  // -------------------
  // | row 4  | (8, 0) |
  // | row 5  | (8, 0) |
  // | row 6  | (8, 0) |
  // | row 7  | (8, 0) |
  // -------------------
  // | row 8  | (0, 8) |
  // | row 9  | (0, 8) |
  // | row 10 | (0, 8) |
  // | row 11 | (0, 8) |
  // -------------------
  // | row 12 | (8, 0) |
  // | row 13 | (8, 0) |
  // | row 14 | (8, 0) |
  // | row 15 | (8, 0) |
  // -------------------
  // swizzle: ((int(j / kStep) ^ int(i / 4)) % int(kColStride / kStep)) * kStep;
  static_assert(kStep == 4 || kStep == 8, "kStep must be 8 or 4.");
  static_assert(kColStride % kStep == 0,
                "kColStride must be multiple of kStep.");
  if constexpr (kStep == 8) {
    return (((j >> 3) ^ (i >> 2)) % (kColStride >> 3)) << 3;
  } else {
    static_assert(kStep == 4);
    return (((j >> 2) ^ (i >> 2)) % (kColStride >> 2)) << 2;
  }
}

template <const int kMmaAtomK = 16>
static __device__ __forceinline__ int swizzle_permuted_Q_j(int i, int j) {
  return swizzle_permuted_j<kMmaAtomK, 8>(i, j);
}

template <const int kMmaAtomK = 16>
static __device__ __forceinline__ int swizzle_permuted_K_j(int i, int j) {
  return swizzle_permuted_j<kMmaAtomK, 8>(i, j);
}

template <const int kMmaAtomK = 16>
static __device__ __forceinline__ int swizzle_permuted_V_j(int i, int j) {
  return swizzle_permuted_j<kMmaAtomK, 8>(i, j);
}

template <
    const int kHeadDim,          // Headdim, 32,64,128
    const int kMmaAtomM,         // MMA Atom M, 16
    const int kMmaAtomN,         // MMA Atom N, 8
    const int kMmaAtomK,         // MMA Atom K, 16
    const int kMmaTileSeqLenQ,   // 4, more MMA(warp), M=16*4=64, Q@K^T=[Br(M),
                                 // d(K)]@[d(K),  Bc(N)]
    const int kMmaTileSeqLenK,   // 1, more MMA(warp), N=8*1 =8,  Q@K^T=[Br(M),
                                 // d(K)]@[d(K),  Bc(N)]
    const int kMmaTileSeqLenP,   // 4, more MMA(warp), M=16*4=64, P@V
                                 // =[Br(M),Bc(K)]@[Bc(K), d(N) ]
    const int kMmaTileHeadDimV,  // 1, more MMA(warp), N=8*1 =8,  P@V
                                 // =[Br(M),Bc(K)]@[Bc(K), d(N) ]
    const int kWarpTileSeqLenQ,  // 1, more values, M, Br=64*1=64, matmul M
    const int kWarpTileSeqLenK,  // 8, more values, N, Bc=8*8 =64, matmul N
    const int kWarpTileSeqLenP,  // 1, more values, M, Br=64*1=64, matmul M
    const int kWarpTileHeadDimV, // 8, more values, N,
                                 // d=8*(1|2|3|4|...)=8|...|32|64|96|128|...
    const int kOStorageAccFloat32, // 0/1, MMA Acc always be fp16, but O
                                   // storage can be fp32 or half.
    const int kStage,              // 1,2
    const int kPadQ,               // Pad Q/K/V 0,8
    const int kPadK, const int kPadV>
__global__ void __launch_bounds__(WARP_SIZE *kMmaTileSeqLenQ *kMmaTileSeqLenK)
    flash_attn_mma_stages_split_q_shared_kv_swizzle_qkv_kernel(half *Q, half *K,
                                                               half *V, half *O,
                                                               int QKV_seqlen,
                                                               int QKV_head) {
  // Matmul Layout: Q[Br,d]@K^T[d,Bc] NT, P[Br,Bc]@V[Bc,d] NN.
  // NOTE: K[Bc,d] with row major means K^T[d,Bc] in col major.
  static_assert(kMmaAtomM == 16 && kMmaAtomN == 8 &&
                kMmaAtomK == 16);                                 // m16n8k16
  static_assert(kMmaTileSeqLenQ <= 8 && kMmaTileSeqLenK == 1);    // Q@K^T
  static_assert(kMmaTileSeqLenP <= 8 && kMmaTileHeadDimV == 1);   // P@V
  static_assert(kWarpTileSeqLenQ == 1 && kWarpTileSeqLenK <= 16); // Q@K^T
  // kWarpTileHeadDimV: d=8*(1|2|3|4|...) = 8|...|32|64|96|128|..., etc.
  // e.g, kWarpTileHeadDimV = 8 -> d = 8*8 = 64; 16 -> d = 8*16 = 128.
  static_assert(kWarpTileSeqLenP == 1 &&
                kWarpTileHeadDimV ==
                    (kHeadDim / (kMmaAtomN * kMmaTileHeadDimV))); // P@V
  static_assert(kOStorageAccFloat32 == 0 || kOStorageAccFloat32 == 1);
  static_assert(kStage < 3 && kStage > 0);
  static_assert(kPadQ >= 0 && kPadQ % 8 == 0); // 0,8,16
  static_assert(kPadK >= 0 && kPadK % 8 == 0); // 0,8,16
  static_assert(kPadV >= 0 && kPadV % 8 == 0); // 0,8,16
  constexpr int Br =
      kMmaAtomM * kMmaTileSeqLenQ * kWarpTileSeqLenQ; // 16*4*1=64
  constexpr int Bc =
      kMmaAtomN * kMmaTileSeqLenK * kWarpTileSeqLenK; //  8*1*8=64
  static_assert(Br >= Bc); // for shared memory reuse.
  constexpr int kNumThreads =
      WARP_SIZE * kMmaTileSeqLenQ * kMmaTileSeqLenK; // 32*4*1=128, num threads
  // Now, N must be mutliples of Bc(32/64) for KV tiling across seqlen.
  const int Tc = div_ceil(QKV_seqlen, Bc); // Tc K_tile[Bc,d]
  const float scale = 1.0f / sqrt((float)kHeadDim);

  // grid(div_ceil(QKV_seqlen, Br), QKV_batch * QKV_head), (x,y,z)
  const int QKV_batch_id = blockIdx.y / QKV_head; // Batch size
  const int QKV_head_id = blockIdx.y % QKV_head;  // Head num
  const int Q_tile_id = blockIdx.x;               // Q tile_id, range [0, Tr]
  const int O_tile_id = Q_tile_id;                // O tile_id, same as Q.
  const int tid = threadIdx.x;                    // within block
  const int warp_id = tid / WARP_SIZE;            // 0~7 warp_id within block
  const int lane_id = tid % WARP_SIZE;            // 0~31
  const int warp_QP = warp_id;                    // 0,1,2,3 or 0~7
  const int warp_KV = 0;                          // 0
  // MMA Layout [Br,Bc]=[64,64], MMA = m16n8k16, Br=16x4=64, Bc=8x8=64, layout:
  // 4 warps |   64x64   |      warp_KV 0       | | warp_QP 0 | MMA 0 ... MMA 0
  // (x8) | | warp_QP 1 | MMA 1 ... MMA 1 (x8) | | warp_QP 2 | MMA 2 ... MMA 2
  // (x8) | | warp_QP 3 | MMA 3 ... MMA 3 (x8) | MMA Layout [Br,Bc]=[128,128],
  // MMA = m16n8k16, Br=16x8=128, Bc=8x16=128, layout: 8 warps |  128x128  |
  // warp_KV 0        | | warp_QP 0 | MMA 0 ... MMA 0 (x16) | | warp_QP 1 | MMA
  // 1 ... MMA 1 (x16) | | warp_QP 2 | MMA 2 ... MMA 2 (x16) | | warp_QP 3 | MMA
  // 3 ... MMA 3 (x16) | | warp_QP 4 | MMA 4 ... MMA 4 (x16) | | warp_QP 5 | MMA
  // 5 ... MMA 5 (x16) | | warp_QP 6 | MMA 6 ... MMA 6 (x16) | | warp_QP 7 | MMA
  // 7 ... MMA 7 (x16) |
  const int Q_gmem_offset =
      ((QKV_batch_id * QKV_head * QKV_seqlen * kHeadDim) +
       (QKV_head_id * QKV_seqlen * kHeadDim)); // Q [seqlen,d]
  const int K_gmem_offset =
      ((QKV_batch_id * QKV_head * QKV_seqlen * kHeadDim) +
       (QKV_head_id * QKV_seqlen * kHeadDim)); // K [seqlen,d]
  const int V_gmem_offset = Q_gmem_offset;     // V [seqlen,d]
  const int O_gmem_offset = Q_gmem_offset;     // O [seqlen,d]

  // Mapping Q gmem -> tid -> smem, Q[Br,d]=[64,64 or 128], 128 threads.
  int load_smem_Q_Br = (tid / (kNumThreads / Br)); // Br 64, tid / 2, row 0~64
  int load_smem_Q_d =
      (tid % (kNumThreads / Br)) *
      (kHeadDim / (kNumThreads / Br)); // (tid % 2) * 32, 0,32,...
  // Mapping K gmem -> tid -> smem, K[Bc,d]=[64 or 128,64], 128 threads.
  int load_smem_K_Bc = (tid / (kNumThreads / Bc)); // Bc 64, tid / 2, row 0~64
  int load_smem_K_d =
      (tid % (kNumThreads / Bc)) *
      (kHeadDim / (kNumThreads / Bc)); // (tid % 2) * 32, 0,32,...
  // Mapping V gmem -> tid -> smem, V[d,Bc]=[64 or 128,64], 128 threads.
  int load_smem_V_d =
      (tid / (kNumThreads / kHeadDim)); // d 64, tid / 2, row 0~64
  int load_smem_V_Bc =
      (tid % (kNumThreads / kHeadDim)) *
      (Bc / (kNumThreads / kHeadDim)); // (tid % 2) * 32, 0,32,...
  // global Q row of current head for tile [Br,d] per block.
  int load_gmem_Q_Br = Q_tile_id * Br + load_smem_Q_Br;
  if (load_gmem_Q_Br >= QKV_seqlen)
    return;
  // KV tile gmem load index starts from 0 and increments with
  // each iteration as we loop over seqlen.
  int load_gmem_K_Bc_offset = 0;
  int load_gmem_V_Bc_offset = 0;

  // Shared memory for Q,K,V, we don not need additional smem for O
  // collective store which perform via registers reuse and warp shuffle.
  extern __shared__ half smem[];
  // TODO: smem layout for swizzle should be [(kHeadDim/16)][Br][16]
  constexpr int Q_tile_size =
      (kHeadDim / kMmaAtomK) * Br *
      (kMmaAtomK + kPadQ); // 4*64*16=4096, ~8192 bytes=8M
  constexpr int K_tile_size =
      (kHeadDim / kMmaAtomK) * Bc * (kMmaAtomK + kPadK); // K[Bc,d]
  constexpr int V_tile_size =
      (Bc / kMmaAtomK) * kHeadDim *
      (kMmaAtomK + kPadV);  // V[d,Bc], means V[Bc,d] in col major
  half *Q_tile_smem = smem; // 8M/16M
  half *K_tile_smem = Q_tile_smem + Q_tile_size; // 8M/16M
  half *V_tile_smem = K_tile_smem;               // KV shared the same smem

  uint32_t smem_Q_base_ptr = __cvta_generic_to_shared(Q_tile_smem);
  uint32_t smem_K_base_ptr = __cvta_generic_to_shared(K_tile_smem);
  uint32_t smem_V_base_ptr = __cvta_generic_to_shared(V_tile_smem);

  // Registers/SMEM for thread block
  // block m_old, l_old, store in lane, use float to
  // keep precision.
  float lane_block_row_max_old[kWarpTileSeqLenQ][2]; // [1][2]
  float lane_block_row_sum_old[kWarpTileSeqLenQ][2]; // [1][2]
  fill_2D_regs<float, kWarpTileSeqLenQ, 2>(lane_block_row_max_old, -INFINITY);
  fill_2D_regs<float, kWarpTileSeqLenQ, 2>(lane_block_row_sum_old, 0.0f);

  // Registers for S=Q@K^T/O=P@V
  // registers for QKV, S=Q[Br,d]@K[Bc,d]=[Br,Bc]
  // and O=P[Br,Bc]@V[Bc,d]=[Br,d]. Allocate R_Q[(kHeadDim/kMmaAtomK)<=8][1][4],
  // e.g R_Q[4][1][4] 16 regs. By the way, we have to reduce R_Z to 0 regs and
  // reuse R_Q for collective store. Then we can load Q from smem only once and
  // reuse it for <loop over K seqlen> processes. This will reduce large
  // io-access for Q smem while N is large.
  // FIXME(DefTruth): why can not get good performance for headdim >= 64 ?
  // Will enable it untill I have figure out the performance issues.
  constexpr bool kCanPrefetchQs2r =
      ((kHeadDim / kMmaAtomK) <= 8) && (kHeadDim < 64);
  constexpr bool kDelayPrefetchQs2r =
      (true && kCanPrefetchQs2r);                   // TODO: make it optional.
  constexpr bool kCanPrefetchKVg2s = (kStage == 2); // whether prefetch KV g2s.
  constexpr int kPrefetchKg2sSmemId = 0;            // smem id for K g2s, 0.
  constexpr int kPrefetchVg2sSmemId =
      kCanPrefetchKVg2s ? 1 : 0; // smem id for V g2s, 1.
  constexpr int kNumPrefetchQs2r =
      (kCanPrefetchQs2r) ? (kHeadDim / kMmaAtomK) : 1;
  uint32_t R_Q[kNumPrefetchQs2r][kWarpTileSeqLenQ][4]; // [4/8/1][1][4]
  uint32_t R_K[kWarpTileSeqLenK][2];                   // [8][2]
  uint32_t R_V[kWarpTileHeadDimV][2];                  // [8][2]
  // registers for current tile_K_seqlen within, [64,64] = S_tile[Br,Bc]
  // = Q_tile[Br,d] * K[Bc,d], each thread hold 2x32 bits regs.
  uint32_t R_S[kWarpTileSeqLenQ][kWarpTileSeqLenK][2]; // [1][8][2]
  // registers for tile_K_seqlen O=PV[Br,d]=P@V, [2][2/4][2], 8 or 16 regs.
  uint32_t R_O[kWarpTileSeqLenP][kWarpTileHeadDimV][2]; // [1][8][2]
  // registers final Output [D]=final rescale(R_O), [2][2/4][2], 8 or 16 regs.
  // 0/1, MMA Acc always be fp16, but O storage(R_D) can be fp32 or half.
  // FP16 can provide precision to approximately 3-4 decimal places. Thus, if
  // the error does not exceed 1e-3, using FP16 storage is sufficient for most
  // applications.
  uint32_t R_D[kWarpTileSeqLenP][kWarpTileHeadDimV]
              [(kOStorageAccFloat32) ? 4 : 2];
  fill_3D_regs<uint32_t, kWarpTileSeqLenP, kWarpTileHeadDimV,
               ((kOStorageAccFloat32) ? 4 : 2)>(R_D, 0);

  // load Q from gmem -> smem, only load once.
  {
    int load_gmem_Q_d = load_smem_Q_d;
    int load_gmem_Q_addr =
        (Q_gmem_offset + load_gmem_Q_Br * kHeadDim + load_gmem_Q_d);
#pragma unroll
    for (int i = 0; i < (kHeadDim / (kNumThreads / Br)); i += 8) {
      // int load_smem_Q_chunk   = ((load_smem_Q_d + i) / kMmaAtomK); // d=64,
      // 0~3 int load_smem_Q_chunk_d = ((load_smem_Q_d + i) % kMmaAtomK); //
      // 0->0,8->8,16->0,24->8
      uint32_t load_smem_Q_ptr =
          (smem_Q_base_ptr +
           (((load_smem_Q_d + i) / kMmaAtomK) * Br * (kMmaAtomK + kPadQ) +
            load_smem_Q_Br * (kMmaAtomK + kPadQ) +
            swizzle_permuted_Q_j<kMmaAtomK>(
                load_smem_Q_Br, ((load_smem_Q_d + i) % kMmaAtomK))) *
               sizeof(half));
      CP_ASYNC_CG(load_smem_Q_ptr, &Q[load_gmem_Q_addr + i], 16);
    }
    CP_ASYNC_COMMIT_GROUP();
  }

// <loop over K seqlen>: for K^T[d,seqlen] with K^T_tile[d,Bc]
// tile_K_seqlen: compute S_tile[Br,Bc] = Q@K^T = Q_tile[Br,d] * K^T[d,Bc]
#pragma unroll 1
  for (int tile_K_seqlen = 0; tile_K_seqlen < Tc; ++tile_K_seqlen) {
    // TODO: process last tile_K_seqlen ? pad to multiple of 8.

    // Load K tile from gmem -> smem, always use smem part 0, send g2s
    // memory issues before Prefetch Q s2r.
    if constexpr (kCanPrefetchKVg2s) {
      if (tile_K_seqlen == 0) {
        load_gmem_K_Bc_offset =
            tile_K_seqlen * Bc; // e.g (0~3)*64=(0,64,128,192,...)
        int load_gmem_K_Bc = load_gmem_K_Bc_offset + load_smem_K_Bc;
        int load_gmem_K_d = load_smem_K_d;
        int load_gmem_K_addr =
            (K_gmem_offset + load_gmem_K_Bc * kHeadDim + load_gmem_K_d);
#pragma unroll
        for (int i = 0; i < (kHeadDim / (kNumThreads / Bc)); i += 8) {
          uint32_t load_smem_K_ptr =
              (smem_K_base_ptr +
               (kPrefetchKg2sSmemId * K_tile_size +
                ((load_smem_K_d + i) / kMmaAtomK) * Bc *
                    (kMmaAtomK + kPadK) + // chunk, d=64, 0~3
                load_smem_K_Bc * (kMmaAtomK + kPadK) +
                swizzle_permuted_K_j<kMmaAtomK>(
                    load_smem_K_Bc, ((load_smem_K_d + i) % kMmaAtomK))) *
                   sizeof(half));
          CP_ASYNC_CG(load_smem_K_ptr, &K[load_gmem_K_addr + i], 16);
        }
        CP_ASYNC_COMMIT_GROUP();

        // Now, we have to wait curr K tile ready for Q@K^T MMA.
        CP_ASYNC_WAIT_GROUP(0);
        __syncthreads();
      }
      // <Prefetch V g2s>: Load V tile async from gmem -> smem 1, before Q@K^T
      {
        // [d,Bc]
        load_gmem_V_Bc_offset =
            tile_K_seqlen * Bc; // e.g (0~3)*64=(0,64,128,192,...)
        int load_gmem_V_d = load_smem_V_d;
        int load_gmem_V_Bc = load_gmem_V_Bc_offset + load_smem_V_Bc;
        int load_gmem_V_addr =
            (V_gmem_offset + load_gmem_V_d * QKV_seqlen + load_gmem_V_Bc);
#pragma unroll
        for (int i = 0; i < (Bc / (kNumThreads / kHeadDim)); i += 8) {
          uint32_t load_smem_V_ptr =
              (smem_V_base_ptr +
               (kPrefetchVg2sSmemId * V_tile_size +
                ((load_smem_V_Bc + i) / kMmaAtomK) * kHeadDim *
                    (kMmaAtomK + kPadV) + // chunk, d=64, 0~3
                load_smem_V_d * (kMmaAtomK + kPadV) +
                swizzle_permuted_V_j<kMmaAtomK>(
                    load_smem_V_d, ((load_smem_V_Bc + i) % kMmaAtomK))) *
                   sizeof(half));
          CP_ASYNC_CG(load_smem_V_ptr, &V[load_gmem_V_addr + i], 16);
        }
        CP_ASYNC_COMMIT_GROUP();
      }
    } else {
      load_gmem_K_Bc_offset =
          tile_K_seqlen * Bc; // e.g (0~3)*64=(0,64,128,192,...)
      int load_gmem_K_Bc = load_gmem_K_Bc_offset + load_smem_K_Bc;
      int load_gmem_K_d = load_smem_K_d;
      int load_gmem_K_addr =
          (K_gmem_offset + load_gmem_K_Bc * kHeadDim + load_gmem_K_d);
#pragma unroll
      for (int i = 0; i < (kHeadDim / (kNumThreads / Bc)); i += 8) {
        uint32_t load_smem_K_ptr =
            (smem_K_base_ptr +
             (kPrefetchKg2sSmemId * K_tile_size +
              ((load_smem_K_d + i) / kMmaAtomK) * Bc *
                  (kMmaAtomK + kPadK) + // chunk, d=64, 0~3
              load_smem_K_Bc * (kMmaAtomK + kPadK) +
              swizzle_permuted_K_j<kMmaAtomK>(
                  load_smem_K_Bc, ((load_smem_K_d + i) % kMmaAtomK))) *
                 sizeof(half));
        CP_ASYNC_CG(load_smem_K_ptr, &K[load_gmem_K_addr + i], 16);
      }
      CP_ASYNC_COMMIT_GROUP();
      // Now, we have to wait curr K tile ready for Q@K^T MMA.
      CP_ASYNC_WAIT_GROUP(0);
      __syncthreads();
    }

    // <Prefetch Q s2r>: Load Q tile from smem -> regs, before Q@K^T.
    if constexpr (kCanPrefetchQs2r && (!kDelayPrefetchQs2r)) {
      // Wait Q ready and let K copy async, then prefetch Q from smem -> regs.
      // NOTE: we only need to load Q once from smem -> regs, and then reuse it.
      if (tile_K_seqlen == 0) {
        if constexpr (!kCanPrefetchKVg2s) {
          CP_ASYNC_WAIT_GROUP(0);
        } else {
          CP_ASYNC_WAIT_GROUP(1); // let V g2s copy async
        }
        __syncthreads();

#pragma unroll
        for (int tile_K_d = 0; tile_K_d < (kHeadDim / kMmaAtomK); ++tile_K_d) {
#pragma unroll
          for (int i = 0; i < kWarpTileSeqLenQ;
               ++i) { // Q[Br,d]=[M,K] [4][Br][16]
            int warp_smem_Q_Br =
                warp_QP * (kMmaAtomM * kWarpTileSeqLenQ) + i * kMmaAtomM;
            // int lane_smem_Q_Br = warp_smem_Q_Br + lane_id % 16; // 0~15
            // int lane_smem_Q_d  = tile_K_d * kMmaAtomK + (lane_id / 16) * 8;
            // // 0,8
            int lane_smem_Q_Br = warp_smem_Q_Br + lane_id % 16; // 0~15
            int lane_smem_Q_d = (lane_id / 16) * 8;             // 0,8
            uint32_t lane_smem_Q_ptr =
                (smem_Q_base_ptr + (tile_K_d * Br * (kMmaAtomK + kPadQ) +
                                    lane_smem_Q_Br * (kMmaAtomK + kPadQ) +
                                    swizzle_permuted_Q_j<kMmaAtomK>(
                                        lane_smem_Q_Br, lane_smem_Q_d)) *
                                       sizeof(half));
            LDMATRIX_X4(R_Q[tile_K_d][i][0], R_Q[tile_K_d][i][1],
                        R_Q[tile_K_d][i][2], R_Q[tile_K_d][i][3],
                        lane_smem_Q_ptr); // now, R_Q[1/2/4/8][1][4]
          }
        }
        __syncthreads(); // wait all warps ready.
      } // end if tile_K_seqlen == 0
    } // end if kCanPrefetchQs2r

    // <loop over K d>: tile_K_d, kMmaAtomK = 16, K_tile_d[kMmaAtomK,Bc]
    // Matmul with NT layout, Q row major, K^T col major.
    // NOTE: K[Bc,d] with row major means K^T[d,Bc] in col major.
    // S_tile[Br,Bc]=Q_tile[Br,d]@K[Bc,d]
    // <HGEMM in shared memory>
    fill_3D_regs<uint32_t, kWarpTileSeqLenQ, kWarpTileSeqLenK, 2>(R_S, 0);
#pragma unroll
    for (int tile_K_d = 0; tile_K_d < (kHeadDim / kMmaAtomK); ++tile_K_d) {
      // smem -> reg, load m16k16 smem Q, offset d according tile_K_d.
      // ldmatrix.x4 for Q_tile_smem.
      if constexpr (!kCanPrefetchQs2r) {
// load Q from smem -> regs in each loop w/o prefetch Q s2r.
#pragma unroll
        for (int i = 0; i < kWarpTileSeqLenQ; ++i) { // Q[Br,d]=[M,K]
          int warp_smem_Q_Br =
              warp_QP * (kMmaAtomM * kWarpTileSeqLenQ) + i * kMmaAtomM;
          // int lane_smem_Q_Br = warp_smem_Q_Br + lane_id % 16; // 0~15
          // int lane_smem_Q_d  = tile_K_d * kMmaAtomK + (lane_id / 16) * 8; //
          // 0,8
          int lane_smem_Q_Br = warp_smem_Q_Br + lane_id % 16; // 0~15
          int lane_smem_Q_d = (lane_id / 16) * 8;             // 0,8
          uint32_t lane_smem_Q_ptr =
              (smem_Q_base_ptr + (tile_K_d * Br * (kMmaAtomK + kPadQ) +
                                  lane_smem_Q_Br * (kMmaAtomK + kPadQ) +
                                  swizzle_permuted_Q_j<kMmaAtomK>(
                                      lane_smem_Q_Br, lane_smem_Q_d)) *
                                     sizeof(half));
          LDMATRIX_X4(R_Q[0][i][0], R_Q[0][i][1], R_Q[0][i][2], R_Q[0][i][3],
                      lane_smem_Q_ptr); // now, R_Q[1][1][4]
        } // end for kWarpTileSeqLenQ
      } else { // kCanPrefetchQs2r = true
        // Lazy Prefetch Q g2s: In order not to block the calculation of MMA,
        // we choose to delay Prefetch Q s2r until this time.
        if constexpr (kDelayPrefetchQs2r) {
          if (tile_K_seqlen == 0) {
            // Wait Q g2s ready if tile_K_d == 0
            if (tile_K_d == 0) {
              if constexpr (!kCanPrefetchKVg2s) {
                CP_ASYNC_WAIT_GROUP(0);
              } else {
                CP_ASYNC_WAIT_GROUP(1); // let V g2s copy async
              }
              __syncthreads();
            } // end if tile_K_d == 0
// Now, load tile_K_d Q from smem -> regs in each loop w/o prefetch Q s2r.
#pragma unroll
            for (int i = 0; i < kWarpTileSeqLenQ; ++i) { // Q[Br,d]=[M,K]
              int warp_smem_Q_Br =
                  warp_QP * (kMmaAtomM * kWarpTileSeqLenQ) + i * kMmaAtomM;
              // int lane_smem_Q_Br = warp_smem_Q_Br + lane_id % 16; // 0~15
              // int lane_smem_Q_d  = tile_K_d * kMmaAtomK + (lane_id / 16) * 8;
              // // 0,8
              int lane_smem_Q_Br = warp_smem_Q_Br + lane_id % 16; // 0~15
              int lane_smem_Q_d = (lane_id / 16) * 8;             // 0,8
              uint32_t lane_smem_Q_ptr =
                  (smem_Q_base_ptr + (tile_K_d * Br * (kMmaAtomK + kPadQ) +
                                      lane_smem_Q_Br * (kMmaAtomK + kPadQ) +
                                      swizzle_permuted_Q_j<kMmaAtomK>(
                                          lane_smem_Q_Br, lane_smem_Q_d)) *
                                         sizeof(half));
              LDMATRIX_X4(R_Q[tile_K_d][i][0], R_Q[tile_K_d][i][1],
                          R_Q[tile_K_d][i][2], R_Q[tile_K_d][i][3],
                          lane_smem_Q_ptr);
            } // end for kWarpTileSeqLenQ
          } // end tile_K_seqlen == 0
        } // end kDelayPrefetchQs2r
      } // end kCanPrefetchQs2r

// smem -> reg, load k16n8 from smem K, offset d according tile_K_d.
// ldmatrix.x2 for K_tile_smem, [Bc,kMmaAtomK] from [Bc,d]=[K,N]
#pragma unroll
      for (int j = 0; j < kWarpTileSeqLenK; ++j) {
        // load k16n8 via ldmatrix.x2 from K_tile_smem[Bc,d].
        // K[Bc,d] with row major means K^T[d,Bc] in col major.
        int warp_smem_K_Bc =
            warp_KV * (kMmaAtomN * kWarpTileSeqLenK) + j * kMmaAtomN;
        int lane_smem_K_Bc = warp_smem_K_Bc + lane_id % 8; // 0~7
        // int lane_smem_K_d = tile_K_d * kMmaAtomK + ((lane_id / 8) % 2) * 8;
        // // 0,8
        int lane_smem_K_d = ((lane_id / 8) % 2) * 8; // 0,8
        uint32_t lane_smem_K_ptr =
            (smem_K_base_ptr +
             (kPrefetchKg2sSmemId * K_tile_size +
              tile_K_d * Bc * (kMmaAtomK + kPadK) +
              lane_smem_K_Bc * (kMmaAtomK + kPadK) +
              swizzle_permuted_K_j<kMmaAtomK>(lane_smem_K_Bc, lane_smem_K_d)) *
                 sizeof(half));
        LDMATRIX_X2(R_K[j][0], R_K[j][1], lane_smem_K_ptr); // R_K
      } // end for kWarpTileSeqLenK

      if constexpr (kCanPrefetchQs2r) {
        // MMA compute
        static_assert(kWarpTileSeqLenQ == 1);
        { // kWarpTileSeqLenQ = 1
#pragma unroll
          for (int j = 0; j < kWarpTileSeqLenK; ++j) {
            HMMA16816(R_S[0][j][0], R_S[0][j][1], R_Q[tile_K_d][0][0],
                      R_Q[tile_K_d][0][1], R_Q[tile_K_d][0][2],
                      R_Q[tile_K_d][0][3], R_K[j][0], R_K[j][1], R_S[0][j][0],
                      R_S[0][j][1]);
          }
        }
      } else {
        // MMA compute
        static_assert(kWarpTileSeqLenQ == 1);
        { // kWarpTileSeqLenQ = 1
#pragma unroll
          for (int j = 0; j < kWarpTileSeqLenK; ++j) {
            HMMA16816(R_S[0][j][0], R_S[0][j][1], R_Q[0][0][0], R_Q[0][0][1],
                      R_Q[0][0][2], R_Q[0][0][3], R_K[j][0], R_K[j][1],
                      R_S[0][j][0], R_S[0][j][1]);
          }
        }
      }
    } // end loop over d, S=Q@K^T
    __syncthreads();

    // <w/o Prefetch V g2s>: If kCanPrefetchKVg2s is not enable,
    // we will load V g2s here, before rowmax and rowsum.
    if constexpr (!kCanPrefetchKVg2s) {
      // [d,Bc]
      load_gmem_V_Bc_offset =
          tile_K_seqlen * Bc; // e.g (0~3)*64=(0,64,128,192,...)
      int load_gmem_V_d = load_smem_V_d;
      int load_gmem_V_Bc = load_gmem_V_Bc_offset + load_smem_V_Bc;
      int load_gmem_V_addr =
          (V_gmem_offset + load_gmem_V_d * QKV_seqlen + load_gmem_V_Bc);
#pragma unroll
      for (int i = 0; i < (Bc / (kNumThreads / kHeadDim)); i += 8) {
        uint32_t load_smem_V_ptr =
            (smem_V_base_ptr +
             (kPrefetchVg2sSmemId * V_tile_size +
              ((load_smem_V_Bc + i) / kMmaAtomK) * kHeadDim *
                  (kMmaAtomK + kPadV) + // chunk, d=64, 0~3
              load_smem_V_d * (kMmaAtomK + kPadV) +
              swizzle_permuted_V_j<kMmaAtomK>(
                  load_smem_V_d, ((load_smem_V_Bc + i) % kMmaAtomK))) *
                 sizeof(half));
        CP_ASYNC_CG(load_smem_V_ptr, &V[load_gmem_V_addr + i], 16);
      }
      CP_ASYNC_COMMIT_GROUP();
    }

    // <Prefetch K g2s>: load next K tile from gmem -> smem 0, before P@V.
    if constexpr (kCanPrefetchKVg2s) {
      if ((tile_K_seqlen + 1) < Tc) {
        load_gmem_K_Bc_offset =
            (tile_K_seqlen + 1) * Bc; // e.g (0~3)*64=(0,64,128,192,...)
        int load_gmem_K_Bc = load_gmem_K_Bc_offset + load_smem_K_Bc;
        int load_gmem_K_d = load_smem_K_d;
        int load_gmem_K_addr =
            (K_gmem_offset + load_gmem_K_Bc * kHeadDim + load_gmem_K_d);
#pragma unroll
        for (int i = 0; i < (kHeadDim / (kNumThreads / Bc)); i += 8) {
          uint32_t load_smem_K_ptr =
              (smem_K_base_ptr +
               (kPrefetchKg2sSmemId * K_tile_size +
                ((load_smem_K_d + i) / kMmaAtomK) * Bc *
                    (kMmaAtomK + kPadK) + // chunk, d=64, 0~3
                load_smem_K_Bc * (kMmaAtomK + kPadK) +
                swizzle_permuted_K_j<kMmaAtomK>(
                    load_smem_K_Bc, ((load_smem_K_d + i) % kMmaAtomK))) *
                   sizeof(half));
          CP_ASYNC_CG(load_smem_K_ptr, &K[load_gmem_K_addr + i], 16);
        }
        CP_ASYNC_COMMIT_GROUP();
      }
    }

    // MMA = m16n8k16, Br=16x4=64, Bc=8x8=64, layout: 4 warps
    // |   64x64   |      warp_KV 0       |
    // | warp_QP 0 | MMA 0 ... MMA 0 (x8) |
    // | warp_QP 1 | MMA 1 ... MMA 1 (x8) |
    // | warp_QP 2 | MMA 2 ... MMA 2 (x8) |
    // | warp_QP 3 | MMA 3 ... MMA 3 (x8) |

    // Online safe softmax, warp/block reduce max/sum, row wise
    float lane_row_max_new[kWarpTileSeqLenQ][2]; // [1][2]
    float lane_row_sum_new[kWarpTileSeqLenQ][2]; // [1][2]
    fill_2D_regs<float, kWarpTileSeqLenQ, 2>(lane_row_max_new, -INFINITY);
    fill_2D_regs<float, kWarpTileSeqLenQ, 2>(lane_row_sum_new, 0.0f);

    static_assert(kWarpTileSeqLenQ == 1);
    // Row max for [Br,Bc] tile, Thread -> Warp -> Block.
    { // kWarpTileSeqLenQ = 1
// Thread level reduce max across kWarpTileSeqLenK dim, namely Bc.
#pragma unroll
      for (int j = 0; j < kWarpTileSeqLenK; ++j) {
        // reference:
        // https://docs.nvidia.com/cuda/parallel-thread-execution/index.html
        // #matrix-fragments-for-mma-m16n8k16-with-floating-point-type
        // The layout of the fragments held by different threads for C.
        // (m16n8k16) Row\Col  0    1    2    3    4    5    6    7 0        T0:
        // {c0, c1}  T1: {c0, c1}  T2: {c0, c1}  T3: {c0, c1} 1        T4: {c0,
        // c1}  T5: {c0, c1}  T6: {c0, c1}  T7: {c0, c1} 2        ...
        // ...
        // 7        T28: {c0, c1}  T29: {c0, c1}  T30: {c0, c1}  T31: {c0, c1}
        // 8        T0: {c2, c3}   T1: {c2, c3}   T2: {c2, c3}   T3: {c2, c3}
        // 9        T4: {c2, c3}   T5: {c2, c3}   T6: {c2, c3}   T7: {c2, c3}
        // 10       ...
        // ...
        // 15       T28: {c2, c3}  T29: {c2, c3}  T30: {c2, c3}  T31: {c2, c3}
        half *t_hptr_S_0_1 = reinterpret_cast<half *>(&(R_S[0][j][0]));
        // This should be the row max after S = (Q @ K^T) / sqrt(d)
        float tmp_max_0 =
            __half2float(__hmax(t_hptr_S_0_1[0], t_hptr_S_0_1[1])) * scale;
        float tmp_max_1 =
            __half2float(__hmax(t_hptr_S_0_1[2], t_hptr_S_0_1[3])) * scale;
        lane_row_max_new[0][0] = max(lane_row_max_new[0][0], tmp_max_0);
        lane_row_max_new[0][1] = max(lane_row_max_new[0][1], tmp_max_1);
      } // end for kWarpTileSeqLenK

      // Warp level reduce max, warp_size = 4
      // Each thread contains the maximum of 2 rows of Br,
      // and only the values of T0, T4, ..., T28 are used.
      lane_row_max_new[0][0] =
          warp_reduce_max<float, 4>(lane_row_max_new[0][0]);
      lane_row_max_new[0][1] =
          warp_reduce_max<float, 4>(lane_row_max_new[0][1]);
    } // end for kWarpTileSeqLenQ

    static_assert(kWarpTileSeqLenQ == 1);
    // Exp sum and mul scale_factor for [Br,Bc] tile, Thread -> Warp -> Block.
    { // kWarpTileSeqLenQ = 1
      // Use latest global row max without update.
      // Br 0, row_id, 0~7,  16~23, 32~39, 48~55;
      float block_row_max_new_0 = lane_row_max_new[0][0];
      // Br 1, row_id, 8~15, 24~31, 40~47, 56~63;
      float block_row_max_new_1 = lane_row_max_new[0][1];

      float block_row_max_old_0 = lane_block_row_max_old[0][0];
      float block_row_max_old_1 = lane_block_row_max_old[0][1];
      // Apply m_new = max(m_old, m_new) here.
      block_row_max_new_0 = max(block_row_max_old_0, block_row_max_new_0);
      block_row_max_new_1 = max(block_row_max_old_1, block_row_max_new_1);

#pragma unroll
      for (int j = 0; j < kWarpTileSeqLenK; ++j) {
        half *t_hptr_S_0_1 = reinterpret_cast<half *>(&(R_S[0][j][0]));
        // P = Exp(S - m_new), fmaf(x, y, z) = x * y + z;
        float4 t_reg_S_0_1;
        t_reg_S_0_1.x = __expf(__fmaf_rn(__half2float(t_hptr_S_0_1[0]), scale,
                                         -block_row_max_new_0));
        t_reg_S_0_1.y = __expf(__fmaf_rn(__half2float(t_hptr_S_0_1[1]), scale,
                                         -block_row_max_new_0));
        t_reg_S_0_1.z = __expf(__fmaf_rn(__half2float(t_hptr_S_0_1[2]), scale,
                                         -block_row_max_new_1));
        t_reg_S_0_1.w = __expf(__fmaf_rn(__half2float(t_hptr_S_0_1[3]), scale,
                                         -block_row_max_new_1));
        lane_row_sum_new[0][0] += (t_reg_S_0_1.x + t_reg_S_0_1.y);
        lane_row_sum_new[0][1] += (t_reg_S_0_1.z + t_reg_S_0_1.w);
        // Update R_S for P[Br,Bc] = Exp(S-m), point wise.
        t_hptr_S_0_1[0] = __float2half_rn(t_reg_S_0_1.x);
        t_hptr_S_0_1[1] = __float2half_rn(t_reg_S_0_1.y);
        t_hptr_S_0_1[2] = __float2half_rn(t_reg_S_0_1.z);
        t_hptr_S_0_1[3] = __float2half_rn(t_reg_S_0_1.w);
      } // end for kWarpTileSeqLenK

      // Warp level reduce sum, warp_size = 4
      lane_row_sum_new[0][0] =
          warp_reduce_sum<float, 4>(lane_row_sum_new[0][0]);
      lane_row_sum_new[0][1] =
          warp_reduce_sum<float, 4>(lane_row_sum_new[0][1]);
    } // end for kWarpTileSeqLenQ = 1

    // Compute P[Br,Bc] @ V[Bc,d] = [Br,d] = [64, 64/128], partion Attention.
    // Here, we have to wait V ready before compute O = P @ V
    if constexpr (kCanPrefetchKVg2s) {
      if ((tile_K_seqlen + 1) < Tc) {
        CP_ASYNC_WAIT_GROUP(
            1); // we have send V & K g2s, wait V and let K async.
      } else {
        CP_ASYNC_WAIT_GROUP(0); // we have only send V g2s.
      }
    } else {
      CP_ASYNC_WAIT_GROUP(0);
    }
    __syncthreads();

    // <loop over V Bc>: P[Br,Bc]@V[Bc,d]=[Br,d]=[64,64/128], partion Attention.
    // Matmul with NN layout: P[Br,Bc] row major, V[Bc,d] row major.
    // Make sure to clear the states in R_O before MMA for P@V for each step.

    // NOTE: Values for P[Br,Bc] already in R_S registers, can we use these
    // registers for P(A) matrix directly ? How to do that ?
    // according to the A matrix layout for MMA m16n8k16 instruction.
    // reference:
    // https://docs.nvidia.com/cuda/parallel-thread-execution/index.html
    // #matrix-fragments-for-mma-m16n8k16-with-floating-point-type
    // The layout of the fragments held by different threads for A matrix with
    // .f16. R\C  0    1    2    3    4    5    6    7    8    9   10   11   12
    // 13   14   15 0    T0: {a0, a1}  T1: {a0, a1}  T2: {a0, a1}  T3: {a0, a1}
    // T0: {a4, a5}  T1: {a4, a5}  T2: {a4, a5}  T3: {a4, a5} 1    T4: {a0, a1}
    // T5: {a0, a1}  T6: {a0, a1}  T7: {a0, a1}  T4: {a4, a5}  T5: {a4, a5}  T6:
    // {a4, a5}  T7: {a4, a5} 2    (dashed arrow pointing right)
    // ...
    // 7    T28: {a0, a1}  T29: {a0, a1}  T30: {a0, a1}  T31: {a0, a1}  T28:
    // {a4, a5}  T29: {a4, a5}  T30: {a4, a5}  T31: {a4, a5} 8    T0: {a2, a3}
    // T1: {a2, a3}   T2: {a2, a3}   T3: {a2, a3}   T0: {a6, a7}   T1: {a6, a7}
    // T2: {a6, a7}   T3: {a6, a7} 9    T4: {a2, a3}   T5: {a2, a3}   T6: {a2,
    // a3}   T7: {a2, a3}   T4: {a6, a7}   T5: {a6, a7}   T6: {a6, a7}   T7:
    // {a6, a7} 10   (dashed arrow pointing right)
    // ...
    // 15   T28: {a2, a3}  T29: {a2, a3}  T30: {a2, a3}  T31: {a2, a3}  T28:
    // {a6, a7}  T29: {a6, a7}  T30: {a6, a7}  T31: {a6, a7}

    // <HGEMM in registers>
    fill_3D_regs<uint32_t, kWarpTileSeqLenP, kWarpTileHeadDimV, 2>(R_O, 0);
#pragma unroll
    for (int tile_V_Bc = 0; tile_V_Bc < (Bc / kMmaAtomK); ++tile_V_Bc) {
// Load k16n8 V from smem -> regs, R_KV, ldmatrix.x2.trans.
#pragma unroll
      for (int j = 0; j < kWarpTileHeadDimV; ++j) {
        // [d,Bc]
        int warp_smem_V_d = warp_KV * (kMmaAtomN * kWarpTileHeadDimV) +
                            j * kMmaAtomN; // d, matmaul N
        // int lane_smem_V_Bc = tile_V_Bc * kMmaAtomK + lane_id % 16; // 0~15;
        // Bc, matmul K
        int lane_smem_V_d = warp_smem_V_d + lane_id % 8; // 0~7;
        int lane_smem_V_Bc = ((lane_id / 8) % 2) * 8;    // 0,8
        uint32_t lane_smem_V_ptr =
            (smem_V_base_ptr +
             (kPrefetchVg2sSmemId * V_tile_size +
              tile_V_Bc * kHeadDim * (kMmaAtomK + kPadV) +
              lane_smem_V_d * (kMmaAtomK + kPadV) +
              swizzle_permuted_V_j<kMmaAtomK>(lane_smem_V_d, lane_smem_V_Bc)) *
                 sizeof(half));
        LDMATRIX_X2(R_V[j][0], R_V[j][1], lane_smem_V_ptr); // R_V
      }

      // For R_S[1][8][2], mapping the layout below of P matrix.
      // MMA = m16n8k16, Br=16x4=64, Bc=8x8=64, layout: 4 warps
      // |   64x64   |      warp_KV 0       |
      // | warp_QP 0 | MMA 0 ... MMA 0 (x8) |
      // | warp_QP 1 | MMA 1 ... MMA 1 (x8) |
      // | warp_QP 2 | MMA 2 ... MMA 2 (x8) |
      // | warp_QP 3 | MMA 3 ... MMA 3 (x8) |
      // tile_V_Bc = 0, all curr MMAs(0~4) need slice P[:,  0:16], 0, 1; stored
      // in all MMAs. tile_V_Bc = 1, all curr MMAs(0~4) need slice P[:, 16:32],
      // 2, 3; stored in all MMAs. tile_V_Bc = 2, all curr MMAs(0~4) need slice
      // P[:, 32:48], 4, 5; stored in all MMAs. tile_V_Bc = 3, all curr
      // MMAs(0~4) need slice P[:, 48:64], 6, 7; stored in all MMAs.
      int w = tile_V_Bc * 2; // MMA(Warp) selected, 0, 2, 4, 6
      static_assert(kWarpTileSeqLenP == 1);
      { // kWarpTileSeqLenP = 1
#pragma unroll
        for (int j = 0; j < kWarpTileHeadDimV; ++j) { // 8, 16, 32, ...
          HMMA16816(R_O[0][j][0], R_O[0][j][1], R_S[0][w][0], R_S[0][w][1],
                    R_S[0][w + 1][0], R_S[0][w + 1][1], R_V[j][0], R_V[j][1],
                    R_O[0][j][0], R_O[0][j][1]);
        }
      }
    } // end for V Bc.
    __syncthreads();

    // Rescale O -> Update row sum Exp -> then, Update row max.
    static_assert(kWarpTileSeqLenP == 1);
    { // kWarpTileSeqLenQ=kWarpTileSeqLenP=1
      // m = max(m_old, m_new), l = exp(m_old - m) * l_old + l_new (FA2 paper)
      // Br 0, row_id, 0~7,  16~23, 32~39, 48~55; Br 1, row_id, 8~15, 24~31,
      // 40~47, 56~63
      float block_row_max_new_0 = lane_row_max_new[0][0];
      float block_row_max_new_1 = lane_row_max_new[0][1];
      float block_row_sum_new_0 = lane_row_sum_new[0][0];
      float block_row_sum_new_1 = lane_row_sum_new[0][1];

      float block_row_max_old_0 = lane_block_row_max_old[0][0];
      float block_row_max_old_1 = lane_block_row_max_old[0][1];
      // NOTE: max(-inf, val) = val.
      block_row_max_new_0 = max(block_row_max_old_0, block_row_max_new_0);
      block_row_max_new_1 = max(block_row_max_old_1, block_row_max_new_1);
      // Avoid inf value while using m_old for rescaling O.
      block_row_max_old_0 =
          (tile_K_seqlen > 0 ? block_row_max_old_0 : block_row_max_new_0);
      block_row_max_old_1 =
          (tile_K_seqlen > 0 ? block_row_max_old_1 : block_row_max_new_1);

      // rescale factor for O and l, exp(m_old - m)
      float rescale_o_factor_0 =
          __expf(block_row_max_old_0 - block_row_max_new_0);
      float rescale_o_factor_1 =
          __expf(block_row_max_old_1 - block_row_max_new_1);
// 0. Rescale O: Online rescaling O each tile_K_seqlen step, need m_new, m_old.
// m = max(m_old, m_new), O_new[Br,d] = exp(m_old - m) * O_old + P@V
#pragma unroll
      for (int j = 0; j < kWarpTileHeadDimV; ++j) { // 8, 16, 32, ...
        // Note that the formula in the FA2 paper is incorrect; here,
        // the inverse of the exp function should not be taken, as it
        // would result in an error during rescaling, namely, you have
        // use exp(m_old - m_new), not 1/(m_old - m_new).
        // O_new[Br,d] = exp(m_old - m_new) * O_old + P@V
        // (x,y) 0~7->{c0, c1}, (z,w)->8~15 {c2, c3}
        half *t_hptr_O_0_1 = reinterpret_cast<half *>(&(R_O[0][j][0]));
        if constexpr (kOStorageAccFloat32) {
          // (x,y) 0~7->{c0, c1}, (z,w)->8~15 {c2, c3}
          float *t_fptr_D_0_1 = reinterpret_cast<float *>(&(R_D[0][j][0]));
          t_fptr_D_0_1[0] = __fmaf_rn(rescale_o_factor_0, t_fptr_D_0_1[0],
                                      __half2float(t_hptr_O_0_1[0]));
          t_fptr_D_0_1[1] = __fmaf_rn(rescale_o_factor_0, t_fptr_D_0_1[1],
                                      __half2float(t_hptr_O_0_1[1]));
          t_fptr_D_0_1[2] = __fmaf_rn(rescale_o_factor_1, t_fptr_D_0_1[2],
                                      __half2float(t_hptr_O_0_1[2]));
          t_fptr_D_0_1[3] = __fmaf_rn(rescale_o_factor_1, t_fptr_D_0_1[3],
                                      __half2float(t_hptr_O_0_1[3]));
        } else {
          half *t_hptr_D_0_1 = reinterpret_cast<half *>(&(R_D[0][j][0]));
          t_hptr_D_0_1[0] = __float2half_rn(
              __fmaf_rn(rescale_o_factor_0, __half2float(t_hptr_D_0_1[0]),
                        __half2float(t_hptr_O_0_1[0])));
          t_hptr_D_0_1[1] = __float2half_rn(
              __fmaf_rn(rescale_o_factor_0, __half2float(t_hptr_D_0_1[1]),
                        __half2float(t_hptr_O_0_1[1])));
          t_hptr_D_0_1[2] = __float2half_rn(
              __fmaf_rn(rescale_o_factor_1, __half2float(t_hptr_D_0_1[2]),
                        __half2float(t_hptr_O_0_1[2])));
          t_hptr_D_0_1[3] = __float2half_rn(
              __fmaf_rn(rescale_o_factor_1, __half2float(t_hptr_D_0_1[3]),
                        __half2float(t_hptr_O_0_1[3])));
        }
      } // end for kWarpTileHeadDimV.

      // Now, we can update m, l after O has been scaled.
      // 1. First, update block row sum Exp for each lane which
      // need both m_new and m_old.
      float block_row_sum_old_0 = lane_block_row_sum_old[0][0];
      float block_row_sum_old_1 = lane_block_row_sum_old[0][1];
      // Update l = exp(m_old - m_new) * l_old + row_sum(P).
      lane_block_row_sum_old[0][0] = (__fmaf_rn(
          rescale_o_factor_0, block_row_sum_old_0, block_row_sum_new_0));
      lane_block_row_sum_old[0][1] = (__fmaf_rn(
          rescale_o_factor_1, block_row_sum_old_1, block_row_sum_new_1));
      // 2. Then, update block row max for each lane.
      lane_block_row_max_old[0][0] = block_row_max_new_0;
      lane_block_row_max_old[0][1] = block_row_max_new_1;
    }

    if constexpr (kCanPrefetchKVg2s) {
      if ((tile_K_seqlen + 1) < Tc) {
        // now, we have to wait next K tile ready in smem.
        CP_ASYNC_WAIT_GROUP(0);
        __syncthreads();
      }
    }

  } // end loop over N
  __syncthreads();

  // Finaly, we still have to rescale O once more.
  // O_output(D) = ( 1/l_final ) * O_final (FA2 paper)
  // NOTE: Here, we choose to reuse R_O as final output
  // in order to reduce regs usage.
  static_assert(kWarpTileSeqLenP == 1);
  { // kWarpTileSeqLenP = 1
    float rescale_factor_0 = __frcp_rn(lane_block_row_sum_old[0][0]);
    float rescale_factor_1 = __frcp_rn(lane_block_row_sum_old[0][1]);
#pragma unroll
    for (int j = 0; j < kWarpTileHeadDimV; ++j) { // 8, 16, 32, ...
      // Scaling in registers & convert F32 -> half for O collective store.
      if constexpr (kOStorageAccFloat32) {
        float *t_fptr_D_0_1 = reinterpret_cast<float *>(&(R_D[0][j][0]));
        half *t_hptr_D_0_1 = reinterpret_cast<half *>(&(R_D[0][j][0]));
        t_hptr_D_0_1[0] = __float2half_rn(rescale_factor_0 * t_fptr_D_0_1[0]);
        t_hptr_D_0_1[1] = __float2half_rn(rescale_factor_0 * t_fptr_D_0_1[1]);
        t_hptr_D_0_1[2] = __float2half_rn(rescale_factor_1 * t_fptr_D_0_1[2]);
        t_hptr_D_0_1[3] = __float2half_rn(rescale_factor_1 * t_fptr_D_0_1[3]);
      } else {
        half *t_hptr_D_0_1 = reinterpret_cast<half *>(&(R_D[0][j][0]));
        t_hptr_D_0_1[0] =
            __float2half_rn(rescale_factor_0 * __half2float(t_hptr_D_0_1[0]));
        t_hptr_D_0_1[1] =
            __float2half_rn(rescale_factor_0 * __half2float(t_hptr_D_0_1[1]));
        t_hptr_D_0_1[2] =
            __float2half_rn(rescale_factor_1 * __half2float(t_hptr_D_0_1[2]));
        t_hptr_D_0_1[3] =
            __float2half_rn(rescale_factor_1 * __half2float(t_hptr_D_0_1[3]));
      }
    } // end for kWarpTileHeadDimV
  } // end for kWarpTileSeqLenP = 1

  // Store O(D): Write O[Br,d] from regs -> gmem, collective store
  // with reg reuse & warp shuffle. need R_Z[2][4].
  // Store O(D): Write O[Br,d] from regs -> gmem, collective store
  // with reg reuse & warp shuffle. may need R_Z[2][4].
  static_assert(kWarpTileSeqLenP == 1);
  { // kWarpTileSeqLenP = 1
#pragma unroll
    for (int j = 0; j < kWarpTileHeadDimV; ++j) { // 8
      if constexpr (kCanPrefetchQs2r && kNumPrefetchQs2r > 1) {
        // reuse R_Q[4/8][1][4] for collective store.
        R_Q[0][0][0] = R_D[0][j][0];
        R_Q[1][0][0] = R_D[0][j][1]; // warp_size 4
        R_Q[0][0][1] = __shfl_sync((0xffffffff), R_D[0][j][0], lane_id + 1, 4);
        R_Q[0][0][2] = __shfl_sync((0xffffffff), R_D[0][j][0], lane_id + 2, 4);
        R_Q[0][0][3] = __shfl_sync((0xffffffff), R_D[0][j][0], lane_id + 3, 4);
        R_Q[1][0][1] = __shfl_sync((0xffffffff), R_D[0][j][1], lane_id + 1, 4);
        R_Q[1][0][2] = __shfl_sync((0xffffffff), R_D[0][j][1], lane_id + 2, 4);
        R_Q[1][0][3] = __shfl_sync((0xffffffff), R_D[0][j][1], lane_id + 3, 4);
        // st.global.v4 128 bits. [Br,d]
        if (lane_id % 4 == 0) {
          // (0/1)*32 + (0/1)*16=(0,16,32,48), + 0~7 -> 0~56
          int store_warp_regs_O_Br =
              warp_QP * (kMmaAtomM * kWarpTileSeqLenP) + 0 * kMmaAtomM;
          int store_lane_gmem_O_Br =
              O_tile_id * Br + store_warp_regs_O_Br + lane_id / 4; // 0~7
          // (0~3)*16 + (0/1)*8=(0,8,16,24,...,48,56)
          int store_warp_regs_O_d =
              warp_KV * (kMmaAtomN * kWarpTileHeadDimV) + j * kMmaAtomN;
          int store_lane_gmem_O_d = store_warp_regs_O_d; // (0~3)*16+(0/8)
          int store_gmem_O_addr_0 =
              (O_gmem_offset + (store_lane_gmem_O_Br + 0) * kHeadDim +
               store_lane_gmem_O_d);
          int store_gmem_O_addr_1 =
              (O_gmem_offset + (store_lane_gmem_O_Br + 8) * kHeadDim +
               store_lane_gmem_O_d);
          LDST128BITS(O[store_gmem_O_addr_0]) = LDST128BITS(R_Q[0][0][0]);
          LDST128BITS(O[store_gmem_O_addr_1]) = LDST128BITS(R_Q[1][0][0]);
        }
      } else {
        // we have to use new R_Z regs for collective store.
        uint32_t R_Z[2][4];
        R_Z[0][0] = R_D[0][j][0];
        R_Z[1][0] = R_D[0][j][1]; // warp_size 4
        R_Z[0][1] = __shfl_sync((0xffffffff), R_D[0][j][0], lane_id + 1, 4);
        R_Z[0][2] = __shfl_sync((0xffffffff), R_D[0][j][0], lane_id + 2, 4);
        R_Z[0][3] = __shfl_sync((0xffffffff), R_D[0][j][0], lane_id + 3, 4);
        R_Z[1][1] = __shfl_sync((0xffffffff), R_D[0][j][1], lane_id + 1, 4);
        R_Z[1][2] = __shfl_sync((0xffffffff), R_D[0][j][1], lane_id + 2, 4);
        R_Z[1][3] = __shfl_sync((0xffffffff), R_D[0][j][1], lane_id + 3, 4);
        // st.global.v4 128 bits. [Br,d]
        if (lane_id % 4 == 0) {
          // (0/1)*32 + (0/1)*16=(0,16,32,48), + 0~7 -> 0~56
          int store_warp_regs_O_Br =
              warp_QP * (kMmaAtomM * kWarpTileSeqLenP) + 0 * kMmaAtomM;
          int store_lane_gmem_O_Br =
              O_tile_id * Br + store_warp_regs_O_Br + lane_id / 4; // 0~7
          // (0~3)*16 + (0/1)*8=(0,8,16,24,...,48,56)
          int store_warp_regs_O_d =
              warp_KV * (kMmaAtomN * kWarpTileHeadDimV) + j * kMmaAtomN;
          int store_lane_gmem_O_d = store_warp_regs_O_d; // (0~3)*16+(0/8)
          int store_gmem_O_addr_0 =
              (O_gmem_offset + (store_lane_gmem_O_Br + 0) * kHeadDim +
               store_lane_gmem_O_d);
          int store_gmem_O_addr_1 =
              (O_gmem_offset + (store_lane_gmem_O_Br + 8) * kHeadDim +
               store_lane_gmem_O_d);
          LDST128BITS(O[store_gmem_O_addr_0]) = LDST128BITS(R_Z[0][0]);
          LDST128BITS(O[store_gmem_O_addr_1]) = LDST128BITS(R_Z[1][0]);
        }
      } // end if kCanPrefetchQs2r
    } // end for kWarpTileHeadDimV
  } // end for kWarpTileSeqLenP = 1
}

// Launch kernel for flash_attn_mma_stages_split_q
template <const int kHeadDim, const int kStage>
void launch_flash_attn_mma_stages_split_q_shared_kv_swizzle_qkv(
    torch::Tensor Q, torch::Tensor K, torch::Tensor V, torch::Tensor O) {
  constexpr int kMmaAtomM = 16;
  constexpr int kMmaAtomN = 8;
  constexpr int kMmaAtomK = 16;
#ifdef BUILD_FLASH_ATTN_MMA_L20
  // Now: fixed tile BrxBc=64x32 kStage > 1, 64x64 for kStage = 1,
  // more threads will need more registers per block, thus, it may
  // cause occupancy to decrease. (tuning)
  constexpr int kMmaTileSeqLenQ = (kHeadDim < 256) ? 4 : 8;
  constexpr int kMmaTileSeqLenK = 1;
  constexpr int kMmaTileSeqLenP = (kHeadDim < 256) ? 4 : 8;
  constexpr int kMmaTileHeadDimV = 1;
  constexpr int kWarpTileSeqLenQ = 1;
  constexpr int kWarpTileSeqLenK =
      (kHeadDim < 256) ? ((kStage > 1) ? 4 : 8) : 8;
  constexpr int kWarpTileSeqLenP = 1;
#else
  constexpr int kMmaTileSeqLenQ = (kHeadDim < 256) ? 8 : 8;
  constexpr int kMmaTileSeqLenK = 1;
  constexpr int kMmaTileSeqLenP = (kHeadDim < 256) ? 8 : 8;
  constexpr int kMmaTileHeadDimV = 1;
  constexpr int kWarpTileSeqLenQ = 1;
  constexpr int kWarpTileSeqLenK =
      (kHeadDim < 256) ? ((kStage > 1) ? 8 : 8) : 4;
  constexpr int kWarpTileSeqLenP = 1;
#endif
  constexpr int kWarpTileHeadDimV =
      (kHeadDim / (kMmaAtomN * kMmaTileHeadDimV)); // 8,16,32,....
  constexpr int Br =
      kMmaAtomM * kMmaTileSeqLenQ * kWarpTileSeqLenQ; // 16*4*1=64
  constexpr int Bc =
      kMmaAtomN * kMmaTileSeqLenK * kWarpTileSeqLenK; //  8*1*8=64
  constexpr int kNumThreads =
      WARP_SIZE * kMmaTileSeqLenQ * kMmaTileSeqLenK; // 32*4*1=128, num threads
  constexpr int kPadQ = 0;
  constexpr int kPadK = 0;
  constexpr int kPadV = 0;
  // 0/1, MMA Acc always be fp16, but O storage can be fp32 or half.
  // FP16 can provide precision to approximately 3-4 decimal places.
  // Thus, if the error does not exceed 1e-3, using FP16 storage is
  // sufficient for most applications.
  constexpr int kOStorageAccFloat32 = (kHeadDim < 256) ? 1 : 0;

  // static int kMaxSramPerBlock;
  // cudaDeviceGetAttribute(&kMaxSramPerBlock,
  // cudaDevAttrMaxSharedMemoryPerBlock, 0); Calculate SRAM size needed per
  // block, Q,K/V smem size, KV shared the same smem.
  constexpr int Q_tile_size = (kHeadDim / kMmaAtomK) * Br * (kMmaAtomK + kPadQ);
  constexpr int K_tile_size = (kHeadDim / kMmaAtomK) * Bc * (kMmaAtomK + kPadK);
  constexpr int V_tile_size = (Bc / kMmaAtomK) * kHeadDim * (kMmaAtomK + kPadV);
  const int smem_max_size =
      (Q_tile_size + kStage * max(K_tile_size, V_tile_size)) * sizeof(half);

  const int QKV_batch = Q.size(0);
  const int QKV_head = Q.size(1);
  const int QKV_seqlen = Q.size(2);      // QKV_seqlen
  assert(QKV_seqlen % max(Br, Bc) == 0); // multiple of max(Br, Bc)

  // TODO: How to apply block swizzle to improve L2 Cache hit rate?
  // NOTE: reorder (B,H,Tr) -> (Tr,B*H) seems can improve L2 Cache hit rate.
  // This might be because SM schedules blocks starting from the x-dimension.
  // Placing Tr at the forefront ensures that identical KV pairs are placed
  // in consecutive scheduling queues, thereby improving L2 Cache hit rates.
  // Tr(=N/Br), batch_size x num_heads
  dim3 grid(div_ceil(QKV_seqlen, Br), QKV_batch * QKV_head);
  dim3 block(kNumThreads); // 4/8 warps per block

  cudaFuncSetAttribute(
      flash_attn_mma_stages_split_q_shared_kv_swizzle_qkv_kernel<
          kHeadDim, kMmaAtomM, kMmaAtomN, kMmaAtomK, kMmaTileSeqLenQ,
          kMmaTileSeqLenK, kMmaTileSeqLenP, kMmaTileHeadDimV, kWarpTileSeqLenQ,
          kWarpTileSeqLenK, kWarpTileSeqLenP, kWarpTileHeadDimV,
          kOStorageAccFloat32, kStage, kPadQ, kPadK, kPadV>,
      cudaFuncAttributeMaxDynamicSharedMemorySize,
      // kMaxSramPerBlock
      98304);

  flash_attn_mma_stages_split_q_shared_kv_swizzle_qkv_kernel<
      kHeadDim, kMmaAtomM, kMmaAtomN, kMmaAtomK, kMmaTileSeqLenQ,
      kMmaTileSeqLenK, kMmaTileSeqLenP, kMmaTileHeadDimV, kWarpTileSeqLenQ,
      kWarpTileSeqLenK, kWarpTileSeqLenP, kWarpTileHeadDimV,
      kOStorageAccFloat32, kStage, kPadQ, kPadK, kPadV>
      <<<grid, block, smem_max_size>>>(reinterpret_cast<half *>(Q.data_ptr()),
                                       reinterpret_cast<half *>(K.data_ptr()),
                                       reinterpret_cast<half *>(V.data_ptr()),
                                       reinterpret_cast<half *>(O.data_ptr()),
                                       QKV_seqlen, QKV_head);
}

void flash_attn_mma_stages_split_q_shared_kv_swizzle_qkv(torch::Tensor Q,
                                                         torch::Tensor K,
                                                         torch::Tensor V,
                                                         torch::Tensor O,
                                                         int stages) {
  CHECK_TORCH_TENSOR_DTYPE(Q, torch::kHalf) // Q [B,H,N,D]
  CHECK_TORCH_TENSOR_DTYPE(K, torch::kHalf) // K [B,H,N,D]
  CHECK_TORCH_TENSOR_DTYPE(V, torch::kHalf) // V [B,H,D,N]
  CHECK_TORCH_TENSOR_DTYPE(O, torch::kHalf) // O [B,H,N,D]
  const int d = Q.size(3);                  // B, H, N, d

  if (stages > 1) {
    switch (d) {
    case 32:
      launch_flash_attn_mma_stages_split_q_shared_kv_swizzle_qkv<32, 2>(Q, K, V,
                                                                        O);
      break;
    case 64:
      launch_flash_attn_mma_stages_split_q_shared_kv_swizzle_qkv<64, 2>(Q, K, V,
                                                                        O);
      break;
    case 96:
      launch_flash_attn_mma_stages_split_q_shared_kv_swizzle_qkv<96, 2>(Q, K, V,
                                                                        O);
      break;
    case 128:
      launch_flash_attn_mma_stages_split_q_shared_kv_swizzle_qkv<128, 2>(Q, K,
                                                                         V, O);
      break;
    default:
      throw std::runtime_error("headdim not support!");
      break;
    }
  } else {
    switch (d) {
    case 32:
      launch_flash_attn_mma_stages_split_q_shared_kv_swizzle_qkv<32, 1>(Q, K, V,
                                                                        O);
      break;
    case 64:
      launch_flash_attn_mma_stages_split_q_shared_kv_swizzle_qkv<64, 1>(Q, K, V,
                                                                        O);
      break;
    case 96:
      launch_flash_attn_mma_stages_split_q_shared_kv_swizzle_qkv<96, 1>(Q, K, V,
                                                                        O);
      break;
    case 128:
      launch_flash_attn_mma_stages_split_q_shared_kv_swizzle_qkv<128, 1>(Q, K,
                                                                         V, O);
      break;
    case 256:
      launch_flash_attn_mma_stages_split_q_shared_kv_swizzle_qkv<256, 1>(Q, K,
                                                                         V, O);
      break;
    default:
      throw std::runtime_error("headdim not support!");
      break;
    }
  }
}
