# Frontend cycle trace

The frontend trace is a one-row-per-cycle record of the Tomasulo instruction
stream frontend.  It complements the resident-instruction trace: instruction
rows explain where accepted dynamic instructions wait, while frontend rows
retain cycles in which no instruction exists to carry a trace ID.

The first supported configuration is the AXI/native-fetch Tomasulo frontend
with the BP9 TAGE predictor and stream-start-indexed RLE BTB.  The trace reads
the existing top-level frontend observation seams; FTQ generation and count
were connected to that seam as well.  Enabling the trace adds no synthesized
storage or functional control path.

## Managed run

```sh
run/run run/cfg/coremark-sv39-3p-tomasulo-rob64-sched32-ddr3-tage-warm4-measure1-frontend-trace.cfg --foreground
```

This uses the normal 64-entry ROB, 32-entry scheduler, 63 physical-register
configuration.  Four CoreMark-loop invocations warm the cache and predictors;
the retired `START_TRACE` and `END_TRACE` markers delimit both the reported
performance interval and the trace.  The managed run compresses the CSV with
`pbzip2`, verifies it, and writes `frontend-report.txt`.

An absolute-cycle diagnostic capture may instead override:

```text
CORE_3P_ICX_L2_FRONTEND_TRACE_START=<cycle>
CORE_3P_ICX_L2_FRONTEND_TRACE_CYCLES=<count>
```

Zero cycles means capture until the marker or simulation end.  A negative
start selects marker mode.

## ABI

The schema identifier is `openrv64-frontend-cycle-v1`.  Cycles are contiguous
and 32-bit.  To keep Verilator code generation and the output size bounded,
each raw row has explicit PCs, queue occupancies and two packed words:
`flags` for Boolean state/events and `lane_state` for decode lane masks.  The
reader expands those words to named fields.  The logical fields cover:

- stream presentation: stream PC, generation, FTQ count, active control
  boundary, splice and prediction acceptance;
- decode admission: presented, ready and accepted lane masks, control and
  prefix qualification, halfword consumption, frontend enables, and backend
  occupancy;
- instruction delivery: fetch request/response handshakes and addresses plus
  current-block and any-demand pending state;
- stream BTB: lookup/response/hit events, root/chained lookup events, response
  queue occupancy/backpressure, transfers, rejects and training;
- TAGE: early-candidate FIFO occupancy, shared-port request/accept, direction
  response, refinement disposition, token-context events, coalesced reads and
  early requests deferred behind an unrelated decode read;
- redirects: preliminary and TAGE predictor redirects, backend correction and
  memory-replay redirects, target correction, architectural restart, flush,
  translation barrier, halt and WFI.

Boolean event columns are not mutually exclusive.  `stall_reason` is a single
primary attribution selected only to make aggregation convenient.  The raw
columns remain authoritative when several conditions coincide.

`flags[0:59]`, in ascending bit order, are:

```text
prediction_valid prediction_taken prediction_refined prediction_accept
splice_valid presentation_ready current_pending pending_any req_valid
req_ready resp_valid resp_ready btb_lookup btb_response btb_hit btb_root
btb_chain btb_queue_full btb_queue_enqueue btb_queue_dequeue btb_transfer
btb_reject btb_train tage_candidate tage_lookup_valid tage_lookup_accept
tage_response tage_taken tage_busy_skip refinement_accept refinement_changed
refinement_late tage_context_hit tage_context_claim tage_context_miss
bp_fetch_stall bp_decode_stall bp_capacity_stall bp_unresolved_target_stall
bp_preliminary_redirect bp_tage_resteer bp_deferred_redirect
bp_predict_redirect backend_redirect backend_memory_replay target_mispredict
control_flush control_restart exception_redirect translation_barrier halted
wfi frontend_enable backend_enable tage_decode_read tage_early_read
tage_dual_read tage_early_context_write tage_read_coalesced
tage_early_read_blocked
```

`lane_state` contains `decode_valid[2:0]`, `decode_ready[5:3]`,
`decode_fire[8:6]`, `control_select[11:9]`, `prefix_allow[14:12]`,
`live_lane_allow[17:15]`, `backend_ready[20:18]`,
`consume_halfwords[24:21]`, and `splice_halfword[28:25]`.

Primary reason codes are:

| Code | Name | Meaning |
|---:|---|---|
| 0 | `PROGRESS` | At least one decoded instruction fired or decode consumed a partial prefix |
| 1 | `HALT_OR_WFI` | Core halt or WFI state |
| 2 | `CONTROL_FLUSH` | Architectural backend flush |
| 3 | `ARCH_RESTART` | Control restart or exception vector |
| 4 | `BACKEND_REDIRECT` | Execution or memory-replay correction |
| 5 | `TARGET_REDIRECT` | Predictor target correction |
| 6 | `BP_PRELIM_REDIRECT` | Preliminary BTFNT/direct redirect |
| 7 | `BP_TAGE_RESTEER` | Decode-side TAGE path correction |
| 8 | `BP_DEFERRED_REDIRECT` | Retained-control deferred correction |
| 9 | `BP_OTHER_REDIRECT` | Other predictor redirect |
| 10 | `TRANSLATION_BARRIER` | Fetch inhibited by translation maintenance |
| 11 | `BP_UNRESOLVED_TARGET` | Targetless indirect blocks fetch |
| 12 | `BP_CAPACITY` | Predictor resolution/context capacity full |
| 13 | `BP_LOOKUP` | Other predictor lookup hold |
| 14 | `BACKEND_BACKPRESSURE` | Presented instruction cannot enter backend |
| 15 | `CONTROL_QUALIFICATION` | Decode prefix held around control prediction |
| 16 | `CURRENT_BLOCK_PENDING` | Current stream block request has not returned |
| 17 | `REFILL_PENDING` | Another demand fetch request is pending |
| 18 | `FTQ_EMPTY` | No stream target is queued |
| 19 | `BTB_QUEUE_FULL` | Stream-BTB response queue asserted full backpressure |
| 20 | `REQUEST_BLOCKED` | Instruction request valid without ready |
| 21 | `NO_PRESENTATION` | FTQ exists but no current bytes or pending request explain it |
| 22 | `DECODE_EMPTY` | Raw presentation is ready but decode emits no instruction |
| 255 | `UNKNOWN` | No current predicate explains lack of progress |

The codes describe observed combinational state and precedence, not a formal
proof that removing the named condition improves IPC.  In particular, a full
BTB or TAGE queue is recorded as state even when an already-buffered FTQ keeps
decode supplied.

## Reader

`tools/frontend_trace.py` reads plain or bzip2-compressed CSV, validates the
header, contiguous cycle sequence, field widths, Boolean values and progress
attribution, then reports stall causes, decode widths, occupancy, events and
post-redirect empty cycles.

Examples:

```sh
python3 tools/frontend_trace.py frontend.csv.bz2
python3 tools/frontend_trace.py frontend.csv.bz2 --events-only --rows 100
python3 tools/frontend_trace.py frontend.csv.bz2 \
  --stall-reason CURRENT_BLOCK_PENDING --rows 100
python3 tools/frontend_trace.py frontend.csv.bz2 \
  --start-cycle 150000 --cycles 200 --rows 200
```
