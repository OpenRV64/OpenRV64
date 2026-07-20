#!/usr/bin/env python3
"""Compare matched OpenRV64 and gem5 HPI dynamic pipeline windows."""

from __future__ import annotations

import argparse
import csv
import re
import statistics
import subprocess
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path


ORV_STAGES = (
    ("F", "fetch_valid", "f"),
    ("D", "decode_valid", "d"),
    ("I", "issue_valid", "i"),
    ("C", "complete_valid", "c"),
    ("R", "retire_valid", "r"),
)


@dataclass
class DynamicInstruction:
    key: str
    pc: int
    bits: int = 0
    text: str = "?"
    stages: dict[str, list[int]] = field(
        default_factory=lambda: defaultdict(list)
    )
    issue_events: list[tuple[int, str]] = field(default_factory=list)
    complete_events: list[tuple[int, str]] = field(default_factory=list)


@dataclass
class OrvTrace:
    instructions: dict[str, DynamicInstruction]
    retired: list[str]
    rows: dict[int, dict[str, int | str]]


@dataclass
class HpiTrace:
    instructions: dict[str, DynamicInstruction]
    committed: list[str]
    failed_issue: dict[int, list[str]]


def stage_span(cycles: list[int], base: int) -> str:
    if not cycles:
        return "-"
    first = min(cycles) - base
    last = max(cycles) - base
    return f"{first}" if first == last else f"{first}-{last}"


def escape_table(text: str) -> str:
    return text.replace("|", "\\|").strip()


def disassembly(elf: Path, objdump: str) -> dict[int, str]:
    output = subprocess.run(
        [objdump, "-d", str(elf)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout
    result: dict[int, str] = {}
    pattern = re.compile(
        r"^\s*([0-9a-fA-F]+):\s+[0-9a-fA-F]+\s+(.+?)\s*$"
    )
    for line in output.splitlines():
        match = pattern.match(line)
        if match:
            result[int(match.group(1), 16)] = match.group(2)
    return result


def load_orv(path: Path, disasm: dict[int, str]) -> OrvTrace:
    instructions: dict[str, DynamicInstruction] = {}
    identities: dict[tuple[int, int, int], str] = {}
    retired: list[str] = []
    retired_seen: set[str] = set()
    rows: dict[int, dict[str, int | str]] = {}

    with path.open(newline="", encoding="utf-8") as source:
        reader = csv.DictReader(source)
        for raw in reader:
            cycle = int(raw["cycle"])
            row: dict[str, int | str] = {
                name: int(raw[name], 16)
                for name in (
                    "fetch_valid", "fetch_fire", "issue_valid",
                    "complete_valid", "retire_valid", "raw", "waw",
                    "read_port", "stall_causes",
                )
            }
            for name in (
                "dispatch_q", "retire_q", "barrier", "bp_fetch_stall",
                "bp_decode_stall", "redirect",
            ):
                row[name] = int(raw[name])
            rows[cycle] = row

            for stage, mask_name, prefix in ORV_STAGES:
                mask = int(raw[mask_name], 16)
                for lane in range(3):
                    if not (mask & (1 << lane)):
                        continue
                    uid = int(raw[f"{prefix}{lane}_uid"], 16)
                    pc = int(raw[f"{prefix}{lane}_pc"], 16)
                    bits = int(raw[f"{prefix}{lane}_instr"], 16)
                    identity = (uid, pc, bits)
                    # Tentative frontend IDs can be reused after a flush.
                    # Keep PC and bits in the key so wrong-path identity does
                    # not overwrite the stable issue/retire instruction.
                    key = identities.setdefault(
                        identity, f"{uid:x}:{pc:x}:{bits:08x}"
                    )
                    inst = instructions.setdefault(
                        key,
                        DynamicInstruction(
                            key=key,
                            pc=pc,
                            bits=bits,
                            text=disasm.get(pc, f"0x{bits:08x}"),
                        ),
                    )
                    inst.stages[stage].append(cycle)
                    if stage == "I":
                        inst.issue_events.append((cycle, inst.text))
                    elif stage == "C":
                        inst.complete_events.append((cycle, inst.text))
                    elif stage == "R" and key not in retired_seen:
                        retired.append(key)
                        retired_seen.add(key)

    return OrvTrace(instructions, retired, rows)


HPI_EVENT_RE = re.compile(
    r"^\s*(\d+): .*? (Issuing inst|Issuing mem ref early inst|"
    r"Committing inst|Trying to commit mem response|Didn't issue inst): "
    r"(\S+) pc: 0x([0-9a-fA-F]+) "
    r"\(([^)]+)\)"
)
HPI_INST_RE = re.compile(
    r"^\s*(\d+): .*?MinorInst: id=(\S+) addr=0x([0-9a-fA-F]+) "
    r"inst=\"(.*?)\" class=.*? flags=\"(.*?)\""
)


def hpi_group(identifier: str) -> str:
    return identifier.rsplit(".", 1)[0]


def load_hpi(path: Path) -> HpiTrace:
    instructions: dict[str, DynamicInstruction] = {}
    metadata: dict[str, tuple[str, str]] = {}
    completed_lines: dict[str, list[tuple[int, int, str]]] = defaultdict(list)
    failed_issue: dict[int, list[str]] = defaultdict(list)

    with path.open(encoding="utf-8", errors="replace") as source:
        for line_number, line in enumerate(source):
            inst_match = HPI_INST_RE.match(line)
            if inst_match:
                cycle = int(inst_match.group(1)) // 1000
                identifier = inst_match.group(2)
                pc = int(inst_match.group(3), 16)
                text = inst_match.group(4).strip()
                flags = inst_match.group(5)
                group = hpi_group(identifier)
                metadata[identifier] = (text, flags)
                inst = instructions.setdefault(
                    group,
                    DynamicInstruction(key=group, pc=pc, text=text),
                )
                if text.endswith("_uop") or "_uop " in text:
                    if "uops" not in inst.text:
                        inst.text += " {multiple uops}"
                continue

            event_match = HPI_EVENT_RE.match(line)
            if not event_match:
                continue
            cycle = int(event_match.group(1)) // 1000
            event = event_match.group(2)
            identifier = event_match.group(3)
            pc = int(event_match.group(4), 16)
            short_op = event_match.group(5)
            group = hpi_group(identifier)
            inst = instructions.setdefault(
                group,
                DynamicInstruction(key=group, pc=pc, text=short_op),
            )
            if event == "Issuing inst":
                inst.issue_events.append((cycle, identifier))
                inst.stages["I"].append(cycle)
            elif event == "Issuing mem ref early inst":
                inst.stages["M"].append(cycle)
            elif event in ("Committing inst",
                           "Trying to commit mem response"):
                inst.complete_events.append((cycle, identifier))
                inst.stages["K"].append(cycle)
                completed_lines[group].append(
                    (line_number, cycle, identifier)
                )
            else:
                failed_issue[cycle].append(group)

    # For decomposed instructions, the final committed micro-op defines the
    # architectural commit point.
    commit_records = []
    for group, events in completed_lines.items():
        last_line, _, _ = max(events)
        commit_records.append((last_line, group))
        inst = instructions[group]
        micro_ops = [
            metadata[identifier][0]
            for _, _, identifier in events
            if identifier in metadata
        ]
        if len(micro_ops) > 1:
            first = micro_ops[0]
            inst.text = f"{first} {{{len(micro_ops)} uops}}"
        elif micro_ops:
            inst.text = micro_ops[0]
    committed = [group for _, group in sorted(commit_records)]
    return HpiTrace(instructions, committed, failed_issue)


def select_window(
    order: list[str],
    instructions: dict[str, DynamicInstruction],
    entry_pc: int,
    occurrence: int,
    count: int,
) -> tuple[int, list[str], int]:
    entries = [
        index for index, key in enumerate(order)
        if instructions[key].pc == entry_pc
    ]
    if len(entries) < occurrence:
        raise ValueError(
            f"only {len(entries)} occurrences of 0x{entry_pc:x}; "
            f"cannot select occurrence {occurrence}"
        )
    start = entries[occurrence - 1]
    selected = order[start:start + count]
    if len(selected) != count:
        raise ValueError(f"only {len(selected)} instructions remain")
    return start, selected, len(entries)


def function_call(
    order: list[str],
    instructions: dict[str, DynamicInstruction],
    start: int,
    low_pc: int,
    high_pc: int,
) -> list[str]:
    result = []
    for key in order[start:]:
        pc = instructions[key].pc
        if result and not (low_pc <= pc < high_pc):
            break
        result.append(key)
    return result


def call_span(
    keys: list[str],
    instructions: dict[str, DynamicInstruction],
    start_stage: str,
    end_stage: str,
) -> int:
    first = min(instructions[key].stages[start_stage][0] for key in keys)
    last = max(instructions[key].stages[end_stage][-1] for key in keys)
    return last - first + 1


def measure_calls(
    order: list[str],
    instructions: dict[str, DynamicInstruction],
    entry_pc: int,
    function_end: int,
    start_stage: str,
    end_stage: str,
) -> list[tuple[int, list[str], int, float]]:
    result = []
    occurrence = 0
    for start, key in enumerate(order):
        if instructions[key].pc != entry_pc:
            continue
        occurrence += 1
        keys = function_call(
            order, instructions, start, entry_pc, function_end
        )
        cycles = call_span(keys, instructions, start_stage, end_stage)
        result.append((occurrence, keys, cycles, len(keys) / cycles))
    return result


def classify(text: str) -> str:
    op = text.strip().split()[0].lower()
    if op.startswith(("lb", "lh", "lw", "ld", "ldr")):
        return "load"
    if op.startswith(("sb", "sh", "sw", "sd", "str", "stp")):
        return "store"
    if op.startswith(("b", "j", "ret", "cbz", "cbnz", "tbz", "tbnz")):
        return "control"
    return "alu/other"


def width_counts(
    selected: list[str],
    instructions: dict[str, DynamicInstruction],
    stage: str,
) -> Counter[int]:
    by_cycle: Counter[int] = Counter()
    for key in selected:
        cycles = instructions[key].stages.get(stage, [])
        if cycles:
            by_cycle[min(cycles)] += 1
    widths: Counter[int] = Counter(by_cycle.values())
    return widths


def issue_activity(
    selected: list[str],
    instructions: dict[str, DynamicInstruction],
) -> tuple[int, int]:
    """Return issued micro-ops and cycles with at least one selected issue."""
    events = [
        cycle
        for key in selected
        for cycle, _ in instructions[key].issue_events
    ]
    return len(events), len(set(events))


def orv_stall_exposure(
    trace: OrvTrace,
    first_cycle: int,
    last_cycle: int,
) -> Counter[str]:
    result: Counter[str] = Counter()
    for cycle in range(first_cycle, last_cycle + 1):
        row = trace.rows.get(cycle)
        if row is None:
            continue
        if not int(row["fetch_valid"]):
            result["frontend empty"] += 1
        if int(row["fetch_valid"]) and not int(row["fetch_fire"]):
            result["frontend held"] += 1
        if not int(row["dispatch_q"]):
            result["dispatch empty"] += 1
        if int(row["dispatch_q"]) and not int(row["issue_valid"]):
            result["queued, no issue"] += 1
        if int(row["raw"]):
            result["RAW"] += 1
        if int(row["waw"]):
            result["WAW"] += 1
        if int(row["read_port"]):
            result["read port"] += 1
        if int(row["barrier"]):
            result["barrier"] += 1
        if int(row["retire_q"]) and not int(row["retire_valid"]):
            result["retire wait"] += 1
        if int(row["bp_fetch_stall"]):
            result["BP fetch stall"] += 1
        if int(row["redirect"]):
            result["redirect"] += 1
    return result


def cycle_stalls(row: dict[str, int | str] | None) -> str:
    if row is None:
        return ""
    labels = []
    if int(row["raw"]):
        labels.append("RAW")
    if int(row["waw"]):
        labels.append("WAW")
    if int(row["read_port"]):
        labels.append("RPORT")
    if int(row["barrier"]):
        labels.append("BAR")
    if int(row["dispatch_q"]) and not int(row["issue_valid"]):
        labels.append("NOISS")
    if int(row["retire_q"]) and not int(row["retire_valid"]):
        labels.append("RETWAIT")
    if int(row["bp_fetch_stall"]):
        labels.append("BPSTALL")
    if int(row["redirect"]):
        labels.append("REDIR")
    return "+".join(labels)


def render(
    orv: OrvTrace,
    hpi: HpiTrace,
    orv_selected: list[str],
    hpi_selected: list[str],
    orv_call: list[str],
    hpi_call: list[str],
    occurrence: int,
    orv_entry_count: int,
    hpi_entry_count: int,
    orv_calls: list[tuple[int, list[str], int, float]],
    hpi_calls: list[tuple[int, list[str], int, float]],
    orv_label: str,
) -> str:
    orv_insts = [orv.instructions[key] for key in orv_selected]
    hpi_insts = [hpi.instructions[key] for key in hpi_selected]
    orv_base = min(min(inst.stages["I"]) for inst in orv_insts)
    hpi_base = min(min(inst.stages["I"]) for inst in hpi_insts)
    orv_last = max(max(inst.stages["R"]) for inst in orv_insts)
    hpi_last = max(max(inst.stages["K"]) for inst in hpi_insts)

    orv_call_cycles = call_span(orv_call, orv.instructions, "I", "R")
    hpi_call_cycles = call_span(hpi_call, hpi.instructions, "I", "K")
    orv_mix = Counter(classify(inst.text) for inst in orv_insts)
    hpi_mix = Counter(classify(inst.text) for inst in hpi_insts)
    orv_widths = width_counts(orv_selected, orv.instructions, "I")
    hpi_widths = width_counts(hpi_selected, hpi.instructions, "I")
    orv_uops, orv_issue_active = issue_activity(
        orv_selected, orv.instructions
    )
    hpi_uops, hpi_issue_active = issue_activity(
        hpi_selected, hpi.instructions
    )
    orv_window_cycles = orv_last - orv_base + 1
    hpi_window_cycles = hpi_last - hpi_base + 1
    orv_stalls = orv_stall_exposure(orv, orv_base, orv_last)
    hpi_blocked_cycles = len({
        cycle
        for cycle, groups in hpi.failed_issue.items()
        if hpi_base <= cycle <= hpi_last
        and any(group in set(hpi_selected) for group in groups)
    })
    matched_calls = []
    for orv_measure, hpi_measure in zip(orv_calls, hpi_calls):
        orv_occurrence, orv_keys, orv_cycles, orv_ipc = orv_measure
        hpi_occurrence, hpi_keys, hpi_cycles, hpi_ipc = hpi_measure
        if orv_occurrence != hpi_occurrence:
            raise ValueError("call occurrence streams are not aligned")
        if len(orv_keys) >= 100 and len(hpi_keys) >= 100:
            matched_calls.append((
                orv_occurrence, len(orv_keys), orv_cycles, orv_ipc,
                len(hpi_keys), hpi_cycles, hpi_ipc,
                orv_cycles - hpi_cycles,
            ))
    worst_calls = sorted(
        matched_calls, key=lambda item: item[-1], reverse=True
    )[:10]
    selected_rank = next(
        (
            rank
            for rank, item in enumerate(
                sorted(
                    matched_calls, key=lambda value: value[-1],
                    reverse=True,
                ),
                start=1,
            )
            if item[0] == occurrence
        ),
        None,
    )

    lines = [
        "# OpenRV64 versus HPI: matched 100-instruction pipeline window",
        "",
        f"This report starts at the {occurrence}th dynamic call to "
        "`state_transition` in both binaries. The call ordinal aligns the "
        "logical workload position; row numbers do not claim ISA-level "
        "instruction equivalence.",
        "",
        f"Observed entry calls: OpenRV64 {orv_entry_count}, HPI "
        f"{hpi_entry_count}.",
        "",
        "## Matched-call and 100-instruction summary",
        "",
        f"| Measurement | {escape_table(orv_label)} | gem5 HPI |",
        "| --- | ---: | ---: |",
        f"| Instructions in matched `state_transition` call | "
        f"{len(orv_call)} | {len(hpi_call)} |",
        f"| Issue-through-retire/commit cycles for matched call | "
        f"{orv_call_cycles} | {hpi_call_cycles} |",
        f"| Local matched-call IPC | {len(orv_call) / orv_call_cycles:.3f} | "
        f"{len(hpi_call) / hpi_call_cycles:.3f} |",
        f"| Cycles spanning the selected 100 instructions | "
        f"{orv_window_cycles} | {hpi_window_cycles} |",
        f"| Local 100-instruction IPC | "
        f"{100 / orv_window_cycles:.3f} | "
        f"{100 / hpi_window_cycles:.3f} |",
        f"| Issued backend micro-ops for those 100 instructions | "
        f"{orv_uops} | {hpi_uops} |",
        f"| Cycles with selected issue / without selected issue | "
        f"{orv_issue_active} / {orv_window_cycles - orv_issue_active} | "
        f"{hpi_issue_active} / {hpi_window_cycles - hpi_issue_active} |",
        f"| Loads / stores / controls / other | "
        f"{orv_mix['load']} / {orv_mix['store']} / "
        f"{orv_mix['control']} / {orv_mix['alu/other']} | "
        f"{hpi_mix['load']} / {hpi_mix['store']} / "
        f"{hpi_mix['control']} / {hpi_mix['alu/other']} |",
        f"| One-wide / two-wide / three-wide issue cycles | "
        f"{orv_widths[1]} / {orv_widths[2]} / {orv_widths[3]} | "
        f"{hpi_widths[1]} / {hpi_widths[2]} / n/a |",
        f"| Cycles where selected oldest instruction was blocked | "
        f"n/a | {hpi_blocked_cycles} |",
        "",
        "The width row counts architectural instruction starts. The micro-op "
        "row exposes decomposed AArch64 instructions, including pre-indexed "
        "loads; these are not free single-operation backend work in HPI.",
        "",
        "## OpenRV64 stall exposure in this 100-instruction span",
        "",
        "Counters overlap: one cycle can carry several causes.",
        "",
        f"| Condition | Cycles | Percent of {orv_window_cycles}-cycle span |",
        "| --- | ---: | ---: |",
        *[
            f"| {label} | {orv_stalls[label]} | "
            f"{100 * orv_stalls[label] / orv_window_cycles:.1f}% |"
            for label in (
                "frontend empty", "frontend held", "dispatch empty",
                "queued, no issue", "RAW", "WAW", "read port",
                "barrier", "retire wait", "BP fetch stall", "redirect",
            )
        ],
        "",
        "## What this window shows",
        "",
        "- Instruction count is not the primary deficit. For the same dynamic "
        f"call HPI executes {len(hpi_call) - len(orv_call)} more architectural "
        f"instructions yet takes {orv_call_cycles - hpi_call_cycles} fewer "
        "cycles.",
        "- Pre/post-increment is not a hidden one-uop advantage here. HPI "
        "decomposes the pre-indexed loads shown below into two issued micro-ops.",
        "- Compare/branch fusion is not required to explain HPI's lead. Its "
        "trace issues separate `subs` and conditional-branch instructions; "
        "it frequently overlaps the branch with the next independent `subs`.",
        "- The dominant deficit is scheduling and availability: OpenRV64 "
        "spends long runs with queued instructions but no issue, and its "
        "load-to-use chains expose the full memory-pipe completion latency.",
        f"- The predictor never explicitly stalls fetch in this span, but "
        f"there are {orv_stalls['redirect']} correction redirects. Prediction "
        "is therefore not free, but it is not large enough to explain the "
        f"{orv_window_cycles - hpi_window_cycles}-cycle window gap by itself.",
        "",
        "## Pipe-state examples and implicated mechanisms",
        "",
        f"- OpenRV64 rows 1-3 form a true load chain: `ld` issues at "
        f"{min(orv_insts[0].stages['I']) - orv_base} and completes at "
        f"{min(orv_insts[0].stages['C']) - orv_base}, dependent `lbu` issues "
        f"at {min(orv_insts[1].stages['I']) - orv_base} and completes at "
        f"{min(orv_insts[1].stages['C']) - orv_base}, and the branch issues "
        f"at {min(orv_insts[2].stages['I']) - orv_base}. HPI fills part of "
        "the corresponding interval with an independent `orr`, then issues "
        "`cbz` and the next independent `movz` together at relative cycle 6.",
        f"- OpenRV64 row 11 writes `a2` at issue "
        f"{min(orv_insts[10].stages['I']) - orv_base}, completes at "
        f"{min(orv_insts[10].stages['C']) - orv_base}, and retires at "
        f"{min(orv_insts[10].stages['R']) - orv_base}. Row 12 also writes "
        f"`a2` and does not issue until "
        f"{min(orv_insts[11].stages['I']) - orv_base}: RAW forwarding would "
        "not remove a destination-ownership WAW stall. HPI rows 9, 11, 13, "
        "and 15 repeatedly write `w0` and start on consecutive cycles 10-13, "
        "committing later on cycles 13-16.",
        "- HPI starts an older conditional branch and the next younger `subs` "
        "together on cycles 10, 11, 12, and 13. OpenRV64 now resolves aligned "
        "conditional branches before retirement and can place a branch behind "
        "older work in the same issue group, but the branch still terminates "
        "that group. It therefore cannot use the second ALU for a younger "
        "instruction after the branch as HPI repeatedly does here.",
        "- OpenRV64's issue chooser is a strict prefix: candidate 1 requires "
        "candidate 0 to fire and candidate 2 requires candidate 1. It cannot "
        "use an idle lane around an oldest blocked load, WAW, branch, or fixed-"
        "lane conflict. HPI is also in-order, but its latency-aware scoreboard "
        "and input buffering make the oldest-blocked intervals materially "
        "shorter.",
        "- `RETWAIT` is visible on "
        f"{orv_stalls['retire wait']} of {orv_window_cycles} cycles. This does "
        "not mean retirement alone owns all of those cycles—the counters "
        "overlap—but it shows how often the finite in-order retirement window "
        "contains work without completing its oldest contiguous prefix.",
        "- This selected window is inside `state_transition`, not at a return. "
        "The RAS improves call-boundary behavior in the full run but does not "
        "remove the dependency and scheduling bubbles shown here.",
        "",
        "## Where the matched-call cycle gap is largest",
        "",
        f"There are {len(matched_calls)} matched calls with at least 100 "
        "architectural instructions on both ISAs. Across those calls, "
        f"OpenRV64 local IPC has median "
        f"{statistics.median(item[3] for item in matched_calls):.3f}; HPI's "
        f"median is {statistics.median(item[6] for item in matched_calls):.3f}. "
        + (
            f"The selected call ranks {selected_rank} by absolute cycle gap."
            if selected_rank is not None
            else "The selected call is shorter than the substantial-call filter."
        ),
        "",
        "| Call occurrence | ORV instructions | ORV cycles | ORV IPC | HPI instructions | HPI cycles | HPI IPC | ORV minus HPI cycles |",
        "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        *[
            f"| {item[0]} | {item[1]} | {item[2]} | {item[3]:.3f} | "
            f"{item[4]} | {item[5]} | {item[6]:.3f} | {item[7]:+d} |"
            for item in worst_calls
        ],
        "",
        "Stage cycles below are relative to each core's first issue in the "
        "window. OpenRV64 shows fetch/decode/issue/complete/retire; HPI's "
        "reliable per-instruction events from `MinorExecute` are issue, "
        "memory launch (`M`), and ordered commit (`K`).",
        "",
        "OpenRV64 `F` and `D` ranges are valid-presentation intervals, not "
        "request-to-response latency. For example, `F=0-9` means the same "
        "already-fetched instruction was visible through cycle 9 while "
        "downstream backpressure prevented acceptance. The trace does not "
        "attach an individual AXI line-request start to each instruction.",
        "",
        "## 100 dynamic instructions side by side",
        "",
        "| # | OpenRV64 PC and instruction | F/D/I/C/R | HPI PC and instruction | I/M/K |",
        "| ---: | --- | --- | --- | --- |",
    ]
    for index, (orv_inst, hpi_inst) in enumerate(
        zip(orv_insts, hpi_insts), start=1
    ):
        orv_pipe = "/".join(
            stage_span(orv_inst.stages.get(stage, []), orv_base)
            for stage in ("F", "D", "I", "C", "R")
        )
        hpi_pipe = "/".join(
            stage_span(hpi_inst.stages.get(stage, []), hpi_base)
            for stage in ("I", "M", "K")
        )
        lines.append(
            f"| {index} | `{orv_inst.pc:08x}` "
            f"{escape_table(orv_inst.text)} | `{orv_pipe}` | "
            f"`{hpi_inst.pc:08x}` {escape_table(hpi_inst.text)} | "
            f"`{hpi_pipe}` |"
        )

    orv_ord = {key: index for index, key in enumerate(orv_selected, 1)}
    hpi_ord = {key: index for index, key in enumerate(hpi_selected, 1)}
    orv_cycles: dict[int, dict[str, list[str]]] = defaultdict(
        lambda: defaultdict(list)
    )
    for key in orv_selected:
        inst = orv.instructions[key]
        for stage in ("I", "C", "R"):
            for cycle in set(inst.stages.get(stage, [])):
                orv_cycles[cycle - orv_base][stage].append(
                    f"#{orv_ord[key]}"
                )
    hpi_cycles: dict[int, dict[str, list[str]]] = defaultdict(
        lambda: defaultdict(list)
    )
    for key in hpi_selected:
        inst = hpi.instructions[key]
        for stage in ("I", "M", "K"):
            for cycle in set(inst.stages.get(stage, [])):
                hpi_cycles[cycle - hpi_base][stage].append(
                    f"#{hpi_ord[key]}"
                )

    max_relative = max(orv_last - orv_base, hpi_last - hpi_base)
    lines.extend([
        "",
        "## Cycle-by-cycle backend pipe state",
        "",
        "Instruction numbers refer to the table above. Empty cells are "
        "real bubbles within that core's selected window.",
        "",
        "| Relative cycle | OpenRV64 issue | complete | retire | ORV stalls | HPI issue | memory | commit | HPI blocked oldest |",
        "| ---: | --- | --- | --- | --- | --- | --- | --- | --- |",
    ])
    for relative in range(max_relative + 1):
        absolute_orv = orv_base + relative
        absolute_hpi = hpi_base + relative
        orv_state = orv_cycles.get(relative, {})
        hpi_state = hpi_cycles.get(relative, {})
        blocked = []
        for group in hpi.failed_issue.get(absolute_hpi, []):
            if group in hpi_ord:
                blocked.append(f"#{hpi_ord[group]}")
        lines.append(
            f"| {relative} | {'/'.join(orv_state.get('I', []))} | "
            f"{'/'.join(orv_state.get('C', []))} | "
            f"{'/'.join(orv_state.get('R', []))} | "
            f"{cycle_stalls(orv.rows.get(absolute_orv))} | "
            f"{'/'.join(hpi_state.get('I', []))} | "
            f"{'/'.join(hpi_state.get('M', []))} | "
            f"{'/'.join(hpi_state.get('K', []))} | "
            f"{'/'.join(dict.fromkeys(blocked))} |"
        )
    lines.append("")
    return "\n".join(lines)


def parse_hex(value: str) -> int:
    return int(value, 16)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--orv-trace", type=Path, required=True)
    parser.add_argument("--hpi-trace", type=Path, required=True)
    parser.add_argument("--orv-elf", type=Path, default=Path("sw/coremark-loop.elf"))
    parser.add_argument(
        "--orv-objdump", default="riscv64-elf-objdump"
    )
    parser.add_argument("--orv-entry", type=parse_hex, default=0x80000040)
    parser.add_argument("--orv-function-end", type=parse_hex, default=0x8000042C)
    parser.add_argument("--hpi-entry", type=parse_hex, default=0x400030)
    parser.add_argument("--hpi-function-end", type=parse_hex, default=0x400380)
    parser.add_argument("--occurrence", type=int, default=100)
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument(
        "--orv-label",
        default="OpenRV64 3P",
        help="table label describing the measured OpenRV64 configuration",
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    orv_disasm = disassembly(args.orv_elf, args.orv_objdump)
    orv = load_orv(args.orv_trace, orv_disasm)
    hpi = load_hpi(args.hpi_trace)
    orv_start, orv_selected, orv_entry_count = select_window(
        orv.retired, orv.instructions, args.orv_entry,
        args.occurrence, args.count,
    )
    hpi_start, hpi_selected, hpi_entry_count = select_window(
        hpi.committed, hpi.instructions, args.hpi_entry,
        args.occurrence, args.count,
    )
    orv_call = function_call(
        orv.retired, orv.instructions, orv_start,
        args.orv_entry, args.orv_function_end,
    )
    hpi_call = function_call(
        hpi.committed, hpi.instructions, hpi_start,
        args.hpi_entry, args.hpi_function_end,
    )
    orv_calls = measure_calls(
        orv.retired, orv.instructions, args.orv_entry,
        args.orv_function_end, "I", "R",
    )
    hpi_calls = measure_calls(
        hpi.committed, hpi.instructions, args.hpi_entry,
        args.hpi_function_end, "I", "K",
    )
    report = render(
        orv, hpi, orv_selected, hpi_selected, orv_call, hpi_call,
        args.occurrence, orv_entry_count, hpi_entry_count,
        orv_calls, hpi_calls,
        args.orv_label,
    )
    if args.output:
        args.output.write_text(report, encoding="utf-8")
    else:
        print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
