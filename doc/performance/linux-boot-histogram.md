# Linux boot PC histogram

Measurement snapshot: 2026-07-28 02:43:58 UTC

Run started: 2026-07-28 00:54:41 UTC

Build ran: 2026-07-28 00:53:14 through 00:54:12 UTC

Status at this snapshot: still running, clean through 83,750,000 cycles

This document records a low-resolution symbolized PC histogram for the
current Linux boot. It answers which kernel functions appear most often at
periodic progress samples. It does **not** provide exact per-function cycle
accounting.

The largest concentrations through 83.75M cycles are:

1. BLAKE2 compression and related random initialization.
2. Early page-descriptor initialization and freeing.
3. `memset` and `memcpy`.
4. VFS, kernfs, device, inode, and kobject construction.
5. Slab/page allocation, formatting, and scheduler accounting.

The single worst interval is much more concentrated than the whole-boot
histogram suggests. From 10M to 20M cycles the core achieves only 0.220 IPC,
and almost every lowest-IPC sample is in `__free_pages_core`.

## What was run

The requested configuration tag was:

```text
bp8-car1-fa3-fc0-iw1-sw1-rd32-prf31-l2m8-pf-short4-long8-q8-o8-r2-ppg1-ddr3
```

The elaborated configuration was:

| Area | Setting |
| --- | --- |
| Backend | 3P |
| Predictor | BP8 |
| Fetch carousel | enabled |
| Alternate lookaside | mode 3 |
| Fetch confidence gate | 0 |
| Issue/speculation controls | 1 / 1 |
| Retirement depth | 32 |
| Physical registers | 31 |
| Store queue | 4 |
| L1I demand MSHRs | 4 |
| L2 | 256 KiB, 8-way, 8 merge entries |
| Shared L2 TLB | 256 entries, 4-way |
| Prefetch streams | 2 |
| Prefetch initial distance | 1 |
| Short-stream cap | 4 lines |
| Long-stream cap | 8 lines |
| Prefetch queue | 8 lines |
| Prefetch outstanding | 8 |
| Demand reserve | 2 |
| Page gating | 4 KiB probation, setting 1 |
| CCX bus | native, 256-bit |
| DDR3 | enabled |
| DDR3 queues | 8 read / 8 write / 16 command |
| Memory timing model | 0 |
| Backing memory | 256 MiB |
| Verilator simulation threads | 1 |

The short-stream limit is the L1D's fixed four-line cap. The
`L1D_PREFETCH_MAX_DISTANCE=8` elaboration parameter supplies the long-stream
limit.

The run used a 200M-cycle maximum and saved a non-exiting checkpoint at 50M:

```text
build/checkpoints/linux-bp8-car1-fa3-fc0-iw1-sw1-rd32-prf31-\
l2m8-pf-short4-long8-q8-o8-r2-ppg1-ddr3-50m-20260728.vls
```

No `BUG`, `Oops`, kernel panic, `FATAL`, LSU timeout, or other terminal error
was present through the snapshot endpoint.

## Provenance

The worktree was dirty. The commit alone does not reproduce the binary.
These hashes identify the measured artifacts and important source inputs:

```text
commit fa83b59b75308ac0dc567b728cb97b2ce1f6dda5

1fdd65b4e8e773b600a5825f3f0fec2cd71bcdae883063d2d09fd2de20df5e47  opensbi_3p_platform_tb
4b33690e34d7a82d7ab6cfbe23157dd39d688a832ab40cf5889dd53f565246a3  build/opensbi/artifacts/linux-image.memh
b8963ccda3b7d8b677f4d670d4d3e6c9e15dbd317c3977540aca7c65175b2855  /home/bill/src/linux/vmlinux
c160966fdbcbb1076e29035305d54a1f4f189f264dfc8da209e237136c44bfe6  rtl/core/cache/l1/l1d/l1d.v
780a180be182b59e66b50fe8bb540f641e18881adfaf9bec404149c878876bc9  tb/tb_opensbi.sv
251c44abd8b2026c5f09b9ad4a58e45cdb4d5112ed6fa96dfd706e8ce4570665  tb/verilator_checkpoint_main.cpp
```

The Linux `vmlinux` is unstripped and has build ID:

```text
d19d4713eae716edb46c475c6deb4921ab3d1c95
```

## Method

`tb_opensbi.sv` prints a progress record every 250,000 cycles after early
boot. Each record contains cycle, retired-instruction count, privilege, and
`dbg_pc`.

For the 3P core, `dbg_pc` is updated on a retirement event and otherwise
holds the most recently retired PC. The histogram therefore samples the
most recently retired instruction at each progress instant. During a stall,
the held PC will receive the sample even when the actual blocking work is
elsewhere in the pipeline or memory hierarchy.

The analysis:

1. Discards early samples before the first kernel S-mode sample.
2. Keeps samples aligned to the 250,000-cycle cadence.
3. Separates kernel S-mode, machine mode, and user mode.
4. Symbolizes canonical kernel PCs with
   `riscv64-linux-gnu-addr2line -f -C`.
5. Counts symbol hits.

The fixed snapshot covers:

```text
cycles:       4,000,000 through 83,750,000
instructions: 4,541,579 through 42,918,578
samples:      320
cadence:      250,000 cycles
```

Of the 320 samples, 316 were kernel S-mode and four were machine mode:

| Privilege class | Samples | Percent |
| --- | ---: | ---: |
| Kernel S-mode | 316 | 98.75% |
| Machine mode | 4 | 1.25% |
| User mode | 0 | 0.00% |

"Sample-equivalent cycles" in the tables below means
`hits * 250,000`. It gives an intuitive scale, but is not exact attribution
of all cycles in each interval.

## Boot signposts

| Signpost | Cycles | Retired instructions |
| --- | ---: | ---: |
| OpenSBI banner | 1,348,235 | 1,796,255 |
| Linux banner | 3,794,988 | 4,407,962 |
| Kernel memory accounting | 19.75M to 20.00M | 10,728,752 to 10,831,820 |
| devtmpfs initialized | 20.25M to 20.50M | 10,917,841 to 10,991,272 |
| PLIC initialized | 31,488,452 | 16,070,755 |

Only OpenSBI, Linux, and PLIC have exact explicit signposts. The memory and
devtmpfs events are bracketed by adjacent progress records.

## IPC by boot phase

| Cycle range | Retired instructions | IPC |
| --- | ---: | ---: |
| 4M to 10M | 4,089,700 | 0.6816 |
| 10M to 20M | 2,200,541 | **0.2201** |
| 20M to 30M | 4,707,673 | 0.4708 |
| 30M to 40M | 3,962,625 | 0.3963 |
| 40M to 50M | 5,352,404 | 0.5352 |
| 50M to 60M | 5,429,734 | 0.5430 |
| 60M to 70M | 5,367,039 | 0.5367 |
| 70M to 80M | 5,328,711 | 0.5329 |
| 80M to 83.75M | 1,938,572 | 0.5170 |

The early page-freeing loop is not the whole explanation for low boot IPC.
Even after 40M, sustained IPC remains near 0.53 to 0.54.

### Distribution of 250K-cycle interval IPC

This distribution contains 320 intervals from 4M through 83.75M:

| Interval IPC | Samples | Percent |
| --- | ---: | ---: |
| Below 0.2 | 28 | 8.75% |
| 0.2 to below 0.4 | 49 | 15.31% |
| 0.4 to below 0.6 | 205 | 64.06% |
| 0.6 to below 0.8 | 25 | 7.81% |
| 0.8 to below 1.0 | 12 | 3.75% |
| 1.0 or above | 1 | 0.31% |

About 88% of sampled intervals are below 0.6 IPC. Nearly one quarter are
below 0.4 IPC.

The 15 lowest intervals are all sampled at `__free_pages_core`, ranging from
0.143640 to 0.144152 IPC. They occur between 10.25M and 16.25M cycles.

## Top symbol histogram

| Rank | Function | Hits | All samples | Sample-equivalent cycles |
| ---: | --- | ---: | ---: | ---: |
| 1 | `blake2s_compress_generic` | 28 | 8.75% | 7.00M |
| 2 | `__free_pages_core` | 26 | 8.12% | 6.50M |
| 3 | `memset` | 18 | 5.62% | 4.50M |
| 4 | `memcpy` | 10 | 3.12% | 2.50M |
| 5 | `memmap_init_range` | 6 | 1.88% | 1.50M |
| 6 | `__init_single_page` | 6 | 1.88% | 1.50M |
| 7 | `string` | 6 | 1.88% | 1.50M |
| 8 | `up_write` | 6 | 1.88% | 1.50M |
| 9 | `vsnprintf` | 6 | 1.88% | 1.50M |
| 10 | `alloc_from_new_slab` | 5 | 1.56% | 1.25M |
| 11 | `__update_load_avg_se` | 5 | 1.56% | 1.25M |
| 12 | `kernfs_link_sibling` | 5 | 1.56% | 1.25M |
| 13 | `inode_init_always_gfp` | 5 | 1.56% | 1.25M |
| 14 | `kmem_cache_alloc_noprof` | 4 | 1.25% | 1.00M |
| 15 | `kmem_cache_free` | 4 | 1.25% | 1.00M |
| 16 | `number` | 4 | 1.25% | 1.00M |
| 17 | `__free_pages_ok` | 3 | 0.94% | 0.75M |
| 18 | `kernfs_name_hash` | 3 | 0.94% | 0.75M |
| 19 | `wakeup_preempt_fair` | 3 | 0.94% | 0.75M |
| 20 | `format_decode` | 3 | 0.94% | 0.75M |
| 21 | `device_add` | 3 | 0.94% | 0.75M |
| 22 | `add_uevent_var` | 3 | 0.94% | 0.75M |
| 23 | `down_write` | 3 | 0.94% | 0.75M |
| 24 | `__legitimize_path` | 3 | 0.94% | 0.75M |
| 25 | `blake2s.constprop.0` | 3 | 0.94% | 0.75M |

The top two functions account for only 16.9% of all samples. Outside the
early `__free_pages_core` plateau, the boot is broad and not reducible to one
hot function.

## Heuristic subsystem grouping

The following groups are disjoint function-name classifications over the
symbolized kernel samples. They are lower bounds: unrecognized functions are
not forced into a category.

| Group | Hits | Kernel samples | Sample-equivalent cycles |
| --- | ---: | ---: | ---: |
| VFS, kernfs, inode, device, kobject | 54 | 17.09% | 13.50M |
| Page initialization/freeing | 42 | 13.29% | 10.50M |
| Crypto/random | 40 | 12.66% | 10.00M |
| Memory primitives | 29 | 9.18% | 7.25M |
| Slab/page allocation | 23 | 7.28% | 5.75M |
| Formatting/printk | 21 | 6.65% | 5.25M |
| Scheduler/accounting | 19 | 6.01% | 4.75M |

These classifications cover 72.2% of kernel samples. The remaining samples
are distributed across many one- and two-hit functions.

## Phase-local symbol concentrations

| Cycle range | Most frequent sampled symbols |
| --- | --- |
| 4M to 10M | `memmap_init_range` 6, `__init_single_page` 6, `fdt_offset_ptr` 2, `__set_fixmap` 2, `memset` 2 |
| 10M to 20M | `__free_pages_core` 25, `__free_pages_ok` 3, `memset` 2 |
| 20M to 30M | `memset` 4, `kernfs_name_hash` 2, `wakeup_preempt_fair` 2 |
| 30M to 40M | `memcpy` 5, `blake2s_compress_generic` 4, `__update_load_avg_se` 2, `kernfs_link_sibling` 2 |
| 40M to 50M | `blake2s_compress_generic` 7, `__legitimize_path` 2, `inode_init_always_gfp` 2 |
| 50M to 60M | `blake2s_compress_generic` 3, `alloc_from_new_slab` 2, `memset` 2, `up_write` 2 |
| 60M to 70M | `blake2s_compress_generic` 7, `memset` 4, `memcpy` 3, `vsnprintf` 2 |
| 70M to 80M | `blake2s_compress_generic` 6, `__update_load_avg_se` 2, `memset` 2, `d_alloc_parallel` 2 |
| 80M to 83.75M | `memset` 2; all other observed symbols have one hit |

## What the two largest functions imply

### `__free_pages_core`

The hot loop advances by exactly one 64-byte `struct page` per iteration:

```asm
__free_pages_core:
    beq   a4,a2,done
    ld    a6,0(a5)
    sw    zero,52(a5)
    addiw a4,a4,1
    and   a6,a6,a3
    sd    a6,0(a5)
    addi  a5,a5,64
    j     loop
```

This is one load and two stores to each new 64-byte line, including a
read/modify/write dependency on the first word. It is a direct stress case
for L1D miss handling, posted-store admission/drain, store-to-load ordering,
and dependency latency. It is not primarily an instruction-fetch workload.

The q8/o8 prefetch configuration does not make this loop good. Its steady
250K-cycle intervals remain around 0.144 IPC. More prefetch capacity alone is
therefore not a sufficient fix.

### `blake2s_compress_generic`

This function uses a 384-byte stack frame, copies state and message data, and
then performs dense 32-bit add/XOR/rotate dependency chains. It stresses a
different part of the core:

- integer dependency latency and forwarding;
- issue-window readiness and wakeup;
- stack-local load/store traffic;
- call/return and `memcpy` overhead.

The PC histogram cannot distinguish these causes. BLAKE2 becoming the
largest whole-snapshot function does show that optimizing only the early
page-free loop would leave a substantial later backend workload.

## Comparison with the prior q4/o4 run

At the matched 83.25M-cycle point:

| Run | Retired instructions | IPC |
| --- | ---: | ---: |
| q8/o8, long distance 8 | 42,653,252 | 0.512351 |
| Prior q4/o4, maximum distance 4 | 42,908,693 | 0.515420 |

The q8/o8 run is behind by 255,441 retired instructions, or 0.595%.

This is **not a controlled causal comparison**. The binaries were built at
different dirty-worktree snapshots. It is evidence that the larger prefetch
configuration has not produced an obvious large boot improvement, but the
0.595% delta must not be assigned entirely to prefetch settings.

## Limitations and next measurement

This report is intentionally qualified:

- 250K-cycle sampling is coarse and misses short hot paths.
- Deterministic periodic sampling can alias with deterministic loops.
- `dbg_pc` is the last retired PC, not necessarily the instruction currently
  causing a stall.
- A function hit does not identify frontend, dependency, cache, TLB, CCX,
  DDR3, or retirement backpressure as the cause.
- "Sample-equivalent cycles" are visual scale only.
- This snapshot ends at 83.75M, before the Bash prompt.

A stronger follow-up is a runtime-gated in-memory simulator histogram sampled
every cycle. It should record, per PC:

- total cycles for which it is the last retired PC;
- cycles with zero retirement;
- cycles with one, two, or three retirements;
- frontend empty/held state;
- retirement-head incomplete state;
- LSU request wait;
- L1I/L1D miss or MSHR-full state;
- active barrier/fence state.

That would separate "this function was nearby when time passed" from "this
function exposed a particular machine bottleneck" without producing a
multi-gigabyte cycle trace.

## Reproduction

Generate the symbol histogram with:

```sh
python3 tools/linux_boot_pc_histogram.py \
  build/logs/linux-bp8-car1-fa3-fc0-iw1-sw1-rd32-prf31-\
l2m8-pf-short4-long8-q8-o8-r2-ppg1-ddr3-to-bash-20260728.log \
  --vmlinux /home/bill/src/linux/vmlinux \
  --end-cycle 83750000 \
  --top 50
```

The fixed 83.75M generated snapshot is:

```text
build/reports/linux-bp8-car1-fa3-fc0-iw1-sw1-rd32-prf31-\
l2m8-pf-short4-long8-q8-o8-r2-ppg1-boot-pc-histogram-83.75m.md
```

The live boot log is:

```text
build/logs/linux-bp8-car1-fa3-fc0-iw1-sw1-rd32-prf31-\
l2m8-pf-short4-long8-q8-o8-r2-ppg1-ddr3-to-bash-20260728.log
```
