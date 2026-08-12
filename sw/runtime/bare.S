/*
 * Minimal machine-mode runtime for freestanding C workloads.
 *
 * Contract:
 *   void c_init(void);  // optional, weak no-op default
 *   uint64_t main(void); // required; return value remains in a0
 */

#include "c_start.inc"

.section .text.startup, "ax", @progbits
.option norvc
.globl _start
.type _start, @function
_start:
    j       openrv64_runtime_c_start

    /* The legacy trace harness reserves PC 0x80000010 as a done marker. */
    .org 0x20
.size _start, .-_start

OPENRV64_DEFINE_C_START openrv64_runtime_c_start, \
    openrv64_runtime_done
