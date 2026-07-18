#!/usr/bin/env python3
"""Summarize a QEMU one-insn-per-TB execution trace."""

from __future__ import annotations

import argparse
import re
from collections import Counter
from pathlib import Path


TRACE_RE = re.compile(
    r"^Trace\s+\d+:\s+\S+\s+\[[^/]+/([0-9a-fA-F]+)/"
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--top", type=int, default=20)
    args = parser.parse_args()

    pcs: Counter[int] = Counter()
    ordered_pcs: list[int] = []
    with args.trace.open(encoding="utf-8", errors="replace") as source:
        for line in source:
            match = TRACE_RE.match(line)
            if match is None:
                continue
            pc = int(match.group(1), 16)
            pcs[pc] += 1
            ordered_pcs.append(pc)

    if not ordered_pcs:
        raise SystemExit("trace contains no QEMU execution records")

    # The harness validates its checksum and terminates with one final HLT
    # semihosting instruction.  It is executed by QEMU but is not analogous
    # to an architecturally retired benchmark instruction.
    before_exit = len(ordered_pcs) - 1
    lines = [
        "QEMU ONE-INSTRUCTION TRACE SUMMARY",
        f"  translation_blocks={len(ordered_pcs)}",
        f"  instructions_before_semihost_exit={before_exit}",
        f"  distinct_pcs={len(pcs)}",
        f"  entry_pc=0x{ordered_pcs[0]:016x}",
        f"  semihost_exit_pc=0x{ordered_pcs[-1]:016x}",
        "  timing=unavailable (QEMU TCG is functional, not Cortex-A53 timing)",
        "",
        "HOT DYNAMIC PCS",
    ]
    for pc, count in pcs.most_common(args.top):
        lines.append(f"  0x{pc:016x} {count:8d}")
    rendered = "\n".join(lines) + "\n"

    if args.output is None:
        print(rendered, end="")
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
