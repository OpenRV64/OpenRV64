#!/usr/bin/env python3
"""Read and decode the paging_init memblock probe over USER1 JTAG."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import struct
import subprocess


FIRST_WORD = 256
WORD_COUNT = 184
MAGIC = 0x4D454D424C4B5031
STACK_BYTES = 128
MEMBLOCK_BYTES = 96
REGION_BYTES = 384
MPRV_STACK = 0x080
WALK_STACK = 0x100
MPRV_MEMBLOCK = 0x180
WALK_MEMBLOCK = 0x1E0
MPRV_REGIONS = 0x240
WALK_REGIONS = 0x3C0
OPENSBI_LINE = 0x540
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


def decode_memblock(block: bytes) -> tuple[int, int, int, int]:
    bottom_up = block[0]
    current_limit = struct.unpack_from("<Q", block, 8)[0]
    count, maximum, total_size, regions = struct.unpack_from("<4Q", block, 16)
    print(f"  bottom_up={bottom_up} current_limit=0x{current_limit:016x}")
    print(f"  memory count={count} max={maximum} total=0x{total_size:016x} regions=0x{regions:016x}")
    return count, maximum, total_size, regions


def decode_regions(data: bytes, count: int) -> None:
    for index in range(min(count, REGION_BYTES // 24)):
        base, size, flags = struct.unpack_from("<QQI", data, index * 24)
        print(
            f"  [{index:02d}] base=0x{base:016x} size=0x{size:016x} "
            f"end=0x{base + size:016x} flags=0x{flags:08x}"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--tool",
        type=Path,
        default=Path(__file__).resolve().with_name("fpga-jtag-snoop"),
    )
    parser.add_argument("--raw-log", type=Path)
    args = parser.parse_args()

    data, raw_log = read_words(args.tool)
    if args.raw_log:
        args.raw_log.write_text(raw_log)

    fields = struct.unpack_from("<9Q", data)
    names = (
        "magic", "mepc", "satp", "mstatus", "stack", "a2", "a3", "s5",
        "memory_regions",
    )
    for name, value in zip(names, fields):
        print(f"{name:16s} 0x{value:016x}")
    if fields[0] != MAGIC:
        print("probe result magic is absent; the stub did not complete")
        return 1

    mprv_stack = data[MPRV_STACK:MPRV_STACK + STACK_BYTES]
    walk_stack = data[WALK_STACK:WALK_STACK + STACK_BYTES]
    mprv_memblock = data[MPRV_MEMBLOCK:MPRV_MEMBLOCK + MEMBLOCK_BYTES]
    walk_memblock = data[WALK_MEMBLOCK:WALK_MEMBLOCK + MEMBLOCK_BYTES]
    mprv_regions = data[MPRV_REGIONS:MPRV_REGIONS + REGION_BYTES]
    walk_regions = data[WALK_REGIONS:WALK_REGIONS + REGION_BYTES]

    print(f"stack_views_equal={mprv_stack == walk_stack}")
    print(f"memblock_views_equal={mprv_memblock == walk_memblock}")
    print(f"region_views_equal={mprv_regions == walk_regions}")
    print("MPRV stack:")
    hexdump(mprv_stack, 0)
    print("software-walk stack:")
    hexdump(walk_stack, 0)
    print("MPRV memblock:")
    mprv_count, _, _, _ = decode_memblock(mprv_memblock)
    print("software-walk memblock:")
    walk_count, _, _, _ = decode_memblock(walk_memblock)
    print("MPRV memory regions:")
    decode_regions(mprv_regions, mprv_count)
    print("software-walk memory regions:")
    decode_regions(walk_regions, walk_count)
    print("OpenSBI 0x80142900 reference bytes:")
    hexdump(data[OPENSBI_LINE:OPENSBI_LINE + 128], 0x80142900)
    print("OPENRV64 FPGA DEBUG MEMBLOCK PROBE READ PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
