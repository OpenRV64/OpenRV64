# Linux generic BLAKE2s compression microbenchmark

This workload isolates the matching Linux kernel's
`blake2s_compress_generic()` implementation. The measured implementation
retains the kernel function's important structure:

- a 120-byte `struct blake2s_ctx`;
- out-of-line 64-byte message and 32-byte state copies;
- ten fully unrolled BLAKE2s rounds;
- 32-bit add, XOR, and rotate dependency chains; and
- repeated calls updating the same context.

The source was checked against Linux commit
`b95f03f04d475aa6719d15a636ddf32222d55657`. Its `vmlinux` contains a
7,984-byte generic compression function at `0xffffffff8016a744`, and its
`arch/riscv/boot/Image` matches `sw/Image`:

```text
23b7dd856339179ff7895de3eb1c4312b40d4dd00ca75a7d16d6f88638caec61
```

The default measurement performs 16 calls with one 64-byte block per call.
That preserves the function prologue, epilogue, and stack traffic that occur
when the kernel repeatedly hashes short inputs. Set `BLAKE2S_CALLS=1` to
emphasize a cold first call, or increase `BLAKE2S_BLOCKS_PER_CALL` to measure
multi-block throughput.

Build, verify, and measure:

```bash
make -j8 sw-blake2s
make -j8 sim-blake2s
make -j8 bench-blake2s
make -j8 bench-blake2s-ddr3
make -j8 sim-blake2s-sv39
make -j8 bench-blake2s-sv39
make -j8 sw-blake2s-a53-gem5
make -j8 sim-blake2s-a53-gem5
make -j8 bench-blake2s-ddr3 BLAKE2S_ZBB=1
make -j8 bench-blake2s-sv39 BLAKE2S_ZBB=1
```

Supported call counts are 1, 4, 16, and 64. Supported blocks per call are 1,
2, 4, 8, and 16. Verification runs after the measured region using a compact,
non-unrolled implementation and compares the complete chaining state.
`BLAKE2S_ZBB=1` builds the RISC-V images with Zbb and uses a separate `-zbb`
artifact directory so the baseline and Zbb binaries cannot be confused.

`PERF_BLAKE2S` reports measured cycles and retired instructions, calls,
blocks per call, total compressed blocks, and a final-state checksum.

The Zbb control is also the regression for the EX0 rotate datapath. The
two-32-bit-shifter implementation measured 20,206 cycles bare and 19,420
cycles under Sv39 for the default 16-block run, versus 34,456 and 33,621 for
the former serialized rotate sequencer. Word rotates accept one request per
cycle; 64-bit rotates intentionally accept one request per two cycles.

The Sv39 targets run the same measured routine in supervisor mode through a
non-identity mapping from VA `0x40000000` to PA `0x80000000`. Both translated
instruction and data accesses are required by the testbench, and timed DDR3
is enabled so this variant matches the Linux execution environment more
closely than the original bare-addressed target. Both images use the common
`sw/runtime` `c_init()`/`main()` startup contract.

This is an instruction-fetch and dependent-integer benchmark with small,
cache-resident data. DDR3 selection primarily affects initial code/data fill;
it is not a streaming-memory workload.

The AArch64 target runs the same benchmark region on gem5's Cortex-A53 HPI
model, bracketed by `m5_reset_stats` and `m5_dump_stats`. It requires the
configured `GEM5_AARCH64` executable and does not silently substitute an
unmatched historical HPI workload.
