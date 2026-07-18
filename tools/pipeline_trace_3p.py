#!/usr/bin/env python3
"""Render openrv64-3p-cycle-v1 CSV as a pipeline and stall report."""

from __future__ import annotations

import argparse
import csv
from collections import Counter
from pathlib import Path


SCHEMA = "openrv64-3p-cycle-v1"
STAGES = (
    ("F", "fetch_valid", "f"),
    ("D", "decode_valid", "d"),
    ("I", "issue_valid", "i"),
    ("C", "complete_valid", "c"),
    ("R", "retire_valid", "r"),
)
HEX_FIELDS = {
    "fetch_valid", "fetch_ready", "fetch_fire",
    "decode_valid", "decode_ready", "decode_fire",
    "issue_valid", "complete_valid", "retire_valid",
    "raw", "waw", "read_port", "write_busy", "stall_causes",
}
DEC_FIELDS = {
    "cycle", "retire_count", "dispatch_q", "retire_q",
    "barrier", "bp_present", "bp_allocate", "bp_taken",
    "bp_fetch_stall", "bp_decode_stall", "redirect",
    "fetch_req_valid", "fetch_req_ready", "fetch_resp_valid",
    "axi_arvalid", "axi_arready",
}


def load(path: Path) -> list[dict[str, int | str]]:
    rows: list[dict[str, int | str]] = []
    with path.open(newline="", encoding="utf-8") as source:
        reader = csv.DictReader(source)
        if reader.fieldnames is None:
            raise ValueError("trace has no CSV header")
        required = {"schema", *HEX_FIELDS, *DEC_FIELDS}
        for _, _, prefix in STAGES:
            for lane in range(3):
                required.update({
                    f"{prefix}{lane}_uid",
                    f"{prefix}{lane}_pc",
                    f"{prefix}{lane}_instr",
                })
        missing = sorted(required.difference(reader.fieldnames))
        if missing:
            raise ValueError(f"trace is missing columns: {', '.join(missing)}")

        identities: dict[int, tuple[int, int]] = {}
        for line_number, raw in enumerate(reader, start=2):
            if raw["schema"] != SCHEMA:
                raise ValueError(
                    f"line {line_number}: unsupported schema {raw['schema']!r}"
                )
            row: dict[str, int | str] = {"schema": raw["schema"]}
            for field in HEX_FIELDS:
                row[field] = int(raw[field], 16)
            for field in DEC_FIELDS:
                row[field] = int(raw[field], 10)
            for _, mask_field, prefix in STAGES:
                mask = int(row[mask_field])
                for lane in range(3):
                    uid = int(raw[f"{prefix}{lane}_uid"], 16)
                    pc = int(raw[f"{prefix}{lane}_pc"], 16)
                    instr = int(raw[f"{prefix}{lane}_instr"], 16)
                    row[f"{prefix}{lane}_uid"] = uid
                    row[f"{prefix}{lane}_pc"] = pc
                    row[f"{prefix}{lane}_instr"] = instr
                    if mask & (1 << lane):
                        if uid == 0:
                            raise ValueError(
                                f"line {line_number}: valid {prefix}{lane} has UID zero"
                            )
                        # F/D IDs are tentative until a dispatch candidate
                        # fires. A held younger lane behind a control may be
                        # discarded and its number reused. Issue is the first
                        # stable dynamic identity in the present 3P contract.
                        if prefix in ("i", "c", "r"):
                            old = identities.setdefault(uid, (pc, instr))
                            if old != (pc, instr):
                                raise ValueError(
                                    f"line {line_number}: UID {uid:x} changed identity"
                                )
            rows.append(row)
    if not rows:
        raise ValueError("trace contains no cycle rows")
    return rows


def popcount(value: int) -> int:
    return value.bit_count()


def stage_text(row: dict[str, int | str], mask_field: str, prefix: str) -> str:
    mask = int(row[mask_field])
    values = []
    for lane in range(3):
        if mask & (1 << lane):
            uid = int(row[f"{prefix}{lane}_uid"])
            pc = int(row[f"{prefix}{lane}_pc"])
            values.append(f"{uid:x}@{pc & 0xffff:04x}")
    return "/".join(values) if values else "-"


def stall_labels(row: dict[str, int | str]) -> str:
    labels: list[str] = []
    if int(row["raw"]):
        labels.append(f"RAW={int(row['raw']):x}")
    if int(row["waw"]):
        labels.append(f"WAW={int(row['waw']):x}")
    if int(row["read_port"]):
        labels.append(f"RPORT={int(row['read_port']):x}")
    if int(row["barrier"]):
        labels.append("BARRIER")
    if int(row["bp_fetch_stall"]) or int(row["bp_decode_stall"]):
        labels.append("BPSTALL")
    if int(row["redirect"]):
        labels.append("REDIRECT")
    if int(row["fetch_req_valid"]) and not int(row["fetch_req_ready"]):
        labels.append("AXIWAIT")
    if int(row["dispatch_q"]) and not int(row["issue_valid"]):
        labels.append("NOISSUE")
    return "+".join(labels) if labels else "-"


def summary(rows: list[dict[str, int | str]]) -> str:
    cycles = len(rows)
    retired = sum(int(row["retire_count"]) for row in rows)
    lines = [
        "SUMMARY",
        f"  cycles={cycles} retired={retired} IPC={retired / cycles:.4f}",
        "  stage  active_cycles  occupied_slots  slot_utilization",
    ]
    for name, mask_field, _ in STAGES:
        active = sum(bool(int(row[mask_field])) for row in rows)
        slots = sum(popcount(int(row[mask_field])) for row in rows)
        lines.append(
            f"  {name:<5} {active:5d}/{cycles:<5d} {slots:7d}/{cycles * 3:<7d} "
            f"{slots / (cycles * 3):7.2%}"
        )

    counts = Counter()
    for row in rows:
        dispatch_q = int(row["dispatch_q"])
        fetch_valid = int(row["fetch_valid"])
        fetch_fire = int(row["fetch_fire"])
        issue_valid = int(row["issue_valid"])
        retire_valid = int(row["retire_valid"])
        counts["frontend_empty"] += fetch_valid == 0
        counts["frontend_held"] += bool(fetch_valid and not fetch_fire)
        counts["dispatch_empty"] += dispatch_q == 0
        counts["queued_no_issue"] += bool(dispatch_q and not issue_valid)
        counts["queued_raw"] += bool(dispatch_q and int(row["raw"]))
        counts["queued_waw"] += bool(dispatch_q and int(row["waw"]))
        counts["queued_read_port"] += bool(
            dispatch_q and int(row["read_port"])
        )
        counts["queued_barrier"] += bool(dispatch_q and int(row["barrier"]))
        counts["retire_wait"] += bool(int(row["retire_q"]) and not retire_valid)
        counts["bp_stall"] += bool(
            int(row["bp_fetch_stall"]) or int(row["bp_decode_stall"])
        )
        counts["redirect"] += bool(int(row["redirect"]))
        counts["axi_wait"] += bool(
            int(row["fetch_req_valid"]) and not int(row["fetch_req_ready"])
        )
    lines.append("  stall_cycles:")
    for name in (
        "frontend_empty", "frontend_held", "dispatch_empty",
        "queued_no_issue", "queued_raw", "queued_waw",
        "queued_read_port", "queued_barrier", "retire_wait",
        "bp_stall", "redirect", "axi_wait",
    ):
        lines.append(f"    {name:<20} {counts[name]:5d}  {counts[name] / cycles:7.2%}")
    return "\n".join(lines)


def find_anchor(rows: list[dict[str, int | str]], pc: int | None) -> int:
    if pc is None:
        return 0
    for index, row in enumerate(rows):
        mask = int(row["retire_valid"])
        for lane in range(3):
            if mask & (1 << lane) and int(row[f"r{lane}_pc"]) == pc:
                return index
    raise ValueError(f"retired PC 0x{pc:x} does not appear in trace")


def window(
    rows: list[dict[str, int | str]], start: int, count: int
) -> str:
    lines = [
        "",
        "PIPELINE WINDOW",
        "  cyc | fetch             | decode            | issue             | complete          | retire            | dq/rq | stalls",
    ]
    for row in rows[start:start + count]:
        fields = [
            stage_text(row, mask_field, prefix)
            for _, mask_field, prefix in STAGES
        ]
        lines.append(
            f"  {int(row['cycle']):3d} | {fields[0]:17.17s} | "
            f"{fields[1]:17.17s} | {fields[2]:17.17s} | "
            f"{fields[3]:17.17s} | {fields[4]:17.17s} | "
            f"{int(row['dispatch_q'])}/{int(row['retire_q'])}   | "
            f"{stall_labels(row)}"
        )
    return "\n".join(lines)


def parse_pc(value: str) -> int:
    return int(value, 16)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--around-pc", type=parse_pc)
    parser.add_argument("--before", type=int, default=6)
    parser.add_argument("--rows", type=int, default=28)
    args = parser.parse_args()

    rows = load(args.trace)
    anchor = find_anchor(rows, args.around_pc)
    start = max(0, anchor - args.before)
    report = summary(rows) + "\n" + window(rows, start, args.rows) + "\n"
    if args.output:
        args.output.write_text(report, encoding="utf-8")
    else:
        print(report, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
