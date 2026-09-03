"""Signals and the module interface.

A module declares what it drives and what it listens to; the bus wires them.
Nothing else about a module is visible to the simulator, which is what makes
one swappable for another (a real model, a replayer, an ideal stub, a process
on the far end of a pipe).

Signal axes
-----------
**kind** -- when a publish becomes visible:

  ``ASYNC`` same cycle, at the next delta.  No flop between the two modules.
  ``REG``   next cycle, at the edge.  A flop between the two modules.

``ASYNC`` is *not* async logic.  Real async logic -- the gates,
the comparator, the priority encoder -- lives inside a module, as ordinary
code, and the bus never sees it.  What crosses the bus is only the question of
*when* a value becomes visible: this cycle, or next.  A module may be one gate
or four hundred; from the bus it is one hop either way, which is why a module
declares ``logic_depth`` if it wants the timing numbers to mean anything.

**mode** -- what a publish means:

  ``LEVEL`` the signal holds its value; it *fires* only when the value
            changes, so a steady value wakes nobody.
  ``PULSE`` a strobe; it auto-clears to ``default`` at the next edge, so a
            stale valid cannot be read next cycle -- and so a strobe repeated
            on consecutive cycles fires on each of them, while a re-publish of
            the same value inside one cycle does not.

Publish rules follow the hardware:

  * ``settle()`` may publish ASYNC (a wire it drives) or REG (the D input of a
    flop it owns).
  * ``tick()`` may publish REG only.  Publishing ASYNC at the edge is an error:
    the cycle has already settled and nothing would see it.

Payloads need value equality
----------------------------
The bus decides a signal fired by comparing the published value to the visible
one.  ``settle`` is re-run whenever an input moves, and a module that builds its
payload fresh each evaluation -- a list of newly allocated records, say -- will
publish an object that is *equal in meaning* but unequal by identity.  That
reads as a change: a spurious fire, an extra wake on everything downstream, and
a async depth reported one level deeper than the signal really settles
at.  Give payload classes ``__eq__``/``__hash__``, or reuse the objects.

Clock and reset
---------------
Every module names the clock it runs on (``clock``, default ``"clk"``) and the
reset that holds it (``reset_n``, default ``"rst_n"``).  Both are subscribed
implicitly, and ``tick()`` is called only on the steps where the module's clock
actually edges -- so a gated or divided clock costs nothing to model and a
module in another domain simply ticks less often.  ``clock = None`` means
free-running: ticked every step, which is what the clock source itself needs.

Reset is a signal, not a callback.  ``build()`` is the once-only python-side
construction (intern signal handles, size arrays); architectural reset is
``if bus.resetting(): ...`` at the top of ``tick``, exactly as an
``always_ff`` writes it.  Conflating the two is how a model ends up unable to
reset twice.
"""

ASYNC = "async"        # arrives this cycle, no flop between the two modules
REG = "reg"            # arrives next cycle: a flop between the two modules
COMB = ASYNC           # old name, kept so existing graphs keep elaborating
LEVEL = "level"
PULSE = "pulse"

CLK = "clk"
RST_N = "rst_n"

_MISSING = object()


MERGES = {
    "and": lambda vs: all(vs),
    "or": lambda vs: any(vs),
    "sum": lambda vs: sum(vs),
    "max": lambda vs: max(vs),
    "min": lambda vs: min(vs),
}


class Signal(object):
    __slots__ = ("name", "kind", "mode", "default", "doc", "publisher", "idx",
                 "subs", "merge", "contributors")

    def __init__(self, name, kind=REG, mode=LEVEL, default=None, doc="",
                 merge=None):
        if kind not in (ASYNC, REG):
            raise ValueError("signal %s: bad kind %r" % (name, kind))
        if mode not in (LEVEL, PULSE):
            raise ValueError("signal %s: bad mode %r" % (name, mode))
        self.name = name
        self.kind = kind
        self.mode = mode
        self.default = default
        self.doc = doc
        if merge is not None and merge not in MERGES:
            raise ValueError("signal %s: bad merge %r" % (name, merge))
        self.merge = merge
        self.publisher = None
        self.contributors = []
        self.idx = -1
        self.subs = []

    def spec(self):
        return {"sig": self.name, "kind": self.kind, "mode": self.mode,
                "default": self.default, "doc": self.doc, "merge": self.merge}

    @staticmethod
    def from_spec(d):
        return Signal(d["sig"], d.get("kind", REG), d.get("mode", LEVEL),
                      d.get("default"), d.get("doc", ""), d.get("merge"))

    def __repr__(self):
        return "<%s %s/%s>" % (self.name, self.kind, self.mode)


def out(name, kind=REG, mode=LEVEL, default=None, doc="", merge=None):
    """Declare a published signal.  Sugar for use in a ``publishes`` list.

    ``merge`` makes it a wired signal that many modules drive: the value is the
    reduction (``and``/``or``/``sum``/``max``/``min``) over each contributor's
    latest contribution.  One module declares it; the rest name it in
    ``contributes``.  This is the one exception to the single-driver rule, and
    it exists because ``sys.done`` genuinely has many drivers."""
    return Signal(name, kind, mode, default, doc, merge)


class Module(object):
    """Base class for an in-process module.

    Subclasses set ``publishes`` (list of Signal) and ``subscribes`` (list of
    names, ``prefix.*`` globs allowed), then implement any of:

      ``build(bus)``  once at elaboration; intern handles, size state
      ``settle(bus)``   woken at each delta where a subscribed signal fired
      ``tick(bus)``   on every edge of this module's clock, after settling
      ``report()``    whatever the run should print or collect

    ``always_async`` additionally wakes the module at delta 1 of every step.
    Rarely needed now that the clock does it: it is for a module declared
    ``clock = None`` whose async output still depends on internal
    state.
    """

    name = None
    logic_depth = 1     # roughly how many levels of logic this unit is, for
                        # the depth estimate.  1 is "unweighted, one hop".
    publishes = ()
    subscribes = ()
    contributes = ()        # merged signals this module drives but does not own
    clock = CLK
    reset_n = RST_N
    always_async = False

    def __init__(self, name=None, rename=None, clock=_MISSING,
                 reset_n=_MISSING):
        if name:
            self.name = name
        if self.name is None:
            self.name = type(self).__name__.lower()
        if clock is not _MISSING:
            self.clock = clock
        if reset_n is not _MISSING:
            self.reset_n = reset_n
        self._rename = dict(rename or {})
        self._sub_idx = ()
        self._clk_idx = None
        self._rst_idx = None

    # -- wiring -----------------------------------------------------------
    def declared_publishes(self):
        outs = []
        for s in self.publishes:
            nm = self._rename.get(s.name, s.name)
            outs.append(Signal(nm, s.kind, s.mode, s.default, s.doc, s.merge))
        return outs

    def declared_contributes(self):
        return [self._rename.get(n, n) for n in self.contributes]

    def declared_subscribes(self):
        subs = [self._rename.get(n, n) for n in self.subscribes]
        for implicit in (self.clock, self.reset_n):
            if implicit and implicit not in subs:
                subs.append(implicit)
        return subs

    # -- lifecycle (all optional) -----------------------------------------
    def build(self, bus):
        """Once, at elaboration.  Not a hardware reset -- see ``resetting``."""
        pass

    def settle(self, bus):
        pass

    def settle_flush(self, bus):
        """Second wake pass.  In-process modules do everything in ``settle``;
        a remote module sends in ``settle`` and publishes the reply here, so
        several remotes overlap instead of serialising on round trips."""
        pass

    def tick(self, bus):
        pass

    def tick_flush(self, bus):
        """Second edge pass, same reason as ``settle_flush``: a remote module
        sends its TICK and collects the reply here, so N remote processes
        compute their edge concurrently instead of one round trip each."""
        pass

    def finish(self, bus):
        pass

    def report(self):
        return None

    def __repr__(self):
        return "<%s %s>" % (type(self).__name__, self.name)
