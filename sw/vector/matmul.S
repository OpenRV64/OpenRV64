/*
 * Minimal FP32 matrix multiply for the private OpenRV64 vector experiment.
 * This is not RVV assembly. The instruction macros below emit the custom
 * encodings consumed by rtl/openrv64_vec_test_top.sv.
 *
 * matmul ABI:
 *   a0 = packed/broadcast A, shaped [M][K][8] FP32. Every group of eight
 *        values contains eight copies of one logical A[i][k].
 *   a1 = B, shaped [N/8][K][8] FP32, eight-column block major.
 *   a2 = C, shaped [M][N] FP32, row major.
 *   a3 = M row count.
 *   a4 = K reduction count.
 *   a5 = N/8 output-column vector count.
 *
 * The current 256-bit VLEN therefore computes eight output columns at once.
 * N must be a multiple of eight. It clobbers t0-t6 and v2-v9. There is no
 * vector-to-GPR write path.
 */

    .option norvc
    .option norelax

    .equ VEC_OPCODE_ALU, 0x0b
    .equ VEC_OPCODE_LSU, 0x2b
    .equ VEC_OPCODE_ACC, 0x5b
    .equ VEC_OPCODE_PREFETCH, 0x7b

    .macro VSET rs1
    .word ((\rs1 << 15) | (0 << 12) | (0 << 7) | VEC_OPCODE_ALU)
    .endm

    .macro VXOR vd, vs1, vs2
    .word ((\vs2 << 20) | (\vs1 << 15) | (3 << 12) | \
           (\vd << 7) | VEC_OPCODE_ALU)
    .endm

    .macro VFADD vd, vs1, vs2
    .word ((\vs2 << 20) | (\vs1 << 15) | (5 << 12) | \
           (\vd << 7) | VEC_OPCODE_ALU)
    .endm

    .macro VFMUL vd, vs1, vs2
    .word ((\vs2 << 20) | (\vs1 << 15) | (6 << 12) | \
           (\vd << 7) | VEC_OPCODE_ALU)
    .endm

    .macro VSYNC vreg1, vreg2
    .word ((\vreg2 << 20) | (\vreg1 << 15) | (7 << 12) | \
           VEC_OPCODE_ALU)
    .endm

    .macro VLOAD vd, base
    .word ((\base << 15) | (0 << 12) | (\vd << 7) | VEC_OPCODE_LSU)
    .endm

    .macro VSTORE vs3, base
    .word ((\vs3 << 20) | (\base << 15) | (1 << 12) | \
           VEC_OPCODE_LSU)
    .endm

    /* stream=0 inserts normally; stream=1 is discard-next after consumption. */
    .macro VPRFM base, lines, stream=0
    .word (((\lines & 15) << 20) | (\base << 15) | \
           ((\stream & 1) << 12) | VEC_OPCODE_PREFETCH)
    .endm

    /* Bit 25 selects one of the two private accumulator contexts. */
    .macro VLDA acc, vs
    .word ((\acc << 25) | (\vs << 15) | (0 << 12) | VEC_OPCODE_ACC)
    .endm

    .macro VSTA acc, vd
    .word ((\acc << 25) | (1 << 12) | (\vd << 7) | VEC_OPCODE_ACC)
    .endm

    .macro VMAC acc, vs1, vs2
    .word ((\acc << 25) | (\vs2 << 20) | (\vs1 << 15) | \
           (2 << 12) | VEC_OPCODE_ACC)
    .endm

    .section .text.startup, "ax", @progbits
    .balign 4
    .globl _start
    .type _start, @function
_start:
    la      a0, matmul_a_packed
    la      a1, matmul_b
    la      a2, matmul_c
    li      a3, 2
    li      a4, 3
    li      a5, 2
    jal     ra, matmul
    ebreak
.Lhalt:
    j       .Lhalt
    .size _start, .-_start

    .section .text, "ax", @progbits
    .balign 4
    .globl matmul
    .type matmul, @function
matmul:
    beqz    a3, .Lmatmul_return
    beqz    a5, .Lmatmul_return

    /* vtype: m1, e32, xfmt=FP32. */
    li      t6, 0x10
    VSET    31                      /* t6=x31 */

.Lmatmul_row:
    mv      t3, a5                 /* remaining eight-column blocks */
    mv      t4, a1                 /* restart B for each output row */

.Lmatmul_column_block:
    addi    t2, t3, -1
    beqz    t2, .Lmatmul_single_block

    /*
     * Two-column-block unroll. acc0 and acc1 retain the two output vectors;
     * v2 broadcasts A and v3/v7 hold the two B vectors. Each accumulator
     * traverses K in source order while the independent recurrences overlap.
     */
    VXOR    8, 8, 8
    VXOR    9, 9, 9
    VSYNC   8, 9
    VLDA    0, 8
    VLDA    1, 9
    mv      t0, a0                 /* packed A row cursor */
    mv      t1, t4                 /* first B column-block cursor */
    slli    t5, a4, 5
    add     t5, t4, t5             /* second B column-block cursor */
    mv      t2, a4
    beqz    t2, .Lmatmul_pair_store

.Lmatmul_pair_k:
    VLOAD   2, 5
    addi    t0, t0, 32
    VLOAD   3, 6
    addi    t1, t1, 32
    VLOAD   7, 30
    addi    t5, t5, 32
    addi    t2, t2, -1

    VSYNC   2, 3
    VMAC    0, 2, 3
    VSYNC   2, 7
    VMAC    1, 2, 7
    bnez    t2, .Lmatmul_pair_k

.Lmatmul_pair_store:
    VSTA    0, 8
    VSTA    1, 9
    VSYNC   8, 9
    VSTORE  8, 12
    addi    a2, a2, 32
    VSTORE  9, 12
    addi    a2, a2, 32
    mv      t4, t5                 /* B start after both blocks */
    mv      t5, t0                 /* packed A start for next row */
    addi    t3, t3, -2
    bnez    t3, .Lmatmul_column_block
    j       .Lmatmul_row_done

.Lmatmul_single_block:
    VXOR    8, 8, 8
    VSYNC   8, 8
    VLDA    0, 8
    mv      t0, a0
    mv      t1, t4
    mv      t2, a4
    beqz    t2, .Lmatmul_single_store

.Lmatmul_single_k:
    VLOAD   2, 5
    addi    t0, t0, 32
    VLOAD   3, 6
    addi    t1, t1, 32
    addi    t2, t2, -1
    VSYNC   2, 3
    VMAC    0, 2, 3
    bnez    t2, .Lmatmul_single_k

.Lmatmul_single_store:
    VSTA    0, 8
    VSYNC   8, 8
    VSTORE  8, 12                  /* C[i][0:8], a2=x12 */
    mv      t4, t1                 /* next B eight-column block */
    mv      t5, t0                 /* packed A start for next row */
    addi    a2, a2, 32

.Lmatmul_row_done:
    mv      a0, t5
    addi    a3, a3, -1
    bnez    a3, .Lmatmul_row

.Lmatmul_return:
    ret
    .size matmul, .-matmul

    /* Two rows by three reduction elements, each scalar pre-broadcast. */
    .section .vector_a, "a", @progbits
    .balign 32
    .globl matmul_a_packed
matmul_a_packed:
    .rept 8
    .word 0x3f800000               /* 1.0 */
    .endr
    .rept 8
    .word 0x40000000               /* 2.0 */
    .endr
    .rept 8
    .word 0x40400000               /* 3.0 */
    .endr
    .rept 8
    .word 0x40800000               /* 4.0 */
    .endr
    .rept 8
    .word 0x40a00000               /* 5.0 */
    .endr
    .rept 8
    .word 0x40c00000               /* 6.0 */
    .endr

    .section .vector_b, "a", @progbits
    .balign 32
    .globl matmul_b
matmul_b:
    .word 0x3f800000, 0x40000000, 0x40400000, 0x40800000
    .word 0x40a00000, 0x40c00000, 0x40e00000, 0x41000000
    .word 0x41200000, 0x41a00000, 0x41f00000, 0x42200000
    .word 0x42480000, 0x42700000, 0x428c0000, 0x42a00000
    .word 0x42c80000, 0x43480000, 0x43960000, 0x43c80000
    .word 0x43fa0000, 0x44160000, 0x442f0000, 0x44480000

    /* Second eight-column block, with every B row reversed. */
    .word 0x41000000, 0x40e00000, 0x40c00000, 0x40a00000
    .word 0x40800000, 0x40400000, 0x40000000, 0x3f800000
    .word 0x42a00000, 0x428c0000, 0x42700000, 0x42480000
    .word 0x42200000, 0x41f00000, 0x41a00000, 0x41200000
    .word 0x44480000, 0x442f0000, 0x44160000, 0x43fa0000
    .word 0x43c80000, 0x43960000, 0x43480000, 0x42c80000

    .section .vector_c, "aw", @progbits
    .balign 32
    .globl matmul_c
matmul_c:
    .zero 128
