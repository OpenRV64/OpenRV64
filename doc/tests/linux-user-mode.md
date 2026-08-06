# Linux user-mode SMP test suite

Last updated: 2026-08-04

## Status

The quick suite has completed on two and four harts with all freestanding,
futex, and pthread cases passing.  The one-hart skip-path control also
completed: the SMP launcher deliberately refuses to run the suite with fewer
than two online CPUs and then proceeds to the shell.

This matrix is also the integrated Linux regression for L2 refactors.  The 2H
and 4H cases are the substantive coherence checks; the 1H case is only a boot
and non-SMP control.  A PASS here does not replace the focused L2 protocol
tests or the eventual extended FPGA stress run.

| Active harts | Suite image | Suite result | Completed coverage | Evidence |
| ---: | --- | --- | --- | --- |
| 1 | `sw/Image.futex` | **PASS: expected suite SKIP** | No SMP workload is possible.  This validates boot and the intentional one-CPU skip path. | `linux-coherent-1h-ddr3-20260804T130744Z` |
| 2 | `sw/Image.futex` | **PASS: 12 passed, 0 failed, 0 skipped; pthread PASS** | All quick-suite cases on both CPUs, including futex and pthread contention. | `linux-smp-2h-ddr3-20260804T025258Z` |
| 4 | `sw/Image.futex` | **PASS: 12 passed, 0 failed, 0 skipped; pthread PASS** | All quick-suite cases on all four CPUs, including futex and pthread contention. | `linux-smp-4h-user-tests-ddr3-20260803T211342Z` |

An older 4H run, `linux-smp-4h-user-tests-ddr3-20260803T103513Z`, passed 11
cases but skipped both futex and the separate pthread binary.  The completed
`sw/Image.futex` runs supersede that coverage result.

## Suite contents

The freestanding test binary is
[`sw/linux-user-tests/openrv64_user_stress.c`](../../sw/linux-user-tests/openrv64_user_stress.c).
It uses Linux syscalls, raw `clone()` workers, and compiler atomics without
libc or TLS.  The boot wrapper is
[`sw/linux-user-tests/run.sh`](../../sw/linux-user-tests/run.sh), which also
runs the separate pthread test when one is installed.

Quick mode currently checks:

| Test | What is checked | 2H result/work | 4H result/work |
| --- | --- | ---: | ---: |
| `affinity_overlap` | One pinned worker per online CPU; every worker executes and remains on its assigned CPU. | PASS / 128 | PASS / 128 |
| `atomic_fetch_add` | Concurrent atomic increments produce the exact aggregate count. | PASS / 256 | PASS / 512 |
| `cas_turn_handoff` | CAS/LR-SC turn passing makes ordered forward progress across all workers. | PASS / 64 | PASS / 128 |
| `ticket_lock` | Ticket acquisition/ownership and a protected non-atomic counter agree. | PASS / 64 | PASS / 128 |
| `same_page_different_lines` | Workers update distinct cache lines in one page without corruption. | PASS / 128 | PASS / 128 |
| `different_pages` | Workers update page-separated private lanes without corruption. | PASS / 128 | PASS / 128 |
| `false_sharing` | Independent words sharing cache lines retain their expected values. | PASS / 128 | PASS / 128 |
| `same_line_handoff` | Ownership and payload move through one shared cache line in order. | PASS / 32 | PASS / 64 |
| `va_alias_atomic` | Atomic updates through two shared virtual aliases remain coherent. | PASS / 128 | PASS / 256 |
| `va_alias_handoff` | Ordered handoff through different virtual aliases observes one backing page. | PASS / 32 | PASS / 64 |
| `remote_mmap_remap` | CPU 1 warms a mapping while CPU 0 changes permissions, moves it with fixed `mremap`, and replaces the old VA; both CPUs observe the expected pages and values. | PASS / 4 | PASS / 4 |
| `futex_mutex` | Contended futex-backed mutex and protected counter. | PASS / 64 | PASS / 128 |

The separate pthread test also passed: 2H reported 128 iterations per worker
and counter 256; 4H reported 128 iterations per worker and counter 512.  Some
UART result lines were split by concurrent IPI trace output.  The reconstructed
records agree with both final summaries: `passed=12 failed=0 skipped=0`.

This is useful integrated stress, not an architectural litmus suite.  In
particular, a PASS does not prove every legal memory ordering, every TLB
shootdown race, or indefinite forward progress under randomized load.

## Completed 2H and 4H runs

Both completed results used:

- one Verilator runtime thread;
- timed DDR3 with bank/row swizzling disabled;
- eight-entry DDR read and write queues, a 16-entry command queue, and a
  maximum burst train of eight;
- eight-entry GenBus read and write buffers;
- L1D prefetching enabled;
- Zicclsm advertised;
- quick suite mode.

The managed artifacts identify the same snapshotted Linux image in all three
runs,
SHA-256
`a98a2ee0b71cfa3b4784c89489d962692f8a30f7c08e8978c717465c71d6e355`,
while 2H and 4H used the same four-core simulator, SHA-256
`db71c8e82939f141e05c8a3adc9de57a7813d59bcd38bbac5d21600c522d04fc`.
The one-core-specialized simulator was SHA-256
`f2b9258771e944dc89782887c7e6a16443b640b9e97e8d82622b79c5292b9166`.
The DT/OpenSBI artifacts intentionally differ with the advertised hart count.
The recorded Git heads differ because the suite sources were committed between
launches, but the snapshotted simulator and Linux image identities are exact.

Both target-visible results include:

```text
OPENRV64_USER_SUITE_END status=PASS passed=12 failed=0 skipped=0
PTHREAD_LOCK_PASS ...
OPENRV64_USER_TESTS_PASS raw_status=0 pthread_status=0
SMP_THREADS_SCRIPT_PASS probe_status=0 suite_status=0
openrv64#
sim_exit_code=0
validation=pass
```

| Active harts | Prompt cycles | Retired instructions | Aggregate IPC | Memory reads | Memory writes | Verilator wall time |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 150,194,739 | 71,685,358 | 0.477283 | 1,116,843 | 649,524 | 10,112.303 s |
| 2 | 155,251,823 | 91,605,424 | 0.590044 | 1,956,127 | 900,067 | 21,027.798 s |
| 4 | 192,589,426 | 127,968,290 | 0.664462 | 2,998,013 | 1,324,221 | 37,246.327 s |

The 2H wrapper started between 141M and 142M cycles, the freestanding suite
ran from the 143M interval through the 149M interval, and pthread passed in the
152M interval.  The corresponding 4H intervals were 172M-173M, 174M-185M,
and 189M.  These are one-million-cycle brackets, not exact suite timings.

The 4H run required 24.1% more target cycles to reach the prompt than 2H, but
this is not a pure hardware scaling measurement: Linux initializes more CPUs
and the suite performs more aggregate work when more workers are online.
Verilator wall time is host simulation throughput, not target performance.

Recorded artifacts:

```text
run/log/linux-smp-2h-ddr3-20260804T025258Z/run.log
run/log/linux-smp-2h-ddr3-20260804T025258Z/artifacts.sha256
run/log/linux-smp-4h-user-tests-ddr3-20260803T211342Z/run.log
run/log/linux-smp-4h-user-tests-ddr3-20260803T211342Z/artifacts.sha256
```

## One-hart control

The first `sw/Image.futex` 1H attempt failed during the forced simulator
rebuild, before simulation.  Optional coherence replay tracing in
`tb/verilator_4h_checkpoint_main.cpp` referenced hart 1 and four-hart-only
probe signals in a one-core generated model.  This was a harness compile bug,
not a target test failure.  The trace function is now compiled out of the
one-core specialization.  The replacement run completed with the expected
skip marker and normal boot evidence:

```text
run ID: linux-coherent-1h-ddr3-20260804T130744Z
SMP_THREADS_SKIP cpus=1
openrv64#
cycles=150194739 hart0_retired=71685358
sim_exit_code=0
validation=pass
```

On one CPU, `sw/smp-thread-test.sh` emits `SMP_THREADS_SKIP cpus=1` and exits
before invoking the user-mode suite.  A successful 1H result therefore proves
boot and skip-path behavior only; it cannot add atomics or coherence coverage.
Its recorded run log is
`run/log/linux-coherent-1h-ddr3-20260804T130744Z/run.log`.

## Reproduction and missing matrix work

Run the source-matched configurations with the futex-enabled image:

```sh
run/run run/cfg/linux-smp-2h-ddr3.cfg \
    --image sw/Image.futex --checkpoint 0 --rebuild
run/run run/cfg/linux-smp-4h-user-tests-ddr3.cfg \
    --image sw/Image.futex --checkpoint 0 --rebuild
```

A one-hart control uses:

```sh
run/run run/cfg/linux-coherent-1h-ddr3.cfg \
    --image sw/Image.futex --checkpoint 0 --rebuild
```

For subsequent comparisons, retain the same Linux image hash, simulator,
DDR settings, suite mode, and completion rule.  A suite PASS is integrated
functional evidence, not a substitute for an extended FPGA meat-grinder run.

Dedicated L2-refactor regression targets run the same matrix and preserve the
purpose in each managed run's ID and `comment.txt`:

```sh
run/run run/cfg/linux-l2-refactor-regression-1h-ddr3.cfg --rebuild
run/run run/cfg/linux-l2-refactor-regression-2h-ddr3.cfg --rebuild
run/run run/cfg/linux-l2-refactor-regression-4h-ddr3.cfg --rebuild
```
