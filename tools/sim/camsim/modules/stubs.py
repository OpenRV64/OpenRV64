"""Stand-ins for units that do not exist yet.

Every one of these is a module the bus cannot distinguish from the real thing,
which is what lets a unit be brought up and measured before the units around
it are written.  ``IdealGate`` is the ``casim.frontend.IdealGate`` cutoff --
a backend that never backpressures -- and running fetch against it is the
frontend-only question: how fast can fetch supply, with nothing in the way.
"""

from ..module import Module, out, ASYNC, REG, LEVEL, PULSE


class IdealGate(Module):
    """Accept every candidate offered, every cycle.  No backpressure."""

    name = "gate"
    publishes = [out("fetch.taken", ASYNC, LEVEL, 0,
                     doc="candidates the gate consumed this cycle")]
    subscribes = ["fetch.cands"]

    def __init__(self, width=None, name=None):
        self.width = width          # None: take everything offered
        Module.__init__(self, name)

    def build(self, bus):
        self.S_TAKEN = bus.signal("fetch.taken")
        self.S_CANDS = bus.signal("fetch.cands")
        self.admitted = []
        self.count = 0

    def settle(self, bus):
        cands = bus.get(self.S_CANDS)
        n = len(cands) if cands else 0
        if self.width is not None and n > self.width:
            n = self.width
        bus.pub(self.S_TAKEN, n)

    def tick(self, bus):
        if bus.resetting():
            del self.admitted[:]
            self.count = 0
            return
        cands = bus.get(self.S_CANDS)
        n = bus.get(self.S_TAKEN) or 0
        if n:
            for c in cands[:n]:
                c.admit_cycle = bus.cycle
            self.admitted.extend(cands[:n])
            self.count += n

    def report(self):
        return {"admitted": self.count}


class IdealBackend(Module):
    """A backend that never backpressures: the frontend-only cutoff.

    ``casim.frontend.IdealGate``, as a module.  Swap it for one that publishes
    real credits and the frontend sees the real machine, with nothing in the
    frontend changing."""

    name = "backend"
    publishes = [out("backend.credits", ASYNC, LEVEL, 0,
                     doc="candidates the backend will take this cycle")]
    always_async = True

    def __init__(self, width=3, name=None):
        self.width = width
        Module.__init__(self, name)

    def build(self, bus):
        self.S = bus.signal("backend.credits")

    def settle(self, bus):
        bus.pub(self.S, 0 if bus.resetting() else self.width)


class NoStash(Module):
    """Drive the stash line and never assert it: fetch with no dispatch."""

    name = "nostash"
    publishes = [out("dispatch.stash", ASYNC, PULSE, None)]
    always_async = True

    def build(self, bus):
        self.S = bus.signal("dispatch.stash")

    def settle(self, bus):
        bus.pub(self.S, None)


class NoRedirect(Module):
    """Drive the redirect line and never assert it.

    A tie-off is a module like any other, and having one means ``redirect``
    has a driver -- so elaboration checks the wiring instead of silently
    accepting a dangling input."""

    name = "noredirect"
    publishes = [out("redirect", REG, PULSE, None,
                     doc="never asserted: nothing resolves yet")]
