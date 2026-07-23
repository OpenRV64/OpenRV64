/*
 * Five-neighbor integer stencil with a 64 KiB source.
 *
 * A sliding window turns the five logical input streams into one new demand
 * load per output while retaining real neighbor reuse.  The output stream is
 * checked in full after the timed region.
 */

.equ STENCIL_BYTES, 65536
.equ STENCIL_WORDS, (STENCIL_BYTES / 8)
.equ STENCIL_OUTPUT_WORDS, (STENCIL_WORDS - 4)
.equ STENCIL_PASS, 0x5354454e355f4f4b /* "STEN5_OK" */
.equ STENCIL_FAIL, 0x5354454e355f4244 /* "STEN5_BD" */

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl _start
.type _start, @function

_start:
    la      sp, __stack_top
    la      s0, stencil_source
    la      s1, stencil_output
    li      s2, STENCIL_OUTPUT_WORDS
    ld      t0, 0(s0)
    ld      t1, 8(s0)
    ld      t2, 16(s0)
    ld      t3, 24(s0)
    fence   rw, rw
    csrr    s3, mcycle

.globl stencil_measure_begin
stencil_measure_begin:
    ld      t4, 32(s0)
    add     t5, t0, t1
    add     t5, t5, t2
    add     t5, t5, t3
    add     t5, t5, t4
    sd      t5, 0(s1)
    addi    t0, t1, 0
    addi    t1, t2, 0
    addi    t2, t3, 0
    addi    t3, t4, 0
    addi    s0, s0, 8
    addi    s1, s1, 8
    addi    s2, s2, -1
    bnez    s2, stencil_measure_begin

    fence   rw, rw
    csrr    t0, mcycle
    sub     a0, t0, s3
    la      t1, stencil_cycles
    sd      a0, 0(t1)

.globl stencil_measure_end
stencil_measure_end:
    nop

    la      s0, stencil_source
    la      s1, stencil_output
    li      s2, STENCIL_OUTPUT_WORDS
.Lverify:
    ld      t0, 0(s0)
    ld      t1, 8(s0)
    ld      t2, 16(s0)
    ld      t3, 24(s0)
    ld      t4, 32(s0)
    add     t0, t0, t1
    add     t0, t0, t2
    add     t0, t0, t3
    add     t0, t0, t4
    ld      t1, 0(s1)
    bne     t0, t1, .Lfail
    addi    s0, s0, 8
    addi    s1, s1, 8
    addi    s2, s2, -1
    bnez    s2, .Lverify

    li      a0, STENCIL_PASS
    ebreak

.Lfail:
    li      a0, STENCIL_FAIL
    ebreak

.Lhalt:
    j       .Lhalt

.size _start, .-_start

.section .rodata.stencil_source, "a", @progbits
.balign 64
.globl stencil_source
.type stencil_source, @object
stencil_source:
    .set stencil_index, 0
    .rept STENCIL_WORDS
        .quad 0x10000 + stencil_index
        .set stencil_index, stencil_index + 1
    .endr
.size stencil_source, .-stencil_source

.section .data.stencil_results, "aw", @progbits
.balign 8
.globl stencil_cycles
.type stencil_cycles, @object
stencil_cycles:
    .quad 0
.size stencil_cycles, .-stencil_cycles

.section .bss.stencil_output, "aw", @nobits
.balign 64
.globl stencil_output
.type stencil_output, @object
stencil_output:
    .skip (STENCIL_OUTPUT_WORDS * 8)
.size stencil_output, .-stencil_output
