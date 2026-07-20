.arch armv8-a

.section .text.startup, "ax", %progbits
.align 4
.global _start
.type _start, %function

/*
 * QEMU's Arm virt board maps RAM at 0x4000_0000.  The image starts 2 MiB
 * above that to avoid QEMU's generated DTB.  The generic loader sets CPU0's
 * PC to this ELF entry point; no firmware or operating system runs.
 */
_start:
    /* Generic-loader entry bypasses firmware, so enable AArch64 FP/SIMD at
       EL1 before GCC's Cortex-A53 code uses NEON to initialize counters. */
    mrs     x0, cpacr_el1
    orr     x0, x0, #(3 << 20)
    msr     cpacr_el1, x0
    isb

    ldr     x0, =__stack_top
    mov     sp, x0
    bl      coremark_loop

    /* Make the cross-ISA result explicit instead of trusting a return-value
       register from the void C function. */
    ldr     x0, =coremark_loop_sink
    ldr     w2, [x0]
    ldr     x0, =a53_coremark_result
    str     w2, [x0]

    ldr     w3, =0x0a27789d
    cmp     w2, w3
    b.ne    .Lfail

    /* AArch64 semihosting: SYS_EXIT_EXTENDED(reason, status). */
    mov     x0, #0x20
    ldr     x1, =.Lexit_success
    hlt     #0xf000

.Lfail:
    mov     x0, #0x20
    ldr     x1, =.Lexit_failure
    hlt     #0xf000

.Lhang:
    wfi
    b       .Lhang

.align 3
.Lexit_success:
    .quad   0x00020026
    .quad   0
.Lexit_failure:
    .quad   0x00020026
    .quad   1

.size _start, .-_start

.section .data.result, "aw", %progbits
.align 2
.global a53_coremark_result
.type a53_coremark_result, %object
a53_coremark_result:
    .word   0
.size a53_coremark_result, 4
