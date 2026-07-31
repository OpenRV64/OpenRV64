# Coherent-complex performance

Last updated: 2026-07-31

## Scope

This document records the bare-metal shared-Sv39 coherence benchmark and its
standard one-hart, non-coherent baseline.  The immediate comparison isolates
the cost of routing one active hart through the four-hart coherent home.  It
does not measure multicore scaling, DDR3 performance, Linux SMP viability, or
FPGA performance.

The measured working tree was based on commit
`66681f2db11c7291050993305f15a45dd556a408` and contained uncommitted coherence
work.  The commit alone therefore does not reproduce these numbers.

## Benchmark

The payload is [`sw/coherence_4h_shared_perf.S`](../../sw/coherence_4h_shared_perf.S).
Every configuration installs one shared Sv39 page table.  Initialization,
cache warming, and the start barrier are outside the measured interval; the
final memory fence is inside it.  Each case runs 64 iterations.  The eight-line
cases perform 512 logical operations with one active hart; the other cases
perform 64.

The cases are:

| Case | Work |
| --- | --- |
| `private` | Ordinary loads and stores to page-separated private lines |
| `different_lines` | Ordinary loads and stores to disjoint lines in one page |
| `same_line` | Ordinary load/store token handoff through one line |
| `same_page` | Token handoff through eight lines in one page |
| `different_pages` | Token handoff through eight lines in separate pages |
| `lrsc` | Ordered LR/SC token handoff through one line |
| `ticket` | Ticket lock protecting a separate shared counter |

With one active hart, the sharing and handoff cases preserve the multicore
code shape but cannot generate inter-hart contention.  They are controls, not
coherence-traffic workloads.

## Compared configurations

### Standard one-hart baseline

`sim-1h-3p-coherence-suite` uses `tb_top_3p_soc`, the standard one-hart CCX
compatibility wrapper and L2.  `ENABLE_L1D_COHERENCE_PROBES` is zero and the
multi-hart coherent home is absent.  It is therefore the non-coherent
baseline, although the one-hart CCX wrapper remains in the hierarchy.

The relevant configuration is:

```text
BP8, fetch mode 3, carousel enabled
issue window enabled, speculation window enabled, RD16
posted stores enabled
16 KiB L1I, 16 KiB L1D
256 KiB 8-way L2, 8 L2 MSHRs
L1D prefetch enabled
16 MiB fixed-latency AXI SRAM; DDR3 disabled
```

### Four-hart coherent path, one active hart

The comparison run uses the four-hart testbench and coherent home with hart 0
active and harts 1-3 held inactive.  It executes the source-matched one-hart
payload.  Consequently, a difference from the standard baseline reflects the
four-hart fabric/home path or its atomic protocol, not useful parallelism.

## One-hart baseline result

The standard one-hart suite completed all seven cases without a fatal error,
assertion, or timeout.  Every case produced the literal testbench PASS line.

| Case | Operations | Cycles | Operations/kcycle | Retired | IPC |
| --- | ---: | ---: | ---: | ---: | ---: |
| Private pages | 64 | 295 | 216 | 325 | 1.101 |
| Disjoint lines, same page | 64 | 295 | 216 | 325 | 1.101 |
| One shared line | 64 | 1,631 | 39 | 516 | 0.316 |
| Eight shared lines, same page | 512 | 5,405 | 94 | 4,548 | 0.841 |
| Eight shared lines, separate pages | 512 | 10,910 | 46 | 4,548 | 0.416 |
| Ordered LR/SC | 64 | 2,581 | 24 | 516 | 0.199 |
| Ticket lock | 64 | 4,447 | 14 | 710 | 0.159 |

The reported operations/kcycle and IPC values use integer truncation in the
testbench output.

## Coherent-home overhead with one active hart

| Case | Standard 1h cycles | Coherent path cycles | Cycle delta | Coherent overhead |
| --- | ---: | ---: | ---: | ---: |
| Private pages | 295 | 295 | 0 | 0% |
| Disjoint lines, same page | 295 | 295 | 0 | 0% |
| One shared line | 1,631 | 1,631 | 0 | 0% |
| Eight shared lines, same page | 5,405 | 5,405 | 0 | 0% |
| Eight shared lines, separate pages | 10,910 | 10,910 | 0 | 0% |
| Ordered LR/SC | 2,581 | 3,029 | +448 | +17.4% |
| Ticket lock | 4,447 | 4,951 | +504 | +11.3% |

For these finite, warmed, one-hart cases, ordinary loads and stores match
cycle-for-cycle.  This is evidence that inserting the current four-hart
fabric and coherent home does not add observable ordinary-access latency in
this benchmark.  It is not proof that the fabric has zero cost for other
access patterns or under contention.

The atomic cases do expose overhead.  LR/SC costs 448 additional cycles and
the ticket lock costs 504 additional cycles because the coherent path retains
home-level reservation and atomic protocol work even when only one hart is
active.  This comparison cleanly isolates that cost; it does not establish
whether the cost is acceptable under multi-hart contention.

## Reproduction

Run the standard one-hart baseline with:

```sh
make COHERENCE_PERF_MAX_CYCLES=100000 sim-1h-3p-coherence-suite
```

Run the corresponding coherent one-active-hart controls with:

```sh
make COHERENCE_PERF_MAX_CYCLES=100000 \
    sim-4h-3p-coherence-1h-private \
    sim-4h-3p-coherence-1h-different_lines \
    sim-4h-3p-coherence-1h-same_line \
    sim-4h-3p-coherence-1h-same_page \
    sim-4h-3p-coherence-1h-different_pages \
    sim-4h-3p-coherence-1h-lrsc \
    sim-4h-3p-coherence-1h-ticket
```

Use `make sim-coherence-scaling-suite` for the complete standard baseline and
one-to-four-hart matrix.

## Limits

- Backing memory is fixed-latency AXI SRAM, not DDR3.
- Data is deliberately warmed before measurement.
- One active hart cannot validate probe behavior, ownership transfer, forward
  progress under contention, or aggregate scaling.
- These runs are bare metal.  They do not cover Linux scheduling, interrupt
  delivery, TLB shootdowns, or long-duration user/kernel stress.
- SMP is not considered viable on this evidence alone.  It still requires
  four active harts on the full FPGA plus extended user-mode and kernel-mode
  stress.
