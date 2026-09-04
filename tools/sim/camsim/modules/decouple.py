"""Run the frontend with the backend removed, and record what to remove.

Two pieces that go together:

``BackChannel`` watches a *full* run and records everything the backend told
the frontend -- every redirect, whose instruction raised it, where it pointed,
and how long after that instruction issued it landed. Keyed on **position in the architectural stream** -- the count of instructions
retired before the one that raised it. Not cycles, which are completely
different once the backend does no work. And not uids either: the moment the
first redirect lands, a frontend with no backpressure has fetched a different
amount of speculative work, so uid allocation diverges and every later key
misses. The retired-instruction index is the one thing both runs agree on,
because it is exactly what does not depend on speculation.

``NullExu``/``NullLsu`` complete every instruction one cycle after it is
issued -- a pipeline stage, not a wormhole -- and hand it straight to
retirement. Nothing computes, nothing waits on memory, nothing is
dependence-blocked beyond that single cycle. What is left is the frontend's own
speed limit: fetch, translation, the L1I, decode, dispatch, and the cost of the
redirects it actually took.

**The control flow has to come from the recording.** A fake execution unit has
no branch outcome, so if it reports "next PC is whatever you predicted",
retirement never sees a mispredict, the predictor trains on its own output, and
the run wanders off the real path -- 433k instructions retired and no `ebreak`
in a 400k-cycle budget, on a program that retires 52.6k. So the recording
carries the architectural next-PC of every retired instruction, keyed by
position in the retired stream, and retirement uses it. Mispredicts are then
detected natively, the predictor trains on real outcomes, and the frontend
takes exactly the wrong paths it took before -- which is the whole point of the
exercise.

The number this produces is the same one ``casim --frontend-only`` produces and
means the same thing: not "how fast could the frontend be" but "how fast is it
when nothing downstream is in the way, still paying for every wrong path it
went down".
"""

import json

from ..module import Module, out, ASYNC, REG, LEVEL, PULSE
from .core import Done, MASK


class BackChannel(Module):
    """Record the backward channel of a full run, keyed by instruction.

    An observer: it drives nothing and adding it cannot change the run."""

    name = "backchannel"
    clock = reset_n = None
    subscribes = ["redirect", "issue.exu", "issue.lsu", "core.cands",
                  "rob.retired"]

    def __init__(self, path, rob, name=None):
        self.path = path
        self.rob = rob
        Module.__init__(self, name)

    def build(self, bus):
        self.S_REDIR = bus.signal("redirect")
        self.S_EXU = bus.signal("issue.exu")
        self.S_LSU = bus.signal("issue.lsu")
        self.S_CANDS = bus.signal("core.cands")
        self.S_RET = bus.signal("rob.retired")
        self.issued = {}          # uid -> cycle it was issued to a unit
        self.pc_of = {}
        self.arch_of = {}         # uid -> its index in the retired stream
        self.retire_cycle = {}
        self.events = []
        self.control = []         # architectural next-PC, in retirement order
        self.retired = 0
        self.csr_events = []      # (arch_i, satp, priv) when either changes
        self._last_csr = None

    def tick(self, bus):
        for pkt in (list(bus.get(self.S_EXU) or []) +
                    list(bus.get(self.S_LSU) or [])):
            self.issued.setdefault(pkt.ins.uid, bus.cycle)
            self.pc_of.setdefault(pkt.ins.uid, pkt.ins.pc)
        for ins in (bus.get(self.S_CANDS) or ()):
            self.pc_of.setdefault(ins.uid, ins.pc)
        for ins in (bus.get(self.S_RET) or ()):
            self.arch_of[ins.uid] = self.retired
            self.retire_cycle[ins.uid] = bus.cycle
            d = self.rob.state_at_retire.get(ins.uid)
            self.control.append(d if d is not None else None)
            now = (self.rob.satp, self.rob.priv)
            if now != self._last_csr:
                # Privileged state, pinned to the instruction that changed it.
                # Applying it as boot state instead would make the stub's own
                # code unreachable -- it runs before the page table exists.
                self.csr_events.append([self.retired, now[0], now[1]])
                self._last_csr = now
            self.retired += 1
        r = bus.get(self.S_REDIR)
        if r is not None:
            # Latency from the owner reaching a unit to the redirect landing.
            # That is the quantity a frontend with no backend cannot compute
            # for itself, so it is the one worth carrying across.
            src = self.issued.get(r.owner)
            ret = self.retire_cycle.get(r.owner)
            self.events.append({
                "arch_i": self.arch_of.get(r.owner),
                "owner": r.owner,
                "owner_pc": "%#x" % self.pc_of.get(r.owner, 0),
                "target": "%#x" % r.target,
                "kind": r.kind,
                "to_correct_path": bool(r.to_correct_path),
                "cycle": bus.cycle,
                # From the owner reaching a unit: the resolve latency, which is
                # the one quantity a frontend with no backend cannot compute.
                "resolve": (bus.cycle - src) if src is not None else 1,
                # From the owner retiring: what the replay keys off.
                "latency": (bus.cycle - ret) if ret is not None else 1,
            })

    def finish(self, bus):
        # The privileged state the stub left behind.  A decoupled run cannot
        # recreate it: with execution faked every register reads zero, so
        # `csrw mepc, t0` writes zero and the machine MRETs to address zero.
        with open(self.path, "w") as f:
            json.dump({"span": bus.cycle, "retired": self.retired,
                       "csr": self.csr_events,
                       "control": self.control, "events": self.events}, f)

    def report(self):
        kinds = {}
        for e in self.events:
            kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
        return {"path": self.path, "redirects": len(self.events),
                "kinds": kinds}


class RedirectReplay(Module):
    """Re-raise a recorded run's redirects, keyed by the instruction that
    raised them.

    Replaces the ROB as the source of ``dispatch.sched``: with no execution
    there is no branch outcome to compare against a prediction, so the
    recording is the only thing that knows the frontend was wrong."""

    name = "replay"
    publishes = [out("dispatch.sched", REG, PULSE, None)]
    subscribes = ["rob.retired"]

    def __init__(self, path, latency=None, name=None):
        with open(path) as f:
            rec = json.load(f)
        self.by_arch = {}
        for e in rec["events"]:
            if e.get("arch_i") is not None:
                self.by_arch.setdefault(e["arch_i"], []).append(e)
        self.dropped = sum(1 for e in rec["events"] if e.get("arch_i") is None)
        self.golden_span = rec.get("span")
        self.golden_retired = rec.get("retired")
        # None replays each redirect's own measured latency; an integer pins
        # every one of them, which is the single most useful knob here.
        self.latency = latency
        Module.__init__(self, name)

    def build(self, bus):
        self.S_SCHED = bus.signal("dispatch.sched")
        self.S_RET = bus.signal("rob.retired")
        self.arch = 0              # instructions retired so far
        self.pending = []          # (fire_cycle, owner_uid, event)
        self.fired = 0

    def tick(self, bus):
        from .dispatch import Sched
        if bus.resetting():
            del self.pending[:]
            self.arch = 0
            return
        # The owner's *uid in this run* is what fetch must flush against, and
        # it is only knowable here, at its retirement.
        for ins in (bus.get(self.S_RET) or ()):
            for e in self.by_arch.get(self.arch, ()):
                lat = self.latency if self.latency is not None else e["latency"]
                self.pending.append((bus.cycle + max(1, lat), ins.uid, e))
            self.arch += 1
        due = [(u, e) for c, u, e in self.pending if c <= bus.cycle]
        self.pending = [(c, u, e) for c, u, e in self.pending if c > bus.cycle]
        if due:
            win_u, win_e = min(due, key=lambda t: t[0])
            self.pending = [(c, u, e) for c, u, e in self.pending if u <= win_u]
            self.fired += 1
            bus.pub(self.S_SCHED, [Sched(1, win_u, int(win_e["target"], 16),
                                         win_e["kind"],
                                         win_e["to_correct_path"])])

    def report(self):
        return {"recorded": sum(len(v) for v in self.by_arch.values()),
                "unkeyed": self.dropped, "fired": self.fired,
                "still_pending": len(self.pending),
                "recorded_span": self.golden_span}


class NullExu(Module):
    """Complete everything one cycle after it is issued.  No arithmetic, no
    memory, no capacity limit -- the point is to not be in the way, while still
    being a pipeline stage rather than a wormhole.

    ``next_pc`` is left as whatever fetch predicted; retirement overrides it
    from the recorded control flow, which is the only place a real outcome
    exists in this configuration."""

    name = "exu"
    publishes = [
        out("exu.result", ASYNC, PULSE, None),
        out("exu.ready", ASYNC, LEVEL, 0),
        out("exu.busy", REG, LEVEL, 0),
    ]
    subscribes = ["issue.exu"]

    def __init__(self, width=64, latency=1, name=None):
        self.width = width
        self.latency = latency
        Module.__init__(self, name)

    def build(self, bus):
        self.S_IN = bus.signal("issue.exu")
        self.S_RES = bus.signal("exu.result")
        self.S_RDY = bus.signal("exu.ready")
        self.S_BUSY = bus.signal("exu.busy")
        self.busy = []
        self.completed = 0

    def _ripe(self, bus):
        return [p for c, p in self.busy if c <= bus.cycle]

    def settle(self, bus):
        if bus.resetting():
            bus.pub(self.S_RDY, 0)
            bus.pub(self.S_RES, None)
            return
        bus.pub(self.S_RDY, self.width)
        bus.pub(self.S_RES, [Done(p.ins.uid, 0, p.ins.pred_pc)
                             for p in self._ripe(bus)] or None)

    def tick(self, bus):
        if bus.resetting():
            del self.busy[:]
            bus.pub(self.S_BUSY, 0)
            return
        self.completed += len(self._ripe(bus))
        self.busy = [(c, p) for c, p in self.busy if c > bus.cycle]
        for p in (bus.get(self.S_IN) or ()):
            self.busy.append((bus.cycle + self.latency, p))
        bus.pub(self.S_BUSY, len(self.busy))

    def report(self):
        return {"completed": self.completed, "note": "null unit"}


class NullLsu(NullExu):
    """The same, for memory operations: no address, no translation, no cache."""

    name = "lsu"
    publishes = [
        out("lsu.result", ASYNC, PULSE, None),
        out("lsu.ready", ASYNC, LEVEL, 0),
        out("lsu.busy", REG, LEVEL, 0),
        out("mtl.dreq", ASYNC, PULSE, None),
    ]
    subscribes = ["issue.lsu"]

    def build(self, bus):
        self.S_IN = bus.signal("issue.lsu")
        self.S_RES = bus.signal("lsu.result")
        self.S_RDY = bus.signal("lsu.ready")
        self.S_BUSY = bus.signal("lsu.busy")
        self.S_REQ = bus.signal("mtl.dreq")
        self.busy = []
        self.completed = 0

    def settle(self, bus):
        NullExu.settle(self, bus)
        bus.pub(self.S_REQ, None)          # the D-side never speaks


class MagicLsu(Module):
    """Loads and stores that complete in one cycle, with the right data.

    Not a null unit: it translates properly and reads real memory, so branch
    outcomes, indirect targets and CSR values are all still correct and the
    machine computes its own control flow. What it removes is *time* -- no
    cache, no queue, no ordering stalls, no translation pipeline. casim calls
    this magic memory and uses it for the same purpose.

    That makes the experiment honest in a way the fake-execution version was
    not: nothing is replayed, so the frontend cannot be fed a path it would not
    have taken. Whatever it does here, it would do."""

    name = "lsu"
    publishes = [
        out("lsu.result", ASYNC, PULSE, None),
        out("lsu.ready", ASYNC, LEVEL, 0),
        out("mtl.dreq", ASYNC, PULSE, None),
        out("lsu.busy", REG, LEVEL, 0),
    ]
    subscribes = ["issue.lsu", "csr.satp", "csr.priv"]

    def __init__(self, mem, mtl, width=64, latency=1, name=None):
        self.mem = mem
        self.mtl = mtl
        self.width = width
        self.latency = latency
        Module.__init__(self, name)

    def build(self, bus):
        self.S_IN = bus.signal("issue.lsu")
        self.S_RES = bus.signal("lsu.result")
        self.S_RDY = bus.signal("lsu.ready")
        self.S_REQ = bus.signal("mtl.dreq")
        self.S_BUSY = bus.signal("lsu.busy")
        self.S_SATP = bus.signal("csr.satp")
        self.S_PRIV = bus.signal("csr.priv")
        self.busy = []
        self.loads = self.stores = self.faults = 0

    def _access(self, pkt, bus):
        from . import rv64 as R
        from .mtl import (ACCESS_READ, ACCESS_WRITE, FAULT_NONE, FAULT_ACCESS,
                          PRIV_M)
        ins = pkt.ins
        i = ins.instr
        nxt = (ins.pc + 4) & MASK
        off = R.imm_s(i) if ins.is_store else R.imm_i(i)
        addr = (pkt.a + off) & MASK
        size = (R.STORE_SIZE if ins.is_store else R.LOAD_SIZE)[R.funct3(i)]
        if addr % size:
            cause = (R.CAUSE_STORE_MISALIGNED if ins.is_store
                     else R.CAUSE_LOAD_MISALIGNED)
            return Done(ins.uid, None, nxt, cause, ins.pc, addr)
        satp = bus.get(self.S_SATP) or 0
        priv = bus.get(self.S_PRIV)
        priv = PRIV_M if priv is None else priv
        acc = ACCESS_WRITE if ins.is_store else ACCESS_READ
        paddr, fault, _ = self.mtl.translate(addr, acc, satp, priv)
        if fault:
            store = ins.is_store
            if fault == FAULT_ACCESS:
                cause = R.CAUSE_STORE_ACCESS if store else R.CAUSE_LOAD_ACCESS
            else:
                cause = (R.CAUSE_STORE_PAGE_FAULT if store
                         else R.CAUSE_LOAD_PAGE_FAULT)
            return Done(ins.uid, None, nxt, cause, ins.pc, addr)
        if ins.is_store:
            data = (pkt.b & ((1 << (size * 8)) - 1)).to_bytes(size, "little")
            # Still committed at retirement, as in the real unit: a store that
            # has not retired is speculative whatever the latency model says.
            return Done(ins.uid, None, nxt, 0, None, addr, (paddr, data))
        raw = self.mem.read(paddr, size)
        return Done(ins.uid, R.load_result(i, raw), nxt, 0, None, addr)

    def _ripe(self, bus):
        return [p for c, p in self.busy if c <= bus.cycle]

    def settle(self, bus):
        if bus.resetting():
            bus.pub(self.S_RDY, 0)
            bus.pub(self.S_RES, None)
            bus.pub(self.S_REQ, None)
            return
        bus.pub(self.S_RDY, self.width)
        bus.pub(self.S_REQ, None)          # the MTL pipeline is bypassed
        bus.pub(self.S_RES, [self._access(p, bus) for p in self._ripe(bus)]
                or None)

    def tick(self, bus):
        if bus.resetting():
            del self.busy[:]
            bus.pub(self.S_BUSY, 0)
            return
        for p in self._ripe(bus):
            d = self._access(p, bus)
            if d.fault:
                self.faults += 1
            elif p.ins.is_store:
                self.stores += 1
            else:
                self.loads += 1
        self.busy = [(c, p) for c, p in self.busy if c > bus.cycle]
        for p in (bus.get(self.S_IN) or ()):
            self.busy.append((bus.cycle + self.latency, p))
        bus.pub(self.S_BUSY, len(self.busy))

    def report(self):
        return {"loads": self.loads, "stores": self.stores,
                "faults": self.faults, "note": "magic memory, %d cycle"
                % self.latency}
