.section .text.startup, "ax", @progbits
.option norvc
#include "runtime/test_markers.inc"
.globl main
.type main, @function

#ifndef COREMARK_LOOP_OUTER_ITERATIONS
#define COREMARK_LOOP_OUTER_ITERATIONS 1
#endif

#ifndef COREMARK_LOOP_WARMUP_ITERATIONS
#define COREMARK_LOOP_WARMUP_ITERATIONS 0
#endif

#ifndef COREMARK_LOOP_MEASURE_ITERATIONS
#define COREMARK_LOOP_MEASURE_ITERATIONS COREMARK_LOOP_OUTER_ITERATIONS
#endif

#if COREMARK_LOOP_WARMUP_ITERATIONS < 0
#error "COREMARK_LOOP_WARMUP_ITERATIONS cannot be negative"
#endif

#if COREMARK_LOOP_MEASURE_ITERATIONS < 1
#error "COREMARK_LOOP_MEASURE_ITERATIONS must be at least one"
#endif

main:
    addi sp, sp, -16
    sd   ra, 8(sp)
    sd   s0, 0(sp)

    OPENRV64_START_TEST

#if COREMARK_LOOP_WARMUP_ITERATIONS > 0
    li   s0, COREMARK_LOOP_WARMUP_ITERATIONS
1:
    call coremark_loop
    addi s0, s0, -1
    bnez s0, 1b
#endif

    OPENRV64_START_TRACE

#if COREMARK_LOOP_MEASURE_ITERATIONS == 1
    call coremark_loop
#else
    li   s0, COREMARK_LOOP_MEASURE_ITERATIONS
2:
    call coremark_loop
    addi s0, s0, -1
    bnez s0, 2b
#endif

    OPENRV64_END_TRACE

#if (COREMARK_LOOP_WARMUP_ITERATIONS + COREMARK_LOOP_MEASURE_ITERATIONS) != 1
    la   t0, coremark_loop_sink
    lwu  a0, 0(t0)
#endif
.globl coremark_vm_done
coremark_vm_done:
    ld   s0, 0(sp)
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

.size main, .-main
