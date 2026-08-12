/*
 * Minimal RV64D integration workload.
 *
 * Computes y[i] = 2.0 * x[i] + y[i] for 256 binary-exact inputs with four
 * separate kernels unrolled by 1, 4, 16, and 32 elements.  Every kernel has
 * private output storage and every result is verified with integer loads.
 *
 * The u16 kernel preloads fifteen independent x/y pairs, the maximum possible
 * while retaining one FPR for alpha, then handles its sixteenth element after
 * that wave.  RV64D has insufficient FPRs for 32 fully independent DAXPY
 * elements, so u32 contains two fifteen-wide waves plus a two-wide tail in one
 * software-unrolled loop body.  The testbench observes actual FPU
 * request/result handshakes and reports maximum overlap for each kernel.
 *
 * At the final EBREAK, a1 points to four pairs of kernel-only cycle and
 * retired-instruction deltas in unroll order 1/4/16/32.  Setup, counter-result
 * stores, and result verification are outside each measured interval.
 *
 * Testbench completion contract:
 *   a0 = 0x44415850595f4f4b ("DAXPY_OK") at the retired EBREAK: pass
 *   a0 = 0x44415850595f4244 ("DAXPY_BD") at the retired EBREAK: data failure
 *   a0 = 0x44415850595f464c ("DAXPY_FL") at the retired EBREAK: fflags failure
 */

.equ MSTATUS_FS_INITIAL, 0x2000
.equ DAXPY_COUNT,         256
.equ DAXPY_PATTERN_COUNT, 32
.equ DAXPY_PASS,          0x44415850595f4f4b
.equ DAXPY_FAIL_DATA,     0x44415850595f4244
.equ DAXPY_FAIL_FLAGS,    0x44415850595f464c

.section .text.startup, "ax", @progbits
.align 3
.globl main
.type main, @function
main:
    /* F/D instructions are illegal while mstatus.FS is Off. */
    li      t0, MSTATUS_FS_INITIAL
    csrs    mstatus, t0
    csrw    fflags, zero

    la      t0, daxpy_alpha
    fld     ft11, 0(t0)

    /* Scalar dependency-chain baseline. */
    la      a0, daxpy_x
    la      a1, daxpy_y_u1
    li      a2, DAXPY_COUNT
    li      s4, 1
    rdcycle s0
    rdinstret s1
    call    daxpy_kernel_u1
    rdcycle s2
    rdinstret s3
    li      s4, 0
    sub     s2, s2, s0
    sub     s3, s3, s1
    la      t0, daxpy_perf
    sd      s2, 0(t0)
    sd      s3, 8(t0)

    /* Four independent x/y-result register pairs. */
    la      a0, daxpy_x
    la      a1, daxpy_y_u4
    li      a2, DAXPY_COUNT
    li      s4, 2
    rdcycle s0
    rdinstret s1
    call    daxpy_kernel_u4
    rdcycle s2
    rdinstret s3
    li      s4, 0
    sub     s2, s2, s0
    sub     s3, s3, s1
    la      t0, daxpy_perf
    sd      s2, 16(t0)
    sd      s3, 24(t0)

    /* Sixteen result registers with rotating x scratch registers. */
    la      a0, daxpy_x
    la      a1, daxpy_y_u16
    li      a2, DAXPY_COUNT
    li      s4, 3
    rdcycle s0
    rdinstret s1
    call    daxpy_kernel_u16
    rdcycle s2
    rdinstret s3
    li      s4, 0
    sub     s2, s2, s0
    sub     s3, s3, s1
    la      t0, daxpy_perf
    sd      s2, 32(t0)
    sd      s3, 40(t0)

    /* Two sixteen-result waves in one thirty-two-element body. */
    la      a0, daxpy_x
    la      a1, daxpy_y_u32
    li      a2, DAXPY_COUNT
    li      s4, 4
    rdcycle s0
    rdinstret s1
    call    daxpy_kernel_u32
    rdcycle s2
    rdinstret s3
    li      s4, 0
    sub     s2, s2, s0
    sub     s3, s3, s1
    la      t0, daxpy_perf
    sd      s2, 48(t0)
    sd      s3, 56(t0)

    /* These inputs are exactly representable, so no IEEE-754 flags are due. */
    frflags t0
    bnez    t0, daxpy_fail_flags

    /* Verify all four private output arrays outside the measured regions. */
    li      s5, 1
    la      a0, daxpy_y_u1
    la      a1, daxpy_expected
    li      a2, DAXPY_COUNT
    call    daxpy_verify
    li      s5, 2
    la      a0, daxpy_y_u4
    la      a1, daxpy_expected
    li      a2, DAXPY_COUNT
    call    daxpy_verify
    li      s5, 3
    la      a0, daxpy_y_u16
    la      a1, daxpy_expected
    li      a2, DAXPY_COUNT
    call    daxpy_verify
    li      s5, 4
    la      a0, daxpy_y_u32
    la      a1, daxpy_expected
    li      a2, DAXPY_COUNT
    call    daxpy_verify

    la      a1, daxpy_perf
    li      a2, 4

.globl daxpy_done
daxpy_done:
    li      a0, DAXPY_PASS
    ebreak
    j       .
.size main, .-main

.section .text, "ax", @progbits
.align 3
.globl daxpy_kernel_u1
.type daxpy_kernel_u1, @function
daxpy_kernel_u1:
    beqz    a2, .Ldaxpy_return
.Ldaxpy_u1_loop:
    fld     ft0, 0(a0)
    fld     ft1, 0(a1)
    fmadd.d ft1, ft11, ft0, ft1, rne
    fsd     ft1, 0(a1)
    addi    a0, a0, 8
    addi    a1, a1, 8
    addi    a2, a2, -1
    bnez    a2, .Ldaxpy_u1_loop
.Ldaxpy_return:
    ret
.size daxpy_kernel_u1, .-daxpy_kernel_u1

.globl daxpy_kernel_u4
.type daxpy_kernel_u4, @function
daxpy_kernel_u4:
    beqz    a2, .Ldaxpy_u4_return
.Ldaxpy_u4_loop:
    fld     ft0, 0(a0)
    fld     ft1, 0(a1)
    fld     ft2, 8(a0)
    fld     ft3, 8(a1)
    fld     ft4, 16(a0)
    fld     ft5, 16(a1)
    fld     ft6, 24(a0)
    fld     ft7, 24(a1)
    fmadd.d ft1, ft11, ft0, ft1, rne
    fmadd.d ft3, ft11, ft2, ft3, rne
    fmadd.d ft5, ft11, ft4, ft5, rne
    fmadd.d ft7, ft11, ft6, ft7, rne
    fsd     ft1, 0(a1)
    fsd     ft3, 8(a1)
    fsd     ft5, 16(a1)
    fsd     ft7, 24(a1)
    addi    a0, a0, 32
    addi    a1, a1, 32
    addi    a2, a2, -4
    bnez    a2, .Ldaxpy_u4_loop
.Ldaxpy_u4_return:
    ret
.size daxpy_kernel_u4, .-daxpy_kernel_u4

/* Fifteen independent x/y pairs occupy f0..f29; ft11/f31 is alpha. */
.macro DAXPY_WAVE15 base
    fld     ft0,  \base+0(a0)
    fld     ft1,  \base+0(a1)
    fld     ft2,  \base+8(a0)
    fld     ft3,  \base+8(a1)
    fld     ft4,  \base+16(a0)
    fld     ft5,  \base+16(a1)
    fld     ft6,  \base+24(a0)
    fld     ft7,  \base+24(a1)
    fld     fs0,  \base+32(a0)
    fld     fs1,  \base+32(a1)
    fld     fa0,  \base+40(a0)
    fld     fa1,  \base+40(a1)
    fld     fa2,  \base+48(a0)
    fld     fa3,  \base+48(a1)
    fld     fa4,  \base+56(a0)
    fld     fa5,  \base+56(a1)
    fld     fa6,  \base+64(a0)
    fld     fa7,  \base+64(a1)
    fld     fs2,  \base+72(a0)
    fld     fs3,  \base+72(a1)
    fld     fs4,  \base+80(a0)
    fld     fs5,  \base+80(a1)
    fld     fs6,  \base+88(a0)
    fld     fs7,  \base+88(a1)
    fld     fs8,  \base+96(a0)
    fld     fs9,  \base+96(a1)
    fld     fs10, \base+104(a0)
    fld     fs11, \base+104(a1)
    fld     ft8,  \base+112(a0)
    fld     ft9,  \base+112(a1)

    fmadd.d ft1,  ft11, ft0, ft1, rne
    fmadd.d ft3,  ft11, ft2, ft3, rne
    fmadd.d ft5,  ft11, ft4, ft5, rne
    fmadd.d ft7,  ft11, ft6, ft7, rne
    fmadd.d fs1,  ft11, fs0, fs1, rne
    fmadd.d fa1,  ft11, fa0, fa1, rne
    fmadd.d fa3,  ft11, fa2, fa3, rne
    fmadd.d fa5,  ft11, fa4, fa5, rne
    fmadd.d fa7,  ft11, fa6, fa7, rne
    fmadd.d fs3,  ft11, fs2, fs3, rne
    fmadd.d fs5,  ft11, fs4, fs5, rne
    fmadd.d fs7,  ft11, fs6, fs7, rne
    fmadd.d fs9,  ft11, fs8, fs9, rne
    fmadd.d fs11, ft11, fs10, fs11, rne
    fmadd.d ft9,  ft11, ft8, ft9, rne

    fsd     ft1,  \base+0(a1)
    fsd     ft3,  \base+8(a1)
    fsd     ft5,  \base+16(a1)
    fsd     ft7,  \base+24(a1)
    fsd     fs1,  \base+32(a1)
    fsd     fa1,  \base+40(a1)
    fsd     fa3,  \base+48(a1)
    fsd     fa5,  \base+56(a1)
    fsd     fa7,  \base+64(a1)
    fsd     fs3,  \base+72(a1)
    fsd     fs5,  \base+80(a1)
    fsd     fs7,  \base+88(a1)
    fsd     fs9,  \base+96(a1)
    fsd     fs11, \base+104(a1)
    fsd     ft9,  \base+112(a1)
.endm

.macro DAXPY_WAVE1 base
    fld     ft0, \base(a0)
    fld     ft1, \base(a1)
    fmadd.d ft1, ft11, ft0, ft1, rne
    fsd     ft1, \base(a1)
.endm

.macro DAXPY_WAVE2 base
    fld     ft0, \base+0(a0)
    fld     ft1, \base+0(a1)
    fld     ft2, \base+8(a0)
    fld     ft3, \base+8(a1)
    fmadd.d ft1, ft11, ft0, ft1, rne
    fmadd.d ft3, ft11, ft2, ft3, rne
    fsd     ft1, \base+0(a1)
    fsd     ft3, \base+8(a1)
.endm

.globl daxpy_kernel_u16
.type daxpy_kernel_u16, @function
daxpy_kernel_u16:
    beqz    a2, .Ldaxpy_u16_return
.Ldaxpy_u16_loop:
    DAXPY_WAVE15 0
    DAXPY_WAVE1 120
    addi    a0, a0, 128
    addi    a1, a1, 128
    addi    a2, a2, -16
    bnez    a2, .Ldaxpy_u16_loop
.Ldaxpy_u16_return:
    ret
.size daxpy_kernel_u16, .-daxpy_kernel_u16

.globl daxpy_kernel_u32
.type daxpy_kernel_u32, @function
daxpy_kernel_u32:
    beqz    a2, .Ldaxpy_u32_return
.Ldaxpy_u32_loop:
    DAXPY_WAVE15 0
    DAXPY_WAVE15 120
    DAXPY_WAVE2 240
    addi    a0, a0, 256
    addi    a1, a1, 256
    addi    a2, a2, -32
    bnez    a2, .Ldaxpy_u32_loop
.Ldaxpy_u32_return:
    ret
.size daxpy_kernel_u32, .-daxpy_kernel_u32

.globl daxpy_verify
.type daxpy_verify, @function
daxpy_verify:
    beqz    a2, .Ldaxpy_verify_return
.Ldaxpy_verify_loop:
    ld      t0, 0(a0)
    ld      t1, 0(a1)
    bne     t0, t1, daxpy_fail_data
    addi    a0, a0, 8
    addi    a1, a1, 8
    addi    a2, a2, -1
    bnez    a2, .Ldaxpy_verify_loop
.Ldaxpy_verify_return:
    ret
.size daxpy_verify, .-daxpy_verify

.globl daxpy_fail_data
daxpy_fail_data:
    /* Preserve variant, remaining count, actual, and expected. */
    mv      a1, s5
    mv      a3, t0
    mv      a4, t1
    li      a0, DAXPY_FAIL_DATA
    ebreak
    j       .

.globl daxpy_fail_flags
daxpy_fail_flags:
    li      a0, DAXPY_FAIL_FLAGS
    ebreak
    j       .

.section .rodata, "a", @progbits
.align 3
daxpy_alpha:
    .dword  0x4000000000000000      /* 2.0 */

daxpy_x:
.rept DAXPY_PATTERN_COUNT
    .dword  0x3ff0000000000000      /*  1.0  */
    .dword  0xc000000000000000      /* -2.0  */
    .dword  0x3fe0000000000000      /*  0.5  */
    .dword  0x4010000000000000      /*  4.0  */
    .dword  0xbfd0000000000000      /* -0.25 */
    .dword  0x4020000000000000      /*  8.0  */
    .dword  0xc008000000000000      /* -3.0  */
    .dword  0x3ff8000000000000      /*  1.5  */
.endr

daxpy_expected:
.rept DAXPY_PATTERN_COUNT
    .dword  0x4004000000000000      /*  2.5  */
    .dword  0xbff0000000000000      /* -1.0  */
    .dword  0x3ff4000000000000      /*  1.25 */
    .dword  0x3ff0000000000000      /*  1.0  */
    .dword  0x3ff8000000000000      /*  1.5  */
    .dword  0x3ff0000000000000      /*  1.0  */
    .dword  0x3ff0000000000000      /*  1.0  */
    .dword  0x3ff0000000000000      /*  1.0  */
.endr

.section .data, "aw", @progbits
.align 3
.globl daxpy_perf
daxpy_perf:
    .zero 64

.macro DAXPY_Y_PATTERN
    .dword  0x3fe0000000000000      /*   0.5  */
    .dword  0x4008000000000000      /*   3.0  */
    .dword  0x3fd0000000000000      /*   0.25 */
    .dword  0xc01c000000000000      /*  -7.0  */
    .dword  0x4000000000000000      /*   2.0  */
    .dword  0xc02e000000000000      /* -15.0  */
    .dword  0x401c000000000000      /*   7.0  */
    .dword  0xc000000000000000      /*  -2.0  */
.endm

.globl daxpy_y_u1
daxpy_y_u1:
.rept DAXPY_PATTERN_COUNT
    DAXPY_Y_PATTERN
.endr

.globl daxpy_y_u4
daxpy_y_u4:
.rept DAXPY_PATTERN_COUNT
    DAXPY_Y_PATTERN
.endr

.globl daxpy_y_u16
daxpy_y_u16:
.rept DAXPY_PATTERN_COUNT
    DAXPY_Y_PATTERN
.endr

.globl daxpy_y_u32
daxpy_y_u32:
.rept DAXPY_PATTERN_COUNT
    DAXPY_Y_PATTERN
.endr
