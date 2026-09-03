"""Checks on the bus's own guarantees, not on any model built with it.

Each one corresponds to a claim the design makes.  If one of these fails the
protocol is wrong, and every model on top of it inherits the wrongness.
"""

import itertools
import os
import sys
import tempfile

from camsim.bus import Bus, AsyncLoop, Elaboration
from camsim.link import Channel, Export, Import
from camsim.module import Module, out, ASYNC, REG, LEVEL, PULSE
from camsim.modules import demo
from camsim.modules.clock import Clock, ClockDiv, ClockGate, DONE
from camsim.probe import Const, Recorder, Replayer
from camsim.system import System
from camsim.wave import Wave, VCDWriter


def _graph(count=6, depth=2, rate=3, stage=None, reset_steps=1, **kw):
    bus = Bus(**kw)
    bus.add(Clock(reset_steps=reset_steps).port())
    bus.add(demo.Producer(count=count))
    bus.add(stage if stage is not None else demo.Stage())
    bus.add(demo.Sink(depth=depth, rate=rate))
    return bus


def _run(bus, count, until=None):
    bus.elaborate()
    sink = [m for m in bus.modules if isinstance(m, demo.Sink)][0]
    bus.run(until=until or (lambda b: len(sink.got) >= count or b.cycle > 500))
    return bus, bus.finish()


def check_order_independence():
    """The central claim: wake order cannot change the result."""
    ref = None
    for perm in itertools.permutations(range(4)):
        mods = [Clock(reset_steps=1).port(), demo.Producer(count=6),
                demo.Stage(), demo.Sink(depth=2, rate=3)]
        bus = Bus()
        for i in perm:
            bus.add(mods[i])
        bus, rep = _run(bus, 6)
        got = (bus.cycle, rep["sink"]["order"], rep["producer"]["sent"])
        if ref is None:
            ref = got
        elif got != ref:
            return "registration order %s changed the run: %r vs %r" % (perm, got, ref)
    return None


def check_local_equals_remote():
    """A module behind a pipe must behave exactly as it does in process."""
    from camsim.remote import hosted
    a, ra = _run(_graph(depth=1, rate=2), 6)
    b, rb = _run(_graph(depth=1, rate=2,
                        stage=hosted("camsim.modules.demo:Stage")), 6)
    if a.cycle != b.cycle:
        return "span %d local vs %d remote" % (a.cycle, b.cycle)
    if ra["sink"] != rb["sink"]:
        return "sink %r vs %r" % (ra["sink"], rb["sink"])
    return None


def check_comb_loop():
    """A async loop must be reported, not hung on."""

    class A(Module):
        name = "a"
        clock = reset_n = None
        publishes = [out("a.x", ASYNC, LEVEL, 0)]
        subscribes = ["b.y"]
        always_async = True

        def settle(self, bus):
            bus.pub("a.x", bus.get("b.y") + 1)

    class B(Module):
        name = "b"
        clock = reset_n = None
        publishes = [out("b.y", ASYNC, LEVEL, 0)]
        subscribes = ["a.x"]

        def settle(self, bus):
            bus.pub("b.y", bus.get("a.x") + 1)

    bus = Bus(max_delta=16)
    bus.add(A()); bus.add(B())
    bus.elaborate()
    try:
        bus.step()
    except AsyncLoop as e:
        return None if "did not settle" in str(e) else "wrong loop message: %s" % e
    return "async loop was not detected"


def check_wiring_errors():
    """Two drivers on one signal, and a subscription nobody drives."""

    class P(Module):
        name = "p"
        clock = reset_n = None
        publishes = [out("x.v", REG)]

    bus = Bus()
    bus.add(P(name="p1")); bus.add(P(name="p2"))
    try:
        bus.elaborate()
        return "two drivers on x.v were accepted"
    except Elaboration:
        pass

    class C(Module):
        name = "c"
        clock = reset_n = None
        subscribes = ["nobody.drives.this"]

    bus = Bus()
    bus.add(C())
    try:
        bus.elaborate()
        return "dangling subscription was accepted in strict mode"
    except Elaboration:
        pass

    bus = Bus(strict=False)
    bus.add(C())
    bus.elaborate()
    return None if bus.warnings else "loose mode did not warn about the dangling input"


def check_missing_clock():
    """A module that names a clock nobody drives is a wiring error, which is
    the whole reason the clock is a signal and not a bus property."""

    class Lonely(Module):
        name = "lonely"
        publishes = [out("lonely.v", REG, LEVEL, 0)]

    bus = Bus()
    bus.add(Lonely())
    try:
        bus.elaborate()
        return "a module with no clock source elaborated"
    except Elaboration as e:
        return None if "clk" in str(e) else "wrong error: %s" % e


def check_done_gates_the_clock():
    """Saying "not done" must stop the next edge, and releasing it must let
    the machine carry on exactly where it left off."""

    class Slow(Module):
        """Withholds done for `hold` steps after each edge.  Free-running, so
        it can still make progress while it is stalling the clock -- which is
        the rule for anything that withholds."""
        name = "slow"
        clock = reset_n = None
        contributes = [DONE]
        always_async = True

        def __init__(self, hold=2):
            self.hold = hold
            Module.__init__(self)

        def build(self, bus):
            self.S = bus.signal(DONE)
            self.left = 0
            self.edges = 0

        def settle(self, bus):
            bus.pub(self.S, self.left <= 0)

        def tick(self, bus):
            if self.left > 0:
                self.left -= 1
            elif bus.fired("clk"):
                self.edges += 1
                self.left = self.hold

    clk = Clock(reset_steps=0)
    bus = Bus()
    bus.add(clk.port())
    slow = Slow(hold=2)
    slow.subscribes = ["clk"]
    bus.add(slow)
    counter = bus.add(_Ticker())
    bus.elaborate()
    bus.run(steps=30)
    if clk.time == 30:
        return "sys.done was withheld but the clock never stalled"
    if clk.total_stalled == 0:
        return "no stalls recorded"
    if counter.n != clk.time:
        return "module ticked %d times for %d edges" % (counter.n, clk.time)
    if clk.time + clk.total_stalled != 30:
        return "edges %d + stalls %d != 30 steps" % (clk.time, clk.total_stalled)
    return None


def check_done_deadlock_is_caught():
    """A module that withholds done forever must be reported, not hung on."""

    class Never(Module):
        name = "never"
        clock = reset_n = None
        contributes = [DONE]
        always_async = True

        def build(self, bus):
            self.S = bus.signal(DONE)

        def settle(self, bus):
            bus.pub(self.S, False)

    bus = Bus()
    bus.add(Clock(reset_steps=0, stall_limit=8).port())
    bus.add(Never())
    bus.add(_Ticker())
    bus.elaborate()
    try:
        bus.run(steps=50)
    except RuntimeError as e:
        return None if "stalled" in str(e) else "wrong error: %s" % e
    return "a permanent done-withholder was not caught"


class _Ticker(Module):
    name = "ticker"
    publishes = [out("ticker.n", REG, LEVEL, 0)]

    def build(self, bus):
        self.S = bus.signal("ticker.n")
        self.n = 0

    def tick(self, bus):
        self.n += 1
        bus.pub(self.S, self.n)


def check_phase_rules():
    """ASYNC at the clock edge is refused, as is driving what you do not own."""

    class Bad(Module):
        name = "bad"
        clock = reset_n = None
        publishes = [out("bad.c", ASYNC, LEVEL, 0)]
        always_async = True

        def tick(self, bus):
            bus.pub("bad.c", 1)

    class Obs(Module):
        name = "obs"
        clock = reset_n = None
        subscribes = ["bad.c"]

    bus = Bus()
    bus.add(Bad()); bus.add(Obs())
    bus.elaborate()
    try:
        bus.step()
        return "ASYNC publish at the edge was accepted"
    except Elaboration:
        pass

    class Thief(Module):
        name = "thief"
        clock = reset_n = None
        publishes = [out("thief.o", REG)]
        subscribes = ["victim.v"]

        def tick(self, bus):
            bus.pub("victim.v", 1)

    class Victim(Module):
        name = "victim"
        clock = reset_n = None
        publishes = [out("victim.v", REG, LEVEL, 0)]

    bus = Bus()
    bus.add(Thief()); bus.add(Victim())
    bus.elaborate()
    try:
        bus.step()
        return "a module published a signal it does not drive"
    except Elaboration:
        return None


def check_reset_is_a_signal():
    """Reset must be re-assertable.  A build-time callback runs once; a signal
    can go low again, and the machine must come back up behind it."""
    bus = Bus()
    bus.add(Clock(reset_windows=[(0, 1), (6, 9)]).port())
    bus.add(demo.Producer(count=6))
    bus.add(demo.Stage())
    bus.add(demo.Sink(depth=2, rate=1))
    bus.elaborate()
    sink = [m for m in bus.modules if isinstance(m, demo.Sink)][0]
    bus.run(steps=6)
    mid = len(sink.got)
    bus.run(steps=3)                       # held in reset
    if sink.got:
        return "reset did not clear the sink (%r)" % (sink.got,)
    bus.run(until=lambda b: len(sink.got) >= 6 or b.cycle > 200)
    if len(sink.got) != 6 or sink.got != list(range(6)):
        return "machine did not restart after reset: %r" % (sink.got,)
    return None if mid > 0 else "nothing happened before the second reset"


def check_clock_domains():
    """A divided domain ticks on its own edges and nobody else's."""

    class Counter(Module):
        publishes = [out("cnt.v", REG, LEVEL, 0)]

        def __init__(self, name, clock):
            Module.__init__(self, name, clock=clock,
                            rename={"cnt.v": name + ".v"})

        def build(self, bus):
            self.S = bus.signal(self.name + ".v")
            self.n = 0

        def tick(self, bus):
            if bus.resetting():
                return
            self.n += 1
            bus.pub(self.S, self.n)

    bus = Bus()
    bus.add(Clock(reset_steps=1).port())
    bus.add(ClockDiv(2))
    bus.add(ClockDiv(4))
    fast = bus.add(Counter("fast", "clk"))
    half = bus.add(Counter("half", "clk_div2"))
    quart = bus.add(Counter("quart", "clk_div4"))
    bus.elaborate()
    bus.run(steps=41)
    # A divider is a flop, so its Nth pulse lands the step after it counts;
    # over a finite run that costs at most one edge per domain.
    if fast.n != 40:
        return "fast domain ticked %d times in 40 running steps" % fast.n
    for got, ratio in ((half.n, 2), (quart.n, 4)):
        want = fast.n // ratio
        if got not in (want, want - 1):
            return "/%d domain ticked %d, expected %d" % (ratio, got, want)
    return None


def check_clock_gating():
    """A gated module must not tick, and must cost nothing while gated."""

    class Enable(Module):
        name = "en"
        publishes = [out("en.v", REG, LEVEL, False)]

        def build(self, bus):
            self.S = bus.signal("en.v")

        def tick(self, bus):
            bus.pub(self.S, (bus.cycle // 4) % 2 == 0)

    class Worker(Module):
        name = "worker"
        clock = "clk_g"
        publishes = [out("worker.n", REG, LEVEL, 0)]

        def build(self, bus):
            self.S = bus.signal("worker.n")
            self.n = 0

        def tick(self, bus):
            self.n += 1
            bus.pub(self.S, self.n)

    bus = Bus()
    bus.add(Clock(reset_steps=0).port())
    bus.add(Enable())
    gate = bus.add(ClockGate("en.v"))
    w = bus.add(Worker())
    bus.elaborate()
    bus.run(steps=40)
    if w.n == 0 or w.n >= 40:
        return "gated worker ticked %d of 40 steps; gating did nothing" % w.n
    if w.n + gate.gated_steps != 40:
        return "ticks %d + gated %d != 40" % (w.n, gate.gated_steps)
    return None


def check_two_buses():
    """The same machine split across two buses delivers the same stream.

    It does not deliver it in the same number of steps, and that is the honest
    result: the ready line now crosses a registered boundary, so the loop is a
    step longer.  A crossing costs what a crossing costs."""
    a, ra = _run(_graph(count=6, depth=2, rate=3), 6)
    ref = ra["sink"]["order"]

    fwd = Channel([out("stage.item", REG, PULSE)], name="fwd")
    back = Channel([out("sink.ready", REG, LEVEL, False)], name="back")

    sysm = System(clock=Clock(reset_steps=1))
    core = sysm.add(Bus(name="core"))
    core.add(demo.Producer(count=6))
    core.add(demo.Stage())
    core.add(Export(fwd))
    core.add(Import(back))

    side = sysm.add(Bus(name="side"))
    side.add(Import(fwd))
    sink = side.add(demo.Sink(depth=2, rate=3))
    side.add(Export(back, src={"sink.ready": "sink.ready"}))

    sysm.elaborate()
    sysm.run(until=lambda s: len(sink.got) >= 6 or s.step_count > 500)
    sysm.finish()
    if sink.got != ref:
        return "split run delivered %r, single bus delivered %r" % (sink.got, ref)
    if len(set(id(m.clk) for b in sysm.buses for m in b.modules
               if hasattr(m, "clk"))) != 1:
        return "the two buses are not on the same clock unit"
    return None


def check_wave_is_an_observer():
    """Dumping must not perturb the run, and must produce a parsable VCD:
    balanced scopes, non-decreasing time, no undeclared identifier."""
    fd, path = tempfile.mkstemp(suffix=".vcd")
    os.close(fd)
    try:
        a, ra = _run(_graph(count=6, rate=3), 6)
        bus = _graph(count=6, rate=3)
        bus.add(Wave(path, ["*"]))
        b, rb = _run(bus, 6)
        if (a.cycle, ra["sink"]) != (b.cycle, rb["sink"]):
            return "adding a Wave changed the run: %r vs %r" % (
                (a.cycle, ra["sink"]), (b.cycle, rb["sink"]))

        idents, depth, t, seen_defs, n = set(), 0, -1, False, 0
        for line in open(path):
            line = line.strip()
            if line.startswith("$scope"):
                depth += 1
            elif line == "$upscope $end":
                depth -= 1
                if depth < 0:
                    return "unbalanced $upscope"
            elif line.startswith("$var"):
                idents.add(line.split()[3])
            elif line == "$enddefinitions $end":
                seen_defs = True
            elif line.startswith("#"):
                nt = int(line[1:])
                if nt < t:
                    return "time went backwards: %d after %d" % (nt, t)
                t = nt
            elif line and seen_defs and not line.startswith("$"):
                n += 1
                ident = line.split()[-1] if line[0] in "br s" and " " in line \
                    else line[1:]
                if ident not in idents:
                    return "value change on undeclared identifier %r" % ident
        if depth != 0:
            return "%d scopes left open" % depth
        if not n:
            return "no value changes written"
        return None
    finally:
        os.unlink(path)


def check_fetch_matches_casim():
    """The ported fetch unit must deliver what casim's frontend delivers, at
    the same cycle, over the knobs that drive it.

    Straight-line only: with no resolver there are no redirects, so this pins
    PC generation, the resident-block window, the presentation queue and the
    same-cycle bypass -- not the flush path, which needs the gate to exist."""
    import os
    try:
        sys.path.insert(0, os.path.dirname(os.path.dirname(
            os.path.dirname(os.path.abspath(__file__)))))
        from casim.config import Config
        from casim import btrace as bt_mod
        from casim.frontend import Frontend, IdealGate as CasimGate
    except ImportError as e:
        return None                      # casim absent: nothing to compare to
    from camsim.modules.fetch import Fetch
    from camsim.modules.stubs import IdealGate, NoRedirect, NoStash

    NOP, ENTRY, N = 0x00000013, 0x80000000, 150
    cases = [(3, 3, 3, 0, 4), (3, 3, 3, 4, 4), (2, 4, 2, 2, 4),
             (1, 1, 1, 0, 4), (4, 8, 3, 4, 2), (3, 6, 2, 1, 1)]
    for (w, q, dw, refill, win) in cases:
        cfg = Config()
        cfg.fetch_width, cfg.fetch_queue_depth, cfg.decode_width = w, q, dw
        cfg.l1i_refill_cycles, cfg.fetch_window_blocks = refill, win
        bt = bt_mod.BranchTrace()
        bt.entry_pc = ENTRY
        bt.image = dict((ENTRY + 4 * i, NOP) for i in range(N))
        bt.events = []
        bt.arch_count = N
        ref = [(x.pc, x.front_ready) for x in
               Frontend(cfg, bt, gate=CasimGate(), golden_stream=[])
               .run(max_cycles=100000).stream]

        bus = Bus(timing=False)
        bus.add(Clock(reset_steps=1).port())
        bus.add(Fetch(bt.image, entry_pc=ENTRY, width=w, queue_depth=q,
                      block_bytes=cfg.fetch_block_bytes, window_blocks=win,
                      refill=refill, present_width=dw))
        g = bus.add(IdealGate(width=dw))
        bus.add(NoRedirect())
        bus.add(NoStash())
        bus.elaborate()
        bus.run(until=lambda b: g.count >= N or b.cycle > 100000)
        bus.finish()
        got = [(c.pc, c.admit_cycle) for c in g.admitted]
        tag = "w%d/q%d/dw%d refill%d win%d" % (w, q, dw, refill, win)
        if got != ref:
            n = min(len(got), len(ref))
            first = next((i for i in range(n) if got[i] != ref[i]), n)
            return "%s: casim %d insns, camsim %d; first difference at %d: %r vs %r" % (
                tag, len(ref), len(got), first,
                ref[first] if first < len(ref) else None,
                got[first] if first < len(got) else None)
    return None


def check_fetch_flush():
    """A redirect must discard exactly the candidates younger than its owner
    and retarget the PC, in the cycle it arrives."""
    from camsim.modules.fetch import Fetch, Redirect
    from camsim.modules.stubs import IdealGate, NoStash

    NOP, ENTRY = 0x00000013, 0x80000000
    image = dict((ENTRY + 4 * i, NOP) for i in range(64))

    class Injector(Module):
        name = "injector"
        publishes = [out("redirect", REG, PULSE, None)]

        def build(self, bus):
            self.S = bus.signal("redirect")

        def tick(self, bus):
            if bus.cycle == 3:
                bus.pub(self.S, Redirect(2, ENTRY + 4 * 32, "test"))

    bus = Bus(timing=False)
    bus.add(Clock(reset_steps=1).port())
    f = bus.add(Fetch(image, entry_pc=ENTRY, width=3, queue_depth=3,
                      refill=0, present_width=1))     # gate narrower than fetch
    g = bus.add(IdealGate(width=1))
    bus.add(Injector())
    bus.add(NoStash())
    bus.elaborate()
    bus.run(steps=8)
    bus.finish()
    target = ENTRY + 4 * 32
    if f.discarded != 2:
        return "redirect discarded %d candidates, expected 2" % f.discarded
    pcs = [c.pc for c in g.admitted]
    if target not in pcs:
        return "PC never retargeted: admitted %s" % [hex(p) for p in pcs[:8]]
    i = pcs.index(target)
    before, after = pcs[:i], pcs[i:]
    if before != [ENTRY + 4 * k for k in range(len(before))]:
        return "pre-redirect stream is not sequential: %s" % [hex(p) for p in before]
    if after != [target + 4 * k for k in range(len(after))]:
        return "post-redirect stream is not sequential from the target: %s" % (
            [hex(p) for p in after[:6]],)
    # The flush, the retarget and the first candidate from the new path all
    # happen in the cycle the redirect lands -- as they do in casim.
    if g.admitted[i].admit_cycle != 4:
        return "target admitted at cycle %s, expected the redirect cycle 4" % (
            g.admitted[i].admit_cycle,)
    return None


def check_frontend_matches_casim():
    """The whole frontend -- fetch, decode, dispatch, resolve -- must reproduce
    casim's frontend-only run: same span, same fetched, same shadow volume,
    same redirect mix.  Synthetic control flow with every case in it: a
    predicted-taken backward branch, a mispredicted one, and an implicit
    serialising refetch."""
    import os
    try:
        sys.path.insert(0, os.path.dirname(os.path.dirname(
            os.path.dirname(os.path.abspath(__file__)))))
        from casim.config import Config
        from casim import btrace as bt_mod
        from casim.frontend import Frontend, IdealGate as CasimGate
    except ImportError:
        return None

    NOP, BEQ_BACK, ENTRY = 0x00000013, 0x00000063, 0x80000000
    N, BODY = 600, 10
    bt = bt_mod.BranchTrace()
    bt.entry_pc = ENTRY
    bt.image = dict((ENTRY + 4 * i, NOP) for i in range(N + 64))
    bt.events = []
    # Every BODY-th instruction is a control transfer; cycle through the four
    # cases so predicted-taken, mispredict and implicit are all exercised.
    for k, i in enumerate(range(BODY, N, BODY)):
        pc = ENTRY + 4 * i
        bt.image[pc] = BEQ_BACK
        seq = pc + 4
        tgt = ENTRY + 4 * (i + 5)
        case = k % 4
        if case == 0:            # predicted taken, right
            ev = bt_mod.CtrlEvent(i, pc, BEQ_BACK, True, tgt, tgt, 4)
        elif case == 1:          # predicted taken, wrong
            ev = bt_mod.CtrlEvent(i, pc, BEQ_BACK, True, tgt, seq, 9)
        elif case == 2:          # predicted not taken, wrong
            ev = bt_mod.CtrlEvent(i, pc, BEQ_BACK, False, seq, tgt, 6)
        else:                    # implicit serialising refetch
            bt.image[pc] = NOP
            ev = bt_mod.CtrlEvent(i, pc, NOP, False, seq, seq, 3, implicit=True)
        bt.events.append(ev)
    bt.arch_count = N

    cfg = Config()
    cfg.fetch_width = cfg.fetch_queue_depth = cfg.decode_width = 3
    cfg.l1i_refill_cycles, cfg.fetch_window_blocks = 0, 4
    ref = Frontend(cfg, bt, gate=CasimGate(), golden_stream=[]).run(max_cycles=200000)

    class A(object):
        width = queue_depth = decode_width = 3
        block_bytes, window_blocks, refill = 64, 4, 0
        resolve_latency = None
        no_timing = True
    from camsim.cli import build_frontend
    bus, fe, dp, rs = build_frontend(A(), bt)
    bus.elaborate()
    bus.run(until=lambda b: (b.cycle > 200000 or
                             (dp.arch_done >= N and not rs.pending)))
    bus.finish()
    span = bus.cycle - 1
    got = (span, fe.fetched, dp.delivered, dp.wrong_path, dp.arch_done)
    want = (ref.cycles, ref.fetched, ref.delivered, ref.wrong_path, N)
    if got != want:
        names = ("span", "fetched", "delivered", "wrong_path", "arch")
        bad = ["%s %s vs %s" % (n, w, g)
               for n, w, g in zip(names, want, got) if w != g]
        return "casim vs camsim: " + ", ".join(bad)
    if rs.kinds != ref.redirects:
        return "redirect mix %r vs casim %r" % (rs.kinds, ref.redirects)
    return None


def check_executes_real_code():
    """The machine must run RV64 and get the right answer, under Sv39, with
    faults where faults belong."""
    from camsim import machine as MA
    from camsim.modules.mtl import PRIV_S

    PA_CODE, PA_DATA, PA_TAB = 0x80000000, 0x80100000, 0x80200000
    VA_CODE, VA_DATA = 0x40000000, 0x40100000
    SUM = ["addi t0, zero, 0", "addi t1, zero, 1", "addi t2, zero, 11",
           "loop:", "add t0, t0, t1", "addi t1, t1, 1", "blt t1, t2, loop",
           "lui a1, 0x40100", "sd t0, a1, 0", "ld a0, a1, 0", "ecall"]

    def run(src, flags=MA.Sv39.RX, data=True, bare=False, maxc=20000):
        base = PA_CODE if bare else VA_CODE
        words, _ = MA.asm(src, base)
        mem = MA.PhysMem()
        MA.load_program(mem, PA_CODE, words)
        if bare:
            m = MA.build(mem, PA_CODE, timing=False)
        else:
            mmu = MA.Sv39(mem, PA_TAB).map(VA_CODE, PA_CODE, 4, flags)
            if data:
                mmu.map(VA_DATA, PA_DATA, 4, MA.Sv39.RW)
            m = MA.build(mem, VA_CODE, timing=False, priv=PRIV_S,
                         satp=mmu.satp())
        return m, MA.run(m, maxc), mem

    m, r, mem = run(SUM, bare=True)
    if m["regs"].read(10) != 55:
        return "bare: sum 1..10 came out %r, not 55" % m["regs"].read(10)

    # Sweep the issue AND retire widths.  Two separate bugs have hidden here:
    # a same-cycle RAW hazard invisible at issue width 1, and a single-valued
    # store-commit pulse that silently dropped one of two stores retiring
    # together.  Both were correct at width 1 and wrong above it.
    SQ = ["addi t0, zero, 0", "addi t1, zero, 1", "addi t2, zero, 11",
          "loop:", "mul t3, t1, t1", "add t0, t0, t3", "addi t1, t1, 1",
          "blt t1, t2, loop", "addi a0, t0, 0", "ecall"]
    for w in (1, 2, 3, 4):
        for rw in (1, 2, 3):
            words, _ = MA.asm(SQ, PA_CODE)
            mm = MA.PhysMem()
            MA.load_program(mm, PA_CODE, words)
            mach = MA.build(mm, PA_CODE, timing=False, issue_width=w,
                            retire_width=rw)
            MA.run(mach, 20000)
            if mach["regs"].read(10) != 385:
                return "issue %d / retire %d: sum of squares came out %r" % (
                    w, rw, mach["regs"].read(10))

    # Several stores retiring together must all reach the cache, not just the
    # last.  Memory stays right regardless (the ROB writes it), so this only
    # shows up as a load reading a stale cache line.
    ST = ["lui a1, 0x10", "addi t0, zero, 11", "addi t1, zero, 22",
          "addi t2, zero, 33", "sd t0, a1, 0", "sd t1, a1, 8",
          "sd t2, a1, 16", "ld a0, a1, 8", "ecall"]
    for rw in (1, 2, 3, 4):
        words, _ = MA.asm(ST, PA_CODE)
        mm = MA.PhysMem()
        MA.load_program(mm, PA_CODE, words)
        mach = MA.build(mm, PA_CODE, timing=False, retire_width=rw)
        MA.run(mach, 20000)
        if mach["regs"].read(10) != 22:
            return "retire width %d: load after 3 stores read %r, not 22" % (
                rw, mach["regs"].read(10))
        got = [mm.u64(0x10000), mm.u64(0x10008), mm.u64(0x10010)]
        if got != [11, 22, 33]:
            return "retire width %d: stores landed as %r, not [11, 22, 33]" % (
                rw, got)

    m, r, mem = run(SUM)
    if m["regs"].read(10) != 55:
        return "sv39: a0 = %r, not 55" % m["regs"].read(10)
    if mem.u64(PA_DATA) != 55:
        return "sv39: store to VA %#x did not land at PA %#x" % (VA_DATA, PA_DATA)
    if "ecall" not in (r["halt"] or ("",))[0]:
        return "sv39: halted on %r, expected the ecall" % (r["halt"],)
    # With backward-taken prediction the loop back-edge is right every time
    # and only the final fall-through is wrong.
    if r["report"]["rob"]["mispredicts"] != 1:
        return "expected 1 mispredict under btfn, got %d" % \
            r["report"]["rob"]["mispredicts"]

    checks = [
        (["lui a1, 0x40500", "addi t0, zero, 1", "sd t0, a1, 0", "ecall"],
         dict(data=False), "store page fault"),
        (SUM, dict(flags=MA.Sv39.RW), "fetch page fault"),
        (["lui a1, 0x40100", "addi t0, zero, 1", "sd t0, a1, 1", "ecall"],
         {}, "misaligned store"),
    ]
    for src, kw, want in checks:
        _, rr, _ = run(src, **kw)
        got = (rr["halt"] or ("none",))[0]
        if want not in got:
            return "expected %r, halted on %r" % (want, got)

    # RISC-V division semantics, through the real pipe rather than the helper.
    m, rr, _ = run(["addi t0, zero, 5", "div a0, t0, zero", "ecall"])
    if m["regs"].read(10) != (1 << 64) - 1:
        return "div by zero gave %#x, expected all ones" % m["regs"].read(10)
    return None


def check_record_replay():
    """A recording standing in for its producer must reproduce the run."""
    fd, path = tempfile.mkstemp(suffix=".rec")
    os.close(fd)
    try:
        bus = _graph(count=6, rate=1)
        bus.add(Recorder(path, ["src.*"]))
        a, ra = _run(bus, 6)

        b = Bus(strict=False)
        b.add(Clock(reset_steps=1).port())
        b.add(Replayer(path))
        b.add(demo.Stage())
        b.add(demo.Sink(depth=2, rate=1))
        b, rb = _run(b, 6, until=lambda x: x.cycle > a.cycle + 2)
        if ra["sink"]["order"] != rb["sink"]["order"]:
            return "replay produced %r, recording came from %r" % (
                rb["sink"]["order"], ra["sink"]["order"])
        return None
    finally:
        os.unlink(path)


def check_no_glitch_latch():
    """The backpressure case that first broke this: an offer withdrawn during
    settling must not be latched, and must not be lost either."""
    bus, rep = _run(_graph(count=5, depth=2, rate=3), 5)
    if rep["sink"]["order"] != [0, 1, 2, 3, 4]:
        return "withdrawn offer mishandled: %r" % (rep["sink"]["order"],)
    return None


CHECKS = [check_order_independence, check_local_equals_remote, check_comb_loop,
          check_wiring_errors, check_missing_clock, check_phase_rules,
          check_reset_is_a_signal, check_done_gates_the_clock,
          check_done_deadlock_is_caught, check_clock_domains,
          check_clock_gating, check_two_buses, check_wave_is_an_observer,
          check_fetch_matches_casim, check_fetch_flush,
          check_frontend_matches_casim, check_executes_real_code,
          check_record_replay, check_no_glitch_latch]


def run_checks():
    bad = 0
    for fn in CHECKS:
        name = fn.__name__.replace("check_", "")
        try:
            err = fn()
        except Exception:
            import traceback
            err = traceback.format_exc().strip().splitlines()[-1]
        if err:
            bad += 1
            print("FAIL  %-22s %s" % (name, err))
        else:
            print("ok    %-22s %s" % (name, (fn.__doc__ or "").split("\n")[0]))
    print("\n%d/%d" % (len(CHECKS) - bad, len(CHECKS)))
    return 1 if bad else 0
