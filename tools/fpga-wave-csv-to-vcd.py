#!/usr/bin/env python3
"""Convert an OpenRV64 FPGA waveform CSV dump to a GTKWave-readable VCD."""

import argparse
import csv
import sys
from pathlib import Path


SIGNALS = (
    ("pc", 32, "a"),
    ("instr", 32, "b"),
    ("fetch_valid", 1, "c"),
    ("fetch_meta", 64, "d"),
    ("fetch_data", 64, "e"),
    ("mem_addr", 32, "f"),
    ("mem_valid", 1, "g"),
    ("mem_ready", 1, "h"),
    ("mem_write", 1, "i"),
    ("trace_valid", 5, "j"),
    ("trace_stall", 5, "k"),
    ("trace_flush", 5, "l"),
    ("trace_advance", 5, "m"),
    ("trace_events", 8, "n"),
)


def parse_value(text: str) -> int:
    return int(text, 0)


def emit_value(output, value: int, width: int, identifier: str) -> None:
    if width == 1:
        output.write(f"{value & 1}{identifier}\n")
    else:
        output.write(f"b{value & ((1 << width) - 1):0{width}b} {identifier}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path, help="CSV from dump-wave-trace")
    parser.add_argument("output", type=Path, help="output VCD")
    parser.add_argument(
        "--extra-input", action="append", default=[], type=Path,
        help="additional range CSV from the same frozen capture",
    )
    parser.add_argument(
        "--period-ns", type=int, default=50,
        help="sample period in nanoseconds (default: 50 for the 20 MHz image)",
    )
    args = parser.parse_args()
    if args.period_ns <= 0:
        parser.error("--period-ns must be positive")

    rows_by_sample = {}
    incomplete_samples = []
    for input_path in [args.input, *args.extra_input]:
        with input_path.open(newline="") as source:
            for row in csv.DictReader(source):
                sample = int(row["sample"])
                if any(row.get(name) in (None, "") for name, _, _ in SIGNALS):
                    incomplete_samples.append((input_path, sample))
                    continue
                prior = rows_by_sample.get(sample)
                if prior is not None and prior != row:
                    raise SystemExit(
                        f"conflicting waveform records for sample {sample}"
                    )
                rows_by_sample[sample] = row
    for input_path, sample in incomplete_samples:
        print(
            f"warning: skipped incomplete sample {sample} in {input_path}",
            file=sys.stderr,
        )
    rows = [rows_by_sample[sample] for sample in sorted(rows_by_sample)]
    if not rows:
        raise SystemExit("waveform CSV has no samples")

    with args.output.open("w", newline="\n") as output:
        output.write("$version OpenRV64 FPGA USER1 waveform export $end\n")
        output.write("$timescale 1ns $end\n")
        output.write("$scope module openrv64_fpga_wave $end\n")
        for name, width, identifier in SIGNALS:
            output.write(f"$var wire {width} {identifier} {name} $end\n")
        output.write("$upscope $end\n$enddefinitions $end\n")

        previous = {}
        for row_number, row in enumerate(rows):
            sample = int(row["sample"])
            output.write(f"#{sample * args.period_ns}\n")
            for name, width, identifier in SIGNALS:
                value = parse_value(row[name])
                if row_number == 0 or previous.get(name) != value:
                    emit_value(output, value, width, identifier)
                    previous[name] = value

    print(
        f"OPENRV64 FPGA WAVE VCD PASS path={args.output.resolve()} "
        f"samples={len(rows)} period_ns={args.period_ns}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
