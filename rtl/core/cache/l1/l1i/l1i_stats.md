# `openrv64_l1i_icx` FPGA synthesis history

Generated build records are stored newest first. Counts from different
files are not automatically additive because module boundaries may overlap.
Do not treat structural depth as physical timing.

<!-- module-statistics-entries: newest-first -->

<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_l1i_icx -->
## 2026-08-27T00:08:20+00:00 — `fpga-xc7k480t-module-stats-20260827T000819Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_l1i_icx` |
| RTL source | `rtl/core/cache/l1/l1i/l1i.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `9d5bc3147455f07928608a1bb90d1e31c0c43269` |
| Worktree | `dirty` |
| RTL input SHA-256 | `fd993cb60a3550542a89a7ff7b98a36ed968052d25f867662b60a02155a1e771` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 162.8 s |
| Build log | `build/fpga/xc7k480t/module-stats/l1i_icx/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `ADDR_WIDTH` | 64 |
| `CACHE_BYTES` | 16384 |
| `DEMAND_DEPTH` | 8 |
| `DEMAND_MSHRS` | 4 |
| `DIRTY_TIMESTAMP_WIDTH` | 8 |
| `ENABLE` | 1 |
| `FILL_BUFFER_LINES` | 8 |
| `HART_ID` | 0 |
| `PREFETCH_SLOTS` | 8 |
| `REQ_TAG_WIDTH` | 2 |
| `WAYS` | 4 |
| `WRITEBACK_TIMEOUT_CYCLES` | 128 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 23,995 |
| LUT primitives | 27,347 |
| Flip-flops | 11,094 |
| Latches | 0 |
| CARRY4 | 19 |
| MUXF7/8/9 | 1,218 |
| DSP48E1 | 0 |
| RAMB36E1 | 4 |
| RAMB18E1 | 60 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 50,837 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 19 |
| `FDCE` | 11,060 |
| `FDPE` | 34 |
| `INV` | 11,095 |
| `LUT1` | 7 |
| `LUT2` | 3,345 |
| `LUT3` | 3,020 |
| `LUT4` | 3,411 |
| `LUT5` | 7,658 |
| `LUT6` | 9,906 |
| `MUXF7` | 1,062 |
| `MUXF8` | 156 |
| `RAMB18E1` | 60 |
| `RAMB36E1` | 4 |

### Timing and diagnostics

- Longest mapped topological path: **1463 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **1430363**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_l1i_icx -->
