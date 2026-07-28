#!/usr/bin/env python3
"""Symbolize periodic Linux boot PC samples from a tb_opensbi log.

The testbench emits one progress PC every 250,000 cycles after early boot.
These PCs form a low-resolution point-sample profile.  They are useful for
finding large residency concentrations, but they are not exact cycle
attribution: a sample says where the core was at that instant, not where it
spent the complete interval since the preceding sample.
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import datetime
import pathlib
import re
import subprocess
import sys


PROGRESS_RE = re.compile(
    r"OpenSBI progress cycles=(?P<cycles>\d+)"
    r" instret=(?P<instret>\d+)"
    r".*? pc=(?P<pc>[0-9a-fA-F]+)"
    r".*? priv=(?P<priv>\d+)"
)
KERNEL_BASE = 0xFFFF_FFFF_8000_0000


@dataclasses.dataclass(frozen=True)
class Sample:
    cycles: int
    instret: int
    pc: int
    priv: int


@dataclasses.dataclass(frozen=True)
class Symbol:
    function: str
    location: str


def parse_samples(path: pathlib.Path) -> list[Sample]:
    samples: list[Sample] = []
    for line in path.read_text(errors="replace").splitlines():
        for match in PROGRESS_RE.finditer(line):
            samples.append(
                Sample(
                    cycles=int(match.group("cycles")),
                    instret=int(match.group("instret")),
                    pc=int(match.group("pc"), 16),
                    priv=int(match.group("priv")),
                )
            )
    samples.sort(key=lambda sample: sample.cycles)
    return samples


def symbolize(
    vmlinux: pathlib.Path, addresses: list[int]
) -> dict[int, Symbol]:
    if not addresses:
        return {}
    command = [
        "riscv64-linux-gnu-addr2line",
        "-f",
        "-C",
        "-e",
        str(vmlinux),
        *(f"0x{address:x}" for address in addresses),
    ]
    result = subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
    )
    lines = result.stdout.splitlines()
    if len(lines) != 2 * len(addresses):
        raise RuntimeError(
            "addr2line returned an unexpected number of output lines: "
            f"{len(lines)} for {len(addresses)} addresses"
        )
    return {
        address: Symbol(lines[2 * index], lines[2 * index + 1])
        for index, address in enumerate(addresses)
    }


def privilege_class(sample: Sample) -> str:
    if sample.priv == 1 and sample.pc >= KERNEL_BASE:
        return "kernel S-mode"
    if sample.priv == 3:
        return "machine mode"
    if sample.priv == 0:
        return "user mode"
    if sample.priv == 1:
        return "non-kernel S-mode"
    return f"privilege {sample.priv}"


def format_cycles(cycles: int) -> str:
    if cycles >= 1_000_000:
        return f"{cycles / 1_000_000:.3f}M"
    if cycles >= 1_000:
        return f"{cycles / 1_000:.3f}K"
    return str(cycles)


def markdown_report(
    log: pathlib.Path,
    vmlinux: pathlib.Path,
    samples: list[Sample],
    symbols: dict[int, Symbol],
    top: int,
    cadence: int,
) -> str:
    generated = datetime.datetime.now(datetime.timezone.utc).isoformat(
        timespec="seconds"
    )
    first = samples[0]
    last = samples[-1]
    categories = collections.Counter(privilege_class(sample) for sample in samples)
    kernel_samples = [
        sample for sample in samples
        if privilege_class(sample) == "kernel S-mode"
    ]

    function_counts: collections.Counter[str] = collections.Counter()
    function_location: dict[str, str] = {}
    for sample in kernel_samples:
        symbol = symbols.get(sample.pc, Symbol("??", "??:0"))
        function_counts[symbol.function] += 1
        function_location.setdefault(symbol.function, symbol.location)

    output = [
        "# Linux boot PC sample histogram",
        "",
        f"Generated: `{generated}`",
        "",
        f"Log: `{log}`",
        "",
        f"Symbols: `{vmlinux}`",
        "",
        "## Method and scope",
        "",
        (
            "This is a periodic point-sample profile from `OpenSBI progress` "
            "records. A hit identifies the PC at the sampling instant; it "
            "does not prove that the complete interval was spent in that "
            "function."
        ),
        "",
        f"- Cycle range: `{first.cycles}` to `{last.cycles}`",
        f"- Retired-instruction range: `{first.instret}` to `{last.instret}`",
        f"- Samples: `{len(samples)}`",
        f"- Nominal cadence: `{cadence}` cycles",
        (
            "- Sample-equivalent cycles below are `hits * cadence`; they are "
            "an intuitive scale, not exact attribution."
        ),
        "",
        "## Privilege histogram",
        "",
        "| Class | Samples | Percent | Sample-equivalent cycles |",
        "|---|---:|---:|---:|",
    ]
    for name, count in categories.most_common():
        output.append(
            f"| {name} | {count} | {100 * count / len(samples):.2f}% | "
            f"{format_cycles(count * cadence)} |"
        )

    output.extend(
        (
            "",
            "## Top kernel functions",
            "",
            (
                "| Rank | Function | Hits | Kernel samples | All samples | "
                "Sample-equivalent cycles | Source |"
            ),
            "|---:|---|---:|---:|---:|---:|---|",
        )
    )
    for rank, (function, count) in enumerate(
        function_counts.most_common(top), start=1
    ):
        kernel_percent = (
            100 * count / len(kernel_samples) if kernel_samples else 0.0
        )
        output.append(
            f"| {rank} | `{function}` | {count} | "
            f"{kernel_percent:.2f}% | {100 * count / len(samples):.2f}% | "
            f"{format_cycles(count * cadence)} | "
            f"`{function_location[function]}` |"
        )
    if not function_counts:
        output.append("| - | No symbolized kernel samples | 0 | 0% | 0% | 0 | - |")

    output.extend(
        (
            "",
            "## Interpretation limits",
            "",
            "- The cadence is coarse enough to miss short hot paths.",
            "- Deterministic periodic sampling can alias with periodic loops.",
            "- Stall causes are not identified by a PC histogram.",
            (
                "- Exact cycle attribution requires a denser runtime-gated "
                "cycle trace or dedicated hardware/simulation counters."
            ),
            "",
        )
    )
    return "\n".join(output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=pathlib.Path)
    parser.add_argument(
        "--vmlinux",
        type=pathlib.Path,
        default=pathlib.Path("/home/bill/src/linux/vmlinux"),
    )
    parser.add_argument("--start-cycle", type=int)
    parser.add_argument("--end-cycle", type=int)
    parser.add_argument("--top", type=int, default=30)
    parser.add_argument(
        "--cadence",
        type=int,
        default=250_000,
        help="retain only samples aligned to this cadence (default: 250000)",
    )
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        help="write Markdown to this path instead of stdout",
    )
    args = parser.parse_args()

    if not args.log.is_file():
        print(f"error: log does not exist: {args.log}", file=sys.stderr)
        return 2
    if not args.vmlinux.is_file():
        print(f"error: vmlinux does not exist: {args.vmlinux}", file=sys.stderr)
        return 2
    if args.cadence <= 0:
        print("error: cadence must be positive", file=sys.stderr)
        return 2
    if args.top <= 0:
        print("error: top must be positive", file=sys.stderr)
        return 2

    samples = [
        sample for sample in parse_samples(args.log)
        if sample.cycles % args.cadence == 0
        and (args.start_cycle is None or sample.cycles >= args.start_cycle)
        and (args.end_cycle is None or sample.cycles <= args.end_cycle)
    ]
    first_kernel_index = next(
        (
            index for index, sample in enumerate(samples)
            if privilege_class(sample) == "kernel S-mode"
        ),
        None,
    )
    if first_kernel_index is None:
        print("error: no kernel S-mode progress samples found", file=sys.stderr)
        return 1
    samples = samples[first_kernel_index:]

    kernel_addresses = sorted(
        {
            sample.pc for sample in samples
            if privilege_class(sample) == "kernel S-mode"
        }
    )
    try:
        symbols = symbolize(args.vmlinux, kernel_addresses)
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        print(f"error: symbolization failed: {error}", file=sys.stderr)
        return 1

    report = markdown_report(
        args.log,
        args.vmlinux,
        samples,
        symbols,
        args.top,
        args.cadence,
    )
    if args.output is None:
        print(report)
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
