#!/usr/bin/env python3
"""Convert a little-endian ELF64 image into sparse $readmemh words.

The compliance testbenches intentionally load ELF PT_LOAD segments rather
than objcopy output.  That preserves sparse VMAs and zero-filled BSS without
silently rebasing a test image.
"""

from __future__ import annotations

import argparse
import json
import struct
from dataclasses import dataclass
from pathlib import Path


ELF_MAGIC = b"\x7fELF"
PT_LOAD = 1


@dataclass(frozen=True)
class Segment:
    address: int
    data: bytes
    memory_size: int


def integer(text: str) -> int:
    return int(text, 0)


def load_elf(path: Path) -> tuple[int, list[Segment]]:
    blob = path.read_bytes()
    if len(blob) < 64 or blob[:4] != ELF_MAGIC:
        raise ValueError(f"{path}: not an ELF file")
    if blob[4] != 2:
        raise ValueError(f"{path}: expected ELF64")
    if blob[5] != 1:
        raise ValueError(f"{path}: expected little-endian ELF")

    header = struct.unpack_from("<16sHHIQQQIHHHHHH", blob, 0)
    machine = header[2]
    entry = header[4]
    phoff = header[5]
    phentsize = header[9]
    phnum = header[10]
    if machine != 243:
        raise ValueError(f"{path}: expected EM_RISCV (243), got {machine}")
    if phentsize < 56:
        raise ValueError(f"{path}: invalid program header size {phentsize}")

    segments: list[Segment] = []
    for index in range(phnum):
        offset = phoff + index * phentsize
        if offset + 56 > len(blob):
            raise ValueError(f"{path}: truncated program header {index}")
        ph = struct.unpack_from("<IIQQQQQQ", blob, offset)
        p_type, _, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, _ = ph
        if p_type != PT_LOAD or p_memsz == 0:
            continue
        if p_filesz > p_memsz or p_offset + p_filesz > len(blob):
            raise ValueError(f"{path}: invalid PT_LOAD segment {index}")
        address = p_paddr if p_paddr else p_vaddr
        data = blob[p_offset : p_offset + p_filesz]
        segments.append(Segment(address, data, p_memsz))

    if not segments:
        raise ValueError(f"{path}: no loadable segments")
    return entry, segments


def image_words(
    segments: list[Segment], base: int, size: int, word_bytes: int
) -> dict[int, bytes]:
    if word_bytes not in (8, 32):
        raise ValueError("word size must be 8 or 32 bytes")
    limit = base + size
    words: dict[int, bytearray] = {}
    owner: dict[int, tuple[int, int]] = {}

    for segment_index, segment in enumerate(segments):
        end = segment.address + segment.memory_size
        if segment.address < base or end > limit or end < segment.address:
            raise ValueError(
                "PT_LOAD segment outside RAM aperture: "
                f"0x{segment.address:x}..0x{end:x}, "
                f"RAM=0x{base:x}..0x{limit:x}"
            )

        payload = segment.data + bytes(segment.memory_size - len(segment.data))
        for byte_offset, value in enumerate(payload):
            absolute = segment.address + byte_offset
            word_index = (absolute - base) // word_bytes
            lane = (absolute - base) % word_bytes
            previous = owner.get(absolute)
            if previous is not None and previous[1] != value:
                raise ValueError(
                    f"conflicting PT_LOAD bytes at 0x{absolute:x}: "
                    f"segments {previous[0]} and {segment_index}"
                )
            owner[absolute] = (segment_index, value)
            words.setdefault(word_index, bytearray(word_bytes))[lane] = value

    return {index: bytes(word) for index, word in words.items()}


def write_memh(path: Path, words: dict[int, bytes]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii") as stream:
        previous = -2
        for index in sorted(words):
            if index != previous + 1:
                stream.write(f"@{index:x}\n")
            stream.write(words[index][::-1].hex())
            stream.write("\n")
            previous = index


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("elf", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--base", type=integer, default=0x8000_0000)
    parser.add_argument("--size", type=integer, default=16 * 1024 * 1024)
    parser.add_argument("--word-bytes", type=int, choices=(8, 32), default=8)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()

    entry, segments = load_elf(args.elf)
    words = image_words(segments, args.base, args.size, args.word_bytes)
    write_memh(args.output, words)

    if args.manifest:
        starts = [segment.address for segment in segments]
        ends = [segment.address + segment.memory_size for segment in segments]
        manifest = {
            "format": "openrv64-elf-image-v1",
            "elf": str(args.elf.resolve()),
            "entry": f"0x{entry:016x}",
            "ram_base": f"0x{args.base:016x}",
            "ram_size": args.size,
            "word_bytes": args.word_bytes,
            "loaded_start": f"0x{min(starts):016x}",
            "loaded_end": f"0x{max(ends):016x}",
            "segments": len(segments),
        }
        args.manifest.parent.mkdir(parents=True, exist_ok=True)
        args.manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
