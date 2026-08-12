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
.globl c_init
.type c_init, @function

c_init:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    call    blake2s_bench_reset
    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret

.size c_init, .-c_init

.globl main
.type main, @function

main:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    fence   rw, rw
    /* Counter aliases work in M-mode and through mcounteren in S-mode. */
    csrr    s0, cycle
    csrr    s1, instret

.globl blake2s_measure_begin
blake2s_measure_begin:
    call    blake2s_bench_run
    mv      s2, a0

    csrr    t0, cycle
    csrr    t1, instret
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
    j       .Lreturn

.Lfail:
    li      a0, BLAKE2S_FAIL

.Lreturn:
    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret

.size main, .-main
