OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x80200000;

    .text : ALIGN(8)
    {
        KEEP(*(.text.startup))
        *(.text .text.*)
    }

    .rodata : ALIGN(8)
    {
        *(.rodata .rodata.*)
    }

    /DISCARD/ :
    {
        *(.comment)
        *(.note .note.*)
    }

    ASSERT((SIZEOF(.text) + SIZEOF(.rodata)) <= 0x10000,
           "OpenSBI smoke payload exceeds its 64 KiB slot")
}
