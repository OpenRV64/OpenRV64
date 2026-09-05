"""Basic statistics over a parsed Trace."""

from .model import stage_name, state_name, reason_name


def _pct(n, total):
    return (100.0 * n / total) if total else 0.0


def basic_stats(trace):
    """Return the --stats report as a string."""
    span = trace.n_cycles
    insns = trace.insns.values()

    fetched = len(trace.insns)
    fetch_rows = sum(r.fetch_cycles for r in insns)
    decoded = sum(1 for r in insns if r.decode_cycle is not None)
    scheduled = sum(1 for r in insns if r.sched_enter_cycle is not None)
    issued = sum(1 for r in insns if r.issue_cycle is not None)
    completed = sum(1 for r in insns if r.complete_cycle is not None)
    retired = sum(1 for r in insns if r.retire_cycle is not None)

    loads = sum(1 for r in insns if r.is_load)
    stores = sum(1 for r in insns if r.is_store)
    loads_issued = sum(1 for r in insns if r.is_load and r.issued)
    loads_retired = sum(1 for r in insns if r.is_load and r.retired)
    stores_retired = sum(1 for r in insns if r.is_store and r.retired)
    branches_retired = sum(1 for r in insns if r.is_branch and r.retired)
    jumps_retired = sum(1 for r in insns if r.is_jump and r.retired)

    ihist = trace.issue_width_histogram()
    rhist = trace.retire_width_histogram()

    out = []
    a = out.append
    a("trace:  %s" % (trace.path or "<stream>"))
    a("schema: %s" % trace.schema)
    a("rows:   {:,}   (parsed with {} worker{})".format(
        trace.rows, trace.parse_jobs, "s" if trace.parse_jobs != 1 else ""))
    a("")
    a("cycles: {:,} .. {:,}  (span {:,})".format(
        trace.min_cycle, trace.max_cycle, span))
    a("")
    a("instructions (distinct insn_ids):")
    a("  fetched:   {:>9,}   ({:,} frontend-resident row-cycles)".format(
        fetched, fetch_rows))
    a("  decoded:   {:>9,}".format(decoded))
    a("  scheduled: {:>9,}".format(scheduled))
    a("  issued:    {:>9,}".format(issued))
    a("  completed: {:>9,}".format(completed))
    a("  retired:   {:>9,}".format(retired))
    a("  fetched but never retired (squashed/wrong-path): {:,}".format(
        fetched - retired))
    a("")
    a("instruction classes (ROB class bits, opcode fallback):")
    a("  loads:    {:>8,} seen   {:>8,} issued   {:>8,} retired"
      "  ({:.2f}% of retired)".format(
          loads, loads_issued, loads_retired, _pct(loads_retired, retired)))
    a("  stores:   {:>8,} seen   {:>8,} retired  ({:.2f}% of retired)".format(
        stores, stores_retired, _pct(stores_retired, retired)))
    a("  branches: {:>8,} retired   jumps: {:>8,} retired".format(
        branches_retired, jumps_retired))
    a("")
    a("issue width per cycle (EXEC FIREs, over {:,}-cycle span):".format(span))
    for w, n in enumerate(ihist):
        a("  %d issued: %10s  (%6.2f%%)" % (w, "{:,}".format(n), _pct(n, span)))
    a("")
    a("retire width per cycle:")
    for w, n in enumerate(rhist):
        a("  %d retired: %9s  (%6.2f%%)" % (w, "{:,}".format(n), _pct(n, span)))
    a("")
    a("IPC (retired/span): %.4f    issue IPC: %.4f" % (
        (retired / span) if span else 0.0,
        (issued / span) if span else 0.0))
    return "\n".join(out)


def ssr_report(trace, limit=None):
    """Row counts per (stage, state, reason), most common first."""
    out = ["rows by (component, state, reason):"]
    table = trace.ssr_table()
    if limit:
        table = table[:limit]
    for (stage, state, reason), count in table:
        out.append("  %-9s %-11s %-22s %11s" % (
            stage_name(stage), state_name(state), reason_name(reason),
            "{:,}".format(count)))
    return "\n".join(out)


def _latency_stats(values):
    """(n, min, mean, p50, p90, p99, max) or None for empty input."""
    if not values:
        return None
    vs = sorted(values)
    n = len(vs)

    def pct(p):
        return vs[min(n - 1, (n * p) // 100)]

    return (n, vs[0], sum(vs) / n, pct(50), pct(90), pct(99), vs[-1])


def _lat_line(label, values):
    s = _latency_stats(values)
    if s is None:
        return "  %-26s (no samples)" % label
    n, lo, mean, p50, p90, p99, hi = s
    return ("  %-26s n=%-7d min=%-4d mean=%-7.2f p50=%-4d p90=%-4d "
            "p99=%-5d max=%d" % (label, n, lo, mean, p50, p90, p99, hi))


def _hist_lines(vals, indent="    ", bar_width=40):
    """ASCII histogram: exact bins 0..15, coarse ranges above, trimmed
    to the occupied span (interior zero bins are kept for shape)."""
    if not vals:
        return [indent + "(no samples)"]
    n = len(vals)
    edges = [(i, i) for i in range(0, 16)] + [
        (16, 19), (20, 24), (25, 29), (30, 39), (40, 59), (60, 99),
        (100, None)]
    rows = []
    neg = sum(1 for v in vals if v < 0)
    if neg:
        rows.append(("<0", neg))
    for lo, hi in edges:
        c = sum(1 for v in vals if v >= lo and (hi is None or v <= hi))
        label = ("%d" % lo if hi == lo else
                 "%d+" % lo if hi is None else "%d-%d" % (lo, hi))
        rows.append((label, c))
    while rows and rows[0][1] == 0:
        rows.pop(0)
    while rows and rows[-1][1] == 0:
        rows.pop()
    out = []
    for label, c in rows:
        bar = "#" * int(round(float(bar_width) * c / n))
        out.append("%s%-7s %9s  (%5.1f%%)  %s" % (
            indent, label, "{:,}".format(c), 100.0 * c / n, bar))
    return out


def _reason_table(title, per_reason, affected, population):
    """Format aggregated wait-reason cycles for one component."""
    out = ["  %s:" % title]
    if not per_reason:
        out.append("    (none)")
        return out
    total = sum(per_reason.values())
    for reason, cycles in sorted(per_reason.items(), key=lambda kv: -kv[1]):
        n = affected.get(reason, 0)
        out.append(
            "    %-22s %10s cyc  (%5.1f%%)  %6d insns affected"
            "  avg %.1f cyc/affected" % (
                reason_name(reason), "{:,}".format(cycles),
                _pct(cycles, total), n, cycles / n if n else 0.0))
    out.append("    %-22s %10s cyc over %s insns" % (
        "total", "{:,}".format(total), "{:,}".format(population)))
    return out


def _insn_class(instr, exec_worker_cycles=0):
    """Coarse producer/consumer class of an instruction word."""
    op = instr & 0x7F
    if op in (0x03, 0x07):
        return "load"
    if op in (0x23, 0x27):
        return "store"
    if op == 0x2F:
        return "amo"
    if op in (0x33, 0x3B):
        if (instr >> 25) & 1:
            return "muldiv"
        return "alu"
    if op in (0x13, 0x1B, 0x37, 0x17):
        return "alu"
    if op in (0x6F, 0x67):
        return "jump"
    if op == 0x63:
        return "branch"
    return "other"


CLASSES = {
    "loads": lambda r: r.is_load,
    "stores": lambda r: r.is_store,
    "alu": lambda r: _insn_class(r.instr) == "alu",
    "muldiv": lambda r: _insn_class(r.instr) == "muldiv",
    "branches": lambda r: _insn_class(r.instr) == "branch",
    "jumps": lambda r: _insn_class(r.instr) == "jump",
}


def characterize(trace, want, hist=False):
    """Per-class characterization report.  want: one of CLASSES.

    hist=True adds full latency histograms for the segments where the
    shape matters (the summary line's p50/p90 hides bimodality)."""
    try:
        pred = CLASSES[want]
    except KeyError:
        raise ValueError("unknown class %r (have %s)"
                         % (want, ", ".join(sorted(CLASSES))))

    sel = [r for r in trace.insns.values() if pred(r)]
    retired = [r for r in sel if r.retired]
    issued = [r for r in sel if r.issued]
    squashed_preissue = [r for r in sel if not r.issued]
    issued_not_completed = [r for r in issued if r.complete_cycle is None]
    completed_not_retired = [r for r in issued
                             if r.complete_cycle is not None
                             and not r.retired]

    out = []
    a = out.append
    a("%s characterization (%s):" % (want, trace.path or "<stream>"))
    a("")
    a("population:")
    a("  %s uids seen:         {:>8,}".format(len(sel)) % want)
    a("  issued:                {:>8,}".format(len(issued)))
    a("  retired:               {:>8,}".format(len(retired)))
    a("  squashed before issue: {:>8,}".format(len(squashed_preissue)))
    a("  issued, no completion: {:>8,}   completed, not retired: {:,}".format(
        len(issued_not_completed), len(completed_not_retired)))

    pipes = {}
    for r in issued:
        pipes[r.issue_pipe] = pipes.get(r.issue_pipe, 0) + 1
    from .model import PIPE_NAMES
    a("  issue pipe split:      %s" % "   ".join(
        "%s=%s" % (PIPE_NAMES.get(p, p), "{:,}".format(n))
        for p, n in sorted(pipes.items())))
    worker = sum(r.exec_worker_cycles for r in sel)
    if worker:
        a("  EX0 worker cycles:     {:>8,}".format(worker))

    def seg(f, g):
        vals = []
        for r in retired:
            x, y = f(r), g(r)
            if x is not None and y is not None:
                vals.append(y - x)
        return vals

    segments = [
        ("fetch -> decode", False,
         seg(lambda r: r.fetch_first_cycle, lambda r: r.decode_cycle)),
        ("decode -> sched entry", False,
         seg(lambda r: r.decode_cycle, lambda r: r.sched_enter_cycle)),
        ("sched entry -> issue", True,
         seg(lambda r: r.sched_enter_cycle, lambda r: r.issue_cycle)),
        ("issue -> complete", True,
         seg(lambda r: r.issue_cycle, lambda r: r.complete_cycle)),
        ("complete -> retire", True,
         seg(lambda r: r.complete_cycle, lambda r: r.retire_cycle)),
        ("fetch -> retire (total)", True,
         seg(lambda r: r.fetch_first_cycle, lambda r: r.retire_cycle)),
    ]
    a("")
    a("timing segments, retired %s (cycles):" % want)
    for label, _, vals in segments:
        a(_lat_line(label, vals))
    if hist:
        for label, wanted, vals in segments:
            if not wanted:
                continue
            a("")
            a("  %s histogram:" % label)
            out.extend(_hist_lines(vals))

    lat = seg(lambda r: r.issue_cycle, lambda r: r.complete_cycle)
    modes = {}
    for v in lat:
        modes[v] = modes.get(v, 0) + 1
    a("")
    a("issue -> complete latency modes (top 12):")
    for v, n in sorted(modes.items(), key=lambda kv: -kv[1])[:12]:
        a("    %4d cyc: %8s  (%5.1f%%)" % (v, "{:,}".format(n),
                                           _pct(n, len(lat))))

    def collect(getter):
        per, affected = {}, {}
        for r in sel:
            d = getter(r)
            if not d:
                continue
            for reason, cyc in d.items():
                per[reason] = per.get(reason, 0) + cyc
                affected[reason] = affected.get(reason, 0) + 1
        return per, affected

    a("")
    a("wait cycles by primary reason (all %s uids):" % want)
    per, aff = collect(lambda r: r.sched_wait_reasons)
    out.extend(_reason_table("scheduler (pre-issue)", per, aff, len(sel)))
    per, aff = collect(lambda r: r.lsq_wait_reasons)
    if per:
        out.extend(_reason_table("LSQ (post-issue)", per, aff, len(sel)))
    per, aff = collect(lambda r: r.decode_wait_reasons)
    out.extend(_reason_table("decode admission", per, aff, len(sel)))
    return "\n".join(out)


def issue_blocked_report(trace):
    """Why zero-issue (and partial-issue) cycles happened, per cycle.

    Attribution is the program-oldest WAITing scheduler entry's primary
    reason in that cycle, captured exactly during parse.
    """
    from .model import NO_UID
    span = trace.n_cycles
    lo, hi = trace.min_cycle, trace.max_cycle
    ic = trace.issue_counts
    sc = trace.sched_cycles

    empty = 0
    ready_only = 0
    by_reason = {}
    partial_by_reason = {}
    partial_cycles = 0
    for c in range(lo, hi + 1):
        issued = ic.get(c, 0)
        if issued >= 3:
            continue
        info = sc.get(c)
        if issued == 0:
            if info is None:
                empty += 1
            elif info[0] == NO_UID:
                ready_only += 1
            else:
                r = info[1]
                by_reason[r] = by_reason.get(r, 0) + 1
        else:
            # 1- or 2-wide cycle with an older entry still waiting:
            # width lost to that entry's reason.
            if info is not None and info[0] != NO_UID:
                partial_cycles += 1
                r = info[1]
                partial_by_reason[r] = partial_by_reason.get(r, 0) + 1

    blocked = empty + ready_only + sum(by_reason.values())
    out = []
    a = out.append
    a("issue-blocked cycles (0 issues): {:,} of {:,} span ({:.1f}%)".format(
        blocked, span, _pct(blocked, span)))
    a("  scheduler empty (frontend starved/drained): {:>7,}  ({:5.1f}%"
      " of blocked)".format(empty, _pct(empty, blocked)))
    a("  entries READY but none issued (arbitration): {:>6,}  ({:5.1f}%)".format(
        ready_only, _pct(ready_only, blocked)))
    a("  oldest waiting entry blocked on:")
    for r, n in sorted(by_reason.items(), key=lambda kv: -kv[1]):
        a("    %-22s %8s  (%5.1f%% of blocked cycles)" % (
            reason_name(r), "{:,}".format(n), _pct(n, blocked)))
    a("")
    a("partial-issue cycles (1-2 issues, older entry still waiting): "
      "{:,}".format(partial_cycles))
    for r, n in sorted(partial_by_reason.items(), key=lambda kv: -kv[1])[:8]:
        a("    %-22s %8s" % (reason_name(r), "{:,}".format(n)))
    return "\n".join(out)


def retire_blocked_report(trace):
    """Why zero-retire cycles happened.

    The ROB head is the minimum live uid that cycle (uids are program-
    ordered).  Its per-cycle ROB state is exact; heads not yet issued
    are sub-attributed by the head insn's *dominant* scheduler wait
    reason, which aggregates its whole residency (approximate, and
    labeled as such).
    """
    span = trace.n_cycles
    lo, hi = trace.min_cycle, trace.max_cycle
    rc = trace.retire_counts
    rhc = trace.rob_head_cycles
    insns = trace.insns

    rob_empty = 0
    head_not_issued = 0
    head_in_flight = 0
    head_done_backpressure = 0
    odd = 0
    not_issued_reason = {}
    in_flight_class = {}
    for c in range(lo, hi + 1):
        if rc.get(c, 0) != 0:
            continue
        info = rhc.get(c)
        if info is None:
            rob_empty += 1
            continue
        uid, state = info
        h = insns.get(uid)
        if state != 10:  # COMPLETE-behind-head or HEAD: result exists
            head_done_backpressure += 1
            continue
        if h is None:
            odd += 1
        elif h.issue_cycle is None or c < h.issue_cycle:
            head_not_issued += 1
            d = h.sched_wait_reasons
            if d:
                r = max(d.items(), key=lambda kv: kv[1])[0]
                not_issued_reason[r] = not_issued_reason.get(r, 0) + 1
        elif h.complete_cycle is None or c <= h.complete_cycle:
            # <=: the COMPLETE FIRE at cycle c is the completion offer,
            # accepted at edge c+1; the ROB row this cycle still reads
            # INCOMPLETE.  The head is completing, not yet retirable.
            head_in_flight += 1
            cls = ("load" if h.is_load else
                   "store" if h.is_store else
                   "branch" if h.is_branch else
                   "jump" if h.is_jump else "other")
            in_flight_class[cls] = in_flight_class.get(cls, 0) + 1
        else:
            odd += 1

    blocked = (rob_empty + head_not_issued + head_in_flight
               + head_done_backpressure + odd)
    out = []
    a = out.append
    a("retire-blocked cycles (0 retires): {:,} of {:,} span ({:.1f}%)".format(
        blocked, span, _pct(blocked, span)))
    a("  ROB empty (nothing to retire):     {:>8,}  ({:5.1f}% of blocked)".format(
        rob_empty, _pct(rob_empty, blocked)))
    a("  head waiting to issue:             {:>8,}  ({:5.1f}%)".format(
        head_not_issued, _pct(head_not_issued, blocked)))
    a("    by head's dominant scheduler reason (approx, whole-residency):")
    for r, n in sorted(not_issued_reason.items(), key=lambda kv: -kv[1]):
        a("      %-22s %8s" % (reason_name(r), "{:,}".format(n)))
    a("  head issued, awaiting completion:  {:>8,}  ({:5.1f}%)".format(
        head_in_flight, _pct(head_in_flight, blocked)))
    a("    by head class: %s" % "   ".join(
        "%s=%s" % (k, "{:,}".format(n))
        for k, n in sorted(in_flight_class.items(), key=lambda kv: -kv[1])))
    a("  head complete, retirement not accepted: {:>3,}  ({:5.1f}%)".format(
        head_done_backpressure, _pct(head_done_backpressure, blocked)))
    a("    (cycles with an explicit RETIRE WAIT row: {:,})".format(
        len(trace.retire_backpressure_cycles)))
    if odd:
        a("  unclassified: {:,}".format(odd))
    return "\n".join(out)


def head_report(trace, hist=False):
    """Retire-head residency: who sits at the ROB head, and for how long.

    The head is the minimum live uid in the ROB each cycle (uid order is
    program order).  Tenure counts every cycle an instruction holds the
    head, split into waiting-for-completion (c <= complete_cycle -- the
    falling-edge sampling rule: at the COMPLETE FIRE cycle the ROB row
    still reads INCOMPLETE) and complete-but-not-yet-retired (retire
    width / acceptance).  Grouped by PC so a hot instruction is named,
    not just a hot class.
    """
    lo, hi = trace.min_cycle, trace.max_cycle
    span = trace.n_cycles
    rhc, insns = trace.rob_head_cycles, trace.insns

    per_uid = {}                  # uid -> [incomplete cyc, complete cyc]
    occupied = 0
    for c in range(lo, hi + 1):
        info = rhc.get(c)
        if info is None:
            continue
        occupied += 1
        uid = info[0]
        e = per_uid.get(uid)
        if e is None:
            e = per_uid[uid] = [0, 0]
        r = insns.get(uid)
        if (r is not None and r.complete_cycle is not None
                and c > r.complete_cycle):
            e[1] += 1
        else:
            e[0] += 1

    def p50(vs):
        vs = sorted(vs)
        return vs[len(vs) // 2]

    per_pc = {}       # pc -> [n, cyc, incomplete, tenures, insn]
    per_cls = {}      # class -> [n, cyc, incomplete, tenures]
    tenures = []
    for uid, (inc, comp) in per_uid.items():
        r = insns.get(uid)
        if r is None:
            continue
        t = inc + comp
        tenures.append(t)
        k = _insn_class(r.instr)
        s = per_cls.setdefault(k, [0, 0, 0, []])
        s[0] += 1
        s[1] += t
        s[2] += inc
        s[3].append(t)
        e = per_pc.get(r.pc)
        if e is None:
            e = per_pc[r.pc] = [0, 0, 0, [], r]
        e[0] += 1
        e[1] += t
        e[2] += inc
        e[3].append(t)

    out = []
    a = out.append
    a("retire-head residency (span {:,} cycles, head occupied {:,} = "
      "{:.1f}%):".format(span, occupied, _pct(occupied, span)))
    a("  {:,} dynamic instructions held the head, mean tenure {:.2f} "
      "cycles".format(len(tenures),
                      float(sum(tenures)) / len(tenures) if tenures else 0))
    a("  (tenure: incomplete = waiting for its own completion; complete = "
      "waiting to be accepted)")
    a("")
    a("by class:")
    a("  %-8s %8s %10s %7s  %6s %5s %5s  %s" % (
        "class", "heads", "head-cyc", "of-occ", "mean", "p50", "max",
        "incomplete%"))
    for k, (n, cyc, inc, ts) in sorted(per_cls.items(),
                                       key=lambda kv: -kv[1][1]):
        a("  %-8s %8s %10s %6.1f%%  %6.2f %5d %5d  %10.1f%%" % (
            k, "{:,}".format(n), "{:,}".format(cyc), _pct(cyc, occupied),
            float(cyc) / n, p50(ts), max(ts), _pct(inc, cyc)))
    a("")
    a("top instructions by cycles held at the head:")
    a("  %-10s %-10s %-7s %6s %9s  %6s %4s %5s  %s" % (
        "pc", "instr", "class", "n", "head-cyc", "mean", "p50", "max",
        "incomplete%"))
    for pc, (n, cyc, inc, ts, r) in sorted(per_pc.items(),
                                           key=lambda kv: -kv[1][1])[:20]:
        a("  %-10x %08x   %-7s %6s %9s  %6.2f %4d %5d  %10.1f%%" % (
            pc, r.instr, _insn_class(r.instr), "{:,}".format(n),
            "{:,}".format(cyc), float(cyc) / n, p50(ts), max(ts),
            _pct(inc, cyc)))

    if hist:
        a("")
        a("head tenure histogram (all dynamic heads, cycles at head):")
        out.extend(_hist_lines(tenures))
        for k, (n, cyc, inc, ts) in sorted(per_cls.items(),
                                           key=lambda kv: -kv[1][1])[:3]:
            a("")
            a("%s head tenure histogram:" % k)
            out.extend(_hist_lines(ts))
    return "\n".join(out)


def wakeup_report(trace, top=12):
    """Wakeup-tax calculator.

    Architectural last-writer walk over the retired stream (same
    provenance as --src1).  Every consumer that logged SRC1/SRC2 wait
    cycles names its producer; the edge's wakeup slack is
    consumer.issue - producer.complete.

      slack <= 0 : consumer issued at/before the completion event
                   (value forwarded early) -- no tax
      slack == 1 : issued exactly one cycle after completion -- the
                   completion-timed wakeup register.  On a 1-cycle
                   producer this doubles the hop.
      slack >= 2 : something else also held the consumer (width, a
                   port, another source) -- not pure wakeup tax.

    The taxed-edge count is an inventory, not a span prediction: taxed
    edges on parallel paths compress for free, serial chains pay per
    hop.  Price the fix by re-execution (camsim/RTL), not from here.
    """
    from .model import ROB_D0_REG_WRITE
    retired = sorted((r.uid, r) for r in trace.insns.values()
                     if r.retired and r.rob_info is not None)
    last_writer = [None] * 32
    per = {}                  # producer key -> [<=0, ==1, ==2, >=3]
    taxed_consumer = {}
    taxed_pc = {}
    for uid, r in retired:
        d = r.sched_wait_reasons
        if d and r.issue_cycle is not None:
            w1 = d.get(1, 0) + d.get(3, 0)
            w2 = d.get(2, 0) + d.get(3, 0)
            for w, reg in ((w1, r.rs1), (w2, r.rs2)):
                if not w or not reg:
                    continue
                p = last_writer[reg]
                if (p is None or p.issue_cycle is None
                        or p.complete_cycle is None):
                    continue
                plat = p.complete_cycle - p.issue_cycle
                pk = _insn_class(p.instr)
                if p.exec_worker_cycles:
                    pk = "muldiv"
                key = "%s lat=%s" % (pk, plat if plat <= 3 else "4+")
                slack = r.issue_cycle - p.complete_cycle
                b = 0 if slack <= 0 else 1 if slack == 1 else \
                    2 if slack == 2 else 3
                per.setdefault(key, [0, 0, 0, 0])[b] += 1
                if slack == 1:
                    ck = _insn_class(r.instr)
                    taxed_consumer[ck] = taxed_consumer.get(ck, 0) + 1
                    t = taxed_pc.setdefault(r.pc, [0, r])
                    t[0] += 1
        if (r.rob_info >> ROB_D0_REG_WRITE) & 1 and r.rd:
            last_writer[r.rd] = r

    out = []
    a = out.append
    total = sum(sum(v) for v in per.values())
    taxed = sum(v[1] for v in per.values())
    a("wakeup tax (waited-on dependence edges, slack = consumer issue"
      " - producer complete):")
    a("  %s edges from consumers that logged SRC waits; %s taxed"
      " (slack == 1, %.1f%%)" % ("{:,}".format(total),
                                 "{:,}".format(taxed),
                                 _pct(taxed, total)))
    a("")
    a("  by producer (class, latency):")
    a("    %-14s %8s  %8s %8s %8s %8s" % (
        "producer", "edges", "<=0", "==1", "==2", ">=3"))
    for key, v in sorted(per.items(), key=lambda kv: -kv[1][1]):
        n = sum(v)
        a("    %-14s %8s  %7.1f%% %7.1f%% %7.1f%% %7.1f%%" % (
            key, "{:,}".format(n), _pct(v[0], n), _pct(v[1], n),
            _pct(v[2], n), _pct(v[3], n)))
    a("")
    a("  taxed edges by consumer class:")
    for k, n in sorted(taxed_consumer.items(), key=lambda kv: -kv[1]):
        a("    %-8s %8s" % (k, "{:,}".format(n)))
    a("")
    a("  top consumer PCs paying the tax:")
    a("    %-10s %-10s %-7s %8s" % ("pc", "instr", "class", "edges"))
    for pc, (n, r) in sorted(taxed_pc.items(),
                             key=lambda kv: -kv[1][0])[:top]:
        a("    %-10x %08x   %-7s %8s" % (pc, r.instr,
                                         _insn_class(r.instr),
                                         "{:,}".format(n)))
    a("")
    a("  (slack==1 on a lat=1 producer doubles that hop; on a lat=3")
    a("   load it adds 33%%.  Serial chains pay per hop; parallel")
    a("   edges are free.  Price the fix by re-execution, not here.)")
    return "\n".join(out)


def overlap_report(trace, boundary_pc=None):
    """Iteration overlap: how many loop iterations are in flight.

    Iterations are delimited by successive retired instances of a
    boundary PC (default: the most frequent retired jump -- the hot
    call site).  For each iteration: first issue, last completion.
    The overlap of consecutive iterations and the Little's-law
    concurrency say whether the machine advances through iterations
    or runs them as a relay."""
    if boundary_pc is None:
        counts = {}
        for r in trace.insns.values():
            if r.retired and r.is_jump:
                counts[r.pc] = counts.get(r.pc, 0) + 1
        if not counts:
            return "overlap: no retired jumps to use as a boundary"
        boundary_pc = max(counts, key=counts.get)
    calls = sorted(r.uid for r in trace.insns.values()
                   if r.pc == boundary_pc and r.retired)
    byuid = dict((r.uid, r) for r in trace.insns.values()
                 if r.retired and r.issue_cycle is not None)
    iters = []
    for k in range(len(calls) - 1):
        rs = [byuid[u] for u in range(calls[k], calls[k + 1])
              if u in byuid]
        if len(rs) < 5:
            continue
        fi = min(r.issue_cycle for r in rs)
        lc = max(r.complete_cycle or r.issue_cycle for r in rs)
        iters.append((fi, lc))
    if len(iters) < 8:
        return ("overlap: boundary %x yields only %d iterations"
                % (boundary_pc, len(iters)))
    periods = [b[0] - a[0] for a, b in zip(iters, iters[1:])
               if 0 < b[0] - a[0] <= 200]
    overlaps = [a[1] - b[0] for a, b in zip(iters, iters[1:])
                if 0 < b[0] - a[0] <= 200]
    spans = [lc - fi for fi, lc in iters]

    def st(vs):
        vs = sorted(vs)
        n = len(vs)
        return "p50=%-4d p90=%-4d mean=%.1f" % (
            vs[n // 2], vs[n * 9 // 10], sum(vs) / float(n))

    conc = (sum(spans) /
            float(max(lc for _, lc in iters) - min(fi for fi, _ in iters)))
    serial = sum(1 for o in overlaps if o <= 0)
    out = []
    out.append("iteration overlap (boundary pc %x, %d iterations):"
               % (boundary_pc, len(iters)))
    out.append("  period (start-to-start):   %s" % st(periods))
    out.append("  lifetime (issue span):     %s" % st(spans))
    out.append("  overlap (prev end - next start): %s" % st(overlaps))
    out.append("  fully serial handoffs: %d (%.0f%%)"
               % (serial, _pct(serial, len(overlaps))))
    out.append("  avg iterations in flight (Little): %.2f" % conc)
    return "\n".join(out)


def pairs_report(trace, same_unit=False, top=24):
    """Back-to-back dependent pairs: dependence edges where the
    consumer issued the very next cycle after its producer (gap == 1
    -- chained execution, visible in the trace).  Grouped by static
    (producer pc, consumer pc), so a hot pair -- a fusion or chaining
    candidate -- shows as one row with a big count.  The gap==2 column
    is the near-miss population: pairs that one more cycle of wakeup
    or forwarding would convert.

    same_unit=True keeps only pairs whose ends are the same class
    (alu->alu, load->load, ...) -- candidates that live in one unit.
    """
    from .model import ROB_D0_REG_WRITE
    retired = sorted((r.uid, r) for r in trace.insns.values()
                     if r.retired and r.rob_info is not None)
    last_writer = [None] * 32
    pairs = {}       # (ppc,cpc) -> [n, b2b, near, p_insn, c_insn, pk, ck]
    cls_pair = {}    # (pk,ck) -> [n, b2b]
    for uid, r in retired:
        if r.issue_cycle is not None:
            ck = _insn_class(r.instr)
            for reg in (r.rs1, r.rs2):
                if not reg or last_writer[reg] is None:
                    continue
                p = last_writer[reg]
                if p.issue_cycle is None:
                    continue
                pk = _insn_class(p.instr)
                if p.exec_worker_cycles:
                    pk = "muldiv"
                g = r.issue_cycle - p.issue_cycle
                c = cls_pair.setdefault((pk, ck), [0, 0, 0])
                c[0] += 1
                if g == 1:
                    c[1] += 1
                if r.uid == p.uid + 1:
                    c[2] += 1
                e = pairs.setdefault((p.pc, r.pc),
                                     [0, 0, 0, p.instr, r.instr, pk, ck,
                                      0])
                e[0] += 1
                if g == 1:
                    e[1] += 1
                elif g == 2:
                    e[2] += 1
                if r.uid == p.uid + 1:
                    e[7] += 1
        if (r.rob_info >> ROB_D0_REG_WRITE) & 1 and r.rd:
            last_writer[r.rd] = r

    out = []
    a = out.append
    a("back-to-back dependent pairs (consumer issued producer+1)%s:"
      % (", same-unit only" if same_unit else ""))
    a("")
    a("  by class pair (dependence edges / issued b2b / istream-adjacent):")
    for (pk, ck), (n, b, adj) in sorted(cls_pair.items(),
                                        key=lambda kv: -kv[1][2]):
        if same_unit and pk != ck:
            continue
        a("    %-8s -> %-8s %9s edges  %8s b2b  %8s adjacent" % (
            pk, ck, "{:,}".format(n), "{:,}".format(b),
            "{:,}".format(adj)))
    a("")
    a("  top static pairs by istream adjacency (decode-fusible):")
    a("    %-10s %-10s  %-10s %-10s %-13s %7s %7s %6s %6s %6s" % (
        "prod pc", "insn", "cons pc", "insn", "classes", "edges",
        "b2b", "b2b%", "gap2", "adj"))
    rows = [(k, v) for k, v in pairs.items()
            if not same_unit or v[5] == v[6]]
    for (ppc, cpc), (n, b, near, pi, ci, pk, ck, adj) in sorted(
            rows, key=lambda kv: (-kv[1][7], -kv[1][1]))[:top]:
        a("    %-10x %08x   %-10x %08x   %-13s %7s %7s %5.1f%% %6s %6s" % (
            ppc, pi, cpc, ci, "%s->%s" % (pk, ck), "{:,}".format(n),
            "{:,}".format(b), _pct(b, n), "{:,}".format(near),
            "{:,}".format(adj)))
    a("")
    a("  (b2b = chained in this trace; gap2 = one cycle short; adj = "
      "adjacent in program order -- decode-fusible)")
    return "\n".join(out)


def bubbles_report(trace, phases=10, width=3):
    """Where pipeline width is lost, and why -- one unified view.

    An issue bubble is an unused issue slot (width x span minus EXEC
    FIREs); a retire bubble is a zero-retire cycle.  Issue attribution
    is the program-oldest WAITing scheduler entry that cycle, which
    also names the *instruction* the machine was stuck behind, so the
    top blockers get a PC.  The phase table says where in the run the
    bubbles live; the PC table says where in the program.
    """
    from .model import NO_UID
    lo, hi = trace.min_cycle, trace.max_cycle
    span = trace.n_cycles
    ic, sc, insns = trace.issue_counts, trace.sched_cycles, trace.insns

    total_slots = width * span
    used = sum(ic.values())
    lost_by = {}                   # reason code or label -> slots
    per_pc = {}                    # pc -> [slots, cycles, {reason: slots}, r]
    ph_lost = [0] * phases         # lost slots per phase
    ph_used = [0] * phases
    ph_reason = [dict() for _ in range(phases)]
    zero_cycles = partial_cycles = 0
    for c in range(lo, hi + 1):
        issued = ic.get(c, 0)
        p = min((c - lo) * phases // span, phases - 1)
        ph_used[p] += issued
        lost = width - issued
        if lost <= 0:
            continue
        if issued == 0:
            zero_cycles += 1
        else:
            partial_cycles += 1
        info = sc.get(c)
        if info is None:
            key = "(scheduler empty)"
        elif info[0] == NO_UID:
            key = "(all READY: width/arbitration)"
        else:
            key = info[1]
        lost_by[key] = lost_by.get(key, 0) + lost
        ph_lost[p] += lost
        ph_reason[p][key] = ph_reason[p].get(key, 0) + lost
        if info is not None and info[0] != NO_UID:
            r = insns.get(info[0])
            if r is not None:
                e = per_pc.get(r.pc)
                if e is None:
                    e = per_pc[r.pc] = [0, 0, {}, r]
                e[0] += lost
                e[1] += 1
                e[2][info[1]] = e[2].get(info[1], 0) + lost

    def rname(key):
        return key if isinstance(key, str) else reason_name(key)

    out = []
    a = out.append
    a("bubble report (span {:,} cycles, issue width {}):".format(
        span, width))
    a("")
    a("issue slots: {:,} total, {:,} used ({:.1f}%), {:,} lost "
      "({:,} zero-issue cycles, {:,} partial)".format(
          total_slots, used, _pct(used, total_slots), total_slots - used,
          zero_cycles, partial_cycles))
    a("  lost slots by the oldest waiting entry's reason:")
    for key, n in sorted(lost_by.items(), key=lambda kv: -kv[1]):
        a("    %-30s %9s  (%5.1f%%)" % (
            rname(key), "{:,}".format(n), _pct(n, total_slots - used)))
    a("")
    a("  top blocker instructions (the entry the machine was stuck "
      "behind):")
    a("    %-10s %-10s %-7s %9s %8s  %s" % (
        "pc", "instr", "class", "slots", "cycles", "dominant reason"))
    top = sorted(per_pc.items(), key=lambda kv: -kv[1][0])[:12]
    for pc, (slots, cycles, reasons, r) in top:
        dk, dn = max(reasons.items(), key=lambda kv: kv[1])
        a("    %-10x %08x   %-7s %9s %8s  %s %d%%" % (
            pc, r.instr, _insn_class(r.instr), "{:,}".format(slots),
            "{:,}".format(cycles), rname(dk), 100 * dn // slots))

    # -- retire side --------------------------------------------------
    rc, rhc = trace.retire_counts, trace.rob_head_cycles
    head_by = {}
    head_pc = {}
    zero = 0
    for c in range(lo, hi + 1):
        if rc.get(c, 0):
            continue
        zero += 1
        info = rhc.get(c)
        if info is None:
            head_by["(ROB empty)"] = head_by.get("(ROB empty)", 0) + 1
            continue
        uid, state = info
        r = insns.get(uid)
        cls = ("store" if r is not None and r.is_store else
               "load" if r is not None and r.is_load else
               "branch" if r is not None and r.is_branch else
               "jump" if r is not None and r.is_jump else "other")
        key = ("head %s, %s" % (cls, "incomplete" if state == 10
                                else "complete (backpressure)"))
        head_by[key] = head_by.get(key, 0) + 1
        if state == 10 and r is not None:
            e = head_pc.get(r.pc)
            if e is None:
                e = head_pc[r.pc] = [0, r]
            e[0] += 1
    a("")
    a("retire: {:,} zero-retire cycles ({:.1f}% of span), by ROB head:"
      .format(zero, _pct(zero, span)))
    for key, n in sorted(head_by.items(), key=lambda kv: -kv[1]):
        a("    %-32s %8s  (%5.1f%%)" % (key, "{:,}".format(n),
                                        _pct(n, zero)))
    a("  top head instructions (incomplete at the head, zero-retire "
      "cycles):")
    for pc, (cycles, r) in sorted(head_pc.items(),
                                  key=lambda kv: -kv[1][0])[:8]:
        a("    %-10x %08x   %-7s %8s" % (
            pc, r.instr, _insn_class(r.instr), "{:,}".format(cycles)))

    # -- frontend delivery --------------------------------------------
    dc = trace.decode_cand
    fe = [0] * (width + 1)
    for c in range(lo, hi + 1):
        fe[min(dc.get(c, 0), width)] += 1
    a("")
    a("frontend delivery (decode candidates present per cycle):")
    for n, cyc in enumerate(fe):
        label = "%d%s" % (n, "+" if n == width else "")
        a("    %-3s %9s  (%5.1f%%)" % (label, "{:,}".format(cyc),
                                       _pct(cyc, span)))

    # -- where in the run ----------------------------------------------
    a("")
    a("phases (issue-slot usage across the run):")
    a("    %-5s %-17s %6s %10s  %s" % ("phase", "cycles", "used%",
                                       "lost", "dominant loss"))
    for p in range(phases):
        c0 = lo + span * p // phases
        c1 = lo + span * (p + 1) // phases - 1
        ncyc = c1 - c0 + 1
        slots = ncyc * width
        dom = ""
        if ph_reason[p]:
            dk, dn = max(ph_reason[p].items(), key=lambda kv: kv[1])
            dom = "%s %d%%" % (rname(dk), 100 * dn // max(ph_lost[p], 1))
        a("    %-5d %8d..%-8d %5.1f%% %10s  %s" % (
            p, c0, c1, _pct(ph_used[p], slots),
            "{:,}".format(ph_lost[p]), dom))
    return "\n".join(out)


def control_report(trace, hist=False):
    """Control-transfer characterization: branches, JAL, JALR.

    'fetched ahead' = the next retired instruction's first fetch precedes
    this control op's completion, i.e. correct-path fetch ran ahead of
    resolution (frontend prediction worked).  Head-wait is scheduler
    cycles under RETIRE_HEAD_REQUIRED (reason 6).

    The refetch detail measures the redirect path itself on the ops
    that missed: complete -> correct-path fetch is the machinery cost
    (0-1 = redirect at complete), fetch -> refetch is the full penalty
    including the operand wait that delayed resolution, and the shadow
    is the wrong-path work thrown away.  hist=True adds histograms,
    including fetch -> complete for every branch (how long each one
    keeps its speculation shadow open).
    """
    import bisect
    retired = sorted((r.uid, r) for r in trace.insns.values() if r.retired)
    index = {u: i for i, (u, _) in enumerate(retired)}
    squashed = sorted(r.uid for r in trace.insns.values() if not r.retired)

    def klass(r):
        op = r.instr & 0x7F
        if op == 0x63:
            return "branch"
        if op == 0x6F:
            return "jal"
        if op == 0x67:
            rd = (r.instr >> 7) & 31
            rs1 = (r.instr >> 15) & 31
            if rd == 0 and rs1 == 1:
                return "jalr.ret"
            if rd == 1:
                return "jalr.call"
            return "jalr.other"
        return None

    stats = {}
    for u, r in retired:
        k = klass(r)
        if k is None:
            continue
        s = stats.setdefault(k, {"n": 0, "ahead": 0, "refetch": 0,
                                 "headwait": [], "shadow_squash": 0,
                                 "c2f": [], "r2f": [], "pen": [],
                                 "shadow": []})
        s["n"] += 1
        if r.sched_wait_reasons:
            w = r.sched_wait_reasons.get(6, 0)
            if w:
                s["headwait"].append(w)
        i = index[u]
        if i + 1 < len(retired):
            nu, nr = retired[i + 1]
            shadow = (bisect.bisect_left(squashed, nu)
                      - bisect.bisect_right(squashed, u))
            if (nr.fetch_first_cycle is not None
                    and r.complete_cycle is not None):
                if nr.fetch_first_cycle < r.complete_cycle:
                    s["ahead"] += 1
                else:
                    s["refetch"] += 1
                    s["c2f"].append(nr.fetch_first_cycle - r.complete_cycle)
                    if r.retire_cycle is not None:
                        s["r2f"].append(nr.fetch_first_cycle
                                        - r.retire_cycle)
                    if r.fetch_first_cycle is not None:
                        s["pen"].append(nr.fetch_first_cycle
                                        - r.fetch_first_cycle)
                    s["shadow"].append(shadow)
            s["shadow_squash"] += shadow

    out = ["control-transfer characterization (retired):"]
    a = out.append
    a("  %-10s %7s  %14s  %8s  %22s  %12s" % (
        "class", "count", "fetched-ahead", "refetch",
        "head-wait n/mean/max", "shadow-squash"))
    for k in ("branch", "jal", "jalr.call", "jalr.ret", "jalr.other"):
        s = stats.get(k)
        if not s:
            continue
        hw = s["headwait"]
        hws = ("%d/%.1f/%d" % (len(hw), sum(hw) / len(hw), max(hw))
               if hw else "0/-/-")
        pred = s["ahead"] + s["refetch"]
        a("  %-10s %7s  %6s (%5.1f%%)  %8s  %22s  %12s" % (
            k, "{:,}".format(s["n"]), "{:,}".format(s["ahead"]),
            100.0 * s["ahead"] / pred if pred else 0.0,
            "{:,}".format(s["refetch"]), hws,
            "{:,}".format(s["shadow_squash"])))
    a("")
    a("  total squashed uids in run: {:,}".format(len(squashed)))
    a("  (shadow-squash: squashed uids between this op and the next")
    a("   retired one -- wrong-path work in its speculation shadow)")

    def _p(vals):
        if not vals:
            return "-"
        vs = sorted(vals)
        n = len(vs)
        return "%d/%.1f/%d" % (vs[n // 2], sum(vs) / float(n), vs[-1])

    a("")
    a("  refetch detail (mispredicted / resolved-late ops):")
    a("  %-10s %6s  %16s  %16s  %16s  %14s" % (
        "class", "n", "complete->fetch", "retire->fetch",
        "fetch->refetch", "shadow uids"))
    a("  %-10s %6s  %16s  %16s  %16s  %14s" % (
        "", "", "p50/mean/max", "p50/mean/max", "p50/mean/max",
        "p50/mean/max"))
    for k in ("branch", "jal", "jalr.call", "jalr.ret", "jalr.other"):
        s = stats.get(k)
        if not s or not s["c2f"]:
            continue
        a("  %-10s %6d  %16s  %16s  %16s  %14s" % (
            k, len(s["c2f"]), _p(s["c2f"]), _p(s["r2f"]), _p(s["pen"]),
            _p(s["shadow"])))
    a("  (complete->fetch ~0-1 = the redirect fires at completion;")
    a("   the rest of fetch->refetch is the wait for operands)")

    if hist:
        br = [r for _, r in retired if (r.instr & 0x7F) == 0x63
              and r.complete_cycle is not None
              and r.fetch_first_cycle is not None]
        a("")
        a("  branch fetch -> complete histogram (all retired branches --")
        a("  how long each keeps its speculation shadow open):")
        out.extend(_hist_lines(
            [r.complete_cycle - r.fetch_first_cycle for r in br]))
        for k in ("branch", "jalr.ret"):
            s = stats.get(k)
            if not s or not s["c2f"]:
                continue
            a("")
            a("  %s fetch -> refetch histogram (full mispredict penalty):"
              % k)
            out.extend(_hist_lines(s["pen"]))
    return "\n".join(out)


def src1_report(trace):
    """SRC-dependence provenance via architectural register tracking.

    The trace's blocker_id is zero on most SRC rows, so instead walk
    retired instructions in uid (program) order keeping a last-writer
    map per architectural register (rd + reg-write bit from ROB
    detail0).  For each retired instruction that waited on SRC1/SRC2,
    the producer is the last older retired writer of that source
    register -- exact for retired consumers, since their true producers
    also retired.

    Slack definitions (consumer c, producer p):
      issue gap    = c.issue - p.issue     (ALU producer ideal: +1)
      wakeup slack = c.issue - p.complete  (<=0: woke ahead of the
                                            completion event, forwarded)
    """
    from .model import ROB_D0_REG_WRITE
    retired = sorted((r.uid, r) for r in trace.insns.values()
                     if r.retired and r.rob_info is not None)
    last_writer = [None] * 32
    per = {}
    consumer = {}
    gaps_alu = {}
    unresolved = 0
    blocked = 0
    total_wait = 0
    for uid, r in retired:
        d = r.sched_wait_reasons
        if d:
            w1 = d.get(1, 0) + d.get(3, 0)
            w2 = d.get(2, 0)
            if w1 or w2:
                blocked += 1
                total_wait += w1 + w2
                ck = _insn_class(r.instr)
                consumer[ck] = consumer.get(ck, 0) + w1 + w2
                for w, reg in ((w1, r.rs1), (w2, r.rs2)):
                    if not w or not reg:
                        continue
                    p = last_writer[reg]
                    if p is None:
                        unresolved += 1
                        continue
                    pk = _insn_class(p.instr)
                    if p.exec_worker_cycles:
                        pk = "muldiv"
                    s = per.setdefault(pk, {"n": 0, "wait": 0,
                                            "gap": [], "slack": []})
                    s["n"] += 1
                    s["wait"] += w
                    if (r.issue_cycle is not None
                            and p.issue_cycle is not None):
                        g = r.issue_cycle - p.issue_cycle
                        s["gap"].append(g)
                        if pk == "alu" and _insn_class(r.instr) == "alu":
                            gaps_alu[min(g, 8)] = \
                                gaps_alu.get(min(g, 8), 0) + 1
                    if (r.issue_cycle is not None
                            and p.complete_cycle is not None):
                        s["slack"].append(r.issue_cycle - p.complete_cycle)
        # Update the writer map after consuming: program order.
        if (r.rob_info >> ROB_D0_REG_WRITE) & 1 and r.rd:
            last_writer[r.rd] = r

    def pcts(vals):
        if not vals:
            return "-"
        vs = sorted(vals)
        n = len(vs)
        return "%d/%d/%d" % (vs[n // 2], vs[n * 9 // 10], vs[-1])

    out = []
    a = out.append
    a("SRC-dependence provenance, retired insns, architectural tracking")
    a("(%s insns waited on sources, %s wait cycles):" % (
        "{:,}".format(blocked), "{:,}".format(total_wait)))
    a("")
    a("by PRODUCER class:")
    a("  %-8s %7s %10s  %19s  %19s" % (
        "class", "deps", "wait-cyc", "issue-gap p50/90/mx",
        "wakeup p50/90/mx"))
    for k, s in sorted(per.items(), key=lambda kv: -kv[1]["wait"]):
        a("  %-8s %7s %10s  %19s  %19s" % (
            k, "{:,}".format(s["n"]), "{:,}".format(s["wait"]),
            pcts(s["gap"]), pcts(s["slack"])))
    if unresolved:
        a("  (unresolved: %s dep edges with no older retired writer)"
          % "{:,}".format(unresolved))
    a("")
    a("by CONSUMER class (who spends the wait):")
    for k, w in sorted(consumer.items(), key=lambda kv: -kv[1]):
        a("  %-8s %10s cyc  (%5.1f%%)" % (k, "{:,}".format(w),
                                          _pct(w, total_wait)))
    a("")
    a("ALU->ALU dependent issue-gap histogram (ideal +1):")
    for g in sorted(gaps_alu):
        a("    %s%d: %7s" % ("+" if g < 8 else ">=", g,
                             "{:,}".format(gaps_alu[g])))
    return "\n".join(out)


def chains_report(trace, restart_penalty=5):
    """Dependency-chain analysis over the retired stream.

    Edges: true register deps (rs1/rs2 use bits, ROB detail0) plus
    store->load same-address (8-byte) deps.  Depth is latency-weighted
    with intrinsic latencies (ALU/branch/jump/store 1, load 3, muldiv
    actual), ideal wakeup.  Also reports idealized schedule bounds:
    what the same insns could do with infinite/3-wide issue, and with
    the measured mispredict-like restarts.
    """
    from .model import ROB_D0_REG_WRITE
    retired = sorted((r.uid, r) for r in trace.insns.values()
                     if r.retired and r.rob_info is not None)
    n = len(retired)
    if not n:
        return "no retired instructions with ROB info"

    CLS = ("alu", "load", "store", "branch", "jump", "muldiv", "other")
    cidx = {k: i for i, k in enumerate(CLS)}

    def lat_of(r, k):
        if k == "load":
            return 3
        if k == "muldiv":
            if r.complete_cycle is not None and r.issue_cycle is not None:
                return max(1, r.complete_cycle - r.issue_cycle)
            return 4
        return 1

    lastw = [None] * 32       # reg -> (depth_cyc, hops, node_index)
    lastst = {}               # addr8 -> (depth_cyc, hops, node_index)
    depth_cyc = [0] * n
    hops = [0] * n
    comp = [None] * n         # class counts along the argmax path
    parent = [-1] * n
    roots = 0
    for i, (u, r) in enumerate(retired):
        k = _insn_class(r.instr)
        best = None
        info = r.rob_info
        if (info >> 25) & 1 and r.rs1 and lastw[r.rs1] is not None:
            best = lastw[r.rs1]
        if (info >> 26) & 1 and r.rs2 and lastw[r.rs2] is not None:
            c = lastw[r.rs2]
            if best is None or c[0] > best[0]:
                best = c
        if k == "load" and r.mem_vaddr is not None:
            c = lastst.get(r.mem_vaddr >> 3)
            if c is not None and (best is None or c[0] > best[0]):
                best = c
        lat = lat_of(r, k)
        if best is None:
            roots += 1
            depth_cyc[i] = lat
            hops[i] = 1
            comp[i] = [0] * len(CLS)
        else:
            depth_cyc[i] = best[0] + lat
            hops[i] = retired_hops = hops[best[2]] + 1
            comp[i] = list(comp[best[2]])
            parent[i] = best[2]
        comp[i][cidx.get(k, len(CLS) - 1)] += 1
        me = (depth_cyc[i], hops[i], i)
        if (info >> ROB_D0_REG_WRITE) & 1 and r.rd:
            lastw[r.rd] = me
        if k == "store" and r.mem_vaddr is not None:
            lastst[r.mem_vaddr >> 3] = me

    out = []
    a = out.append
    a("dependency-chain analysis (retired stream, %s insns, "
      "%s roots):" % ("{:,}".format(n), "{:,}".format(roots)))
    a("")
    hs = sorted(hops)
    ds = sorted(depth_cyc)
    a("chain depth ending at each insn:")
    a("  hops:   p50=%d  p90=%d  p99=%d  max=%d" % (
        hs[n // 2], hs[n * 9 // 10], hs[n * 99 // 100], hs[-1]))
    a("  cycles: p50=%d  p90=%d  p99=%d  max=%d  (latency-weighted)" % (
        ds[n // 2], ds[n * 9 // 10], ds[n * 99 // 100], ds[-1]))
    a("")

    # Composition of the deep chains (insns in the top depth decile).
    cut = ds[n * 9 // 10]
    agg = [0] * len(CLS)
    for i in range(n):
        if depth_cyc[i] >= cut:
            for j, v in enumerate(comp[i]):
                agg[j] += v
    tot = sum(agg) or 1
    a("class mix along the longest paths of top-decile-depth insns:")
    for j, k in enumerate(CLS):
        if agg[j]:
            a("  %-7s %5.1f%%" % (k, 100.0 * agg[j] / tot))
    a("")

    # Reconstruct the single deepest chain.
    i = max(range(n), key=lambda x: depth_cyc[x])
    chain = []
    while i >= 0 and len(chain) < 200000:
        chain.append(i)
        i = parent[i]
    chain.reverse()
    a("deepest chain: %d hops, %d cycles; composition:" % (
        len(chain), depth_cyc[chain[-1]]))
    cc = {}
    for i in chain:
        k = _insn_class(retired[i][1].instr)
        cc[k] = cc.get(k, 0) + 1
    a("  " + "   ".join("%s=%d" % (k, v)
                        for k, v in sorted(cc.items(), key=lambda kv: -kv[1])))
    a("  first/last hops (pc):")
    for i in chain[:4]:
        r = retired[i][1]
        a("    %x %08x (%s)" % (r.pc, r.instr, _insn_class(r.instr)))
    a("    ...")
    for i in chain[-4:]:
        r = retired[i][1]
        a("    %x %08x (%s)" % (r.pc, r.instr, _insn_class(r.instr)))
    a("")

    # Parallelism profile: insns per depth-cycle level, summarized.
    width_at = {}
    for d in depth_cyc:
        width_at[d] = width_at.get(d, 0) + 1
    ws = sorted(width_at.values())
    m = len(ws)
    a("dataflow parallelism (insns per depth level, %d levels):" % m)
    a("  p10=%d  p50=%d  p90=%d  max=%d   mean=%.1f" % (
        ws[m // 10], ws[m // 2], ws[m * 9 // 10], ws[-1],
        n / float(m)))
    return "\n".join(out)


def health_report(trace, phases=10, width=3):
    """Bill's three top-level health metrics, per phase.

    frontend: candidates present at the dispatch gate vs capacity.
    issue:    insns issued vs min(width, scheduler entries waiting).
    retire:   insns retired vs min(width, ROB entries waiting).
    Each also reports the fraction of cycles its structure was empty
    (vacuous cycles are excluded from the utilization ratio).
    """
    lo, hi = trace.min_cycle, trace.max_cycle
    span = hi - lo + 1
    edges = [lo + span * i // phases for i in range(phases)] + [hi + 1]

    out = []
    a = out.append
    a("pipeline health (%d phases of ~%s cycles; capacity %d-wide):"
      % (phases, "{:,}".format(span // phases), width))
    a("  %-7s %9s | %6s %6s | %6s %6s | %6s %6s | %s" % (
        "phase", "cycles", "FE%", "FEmt%", "IS%", "ISmt%",
        "RT%", "RTmt%", "weakest"))
    for p in range(phases):
        c0, c1 = edges[p], edges[p + 1]
        n = c1 - c0
        fe_num = fe_den = fe_mt = 0
        is_num = is_den = is_mt = 0
        rt_num = rt_den = rt_mt = 0
        for c in range(c0, c1):
            cand = min(trace.decode_cand.get(c, 0), width)
            fe_num += cand; fe_den += width
            if cand == 0: fe_mt += 1
            so = trace.sched_occ.get(c, 0)
            if so == 0:
                is_mt += 1
            else:
                is_num += min(trace.issue_counts.get(c, 0), width)
                is_den += min(so, width)
            ro = trace.rob_occ.get(c, 0)
            if ro == 0:
                rt_mt += 1
            else:
                rt_num += min(trace.retire_counts.get(c, 0), width)
                rt_den += min(ro, width)
        fe = 100.0 * fe_num / fe_den if fe_den else 0.0
        is_ = 100.0 * is_num / is_den if is_den else 0.0
        rt = 100.0 * rt_num / rt_den if rt_den else 0.0
        scores = {"frontend": fe, "issue": is_, "retire": rt}
        weakest = min(scores, key=scores.get)
        a("  %-7d %9s | %5.1f %6.1f | %5.1f %6.1f | %5.1f %6.1f | %s" % (
            p, "{:,}".format(n), fe, 100.0 * fe_mt / n,
            is_, 100.0 * is_mt / n, rt, 100.0 * rt_mt / n, weakest))
    a("")
    a("FE%%  = candidates at dispatch gate / %d (delivery vs capacity)"
      % width)
    a("IS%% = issued / min(%d, scheduler waiting); RT%% = retired / "
      "min(%d, ROB waiting)" % (width, width))
    a("*mt%% = cycles that structure was empty (excluded from its ratio)")
    return "\n".join(out)
