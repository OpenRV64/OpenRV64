OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x80000000;

    .text : ALIGN(8)
    {
        KEEP(*(.text.startup))
        *(.text .text.*)
    }

    /DISCARD/ :
    {
        *(.comment)
        *(.note .note.*)
    }

    ASSERT(SIZEOF(.text) <= 0x10000,
           "OpenSBI trampoline exceeds its 64 KiB slot")
}
