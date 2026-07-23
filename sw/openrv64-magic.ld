OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 64K
}

SECTIONS
{
    . = ORIGIN(RAM);

    .text : ALIGN(8)
    {
        KEEP(*(.text.startup))
        KEEP(*(.text.trap))
        *(.text .text.*)
    } > RAM :text

    .rodata : ALIGN(8)
    {
        *(.rodata .rodata.*)
    } > RAM :text

    .data : ALIGN(8)
    {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > RAM :data

    .bss (NOLOAD) : ALIGN(8)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > RAM :data

    . = ALIGN(16);
    __image_end = .;
    PROVIDE(__global_pointer$ = __image_end + 0x800);
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);

    ASSERT(__image_end <= (__stack_top - 4096),
           "firmware image leaves less than 4 KiB for the stack")

    /DISCARD/ :
    {
        *(.eh_frame .eh_frame.*)
        *(.note .note.*)
    }
}
