.section .text.startup, "ax", @progbits
.option norvc
#include "runtime/test_markers.inc"
.globl main
.type main, @function

#ifndef COREMARK_LOOP_OUTER_ITERATIONS
#define COREMARK_LOOP_OUTER_ITERATIONS 1
#endif

#if COREMARK_LOOP_OUTER_ITERATIONS < 1
#error "COREMARK_LOOP_OUTER_ITERATIONS must be at least one"
#endif

main:
    addi sp, sp, -16
    sd   ra, 8(sp)
#if COREMARK_LOOP_OUTER_ITERATIONS != 1
    sd   s0, 0(sp)
    li   s0, COREMARK_LOOP_OUTER_ITERATIONS
#endif

    OPENRV64_START_TEST

#if COREMARK_LOOP_OUTER_ITERATIONS == 1
    call coremark_loop
#else
1:
    call coremark_loop
    addi s0, s0, -1
    bnez s0, 1b
    ld   s0, 0(sp)
    la   t0, coremark_loop_sink
    lwu  a0, 0(t0)
#endif
.globl coremark_vm_done
coremark_vm_done:
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

.size main, .-main
