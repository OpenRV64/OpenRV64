# Linux page-free call-chain boot plateau

## Measurement header

- Report written: 2026-07-28 05:22 UTC
- Last updated: 2026-07-28 06:56 UTC
- Workload: single-hart OpenSBI v1.9 and Linux boot to static Bash
- Core: 3-pipe, BP8, carousel enabled, FA3/FC0, IW1/SW1, RD32,
  PRF31
- Memory hierarchy: 16 KiB L1I, 16 KiB L1D, 256 KiB 8-way L2,
  eight L2 merge entries, native 256-bit bus, timed DDR3
- Compared configurations:
  - `o8`: GenBus 8/8, prefetch max 8, queue 8, outstanding 8,
    demand reserve 2, page gating 1
  - `o4`: GenBus 8/8, prefetch max 8, queue 8, outstanding 4,
    demand reserve 2, page gating 1
- Progress sample period: 250,000 cycles
- Status: the `o4` Linux run is continuing past 51.0M cycles; a 50.0M-cycle
  checkpoint was saved successfully

The two Linux binaries were built from the same RTL worktree snapshot.  The
only hardware elaboration difference was
`L1D_PREFETCH_OUTSTANDING=8` versus `4`.  The Make wrapper changed between
the builds, but that change affected build parallelism rather than generated
hardware.

Binary hashes:

```text
o8 ee9656d1c9b8e934482b93f70a73d6a8a167cebb19030a3687a3565aa7a1e828
o4 651bdcf134d04caf70deb354a44389ff2b23e71eca62aa0a7be231ec78eba3ec
```

Logs:

```text
build/logs/linux-bp8-car1-fa3-fc0-iw1-sw1-rd32-prf31-l2m8-gb8x8-pf-short4-long8-q8-o8-r2-ppg1-ddr3-to-bash-20260728.log
build/logs/linux-bp8-car1-fa3-fc0-iw1-sw1-rd32-prf31-l2m8-gb8x8-pf-short4-long8-q8-o4-r2-ppg1-ddr3-to-bash-20260728.log
```

The RTL worktree changed after both Linux binaries were built.  In
particular, DDR bank/row swizzling was added to the platform path after the
`o4` binary timestamp.  Results below describe the hashed binaries, not the
later worktree.

## Result

The sustained low-IPC region is the repeated order-10 page-free call chain,
not 6.5 million cycles spent exclusively in the eight-instruction
`__free_pages_core` inner loop. The progress PC over-represents that loop
because it is sampled while retirement is stalled.

The sampled PC is:

```text
ffffffff802582c8 __free_pages_core+0x18
```

For the `o4` run, the 27 complete samples from 10.25M through 16.75M cycles
have:

| Statistic | Interval IPC |
|---|---:|
| Minimum | 0.140056 |
| Mean | 0.141241 |
| Maximum | 0.142164 |

This is a stable call-chain plateau, not a transient sample or a misleading
aggregate IPC calculation.

The apparent aggregate IPC falls throughout this interval because the boot
had accumulated faster work before entering the loop.  For example, the
`o4` run reports:

| Cycle | Retired instructions | Aggregate IPC | Interval IPC |
|---:|---:|---:|---:|
| 10,000,000 | 8,630,151 | 0.863015 | 0.208548 |
| 10,250,000 | 8,665,677 | 0.845431 | 0.142104 |
| 12,000,000 | 8,912,878 | 0.742739 | 0.140152 |
| 14,000,000 | 9,195,174 | 0.656798 | 0.140216 |
| 16,750,000 | 9,583,526 | 0.572150 | 0.142100 |

The interval IPC is the useful number for this phase.  Aggregate boot IPC is
contaminated by all earlier phases.

## Function body

The measured Linux image places the function at
`ffffffff802582b0`:

```asm
ffffffff802582b0 <__free_pages_core>:
ffffffff802582b0: 00100613  li      a2,1
ffffffff802582b4: ffffe6b7  lui     a3,0xffffe
ffffffff802582b8: 00b6163b  sllw    a2,a2,a1
ffffffff802582bc: 00050793  mv      a5,a0
ffffffff802582c0: fff68693  addi    a3,a3,-1
ffffffff802582c4: 00000713  li      a4,0

ffffffff802582c8: 02c70063  beq     a4,a2,ffffffff802582e8
ffffffff802582cc: 0007b803  ld      a6,0(a5)
ffffffff802582d0: 0207aa23  sw      zero,52(a5)
ffffffff802582d4: 0017071b  addiw   a4,a4,1
ffffffff802582d8: 00d87833  and     a6,a6,a3
ffffffff802582dc: 0107b023  sd      a6,0(a5)
ffffffff802582e0: 04078793  addi    a5,a5,64
ffffffff802582e4: fe5ff06f  j       ffffffff802582c8
```

Each steady-state iteration:

1. retires eight instructions;
2. reads one 64-byte `struct page` cache line;
3. clears a 32-bit field at byte offset 52;
4. masks and rewrites the 64-bit flags word at byte offset 0; and
5. advances exactly 64 bytes to the next descriptor.

The two stores target the same line loaded by the iteration.  The flags
store depends on the load through the `and`; adjacent iterations do not have
an architectural data dependency on each other.

It is incorrect to divide every 250K-cycle interval by eight instructions
per descriptor. Linux frees `MAX_PAGE_ORDER=10` blocks here. For each
1024-page block it:

1. executes the eight-instruction `__free_pages_core` loop over all 1024
   descriptors;
2. enters `__free_pages_ok()` and executes the common nine-instruction
   `__free_pages_prepare` tail loop over 1023 descriptors; and
3. performs the head preparation, zone lookup/locking, accounting, PageBuddy
   update, free-list insertion, VM-event work, and returns through the call
   chain.

The trace data confirms that cadence. Between 10.25M and 10.50M cycles, the
sampled descriptor address advances by 2,054 records while 35,414
instructions retire:

```text
17.241 retired instructions per descriptor
121.714 cycles per descriptor
```

The core loop accounts for 16,432 of those instructions. The other 18,982
instructions are real work; they cannot be treated as stalls inside the core
loop. Across 10.25M through 16.75M cycles, the address advances 53,040
descriptors while 917,849 instructions retire:

```text
17.305 retired instructions per descriptor
122.549 cycles per descriptor
```

The roughly 17 instructions per descriptor are exactly the scale expected
from an eight-instruction core pass followed by a nine-instruction
preparation pass. This corrects the earlier 56.6-cycles-per-descriptor
interpretation.

## PC sampling caveat

`dbg_pc` is updated by retirement and holds the last retired PC while the
core stalls.  It is not an exact active-stage PC sampler.  This explains why
the loop branch at `+0x18` dominates the samples.

That caveat does not invalidate the throughput measurement:

- `mcycle` and `minstret` provide exact interval IPC;
- every complete interval in the plateau samples the same symbol;
- the disassembly is the expected 64-byte-stride page loop; and
- the plateau persists for millions of cycles.

The safe claim is that retirement is slow while repeatedly executing the
page-free call chain, with the held retirement PC usually inside
`__free_pages_core`. The PC sample alone neither assigns the whole interval
to that loop nor identifies which cache, LSQ, ICX, L2, or DDR state owns
every stalled cycle. The 17.00M-cycle sample at
`__free_pages_ok+0x1d4` directly exposes the preparation pass that the
coarse PC histogram mostly hides.

## Outstanding-prefetch split

The L1D has sixteen ICX transaction IDs.  With four prefetch MSHRs, the
current allocator reserves IDs 12 through 15 for prefetch and leaves twelve
IDs for demand/store traffic.  With eight prefetch MSHRs, it leaves eight
IDs for main traffic.

Changing from `o8` to `o4` does not improve this Linux phase.

At the first fully enclosed 250K-cycle interval:

| Configuration | Retired in interval | Interval IPC |
|---|---:|---:|
| `o8` | 35,430 | 0.141720 |
| `o4` | 35,526 | 0.142104 |

Across the twelve cycle-aligned samples available in both aborted `o8` and
continuing `o4` runs:

| Configuration | Mean interval IPC |
|---|---:|
| `o8` | 0.141980 |
| `o4` | 0.141298 |
| `o4 - o8` | -0.000682 (-0.48%) |

This difference is negligible and is in the wrong direction for an
outstanding-ID starvation explanation.

Conclusion: 12 main / 4 prefetch remains the saner allocation, but the old
8/8 split did not cause the `__free_pages_core` plateau.

## GenBus depth

Both compared Linux binaries explicitly use:

```text
GENBUS_READ_BUFFER_DEPTH=8
GENBUS_WRITE_BUFFER_DEPTH=8
```

The older platform path also inherited 8/8 as the bridge default, although
the values were not exposed in the OpenSBI build tag.  Making GenBus8
explicit improves provenance; it does not by itself explain a throughput
change in these runs.

No GenBus4 versus GenBus8 causal Linux comparison has been run on a matched
source snapshot.

## Call-chain counter delta

### Run header

- Run completed: 2026-07-28 06:07 UTC
- Executable: the hashed `o4` Linux binary from the measurement header
- Inputs: identical OpenSBI, Linux image, FDT, plusargs, and elaboration
- Start snapshot: fresh deterministic run stopped at 9,750,000 cycles
- End snapshot: fresh deterministic run stopped at 16,750,000 cycles
- Method: subtract every cumulative end counter from the corresponding
  start counter
- Scope: the repeated page-free call-chain plateau, not a PC-gated count of
  only `__free_pages_core`

Logs:

```text
build/logs/linux-free-pages-rca-o4-9750k-20260728.log
build/logs/linux-free-pages-rca-o4-16750k-20260728.log
```

Log hashes:

```text
9750k  f35290b20aa41bf2596915629f0517d8d116da8ddd32696b8198c661061ce38e
16750k 66609a53daaa0d6298e12fdda7156b55eabc8cb663efeb5e86d1670371e74aaa
```

The two runs are cycle-deterministic through the common endpoint. The
subtracted interval contains 7,000,000 cycles and 1,005,512 retired
instructions, for 0.143645 IPC. This closely agrees with the independent
250K-cycle progress samples.

### Dominant state

| Counter delta | Cycles | Percent of interval |
|---|---:|---:|
| Retirement head incomplete | 6,466,893 | 92.38% |
| Completed instruction behind retirement head | 6,465,017 | 92.36% |
| Frontend held | 6,484,936 | 92.64% |
| Dispatch nonempty but no issue | 6,234,097 | 89.06% |
| Translated store ready but not ordered head | 6,124,485 | 87.49% |
| Hard barrier active | 32,588 | 0.47% |

`perf_store_order_wait_cycles` has a precise meaning in `lsq.v`: at least
one non-atomic store is valid, translation has completed without a fault,
the memory access has not been sent, and that store is not the ordered
retirement head. It is not a store-buffer-full counter.

The corresponding entry-cycle count is 6,127,775, only slightly larger
than the cycle count. There is usually one such younger store waiting,
rather than several stores saturating the LSQ.

### Resources that are not saturated

| Counter delta | Cycles | Percent of interval |
|---|---:|---:|
| L1D load request backpressure | 3,598 | 0.051% |
| LSQ load queue full | 2,295 | 0.033% |
| L1D store request backpressure | 692 | 0.010% |
| L1D store buffer full | 519 | 0.007% |
| LSQ store queue full | 342 | 0.005% |
| L1D demand MSHRs full | 327 | 0.005% |
| L2 lookup stall | 56 | 0.001% |
| DTLB pipe miss | 132 | 0.002% |
| PTW active | 134 | 0.002% |
| L2 MSHRs full | 0 | 0.000% |
| L2 bus wait | 0 | 0.000% |
| ICX request wait | 0 | 0.000% |
| AXI AR/AW/W/R/B wait | 0 | 0.000% |

There was one serial DTLB miss in the entire interval. Translation, queue
capacity, store-buffer capacity, L1D/L2 MSHR capacity, ICX admission,
GenBus/AXI backpressure, and barriers cannot explain a stall present for
roughly 6.5 million cycles.

### Prefetch result

| Counter delta | Events | Fraction |
|---|---:|---:|
| Prefetch issued | 117,266 | 100.00% of issued |
| Prefetch useful | 116,047 | 98.96% of issued |
| Useful and on time | 62,442 | 53.81% of useful |
| Useful but late | 53,605 | 46.19% of useful |
| Late in prefetch MSHR | 53,577 | 99.95% of late-useful |
| Prefetch dropped | 958 | 0.82% of issued |
| Prefetch useless | 364 | 0.31% of issued |
| Store poisoned prefetch fill | 171 | 0.15% of useful |
| Store poisoned demand fill | 0 | 0.00% |

The prefetcher recognizes the stream and is exceptionally accurate. The
problem is coverage latency: almost half of useful prefetches are still in
a prefetch MSHR when demand reaches the line. Queue and command lateness are
negligible; the late event is downstream of prefetch command issue.

The interval also contains 58,361 DDR read commands and 58,229 DDR write
commands. L2 and AXI report no admission backpressure, and the cumulative
DDR queue maxima remain one. This rules out a full queue, but the current
counters do not measure command-to-fill latency, so they do not yet
distinguish insufficient prefetch lead from serialized downstream service.

### Attribution

The direct facts are:

1. retirement waits on an incomplete head for 92.38% of the interval;
2. completed younger work exists behind it for almost every one of those
   cycles;
3. younger translated stores wait for ordered-head permission for 87.49%
   of the interval;
4. none of the translation, LSQ-capacity, cache-capacity, ICX, L2, or AXI
   full/wait counters is active at a comparable rate; and
5. the sequential prefetches are accurate but 46.19% late.

The high-confidence inference is that an older demand load is waiting for
its cache line. Younger instructions complete and younger stores translate,
but stores cannot access memory before becoming the ordered head. The
retirement queue then applies backpressure to issue and the frontend.

This older `o4` binary does not record the opcode of the incomplete
retirement head. Calling it a load in this source snapshot is therefore an
inference from the loop, the useful-but-late prefetches, and the absence of
store-access or other resource stalls. The following current-source run
measures the head class directly, but it is not source-matched to this older
`o4` delta.

## Direct retirement-head classification

### Run header

- Run completed: 2026-07-28 06:56 UTC
- Git commit: `43230abb95a6df9f4539f819920ff19e589090d3`
- Worktree: dirty; the executable includes the current uncommitted RTL and
  testbench changes
- Executable configuration: BP8, carousel 1, FA3/FC0, IW1/SW1, RD32,
  PRF31, GenBus 8/8, prefetch outstanding 4, timed DDR3, row swizzle 1
- Executable SHA-256:
  `d172ef4993abcca436c1ca324deb9589e95ae1791289ca8781c1ee15bf46bb3c`
- Measurement window: 9,750,000 through 16,750,000 cycles
- Method: the C++ host captured a non-serialized baseline at 9,750,000
  cycles and subtracted the five cumulative RTL counters at the exact stop
  cycle
- Checkpoint: saved at the start boundary and verified at 513 MiB

Artifacts:

```text
build/logs/linux-free-pages-head-block-xsw1-9750k-to-16750k-20260728.log
build/checkpoints/linux-free-pages-head-block-xsw1-9750k-20260728.vls
```

Log SHA-256:

```text
9f38bff990065b384d1ee6934e8ab8b7490074a6903651cee401f9628b75f033
```

The counter classifies every cycle counted by
`retire_head_incomplete` from the retirement-record metadata captured at
allocation. The mutually exclusive priority is store, load, branch/jump,
hard-order barrier, then ALU/other. Read-modify-write instructions therefore
count as stores. The testbench reports a fatal accounting error unless the
five classes sum exactly to the existing incomplete-head counter.

| Incomplete retirement-head class | Cycles | Percent of classified cycles |
|---|---:|---:|
| Load | 3,451,297 | 69.76% |
| Store, including read-modify-write | 1,184,168 | 23.94% |
| ALU/other | 213,440 | 4.31% |
| Branch or jump | 78,094 | 1.58% |
| Barrier/hard-order | 20,188 | 0.41% |
| **Total/accounted** | **4,947,187** | **100.00%** |

The accounting is exact:

```text
incomplete=4947187
load=3451297 store=1184168 branch=78094 barrier=20188 alu=213440
accounted=4947187
```

Loads are directly established as the primary retirement-head blocker in
this current-source, swizzled run. Stores are also material at 23.94%;
describing them all as younger work waiting behind a load would be wrong.
Branch, barrier, and ALU/other heads together account for only 6.30%.

This run is not a controlled row-swizzle comparison with the older `o4`
binary: it includes intervening RTL changes as well as swizzle 1. Its
9.75M--16.75M execution rate also differs from the older stable 0.14-IPC
plateau. The head-class result is direct for the current source, but it must
not be retroactively assigned to the older binary as an exact distribution.

## Directed pagefree proxy

`sw/pagefree/pagefree.S` preserves the isolated core and preparation loops
and now also provides `PAGEFREE_KERNEL=buddy`. The combined mode repeats the
observed order-10 cadence: 1024 core records, 1023 tail records, then
representative zone accounting, PageBuddy/order state, circular free-list
insertion, and atomic lock/unlock.

The following are the older isolated-core proxy results; they do not include
the newly added combined mode:

| Proxy configuration | Cycles | Instructions | IPC | Approx. cycles per iteration |
|---|---:|---:|---:|---:|
| Timed DDR3, prefetch disabled | 988,750 | 65,539 | 0.066285 | 120.69 |
| Timed DDR3, max4/q4/o4 | 260,233 | 65,539 | 0.251847 | 31.77 |
| Timed DDR3, max8/q8/o4, GenBus8 | 181,497 | 65,539 | 0.361102 | 22.15 |
| AXI SRAM, max4/q4/o4, 65,536 records | 589,847 | 524,291 | 0.888859 | 9.00 |

The max8/q8/o4 proxy reports:

```text
prefetch issued=8197
prefetch useful=8191
prefetch useful_pct=99.93
prefetch on_time_useful=2027
prefetch late_useful=6164
prefetch useless=0
```

This shows that the standalone loop can be prefetched effectively.  It does
not prove that the Linux loop sees the same behavior.

The new combined `buddy` mode was also measured over 8,192 descriptors with
timed DDR3, max8/q8/o4, GenBus 8/8, page gating 1, and DDR bank/row swizzling
disabled:

| Cycles | Instructions | IPC | Instructions/descriptor | Cycles/descriptor |
|---:|---:|---:|---:|---:|
| 347,595 | 139,495 | 0.401315 | 17.028 | 42.431 |

The instruction density now matches the Linux call chain closely
(17.028 versus 17.305 instructions/descriptor), but the proxy remains
2.89 times faster per descriptor (42.431 versus 122.549 cycles). Adding the
block cadence and representative buddy-list traffic does not reproduce the
Linux slowdown. It makes the benchmark structurally less wrong, but it also
shows that omitted buddy work was not the primary explanation.

The max8/q8/o4 proxy was built after the Linux binary, while DDR timing and
bank/row mapping RTL was changing.  It is therefore a reference result, not
a source-matched causal comparison.

Additional differences between even the combined proxy and Linux include:

- bare physical addressing versus Sv39 translation;
- the direct `tb_top_3p_soc` harness versus the full platform wrapper;
- an isolated loop versus Linux cache, TLB, store-buffer, and DDR history;
- a fixed 8,192-record array versus the allocator's real physical placement;
- no concurrent kernel initialization traffic; and
- different source timestamps for the latest proxy and Linux binaries.

The proxy/full-Linux gap is real, but the current evidence does not assign it
to Sv39, physical placement, platform integration, or stale-source DDR
mapping.

## What is ruled out

The current data rules out:

1. **A progress-print artifact.** The low value is exact
   `minstret / mcycle` over 250K-cycle intervals.
2. **A single unlucky interval.** Twenty-seven consecutive complete samples
   average 0.141241 IPC.
3. **A wrong symbol.** The sampled address resolves directly to
   `__free_pages_core+0x18`, and the surrounding instructions are the
   expected page-descriptor loop.
4. **A per-page fence.** The relevant core, preparation, and order-10 free
   path contains no per-page `SFENCE`.
5. **The 8-main/8-prefetch ID split as the primary cause.** Moving to
   12-main/4-prefetch changes matched interval IPC by less than one percent.
6. **GenBus depth silently remaining at four.** Both compared binaries
   explicitly elaborate GenBus read/write depth 8.
7. **Prefetch being fundamentally unable to handle the isolated instruction
   pattern.** The isolated timed-DDR3 proxy can sustain 0.361 IPC and reports
   nearly every issued prefetch useful.
8. **Store-buffer, MSHR, translation, ICX, L2, or AXI capacity.** Every
   corresponding full or admission-wait counter is below 0.06% of the
   measured call-chain interval; several are zero.
9. **Bad prefetch recognition or accuracy.** 116,047 of 117,266 issued
   prefetches are useful.
10. **Store poisoning as the primary loss.** Only 171 prefetch fills and no
    demand fills are poisoned during the interval.

## What is not established

The current data does not establish:

- the exact head-class distribution in the older, source-matched `o4`
  counter delta;
- the distribution from prefetch issue to L1D fill;
- the number of cache lines of prefetch lead at demand arrival;
- whether late fills are caused primarily by insufficient prefetch distance,
  the four-prefetch outstanding limit, L2 service, or DDR response latency;
- exact PC-gated counter totals for `__free_pages_core` alone;
- whether the allocator's physical address stream interacts badly with DDR
  bank/row mapping; or
- whether the post-build DDR swizzle changes remove the plateau.

The existing phase delta identifies the blocked dependency chain. It does
not yet identify why downstream prefetch latency exceeds the available
lead.

## Required next measurement

Add source-matched counters or a trace for:

- retirement-head age and, if exact instruction attribution is required,
  its PC and opcode while incomplete;
- prefetch issue, ICX acceptance, L2 lookup, DDR command, response, L1D
  fill, and first-demand timestamps;
- prefetch lead in cache lines at first demand;
- instantaneous prefetch-MSHR, L2-MSHR, GenBus, and DDR-owner occupancy;
- DDR row hit/miss and command-to-response latency; and
- entry/exit gating for `ffffffff802582b0..ffffffff8025831b`.

The fastest workflow is to save a checkpoint at the start boundary, restore
it, take an external counter baseline, and report deltas at the end boundary.
Maximum-occupancy counters cannot be subtracted like monotonic event
counters; they must be cleared at restore or tracked as windowed maxima by
the host harness.

Then run a controlled matrix from one frozen source snapshot:

| Variable | Values |
|---|---|
| Harness | bare proxy, Sv39 proxy, full Linux platform |
| Prefetch | off, max4/q4/o4, max8/q8/o4 |
| GenBus | 4/4, 8/8 |
| DDR bank/row swizzle | off, on |
| Physical array placement | proxy default, Linux `mem_map`-matched |

The Sv39 proxy and Linux platform must use the same L1D, ICX/L2, GenBus,
DDR configuration, memory image placement, and RTL build.  Without that
control, another fast proxy result will not explain the Linux plateau.

## Reproduction commands

Symbolize and disassemble the function:

```sh
riscv64-elf-addr2line -f -i -p \
    -e /home/bill/src/linux/vmlinux 0xffffffff802582c8

riscv64-elf-objdump -d \
    --start-address=0xffffffff802582b0 \
    --stop-address=0xffffffff8025831c \
    /home/bill/src/linux/vmlinux
```

Run the max8/q8/o4 timed-DDR3 proxy:

```sh
make bench-pagefree \
    PAGEFREE_KERNEL=core \
    PAGEFREE_RECORDS=8192 \
    PAGEFREE_DDR3=1 \
    PAGEFREE_REQUIRE_ARGS=+require_timed_memory \
    PAGEFREE_L1D_PREFETCH_MAX_DISTANCE=8 \
    CORE_3P_ICX_L2_L1D_PREFETCH_QUEUE_LINES=8 \
    CORE_3P_ICX_L2_L1D_PREFETCH_OUTSTANDING=4 \
    CORE_3P_ICX_L2_L1D_PREFETCH_DEMAND_RESERVE=2 \
    CORE_3P_ICX_L2_GENBUS_READ_DEPTH=8 \
    CORE_3P_ICX_L2_GENBUS_WRITE_DEPTH=8
```
