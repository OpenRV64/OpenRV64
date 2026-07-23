# OpenRV64 L1 cache

`openrv64_l1_cache` is a pipelined, physically tagged, set-associative L1.  Its
request and response channels are decoupled: `req_ready_o` accepts a request,
while `resp_valid_o` returns the ordered result under independent response
backpressure.  It accepts separate lookup and physical addresses: tying them
together gives PIPT operation, while L1I uses virtual page-offset bits for its
set/beat and the translated address for its tag and refill.  The L1I wrappers
default to four ways, 16 KiB, and 64-byte lines; the shared cache and L1D retain
their eight-way module defaults.  The integrated CCX core uses 16 KiB and four
ways for both L1I and L1D.  `L1I_CACHE_BYTES` and `L1D_CACHE_BYTES` expose
those capacities at the core and production top levels.  `CACHE_BYTES`
accepts power-of-two capacities from 1 KiB through 32 KiB.

## Policy

- read allocate, one 64-bit refill request per line beat;
- parallel way reads and tag compare with a registered selected-way response;
- one accepted and one completed resident read hit per cycle after fill;
- ordered one-entry response buffering with arbitrary response backpressure;
- write-through and no-write-allocate;
- successful write hits update the resident word when the lower-memory request
  is accepted; the CCX L1D endpoint may satisfy that acceptance by reserving a
  byte-masked posted-store entry;
- failed refills never validate a partial line;
- round-robin replacement, preferring invalid ways and then retired-path lines
  marked `aged_q`;
- `req_cacheable_i=0` sends a request directly through the cache instance;
- `ENABLE=0` on `openrv64_l1`, `openrv64_l1i`, or `openrv64_l1d` elaborates a
  transparent wire-through path with no tag or data arrays.

The line data arrays contain no dirty state.  With the CCX L1D endpoint, bytes
which have not reached the lower level are owned by the store FIFO rather than
represented as Modified cache lines.

## Physical storage

Each way's data store is one synchronous, full-width, one-read/one-write
inferred RAM.  Store byte enables are merged with the registered resident word
before the full-width write, so synthesis does not split a way into eight
byte-wide memories.  The integrated 16 KiB caches therefore infer:

- L1I: four 64x512-bit RAMs;
- L1D: four 512x64-bit RAMs.

The RAM contents are deliberately not reset; validity metadata suppresses
uninitialized data.  Tags, validity, replacement, aging, and reserved
coherence metadata remain standard-cell logic because the current same-cycle
parallel tag lookup and bulk invalidation contract does not fit a simple
synchronous SRAM without another lookup stage.

The Sky130 resource flow preserves these eight data arrays as `$mem_v2` cells
and reports their 262,144-bit capacity separately.  This repository has no
SRAM Liberty/LEF macro library, so their physical area and timing remain
unknown until a macro generator/library and Yosys memory mapping are selected.
Expanding them into flip-flops is not a valid cache-area estimate.

## Reserved coherence metadata

Each line carries a two-bit `mesi_q` field (`I=00`, `S=01`, `E=10`, `M=11`)
and a configurable `dirty_timestamp_q`.  `WRITEBACK_TIMEOUT_CYCLES` defaults to
128; `DIRTY_TIMESTAMP_WIDTH` therefore defaults to 8 bits, is capped at 16
bits, and may be overridden as long as the timeout fits.  These are stubs for a
later coherence controller: `valid_q` is still authoritative, a successful
refill records `E/0`, and reset, replacement, or invalidation records `I/0`.
The current write-through path never creates `M` or a nonzero dirty timestamp
because its lower-level copy is current when a store completes.

## Inclusion contract

Inclusion is a hierarchy property, not something an L1 can guarantee by
itself.  A lower inclusive cache must hold every line resident in this L1 and
must issue `invalidate_valid_i` before it evicts that line.  It holds the
request until `invalidate_ready_o`; `invalidate_all_i` clears every line and a
deasserted `invalidate_all_i` invalidates the line containing
`invalidate_addr_i`.  Invalidation has priority over a new upstream request.

## Specializations

`l1i/l1i.v` removes requester write inputs.  `l1d/l1d.v` retains the complete
read/write interface.  Both keep the same downstream interface so platforms
can select cached or cacheless builds without changing bus wiring.

## Frontend integration

The 256-bit frontend instantiates `openrv64_l1i_ccx` as a VIPT cache.  A demand
virtual address indexes L1I while the ITLB produces the physical tag and CCX
address; Bare and ITLB-hit launches avoid a serialized translation state.
Translation misses use the shared PTW, and every architectural demand is PMP
checked.  Fetch owns one current 256-bit line plus the immediately following
line needed for boundary-crossing bundles, with only one cache request in
flight.  Cache residency and speculative work belong to L1I.

The cache hit datapath is pipelined; misses, writes, and uncached operations
still serialize the pipeline while they use the blocking lower-memory port.  A
64-byte miss issues exactly one aligned 512-bit native CCX read with `size=6`
and `burst_len=0`.  The requested 256-bit frontend half is then selected from
the resident 64-byte line.  With L1I enabled, instruction traffic does not use
AXI.  `FENCE.I` invalidates both the L1I and the three-wide fetcher's bridge
lines; an invalidation waits until accepted lookups and responses have drained.

L1I has eight best-effort virtual fill/prefetch/aging slots by default.
`FILL_BUFFER_LINES` sets this capacity from two through sixteen;
`PREFETCH_SLOTS` remains an override-compatible alias.  Accepting a conditional
branch queues both its direct target and fallthrough, collapses same-line and
already-pending duplicates, and translates each path through the demand-priority
ITLB/PTW/PMP service.  Speculative faults are discarded.  Once the branch
retires, the losing path is marked as a preferred replacement victim; aging
does not invalidate a resident line.  Demand lookup always has priority over
starting another prefetch lookup or fill.

The generic 64-bit frontend is unchanged.  Set `ENABLE_L1I=0` on the 256-bit
AXI top-level path for a direct, single-request cacheless fetch path.

`rtl/openrv64_l1i_top.v` is the standalone integration boundary.  It accepts
virtual and translated physical demand addresses, exposes the private
speculative translation service, and presents the read-only native CCX command
and response channels.  The standalone top and testbench parameterize cache
capacity, associativity, and speculative slot count; their defaults are 16 KiB,
four ways, and eight slots.  Override them with `L1I_TOP_CACHE_BYTES`,
`L1I_TOP_WAYS`, and `L1I_TOP_PREFETCH_SLOTS` on `make sim-l1i-top`.  The target
builds the current CoreMark-derived binary as 512-bit lines and replays a
checked-in 128-instruction dynamic excerpt through this top twice; every
returned instruction is checked, and the warm replay must issue no CCX fills.

## Data integration

The scalar LSU enters `openrv64_l1d_ccx` only after translation and PMP
checking.  The cache retains its 64-bit internal SRAM/refill datapath, while
the backend converts a cacheable miss into one aligned 512-bit native CCX read
with `size=6` and `burst_len=0`.  It buffers that line and feeds its eight
64-bit words into the shared refill controller; a CPU load returns the selected
64-bit word.

`FILL_BUFFER_LINES` and `STORE_BUFFER_LINES` both default to eight cachelines
and accept values from one through sixteen.  Each L1D store entry contains an
aligned 64-byte address, 512 data bits, and 64 byte enables.  It is deliberately
not a scalar write queue: the addressed 64-bit CPU lane is placed in a native
line record and downstream L2 or memory may perform the masked merge.

A tagged, cacheable, unlocked store completes to the shared L1 after reserving
one FIFO entry.  The resident word is updated on a hit; a miss remains
no-write-allocate.  FIFO order is preserved, and the backend drains each entry
as one aligned CCX write with `size=6` and `burst_len=0`.  The independent
`store_resp_*` channel reports drain completion and error in FIFO order.  The
core bus retains the original LSU tags in a matching FIFO, so a store may retire
at request admission without losing a later asynchronous access fault.

The L1D endpoint also contains a deliberately small address-stream prefetcher.
It trains on accepted cacheable, unlocked loads after aligning them to
64-byte lines.  The first observation predicts the next line.  Two matching
nonzero deltas establish a global signed stride.  `PREFETCH_DISTANCE` is the
initial contiguous read-ahead depth; it does not select one farther line and
leave holes.  Demand catching a queued or outstanding prefetch doubles the
depth, bounded by `PREFETCH_MAX_DISTANCE`.  Two unused speculative
replacements halve it.  `PREFETCH_MAX_STRIDE_LINES` limits eligible deltas and
defaults to 64 lines (4096 bytes).
`PREFETCH_ENABLE=0` removes prefetch issue while retaining the same demand
path.

There is no PC input, table, or LSU predictor state.  The default four-entry
candidate window feeds four prefetch MSHRs.  Prefetch transaction IDs occupy
the upper half of the four-bit L1D ID space, so their responses may return out
of order while the blocking architectural demand/store backend uses the lower
half.  A completed speculative line resides in the existing fill buffers until
demanded; it does not install in the L1 tag or data arrays, so unused prefetches
cannot evict resident cache lines.  `PREFETCH_DEMAND_RESERVE` entries cannot be
consumed by speculative responses.  Demand traffic may use those entries or
replace an unused speculative line.

Demand misses take priority.  A speculative read may pass queued posted stores
only when no buffered store aliases its line.  An aliasing store, invalidation,
or lock transition cancels or discards queued and outstanding speculative
copies.

`prefetch_issued_o`, `prefetch_useful_o`, `prefetch_late_o`, and
`prefetch_dropped_o` are one-cycle event outputs for testbench counters.
`useful` means a completed speculative line supplied a later demand; `late`
means demand reached a queued or outstanding speculative request; `dropped`
means the candidate window was full.  `prefetch_useless_o` reports replacement
of an unused speculative fill, and `prefetch_depth_o` exposes the current
adaptive depth.  They are observability signals, not architectural counters.

The command and write-data channels remain independently backpressured and are
correlated by hart, source, and transaction IDs.  A later blocking read cannot
pass queued stores at the L1D backend, and external invalidation is not
acknowledged until the store FIFO has drained.  `#LOCK` accesses bypass and
invalidate L1D and remain non-posted.  Uncached/device writes also remain
blocking in the current RTL; the intended later policy is ordinary posting
with software responsible for an explicit pre-barrier.  A device write does
not implicitly perform that pre-drain.  A future CSR may request automatic
pre-barrier behavior.

The fill capacities do not imply eight simultaneous architectural misses.  The
shared cache controller and each CCX demand backend still allow one active
demand miss.  L1D separately supports `PREFETCH_OUTSTANDING` speculative MSHRs
with transaction-ID-indexed response matching; the default is four.

`L1I_FILL_BUFFER_LINES`, `L1D_FILL_BUFFER_LINES`, and
`L1D_STORE_BUFFER_LINES` are propagated through the AXI core-bus, three-pipe
core, and production top-level parameters.  The execution pipe defaults to
eight LSU tags, matching the default L1D store FIFO and allowing one hart to
hold eight unacknowledged stores.  Configurations with a deeper store FIFO
still require a larger tag namespace or a separate deferred-fault metadata
queue to use every entry from one hart.

The current one-hart AMO bring-up path adds `req_lock_i`/`ccx_req_lock_o` to
the native L1D endpoint.  Before either marked phase proceeds, L1D invalidates
its resident copy of the addressed line.  The phase then bypasses L1 lookup
and allocation but retains the original cacheable PMA attribute at CCX.  Both
the read and write phases carry the marker.  This prevents a stale L1 hit and
prevents the result from being installed privately while the temporary home
lock is active.

This is self-invalidation for a one-hart serialized AMO, not a snoop protocol.
External invalidation drains the lookup/response pipeline before modifying
tags.  There is still no probe queue, transient-refill poison, directory, or
probe acknowledgement path.

The core bus arbitrates independent I-cache and D-cache command sources and
routes responses by `source_id`; only L1D drives write data.  The L1 arrays are
pipelined, but the present CCX demand adapters still permit one active demand
miss per cache.  Posted L1D writes are the exception: up to the configured
store-buffer capacity may wait behind the active CCX operation.  L1I may retain
up to the configured number of untranslated, translated, or aging jobs behind
its port.  It adds no probes or coherence behavior.  Scalar LSU traffic never
uses AXI;
AXI remains only for the `ENABLE_L1I=0` cacheless-fetch path. Page-table walks
use native CCX and identify their memory object with `kind=PTE`.
