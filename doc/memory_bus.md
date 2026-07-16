# OpenRV64 Initial Memory Bus

The first top-level interface is a single 64-bit blocking memory bus. It is
deliberately smaller than AXI/Wishbone so the first core milestones can focus
on fetch, decode, and execute behavior before interconnect details.

## Signals

| Signal | Direction | Description |
| --- | --- | --- |
| `mem_valid` | core to memory | Request is active. Request fields stay stable until `mem_ready`. |
| `mem_ready` | memory to core | Response/acceptance for the active request. |
| `mem_write` | core to memory | `1` for write, `0` for read. The initial top only reads. |
| `mem_addr[63:0]` | core to memory | Byte address. The initial top aligns fetch reads to 8 bytes. |
| `mem_wdata[63:0]` | core to memory | Write data. |
| `mem_wstrb[7:0]` | core to memory | One byte lane enable per write byte. |
| `mem_rdata[63:0]` | memory to core | Read data valid when `mem_ready` is high for a read. |

There is no burst, byte-size, privilege, error, or separate instruction/data
channel yet. Those should be added only when the core has behavior that needs
them.
