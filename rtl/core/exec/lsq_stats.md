# `openrv64_lsq` FPGA synthesis history

Generated build records are stored newest first. Counts from different
files are not automatically additive because module boundaries may overlap.
Do not treat structural depth as physical timing.

<!-- module-statistics-entries: newest-first -->

<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T032508Z:openrv64_lsq -->
## 2026-08-27T03:25:09+00:00 — `fpga-xc7k480t-module-stats-20260827T032508Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_lsq` |
| RTL source | `rtl/core/exec/lsq.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `6a96ae8ecb366b9370e1da7e2b17509400dd7339` |
| Worktree | `dirty` |
| RTL input SHA-256 | `7e7e1bcc8e65e2790e484fa9d55be0b040ac9c296d1a750918db6b8ae76ba23f` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 25.2 s |
| Build log | `build/fpga/xc7k480t/module-stats/lsq/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `CACHEABLE_BASE` | `64'h0000000080000000` |
| `CACHEABLE_SIZE` | `64'h00ffffff80000000` |
| `DEPTH` | 8 |
| `GUARD_HASH_WIDTH` | 10 |
| `LOAD_QUEUE_DEPTH` | 4 |
| `META_WIDTH` | 116 |
| `RETIRE_SLOT_WIDTH` | 5 |
| `STORE_QUEUE_DEPTH` | 4 |
| `TAG_WIDTH` | 3 |
| `TIMEOUT_CYCLES` | 10000 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 3,875 |
| LUT primitives | 5,472 |
| Flip-flops | 2,516 |
| Latches | 0 |
| CARRY4 | 246 |
| MUXF7/8/9 | 280 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 11,822 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 246 |
| `FDCE` | 2,516 |
| `INV` | 3,308 |
| `LUT1` | 73 |
| `LUT2` | 1,904 |
| `LUT3` | 901 |
| `LUT4` | 243 |
| `LUT5` | 224 |
| `LUT6` | 2,127 |
| `MUXF7` | 248 |
| `MUXF8` | 32 |

### Timing and diagnostics

- Longest mapped topological path: **400 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **34242**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T032508Z:openrv64_lsq -->
<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T014901Z:openrv64_lsq -->
## 2026-08-27T01:49:02+00:00 — `fpga-xc7k480t-module-stats-20260827T014901Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_lsq` |
| RTL source | `rtl/core/exec/lsq.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `6a96ae8ecb366b9370e1da7e2b17509400dd7339` |
| Worktree | `dirty` |
| RTL input SHA-256 | `1a86384cb4b35ea53ffa9c28b41f3674b44cafe692b2af2c6a87e9f7b9d4a2bb` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 16.2 s |
| Build log | `build/fpga/xc7k480t/module-stats/lsq/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `CACHEABLE_BASE` | `64'h0000000080000000` |
| `CACHEABLE_SIZE` | `64'h00ffffff80000000` |
| `DEPTH` | 8 |
| `GUARD_HASH_WIDTH` | 10 |
| `LOAD_QUEUE_DEPTH` | 4 |
| `META_WIDTH` | 116 |
| `RETIRE_SLOT_WIDTH` | 5 |
| `STORE_QUEUE_DEPTH` | 4 |
| `TAG_WIDTH` | 3 |
| `TIMEOUT_CYCLES` | 10000 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 2,367 |
| LUT primitives | 3,051 |
| Flip-flops | 1,700 |
| Latches | 0 |
| CARRY4 | 132 |
| MUXF7/8/9 | 113 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 7,009 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 132 |
| `FDCE` | 1,700 |
| `INV` | 2,013 |
| `LUT1` | 5 |
| `LUT2` | 749 |
| `LUT3` | 523 |
| `LUT4` | 87 |
| `LUT5` | 77 |
| `LUT6` | 1,610 |
| `MUXF7` | 91 |
| `MUXF8` | 22 |

### Timing and diagnostics

- Longest mapped topological path: **272 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **10024**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T014901Z:openrv64_lsq -->
<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T014614Z:openrv64_lsq -->
## 2026-08-27T01:46:14+00:00 — `fpga-xc7k480t-module-stats-20260827T014614Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_lsq` |
| RTL source | `rtl/core/exec/lsq.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `6a96ae8ecb366b9370e1da7e2b17509400dd7339` |
| Worktree | `dirty` |
| RTL input SHA-256 | `7d71539fb6c3eed5d8c7f1a213e1857dafdaaa2e6f9e8d30b8c50b07565ae452` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 18.2 s |
| Build log | `build/fpga/xc7k480t/module-stats/lsq/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `CACHEABLE_BASE` | `64'h0000000080000000` |
| `CACHEABLE_SIZE` | `64'h00ffffff80000000` |
| `DEPTH` | 8 |
| `GUARD_HASH_WIDTH` | 10 |
| `LOAD_QUEUE_DEPTH` | 4 |
| `META_WIDTH` | 116 |
| `RETIRE_SLOT_WIDTH` | 5 |
| `STORE_QUEUE_DEPTH` | 4 |
| `TAG_WIDTH` | 3 |
| `TIMEOUT_CYCLES` | 10000 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 2,229 |
| LUT primitives | 3,111 |
| Flip-flops | 1,700 |
| Latches | 0 |
| CARRY4 | 132 |
| MUXF7/8/9 | 349 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 7,487 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 132 |
| `FDCE` | 1,700 |
| `INV` | 2,195 |
| `LUT1` | 223 |
| `LUT2` | 735 |
| `LUT3` | 323 |
| `LUT4` | 260 |
| `LUT5` | 276 |
| `LUT6` | 1,294 |
| `MUXF7` | 309 |
| `MUXF8` | 40 |

### Timing and diagnostics

- Longest mapped topological path: **295 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **18112**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T014614Z:openrv64_lsq -->
<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_lsq -->
## 2026-08-27T00:08:20+00:00 — `fpga-xc7k480t-module-stats-20260827T000819Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_lsq` |
| RTL source | `rtl/core/exec/lsq.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `9d5bc3147455f07928608a1bb90d1e31c0c43269` |
| Worktree | `dirty` |
| RTL input SHA-256 | `fd993cb60a3550542a89a7ff7b98a36ed968052d25f867662b60a02155a1e771` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 109.3 s |
| Build log | `build/fpga/xc7k480t/module-stats/lsq/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `CACHEABLE_BASE` | `64'h0000000080000000` |
| `CACHEABLE_SIZE` | `64'h00ffffff80000000` |
| `DEPTH` | 8 |
| `LOAD_QUEUE_DEPTH` | 4 |
| `META_WIDTH` | 402 |
| `RETIRE_SLOT_WIDTH` | 5 |
| `STORE_QUEUE_DEPTH` | 4 |
| `TAG_WIDTH` | 3 |
| `TIMEOUT_CYCLES` | 10000 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 10,067 |
| LUT primitives | 13,010 |
| Flip-flops | 4,776 |
| Latches | 0 |
| CARRY4 | 864 |
| MUXF7/8/9 | 953 |
| DSP48E1 | 0 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 25,172 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 864 |
| `FDCE` | 4,776 |
| `INV` | 5,569 |
| `LUT1` | 8 |
| `LUT2` | 3,454 |
| `LUT3` | 964 |
| `LUT4` | 1,452 |
| `LUT5` | 2,365 |
| `LUT6` | 4,767 |
| `MUXF7` | 708 |
| `MUXF8` | 245 |

### Timing and diagnostics

- Longest mapped topological path: **381 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **22208**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_lsq -->
