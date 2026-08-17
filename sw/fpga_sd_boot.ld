OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x1000;
    .text : {
        KEEP(*(.text.startup))
        *(.text*)
        *(.rodata*)
    }
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
    ASSERT(SIZEOF(.text) <= 4096, "FPGA SD boot ROM exceeds 4 KiB")
}
