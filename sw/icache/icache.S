/*
 * Controlled I-cache footprint benchmark.
 *
 * ICACHE_PATTERN:
 *   0 = straight-line fall-through
 *   1 = one taken direct branch per 64-byte line
 *   2 = one call/return pair plus a direct branch per 64-byte line
 *
 * The generated tape is exactly ICACHE_BYTES long.  Every line contributes a
 * known number of integer increments, providing a correctness check without
 * data-cache traffic inside the measured region.
 */

.ifndef ICACHE_PATTERN
.equ ICACHE_PATTERN, 1
.endif

.ifndef ICACHE_BYTES
.equ ICACHE_BYTES, 65536
.endif

.if ((ICACHE_PATTERN < 0) || (ICACHE_PATTERN > 2))
.error "ICACHE_PATTERN must be 0 through 2"
.endif

.if ((ICACHE_BYTES < 4096) || ((ICACHE_BYTES % 64) != 0))
.error "ICACHE_BYTES must be at least 4096 and a multiple of 64"
.endif

.equ ICACHE_LINES, (ICACHE_BYTES / 64)
.if ICACHE_PATTERN == 0
.equ ICACHE_EXPECTED, (ICACHE_LINES * 16)
.elseif ICACHE_PATTERN == 1
.equ ICACHE_EXPECTED, (ICACHE_LINES * 15)
.else
.equ ICACHE_EXPECTED, (ICACHE_LINES * 13)
.endif

.equ ICACHE_PASS, 0x4943414348454f4b /* "ICACHEOK" */
.equ ICACHE_FAIL, 0x4943414348454244 /* "ICACHEBD" */

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl _start
.type _start, @function

_start:
    la      sp, __stack_top
    li      s0, 0
    fence.i
    csrr    s1, mcycle
    j       icache_measure_begin
.size _start, .-_start

.section .text.icache_tape, "ax", @progbits
.balign 64
.globl icache_measure_begin
icache_measure_begin:
.if ICACHE_PATTERN == 0
    .rept ICACHE_LINES
        .rept 16
            addi    s0, s0, 1
        .endr
    .endr
.elseif ICACHE_PATTERN == 1
    .rept ICACHE_LINES
        .rept 15
            addi    s0, s0, 1
        .endr
        j       1f
1:
    .endr
.else
    /*
     * One 64-byte line:
     *   call 32-byte callee, return, six caller increments, branch onward.
     */
    .rept ICACHE_LINES
        jal     ra, 1f
        .rept 6
            addi    s0, s0, 1
        .endr
        j       2f
1:
        .rept 7
            addi    s0, s0, 1
        .endr
        jalr    zero, 0(ra)
2:
    .endr
.endif

    csrr    t0, mcycle
    sub     a0, t0, s1
    la      t1, icache_cycles
    sd      a0, 0(t1)

.globl icache_measure_end
icache_measure_end:
    nop

    li      t0, ICACHE_EXPECTED
    bne     s0, t0, .Lfail
    li      a0, ICACHE_PASS
    ebreak

.Lfail:
    li      a0, ICACHE_FAIL
    ebreak

.Lhalt:
    j       .Lhalt

.section .data.icache_results, "aw", @progbits
.balign 8
.globl icache_cycles
.type icache_cycles, @object
icache_cycles:
    .quad 0
.size icache_cycles, .-icache_cycles
