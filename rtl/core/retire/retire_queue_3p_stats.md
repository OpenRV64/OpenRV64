# `openrv64_retire_queue_3p` FPGA synthesis history

Generated build records are stored newest first. Counts from different
files are not automatically additive because module boundaries may overlap.
Do not treat structural depth as physical timing.

<!-- module-statistics-entries: newest-first -->

<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T032508Z:openrv64_retire_queue_3p -->
## 2026-08-27T03:25:09+00:00 — `fpga-xc7k480t-module-stats-20260827T032508Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_retire_queue_3p` |
| RTL source | `rtl/core/retire/retire_queue_3p.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `6a96ae8ecb366b9370e1da7e2b17509400dd7339` |
| Worktree | `dirty` |
| RTL input SHA-256 | `7e7e1bcc8e65e2790e484fa9d55be0b040ac9c296d1a750918db6b8ae76ba23f` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 18.0 s |
| Build log | `build/fpga/xc7k480t/module-stats/retire_queue_3p/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `COUNT_WIDTH` | 6 |
| `DEPTH` | 32 |
| `ENABLE_EXTENSION_COMPLETION` | 0 |
| `ID_WIDTH` | 10 |
| `INDEX_WIDTH` | 5 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 2,410 |
| LUT primitives | 3,133 |
| Flip-flops | 410 |
| Latches | 0 |
| CARRY4 | 136 |
| MUXF7/8/9 | 321 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 4,108 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 136 |
| `FDCE` | 90 |
| `FDRE` | 320 |
| `INV` | 108 |
| `LUT1` | 49 |
| `LUT2` | 694 |
| `LUT3` | 405 |
| `LUT4` | 249 |
| `LUT5` | 554 |
| `LUT6` | 1,182 |
| `MUXF7` | 247 |
| `MUXF8` | 74 |

### Timing and diagnostics

- Longest mapped topological path: **151 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **25628**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T032508Z:openrv64_retire_queue_3p -->
<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_retire_queue_3p -->
## 2026-08-27T00:08:20+00:00 — `fpga-xc7k480t-module-stats-20260827T000819Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_retire_queue_3p` |
| RTL source | `rtl/core/retire/retire_queue_3p.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `9d5bc3147455f07928608a1bb90d1e31c0c43269` |
| Worktree | `dirty` |
| RTL input SHA-256 | `fd993cb60a3550542a89a7ff7b98a36ed968052d25f867662b60a02155a1e771` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 16.7 s |
| Build log | `build/fpga/xc7k480t/module-stats/retire_queue_3p/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `COUNT_WIDTH` | 6 |
| `DEPTH` | 32 |
| `ENABLE_EXTENSION_COMPLETION` | 0 |
| `ID_WIDTH` | 10 |
| `INDEX_WIDTH` | 5 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 2,404 |
| LUT primitives | 3,136 |
| Flip-flops | 410 |
| Latches | 0 |
| CARRY4 | 136 |
| MUXF7/8/9 | 289 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 4,079 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 136 |
| `FDCE` | 90 |
| `FDRE` | 320 |
| `INV` | 108 |
| `LUT1` | 45 |
| `LUT2` | 723 |
| `LUT3` | 377 |
| `LUT4` | 275 |
| `LUT5` | 520 |
| `LUT6` | 1,196 |
| `MUXF7` | 222 |
| `MUXF8` | 67 |

### Timing and diagnostics

- Longest mapped topological path: **125 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **24442**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_retire_queue_3p -->
