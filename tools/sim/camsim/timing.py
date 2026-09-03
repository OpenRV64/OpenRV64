"""Reading the delta counts as a timing estimate.

Be precise about what this counts.  An ASYNC signal settles at a delta equal to
the number of *module hops* between it and the flop that started the cascade --
not logic levels.  The bus cannot see logic levels: the gates are inside the
modules, and a unit that is one inverter and a unit that is a 64-bit priority
encoder are both one hop.

So the raw number answers a structural question, and a real one: how many units
have to resolve in series before this cycle is settled.  A chain of five units
inside one cycle is a chain of five units however small each is, and it is the
shape a critical path takes.

For the number to approximate logic levels, a module says how much logic it is:

    class Select(Module):
        logic_depth = 6         # a 32-entry age-ordered picker, roughly

Depth then accumulates by declared weight instead of by one, and the report is
an estimate rather than a hop count.  Either way use it as a differential --
``depth(x) went 3 -> 6 when I added the bypass`` is a real statement about a
path that got longer; ``depth 6 will not close at 50 MHz`` is not.
"""


def report(bus, top=12):
    import sys
    L = ["interpreter %s %s" % (sys.implementation.name,
                                ".".join(str(x) for x in sys.version_info[:3]))]
    st = bus.stats
    cyc = max(1, st["cycles"])
    L.append("cycles %d   deltas %d (%.2f/cyc)   wakes %d (%.2f/cyc)   publishes %d"
             % (st["cycles"], st["deltas"], st["deltas"] / float(cyc),
                st["wakes"], st["wakes"] / float(cyc), st["publishes"]))
    if not bus.timing:
        L.append("timing instrumentation off")
        return "\n".join(L)

    md = bus.max_depths()
    if md:
        L.append("")
        weighted = any(getattr(m, "logic_depth", 1) != 1 for m in bus.modules)
        L.append("deepest async signals (%s from a flop):"
                 % ("estimated logic levels" if weighted else "module hops"))
        for d, name in md[:top]:
            if d == 0:
                continue
            L.append("  %2d  %s" % (d, name))
    if bus.worst:
        d, c, name = bus.worst
        L.append("")
        L.append("worst path: depth %d at cycle %d, settling on %s" % (d, c, name))
        for nm, dd in bus.worst_chain:
            L.append("   %2d  %s" % (dd, nm))
    return "\n".join(L)


def regions(bus):
    """Where the design can be cut, and where it cannot."""
    L = ["same-cycle regions (modules that settle together):"]
    for g in bus.regions():
        if len(g) == 1:
            L.append("  %-28s  separable" % g[0])
        else:
            L.append("  %-28s  fused: %s" % (g[0] + " ...", ", ".join(g)))
    n = sum(1 for g in bus.regions() if len(g) > 1)
    L.append("  %d of %d regions hold more than one module; a region is the unit "
             "that can cross a thread, a process or a bus"
             % (n, len(bus.regions())))
    return "\n".join(L)


def graph(bus):
    """The wiring, as text.  Useful for confirming a swap did what you meant."""
    L = []
    for m in bus.modules:
        outs = [s for s in bus.order if s.publisher is m]
        L.append("%s" % m.name)
        for s in outs:
            subs = ",".join(x.name for x in s.subs) or "-"
            L.append("   out %-26s %-4s %-5s -> %s" % (s.name, s.kind, s.mode, subs))
        for i in m._sub_idx:
            s = bus.order[i]
            L.append("   in  %-26s %-4s %-5s <- %s" % (s.name, s.kind, s.mode,
                                                       s.publisher.name))
    return "\n".join(L)
