# camsim — cycle-accurate modular simulator

A core model assembled as **modules on an event bus** rather than as one
program. Each module announces the signals it drives and subscribes to the
ones it reads; the bus wires them at elaboration and clocks them. Nothing calls
anything directly, so a module can be replaced by a different implementation,
by a recording, by an ideal stub, or by a process on the other end of a pipe,
and its neighbours do not change.

Sibling: `tools/casim` is the monolithic model this is the modular form of.
**Nothing is copied from it yet** — this tree is the protocol plus a toy graph
that exercises it.

```bash
python3 tools/sim/camsim check                    # 19 checks on the bus's own guarantees
python3 tools/sim/camsim demo --watch             # toy graph, every signal fire
python3 tools/sim/camsim demo --graph             # print the wiring
python3 tools/sim/camsim demo --remote            # one module in a child process
python3 tools/sim/camsim demo --reset-steps 4     # rst_n held longer
python3 tools/sim/camsim demo --record f.rec      # then --replay f.rec
python3 tools/sim/camsim demo --wave run.vcd      # VCD, settling on the time axis
```

Re-execs under `pypy3` automatically; `CAMSIM_NO_PYPY=1` opts out. Both
interpreters produce identical runs.

---

## 1. The bus is a clock, not a queue

The obvious event bus calls subscribers the instant something is published.
That is blocking-assignment semantics: the result depends on the order modules
happened to be registered, and a module that publishes early in a cycle sees a
different world than one that publishes late. **A publish is never visible to
anyone during the round in which it was made.**

One cycle:

| phase | what happens |
|---|---|
| **edge** | pulses clear; REG values published during cycle N−1 become visible, at depth 0. These are the flops. |
| **deltas** | every module subscribed to something that just fired is woken and may publish COMB. Those publishes become visible at the *next* delta. Repeat until nothing fires — the cycle has settled. |
| **tick** | every module runs its edge behaviour and publishes REG for cycle N+1. |

Because nothing published in a round is readable in that round, **wake order
within a round cannot change the result**. That is the whole guarantee, and it
is what `check order_independence` tests: the same three modules registered in
all six orders must give the identical run.

## 2. Clock, reset, and saying "I'm done"

`clk` and `rst_n` are ordinary signals, published by one small unit that sits
on **every** bus. Not a bus property, not one clock per bus — per-bus clocks
would let two halves of a machine drift, which is not a machine.

```python
clk = Clock(reset_steps=2)
core.add(clk.port())
side.add(clk.port())        # same unit, second bus
```

`clk` is a REG PULSE meaning *your domain edges this step*, not a level that
toggles — one step is one edge opportunity rather than half a period, so the
single-domain case costs nothing and a divided domain is just a clock that
pulses on some steps and not others. `ClockDiv` and `ClockGate` are twelve-line
modules that republish it; a gated module simply stops ticking and costs
nothing while idle.

`rst_n` is a REG LEVEL, read in `tick` as `if bus.resetting(): ...` — the
`always_ff` idiom. This is why reset is a signal and not a lifecycle callback:
a callback runs once, and cannot express a machine that resets twice or one
whose halves release at different times. `build()` is now only python-side
construction.

**`sys.done`** is how a module says it has finished the step, and **the clock
will not pulse again until every bus reports done**:

```python
class Slow(Module):
    contributes = ["sys.done"]
    def comb(self, bus):
        bus.pub("sys.done", self.reply_arrived)
```

That is what makes a module on another thread, another process, or another bus
safe — the clock cannot run ahead of work that has not landed. The decision is
made in a *pre-step* hook, not in anybody's `tick`, so it happens after every
bus has finished the previous step rather than in the middle of one: a stall
costs exactly one step and no bus can observe a different clock than another.
`clock.time` counts edges, `bus.cycle` counts steps, and once anything stalls
those are different numbers.

The obvious deadlock — withholding `done` while needing an edge to make
progress — is real. The rule is that a withholder must be driven by something
other than the clock it is stalling (a reply, a queue, a free-running module).
`stall_limit` catches the rest rather than hanging.

## 3. Signals: two axes

Declared once, by the module that drives them.

**kind** — when a publish becomes visible:

| | |
|---|---|
| `ASYNC` | same cycle, next delta. No flop between the two modules. |
| `REG` | next cycle, at the edge. A flop between the two modules. |

`ASYNC` is **not** combinational logic, and it is worth being exact about that.
Real gates — the comparator, the priority encoder, the mux tree — live *inside*
a module as ordinary code, and the bus never sees them. What crosses the bus is
only the question of *when* a value becomes visible: this cycle or next. A
module may be one inverter or four hundred gates; from the bus it is one hop
either way.

**mode** — what a publish means:

| | |
|---|---|
| `LEVEL` | holds its value; *fires* only when the value changes, so a steady value wakes nobody. |
| `PULSE` | a strobe; fires on any publish of a non-idle value, and auto-clears to `default` at the next edge, so a stale valid cannot be read next cycle. |

One exception to single-driver: a **merged** signal is wired across many
drivers, reduced by `and`/`or`/`sum`/`max`/`min`. One module declares it, the
rest name it in `contributes`. It exists because `sys.done` genuinely has many
drivers, and it is the right shape for any other "any-of"/"all-of" condition.

```python
publishes = [out("fetch.block", COMB, PULSE, doc="block presented this cycle"),
             out("rob.full",    COMB, LEVEL, False),
             out("ex0.result",  REG,  PULSE)]
subscribes = ["sched.ready", "redirect.*"]
```

## 4. The module interface

```python
class Stage(Module):
    name = "stage"
    publishes  = [out("stage.item", REG, PULSE)]
    subscribes = ["src.item"]

    def build(self, bus):  ...   # once at elaboration; python-side setup only
    def settle(self, bus): ...   # woken at each delta where a subscription fired
    def tick(self, bus):   ...   # on every edge of *this module's* clock; REG only
    def report(self):      ...   # whatever the run should collect
```

That is the entire protocol. `bus.get(sig)` reads, `bus.pub(sig, v)` writes,
`bus.fired(sig)` asks why you were woken, `bus.cycle` is the cycle number.

## 5. Five rules, all of them the hardware's

**`settle()` must be pure.** It may publish; it must not mutate module state.
Settling re-runs it as often as its inputs move, and a module woken with a
half-settled input can publish a value it withdraws two deltas later — exactly
as real logic glitches before it settles. Counting something in `settle` counts
the glitches. State changes belong in `tick`.

**Drive your output on every evaluation**, idle value included, the way a
continuous assignment does. Withdrawal is explicit: publishing `None` (or
whatever `default` is) takes an offer back off. Publishing the default of a
pulse that is already idle is a no-op, so always driving does not spin the
settling loop.

**Read only what you subscribe to** (plus what you drive). This is the port
list. It is also precisely why an out-of-process module behaves identically —
the host sends it exactly the signals it declared, and nothing else exists.

**One driver per signal.** Checked at elaboration.

**Read values, not wake reasons.** `bus.fired(sig)` asks *is this asserted this
cycle* — a pulse whose value is not idle, or a level that differs from what it
was at the edge — and it means the same thing in every phase. It deliberately
does not mean "did this wake me": a module is re-woken whenever any input
moves, so logic keyed on the per-delta question gets a different answer on the
second wake and publishes something it has already contradicted. `woke_on()` is
the per-delta question, for observers recording transitions, and must not
decide what a module drives.

**Payloads need value equality.** The bus decides a signal fired by comparing
values. A module that builds its payload fresh each evaluation — a list of
newly allocated records — publishes something equal in meaning but unequal by
identity, which reads as a change: a spurious fire, an extra wake downstream,
and a async depth reported one level deeper than the signal settles at.
Give payload classes `__eq__`/`__hash__`, or reuse the objects.

The first two rules are not stylistic. `check no_glitch_latch` is the case that
broke the first version of this bus: a producer evaluated with a stale `ready`,
offered an item, `ready` fell later in the same cycle, and the offer could not
be withdrawn — the sink overflowed. `fired()` is phase-aware for the same
reason: during `settle` it means *this delta* (the wake reason, possibly a
glitch), during `tick` it means the **settled** answer a flop would latch. A
pulse that ended at its idle value did not fire, however many times it moved on
the way there. `bus.glitched(sig)` reports the difference, which names paths
that toggle for nothing.

## 6. Waking

A module is woken when something it subscribes to fires — and since every
module implicitly subscribes to its clock, **everything is woken once per
edge**. That removes the one real footgun of a pure event bus: a module whose
async output depends on its own flop state, with no signal to wake it
when that state changes. It costs a full evaluation per edge, which for a
core-sized model is nothing.

Two escapes remain for a module declared `clock = None` (an observer, a purely
async block, a free-running unit): `always_comb = True` wakes it at
delta 1 of every step, and `bus.wake_next()` from `tick` wakes it only on the
steps where its state actually changed.

## 7. Timing, for free

An ASYNC signal's **delta depth** counts *module hops* from the flop that
started the cascade — not logic levels, which the bus cannot see. It answers a
structural question, and a real one: how many units have to resolve in series
before the cycle settles. A chain of five units inside one cycle is a chain of
five units however small each one is, and that is the shape a critical path
takes.

For the number to approximate logic levels, a module declares how much logic it
is (`logic_depth = 6`); depth then accumulates by declared weight instead of by
one, and the report says "estimated logic levels" rather than "module hops".
Depth resets at every edge, so it is a per-cycle measurement, and the bus keeps
the per-signal maximum plus the chain behind the deepest signal in the run:

```
worst path: depth 2 at cycle 0, settling on src.item
    1  sink.ready
    2  src.item
```

**Use it as a differential.** "depth(x) went 3 → 6 when I added the bypass" is a
real statement about a path that got longer; "depth 6 will not close at 50 MHz"
is not. `Bus(timing=False)` drops the bookkeeping.

A async loop is a cycle that never settles; the bus aborts at
`max_delta` and names the signals still oscillating and the modules still
waking.

## 8. Waves

`Wave` is an ordinary module that listens: it declares subscriptions, drives
nothing, sits off the clock, and adding one cannot change a run — which
`check wave_is_an_observer` verifies by running with and without it. It does
raise the `wakes` count, because it is a module and it gets woken; `deltas`,
`publishes`, the span and every result are untouched, since a module that
publishes nothing cannot cause a fire.

```python
bus.add(Wave("run.vcd", ["fe.*", "rob.*"]))     # or ["*"]
sysm.wave("run.vcd")                            # every bus, one file, one time axis
```

The one real decision is the time axis. A dump with one timestamp per step
throws away the thing this model knows that a functional model does not — the
delta each signal settled at. So a step is a *block* and a delta is a tick
inside it:

```
time = step * step_ticks + delta        # default 1000 ps per step
```

At nanosecond zoom that reads as an ordinary cycle-by-cycle waveform. Zoom into
a step and the settling order is laid out left to right — this is the demo's
backpressure case:

```
#1000  clk↑, rst_n↑          step 1 edge: the flops
#1001  sink.ready = 1        delta 1 — one level of logic from a flop
#1002  src.item   = 0        delta 2 — gated by ready, so two levels
#1500  clk↓, pulses clear    half-step
#2000  clk↑, stage.item = 0  registered, so back to depth 0
```

That is what `timing.report` prints as numbers, drawn. The critical path is
whatever is furthest right inside the step.

PULSE signals render high for half a step. The assertion really covers the
whole step — the width is a display convention — but it makes `clk` read as a
50% duty clock and a strobe read as a strobe. It also makes a stall visible:
**a step where `sys.done` was withheld is a step with no clock pulse**, a hole
in the waveform.

`None` is undefined, not the text `"None"` — it renders as `x` whatever the
signal's type, so an unasserted pulse reads as blank rather than as a word.

Types come from each signal's `default`, the only static type information the
bus carries: bool → 1-bit wire, int → 64-bit vector, float → real, anything
else → string var (GTKWave draws those as labelled boxes, which is what you
want for a payload like an instruction). A string-typed PULSE also gets a 1-bit
`<name>_fired` companion, because a text trace shows the payload but not the
density of activity. Declaring `out("rob.full", COMB, LEVEL, False)` instead of
leaving the default `None` is therefore worth doing for its own sake.

## 9. Dual mode: in process, or down a pipe

Same protocol both ways. `RemoteModule` is a `Module` like any other — it takes
its `publishes`/`subscribes` from the child's manifest at connect time, and the
bus wires it without knowing there is a pipe.

```python
bus.add(demo.Stage())                                    # in process
bus.add(hosted("camsim.modules.demo:Stage"))             # child process
```

The child runs the **unmodified module class** against a bus shim with the same
surface, which is the point — if a module can tell which side of a pipe it is
on, the protocol has failed. `check local_equals_remote` demands identical runs.

Frame = 4-byte length + payload; codec `pickle` (default, python↔pypy) or
`json` (portable, for a module written in another language, at the cost of
JSON-representable signal values).

| host → module | | module → host | |
|---|---|---|---|
| `HELLO` | proto, codec | `MANIFEST` | name, publishes, subscribes, always_comb |
| `RESET` | | `PUB` | pubs, wake |
| `DELTA` | cycle, delta, fired{sig: val} | `PUB` | pubs, wake |
| `TICK` | cycle, fired{}, vals{} | `PUB` | pubs, wake |
| `FINISH` | | `REPORT` | |

**The cost model is the hardware's.** A ASYNC signal crossing the process
boundary costs a round trip *per delta*, because the host cannot advance the
settling round until the remote answers. A module whose outputs are all REG
costs no stall at all: the host sends `TICK` to every remote first and collects
the replies afterwards (`comb_flush`/`tick_flush`), so N remote processes
compute their edge concurrently. Registering the boundary is what makes it
cheap to distribute — the same reason registering a boundary is what lets you
place two blocks far apart on a die.

`TICK` carries `vals` as well as `fired` because a remote's last wake may
predate the final delta; without the settled values a remote flop would sample
a stale input and the two modes would diverge.

## 10. The decoupled runs fall out of the graph

This is why the bus exists. To run the frontend with no backend, replace the
backend with a tie-off; to run the backend with no frontend, replace the
frontend with a recording. **Neither the frontend nor the backend module learns
a mode flag**, because from where they sit nothing changed.

```python
bus.add(Const({"admit.ready": 3}))            # gate never backpressures
bus.add(Replayer("fe.stream"))                # candidates, wrong path included
bus.add(Recorder("run.rec", ["rob.*"]))       # observe anything, change nothing
```

The elaborator then tells you what you decoupled: replaying the producer in the
demo warns `sink.ready is driven by sink but nobody subscribes` — the
backpressure path is gone, which is exactly the experiment.

One caveat: a recording keeps the cycle a signal fired, not the delta it
settled at, so a replayed ASYNC signal is republished at the first delta of its
cycle. Cycle behaviour is exact; settling order is not, so **a run with a
Replayer in it should not be read for timing.**

## 11. Many buses

A bus is a scope: its own signal namespace, its own settling, its own wake
traffic. Several of them isolate a subsystem so its noise does not reach the
rest — and with the same seam, put it on another thread or in another process.

```python
sysm = System(clock=Clock(reset_steps=1))
core = sysm.add(Bus(name="core"))       # the shared clock is ported onto each
side = sysm.add(Bus(name="side"))
core.add(Export(ch)); side.add(Import(ch))
```

**A crossing is always registered.** A ASYNC signal spanning two buses would
force their delta loops into lockstep, defeating the isolation and making
threading impossible; a REG crossing costs one step and nothing else. Third
time the same rule has paid — registering the boundary is what makes it cheap
to distribute, across a bus, a thread, a process, or a die. Determinism does
not depend on which bus steps first: `Export` tags what it sends with its step
and `Import` takes only tags strictly older than its own.

Worth being blunt about threads: CPython and PyPy both hold a GIL, so a bus per
thread buys isolation and I/O overlap, **not throughput**. The boundary that
actually parallelises is the process one, and it is the same boundary.

## 12. Elaboration checks

Port-connection rules, applied before step 0:

- two drivers on one signal → error (unless it is declared merged)
- subscription to a signal nobody drives → error (`strict=False` downgrades to
  a warning, for deliberately decoupled graphs)
- a driven signal nobody subscribes to → warning (dead output)
- ASYNC published at the clock edge, at build time, or in a pre-step hook →
  error (only a flop can be driven there)
- a module whose named clock nobody drives → error, like any dangling input
- publishing a signal you do not drive, or reading one you did not subscribe to
  → error

## 13. Layout

| file | |
|---|---|
| `bus.py` | the clock, the delta loop, elaboration, depth accounting |
| `module.py` | `Signal`, `Module` — the protocol a module implements |
| `wire.py` | the same protocol serialised: framing, codecs, messages |
| `remote.py` | host side of an out-of-process module |
| `hosted.py` | remote side: `python3 -m camsim.hosted pkg.mod:Class` |
| `link.py` | `Channel`, `Export`, `Import` — the registered crossing between buses |
| `system.py` | several buses and the one clock they share |
| `modules/clock.py` | `Clock`/`ClockPort`, `ClockDiv`, `ClockGate` |
| `modules/fetch.py` | the fetch unit, ported from `casim.frontend` |
| `modules/decode.py` | decode: instruction word to operation |
| `modules/dispatch.py` | the admission gate, and where speculation is decided |
| `modules/resolve.py` | armed redirects, timing and arbitration |
| `modules/stubs.py` | `IdealBackend`, `NoRedirect`, `NoStash` — stand-ins |
| `probe.py` | `Const`, `Recorder`, `Replayer`, `Watch` |
| `wave.py` | `Wave`, `VCDWriter` — VCD out, deltas on the time axis |
| `timing.py` | delta-depth report, wiring dump |
| `selftest.py` | the checks behind `camsim check` |
| `modules/demo.py` | toy graph: source, registered stage, sink with backpressure |

`modules/` is where the real thing goes.

## 14. What is ported

The whole frontend, as four units:

| unit | from | what it owns |
|---|---|---|
| `Fetch` | `frontend` phase 1–2 | fetch PC, resident-block window, presentation queue, redirect flush |
| `Decode` | `frontend._fill` | instruction word → operation. Stateless |
| `Dispatch` | `frontend` phase 3 | admission gate, shadow-path decision, event matching, redirect arming |
| `Resolve` | `frontend` phase 1 | armed redirects, when they land, which wins |

```bash
python3 tools/sim/camsim frontend bp8.btrace
python3 tools/sim/camsim frontend bp8.btrace --resolve-latency 1
python3 tools/sim/camsim fetch bp8.btrace --refill 4 --wave fetch.vcd
```

### It reproduces casim exactly

Against `casim --frontend-only` on both committed goldens — not close, identical:

| | oracle | | bp8 | |
|---|---:|---:|---:|---:|
| | casim | camsim | casim | camsim |
| span | 36,284 | **36,284** | 43,895 | **43,895** |
| fetched | 108,727 | **108,727** | 131,561 | **131,561** |
| correct-path | 52,591 | **52,591** | 52,591 | **52,591** |
| shadow | 56,136 | **56,136** | 78,970 | **78,970** |
| correct-path IPC | 1.449 | **1.449** | 1.198 | **1.198** |
| predicted-taken | 5,645 | **5,645** | 6,065 | **6,065** |
| wrong-path-predict | 2,820 | **2,820** | 2,941 | **2,941** |
| mispredict | 618 | **618** | 1,007 | **1,007** |
| implicit-redirect | 645 | **645** | 6 | **6** |

The resolve sweep lands on casim's numbers too — 21,061 cycles at a one-cycle
resolve on bp8, against 43,895 replayed, so the same conclusion survives the
port: **frontend speed is branch-resolve latency**, and roughly 4,000 cycles
per doubling.

| resolve | 1 | 2 | 4 | 8 | 16 | replay |
|---|---:|---:|---:|---:|---:|---:|
| bp8 span | 21,061 | 22,074 | 24,100 | 28,152 | 36,256 | 43,895 |

`check frontend_matches_casim` runs the same comparison on synthetic control
flow carrying all four redirect cases — predicted-taken right and wrong,
predicted-not-taken wrong, and an implicit serialising refetch.

### Where the boundaries went

`fetch.cands → decode.ops → dispatch → fetch.taken` is all ASYNC: one
same-cycle region, because the machine admits in the cycle it fetched. That is
not a modelling shortcut — `rtl/core/fetch/fetch_3w.v` drives `decode_valid_o`
with a continuous assignment off `lane_found_r`.

Dispatch is one unit rather than three because its loop is sequential *within*
a cycle: admitting a predicted-taken branch makes the very next candidate in
the same cycle shadow work. Where two things resolve in series inside one
cycle, they are one unit — that is the rule that decides where a module
boundary goes, and it is why `Resolve` is separate (a flop sits between it and
fetch) while the gate is not.

`dispatch.stash` is a real signal, not a convenience: it is `req_stash_o`,
dispatch asking fetch to bring the not-taken side resident so a mispredict
finds it there.

Two static artefacts still arrive as constructor arguments rather than signals
— the fetch image and the control-event trace. Both are replay inputs, and both
are the seam for a real unit: an L1I module that publishes responses, and a
predictor that publishes predictions. Until those exist the frontend replays
the golden's control flow, which is exactly what casim does and why its
frontend-only number means anything.

### Next

The backend: scheduler, ROB, execution pipes, retirement (`casim.machine`).
`backend.credits` is already the signal it drives — replace `IdealBackend` with
the real thing and the frontend does not change. Watch the wakeup → select →
issue loop when it lands: registering that boundary costs a cycle per
*dependent instruction*, not per boundary, and this model says the backend is
77% dependence-bound.

## 15. Where a boundary may be async

The reason to care about an ASYNC export is not any claim about gates — it is
that two modules joined by one are **not finished until both are**. They settle
together, so they cannot be split across a thread, a process or a bus without
changing the machine by a cycle, and every settling hazard in section 5 lives
inside such a region. `bus.regions()` reports them, and
`Bus(async_policy="warn"|"deny")` enforces a boundary-is-a-flop discipline
where you want one.

So: what does registering a boundary cost? Measured on the fetch/gate handoff
against casim, 400 instructions, deliberately including a gate that
backpressures:

| gate | casim | async handoff | registered, credit-based |
|---|---:|---:|---:|
| never blocks | 134 | 134 (exact) | 135 (+0.7%) |
| blocks 1 of 2 | 267 | 267 (exact) | 269 (+0.7%) |
| blocks 2 of 5 | 223 | 223 (exact) | 227 (+1.8%) |
| blocks 6 of 8 | 535 | 535 (exact) | 543 (+1.5%) |

Registering a **feed-forward** boundary costs a few cycles of pipeline fill plus
a skid buffer of about 2× the width — it is not proportional to the number of
stalls, only to the number of stall *onsets*. That is cheap, and if the whole
frontend were registered end to end it would stay cheap.

A **feedback** boundary is the opposite case and the one to protect. Wakeup →
select → issue closes a loop inside a cycle: register it and every dependent
instruction takes one more cycle, which is per-instruction, not per-boundary.
On a workload this model says is 77% dependence-bound that is not a rounding
error. Unmeasured so far — the backend is not ported — but it is the mechanism
to watch, and the reason `async_policy` is a per-bus choice rather than a rule.

For the record, the RTL agrees that the fetch boundary is async:
`rtl/core/fetch/fetch_3w.v` drives `decode_valid_o` with a continuous
assignment off `lane_found_r`.

## 16. Open, before more is ported from casim

- **Signal granularity.** One signal per architectural bundle
  (`fe.candidates` carrying a 3-wide list) or one per lane
  (`fe.cand[0..2]`)? Per-lane gives honest per-lane depth numbers and finer
  wakes; per-bundle is far fewer events. Probably per-bundle to start, split
  where a depth number turns out to matter.
- **Squash.** A broadcast `redirect` signal every speculative holder subscribes
  to, or point-to-point? Broadcast matches the RTL and keeps modules ignorant
  of each other, but it wakes everything on every redirect.
- **Where the bus boundaries go.** Frontend / backend / memory is the obvious
  cut, and it matches the decoupled runs. But every crossing costs a registered
  step, so cutting the fetch-to-admit path changes the number the model exists
  to measure. Probably: one bus for the core, a second for anything whose
  latency is already many cycles (memory, an external agent).
- **Whether the ROB is one module or three.** Allocation, completion and
  retirement have different natural owners but share one state array; sharing
  state across modules is exactly what the bus is supposed to prevent.

## 17. It executes

The replay path above reproduces a trace. The **execute** path runs real RV64
code against real memory, behind real translation, through real caches:

```bash
python3 tools/sim/camsim run              # bare, machine mode
python3 tools/sim/camsim run --sv39       # supervisor, behind a page table
```

| unit | what it owns |
|---|---|
| `PhysMem` / `Sram` | one backing store, several ports |
| `L1` | 16 KiB 4-way 64 B, read-allocate, write-through no-write-allocate, per-beat refill |
| `Mtl` | Bare/Sv39, micro-TLBs, the blocking walker, PMP; independent I/D paths |
| `bp.Tournament` | bp8: 2048x3b global / GHR 11, 512x10b local, 512x2b chooser, 256-entry BTB, RAS |
| `IFetch` | virtual PC, line requests through the MTL |
| `Issue` | rename over 63 physical registers, Tomasulo window, out-of-order issue |
| `Exu` / `Lsu` | ALU/branch 1 cycle, mul 3, div 12; agen, ordering, store-to-load forwarding |
| `Rob` | in-order retirement: registers, memory, CSRs, mispredict redirect, MRET/SRET |

`rv64.py` is RV64IM plus enough Zicsr to boot and stop. An unimplemented
encoding raises rather than falling through to `add`.

**Sv39 is the MTL's, not each unit's.** Fetch asks for a virtual line and the
LSU for a virtual address; neither contains a walk. Verified against a
hand-built page table: 4K and 2M mappings, R/W/X/U/A/D, SUM, privilege,
non-canonical VA rejection, PMP denial on both PTE reads and post-translation
targets. A store is translated and checked at the LSU but **committed at
retirement**, because a store that has not retired is speculative.

## 18. Running the golden's own program

`pipeline-state.csv` is **`sw/coremark_loop.c` with an Sv39 stub loader** --
`sw/runtime/sv39.S` sets mtvec and PMP, builds a page table, writes SATP and
`MRET`s into supervisor mode at VA `0x40001000` where the payload runs.

**Use the shipped binary: `core/CORE_3P_VM_ELF-coremark-loop-vm.elf`.** Do not
rebuild it. The make target uses `riscv64-elf-gcc`; building with
`riscv64-unknown-elf-gcc` and the same flags produces a *different program* --
297 of 367 common PCs hold different instructions, diverging from
`0x4000105c`. The prologue matches, which is exactly what makes the mistake
easy: checking the first ten instructions confirms nothing. Check all of them
against the trace's own `pc -> instr` map, which takes a minute and is the only
way to know.

Two things had to exist first. `MRET`/`SRET` now restore the privilege their
mode-return bits name and redirect to the EPC -- entering a trap is still not
modelled, but a boot stub dropping into supervisor mode is how a machine
starts, not an exceptional path. And `load_elf` places segments at their
**physical** address: the image is linked `.text 0x40001000 : AT(0x80001000)`,
so loading by `p_vaddr` puts the payload where the machine will never look.

**Read the golden's configuration from the golden, not from a README.** This
file has been regenerated at least once during development, and the accepted
description of it (casim's, and an earlier version of this one) said "oracle
branches + magic L1I", which it is not. Two measurements settle it in a
minute: 29,332 of 81,925 fetched instructions never retire, so it mispredicts
and its branches are not oracles; and 0.05% of its loads take more than forty
cycles, which is DRAM. It is **bp9 (TAGE) with DDR3**.

| | camsim | golden |
|---|---:|---:|
| span | **40,620** | **40,407** |
| retired | **52,588** | **52,593** |
| IPC | 1.295 | 1.302 |
| squashed | 40.5% | 35.8% |
| result | `0x0a27789d` | -- |

**+0.5% on span, and the retired count agrees within five instructions** --
which is the check that says the two are running the same program at all.
Per-class issue-to-complete:

| class | camsim p50 / mean | golden p50 / mean | |
|---|---|---|---|
| alu | 1 / 1.00 | 1 / 1.02 | matches |
| branch | 1 / 1.00 | 1 / 1.03 | matches |
| jump | 1 / 1.00 | 1 / 1.03 | matches |
| load | 5 / 5.18 | 3 / 3.89 | 1.3 cycles long |
| store | 3 / 5.13 | 6 / 6.57 | faster; boundaries differ |

Retire mix is close too: idle 35.9% vs 36.9%, 1/cycle 33.4% vs 34.1%,
2/cycle 30.0% vs 25.5%, 3/cycle 36.6% vs 40.4%.

### The aggregate agrees; the components do not

Worth stating plainly, because a 0.6% span match invites more confidence than
it has earned. Loads are still 1.3 cycles long and 5 points more work is thrown
away -- both *worse* than the golden -- and yet the total lands. Something is
compensating, and the candidate is instruction supply: `IFetch` keeps its own
line buffer, so the L1I sees **28 reads in the whole run** and fetch is very
nearly free here where the real machine pays for it.

**There is no DRAM model.** Below the L1 is a dict with zero latency; an L1
miss costs `hit_latency + beats x beat_cycles` = 9 cycles flat. No tRCD/tCL/tRP,
no bank or row state, no refresh, no controller queueing. That is defensible
only because this workload fits in 16 KiB -- **40 L1 misses in the entire run**,
and the golden agrees (0.05% of its loads exceed 40 cycles). On anything with a
real working set the number would not survive.

### The page screen

`mtl.v` carries a four-entry PLRU **page screen** per side
(`ENABLE_FETCH_PAGE_SCREEN`, `LSU_PAGE_SCREEN_ENTRIES = 4`) checked in the
accept path. A hit lets the request be accepted *and launched in the same
cycle* (`xlate_request_fire && lsu_page_hit_r`) and lets the cache's answer
bypass the normal response path (`fetch_page_screen_resp_bypass`).

It is not a second TLB. It is small enough to sit in the accept path at all,
which is the whole point -- a sixteen-entry micro-TLB cannot, and that is why
the fast path is gated on the screen rather than on any translation hit. Four
entries sounds far too few until you notice it caches *pages*: a loop touching
code, stack and one array is three pages and stays hot indefinitely. Measured
here: **99.96% hit rate on four entries**, 13,750 accesses taking the fast
path, and it removed the MTL accept hop outright (dreq -> l1req went to 0.00
cycles).

Modelling it also fixed the fast path I had already tried and gated off. The
general "any TLB hit passes through" version hung; gating on the screen is
both what the RTL does and a narrow enough condition to be correct.

### Where a load's cycles went

Measured hop by hop, which is the only way this was ever going to be found:

| hop | before | after |
|---|---:|---:|
| select -> dreq | 4.50 | 3.88 |
| dreq -> l1req (MTL accept) | 1.00 | **0.00** |
| l1req -> l1resp (cache) | 2.01 | 1.00 |
| l1resp -> dresp (MTL response) | 1.00 | 1.00 |
| dresp -> done | 0.00 | 0.25 |
| **total** | **8.51** | **5.18** |

Three fixes account for it. The LSU now generates addresses and launches in
the same cycle -- enqueueing first put a one-cycle floor under 17% of loads.
The L1 answers in the cycle its array read completes rather than a cycle later;
a registered response there is a pipeline stage the hit path does not have, and
it lands on every load. And two bugs fell out of the first column. The LSU treated "there is a store ahead
of me" as a reason for a load to wait, without comparing addresses -- and when
a *store* had to wait behind an older store it `return`ed instead of
`continue`d, blocking every load behind it too. And what the LSU advertises as
ready has to be launch capacity, not queue space: advertising the queue lets
the scheduler select eight loads into a one-per-cycle port, which pins ROB
entries and moves the wait inside the load's own latency.

By Little's law the residual `select -> dreq` is the port: mean queue 2.68 at a
service rate of 0.771 gives 3.47 cycles, against 3.88 measured.

### Next, by measurement

1. **`IFetch` shadows the L1I** -- 28 reads in the whole run, so instruction
   supply is nearly free. This is the compensating error above, and unifying it
   with the casim-validated `modules/fetch.py` is what would make the aggregate
   agreement mean what it looks like it means.
2. **bp9/TAGE.** 41.2% of dispatched work thrown away against the golden's
   35.8%; bp8 runs 90.7% conditional accuracy.
3. **The last load cycle**: the MTL's registered response. The RTL bypasses it
   on a screen hit (`fetch_page_screen_resp_bypass`); only the request side of
   the screen is modelled.
4. **A DRAM model.** Invisible on this workload, decisive on any other.
4. **`IFetch` shadows the L1I** -- its own line buffer means the cache sees 28
   accesses at a 0% hit rate. Until it is the casim-validated
   `modules/fetch.py`, no frontend number here is trustworthy.
5. A memory system below L1 with DRAM timing. Barely visible on this workload
   (0.05% of loads), so it is last, not first.
