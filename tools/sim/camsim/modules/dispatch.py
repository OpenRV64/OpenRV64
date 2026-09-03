"""Dispatch: the admission gate, and where speculation is decided.

``casim.frontend`` phase 3.  Candidates are consumed in order, up to the
backend's credit, and each one's *path* is decided here rather than at fetch:
the sequential candidates presented alongside a predicted-taken transfer were
fetched before anyone knew they were shadow work.

This is sequential within a cycle, and deliberately one module because of it.
Admitting a predicted-taken branch makes the very next candidate in the same
cycle shadow work, so the loop cannot be split across a signal without
iterating the bus per candidate.  Where two things resolve in series inside one
cycle, they are one unit -- that is the rule that decides where a module
boundary goes.

What it drives out:

  ``fetch.taken``       how many candidates it consumed
  ``dispatch.sched``    redirects to arm, for the resolver to time
  ``dispatch.stash``    bring the not-taken side resident (``req_stash_o``)
  ``dispatch.admitted`` the frontend's output stream, shadow work included

Two static artefacts arrive as constructor arguments, not signals: the control
event trace being replayed, and the fetch image (a wrong-path prediction is
only followed where the golden recorded encodings to follow).  Both are replay
inputs -- when a real predictor exists it publishes instead, and this unit
subscribes.
"""

from ..module import Module, out, ASYNC, REG, LEVEL, PULSE

_MASK = 0xFFFFFFFFFFFFFFFF


class Sched(object):
    """A redirect dispatch wants armed, and when relative to now."""

    __slots__ = ("delay", "owner", "target", "kind", "to_correct_path")

    def __init__(self, delay, owner, target, kind, to_correct_path):
        self.delay = delay
        self.owner = owner
        self.target = target
        self.kind = kind
        self.to_correct_path = to_correct_path

    def __eq__(self, o):
        return (isinstance(o, Sched) and o.owner == self.owner
                and o.target == self.target and o.kind == self.kind
                and o.delay == self.delay)

    def __ne__(self, o):
        return not self.__eq__(o)

    def __hash__(self):
        return hash((self.delay, self.owner, self.target, self.kind))

    def __repr__(self):
        return "%s+%d>u%d@%x" % (self.kind, self.delay, self.owner, self.target)


def default_wrong_path_predictor():
    """Static backward-taken, the rule casim uses off the architectural path.

    There is no recorded outcome on a wrong path, so this only decides which
    garbage fills the shadow.  It is an approximation and is counted as one."""
    from casim import isa

    def predict(op):
        tgt = isa.taken_target(op.pc, op.instr)
        if tgt is None:
            return None
        if (op.instr & 0x7F) == isa.OP_JAL or tgt < op.pc:
            return tgt
        return None
    return predict


class Dispatch(Module):
    name = "dispatch"
    publishes = [
        out("fetch.taken", ASYNC, LEVEL, 0, doc="candidates admitted this cycle"),
        out("dispatch.sched", ASYNC, PULSE, doc="redirects to arm"),
        out("dispatch.stash", ASYNC, PULSE, doc="bring this block resident"),
        out("dispatch.admitted", ASYNC, PULSE, doc="admitted stream, shadow included"),
        out("dispatch.arch", REG, LEVEL, 0, doc="architectural instructions admitted"),
        out("dispatch.shadow", REG, LEVEL, 0, doc="uid owning the open shadow, 0 none"),
    ]
    subscribes = ["decode.ops", "redirect", "backend.credits"]

    def __init__(self, events, image, width=3, taken_delay=1, mispredict_delay=1,
                 resolve_latency=None, stash_unpredicted=True, refill=0,
                 predictor=None, keep_stream=False, name=None):
        self.events = events
        self.image = image
        self.width = width
        self.taken_delay = taken_delay
        self.mispredict_delay = mispredict_delay
        self.resolve_latency = resolve_latency
        self.stash_unpredicted = stash_unpredicted
        self.refill = refill
        self._predict = predictor
        self.keep_stream = keep_stream
        Module.__init__(self, name)

    def build(self, bus):
        self.S_OPS = bus.signal("decode.ops")
        self.S_REDIR = bus.signal("redirect")
        self.S_CRED = bus.signal("backend.credits")
        self.S_TAKEN = bus.signal("fetch.taken")
        self.S_SCHED = bus.signal("dispatch.sched")
        self.S_STASH = bus.signal("dispatch.stash")
        self.S_ADM = bus.signal("dispatch.admitted")
        self.S_ARCH = bus.signal("dispatch.arch")
        self.S_SHADOW = bus.signal("dispatch.shadow")
        if self._predict is None:
            self._predict = default_wrong_path_predictor()
        self._reset_state()

    def _reset_state(self):
        self.arch_done = 0
        self.ev_i = 0
        self.shadow_owner = None
        self.shadow_live = []      # admitted shadow work not yet attributed
        self.delivered = 0
        self.wrong_path = 0
        self.squashed = 0
        self.stream = []
        self.event_pc_mismatches = 0
        self.wrong_path_predicts = 0

    # -- the pure admission function ---------------------------------------
    def _eval(self, bus):
        """Admit in order.  Pure: nothing on self is written."""
        ops = bus.get(self.S_OPS) or ()
        credits = bus.get(self.S_CRED)
        credits = self.width if credits is None else min(credits, self.width)
        redir = bus.get(self.S_REDIR)

        shadow = self.shadow_owner
        squashed = 0
        if redir is not None:
            # Shadow work already admitted is the backend's problem now; what
            # matters here is that a redirect back to the architectural path
            # closes the shadow.
            squashed = sum(1 for o in self.shadow_live if o.uid > redir.owner)
            if redir.to_correct_path:
                shadow = None

        arch, ev_i = self.arch_done, self.ev_i
        taken, admitted, sched, stash = 0, [], [], []
        n_ev = len(self.events)
        for op in ops:
            if taken >= credits:
                break
            wrong = shadow is not None
            ev = None
            if not wrong and ev_i < n_ev and self.events[ev_i].arch_i == arch:
                ev = self.events[ev_i]
            admitted.append((op, wrong))
            taken += 1
            if wrong:
                if op.is_control:
                    tgt = self._predict(op)
                    if tgt is not None and tgt in self.image:
                        sched.append(Sched(self.taken_delay, op.uid, tgt,
                                           "wrong-path-predict", False))
            else:
                arch += 1
                if ev is not None:
                    ev_i += 1
                    shadow = self._arm(op, ev, sched, stash, shadow)
        return {"taken": taken, "admitted": admitted, "sched": sched,
                "stash": stash, "arch": arch, "ev_i": ev_i, "shadow": shadow,
                "squashed": squashed, "redir": redir}

    def _arm(self, op, e, sched, stash, shadow):
        """The redirects an admitted architectural transfer raises.

        Four cases, all visible in the golden: predicted not-taken and right
        (nothing); predicted not-taken and wrong (shadow opens now, closes on
        resolve); predicted taken and right (shadow until the prediction
        redirects); predicted taken and wrong (shadow until resolve, through
        the predicted target)."""
        seq = (op.pc + 4) & _MASK
        predicted_elsewhere = not e.implicit and e.pred_next_pc != seq
        # An implicit event always needs a resolve-time redirect even when it
        # lands back on its own successor: a serialising CSR write or fence
        # refetches pc+4 and throws away the prefix it had already fetched,
        # which the mispredict test cannot see.
        mispredicted = e.mispredicted or e.implicit
        if predicted_elsewhere:
            sched.append(Sched(self.taken_delay, op.uid, e.pred_next_pc,
                               "predicted-taken", not mispredicted))
            if self.refill and self.stash_unpredicted:
                stash.append(seq)
        if mispredicted:
            lat = self.resolve_latency or e.resolve_lat or 1
            sched.append(Sched(lat + self.mispredict_delay, op.uid, e.next_pc,
                               "implicit-redirect" if e.implicit else "mispredict",
                               True))
        if predicted_elsewhere or mispredicted:
            return op.uid if shadow is None else shadow
        return shadow

    # -- phases -------------------------------------------------------------
    def settle(self, bus):
        if bus.resetting():
            bus.pub(self.S_TAKEN, 0)
            bus.pub(self.S_SCHED, None)
            bus.pub(self.S_STASH, None)
            bus.pub(self.S_ADM, None)
            return
        e = self._eval(bus)
        bus.pub(self.S_TAKEN, e["taken"])
        bus.pub(self.S_SCHED, e["sched"] or None)
        bus.pub(self.S_STASH, e["stash"] or None)
        bus.pub(self.S_ADM, e["admitted"] or None)

    def tick(self, bus):
        if bus.resetting():
            self._reset_state()
            bus.pub(self.S_ARCH, 0)
            bus.pub(self.S_SHADOW, 0)
            return
        e = self._eval(bus)
        redir = e["redir"]
        if redir is not None:
            self.shadow_live = [o for o in self.shadow_live
                                if o.uid <= redir.owner]
            self.squashed += e["squashed"]
        self.arch_done, self.ev_i = e["arch"], e["ev_i"]
        self.shadow_owner = e["shadow"]
        for op, wrong in e["admitted"]:
            self.delivered += 1
            if wrong:
                self.wrong_path += 1
                self.shadow_live.append(op)
            if self.keep_stream:
                self.stream.append((op, wrong))
        for s in e["sched"]:
            if s.kind == "wrong-path-predict":
                self.wrong_path_predicts += 1
        bus.pub(self.S_ARCH, self.arch_done)
        bus.pub(self.S_SHADOW, self.shadow_owner or 0)

    def report(self):
        return {"delivered": self.delivered, "arch": self.arch_done,
                "wrong_path": self.wrong_path,
                "events_used": self.ev_i, "events": len(self.events),
                "shadow_squashed": self.squashed,
                "wrong_path_predicts": self.wrong_path_predicts}
