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

Both measurements used `make bench-memcpy-sweep` with the same observed
simulator configuration; this task intentionally changed only the fallback
body and its descriptive report label. The broader OpenRV64 worktree was dirty
and was committed concurrently, so this is not a pristine, commit-isolated
A/B result. It must be repeated from two explicit source commits before use as
upstream evidence. Each run completed all 162 size/alignment reports and the
final byte comparison with `MEMCPYOK`. The timed span includes the function call
and final ordering fence. The backing memory is the functional fixed-latency
AXI model, not the timed DDR3 model.

## Full Linux Zicclsm control experiment

A three-run full Linux boot experiment separated the Zicclsm RTL enable from
its FDT advertisement. All runs used the same `sw/Image.Zicclsm` binary, BP8,
a 32-entry retirement window, one Verilator thread, the functional SRAM model,
and the same L1D prefetch settings: distance eight, queue depth eight, and four
outstanding requests. Every run reached the literal `openrv64# ` prompt,
reported the testbench PASS, and exited with status zero.

The recorded artifact hashes establish the intended controls:

- all three runs used the same Linux image;
- hardware-on/advertised and hardware-on/not-advertised used the same
  simulator binary; and
- hardware-on/not-advertised and hardware-off/not-advertised used the same
  DTB, which omitted Zicclsm.

The cumulative signposts were:

| RTL | FDT advertisement | Signpost | Cycles | Retired instructions |
|---|---|---|---:|---:|
| on | on | OpenSBI | 1,317,653 | 1,798,855 |
| on | on | Linux | 3,646,079 | 4,413,147 |
| on | on | PLIC | 19,284,807 | 15,945,882 |
| on | on | Bash prompt | 80,691,730 | 58,906,019 |
| on | off | OpenSBI | 1,315,628 | 1,796,271 |
| on | off | Linux | 3,643,292 | 4,409,492 |
| on | off | PLIC | 19,296,493 | 15,940,341 |
| on | off | Bash prompt | 80,798,787 | 58,937,990 |
| off | off | OpenSBI | 1,315,628 | 1,796,271 |
| off | off | Linux | 3,709,304 | 4,458,827 |
| off | off | PLIC | 20,520,862 | 16,794,029 |
| off | off | Bash prompt | 93,451,606 | 67,055,171 |

Removing only the advertisement increased prompt time by 0.133% and retired
instructions by 0.054%. This is a whole-boot result, not a direct attribution
to memcpy or another kernel policy. A small phase change can alter the
placement of timer-driven work. Repeat the pair and compare event counts before
treating a difference this small as a stable advertisement penalty.

Disabling the hardware while retaining the non-advertising DTB increased
prompt time by 15.66% and retired instructions by 13.77%. This is not a
measurement of dormant Zicclsm RTL overhead. The hardware-off log repeatedly
sampled `mcause` values four and six, indicating misaligned load and store
exceptions. The kernel, firmware, or userspace can still execute misaligned
instructions when Zicclsm is not advertised; advertisement changes software
policy, not the legality of every instruction in existing code. The
hardware-off run therefore includes trap-and-emulation work that the
hardware-on run avoids.

The hardware-on and hardware-off non-advertising runs had exactly the same
OpenSBI signpost, 1,315,628 cycles and 1,796,271 retired instructions. This
shows no cycle-level difference in that prefix. It does not prove that adding
Zicclsm has no cost to ordinary LSU operations.

There are two remaining cost questions:

1. The current serialized engine waits for accepted LSQ transactions to drain
   before starting a misaligned operation and suppresses ordinary LSQ launches
   while that operation is pending or active. This can impose cycle-level
   interference on workloads that actually issue misaligned accesses.
2. The additional arbitration and muxing can lengthen an LSU critical path or
   increase area even when the engine is inactive. Verilator cycle counts
   cannot measure an Fmax penalty.

The first question needs an aligned-only directed workload built both ways,
plus an assertion or counter proving that the misaligned engine never
activates. The second needs matched synthesis and post-route timing results.
The full Linux boots characterize the architectural benefit and software
policy interaction, not those dormant structural costs.

The retained records are:

```text
build/runs/linux-3p/20260729T025818Z-l1i-response-plus64-sram-full-linux/
build/runs/linux-3p/20260729T033408Z-l1i-response-plus64-sram-zicclsm-hardware-on-advert-off/
build/runs/linux-3p/20260729T033549Z-l1i-response-plus64-sram-zicclsm-hardware-off-advert-off/
```

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
@@ -99,9 +99,37 @@ SYM_FUNC_START(__memcpy)
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
replace label `10`. Numeric local labels may legally be reused, although
renumbering them makes the merged result easier to review. The changes are
logically independent but overlap the same trailing-copy hunk, so parallel
submissions will require a rebase or manual conflict resolution if either is
accepted first.

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
