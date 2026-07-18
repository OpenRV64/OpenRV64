#!/usr/bin/env python3
"""Render openrv64-cycle-v1 CSV as a readable pipeline/utilization report."""

from __future__ import annotations

import argparse
import csv
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, TextIO


SCHEMA = "openrv64-cycle-v1"
STAGES = ("IF", "ID", "EX", "MEM", "WB")
EVENTS = (
    "redirect",
    "trap",
    "irq",
    "mret",
    "sret",
    "restart",
    "halt",
    "reset",
)
STALL_CAUSES = (
    "raw",
    "waw",
    "scoreboard",
    "if-memory",
    "data-memory",
    "execute",
    "frontend-held",
    "serializing",
)


def parse_int(value: str, base: int, field_name: str, line_number: int) -> int:
    try:
        return int(value, base)
    except ValueError as exc:
        raise ValueError(
            f"line {line_number}: invalid {field_name} value {value!r}"
        ) from exc


@dataclass(frozen=True)
class StageValue:
    valid: bool
    uid: int
    pc: int
    instr: int


@dataclass(frozen=True)
class Row:
    cycle: int
    valid: int
    stall: int
    flush: int
    advance: int
    events: int
    stall_causes: int
    stages: tuple[StageValue, ...]
    retire_valid: bool
    retire_arch: bool
    retire_exception: bool
    retire_cause: int
    retire_next_pc: int
    retire_rd_write: bool
    retire_rd: int
    retire_wdata: int


@dataclass
class Instruction:
    uid: int
    pc: int | None = None
    instr: int | None = None
    stage_cycles: dict[str, list[int]] = field(
        default_factory=lambda: defaultdict(list)
    )
    stall_cycles: int = 0
    retire_cycle: int | None = None
    retire_arch: bool = False
    exception: bool = False
    cause: int = 0
    next_pc: int = 0
    rd_write: bool = False
    rd: int = 0
    wdata: int = 0


def load_rows(path: Path) -> list[Row]:
    rows: list[Row] = []
    with path.open(newline="", encoding="utf-8") as source:
        reader = csv.DictReader(source)
        if reader.fieldnames is None:
            raise ValueError("trace has no CSV header")

        required = {
            "schema", "cycle", "valid", "stall", "flush", "advance",
            "events", "stall_causes", "retire_valid", "retire_arch",
            "retire_exception", "retire_cause", "retire_next_pc",
            "retire_rd_write", "retire_rd", "retire_wdata",
        }
        for stage in ("if", "id", "ex", "mem", "wb"):
            required.update({f"{stage}_uid", f"{stage}_pc", f"{stage}_instr"})
        missing = sorted(required.difference(reader.fieldnames))
        if missing:
            raise ValueError(f"trace is missing columns: {', '.join(missing)}")

        for line_number, raw in enumerate(reader, start=2):
            if raw["schema"] != SCHEMA:
                raise ValueError(
                    f"line {line_number}: unsupported schema {raw['schema']!r}"
                )
            valid = parse_int(raw["valid"], 16, "valid", line_number)
            stages: list[StageValue] = []
            for index, name in enumerate(("if", "id", "ex", "mem", "wb")):
                stages.append(StageValue(
                    valid=bool(valid & (1 << index)),
                    uid=parse_int(raw[f"{name}_uid"], 16, f"{name}_uid", line_number),
                    pc=parse_int(raw[f"{name}_pc"], 16, f"{name}_pc", line_number),
                    instr=parse_int(
                        raw[f"{name}_instr"], 16, f"{name}_instr", line_number
                    ),
                ))
            rows.append(Row(
                cycle=parse_int(raw["cycle"], 10, "cycle", line_number),
                valid=valid,
                stall=parse_int(raw["stall"], 16, "stall", line_number),
                flush=parse_int(raw["flush"], 16, "flush", line_number),
                advance=parse_int(raw["advance"], 16, "advance", line_number),
                events=parse_int(raw["events"], 16, "events", line_number),
                stall_causes=parse_int(
                    raw["stall_causes"], 16, "stall_causes", line_number
                ),
                stages=tuple(stages),
                retire_valid=bool(parse_int(
                    raw["retire_valid"], 10, "retire_valid", line_number
                )),
                retire_arch=bool(parse_int(
                    raw["retire_arch"], 10, "retire_arch", line_number
                )),
                retire_exception=bool(parse_int(
                    raw["retire_exception"], 10, "retire_exception", line_number
                )),
                retire_cause=parse_int(
                    raw["retire_cause"], 16, "retire_cause", line_number
                ),
                retire_next_pc=parse_int(
                    raw["retire_next_pc"], 16, "retire_next_pc", line_number
                ),
                retire_rd_write=bool(parse_int(
                    raw["retire_rd_write"], 10, "retire_rd_write", line_number
                )),
                retire_rd=parse_int(raw["retire_rd"], 10, "retire_rd", line_number),
                retire_wdata=parse_int(
                    raw["retire_wdata"], 16, "retire_wdata", line_number
                ),
            ))
    if not rows:
        raise ValueError("trace contains no cycle rows")
    return rows


def collect_instructions(rows: Iterable[Row]) -> dict[int, Instruction]:
    instructions: dict[int, Instruction] = {}
    for row in rows:
        for index, stage in enumerate(row.stages):
            if not stage.valid:
                continue
            if stage.uid == 0:
                raise ValueError(
                    f"cycle {row.cycle}: valid {STAGES[index]} stage has UID zero"
                )
            instruction_available = index != 0 or stage.instr != 0
            record_key = stage.uid
            record = instructions.setdefault(record_key,
                                             Instruction(stage.uid))
            pc_changed = record.pc is not None and record.pc != stage.pc
            instr_changed = (instruction_available and
                             record.instr is not None and
                             record.instr != stage.instr)

            # A context-changing flush can expose an in-flight fetch request
            # in the IF trace slot that was hidden behind a buffered decode in
            # the preceding cycle.  The legacy 1P trace pin can carry the
            # buffered candidate's UID on that single flushed row.  Preserve
            # the flushed request as a separate record instead of merging it
            # with the older candidate or rejecting the complete trace.
            if (pc_changed or instr_changed) and (row.flush & (1 << index)):
                record_key = ((row.cycle + 1) << 68) | (index << 64) | stage.uid
                record = Instruction(stage.uid)
                instructions[record_key] = record
                pc_changed = False
                instr_changed = False

            if pc_changed:
                raise ValueError(
                    f"cycle {row.cycle}: UID {stage.uid:x} changed PC from "
                    f"{record.pc:x} to {stage.pc:x}"
                )
            record.pc = stage.pc
            if instr_changed:
                raise ValueError(
                    f"cycle {row.cycle}: UID {stage.uid:x} changed instruction "
                    f"from {record.instr:08x} to {stage.instr:08x}"
                )
            if instruction_available:
                record.instr = stage.instr
            record.stage_cycles[STAGES[index]].append(row.cycle)
            if row.stall & (1 << index):
                record.stall_cycles += 1

        if row.retire_valid:
            wb = row.stages[4]
            if not wb.valid or wb.uid == 0:
                raise ValueError(
                    f"cycle {row.cycle}: retirement without a valid WB UID"
                )
            record = instructions.setdefault(wb.uid, Instruction(wb.uid))
            record.retire_cycle = row.cycle
            record.retire_arch = row.retire_arch
            record.exception = row.retire_exception
            record.cause = row.retire_cause
            record.next_pc = row.retire_next_pc
            record.rd_write = row.retire_rd_write
            record.rd = row.retire_rd
            record.wdata = row.retire_wdata
    return instructions


def bit_names(mask: int, names: tuple[str, ...]) -> str:
    selected = [name for index, name in enumerate(names) if mask & (1 << index)]
    return ",".join(selected) if selected else "-"


def cycle_ranges(cycles: list[int]) -> str:
    if not cycles:
        return "-"
    ordered = sorted(set(cycles))
    ranges: list[str] = []
    start = previous = ordered[0]
    for cycle in ordered[1:]:
        if cycle == previous + 1:
            previous = cycle
            continue
        ranges.append(str(start) if start == previous else f"{start}-{previous}")
        start = previous = cycle
    ranges.append(str(start) if start == previous else f"{start}-{previous}")
    return ",".join(ranges)


def write_summary(
    out: TextIO,
    rows: list[Row],
    instructions: dict[int, Instruction],
) -> None:
    completed_ids = {
        uid for uid, record in instructions.items() if record.retire_cycle is not None
    }
    cycles = len(rows)
    retired = sum(row.retire_arch for row in rows)
    exceptions = sum(row.retire_exception for row in rows)
    print("SUMMARY", file=out)
    print(
        f"  cycles={cycles} range={rows[0].cycle}-{rows[-1].cycle} "
        f"fetched_uids={len(instructions)} arch_retired={retired} "
        f"exceptions={exceptions} IPC={retired / cycles:.4f}",
        file=out,
    )
    print("  stage  occupied completed  not_done   stalls  advances", file=out)
    for index, name in enumerate(STAGES):
        occupied = sum(bool(row.valid & (1 << index)) for row in rows)
        completed = sum(
            stage.valid and stage.uid in completed_ids for row in rows
            for stage in (row.stages[index],)
        )
        stalls = sum(bool(row.stall & (1 << index)) for row in rows)
        advances = sum(bool(row.advance & (1 << index)) for row in rows)
        print(
            f"  {name:<5} {occupied:5d}/{cycles:<5d} {occupied / cycles:7.2%} "
            f"{completed:5d}/{cycles:<5d} {(occupied - completed):9d} "
            f"{stalls:8d} {advances:9d}",
            file=out,
        )
    cause_counts = [
        sum(bool(row.stall_causes & (1 << index)) for row in rows)
        for index in range(len(STALL_CAUSES))
    ]
    active_causes = [
        f"{name}={count}" for name, count in zip(STALL_CAUSES, cause_counts)
        if count
    ]
    print(f"  stall_causes: {', '.join(active_causes) if active_causes else '-'}", file=out)
    print(file=out)


def stage_cell(row: Row, index: int) -> str:
    stage = row.stages[index]
    if not stage.valid:
        return "FLUSH" if row.flush & (1 << index) else "."
    instr = "--------" if index == 0 and stage.instr == 0 else f"{stage.instr:08x}"
    marker = "~" if row.stall & (1 << index) else \
             ">" if row.advance & (1 << index) else " "
    return f"{marker}{stage.uid:x}@{stage.pc:x}:{instr}"


def write_cycles(out: TextIO, rows: list[Row], max_cycles: int) -> None:
    visible = rows if max_cycles == 0 else rows[:max_cycles]
    print("CYCLE PIPELINE  (~ held/stalled, > advances, FLUSH invalidated)", file=out)
    print(
        "cycle | IF                         | ID                         | "
        "EX                         | MEM                        | "
        "WB                         | events / stall causes",
        file=out,
    )
    for row in visible:
        cells = [f"{stage_cell(row, index):<26}" for index in range(5)]
        events = bit_names(row.events, EVENTS)
        causes = bit_names(row.stall_causes, STALL_CAUSES)
        print(
            f"{row.cycle:5d} | " + " | ".join(cells) + f" | {events} / {causes}",
            file=out,
        )
    if len(visible) < len(rows):
        print(f"... {len(rows) - len(visible)} cycles omitted; use --max-cycles 0", file=out)
    print(file=out)


def instruction_status(record: Instruction) -> str:
    if record.exception:
        return f"exception({record.cause})"
    if record.retire_arch:
        return "retired"
    if record.retire_cycle is not None:
        return "consumed"
    return "not-retired"


def write_instructions(out: TextIO, instructions: dict[int, Instruction]) -> None:
    print("INSTRUCTION TIMING", file=out)
    print(
        "uid    pc               instr     IF          ID          EX          "
        "MEM         WB          latency stalls status",
        file=out,
    )
    for uid in sorted(instructions):
        record = instructions[uid]
        all_cycles = [
            cycle for cycles in record.stage_cycles.values() for cycle in cycles
        ]
        latency = max(all_cycles) - min(all_cycles) + 1 if all_cycles else 0
        spans = [cycle_ranges(record.stage_cycles[name]) for name in STAGES]
        print(
            f"{uid:6x} {(record.pc or 0):016x} {(record.instr or 0):08x} "
            + " ".join(f"{span:<11}" for span in spans)
            + f" {latency:7d} {record.stall_cycles:6d} {instruction_status(record)}",
            file=out,
        )
    print(file=out)


def write_retire_log(out: TextIO, instructions: dict[int, Instruction]) -> None:
    retired = sorted(
        (record for record in instructions.values() if record.retire_cycle is not None),
        key=lambda record: record.retire_cycle or 0,
    )
    print("RETIRE LOG", file=out)
    print("cycle  uid    pc               instr     next_pc          result", file=out)
    for record in retired:
        if record.exception:
            result = f"exception cause={record.cause}"
        elif record.rd_write:
            result = f"x{record.rd}={record.wdata:016x}"
        elif record.retire_arch:
            result = "architectural"
        else:
            result = "consumed"
        print(
            f"{record.retire_cycle:5d} {record.uid:6x} "
            f"{(record.pc or 0):016x} {(record.instr or 0):08x} "
            f"{record.next_pc:016x} {result}",
            file=out,
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path, help="openrv64-cycle-v1 CSV")
    parser.add_argument("-o", "--output", type=Path, help="write report to this path")
    parser.add_argument("--start-cycle", type=int, help="first cycle to report")
    parser.add_argument("--end-cycle", type=int, help="last cycle to report")
    parser.add_argument(
        "--max-cycles", type=int, default=200,
        help="maximum timeline rows (0 means all; default: 200)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        all_rows = load_rows(args.trace)
        instructions = collect_instructions(all_rows)
    except (OSError, ValueError) as exc:
        print(f"pipeline_trace.py: {exc}", file=sys.stderr)
        return 2

    rows = [
        row for row in all_rows
        if (args.start_cycle is None or row.cycle >= args.start_cycle)
        and (args.end_cycle is None or row.cycle <= args.end_cycle)
    ]
    if not rows:
        print("pipeline_trace.py: selected cycle range is empty", file=sys.stderr)
        return 2

    destination: TextIO
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        destination = args.output.open("w", encoding="utf-8")
    else:
        destination = sys.stdout
    try:
        write_summary(destination, rows, instructions)
        write_cycles(destination, rows, args.max_cycles)
        write_instructions(destination, instructions)
        write_retire_log(destination, instructions)
    finally:
        if destination is not sys.stdout:
            destination.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
