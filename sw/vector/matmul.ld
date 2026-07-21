OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = 0x100;
    .text : ALIGN(4)
    {
        KEEP(*(.text.startup))
        *(.text .text.*)
    } :text

    /* Fixed addresses make the small RTL test image and result checks simple. */
    . = 0x300;
    .vector_a : ALIGN(32) { KEEP(*(.vector_a)) } :rodata

    . = 0x400;
    .vector_b : ALIGN(32) { KEEP(*(.vector_b)) } :rodata

    . = 0x500;
    .vector_c : ALIGN(32) { KEEP(*(.vector_c)) } :data

    /DISCARD/ :
    {
        *(.riscv.attributes)
        *(.comment)
        *(.note .note.*)
    }
}
