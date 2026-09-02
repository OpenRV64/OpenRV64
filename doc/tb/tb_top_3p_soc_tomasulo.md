# `tb_top_3p_soc` Tomasulo profile

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

The current profile also prints three memory-disambiguation groups:

- `PERF_ICX_L2_MEMORY_DISAMBIG` counts speculative-load watches,
  store-address checks, detected collisions, and emitted replay redirects.
- `PERF_ICX_L2_MEMORY_REPLAY_CUT` counts accepted or replacement replay-cut
  candidates, entries preserved relative to the old store-inclusive cut, and
  store-to-load distance buckets.  Candidate counts need not equal redirects:
  an older colliding load can replace a pending cut before a redirect fires.
- `PERF_ICX_L2_MEMORY_REPLAY_CONTROL_WAIT` counts cycles in which a pending
  memory replay is held behind an older incomplete branch or jump.

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
