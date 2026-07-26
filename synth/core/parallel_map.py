#!/usr/bin/env python3
"""Technology-map retained Yosys modules concurrently and merge their stats.

Yosys's ``abc`` pass maps modules one at a time.  The retained reporting
partitions in the core resource flow are independent at that point, so separate
Yosys processes can map them concurrently from one pre-ABC RTLIL checkpoint.
This script reconstructs the recursive module areas expected by
``summarize_resources.py`` from each worker's direct mapped-cell area.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import re
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path


MODULE_RE = re.compile(r"^module\s+(\S+)\s*$")
CELL_RE = re.compile(r"^\s{2}cell\s+(\S+)\s+(\S+)\s*$")
MAX_JOBS = 32


def canonical(name: str) -> str:
    return name[1:] if name.startswith("\\") else name


def yosys_quote(path: Path) -> str:
    value = str(path)
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def load_hierarchy(path: Path) -> dict[str, list[str]]:
    children: dict[str, list[str]] = defaultdict(list)
    current_module: str | None = None
    for line in path.read_text().splitlines():
        module_match = MODULE_RE.match(line)
        if module_match:
            current_module = canonical(module_match.group(1))
            continue
        cell_match = CELL_RE.match(line)
        if cell_match:
            if current_module is None:
                raise ValueError("kept cell appears outside a module")
            children[current_module].append(canonical(cell_match.group(1)))
    return children


def worker_stem(index: int, module: str) -> str:
    base = re.findall(r"openrv64_[A-Za-z0-9_]+", canonical(module))
    label = base[-1] if base else "module"
    return f"{index:02d}-{label}"


def run_worker(
    *,
    index: int,
    module: str,
    yosys: Path,
    checkpoint: Path,
    liberty: Path,
    constraint: Path,
    worker_dir: Path,
    reuse_worker: bool,
) -> tuple[str, dict, float]:
    stem = worker_stem(index, module)
    script_path = worker_dir / f"{stem}.ys"
    stat_path = worker_dir / f"{stem}.json"
    log_path = worker_dir / f"{stem}.log"
    if reuse_worker and stat_path.is_file():
        data = json.loads(stat_path.read_text())
        modules = {
            canonical(name): stats
            for name, stats in data["modules"].items()
        }
        key = canonical(module)
        if key not in modules:
            raise ValueError(
                f"reused worker stat omitted selected module {module}"
            )
        return key, modules[key], 0.0
    script_path.write_text(
        "\n".join(
            [
                f"read_rtlil {yosys_quote(checkpoint)}",
                (
                    f"abc -liberty {yosys_quote(liberty)} "
                    f"-constr {yosys_quote(constraint)} {module}"
                ),
                "clean -purge",
                (
                    f"tee -o {yosys_quote(stat_path)} stat "
                    f"-liberty {yosys_quote(liberty)} -json {module}"
                ),
                f"check {module}",
                "",
            ]
        )
    )
    start = time.monotonic()
    with log_path.open("w") as log:
        process = subprocess.run(
            [str(yosys), "-Q", "-s", str(script_path)],
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    elapsed = time.monotonic() - start
    if process.returncode:
        raise RuntimeError(
            f"Yosys worker failed for {module} (see {log_path})"
        )
    data = json.loads(stat_path.read_text())
    modules = {canonical(name): stats for name, stats in data["modules"].items()}
    key = canonical(module)
    if key not in modules:
        raise ValueError(f"worker stat omitted selected module {module}")
    return key, modules[key], elapsed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--yosys", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--pre-stat", type=Path, required=True)
    parser.add_argument("--hierarchy", type=Path, required=True)
    parser.add_argument("--liberty", type=Path, required=True)
    parser.add_argument("--constraint", type=Path, required=True)
    parser.add_argument("--out-stat", type=Path, required=True)
    parser.add_argument("--worker-dir", type=Path, required=True)
    parser.add_argument("--jobs", type=int, required=True)
    parser.add_argument("--reuse-workers", action="store_true")
    args = parser.parse_args()

    if args.jobs < 1:
        parser.error("--jobs must be at least one")
    jobs = min(args.jobs, MAX_JOBS)
    if jobs != args.jobs:
        print(
            f"limiting requested worker count from {args.jobs} to {MAX_JOBS}",
            flush=True,
        )
    args.worker_dir.mkdir(parents=True, exist_ok=True)

    pre_data = json.loads(args.pre_stat.read_text())
    original_names = {
        canonical(name): name for name in pre_data["modules"]
    }
    modules = sorted(original_names)
    hierarchy = load_hierarchy(args.hierarchy)
    missing = sorted(
        child
        for children in hierarchy.values()
        for child in children
        if child not in original_names
    )
    if missing:
        raise ValueError(
            "hierarchy references modules absent from pre-ABC stat: "
            + ", ".join(missing)
        )

    print(
        f"mapping {len(modules)} retained modules with "
        f"{min(jobs, len(modules))} workers",
        flush=True,
    )
    direct: dict[str, dict] = {}
    elapsed_by_module: dict[str, float] = {}
    with concurrent.futures.ThreadPoolExecutor(
        max_workers=min(jobs, len(modules))
    ) as executor:
        futures = {
            executor.submit(
                run_worker,
                index=index,
                module=original_names[module],
                yosys=args.yosys,
                checkpoint=args.checkpoint,
                liberty=args.liberty,
                constraint=args.constraint,
                worker_dir=args.worker_dir,
                reuse_worker=args.reuse_workers,
            ): module
            for index, module in enumerate(modules)
        }
        try:
            for future in concurrent.futures.as_completed(futures):
                module, stats, elapsed = future.result()
                direct[module] = stats
                elapsed_by_module[module] = elapsed
                print(
                    f"mapped {module} in {elapsed:.1f}s "
                    f"({len(direct)}/{len(modules)})",
                    flush=True,
                )
        except BaseException:
            for future in futures:
                future.cancel()
            raise

    # A module selection passed to ``stat`` reports only that selected
    # module's direct mapped cells. Retained child modules appear as
    # submodule cells but do not contribute area. Rebuild the recursive area
    # expected by the serial all-module ``stat`` by adding each independently
    # mapped child below.

    recursive_area: dict[str, float] = {}
    recursive_seq: dict[str, float] = {}
    visiting: set[str] = set()

    def accumulate(module: str) -> tuple[float, float]:
        if module in recursive_area:
            return recursive_area[module], recursive_seq[module]
        if module in visiting:
            raise ValueError(f"cycle in retained hierarchy at {module}")
        visiting.add(module)
        stats = direct[module]
        area = float(stats.get("area", 0.0))
        sequential = float(stats.get("sequential_area", 0.0))
        for child in hierarchy.get(module, []):
            child_area, child_seq = accumulate(child)
            area += child_area
            sequential += child_seq
        visiting.remove(module)
        recursive_area[module] = area
        recursive_seq[module] = sequential
        return area, sequential

    for module in modules:
        accumulate(module)

    merged_modules = {}
    for module in modules:
        stats = dict(direct[module])
        stats["area"] = recursive_area[module]
        stats["sequential_area"] = recursive_seq[module]
        merged_modules[original_names[module]] = stats
    merged = dict(pre_data)
    merged["modules"] = merged_modules
    args.out_stat.write_text(json.dumps(merged, indent=2) + "\n")

    timing_path = args.worker_dir / "timing.json"
    timing_path.write_text(
        json.dumps(
            {
                "requested_jobs": args.jobs,
                "jobs": min(jobs, len(modules)),
                "job_limit": MAX_JOBS,
                "module_seconds": dict(sorted(elapsed_by_module.items())),
            },
            indent=2,
        )
        + "\n"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise
