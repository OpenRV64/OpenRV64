#!/usr/bin/env python3
"""Build an exclusive functional-area table from Yosys Sky130 reports."""

from __future__ import annotations

import argparse
import csv
import json
import re
from collections import defaultdict
from pathlib import Path


MODULE_RE = re.compile(r"^module\s+(\S+)\s*$")
CELL_RE = re.compile(r"^\s{2}cell\s+(\S+)\s+(\S+)\s*$")
MEMORY_CELL_RE = re.compile(r"^\s{2}cell\s+\$mem_v2\s+(\S+)\s*$")
MEMORY_PARAMETER_RE = re.compile(
    r"^\s{4}parameter\s+\\(WIDTH|SIZE|RD_PORTS|WR_PORTS)\s+(\d+)\s*$"
)
MEMORY_READ_CLOCK_RE = re.compile(
    r"^\s{4}parameter\s+\\RD_CLK_ENABLE\s+\d+'([01]+)\s*$"
)
SKY130_PREFIX = "sky130_fd_sc_hd__"


def canonical(name: str) -> str:
    return name[1:] if name.startswith("\\") else name


def base_module(name: str) -> str:
    name = canonical(name)
    matches = re.findall(r"openrv64_[A-Za-z0-9_]+", name)
    if matches:
        return matches[-1]
    return name


def category_for(module: str) -> tuple[str, str]:
    base = base_module(module)
    categories = {
        "openrv64_rv64_top_3p": (
            "Frontend/core control",
            "PC/redirect control, packet construction, and top-level frontend glue",
        ),
        "openrv64_backend_3p": (
            "Backend control/forwarding",
            "allocation, full-forwarding fabric, branch control, and backend glue",
        ),
        "openrv64_fetch_3w": (
            "Fetch/line buffers",
            "three-wide fetch, line slots, replay, and predecode metadata",
        ),
        "openrv64_exec_bp": (
            "Branch predictor",
            "32x3-bit bimodal table, four-update queue, and eight-entry RAS",
        ),
        "openrv64_prefix_addsub": (
            "Branch predictor",
            "direct branch-target adder",
        ),
        "openrv64_decode_top": ("Decode", "three complete RV64 decode lanes"),
        "openrv64_rv64i_csrs": (
            "CSR/PMP",
            "privileged CSRs, interrupt state, counters, and PMP",
        ),
        "openrv64_except_vector": (
            "Trap/redirect vector",
            "trap, return, restart, and reset target selection",
        ),
        "openrv64_core_bus": (
            "Memory-system routing/AXI",
            "core-bus wrapper and external interface selection",
        ),
        "openrv64_core_mtl": (
            "Memory transaction layer",
            "translation queues, TLB/PTW, PMP clearance, barriers, and cache transaction control",
        ),
        "openrv64_core_icx_bus": (
            "ICX transport",
            "physical L1I/L1D/PTW command arbitration and response routing",
        ),
        "openrv64_l1d_icx": (
            "L1D control/tags",
            "16 KiB four-way L1D control, tags, fill/store buffers, prefetcher, and ICX client; data SRAM excluded",
        ),
        "openrv64_l1i_icx": (
            "L1I control/tags",
            "16 KiB four-way L1I control, tags, fill buffers, prefetch state, and ICX client; data SRAM excluded",
        ),
        "openrv64_bus_tlb": (
            "I/D TLBs",
            "two 16-entry translation lookaside buffers",
        ),
        "openrv64_bus_tlb_l2": (
            "Shared L2 TLB",
            "shared 256-entry, four-way second-level translation lookaside buffer",
        ),
        "openrv64_bus_ptw": (
            "Page-table walker",
            "shared page-table walker, PTE cache, and ICX client",
        ),
        "openrv64_dispatch_3p": (
            "Dispatch/hazards",
            "six-entry dispatch queue, dependency map, issue selection, and barriers",
        ),
        "openrv64_dispatch": (
            "Dispatch/hazards",
            "six-entry dispatch queue, dependency map, issue selection, and barriers",
        ),
        "openrv64_rv64i_gpr_3p": (
            "Integer register file",
            "32x64 GPRs with six reads and three writes",
        ),
        "openrv64_exec_pipe_ex0": (
            "EX0 integer/M",
            "RV64I ALU and iterative RV64M execution",
        ),
        "openrv64_exec_pipe_ex1": (
            "EX1 integer/branch",
            "RV64I ALU, conditional branch unit, system-CSR execution, and exceptions",
        ),
        "openrv64_exec_pipe_mem": (
            "LSU/MEM pipes",
            "two pipelined load/store queues with MEM0 atomics, posted-store state, and store-load forwarding",
        ),
        "openrv64_retire_queue_3p": (
            "Retirement",
            "eight-entry retirement ordering and completion control",
        ),
        "openrv64_retire_records_3p": (
            "Retirement",
            "canonical slot-indexed allocation and completion records",
        ),
        "openrv64_retire_3p": (
            "Retirement",
            "in-order prefix retirement and architectural side effects",
        ),
    }
    if base not in categories:
        raise ValueError(f"unclassified kept module: {module} (base {base})")
    return categories[base]


def load_stat(path: Path) -> dict[str, dict]:
    data = json.loads(path.read_text())
    return {canonical(name): stats for name, stats in data["modules"].items()}


def mapped_cells(stats: dict) -> int:
    return sum(
        count
        for cell_type, count in stats.get("num_cells_by_type", {}).items()
        if canonical(cell_type).startswith(SKY130_PREFIX)
    )


def kept_hierarchy(path: Path) -> dict[str, list[tuple[str, str]]]:
    children: dict[str, list[tuple[str, str]]] = defaultdict(list)
    current_module = None
    for line in path.read_text().splitlines():
        module_match = MODULE_RE.match(line)
        if module_match:
            current_module = canonical(module_match.group(1))
            continue
        cell_match = CELL_RE.match(line)
        if cell_match:
            if current_module is None:
                raise ValueError("kept cell appears outside a module")
            children[current_module].append(
                (canonical(cell_match.group(1)), canonical(cell_match.group(2)))
            )
    return children


def inferred_memories(path: Path) -> list[dict]:
    memories = []
    current_module = None
    current_memory = None

    def finish_memory() -> None:
        nonlocal current_memory
        if current_memory is None:
            return
        missing = [
            field
            for field in (
                "width",
                "size",
                "read_ports",
                "write_ports",
                "read_clock_enable",
            )
            if field not in current_memory
        ]
        if missing:
            raise ValueError(
                f"incomplete $mem_v2 record {current_memory.get('name')}: "
                f"missing {', '.join(missing)}"
            )
        current_memory["bits"] = current_memory["width"] * current_memory["size"]
        name = current_memory["name"].lower()
        module = current_memory["module"].lower()
        if (
            "tag_overlay_mem" in name
            and "openrv64_l1d_icx" in module
        ):
            current_memory["group"] = "L1D request overlay"
        elif "u_l1i" in name:
            current_memory["group"] = "L1I data"
        elif "u_l1d" in name:
            current_memory["group"] = "L1D data"
        elif current_memory["write_ports"] == 0:
            current_memory["group"] = "Other inferred ROM"
        else:
            current_memory["group"] = "Other inferred memory"
        memories.append(current_memory)
        current_memory = None

    for line in path.read_text().splitlines():
        module_match = MODULE_RE.match(line)
        if module_match:
            finish_memory()
            current_module = canonical(module_match.group(1))
            continue
        cell_match = MEMORY_CELL_RE.match(line)
        if cell_match:
            finish_memory()
            if current_module is None:
                raise ValueError("$mem_v2 cell appears outside a module")
            current_memory = {
                "module": current_module,
                "name": canonical(cell_match.group(1)),
            }
            continue
        parameter_match = MEMORY_PARAMETER_RE.match(line)
        if parameter_match and current_memory is not None:
            field = {
                "WIDTH": "width",
                "SIZE": "size",
                "RD_PORTS": "read_ports",
                "WR_PORTS": "write_ports",
            }[parameter_match.group(1)]
            current_memory[field] = int(parameter_match.group(2))
            continue
        read_clock_match = MEMORY_READ_CLOCK_RE.match(line)
        if read_clock_match and current_memory is not None:
            current_memory["read_clock_enable"] = (
                read_clock_match.group(1)
            )
    finish_memory()
    return memories


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--partition-stat", type=Path, required=True)
    parser.add_argument("--hierarchy", type=Path, required=True)
    parser.add_argument("--memories", type=Path, required=True)
    parser.add_argument("--flat-stat", type=Path)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()

    partition = load_stat(args.partition_stat)
    top = "openrv64_top_3p"
    if top not in partition:
        raise ValueError("openrv64_top_3p missing from partitioned Yosys stat report")

    category_area: dict[str, float] = defaultdict(float)
    category_seq: dict[str, float] = defaultdict(float)
    category_cells: dict[str, int] = defaultdict(int)
    descriptions: dict[str, list[str]] = defaultdict(list)
    instances: dict[str, list[str]] = defaultdict(list)

    hierarchy = kept_hierarchy(args.hierarchy)
    memories = inferred_memories(args.memories)
    memory_bits = sum(memory["bits"] for memory in memories)
    cache_memories = [
        memory
        for memory in memories
        if memory["group"] in ("L1I data", "L1D data")
    ]
    cache_memory_bits = sum(memory["bits"] for memory in cache_memories)
    expected_cache_geometry = {
        "L1I data": (4, 16 * 1024 * 8),
        # Four ways, each split into eight 64-bit word banks so a 512-bit
        # refill can install the complete line in one SRAM write cycle.
        "L1D data": (32, 16 * 1024 * 8),
    }
    for group_name, (expected_banks, expected_bits) in expected_cache_geometry.items():
        group_memories = [
            memory for memory in cache_memories if memory["group"] == group_name
        ]
        group_bits = sum(memory["bits"] for memory in group_memories)
        if len(group_memories) != expected_banks or group_bits != expected_bits:
            raise ValueError(
                f"{group_name} RAM inference changed: "
                f"{len(group_memories)} banks/{group_bits} bits, expected "
                f"{expected_banks} banks/{expected_bits} bits"
            )
        if any(
            memory["read_ports"] != 1
            or memory["write_ports"] != 1
            or memory["read_clock_enable"] != "1"
            for memory in group_memories
        ):
            raise ValueError(
                f"{group_name} must remain synchronous one-read/one-write SRAM"
            )
    overlay_memories = [
        memory
        for memory in memories
        if memory["group"] == "L1D request overlay"
    ]
    if overlay_memories:
        overlay_shapes = {
            (
                memory["size"],
                memory["width"],
                memory["read_ports"],
                memory["write_ports"],
                memory["read_clock_enable"],
            )
            for memory in overlay_memories
        }
        if (
            len(overlay_memories) != 1
            or overlay_shapes != {(8, 576, 1, 1, "1")}
        ):
            raise ValueError(
                "L1D request overlay RAM inference changed: "
                f"{len(overlay_memories)} memories with shapes "
                f"{sorted(overlay_shapes)}, expected one synchronous "
                "8x576 1R/1W memory"
            )
    memory_groups: dict[str, dict] = {}
    for memory in memories:
        group = memory_groups.setdefault(
            memory["group"], {"instances": 0, "bits": 0, "shapes": defaultdict(int)}
        )
        group["instances"] += 1
        group["bits"] += memory["bits"]
        shape = (
            memory["size"],
            memory["width"],
            memory["read_ports"],
            memory["write_ports"],
            memory["read_clock_enable"],
        )
        group["shapes"][shape] += 1

    def walk(module: str, instance: str) -> None:
        if module not in partition:
            raise ValueError(f"kept module {module} missing from stat report")
        children = hierarchy.get(module, [])
        stats = partition[module]
        child_area = sum(partition[child].get("area", 0.0) for child, _ in children)
        child_seq = sum(
            partition[child].get("sequential_area", 0.0) for child, _ in children
        )
        direct_area = stats.get("area", 0.0) - child_area
        direct_seq = stats.get("sequential_area", 0.0) - child_seq
        if direct_area < -0.01 or direct_seq < -0.01:
            raise ValueError(f"negative direct area while expanding {module}")

        if module == top:
            category = "AXI wrapper/glue"
            description = "fixed 3P AXI boundary and external tie-offs"
        else:
            category, description = category_for(module)
        category_area[category] += max(0.0, direct_area)
        category_seq[category] += max(0.0, direct_seq)
        category_cells[category] += mapped_cells(stats)
        if description not in descriptions[category]:
            descriptions[category].append(description)
        instances[category].append(instance)

        for child, child_instance in children:
            walk(child, f"{instance}/{child_instance}")

    walk(top, top)

    partition_total = sum(category_area.values())
    if partition_total <= 0.0:
        raise ValueError("partitioned area is zero")
    reported_total = partition[top].get("area", 0.0)
    if abs(partition_total - reported_total) > 0.1:
        raise ValueError(
            f"exclusive categories total {partition_total}, expected {reported_total}"
        )
    rows = []
    for category, area in category_area.items():
        rows.append(
            {
                "block": category,
                "area_um2": area,
                "percent": 100.0 * area / partition_total,
                "sequential_area_um2": category_seq[category],
                "mapped_cells": category_cells[category],
                "instances": len(instances[category]),
                "description": "; ".join(descriptions[category]),
            }
        )
    rows.sort(key=lambda row: row["area_um2"], reverse=True)

    flat_total = None
    flat_cells = None
    hierarchy_delta = None
    flat_failure = None
    if args.flat_stat and args.flat_stat.is_file():
        flat = load_stat(args.flat_stat)
        if top not in flat:
            flat_failure = "top module is absent from the flat stat report"
        else:
            flat_stats = flat[top]
            generic_cells = {
                canonical(cell_type): count
                for cell_type, count in flat_stats.get("num_cells_by_type", {}).items()
                if not canonical(cell_type).startswith(SKY130_PREFIX)
                and canonical(cell_type) != "$mem_v2"
            }
            if generic_cells:
                generic_count = sum(generic_cells.values())
                generic_types = ", ".join(sorted(generic_cells)[:4])
                flat_failure = (
                    f"{generic_count:,} cells remain unmapped "
                    f"({generic_types})"
                )
            else:
                flat_total = flat_stats.get("area", 0.0)
                flat_cells = mapped_cells(flat_stats)
                if flat_total <= 0.0:
                    flat_failure = "reported flat area is zero"
                    flat_total = None
                    flat_cells = None
                else:
                    hierarchy_delta = 100.0 * (partition_total / flat_total - 1.0)
    seq_total = sum(category_seq.values())

    args.out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = args.out_dir / "resources.csv"
    with csv_path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)

    (args.out_dir / "resources.json").write_text(
        json.dumps(
            {
                "configuration": {
                    "top": top,
                    "pipeline": "3-wide decode, EX0/EX1/MEM0/MEM1 issue",
                    "axi_data_width": 256,
                    "rv64m": True,
                    "rv64a": True,
                    "retire_depth": 8,
                    "full_forwarding": True,
                    "relaxed_waw": True,
                    "relaxed_hazards": True,
                    "free_branches": False,
                    "posted_stores": True,
                    "issue_window": False,
                    "predictor": "32-entry 3-bit bimodal + RAS8",
                    "trace": False,
                    "fpu": False,
                    "cache": True,
                    "l1i": "16 KiB, 4-way, 64-byte lines",
                    "l1d": "16 KiB, 4-way, 64-byte lines",
                    "cache_data_storage": "inferred synchronous SRAM",
                },
                "totals": {
                    "partitioned_area_um2": partition_total,
                    "partitioned_sequential_area_um2": seq_total,
                    "inferred_memory_instances": len(memories),
                    "inferred_memory_bits": memory_bits,
                    "cache_sram_instances": len(cache_memories),
                    "cache_sram_bits": cache_memory_bits,
                    "flat_area_um2": flat_total,
                    "flat_mapped_cells": flat_cells,
                    "partition_boundary_overhead_percent": hierarchy_delta,
                    "flat_map_failure": flat_failure,
                },
                "inferred_memories": memories,
                "blocks": rows,
            },
            indent=2,
        )
        + "\n"
    )

    report = [
        "# OpenRV64 3P Sky130 functional area\n",
        "## Result\n",
        "Exclusive functional categories from a Sky130 HD standard-cell logic "
        "map. Inferred SRAM is reported separately because no SRAM Liberty/LEF "
        "macro library is present. Percentages use the partitioned standard-cell "
        "total and sum to 100%.\n",
        "| Functional block | Area (um^2) | Size | Seq. area | Cells |",
        "|---|---:|---:|---:|---:|",
    ]
    for row in rows:
        report.append(
            f"| {row['block']} | {row['area_um2']:,.0f} | "
            f"{row['percent']:.2f}% | {row['sequential_area_um2']:,.0f} | "
            f"{row['mapped_cells']:,} |"
        )
    report.extend(
        [
            f"| **Partitioned total** | **{partition_total:,.0f}** | "
            f"**100.00%** | **{seq_total:,.0f}** | "
            f"**{sum(category_cells.values()):,}** |\n",
            "## Inferred SRAM\n",
        ]
    )
    report.append(
        f"The map preserves **{len(cache_memories)} synchronous cache SRAM "
        f"banks** totaling **{cache_memory_bits:,} bits "
        f"({cache_memory_bits / 8 / 1024:.1f} KiB)**. Their physical area is "
        "not included in the standard-cell total. Small inferred ROMs are "
        "listed separately.\n"
    )
    report.extend(
        [
            "| Storage | Banks | Shape | Capacity |",
            "|---|---:|---|---:|",
        ]
    )
    for group_name in (
        "L1I data",
        "L1D data",
        "L1D request overlay",
        "Other inferred memory",
        "Other inferred ROM",
    ):
        if group_name not in memory_groups:
            continue
        group = memory_groups[group_name]
        shapes = ", ".join(
            f"{count}x {size}x{width} {read_ports}R/{write_ports}W "
            f"{'sync' if read_clock_enable == '1' else 'async'}"
            for (size, width, read_ports, write_ports, read_clock_enable), count in
            sorted(group["shapes"].items())
        )
        report.append(
            f"| {group_name} | {group['instances']} | {shapes} | "
            f"{group['bits'] / 8 / 1024:.1f} KiB |"
        )
    report.extend(["", "## Flat-map cross-check\n"])
    if flat_total is not None:
        report.append(
            f"The fully flattened core maps to **{flat_total:,.0f} um^2** and "
            f"**{flat_cells:,} cells**. The category-boundary map is "
            f"**{hierarchy_delta:.2f}% larger** because ABC cannot optimize across "
            "the retained reporting boundaries.\n"
        )
    else:
        reason = flat_failure or "the optional flat flow was not run"
        report.append(
            "No valid fully flattened standard-cell total is reported. The default ABC "
            "global flow on the 105 MiB BLIF was impractically slow; the fast flow failed "
            "in buffer sizing; and the custom mapping attempt was rejected because "
            f"{reason}. **Do not use the incomplete 704,408 um^2 flop-only value.** "
            "The percentage table is normalized to the normal-flow partitioned map.\n"
        )
    report.extend(
        [
            "## Configuration\n",
            "- `openrv64_top_3p`, three-wide decode with EX0/EX1/MEM0/MEM1 issue, 256-bit AXI.",
            "- RV64IM+A; eight-entry retirement buffer; posted stores.",
            "- Full forwarding and relaxed tagged hazards/WAW.",
            "- Normal branch issue/resolution (`FREE_BRANCHES=0`); free branches are an oracle-only experiment.",
            "- 32-entry, 3-bit bimodal predictor; four-entry update queue; RAS depth 8.",
            "- 16 KiB four-way L1I and 16 KiB four-way L1D enabled; data arrays "
            "preserved as inferred synchronous SRAM.",
            "- Issue-window experiment, trace-only hardware, FPU, SoC peripherals, and "
            "the 16 MiB testbench RAM excluded.\n",
            "## Block boundaries\n",
        ]
    )
    for row in rows:
        report.append(f"- **{row['block']}:** {row['description']}.")
    report.extend(
        [
            "\n## Interpretation limits\n",
            "This is Yosys/ABC standard-cell mapping at the "
            "`sky130_fd_sc_hd__tt_025C_1v80` corner. Cache data arrays remain inferred "
            "`$mem_v2` cells rather than being expanded to flops. Their area, timing, "
            "routing, and macro halos are unknown until an SRAM macro library and mapping "
            "are selected. Other inferred structures that do not fit the SRAM contract "
            "still map to flops and logic. The result contains no placement, routing, "
            "clock tree, physical-only cells, power grid, or macro halos. Treat the "
            "percentages as standard-cell logic composition, not whole-core die area.\n",
        ]
    )
    (args.out_dir / "resources.md").write_text("\n".join(report))

    print(f"partitioned area: {partition_total:,.1f} um^2")
    if flat_total is not None:
        print(f"flat area:        {flat_total:,.1f} um^2")
        print(f"boundary delta:   {hierarchy_delta:.2f}%")
    else:
        print(f"flat area:        unavailable ({flat_failure or 'not run'})")
    print(
        f"cache SRAM:        {len(cache_memories)} banks, "
        f"{cache_memory_bits:,} bits ({cache_memory_bits / 8 / 1024:.1f} KiB)"
    )
    for row in rows:
        print(f"{row['block']:<28} {row['percent']:6.2f}%  {row['area_um2']:12,.1f} um^2")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
