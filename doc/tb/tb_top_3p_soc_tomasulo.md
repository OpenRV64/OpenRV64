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

The current source-matched reference is:

```text
coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-20260902T000143Z
```

| Metric | Result |
|---|---:|
| Cycles | 68,386 |
| Retired instructions | 52,589 |
| IPC | 0.7690 |
| Issue width 0 / 1 / 2 / 3 | 29,006 / 19,197 / 16,770 / 3,413 cycles |
| Retire width 0 / 1 / 2 / 3 | 34,056 / 16,071 / 18,259 / 0 cycles |
| ROB nonempty, no retire | 33,388 cycles |
| Incomplete ROB head | 33,275 cycles |
| Completed instructions behind head | 19,632 cycles |
| GPR-write-blocked retirement | 0 cycles |
| Rename blocked by physical tags | 5,393 cycles |
| Free-list empty | 3,853 cycles |

The incomplete-head cross-tab for that run is:

| Head instruction | Total | Unissued | Register-load | Memory | Execute |
|---|---:|---:|---:|---:|---:|
| Load | 11,320 | 1,616 | 0 | 9,704 | 0 |
| Store | 7,147 | 22 | 0 | 7,125 | 0 |
| ALU | 6,962 | 1,813 | 0 | 0 | 5,149 |
| Jump | 5,847 | 2,923 | 0 | 0 | 2,924 |
| Branch | 1,954 | 13 | 0 | 0 | 1,941 |
| System | 45 | 20 | 0 | 0 | 25 |
| Multiply, divide, atomic, fence, unknown | 0 | 0 | 0 | 0 | 0 |
| **Total** | **33,275** | **6,407** | **0** | **16,829** | **10,039** |

This says the measured zero-retire problem is not a single bottleneck.  Memory
heads account for 16,829 cycles, released non-memory heads for 10,039, and
still-unissued heads for 6,407.  Loads and stores are 55.5% of incomplete-head
cycles; ALU and control instructions are the remaining 44.5%.  Aggregate
counters establish attribution, not causality inside each coarse state.

## Supporting validation

- `3p-banked-tomasulo-window-stream-20260901T225950Z` passed the focused
  16-ROB/8-scheduler stream test and observed scheduler-slot reuse while an
  older issued instruction remained ROB-resident.
- `compliance-act4-platform-3p-tomasulo-ddr3-20260901T230726Z` passed all 93
  preserved RV64IMA ACT4 platform tests with the 64-ROB/32-scheduler Tomasulo
  profile through L2 and timed DDR3.
- `coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-20260902T000143Z` passed the
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
