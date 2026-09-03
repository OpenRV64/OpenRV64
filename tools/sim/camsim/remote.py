"""Host side of an out-of-process module.

``RemoteModule`` is a ``Module`` like any other: it declares publishes and
subscribes (taken from the child's manifest at connect time) and the bus wires
it without knowing it is talking to a pipe.  Swapping a local model for a
remote one is a one-line change at graph-assembly time.

Cost model, which is the same one the hardware has: a ASYNC signal crossing the
process boundary costs a round trip *per delta*, because the host cannot
advance the settling round until the remote answers.  A module whose outputs
are all REG costs no stalls at all -- its TICK is sent to every remote first
and the replies collected afterwards, so N remote processes compute their edge
concurrently.  Registering the boundary is what makes it cheap to distribute,
exactly as registering a boundary is what lets you place two blocks far apart.
"""

import os
import subprocess
import sys

from . import wire
from .module import Module, Signal


class RemoteModule(Module):
    def __init__(self, argv, name=None, codec="pickle", env=None, cwd=None,
                 stderr=None):
        self._argv = list(argv)
        e = dict(os.environ)
        e.update(env or {})
        self._proc = subprocess.Popen(
            self._argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=stderr, env=e, cwd=cwd, bufsize=0)
        self._link = wire.Framer(self._proc.stdout, self._proc.stdin, codec)
        self._link.send(wire.HELLO, proto=wire.PROTO, codec=codec, name=name)
        man = self._link.expect(wire.MANIFEST)
        Module.__init__(self, name or man["name"])
        self._pub_specs = [Signal.from_spec(d) for d in man["publishes"]]
        self.subscribes = list(man["subscribes"])
        self.always_async = bool(man.get("always_async"))
        self.clock = man.get("clock")
        self.reset_n = man.get("reset_n")
        self.contributes = list(man.get("contributes") or ())
        self._inflight = None
        self._report = None
        self._sig = {}

    # -- wiring -------------------------------------------------------------
    def declared_publishes(self):
        return [Signal(s.name, s.kind, s.mode, s.default, s.doc, s.merge)
                for s in self._pub_specs]

    def build(self, bus):
        for s in self._pub_specs:
            self._sig[s.name] = bus.signal(s.name)
        self._link.send(wire.BUILD)
        self._apply(bus, self._link.expect(wire.PUB))

    # -- per-cycle ----------------------------------------------------------
    def settle(self, bus):
        # `vals` is the whole subscribed state, not just what moved.  A pulse
        # auto-clears at the edge without firing, so a remote told only about
        # fires would hold a stale strobe forever; and `fired` must mean the
        # settled question on both sides or local and remote diverge.
        self._link.send(wire.DELTA, cycle=bus.cycle,
                        vals=self._val_map(bus),
                        woke=self._names(bus, bus._fired),
                        sfired=self._settled_names(bus))
        self._inflight = wire.PUB

    def settle_flush(self, bus):
        self._drain(bus)

    def tick(self, bus):
        # The remote's last wake may predate the final delta, so the edge
        # message carries the settled value of everything it subscribes to
        # that fired this cycle.  Without it a remote flop would sample a
        # stale input and local/remote would diverge.
        self._link.send(wire.TICK, cycle=bus.cycle,
                        vals=self._val_map(bus),
                        woke=(),
                        sfired=self._settled_names(bus))
        self._inflight = wire.PUB

    def tick_flush(self, bus):
        self._drain(bus)

    def _drain(self, bus):
        if self._inflight is None:
            return
        kind, self._inflight = self._inflight, None
        self._apply(bus, self._link.expect(kind))

    def _val_map(self, bus):
        """Settled values of every subscribed signal, so a remote flop samples
        the same thing a local one would."""
        return dict((bus.order[i].name, bus._val[i]) for i in self._sub_idx)

    def _names(self, bus, which):
        return [bus.order[i].name for i in self._sub_idx if i in which]

    def _settled_names(self, bus):
        return [bus.order[i].name for i in self._sub_idx
                if bus._settled(bus.order[i])]

    def _apply(self, bus, msg):
        for name, value in msg.get("pubs", ()):
            bus.pub(self._sig.get(name) or bus.signal(name), value)
        if msg.get("wake"):
            bus.wake_next(self)

    # -- teardown -----------------------------------------------------------
    def finish(self, bus):
        try:
            self._link.send(wire.FINISH)
            self._report = self._link.expect(wire.REPORT).get("report")
        except (EOFError, RuntimeError, OSError):
            pass
        try:
            self._proc.stdin.close()
        except OSError:
            pass
        self._proc.wait(timeout=5)

    def report(self):
        return self._report


def hosted(module_spec, python=None, **kw):
    """Run ``pkg.mod:Class`` from this tree in a child process.

    ``hosted("camsim.modules.demo:Stage")`` is a drop-in for ``Stage()``."""
    py = python or sys.executable
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = dict(kw.pop("env", None) or {})
    env["PYTHONPATH"] = root + os.pathsep + os.environ.get("PYTHONPATH", "")
    return RemoteModule([py, "-m", "camsim.hosted", module_spec], env=env, **kw)
