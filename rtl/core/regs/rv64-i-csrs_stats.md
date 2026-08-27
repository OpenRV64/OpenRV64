# `openrv64_rv64i_csrs` FPGA synthesis history

Generated build records are stored newest first. Counts from different
files are not automatically additive because module boundaries may overlap.
Do not treat structural depth as physical timing.

<!-- module-statistics-entries: newest-first -->

<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_rv64i_csrs -->
## 2026-08-27T00:08:20+00:00 — `fpga-xc7k480t-module-stats-20260827T000819Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_rv64i_csrs` |
| RTL source | `rtl/core/regs/rv64-i-csrs.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `9d5bc3147455f07928608a1bb90d1e31c0c43269` |
| Worktree | `dirty` |
| RTL input SHA-256 | `fd993cb60a3550542a89a7ff7b98a36ed968052d25f867662b60a02155a1e771` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 29.1 s |
| Build log | `build/fpga/xc7k480t/module-stats/rv64i_csrs/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `ENABLE_EXTENSION` | 0 |
| `ENABLE_RV64A` | 1 |
| `ENABLE_RV64M` | 1 |
| `HART_ID` | `64'h0000000000000000` |
| `HPM_COUNTERS` | 8 |
| `PMP_ACTIVE_ENTRIES` | 8 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 4,090 |
| LUT primitives | 4,864 |
| Flip-flops | 2,879 |
| Latches | 0 |
| CARRY4 | 321 |
| MUXF7/8/9 | 578 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 11,527 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 321 |
| `FDCE` | 2,866 |
| `FDPE` | 13 |
| `INV` | 2,885 |
| `LUT1` | 110 |
| `LUT2` | 664 |
| `LUT3` | 1,169 |
| `LUT4` | 473 |
| `LUT5` | 630 |
| `LUT6` | 1,818 |
| `MUXF7` | 443 |
| `MUXF8` | 135 |

### Timing and diagnostics

- Longest mapped topological path: **1432 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **229811**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_rv64i_csrs -->
