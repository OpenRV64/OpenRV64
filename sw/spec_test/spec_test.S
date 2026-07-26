/*
 * Speculative issue stress test.
 *
 * The 32-instruction kernel fits one RD32 issue window.  Its first branch
 * depends on a short serial chain and is always not taken by default.  With
 * SPEC_TEST_MISPRED_LOG2=N, it is instead taken once every 2^N iterations
 * through a trampoline that rejoins the useful work.  The remaining work is
 * independent: eight cacheable loads, eight dependent adds, and eight
 * independent adds.  With speculation enabled that work may issue while the
 * branch waits; with speculation disabled the same branch is an issue barrier.
 *
 * The final loop branch is predictably taken except at phase boundaries.  A
 * warm-up phase trains both conditional branch PCs before the measured phase.
 * SPEC_TEST_FIRST_BRANCH_SLOT selects an early branch at instruction 6 or a
 * second kernel with branches exactly at instructions 16 and 32.
 */

#ifndef SPEC_TEST_MISPRED_LOG2
#define SPEC_TEST_MISPRED_LOG2 0
#endif

#ifndef SPEC_TEST_FIRST_BRANCH_SLOT
#define SPEC_TEST_FIRST_BRANCH_SLOT 6
#endif

#if (SPEC_TEST_MISPRED_LOG2 < 0) || (SPEC_TEST_MISPRED_LOG2 > 13)
#error "SPEC_TEST_MISPRED_LOG2 must be zero or between 1 and 13"
#endif

#if (SPEC_TEST_FIRST_BRANCH_SLOT != 6) && \
    (SPEC_TEST_FIRST_BRANCH_SLOT != 16)
#error "SPEC_TEST_FIRST_BRANCH_SLOT must be 6 or 16"
#endif

.equ SPEC_TEST_WARMUP_ITERS, 256
.equ SPEC_TEST_ITERS,        8192
.equ SPEC_TEST_PASS,         0x53504543544f4b21 /* "SPECTOK!" */
.equ SPEC_TEST_FAIL,         0x5350454342414421 /* "SPECBAD!" */

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl _start
.type _start, @function

_start:
    la      sp, __stack_top
    la      s0, spec_test_data
    li      s1, SPEC_TEST_WARMUP_ITERS
    li      s11, 0
    jal     zero, .Lclear_accumulators

/*
 * Exactly 32 instructions from the selected kernel through its loop branch.
 * The eight data words are all one, so every accumulator must equal the
 * measured iteration count after the measured phase.
 */
.balign 64
.Lactive_kernel:
#if SPEC_TEST_FIRST_BRANCH_SLOT == 6
.globl spec_test_kernel
spec_test_kernel:
    ld      t0, 64(s0)
#if SPEC_TEST_MISPRED_LOG2 == 0
    addi    t0, t0, 1
    addi    t0, t0, 1
    addi    t0, t0, 1
    addi    t0, t0, 1
    beq     t0, zero, .Lfail
#else
    addi    t0, t0, 0
    addi    t0, t0, 0
    addi    t0, t0, 0
    and     t0, t0, s1
    beq     t0, zero, .Lmispred_trampoline
#endif

.Lspec_work:
    ld      ra, 0(s0)
    add     a0, a0, ra
    addi    a1, a1, 1

    ld      gp, 8(s0)
    add     a2, a2, gp
    addi    a3, a3, 1

    ld      tp, 16(s0)
    add     a4, a4, tp
    addi    a5, a5, 1

    ld      t1, 24(s0)
    add     a6, a6, t1
    addi    a7, a7, 1

    ld      t2, 32(s0)
    add     s2, s2, t2
    addi    s3, s3, 1

    ld      t3, 40(s0)
    add     s4, s4, t3
    addi    s5, s5, 1

    ld      t4, 48(s0)
    add     s6, s6, t4
    addi    s7, s7, 1

    ld      t5, 56(s0)
    add     s8, s8, t5
    addi    s9, s9, 1

    addi    s1, s1, -1
    bnez    s1, .Lactive_kernel
.globl spec_test_kernel_end
spec_test_kernel_end:
#else
.globl spec_test_two_branch_kernel
spec_test_two_branch_kernel:
    ld      ra, 0(s0)
    add     a0, a0, ra
    addi    a1, a1, 1

    ld      gp, 8(s0)
    add     a2, a2, gp
    addi    a3, a3, 1

    ld      tp, 16(s0)
    add     a4, a4, tp
    addi    a5, a5, 1
    addi    a6, a6, 1

    ld      t0, 64(s0)
#if SPEC_TEST_MISPRED_LOG2 == 0
    addi    t0, t0, 1
    addi    t0, t0, 1
    addi    t0, t0, 1
    addi    t0, t0, 1
#else
    addi    t0, t0, 0
    addi    t0, t0, 0
    addi    t0, t0, 0
    and     t0, t0, s1
#endif
.globl spec_test_two_branch_first
spec_test_two_branch_first:
#if SPEC_TEST_MISPRED_LOG2 == 0
    beq     t0, zero, .Lfail
#else
    beq     t0, zero, .Lmispred_trampoline
#endif

.Lspec_work:
    ld      t1, 24(s0)
    add     a7, a7, t1
    addi    s2, s2, 1

    ld      t2, 32(s0)
    add     s3, s3, t2
    addi    s4, s4, 1

    ld      t3, 40(s0)
    add     s5, s5, t3
    addi    s6, s6, 1

    ld      t4, 48(s0)
    add     s7, s7, t4
    addi    s8, s8, 1

    ld      t5, 56(s0)
    add     s9, s9, t5

    addi    s1, s1, -1
.globl spec_test_two_branch_second
spec_test_two_branch_second:
    bnez    s1, .Lactive_kernel
.globl spec_test_two_branch_kernel_end
spec_test_two_branch_kernel_end:
#endif

    /* The warm-up and measured phases deliberately reuse both branch PCs. */
    bnez    s11, .Lmeasure_done

    li      s11, 1
    li      s1, SPEC_TEST_ITERS
    jal     zero, .Lclear_accumulators

.Lstart_measurement:
    fence   rw, rw
.globl spec_test_measure_begin
spec_test_measure_begin:
    csrr    s10, mcycle
    jal     zero, .Lactive_kernel

.Lmeasure_done:
.globl spec_test_measure_end
spec_test_measure_end:
    csrr    t6, mcycle
    sub     t6, t6, s10
    la      t5, spec_test_cycles
    sd      t6, 0(t5)
    fence   rw, rw

    li      t6, SPEC_TEST_ITERS
    bne     a0, t6, .Lfail
    bne     a1, t6, .Lfail
    bne     a2, t6, .Lfail
    bne     a3, t6, .Lfail
    bne     a4, t6, .Lfail
    bne     a5, t6, .Lfail
    bne     a6, t6, .Lfail
    bne     a7, t6, .Lfail
    bne     s2, t6, .Lfail
    bne     s3, t6, .Lfail
    bne     s4, t6, .Lfail
    bne     s5, t6, .Lfail
    bne     s6, t6, .Lfail
    bne     s7, t6, .Lfail
    bne     s8, t6, .Lfail
    bne     s9, t6, .Lfail

    li      a0, SPEC_TEST_PASS
    ebreak

.Lclear_accumulators:
    li      a0, 0
    li      a1, 0
    li      a2, 0
    li      a3, 0
    li      a4, 0
    li      a5, 0
    li      a6, 0
    li      a7, 0
    li      s2, 0
    li      s3, 0
    li      s4, 0
    li      s5, 0
    li      s6, 0
    li      s7, 0
    li      s8, 0
    li      s9, 0
    beqz    s11, .Lactive_kernel
    jal     zero, .Lstart_measurement

.Lfail:
    li      a0, SPEC_TEST_FAIL
    ebreak

.Lhalt:
    jal     zero, .Lhalt

#if SPEC_TEST_MISPRED_LOG2 != 0
/*
 * A rare taken direction redirects here, then back to the common work.  This
 * retains all arithmetic and makes the injected event exercise squash/refetch.
 */
.Lmispred_trampoline:
    jal     zero, .Lspec_work
#endif

.size _start, .-_start

.section .rodata.spec_test, "a", @progbits
.balign 64
.globl spec_test_data
.type spec_test_data, @object
spec_test_data:
    .rept 8
        .quad 1
    .endr
#if SPEC_TEST_MISPRED_LOG2 == 0
    .quad 1
#else
    .quad ((1 << SPEC_TEST_MISPRED_LOG2) - 1)
#endif
.size spec_test_data, .-spec_test_data

.section .bss.spec_test, "aw", @nobits
.balign 8
.globl spec_test_cycles
.type spec_test_cycles, @object
spec_test_cycles:
    .zero 8
.size spec_test_cycles, .-spec_test_cycles
