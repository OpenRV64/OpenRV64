# OpenRV64 PLIC

`openrv64_plic` is a self-contained basic implementation of the ratified
[RISC-V PLIC specification](https://github.com/riscv/riscv-plic-spec/blob/master/riscv-plic.adoc).
It is intended to sit beside `openrv64_clint` under the SoC-level
`rtl/rv_top.v` memory interconnect, not inside `rtl/core`.

The block implements one supervisor-mode interrupt context per hart. Context
index N therefore drives `seip_o[N]`. Machine contexts are intentionally
outside this basic implementation.

## Parameters and signals

- The bus address presented to the PLIC is a target-local offset. The physical
  PLIC window is defined in `rtl/soc/bus/mem_map.v` and translated by
  `openrv64_soc_bus_decode`.
- `NUM_HARTS` sets the number of supervisor-mode target contexts, from 1 through
  the architectural maximum of 15872.
- `NUM_SOURCES` sets the number of real external sources, from 1 through 1023.
- `PRIORITY_WIDTH` sets the implemented WARL priority width and must not exceed
  32 bits.
- `irq_sources_i[0]` maps to architectural interrupt source ID 1. Source ID 0
  is permanently reserved.

The source inputs are active-high and level-sensitive. A request remains
pending if its input deasserts before claim. Once claimed, that source cannot
become pending again until a valid completion is written. If its input remains
asserted after completion, it becomes pending again on the following clock.

## Register map

Offsets follow the standard PLIC layout:

| Offset | Register |
| --- | --- |
| `0x000004 + 4 * (source_id - 1)` | Source priority |
| `0x001000 + 4 * pending_word` | Read-only pending bits |
| `0x002000 + 0x80 * hart + 4 * enable_word` | Enables |
| `0x200000 + 0x1000 * hart` | Priority threshold |
| `0x200004 + 0x1000 * hart` | Claim/complete |

Priority zero disables a source. A target is notified only when an enabled
pending source has priority strictly greater than its threshold. The highest
priority wins; the lowest source ID wins ties.

The PLIC registers are architecturally 32-bit and must be accessed with `LW`
or `SW`. On the OpenRV64 64-bit bus, the target returns both 32-bit lanes of
the addressed bus word and uses the preserved `mem_addr_i[2]` bit to identify
whether an accepted read targeted the threshold or the side-effecting claim
register. Writes require all four byte strobes for their selected lane.

Reserved local offsets within the standard 64 MiB PLIC window read as zero and
ignore writes. The SoC decoder prevents requests outside that global window
from reaching the PLIC.
