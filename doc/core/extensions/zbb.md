# Zbb execution and performance

This document describes OpenRV64's current Zbb implementation. It is both an
implementation reference and a record of the performance behavior observed
while applying Zbb to Linux BLAKE2s. Zbb instruction semantics come from the
RISC-V ISA; the pipe assignment, latency, forwarding, and throughput described
here are specific to this core.

## Scope and availability

Zbb is implemented only by the three-pipe integer core. It is controlled by
`ENABLE_RV64ZBB`, which defaults to enabled on the supported 3P integration
surfaces. The 1P core neither implements nor advertises Zbb.

The decoder currently accepts:

- `andn`, `orn`, and `xnor`;
- `min`, `max`, `minu`, and `maxu`;
- `sext.b`, `sext.h`, and `zext.h`;
- `clz`, `ctz`, `cpop`, and their word forms;
- `rol`, `ror`, `rori`, and their word forms where defined; and
- `orc.b` and `rev8`.

The primary RTL is:

- [`rtl/core/decode/alu.v`](../../../rtl/core/decode/alu.v), for decode;
- [`rtl/core/exec/exec_pipe_ex0.v`](../../../rtl/core/exec/exec_pipe_ex0.v),
  for EX0 integration and completion arbitration;
- [`rtl/core/exec/ext/zbb_rotate.v`](../../../rtl/core/exec/ext/zbb_rotate.v),
  for pipelined rotates; and
- [`rtl/core/exec/ext/zbb.v`](../../../rtl/core/exec/ext/zbb.v), for the
  remaining sequenced operations.

The generated OpenSBI device tree advertises `zbb` through both `riscv,isa`
and `riscv,isa-extensions` when `OPENSBI_3P_ADVERTISE_ZBB=1`. Advertisement
defaults to `OPENSBI_3P_ENABLE_ZBB` and cannot be enabled when execution is
disabled. There is no Z-extension bit in `misa`; software discovery comes
from the ISA string/extension list.

## EX0 and RV64M sharing

All Zbb instructions are fixed to EX0. RV64M is fixed to the same issue pipe.
This does not mean Zbb reuses the multiplier or divider arithmetic:

- RV64M has its own worker;
- non-rotate Zbb operations use the Zbb sequencer, which reuses EX0's base
  integer ALU for shifts, Boolean operations, and comparisons; and
- rotates use a dedicated two-32-bit-shifter pipeline.

The EX0 issue slot and registered completion port are shared by all three
paths. RV64M and sequenced Zbb additionally share the long-operation ownership
state: `worker_pending_q` selects one of their results. The rotate path has its
own internal state, but a pending RV64M/sequenced-Zbb operation prevents a
rotate from entering EX0, and a busy rotate path prevents RV64M or sequenced
Zbb from entering. A rotate does not reserve the base ALU for every internal
cycle, so an ordinary base operation can sometimes overlap the rotate
pipeline. It still consumes EX0 issue on acceptance and EX0 completion when
the result is published.

A workload mixing multiply/divide and Zbb therefore has structural contention
even though the arithmetic datapaths are separate. BLAKE2s contains no
multiply/divide operations, so the measurements below isolate Zbb dependency
and completion behavior rather than RV64M contention.

Base RV64I ALU operations are different: the issue window may place them on
EX0 or EX1. This distinction matters when comparing a compiler-generated
shift/or rotate with `roriw`. The shift/or sequence exposes ordinary flexible
ALU operations; `roriw` remains a fixed EX0 operation.

## Rotate datapath

The current rotate datapath uses exactly two 32-bit bidirectional barrel
shifters. Left shifts are normalized through local bit reversal so the RTL has
two variable right-shift expressions rather than separate left- and
right-shifter networks.

For a word rotate, both terms are produced in parallel:

```text
accept -> stage 0: two shifted terms -> stage 1: OR/sign extension
       -> EX0 completion register
```

Word rotates can be accepted every cycle when the output is not backpressured.
This is initiation interval one.

A 64-bit rotate uses the same two shifters twice. The first cycle produces the
direct term for each 32-bit half and the second produces the cross-half wrap
terms. The result then uses the same elastic OR stage and EX0 completion
register. A 64-bit rotate therefore has initiation interval two.

This replaced the original implementation that sequenced each rotate through
shift, inverse shift, and OR micro-operations on the shared EX0 ALU. The old
implementation reduced dynamic instruction count but increased total BLAKE2s
cycles by about 35%; it is retained only as historical regression evidence in
[`doc/tests/sv39-smoke.md`](../../tests/sv39-smoke.md).

## Current latency schedule

The following table is the zero-backpressure schedule derived from the current
registered RTL. It is not an architectural timing promise. "Completion
latency" counts cycles after the issue-accepting edge until EX0's registered
completion becomes visible. "Dependent spacing" is the earliest edge on which
a tagged dependent instruction can be accepted by the execution pipe.

| Operation class | Implementation | Completion latency | Earliest dependent spacing | Initiation interval |
| --- | --- | ---: | ---: | ---: |
| `sext.b`, `sext.h`, `zext.h`, `orc.b`, `rev8` | direct Zbb result register | 1 | 2 | 2 |
| `andn`, `orn`, `xnor`, `min`, `max`, `minu`, `maxu` | one EX0 ALU micro-operation | 2 | 3 | 3 |
| word `rol`/`ror`/`rori` | two parallel shifters plus OR stage | 2 | 3 | 1 |
| 64-bit `rol`/`ror`/`rori` | two shifter-use cycles plus OR stage | 3 | 4 | 2 |
| `cpopw` | two 16-bit population-count steps | 3 | 4 | 4 |
| `cpop` | four 16-bit population-count steps | 5 | 6 | 6 |
| `clz`, `ctz`, `clzw`, `ctzw` | six binary-search shift steps | 7 | 8 | 8 |

The sequenced operation initiation intervals include the EX0 worker ownership
round trip. Output backpressure or an occupied EX0 completion port increases
both latency and initiation interval. The rotate path is separately elastic
and preserves its word-II=1 and wide-II=2 contracts when completions drain.

## Forwarding contract

Zbb does not have pre-completion result forwarding.

In particular, the rotate's registered `stage1_result_q` is not a producer
source for the issue window. `exec_pipe_ex0` first copies it into
`complete_payload_q`. Only that registered EX0 completion is sent to the
backend. The issue window then matches the exact producer instruction ID,
marks either source ready, and stores the completion data in the dependent
entry.

Consequences:

- a dependent instruction cannot consume a rotate result directly from the
  rotate OR stage;
- a dependent store is not a special exception: its address or data source is
  woken only when the registered Zbb completion is published;
- after publication, the issue window can forward the value to any tagged
  `src1` or `src2` consumer, including a store; and
- the limitation is therefore **no early Zbb forwarding**, not "a Zbb result
  can never be forwarded."

Ordinary base-ALU operations have shorter completion paths and local
same-pipe forwarding support. The current benchmark configuration also has
`COMPLETION_FORWARD_MASK=0` and full forwarding disabled, so there is no
additional general live-completion network hiding the Zbb completion delay.

The most direct prospective optimization is an exact-ID-tagged bypass from the
registered rotate output to issue-window wakeup/operand data, or removal of the
otherwise redundant EX0 completion-register cycle for rotates. Either change
must preserve flush cancellation, instruction-ID and retirement-slot identity,
WAW ownership, held-valid backpressure, and completion-port arbitration. A
larger retirement/issue window hides the problem but does not remove the
producer latency.

## Dependency behavior in BLAKE2s

BLAKE2s repeatedly executes dependent 32-bit add, XOR, and rotate operations.
The three relevant rotate forms expose different schedules:

```text
generic shift/or: xor -> {srliw || slliw} -> or -> add/xor
hand Zbb:         xor -> roriw -> add/xor
inline-asm Zbb:  xor -> roriw -> sext.w -> add/xor
```

The generic form uses more instructions, but its two shifts can become
eligible together and can use the two flexible integer ALU pipes. The hand
Zbb form has fewer instructions and word-rotate throughput of one per cycle,
but each dependent chain waits for registered rotate completion. A larger
window can find independent work from other BLAKE2s state lanes while waiting;
a 16-entry window frequently cannot.

The inline-assembly `ror32()` experiment is worse than the hand-written Zbb
compressor when the compiler emits `roriw` followed by `sext.w`. `roriw`
already sign-extends its architectural 32-bit result. The extra `sext.w`
exists because the compiler cannot infer the upper-bit semantics of an opaque
inline-assembly output. Although `sext.w` is an ordinary forwardable ALU
operation, it creates another mandatory producer in the critical chain: it
cannot issue until the late rotate completion, and the true consumer must then
wait for the `sext.w` result. The fully hand-written compressor avoids this
redundant dependency.

## Source-matched Sv39 BLAKE2s matrix

The current controlled matrix runs in supervisor mode with Sv39 translation,
timed banked DDR3, issue/speculation windows enabled, and the same surrounding
harness and kernel `memcpy` object. The non-Zbb control uses the extracted
kernel shift-chain compressor while keeping the harness compiled with Zbb so
the compressor is the implementation variable.

All cases below compressed 16 blocks, reached the requested measurement
endpoint with a hierarchy-level PASS, and produced checksum `f5287fd3`. The
`bench-*` targets stop at `blake2s_measure_end`, before the software reference
verifier. Use the `sim-*` commands below when the post-measure reference check
is required; the checksum agreement is useful evidence but is not that check.

| Shape | Offset | Compressor | Instructions | RD16 cycles | RD32 cycles | RD16 penalty | Zbb cycle reduction at RD16 / RD32 |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 16 calls x 1 block | 0 | kernel generic shift-chain | 34,582 | 24,990 | 23,603 | 5.88% | - |
| 16 calls x 1 block | 0 | hand-written kernel Zbb | 22,534 | 23,392 | 19,932 | 17.36% | 6.39% / 15.55% |
| 16 calls x 1 block | 1 | kernel generic shift-chain | 34,582 | 26,806 | 25,286 | 6.01% | - |
| 16 calls x 1 block | 1 | hand-written kernel Zbb | 23,542 | 26,135 | 22,675 | 15.26% | 2.50% / 10.33% |
| 1 call x 16 blocks | 0 | kernel generic shift-chain | 33,617 | 23,680 | 22,288 | 6.25% | - |
| 1 call x 16 blocks | 0 | hand-written kernel Zbb | 21,959 | 22,531 | 19,121 | 17.83% | 4.85% / 14.21% |
| 1 call x 16 blocks | 1 | kernel generic shift-chain | 33,617 | 25,456 | 24,059 | 5.81% | - |
| 1 call x 16 blocks | 1 | hand-written kernel Zbb | 22,967 | 25,368 | 21,862 | 16.04% | 0.35% / 9.13% |
| aligned aggregate | - | kernel generic shift-chain | 68,199 | 48,670 | 45,891 | 6.06% | - |
| aligned aggregate | - | hand-written kernel Zbb | 44,493 | 45,923 | 39,053 | 17.59% | 5.64% / 14.90% |
| all-case aggregate | - | kernel generic shift-chain | 136,398 | 100,932 | 95,236 | 5.98% | - |
| all-case aggregate | - | hand-written kernel Zbb | 91,002 | 97,426 | 83,590 | 16.55% | 3.47% / 12.23% |

The dynamic instruction reduction is about 35%, but RD16 converts little of
it into cycle reduction. This is not a memory-system effect in the measured
multi-block case:

| Counter, 1 call x 16 aligned blocks | Generic RD16 | Generic RD32 | Zbb RD16 | Zbb RD32 |
| --- | ---: | ---: | ---: | ---: |
| window has no eligible instruction | 2,136 | 2,205 | 5,050 | 3,207 |
| RAW-stall cycles | 1,914 | 2,053 | 4,903 | 3,063 |
| dispatch nonempty with no issue | 2,473 | 2,390 | 5,538 | 3,569 |
| incomplete ALU at retirement head | 294 | 260 | 7,158 | 5,635 |
| LSU request-wait cycles | 595 | 586 | 156 | 112 |

The Zbb RD16-to-RD32 gap coincides with 1,840 additional RAW-stall cycles,
1,969 additional nonempty/no-issue cycles, and 1,523 additional
retirement-head ALU-wait cycles. DDR refresh time was 548 cycles in both Zbb
runs. These counters support a dependency-latency diagnosis; they do not by
themselves prove which prospective bypass implementation is best.

The Linux/OpenSBI platform defaults are therefore RD32:
`OPENSBI_4H_HELD_RETIRE_DEPTH=32` for the managed SMP harness and
`OPENSBI_3P_PLATFORM_RETIRE_DEPTH=32` for the standalone 3P platform.
Directed tests and controlled RD16 comparisons retain explicit overrides;
the generic core and unrelated microbenchmark defaults are unchanged.

The kernel generic function accepts an unaligned byte source because it first
copies each block through `memcpy` into an aligned local `u32 m[16]`. Offset
one costs the generic implementation 7.13-7.95% and the hand-written Zbb
implementation 11.73-14.34% in these cases. The RD16 Zbb advantage consequently
falls to 2.50% for repeated single-block calls and 0.35% for the multiblock
call.

The longer RD16 test uses 64 calls of 16 blocks, or 1,024 blocks total:

| Compressor | Cycles | Instructions | Result relative to generic |
| --- | ---: | ---: | ---: |
| kernel generic shift-chain | 1,286,742 | 2,147,398 | reference |
| hand-written kernel Zbb | 1,323,783 | 1,401,286 | 2.88% more cycles, 34.74% fewer instructions |

This longer result is a warning against treating instruction count as the
performance result. Under RD16, repeated Zbb compression remains sufficiently
dependency-limited to lose despite retiring roughly one third fewer
instructions.

### Measurement provenance

The matrix used:

```text
975d3577a630df334cb88016220df2c2cedd37a1745137068e06cbeb28f373eb  vmlinux
5ab496938ab53346cd227b08224838de9b3e43ec1b4ef53fc7d5211148f053db  memcpy.o
6eb8895be43615e5b816ed2eb4ff7019ad75b0b7425545840b170843ad67f627  blake2s-riscv64-zbb-or-zbkb.o
```

The RD16 and RD32 ELF/memory-image hashes match within each implementation;
only the elaborated retirement depth changes. Managed logs are:

- `run/log/blake2s-sv39-kernel-generic-matrix-rd16-20260816T133223Z/`;
- `run/log/blake2s-sv39-kernel-generic-matrix-rd32-20260816T133223Z/`;
- `run/log/blake2s-sv39-kernel-zbb-matrix-rd16-20260816T123651Z/`; and
- `run/log/blake2s-sv39-kernel-zbb-matrix-rd32-20260816T124232Z/`.

These are simulator/core results, not hardware PPA or silicon performance
claims.

## Linux boot applicability

The generated 3P OpenSBI platform enables and advertises Zbb by default, so a
Linux kernel may select Zbb alternatives after parsing the hart ISA
extensions. Whether a particular hot function uses Zbb is a separate software
question. `CONFIG_RISCV_ISA_ZBB=y` does not cause arbitrary generic C to be
recompiled for Zbb.

For the checked kernel, `blake2s_compress_generic` contains 320 `slliw` and
320 `srliw` instructions and no `roriw`. Consequently, simply enabling Zbb in
the platform does not accelerate that function. A separately compiled or
hand-written Zbb implementation is required, along with runtime ISA dispatch
if the kernel image must support harts without Zbb.

A 250,000-cycle Linux boot PC histogram attributed 28 of 320 post-kernel
samples to `blake2s_compress_generic`: 8.75% of samples, or 7.00M
sample-equivalent cycles. This establishes that BLAKE2s is material in that
boot, but it is coarse held-PC sampling rather than exact function accounting.
See [`doc/performance/linux-boot-histogram.md`](../../performance/linux-boot-histogram.md).

The practical conclusions are:

- Zbb can materially reduce BLAKE2s dynamic instruction count.
- The current no-early-forwarding rotate latency makes the result strongly
  dependent on issue-window depth and compiler scheduling.
- A globally enabled Zbb bit is not evidence that Linux emitted or selected a
  Zbb BLAKE2s compressor; inspect the linked object or `vmlinux` disassembly.
- Boot-level improvement is bounded by the fraction of boot actually executing
  the optimized path and can be obscured by unrelated kernel/configuration
  changes. Use the isolated benchmark before interpreting a full boot delta.
- Hand-written assembly currently avoids the redundant `roriw`/`sext.w`
  dependency produced by the inline-assembly experiment.

## Tests and benchmark targets

Run the directed sequencer and rotate tests with:

```bash
make sim-exec-ext-zbb
```

This runs the sequenced-operation test plus the dedicated rotate test. The
rotate test covers word II=1, wide II=2, output backpressure, exact tags,
flush cancellation, randomized operands, and every architectural shift amount
for both widths. `make sim-isa-bitmanip` and `make sim-decode-alu` provide
encoding/decode coverage, but they are not substitutes for execution tests.

Run the hand-written Zbb aligned/misaligned and single/multiblock matrix with:

```bash
make -j8 bench-blake2s-kernel-matrix-sv39 \
  BLAKE2S_KERNEL_ZBB_OBJ=/path/to/linux/lib/crypto/riscv/blake2s-riscv64-zbb-or-zbkb.o \
  BLAKE2S_KERNEL_MEMCPY_OBJ=/path/to/linux/arch/riscv/lib/memcpy.o \
  BLAKE2S_RETIRE_DEPTH=16
```

Set `BLAKE2S_RETIRE_DEPTH=32` for the matched RD32 case.

Run the same Zbb cases through the post-measure software reference verifier
with:

```bash
make -j8 sim-blake2s-kernel-matrix-sv39 \
  BLAKE2S_KERNEL_ZBB_OBJ=/path/to/linux/lib/crypto/riscv/blake2s-riscv64-zbb-or-zbkb.o \
  BLAKE2S_KERNEL_MEMCPY_OBJ=/path/to/linux/arch/riscv/lib/memcpy.o \
  BLAKE2S_RETIRE_DEPTH=16
```

Run the aligned/misaligned source-matched generic shift-chain control with:

```bash
make -j8 bench-blake2s-kernel-generic-matrix-sv39 \
  BLAKE2S_KERNEL_GENERIC_VMLINUX=/path/to/linux/vmlinux \
  BLAKE2S_KERNEL_MEMCPY_OBJ=/path/to/linux/arch/riscv/lib/memcpy.o \
  BLAKE2S_RETIRE_DEPTH=16
```

The surrounding harness remains Zbb-enabled to keep the compressor as the
only implementation change.

Verify one generic shape through the post-measure reference check with:

```bash
make -j8 sim-blake2s-sv39 \
  BLAKE2S_IMPLEMENTATION=kernel-generic-shift \
  BLAKE2S_KERNEL_GENERIC_VMLINUX=/path/to/linux/vmlinux \
  BLAKE2S_KERNEL_MEMCPY_OBJ=/path/to/linux/arch/riscv/lib/memcpy.o \
  BLAKE2S_CALLS=16 BLAKE2S_BLOCKS_PER_CALL=1 \
  BLAKE2S_RETIRE_DEPTH=16
```

Compare a shift-chain kernel against a kernel containing the inline-assembly
`roriw` alternative over 1,024 blocks with:

```bash
make -j8 bench-blake2s-ror32-kernel-sv39 \
  BLAKE2S_ROR32_SHIFT_VMLINUX=/path/to/pre-change/vmlinux \
  BLAKE2S_ROR32_PATCHED_VMLINUX=/path/to/post-change/vmlinux \
  BLAKE2S_KERNEL_MEMCPY_OBJ=/path/to/linux/arch/riscv/lib/memcpy.o \
  BLAKE2S_RETIRE_DEPTH=16
```

Disassemble both extracted compressor artifacts and confirm the intended
shift/or versus `roriw`/`sext.w` sequences before accepting the result. The
requested input path alone is not sufficient provenance; retain the `vmlinux`
hash in the run record.

For managed, provenance-capturing runs in the current workspace, use:

```bash
run/run run/cfg/blake2s-sv39-kernel-generic-matrix-rd16.cfg
run/run run/cfg/blake2s-sv39-kernel-generic-matrix-rd32.cfg
run/run run/cfg/blake2s-sv39-kernel-zbb-matrix-rd16.cfg
run/run run/cfg/blake2s-sv39-kernel-zbb-matrix-rd32.cfg
```

The combined `make test-sv39-smoke` image also contains BLAKE2s, but it is a
quick correctness/performance regression signal with shared warm state. It is
not the controlled Zbb A/B benchmark.

## Current limitations and optimization priorities

1. Add or evaluate exact-tagged early rotate-result forwarding before
   increasing window depth solely to cover the latency.
2. Preserve word-rotate II=1 and wide-rotate II=2 while changing completion
   or bypass wiring.
3. Add a directed full-core producer/consumer latency test. The current rotate
   unit test checks initiation interval and correctness but does not make the
   EX0-to-dependent spacing a regression contract.
4. Measure mixed RV64M/Zbb workloads before changing EX0 arbitration; BLAKE2s
   does not cover their shared-pipe contention.
5. Keep compiler-generated, inline-assembly, and hand-written Zbb software
   results separate. They have different dependency graphs even when all
   contain `roriw`.
6. Do not claim full Zbb architectural signoff from these tests. Directed
   execution, decode, BLAKE2s correctness, Sv39, and Linux boot evidence exist;
   a current full architectural compliance campaign and physical timing proof
   are separate requirements.
