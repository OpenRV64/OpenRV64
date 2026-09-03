"""Resolve: hold armed redirects until they are due, and pick the winner.

``casim.frontend`` phase 1.  Dispatch says *what* redirect a transfer raises
and how long it takes; this unit says *when* it lands and which one wins when
several are due at once.

The winner is the oldest owner.  An older branch resolving supersedes a younger
branch's prediction, and everything the loser would have done is dropped along
with it -- that is the recovery the hardware performs, and getting the
arbitration wrong shows up as a frontend that redirects to a path it has
already left.

``redirect`` is REG on purpose.  A resolver deciding at the edge and a fetch
flushing at the next one is a flop between two units, so the two are separable:
the resolver can sit on another bus, another thread or another process without
changing a cycle.  Fetch's flush is same-cycle with its own presentation, which
is why *that* boundary is async and this one is not.
"""

from ..module import Module, out, ASYNC, REG, LEVEL, PULSE
from .fetch import Redirect


class _Armed(object):
    __slots__ = ("cycle", "owner", "target", "kind", "to_correct_path")

    def __init__(self, cycle, s):
        self.cycle = cycle
        self.owner = s.owner
        self.target = s.target
        self.kind = s.kind
        self.to_correct_path = s.to_correct_path


class Resolve(Module):
    name = "resolve"
    publishes = [
        out("redirect", REG, PULSE, None, doc="the redirect landing next cycle"),
        out("resolve.pending", REG, LEVEL, 0, doc="redirects armed and waiting"),
    ]
    subscribes = ["dispatch.sched"]

    def __init__(self, name=None):
        Module.__init__(self, name)

    def build(self, bus):
        self.S_SCHED = bus.signal("dispatch.sched")
        self.S_REDIR = bus.signal("redirect")
        self.S_PEND = bus.signal("resolve.pending")
        self._reset_state()

    def _reset_state(self):
        self.pending = []
        self.landed = 0
        self.kinds = {}

    def tick(self, bus):
        if bus.resetting():
            self._reset_state()
            bus.pub(self.S_PEND, 0)
            return

        for s in (bus.get(self.S_SCHED) or ()):
            self.pending.append(_Armed(bus.cycle + s.delay, s))

        # `redirect` is a flop, so what is armed for the next cycle is decided
        # now.  casim lands a redirect when its cycle has arrived; the same
        # test one cycle early puts it on the wire for exactly that cycle.
        when = bus.cycle + 1
        due = [r for r in self.pending if r.cycle <= when]
        if due:
            win = min(due, key=lambda r: r.owner)
            # Everything younger than the winner is superseded, due or not.
            self.pending = [r for r in self.pending
                            if r.cycle > when and r.owner <= win.owner]
            bus.pub(self.S_REDIR, Redirect(win.owner, win.target, win.kind,
                                           win.to_correct_path))
            self.landed += 1
            self.kinds[win.kind] = self.kinds.get(win.kind, 0) + 1
        bus.pub(self.S_PEND, len(self.pending))

    def report(self):
        return {"landed": self.landed, "pending": len(self.pending),
                "kinds": dict(sorted(self.kinds.items()))}
