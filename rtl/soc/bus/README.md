# OpenRV64 SoC bus

`mem_map.v` is the single source of truth for physical MMIO windows. No
peripheral contains or accepts a configurable global base address.

| Target | Base | Size | Downstream address |
| --- | ---: | ---: | --- |
| Boot ROM | `0x0000_1000` | `0x0001_0000` | physical address minus ROM base |
| Memory | `0x8000_0000` | `0x1000_0000` | physical address minus memory base |
| CLINT | `0x0200_0000` | `0x0001_0000` | physical address minus CLINT base |
| PLIC | `0x0C00_0000` | `0x0400_0000` | physical address minus PLIC base |
| FPGA debug snapshot | `0x0C30_0000` | `0x0000_1000` | PLIC-local intercept when FPGA debug is enabled |
| FPGA debug stub | `0x0C30_4000` | `0x0000_4000` | PLIC-local intercept when FPGA debug is enabled |
| UART | `0x1000_0000` | `0x0000_0100` | physical address minus UART base |
| GPIO | `0x1001_0000` | `0x0000_1000` | physical address minus GPIO base |
| Timer | `0x1002_0000` | `0x0000_1000` | physical address minus timer base |
| Invariant zero page | `0x00FF_FFFF_FF00_0000` | `0x0000_1000` | L2-generated, no downstream request |
| Invariant one page | `0x00FF_FFFF_FF00_1000` | `0x0000_1000` | L2-generated, no downstream request |
| Invariant pseudorandom page | `0x00FF_FFFF_FF00_2000` | `0x0000_1000` | L2-generated, no downstream request |
| Invariant reserved RAZ/WI | `0x00FF_FFFF_FF00_3000` | `0x00FF_D000` | L2-generated, no downstream request |

`openrv64_soc_bus_decode` is purely combinational. It fans out the complete
blocking request bus, asserts at most one target valid, and returns only the
selected target's ready/data response. A target that holds ready low applies
backpressure unchanged to the upstream core. An address outside every window
is not routed; it completes immediately with `mem_error_o` asserted.

The physical boot ROM occupies the first 4 KiB of its 64 KiB decode window.
It uses a synchronous block-ROM-compatible read, one explicit wait cycle, one
response cycle, and one recovery cycle.  It therefore never accepts requests
back to back; offsets in the remainder of the decode window return zero with
the same timing.

The decoder's memory-window size is parameterized so reduced-capacity unit
tests can keep the decoder and backing RAM consistent. The platform default is
the 256 MiB aperture declared by `mem_map.v`.

The fixed devices follow the conventional QEMU RISC-V `virt` addresses. GPIO
and the general-purpose timer are board-specific and occupy separate 4 KiB
slots outside QEMU's first VirtIO aperture. Reset begins at ROM `0x1000`; its
four-instruction stub forwards `mhartid` in `a0`, constructs RAM base
`0x8000_0000`, and jumps there.

The two FPGA-debug rows are conditional subregions of the PLIC decode window,
not independent top-level decoder targets. They are absent when
`FPGA_DEBUG_ENABLE` is zero. The snapshot is a 4 KiB CPU-write/JTAG-read array.
The 16 KiB stub workspace is CPU executable and conditionally byte-writable,
with an independent paced 64-bit USER1 JTAG read/write port. CPU writes are
accepted only while the JTAG debug-trigger level is asserted, which keeps
S-mode from replacing code that will later execute in M-mode. Neither region
is an architectural PLIC register range.

The same FPGA-debug configuration also instantiates a separate, non-CPU-
mapped 16 KiB rolling UART-TX capture. It records bytes when the NS16550 starts
transmitting them, retains a 64-bit total-byte counter, and exposes only a
paced 64-bit USER1 JTAG read port. It is not a third PLIC subregion.

The 16 MiB invariant aperture occupies `0x00ff_ffff_ff00_0000` through
`0x00ff_ffff_ffff_ffff`, the top of the 56-bit physical DRAM PMA aperture.  It
does not reduce the installed 256 MiB RAM window.  It is described separately
in the device tree and intercepted by the shared L2 before its SRAM/miss path.
The zero page returns all-zero cache lines.  Every 64-bit lane of the
one page contains numeric one.  The random page advances a deterministic 64-bit
xorshift generator once per dispatched read and expands that state into a
64-byte response; it is useful for testing and bulk-data experiments but is
not a cryptographic entropy source.  The remainder of the aperture reads as
zero, reserving address space for future invariant types.  Ordinary writes
anywhere in the aperture are acknowledged and discarded, allowing cacheable
store-buffer entries to drain without changing invariant contents.  No part
of the aperture allocates L2 SRAM or accesses DDR.  The core's ordinary
translation and PMP/PMA checks still occur before the physical request reaches
L2.
