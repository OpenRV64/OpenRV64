#!/usr/bin/env python3
"""Validate OpenRV64 architectural retirement trace invariants."""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path


FIELDS = (
    "order",
    "cycle",
    "lane",
    "arch",
    "pc",
    "instr",
    "next_pc",
    "rd_write",
    "rd",
    "wdata",
    "exception",
    "cause",
    "mode",
)


def parse_uint(value: str | None, *, name: str, line: int, base: int = 10) -> int:
    try:
        parsed = int(value, base)
    except (TypeError, ValueError) as error:
        raise ValueError(
            f"line {line}: {name} is not a base-{base} integer: {value!r}"
        ) from error
    if parsed < 0:
        raise ValueError(f"line {line}: {name} is negative")
    return parsed


def validate(path: Path) -> int:
    with path.open(newline="") as stream:
        reader = csv.DictReader(stream)
        if tuple(reader.fieldnames or ()) != FIELDS:
            raise ValueError(
                f"header mismatch: got {reader.fieldnames!r}, expected {list(FIELDS)!r}"
            )
        rows = list(reader)

    if not rows:
        raise ValueError("trace has no retirement rows")

    previous_cycle = -1
    previous_lane = -1
    for expected_order, row in enumerate(rows):
        line = expected_order + 2
        if None in row or any(value is None for value in row.values()):
            raise ValueError(f"line {line}: row does not match the declared columns")
        order = parse_uint(row["order"], name="order", line=line)
        cycle = parse_uint(row["cycle"], name="cycle", line=line)
        lane = parse_uint(row["lane"], name="lane", line=line)
        arch = parse_uint(row["arch"], name="arch", line=line)
        rd_write = parse_uint(row["rd_write"], name="rd_write", line=line)
        rd = parse_uint(row["rd"], name="rd", line=line)
        exception = parse_uint(row["exception"], name="exception", line=line)
        cause = parse_uint(row["cause"], name="cause", line=line)
        mode = parse_uint(row["mode"], name="mode", line=line)

        if order != expected_order:
            raise ValueError(
                f"line {line}: order is {order}, expected contiguous {expected_order}"
            )
        if cycle < previous_cycle:
            raise ValueError(
                f"line {line}: cycle regressed from {previous_cycle} to {cycle}"
            )
        expected_lane = previous_lane + 1 if cycle == previous_cycle else 0
        if lane != expected_lane:
            raise ValueError(
                f"line {line}: lane is {lane}, expected {expected_lane} in cycle {cycle}"
            )
        if lane > 2:
            raise ValueError(f"line {line}: lane {lane} is outside 0..2")
        if arch not in (0, 1) or rd_write not in (0, 1) or exception not in (0, 1):
            raise ValueError(f"line {line}: arch/rd_write/exception fields must be bits")
        if not arch and rd_write:
            raise ValueError(f"line {line}: non-architectural retirement writes a register")
        if rd > 31:
            raise ValueError(f"line {line}: rd {rd} is outside x0..x31")
        if cause > 31:
            raise ValueError(f"line {line}: cause {cause} exceeds the trace's 5-bit field")
        if mode not in (0, 1, 3):
            raise ValueError(f"line {line}: invalid RISC-V privilege mode {mode}")

        for name, digits in (
            ("pc", 16),
            ("instr", 8),
            ("next_pc", 16),
            ("wdata", 16),
        ):
            value = row[name]
            if len(value) != digits or any(
                char not in "0123456789abcdefABCDEF" for char in value
            ):
                raise ValueError(f"line {line}: {name} must be exactly {digits} hex digits")
        if arch and not exception:
            if int(row["pc"], 16) & 3:
                raise ValueError(f"line {line}: architectural PC is not 4-byte aligned")
            if int(row["next_pc"], 16) & 3:
                raise ValueError(f"line {line}: architectural next_pc is not 4-byte aligned")

        previous_cycle = cycle
        previous_lane = lane

    return len(rows)


def discover(paths: list[Path]) -> list[Path]:
    found: list[Path] = []
    for path in paths:
        if path.is_file():
            found.append(path)
        elif path.is_dir():
            found.extend(path.rglob("arch.csv"))
        else:
            raise FileNotFoundError(path)
    return sorted({path.resolve() for path in found})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    try:
        paths = discover(args.paths)
        if not paths:
            raise ValueError("no arch.csv traces found")
        for path in paths:
            rows = validate(path)
            print(f"TRACE PASS {path} rows={rows}")
        return 0
    except (FileNotFoundError, OSError, ValueError) as error:
        print(f"TRACE FAIL {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
