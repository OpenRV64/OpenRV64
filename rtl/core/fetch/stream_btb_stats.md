# `openrv64_fetch_stream_btb` FPGA synthesis history

Generated build records are stored newest first. Counts from different
files are not automatically additive because module boundaries may overlap.
Do not treat structural depth as physical timing.

<!-- module-statistics-entries: newest-first -->

<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-stream-btb-20260905T082402Z:openrv64_fetch_stream_btb -->
## 2026-09-05T08:24:03+00:00 — `fpga-xc7k480t-module-stats-stream-btb-20260905T082402Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_fetch_stream_btb` |
| RTL source | `rtl/core/fetch/stream_btb.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `7f5b8a8a2c25b8bff388fe0b8c38d8da2094c9f0` |
| Worktree | `dirty` |
| RTL input SHA-256 | `b1235ee442393e7939c122c7587d45542e9b31826610bf83a07e466f960ff1af` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 13.6 s |
| Build log | `build/fpga/xc7k480t/module-stats-stream-btb/fetch_stream_btb/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `ENTRIES` | 256 |
| `REQUEST_ID_WIDTH` | 32 |
| `SETS` | 128 |
| `SET_INDEX_WIDTH` | 7 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 1,592 |
| LUT primitives | 2,101 |
| Flip-flops | 806 |
| Latches | 0 |
| CARRY4 | 34 |
| MUXF7/8/9 | 234 |
| DSP48E1 | 0 |
| RAMB36E1 | 8 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 3,802 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 34 |
| `FDCE` | 610 |
| `FDPE` | 1 |
| `FDRE` | 195 |
| `INV` | 619 |
| `LUT1` | 5 |
| `LUT2` | 504 |
| `LUT3` | 383 |
| `LUT4` | 674 |
| `LUT5` | 142 |
| `LUT6` | 393 |
| `MUXF7` | 208 |
| `MUXF8` | 26 |
| `RAMB36E1` | 8 |

### Timing and diagnostics

- Longest mapped topological path: **58 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **1657**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-stream-btb-20260905T082402Z:openrv64_fetch_stream_btb -->
