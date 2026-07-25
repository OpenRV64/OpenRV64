#!/usr/bin/env python3
# Copyright 2015 Google Inc. All Rights Reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Modified for OpenRV64: this build-time generator retains Google
# Multi-Chase's randomized permutation, TLB-locality grouping, and mixed
# in-element pointer placement, but emits a static cross-architecture ring.

"""Generate a deterministic Google Multi-Chase-style pointer ring."""

from __future__ import annotations

import argparse
from pathlib import Path


MASK64 = (1 << 64) - 1


class SplitMix64:
    """Small, specified RNG so generated images do not depend on Python's RNG."""

    def __init__(self, seed: int) -> None:
        self.state = seed & MASK64

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        value = self.state
        value = ((value ^ (value >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        value = ((value ^ (value >> 27)) * 0x94D049BB133111EB) & MASK64
        return value ^ (value >> 31)

    def bounded(self, limit_inclusive: int) -> int:
        if limit_inclusive < 0:
            raise ValueError("negative RNG limit")
        return self.next() % (limit_inclusive + 1)


def random_permutation(count: int, base: int, rng: SplitMix64) -> list[int]:
    """Forward Fisher-Yates form used by Google Multi-Chase."""

    permutation = [0] * count
    for index in range(count):
        target = rng.bounded(index)
        permutation[index] = permutation[target]
        permutation[target] = base + index
    return permutation


def make_order(
    nodes: int, nodes_per_locality_group: int, rng: SplitMix64
) -> list[int]:
    groups = (nodes + nodes_per_locality_group - 1) // nodes_per_locality_group
    group_order = random_permutation(groups, 0, rng)
    order: list[int] = []
    for group in group_order:
        base = group * nodes_per_locality_group
        count = min(nodes_per_locality_group, nodes - base)
        order.extend(random_permutation(count, base, rng))
    if sorted(order) != list(range(nodes)):
        raise RuntimeError("internal error: generated order is not a permutation")
    return order


def make_successors(order: list[int]) -> list[int]:
    successors = [0] * len(order)
    for index, node in enumerate(order):
        successors[node] = order[(index + 1) % len(order)]

    visited: set[int] = set()
    node = 0
    for _ in order:
        if node in visited:
            raise RuntimeError("internal error: ring closes before visiting every node")
        visited.add(node)
        node = successors[node]
    if node != 0 or len(visited) != len(order):
        raise RuntimeError("internal error: generated links do not form one ring")
    return successors


def emit(
    output: Path,
    byte_count: int,
    stride: int,
    locality: int,
    seed: int,
) -> None:
    if byte_count <= 0 or stride <= 0 or locality <= 0:
        raise SystemExit("bytes, stride, and locality must be positive")
    if stride < 8 or stride % 8:
        raise SystemExit("stride must be a multiple of 8 and at least 8")
    if byte_count % stride:
        raise SystemExit("bytes must be a multiple of stride")
    if locality % stride:
        raise SystemExit("TLB locality must be a multiple of stride")

    nodes = byte_count // stride
    rng = SplitMix64(seed)
    order = make_order(nodes, locality // stride, rng)
    successors = make_successors(order)

    # Multi-Chase mixes pointer locations within each stride-sized element to
    # avoid favoring one cache-bank or DRAM-index pattern.
    slots = stride // 8
    offsets = [rng.bounded(slots - 1) * 8 for _ in range(nodes)]

    lines = [
        "/*",
        " * Generated Google Multi-Chase-style pointer ring.",
        " *",
        " * Copyright 2015 Google Inc. All Rights Reserved.",
        " * SPDX-License-Identifier: Apache-2.0",
        " *",
        " * Modified for OpenRV64 into a static, deterministic ring.",
        " * Do not edit; regenerate with tools/gen_multichase_ring.py.",
        " */",
        "",
        '.section .rodata.pointer_chase, "a"',
        f".balign {stride}",
        ".global pointer_chase_arena",
        "pointer_chase_arena:",
    ]

    for node, successor in enumerate(successors):
        offset = offsets[node]
        if offset:
            lines.append(f"    .zero {offset}")
        if node == 0:
            lines.extend((".global pointer_chase_start", "pointer_chase_start:"))
        target_offset = successor * stride + offsets[successor]
        lines.append(f"    .quad pointer_chase_arena + {target_offset}")
        tail = stride - offset - 8
        if tail:
            lines.append(f"    .zero {tail}")

    lines.extend(
        (
            ".global pointer_chase_arena_end",
            "pointer_chase_arena_end:",
            "",
        )
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--bytes", type=int, default=16 * 1024 * 1024)
    parser.add_argument("--stride", type=int, default=256)
    parser.add_argument("--tlb-locality", type=int, default=256 * 1024)
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    emit(args.output, args.bytes, args.stride, args.tlb_locality, args.seed)


if __name__ == "__main__":
    main()
