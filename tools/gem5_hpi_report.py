#!/usr/bin/env python3
"""Extract the useful ARM HPI counters from a gem5 stats file."""

from __future__ import annotations

import argparse
from pathlib import Path


def read_stats(path: Path) -> dict[str, float]:
    stats: dict[str, float] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if len(fields) < 2 or fields[0].startswith("-"):
            continue
        try:
            stats[fields[0]] = float(fields[1])
        except ValueError:
            continue
    return stats


def require(stats: dict[str, float], name: str) -> float:
    try:
        return stats[name]
    except KeyError as exc:
        raise SystemExit(f"missing gem5 statistic: {name}") from exc


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("stats", type=Path)
    parser.add_argument("--trace", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    stats = read_stats(args.stats)
    cycles = int(require(stats, "system.cpu_cluster.cpus.numCycles"))
    committed = int(
        require(stats, "system.cpu_cluster.cpus.commitStats0.numInsts")
    )
    fetched = int(require(stats, "system.cpu_cluster.cpus.fetchStats0.numInsts"))
    branches = int(
        require(stats, "system.cpu_cluster.cpus.branchPred.committed_0::total")
    )
    mispredicted = int(
        require(stats, "system.cpu_cluster.cpus.branchPred.mispredicted_0::total")
    )
    icache_misses = int(
        require(stats, "system.cpu_cluster.cpus.icache.demandMisses::total")
    )
    dcache_misses = int(
        require(stats, "system.cpu_cluster.cpus.dcache.demandMisses::total")
    )
    discarded_ops = int(
        require(stats, "system.cpu_cluster.cpus.executeStats0.numDiscardedOps")
    )

    ipc = committed / cycles
    fetch_rate = fetched / cycles
    mispredict_rate = mispredicted / branches
    wrong_path_overhead = (fetched - committed) / committed

    lines = [
        "GEM5 ARM HPI COREMARK-DERIVED LOOP",
        "  model=HPI (2-wide in-order ARMv8-A proxy; not an exact Cortex-A53)",
        "  frequency=1GHz memory=DDR3_1600_8x8/1-channel",
        f"  cycles={cycles}",
        f"  committed_instructions={committed}",
        f"  IPC={ipc:.6f}",
        f"  fetched_instructions={fetched}",
        f"  fetch_rate={fetch_rate:.6f} instructions/cycle",
        f"  fetched_over_committed={wrong_path_overhead:.2%}",
        f"  committed_branches={branches}",
        f"  branch_mispredictions={mispredicted}",
        f"  branch_mispredict_rate={mispredict_rate:.2%}",
        f"  discarded_micro_ops={discarded_ops}",
        f"  l1i_demand_misses={icache_misses}",
        f"  l1d_demand_misses={dcache_misses}",
        f"  stats={args.stats}",
    ]
    if args.trace:
        lines.append(f"  pipeline_trace={args.trace}")
    lines.append(
        "  timing_note=gem5 model cycles; QEMU TCG is used only for functional validation"
    )

    report = "\n".join(lines) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report, encoding="utf-8")
    print(report, end="")


if __name__ == "__main__":
    main()
