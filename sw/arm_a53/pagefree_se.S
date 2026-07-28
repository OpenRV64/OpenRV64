/*
 * AArch64 equivalent of sw/pagefree/pagefree.S for gem5 HPI.
 *
 * This preserves the descriptor layout, memory operations, masks, and loop
 * dependencies.  It is a cross-ISA semantic comparison, not an instruction-
 * matched reproduction of the RISC-V kernel.
 */

.ifndef PAGEFREE_KERNEL
.equ PAGEFREE_KERNEL, 0
.endif

.ifndef PAGEFREE_RECORDS
.equ PAGEFREE_RECORDS, 8192
.endif

.if ((PAGEFREE_KERNEL < 0) || (PAGEFREE_KERNEL > 1))
.error "PAGEFREE_KERNEL must be 0 (core) or 1 (tail)"
.endif

.if ((PAGEFREE_RECORDS < 1024) || ((PAGEFREE_RECORDS % 1024) != 0))
.error "PAGEFREE_RECORDS must be a multiple of 1024"
.endif

.equ PAGEFREE_RECORD_BYTES, 64
.equ PAGEFREE_INITIAL_FLAGS, 0xdeadbeefcafebfff
.equ PAGEFREE_CORE_FLAGS,   0xdeadbeefcafe9fff
.equ PAGEFREE_TAIL_FLAGS,   0xdeadbeefcae00000

/* gem5 AArch64 magic instructions. */
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
    adrp    x19, pagefree_records
    add     x19, x19, :lo12:pagefree_records
    mov     x20, PAGEFREE_RECORDS
.if PAGEFREE_KERNEL == 1
    adrp    x22, pagefree_check_pages_enabled
    add     x22, x22, :lo12:pagefree_check_pages_enabled
.endif

    dmb     sy
    mov     x0, xzr
    mov     x1, xzr
    .inst   M5_RESET_STATS

.global pagefree_measure_begin
pagefree_measure_begin:
.if PAGEFREE_KERNEL == 0
    ldr     x0, [x19]
    str     wzr, [x19, #52]
    and     x0, x0, #0xffffffffffffdfff
    str     x0, [x19]
    add     x19, x19, PAGEFREE_RECORD_BYTES
    subs    x20, x20, #1
    b.ne    pagefree_measure_begin
.else
    ldr     w0, [x22]
    ldr     x1, [x19]
    cmp     w0, #0
    b.gt    .Lfail
    and     x1, x1, #0xffffffffffe00000
    str     x1, [x19]
    add     x19, x19, PAGEFREE_RECORD_BYTES
    subs    x20, x20, #1
    b.ne    pagefree_measure_begin
.endif

.global pagefree_measure_end
pagefree_measure_end:
    mov     x0, xzr
    mov     x1, xzr
    .inst   M5_DUMP_STATS

    /*
     * Measure the residual store drain separately.  Resetting gem5 statistics
     * does not reset architectural or cache state.
     */
    mov     x0, xzr
    mov     x1, xzr
    .inst   M5_RESET_STATS
    dmb     sy
    mov     x0, xzr
    mov     x1, xzr
    .inst   M5_DUMP_STATS

    /* Verification is outside both measured statistics blocks. */
    adrp    x19, pagefree_records
    add     x19, x19, :lo12:pagefree_records
    mov     x20, PAGEFREE_RECORDS
.if PAGEFREE_KERNEL == 0
    ldr     x21, =PAGEFREE_CORE_FLAGS
    mov     w22, wzr
.else
    ldr     x21, =PAGEFREE_TAIL_FLAGS
    mov     w22, #1
.endif

.Lverify:
    ldr     x0, [x19]
    cmp     x0, x21
    b.ne    .Lfail
    ldr     w0, [x19, #52]
    cmp     w0, w22
    b.ne    .Lfail
    add     x19, x19, PAGEFREE_RECORD_BYTES
    subs    x20, x20, #1
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

.section .data.pagefree_control, "aw", %progbits
.balign 64
.global pagefree_check_pages_enabled
pagefree_check_pages_enabled:
    .word 0
    .zero 60

.section .data.pagefree_records, "aw", %progbits
.balign 64
.global pagefree_records
.type pagefree_records, %object
pagefree_records:
    .rept PAGEFREE_RECORDS
        .quad PAGEFREE_INITIAL_FLAGS
        .zero 44
        .word 1
        .zero 8
    .endr
.size pagefree_records, .-pagefree_records
