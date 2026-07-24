#!/usr/bin/env python3
"""Annotate a live tb_opensbi stream with ELF function symbols.

Typical use:

  simulator ... 2>&1 |
    python3 tools/linux_boot_watch.py \
      --configuration bp6-gshare \
      --elf linux=/path/to/vmlinux \
      --elf opensbi=build/opensbi/artifacts/fw_jump.elf \
      --csv build/logs/bp6-functions.csv |
    tee build/logs/bp6.log

The original stream is preserved on stdout.  FUNCTION SAMPLE/SIGNPOST records
are inserted after recognized progress and exact signpost records.
"""

from __future__ import annotations

import argparse
import csv
import pathlib
import signal
import subprocess
import sys

from elf_symbols import load_symbol_tables, parse_elf_image, symbolize
from linux_boot_signposts import EXACT_RE, PROGRESS_RE


def main() -> int:
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--configuration",
        default="unknown",
        help="configuration label stored in annotations and CSV",
    )
    parser.add_argument(
        "--elf",
        action="append",
        type=parse_elf_image,
        default=[],
        help="ELF symbol source as IMAGE=PATH; repeatable",
    )
    parser.add_argument(
        "--nm",
        default="riscv64-linux-gnu-nm",
        help="nm executable used to read ELF symbols",
    )
    parser.add_argument(
        "--csv",
        type=pathlib.Path,
        help="optional normalized function-sample CSV",
    )
    parser.add_argument(
        "--annotations-only",
        action="store_true",
        help="suppress pass-through of the original simulator stream",
    )
    parser.add_argument(
        "--changes-only",
        action="store_true",
        help="emit progress annotations only when the function changes",
    )
    args = parser.parse_args()

    missing = [image.path for image in args.elf if not image.path.is_file()]
    if missing:
        for path in missing:
            print(f"error: ELF does not exist: {path}", file=sys.stderr)
        return 2
    try:
        tables = load_symbol_tables(args.elf, args.nm)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"error: could not load ELF symbols: {error}", file=sys.stderr)
        return 2

    csv_file = None
    writer = None
    if args.csv is not None:
        args.csv.parent.mkdir(parents=True, exist_ok=True)
        csv_file = args.csv.open("w", newline="")
        writer = csv.writer(csv_file)
        writer.writerow(
            (
                "configuration",
                "record",
                "signpost",
                "cycles",
                "instret",
                "pc",
                "image",
                "function",
                "function_base",
                "offset",
            )
        )
        csv_file.flush()

    previous_function: tuple[str, str] | None = None
    try:
        for line in sys.stdin:
            if not args.annotations_only:
                sys.stdout.write(line)
                sys.stdout.flush()

            records: list[tuple[str, str, int, int, int]] = []
            for match in PROGRESS_RE.finditer(line):
                records.append(
                    (
                        "SAMPLE",
                        "",
                        int(match.group("cycles")),
                        int(match.group("instret")),
                        int(match.group("pc"), 16),
                    )
                )
            for match in EXACT_RE.finditer(line):
                if match.group("pc") is None:
                    continue
                records.append(
                    (
                        "SIGNPOST",
                        match.group("name"),
                        int(match.group("cycles")),
                        int(match.group("instret")),
                        int(match.group("pc"), 16),
                    )
                )

            for record, signpost, cycles, instret, pc in records:
                symbol = symbolize(tables, pc)
                current_function = (
                    (symbol.image, symbol.function)
                    if symbol is not None
                    else ("unmapped", "unmapped")
                )
                if (
                    record == "SAMPLE"
                    and args.changes_only
                    and current_function == previous_function
                ):
                    continue
                if record == "SAMPLE":
                    previous_function = current_function

                if symbol is None:
                    image = "unmapped"
                    function = "unmapped"
                    function_base = ""
                    offset = ""
                    symbol_text = "unmapped"
                else:
                    image = symbol.image
                    function = symbol.function
                    function_base = f"0x{symbol.base:016x}"
                    offset = f"0x{symbol.offset:x}"
                    symbol_text = symbol.text()

                annotation = (
                    f"FUNCTION {record} "
                    f"configuration={args.configuration} "
                    f"cycles={cycles} instret={instret} "
                    f"pc=0x{pc:016x} symbol={symbol_text}"
                )
                if signpost:
                    annotation += f" signpost={signpost}"
                print(annotation, flush=True)

                if writer is not None:
                    writer.writerow(
                        (
                            args.configuration,
                            record.lower(),
                            signpost,
                            cycles,
                            instret,
                            f"0x{pc:016x}",
                            image,
                            function,
                            function_base,
                            offset,
                        )
                    )
                    csv_file.flush()
    except BrokenPipeError:
        return 0
    finally:
        if csv_file is not None:
            csv_file.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
