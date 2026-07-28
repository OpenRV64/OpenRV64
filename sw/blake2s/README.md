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
```

Supported call counts are 1, 4, 16, and 64. Supported blocks per call are 1,
2, 4, 8, and 16. Verification runs after the measured region using a compact,
non-unrolled implementation and compares the complete chaining state.

`PERF_BLAKE2S` reports measured cycles and retired instructions, calls,
blocks per call, total compressed blocks, and a final-state checksum.

This is an instruction-fetch and dependent-integer benchmark with small,
cache-resident data. DDR3 selection primarily affects initial code/data fill;
it is not a streaming-memory workload.
