# OpenRV64 L1 cache

`openrv64_l1_cache` is a blocking, physically addressed, set-associative L1
using the generic 64-bit OpenRV64 request/completion handshake.  The checked-in
wrappers default to eight ways, 8 KiB, and 64-byte lines.  `CACHE_BYTES` accepts
power-of-two capacities from 1 KiB through 32 KiB.

## Policy

- read allocate, one 64-bit refill request per line beat;
- registered byte-banked data-array reads for SRAM-friendly inference;
- write-through and no-write-allocate;
- successful write hits update the resident word after lower-memory completion;
- failed refills never validate a partial line;
- round-robin replacement, preferring invalid ways;
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
