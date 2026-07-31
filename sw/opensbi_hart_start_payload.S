    .option norvc
    .section .text.startup, "ax", @progbits
    .globl _start
    .type _start, @function

#ifndef OPENRV64_HART_COUNT
#error OPENRV64_HART_COUNT must be defined
#endif

#if OPENRV64_HART_COUNT != 2 && OPENRV64_HART_COUNT != 4
#error Hart-start payload requires two or four harts
#endif

/*
 * SBI HSM identifiers and the fixed scratch area used by this directed test.
 * The scratch area is outside the firmware/payload/FDT regions and is cleared
 * explicitly by hart 0 before any secondary is started.
 */
    .equ SBI_EXT_HSM,                 0x48534d
    .equ SBI_HSM_HART_START,          0
    .equ SBI_EXT_DBCN,                0x4442434e
    .equ SBI_DBCN_WRITE_BYTE,         2

    .equ TEST_BASE,                   0x80d00000
    .equ STARTED_MASK,                TEST_BASE + 0x0000
    .equ GO_FLAG,                     TEST_BASE + 0x0040
    .equ DONE_MASK,                   TEST_BASE + 0x0080
    .equ RESPONSE_MASK,               TEST_BASE + 0x00c0
    .equ ERROR_MASK,                  TEST_BASE + 0x0100
    .equ MAILBOX_BASE,                TEST_BASE + 0x0200
    .equ MAILBOX_STRIDE,              64
    .equ ATOMIC_COUNTER,              TEST_BASE + 0x1000

    .equ COMPLETION_ADDR,             0x80e00000
    .equ FAILURE_ADDR,                0x80e00008
    .equ COMPLETION_VALUE,            0x5342495041535301

    .equ SIGNATURE_BASE,              0x4841525400000000
    .equ COMMAND_BASE,                0x434d440000000100
    .equ OPAQUE_BASE,                 0x4f50415100000000
    .equ ACTIVE_MASK_VALUE,           (1 << OPENRV64_HART_COUNT) - 1
    .equ ATOMIC_ITERATIONS,           64
    .equ ATOMIC_EXPECTED,             \
        OPENRV64_HART_COUNT * ATOMIC_ITERATIONS

/*
 * OpenSBI enters only the coldboot hart here. Secondary harts remain in
 * sbi_hsm_hart_wait() until hart 0 issues SBI HSM hart_start calls below.
 */
_start:
    bnez    a0, primary_bad_entry

    /* Clear every shared control line and all possible private mailboxes. */
    li      t0, STARTED_MASK
    sd      zero, 0(t0)
    li      t0, GO_FLAG
    sd      zero, 0(t0)
    li      t0, DONE_MASK
    sd      zero, 0(t0)
    li      t0, RESPONSE_MASK
    sd      zero, 0(t0)
    li      t0, ERROR_MASK
    sd      zero, 0(t0)
    li      t0, ATOMIC_COUNTER
    sd      zero, 0(t0)

    li      t0, MAILBOX_BASE
    li      t1, 4
1:
    sd      zero, 0(t0)
    sd      zero, 8(t0)
    sd      zero, 16(t0)
    sd      zero, 24(t0)
    addi    t0, t0, MAILBOX_STRIDE
    addi    t1, t1, -1
    bnez    t1, 1b
    fence   rw, rw

    /*
     * Publish and read back hart 0's private line before starting the
     * secondaries. The same checks run independently on each secondary.
     */
    li      s0, MAILBOX_BASE
    li      s1, SIGNATURE_BASE
    sd      s1, 0(s0)
    fence   rw, rw
    ld      t0, 0(s0)
    bne     t0, s1, primary_private_failure

    li      t0, STARTED_MASK
    li      t1, 1
    amoor.d.aqrl zero, t1, (t0)

    /* Start each FDT-described secondary at the same S-mode entry point. */
    li      s2, 1
2:
    li      t0, OPENRV64_HART_COUNT
    bgeu    s2, t0, 3f
    mv      a0, s2
    la      a1, secondary_entry
    li      a2, OPAQUE_BASE
    or      a2, a2, s2
    li      a7, SBI_EXT_HSM
    li      a6, SBI_HSM_HART_START
    ecall
    bnez    a0, primary_hart_start_failure
    addi    s2, s2, 1
    j       2b

    /* Wait until every secondary has checked hartid, opaque, and memory. */
3:
    li      s3, ACTIVE_MASK_VALUE
4:
    li      t0, ERROR_MASK
    ld      t1, 0(t0)
    bnez    t1, primary_secondary_failure
    li      t0, STARTED_MASK
    ld      t1, 0(t0)
    bne     t1, s3, 4b

    /* Release all active harts into the contended LR/SC test together. */
    fence   rw, rw
    li      t0, GO_FLAG
    li      t1, 1
    sd      t1, 0(t0)
    fence   rw, rw

    li      a0, 0
    jal     ra, atomic_increment_test

    li      t0, DONE_MASK
    li      t1, 1
    amoor.d.aqrl zero, t1, (t0)

5:
    li      t0, ERROR_MASK
    ld      t1, 0(t0)
    bnez    t1, primary_secondary_failure
    li      t0, DONE_MASK
    ld      t1, 0(t0)
    bne     t1, s3, 5b

    li      t0, ATOMIC_COUNTER
    ld      t1, 0(t0)
    li      t2, ATOMIC_EXPECTED
    bne     t1, t2, primary_atomic_failure

    /*
     * Read each hart's private publication, then write a command into that
     * same cache line. Each secondary must observe the boot-hart store and
     * return a response, forcing coherent visibility in both directions.
     */
    li      s2, 0
    li      s4, MAILBOX_BASE
6:
    li      t0, OPENRV64_HART_COUNT
    bgeu    s2, t0, 7f
    li      t1, SIGNATURE_BASE
    add     t1, t1, s2
    ld      t2, 0(s4)
    bne     t1, t2, primary_signature_failure
    li      t1, COMMAND_BASE
    add     t1, t1, s2
    sd      t1, 8(s4)
    addi    s4, s4, MAILBOX_STRIDE
    addi    s2, s2, 1
    j       6b

    /* Hart 0 consumes its own command using the same response transform. */
7:
    fence   rw, rw
    li      t0, MAILBOX_BASE
    ld      t1, 8(t0)
    li      t2, SIGNATURE_BASE
    add     t1, t1, t2
    sd      t1, 16(t0)
    fence   rw, rw
    li      t0, RESPONSE_MASK
    li      t1, 1
    amoor.d.aqrl zero, t1, (t0)

8:
    li      t0, ERROR_MASK
    ld      t1, 0(t0)
    bnez    t1, primary_secondary_failure
    li      t0, RESPONSE_MASK
    ld      t1, 0(t0)
    bne     t1, s3, 8b

    /* Validate every response rather than trusting only the response mask. */
    li      s2, 0
    li      s4, MAILBOX_BASE
9:
    li      t0, OPENRV64_HART_COUNT
    bgeu    s2, t0, 10f
    li      t1, SIGNATURE_BASE
    li      t2, COMMAND_BASE
    add     t1, t1, t2
    slli    t2, s2, 1
    add     t1, t1, t2
    ld      t2, 16(s4)
    bne     t1, t2, primary_response_failure
    addi    s4, s4, MAILBOX_STRIDE
    addi    s2, s2, 1
    j       9b

10:
    la      a0, pass_message
    jal     ra, print_string
    li      t0, COMPLETION_ADDR
    li      t1, COMPLETION_VALUE
    sd      t1, 0(t0)
    fence   rw, rw
11:
    wfi
    j       11b

/*
 * OpenSBI supplies a0=hartid and a1=the opaque value passed to hart_start.
 * This code runs in S-mode and deliberately shares no stack with hart 0.
 */
    .balign 4
    .globl secondary_entry
    .type secondary_entry, @function
secondary_entry:
    mv      s0, a0
    mv      s1, a1
    beqz    s0, secondary_identity_failure
    li      t0, OPENRV64_HART_COUNT
    bgeu    s0, t0, secondary_identity_failure
    li      t0, OPAQUE_BASE
    or      t0, t0, s0
    bne     s1, t0, secondary_opaque_failure

    slli    t0, s0, 6
    li      s2, MAILBOX_BASE
    add     s2, s2, t0
    li      s3, SIGNATURE_BASE
    add     s3, s3, s0
    sd      s3, 0(s2)
    fence   rw, rw
    ld      t0, 0(s2)
    bne     t0, s3, secondary_private_failure

    li      t0, 1
    sll     s4, t0, s0
    li      t0, STARTED_MASK
    amoor.d.aqrl zero, s4, (t0)

12:
    li      t0, GO_FLAG
    ld      t1, 0(t0)
    beqz    t1, 12b
    fence   rw, rw

    mv      a0, s0
    jal     ra, atomic_increment_test

    li      t0, DONE_MASK
    amoor.d.aqrl zero, s4, (t0)

13:
    ld      t0, 8(s2)
    beqz    t0, 13b
    li      t1, COMMAND_BASE
    add     t1, t1, s0
    bne     t0, t1, secondary_command_failure
    add     t0, t0, s3
    sd      t0, 16(s2)
    fence   rw, rw
    li      t0, RESPONSE_MASK
    amoor.d.aqrl zero, s4, (t0)
14:
    wfi
    j       14b
    .size secondary_entry, . - secondary_entry

/*
 * Perform a contended 64-bit LR/SC increment loop. a0 is retained only for
 * diagnostics; all active harts update the same cache line.
 */
    .balign 4
atomic_increment_test:
    li      t0, ATOMIC_COUNTER
    li      t1, ATOMIC_ITERATIONS
15:
    lr.d.aq t2, (t0)
    addi    t3, t2, 1
    sc.d.rl t4, t3, (t0)
    bnez    t4, 15b
    addi    t1, t1, -1
    bnez    t1, 15b
    fence   rw, rw
    ret

/* Secondary failures are published to hart 0 without concurrent console I/O. */
secondary_identity_failure:
    li      t0, 1
    j       secondary_failure
secondary_opaque_failure:
    li      t0, 2
    j       secondary_failure
secondary_private_failure:
    li      t0, 3
    j       secondary_failure
secondary_command_failure:
    li      t0, 4
secondary_failure:
    slli    t1, s0, 6
    li      t2, MAILBOX_BASE
    add     t2, t2, t1
    slli    t1, s0, 8
    or      t0, t0, t1
    sd      t0, 24(t2)
    fence   rw, rw
    li      t2, 1
    sll     t2, t2, s0
    li      t1, ERROR_MASK
    amoor.d.aqrl zero, t2, (t1)
16:
    wfi
    j       16b

primary_bad_entry:
    li      a0, 0x101
    j       primary_failure
primary_private_failure:
    li      a0, 0x102
    j       primary_failure
primary_hart_start_failure:
    li      a0, 0x103
    j       primary_failure
primary_secondary_failure:
    li      a0, 0x104
    j       primary_failure
primary_atomic_failure:
    li      a0, 0x105
    j       primary_failure
primary_signature_failure:
    li      a0, 0x106
    j       primary_failure
primary_response_failure:
    li      a0, 0x107

primary_failure:
    li      t0, FAILURE_ADDR
    sd      a0, 0(t0)
    fence   rw, rw
    la      a0, failure_message
    jal     ra, print_string
17:
    wfi
    j       17b

print_string:
    mv      t0, a0
18:
    lbu     a0, 0(t0)
    beqz    a0, 19f
    addi    t0, t0, 1
    li      a7, SBI_EXT_DBCN
    li      a6, SBI_DBCN_WRITE_BYTE
    ecall
    j       18b
19:
    ret

    .size _start, . - _start

    .section .rodata, "a", @progbits
pass_message:
    .asciz  "OPENRV64 SBI HART_START MEMORY PASS\n"
failure_message:
    .asciz  "OPENRV64 SBI HART_START MEMORY FAIL\n"
