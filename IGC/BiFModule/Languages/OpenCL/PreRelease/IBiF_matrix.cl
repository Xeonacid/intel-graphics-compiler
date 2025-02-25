/*========================== begin_copyright_notice ============================

Copyright (C) 2021 Intel Corporation

SPDX-License-Identifier: MIT

============================= end_copyright_notice ===========================*/

// uncomment for debugging to print friendly numbers
//
// convert bf16 to int
// int bf162int(short a) {
//     return convert_int(as_float(a << 16));
// }
//
// convert packed 2 bf16 numbers to int2
// int2 pbf162int2(int a) {
//     short2 ai = as_short2(a);
//     return (int2)(bf162int(ai.x), bf162int(ai.y));
// }
//

// Optimized implementation of Joint Matrix Load/Store built-ins
// Highest values indicate most preferable implementations, when given level of
// optimization is not avaialble due to platform capabilities or given
// combination of parameters next best implementation will be used.
#define SCALAR_IMPL      0 // Subgroup load/store for each item of the slice.
#define VECTOR_IMPL      1 // Block read/write per row/column of the slice.
#define VECTOR_CONT_IMPL 2 // Single block read/write for whole slice, where possible.
#define BLOCK2D_IMPL     3 // Single block read/write 2d operation, only on supported platforms (default).

// Matrix order
#define _ROW_MAJOR 0
#define _COL_MAJOR 1
#define _VNNI_TX   2

// Address space
#define AS_GENERIC 0
#define AS_LOCAL   1
#define AS_GLOBAL  2

// Matrix layout
#define _PackedA_RowMajor 0
#define _PackedB_RowMajor 1
#define _PackedB_ColumnMajor 2
#define _PackedB_PackedB 3
#define _Accumulator_RowMajor 4
#define _Accumulator_ColumnMajor 5
#define _PackedA_ColumnMajor 6

#define ATTRIBUTE_AS_GENERIC __global /* the branch using this will be dead,
                                         however we still need a valid address
                                         space specifier to make a call to
                                         block read/write BI. */
#define ATTRIBUTE_AS_LOCAL   __local
#define ATTRIBUTE_AS_GLOBAL  __global

// Index for row major layout is calculated based on that sub group size may be
// bigger than N.
// Arguments:
//   sg_cols: Number of contiguous columns held in the subgroup
//   skip_factor: n, where we include elements from every n-th row of the JM
//   to be part of the wi.  e.g for a Matrix
//     1 2 3 4
//     5 6 7 8
//     9 10 11 12
//     13 14 15 16
//    if skip_factor == 2, we will include items <1, 9> (every "2"nd row) in the
//    first WI, <2, 10> in the second WI and so on..
#define IND_ROW_MAJOR(slid, stride, skip_factor, i, sg_cols) ((slid/sg_cols + i*skip_factor)*stride + (slid%sg_cols))
#define IND_COL_MAJOR(slid, stride, skip_factor, i, sg_cols) ((slid/sg_cols + i*skip_factor) + (slid%sg_cols)*stride)
#define IND_VNNI_TX(slid, stride, skip_factor, i, sg_cols) (i + (slid * stride))

// no int7, int6, int5 types
#define VEC_TO_VEC16(type, vec) \
    (type##16)(vec.s0, vec.s1, vec.s2, vec.s3, vec.s4, vec.s5, vec.s6, vec.s7, vec.s8, vec.s9, vec.sA, vec.sB, vec.sC, vec.sD, vec.sE, vec.sF)
#define VEC_TO_VEC8(type, vec) \
    (type##8)(vec.s0, vec.s1, vec.s2, vec.s3, vec.s4, vec.s5, vec.s6, vec.s7)
#define VEC_TO_VEC7(type, vec) \
    (type##8)(vec.s0, vec.s1, vec.s2, vec.s3, vec.s4, vec.s5, vec.s6, 0)
#define VEC_TO_VEC6(type, vec) \
    (type##8)(vec.s0, vec.s1, vec.s2, vec.s3, vec.s4, vec.s5, 0, 0)
#define VEC_TO_VEC5(type, vec) \
    (type##8)(vec.s0, vec.s1, vec.s2, vec.s3, vec.s4, 0, 0, 0)
#define VEC_TO_VEC4(type, vec) (type##4)(vec.s0, vec.s1, vec.s2, vec.s3)
#define VEC_TO_VEC3(type, vec) (type##3)(vec.s0, vec.s1, vec.s2)
#define VEC_TO_VEC2(type, vec) (type##2)(vec.s0, vec.s1)
#define VEC_TO_VEC1(type, vec) (type)(vec)

// in case of store, we can not use uint3 with intel_sub_group_block_write4
// for size 32, assumption is resulting vector is the same as input vector, so no need to create new one.
#define VEC_TO_VEC_STORE32(type, vec) vec
#define VEC_TO_VEC_STORE16(type, vec) VEC_TO_VEC16(type, vec)
#define VEC_TO_VEC_STORE8(type, vec) VEC_TO_VEC8(type, vec)
#define VEC_TO_VEC_STORE7(type, vec) VEC_TO_VEC7(type, vec)
#define VEC_TO_VEC_STORE6(type, vec) VEC_TO_VEC6(type, vec)
#define VEC_TO_VEC_STORE5(type, vec) VEC_TO_VEC5(type, vec)
#define VEC_TO_VEC_STORE4(type, vec) VEC_TO_VEC4(type, vec)
#define VEC_TO_VEC_STORE3(type, vec) (type##4)(vec.s0, vec.s1, vec.s2, 0)
#define VEC_TO_VEC_STORE2(type, vec) VEC_TO_VEC2(type, vec)
#define VEC_TO_VEC_STORE1(type, vec) VEC_TO_VEC1(type, vec)

#define ARR_TO_VEC8(type, arr) \
    (type##8)(arr[0], arr[1], arr[2], arr[3], \
              arr[4], arr[5], arr[6], arr[7])

#define ARR_TO_VEC7(type, arr) \
    (type##8)(arr[0], arr[1], arr[2], arr[3], \
              arr[4], arr[5], arr[6], 0)

#define ARR_TO_VEC6(type, arr) \
    (type##8)(arr[0], arr[1], arr[2], arr[3], \
              arr[4], arr[5], 0,      0)

#define ARR_TO_VEC5(type, arr) \
    (type##8)(arr[0], arr[1], arr[2], arr[3], \
              arr[4], 0,      0,      0)

#define ARR_TO_VEC4(type, arr) \
    (type##4)(arr[0], arr[1], arr[2], arr[3])

#define ARR_TO_VEC3(type, arr) \
    (type##3)(arr[0], arr[1], arr[2])

#define ARR_TO_VEC2(type, arr) \
    (type##2)(arr[0], arr[1])

#define ARR_TO_VEC1(type, arr) \
    arr[0]

typedef ushort __attribute__((ext_vector_type(32))) ushort32;
typedef uint   __attribute__((ext_vector_type(32))) uint32;

#define OUT_VEC64(type) type##64
#define OUT_VEC32(type) type##32
#define OUT_VEC16(type) type##16
#define OUT_VEC8(type) type##8
#define OUT_VEC7(type) type##8
#define OUT_VEC6(type) type##8
#define OUT_VEC5(type) type##8
#define OUT_VEC4(type) type##4
#define OUT_VEC3(type) type##3
#define OUT_VEC2(type) type##2
#define OUT_VEC1(type) type

#define OUT_STORE_VEC32(type) type##32
#define OUT_STORE_VEC16(type) type##16
#define OUT_STORE_VEC8(type) type##8
#define OUT_STORE_VEC7(type) type##8
#define OUT_STORE_VEC6(type) type##8
#define OUT_STORE_VEC5(type) type##8
#define OUT_STORE_VEC4(type) type##4
#define OUT_STORE_VEC3(type) type##4
#define OUT_STORE_VEC2(type) type##2
#define OUT_STORE_VEC1(type) type

// Math division macros
#define MATH_128_DIV_8 16
#define MATH_128_DIV_4 32
#define MATH_128_DIV_2 64
#define MATH_64_DIV_64 1
#define MATH_64_DIV_32 2
#define MATH_64_DIV_16 4
#define MATH_64_DIV_8 8
#define MATH_64_DIV_4 16
#define MATH_64_DIV_2 32
#define MATH_64_DIV_1 64
#define     MATH_32_DIV_32 1
#define     MATH_32_DIV_16 2
#define     MATH_32_DIV_8 4
#define     MATH_32_DIV_4 8
#define     MATH_32_DIV_2 16
#define     MATH_32_DIV_1 32
#define MATH_16_DIV_16 1
#define MATH_16_DIV_8 2
#define MATH_16_DIV_4 4
#define MATH_16_DIV_2 8
#define MATH_16_DIV_1 16
#define     MATH_8_DIV_8 1
#define     MATH_8_DIV_4 2
#define     MATH_8_DIV_2 4
#define     MATH_8_DIV_1 8
#define     MATH_7_DIV_1 7
#define     MATH_6_DIV_1 6
#define     MATH_5_DIV_1 5
#define MATH_4_DIV_4 1
#define MATH_4_DIV_2 2
#define MATH_4_DIV_1 4
#define MATH_3_DIV_1 3
#define     MATH_2_DIV_2 1
#define     MATH_2_DIV_1 2
#define MATH_1_DIV_1 1
#define MATH_DIV__(a, b) MATH_##a##_DIV_##b
#define MATH_DIV(a, b) MATH_DIV__(a, b)

// Math multiplication macros
#define MATH_32_MUL_2 64
#define MATH_32_MUL_1 32
#define     MATH_16_MUL_4 64
#define     MATH_16_MUL_2 32
#define     MATH_16_MUL_1 16
#define MATH_8_MUL_4 32
#define MATH_8_MUL_2 16
#define MATH_8_MUL_1 8
#define     MATH_4_MUL_4 16
#define     MATH_4_MUL_2 8
#define     MATH_4_MUL_1 4
#define MATH_2_MUL_2 4
#define MATH_2_MUL_1 2
#define     MATH_1_MUL_2 2
#define     MATH_1_MUL_1 1
#define MATH_MUL__(a, b) MATH_##a##_MUL_##b
#define MATH_MUL(a, b) MATH_MUL__(a, b)

// Bitwidth of types
#define BITWIDTH_char  8
#define BITWIDTH_short 16
#define BITWIDTH_int   32
#define BITWIDTH_long  64
#define BITWIDTH_uchar  8
#define BITWIDTH_ushort 16
#define BITWIDTH_uint   32
#define BITWIDTH_ulong  64
#define BITWIDTH__(type) BITWIDTH_##type
#define BITWIDTH(type) BITWIDTH__(type)

// converts VNNI dimentions to original
// H stands for Height, W stands for Width, VF stands for VNNI Factor
#define H_VNNI_TO_ORIG_PackedA_RowMajor(H, VF)          H
#define H_VNNI_TO_ORIG_PackedA_ColumnMajor(H, VF)       H
#define H_VNNI_TO_ORIG_PackedB_RowMajor(H, VF)          MATH_MUL(H, VF)
#define H_VNNI_TO_ORIG_PackedB_ColumnMajor(H, VF)       MATH_MUL(H, VF)
#define H_VNNI_TO_ORIG_PackedB_PackedB(H, VF)           MATH_MUL(H, VF)
#define H_VNNI_TO_ORIG_Accumulator_RowMajor(H, VF)      H
#define H_VNNI_TO_ORIG_Accumulator_ColumnMajor(H, VF)   H
#define H_VNNI_TO_ORIG(layout, H, VF) H_VNNI_TO_ORIG_##layout(H, VF)

#define W_VNNI_TO_ORIG_PackedA_RowMajor(W, VF)          W
#define W_VNNI_TO_ORIG_PackedA_ColumnMajor(W, VF)       W
#define W_VNNI_TO_ORIG_PackedB_RowMajor(W, VF)          MATH_DIV(W, VF)
#define W_VNNI_TO_ORIG_PackedB_ColumnMajor(W, VF)       MATH_DIV(W, VF)
#define W_VNNI_TO_ORIG_PackedB_PackedB(W, VF)           MATH_DIV(W, VF)
#define W_VNNI_TO_ORIG_Accumulator_RowMajor(W, VF)      W
#define W_VNNI_TO_ORIG_Accumulator_ColumnMajor(W, VF)   W
#define W_VNNI_TO_ORIG(layout, W, VF) W_VNNI_TO_ORIG_##layout(W, VF)

// Shape MxK macros - shape is a part of final builtin's name.
// There is special logic for vnni builtins: (M * vnni_factor)x(K / vnni_factor)
#define SHAPE_CONCAT(M, K) M##x##K
#define SHAPE___(M, K) SHAPE_CONCAT(M, K)
#define SHAPE__(layout, M, K, VF) SHAPE___(H_VNNI_TO_ORIG(layout, M, VF), W_VNNI_TO_ORIG(layout, K, VF))
#define SHAPE_(layout, M, K, elem_bitwidth, contrib_bitwidth) SHAPE__(layout, M, K, MATH_DIV(contrib_bitwidth, elem_bitwidth))
#define SHAPE(layout, M, K, element_type, contrib_type) SHAPE_(layout, M, K, BITWIDTH(element_type), BITWIDTH(contrib_type))

/* Explanation of calculation for row_stride and column_stride in DEFINE_LOAD_LARGE and DEFINE_STORE_LARGE.
PackedA_RowMajor 16x16, sub_group_size=16, using 2 stores example:
Each subgroup stores 2 of 8x16 slices. Hence, row_stride (# of rows between consecutive stores) = R / 2 = 16 / 2 = 8
and column_stride (# of columns between consecutive stores) = C = 16. */
#define ROW_STRIDE_PackedA_RowMajor_2(R, C)        MATH_DIV(R, 2)
#define ROW_STRIDE_Accumulator_RowMajor_2(R, C)    MATH_DIV(R, 2)
#define COLUMN_STRIDE_PackedA_RowMajor_2(R, C)     C
#define COLUMN_STRIDE_Accumulator_RowMajor_2(R, C) C

/* PackedA_RowMajor 32x16, sub_group_size=8, using 4 stores example:
Each subgroup stores 4 of 8x16 slices. Hence, row_stride = R / 4 = 32 / 4 = 8 and column_stride = C = 16. */
#define ROW_STRIDE_PackedA_RowMajor_4(R, C)  MATH_DIV(R, 4)
#define COLUMN_STRIDE_PackedA_RowMajor_4(R, C)  C

// PackedA_RowMajor 32x32, sub_group_size=16, using 8 stores.
#define ROW_STRIDE_PackedA_RowMajor_8(R, C)  MATH_DIV(R, 4)
#define COLUMN_STRIDE_PackedA_RowMajor_8(R, C)  MATH_DIV(C, 2)

/* PackedB_PackedB, 8x64 (orig shape: 16x32), sub_group_size=8, using 4 stores example:
Subgroup stores 4 of 8x16 slices. Hence, row_stride = R = 8 and column_stride = C / 4 = 64 / 4 = 16. */
#define ROW_STRIDE_PackedB_PackedB_4(R, C) R
#define COLUMN_STRIDE_PackedB_PackedB_4(R, C)  MATH_DIV(C, 4)

/* PackedB_RowMajor, 16x32 (VNNI shape 8x64), sub_group_size=8, using 4 stores example.
Each subgroup stores 4 of 16x8 slices. Since the shape for matrix B is in VNNI format on device, we store 16 x 8 slice as 8x16.
Hence, row_stride = R (VNNI'ed) = 8 and column_stride = C (VNNI'ed) / 4 = 64 / 4 = 16. */
#define ROW_STRIDE_PackedB_RowMajor_4(R, C) R
#define COLUMN_STRIDE_PackedB_RowMajor_4(R, C)  MATH_DIV(C, 4)

/* PackedB_PackedB, d16 R=16, C=128 (orig shape: d16 32x64), sub_group_size=16, using 8 stores:
1 store opeartion handles d32 8x16 (d16 8x32). Hence, row_stride = R /2 = 8 and column_stride = C / 4 = 128 / 4 = 32. */
#define ROW_STRIDE_PackedB_PackedB_8(R, C) MATH_DIV(R, 2)
#define COLUMN_STRIDE_PackedB_PackedB_8(R, C)  MATH_DIV(C, 4)
#define ROW_STRIDE_PackedB_RowMajor_8(R, C) MATH_DIV(R, 2)
#define COLUMN_STRIDE_PackedB_RowMajor_8(R, C)  MATH_DIV(C, 4)

/* Accumulator_RowMajor 32x32, sub_group_size=8, using 4 stores example:
Each subgroup stores 4 of 32x8 slices. Hence, row_stride = R = 32 and column_stride = C / 4 = 32 / 4 = 8. */
#define ROW_STRIDE_Accumulator_RowMajor_4(R, C) R
#define COLUMN_STRIDE_Accumulator_RowMajor_4(R, C) MATH_DIV(C, 4)

/* Accumulator_RowMajor 32x64 sub_group_size=16, using 16 stores example:
Each subgroup stores 16 of 8x16 slices. Hence, row_stride = R / 4 = 32 / 4 = 8 and column_stride = C / 4 = 64 / 4 = 16. */
#define ROW_STRIDE_Accumulator_RowMajor_16(R, C) MATH_DIV(R, 4)
#define COLUMN_STRIDE_Accumulator_RowMajor_16(R, C) MATH_DIV(C, 4)

// The number of rows between successive load/store operations depending on layouts and number of loads/stores.
// This is used to calculate the row_stride in DEFINE_LOAD_LARGE and DEFINE_STORE_LARGE.
#define ROW_STRIDE(layout, R, C, num_ops) ROW_STRIDE_##layout##_##num_ops(R, C)

// The number of columns between successive load/store operations depending on layouts and number of loads/stores.
// This is used to calculate the column_stride in DEFINE_LOAD_LARGE and DEFINE_STORE_LARGE.
#define COLUMN_STRIDE(layout, R, C, num_ops) COLUMN_STRIDE_##layout##_##num_ops(R, C)

/* MEM_OFFSET calculates the memory offset, used in big shapes implementation*/
// Calculates memory offset for multiple loads/stores, where row_stride and column_stride are shape of one store
// and S is stride in units equal to row_stride or column_stride, depending on order in which small matrices are
// loaded/stored as big matrix.
// For example, if matrix has shape 32x32 and is being stored using 8 stores 8x16 in that col-major order:
// 0, 4 <-- each number is matrix 8x16 and index.
// 1, 5
// 2, 6
// 3, 7
// then parameters would be:
// row_stride = 8, column_stride = 16, S = 4
// I is index
#define MEM_OFFSET_COLMAJ(row_stride, column_stride, S, I) \
    (((I) % (S)) * (row_stride) * stride + ((I) / (S)) * (column_stride))
#define MEM_OFFSET_ROWMAJ(row_stride, column_stride, S, I) \
    (((I) / (S)) * (row_stride) * stride + ((I) % (S)) * (column_stride))

// PackedA_RowMajor is split into 4 slices row-wise. Host memory location increments by row_stride * stride.
#define MEM_OFFSET4_PackedA_RowMajor(row_stride, column_stride, I) MEM_OFFSET_COLMAJ(row_stride, column_stride, 4, I)

// Split into 4 slices col-wise. Host memory location increments by column_stride.
#define MEM_OFFSET4_PackedB_PackedB(row_stride, column_stride, I) MEM_OFFSET_ROWMAJ(row_stride, column_stride, 4, I)
#define MEM_OFFSET4_Accumulator_RowMajor(row_stride, column_stride, I) MEM_OFFSET_ROWMAJ(row_stride, column_stride, 4, I)

// PackedB_RowMajor is split into 4 slices col-wise. Host memory location increments by column_stride converted to original shape.
#define MEM_OFFSET4_PackedB_RowMajor(row_stride, column_stride, I) MEM_OFFSET_ROWMAJ(row_stride, MATH_DIV(column_stride, 2), 4, I)

#define MEM_OFFSET8_PackedA_RowMajor(row_stride, column_stride, I) MEM_OFFSET_COLMAJ(row_stride, column_stride, 4, I)
#define MEM_OFFSET8_PackedB_PackedB(row_stride, column_stride, I) MEM_OFFSET_COLMAJ(row_stride, column_stride, 2, I)
#define MEM_OFFSET8_PackedB_RowMajor(row_stride, column_stride, I) MEM_OFFSET_COLMAJ(MATH_MUL(row_stride, 2), MATH_DIV(column_stride, 2), 2, I)

// layout can be PackedA_RowMajor, PackedB_ColumnMajor, PackedB_PackedB, etc.
// sg is empty for XMX8 and _SG16 for PVC
// elem_bitwidth is 8, 16 or 32
// shape is shape of the matrix, like 8x16 (MxK). There is special logic for vnni shapes
// WI_rows is the number of rows owned by each WI, which can be different from M e.g. for tf32
#define MANGLE_LOAD_NAME_AS_GENERIC(layout, sg, elem_bitwidth, shape, WI_rows) \
  __builtin_spriv_OpJointMatrixLoadINTEL_##layout##sg##_##shape##_i##elem_bitwidth##_##WI_rows##_generic_v8i8_pi32_i32

#define MANGLE_LOAD_NAME_AS_LOCAL(layout, sg, elem_bitwidth, shape, WI_rows) \
  __builtin_spriv_OpJointMatrixLoadINTEL_##layout##sg##_##shape##_i##elem_bitwidth##_##WI_rows##_local_v8i8_pi32_i32

#define MANGLE_LOAD_NAME_AS_GLOBAL(layout, sg, elem_bitwidth, shape, WI_rows) \
  __builtin_spriv_OpJointMatrixLoadINTEL_##layout##sg##_##shape##_i##elem_bitwidth##_##WI_rows##_global_v8i8_pi32_i32

#define MANGLE_LOAD_CHECKED_NAME(layout, sg, elem_bitwidth, shape, WI_rows) \
  __builtin_spriv_OpJointMatrixLoadCheckedINTEL_##layout##sg##_##shape##_i##elem_bitwidth##_##WI_rows##_v8i8_pi32_i32

#define MANGLE_PREFETCH_NAME(sg, elem_bitwidth, shape) \
  __builtin_spriv_OpJointMatrixPrefetchINTEL##sg##_##shape##_i##elem_bitwidth

#define SUB_GROUP_LOAD(readop, M, WI_rows, src, dst, stride, contrib_type) \
    __private contrib_type *wi_contrib = (__private contrib_type *)dst; \
    int ratio = WI_rows / M; \
    for (int i = 0; i < WI_rows; i++) \
        wi_contrib[i] = readop(src + (i/ratio)*stride + (i%ratio)*sg_size);

#define SUB_GROUP_LOAD_PACK_32(M, src, dst, stride) \
    /* empty */

#define SUB_GROUP_LOAD_PACK_16(M, src, dst, stride) \
    __private int *wi_contrib = (__private int *)dst; \
    for (int i = 0; i < M; i++) { \
      ushort row0 = intel_sub_group_block_read_us((src) + 2 * i * (stride)); \
      ushort row1 = intel_sub_group_block_read_us((src) + (2 * i + 1) * (stride)); \
      wi_contrib[i] = as_int((ushort2)(row0, row1)); \
    }

#define SUB_GROUP_LOAD_PACK_8(M, src, dst, stride) \
    __private int *wi_contrib = (__private int *)dst; \
    for (int i = 0; i < M; i++) { \
      uchar row0 = intel_sub_group_block_read_uc((src) + 4 * i * (stride)); \
      uchar row1 = intel_sub_group_block_read_uc((src) + (4 * i + 1) * (stride)); \
      uchar row2 = intel_sub_group_block_read_uc((src) + (4 * i + 2) * (stride)); \
      uchar row3 = intel_sub_group_block_read_uc((src) + (4 * i + 3) * (stride)); \
      wi_contrib[i] = as_int((uchar4)(row0, row1, row2, row3)); \
    }

#define GATHER_LOAD_PACK_32(element_type, M, dst, slid, stride) \
    /* empty */

#define GATHER_LOAD_PACK_16(element_type, M, dst, slid, stride) \
    element_type *src = (element_type *)mem; \
    for (int i = 0; i < M; i++) { \
      ushort row0 = src[(2 * i + 0) * stride + slid]; \
      ushort row1 = src[(2 * i + 1) * stride + slid]; \
      dst[i] = as_int((ushort2)(row0, row1)); \
    }

#define GATHER_LOAD_PACK_8(element_type, M, dst, slid, stride) \
    element_type *src = (element_type *)mem; \
    for (int i = 0; i < M; i++) { \
      uchar row0 = src[(4 * i + 0) * stride + slid]; \
      uchar row1 = src[(4 * i + 1) * stride + slid]; \
      uchar row2 = src[(4 * i + 2) * stride + slid]; \
      uchar row3 = src[(4 * i + 3) * stride + slid]; \
      dst[i] = as_int((uchar4)(row0, row1, row2, row3)); \
    }

// variants for 32, 16, 7, 6, 5, 3 and 1 are only used to make the code compilable
#define DEFINE_BLOCK_RW_NAME32(rw, us) intel_sub_group_block_##rw##us##32
#define DEFINE_BLOCK_RW_NAME16(rw, us) intel_sub_group_block_##rw##us##16
#define DEFINE_BLOCK_RW_NAME8(rw, us) intel_sub_group_block_##rw##us##8
#define DEFINE_BLOCK_RW_NAME7(rw, us) intel_sub_group_block_##rw##us##8
#define DEFINE_BLOCK_RW_NAME6(rw, us) intel_sub_group_block_##rw##us##8
#define DEFINE_BLOCK_RW_NAME5(rw, us) intel_sub_group_block_##rw##us##8
#define DEFINE_BLOCK_RW_NAME4(rw, us) intel_sub_group_block_##rw##us##4
#define DEFINE_BLOCK_RW_NAME3(rw, us) intel_sub_group_block_##rw##us##4
#define DEFINE_BLOCK_RW_NAME2(rw, us) intel_sub_group_block_##rw##us##2
#define DEFINE_BLOCK_RW_NAME1(rw, us) intel_sub_group_block_##rw##us

#define DEFINE_BLOCK2D_RW_NAME(rw, tx, contrib_bitwidth, WI_rows, tile_height, tile_width) __builtin_IB_subgroup_block_##rw##_flat_cacheopts##tx##_u##contrib_bitwidth##_wi##WI_rows##_m##tile_height##k##tile_width##v1
#define DEFINE_BLOCK2D_TRANSPOSE_NAME(contrib_bitwidth, WI_rows, tile_height, tile_width) __builtin_IB_subgroup_block_read_flat_cacheopts_transpose_u##contrib_bitwidth##_wi##WI_rows##_m##tile_height##_k##tile_width
#define DEFINE_BLOCK2D_VNNI_NAME(contrib_bitwidth, WI_rows, tile_height, tile_width) __builtin_IB_subgroup_block_read_flat_cacheopts_transform_u##contrib_bitwidth##_wi##WI_rows##_##k##tile_height##n##tile_width

/* For platforms without SG16 JointMatrix support block2d is not available. The
 * implementation remains empty, will fallthrough to vector implementation. */
#define IMPLEMENT_BLOCK2D_LOAD_ROW_MAJOR_PackedA_RowMajor(p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12)
#define IMPLEMENT_BLOCK2D_LOAD_COL_MAJOR_PackedA_ColumnMajor(p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12)

#define IMPLEMENT_BLOCK2D_LOAD_ROW_MAJOR_PackedB_PackedB(p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12)
#define IMPLEMENT_BLOCK2D_LOAD_VNNI_TX_PackedB_RowMajor(p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12)
#define IMPLEMENT_BLOCK2D_LOAD_ROW_MAJOR_PackedB_RowMajor(p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12)
#define IMPLEMENT_BLOCK2D_LOAD_COL_MAJOR_PackedB_ColumnMajor(p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12)

#define IMPLEMENT_BLOCK2D_LOAD_ROW_MAJOR_Accumulator_RowMajor(p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12)
#define IMPLEMENT_BLOCK2D_LOAD_COL_MAJOR_Accumulator_ColumnMajor(p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12)

#define IMPLEMENT_BLOCK2D_STORE(p1, p2, p3, p4, p5, p6, p7, p8)

// contrib_K - calculated in BLOCK2D loads; contrib_K = K/(contrib_bitwidth/elem_bitwidth);
//     Since contrib_type might be larger than element_type.
//     To load a proper ammout per WI we need to contrib_K that's derived from K but it's smaller for some configurations.

#define MAX_ROW_BYTES_2D_BLOCK_LOAD 64 // maximum per row size in bytes supported by 2D block load

// M and K are the original tile dimensions for A and C.
// M and K are the VNNI-ed dimensions for matrix B (hence the are also aliased as M_VNNI and K_VNNI in some places)
// Hence, we also have orig_M and orig_K, which can be used as non-VNNI'ed M/K dimensions of matrix B
// orig_M == M and orig_K == K for A and C
// When smaller elements are packed into bigger types, contrib_K represents K dimension of the packed matrix
// contrib_M is a special case, used only in IMPLEMENT_BLOCK2D_LOAD_SG16_COL_MAJOR_PackedA_ColumnMajor.
// It is special, because it is always using `int` as a contrib type for load messages, while contrib type
// used in LLVM IR and by dpas is still `short`
#define IMPLEMENT_BLOCK2D_LOAD_SG16_ROW_MAJOR(element_type, contrib_type, contrib_bitwidth, M, K, WI_rows, contrib_K) \
  if (contrib_K*sizeof(contrib_type) <= MAX_ROW_BYTES_2D_BLOCK_LOAD) { /* For 2D loads (block2d width)*(data size) must be <= MAX_ROW_BYTES_2D_BLOCK_LOAD */ \
    long offset = as_long(mem); \
    long baseoffset = offset & (~0x3f); /* align to 64-byte */ \
    int width = (sizeof (element_type)) * stride - 1; /* in bytes */ \
    int pitch = width; /* JointMatrices are expected to be contiguous in memory, without padding at the end of a row */ \
    int height = M - 1; /* row count */ \
    long x = (offset - baseoffset) / (sizeof (contrib_type)); /* in elements */ \
    int2 coords = (int2)(x, 0); \
    OUT_VEC##WI_rows(u##contrib_type) DEFINE_BLOCK2D_RW_NAME(read, , contrib_bitwidth, WI_rows, M, contrib_K)(long, int, int, int, int2, int); \
    OUT_VEC##WI_rows(u##contrib_type) res = DEFINE_BLOCK2D_RW_NAME(read, , contrib_bitwidth, WI_rows, M, contrib_K)(baseoffset, width, height, pitch, coords, cacheOpt); \
    *(__private OUT_VEC##WI_rows(u##contrib_type) *)dst = res; \
    return; \
  }

#define IMPLEMENT_BLOCK2D_LOAD_SG16_ROW_MAJOR_PackedA_RowMajor(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  IMPLEMENT_BLOCK2D_LOAD_SG16_ROW_MAJOR(element_type, contrib_type, contrib_bitwidth, M, K, WI_rows, contrib_K)
#define IMPLEMENT_BLOCK2D_LOAD_SG16_ROW_MAJOR_PackedB_PackedB(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  IMPLEMENT_BLOCK2D_LOAD_SG16_ROW_MAJOR(element_type, contrib_type, contrib_bitwidth, M, K, WI_rows, contrib_K)
#define IMPLEMENT_BLOCK2D_LOAD_SG16_ROW_MAJOR_PackedB_RowMajor(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  IMPLEMENT_BLOCK2D_LOAD_SG16_ROW_MAJOR(element_type, contrib_type, contrib_bitwidth, M, K, WI_rows, contrib_K)
#define IMPLEMENT_BLOCK2D_LOAD_SG16_ROW_MAJOR_Accumulator_RowMajor(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  IMPLEMENT_BLOCK2D_LOAD_SG16_ROW_MAJOR(element_type, contrib_type, contrib_bitwidth, M, K, WI_rows, contrib_K)

// 2D block read transpose builtin requires K value _after_ the transpose operation is done - which is equal to M before the transpose
#define IMPLEMENT_BLOCK2D_LOAD_SG16_COL_MAJOR(element_type, contrib_type, contrib_bitwidth, M, K, WI_rows, orig_M, orig_K) \
  if (M*sizeof(element_type) <= MAX_ROW_BYTES_2D_BLOCK_LOAD) { /* For 2D loads (block2d width)*(data size) must be <= MAX_ROW_BYTES_2D_BLOCK_LOAD */ \
    long offset = as_long(mem); \
    long baseoffset = offset & (~0x3f); /* align to 64-byte */ \
    int width = (sizeof (element_type)) * stride - 1; /* in bytes */ \
    int pitch = width; /* JointMatrices are expected to be contiguous in memory, without padding at the end of a row */ \
    int height = orig_K - 1; \
    long x = (offset - baseoffset) / (sizeof (contrib_type)); /* in elements */ \
    int2 coords = (int2)(x, 0); \
\
    OUT_VEC##WI_rows(u##contrib_type) DEFINE_BLOCK2D_TRANSPOSE_NAME(contrib_bitwidth, WI_rows, orig_K, M)(long, int, int, int, int2, int); \
    OUT_VEC##WI_rows(u##contrib_type) res = DEFINE_BLOCK2D_TRANSPOSE_NAME(contrib_bitwidth, WI_rows, orig_K, M)(baseoffset, width, height, pitch, coords, cacheOpt); \
    *(__private OUT_VEC##WI_rows(u##contrib_type) *)dst = *(__private OUT_VEC##WI_rows(u##contrib_type) *)&res; \
    return; \
  }

#define IMPLEMENT_BLOCK2D_LOAD_SG16_COL_MAJOR_PackedB_ColumnMajor(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  IMPLEMENT_BLOCK2D_LOAD_SG16_COL_MAJOR(element_type, contrib_type, contrib_bitwidth, M, K, WI_rows, orig_M, orig_K)
#define IMPLEMENT_BLOCK2D_LOAD_SG16_COL_MAJOR_Accumulator_ColumnMajor(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  IMPLEMENT_BLOCK2D_LOAD_SG16_COL_MAJOR(element_type, contrib_type, contrib_bitwidth, M, K, WI_rows, orig_M, orig_K)

#define HELPER_PACKEDA_COL_MAJOR_SHUFFLE(contrib_type, elem_bitwidth, M, K, WI_rows) \
    int slid = get_sub_group_local_id(); \
    int pack_factor = 2; /* either sizeof(short)/sizeof(char) or sizeof(int)/sizeof(short) */ \
\
    if(elem_bitwidth == 16) { \
      if (M == WI_rows) { \
        *(__private OUT_VEC##WI_rows(u##contrib_type) *)dst = *(__private OUT_VEC##WI_rows(u##contrib_type) *)&res; \
        return; \
      } \
      /*Sub-group size = 32 support: */ \
      short4 *data = (short4*)&res; \
      short4 tdata; \
      for (int i = 0; i < WI_rows; i++) { \
        int from_slid = slid % K + (i % pack_factor) * K; \
        short tmp0 = sub_group_shuffle((*data)[(i / pack_factor) * pack_factor], from_slid); \
        short tmp1 = sub_group_shuffle((*data)[(i / pack_factor) * pack_factor + 1], from_slid); \
        tdata[i] = slid < (sg_size / pack_factor) ? tmp0 : tmp1; \
      } \
      *(__private OUT_VEC##WI_rows(u##contrib_type) *)dst = *(__private OUT_VEC##WI_rows(u##contrib_type) *)&tdata; \
      return; \
    } \
    if (elem_bitwidth == 8) { \
      if (M == WI_rows) { \
        char16 *data = (char16*)&res; \
        char16 tdata; \
        for (int i = 0; i < 16; i++) { \
          int from_slid = (slid * pack_factor) % sg_size + i % pack_factor; \
          char tmp0 = sub_group_shuffle((*data)[(i / pack_factor) + (i / (load_pack_factor * pack_factor)) * load_pack_factor], from_slid); \
          char tmp1 = sub_group_shuffle((*data)[(i / pack_factor) + (i / (load_pack_factor * pack_factor) + 1) * load_pack_factor], from_slid); \
          tdata[i] = slid < (sg_size / pack_factor) ? tmp0 : tmp1; \
        } \
        *(__private OUT_VEC##WI_rows(u##contrib_type) *)dst = *(__private OUT_VEC##WI_rows(u##contrib_type) *)&tdata; \
        return; \
      } \
      /*Sub-group size = 32 support: */ \
      char8 *data = (char8*)&res; \
      char8 tdata; \
      for (int i = 0; i < 8; i++) { \
          int from_slid = (slid * pack_factor) % sg_size + i % pack_factor; \
          char tmp0 = sub_group_shuffle((*data)[(i / pack_factor) * pack_factor], from_slid); \
          char tmp1 = sub_group_shuffle((*data)[(i / pack_factor) * pack_factor + 1], from_slid); \
          tdata[i] = slid < (sg_size / pack_factor) ? tmp0 : tmp1; \
      } \
      *(__private OUT_VEC##WI_rows(u##contrib_type) *)dst = *(__private OUT_VEC##WI_rows(u##contrib_type) *)&tdata; \
      return; \
    }

// ret_num is used only for this load implementation. It is the number of elements in the return vector from block2d call.
// In other cases it is equal to WI_rows but in this case, because we use 32-bit data size to load data,
// while "contrib type" is still 16-bit, we need to use different return type.
#define IMPLEMENT_BLOCK2D_LOAD_SG16_COL_MAJOR_PackedA_ColumnMajor(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  if (M*sizeof(element_type) <= MAX_ROW_BYTES_2D_BLOCK_LOAD) { /* For 2D loads (block2d width)*(data size) must be <= MAX_ROW_BYTES_2D_BLOCK_LOAD */ \
    long offset = as_long(mem); \
    long baseoffset = offset & (~0x3f); /* align to 64-byte */ \
    int width = (sizeof (element_type)) * stride - 1; /* in bytes */ \
    int pitch = width; /* JointMatrices are expected to be contiguous in memory, without padding at the end of a row */ \
    int height = K - 1; \
    long x = (offset - baseoffset) / (sizeof(int)); /* in elements */ \
    int2 coords = (int2)(x, 0); \
\
    OUT_VEC##ret_num(uint) DEFINE_BLOCK2D_TRANSPOSE_NAME(32, ret_num, K, contrib_M)(long, int, int, int, int2, int); \
    OUT_VEC##ret_num(uint) res = DEFINE_BLOCK2D_TRANSPOSE_NAME(32, ret_num, K, contrib_M)(baseoffset, width, height, pitch, coords, cacheOpt); \
    int load_pack_factor = sizeof(int) / sizeof(element_type); \
    HELPER_PACKEDA_COL_MAJOR_SHUFFLE(contrib_type, elem_bitwidth, M, K, WI_rows) \
  }

#define IMPLEMENT_BLOCK2D_LOAD_SG16_VNNI_TX_PackedB_RowMajor(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M_VNNI, K_VNNI, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  if (contrib_K*sizeof(element_type) <= MAX_ROW_BYTES_2D_BLOCK_LOAD) { /* For 2D loads (block2d width)*(data size) must be <= MAX_ROW_BYTES_2D_BLOCK_LOAD */ \
    long offset = as_long(mem); \
    long baseoffset = offset & (~0x3f); /* align to 64-byte */ \
    int width = (sizeof (element_type)) * stride - 1; /* in bytes */ \
    int pitch = width; /* JointMatrices are expected to be contiguous in memory, without padding at the end of a row */ \
    int height = orig_M - 1; /* row count */ \
    long x = (offset - baseoffset) / (sizeof (element_type)); /* in elements */ \
    int2 coords = (int2)(x, 0); \
    OUT_VEC##WI_rows(u##contrib_type) DEFINE_BLOCK2D_VNNI_NAME(elem_bitwidth, WI_rows, orig_M, orig_K)(long, int, int, int, int2, int); \
    OUT_VEC##WI_rows(u##contrib_type) res = DEFINE_BLOCK2D_VNNI_NAME(elem_bitwidth, WI_rows, orig_M, orig_K)(baseoffset, width, height, pitch, coords, cacheOpt); \
    *(__private OUT_VEC##WI_rows(u##contrib_type) *)dst = res; \
    return; \
  }

#define IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_ROW_MAJOR(element_type, contrib_type, contrib_bitwidth, M, K, WI_rows, contrib_K) \
  long offset = as_long(mem); \
  int width_size = sizeof (element_type) * width - 1; /* in bytes */ \
  int pitch = sizeof (element_type) * stride - 1; /* in bytes */ \
  int height_size = height - 1; \
  int pack_factor = sizeof (contrib_type) / sizeof (element_type); \
  int2 coords = (int2)(x / pack_factor, y); \
  OUT_VEC##WI_rows(u##contrib_type) DEFINE_BLOCK2D_RW_NAME(read, , contrib_bitwidth, WI_rows, M, contrib_K)(long, int, int, int, int2, int); \
  OUT_VEC##WI_rows(u##contrib_type) res = DEFINE_BLOCK2D_RW_NAME(read, , contrib_bitwidth, WI_rows, M, contrib_K)(offset, width_size, height_size, pitch, coords, cacheOpt); \
  *(__private OUT_VEC##WI_rows(u##contrib_type) *)dst = res; \
  return;

#define IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_ROW_MAJOR_PackedA_RowMajor(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_ROW_MAJOR(element_type, contrib_type, contrib_bitwidth, M, K, WI_rows, contrib_K)
#define IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_ROW_MAJOR_PackedB_PackedB(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_ROW_MAJOR(element_type, contrib_type, contrib_bitwidth, M, K, WI_rows, contrib_K)
#define IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_ROW_MAJOR_PackedB_RowMajor(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_ROW_MAJOR(element_type, contrib_type, contrib_bitwidth, M, K, WI_rows, contrib_K)
#define IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_ROW_MAJOR_Accumulator_RowMajor(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_ROW_MAJOR(element_type, contrib_type, contrib_bitwidth, M, K, WI_rows, contrib_K)

#define IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_COL_MAJOR_PackedA_ColumnMajor(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  long offset = as_long(mem); \
  int width_size = sizeof (element_type) * width - 1; /* in bytes */ \
  int pitch = sizeof (element_type) * stride - 1; /* in bytes */ \
  int height_size = height - 1; \
  int load_pack_factor = sizeof (int) / sizeof (element_type); \
  int2 coords = (int2)(x/load_pack_factor, y); \
  /* 2D block read transpose builtin requires K value _after_ the transpose operation is done - which is equal to M before the transpose */ \
  OUT_VEC##ret_num(uint) DEFINE_BLOCK2D_TRANSPOSE_NAME(32, ret_num, K, contrib_M)(long, int, int, int, int2, int); \
  OUT_VEC##ret_num(uint) res = DEFINE_BLOCK2D_TRANSPOSE_NAME(32, ret_num, K, contrib_M)(offset, width_size, height_size, pitch, coords, cacheOpt); \
  int sg_size = get_sub_group_size(); \
  HELPER_PACKEDA_COL_MAJOR_SHUFFLE(contrib_type, elem_bitwidth, M, K, WI_rows)

#define IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_COL_MAJOR(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, orig_M, orig_K) \
  long offset = as_long(mem); \
  int width_size = sizeof (element_type) * width - 1; /* in bytes */ \
  int pitch = sizeof (element_type) * stride - 1; /* in bytes */ \
  int height_size = height - 1; \
  int pack_factor = sizeof (contrib_type) / sizeof (element_type); \
  int2 coords = (int2)(x/pack_factor, y); \
  /* 2D block read transpose builtin requires K value _after_ the transpose operation is done - which is equal to M before the transpose */ \
  OUT_VEC##WI_rows(u##contrib_type) DEFINE_BLOCK2D_TRANSPOSE_NAME(contrib_bitwidth, WI_rows, orig_K, M)(long, int, int, int, int2, int); \
  OUT_VEC##WI_rows(u##contrib_type) res = DEFINE_BLOCK2D_TRANSPOSE_NAME(contrib_bitwidth, WI_rows, orig_K, M)(offset, width_size, height_size, pitch, coords, cacheOpt); \
  *(__private OUT_VEC##WI_rows(u##contrib_type) *)dst = *(__private OUT_VEC##WI_rows(u##contrib_type) *)&res; \
  return;

#define IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_COL_MAJOR_PackedB_ColumnMajor(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_COL_MAJOR(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, orig_M, orig_K)
#define IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_COL_MAJOR_Accumulator_ColumnMajor(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_COL_MAJOR(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, orig_M, orig_K)

#define IMPLEMENT_BLOCK2D_LOAD_CHECKED_SG16_VNNI_TX_PackedB_RowMajor(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M_VNNI, K_VNNI, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  long offset = as_long(mem); \
  int width_size = sizeof (element_type) * width - 1; /* in bytes */ \
  int pitch = sizeof (element_type) * stride - 1; /* in bytes */ \
  int height_size = height - 1; \
  int2 coords = (int2)(x, y); \
  OUT_VEC##WI_rows(u##contrib_type) DEFINE_BLOCK2D_VNNI_NAME(elem_bitwidth, WI_rows, orig_M, orig_K)(long, int, int, int, int2, int); \
  OUT_VEC##WI_rows(u##contrib_type) res = DEFINE_BLOCK2D_VNNI_NAME(elem_bitwidth, WI_rows, orig_M, orig_K)(offset, width_size, height_size, pitch, coords, cacheOpt); \
  *(__private OUT_VEC##WI_rows(u##contrib_type) *)dst = res; \
  return;

#define IMPLEMENT_BLOCK2D_LOAD___(layout, checked, sg, order, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K) \
  IMPLEMENT_BLOCK2D_LOAD##checked##sg##order##layout(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, \
                                                 M, K, WI_rows, ret_num, orig_M, orig_K, contrib_M, contrib_K)

// ret_num is used only in IMPLEMENT_BLOCK2D_LOAD_SG16_COL_MAJOR_PackedA_ColumnMajor.
// It is calculated by this formula: (M/pack_factor)*(K/sg_size). We can not use sg_size, since it is resolved late.
// So instead we use this formula: (WI_rows/pack_factor)*(K/16). Assuming that WI_rows already contains information about sg_size.
// contrib_M calculate is always using 32 as contrib type bit width. It is exception for IMPLEMENT_BLOCK2D_LOAD_SG16_COL_MAJOR_PackedA_ColumnMajor
// since we always use 32-bit data type in loads for COL_MAJOR_PackedA.
#define IMPLEMENT_BLOCK2D_LOAD__(layout, checked, sg, order, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows) \
  IMPLEMENT_BLOCK2D_LOAD___(layout, checked, sg, order, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, \
                                    MATH_MUL(MATH_DIV(WI_rows, MATH_DIV(32, elem_bitwidth)), MATH_DIV(K, 16)), \
                                    H_VNNI_TO_ORIG(layout, M, MATH_DIV(contrib_bitwidth, elem_bitwidth)), \
                                    W_VNNI_TO_ORIG(layout, K, MATH_DIV(contrib_bitwidth, elem_bitwidth)), \
                                    MATH_DIV(M, MATH_DIV(32, elem_bitwidth)), \
                                    MATH_DIV(K, MATH_DIV(contrib_bitwidth, elem_bitwidth)))

#define IMPLEMENT_BLOCK2D_LOAD(layout, checked, sg, order, element_type, contrib_type, M, K, WI_rows) \
  IMPLEMENT_BLOCK2D_LOAD__(layout, checked, sg, order, element_type, BITWIDTH(element_type), contrib_type, BITWIDTH(contrib_type), \
                           M, K, WI_rows)

#define IMPLEMENT_BLOCK2D_STORE_SG16(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, contrib_K) \
    long offset = as_long(mem); \
    long baseoffset = offset & (~0x3f); /* align to 64-byte */ \
    int width = (sizeof (element_type)) * stride - 1; /* in bytes */ \
    int pitch = width; /* JointMatrices are expected to be contiguous in memory, without padding at the end of a row */ \
    int height = M - 1; /* row count */ \
    long x = (offset - baseoffset) / (sizeof (contrib_type)); /* in elements */ \
    int2 coords = (int2)(x, 0); \
    void DEFINE_BLOCK2D_RW_NAME(write, , contrib_bitwidth, WI_rows, M, contrib_K)(long, int, int, int, int2, OUT_VEC##WI_rows(u##contrib_type), int); \
    OUT_VEC##WI_rows(u##contrib_type) val = *(OUT_VEC##WI_rows(u##contrib_type) *)src; \
    DEFINE_BLOCK2D_RW_NAME(write, , contrib_bitwidth, WI_rows, M, contrib_K)(baseoffset, width, height, pitch, coords, val, cacheOpt); \
    return;

#define IMPLEMENT_BLOCK2D_STORE_CHECKED_SG16(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, contrib_K) \
    long offset = as_long(mem); \
    int width_size = sizeof (element_type) * width - 1; /* in bytes */ \
    int pitch = sizeof (element_type) * stride - 1; /* in bytes */ \
    int height_size = height - 1; \
    int pack_factor = sizeof (contrib_type) / sizeof (element_type); \
    int2 coords = (int2)(x / pack_factor, y); \
    void DEFINE_BLOCK2D_RW_NAME(write, , contrib_bitwidth, WI_rows, M, contrib_K)(long, int, int, int, int2, OUT_VEC##WI_rows(u##contrib_type), int); \
    OUT_VEC##WI_rows(u##contrib_type) val = *(OUT_VEC##WI_rows(u##contrib_type) *)src; \
    DEFINE_BLOCK2D_RW_NAME(write, , contrib_bitwidth, WI_rows, M, contrib_K)(offset, width_size, height_size, pitch, coords, val, cacheOpt); \
    return;

// layout can be PackedA_RowMajor, PackedB_ColumnMajor, PackedB_PackedB, etc.
// sg is empty for XMX8 and _SG16 for PVC
// element_type is char for i8, short for i16 and int for i32
// [automatic] elem_bitwidth is the bitwidth of the elem_type, expected values are 8, 16 or 32
// contrib_type is int or short depending on available OpenCL extension API
//     Following needs to be true -> (sizeof contrib_type)*(SG size) == (sizeof element_type)*K.
//     We might use contrib_type that is different to element_type to handle sizes K values
//     that aren't equal to 8 for SG8 or 16 for SG16.
// [automatic] contrib_bitwidth is the bitwidth of the contrib_type, expected values are 16 or 32
// M is number of rows
// K is number of columns
// [automatic] shape is shape of the matrix, like 8x16 (MxK). There is special logic for vnni shapes.
// order is ROW_MAJOR, COL_MAJOR, VNNI_TX
// us is empty for int contrib type and _us for short contrib type.
// WI_rows is the number of rows owned by each WI, which can be different from M e.g. for tf32
#define DEFINE_LOAD_BLOCK2D_IMPL(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows) \
    if (BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) >= BLOCK2D_IMPL && (M <= 8 || M == 16 || M == 32)) { \
        IMPLEMENT_BLOCK2D_LOAD(layout, , sg, order##_, element_type, contrib_type, M, K, WI_rows) \
    }

#define DEFINE_LOAD_CHECKED_BLOCK2D_IMPL(layout, sg, element_type, contrib_type, M, K, order, WI_rows) \
    IMPLEMENT_BLOCK2D_LOAD(layout, _CHECKED, sg, order##_, element_type, contrib_type, M, K, WI_rows)

#define DEFINE_LOAD_VECTORS_IMPL(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows, address_space) \
    if (WI_rows >= M && BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) >= VECTOR_CONT_IMPL \
        && (stride == K || (WI_rows > M && WI_rows % M == 0)) && \
        (M == 1 || M == 2 || M == 4 || M == 8 || (M == 16 && contrib_bitwidth <= 16)) && \
        order == _ROW_MAJOR \
        ) { \
        OUT_STORE_VEC##WI_rows(u##contrib_type) OVERLOADABLE DEFINE_BLOCK_RW_NAME##WI_rows(read, us)(const ATTRIBUTE_##address_space u##contrib_type *); \
        OUT_STORE_VEC##WI_rows(u##contrib_type) res = DEFINE_BLOCK_RW_NAME##WI_rows(read, us)((ATTRIBUTE_##address_space u##contrib_type *)mem); \
        *(__private OUT_VEC##WI_rows(u##contrib_type) *)dst = *(__private OUT_VEC##WI_rows(u##contrib_type) *)&res; \
        return; \
    } \
    if (WI_rows >= M && BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) >= VECTOR_IMPL && (order == _ROW_MAJOR || order == _VNNI_TX) \
        && (M != 1 || sg_size != 32) \
        ) { \
        int pack_factor = sizeof (u##contrib_type) / sizeof (element_type); \
        stride = stride / pack_factor; \
        if (WI_rows == M && order == _VNNI_TX) { /* for VNNI_TX contrib_type should be int and elem_type should be char or short */ \
            SUB_GROUP_LOAD_PACK_##elem_bitwidth(M, (ATTRIBUTE_##address_space uint *)mem, dst, stride); \
            return; \
        } \
        SUB_GROUP_LOAD(intel_sub_group_block_read##us, M, WI_rows, (ATTRIBUTE_##address_space u##contrib_type *)mem, dst, stride, contrib_type); \
        return; \
    }

#define DEFINE_LOAD_SCALAR_IMPL(layout, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, order, WI_rows) \
    int slid = get_sub_group_local_id(); \
    int pack_factor = sizeof (contrib_type) / sizeof (element_type); \
    int elem_num = (M * K) / sg_size; \
    int sg_cols = K / pack_factor; \
    int skip_factor = sg_size / sg_cols; \
    if (_##layout == _PackedA_ColumnMajor && elem_bitwidth == 8 && contrib_bitwidth == 16) { \
        for (int i = 0; i < elem_num; i++) \
            dst[i] = mem[(i % pack_factor) * stride + ((slid * pack_factor) % K) * stride + (i / pack_factor) * skip_factor + (slid * pack_factor) / K]; \
        return; \
    } \
    contrib_type *ptr = (contrib_type *)mem; \
    long packed_stride = stride / pack_factor; \
    __private contrib_type *wi_contrib = (__private contrib_type *)dst; \
    if (order == _VNNI_TX) { \
      GATHER_LOAD_PACK_##elem_bitwidth(element_type, M, wi_contrib, slid, stride) \
      return; \
    } \
    if (sg_size >= sg_cols) { \
        for (int i = 0; i < WI_rows; i++) { \
            if ( (i*skip_factor + slid/sg_cols) < M ) \
                wi_contrib[i] = ptr[IND##order(slid, packed_stride, skip_factor, i, sg_cols)]; \
            else \
                wi_contrib[i] = 0; /*last even row for matrix with odd number of rows doesn't exist*/ \
        } \
        return; \
    } \
    int ratio = WI_rows / M; \
    for (int i = 0; i < WI_rows; i++) { \
        wi_contrib[i] = ptr[(i/ratio)*stride + (i%ratio)*sg_size + slid]; \
    }

#define DEFINE_LOAD_IMPL_AS_GENERIC(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows) \
    INLINE void MANGLE_LOAD_NAME_AS_GENERIC(layout, sg, elem_bitwidth, shape, WI_rows) (__private char *dst, char *mem, long stride, int cacheOpt) { \
        int sg_size = get_sub_group_size(); \
        __builtin_assume((__global char*)mem != 0); \
        int memIsGlobal = (0 != SPIRV_BUILTIN(GenericCastToPtrExplicit, _p1i8_p4i8_i32, _ToGlobal)(__builtin_astype((mem), __generic char*), StorageWorkgroup)); \
        if (memIsGlobal) { \
            DEFINE_LOAD_BLOCK2D_IMPL(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, _##order, us, WI_rows) \
            DEFINE_LOAD_VECTORS_IMPL(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, _##order, us, WI_rows, AS_GLOBAL) \
        } else { \
            DEFINE_LOAD_VECTORS_IMPL(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, _##order, us, WI_rows, AS_LOCAL) \
        } \
        DEFINE_LOAD_SCALAR_IMPL(layout, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, _##order, WI_rows) \
    }
#define DEFINE_LOAD_IMPL_AS_LOCAL(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows) \
    INLINE void MANGLE_LOAD_NAME_AS_LOCAL(layout, sg, elem_bitwidth, shape, WI_rows) (__private char *dst, char *mem, long stride, int cacheOpt) { \
        int sg_size = get_sub_group_size(); \
        DEFINE_LOAD_VECTORS_IMPL(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, _##order, us, WI_rows, AS_LOCAL) \
        DEFINE_LOAD_SCALAR_IMPL(layout, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, _##order, WI_rows) \
    }
#define DEFINE_LOAD_IMPL_AS_GLOBAL(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows) \
    INLINE void MANGLE_LOAD_NAME_AS_GLOBAL(layout, sg, elem_bitwidth, shape, WI_rows) (__private char *dst, char *mem, long stride, int cacheOpt) { \
        int sg_size = get_sub_group_size(); \
        DEFINE_LOAD_BLOCK2D_IMPL(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, _##order, us, WI_rows) \
        DEFINE_LOAD_VECTORS_IMPL(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, _##order, us, WI_rows, AS_GLOBAL) \
        DEFINE_LOAD_SCALAR_IMPL(layout, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, _##order, WI_rows) \
    }

#define DEFINE_LOAD_CHECKED_IMPL(layout, sg, element_type, elem_bitwidth, contrib_type, M, K, shape, order, WI_rows) \
    INLINE void MANGLE_LOAD_CHECKED_NAME(layout, sg, elem_bitwidth, shape, WI_rows) (__private char *dst, char *mem, int y, int x, int height, int width, long stride, int cacheOpt) { \
        DEFINE_LOAD_CHECKED_BLOCK2D_IMPL(layout, sg, element_type, contrib_type, M, K, _##order, WI_rows) \
    }

#define DEFINE_LOAD_IMPL(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows) \
    DEFINE_LOAD_IMPL_AS_GENERIC(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows) \
    DEFINE_LOAD_IMPL_AS_LOCAL(  layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows) \
    DEFINE_LOAD_IMPL_AS_GLOBAL( layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows)

#define DEFINE_LOAD(layout, sg, element_type, contrib_type, M, K, order, us, WI_rows) \
    DEFINE_LOAD_IMPL(layout, sg, element_type, BITWIDTH(element_type), contrib_type, BITWIDTH(contrib_type), \
                     M, K, SHAPE(layout, M, K, element_type, contrib_type), order, us, WI_rows)

/* only 2D block load is supported for checked load */
#define DEFINE_LOAD_CHECKED(layout, sg, element_type, contrib_type, M, K, order, WI_rows) \
    DEFINE_LOAD_CHECKED_IMPL(layout, sg, element_type, BITWIDTH(element_type), contrib_type, \
                     M, K, SHAPE(layout, M, K, element_type, contrib_type), order, WI_rows)

// Prefetch impl
#define DEFINE_PREFETCH_IMPL(sg, element_type, elem_bitwidth, M, K, shape) \
  INLINE void MANGLE_PREFETCH_NAME(sg, elem_bitwidth, shape) (char *mem, long stride, int cacheOpt) { \
    long offset = as_long(mem); \
    long baseoffset = offset & (~0x3f); \
    int width = (sizeof (element_type)) * stride - 1; \
    int pitch = width; \
    int height = M - 1; \
    long x = (offset - baseoffset) / (sizeof (element_type)); \
    int2 coords = (int2)(x, 0); \
    void __builtin_IB_subgroup_block_read_flat_prefetch_u##elem_bitwidth##_m##M##k##K##v1(long, int, int, int, int2, int); \
    __builtin_IB_subgroup_block_read_flat_prefetch_u##elem_bitwidth##_m##M##k##K##v1(baseoffset, width, height, pitch, coords, cacheOpt); \
  }

#define DEFINE_PREFETCH__(sg, element_type, elem_bitwidth, M, K, shape) \
  DEFINE_PREFETCH_IMPL(sg, element_type, elem_bitwidth, M, K, shape)

#define DEFINE_PREFETCH(sg, element_type, M, K) \
  DEFINE_PREFETCH__(sg, element_type, BITWIDTH(element_type), M, K, SHAPE_CONCAT(M, K))

// Prefetch define all combinations
#define DEFINE_PREFETCH_GROUP_MK(M, K) \
    DEFINE_PREFETCH(_SG16, char,  M, K) \
    DEFINE_PREFETCH(_SG16, short, M, K) \
    DEFINE_PREFETCH(_SG16, int,   M, K) \
    DEFINE_PREFETCH(_SG16, long,  M, K)
#define DEFINE_PREFETCH_GROUP_K(K) \
    DEFINE_PREFETCH_GROUP_MK(1,  K) \
    DEFINE_PREFETCH_GROUP_MK(2,  K) \
    DEFINE_PREFETCH_GROUP_MK(4,  K) \
    DEFINE_PREFETCH_GROUP_MK(8,  K) \
    DEFINE_PREFETCH_GROUP_MK(16, K) \
    DEFINE_PREFETCH_GROUP_MK(32, K)
DEFINE_PREFETCH_GROUP_K(8)
DEFINE_PREFETCH_GROUP_K(16)
DEFINE_PREFETCH_GROUP_K(32)
DEFINE_PREFETCH_GROUP_K(64)

#define DEFINE_LOAD_AND_CHECKED(layout, sg, element_type, contrib_type, M, K, order, us, WI_rows) \
    DEFINE_LOAD(layout, sg, element_type, contrib_type, M, K, order, us, WI_rows) \
    DEFINE_LOAD_CHECKED(layout, sg, element_type, contrib_type, M, K, order, WI_rows)

/* PackedA load i16 */
DEFINE_LOAD(PackedA_RowMajor, , short, int, 8, 16, ROW_MAJOR, , 8)
DEFINE_LOAD(PackedA_RowMajor, , short, int, 7, 16, ROW_MAJOR, , 7)
DEFINE_LOAD(PackedA_RowMajor, , short, int, 6, 16, ROW_MAJOR, , 6)
DEFINE_LOAD(PackedA_RowMajor, , short, int, 5, 16, ROW_MAJOR, , 5)
DEFINE_LOAD(PackedA_RowMajor, , short, int, 4, 16, ROW_MAJOR, , 4)
DEFINE_LOAD(PackedA_RowMajor, , short, int, 3, 16, ROW_MAJOR, , 3)
DEFINE_LOAD(PackedA_RowMajor, , short, int, 2, 16, ROW_MAJOR, , 2)
DEFINE_LOAD(PackedA_RowMajor, , short, int, 1, 16, ROW_MAJOR, , 1)

/* PackedA load i8 */
DEFINE_LOAD(PackedA_RowMajor, , char, int, 8, 32, ROW_MAJOR, , 8)
DEFINE_LOAD(PackedA_RowMajor, , char, int, 7, 32, ROW_MAJOR, , 7)
DEFINE_LOAD(PackedA_RowMajor, , char, int, 6, 32, ROW_MAJOR, , 6)
DEFINE_LOAD(PackedA_RowMajor, , char, int, 5, 32, ROW_MAJOR, , 5)
DEFINE_LOAD(PackedA_RowMajor, , char, int, 4, 32, ROW_MAJOR, , 4)
DEFINE_LOAD(PackedA_RowMajor, , char, int, 3, 32, ROW_MAJOR, , 3)
DEFINE_LOAD(PackedA_RowMajor, , char, int, 2, 32, ROW_MAJOR, , 2)
DEFINE_LOAD(PackedA_RowMajor, , char, int, 1, 32, ROW_MAJOR, , 1)

/* PackedA load i16 SG16 */
DEFINE_LOAD_AND_CHECKED(PackedA_RowMajor, _SG16, short, short, 8, 16, ROW_MAJOR, _us, 8)
DEFINE_LOAD(PackedA_RowMajor, _SG16, short, short, 7, 16, ROW_MAJOR, _us, 7)
DEFINE_LOAD(PackedA_RowMajor, _SG16, short, short, 6, 16, ROW_MAJOR, _us, 6)
DEFINE_LOAD(PackedA_RowMajor, _SG16, short, short, 5, 16, ROW_MAJOR, _us, 5)
DEFINE_LOAD_AND_CHECKED(PackedA_RowMajor, _SG16, short, short, 4, 16, ROW_MAJOR, _us, 4)
DEFINE_LOAD(PackedA_RowMajor, _SG16, short, short, 3, 16, ROW_MAJOR, _us, 3)
DEFINE_LOAD_AND_CHECKED(PackedA_RowMajor, _SG16, short, short, 2, 16, ROW_MAJOR, _us, 2)
DEFINE_LOAD_AND_CHECKED(PackedA_RowMajor, _SG16, short, short, 1, 16, ROW_MAJOR, _us, 1)

DEFINE_LOAD_AND_CHECKED(PackedA_RowMajor, _SG16, short, short, 1, 32, ROW_MAJOR, _us, 2)

/* PackedA load i16 SG16 Col Major */
DEFINE_LOAD_AND_CHECKED(PackedA_ColumnMajor, _SG16, short, short, 8, 16, COL_MAJOR, , 8)

/* PackedA load i16 SG16 for sub group size = 32*/
DEFINE_LOAD_AND_CHECKED(PackedA_RowMajor, _SG16, short, short, 8, 16, ROW_MAJOR, _us, 4)
DEFINE_LOAD(PackedA_RowMajor, _SG16, short, short, 7, 16, ROW_MAJOR, _us, 4)
DEFINE_LOAD(PackedA_RowMajor, _SG16, short, short, 6, 16, ROW_MAJOR, _us, 3)
DEFINE_LOAD(PackedA_RowMajor, _SG16, short, short, 5, 16, ROW_MAJOR, _us, 3)
DEFINE_LOAD(PackedA_RowMajor, _SG16, short, short, 4, 16, ROW_MAJOR, _us, 2)
DEFINE_LOAD(PackedA_RowMajor, _SG16, short, short, 3, 16, ROW_MAJOR, _us, 2)
DEFINE_LOAD(PackedA_RowMajor, _SG16, short, short, 2, 16, ROW_MAJOR, _us, 1)
// DEFINE_LOAD(PackedA_RowMajor, _SG16, short, short, 1, 16, ROW_MAJOR, _us, 1) same as for subgroup 16

/* PackedA load i16 SG16 Col Major for sub group size = 32*/
DEFINE_LOAD_AND_CHECKED(PackedA_ColumnMajor, _SG16, short, short, 8, 16, COL_MAJOR, , 4)

/* PackedA load i8 SG16 */
DEFINE_LOAD_AND_CHECKED(PackedA_RowMajor, _SG16, char, short, 8, 32, ROW_MAJOR, _us, 8)
DEFINE_LOAD(PackedA_RowMajor, _SG16, char, short, 7, 32, ROW_MAJOR, _us, 7)
DEFINE_LOAD(PackedA_RowMajor, _SG16, char, short, 6, 32, ROW_MAJOR, _us, 6)
DEFINE_LOAD(PackedA_RowMajor, _SG16, char, short, 5, 32, ROW_MAJOR, _us, 5)
DEFINE_LOAD_AND_CHECKED(PackedA_RowMajor, _SG16, char, short, 4, 32, ROW_MAJOR, _us, 4)
DEFINE_LOAD(PackedA_RowMajor, _SG16, char, short, 3, 32, ROW_MAJOR, _us, 3)
DEFINE_LOAD_AND_CHECKED(PackedA_RowMajor, _SG16, char, short, 2, 32, ROW_MAJOR, _us, 2)
DEFINE_LOAD_AND_CHECKED(PackedA_RowMajor, _SG16, char, short, 1, 32, ROW_MAJOR, _us, 1)

/* PackedA load i8 SG16 Col Major*/
DEFINE_LOAD_AND_CHECKED(PackedA_ColumnMajor, _SG16, char, short, 8, 32, COL_MAJOR, , 8)

/* PackedA load i8 SG16 for sub group size 32*/
DEFINE_LOAD_AND_CHECKED(PackedA_RowMajor, _SG16, char, short, 8, 32, ROW_MAJOR, _us, 4)
DEFINE_LOAD(PackedA_RowMajor, _SG16, char, short, 7, 32, ROW_MAJOR, _us, 4)
DEFINE_LOAD(PackedA_RowMajor, _SG16, char, short, 6, 32, ROW_MAJOR, _us, 3)
DEFINE_LOAD(PackedA_RowMajor, _SG16, char, short, 5, 32, ROW_MAJOR, _us, 3)
DEFINE_LOAD(PackedA_RowMajor, _SG16, char, short, 4, 32, ROW_MAJOR, _us, 2)
DEFINE_LOAD(PackedA_RowMajor, _SG16, char, short, 3, 32, ROW_MAJOR, _us, 2)
DEFINE_LOAD(PackedA_RowMajor, _SG16, char, short, 2, 32, ROW_MAJOR, _us, 1)
// DEFINE_LOAD(PackedA_RowMajor, _SG16, char, short, 1, 32, ROW_MAJOR, _us, 1)  same as for subgroup 16

/* PackedA load i8 SG16 Col Major for sub group size 32*/
DEFINE_LOAD_AND_CHECKED(PackedA_ColumnMajor, _SG16, char,  short, 8, 32, COL_MAJOR, , 4)

/* A load tf32 SG16 */
DEFINE_LOAD_AND_CHECKED(PackedA_RowMajor, _SG16, int, int, 8, 8, ROW_MAJOR, , 4)

/* A load tf32 SG16 for sub group size 32*/
DEFINE_LOAD(PackedA_RowMajor, _SG16, int, int, 8, 8, ROW_MAJOR, , 2)

/* PackedB load i16 */
DEFINE_LOAD(PackedB_ColumnMajor, , short, int, 8, 16, COL_MAJOR, , 8)
DEFINE_LOAD(PackedB_PackedB, ,     short, int, 8, 16, ROW_MAJOR, , 8)
DEFINE_LOAD(PackedB_RowMajor, ,    short, int, 8, 16, VNNI_TX,   , 8)

/* PackedB load i8 */
DEFINE_LOAD(PackedB_ColumnMajor, , char, int, 8, 32, COL_MAJOR, , 8)
DEFINE_LOAD(PackedB_PackedB,     , char, int, 8, 32, ROW_MAJOR, , 8)
DEFINE_LOAD(PackedB_RowMajor, ,    char, int, 8, 32, VNNI_TX,   , 8)

/* PackedB load i16 SG16 */
DEFINE_LOAD_AND_CHECKED(PackedB_ColumnMajor, _SG16, short, int, 8, 32, COL_MAJOR, , 8)
DEFINE_LOAD_AND_CHECKED(PackedB_PackedB,     _SG16, short, int, 8, 32, ROW_MAJOR, , 8)
DEFINE_LOAD_AND_CHECKED(PackedB_RowMajor,    _SG16, short, int, 8, 32, VNNI_TX,   , 8)

/* used for implementation of PackedB load i16 SG16 32x64 (vnni 16x128) shape*/
DEFINE_LOAD_AND_CHECKED(PackedB_PackedB,     _SG16, short, int, 16, 32, ROW_MAJOR, , 16)
DEFINE_LOAD_AND_CHECKED(PackedB_RowMajor,    _SG16, short, int, 16, 32, VNNI_TX,   , 16)

/* PackedB load i16 SG16 for sub group size = 32*/
DEFINE_LOAD_AND_CHECKED(PackedB_ColumnMajor, _SG16, short, int, 8, 32, COL_MAJOR, , 4)
DEFINE_LOAD_AND_CHECKED(PackedB_PackedB,     _SG16, short, int, 8, 32, ROW_MAJOR, , 4)
DEFINE_LOAD_AND_CHECKED(PackedB_RowMajor,    _SG16, short, int, 8, 32, VNNI_TX,   , 4)

/* PackedB load i8 SG16*/
DEFINE_LOAD_AND_CHECKED(PackedB_ColumnMajor, _SG16, char, int, 8, 64, COL_MAJOR, , 8)
DEFINE_LOAD_AND_CHECKED(PackedB_PackedB,     _SG16, char, int, 8, 64, ROW_MAJOR, , 8)
DEFINE_LOAD_AND_CHECKED(PackedB_RowMajor,    _SG16, char, int, 8, 64, VNNI_TX,   , 8)

/* PackedB load i8 SG16 for sub group size 32*/
DEFINE_LOAD_AND_CHECKED(PackedB_ColumnMajor, _SG16, char, int, 8, 64, COL_MAJOR, , 4)
DEFINE_LOAD_AND_CHECKED(PackedB_PackedB,     _SG16, char, int, 8, 64, ROW_MAJOR, , 4)
DEFINE_LOAD_AND_CHECKED(PackedB_RowMajor,    _SG16, char, int, 8, 64, VNNI_TX,   , 4)

/* B load tf32 SG16 */
DEFINE_LOAD_AND_CHECKED(PackedB_RowMajor, _SG16, int, int, 8, 16, ROW_MAJOR, , 8)

/* B load tf32 SG16 sub group = 32 */
DEFINE_LOAD_AND_CHECKED(PackedB_RowMajor, _SG16, int, int, 8, 16, ROW_MAJOR, , 4)

/* Load accumulator is a special case of load packed A, both are row major: */
DEFINE_LOAD(Accumulator_RowMajor, , int, int, 8, 8, ROW_MAJOR, , 8)
DEFINE_LOAD(Accumulator_RowMajor, , int, int, 7, 8, ROW_MAJOR, , 7)
DEFINE_LOAD(Accumulator_RowMajor, , int, int, 6, 8, ROW_MAJOR, , 6)
DEFINE_LOAD(Accumulator_RowMajor, , int, int, 5, 8, ROW_MAJOR, , 5)
DEFINE_LOAD(Accumulator_RowMajor, , int, int, 4, 8, ROW_MAJOR, , 4)
DEFINE_LOAD(Accumulator_RowMajor, , int, int, 3, 8, ROW_MAJOR, , 3)
DEFINE_LOAD(Accumulator_RowMajor, , int, int, 2, 8, ROW_MAJOR, , 2)
DEFINE_LOAD(Accumulator_RowMajor, , int, int, 1, 8, ROW_MAJOR, , 1)

/* Accumulator load i32 SG8 with transpose */
DEFINE_LOAD(Accumulator_ColumnMajor, , int, int, 8, 8, COL_MAJOR, , 8)
DEFINE_LOAD(Accumulator_ColumnMajor, , int, int, 7, 8, COL_MAJOR, , 7)
DEFINE_LOAD(Accumulator_ColumnMajor, , int, int, 6, 8, COL_MAJOR, , 6)
DEFINE_LOAD(Accumulator_ColumnMajor, , int, int, 5, 8, COL_MAJOR, , 5)
DEFINE_LOAD(Accumulator_ColumnMajor, , int, int, 4, 8, COL_MAJOR, , 4)
DEFINE_LOAD(Accumulator_ColumnMajor, , int, int, 3, 8, COL_MAJOR, , 3)
DEFINE_LOAD(Accumulator_ColumnMajor, , int, int, 2, 8, COL_MAJOR, , 2)
DEFINE_LOAD(Accumulator_ColumnMajor, , int, int, 1, 8, COL_MAJOR, , 1)

/* SG16*/
DEFINE_LOAD_AND_CHECKED(Accumulator_RowMajor, _SG16, int, int, 8, 16, ROW_MAJOR, , 8)
DEFINE_LOAD(Accumulator_RowMajor, _SG16, int, int, 7, 16, ROW_MAJOR, , 7)
DEFINE_LOAD(Accumulator_RowMajor, _SG16, int, int, 6, 16, ROW_MAJOR, , 6)
DEFINE_LOAD(Accumulator_RowMajor, _SG16, int, int, 5, 16, ROW_MAJOR, , 5)
DEFINE_LOAD_AND_CHECKED(Accumulator_RowMajor, _SG16, int, int, 4, 16, ROW_MAJOR, , 4)
DEFINE_LOAD(Accumulator_RowMajor, _SG16, int, int, 3, 16, ROW_MAJOR, , 3)
DEFINE_LOAD_AND_CHECKED(Accumulator_RowMajor, _SG16, int, int, 2, 16, ROW_MAJOR, , 2)
DEFINE_LOAD_AND_CHECKED(Accumulator_RowMajor, _SG16, int, int, 1, 16, ROW_MAJOR, , 1)

/* Accumulator load i32 SG16 with transpose */
DEFINE_LOAD_AND_CHECKED(Accumulator_ColumnMajor, _SG16, int, int, 8, 16, COL_MAJOR, , 8)
DEFINE_LOAD(Accumulator_ColumnMajor, _SG16, int, int, 7, 16, COL_MAJOR, , 7)
DEFINE_LOAD(Accumulator_ColumnMajor, _SG16, int, int, 6, 16, COL_MAJOR, , 6)
DEFINE_LOAD(Accumulator_ColumnMajor, _SG16, int, int, 5, 16, COL_MAJOR, , 5)
DEFINE_LOAD_AND_CHECKED(Accumulator_ColumnMajor, _SG16, int, int, 4, 16, COL_MAJOR, , 4)
DEFINE_LOAD(Accumulator_ColumnMajor, _SG16, int, int, 3, 16, COL_MAJOR, , 3)
DEFINE_LOAD_AND_CHECKED(Accumulator_ColumnMajor, _SG16, int, int, 2, 16, COL_MAJOR, , 2)
DEFINE_LOAD_AND_CHECKED(Accumulator_ColumnMajor, _SG16, int, int, 1, 16, COL_MAJOR, , 1)

/* SG16 for subgroup 32*/
DEFINE_LOAD_AND_CHECKED(Accumulator_RowMajor, _SG16, int, int, 8, 16, ROW_MAJOR, , 4)
DEFINE_LOAD(Accumulator_RowMajor, _SG16, int, int, 7, 16, ROW_MAJOR, , 4)
DEFINE_LOAD(Accumulator_RowMajor, _SG16, int, int, 6, 16, ROW_MAJOR, , 3)
DEFINE_LOAD(Accumulator_RowMajor, _SG16, int, int, 5, 16, ROW_MAJOR, , 3)
DEFINE_LOAD_AND_CHECKED(Accumulator_RowMajor, _SG16, int, int, 4, 16, ROW_MAJOR, , 2)
DEFINE_LOAD(Accumulator_RowMajor, _SG16, int, int, 3, 16, ROW_MAJOR, , 2)
DEFINE_LOAD_AND_CHECKED(Accumulator_RowMajor, _SG16, int, int, 2, 16, ROW_MAJOR, , 1)
// DEFINE_LOAD(Accumulator_RowMajor, _SG16, int, int, 1, 16, ROW_MAJOR, , 1) same as for subgroup 16

/* Accumulator load i32 SG16 for subgroup 32 with transpose */
DEFINE_LOAD(Accumulator_ColumnMajor, _SG16, int, int, 8, 16, COL_MAJOR, , 4)
DEFINE_LOAD(Accumulator_ColumnMajor, _SG16, int, int, 7, 16, COL_MAJOR, , 4)
DEFINE_LOAD(Accumulator_ColumnMajor, _SG16, int, int, 6, 16, COL_MAJOR, , 3)
DEFINE_LOAD(Accumulator_ColumnMajor, _SG16, int, int, 5, 16, COL_MAJOR, , 3)
DEFINE_LOAD(Accumulator_ColumnMajor, _SG16, int, int, 4, 16, COL_MAJOR, , 2)
DEFINE_LOAD(Accumulator_ColumnMajor, _SG16, int, int, 3, 16, COL_MAJOR, , 2)
DEFINE_LOAD(Accumulator_ColumnMajor, _SG16, int, int, 2, 16, COL_MAJOR, , 1)
// DEFINE_LOAD(Accumulator_ColumnMajor, _SG16, int, int, 1, 16, COL_MAJOR, , 1) same as for subgroup 16

// --------- STORE built-ins --------------------------------------

#define MANGLE_STORE_NAME(layout, sg, elem_bitwidth, shape, WI_rows, address_space) \
  __builtin_spriv_OpJointMatrixStoreINTEL_##layout##sg##_##shape##_i##elem_bitwidth##_##WI_rows##_##address_space##_pi64_v8i8

#define MANGLE_STORE_CHECKED_NAME(layout, sg, elem_bitwidth, shape, WI_rows) \
  __builtin_spriv_OpJointMatrixStoreCheckedINTEL_##layout##sg##_##shape##_i##elem_bitwidth##_##WI_rows##_pi64_v8i8

#define VEC_IND8(var, ind) var[ind]
#define VEC_IND7(var, ind) var[ind]
#define VEC_IND6(var, ind) var[ind]
#define VEC_IND5(var, ind) var[ind]
#define VEC_IND4(var, ind) var[ind]
#define VEC_IND3(var, ind) var[ind]
#define VEC_IND2(var, ind) var[ind]
#define VEC_IND1(var, ind) var

#define DEFINE_STORE_BLOCK2D_IMPL(sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, order, WI_rows) \
    if (WI_rows >= M && BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) >= BLOCK2D_IMPL && \
        (M == 1 || M == 2 || M == 4 || M == 8 || M == 16 || M == 32) \
        && order == _ROW_MAJOR && elem_bitwidth >= 8  \
        ) { \
        IMPLEMENT_BLOCK2D_STORE##sg(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, MATH_DIV(K, MATH_DIV(contrib_bitwidth, elem_bitwidth))) \
    }

#define DEFINE_STORE_CHECKED_BLOCK2D_IMPL(sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, order, WI_rows) \
    IMPLEMENT_BLOCK2D_STORE_CHECKED##sg(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, WI_rows, MATH_DIV(K, MATH_DIV(contrib_bitwidth, elem_bitwidth)))

// set block_opt to false to disable block non-continous optimization per one built-in as a workaround
#define DEFINE_STORE_VECTORS_IMPL(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, order, us, WI_rows, block_opt, address_space) \
    if (WI_rows >= M && BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) >= VECTOR_CONT_IMPL && \
        (stride == K || (WI_rows > M && WI_rows % M == 0)) \
        && (M == 1 || M == 2 || M == 4 || M == 8) && order == _ROW_MAJOR \
        ) { \
        OUT_VEC##WI_rows(u##contrib_type) vec = *(__private OUT_VEC##WI_rows(u##contrib_type) *)src; \
        void OVERLOADABLE DEFINE_BLOCK_RW_NAME##WI_rows(write, us)(ATTRIBUTE_##address_space u##contrib_type *, OUT_STORE_VEC##WI_rows(u##contrib_type)); \
        DEFINE_BLOCK_RW_NAME##WI_rows(write, us)((ATTRIBUTE_##address_space u##contrib_type *)mem, VEC_TO_VEC_STORE##WI_rows(u##contrib_type , vec)); \
        return; \
    } \
    if (WI_rows >= M && (BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) >= VECTOR_IMPL) \
        && order == _ROW_MAJOR && block_opt == true \
        && (M != 1 || sg_size != 32) \
        ) { \
        ATTRIBUTE_##address_space u##contrib_type *ptr = (ATTRIBUTE_##address_space u##contrib_type *)mem; \
        int pack_factor = sizeof (u##contrib_type) / sizeof (element_type); \
        stride = stride / pack_factor; \
        int ratio = WI_rows / M; \
        for (int i = 0; i < WI_rows; i++) \
            intel_sub_group_block_write##us(ptr + (i/ratio)*stride + (i%ratio)*sg_size, ((__private u##contrib_type *)src)[i]); \
        return; \
    }

#define DEFINE_STORE_SCALAR_IMPL(layout, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, order, WI_rows) \
    int slid = get_sub_group_local_id(); \
    int pack_factor = sizeof (contrib_type) / sizeof (element_type); \
    int elem_num = (M * K) / sg_size; \
    int sg_cols = K / pack_factor; \
    int skip_factor = sg_size / sg_cols; \
    if (_##layout == _PackedA_ColumnMajor && elem_bitwidth == 8 && contrib_bitwidth == 16) { \
        for (int i = 0; i < elem_num; i++) \
            mem[(i % pack_factor) * stride + ((slid * pack_factor) % K) * stride + (i / pack_factor) * skip_factor + (slid * pack_factor) / K] = src[i]; \
        return; \
    } \
    contrib_type *ptr = (contrib_type *)mem; \
    stride = stride / pack_factor; \
    __private contrib_type *slice = (__private contrib_type *)src; \
    if(sg_size >= sg_cols) { \
        for (int i = 0; i < WI_rows; i++) { \
            if ( (i*skip_factor + slid/sg_cols) < M ) \
                ptr[IND##order(slid, stride, skip_factor, i, sg_cols)] = slice[i]; \
            else \
                continue; /*last even row for matrix with odd number of rows doesn't exist*/ \
        } \
        return; \
    } \
    int ratio = WI_rows / M; \
    for (int i = 0; i < WI_rows; i++) { \
        ptr[(i/ratio)*stride + (i%ratio)*sg_size + slid] = slice[i]; \
    }

#define DEFINE_STORE_IMPL_AS_GENERIC(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows, block_opt) \
    INLINE void MANGLE_STORE_NAME(layout, sg, elem_bitwidth, shape, WI_rows, generic) (char *mem, __private char *src, long stride, int cacheOpt) { \
        int sg_size = get_sub_group_size(); \
        __builtin_assume((__global char*)mem != 0); \
        int memIsGlobal = (0 != SPIRV_BUILTIN(GenericCastToPtrExplicit, _p1i8_p4i8_i32, _ToGlobal)(__builtin_astype((mem), __generic char*), StorageWorkgroup)); \
        if (memIsGlobal) { \
            DEFINE_STORE_BLOCK2D_IMPL(sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, _##order, WI_rows) \
            DEFINE_STORE_VECTORS_IMPL(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, _##order, us, WI_rows, block_opt, AS_GLOBAL) \
        } else { \
            DEFINE_STORE_VECTORS_IMPL(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, _##order, us, WI_rows, block_opt, AS_LOCAL) \
        } \
        DEFINE_STORE_SCALAR_IMPL(layout, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, _##order, WI_rows) \
    }

#define DEFINE_STORE_IMPL_AS_LOCAL(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows, block_opt) \
    INLINE void MANGLE_STORE_NAME(layout, sg, elem_bitwidth, shape, WI_rows, local) (char *mem, __private char *src, long stride, int cacheOpt) { \
        int sg_size = get_sub_group_size(); \
        DEFINE_STORE_VECTORS_IMPL(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, _##order, us, WI_rows, block_opt, AS_LOCAL) \
        DEFINE_STORE_SCALAR_IMPL(layout, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, _##order, WI_rows) \
    }

#define DEFINE_STORE_IMPL_AS_GLOBAL(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows, block_opt) \
    INLINE void MANGLE_STORE_NAME(layout, sg, elem_bitwidth, shape, WI_rows, global) (char *mem, __private char *src, long stride, int cacheOpt) { \
        int sg_size = get_sub_group_size(); \
        DEFINE_STORE_BLOCK2D_IMPL(sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, _##order, WI_rows) \
        DEFINE_STORE_VECTORS_IMPL(element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, _##order, us, WI_rows, block_opt, AS_GLOBAL) \
        DEFINE_STORE_SCALAR_IMPL(layout, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, _##order, WI_rows) \
    }

#define DEFINE_STORE_CHECKED_IMPL(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows, block_opt) \
    INLINE void MANGLE_STORE_CHECKED_NAME(layout, sg, elem_bitwidth, shape, WI_rows) (char *mem, __private char *src, int y, int x, int height, int width, long stride, int cacheOpt) { \
        DEFINE_STORE_CHECKED_BLOCK2D_IMPL(sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, _##order, WI_rows) \
    }

#define DEFINE_STORE_IMPL(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows, block_opt) \
    DEFINE_STORE_IMPL_AS_GENERIC(layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows, block_opt) \
    DEFINE_STORE_IMPL_AS_LOCAL(  layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows, block_opt) \
    DEFINE_STORE_IMPL_AS_GLOBAL( layout, sg, element_type, elem_bitwidth, contrib_type, contrib_bitwidth, M, K, shape, order, us, WI_rows, block_opt)

#define DEFINE_STORE(layout, sg, element_type, contrib_type, M, K, order, us, WI_rows, block_opt) \
    DEFINE_STORE_IMPL(layout, sg, element_type, BITWIDTH(element_type), contrib_type, BITWIDTH(contrib_type),\
                      M, K, SHAPE(layout, M, K, element_type, contrib_type), \
                      order, us, WI_rows, block_opt)

/* only 2D block store is supported for checked store */
#define DEFINE_STORE_CHECKED(layout, sg, element_type, contrib_type, M, K, order, us, WI_rows, block_opt) \
    DEFINE_STORE_CHECKED_IMPL(layout, sg, element_type, BITWIDTH(element_type), contrib_type, BITWIDTH(contrib_type),\
                      M, K, SHAPE(layout, M, K, element_type, contrib_type), \
                      order, us, WI_rows, block_opt)

// TODO: investigate why intel_sub_group_block_write causes an assertion and enable blocked non-continuous optimization

#define DEFINE_STORE_AND_CHECKED(layout, sg, element_type, contrib_type, M, K, order, us, WI_rows, block_opt) \
    DEFINE_STORE(layout, sg, element_type, contrib_type, M, K, order, us, WI_rows, block_opt) \
    DEFINE_STORE_CHECKED(layout, sg, element_type, contrib_type, M, K, order, us, WI_rows, block_opt)

/* PackedA store i8 */
DEFINE_STORE(PackedA_RowMajor,      , char, int,   1, 32, ROW_MAJOR,    , 1, false)
DEFINE_STORE(PackedA_RowMajor,      , char, int,   2, 32, ROW_MAJOR,    , 2, false)
DEFINE_STORE(PackedA_RowMajor,      , char, int,   3, 32, ROW_MAJOR,    , 3, false)
DEFINE_STORE(PackedA_RowMajor,      , char, int,   4, 32, ROW_MAJOR,    , 4, false)
DEFINE_STORE(PackedA_RowMajor,      , char, int,   5, 32, ROW_MAJOR,    , 5, false)
DEFINE_STORE(PackedA_RowMajor,      , char, int,   6, 32, ROW_MAJOR,    , 6, false)
DEFINE_STORE(PackedA_RowMajor,      , char, int,   7, 32, ROW_MAJOR,    , 7, false)
DEFINE_STORE(PackedA_RowMajor,      , char, int,   8, 32, ROW_MAJOR,    , 8, false)

/* PackedA store i16 */
DEFINE_STORE(PackedA_RowMajor,      , short, int,   1, 16, ROW_MAJOR,    , 1, false)
DEFINE_STORE(PackedA_RowMajor,      , short, int,   2, 16, ROW_MAJOR,    , 2, false)
DEFINE_STORE(PackedA_RowMajor,      , short, int,   3, 16, ROW_MAJOR,    , 3, false)
DEFINE_STORE(PackedA_RowMajor,      , short, int,   4, 16, ROW_MAJOR,    , 4, false)
DEFINE_STORE(PackedA_RowMajor,      , short, int,   5, 16, ROW_MAJOR,    , 5, false)
DEFINE_STORE(PackedA_RowMajor,      , short, int,   6, 16, ROW_MAJOR,    , 6, false)
DEFINE_STORE(PackedA_RowMajor,      , short, int,   7, 16, ROW_MAJOR,    , 7, false)
DEFINE_STORE(PackedA_RowMajor,      , short, int,   8, 16, ROW_MAJOR,    , 8, false)

/* PackedA store i8 SG16 */
DEFINE_STORE_AND_CHECKED(PackedA_RowMajor, _SG16, char,  short, 1, 32, ROW_MAJOR, _us, 1, false)
DEFINE_STORE_AND_CHECKED(PackedA_RowMajor, _SG16, char,  short, 2, 32, ROW_MAJOR, _us, 2, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, char,  short, 3, 32, ROW_MAJOR, _us, 3, false)
DEFINE_STORE_AND_CHECKED(PackedA_RowMajor, _SG16, char,  short, 4, 32, ROW_MAJOR, _us, 4, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, char,  short, 5, 32, ROW_MAJOR, _us, 5, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, char,  short, 6, 32, ROW_MAJOR, _us, 6, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, char,  short, 7, 32, ROW_MAJOR, _us, 7, false)
DEFINE_STORE_AND_CHECKED(PackedA_RowMajor, _SG16, char,  short, 8, 32, ROW_MAJOR, _us, 8, false)

/* PackedA store i8 SG16 Col Major*/
DEFINE_STORE(PackedA_ColumnMajor, _SG16, char,  short, 8, 32, COL_MAJOR, _us, 8, true)

/* PackedA store i8 SG16 for subgroup 32*/
// DEFINE_STORE(PackedA_RowMajor, _SG16, char,  short, 1, 32, ROW_MAJOR, _us, 1, false) same as for subgroup 16
DEFINE_STORE(PackedA_RowMajor, _SG16, char,  short, 2, 32, ROW_MAJOR, _us, 1, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, char,  short, 3, 32, ROW_MAJOR, _us, 2, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, char,  short, 4, 32, ROW_MAJOR, _us, 2, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, char,  short, 5, 32, ROW_MAJOR, _us, 3, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, char,  short, 6, 32, ROW_MAJOR, _us, 3, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, char,  short, 7, 32, ROW_MAJOR, _us, 4, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, char,  short, 8, 32, ROW_MAJOR, _us, 4, false)

/* PackedA store i8 SG16 Col Major for sg 32*/
DEFINE_STORE(PackedA_ColumnMajor, _SG16, char,  short, 8, 32, COL_MAJOR, _us, 4, true)

/* PackedA store i16 SG16 */
DEFINE_STORE_AND_CHECKED(PackedA_RowMajor, _SG16, short, short, 1, 16, ROW_MAJOR, _us, 1, false)
DEFINE_STORE_AND_CHECKED(PackedA_RowMajor, _SG16, short, short, 2, 16, ROW_MAJOR, _us, 2, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, short, short, 3, 16, ROW_MAJOR, _us, 3, false)
DEFINE_STORE_AND_CHECKED(PackedA_RowMajor, _SG16, short, short, 4, 16, ROW_MAJOR, _us, 4, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, short, short, 5, 16, ROW_MAJOR, _us, 5, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, short, short, 6, 16, ROW_MAJOR, _us, 6, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, short, short, 7, 16, ROW_MAJOR, _us, 7, false)
DEFINE_STORE_AND_CHECKED(PackedA_RowMajor, _SG16, short, short, 8, 16, ROW_MAJOR, _us, 8, false)

DEFINE_STORE_AND_CHECKED(PackedA_RowMajor, _SG16, short, short, 1, 32, ROW_MAJOR, _us, 2, true)

/* PackedA store i16 SG16 Col Major*/
DEFINE_STORE(PackedA_ColumnMajor, _SG16, short, short, 8, 16, COL_MAJOR, _us, 8, true)

/* PackedA store i16 SG16 Col Major for sg size 32*/
DEFINE_STORE(PackedA_ColumnMajor, _SG16, short, short, 8, 16, COL_MAJOR, _us, 4, true)

/* PackedA store i16 SG16 for sub group size 32 */
// DEFINE_STORE(PackedA_RowMajor, _SG16, short, short, 1, 16, ROW_MAJOR, _us, 1, false) same as for subgroup 16
DEFINE_STORE(PackedA_RowMajor, _SG16, short, short, 2, 16, ROW_MAJOR, _us, 1, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, short, short, 3, 16, ROW_MAJOR, _us, 2, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, short, short, 4, 16, ROW_MAJOR, _us, 2, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, short, short, 5, 16, ROW_MAJOR, _us, 3, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, short, short, 6, 16, ROW_MAJOR, _us, 3, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, short, short, 7, 16, ROW_MAJOR, _us, 4, false)
DEFINE_STORE(PackedA_RowMajor, _SG16, short, short, 8, 16, ROW_MAJOR, _us, 4, false)

/* A store tf32 SG16 */
DEFINE_STORE(PackedA_RowMajor, _SG16, int, int, 8, 8, ROW_MAJOR, , 4, false)
/* A store tf32 SG16 for sub group size 32*/
DEFINE_STORE(PackedA_RowMajor, _SG16, int, int, 8, 8, ROW_MAJOR, , 2, false)

/* PackedB store i16*/
DEFINE_STORE(PackedB_ColumnMajor, , short, int, 8, 16, COL_MAJOR, , 8, false)
DEFINE_STORE(PackedB_PackedB,     , short, int, 8, 16, ROW_MAJOR, , 8, true)
DEFINE_STORE(PackedB_RowMajor,    , short, int, 8, 16, VNNI_TX,   , 8, true)

/* PackedB store i16 SG16*/
DEFINE_STORE(PackedB_ColumnMajor, _SG16, short, int, 8, 32, COL_MAJOR, , 8, false)
DEFINE_STORE_AND_CHECKED(PackedB_PackedB,     _SG16, short, int, 8, 32, ROW_MAJOR, , 8, true)
DEFINE_STORE(PackedB_RowMajor,    _SG16, short, int, 8, 32, VNNI_TX,   , 8, true)

/* PackedB store i16 SG16 for subgroup 32*/
DEFINE_STORE(PackedB_ColumnMajor, _SG16, short, int, 8, 32, COL_MAJOR, , 4, false)
DEFINE_STORE(PackedB_PackedB,     _SG16, short, int, 8, 32, ROW_MAJOR, , 4, true)

// TODO: investigate why intel_sub_group_block_write causes an assertion and enable blocked non-continuous optimization
/* PackedB store i8 */
DEFINE_STORE(PackedB_ColumnMajor, , char, int, 8, 32, COL_MAJOR, , 8, false)
DEFINE_STORE(PackedB_PackedB,     , char, int, 8, 32, ROW_MAJOR, , 8, false)

/* PackedB store i8 SG16 */
DEFINE_STORE(PackedB_ColumnMajor, _SG16, char, int, 8, 64, COL_MAJOR, , 8, false)
DEFINE_STORE_AND_CHECKED(PackedB_PackedB,     _SG16, char, int, 8, 64, ROW_MAJOR, , 8, false)

/* PackedB store i8 SG16 for subgroup 32*/
DEFINE_STORE(PackedB_ColumnMajor, _SG16, char, int, 8, 64, COL_MAJOR, , 4, false)
DEFINE_STORE(PackedB_PackedB,     _SG16, char, int, 8, 64, ROW_MAJOR, , 4, true)

/* B store tf32 SG16 */
DEFINE_STORE_AND_CHECKED(PackedB_RowMajor, _SG16, int, int, 8, 16, ROW_MAJOR, , 8, true)

/* B store tf32 SG16 for sub group size 32 */
DEFINE_STORE(PackedB_RowMajor, _SG16, int, int, 8, 16, ROW_MAJOR, , 4, true)

/* Acc i32 */
DEFINE_STORE(Accumulator_RowMajor, , int, int, 8, 8, ROW_MAJOR, , 8, true)
DEFINE_STORE(Accumulator_RowMajor, , int, int, 7, 8, ROW_MAJOR, , 7, true)
DEFINE_STORE(Accumulator_RowMajor, , int, int, 6, 8, ROW_MAJOR, , 6, true)
DEFINE_STORE(Accumulator_RowMajor, , int, int, 5, 8, ROW_MAJOR, , 5, true)
DEFINE_STORE(Accumulator_RowMajor, , int, int, 4, 8, ROW_MAJOR, , 4, true)
DEFINE_STORE(Accumulator_RowMajor, , int, int, 3, 8, ROW_MAJOR, , 3, true)
DEFINE_STORE(Accumulator_RowMajor, , int, int, 2, 8, ROW_MAJOR, , 2, true)
DEFINE_STORE(Accumulator_RowMajor, , int, int, 1, 8, ROW_MAJOR, , 1, true)

/* Accumulator store i32 SG8 with transpose */
DEFINE_STORE(Accumulator_ColumnMajor, , int, int, 8, 8, COL_MAJOR, , 8, true)
DEFINE_STORE(Accumulator_ColumnMajor, , int, int, 7, 8, COL_MAJOR, , 7, true)
DEFINE_STORE(Accumulator_ColumnMajor, , int, int, 6, 8, COL_MAJOR, , 6, true)
DEFINE_STORE(Accumulator_ColumnMajor, , int, int, 5, 8, COL_MAJOR, , 5, true)
DEFINE_STORE(Accumulator_ColumnMajor, , int, int, 4, 8, COL_MAJOR, , 4, true)
DEFINE_STORE(Accumulator_ColumnMajor, , int, int, 3, 8, COL_MAJOR, , 3, true)
DEFINE_STORE(Accumulator_ColumnMajor, , int, int, 2, 8, COL_MAJOR, , 2, true)
DEFINE_STORE(Accumulator_ColumnMajor, , int, int, 1, 8, COL_MAJOR, , 1, true)

/* Acc i32 SG16 */
DEFINE_STORE_AND_CHECKED(Accumulator_RowMajor, _SG16, int, int, 8, 16, ROW_MAJOR, , 8, true)
DEFINE_STORE(Accumulator_RowMajor, _SG16, int, int, 7, 16, ROW_MAJOR, , 7, true)
DEFINE_STORE(Accumulator_RowMajor, _SG16, int, int, 6, 16, ROW_MAJOR, , 6, true)
DEFINE_STORE(Accumulator_RowMajor, _SG16, int, int, 5, 16, ROW_MAJOR, , 5, true)
DEFINE_STORE_AND_CHECKED(Accumulator_RowMajor, _SG16, int, int, 4, 16, ROW_MAJOR, , 4, true)
DEFINE_STORE(Accumulator_RowMajor, _SG16, int, int, 3, 16, ROW_MAJOR, , 3, true)
DEFINE_STORE_AND_CHECKED(Accumulator_RowMajor, _SG16, int, int, 2, 16, ROW_MAJOR, , 2, true)
DEFINE_STORE_AND_CHECKED(Accumulator_RowMajor, _SG16, int, int, 1, 16, ROW_MAJOR, , 1, true)

/* Accumulator store i32 SG16 with transpose */
DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 8, 16, COL_MAJOR, , 8, true)
DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 7, 16, COL_MAJOR, , 7, true)
DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 6, 16, COL_MAJOR, , 6, true)
DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 5, 16, COL_MAJOR, , 5, true)
DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 4, 16, COL_MAJOR, , 4, true)
DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 3, 16, COL_MAJOR, , 3, true)
DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 2, 16, COL_MAJOR, , 2, true)
DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 1, 16, COL_MAJOR, , 1, true)

/* Acc i32 SG16 for subgroup 32*/
DEFINE_STORE_AND_CHECKED(Accumulator_RowMajor, _SG16, int, int, 8, 16, ROW_MAJOR, , 4, true)
DEFINE_STORE(Accumulator_RowMajor, _SG16, int, int, 7, 16, ROW_MAJOR, , 4, true)
DEFINE_STORE(Accumulator_RowMajor, _SG16, int, int, 6, 16, ROW_MAJOR, , 3, true)
DEFINE_STORE(Accumulator_RowMajor, _SG16, int, int, 5, 16, ROW_MAJOR, , 3, true)
DEFINE_STORE(Accumulator_RowMajor, _SG16, int, int, 4, 16, ROW_MAJOR, , 2, true)
DEFINE_STORE(Accumulator_RowMajor, _SG16, int, int, 3, 16, ROW_MAJOR, , 2, true)
DEFINE_STORE(Accumulator_RowMajor, _SG16, int, int, 2, 16, ROW_MAJOR, , 1, true)
// DEFINE_STORE(Accumulator_RowMajor, _SG16, int, int, 1, 16, ROW_MAJOR, , 1, true) same as for subgroup 16

/* Accumulator store i32 SG16 for subgroup 32 with transpose */
DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 8, 16, COL_MAJOR, , 4, true)
DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 7, 16, COL_MAJOR, , 4, true)
DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 6, 16, COL_MAJOR, , 3, true)
DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 5, 16, COL_MAJOR, , 3, true)
DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 4, 16, COL_MAJOR, , 2, true)
DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 3, 16, COL_MAJOR, , 2, true)
DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 2, 16, COL_MAJOR, , 1, true)
// DEFINE_STORE(Accumulator_ColumnMajor, _SG16, int, int, 1, 16, COL_MAJOR, , 1, true) same as for subgroup 16

// sub group size 32 for big combinations is not optimized yet
DEFINE_STORE(PackedA_RowMajor,     _SG16, short, short, 16, 16, ROW_MAJOR, , 8, false)
DEFINE_STORE(Accumulator_RowMajor, _SG16, int,   int,   16, 16, ROW_MAJOR, , 8, false)

/* get_coord() support: */

#define MANGLE_GETCOORD_NAME(layout, sg, elem_bitwidth, R, C) \
  __builtin_spirv_OpJointMatrixGetCoordINTEL_##layout##sg##_##R##x##C##_i##elem_bitwidth

/* Explanation of calculation for int8 and bf16 types
Let's say we are considering a JM of use::A, 8x32, of type i8, in Platform PVC.
with sub-group size 16.

<--------- 32----------------------------->
0 0 x x x x ..........................x x ^
0 o x x x x ..........................x x |
0 0 x x x x ..........................x x 8
0 0 x x x x ..........................x x |
..
0 0 x x x x ..........................x x v

As we divide the elements of the JM col-wise across WIs, each WI will have a
8x2 slice of the JM, and the number of elements held by each WI will be 16.
For example, in the above figure, the elements marked with a '0' is held by
work_item_0 of that subgroup. The next WI will be holding the next 2 cols
and so on..

Now let's look at the calculation. Let's say we are interested in getting the
small o item in work_item_0. The index here is 3. (Please note that index is
the argument of get_coord() call. And each WI has index running 0-15 in this
case, as they hold 16 elements (8x2))

So the calculation becomes:
sg_cols = (C * VF) / pack_factor --> (32 * 1) / 2 = 16
skip_factor = sg_size / sg_cols --> 16 / 16  = 1
row: (wi_id / sg_cols + index / pack_factor * skip_factor) * VF + index % VF --> (0 / 16 + 3 / 2 * 1) * 1 + 3 % 1 = 1
col: (wi_id % sg_cols * pack_factor + index % pack_factor) / VF --> (0 % 16 * 2 + 3 % 2) / 1 = 1

Now, why the index for this particular item is 3 and not 9? That is because
the slice is stored in row-major fashion. So if we have the slice like
the following for a WI:

0 0
1 *1*
2 2
3 3
4 4
5 5
6 6
7 7

The storage in memory will be: 0 0 1 1 2 2 ... 7 7
*/

// R - number of rows
// C - number of columns
// VF - VNNI Factor
#define DEFINE_GET_COORD(layout, sg, elem_bitwidth, contrib_bitwidth, R, C, VF) \
  INLINE int2 MANGLE_GETCOORD_NAME(layout, sg, elem_bitwidth, R, C) (int index) { \
    int sg_size = get_sub_group_size(); \
    int wi_id = get_sub_group_local_id(); \
    int pack_factor = contrib_bitwidth / elem_bitwidth; \
    int sg_cols = (C * VF) / pack_factor; \
    int skip_factor = sg_size / sg_cols; \
    int row = (wi_id / sg_cols + index / pack_factor * skip_factor) * VF + index % VF; \
    int col = (wi_id % sg_cols * pack_factor + index % pack_factor) / VF; \
    int2 result = (int2)(row, col); \
    return result; \
  }

// ------ PVC -------
// layout, sg, elem_bitwidth, contrib_bitwidth, R, C, VF
//int8
DEFINE_GET_COORD(PackedA, _SG16, 8, 16, 8, 32, 1)
DEFINE_GET_COORD(PackedB, _SG16, 8, 32, 32, 16, 4)

//bfloat16
DEFINE_GET_COORD(PackedA, _SG16, 16, 16, 8, 16, 1)
DEFINE_GET_COORD(PackedA, _SG16, 16, 16, 16, 16, 1)
DEFINE_GET_COORD(PackedB, _SG16, 16, 32, 16, 16, 2)

// Accumulator
DEFINE_GET_COORD(Accumulator, _SG16, 32, 32, 8, 16, 1)
DEFINE_GET_COORD(Accumulator, _SG16, 32, 32, 16, 16, 1)

// --------- XMX8 ------------
//int8
DEFINE_GET_COORD(PackedA, , 8, 32, 8, 32, 1)
DEFINE_GET_COORD(PackedB, , 8, 32, 32, 8, 4)

//bfloat16
DEFINE_GET_COORD(PackedA, , 16, 32, 8, 16, 1)
DEFINE_GET_COORD(PackedB, , 16, 32, 16, 8, 2)

// Accumulator
DEFINE_GET_COORD(Accumulator, , 32, 32, 8, 8, 1)

/* experimental large slice support: */

// MAD:

#define DEFINE_MAD_LARGE_SLICE_16bit_AB_IMPL(a_type, b_type, a_suffix, b_suffix) \
INLINE void __builtin_spriv_OpJointMatrixMadINTEL_16x16x16_##a_type##_##b_type##_fp32(__private char *a_ptr, __private char *b_ptr, __private char *raw_c_ptr, __private char *result) { \
    short16 a   = *(short16 *)a_ptr; \
    int8 b      = *(int8 *)b_ptr; \
    int16 raw_c = *(int16 *)raw_c_ptr; \
\
    short8 a0 = (short8)(a.s0, a.s1, a.s2, a.s3, a.s4, a.s5, a.s6, a.s7); \
    short8 a1 = (short8)(a.s8, a.s9, a.sa, a.sb, a.sc, a.sd, a.se, a.sf); \
\
    float16 c = *(float16 *)&raw_c; \
\
    float8 c0 = (float8)(c.s0, c.s1, c.s2, c.s3, c.s4, c.s5, c.s6, c.s7); \
    float8 c1 = (float8)(c.s8, c.s9, c.sa, c.sb, c.sc, c.sd, c.se, c.sf); \
\
    float8 fres0 = __builtin_IB_sub_group16_fdpas_f_f_##a_suffix##_##b_suffix##_8_8(c0, a0, b); \
    float8 fres1 = __builtin_IB_sub_group16_fdpas_f_f_##a_suffix##_##b_suffix##_8_8(c1, a1, b); \
\
    int8 res0 = *(int8 *)&fres0; \
    int8 res1 = *(int8 *)&fres1; \
\
    __private int16 *dst = (__private int16 *)result; \
    *dst = (int16)(res0.s0, res0.s1, res0.s2, res0.s3, res0.s4, res0.s5, res0.s6, res0.s7, \
                   res1.s0, res1.s1, res1.s2, res1.s3, res1.s4, res1.s5, res1.s6, res1.s7); \
} \
\
INLINE void __builtin_spriv_OpJointMatrixMadINTEL_32x32x16_##a_type##_##b_type##_fp32(__private char *a_ptr, __private char *b_ptr, __private char *c_ptr, __private char *d_ptr) { \
    int8 a0 = *(int8 *)a_ptr; \
    int8 a1 = *(int8 *) (a_ptr + 1 * 16 * (sizeof (short))); \
    int8 a2 = *(int8 *) (a_ptr + 2 * 16 * (sizeof (short))); \
    int8 a3 = *(int8 *) (a_ptr + 3 * 16 * (sizeof (short))); \
\
    int8 b0 = *(int8 *)b_ptr; \
    int8 b1 = *(int8 *) (b_ptr + 1 * 16 * (sizeof (short))); \
    int8 b2 = *(int8 *) (b_ptr + 2 * 16 * (sizeof (short))); \
    int8 b3 = *(int8 *) (b_ptr + 3 * 16 * (sizeof (short))); \
\
    float8 c0 = *(float8 *) (c_ptr + 0 * 8 * (sizeof (int))); \
    float8 c1 = *(float8 *) (c_ptr + 4 * 8 * (sizeof (int))); \
    float8 c2 = *(float8 *) (c_ptr + 8 * 8 * (sizeof (int))); \
    float8 c3 = *(float8 *) (c_ptr + 12 * 8 * (sizeof (int))); \
    float8 c4 = *(float8 *) (c_ptr + 1 * 8 * (sizeof (int))); \
    float8 c5 = *(float8 *) (c_ptr + 5 * 8 * (sizeof (int))); \
    float8 c6 = *(float8 *) (c_ptr + 9 * 8 * (sizeof (int))); \
    float8 c7 = *(float8 *) (c_ptr + 13 * 8 * (sizeof (int))); \
    float8 c8 = *(float8 *) (c_ptr + 2 * 8 * (sizeof (int))); \
    float8 c9 = *(float8 *) (c_ptr + 6 * 8 * (sizeof (int))); \
    float8 c10 = *(float8 *) (c_ptr + 10 * 8 * (sizeof (int))); \
    float8 c11 = *(float8 *) (c_ptr + 14 * 8 * (sizeof (int))); \
    float8 c12 = *(float8 *) (c_ptr + 3 * 8 * (sizeof (int))); \
    float8 c13 = *(float8 *) (c_ptr + 7 * 8 * (sizeof (int))); \
    float8 c14 = *(float8 *) (c_ptr + 11 * 8 * (sizeof (int))); \
    float8 c15 = *(float8 *) (c_ptr + 15 * 8 * (sizeof (int))); \
\
    *(float8 *) (d_ptr + 0 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c0, a0, b0); \
    *(float8 *) (d_ptr + 4 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c1, a0, b1); \
    *(float8 *) (d_ptr + 8 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c2, a0, b2); \
    *(float8 *) (d_ptr + 12 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c3, a0, b3); \
    *(float8 *) (d_ptr + 1 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c4, a1, b0); \
    *(float8 *) (d_ptr + 5 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c5, a1, b1); \
    *(float8 *) (d_ptr + 9 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c6, a1, b2); \
    *(float8 *) (d_ptr + 13 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c7, a1, b3); \
    *(float8 *) (d_ptr + 2 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c8, a2, b0); \
    *(float8 *) (d_ptr + 6 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c9, a2, b1); \
    *(float8 *) (d_ptr + 10 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c10, a2, b2); \
    *(float8 *) (d_ptr + 14 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c11, a2, b3); \
    *(float8 *) (d_ptr + 3 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c12, a3, b0); \
    *(float8 *) (d_ptr + 7 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c13, a3, b1); \
    *(float8 *) (d_ptr + 11 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c14, a3, b2); \
    *(float8 *) (d_ptr + 15 * 8 * (sizeof (float))) = __builtin_IB_sub_group_fdpas_##a_suffix##_##b_suffix##_8_8(c15, a3, b3); \
} \
\
INLINE void __builtin_spriv_OpJointMatrixMadINTEL_1x64x16_##a_type##_##b_type##_fp32(__private char *a_ptr, __private char *b_ptr, __private char *c_ptr, __private char *d_ptr) { \
    short a = *(short *) a_ptr; \
\
    int8 b0 = *(int8 *) b_ptr; \
    int8 b1 = *(int8 *)(b_ptr + 1 * 16 * (sizeof (short))); \
    int8 b2 = *(int8 *)(b_ptr + 2 * 16 * (sizeof (short))); \
    int8 b3 = *(int8 *)(b_ptr + 3 * 16 * (sizeof (short))); \
\
    float c0 = *(float *)  c_ptr; \
    float c1 = *(float *) (c_ptr + 1 * (sizeof (int))); \
    float c2 = *(float *) (c_ptr + 2 * (sizeof (int))); \
    float c3 = *(float *) (c_ptr + 3 * (sizeof (int))); \
\
    float d0 = __builtin_IB_sub_group16_fdpas_f_f_##a_suffix##_##b_suffix##_8_1(c0, a, b0); \
    float d1 = __builtin_IB_sub_group16_fdpas_f_f_##a_suffix##_##b_suffix##_8_1(c1, a, b1); \
    float d2 = __builtin_IB_sub_group16_fdpas_f_f_##a_suffix##_##b_suffix##_8_1(c2, a, b2); \
    float d3 = __builtin_IB_sub_group16_fdpas_f_f_##a_suffix##_##b_suffix##_8_1(c3, a, b3); \
\
    __private int4 *dst = (__private int4 *)d_ptr; \
    *dst = (int4)(as_int(d0), as_int(d1), as_int(d2), as_int(d3)); \
} \
\
INLINE void __builtin_spriv_OpJointMatrixMadINTEL_32x64x16_##a_type##_##b_type##_fp32(__private char *a_ptr, __private char *b_ptr, __private char *c_ptr, __private char *d_ptr) { \
    __private char *a0 = a_ptr; \
    __private char *a1 = a_ptr + 16 * (sizeof (short)); \
\
    __private char *b0 = b_ptr; \
    __private char *b1 = b_ptr + 1 * 16 * (sizeof (short)); \
    __private char *b2 = b_ptr + 2 * 16 * (sizeof (short)); \
    __private char *b3 = b_ptr + 3 * 16 * (sizeof (short)); \
\
    __private char *c0 = c_ptr + 0 * 16 * (sizeof (int)); \
    __private char *c1 = c_ptr + 2 * 16 * (sizeof (int)); \
    __private char *c2 = c_ptr + 4 * 16 * (sizeof (int)); \
    __private char *c3 = c_ptr + 6 * 16 * (sizeof (int)); \
    __private char *c4 = c_ptr + 1 * 16 * (sizeof (int)); \
    __private char *c5 = c_ptr + 3 * 16 * (sizeof (int)); \
    __private char *c6 = c_ptr + 5 * 16 * (sizeof (int)); \
    __private char *c7 = c_ptr + 7 * 16 * (sizeof (int)); \
\
    __private char *d0 = d_ptr + 0 * 16 * (sizeof (int)); \
    __private char *d1 = d_ptr + 2 * 16 * (sizeof (int)); \
    __private char *d2 = d_ptr + 4 * 16 * (sizeof (int)); \
    __private char *d3 = d_ptr + 6 * 16 * (sizeof (int)); \
    __private char *d4 = d_ptr + 1 * 16 * (sizeof (int)); \
    __private char *d5 = d_ptr + 3 * 16 * (sizeof (int)); \
    __private char *d6 = d_ptr + 5 * 16 * (sizeof (int)); \
    __private char *d7 = d_ptr + 7 * 16 * (sizeof (int)); \
\
    __builtin_spriv_OpJointMatrixMadINTEL_16x16x16_##a_type##_##b_type##_fp32(a0, b0, c0, d0); \
    __builtin_spriv_OpJointMatrixMadINTEL_16x16x16_##a_type##_##b_type##_fp32(a0, b1, c1, d1); \
    __builtin_spriv_OpJointMatrixMadINTEL_16x16x16_##a_type##_##b_type##_fp32(a0, b2, c2, d2); \
    __builtin_spriv_OpJointMatrixMadINTEL_16x16x16_##a_type##_##b_type##_fp32(a0, b3, c3, d3); \
\
    __builtin_spriv_OpJointMatrixMadINTEL_16x16x16_##a_type##_##b_type##_fp32(a1, b0, c4, d4); \
    __builtin_spriv_OpJointMatrixMadINTEL_16x16x16_##a_type##_##b_type##_fp32(a1, b1, c5, d5); \
    __builtin_spriv_OpJointMatrixMadINTEL_16x16x16_##a_type##_##b_type##_fp32(a1, b2, c6, d6); \
    __builtin_spriv_OpJointMatrixMadINTEL_16x16x16_##a_type##_##b_type##_fp32(a1, b3, c7, d7); \
} \
\
INLINE void __builtin_spriv_OpJointMatrixMadINTEL_32x64x32_##a_type##_##b_type##_fp32(__private char *a_ptr, __private char *b_ptr, __private char *c_ptr, __private char *d_ptr) { \
    short8 a[8]; \
    int8 b[8]; \
    for (int i = 0; i < 8; i++) { \
        a[i] = *(short8 *)(a_ptr + i * 8 * (sizeof (short))); \
        b[i] = *(int8 *)(b_ptr + i * 8 * (sizeof (int))); \
    } \
\
    float8 c[16]; \
    for (int i = 0; i < 16; i++) \
        c[i] = *(float8 *)(c_ptr + i * 8 * (sizeof (int))); \
\
_Pragma("unroll") /* TODO: investigate, why not unrolling the loop causes wrong code generated*/ \
    for (int i = 0; i < 4; i++) { \
        for (int j = 0; j < 4; j++) { \
            float8 d = __builtin_IB_sub_group16_fdpas_f_f_##a_suffix##_##b_suffix##_8_8(c[i + 4*j], a[i], b[2*j]); \
            *(float8 *)(d_ptr + (i + 4*j) * 8 * (sizeof (float))) = __builtin_IB_sub_group16_fdpas_f_f_##a_suffix##_##b_suffix##_8_8(d, a[i + 4], b[2*j + 1]); \
        } \
    } \
} \
\
INLINE void __builtin_spriv_OpJointMatrixMadINTEL_1x64x32_##a_type##_##b_type##_fp32(__private char *a_ptr, __private char *b_ptr, __private char *c_ptr, __private char *d_ptr) { \
    short a0 = *(short *)(a_ptr + 0 * (sizeof (short))); \
    short a1 = *(short *)(a_ptr + 1 * (sizeof (short))); \
\
    int8 b[8]; \
    for (int i = 0; i < 8; i++) \
        b[i] = *(int8 *)(b_ptr + i * 8 * (sizeof (int))); \
\
    float c[4]; \
    for (int i = 0; i < 4; i++) \
        c[i] = *(float *)(c_ptr + i * (sizeof (int))); \
\
    for (int i = 0; i < 4; i++) { \
        float d = __builtin_IB_sub_group16_fdpas_f_f_##a_suffix##_##b_suffix##_8_1(c[i], a0, b[2 * i]); \
        *(float *)(d_ptr + i * (sizeof (float))) = __builtin_IB_sub_group16_fdpas_f_f_##a_suffix##_##b_suffix##_8_1(d, a1, b[2 * i + 1]); \
    } \
}

DEFINE_MAD_LARGE_SLICE_16bit_AB_IMPL(bf16, bf16, bf, bf)
DEFINE_MAD_LARGE_SLICE_16bit_AB_IMPL(fp16, fp16, hf, hf)

// LOADS:

/* PackedA load i16 for big shapes */
DEFINE_LOAD(PackedA_RowMajor, , short, int, 32, 16,  ROW_MAJOR, , 32)

/* PackedA load i16 SG16 for big shapes */
DEFINE_LOAD_AND_CHECKED(        PackedA_RowMajor,  _SG16, short, short, 16, 16, ROW_MAJOR, _us, 16)
DEFINE_LOAD_AND_CHECKED(        PackedA_RowMajor,  _SG16, short, short, 32, 16, ROW_MAJOR, _us, 32)

/* Accumulator load i32 for big shapes */
DEFINE_LOAD(Accumulator_RowMajor, , int,   int,   32,  8, ROW_MAJOR, , 32)

/* Accumulator load i32 SG16 for big shapes */
DEFINE_LOAD_AND_CHECKED(        Accumulator_RowMajor, _SG16, int, int, 16, 16, ROW_MAJOR, , 16)
DEFINE_LOAD_AND_CHECKED(        Accumulator_RowMajor, _SG16, int, int, 32, 16, ROW_MAJOR, , 32)

/* Optimization for big shapes 1d load, where number of columns is multiple of sub-group size
   specifically, for sub group size 16 and number of columns 32, we can load 2 elements in one instruction */
#define DEFINE_LOAD_LARGE_IMPL_2_OPTIMIZED_VECTOR_CONT_IMPL(layout, elem_type, contrib_type, R, address_space) \
    if (BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) == VECTOR_CONT_IMPL) { \
      if (_##layout == _PackedA_RowMajor) { \
        for (int i = 0; i < R; i++) { \
          ushort2 row = intel_sub_group_block_read_us2((__##address_space ushort *)(mem + i * stride * sizeof(elem_type))); \
          *((__private ushort *)(dst +  i        * sizeof(contrib_type))) = row.x; \
          *((__private ushort *)(dst + (i + R)   * sizeof(contrib_type))) = row.y; \
        } \
        return; \
      } \
    }

// default implementation for large shapes which is reusing smaller loads
// _2 in the name is for 2 smaller loads
// This function implements the LOAD operations for Matrix A 32x32
#define DEFINE_LOAD_LARGE_IMPL_2(layout, sg, elem_type, elem_bitwidth, contrib_type, WI_rows_per_load, address_space, row_stride, column_stride, load_shape) \
    __private char *dst0 = dst; \
    __private char *dst1 = dst + WI_rows_per_load * (sizeof (contrib_type)); \
\
    char *mem0 = mem; \
    char *mem1 = mem + 16 * sizeof(elem_type); \
\
    __builtin_spriv_OpJointMatrixLoadINTEL_##layout##sg##_32x16_i##elem_bitwidth##_##WI_rows_per_load##_##address_space##_v8i8_pi32_i32(dst0, mem0, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixLoadINTEL_##layout##sg##_32x16_i##elem_bitwidth##_##WI_rows_per_load##_##address_space##_v8i8_pi32_i32(dst1, mem1, stride, cacheOpt); \
    return;

// This function implements the LOAD operations for Matrix A 32x32
#define DEFINE_LOAD_CHECKED_LARGE_IMPL_2(layout, elem_bitwidth, contrib_type, shape, WI_rows, WI_rows_per_load, column_stride, load_shape) \
  INLINE void __builtin_spriv_OpJointMatrixLoadCheckedINTEL_##layout##_SG16_##shape##_i##elem_bitwidth##_##WI_rows##_v8i8_pi32_i32(__private char *dst, char *mem, int y, int x, int height, int width, long stride, int cacheOpt) { \
      __private char *dst0 = dst; \
      __private char *dst1 = dst + 1 * WI_rows_per_load * (sizeof (contrib_type)); \
\
      __builtin_spriv_OpJointMatrixLoadCheckedINTEL_##layout##_SG16_32x16_i##elem_bitwidth##_##WI_rows_per_load##_v8i8_pi32_i32(dst0, mem, y, x + MEM_OFFSET_ROWMAJ(0, 16, 2, 0), height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixLoadCheckedINTEL_##layout##_SG16_32x16_i##elem_bitwidth##_##WI_rows_per_load##_v8i8_pi32_i32(dst1, mem, y, x + MEM_OFFSET_ROWMAJ(0, 16, 2, 1), height, width, stride, cacheOpt); \
  }

/* Optimization for big shapes 1d load, where number of columns is multiple of sub-group size
   specifically, for sub group size 16 and number of columns 64, we can load 4 elements in one instruction */
#define DEFINE_LOAD_LARGE_IMPL_4_OPTIMIZED_VECTOR_CONT_IMPL(layout, elem_type, contrib_type, R, address_space) \
    if (BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) == VECTOR_CONT_IMPL) { \
      if (_##layout == _Accumulator_RowMajor || _##layout == _PackedB_PackedB) { \
        for (int i = 0; i < R; i++) { \
          uint4 row = intel_sub_group_block_read4((__##address_space uint *)(mem + i * stride * sizeof(elem_type))); \
          *((__private uint *)(dst +  i        * sizeof(contrib_type))) = row.x; \
          *((__private uint *)(dst + (i + R)   * sizeof(contrib_type))) = row.y; \
          *((__private uint *)(dst + (i + R*2) * sizeof(contrib_type))) = row.z; \
          *((__private uint *)(dst + (i + R*3) * sizeof(contrib_type))) = row.w; \
        } \
        return; \
      } \
      /* B row major case - need to VNNI manually */\
      for (int i = 0; i < R; i++) { \
        ushort4 row0 = intel_sub_group_block_read_us4((__##address_space uint *)(mem + (2*i    ) * stride * sizeof(elem_type))); \
        ushort4 row1 = intel_sub_group_block_read_us4((__##address_space uint *)(mem + (2*i + 1) * stride * sizeof(elem_type))); \
        *((__private uint *)(dst +  i        * sizeof(contrib_type))) = as_int((ushort2)(row0.x, row1.x)); \
        *((__private uint *)(dst + (i + R)   * sizeof(contrib_type))) = as_int((ushort2)(row0.y, row1.y)); \
        *((__private uint *)(dst + (i + R*2) * sizeof(contrib_type))) = as_int((ushort2)(row0.z, row1.z)); \
        *((__private uint *)(dst + (i + R*3) * sizeof(contrib_type))) = as_int((ushort2)(row0.w, row1.w)); \
      } \
      return; \
    }

// default implementation for large shapes which is reusing smaller loads
// _4 in the name is for 4 smaller loads
// This function implements the LOAD operations for Matrix B and Martix C for combinations 32x64x16, and 32x32x16
#define DEFINE_LOAD_LARGE_IMPL_4(layout, sg, elem_type, elem_bitwidth, contrib_type, WI_rows_per_load, address_space, row_stride, column_stride, load_shape) \
    __private char *dst0 = dst; \
    __private char *dst1 = dst + 1 * WI_rows_per_load * (sizeof (contrib_type)); \
    __private char *dst2 = dst + 2 * WI_rows_per_load * (sizeof (contrib_type)); \
    __private char *dst3 = dst + 3 * WI_rows_per_load * (sizeof (contrib_type)); \
\
    char *mem0 = mem + MEM_OFFSET4_##layout(row_stride, column_stride, 0) * sizeof(elem_type); \
    char *mem1 = mem + MEM_OFFSET4_##layout(row_stride, column_stride, 1) * sizeof(elem_type); \
    char *mem2 = mem + MEM_OFFSET4_##layout(row_stride, column_stride, 2) * sizeof(elem_type); \
    char *mem3 = mem + MEM_OFFSET4_##layout(row_stride, column_stride, 3) * sizeof(elem_type); \
\
    __builtin_spriv_OpJointMatrixLoadINTEL_##layout##sg##_##load_shape##_i##elem_bitwidth##_##WI_rows_per_load##_##address_space##_v8i8_pi32_i32(dst0, mem0, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixLoadINTEL_##layout##sg##_##load_shape##_i##elem_bitwidth##_##WI_rows_per_load##_##address_space##_v8i8_pi32_i32(dst1, mem1, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixLoadINTEL_##layout##sg##_##load_shape##_i##elem_bitwidth##_##WI_rows_per_load##_##address_space##_v8i8_pi32_i32(dst2, mem2, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixLoadINTEL_##layout##sg##_##load_shape##_i##elem_bitwidth##_##WI_rows_per_load##_##address_space##_v8i8_pi32_i32(dst3, mem3, stride, cacheOpt); \
    return;

#define DEFINE_LOAD_LARGE_IMPL_AS_GENERIC(num_loads, layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, WI_rows_per_load, row_stride, column_stride, load_shape) \
    INLINE void MANGLE_LOAD_NAME_AS_GENERIC(layout, sg, elem_bitwidth, shape, WI_rows) (__private char *dst, char *mem, long stride, int cacheOpt) { \
        __builtin_assume((__global char*)mem != 0); \
        int memIsGlobal = (0 != SPIRV_BUILTIN(GenericCastToPtrExplicit, _p1i8_p4i8_i32, _ToGlobal)(__builtin_astype((mem), __generic char*), StorageWorkgroup)); \
        if (memIsGlobal) { \
            DEFINE_LOAD_LARGE_IMPL_##num_loads##_OPTIMIZED_VECTOR_CONT_IMPL(layout, elem_type, contrib_type, R, global) \
            DEFINE_LOAD_LARGE_IMPL_##num_loads(layout, sg, elem_type, elem_bitwidth, contrib_type, WI_rows_per_load, global, row_stride, column_stride, load_shape) \
        } \
        DEFINE_LOAD_LARGE_IMPL_##num_loads##_OPTIMIZED_VECTOR_CONT_IMPL(layout, elem_type, contrib_type, R, local) \
        DEFINE_LOAD_LARGE_IMPL_##num_loads(layout, sg, elem_type, elem_bitwidth, contrib_type, WI_rows_per_load, local, row_stride, column_stride, load_shape) \
    }

#define DEFINE_LOAD_LARGE_IMPL_AS_LOCAL(num_loads, layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, WI_rows_per_load, row_stride, column_stride, load_shape) \
    INLINE void MANGLE_LOAD_NAME_AS_LOCAL(layout, sg, elem_bitwidth, shape, WI_rows) (__private char *dst, char *mem, long stride, int cacheOpt) { \
        DEFINE_LOAD_LARGE_IMPL_##num_loads##_OPTIMIZED_VECTOR_CONT_IMPL(layout, elem_type, contrib_type, R, local) \
        DEFINE_LOAD_LARGE_IMPL_##num_loads(layout, sg, elem_type, elem_bitwidth, contrib_type, WI_rows_per_load, local, row_stride, column_stride, load_shape) \
    }

#define DEFINE_LOAD_LARGE_IMPL_AS_GLOBAL(num_loads, layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, WI_rows_per_load, row_stride, column_stride, load_shape) \
    INLINE void MANGLE_LOAD_NAME_AS_GLOBAL(layout, sg, elem_bitwidth, shape, WI_rows) (__private char *dst, char *mem, long stride, int cacheOpt) { \
        DEFINE_LOAD_LARGE_IMPL_##num_loads##_OPTIMIZED_VECTOR_CONT_IMPL(layout, elem_type, contrib_type, R, global) \
        DEFINE_LOAD_LARGE_IMPL_##num_loads(layout, sg, elem_type, elem_bitwidth, contrib_type, WI_rows_per_load, global, row_stride, column_stride, load_shape) \
    }

// _4 in the name is for 4 2d block loads
#define DEFINE_LOAD_CHECKED_LARGE_IMPL_4(layout, elem_bitwidth, contrib_type, shape, WI_rows, WI_rows_per_load, column_stride, load_shape) \
  INLINE void __builtin_spriv_OpJointMatrixLoadCheckedINTEL_##layout##_SG16_##shape##_i##elem_bitwidth##_##WI_rows##_v8i8_pi32_i32(__private char *dst, char *mem, int y, int x, int height, int width, long stride, int cacheOpt) { \
      __private char *dst0 = dst; \
      __private char *dst1 = dst + 1 * WI_rows_per_load * (sizeof (contrib_type)); \
      __private char *dst2 = dst + 2 * WI_rows_per_load * (sizeof (contrib_type)); \
      __private char *dst3 = dst + 3 * WI_rows_per_load * (sizeof (contrib_type)); \
      __builtin_spriv_OpJointMatrixLoadCheckedINTEL_##layout##_SG16_##load_shape##_i##elem_bitwidth##_##WI_rows_per_load##_v8i8_pi32_i32(dst0, mem, y, x + MEM_OFFSET4_##layout(0, column_stride, 0), height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixLoadCheckedINTEL_##layout##_SG16_##load_shape##_i##elem_bitwidth##_##WI_rows_per_load##_v8i8_pi32_i32(dst1, mem, y, x + MEM_OFFSET4_##layout(0, column_stride, 1), height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixLoadCheckedINTEL_##layout##_SG16_##load_shape##_i##elem_bitwidth##_##WI_rows_per_load##_v8i8_pi32_i32(dst2, mem, y, x + MEM_OFFSET4_##layout(0, column_stride, 2), height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixLoadCheckedINTEL_##layout##_SG16_##load_shape##_i##elem_bitwidth##_##WI_rows_per_load##_v8i8_pi32_i32(dst3, mem, y, x + MEM_OFFSET4_##layout(0, column_stride, 3), height, width, stride, cacheOpt); \
  }

#define DEFINE_LOAD_LARGE__(layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, num_loads, WI_rows_per_load, row_stride, column_stride) \
  DEFINE_LOAD_LARGE_IMPL_AS_GENERIC(num_loads, layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, WI_rows_per_load, row_stride, column_stride, SHAPE(layout, row_stride, column_stride, elem_type, contrib_type)) \
  DEFINE_LOAD_LARGE_IMPL_AS_LOCAL(num_loads, layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, WI_rows_per_load, row_stride, column_stride, SHAPE(layout, row_stride, column_stride, elem_type, contrib_type)) \
  DEFINE_LOAD_LARGE_IMPL_AS_GLOBAL(num_loads, layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, WI_rows_per_load, row_stride, column_stride, SHAPE(layout, row_stride, column_stride, elem_type, contrib_type))

#define DEFINE_LOAD_CHECKED_LARGE_IMPL_(layout, elem_bitwidth, contrib_type, shape, WI_rows, num_loads, WI_rows_per_load, column_stride, load_shape) \
  DEFINE_LOAD_CHECKED_LARGE_IMPL_##num_loads(layout, elem_bitwidth, contrib_type, shape, WI_rows, WI_rows_per_load, column_stride, load_shape)

#define DEFINE_LOAD_CHECKED_LARGE__(layout, elem_type, elem_bitwidth, contrib_type, shape, WI_rows, num_loads, WI_rows_per_load, row_stride, column_stride) \
  DEFINE_LOAD_CHECKED_LARGE_IMPL_(layout, elem_bitwidth, contrib_type, shape, WI_rows, num_loads, WI_rows_per_load, column_stride, SHAPE(layout, row_stride, column_stride, elem_type, contrib_type))

#define DEFINE_LOAD_LARGE(layout, sg, elem_type, contrib_type, R, C, WI_rows, num_loads) \
  DEFINE_LOAD_LARGE__(layout, sg, elem_type, BITWIDTH(elem_type), contrib_type, R, SHAPE(layout, R, C, elem_type, contrib_type), WI_rows, num_loads, MATH_DIV(WI_rows, num_loads), ROW_STRIDE(layout, R, C, num_loads), COLUMN_STRIDE(layout, R, C, num_loads))

#define DEFINE_LOAD_CHECKED_LARGE(layout, elem_type, contrib_type, R, C, WI_rows, num_loads) \
  DEFINE_LOAD_CHECKED_LARGE__(layout, elem_type, BITWIDTH(elem_type), contrib_type, SHAPE(layout, R, C, elem_type, contrib_type), WI_rows, num_loads, MATH_DIV(WI_rows, num_loads), ROW_STRIDE(layout, R, C, num_loads), COLUMN_STRIDE(layout, R, C, num_loads))

#define DEFINE_LOAD_AND_CHECKED_LARGE(layout, sg, elem_type, contrib_type, R, C, WI_rows, num_loads) \
    DEFINE_LOAD_LARGE(layout, sg, elem_type, contrib_type, R, C, WI_rows, num_loads) \
    DEFINE_LOAD_CHECKED_LARGE(layout, elem_type, contrib_type, R, C, WI_rows, num_loads)

/* PackedA load i16 SG16 */
// technically it can be implemented using 1 load 32x32, but in that case to put together
// 8 matrices for dpas, we would need 64 mov instructions
// each matrix would be composed like that: (wi[0], wi[2], ..., wi[14]), (wi[1], wi[3], ..., wi[15]), ...
// since only 16 elements are contiguous in memory for each 8x16 matrix for dpas
// hence implementing load as 2 loads 32x16. That way we get 2 contiguous (for dpas) matrices,
// which can be easily split on 4 8x16 matrices each.
DEFINE_LOAD_AND_CHECKED_LARGE(PackedA_RowMajor,    _SG16, short, short, 32, 32, 64, 2)

/* PackedB load i16 */
DEFINE_LOAD_LARGE(PackedB_PackedB,  ,   short, int,  8,  64,   32, 4)
DEFINE_LOAD_LARGE(PackedB_RowMajor, ,   short, int,  8,  64,   32, 4)

/* PackedB load i16 SG16 */
DEFINE_LOAD_AND_CHECKED_LARGE(PackedB_PackedB,     _SG16, short, int,  8, 128,  32, 4)
DEFINE_LOAD_AND_CHECKED_LARGE(PackedB_PackedB,     _SG16, short, int, 16, 128,  64, 4)
DEFINE_LOAD_AND_CHECKED_LARGE(PackedB_RowMajor,    _SG16, short, int,  8, 128,  32, 4)
DEFINE_LOAD_AND_CHECKED_LARGE(PackedB_RowMajor,    _SG16, short, int, 16, 128,  64, 4)

/* Accumulator load i32 */
DEFINE_LOAD_LARGE(Accumulator_RowMajor, , int, int, 32,  32,  128, 4)

/* Accumulator load i32 SG16 */
DEFINE_LOAD_AND_CHECKED_LARGE(Accumulator_RowMajor,  _SG16, int, int, 32,  64, 128, 4)

#define DEFINE_STORE_LARGE_IMPL_2_OPT_VEC_CONT_IMPL(layout, elem_type, contrib_type, R, address_space) \
  /* Not applicable, fallthrough */

// _2 suffix in the name indicates that the function is using 2 stores
// This function implements the STORE operations for PackedA_RowMajor 16x16, and Accumulator_RowMajor 16x16 matrix formats
#define DEFINE_STORE_LARGE_IMPL_2(layout, sg, element_type, elem_bitwidth, contrib_type, shape, WI_rows, address_space, row_stride, column_stride, store_shape) \
    __private char *c0 = src + 0 * 8 * (sizeof (contrib_type)); \
    __private char *c1 = src + 1 * 8 * (sizeof (contrib_type)); \
\
    char *mem0 = mem; \
    char *mem1 = mem + row_stride * stride * sizeof(element_type); \
\
    __builtin_spriv_OpJointMatrixStoreINTEL_##layout##sg##_##store_shape##_i##elem_bitwidth##_8_##address_space##_pi64_v8i8(mem0, c0, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_##layout##sg##_##store_shape##_i##elem_bitwidth##_8_##address_space##_pi64_v8i8(mem1, c1, stride, cacheOpt); \
    return;

// Optimization for big shapes 1d load, where number of columns, converted to contrib type is multiple of sub-group size
// Specifically: for sub group size 16 (8) and number of columns 64 (32), we can store 4 elements in one instruction
// This function implements the STORE operations for PackedB_PackedB 16x32, PackedB_RowMajor 16x32, PackedB_PackedB 16x64
#define DEFINE_STORE_LARGE_IMPL_4_OPT_VEC_CONT_IMPL(layout, elem_type, contrib_type, R, address_space) \
    if (BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) == VECTOR_CONT_IMPL || \
        /* 2d block store doesn't support transpose/transform, so this is the most optimized variant for B row major */ \
        BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) > VECTOR_CONT_IMPL && _##layout == _PackedB_RowMajor) { \
      if (_##layout == _Accumulator_RowMajor || _##layout == _PackedB_PackedB) { \
        for (int i = 0; i < R; i++) { \
            uint src0 = *((uint*)(src +  i          * sizeof(contrib_type))); \
            uint src1 = *((uint*)(src + (i + R)     * sizeof(contrib_type))); \
            uint src2 = *((uint*)(src + (i + R * 2) * sizeof(contrib_type))); \
            uint src3 = *((uint*)(src + (i + R * 3) * sizeof(contrib_type))); \
            uint4 row = (uint4)(src0, src1, src2, src3); \
            intel_sub_group_block_write4((__##address_space uint *)(mem + i * stride * sizeof(elem_type)), row); \
        } \
        return; \
      } \
      /* B row major case - need to convert from VNNI to row major layout */ \
      if (_##layout == _PackedB_RowMajor) { \
        for (int i = 0; i < R; i++) { \
            uint src0 = *((uint*)(src +  i          * sizeof(contrib_type))); \
            uint src1 = *((uint*)(src + (i + R)     * sizeof(contrib_type))); \
            uint src2 = *((uint*)(src + (i + R * 2) * sizeof(contrib_type))); \
            uint src3 = *((uint*)(src + (i + R * 3) * sizeof(contrib_type))); \
\
            ushort2 src0us2 = as_ushort2(src0); \
            ushort2 src1us2 = as_ushort2(src1); \
            ushort2 src2us2 = as_ushort2(src2); \
            ushort2 src3us2 = as_ushort2(src3); \
\
            ushort4 row0 = (ushort4)(src0us2.x, src1us2.x, src2us2.x, src3us2.x); \
            ushort4 row1 = (ushort4)(src0us2.y, src1us2.y, src2us2.y, src3us2.y); \
            intel_sub_group_block_write_us4((__##address_space ushort *)(mem + (2*i  ) * stride * sizeof(elem_type)), row0); \
            intel_sub_group_block_write_us4((__##address_space ushort *)(mem + (2*i+1) * stride * sizeof(elem_type)), row1); \
        } \
        return; \
      } \
      /* fall through for anything else not supported */ \
    }

// _4 suffix in the name indicates that the function is using 4 stores
// This function implements the STORE operations for PackedA_RowMajor 32x16, PackedB_PackedB 16x64, PackedB_RowMajor 16x64,
// PackedB_PackedB 16x32, and PackedB_RowMajor 16x32 matrix formats.
#define DEFINE_STORE_LARGE_IMPL_4(layout, sg, element_type, elem_bitwidth, contrib_type, shape, WI_rows, address_space, row_stride, column_stride, store_shape) \
    __private char *c0 = src + 0 * 8 * (sizeof (contrib_type)); \
    __private char *c1 = src + 1 * 8 * (sizeof (contrib_type)); \
    __private char *c2 = src + 2 * 8 * (sizeof (contrib_type)); \
    __private char *c3 = src + 3 * 8 * (sizeof (contrib_type)); \
\
    char *mem0 = mem; \
    char *mem1 = mem + MEM_OFFSET4_##layout(row_stride, column_stride, 1) * sizeof(element_type);\
    char *mem2 = mem + MEM_OFFSET4_##layout(row_stride, column_stride, 2) * sizeof(element_type);\
    char *mem3 = mem + MEM_OFFSET4_##layout(row_stride, column_stride, 3) * sizeof(element_type);\
\
    __builtin_spriv_OpJointMatrixStoreINTEL_##layout##sg##_##store_shape##_i##elem_bitwidth##_8_##address_space##_pi64_v8i8(mem0, c0, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_##layout##sg##_##store_shape##_i##elem_bitwidth##_8_##address_space##_pi64_v8i8(mem1, c1, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_##layout##sg##_##store_shape##_i##elem_bitwidth##_8_##address_space##_pi64_v8i8(mem2, c2, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_##layout##sg##_##store_shape##_i##elem_bitwidth##_8_##address_space##_pi64_v8i8(mem3, c3, stride, cacheOpt); \
    return;

// Optimization for big shapes 1d store, where number of columns, converted to contrib type is multiple of sub-group size
// Specifically: for sub group size 16 and number of columns 32, we can store 2 elements in one instruction
// This function implements the STORE operations for PackedA_RowMajor 32x32, PackedB_PackedB 32x64,
// PackedB_RowMajor 32x64 matrix formats for sub-group size 16
#define DEFINE_STORE_LARGE_IMPL_8_OPT_VEC_CONT_IMPL(layout, elem_type, contrib_type, R, address_space) \
    if (BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) == VECTOR_CONT_IMPL) { \
      if (_##layout == _PackedA_RowMajor) { \
        for (int i = 0; i < R; i++) { \
            ushort src0 = *((ushort*)(src + i * sizeof(contrib_type))); \
            ushort src1 = *((ushort*)(src + (R + i) * sizeof(contrib_type))); \
            ushort2 row = (ushort2)(src0, src1); \
            intel_sub_group_block_write_us2((__##address_space ushort *)(mem + i * stride * sizeof(elem_type)), row); \
        } \
        return; \
      } \
    } \
    /* _PackedB_RowMajor and _PackedB_PackedB implementation is the same as for 4 stores */ \
    DEFINE_STORE_LARGE_IMPL_4_OPT_VEC_CONT_IMPL(layout, elem_type, contrib_type, R, address_space)

// _8 suffix in the name indicates that function is using 8 stores
// This function implements the STORE operations for PackedA_RowMajor 32x32 and PackedB_PackedB 32x64 matrix formats for sub-group size 16
#define DEFINE_STORE_LARGE_IMPL_8(layout, sg, element_type, elem_bitwidth, contrib_type, shape, WI_rows, address_space, row_stride, column_stride, store_shape) \
    for (int i = 0; i < 8; i++) { \
        __private char *c = src + i * 8 * (sizeof (contrib_type)); \
        char *mem_w_offset = mem + MEM_OFFSET8_##layout(row_stride, column_stride, i) * sizeof(element_type); \
        __builtin_spriv_OpJointMatrixStoreINTEL_##layout##sg##_##store_shape##_i##elem_bitwidth##_8_##address_space##_pi64_v8i8(mem_w_offset, c, stride, cacheOpt); \
    } \
    return;

// Optimization for big shapes 1d load, where number of columns is multiple of sub-group size
// Specifically: for sub group size 16 (8) and number of columns 64 (32), we can store 4 elements in one instruction
// This function implements the STORE operations for Accumulator_RowMajor 32x64, and Accumulator_RowMajor 32x32 matrix formats
#define DEFINE_STORE_LARGE_IMPL_16_OPT_VEC_CONT_IMPL(layout, elem_type, contrib_type, R, address_space) \
    DEFINE_STORE_LARGE_IMPL_4_OPT_VEC_CONT_IMPL(layout, elem_type, contrib_type, R, address_space)

// _16 suffix in the name indicates that the function is using 16 stores
// This function implements the STORE operations for Accumulator_RowMajor 32x64, and Accumulator_RowMajor 32x32 matrix formats
#define DEFINE_STORE_LARGE_IMPL_16(layout, sg, element_type, elem_bitwidth, contrib_type, shape, WI_rows, address_space, row_stride, column_stride, store_shape) \
    __private char *c0 = src + 0 * 8 * (sizeof (contrib_type)); \
    __private char *c1 = src + 1 * 8 * (sizeof (contrib_type)); \
    __private char *c2 = src + 2 * 8 * (sizeof (contrib_type)); \
    __private char *c3 = src + 3 * 8 * (sizeof (contrib_type)); \
    __private char *c4 = src + 4 * 8 * (sizeof (contrib_type)); \
    __private char *c5 = src + 5 * 8 * (sizeof (contrib_type)); \
    __private char *c6 = src + 6 * 8 * (sizeof (contrib_type)); \
    __private char *c7 = src + 7 * 8 * (sizeof (contrib_type)); \
    __private char *c8 = src + 8 * 8 * (sizeof (contrib_type)); \
    __private char *c9 = src + 9 * 8 * (sizeof (contrib_type)); \
    __private char *c10 = src + 10 * 8 * (sizeof (contrib_type)); \
    __private char *c11 = src + 11 * 8 * (sizeof (contrib_type)); \
    __private char *c12 = src + 12 * 8 * (sizeof (contrib_type)); \
    __private char *c13 = src + 13 * 8 * (sizeof (contrib_type)); \
    __private char *c14 = src + 14 * 8 * (sizeof (contrib_type)); \
    __private char *c15 = src + 15 * 8 * (sizeof (contrib_type)); \
\
    char *mem0 = mem; \
    char *mem1 = mem + 0 * column_stride * (sizeof (element_type)) + 1 * row_stride * stride * (sizeof (element_type)); \
    char *mem2 = mem + 0 * column_stride * (sizeof (element_type)) + 2 * row_stride * stride * (sizeof (element_type)); \
    char *mem3 = mem + 0 * column_stride * (sizeof (element_type)) + 3 * row_stride * stride * (sizeof (element_type)); \
    char *mem4 = mem + 1 * column_stride * (sizeof (element_type)); \
    char *mem5 = mem + 1 * column_stride * (sizeof (element_type)) + 1 * row_stride * stride * (sizeof (element_type)); \
    char *mem6 = mem + 1 * column_stride * (sizeof (element_type)) + 2 * row_stride * stride * (sizeof (element_type)); \
    char *mem7 = mem + 1 * column_stride * (sizeof (element_type)) + 3 * row_stride * stride * (sizeof (element_type)); \
    char *mem8 = mem + 2 * column_stride * (sizeof (element_type)); \
    char *mem9 = mem + 2 * column_stride * (sizeof (element_type)) + 1 * row_stride * stride * (sizeof (element_type)); \
    char *mem10 = mem + 2 * column_stride * (sizeof (element_type)) + 2 * row_stride * stride * (sizeof (element_type)); \
    char *mem11 = mem + 2 * column_stride * (sizeof (element_type)) + 3 * row_stride * stride * (sizeof (element_type)); \
    char *mem12 = mem + 3 * column_stride * (sizeof (element_type)); \
    char *mem13 = mem + 3 * column_stride * (sizeof (element_type)) + 1 * row_stride * stride * (sizeof (element_type)); \
    char *mem14 = mem + 3 * column_stride * (sizeof (element_type)) + 2 * row_stride * stride * (sizeof (element_type)); \
    char *mem15 = mem + 3 * column_stride * (sizeof (element_type)) + 3 * row_stride * stride * (sizeof (element_type)); \
\
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem0, c0, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem1, c1, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem2, c2, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem3, c3, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem4, c4, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem5, c5, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem6, c6, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem7, c7, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem8, c8, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem9, c9, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem10, c10, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem11, c11, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem12, c12, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem13, c13, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem14, c14, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor##sg##_##store_shape##_i32_8_##address_space##_pi64_v8i8(mem15, c15, stride, cacheOpt); \
    return;

// _2 suffix in the name indicates that the function is using 2 2d block stores
#define DEFINE_STORE_CHECKED_LARGE_IMPL_2(layout, elem_bitwidth, contrib_type, shape, WI_rows, row_stride, column_stride, store_shape) \
    INLINE void MANGLE_STORE_CHECKED_NAME(layout, _SG16, elem_bitwidth, shape, WI_rows) (char *mem, __private char *src, int y, int x, int height, int width, long stride, int cacheOpt) { \
        __private char *c0 = src + 0 * 8 * (sizeof (contrib_type)); \
        __private char *c1 = src + 1 * 8 * (sizeof (contrib_type)); \
        __builtin_spriv_OpJointMatrixStoreCheckedINTEL_##layout##_SG16_##store_shape##_i##elem_bitwidth##_8_pi64_v8i8(mem, c0, y + 0 * row_stride, x, height, width, stride, cacheOpt); \
        __builtin_spriv_OpJointMatrixStoreCheckedINTEL_##layout##_SG16_##store_shape##_i##elem_bitwidth##_8_pi64_v8i8(mem, c1, y + 1 * row_stride, x, height, width, stride, cacheOpt); \
    }

// _4 suffix in the name indicates that the function is using 4 2d block stores
#define DEFINE_STORE_CHECKED_LARGE_IMPL_4(layout, elem_bitwidth, contrib_type, shape, WI_rows, row_stride, column_stride, store_shape) \
    INLINE void MANGLE_STORE_CHECKED_NAME(layout, _SG16, elem_bitwidth, shape, WI_rows) (char *mem, __private char *src, int y, int x, int height, int width, long stride, int cacheOpt) { \
        __private char *c0 = src + 0 * 8 * (sizeof (contrib_type)); \
        __private char *c1 = src + 1 * 8 * (sizeof (contrib_type)); \
        __private char *c2 = src + 2 * 8 * (sizeof (contrib_type)); \
        __private char *c3 = src + 3 * 8 * (sizeof (contrib_type)); \
    \
        if (_##layout == _PackedA_RowMajor) { \
            __builtin_spriv_OpJointMatrixStoreCheckedINTEL_##layout##_SG16_##store_shape##_i##elem_bitwidth##_8_pi64_v8i8(mem, c0, y + 0 * row_stride, x, height, width, stride, cacheOpt); \
            __builtin_spriv_OpJointMatrixStoreCheckedINTEL_##layout##_SG16_##store_shape##_i##elem_bitwidth##_8_pi64_v8i8(mem, c1, y + 1 * row_stride, x, height, width, stride, cacheOpt); \
            __builtin_spriv_OpJointMatrixStoreCheckedINTEL_##layout##_SG16_##store_shape##_i##elem_bitwidth##_8_pi64_v8i8(mem, c2, y + 2 * row_stride, x, height, width, stride, cacheOpt); \
            __builtin_spriv_OpJointMatrixStoreCheckedINTEL_##layout##_SG16_##store_shape##_i##elem_bitwidth##_8_pi64_v8i8(mem, c3, y + 3 * row_stride, x, height, width, stride, cacheOpt); \
            return; \
        } \
        __builtin_spriv_OpJointMatrixStoreCheckedINTEL_##layout##_SG16_##store_shape##_i##elem_bitwidth##_8_pi64_v8i8(mem, c0, y, x + MEM_OFFSET4_##layout(row_stride, column_stride, 0), height, width, stride, cacheOpt); \
        __builtin_spriv_OpJointMatrixStoreCheckedINTEL_##layout##_SG16_##store_shape##_i##elem_bitwidth##_8_pi64_v8i8(mem, c1, y, x + MEM_OFFSET4_##layout(row_stride, column_stride, 1), height, width, stride, cacheOpt); \
        __builtin_spriv_OpJointMatrixStoreCheckedINTEL_##layout##_SG16_##store_shape##_i##elem_bitwidth##_8_pi64_v8i8(mem, c2, y, x + MEM_OFFSET4_##layout(row_stride, column_stride, 2), height, width, stride, cacheOpt); \
        __builtin_spriv_OpJointMatrixStoreCheckedINTEL_##layout##_SG16_##store_shape##_i##elem_bitwidth##_8_pi64_v8i8(mem, c3, y, x + MEM_OFFSET4_##layout(row_stride, column_stride, 3), height, width, stride, cacheOpt); \
    }

// _8 suffix in the name indicates that the function is using 8 stores
#define DEFINE_STORE_CHECKED_LARGE_IMPL_8(layout, elem_bitwidth, contrib_type, shape, WI_rows, row_stride, column_stride, store_shape) \
  INLINE void MANGLE_STORE_CHECKED_NAME(layout, _SG16, elem_bitwidth, shape, WI_rows) (char *mem, __private char *src, int y, int x, int height, int width, long stride, int cacheOpt) { \
    int VF = (_##layout == _PackedB_RowMajor) ? 2 : 1; \
    for (int i = 0; i < 8; i++) { \
        __private char *c = src + i * 8 * (sizeof (contrib_type)); \
        if (_##layout == _PackedA_RowMajor) \
            __builtin_spriv_OpJointMatrixStoreCheckedINTEL_##layout##_SG16_##store_shape##_i##elem_bitwidth##_8_pi64_v8i8(mem, c, y + (i % 4) * row_stride, x + (i / 4) * column_stride, height, width, stride, cacheOpt); \
        else \
            __builtin_spriv_OpJointMatrixStoreCheckedINTEL_##layout##_SG16_##store_shape##_i##elem_bitwidth##_8_pi64_v8i8(mem, c, y + (i % 2) * row_stride * VF, x + (i / 2) * column_stride / VF, height, width, stride, cacheOpt); \
    } \
  }

// _16 suffix in the name indicates that the function is using 16 stores
#define DEFINE_STORE_CHECKED_LARGE_IMPL_16(layout, elem_bitwidth, contrib_type, shape, WI_rows, row_stride, column_stride, store_shape) \
  INLINE void MANGLE_STORE_CHECKED_NAME(layout, _SG16, elem_bitwidth, shape, WI_rows) (char *mem, __private char *src, int y, int x, int height, int width, long stride, int cacheOpt) { \
      __private char *c0 = src + 0 * 8 * (sizeof (contrib_type)); \
      __private char *c1 = src + 1 * 8 * (sizeof (contrib_type)); \
      __private char *c2 = src + 2 * 8 * (sizeof (contrib_type)); \
      __private char *c3 = src + 3 * 8 * (sizeof (contrib_type)); \
      __private char *c4 = src + 4 * 8 * (sizeof (contrib_type)); \
      __private char *c5 = src + 5 * 8 * (sizeof (contrib_type)); \
      __private char *c6 = src + 6 * 8 * (sizeof (contrib_type)); \
      __private char *c7 = src + 7 * 8 * (sizeof (contrib_type)); \
      __private char *c8 = src + 8 * 8 * (sizeof (contrib_type)); \
      __private char *c9 = src + 9 * 8 * (sizeof (contrib_type)); \
      __private char *c10 = src + 10 * 8 * (sizeof (contrib_type)); \
      __private char *c11 = src + 11 * 8 * (sizeof (contrib_type)); \
      __private char *c12 = src + 12 * 8 * (sizeof (contrib_type)); \
      __private char *c13 = src + 13 * 8 * (sizeof (contrib_type)); \
      __private char *c14 = src + 14 * 8 * (sizeof (contrib_type)); \
      __private char *c15 = src + 15 * 8 * (sizeof (contrib_type)); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c0, y + 0 * row_stride, x + 0 * column_stride, height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c1, y + 1 * row_stride, x + 0 * column_stride, height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c2, y + 2 * row_stride, x + 0 * column_stride, height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c3, y + 3 * row_stride, x + 0 * column_stride, height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c4, y + 0 * row_stride, x + 1 * column_stride, height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c5, y + 1 * row_stride, x + 1 * column_stride, height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c6, y + 2 * row_stride, x + 1 * column_stride, height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c7, y + 3 * row_stride, x + 1 * column_stride, height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c8, y + 0 * row_stride, x + 2 * column_stride, height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c9, y + 1 * row_stride, x + 2 * column_stride, height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c10, y + 2 * row_stride, x + 2 * column_stride, height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c11, y + 3 * row_stride, x + 2 * column_stride, height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c12, y + 0 * row_stride, x + 3 * column_stride, height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c13, y + 1 * row_stride, x + 3 * column_stride, height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c14, y + 2 * row_stride, x + 3 * column_stride, height, width, stride, cacheOpt); \
      __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_##store_shape##_i32_8_pi64_v8i8(mem, c15, y + 3 * row_stride, x + 3 * column_stride, height, width, stride, cacheOpt); \
  }

#define DEFINE_STORE_LARGE_IMPL_AS_GENERIC(layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, row_stride, column_stride, store_shape, num_stores) \
    INLINE void MANGLE_STORE_NAME(layout, sg, elem_bitwidth, shape, WI_rows, generic) (char *mem, __private char *src, long stride, int cacheOpt) { \
        __builtin_assume((__global char*)mem != 0); \
        int memIsGlobal = (0 != SPIRV_BUILTIN(GenericCastToPtrExplicit, _p1i8_p4i8_i32, _ToGlobal)(__builtin_astype((mem), __generic char*), StorageWorkgroup)); \
        if (memIsGlobal) { \
            DEFINE_STORE_LARGE_IMPL_##num_stores##_OPT_VEC_CONT_IMPL(layout, elem_type, contrib_type, R, global) \
            DEFINE_STORE_LARGE_IMPL_##num_stores(layout, sg, elem_type, elem_bitwidth, contrib_type, shape, WI_rows, global, row_stride, column_stride, store_shape) \
        } \
        DEFINE_STORE_LARGE_IMPL_##num_stores##_OPT_VEC_CONT_IMPL(layout, elem_type, contrib_type, R, local) \
        DEFINE_STORE_LARGE_IMPL_##num_stores(layout, sg, elem_type, elem_bitwidth, contrib_type, shape, WI_rows, local, row_stride, column_stride, store_shape) \
    }

#define DEFINE_STORE_LARGE_IMPL_AS_LOCAL(layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, row_stride, column_stride, store_shape, num_stores) \
    INLINE void MANGLE_STORE_NAME(layout, sg, elem_bitwidth, shape, WI_rows, local) (char *mem, __private char *src, long stride, int cacheOpt) { \
        DEFINE_STORE_LARGE_IMPL_##num_stores##_OPT_VEC_CONT_IMPL(layout, elem_type, contrib_type, R, local) \
        DEFINE_STORE_LARGE_IMPL_##num_stores(layout, sg, elem_type, elem_bitwidth, contrib_type, shape, WI_rows, local, row_stride, column_stride, store_shape) \
    }

#define DEFINE_STORE_LARGE_IMPL_AS_GLOBAL(layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, row_stride, column_stride, store_shape, num_stores) \
    INLINE void MANGLE_STORE_NAME(layout, sg, elem_bitwidth, shape, WI_rows, global) (char *mem, __private char *src, long stride, int cacheOpt) { \
        DEFINE_STORE_LARGE_IMPL_##num_stores##_OPT_VEC_CONT_IMPL(layout, elem_type, contrib_type, R, global) \
        DEFINE_STORE_LARGE_IMPL_##num_stores(layout, sg, elem_type, elem_bitwidth, contrib_type, shape, WI_rows, global, row_stride, column_stride, store_shape) \
    }

#define DEFINE_STORE_LARGE_IMPL_(layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, num_stores, row_stride, column_stride, store_shape) \
  DEFINE_STORE_LARGE_IMPL_AS_GENERIC(layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, row_stride, column_stride, store_shape, num_stores) \
  DEFINE_STORE_LARGE_IMPL_AS_LOCAL(  layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, row_stride, column_stride, store_shape, num_stores) \
  DEFINE_STORE_LARGE_IMPL_AS_GLOBAL( layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, row_stride, column_stride, store_shape, num_stores)

#define DEFINE_STORE_CHECKED_LARGE_IMPL_(layout, elem_bitwidth, contrib_type, shape, WI_rows, num_stores, row_stride, column_stride, store_shape) \
    DEFINE_STORE_CHECKED_LARGE_IMPL_##num_stores(layout, elem_bitwidth, contrib_type, shape, WI_rows, row_stride, column_stride, store_shape)

#define DEFINE_STORE_LARGE__(layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, num_stores, row_stride, column_stride)\
    DEFINE_STORE_LARGE_IMPL_(layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, num_stores, row_stride, column_stride, SHAPE(layout, row_stride, column_stride, elem_type, contrib_type))

#define DEFINE_STORE_CHECKED_LARGE__(layout, elem_type, elem_bitwidth, contrib_type, shape, WI_rows, num_stores, row_stride, column_stride) \
  DEFINE_STORE_CHECKED_LARGE_IMPL_(layout, elem_bitwidth, contrib_type, shape, WI_rows, num_stores, row_stride, column_stride, SHAPE(layout, row_stride, column_stride, elem_type, contrib_type))

#define DEFINE_STORE_LARGE_(layout, sg, elem_type, elem_bitwidth, contrib_type, contrib_bitwidth, R, C, shape, WI_rows, num_stores) \
  DEFINE_STORE_LARGE__(layout, sg, elem_type, elem_bitwidth, contrib_type, R, shape, WI_rows, num_stores, ROW_STRIDE(layout, R, C, num_stores), COLUMN_STRIDE(layout, R, C, num_stores))

#define DEFINE_STORE_CHECKED_LARGE_(layout, elem_type, elem_bitwidth, contrib_type, R, C, shape, WI_rows, num_stores) \
  DEFINE_STORE_CHECKED_LARGE__(layout, elem_type, elem_bitwidth, contrib_type,  shape, WI_rows, num_stores, ROW_STRIDE(layout, R, C, num_stores), COLUMN_STRIDE(layout, R, C, num_stores))

#define DEFINE_STORE_LARGE(layout, sg, elem_type, contrib_type, R, C, WI_rows) \
  DEFINE_STORE_LARGE_(layout, sg, elem_type, BITWIDTH(elem_type), contrib_type, BITWIDTH(contrib_type), R, C, SHAPE(layout, R, C, elem_type, contrib_type), WI_rows, MATH_DIV(WI_rows, 8))

#define DEFINE_STORE_CHECKED_LARGE(layout, elem_type, contrib_type, R, C,  WI_rows) \
  DEFINE_STORE_CHECKED_LARGE_(layout, elem_type, BITWIDTH(elem_type), contrib_type, R, C, SHAPE(layout, R, C, elem_type, contrib_type), WI_rows, MATH_DIV(WI_rows, 8))

#define DEFINE_STORE_AND_CHECKED_LARGE(layout, sg, elem_type, contrib_type, R, C, WI_rows) \
  DEFINE_STORE_LARGE(layout, sg, elem_type, contrib_type, R, C, WI_rows) \
  DEFINE_STORE_CHECKED_LARGE(layout, elem_type, contrib_type, R, C, WI_rows)

/* PackedA i16 */
DEFINE_STORE_LARGE(PackedA_RowMajor, ,  short,  int,  32, 16, 32) // 4 stores in default impl, no 1d optimization possible

/* PackedA i16 SG16 */
DEFINE_STORE_AND_CHECKED_LARGE(PackedA_RowMajor,  _SG16,   short, short, 16, 16,  16) // 2 stores in default impl, no 1d optimization possible
DEFINE_STORE_AND_CHECKED_LARGE(PackedA_RowMajor,  _SG16,   short, short, 32, 16,  32) // 4 stores in default impl, no 1d optimization possible
DEFINE_STORE_AND_CHECKED_LARGE(PackedA_RowMajor,  _SG16,   short, short, 32, 32,  64) // 8 stores in default impl, 1d can be optimized with 2 stores at one op

/* PackedB i16 */
DEFINE_STORE_LARGE(PackedB_PackedB, ,   short,   int,   8, 64, 32) // 4 stores in default impl, 1d optimized with 4 stores at one op
DEFINE_STORE_LARGE(PackedB_RowMajor, ,  short,   int,   8, 64, 32) // 4 stores in default impl, 1d optimized with 2 stores at one op

/* PackedB i16 SG16 */
DEFINE_STORE_AND_CHECKED_LARGE(PackedB_PackedB,  _SG16,  short,   int,  8, 128,  32) // 4 stores in default impl, 1d optimized with 4 stores at one op
DEFINE_STORE_LARGE(PackedB_RowMajor, _SG16,  short,   int,  8, 128,  32) // 4 stores in default impl, 1d optimized with 4 stores at one op
DEFINE_STORE_AND_CHECKED_LARGE(PackedB_PackedB,  _SG16,  short,   int, 16, 128,  64) // 8 stores in default impl, 1d optimized with 4 stores at one op
DEFINE_STORE_LARGE(PackedB_RowMajor, _SG16,  short,   int, 16, 128,  64) // 8 stores in default impl, 1d optimized with 4 stores at one op

/* Accumulator i32 */
DEFINE_STORE_LARGE(Accumulator_RowMajor, ,   int,   int,  32, 32, 128) // 16 stores in default impl, 1d optimized with 4 stores at one op

/* Accumulator i32 SG16 */
DEFINE_STORE_AND_CHECKED_LARGE(Accumulator_RowMajor,  _SG16, int,   int,   16, 16,  16) // 2 stores in default impl, no 1d optimization possible
DEFINE_STORE_AND_CHECKED_LARGE(Accumulator_RowMajor,  _SG16, int,   int,   32, 64, 128) // 16 stores in default impl, 1d optimized with 4 stores at one op

// special case for 1x64 C load and store
// Joint Matrices are expected to be contiguous in memory, without padding at the end of a row
// hence, we can load 1x64 shape using single 2d block load of shape 4x16 instead of 4 1x16 loads
// or 1 block read4 instead of 4 block read by 1 element

#define DEFINE_LOAD_LARGE_BLOCK2D_IMPL_1() \
    if (BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) >= BLOCK2D_IMPL) { \
      long offset = as_long(mem); \
      long baseoffset = offset & (~0x3f); /* align to 64-byte */ \
      int width = sizeof(int) * 16 - 1; /* load 1x64 as 4x16, hence, width is 16 int in bytes */ \
      int height = 4 - 1; /* row count */ \
      int pitch = width; /* JointMatrices are expected to be contiguous in memory, without padding at the end of a row */ \
      long x = (offset - baseoffset) / sizeof(int); /* in elements */ \
      int2 coords = (int2)(x, 0); \
      uint4 __builtin_IB_subgroup_block_read_flat_u32_wi4_m4k16v1(long, int, int, int, int2, int); \
      uint4 res = __builtin_IB_subgroup_block_read_flat_u32_wi4_m4k16v1(baseoffset, width, height, pitch, coords, cacheOpt); \
      *(__private uint4 *)dst = res; \
      return; \
    }

#define DEFINE_LOAD_LARGE_VECTORS_IMPL_1(address_space) \
    if(BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) >= VECTOR_CONT_IMPL) { \
        *(__private uint4 *)dst = intel_sub_group_block_read4((__##address_space uint *)mem); \
        return; \
    } \
    if(BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) >= VECTOR_IMPL) { \
        SUB_GROUP_LOAD(intel_sub_group_block_read, 4, 4, (__##address_space uint *)mem, dst, 16, int); \
        return; \
    }

#define DEFINE_LOAD_LARGE_SCALAR_IMPL_1() \
    int *ptr = (int *)mem; \
    int slid = get_sub_group_local_id(); \
    __private int *wi_contrib = (__private int *)dst; \
    for (int i = 0; i < 4; i++) \
      wi_contrib[i] = ptr[i*16 + slid];

#define DEFINE_LOAD_CHECKED_LARGE_BLOCK2D_IMPL_1() \
    /* load 1x64 as 4 loads 1x16 */ \
    __private char *dst0 = dst + 0 * 1 * sizeof(int); \
    __private char *dst1 = dst + 1 * 1 * sizeof(int); \
    __private char *dst2 = dst + 2 * 1 * sizeof(int); \
    __private char *dst3 = dst + 3 * 1 * sizeof(int); \
    __builtin_spriv_OpJointMatrixLoadCheckedINTEL_Accumulator_RowMajor_SG16_1x16_i32_1_v8i8_pi32_i32(dst0, mem, y, x + 0 * 16, height, width, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixLoadCheckedINTEL_Accumulator_RowMajor_SG16_1x16_i32_1_v8i8_pi32_i32(dst1, mem, y, x + 1 * 16, height, width, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixLoadCheckedINTEL_Accumulator_RowMajor_SG16_1x16_i32_1_v8i8_pi32_i32(dst2, mem, y, x + 2 * 16, height, width, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixLoadCheckedINTEL_Accumulator_RowMajor_SG16_1x16_i32_1_v8i8_pi32_i32(dst3, mem, y, x + 3 * 16, height, width, stride, cacheOpt);

#define DEFINE_LOAD_LARGE_1_IMPL_AS_GENERIC() \
    INLINE void __builtin_spriv_OpJointMatrixLoadINTEL_Accumulator_RowMajor_SG16_1x64_i32_4_generic_v8i8_pi32_i32(__private char *dst, char *mem, long stride, int cacheOpt) { \
        int sg_size = get_sub_group_size(); \
        __builtin_assume((__global char*)mem != 0); \
        int memIsGlobal = (0 != SPIRV_BUILTIN(GenericCastToPtrExplicit, _p1i8_p4i8_i32, _ToGlobal)(__builtin_astype((mem), __generic char*), StorageWorkgroup)); \
        if (memIsGlobal) { \
            DEFINE_LOAD_LARGE_BLOCK2D_IMPL_1() \
            DEFINE_LOAD_LARGE_VECTORS_IMPL_1(global) \
        } else { \
            DEFINE_LOAD_LARGE_VECTORS_IMPL_1(local) \
        } \
        DEFINE_LOAD_LARGE_SCALAR_IMPL_1() \
    }
#define DEFINE_LOAD_LARGE_1_IMPL_AS_LOCAL() \
    INLINE void __builtin_spriv_OpJointMatrixLoadINTEL_Accumulator_RowMajor_SG16_1x64_i32_4_local_v8i8_pi32_i32(__private char *dst, char *mem, long stride, int cacheOpt) { \
        int sg_size = get_sub_group_size(); \
        DEFINE_LOAD_LARGE_VECTORS_IMPL_1(local) \
        DEFINE_LOAD_LARGE_SCALAR_IMPL_1() \
    }
#define DEFINE_LOAD_LARGE_1_IMPL_AS_GLOBAL() \
    INLINE void __builtin_spriv_OpJointMatrixLoadINTEL_Accumulator_RowMajor_SG16_1x64_i32_4_global_v8i8_pi32_i32(__private char *dst, char *mem, long stride, int cacheOpt) { \
        int sg_size = get_sub_group_size(); \
        DEFINE_LOAD_LARGE_BLOCK2D_IMPL_1() \
        DEFINE_LOAD_LARGE_VECTORS_IMPL_1(global) \
        DEFINE_LOAD_LARGE_SCALAR_IMPL_1() \
    }
#define DEFINE_LOAD_CHECKED_LARGE_1_IMPL() \
    INLINE void __builtin_spriv_OpJointMatrixLoadCheckedINTEL_Accumulator_RowMajor_SG16_1x64_i32_4_v8i8_pi32_i32(__private char *dst, char *mem, int y, int x, int height, int width, long stride, int cacheOpt) { \
        DEFINE_LOAD_CHECKED_LARGE_BLOCK2D_IMPL_1() \
    }

#define DEFINE_LOAD_LARGE_1(layout, M, K) \
    DEFINE_LOAD_LARGE_1_IMPL_AS_GENERIC() \
    DEFINE_LOAD_LARGE_1_IMPL_AS_LOCAL() \
    DEFINE_LOAD_LARGE_1_IMPL_AS_GLOBAL()

#define DEFINE_LOAD_CHECKED_LARGE_1(layout, M, K) \
    DEFINE_LOAD_CHECKED_LARGE_1_IMPL()

DEFINE_LOAD_LARGE_1(Accumulator_RowMajor, 1, 64)

DEFINE_LOAD_CHECKED_LARGE_1(Accumulator_RowMajor, 1, 64)

#define DEFINE_STORE_LARGE_BLOCK2D_IMPL_1() \
    if (BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) >= BLOCK2D_IMPL) { \
      long offset = as_long(mem); \
      long baseoffset = offset & (~0x3f); /* align to 64-byte */ \
      int width = sizeof(int) * 16 - 1; /* in bytes, load 1x64 as 4x16 to use one load instead of 4 */ \
      int pitch = width; /* JointMatrices are expected to be contiguous in memory, without padding at the end of a row */ \
      int height = 4 - 1; /* row count */ \
      long x = (offset - baseoffset) / sizeof(int); /* in elements */ \
      int2 coords = (int2)(x, 0); \
      uint4 val = *(uint4 *)src; \
      void __builtin_IB_subgroup_block_write_flat_u32_wi4_m4k16v1(long, int, int, int, int2, uint4, int); \
      __builtin_IB_subgroup_block_write_flat_u32_wi4_m4k16v1(baseoffset, width, height, pitch, coords, val, cacheOpt); \
      return; \
    }

#define DEFINE_STORE_LARGE_VECTORS_IMPL_1(address_space) \
    if(BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) >= VECTOR_CONT_IMPL) { \
        uint4 c = *(uint4 *) src; \
        intel_sub_group_block_write4((__##address_space uint *)mem, c); \
        return; \
    } \
    if(BIF_FLAG_CTRL_GET(JointMatrixLoadStoreOpt) >= VECTOR_IMPL) { \
        __##address_space uint *ptr = (__##address_space uint *)mem; \
        for (int i = 0; i < 4; i++) \
            intel_sub_group_block_write(ptr + i * 16, ((__private uint *)src)[i]); \
        return; \
    }

#define DEFINE_STORE_LARGE_SCALAR_IMPL_1() \
    int *ptr = (int *)mem; \
    int slid = get_sub_group_local_id(); \
    __private int *slice = (__private int *)src; \
    for (int i = 0; i < 4; i++) \
      ptr[i*16 + slid] = slice[i];

#define DEFINE_STORE_CHECKED_LARGE_BLOCK2D_IMPL_1() \
    /* store 1x64 as 4 stores 1x16 */ \
    __private char *c0 = src + 0 * 1 * (sizeof (int)); \
    __private char *c1 = src + 1 * 1 * (sizeof (int)); \
    __private char *c2 = src + 2 * 1 * (sizeof (int)); \
    __private char *c3 = src + 3 * 1 * (sizeof (int)); \
    __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_1x16_i32_1_pi64_v8i8(mem, c0, y, x + 0 * 16, height, width, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_1x16_i32_1_pi64_v8i8(mem, c1, y, x + 1 * 16, height, width, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_1x16_i32_1_pi64_v8i8(mem, c2, y, x + 2 * 16, height, width, stride, cacheOpt); \
    __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_1x16_i32_1_pi64_v8i8(mem, c3, y, x + 3 * 16, height, width, stride, cacheOpt);

#define DEFINE_STORE_LARGE_1_IMPL_AS_GENERIC() \
    INLINE void __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor_SG16_1x64_i32_4_generic_pi64_v8i8(char *mem, __private char *src, long stride, int cacheOpt) { \
        __builtin_assume((__global char*)mem != 0); \
        int memIsGlobal = (0 != SPIRV_BUILTIN(GenericCastToPtrExplicit, _p1i8_p4i8_i32, _ToGlobal)(__builtin_astype((mem), __generic char*), StorageWorkgroup)); \
        if (memIsGlobal) { \
            DEFINE_STORE_LARGE_BLOCK2D_IMPL_1() \
            DEFINE_STORE_LARGE_VECTORS_IMPL_1(global) \
        } else { \
            DEFINE_STORE_LARGE_VECTORS_IMPL_1(local) \
        } \
        DEFINE_STORE_LARGE_SCALAR_IMPL_1() \
    }
#define DEFINE_STORE_LARGE_1_IMPL_AS_LOCAL() \
    INLINE void __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor_SG16_1x64_i32_4_local_pi64_v8i8(char *mem, __private char *src, long stride, int cacheOpt) { \
        DEFINE_STORE_LARGE_VECTORS_IMPL_1(local) \
        DEFINE_STORE_LARGE_SCALAR_IMPL_1() \
    }
#define DEFINE_STORE_LARGE_1_IMPL_AS_GLOBAL() \
    INLINE void __builtin_spriv_OpJointMatrixStoreINTEL_Accumulator_RowMajor_SG16_1x64_i32_4_global_pi64_v8i8(char *mem, __private char *src, long stride, int cacheOpt) { \
        DEFINE_STORE_LARGE_BLOCK2D_IMPL_1() \
        DEFINE_STORE_LARGE_VECTORS_IMPL_1(global) \
        DEFINE_STORE_LARGE_SCALAR_IMPL_1() \
    }

#define DEFINE_STORE_CHECKED_LARGE_1_IMPL() \
    INLINE void __builtin_spriv_OpJointMatrixStoreCheckedINTEL_Accumulator_RowMajor_SG16_1x64_i32_4_pi64_v8i8(char *mem, __private char *src, int y, int x, int height, int width, long stride, int cacheOpt) { \
        DEFINE_STORE_CHECKED_LARGE_BLOCK2D_IMPL_1() \
    }

#define DEFINE_STORE_LARGE_1(layout, M, K) \
    DEFINE_STORE_LARGE_1_IMPL_AS_GENERIC() \
    DEFINE_STORE_LARGE_1_IMPL_AS_LOCAL() \
    DEFINE_STORE_LARGE_1_IMPL_AS_GLOBAL()

#define DEFINE_STORE_CHECKED_LARGE_1(layout, M, K) \
    DEFINE_STORE_CHECKED_LARGE_1_IMPL()

DEFINE_STORE_LARGE_1(Accumulator_RowMajor, 1, 64)

DEFINE_STORE_CHECKED_LARGE_1(Accumulator_RowMajor, 1, 64)

// FillChecked implementation

#define MANGLE_FILLCHECKED_NAME(elem_bitwidth, contrib_bitwidth, K, WI_rows) \
  __builtin_spirv_OpJointMatrixFillCheckedINTEL_i##elem_bitwidth##_i##contrib_bitwidth##_k##K##_wi##WI_rows

#define DEFINE_FILLCHECKED_IMPL(element_type, elem_bitwidth, contrib_bitwidth, K, WI_rows) \
  INLINE void MANGLE_FILLCHECKED_NAME(elem_bitwidth, contrib_bitwidth, K, WI_rows) (__private char *dst, int y, int x, int height, int width, element_type value) { \
    int slid = get_sub_group_local_id(); \
    int sg_size = get_sub_group_size(); \
    int pack_factor = contrib_bitwidth / elem_bitwidth; \
    int col_sg_ratio = (sg_size * pack_factor) / K; \
    int M = (WI_rows * sg_size * pack_factor) / K; \
    __private element_type *wi_contrib = (__private element_type *) dst; \
    for (int i = 0; i < WI_rows; i++) { \
        int row, col; \
        if (col_sg_ratio != 0) { \
            /* sg_size * pack_factor >= matrix width */ \
            row = slid / K + i * col_sg_ratio; \
            col = slid % K; \
        } else { \
            /* sg_size * pack_factor < matrix width */ \
            row = i % M; \
            col = (i / M) * sg_size + slid; \
        } \
        wi_contrib[i] = col < width - x && row < height - y ? value : 0; \
    } \
}

#define DEFINE_FILLCHECKED__(element_type, elem_bitwidth, contrib_bitwidth, K, WI_rows) \
  DEFINE_FILLCHECKED_IMPL(element_type, elem_bitwidth, contrib_bitwidth, K, WI_rows)

#define DEFINE_FILLCHECKED(element_type, contrib_type, K, WI_rows) \
  DEFINE_FILLCHECKED__(element_type, BITWIDTH(element_type), BITWIDTH(contrib_type), K, WI_rows)

#define DEFINE_FILLCHECKED_K(element_type, contrib_type, K) \
  DEFINE_FILLCHECKED(element_type, contrib_type, K, 1) \
  DEFINE_FILLCHECKED(element_type, contrib_type, K, 2) \
  DEFINE_FILLCHECKED(element_type, contrib_type, K, 4) \
  DEFINE_FILLCHECKED(element_type, contrib_type, K, 8) \
  DEFINE_FILLCHECKED(element_type, contrib_type, K, 16) \
  DEFINE_FILLCHECKED(element_type, contrib_type, K, 32) \
  DEFINE_FILLCHECKED(element_type, contrib_type, K, 64) \
  DEFINE_FILLCHECKED(element_type, contrib_type, K, 128)

#define DEFINE_FILLCHECKED_CONTRIB(element_type, contrib_type) \
  DEFINE_FILLCHECKED_K(element_type, contrib_type, 8) \
  DEFINE_FILLCHECKED_K(element_type, contrib_type, 16) \
  DEFINE_FILLCHECKED_K(element_type, contrib_type, 32) \
  DEFINE_FILLCHECKED_K(element_type, contrib_type, 64)

#define DEFINE_FILLCHECKED_GROUP(element_type) \
  DEFINE_FILLCHECKED_CONTRIB(element_type, short) \
  DEFINE_FILLCHECKED_CONTRIB(element_type, int)

DEFINE_FILLCHECKED_GROUP(char)
DEFINE_FILLCHECKED_GROUP(short)
DEFINE_FILLCHECKED_GROUP(int)
