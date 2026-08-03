# RV64F/RV64D ISA, execution pipeline, and 4PF core

This document defines the floating-point ISA contract added to OpenRV64, the
architectural floating-point register file, execution pipeline, and the 4PF
core integration. It also describes the implemented FP CSR state. The encoding
headers cover the ratified F and D instruction spaces. The distinct 4PF top
advertises F and D by default; the existing 1P and 3P tops deliberately do not.

## Architectural contract

The intended architectural configuration is RV64 with `FLEN=64`:

- F provides IEEE-754 binary32 arithmetic and 32 floating-point registers.
- D widens those registers to 64 bits and adds IEEE-754 binary64 arithmetic.
- A binary32 value held in a 64-bit floating-point register is NaN-boxed: bits
  63:32 are all ones.  A computational F instruction treats a non-boxed input
  as canonical NaN.
- `fcsr` contains the five accrued exception flags in `fflags` and the dynamic
  rounding mode in `frm`.  Their CSR addresses are `0x003`, `0x001`, and
  `0x002`, respectively.
- The rounding modes are RNE, RTZ, RDN, RUP, and RMM.  An instruction `rm` of
  DYN selects `frm`; reserved `rm` or `frm` values must be rejected.
- The exception flags are invalid operation (`NV`), divide by zero (`DZ`),
  overflow (`OF`), underflow (`UF`), and inexact (`NX`).
- `mstatus.FS` gates access to FP instructions and FP CSRs.  Retired FPR or FP
  CSR state changes set it to Dirty; `mstatus.SD` reflects that state.

The Verilog encoding contract is in
`rtl/core/exec/fpu/isa/rv64-f.v` and
`rtl/core/exec/fpu/isa/rv64-d.v`.

The architectural FPR is `openrv64_rv64fd_fpr` in
`rtl/core/exec/fpu/fpr.v`.  It is a 32-entry identity-mapped instance of
the shared parameterized register file, configured for three combinational
compute reads, one independent buffered-store read, and one ordered write.
The dedicated store read does not arbitrate with the compute operands.  There
is no hardwired-zero FPR: `f0` is ordinary writable state.  The file stores
values bit-for-bit; binary32 producers remain responsible for NaN boxing
before writeback.

### Major encodings

| Class | Opcode | Additional selector |
| --- | --- | --- |
| `FLW`, `FLD` | `0000111` (`LOAD-FP`) | `funct3=010`, `011` |
| `FSW`, `FSD` | `0100111` (`STORE-FP`) | `funct3=010`, `011` |
| `FMADD.S/D` | `1000011` | `fmt=00`, `01` |
| `FMSUB.S/D` | `1000111` | `fmt=00`, `01` |
| `FNMSUB.S/D` | `1001011` | `fmt=00`, `01` |
| `FNMADD.S/D` | `1001111` | `fmt=00`, `01` |
| Other FP operations | `1010011` (`OP-FP`) | `funct5`, `fmt`, `rs2`, and `funct3/rm` |

For the R4 fused operations, bits 31:27 are `rs3`, bits 26:25 are `fmt`,
and bits 14:12 are `rm`.  For OP-FP, bits 31:27 are `funct5` and bits
26:25 are `fmt`.

| OP-FP family | `funct5` | Secondary selection |
| --- | --- | --- |
| `FADD` | `00000` | `fmt` |
| `FSUB` | `00001` | `fmt` |
| `FMUL` | `00010` | `fmt` |
| `FDIV` | `00011` | `fmt` |
| `FSGNJ`, `FSGNJN`, `FSGNJX` | `00100` | `funct3=000/001/010` |
| `FMIN`, `FMAX` | `00101` | `funct3=000/001` |
| FP format conversion | `01000` | source format in `rs2` |
| `FSQRT` | `01011` | `rs2=0` |
| `FLE`, `FLT`, `FEQ` | `10100` | `funct3=000/001/010` |
| FP-to-integer conversion | `11000` | W/WU/L/LU in `rs2` |
| Integer-to-FP conversion | `11010` | W/WU/L/LU in `rs2` |
| `FMV.X.W/D`, `FCLASS.S/D` | `11100` | `funct3=000/001`, `rs2=0` |
| `FMV.W/D.X` | `11110` | `funct3=000`, `rs2=0` |

This covers the F/D arithmetic, fused arithmetic, comparisons, classification,
sign injection, minimum/maximum, integer conversions, S/D conversions, raw
moves, and floating load/store encodings needed by RV64.  Integer conversion
selectors include RV64's signed and unsigned 64-bit `L`/`LU` forms.

## Standalone execution pipeline

`openrv64_exec_fpu_rv64fd` in `rtl/core/exec/fpu/rv64-fd.v` is an elastic
variable-latency pipeline:

1. The input stage classifies operands, handles architectural special cases,
   and initializes the arithmetic state.
2. A one-entry fast lane accepts non-iterative operations and arithmetic
   special cases that were completely resolved during classification.
3. Fourteen iteration stages advance four significand bits per stage for
   multiply, fused multiply-add, divide, and square root.  Multiply consumes a
   radix-16 digit; divide and square root unroll four radix-2 steps in each
   stage.
4. Binary32 multiply exits after six iteration stages and binary32 square root
   after seven.  Fused operations, divide, and binary64 multiply/square root
   continue to the final stage.
5. A rotating arbiter selects among the fast lane, the two binary32 taps, and
   the final iterative stage.

Without contention, the observable timing is:

| Result class | `result_valid_o` appears | Earliest output handshake |
| --- | ---: | ---: |
| Fast lane | after acceptance | 1 cycle |
| `FMUL.S` | after 6 iteration cycles | 7 cycles |
| `FSQRT.S` | after 7 iteration cycles | 8 cycles |
| Final iterative stage | after 14 iteration cycles | 15 cycles |

The distinction exists because ready/valid transfers occur on rising edges:
the consumer observes a newly asserted `result_valid_o` during the cycle and
accepts it at the following edge.

Tagged results may complete out of issue order.  This avoids placing a second
reorder structure in the FPU; architectural retirement must use the tag and
remain ordered.  The output arbiter is fair and locks its selected source while
`result_ready_i` is low, so the visible tag, result, and flags cannot change
under backpressure.

Here, an output stall means exactly
`result_valid_o && !result_ready_i`.  It does not intrinsically mean retirement
is stalled.  A blocked result holds its source and backpressure propagates
through that lane as its available slots fill.  The input `ready_o` is selected
from the lane required by the presented request, so a blocked fast lane does
not prevent an iterative request from entering if the iterative pipeline has
space, and vice versa.  `flush_i` discards every in-flight request in both
lanes.

This is intentionally a deep, low-combinational-complexity-per-stage
implementation, not a short combinational divide/square-root path.  The
throughput is not free: arithmetic state and iteration logic are replicated
across all fourteen stages rather than shared by one blocking engine.

The interface reports floating and integer results separately, the five
per-instruction exception flags, and an explicit `unsupported_o` bit.  The tag
is opaque and is intended to become a retirement or producer tag during later
integration.  `type_i` carries the instruction `rs2` selector for conversions:
W/WU/L/LU for integer conversions and S/D for format conversions.

### Implemented now

- `FADD.S/D`, `FSUB.S/D`, `FMUL.S/D`, `FDIV.S/D`, and `FSQRT.S/D`.
- `FMADD.S/D`, `FMSUB.S/D`, `FNMSUB.S/D`, and `FNMADD.S/D`, with one final
  rounding rather than a rounded multiply followed by an add.
- All five rounding modes, including dynamic selection through `frm`.
- Normal, subnormal, zero, infinity, quiet-NaN, and signaling-NaN handling.
- Canonical NaN production and binary32 NaN boxing.
- `FSGNJ*`, `FMIN/FMAX`, `FEQ/FLT/FLE`, and `FCLASS` for S and D.
- `FMV.X.W`, `FMV.W.X`, `FMV.X.D`, and `FMV.D.X` datapath behavior.
- `FCVT.W/WU/L/LU.S/D`, `FCVT.S/D.W/WU/L/LU`, `FCVT.S.D`, and `FCVT.D.S`,
  including saturation, accrued per-instruction flags, and RV64 sign
  extension for 32-bit integer conversion results.
- Tagged out-of-order completion, full valid/ready backpressure, stable
  arbitration under output stalls, and flush.

### Rejected requests

`unsupported_o` is reserved for an invalid operation enum, a format other than
S or D, a reserved static or dynamic rounding mode, or an invalid conversion
type selector.  Architecturally defined F/D computational operations do not
return an unsupported placeholder.

## 4PF core integration

`openrv64_decode_early` hands otherwise-unowned 32-bit major opcodes to a
generic extension-decode class.  It contains no F/D opcode knowledge.
`openrv64_fpu_decode_top` owns F/D opcode selection and delegates detailed
legality and typed register metadata to `openrv64_decode_rv64fd`, then claims
the generic extension candidate from `openrv64_decode_top`.  With no extension
connected, the existing 1P and 3P decode paths still turn F/D instructions into
ordinary illegal-instruction records.  The
`openrv64_fd_dispatch` is instantiated only by the separate 4PF core variant.
It provides independent FPR producer tracking, exact-tag pending-result
bypass, an oldest-eligible backpressured FPU request, and per-slot buffered FP
store operands.  Producer and result identity includes both the wrapping age
ID and physical retirement slot, so a late FPU or LSU response cannot alias a
reused slot.

Only instructions claimed by F/D assert the sidecar allocation-valid lanes;
ordinary integer instructions allocate no FPU state.  The sidecar owns a
sparse result scoreboard indexed by retirement slot.  FPU and FP-load results
enter the same cell only after an exact `(slot, instruction ID)` match.  A
consumer waiting for that exact producer can use the resident value before
architectural retirement.  Compute results emit an identity-only extension
completion token; FP loads and stores use the ordinary LSU completion record
and do not emit a duplicate token.  At ordered retirement the sidecar supplies
readiness, FPR/GPR result selection, flags, and unsupported-operation status;
the integer retirement queue stores none of those F/D fields.

`openrv64_fpu_csrs` owns `fflags`, `frm`, `fcsr`, and `mstatus.FS/SD` behavior.
It connects through the generic CSR-extension response and status-overlay
contract in `openrv64_rv64i_csrs`.  Existing 1P and 3P tops tie that contract
inactive. The 4PF retirement path serializes an FP CSR/status write against an
FP state update when both would otherwise occur in one cycle. Dispatch also
holds an FP instruction behind an older unretired write to `mstatus.FS` or
`frm`, and holds an FP-CSR read behind older unretired FP flag producers. The
generic cross-extension contract is documented in
`doc/core/extension-contract.md`.

The concrete hierarchy is:

- `openrv64_top_4pf`: fixed AXI/native-CCX outer boundary;
- `openrv64_rv64_top_4pf`: fetch, three-lane decode, CSR, and bus integration;
- `openrv64_backend_4pf`: integer execution, window, extension completion, and
  ordered retirement;
- `openrv64_dispatch_window_4pf`: three scalar issue lanes plus the FPU
  sidecar issue path; and
- `openrv64_fd_dispatch`: private-register scheduling, slot-owned tagged
  results, a buffered store-operand cell per live slot, and ordered private
  retirement state.

"4PF" means the existing EX0/EX1/MEM issue structure plus a pipelined FPU
sidecar. It does not mean four decoded instructions per cycle: fetch/decode and
allocation remain three-wide.

Floating loads and stores use the ordinary LSU payload, ordering, translation,
PMP/PMA, alignment, and completion records. Consequently their load/store
access and page faults have the same causes and `tval` rules as integer memory
operations. A successful FP load places its data in the sidecar's tagged result
cell while the ordinary LSU event completes the retirement record.  A faulting
load records only the fault identity in the sidecar; the exception suppresses
the FPR write at retirement.  An FP store operand is captured before issue
through the dedicated FPR read port and then appears to the LSU as ordinary
store data.  An
execution-time FPU rejection uses the generic precise-extension exception
sideband and retires as illegal instruction (cause 2), with `tval` equal to the
original instruction. An F/D instruction while `mstatus.FS=Off`, a disabled
format, or an unclaimed encoding takes the same standard illegal path during
decode.

The existing integer LSU contract still applies: a cacheable store may be
posted only where the endpoint guarantees that no late access/page fault can
arrive. The directed store-fault test uses an uncacheable address and proves
the precise response path; 4PF does not invent a recovery mechanism for a late
fault on an already-retired posted store.

Current conservative policies are deliberate:

- A private source bypasses only a resident result with an exact producer
  `(slot, ID)` match; there is no architectural-register-only forwarding map.
- At most one private FPR write retires per cycle.
- 4PF issues at most one memory operation per cycle. Restoring integer memory
  pairing requires a registered skid/reservation boundary.  The buffered FPR
  store port itself does not participate in integer LSU ready/valid or
  arbitration.
- Full redirects flush the FPU. Selective recovery uses exact `(slot, ID)` age
  identity for correctness; the four-bit branch mask is only an early hint.
- Architectural context/debug save and a complete F/D compliance run are not
  yet provided. Passing the directed tests is not a claim of full ISA
  compliance.

The focused checks for the new integration scaffolding are
`make sim-decode-rv64-fd`, `make sim-rv64-i-csrs`,
`make sim-fpu-csrs`, `make sim-retire-queue-3p`, `make sim-retire-3p`,
`make sim-fd-dispatch`, and
`make sim-fd-uop-harness`. The last target connects the real sidecar,
architectural FPR, and pipelined FPU to small parent window, LSU, completion,
and ordered-retirement models.  It feeds a DAXPY-shaped decoded-uop chain and
a selective-redirect/slot-reuse sequence, including load-to-FPU and
FPU-to-store bypass before architectural FPR retirement.

`make sim-top-4pf` is the fetch-to-retirement test. It runs four private
256-element `sw/fp/daxpy.S` kernels with software unroll factors 1, 4, 16, and
32. It records kernel-only `cycle`/`instret`, accepted/completed FPU requests,
maximum FPU overlap, and average request interval while checking every FP load,
fused arithmetic result, FP store, flag, and final retirement. The u16 kernel
uses the maximum fifteen independent x/y pairs available after reserving one
FPR for alpha; u32 is two fifteen-wide waves plus a two-wide tail.

The current exact-tag bypass and buffered-store implementation produced:

| Unroll | Cycles | Retired | IPC | Previous retire-only cycles | Change |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 10,015 | 2,054 | 0.205 | 11,288 | -11.28% |
| 4 | 6,553 | 1,286 | 0.196 | 6,555 | -0.03% |
| 16 | 5,810 | 1,094 | 0.188 | 5,858 | -0.82% |
| 32 | 5,595 | 1,062 | 0.189 | 5,603 | -0.14% |

The old two-entry versus four-entry transfer-buffer experiment remains useful
historical evidence: extra transfer capacity was exercised but did not shorten
the kernels.  The transfer buffer has now been removed.  The current result
shows why capacity was the wrong lever: bypass materially helps the dependent
u1 schedule, while the already-unrolled kernels remain dominated by memory
ordering and the incomplete retirement head.

`make sim-top-4pf-fmadd32` removes FP memory traffic and arithmetic RAW
dependencies. Its 32-instruction loop body repeats
`fmadd.d f0,f1,f2,f3,rne`; reusing destination `f0` retains WAW ordering but
does not make any FMADD consume the preceding result. With 32 loop iterations,
the full-core test completed 1,024 FMADDs in 1,808 kernel cycles, retired 1,090
instructions, accepted one FMADD every 1.736 cycles on average, and reached 14
FMADDs in flight. This is 0.566 FMADD/cycle and 0.602 scalar IPC with L1I/L1D
disabled and the simple generic-memory testbench. It proves that the integrated
FPU pipelines independent operations; it does not prove one-request-per-cycle
saturation.

`make sim-top-4pf-daxpy-compute` retains DAXPY's accumulator RAW dependency but
removes all load/store instructions from the measured regions.  Each phase
executes 256 exact `fmadd.d y,alpha,x,y` operations.  Constants and accumulators
are initialized before measurement, and results and flags are checked after it.
The testbench requires exactly 256 FPU requests and results and zero LSU
acceptances in every phase.

| Unroll | Cycles | Retired | IPC | FMADD/cycle | Average request interval |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 4,112 | 770 | 0.187 | 0.062 | 16.000 cycles |
| 4 | 1,043 | 386 | 0.370 | 0.245 | 3.964 cycles |
| 16 | 503 | 290 | 0.576 | 0.509 | 1.847 cycles |
| 32 | 464 | 274 | 0.590 | 0.552 | 1.694 cycles |

This confirms that unrolling hides the arithmetic RAW latency: u32 is 8.86
times faster than u1 for the same number of FMADDs.  It also identifies a
separate compute-side ceiling near 0.55 FMADD/cycle.  In u16 and u32 there were
no producer-pending, FPU-backpressure, or full-window cycles; every non-issue
cycle was classified as having no resident compute candidate.  The remaining
compute-only limit is therefore instruction delivery/allocation into the FPU
sidecar, not FPU readiness or operand forwarding.  Full DAXPY's 5,595 u32
cycles versus 464 compute-only cycles confirms that its dominant loss is the
memory instruction stream and shared LSU service, while also showing that an
ideal memory path cannot be equated with the 464-cycle compute-only result.

`make sim-top-4pf-daxpy-store` retains every FMADD and result store while
removing measured loads.  Operands are initialized through `FMV.D.X` before
each phase.  The testbench requires 256 FPU requests/results, 256 LSU
acceptances, and zero FP-load retirement-head cycles per phase.

| Unroll | Compute only | FMADD + stores | Full DAXPY |
| ---: | ---: | ---: | ---: |
| 1 | 4,112 | 4,116 | 10,015 |
| 4 | 1,043 | 1,824 | 6,553 |
| 16 | 503 | 2,105 | 5,810 |
| 32 | 464 | 2,082 | 5,595 |

For u32, removing loads reduces runtime by 3,513 cycles, or 62.8 percent.
Stores are not free: retaining them costs 1,618 cycles over compute-only and
leaves 1,181 LSU-wait cycles, 1,511 memory-order-blocked cycles, and 1,444
incomplete-retirement-head cycles attributed to FP stores.  These counters
overlap.  The store source itself was not blocked in u16 or u32.  This supports
treating load assignment/wakeup as the first F/D-specific problem, but it does
not justify bypassing the ordinary store queue or its retirement authorization.

A clean load-only assignment direction is:

- allocate a strict per-FPR pending owner at decode, before younger consumers
  can observe the destination;
- allocate a small assignment entry when the ordinary LSU accepts the load;
- keep consumers blocked until an exact tagged response deposits data into the
  pending FPR record, then allow result bypass immediately;
- free the transient LSU assignment entry on response, while retaining the
  pending value/owner until precise retirement commits or discards it; and
- initially reject a second live writer to the same FPR, avoiding a
  multi-version physical FPR design.

Read readiness and destination ownership are different lifetimes.  LSU
completion may make a pending FPR readable, but the owner cannot be cleared
until retirement.  Faulted loads remain unreadable until the precise exception
flushes younger consumers.  Stores allocate no destination assignment; they
continue to consume either an architectural or exact-tag pending FPR value and
enter the unified store queue normally.

The existing implementation already realizes the essential assignment
protocol without a second F/D queue.  F/D reserves the destination owner when
the instruction is allocated, the unified LSQ retains `(slot, instruction ID)`
and opaque operation metadata, and the tagged load completion makes the
slot-indexed F/D result readable.  Moving owner creation to LSU completion would
be too late for younger dependency capture.

The shared LSU now emits a generic accepted-load assignment notification with
`(slot, instruction ID, rd, size)`.  The F/D sidecar exact-matches it against
the reservation created at decode and records one `load_assigned` bit in the
existing slot-owned result bank.  It rejects a mismatched destination or
single/double transfer width, and a live FP load result or fault cannot be
accepted without the prior assignment.  Integer loads emit the same generic
notification but do not match F/D state.  This adds a checked protocol edge,
not a duplicate F/D queue.

A controlled unified-load-capacity experiment confirmed that distinction.  The
testbench now snapshots the LSQ's registered counters for each DAXPY phase.  An
eight-load/four-store LSQ used a four-bit transaction tag; production defaults
remained four loads, four stores, and a three-bit tag.

| Memory model | Load entries | u32 cycles | Load queue-full cycles | Load access-wait cycles |
| --- | ---: | ---: | ---: | ---: |
| Cacheless blocking port | 4 | 5,595 | 2,547 | 2,873 |
| Cacheless blocking port | 8 | 5,595 | 2,109 | 2,873 |
| Immediate testbench memory | 4 | 4,351 | 1,833 | 2,077 |
| Immediate testbench memory | 8 | 4,351 | 1,505 | 2,077 |

All four cases completed exactly 512 load allocations, responses, and
completions in the u32 phase.  Extra load entries reduce exposed queue-full and
memory-order-blocked cycles but do not change wall time.  The current DAXPY
harness disables L1D and reaches memory through a blocking core-bus requester,
so it cannot validate hit-under-hit L1D throughput.  Adding a second F/D
assignment queue based on this harness would duplicate LSQ state without
addressing the measured serialization.  The next useful performance harness
must model a pipelined L1D-hit response path while preserving the same exact-tag
completion protocol.

After adding the explicit assignment edge, the normal four-entry LSQ software
run again measured 10,015 / 6,553 / 5,810 / 5,595 cycles for unrolls
1 / 4 / 16 / 32.  Each phase matched exactly 512 FP load assignments and
completed exactly 512 load responses.  The unchanged timing is expected: the
event confirms a reservation that already existed and adds no storage or
memory-service bandwidth.

Phase-scoped DAXPY attribution separates FPU issue-idle cycles by a strict
priority: no unissued compute resident, all blocked operands already available
for forwarding, a producer value still pending, global eligibility, or FPU
input backpressure. For u32, the 5,612 trace-phase cycles contained 256 FPU
issues, 4,586 cycles with no compute candidate resident, 754 with a genuinely
pending producer, and only 16 same-cycle completion opportunities not already
covered by the resident-result bypass. There was no FPU input backpressure.
Separately, the LSU accepted 768 memory operations and exposed 3,960 request
wait cycles; memory-order blocking was exposed for 4,937 cycles, and the
nonempty retirement queue had an incomplete head for 4,559 cycles. FP loads or
stores occupied that incomplete head for 4,329 cycles; a completed head was
never blocked by retirement acceptance. These memory and retirement counts
overlap and must not be added as a wall-time decomposition.

This explains the remaining unroll plateau. The u16 wave places 30 loads before
its first FMADD, beyond the 16-entry window. Larger batches reduce some pending
producer time but still serialize long memory phases and accumulate completed
work behind an incomplete retirement head. Exact-tag bypass fixed a real RAW
delay; it did not create additional LSU bandwidth or decouple ordered
retirement.

### Non-architectural performance probes

Temporary, default-off oracle modifications were used to remove individual
constraints from the u32 DAXPY kernel.  These experiments deliberately did not
check numerical results.  The impossible RTL shortcuts were removed after the
measurements; only the normal implementation and the testbench's selectable
always-ready backing-memory model remain.

| Probe | u32 cycles | Change from 5,595 | What it removes |
| --- | ---: | ---: | --- |
| Normal implementation | 5,595 | baseline | nothing |
| Perfect FP operand availability | 5,496 | -1.8% | all private-register RAW waits |
| Loads complete after real LSU acceptance | 5,237 | -6.4% | load response and load-head wait |
| Always-ready backing memory | 4,351 | -22.2% | external endpoint latency only |
| Both preceding probes | 4,210 | -24.8% | RAW waits and endpoint latency |
| FP memory completes at allocation | 1,667 | -70.2% | FP LSU issue, response, and retirement lifetime |

The last probe retained the real FPU and observed all 256 FPU requests and
results.  It took exactly the same 1,667 kernel cycles as a broader probe that
also completed FP arithmetic at allocation.  Therefore FPU arithmetic latency
is hidden once FP memory lifetime is removed; arithmetic forwarding is not the
critical path for this unrolled kernel.  Conversely, this does not partition
the 3,928-cycle memory-lifetime cost among LSU acceptance bandwidth, outstanding
request capacity, response latency, and ordered-retirement/window residence.
Those need separate probes.

The narrower load probe preserved all 768 real LSU acceptances and the normal
store path.  Its small gain shows that early load-result wakeup alone cannot
drain the ordered memory stream.  An analogous early-store completion probe
did not produce a timing result: it intentionally retired stores before their
LSQ entries had obtained commit authorization, and the LSQ timeout correctly
caught the stranded entry.  Store issue state therefore cannot be detached
from retirement without moving the commit/order token into a persistent LSQ
record.

The first practical target is therefore not another FP-only queue, a larger
FPU window, or more arithmetic forwarding.  The u32 trace recorded no
full-window cycles.  FP loads and stores should remain on the unified LSU/LSQ,
but that path must accept and service multiple tagged operations without
serializing the dispatch stream behind each response.  A registered acceptance
boundary is required before restoring paired memory issue; a combinational
completion-to-issue shortcut formed a zero-time ready/valid loop in simulation.
Separating issued operations from scheduling entries may become useful later,
but the current measurements do not identify window capacity as the first
limit.  Any such split must retain precise result/fault metadata through
retirement and a persistent store commit/order token in the LSQ.

`make sim-top-4pf-faults` runs
`sw/fp/faults.S`; its trap handler verifies FP load access fault cause 5, FP
store access fault cause 7, and execution-time unsupported cause 2, including
`mepc` and `mtval`. The testbench independently observes all three retired
exception causes.

The standalone FPU remains intentionally absent from the 1P/3P `CORE_SRCS` and
`EXEC_SRCS`; `CORE_4PF_SRCS` is a separate manifest. Its focused checks are `make sim-isa-fp`,
`make sim-rv64-fd-fpr`, and
`make sim-exec-fpu-rv64-fd`; the aggregate regression runs all three without
wiring the FPU or FPR into either core.
