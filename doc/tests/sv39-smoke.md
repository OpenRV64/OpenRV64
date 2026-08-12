# Single-image Sv39 smoke test

`test-sv39-smoke` builds one Sv39 ELF. It is not an aggregate target that
launches several unrelated simulations. The shared runtime calls `main`,
which aliases `test_main`; `test_main` conditionally calls each selected test
function, verifies its result, records its cycle interval, and returns one
combined result to the runtime.

The default image includes:

- CoreMark loop;
- Linux generic BLAKE2s compression;
- 64 KiB STREAM triad;
- RV64A atomic correctness test;
- fence behavior/performance test; and
- synchronous-tag same-line store-extension test.

## Running it

Run the complete image with:

```bash
make test-sv39-smoke
```

Each workload is controlled at compile time. For example, a BLAKE2s-only
image is:

```bash
make test-sv39-smoke \
  SV39_SMOKE_ENABLE_COREMARK=0 \
  SV39_SMOKE_ENABLE_BLAKE2S=1 \
  SV39_SMOKE_ENABLE_STREAM=0 \
  SV39_SMOKE_ENABLE_ATOMIC=0 \
  SV39_SMOKE_ENABLE_FENCE=0 \
  SV39_SMOKE_ENABLE_STORE_EXTENSION=0
```

Every control must be `0` or `1`. Its value is part of the build-directory
tag, so changing a directive cannot accidentally reuse an incompatible ELF.

The testbench prints one machine-readable record:

```text
PERF_SV39_SMOKE coremark_cycles=56375 blake2s_cycles=26058 stream_cycles=119860 atomic_cycles=3022 fence_cycles=140940 store_extension_cycles=10964 selected_mask=3f
```

The selected-mask bits, from bit 0 through bit 5, are CoreMark, BLAKE2s,
STREAM, atomic, fence, and store extension. A disabled test reports zero
cycles. The final architectural registers are:

| Register | Result |
| --- | --- |
| `a0` | `SV39_OK!`, or `SV39BAD` plus failing test ID |
| `a1` | CoreMark cycles |
| `a2` | BLAKE2s cycles |
| `a3` | STREAM cycles |
| `a4` | atomic cycles |
| `a5` | fence cycles |
| `a6` | store-extension cycles |
| `a7` | selected mask |

## Configuration and baseline

The default target uses the three-pipe core, BP8 mode 3, 16 retirement
entries, issue/speculation windows enabled, posted stores, synchronous L1D
tags with the store extension, L1D prefetch, timed DDR3, and acknowledged L2
fences. It requires observed supervisor mode, Sv39 translation, translated
instruction/data aliases, and timed memory.

The 2026-08-12 all-tests baseline passed with 424,852 total simulation cycles,
368,654 retired instructions, 0.8677 aggregate IPC, and the per-test record
shown above. A separate BLAKE2s-only directive check passed with
`selected_mask=02`, all disabled results zero, and 26,454 BLAKE2s cycles.

These per-test values are regression signals, not isolated benchmark numbers.
The tests execute sequentially in one address space, so later tests inherit
warm TLB, cache, predictor, and memory-controller state. Each driver interval
also includes completion fences around the function. Use the standalone
benchmark targets for controlled performance comparisons.

## Shared-runtime migration check

The previous standalone software images from repository `HEAD` were rebuilt
and run on the same current RTL before adapting the tests as callable
functions. This isolates the shared-runtime migration from RTL drift:

| Workload | Previous image cycles | Shared-runtime cycles | Delta |
| --- | ---: | ---: | ---: |
| CoreMark Sv39 | 56,892 | 56,611 | -281 (-0.494%) |
| STREAM triad Sv39 | 126,975 | 127,425 | +450 (+0.354%) |
| atomic Sv39 | 2,096 | 2,052 | -44 (-2.099%) |
| fence Sv39 | 159,710 | 159,673 | -37 (-0.023%) |
| LZ4 | 2,217,719 | 2,217,753 | +34 (+0.002%) |
| FMADD32 | 1,839 | 1,839 | 0 |

The deltas are sub-percent except for the very short atomic test, where 44
cycles is 2.10%. They do not show a material runtime-migration regression.

## BLAKE2s interpretation and HPI status

The pre-runtime bare BLAKE2s image measured 25,412 cycles and 35,758 retired
instructions. The shared-runtime bare image measured 25,568 cycles with the
same instruction count: +156 cycles, or +0.614%. The current standalone Sv39
image measured 24,755 cycles, but that number uses a different startup and
fence configuration and must not be interpreted as Sv39 being faster.

This workload processes only 16 64-byte blocks, or 1 KiB of input. Its cost is
not data volume or memory bandwidth. The matching generic kernel function is
roughly 8 KiB of code and performs ten fully unrolled rounds dominated by
dependent 32-bit add/XOR/rotate chains, stack-local traffic, and out-of-line
copies. A Linux boot PC histogram attributed 28 of 320 samples (8.75%) to
`blake2s_compress_generic`, equivalent to 7.00M sampled cycles. That is a
coarse PC-sampling estimate, not exact function accounting.

There is no preserved BLAKE2s result for the Cortex-A53 HPI model in the
repository. Existing HPI artifacts cover CoreMark, STREAM, page-free, and
pointer-chase workloads. The new `sw-blake2s-a53-gem5` image builds, and
`sim-blake2s-a53-gem5` provides a matched measurement path, but it cannot
produce a comparison until the configured `gem5.opt` executable is restored.
Do not compare BLAKE2s against an HPI number from a different workload.

## Adding a test

Add a callable function that preserves `sp` and `ra`, returns a deterministic
correctness result, and has no private startup or terminal spin. Add its
source and enable directive to `scripts/make/sv39-smoke.mk`, then call and
verify it in `sw/runtime/sv39_smoke.S`. Assembly tests in this image otherwise
use a deliberate clobber-all test-function convention; they are not general C
ABI library routines.

Keep the standalone target when the workload has useful isolated performance
controls. The combined smoke image is for quick correctness and broad
performance-regression detection, not for replacing controlled A/B runs.
