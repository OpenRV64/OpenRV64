# OpenRV64 3P physical size

## What was run, and when (UTC)

| Item | Value |
|---|---|
| Run | Sky130 functional-partition standard-cell map |
| Command | `make yosys-resources-core-sky130` |
| Started | 2026-07-21 00:28:33 UTC |
| Finished | 2026-07-21 00:41:50 UTC |
| Source | Git `1f46e483f34305a9be2c45f902a9e4c0b7015ee9`, with a dirty working tree |
| Top | `openrv64_top_3p` |
| Tool | Yosys 0.66 (`86f2ddebc-dirty`) with ABC |
| Cell library | `sky130_fd_sc_hd__tt_025C_1v80.lib`, TT, 25 C, 1.8 V |
| Library SHA-256 | `ec0e1067a35c8bf20b11e58d1e8ac53326067e4dac84a125cc1b917a3518d0d9` |
| ABC constraints | `sky130_fd_sc_hd__inv_2` input driver, 10 fF output load |
| Constraint SHA-256 | `7bc97e5a90f50e8b3f7f46984b55595886869c3b0b9b09b8f752a7dc6574714b` |

The run used the live working tree, including uncommitted and untracked RTL.
The commit hash alone therefore does not reproduce this snapshot. The raw
outputs are in `sim/yosys/core-sky130/`: `resources.md`, `resources.csv`,
`resources.json`, and `partitioned-yosys.log`.

## Result

The current core maps to **2,808,674 um^2**, or **2.808674 mm^2**, of Sky130
HD Liberty cell area. Sequential cells account for **788,965 um^2**
(**28.09%**). There are **372,966 mapped standard cells**.

The categories below are exclusive. Parent area has its retained child area
subtracted, so the table does not double-count hierarchy. Percentages use the
2,808,674 um^2 partitioned total. The unrounded percentages sum to 100%; the
displayed two-decimal entries sum to 100.01% because of independent rounding.
For the same reason, the displayed whole-um^2 block rows sum one um^2 above the
rounded total.

| Functional block | Area (um^2) | Area (mm^2) | Core | Sequential area (um^2) | Cells |
|---|---:|---:|---:|---:|---:|
| Retirement | 699,146 | 0.699146 | 24.89% | 187,630 | 97,405 |
| Backend control/forwarding | 375,060 | 0.375060 | 13.35% | 113,709 | 50,819 |
| MMU + 256-bit AXI | 371,832 | 0.371832 | 13.24% | 176,365 | 40,033 |
| CSR/PMP | 353,881 | 0.353881 | 12.60% | 37,168 | 52,037 |
| Dispatch/hazards | 291,065 | 0.291065 | 10.36% | 46,194 | 39,058 |
| Integer register file | 182,192 | 0.182192 | 6.49% | 49,648 | 26,723 |
| EX1 integer/M | 167,477 | 0.167477 | 5.96% | 32,957 | 24,533 |
| LSU/MEM pipe | 150,705 | 0.150705 | 5.37% | 68,293 | 16,110 |
| Fetch/line buffers | 95,201 | 0.095201 | 3.39% | 40,964 | 9,473 |
| EX0 integer/branch | 52,465 | 0.052465 | 1.87% | 13,113 | 8,013 |
| Branch predictor | 45,421 | 0.045421 | 1.62% | 18,863 | 5,393 |
| Frontend/core control | 15,415 | 0.015415 | 0.55% | 4,061 | 2,058 |
| Decode | 5,225 | 0.005225 | 0.19% | 0 | 858 |
| Trap/redirect vector | 3,590 | 0.003590 | 0.13% | 0 | 453 |
| AXI wrapper/glue | 0 | 0.000000 | 0.00% | 0 | 0 |
| **Total** | **2,808,674** | **2.808674** | **100.00%** | **788,965** | **372,966** |

The five largest categories consume **74.45%** of the core. Retirement alone
is nearly one quarter. Retirement, backend control/forwarding, and dispatch
together consume **48.61%**, which confirms that dependency, ordering,
completion, and forwarding state is the dominant structural cost.

## What each block contains

- **Retirement:** eight-entry completion/retirement buffer, in-order prefix
  retirement, and architectural side effects.
- **Backend control/forwarding:** allocation, full-forwarding fabric, branch
  control, and backend glue, excluding the retained children below it.
- **MMU + 256-bit AXI:** I/D TLBs, page-table walker, request tracking, and the
  256-bit AXI master.
- **CSR/PMP:** privileged CSRs, interrupt state, counters, and eight-entry PMP.
- **Dispatch/hazards:** six-entry dispatch queue, dependency map, issue
  selection, and barriers.
- **Integer register file:** 32x64 GPRs with six read and three write ports.
- **EX1 integer/M:** the second RV64I ALU and the RV64M unit.
- **LSU/MEM pipe:** loads/stores, atomics, posted-store state, and store/load
  forwarding.
- **Fetch/line buffers:** three-wide fetch, four line slots, replay, and
  predecode metadata.
- **EX0 integer/branch:** RV64I ALU, conditional branch execution, system CSR
  execution, and exceptions.
- **Branch predictor:** 32-entry, 3-bit bimodal table, four-entry update queue,
  eight-entry RAS, and direct-target adder.
- **Frontend/core control:** PC/redirect control, packet construction, and
  top-level frontend glue.
- **Decode:** three complete RV64 decode lanes.
- **Trap/redirect vector:** trap, return, restart, and reset-target selection.
- **AXI wrapper/glue:** fixed top-level 3P AXI boundary and tie-offs. It maps to
  no cells after optimization.

## Configuration and exclusions

This is the current real-branch, high-performance 3P profile:

- RV64IM+A, EX0/EX1/MEM, 256-bit AXI;
- retirement depth 8 and dispatch depth 6;
- full forwarding, relaxed WAW, and relaxed tagged hazards;
- normal branch issue/resolution (`FREE_BRANCHES=0`);
- posted stores enabled;
- 32-entry, 3-bit bimodal predictor, four-entry update queue, RAS depth 8;
- issue-window experiment and trace hardware disabled;
- cache, scalar FPU, vector unit, SoC peripherals, and testbench RAM excluded.

Inferred arrays, including the GPR, TLBs, predictor, and queues, map to flops
and logic. No SRAM or register-file macros are used.

## Cortex-A53 comparison

There is no honest numeric cacheless Cortex-A53 ratio from this run. The
processes, physical stages, and feature sets do not match.

The [Arm Cortex-A53 product description](https://www.arm.com/products/silicon-ip-cpu/cortex-a/cortex-a53)
includes private L1 instruction/data caches and NEON/FPU. A published
[TSMC 28HPM physical implementation](https://gtcad.gatech.edu/www/papers/9420273.pdf)
uses one A53 core, 32 KiB I-cache, 32 KiB D-cache, and 1 MiB L2; the paper says
memory occupies more than half of its 2-D silicon area. It does not publish an
absolute cacheless A53 logic-only area that can be normalized against this
Sky130 cell sum.

Consequently, **2.808674 mm^2 is a measured OpenRV64 pre-layout cell sum, not
evidence that the logic is larger or smaller than an A53**. A defensible ratio
requires both cores mapped to the same process, cell library, memory macros,
PVT corner, timing target, and physical flow. The current comparison is only
qualitative: OpenRV64 omits the A53 caches and NEON/FPU, while implementing a
wider three-issue backend and 256-bit memory interface.

## Method and limits

The flow flattens logic inside functional reporting boundaries, then maps each
partition with the normal constrained ABC script. The summarizer walks the
retained instance tree and subtracts recursive child area from each parent.

The partitioned total is conservative because ABC cannot optimize across the
retained reporting boundaries. The optional flat cross-check did not produce a
valid total: its saved result still contains **1,045,302 unmapped `$lut` cells**.
The apparent 704,408 um^2 flop-only value is invalid and must not be used.

This report has no placement, routing, extracted interconnect, setup/hold
analysis, clock tree, power grid, taps/fillers, physical-only buffering, macro
halos, or utilization margin. It is a logical-area composition and a
pre-layout standard-cell estimate, not die area.
