# OpenRV64 SoC bus

`mem_map.v` is the single source of truth for physical MMIO windows. No
peripheral contains or accepts a configurable global base address.

| Target | Base | Size | Downstream address |
| --- | ---: | ---: | --- |
| Boot ROM | `0x0000_1000` | `0x0001_0000` | physical address minus ROM base |
| Memory | `0x8000_0000` | `0x0001_0000` | physical address minus memory base |
| CLINT | `0x0200_0000` | `0x0001_0000` | physical address minus CLINT base |
| PLIC | `0x0C00_0000` | `0x0400_0000` | physical address minus PLIC base |
| UART | `0x1000_0000` | `0x0000_0100` | physical address minus UART base |
| GPIO | `0x1001_0000` | `0x0000_1000` | physical address minus GPIO base |
| Timer | `0x1002_0000` | `0x0000_1000` | physical address minus timer base |

`openrv64_soc_bus_decode` is purely combinational. It fans out the complete
blocking request bus, asserts at most one target valid, and returns only the
selected target's ready/data response. A target that holds ready low applies
backpressure unchanged to the upstream core. An address outside every window
is not routed; it completes immediately with `mem_error_o` asserted.

The fixed devices follow the conventional QEMU RISC-V `virt` addresses. GPIO
and the general-purpose timer are board-specific and occupy separate 4 KiB
slots outside QEMU's first VirtIO aperture. Reset begins at ROM `0x1000`; its
three-instruction stub constructs RAM base `0x8000_0000` and jumps there.
