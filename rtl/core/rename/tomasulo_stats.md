# `openrv64_rename_tomasulo` FPGA synthesis history

Generated build records are stored newest first. Counts from different
files are not automatically additive because module boundaries may overlap.
Do not treat structural depth as physical timing.

<!-- module-statistics-entries: newest-first -->

<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-rename32-20260902T051945Z:openrv64_rename_tomasulo -->
## 2026-09-02T05:21:52+00:00 — `fpga-xc7k480t-module-stats-rename32-20260902T051945Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_rename_tomasulo` |
| RTL source | `rtl/core/rename/tomasulo.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `e360d89c53551354a10e50f35fd2ba54143a4a26` |
| Worktree | `dirty` |
| RTL input SHA-256 | `6df26bc8f61e6933fa60e064fb9e35cb6bf6574b25121e6154451e26ea5f59fc` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 568.4 s |
| Build log | `build/fpga/xc7k480t/module-stats-rename64/rename_tomasulo/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `ARCH_ADDR_WIDTH` | 5 |
| `ARCH_REG_COUNT` | 32 |
| `CHECKPOINT_DEPTH` | 64 |
| `CHECKPOINT_SLOT_WIDTH` | 6 |
| `COMMIT_PORTS` | 3 |
| `FREE_COUNT_WIDTH` | 6 |
| `FREE_PORTS` | 2 |
| `LANES` | 3 |
| `PHYS_ADDR_WIDTH` | 6 |
| `PHYS_REG_COUNT` | 63 |
| `SOURCES_PER_LANE` | 2 |
| `WRITE_PORTS` | 3 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 62,135 |
| LUT primitives | 70,454 |
| Flip-flops | 21,317 |
| Latches | 0 |
| CARRY4 | 889 |
| MUXF7/8/9 | 3,098 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 100,567 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 889 |
| `FDCE` | 4,388 |
| `FDPE` | 225 |
| `FDRE` | 16,704 |
| `INV` | 4,809 |
| `LUT1` | 791 |
| `LUT2` | 7,528 |
| `LUT3` | 21,717 |
| `LUT4` | 3,456 |
| `LUT5` | 8,009 |
| `LUT6` | 28,953 |
| `MUXF7` | 2,437 |
| `MUXF8` | 661 |

### Timing and diagnostics

- Longest mapped topological path: **855 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **1085800**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-rename32-20260902T051945Z:openrv64_rename_tomasulo -->
<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-rename32-20260902T051651Z:openrv64_rename_tomasulo -->
## 2026-09-02T05:16:52+00:00 — `fpga-xc7k480t-module-stats-rename32-20260902T051651Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_rename_tomasulo` |
| RTL source | `rtl/core/rename/tomasulo.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `e360d89c53551354a10e50f35fd2ba54143a4a26` |
| Worktree | `dirty` |
| RTL input SHA-256 | `d932ef489861c902e2d42fbd6e603a2e33f2ced2b49f9843e0aa39b454d951fe` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 298.3 s |
| Build log | `build/fpga/xc7k480t/module-stats-rename32/rename_tomasulo/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `ARCH_ADDR_WIDTH` | 5 |
| `ARCH_REG_COUNT` | 32 |
| `CHECKPOINT_DEPTH` | 32 |
| `CHECKPOINT_SLOT_WIDTH` | 5 |
| `COMMIT_PORTS` | 3 |
| `FREE_COUNT_WIDTH` | 6 |
| `FREE_PORTS` | 2 |
| `LANES` | 3 |
| `PHYS_ADDR_WIDTH` | 6 |
| `PHYS_REG_COUNT` | 63 |
| `SOURCES_PER_LANE` | 2 |
| `WRITE_PORTS` | 3 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 38,026 |
| LUT primitives | 45,478 |
| Flip-flops | 10,917 |
| Latches | 0 |
| CARRY4 | 889 |
| MUXF7/8/9 | 3,119 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 63,160 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 889 |
| `FDCE` | 2,340 |
| `FDPE` | 225 |
| `FDRE` | 8,352 |
| `INV` | 2,757 |
| `LUT1` | 714 |
| `LUT2` | 6,738 |
| `LUT3` | 11,719 |
| `LUT4` | 2,696 |
| `LUT5` | 4,413 |
| `LUT6` | 19,198 |
| `MUXF7` | 2,481 |
| `MUXF8` | 638 |

### Timing and diagnostics

- Longest mapped topological path: **800 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **856789**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-rename32-20260902T051651Z:openrv64_rename_tomasulo -->
