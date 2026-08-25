#!/usr/bin/env python3
"""Read and decode the M-mode property-name strcmp probe over USER1 JTAG."""

from __future__ import annotations

import os
from pathlib import Path
import re
import struct
import subprocess


FIRST_WORD = 256
WORD_COUNT = 64
MAGIC = 0x53545250524F4231
WORD_RE = re.compile(r"^\s*(\d+)\s+0x[0-9a-fA-F]+\s+0x([0-9a-fA-F]{16})\s*$")


def read_words(tool: Path) -> bytes:
    completed = subprocess.run(
        [str(tool), "dump-stub", str(FIRST_WORD), str(WORD_COUNT)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=os.environ.copy(),
    )
    words: dict[int, int] = {}
    for line in completed.stdout.splitlines():
        match = WORD_RE.match(line)
        if match:
            words[int(match.group(1))] = int(match.group(2), 16)
    missing = [index for index in range(FIRST_WORD, FIRST_WORD + WORD_COUNT)
               if index not in words]
    if missing:
        raise RuntimeError(f"missing JTAG words: {missing}")
    return b"".join(struct.pack("<Q", words[index])
                    for index in range(FIRST_WORD, FIRST_WORD + WORD_COUNT))


def shown(data: bytes) -> str:
    raw = data.split(b"\0", 1)[0]
    return raw.decode("ascii", "backslashreplace")


def main() -> int:
    tool = Path(__file__).resolve().with_name("fpga-jtag-snoop")
    data = read_words(tool)
    fields = struct.unpack_from("<11Q", data)
    names = (
        "magic", "mepc", "satp", "mstatus", "ra", "t0", "t1",
        "property", "requested_name", "a0", "a1",
    )
    for name, value in zip(names, fields):
        print(f"{name:16s} 0x{value:016x}")
    if fields[0] != MAGIC:
        raise RuntimeError("probe result magic is absent; stub did not complete")

    prop_mprv = data[0x80:0xA0]
    name_mprv = data[0xA0:0xE0]
    target_mprv = data[0xE0:0x120]
    prop_walk = data[0x120:0x140]
    name_walk = data[0x140:0x180]
    target_walk = data[0x180:0x1C0]
    print(f"property_name_ptr 0x{int.from_bytes(prop_mprv[:8], 'little'):016x}")
    print(f"mprv_property_name {shown(name_mprv)!r}")
    print(f"mprv_requested     {shown(target_mprv)!r}")
    print(f"walk_property_name {shown(name_walk)!r}")
    print(f"walk_requested     {shown(target_walk)!r}")

    if prop_mprv != prop_walk:
        raise RuntimeError("MPRV and software-walk property objects differ")
    if name_mprv != name_walk:
        raise RuntimeError("MPRV and software-walk property names differ")
    if target_mprv != target_walk:
        raise RuntimeError("MPRV and software-walk requested names differ")
    print("OPENRV64 FPGA DEBUG STRCMP PROBE READ PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
