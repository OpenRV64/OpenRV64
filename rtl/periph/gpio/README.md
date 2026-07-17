# OpenRV64 GPIO

`openrv64_gpio` is a target-local, programmed-I/O GPIO block. It exposes
separate synchronized input and registered output vectors; it deliberately has
no direction register or pad tri-state control yet.

## Parameters and signals

- `NUM_PINS` selects 1 through 64 input/output bits; the default is 32.
- `ENABLE_INTERRUPTS=0` hard-disables `irq_o` without removing the interrupt
  configuration registers.
- `gpio_in_i` passes through a two-flop synchronizer before it is visible.
- `gpio_out_o` is the output register value.
- `irq_o` is one active-high aggregated interrupt suitable for a PLIC source.

## Local register map

| Offset | Register | Access | Description |
| ---: | --- | --- | --- |
| `0x00` | INPUT | R | Synchronized pin inputs |
| `0x08` | OUTPUT | R/W | Registered pin outputs |
| `0x10` | IRQ_ENABLE | R/W | One enables routing for that pin |
| `0x18` | IRQ_TYPE | R/W | One selects edge; zero selects level |
| `0x20` | IRQ_POLARITY | R/W | One selects rising/high; zero falling/low |
| `0x28` | IRQ_PENDING | R/W1C | Enabled pending sources; writes clear edge latches |

Level interrupts follow the synchronized input and cannot be cleared while
their configured level remains active. Edge interrupts remain latched until a
strobed W1C write; transitions are latched only while a pin is configured for
edge operation. A coincident edge wins over a clear. Disabled sources do not
appear in IRQ_PENDING and cannot assert `irq_o`.

The physical window is defined only in `rtl/soc/bus/mem_map.v`; the GPIO module
receives local offsets from `openrv64_soc_bus_decode`.
