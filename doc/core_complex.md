# OpenRV64 core complex and shared L2

`openrv64_core_complex_nh` is the generated 1-16-hart complex.  It straps
each legacy hart endpoint to `HART_ID_BASE + hart_index`, round-robin
arbitrates requests onto CCX, and terminates them in a shared L2.
`genbus_interface` then converts the L2 producer width to the independently
selected AXI4 or WISHBONE Revision B.4 width and protocol.

```text
hart 0 -- legacy adapter --+
hart 1 -- legacy adapter --+-- CCX crossbar -- shared L2 -- genbus_interface
...                        |                                      |
hart N -- legacy adapter --+                         +------------+-----------+
                                                       |                      |
                                                  AXI4 master        WISHBONE B.4 master
```

The older `openrv64_ccx_protocol_wrapper_{1h,2h,4h}` modules remain cacheless
protocol tests and compatibility seams.  They are not aliases for the full
core complex.

## L2 geometry and policy

The defaults are:

- 256 KiB, configurable to 512 KiB or 1 MiB with `L2_BYTES`;
- eight ways, configurable with `L2_WAYS`;
- 64-byte lines, matching the current L1 line size;
- write-back and write-allocate; and
- invalid-first, round-robin replacement.

Eight ways is a defensible starting point, not a measured optimum.  At
256 KiB and 64-byte lines it gives 512 sets.  Four ways would reduce tag
comparators and likely lower hit latency and energy, but changing that before
workload measurements would be guesswork.  The parameter remains exposed so
four-way and eight-way implementations can be compared with miss-rate and
timing data.

The behavioral controller accepts one active line miss.  While that line is
being written back or refilled, up to `L2_MERGE_ENTRIES` requests for the same
line may join it.  They replay in CCX acceptance order after refill, including
writes, so read-after-write, write-after-read, and write-after-write cases on
the line retain one explicit order.  Requests for other lines wait.  This is
same-line miss merging; it is not a banked hit-under-miss cache or a general
multi-MSHR implementation.

Cacheable hits do not reach the external bus.  Stores update byte-selected L2
data and mark the line dirty.  Dirty replacement writes a whole line before
refill.  A writeback failure preserves the dirty victim and fails every merged
request; a refill failure leaves the destination invalid and likewise fails
the merged requests.  Device or non-cacheable requests bypass allocation but
remain ordered through the same controller.

`FENCE` currently completes only after reaching an otherwise idle controller,
which drains all older traffic in this globally serialized implementation.
LR, SC, and AMO encodings fail explicitly.  They are not degraded into plain
reads and writes.

The data store has one registered 256-bit read port and one byte-enabled
256-bit write port. `L2_BUS_DATA_WIDTH` controls the L2 producer beat and
defaults to that same 256-bit width. Extra controller states serialize SRAM
reads before hits, replay, and writeback. This is a credible macro boundary
rather than an asynchronous 256 KiB mux. The tag/status arrays remain
behavioral and still need banking or explicit macros before physical
implementation; inference alone is not a frequency or area result.

## Shared generic bus boundary

The L2 does not contain AXI or WISHBONE state. Its southbound neutral request
carries:

| Field | Meaning |
| --- | --- |
| `valid/ready` | One accepted external beat. |
| `write` | Read or write selection. |
| `addr` | Physical byte address. |
| `size` | Base-two logarithm of transfer bytes. |
| `burst` | Read-only AXI-LEN-style count: zero is this request only; `N` declares this request plus the next `N` contiguous peer requests. |
| `wdata/wstrb` | Producer-width data and per-byte enables, already lane-positioned. |
| `cacheable` | Transport hint; line traffic is cacheable and bypass traffic is not. |

The response carries producer-width read data and an error bit.
`rtl/bus/genbus_interface.v` is the shared boundary used here and by the
vector streaming cache. `UPSTREAM_DATA_WIDTH` and `DOWNSTREAM_DATA_WIDTH` are
independent. It splits a wide producer transfer over a narrow downstream bus,
places a narrow transfer in the addressed lane of a wider bus, and performs
the inverse read-data assembly. `READ_BUFFER_DEPTH` and
`WRITE_BUFFER_DEPTH` independently size its admission and outstanding state.
Untagged upstream responses are restored to request-acceptance order. AXI
reads and writes may execute concurrently, but a younger request is not issued
past an older opposite-direction request whose byte range overlaps.

The CCX/L2 instance explicitly drives `burst=0`. This disables cross-request
coalescing at that client boundary; it does not disable the AXI burst needed to
split one wide L2 request over a narrower external port.

In the core complex, `L2_BUS_DATA_WIDTH` selects the upstream producer width
(32 through 256 bits) and `BUS_DATA_WIDTH` independently selects the external
width. With the default 256-bit L2 producer, a 64-byte line takes 16, 8, 4, 2,
or 2 downstream beats on 32-, 64-, 128-, 256-, or 512-bit AXI. Because CCX
drives the coalescing count to zero, those are two AXI transactions: each
256-bit L2 request becomes an 8-, 4-, 2-, 1-, or 1-beat transaction. The
512-bit case remains two legal narrow transfers. Scalar bypasses split when
necessary and use addressed byte lanes on wider buses.

`BUS_TYPE` selects `OPENRV64_COMPLEX_BUS_AXI` or
`OPENRV64_COMPLEX_BUS_WISHBONE` at elaboration. `BUS_DATA_WIDTH` accepts 32,
64, 128, 256, or 512 bits for AXI. The official WISHBONE B.4 specification
caps a data port at 64 bits, so that backend accepts 32 or 64 bits; wider
Wishbone would be a nonstandard extension and is rejected.

### AXI4

One neutral request wider than the external port becomes one AXI4 INCR burst,
up to the AXI limit of 256 beats. AW and W may handshake independently. Up to
`READ_BUFFER_DEPTH` reads and `WRITE_BUFFER_DEPTH` writes can be admitted, and
multiple address transactions using the fixed master `AXI_ID` can be
outstanding. AXI's same-ID ordering is therefore part of this interface
contract. R and B IDs must match `AXI_ID`, and non-OKAY responses become CCX
errors.

The optional neutral `burst` count performs explicit read coalescing. A leader
with count `N` reserves room for itself and the next `N` requests; followers
must be contiguous, have the same size/cacheability, and carry count zero.
Genbus emits one larger INCR burst but still returns one upstream response per
neutral request. Each response may cut through as soon as its own beats are
complete rather than waiting for the final AXI `RLAST`. Declared write
coalescing and speculative detection of unrelated adjacent requests are not
implemented. Genbus automatically splits a declared group at the 256-beat AXI
limit and at every 4 KiB boundary.

### WISHBONE B.4

The WISHBONE path uses the same admission buffers, then drains the globally
oldest request. It emits one Classic transfer per genbus beat (`CTI=000`,
`BTE=00`).  It holds `CYC` for the transfer, holds `STB` until the request is
accepted under the B.4 `STALL` rule, and then waits for exactly one of `ACK`,
`ERR`, or `RTY`.  `RTY` inserts an idle cycle and reissues the request;
`WB_MAX_RETRIES` limits retries, with zero meaning no limit.

The WISHBONE specification defines the lower `ADR` boundary from port size and
granularity rather than requiring one universal flat-vector convention.
`WB_ADDR_SHIFT` makes that integration choice explicit.  It defaults to
`clog2(BUS_DATA_WIDTH/8)`, which exports a bus-word address for an 8-bit
granularity port.  Set it to zero for an interconnect whose flat `ADR` vector
expects the complete byte address.  `SEL` always contains byte enables.

The implementation follows the OpenCores WISHBONE Revision B.4 signal and
termination rules: <https://cdn.opencores.org/downloads/wbspec_b4.pdf>.

## L1 and coherence boundary

The shared L2 is correct for direct hart requests when there are no private
cached copies.  It is **not yet coherent with multiple private L1 caches**.
The current L1 has a back-invalidation input, but this L2 does not yet track
sharers or emit invalidations.  Placing it below multiple enabled L1s today can
leave a private clean copy stale after another hart writes the line.

L1 integration therefore still requires a probe/invalidation network with at
least these rules:

1. a store must invalidate other private copies before it becomes visible;
2. an inclusive L2 must invalidate every private copy before replacing a line;
3. an L1 must accept a probe while its own miss is outstanding, or the design
   needs a nonblocking probe queue to avoid eviction/refill deadlock; and
4. LR/SC reservations and AMOs must occupy the same per-line order as ordinary
   requests.

The compatibility hart adapter also applies one constant `DEFAULT_ATTR` to a
whole port.  The core-complex default marks that port cacheable so the top is
useful for a DRAM-only memory aperture.  Do not route MMIO through that default:
an integrated core/L1 endpoint must supply per-request PMA/CCX attributes, or
the MMIO path must bypass the cached port.

## Verification

Focused targets are:

- `make sim-ccx-l2` for fills, hits, writeback, bypass, refill errors, ordered
  same-line merge, and response identity;
- `make sim-ccx-l2-widths` for 32-, 128-, and 256-bit cache paths (the default
  `sim-ccx-l2` target covers 64 bits);
- `make sim-complex-bus-axi` and `make sim-complex-bus-wb` for transport
  backpressure, independent AXI channels, WISHBONE retry, and bus errors;
- `make sim-genbus-axi sim-genbus-wb` for independent read/write buffering,
  wide-request bursts, declared read coalescing, response order, read
  cut-through, and the serialized WISHBONE fallback; and
- `make sim-core-complex-2h-axi sim-core-complex-4h-wb` for generated hart IDs,
  response routing, one-line merging, L2 hits, shared genbus width conversion,
  the explicit zero burst count, and both complete backend paths.
