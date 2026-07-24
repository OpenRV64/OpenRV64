#!/usr/bin/env python3
"""Extract comparable Linux boot milestones from tb_opensbi logs.

UART output and periodic progress output share stdout.  Unless the testbench
printed an explicit PERF SIGNPOST/PERF MILESTONE record, a UART milestone can
only be bracketed by the progress records before and after it.  Report that
range rather than assigning the milestone a false exact cycle.
"""

from __future__ import annotations

import argparse
import bisect
import dataclasses
import pathlib
import re
import sys


PROGRESS_RE = re.compile(
    r"OpenSBI progress cycles=(?P<cycles>\d+) instret=(?P<instret>\d+)"
)
EXACT_RE = re.compile(
    r"PERF (?:SIGNPOST|MILESTONE) name=(?P<name>[-a-z0-9]+)"
    r" cycles=(?P<cycles>\d+) instret=(?P<instret>\d+)"
)


@dataclasses.dataclass(frozen=True)
class Marker:
    name: str
    description: str
    pattern: re.Pattern[str]


MARKERS = (
    Marker("opensbi", "OpenSBI banner", re.compile(r"OpenSBI v\d")),
    Marker("linux", "Linux banner", re.compile(r"Linux version \S+")),
    Marker(
        "memory",
        "kernel memory accounting",
        re.compile(r"Memory: \d+K/\d+K available"),
    ),
    Marker(
        "devtmpfs",
        "devtmpfs initialized",
        re.compile(r"devtmpfs: initialized"),
    ),
    Marker(
        "plic",
        "PLIC initialized",
        re.compile(r"riscv-plic: .* mapped \d+ interrupts"),
    ),
    Marker(
        "uart",
        "8250 console initialized",
        re.compile(r"serial: ttyS0 .* is a 16550A"),
    ),
    Marker(
        "initmem",
        "kernel init memory freed",
        re.compile(r"Freeing unused kernel image"),
    ),
    Marker(
        "init",
        "PID 1 started",
        re.compile(r"Run /init as init process"),
    ),
    Marker("bash", "Bash prompt", re.compile(r"openrv64# ")),
)


@dataclasses.dataclass(frozen=True)
class Progress:
    line: int
    cycles: int
    instret: int


@dataclasses.dataclass(frozen=True)
class Signpost:
    log: pathlib.Path
    marker: Marker
    line: int
    exact_cycles: int | None
    exact_instret: int | None
    lower: Progress | None
    upper: Progress | None

    def cycle_text(self) -> str:
        if self.exact_cycles is not None:
            return format_cycles(self.exact_cycles)
        if self.lower is not None and self.upper is not None:
            if self.lower.cycles == self.upper.cycles:
                return format_cycles(self.lower.cycles)
            return (
                f"{format_cycles(self.lower.cycles)}"
                f"..{format_cycles(self.upper.cycles)}"
            )
        if self.lower is not None:
            return f">={format_cycles(self.lower.cycles)}"
        if self.upper is not None:
            return f"<={format_cycles(self.upper.cycles)}"
        return "unknown"

    def instret_text(self) -> str:
        if self.exact_instret is not None:
            return str(self.exact_instret)
        if self.lower is not None and self.upper is not None:
            if self.lower.instret == self.upper.instret:
                return str(self.lower.instret)
            return f"{self.lower.instret}..{self.upper.instret}"
        if self.lower is not None:
            return f">={self.lower.instret}"
        if self.upper is not None:
            return f"<={self.upper.instret}"
        return "unknown"


def format_cycles(cycles: int) -> str:
    if cycles % 1_000_000 == 0:
        return f"{cycles // 1_000_000}M"
    value = f"{cycles / 1_000_000:.3f}".rstrip("0").rstrip(".")
    return f"{value}M"


def extract(path: pathlib.Path) -> list[Signpost]:
    lines = path.read_text(errors="replace").splitlines()
    progress: list[Progress] = []
    exact: dict[str, tuple[int, int, int]] = {}

    for line_number, line in enumerate(lines, start=1):
        for match in PROGRESS_RE.finditer(line):
            progress.append(
                Progress(
                    line=line_number,
                    cycles=int(match.group("cycles")),
                    instret=int(match.group("instret")),
                )
            )
        for match in EXACT_RE.finditer(line):
            exact.setdefault(
                match.group("name"),
                (
                    line_number,
                    int(match.group("cycles")),
                    int(match.group("instret")),
                ),
            )

    progress.sort(key=lambda item: item.line)
    progress_lines = [item.line for item in progress]
    found: list[Signpost] = []
    for marker in MARKERS:
        marker_line = next(
            (
                line_number
                for line_number, line in enumerate(lines, start=1)
                if marker.pattern.search(line)
            ),
            None,
        )
        exact_entry = exact.get(marker.name) or exact.get(f"linux-{marker.name}")
        if marker_line is None and exact_entry is None:
            continue

        if exact_entry is not None:
            exact_line, exact_cycles, exact_instret = exact_entry
            marker_line = marker_line or exact_line
        else:
            exact_cycles = None
            exact_instret = None

        position = bisect.bisect_right(progress_lines, marker_line)
        lower = progress[position - 1] if position else None
        upper = progress[position] if position < len(progress) else None
        found.append(
            Signpost(
                log=path,
                marker=marker,
                line=marker_line,
                exact_cycles=exact_cycles,
                exact_instret=exact_instret,
                lower=lower,
                upper=upper,
            )
        )
    return found


def render_markdown(groups: list[tuple[pathlib.Path, list[Signpost]]]) -> str:
    output = []
    for path, signposts in groups:
        output.extend(
            (
                f"### `{path}`",
                "",
                "| Signpost | Cycles | Instructions retired | Log line |",
                "|---|---:|---:|---:|",
            )
        )
        for signpost in signposts:
            output.append(
                f"| {signpost.marker.description} | "
                f"{signpost.cycle_text()} | {signpost.instret_text()} | "
                f"{signpost.line} |"
            )
        if not signposts:
            output.append("| No recognized signposts | unknown | unknown | - |")
        output.append("")
    return "\n".join(output)


def render_tsv(groups: list[tuple[pathlib.Path, list[Signpost]]]) -> str:
    output = ["log\tname\tdescription\tcycles\tinstret\tline"]
    for path, signposts in groups:
        for signpost in signposts:
            output.append(
                "\t".join(
                    (
                        str(path),
                        signpost.marker.name,
                        signpost.marker.description,
                        signpost.cycle_text(),
                        signpost.instret_text(),
                        str(signpost.line),
                    )
                )
            )
    return "\n".join(output) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", type=pathlib.Path, nargs="+")
    parser.add_argument(
        "--format",
        choices=("markdown", "tsv"),
        default="markdown",
        help="output format (default: markdown)",
    )
    args = parser.parse_args()

    missing = [path for path in args.logs if not path.is_file()]
    if missing:
        for path in missing:
            print(f"error: log does not exist: {path}", file=sys.stderr)
        return 2

    groups = [(path, extract(path)) for path in args.logs]
    if args.format == "markdown":
        print(render_markdown(groups))
    else:
        print(render_tsv(groups), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
