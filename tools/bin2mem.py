#!/usr/bin/env python3
"""Convert a flat little-endian binary to fixed-width readmemh words."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def integer(value: str) -> int:
    return int(value, 0)


def convert(
    source: Path, destination: Path, size: int, word_bytes: int = 8
) -> int:
    data = source.read_bytes()
    if word_bytes <= 0 or word_bytes & (word_bytes - 1):
        raise ValueError("word size must be a positive power of two")
    if size <= 0 or size % word_bytes:
        raise ValueError(
            "memory size must be a positive multiple of the word size"
        )
    if len(data) > size:
        raise ValueError(
            f"binary is {len(data)} bytes, larger than the {size}-byte memory"
        )

    image = bytearray(size)
    image[:len(data)] = data
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w", encoding="ascii") as output:
        for offset in range(0, size, word_bytes):
            word = int.from_bytes(
                image[offset:offset + word_bytes], "little"
            )
            output.write(f"{word:0{word_bytes * 2}x}\n")
    return len(data)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--size", type=integer, required=True)
    parser.add_argument("--word-bytes", type=integer, default=8)
    args = parser.parse_args()
    try:
        loaded = convert(
            args.binary, args.output, args.size, args.word_bytes
        )
    except (OSError, ValueError) as exc:
        print(f"bin2mem.py: {exc}", file=sys.stderr)
        return 2
    print(
        f"binary {args.binary}: loaded={loaded} bytes "
        f"memory={args.size} bytes word={args.word_bytes} bytes"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
