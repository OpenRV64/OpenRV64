/*
 * Compute-only RV64D DAXPY scheduling benchmark.
 *
 * Each measured region executes exactly 256 copies of
 *
 *     y = 2.0 * 1.0 + y
 *
 * with 1, 4, or 16 independent accumulator chains.  The u32 and u256 bodies
 * emit repeated sixteen-instruction waves, so each dependency has a distance
 * of sixteen.  The u256 region executes its entire useful workload in one
 * loop iteration to isolate straight-line issue/retirement throughput.
 * Constants and accumulators are initialized with FMV.D.X before measurement;
 * there are no load or store instructions inside any measured region.  Result
 * checks and integer stores used to publish counters occur after measurement.
 *
 * At the final EBREAK:
 *   a0 = DAXPY_COMPUTE_PASS
 *   a1 = address of five {cycle_delta, instret_delta} pairs
 *   a2 = 5
 */

.equ MSTATUS_FS_INITIAL, 0x2000
.equ DAXPY_COMPUTE_OPS,  256
.equ DAXPY_COMPUTE_PASS, 0x4458435f4f4b2121 /* "DXC_OK!!" */
.equ DAXPY_COMPUTE_FAIL, 0x4458435f42414421 /* "DXC_BAD!" */
.equ DAXPY_COMPUTE_FLAGS,0x4458435f464c4721 /* "DXC_FLG!" */

.macro INIT_ACCUMULATORS
    fmv.d.x f2,  zero
    fmv.d.x f3,  zero
    fmv.d.x f4,  zero
    fmv.d.x f5,  zero
    fmv.d.x f6,  zero
    fmv.d.x f7,  zero
    fmv.d.x f8,  zero
    fmv.d.x f9,  zero
    fmv.d.x f10, zero
    fmv.d.x f11, zero
    fmv.d.x f12, zero
    fmv.d.x f13, zero
    fmv.d.x f14, zero
    fmv.d.x f15, zero
    fmv.d.x f16, zero
    fmv.d.x f17, zero
.endm

.macro DAXPY_COMPUTE_WAVE4
    fmadd.d f2, f0, f1, f2, rne
    fmadd.d f3, f0, f1, f3, rne
    fmadd.d f4, f0, f1, f4, rne
    fmadd.d f5, f0, f1, f5, rne
.endm

.macro DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE4
    fmadd.d f6,  f0, f1, f6,  rne
    fmadd.d f7,  f0, f1, f7,  rne
    fmadd.d f8,  f0, f1, f8,  rne
    fmadd.d f9,  f0, f1, f9,  rne
    fmadd.d f10, f0, f1, f10, rne
    fmadd.d f11, f0, f1, f11, rne
    fmadd.d f12, f0, f1, f12, rne
    fmadd.d f13, f0, f1, f13, rne
    fmadd.d f14, f0, f1, f14, rne
    fmadd.d f15, f0, f1, f15, rne
    fmadd.d f16, f0, f1, f16, rne
    fmadd.d f17, f0, f1, f17, rne
.endm

.macro DAXPY_COMPUTE_WAVE256
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
.endm

.macro CHECK_ACCUMULATOR reg
    la      t3, daxpy_compute_scratch
    fsd     \reg, 0(t3)
    ld      t1, 0(t3)
    bne     t1, t2, daxpy_compute_fail
.endm

.macro CHECK_ACCUMULATORS4
    CHECK_ACCUMULATOR f2
    CHECK_ACCUMULATOR f3
    CHECK_ACCUMULATOR f4
    CHECK_ACCUMULATOR f5
.endm

.macro CHECK_ACCUMULATORS16
    CHECK_ACCUMULATORS4
    CHECK_ACCUMULATOR f6
    CHECK_ACCUMULATOR f7
    CHECK_ACCUMULATOR f8
    CHECK_ACCUMULATOR f9
    CHECK_ACCUMULATOR f10
    CHECK_ACCUMULATOR f11
    CHECK_ACCUMULATOR f12
    CHECK_ACCUMULATOR f13
    CHECK_ACCUMULATOR f14
    CHECK_ACCUMULATOR f15
    CHECK_ACCUMULATOR f16
    CHECK_ACCUMULATOR f17
.endm

.section .text.startup, "ax", @progbits
.align 3
.globl _start
.type _start, @function
_start:
    li      t0, MSTATUS_FS_INITIAL
    csrs    mstatus, t0
    csrw    fflags, zero

    li      t0, 0x4000000000000000 /* 2.0 */
    fmv.d.x f0, t0
    li      t0, 0x3ff0000000000000 /* 1.0 */
    fmv.d.x f1, t0

    /* One accumulator: one 256-operation RAW chain. */
    INIT_ACCUMULATORS
    li      s5, 1
    li      t0, 256
    li      s4, 1
    rdcycle s0
    rdinstret s1
.Ldaxpy_compute_u1:
    fmadd.d f2, f0, f1, f2, rne
    addi    t0, t0, -1
    bnez    t0, .Ldaxpy_compute_u1
    rdcycle s2
    rdinstret s3
    li      s4, 0
    sub     s2, s2, s0
    sub     s3, s3, s1
    la      t0, daxpy_compute_perf
    sd      s2, 0(t0)
    sd      s3, 8(t0)
    li      t2, 0x4080000000000000 /* 512.0 */
    CHECK_ACCUMULATOR f2

    /* Four independent 64-operation chains. */
    INIT_ACCUMULATORS
    li      s5, 4
    li      t0, 64
    li      s4, 2
    rdcycle s0
    rdinstret s1
.Ldaxpy_compute_u4:
    DAXPY_COMPUTE_WAVE4
    addi    t0, t0, -1
    bnez    t0, .Ldaxpy_compute_u4
    rdcycle s2
    rdinstret s3
    li      s4, 0
    sub     s2, s2, s0
    sub     s3, s3, s1
    la      t0, daxpy_compute_perf
    sd      s2, 16(t0)
    sd      s3, 24(t0)
    li      t2, 0x4060000000000000 /* 128.0 */
    CHECK_ACCUMULATORS4

    /* Sixteen independent 16-operation chains. */
    INIT_ACCUMULATORS
    li      s5, 16
    li      t0, 16
    li      s4, 3
    rdcycle s0
    rdinstret s1
.Ldaxpy_compute_u16:
    DAXPY_COMPUTE_WAVE16
    addi    t0, t0, -1
    bnez    t0, .Ldaxpy_compute_u16
    rdcycle s2
    rdinstret s3
    li      s4, 0
    sub     s2, s2, s0
    sub     s3, s3, s1
    la      t0, daxpy_compute_perf
    sd      s2, 32(t0)
    sd      s3, 40(t0)
    li      t2, 0x4040000000000000 /* 32.0 */
    CHECK_ACCUMULATORS16

    /* Thirty-two-instruction body: two waves, dependency distance sixteen. */
    INIT_ACCUMULATORS
    li      s5, 32
    li      t0, 8
    li      s4, 4
    rdcycle s0
    rdinstret s1
.Ldaxpy_compute_u32:
    DAXPY_COMPUTE_WAVE16
    DAXPY_COMPUTE_WAVE16
    addi    t0, t0, -1
    bnez    t0, .Ldaxpy_compute_u32
    rdcycle s2
    rdinstret s3
    li      s4, 0
    sub     s2, s2, s0
    sub     s3, s3, s1
    la      t0, daxpy_compute_perf
    sd      s2, 48(t0)
    sd      s3, 56(t0)
    li      t2, 0x4040000000000000 /* 32.0 */
    CHECK_ACCUMULATORS16

    /* Entire 256-FMA workload in one loop iteration. */
    INIT_ACCUMULATORS
    li      s5, 256
    li      t0, 1
    li      s4, 5
    rdcycle s0
    rdinstret s1
.Ldaxpy_compute_u256:
    DAXPY_COMPUTE_WAVE256
    addi    t0, t0, -1
    bnez    t0, .Ldaxpy_compute_u256
    rdcycle s2
    rdinstret s3
    li      s4, 0
    sub     s2, s2, s0
    sub     s3, s3, s1
    la      t0, daxpy_compute_perf
    sd      s2, 64(t0)
    sd      s3, 72(t0)
    li      t2, 0x4040000000000000 /* 32.0 */
    CHECK_ACCUMULATORS16

    /* Make every counter record visible to the external testbench RAM. */
    fence   rw, rw

    frflags t0
    bnez    t0, daxpy_compute_fail_flags

    la      a1, daxpy_compute_perf
    li      a2, 5
    li      a3, DAXPY_COMPUTE_OPS
    li      a0, DAXPY_COMPUTE_PASS
.globl daxpy_compute_done
daxpy_compute_done:
    ebreak
    j       .

.globl daxpy_compute_fail
daxpy_compute_fail:
    mv      a1, s5
    mv      a2, t1
    mv      a3, t2
    li      a0, DAXPY_COMPUTE_FAIL
    ebreak
    j       .

.globl daxpy_compute_fail_flags
daxpy_compute_fail_flags:
    mv      a1, t0
    li      a0, DAXPY_COMPUTE_FLAGS
    ebreak
    j       .
.size _start, .-_start

.section .data, "aw", @progbits
.align 3
.globl daxpy_compute_perf
daxpy_compute_perf:
    .zero 80
daxpy_compute_scratch:
    .zero 8
