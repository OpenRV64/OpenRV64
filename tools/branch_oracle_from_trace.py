#!/usr/bin/env python3
"""Build a correct-path branch oracle from an OpenRV64 retirement trace.

Unlike a resolution-time dump, retirement order remains architectural when an
issue window resolves branches out of order.  The next retired PC therefore
provides the actual direction and target for each retired branch/JAL/JALR.
"""

import argparse
import csv
from pathlib import Path


CONTROL_OPCODES = {0x63, 0x6F, 0x67}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--expect-count",
        type=int,
        help="fail unless exactly this many control records are produced",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    retired: list[tuple[int, int]] = []

    with args.trace.open(newline="") as trace_file:
        rows = csv.DictReader(trace_file)
        required = {"retire_valid"}
        required.update(
            f"r{lane}_{field}"
            for lane in range(3)
            for field in ("pc", "instr")
        )
        missing = required.difference(rows.fieldnames or ())
        if missing:
            raise ValueError(
                "trace lacks required columns: " + ", ".join(sorted(missing))
            )

        for row in rows:
            retire_valid = int(row["retire_valid"], 16)
            for lane in range(3):
                if retire_valid & (1 << lane):
                    retired.append(
                        (int(row[f"r{lane}_pc"], 16),
                         int(row[f"r{lane}_instr"], 16))
                    )

    records: list[int] = []
    for index, (pc, instr) in enumerate(retired):
        if (instr & 0x7F) not in CONTROL_OPCODES:
            continue
        if index + 1 >= len(retired):
            raise ValueError(
                f"final retired instruction at 0x{pc:016x} is a control; "
                "its actual target is unavailable"
            )
        actual_target = retired[index + 1][0]
        actual_taken = actual_target != pc + 4
        records.append((int(actual_taken) << 64) | actual_target)

    if args.expect_count is not None and len(records) != args.expect_count:
        raise ValueError(
            f"oracle records={len(records)} expected={args.expect_count}"
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as output_file:
        for record in records:
            output_file.write(f"{record:017x}\n")

    print(
        f"branch oracle: trace={args.trace} retired={len(retired)} "
        f"records={len(records)} output={args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
