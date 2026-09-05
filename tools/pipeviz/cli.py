"""Command-line interface for pipeviz."""

import argparse
import os
import sys
import time


def _maybe_reexec_pypy():
    """Re-exec under pypy3 for parse speed unless told not to."""
    if sys.implementation.name == "pypy":
        return
    if os.environ.get("PIPEVIZ_NO_PYPY"):
        return
    from shutil import which
    pypy = which("pypy3")
    if not pypy:
        return
    pkg_dir = os.path.dirname(os.path.abspath(__file__))
    os.environ["PIPEVIZ_NO_PYPY"] = "1"  # belt and braces vs exec loops
    os.execv(pypy, [pypy, pkg_dir] + sys.argv[1:])


def main(argv=None):
    _maybe_reexec_pypy()

    ap = argparse.ArgumentParser(
        prog="pipeviz",
        description="Parse and analyze openrv64-pipeline-state-v1 traces.")
    ap.add_argument("csv", help="trace CSV file")
    ap.add_argument("--stats", action="store_true",
                    help="print basic statistics (cycles, insn counts, "
                         "loads, issue/retire width histograms)")
    ap.add_argument("--loads", action="store_true",
                    help="per-class characterization of loads: timing "
                         "segments, latency modes, wait-reason attribution")
    ap.add_argument("--alu", action="store_true",
                    help="per-class characterization of ALU ops")
    ap.add_argument("--stores", action="store_true",
                    help="per-class characterization of stores")
    ap.add_argument("--muldiv", action="store_true",
                    help="per-class characterization of mul/div ops")
    ap.add_argument("--branches", action="store_true",
                    help="per-class characterization of conditional "
                         "branches (fetch->complete is the resolve time)")
    ap.add_argument("--jumps", action="store_true",
                    help="per-class characterization of JAL/JALR")
    ap.add_argument("--hist", action="store_true",
                    help="add latency histograms to class and control "
                         "reports (sched->issue, issue->complete, "
                         "complete->retire, fetch->retire, refetch)")
    ap.add_argument("--bubbles", action="store_true",
                    help="unified bubble report: lost issue slots and "
                         "zero-retire cycles, attributed by reason, "
                         "blocker PC, and phase of the run")
    ap.add_argument("--wakeup", action="store_true",
                    help="wakeup-tax calculator: waited-on dependence "
                         "edges whose consumer issued exactly one cycle "
                         "after the producer's completion, by producer "
                         "class/latency and consumer PC")
    ap.add_argument("--overlap", action="store_true",
                    help="iteration overlap: period, lifetime, and "
                         "iterations-in-flight, delimited by the "
                         "hottest call site (or --overlap-pc)")
    ap.add_argument("--overlap-pc", type=lambda x: int(x, 16),
                    default=None, metavar="HEX",
                    help="boundary PC for --overlap")
    ap.add_argument("--pairs", action="store_true",
                    help="back-to-back dependent pairs by static PC "
                         "pair: chained/fusion candidates, with "
                         "adjacency and near-miss columns")
    ap.add_argument("--same-unit", action="store_true",
                    help="restrict --pairs to producer/consumer of "
                         "the same class (alu->alu, ...)")
    ap.add_argument("--head", action="store_true",
                    help="retire-head residency: which instructions sit "
                         "at the ROB head, tenure by PC and class, split "
                         "into awaiting-completion vs awaiting-acceptance")
    ap.add_argument("--chains", action="store_true",
                    help="dependency-chain analysis: depth distributions, "
                         "class mix of deep chains, parallelism profile")
    ap.add_argument("--src1", action="store_true",
                    help="SRC-dependence provenance: producer classes, "
                         "wakeup slack, forwarding-gap histograms")
    ap.add_argument("--health", action="store_true",
                    help="three top-level health metrics (frontend/issue/"
                         "retire) per phase")
    ap.add_argument("--phases", type=int, default=10, metavar="N",
                    help="phase count for --health (default 10)")
    ap.add_argument("--control", action="store_true",
                    help="characterize control transfers: prediction "
                         "fetch-ahead rate, head-wait, squash shadows")
    ap.add_argument("--issue-blocked", action="store_true",
                    help="attribute zero/partial-issue cycles to the "
                         "oldest waiting scheduler entry's reason")
    ap.add_argument("--retire-blocked", action="store_true",
                    help="attribute zero-retire cycles via the ROB "
                         "head's state that cycle")
    ap.add_argument("--ssr", action="store_true",
                    help="print row counts by (stage, state, reason)")
    ap.add_argument("--jobs", "-j", type=int, default=0, metavar="N",
                    help="parser worker processes (default: auto from "
                         "file size and CPU count; 1 = serial)")
    ap.add_argument("--quiet", action="store_true",
                    help="suppress parse progress on stderr")
    args = ap.parse_args(argv)

    from .parser import parse_file
    from .stats import (basic_stats, ssr_report, characterize,
                        issue_blocked_report, retire_blocked_report,
                        control_report, src1_report, chains_report,
                        health_report, bubbles_report, head_report,
                        wakeup_report, pairs_report,
                        overlap_report)

    t0 = time.time()
    progress = None
    if not args.quiet and sys.stderr.isatty():
        def progress(rows):
            sys.stderr.write("\rpipeviz: %d rows..." % rows)
            sys.stderr.flush()
    trace = parse_file(args.csv, progress=progress,
                       jobs=args.jobs if args.jobs > 0 else None)
    dt = time.time() - t0
    if not args.quiet:
        if progress is not None:
            sys.stderr.write("\r")
        sys.stderr.write(
            "pipeviz: parsed {:,} rows in {:.1f}s ({}, {} worker{})\n".format(
                trace.rows, dt, sys.implementation.name, trace.parse_jobs,
                "s" if trace.parse_jobs != 1 else ""))

    did_something = False
    if args.stats:
        print(basic_stats(trace))
        did_something = True
    for cls in ("loads", "stores", "alu", "muldiv", "branches", "jumps"):
        if getattr(args, cls):
            if did_something:
                print()
            print(characterize(trace, cls, hist=args.hist))
            did_something = True
    if args.chains:
        if did_something:
            print()
        print(chains_report(trace))
        did_something = True
    if args.src1:
        if did_something:
            print()
        print(src1_report(trace))
        did_something = True
    if args.health:
        if did_something:
            print()
        print(health_report(trace, phases=args.phases))
        did_something = True
    if args.control:
        if did_something:
            print()
        print(control_report(trace, hist=args.hist))
        did_something = True
    if args.bubbles:
        if did_something:
            print()
        print(bubbles_report(trace, phases=args.phases))
        did_something = True
    if args.head:
        if did_something:
            print()
        print(head_report(trace, hist=args.hist))
        did_something = True
    if args.overlap:
        if did_something:
            print()
        print(overlap_report(trace, boundary_pc=args.overlap_pc))
        did_something = True
    if args.pairs:
        if did_something:
            print()
        print(pairs_report(trace, same_unit=args.same_unit))
        did_something = True
    if args.wakeup:
        if did_something:
            print()
        print(wakeup_report(trace))
        did_something = True
    if args.issue_blocked:
        if did_something:
            print()
        print(issue_blocked_report(trace))
        did_something = True
    if args.retire_blocked:
        if did_something:
            print()
        print(retire_blocked_report(trace))
        did_something = True
    if args.ssr:
        if did_something:
            print()
        print(ssr_report(trace))
        did_something = True
    if not did_something:
        print("parsed {:,} rows, {:,} insns, cycles {:,}..{:,} "
              "(try --stats)".format(
                  trace.rows, len(trace.insns),
                  trace.min_cycle, trace.max_cycle))
    return 0
