    .section .text.init
    .globl _start
_start:
    li      t0, 0x11223344
    li      t1, 0x11223344
    bne     t0, t1, fail
    la      t0, scratch
    li      t1, 0x55aa55aa
    sd      t1, 0(t0)
    ld      t2, 0(t0)
    bne     t1, t2, fail

pass:
    la      t0, tohost
    li      t1, 1
    sd      t1, 0(t0)
1:  j       1b

fail:
    la      t0, tohost
    li      t1, 3
    sd      t1, 0(t0)
2:  j       2b

    .section .bss
    .balign 8
scratch:
    .dword 0

    .section .tohost,"aw",@progbits
    .balign 64
    .globl tohost
tohost:
    .dword 0
    .globl fromhost
fromhost:
    .dword 0
