/*
 * Integrated same-line store-extension benchmark.
 *
 * The shared Sv39 runtime maps supervisor VA 0x40000000 to PA 0x80000000.
 * Sixteen lines are made resident before the timed interval.  The measured
 * loop then performs 4096 translated 64-bit stores: eight adjacent stores per
 * line, sixteen lines per pass, and thirty-two passes.  The final fence keeps
 * the result comparable across posted-store implementations.
 */

.equ STORE_EXTENSION_LINES, 16
.equ STORE_EXTENSION_PASSES, 32
.equ STORE_EXTENSION_WORDS, (STORE_EXTENSION_LINES * 8)
.equ STORE_EXTENSION_EXPECT, STORE_EXTENSION_PASSES

#ifndef OPENRV64_STORE_EXTENSION_ENTRY
#define OPENRV64_STORE_EXTENSION_ENTRY main
#endif

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl OPENRV64_STORE_EXTENSION_ENTRY
.type OPENRV64_STORE_EXTENSION_ENTRY, @function

OPENRV64_STORE_EXTENSION_ENTRY:

    /* Demand-fill each target line before measuring valid-hit stores. */
    la      s0, store_extension_data
    li      s1, STORE_EXTENSION_LINES
.Lwarm:
    ld      t0, 0(s0)
    addi    s0, s0, 64
    addi    s1, s1, -1
    bnez    s1, .Lwarm
    fence   rw, rw

    li      s2, STORE_EXTENSION_PASSES
    li      t0, 1
    csrr    s3, cycle

.globl store_extension_measure_begin
store_extension_measure_begin:
    la      s0, store_extension_data
    li      s1, STORE_EXTENSION_LINES
.Lstore_line:
    sd      t0, 0(s0)
    sd      t0, 8(s0)
    sd      t0, 16(s0)
    sd      t0, 24(s0)
    sd      t0, 32(s0)
    sd      t0, 40(s0)
    sd      t0, 48(s0)
    sd      t0, 56(s0)
    addi    s0, s0, 64
    addi    s1, s1, -1
    bnez    s1, .Lstore_line
    addi    t0, t0, 1
    addi    s2, s2, -1
    bnez    s2, store_extension_measure_begin

    fence   rw, rw
    csrr    s4, cycle
    sub     s4, s4, s3

    /* Verify every byte outside the measured interval. */
    la      s0, store_extension_data
    li      s1, STORE_EXTENSION_WORDS
    li      t0, STORE_EXTENSION_EXPECT
.Lverify:
    ld      t1, 0(s0)
    bne     t0, t1, .Lfail
    addi    s0, s0, 8
    addi    s1, s1, -1
    bnez    s1, .Lverify

    mv      a0, s4
.globl store_extension_measure_end
store_extension_measure_end:
    nop
    ret

.Lfail:
    li      a0, 0x53544f5245424144 /* "STOREBAD" */
    ret

.size OPENRV64_STORE_EXTENSION_ENTRY, .-OPENRV64_STORE_EXTENSION_ENTRY

.section .data.store_extension, "aw", @progbits
.balign 64
.globl store_extension_data
.type store_extension_data, @object
store_extension_data:
    .zero STORE_EXTENSION_LINES * 64
.size store_extension_data, .-store_extension_data
