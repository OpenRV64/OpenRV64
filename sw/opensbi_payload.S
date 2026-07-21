    .option norvc
    .section .text.startup, "ax", @progbits
    .globl _start
    .type _start, @function

/* OpenSBI v0.2 base, timer, and debug-console identifiers. */
    .equ SBI_EXT_BASE,             0x10
    .equ SBI_BASE_GET_SPEC_VERSION, 0
    .equ SBI_EXT_TIME,             0x54494d45
    .equ SBI_TIME_SET_TIMER,       0
    .equ SBI_EXT_DBCN,             0x4442434e
    .equ SBI_DBCN_WRITE_BYTE,      2

    .equ SSTATUS_SIE,              0x2
    .equ SIE_STIE,                 0x20
    .equ SCAUSE_STI,               0x8000000000000005

_start:
    /* Prove that OpenSBI entered this payload in S-mode and handles ECALL. */
    li      a7, SBI_EXT_BASE
    li      a6, SBI_BASE_GET_SPEC_VERSION
    ecall
    bnez    a0, failure

    /*
     * Exercise the complete Linux clock-event path: SBI set_timer programs
     * MTIME, OpenSBI handles MTIP and writes mip.STIP, and the delegated
     * supervisor timer interrupt enters timer_trap.
     */
    la      t0, timer_trap
    csrw    stvec, t0
    li      t0, SIE_STIE
    csrw    sie, t0

    rdtime  a0
    li      t0, 10000
    add     a0, a0, t0
    li      a7, SBI_EXT_TIME
    li      a6, SBI_TIME_SET_TIMER
    ecall
    bnez    a0, failure
    csrsi   sstatus, SSTATUS_SIE

1:
    wfi
    j       1b

    .balign 4
timer_trap:
    csrr    t0, scause
    li      t1, SCAUSE_STI
    bne     t0, t1, failure

    /* Clear STIP and leave the next event disabled. */
    li      a0, -1
    li      a7, SBI_EXT_TIME
    li      a6, SBI_TIME_SET_TIMER
    ecall
    bnez    a0, failure
    csrci   sstatus, SSTATUS_SIE

    la      t0, payload_message
2:
    lbu     a0, 0(t0)
    beqz    a0, 3f
    addi    t0, t0, 1
    li      a7, SBI_EXT_DBCN
    li      a6, SBI_DBCN_WRITE_BYTE
    ecall
    j       2b

3:
    /* A testbench-visible completion mark outside OpenSBI's protected area. */
    li      t0, 0x80e00000
    li      t1, 0x5342495041535301
    sd      t1, 0(t0)
4:
    wfi
    j       4b

failure:
    la      t0, failure_message
5:
    lbu     a0, 0(t0)
    beqz    a0, 6f
    addi    t0, t0, 1
    li      a7, SBI_EXT_DBCN
    li      a6, SBI_DBCN_WRITE_BYTE
    ecall
    j       5b
6:
    wfi
    j       6b

    .size _start, . - _start

    .section .rodata, "a", @progbits
payload_message:
    .asciz  "OPENRV64 SBI TIMER PAYLOAD\n"
failure_message:
    .asciz  "OPENRV64 SBI FAIL\n"
