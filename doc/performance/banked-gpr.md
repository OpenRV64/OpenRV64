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
