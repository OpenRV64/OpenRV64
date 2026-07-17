`ifndef OPENRV64_SOC_MEM_MAP_V
`define OPENRV64_SOC_MEM_MAP_V

// OpenRV64 SoC physical address map.
//
// Bus targets consume target-local offsets. These are the only global
// addresses and window sizes; openrv64_soc_bus_decode translates them.
// Standard-device bases follow the conventional QEMU RISC-V "virt" layout.
// Window sizes remain OpenRV64 implementation choices.
`define OPENRV64_SOC_ROM_BASE    64'h0000_0000_0000_1000
`define OPENRV64_SOC_ROM_SIZE    64'h0000_0000_0001_0000

`define OPENRV64_SOC_MEMORY_BASE 64'h0000_0000_8000_0000
`define OPENRV64_SOC_MEMORY_SIZE 64'h0000_0000_0001_0000
`define OPENRV64_SOC_RESET_VECTOR `OPENRV64_SOC_ROM_BASE

`define OPENRV64_SOC_CLINT_BASE 64'h0000_0000_0200_0000
`define OPENRV64_SOC_CLINT_SIZE 64'h0000_0000_0001_0000

`define OPENRV64_SOC_PLIC_BASE  64'h0000_0000_0c00_0000
`define OPENRV64_SOC_PLIC_SIZE  64'h0000_0000_0400_0000

`define OPENRV64_SOC_UART_BASE  64'h0000_0000_1000_0000
`define OPENRV64_SOC_UART_SIZE  64'h0000_0000_0000_0100

// GPIO and the general-purpose timer are OpenRV64-specific. Keep them in
// page-aligned MMIO slots without occupying QEMU virt's 0x1000_1000 VirtIO
// aperture.
`define OPENRV64_SOC_GPIO_BASE  64'h0000_0000_1001_0000
`define OPENRV64_SOC_GPIO_SIZE  64'h0000_0000_0000_1000

`define OPENRV64_SOC_TIMER_BASE 64'h0000_0000_1002_0000
`define OPENRV64_SOC_TIMER_SIZE 64'h0000_0000_0000_1000

`endif
