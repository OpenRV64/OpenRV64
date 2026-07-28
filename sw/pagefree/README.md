# Linux page-freeing loop microbenchmark

This workload reproduces the two long sequential `struct page` loops observed
during Linux boot:

- `PAGEFREE_KERNEL=core`: `__free_pages_core+0x18..+0x34`
- `PAGEFREE_KERNEL=tail`: the common tail-page path at
  `__free_pages_ok+0x1d4..+0x1f4`

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

Build and run both functional variants:

```bash
make -j8 sim-pagefree-suite
```

Measure both variants through the BP8/RD32 L1/CCX/L2 hierarchy with the
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

Run the cross-ISA semantic equivalent on gem5's HPI AArch64 model:

```bash
make -j8 sim-pagefree-a53-gem5-suite
make -j8 sim-pagefree-a53-gem5-full-suite
```

HPI is a two-wide in-order ARMv8-A performance proxy, not Cortex-A53 silicon.
Its loop has the same descriptor layout and memory operations, but a different
ISA instruction stream.

`PERF_PAGEFREE` reports loop cycles, retired instructions, record count, and
cycles through a post-loop `FENCE`. The ordinary harness counters remain
available for frontend, backend, cache, prefetch, and memory diagnosis.

This is an instruction/data-path microbenchmark. It does not reproduce buddy
list manipulation, zone locking, page-table setup, or the surrounding
`memblock_free_pages()` call sequence.

Linux also does not execute these as two complete independent 4 MiB sweeps.
It normally runs the core pass for a 1024-page block, enters
`__free_pages_ok()`, processes the tail pages, and then performs allocator
work before advancing. Therefore, summing the two isolated microbenchmark
times is only a diagnostic comparison, not a prediction of the complete
Linux phase.
