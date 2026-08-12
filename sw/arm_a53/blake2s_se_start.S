/* Matched BLAKE2s driver for the gem5 HPI AArch64 SE reference. */

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
    bl      blake2s_bench_reset
    dmb     sy
    mov     x0, xzr
    mov     x1, xzr
    .inst   M5_RESET_STATS

.global blake2s_hpi_measure_begin
blake2s_hpi_measure_begin:
    bl      blake2s_bench_run
    mov     w19, w0
    dmb     sy

.global blake2s_hpi_measure_end
blake2s_hpi_measure_end:
    mov     x0, xzr
    mov     x1, xzr
    .inst   M5_DUMP_STATS

    mov     w0, w19
    bl      blake2s_bench_verify
    cbz     w0, .Lfail

    mov     x0, xzr
    .inst   M5_EXIT

.Lfail:
    mov     x0, xzr
    mov     x1, #1
    .inst   M5_FAIL

.Lhang:
    b       .Lhang
.size _start, .-_start
