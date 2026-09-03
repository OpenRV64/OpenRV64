"""Bottleneck exploration: lift one restriction at a time, rank the savings.

Answers Bill's question directly -- "shove the frontend stream at the issue
ports and see what clogs, and take restrictions off elsewhere too."  Each
experiment reruns the model with one lever changed and reports the span delta
against the anchored baseline, plus pipe utilisation and occupancy so the
mechanism is visible, not just the number.
"""

import copy

from .config import Config
from .machine import Machine


def _run(stream, mutate):
    cfg = Config()
    mutate(cfg)
    # Fresh sim outputs each run (SInsn carries mutable s_* fields).
    from .stream import reset_sim
    reset_sim(stream)
    m = Machine(cfg, stream)
    return m.run(), cfg


_LEVERS = [
    ("baseline", lambda c: None),
    ("frontend ideal (shove at issue ports)",
     lambda c: setattr(c, "ideal_frontend", True)),
    ("scheduler unbounded", lambda c: setattr(c, "ideal_sched", True)),
    ("ROB unbounded", lambda c: setattr(c, "ideal_rob", True)),
    ("phys regs unbounded", lambda c: setattr(c, "ideal_prf", True)),
    ("issue width 4 (add a pipe)", lambda c: setattr(c, "issue_width", 4)),
    ("retire width 6", lambda c: setattr(c, "retire_width", 6)),
    ("store launch anytime (no LSQ-head gate)",
     lambda c: setattr(c, "store_at_lsq_head", False)),
    ("loads bypass store order (no mem ordering)",
     lambda c: setattr(c, "in_order_memory", False)),
]


def _combo(c):
    c.ideal_frontend = True
    c.ideal_sched = True
    c.ideal_rob = True
    c.ideal_prf = True
    c.issue_width = 4
    c.retire_width = 6


def battery(stream, golden_span=None):
    out = []
    a = out.append
    base_stats, _ = _run(stream, lambda c: None)
    base = base_stats["cycles"]
    a("== bottleneck battery ==  (baseline span %d%s)" % (
        base, "" if golden_span is None else
        ", golden %d, model %+d" % (golden_span, base - golden_span)))
    a("baseline pipe util EX0/EX1/MEM0/MEM1 = %s   sched_occ~%s rob_occ~%s" % (
        base_stats["pipe_util"], base_stats["sched_occ_avg"],
        base_stats["rob_occ_avg"]))
    a("")
    a("  %-42s %8s %9s  %s" % ("lever", "span", "vs base", "pipe util %"))
    rows = []
    for name, mut in _LEVERS[1:]:
        st, _ = _run(stream, mut)
        rows.append((name, st))
    st_all, _ = _run(stream, _combo)
    rows.append(("ALL levers combined", st_all))
    # Rank by savings.
    rows.sort(key=lambda r: r[1]["cycles"])
    for name, st in rows:
        d = st["cycles"] - base
        a("  %-42s %8d %+9d  %s" % (name, st["cycles"], d, st["pipe_util"]))
    a("")
    a("Reading: a large negative 'vs base' means that restriction is binding;")
    a("~0 means it is not what clogs. Pipe util shows where work concentrates")
    a("(EX0=ALU/M/Zbb, EX1=ALU/branch/CSR/sys, MEM0=loads, MEM1=stores).")
    return "\n".join(out)
