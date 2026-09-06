# Performance TODO

## Provisional stream-RLE output queue

- [ ] Re-evaluate the four-entry output queue between the stream-start RLE
      predictor and the instruction-stream FTQ.  The FTQ is already the
      architectural buffering point; this second queue is justified only if
      autonomous successor chaining measurably runs ahead while FTQ admission
      is paused.  Keep queue occupancy, enqueue/dequeue, and full-stall
      counters through the RLE experiments.  Remove the queue and retain only
      the single synchronous-result bypass if the warm benchmark traces do not
      show useful occupancy or avoided fetch starvation.

  Current evidence (2026-09-05): the final source-matched warm-four CoreMark run
  hit occupancy four and counted 9,334 full-stall cycles, so the queue is active.
  The standalone RLE module maps to eight RAMB36E1s, 3,190 LUT primitives, and
  2,497 flip-flops; the earlier queue-free sector module used the same BRAM
  count but 2,101 LUTs and 806 flip-flops.  This delta is not a queue-only
  attribution, but it makes a queue-bypass or queue-removal A/B mandatory.

## Conservative store-guard relaxation

The compact four-load/four-store LSU currently uses folded cache-line hashes
for store guards.  A younger cacheable load is blocked when an older store has
not translated yet or when its hash matches the load.  Hash collisions are
deliberately conservative.  The aggregate guard stall is measurable, but the
current counters do not distinguish unresolved stores, true same-line matches,
and false hash collisions.

Observed with `coremark-sv39-linux-rd32-ddr3`:

| Counter | Older four-load run | Compact guarded LSQ | Delta |
|---|---:|---:|---:|
| Total cycles | 46,523 | 47,439 | +916 |
| Load dependency cycles | 0 | 855 | +855 |
| L1D load-response wait | 883 | 1,004 | +121 |
| Load allocation/full wait | 18 | 136 | +118 |

The counters overlap and therefore must not be added.  The runs also contain
substantial RTL source drift, so this is attribution evidence rather than a
strict single-variable A/B result.  The identical memory-traffic counts and
zero translation-wait cycles nevertheless point at conservative store-guard
blocking as the dominant remaining LSQ regression.  They do not establish
that hash collisions are the dominant guard-block cause.

Proposed relaxation:

- First add separate counters for unresolved-store, true-line-match, and
  false-hash-collision blocking.  Do not change the guard based only on the
  aggregate dependency counter.
- Keep load translation independent of store guards.
- Use the hash as a cheap first-stage rejection test.
- On a hash match, perform a slower exact physical cache-line comparison and
  release false collisions.  The comparison may take extra cycles.
- Continue blocking behind an older store whose physical address is unresolved.
- Continue blocking true same-line conflicts until the store drains because
  the compact LSU has no store-to-load forwarding matrix.
- Continue ordering device/uncached loads behind every older store, and retain
  the existing atomic and fault conservatism.

Validation requirements:

- A directed forced-hash-collision test must show that different physical
  cache lines eventually pass.
- Same-line loads, unresolved-store loads, device reads, and atomics must
  remain blocked where required.
- Re-run the exact Sv39/RD32/DDR3 micro-CoreMark profile and report dependency,
  allocation-full, L1D-wait, and total-cycle counters.
- Re-map `openrv64_lsq` and `openrv64_exec_lsu` to XC7 primitives; report area
  and structural depth separately from routed timing.

Reference runs:

- `coremark-sv39-linux-rd32-ddr3-20260823T074114Z`
- `coremark-sv39-linux-rd32-ddr3-20260827T032517Z`
