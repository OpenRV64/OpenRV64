#!/usr/bin/env python3
"""Report the measured gem5 HPI BLAKE2s statistics block."""

from __future__ import annotations

import argparse
from pathlib import Path


BEGIN = "---------- Begin Simulation Statistics ----------"
END = "---------- End Simulation Statistics   ----------"


def read_first_block(path: Path) -> dict[str, float]:
    current: dict[str, float] | None = None
    for line in path.read_text(encoding="utf-8").splitlines():
        if line == BEGIN:
            current = {}
            continue
        if line == END and current is not None:
            return current
        if current is None:
            continue
        fields = line.split()
        if len(fields) < 2:
            continue
        try:
            current[fields[0]] = float(fields[1])
        except ValueError:
            pass
    raise SystemExit(f"no complete gem5 statistics block in {path}")


def require(stats: dict[str, float], name: str) -> float:
    try:
        return stats[name]
    except KeyError as exc:
        raise SystemExit(f"missing gem5 statistic: {name}") from exc


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("stats", type=Path)
    parser.add_argument("--calls", type=int, required=True)
    parser.add_argument("--blocks-per-call", type=int, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    stats = read_first_block(args.stats)
    cycles = int(require(stats, "system.cpu_cluster.cpus.numCycles"))
    instructions = int(
        require(stats, "system.cpu_cluster.cpus.commitStats0.numInsts")
    )
    blocks = args.calls * args.blocks_per_call
    ipc = instructions / cycles

    lines = [
        "GEM5 ARM HPI BLAKE2S",
        "  model=HPI (2-wide in-order ARMv8-A proxy; not Cortex-A53 silicon)",
        "  frequency=1GHz memory=DDR3_1600_8x8/1-channel",
        f"  calls={args.calls}",
        f"  blocks_per_call={args.blocks_per_call}",
        f"  total_blocks={blocks}",
        f"  cycles={cycles}",
        f"  committed_instructions={instructions}",
        f"  IPC={ipc:.6f}",
        f"  cycles_per_block={cycles / blocks:.3f}",
    ]
    for label, name in (
        ("l1i_demand_misses", "system.cpu_cluster.cpus.icache.demandMisses::total"),
        ("l1d_demand_misses", "system.cpu_cluster.cpus.dcache.demandMisses::total"),
    ):
        if name in stats:
            lines.append(f"  {label}={int(stats[name])}")

    report = "\n".join(lines) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report, encoding="utf-8")
    print(report, end="")


if __name__ == "__main__":
    main()
