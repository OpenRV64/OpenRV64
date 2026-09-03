"""The event bus: a clock, not a queue.

The naive event bus calls subscribers the instant something is published.
That is blocking-assignment semantics -- the result depends on the order
modules happened to be registered, and a module that publishes early in a
cycle sees a different world than one that publishes late.  This bus does not
do that.  A publish is never visible to anyone during the round in which it
was made.

``clk`` and ``rst_n`` are ordinary signals, published by a small module every
other module listens to.  That buys three things a bus-owned clock does not:
reset becomes a signal a module reads in ``tick`` (so a machine can reset
twice, and parts of it can be held in reset longer), a gated or divided clock
is a module that republishes ``clk`` (and its domain simply stops ticking), and
every module is woken once per step by the clock edge -- which removes the one
real footgun of a pure event bus, a module whose async output depends
on its own flop state with no signal to wake it.

One step is:

  edge     pulses clear; REG values published during step N-1 become visible
           at depth 0.  These are the flops, ``clk`` among them.
  deltas   every module subscribed to something that just fired is woken and
           may publish ASYNC.  Those publishes become visible at the *next*
           delta.  Repeat until nothing fires: the cycle has settled.
  tick     every module *whose clock edged this step* runs its edge behaviour
           and publishes REG for N+1.

Because nothing published in a round is readable in that round, wake order
within a round cannot change the result.  That is the whole guarantee, and it
is what makes a module swappable without reasoning about who runs first.

The rule that guarantee costs you
---------------------------------
``settle()`` must be a pure function of its inputs.  It may publish; it must not
mutate module state.  Settling re-runs it as often as its inputs move, and a
module woken with a half-settled input can publish a value it will withdraw
two deltas later -- exactly as real logic glitches before it settles.  Counting
something in ``settle`` counts the glitches.  State changes belong in ``tick``,
where the cycle has settled and the answer is final.

Withdrawal is therefore explicit: a module drives its output on *every*
evaluation, publishing the idle value when it has nothing to offer, the way a
continuous assignment does.  Publishing the default value of a PULSE that is
already idle is a no-op, so a module that always drives its output does not
spin the settling loop.

Timing
------
A ASYNC signal's *delta depth* is its distance in logic levels from the nearest
flop: a signal delivered at the edge is depth 0, and a module woken by inputs
of depth d publishes at depth d+1.  The bus tracks the per-signal maximum and
the chain that produced the deepest signal in the run, which is a first-order
read on where the critical path lives -- late in the settling order is late in
timing.  ``Bus(timing=False)`` drops the bookkeeping.

A async loop shows up as a cycle that never settles; the bus aborts at
``max_delta`` and names the signals still oscillating.
"""

from .module import ASYNC, REG, LEVEL, PULSE, MERGES, Signal


class AsyncLoop(RuntimeError):
    pass


class Elaboration(RuntimeError):
    pass


class Bus(object):
    def __init__(self, name="main", timing=True, max_delta=64, strict=True,
                 async_policy="allow", async_exempt=()):
        self.name = name
        self.cycle = 0
        self.delta = 0                # settling round in progress, for probes
        self.timing = timing
        self.max_delta = max_delta
        self.strict = strict          # dangling subscription is an error
        # "allow" / "warn" / "deny" an ASYNC signal crossing a module
        # boundary.  Deny is the fully decoupled discipline: every boundary a
        # flop, so every module is its own region and cheap to cut across a
        # thread, a process or a bus -- and none of the settling hazards can
        # arise, because nothing settles.  It costs what a pipeline stage
        # costs, which is measured in README 16.
        self.async_policy = async_policy
        self.async_exempt = set(async_exempt) | {"sys.done"}
        self.modules = []
        self.sigs = {}                # name -> Signal
        self.order = []               # idx -> Signal
        self._val = []
        self._val0 = []
        self._depth = []
        self._origin = []
        self._next_reg = {}
        self._stage = {}
        self._fired = frozenset()
        self._cyc_fired = set()
        self._always = []
        self._wake_next = []
        self._pre = []                # (module, fn) run before each edge
        self._contrib = {}            # merged signal idx -> {module id: value}
        self._elaborated = False
        self._cur_mod = None
        self._cur_depth = 0
        self._phase = "idle"
        self.warnings = []
        self.stats = {"cycles": 0, "deltas": 0, "publishes": 0, "wakes": 0}
        self.worst = None             # (depth, cycle, signal name)
        self.worst_chain = []         # settled path behind that signal
        self._maxd = []               # running per-signal max async depth

    # -- construction ------------------------------------------------------
    def add(self, module):
        if self._elaborated:
            raise Elaboration("bus already elaborated")
        self.modules.append(module)
        return module

    def elaborate(self):
        """Resolve names, check the wiring, freeze the graph.

        Checks, all of which are the port-connection rules a hardware
        elaborator would apply: exactly one driver per signal, no subscription
        to a signal nobody drives, and a warning for a driven signal nobody
        reads."""
        for m in self.modules:
            for s in m.declared_publishes():
                if s.name in self.sigs:
                    other = self.sigs[s.name].publisher
                    raise Elaboration("signal %r driven by both %s and %s"
                                      % (s.name, other.name, m.name))
                s.publisher = m
                s.idx = len(self.order)
                self.sigs[s.name] = s
                self.order.append(s)
                if s.merge is not None:
                    self._contrib[s.idx] = {}

        for m in self.modules:
            for nm in m.declared_contributes():
                s = self.sigs.get(nm)
                if s is None:
                    raise Elaboration("%s contributes to %r, which nothing declares"
                                      % (m.name, nm))
                if s.merge is None:
                    raise Elaboration("%s contributes to %r, which is not a merged "
                                      "signal -- only one module may drive it"
                                      % (m.name, nm))
                s.contributors.append(m)

        for m in self.modules:
            idxs = []
            for pat in m.declared_subscribes():
                hits = self._match(pat)
                if not hits:
                    msg = "%s subscribes to %r, which nothing publishes" % (m.name, pat)
                    if self.strict:
                        raise Elaboration(msg)
                    self.warnings.append(msg)
                for s in hits:
                    if m not in s.subs:
                        s.subs.append(m)
                    idxs.append(s.idx)
            m._sub_idx = tuple(sorted(set(idxs)))
            if m.always_async:
                self._always.append(m)

        for s in self.order:
            if not s.subs:
                self.warnings.append("signal %r is driven by %s but nobody subscribes"
                                     % (s.name, s.publisher.name))
            if (s.kind == ASYNC and s.subs and s.name not in self.async_exempt
                    and self.async_policy != "allow"):
                msg = ("%r is ASYNC and crosses a module boundary (%s -> %s): it "
                       "fuses them into one timing region and one process"
                       % (s.name, s.publisher.name,
                          ", ".join(m.name for m in s.subs)))
                if self.async_policy == "deny":
                    raise Elaboration(msg)
                self.warnings.append(msg)

        n = len(self.order)
        self._val = [s.default for s in self.order]
        self._val0 = [s.default for s in self.order]
        self._depth = [0] * n
        self._maxd = [0] * n
        self._origin = [None] * n
        self._elaborated = True

        for m in self.modules:
            ck = self.sigs.get(m.clock) if m.clock else None
            rs = self.sigs.get(m.reset_n) if m.reset_n else None
            m._clk_idx = ck.idx if ck is not None else None
            m._rst_idx = rs.idx if rs is not None else None

        self._phase = "build"
        for m in self.modules:
            self._cur_mod = m
            self._cur_depth = 0
            m.build(self)
        self._phase = "idle"
        self._cur_mod = None
        return self

    def _match(self, pat):
        if pat.endswith("*"):
            pre = pat[:-1]
            return [s for s in self.order if s.name.startswith(pre)]
        s = self.sigs.get(pat)
        return [s] if s is not None else []

    # -- module-facing API -------------------------------------------------
    def signal(self, name):
        """Intern a name once (in ``reset``) and publish/read by handle."""
        s = self.sigs.get(name)
        if s is None:
            raise Elaboration("no such signal %r" % name)
        return s

    def pub(self, sig, value):
        s = sig if type(sig) is Signal else self.sigs.get(sig)
        if s is None:
            raise Elaboration("publish to undeclared signal %r" % (sig,))
        if s.publisher is not self._cur_mod and self._cur_mod not in s.contributors:
            raise Elaboration("%s published %r, which %s drives"
                              % (self._cur_mod.name, s.name,
                                 s.publisher.name if s.publisher else "nobody"))
        if s.merge is not None:
            c = self._contrib[s.idx]
            c[id(self._cur_mod)] = value
            vals = list(c.values())
            value = MERGES[s.merge](vals) if vals else s.default
        if s.kind is ASYNC or s.kind == ASYNC:
            if self._phase == "tick":
                raise Elaboration("%s published ASYNC %r at the clock edge; the "
                                  "cycle has settled and nothing would see it"
                                  % (self._cur_mod.name, s.name))
            if self._phase in ("build", "prestep"):
                raise Elaboration("%s published ASYNC %r during %s; only a flop "
                                  "can be driven there"
                                  % (self._cur_mod.name, s.name, self._phase))
            self._stage[s.idx] = (value, self._cur_depth)
        else:
            self._next_reg[s.idx] = value
        self.stats["publishes"] += 1

    def get(self, sig):
        """Read a signal.  A module may read only what it subscribes to (plus
        what it drives itself) -- the same rule as a port list, and the reason
        an out-of-process module behaves identically: the host sends it only
        the signals it declared."""
        s = sig if type(sig) is Signal else self.sigs[sig]
        m = self._cur_mod
        if self.strict and m is not None and s.publisher is not m \
                and s.idx not in m._sub_idx:
            raise Elaboration("%s read %r without subscribing to it"
                              % (m.name, s.name))
        return self._val[s.idx]

    def fired(self, sig):
        """Is this signal asserted this cycle?

        The same question in every phase: a pulse whose value is not its idle
        value, or a level that differs from what it was at the edge.  It is
        deliberately *not* "did this wake me" -- a module is re-woken whenever
        any of its inputs moves, and logic that asked the per-delta question
        would get a different answer on the second wake and publish something
        it had already contradicted.  Read values, not wake reasons.

        ``woke_on`` is the per-delta question, for bookkeeping that genuinely
        wants it (an observer recording transitions).  It must not decide what
        a module drives."""
        s = sig if type(sig) is Signal else self.sigs[sig]
        return self._settled(s)

    def woke_on(self, sig):
        """Did this signal fire in the delta I am being called for?  Diagnostic
        only -- see ``fired``."""
        s = sig if type(sig) is Signal else self.sigs[sig]
        return s.idx in self._fired

    def _settled(self, s):
        if s.mode == PULSE:
            return self._val[s.idx] != s.default
        return self._val[s.idx] != self._val0[s.idx]

    def glitched(self, sig):
        """Moved during settling but ended where it started -- a path that
        toggles for nothing.  Free to ask, and it names real wasted logic."""
        s = sig if type(sig) is Signal else self.sigs[sig]
        return s.idx in self._cyc_fired and not self._settled(s)

    def fired_cycle(self, sig):
        s = sig if type(sig) is Signal else self.sigs[sig]
        return s.idx in self._cyc_fired

    def pre_step(self, module, fn):
        """Run ``fn(bus)`` at the very start of each step, before the edge.

        The clock uses this and little else should: it is the one place a value
        can be driven into the step about to run rather than the next one,
        which is what lets the clock decide whether to pulse *after* seeing
        every bus finish the previous step."""
        self._pre.append((module, fn))

    def resetting(self, module=None):
        """Is this module held in reset?  The ``if (!rst_n)`` arm of an
        always_ff, and the only architectural reset there is -- ``build`` runs
        once and cannot model a machine that resets twice."""
        m = module or self._cur_mod
        ri = m._rst_idx if m is not None else None
        return False if ri is None else not self._val[ri]

    def wake_next(self, module=None):
        """Ask to be woken at delta 1 of the next cycle.

        A module whose async output depends on its own flop state has
        no signal to wake it when that state changes -- nothing on the bus
        moved.  Calling this from ``tick`` when the state actually changed is
        the precise form: the module wakes exactly on the cycles where it has
        something new to say.  ``always_async = True`` is the blunt form, one
        wake every cycle, and is right for a module whose output depends on
        state that changes constantly."""
        m = module or self._cur_mod
        if m is not None:
            self._wake_next.append(m)

    def fired_names(self):
        return [self.order[i].name for i in sorted(self._fired)]

    def depth_of(self, sig):
        s = sig if type(sig) is Signal else self.sigs[sig]
        return self._depth[s.idx]

    # -- the clock ---------------------------------------------------------
    def step(self):
        if not self._elaborated:
            raise Elaboration("elaborate() before stepping")
        if self._pre:
            self._phase = "prestep"
            for m, fn in self._pre:
                self._cur_mod = m
                fn(self)
            self._cur_mod = None
            self._phase = "idle"
        order = self.order
        val = self._val
        depth = self._depth

        # --- edge: pulses clear, registered values land at depth 0 ---------
        for s in order:
            i = s.idx
            if s.mode == PULSE and val[i] != s.default:
                val[i] = s.default
            depth[i] = 0
            self._origin[i] = None
        self._val0 = list(val)          # the cycle's starting point
        fired = set()
        self._cyc_fired = cyc_fired = set()
        for idx, v in self._next_reg.items():
            if val[idx] != v:
                val[idx] = v
                fired.add(idx)
        self._next_reg = {}

        # --- deltas: settle ------------------------------------------------
        self._phase = "settle"
        delta = 0
        pending = self._always + self._wake_next
        self._wake_next = []
        while True:
            wake = list(pending)
            seen = set(id(m) for m in wake)
            for idx in fired:
                for m in order[idx].subs:
                    if id(m) not in seen:
                        seen.add(id(m))
                        wake.append(m)
            pending = ()
            if not wake:
                break
            delta += 1
            self.delta = delta
            if delta > self.max_delta:
                raise AsyncLoop(self._loop_report(delta, fired, wake))
            self._fired = fired
            cyc_fired |= fired
            self._stage = {}
            self.stats["deltas"] += 1
            self.stats["wakes"] += len(wake)
            for m in wake:
                self._cur_mod = m
                self._cur_depth = self._in_depth(m, fired) if self.timing else 0
                m.settle(self)
            for m in wake:
                self._cur_mod = m
                self._cur_depth = self._in_depth(m, fired) if self.timing else 0
                m.settle_flush(self)
            self._cur_mod = None
            newly = set()
            for idx, (v, d) in self._stage.items():
                if val[idx] == v:
                    # Re-evaluated to the same answer.  Nothing propagated, so
                    # nothing arrived later than it already had: a recompute is
                    # not a transition and must not deepen the path.
                    continue
                s = order[idx]
                val[idx] = v
                newly.add(idx)
                dd = d + self._weight(s.publisher)
                if self.timing and dd > depth[idx]:
                    depth[idx] = dd
                    self._origin[idx] = self._deepest_in(s.publisher, fired)
                    if dd > self._maxd[idx]:
                        self._maxd[idx] = dd
                    if self.worst is None or dd > self.worst[0]:
                        self.worst = (dd, self.cycle, s.name)
                        self.worst_chain = self._walk(idx)
            fired = newly

        # --- edge behaviour ------------------------------------------------
        self.delta = 0
        self._phase = "tick"
        ticking = [m for m in self.modules
                   if m._clk_idx is None or self._settled(order[m._clk_idx])]
        for m in ticking:
            self._cur_mod = m
            m.tick(self)
        for m in ticking:
            self._cur_mod = m
            m.tick_flush(self)
        self._cur_mod = None
        self._phase = "idle"
        self.stats["cycles"] += 1
        self.cycle += 1
        return delta

    def run(self, steps=None, until=None, cycles=None):
        steps = steps if steps is not None else cycles
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
        self._phase = "finish"
        for m in self.modules:
            self._cur_mod = m
            m.finish(self)
        self._cur_mod = None
        self._phase = "idle"
        return {m.name: m.report() for m in self.modules if m.report() is not None}

    # -- timing helpers ----------------------------------------------------
    def _in_depth(self, m, fired):
        d = 0
        for i in m._sub_idx:
            if i in fired and self._depth[i] > d:
                d = self._depth[i]
        return d

    def _weight(self, m):
        return getattr(m, "logic_depth", 1)

    def _deepest_in(self, m, fired):
        best, bi = -1, None
        for i in m._sub_idx:
            if i in fired and self._depth[i] > best:
                best, bi = self._depth[i], i
        return bi

    def chain(self, name):
        """Walk a signal back to the flop it settled from, this cycle."""
        return self._walk(self.sigs[name].idx)

    def _walk(self, idx):
        out = []
        seen = set()
        while idx is not None and idx not in seen:
            seen.add(idx)
            out.append((self.order[idx].name, self._depth[idx]))
            idx = self._origin[idx]
        return list(reversed(out))

    def regions(self):
        """Modules that settle together, as a list of sets.

        An ASYNC signal between two modules means neither is finished until
        both are: they cannot be split across a thread, a process or a bus
        without changing the machine by a cycle, and every settling hazard
        lives inside one of these.  A region of one module can be cut out
        anywhere around.  This is the honest measure of how decoupled a design
        actually is -- and the reason to care about an ASYNC export is this,
        not any claim about gates."""
        parent = dict((m.name, m.name) for m in self.modules)

        def find(a):
            while parent[a] != a:
                parent[a] = parent[parent[a]]
                a = parent[a]
            return a

        for s in self.order:
            if s.kind != ASYNC or not s.subs:
                continue
            for m in s.subs:
                ra, rb = find(s.publisher.name), find(m.name)
                if ra != rb:
                    parent[rb] = ra
        groups = {}
        for m in self.modules:
            groups.setdefault(find(m.name), []).append(m.name)
        return sorted((sorted(v) for v in groups.values()),
                      key=lambda g: (-len(g), g[0]))

    def max_depths(self):
        """Per-signal maximum async depth over the whole run."""
        return sorted(((self._maxd[s.idx], s.name) for s in self.order
                       if s.kind == ASYNC), reverse=True)

    def _loop_report(self, delta, fired, wake):
        names = ", ".join(sorted(self.order[i].name for i in fired)[:8])
        mods = ", ".join(sorted(m.name for m in wake)[:8])
        return ("async loop: cycle %d did not settle in %d deltas.\n"
                "  still firing: %s\n  still waking: %s\n"
                "  break it by making one signal on the loop REG, or by making "
                "the backward signal (ready) independent of the forward one "
                "(valid) within the cycle." % (self.cycle, delta, names, mods))
