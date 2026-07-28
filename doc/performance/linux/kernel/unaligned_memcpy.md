# RISC-V kernel memcpy: unroll the byte fallback

## Status and scope

This is a proposed Linux patch, not an OpenRV64 benchmark optimization. The
OpenRV64 sweep deliberately retains the current kernel byte-loop shape so that
it measures the code Linux actually runs on CPUs where misaligned word accesses
are not classified as fast.

The patch below is written against Linux commit `b95f03f04d47`
(`v7.2-rc4-15-gb95f03f04d47`). The local Linux worktree also contains a
separate, uncommitted change to route CPUs with fast native misaligned accesses
through `REG_L`/`REG_S`. That worktree was inspected but not modified. This
proposal is independent: it improves the fallback used when native misaligned
accesses are slow or unavailable.

## Problem

`arch/riscv/lib/memcpy.S` falls back to this loop when the remaining source and
destination ranges cannot use its aligned word paths:

```asm
5:
	lb	a4, 0(a1)
	addi	a1, a1, 1
	sb	a4, 0(t6)
	addi	t6, t6, 1
	bltu	a1, a3, 5b
```

The loop retires five instructions and resolves one taken branch for every
byte. The load-to-store value dependency is unavoidable without changing the
algorithm, but the pointer and control recurrence does not require serializing
every byte. Multiple byte values can occupy independent caller-clobbered
registers.

This path matters for:

- source and destination addresses with different low-order alignment bits on
  CPUs with slow or faulting misaligned word accesses;
- small copies that do not enter the 128-byte bulk path and are not eligible
  for the existing 32-bit co-aligned path; and
- the final bytes after a bulk copy.

## Measured proxy result

The OpenRV64 scalar sweep exercised 4 KiB copies with offsets `1:0`, `0:1`,
and `3:5` on the native 3-pipe L1D/CCX path. Replacing the byte-at-a-time
fallback with eight independent byte loads and stores gave:

| Implementation | Warm cycles | Bytes/cycle | Retired instructions | IPC |
|---|---:|---:|---:|---:|
| Kernel-shaped byte loop | 20,507 | 0.1997 | 20,494 | 0.9994 |
| Eight-byte unrolled proxy | 13,342 to 13,597 | 0.3012 to 0.3070 | 10,255 | 0.754 to 0.769 |

The kernel-shaped result is exact enough to explain itself: 4,096 iterations
times five instructions per byte accounts for 20,480 instructions, leaving
only 14 instructions of measured call, setup, return, and fence overhead. The
loop is not suffering poor retirement on this core; it sustains almost exactly
one instruction per cycle. Its problem is dynamic instruction count.

The measured throughput improvement from unrolling was approximately 1.51 to
1.54 times, with almost exactly half as many retired instructions. These are
OpenRV64 simulation results, not Linux benchmark results and not evidence of
the same speedup on other implementations. The proposed kernel loop below also
has slightly leaner pointer bookkeeping than the measured proxy.

The result establishes the mechanism: removing seven of every eight loop
branches and exposing independent byte operations materially improves this
core even though its average IPC falls. It does not establish the best unroll
factor across RISC-V CPUs.

## Proposed patch

The patch copies eight bytes per main-loop iteration and leaves a zero-to-seven
byte tail. It performs only byte accesses, so it does not weaken the existing
alignment or access-speed policy and cannot introduce a misaligned access
exception. `memcpy()` does not support overlapping ranges, so grouping loads
before stores does not change its contract.

```diff
diff --git a/arch/riscv/lib/memcpy.S b/arch/riscv/lib/memcpy.S
index 44e009ec5fef..XXXXXXXXXXXX 100644
--- a/arch/riscv/lib/memcpy.S
+++ b/arch/riscv/lib/memcpy.S
@@ -97,11 +97,39 @@ SYM_FUNC_START(__memcpy)
 	ret
 
 5:
+	/* Copy eight bytes per iteration, then handle a bounded byte tail. */
+	andi a5, a2, -8
+	beqz a5, 9f
+	sub a2, a2, a5
+	add a5, a1, a5
+8:
 	lb a4, 0(a1)
-	addi a1, a1, 1
-	sb a4, 0(t6)
-	addi t6, t6, 1
-	bltu a1, a3, 5b
+	lb a6, 1(a1)
+	lb a7, 2(a1)
+	lb t0, 3(a1)
+	sb a4, 0(t6)
+	sb a6, 1(t6)
+	sb a7, 2(t6)
+	sb t0, 3(t6)
+	lb t1, 4(a1)
+	lb t2, 5(a1)
+	lb t3, 6(a1)
+	lb t4, 7(a1)
+	sb t1, 4(t6)
+	sb t2, 5(t6)
+	sb t3, 6(t6)
+	sb t4, 7(t6)
+	addi a1, a1, 8
+	addi t6, t6, 8
+	bltu a1, a5, 8b
+	beqz a2, 6f
+9:
+	lb a4, 0(a1)
+	addi a1, a1, 1
+	sb a4, 0(t6)
+	addi t6, t6, 1
+	addi a2, a2, -1
+	bnez a2, 9b
 6:
 	ret
 SYM_FUNC_END(__memcpy)
```

The loop uses distinct value registers and schedules two groups of four loads
followed by their stores. This removes false register dependencies between
bytes while avoiding an eight-load burst. The OpenRV64 proxy measured this
form. The grouping is not necessarily optimal for every implementation, so it
should be compared with interleaved load/store and eight-load/eight-store
variants on real CPUs before submission.

When stacked on the local native-misaligned-access change, the same body should
replace label `10`, with fresh numeric labels because that change already uses
labels `8`, `9`, and `11`.

## Correctness constraints

- Preserve `a0` as the original destination return value; this routine keeps it
  in `t6`.
- Use only caller-clobbered registers.
- Issue no access wider than one byte in this fallback.
- Never access beyond `[src, src + n)` or `[dst, dst + n)`.
- Support RV32 and RV64. The fixed eight-byte chunk is valid for both.
- Keep zero-length handling at label `4`; label `5` is entered only with a
  nonzero remainder.
- Do not claim `memmove()` semantics. Source/destination overlap is outside the
  `memcpy()` contract.

## Validation required before submission

Build coverage:

```sh
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- defconfig
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$(nproc) \
  arch/riscv/lib/memcpy.o

make ARCH=riscv CROSS_COMPILE=riscv32-linux-gnu- rv32_defconfig
make ARCH=riscv CROSS_COMPILE=riscv32-linux-gnu- -j$(nproc) \
  arch/riscv/lib/memcpy.o
```

Correctness testing should cover lengths zero through at least 256, larger page
and multi-page sizes, all source and destination offsets modulo 16, guard pages
immediately before and after both buffers, and randomized contents. Run both
with native misaligned access classified as slow and, where supported, fast.

Performance testing should report distributions rather than one timing:

- representative in-order and out-of-order RISC-V CPUs;
- cold and warm copies;
- lengths around 8, 16, 64, and 128 bytes plus 256 bytes, 4 KiB, and 64 KiB;
- equal and differing source/destination alignments;
- cycles, instructions, branches, and branch misses where counters exist; and
- kernel-relevant callers or an in-kernel microbenchmark, not only userspace
  libc.

The expected tradeoff is increased text size for lower dynamic instruction and
branch counts. A submission should include `bloat-o-meter` output and should
not claim a universal speedup until multiple implementations have been tested.

## Suggested commit message

```text
riscv: lib: Unroll the byte fallback in memcpy

The RISC-V memcpy implementation copies one byte and executes one taken
branch per iteration when the source and destination cannot use an aligned
word path. This is used on CPUs where native misaligned word accesses are
slow or unavailable.

Copy eight bytes per main-loop iteration and retain a byte loop only for the
zero-to-seven-byte tail. All accesses remain byte-sized, so the change does
not alter alignment requirements or the misaligned-access policy.

On an OpenRV64 cycle-accurate simulation, a warm 4 KiB
differing-alignment copy improved from 0.200 to 0.301-0.307 bytes/cycle
in a closely matching eight-byte-unrolled proxy. Retired instructions
fell from 20,494 to 10,255. This result motivates the change but is not
claimed to represent other RISC-V implementations.

Signed-off-by: ...
```
