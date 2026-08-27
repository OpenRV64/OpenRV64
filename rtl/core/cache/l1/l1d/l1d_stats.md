# `openrv64_l1d_icx` FPGA synthesis history

Generated build records are stored newest first. Counts from different
files are not automatically additive because module boundaries may overlap.
Do not treat structural depth as physical timing.

<!-- module-statistics-entries: newest-first -->

<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T032508Z:openrv64_l1d_icx -->
## 2026-08-27T03:25:09+00:00 — `fpga-xc7k480t-module-stats-20260827T032508Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_l1d_icx` |
| RTL source | `rtl/core/cache/l1/l1d/l1d.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `6a96ae8ecb366b9370e1da7e2b17509400dd7339` |
| Worktree | `dirty` |
| RTL input SHA-256 | `7e7e1bcc8e65e2790e484fa9d55be0b040ac9c296d1a750918db6b8ae76ba23f` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 702.6 s |
| Build log | `build/fpga/xc7k480t/module-stats/l1d_icx/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `ADDR_WIDTH` | 64 |
| `ATOMIC_HOT_LINES` | 16 |
| `CACHE_BYTES` | 16384 |
| `COHERENT_ATOMICS` | 0 |
| `DEMAND_MSHRS` | 3 |
| `DIRTY_TIMESTAMP_WIDTH` | 8 |
| `ENABLE` | 1 |
| `FILL_BUFFER_LINES` | 8 |
| `FREELOADER` | 0 |
| `FREELOADER_LATENCY` | 3 |
| `HART_ID` | 0 |
| `LINE_BYTES` | 64 |
| `PREFETCH_ADAPTIVE_ENABLE` | 1 |
| `PREFETCH_CACHEABLE_BASE` | `64'h0000000080000000` |
| `PREFETCH_CACHEABLE_SIZE` | `64'h00ffffff80000000` |
| `PREFETCH_DEMAND_RESERVE` | 2 |
| `PREFETCH_DISTANCE` | 1 |
| `PREFETCH_ENABLE` | 1 |
| `PREFETCH_MAX_DISTANCE` | 4 |
| `PREFETCH_MAX_STRIDE_LINES` | 64 |
| `PREFETCH_OUTSTANDING` | 4 |
| `PREFETCH_PAGE_GATING` | 1 |
| `PREFETCH_QUEUE_LINES` | 4 |
| `PREFETCH_STREAMS` | 2 |
| `REQ_DEPTH` | 8 |
| `REQ_TAG_WIDTH` | 3 |
| `SPECULATION_EPOCH_WIDTH` | 8 |
| `STORE_BUFFER_DRAIN_WATERMARK` | 4 |
| `STORE_BUFFER_LINES` | 8 |
| `STORE_BUFFER_TIMEOUT_CYCLES` | 1024 |
| `SYNC_STORE_EXTENSION` | 1 |
| `SYNC_TAG_LOOKUP` | 1 |
| `WAYS` | 4 |
| `WRITEBACK_TIMEOUT_CYCLES` | 128 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 71,973 |
| LUT primitives | 93,588 |
| Flip-flops | 18,174 |
| Latches | 0 |
| CARRY4 | 548 |
| MUXF7/8/9 | 10,308 |
| DSP48E1 | 8 |
| RAMB36E1 | 44 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 1 |
| SRL primitives | 0 |
| Total mapped cells | 140,708 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 548 |
| `DSP48E1` | 8 |
| `FDCE` | 17,584 |
| `FDPE` | 6 |
| `FDRE` | 584 |
| `INV` | 18,037 |
| `LUT1` | 1,684 |
| `LUT2` | 19,931 |
| `LUT3` | 14,439 |
| `LUT4` | 7,769 |
| `LUT5` | 10,291 |
| `LUT6` | 39,474 |
| `MUXF7` | 7,741 |
| `MUXF8` | 2,567 |
| `RAM32M` | 1 |
| `RAMB36E1` | 44 |

### Timing and diagnostics

- Longest mapped topological path: **1390 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **1739193**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T032508Z:openrv64_l1d_icx -->
<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_l1d_icx -->
## 2026-08-27T00:08:20+00:00 — `fpga-xc7k480t-module-stats-20260827T000819Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_l1d_icx` |
| RTL source | `rtl/core/cache/l1/l1d/l1d.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `9d5bc3147455f07928608a1bb90d1e31c0c43269` |
| Worktree | `dirty` |
| RTL input SHA-256 | `fd993cb60a3550542a89a7ff7b98a36ed968052d25f867662b60a02155a1e771` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 690.0 s |
| Build log | `build/fpga/xc7k480t/module-stats/l1d_icx/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `ADDR_WIDTH` | 64 |
| `ATOMIC_HOT_LINES` | 16 |
| `CACHE_BYTES` | 16384 |
| `COHERENT_ATOMICS` | 0 |
| `DEMAND_MSHRS` | 3 |
| `DIRTY_TIMESTAMP_WIDTH` | 8 |
| `ENABLE` | 1 |
| `FILL_BUFFER_LINES` | 8 |
| `FREELOADER` | 0 |
| `FREELOADER_LATENCY` | 3 |
| `HART_ID` | 0 |
| `LINE_BYTES` | 64 |
| `PREFETCH_ADAPTIVE_ENABLE` | 1 |
| `PREFETCH_CACHEABLE_BASE` | `64'h0000000080000000` |
| `PREFETCH_CACHEABLE_SIZE` | `64'h00ffffff80000000` |
| `PREFETCH_DEMAND_RESERVE` | 2 |
| `PREFETCH_DISTANCE` | 1 |
| `PREFETCH_ENABLE` | 1 |
| `PREFETCH_MAX_DISTANCE` | 4 |
| `PREFETCH_MAX_STRIDE_LINES` | 64 |
| `PREFETCH_OUTSTANDING` | 4 |
| `PREFETCH_PAGE_GATING` | 1 |
| `PREFETCH_QUEUE_LINES` | 4 |
| `PREFETCH_STREAMS` | 2 |
| `REQ_DEPTH` | 8 |
| `REQ_TAG_WIDTH` | 3 |
| `SPECULATION_EPOCH_WIDTH` | 8 |
| `STORE_BUFFER_DRAIN_WATERMARK` | 4 |
| `STORE_BUFFER_LINES` | 8 |
| `STORE_BUFFER_TIMEOUT_CYCLES` | 1024 |
| `SYNC_STORE_EXTENSION` | 1 |
| `SYNC_TAG_LOOKUP` | 1 |
| `WAYS` | 4 |
| `WRITEBACK_TIMEOUT_CYCLES` | 128 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 70,910 |
| LUT primitives | 94,447 |
| Flip-flops | 18,174 |
| Latches | 0 |
| CARRY4 | 548 |
| MUXF7/8/9 | 12,374 |
| DSP48E1 | 8 |
| RAMB36E1 | 44 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 1 |
| SRL primitives | 0 |
| Total mapped cells | 143,633 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 548 |
| `DSP48E1` | 8 |
| `FDCE` | 17,584 |
| `FDPE` | 6 |
| `FDRE` | 584 |
| `INV` | 18,037 |
| `LUT1` | 2,723 |
| `LUT2` | 21,732 |
| `LUT3` | 12,950 |
| `LUT4` | 6,946 |
| `LUT5` | 9,727 |
| `LUT6` | 40,369 |
| `MUXF7` | 8,791 |
| `MUXF8` | 3,583 |
| `RAM32M` | 1 |
| `RAMB36E1` | 44 |

### Timing and diagnostics

- Longest mapped topological path: **1577 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **865316**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_l1d_icx -->
