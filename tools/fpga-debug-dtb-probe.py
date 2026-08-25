#!/usr/bin/env python3
"""Read and decode the M-mode CPU-node probe result over USER1 JTAG."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import struct
import subprocess
import sys


FIRST_WORD = 256
WORD_COUNT = 284
MAGIC = 0x44544250524F4231
PROPERTY_RECORD_BASE = 0x240
PROPERTY_RECORD_SIZE = 104
PROPERTY_RECORDS = 12
WALK_PROPERTY_BASE = 0x720
WALK_STACK_BASE = 0x760
WALK_NODE_BASE = 0x7E0
WORD_RE = re.compile(r"^\s*(\d+)\s+0x[0-9a-fA-F]+\s+0x([0-9a-fA-F]{16})\s*$")


def hexdump(data: bytes, base: int) -> None:
    for offset in range(0, len(data), 16):
        chunk = data[offset : offset + 16]
        hex_text = " ".join(f"{byte:02x}" for byte in chunk)
        ascii_text = "".join(chr(byte) if 32 <= byte < 127 else "." for byte in chunk)
        print(f"  {base + offset:04x}: {hex_text:<47}  {ascii_text}")


def read_words(tool: Path) -> tuple[bytes, str]:
    command = [str(tool), "dump-stub", str(FIRST_WORD), str(WORD_COUNT)]
    completed = subprocess.run(
        command,
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
    data = b"".join(struct.pack("<Q", words[index])
                    for index in range(FIRST_WORD, FIRST_WORD + WORD_COUNT))
    return data, completed.stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--tool",
        type=Path,
        default=Path(__file__).resolve().with_name("fpga-jtag-snoop"),
        help="path to the USER1 command wrapper",
    )
    parser.add_argument("--raw-log", type=Path,
                        help="also save the unparsed dump-stub output")
    args = parser.parse_args()

    data, raw_log = read_words(args.tool)
    if args.raw_log:
        args.raw_log.write_text(raw_log)

    fields = struct.unpack_from("<12Q", data)
    names = (
        "magic", "mepc", "satp", "property_value", "stack",
        "address_cells", "cpu_index", "device_node", "trapped_a1",
        "trapped_ra", "mstatus", "property_records",
    )
    for name, value in zip(names, fields):
        print(f"{name:16s} 0x{value:016x}")
    if fields[0] != MAGIC:
        print("probe result magic is absent; the stub did not complete", file=sys.stderr)
        return 1

    property_data = data[0x80:0xC0]
    stack_data = data[0xC0:0x140]
    node_data = data[0x140:0x240]
    walk_property_data = data[WALK_PROPERTY_BASE:WALK_STACK_BASE]
    walk_stack_data = data[WALK_STACK_BASE:WALK_NODE_BASE]
    walk_node_data = data[WALK_NODE_BASE:WALK_NODE_BASE + 0x100]
    print(f"property_u32_le  0x{int.from_bytes(property_data[:4], 'little'):08x}")
    print(f"property_be32    0x{int.from_bytes(property_data[:4], 'big'):08x}")
    print(f"property_length  {int.from_bytes(stack_data[12:16], 'little')}")
    print("property bytes:")
    hexdump(property_data, 0)
    print("of_get_cpu_hwid stack:")
    hexdump(stack_data, 0)
    print("device_node bytes:")
    hexdump(node_data, 0)
    print(f"walk_property_be32 0x{int.from_bytes(walk_property_data[:4], 'big'):08x}")
    print(f"walk_property_length {int.from_bytes(walk_stack_data[12:16], 'little')}")
    print("software-walk property bytes:")
    hexdump(walk_property_data, 0)
    print("software-walk of_get_cpu_hwid stack:")
    hexdump(walk_stack_data, 0)
    print("software-walk device_node bytes:")
    hexdump(walk_node_data, 0)

    record_count = min(fields[11], PROPERTY_RECORDS)
    print("device_node property chain:")
    for index in range(record_count):
        offset = PROPERTY_RECORD_BASE + index * PROPERTY_RECORD_SIZE
        prop_ptr, name_ptr = struct.unpack_from("<QQ", data, offset)
        length = struct.unpack_from("<I", data, offset + 16)[0]
        value_ptr, next_ptr = struct.unpack_from("<QQ", data, offset + 24)
        name_bytes = data[offset + 40 : offset + 72]
        value_bytes = data[offset + 72 : offset + 104]
        name = name_bytes.split(b"\0", 1)[0].decode("ascii", "backslashreplace")
        shown_value = value_bytes[:min(length, len(value_bytes))]
        print(
            f"  [{index:02d}] property=0x{prop_ptr:016x} "
            f"name_ptr=0x{name_ptr:016x} name={name!r} length={length} "
            f"value_ptr=0x{value_ptr:016x} next=0x{next_ptr:016x}"
        )
        hexdump(shown_value, 0)
    print("OPENRV64 FPGA DEBUG DTB PROBE READ PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
