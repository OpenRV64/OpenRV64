# casim — cycle-accurate core model for the 3P Tomasulo core

`casim` models the machine in two halves that can be run separately or in
series. The **frontend** model generates instruction candidates — PC
generation, fetch block supply, 3-wide presentation, redirects — and stops at
the backend admission gate. The **backend** model takes a stream of candidates
from there and drives it through the scheduler, execution pipes, ROB and
in-order retirement. Its purpose is bottleneck exploration: cut the machine at
the gate, remove one half as a constraint, and see what the other half can
actually do.

    python3 tools/casim <golden.csv>                    # backend, anchored to the golden
    python3 tools/casim <golden.csv> --experiments      # rank what clogs
    python3 tools/casim <golden.csv> --branch-trace OUT # extract the control-flow record
    python3 tools/casim --frontend-only <golden.csv>    # frontend with nothing blocking it
    python3 tools/casim --backend-only  <golden.csv>    # backend fed at full rate
    python3 tools/casim --coupled       <golden.csv>    # both halves in series
    python3 tools/casim <golden.csv> --prf 40 --sched 24 --retire-width 4

Re-execs under `pypy3` automatically (a full CoreMark-scale run is ~2.5 s).
`CASIM_NO_PYPY=1` opts out.

## The two decoupled runs

**`--frontend-only`** removes the backend: the admission gate always accepts,
so the frontend never sees backpressure and the span it reports is its own
speed limit. It replays a **branch trace** — the fetch image plus every
redirect the machine performed, each with the prediction it made and the
latency it took to resolve — so it makes the same mistakes the real machine
made and pays the same refetch, with no re-implementation of the predictor.

The one number a frontend with no backend cannot compute is when a branch
resolves. Replaying the golden's per-branch latency is the default;
`--resolve-latency N` pins it to a constant and `--resolve-sweep` walks a
range, which turns out to be the most useful single knob in the tool.

**`--backend-only`** removes the frontend: it takes the candidate stream a
frontend run produced — **wrong path included** — and admits it at full width
every cycle, so nothing waits on delivery. Shadow instructions hold scheduler
entries, ROB entries and rename tags until their control transfer redirects,
then leave together. That is the point of feeding them: on the bp8 golden they
are 37% of the stream and about 29% of everything the scheduler ever holds, and
a correct-path-only stream cannot show that pressure at all.

The two chain through a file:

    python3 tools/casim --frontend-only <golden.csv> --dump-stream fe.stream
    python3 tools/casim --backend-only  fe.stream

A branch trace is a standalone artifact too, so a frontend-only run needs no
CSV once one has been extracted:

    python3 tools/casim <golden.csv> --branch-trace bp8.btrace
    python3 tools/casim --frontend-only bp8.btrace --resolve-sweep

## What the modes say about this core

On `pipeline-state-52448` (bp8, 52,527 cycles) and `pipeline-state` (oracle
branches + magic L1I, 38,161 cycles):

| run | bp8 span | oracle span |
|---|---:|---:|
| golden | 52,527 | 38,161 |
| `--coupled` (both models in series) | 52,516 (−0.02%) | 38,204 (+0.11%) |
| `--backend-only` (no delivery limit) | 40,049 (−23.8%) | 35,185 (−7.8%) |
| `--frontend-only` (no backpressure) | 43,895 (−16.4%) | 36,284 (−4.9%) |

- **The frontend never idles once the backend stops blocking it — it delivers
  a full 3 candidates every cycle.** What it delivers is the problem: 60% of
  that bandwidth is shadow work. Correct-path delivery is only 1.20
  instructions/cycle on bp8, and the resolve sweep shows why — at a
  one-cycle branch resolve the same frontend finishes in 21,061 cycles, and
  every 2× in resolve latency costs roughly 4,000 cycles.
- **Capacity stalls are a symptom, not the bottleneck.** In `--backend-only`,
  rename tags close the admission gate for 20–26% of all slots and the
  scheduler for 13–15%, but lifting the PRF entirely recovers 1.7% of span and
  lifting PRF, scheduler and ROB together recovers 4.1%. The critical path is
  issue, not admission, and issue is dependence-bound: 77% of blocked resident
  entries are waiting on sources, with memory ordering a distant second at 16%.
- **On the oracle golden the largest single source of discarded fetch is not
  branch misprediction.** 639 store instructions flush the pipeline and refetch
  their own successor while sitting in the LSQ on `MEMORY_ORDER`, discarding
  17,255 fetched candidates — 62% of all speculative fetch waste on that trace,
  against 3,622 for JALR mispredicts. The bp8 golden has none of these.

## Design

- **Branch trace** (`btrace.py`) is the control-flow record the frontend
  replays: a fetch image (PC → instruction, correct path and wrong path) and an
  ordered list of every redirect, each carrying its prediction, its
  architectural outcome, its resolve latency, and how much fetch it discarded.
  Redirects are found by walking the architectural instruction sequence and
  looking at the gap between consecutive entries — the work one redirect threw
  away — which catches the serialising and replay flushes that have no PC
  discontinuity to give them away.
- **Frontend** (`frontend.Frontend`) is a per-cycle model of PC generation,
  fetch block supply over a resident window, 3-wide candidate presentation, and
  redirect handling. Its admission gate is a policy object: `IdealGate` never
  backpressures (frontend-only mode), `GoldenGate` replays the golden's
  admission timing (validation).
- **Backend** (`machine.Machine`) is a deterministic single pass over cycles.
  Within a cycle: remove squashed work, retire in order from the ROB head,
  admit from the frontend, then wake / select / issue. It encodes the RTL
  policies from `dispatch_window_3p.v` (persistent-hard head gating, branch
  order, store-at-LSQ-head, load/store memory ordering, the EX0/EX1/MEM0/MEM1
  fixed lane capabilities) and the measured latencies (alu/branch/jump 1, load
  3 magic, muldiv worker latency replayed).
- **Stream** (`stream.SInsn`) is the shared currency. Correct-path
  instructions take their class and register dependences from ROB detail0,
  which is authoritative; synthesised wrong-path work is decoded from the
  instruction word (`isa.py`). Dependences come from a last-writer walk with
  rename rollback at every redirect, so a correct-path instruction after a
  squash never reads a wrong-path producer.
- **Idealisation knobs** (`config.Config`) are the "take the restriction off"
  levers: `ideal_frontend` (inject the whole stream at full width),
  `ideal_sched`, `ideal_rob`, `ideal_prf`, plus width, latency, fetch-supply
  and redirect-timing overrides.

## Frontend timing constants

Measured from the goldens, not assumed — `probe`-style checks on
`pipeline-state-52448`:

| constant | measured | default |
|---|---|---:|
| predicted-taken redirect, admit → corrected fetch | +1 (73%), +2 (26%) | 1 |
| mispredict redirect, complete → corrected delivery | +1 (99%) | 1 |
| candidates presented per cycle from a resident block | 3 (71% of sequential pairs same cycle) | 3 |
| L1I refill | this profile's I-side is effectively resident | 0 |

The fetch block machinery (`--fetch-block`, `--fetch-window`, `--l1i-refill`)
is a knob rather than a fitted result: on this workload only 27 64-byte blocks
are ever touched and redirect refetch lands at +0/+1, so the model reproduces
the golden with refills free and the window inert. The window is direct-mapped
with a rolling request cursor ahead of the fetch PC, so raising
`--l1i-refill` asks what a real I-side would cost, and `--fetch-window` says
how much of it the carousel hides:

| refill | window 2 | window 4 | window 8 | window 16 |
|---:|---:|---:|---:|---:|
| 0 | 43,895 | 43,895 | 43,895 | 43,895 |
| 4 | 67,083 | 64,033 | 62,320 | 58,918 |

Four cycles of refill costs the frontend 46% at the shipped four-block window,
and quadrupling the window buys only 8% of it back — the misses are redirect
targets, not sequential run-ahead, so a deeper carousel does not help much.

## Validating the frontend

`--coupled` is the end-to-end check and lands within 0.11% of both goldens. The
per-instruction check is delivery timing against the golden's own
`fetch_first_cycle` on the architectural path, with the golden's backpressure
replayed at the gate: **82.9% exact, 98.7% within one cycle** over all 52,591
architectural instructions of the bp8 golden, with admitted shadow volume
30,860 against the golden's ~30,908.

Only the architectural path is identity-matched. Shadow work is not: a
one-cycle difference in redirect timing changes how many candidates a shadow
holds, so pairing them by fetch position desynchronises permanently and
measures nothing. Shadow is checked in aggregate instead.

## Memory

Data memory is **not** modelled here — the cache hierarchy is Bill's domain and
deliberately out of scope for the core model. Two regimes:

- **magic** (default): every load hits at `lat_load`. This is the intended
  first target ("magic memory, focus on the core").
- **mem-replay** (`Config.mem_replay`): inject the real per-load latency
  captured from a real-memory golden. Note this double-counts against a golden
  whose frontend anchor already encodes backend memory stalls; see below.

## Golden traces and validation status

Validation golden is a committed trace, decompressed:

| committed .bz2 | span (cyc) | config |
|---|---:|---|
| `pipeline-state.csv.bz2` | 38,161 | oracle branches + **magic L1I** + DDR3 data, 64 ROB / 32 sched / 63 PRF, 3-wide |
| `pipeline-state-oracle.csv.bz2` | 42,585 | oracle branches, real memory |
| `pipeline-state-52448.csv.bz2` | 52,527 | bp8 production (post-JALR-relax) |
| `pipeline-state-pre-jalr.csv.bz2` | 68,386 | bp8, pre-JALR-relax |

Current status against `pipeline-state.csv` (38,161):

- **Span: −8 cycles (0.02%).** The admission-anchored macro-behaviour is
  correct; structural sweeps reproduce known results (PRF non-binding ≥48,
  costs +1.7k at 40).
- **Per-instruction exact: ~4–7%.** The gap is *not* a core-model error: this
  golden is magic-L1I but **real DDR3 data memory**, so its frontend anchor
  already bakes in backend memory stalls. Validating a magic core
  per-instruction against it is ill-posed (anchor and backend are
  magic-inconsistent). The clean per-instruction target is a
  **magic-everything** (magic L1I + magic L1D) oracle golden. `--` the
  `taint_memory` split in the validator quantifies the coupled slice (37.7% of
  insns here).

## Keeping current with trunk

The model's timing constants and policies track top-of-trunk RTL and must be
re-checked when the backend changes (JALR/branch policy, store launch rule,
retire width, PRF sizing). Regenerate the golden from the same commit and
re-run validation.

### Regenerating goldens (toolchain note)

Regenerating a golden needs the SoC-trace Verilator build. In a clean
Debian-Verilator-5.032 (and a source-built 5.050) environment this hits a
Verilator internal error, `V3Delayed.cpp: Multiple Write refs on LHS of NBA`,
whenever an NBA left-hand-side array index contains a value-returning SV
function (`arr[func(...)] <= x`) — it appears in `rtl/cache/l1/l1.v`
(`line_index_of`) and `rtl/soc/memory/mem_channel.v`
(`write/read_data_index_of`, `memory_index_of`, and `burst_address_at` nested in
the memory-write NBA). A candidate workaround (index functions → textual macros,
plus hoisting the one nested value-function index into a blocking temp) makes it
Verilate and build, but is **not correctness-verified** — the rebuilt sim
completed with a wrong CoreMark self-check result, un-attributable here between
the RTL rewrite and the local `riscv64-unknown-elf` toolchain. Validate on a
known-good toolchain before trusting a regenerated golden.
