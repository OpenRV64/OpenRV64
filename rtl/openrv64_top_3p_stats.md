# `openrv64_top_3p` FPGA synthesis history

Build records are stored newest first.  Resource counts below are synthesis
mapping results, not placement, routing, or bitstream evidence.

<!-- module-statistics-entries: newest-first -->

<!-- module-statistics-entry:start id=fpga-xc7k480t-3p-tomasulo32-cacheless-area-20260903T005310Z:openrv64_top_3p -->
## 2026-09-03T01:22:20+00:00 — `fpga-xc7k480t-3p-tomasulo32-cacheless-area-20260903T005310Z`

| Build field | Value |
|---|---|
| Status | **mapped; managed validation passed** |
| Module | `openrv64_top_3p` |
| RTL source | `rtl/openrv64_top_3p.v` |
| Profile | 32-entry retirement, 32-entry Tomasulo scheduler, 63-entry physical register file, L1 arrays disabled |
| Synthesis boundary | Out-of-context whole 3P core; hierarchy preserved with `flatten_hierarchy=none` |
| Target used | `xc7a100tfgg484-2` native Vivado 7-series proxy; installed Vivado lacks the requested `xc7k480tffg1156-2` device files |
| Git commit | `a8e83d84bd2c98c9307c6ed11f2bec255641d61c` |
| Worktree | `dirty` |
| Top RTL SHA-256 | `a92cfd38934574e98247668afe799eb3c75ba4139c57fcec6dce870c7c57f523` |
| Tool | Vivado 2026.1, build 6511674 |
| Synthesis mode | `-no_timing_driven`; 50 MHz constraint retained for diagnostics |
| Elapsed | 29m 10s managed run; `synth_design` 26m 49s |
| Build log | `run/log/fpga-xc7k480t-3p-tomasulo32-cacheless-area-20260903T005310Z/build.log` |
| Reports | `build/fpga/xc7k480t/core-3p-tomasulo32-cacheless-vivado-area-xc7a100t-proxy-v3/` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `RETIRE_DEPTH` | 32 |
| `ISSUE_WINDOW_DEPTH` | 32 |
| `PHYS_REG_COUNT` | 63 |
| `RENAME_MODE` | 1 |
| `BANKED_GPR` | 1 |
| `FPGA_GPR_LUTRAM` | 1 |
| `ENABLE_ISSUE_WINDOW` | 1 |
| `ENABLE_SPECULATION_WINDOW` | 1 |
| `BRANCH_COMPLETION_FORWARD_MASK` | 0 |
| `RELAX_WAW` | 1 |
| `ENABLE_L1I` | 0 |
| `ENABLE_L1D` | 0 |
| `L2_TLB_ENTRIES` | 256 |
| `L2_TLB_WAYS` | 4 |
| `BP_TYPE` | 8 |

### Resources

| Metric | Count | Nominal XC7K480T share |
|---|---:|---:|
| Slice LUTs | 295,319 | 98.90% of 298,600 |
| LUT as logic | 293,395 | 98.26% of 298,600 |
| LUT as memory | 1,924 | 0.64% of 298,600 |
| Slice registers | 86,280 | 14.45% of 597,200 |
| RAMB36 | 8 | 0.84% of 955 |
| DSP48E1 | 16 | 0.83% of 1,920 |

The K480T shares are capacity comparisons, not results from a K480T device
model.  Only 3,281 nominal LUTs remain before placement; this is not credible
routing headroom.

### Hierarchical LUT attribution

| Instance boundary | LUTs | Whole-core share |
|---|---:|---:|
| Dispatch plus rename | 138,250 | 46.81% |
| Tomasulo scheduler | 103,334 | 34.99% |
| Tomasulo rename | 34,901 | 11.82% |
| Retirement records | 53,983 | 18.28% |
| MTL/core bus | 41,001 | 13.88% |
| Execution | 17,167 | 5.81% |
| Fetch | 13,539 | 4.58% |
| Branch predictor | 10,413 | 3.53% |
| GPR/PRF | 2,828 | 0.96% |

The checkpoint-only run
`fpga-xc7k480t-dispatch-rename-breakdown-20260903T013022Z` attributed
primitive cell names below the two dispatch boundaries.  These are raw LUT
primitive counts; they exceed `report_utilization` LUT sites because compatible
LUT functions can share a physical LUT.

| Scheduler cone | Raw LUT primitives | Scheduler share |
|---|---:|---:|
| Issued payload read mux (`pipe_payload_o`) | 41,338 | 37.07% |
| Payload update/storage input (`payload_q`) | 26,317 | 23.60% |
| Per-pipe candidate generation | 21,269 | 19.07% |
| Candidate age/rank output | 7,062 | 6.33% |
| Candidate instruction-ID output | 6,814 | 6.11% |
| Other dependency, metadata, and control | 8,704 | 7.81% |

The scheduler contains 111,504 raw LUT primitives and 12,090 FFs.  `payload_q`
accounts for 9,737 FFs (80.54%).  Its write/update and issued-read mux cones
together account for 67,655 raw LUTs (60.67%); candidate generation, age, and
ID selection account for another 35,145 (31.52%).

| Rename cone | Raw LUT primitives | Rename share |
|---|---:|---:|
| Checkpoint RAT | 13,164 | 35.12% |
| Checkpoint post-allocation bitmap | 8,405 | 22.43% |
| Current source-map readout | 3,473 | 9.27% |
| Current RAT update | 3,370 | 8.99% |
| Current free bitmap/allocation | 3,037 | 8.10% |
| Checkpoint free bitmap | 2,585 | 6.90% |
| Destination allocation/readout | 2,015 | 5.38% |
| Checkpoint cursor/live state | 539 | 1.44% |
| RRAT, readiness, and remaining control | 892 | 2.38% |

Rename contains 37,480 raw LUT primitives and 10,928 FFs.  Full checkpoint
snapshots consume 24,693 raw LUTs (65.88%) and 10,400 FFs (95.17%).

The GPR banks inferred 352 LUTRAMs.  The scheduler and retirement records
inferred none.  Vivado dissolved the 8,992-bit retirement `result_q` into
registers because its multiwrite/asynchronous access contract does not match a
supported RAM template.  Fetch also inferred no RAM.  Although both L1 cache
arrays were disabled, their wrappers remain: L1D used 20,185 LUTs and eight
RAMB36 tag-overlay blocks, and L1I used 5,116 LUTs.  The L2 TLB used 3,450 LUTs,
including 704 LUTRAMs; it is not an L2 data cache.

### Timing and diagnostics

- Physical timing and Fmax were not measured.
- The synthesis timing report found 79 combinational loops and one latch loop.
  Its `-437.598 ns` WNS is therefore not a usable timing estimate.
- Vivado reported zero synthesis errors, one post-synthesis critical warning
  for a malformed `keep` attribute, and 7,030 synthesis warnings.

<!-- module-statistics-entry:end id=fpga-xc7k480t-3p-tomasulo32-cacheless-area-20260903T005310Z:openrv64_top_3p -->
