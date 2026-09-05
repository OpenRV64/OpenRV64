# Istream and BTB-driven fetch experiment

Status: experimental, 2026-09-05.  The current implementation is integrated
only into the AXI Tomasulo frontend.  Results below are simulation results from
managed runs, not FPGA timing or full physical validation.

## Executive result

The experiment replaced the Tomasulo core's legacy block-oriented fetch policy
with an instruction-stream frontend.  Instead of treating a predicted branch as
a late restart, the new frontend builds a queue of stream segments.  A stream
BTB describes the next control instruction in each segment and its predicted
successor.  Fetch can therefore obtain the current segment and begin the next
one without waiting for the current control instruction to reach decode.

That design is working and is not intrinsically slower than the old frontend.
The best pre-istream CoreMark loop result was 328,597 cycles for ten invocations,
or 32,859.7 cycles per invocation and 1.5992 aggregate IPC.  During istream
bring-up, the best warm-ten result reached 321,780 cycles and 1.6331 IPC.  Those
two runs were made from evolving dirty source snapshots, so the 2.07% cycle
improvement is evidence that the architecture can outperform `fetch_3w`, not a
controlled attribution of the gain to a particular change.

The current controlled result is clearer.  With four warm-up invocations and
one marker-delimited measurement, native stream-BTB direction selection took
34,687 cycles at 1.5148 IPC.  Adding the current early-BP9 adapter increased the
measurement to 35,494 cycles at 1.4804 IPC, despite reducing accumulated
direction corrections from 2,332 to 2,041.  The adapter serializes conditional
stream-BTB responses behind a shared BP9 read port: only 5,418 of 26,710
candidate events started a lookup, while stream transfers fell from 31,393 to
1,786.  The 807-cycle regression is therefore a frontend scheduling error, not
evidence against BTB-driven fetch or TAGE accuracy.

The immediate design decision should be:

1. Admit native stream-BTB results without waiting for TAGE.
2. Launch an observational TAGE request in parallel when the predictor port is
   available.
3. Patch an unconsumed FTQ segment if the TAGE result arrives in time.
4. Fall back to the existing decode-side correction if it arrives too late.

Do not enlarge the stream BTB yet.  CoreMark recorded no replacements in the
current 256-entry table, while the standalone mapping already consumes eight
`RAMB36E1` blocks.  Capacity is not the demonstrated bottleneck.

## Goal and design boundary

The goal is to keep the instruction side ahead of a three-wide out-of-order
backend without turning every control transfer into an instruction-cache
restart.  The frontend should:

- maintain a continuous byte stream across predicted controls;
- discover the next control target early enough to overlap target fetch;
- tolerate synchronous BRAM lookup latency rather than adding it to decode;
- preserve precise correction at decode and execution;
- support instruction lengths of two and four bytes structurally;
- keep fetched blocks reusable across redirects when their addresses still
  match; and
- remain isolated from the compact legacy frontend.

This is not yet a complete RV64C implementation, a context-safe virtual-address
BTB, or a physical FPGA result.  It also does not make branch prediction
architectural.  Decode must verify that a predicted boundary is really a
control instruction, and execution remains responsible for resolving the
actual direction and target.

The current integration boundary is deliberate.  `rv64_top_3p.v` instantiates
the istream path only for the AXI Tomasulo configuration.  The non-Tomasulo and
legacy paths continue to use `fetch_3w.v`.  The controls
`ENABLE_STREAM_BTB` and `ENABLE_ISTREAM_BP9` are useful experiment switches,
but the intended Tomasulo frontend is `fetch_istream.v`; this is not a proposal
to grow another permanent family of fetch modes.

## Why the legacy frontend stopped scaling

`fetch_3w.v` was built as a compact latency-hiding frontend.  It has a
four-entry direct-mapped carousel of 128-byte blocks, plus redirect and fetch
alternate-line state.  Branch hints can fetch both sides and preserve an
alternate path in the FAL.  This is effective for a smaller core because a
branch prediction is treated as a controlled restart into data that may
already have been staged.

For the Tomasulo backend, that structure has the wrong center of gravity.  It
tracks blocks and restart cases rather than the sequence of predicted
instructions.  As backend IPC rises, even a short gap between a predicted
control and presentation of its target becomes visible as an empty scheduler.
Adding more alternate-path cases to the carousel makes ownership and
half-line behavior harder to reason about without changing that basic model.

The new frontend instead makes predicted stream topology explicit.  An FTQ
entry is a segment beginning at a PC and ending either at a predicted control
boundary or at an open sequential frontier.  A stream-BTB hit closes the
segment at the exclusive end of the control instruction and appends the chosen
successor.  Decode consumes bytes through the control, but never sees the
sequential suffix beyond a taken boundary.

## Current architecture

The current data and prediction paths are:

```text
                       +----------------------+
sector PC ------------>| 256-entry stream BTB |---- next control + successor
                       +----------+-----------+
                                  |
                                  v
redirect/restart ---> FTQ segments and generation ----> block requests
                                  |                           |
                                  v                           v
                         presentation skid <------ address-tagged blocks
                                  |
                         raw six-halfword prefix
                                  |
                                  v
                         istream_3w / decode
                                  |
                 validate boundary; correct prediction
                                  |
                         dispatch / scheduler
```

### Fetch stream and block storage

`fetch_istream.v` presents a raw contiguous prefix of six halfwords, sufficient
for three 32-bit instructions or three compressed instructions.  Its default
configuration contains an eight-entry FTQ, eight pending requests, sixteen
address-tagged block-buffer entries, four blocks of sequential lookahead, and
eight 16-byte sectors of predictor horizon.  A 32-byte presentation skid
decouples the raw stream from downstream holds.

The block buffer is deliberately independent of FTQ lifetime.  A redirect
rebuilds predicted stream state but does not discard address-tagged instruction
data that is still valid.  A corrected target can therefore reuse a block that
was fetched on a discarded path.  Flush and invalidation still remove content
when architectural or memory-system correctness requires it.

The BTB scan is pipelined independently from instruction-data arrival.  One
lookup is outstanding at a time, identified by a 32-bit request ID, FTQ slot,
and generation.  Late responses from discarded generations are ignored.  The
response and next lookup can overlap, and a hit may chain directly when it
closes the only FTQ entry.  Same-edge block-response bypass and an immediately
following-sector append avoid avoidable buffer and sector-boundary bubbles.

Request priority is current demand, a future FTQ target start, then sequential
lookahead.  This policy is plausible but not yet demonstrated optimal; FTQ and
request-source occupancy counters are needed before tuning it.

### Stream BTB

`stream_btb.v` contains 256 entries organized as two ways and 128 sets.  The
lookup key is a 16-byte sector plus a starting halfword.  It finds the earliest
known control at or after that position.  Two ways allow two controls in one
sector as well as ordinary set conflicts.

Each payload is 128 bits: a full 60-bit sector tag, a three-bit halfword offset,
conditional and instruction-length bits, and a 63-bit target.  The payload
arrays are synchronous, reset-free memories with Xilinx and Intel block-RAM
attributes.  Validity and replacement state are separate resettable sidecars.
Training uses explicit collision forwarding so read/write behavior is
deterministic while retaining RAM inference.

The native conditional policy is backward-taken/forward-not-taken.  Direct and
unconditional controls select their recorded targets.  This directory is
separate from the execution predictor's exact-PC indirect-target BTB.  It says
where the next control is in a stream and supplies a likely successor; it is not
a replacement for resolved predictor training.

The full sector tag eliminates the earlier low-tag M/S alias observed during
bring-up.  It does not solve address-space aliasing: identical virtual PCs in
different S-mode address spaces can still share an entry.  M-mode stream
steering is currently masked, but an ASID/VM-generation/privilege tag or a
defined invalidation policy is required before this can be considered safe for
general multi-address-space execution.

### Decode and variable-length preparation

`istream_3w.v` discovers instruction boundaries after fetch.  If a 32-bit
instruction begins at the final halfword of a presented window, it holds that
lower parcel and combines it with the next halfword.  Its `advance_half` path
can consume three compressed instructions using three halfwords, preserving
three-instruction decode width instead of wasting half the lanes.

This is preparation for RV64C, not RV64C enablement.  The architectural decoder,
fallthrough-PC handling, branch/RAS link semantics, and training path still
need complete length awareness.  The current top-level boundary acceptance
explicitly requires `control_end_pc == pc + 4`, and training currently marks
controls as 32-bit.  Claims that compressed instructions are supported would
therefore be false.  Required directed tests include 16/32-bit mixtures across
sector, block, page, redirect, and fault boundaries.

### BP9 early-direction adapter

`istream_bp9.v` attempts to replace native BTFNT on conditional stream-BTB hits
with a TAGE direction before admitting the BTB result.  Misses and
unconditional hits pass through.  The lookup is observational: it does not
allocate predictor context, update speculative history, touch the RAS, or
create a training record.  Decode remains the authoritative predictor client.

The architectural idea is sound; the present scheduling is not.  Decode and
the adapter share one BP9 read port, with decode having priority.  The adapter
holds the entire conditional BTB response while waiting for a request and then
for the synchronous answer.  A direction refinement has therefore become a
head-of-line barrier on discovery of future stream segments.

The branch should eventually carry a small predictor context handle so
resolution can train the same prediction state that supplied it.  That is
separate from the early observational request.  It does not justify blocking
FTQ construction while waiting for the handle or direction.

## Experimental method and limitations

All cited runs are managed under `run/log/<run-id>/` and retain their effective
configuration, Git head, dirty-worktree patch, source-input hashes, and result
log.  Runs from different dirty snapshots are historical milestones, not
source-matched A/B tests.

The latest harness warms CoreMark for either four or nine invocations, retires
a `START_TRACE` marker, executes one measured invocation, then retires an
`END_TRACE` marker.  `PERF_TEST_REGION` cycles, retired instructions, and IPC
cover exactly that marker interval.  The detailed `PERF_*` counters currently
accumulate from reset through the end of the run.  Consequently:

- measured cycles can be compared between warm-four and warm-nine runs;
- detailed counters can only be compared directly when warm-up counts match;
- accumulated counter deltas cannot be divided by the measured interval and
  described as a measured-pass rate; and
- trace residency counts overlap by design and must not be summed into cycles.

The measured invocation also occurs at a different outer-loop state when the
warm-up count changes.  Warm-four versus warm-nine is therefore a useful
stability check, not a perfectly identical input experiment.

## Performance history

### BP8 to BP9: why prediction had to move earlier

The initial source-matched single-pass comparison showed the core problem.

| Predictor | Cycles | Retired | IPC | Direction corrections | Target corrections |
|---|---:|---:|---:|---:|---:|
| BP8 tournament, asynchronous BTB | 43,881 | 52,589 | 1.1984 | 1,433 | 36 |
| BP9 compact TAGE, synchronous BTB | 45,245 | 52,589 | 1.1623 | 887 | 12 |

BP9 reduced direction corrections by 38.1% and target corrections by 66.7%,
but cost 1,364 cycles, or 3.11%.  Its direction memories and target BTB infer
BRAM, so the lookup cannot remain a combinational decode operation.  The
latency was exposed as decode backpressure.

A later matched warm-ten comparison repeated the same pattern at higher IPC.

| Mode | Cycles | IPC | Direction corrections | Fetch empty | Fetch held |
|---|---:|---:|---:|---:|---:|
| BP8 | 351,263 | 1.4960 | 10,693 | 48,621 | 19,405 |
| BP9 | 360,526 | 1.4576 | 1,609 | 41,038 | 74,191 |

BP9 was 9,263 cycles slower even though it removed most corrections.  The
54,786 additional held cycles identify latency/flow control, not predictor
quality, as the first-order issue.  This led first to decode-side early
prediction and then to launching stream prediction before decode.

BP9 itself is a 2,048-entry base predictor plus four 512-entry tagged tables
with 4/12/32/96-bit histories and 8/9/10/11-bit tags.  The standalone generic
XC7 mapping inferred eight `RAMB18E1` blocks and reported 24,095 LUTs and 14,908
flip-flops.  That is mapping evidence only; no routed timing or Fmax was
measured.

### Best legacy frontend baseline

The best recorded pre-istream run is:

`coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-tage-warm10-20260905T041929Z`

| Cycles, ten invocations | Retired | Aggregate IPC | Mean cycles/invocation |
|---:|---:|---:|---:|
| 328,597 | 525,494 | 1.5992 | 32,859.7 |

Selected accumulated counters were 300 direction corrections, zero target
corrections, 7,314/7,314 RAS hits, 40,635 fetch-empty cycles, 41,848 held
cycles, 69,692 redirects, 35,467 post-redirect-empty cycles, 2,993 LSQ-full
cycles, and two memory violations.  This configuration used the legacy
carousel/FAL fetch path, BP9, completion forwarding, ALU chaining, the load
conflict record, and fusion.  “Non-BTB-driven fetch” here means the new stream
directory did not drive fetch; the execution predictor still had its ordinary
BTB for indirect targets.

### Istream bring-up milestones

These warm-ten runs came from evolving snapshots.  They record progress but do
not isolate individual RTL changes.

| Run suffix | Cycles | IPC | Fetch empty | Post-redirect empty | Stream transfers |
|---|---:|---:|---:|---:|---:|
| `T084716Z` | 385,047 | 1.3648 | 85,446 | 73,009 | 30,112 |
| `T090316Z` | 354,778 | 1.4812 | 44,006 | 31,114 | 25,042 |
| `T091742Z` | 329,258 | 1.5960 | 31,267 | 30,341 | 12,495 |
| `T095518Z` | 322,656 | 1.6287 | 23,759 | 18,441 | 47,220 |
| `T100240Z` | 321,780 | 1.6331 | 20,822 | 17,025 | 66,411 |

The improvements include pipelined directory scanning, response-to-presentation
bypass, and adjacent-sector handling.  The table does not prove how much each
change contributed.  The last row is 6,817 cycles faster than the historical
legacy baseline, but later backend defaults changed; it must not be compared to
the current 34--36K marker interval as a pure frontend delta.

### Current controlled BP9-adapter A/B

The most diagnostic comparison uses the same warm-four harness and current
source, differing only in whether conditional stream-BTB hits wait for early
BP9.

| Counter | Native stream BTB | Blocking early BP9 | Delta |
|---|---:|---:|---:|
| Measured cycles | 34,687 | 35,494 | +807 (+2.33%) |
| Measured IPC | 1.5148 | 1.4804 | -0.0344 |
| Direction corrections | 2,332 | 2,041 | -291 |
| Stream-BTB lookups | 129,396 | 72,746 | -56,650 |
| Stream-BTB hits | 68,823 | 36,509 | -32,314 |
| Stream transfers | 31,393 | 1,786 | -29,607 (-94.3%) |
| Stream-TAGE candidates | 0 | 26,710 | +26,710 |
| Stream-TAGE accepted lookups | 0 | 5,418 | +5,418 |
| Fetch empty | 10,819 | 13,919 | +3,100 |
| Fetch held | 28,469 | 30,298 | +1,829 |
| Predictor-stall cycles | 0 | 767 | +767 |
| Post-redirect empty | 8,607 | 13,616 | +5,009 |

Only 20.3% of early-TAGE candidates obtained the shared predictor port.  More
accurate direction prediction cannot compensate for stopping stream discovery
behind the other 79.7%.  The counters overlap, so they cannot be added to
explain exactly 807 cycles, but direction, transfer, and stall counters all
support the same mechanism.

### Current full-disable comparison

A warm-nine pair compared the combined stream-BTB plus blocking adapter with a
behavioral full-disable mode.

| Counter | Stream BTB + adapter | Stream BTB disabled |
|---|---:|---:|
| Measured cycles | 35,503 | 35,658 |
| Measured IPC | 1.4800 | 1.4736 |
| Direction corrections | 3,864 | 3,648 |
| Stream lookups | 144,507 | 277,602 |
| Stream hits | 72,612 | 0 |
| Stream transfers | 3,552 | 0 |
| Early-TAGE candidates/lookups | 53,104 / 10,812 | 0 / 0 |
| Fetch empty | 26,957 | 28,900 |
| Fetch held | 59,680 | 60,468 |
| Predictor-stall cycles | 1,528 | 0 |
| Post-redirect empty | 26,493 | 28,486 |

The combined path wins by only 155 cycles, or 0.44%.  This does not contradict
the warm-four result: native stream steering is useful, while the adapter gives
most of that gain back.  The disabled implementation still performs
synchronous directory transactions with hits and training masked, preserving
pipeline timing for the A/B.  It is not proof of the area or timing obtained by
physically removing the stream BTB.

The marker-window traces contain 74,568 dynamic IDs and 1,276,377 rows with the
combined path, versus 74,719 IDs and 1,275,414 rows disabled.  Dominant
residencies are similar: about 388K `ROB_INCOMPLETE`, 177K `ROB_ORDER`, 128K
`SRC1`, 22.6K `FRONTEND_CONTROL`, and 17.3K `DECODE_DOWNSTREAM` rows.  The trace
does not directly represent the adapter's pre-instruction wait: no dynamic
instruction exists yet for a speculative sector query.  That is why global
frontend event records and counters remain necessary.

### Other workloads and backend confounds

The current istream has not yet been validated across the earlier workload
set.  Pre-istream results establish scope, not a current frontend comparison.

| Workload/configuration | Cycles | Retired | IPC | Relevant observation |
|---|---:|---:|---:|---|
| memcpy 64 KiB, earlier baseline | 31,293 | 20,523 | 0.6558 | Memory/backend limited |
| memcpy 64 KiB, later trace | 28,290 | 20,529 | 0.7257 | Improved before istream |
| memcpy, SQ4 | 27,342 | 20,529 | 0.7508 | 11,155 LSQ-full cycles |
| memcpy, SQ8 | 34,158 | 20,529 | 0.6010 | 20,966 LSQ-full cycles |
| STREAM copy | 31,269 | 20,523 | 0.6563 | 1,015 on-time prefetches |
| STREAM scale | 43,425 | 41,003 | 0.9442 | 1,015 on-time prefetches |
| STREAM add | 61,868 | 43,056 | 0.6959 | 2,778 late prefetches |

The controlled SQ4/SQ8 result is particularly important: adding store-queue
capacity made memcpy 24.9% slower under the then-current load/store arbitration.
This prevents careless attribution of all cycle movement to fetch.  The STREAM
triad run retired only 75 instructions and did not exercise the intended
payload, so it is excluded as performance evidence.  Both recorded pointer-
chase attempts terminated with simulator errors and provide no valid result.
Current istream measurements are still needed for memcpy, STREAM, and a repaired
pointer-chase test.

## Counter inventory and required additions

The existing counters are useful but not sufficient to tune the frontend.
Current groups include:

- `PERF_ICX_L2_STREAM_BTB`: lookups, responses, hits, misses, way-one hits,
  training updates/inserts/replacements, same-sector second entries and
  overflows, transfers, and decode rejects;
- `PERF_ICX_L2_STREAM_TAGE`: candidates, accepted lookups, responses, and taken
  responses;
- `PERF_ICX_L2_FETCH`: empty, held, request wait, control empty, refill wait,
  no-line, predictor stall, and other empty cycles;
- redirect, post-redirect, execution-BTB, TAGE, RAS, scheduler, ROB, LSQ, and
  memory-system groups; and
- the `openrv64-3p-cycle-v2` trace with stable dynamic IDs, simultaneous
  fetch/decode/scheduler/ROB/LSU residency, and explicit block causes.

The next counter change should add the following.  These are proposed counters,
not implemented by this document.

| Group | Counters | Question answered |
|---|---|---|
| Marker deltas | Snapshot every detailed group at `START_TRACE`; print delta at `END_TRACE` | What happened in the measured invocation rather than during all warm-up? |
| FTQ occupancy | Cycles at occupancy 0 through 8; full/empty; segment append, consume, correction drop, generation drop | Is prediction, request capacity, or decode consumption limiting stream depth? |
| BTB result disposition | Miss; useful hit; hit behind scan PC; no FTQ room; stale generation; late response; invalid boundary; response-to-transfer latency histogram | Why does a lookup not become a transferred segment? |
| Adapter state | Cycles waiting for predictor port, lookup response, fetch acceptance, or cancellation; decode port denials; conditional response held | How much head-of-line delay is specifically created by early TAGE? |
| Adapter latency | Candidate-to-request, request-to-response, response-to-FTQ-patch histograms; patch-on-time and patch-too-late | Can nonblocking TAGE refine a segment before it is consumed? |
| Presentation | Current sector absent, successor absent, partial first/second sector, pending block response, skid full, downstream hold | Why was a three-wide prefix unavailable? |
| Prediction quality | Native BTFNT correct, early TAGE correct, stream successor correct; wrong direction, target, boundary, and control class separately | Is more predictor sophistication worth its latency and area? |
| Context safety | Hits/training/rejects by privilege and VM generation; context-flush events | Are stale virtual-address entries being used across address spaces? |

Counters should be 64-bit or saturating in long simulations.  Most should live
in the testbench/performance instrumentation and be compiled out of the
synthesized datapath by default.  Histograms should use small fixed buckets,
not per-PC arrays.  The event trace should also gain global frontend rows for
BTB requests, responses, FTQ mutations, and predictor patch attempts.  A purely
per-instruction trace cannot explain work performed before an instruction has
been fetched or assigned a dynamic ID.

Derived metrics should be printed alongside raw counts, but never replace
them.  At minimum:

```text
stream_hit_rate       = useful_hits / responses
stream_transfer_rate  = transfers / useful_hits
tage_accept_rate      = accepted_lookups / candidates
tage_patch_rate       = on_time_patches / responses
ftq_starve_rate       = ftq_empty_cycles / marker_cycles
presentation_rate     = accepted_instruction_slots / available_decode_slots
```

Each denominator must be zero-safe and marker-relative.  Current reports mix a
marker-relative cycle result with reset-to-end detailed counts; fixing that is
higher priority than adding dozens of new totals.

## FPGA cost and timing status

The stream BTB was mapped standalone for generic Xilinx 7-series primitives in
`fpga-xc7k480t-module-stats-stream-btb-20260905T082402Z`.  It inferred eight
`RAMB36E1` blocks, no distributed RAM, 2,101 LUT primitives, 806 flip-flops, 34
`CARRY4`s, and no latches or reported combinational loops.  The longest mapped
topological path was 58 cells.

That is not a physical timing result.  There is no placement, routing, WNS, or
Fmax measurement.  It also exposes a cost problem: the 128-bit payload width
uses eight 36-Kibit blocks even though the logical table holds about 4 KiB of
payload.  The full tag and target make the directory robust but wide.  Before
increasing entry count, investigate whether target compression or a split
tag/target organization reduces BRAM width without reintroducing unsafe alias
behavior.  The block buffer and associative presentation logic also need
whole-frontend synthesis; successful stream-BTB RAM inference says nothing
about the physical cost of those structures.

## Conclusions and next experiments

The stream frontend is viable and has already crossed the legacy result in a
historical warm-ten run.  The current problem is narrower: early TAGE is placed
on the critical admission path and contends with authoritative decode lookups.
It should be made a nonblocking refinement.

Recommended order:

1. Add marker-relative counter snapshots and adapter/FTQ disposition counters.
2. Change early TAGE to patch an existing, unconsumed FTQ segment; never hold a
   native BTB result for it.
3. Repeat the warm-four native, nonblocking-TAGE, and full-disable A/B from the
   same source snapshot, with a marker-window trace for each.
4. Run current istream configurations on memcpy, STREAM copy/scale/add, and a
   fixed pointer-chase benchmark.  Fetch improvements that only help CoreMark
   are insufficient.
5. Add address-space/privilege qualification or explicit invalidation before
   multi-process Linux use.
6. Complete RV64C semantics and directed boundary tests before enabling
   compressed code.
7. Synthesize the complete istream frontend and then perform a part-specific
   routed build.  Do not infer Fmax from standalone cell depth.

A replicated or dual-read TAGE could eliminate port denial, but it spends area
and still leaves lookup latency on the admission path.  It is not the first
fix.  Likewise, a larger stream BTB is unjustified by the current zero-
replacement CoreMark result.  The next useful work is removing serialization
and measuring where FTQ depth is actually lost.

## Managed evidence

Primary run directories:

- `run/log/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-tage-warm10-20260905T041929Z`
- `run/log/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-tage-warm10-20260904T060141Z`
- `run/log/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-alu-chain-warm10-20260904T060449Z`
- `run/log/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-tage-warm4-measure1-istream-bp9-off-20260905T131314Z`
- `run/log/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-tage-warm4-measure1-trace-20260905T132112Z`
- `run/log/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-tage-warm9-measure1-trace-20260905T133102Z`
- `run/log/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-tage-warm9-measure1-stream-btb-off-trace-20260905T134107Z`
- `run/log/fpga-xc7k480t-module-stats-stream-btb-20260905T082402Z`
- `run/log/fetch-istream-directed-20260905T100655Z`
- `run/log/fetch-stream-btb-directed-20260905T115911Z`
- `run/log/fetch-istream-bp9-directed-20260905T131600Z`
- `run/log/bp9-tage-focused-20260905T121132Z`

Related implementation and background documents:

- `rtl/core/fetch/fetch_istream.v`
- `rtl/core/fetch/istream_3w.v`
- `rtl/core/fetch/stream_btb.v`
- `rtl/core/fetch/istream_bp9.v`
- `rtl/core/rv64_top_3p.v`
- `doc/performance/bp-results.md`
- `doc/issues/ras-btb-regression.md`
- `doc/tomasulo_pipeline_trace.md`
