/*
 * Cold, cache-line-sized memcpy benchmark for the native L1D/ICX path.
 *
 * MEMCPY_BYTES is supplied by the build and is deliberately restricted to
 * the two page-copy cases used by this benchmark: 4 KiB and 64 KiB.
 *
 * The source is part of the load image, while the destination is zeroed
 * storage.  Consequently the timed region contains only the copy and the
 * final ordering fence: no source initialization and no correctness
 * scan.  memcpy_measure_begin and memcpy_measure_end are exported so a
 * harness can stop at the latter and report the cycle delta left in a0.
 * A normal run continues through a full byte-for-byte check and terminates
 * with EBREAK, returning MEMCPY_PASS in a0.
 */

.ifndef MEMCPY_BYTES
.equ MEMCPY_BYTES, 65536
.endif

.if ((MEMCPY_BYTES != 4096) && (MEMCPY_BYTES != 65536))
.error "MEMCPY_BYTES must be 4096 or 65536"
.endif

.equ MEMCPY_PASS, 0x4d454d4350594f4b /* "MEMCPYOK" */
.equ MEMCPY_FAIL, 0x4d454d4350594244 /* "MEMCPYBD" */

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl main
.type main, @function

main:
    la      s0, memcpy_source
    la      s1, memcpy_destination
    li      s2, MEMCPY_BYTES

    /*
     * The source and destination are both 64-byte aligned and each iteration
     * moves exactly one L1 cache line.  The final FENCE is the architectural
     * end of the copy; a posted lower-level store tail may still drain after
     * retirement, as it can after a normal memcpy return.
    */
    fence   rw, rw
.ifdef MEMCPY_VM
    csrr    s3, cycle
.else
    csrr    s3, mcycle
.endif

.globl memcpy_measure_begin
memcpy_measure_begin:
    ld      t0, 0(s0)
    ld      t1, 8(s0)
    ld      t2, 16(s0)
    ld      t3, 24(s0)
    ld      t4, 32(s0)
    ld      t5, 40(s0)
    ld      t6, 48(s0)
    ld      a0, 56(s0)

    sd      t0, 0(s1)
    sd      t1, 8(s1)
    sd      t2, 16(s1)
    sd      t3, 24(s1)
    sd      t4, 32(s1)
    sd      t5, 40(s1)
    sd      t6, 48(s1)
    sd      a0, 56(s1)

    addi    s0, s0, 64
    addi    s1, s1, 64
    addi    s2, s2, -64
    bnez    s2, memcpy_measure_begin

    fence   rw, rw
.ifdef MEMCPY_VM
    csrr    t0, cycle
.else
    csrr    t0, mcycle
.endif
    sub     a0, t0, s3
    la      t1, memcpy_cycles
    sd      a0, 0(t1)

.globl memcpy_measure_end
memcpy_measure_end:
    nop

    /* Correctness is outside the timed region. */
    la      s0, memcpy_source
    la      s1, memcpy_destination
    li      s2, MEMCPY_BYTES

.Lverify:
    ld      t0, 0(s0)
    ld      t1, 0(s1)
    bne     t0, t1, .Lfail
    addi    s0, s0, 8
    addi    s1, s1, 8
    addi    s2, s2, -8
    bnez    s2, .Lverify

    li      a0, MEMCPY_PASS
    ebreak

.Lfail:
    li      a0, MEMCPY_FAIL
    ebreak

.Lhalt:
    j       .Lhalt

.size main, .-main

.section .rodata.memcpy_source, "a", @progbits
.balign 64
.globl memcpy_source
.type memcpy_source, @object
memcpy_source:
    /*
     * Every line differs, and every word within a line differs.  That catches
     * missing, duplicated, or lane-shifted stores without a source-generation
     * pass that would pre-warm the data cache.
     */
    .set source_line, 0
    .rept (MEMCPY_BYTES / 64)
        .quad 0x0123456789abcdef + source_line
        .quad 0xfedcba9876543210 + source_line
        .quad 0x0f1e2d3c4b5a6978 + source_line
        .quad 0x8877665544332211 + source_line
        .quad 0x55aa55aa55aa55aa + source_line
        .quad 0xaa55aa55aa55aa55 + source_line
        .quad 0x13579bdf2468ace0 + source_line
        .quad 0xc001d00d5eedface + source_line
        .set source_line, source_line + 1
    .endr
.size memcpy_source, .-memcpy_source

.section .data.memcpy_results, "aw", @progbits
.balign 8
.globl memcpy_cycles
.type memcpy_cycles, @object
memcpy_cycles:
    .quad 0
.size memcpy_cycles, .-memcpy_cycles

.section .bss.memcpy_destination, "aw", @nobits
.balign 64
.globl memcpy_destination
.type memcpy_destination, @object
memcpy_destination:
    .skip MEMCPY_BYTES
.size memcpy_destination, .-memcpy_destination
