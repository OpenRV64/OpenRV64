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

The matched gem5 HPI AArch64 image measured 22,257 cycles, 23,774 committed
architectural instructions, 24,438 committed operations, 1.0682 architectural
IPC, and 1,391.1 cycles per block. The source-matched OpenRV64 bare result
without Zbb takes 25,568 cycles: 3,311 cycles or 14.88% more. Its 35,758
retired RV64 instructions are 50.4% more than the AArch64 architectural count,
even though its within-ISA IPC is higher at 1.3985. Cross-ISA IPC is not
directly comparable.

Enabling Zbb changes both code generation and execution throughput. The table
keeps the former serialized implementation as a measured regression control:

| Environment | ISA / rotate implementation | Cycles | Instructions | IPC |
| --- | --- | ---: | ---: | ---: |
| Bare DDR3 | RV64I | 25,568 | 35,758 | 1.3985 |
| Bare DDR3 | Zbb, serialized | 34,456 | 25,302 | 0.7343 |
| Bare DDR3 | Zbb, two 32-bit shifters | 20,206 | 25,302 | 1.2522 |
| Sv39 DDR3 | RV64I | 24,755 | 35,758 | 1.4445 |
| Sv39 DDR3 | Zbb, serialized | 33,621 | 25,302 | 0.7526 |
| Sv39 DDR3 | Zbb, two 32-bit shifters | 19,420 | 25,302 | 1.3029 |
| gem5 HPI | AArch64 | 22,257 | 23,774 | 1.0682 |

Zbb reduces the RV64 dynamic instruction count by 29.24% and leaves it only
6.43% above the AArch64 architectural count, or 3.54% above HPI's committed
operation count. The old sequencer nevertheless increased cycles by 34.77%
bare and 35.81% under Sv39 because each `roriw` occupied EX0 for shift,
inverse-shift, and OR micro-steps. In the bare run, retirement-head cycles
attributed to ALU completion rose from 344 to 16,471.

The replacement uses two reusable 32-bit barrel-shifter lanes and a separate
elastic OR stage. Word rotates have initiation interval one. A 64-bit rotate
uses both lanes for direct-half terms, reuses them on the following cycle for
wrap terms, and therefore has initiation interval two. `clz`, `ctz`, and
`cpop` remain sequenced. Local bit reversal normalizes left shifts into right
shifts; an unmapped Yosys structural check reports exactly two `$shr` cells
and no `$shl` cells. This is resource-structure evidence, not mapped area or
timing evidence.

With that datapath, Zbb is 20.97% faster than RV64I bare and 21.55% faster
under Sv39. Relative to the serialized Zbb implementation, the reductions are
41.36% and 42.24%. The bare result is also 9.21% fewer cycles than gem5 HPI,
but that comparison is between different ISAs and simulation models, not a
silicon performance claim.

The AArch64 compression body contains 20 `ldp` and 13 `stp` instructions per
compression invocation, hence 528 pair instructions across this 16-block run.
HPI reports 664 more committed operations than architectural instructions,
consistent with most pairs decomposing into separate backend operations.
Load/store pairs therefore provide meaningful code-density and frontend
savings, but do not halve memory references or LSU execution work.

The HPI result is from gem5 25.1.0.1 at the repository-pinned commit
`51edbbb9cfd37e92e9901aea2caa4a8f20eda005`. It is a two-wide in-order model,
not measured Cortex-A53 silicon. Reproduce it with
`make sim-blake2s-a53-gem5`; the report is written under
`sim/a53/gem5-hpi-blake2s-c16-b1/`.

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
