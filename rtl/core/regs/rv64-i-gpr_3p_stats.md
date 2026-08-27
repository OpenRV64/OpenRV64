# `openrv64_rv64i_gpr_3p` FPGA synthesis history

Generated build records are stored newest first. Counts from different
files are not automatically additive because module boundaries may overlap.
Do not treat structural depth as physical timing.

<!-- module-statistics-entries: newest-first -->

<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T032508Z:openrv64_rv64i_gpr_3p -->
## 2026-08-27T03:25:09+00:00 — `fpga-xc7k480t-module-stats-20260827T032508Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_rv64i_gpr_3p` |
| RTL source | `rtl/core/regs/rv64-i-gpr_3p.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `6a96ae8ecb366b9370e1da7e2b17509400dd7339` |
| Worktree | `dirty` |
| RTL input SHA-256 | `7e7e1bcc8e65e2790e484fa9d55be0b040ac9c296d1a750918db6b8ae76ba23f` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 95.4 s |
| Build log | `build/fpga/xc7k480t/module-stats/rv64i_gpr_3p/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `ALLOW_DUPLICATE_WRITES` | 1 |
| `NUM_REGS` | 31 |
| `READ_WRITE_BYPASS` | 1 |
| `REG_ADDR_WIDTH` | 5 |
| `RESET_REGS` | 1 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 25,788 |
| LUT primitives | 31,739 |
| Flip-flops | 1,984 |
| Latches | 0 |
| CARRY4 | 63 |
| MUXF7/8/9 | 13,151 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 48,957 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 63 |
| `FDCE` | 1,984 |
| `INV` | 2,020 |
| `LUT1` | 2,920 |
| `LUT2` | 3,031 |
| `LUT3` | 4,475 |
| `LUT4` | 5,008 |
| `LUT5` | 3,658 |
| `LUT6` | 12,647 |
| `MUXF7` | 9,813 |
| `MUXF8` | 3,338 |

### Timing and diagnostics

- Longest mapped topological path: **50 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **21190**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T032508Z:openrv64_rv64i_gpr_3p -->
<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_rv64i_gpr_3p -->
## 2026-08-27T00:08:20+00:00 — `fpga-xc7k480t-module-stats-20260827T000819Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_rv64i_gpr_3p` |
| RTL source | `rtl/core/regs/rv64-i-gpr_3p.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `9d5bc3147455f07928608a1bb90d1e31c0c43269` |
| Worktree | `dirty` |
| RTL input SHA-256 | `fd993cb60a3550542a89a7ff7b98a36ed968052d25f867662b60a02155a1e771` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 95.0 s |
| Build log | `build/fpga/xc7k480t/module-stats/rv64i_gpr_3p/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `ALLOW_DUPLICATE_WRITES` | 1 |
| `NUM_REGS` | 31 |
| `READ_WRITE_BYPASS` | 1 |
| `REG_ADDR_WIDTH` | 5 |
| `RESET_REGS` | 1 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 25,788 |
| LUT primitives | 31,739 |
| Flip-flops | 1,984 |
| Latches | 0 |
| CARRY4 | 63 |
| MUXF7/8/9 | 13,151 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 48,957 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 63 |
| `FDCE` | 1,984 |
| `INV` | 2,020 |
| `LUT1` | 2,920 |
| `LUT2` | 3,031 |
| `LUT3` | 4,475 |
| `LUT4` | 5,008 |
| `LUT5` | 3,658 |
| `LUT6` | 12,647 |
| `MUXF7` | 9,813 |
| `MUXF8` | 3,338 |

### Timing and diagnostics

- Longest mapped topological path: **50 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **21190**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_rv64i_gpr_3p -->
