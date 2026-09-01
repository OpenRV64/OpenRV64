# Banked GPR experiments

This is the running measurement log for banked-GPR changes.  The parity track
uses the compact CoreMark-derived loop in `sw/coremark_loop.c` under Sv39,
through the current L1, ICX, L2, GenBus, and timed-DDR3 platform.  The earlier
bare-physical matrix is retained below as a secondary controlled experiment.
Neither workload is the official EEMBC CoreMark benchmark and neither
produces a reportable CoreMark score.

## Sv39 RD32 parity track

The 2026-08-31 matched banked comparison holds the entire core and platform
configuration fixed across its three banked rows: two 16-entry banks with two
physical read ports and one write port per bank, BP8, mode 3, confidence gate
enabled, pair-stack depth 2, strict WAW/RAW handling, no branch forwarding,
no issue/speculation window, retirement depth 32, and timed DDR3.  The
forwarding mask progresses from 0, to 3 for live EX0/EX1 results, to 7 for
live EX0/EX1 plus registered load-only MEM0 results.

| Configuration | Cycles | Retired | IPC | Versus banked 2R1W control | Versus current normal 3P |
|---|---:|---:|---:|---:|---:|
| Current normal 3P RD32 reference | 47,439 | 52,592 | 1.1086 | not configuration-matched | baseline |
| Banked 2R1W, no forwarding | 187,302 | 52,589 | 0.2808 | baseline | 3.948x cycles |
| Banked 2R1W, EX0/EX1 forwarding | **160,297** | 52,589 | **0.3281** | **-27,005 (-14.42%)** | 3.379x cycles |
| Banked 2R1W, EX0/EX1 + load-only MEM0 forwarding | **123,621** | 52,589 | **0.4254** | **-63,681 (-34.00%)** | 2.606x cycles |
| Above plus write-busy release on ack | **116,383** | 52,589 | **0.4519** | **-70,919 (-37.86%)** | 2.453x cycles |

All five runs passed the checksum, Sv39/S-mode, alias, PTW, and timed-memory
requirements:

- normal RD32: `coremark-sv39-linux-rd32-ddr3-20260831T202101Z`;
- banked 2R1W control:
  `coremark-sv39-3p-banked-2r1w-ddr3-20260831T202101Z`;
- banked 2R1W plus EXU forwarding:
  `coremark-sv39-3p-banked-2r1w-exu-forward-ddr3-20260831T202101Z`;
- banked 2R1W plus EXU and load-only MEM0 forwarding:
  `coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260831T220841Z`;
- above plus write-busy release on write ack:
  `coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260831T221634Z`.

The normal row is a parity target, not an isolated register-file comparison.
It already enables branch forwarding, relaxed WAW, and the merged
issue/speculation window; the banked rows deliberately do not.  The previously
recorded current-baseline result in `doc/performance/current.md` is 45,999
cycles and 1.1433 IPC.  The current-tree rerun above is 1,440 cycles (3.13%)
slower, so the archived number is retained as historical data rather than
silently substituted for the rerun.

### Banked conflict and operand-wait counters

| Counter | 2R1W control | EXU forwarding | EXU + MEM0 | + ack release | Ack-release delta |
|---|---:|---:|---:|---:|---:|
| Any bank-conflict cycles | 4,382 | 4,054 | 3,633 | 3,642 | +9 |
| Read-bank-conflict cycles | 989 | 813 | 616 | 625 | +9 |
| Write-bank-conflict cycles | 3,393 | 3,241 | 3,017 | 3,017 | 0 |
| Same-word read/write conflict cycles | 0 | 0 | 0 | 5,957 | +5,957 |
| Cycles blocked on storage reads | 53,451 | 41,764 | 33,224 | 31,824 | -1,400 |
| Cycles blocked by pending writers | 113,147 | 61,261 | 39,967 | 35,925 | -4,042 |
| EXU-forward cycles | 0 | 15,034 | 14,398 | 14,493 | +95 |
| EXU-forwarded operands | 0 | 18,111 | 17,299 | 17,394 | +95 |
| MEM0-forward cycles | 0 | 0 | 15,412 | 15,506 | +94 |
| MEM0-forwarded operands | 0 | 0 | 20,037 | 20,131 | +94 |

These are overlapping predicates, not an additive stall decomposition.  A
cycle may be blocked by a pending writer for one operand and by a storage read
for another.  `bank_conflict_cycles` means an asserted address-phase request
was denied because the target bank had no remaining port; its read and write
subcounters show which side waited.  `read_write_conflict` means an accepted
read and accepted write named the same word and the write-data bypass supplied
the read response.  The pre-ack-release configurations could not exercise that
path because their read gate remained blocked through the write-ack cycle; the
final configuration deliberately uses it.

### What prevented issue before shortening write busy

The instrumented pre-ack-release run records a mutually exclusive
classification of all 85,952 cycles where dispatch was nonempty but issued no
instruction:

| Immediate state | Cycles | Share of no-issue cycles |
|---|---:|---:|
| Pending writer, no simultaneous storage-read wait | 31,658 | 36.83% |
| Pending writer plus storage-read wait on another operand | 8,309 | 9.67% |
| Accepted read waiting for its registered data phase | 24,299 | 28.27% |
| Read-bank conflict only | 0 | 0.00% |
| Read-bank conflict while another read was accepted | 616 | 0.72% |
| Other GPR-not-ready state, principally redirect drain | 1,122 | 1.31% |
| GPR operands ready; blocked elsewhere | 19,948 | 23.21% |
| **Total** | **85,952** | **100.00%** |

The result is not dominated by bank conflicts.  Every one of the 616 read
conflict cycles still accepted at least one other read; there were no cycles
whose only GPR reason was a denied read address.  The fixed registered read
phase is material: 33,224 cycles accepted one or more reads, comprising 24,299
pure read-latency cycles plus the 8,309 writer/read and 616 accept/conflict
mixed cycles.  The 19,948 GPR-ready cycles are outside the banked-file gather
path; the existing WAW, bundle RAW, execution-pipe, barrier, and retirement
predicates overlap, so they are not presented as an additive subdivision.

The pending-writer state splits further by exact youngest producer:

| Youngest producer state | Cycles present | Operand-cycles |
|---|---:|---:|
| Load not yet consumable | 24,124 | 30,702 |
| Load completed but still architecturally owned | 0 | 0 |
| Non-load not yet complete | 7,636 | 9,140 |
| Non-load complete but still architecturally owned | 9,274 | 10,887 |

These rows may overlap in cycles because different operands can wait on
different producers.  Loads are the largest writer-wait source.  Of the
30,702 unfinished-load operand-cycles, 11,896 are the exact cycle in which the
matching load completes but the registered MEM0 forwarding latch is not usable
until the next cycle; the remaining 18,806 occur before completion.  Thus the
MEM0 register boundary accounts for 38.75% of unfinished-load operand-cycles
in this workload.  The run observed 10,445 MEM0 latch captures and issued
12,650 operands from MEM0 across 10,938 issue cycles.

Before ack release, a completed producer was not yet presented to the register
file on 3,815 cycles, its matching write was granted on 5,382 cycles, and it
was denied on only 205 cycles.  Those cycle predicates can overlap for separate
operands.  This showed that the final grant-visibility cycle, not write-bank
denial, was the removable part of the completed-writer wait.  The source run is
`coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260831T220841Z`.

### Write-busy release on ack

The follow-up makes the acknowledged destination combinationally non-busy and
allows its dependent read address phase to share the write-ack cycle.  The
registered read response receives the acknowledged write data through the
existing same-word bypass.  The physical write request is still held until
ack, and strict WAW allocation still waits for registered retirement feedback.

| Counter | Before | Ack release | Delta |
|---|---:|---:|---:|
| Total cycles | 123,621 | 116,383 | -7,238 (-5.85%) |
| Dispatch-nonempty/no-issue cycles | 85,952 | 78,614 | -7,338 |
| Writer-only no-issue cycles | 31,658 | 24,368 | -7,290 |
| Writer/read mixed no-issue cycles | 8,309 | 7,550 | -759 |
| Pure registered-read-latency cycles | 24,299 | 23,649 | -650 |
| Completed non-load writer cycles | 9,274 | 4,108 | -5,166 |
| Matching write granted while still busy | 5,382 | 0 | -5,382 |
| Matching write denied while consumer waits | 205 | 207 | +2 |
| Accepted same-word read/write bypass cycles | 0 | 5,957 | +5,957 |
| Accepted same-word read/write bypass events | 0 | 7,378 | +7,378 |

The 7,238-cycle reduction is larger than the removed 5,382 grant-cycle
predicate because the schedule changes downstream overlap.  It must not be
attributed by simple subtraction among overlapping counters.  The final
validation-pass run is
`coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260831T221634Z`.

### Deep pending-writer attribution after ack release

The follow-up diagnostic rerun is behavior-identical at 116,383 cycles,
52,589 retired instructions, and 0.4519 IPC.  It passed with the same result
and platform checks as the preceding run.  Its managed run is
`coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260831T225243Z`.

Here, "pending writer" does not mean that a register-file write port is busy.
It means that a source operand of one of the first two strict-dispatch
candidates still names an allocated youngest producer and has neither a
captured value nor a producer-qualified bypass.  Ownership begins at producer
allocation and normally clears at retirement; completion only marks the
retained owner entry ready.  The ack-release path makes an acknowledged
destination readable in the write-ack cycle, but it does not otherwise shorten
producer ownership.

Every one of the 44,766 blocked operand-events was classified by dynamic
instruction-ID distance from its exact youngest producer:

| Producer-to-consumer distance | Operand-events | Share |
|---|---:|---:|
| 1 | 10,267 | 22.93% |
| 2 | 20,398 | 45.57% |
| 3-4 | 13,632 | 30.45% |
| 5-8 | 469 | 1.05% |
| 9 or more | 0 | 0.00% |
| **Total** | **44,766** | **100.00%** |

Thus 68.50% of blocked operands are within two dynamic instructions of their
producer and 98.95% are within four.  This is a short dependency-chain problem,
not evidence of ancient or stuck register ownership.

The consumer mix also rules out one isolated opcode pathology:

| Consumer class | Blocked operand-events | Share | Zero-issue writer cycles | Share |
|---|---:|---:|---:|---:|
| ALU | 16,840 | 37.62% | 12,310 | 38.57% |
| Branch | 16,948 | 37.86% | 7,710 | 24.16% |
| Jump | 6 | 0.01% | 1,435 | 4.50% |
| Load | 5,980 | 13.36% | 6,840 | 21.43% |
| Store | 4,992 | 11.15% | 3,623 | 11.35% |
| **Total** | **44,766** | **100.00%** | **31,918** | **100.00%** |

The zero-issue column classifies the oldest candidate only on cycles where a
pending writer prevents all issue.  The operand column counts both source
operands of the first two candidates, so the two columns are intentionally not
directly comparable.

Unfinished loads account for 30,890 blocked operand-events.  Their exact phase
is:

| Youngest load-producer phase | Operand-events | Share |
|---|---:|---:|
| Completing now; registered MEM0 value not yet usable | 11,993 | 38.82% |
| Translation incomplete | 160 | 0.52% |
| Translated; LSU access not yet launched | 9,355 | 30.28% |
| LSU access launched; response outstanding | 9,382 | 30.37% |
| Producer absent from LSQ after completion | 0 | 0.00% |
| **Total** | **30,890** | **100.00%** |

The 9,355 pre-launch events are not 9,355 cycles of hidden memory latency.  An
exact launch-path split finds 8,938 operand-events (95.54%) on the same edge
that fires the matching LSU access; `slot_access_sent_q` becomes visible after
that edge.  Another 257 events (2.75%) have selected the matching request but
are waiting for request readiness, and 160 (1.71%) lose the single launch port
to an older request.  Store-guard, uncacheable-order, and unexplained buckets
are all zero.  The run records 335 aggregate load request-wait cycles at the
L1D interface; only the subset with a currently exposed dependent operand
appears in the 257-event count.

The deliberate MEM0 register boundary remains the largest individual
load-wait bucket.  It was exposed on 11,993 operand-events across 9,321 cycles;
10,445 load results were captured.  No completed load waited for architectural
writeback (`load_ready=0`), so the registered MEM0 bypass works once its value
becomes available.  For a tight dependent chain, however, the observable path
still includes access launch, an outstanding-response cycle, the completion
cycle, and the registered MEM0 forwarding cycle.

Completed non-load producers account for 4,108 writer-blocked cycles.  They
split exactly into 3,901 cycles where retirement had not yet presented the
matching write and 207 cycles where that write was presented but denied; zero
cycles remained blocked on a granted write.  Actual bank-write denial is
therefore a minor part of this tail.  A retained completion-result source could
remove much of it, and the backend already stores the qualified result in
`youngest_owner_data_q`.  Such a source cannot help the 24,308 load-incomplete
or 8,248 other-incomplete writer cycles because those results do not exist yet.

Retirement exposes a separate throughput problem.  Of 64,795 cycles with a
nonempty retirement queue and no retirement, 33,023 have an incomplete head.
The remaining 31,772 have a ready head.  Exact wrapper-state attribution splits
those ready-head cycles into 28,642 unconditional `write_active_q` capture
cycles, 3,017 cycles waiting for a denied bank write, zero cycles with writes
complete but retirement still blocked, and 113 ready non-GPR cases.  The
31,659 physical write-request cycles are exactly the 28,642 writing groups plus
the 3,017 retry cycles; normally the granted request cycle retires the group.

The capture bubble alone is 24.61% of the entire 116,383-cycle run.  That is an
upper bound on direct cycle savings, not a predicted benchmark delta, because
removing it changes overlap and the downstream schedule.  A fall-through/skid
write path is nevertheless the clearly justified next retirement change: offer
the current ready head directly to the register file, retire it on full ack,
and latch only an unacknowledged partial transaction.  It must retain stable
address/data for denied lanes plus flush-discard and CSR-order behavior.  This
is independent of the incomplete-producer latency above.

The diagnostic work also corrected a testbench-only classification error:
`PERF_ICX_L2_RAW` and conflict consumer opcodes had been decoded using
retirement-record bit positions even though the probes observe execution issue
payloads.  The fixed counters do not change RTL behavior or benchmark timing.
The corrected raw split is 12,558 ALU, 10,800 branch, 728 jump, 2,970 load, and
5,204 store first-block cycles.  The corrected execution-resource conflicts
are 588 branch/branch and 1,362 memory conflicts (1,290 load/load and 72
store/store).

The directed run `3p-banked-directed-20260831T202004Z` passed after the
forwarding change.  It proves that a dependent operand can consume a
producer-ID-qualified EXU completion while the architectural scoreboard bit
is still busy, in addition to the existing 2R1W, held-retry, bypass, and
redirect-drain checks.

The load-forwarding directed run `3p-banked-directed-20260831T214031Z` adds a
tagged load followed immediately by a dependent integer operation.  It checks
that the registered MEM0 result is consumed while the exact producer still
owns the architectural destination and that both instructions retire with the
expected values.  MEM0 is deliberately load-only: non-load completion traffic
on that lane cannot satisfy an operand.  During an issue cycle whose operand
came from MEM0, live EX0/EX1 forwarding is suppressed to avoid a combinational
LSU issue/response loop; this is a conservative timing boundary, not a claim
of maximum forwarding bandwidth.

`3p-banked-directed-20260831T221616Z` additionally requires a dependent read
address to be accepted on its producer's write-ack cycle and verifies the
result after the registered bypass response.

The final platform ACT4 run
`compliance-act4-platform-3p-banked-ddr3-20260831T221753Z` passed all 93
preserved RV64IMA tests with 2R1W banks, EX0/EX1 forwarding, registered
load-only MEM0 forwarding, write-busy release on ack, the integrated L2, and
timed DDR3 (`pass=93 fail=0`).

Each comparison below uses the same binary and core/platform controls: BP8,
mode 3, fetch carousel enabled, confidence gate enabled, pair-stack depth 2,
no completion or branch forwarding, conservative WAW/RAW handling, no issue or
speculation window, retirement depth 32, posted stores, 16-KiB L1I and L1D,
256-KiB 8-way L2, and the timed-DDR3 model.  All three configurations were
launched concurrently and retired the same 52,563 instructions with the same
`a0=0x0a277880` result.

## Earlier compact bare-physical loop on DDR3

| Configuration | Physical GPR banks | Cycles | Retired | IPC | Versus normal 3P | Versus banked 1R1W |
|---|---|---:|---:|---:|---:|---:|
| Normal 3P control | Unbanked multiport PRF | 79,318 | 52,563 | 0.6627 | baseline | -60.27% cycles |
| Banked A | 2 x 16, 1R1W each | 199,660 | 52,563 | 0.2633 | +120,342 (+151.72%), 2.518x | baseline |
| Banked B | 2 x 16, 2R1W each | 190,267 | 52,563 | 0.2763 | +110,949 (+139.88%), 2.399x | -9,393 (-4.70%) |

Managed runs, all validation pass:

- Normal 3P:
  `coremarks-compact-3p-ddr3-20260831T200324Z`.
- Banked 1R1W:
  `coremarks-compact-3p-banked-1r1w-ddr3-20260831T200324Z`.
- Banked 2R1W:
  `coremarks-compact-3p-banked-2r1w-ddr3-20260831T200324Z`.

The 2R1W result shows that eliminating most two-request bank conflicts helps,
but it does not explain most of the banked-core gap.  The remaining 2.399x
cycle ratio includes the banked backend's two-wide cap, disabled forwarding,
conservative dependency release, address/data operand-gather stage, and
one-write-per-bank retirement behavior.  This run does not attribute the
remaining loss among those causes.

## Directed 2R1W validation

`3p-banked-directed-20260831T194705Z` passed with two physical read ports per
bank.  Its focused cases include:

- three same-bank requests grant exactly two slots and retry the third;
- four reads distributed two per bank are accepted in one address phase;
- four same-bank reads complete over two address phases;
- redirect while two accepted responses return and two same-bank requests
  remain unacknowledged;
- flush after a partial two-slot response;
- same-address read/write bypass and pipelined address/data association.

## Secondary longer-workload measurements

These measurements were collected before the compact workload was clarified.
They remain useful secondary evidence but are not the primary comparison.

| Geometry | Workload | Cycles | Retired | IPC | Managed run |
|---|---|---:|---:|---:|---|
| 1R1W | Official CoreMark one-iteration smoke | 1,482,850 | 358,184 | 0.2416 | `coremark-bare-smoke-3p-banked-ddr3-20260831T193417Z` |
| 1R1W | Sv39 CoreMark-derived loop | 195,619 | 52,589 | 0.2688 | `coremark-sv39-3p-banked-ddr3-20260831T193733Z` |
| 2R1W | Official CoreMark one-iteration smoke | 1,410,032 | 358,184 | 0.2540 | `coremark-bare-smoke-3p-banked-ddr3-20260831T194719Z` |

For the longer bare smoke, 2R1W saves 72,818 cycles (4.91%) relative to the
1R1W address/data-phase baseline.  A matching 2R1W Sv39 rerun was intentionally
not started after the benchmark clarification.

## Registered operand-load stage

The 2026-09-01 change makes the banked register access an explicit pipeline
stage instead of forcing dispatch to retain the queue head until every read
data phase returns.  The interface and requester now have the following cycle
contract:

| Cycle | Register path action |
|---|---|
| N, address | Dispatch presents up to four operand addresses and holds each request until its per-port ack.  The ack allocates that transaction to either the execution-facing operand group or its one-group pending credit. |
| N+1, data | Data for the acked addresses returns with the prior-cycle ack as its ownership token.  The group captures each operand independently.  If the pending credit is free, dispatch may submit the next group's address phase in this same cycle. |
| N+1 or later, issue | Each lane may issue independently after both operands are captured and its selected pipe accepts it.  A completed active group promotes the pending group without returning through dispatch. |

An unacknowledged request remains asserted with a stable address.  Redirect
poisons accepted responses, continues holding denied requests until ack, and
blocks new traffic until `(|req) || !quiescent` becomes false.  Simulation
fails a read, write, or redirect drain that remains pending for 100 cycles.
Same-cycle read/write collisions return the acknowledged write data.  Reads
of x0 are synthesized as zero and never enter bank storage; writes to x0 are
suppressed.

The stage also retains producer-qualified EX0/EX1 and registered load-only
MEM0 forwarding.  A payload-independent EX0/EX1 capacity sideband permits an
ordinary base-ALU packet to switch to the peer ALU after operand capture;
using payload-dependent `ready` for that decision would create a route/ready
combinational loop.

Equality-branch pairing is resolved in the operand stage.  A BEQ/BNE and one
non-hard follower may allocate together, but the follower is not offered to
execution until the following cycle's registered branch resolution proves the
prediction correct.  The extra branch-pair cycle keeps output valid independent
of execution ready; allowing same-edge follower issue closed a ready/valid loop
through a MEM follower and LSU translation.  Hard followers remain serialized
because the barrier scoreboard is not counted.  On a wrong prediction, the
follower has had no execution side effects:
selective recovery removes its retirement entry, its conservative scoreboard
writer, and its youngest-owner tag.  This rollback relies on banked 3P's
required strict WAW mode; it is not a general speculative recovery mechanism.

### Stage performance checkpoints

All rows use the matched Sv39 RD32, 2R1W, EX0/EX1 plus registered load-only
MEM0 forwarding, fall-through banked retirement, BP8, and timed-DDR3 setup.

| Change | Cycles | Retired | IPC | Delta from preceding row | Managed run |
|---|---:|---:|---:|---:|---|
| Pre-stage fall-through-retire control | 105,835 | 52,589 | 0.4969 | baseline | `coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260831T230824Z` |
| Explicit operand-load stage, branch pairing disabled | 117,971 | 52,589 | 0.4458 | +12,136 (+11.47%) | `coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260901T000239Z` |
| Add post-capture EX0/EX1 retargeting | 117,971 | 52,589 | 0.4458 | 0 (0.00%) | `coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260901T001126Z` |
| Add deferred equality-branch pairing and precise follower recovery | 115,913 | 52,589 | 0.4537 | -2,058 (-1.74%) | `coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260901T004012Z` |
| Simulation-only same-cycle magic register reads | 115,913 | 52,589 | 0.4537 | 0 (0.00%) | `coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260901T011731Z` |

The first stage run did not simply add one read-latency cycle to every group.
Pure registered-read-latency no-issue cycles fell from 24,823 to 3,307 because
address and data work overlap, but `gpr_ready_other` rose from 12,199 to
43,534.  Total cycles consequently regressed by 12,136.  The stage changed
when instructions become allocated and exposed the old rule that a hard
branch cannot carry a following instruction through the new stage.  There are
10,786 conditional branch resolutions in this workload, which made deferred
branch pairing the first structural follow-up.  ALU retargeting's exact
zero-cycle result rules out provisional EX0/EX1 placement as the cause of the
regression.  Deferred branch pairing recovers 2,058 cycles, but the registered
stage remains 10,078 cycles (9.52%) slower than the pre-stage control.  In the
final run, dispatch is nonempty without issue for 76,159 cycles; the banked
breakdown attributes 27,373 of those to writer-only blocking, 2,283 to mixed
writer/read blocking, 3,979 to registered read latency, and 42,000 to
`gpr_ready_other`.  This is aggregate attribution, not proof of one root cause.

`OPENRV64_BANKED_GPR_MAGIC_READS` replaces the acknowledged register read's
one-cycle data phase with an asynchronous simulation read.  It deliberately
retains the two 2R1W banks, arbitration, bank conflicts, write blocking,
forwarding, and the explicit regload stage.  This changed
`blocked_on_reads_cycles` from 34,298 to 1,267 and classified zero cycles as
`read_latency_only`, but total cycles and every top-level issue/retirement
count were identical.  The apparent stall reductions were reclassified into
other overlapping predicates, including `gpr_ready_other` rising from 42,000
to 49,470.  The normal registered response is therefore already consumed in
the first cycle that the allocated regload group can issue; removing its data
latency does not shorten this workload's schedule.  This experiment only
isolates the storage data phase behind the new stage.  It does **not** emulate
the old 3P direct-read/direct-issue path and therefore cannot answer whether
that path is the missing performance.

### Corrected direct-path controls

The initial magic-read comparison tested the wrong boundary.  The following
controls distinguish storage latency from the mandatory regload stage and from
the other current-normal-3P scheduler controls.

These banked measurements use the conservative bring-up topology, not the
intended post-issue-selection register-load stage.  The configuration forces
`ISSUE_WINDOW=0`, the backend rejects `BANKED_GPR` combined with the issue
window, and regload capture currently keys from `allocation_valid`.  Allocation
and selected execution issue are the same event only on the strict dispatch
path.  In the normal windowed path, retirement/rename allocation and selection
of any dependency-cleared instruction are separate events.  Consequently,
these results must not be interpreted as the cost of adding one pipeline stage
after the current normal-3P scheduler.

| Path and controls | Cycles | Retired | IPC | Managed run |
|---|---:|---:|---:|---|
| Banked regload stage with registered bank reads | 115,913 | 52,589 | 0.4537 | `coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260901T004012Z` |
| Same regload stage with simulation-only asynchronous bank reads | 115,913 | 52,589 | 0.4537 | `coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260901T011731Z` |
| Strict configuration using the old six-read/direct-issue path | 66,437 | 52,592 | 0.7916 | `coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260901T012746Z` |
| Current normal 3P configuration | 47,439 | 52,592 | 1.1086 | `coremark-sv39-linux-rd32-ddr3-20260901T012937Z` |

Selecting the old direct path recovered 49,476 cycles from the staged magic
run.  That is within six cycles of the magic run's 49,470-cycle
`gpr_ready_other` bucket.  The near identity ties that bucket to the banked
regload mode bundle, not physical register-bank data latency.  It does not
isolate the stage register itself: the same `BANKED_GPR` parameter also changes
maximum allocation/issue width from three lanes to two, selects two-wide
banked retirement, enables the active-plus-pending group controller and its
hard-group gate, and changes writer ownership/forwarding behavior.

The 66,437-cycle point is an upper-bound isolation control, not a pure
"banked writes plus magic reads" configuration: overriding `BANKED_GPR=0`
also selects normal retirement.  It retains the strict banked experiment's
disabled branch forwarding, strict WAW, disabled merged issue window, and
disabled speculation window.  The current normal 3P point enables those
features and takes another 18,998 cycles off.  That second delta is a combined
configuration effect; these aggregate runs do not attribute it among the
individual controls.  A clean banked-write/direct-magic-read measurement
requires splitting storage/retirement selection from regload/issue-path
selection.

### Stage-local attribution

Stage-local counters remove an ambiguity in the earlier dispatch-input
`gpr_ready_other` classification.  Registered and magic-read runs produced the
same schedule and the same stage state:

| Stage state or event | Cycles/events |
|---|---:|
| Active group resident | 38,075 cycles |
| Pending group resident | 0 cycles |
| Active and pending groups resident | 0 cycles |
| Allocate into active | 35,818 events |
| Allocate into pending | 0 events |
| Promote pending to active | 0 events |
| Issue active and allocate its replacement together | 2,649 cycles |
| No issue: stage empty, selection captured this cycle | 33,169 cycles |
| No issue: stage empty, no selection available | 42,990 cycles |
| No issue: active operands incomplete | 0 cycles |
| No issue: execution pipe unavailable | 0 cycles |
| No issue: deferred branch gate | 0 cycles |
| No issue: stage output backpressured | 0 cycles |

Thus an active group issues on its first eligible cycle; the pending credit is
never used by this workload.  The explicit stage does not stall while full.
It inserts a selection/capture edge before execution, which lengthens short
dependency chains because a consumer can become selectable only after its
producer result is known.  The historical A/B measurement attributes 10,078
net cycles to that boundary: 105,835 before the explicit stage versus 115,913
after it.  The other 39,398 cycles between the 66,437-cycle old direct path and
the 105,835-cycle pre-stage banked path already existed in the banked
dependency, read-gather, write, and retirement machinery.  Those 39,398 cycles
cannot be charged to the new pipeline register.

A rejected experiment made live EX0/EX1 forwarding satisfy the dispatch-side
candidate-ready hint in addition to the retained forwarded-result bit.  Both
the registered-read and magic-read configurations remained exactly 115,913
cycles, 52,589 retired instructions, and 0.4537 IPC, with every stage-local
counter above unchanged.  The managed runs were
`coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260901T014850Z-3071629`
and `coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260901T014850Z`.
The RTL experiment was reverted; the existing local-forward path already
covered the live result for scheduling purposes.

### Post-issue-window register loads

The intended topology now defers architectural GPR reads until after the
merged issue window selects dependency-cleared work:

`dispatch metadata and producer tags -> issue selection -> banked register
load -> execution`

The window admits at most two selected packets into the register-load stage.
Producer-owned operands retain their qualified completion data; only unowned
architectural operands consume the four banked read requesters.  The active
plus pending group credit lets address phases continue while the preceding
group waits for its registered data phase.  Hard/control work is selected
alone so it cannot provisionally admit younger side effects behind a branch.

| Configuration | Cycles | Retired | IPC | Versus explicit strict stage | Versus current normal 3P |
|---|---:|---:|---:|---:|---:|
| Explicit regload stage before a strict dispatcher | 115,913 | 52,589 | 0.4537 | baseline | 2.444x cycles |
| Banked 2R1W regload after issue-window selection | **87,228** | 52,588 | **0.6029** | **-28,685 (-24.75%)** | **1.839x cycles** |
| Current normal 3P matched control | **47,439** | 52,592 | **1.1086** | not configuration-matched | baseline |

Final managed runs, both with Sv39 and timed DDR3 required:

- banked post-window:
  `coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T023047Z`;
- current normal 3P:
  `coremark-sv39-linux-rd32-ddr3-20260901T023222Z`.

The remembered approximately 95,000-cycle old-3P result was collected during
early bring-up.  It is not a matched current-tree control and is deliberately
excluded from the parity calculation.  The current parity gap is 39,789 cycles
(83.87% over normal), not a comparison against that historical point.

The final banked run's focused counters are:

| State or event | Cycles/events |
|---|---:|
| Read-bank-conflict cycles / events | 0 / 0 |
| Write-bank-conflict cycles / denied events | 4,453 / 4,453 |
| Same-word read/write conflict cycles / events | 0 / 0 |
| Blocked-on-read cycles | 15,064 |
| No issue from registered read latency alone | 5,057 |
| Regload active / pending / both active-and-pending | 50,214 / 5,248 / 5,248 cycles |
| Allocate active / allocate pending / promote pending | 37,335 / 5,039 / 5,039 events |
| Issue and allocate replacement together | 25,965 cycles |
| Stage empty while allocating / empty with no selection | 22,230 / 14,140 cycles |
| Window nonempty with no eligible instruction | 26,304 cycles |
| Window RAW / hard / memory-order stall predicates | 26,129 / 23,211 / 17,485 cycles |
| Retirement nonempty with no retirement / incomplete head | 48,425 / 43,859 cycles |
| GPR write request cycles / accepts / denials | 32,001 / 37,364 / 4,453 |

These predicates overlap and are not an additive decomposition.  The zero
read-conflict result establishes that this workload's remaining gap is not
caused by 2R1W read arbitration.  The 5,057 fixed response-latency cycles are
real but explain only a minority of the 39,789-cycle gap.  The banked run also
uses strict WAW, no branch completion forwarding, conservative hard ordering,
and banked retirement; its window reports roughly twice the normal run's
no-eligible, RAW, hard, and memory-order cycle predicates.  Those ratios are
diagnostic, not causal proof, because the banked run is longer and the
predicates overlap.

#### Window dependency, WAW, and wakeup counters

The window now reports actual overlapping-writer admission, resident older
writers shadowed by the youngest-owner map, same-cycle completion wakeups, and
the phase of every unavailable producer-tagged operand.  The harness trace
widths are derived from `RETIRE_DEPTH`; the former fixed five-bit window wires
could represent only 0 through 31 and would alias a full 32-entry count to
zero.

The matched instrumented runs are:

- banked post-window:
  `coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T024307Z`;
- current normal 3P:
  `coremark-sv39-linux-rd32-ddr3-20260901T024446Z`.

Both passed with the same 87,228-cycle and 47,439-cycle schedules reported
above.  The final focused regression is
`3p-banked-directed-20260901T024243Z` (`validation=pass`).

| Window event or state | Banked post-window | Current normal 3P |
|---|---:|---:|
| WAW admissions over a live prior owner | 47,302 | 41,385 |
| Prior owner ready / unready at admission | 5,527 / 41,775 | 7,827 / 33,558 |
| Resident / same-decode-bundle WAW admission | 43,605 / 3,697 | 35,786 / 5,599 |
| Shadowed older-writer entry-cycles | 1,099,575 | 478,312 |
| Shadowed ready-writer entry-cycles | 278,321 | 136,639 |
| Completion-woken operand events | 49,132 | 44,664 |
| Wakeups from EX0 / EX1 / MEM0 | 25,534 / 6,307 / 17,291 | 21,473 / 6,486 / 16,705 |
| Completion-woken entry events | 48,974 | 43,999 |
| Woken entries eligible in the same cycle | 28,494 | 28,081 |

The legacy `waw_hazard_o` result is zero by construction in window mode.  It
does not mean that the workload lacks WAWs.  The youngest-owner map already
admits a younger writer and replaces ownership without waiting for the older
writer to retire, even when the top-level configuration prints
`relax_waw=0`.  Consequently, merely toggling the legacy `RELAX_WAW` parameter
is not a meaningful next performance experiment for this window.  The WAW
policy is already relaxed and is heavily exercised: 41,775 of the banked
run's 47,302 overlapping-writer admissions saw an unready prior owner.

The stale banked-backend parameter check was then narrowed so it rejects only
the still-unsupported broad `RELAX_HAZARDS` mode.  The persistent banked-window
configuration now sets `RELAX_WAW=1`, making the printed configuration agree
with the owner-map behavior.  Managed run
`coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T025052Z` passed at exactly
87,228 cycles, 52,588 retired instructions, and 0.6029 IPC; every focused
counter was unchanged.  This was the expected null result, not a performance
gain.  The corresponding focused regression was
`3p-banked-directed-20260901T025041Z` (`validation=pass`).

Unavailable producer-tagged operands were classified each cycle as follows.
These are operand-cycle snapshots, not disjoint retired-instruction counts;
speculative entries that are later squashed are included.

| Producer phase for unavailable operand | Banked post-window | Current normal 3P |
|---|---:|---:|
| Producer not issued, load-class | 443,021 | 187,267 |
| Producer not issued, other | 787,220 | 319,498 |
| Producer issued but incomplete, load-class | 63,430 | 45,876 |
| Producer issued but incomplete, other | 39,241 | 0 |
| Producer already complete but operand still unavailable | 0 | 0 |
| Producer tag absent from the resident window | 0 | 0 |
| **Total unavailable producer operand-cycles** | **1,332,912** | **552,641** |

For the banked run, 1,230,241 operand-cycles, or 92.30%, wait for a producer
that has not issued.  Only 102,671, or 7.70%, wait for an issued producer to
return a result.  Unissued producers also account for 92.72% of the 780,271
operand-cycle excess over current normal 3P.  This rejects the simple model
that the remaining performance gap is primarily the one-cycle completion
latency.  The 39,241 banked-only in-flight non-load operand-cycles are
consistent with the added post-selection register-load boundary, but they are
only 2.94% of the banked total and the configurations differ in other policy
controls, so this counter is not a pure stage-latency measurement.

Completion-to-window forwarding is already active in the scheduling cycle:
28,494 banked entries became eligible in the same cycle that a matching
completion woke an operand, almost identical in absolute count to the normal
control's 28,081.  A useful forwarding follow-up therefore has to attack
producer-to-consumer chaining before the producer is marked issued, or remove
the extra banked execution-launch interval.  Adding another ordinary
completion bypass is unlikely to recover the dominant 92.30% unissued-producer
bucket.

#### Conditional-branch speculation and retirement write blocking

The LSQ's `spec_alloc` count is not a branch-speculation counter: it means that
an operation allocated before becoming the ordered retirement head.  New
window counters therefore track younger scheduler releases across an actually
unresolved conditional branch and snapshot younger completed work when that
branch resolves.  In the banked configuration, a scheduler release transfers
ownership into the registered operand-load stage; it does not necessarily mean
that execution occurred.  The completion snapshot is the stronger measure and
conservatively excludes same-cycle completions.

The final matched runs with these counters and the explicit retirement
`gpr_write_blocked` aggregate are:

- banked post-window:
  `coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T032931Z`;
- current normal 3P:
  `coremark-sv39-linux-rd32-ddr3-20260901T033058Z`.

Both passed and retained the 87,228-cycle and 47,439-cycle schedules.  Focused
banked validation is `3p-banked-directed-20260901T031259Z`
(`validation=pass`).

The normal control sets its legacy branch-completion-forward mask to one while
the banked configuration sets it to zero.  Normal-3P ablation
`coremark-sv39-linux-rd32-ddr3-20260901T031854Z` disabled that mask and still
ran in exactly 47,439 cycles with every branch-speculation counter unchanged.
The legacy mask is therefore inert for this workload under the issue window;
porting it alone is not a supported performance target.

| Conditional-branch event or state | Banked post-window | Current normal 3P |
|---|---:|---:|
| Conditional resolutions | 10,786 | 10,786 |
| Correct / corrected direction | 9,936 / 850 | 9,902 / 884 |
| Correct direction | 92.12% | 91.80% |
| Cycles with an unresolved conditional | 80,074 | 41,927 |
| Scheduler release cycles / events | 15,662 / 21,870 | 18,212 / 23,282 |
| Instruction-branch release relationships | 70,616 | 65,928 |
| Resolutions with younger completed work | 9,764 (90.52%) | 8,474 (78.56%) |
| Younger-completed instruction-branch relationships | 53,666 | 35,210 |
| Completed behind correct / corrected branches | 50,016 / 3,650 | 32,566 / 2,644 |
| Retained / discarded share of completed relationships | 93.20% / 6.80% | 92.49% / 7.51% |
| Maximum younger scheduler releases at resolution | 15 | 12 |
| Incomplete branch at retirement-head cycles | 3,072 | 4 |
| Correction post-redirect empty cycles | 539 | 385 |
| Retirement cycles blocked by GPR writes | 4,453 | 0 |
| Direct-address / retry write-blocked cycles | 4,453 / 0 | 0 / 0 |

Relationship totals are not unique instruction counts.  One instruction can
be younger than multiple unresolved branches and is then counted once for each
branch.  Direction correctness compares the resolved conditional outcome with
the predicted-taken bit stored in that branch's resident window entry.  It is
therefore narrower than the frontend's total direction-correction count, which
also includes other control-flow cases.

Branch speculation is active and reasonably effective.  In the banked run,
90.52% of conditional resolutions already observe completed younger work, and
93.20% of all such completed relationships are retained behind a correct
prediction.  The banked core's larger speculative depth is not evidence that
it schedules better: branches remain unresolved for almost twice as many
cycles, while its scheduler releases only 0.251 instructions per runtime cycle
across an unresolved branch versus 0.491 for normal 3P.  The extra 154
correction-recovery empty cycles are negligible beside the 39,789-cycle total
performance gap.  Increasing speculative reach or changing the predictor is
therefore not the leading banked-GPR optimization.

The 3,072 banked cycles with an incomplete branch at the retirement head do
show that the post-selection branch execution path is late; normal 3P reports
only four.  This is a narrower launch/resolution-latency problem, not evidence
that the window refuses to speculate past branches.  It bounds a meaningful
branch fast path, but it is still much smaller than the total parity gap and
the normal branch-forward-mask ablation shows that simply enabling the old
bypass does not implement that fast path.

The write-block result is also bounded.  All 4,453 blocked cycles are the
initial write address phase; there are no multi-cycle retry waits.  That is
5.11% of banked runtime and only 11.19% of the gap to normal 3P.  Removing the
retirement write bubble could help, but cannot explain or repair the dominant
loss.  The stronger next target remains the post-window operand-load launch
interval.  A branch-specific fast path can share that fall-through machinery
to shorten resolution, but it should follow the general already-materialized
ALU/operand path rather than replace it.

#### EXU/MEM0 completion forwarding into conditional branches

Branch-consumer counters confirm that the issue window's generic completion
bus, not the legacy branch-forward mask, forwards both EXU and MEM0 results.
An exact producer-ID match makes the operand ready and patches the selected
payload from the completion data in the same cycle.  If downstream admission
is blocked, the window persists that completion data for a later release.

| Conditional-branch forwarding event | Banked post-window | Current normal 3P |
|---|---:|---:|
| Woken branch operands | 18,605 | 17,662 |
| Woken by EX0 / EX1 / MEM0 | 9,889 / 1,943 / 6,773 | 8,219 / 2,969 / 6,474 |
| Woken branch entries | 18,511 | 17,088 |
| Eligible on the wakeup edge | 8,183 | 8,285 |
| Selected on the wakeup edge | 8,182 | 8,285 |
| Offered on the wakeup edge | 5,400 | 8,285 |
| Accepted on the wakeup edge | 4,241 | 8,285 |
| Accepted forwarded operands | 4,322 | 8,795 |
| Accepted EXU / MEM0 operands | 2,385 / 1,937 | 4,278 / 4,517 |

These are dynamic speculative events, not unique retired branches; wrong-path
entries are included.  Source counts are operand counts, so an event can
include two forwarded operands.  In normal 3P, `accepted` is the EX1 execution
handshake.  In banked mode it is only capture by the registered operand-load
stage; branch execution and resolution remain later.

The forwarding is meaningful.  The banked core accepts 4,241 branches on the
same edge that supplies a missing result, split almost evenly between EXU and
MEM0 sources.  It works even with `branch_forward_mask=0`, consistent with the
normal-mask ablation above: issue-window completion wakeup supersedes that old
special-case path.

It is not delivering normal-3P latency.  Selection loses essentially nothing
(8,182 of 8,183 eligible entries), but window offer/admission gates suppress
2,782 selected offers and regload readiness withholds another 1,159 accepted
transfers.  The current counters do not split the former between two-lane age
rank, deferred hard-control, and recovery suppression.  Only 51.83% of selected
wakeup-edge branches
therefore leave the window on that edge, versus 100% in normal 3P.  The delayed
cases remain correct and retain their forwarded data, but lose the same-cycle
latency benefit.  Even accepted banked branches still cross regload before EX1.
This supports a general regload fall-through/acceptance improvement and,
secondarily, a branch fast path when every used operand is already materialized;
adding the legacy branch-forward mask would not address the bottleneck.

Redirect handling uses poison rather than combinational valid suppression.
The registered regload output keeps `valid` independent of redirect and
execution `ready`; selective recovery discards younger issued state, the LSQ
kills or refuses younger memory work, and the regfile requester continues to
hold every denied address until ack before draining accepted responses.  New
traffic remains blocked until the regfile is quiescent.  This removed the two
new regload-stage combinational loops reported by Verilator without changing
the 87,228-cycle schedule.  Pre-existing `UNOPTFLAT` warnings remain in the
platform translation/control and retirement paths; this work does not claim
to remove them.

The final focused regression is
`3p-banked-directed-20260901T023036Z` (`validation=pass`).  It includes the new
issue-window/backend case, held bank retries, delayed-response redirect drain,
arithmetic and load/use dependencies, plus the strict banked top-level branch
loop.  The persistent benchmark configuration is
`run/cfg/coremark-sv39-3p-banked-window-2r1w-ddr3.cfg`.

#### Full exclusive pipeline partition and hard-control admission barrier

The previous aggregate counters overlapped and therefore did not close the
runtime gap.  The following results add mutually exclusive per-cycle
partitions at decode, issue-window address admission, the banked register-load
data stage, and zero-width retirement.  The final matched Sv39/DDR3 runs are:

- banked post-window 2R1W:
  `coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T043133Z`;
- current normal 3P:
  `coremark-sv39-linux-rd32-ddr3-20260901T043316Z`.

Both passed.  The banked run took 87,228 cycles for 52,588 retired
instructions; normal 3P took 47,439 cycles for 52,592.  The measured runtime
gap is therefore 39,789 cycles, not approximately 20,000.

The issue-window output is an address-phase offer.  A `fire` below is an offer
accepted by the downstream ready/ack vector; `offer replay` means that the
window selected work but downstream withheld every relevant ack.

| Exclusive issue-window state | Banked post-window | Current normal 3P | Delta |
|---|---:|---:|---:|
| Window empty | 1,570 | 1,467 | +103 |
| Nonempty, no eligible entry | 26,304 | 13,228 | +13,076 |
| Eligible, but no output offer | 1,656 | 862 | +794 |
| Output offer replayed by downstream | 15,324 | 420 | +14,904 |
| At least one address-phase fire | 42,374 | 31,462 | +10,912 |
| **Total cycles** | **87,228** | **47,439** | **+39,789** |
| Address-phase fire events | 56,860 | 56,560 | +300 |

The positive delta in fire cycles is not a gain.  Almost the same number of
speculative instruction offers is accepted in both runs, but the banked path
spreads them over 10,912 more address-admission cycles because its register-load
group has at most two lanes and often contains only one usable lane.

The 15,324 banked offer-replay cycles split exactly as follows:

| Downstream reason for replaying a selected window offer | Cycles |
|---|---:|
| Pending regload group already occupied | 3,730 |
| Active hard group contains a conditional branch | 10,053 |
| Active hard group contains a jump | 475 |
| Active hard group contains another hard operation | 0 |
| Redirect/flush regfile drain | 1,066 |
| Unclassified | 0 |
| **Total** | **15,324** |

This is the missing serialization.  `banked_regload_hard_q` closes the whole
window-to-regload ready/ack vector while an active hard group is resident.  It
also prevents use of the pending-group credit.  A branch or jump is therefore
fully blocking at this interface: the issue window can select younger eligible
work, but cannot transfer its address phase until the hard group leaves.  For
the common ready branch this is approximately one lost admission cycle per
conditional branch.  It is not register-file port saturation.  With two read
ports per bank, accepted reads saw zero read-bank conflicts and zero read/write
conflicts in this run.

The banked register-load data phase itself partitions all 87,228 cycles:

| Exclusive banked regload state | Cycles |
|---|---:|
| Empty | 37,014 |
| Active, zero fires | 5,281 |
| Active single-lane group, one fire | 30,447 |
| Active two-lane group, one fire and one replay | 2,559 |
| Active two-lane group, two fires | 11,927 |
| **Total cycles** | **87,228** |
| Execution fire events | 56,860 |

The 5,281 zero-fire cycles are 5,057 operand-return waits and 224 execution
backpressure cycles.  The 2,559 partial-fire cycles are 2,457 operand-return
waits and 102 execution-backpressure cycles.  There are zero target conflicts,
branch-follower gates, missing-pipe mappings, or unexplained cycles in these
partitions.  Thus the one-cycle register read affects 7,514 active stage
cycles, but only 5,057 of them produce no execution fire.  The larger width
effect is visible by comparing 44,933 banked execution-fire cycles against
31,462 normal window-fire cycles for nearly identical event counts.  The
13,471-cycle difference is not independently additive to the runtime gap,
because address admission, dependencies, and retirement overlap it.

Decode also closes independently:

| Exclusive decode state | Banked post-window | Current normal 3P | Delta |
|---|---:|---:|---:|
| Decode progress | 51,490 | 29,119 | +22,371 |
| No decode: fetch empty | 5,072 | 4,494 | +578 |
| No decode: backend held | 30,666 | 13,826 | +16,840 |
| **Total cycles** | **87,228** | **47,439** | **+39,789** |

The large positive progress-cycle delta is again a throughput loss: the banked
backend consumes more cycles to admit the same program, so frontend work is
distributed over a longer schedule.

Finally, every zero-retirement cycle is assigned to one state of the oldest
retirement entry.  The trace scans all 32 configured window slots; an earlier
diagnostic version accidentally scanned only 16 and its `unknown` sub-bucket
was discarded.

| Exclusive zero-retirement state | Banked post-window | Current normal 3P | Delta |
|---|---:|---:|---:|
| Retirement queue empty | 648 | 612 | +36 |
| Head still unissued in the window | 7,664 | 3,106 | +4,558 |
| Head resident in active regload group | 8,963 | 0 | +8,963 |
| Head resident in pending regload group | 556 | 0 | +556 |
| Head load/store waiting for translation | 74 | 72 | +2 |
| Head load/store waiting to send access | 5,395 | 1,455 | +3,940 |
| Head load/store access in flight | 7,096 | 6,643 | +453 |
| Head memory op transiently absent from LSQ | 3,662 | 3,711 | -49 |
| Head issued non-memory op waiting to complete | 10,449 | 2,602 | +7,847 |
| Head state unknown | 0 | 0 | 0 |
| Head complete but GPR write ack withheld | 4,453 | 0 | +4,453 |
| Head otherwise ready | 113 | 99 | +14 |
| **Total zero-retirement cycles** | **49,073** | **18,300** | **+30,773** |

The remaining 9,016 cycles of the total runtime gap are positive-width retire
cycles: 38,155 banked versus 29,139 normal.  As with the issue partition, this
means the same retirement work is spread across more cycles, not that these
cycles are a separate stall source.

The hard-control result changes the previous priority.  The issue window does
speculate around branches, but the post-window register-load adapter defeats
part of that speculation by refusing the next address phase whenever a branch
or jump occupies its active group.  The directly observed offer-replay portion
is 10,528 hard-control cycles, plus 3,730 cycles where its single pending slot
is already full.  Removing or narrowing this barrier is ahead of another
forwarding bypass.  Correct recovery must poison younger active/pending groups
on redirect while continuing to drain every acknowledged register read; it
must not cancel a held request before ack.

A speculation-disabled ablation was attempted as managed run
`coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T042900Z`.  It does not
provide a performance number: with `SPECULATION_WINDOW=0`, the existing issue
window asserted `issue window overflow` at cycle 795 and validation ended
`fatal`.  The structural replay split above is therefore the valid evidence
for the hard-control barrier; no result is inferred from the failed ablation.

Final focused validation after branch recovery is
`3p-banked-directed-20260901T002704Z`.  It covers held bank retries,
address/issue overlap, back-to-back issue, pending-group promotion, EXU and
MEM0 forwarding, redirect drain, wrong-prediction follower removal, and a
correctly predicted branch/follower issue.  The final timed-DDR3 ACT4 result
is `compliance-act4-platform-3p-banked-ddr3-20260901T003018Z`: 93 passed, zero
failed, `validation=pass`, after a forced Verilator regeneration.  The final
CoreMark run above was also forced-regenerated and ended `validation=pass`.

#### Pipelined control admission and selective redirect recovery

The hard-control barrier was relaxed for issue-window traffic by allowing one
younger register-load group to occupy the pending credit while an active branch
or jump crosses the operand-read stage.  This is speculation of register reads
only.  GPR writes remain retirement-only, and a younger instruction cannot
write architectural register state from either the active or pending group.

Simply opening the credit was not correct.  Both the initial broad experiment
and the narrower control-only experiment reached the same LSQ timeout at cycle
15,047.  The final diagnostic run was
`coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T044856Z` and reported a
store with ID 99 waiting behind retirement head ID 79.  Its pipeline trace
showed the actual cause two cycles earlier:

| Trace cycle | Active group | Pending group | Redirect |
|---:|---|---|---|
| 5,027 | control ID 81 | empty | none |
| 5,028 | control ID 81 | IDs 79 and 84 | ID 81 |
| 5,029, before the fix | empty | empty | recovery |

The pending group straddled the redirect cut: ID 79 was older than the
resolving branch and ID 84 was younger.  Clearing the complete group discarded
the still-live older instruction, so retirement could never pass ID 79.  The
later store timeout was only the symptom.

Redirect recovery now filters active and pending state per lane using modular
instruction-ID age.  It preserves older lanes that did not issue on the
redirect edge, removes the resolving and younger lanes, filters their physical
pipe metadata, and recomputes the surviving hard/control classification.
Already acknowledged or held register-file requests are still poisoned and
drained to `quiescent`; preserved lanes with incomplete operands issue fresh
reads only after that drain.  This is required because the read response has a
fixed port association, whereas architectural writes need no rollback because
they occur only at retirement.

The final Sv39/DDR3 CoreMark run is
`coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T045452Z` and passed:

| Metric | Hard-control barrier | Selective control admission | Change |
|---|---:|---:|---:|
| Cycles | 87,228 | 79,225 | -8,003 (-9.17%) |
| Retired instructions | 52,588 | 52,588 | 0 |
| IPC | 0.6029 | 0.6638 | +10.10% |
| Gap to normal 3P (47,439 cycles) | 39,789 | 31,786 | -8,003 |
| Issue-window offer-replay cycles | 15,324 | 6,311 | -9,013 |
| Pending-credit-full replay | 3,730 | 3,634 | -96 |
| Hard branch / jump replay | 10,053 / 475 | 0 / 0 | -10,528 |
| Redirect RF-drain replay | 1,066 | 2,677 | +1,611 |
| Read-bank / read-write conflicts | 0 / 0 | 0 / 0 | 0 |

The 8,003-cycle runtime reduction closes 20.11% of the old 39,789-cycle gap to
normal 3P.  It is smaller than the 9,013-cycle replay reduction because the
new overlap changes downstream scheduling and increases redirect drain time.
The drain increase is expected from allowing more speculative read address
phases across control operations; it is now the complete residual control-side
replay bucket, rather than hidden hard-control serialization.

The zero-retirement partition changed as follows:

| Zero-retirement state | Before | After | Change |
|---|---:|---:|---:|
| Queue empty | 648 | 667 | +19 |
| Head unissued | 7,664 | 8,052 | +388 |
| Head in active regload | 8,963 | 7,585 | -1,378 |
| Head in pending regload | 556 | 592 | +36 |
| Memory translation / access / inflight | 74 / 5,395 / 7,096 | 74 / 5,183 / 6,808 | 0 / -212 / -288 |
| Memory transient | 3,662 | 3,140 | -522 |
| Issued non-memory execution wait | 10,449 | 7,317 | -3,132 |
| GPR write ack withheld at retirement | 4,453 | 5,119 | +666 |
| Otherwise ready | 113 | 113 | 0 |
| **Total zero-retirement cycles** | **49,073** | **44,650** | **-4,423** |

The main retirement improvement is no longer waiting for a non-memory head to
cross the serialized control/regload path.  Retirement-side write arbitration
became worse by 666 cycles and is still independent of speculative reads; it
remains a separate optimization target.

Focused validation is `3p-banked-directed-20260901T050426Z`
(`validation=pass`).  It directly seeds the observed pending IDs 79 and 84,
redirects at live retirement ID 81, and checks that all lane, operand, pipe,
producer, and use-valid metadata for only ID 79 survives.  Timed-DDR3 ACT4
validation is
`compliance-act4-platform-3p-banked-ddr3-20260901T045622Z`: 93 passed and zero
failed.  That ACT4 platform target currently has `ISSUE_WINDOW=0`, so it proves
the banked legacy/platform and DDR3 paths were not regressed; it does not cover
the new selective window recovery.  The passing Sv39 CoreMark run is the
end-to-end validation of the relaxed window path and reproduces the workload
that exposed the orphaned older lane before the fix.

#### Blocked-operand producer cross-tab

The scheduler-to-regload rejection was split from register-file arbitration by
classifying every unavailable window source operand by the current state of its
producer.  These are operand-cycle counts: several consumers and both operands
can contribute in one core cycle.  `unissued no offer` means the producer was
eligible but not selected, `unissued replay` means it was offered but the
post-window stage withheld its handshake, and `unissued fire` means it was
accepted on the sampled edge.  `regload pending` and `regload active` are the
two registered gather groups; `execution` is issued but not in either group and
not complete.

The source-matched runs are:

- banked: `coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T053508Z`,
  79,225 cycles, 52,588 retired, IPC 0.6638;
- normal 3P: `coremark-sv39-linux-rd32-ddr3-20260901T053746Z`,
  47,439 cycles, 52,592 retired, IPC 1.1086.

Both passed the Sv39 timed-DDR3 CoreMark check.  The banked register file
accepted 8,715 reads in 7,143 cycles and reported **zero read-grant conflict
events**.  Consequently, the 6,311 banked `offer_replay` cycles are not read
bank conflicts: 3,634 had the single pending group occupied and 2,677 were
redirect/quiescent drains.

| Producer state, all blocked operands | Banked load | Banked other | Normal load | Normal other |
|---|---:|---:|---:|---:|
| Unissued, ineligible | 366,884 | 596,342 | 170,866 | 282,235 |
| Unissued, eligible but not offered | 7,128 | 36,436 | 316 | 12,697 |
| Unissued, offered but replayed | 2,063 | 4,146 | 130 | 0 |
| Unissued, accepted this cycle | 16,678 | 29,111 | 15,955 | 24,566 |
| Regload pending group | 1,703 | 5,222 | 0 | 0 |
| Regload active group | 20,820 | 34,463 | 0 | 0 |
| Execution | 43,518 | 16 | 45,876 | 0 |
| Complete but operand unavailable | 0 | 0 | 0 | 0 |
| **Total** | **458,794** | **705,736** | **233,143** | **319,498** |

The banked run has 1,164,530 blocked operand-cycles, 22.144 per retired
instruction, versus 552,641 and 10.508 for normal 3P.  The direct issued
producer population is 105,742 banked versus 45,876 normal.  Of the banked
population, 62,208 operand-cycles are in the active or pending register-load
groups; execution itself is slightly lower than normal (43,534 versus 45,876).
The much larger difference is downstream magnification: unissued producers
account for 1,058,788 banked operand-cycles versus 506,765 normal.

The same cross-tab restricted to cycles with a nonempty window and no eligible
instruction makes that structure explicit:

| Producer state, no-eligible cycles | Banked load | Banked other | Normal load | Normal other |
|---|---:|---:|---:|---:|
| Unissued, ineligible | 202,623 | 288,672 | 78,684 | 116,576 |
| Regload pending group | 342 | 2,160 | 0 | 0 |
| Regload active group | 2,184 | 10,163 | 0 | 0 |
| Execution | 12,038 | 1 | 8,910 | 0 |
| **Total** | **217,187** | **300,996** | **87,594** | **116,576** |

Unissued/ineligible producers are 491,295 of 518,183 blocked operand-cycles on
banked no-eligible cycles (94.81%).  Active and pending regload groups are
14,849 (2.87%), and execution is 12,039 (2.32%).  Normal 3P is also dominated
by an unissued first-hop producer (95.64%), but at a lower density: 15.435
blocked operands per no-eligible cycle versus 18.996 banked.

This is not proof that the register-load stage causes only 2.87% of the stall.
The cross-tab follows one dependency edge.  A consumer often waits for an
unissued producer which is itself waiting on another producer, so added gather
latency is amplified down dependency chains and migrates into the
`unissued/ineligible` bucket.  The next diagnostic needs to follow each chain to
its issued root, rather than treating this first-hop state as a causal
partition.

#### Independent request pairs and four-bank geometry

The shared two-instruction register-load group was replaced by three
independent atomic two-source requesters.  Each requester holds an address
phase stable until the register file acknowledges the complete pair, retains
delayed response ownership by execution pipe and instruction ID, and latches
returned operands until its execution pipe accepts them.  A denied pair uses a
private retry skid; it does not reserve or block the other two requester pairs.
Redirect recovery preserves older output-latch state and drains or poisons
acknowledged and held younger transactions before trusting `quiescent`.

The source-matched two-bank run is
`coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T063649Z`.  It passed Sv39
CoreMark on timed DDR3 in 74,088 cycles at 0.7098 IPC.  Relative to the grouped
run at 79,225 cycles, this saves 5,137 cycles (6.48%).  Window replay fell from
6,311 to 3,239 cycles; the old pending-full bucket fell from 3,634 to zero.
The remaining 3,239 replay cycles were redirect/quiescent drain.  The new path
also issued three instructions in 3,020 cycles; the grouped path never issued
three-wide.

The banked storage geometry was then changed from 32 slots in two 16-entry
banks to 64 slots in four 16-entry banks.  Architectural tags remain p0-p31;
the upper 32 storage slots are reserved and currently unreachable.  Explicit
per-port zero extension preserves packed address boundaries as the internal
storage address widens from five to six bits.

The four-bank run is
`coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T064627Z` and passed the same
Sv39 timed-DDR3 check.  Focused validation is
`3p-banked-directed-20260901T064617Z` (`validation=pass`).  The RF test
deliberately oversubscribes one four-bank read bank, and the backend test
deliberately retires p1 and p29 into the same write bank; both verify retry and
forward progress instead of depending on incidental two-bank collisions.

| Metric | Two banks | Four banks | Change |
|---|---:|---:|---:|
| Cycles | 74,088 | 72,189 | -1,899 (-2.56%) |
| Retired instructions | 52,588 | 52,588 | 0 |
| IPC | 0.7098 | 0.7285 | +2.63% |
| Gap to normal 3P (47,439 cycles) | 26,649 | 24,750 | -1,899 |
| All bank-conflict cycles | 5,285 | 2,054 | -3,231 |
| Read-bank conflict cycles | 11 | 1 | -10 |
| Write-bank denied events | 5,274 | 2,053 | -3,221 |
| Write-request cycles | 31,511 | 28,476 | -3,035 |
| Accepted write events | 37,364 | 37,364 | 0 |
| Window redirect-drain replay | 3,239 | 2,303 | -936 |

The 5,274 two-bank write denials were real arbitration events, but they were not
5,274 independently exposed runtime cycles.  Four banks removed 3,221 denial
events while runtime improved by 1,899 cycles.  The zero-retirement partition
shows why: head write blocking fell by 3,221 cycles, but head execution wait
increased by 1,048 and memory-inflight wait increased by 192 as scheduling
shifted.  The net zero-retirement reduction was 2,125 cycles; changes in
one-wide and two-wide retirement cycles reduce the final runtime improvement
to 1,899.  Aggregate stall counters identify occupied states, not independent
causes, so subtracting a conflict count directly from runtime is invalid.

#### Oldest-first sliding write retirement

The initial four-bank write arbitration rotated priority between the two
retirement ports.  Instrumented run
`coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T065240Z` split its 2,053
same-bank dual-write cycles into 1,045 older-only grants and 1,008 younger-only
grants.  Different-bank pairs received both grants in 8,888 cycles and no pair
received neither grant.  This confirmed that the physical write ports were
independent, but also exposed inappropriate age rotation at the in-order
retirement boundary.

Register-file run `3p-banked-directed-20260901T065226Z` explicitly requested
simultaneous writes through ports zero and one to different banks and required
both acknowledgments in the same cycle.  It also checks that a same-bank pair
grants port zero, the older lane, before port one.  Fixed-priority CoreMark run
`coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T065544Z` reproduced exactly
the prior 72,189-cycle result while moving all 2,053 collisions into the
older-only bucket.  Priority alone therefore corrected policy but did not
remove the all-or-nothing retirement grouping.

The retirement wrapper now pre-arbitrates a known same-bank pair.  It presents
only the older address phase, accepts that instruction on its acknowledgment,
and leaves the unrequested younger instruction in the retirement queue.  The
queue advances at the edge, so the former younger instruction becomes port
zero and can issue alongside the newly exposed second entry next cycle.  The
younger request is suppressed before presentation rather than moved after a
withheld acknowledgment; this preserves the per-port requirement that request,
address, and data remain stable until acknowledgment.  Suppressed transactions
remain counted as write-bank capacity events.

Source-matched sliding run
`coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T070211Z` passed Sv39
CoreMark on timed DDR3.  Focused run
`3p-banked-directed-20260901T070201Z` also passed, including an explicit
same-bank older-only retirement followed by a shifted two-wide retirement.

| Metric | Fixed priority, grouped | Oldest-first sliding | Change |
|---|---:|---:|---:|
| Cycles | 72,189 | 72,047 | -142 (-0.20%) |
| Retired instructions | 52,588 | 52,588 | 0 |
| IPC | 0.7285 | 0.7299 | +0.19% |
| Same-bank write capacity events | 2,053 | 2,052 | -1 |
| Both write ports acknowledged | 8,888 | 9,637 | +749 |
| Older-only acknowledgments | 2,053 | 0 | -2,053 |
| Pre-arbitrated younger deferrals | 0 | 2,052 | +2,052 |
| Zero-retire cycles blocked by GPR writes | 2,053 | 0 | -2,053 |
| Zero-wide retirement cycles | 37,583 | 35,529 | -2,054 |
| One-wide retirement cycles | 16,624 | 20,448 | +3,824 |
| Two-wide retirement cycles | 17,982 | 16,070 | -1,912 |

The result is correct but small.  Removing 2,053 zero-retire write stalls does
not remove 2,053 total cycles: it converts the retirement-width distribution,
and the changed queue timing shifts issue, branch, fetch, and memory overlap.
The one-event conflict delta is likewise schedule drift, not evidence that the
physical bank geometry changed.  The measured end-to-end gain is 142 cycles;
the remaining CoreMark gap is not a grouped write-port bottleneck.

#### Two-bank sliding-retirement confirmation

Run `coremark-sv39-3p-banked-window-2r1w-2bank-ddr3-20260901T070857Z`
reduced the same 64 storage slots from four 16-entry banks to two 32-entry
banks.  The read bandwidth remained 2R per bank and the write bandwidth 1W per
bank.  It passed the same compact Sv39 CoreMark workload on timed DDR3.

| Metric | Two banks, sliding | Four banks, sliding | Two-bank delta |
|---|---:|---:|---:|
| Cycles | 73,090 | 72,047 | +1,043 (+1.45%) |
| Retired instructions | 52,588 | 52,588 | 0 |
| IPC | 0.7195 | 0.7299 | -1.42% |
| Legacy four-port read-conflict probe (incomplete) | 10 | 1 | +9 |
| Write-bank capacity events | 6,313 | 2,052 | +4,261 |
| Both write ports acknowledged | 6,672 | 9,637 | -2,965 |
| Pre-arbitrated younger deferrals | 6,313 | 2,052 | +4,261 |
| Zero-retire cycles blocked by GPR writes | 0 | 0 | 0 |
| Zero-wide retirement cycles | 34,361 | 35,529 | -1,168 |
| One-wide retirement cycles | 24,870 | 20,448 | +4,422 |
| Two-wide retirement cycles | 13,859 | 16,070 | -2,211 |

This confirms that the write ports are not subject to the former grouped
handshake.  Every same-bank pair was pre-arbitrated before request: the older
lane retired, the younger lane slid forward, and neither the aggregate
`gpr_write_blocked` counter nor the head-specific `head_write_blocked` counter
recorded a cycle.  Different-bank pairs still received two acknowledgments.

The read-conflict delta is not usable evidence for the independent requester.
That requester uses six RF ports and its own per-port held/response state, but
the probe still observes only `gpr_read_req[3:0]` and the legacy four-port
`banked_read_waiting` controller.  A read-side contribution to the two-bank
penalty therefore remains unmeasured.  The valid visible change is 4,261 more
same-bank dual-write opportunities.  Sliding absorbs those conflicts without
a zero-retirement write stall, but shifts useful retirement from two-wide to
one-wide.  Schedule changes also reduce zero-wide retirement by 1,168 cycles,
so the end-to-end penalty is 1,043 cycles rather than the raw write-conflict
delta.

#### Direct-GPR baseline without issue-window speculation

The current direct/asynchronous six-read GPR path was run with the same BP8,
completion forwarding, relaxed WAW, Sv39, cache, and timed-DDR3 controls.  The
non-speculative baseline disables both the issue window and its speculation
window.  This means no *issue-window* speculation; frontend prediction and
the LSU's internal speculative classifications remain enabled.

| Direct-GPR control | Cycles | Retired | IPC | Managed run |
|---|---:|---:|---:|---|
| Issue and speculation windows enabled | 47,439 | 52,592 | 1.1086 | `coremark-sv39-3p-magic-gpr-window-ddr3-20260901T074342Z` |
| Issue and speculation windows disabled | 63,716 | 52,592 | 0.8254 | `coremark-sv39-3p-magic-gpr-nospec-ddr3-20260901T074712Z` |

The strict non-windowed baseline is 16,277 cycles slower.  This delta combines
the issue scheduler and issue-window speculation because the intermediate
configuration is currently broken: run
`coremark-sv39-3p-magic-gpr-window-nospec-ddr3-20260901T074512Z`, with the issue
window retained and only `SPECULATION_WINDOW=0`, failed at cycle 1,134 with
`LSQ received unexpected store completion tag=5`.  It is not a benchmark
result and must not be used as an A/B data point.

Against the usable 63,716-cycle direct-GPR baseline, the speculative four-bank
banked result is 8,331 cycles slower and the speculative two-bank result is
9,374 cycles slower.  Those are useful system-level bounds, not isolated RF
latencies: `BANKED_GPR` also selects the registered operand-load path and
two-wide banked retirement, while the direct path has asynchronous reads and
three-wide normal retirement.

#### Counter decomposition against direct GPR

The apparent 8,331-cycle gap to the non-windowed direct-GPR baseline is the net
of two larger effects.  Enabling the direct-path issue-window package reduces
runtime by 16,277 cycles, from 63,716 to 47,439.  Selecting the four-bank GPR
path under those window controls then adds 24,608 cycles, to 72,047.  The first
delta cannot be split between scheduling and branch-crossing speculation
because the issue-window/no-speculation intermediate configuration fails the
LSQ assertion documented above.

The final source-matched counter runs are:

- direct asynchronous GPR with issue/speculation windows:
  `coremark-sv39-3p-magic-gpr-window-ddr3-20260901T102811Z`;
- four-bank 2R1W GPR with the same window controls:
  `coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T101224Z`.

Both passed the Sv39 timed-DDR3 CoreMark-derived check and reproduce 47,439
and 72,047 cycles respectively.

The issue-window counters give an exact, exclusive partition of the 24,608
cycle BANKED_GPR-path penalty:

| Issue-window state | Direct GPR | Four-bank GPR | Delta |
|---|---:|---:|---:|
| Empty | 1,467 | 1,592 | +125 |
| No eligible instruction | 13,228 | 24,390 | +11,162 |
| Eligible, no offer | 862 | 1,654 | +792 |
| Offer replayed | 420 | 2,229 | +1,809 |
| At least one instruction issued | 31,462 | 42,182 | +10,720 |
| Issued instruction events | 56,560 | 58,122 | +1,562 |
| Instructions per issuing cycle | 1.798 | 1.378 | -0.420 |

Those are window address-phase events.  Physical execution issue width shows
that banked issue is not limited to two, but it is substantially less dense:

| Physical issue width | Direct GPR | Four-bank GPR | Delta |
|---|---:|---:|---:|
| Zero | 15,557 | 29,861 | +14,304 |
| One | 12,323 | 29,293 | +16,970 |
| Two | 14,441 | 9,777 | -4,664 |
| Three | 4,635 | 3,116 | -1,519 |
| Four | 483 | 0 | -483 |
| Physical issue events | 57,042 | 58,195 | +1,153 |
| Instructions per physical-issue cycle | 1.789 | 1.379 | -0.410 |

The direct issue window can release four physical pipes even though decode is
three-wide; the banked requester is capped at three.  The larger loss is not
the absence of three-wide issue but the shift of 16,970 cycles into one-wide
issue.

The additional no-eligible cycles have overlapping predicates: RAW rises by
11,318 cycles, hard blocking by 10,271, and memory-order blocking by 9,930.
Those values cannot be added.  The replay increase is redirect drain: the
four-bank run records 2,229 redirect-drain replays, while the direct run's 420
replays are classified as other.  It is not a bank-conflict count.

Retirement exposes where the longer dependency and issue schedule becomes
architecturally visible.  The four-bank path has 17,229 additional zero-retire
cycles, partitioned exactly as follows:

| Additional zero-retire state | Cycles |
|---|---:|
| Issued head waiting for execution result | 7,918 |
| Head present but not issued | 4,781 |
| Memory head translated but access not sent | 3,671 |
| Memory head transiently absent from LSQ | 495 |
| Memory access inflight | 307 |
| Empty retirement queue | 41 |
| Other classified states | 16 |
| GPR write blocked | 0 |

The direct speculative path retires three-wide in 7,888 cycles; banked
retirement is capped at two.  That lost width is material, but 7,888 is not an
additive cycle penalty because the queue schedule and the one-/two-wide counts
change simultaneously.  Register writes are not the exposed bottleneck:
sliding retirement records zero head-write-blocked cycles.

The complete retirement-width distribution closes the 24,608-cycle runtime
delta without overlap:

| Retirement width | Direct GPR | Four-bank GPR | Delta |
|---|---:|---:|---:|
| Zero | 18,300 | 35,529 | +17,229 |
| One | 13,574 | 20,448 | +6,874 |
| Two | 7,677 | 16,070 | +8,393 |
| Three | 7,888 | 0 | -7,888 |
| At least one retirement | 29,139 | 36,518 | +7,379 |

Thus the banked two-wide retirement cap and changed queue schedule expose
7,379 more positive-retirement cycles.  The larger component remains the
17,229-cycle increase in zero-retirement cycles.  Of the latter, incomplete
head cycles rise from 17,589 to 34,763.  Their opcode split is:

| Incomplete retirement-head opcode | Direct GPR | Four-bank GPR | Delta |
|---|---:|---:|---:|
| ALU | 1,961 | 8,501 | +6,540 |
| Branch | 4 | 1,933 | +1,929 |
| Jump | 2,924 | 5,847 | +2,923 |
| Load | 8,674 | 11,007 | +2,333 |
| Store | 4,026 | 7,475 | +3,449 |
| **Total** | **17,589** | **34,763** | **+17,174** |

`head_unissued` means the oldest retirement entry is still resident in the
issue window with `issued_q=0`; it does not mean that every execution pipe is
empty.  The scheduler may issue younger eligible entries around it.  The
aggregate evidence is strong but not a direct cross-tab: on 19,552 of the
banked run's 34,763 incomplete-head cycles at least one younger entry was
already complete, versus 11,135 of 17,589 on the direct path.  A dedicated
`head_unissued` by current issue width/completed-behind cross-tab is still
needed to divide those 7,887 cycles exactly.

The matched speculative control also corrects the misleading comparison to
the non-windowed run.  Physical issued-minus-retired exposure is 4,450 events
on direct GPR and 5,607 on banked GPR, a difference of 1,157 rather than 5,607.
The banked run does not have materially more corrected conditional branches
(868 versus 884).  It keeps younger work exposed behind them for longer:
corrected-branch younger-release relationships rise from 3,966 to 5,159 and
younger-completed relationships rise from 2,644 to 4,363.  These are
branch-entry relationships, not unique wrong-path instructions.  The cause is
greater speculative depth across roughly the same misprediction population,
not an observed loss of predictor accuracy.

The direct-path issue-window package gain also has clear high-level evidence:
dispatch-full cycles fall from 52,168 to 857, backend-held cycles fall by
8,386, zero-retire cycles fall by 9,831, execution-port conflict cycles fall
from 4,200 to zero.  Separately, 23,282 issue releases occur behind at least
one unresolved conditional branch.  The larger 51,277 released and 35,210
completed resolution totals count branch-entry relationships, not unique
instructions.  These counters establish that the window is doing substantial
work, but do not isolate branch speculation from scheduler capacity.

Several older GPR-detail counters must be rewired before they can attribute the
remaining banked penalty.  `banked_read_bank_conflict`, read accept/conflict,
`blocked_on_reads`, writer-distance, and the stage-local no-issue split still
observe the legacy four-port/grouped controller.  The current six-port,
three-pair requester needs request/ack/response counters and per-requester held,
data-wait, output-backpressure, redirect-poison, and issue-fire states.  Until
that rerun exists, the valid conclusion is limited: the remaining banked cost
is concentrated in lower issue density, dependency no-eligibility, execution
completion latency at the retire head, memory-access launch delay, and the
two-wide retirement ceiling; the present counters do not separate their RF
causes reliably.

#### Atomic source-pair admission measurement

The register-file arbiter still grants each instruction's `rs1`/`rs2` requests
as an atomic pair.  Non-functional probes now replay every denied pair as two
independent requests at the exact arbitration point, against the slots already
consumed by older admitted pairs.  `partial_groups` counts denied pairs where
at least one source could have been accepted; `early_accept_operands` counts
those independently serviceable sources.  This is a conservative local
measurement: it identifies directly suppressed address phases but does not
predict how a different arbitration history would change later requests.

| Banks, ports per bank | Cycles | Denied pair cycles | Partial-opportunity cycles | Early source accepts | Held-pair cycles | Managed run |
|---|---:|---:|---:|---:|---:|---|
| 4 banks, 2R | 72,047 | 1 | 0 | 0 | 1 | `coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T101224Z` |
| 2 banks, 2R | 73,090 | 15 | 0 | 0 | 15 | `coremark-sv39-3p-banked-window-2r1w-2bank-ddr3-20260901T100922Z` |

Atomic pairing therefore exposes no independently serviceable source in this
CoreMark trace.  The denied-pair incidence is 0.0014% of four-bank cycles and
0.0205% of two-bank cycles.  This does not make atomic admission a good general
interface: it prevents retained partial operand progress and will behave worse
under denser six-read traffic.  It does show that removing it cannot explain
the current CoreMark gap.  In the same runs, reducing the file from four banks
to two raises denied write events from 2,052 to 6,313 while total runtime rises
by 1,043 cycles; those counts overlap pipeline effects and are not additive.

#### EX1 read-priority experiment

A source-matched experiment gave EX1 first consideration in the register-file
address arbiter whenever its selected requester needed at least one storage
read.  It changed only address-phase group order; response ownership and the
remaining requesters' age order were unchanged.  The experiment passed the
managed banked directed suite in
`3p-banked-directed-20260901T104736Z` and the Sv39 timed-DDR3 CoreMark-derived
run in
`coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T104832Z`.

| Four-bank 2R1W case | Cycles | Retired | EX1 read-request cycles | EX1 accepted | EX1 accepted during contention |
|---|---:|---:|---:|---:|---:|
| Rotating pair order | 72,047 | 52,588 | n/a | n/a | n/a |
| EX1-first pair order | 72,048 | 52,588 | 1,810 | 1,810 | 1 |

The result is null: runtime worsened by one cycle, and EX1 priority affected at
most the sole cycle in which any read pair was denied.  Physical issue events
were unchanged at 58,195; issue-window fire events changed from 58,122 to
58,123; incomplete retirement-head cycles changed from 34,763 to 34,765.  Such
one- or two-event schedule movement is not a performance signal.

The priority interface and arbiter override were therefore reverted after the
measurement.  EX1 priority cannot address the present branch selected-to-offer
loss either: that filtering occurs before register-file arbitration.  A future
workload with sustained read oversubscription could justify reconsidering
pipe-aware arbitration, but this CoreMark trace does not.

#### Removing the deferred early-control issue barrier

The post-selection register-load conversion originally classified every
conditional branch and jump as a hard issue-group barrier.  An early control
could enter the deferred-read boundary only when it was the oldest selected
packet, and then entered alone.  This was stricter than the normal 3P issue
contract.  The independent requester now preserves accepted packets older than
the redirecting instruction by ID and poisons younger or stale RF responses,
so early branches and deterministic direct jumps no longer use that barrier.
Persistent hard operations such as faults, fences, and system instructions
remain isolated.

The source-matched Sv39 timed-DDR3 CoreMark-derived result is:

| Four-bank 2R1W issue-window case | Cycles | Retired | IPC | Managed run |
|---|---:|---:|---:|---|
| Early controls isolated | 72,047 | 52,588 | 0.7299 | `coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T101224Z` |
| Early controls issue normally | 69,991 | 52,589 | 0.7514 | `coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T110127Z` |

This recovers 2,056 cycles, or 2.85% of the previous runtime.  Branch
completion-wakeup selection now reaches the scheduler offer on 7,795 of 7,961
events (97.91%), versus 5,273 of 7,644 (68.98%).  Same-edge branch releases
increase by 2,522.  The remaining 166 selected-to-offer losses can come from
the three-wide age cap or active redirect recovery; they are not RF denials.
Every one of the 7,795 offered wakeup-edge branches was accepted.

The fresh normal-3P, direct-GPR, issue-window-disabled control is
`coremark-sv39-3p-magic-gpr-nospec-ddr3-20260901T110658Z`.  It reproduces
63,716 cycles, 52,592 retired instructions, and 0.8254 IPC.  The remaining
banked gap is therefore 6,275 cycles (9.85%), down from 8,331 cycles.

The retirement-width partition closes that gap exactly:

| Retirement width | Normal 3P, window 0 | Banked window | Delta |
|---|---:|---:|---:|
| Zero | 28,131 | 33,858 | +5,727 |
| One | 21,491 | 19,677 | -1,814 |
| Two | 11,181 | 16,456 | +5,275 |
| Three | 2,913 | 0 | -2,913 |
| At least one retirement | 35,585 | 36,133 | +548 |

Thus 5,727 cycles of the 6,275-cycle runtime delta are extra zero-retire
cycles.  The remaining 548 cycles are extra productive cycles required by the
changed width distribution, including the banked two-wide retirement ceiling.
Within the zero-retire delta, empty-queue cycles improve by 2,157 while
nonempty/no-retire cycles worsen by 7,884.  The latter divides into 7,870
additional incomplete-head cycles and 14 other ready-head cycles.  Neither run
records a retirement-head GPR-write stall.

The incomplete retirement-head opcode partition is:

| Head opcode | Normal 3P, window 0 | Banked window | Delta |
|---|---:|---:|---:|
| ALU | 1,408 | 7,273 | +5,865 |
| Conditional branch | 2,015 | 1,343 | -672 |
| Jump | 1,462 | 5,847 | +4,385 |
| Load | 14,192 | 11,350 | -2,842 |
| Store | 6,152 | 7,286 | +1,134 |
| **Total** | **25,229** | **33,099** | **+7,870** |

Branch-head delay is now better than the strict control; it is no longer the
remaining deficit.  The positive excess is ALU completion exposure, jump
completion exposure, and stores, partly offset by lower branch and load head
waits.  The state-specific `head_exec_wait` and `head_unissued` fields are not
directly comparable because the strict path lacks issue-window state and
classifies 4,885 cycles as unknown; the opcode partition is comparable.

Physical issue also shows the different speculation model.  The banked window
issues 59,378 instructions for 52,589 retired, while strict normal 3P issues
52,593 for 52,592 retired.  The 6,788-event difference in issued-minus-retired
exposure is speculative or otherwise discarded work, not an additive cycle
penalty.  It accompanies 2,254 more redirects, including 320 more corrections.
Despite that, post-redirect empty time rises by only 365 cycles and normalized
empty time improves from 523 to 437 cycles per thousand redirects.  LSU request
wait falls from 1,494 to 1,022 cycles, execution-port conflicts fall from 4,200
to zero, and the banked RF records only one denied read pair.  These counters
rule out branch-head delay, LSU request backpressure, execution-port conflicts,
and RF read-bank conflicts as the dominant remainder; they do not by themselves
separate the extra register-load latency from retirement width and speculative
schedule effects.

Validation after the change:

- `3p-banked-window-focused-20260901T110115Z` passed the independent requester
  and redirect-survivor regression;
- `3p-banked-directed-20260901T110413Z` passed the complete managed banked
  directed suite;
- `compliance-act4-platform-3p-banked-ddr3-20260901T110445Z` passed all 93
  preserved RV64IMA ACT4 tests with the platform target corrected to enable
  the banked issue and speculation windows.

## Tomasulo physical-register bring-up

The first physical-register configuration uses p0-p63, four banks with two
read ports and one write port per bank, completion-time PRF writes, retirement
RRAT commit/free, and the independent six-read address/data pipeline.  These
runs deliberately disable the older architectural completion and branch
forwarding knobs.  They use the compact bare-metal CoreMark-derived loop
through L1, ICX, L2, and timed DDR3; they are correctness and relative-cycle
measurements, not official CoreMark scores.

| Tomasulo configuration | Cycles | Retired | IPC | Managed run |
|---|---:|---:|---:|---|
| Strict, depth 16, speculation disabled | 101,699 | 52,563 | 0.5168 | `coremarks-compact-3p-tomasulo-strict-ddr3-20260901T201554Z` |
| Window 16, speculation enabled | 102,372 | 52,563 | 0.5135 | `coremarks-compact-3p-tomasulo-window16-ddr3-20260901T201652Z` |
| Window 32, speculation enabled | 101,604 | 52,563 | 0.5173 | `coremarks-compact-3p-tomasulo-window32-ddr3-20260901T203100Z` |

All three runs reached the expected `a0=0x0a277880` result.  Window depth and
control speculation do not improve this unforwarded configuration: depth 32
is only 95 cycles faster than strict and depth 16 is 673 cycles slower.  That
is a measured result, not evidence that the speculative machinery is idle.
The corrected depth-32 counters record 60,752 crossings of unresolved
conditional branches; 10,471 of 10,785 resolutions had younger issued work,
and 9,198 had younger completed work.

Against the source-matched normal-3P compact control above, depth-32 Tomasulo
adds 22,286 cycles (101,604 versus 79,318).  Normal 3P issues 52,565
instructions for 52,563 retired; Tomasulo issues 74,835 for the same 52,563
retired.  The 22,270-event increase in issued-minus-retired exposure nearly
equals the runtime increase, while zero-retire cycles increase by 22,357
(64,709 versus 42,352).  This is discarded/speculative work, not direct proof
that every extra issue costs one cycle.  In fact the strict Tomasulo control
takes 101,699 cycles while issuing only 52,910 instructions, so it rules out
discarded work as the cause of the base 22-thousand-cycle regression.  The
depth-32 result instead shows that current speculation consumes otherwise idle
issue capacity without hiding the older-head latency.  The
incomplete-head population rises from 38,765 to 64,446 cycles and completed
work behind that head rises from 9,039 to 39,263 cycles.  Completion/load
forwarding is disabled in these first runs, and the banked path adds the
register-load stage; those are stronger immediate suspects than PRF capacity.

The depth-32 physical free pool reached a minimum of two tags but never became
empty.  A split counter records zero destination-offer stalls from physical-tag
shortage and 4,647 from downstream allocation backpressure.  In this path that
downstream gate is the conservative retirement-queue capacity check, which
stops admission above 30 occupied entries so a complete two-instruction group
still fits.  The current result therefore does not support attributing the
slowdown to the 32 spare physical tags.  The register count remains tight in
principle, but the ROB capacity gate fires first.  Other current depth-32
counters are 2,910 bank-conflict cycles (556 read, 2,364 write), 652 denied
atomic source-pair cycles, 42,677 cycles with register-read activity, and
64,446 incomplete retirement-head cycles.  These populations overlap and are
not additive.

Selective recovery required more than a RAT and free-bitmap snapshot.  A tag
can be busy at a branch checkpoint, retire and become free while the branch is
live, then be reused by younger work.  Recovery now tracks all allocations
after each live checkpoint, reclaiming that recycled tag as well.  The focused
renamer test explicitly exercises this sequence in addition to same-bundle
WAW mapping, two-wide retirement recycling, and RRAT-based full flush.

The dedicated DDR3 ACT4 target passed all 93 preserved RV64IMA tests in
`compliance-act4-platform-3p-tomasulo-ddr3-20260901T202115Z`.  The existing
identity-renamed banked dispatch, backend, and top smoke controls also passed
in `3p-banked-smoke-20260901T202942Z`.

#### Sv39 branch-survival correction

The compact bare-metal measurements above execute in M-mode.  They are valid
register-pipeline measurements, but they are the wrong experiment for judging
branch speculation: `rv64_top_3p.v` deliberately makes M-mode controls
effectively predicted not-taken because the current partial-tag indirect BTB
is not context-safe across translated S-mode and physical M-mode addresses.
Taken loop branches therefore correct and discard their sequential followers
even when the direction predictor learned the loop.  No M-mode predictor
relaxation is included in the implementation.

The source-matched rerun uses the finite CoreMark-derived Sv39 workload and
requires both `satp_sv39=1` and supervisor execution.  All cases use the same
four-bank 2R1W file, BP8 frontend, cache hierarchy, and timed-DDR3 platform.

| Sv39 configuration | Cycles | Retired | IPC | Managed run |
|---|---:|---:|---:|---|
| Tomasulo, speculative issue disabled | 91,690 | 52,589 | 0.5736 | `coremark-sv39-3p-tomasulo-strict-ddr3-20260901T211509Z` |
| Tomasulo, 32-entry speculative window | 68,364 | 52,589 | 0.7692 | `coremark-sv39-3p-tomasulo-window32-ddr3-20260901T210750Z` |
| Identity rename, banked speculative window | 69,991 | 52,589 | 0.7514 | `coremark-sv39-3p-banked-window-2r1w-ddr3-20260901T110127Z` |
| Normal 3P, direct GPR, window disabled | 63,716 | 52,592 | 0.8254 | `coremark-sv39-3p-magic-gpr-nospec-ddr3-20260901T110658Z` |

Speculative Tomasulo saves 23,326 cycles, or 25.44%, against its strict Sv39
control.  It is also 1,627 cycles faster than the identity-renamed banked
window.  The remaining gap to the normal direct-GPR/window-disabled control is
4,648 cycles; that comparison still includes the registered register-load
stage and two-wide banked retirement ceiling.

The branch counters directly reject the hypothesis that correct speculative
work is discarded when a branch retires:

| Conditional-resolution outcome | Strict | Speculative |
|---|---:|---:|
| Correct | 9,903 | 9,911 |
| Correct with younger issued work | 5 | 9,824 |
| Correct with younger completed work | 0 | 9,356 |
| Corrected | 883 | 875 |
| Corrected with younger issued work | 0 | 863 |
| Corrected with younger completed work | 0 | 818 |

Thus 99.12% of correctly predicted conditional resolutions have younger issued
work and 94.40% have younger completed work.  Correct resolution merely marks
the resident branch complete; it does not drive `squash_frontend_i`.  A real
direction or target correction drives selective recovery, preserving the
resolving control and older IDs while discarding only younger IDs.

The cycle effect is correspondingly large.  With speculation enabled,
nonempty/no-retire cycles fall from 53,718 to 33,465 and incomplete-head cycles
fall from 53,605 to 33,352.  Scheduler fire events rise from 53,659 to 61,286,
so this is useful overlap rather than an apparent gain from doing less work.
The Sv39 data supports selective branch survival; the earlier M-mode near-null
result was an execution-context artifact.

#### Scheduler/ROB lifetime split

The Tomasulo issue scheduler and retirement queue now have independent storage
lifetimes and independently configurable depths.  A scheduler entry is freed
when its selected operation is accepted by the downstream execution or
register-load path.  The corresponding retirement record remains in its ROB
slot until architectural retirement.  Scheduler entries therefore carry an
explicit ROB-slot tag, free-slot allocation no longer aliases the ROB ring,
and oldest-first selection compares instruction IDs rather than scheduler-slot
positions.  Issued hard barriers retain a separate token until retirement so
releasing their scheduler entries does not accidentally relax serialization.
The public 3P core, top-level wrappers, platform, testbench, and managed build
parameters expose `ISSUE_WINDOW_DEPTH` separately from `RETIRE_DEPTH`.

The focused Tomasulo stream test was also run with a 16-entry ROB and an
8-entry scheduler.  It requires both scheduler occupancy below ROB occupancy
and exact reuse of a scheduler slot while that slot's prior instruction is
still live in a different ROB record.  That check passed in
`3p-banked-tomasulo-window-stream-20260901T225950Z`; it is direct evidence of
the intended lifetime split rather than an inference from aggregate counts.
The equal-depth Tomasulo and identity controls passed in
`3p-banked-tomasulo-window-stream-20260901T225234Z` and
`3p-banked-window-focused-20260901T225303Z`, respectively.

The source-matched Sv39 result is deliberately negative on performance:

| ROB entries | Scheduler entries | Cycles | Retired | IPC | Rename blocked: tags / downstream | Managed run |
|---:|---:|---:|---:|---:|---:|---|
| 32 | 32 | 68,396 | 52,589 | 0.7689 | 0 / 23,010 | `coremark-sv39-3p-tomasulo-window32-ddr3-20260901T225452Z` |
| 64 | 32 | 68,386 | 52,589 | 0.7690 | 5,393 / 0 | `coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-20260901T230125Z` |

Increasing only the ROB saves 10 cycles, or 0.015%.  It moves the allocation
limit from ROB capacity to the 63-entry physical-register pool: the 64/32 run
records 3,853 cycles with no free physical tag and a minimum free count of
zero.  Scheduler fire events rise from 61,143 to 63,686, but incomplete
retirement-head cycles barely move (33,379 to 33,275).  Thus the split works,
but a deeper ROB alone does not hide the current head latency or approach the
normal-3P target.  More physical registers are required to exercise a 64-entry
ROB fully; even that is a capacity experiment, not evidence that retirement
latency will improve.

The platform ACT4 target now instantiates the geometry it already described:
64 ROB entries and 32 scheduler entries, rather than the former accidental
32/32 configuration.  All 93 preserved RV64IMA tests passed through L2 and
timed DDR3 in
`compliance-act4-platform-3p-tomasulo-ddr3-20260901T230726Z`.
