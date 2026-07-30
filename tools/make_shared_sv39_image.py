#!/usr/bin/env python3
"""Install one shared Sv39 root into a linked four-hart supervisor image."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


PHYSICAL_BASE = 0x8000_0000
VIRTUAL_BASE = 0x4000_0000
MAPPED_BYTES = 0x2_0000
ROOT_OFFSET = 0x2_0000
LEVEL1_OFFSET = 0x2_1000
LEVEL0_OFFSET = 0x2_2000
IMAGE_BYTES = LEVEL0_OFFSET + 0x1000
PTE_FLAGS_RWXAD = 0xCF
PTE_FLAGS_RWAD = 0xC7

TLBI_TARGET_PAGE = 24
TLBI_NEW_PAGE = 28
TLBI_PTE_ALIAS_PAGE = 31
TLBI_OLD_VALUE = 0x1111_2222_3333_4444
TLBI_NEW_VALUE = 0xAAAA_BBBB_CCCC_DDDD


def pte(pointer_or_page: int, flags: int) -> int:
    return ((pointer_or_page >> 12) << 10) | flags


def put_u64(image: bytearray, offset: int, value: int) -> None:
    image[offset:offset + 8] = value.to_bytes(8, "little")


def build(template: bytes, tlbi_test: bool = False) -> bytearray:
    if len(template) > IMAGE_BYTES:
        raise ValueError(
            f"template is {len(template):#x} bytes; expected at most "
            f"{IMAGE_BYTES:#x}"
        )

    image = bytearray(IMAGE_BYTES)
    image[:len(template)] = template
    image[ROOT_OFFSET:IMAGE_BYTES] = bytes(IMAGE_BYTES - ROOT_OFFSET)

    # VA 0x40000000 has VPN[2] == 1 and VPN[1] == 0.
    put_u64(
        image,
        ROOT_OFFSET + 1 * 8,
        pte(PHYSICAL_BASE + LEVEL1_OFFSET, 0x1),
    )
    put_u64(
        image,
        LEVEL1_OFFSET,
        pte(PHYSICAL_BASE + LEVEL0_OFFSET, 0x1),
    )
    for page in range(MAPPED_BYTES // 0x1000):
        put_u64(
            image,
            LEVEL0_OFFSET + page * 8,
            pte(PHYSICAL_BASE + page * 0x1000, PTE_FLAGS_RWXAD),
        )

    if tlbi_test:
        # Give supervisor software a writable alias of the level-0 table.
        # The directed workload uses it to remap TLBI_TARGET_PAGE while every
        # hart retains the old translation.
        put_u64(
            image,
            LEVEL0_OFFSET + TLBI_PTE_ALIAS_PAGE * 8,
            pte(PHYSICAL_BASE + LEVEL0_OFFSET, PTE_FLAGS_RWAD),
        )
        put_u64(
            image,
            TLBI_TARGET_PAGE * 0x1000,
            TLBI_OLD_VALUE,
        )
        put_u64(
            image,
            TLBI_NEW_PAGE * 0x1000,
            TLBI_NEW_VALUE,
        )
    return image


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("template", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--tlbi-test",
        action="store_true",
        help="install the directed remap alias and old/new data pages",
    )
    args = parser.parse_args()

    try:
        result = build(args.template.read_bytes(), tlbi_test=args.tlbi_test)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(result)
    except (OSError, ValueError) as exc:
        print(f"make_shared_sv39_image.py: {exc}", file=sys.stderr)
        return 2

    root_ppn = (PHYSICAL_BASE + ROOT_OFFSET) >> 12
    print(
        f"shared Sv39 image: {len(result):#x} bytes, "
        f"satp.ppn={root_ppn:#x}, VA={VIRTUAL_BASE:#x}, "
        f"mapped={MAPPED_BYTES:#x}, tlbi_test={int(args.tlbi_test)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
