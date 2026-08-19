# Current performance baseline

Date: 2026-08-19

This document records the current Linux-profile CoreMark-derived baseline, the
last pre-512-bit STREAM baseline, a completed-control release experiment, and
the 2026-07-26 CoreMark/STREAM comparison matrix below them.
"Best-known" describes selected knobs; it does not mean the resulting
performance is good or globally optimal. No exhaustive parameter sweep was
performed.

These are cycle-model results, not frequency measurements. The CoreMark
workload is the finite branch-heavy loop in `sw/coremark_loop.c`, not the full
CoreMark suite, and it does not produce a valid CoreMark/MHz score.

## Current Linux-profile RD32 baseline

The 2026-08-19 CoreMark baseline maps the one-hart Linux performance profile
onto the Sv39 performance harness. The table describes that current CoreMark
configuration. The retained STREAM results predate the 512-bit fetch delivery
and conditional-branch release changes; their exceptions are identified below.

| Area | Baseline setting |
| --- | --- |
| Harness | one hart, non-coherent `tb_top_3p_soc` |
| Address translation | Sv39; workload executes in supervisor mode |
| Predictor / fetch | BP8; mode 3; carousel 1; confidence gate 0; two FAL/pair-stack slots; 512-bit L1I-to-fetch delivery; predicted redirects override sequential requests and launch a same-edge target demand |
| Forwarding / hazards | completion mask 0; branch mask 1; full forwarding 0; WAW relaxation 1; general hazard relaxation 0 |
| Issue / retirement | issue window 1; speculation 1; retirement and window depth 32; 31 physical registers |
| Memory ordering | posted stores 1; L2 fence acknowledgment 0; `RESULT_READY_CONTROL_RELEASE=1` |
| L1 caches | 16 KiB L1I and 16 KiB L1D; synchronous L1D tag lookup and store extension enabled |
| L2 / shared TLB | 256 KiB, 8-way L2 with 8 merge entries; 256-entry, 4-way L2 TLB |
| GenBus | read depth 8; write depth 8 |
| L1D prefetch | enabled; M/BARE enable 1; 2 streams; initial distance 1; adaptive maximum 4; queue/outstanding/reserve 4/4/2; page gating 1 |
| DDR3 model | banked DDR3 and timed memory enabled; read/write/command queues 8/8/16; burst train 8; bank-row swizzle 0; timing model 0 |
| Backing RAM | 16 MiB |
| STREAM working set | 64 KiB per array (`STREAM_BYTES=65536`) |
| Managed configurations | `run/cfg/coremark-sv39-linux-rd32-ddr3.cfg`; retained STREAM data used `run/cfg/stream-sv39-linux-rd32-ddr3.cfg` at its recorded snapshot |

This is a per-core and memory-profile match, not a topology-identical Linux
run. The benchmark uses the one-hart, non-coherent `tb_top_3p_soc` performance
harness; Linux uses the four-hart coherent harness with harts 1-3 held in
reset and 256 MiB of installed RAM. The benchmark harness retains its 16 MiB
backing RAM. The workload also retains its existing RV64I compiler profile;
this is not a Linux userspace binary benchmark.

### CoreMark-derived loop

| Cycles | Retired | IPC | Result |
| ---: | ---: | ---: | --- |
| **47,577** | 52,592 | **1.1054** | `a0=0x000000000a277880` |

This is the current 512-bit, mode-3, two-slot baseline, including the
generalized same-edge predicted-redirect demand path. Redirect demand has
strict priority over the sequential request; this does not add a second fetch
address or downstream port. The run reported
`satp_sv39=1`, supervisor execution, passing instruction/data alias checks,
`timed_memory=1`, and timing model 0. The corrected older-store dependency
counter remained zero. DDR3 handled 46 read and 11 write bursts as 57 commands;
the command queue, timing-owner set, and L2 MSHRs each reached five entries.

The last source-matched width comparison, immediately before generalizing the
redirect sideband, was 54,601 cycles at 256 bits versus 48,523 at 512 bits.
That pair isolates the width change: 6,078 cycles (11.13%), frontend-empty
cycles from 27,355 to 17,120, and post-redirect empty cycles from 23,291 to
14,905. It is not the current-RTL result.

Relative to the immediately preceding 48,523-cycle 512-bit control, extending
the RAS-only replacement demand to every predicted redirect removed another
946 cycles (1.95%), reduced frontend-empty cycles from 17,120 to 14,491, and
reduced post-redirect empty cycles from 14,905 to 11,896. The recorded source
inputs changed only `rv64_top_3p.v`, `fetch_3w.v`, and its passive debug stub;
the control also enabled the output-only `+fetch_demand_trace` plusarg. This
still does not prove a realizable timing point: the same-edge combinational path
through line selection, predecode/prediction, target generation, and request
selection needs synthesis and physical timing evidence.

The current baseline completed with simulator exit 0 and validation `pass`:

```text
run_id=coremark-sv39-linux-rd32-ddr3-20260819T120611Z
config=run/cfg/coremark-sv39-linux-rd32-ddr3.cfg
log=run/log/coremark-sv39-linux-rd32-ddr3-20260819T120611Z/run.log
git_head=2b77e300ff9354e62a9db8af094a9ff5fc95d422
f2b5a8d4f8713d22791f5e71f48117284ef9bf7253a5576afbc51cef3ecb0afc  sim/coremark-loop-vm.elf
1d4f66f6b482b4e5ea8cc1cf79b86049b8eaf45a96b658b296726233a0e7052b  sim/coremark-loop-vm.bin
68583b052a983abd41c490210070292af85d7549a2dfd91d257b4834095660ee  sim/coremark-loop-vm.memh
e63b426e86a2c5f1a0dbab5991051067bd5327fcc1dfe11a0c1d947de389a298  sim/coremark-loop-vm.disasm
146a569a2177dffd5a056df9a73e5a9616034c4ac7135bc19eb0850198fd5777  core_3p_icx_l2_tb
```

The worktree was dirty. The run directory captures `git-status.txt`,
`worktree.patch`, the effective configuration, source hashes, and snapshots of
the workload and simulator. The commit hash alone does not reproduce the
measured RTL.

The pre-generalized-redirect, source-matched FAL mode sweep was nearly flat:

| FAL mode | FAL slots | Cycles | IPC | Delta from mode 3 |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 2 | 48,615 | 1.0818 | +92 (+0.19%) |
| 1 | 2 | 48,571 | 1.0828 | +48 (+0.10%) |
| 2 | 2 | 48,571 | 1.0828 | +48 (+0.10%) |
| **3** | **2** | **48,523** | **1.0839** | -- |

At that same pre-generalized-redirect source, an eight-slot mode-3 experiment
reached 48,252 cycles (0.56% faster than its two-slot control). It is not
evidence for eight slots under current RTL. The current configuration remains
mode 3 with two slots.

### Retained pre-512-bit STREAM baseline (2026-08-18)

These STREAM results used the earlier 256-bit L1I-to-fetch path and pre-sideband
completed-control policy. They are retained as the latest complete four-kernel
set, not presented as configuration-matched to the current CoreMark result.

STREAM's kernel cycles are measured by the workload between its cycle-counter
reads. Measurement-stop cycles include Sv39 bootstrap and setup through
`stream_measure_end`. Payload rate counts one read plus one write for copy and
scale, and two reads plus one write for add and triad.

| Kernel | Kernel cycles | Measurement-stop cycles | Retired at stop | IPC at stop | Payload | Payload rate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Copy | **29,245** | 29,915 | 20,530 | 0.6863 | 128 KiB | **4.4819 B/cycle** |
| Scale | **35,619** | 36,289 | 41,010 | 1.1301 | 128 KiB | **3.6798 B/cycle** |
| Add | **61,085** | 61,756 | 43,060 | 0.6973 | 192 KiB | **3.2186 B/cycle** |
| Triad | **60,616** | 61,287 | 59,444 | 0.9699 | 192 KiB | **3.2435 B/cycle** |

All four measurement runs reported Sv39 and timing model 0. Separate
full-result executions returned `a0=0x53545245414d4f4b` (`STREAMOK`) after
56,378, 71,042, 112,205, and 114,903 cycles respectively. The forced baseline
build captured `dispatch_window_3p.v` hash
`fd08288b04897f69d66beb8d6c8e5e95c78952ed3df28fc84db3778421577b42`
and simulator hash
`3a1428fe346be2b9836aba052c4c902e54791f87f33b3f5e02c4429773f2ffbd`.

```text
copy  stream-sv39-linux-rd32-ddr3-20260818T143429Z
scale stream-sv39-linux-rd32-ddr3-20260818T143651Z
add   stream-sv39-linux-rd32-ddr3-20260818T143652Z
triad stream-sv39-linux-rd32-ddr3-20260818T143651Z-3926674
```

### Completed-control release mechanism

`dispatch_window_3p.v` stops treating older control as live once its resident
issue-window `result_ready_q` bit is set. Safe register-writing completions set
the bit for direct JALs. Conditional branches now receive a separate tagged
EX1-resolution sideband carrying valid, instruction ID, and retirement slot;
the window queues that one-cycle resolve event in `result_ready_q` until the
branch retires or is squashed.

The compile-time policy seam is
`OPENRV64_3P_RESULT_READY_CONTROL_RELEASE`. The managed performance harness
sets it through `CORE_3P_ICX_L2_RESULT_READY_CONTROL_RELEASE`, includes the
value in the Verilator build-directory key, records it in the effective
configuration, and prints it in the `PERF_ICX_L2` header. Value 1 selects:

```verilog
older_live_control = !result_ready_q[older_idx];
```

Value 0 keeps every resident branch/JAL live until window removal. The default
macro value is 1.

The following CoreMark-derived comparison predates the conditional-resolution
sideband. It exercised only controls that already produced safe register-write
completions and must not be treated as a current estimate of the new policy:

| Configuration | Cycles | Retired | IPC | Delta from baseline |
| --- | ---: | ---: | ---: | ---: |
| Baseline: control live until window removal | 55,799 | 52,592 | 0.9425 | -- |
| Experiment: release at result ready | **55,600** | 52,592 | **0.9459** | **-199 (-0.36%)** |

```text
run_id=coremark-sv39-linux-rd32-ddr3-20260818T141157Z
source dispatch_window_3p.v=560f57f768e90f4a6f6c2ebe7f2de63e910e1a517f531e665cd8b05f527bd679
simulator=ec45aa42b39f0f22530c78af09234131a72cbfcebf856ecf1c1f3763645a47e2
validation=pass
```

The main counter changes were:

| Counter | Baseline | Experiment | Delta |
| --- | ---: | ---: | ---: |
| Frontend empty | 28,122 | 27,935 | -187 |
| Dispatch nonempty, no issue | 21,067 | 20,809 | -258 |
| Window nonempty, no eligible instruction | 15,954 | 15,664 | -290 |
| Window RAW-stall predicate | 13,211 | 12,505 | -706 |
| Window hard-stall predicate | 10,667 | 10,277 | -390 |
| Window memory-order predicate | 4,005 | 3,478 | -527 |
| Retirement head incomplete | 22,711 | 22,451 | -260 |
| Completed behind incomplete head | 12,477 | 11,869 | -608 |
| LSU request wait | 1,455 | 1,533 | +78 |
| Explicit DDR read-timing wait | 270 | 0 | -270 |
| Direction corrections | 864 | 862 | -2 |
| Branch-aborted loads / stores | 314 / 0 | 278 / 6 | -36 / +6 |

The intended memory-order predicate fell by 527 cycles, but that is not a
527-cycle isolated gain: the overlapping scheduler predicates also changed,
LSU request wait increased, and the changed request phase eliminated 270
cycles of explicit DDR admission delay while preserving the same 44 reads and
11 writes. External ICX/L2 traffic was otherwise unchanged. Loads blocked by
older stores remained zero.

Those pre-sideband runs passed focused regressions, but they are superseded as
functional evidence for conditional controls. The current tagged resolve path
passes `sim-dispatch-window-3p`, `sim-backend-3p`, and `sim-top-3p`; the current
CoreMark baseline above also passed with the sideband enabled. The retained
STREAM table has not been refreshed after the sideband change.
Feeding `result_ready_q` into the all-pairs issue-eligibility cone also still
requires synthesis timing evidence.

#### Pre-sideband STREAM control comparison

The old JAL-only completed-control release was also forced-built and run for
all four STREAM kernels under the recorded pre-512-bit STREAM configuration.
Baseline and experiment produced identical kernel cycles, measurement-stop cycles,
full-result cycles, and every reported `PERF_ICX_L2` counter. This comparison
predates the conditional-resolution sideband and has not been refreshed.

The experimental runs were `20260818T142706Z`, `20260818T142708Z`,
`20260818T142709Z`, and `20260818T142710Z`; they captured
`dispatch_window_3p.v` hash
`560f57f768e90f4a6f6c2ebe7f2de63e910e1a517f531e665cd8b05f527bd679`
and simulator hash
`ec45aa42b39f0f22530c78af09234131a72cbfcebf856ecf1c1f3763645a47e2`.

The retained 2026-08-18 STREAM set is much faster than the older recorded points,
but that is not an RD16-versus-RD32 result: the older 38.5k/92.3k points in
the historical table below were explicitly RD32. They are an unmatched
configuration comparison and did not use the complete current Linux-profile
controls, including the current GenBus depth.

#### Directed completed-control/load microbenchmark

`sw/branch-gated-load/branch_gated_load.S` isolates the policy seam. It walks
a 128 KiB cache-line stream 16 times (32,768 read-only loads). Each four-line
group starts one load, then places three more loads behind always-not-taken
conditional branches. EX1 resolves each branch and the tagged sideband queues
that resolution in its resident window entry while an older load keeps the
branch behind the retirement head. The elapsed `a0` value is stored to a
translated data word before the measurement stop, and the separate full-result
run checks the accumulated load sum and returns `BRGLD_OK`.

The directed comparison uses the RD32/Linux-profile configuration above except
that load speculation is disabled (`SPECULATION_WINDOW=0`). This exception is
required: with speculation enabled, ordinary Sv39 read-only loads are already
speculative-load candidates and do not consult `older_live_control`.

| Policy | Kernel cycles | Reset-to-stop cycles | Retired | IPC | Candidate cycles / entry-cycles | Gated cycles / entry-cycles |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Macro 0: live until removal | 324,077 | 324,749 | 114,818 | 0.3536 | 323,937 / 2,537,543 | 323,937 / 2,537,543 |
| Macro 1: release after resolve | **127,662** | **128,334** | 114,818 | **0.8947** | 127,468 / 507,356 | **0 / 0** |

The directed kernel improves by 196,415 cycles, or 60.61% (2.539x speedup).
This is an intentionally saturated upper-bound microbenchmark, not an
application-performance estimate. The gate counters establish causality:
every baseline candidate was held, while the experimental policy held none.
Both full-result runs passed the Sv39, DDR3-overlap, stored-result, and checksum
checks. The two managed runs captured identical source and benchmark images;
their effective configurations differ only in the macro value and the derived
`crr0`/`crr1` Verilator artifact path.

```text
macro 0 branch-gated-load-sv39-rd32-ddr3-20260818T165217Z
        simulator=75425d008a9cbe502e1cec5e2bd6a97b5009e620b7f8a10e99d1901d329cfd45
macro 1 branch-gated-load-sv39-rd32-ddr3-20260818T165042Z
        simulator=18c0aa1cd4a58b2a2793424b7870d55550d87b11d508515c12292eeb3c4893d8
dispatch_window_3p.v=98d1803803d6d00e8076edbc1c5b98ddc8150c659300bd64b4170746994c9dba
backend-defs.v=7b28c59a515bb6ba68cc0dfdd5d3e82c9631a8ca498641eb4b2c8197a6d6a236
branch_gated_load.S=45e6dccfafcf3c72a7197590282a13052f109c4def6519736a58bd2e4be3c510
```

As a negative control, both policies were also forced-built with
`SPECULATION_WINDOW=1` immediately before introducing the macro seam. Both
produced exactly 124,009 kernel cycles and 124,679 reset-to-stop cycles; the
counter panels were identical, and the completed-control candidate/gate
counters were zero. The live-until-removal and release run IDs were
`20260818T164555Z` and `20260818T164311Z`. This confirms that speculative Sv39
loads bypass this particular control gate; it is not a macro-plumbing test.

### Current 512-bit mode-3 critical performance-counter breakdown

All percentages in this subsection use the 47,577 reset-to-done cycles as the
denominator unless another denominator is named. Counters are not generally
additive. The RAW, hard-block, and memory-order window predicates overlap.

Average width was 1.3608 decoded, 1.1861 issued, and 1.1054 retired
instructions per cycle:

| Width | Decode cycles | Issue cycles | Retire cycles |
| ---: | ---: | ---: | ---: |
| 0 | 20,563 (43.22%) | 17,007 (35.75%) | 18,905 (39.74%) |
| 1 | 6,233 (13.10%) | 10,599 (22.28%) | 13,009 (27.34%) |
| 2 | 3,831 (8.05%) | 14,769 (31.04%) | 7,406 (15.57%) |
| 3 | 16,950 (35.63%) | 4,513 (9.49%) | 8,257 (17.36%) |
| 4 | n/a | 689 (1.45%) | n/a |

#### Frontend and redirects

| Counter | Cycles/events | Fraction of run where cycle-based |
| --- | ---: | ---: |
| Fetch output empty | 14,491 cycles | 30.46% |
| Fetch held by decode | 6,072 cycles | 12.76% |
| Total zero-decode cycles | 20,563 cycles | 43.22% |
| Empty: control flush/redirect | 191 cycles | 0.40% |
| Empty: refill/pending state | 14,030 cycles | 29.49% |
| Empty: no line available | 270 cycles | 0.57% |
| Fetch request-channel wait | 91 cycles | 0.19% |
| External-miss empty | 585 cycles | 1.23% |
| Pending without external miss | 13,638 cycles | 28.67% |
| Redirects | 8,133 events | n/a |
| Post-redirect empty | 11,896 cycles | 25.00% |
| Post-redirect critical empty | 713 cycles | 1.50% |

The three `Empty:` reason rows are an exclusive partition of the 14,491 fetch
empty cycles. The request-channel wait counter is separate. Dispatch remained
nonempty for 13,688 empty cycles (94.46% of empty time), so most frontend
emptiness was hidden by older backend work. Only 585 empty cycles coincided
with an external L1I miss; 13,638 were pending with no external miss. The
dominant counted state is therefore internal fetch/refill handoff, not DDR
latency.

The run resolved 10,786 conditional branches and recorded 942 direction
corrections: an 8.73% correction rate, or 17.91 corrections per 1,000 retired
instructions. It recorded 419 lookaside restart hits. Post-redirect empty time
was 1.463 cycles per redirect overall: 10,128 cycles after predicted redirects,
1,379 after corrections, and 389 after restarts. Only eight empty cycles
followed a lookaside hit; 11,888 followed a miss.

The legacy `PERF_ICX_L2_STASH_STALL`, `STASH_OFFSET`, and `STASH_SECTOR`
breakdowns are not exact under 512-bit fetch delivery: their tracker still
classifies 32-byte lines/sectors. The aggregate fetch and redirect counters
above do not have that limitation.

#### Backend issue and retirement

| Counter | Cycles | Fraction of run |
| --- | ---: | ---: |
| Dispatch nonempty | 46,446 | 97.62% |
| Dispatch nonempty, no issue | 15,876 | 33.37% |
| Dispatch full | 1,007 | 2.12% |
| Issue window nonempty | 43,948 | 92.37% |
| Window nonempty, no eligible instruction | 13,378 | 28.12% |
| No eligible: RAW predicate present | 11,836 | 24.88% |
| No eligible: hard-block predicate present | 11,185 | 23.51% |
| No eligible: memory-order predicate present | 4,150 | 8.72% |
| Retirement queue nonempty, no retirement | 17,774 | 37.36% |
| Retirement head incomplete | 17,650 | 37.10% |
| Completed instruction behind incomplete head | 10,368 | 21.79% |

Relative to no-eligible cycles, RAW was present in 88.47%, a hard block in
83.61%, and a memory-order block in 31.02%. These predicates overlap and do not
assign exclusive lost cycles. Broad state predicates were `raw_hazard=39564`,
`write_busy=45788`, and `barrier=20974`; they likewise report presence, not
exclusive causality.

The incomplete retirement head partitions as follows:

| Head operation | Cycles | Fraction of incomplete-head time |
| --- | ---: | ---: |
| ALU/other | 1,930 | 10.93% |
| Branch | 10 | 0.06% |
| Jump | 2,986 | 16.92% |
| Load | 7,934 | 44.95% |
| Store | 4,790 | 27.14% |

Loads and stores account for 12,724 cycles (72.09%). Their exclusive subreason
partition is 4,068 LSQ-absent cycles (31.97%), 62 translation cycles (0.49%),
1,682 access-launch cycles (13.22%), and 6,912 access-in-flight cycles
(54.32%). Of the LSQ-absent cycles, 1,029 were unissued and 3,039 were already
marked complete. Completed work existed behind the incomplete head during
58.74% of incomplete-head cycles.

#### LSU, translation, cache, and memory

| Counter | Value | Fraction of run where cycle-based |
| --- | ---: | ---: |
| LSU request wait | 1,273 cycles | 2.68% |
| LSU load / store request wait | 787 / 486 cycles | 1.65% / 1.02% |
| Any LSU request outstanding | 20,285 cycles | 42.64% |
| Load allocation / access / retirement | 11,514 / 11,233 / 10,445 events | n/a |
| Load allocation / access wait | 157 / 787 cycles | 0.33% / 1.65% |
| Load blocked by older store | 0 cycles | 0% |
| Load branch aborts | 579 events | 5.03% of allocations |
| Store allocation / retirement | 3,270 / 3,252 events | n/a |
| Store allocation / queue-full / access wait | 369 / 348 / 486 cycles | 0.78% / 0.73% / 1.02% |
| Store order wait | 5,405 cycles | 11.36% |

Sv39 required six PTW reads. The fast DTLB handled all 11,472 load
translations and 3,269 of 3,270 store translations; one store serialized.
Translation overlapped access for 5,956 loads. Both LSQ queues reached four
entries. There were no cache reissues, load faults, atomics, execution-port
conflicts, or ICX/L2/AXI backpressure cycles.

The hierarchy accepted 1,985 ICX requests: 34 fetch reads, 442 data reads,
1,503 data writes, and six PTW reads. L2 issued 46 two-beat AXI reads and 11
two-beat writes. DDR3 activity was 1,554 active cycles, 285 bus-busy cycles,
668 bank-wait cycles, 544 queue-wait cycles, and 1,314 refresh cycles across
five events. These activities overlap; they are not a stall-cycle sum. No
explicit memory-channel timing, queue-full, or AXI backpressure cycle fired.

The L1D prefetcher issued 438 requests and reported five useful/on-time uses
(1.14%), 648 late demand events, 62 useless completions, and 372 store-poison
events. The event populations differ and cannot be added. The L1I next-line
hint path recorded no hints or enqueues.

#### Raw current CoreMark counter dump

This is the complete `PERF_*` panel from the managed baseline run. It is kept
verbatim so later analysis can distinguish cycle predicates from event counts.

```text
PERF_ICX_L2 mode=3 carousel=1 confidence_gate=0 bp=8 completion_forward_mask=0 branch_forward_mask=1 full_forwarding=0 relax_waw=1 relax_hazards=0 issue_window=1 speculation_window=1 result_ready_control_release=1 retire_depth=32 posted_stores=1 timed_memory=1 memory_timing_model=0 cycles=47577 retired=52592 IPC=1.1054 a0=000000000a277880 l1i_bytes=16384 l1i_fetch_width=512 l1d_bytes=16384 l2_bytes=262144 l2_ways=8 ram_bytes=16777216
PERF_ICX_L2_TRAFFIC icx_requests=1985 fetch_reads=34 data_reads=442 data_writes=1503 ptw_reads=6 l2_axi_reads=46 l2_axi_read_beats=92 l2_axi_writes=11 l2_axi_write_beats=22
PERF_ICX_L2_L1I_PREFETCH next_line_hints=0 next_line_enqueues=0 probes=3320 miss_completions=0
PERF_ICX_L2_VM required=1 satp_sv39=1 supervisor=1 alias_fetch=1 alias_data=1 ptw_reads=6 dtlb_fast_loads=11472 dtlb_fast_stores=3269 dtlb_access_overlap_loads=5956 dtlb_serial_loads=0 dtlb_serial_stores=1 cacheable_pa_base=0000000080000000 cacheable_pa_size=00ffffff80000000
PERF_ZERO_SV39 required=0 xlates=0 accesses=0 mapping_errors=0
PERF_ICX_MAGIC source_mask=0 l1i_line_reads=0 l1d_line_reads=0
PERF_MEMORY timing_model=0 commands=57 max_command_queue=5 max_timing_owners=5 max_l2_mshrs=5 read_queue_depth=8 write_queue_depth=8 command_queue_depth=16 max_burst_train_bursts=8 bank_row_swizzle=0
PERF_MEMORY_CHANNEL read_bursts=46 write_bursts=11 read_beats_requested=92 read_beats_returned=92 write_beats_requested=22 write_beats_received=22 timing_read_commands=46 timing_write_commands=11
PERF_MEMORY_AXI_BURSTS read_1beat=0 read_2beat=46 read_other=0 write_1beat=0 write_2beat=11 write_other=0
PERF_MEMORY_CHANNEL_WAIT ar_queue=0 aw_queue=0 w_queue=0 r_backpressure=0 b_backpressure=0 read_timing=0 write_timing=0 timing_backend=0 timing_owner_full=0 max_read_queue=5 max_write_queue=3 max_timing_owners=5
PERF_MEMORY_CHANNEL_MERGE source_read_requests=46 axi_read_bursts=46 read_requests_merged=0 axi_write_bursts=11 write_requests_merged=0 ddr_commands_coalesced=16 ddr_reads_coalesced=13 ddr_writes_coalesced=3 ddr_coalesced_groups=10
PERF_MEMORY_DDR_UTIL active_cycles=1554 total_cycles=47577 bus_busy=285 bus_read=230 bus_write=55 bus_launches=57 read_launches=46 write_launches=11 bank_wait=668 queue_wait=544 bank_entry_cycles=1052 max_busy_banks=2
PERF_MEMORY_DDR_QUEUE entry_cycles=3043 full_cycles=0 input_wait=0 refresh_wait=0
PERF_MEMORY_DDR_ROWS hits=49 misses=8 conflicts=2 empty=6 direction_switches=2
PERF_MEMORY_DDR_BURSTS native=57 full_commands=57 partial_commands=0 multi_commands=0
PERF_MEMORY_DDR_TRAINS total=41 burst1=31 burst2=6 burst3=2 burst4=2 burst5=0 burst6=0 burst7=0 burst8=0 burst_long=0
PERF_MEMORY_DDR_REFRESH cycles=1314 events=5 deferred_cycles=0
PERF_ICX_L2_FRONTEND direction_corrections=942 target_corrections=1 lookaside_restart_hits=419
PERF_ICX_L2_BP_TARGET btb_lookups=743 btb_hits=738 btb_misses=5 btb_wrong_targets=0 ras_lookups=893 ras_hits=801 ras_misses=92 ras_wrong_targets=1
PERF_ICX_L2_LOOKASIDE pair_stack_depth=2 eligible_restarts=8129 hits=419 pair_overlaps=11361 pair_stack_overflows=5891 pair_stack_max_saved=1 fills=3027 duplicate_fills=0 free_fills=3027 evictions=0 full_branch_allocations=0
PERF_ICX_L2_SECTOR allocations=12937 predicted_free=9515 unpredicted_free=5457 response_taps=1337 predicted_taps=1235 unpredicted_taps=125 background_requests=68 background_deferred_cycles=12347
PERF_ICX_L2_STASH_STALL episodes=419 completed=4 interrupted=414 active=1 requested=6 stalled=23 completed_stalled=4 interrupted_stalled=19 exposed_cycles=96 completed_stall_cycles=13 interrupted_stall_cycles=83 same_line_cycles=25 next_line_cycles=71 preview_instr=3476 request_delay_sum=6 request_delay_max=1 response_delay_sum=17 response_delay_max=5 refill_latency_sum=13 refill_latency_max=4
PERF_ICX_L2_STASH_OFFSET hits=145,97,158,19 stalled=8,3,10,2 stall_cycles=38,13,39,6
PERF_ICX_L2_STASH_SECTOR hits=191,228 stalled=14,9 stall_cycles=55,41
PERF_ICX_L2_PREFETCH enabled=1 streams=2 initial_depth=1 adaptive=1 max_depth_cfg=4 max_depth_seen=2 outstanding=4 reserve=2 issued=438 useful=5 useful_pct=1.14 on_time_useful=5 on_time_pct=1.14 late_useful=0 late_useful_pct=0.00 late=648 late_queued=648 late_command=0 late_mshr=0 dropped=0 useless=62
PERF_ICX_L2_STORE_POISON any_events=372 prefetch_events=372 prefetch_queue=6 prefetch_command=0 prefetch_mshr=0 prefetch_fill=366 demand_events=0 demand_wait_prefetch=0 demand_fill=0 demand_mshr_overlays=0
PERF_ICX_L2_WIDTH issued=56432 decoded=64745 issue_w0=17007 issue_w1=10599 issue_w2=14769 issue_w3=4513 issue_w4=689 decode_w0=20563 decode_w1=6233 decode_w2=3831 decode_w3=16950 retire_w0=18905 retire_w1=13009 retire_w2=7406 retire_w3=8257
PERF_ICX_L2_BACKEND dispatch_nonempty=46446 dispatch_nonempty_no_issue=15876 dispatch_full=1007 raw_hazard=39564 waw_hazard=0 read_port_hazard=0 write_busy=45788 barrier=20974
PERF_ICX_L2_RAW first_block=0 pending=0 bundle=0 completed=0 secondary_only=0 rs1=0 rs2=0 both=0 lane0=0 lane1=0 lane2=0 blocked_alu=0 blocked_branch=0 blocked_jump=0 blocked_load=0 blocked_store=0
PERF_ICX_L2_WINDOW enabled=1 speculation=1 nonempty_cycles=43948 no_eligible_cycles=13378 raw_stall_cycles=11836 hard_stall_cycles=11185 mem_order_stall_cycles=4150 unissued_entry_cycles=518432 operand_ready_entry_cycles=178940 eligible_entry_cycles=70132 raw_block_entry_cycles=339492 hard_block_entry_cycles=66870 mem_order_block_entry_cycles=41938
PERF_ICX_L2_BRANCH_GATED_LOAD candidate_cycles=0 gated_cycles=0 candidate_entry_cycles=0 gated_entry_cycles=0
PERF_ICX_L2_RETIRE nonempty=46446 nonempty_no_retire=17774 head_incomplete=17650 completed_behind_head=10368
PERF_ICX_L2_RETIRE_HEAD alu=1930 branch=10 jump=2986 load=7934 store=4790 mem_lsq_absent=4068 mem_wait_xlate=62 mem_wait_access=1682 mem_access_inflight=6912
PERF_ICX_L2_RETIRE_HEAD_ABSENT unissued=1029 issued=0 result=0 complete=3039
PERF_ICX_L2_FETCH empty=14491 held=6072 request_wait=91 control_empty=191 refill_wait=14030 no_line=270 bp_stall=0 other_empty=0
PERF_ICX_L2_FETCH_CAUSAL empty_backend_ready=13949 empty_dispatch_empty=803 empty_dispatch_empty_backend_ready=789 empty_dispatch_empty_retire_empty=803 empty_dispatch_nonempty=13688 empty_dispatch_full=360 empty_l1i_external_miss=585 empty_pending_no_external_miss=13638
PERF_ICX_L2_REDIRECT total=8133 predicted=7186 correction=943 target_correction=1 control_restart=2 exception=2 other=0 lookaside_hits=419 predicted_lookaside_hits=221 correction_lookaside_hits=198 completed=6947 superseded=1185 active=1
PERF_ICX_L2_POST_REDIRECT empty_cycles=11896 empty_cycles_x1000_per_redirect=1462 stalled_events=2458 zero_stall_events=4489 max_empty_cycles=363 critical_empty_cycles=713 predicted_empty_cycles=10128 correction_empty_cycles=1379 restart_empty_cycles=389 other_empty_cycles=0
PERF_ICX_L2_POST_REDIRECT_CAUSE current_pending=1414 other_pending=10280 no_pending=202 external_miss=467 request_wait=39
PERF_ICX_L2_POST_REDIRECT_LOOKASIDE hit_empty_cycles=8 miss_empty_cycles=11888 hit_stalled_events=2 hit_zero_stall_events=366 miss_stalled_events=2456 miss_zero_stall_events=4123
PERF_ICX_L2_CORRECTION_FAL no_context=653 context_pending=20 context_not_pending=72 lookaside_hit_empty_cycles=8 no_context_empty_cycles=1144 context_pending_empty_cycles=95 context_not_pending_empty_cycles=132
PERF_ICX_L2_LSU request_wait=1273 load_wait=787 store_wait=486 outstanding=20285 branch_resolutions=12714 conditional_branch_resolutions=10786
PERF_ICX_L2_SPEC_LOAD alloc=11514 spec_alloc=10600 ordered_alloc=914 xlate=11472 spec_xlate=10558 access=11233 spec_access=8423 ordered_access=2810 responses=11233 completions=10935 forwarded=0 faults=0
PERF_ICX_L2_SPEC_LOAD_WAIT alloc_wait=157 queue_full=8 xlate_wait=0 access_wait=787 dependency_cycles=0 dependency_entry_cycles=0 forward_cycles=0 forward_entry_cycles=0 occupancy_entry_cycles=27978 spec_occupancy_entry_cycles=21796 max_occupancy=4
PERF_ICX_L2_SPEC_LOAD_SQUASH branch_total=579 before_xlate=42 xlate_inflight=0 xlate_done=239 access_inflight=298 killed_responses=298 flushed=0
PERF_ICX_L2_SPEC_LOAD_OUTCOME retired=10445 spec_retired=9531 ordered_retired=914 cache_reissues=0 branch_aborted=579 flush_aborted=0
PERF_ICX_L2_SPEC_STORE alloc=3270 spec_alloc=3030 ordered_alloc=240 atomic_alloc=0 xlate=3270 spec_xlate=3030 ordered_access=3252 posted_results=3252 done=3252
PERF_ICX_L2_SPEC_STORE_WAIT alloc_wait=369 queue_full=348 xlate_wait=0 access_wait=486 order_wait_cycles=5405 order_wait_entry_cycles=7221 occupancy_entry_cycles=20629 spec_occupancy_entry_cycles=13018 max_occupancy=4
PERF_ICX_L2_SPEC_STORE_SQUASH branch_total=18 before_xlate=0 xlate_inflight=0 xlate_done=18 access_inflight=0 killed_responses=0 flushed=0
PERF_ICX_L2_SPEC_STORE_OUTCOME retired=3252 spec_retired=3012 ordered_retired=240 cache_reissues=0 branch_aborted=18 flush_aborted=0 untracked_retired=0
PERF_ICX_L2_ATOMIC starts=0 done=0 active_cycles=0 store_success=0 store_failed=0 home_sc_success=0 home_sc_failed=0
PERF_ICX_L2_PREFETCH_PAGE_END boundaries_seen=9
PERF_ICX_L2_MEM_PORTS second_port_opportunities=0
PERF_ICX_L2_BACKPRESSURE l1d_wait=1273 l1d_load_wait=787 l1d_store_wait=486 icx_wait=0 icx_read_wait=0 icx_write_wait=0 l2_bus_wait=0 l2_command_full=0 axi_ar_wait=0 axi_aw_wait=0 axi_w_wait=0
PERF_ICX_L2_L1D_WAIT store_block=0 dirty_snoops=3413 lock_barrier=0 response_tags=0 refill=0 access=376 run_response=787 unknown=110
PERF_ICX_L2_CONFLICT total=0 ex0=0 ex1=0 mem=0 blocked_alu=0 blocked_branch=0 blocked_jump=0 blocked_load=0 blocked_store=0
PERF_ICX_L2_CONFLICT_PAIR branch_alu=0 alu_branch=0 branch_branch=0 alu_alu=0 load_load=0 store_load=0 store_store=0 other=0
```

### Historical 55,799-cycle critical counter breakdown (2026-08-18)

All percentages in this historical subsection use the 55,799 reset-to-done cycles as the
denominator unless another denominator is named. Counters are not generally
additive. The frontend empty reasons and retirement-head operation/reason
tables are exclusive partitions; the issue-window RAW, hard, and memory-order
predicates overlap.

The average widths were 1.0775 decoded, 0.9846 issued, and 0.9425 retired
instructions per cycle:

| Width | Decode cycles | Issue cycles | Retire cycles |
| ---: | ---: | ---: | ---: |
| 0 | 30,593 (54.83%) | 23,436 (42.00%) | 25,204 (45.17%) |
| 1 | 6,360 (11.40%) | 13,285 (23.81%) | 14,889 (26.68%) |
| 2 | 2,776 (4.98%) | 15,805 (28.33%) | 9,415 (16.87%) |
| 3 | 16,070 (28.80%) | 3,047 (5.46%) | 6,291 (11.27%) |
| 4 | n/a | 226 (0.41%) | n/a |

#### Frontend

| Counter | Cycles | Fraction of run |
| --- | ---: | ---: |
| Fetch output empty | 28,122 | 50.40% |
| Fetch output held by decode | 2,471 | 4.43% |
| Fetch request-channel wait | 351 | 0.63% |
| Empty: control flush/redirect | 497 | 0.89% |
| Empty: refill/pending state | 25,819 | 46.27% |
| Empty: no line available | 1,806 | 3.24% |
| Empty: predictor stall / other | 0 / 0 | 0% / 0% |

The five empty-reason rows are an exclusive partition of the 28,122 empty
cycles. They do not establish that all 28,122 cycles reached the critical
path. Dispatch still contained work during 26,930 of them (95.76% of empty
cycles). Dispatch was empty during only 1,192 cycles (2.14% of the run), and
the stricter dispatch-empty/backend-ready slice was 1,150 cycles (2.06%). All
1,192 dispatch-empty cycles also had an empty retirement queue.

Only 794 empty cycles coincided with a live external L1I miss: 1.42% of the
run and 2.82% of frontend-empty time. Another 25,526 empty cycles were in a
pending fetch state without an external miss: 45.75% of the run and 90.77% of
frontend-empty time. Thus `refill_wait=25819` is primarily an internal
fetch/pending/refill-handoff counter, not DDR latency.

Control-flow counters were 10,786 conditional-branch resolutions, 864
direction corrections (8.01% of conditional resolutions, or 16.43 per 1,000
retired instructions), and one target correction. The BTB recorded 735 hits
from 740 lookups (99.32%) with no wrong targets. The RAS recorded 800 hits, 60
misses, and one wrong target from 860 lookups. Lookaside restart logic produced
340 hits from 7,698 eligible restarts; stash stalls exposed 240 cycles. Sector
background requests were deferred for 21,352 cycles, but this is a background
activity counter, not a core-stall count.

#### Backend issue and retirement

| Counter | Cycles | Fraction of run |
| --- | ---: | ---: |
| Dispatch nonempty | 53,430 | 95.75% |
| Dispatch nonempty, no issue | 21,067 | 37.76% |
| Dispatch full | 2,982 | 5.34% |
| Issue window nonempty | 48,317 | 86.59% |
| Window nonempty, no eligible instruction | 15,954 | 28.59% |
| No eligible: RAW predicate present | 13,211 | 23.68% |
| No eligible: hard-block predicate present | 10,667 | 19.12% |
| No eligible: memory-order predicate present | 4,005 | 7.18% |
| Retirement queue nonempty, no retirement | 22,835 | 40.92% |
| Retirement head incomplete | 22,711 | 40.70% |
| Completed instruction behind incomplete head | 12,477 | 22.36% |

The three `no eligible` predicate rows overlap and must not be summed. Relative
to the 15,954 no-eligible cycles, RAW was present in 82.81%, a hard block in
66.86%, and a memory-order block in 25.10%. The older `PERF_ICX_L2_RAW` detail
record is all zero because that record is populated only for the non-windowed
issue path; it is not evidence that RAW blocking is absent.

Broad state predicates were also high: `raw_hazard` was asserted for 40,762
cycles (73.05%), `write_busy` for 52,298 (93.73%), and `barrier` for 19,019
(34.09%). These identify state present during a cycle; they are not exclusive
or proof that the state alone prevented issue.

The incomplete retirement head divides exclusively by operation:

| Head operation | Cycles | Fraction of incomplete-head time |
| --- | ---: | ---: |
| ALU/other | 2,657 | 11.70% |
| Branch | 58 | 0.26% |
| Jump | 2,936 | 12.93% |
| Load | 12,103 | 53.29% |
| Store | 4,957 | 21.83% |

Loads and stores therefore account for 17,060 cycles, or 75.12% of
incomplete-head time. Their exclusive subreasons were:

| Memory-head reason | Cycles | Fraction of memory-head time |
| --- | ---: | ---: |
| LSQ entry absent | 6,403 | 37.53% |
| Waiting for translation | 62 | 0.36% |
| Waiting to launch access | 2,746 | 16.10% |
| Access in flight | 7,849 | 46.01% |

Of the 6,403 absent-entry cycles, 2,011 were still unissued and 4,392 had an
LSU-complete indication but no matching live LSQ entry. Completed work existed
behind the incomplete head during 54.94% of incomplete-head cycles, showing
substantial in-order retirement head-of-line blocking.

#### LSU, cache, translation, and memory

| Counter | Value | Fraction of run where cycle-based |
| --- | ---: | ---: |
| LSU request wait | 1,455 cycles | 2.61% |
| LSU load / store request wait | 1,038 / 417 cycles | 1.86% / 0.75% |
| Any LSU request outstanding | 19,633 cycles | 35.19% |
| Load allocation / access / retirement | 10,994 / 10,851 / 10,445 events | n/a |
| Load allocation / access wait | 143 / 1,038 cycles | 0.26% / 1.86% |
| Load blocked by older store | 0 cycles | 0% |
| Load branch aborts | 314 events | 2.86% of allocations |
| Store allocation / retirement | 3,252 / 3,252 events | n/a |
| Store allocation / queue-full / access wait | 87 / 39 / 417 cycles | 0.16% / 0.07% / 0.75% |
| Store order wait | 1,520 cycles | 2.72% |

The 1,455 L1D-wait cycles partition into 1,038 response-run cycles, 313 access
cycles, and 104 unknown cycles. Store blocking, locks/barriers, response-tag
exhaustion, and refill waits were all zero. ICX wait, L2-bus wait, L2-command
full, and AXI AR/AW/W waits were also all zero. The load and store queues each
reached their four-entry maximum occupancy. There were no cache reissues,
load faults, atomics, or execution-pipe port conflicts.

Sv39 translation required six PTW reads. All 10,994 loads and 3,251 of 3,252
stores used the fast DTLB path; one store serialized. Translation overlapped
the data access for 5,587 loads (50.82%). LSU translation-wait cycles were
zero, although 62 retirement-head cycles observed a memory operation before
its translation completed.

The hierarchy accepted 1,982 ICX requests: 31 fetch reads, 442 data reads,
1,503 data writes, and six PTW reads. L2 generated 44 AXI reads and 11 writes,
or 55 DDR commands. Critical memory/controller counters were:

| Counter | Cycles/events | Fraction of run where cycle-based |
| --- | ---: | ---: |
| Explicit channel `read_timing` wait | 270 cycles | 0.48% |
| DDR active | 1,699 cycles | 3.05% |
| DDR bus busy | 275 cycles | 0.49% |
| Bank wait / queue wait | 682 / 687 cycles | 1.22% / 1.23% |
| Refresh | 1,588 cycles, 6 events | 2.85% |
| Command-queue full | 0 cycles | 0% |
| Row hits / misses / conflicts | 47 / 8 / 2 events | n/a |
| Maximum command queue / timing owners / L2 MSHRs | 5 / 5 / 6 entries | n/a |

These controller activities overlap core execution and may overlap each other;
they are not a memory-stall sum. In particular, `read_timing=270` is explicit
channel admission delay, not total demand-miss latency.

The L1D prefetcher issued 438 requests and recorded only five useful/on-time
uses (1.14%), 648 late demand events, 62 useless completions, and 372
store-poison events. These counters use different event populations and must
not be arithmetically combined. The matched prefetch-control comparison above
shows no performance benefit for this workload; it does not prove that each
poison or late event costs a cycle. The separate L1I next-line hint path had
zero hints and zero enqueues.

## Historical RD16 comparison configuration (2026-07-26)

The historical configuration is BP8, the fetch carousel, confidence gate
zero, the issue/speculation window enabled, and retirement depth 16. The bare
CoreMark run replaces the cache/DDR3 hierarchy with one-cycle instruction/data
SRAM.
The SoC CoreMark and all STREAM runs use Sv39 and the full
L1I/L1D -> ICX -> L2 -> AXI -> banked-DDR3 path.

| Area | Setting |
| --- | --- |
| Direction/target predictor | `BP_TYPE=8`, BTB256, RAS8 |
| Fetch mode | alternate lookaside mode 3 |
| Fetch carousel | enabled (`FETCH_CAROUSEL=1`) |
| Fetch confidence gate | disabled (`CONFIDENCE_GATE=0`, or `fc0`) |
| Lookaside pair-stack depth | 2 |
| Completion forwarding | mask 0 |
| Branch forwarding | mask 1 |
| Full forwarding | disabled |
| WAW relaxation | enabled (`RELAX_WAW=1`) |
| General hazard relaxation | disabled |
| Issue window | enabled (`ISSUE_WINDOW=1`) |
| Speculation | enabled (`SPECULATION_WINDOW=16`) |
| Issue-window depth | tied to retirement depth: 16 entries |
| Retirement depth | 16 (`rd16`) |
| Physical registers | 31 |
| Posted stores | enabled |
| L1I / L1D | 16 KiB / 16 KiB |
| L2 | 256 KiB, 8-way, 8 merge entries |
| Shared L2 TLB | 256 entries, 4-way |
| GenBus read/write buffering | 4 / 4 |
| L1D prefetch | enabled, 2 streams, initial distance 1 |
| Adaptive prefetch | enabled, maximum distance 4 |
| Prefetch queue/outstanding/reserve | 4 / 4 / 2 |
| DDR3 queues | 8 read / 8 write / 16 command |
| Memory timing model | 0, banked DDR3 enabled |
| Backing RAM | 16 MiB |
| Speculative-load PMA gate | translated PA must be inside configured backing RAM; VA is not classified |

`ISSUE_WINDOW` and `SPECULATION_WINDOW` are enable controls in the RTL; the
actual issue-window depth is `RETIRE_DEPTH`. Any nonzero speculation value
enables the same mechanism. The value 16 is retained in the build tag and
performance report to identify the requested configuration.

The repository build tag calls WAW relaxation `rw1`. Retirement depth is
`rd16`; referring to this configuration as `rw16` is ambiguous and does not
match the Make variable names.

## Historical RD16/STREAM results (2026-07-26)

### CoreMark-derived loop

| Environment | Cycles | Retired | IPC |
| --- | ---: | ---: | ---: |
| One-cycle magic SRAM, bare physical addresses | **48,652** | 52,547 | **1.0801** |
| 3P SoC, Sv39 and banked DDR3 | **56,146** | 52,570 | **0.9363** |

The SoC costs 7,494 cycles, or 15.4% relative to the magic-SRAM run. It also
retires 23 Sv39 bootstrap instructions, so this is close but not a perfectly
identical instruction-stream comparison.

### STREAM

STREAM's "kernel cycles" are measured by the workload between its cycle
counter reads. "Stop cycles" and IPC are the harness totals through
`stream_measure_end`, including 536 or 537 cycles of Sv39 boot and setup.
Payload rate counts one read plus one write for copy/scale, and two reads plus
one write for add/triad.

| Workload | Kernel cycles | Stop cycles | Retired | IPC | Payload | Payload rate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| STREAM copy | **38,539** | 39,075 | 20,522 | 0.5252 | 128 KiB | 3.4010 B/cycle |
| STREAM scale | **38,788** | 39,324 | 41,002 | 1.0427 | 128 KiB | 3.3792 B/cycle |
| STREAM add | **92,142** | 92,679 | 43,052 | 0.4645 | 192 KiB | 2.1338 B/cycle |
| STREAM triad | **92,333** | 92,870 | 59,436 | 0.6400 | 192 KiB | 2.1293 B/cycle |

At 1 GHz, B/cycle has the same numeric value as GB/s. This is only a scaling
identity; these simulations do not establish a 1 GHz implementation.

## RD16 effect

RD16 is materially better than RD8 for CoreMark and scale. It does not repair
the two-input STREAM kernels.

| Workload | RD8 cycles | RD16 cycles | RD16 delta |
| --- | ---: | ---: | ---: |
| CoreMark, Sv39 SoC | 65,670 | 56,146 | -9,524 (-14.5%) |
| STREAM copy | 38,792 | 38,539 | -253 (-0.7%) |
| STREAM scale | 44,904 | 38,788 | -6,116 (-13.6%) |
| STREAM add | 92,664 | 92,142 | -522 (-0.6%) |
| STREAM triad | 92,236 | 92,333 | +97 (+0.1%) |

This is why RD16 is now the project default. When the issue window is enabled,
changing retirement depth also changes issue-window capacity.

## RD32 experiment

RD32 was rerun with every other reported control unchanged: BP8, mode 3,
carousel 1, confidence gate 0, pair stack 2, issue window enabled,
speculation value 16, posted stores, two adaptive prefetch streams, Sv39, and
banked DDR3. RD32 improves CoreMark modestly but does not improve STREAM as a
class.

| Workload | RD16 cycles | RD32 cycles | RD32 delta | RD32 IPC/rate |
| --- | ---: | ---: | ---: | ---: |
| CoreMark, magic SRAM | 48,652 | **47,588** | -1,064 (-2.2%) | 1.1042 IPC |
| CoreMark, Sv39 SoC | 56,146 | **55,398** | -748 (-1.3%) | 0.9490 IPC |
| STREAM copy, kernel | 38,539 | **38,533** | -6 (-0.02%) | 3.4016 B/cycle |
| STREAM scale, kernel | 38,788 | **38,782** | -6 (-0.02%) | 3.3797 B/cycle |
| STREAM add, kernel | 92,142 | **92,279** | +137 (+0.15%) | 2.1306 B/cycle |
| STREAM triad, kernel | 92,333 | **92,256** | -77 (-0.08%) | 2.1311 B/cycle |

RD32 STREAM stop cycles were 39,053, 39,302, 92,800, and 92,777 for
copy, scale, add, and triad respectively. Separate full-result runs of all
four kernels passed with `STREAMOK`, Sv39 active, and the DDR3-overlap
assertion.

The CoreMark gain is not a clean frontend or prediction improvement. Relative
to RD16, the RD32 SoC run reduces dispatch-nonempty/no-issue cycles from
20,546 to 19,932 and retirement-head-incomplete cycles from 21,883 to 21,505.
However, frontend-empty cycles increase from 25,855 to 26,488, direction
corrections increase from 789 to 857, and the RAS changes from 780/780/0/0 to
888/824/64/0 (lookups/hits/misses/wrong targets). The magic run shows the same
direction: 927 direction corrections and 144 RAS misses at RD32, versus 732
and zero at RD16. RD32 therefore exposes more speculative control-flow
pressure even while its larger window reduces total runtime.

The STREAM changes are below 0.2% and non-monotonic. In particular, add gets
slower even though its late/dropped prefetch counters fall from 1,431/585 to
1,301/513. That is further evidence that retirement-window capacity is not
the limiting resource for the two-input kernels. RD16 remains the default;
the small workload-dependent RD32 gain has not been weighed against its
additional state and implementation cost.

## Remaining holes

### Two-input STREAM is not fixed end to end

The two-stream prefetch implementation is present and active. Add and triad
issue about twice as many prefetches as copy, which is the expected signature
for tracking both input arrays:

| Counter | Copy | Add | Triad |
| --- | ---: | ---: | ---: |
| Kernel cycles | 38,539 | 92,142 | 92,333 |
| L1D line reads | 1,028 | 2,061 | 2,060 |
| L1D line writes | 1,024 | 1,024 | 1,024 |
| DDR commands | 2,065 | 3,094 | 3,094 |
| Prefetch issued | 1,027 | 2,059 | 2,058 |
| Prefetch late | 311 | 1,431 | 1,329 |
| Prefetch dropped | 0 | 585 | 586 |
| Retirement head incomplete | 24,007 | 67,621 | 61,601 |
| Load at retirement head | 13,238 | 56,539 | 50,504 |
| Memory access in flight at head | 22,416 | 64,712 | 58,502 |

Detection is therefore fixed; throughput is not. Add and triad still sustain
only about 2.13 B/cycle, 37% below copy. The current backend has a four-entry
load queue, and the unified LSQ exposes one translation/L1D launch port. The
assembly issues four loads from A followed by four loads from B. Four A loads
can occupy the entire load queue before the B group enters, so the demand side
cannot keep both groups live together when the prefetched lines are late.

The high late/drop counts confirm that prefetch timeliness is not hiding this
limit. Increasing retirement/issue-window capacity from 8 to 16 barely moves
add and triad because the load queue and single L1D launch port remain
unchanged. The next controlled experiment should enlarge the load queue to at
least eight entries before adding a second physical cache port; that separates
queue-capacity failure from true single-port bandwidth failure.

### CoreMark still has frontend and backend loss

The RD16 SoC run reaches 0.9363 IPC, but remains 7,494 cycles behind the
one-cycle-SRAM result. Its major non-exclusive counters are:

| Counter | Cycles | Fraction of SoC run |
| --- | ---: | ---: |
| Frontend empty | 25,855 | 46.1% |
| Fetch refill wait | 24,048 | 42.8% |
| Retirement queue nonempty, no retirement | 21,883 | 39.0% |
| Dispatch nonempty, no issue | 20,546 | 36.6% |
| Window RAW-stall cycles | 10,982 | 19.6% |
| Completed instructions behind retirement head | 11,208 | 20.0% |

The memory hierarchy itself reports only 68 cycles of explicit DDR read-timing
blockage. Likewise, only 827 frontend-empty cycles coincide with an external
L1I miss, while 23,607 are pending with no external miss. Treating
`refill_wait=24048` as time blocked on DDR3 reads would be wrong. The
frontend's pending/carousel/refill handoff remains a distinct hole.

Target prediction is not the remaining control-flow problem: the SoC run has
zero target corrections, BTB 737/734/3/0 and RAS 780/780/0/0
(lookups/hits/misses/wrong targets). It still has 789 direction corrections.

The SoC memory details are six PTW reads, 42 DDR read bursts, four write
bursts, 46 total DDR commands, and 68 explicit read-timing wait cycles.
Instruction and data aliases were verified under supervisor-mode Sv39.

## RD16 default

Retirement depth now defaults to 16 consistently in the 3P backend/core/top
hierarchy, platform wrapper, magic/SoC/AXI testbenches, and the corresponding
Make configurations. STREAM, pointer-chase, and the OpenSBI 3P platform
already selected 16 explicitly. Tests may still override the parameter for
directed depth-specific coverage.

## Historical validation and provenance (2026-07-26)

Both CoreMark environments completed with
`a0=0x000000000a277880`. Separate RD16 full-result runs of all four STREAM
kernels completed with `a0=0x53545245414d4f4b` (`STREAMOK`). Every SoC run
reported Sv39 active and passed the banked-DDR3 overlap assertion.

The worktree was dirty, so the commit alone is not sufficient provenance.
The hashes below identify the explicitly configured RD16 measurement
snapshot. The later RD16 default-only patch changed parameter-initializer
hashes in the hierarchy and testbenches, but not the explicitly elaborated
behavior used for these measurements. `sim-backend-3p` and `sim-top-3p` pass
after that patch.

```text
commit 78dd1823c990c2bf184cf0dc38b0fd78d4e43309
94553e822417b8229f7350a6a9893829f0fbe9704044ec36f7e53f5e970e2fa0  rtl/core/fetch/fetch_3w.v
aeb0c0be2abea924fa48f2acfe8a1acc5f746eae488387234381faabd5d5f1d3  rtl/core/rv64_top_3p.v
6f8efc770442d42e29059f809981c523589ac650d410f774201ab8955a1b8e96  rtl/core/cache/l1/l1d/l1d.v
0ca06acde412571ce85ed97492d8ca334c5b641af381a19a504f7f14c6518476  tb/tb_top_3p_soc.v
25587cab1a0e73b3db20898a3a19914b04545b17c516e30a09f3bdde6d2fd68b  sw/coremark_loop.c
b40da41e47aeeb9f459cf5d120ad3d6426bcdc7dd034fffc6b6c0173bc1cec73  sw/stream/stream.S
```

The accepted CoreMark SoC run used `sim-core-3p-icx-l2` directly. The
`sim-core-3p-icx-l2-vm` wrapper hard-codes retirement depth 16 and a nonzero
speculation enable, so it is behaviorally equivalent for those controls but
reports `speculation_window=1` rather than the requested build tag value 16.
