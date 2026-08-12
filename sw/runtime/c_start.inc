/* Shared freestanding C-entry sequence for bare and supervisor runtimes. */

.macro OPENRV64_DEFINE_C_START entry, exit
.section .text.startup, "ax", @progbits
.option norvc
.balign 16
.globl \entry
.type \entry, @function

\entry:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, __stack_top
    li      tp, 0

#ifndef OPENRV64_RUNTIME_NO_BSS_CLEAR
    la      t0, __bss_start
    la      t1, __bss_end
.Lclear_bss_\@:
    bgeu    t0, t1, .Lc_init_\@
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       .Lclear_bss_\@
#endif

.Lc_init_\@:
    call    c_init
    call    main

.globl \exit
\exit:
    ebreak
.Lhalt_\@:
    j       .Lhalt_\@

.size \entry, .-\entry

/* A workload may provide a strong void c_init(void) implementation. */
.weak c_init
.type c_init, @function
c_init:
    ret
.size c_init, .-c_init
.endm
