#!/usr/bin/env python3
"""Differential trace-replay estimate for a 16-entry OpenRV64 issue window.

This is not an ISA simulator.  It extracts the committed dynamic instruction
stream, operand metadata, and measured execution latencies from a successful
3P cycle trace, then compares two schedulers under identical assumptions:

* strict: the current oldest-unissued prefix policy;
* window: oldest-ready selection from a producer-tagged window.

Both models retain real register dependencies, one MEM issue per cycle,
program-ordered MEM issue, ordered stores, hard-order operations, three-wide
issue/retirement, and a finite combined window/retirement capacity.
"""

from __future__ import annotations

import argparse
import csv
import heapq
import itertools
import json
from dataclasses import dataclass
from pathlib import Path
from statistics import median


@dataclass
class DynamicInstruction:
    uid: int
    pc: int
    bits: int
    uses_rs1: bool
    uses_rs2: bool
    rs1: int
    rs2: int
    writes_rd: bool
    rd: int
    observed_release: int
    intrinsic_release: int
    actual_issue: int
    actual_complete: int
    actual_retire: int
    actual_pipe: int
    deps: tuple[int, ...] = ()
    previous_mem: int | None = None

    @property
    def opcode(self) -> int:
        return self.bits & 0x7f

    @property
    def is_mem(self) -> bool:
        return self.opcode in (0x03, 0x23, 0x2f)

    @property
    def is_store(self) -> bool:
        return self.opcode == 0x23

    @property
    def is_branch(self) -> bool:
        return self.opcode == 0x63

    @property
    def is_jump(self) -> bool:
        return self.opcode in (0x67, 0x6f)

    @property
    def is_system_or_fence(self) -> bool:
        return self.opcode in (0x0f, 0x73)

    @property
    def is_hard(self) -> bool:
        return self.is_branch or self.is_jump or self.is_system_or_fence

    @property
    def is_persistent_hard(self) -> bool:
        # Aligned conditional branches resolve early in the current RTL.
        return self.is_jump or self.is_system_or_fence

    @property
    def is_m(self) -> bool:
        return self.opcode in (0x33, 0x3b) and ((self.bits >> 25) & 0x7f) == 1

    @property
    def pipe_options(self) -> tuple[int, ...]:
        if self.is_mem:
            return (2,)
        if self.is_branch or self.is_jump or self.is_system_or_fence:
            return (0,)
        if self.is_m:
            return (1,)
        return (0, 1)

    @property
    def latency(self) -> int:
        return max(1, self.actual_complete - self.actual_issue)


def parse_hex(raw: dict[str, str], field: str) -> int:
    return int(raw[field], 16)


def packed_reg(raw: dict[str, str], field: str, lane: int) -> int:
    return (parse_hex(raw, field) >> (lane * 5)) & 0x1f


def load_trace(path: Path) -> tuple[list[DynamicInstruction], dict[str, int]]:
    metadata: dict[int, dict[str, int | bool]] = {}
    first_f: dict[int, int] = {}
    first_f_intrinsic: dict[int, int] = {}
    first_q: dict[int, int] = {}
    issue: dict[int, tuple[int, int]] = {}
    complete: dict[int, int] = {}
    retire: dict[int, int] = {}
    committed: list[int] = []
    held_cycles = 0
    backend_held_cycles = 0
    total_cycles = 0
    actual_retired = 0

    with path.open(newline="", encoding="utf-8") as source:
        reader = csv.DictReader(source)
        required = {
            "cycle", "fetch_valid", "fetch_fire", "queue_valid",
            "issue_valid", "complete_valid", "retire_count",
            "candidate_uses_rs1", "candidate_uses_rs2",
            "candidate_reg_write", "candidate_rs1", "candidate_rs2",
            "candidate_rd",
        }
        if reader.fieldnames is None or not required.issubset(reader.fieldnames):
            missing = sorted(required.difference(reader.fieldnames or []))
            raise ValueError(f"trace lacks fields: {', '.join(missing)}")

        for raw in reader:
            cycle = int(raw["cycle"], 10)
            total_cycles += 1

            fetch_mask = parse_hex(raw, "fetch_valid")
            for lane in range(3):
                if not fetch_mask & (1 << lane):
                    continue
                uid = int(raw[f"f{lane}_uid"], 16)
                first_f.setdefault(uid, cycle)
                first_f_intrinsic.setdefault(uid, cycle - backend_held_cycles)

            queue_mask = parse_hex(raw, "queue_valid")
            uses1 = parse_hex(raw, "candidate_uses_rs1")
            uses2 = parse_hex(raw, "candidate_uses_rs2")
            reg_write = parse_hex(raw, "candidate_reg_write")
            for lane in range(3):
                if not queue_mask & (1 << lane):
                    continue
                uid = int(raw[f"q{lane}_uid"], 16)
                first_q.setdefault(uid, cycle)
                metadata.setdefault(uid, {
                    "pc": int(raw[f"q{lane}_pc"], 16),
                    "bits": int(raw[f"q{lane}_instr"], 16),
                    "uses_rs1": bool(uses1 & (1 << lane)),
                    "uses_rs2": bool(uses2 & (1 << lane)),
                    "rs1": packed_reg(raw, "candidate_rs1", lane),
                    "rs2": packed_reg(raw, "candidate_rs2", lane),
                    "writes_rd": bool(reg_write & (1 << lane)),
                    "rd": packed_reg(raw, "candidate_rd", lane),
                })

            issue_mask = parse_hex(raw, "issue_valid")
            for lane in range(3):
                if issue_mask & (1 << lane):
                    uid = int(raw[f"i{lane}_uid"], 16)
                    issue.setdefault(uid, (cycle, lane))

            complete_mask = parse_hex(raw, "complete_valid")
            for lane in range(3):
                if complete_mask & (1 << lane):
                    uid = int(raw[f"c{lane}_uid"], 16)
                    complete.setdefault(uid, cycle)

            retire_count = int(raw["retire_count"], 10)
            actual_retired += retire_count
            for lane in range(retire_count):
                uid = int(raw[f"r{lane}_uid"], 16)
                committed.append(uid)
                retire[uid] = cycle

            if fetch_mask and not parse_hex(raw, "fetch_fire"):
                held_cycles += 1
                predictor_hold = (
                    int(raw.get("bp_fetch_stall", "0"), 10) or
                    int(raw.get("bp_decode_stall", "0"), 10)
                )
                control_hold = (
                    int(raw.get("control_flush", "0"), 10) or
                    int(raw.get("control_redirect", "0"), 10)
                )
                if not predictor_hold and not control_hold:
                    backend_held_cycles += 1

    instructions: list[DynamicInstruction] = []
    for uid in committed:
        if uid not in metadata or uid not in issue or uid not in complete:
            raise ValueError(f"committed UID 0x{uid:x} lacks Q/I/C metadata")
        meta = metadata[uid]
        issue_cycle, issue_pipe = issue[uid]
        observed = first_f.get(uid, first_q[uid])
        intrinsic = first_f_intrinsic.get(
            uid, first_q[uid] - backend_held_cycles
        )
        instructions.append(DynamicInstruction(
            uid=uid,
            pc=int(meta["pc"]),
            bits=int(meta["bits"]),
            uses_rs1=bool(meta["uses_rs1"]),
            uses_rs2=bool(meta["uses_rs2"]),
            rs1=int(meta["rs1"]),
            rs2=int(meta["rs2"]),
            writes_rd=bool(meta["writes_rd"]),
            rd=int(meta["rd"]),
            observed_release=observed,
            intrinsic_release=intrinsic,
            actual_issue=issue_cycle,
            actual_complete=complete[uid],
            actual_retire=retire[uid],
            actual_pipe=issue_pipe,
        ))

    if len(instructions) != actual_retired:
        raise ValueError(
            f"extracted {len(instructions)} instructions, trace says "
            f"{actual_retired}"
        )

    last_writer: list[int | None] = [None] * 32
    previous_mem: int | None = None
    for index, instruction in enumerate(instructions):
        deps: list[int] = []
        for uses, reg in (
            (instruction.uses_rs1, instruction.rs1),
            (instruction.uses_rs2, instruction.rs2),
        ):
            producer = last_writer[reg] if uses and reg else None
            if producer is not None and producer not in deps:
                deps.append(producer)
        instruction.deps = tuple(deps)
        if instruction.writes_rd and instruction.rd:
            last_writer[instruction.rd] = index
        if instruction.is_mem:
            instruction.previous_mem = previous_mem
            previous_mem = index

    stats = {
        "cycles": total_cycles,
        "retired": actual_retired,
        "held_cycles": held_cycles,
        "backend_held_cycles": backend_held_cycles,
    }
    return instructions, stats


def pipe_assignment(
    instructions: list[DynamicInstruction], selected: tuple[int, ...]
) -> dict[int, int] | None:
    result: dict[int, int] = {}

    def assign(position: int, used: set[int]) -> bool:
        if position == len(selected):
            return True
        index = selected[position]
        for pipe in instructions[index].pipe_options:
            if pipe in used:
                continue
            result[index] = pipe
            used.add(pipe)
            if assign(position + 1, used):
                return True
            used.remove(pipe)
            result.pop(index, None)
        return False

    return result if assign(0, set()) else None


def schedule(
    instructions: list[DynamicInstruction],
    releases: list[int],
    policy: str,
    capacity: int,
    pausable_feed: bool,
    free_perfect_branches: bool = False,
    free_perfect_jumps: bool = False,
) -> dict[str, int | float]:
    count = len(instructions)
    admitted = [False] * count
    issued = [False] * count
    completed = [False] * count
    retired = [False] * count
    issue_cycle = [-1] * count
    complete_cycle = [-1] * count
    completion_heap: list[tuple[int, int]] = []
    next_admit = 0
    retire_head = 0
    cycle = min(releases)
    start_cycle = cycle
    feed_clock = cycle
    issue_slots = 0
    no_issue_cycles = 0
    window_full_cycles = 0
    max_occupancy = 0
    mem_active = 0
    skipped_oldest_cycles = 0
    max_skip_distance = 0
    feed_stall_cycles = 0
    free_branches = 0
    free_jumps = 0

    def is_free_control(index: int) -> bool:
        instruction = instructions[index]
        return (
            (free_perfect_branches and instruction.is_branch) or
            (free_perfect_jumps and instruction.is_jump)
        )

    def ready(index: int) -> bool:
        instruction = instructions[index]
        if any(not completed[producer] for producer in instruction.deps):
            return False
        if (instruction.previous_mem is not None and
                not issued[instruction.previous_mem]):
            return False
        if instruction.is_mem and mem_active >= 3:
            return False
        if instruction.is_persistent_hard and index != retire_head:
            return False
        return True

    def barrier_cutoff() -> int:
        for index in range(retire_head, next_admit):
            if (instructions[index].is_persistent_hard and
                    not retired[index]):
                return index
        return next_admit - 1

    def choose() -> dict[int, int]:
        unissued = [
            index for index in range(retire_head, next_admit)
            if admitted[index] and not issued[index]
        ]
        if not unissued:
            return {}
        cutoff = barrier_cutoff()
        unissued = [index for index in unissued if index <= cutoff]

        if policy == "strict":
            candidates: list[int] = []
            for index in unissued[:3]:
                if not ready(index):
                    break
                candidates.append(index)
                if instructions[index].is_hard:
                    break
            for width in range(len(candidates), 0, -1):
                assignment = pipe_assignment(
                    instructions, tuple(candidates[:width])
                )
                if assignment is not None:
                    return assignment
            return {}

        ready_indices = [index for index in unissued if ready(index)]
        for width in range(min(3, len(ready_indices)), 0, -1):
            best: tuple[int, ...] | None = None
            best_assignment: dict[int, int] | None = None
            for combination in itertools.combinations(ready_indices, width):
                # A hard instruction terminates its issue group.
                if any(
                    instructions[index].is_hard and
                    any(younger > index for younger in combination)
                    for index in combination
                ):
                    continue
                assignment = pipe_assignment(instructions, combination)
                if assignment is None:
                    continue
                if best is None or combination < best:
                    best = combination
                    best_assignment = assignment
            if best_assignment is not None:
                return best_assignment
        return {}

    while retire_head < count:
        # Retirement sees results completed before this cycle and preserves the
        # hard-instruction group boundary used by the RTL.
        retired_this_cycle = 0
        while (retire_head < count and retired_this_cycle < 3 and
               completed[retire_head]):
            index = retire_head
            retired[index] = True
            retire_head += 1
            retired_this_cycle += 1
            if instructions[index].is_hard and not is_free_control(index):
                break

        while completion_heap and completion_heap[0][0] <= cycle:
            when, index = heapq.heappop(completion_heap)
            if not completed[index]:
                completed[index] = True
                complete_cycle[index] = when
                if instructions[index].is_mem:
                    mem_active -= 1

        # A posted store can produce its architectural completion only at the
        # ordered head, even if its address/data were scheduled earlier.
        if (retire_head < count and issued[retire_head] and
                instructions[retire_head].is_store and
                not completed[retire_head]):
            completed[retire_head] = True
            complete_cycle[retire_head] = cycle
            mem_active -= 1

        admissions = 0
        while (next_admit < count and admissions < 3 and
               next_admit - retire_head < capacity and
               releases[next_admit] <= feed_clock):
            admitted[next_admit] = True
            if is_free_control(next_admit):
                # Performance-bound mode: perfect prediction has already put
                # the correct path in the source trace.  Treat the selected
                # control transfer as completed when it enters the window,
                # independent of source readiness and without consuming EX0
                # or an issue slot.
                # It still occupies decode/window/retirement capacity and
                # retires in program order like any architectural instruction.
                issued[next_admit] = True
                completed[next_admit] = True
                issue_cycle[next_admit] = cycle
                complete_cycle[next_admit] = cycle
                if instructions[next_admit].is_branch:
                    free_branches += 1
                else:
                    free_jumps += 1
            next_admit += 1
            admissions += 1
        occupancy = next_admit - retire_head
        max_occupancy = max(max_occupancy, occupancy)
        feed_blocked = (
            next_admit < count and releases[next_admit] <= feed_clock and
            occupancy >= capacity
        )
        if feed_blocked:
            window_full_cycles += 1

        assignment = choose()
        if assignment:
            issue_slots += len(assignment)
            oldest_unissued = next(
                index for index in range(retire_head, next_admit)
                if admitted[index] and not issued[index]
            )
            if oldest_unissued not in assignment:
                skipped_oldest_cycles += 1
                max_skip_distance = max(
                    max_skip_distance,
                    max(assignment) - oldest_unissued,
                )
            for index in sorted(assignment):
                issued[index] = True
                issue_cycle[index] = cycle
                instruction = instructions[index]
                if instruction.is_mem:
                    mem_active += 1
                if not instruction.is_store:
                    heapq.heappush(
                        completion_heap,
                        (cycle + instruction.latency, index),
                    )
        elif occupancy:
            no_issue_cycles += 1

        if pausable_feed:
            if feed_blocked:
                feed_stall_cycles += 1
            else:
                feed_clock += 1
        else:
            feed_clock += 1
        cycle += 1
        if cycle - start_cycle > 10 * max(1, count):
            raise RuntimeError(
                f"{policy} scheduler made no terminating progress at "
                f"instruction {retire_head}"
            )

    return {
        "cycles": cycle - start_cycle,
        "ipc": count / (cycle - start_cycle),
        "issued": issue_slots,
        "no_issue_cycles": no_issue_cycles,
        "window_full_cycles": window_full_cycles,
        "max_occupancy": max_occupancy,
        "skipped_oldest_cycles": skipped_oldest_cycles,
        "max_skip_distance": max_skip_distance,
        "feed_stall_cycles": feed_stall_cycles,
        "free_branches": free_branches,
        "free_jumps": free_jumps,
    }


def monotonic_release(
    instructions: list[DynamicInstruction], field: str
) -> list[int]:
    result: list[int] = []
    previous = -10**18
    for instruction in instructions:
        value = int(getattr(instruction, field))
        previous = max(previous, value)
        result.append(previous)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--capacity", type=int, default=16)
    parser.add_argument(
        "--free-perfect-branches",
        action="store_true",
        help=(
            "treat conditional branches as perfectly predicted, dependency-"
            "free zero-resource completions at window admission"
        ),
    )
    parser.add_argument(
        "--free-perfect-jumps",
        action="store_true",
        help=(
            "also treat JAL/JALR as perfectly predicted, dependency-free "
            "zero-resource completions"
        ),
    )
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    instructions, trace_stats = load_trace(args.trace)
    observed = monotonic_release(instructions, "observed_release")
    intrinsic = monotonic_release(instructions, "intrinsic_release")

    results: dict[str, dict[str, int | float]] = {}
    for feed_name, release in (
        ("observed_feed", observed),
        ("debackpressured_feed", intrinsic),
    ):
        for policy in ("strict", "window"):
            results[f"{feed_name}_{policy}"] = schedule(
                instructions, release, policy, args.capacity,
                pausable_feed=(feed_name == "debackpressured_feed"),
                free_perfect_branches=args.free_perfect_branches,
                free_perfect_jumps=args.free_perfect_jumps,
            )

    latencies = {
        "alu": [i.latency for i in instructions if not i.is_mem],
        "load": [
            i.latency for i in instructions if i.is_mem and not i.is_store
        ],
        "store": [i.latency for i in instructions if i.is_store],
    }
    output = {
        "trace": str(args.trace),
        "trace_stats": trace_stats,
        "capacity": args.capacity,
        "free_perfect_branches": args.free_perfect_branches,
        "free_perfect_jumps": args.free_perfect_jumps,
        "hazard_model": (
            "youngest-producer completion forwarding; WAW allocation "
            "allowed; no synthetic read-port cap"
        ),
        "latency_median": {
            name: median(values) if values else 0
            for name, values in latencies.items()
        },
        "results": results,
    }
    observed_strict = results["observed_feed_strict"]
    buffered_strict = results["debackpressured_feed_strict"]
    buffered_window = results["debackpressured_feed_window"]
    calibration = trace_stats["cycles"] - int(observed_strict["cycles"])
    selection_delta = (
        int(buffered_strict["cycles"]) - int(buffered_window["cycles"])
    )
    projected_cycles = int(buffered_window["cycles"]) + calibration
    strict_buffered_cycles = int(buffered_strict["cycles"]) + calibration
    output["projection"] = {
        "calibration_cycles": calibration,
        "selection_delta_cycles": selection_delta,
        "selection_only_cycles": trace_stats["cycles"] - selection_delta,
        "selection_only_ipc": (
            trace_stats["retired"] /
            (trace_stats["cycles"] - selection_delta)
        ),
        "strict_buffered_cycles": strict_buffered_cycles,
        "strict_buffered_ipc": trace_stats["retired"] / strict_buffered_cycles,
        "issue_window_cycles": projected_cycles,
        "issue_window_ipc": trace_stats["retired"] / projected_cycles,
        "issue_window_saved_cycles": trace_stats["cycles"] - projected_cycles,
    }
    print(json.dumps(output, indent=2, sort_keys=True))
    if args.json is not None:
        args.json.write_text(
            json.dumps(output, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
