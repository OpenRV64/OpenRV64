    .option norvc
    .section .text.startup, "ax", @progbits
    .globl _start
    .type _start, @function

/*
 * The reset ROM only jumps to 0x8000_0000.  This RAM-resident trampoline
 * supplies the OpenSBI fw_jump entry contract and keeps policy out of ROM.
 */
_start:
    li      a0, 0
    li      a1, 0x8ff00000
    li      a2, 0
    li      t0, 0x80100000
    jr      t0

    .size _start, . - _start
