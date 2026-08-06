# Linux page-freeing loop microbenchmark

This workload reproduces the two long sequential `struct page` loops observed
during Linux boot and provides a combined order-10 mode:

- `PAGEFREE_KERNEL=core`: `__free_pages_core+0x18..+0x34`
- `PAGEFREE_KERNEL=tail`: the common tail-page path at
  `__free_pages_ok+0x1d4..+0x1f4`
- `PAGEFREE_KERNEL=buddy`: repeated 1024-page core and 1023-page preparation
  passes followed by representative order-10 zone accounting, PageBuddy/order
  updates, and free-list insertion under an atomic lock

The source and disassembly were checked against the local matching
`/home/bill/src/linux/vmlinux`. Its `arch/riscv/boot/Image` has the same
SHA-256 as `sw/Image`:

```text
23b7dd856339179ff7895de3eb1c4312b40d4dd00ca75a7d16d6f88638caec61
```

The quick default uses 8,192 records (512 KiB), one eighth of the simulated
machine's full memmap. The full option uses 65,536 records (4 MiB), matching
the memmap footprint for the simulated 256 MiB Linux machine. The timed loop
operates on preinitialized records, so setup does not pollute the measurement.
A complete verification pass runs after timing.

Build and run all three functional variants:

```bash
make -j8 sim-pagefree-suite
```

Measure all three variants through the BP8/RD32 L1/ICX/L2 hierarchy with the
untimed AXI SRAM backend:

```bash
make -j8 bench-pagefree-suite
```

This target is useful for core/frontend throughput, but it is not comparable
to the normal Linux run. Use the banked DDR3 backend for that comparison:

```bash
make -j8 bench-pagefree-ddr3-suite
```

Use the named full targets when the complete 65,536-record sweep is needed:

```bash
make -j8 bench-pagefree-full-suite
make -j8 bench-pagefree-ddr3-full-suite
```

All targets also accept an explicit record count, for example
`PAGEFREE_RECORDS=4096`. Use `PAGEFREE_L1D_PREFETCH_ENABLE=0` for the
OpenRV64 prefetch-off control.

OpenRV64 runs print a `SIM_PROGRESS` heartbeat every 1,000,000 simulated
cycles. Set `PAGEFREE_PROGRESS_CYCLES` to change the interval, or to `0` to
disable progress output.

Run the two isolated cross-ISA semantic equivalents on gem5's HPI AArch64
model:

```bash
make -j8 sim-pagefree-a53-gem5-suite
make -j8 sim-pagefree-a53-gem5-full-suite
```

HPI is a two-wide in-order ARMv8-A performance proxy, not Cortex-A53 silicon.
Its loop has the same descriptor layout and memory operations, but a different
ISA instruction stream. The combined `buddy` mode is currently RISC-V only;
it is deliberately not included in the HPI suite without a separately
validated AArch64 allocator sequence.

`PERF_PAGEFREE` reports loop cycles, retired instructions, record count, and
cycles through a post-loop `FENCE`. The ordinary harness counters remain
available for frontend, backend, cache, prefetch, and memory diagnosis.

The isolated `core` and `tail` modes are instruction/data-path
microbenchmarks. Linux does not execute them as two complete independent
4 MiB sweeps: it normally runs the core pass for a 1024-page block, enters
`__free_pages_ok()`, processes its tail pages, and performs allocator work
before advancing. Therefore, summing their independent times is only a
diagnostic comparison.

Use `buddy` when that block cadence and allocator memory traffic matter. It
models the no-merge order-10 fast path used by this kernel configuration:
lock, free-page and block accounting, head order/PageBuddy state, circular
free-list insertion, and unlock. It does not import the complete Linux call
path, zone layout, VM-event/static-key machinery, page-to-zone/PFN lookup, or
Sv39/platform history. It is structurally closer to the boot phase, but it is
not instruction-matched Linux.
