#!/usr/bin/env python3
"""Build a correct-path branch oracle from an OpenRV64 retirement trace.

Unlike a resolution-time dump, retirement order remains architectural when an
issue window resolves branches out of order.  Resident-state retirement events
carry the actual next PC; the legacy wide trace derives it from the following
retired PC.
"""

import argparse
import bz2
import csv
from pathlib import Path


CONTROL_OPCODES = {0x63, 0x6F, 0x67}
RESIDENT_TRACE_HEADER = {
    "schema", "cycle", "insn_id", "core_id", "pc", "instr", "stage",
    "slot", "lane", "state", "reason", "blocker_id", "flags",
    "detail0", "detail1",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--expect-count",
        type=int,
        help="fail unless exactly this many control records are produced",
    )
    parser.add_argument(
        "--include-pc",
        action="store_true",
        help="emit checked 129-bit PC/taken/target records",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    retired: list[tuple[int, int, int | None]] = []

    if args.trace.suffix == ".bz2":
        trace_context = bz2.open(args.trace, "rt", newline="")
    else:
        trace_context = args.trace.open(newline="")

    with trace_context as trace_file:
        rows = csv.DictReader(trace_file)
        fieldnames = set(rows.fieldnames or ())
        if RESIDENT_TRACE_HEADER.issubset(fieldnames):
            for row in rows:
                if (row["schema"] == "openrv64-pipeline-state-v1" and
                        int(row["stage"]) == 9 and
                        int(row["state"]) == 4):
                    retired.append(
                        (int(row["pc"], 16), int(row["instr"], 16),
                         int(row["detail1"], 16))
                    )
        else:
            required = {"retire_valid"}
            required.update(
                f"r{lane}_{field}"
                for lane in range(3)
                for field in ("pc", "instr")
            )
            missing = required.difference(fieldnames)
            if missing:
                raise ValueError(
                    "trace lacks required columns: " +
                    ", ".join(sorted(missing))
                )

            for row in rows:
                retire_valid = int(row["retire_valid"], 16)
                for lane in range(3):
                    if retire_valid & (1 << lane):
                        retired.append(
                            (int(row[f"r{lane}_pc"], 16),
                             int(row[f"r{lane}_instr"], 16), None)
                        )

    records: list[int] = []
    for index, (pc, instr, recorded_next_pc) in enumerate(retired):
        if (instr & 0x7F) not in CONTROL_OPCODES:
            continue
        if recorded_next_pc is not None:
            actual_target = recorded_next_pc
        elif index + 1 < len(retired):
            actual_target = retired[index + 1][0]
        else:
            raise ValueError(
                f"final retired instruction at 0x{pc:016x} is a control; "
                "its actual target is unavailable"
            )
        actual_taken = actual_target != pc + 4
        record = (int(actual_taken) << 64) | actual_target
        if args.include_pc:
            record |= pc << 65
        records.append(record)

    if args.expect_count is not None and len(records) != args.expect_count:
        raise ValueError(
            f"oracle records={len(records)} expected={args.expect_count}"
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as output_file:
        record_digits = 33 if args.include_pc else 17
        for record in records:
            output_file.write(f"{record:0{record_digits}x}\n")

    print(
        f"branch oracle: trace={args.trace} retired={len(retired)} "
        f"records={len(records)} output={args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
