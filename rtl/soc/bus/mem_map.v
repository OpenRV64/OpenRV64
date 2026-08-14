`ifndef OPENRV64_SOC_MEM_MAP_V
`define OPENRV64_SOC_MEM_MAP_V

// OpenRV64 SoC physical address map.
//
// Bus targets consume target-local offsets. These are the only global
// addresses and window sizes; openrv64_soc_bus_decode translates them.
// Standard-device bases follow the conventional QEMU RISC-V "virt" layout.
// Window sizes remain OpenRV64 implementation choices.
`define OPENRV64_SOC_ROM_BASE    64'h0000_0000_0000_1000
`define OPENRV64_SOC_ROM_SIZE    64'h0000_0000_0000_1000

`define OPENRV64_SOC_MEMORY_BASE 64'h0000_0000_8000_0000
`define OPENRV64_SOC_MEMORY_SIZE 64'h0000_0000_1000_0000
// Sv39 PTEs carry a 44-bit PPN, so normal physical memory may extend to the
// exclusive 56-bit physical-address limit.  MEMORY_SIZE is installed RAM;
// DRAM_PMA_SIZE is the larger normal-memory attribute aperture.
`define OPENRV64_SOC_DRAM_PMA_LIMIT 64'h0100_0000_0000_0000
`define OPENRV64_SOC_DRAM_PMA_SIZE  64'h00ff_ffff_8000_0000
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

// L2-resident invariant aperture.  This is the top 16 MiB of the 56-bit
// cacheable DRAM PMA aperture, but it is completed by the shared L2 without a
// backing-memory transaction and is not installed RAM.
// The first three pages have defined behavior; the remainder is reserved
// read-as-zero/write-ignored space for future invariant types.
`define OPENRV64_SOC_INVARIANT_BASE        64'h00ff_ffff_ff00_0000
`define OPENRV64_SOC_INVARIANT_PAGE_SIZE   64'h0000_0000_0000_1000
`define OPENRV64_SOC_INVARIANT_ZERO_BASE   64'h00ff_ffff_ff00_0000
`define OPENRV64_SOC_INVARIANT_ONE_BASE    64'h00ff_ffff_ff00_1000
`define OPENRV64_SOC_INVARIANT_RANDOM_BASE 64'h00ff_ffff_ff00_2000
`define OPENRV64_SOC_INVARIANT_RAZWI_BASE  64'h00ff_ffff_ff00_3000
`define OPENRV64_SOC_INVARIANT_RAZWI_SIZE  64'h0000_0000_00ff_d000
`define OPENRV64_SOC_INVARIANT_SIZE        64'h0000_0000_0100_0000

// Stable PLIC source assignments made by openrv64_platform.  External source
// input bit zero continues at architectural PLIC source ID 4.
`define OPENRV64_SOC_PLIC_SOURCE_UART  1
`define OPENRV64_SOC_PLIC_SOURCE_GPIO  2
`define OPENRV64_SOC_PLIC_SOURCE_TIMER 3
`define OPENRV64_SOC_PLIC_SOURCE_EXTERNAL_BASE 4

`endif
