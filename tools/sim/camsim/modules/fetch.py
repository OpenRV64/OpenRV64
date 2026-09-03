"""The fetch unit, ported from ``casim.frontend`` phase 1-2.

What it owns is what the RTL's fetch owns: the fetch PC, a small
direct-mapped window of resident fetch blocks, a presentation queue, and the
flush a redirect causes.  What it does not own is why a redirect happened --
that arrives as a signal, which is the whole point of the split.  In casim
these were steps 1 and 2 of one loop that also contained the admission gate;
here the gate is a separate unit and the boundary between them is
``fetch.cands`` / ``fetch.taken``.

Same-cycle push and pop
-----------------------
casim fills the presentation queue and drains it inside one iteration, so a
candidate can be fetched and admitted in the same cycle -- a fetch buffer with
bypass.  Reproducing that means ``fetch.cands`` is ASYNC: it is the queue head
*after* this cycle's flush and push, computed from flop state.  The state
changes that go with it (the PC advancing, the queue growing, blocks becoming
resident) happen at ``tick``.

So the presentation is written once, as a pure function of the flop state plus
the redirect, and called from both phases -- ``settle`` to publish it and
``tick`` to commit it.  That is ``always_async`` next-state logic feeding an
``always_ff``, and running the identical function in both is what stops the
published candidates and the committed state from ever disagreeing.

Not modelled here: the instruction image is a constructor argument rather than
a signal.  That is the seam where a real L1I module goes -- it would publish a
response and this unit would subscribe to it, and the resident-window model
below would move into it.
"""

from ..module import Module, out, ASYNC, REG, LEVEL, PULSE

_MASK = 0xFFFFFFFFFFFFFFFF

# Why fetch presented nothing.  Exclusive, tested in this order, mirroring
# casim's reason discipline (and the trace's).  DELIVER/GATE are decided with
# the gate's answer, so they are settled at the edge, not in settle.
(FS_DELIVER, FS_GATE, FS_REDIRECT, FS_REFILL, FS_IMAGE) = range(5)
FS_NAMES = {
    FS_DELIVER: "delivering",
    FS_GATE: "gate backpressure (backend)",
    FS_REDIRECT: "redirect bubble (nothing to present)",
    FS_REFILL: "fetch block not resident",
    FS_IMAGE: "wrong path ran off the fetch image",
}


class Cand(object):
    """One presented candidate.  Fetch knows a candidate's identity and where
    it came from; what it *is* is decode's business."""

    __slots__ = ("uid", "pc", "instr", "fetch_cycle", "admit_cycle")

    def __init__(self, uid, pc, instr, fetch_cycle):
        self.uid = uid
        self.pc = pc
        self.instr = instr
        self.fetch_cycle = fetch_cycle
        self.admit_cycle = None

    # Value equality matters on the bus: `settle` is re-run whenever an input
    # moves and allocates fresh objects each time, so without this a
    # re-evaluation that reached the identical answer would look like a change
    # -- a spurious fire, an extra wake, and a async depth reported one
    # level deeper than the signal really settles at.
    def __eq__(self, other):
        return isinstance(other, Cand) and other.uid == self.uid

    def __ne__(self, other):
        return not self.__eq__(other)

    def __hash__(self):
        return self.uid

    def __repr__(self):
        return "u%d@%x" % (self.uid, self.pc)


class Redirect(object):
    """What a resolver hands fetch: which uid supersedes, and where to go."""

    __slots__ = ("owner", "target", "kind", "to_correct_path")

    def __init__(self, owner, target, kind="redirect", to_correct_path=True):
        self.owner = owner
        self.target = target
        self.kind = kind
        self.to_correct_path = to_correct_path

    def __eq__(self, other):
        return (isinstance(other, Redirect) and other.owner == self.owner
                and other.target == self.target and other.kind == self.kind)

    def __ne__(self, other):
        return not self.__eq__(other)

    def __hash__(self):
        return hash((self.owner, self.target, self.kind))

    def __repr__(self):
        return "%s>u%d@%x" % (self.kind, self.owner, self.target)


class Fetch(Module):
    name = "fetch"
    publishes = [
        out("fetch.cands", ASYNC, PULSE, doc="queue head, this cycle's offer"),
        out("fetch.qdepth", ASYNC, LEVEL, 0, doc="presentation queue occupancy"),
        out("fetch.reason", ASYNC, LEVEL, FS_DELIVER, doc="why fetch supplied less"),
        out("fetch.pc", REG, LEVEL, 0, doc="fetch PC after this cycle"),
        out("fetch.uid", REG, LEVEL, 0, doc="last uid allocated"),
    ]
    subscribes = ["fetch.taken", "redirect", "dispatch.stash"]

    def __init__(self, image, entry_pc=0, width=3, queue_depth=3,
                 block_bytes=64, window_blocks=4, refill=0, present_width=3,
                 name=None):
        self.image = image
        self.entry_pc = entry_pc
        self.width = width                  # candidates presented per cycle
        self.queue_depth = queue_depth
        self.block_bytes = block_bytes
        self.window_blocks = window_blocks
        self.refill = refill
        self.present_width = present_width  # how many the gate may see at once
        Module.__init__(self, name)

    # -- wiring ------------------------------------------------------------
    def build(self, bus):
        self.S_CANDS = bus.signal("fetch.cands")
        self.S_QD = bus.signal("fetch.qdepth")
        self.S_REASON = bus.signal("fetch.reason")
        self.S_PC = bus.signal("fetch.pc")
        self.S_UID = bus.signal("fetch.uid")
        self.S_TAKEN = bus.signal("fetch.taken")
        self.S_REDIR = bus.signal("redirect")
        self.S_STASH = bus.signal("dispatch.stash")
        self._reset_state()

    def _reset_state(self):
        self.pc = self.entry_pc
        self.uid = 0
        self.queue = []          # presented, not yet taken (fetch order)
        self.resident = {}       # window slot -> (block, cycle it is usable)
        self.fetched = 0
        self.discarded = 0
        self.image_misses = 0
        self.reasons = {}
        self.redirects = {}
        self.delivered = 0

    # -- the resident window ----------------------------------------------
    def _block(self, pc):
        return pc // self.block_bytes

    def _ready(self, blk, cyc, overlay):
        """When this block becomes usable, without changing anything.

        The window is direct-mapped, so a block displaces whatever shares its
        slot rather than joining an unbounded set.  ``overlay`` carries the
        requests this same evaluation has already made, which is what keeps
        the function pure: called twice with the same state it answers twice
        the same way."""
        slot = blk % self.window_blocks
        have = overlay.get(slot, self.resident.get(slot))
        if have is not None and have[0] == blk:
            return have[1]
        ready = cyc + self.refill
        overlay[slot] = (blk, ready)
        return ready

    # -- the pure next-state function --------------------------------------
    def _eval(self, bus, cyc):
        """Flush, present, and offer -- from flop state alone.

        Returns everything both phases need: what to publish now and what to
        commit at the edge.  No attribute of self is written."""
        pc = self.pc
        uid = self.uid
        queue = self.queue
        overlay = {}
        reason = None
        discarded = 0
        redir = bus.get(self.S_REDIR)      # a pulse holds all cycle; asserted
                                           # means non-idle, not "woke me"

        # (1) A redirect supersedes everything younger than its owner.
        if redir is not None:
            discarded = sum(1 for c in queue if c.uid > redir.owner)
            queue = [c for c in queue if c.uid <= redir.owner]
            pc = redir.target
            reason = FS_REDIRECT

        # (2) Present up to `width` candidates from resident blocks.
        queue = list(queue)
        new = []
        misses = 0
        while len(new) < self.width and len(queue) < self.queue_depth:
            if self._ready(self._block(pc), cyc, overlay) > cyc:
                if reason is None:
                    reason = FS_REFILL
                break
            instr = self.image.get(pc)
            if instr is None:
                # Off the recorded image.  Only reachable on a wrong path,
                # where the golden never went and so never recorded the
                # encodings.  Stop; the pending resolve redirect recovers.
                misses += 1
                if reason is None:
                    reason = FS_IMAGE
                break
            uid += 1
            c = Cand(uid, pc, instr, cyc)
            queue.append(c)
            new.append(c)
            pc = (pc + 4) & _MASK

        # Stash: dispatch asks for the side the predictor did not take, so a
        # mispredict finds it already resident.
        if self.refill:
            for spc in (bus.get(self.S_STASH) or ()):
                self._ready(self._block(spc), cyc, overlay)

        # Rolling cursor: keep the blocks ahead of the fetch PC requested,
        # which is what hides refill latency on a sequential stream.  Walk
        # oldest-first so the block under the cursor survives.
        if self.refill:
            base = self._block(pc)
            for k in range(self.window_blocks - 1, -1, -1):
                self._ready(base + k, cyc, overlay)

        offer = queue[:self.present_width]
        return {"queue": queue, "pc": pc, "uid": uid, "overlay": overlay,
                "offer": offer, "reason": reason, "new": len(new),
                "discarded": discarded, "misses": misses, "redir": redir}

    # -- phases -------------------------------------------------------------
    def settle(self, bus):
        if bus.resetting():
            bus.pub(self.S_CANDS, None)
            bus.pub(self.S_QD, 0)
            bus.pub(self.S_REASON, FS_REDIRECT)
            return
        e = self._eval(bus, bus.cycle)
        bus.pub(self.S_CANDS, e["offer"] or None)
        bus.pub(self.S_QD, len(e["queue"]))
        bus.pub(self.S_REASON, FS_DELIVER if e["reason"] is None else e["reason"])

    def tick(self, bus):
        if bus.resetting():
            self._reset_state()
            bus.pub(self.S_PC, self.pc)
            bus.pub(self.S_UID, 0)
            return

        e = self._eval(bus, bus.cycle)
        taken = bus.get(self.S_TAKEN) or 0
        if taken > len(e["offer"]):
            raise RuntimeError(
                "%s: gate took %d of %d offered candidates"
                % (self.name, taken, len(e["offer"])))

        self.resident.update(e["overlay"])
        self.queue = e["queue"][taken:]
        self.pc = e["pc"]
        self.uid = e["uid"]
        self.fetched += e["new"]
        self.discarded += e["discarded"]
        self.image_misses += e["misses"]
        self.delivered += taken
        if e["redir"] is not None:
            k = e["redir"].kind
            self.redirects[k] = self.redirects.get(k, 0) + 1

        # The reason is exclusive and the gate's answer completes it, which is
        # why it is settled here rather than published in settle.
        reason = e["reason"]
        if taken:
            reason = FS_DELIVER
        elif reason is None:
            reason = FS_GATE if e["queue"] else FS_REDIRECT
        self.reasons[reason] = self.reasons.get(reason, 0) + 1

        bus.pub(self.S_PC, self.pc)
        bus.pub(self.S_UID, self.uid)

    def report(self):
        return {"fetched": self.fetched, "delivered": self.delivered,
                "discarded": self.discarded, "image_misses": self.image_misses,
                "qdepth": len(self.queue),
                "reasons": dict((FS_NAMES[k], v)
                                for k, v in sorted(self.reasons.items())),
                "redirects": dict(sorted(self.redirects.items()))}
