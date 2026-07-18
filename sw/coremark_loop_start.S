.section .text.startup, "ax", @progbits
.option norvc
.globl _start
.type _start, @function

_start:
    j    .Linit

    /* Keep 0x80000010 off the execution path: the legacy software-trace
       harness reserves that PC as its finite-test completion marker. */
    .org 0x20
.Linit:
    li   sp, 0x80010000
    li   tp, 0
    call coremark_loop
    ebreak
.Lhalt:
    j    .Lhalt

.size _start, .-_start
