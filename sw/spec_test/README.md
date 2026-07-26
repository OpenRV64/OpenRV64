# Speculative issue stress test

`spec_test.S` isolates useful issue past a predictable unresolved branch. It
provides two selectable 32-instruction, 128-byte loop bodies:

- `SPEC_TEST_FIRST_BRANCH_SLOT=6` places the delayed branch at instruction 6
  and the predictable loop branch at instruction 32;
- `SPEC_TEST_FIRST_BRANCH_SLOT=16` moves useful work ahead of the delayed
  branch, placing the two predictable branches exactly at instructions 16 and
  32.

Both layouts contain nine cache-hot loads and verified arithmetic across
sixteen accumulators. The delayed branch is always not taken by default, while
the final loop branch is predictably taken.

All sixteen accumulators are checked after 8,192 measured iterations.  A
256-iteration warm-up uses the same two branch PCs before the `mcycle`
interval.

The kernel contains 9 MEM operations and 23 EX/control operations.  With one
MEM pipe and two EX pipes, its issue-mix ceiling is therefore 32 / 12 =
2.6667 IPC, not 3 IPC.

Run the speculation-enabled and disabled controls concurrently:

```sh
make -j2 bench-spec-test
```

Run the instruction-16/instruction-32 branch layout with:

```sh
make -j2 bench-spec-test-two-branch \
    SPEC_TEST_RETIRE_DEPTH=32
```

Both use BP8, fetch mode 3, confidence gating 0, IW enabled, and RD32.  The
only changed hardware parameter is `CORE_3P_MAGIC_SPECULATION_WINDOW`: zero or
one.  This RTL parameter is an enable, despite its historical "window" name;
the issue/retirement depth is RD32.

The retirement depth and injected rare-taken rate are tunable:

```sh
# RD16, with the delayed branch taken once every 64 iterations.
make -j2 bench-spec-test \
    SPEC_TEST_RETIRE_DEPTH=16 \
    SPEC_TEST_FIRST_BRANCH_SLOT=6 \
    SPEC_TEST_MISPRED_LOG2=6
```

`SPEC_TEST_MISPRED_LOG2=0` preserves the original always-not-taken baseline.
For a nonzero value `N`, the delayed branch is taken when the iteration count
is a multiple of `2^N`; valid nonzero values are 1 through 13. Its target is a
trampoline back to the common work, so no arithmetic is skipped and the event
exercises redirect, squash, and refetch. The actual misprediction count remains
a predictor result; verify it using `direction_corrections` rather than
assuming every injected taken outcome was mispredicted.

The following injection results use the instruction-6/instruction-32 layout.
The RD16 result with one injected rare-taken outcome per 64 iterations was:

| Injection | Speculation | Cycles | Retired | IPC | Direction corrections |
|---|---|---:|---:|---:|---:|
| disabled | disabled | 219,746 | 270,417 | 1.2306 | 4 |
| disabled | enabled | 143,695 | 270,417 | 1.8819 | 4 |
| every 64 | disabled | 220,210 | 270,549 | 1.2286 | 136 |
| every 64 | enabled | 144,101 | 270,549 | 1.8775 | 137 |

The 132 injected events add exactly 132 retired trampoline jumps. Under RD16
with speculation enabled, they add 406 cycles, or 3.08 cycles per event. No
target corrections occurred.

Rate scaling under RD16 with speculation enabled:

| `MISPRED_LOG2` | Taken interval | Injected events | Cycles | Retired | Direction corrections |
|---:|---:|---:|---:|---:|---:|
| 0 | disabled | 0 | 143,695 | 270,417 | 4 |
| 4 | 16 | 528 | 145,289 | 270,945 | 533 |
| 6 | 64 | 132 | 144,101 | 270,549 | 137 |
| 8 | 256 | 33 | 143,804 | 270,450 | 38 |

The retired-instruction deltas exactly match the injected trampoline count.
SW1 produces one additional direction correction beyond each injected count,
apparently from the resulting predictor-state transition. The SW0 interval-64
control produces exactly 132 additional corrections. These counters measure
actual observed behavior; the benchmark does not label a direction change a
misprediction without a correction.

## Instruction-16/instruction-32 results

With injection disabled, both branch PCs remain predictable:

| Depth | Speculation | Cycles | Retired | IPC | Direction corrections |
|---|---|---:|---:|---:|---:|
| RD16 | disabled | 194,401 | 270,417 | 1.3910 | 4 |
| RD16 | enabled | 143,692 | 270,417 | 1.8819 | 4 |
| RD32 | disabled | 194,401 | 270,417 | 1.3910 | 4 |
| RD32 | enabled | 109,904 | 270,417 | 2.4605 | 5 |

RD32 speculation provides a 1.77x speedup over its disabled control. The
2.4605 IPC result reaches 92.27% of the common 2.6667 instruction-mix ceiling.
RD16 retains a 1.35x speculation speedup.

The remaining RD32 loss is not a branch-prediction failure.  The slot-6 and
slot-16 runs have the same five direction corrections and nearly identical
frontend-empty time (8,462 versus 8,457 cycles).  Instead,
`rv64_top_3p.v` applies `frontend_prefix_allow` before the prediction outcome
matters: every lane younger than the oldest control instruction is masked from
decode.  Thus even a correctly predicted not-taken branch ends the current
3-wide packet.

That policy interacts badly with branch positions 16 and 32:

- slots 1--16 and 17--32 each require `ceil(16 / 3) = 6` packets, for 12
  packets per iteration;
- with branches at slots 6 and 32, the two segments require
  `ceil(6 / 3) + ceil(26 / 3) = 11` packets per iteration.

The measured width histograms confirm the static packet count.  The slot-16
layout decoded 16,917 one-wide packets, almost exactly two branch-ending
packets for each of 8,448 warm-up plus measured iterations.  The slot-6 layout
instead decoded 8,450 two-wide packets and only 23 one-wide packets.  Moving
the first branch from slot 6 to slot 16 therefore adds one decode packet and
8,442 total cycles, effectively one cycle per iteration.  Both layouts already
pay roughly one frontend-empty predicted-loop-redirect cycle per iteration.
The slot-6 layout has enough packing headroom to overlap that bubble with its
12-cycle execution floor: 11 nonempty decode packets plus the redirect bubble.
The slot-16 layout needs 12 nonempty packets plus the same bubble, making its
steady-state floor 13 cycles, or `32 / 13 = 2.4615` IPC.  The measured 2.4605
IPC is essentially that floor.

Fetch requests also rise from 25,384 to 33,822 while frontend-empty cycles do
not rise.  This is control-boundary packet fragmentation plus the existing
predicted-taken restart bubble, not loss of predictor accuracy or L1I
starvation.  Predictable branches avoid correction flushes; they do not make
redirects free, and the current frontend does not support branch-through
packing of their fall-through lanes.

RD32 with an injected rare-taken outcome every 64 iterations:

| Speculation | Cycles | Retired | IPC | Direction corrections |
|---|---:|---:|---:|---:|
| disabled | 194,928 | 270,549 | 1.3879 | 137 |
| enabled | 110,906 | 270,549 | 2.4394 | 137 |

The 132 injected events add 1,002 cycles to the enabled RD32 result, or 7.59
cycles per event including the retired trampoline. No target corrections
occurred.

On 2026-07-26, the instruction-6/instruction-32 RD32 runs passed with the same
270,417 retired instructions:

| Speculation | Cycles | IPC |
|---|---:|---:|
| disabled | 202,847 | 1.3331 |
| enabled | 101,462 | 2.6652 |

The enabled result is 99.95% of the kernel's 2.6667 mix ceiling and cuts
cycles by 49.98%.  It resolved 16,917 conditional branches with five direction
corrections and no target corrections.
