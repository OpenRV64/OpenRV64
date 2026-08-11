# Bare-metal software

`uart.c` is a freestanding RV64I/Zicsr platform test linked into the 256 MiB
RAM window at `0x8000_0000`. The boot ROM transfers control there after reset.

The firmware configures the 16550-compatible UART for divisor 1, routes UART
source ID 1 through the PLIC, and arms a CLINT machine-timer deadline. UART RX
and TX are serviced from the PLIC's supervisor-external interrupt. This
bare-metal firmware leaves SEIP undelegated and handles cause 9 through its
machine trap vector. A newline ends the input line; carriage return immediately
before it is stripped.

Given:

```text
codex\n
```

the serial output is:

```text
hello codex\n
```

If no complete line arrives within 4096 `mtime` ticks, the machine-timer ISR
cancels the deadline and the interrupt-driven UART transmits `timeout\n`.

Build the ELF and flat image with:

```sh
make sw-uart
```

Run both the successful-input and timeout boots against the integrated
platform with:

```sh
make sim-uart-firmware
```

The toolchain prefix can be overridden with `RISCV_CC` and
`RISCV_OBJCOPY`. The default is Arch Linux's `riscv64-elf-*` toolchain.

## RV64D DAXPY integration payload

`fp/daxpy.S` is a finite, self-checking 4PF bring-up payload. It executes four
256-element kernels with software unroll factors 1, 4, 16, and 32 over private
copies of a repeated binary-exact data pattern. It records kernel-only `cycle`
and `instret` deltas in a table addressed by `a1` at the final `EBREAK`.
The larger variants expose integrated FPU overlap while retaining
`FLD`/`FMADD.D`/`FSD` traffic. The u16 body preloads fifteen independent pairs
before a one-element tail; because RV64D lacks enough registers for 32
simultaneously independent DAXPY elements, the u32 body contains two
fifteen-wide waves and a two-element tail. The payload checks
`fflags == 0`, and verifies the stored double-precision result bits using
integer loads. Build its ELF, flat binary, disassembly, and 256-bit memory
image with:

```sh
make sw-fp-daxpy
```

A retired `EBREAK` with `a0 = 0x44415850595f4f4b` (`DAXPY_OK`) is success.
The `DAXPY_BD` and `DAXPY_FL` signatures distinguish stored-data and floating
flag failures. The existing 1P/3P cores do not enable F/D, so this payload is
an input only for the separate 4PF core regression. Run the complete path with
`make sim-top-4pf`; 1P and 3P still reject F/D.

`fp/fmadd32.S` is a compute-only pipeline microbenchmark. Its loop body has
exactly 32 adjacent `fmadd.d f0,f1,f2,f3,rne` instructions and repeats 32
times. Since `f0` is destination-only, the stream has a same-destination WAW
relationship but no arithmetic RAW dependency. The payload checks the final
10.0 result and `fflags`, and reports kernel-only counters plus FPU handshake
overlap through `make sim-top-4pf-fmadd32`.

`fp/faults.S` installs a machine-mode trap handler and checks that FP load and
store access faults reuse ordinary LSU causes and addresses. It also selects a
reserved dynamic rounding mode to force an execution-time FPU rejection and
checks standard illegal-instruction cause 2, `mepc`, and instruction `mtval`.
Build it with `make sw-fp-faults` or run it with
`make sim-top-4pf-faults`. The success signature is
`a0 = 0x4650464c545f4f4b` (`FPFLT_OK`).

## Sv39 CoreMark-derived wrapper

`coremark_loop_vm_start.S` runs the CoreMark-derived loop in supervisor mode
through a non-identity Sv39 mapping. Machine-mode boot installs a 16 MiB PMP
region, writes `satp`, executes `sfence.vma`, and enters S mode with `mret`.
Three statically linked page-table pages map virtual
`0x4000_0000-0x4001_ffff` to physical
`0x8000_0000-0x8001_ffff`; the supervisor entry point is
`0x4000_1000`. A/D bits are preset because the current PTW uses Svade
semantics.

Run the translated workload through the BP8, fetch-lookaside-mode-3,
16-entry-retirement, issue/speculation-window, posted-store,
L1D-prefetch, L2/AXI/banked-DDR3 configuration with:

```sh
make sim-core-3p-icx-l2-vm
```

The test requires observation of Sv39 in `satp`, supervisor mode, translated
instruction and data traffic in the physical alias, and at least three PTW
reads. It also checks the same final `a0` signature as the Bare run. This is a
functional VM test, not a fully matched VM performance result.

## Synchronized four-hart bare performance payload

`coremark_4h_bare_perf_start.S` runs the finite CoreMark-derived parser loop
concurrently on all four harts in S-mode with `satp` Bare. Text and read-only
data are shared; each hart has a separate 4 KiB result/stack page and parser
sink. A software barrier excludes machine-mode setup and start skew from the
per-hart measurements.

Build the software image or run it on the four-hart coherent rig with:

```sh
make sw-coremark-loop-4h-bare-perf
make sim-4h-3p-bare-perf
```

`CORE_4H_BARE_PERF_ITERATIONS` selects the number of parser calls per hart and
defaults to 16. Each hart records raw start/end `cycle` and `instret` values,
their deltas, and a deterministic signature accumulated across all calls. The
testbench requires complete, internally consistent records and identical
instruction counts and signatures before reporting:

- per-hart IPC: that hart's measured `instret` delta divided by its measured
  cycle delta;
- aggregate IPC: the sum of all four `instret` deltas divided by the interval
  from the earliest start to the latest end.

This is a synchronized throughput test, not a CoreMark score. Its small hot
working set primarily exercises concurrent core, shared-L2, and coherence
throughput. The default four-hart testbench uses fixed-latency 512-bit backing
memory, so the result is not evidence about DDR3 performance or Linux SMP
stability.

## Shared-Sv39 L2 coherence performance suite

`coherence_4h_shared_perf.S` isolates coherence traffic from useful-core
throughput. One source builds for one through four active harts; every active
hart installs the same Sv39 root and uses the same virtual-to-physical mapping.
Inactive harts remain in reset. Setup, cache warming, barriers, validation, and
result publication are outside the timed interval. The closing `fence rw,rw`
is inside it so the measured interval includes completion of every tested
write.

The seven cases are:

- `private`: one page-separated private line per hart, with no remote probes;
- `different_lines`: one disjoint line per hart, 1 KiB apart within the same
  page; any probes here expose non-demand residency or conservative directory
  state, not architectural false sharing;
- `same_line`: release-completed ordinary load/store ownership handoff on one
  shared line;
- `same_page`: eight independent handoff lines within one shared page;
- `different_pages`: eight independent handoff lines separated by 4 KiB;
- `lrsc`: deterministic turn-taking with `lr.w.aq` and `sc.w.rl`;
- `ticket`: `amoadd.d.aq` ticket allocation, a separate serving line, and a
  protected counter on a third line.

The ordinary handoffs use an explicit completion fence after the one-line
transfer or eight-line batch. Without it, posted stores can remain local while
the same hart polls for the token's return; that measures store-drain policy,
not a defined coherence handoff boundary. The ticket case validates the ticket
dispenser, serving counter, and protected counter independently. ISA AMOs are
lowered to coherent LR/SC transactions before ICX, so the harness reports LR
attempts plus successful and failed SC responses rather than expecting a raw
AMO opcode at the home.

Build or run with:

```sh
make sw-coherence-shared-perf
make sim-1h-3p-coherence-suite
make sim-4h-3p-coherence-suite
make sim-4h-3p-coherence-scaling-suite
make sim-coherence-scaling-suite
```

The one-hart suite is the noncoherent one-hart ICX/L2 control. The scaling
suite uses the coherent four-hart rig with one, two, three, then four active
harts. `COHERENCE_PERF_ITERATIONS` defaults to 64. Each run verifies the final
shared values and signatures, reports operations per thousand cycles, target
L2 reads and writes, LR attempts, invalidate probes, SC outcomes, and maximum
target-line L2 MSHR occupancy. Compare scaling only within one case: the
eight-line cases define eight logical operations per iteration, while the
other cases define one.

The instruction and data sides each have a 16-entry fully associative
micro-TLB in front of the shared 256-entry, four-way main TLB. The main array
stores 4 KiB leaves; a small fully associative sidecar retains superpage
translations. The LSQ translates ordinary loads and stores at admission and
submits physical addresses to L1D later. Micro-TLB and main-TLB hits can return
in the admission cycle, and a younger translation can overlap an older
physical L1D access. Translation misses remain limited by the single shared
PTW. Atomics and non-fast-path accesses retain the serialized precise path.

## Non-contiguous Sv39 zero benchmark

`zero/zero_sv39.S` zeros a contiguous 256 KiB supervisor virtual window. Its
64 virtual pages map onto every other physical page, leaving a 4 KiB physical
gap between adjacent mapped pages:

```text
VA 0x4004_0000 + i * 0x1000
  -> PA 0x8020_0000 + i * 0x2000, 0 <= i < 64
```

The load image seeds each mapped page with nonzero data. The timed target
stops after the stores and reports the `cycle` delta in `a0`; the full target
then reads every word back and checks the pass signature. The integrated
testbench also requires exactly 32,768 translated store admissions and
physical L1D submissions and checks every submitted PA against the expected
non-contiguous mapping.

```sh
make bench-zero-sv39
make sim-zero-sv39
```

## Atomic SoC tests

`atomic/atomic.S` is a self-checking RV64A test that runs on the production
three-pipe hierarchy: L1I/L1D, native ICX, shared L2, and the AXI SRAM model.
It covers successful and failed LR/SC sequences, reservation consumption and
local-store invalidation, and every integer AMO in both 64-bit and upper-lane
32-bit forms. The word cases also check sign extension and preservation of the
adjacent word.

Build the ELF, flat image, and disassembly with:

```sh
make sw-atomic
```

Run it through `tb_top_3p_soc` with:

```sh
make sim-atomic-soc
```

Success returns `ATOMICOK` in `a0`. A failure returns `ATOMFA` followed by a
16-bit case number. These are single-hart architectural tests: reservation
state currently lives in the LSU and AMOs are locally serialized read/write
pairs. They do not establish multicore atomicity at the L2/home agent.

## Sv39 fence suite

`fence/` contains independent external-boundary correctness cases and matched
cycle microbenchmarks for ordinary `FENCE` and `FENCE.I` under a non-identity
Sv39 mapping. It also runs the existing atomic tests, including the same
workload under Sv39.

```sh
make check-fence-sv39
make bench-fence-sv39
make fence-sv39-suite
```

See [`fence/README.md`](fence/README.md) for the case map, visibility-boundary
definition, and the intentionally deferred SATP/`SFENCE.VMA` stress scope.

The separate four-hart target covers the inter-hart software shootdown
sequence and its interaction with coherence invalidates and LR/SC
reservations:

```sh
make sim-4h-3p-tlbi-sv39
```

Hart 0 updates a shared PTE and performs its local `SFENCE.VMA`, remote harts
first prove their translations remain stale, then CLINT MSIP handlers execute
the remote fences and acknowledge completion. This is not an OpenSBI or Linux
shootdown-path test.

The focused two-hart IPI target runs without OpenSBI, but follows the same
firmware-owned CLINT path: S-mode enters a minimal M-mode handler with `ecall`,
the handler sets the peer's MSIP bit, and the peer wakes from `WFI`, clears the
level interrupt, and returns to S-mode. Both harts execute through one shared,
non-identity Sv39 map and ping-pong 4096 interrupts in each direction. A
deterministic per-hart xorshift sequence inserts 0--31 architectural NOPs
before every send, varying the interrupt/WFI phase while keeping failures
reproducible.

```sh
make sim-2h-3p-ipi-sv39
```

The testbench independently requires 4096 MSIP assertions, 4096 clears, and
4096 machine-software trap entries per hart, exact software receive counts,
WFI sleep on both harts, and no execution or IPI activity from harts 2-3.

## memcpy prefetch benchmark

`memcpy/memcpy.S` supplies 4 KiB and 64 KiB page-copy workloads for the
three-pipe native L1D/ICX path. Each loop iteration copies one aligned 64-byte
cache line. The source is already present in the load image, so source
generation does not warm the data cache before measurement.

Build both images and their disassemblies with:

```sh
make sw-memcpy
```

Run only the timed copy regions with:

```sh
make bench-memcpy
```

The benchmark stops at `memcpy_measure_end`; `a0` in the `PERF` line is the
copy's `mcycle` delta through the final ordering fence. It measures
software-visible completion; a posted lower-level store tail can still drain
afterward, as it can after a normal `memcpy` return. Run the
post-copy full comparison and require the `MEMCPYOK` result with:

```sh
make sim-memcpy
```

The individual targets are `bench-memcpy-4k`, `bench-memcpy-64k`,
`sim-memcpy-4k`, and `sim-memcpy-64k`. The AXI harness's
`AXI_3P_FREE_L1I_REFILLS` and `AXI_3P_FREE_L1D_REFILLS` controls can be used
to establish separate ideal-refill bounds. Its backing RAM is still a
functional fixed-latency model, not a DRAM timing model; prefetch distance and
bandwidth tuning require the memory-channel timing model in the measured path.

`memcpy/memcpy_sweep.S` adds a general scalar memcpy characterization sweep:

```sh
make bench-memcpy-sweep
```

It reports 162 `MEMCPY_SPAN` records: three repetitions of 54 size/alignment
cases. The aligned boundary sweep covers 0 through 65 bytes around scalar and
cache-line boundaries, then 127/128, 255/256, 511/512, 1 KiB, 4 KiB, and
64 KiB. Additional cases cover equal source/destination offsets of 1 and 7,
including the offset-specific thresholds at 63/64/65 and 70/71/72 bytes, and
unequal offsets `1:0`, `0:1`, and `3:5`. Each case has a disjoint buffer slot
with roughly 16 cache lines of separation, beyond the default four-line
maximum prefetch distance. Repetition zero is therefore the default-profile
cold access to that slot and repetitions one and two expose its warm behavior.
Every record includes byte count, offsets, alignment-path class, cycle and
retired-instruction deltas, bytes/cycle, and IPC. The run continues through a
full byte comparison and requires `MEMCPYOK`; `sim-memcpy-sweep` is an alias
for the same report-and-check run.

The 1P core faults naturally misaligned accesses wider than a byte. The 3P
core implements Zicclsm for ordinary scalar loads and stores to cacheable,
coherent main memory with a small ordered component-serial engine. Atomics
retain their alignment faults, and non-cacheable misaligned accesses remain
unsupported. `ENABLE_ZICCLSM` defaults to one on the 3P RTL tops. For OpenSBI
and Linux simulations, `OPENSBI_3P_ENABLE_ZICCLSM=0` disables the RTL feature
and removes it from the 3P FDT. The sweep deliberately models a portable
scalar implementation rather than depending on 3P-only misaligned `ld`/`sd`:
equal source/destination alignment uses a byte prologue followed by aligned
64-byte bulk iterations, while unequal alignment uses the Linux RISC-V
kernel's slow-access fallback shape: one byte load, one byte store, and one
loop branch per copied byte. Each timed span includes call/return and the final
ordering fence; the zero-byte case exposes that fixed cost. The sweep results
are still from the functional fixed-latency AXI test memory, so they
characterize core/cache behavior rather than DRAM bandwidth.

`AXI_3P_FREELOADER=1` is a stronger simulation-only backend bound. Cacheable,
unlocked RAM loads bypass L1D/ICX demand timing and return through a tagged,
pipelined oracle. `AXI_3P_FREELOADER_LATENCY` is MEM issue to registered
result and defaults to 3, the minimum supported by the current MEM/L1D
crossings. Posted stores still enter and drain the real L1D store buffer;
pending store bytes are forwarded into oracle load data. MMIO, translated
accesses, atomics, and stores remain on the real path. For a three-cycle
load-to-dependent-use experiment, also set
`AXI_3P_COMPLETION_FORWARD_MASK=4`; without that bypass, the value is ready in
three cycles but a dependent instruction can still wait for ordered
retirement. The mode removes demand-miss timeliness from the prefetch
experiment, so it is an upper bound rather than a prefetch score:

```sh
make bench-stream AXI_3P_FREELOADER=1 \
    AXI_3P_FREELOADER_LATENCY=3 \
    AXI_3P_COMPLETION_FORWARD_MASK=4
```

## Performance and prefetch characterization suites

The remaining prefetch workloads use the same native three-pipe L1/ICX
harness. Build every configuration-specific ELF, binary, map, and disassembly
with:

```sh
make sw-prefetch-benchmarks
make bench-performance-suite
make bench-prefetch-suite
make sim-prefetch-checks
```

`bench-performance-suite` is the default performance regression entry point.
It runs the prefetch characterization suite, then CoreMark and all four STREAM
kernels under Sv39 through the L1/ICX/L2/AXI/DDR3 hierarchy. STREAM runs once
to the timing boundary and once through full result verification. The Sv39
stages use the current BP8, fetch-lookaside-mode-3, confidence-gated profile;
set `PERFORMANCE_CONFIDENCE_GATE=0` only for an explicit ungated comparison.
`bench-prefetch-suite` remains available as the untranslated prefetch-only
subset.

Each source exposes `*_measure_begin` and `*_measure_end` symbols. The
`bench-*` targets stop when the end marker retires and report the workload's
`mcycle` delta in `a0`; setup and result verification are outside that timed
interval. The corresponding `sim-*` targets continue through full correctness
checks and halt on a workload-specific pass signature.

The data-side workloads are:

- `stream/stream.S`: integer copy, scale, add, and triad over aligned arrays.
  `STREAM_BYTES` is the size of each array and defaults to 64 KiB.
- `stride/stride.S`: exactly 1024 loads after a separate 32 KiB L1D eviction
  walk. `bench-stride-sweep` tests 64, 128, 256, 1024, and 4096-byte strides,
  changing footprint without changing the measured access count.
- `stride/stencil5.S`: a 64 KiB, five-neighbor integer stencil. Its sliding
  window retains neighbor reuse while demanding one new source word and one
  output store per result.
- `lz4/lz4.c`: a bounds-checked raw LZ4 decoder. Its fixed 1584-byte,
  64-sequence block expands to 64 KiB and exercises literal and dependent
  match-copy streams; it is not a one-token copy-loop surrogate.
- `multichase/pointer_chase.S`: a deterministic, static adaptation of Google
  Multi-Chase. Its default single dependent chain spans 16 MiB at a 256-byte
  stride, producing a 4 MiB touched-line working set. It measures exposed load
  latency, not memory-level parallelism.

Run them with:

```sh
make bench-stream-suite
make bench-stride-sweep
make bench-stencil5
make bench-lz4
make bench-pointer-chase-ddr3
make sim-pointer-chase-a53-gem5
```

Select one STREAM case with, for example:

```sh
make bench-stream STREAM_KERNEL=triad STREAM_BYTES=65536
make sim-stream-suite STREAM_BYTES=4096
```

Those targets use the direct functional ICX home. To run the same STREAM
image through the production memory hierarchy, use:

```sh
make bench-stream-ddr3 STREAM_KERNEL=triad STREAM_BYTES=65536
make sim-stream-ddr3 STREAM_KERNEL=triad STREAM_BYTES=65536
make bench-stream-magic STREAM_KERNEL=triad STREAM_BYTES=65536
make sim-stream-magic STREAM_KERNEL=triad STREAM_BYTES=65536
```

The Sv39 variants run the same kernel through a non-identity 256 KiB
supervisor mapping and require translated instruction fetches, data accesses,
PTW traffic, and fast-hit translated loads and stores:

```sh
make bench-stream-ddr3-vm-suite STREAM_BYTES=65536
make bench-stream-ddr3-vm STREAM_KERNEL=triad STREAM_BYTES=65536
make sim-stream-ddr3-vm STREAM_KERNEL=triad STREAM_BYTES=65536
```

The same-line store-extension regression uses the same non-identity Sv39
mapping but makes sixteen lines resident before issuing 4,096 translated
stores.  It verifies all data after the timed region and runs legacy tags,
synchronous tags without the extension, and synchronous tags with it:

```sh
make sim-store-extension-sv39-suite
```

The DDR3 targets route private L1 traffic through the one-hart ICX complex,
shared L2, 512-to-256-bit AXI adapter, multi-outstanding memory channel, and
banked DDR3 scheduler. Their default core configuration is BP8, fetch
lookaside mode 3, a 16-entry retirement queue, and enabled issue and
speculation windows. The run prints maximum L2 MSHR, timing-owner, and banked
command-queue occupancy. `PERF_MEMORY_CHANNEL*` reports accepted bursts and
beats, queue and timing wait cycles, maximum queue occupancy, and exact
declared AXI read coalescing. It also reports DDR commands joined to active
same-bank, same-row, same-direction runs. Unrelated queued requests may be
reordered so the controller can gather a contiguous read or write run.
Completions carry tags back to the memory channel, which preserves AXI order;
overlapping RAW, WAR, and WAW pairs remain age ordered, and completed read data
is snapshotted before younger writes may commit. `+require_ddr3_overlap` makes
lack of overlapping DDR commands a failure. The reported `mcycle` delta
remains a cycle-model result, not a frequency or physical-bandwidth claim.

The `*-stream-magic` variants retain that same L2, AXI adapter, memory-channel
storage, and ordering path, but replace the banked DDR3 scheduler with a
registered one-cycle timing backend. They are therefore a latency-control
measurement, not the direct AXI SRAM configuration.

The matched AArch64 scalar kernel can be run on the repository-pinned gem5
HPI model with:

```sh
make sim-stream-a53-gem5 STREAM_KERNEL=triad STREAM_BYTES=65536
```

The HPI image uses gem5 reset/dump pseudo-instructions around the same kernel
boundary and verifies the entire result afterward.  HPI is an A53-class model,
not an exact Cortex-A53, and its default 32 KiB L1D includes a degree-four
stride prefetcher.  Its cache and DDR timing therefore must not be conflated
with the functional OpenRV64 backing-memory timing.

`icache/icache.S` creates exact 4, 16, 64, or 256 KiB executable tapes. The
`fallthrough` pattern is straight-line code. `branch` visits each four-line
group in physical order 0, 2, 1, 3 with a taken direct jump on every line, so
blind next-line prefetch has only partial coverage. `call` puts a call/return
pair on every line. The measured tape performs no data accesses; a register
checksum catches skipped or repeated instructions.

```sh
make bench-icache-footprints ICACHE_PATTERN=branch
make bench-icache-patterns ICACHE_BYTES=65536
make sim-icache-patterns ICACHE_BYTES=4096
```

Pipeline CSV generation is disabled for these runs because it dominates
Icarus runtime and storage on the larger footprints. Set
`PREFETCH_PIPELINE_TRACE=1` when a detailed pipeline trace is needed.
Verilator is the default execution engine and its elaborated model is reused
across workloads with the same core parameters. Set `PREFETCH_ENGINE=icarus`
for the slower Icarus path. The suite pins the experimental frontend alternate
lookaside off for a stable baseline; opt in with
`PREFETCH_FETCH_ALT_LOOKASIDE=1`.

The integrated L1D address-stream prefetcher is enabled by default for these
targets. Run a matched off/on pair with:

```sh
make bench-stride STRIDE_BYTES=64 PREFETCH_L1D_ENABLE=0
make bench-stride STRIDE_BYTES=64 PREFETCH_L1D_ENABLE=1
```

`PREFETCH_L1D_MAX_STRIDE_LINES` defaults to 64, and
`PREFETCH_L1D_STREAMS` defaults to two independent address histories,
`PREFETCH_L1D_DISTANCE` is the initial depth and defaults to 1, and adaptive
read-ahead defaults to a maximum depth of 4. The default candidate queue and
outstanding ICX-prefetch count are both four; two fill-buffer entries are
reserved for demand. `PREFETCH_L1D_STREAMS` accepts one through four;
`PREFETCH_L1D_ADAPTIVE_ENABLE`,
`PREFETCH_L1D_MAX_DISTANCE`, `PREFETCH_L1D_QUEUE_LINES`,
`PREFETCH_L1D_OUTSTANDING`, and `PREFETCH_L1D_DEMAND_RESERVE` expose those
controls. Changing any value selects a separate Verilator build.

Each run prints issued, useful, late, dropped, and unused-replacement counts,
plus maximum adaptive depth seen. It also prints total native `PERF_ICX` reads
and writes; coverage without that traffic delta is not enough to judge a
prefetcher.

These tests can characterize cache-line coverage, pollution, and extra ICX
traffic now. Their direct ICX backing RAM does not represent real memory
timing. DDR timing is deliberately not attached to that ICX home: the modeled
memory hierarchy is shared L2 to AXI to DDR3. Run `make sim-l2-axi-ddr3` for
the focused hierarchy regression. It checks AXI burst conversion, banked DDR3
scheduling, uncached reads and writes, an L2 fill and hit, and multiple active
L2 misses.

## OpenSBI smoke boot

`tools/build-opensbi.sh` clones the pinned OpenSBI v1.9 release, verifies its
commit, and builds the generic FDT platform plus a RAM-resident trampoline and
S-mode smoke payload. OpenSBI requires a PIE-capable toolchain, so its default
prefix is `riscv64-linux-gnu-`; the two small bare-metal stages continue to use
`riscv64-elf-*`. The other build dependencies are Git, GNU Make, DTC, Python,
and Verilator.

The RAM image layout is:

```text
0x8000_0000  reset-ROM target and RAM trampoline
0x8010_0000  OpenSBI fw_jump
0x8020_0000  S-mode SBI smoke payload
0x80e0_0000  testbench completion word
0x8ff0_0000  flattened device tree
```

The ROM reads `mhartid` into `a0` and jumps to `0x8000_0000`; the trampoline
preserves that hart ID, supplies the remaining OpenSBI entry registers, and
jumps to fw_jump. The build script forces OpenSBI-generated linker inputs to
refresh, checks the linked entry address, derives the linked
`sbi_hsm_hart_wait()` WFI PC, and writes bounded memory fragments under
`build/opensbi/artifacts/`. `OPENRV64_HART_COUNT` selects a one-, two-, or
four-hart device tree.

Build only the artifacts with:

```sh
make opensbi
```

Run the integrated platform test with:

```sh
make sim-opensbi
```

Run the same boot contract on the fixed three-pipe baseline, including its
three-wide frontend and native 256-bit AXI RAM path, with:

```sh
make sim-opensbi-3p
```

The test uses Verilator by default and proves the OpenSBI banner, eight-entry
PMP isolation setup, M-to-S transition, SBI base and TIME ECALLs, machine-mode
STIP injection, a delegated S-mode timer trap, debug-console output, and payload
completion. The device tree advertises Svade and 256 MiB of RAM.
`make sim-opensbi-icarus` provides a much slower
Icarus path. Set `OPENSBI_DEBUG=1` only when an unoptimized OpenSBI build is
intentional; the script ignores an unrelated ambient `DEBUG` variable.

The focused four-core coherent harness provides two additional targets:

```sh
make sim-opensbi-4h-held  # only hart 0 leaves reset
make sim-opensbi-4h-smp   # all harts enter OpenSBI
```

The SMP target requires harts 1 through 3 to retire the exact build-derived
OpenSBI HSM WFI instruction, remain asleep there in M-mode, and requires hart
0 to complete the S-mode payload. WFI wake detection honors individual
interrupt-enable bits but does not require the global MIE/SIE bits, matching
the privileged ISA rule.

Two directed HSM targets replace the timer payload with
`opensbi_hart_start_payload.S`:

```sh
make sim-opensbi-2h-hart-start
make sim-opensbi-4h-hart-start
```

Hart 0 calls SBI HSM `hart_start` for every secondary with a distinct opaque
value. Each secondary verifies its SBI entry arguments, publishes and reads
back a private cache-line signature, performs 64 contended LR/SC increments
on one shared counter, and completes a command/response exchange with hart 0.
The testbench also requires every active secondary to have slept at the
build-derived OpenSBI HSM WFI before release, every active hart to reach
S-mode, the exact final counter value, correct writer-hart identity for the
private and response lines, and no traffic from reset harts in the two-hart
case. These targets use fixed-latency memory by default; set
`OPENSBI_HART_START_DDR3_ENABLE=1` for the timed-DDR3 backend.
