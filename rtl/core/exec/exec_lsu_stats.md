# `openrv64_exec_lsu` FPGA synthesis history

Generated build records are stored newest first. Counts from different
files are not automatically additive because module boundaries may overlap.
Do not treat structural depth as physical timing.

<!-- module-statistics-entries: newest-first -->

<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_exec_lsu -->
## 2026-08-27T00:08:20+00:00 — `fpga-xc7k480t-module-stats-20260827T000819Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_exec_lsu` |
| RTL source | `rtl/core/exec/exec_lsu.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `9d5bc3147455f07928608a1bb90d1e31c0c43269` |
| Worktree | `dirty` |
| RTL input SHA-256 | `fd993cb60a3550542a89a7ff7b98a36ed968052d25f867662b60a02155a1e771` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 165.4 s |
| Build log | `build/fpga/xc7k480t/module-stats/exec_lsu/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `CACHEABLE_BASE` | `64'h0000000080000000` |
| `CACHEABLE_SIZE` | `64'h00ffffff80000000` |
| `COHERENT_ATOMICS` | 0 |
| `ENABLE_ZICCLSM` | 1 |
| `LOAD_QUEUE_DEPTH` | 4 |
| `LSU_TAG_WIDTH` | 3 |
| `RETIRE_SLOT_WIDTH` | 5 |
| `STORE_QUEUE_DEPTH` | 4 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 12,792 |
| LUT primitives | 16,899 |
| Flip-flops | 6,261 |
| Latches | 0 |
| CARRY4 | 1,071 |
| MUXF7/8/9 | 1,402 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 32,713 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 1,071 |
| `FDCE` | 6,258 |
| `FDPE` | 3 |
| `INV` | 7,080 |
| `LUT1` | 56 |
| `LUT2` | 4,231 |
| `LUT3` | 1,867 |
| `LUT4` | 2,005 |
| `LUT5` | 2,613 |
| `LUT6` | 6,127 |
| `MUXF7` | 1,063 |
| `MUXF8` | 339 |

### Timing and diagnostics

- Longest mapped topological path: **571 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **58010**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_exec_lsu -->
