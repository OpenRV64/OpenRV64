"""VCD output.

The interesting choice is the time axis.  A dump that puts one VCD timestamp
per step throws away the thing this model knows that a functional model does
not -- the delta each signal settled at.  So a step is a *block* of time and a
delta is a tick inside it:

    time = step * step_ticks + delta          (default 1000 ps per step)

At nanosecond zoom that reads as an ordinary cycle-by-cycle waveform.  Zoom
into a step and the settling order is laid out left to right: what resolves at
delta 1 is one level of logic from a flop, what resolves at delta 5 is five,
and the eye reads the critical path off the picture.  That is the same
measurement ``timing.report`` prints as numbers, drawn.

PULSE signals are rendered high for half a step.  The assertion is really for
the whole step -- the width is a display convention -- but it makes ``clk``
read as a 50% duty clock and a data strobe read as a strobe.  It also makes a
stall obvious: a step where ``sys.done`` was withheld is a step with no clock
pulse, a visible hole in the waveform.

``None`` is undefined, not the text "None": it renders as ``x`` whatever the
signal's type, so an unasserted pulse reads as blank.

Types come from each signal's ``default``, because that is the only static type
information a bus carries: a bool default gives a 1-bit wire, an int default a
64-bit vector, a float a real, and anything else a string var (GTKWave renders
those as labelled boxes, which is what you want for a payload like an
instruction).  Declaring ``out("rob.full", ASYNC, LEVEL, False)`` rather than
leaving the default at ``None`` is therefore worth doing for its own sake.

    bus.add(Wave("run.vcd", ["fe.*", "rob.*"]))     # or ["*"]

Several buses share one writer and one time axis, which is what you want for a
split model -- they are on the same clock unit, so they belong in one file.
"""

import sys

from .module import Module, LEVEL, PULSE

_ID_CHARS = "".join(chr(c) for c in range(33, 127))


def _ident(n):
    s = ""
    while True:
        s += _ID_CHARS[n % len(_ID_CHARS)]
        n //= len(_ID_CHARS)
        if not n:
            return s


def _kind_of(sig):
    d = sig.default
    if isinstance(d, bool):
        return "bit"
    if isinstance(d, int):
        return "vec"
    if isinstance(d, float):
        return "real"
    return "str"


def _sanitise(text, limit=96):
    out = []
    for ch in text[:limit]:
        out.append("_" if ch.isspace() else ch)
    if len(text) > limit:
        out.append("...")
    return "".join(out) or "_"


def _fmt(kind, value, ident):
    if kind == "bit":
        if value is True:
            return "1" + ident
        if value is False:
            return "0" + ident
        return "x" + ident
    if kind == "vec":
        if isinstance(value, bool) or not isinstance(value, int):
            return "bx " + ident
        v = value & ((1 << 64) - 1)
        return "b" + (bin(v)[2:] or "0") + " " + ident
    if kind == "real":
        if value is None:
            return "x" + ident
        try:
            return "r%.17g " % float(value) + ident
        except (TypeError, ValueError):
            return "x" + ident
    if value is None:
        # No value is not the text "None": a string var is declared one bit
        # wide, so the scalar undefined applies to it like any other.  A pulse
        # that is not asserted then reads as blank rather than as a word.
        return "x" + ident
    return "s" + _sanitise(repr(value)) + " " + ident


class VCDWriter(object):
    """One file, one time axis, however many buses feed it."""

    def __init__(self, path, timescale="1ps", step_ticks=1000, date=""):
        self.path = path
        self.timescale = timescale
        self.step_ticks = step_ticks
        self.date = date
        self._f = None
        self._vars = []          # (scope tuple, name, kind, ident)
        self._started = False
        self._pend = {}          # time -> [value-change strings]
        self._pend_step = -1
        self._last = {}          # ident -> last string written
        self._initial = {}       # ident -> (kind, value at time 0)
        self.changes = 0

    # -- declaration -------------------------------------------------------
    def declare(self, scope, name, kind, initial=None):
        ident = _ident(len(self._vars))
        self._vars.append((tuple(scope), name, kind, ident))
        self._initial[ident] = (kind, initial)
        return ident

    def _start(self):
        self._f = open(self.path, "w")
        w = self._f.write
        w("$date %s $end\n" % (self.date or "camsim"))
        w("$version camsim vcd $end\n")
        w("$timescale %s $end\n" % self.timescale)
        cur = ()
        for scope, name, kind, ident in sorted(self._vars):
            common = 0
            while common < len(cur) and common < len(scope) \
                    and cur[common] == scope[common]:
                common += 1
            for _ in range(len(cur) - common):
                w("$upscope $end\n")
            for part in scope[common:]:
                w("$scope module %s $end\n" % part)
            cur = scope
            if kind == "bit":
                w("$var wire 1 %s %s $end\n" % (ident, name))
            elif kind == "vec":
                w("$var wire 64 %s %s $end\n" % (ident, name))
            elif kind == "real":
                w("$var real 64 %s %s $end\n" % (ident, name))
            else:
                w("$var string 1 %s %s $end\n" % (ident, name))
        for _ in range(len(cur)):
            w("$upscope $end\n")
        w("$enddefinitions $end\n")
        # Time 0 state, so nothing reads as undefined before its first change.
        w("$dumpvars\n")
        for _, _, kind, ident in sorted(self._vars):
            line = _fmt(kind, self._initial[ident][1], ident)
            self._last[ident] = line
            w(line + "\n")
        w("$end\n")
        self._started = True

    # -- value changes -----------------------------------------------------
    def change(self, step, delta, ident, kind, value):
        if not self._started:
            self._start()
        if step != self._pend_step:
            self._flush()
            self._pend_step = step
        s = _fmt(kind, value, ident)
        if self._last.get(ident) == s:
            return
        self._last[ident] = s
        self._pend.setdefault(step * self.step_ticks + delta, []).append(s)
        self.changes += 1

    def _flush(self):
        if not self._pend:
            return
        w = self._f.write
        for t in sorted(self._pend):
            w("#%d\n" % t)
            for line in self._pend[t]:
                w(line + "\n")
        self._pend = {}

    def close(self):
        if not self._started:
            self._start()
        self._flush()
        if self._f:
            self._f.close()
            self._f = None

    def report(self):
        return {"path": self.path, "vars": len(self._vars),
                "changes": self.changes}


class Wave(Module):
    """Dump matched signals to VCD.

    An observer: it drives nothing, is not on the clock, and adding one cannot
    change a run.  It does raise the bus's ``wakes`` count -- it is a module
    and it gets woken -- but not ``deltas`` or ``publishes``, because a module
    that publishes nothing cannot cause a fire."""

    clock = reset_n = None

    def __init__(self, target, patterns=("*",), name="wave", strobes=True,
                 step_ticks=1000, scope=None):
        self.subscribes = list(patterns)
        self._w = target if isinstance(target, VCDWriter) \
            else VCDWriter(target, step_ticks=step_ticks)
        self._own = not isinstance(target, VCDWriter)
        self._strobes = strobes
        self._scope = scope
        Module.__init__(self, name)

    def build(self, bus):
        top = self._scope if self._scope is not None else bus.name
        self._watch = []          # (idx, ident, kind)
        self._pulses = []         # (idx, ident, kind, default, strobe ident)
        for i in self._sub_idx:
            s = bus.order[i]
            parts = s.name.split(".")
            scope = ([top] if top else []) + parts[:-1]
            kind = _kind_of(s)
            ident = self._w.declare(scope, parts[-1], kind, s.default)
            self._watch.append((i, ident, kind))
            if s.mode == PULSE:
                strobe = None
                if self._strobes and kind == "str":
                    # A string trace shows the payload but not the density of
                    # activity; a one-bit companion shows it at a glance.
                    strobe = self._w.declare(scope, parts[-1] + "_fired",
                                             "bit", False)
                self._pulses.append((i, ident, kind, s.default, strobe))
        self._by_idx = dict((i, (ident, kind)) for i, ident, kind in self._watch)
        self._strobe_of = dict((i, st) for i, _, _, _, st in self._pulses if st)

    def settle(self, bus):
        d = bus.delta - 1
        step = bus.cycle
        for i, ident, kind in self._watch:
            if i in bus._fired:
                self._w.change(step, d, ident, kind, bus._val[i])
                st = self._strobe_of.get(i)
                if st is not None:
                    self._w.change(step, d, st, "bit", True)

    def tick(self, bus):
        # Pulses clear at the next edge; draw that at the half-step so a strobe
        # reads as a strobe and clk reads as a clock.
        half = self._w.step_ticks // 2
        for i, ident, kind, default, strobe in self._pulses:
            self._w.change(bus.cycle, half, ident, kind, default)
            if strobe is not None:
                self._w.change(bus.cycle, half, strobe, "bit", False)

    def finish(self, bus):
        if self._own:
            self._w.close()

    def report(self):
        return self._w.report() if self._own else None
