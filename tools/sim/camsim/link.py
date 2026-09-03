"""Crossing between buses.

A bus is a scope: its own signal namespace, its own clock, its own settling.
Several of them let you isolate a subsystem so its traffic does not wake or
clutter the rest, give a block its own clock domain, and -- with the same
seam -- put a bus on another thread or in another process.

**A crossing is always registered.** A ASYNC signal spanning two buses would
force their delta loops into lockstep, which defeats the isolation and makes
threading impossible; a REG crossing costs one step of latency and nothing
else.  This is the third time the same rule has paid: registering the boundary
is what makes it cheap to distribute, across a bus, a thread, a process, or a
die.

    ch = Channel([out("fe.cands", REG, PULSE)])
    core.add(Export(ch))        # drives them on `core`
    mem.add(Import(ch))         # republishes them on `mem`, one step later

Determinism does not depend on which bus steps first: ``Export`` tags what it
sends with its step number and ``Import`` consumes only tags strictly older
than its own step.  That is the same guarantee the delta loop gives inside one
bus, one level up.

On threading: ``Channel(threaded=True)`` is a blocking queue and ``Export``
sends every step, empty or not, so the token doubles as the step barrier.
Worth being blunt about the payoff -- CPython and PyPy both hold a GIL, so
threads buy isolation and I/O overlap, not throughput.  The boundary that
actually parallelises is the process one in ``remote.py``, and it is the same
boundary.
"""

from .module import Module, Signal, REG, out


class Channel(object):
    """One-way carrier of registered signal values between two buses."""

    def __init__(self, specs, name="channel", threaded=False, maxsize=0):
        self.name = name
        self.specs = [s if isinstance(s, Signal) else Signal.from_spec(s)
                      for s in specs]
        for s in self.specs:
            if s.kind != REG:
                # The specs describe what Import *publishes*.  A ASYNC source
                # is fine -- Export samples it settled and Import republishes
                # it registered, which is what a synchroniser is.  What cannot
                # exist is a crossing that arrives asynchronously.
                raise ValueError(
                    "%s: %s must be declared REG; a crossing arrives registered"
                    % (name, s.name))
        self.threaded = threaded
        if threaded:
            try:
                import queue
            except ImportError:                     # pragma: no cover
                import Queue as queue
            self._q = queue.Queue(maxsize)
        else:
            from collections import deque
            self._q = deque()
        self._peek = None
        self.sent = 0

    def send(self, step, items):
        self.sent += 1
        if self.threaded:
            self._q.put((step, items))
        else:
            self._q.append((step, items))

    def take(self, before):
        """Everything tagged strictly older than ``before``."""
        out = []
        while True:
            if self._peek is None:
                if self.threaded:
                    if not out and not self._q.qsize():
                        self._peek = self._q.get()      # block for the token
                    elif self._q.qsize():
                        self._peek = self._q.get()
                    else:
                        break
                else:
                    if not self._q:
                        break
                    self._peek = self._q.popleft()
            step, items = self._peek
            if step >= before:
                break
            self._peek = None
            out.extend(items)
        return out


class Export(Module):
    """Send this bus's settled values into a channel, once per step."""

    def __init__(self, channel, src=None, name=None):
        self.channel = channel
        self._src = dict(src or {})     # destination name -> local name
        self.subscribes = [self._src.get(s.name, s.name) for s in channel.specs]
        Module.__init__(self, name or ("export_" + channel.name))

    def build(self, bus):
        self._watch = [(bus.signal(self._src.get(s.name, s.name)), s.name)
                       for s in self.channel.specs]

    def tick(self, bus):
        items = [(nm, bus.get(h)) for h, nm in self._watch if bus.fired(h)]
        self.channel.send(bus.cycle, items)      # every step: also the token


class Import(Module):
    """Republish a channel's contents on this bus, one step later."""

    def __init__(self, channel, name=None):
        self.channel = channel
        self.publishes = [Signal(s.name, s.kind, s.mode, s.default, s.doc,
                                 s.merge) for s in channel.specs]
        Module.__init__(self, name or ("import_" + channel.name))

    def build(self, bus):
        self._h = {s.name: bus.signal(s.name) for s in self.publishes}
        self.received = 0

    def tick(self, bus):
        for nm, val in self.channel.take(bus.cycle):
            bus.pub(self._h[nm], val)
            self.received += 1

    def report(self):
        return {"received": self.received}
