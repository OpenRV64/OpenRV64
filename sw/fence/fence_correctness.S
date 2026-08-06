/*
 * Sv39 architectural driver for external-boundary fence checking.
 *
 * The companion testbench delays selected ICX completions and rejects a
 * successor request if it becomes externally visible before its predecessor
 * completes.  Software pass/fail checks supplement that boundary checker;
 * they are not the ordering oracle.
 */

.equ FENCE_PASS,       0x46454e43454f4b21 /* "FENCEOK!" */
.equ FENCE_FAIL_BASE,  0x46454e4345460000 /* "FENCEF\0\0" */

.equ TEST_BASE,        0x40010000
.equ DEVICE_BASE,      0x40040000
.equ PRESSURE_LINES,   12

#ifndef FENCE_CASE
#define FENCE_CASE 0
#endif

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl _start
.type _start, @function

.macro FAIL case
    li      a0, (FENCE_FAIL_BASE + \case)
    ebreak
.endm

.macro CHECK_EQ actual, expected, case
    beq     \actual, \expected, 991f
    FAIL    \case
991:
.endm

_start:
    la      sp, __stack_top

    /* Prove the workload, rather than only its bootstrap, sees Sv39. */
    csrr    t0, satp
    srli    t0, t0, 60
    li      t1, 8
    CHECK_EQ t0, t1, 0x0001

#if FENCE_CASE == 0 || FENCE_CASE == 1
    /*
     * W -> W: the checker delays the first line completion and rejects the
     * second line if it reaches the ICX home first.
     */
    li      s0, TEST_BASE + 0x000
    li      s1, TEST_BASE + 0x040
    li      t0, 0x1111111111111111
    sd      t0, 0(s0)
    fence   w, w
    li      t0, 0x2222222222222222
    sd      t0, 0(s1)
#if FENCE_CASE == 1
    /* Demand traffic drains both posted successors without another fence. */
    ld      t1, 0x80(s0)
#endif
#endif

#if FENCE_CASE == 0 || FENCE_CASE == 2
    /*
     * W -> R: the following cold-line read must not cross ICX before the
     * older write response establishes visibility.
     */
    li      s0, TEST_BASE + 0x100
    li      s1, TEST_BASE + 0x140
    li      t0, 0x3333333333333333
    sd      t0, 0(s0)
    fence   w, r
    ld      t1, 0(s1)
    bnez    t1, .Lfail_0011
#endif

#if FENCE_CASE == 0 || FENCE_CASE == 3
    /* R -> R. */
    li      s0, TEST_BASE + 0x200
    li      s1, TEST_BASE + 0x240
    ld      t0, 0(s0)
    fence   r, r
    ld      t1, 0(s1)
    or      t0, t0, t1
    bnez    t0, .Lfail_0012
#endif

#if FENCE_CASE == 0 || FENCE_CASE == 4
    /* R -> W. */
    li      s0, TEST_BASE + 0x300
    li      s1, TEST_BASE + 0x340
    ld      t0, 0(s0)
    fence   r, w
    li      t1, 0x4444444444444444
    sd      t1, 0(s1)
#if FENCE_CASE == 4
    ld      t1, 0x380(s0)
#endif
#endif

#if FENCE_CASE == 5
    /*
     * I/O predecessor/successor bits.  These virtual addresses translate to
     * an uncached physical device page, not the cacheable RAM aperture.
     */
    li      s0, DEVICE_BASE + 0x000
    li      s1, DEVICE_BASE + 0x040
    li      t0, 0x51
    sd      t0, 0(s0)
    fence   o, o
    li      t0, 0x52
    sd      t0, 0(s1)

    li      s0, DEVICE_BASE + 0x100
    li      s1, DEVICE_BASE + 0x140
    li      t0, 0x53
    sd      t0, 0(s0)
    fence   o, i
    ld      t1, 0(s1)

    li      s0, DEVICE_BASE + 0x200
    li      s1, DEVICE_BASE + 0x240
    ld      t0, 0(s0)
    fence   i, i
    ld      t1, 0(s1)

    li      s0, DEVICE_BASE + 0x300
    li      s1, DEVICE_BASE + 0x340
    ld      t0, 0(s0)
    fence   i, o
    li      t1, 0x54
    sd      t1, 0(s1)
#endif

#if FENCE_CASE == 0 || FENCE_CASE == 6
    /*
     * Partial-byte stores must merge into one line transaction.  The checker
     * verifies the exact external byte strobes and data before allowing the
     * post-fence load.
     */
    li      s0, TEST_BASE + 0x400
    li      t0, 0x11
    sb      t0, 1(s0)
    li      t0, 0x3322
    sh      t0, 2(s0)
    li      t0, 0x77665544
    sw      t0, 4(s0)
    li      t0, 0xffeeddccbbaa9988
    sd      t0, 8(s0)
    fence   w, r
    ld      t1, 0x40(s0)
    bnez    t1, .Lfail_0020
#endif

#if FENCE_CASE == 0 || FENCE_CASE == 7
    /*
     * Twelve lines exceed the historical eight-line pressure point.  The
     * successor load may become visible only after every store completion.
     */
    li      s0, TEST_BASE + 0x800
    li      s1, PRESSURE_LINES
    li      t0, 1
.Lpressure:
    sd      t0, 0(s0)
    addi    s0, s0, 64
    addi    t0, t0, 1
    addi    s1, s1, -1
    bnez    s1, .Lpressure
    fence   w, r
    li      s0, TEST_BASE + 0xc00
    ld      t1, 0(s0)
    bnez    t1, .Lfail_0030
#endif

#if FENCE_CASE == 0 || FENCE_CASE == 8
    /*
     * Empty and back-to-back fences must make progress without inventing a
     * memory transaction.  The final external write proves execution passed
     * the sequence.
     */
    fence   r, r
    fence   w, w
    fence   o, i
    li      s0, TEST_BASE + 0xd00
    li      t0, 0x5555555555555555
    sd      t0, 0(s0)
    fence   w, r
#if FENCE_CASE == 8
    ld      t1, 0x40(s0)
#endif
#endif

#if FENCE_CASE == 0 || FENCE_CASE == 9
    /*
     * Populate I-cache with the old instruction, modify it through D-cache,
     * then require FENCE.I to wait for external store completion and refetch.
     */
    call    fence_smc_function
    li      t0, 1
    CHECK_EQ a0, t0, 0x0040
    la      s0, fence_smc_function
    li      t0, 0x00200513       /* addi a0, zero, 2 */
    sw      t0, 0(s0)
    fence.i
    call    fence_smc_function
    li      t0, 2
    CHECK_EQ a0, t0, 0x0041

#endif
#if FENCE_CASE == 0
    fence   r, r
#endif
    li      a0, FENCE_PASS
    ebreak

.Lfail_0011:
    FAIL    0x0011
.Lfail_0012:
    FAIL    0x0012
.Lfail_0020:
    FAIL    0x0020
.Lfail_0030:
    FAIL    0x0030

.size _start, .-_start

.section .fence_smc, "ax", @progbits
.option norvc
.balign 64
.globl fence_smc_function
.type fence_smc_function, @function
fence_smc_function:
    addi    a0, zero, 1
    ret
.size fence_smc_function, .-fence_smc_function

.section .fence_test, "aw", @progbits
.balign 4096
.globl fence_test_data
fence_test_data:
    .zero 0x2000
