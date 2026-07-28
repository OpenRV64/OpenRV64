/* SPDX-License-Identifier: MIT */

#ifndef BLAKE2S_BENCH_CALLS
#define BLAKE2S_BENCH_CALLS 16
#endif

#ifndef BLAKE2S_BLOCKS_PER_CALL
#define BLAKE2S_BLOCKS_PER_CALL 1
#endif

.equ BLAKE2S_PASS, 0x424c414b45324f4b /* "BLAKE2OK" */
.equ BLAKE2S_FAIL, 0x424c414b45324244 /* "BLAKE2BD" */

.section .text.startup, "ax", @progbits
.option norvc
.balign 64
.globl _start
.type _start, @function

_start:
    la      sp, __stack_top
    call    blake2s_bench_reset
    fence   rw, rw
    csrr    s0, mcycle
    csrr    s1, minstret

.globl blake2s_measure_begin
blake2s_measure_begin:
    call    blake2s_bench_run
    mv      s2, a0

    csrr    t0, mcycle
    csrr    t1, minstret
    sub     a0, t0, s0
    sub     a1, t1, s1
    li      a2, BLAKE2S_BENCH_CALLS
    li      a3, BLAKE2S_BLOCKS_PER_CALL
    li      a4, BLAKE2S_BENCH_CALLS * BLAKE2S_BLOCKS_PER_CALL
    mv      a5, s2

    /*
     * Keep the marker out of the retire group that writes the report
     * registers sampled by the three-wide testbench.
     */
    nop
    nop
    nop
    nop
    nop
    nop

.globl blake2s_measure_end
blake2s_measure_end:
    nop

    mv      a0, s2
    call    blake2s_bench_verify
    beqz    a0, .Lfail
    li      a0, BLAKE2S_PASS
    ebreak

.Lfail:
    li      a0, BLAKE2S_FAIL
    ebreak

.Lhalt:
    j       .Lhalt

.size _start, .-_start
