# RV64F/RV64D performance

Last updated: 2026-08-03

## Scope

This document records cycle-model measurements of the 4PF floating-point
integration.  The results are functional RTL simulation measurements, not
frequency, area, power, or FPGA measurements.  The measured working tree was
based on commit `3553711699e2154755f1fd7f6edd315d1a84799f` and contained
uncommitted F/D, 4PF, L1, testbench, and documentation work.  The commit alone
therefore does not reproduce these numbers.

The tests use the full 4PF decode, issue window, F/D sidecar, FPU, retirement,
and core top.  L1I and L1D are enabled and connect to the testbench's native
tagged-RAM CCX home.  The FPU accepts at most one computational request per
cycle, so one accepted FMA per cycle is its current steady-state throughput
limit.

## Workloads

The full DAXPY test in [`sw/fp/daxpy.S`](../../sw/fp/daxpy.S) executes 256
elements, each containing two FP loads, one `FMADD.D`, and one FP store.  Its
measured instruction stream therefore contains 512 FP loads, 256 FMAs, 256 FP
stores, and integer loop/control work.

The compute-only isolation test in
[`sw/fp/daxpy_compute.S`](../../sw/fp/daxpy_compute.S) executes exactly 256
`FMADD.D` operations in every measured region.  Constants and accumulators are
initialized before measurement, and result checking and counter publication
occur afterward.  The measured regions issue no loads or stores.  The cases
are:

| Case | Structure |
| --- | --- |
| u1 | One accumulator, 256 loop iterations |
| u4 | Four accumulators, 64 loop iterations |
| u16 | Sixteen accumulators, 16 loop iterations |
| u32 | Two repeated 16-FMA waves, 8 loop iterations |
| u256 | Sixteen repeated 16-FMA waves, one loop iteration |

The u32 and u256 cases still use 16 architectural accumulator registers,
`f2` through `f17`.  They repeat those registers with a dependency distance of
16; they do not require 32 or 256 independent FPRs.  This distance covers the
15-cycle final iterative FPU path in the measured design.  The counters confirm
that neither producer readiness nor missing forwarding blocks u16, u32, or
u256.

## Full DAXPY, 16-entry window

The proper-L1 full DAXPY run passed its numerical and handshake checks.

| Unroll | Cycles | Retired | IPC | Cycles/element | Average FPU request interval | Maximum FPU inflight |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 6,027 | 2,054 | 0.340 | 23.542 | 23.360 | 1 |
| 4 | 2,126 | 1,286 | 0.604 | 8.304 | 8.105 | 4 |
| 16 | 1,818 | 1,094 | 0.601 | 7.101 | 6.815 | 8 |
| 32 | 1,665 | 1,062 | 0.637 | 6.503 | 6.239 | 14 |

For u32, all 768 memory operations were accepted.  There were 32 cycles of
memory-interface backpressure and 39 cycles in which the four-entry load queue
was full.  The FPU itself reported zero backpressure.  Retirement produced no
instruction on 649 phase cycles; 314 of those cycles had FP compute at the
head and 287 had an FP store at the head.  Compute plus store therefore
accounted for 601 of 649, or 92.6%, of the observed retirement-empty cycles.

These counts overlap and cannot be added as independent costs.  They establish
that the proper L1/LSQ interface is not the dominant remaining full-DAXPY
limit.  The full workload is constrained by its three memory operations per
FMA, the current one-memory-operation-per-cycle scheduler, FP result/store-data
timing, and precise in-order retirement.

The recorded output is in
[`build/logs/20260803-top-4pf-l1-daxpy.log`](../../build/logs/20260803-top-4pf-l1-daxpy.log).

## Compute-only isolation

### 16-entry window

| Unroll | Cycles | Retired | IPC | Cycles/FMA | Average FPU request interval | Maximum FPU inflight |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 4,112 | 770 | 0.187 | 16.062 | 16.000 | 1 |
| 4 | 1,043 | 386 | 0.370 | 4.074 | 3.964 | 4 |
| 16 | 411 | 290 | 0.705 | 1.605 | 1.486 | 15 |
| 32 | 409 | 274 | 0.669 | 1.597 | 1.478 | 15 |
| 256 | 372 | 260 | 0.698 | 1.453 | 1.333 | 15 |

Removing seven of the eight u32 loop backedges in u256 reduced execution from
409 to 372 cycles, a 9.0% improvement.  It did not reach one request per cycle.
The u256 phase contained 133 cycles with no unissued compute candidate and 124
cycles with a nonempty retirement queue but no retirement.  FP compute occupied
the incomplete retirement head for 102 of those cycles.  FPU backpressure,
producer-pending stalls, forwarding-ready stalls, and measured memory traffic
were all zero.

The 16-entry result is a capacity/turnaround limit, not exhaustion of the
architectural FPR names.  The backend deliberately uses the conservative
admission equation:

```verilog
allocation_ready = retire_occupancy_o <= RETIRE_DEPTH - 3;
```

It reserves room for a complete three-instruction allocation group, does not
credit same-cycle retirement, and can stop admission at occupancy 14 or 15.
Consequently, a counter that only reports occupancy exactly equal to 16 can
remain zero while capacity admission is already blocking.  A slot remains live
through allocation, FPU issue, the 15-cycle arithmetic path, result capture,
extension completion, ordered retirement, and reuse.  Sixteen total slots do
not cover that lifetime with enough margin to sustain continuous issue.

### Controlled 32-entry window

The same software and L1 configuration were recompiled with only
`tb_top_4pf.RETIRE_DEPTH=32` changed.  In 4PF, retirement and issue-window depth
are tied, so this changes both capacities.

| Unroll | Cycles | Retired | IPC | Cycles/FMA | Average FPU request interval | Maximum FPU inflight |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 4,112 | 770 | 0.187 | 16.062 | 16.000 | 1 |
| 4 | 1,043 | 386 | 0.370 | 4.074 | 3.964 | 4 |
| 16 | **287** | 290 | **1.010** | **1.121** | **1.000** | 15 |
| 32 | **287** | 274 | 0.954 | **1.121** | **1.000** | 15 |
| 256 | **287** | 260 | 0.905 | **1.121** | **1.000** | 15 |

For u256, increasing the window from 16 to 32 entries changed:

| Counter | Window 16 | Window 32 | Delta |
| --- | ---: | ---: | ---: |
| Measured cycles | 372 | 287 | -85 (-22.8%) |
| Average FPU request interval | 1.333 | 1.000 | -0.333 |
| No-compute-candidate phase cycles | 133 | 48 | -85 |
| Retirement-empty phase cycles | 124 | 39 | -85 |
| Incomplete FP-compute head cycles | 102 | 17 | -85 |
| FPU backpressure cycles | 0 | 0 | 0 |
| Producer/forwarding dependency cycles | 0 | 0 | 0 |
| Measured memory accepts | 0 | 0 | 0 |

The active FPU request stream is continuous in the u16, u32, and u256 cases:
one accepted `FMADD.D` every cycle.  This reaches the current single-request
FPU's throughput limit.  The 287-cycle finite-region measurement still
contains counter-boundary effects and pipeline fill/drain; it should not be
interpreted as a steady-state initiation interval of 1.121 cycles.

IPC is not the right saturation metric for this isolation test.  Larger
unrolls remove integer loop instructions, so u256 retires fewer instructions
than u16 while both finish in 287 cycles.  This lowers reported IPC even though
useful FMA throughput is unchanged.  The request interval directly measures
whether the FPU remains filled.

## Findings

1. Sixteen independent accumulator chains are sufficient to hide the FPU RAW
   latency; the u16/u32/u256 dependency counters are zero.
2. A 16-entry combined issue/retirement window is not sufficient to cover FPU
   execution plus result/completion/retirement slot lifetime under the current
   conservative three-entry admission rule.
3. A controlled 32-entry window sustains exactly one accepted FMA per cycle,
   which is the implemented FPU's maximum input throughput.
4. Further compute-only unrolling cannot improve steady-state FPU issue without
   adding another FPU request port.  It can only change finite-region overhead
   or instruction-mix IPC.
5. This compute-only result does not imply one-FMA-per-cycle full DAXPY.  Full
   DAXPY remains subject to memory scheduling, load-to-FPR availability,
   store-data capture, and precise retirement.

The 32-entry result is a controlled experiment.  It does not change the 4PF
source or testbench default from 16 entries.

## Reproduction

Build the software, then compile separate L1-enabled window-16 and window-32
testbench binaries:

```sh
make sw-fp-daxpy-compute

make -B \
  TOP_4PF_SIM_BUILD=/tmp/top_4pf_l1_w16_tb.vvp \
  TOP_4PF_IVERILOG_FLAGS=-Ptb_top_4pf.ENABLE_L1=1 \
  /tmp/top_4pf_l1_w16_tb.vvp

make -B \
  TOP_4PF_SIM_BUILD=/tmp/top_4pf_l1_w32_tb.vvp \
  TOP_4PF_IVERILOG_FLAGS='-Ptb_top_4pf.ENABLE_L1=1 -Ptb_top_4pf.RETIRE_DEPTH=32' \
  /tmp/top_4pf_l1_w32_tb.vvp

vvp /tmp/top_4pf_l1_w16_tb.vvp \
  +daxpy_compute +memh=sim/fp-daxpy-compute.memh
vvp /tmp/top_4pf_l1_w32_tb.vvp \
  +daxpy_compute +memh=sim/fp-daxpy-compute.memh
```

Both configurations must print the literal compute-only DAXPY PASS line.  The
testbench also asserts 256 FPU requests, 256 FPU results, and zero measured
memory operations for every compute-only phase.
