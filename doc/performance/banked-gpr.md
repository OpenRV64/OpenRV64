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

Final focused validation after branch recovery is
`3p-banked-directed-20260901T002704Z`.  It covers held bank retries,
address/issue overlap, back-to-back issue, pending-group promotion, EXU and
MEM0 forwarding, redirect drain, wrong-prediction follower removal, and a
correctly predicted branch/follower issue.  The final timed-DDR3 ACT4 result
is `compliance-act4-platform-3p-banked-ddr3-20260901T003018Z`: 93 passed, zero
failed, `validation=pass`, after a forced Verilator regeneration.  The final
CoreMark run above was also forced-regenerated and ended `validation=pass`.
