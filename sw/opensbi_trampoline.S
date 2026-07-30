    .option norvc
    .section .text.startup, "ax", @progbits
    .globl _start
    .type _start, @function

#ifndef OPENRV64_FDT_ADDR
#define OPENRV64_FDT_ADDR 0x8ff00000
#endif

/*
 * The reset ROM forwards mhartid in a0 and jumps to 0x8000_0000.  This
 * RAM-resident trampoline preserves a0, supplies the remaining OpenSBI
 * fw_jump entry state, and keeps the FDT address policy out of ROM.
 */
_start:
    li      a1, OPENRV64_FDT_ADDR
    li      a2, 0
    li      t0, 0x80100000
    jr      t0

    .size _start, . - _start
