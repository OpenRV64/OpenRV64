# Four-hart 3P shared-Sv39 and atomic integration

## Main-based port: 2026-07-30 UTC

The `ccx-merge` branch imports this four-hart variant onto main at
`bcc49fa3b2b0`.  Coherent L1D probes and coherent atomic reservation clearing
remain explicit `openrv64_rv64_top_3p` options and default off.  The public
one-hart wrappers hard-disable and tie off those interfaces, so the port does
not change the one-hart module boundary.

The source branch's `SPEC_LOAD_BASE` and `SPEC_LOAD_SIZE` testbench parameters
were not ported.  Current main permits ordinary cacheable loads to translate
across unresolved branches and uses the resolved physical cacheability check
to hold MMIO/non-cacheable accesses at the ordered head.  Reintroducing the
older virtual-address eligibility window would regress that policy.

The four-hart testbench now has two backing-memory modes.  The finite
coherence workloads retain the fixed-latency 512-bit line model.  The OpenSBI
targets default to a 512-to-256-bit generic-bus adapter, 256-bit AXI, and the
existing timed DDR3-1600 endpoint.  `OPENSBI_4H_DDR3_ENABLE=0` retains the
old OpenSBI memory model for controlled comparisons; the build identity
records the selected backend and all queue/mapping parameters.

The main-based port passed the following focused regressions:

```sh
make -B sim-exec-top-3p sim-backend-3p sim-top-3p sim-core-3p-magic
make -B sim-dispatch-window-3p sim-lsq sim-lsu-misaligned
make -B sim-zicclsm-context sim-top-axi-3p
make -B sim-exec-lsu-rv64-a sim-atomic-context
make -B sim-ccx-4h-l1d-directory-l2
make -B sim-4h-3p-sv39 sim-4h-3p-shared-sv39
make sim-4h-3p-bare-configured sim-4h-3p-atomic-sv39
make -B sim-core-3p-ccx-l2-vm
make sim-opensbi-4h-held
make sim-opensbi-4h-smp
```

| Main-based 4h test | Cycles | Completion cycles, harts 0..3 | CCX requests, harts 0..3 | L2 memory R/W |
| --- | ---: | --- | --- | ---: |
| Separate Sv39 | 71,311 | 68,240 / 69,375 / 70,288 / 70,299 | 1,537 / 1,539 / 1,539 / 1,538 | 147 / 16 |
| Shared Sv39 | 72,576 | 71,566 / 71,533 / 71,544 / 71,555 | 1,562 / 1,561 / 1,561 / 1,561 | 57 / 44 |
| Bare | 72,325 | 71,315 / 71,282 / 71,293 / 71,304 | 1,556 / 1,555 / 1,555 / 1,555 | 54 / 44 |
| Shared atomic Sv39 | 26,945 | 25,861 / 25,870 / 25,879 / 25,888 | 595 / 595 / 595 / 595 | 13 / 3 |

The main-based atomic run completed 64 successful SC operations per hart with
no SC failures.  Each hart accepted 192 remote probes and observed 192 local
reservation clears.  The randomized four-L1D directory/L2 test also passed
2,048 rounds and 8,192 ordinary operations.

Before the four-hart migration, the separate one-hart timed-memory regression
passed in 55,745 cycles at 0.9430 IPC through `openrv64_axi_ddr3`,
`openrv64_timing_ddr3`, banked timing, CCX, and L2.  The OpenSBI results below
now exercise that timed-memory stack from the four-hart coherent hierarchy.

### OpenSBI with secondary harts held in reset

`make sim-opensbi-4h-held` builds the same pinned OpenSBI v1.9 revision and
the same boot ROM implementation used by the normal OpenSBI platform test.
The four-core coherent topology is instantiated, but only hart 0 leaves reset.
Harts 1 through 3 remain in reset for the complete run.  The coherence home,
shared L2, and four probe endpoints remain out of reset.

The `+opensbi_held` harness mode adds:

- the normal `openrv64_soc_rom` contents at reset vector `0x1000`, widened
  across eight 64-bit ROM instances for the 512-bit L2 line interface;
- one shared four-hart CLINT, one PLIC, and one UART on the L2 device-bypass
  path;
- OpenSBI trampoline, `fw_jump`, supervisor payload, and FDT images at
  `0x80000000`, `0x80100000`, `0x80200000`, and `0x80f00000`;
- 1M-cycle progress records and an OpenSBI retirement trace on failure; and
- explicit checks for the OpenSBI v1.9 banner, M-to-S handoff, SBI timer
  interrupt, DBCN output, supervisor payload magic, no held-hart retirement
  or CCX traffic, and no coherence protocol error.

The initial 2026-07-30 fixed-latency run passed:

```text
PASS: 4H coherent OpenSBI v1.9 on hart 0 with harts 1-3 held in reset;
ROM handoff, banner, M-to-S handoff, SBI TIME/STIP, DBCN, and payload completion
cycles=3543682 hart0_retired=4065191 hart0_ccx_req=126654
uart_bytes=2692 memory_reads=1725 memory_writes=624
```

The default target was then migrated to timed DDR3 and passed:

```text
PASS: 4H coherent OpenSBI v1.9 on hart 0 with harts 1-3 held in reset;
ROM handoff, banner, M-to-S handoff, SBI TIME/STIP, DBCN, and payload completion
cycles=3634843 hart0_retired=4032724 hart0_ccx_req=137179
uart_bytes=2692 memory_reads=1719 memory_writes=629
ddr3 read_bursts=1719 write_bursts=629
ddr3 read_commands=1719 write_commands=629
ddr3 max_command_queue=1 max_timing_owners=1
walltime=935.039 s
```

This configuration uses 8-entry genbus read and write buffers, 8-entry DDR
read and write queues, a 16-command timing queue, burst-train limit eight, and
bank/row swizzling disabled.  Every L2 line became one 64-byte timed command
and one two-beat 256-bit AXI burst.  The observed queue maxima were one because
this workload and the globally blocking coherence home exposed only one
backing-memory command at a time; the result validates placement and protocol,
not DDR queue concurrency.

This run exposed a real progress bug before it passed.  A hart-0 I-cache fill
evicted a directory entry with a hart-0 D-cache sharer.  The home accepted the
probe, but the L1D array was in `STATE_ACCESS` waiting to send an AMO
write-through transaction to that same occupied home.  The home waited for
the invalidate ACK while the write waited for the home.  Targeted invalidation
now revokes a tag during a stalled write-through access; full-cache
maintenance still requires the cache to return to `STATE_RUN`.  If the probe
matches the pending write line, its later completion cannot recreate the
revoked private copy.  `make sim-l1-cache` contains a directed stalled-write
regression for this case.

The result is deliberately narrow.  It proves normal ROM-to-OpenSBI-to-S-mode
execution through the four-hart coherent hierarchy with three reset harts and
timed DDR3 backing memory.  It does not prove secondary-hart release,
simultaneous four-hart OpenSBI execution, reset-time directory cleanup, or
memory-level parallelism from multiple harts.

### OpenSBI with all four harts released

`make sim-opensbi-4h-smp` builds a four-hart FDT, releases all four cores from
reset, and selects hart 0 as the OpenSBI coldboot hart.  The ROM reads each
core's real `mhartid`; the RAM trampoline preserves it instead of forcing
zero.  The FDT describes CPU, CLINT, and PLIC interrupt contexts for harts
zero through three.

WFI now quiesces architectural fetch and issue until an individually enabled
local interrupt becomes pending. The test derives the exact
`sbi_hsm_hart_wait()` WFI address from the linked OpenSBI ELF using DWARF
attribution, passes it to the testbench, and requires each secondary both to
retire that instruction in M-mode and remain asleep at that PC. The generated
address is also retained in
`build/opensbi-4h-smp/artifacts/hsm-wfi-pc.txt`.

The pre-WFI-sleep 2026-07-30 baseline passed:

```text
PASS: 4H coherent OpenSBI v1.9; hart 0 completed the S-mode payload and
harts 1-3 retired HSM WFI at 00000000801173ec
cycles=7775571
retired=9650778,4115605,4265852,4050650
ccx_req=278793,7263,7357,7243
uart_bytes=2705 memory_reads=1782 memory_writes=710
```

The source-matched WFI sleep and backend-gating run then passed:

```text
PASS: 4H coherent OpenSBI v1.9; hart 0 completed the S-mode payload and
harts 1-3 sleep at HSM WFI 00000000801173ec
cycles=7770120
retired=9649110,425994,426057,426295
ccx_req=280034,155,164,171
uart_bytes=2705 memory_reads=1783 memory_writes=708
walltime=1439.188 s
```

The default target was then migrated to timed DDR3 and passed:

```text
PASS: 4H coherent OpenSBI v1.9; hart 0 completed the S-mode payload and
harts 1-3 sleep at HSM WFI 00000000801173ec
cycles=7865514
retired=9621510,449911,449357,449655
ccx_req=288306,163,163,171
uart_bytes=2705 memory_reads=1771 memory_writes=714
ddr3 read_bursts=1771 write_bursts=714
ddr3 read_commands=1771 write_commands=714
ddr3 max_command_queue=1 max_timing_owners=1
walltime=1580.648 s
```

At the first 1M-cycle checkpoint, harts 1 through 3 had already retired the
derived HSM WFI and were asleep at that PC.  They remained asleep through the
hart-0 platform report, M-to-S handoff, SBI timer interrupt, DBCN payload, and
completion magic.  The older fixed-latency result and this run are not a
source-matched performance comparison because intervening main changes alter
retirement and cache/TLB behavior.

Target completion time changed by only 5,451 cycles (0.070%): the hart-0
coldboot/timer path, not secondary spinning, determines this endpoint.
Secondary retirement fell from 12,432,107 instructions in aggregate to
1,278,346 (89.7%), and their aggregate CCX requests fell from 21,863 to 490
(97.8%). Verilator wall time fell from 1540.766 seconds to 1439.188 seconds
(6.59%). The wall-time comparison is an observed simulator result, not an RTL
frequency or physical-power measurement.

This proves concurrent ROM and OpenSBI entry, four-hart FDT discovery, HSM
parking of harts 1 through 3, and the existing hart-0 S-mode payload path
through the coherent hierarchy and timed DDR3. The pre-sleep baseline only
observed the HSM WFI retiring: secondaries still spun because WFI resumed
immediately. The current DDR-backed run requires them to remain asleep. It
does not prove SBI HSM restart of a stopped hart, Linux SMP bring-up,
reset-time directory cleanup, or scalable memory concurrency.

### Directed SBI HSM hart-start and coherent-memory test

`make sim-opensbi-2h-hart-start` and
`make sim-opensbi-4h-hart-start` replace the ordinary supervisor payload with
a finite HSM and coherent-memory test. Hart 0 issues `SBI_EXT_HSM_HART_START`
for every secondary. Each secondary must enter S-mode at the requested start
address with its requested opaque argument. The payload then checks:

- a private signature and readback on a separate cache line per hart;
- bidirectional cache-line command and response transfers between hart 0 and
  every secondary; and
- 64 contended LR/SC increments per active hart, with an exact final count.

The testbench independently observes every hart's OpenSBI HSM WFI, WFI sleep,
S-mode entry, retirement, CCX requests, signatures, responses, and LR/SC
counter. Inactive harts in the two-hart variant remain in reset and must
produce no retirement or CCX traffic.

The first two-hart run found a snoop-filter bookkeeping defect rather than an
OpenSBI defect. A deferred write-probe completion reconstructed its directory
entry from whichever SRAM row had most recently been looked up. An unrelated
lookup could therefore corrupt the saved sharer set while the probe was in
flight. The L2 MSHR now captures the complete I/D sharer snapshot and the
completion overwrites the matching directory entry from that snapshot.
`make sim-ccx-4h-l1d-directory-l2` passes 8,192 randomized operations and 128
atomic operations with this fix.

The fixed-latency two-hart run passed:

```text
PASS: 2H OpenSBI SBI hart_start woke all secondaries into S-mode and completed
private, bidirectional coherent, and contended LR/SC memory tests
cycles=4743722
active=0011 retired=5724567,319873,0,0 ccx_req=184868,1572,0,0
hsm_wfi=0010 hsm_sleep=0010 s_mode=0011 private=0011 response=0011 counter=128
sc success=222,74,0,0 failure=64,65,0,0
```

The fixed-latency four-hart run passed:

```text
PASS: 4H OpenSBI SBI hart_start woke all secondaries into S-mode and completed
private, bidirectional coherent, and contended LR/SC memory tests
cycles=7743410
active=1111 retired=9686324,441210,436493,429505
ccx_req=299825,1743,1835,2005
hsm_wfi=1110 hsm_sleep=1110 s_mode=1111 private=1111 response=1111 counter=256
sc success=236,74,74,74 failure=138,107,137,197
```

These are directed fixed-latency-memory tests. They are not timed-DDR3
performance results and do not establish Linux SMP viability. That claim
remains gated on four harts running on the full FPGA plus extended user-mode
and kernel-mode stress.

## Synchronized bare-metal software performance

`make sim-4h-3p-bare-perf` runs the same finite CoreMark-derived parser work on
all four harts after a shared software barrier. Machine-mode setup, barrier
arrival, result publication, and completion polling are outside each hart's
measured interval. Each hart records raw `cycle` and `instret` endpoints and a
signature accumulated across every parser call; the testbench rejects
incomplete deltas, mismatched signatures, or mismatched measured instruction
counts.

The 2026-07-31 run used the fixed-latency 512-bit backing memory at latency 8,
L1D prefetch enabled, and 16 parser calls per hart:

```text
PERF_4H_BARE iterations=16 signature=c2457f54a813c07b
parallel_start=638 parallel_end=878596 parallel_cycles=877958
total_instret=3363560 aggregate_ipc_x1000=3831
PERF_4H_BARE_HART hart=0 cycles=877958 instret=840890 ipc_x1000=957
PERF_4H_BARE_HART hart=1 cycles=874852 instret=840890 ipc_x1000=961
PERF_4H_BARE_HART hart=2 cycles=874897 instret=840890 ipc_x1000=961
PERF_4H_BARE_HART hart=3 cycles=874898 instret=840890 ipc_x1000=961
```

Aggregate IPC is the sum of the four measured instruction deltas divided by
the span from the earliest start to the latest end. It is 3.831 here; the
per-hart IPC range is 0.957-0.961. Start endpoints span 14 cycles. These are
source-matched concurrent-core throughput numbers, not a CoreMark score and
not a DDR3 result. The payload's small hot working set also makes it a poor
proxy for Linux memory behavior. It does not satisfy the project's SMP
viability criterion, which still requires the full FPGA and extended
user-mode and kernel-mode stress.

## Shared-Sv39 coherence scaling suite

The CoreMark-derived run above measures aggregate core throughput and is a
poor coherence benchmark. `sw/coherence_4h_shared_perf.S` instead keeps every
active hart on one shared Sv39 root, prewarms the target lines, excludes setup
and barriers from timing, and varies only the sharing pattern. Harts above the
selected active count remain in reset. The private control places each hart's
line on a separate 4 KiB page. A second disjoint control keeps the lines 1 KiB
apart within one page, separating page placement from actual address sharing.

The source-matched 2026-07-31 runs used 64 iterations, L1D prefetch enabled,
the 256 KiB eight-way L2 with eight MSHRs, and the four-hart harness's
fixed-latency 512-bit backing model at latency 8. `cycles / ops/kcycle` is
shown below. Operations are comparable down a column within a case, not
between cases: `same_page` and `different_pages` count eight independent line
transfers per iteration.

| Case | Pre-coherent 1H control | Coherent rig, 1 active | 2 active | 3 active | 4 active |
| --- | ---: | ---: | ---: | ---: | ---: |
| Private, disjoint pages | 295 / 216 | 295 / 216 | 305 / 419 | 308 / 623 | 311 / 823 |
| Disjoint lines, one page | 295 / 216 | 295 / 216 | 305 / 419 | 308 / 623 | 312 / 820 |
| One shared line | 1,631 / 39 | 1,631 / 39 | 3,485 / 36 | 5,153 / 37 | 6,691 / 38 |
| Eight shared lines, one page | 5,405 / 94 | 5,405 / 94 | 8,981 / 114 | 12,781 / 120 | 17,002 / 120 |
| Eight shared lines, eight pages | 10,910 / 46 | 10,910 / 46 | 12,103 / 84 | 17,208 / 89 | 20,663 / 99 |
| Ordered LR/SC handoff | 2,581 / 24 | 3,029 / 21 | 4,963 / 25 | 7,724 / 24 | 10,268 / 24 |
| Ticket lock | 4,447 / 14 | 4,951 / 12 | 7,733 / 16 | 13,274 / 14 | 19,065 / 13 |

The pre-coherent control is the one-hart CCX/L2 rig, not the four-hart
coherence home with three harts held in reset. Its fixed-latency endpoint is
not structurally identical to the four-hart harness. All target data is warm
before measurement, and the four ordinary-access cases match exactly at one
hart, but the topology distinction remains part of the result. Coherent
atomics are slower at one active hart because they still traverse the home
reservation protocol.

The four-active-hart protocol evidence was:

| Case | Target L2 reads/writes | Atomic LR attempts | Invalidate probes | SC success/failure | Max target MSHRs |
| --- | ---: | ---: | ---: | ---: | ---: |
| Private | 0 / 4 | 0 | 0 | 0 / 0 | 0 |
| Disjoint same-page lines | 0 / 4 | 0 | 3 | 0 / 0 | 1 |
| One shared line | 762 / 256 | 0 | 765 | 0 / 0 | 1 |
| Same-page lines | 2,809 / 2,048 | 0 | 2,821 | 0 / 0 | 4 |
| Different-page lines | 2,558 / 2,048 | 0 | 2,571 | 0 / 0 | 2 |
| LR/SC | 2,286 / 256 | 1,272 | 762 | 256 / 0 | 1 |
| Ticket lock | 1,669 / 768 | 263 | 1,156 | 256 / 7 | 1 |

These results show the intended distinction. Disjoint private work reaches
3.80-3.81x aggregate logical-operation throughput at four harts regardless of
whether the lines occupy one page or four. The same-page disjoint case still
generated one, two, and three remote probes at two, three, and four harts.
Because no hart architecturally touches another hart's line, those probes show
non-demand residency or conservative directory state; the present counters do
not distinguish prefetch residency from a directory false positive. A single
shared line remains about 36-39 operations/kcycle because ownership is
serialized.
The eight-line same-page case exposes four simultaneous target MSHRs and gains
some throughput, but it does not scale like private work. LR/SC and the ticket
lock remain serialization-bound. In the ticket test, 263 target LR attempts
equal 256 successful plus seven failed SC attempts, and software separately
validated the ticket dispenser, serving counter, and protected counter.

Run the complete controls and matrix with:

```sh
make sim-1h-3p-coherence-suite
make sim-4h-3p-coherence-scaling-suite
make sim-coherence-scaling-suite
```

This is fixed-latency, hot-data, bare-metal evidence. It is not a DDR3 result,
an FPGA throughput result, a general RVWMO litmus suite, or evidence that Linux
SMP is viable. The latter still requires four harts on the full FPGA and long
user-mode and kernel-mode stress.

## Historical source-branch validation: 2026-07-27 UTC

- Repository base: `fa83b59`, plus the uncommitted implementation described
  here.
- Four-hart top: `tb/tb_4h_3p.sv`.
- Verilator runtime worker budget: `--threads 4` for four instantiated harts.
  This enforces the requested one-thread-per-hart ratio.  Verilator may still
  schedule generated partitions dynamically; it does not promise permanent
  hart-to-host-thread affinity.
- Verilator compile parallelism: `-j 32`.
- Invocation rule: run the outer `make` without `-j`.  The target owns its
  32-way generated-C++ build; an inherited outer jobserver made that nested
  build effectively serial in the observed environment.
- Workloads: finite CoreMark-derived parser loop and a directed RV64A
  turn-taking test.  No CoreMark score is claimed.

Commands run:

```sh
make sim-4h-3p-sv39
make sim-4h-3p-shared-sv39
make sim-4h-3p-shared-sv39 CORE_4H_3P_L1D_PREFETCH_ENABLE=0
make sim-4h-3p-bare
make sim-4h-3p-bare CORE_4H_3P_L1D_PREFETCH_ENABLE=0
make sim-4h-3p-atomic-sv39
make sim-4h-3p-shared-suite
make sim-ccx-4h-l1d-directory-l2
make sim-exec-lsu-rv64-a sim-atomic-context
make sim-core-3p-ccx-l2-vm
```

All commands passed.  The complete-core results were:

The final four-hart Verilation rebuilt 147 generated C++ files in 42.392 s
wall time; Verilator reported 27.841 s CPU on the configured 32 compile
threads.

| Test | SATP arrangement | Cycles | Completion cycles, harts 0..3 | Retired, harts 0..3 | CCX requests, harts 0..3 | L2 memory R/W |
| --- | --- | ---: | --- | --- | --- | ---: |
| `sim-4h-3p-sv39` | four roots, same VA maps to separate physical prefixes | 66,320 | 62,574 / 64,102 / 65,119 / 65,309 | 56,324 / 54,796 / 53,779 / 53,589 | 1,542 / 1,541 / 1,542 / 1,541 | 155 / 16 |
| `sim-4h-3p-shared-sv39` | one shared root, hart-indexed private pages | 67,825 | 66,368 / 66,778 / 66,788 / 66,798 | 54,036 / 53,626 / 53,616 / 53,606 | 1,593 / 1,574 / 1,574 / 1,566 | 58 / 44 |
| `sim-4h-3p-atomic-sv39` | one shared root and one shared atomic line | 24,228 | 23,148 / 23,156 / 23,164 / 23,172 | 2,470 / 2,462 / 2,454 / 2,446 | 593 / 593 / 593 / 593 | 11 / 3 |

### L1D prefetch comparison: 2026-07-27 UTC

The shared-root workload was rebuilt and run with the L1D next-line prefetcher
both enabled and disabled.  Both models used four Verilator runtime threads.
The historical build directory included `pf0` or `pf1` and the then-current
speculative-load address window, so changing either elaboration setting could
not accidentally reuse an incompatible model.  The main-based port retains
only the prefetch setting in its build identity because main no longer has the
address-window parameters.

| L1D prefetch | Test completion | Hart completion cycles, 0..3 | Completion mean / spread | CCX requests, 0..3 | L2 memory R/W |
| --- | ---: | --- | ---: | --- | ---: |
| on (default) | 67,825 | 66,368 / 66,778 / 66,788 / 66,798 | 66,683 / 430 | 1,593 / 1,574 / 1,574 / 1,566 | 58 / 44 |
| off | 67,587 | 66,548 / 66,558 / 66,568 / 66,578 | 66,563 / 30 | 1,549 / 1,549 / 1,549 / 1,549 | 51 / 44 |

Disabling prefetch reduced final test completion by 238 cycles (0.351%) and
mean hart completion by 120 cycles (0.180%).  This was not a uniform speedup:
hart 0 finished 180 cycles later, while harts 1 through 3 each finished 220
cycles earlier.  The more defensible result is that prefetch increased
contention and completion skew in this globally serialized four-hart home.  It
added 111 CCX requests and seven backing-memory reads without improving the
tail.

The reported retired-instruction totals are not suitable for this comparison.
A hart spins at its completion label until the last mailbox becomes visible,
so an earlier-finishing hart accumulates extra loop retirements.  The
prefetch-on run's larger completion skew therefore also produced a larger
retirement count.

### Bare-address comparison: 2026-07-27 UTC

The same shared workload also ran in S-mode with `satp` left Bare.  Code and
data retain the same physical addresses and cache indices as the shared-Sv39
image.  These numbers were produced on the source branch, whose bare target
moved its speculative-load eligibility window from virtual `0x40000000` to
physical `0x80000000`.  The main-based port does not have that window.

| Address mode | L1D prefetch | Test completion | Hart completion cycles, 0..3 | Completion mean / spread | CCX requests, 0..3 | L2 memory R/W |
| --- | --- | ---: | --- | ---: | --- | ---: |
| Sv39 | off | 67,587 | 66,548 / 66,558 / 66,568 / 66,578 | 66,563 / 30 | 1,549 / 1,549 / 1,549 / 1,549 | 51 / 44 |
| Bare | off | 67,247 | 66,208 / 66,218 / 66,228 / 66,238 | 66,223 / 30 | 1,542 / 1,542 / 1,542 / 1,542 | 47 / 44 |
| Sv39 | on | 67,825 | 66,368 / 66,778 / 66,788 / 66,798 | 66,683 / 430 | 1,593 / 1,574 / 1,574 / 1,566 | 58 / 44 |
| Bare | on | 67,526 | 65,979 / 66,479 / 66,489 / 66,499 | 66,361.5 / 520 | 1,595 / 1,566 / 1,566 / 1,559 | 54 / 44 |

With prefetch disabled, removing Sv39 saved exactly 340 cycles per hart and
seven accepted CCX requests per hart.  The shared L2 reduced those 28 PTW
requests to four additional backing-memory reads.  Bare mode was 0.503%
faster at final test completion.

Direct handshake counters reject a store-fast-path explanation for this
workload.  Both the Bare and Sv39 prefetch-off runs allocated 3,255 stores per
hart, accepted 3,255 stores per hart through the tagged PMP/L1D fast path, and
accepted zero stores through the serial fallback.  In Bare mode,
`translation_bypass_i` marks each LSQ store translated at allocation and
copies its virtual address into the physical-address field; it does not send
the store through the translation state machine.  This evidence is narrower
than a general correctness proof: it does not exercise uncached stores,
atomics, PMP rejection, or every redirect/backpressure interleaving.

Within Bare mode, disabling prefetch saved 279 final-completion cycles
(0.413%) and 138.5 mean hart-completion cycles (0.209%).  It removed 118 CCX
requests and seven backing-memory reads.  This independently reproduces the
Sv39 result: current L1D prefetching causes small contention and completion
skew, not bus saturation.

An initial historical Bare run used the virtual speculative-load base and
completed in about 75,000 cycles.  That source-branch run is invalid as an
address-mode comparison because physical Bare loads fell outside its
eligibility window.  It is intentionally excluded from the tables and does
not describe current main scheduling.

The atomic run reached counter value 256.  Each hart completed exactly 64
successful SC operations after 257 LRs.  SC failures were zero.  Every
successful write invalidated three remote L1D copies: each hart accepted 192
probes and observed 192 reservation-clear events.  The final suite run reported
5.069 s aggregate CPU on four threads and 1.283 s wall time for this atomic
test.  Its shared-root test reported 31.383 s aggregate CPU on four threads
and 7.893 s wall time.  The earlier separate-root run reported 28.933 s
aggregate CPU on four threads.

The lower-level four-L1D directory test passed at cycle 113,615 after 2,048
randomized rounds, 8,192 ordinary operations, 2,113 stores, and 128 atomics.
The serialized RV64A LSU test, integrated atomic-context test, and one-core
Sv39 CCX/L2/AXI/banked-DDR3 regression also passed.  The last completed in
55,846 cycles with `a0=0x000000000a277880`.

## Instantiated hierarchy

```text
4 x openrv64_rv64_top_3p
  - fixed HART_ID = 0, 1, 2, 3
  - mhartid wired through the CSR path
  - private L1I and L1D
  - coherent reservation-clear input from its L1D probe endpoint
        |
        v
openrv64_ccx_line_crossbar
        |
        v
openrv64_ccx_coherent_protocol
  - independently tagged D/I sharer directory
  - one 64-byte LR reservation record per hart
  - one globally active home transaction
        |                         ^
        |                         |
        |                4 x independent L1D
        |                invalidate/ACK slots
        v
256 KiB shared l2_native
        |
        v
selectable backing memory
  - fixed-latency 512-bit line model for finite coherence tests
  - 512-to-256-bit genbus -> 256-bit AXI -> timed DDR3 for OpenSBI
```

The finite four-hart workloads tie interrupts low and do not enable the
platform devices.  In `+opensbi_held` mode the harness instead routes one
shared CLINT, PLIC, UART, and the normal boot ROM around L2. Both OpenSBI modes
default to the AXI/timed-DDR backend. Device requests wait for all accepted
RAM responses to drain before entering the untagged L2 response stream.

## Address-space tests

### Separate roots

All harts start at physical `0x80000000`, read their actual `mhartid`, and
select one of four Sv39 roots.  The same supervisor virtual range beginning at
`0x40000000` maps to a different 1 MiB physical prefix:

| Hart | Supervisor physical prefix | Root page table |
| ---: | ---: | ---: |
| 0 | `0x80000000` | `0x80020000` |
| 1 | `0x80100000` | `0x80120000` |
| 2 | `0x80200000` | `0x80220000` |
| 3 | `0x80300000` | `0x80320000` |

The test checks independent root fetches, physical prefixes, mailbox values,
retirement from all harts before first completion, and absence of home/probe
protocol errors.

### Shared root

All harts install identical SATP mode and PPN bits, naming the root at physical
`0x80020000`.  One three-level Sv39 table maps the 128 KiB range
`0x40000000-0x4001ffff` to `0x80000000-0x8001ffff`.

Code and read-only data are shared.  Four adjacent private pages at virtual
addresses `0x40002000`, `0x40003000`, `0x40004000`, and `0x40005000` provide
separate stacks, sinks, and completion records.  The workload derives the
page address from `mhartid`; the page table itself is not hart-specific.

## Atomic test and coherence contract

The counter is a 32-bit word at virtual `0x40001080`, initially zero.  Every
hart repeatedly executes `lr.w.aq`.  Only the hart satisfying
`counter % 4 == mhartid` attempts `sc.w.rl`, so successful stores advance the
counter in the exact hart order 0, 1, 2, 3.  Each hart stops after the counter
reaches 256 and records its completion and success count in its private page.

This is a shared-copy invalidation test, not an SC-contention test.  Zero SC
failures are expected under the deterministic turn rule: non-eligible harts
read and retain the line but do not attempt SC.  The meaningful coherence
evidence is the exact 768 remote probes, three per successful write, and 192
probe-driven reservation clears observed by each hart.

A coherent LR uses two phases:

1. L1D issues LR to the home before admitting the cached lookup.
2. The home establishes the hart's 64-byte reservation and conservatively
   records the L1D as a sharer.
3. L1D ignores the home-returned data and performs its normal cache lookup.
4. A resident clean hit supplies the architectural value.  A miss issues an
   ordinary shared read because the reservation already exists.

Reserve-first order is required.  Lookup-first could pair stale private data
with a new home reservation if another hart wrote between the lookup and
reservation transaction.

Any coherent write to the line clears matching home reservations.  Probe
acceptance clears the target hart's local architectural reservation before ACK.
SC first invalidates the requester's local copy, so the home excludes that
requester from the remote probe mask.  A redundant self-probe deadlocks: the
requester's L1D is waiting for its SC response and therefore cannot service a
probe whose ACK is required to produce that response.  After remote ACKs, a
successful SC clears the complete directory D-sharer vector and writes L2.

Reservation and ownership are separate.  The current private data state is
clean Shared/Invalid; there is no Exclusive or Modified owner and no
cache-to-cache data forwarding.  Adding dirty ownership later requires
data-bearing probes and a rule that an LR observes forwarded current data
before its reservation is established.

The assembly contains `.aq` and `.rl` encodings, but the current compatibility
path does not preserve the original AMO operation or `aq`/`rl` metadata at the
home.  This run therefore does not validate acquire/release ordering.

## Bugs exposed by the complete-core runs

- `HART_ID` reached the CCX bus but not the CSR implementation, so every core
  originally observed `mhartid == 0`.
- A full posted-store buffer could hold the shared L1 port while waiting for
  home progress, preventing an incoming probe from draining.  Posted-store
  admission is now gated when the buffer is full.
- A cache-hit LR originally had no point at which to create the home
  reservation.  The reserve-first two-phase path fixes that without hiding
  broken invalidation behind home-returned data.
- Probing the SC requester created the local circular wait described above.
  The home now probes only remote sharers and still clears all sharer metadata
  after successful SC.
- Deferred probe completion originally updated the directory from the SRAM's
  most recently read row. An unrelated lookup could replace that row while
  the probe was in flight. The L2 MSHR now carries the complete lookup sharer
  snapshot and overwrites the original entry on completion.

## Directed four-hart TLB shootdown

`make sim-4h-3p-tlbi-sv39` exercises translation invalidation, cache
invalidation, and atomic reservation state in one directed sequence:

1. all four harts install and warm the same old Sv39 leaf mapping;
2. harts 1-3 establish LR reservations and cache the reservation line;
3. hart 0 writes that line, requiring remote D-cache probes and reservation
   clears;
4. hart 0 rewrites the leaf PTE through a supervisor-writable alias, orders
   the PTE store, and executes its local `SFENCE.VMA`;
5. the remote harts prove that their old translations remain stale before
   shootdown;
6. hart 0 sets the real CLINT MSIP bits for harts 1-3; each remote M-mode
   handler executes `SFENCE.VMA`, clears MSIP, and acknowledges completion;
7. every hart reads the new physical page, and each remote SC proves failure
   after the earlier coherence invalidate cleared its reservation.

The final source-matched 2026-07-30 run passed in 3,672 cycles. Each hart
retired two
`SFENCE.VMA` instructions (bootstrap and directed) and emitted three
completion-tracked PTE fences (`satp`, bootstrap fence, directed fence).
Every hart fetched both old and new physical target lines. Harts 1-3 each
accepted a reservation-line invalidate probe and returned a nonzero SC
result.

This is a real hardware IPI/local-invalidate sequence, but it uses the
workload's small M-mode handler. It does not execute the OpenSBI SBI IPI path
or Linux `flush_tlb_*` code, and it does not cover selective VPN/ASID
invalidation because the current hardware deliberately over-flushes all local
translation state.

## Scope limits

This proves four complete cores can execute concurrently through Sv39 and the
shared CCX/L2 hierarchy, and that the directed atomic schedule causes real
remote L1D invalidation.  It does not prove:

- scalable coherent throughput; the home serializes globally;
- dirty ownership, cache-line forwarding, Exclusive/Modified states, or
  writeback;
- concurrent SC failure/retry or AMO retry under active contention;
- acquire/release, fence, or general RISC-V memory-model litmus behavior;
- L1I coherence or executable-data modification;
- DMA or external coherent-master interaction;
- the standard shared/atomic workloads do not cover interrupt routing,
  secondary-hart release, OpenSBI/Linux boot, AXI, or timed DDR behavior;
  the OpenSBI targets cover AXI/timed DDR, CLINT/PLIC/UART discovery, and HSM
  parking; the fixed-latency HSM tests cover secondary restart into S-mode and
  directed coherent-memory traffic but not Linux SMP; the directed shootdown
  target covers only CLINT MSIP routing and its local M-mode handler; or
- fixed host affinity between one Verilator worker and one RTL hart.
