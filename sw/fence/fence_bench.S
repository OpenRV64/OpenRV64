/*
 * Cache-hot Sv39 fence microbenchmarks.
 *
 * a0..a7 report cycle deltas for matched no-fence/fence pairs:
 *
 *   a0 rr_none    a1 rr
 *   a2 rw_none    a3 rw
 *   a4 wr_none    a5 wr
 *   a6 ww_none    a7 ww
 *
 * The loop count is fixed and exported in the output documentation so the
 * incremental cost is (fenced - baseline) / iterations.  The workload uses
 * no I/O, FENCE.I, SFENCE.VMA, or SATP writes in the measured regions.
 */

.equ FENCE_BENCH_ITERS, 1024
.equ BENCH_BASE,        0x40010000

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl _start
.type _start, @function

.macro WARM_RR use_fence
    li      s0, BENCH_BASE
    li      s1, 32
991:
    ld      t0, 0(s0)
.if \use_fence
    fence   r, r
.endif
    ld      t1, 64(s0)
    add     t2, t0, t1
    addi    s1, s1, -1
    bnez    s1, 991b
.endm

.macro MEASURE_RR result, use_fence
    WARM_RR \use_fence
    li      s0, BENCH_BASE
    li      s1, FENCE_BENCH_ITERS
    csrr    s2, cycle
991:
    ld      t0, 0(s0)
.if \use_fence
    fence   r, r
.endif
    ld      t1, 64(s0)
    add     t2, t0, t1
    addi    s1, s1, -1
    bnez    s1, 991b
    csrr    t0, cycle
    sub     \result, t0, s2
.endm

.macro WARM_RW use_fence
    li      s0, BENCH_BASE
    li      s1, 32
991:
    ld      t0, 0(s0)
.if \use_fence
    fence   r, w
.endif
    sd      t0, 128(s0)
    addi    s1, s1, -1
    bnez    s1, 991b
    fence   w, r
.endm

.macro MEASURE_RW result, use_fence
    WARM_RW \use_fence
    li      s0, BENCH_BASE
    li      s1, FENCE_BENCH_ITERS
    csrr    s2, cycle
991:
    ld      t0, 0(s0)
.if \use_fence
    fence   r, w
.endif
    sd      t0, 128(s0)
    addi    s1, s1, -1
    bnez    s1, 991b
    csrr    t0, cycle
    sub     \result, t0, s2
    fence   w, r
.endm

.macro WARM_WR use_fence
    li      s0, BENCH_BASE
    li      s1, 32
991:
    sd      s1, 128(s0)
.if \use_fence
    fence   w, r
.endif
    ld      t0, 0(s0)
    addi    s1, s1, -1
    bnez    s1, 991b
    fence   w, r
.endm

.macro MEASURE_WR result, use_fence
    WARM_WR \use_fence
    li      s0, BENCH_BASE
    li      s1, FENCE_BENCH_ITERS
    csrr    s2, cycle
991:
    sd      s1, 128(s0)
.if \use_fence
    fence   w, r
.endif
    ld      t0, 0(s0)
    addi    s1, s1, -1
    bnez    s1, 991b
    csrr    t0, cycle
    sub     \result, t0, s2
    fence   w, r
.endm

.macro WARM_WW use_fence
    li      s0, BENCH_BASE
    li      s1, 32
991:
    sd      s1, 128(s0)
.if \use_fence
    fence   w, w
.endif
    sd      s1, 192(s0)
    addi    s1, s1, -1
    bnez    s1, 991b
    fence   w, r
.endm

.macro MEASURE_WW result, use_fence
    WARM_WW \use_fence
    li      s0, BENCH_BASE
    li      s1, FENCE_BENCH_ITERS
    csrr    s2, cycle
991:
    sd      s1, 128(s0)
.if \use_fence
    fence   w, w
.endif
    sd      s1, 192(s0)
    addi    s1, s1, -1
    bnez    s1, 991b
    csrr    t0, cycle
    sub     \result, t0, s2
    fence   w, r
.endm

_start:
    la      sp, __stack_top

    /* Touch every measured line before taking counters. */
    li      s0, BENCH_BASE
    ld      t0, 0(s0)
    ld      t0, 64(s0)
    sd      zero, 128(s0)
    sd      zero, 192(s0)
    fence   w, r

    MEASURE_RR a0, 0
    MEASURE_RR a1, 1
    MEASURE_RW a2, 0
    MEASURE_RW a3, 1
    MEASURE_WR a4, 0
    MEASURE_WR a5, 1
    MEASURE_WW a6, 0
    MEASURE_WW a7, 1

    fence   w, r
    ebreak

.size _start, .-_start

.section .fence_test, "aw", @progbits
.balign 4096
.globl fence_bench_data
fence_bench_data:
    .quad 0x0102030405060708
    .zero 56
    .quad 0x1112131415161718
    .zero 4096 - 72
