# Sv39 fence suite

This suite tests ordinary `FENCE`, `FENCE.I`, and the existing RV64A
workloads while supervisor code runs through a non-identity Sv39 mapping.
It deliberately does not test SATP replacement or `SFENCE.VMA` under
outstanding traffic yet.  The bootstrap executes one `SFENCE.VMA` to activate
the initial page tables; directed workloads execute no translation fence.

## Ordering oracle

`+fence_check` terminates selected physical requests in a delayed CCX/home
model in `tb_top_3p_soc.v`.  A predecessor becomes complete only when that
external model launches its tagged response after 24 cycles.  A successor
request reaching the model before that point is a failure.  Retirement,
dispatch stalls, and local L1D acceptance are coverage signals only; they are
not the ordering oracle.

For cacheable memory, the coherent home is the visibility boundary.  Waiting
for a later dirty-line DRAM writeback would test replacement policy, not
architectural visibility.  I/O cases use a translated, non-cacheable physical
page at `0x10000000`.

The virtual layout is:

- `0x40000000..0x4003ffff` to `0x80000000..0x8003ffff`, supervisor RWX
- `0x40040000..0x40040fff` to `0x10000000..0x10000fff`, supervisor RW device

## Directed cases

`make sim-fence-sv39-case FENCE_CASE=N` runs one independent case.  Cases are
isolated so a deadlock or lost posted store cannot hide later results.

| Case | Directed operation |
| ---: | --- |
| 1 | store; `fence w,w`; store |
| 2 | store; `fence w,r`; load |
| 3 | load; `fence r,r`; load |
| 4 | load; `fence r,w`; store |
| 5 | `o,o`, `o,i`, `i,i`, and `i,o` on the device page |
| 6 | merged `sb`/`sh`/`sw`/`sd`; `fence w,r`; load |
| 7 | twelve posted stores to distinct lines; `fence w,r`; load |
| 8 | empty and back-to-back fences, followed by an observed store |
| 9 | executable-memory store; `fence.i`; instruction refetch |

Case 6 also checks the exact external 64-byte write payload and byte strobes.
Case 7 exceeds the historical eight-line pressure point.  All selected
requests and responses are delayed, covering outstanding L1D/CCX traffic.

Run all correctness cases, the Sv39 and bare end-to-end atomic workloads, and
the existing serialized/integrated atomic tests with:

```sh
make check-fence-sv39
```

The target continues through every subtest and returns nonzero if any failed.
`make fence-sv39-suite` also runs the microbenchmark.

## Microbenchmark

`make bench-fence-sv39` measures 1024 cache-hot iterations of matched
no-fence/fence pairs for `r,r`, `r,w`, `w,r`, and `w,w`.  The harness prints:

```text
PERF_FENCE_SV39_RESULTS iters=1024 rr_none=... rr=... ...
```

Incremental fence cost is `(fenced_cycles - baseline_cycles) / 1024`.
These are simulation-cycle costs for the fixed-latency SRAM configuration,
not frequency, silicon latency, or DRAM performance claims.

## Deferred translation-fence work

Outstanding loads, stores, PTW requests, and speculative reads across SATP
writes or `SFENCE.VMA` need a separate suite.  Combining them with this
ordinary-fence suite would obscure whether a failure is memory ordering,
translation invalidation, or shootdown completion.
