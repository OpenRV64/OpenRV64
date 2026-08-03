# Coherent-complex performance

Last updated: 2026-08-03

## Scope

This document records the bare-metal shared-Sv39 coherence benchmark and its
standard one-hart, non-coherent baseline.  The immediate comparison isolates
the cost of routing one active hart through the four-hart coherent home.  A
separate section records full-Linux timed-DDR3 validation runs; those runs do
not change the scope of the bare-metal comparison and are not FPGA results.

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

## Linux SMP timed-DDR3 validation

These are complete-system OpenSBI/Linux runs on the four-hart coherent rig,
using one Verilator runtime thread, timed DDR3, DDR swizzle disabled, and L1D
prefetch enabled.  They are separate from the warmed bare-metal benchmark
above.  A successful run requires the interactive `openrv64# ` prompt, the
literal testbench PASS line, and simulator exit zero.  Managed runs additionally
require runner validation PASS; the explicitly identified compatibility replay
below was run directly and therefore has no runner result.

| Active harts | Run ID | Result | Cycles | Retired instructions | Aggregate IPC | Wall time |
| ---: | --- | --- | ---: | ---: | ---: | ---: |
| 1 | `linux-coherent-1h-ddr3-20260802T135359Z` | PASS, contextual only | 112,651,770 | 60,157,458 | 0.534013 | 7,491.047 s |
| 2 | `linux-smp-2h-ddr3-20260802T202655Z` | FAIL: forward-progress stall; manually stopped | >=133,000,000 | unavailable | unavailable | unavailable |
| 2 | `linux-smp-2h-ddr3-20260803T060504Z/fixed-replay` | PASS, fixed checkpoint replay | 124,872,576 | 78,294,231 | 0.626993 | 2,317.42 s replay only |
| 4 | `linux-smp-4h-ddr3-checkpoint34m-20260802T041852Z` | PASS | 151,569,992 | 102,412,877 | 0.675680 | 28,603.391 s |

The one-hart row is not source matched to the SMP rows.  Its kernel snapshot
was SHA-256 `6d7071598d68d66199ea96834538cf95b51aaa45550d6dd871c0ba1c66a450ba`
and its simulator snapshot was
`a819a79d8bbf9d8552acb5335ba805103948e2f89662e4dbd9c3bc36d096ce0c`.
It is therefore context, not a valid one-to-two-to-four-hart scaling point.

The failed two-hart and completed four-hart rows are source matched.  Both used
kernel snapshot SHA-256
`5daccb7717da2aa20fc7190fdf451eb1a5e88148018fc5ac7a71513e84a27637` and
simulator snapshot SHA-256
`c899ab31694b81f5f7cdcccabba28dba8b4408ec7ea86bd744812003f9d8c9b1`.
The target-visible configuration difference was the active/advertised hart
count.  The host-side checkpoint capture point also differed (25 million
cycles for 2H and 34 million for 4H).

The completed four-hart run retired 44,205,499, 17,965,672, 25,778,899, and
14,462,807 instructions on harts 0-3.  The corresponding per-hart CCX request
counts were 8,151,264, 3,908,712, 5,302,998, and 3,458,313.  It issued
2,074,946 memory reads and 979,739 memory writes; the DDR model reported the
same numbers of read and write bursts.

The failed two-hart rerun did not produce a performance result.  It printed the
serial-driver line after cycle 105,786,016 and before cycle 106,000,000, then
disabled the legacy ttyS0 console shortly after cycle 107,097,272.  From the
108,000,000-cycle progress sample through the final 133,000,000-cycle sample,
hart 0 remained at `0xffffffff8024b7e0`, the `klist_put` call into
`klist_release`, while UART output remained fixed at 7,841 bytes.  Later
hart-1 samples repeatedly symbolized to the OpenSBI `spin_lock` path.  The run
was manually stopped after 25 million sampled cycles without boot-thread
progress; it had no prompt, testbench PASS, simulator result, or runner
validation result.  Cycle tracing identified the owning defect as the
hart-local CCX command arbiter retaining a grant after a one-cycle requester
withdrew before the downstream handshake.  The stale data-side grant then
masked a later instruction-side request indefinitely.

The fixed two-hart row restored the source-matched machine state at cycle
106,900,000 and applied only the stale-grant correction to a
serialization-compatible simulator, SHA-256
`79dbd8659e2910c0fc53bb8a747978f861f6969687034cbfe83e1583b3d52585`.  It
reached the literal `openrv64# ` prompt and testbench PASS at cycle 124,872,576.
Harts 0 and 1 retired
51,214,548 and 27,079,683 instructions and issued 8,337,236 and 6,316,927 CCX
requests.  The memory model completed 1,389,271 reads and 712,707 writes; the
DDR model reported the same read- and write-burst counts.  The reported wall
time covers only the 106.9-million-cycle-to-prompt replay and was measured
while another four-hart Verilator run contended for the host, so it is not
comparable to the full-run wall times.  The target cycle and retirement
counters are restored architectural counters and cover the full boot.

The successful replay establishes two-hart functional completion with the
arbiter fix, but it is not a fresh reset-to-prompt build of the corrected RTL.
Linux also performs different initialization work for each active CPU, so a
boot-cycle delta combines software work with hardware contention.  Verilator
wall time measures host simulation throughput and is not target performance.

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

Run the Linux configurations with:

```sh
run/cfg/linux-coherent-1h-ddr3.cfg --rebuild
run/cfg/linux-smp-2h-ddr3.cfg --rebuild
run/cfg/linux-smp-4h-ddr3.cfg --rebuild
```

## Limits

- The bare-metal tables use fixed-latency AXI SRAM; only the Linux section uses
  timed DDR3.
- Bare-metal benchmark data is deliberately warmed before measurement.
- The one-active-hart bare-metal controls cannot validate probe behavior,
  ownership transfer, forward progress under contention, or aggregate scaling.
- The bare-metal suite does not cover Linux scheduling, interrupt delivery, TLB
  shootdowns, or long-duration user/kernel stress.  Reaching a Linux prompt is
  also not a substitute for that stress coverage.
- SMP is not considered viable on this evidence alone.  It still requires
  four active harts on the full FPGA plus extended user-mode and kernel-mode
  stress.
