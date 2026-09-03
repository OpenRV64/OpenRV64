"""The execute pipeline: fetch, issue, execute, retire.

This is not a port.  casim replays a golden, so it never needed to know what
an instruction computes; running real code does, and these units are new.  The
shape is in-order issue with a scoreboard, out-of-order completion, in-order
retirement -- a real machine, and the skeleton the Tomasulo scheduler drops
into later without the units around it changing.

Everything above the MTL speaks *virtual* addresses.  ``IFetch`` asks for an
instruction at a virtual PC and ``Lsu`` asks for a virtual data address; the
MTL translates, checks, and comes back.  Neither unit contains a page walk,
which is the point of having an MTL at all.

Faults halt the machine with a cause and a PC rather than being delivered to a
handler.  Trap delivery is real work (mepc/mcause/mtvec, the privilege
transition, the return path) and inventing half of it would make a page fault
look like a hang; stopping with "store page fault at 0x...", which is what
happens now, is the honest intermediate.
"""

from ..module import Module, out, ASYNC, REG, LEVEL, PULSE
from . import rv64 as R
from .mtl import (Xlate, ACCESS_READ, ACCESS_WRITE, ACCESS_EXEC,
                  FAULT_NONE, FAULT_PAGE, FAULT_ACCESS, PRIV_U, PRIV_S,
                  PRIV_M)

MASK = R.MASK


class RegFile(object):
    """Architectural registers.  A plain object, not a module: with no rename
    there is exactly one writer (retirement) and reads are same-cycle, so a
    signal between issue and the file would be a same-cycle region with no
    question attached."""

    def __init__(self):
        self.x = [0] * 32
        self.writes = 0

    def read(self, i):
        return 0 if i == 0 else self.x[i]

    def write(self, i, v):
        if i:
            self.x[i] = v & MASK
            self.writes += 1


class Insn(object):
    """One in-flight instruction: everything the pipeline needs about it."""

    __slots__ = ("uid", "pc", "instr", "klass", "rd", "rs1", "rs2",
                 "writes_rd", "uses_rs1", "uses_rs2", "a", "b",
                 "result", "next_pc", "pred_pc", "done", "fault", "fault_pc",
                 "is_store", "addr", "store_data", "csr_done", "bp_rec")

    def __init__(self, uid, pc, instr):
        self.uid = uid
        self.pc = pc
        self.instr = instr
        self.klass = R.classify(instr)
        (self.rd, self.rs1, self.rs2, self.writes_rd,
         self.uses_rs1, self.uses_rs2) = R.regs_used(instr)
        self.a = self.b = 0
        self.result = None
        self.next_pc = None
        self.pred_pc = None
        self.done = False
        self.fault = FAULT_NONE
        self.fault_pc = None
        self.is_store = (self.klass == R.STORE)
        self.addr = None
        self.store_data = None
        self.csr_done = False
        self.bp_rec = None

    def __eq__(self, o):
        return isinstance(o, Insn) and o.uid == self.uid

    def __ne__(self, o):
        return not self.__eq__(o)

    def __hash__(self):
        return self.uid

    def __repr__(self):
        return "i%d@%x" % (self.uid, self.pc)


class Ready(object):
    """An instruction issued with its operand values.

    Issue does not write them into the instruction: ``settle`` is re-run
    whenever an input moves, so anything it wrote would be written several
    times per cycle and read by whoever looked first.  The values travel in the
    packet instead."""

    __slots__ = ("ins", "a", "b")

    def __init__(self, ins, a, b):
        self.ins = ins
        self.a = a
        self.b = b

    def __eq__(self, o):
        return isinstance(o, Ready) and o.ins.uid == self.ins.uid

    def __ne__(self, o):
        return not self.__eq__(o)

    def __hash__(self):
        return self.ins.uid

    def __repr__(self):
        return "rdy%d" % self.ins.uid


class Done(object):
    """A completion, as it crosses the bus.

    The unit that computed the result does not reach into the ROB entry to
    store it -- if it did, whether the ROB saw the result this cycle or next
    would depend on which module happened to be registered first, and the
    bus's one guarantee would be gone."""

    __slots__ = ("uid", "result", "next_pc", "fault", "fault_pc", "addr",
                 "store")

    def __init__(self, uid, result=None, next_pc=None, fault=0, fault_pc=None,
                 addr=None, store=None):
        self.uid = uid
        self.result = result
        self.next_pc = next_pc
        self.fault = fault
        self.fault_pc = fault_pc
        self.addr = addr
        self.store = store        # (paddr, bytes) held until retirement

    def __eq__(self, o):
        return isinstance(o, Done) and o.uid == self.uid

    def __ne__(self, o):
        return not self.__eq__(o)

    def __hash__(self):
        return self.uid

    def __repr__(self):
        return "done%d" % self.uid


class IFetch(Module):
    """Fetch through the MTL, one line at a time.

    Simpler than ``modules/fetch.py`` on purpose: that unit is the
    cycle-accurate port validated against casim and it takes its encodings from
    a recorded image, while this one has to go and get them.  Unifying the two
    -- giving the ported fetch a memory-backed line provider -- is the obvious
    follow-up and is not done here."""

    name = "ifetch"
    publishes = [
        out("core.cands", ASYNC, PULSE, doc="instructions offered this cycle"),
        out("mtl.ireq", ASYNC, PULSE, None, doc="line request, virtual"),
        out("core.pc", REG, LEVEL, 0),
        out("core.ifault", REG, PULSE, None, doc="fetch fault, halts the machine"),
    ]
    subscribes = ["mtl.iresp", "mtl.iready", "mtl.iack", "redirect",
                  "core.taken"]

    LINE = 64

    def __init__(self, entry_pc=0, width=3, name=None, predict="bp8",
                 predictor=None):
        self.entry_pc = entry_pc
        self.width = width
        # "seq" is the degenerate rule (always pc+4); anything else names a
        # predictor from `modules/bp.py`, which follows the RTL's numbering.
        self.predict = predict
        self.bp = predictor
        Module.__init__(self, name)

    def _predict(self, pc, w):
        """Predict, and hand the record back so retirement can train against
        the state that made this prediction rather than a later lookup."""
        if self.bp is None:
            return (pc + 4) & MASK, None
        return self.bp.predict(pc, w)

    def build(self, bus):
        if self.bp is None and self.predict != "seq":
            from .bp import make
            self.bp = make(self.predict)
        for a, n in (("S_CANDS", "core.cands"), ("S_IREQ", "mtl.ireq"),
                     ("S_PC", "core.pc"), ("S_IFAULT", "core.ifault"),
                     ("S_IRESP", "mtl.iresp"), ("S_IRDY", "mtl.iready"),
                     ("S_IACK", "mtl.iack"), ("S_REDIR", "redirect"),
                     ("S_TAKEN", "core.taken")):
            setattr(self, a, bus.signal(n))
        self._reset_state()

    def _reset_state(self):
        self.pc = self.entry_pc
        self.uid = 0
        self.lines = {}          # line base -> bytes
        self.pending_line = None
        self.queue = []
        self.fetched = 0
        self.misses = 0
        self.stall_mem = 0

    def _word(self, pc):
        base = pc & ~(self.LINE - 1)
        line = self.lines.get(base)
        if line is None:
            return None
        off = pc - base
        return int.from_bytes(line[off:off + 4], "little")

    def _eval(self, bus):
        pc = self.pc
        queue = list(self.queue)
        uid = self.uid
        redir = bus.get(self.S_REDIR)
        if redir is not None:
            queue = [c for c in queue if c.uid <= redir.owner]
            pc = redir.target
        new, want_line = [], None
        while len(queue) < self.width:
            w = self._word(pc)
            if w is None:
                want_line = pc & ~(self.LINE - 1)
                break
            uid += 1
            ins = Insn(uid, pc, w)
            ins.pred_pc, ins.bp_rec = self._predict(pc, w)
            queue.append(ins)
            new.append(ins)
            pc = ins.pred_pc
        return {"pc": pc, "uid": uid, "queue": queue, "new": new,
                "want_line": want_line, "redir": redir}

    def settle(self, bus):
        if bus.resetting():
            bus.pub(self.S_CANDS, None)
            bus.pub(self.S_IREQ, None)
            return
        e = self._eval(bus)
        bus.pub(self.S_CANDS, e["queue"][:self.width] or None)
        want = e["want_line"]
        if (want is not None and want != self.pending_line
                and self.pending_line is None and bus.get(self.S_IRDY)):
            bus.pub(self.S_IREQ, Xlate(want, want, self.LINE, ACCESS_EXEC,
                                       side="i"))
        else:
            bus.pub(self.S_IREQ, None)

    def tick(self, bus):
        if bus.resetting():
            self._reset_state()
            bus.pub(self.S_PC, self.pc)
            return
        if bus.get(self.S_REDIR) is not None and self.bp is not None:
            self.bp.recover()
        resp = bus.get(self.S_IRESP)
        if resp is not None and resp.side == "i":
            if resp.fault:
                bus.pub(self.S_IFAULT, (resp.fault, resp.vaddr))
            else:
                self.lines[resp.vaddr] = resp.data
            self.pending_line = None

        e = self._eval(bus)
        taken = bus.get(self.S_TAKEN) or 0
        self.queue = e["queue"][taken:]
        self.pc = e["pc"]
        self.uid = e["uid"]
        for ins in e["new"]:
            if self.bp is not None and ins.bp_rec is not None:
                self.bp.speculate(ins.bp_rec)
        self.fetched += len(e["new"])
        if e["want_line"] is not None:
            self.stall_mem += 1
        ack = bus.get(self.S_IACK)
        if ack is not None:
            self.pending_line = ack
            self.misses += 1
        bus.pub(self.S_PC, self.pc)

    def report(self):
        return {"fetched": self.fetched, "line_misses": self.misses,
                "cycles_waiting_on_imem": self.stall_mem}


class Issue(Module):
    """Rename, then Tomasulo: dispatch in order, issue out of order.

    The scoreboard this replaces stalled the whole issue stage on any
    unresolved source, and measured 57% of cycles on ``coremark_loop`` doing
    exactly that.  Two separate things fix it, and they are separate:

    **Rename** removes the false dependences.  Each destination takes a fresh
    physical register, so a WAW or WAR is not a dependence at all any more, and
    a source names the exact producer it wants rather than an architectural
    name several instructions might be fighting over.

    **Out-of-order issue** removes the head-of-line blocking.  An instruction
    waits in the window until *its own* sources are ready; a younger
    independent instruction goes first rather than queueing behind it.

    Wakeup is same-cycle.  ``exu.result`` is ASYNC, so a result produced this
    cycle wakes its dependent this cycle and that dependent issues this cycle:
    back-to-back dependent ALU ops at one cycle each, which is what the
    hardware does with a bypass network.  Registering that broadcast would cost
    one cycle per *dependent instruction* -- the exact case the boundary
    analysis in README 15 says never to register.

    Recovery is a walk, not a checkpoint: on a redirect the rename history is
    replayed backwards, each destination's previous mapping restored and its
    physical register returned. Slower than checkpointing at every branch, and
    it is a per-redirect cost rather than a per-cycle one."""

    name = "issue"
    publishes = [
        out("core.taken", ASYNC, LEVEL, 0),
        out("issue.exu", ASYNC, PULSE, None),
        out("issue.lsu", ASYNC, PULSE, None),
        out("issue.stall", ASYNC, LEVEL, 0, doc="reason dispatch stopped"),
        out("issue.window", REG, LEVEL, 0, doc="scheduler occupancy"),
        out("issue.free_prf", REG, LEVEL, 0, doc="physical registers free"),
    ]
    subscribes = ["core.cands", "redirect", "rob.free", "exu.ready",
                  "lsu.ready", "exu.result", "lsu.result", "rob.retired"]

    (OK, NO_ROB, NO_PRF, NO_WINDOW, UNIT) = range(5)
    STALL_NAMES = {OK: "dispatching", NO_ROB: "rob full", NO_PRF: "no free prf",
                   NO_WINDOW: "scheduler full", UNIT: "unit busy"}

    def __init__(self, regs, rob, width=2, phys_regs=63, window=32, name=None):
        self.regs = regs
        self.rob = rob
        self.width = width
        self.nphys = phys_regs
        self.window_size = window
        Module.__init__(self, name)

    def build(self, bus):
        for a, n in (("S_CANDS", "core.cands"), ("S_TAKEN", "core.taken"),
                     ("S_EXU", "issue.exu"), ("S_LSU", "issue.lsu"),
                     ("S_STALL", "issue.stall"), ("S_REDIR", "redirect"),
                     ("S_FREE", "rob.free"), ("S_ERDY", "exu.ready"),
                     ("S_LRDY", "lsu.ready"), ("S_ERES", "exu.result"),
                     ("S_LRES", "lsu.result"), ("S_RET", "rob.retired"),
                     ("S_WIN", "issue.window"), ("S_PRF", "issue.free_prf")):
            setattr(self, a, bus.signal(n))
        self._reset_state()

    def _reset_state(self):
        # p0 is the architectural zero: always ready, always zero.
        self.map = [0] * 32
        self.prf = [0] * (self.nphys + 1)
        self.ready = [True] * (self.nphys + 1)
        self.free = list(range(1, self.nphys + 1))
        for r in range(1, 32):
            self.map[r] = self.free.pop(0)
        self.window = []          # scheduler entries, waiting to issue
        # Selected but not yet complete.  The window entry is gone by then, so
        # without this a completing instruction has no physical destination to
        # wake and every dependent waits forever.
        self.inflight_pd = {}
        self.history = []         # (uid, arch_rd, new_p, old_p) for rollback
        self.issued = 0
        self.dispatched = 0
        self.stalls = {}
        self.window_peak = 0

    # -- wakeup ------------------------------------------------------------
    def _wakeups(self, bus):
        w = {}
        for d in (bus.get(self.S_ERES) or ()):
            w[d.uid] = d
        for d in (bus.get(self.S_LRES) or ()):
            w[d.uid] = d
        return w

    def _ready_now(self, p, woken_p):
        return p == 0 or self.ready[p] or p in woken_p

    def _value(self, p, woken_p):
        return 0 if p == 0 else woken_p.get(p, self.prf[p])

    # -- the pure dispatch + select function -------------------------------
    def _eval(self, bus):
        woken_p = {}
        for d in self._wakeups(bus).values():
            pd = self.inflight_pd.get(d.uid)
            if pd:
                woken_p[pd] = d.result if d.result is not None else 0

        if bus.get(self.S_REDIR) is not None:
            return {"taken": 0, "exu": [], "lsu": [], "order": [],
                    "sel": [], "stall": self.OK, "woken_p": woken_p}

        # --- dispatch, in order ------------------------------------------
        cands = bus.get(self.S_CANDS) or ()
        rob_free = bus.get(self.S_FREE) or 0
        taken, order = 0, []
        nfree = len(self.free)
        reason = self.OK
        room = self.window_size - len(self.window)
        for ins in cands:
            if taken >= self.width:
                break
            if taken >= rob_free:
                reason = self.NO_ROB
                break
            if room - taken <= 0:
                reason = self.NO_WINDOW
                break
            if ins.writes_rd and nfree - sum(1 for x in order if x.writes_rd) <= 0:
                reason = self.NO_PRF
                break
            order.append(ins)
            taken += 1

        # --- select, out of order ----------------------------------------
        eslots = bus.get(self.S_ERDY) or 0
        lslots = bus.get(self.S_LRDY) or 0
        exu, lsu = [], []
        oldest_store = None
        for e in self.window:
            if e["ins"].is_store and oldest_store is None:
                oldest_store = e["uid"]
            if not self._ready_now(e["ps1"], woken_p):
                continue
            if not self._ready_now(e["ps2"], woken_p):
                continue
            ins = e["ins"]
            wants_lsu = ins.klass in (R.LOAD, R.STORE)
            if wants_lsu:
                # Memory issues in order: the LSU is a queue, and letting a
                # younger access overtake an older one there would reorder
                # memory, not just execution.
                if oldest_store is not None and e["uid"] > oldest_store:
                    continue
                if len(lsu) >= lslots:
                    continue
            elif len(exu) >= eslots:
                continue
            pkt = Ready(ins, self._value(e["ps1"], woken_p),
                        self._value(e["ps2"], woken_p))
            (lsu if wants_lsu else exu).append(pkt)
        sel = [p.ins.uid for p in exu + lsu]
        return {"taken": taken, "exu": exu, "lsu": lsu, "order": order,
                "sel": sel, "stall": reason, "woken_p": woken_p}

    # -- phases -------------------------------------------------------------
    def settle(self, bus):
        if bus.resetting():
            bus.pub(self.S_TAKEN, 0)
            bus.pub(self.S_EXU, None)
            bus.pub(self.S_LSU, None)
            bus.pub(self.S_STALL, self.OK)
            return
        e = self._eval(bus)
        bus.pub(self.S_TAKEN, e["taken"])
        bus.pub(self.S_EXU, e["exu"] or None)
        bus.pub(self.S_LSU, e["lsu"] or None)
        bus.pub(self.S_STALL, e["stall"])

    def tick(self, bus):
        if bus.resetting():
            self._reset_state()
            bus.pub(self.S_WIN, 0)
            bus.pub(self.S_PRF, len(self.free))
            return

        e = self._eval(bus)

        # writeback: the physical register holds the value from now on
        for p, v in e["woken_p"].items():
            self.prf[p] = v
            self.ready[p] = True

        redir = bus.get(self.S_REDIR)
        if redir is not None:
            self._rollback(redir.owner)

        # retirement frees the mapping the retired instruction displaced
        for ins in (bus.get(self.S_RET) or ()):
            for i, (uid, rd, newp, oldp) in enumerate(self.history):
                if uid == ins.uid:
                    if oldp:
                        self.free.append(oldp)
                    del self.history[i]
                    break

        sel = set(e["sel"])
        for w in self.window:
            if w["uid"] in sel:
                self.inflight_pd[w["uid"]] = w["pd"]
        self.window = [w for w in self.window if w["uid"] not in sel]
        self.issued += len(sel)
        for uid in self._wakeups(bus):
            self.inflight_pd.pop(uid, None)

        for ins in e["order"]:
            ps1 = self.map[ins.rs1] if ins.uses_rs1 else 0
            ps2 = self.map[ins.rs2] if ins.uses_rs2 else 0
            pd, oldp = 0, 0
            if ins.writes_rd:
                pd = self.free.pop(0)
                oldp = self.map[ins.rd]
                self.map[ins.rd] = pd
                self.ready[pd] = False
                self.history.append((ins.uid, ins.rd, pd, oldp))
            self.window.append({"uid": ins.uid, "ins": ins, "ps1": ps1,
                                "ps2": ps2, "pd": pd})
            self.rob.alloc(ins, pd, oldp)
            self.dispatched += 1
        self.window_peak = max(self.window_peak, len(self.window))

        r = e["stall"] if not e["taken"] else self.OK
        self.stalls[r] = self.stalls.get(r, 0) + 1
        bus.pub(self.S_WIN, len(self.window))
        bus.pub(self.S_PRF, len(self.free))

    def _rollback(self, owner):
        """Undo renaming for everything younger than the redirect, newest
        first, so a register renamed twice ends up back at the older of the
        two mappings rather than the newer."""
        while self.history and self.history[-1][0] > owner:
            uid, rd, newp, oldp = self.history.pop()
            self.map[rd] = oldp
            self.free.append(newp)
            self.ready[newp] = True
            self.inflight_pd.pop(uid, None)
        self.window = [w for w in self.window if w["uid"] <= owner]

    def value_of(self, p):
        """Read a physical register, for the ROB at commit."""
        return 0 if p == 0 else self.prf[p]

    def report(self):
        return {"dispatched": self.dispatched, "issued": self.issued,
                "window_peak": self.window_peak, "prf": self.nphys,
                "cycles": dict((self.STALL_NAMES[k], v)
                               for k, v in sorted(self.stalls.items()))}


class Exu(Module):
    """The arithmetic pipes.  ALU and branch resolve in one cycle, multiply and
    divide take their own; a branch that disagrees with the prediction is the
    only thing here that redirects the frontend."""

    name = "exu"
    publishes = [
        # ASYNC on purpose.  Wakeup -> select -> issue is a loop *inside* one
        # cycle; register it and every dependent instruction takes an extra
        # cycle, which on a dependence-bound workload is the whole budget.
        out("exu.result", ASYNC, PULSE, None, doc="completions, this cycle"),
        out("exu.ready", ASYNC, LEVEL, 0, doc="pipes free this cycle"),
        out("exu.busy", REG, LEVEL, 0),
    ]
    subscribes = ["issue.exu", "redirect"]

    def __init__(self, pipes=2, mul_latency=3, div_latency=12, name=None):
        self.pipes = pipes
        self.mul_latency = mul_latency
        self.div_latency = div_latency
        Module.__init__(self, name)

    def build(self, bus):
        for a, n in (("S_IN", "issue.exu"), ("S_RES", "exu.result"),
                     ("S_RDY", "exu.ready"), ("S_BUSY", "exu.busy"),
                     ("S_REDIR", "redirect")):
            setattr(self, a, bus.signal(n))
        self._reset_state()

    def _reset_state(self):
        self.busy = []            # [(done_cycle, Ready)]
        self.completed = 0
        self.by_class = {}

    def _ripe(self, bus):
        """Which packets finish this cycle.  Pure: a function of the busy
        list, so settle and tick cannot disagree about it."""
        return [p for c, p in self.busy if c <= bus.cycle]

    def settle(self, bus):
        if bus.resetting():
            bus.pub(self.S_RDY, 0)
            bus.pub(self.S_RES, None)
            return
        bus.pub(self.S_RDY, max(0, self.pipes - len(self.busy)))
        out_ = [self._execute(p) for p in self._ripe(bus)]
        bus.pub(self.S_RES, out_ or None)

    def _latency(self, ins):
        if ins.klass != R.MULDIV:
            return 1
        return self.div_latency if R.funct3(ins.instr) >= 4 else self.mul_latency

    def tick(self, bus):
        if bus.resetting():
            self._reset_state()
            bus.pub(self.S_BUSY, 0)
            return
        redir = bus.get(self.S_REDIR)
        if redir is not None:
            self.busy = [(c, p) for c, p in self.busy if p.ins.uid <= redir.owner]

        for pkt in self._ripe(bus):
            self.completed += 1
            k = pkt.ins.klass
            self.by_class[k] = self.by_class.get(k, 0) + 1
        self.busy = [(c, p) for c, p in self.busy if c > bus.cycle]

        for pkt in (bus.get(self.S_IN) or ()):
            self.busy.append((bus.cycle + self._latency(pkt.ins), pkt))
        bus.pub(self.S_BUSY, len(self.busy))

    def _execute(self, pkt):
        ins, a, b = pkt.ins, pkt.a, pkt.b
        i, pc = ins.instr, ins.pc
        try:
            result = R.alu(i, a, b, pc) if ins.klass in (R.ALU, R.MULDIV,
                                                         R.JUMP) else None
            return Done(ins.uid, result, R.next_pc(i, pc, a, b))
        except R.Illegal:
            return Done(ins.uid, None, (pc + 4) & MASK, R.CAUSE_ILLEGAL, pc)

    def report(self):
        names = {R.ALU: "alu", R.BRANCH: "branch", R.JUMP: "jump",
                 R.MULDIV: "muldiv", R.SYSTEM: "system"}
        return {"completed": self.completed,
                "by_class": dict((names.get(k, str(k)), v)
                                 for k, v in sorted(self.by_class.items()))}


class Lsu(Module):
    """Loads and stores, through the MTL.

    Address generation is here; translation is not.  A store is held until it
    retires -- an in-order-retire machine must not let a speculative store
    change memory -- so what the LSU launches for a store is the *translation*,
    and retirement is what commits the bytes."""

    name = "lsu"
    publishes = [
        out("lsu.result", ASYNC, PULSE, None, doc="completions, this cycle"),
        out("lsu.ready", ASYNC, LEVEL, 0),
        out("mtl.dreq", ASYNC, PULSE, None),
        out("lsu.busy", REG, LEVEL, 0),
    ]
    subscribes = ["issue.lsu", "mtl.dresp", "mtl.dready", "mtl.dack",
                  "redirect", "rob.retired"]

    def __init__(self, depth=8, outstanding=8, ports=1, name=None):
        self.depth = depth
        # How many accesses can be *launched* per cycle.  What this unit
        # advertises as ready has to be launch capacity, not queue space:
        # advertising the queue lets the scheduler select eight loads into a
        # one-per-cycle port, and the wait then happens inside the load's
        # issue-to-complete rather than in the window where it belongs.  It
        # also pins ROB entries that are doing nothing.
        self.ports = ports
        # Non-blocking loads.  One access at a time puts the whole machine
        # behind each load's translate-plus-cache latency; the queue is still
        # ordered, but several accesses are in flight down it.
        self.outstanding = outstanding
        Module.__init__(self, name)

    def build(self, bus):
        for a, n in (("S_IN", "issue.lsu"), ("S_RES", "lsu.result"),
                     ("S_RDY", "lsu.ready"), ("S_REQ", "mtl.dreq"),
                     ("S_BUSY", "lsu.busy"), ("S_RESP", "mtl.dresp"),
                     ("S_DRDY", "mtl.dready"), ("S_REDIR", "redirect"),
                     ("S_RET", "rob.retired"), ("S_DACK", "mtl.dack")):
            setattr(self, a, bus.signal(n))
        self._reset_state()

    def _reset_state(self):
        self.q = []             # in-order, awaiting translation: [(Ready, addr, data)]
        self.sent = set()
        # Translated, not yet retired: (uid, paddr, bytes).  A store's bytes
        # are not in memory until it retires, so this is the only place a
        # younger load can find them.
        self.open_stores = []
        self.forwarded = 0
        self.blocked_partial = 0
        self.ordered = 0
        self.loads = 0
        self.stores = 0
        self.misaligned = 0

    def settle(self, bus):
        if bus.resetting():
            bus.pub(self.S_RDY, 0)
            bus.pub(self.S_REQ, None)
            return
        bus.pub(self.S_RDY, min(self.ports,
                                max(0, self.depth - len(self.q))))
        bus.pub(self.S_REQ, self._next_request(bus))

    def _next_request(self, bus):
        """The oldest access not yet handed to the MTL.  Pure.

        Ordered, but not serialised: an access is launched as soon as the port
        will take it, without waiting for the one before it to come back."""
        if not bus.get(self.S_DRDY) or len(self.sent) >= self.outstanding:
            return None
        for i, (pkt, addr, data) in enumerate(self.q):
            ins = pkt.ins
            if ins.uid in self.sent:
                continue
            size = (R.STORE_SIZE if ins.is_store else R.LOAD_SIZE)[
                R.funct3(ins.instr)]
            if not ins.is_store:
                st = self._disambiguate(ins.uid, addr, size, i)
                if st == "wait":
                    return None
                if st is not None:
                    continue          # forwarded; it needs no memory access
            elif i and any(self.q[j][0].ins.is_store for j in range(i)):
                # Stores translate in order among themselves; what makes them
                # visible is retirement, which is ordered anyway.  `continue`,
                # not `return`: stopping the scan here blocks every *load*
                # behind the store too, which is where 3 of the 4 cycles a
                # load spent waiting in this queue were going.
                continue
            acc = ACCESS_WRITE if ins.is_store else ACCESS_READ
            return Xlate(ins.uid, addr, size, acc, data, side="d")
        return None

    def _disambiguate(self, uid, addr, size, idx):
        """What older stores mean for this load.

        ``None``  nothing older overlaps -- go to memory.
        bytes     an older store covers it exactly -- forward, no access.
        "wait"    an older store overlaps only partially, or its address is
                  not known yet.

        Addresses are compared, not merely presence.  An older store in the
        queue has already been through address generation, so treating "there
        is a store ahead of me" as a reason to wait blocks every load behind
        every store regardless of where they point -- which measured as 4.5
        cycles per load sitting in this queue before it was even sent, more
        than the entire cache round trip."""
        best = None
        for j in range(idx):
            pkt_j, addr_j, data_j = self.q[j]
            other = pkt_j.ins
            if not other.is_store:
                continue
            if data_j is None or addr_j is None:
                return "wait"                     # address not resolved yet
            n = len(data_j)
            if addr_j == addr and n == size:
                best = data_j                     # exact cover: forwardable
            elif not (addr_j + n <= addr or addr + size <= addr_j):
                self.blocked_partial += 1
                return "wait"                     # partial overlap, no merge
        for (suid, spaddr, sdata) in self.open_stores:
            if suid > uid or sdata is None:
                continue
            if spaddr == addr and len(sdata) == size:
                best = sdata
            elif not (spaddr + len(sdata) <= addr or addr + size <= spaddr):
                self.blocked_partial += 1
                return "wait"
        return best

    def _blocked(self):
        """A load must not read past an older store that has not committed.

        A store leaves this queue when it is translated but its bytes do not
        land until it retires, so between those two points memory does not yet
        contain it.  Letting a younger load through that window reads stale
        memory -- invisible in any program where the store happens to retire
        first."""
        if not self.q:
            return False
        head = self.q[0][0].ins
        if head.is_store:
            return False
        _, addr, _d = self.q[0]
        size = R.LOAD_SIZE[R.funct3(head.instr)]
        return self._disambiguate(head.uid, addr, size, 0) == "wait"

    def _complete(self, bus):
        """The completion this cycle: a forward from an older store, or the
        MTL's answer.  Pure."""
        if self.q:
            pkt, addr, _ = self.q[0]
            ins = pkt.ins
            if not ins.is_store and ins.uid not in self.sent:
                size = R.LOAD_SIZE[R.funct3(ins.instr)]
                st = self._disambiguate(ins.uid, addr, size, 0)
                if st is not None and st != "wait":
                    d = Done(ins.uid, R.load_result(ins.instr, st),
                             (ins.pc + 4) & MASK, 0, None, addr)
                    d.store = ("fwd", None)   # marks where the value came from
                    return d
        resp = bus.get(self.S_RESP)
        if resp is None or resp.side != "d" or not self.q:
            return None
        pkt, addr, sdata = self.q[0]
        ins = pkt.ins
        if resp.tag != ins.uid:
            return None
        nxt = (ins.pc + 4) & MASK
        if resp.fault:
            store = ins.is_store
            if resp.fault == FAULT_ACCESS:
                cause = R.CAUSE_STORE_ACCESS if store else R.CAUSE_LOAD_ACCESS
            else:
                cause = (R.CAUSE_STORE_PAGE_FAULT if store
                         else R.CAUSE_LOAD_PAGE_FAULT)
            return Done(ins.uid, None, nxt, cause, ins.pc, addr)
        if ins.is_store:
            return Done(ins.uid, None, nxt, 0, None, addr, (resp.paddr, sdata))
        return Done(ins.uid, R.load_result(ins.instr, resp.data), nxt, 0,
                    None, addr)

    def _agen(self, bus):
        """Address generation for what issue just handed over.  Pure."""
        out_, queued = [], []
        for pkt in (bus.get(self.S_IN) or ()):
            ins = pkt.ins
            i = ins.instr
            off = R.imm_s(i) if ins.is_store else R.imm_i(i)
            addr = (pkt.a + off) & MASK
            size = (R.STORE_SIZE if ins.is_store else R.LOAD_SIZE)[R.funct3(i)]
            if addr % size:
                cause = (R.CAUSE_STORE_MISALIGNED if ins.is_store
                         else R.CAUSE_LOAD_MISALIGNED)
                out_.append(Done(ins.uid, None, (ins.pc + 4) & MASK, cause,
                                 ins.pc, addr))
                continue
            data = None
            if ins.is_store:
                data = (pkt.b & ((1 << (size * 8)) - 1)).to_bytes(size, "little")
            queued.append((pkt, addr, data))
        return out_, queued

    def settle(self, bus):
        if bus.resetting():
            bus.pub(self.S_RDY, 0)
            bus.pub(self.S_REQ, None)
            bus.pub(self.S_RES, None)
            return
        bus.pub(self.S_RDY, min(self.ports,
                                max(0, self.depth - len(self.q))))
        bus.pub(self.S_REQ, self._next_request(bus))
        done = self._complete(bus)
        bad, _ = self._agen(bus)
        out_ = ([done] if done else []) + bad
        bus.pub(self.S_RES, out_ or None)

    def tick(self, bus):
        if bus.resetting():
            self._reset_state()
            bus.pub(self.S_BUSY, 0)
            return
        for ins in (bus.get(self.S_RET) or ()):
            self.open_stores = [t for t in self.open_stores
                                if t[0] != ins.uid]
        if self._blocked():
            self.ordered += 1
        redir = bus.get(self.S_REDIR)
        if redir is not None:
            self.q = [t for t in self.q if t[0].ins.uid <= redir.owner]
            self.open_stores = [t for t in self.open_stores
                                if t[0] <= redir.owner]
            # `sent` is not pruned here: those transactions are still in the
            # MTL and their responses are what retire them.

        resp = bus.get(self.S_RESP)
        if resp is not None and resp.side == "d":
            self.sent.discard(resp.tag)
        done = self._complete(bus)
        if done is not None:
            self.q.pop(0)
            if done.store is not None:
                self.stores += 1
                self.open_stores.append((done.uid, done.store[0], done.store[1]))
            elif not done.fault:
                self.loads += 1
                if done.store is not None and done.store[0] == "fwd":
                    self.forwarded += 1
                    done.store = None
        bad, queued = self._agen(bus)
        self.misaligned += len(bad)
        self.q.extend(queued)
        ack = bus.get(self.S_DACK)
        if ack is not None:
            self.sent.add(ack)
        bus.pub(self.S_BUSY, len(self.q))

    def report(self):
        return {"loads": self.loads, "stores": self.stores,
                "misaligned": self.misaligned,
                "cycles_ordered_behind_a_store": self.ordered,
                "forwarded_from_store": self.forwarded,
                "blocked_partial_overlap": self.blocked_partial,
                "max_outstanding": self.outstanding}


class Rob(Module):
    """Reorder buffer and in-order retirement.

    Retirement is the only thing that changes architectural state: registers,
    memory (a store is launched here, not at issue), and the CSRs.  It is also
    where a branch is checked against what fetch predicted, because that is the
    first point at which the answer is known to be on the real path -- a
    mispredict found on a wrong path is not a mispredict.

    A fault at the head stops the machine.  See the module docstring: the
    honest intermediate is to halt with a cause rather than half-deliver a
    trap."""

    name = "rob"
    publishes = [
        out("rob.free", ASYNC, LEVEL, 0),
        out("rob.retired", REG, PULSE, None, doc="committed this edge"),
        out("dispatch.sched", REG, PULSE, None, doc="redirect on mispredict"),
        out("rob.count", REG, LEVEL, 0),
        out("csr.satp", REG, LEVEL, 0),
        out("csr.priv", REG, LEVEL, PRIV_M),
        out("csr.sfence", REG, PULSE, False),
        out("core.halt", REG, LEVEL, None, doc="(reason, pc) once stopped"),
        # A list: retirement can commit several stores in one cycle, and a
        # single-valued pulse silently keeps only the last of them -- memory
        # stays right because the ROB writes it directly, but the cache keeps
        # a stale line and a later load reads it.  Only visible above retire
        # width 2, which is why a width sweep is worth running.
        out("commit.store", REG, PULSE, None,
            doc="[(paddr, bytes)] posted at retirement, never before"),
    ]
    subscribes = ["exu.result", "lsu.result", "core.ifault", "redirect"]

    def __init__(self, regs, mem, depth=16, retire_width=2, name=None,
                 predictor=None):
        self.boot_priv = PRIV_M
        self.boot_satp = 0
        self.regs = regs
        self.mem = mem
        self.depth = depth
        self.retire_width = retire_width
        self.bp = predictor        # trained at retirement: the only ordered
                                   # point at which an outcome is known real
        self.entries = []
        self.renames = {}          # uid -> (new phys, displaced phys)
        Module.__init__(self, name)

    def build(self, bus):
        for a, n in (("S_FREE", "rob.free"), ("S_RET", "rob.retired"),
                     ("S_SCHED", "dispatch.sched"), ("S_COUNT", "rob.count"),
                     ("S_SATP", "csr.satp"), ("S_PRIV", "csr.priv"),
                     ("S_SFENCE", "csr.sfence"), ("S_HALT", "core.halt"),
                     ("S_EXU", "exu.result"), ("S_LSU", "lsu.result"),
                     ("S_IFAULT", "core.ifault"), ("S_REDIR", "redirect"),
                     ("S_ST", "commit.store")):
            setattr(self, a, bus.signal(n))
        self._reset_state()
        # The boot CSR state has to be visible in cycle 0, not a cycle later:
        # the very first fetch translates, and a machine that starts in Bare
        # for one cycle reads whatever is at the untranslated address.
        bus.pub(self.S_SATP, self.satp)
        bus.pub(self.S_PRIV, self.priv)

    def _reset_state(self):
        del self.entries[:]
        self.renames.clear()
        self.state = {}            # uid -> Done, as results arrive
        self._posted = []
        self.retired = 0
        self.mispredicts = 0
        self.halt = None
        self.satp = self.boot_satp
        self.priv = self.boot_priv
        self.csrs = {0x180: self.boot_satp}
        self.mode_returns = 0
        self.ecalls = 0

    # -- the scoreboard, read by Issue -------------------------------------
    def alloc(self, ins, pd=0, oldp=0):
        self.entries.append(ins)
        self.renames[ins.uid] = (pd, oldp)



    def _flush(self, owner):
        for i in self.entries:
            if i.uid > owner:
                self.state.pop(i.uid, None)
                self.renames.pop(i.uid, None)
        self.entries = [i for i in self.entries if i.uid <= owner]

    def settle(self, bus):
        bus.pub(self.S_FREE, 0 if (bus.resetting() or self.halt)
                else max(0, self.depth - len(self.entries)))

    def tick(self, bus):
        if bus.resetting():
            self._reset_state()
            bus.pub(self.S_COUNT, 0)
            # Reset restores the *boot* CSR state, not zero: a machine handed
            # a page table and dropped into supervisor mode must come out of
            # reset translating, or its first fetch reads an untranslated
            # address and finds whatever is there.
            bus.pub(self.S_SATP, self.satp)
            bus.pub(self.S_PRIV, self.priv)
            bus.pub(self.S_HALT, None)
            return
        if self.halt:
            return

        f = bus.get(self.S_IFAULT)
        if f is not None:
            self.halt = ("fetch %s at %#x" %
                         ("page fault" if f[0] == FAULT_PAGE else "access fault",
                          f[1]), f[1])
            bus.pub(self.S_HALT, self.halt)
            return

        redir = bus.get(self.S_REDIR)
        if redir is not None:
            # Anything younger than the redirect's owner was fetched down a
            # path that no longer exists.  Without this the entries issued
            # between detecting a mispredict and the redirect landing sit at
            # the head forever, waiting for units that already dropped them.
            self._flush(redir.owner)

        for d in (bus.get(self.S_EXU) or ()):
            self.state[d.uid] = d
        for d in (bus.get(self.S_LSU) or ()):
            self.state[d.uid] = d

        retired, sched = [], []
        self._posted = []
        n = 0
        while self.entries and n < self.retire_width:
            head = self.entries[0]
            d = self.state.get(head.uid)
            if d is None:
                break
            if d.fault:
                self.halt = ("%s at %#x%s" % (_CAUSE.get(d.fault, "fault"),
                                              d.fault_pc or head.pc,
                                              "" if d.addr is None
                                              else " (addr %#x)" % d.addr),
                             head.pc)
                break
            self.entries.pop(0)
            self.state.pop(head.uid, None)
            self.renames.pop(head.uid, None)
            stop = self._commit(head, d, bus, sched)
            retired.append(head)
            self.retired += 1
            n += 1
            if stop:
                break
        if retired:
            bus.pub(self.S_RET, retired)
        if self._posted:
            bus.pub(self.S_ST, list(self._posted))
        if sched:
            bus.pub(self.S_SCHED, sched)
        bus.pub(self.S_COUNT, len(self.entries))
        bus.pub(self.S_SATP, self.satp)
        bus.pub(self.S_PRIV, self.priv)
        if self.halt:
            bus.pub(self.S_HALT, self.halt)

    def _commit(self, ins, d, bus, sched):
        """Architectural state changes, in order.  Returns True to stop this
        cycle's retirement (a redirect or a halt)."""
        from .dispatch import Sched
        if self.bp is not None and ins.bp_rec is not None \
                and d.next_pc is not None:
            taken = d.next_pc != ((ins.pc + 4) & MASK)
            self.bp.train(ins.bp_rec, taken, d.next_pc)
        if ins.klass == R.SYSTEM and self._system(ins, d, bus, sched):
            return True
        if ins.writes_rd and d.result is not None:
            self.regs.write(ins.rd, d.result)
        if d.store is not None and d.store[1] is not None:
            # Posted here and nowhere earlier.  The cache is write-through, so
            # if it applied the store when the LSU translated it, a store on a
            # path that never retires would already be in memory.
            self.mem.write(d.store[0], d.store[1])
            self._posted.append(d.store)
        if d.next_pc is not None and d.next_pc != ins.pred_pc:
            self.mispredicts += 1
            sched.append(Sched(1, ins.uid, d.next_pc, "mispredict", True))
            self._flush(ins.uid)
            return True
        return False

    def _system(self, ins, d, bus, sched):
        from .dispatch import Sched
        i = ins.instr
        f3 = R.funct3(i)
        if f3 == 0:
            imm = (i >> 20) & 0xFFF
            if imm == 0:                        # ECALL
                self.ecalls += 1
                self.halt = ("ecall at %#x (a0=%d)" %
                             (ins.pc, self.regs.read(10)), ins.pc)
                return True
            if imm == 1:                        # EBREAK
                self.halt = ("ebreak at %#x" % ins.pc, ins.pc)
                return True
            if imm in (0x102, 0x302):           # SRET / MRET
                # Enough of the trap frame to *leave* a trap: restore the
                # privilege the mode-return bits name and resume at the EPC.
                # Entering a trap is still not modelled -- a fault halts -- but
                # a boot stub dropping into supervisor mode is the normal way
                # a machine starts, not an exceptional path, and refusing it
                # meant no image with an Sv39 loader could run at all.
                mret = imm == 0x302
                st = self.csrs.get(0x300, 0)          # mstatus
                if mret:
                    self.priv = (st >> 11) & 3        # MPP
                    st = (st & ~(3 << 11)) | (PRIV_U << 11)
                    st |= (1 << 3) if (st >> 7) & 1 else 0   # MIE <- MPIE
                    self.csrs[0x300] = st | (1 << 7)
                    target = self.csrs.get(0x341, 0)  # mepc
                else:
                    self.priv = (st >> 8) & 1         # SPP
                    self.csrs[0x300] = st & ~(1 << 8)
                    target = self.csrs.get(0x141, 0)  # sepc
                self.mode_returns += 1
                sched.append(Sched(1, ins.uid, target & MASK,
                                   "mret" if mret else "sret", True))
                self._flush(ins.uid)
                return True
            if (i >> 25) == 0x09:               # SFENCE.VMA
                bus.pub(self.S_SFENCE, True)
                return False
            return False
        csr = (i >> 20) & 0xFFF
        old = self.csrs.get(csr, self.satp if csr == 0x180 else 0)
        src = self.regs.read((i >> 15) & 0x1F) if f3 in (1, 2, 3) \
            else ((i >> 15) & 0x1F)
        if f3 in (1, 5):
            new = src
        elif f3 in (2, 6):
            new = old | src
        elif f3 in (3, 7):
            new = old & ~src
        else:
            new = old
        if ins.writes_rd:
            self.regs.write(ins.rd, old)
        self.csrs[csr] = new & MASK
        if csr == 0x180:                        # satp
            self.satp = new & MASK
        return False

    def report(self):
        return {"retired": self.retired, "mispredicts": self.mispredicts,
                "in_flight": len(self.entries), "halt": self.halt,
                "mode_returns": self.mode_returns,
                "priv": self.priv, "satp": "%#x" % self.satp}


_CAUSE = {
    R.CAUSE_ILLEGAL: "illegal instruction",
    R.CAUSE_LOAD_MISALIGNED: "misaligned load",
    R.CAUSE_STORE_MISALIGNED: "misaligned store",
    R.CAUSE_LOAD_PAGE_FAULT: "load page fault",
    R.CAUSE_STORE_PAGE_FAULT: "store page fault",
    R.CAUSE_LOAD_ACCESS: "load access fault",
    R.CAUSE_STORE_ACCESS: "store access fault",
}
