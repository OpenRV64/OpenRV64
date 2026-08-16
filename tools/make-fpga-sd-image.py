#!/usr/bin/env python3
"""Build or verify the raw OpenRV64 FPGA microSD boot image."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
import sys
import tempfile
import zlib
from dataclasses import dataclass
from pathlib import Path


SECTOR_BYTES = 512
FIRST_PAYLOAD_LBA = 8
MAGIC = b"ORV64SD1"
VERSION = 1
HEADER_BYTES = SECTOR_BYTES
HEADER_CRC_OFFSET = HEADER_BYTES - 4
ENTRY_OFFSET = 64
ENTRY_BYTES = 32
HEADER_STRUCT = struct.Struct("<8sIIIIQ")
ENTRY_STRUCT = struct.Struct("<8sIIQII")
LINUX_MAGIC_OFFSET = 0x38
LINUX_MAGIC = b"RSC\x05"
TRAMPOLINE_WORDS = (
    0x000015B7,  # lui   a1, 0x1
    0x8FF5859B,  # addiw a1, a1, -0x701
    0x01459593,  # slli  a1, a1, 20       -> 0x8ff00000
    0x00000613,  # li    a2, 0
    0x000012B7,  # lui   t0, 0x1
    0x8012829B,  # addiw t0, t0, -0x7ff
    0x01429293,  # slli  t0, t0, 20       -> 0x80100000
    0x00028067,  # jr    t0
)


@dataclass(frozen=True)
class InputImage:
    tag: str
    path: Path
    load_address: int


@dataclass(frozen=True)
class Entry:
    tag: str
    lba: int
    sector_count: int
    load_address: int
    byte_length: int
    crc32: int


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sectors_for(byte_length: int) -> int:
    return (byte_length + SECTOR_BYTES - 1) // SECTOR_BYTES


def compile_dts(args: argparse.Namespace) -> tuple[bytes, bytes]:
    try:
        dts_source = args.dts.read_bytes()
    except OSError as exc:
        raise ValueError(f"cannot read {args.dts}: {exc}") from exc

    definitions = (
        f"OPENRV64_MEMORY_SIZE={args.memory_size:#x}",
        f"OPENRV64_HART_COUNT={args.hart_count}",
        f"OPENRV64_TIMEBASE_FREQUENCY={args.timebase_frequency}",
        f"OPENRV64_UART_CLOCK_FREQUENCY={args.uart_clock_frequency}",
    )
    with tempfile.TemporaryDirectory(prefix="openrv64-sd-image-") as directory:
        preprocessed = Path(directory) / "openrv64.dts"
        dtb = Path(directory) / "openrv64.dtb"
        cpp_command = [args.cpp, "-E", "-P", "-x", "assembler-with-cpp"]
        cpp_command.extend(f"-D{definition}" for definition in definitions)
        cpp_command.extend(["-o", str(preprocessed), str(args.dts)])
        try:
            subprocess.run(cpp_command, check=True)
            subprocess.run(
                [args.dtc, "-I", "dts", "-O", "dtb", "-o", str(dtb), str(preprocessed)],
                check=True,
            )
            return dts_source, dtb.read_bytes()
        except FileNotFoundError as exc:
            raise ValueError(f"required DTS tool is not installed: {exc.filename}") from exc
        except subprocess.CalledProcessError as exc:
            raise ValueError(f"DTS compilation failed with exit code {exc.returncode}") from exc
        except OSError as exc:
            raise ValueError(f"cannot read generated DTB: {exc}") from exc


def make_entries(inputs: list[InputImage], payloads: list[bytes]) -> list[Entry]:
    entries: list[Entry] = []
    next_lba = FIRST_PAYLOAD_LBA
    for item, data in zip(inputs, payloads, strict=True):
        sector_count = sectors_for(len(data))
        entries.append(
            Entry(
                tag=item.tag,
                lba=next_lba,
                sector_count=sector_count,
                load_address=item.load_address,
                byte_length=len(data),
                crc32=zlib.crc32(data),
            )
        )
        next_lba += sector_count
    return entries


def encode_header(entries: list[Entry], image_bytes: int) -> bytes:
    header = bytearray(HEADER_BYTES)
    HEADER_STRUCT.pack_into(
        header,
        0,
        MAGIC,
        VERSION,
        HEADER_BYTES,
        ENTRY_BYTES,
        len(entries),
        image_bytes,
    )
    for index, entry in enumerate(entries):
        encoded_tag = entry.tag.encode("ascii")
        if len(encoded_tag) > 8:
            raise ValueError(f"entry tag is longer than eight bytes: {entry.tag}")
        ENTRY_STRUCT.pack_into(
            header,
            ENTRY_OFFSET + index * ENTRY_BYTES,
            encoded_tag,
            entry.lba,
            entry.sector_count,
            entry.load_address,
            entry.byte_length,
            entry.crc32,
        )
    struct.pack_into("<I", header, HEADER_CRC_OFFSET, zlib.crc32(header[:HEADER_CRC_OFFSET]))
    return bytes(header)


def decode_header(header: bytes, actual_image_bytes: int) -> list[Entry]:
    if len(header) != HEADER_BYTES:
        raise ValueError("image is shorter than its 512-byte header")
    magic, version, header_bytes, entry_bytes, entry_count, image_bytes = (
        HEADER_STRUCT.unpack_from(header, 0)
    )
    if magic != MAGIC:
        raise ValueError(f"bad image magic: {magic!r}")
    if version != VERSION:
        raise ValueError(f"unsupported format version: {version}")
    if header_bytes != HEADER_BYTES or entry_bytes != ENTRY_BYTES:
        raise ValueError("unsupported header or entry size")
    maximum_entries = (HEADER_CRC_OFFSET - ENTRY_OFFSET) // ENTRY_BYTES
    if not 1 <= entry_count <= maximum_entries:
        raise ValueError(f"invalid entry count: {entry_count}")
    if image_bytes != actual_image_bytes:
        raise ValueError(
            f"header image length is {image_bytes}, file is {actual_image_bytes} bytes"
        )
    stored_crc, = struct.unpack_from("<I", header, HEADER_CRC_OFFSET)
    calculated_crc = zlib.crc32(header[:HEADER_CRC_OFFSET])
    if stored_crc != calculated_crc:
        raise ValueError(
            f"header CRC32 mismatch: stored={stored_crc:08x} "
            f"calculated={calculated_crc:08x}"
        )

    entries: list[Entry] = []
    for index in range(entry_count):
        raw_tag, lba, sector_count, load_address, byte_length, crc32 = (
            ENTRY_STRUCT.unpack_from(header, ENTRY_OFFSET + index * ENTRY_BYTES)
        )
        try:
            tag = raw_tag.rstrip(b"\0").decode("ascii")
        except UnicodeDecodeError as exc:
            raise ValueError(f"entry {index} has a non-ASCII tag") from exc
        if not tag or not sector_count or not byte_length:
            raise ValueError(f"entry {index} has a zero tag, sector count, or length")
        if byte_length > sector_count * SECTOR_BYTES:
            raise ValueError(f"entry {tag} is longer than its sector allocation")
        start = lba * SECTOR_BYTES
        end = start + sector_count * SECTOR_BYTES
        if lba < FIRST_PAYLOAD_LBA or end > actual_image_bytes:
            raise ValueError(f"entry {tag} lies outside the payload area")
        entries.append(Entry(tag, lba, sector_count, load_address, byte_length, crc32))

    ranges = sorted(
        (entry.lba, entry.lba + entry.sector_count, entry.tag) for entry in entries
    )
    for previous, current in zip(ranges, ranges[1:]):
        if current[0] < previous[1]:
            raise ValueError(f"entries {previous[2]} and {current[2]} overlap")
    return entries


def manifest(
    output: Path,
    image: bytes,
    entries: list[Entry],
    sources: dict[str, tuple[str, bytes]] | None = None,
) -> dict[str, object]:
    records: list[dict[str, object]] = []
    for entry in entries:
        start = entry.lba * SECTOR_BYTES
        data = image[start:start + entry.byte_length]
        record: dict[str, object] = {
            "tag": entry.tag,
            "start_lba": entry.lba,
            "sector_count": entry.sector_count,
            "load_address": f"0x{entry.load_address:016x}",
            "byte_length": entry.byte_length,
            "crc32": f"{entry.crc32:08x}",
            "sha256": sha256(data),
        }
        if sources is not None:
            source_name, source_data = sources[entry.tag]
            record["source"] = source_name
            record["source_sha256"] = sha256(source_data)
        records.append(record)
    return {
        "format": "openrv64-fpga-sd-image-v1",
        "image": str(output),
        "image_bytes": len(image),
        "image_sectors": len(image) // SECTOR_BYTES,
        "sha256": sha256(image),
        "entries": records,
    }


def verify_bytes(path: Path, image: bytes) -> tuple[list[Entry], dict[str, object]]:
    if len(image) % SECTOR_BYTES:
        raise ValueError("image length is not a multiple of 512 bytes")
    entries = decode_header(image[:HEADER_BYTES], len(image))
    for entry in entries:
        start = entry.lba * SECTOR_BYTES
        data = image[start:start + entry.byte_length]
        calculated_crc = zlib.crc32(data)
        if calculated_crc != entry.crc32:
            raise ValueError(
                f"{entry.tag} CRC32 mismatch: stored={entry.crc32:08x} "
                f"calculated={calculated_crc:08x}"
            )
        padding_end = start + entry.sector_count * SECTOR_BYTES
        if any(image[start + entry.byte_length:padding_end]):
            raise ValueError(f"{entry.tag} sector padding is not zero")
    return entries, manifest(path, image, entries)


def build(args: argparse.Namespace) -> int:
    dts_source, dtb = compile_dts(args)
    trampoline = struct.pack("<8I", *TRAMPOLINE_WORDS)
    inputs = [
        InputImage("TRAMP", Path("<generated>"), 0x80000000),
        InputImage("OPENSBI", args.opensbi, 0x80100000),
        InputImage("LINUX", args.linux, 0x80200000),
        InputImage("FDT", args.dts, 0x8FF00000),
    ]
    try:
        opensbi = args.opensbi.read_bytes()
        linux = args.linux.read_bytes()
    except OSError as exc:
        raise ValueError(f"cannot read boot input: {exc}") from exc
    payloads = [trampoline, opensbi, linux, dtb]
    if not opensbi:
        raise ValueError(f"OpenSBI input is empty: {args.opensbi}")
    if not linux:
        raise ValueError(f"Linux input is empty: {args.linux}")
    if linux[LINUX_MAGIC_OFFSET:LINUX_MAGIC_OFFSET + len(LINUX_MAGIC)] != LINUX_MAGIC:
        raise ValueError(
            f"Linux input lacks RISC-V Image magic at offset "
            f"{LINUX_MAGIC_OFFSET:#x}: {args.linux}"
        )
    entries = make_entries(inputs, payloads)
    image_bytes = (entries[-1].lba + entries[-1].sector_count) * SECTOR_BYTES
    image = bytearray(image_bytes)
    image[:HEADER_BYTES] = encode_header(entries, image_bytes)
    for entry, data in zip(entries, payloads, strict=True):
        start = entry.lba * SECTOR_BYTES
        image[start:start + len(data)] = data

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    verified_entries, _ = verify_bytes(args.output, bytes(image))
    source_map: dict[str, tuple[str, bytes]] = {
        "TRAMP": ("generated:fixed-openrv64-fpga-trampoline", trampoline),
        "OPENSBI": (str(args.opensbi), opensbi),
        "LINUX": (str(args.linux), linux),
        "FDT": (str(args.dts), dts_source),
    }
    record = manifest(args.output, bytes(image), verified_entries, source_map)
    manifest_path = args.manifest or args.output.with_suffix(args.output.suffix + ".json")
    manifest_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(record, indent=2))
    print(f"manifest: {manifest_path}")
    return 0


def verify(args: argparse.Namespace) -> int:
    image = args.image.read_bytes()
    _, record = verify_bytes(args.image, image)
    print(json.dumps(record, indent=2))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dts", type=Path, nargs="?", help="DTS source")
    parser.add_argument("opensbi", type=Path, nargs="?", help="OpenSBI fw_jump.bin")
    parser.add_argument("linux", type=Path, nargs="?", help="raw RISC-V Linux Image")
    parser.add_argument("output", type=Path, nargs="?", help="raw output card image")
    parser.add_argument("--verify", dest="image", type=Path, help="verify an existing image")
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--memory-size", type=lambda value: int(value, 0), default=0x10000000)
    parser.add_argument("--hart-count", type=int, default=1)
    parser.add_argument("--timebase-frequency", type=int, default=9_216_000)
    parser.add_argument("--uart-clock-frequency", type=int, default=9_216_000)
    parser.add_argument("--cpp", default="cpp")
    parser.add_argument("--dtc", default="dtc")

    args = parser.parse_args()
    build_arguments = (args.dts, args.opensbi, args.linux, args.output)
    if args.image is not None:
        if any(argument is not None for argument in build_arguments):
            parser.error("--verify cannot be combined with build inputs")
        args.action = verify
    else:
        if any(argument is None for argument in build_arguments):
            parser.error("DTS, OpenSBI, Linux, and output paths are required")
        if args.memory_size <= 0 or args.hart_count not in (1, 2, 4):
            parser.error("memory-size must be positive and hart-count must be 1, 2, or 4")
        if args.timebase_frequency <= 0 or args.uart_clock_frequency <= 0:
            parser.error("clock frequencies must be positive")
        args.action = build
    try:
        return args.action(args)
    except (OSError, ValueError) as exc:
        print(f"make-fpga-sd-image.py: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
