# Banked GPR experiments

This is the running measurement log for banked-GPR changes.  The parity track
uses the compact CoreMark-derived loop in `sw/coremark_loop.c` under Sv39,
through the current L1, ICX, L2, GenBus, and timed-DDR3 platform.  The earlier
bare-physical matrix is retained below as a secondary controlled experiment.
Neither workload is the official EEMBC CoreMark benchmark and neither
produces a reportable CoreMark score.

## Sv39 RD32 parity track

The 2026-08-31 matched banked comparison holds the entire core and platform
configuration fixed across its three banked rows: two 16-entry banks with two
physical read ports and one write port per bank, BP8, mode 3, confidence gate
enabled, pair-stack depth 2, strict WAW/RAW handling, no branch forwarding,
no issue/speculation window, retirement depth 32, and timed DDR3.  The
forwarding mask progresses from 0, to 3 for live EX0/EX1 results, to 7 for
live EX0/EX1 plus registered load-only MEM0 results.

| Configuration | Cycles | Retired | IPC | Versus banked 2R1W control | Versus current normal 3P |
|---|---:|---:|---:|---:|---:|
| Current normal 3P RD32 reference | 47,439 | 52,592 | 1.1086 | not configuration-matched | baseline |
| Banked 2R1W, no forwarding | 187,302 | 52,589 | 0.2808 | baseline | 3.948x cycles |
| Banked 2R1W, EX0/EX1 forwarding | **160,297** | 52,589 | **0.3281** | **-27,005 (-14.42%)** | 3.379x cycles |
| Banked 2R1W, EX0/EX1 + load-only MEM0 forwarding | **123,621** | 52,589 | **0.4254** | **-63,681 (-34.00%)** | 2.606x cycles |

All four runs passed the checksum, Sv39/S-mode, alias, PTW, and timed-memory
requirements:

- normal RD32: `coremark-sv39-linux-rd32-ddr3-20260831T202101Z`;
- banked 2R1W control:
  `coremark-sv39-3p-banked-2r1w-ddr3-20260831T202101Z`;
- banked 2R1W plus EXU forwarding:
  `coremark-sv39-3p-banked-2r1w-exu-forward-ddr3-20260831T202101Z`;
- banked 2R1W plus EXU and load-only MEM0 forwarding:
  `coremark-sv39-3p-banked-2r1w-exu-mem-forward-ddr3-20260831T220841Z`.

The normal row is a parity target, not an isolated register-file comparison.
It already enables branch forwarding, relaxed WAW, and the merged
issue/speculation window; the banked rows deliberately do not.  The previously
recorded current-baseline result in `doc/performance/current.md` is 45,999
cycles and 1.1433 IPC.  The current-tree rerun above is 1,440 cycles (3.13%)
slower, so the archived number is retained as historical data rather than
silently substituted for the rerun.

### Banked conflict and operand-wait counters

| Counter | 2R1W control | EXU forwarding | EXU + MEM0 | MEM0 delta vs EXU |
|---|---:|---:|---:|---:|
| Any bank-conflict cycles | 4,382 | 4,054 | 3,633 | -421 |
| Read-bank-conflict cycles | 989 | 813 | 616 | -197 |
| Write-bank-conflict cycles | 3,393 | 3,241 | 3,017 | -224 |
| Same-word read/write conflict cycles | 0 | 0 | 0 | 0 |
| Cycles blocked on storage reads | 53,451 | 41,764 | 33,224 | -8,540 (-20.45%) |
| Cycles blocked by pending writers | 113,147 | 61,261 | 39,967 | -21,294 (-34.76%) |
| EXU-forward cycles | 0 | 15,034 | 14,398 | -636 |
| EXU-forwarded operands | 0 | 18,111 | 17,299 | -812 |
| MEM0-forward cycles | 0 | 0 | 15,412 | +15,412 |
| MEM0-forwarded operands | 0 | 0 | 20,037 | +20,037 |

These are overlapping predicates, not an additive stall decomposition.  A
cycle may be blocked by a pending writer for one operand and by a storage read
for another.  `bank_conflict_cycles` means an asserted address-phase request
was denied because the target bank had no remaining port; its read and write
subcounters show which side waited.  `read_write_conflict` means an accepted
read and accepted write named the same word and the write-data bypass supplied
the read response.  This workload happened not to exercise that case.

The directed run `3p-banked-directed-20260831T202004Z` passed after the
forwarding change.  It proves that a dependent operand can consume a
producer-ID-qualified EXU completion while the architectural scoreboard bit
is still busy, in addition to the existing 2R1W, held-retry, bypass, and
redirect-drain checks.

The load-forwarding directed run `3p-banked-directed-20260831T214031Z` adds a
tagged load followed immediately by a dependent integer operation.  It checks
that the registered MEM0 result is consumed while the exact producer still
owns the architectural destination and that both instructions retire with the
expected values.  MEM0 is deliberately load-only: non-load completion traffic
on that lane cannot satisfy an operand.  During an issue cycle whose operand
came from MEM0, live EX0/EX1 forwarding is suppressed to avoid a combinational
LSU issue/response loop; this is a conservative timing boundary, not a claim
of maximum forwarding bandwidth.

The final platform ACT4 run
`compliance-act4-platform-3p-banked-ddr3-20260831T214056Z` passed all 93
preserved RV64IMA tests with 2R1W banks, EX0/EX1 forwarding, registered
load-only MEM0 forwarding, the integrated L2, and timed DDR3
(`pass=93 fail=0`).

Each comparison below uses the same binary and core/platform controls: BP8,
mode 3, fetch carousel enabled, confidence gate enabled, pair-stack depth 2,
no completion or branch forwarding, conservative WAW/RAW handling, no issue or
speculation window, retirement depth 32, posted stores, 16-KiB L1I and L1D,
256-KiB 8-way L2, and the timed-DDR3 model.  All three configurations were
launched concurrently and retired the same 52,563 instructions with the same
`a0=0x0a277880` result.

## Earlier compact bare-physical loop on DDR3

| Configuration | Physical GPR banks | Cycles | Retired | IPC | Versus normal 3P | Versus banked 1R1W |
|---|---|---:|---:|---:|---:|---:|
| Normal 3P control | Unbanked multiport PRF | 79,318 | 52,563 | 0.6627 | baseline | -60.27% cycles |
| Banked A | 2 x 16, 1R1W each | 199,660 | 52,563 | 0.2633 | +120,342 (+151.72%), 2.518x | baseline |
| Banked B | 2 x 16, 2R1W each | 190,267 | 52,563 | 0.2763 | +110,949 (+139.88%), 2.399x | -9,393 (-4.70%) |

Managed runs, all validation pass:

- Normal 3P:
  `coremarks-compact-3p-ddr3-20260831T200324Z`.
- Banked 1R1W:
  `coremarks-compact-3p-banked-1r1w-ddr3-20260831T200324Z`.
- Banked 2R1W:
  `coremarks-compact-3p-banked-2r1w-ddr3-20260831T200324Z`.

The 2R1W result shows that eliminating most two-request bank conflicts helps,
but it does not explain most of the banked-core gap.  The remaining 2.399x
cycle ratio includes the banked backend's two-wide cap, disabled forwarding,
conservative dependency release, address/data operand-gather stage, and
one-write-per-bank retirement behavior.  This run does not attribute the
remaining loss among those causes.

## Directed 2R1W validation

`3p-banked-directed-20260831T194705Z` passed with two physical read ports per
bank.  Its focused cases include:

- three same-bank requests grant exactly two slots and retry the third;
- four reads distributed two per bank are accepted in one address phase;
- four same-bank reads complete over two address phases;
- redirect while two accepted responses return and two same-bank requests
  remain unacknowledged;
- flush after a partial two-slot response;
- same-address read/write bypass and pipelined address/data association.

## Secondary longer-workload measurements

These measurements were collected before the compact workload was clarified.
They remain useful secondary evidence but are not the primary comparison.

| Geometry | Workload | Cycles | Retired | IPC | Managed run |
|---|---|---:|---:|---:|---|
| 1R1W | Official CoreMark one-iteration smoke | 1,482,850 | 358,184 | 0.2416 | `coremark-bare-smoke-3p-banked-ddr3-20260831T193417Z` |
| 1R1W | Sv39 CoreMark-derived loop | 195,619 | 52,589 | 0.2688 | `coremark-sv39-3p-banked-ddr3-20260831T193733Z` |
| 2R1W | Official CoreMark one-iteration smoke | 1,410,032 | 358,184 | 0.2540 | `coremark-bare-smoke-3p-banked-ddr3-20260831T194719Z` |

For the longer bare smoke, 2R1W saves 72,818 cycles (4.91%) relative to the
1R1W address/data-phase baseline.  A matching 2R1W Sv39 rerun was intentionally
not started after the benchmark clarification.
