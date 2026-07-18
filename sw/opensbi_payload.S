    .option norvc
    .section .text.startup, "ax", @progbits
    .globl _start
    .type _start, @function

/* OpenSBI v0.2 base extension and debug-console identifiers. */
    .equ SBI_EXT_BASE,             0x10
    .equ SBI_BASE_GET_SPEC_VERSION, 0
    .equ SBI_EXT_DBCN,             0x4442434e
    .equ SBI_DBCN_WRITE_BYTE,      2

_start:
    /* Prove that OpenSBI entered this payload in S-mode and handles ECALL. */
    li      a7, SBI_EXT_BASE
    li      a6, SBI_BASE_GET_SPEC_VERSION
    ecall
    bnez    a0, 2f

    la      t0, payload_message
    j       3f
2:
    la      t0, failure_message
3:
    lbu     a0, 0(t0)
    beqz    a0, 4f
    addi    t0, t0, 1
    li      a7, SBI_EXT_DBCN
    li      a6, SBI_DBCN_WRITE_BYTE
    ecall
    j       3b

4:
    /* A testbench-visible completion mark outside OpenSBI's protected area. */
    li      t0, 0x80e00000
    li      t1, 0x5342495041535301
    sd      t1, 0(t0)
5:
    wfi
    j       5b

    .size _start, . - _start

    .section .rodata, "a", @progbits
payload_message:
    .asciz  "OPENRV64 SBI PAYLOAD\n"
failure_message:
    .asciz  "OPENRV64 SBI FAIL\n"
