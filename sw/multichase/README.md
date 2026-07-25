# Pointer-chase latency workload

This is a deterministic bare-metal adaptation of
[Google Multi-Chase](https://github.com/google/multichase), pinned when
adapted at commit `8cc86819b290d359f72d3f3308b6c2294cbc6455`.
Multi-Chase and the derived ring generator are licensed under Apache License
2.0; see `LICENSES/Apache-2.0.txt`.

The default workload is one dependent pointer chain over 16 MiB with a
256-byte stride, 256 KiB TLB-locality groups, and mixed pointer offsets within
each element. The touched cache-line working set is 4 MiB, sixteen times the
256 KiB OpenRV64 L2 and four times the 1 MiB HPI L2. One complete traversal
precedes the measured two traversals. The OpenRV64 target uses a benchmark-only
32 MiB simulated RAM layout. The static ring makes the RISC-V and AArch64
images execute identical links without putting allocator, random-number
generation, or image initialization inside the benchmark.

This is a latency test. A single chain has exactly one useful demand load in
flight, so it does not measure memory-level parallelism or the benefit of
multiple demand MSHRs. The hot loop contains no indirect branch: RAS and
indirect-target prediction are not under test.

Run the production DDR3 hierarchy and matched gem5 HPI model with:

```sh
make bench-pointer-chase-ddr3
make sim-pointer-chase-ddr3
make sim-pointer-chase-a53-gem5
```

`POINTER_CHASE_BYTES`, `POINTER_CHASE_STRIDE`,
`POINTER_CHASE_TLB_LOCALITY`, `POINTER_CHASE_STEPS`, and
`POINTER_CHASE_SEED` select a reproducible configuration. Steps must be a
multiple of the number of nodes so the final pointer supplies a cheap
correctness check.
