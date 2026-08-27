# `openrv64_retire_3p` FPGA synthesis history

Generated build records are stored newest first. Counts from different
files are not automatically additive because module boundaries may overlap.
Do not treat structural depth as physical timing.

<!-- module-statistics-entries: newest-first -->

<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T032508Z:openrv64_retire_3p -->
## 2026-08-27T03:25:09+00:00 — `fpga-xc7k480t-module-stats-20260827T032508Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_retire_3p` |
| RTL source | `rtl/core/retire/retire_3p.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `6a96ae8ecb366b9370e1da7e2b17509400dd7339` |
| Worktree | `dirty` |
| RTL input SHA-256 | `7e7e1bcc8e65e2790e484fa9d55be0b040ac9c296d1a750918db6b8ae76ba23f` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 12.8 s |
| Build log | `build/fpga/xc7k480t/module-stats/retire_3p/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `ENABLE_EXTENSION` | 0 |
| `META_WIDTH` | 130 |
| `PHYS_REG_ADDR_WIDTH` | 5 |
| `PHYS_REG_COUNT` | 31 |
| `RESULT_WIDTH` | 281 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 497 |
| LUT primitives | 517 |
| Flip-flops | 0 |
| Latches | 0 |
| CARRY4 | 0 |
| MUXF7/8/9 | 12 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 529 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `LUT1` | 1 |
| `LUT2` | 23 |
| `LUT3` | 6 |
| `LUT4` | 10 |
| `LUT5` | 385 |
| `LUT6` | 92 |
| `MUXF7` | 9 |
| `MUXF8` | 3 |

### Timing and diagnostics

- Longest mapped topological path: **7 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **0**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T032508Z:openrv64_retire_3p -->
<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_retire_3p -->
## 2026-08-27T00:08:20+00:00 — `fpga-xc7k480t-module-stats-20260827T000819Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_retire_3p` |
| RTL source | `rtl/core/retire/retire_3p.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `9d5bc3147455f07928608a1bb90d1e31c0c43269` |
| Worktree | `dirty` |
| RTL input SHA-256 | `fd993cb60a3550542a89a7ff7b98a36ed968052d25f867662b60a02155a1e771` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 11.9 s |
| Build log | `build/fpga/xc7k480t/module-stats/retire_3p/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `ENABLE_EXTENSION` | 0 |
| `META_WIDTH` | 130 |
| `PHYS_REG_ADDR_WIDTH` | 5 |
| `PHYS_REG_COUNT` | 31 |
| `RESULT_WIDTH` | 281 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 497 |
| LUT primitives | 517 |
| Flip-flops | 0 |
| Latches | 0 |
| CARRY4 | 0 |
| MUXF7/8/9 | 12 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 529 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `LUT1` | 1 |
| `LUT2` | 23 |
| `LUT3` | 6 |
| `LUT4` | 10 |
| `LUT5` | 385 |
| `LUT6` | 92 |
| `MUXF7` | 9 |
| `MUXF8` | 3 |

### Timing and diagnostics

- Longest mapped topological path: **7 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **0**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_retire_3p -->
