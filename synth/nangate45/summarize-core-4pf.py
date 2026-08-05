#!/usr/bin/env python3
"""Summarize a partitioned Nangate45 map of the cacheless 4PF core."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


TOP = "openrv64_top_4pf"
CELL_RE = re.compile(r"^\s*cell\s*\(\s*([^\s)]+)", re.MULTILINE)
DELAY_RE = re.compile(r"Delay\s*=\s*([0-9.]+)\s*ps")


def canonical(name: str) -> str:
    return name[1:] if name.startswith("\\") else name


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--variant", choices=("fd", "nofd"), required=True)
    parser.add_argument(
        "--register-issue-select", type=int, choices=(0, 1), default=0
    )
    parser.add_argument("--stat", type=Path, required=True)
    parser.add_argument("--liberty", type=Path, required=True)
    parser.add_argument("--worker-dir", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()

    data = json.loads(args.stat.read_text())
    modules = {canonical(name): stats for name, stats in data["modules"].items()}
    if TOP not in modules:
        raise ValueError(f"{TOP} missing from mapped stat report")

    library_cells = set(CELL_RE.findall(args.liberty.read_text(errors="replace")))
    mapped_cells = 0
    for stats in modules.values():
        mapped_cells += sum(
            count
            for cell_type, count in stats.get("num_cells_by_type", {}).items()
            if canonical(cell_type) in library_cells
        )

    delays = []
    for log in sorted(args.worker_dir.glob("*.log")):
        matches = DELAY_RE.findall(log.read_text(errors="replace"))
        if matches:
            delays.append((float(matches[-1]), log.name))
    worst_delay, worst_log = max(delays, default=(None, None))

    top = modules[TOP]
    result = {
        "configuration": {
            "top": TOP,
            "variant": args.variant,
            "rv64f": args.variant == "fd",
            "rv64d": args.variant == "fd",
            "retire_depth": 16,
            "l1i": False,
            "l1d": False,
            "trace": False,
            "pipelined_fp_multiply": True,
            "registered_issue_select": bool(args.register_issue_select),
        },
        "area_um2": float(top.get("area", 0.0)),
        "sequential_area_um2": float(top.get("sequential_area", 0.0)),
        "mapped_library_cells": mapped_cells,
        "retained_modules": len(modules),
        "worst_partition_delay_ps": worst_delay,
        "worst_partition_log": worst_log,
        "timing_scope": (
            "maximum unbuffered ABC stime delay within any retained partition"
        ),
        "timing_qualified": False,
        "abc_recipe": "strash-dretime-scl-nf",
    }

    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    delay_text = "unavailable" if worst_delay is None else f"{worst_delay:,.2f} ps"
    report = [
        f"# Cacheless 4PF Nangate45 map: {args.variant}",
        "",
        f"- Standard-cell area: {result['area_um2']:,.3f} um^2",
        f"- Sequential-cell area: {result['sequential_area_um2']:,.3f} um^2",
        f"- Mapped library cells: {mapped_cells:,}",
        f"- Worst retained-partition unbuffered ABC delay: {delay_text}",
        "- ABC recipe: `strash; dretime; strash; &get -n; &nf; &put` "
        "(no buffer/upsize/downsize)",
        "",
        "The area is recursive across retained reporting partitions. L1I and L1D "
        "are disabled in both variants. The timing number is not a flattened "
        "whole-core STA result: paths crossing a retained hierarchy boundary are "
        "not represented by one ABC delay. It is also unbuffered and unsized, so "
        "it must not be converted into a core frequency.",
        "",
    ]
    (args.out_dir / "report.md").write_text("\n".join(report))

    print(
        f"{args.variant}: area={result['area_um2']:.3f} um^2 "
        f"seq={result['sequential_area_um2']:.3f} um^2 "
        f"cells={mapped_cells} worst_partition_delay={delay_text}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
