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

#ifndef OPENRV64_FENCE_BENCH_ENTRY
#define OPENRV64_FENCE_BENCH_ENTRY main
#endif

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl OPENRV64_FENCE_BENCH_ENTRY
.type OPENRV64_FENCE_BENCH_ENTRY, @function

.macro WARM_RR use_fence
    la      s0, fence_bench_data
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
    la      s0, fence_bench_data
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
    la      s0, fence_bench_data
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
    la      s0, fence_bench_data
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
    la      s0, fence_bench_data
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
    la      s0, fence_bench_data
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
    la      s0, fence_bench_data
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
    la      s0, fence_bench_data
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

OPENRV64_FENCE_BENCH_ENTRY:

    /* Touch every measured line before taking counters. */
    la      s0, fence_bench_data
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
    ret

.size OPENRV64_FENCE_BENCH_ENTRY, .-OPENRV64_FENCE_BENCH_ENTRY

.section .data.fence_test, "aw", @progbits
.balign 4096
.globl fence_bench_data
fence_bench_data:
    .quad 0x0102030405060708
    .zero 56
    .quad 0x1112131415161718
    .zero 4096 - 72
