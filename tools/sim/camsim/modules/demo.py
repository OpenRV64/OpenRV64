"""A three-module toy graph, here to exercise the protocol rather than model
anything: a source with async backpressure, a registered pipeline
stage, and a sink whose occupancy drives the ready line.

It is the smallest graph that shows all four signal behaviours at once --
ASYNC/REG and LEVEL/PULSE -- plus a backward-flowing ready that must *not*
close a async loop, plus a flop boundary resetting the depth count,
plus reset held as a signal rather than run as a callback.  The expected
settling order once out of reset is

    edge      clk, stage.item   (REG, depth 0)
    delta 1   sink.ready        (ASYNC, depth 1)  -- from the occupancy flop
    delta 2   src.item          (ASYNC, depth 2)  -- gated by ready
    delta 3   Stage wakes, publishes stage.item for the next edge

``Stage`` is the piece meant to be swapped: run it in-process, hand it to
``remote.hosted('camsim.modules.demo:Stage')``, or put it on its own bus behind
a ``Channel``, and the run is identical.
"""

from ..module import Module, out, ASYNC, REG, LEVEL, PULSE


class Producer(Module):
    """Offers one item per step while the downstream ready line is up."""

    name = "producer"
    publishes = [out("src.item", ASYNC, PULSE, doc="one item offered this step"),
                 out("src.done", REG, LEVEL, False)]
    subscribes = ["sink.ready"]

    def __init__(self, count=8, name=None):
        self.count = count
        Module.__init__(self, name)

    def build(self, bus):
        self.S_ITEM = bus.signal("src.item")
        self.S_DONE = bus.signal("src.done")
        self.S_RDY = bus.signal("sink.ready")
        self.next_id = 0

    def settle(self, bus):
        # Drive the offer every evaluation, idle value included: `ready` can
        # fall later in the same step and the offer has to come back off.
        if self.next_id < self.count and bus.get(self.S_RDY) \
                and not bus.resetting():
            bus.pub(self.S_ITEM, self.next_id)
        else:
            bus.pub(self.S_ITEM, None)

    def tick(self, bus):
        if bus.resetting():
            self.next_id = 0
            return
        if bus.fired(self.S_ITEM):          # settled, not mid-settling
            self.next_id += 1
        if self.next_id >= self.count and not bus.get(self.S_DONE):
            bus.pub(self.S_DONE, True)

    def report(self):
        return {"sent": self.next_id}


class Stage(Module):
    """One step of latency.  The swappable module in this demo."""

    name = "stage"
    publishes = [out("stage.item", REG, PULSE, doc="item, one step later")]
    subscribes = ["src.item"]

    def __init__(self, name=None, label=""):
        self.label = label
        Module.__init__(self, name)

    def build(self, bus):
        self.S_IN = bus.signal("src.item")
        self.S_OUT = bus.signal("stage.item")
        self.passed = 0

    def settle(self, bus):
        # A flop's D input is async; the publish lands next step.
        # Unconditional, so a withdrawn offer withdraws the capture too.
        bus.pub(self.S_OUT, None if bus.resetting() else bus.get(self.S_IN))

    def tick(self, bus):
        if bus.resetting():
            self.passed = 0
            return
        if bus.fired(self.S_IN):
            self.passed += 1

    def report(self):
        return {"passed": self.passed, "label": self.label}


class Sink(Module):
    """Holds up to ``depth`` items and retires one every ``rate`` steps.  Its
    ready line is async out of the occupancy flop, and deliberately
    does not depend on the item arriving this step -- that is what keeps
    ready/valid from closing a loop."""

    name = "sink"
    publishes = [out("sink.ready", ASYNC, LEVEL, False)]
    subscribes = ["stage.item"]

    def __init__(self, depth=2, rate=1, name=None):
        self.depth = depth
        self.rate = rate
        Module.__init__(self, name)

    def build(self, bus):
        self.S_IN = bus.signal("stage.item")
        self.S_RDY = bus.signal("sink.ready")
        self.occ = 0
        self.ticks = 0
        self.got = []

    def settle(self, bus):
        # Woken every step by the clock edge, so the ready line tracks its own
        # flop state with no `always_async` and no self-scheduled wake.
        bus.pub(self.S_RDY, self.occ < self.depth and not bus.resetting())

    def tick(self, bus):
        if bus.resetting():
            self.occ = self.ticks = 0
            del self.got[:]
            return
        if bus.fired(self.S_IN):
            self.occ += 1
            self.got.append(bus.get(self.S_IN))
        # Its own edges, not the bus's steps: with a stall or a divided clock
        # those are different numbers, and the flop only sees its own.
        self.ticks += 1
        if self.occ and self.ticks % self.rate == 0:
            self.occ -= 1

    def report(self):
        return {"received": len(self.got), "order": self.got}
