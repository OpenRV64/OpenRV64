#!/usr/bin/env python3
"""Render versioned OpenRV64 3P cycle CSV as a causal pipeline report."""

from __future__ import annotations

import argparse
import csv
from collections import Counter
from pathlib import Path


SCHEMAS = {"openrv64-3p-cycle-v1", "openrv64-3p-cycle-v2"}
STAGES_V1 = (
    ("F", "fetch_valid", "f"),
    ("D", "decode_valid", "d"),
    ("I", "issue_valid", "i"),
    ("C", "complete_valid", "c"),
    ("R", "retire_valid", "r"),
)
STAGES_V2 = (
    ("F", "fetch_valid", "f"),
    ("D", "decode_valid", "d"),
    ("Q", "queue_valid", "q"),
    ("I", "issue_valid", "i"),
    ("C", "complete_valid", "c"),
    ("R", "retire_valid", "r"),
)
BASE_HEX_FIELDS = {
    "fetch_valid", "fetch_ready", "fetch_fire",
    "decode_valid", "decode_ready", "decode_fire",
    "issue_valid", "complete_valid", "retire_valid",
    "raw", "waw", "read_port", "write_busy", "stall_causes",
}
BASE_DEC_FIELDS = {
    "cycle", "retire_count", "dispatch_q", "retire_q",
    "barrier", "bp_present", "bp_allocate", "bp_taken",
    "bp_fetch_stall", "bp_decode_stall", "redirect",
    "fetch_req_valid", "fetch_req_ready", "fetch_resp_valid",
    "axi_arvalid", "axi_arready",
}
V2_HEX_FIELDS = {
    "queue_valid", "candidate_fire", "candidate_hazard_free",
    "candidate_pipe", "pipe_ready", "barrier_allow",
    "raw_existing", "raw_bundle", "raw_completed", "raw_rs1", "raw_rs2",
    "waw_bundle", "waw_completed", "candidate_uses_rs1", "candidate_uses_rs2",
    "candidate_reg_write", "candidate_rs1", "candidate_rs2", "candidate_rd",
    "queue_retire_valid", "completed_entries", "fetch_line_valid",
    "fetch_pending", "lsu_slots", "lsu_sent",
}
V2_DEC_FIELDS = {
    "allocation_ready", "block_lane", "block_reason", "control_flush",
    "control_redirect", "fetch_bus_q", "fetch_consume_hit",
    "fetch_follow_hit", "fetch_active", "mem_req_valid", "mem_req_ready",
    "mem_resp_valid", "mem_resp_ready", "mem_write", "lsu_store_inflight",
    "lsu_order_block",
}
V2_OPTIONAL_HEX_FIELDS = {
    "retire_gpr_write", "retire_gpr_rd", "retire_gpr_data",
    "mem_req_tag", "mem_req_addr", "mem_req_wdata", "mem_req_wstrb",
    "mem_resp_tag", "mem_resp_rdata",
}
V2_OPTIONAL_DEC_FIELDS = {
    "window_unissued", "window_operand_ready", "window_eligible",
    "window_raw_block", "window_hard_block", "window_mem_order_block",
    "window_selected", "window_issued",
}

BLOCK_REASONS = {
    0: "none",
    1: "raw_pending",
    2: "raw_bundle",
    3: "raw_completed",
    4: "waw_pending",
    5: "waw_bundle",
    6: "waw_completed",
    7: "read_port",
    8: "barrier",
    9: "retire_capacity",
    10: "pipe_conflict",
    11: "pipe_busy",
    12: "invalid_pipe",
    13: "branch_redirect",
    14: "unknown",
}
PIPE_NAMES = {0: "EX0", 1: "EX1", 2: "MEM", 3: "INVALID"}


def stages_for_schema(schema: str):
    return STAGES_V2 if schema.endswith("v2") else STAGES_V1


def load(path: Path) -> list[dict[str, int | str]]:
    with path.open(newline="", encoding="utf-8") as source:
        reader = csv.DictReader(source)
        if reader.fieldnames is None:
            raise ValueError("trace has no CSV header")
        raw_rows = list(reader)
        fieldnames = set(reader.fieldnames)

    if not raw_rows:
        raise ValueError("trace contains no cycle rows")
    schemas = {raw["schema"] for raw in raw_rows}
    if len(schemas) != 1:
        raise ValueError(f"trace mixes schemas: {', '.join(sorted(schemas))}")
    schema = schemas.pop()
    if schema not in SCHEMAS:
        raise ValueError(f"unsupported schema {schema!r}")

    hex_fields = set(BASE_HEX_FIELDS)
    dec_fields = set(BASE_DEC_FIELDS)
    if schema.endswith("v2"):
        hex_fields.update(V2_HEX_FIELDS)
        dec_fields.update(V2_DEC_FIELDS)
    stages = stages_for_schema(schema)
    required = {"schema", *hex_fields, *dec_fields}
    for _, _, prefix in stages:
        for lane in range(3):
            required.update({
                f"{prefix}{lane}_uid",
                f"{prefix}{lane}_pc",
                f"{prefix}{lane}_instr",
            })
    missing = sorted(required.difference(fieldnames))
    if missing:
        raise ValueError(f"trace is missing columns: {', '.join(missing)}")

    rows: list[dict[str, int | str]] = []
    identities: dict[int, tuple[int, int]] = {}
    for line_number, raw in enumerate(raw_rows, start=2):
        row: dict[str, int | str] = {"schema": schema}
        for field in hex_fields:
            row[field] = int(raw[field], 16)
        for field in dec_fields:
            row[field] = int(raw[field], 10)
        row["data_fields_present"] = int(
            V2_OPTIONAL_HEX_FIELDS.issubset(fieldnames)
        )
        row["window_fields_present"] = int(
            V2_OPTIONAL_DEC_FIELDS.issubset(fieldnames)
        )
        for field in V2_OPTIONAL_HEX_FIELDS:
            row[field] = int(raw[field], 16) if field in fieldnames else 0
        for field in V2_OPTIONAL_DEC_FIELDS:
            row[field] = int(raw[field], 10) if field in fieldnames else 0
        for field in V2_HEX_FIELDS.difference(hex_fields):
            row[field] = 0
        for field in V2_DEC_FIELDS.difference(dec_fields):
            row[field] = 0
        if schema.endswith("v1"):
            row["block_lane"] = 3

        for _, mask_field, prefix in stages:
            mask = int(row[mask_field])
            for lane in range(3):
                uid = int(raw[f"{prefix}{lane}_uid"], 16)
                pc = int(raw[f"{prefix}{lane}_pc"], 16)
                instr = int(raw[f"{prefix}{lane}_instr"], 16)
                row[f"{prefix}{lane}_uid"] = uid
                row[f"{prefix}{lane}_pc"] = pc
                row[f"{prefix}{lane}_instr"] = instr
                if not (mask & (1 << lane)):
                    continue
                if uid == 0:
                    raise ValueError(
                        f"line {line_number}: valid {prefix}{lane} has UID zero"
                    )
                # F/D IDs remain tentative until they enter the dispatch
                # queue. Q and all later stages must preserve identity.
                if prefix in ("q", "i", "c", "r"):
                    old = identities.setdefault(uid, (pc, instr))
                    if old != (pc, instr):
                        raise ValueError(
                            f"line {line_number}: UID {uid:x} changed identity"
                        )
        rows.append(row)
    return rows


def popcount(value: int) -> int:
    return value.bit_count()


def lane_value(row: dict[str, int | str], field: str, lane: int) -> int:
    return (int(row[field]) >> (lane * 5)) & 0x1F


def candidate_pipe(row: dict[str, int | str], lane: int) -> int:
    return (int(row["candidate_pipe"]) >> (lane * 2)) & 0x3


def stage_text(row: dict[str, int | str], mask_field: str, prefix: str) -> str:
    mask = int(row[mask_field])
    values = []
    for lane in range(3):
        if mask & (1 << lane):
            uid = int(row[f"{prefix}{lane}_uid"])
            pc = int(row[f"{prefix}{lane}_pc"])
            values.append(f"{uid:x}@{pc & 0xffff:04x}")
    return "/".join(values) if values else "-"


def block_text(row: dict[str, int | str]) -> str | None:
    if not str(row["schema"]).endswith("v2"):
        return None
    reason = int(row["block_reason"])
    if reason == 0:
        return None
    lane = int(row["block_lane"])
    name = BLOCK_REASONS.get(reason, f"reason_{reason}").upper()
    if lane not in range(3):
        return f"BLOCK={name}@Q?"
    uid = int(row[f"q{lane}_uid"])
    pc = int(row[f"q{lane}_pc"])
    pipe = PIPE_NAMES.get(candidate_pipe(row, lane), "?")
    details = []
    if int(row["raw_rs1"]) & (1 << lane):
        details.append(f"rs1=x{lane_value(row, 'candidate_rs1', lane)}")
    if int(row["raw_rs2"]) & (1 << lane):
        details.append(f"rs2=x{lane_value(row, 'candidate_rs2', lane)}")
    if name.startswith("WAW"):
        details.append(f"rd=x{lane_value(row, 'candidate_rd', lane)}")
    suffix = f"({','.join(details)})" if details else ""
    return f"BLOCK={name}@Q{lane}:{uid:x}@{pc & 0xffff:04x}/{pipe}{suffix}"


def stall_labels(row: dict[str, int | str]) -> str:
    labels: list[str] = []
    block = block_text(row)
    if block:
        labels.append(block)
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
        labels.append("IF_REQ_WAIT")
    if int(row["mem_req_valid"]) and not int(row["mem_req_ready"]):
        labels.append("LSU_REQ_WAIT")
    if int(row["lsu_order_block"]):
        labels.append("LSU_ORDER")
    if int(row["dispatch_q"]) and not int(row["issue_valid"]):
        labels.append("NOISSUE")
    if int(row.get("data_fields_present", 0)):
        if int(row["mem_req_valid"]) and int(row["mem_req_ready"]):
            tag = int(row["mem_req_tag"])
            addr = int(row["mem_req_addr"])
            if int(row["mem_write"]):
                labels.append(
                    f"MEMW[t{tag}]@{addr:x}={int(row['mem_req_wdata']):x}"
                    f"/{int(row['mem_req_wstrb']):02x}"
                )
            else:
                labels.append(f"MEMR[t{tag}]@{addr:x}")
        if int(row["mem_resp_valid"]) and int(row["mem_resp_ready"]):
            labels.append(
                f"MEMRESP[t{int(row['mem_resp_tag'])}]="
                f"{int(row['mem_resp_rdata']):x}"
            )
        write_mask = int(row["retire_gpr_write"])
        packed_rd = int(row["retire_gpr_rd"])
        packed_data = int(row["retire_gpr_data"])
        for lane in range(3):
            if write_mask & (1 << lane):
                rd = (packed_rd >> (lane * 5)) & 0x1f
                data = (packed_data >> (lane * 64)) & ((1 << 64) - 1)
                labels.append(f"WB{lane}=x{rd}:{data:x}")
    return "+".join(labels) if labels else "-"


def summary(rows: list[dict[str, int | str]]) -> str:
    cycles = len(rows)
    schema = str(rows[0]["schema"])
    stages = stages_for_schema(schema)
    retired = sum(int(row["retire_count"]) for row in rows)
    lines = [
        "SUMMARY",
        f"  schema={schema}",
        f"  cycles={cycles} retired={retired} IPC={retired / cycles:.4f}",
        "  stage  active_cycles  occupied_slots  slot_utilization",
    ]
    for name, mask_field, _ in stages:
        active = sum(bool(int(row[mask_field])) for row in rows)
        slots = sum(popcount(int(row[mask_field])) for row in rows)
        lines.append(
            f"  {name:<5} {active:5d}/{cycles:<5d} {slots:7d}/{cycles * 3:<7d} "
            f"{slots / (cycles * 3):7.2%}"
        )

    counts = Counter()
    reason_counts = Counter()
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
        counts["queued_read_port"] += bool(dispatch_q and int(row["read_port"]))
        counts["queued_barrier"] += bool(dispatch_q and int(row["barrier"]))
        counts["retire_wait"] += bool(int(row["retire_q"]) and not retire_valid)
        counts["bp_stall"] += bool(
            int(row["bp_fetch_stall"]) or int(row["bp_decode_stall"])
        )
        counts["redirect"] += bool(int(row["redirect"]))
        counts["if_request_wait"] += bool(
            int(row["fetch_req_valid"]) and not int(row["fetch_req_ready"])
        )
        if schema.endswith("v2"):
            reason_counts[int(row["block_reason"])] += 1
            counts["retire_head_incomplete"] += bool(
                int(row["retire_q"]) and
                not (int(row["queue_retire_valid"]) & 1)
            )
            counts["completed_behind_head"] += bool(
                int(row["retire_q"]) and
                not (int(row["queue_retire_valid"]) & 1) and
                int(row["completed_entries"])
            )
            counts["lsu_pipe_full"] += bool(
                int(row["block_reason"]) == 11 and
                int(row["block_lane"]) in range(3) and
                candidate_pipe(row, int(row["block_lane"])) == 2
            )
            counts["lsu_request_wait"] += bool(
                int(row["mem_req_valid"]) and not int(row["mem_req_ready"])
            )
            counts["lsu_outstanding"] += bool(int(row["lsu_sent"]))
            counts["lsu_order_block"] += bool(int(row["lsu_order_block"]))
            if int(row["window_fields_present"]):
                counts["window_live"] += bool(int(row["window_unissued"]))
                counts["window_full"] += int(row["dispatch_q"]) >= 16
                counts["window_no_eligible"] += bool(
                    int(row["window_unissued"]) and
                    not int(row["window_eligible"])
                )
                counts["window_raw_blocked"] += bool(
                    int(row["window_raw_block"])
                )
                counts["window_hard_blocked"] += bool(
                    int(row["window_hard_block"])
                )
                counts["window_mem_order_blocked"] += bool(
                    int(row["window_mem_order_block"])
                )
            if fetch_valid == 0:
                if int(row["control_flush"]) or int(row["control_redirect"]):
                    counts["frontend_control"] += 1
                elif int(row["bp_fetch_stall"]):
                    counts["frontend_bp_stall"] += 1
                elif not int(row["fetch_consume_hit"]) and (
                    int(row["fetch_pending"]) or int(row["fetch_bus_q"])
                ):
                    counts["frontend_refill_wait"] += 1
                elif not int(row["fetch_consume_hit"]):
                    counts["frontend_no_line"] += 1
                else:
                    counts["frontend_other_empty"] += 1

    if schema.endswith("v2"):
        blocked = cycles - reason_counts[0]
        lines.append(
            "  first_nonissued_candidate (exclusive; hazards take precedence):"
        )
        for reason in range(1, 14):
            count = reason_counts[reason]
            lines.append(
                f"    {BLOCK_REASONS[reason]:<20} {count:6d}  "
                f"{count / cycles:7.2%} cycles  "
                f"{(count / blocked if blocked else 0):7.2%} blocked"
            )
        lines.append("  retirement_head:")
        for name in ("retire_head_incomplete", "completed_behind_head"):
            lines.append(
                f"    {name:<24} {counts[name]:6d}  {counts[name] / cycles:7.2%}"
            )
        lines.append("  lsu:")
        for name in (
            "lsu_pipe_full", "lsu_request_wait", "lsu_outstanding",
            "lsu_order_block",
        ):
            lines.append(
                f"    {name:<24} {counts[name]:6d}  {counts[name] / cycles:7.2%}"
            )
        lines.append("  frontend_empty (exclusive):")
        for name in (
            "frontend_control", "frontend_bp_stall", "frontend_refill_wait",
            "frontend_no_line", "frontend_other_empty",
        ):
            lines.append(
                f"    {name:<24} {counts[name]:6d}  {counts[name] / cycles:7.2%}"
            )
        if int(rows[0]["window_fields_present"]):
            lines.append("  issue_window:")
            for name in (
                "window_live", "window_full", "window_no_eligible",
                "window_raw_blocked", "window_hard_blocked",
                "window_mem_order_blocked",
            ):
                lines.append(
                    f"    {name:<24} {counts[name]:6d}  "
                    f"{counts[name] / cycles:7.2%}"
                )
            for name in (
                "window_unissued", "window_operand_ready", "window_eligible",
                "window_selected", "window_issued",
            ):
                total = sum(int(row[name]) for row in rows)
                lines.append(
                    f"    avg_{name:<20} {total / cycles:7.3f}"
                )

    lines.append("  observations (overlapping, not causal attribution):")
    for name in (
        "frontend_empty", "frontend_held", "dispatch_empty",
        "queued_no_issue", "queued_raw", "queued_waw",
        "queued_read_port", "queued_barrier", "retire_wait",
        "bp_stall", "redirect", "if_request_wait",
    ):
        lines.append(f"    {name:<24} {counts[name]:6d}  {counts[name] / cycles:7.2%}")
    return "\n".join(lines)


def find_anchor(
    rows: list[dict[str, int | str]],
    pc: int | None,
    uid: int | None,
    cycle: int | None,
    block_reason: str | None,
) -> int:
    if cycle is not None:
        for index, row in enumerate(rows):
            if int(row["cycle"]) >= cycle:
                return index
        raise ValueError(f"cycle {cycle} does not appear in trace")
    if uid is not None:
        for index, row in enumerate(rows):
            for _, mask_field, prefix in stages_for_schema(str(row["schema"])):
                mask = int(row[mask_field])
                if any(
                    mask & (1 << lane) and int(row[f"{prefix}{lane}_uid"]) == uid
                    for lane in range(3)
                ):
                    return index
        raise ValueError(f"UID 0x{uid:x} does not appear in trace")
    if block_reason is not None:
        reason = next(
            key for key, value in BLOCK_REASONS.items() if value == block_reason
        )
        for index, row in enumerate(rows):
            if int(row["block_reason"]) == reason:
                return index
        raise ValueError(f"block reason {block_reason!r} does not appear in trace")
    if pc is None:
        return 0
    for index, row in enumerate(rows):
        mask = int(row["retire_valid"])
        for lane in range(3):
            if mask & (1 << lane) and int(row[f"r{lane}_pc"]) == pc:
                return index
    raise ValueError(f"retired PC 0x{pc:x} does not appear in trace")


def window(rows: list[dict[str, int | str]], start: int, count: int) -> str:
    stages = stages_for_schema(str(rows[0]["schema"]))
    stage_headers = " | ".join(f"{name:<17}" for name, _, _ in stages)
    lines = [
        "",
        "PIPELINE WINDOW",
        f"  cyc | {stage_headers} | dq/rq | stalls",
    ]
    for row in rows[start:start + count]:
        fields = [
            stage_text(row, mask_field, prefix)
            for _, mask_field, prefix in stages
        ]
        stage_columns = " | ".join(f"{field:17.17s}" for field in fields)
        lines.append(
            f"  {int(row['cycle']):5d} | {stage_columns} | "
            f"{int(row['dispatch_q'])}/{int(row['retire_q'])}   | "
            f"{stall_labels(row)}"
        )
    return "\n".join(lines)


def parse_hex(value: str) -> int:
    return int(value, 16)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--output", type=Path)
    anchors = parser.add_mutually_exclusive_group()
    anchors.add_argument("--around-pc", type=parse_hex)
    anchors.add_argument("--around-uid", type=parse_hex)
    anchors.add_argument("--start-cycle", type=int)
    anchors.add_argument("--block-reason", choices=tuple(BLOCK_REASONS.values())[1:])
    parser.add_argument("--before", type=int, default=6)
    parser.add_argument("--rows", type=int, default=28)
    args = parser.parse_args()

    rows = load(args.trace)
    anchor = find_anchor(
        rows, args.around_pc, args.around_uid, args.start_cycle,
        args.block_reason,
    )
    start = max(0, anchor - args.before)
    report = summary(rows) + "\n" + window(rows, start, args.rows) + "\n"
    if args.output:
        args.output.write_text(report, encoding="utf-8")
    else:
        print(report, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
