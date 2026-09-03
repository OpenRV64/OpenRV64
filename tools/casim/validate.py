"""Compare a simulator run against the golden per-instruction cycles."""

from .stream import CLASS_NAMES, LOAD


def taint_memory(stream, magic_lat=4):
    """Mark instructions whose golden timing is set by real data memory.

    An instruction is memory-tainted if it is a load whose golden
    issue->complete exceeds the magic latency (a real L1D/L2/DRAM access),
    or if any of its source producers is tainted.  Program-order single
    pass; uses the reconstructed src uids.  Returns a set of tainted uids.
    """
    tainted = set()
    by_uid = {s.uid: s for s in stream}
    for s in stream:
        t = False
        if s.klass == LOAD and s.exec_lat is not None and s.exec_lat > magic_lat:
            t = True
        for u in (s.src1_uid, s.src2_uid):
            if u in tainted:
                t = True
                break
        if t:
            tainted.add(s.uid)
    return tainted


def _hist(deltas, lo=-4, hi=4):
    buckets = {}
    for d in deltas:
        k = d if lo <= d <= hi else (lo - 1 if d < lo else hi + 1)
        buckets[k] = buckets.get(k, 0) + 1
    n = len(deltas) or 1
    parts = []
    for k in range(lo - 1, hi + 2):
        if k in buckets:
            lbl = ("<%d" % lo if k == lo - 1 else
                   ">%d" % hi if k == hi + 1 else "%+d" % k)
            parts.append("%s:%.0f%%" % (lbl, 100.0 * buckets[k] / n))
    return "  ".join(parts)


def _pcts(vals):
    if not vals:
        return "-"
    v = sorted(vals)
    n = len(v)
    return "p10=%d p50=%d p90=%d min=%d max=%d" % (
        v[n // 10], v[n // 2], v[min(n - 1, n * 9 // 10)], v[0], v[-1])


def report(stream, sim_stats, golden_span=None, split_taint=True):
    out = []
    a = out.append
    tainted = taint_memory(stream) if split_taint else set()
    a("== casim validation ==")
    if split_taint:
        a("memory-tainted insns (real DDR-latency slice): %d / %d (%.1f%%)" % (
            len(tainted), len(stream), 100.0 * len(tainted) / (len(stream) or 1)))
    a("stream insns: %d   admitted: %d   retired: %d/%d%s" % (
        sim_stats["n"], sim_stats["admitted"], sim_stats["retired"],
        sim_stats["n"], "" if sim_stats["completed_all"]
        else "  (INCOMPLETE)"))
    a("sim span end cycle: %d%s" % (
        sim_stats["cycles"],
        ("   golden: %d   delta: %+d (%.2f%%)" % (
            golden_span, sim_stats["cycles"] - golden_span,
            100.0 * (sim_stats["cycles"] - golden_span) / golden_span)
         if golden_span else "")))
    a("issue-width cycles 0/1/2/3: %s" % sim_stats["issue_hist"])
    a("retire-width cycles 0/1/2/3: %s" % sim_stats["retire_hist"])
    a("")

    # Per-instruction exact match on each milestone.
    for field, sf, gf in (("issue", "s_issue", "g_issue"),
                          ("complete", "s_complete", "g_complete"),
                          ("retire", "s_retire", "g_retire")):
        by_class = {}
        deltas_all = []
        deltas_clean = []
        for s in stream:
            gv = getattr(s, gf)
            sv = getattr(s, sf)
            if gv is None or sv is None:
                continue
            d = sv - gv
            deltas_all.append(d)
            if s.uid not in tainted:
                deltas_clean.append(d)
            k = CLASS_NAMES.get(s.klass, "?")
            by_class.setdefault(k, []).append((d, s.uid in tainted))
        if not deltas_all:
            continue
        exact = sum(1 for d in deltas_all if d == 0)
        a("[%s] n=%d exact=%.1f%%  delta(s-g): %s" % (
            field, len(deltas_all), 100.0 * exact / len(deltas_all),
            _pcts(deltas_all)))
        if split_taint and deltas_clean:
            exc = sum(1 for d in deltas_clean if d == 0)
            w1 = sum(1 for d in deltas_clean if -1 <= d <= 1)
            a("    core-only (untainted) n=%d exact=%.1f%% within1=%.1f%%" % (
                len(deltas_clean), 100.0 * exc / len(deltas_clean),
                100.0 * w1 / len(deltas_clean)))
            a("      hist: %s" % _hist(deltas_clean))
        for k in ("alu", "load", "store", "branch", "jump", "muldiv",
                  "system"):
            ds = by_class.get(k)
            if not ds:
                continue
            clean = [d for d, t in ds if not t]
            ex = sum(1 for d in clean if d == 0) if clean else 0
            a("    %-7s n=%-6d core=%-6d exact=%5.1f%%  %s" % (
                k, len(ds), len(clean),
                100.0 * ex / len(clean) if clean else 0.0,
                _pcts(clean) if clean else "-"))
        a("")
    return "\n".join(out)


def first_divergences(stream, field="s_issue", gfield="g_issue", limit=25):
    out = ["first %d %s divergences (uid pc instr class  sim vs golden):"
           % (limit, field)]
    shown = 0
    for s in sorted(stream, key=lambda s: s.uid):
        gv = getattr(s, gfield)
        sv = getattr(s, field)
        if gv is None or sv is None or sv == gv:
            continue
        out.append("  uid=%#08x pc=%#010x %08x %-6s  sim=%d golden=%d (%+d)"
                   % (s.uid, s.pc, s.instr, CLASS_NAMES.get(s.klass, "?"),
                      sv, gv, sv - gv))
        shown += 1
        if shown >= limit:
            break
    if shown == 0:
        out.append("  (none)")
    return "\n".join(out)
