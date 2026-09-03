/*
 * Reproduce the control shape of Linux's queued-spinlock cmpxchg loop under
 * Sv39: LR, compare, SC, and a taken retry branch which selectively squashes
 * younger work.  SC deliberately targets the adjacent doubleword, so every
 * attempt fails and the recovery path is exercised thousands of times.
 */

#ifndef OPENRV64_LRSC_REDIRECT_STRESS_ITERS
#define OPENRV64_LRSC_REDIRECT_STRESS_ITERS 4096
#endif

.equ LRSC_REDIRECT_STRESS_PASS, 0x4c5253434f4b2121 /* "LRSCOK!!" */
.equ LRSC_REDIRECT_STRESS_FAIL, 0x4c52534342414400 /* "LRSCBAD\0" */

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl main
.type main, @function
main:
    la      s0, lrsc_redirect_slots
    sd      zero, 0(s0)
    sd      zero, 8(s0)
    addi    s1, s0, 8
    li      s2, OPENRV64_LRSC_REDIRECT_STRESS_ITERS
    li      a2, 1

.Lretry:
    lr.d    a3, (s0)
    bne     a3, zero, .Lfail
    sc.d.rl a1, a2, (s1)
    beq     a1, zero, .Lfail
    addi    s2, s2, -1
    bnez    s2, .Lretry

    ld      a3, 0(s0)
    bne     a3, zero, .Lfail
    ld      a3, 8(s0)
    bne     a3, zero, .Lfail
    li      a0, LRSC_REDIRECT_STRESS_PASS
    ret

.Lfail:
    li      a0, LRSC_REDIRECT_STRESS_FAIL
    ret
.size main, .-main

.section .data.atomic, "aw", @progbits
.balign 64
lrsc_redirect_slots:
    .quad 0
    .quad 0
