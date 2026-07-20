.arch armv8-a

.section .text.startup, "ax", %progbits
.align 4
.global _start
.type _start, %function

_start:
    bl      main

    /* Linux AArch64 exit(main_result), handled by gem5 SE mode. */
    mov     x8, #93
    svc     #0

.Lhang:
    b       .Lhang

.size _start, .-_start
