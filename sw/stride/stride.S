/*
 * Fixed-access-count stride sweep.
 *
 * The working set is initialized before timing and then displaced from the
 * 8 KiB L1D by a 32 KiB eviction walk.  Every timed variant performs exactly
 * STRIDE_ACCESSES loads; only the address delta and footprint change.
 */

.ifndef STRIDE_BYTES
.equ STRIDE_BYTES, 64
.endif

.equ STRIDE_ACCESSES, 1024
.equ STRIDE_EXPECTED_SUM, 524800 /* sum(1..1024) */
.equ STRIDE_EVICT_BYTES, 32768
.equ STRIDE_PASS, 0x5354524944454f4b /* "STRIDEOK" */
.equ STRIDE_FAIL, 0x5354524944454244 /* "STRIDEBD" */

.if ((STRIDE_BYTES != 64) && (STRIDE_BYTES != 128) && \
     (STRIDE_BYTES != 256) && (STRIDE_BYTES != 1024) && \
     (STRIDE_BYTES != 4096))
.error "STRIDE_BYTES must be 64, 128, 256, 1024, or 4096"
.endif

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl _start
.type _start, @function

_start:
    la      sp, __stack_top

    /* Give every timed address a non-zero, order-sensitive value. */
    la      s0, stride_data
    li      s1, STRIDE_ACCESSES
    li      s2, STRIDE_BYTES
    li      t0, 1
.Linitialize:
    sd      t0, 0(s0)
    add     s0, s0, s2
    addi    t0, t0, 1
    addi    s1, s1, -1
    bnez    s1, .Linitialize
    fence   rw, rw

    /* Displace initialized lines before the timed demand stream. */
    la      s0, stride_evict
    li      s1, (STRIDE_EVICT_BYTES / 64)
    li      t0, 0
.Levict:
    ld      t1, 0(s0)
    add     t0, t0, t1
    addi    s0, s0, 64
    addi    s1, s1, -1
    bnez    s1, .Levict

    la      s0, stride_data
    li      s1, STRIDE_ACCESSES
    li      s2, STRIDE_BYTES
    li      s4, 0
    fence   rw, rw
    csrr    s3, mcycle

.globl stride_measure_begin
stride_measure_begin:
    ld      t0, 0(s0)
    add     s0, s0, s2
    ld      t1, 0(s0)
    add     s0, s0, s2
    ld      t2, 0(s0)
    add     s0, s0, s2
    ld      t3, 0(s0)
    add     s0, s0, s2
    add     s4, s4, t0
    add     s4, s4, t1
    add     s4, s4, t2
    add     s4, s4, t3
    addi    s1, s1, -4
    bnez    s1, stride_measure_begin

    fence   rw, rw
    csrr    t0, mcycle
    sub     a0, t0, s3
    la      t1, stride_cycles
    sd      a0, 0(t1)

.globl stride_measure_end
stride_measure_end:
    nop

    li      t0, STRIDE_EXPECTED_SUM
    bne     s4, t0, .Lfail
    li      a0, STRIDE_PASS
    ebreak

.Lfail:
    li      a0, STRIDE_FAIL
    ebreak

.Lhalt:
    j       .Lhalt

.size _start, .-_start

.section .data.stride_results, "aw", @progbits
.balign 8
.globl stride_cycles
.type stride_cycles, @object
stride_cycles:
    .quad 0
.size stride_cycles, .-stride_cycles

.section .bss.stride_data, "aw", @nobits
.balign 4096
.globl stride_data
.type stride_data, @object
stride_data:
    .skip (STRIDE_BYTES * STRIDE_ACCESSES)
.size stride_data, .-stride_data

.section .bss.stride_evict, "aw", @nobits
.balign 4096
.globl stride_evict
.type stride_evict, @object
stride_evict:
    .skip STRIDE_EVICT_BYTES
.size stride_evict, .-stride_evict
