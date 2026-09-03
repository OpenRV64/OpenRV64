# `tb_top_3p_soc` Tomasulo profile

## Linux bring-up harness

Full-system bring-up uses a separate compiled harness identity:

```text
tb/tb_4h_3p_tomasulo.sv
run/cfg/linux-l1-tomasulo-1h-ddr3.cfg
```

Its configuration is composed as an explicit backend hierarchy:

```text
common/opensbi-4h-3p-banked.inc
  -> common/opensbi-4h-3p-tomasulo.inc
    -> common/opensbi-4h-3p-tomasulo-rob64-sched32-pr63.inc
      -> linux-l1-tomasulo-1h-ddr3.cfg
```

The final configuration also sources the existing one-hart L1, Zbb,
M-mode-prefetch, timed-DDR3 Linux workload configuration.  Thus register-file
selection, Tomasulo policy, queue/register geometry, and Linux workload policy
remain independently visible instead of being collapsed into one argument
list.

The source is intentionally a thin derivative of `tb_4h_3p`: it defines the
Tomasulo-harness policy and includes the existing coherent platform, devices,
DDR3 model, and checkpoint hierarchy.  This avoids maintaining a divergent
copy of roughly 5,500 lines while still producing a distinct Verilator model
and build directory.  Tomasulo-only diagnostics and memory-model behavior are
guarded by `OPENRV64_TOMASULO_HARNESS`; the baseline 3P Linux model does not
enable them.

The initial one-hart profile is 64 ROB entries, 32 scheduler entries, 63
physical registers, a four-bank 2R1W PRF, Sv39-capable Linux platform support,
and the timed DDR3 backend.  It records a resumable checkpoint at 25 million
cycles because a complete timed-DDR3 boot is a multi-hour simulation.  Run it
through the managed runner:

```sh
run/run run/cfg/linux-l1-tomasulo-1h-ddr3.cfg
```

The installed testbench RAM is smaller than the architectural normal-memory
PMA aperture.  A recoverable wrong-path load may therefore address normal
memory that is absent from this particular model.  The Tomasulo harness lets
the DDR endpoint return AXI `DECERR`, which selective LSU recovery must drain
without retiring a fault.  The baseline harness retains its out-of-range fatal
check.  A focused backend regression also covers a predicted-not-taken JALR,
an outstanding younger load, selective squash, and a late bus-error response.

Until a managed run reaches a literal `openrv64# ` prompt with a passing
runner result, this is Linux bring-up evidence, not a Linux-boot claim.

PMP writes use literal full flushes on both sides of the mutation.  The first
endpoint presentation is suppressed and flushes back to the PMP instruction;
only its replay may update the CSR.  Because the banked CSR completion is
acknowledged one cycle before architectural retirement, the second flush is
delayed to the retirement edge and restarts after the instruction.  The
scheduler's persistent-hard token additionally prevents younger issue across
either attempt.  The focused `3p-tomasulo-pmp-directed` configuration probes
and restores eight PMP address CSRs and checks that every accepted update has
exactly one suppressed pre-flush and one post-retirement flush.  SATP keeps its
existing acceptance-edge flush until a failing case demonstrates that it needs
the same treatment.  Managed run
`3p-tomasulo-pmp-directed-20260903T031106Z` passed all 16 write/replay pairs.
The current target-correction interface was recompiled through the same full
top and re-passed in `3p-tomasulo-pmp-directed-20260903T100438Z`.
The non-Tomasulo 3P integration suite also passed with the shared top-level
logic in `lsu-xlate-generation-3p-20260903T031932Z`.

## RV64A ordering regression

The initial full Linux run reached the supervisor kernel, then timed out with
an `sc.d.rl` at the ROB head but absent from the LSQ.  A cycle trace showed an
age inversion rather than a dropped transaction: while the older SC waited for
its input branch, four younger LR operations were classified as speculative
ordinary loads and filled the four-entry LSQ.  The LSQ correctly refused to
execute those younger atomics before the SC, leaving no slot in which the SC
could be issued.

The decode metadata is asymmetric: LR is read-only and SC is write-only, while
read-modify-write AMOs set both bits.  Therefore `MEM_READ && !MEM_WRITE` and
`MEM_WRITE && !MEM_READ` are not sufficient tests for ordinary replayable
loads and stores.  The Tomasulo scheduler now excludes the complete AMO opcode
class from both speculation paths.  RV64A requests remain age ordered; ordinary
loads and stores retain selective speculation.

The exact Sv39/timed-DDR3 reproducer is:

```text
run/cfg/lrsc-redirect-stress-sv39-3p-tomasulo-ddr3.cfg
```

It repeatedly executes an LR followed by an intentionally failing SC to a
different address, with a branch on the SC result.  Managed run
`lrsc-redirect-stress-sv39-3p-tomasulo-ddr3-20260903T030000Z` passed 4,096
iterations: 8,192 atomic starts and 8,192 completions, with no LSQ timeout.
`branch-gated-load-3p-tomasulo-ddr3-20260903T030327Z` separately passed with
32,767 speculative ordinary loads, confirming that the opcode exclusion did
not globally disable load speculation.  The broader
`atomic-sv39-3p-tomasulo-ddr3-20260903T031703Z` smoke also passed its expected
signature with 30 atomic starts and 30 completions under active Sv39.

## Name and purpose

The current performance/correctness test is the **Tomasulo 64/32 Sv39 DDR3
profile**.  It uses the generic `tb_top_3p_soc` system testbench with this
managed configuration:

```text
run/cfg/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3.cfg
```

`tb_top_3p_soc` is not Tomasulo-specific RTL.  It is the parameterized full-SoC
harness in `tb/tb_top_3p_soc.v`.  The managed configuration selects the
Tomasulo rename/dispatch implementation and fixes the profile described below.
Keeping that distinction matters when comparing results: a testbench name alone
does not identify the backend configuration.

The workload is the finite CoreMark-derived `coremark_loop` extract running in
Sv39 supervisor mode.  This profile is intended to expose issue, physical-tag,
ROB, register-bank, retirement, cache, and DDR3 timing effects in one repeatable
run.  It is not an official CoreMark score and it is not a Linux boot.

## Managed invocation

Run it through the repository runner:

```sh
run/run run/cfg/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3.cfg --foreground
```

`--foreground` is the known reliable form for this inherited configuration.  A
run is successful only when `run/run` records `validation=pass`, the simulator
exits with zero status, `a0` equals `0x000000000a277880`, and the log ends with:

```text
PASS: 3P L1I/L1D -> ICX -> L2 -> AXI -> banked DDR3
```

The runner records the effective configuration, ordered make arguments, source
hashes, dirty-worktree patch, build log, and run log under `run/log/<run-id>/`.
Use `effective-config.txt`, not a single inherited `.cfg` file, when auditing a
result.

## Per-instruction resident-state trace

The trace-enabled derivative is:

```text
run/cfg/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-trace.cfg
```

It records cycle-stamped FETCH, DECODE, scheduler, deferred register-read,
execution, completion, LSQ, ROB, and retirement residency for each dynamic
instruction.  It also records a stable numeric primary block reason and, when
the cause is a unique older instruction or producer, that instruction's ID.
The schema, code tables, invocation, and current reconstruction limits are in
[`doc/tomasulo_pipeline_trace.md`](../tomasulo_pipeline_trace.md).

## Branch-oracle A/B

Two managed derivatives provide a simulation-only perfect-architectural-branch
experiment:

```text
run/cfg/coremark-sv39-3p-tomasulo-oracle-capture-ddr3.cfg
run/cfg/coremark-sv39-3p-tomasulo-oracle-ddr3.cfg
run/cfg/coremark-sv39-3p-tomasulo-oracle-trace-ddr3.cfg
run/cfg/coremark-sv39-3p-tomasulo-oracle-magic-l1i-trace-ddr3.cfg
```

First run the capture configuration.  It records and compresses the full
resident-state trace, then writes `branch-oracle.memh` into that managed run
directory.  The file contains one checked `{pc, taken, next_pc}` record per
architecturally retired conditional branch, JAL, or JALR.  Replay requires the
absolute artifact path and record count, for example:

```sh
run/run run/cfg/coremark-sv39-3p-tomasulo-oracle-ddr3.cfg --foreground \
  CORE_3P_ICX_L2_BRANCH_ORACLE_PATH=/absolute/run/log/<capture>/branch-oracle.memh \
  CORE_3P_ICX_L2_BRANCH_ORACLE_COUNT=12696
```

Replay maintains committed and speculative tape positions.  A redirect or
memory-order replay reconstructs the speculative position by walking surviving
ROB controls in age order; it does not permanently consume records belonging to
squashed work.  Retirement checks PC, direction, and target for every record.
The test fails on a mismatch, missing record, incorrect result, or incomplete
tape.

Oracle mode supplies direction and target to matching frontend controls and
removes the real predictor's finite bookkeeping stalls and training.  Controls
on a transient wrong path do not consume the architectural tape.  This makes
the result an optimistic simulation bound, not a synthesizable predictor or a
claim that BTB/RAS storage is unnecessary.

The current passing A/B is 43,881 cycles/1.1984 IPC for BP8 versus 42,585
cycles/1.2349 IPC for the oracle.  The oracle retired all 12,696 records, used
502 rollback repairs, and rewound 2,544 speculative records.  Detailed counter
comparison and run IDs are in
[`doc/performance/banked-gpr.md`](../performance/banked-gpr.md).

The `oracle-magic-l1i-trace` derivative is the compatible fetch-memory
isolation for this Sv39 profile.  It returns L1I line fills immediately but
does not bypass the frontend or the L1I request/response machinery.  It passed
at 42,372 cycles/1.2411 IPC, only 213 cycles faster than the ordinary oracle;
the trace attributes the surviving fetch-empty population mainly to internal
pending/turnaround behavior rather than exposed external misses.

## Profile definition

| Area | Effective setting |
|---|---|
| Core/backend | 3P backend, `RENAME_MODE=1` (Tomasulo) |
| Physical register tags | `PHYS_REG_COUNT=63`: p0 is reserved; p1-p63 are usable |
| ROB | 64 entries |
| Scheduler | 32 entries |
| Scheduling | issue window and speculation window enabled |
| Integer PRF | 4 banks, 2 read ports and 1 write port per bank |
| PRF implementation | banked GPR enabled, FPGA LUTRAM mode disabled |
| Completion forwarding | mask 7: EX0, EX1, and registered load-only MEM0 |
| Branch forwarding | disabled (`BRANCH_FORWARD_MASK=0`) |
| Hazard policy | relaxed WAW enabled; general relaxed hazards disabled |
| Stores | posted stores enabled |
| Frontend | BP8, 3P fetch carousel, confidence gate, pair-stack depth 2 |
| Translation | Sv39 and supervisor execution required; 256-entry, 4-way TLB |
| L1 | 16 KiB L1I and 16 KiB L1D |
| L2 | 256 KiB, 8 ways, 8 MSHRs |
| Main memory | 16 MiB through the banked/timed DDR3 model |
| DDR queues | 8 read, 8 write, 16 command entries |
| Timeout | 1,000,000 simulated cycles |

The relevant configuration inheritance is:

```text
coremark-sv39-3p-tomasulo-rob64-sched32-ddr3.cfg
  -> coremark-sv39-3p-tomasulo-window32-ddr3.cfg
  -> coremark-sv39-3p-banked-window-2r1w-ddr3.cfg
  -> coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3.cfg
  -> coremark-sv39-3p-banked-2r1w-exu-forward-ddr3.cfg
  -> coremark-sv39-3p-banked-2r1w-ddr3.cfg
  -> coremark-sv39-3p-banked-ddr3.cfg
  -> coremark-sv39-linux-rd32-ddr3.cfg
```

The intended storage split is a 32-entry execution scheduler in front of a
64-entry ROB.  An instruction releases its scheduler slot when it is issued
into execution; its ROB entry remains until retirement.  Consequently the
machine should become physical-register- or ROB-limited without requiring a
64-entry scheduler.

## Simulated hierarchy

The profile exercises this path:

```text
3P core
  -> private L1I/L1D
  -> interconnect
  -> shared L2
  -> AXI memory channel
  -> banked DDR3 timing model
```

The program uses Sv39 mappings and supervisor privilege.  The pass therefore
checks substantially more than the standalone scheduler or backend tests, but
it remains simulation evidence.  It does not establish synthesis timing,
physical FPGA behavior, Linux boot, or complete architectural compliance.

## Counter contract

The testbench prints one final snapshot of the major pipeline and memory
counters.  The primary groups for this profile are:

| Counter family | What it measures |
|---|---|
| `PERF_ICX_L2_WIDTH` | issue, decode, and retire width histograms |
| `PERF_ICX_L2_PIPE_DECODE` | decode progress and frontend/backend holds |
| `PERF_ICX_L2_BACKEND` | dispatch occupancy and broad issue blockers |
| `PERF_ICX_L2_TOMASULO_WINDOW` | Tomasulo scheduler occupancy, eligibility, issue, rename, and free-tag pressure |
| `PERF_ICX_L2_TOMASULO_JALR*` | JALR scheduler release, pre-head resolution, and younger work crossing an unresolved JALR |
| `PERF_ICX_L2_BP_TARGET`, `JALR_PREDICT` | BTB/RAS outcomes, JALR corrections, and younger ROB residency at JALR resolution |
| `PERF_ICX_L2_BANKED_GPR*` | PRF read/write accepts, bank conflicts, retry, and register-access stalls |
| `PERF_ICX_L2_RETIRE` | nonempty ROB cycles, zero-retire cycles, incomplete head, and completed work behind the head |
| `PERF_ICX_L2_PIPE_RETIRE_ZERO` | mutually exclusive zero-retire attribution |
| `PERF_ICX_L2_RETIRE_HEAD*` | instruction class and coarse state of an incomplete ROB head |
| `PERF_ICX_L2_LSU`, `SPEC_LOAD*`, `SPEC_STORE*` | LSQ throughput, waits, squash, and outcome |
| `PERF_ICX_L2_FETCH*`, `REDIRECT*`, `POST_REDIRECT*` | frontend availability and redirect recovery |
| `PERF_MEMORY*` | AXI/DDR queues, commands, rows, refresh, and utilization |

`PERF_ICX_L2_WINDOW` and `PERF_ICX_L2_PIPE_WINDOW` describe the older banked
issue-window path and are zero in Tomasulo mode.  Use
`PERF_ICX_L2_TOMASULO_WINDOW` for this profile.  Some branch-resolution fields
inside the Tomasulo group are not yet connected: the reference run reports
large branch crossings but zero resolutions while the LSU and frontend report
real branch activity.  Those zero fields are an instrumentation gap, not proof
that no speculation occurred.

### Incomplete-head classification

When the ROB is nonempty and retires nothing because its head is incomplete,
the testbench assigns the head to exactly one instruction class:

```text
ALU, multiply, divide, branch, jump, load, store,
atomic, system, fence, or unknown
```

It also assigns the same cycle to exactly one coarse state:

- `UNISSUED`: the head still has a scheduler entry.
- `REGLOAD`: the head is visible in the retained legacy register-load stage.
- `MEMORY`: the head was released and is in memory/LSQ processing.
- `EXECUTE`: the head was released, is non-memory, and is not complete.

Simulation assertions require the instruction-class sum and the class/state
cross-tab sum to equal `PERF_ICX_L2_RETIRE head_incomplete` exactly.

`EXECUTE` is deliberately a coarse label.  The independent Tomasulo register
read requesters do not retain a head-ID-visible address/data record, so some
register-read latency can land in `UNISSUED` or `EXECUTE`.  It is not a pure
execution-unit latency counter.  `REGLOAD=0` is expected for the independent
Tomasulo requester path; it does not prove zero register-read latency.

## Reference result

The current source-matched reference includes speculative JALR release and
physical-tagged ALU and load completion wakeup:

```text
coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-20260902T050217Z
```

| Metric | Result |
|---|---:|
| Cycles | 52,107 |
| Retired instructions | 52,589 |
| IPC | 1.0093 |
| Issue width 0 / 1 / 2 / 3 | 13,044 / 15,461 / 19,952 / 3,650 cycles |
| Retire width 0 / 1 / 2 / 3 | 19,471 / 12,683 / 19,953 / 0 cycles |
| ROB nonempty, no retire | 18,926 cycles |
| Incomplete ROB head | 18,813 cycles |
| Completed instructions behind head | 17,118 cycles |
| GPR-write-blocked retirement | 0 cycles |
| Rename blocked by physical tags | 6,767 cycles |
| Free-list empty | 5,711 cycles |
| Completion wakeup operands / entries | 19,434 / 19,352 |
| Wakeup operands from EX0 / EX1 / MEM0 | 10,678 / 1,836 / 6,920 |

The incomplete-head cross-tab for that run is:

| Head instruction | Total | Unissued | Register-load | Memory | Execute |
|---|---:|---:|---:|---:|---:|
| Load | 7,142 | 167 | 0 | 6,975 | 0 |
| Store | 7,196 | 26 | 0 | 7,170 | 0 |
| ALU | 2,454 | 316 | 0 | 0 | 2,138 |
| Jump | 6 | 1 | 0 | 0 | 5 |
| Branch | 1,970 | 14 | 0 | 0 | 1,956 |
| System | 45 | 20 | 0 | 0 | 25 |
| Multiply, divide, atomic, fence, unknown | 0 | 0 | 0 | 0 | 0 |
| **Total** | **18,813** | **544** | **0** | **14,145** | **4,124** |

The immediately preceding source-matched hard-JALR run took 68,386 cycles, so
this policy saves 15,859 cycles (23.2%) and raises IPC from 0.7690 to 1.0012.
The jump-head population falls from 5,847 cycles to 6.  This is direct evidence
that JALR was previously held through head issue/completion; it does not assign
every remaining cycle reduction to JALR because removing that barrier also
changes downstream overlap and resource pressure.

Of 1,462 JALR scheduler releases, 1,461 occurred before the ROB head and zero
cycles retained a persistent JALR barrier.  At execution resolution, 1,295
JALRs had younger valid ROB entries and 1,034 had at least one younger completed
entry.  The scheduler released 7,261 younger packets while an older JALR was
still unissued.  The predictor recorded 155 JALR direction corrections and one
target correction.  These counters establish that useful younger work crosses
JALR and selective correction remains active.

The remaining incomplete-head population is predominantly memory: active
load/store processing accounts for 14,145 cycles (75.2%), released non-memory
work for 4,124, and still-unissued heads for 544.  Aggregate counters establish
attribution, not causality inside each coarse state.

The ALU completion wakeup changes this workload by only 161 cycles (-0.31%),
despite removing 11,796 register-read accept events and 9,816 read/write
conflict events.  This is evidence that the path works and reduces PRF demand;
it is also evidence that ALU register-read latency is not the dominant
remaining bottleneck in this profile.  The active Tomasulo-window probe records
12,478 operand wakeups.  Earlier zero values from this counter are invalid:
the testbench was sampling the dormant identity-window instance.

Adding safe MEM0 load-completion wakeup saves another 259 cycles (-0.49%) and
records 6,920 MEM0 operand wakeups.  Register-read accepts fall by another
6,352 events and read/write conflicts by 4,924 events.  A load is not predicted
ready one cycle after issue: its dependent wakes in the first cycle that the
registered MEM0 completion is live.  Stores, AMOs, exceptional loads, and
non-ALU consumers do not use this path.

## Supporting validation

- `3p-banked-tomasulo-window-stream-20260902T050151Z` passed the focused
  16-ROB/8-scheduler stream test.  In addition to scheduler-slot reuse, its
  directed probes check speculative JALR release and exact N+1 ALU-dependent
  acceptance, plus same-completion-cycle load-dependent acceptance, while PRF
  write acknowledgement is denied.
- `compliance-act4-platform-3p-tomasulo-ddr3-20260902T050409Z` passed all 93
  preserved RV64IMA ACT4 platform tests with the 64-ROB/32-scheduler Tomasulo
  profile through L2 and timed DDR3.
- `coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-20260902T050217Z` passed the
  full Sv39 CoreMark-derived profile described here.

These are complementary results.  The stream test checks the scheduler/ROB
split directly, ACT4 checks the preserved architectural tests, and the Sv39
loop supplies performance attribution.  None substitutes for Linux boot or a
full architectural compliance claim.

## Known testbench limitation

The new Tomasulo-only hierarchical probes in `tb_top_3p_soc.v` are currently
referenced unconditionally.  As a result, the direct-GPR identity-mode control
`coremark-sv39-3p-magic-gpr-nospec-ddr3` fails during Verilator elaboration
because its hierarchy has no `g_tomasulo` generate block.  The recorded failed
run is `coremark-sv39-3p-magic-gpr-nospec-ddr3-20260901T233336Z`.

That is a testbench instrumentation bug, not a demonstrated core failure.  Do
not use the missing direct-GPR control as performance evidence until the probes
are generate-safe and the control run completes.

Historical measurements and the change-by-change banked-GPR performance log
remain in `doc/performance/banked-gpr.md`.

## Selective memory-replay counters

The current profile also prints four memory-disambiguation groups:

- `PERF_ICX_L2_MEMORY_DISAMBIG` counts speculative-load watches,
  store-address checks, detected collisions, and emitted replay redirects.
- `PERF_ICX_L2_MEMORY_REPLAY_CUT` counts accepted or replacement replay-cut
  candidates, entries preserved relative to the old store-inclusive cut, and
  store-to-load distance buckets.  Candidate counts need not equal redirects:
  an older colliding load can replace a pending cut before a redirect fires.
- `PERF_ICX_L2_MEMORY_REPLAY_CONTROL_WAIT` counts cycles in which a pending
  memory replay is held behind an older incomplete branch or jump.
- `PERF_ICX_L2_MEMORY_ORDERED_ISSUE_REPLAY` counts selected replay candidates
  where a naturally misaligned scalar access reached a pipelined execution
  input before the ordered ROB head.  As with the cut-candidate counters, a
  later same-cycle or older candidate can supersede one before redirect.
- `PERF_ICX_L2_MEMORY_REPLAY_REDIRECT_COLLISION` separates any simultaneous
  execution/free-branch redirect from the subset whose cut is older than the
  memory replay.  A younger redirect is subsumed by the replay cut.  An older
  execution redirect is a one-shot event and must be retained.

The selective-replay reference is
`coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-20260902T155713Z`.  It passed at
40,816 cycles for 52,589 retired instructions (IPC 1.2884), with 211 replay
redirects, 1,812 preserved ROB entries across 273 selected cut candidates, and
264 control-wait cycles.  The preceding three-wide-retire reference took
41,449 cycles, so the measured reduction is 633 cycles (1.53%).
`compliance-act4-platform-3p-tomasulo-ddr3-20260902T155929Z` passed all 93
preserved RV64IMA tests on the same final RTL.

The recovery boundary is the oldest colliding load, inclusive.  Work between
the older store and that load survives; the load and all younger instructions
are replayed.  This is not dependency-cone recovery.  See
`doc/performance/banked-gpr.md` for the implementation and validation details.

## Linux bring-up: ordered-input age inversion

Two independent Linux runs, one using the initially frozen simulator and one
rebuilt from the PMP pre/post-flush source, stopped retiring at the same
instruction sequence.  The source-current run
`linux-l1-tomasulo-1h-ddr3-20260903T031221Z` had retired 4,126,434
instructions and held debug PC `ffffffff802850e8`.  Its ROB head was ID
`0x26c`, the aligned `lw a5,0(a5)` at `ffffffff802850ec`, ready and selected
for MEM0.  MEM0 instead retained younger ID `0x280`, a naturally misaligned
load.  All LSQ slots were empty.

That is a backend deadlock, not demonstrated DDR latency: the LSU correctly
withheld the younger Zicclsm access until ordered head, but the one-entry
pipelined register-load output latch prevented the older head from reaching
the LSU.  The LSU now reports this specific out-of-order presentation and the
Tomasulo backend performs an inclusive replay at the held instruction.  This
replay bypasses the ordinary older-control wait because an older unresolved
control can depend on the blocked head load; waiting for it recreates the same
cycle.  The normal store-collision replay retains its older-control wait.

SATP behavior was deliberately not changed.  It remains an ordered translation
barrier with the existing context flush.  There is no evidence from this
failure tying the stall to stale SATP state, so a separate SATP pre/post hard
flush would currently be an unproven workaround rather than a diagnosis.

The focused Sv39/timed-DDR3 reproducer
`misaligned-order-replay-sv39-3p-tomasulo-ddr3-20260903T040211Z` passed in 840
cycles with the expected `MISORDOK` result.  It recorded 12 ordered-issue
replays.  The unchanged count under a temporary retained-ID filter is
consistent with repeated dynamic retries of the younger misaligned load while
its older cold-load dependency remains unresolved, rather than twelve reports
from one retained packet; that filter was discarded.  The test also performs a
translated store so the harness validates both DTLB load and store paths.

The stress form repeats the exact backward unaligned-copy loop 128 times.
`misaligned-order-replay-sv39-3p-tomasulo-ddr3-20260903T055505Z` passed at
172,762 cycles / 21,801 retired instructions and recorded 31,966 ordered-issue
replays.  Its seven simultaneous execution redirects were all younger than the
replay cut; none required retention.  The identical result before and after
adding redirect retention establishes that the normal replay case was not
perturbed, but it does not exercise the dangerous older-redirect case.

## Linux bring-up: replay/redirect composition

The inclusive scheduler cut fixed the retained issue-window orphan but exposed
a second recovery defect at the next repeatable boundary.  Run
`linux-l1-tomasulo-1h-ddr3-20260903T051854Z` reached 6,557,491 cycles and then
stopped making architectural progress.  A live savable-model snapshot at cycle
7,071,962 showed an empty ROB, empty scheduler, no pending memory replay, and no
pipeline work.  The run had observed two cycles where an ordered memory replay
overrode an older execution redirect.  This is evidence of a lost redirect,
not a residual issue-window orphan and not evidence against SATP coherency.

The backend now retains that older one-shot redirect in a one-entry register.
The memory replay is emitted first to clear the MEM-input age inversion, the
older redirect is emitted on the following cycle, and any replay arriving in
that second cycle remains pending.  If a still older execution redirect appears
while the retained redirect is emitted, it monotonically replaces the retained
cut for the next cycle.  Younger redirects are already covered by the older
cut.  This avoids feeding live execution redirect state combinationally back
into replay eligibility.

`3p-banked-directed-20260903T055424Z` directly forces the ordered-replay/older-
execution-redirect collision and checks both consecutive redirect phases.
`atomic-sv39-3p-tomasulo-ddr3-20260903T055912Z` and
`lrsc-redirect-stress-sv39-3p-tomasulo-ddr3-20260903T055912Z` pass on the same
RTL; the latter completes 8,192 atomic operations.  These tests establish the
direct arbitration contract and adjacent atomic recovery behavior.  Linux
progress beyond the old boundary is reported separately because a focused
test is not a boot claim.

Retaining the execution redirect was necessary but not sufficient.  Run
`linux-l1-tomasulo-1h-ddr3-20260903T060003Z` stopped permanently at
4,328,756 retired instructions.  A live snapshot showed an empty ROB,
empty scheduler, and otherwise idle backend, while the branch predictor's
16-entry unresolved-record queue was full.  The retained redirect was
published one cycle after its branch-resolution pulse, but the predictor's
ordinary squash input derives its recovery ID from that simultaneous pulse.
Consequently the ROB and scheduler discarded the younger suffix while the
predictor retained its records and eventually blocked decode.

The backend now distinguishes redirects carrying an explicit instruction-ID
cut from its memory-replay diagnostic.  Both the replay phase and a retained
execution-redirect phase drive the predictor's tagged recovery input with the
published redirect ID.  The predictor discards younger records even when the
original resolution pulse is no longer present.  The directed collision test
also verifies that a younger ordered-input report present during the retained
redirect cannot seed another replay afterward.

## Linux bring-up: pending replay versus retirement

With tagged predictor recovery, run
`linux-l1-tomasulo-1h-ddr3-20260903T064536Z` passed the prior permanent stop:
at six million cycles it had retired 4,386,308 instructions.  It then reached
a distinct LSQ timeout at cycle 6,001,437.  Four translated byte stores were
waiting to become ordered head behind a completed ALU instruction, but all
three retirement lanes were rejected.

The cause was a global retirement gate on `memory_replay_pending_q`.  A normal
store-collision replay may remain pending while an older unresolved control
completes.  Preventing the older ROB prefix from retiring during that wait is
circular: the intervening instructions and stores cannot reach their ordering
points, so the replay wait cannot drain.  The stale-gate build independently
reproduced the same pattern in
`atomic-sv39-3p-tomasulo-ddr3-20260903T071915Z`.

Retirement cannot simply be opened for the entire pending interval.  Only ROB
entries strictly older than the registered replay ID may retire while the
replay waits.  The replay target and younger suffix remain uncommitted, and an
actual redirect edge blocks all retirement while it applies the ROB cut.  This
preserves forward progress without allowing architectural state to cross a
pending recovery boundary.

A first attempt to use the combinational violation detector as an additional
hold was discarded because Verilator correctly exposed a combinational loop
through retire, dispatch, and LSU selection.  Linux run
`linux-l1-tomasulo-1h-ddr3-20260903T071733Z` was stopped before its result was
used.  The subsequent all-open retirement experiment crossed the old LSQ
timeout, but `linux-l1-tomasulo-1h-ddr3-20260903T072350Z` later took a kernel
load fault at virtual address `0x400`, with EPC `ffffffff80288b80`.  That
policy is still architecturally invalid because it permits the replay target
and younger instructions to retire before the pending cut.  It was not,
however, the cause of this particular fault: the corrected replay-ID prefix
build reproduced the same fault in
`linux-l1-tomasulo-1h-ddr3-20260903T081205Z`.  No combinational loop exists in
the registered replay-ID prefix mask.

The earlier all-open experiment passed these managed tests, which were
insufficient to catch its retirement-boundary bug:

- `3p-banked-directed-20260903T072217Z`, including pending-replay retirement
  and retained-redirect replay-filter checks;
- `atomic-sv39-3p-tomasulo-ddr3-20260903T072100Z`, with 30 atomic starts and
  30 completions;
- `lrsc-redirect-stress-sv39-3p-tomasulo-ddr3-20260903T072226Z`, with 8,192
  atomic starts and completions;
- `misaligned-order-replay-sv39-3p-tomasulo-ddr3-20260903T072257Z`, unchanged
  at 172,762 cycles, 21,801 retired instructions, and 31,966 ordered-input
  replays.

The corrected prefix policy additionally passes:

- `3p-banked-directed-20260903T080546Z`, which checks both a fully older
  three-lane group and a mixed group ending at the replay cut;
- `atomic-sv39-3p-tomasulo-ddr3-20260903T080613Z`;
- `lrsc-redirect-stress-sv39-3p-tomasulo-ddr3-20260903T081012Z`, with 8,192
  atomic starts and completions; and
- `misaligned-order-replay-sv39-3p-tomasulo-ddr3-20260903T081050Z`, unchanged
  at 172,762 cycles, 21,801 retired instructions, and 31,966 ordered-input
  replays.

The Linux harness now dumps its 128-entry retirement/exception history on a
kernel panic, rather than only on the OpenSBI `_start_hang` detector.  The
source-current Linux result is recorded below after it crosses the known
failure boundaries.

## Linux bring-up: JALR target correction versus memory replay

The prefix-policy failure is a redirect-composition bug, not a demonstrated
SATP or translation-context bug.  The exact fault-edge run
`linux-l1-tomasulo-1h-ddr3-20260903T084758Z` reported the architectural load
page fault at cycle 5,958,596:

```text
pc=ffffffff80288b80 instr=0005b783 cause=13 tval=0000000000000400
```

The source-matched kernel image executes the switch sequence at
`ffffffff802850ec` through `ffffffff802850f4`: load the table entry, add its
base, then `jalr` to `ffffffff80285214`.  A dynamic backend trace over this
region in `linux-l1-tomasulo-1h-ddr3-20260903T092047Z` establishes the failure
order:

1. Wrong-path memcpy load ID 128 at `ffffffff80288b80` issues early with base
   `0x400`.
2. JALR ID 127 obtains its actual target `ffffffff80285214` and issues at cycle
   5,958,592.
3. In that same cycle, younger ordered replay ID 157 wins the backend redirect
   port with target `ffffffff80288b80`.
4. The JALR is predicted taken, so the execution pipe has no direction
   mispredict pulse.  Its wrong-target correction is a separate predictor
   pulse.  The replay deferral logic only retained execution direction
   redirects, and the replay cut at ID 157 could not remove older wrong-path
   load ID 128.
5. JALR ID 127 retires at cycle 5,958,595; ID 128 reaches the precise exception
   boundary one cycle later and faults on `0x400`.

There was a second target-path defect in the same interface.  Predictor
resolution consumed the backend's arbitrated redirect target.  During a
simultaneous memory replay that value names the replay PC, not the resolving
branch's actual target.  The backend now exports the raw resolved branch target
separately for predictor comparison and training.

For the Tomasulo speculative backend, an older live target correction now
preempts a younger memory replay.  This is intentionally different from the
existing two-phase ordered-replay/direction-redirect collision: the older
branch cut immediately removes the replaying load and every intervening
wrong-path instruction, while a replay-first cut cannot.  An older replay still
discards a younger resolving branch normally.  The directed regression forces
the failing age relation and checks that branch ID 90 redirects while replay ID
100 remains pending until the branch squash removes it.

SATP remains unchanged.  A pre/post SATP hard flush may still be evaluated as
a conservative architectural policy, but this failure supplies no evidence for
it: the fault is fully explained before any stale translation state is needed.

The target-correction arbitration and raw-target interface pass these managed
regressions:

- `3p-banked-directed-20260903T095444Z`, including the forced older-target-
  correction/younger-replay collision;
- `atomic-sv39-3p-tomasulo-ddr3-20260903T095459Z`;
- `lrsc-redirect-stress-sv39-3p-tomasulo-ddr3-20260903T095803Z`, with 8,192
  atomic starts and completions; and
- `misaligned-order-replay-sv39-3p-tomasulo-ddr3-20260903T095835Z`, unchanged
  at 172,762 cycles, 21,801 retired instructions, and 31,966 ordered-input
  replays.

The source-current Linux run
`linux-l1-tomasulo-1h-ddr3-20260903T095928Z` crossed both previously observed
failure boundaries: the exact load-fault edge at cycle 5,958,596 and the prior
kernel-panic point at cycle 7,086,900.  It emitted neither a
`LINUX_FAULT_EDGE` record nor a kernel panic, Oops, or BUG record.  A source-
matched checkpoint was saved at 6,000,000 cycles as
`run/log/linux-l1-tomasulo-1h-ddr3-20260903T095928Z/checkpoint-6000000.vls`.
The run then stopped at its configured 7,500,000-cycle diagnostic limit while
still in S-mode, at PC `ffffffff80280e58`.  Linux had progressed through early
initialization but had not reached the shell prompt, so this is evidence that
the identified redirect fault is fixed, not a Linux boot pass.

## Linux bring-up: L1D response arbitration under backpressure

The next source-current Linux run,
`linux-l1-tomasulo-1h-ddr3-20260903T104141Z`, reached S-mode without a Linux
fault edge, panic, Oops, or BUG, then failed at simulation time 145,234,000:

```text
L1D response changed while held by backpressure
```

This is a northbound ready/valid violation in the L1D, not a Linux or SATP
failure.  The public response was a combinational priority mux over completed
demand misses, resident L1 responses, and the simulation-only freeloader.  A
resident response could be presented while the requester withheld ready, then
be replaced by a newly eligible higher-priority demand completion before the
resident response was accepted.

The source-identical pre-fix simulator resumed from the 6,000,000-cycle
checkpoint in `linux-l1-tomasulo-1h-ddr3-20260903T095928Z` and saved the
requested exact-state snapshot at 14,000,000 cycles in
`linux-l1-tomasulo-1h-ddr3-20260903T130420Z`.  Its managed validation is
`checkpoint`; the simulator exited normally after writing the 529 MiB file,
whose SHA-256 is
`46b2780b72cac4a30e92c2f18a2a3c8e9d1e66bd86d3de50dbfae99bfc79e712`.
The wrapper's later exit code 2 is only failed optional symbol-map
postprocessing; `sim_exit_code=0` and the checkpoint is complete.

Exact replays of the final failure window under GDB used the original
checkpoint-compatible model.  On the capture edge, the public tuple was tag 0,
data 0, no error, valid with ready low.  The L1 resident response was valid;
the tag-2 demand waiter was found but its overlay was not yet ready, so the
public tuple was unambiguously the resident response.  On the next edge, before
that tuple was accepted, the public output became tag 2, data 1, no error.  The
live source was then the completed demand waiter: tag 2, MSHR 0, overlay ready,
and no speculation barrier.  The resident L1 response was still valid and its
ready was withheld because the demand completion had taken priority.  Runs
`linux-l1-tomasulo-1h-ddr3-20260903T140828Z` and
`linux-l1-tomasulo-1h-ddr3-20260903T135542Z` record the capture and failure
edges respectively.

The L1D now has a one-entry fall-through response skid slot.  When empty and
the requester is ready, it adds no response latency.  When the requester
stalls, it accepts the selected internal source into the slot and owns its
tag/data/error tuple until the requester accepts it.  When a held tuple drains,
the next internal source can enter the slot on the same edge, preserving one
response per cycle.  This also protects against a completed demand waiter
changing selection while another demand response is held.

The demand-MSHR directed test now explicitly presents a resident response,
withholds northbound ready, and makes a demand waiter complete during the
stall.  The pre-fix managed run
`l1d-retired-store-mshr-20260903T125858Z` fails that check.  The fixed focused
run `l1d-retired-store-mshr-20260903T130022Z` passes, and the combined run
`l1d-response-arbiter-directed-20260903T130145Z` passes all seven L1D suites:
prefetch, demand MSHR, retirement-canonical MSHR, store order, store buffer,
fence, and invalidate arbitration.

The fixed cache/response integration also passes the Sv39 timed-DDR3 atomic
run `atomic-sv39-3p-tomasulo-ddr3-20260903T135855Z` and the 4,096-iteration
redirect/LR-SC stress run
`lrsc-redirect-stress-sv39-3p-tomasulo-ddr3-20260903T135855Z`.  The
misaligned ordered-replay run
`misaligned-order-replay-sv39-3p-tomasulo-ddr3-20260903T141120Z` also passes
unchanged at 172,762 cycles, 21,801 retired instructions, and 31,966
ordered-input replays.

The fixed-RTL Linux run from reset,
`linux-l1-tomasulo-1h-ddr3-20260903T135957Z`, crossed the old approximately
14.5234M-cycle failure and stopped intentionally at 15,000,000 cycles with
10,016,473 retired instructions.  It remained in S-mode and emitted no L1D
hold failure, `LINUX_FAULT_EDGE`, panic, Oops, or BUG.  The simulator exit is
zero and managed validation is `stopped`; the wrapper's exit code 2 is again
only the unavailable optional Linux symbol map.  The run also saved a
source-current 14,000,000-cycle checkpoint with SHA-256
`6b4ff9f30b98771c291e7061f98346b868cafa4a17fd9db195edbe5483b2d150`.
This is a targeted failure-boundary pass, not a completed Linux boot.  This
work does not change SATP policy.

## Posted-store identity-only completion

An accepted ordinary cacheable store no longer occupies the LSU's full result
datapath.  Retirement result storage is initialized for stores at allocation
with the sequential next PC and zero data/control result.  When the L1D request
handshake becomes irrevocable, the LSQ emits only the instruction ID and ROB
slot on an independent posted-store completion port.  The ROB validates that
identity and marks the entry complete.  A simulation assertion treats failure
to match the live ROB entry as fatal.

This port is independent of the three normal completion payloads and, in the
4PF backend, the extension-completion sideband.  Loads, translation or access
faults, atomics, uncached stores, and naturally misaligned operations retain
their full-result paths.  The LSQ also retains a posted store until the later
store-done response, so downstream protocol ownership and asynchronous store
error reporting are unchanged.

The source-matched Sv39 memcpy waveform run is
`memcpy-64k-sv39-3p-tomasulo-ddr3-tage-store-wave-20260903T204827Z`.
Edge-level analysis found 8,193 cacheable store request handshakes and 8,193
same-edge sideband completions.  Every completion matched and was accepted by
the ROB; no cacheable store used the full result port.  In 1,001 cycles the
store sideband coincided with another LSU result, demonstrating that a load
result no longer delays the store acknowledgment.

This removes the local completion arbitration defect but does not improve this
memcpy run's elapsed time.  Both the old payload-bypass run
`memcpy-64k-sv39-3p-tomasulo-ddr3-tage-store-wave-20260903T200836Z` and the
sideband run take 31,275 cycles for 20,529 retired instructions, IPC 0.6564.
Store request wait remains 3,040 cycles and the DDR request schedule is
unchanged.  Retirement attribution does change: head-incomplete cycles fall
from 16,221 to 14,219 and store-at-head cycles from 14,703 to 11,700.  Those
cycles are absorbed by other head states and retirement grouping rather than
shortening the memory-bound critical path.

Focused managed validation passes in:

- `lsq-store-guards-20260903T204415Z`;
- `retire-queue-store-sideband-20260903T204804Z`;
- `lsu-xlate-generation-3p-20260903T205139Z`;
- `top-4pf-screen-policy-regression-20260903T204721Z`; and
- the full Sv39 memcpy run above.

The broader `ret-load-inhibit-focused-20260903T204550Z` run reaches and passes
its new posted-store sideband check, then fails a later, separate misaligned
memory-replay counter assertion.  The observed counts are five store-address
checks, two violations, and three total emitted replays versus an expected two;
the additional event is an ordered-input replay preceding the collision
replay.  This is not evidence of a store-completion failure, but that broader
test is not a clean pass and should not be reported as one.

## ROB-head store-prefix authorization

Posted completion alone left a registered-head bubble between consecutive
stores.  The ROB now exposes the identity and slot of its first three raw
entries, independent of their completion state.  The LSU may authorize the
consecutive ordinary cacheable-store prefix from that window.  Its existing
oldest-request selection still presents at most one request per cycle, so an
older ready store always reaches the single L1D port before a younger one.

Authorization is not retirement.  Every store must already have a live,
translated, fault-free cacheable SQ entry, and its own L1D request handshake
must publish the identity-only ROB completion before the ROB can retire it.
The SQ entry remains allocated until the later store-done response.  Atomics,
uncached stores, immediate faults, misaligned operations, replay, and the
younger side of a pending interrupt retain exact-head ordering.

The source-matched timing waveform run
`memcpy-64k-sv39-3p-tomasulo-ddr3-tage-store-wave-20260903T214303Z` takes
28,290 cycles for 20,529 retired instructions, IPC 0.7257.  Relative to the
31,275-cycle posted-sideband baseline above, this is 2,985 fewer cycles
(9.54%) and 10.56% higher IPC.  Of 8,193 store handshakes, 6,129 used the
head-prefix authorization while the registered ordered head still named an
older store.  The waveform contains 6,129 one-cycle store-request gaps; the
baseline contains none.

The full Sv39 correctness workload
`memcpy-64k-sv39-3p-tomasulo-ddr3-tage-correctness-20260903T214303Z` also
passes: 77,890 retired instructions in 61,982 cycles, IPC 1.2567, and all
8,193 stores acknowledged and retired.  Its preceding source-matched result
was 65,159 cycles and IPC 1.1954.  Focused store guards pass in
`lsq-store-guards-20260903T214557Z`, including a directed assertion that the
second store is presented in the cycle immediately following the first while
the externally registered ordered head remains unchanged.  The banked-window
lint run `3p-banked-window-lint-20260903T214557Z` also passes without adding a
retire/LSQ combinational loop.

The complete resident-state trace is
`memcpy-64k-sv39-3p-tomasulo-ddr3-tage-trace-20260903T214704Z`.  Its validated
`pipeline-state.csv.bz2` is 7,419,425 bytes and contains 2,450,175 rows over
27,811 sampled cycles for 23,896 dynamic instruction IDs.  The trace reader
and report generation both pass directly on the compressed file.

This workload does not retire two stores in the same cycle.  The L1D request
interface still accepts at most one store per cycle, and the ROB generally
retires each store as soon as that individual acknowledgement arrives.  The
throughput gain comes from eliminating the otherwise idle cycle between
successive store acknowledgements.  Supporting more than one store
acknowledgement per cycle would require a multi-entry L1D enqueue interface;
delaying acknowledged stores merely to retire them as a batch would not add
throughput.
