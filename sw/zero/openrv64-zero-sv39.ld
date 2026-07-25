OUTPUT_ARCH(riscv)
ENTRY(zero_vm_boot)

PHDRS
{
    boot PT_LOAD FLAGS(5);
    supervisor_text PT_LOAD FLAGS(5);
    supervisor_data PT_LOAD FLAGS(6);
    seed PT_LOAD FLAGS(4);
    page_tables PT_LOAD FLAGS(4);
}

SECTIONS
{
    .boot 0x80000000 :
    {
        KEEP(*(.text.boot))
    } :boot

    .text 0x40001000 : AT(0x80001000)
    {
        KEEP(*(.text.startup))
        *(.text .text.*)
    } :supervisor_text

    .rodata ALIGN(8) :
        AT(0x80000000 + (ADDR(.rodata) - 0x40000000))
    {
        *(.rodata .rodata.*)
    } :supervisor_text

    .data ALIGN(8) :
        AT(0x80000000 + (ADDR(.data) - 0x40000000))
    {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } :supervisor_data

    .bss ALIGN(8) (NOLOAD) :
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } :supervisor_data

    __supervisor_image_end = .;
    PROVIDE(__global_pointer$ = __supervisor_image_end + 0x800);
    __stack_top = 0x4003f000;

    .zero_seed 0x80200000 : AT(0x80200000)
    {
        KEEP(*(.zero_seed))
    } :seed

    .page_table.root 0x80300000 : AT(0x80300000)
    {
        KEEP(*(.page_table.root))
    } :page_tables

    .page_table.level1 0x80301000 : AT(0x80301000)
    {
        KEEP(*(.page_table.level1))
    } :page_tables

    .page_table.level0 0x80302000 : AT(0x80302000)
    {
        KEEP(*(.page_table.level0))
    } :page_tables

    ASSERT(__supervisor_image_end <= 0x4003e000,
           "zero benchmark supervisor image collides with its stack")
    ASSERT(SIZEOF(.zero_seed) == 0x80000,
           "zero benchmark seed must cover 64 scattered page pairs")
    ASSERT(SIZEOF(.page_table.root) == 4096,
           "Sv39 root page table must be exactly 4 KiB")
    ASSERT(SIZEOF(.page_table.level1) == 4096,
           "Sv39 level-1 page table must be exactly 4 KiB")
    ASSERT(SIZEOF(.page_table.level0) == 4096,
           "Sv39 level-0 page table must be exactly 4 KiB")

    /DISCARD/ :
    {
        *(.eh_frame .eh_frame.*)
        *(.note .note.*)
    }
}
