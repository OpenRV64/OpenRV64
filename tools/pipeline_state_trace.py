#!/usr/bin/env python3
"""Validate and summarize openrv64-pipeline-state-v1 resident-state CSV."""

from __future__ import annotations

import argparse
import csv
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path


SCHEMA = "openrv64-pipeline-state-v1"
HEADER = (
    "schema", "cycle", "insn_id", "core_id", "pc", "instr", "stage",
    "slot", "lane", "state", "reason", "blocker_id", "flags",
    "detail0", "detail1",
)
STAGES = {
    1: "FETCH",
    2: "DECODE",
    3: "SCHED",
    4: "REGREAD",
    5: "EXEC",
    6: "COMPLETE",
    7: "LSQ",
    8: "ROB",
    9: "RETIRE",
}
STATES = {
    1: "PRESENT",
    2: "WAIT",
    3: "READY",
    4: "FIRE",
    5: "PENDING",
    6: "ACTIVE",
    7: "WORKER",
    8: "LOAD",
    9: "STORE",
    10: "INCOMPLETE",
    11: "COMPLETE",
    12: "HEAD",
}
REASONS = {
    0: "NONE",
    1: "SRC1_PENDING",
    2: "SRC2_PENDING",
    3: "BOTH_SOURCES_PENDING",
    4: "OLDER_HARD",
    5: "PERSISTENT_BARRIER",
    6: "RETIRE_HEAD_REQUIRED",
    7: "OLDER_MEMORY",
    8: "OLDER_CONTROL",
    9: "BRANCH_ORDER",
    10: "PIPE_CONFLICT",
    11: "ISSUE_WIDTH",
    12: "PIPE_BUSY",
    13: "REGREAD_PORT",
    14: "REGREAD_BUFFER",
    15: "EXEC_WORKER",
    16: "COMPLETION_BACKPRESSURE",
    17: "XLATE_ARBITRATION",
    18: "XLATE_RESPONSE",
    19: "STORE_GUARD",
    20: "MEMORY_ORDER",
    21: "MEMORY_PORT",
    22: "MEMORY_RESPONSE",
    23: "POSTED_STORE_ACK",
    24: "ROB_INCOMPLETE",
    25: "ROB_ORDER",
    26: "RETIRE_BACKPRESSURE",
    27: "REDIRECT_SQUASH",
    28: "FRONTEND_CONTROL",
    29: "BP_STALL",
    30: "TRANSLATION_BARRIER",
    31: "RENAME_TAG",
    32: "ROB_CAPACITY",
    33: "SCHED_CAPACITY",
    34: "DECODE_DOWNSTREAM",
    35: "HALT_OR_WFI",
    36: "RESULT_ARBITRATION",
    37: "ATOMIC_UNIT",
    255: "UNKNOWN",
}


@dataclass(frozen=True)
class Row:
    line: int
    cycle: int
    insn_id: int
    core_id: int
    pc: int
    instr: int
    stage: int
    slot: int
    lane: int
    state: int
    reason: int
    blocker_id: int
    flags: int
    detail0: int
    detail1: int


def parse_int(value: str, base: int, field: str, line: int) -> int:
    try:
        return int(value, base)
    except ValueError as exc:
        raise ValueError(
            f"line {line}: invalid {field} value {value!r}"
        ) from exc


def parse_id(text: str) -> int:
    value = text.lower()
    return int(value, 16 if not value.startswith("0x") else 0)


def select_row(row: Row, args: argparse.Namespace) -> bool:
    if args.instruction is not None and row.insn_id != args.instruction:
        return False
    if args.start_cycle is not None and row.cycle < args.start_cycle:
        return False
    if (args.start_cycle is not None and args.cycles is not None and
            row.cycle >= args.start_cycle + args.cycles):
        return False
    return True


def validate_and_collect(
    path: Path, args: argparse.Namespace
) -> tuple[list[str], int]:
    stage_counts: Counter[int] = Counter()
    state_counts: Counter[int] = Counter()
    reason_counts: Counter[int] = Counter()
    identities: dict[int, tuple[int, int]] = {}
    selected: list[Row] = []
    row_count = 0
    cycle_count = 0
    first_cycle: int | None = None
    last_cycle: int | None = None
    cycle_keys: set[tuple[int, int, int, int]] = set()

    with path.open(newline="", encoding="utf-8") as source:
        reader = csv.DictReader(source)
        if reader.fieldnames is None:
            raise ValueError("trace has no CSV header")
        if tuple(reader.fieldnames) != HEADER:
            raise ValueError(
                "trace header does not match openrv64-pipeline-state-v1: "
                f"{','.join(reader.fieldnames)}"
            )

        for line, raw in enumerate(reader, start=2):
            if raw["schema"] != SCHEMA:
                raise ValueError(
                    f"line {line}: unsupported schema {raw['schema']!r}"
                )
            row = Row(
                line=line,
                cycle=parse_int(raw["cycle"], 10, "cycle", line),
                insn_id=parse_int(raw["insn_id"], 16, "insn_id", line),
                core_id=parse_int(raw["core_id"], 16, "core_id", line),
                pc=parse_int(raw["pc"], 16, "pc", line),
                instr=parse_int(raw["instr"], 16, "instr", line),
                stage=parse_int(raw["stage"], 10, "stage", line),
                slot=parse_int(raw["slot"], 10, "slot", line),
                lane=parse_int(raw["lane"], 10, "lane", line),
                state=parse_int(raw["state"], 10, "state", line),
                reason=parse_int(raw["reason"], 10, "reason", line),
                blocker_id=parse_int(
                    raw["blocker_id"], 16, "blocker_id", line
                ),
                flags=parse_int(raw["flags"], 16, "flags", line),
                detail0=parse_int(raw["detail0"], 16, "detail0", line),
                detail1=parse_int(raw["detail1"], 16, "detail1", line),
            )

            if row.cycle > 0xFFFFFFFF:
                raise ValueError(f"line {line}: cycle exceeds v1 width")
            if row.insn_id == 0 or row.insn_id > 0xFFFFFFFF:
                raise ValueError(f"line {line}: invalid v1 instruction ID")
            if row.blocker_id > 0xFFFFFFFF:
                raise ValueError(f"line {line}: blocker ID exceeds v1 width")
            if row.stage not in STAGES:
                raise ValueError(f"line {line}: unknown stage {row.stage}")
            if row.state not in STATES:
                raise ValueError(f"line {line}: unknown state {row.state}")
            if row.reason not in REASONS:
                raise ValueError(f"line {line}: unknown reason {row.reason}")
            if row.reason == 0 and row.blocker_id != 0:
                raise ValueError(
                    f"line {line}: blocker ID present with reason NONE"
                )
            if last_cycle is not None and row.cycle < last_cycle:
                raise ValueError(
                    f"line {line}: cycle regressed from {last_cycle} "
                    f"to {row.cycle}"
                )
            if last_cycle != row.cycle:
                cycle_count += 1
                cycle_keys.clear()
            key = (row.insn_id, row.stage, row.slot, row.lane)
            if key in cycle_keys:
                raise ValueError(
                    f"line {line}: duplicate component record for "
                    f"instruction {row.insn_id:08x}"
                )
            cycle_keys.add(key)

            identity = identities.setdefault(row.insn_id, (row.pc, row.instr))
            if identity != (row.pc, row.instr):
                raise ValueError(
                    f"line {line}: instruction {row.insn_id:08x} changed "
                    "PC or encoding"
                )

            row_count += 1
            first_cycle = row.cycle if first_cycle is None else first_cycle
            last_cycle = row.cycle
            stage_counts[row.stage] += 1
            state_counts[row.state] += 1
            if row.reason != 0:
                reason_counts[row.reason] += 1
            if select_row(row, args) and len(selected) < args.rows:
                selected.append(row)

    if row_count == 0:
        raise ValueError("trace contains no resident-state rows")

    report = [
        f"trace: {path}",
        f"schema: {SCHEMA}",
        f"cycles: {first_cycle}..{last_cycle} ({cycle_count} sampled)",
        f"rows: {row_count}",
        f"instructions: {len(identities)}",
        "",
        "component rows:",
    ]
    report.extend(
        f"  {STAGES[code]:8s} {stage_counts[code]}"
        for code in STAGES if stage_counts[code]
    )
    report.extend(("", "primary non-progress reasons:"))
    if reason_counts:
        report.extend(
            f"  {REASONS[code]:28s} {count}"
            for code, count in reason_counts.most_common()
        )
    else:
        report.append("  none")
    report.extend(("", "selected records:"))
    if selected:
        for row in selected:
            blocker = f" blocker={row.blocker_id:08x}" if row.blocker_id else ""
            report.append(
                f"  c={row.cycle:10d} id={row.insn_id:08x} "
                f"pc={row.pc:016x} insn={row.instr:08x} "
                f"{STAGES[row.stage]}[{row.slot},{row.lane}] "
                f"{STATES[row.state]} reason={REASONS[row.reason]}"
                f"{blocker} flags={row.flags:016x} "
                f"d0={row.detail0:016x} d1={row.detail1:016x}"
            )
    else:
        report.append("  no records matched the selection")
    report.extend(("", f"PIPELINE_STATE_TRACE_OK rows={row_count}"))
    return report, row_count


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate and summarize an OpenRV64 resident-state trace"
    )
    parser.add_argument("trace", type=Path)
    parser.add_argument(
        "--instruction", type=parse_id,
        help="select one hexadecimal 32-bit instruction ID",
    )
    parser.add_argument("--start-cycle", type=int)
    parser.add_argument(
        "--cycles", type=int,
        help="with --start-cycle, select this many cycles",
    )
    parser.add_argument(
        "--rows", type=int, default=200,
        help="maximum selected records in the report (default: 200)",
    )
    parser.add_argument("--output", type=Path)
    return parser


def main() -> int:
    parser = argument_parser()
    args = parser.parse_args()
    if args.rows < 0:
        parser.error("--rows must be nonnegative")
    if args.cycles is not None and args.cycles <= 0:
        parser.error("--cycles must be positive")
    if args.cycles is not None and args.start_cycle is None:
        parser.error("--cycles requires --start-cycle")
    try:
        report, _ = validate_and_collect(args.trace, args)
    except (OSError, ValueError) as exc:
        print(f"pipeline_state_trace.py: error: {exc}", file=sys.stderr)
        return 2
    text = "\n".join(report) + "\n"
    if args.output is not None:
        args.output.write_text(text, encoding="utf-8")
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
