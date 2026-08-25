/* SPDX-License-Identifier: BSD-2-Clause */
/* Minimal uploaded M-mode stub used to prove debug-interrupt execution. */

    .section .text
    .option norvc
    .globl _start
    .type _start, @function

_start:
    li      a0, 0x51
    ret
    .size _start, .-_start
