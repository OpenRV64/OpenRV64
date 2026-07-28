#!/usr/bin/env python3
"""Report m5-delimited gem5 HPI page-free statistics."""

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
    if len(blocks) < 2:
        raise SystemExit(f"expected loop and drain statistics blocks in {path}")
    return blocks


def require(stats: dict[str, float], name: str) -> float:
    try:
        return stats[name]
    except KeyError as exc:
        raise SystemExit(f"missing gem5 statistic: {name}") from exc


def optional_int(stats: dict[str, float], name: str) -> int | None:
    value = stats.get(name)
    return None if value is None else int(value)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("stats", type=Path)
    parser.add_argument("--kernel", required=True, choices=("core", "tail"))
    parser.add_argument("--records", required=True, type=int)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    blocks = read_blocks(args.stats)
    loop = blocks[0]
    drain = blocks[1]
    cpu = "system.cpu_cluster.cpus."
    dcache = cpu + "dcache."
    prefetch = dcache + "prefetcher."

    cycles = int(require(loop, cpu + "numCycles"))
    committed = int(require(loop, cpu + "commitStats0.numInsts"))
    drain_cycles = int(require(drain, cpu + "numCycles"))
    clock_ticks = require(loop, "system.cpu_cluster.clk_domain.clock")
    miss_ticks = require(loop, dcache + "demandMissLatency::total")
    prefetch_issued = optional_int(loop, prefetch + "pfIssued") or 0
    prefetch_useful = optional_int(loop, prefetch + "pfUseful") or 0
    useful_pct = (
        100.0 * prefetch_useful / prefetch_issued if prefetch_issued else 0.0
    )

    lines = [
        "GEM5 ARM HPI PAGEFREE",
        "  model=HPI (2-wide in-order ARMv8-A proxy; not Cortex-A53 silicon)",
        "  comparison=cross-ISA semantic loop; not instruction matched",
        "  frequency=1GHz memory=DDR3_1600_8x8/1-channel",
        f"  kernel={args.kernel}",
        f"  records={args.records}",
        f"  loop_cycles={cycles}",
        f"  committed_instructions={committed}",
        f"  IPC={committed / cycles:.6f}",
        f"  cycles_per_record={cycles / args.records:.6f}",
        f"  post_loop_drain_cycles={drain_cycles}",
        f"  load_instructions={int(require(loop, cpu + 'commitStats0.numLoadInsts'))}",
        f"  store_instructions={int(require(loop, cpu + 'commitStats0.numStoreInsts'))}",
        f"  branch_mispredicts={int(require(loop, cpu + 'branchPred.mispredicted_0::total'))}",
        f"  discarded_ops={int(require(loop, cpu + 'executeStats0.numDiscardedOps'))}",
        f"  l1d_demand_accesses={int(require(loop, dcache + 'demandAccesses::total'))}",
        f"  l1d_demand_misses={int(require(loop, dcache + 'demandMisses::total'))}",
        f"  l1d_demand_miss_service_cycles={miss_ticks / clock_ticks:.0f}",
        f"  l1d_demand_mshr_misses={int(require(loop, dcache + 'demandMshrMisses::total'))}",
        f"  l1d_blocked_no_mshrs={int(require(loop, dcache + 'blockedCycles::no_mshrs'))}",
        f"  l1d_blocked_no_wbuffers={int(require(loop, dcache + 'blockedCycles::no_wbuffers'))}",
        f"  l1d_blocked_no_targets={int(require(loop, dcache + 'blockedCycles::no_targets'))}",
        f"  prefetch_issued={prefetch_issued}",
        f"  prefetch_useful={prefetch_useful}",
        f"  prefetch_useful_pct={useful_pct:.2f}",
        f"  prefetch_late={optional_int(loop, prefetch + 'pfLate') or 0}",
        f"  prefetch_unused={optional_int(loop, prefetch + 'pfUnused') or 0}",
        f"  prefetch_removed_by_demand={optional_int(loop, prefetch + 'pfRemovedDemand') or 0}",
        f"  prefetch_queue_hits={optional_int(loop, prefetch + 'pfBufferHit') or 0}",
        f"  prefetch_span_page={optional_int(loop, prefetch + 'pfSpanPage') or 0}",
        f"  prefetch_useful_span_page={optional_int(loop, prefetch + 'pfUsefulSpanPage') or 0}",
        f"  statistics_blocks={len(blocks)}",
        f"  stats={args.stats}",
    ]

    report = "\n".join(lines) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report, encoding="utf-8")
    print(report, end="")


if __name__ == "__main__":
    main()
