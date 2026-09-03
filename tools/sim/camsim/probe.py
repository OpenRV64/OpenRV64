"""Generic modules: record, replay, tie off, watch.

These are what make the decoupled runs fall out of the graph instead of being
special cases inside a model.  To run the frontend with no backend you replace
the backend with ``Const`` holding the admission gate open; to run the backend
with no frontend you replace the frontend with ``Replayer`` of a recorded
candidate stream.  Neither the frontend nor the backend module learns a new
mode flag, because from where they sit nothing changed.
"""

import pickle

from .module import Module, Signal, ASYNC, REG, LEVEL, PULSE, out

REC_MAGIC = "camsim-rec-1"


class Const(Module):
    """Hold signals at fixed values.  A tie-off, or an ideal stub.

        Const({"admit.ready": 3})          # gate never backpressures
    """

    clock = reset_n = None      # an observer is not part of the machine

    def __init__(self, values, kind=ASYNC, mode=LEVEL, name="const"):
        self.publishes = [Signal(k, kind, mode, v) for k, v in sorted(values.items())]
        self.always_async = (kind == ASYNC)
        self._values = dict(values)
        Module.__init__(self, name)

    def build(self, bus):
        self._h = [(bus.signal(k), v) for k, v in sorted(self._values.items())]
        if not self.always_async:
            for h, v in self._h:
                bus.pub(h, v)

    def settle(self, bus):
        for h, v in self._h:
            bus.pub(h, v)


class Recorder(Module):
    """Write every fire of the matched signals to a file.

    The header carries the signal declarations, so a ``Replayer`` of the file
    can stand in for the module that produced them without anyone declaring
    them twice."""

    clock = reset_n = None      # an observer is not part of the machine

    def __init__(self, path, patterns=("*",), name="recorder"):
        self.subscribes = list(patterns)
        self._path = path
        self._f = None
        self._n = 0
        Module.__init__(self, name)

    def build(self, bus):
        sigs = [bus.order[i] for i in self._sub_idx]
        self._f = open(self._path, "wb")
        pickle.dump({"magic": REC_MAGIC, "signals": [s.spec() for s in sigs]},
                    self._f, 4)
        self._watch = [(i, bus.order[i].name) for i in self._sub_idx]

    def settle(self, bus):
        rec = [(nm, bus._val[i]) for i, nm in self._watch if i in bus._fired]
        if rec:
            pickle.dump((bus.cycle, rec), self._f, 4)
            self._n += len(rec)

    def tick(self, bus):
        pass

    def finish(self, bus):
        if self._f:
            self._f.close()
            self._f = None

    def report(self):
        return {"path": self._path, "events": self._n}


class Replayer(Module):
    """Publish a recording back onto the bus, standing in for its producer.

    Caveat worth knowing: a recording keeps the cycle a signal fired, not the
    delta it settled at, so a replayed ASYNC signal is republished at the first
    delta of its cycle.  Cycle-level behaviour is exact; the settling order --
    and therefore the depth numbers -- is not, and a run with a Replayer in it
    should not be read for timing."""

    clock = reset_n = None      # an observer is not part of the machine

    always_async = True

    def __init__(self, path, only=None, name="replayer"):
        with open(path, "rb") as f:
            hdr = pickle.load(f)
        if hdr.get("magic") != REC_MAGIC:
            raise ValueError("%s is not a camsim recording" % path)
        specs = [Signal.from_spec(d) for d in hdr["signals"]]
        if only is not None:
            keep = set(only)
            specs = [s for s in specs if s.name in keep]
        self.publishes = specs
        self._names = set(s.name for s in specs)
        self._path = path
        self._by_cycle = {}
        with open(path, "rb") as f:
            pickle.load(f)
            while True:
                try:
                    cyc, rec = pickle.load(f)
                except EOFError:
                    break
                keep = [(n, v) for n, v in rec if n in self._names]
                if keep:
                    self._by_cycle.setdefault(cyc, []).extend(keep)
        self.last_cycle = max(self._by_cycle) if self._by_cycle else -1
        Module.__init__(self, name)

    def build(self, bus):
        self._h = {s.name: bus.signal(s.name) for s in self.publishes}
        self._reg = set(s.name for s in self.publishes if s.kind == REG)

    def settle(self, bus):
        for n, v in self._by_cycle.get(bus.cycle, ()):
            if n not in self._reg:
                bus.pub(self._h[n], v)

    def tick(self, bus):
        for n, v in self._by_cycle.get(bus.cycle + 1, ()):
            if n in self._reg:
                bus.pub(self._h[n], v)

    def report(self):
        return {"path": self._path, "cycles": len(self._by_cycle),
                "last_cycle": self.last_cycle}


class Watch(Module):
    """Print every fire.  Debug only; noisy by construction."""

    clock = reset_n = None      # an observer is not part of the machine

    def __init__(self, patterns=("*",), out=None, name="watch"):
        self.subscribes = list(patterns)
        self._out = out
        Module.__init__(self, name)

    def build(self, bus):
        import sys
        self._w = self._out or sys.stderr

    def settle(self, bus):
        for i in self._sub_idx:
            if i in bus._fired:
                s = bus.order[i]
                self._w.write("  %6d.%-2d %-5s %-24s = %r\n"
                              % (bus.cycle, bus.delta - 1, s.kind, s.name,
                                 bus._val[i]))
