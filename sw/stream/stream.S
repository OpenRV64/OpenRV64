/*
 * Integer STREAM-style kernels for L1D/prefetch characterization.
 *
 * STREAM_KERNEL:
 *   0 = copy   c[i] = a[i]
 *   1 = scale  c[i] = 3 * a[i]
 *   2 = add    c[i] = a[i] + b[i]
 *   3 = triad  c[i] = a[i] + 3 * b[i]
 *
 * STREAM_BYTES defaults to 64 KiB per array.  The source arrays are part of
 * the load image so the timed region contains only the selected kernel.
 */

.ifndef STREAM_KERNEL
.equ STREAM_KERNEL, 3
.endif

.ifndef STREAM_BYTES
.equ STREAM_BYTES, 65536
.endif

.if ((STREAM_KERNEL < 0) || (STREAM_KERNEL > 3))
.error "STREAM_KERNEL must be 0 through 3"
.endif

.if ((STREAM_BYTES < 4096) || ((STREAM_BYTES % 64) != 0))
.error "STREAM_BYTES must be at least 4096 and a multiple of 64"
.endif

.equ STREAM_WORDS, (STREAM_BYTES / 8)
.equ STREAM_PASS, 0x53545245414d4f4b /* "STREAMOK" */
.equ STREAM_FAIL, 0x53545245414d4244 /* "STREAMBD" */

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl _start
.type _start, @function

_start:
    la      sp, __stack_top
    la      s0, stream_a
    la      s1, stream_c
    li      s2, STREAM_WORDS
.if (STREAM_KERNEL >= 2)
    la      s3, stream_b
.endif

    fence   rw, rw
.ifdef STREAM_VM
    csrr    s4, cycle
.else
    csrr    s4, mcycle
.endif

.globl stream_measure_begin
stream_measure_begin:
.if STREAM_KERNEL == 0
    /* Eight independent loads followed by eight stores: 64 bytes. */
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
    addi    s2, s2, -8
.elseif STREAM_KERNEL == 1
    /* Four words retain useful load distance without exhausting registers. */
    ld      t0, 0(s0)
    ld      t1, 8(s0)
    ld      t2, 16(s0)
    ld      t3, 24(s0)
    slli    t4, t0, 1
    add     t0, t0, t4
    slli    t4, t1, 1
    add     t1, t1, t4
    slli    t4, t2, 1
    add     t2, t2, t4
    slli    t4, t3, 1
    add     t3, t3, t4
    sd      t0, 0(s1)
    sd      t1, 8(s1)
    sd      t2, 16(s1)
    sd      t3, 24(s1)
    addi    s0, s0, 32
    addi    s1, s1, 32
    addi    s2, s2, -4
.elseif STREAM_KERNEL == 2
    ld      t0, 0(s0)
    ld      t1, 8(s0)
    ld      t2, 16(s0)
    ld      t3, 24(s0)
    ld      t4, 0(s3)
    ld      t5, 8(s3)
    ld      t6, 16(s3)
    ld      a0, 24(s3)
    add     t0, t0, t4
    add     t1, t1, t5
    add     t2, t2, t6
    add     t3, t3, a0
    sd      t0, 0(s1)
    sd      t1, 8(s1)
    sd      t2, 16(s1)
    sd      t3, 24(s1)
    addi    s0, s0, 32
    addi    s3, s3, 32
    addi    s1, s1, 32
    addi    s2, s2, -4
.else
    ld      t0, 0(s0)
    ld      t1, 8(s0)
    ld      t2, 16(s0)
    ld      t3, 24(s0)
    ld      t4, 0(s3)
    ld      t5, 8(s3)
    ld      t6, 16(s3)
    ld      a0, 24(s3)
    slli    a1, t4, 1
    add     t0, t0, a1
    add     t0, t0, t4
    slli    a1, t5, 1
    add     t1, t1, a1
    add     t1, t1, t5
    slli    a1, t6, 1
    add     t2, t2, a1
    add     t2, t2, t6
    slli    a1, a0, 1
    add     t3, t3, a1
    add     t3, t3, a0
    sd      t0, 0(s1)
    sd      t1, 8(s1)
    sd      t2, 16(s1)
    sd      t3, 24(s1)
    addi    s0, s0, 32
    addi    s3, s3, 32
    addi    s1, s1, 32
    addi    s2, s2, -4
.endif
    bnez    s2, stream_measure_begin

    fence   rw, rw
.ifdef STREAM_VM
    csrr    t0, cycle
.else
    csrr    t0, mcycle
.endif
    sub     a0, t0, s4
    la      t1, stream_cycles
    sd      a0, 0(t1)

.globl stream_measure_end
stream_measure_end:
    nop

    /* Full result verification is deliberately outside the timed region. */
    la      s0, stream_a
    la      s1, stream_c
    li      s2, STREAM_WORDS
.if (STREAM_KERNEL >= 2)
    la      s3, stream_b
.endif

.Lverify:
    ld      t0, 0(s0)
.if STREAM_KERNEL == 1
    slli    t1, t0, 1
    add     t0, t0, t1
.elseif STREAM_KERNEL == 2
    ld      t1, 0(s3)
    add     t0, t0, t1
    addi    s3, s3, 8
.elseif STREAM_KERNEL == 3
    ld      t1, 0(s3)
    slli    t2, t1, 1
    add     t0, t0, t2
    add     t0, t0, t1
    addi    s3, s3, 8
.endif
    ld      t1, 0(s1)
    bne     t0, t1, .Lfail
    addi    s0, s0, 8
    addi    s1, s1, 8
    addi    s2, s2, -1
    bnez    s2, .Lverify

    li      a0, STREAM_PASS
    ebreak

.Lfail:
    li      a0, STREAM_FAIL
    ebreak

.Lhalt:
    j       .Lhalt

.size _start, .-_start

.section .rodata.stream_a, "a", @progbits
.balign 64
.globl stream_a
.type stream_a, @object
stream_a:
    .set stream_index, 0
    .rept STREAM_WORDS
        .quad 0x100000000 + stream_index
        .set stream_index, stream_index + 1
    .endr
.size stream_a, .-stream_a

.if (STREAM_KERNEL >= 2)
.section .rodata.stream_b, "a", @progbits
.balign 64
.globl stream_b
.type stream_b, @object
stream_b:
    .set stream_index, 0
    .rept STREAM_WORDS
        .quad 0x200000000 + stream_index
        .set stream_index, stream_index + 1
    .endr
.size stream_b, .-stream_b
.endif

.section .data.stream_results, "aw", @progbits
.balign 8
.globl stream_cycles
.type stream_cycles, @object
stream_cycles:
    .quad 0
.size stream_cycles, .-stream_cycles

.section .bss.stream_c, "aw", @nobits
.balign 64
.globl stream_c
.type stream_c, @object
stream_c:
    .skip STREAM_BYTES
.size stream_c, .-stream_c
