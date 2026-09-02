# `openrv64_dispatch_window_3p` FPGA synthesis history

Generated build records are stored newest first. Counts from different
files are not automatically additive because module boundaries may overlap.
Do not treat structural depth as physical timing.

<!-- module-statistics-entries: newest-first -->

<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-window-identity32-20260902T051848Z:openrv64_dispatch_window_3p -->
## 2026-09-02T05:18:52+00:00 — `fpga-xc7k480t-module-stats-window-identity32-20260902T051848Z`

| Build field | Value |
|---|---|
| Status | **failed** |
| Module | `openrv64_dispatch_window_3p` |
| RTL source | `rtl/core/dispatch/dispatch_window_3p.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `e360d89c53551354a10e50f35fd2ba54143a4a26` |
| Worktree | `dirty` |
| RTL input SHA-256 | `63428eadf2b3b3ec4f26949fe13730e341af0e384a875e4c78ec125edc9d6e90` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 16190.1 s |
| Build log | `build/fpga/xc7k480t/module-stats-window-identity32/dispatch_window_3p/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `CACHEABLE_BASE` | `64'h0000000080000000` |
| `CACHEABLE_SIZE` | `64'h00ffffff80000000` |
| `COUNT_WIDTH` | `6` |
| `DEFER_GPR_READ` | `1` |
| `DEPTH` | `32` |
| `ENABLE` | `1` |
| `ENABLE_SPECULATION` | `1` |
| `MAX_ISSUE_LANES` | `3` |
| `PHYSICAL_RENAME` | `0` |
| `PHYS_REG_ADDR_WIDTH` | `5` |
| `RETIRE_SLOT_WIDTH` | `5` |

### Failure

```text
No latch inferred for signal `\openrv64_dispatch_window_3p.\select_ex0' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\select_ex1' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\select_mem' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\select_mem2' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\select_ex0_admit' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\select_ex1_admit' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\select_mem_admit' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\select_mem2_admit' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\select_offset' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\select_slot' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\selected_idx' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\selected_mem_pipe' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\selected_mem2_pipe' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\selected_age_rank' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\select_ex0_rank' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\select_ex1_rank' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\select_mem_rank' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\select_mem2_rank' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\checked_next_mem' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\trace_pipe_uses_rs1' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\trace_pipe_uses_rs2' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1669$910745'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\trace_wait_unissued_load_count' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1565$891864'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\trace_wait_unissued_other_count' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1565$891864'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\trace_wait_inflight_load_count' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1565$891864'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\trace_wait_inflight_other_count' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1565$891864'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\trace_wait_completed_count' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1565$891864'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\trace_wait_missing_count' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1565$891864'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\wait_idx' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1565$891864'.
No latch inferred for signal `\openrv64_dispatch_window_3p.\wait_found' from process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1565$891864'.
ERROR: Latch inferred for signal `\openrv64_dispatch_window_3p.\producer_idx' from always_comb process `\openrv64_dispatch_window_3p.$proc$/home/bill/src/openrv64/rtl/core/dispatch/dispatch_window_3p.v:1565$891864'.
```

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-window-identity32-20260902T051848Z:openrv64_dispatch_window_3p -->
<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T032508Z:openrv64_dispatch_window_3p -->
## 2026-08-27T03:25:09+00:00 — `fpga-xc7k480t-module-stats-20260827T032508Z`

| Build field | Value |
|---|---|
| Status | **mapped** |
| Module | `openrv64_dispatch_window_3p` |
| RTL source | `rtl/core/dispatch/dispatch_window_3p.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `6a96ae8ecb366b9370e1da7e2b17509400dd7339` |
| Worktree | `dirty` |
| RTL input SHA-256 | `7e7e1bcc8e65e2790e484fa9d55be0b040ac9c296d1a750918db6b8ae76ba23f` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 8441.5 s |
| Build log | `build/fpga/xc7k480t/module-stats/dispatch_window_3p/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `CACHEABLE_BASE` | `64'h0000000080000000` |
| `CACHEABLE_SIZE` | `64'h00ffffff80000000` |
| `COUNT_WIDTH` | 6 |
| `DEPTH` | 32 |
| `ENABLE` | 1 |
| `ENABLE_SPECULATION` | 1 |
| `RETIRE_SLOT_WIDTH` | 5 |

### Resources

| Metric | Count |
|---|---:|
| Estimated logic cells | 189,943 |
| LUT primitives | 242,338 |
| Flip-flops | 18,576 |
| Latches | 0 |
| CARRY4 | 4,165 |
| MUXF7/8/9 | 13,309 |
| DSP48E1 | 2 |
| RAMB36E1 | 0 |
| RAMB18E1 | 0 |
| Distributed-RAM primitives | 0 |
| SRL primitives | 0 |
| Total mapped cells | 299,623 |

Raw nonzero primitive counts:

| Primitive | Count |
|---|---:|
| `CARRY4` | 4,165 |
| `DSP48E1` | 2 |
| `FDCE` | 18,546 |
| `FDRE` | 30 |
| `INV` | 21,233 |
| `LUT1` | 1,606 |
| `LUT2` | 50,789 |
| `LUT3` | 38,182 |
| `LUT4` | 13,697 |
| `LUT5` | 43,542 |
| `LUT6` | 94,522 |
| `MUXF7` | 10,215 |
| `MUXF8` | 3,094 |

### Timing and diagnostics

- Longest mapped topological path: **1400 netlist cells** (`ltp -noff`).
- Physical delay, WNS, and Fmax: **not measured**. These require part-specific implementation and are not inferable from topological depth.
- Logic-loop warnings: **0**; ABC loop cuts: **0**.
- Total Yosys warnings: **7011601**.

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T032508Z:openrv64_dispatch_window_3p -->
<!-- module-statistics-entry:start id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_dispatch_window_3p -->
## 2026-08-27T00:08:20+00:00 — `fpga-xc7k480t-module-stats-20260827T000819Z`

| Build field | Value |
|---|---|
| Status | **failed** |
| Module | `openrv64_dispatch_window_3p` |
| RTL source | `rtl/core/dispatch/dispatch_window_3p.v` |
| Profile | `xc7k480t-3p-linux` — Standalone module-local XC7 mappings for the full single-hart 3P Linux profile. |
| Synthesis boundary | This module is the standalone top; only logic below this boundary is flattened. |
| Target | Generic Xilinx 7-series primitives (`xc7`); no part-specific placement or routing |
| Git commit | `9d5bc3147455f07928608a1bb90d1e31c0c43269` |
| Worktree | `dirty` |
| RTL input SHA-256 | `fd993cb60a3550542a89a7ff7b98a36ed968052d25f867662b60a02155a1e771` |
| Tool | `Yosys 0.66 (git sha1 86f2ddebc-dirty, g++ 16.1.1 -march=x86-64 -mtune=generic -O2 -fno-plt -fexceptions -fstack-clash-protection -fcf-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffile-prefix-map=/build/yosys/src=/usr/src/debug/yosys -fPIC -O3) [startdir/yosys at makepkg]` |
| Elapsed | 4248.6 s |
| Build log | `build/fpga/xc7k480t/module-stats/dispatch_window_3p/yosys.log` |

### Effective parameters

| Parameter | Value |
|---|---:|
| `CACHEABLE_BASE` | `64'h0000000080000000` |
| `CACHEABLE_SIZE` | `64'h00ffffff80000000` |
| `COUNT_WIDTH` | 6 |
| `DEPTH` | 32 |
| `ENABLE` | 1 |
| `ENABLE_SPECULATION` | 1 |
| `RETIRE_SLOT_WIDTH` | 5 |

### Failure

```text
<suppressed ~1 debug messages>

89.36.33. Executing OPT_EXPR pass (perform const folding).
Optimizing module openrv64_dispatch_window_3p.

89.36.34. Rerunning OPT passes. (Maybe there is more to do..)

89.36.35. Executing OPT_MUXTREE pass (detect dead branches in mux trees).
Running muxtree optimizer on module \openrv64_dispatch_window_3p..
  Creating internal representation of mux trees.
  Evaluating internal representation of mux trees.
  Analyzing evaluation results.
Removed 0 multiplexer ports.
<suppressed ~119379 debug messages>

89.36.36. Executing OPT_REDUCE pass (consolidate $*mux and $reduce_* inputs).
  Optimizing cells in module \openrv64_dispatch_window_3p.
Performed a total of 0 changes.

89.36.37. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\openrv64_dispatch_window_3p'.
Computing hashes of 43340 cells of `\openrv64_dispatch_window_3p'.
Finding duplicate cells in `\openrv64_dispatch_window_3p'.
Removed a total of 0 cells.

89.36.38. Executing OPT_SHARE pass.

89.36.39. Executing OPT_DFF pass (perform DFF optimizations).

89.36.40. Executing OPT_CLEAN pass (remove unused cells and wires).
```

<!-- module-statistics-entry:end id=fpga-xc7k480t-module-stats-20260827T000819Z:openrv64_dispatch_window_3p -->
