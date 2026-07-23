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

## memcpy prefetch benchmark

`memcpy/memcpy.S` supplies 4 KiB and 64 KiB page-copy workloads for the
three-pipe native L1D/CCX path. Each loop iteration copies one aligned 64-byte
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

`AXI_3P_FREELOADER=1` is a stronger simulation-only backend bound. Cacheable,
unlocked RAM loads bypass L1D/CCX demand timing and return through a tagged,
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

## Prefetch characterization suite

The remaining prefetch workloads use the same native three-pipe L1/CCX
harness. Build every configuration-specific ELF, binary, map, and disassembly
with:

```sh
make sw-prefetch-benchmarks
make bench-prefetch-suite
make sim-prefetch-checks
```

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

Run them with:

```sh
make bench-stream-suite
make bench-stride-sweep
make bench-stencil5
make bench-lz4
```

Select one STREAM case with, for example:

```sh
make bench-stream STREAM_KERNEL=triad STREAM_BYTES=65536
make sim-stream-suite STREAM_BYTES=4096
```

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
outstanding CCX-prefetch count are both four; two fill-buffer entries are
reserved for demand. `PREFETCH_L1D_STREAMS` accepts one through four;
`PREFETCH_L1D_ADAPTIVE_ENABLE`,
`PREFETCH_L1D_MAX_DISTANCE`, `PREFETCH_L1D_QUEUE_LINES`,
`PREFETCH_L1D_OUTSTANDING`, and `PREFETCH_L1D_DEMAND_RESERVE` expose those
controls. Changing any value selects a separate Verilator build.

Each run prints issued, useful, late, dropped, and unused-replacement counts,
plus maximum adaptive depth seen. It also prints total native `PERF_CCX` reads
and writes; coverage without that traffic delta is not enough to judge a
prefetcher.

These tests can characterize cache-line coverage, pollution, and extra CCX
traffic now. The functional backing RAM does not represent real memory timing.
The L1D can keep multiple prefetch transaction IDs live, but meaningful depth,
outstanding-count, and bandwidth-pressure tuning still requires routing the
benchmark path through `mem_channel.v`. Functional-cycle deltas are not timing
evidence.

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

The ROM remains a policy-free jump to `0x8000_0000`; the trampoline supplies
the OpenSBI entry registers and jumps to fw_jump. The build script forces
OpenSBI-generated linker inputs to refresh, checks the linked entry address,
and writes bounded memory fragments under `build/opensbi/artifacts/`.

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
