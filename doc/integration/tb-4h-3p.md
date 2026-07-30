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

The four-hart testbench still terminates in a fixed-latency 512-bit line-memory
model.  It is a coherence/core integration test, not a DDR timing or
performance model.

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

The separate one-hart timed-memory regression passed in 55,745 cycles at
0.9430 IPC through `openrv64_axi_ddr3`, `openrv64_timing_ddr3`, banked timing,
CCX, and L2.  That result validates the existing one-hart DDR path; it does not
make the fixed-latency 4h test DDR-timed.

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

The 2026-07-30 run passed:

```text
PASS: 4H coherent OpenSBI v1.9 on hart 0 with harts 1-3 held in reset;
ROM handoff, banner, M-to-S handoff, SBI TIME/STIP, DBCN, and payload completion
cycles=3543682 hart0_retired=4065191 hart0_ccx_req=126654
uart_bytes=2692 memory_reads=1725 memory_writes=624
```

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
fixed-latency backing memory.  It does not prove secondary-hart release,
simultaneous four-hart OpenSBI execution, reset-time directory cleanup, or
timed DDR3 operation.

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

Target completion time changed by only 5,451 cycles (0.070%): the hart-0
coldboot/timer path, not secondary spinning, determines this endpoint.
Secondary retirement fell from 12,432,107 instructions in aggregate to
1,278,346 (89.7%), and their aggregate CCX requests fell from 21,863 to 490
(97.8%). Verilator wall time fell from 1540.766 seconds to 1439.188 seconds
(6.59%). The wall-time comparison is an observed simulator result, not an RTL
frequency or physical-power measurement.

This proves concurrent ROM and OpenSBI entry, four-hart FDT discovery, HSM
parking of harts 1 through 3, and the existing hart-0 S-mode payload path
through the coherent hierarchy. That baseline only observed the HSM WFI
retiring: secondaries still spun because WFI resumed immediately. It still
uses fixed-latency backing memory. It does not prove SBI HSM restart of a
stopped hart, Linux SMP bring-up, reset-time directory cleanup, or timed DDR3
operation.

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
fixed-latency 512-bit line-memory model
```

The finite four-hart workloads tie interrupts low and do not enable the
platform devices.  In `+opensbi_held` mode the harness instead routes one
shared CLINT, PLIC, UART, and the normal boot ROM around L2 while leaving RAM
behind the same fixed-latency 512-bit model.  Neither mode includes the AXI
bridge or timed DDR model.

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
  secondary-hart release, OpenSBI/Linux boot, AXI, or timed DDR behavior in
  the four-hart hierarchy; the directed shootdown target covers only CLINT
  MSIP routing and its local M-mode handler; or
- fixed host affinity between one Verilator worker and one RTL hart.
