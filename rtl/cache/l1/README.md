# OpenRV64 L1 cache

`openrv64_l1_cache` is a blocking, physically tagged, set-associative L1 using
the generic OpenRV64 request/completion handshake.  It accepts separate lookup
and physical addresses: tying them together gives PIPT operation, while L1I
uses virtual page-offset bits for its set/beat and the translated address for
its tag and refill.  The L1I wrappers default to four ways, 8 KiB, and 64-byte
lines; the shared cache and L1D retain their eight-way defaults.  `CACHE_BYTES`
accepts power-of-two capacities from 1 KiB through 32 KiB.

## Policy

- read allocate, one 64-bit refill request per line beat;
- registered byte-banked data-array reads for SRAM-friendly inference;
- write-through and no-write-allocate;
- successful write hits update the resident word after lower-memory completion;
- failed refills never validate a partial line;
- round-robin replacement, preferring invalid ways and then retired-path lines
  marked `aged_q`;
- `req_cacheable_i=0` sends a request directly through the cache instance;
- `ENABLE=0` on `openrv64_l1`, `openrv64_l1i`, or `openrv64_l1d` elaborates a
  transparent wire-through path with no tag or data arrays.

The line data arrays contain no dirty state because every store reaches the
lower level before it completes upstream.

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

The cache datapath remains blocking: one lookup is serviced at a time, and a
64-byte miss issues exactly one aligned 512-bit native CCX read
with `size=6` and `burst_len=0`.  The requested 256-bit frontend half is then
selected from the resident 64-byte line.  With L1I enabled, instruction
traffic does not use AXI.  `FENCE.I` invalidates both the L1I and the
three-wide fetcher's bridge lines; an invalidation arriving during a refill is
retained until the L1I can accept it.

L1I has eight best-effort virtual prefetch/aging slots.  Accepting a conditional
branch queues both its direct target and fallthrough, collapses same-line and
already-pending duplicates, and translates each path through the demand-priority
ITLB/PTW/PMP service.  Speculative faults are discarded.  Once the branch
retires, the losing path is marked as a preferred replacement victim; aging
does not invalidate a resident line.  Demand lookup always has priority over
starting another prefetch lookup or fill.

The generic 64-bit frontend is unchanged.  Set `ENABLE_L1I=0` on the 256-bit
AXI top-level path for a direct, single-request cacheless fetch path.

`rtl/openrv64_l1i_top.v` is the standalone integration boundary.  It decouples
the blocking cache completion into separate demand request/response channels,
accepts virtual and translated physical demand addresses, exposes the private
speculative translation service, and presents the read-only native CCX command
and response channels.  The standalone top and testbench parameterize cache
capacity, associativity, and speculative slot count; their defaults are 8 KiB,
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

Write-through stores and uncached accesses use the same native CCX command,
response, and 512-bit write-data channels.  Address and size identify the
sub-line access, and data plus byte enables occupy the addressed lane.  The
command and write-data channels are independently backpressured and correlated
by hart, source, and transaction IDs.

The core bus arbitrates independent I-cache and D-cache command sources and
routes responses by `source_id`; only L1D drives write data.  The current
implementation permits one active cache operation per cache; L1I may retain
up to eight untranslated, translated, or aging jobs behind that port.  It adds
no probes or coherence behavior.  Scalar LSU traffic never uses AXI;
AXI remains only for page-table walks and the `ENABLE_L1I=0` cacheless-fetch
path.
