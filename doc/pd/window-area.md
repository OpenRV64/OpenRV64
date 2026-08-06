# 4PF issue-window area reduction

Last updated: 2026-08-05

## Scope

This report records two structural experiments on the 16-entry 4PF issue and
retirement window:

1. **Stage 1**, the implemented compact resident-window representation and
   slot-based dependency/age machinery.
2. **Registered issue selection**, an optional second boundary that holds the
   selected integer and LSU slot for one cycle before execution.

The stage-1 measurement is a comparison of complete source states.  It
includes the compact payload, slot tags, circular age walk, selected operand
reads, and registered completion wakeup as one change set.  The retained data
does not isolate those edits individually, so this report does not assign an
area percentage to any one of them.

The implementation is in
[`dispatch_window_4pf.v`](../../rtl/core/exec/fpu/dispatch_window_4pf.v).  The
reproducible mapping entry point is
[`report-core-4pf.sh`](../../synth/nangate45/report-core-4pf.sh).

The working tree was based on commit
`c9c830eb48074afe62612abefc9e4bc2f9467878` and contained uncommitted 4PF and
F/D work.  The commit alone therefore does not reproduce the measurements.

## Result

Stage 1 removed approximately 56% of the window's mapped standard-cell area
and 56% of its cells.  The unbuffered, partition-local ABC delay fell by
76--77%.  In the cacheless full-core accounting this reduced area by 11.8%
with F/D enabled and 18.6% without F/D.

The optional registered selector removes a further 5.8% of the stage-1
window area, but does **not** improve its mapped delay.  The window delay is
1.7% worse and the full-core worst retained-partition delay is unchanged.  It
is therefore an area option, not a demonstrated frequency optimization.

## Why the original window was large

A window entry remains allocated until precise retirement.  The original
implementation treated that long-lived entry as both scheduling metadata and
an execution-payload cache:

- every entry retained the complete 402-bit execution payload;
- the payload included two 64-bit operand values and a 64-bit trace identity;
- source dependencies and owner state used global 10-bit instruction IDs;
- the architectural owner table duplicated 64-bit completed values;
- issue reconstructed several wide, depth-selected payload paths; and
- age and readiness logic was expressed in terms of broad entry comparisons
  rather than the natural circular retirement-slot order.

At depth 16 this produced 10,499 mapped DFFs and more than 126,000 `MUX2_X1`
cells in the retained window partition.  The problem was not merely the
number of entries.  It was the product of entry count, resident payload width,
multi-consumer selection, and age/readiness fanout.

## Stage 1 structural changes

Stage 1 changes the representation and the issue-time materialization point.

### Compact resident payload

The resident execution payload falls from 402 bits to 210 static bits.  The
window keeps fields needed for scheduling, exception/order classification,
and eventual execution, but no longer stores both operand values in every
entry.  The legacy 402-bit execution packet is reconstructed only for a
selected instruction.

Trace identity is held separately and synthesizes away when `ENABLE_TRACE=0`,
which is the measured configuration.

### Slot-indexed dependency state

The retirement slot is already the unique identity of a live window entry.
Stage 1 therefore replaces 10-bit producer instruction IDs with 4-bit producer
slots at depth 16.  Each source reads the producer's single slot-indexed result
instead of copying the completed value into every consumer or architectural
owner entry.

The age walk starts at `next_retire_slot_i` and visits the circular slot ring
from oldest to youngest.  Prefix state accumulated during that walk encodes
older hard, memory, and control blockers.  This removes the need for a forest
of pairwise modular instruction-ID age comparisons.

These two changes are coupled: a four-bit slot tag is sufficient only while a
slot cannot be reused before the prior occupant retires.  That is true for the
current combined issue/retirement window.

### Selected operand access

Architectural operands are read after selection.  Integer and LSU selections
drive the GPR addresses required for that cycle; dependent sources select the
producer slot's result.  The F/D sidecar requests a scalar GPR value through a
selected read interface rather than receiving two 64-bit values for every
window entry.

Completion wakeup is registered.  A dependent instruction becomes eligible
on the cycle after its producer completes.  This deliberate cycle prevents an
issue-to-execute-to-complete-to-wakeup-to-issue combinational loop.

## Synthesis method

All figures use the same repository Nangate45 flow:

| Setting | Value |
| --- | --- |
| Yosys | 0.66 (`86f2ddebc-dirty`) |
| Library | Nangate Open Cell Library, typical |
| Liberty SHA-256 | `8d540a4d4cf6d09d27c87ad067857a9c0c2eeb023ab7a56e058cd3113db4e9b1` |
| ABC constraints SHA-256 | `38f99902a70c188bf0272f5e76f3fe244f15ee134f48b2b31de54e4f3a40f6bf` |
| Window / retirement depth | 16 |
| L1I / L1D | Disabled |
| Trace | Disabled |
| FP multiplier | Pipelined |
| ABC recipe | `strash; dretime; strash; &get -n; &nf; &put` |

The flow retains major reporting partitions and recursively accounts their
mapped cells at the top.  The reported delay is the maximum unbuffered ABC
`stime` delay inside a retained partition.  It is not flattened whole-core
STA, has no placement, routing, CTS, wire load, clock uncertainty, or SRAM
macro timing, and must not be converted into a frequency claim.

The `fd` and `nofd` variants are otherwise source matched.  The latter proves
that the window result is not an artifact of reachable F/D logic.

## Stage 1 mapped results

### Window partition

| Variant | Metric | Original | Stage 1 | Change |
| --- | --- | ---: | ---: | ---: |
| F/D | Area | 555,425.822 um² | 244,169.380 um² | -311,256.442 um² (-56.04%) |
| F/D | Sequential area | 55,854.680 um² | 26,743.640 um² | -29,111.040 um² (-52.12%) |
| F/D | Mapped cells | 377,551 | 167,635 | -209,916 (-55.60%) |
| F/D | DFFs | 10,499 | 5,027 | -5,472 (-52.12%) |
| F/D | `MUX2_X1` | 126,296 | 35,053 | -91,243 (-72.25%) |
| F/D | Partition delay | 5,877,050 ps | 1,377,164 ps | -76.57% |
| no F/D | Area | 555,503.760 um² | 244,167.784 um² | -311,335.976 um² (-56.05%) |
| no F/D | Mapped cells | 378,086 | 167,635 | -210,451 (-55.66%) |
| no F/D | Partition delay | 6,087,163 ps | 1,377,163 ps | -77.38% |

The nearly identical stage-1 window maps with and without F/D are expected:
F/D arithmetic is outside this retained partition, and the window exposes a
narrow selected interface to the extension sidecar.

### Cacheless full core

| Variant | Metric | Original | Stage 1 | Change |
| --- | --- | ---: | ---: | ---: |
| F/D | Area | 2,679,917.548 um² | 2,362,813.628 um² | -317,103.920 um² (-11.83%) |
| F/D | Sequential area | 439,291.552 um² | 410,180.512 um² | -6.63% |
| F/D | Mapped cells | 1,769,651 | 1,555,722 | -12.09% |
| F/D | Worst retained delay | 26,274,024 ps | 23,144,082 ps | -11.91% |
| no F/D | Area | 1,684,807.026 um² | 1,371,543.880 um² | -313,263.146 um² (-18.59%) |
| no F/D | Sequential area | 355,618.592 um² | 326,507.552 um² | -8.19% |
| no F/D | Mapped cells | 1,035,754 | 823,743 | -20.47% |
| no F/D | Worst retained delay | 7,668,951 ps | 7,668,951 ps | unchanged |

The F/D whole-core delay improves because the changed source state also
reduces logic in the retained 4PF core partition.  The no-F/D worst partition
remains the ICX bus, so a large window-local improvement cannot change its
reported maximum.  Neither observation proves timing closure.

## Registered issue-selection probe

`REGISTER_ISSUE_SELECT=1` holds three integer/LSU selections: EX0, EX1, and
MEM.  Each boundary contains one valid bit and a four-bit slot, for 15 added
DFFs.  A held slot remains unissued until the destination pipe accepts it and
is excluded from reselection.

The F/D sidecar retains its direct selector.  This probe therefore does not
insert a cycle in front of ordinary F/D compute issue.

### Area and timing impact

| Metric | Stage 1 direct | Registered select | Change |
| --- | ---: | ---: | ---: |
| F/D window area | 244,169.380 um² | 230,078.828 um² | -14,090.552 um² (-5.77%) |
| no-F/D window area | 244,167.784 um² | 230,072.444 um² | -14,095.340 um² (-5.77%) |
| Window sequential area | 26,743.640 um² | 26,823.440 um² | +79.800 um² (+0.30%) |
| F/D window cells | 167,635 | 155,056 | -12,579 (-7.50%) |
| F/D window delay | 1,377,164 ps | 1,400,999 ps | +1.73% worse |
| Full F/D area | 2,362,813.628 um² | 2,348,723.076 um² | -0.60% |
| Full no-F/D area | 1,371,543.880 um² | 1,357,448.540 um² | -1.03% |
| Full F/D worst delay | 23,144,082 ps | 23,144,082 ps | unchanged |
| Full no-F/D worst delay | 7,668,951 ps | 7,668,951 ps | unchanged |

The additional 0.0141 mm² window saving is real in this map, but it is only
4.5% as large as the absolute stage-1 window saving.  Cumulatively, stage 1
plus registered selection reduces the original F/D window area by 58.58%, the
full F/D core by 12.36%, and the no-F/D core by 19.43%.

The registered window's reported critical path still starts at `valid_q[0]`
and ends at an output mux.  Registering the selected slot does not cut that
cone.  It permits a smaller mapping of the selection/output logic, but the
remaining mapped cone is 1.7% slower.  A timing benefit should not be claimed
from this experiment.

### Cycle-model cost

The source-matched full DAXPY comparison used the immediate testbench memory
configuration (`l1i=0`, `l1d=0`, tagged-RAM ICX home).  Both configurations
passed numerical checks, issued and received all 256 FMA operations in every
phase, and completed all FP loads and stores.

| DAXPY region | Stage 1 direct | Registered select | Change |
| --- | ---: | ---: | ---: |
| Unroll 1 | 10,018 cycles | 10,279 cycles | +2.61% |
| Unroll 4 | 6,555 cycles | 6,562 cycles | +0.11% |
| Unroll 16 | 5,812 cycles | 5,803 cycles | -0.15% |
| Unroll 32 | 5,597 cycles | 5,595 cycles | -0.04% |
| Entire test, including setup/checking | 51,303 cycles | 55,704 cycles | +8.58% |

The small negative deltas in the longer-unroll measured regions are noise at
this level, not evidence that the extra stage improves performance.  The
useful conclusion is that LSU and retirement pressure hide the extra selector
stage in the unrolled DAXPY kernels.  The larger whole-test regression shows
that integer-heavy setup, checking, and control code does not hide it as well.

Stage 1 itself deliberately delays dependent wakeup by one cycle.  Functional
regressions pass, but no retained source-matched pre-stage cycle log isolates
the performance cost of that wakeup change alone.  This report therefore
makes no numerical stage-1 IPC claim.

## Remaining limitation in registered mode

The registered memory slot remains formally unissued until acceptance.
Program-order memory prefix logic consequently treats it as the oldest
unissued memory operation and prevents selection of the following memory
operation during that cycle.  The current DAXPY/LSU bottlenecks mostly hide
this bubble, but a future one-request-per-cycle LSU could expose it directly.

Before registered selection is considered production-ready, the handoff must
allow selection of the next memory operation when the held request is known to
fire, without creating a ready/valid combinational loop.  That change needs a
directed consecutive-load/store test in addition to DAXPY.

## Physical-design interpretation

Stage 1 is the major structural win and should remain the baseline.  The
window is no longer primarily a register-capacity problem: sequential cells
are about 11% of its stage-1 mapped area.  Further reductions now require
changing combinational selection, fanout, and output organization rather than
only deleting resident bits.

The registered selector is a plausible area knob when one additional integer
and LSU issue cycle is acceptable.  It should remain disabled by default for
now because:

- it saves only 0.60% of the mapped F/D core;
- it has no demonstrated timing benefit;
- the complete test is 8.58% slower in this cycle model;
- consecutive memory scheduling contains a known bubble; and
- the F/D selector is not registered by this option.

If physical implementation later shows the window output mux or its routing
on the real critical path, the next experiment should register a deliberately
defined payload/read-address boundary and run placed-and-routed comparison.
The current partition-local ABC result is insufficient reason to add more
latency.

## Validation and reproduction

Stage 1 and the registered probe passed:

- the full 4PF F/D load/store fault and unsupported-operation trap test;
- full fetch-to-retirement DAXPY with unroll 1, 4, 16, and 32;
- Verilator lint, with existing unrelated top-level warnings;
- Nangate45 F/D and no-F/D synthesis; and
- `git diff --check`.

Run the direct stage-1 reports with:

```sh
YOSYS_CORE_4PF_NANGATE45_REPORT_DIR=/tmp/window-stage1 \
  make -j2 yosys-resources-core-4pf-nangate45
```

Run the registered-selector reports with:

```sh
REGISTER_ISSUE_SELECT=1 \
YOSYS_CORE_4PF_NANGATE45_REPORT_DIR=/tmp/window-registered \
  make -j2 yosys-resources-core-4pf-nangate45
```

The synthesis wrapper records `registered_issue_select` in each generated
`summary.json`.  Use separate output directories: reusing a worker directory
can retain stale per-partition files from a prior parameterization.
