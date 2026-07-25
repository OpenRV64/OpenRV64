#!/usr/bin/env python3
"""Report the measured gem5 HPI pointer-chase statistics block."""

from __future__ import annotations

import argparse
from pathlib import Path


BEGIN = "---------- Begin Simulation Statistics ----------"
END = "---------- End Simulation Statistics   ----------"


def read_blocks(path: Path) -> list[dict[str, float]]:
    blocks: list[dict[str, float]] = []
    current: dict[str, float] | None = None
    for line in path.read_text(encoding="utf-8").splitlines():
        if line == BEGIN:
            current = {}
        elif line == END:
            if current is not None:
                blocks.append(current)
            current = None
        elif current is not None:
            fields = line.split()
            if len(fields) >= 2:
                try:
                    current[fields[0]] = float(fields[1])
                except ValueError:
                    pass
    if not blocks:
        raise SystemExit(f"no complete gem5 statistics blocks in {path}")
    return blocks


def require(stats: dict[str, float], name: str) -> float:
    try:
        return stats[name]
    except KeyError as exc:
        raise SystemExit(f"missing gem5 statistic: {name}") from exc


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("stats", type=Path)
    parser.add_argument("--bytes", required=True, type=int)
    parser.add_argument("--stride", required=True, type=int)
    parser.add_argument("--tlb-locality", required=True, type=int)
    parser.add_argument("--steps", required=True, type=int)
    parser.add_argument("--seed", required=True, type=int)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    blocks = read_blocks(args.stats)
    stats = blocks[0]
    cycles = int(require(stats, "system.cpu_cluster.cpus.numCycles"))
    committed = int(
        require(stats, "system.cpu_cluster.cpus.commitStats0.numInsts")
    )
    lines = [
        "GEM5 ARM HPI POINTER CHASE",
        "  model=HPI (2-wide in-order ARMv8-A proxy; not an exact Cortex-A53)",
        "  frequency=1GHz memory=DDR3_1600_8x8/1-channel",
        f"  footprint_bytes={args.bytes}",
        f"  stride_bytes={args.stride}",
        f"  tlb_locality_bytes={args.tlb_locality}",
        f"  dependent_loads={args.steps}",
        f"  seed={args.seed}",
        f"  cycles={cycles}",
        f"  committed_instructions={committed}",
        f"  IPC={committed / cycles:.6f}",
        f"  cycles_per_dependent_load={cycles / args.steps:.6f}",
        f"  instructions_per_dependent_load={committed / args.steps:.6f}",
    ]

    optional_stats = (
        ("l1d_demand_accesses", "system.cpu_cluster.cpus.dcache.demandAccesses::total"),
        ("l1d_demand_misses", "system.cpu_cluster.cpus.dcache.demandMisses::total"),
        ("l1d_overall_accesses", "system.cpu_cluster.cpus.dcache.overallAccesses::total"),
        ("l1d_overall_misses", "system.cpu_cluster.cpus.dcache.overallMisses::total"),
        (
            "l2_demand_accesses",
            "system.cpu_cluster.l2.demandAccesses::cpu_cluster.cpus.data",
        ),
        (
            "l2_demand_misses",
            "system.cpu_cluster.l2.demandMisses::cpu_cluster.cpus.data",
        ),
        ("dram_read_requests", "system.mem_ctrls.readReqs"),
    )
    for label, name in optional_stats:
        if name in stats:
            lines.append(f"  {label}={int(stats[name])}")

    prefetch_prefix = "system.cpu_cluster.cpus.dcache.prefetcher."
    for label, suffix in (
        ("l1d_prefetch_issued", "pfIssued"),
        ("l1d_prefetch_useful", "pfUseful"),
        ("l1d_prefetch_unused", "pfUnused"),
        ("l1d_prefetch_late", "pfLate"),
        ("l1d_demand_misses_not_covered", "demandMshrMisses"),
    ):
        name = prefetch_prefix + suffix
        if name in stats:
            lines.append(f"  {label}={int(stats[name])}")

    lines.extend(
        (
            f"  statistics_blocks={len(blocks)}",
            "  selected_statistics_block=0 (m5 reset/dump delimited kernel)",
            f"  stats={args.stats}",
            "  timing_note=gem5 model cycles; not measured Cortex-A53 silicon",
        )
    )
    report = "\n".join(lines) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report, encoding="utf-8")
    print(report, end="")


if __name__ == "__main__":
    main()
