#!/usr/bin/env python3
"""Load a raw RISC-V Linux Image through the OpenRV64 FPGA UART stage."""

from __future__ import annotations

import argparse
import os
import select
import struct
import sys
import termios
import time
import tty
import zlib
from pathlib import Path


MAGIC = b"ORV64LNX"
READY = b"OPENRV64 LINUX LOAD READY\r\n"
START = b"OPENRV64 LINUX LOAD START\r\n"
PASS = b"OPENRV64 LINUX LOAD PASS\r\n"
FAIL = b"OPENRV64 LINUX LOAD CRC FAIL\r\n"
DDR_START = b"OPENRV64 DDR LOAD START\r\n"
DDR_PASS = b"OPENRV64 DDR LOAD PASS\r\n"
DDR_FAIL = b"OPENRV64 DDR LOAD CRC FAIL\r\n"
PROMPT = b"openrv64# "
MAX_IMAGE_BYTES = 0x8FF00000 - 0x80200000
BLOCK_BYTES = 1024


def configure_serial(fd: int) -> None:
    tty.setraw(fd, termios.TCSANOW)
    attrs = termios.tcgetattr(fd)
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    attrs[2] = (attrs[2] & ~(termios.CSIZE | termios.PARENB | termios.CSTOPB)) | termios.CS8 | termios.CLOCAL | termios.CREAD
    attrs[0] &= ~(termios.IXON | termios.IXOFF | termios.IXANY)
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)


def read_until(fd: int, markers: tuple[bytes, ...], timeout: float) -> bytes:
    deadline = time.monotonic() + timeout
    received = bytearray()
    while time.monotonic() < deadline:
        readable, _, _ = select.select([fd], [], [], min(0.25, deadline - time.monotonic()))
        if not readable:
            continue
        block = os.read(fd, 4096)
        if not block:
            continue
        received.extend(block)
        sys.stdout.buffer.write(block)
        sys.stdout.buffer.flush()
        if any(marker in received for marker in markers):
            return bytes(received)
        if len(received) > 65536:
            del received[:-32768]
    raise TimeoutError(f"timed out waiting for {markers!r}")


def write_all(
    fd: int,
    data: memoryview,
    *,
    stall_timeout: float = 120.0,
    report_progress: bool = False,
) -> None:
    offset = 0
    next_report = 256 * 1024
    started = time.monotonic()
    while offset < len(data):
        _, writable, _ = select.select([], [fd], [], stall_timeout)
        if not writable:
            raise TimeoutError(
                f"UART stopped accepting output after {offset}/{len(data)} bytes"
            )
        offset += os.write(fd, data[offset : offset + 4096])
        if report_progress and offset >= next_report:
            elapsed = time.monotonic() - started
            print(
                f"queued {offset}/{len(data)} bytes in {elapsed:.1f}s",
                flush=True,
            )
            next_report += 256 * 1024


def write_paced(fd: int, data: memoryview, burst_bytes: int, pause: float) -> None:
    """Preserve idle intervals through the SSH/socat PTY bridge."""
    for offset in range(0, len(data), burst_bytes):
        write_all(fd, data[offset : offset + burst_bytes])
        if offset + burst_bytes < len(data):
            time.sleep(pause)


def wait_for_ack(fd: int, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        readable, _, _ = select.select([fd], [], [], min(0.25, deadline - time.monotonic()))
        if not readable:
            continue
        byte = os.read(fd, 1)
        if byte == b"+":
            return
        if byte:
            sys.stdout.buffer.write(byte)
            sys.stdout.buffer.flush()
    raise TimeoutError("timed out waiting for a loader block acknowledgement")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path, help="raw RISC-V Linux Image")
    parser.add_argument("--device", default="/tmp/ttyACM0")
    parser.add_argument("--ready-timeout", type=float, default=120.0)
    parser.add_argument("--boot-timeout", type=float, default=7200.0)
    parser.add_argument(
        "--hardware-preload", action="store_true",
        help="stream directly into the pre-boot UART-to-MIG loader",
    )
    parser.add_argument(
        "--header-retry", type=float, default=2.0,
        help="seconds to wait for START before retransmitting the header",
    )
    parser.add_argument(
        "--burst-bytes", type=int, default=4,
        help="bytes per UART burst before inserting an idle interval",
    )
    parser.add_argument(
        "--burst-pause", type=float, default=0.001,
        help="idle seconds between bursts (needed by the SSH/socat bridge)",
    )
    args = parser.parse_args()

    if args.burst_bytes <= 0 or args.burst_pause < 0:
        parser.error("burst-bytes must be positive and burst-pause nonnegative")

    image = args.image.read_bytes()
    if not image or len(image) > MAX_IMAGE_BYTES:
        parser.error(f"image size must be 1..{MAX_IMAGE_BYTES} bytes")
    if image[0x38:0x3C] != b"RSC\x05":
        parser.error("input lacks the RISC-V Linux Image magic at offset 0x38")

    checksum = zlib.crc32(image)
    header = MAGIC + struct.pack("<II", len(image), checksum)
    print(
        f"loading {len(image)} bytes, crc32={checksum:08x}, "
        f"minimum wire time={len(image) * 10 / 115200:.1f}s",
        flush=True,
    )

    fd = os.open(args.device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        configure_serial(fd)
        start_marker = DDR_START if args.hardware_preload else START
        pass_marker = DDR_PASS if args.hardware_preload else PASS
        fail_marker = DDR_FAIL if args.hardware_preload else FAIL
        deadline = time.monotonic() + args.ready_timeout
        while True:
            # Pace the header byte by byte.  A rejected header is cheap to
            # retry, and this prevents an SSH/socat write from becoming one
            # gapless physical UART burst.
            write_paced(fd, memoryview(header), 1, args.burst_pause)
            try:
                read_until(
                    fd, (start_marker,),
                    min(args.header_retry, deadline - time.monotonic()),
                )
                break
            except TimeoutError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("loader never accepted the transfer header")

        started = time.monotonic()
        if args.hardware_preload:
            write_all(fd, memoryview(image), report_progress=True)
        else:
            for offset in range(0, len(image), BLOCK_BYTES):
                write_paced(
                    fd,
                    memoryview(image)[offset : offset + BLOCK_BYTES],
                    args.burst_bytes,
                    args.burst_pause,
                )
                wait_for_ack(fd)
                if offset == 0:
                    print(
                        "\nfirst 1 KiB DDR block acknowledged; continuing upload",
                        flush=True,
                    )
        termios.tcdrain(fd)
        elapsed = time.monotonic() - started
        minimum_wire_time = len(image) * 10 / 115200
        earliest_remaining = max(0.0, minimum_wire_time - elapsed)
        print(
            f"\nupload queued through local PTY in {elapsed:.1f}s; "
            f"physical UART needs at least {earliest_remaining:.1f}s more; "
            "awaiting checksum and boot",
            flush=True,
        )
        result = read_until(fd, (pass_marker, fail_marker), args.boot_timeout)
        if fail_marker in result:
            return 1
        print("\nloader verified image; awaiting Linux shell prompt", flush=True)
        read_until(fd, (PROMPT,), args.boot_timeout)
        print("\nobserved Linux shell prompt", flush=True)
        return 0
    finally:
        os.close(fd)


if __name__ == "__main__":
    raise SystemExit(main())
