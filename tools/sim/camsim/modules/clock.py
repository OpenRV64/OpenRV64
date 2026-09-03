"""The clock and reset source: one unit, present on every bus.

``Clock`` is not a module.  It is the shared timebase, and it puts a
``ClockPort`` on each bus that needs it -- the *same* clock unit on all buses,
so a split model has one time, one reset, and one place that decides whether
the machine advances.  Per-bus clocks would let two halves of a machine drift,
which is not a thing you can build.

    clk = Clock(reset_steps=2)
    core.add(clk.port())
    side.add(clk.port())        # same unit, second bus

``clk`` is a REG PULSE meaning *your domain edges this step*, not a level that
toggles.  One step is one edge opportunity rather than half a period, so the
single-domain case costs nothing and a divided domain is a clock that pulses on
some steps and not others.

``rst_n`` is a REG LEVEL, low while held.  Modules read it in ``tick`` --
``if bus.resetting(): ...`` -- which is the ``always_ff`` idiom, and the reason
reset is not a lifecycle callback: a callback runs once and cannot model a
machine that resets twice or one whose halves release at different times.

Saying "I'm done"
-----------------
``sys.done`` is a merged (wired-AND) signal on every bus, True unless somebody
says otherwise.  Any module can publish False to withhold it, and **the clock
will not pulse again until every bus reports done**:

    class Slow(Module):
        contributes = ["sys.done"]
        def settle(self, bus):
            bus.pub("sys.done", self.reply_arrived)

This is what makes a module on another thread, another process, or another bus
safe: the clock does not run ahead of work that has not landed.  Note where the
decision happens -- the port drives ``clk`` from a *pre-step* hook, not from
its own tick, so the call is made after every bus has finished the previous
step rather than in the middle of it.  A stall therefore costs exactly one
step, and no bus can observe a different clock than another.

The obvious deadlock -- a module withholding ``done`` while needing a clock
edge to make progress -- is real, and the rule is that a withholder must be
driven by something other than the clock it is stalling (a reply, a queue, a
free-running module).  ``stall_limit`` catches the rest rather than hanging.
"""

from ..module import Module, out, ASYNC, REG, LEVEL, PULSE

DONE = "sys.done"


class Clock(object):
    """The shared timebase.  One per system, however many buses there are."""

    def __init__(self, reset_steps=1, reset_windows=None, stall_limit=1000,
                 clk="clk", rst="rst_n", done=DONE):
        self.clk_name = clk
        self.rst_name = rst
        self.done_name = done
        self.stall_limit = stall_limit
        # Held low for [lo, hi).  More than one window is a warm reset, the
        # thing a build-time callback structurally cannot express.
        self.windows = list(reset_windows or ([(0, reset_steps)]
                                              if reset_steps > 0 else []))
        self.ports = []
        self.time = 0             # edges issued: the machine's own cycle count
        self.edge = 0             # index of the edge being issued this step
        self.step = -1            # bus steps taken, stalls included
        self.stalled = 0
        self.total_stalled = 0
        self._pulse = True        # does this step get an edge?
        self._acks = {}
        self._acked_step = -1

    def port(self, name=None):
        p = ClockPort(self, name or ("clkport%d" % len(self.ports)))
        self.ports.append(p)
        return p

    def held(self, step):
        return any(lo <= step < hi for lo, hi in self.windows)

    # -- called by the ports ------------------------------------------------
    def ack(self, port, done, step):
        """A bus reports whether it finished this step."""
        if step != self._acked_step:
            self._acked_step = step
            self._acks = {}
        self._acks[id(port)] = done

    def decide(self, step):
        """Pulse this step?  Answered once, from the acks of the step before,
        so every port gets the same answer whatever order they run in."""
        if step != self.step:
            self.step = step
            all_done = all(self._acks.values()) if self._acks else True
            self._pulse = all_done
            if all_done:
                self.stalled = 0
            else:
                self.stalled += 1
                self.total_stalled += 1
                if self.stall_limit and self.stalled > self.stall_limit:
                    raise RuntimeError(
                        "clock stalled %d steps at time %d: sys.done never came "
                        "back. A module withholding done must be driven by "
                        "something other than the clock it is stalling."
                        % (self.stalled, self.time))
            if self._pulse:
                self.edge = self.time
                self.time += 1
        return self._pulse

    def reset_held(self):
        """Reset tracks edges, not steps: a stalled step is not a cycle, so
        holding reset for two cycles must not be shortened by a stall."""
        return self.held(self.edge)

    def report(self):
        return {"time": self.time, "steps": self.step,
                "stalled_steps": self.total_stalled}


class ClockPort(Module):
    """One bus's view of the shared clock.  Free-running by construction: it
    is the thing that produces edges, so it cannot wait for one."""

    clock = None
    reset_n = None

    def __init__(self, clock, name):
        self.clk = clock
        self.publishes = [
            out(clock.clk_name, REG, PULSE, False, doc="this domain edges now"),
            out(clock.rst_name, REG, LEVEL, False, doc="low while held in reset"),
            out(clock.done_name, ASYNC, LEVEL, True, merge="and",
                doc="every module says it finished this step"),
        ]
        self.subscribes = [clock.done_name]
        Module.__init__(self, name)

    def build(self, bus):
        self.S_CLK = bus.signal(self.clk.clk_name)
        self.S_RST = bus.signal(self.clk.rst_name)
        self.S_DONE = bus.signal(self.clk.done_name)
        bus.pre_step(self, self._drive)

    def _drive(self, bus):
        # Before the edge, so the decision uses the completed previous step.
        if self.clk.decide(bus.cycle):
            bus.pub(self.S_CLK, True)
        bus.pub(self.S_RST, not self.clk.reset_held())

    def tick(self, bus):
        self.clk.ack(self, bus.get(self.S_DONE), bus.cycle)

    def report(self):
        return self.clk.report() if self.clk.ports[0] is self else None


class ClockDiv(Module):
    """A slower domain: pass one edge in ``ratio`` through.  Modules in it
    declare ``clock = "<name>"`` and tick only on the steps it pulses."""

    def __init__(self, ratio, src="clk", dst=None, name=None, rst="rst_n"):
        dst = dst or (src + "_div%d" % ratio)
        self.ratio = ratio
        self.publishes = [out(dst, REG, PULSE, False,
                              doc="%s divided by %d" % (src, ratio))]
        self.subscribes = [src]
        self._dst = dst
        Module.__init__(self, name or ("clkdiv_%d" % ratio), clock=src,
                        reset_n=rst)

    def build(self, bus):
        self.S_DST = bus.signal(self._dst)
        self.n = 0

    def tick(self, bus):
        if bus.resetting():
            self.n = 0
            return
        self.n += 1
        if self.n >= self.ratio:
            self.n = 0
            bus.pub(self.S_DST, True)


class ClockGate(Module):
    """Stop a domain when an enable is low.  A gated module costs nothing on
    the steps it does not tick, which is the point -- the cheapest way to model
    a block being idle is for it not to run."""

    def __init__(self, enable, src="clk", dst=None, name=None, rst="rst_n"):
        dst = dst or (src + "_g")
        self.publishes = [out(dst, REG, PULSE, False,
                              doc="%s gated by %s" % (src, enable))]
        self.subscribes = [src, enable]
        self._enable, self._dst = enable, dst
        Module.__init__(self, name or "clkgate", clock=src, reset_n=rst)

    def build(self, bus):
        self.S_DST = bus.signal(self._dst)
        self.S_EN = bus.signal(self._enable)
        self.gated_steps = 0

    def tick(self, bus):
        if bus.get(self.S_EN):
            bus.pub(self.S_DST, True)
        else:
            self.gated_steps += 1

    def report(self):
        return {"gated_steps": self.gated_steps}
