/*
 * Single-hart RV64A architectural tests for the complete production path:
 *
 *   3P core -> L1D -> native ICX -> L2 -> AXI SRAM
 *
 * The current implementation keeps LR/SC reservation state in the LSU and
 * performs each AMO as a locally serialized read followed by a write.  These
 * tests deliberately validate that contract; they are not evidence of
 * multicore atomicity.
 *
 * On success a0 is "ATOMICOK".  On failure it is "ATOMFA" followed by a
 * 16-bit case number, which the SoC testbench prints in its a0 mismatch.
 */

.equ ATOMIC_PASS,      0x41544f4d49434f4b /* "ATOMICOK" */
.equ ATOMIC_FAIL_BASE, 0x41544f4d46410000 /* "ATOMFA\0\0" */

#ifndef OPENRV64_ATOMIC_ENTRY
#define OPENRV64_ATOMIC_ENTRY main
#endif

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl OPENRV64_ATOMIC_ENTRY
.type OPENRV64_ATOMIC_ENTRY, @function

/*
 * CHECK_EQ actual, expected, case
 *
 * Both operands must be registers.  Keep the failure path inline so the
 * reported case remains stable when more checks are inserted later.
 */
.macro CHECK_EQ actual, expected, case
    beq     \actual, \expected, 991f
    li      a0, (ATOMIC_FAIL_BASE + \case)
    j       atomic_fail
991:
.endm

.macro CHECK_NZ actual, case
    bnez    \actual, 991f
    li      a0, (ATOMIC_FAIL_BASE + \case)
    j       atomic_fail
991:
.endm

/*
 * Every AMO case initializes the operand through an ordinary posted store,
 * performs the atomic, and reloads it normally.  Besides checking the ALU
 * operation, this exercises store-buffer draining before the atomic and L1D
 * invalidation/reload after it.
 */
.macro TEST_AMO_D op, initial, operand, final, case
    la      s0, atomic_amo_slot
    li      t0, \initial
    sd      t0, 0(s0)
    li      t1, \operand
    \op     t2, t1, (s0)
    li      t3, \initial
    CHECK_EQ t2, t3, \case
    ld      t2, 0(s0)
    li      t3, \final
    CHECK_EQ t2, t3, (\case + 1)
.endm

/*
 * Word AMOs target address+4.  The expected 64-bit line image therefore
 * checks both sign extension of rd and preservation of the adjacent low word.
 */
.macro TEST_AMO_W op, initial64, operand, old_result, final64, case
    la      s0, atomic_amo_slot
    li      t0, \initial64
    sd      t0, 0(s0)
    addi    s1, s0, 4
    li      t1, \operand
    \op     t2, t1, (s1)
    li      t3, \old_result
    CHECK_EQ t2, t3, \case
    ld      t2, 0(s0)
    li      t3, \final64
    CHECK_EQ t2, t3, (\case + 1)
.endm

OPENRV64_ATOMIC_ENTRY:

    /*
     * SC without a reservation fails and does not modify memory.
     */
    la      s0, atomic_lrsc_slot
    li      t0, 0x1122334455667788
    sd      t0, 0(s0)
    li      t1, 0x8877665544332211
    sc.d    t2, t1, (s0)
    CHECK_NZ t2, 0x0001
    ld      t2, 0(s0)
    li      t3, 0x1122334455667788
    CHECK_EQ t2, t3, 0x0002

    /*
     * A matching LR.D/SC.D succeeds once.  A second SC fails and leaves the
     * successful value intact.  aq/rl encodings are included explicitly.
     */
    li      t0, 0x0123456789abcdef
    sd      t0, 0(s0)
    lr.d.aq t1, (s0)
    CHECK_EQ t1, t0, 0x0010
    li      t1, 0xfedcba9876543210
    sc.d.rl t2, t1, (s0)
    li      t3, 0
    CHECK_EQ t2, t3, 0x0011
    ld      t2, 0(s0)
    CHECK_EQ t2, t1, 0x0012
    li      t1, 0x5555aaaa5555aaaa
    sc.d    t2, t1, (s0)
    CHECK_NZ t2, 0x0013
    ld      t2, 0(s0)
    li      t3, 0xfedcba9876543210
    CHECK_EQ t2, t3, 0x0014

    /*
     * LR.W sign-extends its result.  SC.W at address+4 updates only the high
     * word and consumes the reservation.
     */
    li      t0, 0x8000000189abcdef
    sd      t0, 0(s0)
    addi    s1, s0, 4
    lr.w.aq t1, (s1)
    li      t3, 0xffffffff80000001
    CHECK_EQ t1, t3, 0x0020
    li      t1, 0x12345678
    sc.w.rl t2, t1, (s1)
    li      t3, 0
    CHECK_EQ t2, t3, 0x0021
    ld      t2, 0(s0)
    li      t3, 0x1234567889abcdef
    CHECK_EQ t2, t3, 0x0022
    li      t1, 0x76543210
    sc.w    t2, t1, (s1)
    CHECK_NZ t2, 0x0023
    ld      t2, 0(s0)
    li      t3, 0x1234567889abcdef
    CHECK_EQ t2, t3, 0x0024

    /*
     * An SC to a different address fails.  That failed attempt also consumes
     * the reservation, so a subsequent SC to the original address fails.
     */
    la      s0, atomic_lrsc_pair
    li      t0, 0x1111111111111111
    sd      t0, 0(s0)
    li      t0, 0x2222222222222222
    sd      t0, 8(s0)
    lr.d    t1, (s0)
    li      t3, 0x1111111111111111
    CHECK_EQ t1, t3, 0x0030
    li      t1, 0x3333333333333333
    addi    s1, s0, 8
    sc.d    t2, t1, (s1)
    CHECK_NZ t2, 0x0031
    ld      t2, 8(s0)
    li      t3, 0x2222222222222222
    CHECK_EQ t2, t3, 0x0032
    li      t1, 0x4444444444444444
    sc.d    t2, t1, (s0)
    CHECK_NZ t2, 0x0033
    ld      t2, 0(s0)
    li      t3, 0x1111111111111111
    CHECK_EQ t2, t3, 0x0034

    /*
     * A completed ordinary store clears the local reservation.  The atomic
     * must also observe that store after the L1D posted-store path drains.
     */
    la      s0, atomic_lrsc_slot
    li      t0, 5
    sd      t0, 0(s0)
    lr.d    t1, (s0)
    CHECK_EQ t1, t0, 0x0040
    li      t0, 7
    sd      t0, 0(s0)
    li      t1, 9
    sc.d    t2, t1, (s0)
    CHECK_NZ t2, 0x0041
    ld      t2, 0(s0)
    CHECK_EQ t2, t0, 0x0042

    /* 64-bit AMO operation and returned-old-value coverage. */
    TEST_AMO_D amoswap.d.aqrl, 0x1122334455667788, \
        0x8877665544332211, 0x8877665544332211, 0x0100
    TEST_AMO_D amoadd.d.aq, 0xfffffffffffffffe, 3, 1, 0x0102
    TEST_AMO_D amoxor.d.rl, 0xaaaa5555aaaa5555, \
        0xffff0000ffff0000, 0x5555555555555555, 0x0104
    TEST_AMO_D amoand.d, 0xf0f00f0ff0f00f0f, \
        0xff00ff00ff00ff00, 0xf0000f00f0000f00, 0x0106
    TEST_AMO_D amoor.d, 0xf0f00f0ff0f00f0f, \
        0xff00ff00ff00ff00, 0xfff0ff0ffff0ff0f, 0x0108
    TEST_AMO_D amomin.d, 0xfffffffffffffffb, 3, \
        0xfffffffffffffffb, 0x010a
    TEST_AMO_D amomax.d, 0xfffffffffffffffb, 3, 3, 0x010c
    TEST_AMO_D amominu.d, 0xfffffffffffffffb, 3, 3, 0x010e
    TEST_AMO_D amomaxu.d, 0xfffffffffffffffb, 3, \
        0xfffffffffffffffb, 0x0110

    /*
     * Repeat every operation as a high-lane word AMO.  The low 32-bit guard
     * catches bad strobes and lane shifts.
     */
    TEST_AMO_W amoswap.w.aqrl, 0x8000000189abcdef, 0x12345678, \
        0xffffffff80000001, 0x1234567889abcdef, 0x0200
    TEST_AMO_W amoadd.w.aq, 0xffffffff89abcdef, 2, \
        0xffffffffffffffff, 0x0000000189abcdef, 0x0202
    TEST_AMO_W amoxor.w.rl, 0xaaaa555589abcdef, 0xffff0000, \
        0xffffffffaaaa5555, 0x5555555589abcdef, 0x0204
    TEST_AMO_W amoand.w, 0xf0f00f0f89abcdef, 0xff00ff00, \
        0xfffffffff0f00f0f, 0xf0000f0089abcdef, 0x0206
    TEST_AMO_W amoor.w, 0xf0f00f0f89abcdef, 0xff00ff00, \
        0xfffffffff0f00f0f, 0xfff0ff0f89abcdef, 0x0208
    TEST_AMO_W amomin.w, 0xfffffffb89abcdef, 3, \
        0xfffffffffffffffb, 0xfffffffb89abcdef, 0x020a
    TEST_AMO_W amomax.w, 0xfffffffb89abcdef, 3, \
        0xfffffffffffffffb, 0x0000000389abcdef, 0x020c
    TEST_AMO_W amominu.w, 0xfffffffb89abcdef, 3, \
        0xfffffffffffffffb, 0x0000000389abcdef, 0x020e
    TEST_AMO_W amomaxu.w, 0xfffffffb89abcdef, 3, \
        0xfffffffffffffffb, 0xfffffffb89abcdef, 0x0210

    fence   rw, rw
    li      a0, ATOMIC_PASS
    ret

atomic_fail:
    ret

.size OPENRV64_ATOMIC_ENTRY, .-OPENRV64_ATOMIC_ENTRY

.section .data.atomic, "aw", @progbits
.balign 64
.globl atomic_lrsc_slot
atomic_lrsc_slot:
    .quad 0

.balign 16
.globl atomic_lrsc_pair
atomic_lrsc_pair:
    .quad 0
    .quad 0

.balign 64
.globl atomic_amo_slot
atomic_amo_slot:
    .quad 0
