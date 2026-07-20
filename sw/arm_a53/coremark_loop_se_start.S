.arch armv8-a

.section .text.startup, "ax", %progbits
.align 4
.global _start
.type _start, %function

/*
 * Minimal Linux/AArch64 entry point for gem5 syscall-emulation mode.  The
 * benchmark body is the same sw/coremark_loop.c used by the RTL and QEMU
 * images; only the process exit mechanism differs.
 */
_start:
    bl      coremark_loop

    /* Validate the memory result, not the undefined return register of the
       void coremark_loop() function. */
    ldr     x1, =coremark_loop_sink
    ldr     w2, [x1]
    ldr     w3, =0x0a27789d
    cmp     w2, w3
    cset    w0, ne

    /* Linux AArch64 exit(status), handled directly by gem5 SE mode. */
    mov     x8, #93
    svc     #0

.Lhang:
    b       .Lhang

.size _start, .-_start
