#!/usr/bin/env python3
"""Build bounded XC7 module mappings and prepend source-local statistics."""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_MANIFEST = ROOT / "synth/fpga/xc7k480t/module_stats.json"
DEFAULT_OUTPUT = ROOT / "build/fpga/xc7k480t/module-stats"
ENTRY_ANCHOR = "<!-- module-statistics-entries: newest-first -->"
LOOP_FOUND = "Warning: found logic loop"
LOOP_BROKEN = "Breaking loop using new signal"


@dataclass(frozen=True)
class Unit:
    module: str
    source: Path
    report: Path
    parameters: dict[str, str]


@dataclass(frozen=True)
class BuildResult:
    unit: Unit
    status: str
    elapsed: float
    effective_parameters: dict[str, str]
    statistics: dict
    ltp_depth: int | None
    loops_found: int
    loops_broken: int
    warnings: int
    log: Path
    failure_tail: str


def canonical(name: str) -> str:
    return name[1:] if name.startswith("\\") else name


def yosys_quote(value: Path | str) -> str:
    text = str(value)
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def run_text(argv: list[str]) -> str:
    result = subprocess.run(
        argv,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(
            f"command failed ({result.returncode}): {' '.join(argv)}\n"
            f"{result.stderr.strip()}"
        )
    return result.stdout.strip()


def core_sources() -> list[Path]:
    output = run_text(
        [
            "make",
            "RV64M_EXEC_SRC=rtl/core/exec/alu/rv64-m-fpga.v",
            "-pn",
        ]
    )
    values: list[str] = []
    for line in output.splitlines():
        if line.startswith("CORE_3P_AXI_SRCS :="):
            values = line.split()[2:]
            break
    if not values:
        raise RuntimeError("could not extract CORE_3P_AXI_SRCS from make")

    ordered = ["rtl/openrv64_top_3p.v", *values]
    seen: set[Path] = set()
    sources: list[Path] = []
    for value in ordered:
        path = (ROOT / value).resolve()
        if path.as_posix().endswith("/debug/stub.v"):
            continue
        if path not in seen:
            seen.add(path)
            sources.append(path)
    missing = [str(path) for path in sources if not path.is_file()]
    if missing:
        raise RuntimeError("missing RTL sources: " + ", ".join(missing))
    return sources


def load_manifest(path: Path) -> tuple[str, str, list[Unit]]:
    data = json.loads(path.read_text())
    if data.get("schema") != 1:
        raise ValueError(f"unsupported manifest schema in {path}")
    profile = str(data["profile"])
    description = str(data["description"])
    units: list[Unit] = []
    names: set[str] = set()
    reports: set[Path] = set()
    for record in data["units"]:
        module = str(record["module"])
        if module in names:
            raise ValueError(f"duplicate module in manifest: {module}")
        names.add(module)
        source = ROOT / str(record["source"])
        if not source.is_file():
            raise ValueError(f"source does not exist for {module}: {source}")
        expected_report = source.with_name(source.stem + "_stats.md")
        report = ROOT / str(record.get("report", expected_report.relative_to(ROOT)))
        if report != expected_report:
            raise ValueError(
                f"report for {module} must be source-adjacent: {expected_report}"
            )
        if report in reports:
            raise ValueError(f"duplicate report path in manifest: {report}")
        reports.add(report)
        parameters = {
            str(key): str(value)
            for key, value in record.get("parameters", {}).items()
        }
        units.append(Unit(module, source, report, parameters))
    return profile, description, units


def source_digest(
    sources: list[Path], manifest: Path, units: list[Unit]
) -> str:
    digest = hashlib.sha256()
    for path in [manifest, *sources]:
        relative = path.relative_to(ROOT)
        digest.update(str(relative).encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    for unit in sorted(units, key=lambda item: item.module):
        digest.update(unit.module.encode())
        digest.update(b"\0")
        for key, value in sorted(unit.parameters.items()):
            digest.update(key.encode())
            digest.update(b"=")
            digest.update(value.encode())
            digest.update(b"\0")
    return digest.hexdigest()


def make_script(unit: Unit, sources: list[Path], directory: Path) -> Path:
    premap = directory / "premap.json"
    stat = directory / "stat.json"
    ltp = directory / "ltp.rpt"
    script = directory / "synth.ys"
    source_args = " ".join(yosys_quote(path) for path in sources)
    parameter_args = " ".join(
        f"-set {key} {value}" for key, value in unit.parameters.items()
    )
    chparam = (
        f"chparam {parameter_args} {unit.module}"
        if parameter_args
        else f"chparam {unit.module}"
    )
    script.write_text(
        "\n".join(
            [
                (
                    "read_verilog -sv -defer -DSYNTHESIS "
                    f"-I{ROOT / 'rtl'} {source_args}"
                ),
                chparam,
                f"hierarchy -check -top {unit.module}",
                "proc",
                f"write_json {yosys_quote(premap)}",
                # Flattening is deliberately bounded by the selected module.
                # The complete core is never presented to ABC as one network.
                (
                    "synth_xilinx -family xc7 "
                    f"-top {unit.module} -flatten -noiopad -noclkbuf"
                ),
                "delete t:$scopeinfo",
                "check -noinit",
                f"tee -o {yosys_quote(stat)} stat -tech xilinx -json",
                f"tee -o {yosys_quote(ltp)} ltp -noff",
                "",
            ]
        )
    )
    return script


def find_module(data: dict, module: str) -> dict:
    for name, record in data.get("modules", {}).items():
        if canonical(name) == module:
            return record
    raise KeyError(f"module {module} absent from Yosys JSON")


def format_parameter(bits: str) -> str:
    if not bits or re.search(r"[^01]", bits):
        return f"`{bits}`"
    width = len(bits)
    value = int(bits, 2)
    if width <= 32:
        return str(value)
    digits = (width + 3) // 4
    return f"`{width}'h{value:0{digits}x}`"


def parse_ltp(path: Path, module: str) -> int | None:
    if not path.is_file():
        return None
    pattern = re.compile(
        rf"Longest topological path in \\?{re.escape(module)} "
        r"\(length=(\d+)\):"
    )
    depths = [int(match.group(1)) for match in pattern.finditer(path.read_text())]
    return max(depths) if depths else None


def build_unit(
    unit: Unit,
    sources: list[Path],
    output: Path,
    yosys: str,
) -> BuildResult:
    directory = output / unit.module.removeprefix("openrv64_")
    directory.mkdir(parents=True, exist_ok=True)
    script = make_script(unit, sources, directory)
    log = directory / "yosys.log"
    start = time.monotonic()
    process = subprocess.run(
        [yosys, "-Q", "-l", str(log), "-s", str(script)],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
        check=False,
    )
    elapsed = time.monotonic() - start
    log_text = log.read_text(errors="replace") if log.is_file() else ""
    loops_found = log_text.count(LOOP_FOUND)
    loops_broken = log_text.count(LOOP_BROKEN)
    warnings = len(re.findall(r"^Warning:", log_text, re.MULTILINE))
    failure_tail = ""
    effective_parameters: dict[str, str] = {}
    statistics: dict = {}
    ltp_depth: int | None = None

    try:
        premap = json.loads((directory / "premap.json").read_text())
        top = find_module(premap, unit.module)
        effective_parameters = {
            key: format_parameter(value)
            for key, value in sorted(
                top.get("parameter_default_values", {}).items()
            )
        }
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        effective_parameters = {
            key: f"`{value}`" for key, value in sorted(unit.parameters.items())
        }

    if process.returncode == 0:
        try:
            stat_data = json.loads((directory / "stat.json").read_text())
            statistics = find_module(stat_data, unit.module)
            ltp_depth = parse_ltp(directory / "ltp.rpt", unit.module)
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
            process = subprocess.CompletedProcess(process.args, 1)
            failure_tail = f"could not parse synthesis artifacts: {error}"

    if process.returncode:
        if not failure_tail:
            failure_tail = "\n".join(log_text.splitlines()[-30:])
        status = "failed"
    elif loops_found or loops_broken:
        status = "mapped with combinational-loop cuts"
    else:
        status = "mapped"

    return BuildResult(
        unit=unit,
        status=status,
        elapsed=elapsed,
        effective_parameters=effective_parameters,
        statistics=statistics,
        ltp_depth=ltp_depth,
        loops_found=loops_found,
        loops_broken=loops_broken,
        warnings=warnings,
        log=log,
        failure_tail=failure_tail,
    )


def resource_summary(statistics: dict) -> tuple[dict[str, int], dict[str, int]]:
    cells = {
        canonical(name): int(count)
        for name, count in statistics.get("num_cells_by_type", {}).items()
    }
    lut_types = {f"LUT{index}" for index in range(1, 7)} | {"LUT6_2"}
    ff_types = {
        "FDCE", "FDCPE", "FDPE", "FDRE", "FDRSE", "FDSE",
        "FDCE_1", "FDCPE_1", "FDPE_1", "FDRE_1", "FDRSE_1", "FDSE_1",
    }
    latch_types = {"LDCE", "LDCPE", "LDPE"}
    summary = {
        "Estimated logic cells": int(statistics.get("estimated_num_lc", 0)),
        "LUT primitives": sum(cells.get(name, 0) for name in lut_types),
        "Flip-flops": sum(cells.get(name, 0) for name in ff_types),
        "Latches": sum(cells.get(name, 0) for name in latch_types),
        "CARRY4": cells.get("CARRY4", 0),
        "MUXF7/8/9": sum(cells.get(f"MUXF{index}", 0) for index in (7, 8, 9)),
        "DSP48E1": cells.get("DSP48E1", 0),
        "RAMB36E1": cells.get("RAMB36E1", 0),
        "RAMB18E1": cells.get("RAMB18E1", 0),
        "Distributed-RAM primitives": sum(
            count
            for name, count in cells.items()
            if name.startswith("RAM") and not name.startswith("RAMB")
        ),
        "SRL primitives": sum(
            count for name, count in cells.items() if name.startswith("SRL")
        ),
        "Total mapped cells": int(statistics.get("num_cells", 0)),
    }
    raw = {name: count for name, count in cells.items() if count}
    return summary, raw


def markdown_escape(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def result_markdown(
    result: BuildResult,
    *,
    timestamp: str,
    run_id: str,
    profile: str,
    description: str,
    commit: str,
    dirty: bool,
    digest: str,
    yosys_version: str,
) -> str:
    unit = result.unit
    relative_source = unit.source.relative_to(ROOT)
    relative_log = result.log.relative_to(ROOT)
    entry_id = f"{run_id}:{unit.module}"
    lines = [
        f"<!-- module-statistics-entry:start id={entry_id} -->",
        f"## {timestamp} — `{run_id}`",
        "",
        "| Build field | Value |",
        "|---|---|",
        f"| Status | **{markdown_escape(result.status)}** |",
        f"| Module | `{unit.module}` |",
        f"| RTL source | `{relative_source}` |",
        f"| Profile | `{profile}` — {markdown_escape(description)} |",
        "| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |",
        "| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |",
        f"| Git commit | `{commit}` |",
        f"| Worktree | `{'dirty' if dirty else 'clean'}` |",
        f"| RTL input SHA-256 | `{digest}` |",
        f"| Tool | `{markdown_escape(yosys_version)}` |",
        f"| Elapsed | {result.elapsed:.1f} s |",
        f"| Build log | `{relative_log}` |",
        "",
        "### Effective parameters",
        "",
        "| Parameter | Value |",
        "|---|---:|",
    ]
    if result.effective_parameters:
        lines.extend(
            f"| `{key}` | {value} |"
            for key, value in result.effective_parameters.items()
        )
    else:
        lines.append("| _Unavailable_ | — |")

    if result.status != "failed":
        summary, raw = resource_summary(result.statistics)
        lines.extend(
            [
                "",
                "### Resources",
                "",
                "| Metric | Count |",
                "|---|---:|",
            ]
        )
        lines.extend(f"| {key} | {value:,} |" for key, value in summary.items())
        lines.extend(
            [
                "",
                "Raw nonzero primitive counts:",
                "",
                "| Primitive | Count |",
                "|---|---:|",
            ]
        )
        lines.extend(f"| `{key}` | {value:,} |" for key, value in sorted(raw.items()))
        depth = str(result.ltp_depth) if result.ltp_depth is not None else "unavailable"
        lines.extend(
            [
                "",
                "### Timing and diagnostics",
                "",
                f"- Longest mapped topological path: **{depth} netlist cells** (`ltp -noff`).",
                "- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.",
                f"- Logic-loop warnings: **{result.loops_found}**; ABC loop cuts: **{result.loops_broken}**.",
                f"- Total Yosys warnings: **{result.warnings}**.",
            ]
        )
        if result.loops_found or result.loops_broken:
            lines.append(
                "- This mapping is diagnostic only: loop cuts make it unsuitable as implementation evidence."
            )
    else:
        lines.extend(
            [
                "",
                "### Failure",
                "",
                "```text",
                result.failure_tail,
                "```",
            ]
        )

    lines.extend(
        [
            "",
            f"<!-- module-statistics-entry:end id={entry_id} -->",
            "",
        ]
    )
    return "\n".join(lines)


def prepend_report(unit: Unit, entry: str, run_id: str) -> None:
    title = f"# `{unit.module}` FPGA synthesis history"
    preamble = "\n".join(
        [
            title,
            "",
            "Generated build records are stored newest first. Counts from different",
            "files are not automatically additive because module boundaries may overlap.",
            "Do not treat structural depth as physical timing.",
            "",
            ENTRY_ANCHOR,
            "",
        ]
    )
    if unit.report.exists():
        content = unit.report.read_text()
        if ENTRY_ANCHOR not in content:
            raise ValueError(f"existing report lacks history anchor: {unit.report}")
    else:
        content = preamble

    entry_id = f"{run_id}:{unit.module}"
    block_pattern = re.compile(
        rf"<!-- module-statistics-entry:start id={re.escape(entry_id)} -->.*?"
        rf"<!-- module-statistics-entry:end id={re.escape(entry_id)} -->\n?",
        re.DOTALL,
    )
    content = block_pattern.sub("", content)
    insertion = content.index(ENTRY_ANCHOR) + len(ENTRY_ANCHOR)
    updated = content[:insertion] + "\n\n" + entry.rstrip() + "\n" + content[insertion:].lstrip("\n")
    temporary = unit.report.with_suffix(unit.report.suffix + ".tmp")
    temporary.write_text(updated)
    os.replace(temporary, unit.report)


def write_summary(
    path: Path,
    results: list[BuildResult],
    *,
    timestamp: str,
    run_id: str,
    profile: str,
    commit: str,
    dirty: bool,
    digest: str,
) -> None:
    lines = [
        "# XC7 module-statistics build",
        "",
        f"- Time: {timestamp}",
        f"- Run: `{run_id}`",
        f"- Profile: `{profile}`",
        f"- Git commit: `{commit}`",
        f"- Worktree: `{'dirty' if dirty else 'clean'}`",
        f"- RTL input SHA-256: `{digest}`",
        "",
        "| Module | Status | Logic cells | Depth | Loops | Report |",
        "|---|---|---:|---:|---:|---|",
    ]
    for result in sorted(results, key=lambda item: item.unit.module):
        estimated = int(result.statistics.get("estimated_num_lc", 0))
        depth = result.ltp_depth if result.ltp_depth is not None else "—"
        report = result.unit.report.relative_to(ROOT)
        lines.append(
            f"| `{result.unit.module}` | {result.status} | {estimated:,} | "
            f"{depth} | {result.loops_found}/{result.loops_broken} | `{report}` |"
        )
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--module", action="append", default=[])
    parser.add_argument("--parameter", action="append", default=[])
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--yosys", default=os.environ.get("YOSYS", "yosys"))
    args = parser.parse_args()

    manifest = args.manifest.resolve()
    output = args.output_dir.resolve()
    profile, description, units = load_manifest(manifest)
    if args.module:
        selected = set(args.module)
        units = [unit for unit in units if unit.module in selected]
        missing = selected - {unit.module for unit in units}
        if missing:
            parser.error("unknown modules: " + ", ".join(sorted(missing)))
    if args.parameter:
        if len(units) != 1:
            parser.error("--parameter requires exactly one selected module")
        overrides: dict[str, str] = {}
        for assignment in args.parameter:
            if "=" not in assignment:
                parser.error(
                    f"parameter override must be NAME=VALUE: {assignment}"
                )
            name, value = assignment.split("=", 1)
            if not name or not value:
                parser.error(
                    f"parameter override must be NAME=VALUE: {assignment}"
                )
            if name not in units[0].parameters:
                parser.error(
                    f"parameter {name} is absent from the manifest entry for "
                    f"{units[0].module}"
                )
            overrides[name] = value
        unit = units[0]
        units = [
            Unit(
                unit.module,
                unit.source,
                unit.report,
                {**unit.parameters, **overrides},
            )
        ]
    if args.list:
        for unit in units:
            print(f"{unit.module}\t{unit.source.relative_to(ROOT)}\t{unit.report.relative_to(ROOT)}")
        return 0
    if args.jobs < 1:
        parser.error("--jobs must be at least one")

    output.mkdir(parents=True, exist_ok=True)
    sources = core_sources()
    digest = source_digest(sources, manifest, units)
    commit = run_text(["git", "rev-parse", "HEAD"])
    dirty = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=no"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        check=False,
    ).stdout.strip() != b""
    timestamp = dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat()
    run_id = os.environ.get(
        "OPENRV64_RUN_ID",
        "manual-" + dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ"),
    )
    yosys_version = run_text([args.yosys, "-V"])

    results: list[BuildResult] = []
    worker_count = min(args.jobs, len(units))
    print(f"mapping {len(units)} module units with {worker_count} workers", flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=worker_count) as executor:
        futures = {
            executor.submit(build_unit, unit, sources, output, args.yosys): unit
            for unit in units
        }
        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            results.append(result)
            entry = result_markdown(
                result,
                timestamp=timestamp,
                run_id=run_id,
                profile=profile,
                description=description,
                commit=commit,
                dirty=dirty,
                digest=digest,
                yosys_version=yosys_version,
            )
            prepend_report(result.unit, entry, run_id)
            print(
                f"{result.status}: {result.unit.module} "
                f"({result.elapsed:.1f}s, {len(results)}/{len(units)})",
                flush=True,
            )

    summary = output / "summary.md"
    write_summary(
        summary,
        results,
        timestamp=timestamp,
        run_id=run_id,
        profile=profile,
        commit=commit,
        dirty=dirty,
        digest=digest,
    )
    failures = [result for result in results if result.status == "failed"]
    if failures:
        print(
            "OPENRV64 XC7K480T MODULE STATS FAIL modules="
            + ",".join(result.unit.module for result in failures),
            flush=True,
        )
        return 1
    print(
        f"OPENRV64 XC7K480T MODULE STATS PASS modules={len(results)} "
        f"summary={summary.relative_to(ROOT)}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
