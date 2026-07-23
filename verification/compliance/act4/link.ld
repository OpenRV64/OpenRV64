OUTPUT_ARCH(riscv)
ENTRY(rvtest_entry_point)

PHDRS
{
  ram PT_LOAD FLAGS(7);
}

SECTIONS
{
  . = 0x80000000;
  .text.init : ALIGN(16) { KEEP(*(.text.init)) } :ram
  .text.rvtest : ALIGN(16) { *(.text.rvtest) *(.text.rvtest.*) } :ram
  . = ALIGN(0x4000);
  .data : { *(.data) *(.data.*) } :ram
  .tohost : ALIGN(64) { KEEP(*(.tohost)) } :ram
  . = ALIGN(0x1000);
  .text.rvmodel : {
    *(.text.rvmodel) *(.text.rvmodel.*) *(.text) *(.text.*)
  } :ram
  .bss : ALIGN(16) { *(.bss) *(.bss.*) *(COMMON) } :ram
  . = ALIGN(0x1000);
  _end = .;
}
