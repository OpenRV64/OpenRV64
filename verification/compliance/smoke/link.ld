OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS
{
    ram PT_LOAD FLAGS(7);
}

SECTIONS
{
    . = 0x80000000;
    .text : ALIGN(16) {
        KEEP(*(.text.init))
        *(.text .text.*)
    } :ram
    .rodata : ALIGN(16) { *(.rodata .rodata.*) } :ram
    .data : ALIGN(16) { *(.data .data.*) } :ram
    .bss : ALIGN(16) { *(.bss .bss.* COMMON) } :ram
    .tohost : ALIGN(64) { KEEP(*(.tohost)) } :ram
    /DISCARD/ : { *(.comment) *(.riscv.attributes) }
}
