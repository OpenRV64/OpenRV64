/*
 * Exercise the Tomasulo register-load/LSU age-inversion boundary.
 *
 * The first cold load produces the address for an older aligned load.  A
 * younger naturally misaligned load has an independent, ready base and can
 * reach the MEM0 input first.  It must be replayed rather than occupying that
 * input while waiting to become the ordered ROB head.
 */

.equ MISALIGNED_ORDER_REPLAY_PASS, 0x4d49534f52444f4b /* "MISORDOK" */
.equ MISALIGNED_ORDER_REPLAY_FAIL, 0x4d49534f52444241 /* "MISORDBA" */

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl main
.type main, @function
main:
    la      s0, pointer_slot
    la      s1, misaligned_bytes
    li      s2, 0x11223344
    li      s3, 0x12345678

    ld      t0, 0(s0)
    lw      t1, 0(t0)
    lw      t2, 1(s1)

    bne     t1, s2, .Lfail
    bne     t2, s3, .Lfail
    /* Satisfy the Sv39 harness contract with one translated data store. */
    sw      t2, 8(s1)

    /*
     * Match the backward unaligned memmove loop that exposed stale scheduler
     * entries during Linux bring-up.  The branch from one iteration may still
     * be unresolved when the next iteration's naturally misaligned load is
     * offered to MEM0.
     */
    li      s4, 128
.Lcopy_outer:
    la      a4, copy_source + 257
    la      t4, copy_dest + 257
    la      t5, copy_dest + 1
.Lcopy:
    ld      t1, -8(a4)
    addi    a4, a4, -8
    addi    t4, t4, -8
    sd      t1, 0(t4)
    bne     t4, t5, .Lcopy
    addi    s4, s4, -1
    bnez    s4, .Lcopy_outer

    la      a4, copy_source + 1
    la      t4, copy_dest + 1
    li      t5, 32
.Lverify:
    ld      t1, 0(a4)
    ld      t2, 0(t4)
    bne     t1, t2, .Lfail
    addi    a4, a4, 8
    addi    t4, t4, 8
    addi    t5, t5, -1
    bnez    t5, .Lverify

    li      a0, MISALIGNED_ORDER_REPLAY_PASS
    ret

.Lfail:
    li      a0, MISALIGNED_ORDER_REPLAY_FAIL
    ret
.size main, .-main

.section .data.order_replay, "aw", @progbits
.balign 64
pointer_slot:
    .quad aligned_word

.balign 64
aligned_word:
    .word 0x11223344

.balign 64
misaligned_bytes:
    .byte 0xaa, 0x78, 0x56, 0x34, 0x12, 0xbb, 0xcc, 0xdd
    .word 0

.balign 64
copy_source:
    .rept 33
    .quad 0x0123456789abcdef
    .endr

.balign 64
copy_dest:
    .zero 264
