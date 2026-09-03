"""Command line: assemble a graph, clock it, report.

Graph assembly is the only place that knows which implementation of a module
is in use, which is the point -- ``--remote`` and ``--replay`` change the graph
here and nothing else in the tree notices.
"""

import argparse
import os
import shutil
import sys

_TOOLS_SIM = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _TOOLS_SIM not in sys.path:
    sys.path.insert(0, _TOOLS_SIM)

from camsim import timing
from camsim.bus import Bus
from camsim.probe import Const, Recorder, Replayer, Watch
from camsim.wave import Wave
from camsim.remote import hosted


def _maybe_reexec_pypy():
    if "CAMSIM_NO_PYPY" in os.environ:
        return
    if sys.implementation.name == "pypy":
        return
    p = shutil.which("pypy3")
    if p:
        os.environ["CAMSIM_NO_PYPY"] = "1"
        os.environ["PYTHONPATH"] = _TOOLS_SIM + os.pathsep + \
            os.environ.get("PYTHONPATH", "")
        os.execv(p, [p, "-m", "camsim.cli"] + sys.argv[1:])


def build_demo(a):
    from camsim.modules import demo
    from camsim.modules.clock import Clock
    bus = Bus(timing=not a.no_timing, strict=not a.loose)
    bus.add(Clock(reset_steps=a.reset_steps).port())
    if a.replay:
        bus.add(Replayer(a.replay, only=["src.item", "src.done"]))
    else:
        bus.add(demo.Producer(count=a.count))
    if a.remote:
        bus.add(hosted("camsim.modules.demo:Stage", stderr=None))
    else:
        bus.add(demo.Stage())
    if a.ideal_sink:
        bus.add(Const({"sink.ready": True}))
        bus.add(demo.Sink(depth=a.sink_depth, rate=a.sink_rate, name="sink_obs"))
    else:
        bus.add(demo.Sink(depth=a.sink_depth, rate=a.sink_rate))
    if a.record:
        bus.add(Recorder(a.record, ["src.*", "stage.*", "sink.*"]))
    if a.watch:
        bus.add(Watch(["src.*", "stage.*", "sink.*"]))
    if a.wave:
        bus.add(Wave(a.wave, a.wave_signals, step_ticks=a.wave_step))
    return bus


def build_frontend(a, bt):
    """The whole frontend as four units and the signals between them.

    fetch.cands -> decode.ops -> dispatch -> fetch.taken   (all async: one
    same-cycle region, because casim admits what it fetched in the cycle it
    fetched it) and dispatch.sched -> resolve -> redirect  (registered: the
    resolver is separable)."""
    from camsim.modules.clock import Clock
    from camsim.modules.fetch import Fetch
    from camsim.modules.decode import Decode
    from camsim.modules.dispatch import Dispatch
    from camsim.modules.resolve import Resolve
    from camsim.modules.stubs import IdealBackend

    bus = Bus(timing=not getattr(a, "no_timing", False))
    bus.add(Clock(reset_steps=1).port())
    fe = bus.add(Fetch(bt.image, entry_pc=bt.entry_pc or 0, width=a.width,
                       queue_depth=a.queue_depth, block_bytes=a.block_bytes,
                       window_blocks=a.window_blocks, refill=a.refill,
                       present_width=a.decode_width))
    bus.add(Decode())
    dp = bus.add(Dispatch(bt.events, bt.image, width=a.decode_width,
                          resolve_latency=a.resolve_latency, refill=a.refill))
    rs = bus.add(Resolve())
    bus.add(IdealBackend(width=a.decode_width))
    return bus, fe, dp, rs


def run_frontend(a):
    import os
    sys.path.insert(0, os.path.dirname(_TOOLS_SIM))
    from casim import btrace as _bt

    bt = _bt.read(a.btrace)
    bus, fe, dp, rs = build_frontend(a, bt)
    if a.wave:
        from camsim.wave import Wave
        bus.add(Wave(a.wave, a.wave_signals or ["*"]))
    bus.elaborate()
    for w in bus.warnings:
        sys.stderr.write("warning: %s\n" % w)
    if a.graph:
        print(timing.graph(bus))
        print()
        print(timing.regions(bus))
        return 0

    want = bt.arch_count or 0
    bus.run(until=lambda b: (b.cycle >= a.max_cycles or
                             (want and dp.arch_done >= want and not rs.pending)))
    rep = bus.finish()
    span = bus.cycle - 1
    print("%s" % bt.summary() if hasattr(bt, "summary") else "")
    for k in ("fetch", "decode", "dispatch", "resolve"):
        if k in rep:
            print("%-9s %s" % (k, rep[k]))
    print("span     %d cycles, %d architectural of %d, %.4f correct-path IPC"
          % (span, dp.arch_done, want,
             (dp.delivered - dp.wrong_path) / float(max(1, span))))
    print()
    print(timing.report(bus))
    print()
    print(timing.regions(bus))
    return 0


# A worked example rather than a benchmark: a loop, a multiply, a store and a
# load back, so every unit is on the critical path of the answer.
DEMO = ["  addi t0, zero, 0", "  addi t1, zero, 1", "  addi t2, zero, 11",
        "loop:", "  mul  t3, t1, t1", "  add  t0, t0, t3",
        "  addi t1, t1, 1", "  blt  t1, t2, loop",
        "  lui  a1, 0x40100", "  sd   t0, a1, 0", "  ld   a0, a1, 0", "  ecall"]


def run_machine(a):
    """Run the demo program, bare or behind Sv39."""
    from camsim import machine as MA
    from camsim.modules.mtl import PRIV_S

    PA_CODE, PA_DATA, PA_TAB = 0x80000000, 0x80100000, 0x80200000
    VA_CODE, VA_DATA = 0x40000000, 0x40100000
    base = VA_CODE if a.sv39 else PA_CODE
    src = list(DEMO)
    if not a.sv39:
        # by name, not by index: the label line is part of the source list
        src = [("  lui  a1, 0x80100" if "0x40100" in x else x) for x in src]
    words, _ = MA.asm(src, base)
    mem = MA.PhysMem()
    MA.load_program(mem, PA_CODE, words)
    kw = dict(timing=True, mem_latency=a.mem_latency,
              walk_latency=a.walk_latency, rob_depth=a.rob,
              issue_width=a.issue_width)
    if a.sv39:
        mmu = MA.Sv39(mem, PA_TAB).map(VA_CODE, PA_CODE, 4, MA.Sv39.RX) \
                                  .map(VA_DATA, PA_DATA, 4, MA.Sv39.RW)
        m = MA.build(mem, VA_CODE, priv=PRIV_S, satp=mmu.satp(), **kw)
    else:
        m = MA.build(mem, PA_CODE, **kw)
    bus = m["bus"]
    if a.wave:
        from camsim.wave import Wave
        bus.add(Wave(a.wave, ["*"]))
    if a.graph:
        bus.elaborate()
        print(timing.graph(bus))
        print()
        print(timing.regions(bus))
        return 0

    r = MA.run(m, max_cycles=a.max_cycles)
    print("%s, entry %#x" % ("sv39, supervisor" if a.sv39 else "bare, machine mode",
                             base))
    print("halted: %s" % (r["halt"][0] if r["halt"] else "ran out of cycles"))
    print("a0 = %d   (sum of squares 1..10 = 385)" % m["regs"].read(10))
    print("memory at PA %#x = %d" % (PA_DATA, mem.u64(PA_DATA)))
    print("%d cycles, %d retired, %.3f IPC" %
          (r["cycles"], r["retired"], r["retired"] / float(max(1, r["cycles"]))))
    for k in ("ifetch", "issue", "exu", "lsu", "rob", "mtl"):
        if k in r["report"]:
            print("  %-7s %s" % (k, r["report"][k]))
    print()
    print(timing.report(bus))
    return 0


def run_fetch(a):
    """Fetch alone: a real instruction image, an ideal gate, no resolver.

    This is the frontend-only cutoff for one unit -- what fetch can supply
    when nothing downstream is in the way and nothing redirects it.  Control
    flow arrives when the gate and the resolver do."""
    import os
    sys.path.insert(0, os.path.dirname(_TOOLS_SIM))
    from casim import btrace as _bt
    from camsim.modules.clock import Clock
    from camsim.modules.fetch import Fetch, FS_NAMES
    from camsim.modules.stubs import IdealGate, NoRedirect, NoStash

    bt = _bt.read(a.btrace)
    bus = Bus(timing=True)
    bus.add(Clock(reset_steps=1).port())
    fe = bus.add(Fetch(bt.image, entry_pc=bt.entry_pc or 0, width=a.width,
                       queue_depth=a.queue_depth, block_bytes=a.block_bytes,
                       window_blocks=a.window_blocks, refill=a.refill,
                       present_width=a.gate_width))
    gate = bus.add(IdealGate(width=a.gate_width))
    bus.add(NoRedirect())
    bus.add(NoStash())
    if a.wave:
        from camsim.wave import Wave
        bus.add(Wave(a.wave, ["*"]))
    bus.elaborate()
    for w in bus.warnings:
        sys.stderr.write("warning: %s\n" % w)
    if a.graph:
        print(timing.graph(bus))
        print()
        print(timing.regions(bus))
        return 0

    bus.run(steps=a.cycles)
    rep = bus.finish()
    run = bus.cycle - 1                  # cycle 0 is held in reset
    print("image %d bytes of encodings, entry %#x"
          % (len(bt.image), bt.entry_pc or 0))
    print("fetch  %s" % rep["fetch"])
    print("gate   %s" % rep["gate"])
    print("supply %.3f candidates/cycle over %d running cycles"
          % (rep["gate"]["admitted"] / float(max(1, run)), run))
    print()
    print(timing.report(bus))
    return 0


def main(argv=None):
    _maybe_reexec_pypy()
    ap = argparse.ArgumentParser(prog="camsim", description=__doc__)
    sub = ap.add_subparsers(dest="cmd")

    sub.add_parser("check", help="verify the bus honours its own guarantees")

    fe = sub.add_parser("frontend", help="fetch + decode + dispatch + resolve")
    fe.add_argument("btrace", help="branch trace from `casim <golden> --branch-trace`")
    fe.add_argument("--max-cycles", type=int, default=4000000)
    fe.add_argument("--width", type=int, default=3)
    fe.add_argument("--queue-depth", type=int, default=3)
    fe.add_argument("--decode-width", type=int, default=3)
    fe.add_argument("--block-bytes", type=int, default=64)
    fe.add_argument("--window-blocks", type=int, default=4)
    fe.add_argument("--refill", type=int, default=0)
    fe.add_argument("--resolve-latency", type=int, default=None,
                    help="pin every branch resolve to N cycles instead of replaying")
    fe.add_argument("--no-timing", action="store_true")
    fe.add_argument("--wave", metavar="FILE.vcd")
    fe.add_argument("--wave-signals", metavar="GLOB", action="append", default=None)
    fe.add_argument("--graph", action="store_true")

    rn = sub.add_parser("run", help="execute a program on the whole machine")
    rn.add_argument("--sv39", action="store_true",
                    help="run in supervisor mode behind a page table")
    rn.add_argument("--max-cycles", type=int, default=200000)
    rn.add_argument("--mem-latency", type=int, default=2)
    rn.add_argument("--walk-latency", type=int, default=3)
    rn.add_argument("--rob", type=int, default=16)
    rn.add_argument("--issue-width", type=int, default=2)
    rn.add_argument("--wave", metavar="FILE.vcd")
    rn.add_argument("--graph", action="store_true")

    f = sub.add_parser("fetch", help="run the fetch unit alone against an ideal gate")
    f.add_argument("btrace", help="branch trace from `casim <golden> --branch-trace`")
    f.add_argument("--cycles", type=int, default=2000)
    f.add_argument("--width", type=int, default=3)
    f.add_argument("--queue-depth", type=int, default=3)
    f.add_argument("--block-bytes", type=int, default=64)
    f.add_argument("--window-blocks", type=int, default=4)
    f.add_argument("--refill", type=int, default=0)
    f.add_argument("--gate-width", type=int, default=3)
    f.add_argument("--wave", metavar="FILE.vcd")
    f.add_argument("--graph", action="store_true")

    d = sub.add_parser("demo", help="run the toy graph that exercises the protocol")
    d.add_argument("--count", type=int, default=8)
    d.add_argument("--sink-depth", type=int, default=2)
    d.add_argument("--reset-steps", type=int, default=1,
                   help="steps to hold rst_n low before the machine runs")
    d.add_argument("--sink-rate", type=int, default=1,
                   help="sink retires one item every N cycles (backpressure)")
    d.add_argument("--remote", action="store_true",
                   help="run the pipeline stage in a child process")
    d.add_argument("--ideal-sink", action="store_true",
                   help="replace the ready line with a tie-off")
    d.add_argument("--record", metavar="FILE")
    d.add_argument("--replay", metavar="FILE",
                   help="drive the graph from a recording instead of the producer")
    d.add_argument("--watch", action="store_true")
    d.add_argument("--wave", metavar="FILE.vcd", help="dump a VCD waveform")
    d.add_argument("--wave-signals", metavar="GLOB", action="append",
                   default=None, help="restrict the dump (repeatable)")
    d.add_argument("--wave-step", type=int, default=1000,
                   help="VCD time units per step; deltas land inside one")
    d.add_argument("--graph", action="store_true", help="print the wiring and exit")
    d.add_argument("--no-timing", action="store_true")
    d.add_argument("--loose", action="store_true",
                   help="downgrade dangling-subscription errors to warnings")
    d.add_argument("--max-cycles", type=int, default=1000)

    a = ap.parse_args(argv)
    if getattr(a, "wave_signals", None) is None and hasattr(a, "wave_signals"):
        a.wave_signals = ["*"]
    if a.cmd == "check":
        from camsim.selftest import run_checks
        return run_checks()
    if a.cmd == "fetch":
        return run_fetch(a)
    if a.cmd == "frontend":
        return run_frontend(a)
    if a.cmd == "run":
        return run_machine(a)
    if a.cmd != "demo":
        ap.print_help()
        return 1

    bus = build_demo(a).elaborate()
    for w in bus.warnings:
        sys.stderr.write("warning: %s\n" % w)
    if a.graph:
        print(timing.graph(bus))
        return 0

    sink = [m for m in bus.modules if m.name.startswith("sink")][0]
    if a.replay:
        last = [m for m in bus.modules if isinstance(m, Replayer)][0].last_cycle
        done = lambda b: b.cycle > last + 2
    else:
        done = lambda b: len(sink.got) >= a.count
    bus.run(until=lambda b: b.cycle >= a.max_cycles or done(b))
    rep = bus.finish()

    print("span %d cycles" % bus.cycle)
    for k in sorted(rep):
        print("  %-10s %s" % (k, rep[k]))
    print()
    print(timing.report(bus))
    return 0


if __name__ == "__main__":
    sys.exit(main())
