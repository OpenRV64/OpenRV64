#!/usr/bin/env python3
"""Validate and summarize the OpenRV64 cycle-complete frontend trace."""

from __future__ import annotations

import argparse
import bz2
import csv
import sys
from collections import Counter
from pathlib import Path


SCHEMA = "openrv64-frontend-cycle-v1"
RAW_HEADER = tuple(
    "schema cycle stall_reason progress stream_pc next_pc control_pc "
    "successor_pc tage_lookup_pc bp_target backend_target "
    "backend_redirect_id flags lane_state generation ftq_count "
    "btb_queue_count tage_queue_count dispatch_occupancy rob_occupancy "
    "req_addr resp_addr".split()
)

FLAG_FIELDS = tuple(
    "prediction_valid prediction_taken prediction_refined prediction_accept "
    "splice_valid presentation_ready current_pending pending_any req_valid "
    "req_ready resp_valid resp_ready btb_lookup btb_response btb_hit btb_root "
    "btb_chain btb_queue_full btb_queue_enqueue btb_queue_dequeue "
    "btb_transfer btb_reject btb_train tage_candidate tage_lookup_valid "
    "tage_lookup_accept tage_response tage_taken tage_busy_skip "
    "refinement_accept refinement_changed refinement_late tage_context_hit "
    "tage_context_claim tage_context_miss bp_fetch_stall bp_decode_stall "
    "bp_capacity_stall bp_unresolved_target_stall bp_preliminary_redirect "
    "bp_tage_resteer bp_deferred_redirect bp_predict_redirect "
    "backend_redirect backend_memory_replay target_mispredict control_flush "
    "control_restart exception_redirect translation_barrier halted wfi "
    "frontend_enable backend_enable tage_decode_read tage_early_read "
    "tage_dual_read tage_early_context_write tage_read_coalesced "
    "tage_early_read_blocked".split()
)

LANE_FIELDS = {
    "decode_valid": (0, 3),
    "decode_ready": (3, 3),
    "decode_fire": (6, 3),
    "control_select": (9, 3),
    "prefix_allow": (12, 3),
    "live_lane_allow": (15, 3),
    "backend_ready": (18, 3),
    "consume_halfwords": (21, 4),
    "splice_halfword": (25, 4),
}

REASONS = {
    0: "PROGRESS",
    1: "HALT_OR_WFI",
    2: "CONTROL_FLUSH",
    3: "ARCH_RESTART",
    4: "BACKEND_REDIRECT",
    5: "TARGET_REDIRECT",
    6: "BP_PRELIM_REDIRECT",
    7: "BP_TAGE_RESTEER",
    8: "BP_DEFERRED_REDIRECT",
    9: "BP_OTHER_REDIRECT",
    10: "TRANSLATION_BARRIER",
    11: "BP_UNRESOLVED_TARGET",
    12: "BP_CAPACITY",
    13: "BP_LOOKUP",
    14: "BACKEND_BACKPRESSURE",
    15: "CONTROL_QUALIFICATION",
    16: "CURRENT_BLOCK_PENDING",
    17: "REFILL_PENDING",
    18: "FTQ_EMPTY",
    19: "BTB_QUEUE_FULL",
    20: "REQUEST_BLOCKED",
    21: "NO_PRESENTATION",
    22: "DECODE_EMPTY",
    255: "UNKNOWN",
}

HEX_FIELDS = {
    "stream_pc", "next_pc", "control_pc", "successor_pc", "tage_lookup_pc",
    "bp_target", "backend_target", "backend_redirect_id", "flags",
    "lane_state", "req_addr", "resp_addr",
}

BOOL_FIELDS = {"progress", *FLAG_FIELDS}

EVENT_FIELDS = (
    "btb_root", "btb_chain", "btb_queue_enqueue", "btb_queue_dequeue",
    "btb_queue_full", "btb_transfer", "btb_reject", "btb_train",
    "tage_candidate", "tage_lookup_accept", "tage_response",
    "tage_busy_skip", "tage_decode_read", "tage_early_read",
    "tage_dual_read", "tage_early_context_write", "tage_read_coalesced",
    "tage_early_read_blocked", "refinement_accept", "refinement_changed",
    "refinement_late", "bp_preliminary_redirect", "bp_tage_resteer",
    "bp_deferred_redirect", "bp_predict_redirect", "backend_redirect",
    "backend_memory_replay", "target_mispredict", "control_flush",
    "control_restart", "exception_redirect",
)

OCCUPANCY_FIELDS = (
    "ftq_count", "btb_queue_count", "tage_queue_count",
    "dispatch_occupancy", "rob_occupancy",
)


def open_trace(path: Path):
    """Open plain CSV or bzip2 CSV without loading it into memory."""
    with path.open("rb") as probe:
        compressed = probe.read(3) == b"BZh"
    if compressed or path.suffix.lower() == ".bz2":
        return bz2.open(path, "rt", newline="", encoding="utf-8")
    return path.open("r", newline="", encoding="utf-8")


def parse_value(field: str, text: str, line: int) -> int:
    try:
        return int(text, 16 if field in HEX_FIELDS else 10)
    except ValueError as exc:
        raise ValueError(
            f"line {line}: invalid {field} value {text!r}"
        ) from exc


def redirect_kind(row: dict[str, int]) -> str | None:
    if row["target_mispredict"]:
        return "TARGET_MISPREDICT"
    if row["backend_redirect"]:
        return "MEMORY_REPLAY" if row["backend_memory_replay"] else "EXEC"
    if row["bp_tage_resteer"]:
        return "TAGE_RESTEER"
    if row["bp_preliminary_redirect"]:
        return "PRELIMINARY"
    if row["bp_deferred_redirect"]:
        return "DEFERRED"
    if row["bp_predict_redirect"]:
        return "BP_OTHER"
    if row["control_restart"] or row["exception_redirect"]:
        return "ARCH_RESTART"
    return None


def row_selected(row: dict[str, int], args: argparse.Namespace) -> bool:
    if args.start_cycle is not None and row["cycle"] < args.start_cycle:
        return False
    if (args.start_cycle is not None and args.cycles is not None and
            row["cycle"] >= args.start_cycle + args.cycles):
        return False
    if args.stall_reason is not None and row["stall_reason"] != args.stall_reason:
        return False
    if args.events_only and not any(row[name] for name in EVENT_FIELDS):
        return False
    return (args.start_cycle is not None or args.stall_reason is not None or
            args.events_only)


def validate_and_collect(path: Path, args: argparse.Namespace) -> list[str]:
    reason_counts: Counter[int] = Counter()
    event_counts: Counter[str] = Counter()
    decode_width: Counter[int] = Counter()
    fire_width: Counter[int] = Counter()
    occupancy_sum: Counter[str] = Counter()
    occupancy_max: Counter[str] = Counter()
    redirect_empty: Counter[str] = Counter()
    redirect_episodes: Counter[str] = Counter()
    redirect_max: Counter[str] = Counter()
    selected: list[dict[str, int]] = []
    first_cycle: int | None = None
    last_cycle: int | None = None
    rows = 0
    progress_cycles = 0
    redirect_active: str | None = None
    redirect_empty_current = 0

    with open_trace(path) as source:
        reader = csv.DictReader(source)
        if reader.fieldnames is None:
            raise ValueError("trace has no CSV header")
        if tuple(reader.fieldnames) != RAW_HEADER:
            raise ValueError(
                "trace header does not match frontend-cycle ABI: "
                f"expected {len(RAW_HEADER)} fields, "
                f"got {len(reader.fieldnames)}"
            )
        for line, raw in enumerate(reader, start=2):
            if raw["schema"] != SCHEMA:
                raise ValueError(
                    f"line {line}: unsupported schema {raw['schema']!r}"
                )
            row = {
                field: parse_value(field, raw[field], line)
                for field in RAW_HEADER if field != "schema"
            }
            flags = row["flags"]
            for bit, field in enumerate(FLAG_FIELDS):
                row[field] = (flags >> bit) & 1
            lane_state = row["lane_state"]
            for field, (lsb, width) in LANE_FIELDS.items():
                row[field] = (lane_state >> lsb) & ((1 << width) - 1)
            if row["cycle"] > 0xFFFFFFFF:
                raise ValueError(f"line {line}: cycle exceeds 32 bits")
            if row["stall_reason"] not in REASONS:
                raise ValueError(
                    f"line {line}: unknown stall reason {row['stall_reason']}"
                )
            for field in BOOL_FIELDS:
                if row[field] not in (0, 1):
                    raise ValueError(
                        f"line {line}: {field} is not boolean: {row[field]}"
                    )
            if last_cycle is not None and row["cycle"] != last_cycle + 1:
                raise ValueError(
                    f"line {line}: expected cycle {last_cycle + 1}, "
                    f"got {row['cycle']}"
                )
            if bool(row["progress"]) != (row["stall_reason"] == 0):
                raise ValueError(
                    f"line {line}: progress disagrees with stall_reason"
                )

            rows += 1
            first_cycle = row["cycle"] if first_cycle is None else first_cycle
            last_cycle = row["cycle"]
            reason_counts[row["stall_reason"]] += 1
            progress_cycles += row["progress"]
            decode_width[row["decode_valid"].bit_count()] += 1
            fire_width[row["decode_fire"].bit_count()] += 1
            for field in OCCUPANCY_FIELDS:
                occupancy_sum[field] += row[field]
                occupancy_max[field] = max(occupancy_max[field], row[field])
            for field in EVENT_FIELDS:
                event_counts[field] += row[field]

            kind = redirect_kind(row)
            if kind is not None:
                if redirect_active is not None:
                    redirect_episodes[redirect_active] += 1
                    redirect_max[redirect_active] = max(
                        redirect_max[redirect_active], redirect_empty_current
                    )
                redirect_active = kind
                redirect_empty_current = 0
            elif redirect_active is not None:
                if row["decode_fire"]:
                    redirect_episodes[redirect_active] += 1
                    redirect_max[redirect_active] = max(
                        redirect_max[redirect_active], redirect_empty_current
                    )
                    redirect_active = None
                    redirect_empty_current = 0
                else:
                    redirect_empty[redirect_active] += 1
                    redirect_empty_current += 1

            if row_selected(row, args) and len(selected) < args.rows:
                selected.append(row)

    if rows == 0:
        raise ValueError("trace contains no cycle rows")
    if redirect_active is not None:
        redirect_episodes[redirect_active] += 1
        redirect_max[redirect_active] = max(
            redirect_max[redirect_active], redirect_empty_current
        )

    report = [
        f"trace: {path}",
        f"schema: {SCHEMA}",
        f"cycles: {first_cycle}..{last_cycle} ({rows} contiguous)",
        f"progress cycles: {progress_cycles}",
        f"no-progress cycles: {rows - progress_cycles}",
        "",
        "primary cycle attribution:",
    ]
    report.extend(
        f"  {REASONS[code]:28s} {count}"
        for code, count in reason_counts.most_common()
    )
    report.extend(("", "presentation width (valid decoded instructions):"))
    report.extend(
        f"  {width} wide {decode_width[width]}"
        for width in sorted(decode_width)
    )
    report.extend(("", "accepted width (frontend decode fire):"))
    report.extend(
        f"  {width} wide {fire_width[width]}"
        for width in sorted(fire_width)
    )
    report.extend(("", "state occupancy:"))
    report.extend(
        f"  {field:24s} avg={occupancy_sum[field] / rows:.3f} "
        f"max={occupancy_max[field]}"
        for field in OCCUPANCY_FIELDS
    )
    report.extend(("", "events:"))
    report.extend(
        f"  {field:28s} {event_counts[field]}"
        for field in EVENT_FIELDS if event_counts[field]
    )
    report.extend(("", "post-redirect empty cycles:"))
    if redirect_episodes:
        report.extend(
            f"  {kind:20s} events={redirect_episodes[kind]} "
            f"empty={redirect_empty[kind]} max={redirect_max[kind]}"
            for kind in sorted(redirect_episodes)
        )
    else:
        report.append("  none")

    if selected:
        report.extend(("", "selected cycles:"))
        for row in selected:
            events = "|".join(
                name for name in EVENT_FIELDS if row[name]
            ) or "-"
            report.append(
                f"  c={row['cycle']:10d} pc={row['stream_pc']:016x} "
                f"reason={REASONS[row['stall_reason']]} "
                f"decode={row['decode_valid']:x}/{row['decode_ready']:x}/"
                f"{row['decode_fire']:x} presentation="
                f"{row['presentation_ready']} "
                f"ftq={row['ftq_count']} btbq={row['btb_queue_count']} "
                f"tageq={row['tage_queue_count']} events={events}"
            )
    report.extend(("", f"FRONTEND_TRACE_OK rows={rows}"))
    return report


def parse_reason(text: str) -> int:
    try:
        value = int(text, 0)
    except ValueError:
        upper = text.upper()
        for code, name in REASONS.items():
            if name == upper:
                return code
        raise argparse.ArgumentTypeError(f"unknown stall reason {text!r}")
    if value not in REASONS:
        raise argparse.ArgumentTypeError(f"unknown stall reason {value}")
    return value


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate and summarize an OpenRV64 frontend trace"
    )
    parser.add_argument("trace", type=Path)
    parser.add_argument("--start-cycle", type=int)
    parser.add_argument("--cycles", type=int)
    parser.add_argument("--stall-reason", type=parse_reason)
    parser.add_argument("--events-only", action="store_true")
    parser.add_argument("--rows", type=int, default=200)
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
        report = validate_and_collect(args.trace, args)
    except (OSError, ValueError) as exc:
        print(f"frontend_trace.py: error: {exc}", file=sys.stderr)
        return 2
    text = "\n".join(report) + "\n"
    if args.output is not None:
        args.output.write_text(text, encoding="utf-8")
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
