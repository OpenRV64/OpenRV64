/*
 * BF16 matrix multiply for the private OpenRV64 vector experiment.
 * These are custom test-harness encodings, not RVV instructions.
 *
 * matmul_bf16 ABI, for VLEN=256:
 *   a0 = packed/broadcast A, shaped [M][K][16] BF16. Each group of sixteen
 *        values contains copies of one logical A[i][k].
 *   a1 = B, shaped [N/16][K][16] BF16, sixteen-column block major.
 *   a2 = C, shaped [M][N] BF16, row major.
 *   a3 = M row count.
 *   a4 = K reduction count.
 *   a5 = N/16 output-column vector count.
 *
 * N must be a multiple of sixteen. The routine clobbers t0-t6 and v2-v9.
 * Multiply and add remain separate operations, so this has the
 * architecture's normal intermediate BF16 rounding rather than fused MAC
 * semantics. There is no vector-to-GPR write path.
 */

    .option norvc
    .option norelax

    .equ VEC_OPCODE_ALU, 0x0b
    .equ VEC_OPCODE_LSU, 0x2b

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

    .macro VSYNC vreg
    .word ((\vreg << 15) | (7 << 12) | VEC_OPCODE_ALU)
    .endm

    .macro VLOAD vd, base
    .word ((\base << 15) | (0 << 12) | (\vd << 7) | VEC_OPCODE_LSU)
    .endm

    .macro VSTORE vs3, base
    .word ((\vs3 << 20) | (\base << 15) | (1 << 12) | \
           VEC_OPCODE_LSU)
    .endm

    .macro BF16_SPLAT bits
    .rept 16
    .hword \bits
    .endr
    .endm

    .section .text.startup, "ax", @progbits
    .balign 4
    .globl _start
    .type _start, @function
_start:
    la      a0, matmul_bf16_a_packed
    la      a1, matmul_bf16_b
    la      a2, matmul_bf16_c
    li      a3, 4
    li      a4, 8
    li      a5, 2
    jal     ra, matmul_bf16
    ebreak
.Lhalt:
    j       .Lhalt
    .size _start, .-_start

    .section .text, "ax", @progbits
    .balign 4
    .globl matmul_bf16
    .type matmul_bf16, @function
matmul_bf16:
    beqz    a3, .Lmatmul_bf16_return
    beqz    a5, .Lmatmul_bf16_return

    /* vtype: m1, e16, xfmt=BF16. */
    li      t6, 0x108
    VSET    31                      /* t6=x31 */

.Lmatmul_bf16_row:
    mv      t3, a5
    mv      t4, a1

.Lmatmul_bf16_column_block:
    addi    t2, t3, -1
    beqz    t2, .Lmatmul_bf16_single_block

    /*
     * Two-column-block unroll. Both outputs traverse K in source order, so
     * BF16 rounding is unchanged. v2 supplies A to the two independent
     * product/accumulator chains, with product parity crossed for the banked
     * vector register file.
     */
    VXOR    8, 8, 8
    VXOR    9, 9, 9
    mv      t0, a0
    mv      t1, t4
    slli    t5, a4, 5
    add     t5, t4, t5
    mv      t2, a4
    beqz    t2, .Lmatmul_bf16_pair_store

.Lmatmul_bf16_pair_k:
    VLOAD   2, 5
    addi    t0, t0, 32
    VLOAD   3, 6
    addi    t1, t1, 32
    VLOAD   7, 30
    addi    t5, t5, 32
    addi    t2, t2, -1

    VSYNC   2
    VSYNC   3
    VSYNC   8
    VFMUL   5, 2, 3
    VSYNC   7
    VSYNC   9
    VFMUL   4, 2, 7

    VSYNC   5
    VFADD   8, 8, 5
    VSYNC   4
    VFADD   9, 9, 4
    bnez    t2, .Lmatmul_bf16_pair_k

.Lmatmul_bf16_pair_store:
    VSYNC   8
    VSTORE  8, 12
    addi    a2, a2, 32
    VSYNC   9
    VSTORE  9, 12
    addi    a2, a2, 32
    mv      t4, t5
    mv      t5, t0
    addi    t3, t3, -2
    bnez    t3, .Lmatmul_bf16_column_block
    j       .Lmatmul_bf16_row_done

.Lmatmul_bf16_single_block:
    VXOR    8, 8, 8
    mv      t0, a0
    mv      t1, t4
    mv      t2, a4
    beqz    t2, .Lmatmul_bf16_single_store

.Lmatmul_bf16_single_k:
    VLOAD   2, 5
    addi    t0, t0, 32
    VLOAD   3, 6
    addi    t1, t1, 32
    addi    t2, t2, -1
    VSYNC   2
    VSYNC   3
    VSYNC   8
    VFMUL   5, 2, 3
    VSYNC   5
    VFADD   8, 8, 5
    bnez    t2, .Lmatmul_bf16_single_k

.Lmatmul_bf16_single_store:
    VSYNC   8
    VSTORE  8, 12                  /* C through a2=x12 */
    mv      t4, t1
    mv      t5, t0
    addi    a2, a2, 32

.Lmatmul_bf16_row_done:
    mv      a0, t5
    addi    a3, a3, -1
    bnez    a3, .Lmatmul_bf16_row

.Lmatmul_bf16_return:
    ret
    .size matmul_bf16, .-matmul_bf16

    /*
     * A rows have logical sums 8, 16, 32 and 64. Keeping those sums as
     * powers of two makes every expected result exactly representable in
     * BF16 while still exercising all eight K iterations.
     */
    .section .vector_bf16_a, "a", @progbits
    .balign 32
    .globl matmul_bf16_a_packed
matmul_bf16_a_packed:
    /* Row 0: 1,1,1,1,1,1,1,1. */
    .rept 8
    BF16_SPLAT 0x3f80
    .endr

    /* Row 1: 1,1,1,1,3,3,3,3. */
    .rept 4
    BF16_SPLAT 0x3f80
    .endr
    .rept 4
    BF16_SPLAT 0x4040
    .endr

    /* Row 2: 1,2,3,4,5,5,6,6. */
    BF16_SPLAT 0x3f80
    BF16_SPLAT 0x4000
    BF16_SPLAT 0x4040
    BF16_SPLAT 0x4080
    BF16_SPLAT 0x40a0
    BF16_SPLAT 0x40a0
    BF16_SPLAT 0x40c0
    BF16_SPLAT 0x40c0

    /* Row 3: 1,3,5,7,9,11,13,15. */
    BF16_SPLAT 0x3f80
    BF16_SPLAT 0x4040
    BF16_SPLAT 0x40a0
    BF16_SPLAT 0x40e0
    BF16_SPLAT 0x4110
    BF16_SPLAT 0x4130
    BF16_SPLAT 0x4150
    BF16_SPLAT 0x4170

    /*
     * B[k][j] = j+1 for every k. Two sixteen-column blocks each contain
     * eight K vectors.
     */
    .section .vector_bf16_b, "a", @progbits
    .balign 32
    .globl matmul_bf16_b
matmul_bf16_b:
    .rept 8
    .hword 0x3f80, 0x4000, 0x4040, 0x4080
    .hword 0x40a0, 0x40c0, 0x40e0, 0x4100
    .hword 0x4110, 0x4120, 0x4130, 0x4140
    .hword 0x4150, 0x4160, 0x4170, 0x4180
    .endr

    .rept 8
    .hword 0x4188, 0x4190, 0x4198, 0x41a0
    .hword 0x41a8, 0x41b0, 0x41b8, 0x41c0
    .hword 0x41c8, 0x41d0, 0x41d8, 0x41e0
    .hword 0x41e8, 0x41f0, 0x41f8, 0x4200
    .endr

    .section .vector_bf16_c, "aw", @progbits
    .balign 32
    .globl matmul_bf16_c
matmul_bf16_c:
    .zero 256
