# OpenRV64 Initial Memory Bus

The first top-level interface is a single 64-bit blocking memory bus. It is
deliberately smaller than AXI/Wishbone so the first core milestones can focus
on fetch, decode, and execute behavior before interconnect details.

## Signals

| Signal | Direction | Description |
| --- | --- | --- |
| `mem_valid` | core to memory | Request is active. Request fields stay stable until `mem_ready`. |
| `mem_ready` | memory to core | Response/acceptance for the active request. |
| `mem_write` | core to memory | `1` for write, `0` for read. |
| `mem_addr[63:0]` | core to memory | Byte address. Fetch requests are 8-byte aligned; data requests preserve their effective byte address. |
| `mem_wdata[63:0]` | core to memory | Write data. |
| `mem_wstrb[7:0]` | core to memory | One byte lane enable per write byte. |
| `mem_rdata[63:0]` | memory to core | Read data valid when `mem_ready` is high for a read. |
| `mem_error` | memory to core | Completion failed; valid only with `mem_valid && mem_ready`. |

There is no burst, transaction ID, or separate instruction/data channel yet.
Access size and privilege are carried inside the core through translation and
PMP, but are not exported on this initial physical bus.

## Core requester

`rtl/core/bus/bus.v` is the only core module that drives the top-level memory
requester. It accepts separate blocking requests from fetch and the LSU,
latches the selected request, and holds the exported request stable through
completion. LSU requests have priority when both requesters arrive together.
An obsolete fetch can be cancelled, but any already-exported physical request
is still drained before another request is issued.

On a fetch completion, the fetch queue can present an accepted successor miss
on an internal sideband. The core requester captures that successor on the
completion edge and returns directly to translation rather than spending an
intervening cycle in `IDLE`. A resident-line hit does not assert the sideband
or launch an external request. A waiting LSU still takes priority. This is
internal request chaining, not a burst on the top-level physical bus: each
missed 8-byte line remains a separate blocking transaction.

Request ownership includes the virtual address, access payload, effective
privilege, VM mode, ASID, and root page-table PPN. The bus captures that whole
context when it grants ownership; an in-flight request never observes later
CSR or requester-context changes. TLB entries are tagged by VM mode and ASID,
with global entries matching every ASID only within their original VM mode.

Bare requests use identity translation. When the effective privilege is S or
U and `satp.MODE=Sv39`, requests first search the fully associative CAM in
`rtl/core/bus/tlb.v`; a miss is sent to `rtl/core/bus/ptw.v`. The TLB stores
mode, ASID/global ownership, 4 KiB/2 MiB/1 GiB page level, and leaf permission
metadata. A tag hit can therefore complete with a page fault when the cached
leaf rejects the current read, write, execute, privilege, SUM, MXR, A, or D
requirements.

The PTW implements a blocking three-level Sv39 walk. It checks canonical
virtual addresses, PTE validity and reserved encodings, leaf permissions,
superpage alignment, inherited global mappings, SUM/MXR, and A/D state.
Physical errors while reading a PTE become an access fault for the original
request. Successful translations refill the TLB; page and access faults are
kept distinct through fetch/LSU, writeback, and the machine/supervisor trap
context.

`SFENCE.VMA` is serializing. At retirement it pulses `tlbi_i`, flushes younger
work, and restarts at the next PC. The current implementation intentionally
treats every `SFENCE.VMA`, including forms with nonzero `rs1` or `rs2`, as a
global shootdown. Invalidation clears TLB validity; it does not manufacture a
faulting entry. The next access misses and either obtains a fresh translation
or receives the PTW's page/access fault. If a shootdown overlaps an active
walk, the bus drains and discards the stale walk result, then restarts it so it
cannot refill the TLB with pre-fence state.

PMP is enforced at the physical requester boundary after translation. Final
instruction/data accesses use their effective privilege and access type;
implicit PTE reads are checked as S-mode 8-byte reads. A PMP denial is returned
through the same physical error path and becomes an access fault for the
original operation.

Current VM limitations are deliberate: only Bare and Sv39 are WARL `satp`
modes, shootdown is global rather than address/ASID selective, and A/D bits use
Svade-style fault-on-clear behavior because the memory bus has no atomic PTE
read-modify-write operation. Sv48, Sv57, hardware A/D updates, and IOASIDs are
not implemented.

Memory targets return the aligned 64-bit word selected by `mem_addr[63:3]`.
Fetch retains both 32-bit instructions from that word in one of eight tagged
two-slot buffers. The eight lines are arranged as two sets selected by address
bit 3, with four ways comparing tag bits `[63:4]`; the circular unread order
still alternates naturally between sets. The window can hold up to sixteen
unread instructions. Consuming an entry clears its unread state but preserves
its resident line tag and data. A control-flow redirect discards the wrong-path
unread stream and checks the resident set. A predicted direct target hit can
replace the branch in IF/ID on the same edge; other resident hits can bypass an
empty fetch queue. Both cases avoid an external request and receive fresh
dynamic trace IDs. Traps, privilege/context returns, `FENCE.I`, and
`SFENCE.VMA` invalidate the resident window. A target in the upper half of a
word uses only that half, then continues with two instructions per following
aligned request.

`ENABLE_PREDECODE_TARGETS` controls the optional direct-target sidecar. When
enabled, fetch stores each direct control's signed PC-relative displacement in
a 20-bit field with the always-zero low bit omitted. The core sign-extends that
encoding and reuses its normal target adder, so a predicted resident target can
still replay on the redirect edge without storing sixteen absolute 64-bit
addresses. When disabled, the displacement arrays, metadata, and predecode
state are not elaborated. The instruction/tag loop buffer remains intact, and
normal decode still supplies control-flow type and target information.

For narrow data accesses, `mem_addr[2:0]` identifies the addressed byte lane;
store data and `mem_wstrb` use that same lane placement. Preserving the low
address bits is required for side-effecting 32-bit MMIO registers, such as the
PLIC threshold and claim registers that share one 64-bit bus word.

## SoC routing

The physical windows are defined only in `rtl/soc/bus/mem_map.v`.
`openrv64_soc_bus_decode` routes a request to boot ROM, memory, CLINT, PLIC,
UART, GPIO, or the general-purpose timer and muxes the selected target's
`mem_ready` and `mem_rdata` back upstream. Target addresses are translated to
local offsets. An unmapped request reaches no target and completes with
`mem_error` asserted.

Peripheral modules do not contain global base addresses or perform global
range checks. A routed peripheral request is therefore always acknowledged,
including reserved offsets inside that peripheral's assigned window.
