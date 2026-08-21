/*
 * Directed completed-control / load-overlap microbenchmark.
 *
 * Each group starts a cache-line load, resolves three always-not-taken
 * conditional branches, and places another read-only load on each fallthrough
 * path.  With load speculation disabled, the younger loads exercise the
 * dispatch-window older_live_control gate.  The first load keeps resolved
 * branches resident behind an incomplete retirement head long enough for the
 * completed-control release policy to matter.
 *
 * The 128 KiB stream is larger than L1D and is repeated to retain a stable
 * branch-predictor state while continuing to generate L1 misses.  Full-result
 * execution checks the sum; the measurement stop leaves elapsed cycles in a0.
 */

.equ BGL_BYTES, 131072
.equ BGL_LINE_BYTES, 64
.equ BGL_LINES, (BGL_BYTES / BGL_LINE_BYTES)
.equ BGL_GROUP_LINES, 4
.equ BGL_GROUP_BYTES, (BGL_GROUP_LINES * BGL_LINE_BYTES)
.equ BGL_GROUPS, (BGL_LINES / BGL_GROUP_LINES)
.equ BGL_PASSES, 16
.equ BGL_EXPECTED_SUM, (((BGL_LINES - 1) * BGL_LINES / 2) * BGL_PASSES)
.equ BGL_PASS, 0x4252474c445f4f4b /* "BRGLD_OK" */
.equ BGL_FAIL, 0x4252474c445f4244 /* "BRGLD_BD" */

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl main
.type main, @function

main:
    la      s0, branch_gated_load_data
    li      s1, BGL_GROUPS
    li      s2, BGL_PASSES
    li      s3, 0

    fence   rw, rw
    csrr    s4, cycle

.globl branch_gated_load_measure_begin
branch_gated_load_measure_begin:
    ld      t0, 0(s0)
    bne     zero, zero, .Lafter_line1
    ld      t1, 64(s0)
.Lafter_line1:
    bne     zero, zero, .Lafter_line2
    ld      t2, 128(s0)
.Lafter_line2:
    bne     zero, zero, .Lafter_line3
    ld      t3, 192(s0)
.Lafter_line3:

    add     s3, s3, t0
    add     s3, s3, t1
    add     s3, s3, t2
    add     s3, s3, t3
    addi    s0, s0, BGL_GROUP_BYTES
    addi    s1, s1, -1
    bnez    s1, branch_gated_load_measure_begin

    la      s0, branch_gated_load_data
    li      s1, BGL_GROUPS
    addi    s2, s2, -1
    bnez    s2, branch_gated_load_measure_begin

    fence   rw, rw
    csrr    t0, cycle
    sub     a0, t0, s4
    la      t1, branch_gated_load_cycles
    sd      a0, 0(t1)

.globl branch_gated_load_measure_end
branch_gated_load_measure_end:
    li      t1, BGL_EXPECTED_SUM
    bne     s3, t1, .Lfail
    li      a0, BGL_PASS
    ret

.Lfail:
    li      a0, BGL_FAIL
    ret

.size main, .-main

.section .data.branch_gated_load, "aw", @progbits
.balign 8
.globl branch_gated_load_cycles
.type branch_gated_load_cycles, @object
branch_gated_load_cycles:
    .quad 0
.size branch_gated_load_cycles, .-branch_gated_load_cycles

.section .rodata.branch_gated_load, "a", @progbits
.balign 64
.globl branch_gated_load_data
.type branch_gated_load_data, @object
branch_gated_load_data:
    .set bgl_line, 0
    .rept BGL_LINES
        .quad bgl_line
        .zero BGL_LINE_BYTES - 8
        .set bgl_line, bgl_line + 1
    .endr
.size branch_gated_load_data, .-branch_gated_load_data
