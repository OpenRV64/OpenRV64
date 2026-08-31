#!/usr/bin/env python3
"""Run self-checking architectural ELFs on OpenRV64 test configurations."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable

from elf2mem import image_words, load_elf, write_memh


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RESULTS = ROOT / "build/compliance/results"
RAM_BASE = 0x8000_0000
RAM_SIZE = 0x10_0000
PASS_RE = re.compile(r"COMPLIANCE PASS\b")
SAIL_INSTR_RE = re.compile(
    r"^\[\d+\] \[[A-Z]\]: 0x([0-9a-fA-F]+) "
    r"\(0x([0-9a-fA-F]+)\)"
)
SAIL_GPR_RE = re.compile(r"^x(\d+) <- 0x([0-9a-fA-F]+)")


@dataclass
class Result:
    test: str
    elf: str
    backend: str
    engine: str
    rv64m: bool
    status: str
    expected_failure: bool
    duration_seconds: float
    returncode: int
    tohost: str
    log: str
    trace: str | None
    message: str


def command_path(name: str) -> str | None:
    return shutil.which(name)


def run_command(
    command: list[str],
    *,
    cwd: Path = ROOT,
    timeout: int | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        env=env,
        check=False,
    )


def tohost_symbol(elf: Path, nm: str) -> int:
    completed = run_command([nm, "-P", str(elf)])
    if completed.returncode:
        raise RuntimeError(f"nm failed for {elf}:\n{completed.stdout}")
    for line in completed.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[0] == "tohost":
            return int(fields[2], 16)
    raise RuntimeError(f"{elf}: no global tohost symbol")


def safe_name(path: Path) -> str:
    stem = re.sub(r"[^A-Za-z0-9_.-]+", "-", path.stem).strip("-")
    digest = hashlib.sha256(str(path.resolve()).encode()).hexdigest()[:10]
    return f"{stem}-{digest}"


def resolve_engine(backend: str, engine: str) -> str:
    if engine != "auto":
        return engine
    if backend in (
        "3p",
        "3p-banked",
        "platform-3p",
        "platform-3p-ddr3",
        "platform-3p-banked-ddr3",
    ) and command_path("verilator"):
        return "verilator"
    return "iverilog"


def simulator(backend: str, rv64m: bool, engine: str) -> tuple[str, Path, int]:
    suffix = "m" if rv64m else "i"
    if engine == "verilator":
        top = (
            "tb_compliance_platform"
            if backend.startswith("platform")
            else "tb_compliance_3p"
            if backend == "3p-banked"
            else f"tb_compliance_{backend}"
        )
        target = f"build/compliance/sim/verilator/{backend}_{suffix}/V{top}"
        word_bytes = 32 if backend in (
            "3p",
            "3p-banked",
            "platform-3p-ddr3",
            "platform-3p-banked-ddr3",
        ) else 8
        return target, ROOT / target, word_bytes
    if backend == "1p":
        return (
            f"build/compliance/sim/compliance_1p_{suffix}.vvp",
            ROOT / f"build/compliance/sim/compliance_1p_{suffix}.vvp",
            8,
        )
    if backend == "3p":
        return (
            f"build/compliance/sim/compliance_3p_{suffix}.vvp",
            ROOT / f"build/compliance/sim/compliance_3p_{suffix}.vvp",
            32,
        )
    if backend == "3p-banked":
        return (
            f"build/compliance/sim/compliance_3p_banked_{suffix}.vvp",
            ROOT / f"build/compliance/sim/compliance_3p_banked_{suffix}.vvp",
            32,
        )
    if backend == "platform":
        return (
            f"build/compliance/sim/compliance_platform_{suffix}.vvp",
            ROOT / f"build/compliance/sim/compliance_platform_{suffix}.vvp",
            8,
        )
    if backend in (
        "platform-3p",
        "platform-3p-ddr3",
        "platform-3p-banked-ddr3",
    ):
        raise ValueError(f"{backend} requires the Verilator engine")
    raise ValueError(f"unsupported backend {backend!r}")


def build_simulator(target: str) -> None:
    # This runner is itself commonly called from a Make recipe.  Do not let a
    # parent's -B/--always-make flag rebuild the complete Verilator model once
    # per ELF in a suite.
    env = os.environ.copy()
    for variable in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL"):
        env.pop(variable, None)
    completed = run_command(["make", target], env=env)
    if completed.returncode:
        raise RuntimeError(f"simulator build failed:\n{completed.stdout}")


def run_one(
    elf: Path,
    *,
    backend: str,
    rv64m: bool,
    results_dir: Path,
    max_cycles: int,
    wall_timeout: int,
    trace: bool,
    nm: str,
    engine: str,
    expected_failure: bool = False,
) -> Result:
    elf = elf.resolve()
    test = safe_name(elf)
    artifact = results_dir / backend / test
    artifact.mkdir(parents=True, exist_ok=True)
    engine = resolve_engine(backend, engine)
    target, sim, word_bytes = simulator(backend, rv64m, engine)
    build_simulator(target)

    entry, segments = load_elf(elf)
    if entry < RAM_BASE or entry >= RAM_BASE + RAM_SIZE:
        raise ValueError(f"{elf}: entry point 0x{entry:x} is outside test RAM")
    words = image_words(segments, RAM_BASE, RAM_SIZE, word_bytes)
    memh = artifact / f"image-{word_bytes * 8}.memh"
    write_memh(memh, words)
    tohost = tohost_symbol(elf, nm)
    trace_path = artifact / "arch.csv" if trace else None
    log_path = artifact / "run.log"

    command = ([] if engine == "verilator" else ["vvp"]) + [
        str(sim),
        f"+memh={memh}",
        f"+tohost={tohost:x}",
        f"+test={test}",
        f"+max_cycles={max_cycles}",
    ]
    if trace_path:
        command.append(f"+arch_trace={trace_path}")

    started = time.monotonic()
    try:
        completed = run_command(command, timeout=wall_timeout)
        output = completed.stdout
        returncode = completed.returncode
        passed = returncode == 0 and PASS_RE.search(output) is not None
        message = output.strip().splitlines()[-1] if output.strip() else "no output"
    except subprocess.TimeoutExpired as error:
        output = (error.stdout or "") + "\nwall-clock timeout\n"
        returncode = 124
        passed = False
        message = f"wall-clock timeout after {wall_timeout}s"
    duration = time.monotonic() - started
    log_path.write_text(output)

    if passed and expected_failure:
        status = "xpass"
    elif passed:
        status = "pass"
    elif expected_failure:
        status = "xfail"
    else:
        status = "fail"
    result = Result(
        test=test,
        elf=str(elf),
        backend=backend,
        engine=engine,
        rv64m=rv64m,
        status=status,
        expected_failure=expected_failure,
        duration_seconds=round(duration, 6),
        returncode=returncode,
        tohost=f"0x{tohost:016x}",
        log=str(log_path),
        trace=str(trace_path) if trace_path else None,
        message=message,
    )
    (artifact / "result.json").write_text(json.dumps(asdict(result), indent=2) + "\n")
    return result


def discover_elfs(paths: Iterable[Path]) -> list[Path]:
    found: list[Path] = []
    for path in paths:
        if path.is_file() and path.suffix == ".elf":
            found.append(path)
        elif path.is_dir():
            found.extend(path.rglob("*.elf"))
        else:
            raise FileNotFoundError(path)
    return sorted({path.resolve() for path in found})


def load_xfails(path: Path | None) -> dict[str, str]:
    if path is None or not path.exists():
        return {}
    entries: dict[str, str] = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t", 1)
        if len(fields) != 2 or not fields[0] or not fields[1]:
            raise ValueError(f"{path}:{number}: expected TEST<TAB>REASON")
        entries[fields[0]] = fields[1]
    return entries


def write_junit(results: list[Result], path: Path) -> None:
    failures = sum(result.status in ("fail", "xpass") for result in results)
    skipped = sum(result.status == "xfail" for result in results)
    suite = ET.Element(
        "testsuite",
        name="openrv64-compliance",
        tests=str(len(results)),
        failures=str(failures),
        skipped=str(skipped),
        time=f"{sum(result.duration_seconds for result in results):.6f}",
    )
    for result in results:
        case = ET.SubElement(
            suite,
            "testcase",
            classname=f"openrv64.{result.backend}",
            name=result.test,
            time=f"{result.duration_seconds:.6f}",
        )
        if result.status == "xfail":
            ET.SubElement(case, "skipped", message=result.message)
        elif result.status in ("fail", "xpass"):
            failure = ET.SubElement(case, "failure", message=result.message)
            failure.text = Path(result.log).read_text()
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(suite).write(path, encoding="unicode", xml_declaration=True)


def add_run_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--backend",
        choices=(
            "1p",
            "3p",
            "3p-banked",
            "platform",
            "platform-3p",
            "platform-3p-ddr3",
            "platform-3p-banked-ddr3",
        ),
        default="1p",
    )
    parser.add_argument(
        "--engine",
        choices=("auto", "iverilog", "verilator"),
        default="auto",
        help="auto uses Verilator for 3p/platform-3p and Icarus elsewhere",
    )
    parser.add_argument("--rv64m", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--results-dir", type=Path, default=DEFAULT_RESULTS)
    parser.add_argument("--max-cycles", type=int, default=2_000_000)
    parser.add_argument("--wall-timeout", type=int, default=300)
    parser.add_argument("--trace", action="store_true")
    parser.add_argument("--nm", default=os.environ.get("RISCV_NM", "riscv64-elf-nm"))


def doctor(args: argparse.Namespace) -> int:
    checks = {
        "python": sys.executable,
        "make": command_path("make"),
        "iverilog": command_path("iverilog"),
        "vvp": command_path("vvp"),
        "verilator": command_path("verilator"),
        "riscv64-elf-gcc": command_path("riscv64-elf-gcc"),
        "riscv64-elf-nm": command_path("riscv64-elf-nm"),
    }
    for name, value in checks.items():
        print(f"{'PASS' if value else 'MISS'} {name}: {value or 'not found'}")
    required = ("make", "iverilog", "vvp", "riscv64-elf-gcc", "riscv64-elf-nm")
    local_ok = all(checks[name] for name in required)
    print(f"LOCAL {'READY' if local_ok else 'INCOMPLETE'}")
    return 0 if local_ok else 1


def run_subcommand(args: argparse.Namespace) -> int:
    result = run_one(
        args.elf,
        backend=args.backend,
        rv64m=args.rv64m,
        results_dir=args.results_dir,
        max_cycles=args.max_cycles,
        wall_timeout=args.wall_timeout,
        trace=args.trace,
        nm=args.nm,
        engine=args.engine,
    )
    print(f"{result.status.upper()} {result.test} ({result.duration_seconds:.3f}s)")
    print(result.log)
    return 0 if result.status == "pass" else 1


def suite_subcommand(args: argparse.Namespace) -> int:
    elfs = discover_elfs(args.paths)
    if args.extensions:
        extensions = {item.strip() for item in args.extensions.split(",") if item.strip()}
        elfs = [elf for elf in elfs if elf.parent.name in extensions]
    if args.match:
        regex = re.compile(args.match)
        elfs = [elf for elf in elfs if regex.search(str(elf))]
    if args.limit is not None:
        elfs = elfs[: args.limit]
    if not elfs:
        raise RuntimeError("no ELF tests selected")
    xfails = load_xfails(args.xfail)
    results: list[Result] = []
    for index, elf in enumerate(elfs, 1):
        key = elf.stem
        result = run_one(
            elf,
            backend=args.backend,
            rv64m=args.rv64m,
            results_dir=args.results_dir,
            max_cycles=args.max_cycles,
            wall_timeout=args.wall_timeout,
            trace=args.trace,
            nm=args.nm,
            engine=args.engine,
            expected_failure=key in xfails,
        )
        results.append(result)
        print(f"[{index}/{len(elfs)}] {result.status.upper()} {elf.name}")
        if args.fail_fast and result.status in ("fail", "xpass"):
            break
    summary = args.results_dir / f"summary-{args.backend}.json"
    summary.parent.mkdir(parents=True, exist_ok=True)
    summary.write_text(json.dumps([asdict(result) for result in results], indent=2) + "\n")
    write_junit(results, args.junit or args.results_dir / f"junit-{args.backend}.xml")
    counts = {
        status: sum(r.status == status for r in results)
        for status in ("pass", "fail", "xfail", "xpass")
    }
    print("SUMMARY " + " ".join(f"{key}={value}" for key, value in counts.items()))
    return 1 if counts["fail"] or counts["xpass"] else 0


def parse_sail_trace(text: str) -> list[dict[str, int]]:
    rows: list[dict[str, int]] = []
    for line in text.splitlines():
        instruction = SAIL_INSTR_RE.match(line)
        if instruction:
            rows.append(
                {
                    "pc": int(instruction.group(1), 16),
                    "instr": int(instruction.group(2), 16),
                }
            )
            continue
        update = SAIL_GPR_RE.match(line.strip())
        if update and rows:
            rows[-1]["rd"] = int(update.group(1))
            rows[-1]["wdata"] = int(update.group(2), 16)
    return rows


def diff_subcommand(args: argparse.Namespace) -> int:
    args.trace = True
    result = run_one(
        args.elf,
        backend=args.backend,
        rv64m=args.rv64m,
        results_dir=args.results_dir,
        max_cycles=args.max_cycles,
        wall_timeout=args.wall_timeout,
        trace=True,
        nm=args.nm,
        engine=args.engine,
    )
    if result.status != "pass" or result.trace is None:
        print(f"DUT {result.status}: {result.log}")
        return 1
    with Path(result.trace).open(newline="") as stream:
        dut = [row for row in csv.DictReader(stream) if row["arch"] == "1"]
    if any(row["exception"] == "1" for row in dut):
        raise RuntimeError("differential mode currently requires a no-trap program")
    command = [
        str(args.sail),
        "--config",
        str(args.sail_config),
        "--trace-instr",
        "--trace-gpr",
        "--inst-limit",
        str(len(dut) + 8),
        str(args.elf.resolve()),
    ]
    completed = run_command(command, timeout=args.wall_timeout)
    sail_log = Path(result.log).with_name("sail.log")
    sail_log.write_text(completed.stdout)
    sail = parse_sail_trace(completed.stdout)
    if len(sail) < len(dut):
        print(f"DIFF FAIL Sail retired {len(sail)}, DUT retired {len(dut)}")
        return 1
    for index, (dut_row, sail_row) in enumerate(zip(dut, sail)):
        pc = int(dut_row["pc"], 16)
        instr = int(dut_row["instr"], 16)
        if pc != sail_row["pc"] or instr != sail_row["instr"]:
            print(
                f"DIFF FAIL order={index} DUT pc={pc:016x} instr={instr:08x} "
                f"Sail pc={sail_row['pc']:016x} instr={sail_row['instr']:08x}"
            )
            return 1
        if dut_row["rd_write"] == "1" and int(dut_row["rd"]) != 0:
            rd = int(dut_row["rd"])
            wdata = int(dut_row["wdata"], 16)
            if sail_row.get("rd") != rd or sail_row.get("wdata") != wdata:
                print(
                    f"DIFF FAIL order={index} x{rd} DUT={wdata:016x} "
                    f"Sail={sail_row.get('wdata')}"
                )
                return 1
    print(f"DIFF PASS backend={args.backend} instructions={len(dut)}")
    return 0


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser()
    sub = top.add_subparsers(dest="command", required=True)

    doctor_parser = sub.add_parser("doctor")
    doctor_parser.set_defaults(func=doctor)

    run_parser = sub.add_parser("run")
    run_parser.add_argument("elf", type=Path)
    add_run_options(run_parser)
    run_parser.set_defaults(func=run_subcommand)

    suite_parser = sub.add_parser("suite")
    suite_parser.add_argument("paths", type=Path, nargs="+")
    add_run_options(suite_parser)
    suite_parser.add_argument(
        "--extensions",
        help="comma-separated parent directories to select",
    )
    suite_parser.add_argument("--match")
    suite_parser.add_argument("--limit", type=int)
    suite_parser.add_argument("--xfail", type=Path)
    suite_parser.add_argument("--junit", type=Path)
    suite_parser.add_argument("--fail-fast", action="store_true")
    suite_parser.set_defaults(func=suite_subcommand)

    diff_parser = sub.add_parser("diff")
    diff_parser.add_argument("elf", type=Path)
    add_run_options(diff_parser)
    diff_parser.add_argument("--sail", type=Path, required=True)
    diff_parser.add_argument("--sail-config", type=Path, required=True)
    diff_parser.set_defaults(func=diff_subcommand)
    return top


def main() -> int:
    args = parser().parse_args()
    try:
        return args.func(args)
    except (FileNotFoundError, RuntimeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
