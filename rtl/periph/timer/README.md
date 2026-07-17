# OpenRV64 general-purpose timer

`openrv64_timer` is a target-local 64-bit down-counter. It supports one-shot or
periodic operation and one active-high interrupt output. It has no PWM or
waveform output.

## Local register map

| Offset | Register | Access | Description |
| ---: | --- | --- | --- |
| `0x00` | CONTROL | R/W | Bit 0 enable, bit 1 periodic, bit 2 IRQ enable |
| `0x08` | DIVIDER | R/W | 32-bit prescaler value |
| `0x10` | LOAD | R/W | Reload value; a write also loads VALUE |
| `0x18` | VALUE | R/W | Current down-counter value |
| `0x20` | STATUS | R/W1C | Bit 0 IRQ pending, bit 1 timer active |

The counter decrements once every `DIVIDER + 1` `clk_i` cycles. On the tick
that changes VALUE from one to zero, the interrupt-pending latch sets. A
one-shot disables itself; a periodic timer reloads VALUE from LOAD. Writing one
to STATUS bit zero clears the pending latch, with a coincident expiry taking
priority. `ENABLE_INTERRUPTS=0` hard-disables `irq_o` while retaining timer
state and status behavior.

The physical window is defined only in `rtl/soc/bus/mem_map.v`; the timer
receives local offsets from `openrv64_soc_bus_decode`.

