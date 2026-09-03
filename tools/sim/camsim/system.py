"""Several buses, stepped together.

The single-threaded scheduler steps each bus once per system step.  Because
every crossing is registered and ``Import`` only takes tags older than its own
step, the order buses are stepped in cannot change the result -- the same
property the delta loop gives inside one bus.

A threaded scheduler drops in here: one thread per bus, ``Channel(threaded=
True)`` between them, the per-step token acting as the barrier.  See the note
in ``link.py`` about what that does and does not buy under a GIL.
"""


class System(object):
    """Several buses and the one clock they all run on.

    The clock unit is shared, not replicated: ``add`` puts a port of the *same*
    ``Clock`` on each bus, so every bus sees the same edge, the same reset, and
    the same decision about whether to advance.  Buses with their own clocks
    could drift apart, which is not a machine."""

    def __init__(self, *buses, **kw):
        self.clock = kw.pop("clock", None)
        if kw:
            raise TypeError("unexpected: %s" % ", ".join(sorted(kw)))
        self.buses = []
        self.step_count = 0
        for b in buses:
            self.add(b)

    def add(self, bus):
        self.buses.append(bus)
        if self.clock is not None:
            bus.add(self.clock.port(bus.name + ".clk"))
        return bus

    def elaborate(self):
        for b in self.buses:
            if not b._elaborated:
                b.elaborate()
        return self

    @property
    def warnings(self):
        return ["[%s] %s" % (b.name, w) for b in self.buses for w in b.warnings]

    def step(self):
        for b in self.buses:
            b.step()
        self.step_count += 1

    def wave(self, path, patterns=("*",), **kw):
        """Add a Wave module to every bus, all sharing one file.  The buses
        are on the same clock unit, so they belong on the same time axis."""
        from .wave import VCDWriter, Wave
        w = VCDWriter(path, **kw)
        for b in self.buses:
            b.add(Wave(w, patterns, name="wave." + b.name))
        self._writer = w
        return w

    def finish_wave(self):
        w = getattr(self, "_writer", None)
        if w is not None:
            w.close()

    @property
    def time(self):
        """Clock edges issued, which is not the step count once anything has
        withheld ``sys.done``."""
        return self.clock.time if self.clock else self.step_count

    def run(self, steps=None, until=None):
        n = 0
        while True:
            if steps is not None and n >= steps:
                break
            if until is not None and until(self):
                break
            self.step()
            n += 1
        return n

    def finish(self):
        rep = {}
        for b in self.buses:
            for k, v in b.finish().items():
                rep["%s/%s" % (b.name, k)] = v
        w = getattr(self, "_writer", None)
        if w is not None:
            w.close()
            rep["wave"] = w.report()
        return rep
