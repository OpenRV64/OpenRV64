#!/usr/bin/env python3
"""Report the first gem5 statistics block dumped by an HPI STREAM image."""

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
            continue
        if line == END:
            if current is not None:
                blocks.append(current)
            current = None
            continue
        if current is None:
            continue

        fields = line.split()
        if len(fields) < 2:
            continue
        try:
            current[fields[0]] = float(fields[1])
        except ValueError:
            continue

    if not blocks:
        raise SystemExit(f"no complete gem5 statistics blocks in {path}")
    return blocks


def require(stats: dict[str, float], name: str) -> float:
    try:
        return stats[name]
    except KeyError as exc:
        raise SystemExit(f"missing gem5 statistic: {name}") from exc


def optional_int(stats: dict[str, float], name: str) -> int | None:
    value = stats.get(name)
    return None if value is None else int(value)


def optional_float(stats: dict[str, float], name: str) -> float | None:
    return stats.get(name)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("stats", type=Path)
    parser.add_argument("--kernel", required=True, choices=("copy", "scale", "add", "triad"))
    parser.add_argument("--bytes", required=True, type=int)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    blocks = read_blocks(args.stats)
    stats = blocks[0]
    cycles = int(require(stats, "system.cpu_cluster.cpus.numCycles"))
    committed = int(
        require(stats, "system.cpu_cluster.cpus.commitStats0.numInsts")
    )
    ipc = committed / cycles

    streams = {"copy": 2, "scale": 2, "add": 3, "triad": 3}[args.kernel]
    logical_bytes = streams * args.bytes
    bytes_per_cycle = logical_bytes / cycles

    lines = [
        "GEM5 ARM HPI INTEGER STREAM",
        "  model=HPI (2-wide in-order ARMv8-A proxy; not an exact Cortex-A53)",
        "  l1d_prefetcher=StridePrefetcher queue_size=4 degree=4",
        "  frequency=1GHz memory=DDR3_1600_8x8/1-channel",
        f"  kernel={args.kernel}",
        f"  bytes_per_array={args.bytes}",
        f"  logical_stream_bytes={logical_bytes}",
        f"  cycles={cycles}",
        f"  committed_instructions={committed}",
        f"  IPC={ipc:.6f}",
        f"  logical_bytes_per_cycle={bytes_per_cycle:.6f}",
        f"  logical_bandwidth_at_1GHz={bytes_per_cycle:.6f} GB/s",
    ]

    optional_stats = (
        ("l1i_demand_accesses", "system.cpu_cluster.cpus.icache.demandAccesses::total"),
        ("l1i_demand_misses", "system.cpu_cluster.cpus.icache.demandMisses::total"),
        ("l1d_demand_accesses", "system.cpu_cluster.cpus.dcache.demandAccesses::total"),
        ("l1d_demand_misses", "system.cpu_cluster.cpus.dcache.demandMisses::total"),
        ("l1d_overall_accesses", "system.cpu_cluster.cpus.dcache.overallAccesses::total"),
        ("l1d_overall_misses", "system.cpu_cluster.cpus.dcache.overallMisses::total"),
    )
    for label, name in optional_stats:
        value = optional_int(stats, name)
        if value is not None:
            lines.append(f"  {label}={value}")

    prefetch_stats = (
        ("l1d_prefetch_issued", "pfIssued"),
        ("l1d_prefetch_useful", "pfUseful"),
        ("l1d_prefetch_unused", "pfUnused"),
        ("l1d_prefetch_late", "pfLate"),
        ("l1d_demand_misses_not_covered", "demandMshrMisses"),
    )
    prefetch_prefix = "system.cpu_cluster.cpus.dcache.prefetcher."
    for label, suffix in prefetch_stats:
        value = optional_int(stats, prefetch_prefix + suffix)
        if value is not None:
            lines.append(f"  {label}={value}")

    for label, suffix in (
        ("l1d_prefetch_accuracy", "accuracy"),
        ("l1d_prefetch_coverage", "coverage"),
    ):
        value = optional_float(stats, prefetch_prefix + suffix)
        if value is not None:
            lines.append(f"  {label}={value:.6f}")

    lines.extend(
        (
            f"  statistics_blocks={len(blocks)}",
            "  selected_statistics_block=0 (m5 reset/dump delimited kernel)",
            f"  stats={args.stats}",
            "  timing_note=gem5 model cycles with modeled caches and DDR; not silicon timing",
        )
    )

    report = "\n".join(lines) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report, encoding="utf-8")
    print(report, end="")


if __name__ == "__main__":
    main()
