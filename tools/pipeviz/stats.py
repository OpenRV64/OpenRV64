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
}


def characterize(trace, want):
    """Per-class characterization report.  want: one of CLASSES."""
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

    a("")
    a("timing segments, retired %s (cycles):" % want)
    a(_lat_line("fetch -> decode",
                seg(lambda r: r.fetch_first_cycle,
                    lambda r: r.decode_cycle)))
    a(_lat_line("decode -> sched entry",
                seg(lambda r: r.decode_cycle,
                    lambda r: r.sched_enter_cycle)))
    a(_lat_line("sched entry -> issue",
                seg(lambda r: r.sched_enter_cycle,
                    lambda r: r.issue_cycle)))
    a(_lat_line("issue -> complete",
                seg(lambda r: r.issue_cycle,
                    lambda r: r.complete_cycle)))
    a(_lat_line("complete -> retire",
                seg(lambda r: r.complete_cycle,
                    lambda r: r.retire_cycle)))
    a(_lat_line("fetch -> retire (total)",
                seg(lambda r: r.fetch_first_cycle,
                    lambda r: r.retire_cycle)))

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


def control_report(trace):
    """Control-transfer characterization: branches, JAL, JALR.

    'fetched ahead' = the next retired instruction's first fetch precedes
    this control op's completion, i.e. correct-path fetch ran ahead of
    resolution (frontend prediction worked).  Head-wait is scheduler
    cycles under RETIRE_HEAD_REQUIRED (reason 6).
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
                                 "headwait": [], "shadow_squash": 0})
        s["n"] += 1
        if r.sched_wait_reasons:
            w = r.sched_wait_reasons.get(6, 0)
            if w:
                s["headwait"].append(w)
        i = index[u]
        if i + 1 < len(retired):
            nu, nr = retired[i + 1]
            if (nr.fetch_first_cycle is not None
                    and r.complete_cycle is not None):
                if nr.fetch_first_cycle < r.complete_cycle:
                    s["ahead"] += 1
                else:
                    s["refetch"] += 1
            s["shadow_squash"] += (bisect.bisect_left(squashed, nu)
                                   - bisect.bisect_right(squashed, u))

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
