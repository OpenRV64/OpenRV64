# Tomasulo resident-state trace

## Purpose and scope

`openrv64-pipeline-state-v2` is a long-form, simulation-only event stream for
the `tb_top_3p_soc` Tomasulo profile.  It records every visible instruction in
every sampled component, with a cycle, stable instruction ID, component-local
state, and one primary reason why the instruction is not making its next
normal transition.

This is deliberately a **component-residency** trace, not a five-stage
pipeline fiction.  A Tomasulo instruction normally has a ROB row at the same
time as a scheduler, register-read, execution, completion, or LSQ row.  A GUI
must preserve those simultaneous rows rather than choosing one exclusive
stage.

The format is sufficient to reconstruct instruction residency,
movement, the active scheduler/LSQ/ROB contents, and causal wait codes.  It is
not yet a complete machine snapshot: it does not dump PRF values, rename-map
contents, cache lines, TLB entries, predictor tables, or all global control
state.  Those require separate versioned snapshot records before a future GUI
can claim to rebuild the entire machine state.

## Managed run

Run the trace-enabled derivative of the documented 64-ROB/32-scheduler
profile:

```sh
run/run run/cfg/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-trace.cfg --foreground
```

The runner places these files directly in `run/log/<run-id>/`:

- `pipeline-state.csv.bz2`: the bzip2-compressed versioned stream.  After the
  simulator closes the raw CSV, `pbzip2 -9` compresses it and removes the raw
  input.  Failed simulations retain their partial raw CSV for diagnosis.
- `pipeline-state-report.txt`: validator output, aggregate component/reason
  counts, and the first selected records.
- the usual effective configuration, source hashes, dirty patch, build log,
  run log, and validation status.

The default records the complete run and can be large.  Bound the sampled
window without bypassing the managed runner:

```sh
run/run run/cfg/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-trace.cfg \
  --foreground \
  CORE_3P_ICX_L2_PIPELINE_STATE_TRACE_START=10000 \
  CORE_3P_ICX_L2_PIPELINE_STATE_TRACE_CYCLES=2000
```

`CYCLES=0` means record from `START` through simulation end.  The default file
flush interval is 1024 cycles and is configurable with
`CORE_3P_ICX_L2_PIPELINE_STATE_TRACE_FLUSH`.

The trace-ID sideband and deep hierarchy probes are compiled only when
`CORE_3P_ICX_L2_ENABLE_PIPELINE_STATE_TRACE=1`.  Ordinary `tb_top_3p_soc`
builds retain their previous `ENABLE_TRACE=0` behavior and use a distinct
Verilator build directory.

## Sampling and identity contract

Rows are sampled on the falling edge, after rising-edge state updates have
settled.  A row with cycle `N` describes the stable component state between
rising edges `N` and `N+1`.  `FIRE` means the displayed valid/ready transfer is
offered for acceptance at the following rising edge.

`insn_id` is the low 32 bits of the existing monotonic 64-bit simulation trace
ID.  It is the cross-component and cross-cycle identity.  The writer stops
with a fatal error instead of silently wrapping if an instruction ID or cycle
does not fit 32 bits.  A future wider format must use a new schema version.

An ID is consumed when its frontend candidate is exposed.  Ordinary partial
decode consumption advances only by accepted lanes, preserving the IDs of
candidates that shift down under backpressure.  A redirect, trap, or
maintenance restart consumes every exposed candidate ID before replacing the
fetch prefix.  Squashed candidates therefore leave gaps; an ID is never
reassigned to a different PC/instruction pair.

`core_id` is the current wrapping internal instruction tag (10 bits in this
profile).  It is included to debug RTL matching but is not globally unique and
must not be used as the GUI identity.

## CSV contract

The exact header is:

```text
schema,cycle,insn_id,core_id,pc,instr,stage,slot,lane,state,reason,blocker_id,flags,detail0,detail1
```

Numeric encoding is fixed:

- `cycle`, `stage`, `slot`, `lane`, `state`, and `reason` are decimal.
- IDs, PC, instruction, flags, and details are zero-padded hexadecimal without
  a `0x` prefix.
- `slot=-1` means that the component has no retained slot.
- `lane=-1` means that no transfer lane applies.
- `blocker_id=00000000` means that the primary reason has no single named
  instruction.  For `BOTH_SOURCES_PENDING`, it names source 1; both internal
  producer tags remain in scheduler `detail0`.

Version 2 adds component code 10 (`DISPATCH`) for the BP9 synchronous lookup
register.  The reader remains backward-compatible with version 1 traces,
whose component set ends at code 9.

The same `insn_id` must always retain the same PC and instruction encoding.
The writer rejects zero or overflowing IDs.  The validator also rejects cycle
regression, unknown codes, changed identity, and duplicate component rows.

## Components and locations

| Code | Name | What one row represents | `slot` / `lane` |
|---:|---|---|---|
| 1 | `FETCH` | frontend fetch/decode output | `-1` / fetch lane |
| 2 | `DECODE` | candidate at the backend admission gate | `-1` / decode lane |
| 3 | `SCHED` | one live Tomasulo scheduler entry | scheduler slot / assigned pipe or 255 |
| 4 | `REGREAD` | active or pending deferred PRF gather | ROB slot / physical pipe |
| 5 | `EXEC` | execution offer or EX0 multicycle worker | ROB slot / physical pipe |
| 6 | `COMPLETE` | execution completion output | ROB slot / completion lane |
| 7 | `LSQ` | one live load or store transaction | LSQ array slot / 2 load or 3 store |
| 8 | `ROB` | one live retirement record | ROB slot / `-1` |
| 9 | `RETIRE` | ordered retirement candidate | ROB slot / retirement lane |
| 10 | `DISPATCH` | BP9 elastic decode-to-dispatch register | `-1` / dispatch lane |

The scheduler row and matching EXEC `FIRE` row coexist in the issue cycle.
The scheduler entry disappears after the issue edge in physical-rename mode;
the ROB row remains.  Similar overlap at other boundaries is intentional.
`REGREAD` rows are emitted only when the deferred PRF-gather active or pending
buffers are occupied.  Those buffers remained empty in the validated Tomasulo
CoreMark window, so that trace contains no `REGREAD` rows; this is observed
profile behavior, not proof that the writer cannot emit them.
The LSU compact metadata retains the trace ID so an LSQ row remains
self-identifying after a posted store has retired and outlived its ROB entry.
For BP9, `DECODE` records the combinational candidate entering the elastic
boundary and `DISPATCH` records the retained bundle presented to rename and
scheduler allocation.  The synchronous TAGE/BTB read latency is therefore a
`DISPATCH` residency interval rather than a `DECODE` wait.

## State codes

| Code | Name | Meaning |
|---:|---|---|
| 1 | `PRESENT` | visible in a component without a transition classification |
| 2 | `WAIT` | cannot make the component's next transition |
| 3 | `READY` | scheduler entry is eligible and selected or awaiting selection |
| 4 | `FIRE` | valid/ready transfer is offered |
| 5 | `PENDING` | retained in the secondary PRF-gather buffer |
| 6 | `ACTIVE` | retained in the active PRF-gather group |
| 7 | `WORKER` | resident in the EX0 multiply/divide/Zbb worker |
| 8 | `LOAD` | resident load LSQ entry |
| 9 | `STORE` | resident store/atomic LSQ entry |
| 10 | `INCOMPLETE` | ROB entry has no completed result |
| 11 | `COMPLETE` | completed ROB entry is behind the head |
| 12 | `HEAD` | completed ROB entry is at the retirement head |

## Primary reason codes

The reason is exclusive and ordered by the component's actual gate priority.
`NONE` means the row is not blocked in the sampled interval.  It does not mean
that the instruction will retire in that cycle.

| Code | Name | Component-level interpretation |
|---:|---|---|
| 0 | `NONE` | no blocking gate; current transfer can progress |
| 1 | `SRC1_PENDING` | scheduler source 1 producer is not ready |
| 2 | `SRC2_PENDING` | scheduler source 2 producer is not ready |
| 3 | `BOTH_SOURCES_PENDING` | both scheduler sources are pending |
| 4 | `OLDER_HARD` | blocked by an older non-speculatable hard operation |
| 5 | `PERSISTENT_BARRIER` | blocked by an older resident/latched barrier |
| 6 | `RETIRE_HEAD_REQUIRED` | this serializing operation is not the ROB head |
| 7 | `OLDER_MEMORY` | memory issue ordering gate |
| 8 | `OLDER_CONTROL` | memory work cannot cross the named live control |
| 9 | `BRANCH_ORDER` | branch resolution is ordered behind an older branch |
| 10 | `PIPE_CONFLICT` | eligible entry lost its compatible physical pipe |
| 11 | `ISSUE_WIDTH` | selected entry exceeded the configured issue budget |
| 12 | `PIPE_BUSY` | assigned execution pipe is not ready |
| 13 | `REGREAD_PORT` | required PRF operand data is not available |
| 14 | `REGREAD_BUFFER` | instruction is in the secondary gather buffer |
| 15 | `EXEC_WORKER` | multiply/divide/Zbb worker still owns the instruction |
| 16 | `COMPLETION_BACKPRESSURE` | completion/result consumer is not ready |
| 17 | `XLATE_ARBITRATION` | LSQ entry has not won translation launch |
| 18 | `XLATE_RESPONSE` | translation request is outstanding |
| 19 | `STORE_GUARD` | load is blocked by an older store guard |
| 20 | `MEMORY_ORDER` | device/store/atomic access requires ordered head |
| 21 | `MEMORY_PORT` | translated entry has not won memory launch |
| 22 | `MEMORY_RESPONSE` | memory request is outstanding |
| 23 | `POSTED_STORE_ACK` | posted store result was sent; access completion remains |
| 24 | `ROB_INCOMPLETE` | ROB entry has no completion |
| 25 | `ROB_ORDER` | completed ROB entry is behind older work |
| 26 | `RETIRE_BACKPRESSURE` | ordered retirement candidate is not accepted |
| 27 | `REDIRECT_SQUASH` | selective/full recovery is removing the work |
| 28 | `FRONTEND_CONTROL` | frontend prefix, flush, or redirect gate |
| 29 | `BP_STALL` | legacy aggregate branch-predictor stall code |
| 30 | `TRANSLATION_BARRIER` | frontend translation barrier is active |
| 31 | `RENAME_TAG` | no physical rename tag is available |
| 32 | `ROB_CAPACITY` | retirement allocation is not ready |
| 33 | `SCHED_CAPACITY` | scheduler has no free entry |
| 34 | `DECODE_DOWNSTREAM` | remaining backend decode/admission hold |
| 35 | `HALT_OR_WFI` | core is halted or sleeping in WFI |
| 36 | `RESULT_ARBITRATION` | LSQ local result lost result-port arbitration |
| 37 | `ATOMIC_UNIT` | atomic waits for the ordered atomic engine |
| 38 | `BP_LOOKUP` | synchronous predictor response is pending in dispatch |
| 39 | `BP_CAPACITY` | predictor in-flight resolution storage is full |
| 40 | `BP_TARGET` | indirect control has no predicted target and awaits resolution |
| 255 | `UNKNOWN` | a live entry failed an unclassified gate; treat as a bug |

For source, ordering, and barrier causes, `blocker_id` names an instruction
when the RTL has a unique blocker.  Resource causes such as pipe conflict,
issue width, and memory-port arbitration have no single blocker in v1.

## Flags and detail words

`flags`, `detail0`, and `detail1` are component-local fixed 64-bit words.  Bits
not listed below are zero.

| Component | `flags` low bits | `detail0` | `detail1` |
|---|---|---|---|
| FETCH | 0 valid, 1 backend-valid, 2 backend-ready, 3 fetch-ready | 0 | 0 |
| DECODE | 0 fire, 1 valid, 2 ready, 3 fetch-ready | free tags `[15:0]` | ROB occupancy `[15:0]`, scheduler occupancy `[31:16]` |
| DISPATCH | 0 fire, 1 backend-valid, 2 backend-ready, 3 control | free tags `[15:0]` | ROB occupancy `[15:0]`, scheduler occupancy `[31:16]` |
| SCHED | 0 valid, 1 issued, 2 eligible, 3/4 source ready, 5/6 source used, 7 result ready, 8 blocker valid | source core IDs `[15:0]`, `[31:16]` | ROB slot `[7:0]`, source physical tags `[15:8]` and `[23:16]`, destination tag `[31:24]` |
| REGREAD active | 0 group valid, 2:1 lane valid, 6:3 fire mask, 10:7 operand-ready mask | operand-done mask `[3:0]` | response-now mask `[3:0]` |
| REGREAD pending | 0 group valid, 2:1 lane valid, 6:3 operand-ready mask | operand-done mask `[3:0]` | 0 |
| EXEC/COMPLETE/RETIRE | 0 valid, 1 ready/accept | completion/retirement result for COMPLETE/RETIRE | next PC for COMPLETE/RETIRE |
| LSQ load | 0 valid, 1 immediate, 2 translation sent, 3 translation done, 4 access sent, 5 killed, 6 guard block, 7 order match | virtual address | physical address |
| LSQ store | load phase bits plus 5 result sent, 6 access done, 7 killed, 8 order match, 9 atomic | virtual address | physical address |
| ROB | 0 present, 1 valid, 2 complete, 3 head | rs1 `[4:0]`, rs2 `[12:8]`, rd `[20:16]`, control/class bits `[32:24]`, new physical tag `[47:40]` | result data |

The ROB control/class bits are: 24 register write, 25 uses rs1, 26 uses rs2,
27 hard, 28 load, 29 store, 30 branch, 31 jump, and 32 predicted taken.

## Validator and focused reports

The managed trace configuration runs the validator automatically.  It can
also inspect an existing trace without loading the full CSV into memory:

```sh
python3 tools/pipeline_state_trace.py run/log/<run-id>/pipeline-state.csv.bz2 \
  --instruction 00001234 --rows 500
```

Cycle-window selection is available with `--start-cycle N --cycles M`.
Selection limits report rows only; validation and aggregate counts always scan
the entire input.  The reader detects bzip2 by `.bz2` suffix or `BZh` magic and
still accepts uncompressed CSV.  The tool exits nonzero on a schema or identity
violation.

## Current limitations

- The writer intentionally probes the current Tomasulo, banked-register-read,
  four-load/four-store LSQ hierarchy.  A hierarchy or depth change must update
  the writer and schema documentation together.
- One primary reason cannot represent all simultaneous pressure.  Component
  flags retain selected secondary conditions, but v1 does not emit a general
  multi-cause list.
- `PIPE_CONFLICT`, `ISSUE_WIDTH`, translation arbitration, memory arbitration,
  and result arbitration do not yet name the competing instruction.
- Disappearance after a redirect is inferable from the last resident row, but
  v1 has no explicit allocate/free/squash tombstone record.
- This is simulation evidence.  It says nothing by itself about synthesis,
  routed timing, FPGA behavior, or architectural compliance.

The numeric ABI is defined in
`rtl/core/trace/tomasulo-trace-defs.v`.  Do not renumber existing codes; add a
new code or schema version.
