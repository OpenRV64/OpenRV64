    .option norvc
    .section .text.startup, "ax", @progbits
    .globl _start
    .type _start, @function

/* OpenSBI v0.2 base, timer, and debug-console identifiers. */
    .equ SBI_EXT_BASE,               0x10
    .equ SBI_BASE_GET_SPEC_VERSION,  0
    .equ SBI_EXT_TIME,               0x54494d45
    .equ SBI_TIME_SET_TIMER,         0
    .equ SBI_EXT_DBCN,               0x4442434e
    .equ SBI_DBCN_WRITE_BYTE,        2

    .equ SSTATUS_SIE,                0x2
    .equ SIE_STIE,                   0x20
    .equ SCAUSE_STI,                 0x8000000000000005

    .equ ROOT_PT,                    0x80d00000
    .equ LEVEL1_PT,                  0x80d01000
    .equ LEVEL0_PT,                  0x80d02000
    .equ PAYLOAD_PA,                 0x80200000
    .equ COMPLETION_PA,              0x80200800

    /* PTEs: physical address shifted right by two, plus permission bits. */
    .equ LEVEL1_PTE,                 ((LEVEL1_PT >> 2) | 0x001)
    .equ LEVEL0_PTE,                 ((LEVEL0_PT >> 2) | 0x001)
    .equ PAYLOAD_PTE,                ((PAYLOAD_PA >> 2) | 0x0cf)

_start:
    /* Prove that OpenSBI entered this payload in S-mode and handles ECALL. */
    li      a7, SBI_EXT_BASE
    li      a6, SBI_BASE_GET_SPEC_VERSION
    ecall
    bnez    a0, failure

    /*
     * Install a three-level, 4 KiB identity mapping for this payload.  The
     * selected PTEs occupy line lanes 2, 1, and 0 respectively, which makes
     * the FPGA ICX-to-scalar adapter's 64-byte line assembly observable.
     */
    li      t0, ROOT_PT + (2 * 8)
    li      t1, LEVEL1_PTE
    sd      t1, 0(t0)
    li      t0, LEVEL1_PT + (1 * 8)
    li      t1, LEVEL0_PTE
    sd      t1, 0(t0)
    li      t0, LEVEL0_PT
    li      t1, PAYLOAD_PTE
    sd      t1, 0(t0)

    li      t0, (ROOT_PT >> 12)
    li      t1, 8
    slli    t1, t1, 60
    or      t0, t0, t1
    csrw    satp, t0
    sfence.vma x0, x0

    /* Retain the timer/delegation coverage from the bare payload. */
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
    li      t0, COMPLETION_PA
    li      t1, 0x5356333950545701
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
    .asciz  "OPENRV64 SBI SV39 PTW PASS\n"
failure_message:
    .asciz  "OPENRV64 SBI SV39 PTW FAIL\n"
