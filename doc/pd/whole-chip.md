# Whole-chip area status: Nangate45

Last updated: 2026-08-05

## Executive result

The current Nangate45 results are **not whole-chip area results**.  They are
pre-layout standard-cell maps of one 4PF core tile with L1I and L1D disabled.
The mapped logic spans **1.357 mm² to 2.363 mm²**, depending mainly on whether
RV64F/RV64D is present and whether the optional registered issue selector is
used.

At an assumed 60--75% standard-cell placement utilization, that corresponds
to a **1.81--3.94 mm² placement-region envelope for the mapped logic only**.
This is not a die-area estimate.  SRAM macros, clock-tree and hold cells,
routing, power grid, DFT, pads, and SoC peripherals are not included.

The strongest defensible statement for a default cacheful F/D tile is
therefore:

> The cacheless logic reference is 2.363 mm² of Nangate45 mapped cells, or
> about 3.375 mm² at a nominal 70% cell utilization.  A cacheful physical
> tile must additionally accommodate SRAM, cache-control deltas, and physical
> integration, none of which currently has a numerical area.

The total cacheful tile area is not yet known.

## What was synthesized

The measured design is [`openrv64_top_4pf`](../../rtl/core/exec/fpu/top_4pf.v),
elaborated through the 4PF core, translation and protection machinery, and the
CCX-facing memory boundary.  It is a core tile, not an SoC top.

The matched direct-selector runs use:

| Setting | Value |
| --- | --- |
| Process library | Nangate Open Cell Library, typical, 25 C, 1.1 V |
| Yosys | 0.66 (`86f2ddebc-dirty`) |
| Source base | `c9c830eb48074afe62612abefc9e4bc2f9467878`, with uncommitted 4PF/F/D work |
| Issue/retirement depth | 16 |
| Issue/speculation window | Enabled |
| Issue selector | Direct (`REGISTER_ISSUE_SELECT=0`) |
| F/D multiplier | Pipelined |
| L1I / L1D | Disabled |
| Trace | Disabled |
| L2 TLB | 256 entries, four ways |
| PTW PTE cache | 64 entries |

The library is pinned to OpenROAD Flow Scripts commit
`f255c15b3dd4362a704b6af9f617b4091bdd4e6a`.  The Liberty SHA-256 is
`8d540a4d4cf6d09d27c87ad067857a9c0c2eeb023ab7a56e058cd3113db4e9b1`.
The flow and its limitations are recorded in the
[`Nangate45 README`](../../synth/nangate45/README.md).

## Direct-selector mapped results

These are the current source-matched output summaries.

| Configuration | Cell area | Sequential area | Library cells | Worst retained-partition delay |
| --- | ---: | ---: | ---: | ---: |
| Integer configuration, no F/D | 1.371544 mm² | 0.326508 mm² | 823,743 | 7,668,951 ps |
| Integer + RV64F/RV64D | 2.362814 mm² | 0.410181 mm² | 1,555,722 | 23,144,082 ps |

The source reports are
[`nofd/summary.json`](../../sim/yosys/core-4pf-nangate45/nofd/summary.json) and
[`fd/summary.json`](../../sim/yosys/core-4pf-nangate45/fd/summary.json).

The F/D-enabled configuration adds:

- 0.991270 mm² of mapped area;
- 83,672.960 um² of sequential area; and
- 731,979 mapped library cells.

That makes the F/D configuration 72.27% larger than the no-F/D configuration.
Conversely, the F/D configuration increment is 41.95% of the final F/D total.
This delta is not a pure arithmetic-unit measurement: it includes the FPR,
F/D execution and control logic, and small configuration-dependent changes in
the surrounding window and retirement logic.

## Where the F/D configuration area goes

The following is a non-overlapping accounting decomposition of the current
2.362814 mm² F/D result.  It uses the no-F/D design as the base and assigns the
complete matched F/D delta to one category.  This avoids double-counting
retained hierarchy, but it is not a floorplan.

| Functional category | Area | Share of F/D total |
| --- | ---: | ---: |
| F/D configuration increment | 0.991270 mm² | 41.95% |
| Memory/translation fabric | 0.398924 mm² | 16.88% |
| Issue/retirement window | 0.244168 mm² | 10.33% |
| Retirement records, queue, and commit | 0.212098 mm² | 8.98% |
| Fetch and branch prediction | 0.170620 mm² | 7.22% |
| Base backend/decode/LSU integration | 0.144493 mm² | 6.12% |
| CSR and PMP state/logic | 0.102880 mm² | 4.35% |
| Integer register file | 0.065592 mm² | 2.78% |
| Integer EX0 and EX1 pipes | 0.031014 mm² | 1.31% |
| Prefix arithmetic and exception vector | 0.001755 mm² | 0.07% |
| **Total** | **2.362814 mm²** | **100.00%** |

The 0.398924 mm² memory/translation category includes the CCX/L1 interface,
PTW, and TLB logic.  The nested mapped accounting is:

| Memory/translation component | Area |
| --- | ---: |
| CCX/L1 interface and residual bus logic | 0.307753 mm² |
| PTW | 0.063157 mm² |
| L2 TLB, including leaf TLB | 0.028014 mm² |
| **Total** | **0.398924 mm²** |

L1 cache data arrays are absent from this result.  Some disabled-controller,
overlay, and interface logic remains because the cache wrappers still form the
core's external memory boundary.

## Issue-selector area option

The optional registered selector is a measured area experiment, not the
default.  Its detailed functional and timing status is in
[`window-area.md`](window-area.md).

| Configuration | Direct selector | Registered selector | Saving |
| --- | ---: | ---: | ---: |
| No F/D | 1.371544 mm² | 1.357449 mm² | 0.014095 mm² (1.03%) |
| F/D | 2.362814 mm² | 2.348723 mm² | 0.014091 mm² (0.60%) |

The registered selector does not improve the reported worst-partition delay.
It also has a known consecutive-memory scheduling bubble and made the complete
DAXPY test 8.58% slower, although the long-unroll kernels were effectively
unchanged.  It is therefore valid as the minimum-area measured point, but it
is not yet the recommended normal configuration.

## Memory area omitted from the cell totals

The synthesis checkpoint preserves memories as `$mem_v2` cells.  Nangate45
does not provide matching SRAM macro areas, so these bits are not priced in
the standard-cell totals.

| Preserved memory | No F/D | F/D |
| --- | ---: | ---: |
| L2 TLB banks | 33,536 bits | 33,536 bits |
| Tournament predictor and BTB | 35,840 bits | 35,840 bits |
| Disabled-L1D tag overlay | 4,608 bits | 4,608 bits |
| Atomic decode ROMs | 64 bits | 64 bits |
| F/D decode ROMs | 0 bits | 640 bits |
| **Unpriced preserved total** | **74,048 bits** | **74,688 bits** |

These totals are only the memories preserved by this particular synthesis
flow.  They do not include the default L1 data capacities because both L1s
were disabled for the measured runs.

The default architectural tile enables a 16 KiB, four-way L1I and a 16 KiB,
four-way L1D.  That is 32 KiB of raw data capacity before tags, coherence and
valid/dirty metadata, replacement state, fill buffers, MSHRs, store buffers,
and prefetch state.  No Nangate45 SRAM compiler or source-matched L1-enabled
logic map has yet been applied, so assigning an area to those structures would
be fabrication rather than estimation.

## Placement-region envelope

Dividing mapped standard-cell area by an assumed utilization gives a rough
logic placement-region requirement.  It does not account for macro halos,
congestion, CTS, power delivery, or die-edge overhead.

| Mapped configuration | Cell area | 75% utilization | 70% utilization | 60% utilization |
| --- | ---: | ---: | ---: | ---: |
| Minimum, no F/D, registered selector | 1.357 mm² | 1.810 mm² | 1.939 mm² | 2.262 mm² |
| No F/D, direct selector | 1.372 mm² | 1.829 mm² | 1.959 mm² | 2.286 mm² |
| F/D, registered selector | 2.349 mm² | 3.132 mm² | 3.355 mm² | 3.915 mm² |
| F/D, direct selector | 2.363 mm² | 3.150 mm² | 3.375 mm² | 3.938 mm² |

Seventy percent is shown as a convenient midpoint, not as a demonstrated
achievable utilization.  Only place-and-route can establish that.

## Timing status

The timing column is the maximum unbuffered ABC `stime` delay inside any one
retained reporting partition.  The mapping recipe omits buffer insertion,
upsizing, and downsizing.  It also omits inter-partition paths, placement,
routing, clock uncertainty, and macro timing.

Consequently:

- the values must not be inverted into clock-frequency claims;
- the no-F/D worst retained partition is the CCX bus;
- the F/D worst retained partition is flattened 4PF top logic; and
- registering the integer/LSU issue selection did not change either maximum.

The current numbers are useful for relative structural comparisons.  They are
not evidence of timing closure.

## What a literal whole chip still requires

The present `openrv64_top_4pf` boundary does not include a complete platform.
A whole-chip estimate needs, at minimum:

- a source-matched L1-enabled synthesis;
- selected SRAM macro implementations and macro timing models;
- placement and routing with CTS, hold repair, and realistic congestion;
- power grid, tap/endcap/filler cells, and DFT overhead;
- pad ring or bump plan, level shifters if required, reset and clock sources;
- interrupt controller, timer, boot ROM, debug, and chosen peripherals; and
- any L2 cache, coherent fabric, memory controller, or additional harts.

Until those are selected, `whole-chip area` is an unknown rather than the sum
of the mapped core-cell area and an arbitrary margin.

## Final configuration summary

"Maximal" below means the current default feature-complete single-tile target,
not every optional debug, trace, coherence, or multicore knob enabled at once.

| Class | Configuration | Current numerical statement | Status |
| --- | --- | --- | --- |
| **Minimal measured** | No F/D, registered selector, L1 arrays off | 1.357 mm² cells; 1.939 mm² nominal 70% region; plus 74,048 unpriced bits | Smallest result, but selector has a memory bubble and is not the default |
| **Minimal normal** | No F/D, direct selector, L1 arrays off | 1.372 mm² cells; 1.959 mm² nominal 70% region; plus 74,048 unpriced bits | Recommended integer-only mapped baseline |
| **Area-biased F/D** | F/D on, registered selector, L1 arrays off | 2.349 mm² cells; 3.355 mm² nominal 70% region; plus 74,688 unpriced bits | Measured option, not performance-default |
| **Typical / maximum measured** | F/D on, pipelined multiply, direct selector, L1 arrays off | 2.363 mm² cells; 3.375 mm² nominal 70% region; plus 74,688 unpriced bits | Current performance-oriented mapped baseline |
| **Maximal current tile target** | Typical F/D configuration plus 16 KiB L1I and 16 KiB L1D | 2.363 mm² cacheless logic reference; cacheful total unknown | Architecturally configured, not yet measured with SRAM macros |
| **Literal whole chip** | Tile plus physical integration and selected platform | Unknown | No defensible Nangate45 total yet |

Thus the current usable range is **1.357--2.363 mm² of mapped standard-cell
area**.  The typical F/D logic point is **2.363 mm²**, and the maximal
cacheful tile and whole-chip values remain unmeasured.

## Reproduction

The library is fetched as a pinned external dependency:

```sh
make nangate45-liberty
make -j2 yosys-resources-core-4pf-nangate45
```

The underlying entry point is
[`report-core-4pf.sh`](../../synth/nangate45/report-core-4pf.sh).  The optional
registered-selector probe can be reproduced into a separate output directory:

```sh
REGISTER_ISSUE_SELECT=1 OUT_DIR=/tmp/openrv64-nangate45-registered \
    synth/nangate45/report-core-4pf.sh nofd
REGISTER_ISSUE_SELECT=1 OUT_DIR=/tmp/openrv64-nangate45-registered \
    synth/nangate45/report-core-4pf.sh fd
```
