"""casim command line.

Three ways to run the model, plus the branch trace that connects them:

  python3 tools/casim <golden.csv>
      Backend model, admission anchored to the golden's frontend delivery.
      The original validation mode.

  python3 tools/casim --branch-trace OUT <golden.csv>
      Extract the control-flow record: fetch image plus every redirect the
      machine performed, with its prediction and its resolve latency.

  python3 tools/casim --frontend-only <golden.csv | branch-trace>
      Frontend model with a backend that never backpressures.  How fast
      the frontend can deliver, and what stops it.

  python3 tools/casim --backend-only <golden.csv | branch-trace | stream>
      Backend model fed a frontend stream -- wrong path included -- at
      full width every cycle.  Where the backend suffers once delivery
      stops being the limit.

  python3 tools/casim --coupled <golden.csv>
      Both halves in series: the frontend model's delivery timing drives
      the backend model.  Validation for the pair.
"""

import argparse
import os
import sys

_TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)

from casim.config import Config
from casim.stream import (load_trace, build_stream, read_stream, write_stream,
                          reset_sim, STREAM_MAGIC)
from casim.machine import Machine, backend_report
from casim import btrace, frontend, validate


def _maybe_reexec_pypy():
    if "PIPEVIZ_NO_PYPY" in os.environ or "CASIM_NO_PYPY" in os.environ:
        return
    if sys.implementation.name == "pypy":
        return
    import shutil
    p = shutil.which("pypy3")
    if p:
        os.environ["CASIM_NO_PYPY"] = "1"
        os.environ["PYTHONPATH"] = _TOOLS + os.pathsep + \
            os.environ.get("PYTHONPATH", "")
        os.execv(p, [p, "-m", "casim.cli"] + sys.argv[1:])


def _kind(path):
    """golden CSV, branch trace, or dumped frontend stream."""
    try:
        with open(path) as f:
            head = f.readline()
    except OSError:
        return "csv"
    if btrace.MAGIC in head:
        return "btrace"
    if STREAM_MAGIC in head:
        return "stream"
    return "csv"


def _apply(cfg, args):
    for name, attr in (("ideal_frontend", "ideal_frontend"),
                       ("ideal_sched", "ideal_sched"),
                       ("ideal_rob", "ideal_rob"),
                       ("ideal_prf", "ideal_prf")):
        if getattr(args, name):
            setattr(cfg, attr, True)
    for name, attr in (("sched", "sched_depth"), ("rob", "rob_depth"),
                       ("prf", "phys_regs"),
                       ("retire_width", "retire_width"),
                       ("issue_width", "issue_width"),
                       ("load_lat", "lat_load"),
                       ("fetch_width", "fetch_width"),
                       ("fetch_queue", "fetch_queue_depth"),
                       ("fetch_block", "fetch_block_bytes"),
                       ("fetch_window", "fetch_window_blocks"),
                       ("l1i_refill", "l1i_refill_cycles"),
                       ("resolve_latency", "resolve_latency")):
        v = getattr(args, name)
        if v is not None:
            setattr(cfg, attr, v)
    if args.no_squash:
        cfg.squash_wrong_path = False


def _load(path, need_golden):
    """Return (branch trace, golden stream, gate inputs, span)."""
    if _kind(path) == "btrace":
        bt = btrace.read(path)
        if need_golden:
            sys.stderr.write(
                "casim: %s is a branch trace; per-instruction golden "
                "comparison needs the original CSV\n" % path)
        return bt, [], None, None, bt.golden_span
    sys.stderr.write("loading %s ...\n" % path)
    tr = load_trace(path)
    bt = btrace.from_trace(tr, source=path)
    chain, recs, _ = btrace.architectural_chain(tr)
    golden = build_stream(tr, records=chain)
    arch_uids = set(r.uid for r in chain)
    dc = {r.uid: r.decode_cycle for r in recs if r.decode_cycle is not None}
    shadow_budget = {}
    for r in recs:
        if r.decode_cycle is not None and r.uid not in arch_uids:
            shadow_budget[r.decode_cycle] = \
                shadow_budget.get(r.decode_cycle, 0) + 1
    return bt, golden, (dc, shadow_budget), tr, tr.max_cycle


def _frontend_run(cfg, bt, golden, gate_inputs, realistic_gate):
    """One frontend pass.  `realistic_gate` replays the golden's
    backpressure; otherwise the gate never stalls (frontend-only)."""
    gate = None
    if realistic_gate and gate_inputs is not None:
        dc, shadow_budget = gate_inputs
        gate = frontend.GoldenGate(dc, shadow_admits_per_cycle=shadow_budget)
    fe = frontend.Frontend(cfg, bt, gate=gate, golden_stream=golden)
    res = fe.run()
    if not res.complete:
        sys.stderr.write(
            "casim: WARNING: the frontend run did not deliver the whole "
            "architectural stream (%d of %d) -- the stream below is "
            "truncated\n" % (res.stats["arch_delivered"],
                              res.stats["arch_expected"]))
    return fe, res


def main(argv=None):
    _maybe_reexec_pypy()
    ap = argparse.ArgumentParser(prog="casim")
    ap.add_argument("input", help="golden pipeline-state-v1 CSV, a branch "
                                  "trace, or a dumped frontend stream")
    mode = ap.add_argument_group("modes")
    mode.add_argument("--frontend-only", action="store_true",
                      help="run the frontend against a backend that never "
                           "backpressures; cutoff is the admission gate")
    mode.add_argument("--backend-only", action="store_true",
                      help="feed a frontend stream (wrong path included) to "
                           "the backend at full width every cycle")
    mode.add_argument("--coupled", action="store_true",
                      help="frontend model delivery drives the backend model")
    mode.add_argument("--branch-trace", metavar="OUT",
                      help="write the control-flow record and exit")
    mode.add_argument("--dump-stream", metavar="OUT",
                      help="write the frontend stream the run produced")
    mode.add_argument("--experiments", action="store_true",
                      help="run the bottleneck battery (lift each restriction)")

    ap.add_argument("--validate", action="store_true",
                    help="compare per-instruction cycles against the golden")
    ap.add_argument("--diverge", metavar="FIELD", default=None,
                    help="print first divergences for issue|complete|retire")
    ap.add_argument("--all-insns", action="store_true",
                    help="include wrong-path (scheduled but not retired) work")
    ap.add_argument("--golden-latency", action="store_true",
                    help="replay exact golden exec latencies (isolate scheduling)")
    ap.add_argument("--ideal-stream", action="store_true",
                    help="for --backend-only, take the stream from an "
                         "unbackpressured frontend run instead of one paced "
                         "by the golden")
    ap.add_argument("--resolve-sweep", action="store_true",
                    help="for --frontend-only, also report the frontend with "
                         "fixed branch-resolve latencies")
    ap.add_argument("--no-squash", action="store_true",
                    help="let wrong-path work retire instead of squashing it")

    for f in ("--ideal-frontend", "--ideal-sched", "--ideal-rob", "--ideal-prf"):
        ap.add_argument(f, action="store_true")
    for f, h in (("--sched", "scheduler entries"), ("--rob", "ROB entries"),
                 ("--prf", "physical registers"),
                 ("--retire-width", None), ("--issue-width", None),
                 ("--load-lat", "magic load latency"),
                 ("--fetch-width", "candidates presented per cycle"),
                 ("--fetch-queue", "presentation queue depth"),
                 ("--fetch-block", "L1I fetch block bytes"),
                 ("--fetch-window", "resident fetch blocks"),
                 ("--l1i-refill", "cycles to make a fetch block resident"),
                 ("--resolve-latency", "fixed branch resolve latency; 0 "
                                       "replays the golden's per-branch value")):
        ap.add_argument(f, type=int, default=None, help=h)
    args = ap.parse_args(argv)

    cfg = Config()
    _apply(cfg, args)

    want_golden = not (args.frontend_only or args.backend_only)
    if _kind(args.input) == "stream":
        if not args.backend_only:
            sys.stderr.write("casim: a dumped stream can only be run with "
                             "--backend-only\n")
            return 2
        stream = read_stream(args.input)
        cfg.ideal_frontend = True
        m = Machine(cfg, stream, use_golden_latency=args.golden_latency)
        print(backend_report(m.run(), cfg))
        return 0

    bt, golden, gate_inputs, tr, span = _load(args.input, want_golden)

    if args.branch_trace:
        btrace.write(bt, args.branch_trace)
        print(bt.summary())
        print("\nwrote %s" % args.branch_trace)
        return 0

    if args.frontend_only:
        fe, res = _frontend_run(cfg, bt, golden, gate_inputs, False)
        print(bt.summary())
        print("")
        print(frontend.report(res, cfg, golden_span=span,
                              golden_fetched=bt.golden_fetched,
                              golden_discarded=bt.golden_discarded))
        if args.dump_stream:
            write_stream(res.stream, args.dump_stream, source=args.input)
            print("\nwrote %s (%d instructions)"
                  % (args.dump_stream, len(res.stream)))
        if args.resolve_sweep:
            print("\n== frontend against fixed branch-resolve latency ==")
            print("  %-18s %10s %10s %12s" % ("resolve latency", "span",
                                              "vs replay", "shadow work"))
            base = res.cycles
            for lat in (1, 2, 4, 8, 16, 32):
                c2 = Config()
                _apply(c2, args)
                c2.resolve_latency = lat
                _, r2 = _frontend_run(c2, bt, golden, gate_inputs, False)
                print("  %-18d %10d %+10d %12d" % (
                    lat, r2.cycles, r2.cycles - base, r2.stats["wrong_path"]))
        return 0

    if args.backend_only or args.coupled:
        fe, res = _frontend_run(cfg, bt, golden, gate_inputs,
                                not args.ideal_stream)
        sys.stderr.write("frontend produced %d instructions (%d shadow)\n"
                         % (len(res.stream), res.stats["wrong_path"]))
        if args.dump_stream:
            write_stream(res.stream, args.dump_stream, source=args.input)
        stream = res.stream
        reset_sim(stream)
        if args.backend_only:
            cfg.ideal_frontend = True
        m = Machine(cfg, stream, use_golden_latency=args.golden_latency)
        stats = m.run()
        print(backend_report(
            stats, cfg, golden_span=span,
            label="backend-only run" if args.backend_only else "coupled run"))
        return 0

    # Default: the original admission-anchored backend validation.
    stream = build_stream(tr, retired_only=not args.all_insns)
    sys.stderr.write("stream: %d insns  golden span: %d..%d (%d)\n" % (
        len(stream), tr.min_cycle, tr.max_cycle, tr.n_cycles))

    if args.experiments:
        from casim import experiments
        print(experiments.battery(stream, golden_span=tr.max_cycle))
        return 0

    m = Machine(cfg, stream, use_golden_latency=args.golden_latency)
    stats = m.run()
    print("config: %s%s" % (cfg.describe(),
                            "  [golden-latency]" if args.golden_latency else ""))
    print("pipe util EX0/EX1/MEM0/MEM1 = %s  sched_occ~%s rob_occ~%s" % (
        stats["pipe_util"], stats["sched_occ_avg"], stats["rob_occ_avg"]))
    print(validate.report(stream, stats, golden_span=tr.max_cycle))
    if args.diverge:
        fmap = {"issue": ("s_issue", "g_issue"),
                "complete": ("s_complete", "g_complete"),
                "retire": ("s_retire", "g_retire")}
        sf, gf = fmap.get(args.diverge, ("s_issue", "g_issue"))
        print(validate.first_divergences(stream, sf, gf))
    return 0


if __name__ == "__main__":
    sys.exit(main())
