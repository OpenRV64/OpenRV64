# RLE stream prediction and instruction-stream fetch

Status: experimental, 2026-09-05. The implementation is confined to the AXI
Tomasulo frontend in `rv64_top_3p.v`. Results in this document are managed RTL
simulation or standalone generic FPGA mapping results. They are not routed
timing results and they are not physical-board validation.

## Executive result

The original stream frontend used a sector directory: fetch repeatedly asked
which control instruction, if any, appeared later in each 16-byte sector. That
model did reduce some redirect latency, but it still performed directory work
in proportion to sequential code volume. It was also an awkward match for the
actual prediction problem. What fetch needs is not a sector inventory. It needs
the next control on the current dynamic path and the start of the path after
that control.

The replacement is an RLE-style stream predictor. A table entry is keyed by an
exact stream-start PC and records the halfword distance to the next control,
the control's instruction length and class, its target, and a local two-bit
direction prediction. A hit closes the current FTQ segment and supplies the
successor stream. The predictor immediately looks up that successor without a
new fetch request. This changes directory traffic from roughly one lookup per
sector to one lookup per predicted control.

The first high-hit implementation was not correct. A control could be captured
by the registered decode predictor before a late RLE result installed its FTQ
boundary, then be admitted on the same edge that fetch followed the new RLE
path. The saved fallback path and the actual fetched path disagreed, while the
ROB checkpoint saw no reason to recover. The first architectural divergence
was a loop branch at `0x400014c8`: the checkpoint recorded fallthrough while
fetch continued at the taken target. The fix binds a still-pending control to
the live RLE successor at admission. This case now has its own
`late_path_binds` counter.

After that fix and the bounded future-run block-enqueue change, the final
source-matched warm-four/measure-one Sv39 CoreMark-loop comparison completed in
33,513 cycles at 1.5679 IPC with RLE prediction and nonblocking TAGE refinement,
33,661 cycles at 1.5610 IPC with native RLE prediction, and 35,602 cycles at
1.4759 IPC with stream prediction disabled. RLE therefore saved 2,089 measured
cycles, or 5.87%, in this workload. The optional adapter was 148 cycles faster
than native RLE in this run, which is too small and too workload-specific to
establish that the extra mechanism is worthwhile.

The four-entry RLE output queue is explicitly provisional. It reached occupancy
four and reported 9,334 full-stall cycles in the final enabled run, so it is
active state, not dead scaffolding. That does not prove it is the right state: a full
queue may mean useful predictor lead, duplicated buffering ahead of the FTQ, or
bad rate matching. The implementation and `doc/performance/TODO.md` both mark
it for removal if later occupancy and starvation evidence do not justify it.

## Design goal and boundary

The goal is to keep a three-wide out-of-order backend supplied across control
transfers without placing synchronous predictor latency in decode. The frontend
should:

- represent the predicted instruction path directly rather than as repeated
  block or sector restarts;
- tolerate synchronous BRAM reads by decoupling prediction, block requests,
  and decode presentation;
- request the blocks of known future runs before those runs become active;
- preserve fetched blocks across speculative redirects when their address tags
  remain valid;
- validate every predicted boundary in decode and every direction and target
  in execution;
- carry stable prediction identity across asynchronous frontend work; and
- structurally support two-byte alignment without claiming complete RV64C
  architectural support.

This predictor is not architectural state. A stale, aliased, or incorrectly
trained entry may waste work but must not change program behavior. Decode must
prove that the claimed control PC is a control of the expected length. Normal
branch execution remains authoritative and can squash the younger path.

The integration is intentionally not shared with the compact frontend.
`fetch_3w.v` and its carousel/FAL mechanisms remain the legacy path. The new
`fetch_istream.v`, `stream_btb.v`, and `istream_bp9.v` path is selected only by
the AXI Tomasulo configuration. Some common BP9 interfaces were extended so a
Tomasulo stream-selected path can be represented in predictor context, but the
feature is parameter-disabled for other frontends.

## Why sector scanning was the wrong abstraction

The sector design indexed a 16-byte region plus a starting halfword and found
the earliest known control at or after that position. Fetch then advanced the
scan to another sector or to the predicted target. Even with pipelining, long
basic blocks consumed directory bandwidth despite containing no control. Short
branch-heavy regions could produce bursts of results, while ordinary sequential
code repeatedly proved that another sector contained no branch.

An RLE entry collapses all sequential bytes before a control into one record:

```text
stream start S
    sequential run: S .. C-1
    control:        C .. E-1
    successor:      taken ? T : E
```

The next lookup key is the selected successor. Thus a predicted path becomes a
chain of runs, and a miss terminates the chain at an open sequential segment.
No scan is needed inside a known run. The amount of predictor work follows the
number of controls rather than the number of fetched sectors.

This does not eliminate instruction-block requests. It tells their scheduler
which ranges are on the predicted path. The current fetcher makes up to four
blocks from every closed future FTQ run eligible immediately, clipped at the
exclusive control end. An open tail exposes only its first block until its RLE
answer arrives. Four is a capacity bound, not a claim that longer runs do not
exist: attempting to enqueue an arbitrarily long encoded run into a 16-entry
block buffer would simply evict near-future data.

## RLE predictor organization

`stream_btb.v` contains 256 entries, two ways, and 128 sets. Bit zero is omitted
from keys and targets because instruction addresses are halfword aligned. The
default entry contains:

| Field | Width | Meaning |
|---|---:|---|
| Key tag | 56 | Remaining exact stream-start address bits after set index and bit zero |
| Run | 16 | Halfwords from stream start to control start |
| Class | 3 | Conditional, direct jump/call, indirect jump/call, or return |
| Length | 1 | Two- versus four-byte control |
| Target | 63 | Halfword-aligned target |
| Direction | 2 | Saturating local conditional predictor |

The logical payload is therefore 141 bits per way per set. Payload arrays are
synchronous, reset-free memories carrying Xilinx `ram_style="block"` and Intel
`syn_ramstyle="block_ram"` attributes. Valid and replacement bits are separate
resettable sidecars. Training and lookup are independently pipelined, with
explicit same-address write forwarding to make read/write collision behavior
deterministic without resetting the payload memories.

A conditional entry chooses its target from the high bit of the two-bit local
counter. Unconditional controls always choose the recorded target. The class
is retained for diagnostics and future call/return policy; ordinary decode and
the execution predictor remain the source of architectural branch semantics.

### Training under out-of-order resolution

Training is keyed by the dynamic stream start, not by the resolving control PC.
The top level stores that start in a per-ROB-slot sidecar alongside the dynamic
instruction ID. Matching both slot and ID rejects stale state after squash and
slot reuse.

Several controls from one cold open stream can resolve before the new table
entry becomes useful. Resolution order is not program order. Blind last-writer
wins training therefore leaves the farthest control in the entry, skipping the
actual next control. The table instead implements nearest-control wins:

- an equal run updates direction and target information;
- a shorter run replaces the stored boundary;
- a later run for the same stream start is ignored; and
- a new key inserts or replaces according to the two-way sidecar policy.

The `shorter` and `later_ignored` counters make this behavior visible. The final
source-matched CoreMark run observed 3 shorten events and 11,584 ignored
later controls, demonstrating that this is not a theoretical ordering case.

### Chaining and the provisional response queue

One root request starts an autonomous chain. Each synchronous hit produces a
unique 32-bit prediction token while retaining the root request ID, then starts
the successor lookup. A miss is returned explicitly and ends the chain. Fetch
uses the root ID plus the response's exact stream PC and its own generation to
reject stale or mismatched results.

A four-entry output queue absorbs predictor results when the FTQ cannot accept
another segment. A direct bypass avoids adding a queue cycle when the consumer
is ready. Cancel drops the read result, autonomous-chain state, and queued
responses, but does not erase trained table contents.

The queue is deliberately not defended as permanent architecture. The FTQ is
already the path buffer. Useful evidence for retaining this second queue is a
reduction in FTQ-empty or post-redirect-empty cycles caused by predictor lead.
Occupancy alone is insufficient. The current counters are queue enqueues,
dequeues, full stalls, and maximum occupancy; future experiments should add
queue-age and “head became useful” histograms.

## FTQ, block buffer, and presentation

`fetch_istream.v` has three distinct forms of state:

1. The FTQ holds ordered dynamic stream segments and prediction metadata.
2. The pending table and address-tagged block buffer hold instruction memory
   work independently of FTQ lifetime.
3. A 32-byte presentation skid exposes a contiguous six-halfword prefix to
   decode.

The default FTQ depth is eight. A hit closes the open tail at the exclusive end
of its control and appends the predicted successor. At full occupancy, a head
transfer and tail append may happen on the same edge; the new tail reuses the
old head slot. A directed regression covers this ring-boundary case because an
ordinary pop-side valid clear initially erased the just-appended entry.

Instruction blocks are tagged by full address rather than FTQ slot. A
speculative redirect rebuilds the FTQ but preserves matching block data. A hard
restart, invalidation, or flush applies the stronger cancellation required by
the memory context. Current request priority is active demand, future-run
blocks in FTQ order, then active sequential lookahead. Resident and already
pending addresses are suppressed associatively.

Presentation is raw data. Fetch clips the valid halfword prefix at a predicted
exclusive control end but does not interpret opcodes. Decode reports exactly
how many halfwords it consumed. A control target at the final halfword of a
sector can compose with the next resident sector on the same presentation
edge. A returning block can also bypass directly into presentation instead of
waiting an extra buffer cycle.

## Decode validation and RV64C preparation

`istream_3w.v` discovers instruction lengths. A 32-bit instruction starting at
the last available halfword leaves a two-byte partial parcel for the next
window. The `advance_half` path consumes three halfwords when all three decoded
instructions are compressed, preserving instruction width rather than byte
width.

This is structural preparation, not full RV64C support. Current branch training
still supplies a four-byte length in the top-level integration, and complete
compressed control, link-PC, exception, predictor, and retirement semantics
have not been validated. Required coverage includes mixed 16/32-bit sequences
across block and page boundaries, partial-instruction faults, predicted targets
at bit 1, compressed calls/returns, and redirect cancellation while a parcel is
stashed.

Decode validates a predicted boundary. A mismatch discards the predicted FTQ
suffix and resumes sequentially at the claimed control end. Execution later
validates the actual direction and target through the normal tagged recovery
path. The RLE predictor never removes either check.

## Optional nonblocking TAGE refinement

`istream_bp9.v` observes conditional RLE hits and borrows BP9's direction read
port when decode is not using it. Every RLE result passes directly to the FTQ;
the adapter cannot exert head-of-line backpressure. A one-entry candidate
register holds one denied request, and `busy_skips` counts additional
conditional results lost while that slot is occupied.

The eventual TAGE answer carries the RLE prediction token and control PC. The
current fetcher accepts it only when it confirms the exact path of a future,
unconsumed FTQ entry. A changed-path answer is counted late and left to the
authoritative decode-time prediction. This restriction is intentional. A
future FTQ entry is not proof that no byte from its old successor has crossed
into decode, because chaining and the block buffer run ahead. Safely changing a
path requires an emitted/decoded generation watermark or an equivalent cut.

The adapter therefore refines metadata more than behavior today. In the final
A/B it saved 148 measured cycles: 33,513 enabled versus 33,661 with the adapter
off. It issued only 5,033 reads from 89,924 candidates, skipped 72,372 while
busy, accepted 793 exact-path confirmations, changed no admitted paths, and
counted 4,234 late answers. These totals include warm-up. The small cycle delta
does not justify a larger candidate queue or a replicated TAGE port, especially
while changed-path refinement cannot be consumed safely.

## Correctness failures found during integration

Three failures materially shaped the current design.

First, last-resolving-control training was wrong for an RLE key. Several
branches shared a cold stream start, and the table retained whichever resolved
last rather than the first control in program order. Nearest-control-wins
training fixed the topology.

Second, simultaneous FTQ full pop and append corrupted the ring. The tail
append reused the physical head slot, then the pop logic cleared its valid bit.
The implementation now suppresses that clear when the slot is reused, and the
directed test fills the FTQ and exercises the exact same-edge transaction.

Third, the registered decode predictor could capture a fallback successor one
cycle before the RLE boundary became visible. Fetch then used the live boundary
at admission while prediction bookkeeping used the saved successor. The fix
selects the live RLE successor for a still-matching pending control on the
admission edge. The full warm benchmark passed after this change. The dedicated
counter is required because architectural PASS alone does not quantify how
often the race was exercised.

Earlier code also allowed late TAGE to rewrite a future FTQ suffix. That was
not demonstrably safe: instruction bytes from the old successor could already
have been emitted. Changed-path mutation is now disabled rather than relying on
FTQ position as a false safety proof.

## Experimental method

All cited tests are owned by `run/run` and retain command, configuration,
source hashes, dirty-worktree patch, and output under `run/log/<run-id>/`.
Historical milestones came from evolving dirty snapshots and are not treated
as single-variable comparisons.

The current CoreMark harness executes four warm-up invocations, retires a
`START_TRACE` marker, executes one measured invocation, then retires
`END_TRACE`. `PERF_TEST_REGION` cycles, retired instructions, and IPC cover the
marker interval. Most detailed `PERF_*` counters still accumulate from reset,
so their denominators include warm-up. They support causal comparison only
when harness and source match; they must not be divided by the marker interval
and presented as measured-pass rates.

### Historical predictor and frontend results

The original BP8-to-BP9 single-pass comparison showed why predictor latency had
to move out of decode:

| Predictor | Cycles | Retired | IPC | Direction corrections | Target corrections |
|---|---:|---:|---:|---:|---:|
| BP8 tournament, asynchronous BTB | 43,881 | 52,589 | 1.1984 | 1,433 | 36 |
| BP9 compact TAGE, synchronous BTB | 45,245 | 52,589 | 1.1623 | 887 | 12 |

BP9 substantially improved prediction but was 3.11% slower because its
synchronous lookup was exposed as frontend backpressure. A warm-ten comparison
showed the same mechanism: BP8 took 351,263 cycles at 1.4960 IPC, while BP9 took
360,526 cycles at 1.4576 IPC despite 10,693 versus 1,609 direction corrections.

The best recorded pre-istream run was 328,597 cycles for ten invocations,
1.5992 aggregate IPC, or 32,859.7 cycles per invocation. It used the legacy
carousel/FAL fetch path plus BP9 and then-current backend optimizations. During
the sector-istream bring-up, a historical warm-ten run reached 321,780 cycles
and 1.6331 IPC. That proves the istream architecture can be competitive, but
source drift prevents attributing the difference solely to fetch.

### Final source-matched RLE comparison

The following values use the same RTL snapshot, warm-four marker harness,
payload, simulator, and bounded future-run block-enqueue implementation. Only
the named stream-predictor configuration changes.

| Mode | Measured cycles | Retired | IPC | Direction corrections | Late path binds | Result |
|---|---:|---:|---:|---:|---:|---|
| RLE + nonblocking TAGE | 33,513 | 52,544 | 1.5679 | 2,273 | 40 | PASS |
| Native RLE, adapter off | 33,661 | 52,544 | 1.5610 | 2,303 | 47 | PASS |
| Stream prediction off | 35,602 | 52,544 | 1.4759 | 1,908 | 0 | PASS |

Relative to stream prediction off, the enabled path saves 2,089 cycles
(5.87%) and native RLE saves 1,941 cycles (5.45%). The enabled adapter saves
148 cycles (0.44%) relative to native RLE in this run. Direction corrections
increase with RLE, so reduced execution correction count is not the source of
the speedup. The dominant correlated change is frontend availability: the
enabled run reports 6,712 fetch-empty cycles and 5,734 post-redirect-empty
cycles, versus 14,883 and 14,604 with stream prediction disabled.

For the enabled run, reset-to-end RLE counters were 120,777 lookups, 29,082
roots, 91,695 chained lookups, 118,236 responses, 117,558 hits, 678 misses,
46,066 FTQ transfers, and zero decode boundary rejects. Training recorded
51,440 same-control updates, 68 inserts, 398 replacements, 3 shorter controls,
and 11,584 ignored later controls. The response queue recorded 20,995 enqueues,
15,933 dequeues, 9,334 full stalls, and occupancy four. Stream-context matching
recorded 69,527 binds, 63,493 resolution matches, 62 misses, no invalid keys,
and 40 late-path binds.

The hit count is not a conventional independent-lookup hit rate: autonomous
cycles repeatedly traverse hot loops, and one root can generate many hits.
The 91,695 chained lookups are the direct evidence that work moved from
per-sector requests to per-control path traversal.

### Other workloads and confounds

Current RLE results are not yet available for the earlier memory workload set.
Pre-istream figures establish priorities but cannot be presented as RLE gains:

| Workload/configuration | Cycles | Retired | IPC | Observation |
|---|---:|---:|---:|---|
| memcpy 64 KiB, earlier baseline | 31,293 | 20,523 | 0.6558 | Memory/backend limited |
| memcpy 64 KiB, later trace | 28,290 | 20,529 | 0.7257 | Improved before istream |
| memcpy, SQ4 | 27,342 | 20,529 | 0.7508 | 11,155 LSQ-full cycles |
| memcpy, SQ8 | 34,158 | 20,529 | 0.6010 | More queue capacity hurt under that arbitration |
| STREAM copy | 31,269 | 20,523 | 0.6563 | 1,015 on-time data prefetches |
| STREAM scale | 43,425 | 41,003 | 0.9442 | 1,015 on-time data prefetches |
| STREAM add | 61,868 | 43,056 | 0.6959 | 2,778 late data prefetches |

The SQ4/SQ8 result is a warning against monocausal frontend conclusions.
Backend memory arbitration changed total cycles by more than many fetch
optimizations. The STREAM triad and pointer-chase attempts in the historical
set did not produce valid payload results and remain unsuitable evidence.

## Counters and trace coverage

Implemented RLE groups include:

- root and chained lookups, responses, hits, misses, and way-one hits;
- inserts, replacements, same-control updates, shorter replacements, ignored
  later controls, run overflows, conditional trains, and taken trains;
- response-queue enqueue, dequeue, full-stall, and maximum occupancy;
- stream-context binds, resolution matches, misses, invalid keys, and late path
  binds;
- FTQ predicted transfers and decode rejects; and
- nonblocking TAGE candidates, accepted lookups, responses, busy skips,
  exact-path accepts, path changes, and late responses.

The existing fetch, redirect, post-redirect, BP9, RAS, scheduler, ROB, LSQ, and
memory groups remain necessary. The `openrv64-3p-cycle-v2` CSV trace carries
stable dynamic instruction IDs and overlapping frontend, decode, scheduler,
ROB, and LSU residency. Trace CSVs are compressed with `pbzip2` after the run,
and the analysis reader accepts `.bz2` input.

Still missing are marker-relative snapshots for every detailed group, FTQ
occupancy histograms, per-source instruction-block request counts, RLE
response-to-use age, and explicit global trace rows for predictor/FTQ events
that happen before an instruction has a dynamic ID. These are more useful than
another broad total counter dump.

## FPGA storage and timing status

The table structure is compatible with FPGA block RAM: payload arrays are
synchronous and reset-free; reset affects only validity sidecars; and collision
forwarding is explicit. The current standalone XC7 mapping inferred eight
`RAMB36E1` blocks and no distributed RAM. It reported 3,190 LUT primitives,
2,497 flip-flops, 85 `CARRY4`s, 2,267 estimated logic cells, no latches, and no
structural combinational or latch loops. This is direct evidence that the large
payload tables infer as BRAM.

The cost is not small. Compared with the earlier sector-table standalone map,
the current complete RLE module uses the same eight BRAMs but 1,089 more LUT
primitives and 1,691 more flip-flops. Much of the added registered state is
consistent with the wide four-entry response queue, although a hierarchy
breakdown is required before assigning all of the delta to it. This strengthens
the case for treating that queue as provisional.

Successful RAM inference does not establish timing. The future-run
request selector performs associative resident/pending suppression across a
larger candidate set, and the complete frontend includes FTQ scans, block
selection, and presentation muxes. Standalone mapped depth is not routed WNS.
A full hierarchy synthesis followed by part-specific implementation is needed
before choosing a frequency or increasing table capacity.

The payload is wide because it retains a nearly full tag and target. This
wastes BRAM width but avoids silently reintroducing unsafe aliases. Target
compression, page-relative targets, split tag/target arrays, or set-level upper
bits are reasonable later studies. Enlarging the entry count before measuring
replacement and context behavior is not justified.

## Remaining correctness limits and next experiments

The largest correctness limit is address-space identity. Exact virtual PCs can
alias across address spaces. M-mode steering is currently masked, but general
multi-process S-mode use needs an ASID, VM-generation, privilege qualifier, or
defined invalidation policy. Ignoring this would turn a performance predictor
alias into an excessive and potentially security-relevant speculative reach.

Recommended order:

1. Synthesize the complete istream hierarchy after the successful standalone
   RLE mapping to expose FTQ selection and future-block request cost.
2. Add marker-relative FTQ occupancy, request-source, and queue-age counters.
   Use them to decide whether the provisional four-entry RLE response queue is
   useful or should be deleted.
3. Run current source on memcpy, valid STREAM copy/scale/add payloads, and a
   repaired pointer-chase benchmark. CoreMark alone is inadequate.
4. Add context qualification before broader Sv39/Linux use.
5. Add an emitted/decoded generation cut before allowing TAGE to change an
   already-admitted FTQ path.
6. Complete RV64C architectural semantics and directed boundary/fault tests.
7. Perform routed timing. Do not infer Fmax from generic mapping or simulation.

## Managed evidence

Principal historical and current run directories are recorded under
`run/log/`. The final three source-matched CoreMark runs are:

- `coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-tage-warm4-measure1-20260905T173607Z`
- `coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-tage-warm4-measure1-istream-bp9-off-20260905T173607Z`
- `coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-tage-warm4-measure1-stream-btb-off-20260905T173607Z`

Relevant configurations and directed tests are:

- `run/cfg/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-tage-warm4-measure1.cfg`
- `run/cfg/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-tage-warm4-measure1-istream-bp9-off.cfg`
- `run/cfg/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-tage-warm4-measure1-stream-btb-off.cfg`
- `run/cfg/fetch-stream-btb-directed.cfg`
- `run/cfg/fetch-istream-directed.cfg`
- `run/cfg/fetch-istream-bp9-directed.cfg`
- `run/cfg/bp9-tage-focused.cfg`
- `run/cfg/fpga-xc7k480t-module-stats-stream-btb.cfg`

Implementation files are `rtl/core/fetch/stream_btb.v`,
`rtl/core/fetch/fetch_istream.v`, `rtl/core/fetch/istream_bp9.v`, the Tomasulo
integration in `rtl/core/rv64_top_3p.v`, and performance instrumentation in
`tb/tb_top_3p_soc.v`.
