/*
 * AArch64 single-chain pointer latency benchmark for gem5 HPI SE mode.
 *
 * The generated pointer ring and hot-loop work match the OpenRV64 image.
 * Statistics cover only the measured traversal; warmup and verification are
 * outside the reset/dump boundary.
 */

.ifndef POINTER_CHASE_NODES
.equ POINTER_CHASE_NODES, 65536
.endif

.ifndef POINTER_CHASE_STEPS
.equ POINTER_CHASE_STEPS, 131072
.endif

.if ((POINTER_CHASE_NODES <= 0) || (POINTER_CHASE_STEPS <= 0))
.error "pointer-chase nodes and steps must be positive"
.endif

.if ((POINTER_CHASE_STEPS % POINTER_CHASE_NODES) != 0)
.error "pointer-chase steps must be a multiple of nodes"
.endif

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
    adrp    x19, pointer_chase_start
    add     x19, x19, :lo12:pointer_chase_start
    mov     x20, POINTER_CHASE_NODES

.Lwarm:
    ldr     x19, [x19]
    subs    x20, x20, #1
    b.ne    .Lwarm

    adrp    x21, pointer_chase_start
    add     x21, x21, :lo12:pointer_chase_start
    cmp     x19, x21
    b.ne    .Lfail
    mov     x20, POINTER_CHASE_STEPS
    dmb     sy
    mov     x0, xzr
    mov     x1, xzr
    .inst   M5_RESET_STATS

.global pointer_chase_measure_begin
pointer_chase_measure_begin:
    ldr     x19, [x19]
    subs    x20, x20, #1
    b.ne    pointer_chase_measure_begin

    dmb     sy

.global pointer_chase_measure_end
pointer_chase_measure_end:
    mov     x0, xzr
    mov     x1, xzr
    .inst   M5_DUMP_STATS

    cmp     x19, x21
    b.ne    .Lfail
    mov     x0, xzr
    .inst   M5_EXIT

.Lfail:
    mov     x0, xzr
    mov     x1, #1
    .inst   M5_FAIL

.Lhang:
    b       .Lhang

.size _start, .-_start
