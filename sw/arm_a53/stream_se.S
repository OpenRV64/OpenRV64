/*
 * AArch64 integer STREAM kernels for the gem5 HPI syscall-emulation rig.
 *
 * Keep the data, unroll factors, scalar memory operations, and arithmetic
 * aligned with sw/stream/stream.S.  gem5 statistics are reset immediately
 * before the kernel and dumped immediately after it; verification is outside
 * the measured statistics block.
 *
 * STREAM_KERNEL:
 *   0 = copy   c[i] = a[i]
 *   1 = scale  c[i] = 3 * a[i]
 *   2 = add    c[i] = a[i] + b[i]
 *   3 = triad  c[i] = a[i] + 3 * b[i]
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

/* gem5 AArch64 magic instructions, using x0 and x1 for their arguments. */
.equ M5_RESET_STATS, 0xff400110
.equ M5_DUMP_STATS,  0xff410110
.equ M5_EXIT,        0xff210110
.equ M5_FAIL,        0xff220110

.arch armv8-a
.section .text.startup, "ax", %progbits
.balign 64
.global _start
.type _start, %function

_start:
    adrp    x19, stream_a
    add     x19, x19, :lo12:stream_a
    adrp    x20, stream_c
    add     x20, x20, :lo12:stream_c
    mov     x21, STREAM_WORDS
.if (STREAM_KERNEL >= 2)
    adrp    x22, stream_b
    add     x22, x22, :lo12:stream_b
.endif

    dmb     sy
    mov     x0, xzr
    mov     x1, xzr
    .inst   M5_RESET_STATS

.global stream_measure_begin
stream_measure_begin:
.if STREAM_KERNEL == 0
    /* Eight independent loads followed by eight stores: 64 bytes. */
    ldr     x0, [x19, #0]
    ldr     x1, [x19, #8]
    ldr     x2, [x19, #16]
    ldr     x3, [x19, #24]
    ldr     x4, [x19, #32]
    ldr     x5, [x19, #40]
    ldr     x6, [x19, #48]
    ldr     x7, [x19, #56]
    str     x0, [x20, #0]
    str     x1, [x20, #8]
    str     x2, [x20, #16]
    str     x3, [x20, #24]
    str     x4, [x20, #32]
    str     x5, [x20, #40]
    str     x6, [x20, #48]
    str     x7, [x20, #56]
    add     x19, x19, #64
    add     x20, x20, #64
    sub     x21, x21, #8
.elseif STREAM_KERNEL == 1
    ldr     x0, [x19, #0]
    ldr     x1, [x19, #8]
    ldr     x2, [x19, #16]
    ldr     x3, [x19, #24]
    add     x0, x0, x0, lsl #1
    add     x1, x1, x1, lsl #1
    add     x2, x2, x2, lsl #1
    add     x3, x3, x3, lsl #1
    str     x0, [x20, #0]
    str     x1, [x20, #8]
    str     x2, [x20, #16]
    str     x3, [x20, #24]
    add     x19, x19, #32
    add     x20, x20, #32
    sub     x21, x21, #4
.elseif STREAM_KERNEL == 2
    ldr     x0, [x19, #0]
    ldr     x1, [x19, #8]
    ldr     x2, [x19, #16]
    ldr     x3, [x19, #24]
    ldr     x4, [x22, #0]
    ldr     x5, [x22, #8]
    ldr     x6, [x22, #16]
    ldr     x7, [x22, #24]
    add     x0, x0, x4
    add     x1, x1, x5
    add     x2, x2, x6
    add     x3, x3, x7
    str     x0, [x20, #0]
    str     x1, [x20, #8]
    str     x2, [x20, #16]
    str     x3, [x20, #24]
    add     x19, x19, #32
    add     x22, x22, #32
    add     x20, x20, #32
    sub     x21, x21, #4
.else
    ldr     x0, [x19, #0]
    ldr     x1, [x19, #8]
    ldr     x2, [x19, #16]
    ldr     x3, [x19, #24]
    ldr     x4, [x22, #0]
    ldr     x5, [x22, #8]
    ldr     x6, [x22, #16]
    ldr     x7, [x22, #24]
    add     x8, x4, x4, lsl #1
    add     x0, x0, x8
    add     x8, x5, x5, lsl #1
    add     x1, x1, x8
    add     x8, x6, x6, lsl #1
    add     x2, x2, x8
    add     x8, x7, x7, lsl #1
    add     x3, x3, x8
    str     x0, [x20, #0]
    str     x1, [x20, #8]
    str     x2, [x20, #16]
    str     x3, [x20, #24]
    add     x19, x19, #32
    add     x22, x22, #32
    add     x20, x20, #32
    sub     x21, x21, #4
.endif
    cbnz    x21, stream_measure_begin

    dmb     sy

.global stream_measure_end
stream_measure_end:
    mov     x0, xzr
    mov     x1, xzr
    .inst   M5_DUMP_STATS

    /* Full result verification is deliberately outside the measured block. */
    adrp    x19, stream_a
    add     x19, x19, :lo12:stream_a
    adrp    x20, stream_c
    add     x20, x20, :lo12:stream_c
    mov     x21, STREAM_WORDS
.if (STREAM_KERNEL >= 2)
    adrp    x22, stream_b
    add     x22, x22, :lo12:stream_b
.endif

.Lverify:
    ldr     x0, [x19], #8
.if STREAM_KERNEL == 1
    add     x0, x0, x0, lsl #1
.elseif STREAM_KERNEL == 2
    ldr     x1, [x22], #8
    add     x0, x0, x1
.elseif STREAM_KERNEL == 3
    ldr     x1, [x22], #8
    add     x1, x1, x1, lsl #1
    add     x0, x0, x1
.endif
    ldr     x1, [x20], #8
    cmp     x0, x1
    b.ne    .Lfail
    subs    x21, x21, #1
    b.ne    .Lverify

    mov     x0, xzr
    .inst   M5_EXIT

.Lfail:
    mov     x0, xzr
    mov     x1, #1
    .inst   M5_FAIL

.Lhang:
    b       .Lhang

.size _start, .-_start

.section .rodata.stream_a, "a", %progbits
.balign 64
.global stream_a
.type stream_a, %object
stream_a:
    .set stream_index, 0
    .rept STREAM_WORDS
        .quad 0x100000000 + stream_index
        .set stream_index, stream_index + 1
    .endr
.size stream_a, .-stream_a

.if (STREAM_KERNEL >= 2)
.section .rodata.stream_b, "a", %progbits
.balign 64
.global stream_b
.type stream_b, %object
stream_b:
    .set stream_index, 0
    .rept STREAM_WORDS
        .quad 0x200000000 + stream_index
        .set stream_index, stream_index + 1
    .endr
.size stream_b, .-stream_b
.endif

.section .bss.stream_c, "aw", %nobits
.balign 64
.global stream_c
.type stream_c, %object
stream_c:
    .skip STREAM_BYTES
.size stream_c, .-stream_c
