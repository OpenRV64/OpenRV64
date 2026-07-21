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

    . = 0x400;
    .vector_bf16_a : ALIGN(32) { KEEP(*(.vector_bf16_a)) } :rodata

    . = 0x800;
    .vector_bf16_b : ALIGN(32) { KEEP(*(.vector_bf16_b)) } :rodata

    . = 0xa00;
    .vector_bf16_c : ALIGN(32) { KEEP(*(.vector_bf16_c)) } :data

    /DISCARD/ :
    {
        *(.riscv.attributes)
        *(.comment)
        *(.note .note.*)
    }
}

