# OpenRV64 CLINT

`openrv64_clint` is a self-contained, SiFive CLINT-compatible machine timer
and software-interrupt block. It exposes the same 64-bit blocking memory bus
used by the core, plus direct per-hart interrupt outputs for later integration
in `rtl/rv_top.v`.

The register semantics follow the
[RISC-V ACLINT 1.0 specification](https://github.com/riscvarchive/riscv-aclint/blob/main/riscv-aclint.adoc),
using its backward-compatible unified SiFive CLINT layout.

## Register map

All addresses presented to `openrv64_clint` are target-local offsets. The
global CLINT window is defined once in `rtl/soc/bus/mem_map.v`, and
`openrv64_soc_bus_decode` removes that base before asserting `mem_valid_i`.

| Offset | Width | Register |
| --- | --- | --- |
| `0x0000 + 4 * hart` | 32 bits | `MSIP[hart]`; only bit 0 is implemented |
| `0x4000 + 8 * hart` | 64 bits | `MTIMECMP[hart]` |
| `0xBFF8` | 64 bits | shared `MTIME` |

The implementation supports 1 to 4095 harts through `NUM_HARTS`. Reserved
local offsets inside the `0x0000`-`0xBFFF` CLINT range read as zero and ignore
writes. Global range ownership is entirely in the SoC decoder.

`MTIME` increments once for each cycle in which `mtime_tick_i` is high. The
input must be synchronous to `clk_i`; tie it high when the SoC clock itself is
the timer timebase, or drive it with a one-cycle pulse from a divider. A write
to `MTIME` has priority over a simultaneous tick.

Writes honor `mem_wstrb_i`. The target uses `mem_addr_i[63:3]` to select a
64-bit bus word and preserves the standard byte-lane layout. A 32-bit access
to an odd-numbered `MSIP` therefore uses the upper half of the corresponding
64-bit bus word.

On reset, `MTIME` and all `MSIP` bits clear to zero. `MTIMECMP` is initialized
to all ones. The architectural specification leaves its reset value unknown;
all ones provides deterministic startup without an immediate timer interrupt.
