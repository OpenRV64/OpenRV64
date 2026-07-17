# OpenRV64 16550 UART

`uart.v` implements a basic NS16550-compatible UART as an SoC peripheral. It
is independent of the core and is intended to be decoded beside the CLINT and
PLIC in `rtl/rv_top.v`.

## Integration

- Module: `openrv64_uart16550`
- The UART consumes target-local offsets `0x0` through `0x7` within a
  QEMU-compatible 0x100-byte aperture. Higher local offsets read as zero and
  ignore writes. The physical window is defined in `rtl/soc/bus/mem_map.v`
  and translated by `openrv64_soc_bus_decode`.
- Interrupt: one active-high `irq_o`; connect it to one `irq_sources_i` bit on
  `openrv64_plic`
- Serial pins: `rx_i`, `tx_o`
- Modem inputs are active low. Tie `cts_ni`, `dsr_ni`, `ri_ni`, and `dcd_ni`
  high if they are unused.

The target uses the same blocking bus as the other OpenRV64 peripherals. It
acknowledges every request routed to it; global range checking belongs to the
SoC decoder. Writes place the register byte in its natural 64-bit lane and
assert the same `mem_wstrb_i` bit. Reads return the complete aligned register
bank, while the exact local address in `mem_addr_i[2:0]` selects any read side
effect. Software should therefore access the UART registers with byte loads
and stores.

## Register map

| Offset | DLAB=0 | DLAB=1 | Access |
| --- | --- | --- | --- |
| `0x0` | RBR / THR | DLL | R / W |
| `0x1` | IER | DLM | R / W |
| `0x2` | IIR / FCR | IIR / FCR | R / W |
| `0x3` | LCR | LCR | R / W |
| `0x4` | MCR | MCR | R / W |
| `0x5` | LSR | LSR | R |
| `0x6` | MSR | MSR | R |
| `0x7` | SCR | SCR | R / W |

The baud rate is `clk_i / (16 * divisor)`. A zero divisor stops the baud
generator. DLL, DLM, and SCR reset to zero for deterministic RTL behavior;
physical 16550 parts leave those three reset values unspecified.

## Implemented behavior

- 5-, 6-, 7-, and 8-bit words
- odd, even, and stick parity
- one, one-and-a-half, and two transmitted stop bits
- break generation and receive break/framing/parity/overrun reporting
- 16-byte transmit and receive FIFOs with 1/4/8/14-byte receive triggers
- four-character receive timeout interrupt
- 16550 interrupt priority and IIR read-to-clear behavior for THRE
- modem status/delta bits, MCR outputs, basic automatic CTS/RTS, and diagnostic
  serial/modem loopback

The FCR DMA mode bit is retained but no DMA request pins are exposed. There is
also no independent receiver reference clock; both directions use `clk_i` and
the programmed divisor. These are deliberate SoC-interface reductions and do
not affect normal programmed-I/O or interrupt-driven 16550 software.
