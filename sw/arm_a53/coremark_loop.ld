OUTPUT_ARCH(aarch64)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}

MEMORY
{
    /* Leave the first 2 MiB of QEMU virt RAM for its generated DTB. */
    RAM (rwx) : ORIGIN = 0x40200000, LENGTH = 126M
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
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > RAM :data

    __image_end = .;
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);

    ASSERT(__image_end <= (__stack_top - 4096),
           "A53 workload leaves less than 4 KiB for the stack")

    /DISCARD/ :
    {
        *(.comment)
        *(.debug_frame)
        *(.eh_frame .eh_frame.*)
        *(.note .note.*)
    }
}
