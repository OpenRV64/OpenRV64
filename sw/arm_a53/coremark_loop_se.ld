OUTPUT_ARCH(aarch64)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00400000, LENGTH = 128M
}

SECTIONS
{
    . = ORIGIN(RAM);

    .text : ALIGN(16)
    {
        KEEP(*(.text.startup))
        *(.text .text.*)
    } > RAM :text

    .rodata : ALIGN(16)
    {
        *(.rodata .rodata.*)
    } > RAM :text

    .data : ALIGN(16)
    {
        *(.data .data.*)
    } > RAM :data

    .bss (NOLOAD) : ALIGN(16)
    {
        *(.bss .bss.*)
        *(COMMON)
    } > RAM :data

    /DISCARD/ :
    {
        *(.comment)
        *(.debug_frame)
        *(.eh_frame .eh_frame.*)
        *(.note .note.*)
    }
}
