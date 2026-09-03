"""Remote side: run one module as a child process speaking the wire protocol.

    python3 -m camsim.hosted camsim.modules.demo:Stage '{"name":"s0"}'

The module class is unmodified -- it sees a bus shim with the same
module-facing API (``signal``/``pub``/``get``/``fired``/``cycle``) and the same
visibility rules, so code written for in-process use runs out-of-process with
no changes.  That equivalence is the point; if a module needs to know which
side of a pipe it is on, the protocol has failed.

stdout is the frame stream and nothing else: it is dup'd away at startup and
``sys.stdout`` is repointed at stderr, so a stray ``print`` in a module is a
debug line rather than a protocol corruption.
"""

import importlib
import json
import os
import sys
import traceback

from . import wire


class Shim(object):
    """The child-side bus: same surface as ``Bus``, no clock of its own."""

    def __init__(self, module):
        self.cycle = 0
        self.module = module
        self.strict = True
        self._val = {}
        self._woke = frozenset()
        self._sfired = frozenset()
        self._cyc = -1
        self._phase = "idle"
        self._stage = []
        self._pending = []
        self._wake = False
        self._owned = set()
        self._subs = set()

    def bind(self, publishes, subscribes, contributes=()):
        for s in publishes:
            self._owned.add(s.name)
            self._val[s.name] = s.default
        self._owned.update(contributes)   # merged signals it drives but owns not
        self._subs = set(subscribes)

    def signal(self, name):
        if name not in self._owned and name not in self._subs:
            raise RuntimeError("%s: %r is neither published nor subscribed"
                               % (self.module.name, name))
        return name

    def pub(self, sig, value):
        name = sig if isinstance(sig, str) else sig.name
        if name not in self._owned:
            raise RuntimeError("%s published %r, which it does not drive"
                               % (self.module.name, name))
        self._stage.append((name, value))
        self._pending.append((name, value))

    def get(self, sig):
        name = sig if isinstance(sig, str) else sig.name
        if name not in self._owned and name not in self._subs:
            raise RuntimeError("%s read %r without subscribing to it"
                               % (self.module.name, name))
        return self._val.get(name)

    def fired(self, sig):
        """Asserted this cycle -- the settled question, as on the host."""
        return (sig if isinstance(sig, str) else sig.name) in self._sfired

    def woke_on(self, sig):
        return (sig if isinstance(sig, str) else sig.name) in self._woke

    def wake_next(self, module=None):
        self._wake = True

    def resetting(self, module=None):
        rn = self.module.reset_n
        return bool(rn) and not self._val.get(rn)

    def depth_of(self, sig):
        return 0            # timing is the host's bookkeeping

    # -- driven by the message loop ---------------------------------------
    def arrive(self, cycle, msg, phase="settle"):
        self._cyc = cycle
        self._phase = phase
        self.cycle = cycle
        # publishes made in the previous round become visible now, exactly as
        # the host's delta boundary would have made them visible.
        for name, value in self._pending:
            self._val[name] = value
        self._pending = []
        self._val.update(msg.get("vals") or {})
        self._woke = frozenset(msg.get("woke") or ())
        self._sfired = frozenset(msg.get("sfired") or ())

    def drain(self):
        out, self._stage = self._stage, []
        wake, self._wake = self._wake, False
        return out, wake


def load(spec):
    modname, _, clsname = spec.partition(":")
    if not clsname:
        raise SystemExit("module spec must be pkg.mod:Class, got %r" % spec)
    return getattr(importlib.import_module(modname), clsname)


def serve(module, rd=None, wr=None):
    """Message loop for one module.  Returns when the host sends FINISH."""
    if rd is None:
        rd = os.fdopen(os.dup(0), "rb", 0)
        sys.stdin = open(os.devnull)
    if wr is None:
        wr = os.fdopen(os.dup(1), "wb", 0)
        os.close(1)
        os.dup2(2, 1)
        sys.stdout = sys.stderr

    link = wire.Framer(rd, wr, "pickle")
    hello = link.expect(wire.HELLO)
    if hello.get("proto") != wire.PROTO:
        link.send(wire.FAULT, where="hello",
                  error="proto %r != %r" % (hello.get("proto"), wire.PROTO))
        return 2
    link.codec = wire.Codec(hello.get("codec") or "pickle")

    pubs = module.declared_publishes()
    subs = module.declared_subscribes()
    shim = Shim(module)
    shim.bind(pubs, subs, module.declared_contributes())
    link.send(wire.MANIFEST, name=module.name,
              publishes=[s.spec() for s in pubs], subscribes=list(subs),
              always_async=bool(module.always_async),
              clock=module.clock, reset_n=module.reset_n,
              contributes=list(module.declared_contributes()))

    while True:
        msg = link.recv()
        if msg is None:
            return 0
        k = msg["k"]
        try:
            if k == wire.BUILD:
                shim.arrive(0, {}, "build")
                module.build(shim)
            elif k == wire.DELTA:
                shim.arrive(msg["cycle"], msg, "settle")
                module.settle(shim)
                module.settle_flush(shim)
            elif k == wire.TICK:
                shim.arrive(msg["cycle"], msg, "tick")
                module.tick(shim)
                module.tick_flush(shim)
            elif k == wire.FINISH:
                module.finish(shim)
                link.send(wire.REPORT, report=module.report())
                return 0
            else:
                link.send(wire.FAULT, where=k, error="unknown message")
                return 2
        except Exception:
            link.send(wire.FAULT, where=k, error=traceback.format_exc())
            return 2
        pubs, wake = shim.drain()
        link.send(wire.PUB, pubs=pubs, wake=wake)


def main(argv):
    if not argv:
        raise SystemExit("usage: python3 -m camsim.hosted pkg.mod:Class [kwargs-json]")
    cls = load(argv[0])
    kw = json.loads(argv[1]) if len(argv) > 1 else {}
    return serve(cls(**kw))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
