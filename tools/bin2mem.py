#!/usr/bin/env python3
"""Convert a flat little-endian binary to 64-bit readmemh words."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def integer(value: str) -> int:
    return int(value, 0)


def convert(source: Path, destination: Path, size: int) -> int:
    data = source.read_bytes()
    if size <= 0 or size % 8:
        raise ValueError("memory size must be a positive multiple of 8")
    if len(data) > size:
        raise ValueError(
            f"binary is {len(data)} bytes, larger than the {size}-byte memory"
        )

    image = bytearray(size)
    image[:len(data)] = data
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w", encoding="ascii") as output:
        for offset in range(0, size, 8):
            word = int.from_bytes(image[offset:offset + 8], "little")
            output.write(f"{word:016x}\n")
    return len(data)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--size", type=integer, required=True)
    args = parser.parse_args()
    try:
        loaded = convert(args.binary, args.output, args.size)
    except (OSError, ValueError) as exc:
        print(f"bin2mem.py: {exc}", file=sys.stderr)
        return 2
    print(
        f"binary {args.binary}: loaded={loaded} bytes "
        f"memory={args.size} bytes"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
