# `openrv64_exec_bp` FPGA synthesis history

Generated build records are stored newest first. Counts from different
files are not automatically additive because module boundaries may overlap.
Do not treat structural depth as physical timing.

<!-- module-statistics-entries: newest-first -->

<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T032508Z:openrv64_exec_bp -->
## 2026-08-27T03:25:09+00:00 — `fpga-xc7k480t-module-stats-20260827T032508Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_exec_bp` |
| RTL source | `rtl/core/exec/bp/bp.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `6a96ae8ecb366b9370e1da7e2b17509400dd7339` |
| Worktree | `dirty` |
| RTL input SHA-256 | `7e7e1bcc8e65e2790e484fa9d55be0b040ac9c296d1a750918db6b8ae76ba23f` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 58.4 s |
| Build log | `build/fpga/xc7k480t/module-stats/exec_bp/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `BIMODAL_COUNTER_BITS` | 3 |
| `BIMODAL_ENTRIES` | 32 |
| `BIMODAL_UPDATE_DEPTH` | 4 |
| `BP_TYPE` | 8 |
| `BTB_ENTRIES` | 256 |
| `BTB_TAG_BITS` | 16 |
| `ENABLE_RAS` | 1 |
| `ENABLE_TAGGED_RESOLUTION` | 1 |
| `GSHARE_COUNTER_BITS` | 3 |
| `GSHARE_ENTRIES` | 256 |
| `INFLIGHT_DEPTH` | 16 |
| `RAS_DEPTH` | 8 |
| `TOURNAMENT_CHOOSER_COUNTER_BITS` | 2 |
| `TOURNAMENT_CHOOSER_ENTRIES` | 512 |
| `TOURNAMENT_GLOBAL_COUNTER_BITS` | 3 |
| `TOURNAMENT_GLOBAL_ENTRIES` | 2048 |
| `TOURNAMENT_GLOBAL_HISTORY_BITS` | 11 |
| `TOURNAMENT_LOCAL_COUNTER_BITS` | 3 |
| `TOURNAMENT_LOCAL_HISTORY_BITS` | 10 |
| `TOURNAMENT_LOCAL_HISTORY_ENTRIES` | 512 |
| `TOURNAMENT_LOCAL_PHT_ENTRIES` | 1024 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 11,308 |
| LUT primitives | 14,758 |
| Flip-flops | 6,864 |
| Latches | 0 |
| CARRY4 | 117 |
| MUXF7/8/9 | 1,420 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 224 |
| SRL primitives | 0 |
| Total mapped cells | 28,548 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 117 |
| `FDCE` | 5,120 |
| `FDRE` | 1,744 |
| `INV` | 5,165 |
| `LUT1` | 94 |
| `LUT2` | 4,075 |
| `LUT3` | 1,143 |
| `LUT4` | 1,494 |
| `LUT5` | 4,552 |
| `LUT6` | 3,400 |
| `MUXF7` | 1,310 |
| `MUXF8` | 110 |
| `RAM128X1D` | 80 |
| `RAM64M` | 144 |

### Timing and diagnostics

- Longest mapped topological path: **555 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **794597**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T032508Z:openrv64_exec_bp -->
<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_exec_bp -->
## 2026-08-27T00:08:20+00:00 — `fpga-xc7k480t-module-stats-20260827T000819Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_exec_bp` |
| RTL source | `rtl/core/exec/bp/bp.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `9d5bc3147455f07928608a1bb90d1e31c0c43269` |
| Worktree | `dirty` |
| RTL input SHA-256 | `fd993cb60a3550542a89a7ff7b98a36ed968052d25f867662b60a02155a1e771` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 53.2 s |
| Build log | `build/fpga/xc7k480t/module-stats/exec_bp/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `BIMODAL_COUNTER_BITS` | 3 |
| `BIMODAL_ENTRIES` | 32 |
| `BIMODAL_UPDATE_DEPTH` | 4 |
| `BP_TYPE` | 8 |
| `BTB_ENTRIES` | 256 |
| `BTB_TAG_BITS` | 16 |
| `ENABLE_RAS` | 1 |
| `ENABLE_TAGGED_RESOLUTION` | 1 |
| `GSHARE_COUNTER_BITS` | 3 |
| `GSHARE_ENTRIES` | 256 |
| `INFLIGHT_DEPTH` | 16 |
| `RAS_DEPTH` | 8 |
| `TOURNAMENT_CHOOSER_COUNTER_BITS` | 2 |
| `TOURNAMENT_CHOOSER_ENTRIES` | 512 |
| `TOURNAMENT_GLOBAL_COUNTER_BITS` | 3 |
| `TOURNAMENT_GLOBAL_ENTRIES` | 2048 |
| `TOURNAMENT_GLOBAL_HISTORY_BITS` | 11 |
| `TOURNAMENT_LOCAL_COUNTER_BITS` | 3 |
| `TOURNAMENT_LOCAL_HISTORY_BITS` | 10 |
| `TOURNAMENT_LOCAL_HISTORY_ENTRIES` | 512 |
| `TOURNAMENT_LOCAL_PHT_ENTRIES` | 1024 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 11,308 |
| LUT primitives | 14,758 |
| Flip-flops | 6,864 |
| Latches | 0 |
| CARRY4 | 117 |
| MUXF7/8/9 | 1,420 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 224 |
| SRL primitives | 0 |
| Total mapped cells | 28,548 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 117 |
| `FDCE` | 5,120 |
| `FDRE` | 1,744 |
| `INV` | 5,165 |
| `LUT1` | 94 |
| `LUT2` | 4,075 |
| `LUT3` | 1,143 |
| `LUT4` | 1,494 |
| `LUT5` | 4,552 |
| `LUT6` | 3,400 |
| `MUXF7` | 1,310 |
| `MUXF8` | 110 |
| `RAM128X1D` | 80 |
| `RAM64M` | 144 |

### Timing and diagnostics

- Longest mapped topological path: **555 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **794597**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_exec_bp -->
