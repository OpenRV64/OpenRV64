# OpenRV64 and gem5 HPI comparison

Last updated: 2026-07-28

## Scope

This document compares the current OpenRV64 3-pipe RTL configuration with
gem5's ARM HPI configuration.  It records:

- the differences between the test harnesses and instruction streams;
- the performance-relevant hardware and model differences;
- the current `__free_pages_core` proxy results;
- the DDR3 bank/row swizzle experiment; and
- the limits on comparisons with Cortex-A53 hardware.

The HPI result is a gem5 MinorCPU timing-model result.  It is not a
measurement of Cortex-A53 silicon and is not a cycle-exact Cortex-A53 model.
OpenRV64 is simulated RTL, but the current physical frequency and area of
this exact configuration have not been established.  Cycle counts therefore
compare two models at a nominal common clock; they do not establish equal
wall-clock performance or performance per area.

The benchmark-specific Linux diagnosis remains in
[`linux/kernel/free_pages_core.md`](linux/kernel/free_pages_core.md).  That
document is authoritative for the observed Linux plateau.  This document
adds the HPI and hardware comparison.

## Reporting policy

Reference and externally reported OpenRV64 performance numbers use the plain
DDR address mapping (`DDR3_BANK_ROW_SWIZZLE=0`).  Bank hashing
(`DDR3_BANK_ROW_SWIZZLE=1`) is a physically implementable controller option,
but its measurements are reported separately as architectural experiments.
Linux boot-time optimization may use swizzling while that option is being
evaluated; those runs must retain the swizzle setting in their configuration
and result label.  Existing swizzle-on measurements below are preserved as
experimental evidence, not promoted to the reference headline.

## Conclusions

1. The reference 65,536-record bare OpenRV64 proxy with plain address mapping
   completes in 1,477,021 cycles, versus 2,904,986 cycles for the gem5 HPI
   semantic proxy.  OpenRV64 therefore completes this specific fixed work
   1.967 times faster in model cycles.
2. This does **not** establish that OpenRV64 is generally faster than a
   Cortex-A53.  The result is dominated by one contiguous 64-byte stream,
   different prefetchers, different cache capacities, and different memory
   controllers.  HPI's configured stride prefetcher gets almost none of its
   lines classified useful in this test; OpenRV64 gets essentially all of
   them useful.
3. The Linux plateau is still much slower than the current bare OpenRV64
   proxy: about 56.64 versus 19.64 cycles per page descriptor.  Those results
   are not source-matched.  The Linux binary predates the bank/row swizzle and
   runs after a real boot with Sv39, real `mem_map` placement, and accumulated
   cache/TLB/controller state.
4. Enabling the OpenRV64 DDR bank/row swizzle reduces the full proxy from
   1,477,021 to 1,287,283 cycles, a 12.85% cycle reduction.  It changes the
   modeled controller address mapping; it is not a core or L2-cache
   optimization and is not enabled in the HPI reference.
5. IPC is not a valid cross-ISA headline.  The steady OpenRV64 loop retires
   eight RV64 instructions per record; the AArch64 loop retires seven.
   Cycles per record is the primary cross-ISA throughput measure.

## Compared configurations

### OpenRV64 page-free proxy

The measured OpenRV64 configuration is:

```text
BP8, fetch mode 3, carousel enabled, FA3/FC0
issue window enabled, speculation enabled, RD32, PRF31
posted stores enabled
16 KiB L1I, 16 KiB L1D
256 KiB 8-way L2, 8 L2 MSHRs
GenBus read/write depth 8/8, 256-bit AXI
L1D prefetch: 2 streams, initial distance 1, adaptive max 8,
              queue 8, outstanding 8, demand reserve 2, ppg=1
DDR3: read/write queues 8/8, command queue 16,
      maximum burst train 8, bank/row swizzle off
```

The exact Verilator build tag is:

```text
bp8-mode3-carousel1-confidence0-ps2-cf0-bf1-ff0-rw1-rh0-
iw1-sw1-rd32-prf31-posted1-ram16777216-l1i16384-l1d16384-
tlb256x4-l2262144x8x8-gb8x8-
pf1x2x1x1x8x8x8x2xppg1-
ddr31x8x8x16xbt8xsw0-timing0
```

The line break is only for readability.  The build directory contains the
same fields as one string.

These measurements came from a dirty worktree based on commit
`43230abb95a6df9f4539f819920ff19e589090d3`.  The source-matched swizzle A/B
used the same worktree and changed only the elaborated swizzle parameter, but
the full patch is not identified by the base commit.  Until the DDR changes
are committed, the result is locally reproducible from the existing build
directories and logs rather than from the Git commit alone.

The current frontend contains eight 32-byte fetch blocks split into two
banks: four direct demand-populated entries and four associative ingress
entries.  Responses enter the ingress bank before promotion.  RAS and FAL
are independent request-owner tags rather than fixed resident slots, so two
FAL halves from back-to-back branch contexts can coexist.  This is materially
newer than the frontend described by the archived HPI reference.

### gem5 HPI page-free proxy

The HPI run uses:

```text
gem5 25.1.0.1, pinned commit
51edbbb9cfd37e92e9901aea2caa4a8f20eda005
starter_se.py, --cpu=hpi, one core, 1 GHz
128 MiB, one DDR3_1600_8x8 channel
system.cpu_cluster.cpus[0].enableIdling=False
```

The idling override avoids a gem5 25.1 activity-recorder underflow; it is not
an HPI performance option.  The generated page-free
[`config.ini`](../../sim/a53/gem5-hpi-pagefree-core-65536/config.ini) is the
authority for the resolved parameters.

## Test and harness differences

| Property | OpenRV64 bare proxy | gem5 HPI proxy | OpenRV64 Linux phase |
| --- | --- | --- | --- |
| ISA | RV64, uncompressed instructions | AArch64 | RV64 Linux kernel |
| Code source | Handwritten loop matching the measured kernel instruction order and 32-byte alignment | Handwritten semantic translation | Compiler-generated `__free_pages_core` in `vmlinux` |
| Steady instructions per record | 8 | 7 | 8 |
| Memory operations per record | One 64-bit load, one 32-bit store, one dependent 64-bit store | Same widths, offsets, and dependency | Same as bare RV64 proxy |
| Descriptor layout | Static 64-byte records in the image | Same static record contents and layout | Real Linux `struct page` array |
| Quick/full footprint | 8,192 / 65,536 records; 512 KiB / 4 MiB | Same | Real invocation; the sampled plateau is not an exact fixed-record ROI |
| Execution environment | Bare M-mode RTL harness | gem5 syscall-emulation starter | OpenSBI plus full Linux, S-mode |
| Translation | Bare physical addresses; Sv39 and PTW counters are zero | SE process address translation, not a modeled Linux page-table walk in the ROI | Sv39, TLBs, PTW, kernel virtual mapping |
| Prior system history | Reset, then isolated benchmark | Process startup, then `m5_reset_stats` | About ten million boot cycles precede the phase |
| Other software traffic | None | None in the ROI | Single hart, but real kernel initialization and its retained cache/controller state |
| Initial descriptor contents | Embedded in the image; no measured warm-up pass | Identical embedded contents; no measured warm-up pass | Produced and consumed by Linux initialization |
| ROI start | `mcycle`/`minstret` immediately before the loop | `m5_reset_stats` immediately before the loop | 250,000-cycle progress intervals while the retired PC remains in the function |
| ROI end | Register snapshot at `pagefree_drain_end` | `m5_dump_stats` at loop end | Sample boundaries, not function entry/exit instrumentation |
| Store ordering after ROI | `fence rw,rw`, reported separately; 14 cycles in these runs | `dmb sy`, reported separately; 2 cycles | Included in surrounding kernel execution, not isolated |
| Correctness | `bench-pagefree` stops before verification; `sim-pagefree` separately verifies all records and reports PASS | Verification after stats reset, then `m5_exit`; failure uses `m5_fail` | Linux continues booting; no per-record microbenchmark check |
| Simulator | Cycle-driven Verilated RTL and explicit cache/bus/controller RTL | gem5 event-driven MinorCPU, cache, crossbar, and MemCtrl models | Verilated full platform RTL |
| Comparable quantity | Cycles per record; IPC within RV64 runs | Cycles per record; IPC within AArch64 runs | Interval IPC and derived cycles per iteration |

The proxy sources are
[`sw/pagefree/pagefree.S`](../../sw/pagefree/pagefree.S) and
[`sw/arm_a53/pagefree_se.S`](../../sw/arm_a53/pagefree_se.S).  Their current
SHA-256 values are:

```text
a097f297b1e8299470b20ca76153e23907843a1768fc79eadcaffca7bf7b9826  sw/pagefree/pagefree.S
4ecc76335446eb6cfddbd3047dc6d3364f5d4584966fdb694106e860c09e45f6  sw/arm_a53/pagefree_se.S
```

The loop instruction-count difference is exact:

```text
OpenRV64 full: 524,291 = 65,536 * 8 + 3
HPI full:      458,756 = 65,536 * 7 + 4
```

Consequently, HPI's lower IPC is partly an ISA/code-shape effect.  It cannot
be read as lower useful throughput without also examining cycles per record.

## Page-free results

### Fixed-work proxy comparison

| Records | Model | Bank swizzle | Cycles | Retired | IPC | Cycles/record |
| ---: | --- | :---: | ---: | ---: | ---: | ---: |
| 8,192 | OpenRV64 RTL | on | 120,580 | 65,539 | 0.5433 | 14.718 |
| 8,192 | gem5 HPI | off/plain | 309,632 | 57,348 | 0.1852 | 37.797 |
| 65,536 | OpenRV64 RTL | off/plain | 1,477,021 | 524,291 | 0.3550 | 22.538 |
| 65,536 | OpenRV64 RTL | on | 1,287,283 | 524,291 | 0.4073 | 19.642 |
| 65,536 | gem5 HPI | off/plain | 2,904,986 | 458,756 | 0.1579 | 44.327 |

For the fixed semantic work:

- The reference plain-map OpenRV64 result is 1.967 times faster for 65,536
  records.
- The swizzled full result is 2.257 times faster, but is an experimental
  controller result rather than the reported reference.
- The 8,192-record OpenRV64 result is also swizzle-on and therefore remains
  experimental until a plain-map quick run is recorded.
- HPI cycles per record worsen by 17.28% from the quick to the full case.
- OpenRV64 swizzled cycles per record worsen by 33.45%.

The last two changes are not a pure working-set measurement.  Cache capacity
changes downstream traffic:

- HPI's 1 MiB L2 holds the complete 512 KiB quick array, so the quick ROI
  sends no dirty writebacks to DDR.
- OpenRV64's 256 KiB L2 holds 4,096 of the 8,192 quick lines and sends about
  4,096 dirty writebacks.
- In the 4 MiB full case, HPI retains about 16,384 lines and writes back about
  49,152; OpenRV64 retains about 4,096 and writes back about 61,440.

### Traffic and prefetch behavior

| Counter | ORV quick, swizzle | HPI quick | ORV full, swizzle | HPI full |
| --- | ---: | ---: | ---: | ---: |
| DDR reads | 8,195 | 8,195 | 65,539 | 65,539 |
| DDR writes | 4,103 | 0 | 61,447 | 49,153 |
| Prefetch issued | 8,199 | 8,194 | 65,543 | 65,538 |
| Prefetch useful | 8,191 | 4 | 65,535 | 4 |
| Prefetch useful percent | 99.90% | 0.05% | 99.99% | 0.01% |
| Prefetch late | 2,898 useful | 130 | 24,807 useful | 1,026 |
| Approximate DDR data-bus utilization | 50.95% | 13.24% | 49.32% | 19.74% |

The counter taxonomies are not identical.  In particular, gem5 reports
7,803 quick and 62,459 full prefetches as removed by demand; OpenRV64 calls a
prefetch late when demand reaches an outstanding prefetch MSHR, and all such
lines in these runs later prove useful.  The table is strong evidence that
the HPI stream is demand-latency/concurrency limited and that OpenRV64 gets
farther ahead.  It is not evidence that the physical DDR3 channel is
saturated: HPI reports only 19.74% bus utilization in the full run.

The utilization counters are also only approximately comparable.  HPI uses
gem5 MemCtrl's `busUtil`; OpenRV64 divides explicit shared-data-bus busy
cycles by timing-model cycles.

### Relation to the Linux plateau

The current Linux report measures a stable mean interval IPC of 0.141241.
At eight instructions per iteration, that is about 56.64 cycles per
descriptor:

| Environment | Instructions/record | IPC | Cycles/record |
| --- | ---: | ---: | ---: |
| OpenRV64 full Linux plateau, pre-swizzle build | 8 | 0.141241 | 56.64 |
| OpenRV64 bare full proxy, plain-map reference | 8 | 0.3550 | 22.54 |
| gem5 HPI full SE proxy | 7 | 0.1579 | 44.33 |

This table is diagnostic, not a causal A/B test.  The Linux binaries were
built before the swizzle was added, and the latest bare proxy was built after
DDR and frontend changes.  Linux also adds Sv39, real physical backing,
platform integration, and boot history.  The evidence therefore establishes
the gap but does not assign it to translation, placement, cache state,
prefetch qualification, store pressure, or DDR mapping.

## Hardware and model differences

The following table covers the performance-relevant macroarchitecture,
cache, interconnect, and memory parameters used by these tests.  It does not
claim that gem5's abstract internal queues correspond one-for-one to physical
Cortex-A53 structures.

| Area | OpenRV64 configuration | gem5 HPI configuration | Consequence for interpretation |
| --- | --- | --- | --- |
| Implementation level | Synthesizable RTL plus transaction-level DDR timing endpoint | MinorCPU timing model plus gem5 cache/crossbar/MemCtrl objects | HPI queue/stage names are model abstractions; ORV cycles expose RTL handshakes |
| ISA | Current integer RV64 core with optional A/M; no integrated C/F/D/RVV in this result | ARMv8-A AArch64 model with HPI integer and FP/SIMD functional units | Page-free is integer-only, but general hardware scope differs |
| Frontend width | Up to 3 decode lanes | Decode input width 2 | Peak IPC and instruction grouping differ |
| Fetch buffering | Four direct 32-byte demand blocks plus four associative 32-byte ingress blocks; FA3 previews and two branch-pair contexts | Fetch1/Fetch2 line and macro-op buffers in MinorCPU | There is no direct carousel equivalent in HPI |
| Issue/commit width | Up to 3-wide strict-prefix dispatch/retirement, subject to port and ordering rules | Issue 2, commit 2 | Width alone does not imply out-of-order execution |
| Memory issue/commit | RTL LSU/LSQ path with port, ordering, and speculation eligibility | Memory issue limit 1, memory commit limit 1, early memory issue enabled | The HPI scalar limits have no one-parameter RTL equivalent |
| Instruction window | RD32 tagged issue/retire state, issue/speculation enabled; PRF31 is identity-mapped, not register renaming | Execute input buffer 7 and in-order in-flight/scoreboard machinery | Neither tested machine is a conventional renamed out-of-order core |
| Dependency handling | Local completion/branch forwarding plus persistent tagged readiness; older ordering restrictions remain | Latency-aware scoreboard and HPI per-op forwarding timings | CoreMark and dependency-heavy code need separate measurement |
| Branch direction predictor | BP8: global 2,048 x 3-bit with 11-bit history; local history 512 x 10-bit and PHT 1,024 x 3-bit; chooser 512 x 2-bit | Tournament: global 1,024 x 2-bit; local history/PHT 64 x 2-bit; chooser 1,024 x 2-bit | ORV has larger global/local state but a smaller chooser; update behavior is also different |
| Target prediction | BTB 256, direct-mapped, RAS 8; FAL branch-side previews | BTB 128, direct-mapped, RAS 8, plus a 256-set 2-way indirect predictor | Return depth matches; other target mechanisms do not |
| L1I | 16 KiB, 4-way, 64-byte lines; 4 demand MSHRs and 8 fill buffers | 32 KiB, 2-way, 64-byte lines; 2 MSHRs, 8 targets/MSHR | Capacity, associativity, and miss concurrency differ |
| L1D | 16 KiB, 8-way, 64-byte lines; 3 demand MSHRs, 8 fill buffers, 8-line store buffer | 32 KiB, 4-way, 64-byte lines; 4 MSHRs, 8 targets/MSHR, 4 write buffers | ORV has half the capacity but more explicit store buffering |
| L1D prefetch | Two stream records; initial distance 1; adaptive max 8; queue 8; 8 outstanding; 2 demand-reserved IDs; 4 KiB probation gating | Stride prefetcher, degree 4, queue 4, 64-entry 4-way table, physical-address mode, 4 KiB page stop | This is the largest observed page-free behavior difference |
| L2 | 256 KiB, 8-way, 64-byte lines; 8 MSHRs and 8 waiters/MSHR | 1 MiB, 16-way, 64-byte lines; 4 MSHRs, 8 targets/MSHR, 16 write buffers; tag/data latency 13, response 5 | HPI gets four times the capacity; ORV exposes twice the L2 miss concurrency |
| Translation | Private small TLB path plus shared 256-entry 4-way L2 TLB and RTL PTW; bypassed in bare proxy | SE translation in this test; not a Linux PTW workload | Bare proxy translation results are not Linux results |
| Core-to-L2 transport | 512-bit/64-byte CCX lines | 64-byte-wide `toL2Bus`, frontend/response latency 1 | Nominal line movement is wide in both, but protocols and arbitration differ |
| L2-to-memory transport | GenBus/AXI 256-bit; each 64-byte line is two AXI beats | gem5 memory crossbar width 16 bytes with frontend 3, forward 4, response 2 cycles | Northbound packetization and latency are not matched |
| DDR data interface | One 64-bit channel, BL8, two ranks, eight banks/rank | Same nominal device/channel organization | Raw data width and burst size are aligned |
| Controller queues | GenBus 8 read/8 write, AXI DDR 8/8, timing command queue 16, 8 timing owners | MemCtrl read buffer 32, write buffer 64 | HPI has deeper controller queues, but the CPU/cache path may not feed them |
| DDR scheduling | Dependency-safe read/write reordering, independent bank preparation, shared data bus, adjacent burst trains up to 8 | FR-FCFS, open-adaptive page policy | Algorithms and command grouping differ even with matched device timings |
| Address mapping | Reference: plain `RoRaBaCo`; experimental Linux: optional `bank ^= low_row_bits` | Plain `RoRaBaCoCh` | Reported ORV results use plain mapping; swizzled results are labeled experiments |
| Coherence/platform | This benchmark is single-hart through local CCX/L2 RTL | One HPI CPU and classic-cache hierarchy | Neither result exercises a multicore A53 coherent cluster |

For exact HPI functional-unit latencies and timing expressions, use the saved
`config.ini` rather than treating the summary table as exhaustive.

## DDR3 timing alignment and remaining differences

The OpenRV64 DDR3 preset was changed to match gem5's
`DDR3_1600_8x8` device timing:

| Parameter | Both nominal configurations |
| --- | ---: |
| Controller clock | 1.0 ns |
| DRAM `tCK` | 1.25 ns |
| `tRCD`, `tRP`, `tCL`, `tCWL` | 13.75 ns |
| `tRAS` | 35 ns |
| `tWR` | 15 ns |
| `tRTP`, `tWTR` | 7.5 ns |
| `tRTW`, rank `tCS` | 2.5 ns |
| `tRRD` | 6 ns |
| `tXAW` | 30 ns; four-activation limit |
| `tRFC` | 260 ns |
| `tREFI` | 7.8 us |
| Frontend/backend controller delay | 10 ns / 10 ns |
| Row policy limit | 16 accesses per row |
| Rank/bank geometry | 2 ranks, 8 banks/rank, aggregate 8 KiB row |
| Native transfer | 64-bit DQ, BL8, 64 bytes in 5 ns |

Matching this parameter list does not make the controllers equivalent.
OpenRV64 has a different request path, queue depths, dependency checks,
turnaround scheduler, refresh arbitration, response timing, and burst-train
implementation.  It is a transaction-level timing model, not a pin-level
DDR PHY or a validated copy of gem5 MemCtrl.

## Bank/row swizzle

The OpenRV64 timing endpoint now optionally maps:

```text
physical_bank = raw_bank XOR low_bits(row)
```

The architectural address, L2 tag, cache-line data, and backing-memory
storage address are unchanged.  Only the timing model's rank/bank/row
selection changes.  The generic timing engine defaults to off; the
OpenRV64 bare benchmark preset defaults to off, while the OpenSBI/Linux
platform preset defaults to on for boot-time tuning.

The source-matched 65,536-record A/B result is:

| Counter | Swizzle off | Swizzle on | Change |
| --- | ---: | ---: | ---: |
| Loop cycles | 1,477,021 | 1,287,283 | -189,738 (-12.85%) |
| IPC | 0.3550 | 0.4073 | +14.74% |
| DDR bus-busy cycles | 634,920 | 634,930 | effectively unchanged |
| Bank-wait cycles | 648,137 | 443,632 | -31.55% |
| Row hits | 110,404 | 118,893 | +7.69% |
| Row misses | 16,583 | 8,099 | -51.16% |
| Row conflicts | 479 | 63 | -86.85% |
| Maximum simultaneously busy banks | 2 | 3 | +1 |
| Direction switches | 15,361 | 21,003 | +36.73% |
| Burst trains | 16,845 | 31,224 | +85.36% |
| Eight-burst trains | 14,903 | 869 | -94.17% |

The result is not “longer bursts made it faster.”  Swizzling breaks up the
very long same-bank trains, raises bank-level parallelism, and reduces row
preparation wait while total data-bus occupancy stays constant.  The changed
completion timing also changes some frontend/lookaside event counts, so the
189,738-cycle reduction cannot be assigned one-for-one to the aggregate
`bank_wait` delta.  The causal hardware difference is nevertheless isolated
to the address-map parameter in this A/B pair.

This gain is realistic only if a physical memory controller uses the same
address mapping.  The RTL cost of the mapping itself is approximately three
XOR functions for an eight-bank channel, but no synthesis or timing run has
measured the current implementation.  The current result must therefore be
reported as a modeled-controller gain, not as free silicon performance.

## HPI versus Cortex-A53 hardware

gem5 documents MinorCPU as a four-stage, in-order CPU model and HPI as an
ARMv8-A configuration of it.  Those four simulation stages are not a
four-stage Cortex-A53 pipeline diagram.  Arm describes Cortex-A53 as an
in-order, limited-dual-issue Armv8-A core with an 8-to-11-stage pipeline.
Arm also documents configurable L1 and L2 sizes, so the particular 32 KiB
L1s and 1 MiB L2 used here are legal A53-class choices, not universal A53
properties.

Primary references:

- [gem5 MinorCPU interface and four-stage organization](https://gem5.googlesource.com/public/gem5/%2B/6719ad32014fd1379eaa6b5af18057a48679bb51/src/cpu/minor/cpu.hh)
- [gem5 HPI configuration source](https://gem5.googlesource.com/public/gem5/%2B/1d03f6de941520860c673b5f7954c82a46e8b191/configs/common/cores/arm/HPI.py)
- [gem5 MinorCPU documentation](https://gem5.googlesource.com/public/gem5-website/%2B/8b2140126ae476cef25e873d688ff57e3f4472e4/_pages/documentation/general_docs/cpu_models/minor_cpu.md)
- [Arm CPU architecture comparison](https://developer.arm.com/-/media/Files/pdf/graphics-and-multimedia/ARM_CPU_Architecture.pdf)
- [Arm Cortex-A comparison table](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/Cortex-A%20R%20M%20datasheets/Arm%20Cortex-A%20Comparison%20Table_v4.pdf?hash=C816A56372483062F01ABFCFB500CDAF46CD82B3&revision=7c836998-353a-4601-80c3-d0f76021ae17)

There is no defensible current area comparison:

- the saved OpenRV64 mapped-area report uses an older frontend, predictor,
  retirement depth, and cache configuration;
- it excludes major SRAM arrays from the standard-cell total;
- it has no placed-and-routed frequency; and
- HPI provides no physical A53 netlist or layout.

The older OpenRV64 area numbers in
[`physical/size.md`](../physical/size.md) remain useful for block-level
orientation, not for claiming area or performance-per-area against A53.

## Historical CoreMark-derived result

The archived
[`a53_proxy_reference.md`](a53_proxy_reference.md) reported a finite
CoreMark-derived state-machine loop:

| Snapshot | Cycles | Retired | IPC |
| --- | ---: | ---: | ---: |
| gem5 HPI AArch64 | 72,146 | 58,695 | 0.8136 |
| old OpenRV64 3P RV64 | 185,775 | 52,547 | 0.2829 |

That result used common C semantics but different ISA binaries.  More
importantly, it predates BP8, the current eight-block frontend, the current
cache/prefetch path, RD32, and the DDR changes.

Do not combine HPI's saved 72,146-cycle result with the newer 55,398-cycle
OpenRV64 RD32 number in [`current.md`](current.md) as if they were a matched
A/B pair.  The archived HPI source SHA is
`adec2749...`; the newer OpenRV64 source SHA is `25587cab...`.  A current
CoreMark-derived comparison requires rebuilding and rerunning both models
from the same source and frozen RTL snapshot.

This matters because page-free and CoreMark exercise different limits.
Page-free is a regular memory stream with almost no control uncertainty.
CoreMark-derived state parsing is branch- and dependency-heavy and has very
few data-cache misses.  Neither ratio predicts the other.

## Reproduction

Run the reported OpenRV64 quick plain-map proxy:

```sh
make bench-pagefree \
    PAGEFREE_KERNEL=core \
    PAGEFREE_RECORDS=8192 \
    PAGEFREE_DDR3=1 \
    PAGEFREE_REQUIRE_ARGS=+require_timed_memory \
    PAGEFREE_L1D_PREFETCH_MAX_DISTANCE=8 \
    CORE_3P_CCX_L2_L1D_PREFETCH_QUEUE_LINES=8 \
    CORE_3P_CCX_L2_L1D_PREFETCH_OUTSTANDING=8 \
    CORE_3P_CCX_L2_L1D_PREFETCH_DEMAND_RESERVE=2 \
    CORE_3P_CCX_L2_L1D_PREFETCH_PAGE_GATING=1 \
    CORE_3P_CCX_L2_GENBUS_READ_DEPTH=8 \
    CORE_3P_CCX_L2_GENBUS_WRITE_DEPTH=8 \
    CORE_3P_CCX_L2_DDR3_MAX_BURST_TRAIN_BURSTS=8 \
    CORE_3P_CCX_L2_DDR3_BANK_ROW_SWIZZLE=0
```

Use `PAGEFREE_RECORDS=65536` for the full proxy.  Set
`CORE_3P_CCX_L2_DDR3_BANK_ROW_SWIZZLE=1` only for the separately labeled
hashed-bank experiment.  Keep all other command-line variables unchanged;
the build tag includes them to prevent accidental binary reuse.

Run gem5 HPI:

```sh
make sim-pagefree-a53-gem5 \
    PAGEFREE_KERNEL=core \
    PAGEFREE_RECORDS=8192 \
    A53_PAGEFREE_OUTDIR=sim/a53/gem5-hpi-pagefree-core-8192

make sim-pagefree-a53-gem5 \
    PAGEFREE_KERNEL=core \
    PAGEFREE_RECORDS=65536 \
    A53_PAGEFREE_OUTDIR=sim/a53/gem5-hpi-pagefree-core-65536
```

The saved HPI reports are:

- [`sim/a53/gem5-hpi-pagefree-core-8192/report.txt`](../../sim/a53/gem5-hpi-pagefree-core-8192/report.txt)
- [`sim/a53/gem5-hpi-pagefree-core-65536/report.txt`](../../sim/a53/gem5-hpi-pagefree-core-65536/report.txt)

The Make targets and measurement boundaries are defined in
[`scripts/make/pagefree.mk`](../../scripts/make/pagefree.mk).

## Rules for future comparisons

1. Freeze the RTL commit or record the dirty-worktree patch and full build
   tag.
2. Record both source hashes and verify the result outside the ROI.
3. Compare fixed semantic work by cycles/record, not cross-ISA IPC.
4. Report L1/L2 capacity and resulting DDR reads and writes with every
   streaming result.
5. Report prefetch issued, useful, late, demand-promoted, dropped, and
   useless counts, with each model's definitions.
6. Match DDR geometry and timing, then state controller queue, scheduling,
   burst, and address-map differences separately.
7. Keep bare physical, Sv39 proxy, full Linux, and gem5 SE results in separate
   rows.  Do not use a fast bare proxy to explain a Linux plateau without a
   source-matched intermediate test.
8. Do not claim Cortex-A53 performance, area, power, or frequency from HPI.
