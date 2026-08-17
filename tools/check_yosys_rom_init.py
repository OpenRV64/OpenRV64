#!/usr/bin/env python3
"""Reject an FPGA system netlist whose boot ROM contains only the fallback."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


INIT_PARAMETER = re.compile(r"^INIT(?:P)?_[0-9A-F]{2}$")


def count_nonzero_segments(path: Path) -> tuple[int, list[str]]:
    with path.open(encoding="utf-8") as stream:
        design = json.load(stream)

    try:
        module = design["modules"]["openrv64_fpga_opensbi_system"]
        cells = module["cells"]
    except (KeyError, TypeError) as error:
        raise ValueError("OpenRV64 FPGA system module is absent") from error

    rom_cells = {
        name: cell
        for name, cell in cells.items()
        if ".u_rom.rom_q." in name and cell.get("type") == "RAMB36E1"
    }
    if not rom_cells:
        raise ValueError("no mapped RAMB36E1 boot-ROM cells found")

    count = 0
    for cell in rom_cells.values():
        parameters = cell.get("parameters", {})
        count += sum(
            1
            for name, value in parameters.items()
            if INIT_PARAMETER.fullmatch(name) and "1" in value
        )
    return count, sorted(rom_cells)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("netlist", type=Path)
    parser.add_argument("--minimum-segments", type=int, default=4)
    args = parser.parse_args()

    try:
        count, cells = count_nonzero_segments(args.netlist)
        if count < args.minimum_segments:
            raise ValueError(
                f"boot ROM has {count} nonzero BRAM INIT segments; "
                f"expected at least {args.minimum_segments}"
            )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"YOSYS ROM INIT FAIL {error}", file=sys.stderr)
        return 1

    print(
        f"YOSYS ROM INIT PASS cells={len(cells)} "
        f"nonzero_segments={count}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
