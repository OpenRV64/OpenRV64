# Cycle and pipeline trace

The existing `dbg_pc` and `dbg_instr` outputs are last-writeback indicators.
They cannot prove pipeline timing: a held instruction repeats, a loop reuses a
PC, and a flushed instruction never appears at writeback. The optional trace
interface adds a unique fetch ID and exposes each pipeline boundary every
cycle.

## Generate a trace

```sh
make sim-top-trace
```

This writes:

- `sim/openrv64-cycle.csv`: stable, machine-readable `openrv64-cycle-v1` rows.
- `sim/openrv64-pipeline.txt`: utilization summary, cycle timeline,
  per-instruction timing, and architectural retire log.

Paths can be overridden without changing the testbench:

```sh
make sim-top-trace \
  TRACE_CSV=/tmp/run.csv \
  TRACE_REPORT=/tmp/run.pipeline.txt
```

An existing CSV can be rendered or filtered directly:

```sh
python3 tools/pipeline_trace.py sim/openrv64-cycle.csv \
  --start-cycle 40 --end-cycle 90 --max-cycles 0
```

## RTL interface

Set `ENABLE_TRACE=1` on `openrv64_top`. When it is zero, all trace outputs are
constant zero and synthesis can remove the trace ID path and counters.

The five-bit stage vectors use bit `0=IF`, `1=ID`, `2=EX`, `3=MEM`, and
`4=WB`. The same ordering is used by the 64-bit slices in `trace_ids` and
`trace_pcs`, and the 32-bit slices in `trace_instrs`. For example, the execute
UID is `trace_ids[2*64 +: 64]`.

| Output | Meaning |
| --- | --- |
| `trace_cycle` | Rising-edge count since reset deassertion. |
| `trace_valid[4:0]` | The corresponding stage owns an instruction ID. |
| `trace_stall[4:0]` | Valid instruction neither advances nor flushes this cycle. |
| `trace_flush[4:0]` | Stage is invalidated this cycle. Payload outputs are masked. |
| `trace_advance[4:0]` | Stage completes a local step or downstream handoff. |
| `trace_ids[319:0]` | Unique dynamic instruction ID per stage; zero when invalid. |
| `trace_pcs[319:0]` | PC per stage; zero when invalid. |
| `trace_instrs[159:0]` | Instruction word per stage; zero when invalid or while IF still waits for its response. |
| `trace_events[7:0]` | Redirect, trap, IRQ, MRET, SRET, restart, halt, reset. |
| `trace_stall_causes[7:0]` | RAW, WAW, scoreboard, IF memory, data memory, execute, frontend held, serializing. |
| `trace_retire_valid` | WB entry is consumed, including a faulting instruction. |
| `trace_retire_arch` | Instruction completed without an exception. |
| `trace_retire_exception` | Instruction generated an exception. |
| `trace_retire_cause` | Exception cause when `trace_retire_exception` is set. |
| `trace_retire_next_pc` | Sequential or resolved next PC carried by WB. |
| `trace_retire_rd_write`, `trace_retire_rd`, `trace_retire_wdata` | Architectural GPR update; writes to x0 are suppressed. |

Bit-number constants are in `rtl/core/trace/trace-defs.v` and form part of the
trace ABI.

The IF slot covers the complete blocking fetch transaction. It can assert
`trace_advance[IF]` once when memory returns and again when the fetched word is
accepted by ID. The UID remains unchanged across both steps. ID through WB use
`advance` for the downstream handoff. A UID is allocated when a fetch PC is
accepted; it is not reused if that fetch is later redirected or flushed.

## CSV and cosimulation contract

`tb/openrv64_cycle_trace.sv` samples the trace pins on the falling edge, after
the preceding rising-edge state update has settled. It writes one flat CSV row
per active-reset cycle. Hexadecimal vectors have no `0x` prefix; `cycle`, the
boolean retire fields, and `retire_rd` are decimal. Every row carries the
literal schema value `openrv64-cycle-v1`.

Cosimulation should compare architectural state only when
`trace_retire_valid` is set:

1. If `trace_retire_exception=1`, compare the trap cause and do not apply a GPR
   write.
2. Otherwise require `trace_retire_arch=1`, advance the reference model by one
   instruction, and compare PC, instruction, next PC, and any reported GPR
   write.
3. Use the UID only for timing correlation. It is intentionally not
   architectural state.

The CSV is also suitable for cocotb or Verilator, but file output is not
required there: those harnesses can sample the same top-level pins directly.

## Reading utilization

The report separates three quantities that should not be conflated:

- `occupied`: cycles in which a stage contains any valid dynamic instruction;
- `completed`: occupied cycles attributed to UIDs that eventually reached the
  retire boundary, including exceptions;
- `not_done`: occupied cycles attributed to wrong-path, flushed, or unfinished
  UIDs.

`IPC` counts only non-exception architectural retirement. A high occupied
percentage with low completed occupancy is wasted speculative work, while high
stall counts with high completed occupancy identify latency rather than wrong
path. The per-instruction table gives exact cycle ranges, so a multi-cycle EX or
MEM residency is directly visible rather than reconstructed from writeback
timestamps.
