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
reads and one ordered write.  There is no hardwired-zero FPR: `f0` is ordinary
writable state.  The file stores values bit-for-bit; binary32 producers remain
responsible for NaN boxing before writeback.

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
It provides independent FPR producer tracking,
retirement-only FPR dependency wakeup, an oldest-eligible backpressured FPU
request, and a two-entry associative FP memory-transfer buffer.  Transfer
entries carry both the wrapping age ID and physical retirement slot,
so a late LSU response cannot alias a reused slot.

Only instructions claimed by F/D assert the sidecar allocation-valid lanes;
ordinary integer instructions allocate no FPU state.  The sidecar owns a
sparse result scoreboard indexed by retirement slot.
FPU, FP-load, and FP-store completions enter that scoreboard only after an
exact `(slot, instruction ID)` match.  It then emits an identity-only completion
token to the ordinary retirement queue.  At ordered retirement it supplies
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
- `openrv64_fd_dispatch`: private-register scheduling, a parameterized transfer
  buffer (two entries by default), and sparse extension results.

"4PF" means the existing EX0/EX1/MEM issue structure plus a pipelined FPU
sidecar. It does not mean four decoded instructions per cycle: fetch/decode and
allocation remain three-wide.

Floating loads and stores use the ordinary LSU payload, ordering, translation,
PMP/PMA, alignment, and completion records. Consequently their load/store
access and page faults have the same causes and `tval` rules as integer memory
operations. A faulting load marks its sidecar entry complete without waiting
for data; the exception suppresses the FPR write at retirement. An
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

- FPR dependencies wake only at retirement; there is no FPR forwarding.
- At most one private FPR write retires per cycle.
- The LSU/FPU transfer depth is parameterized and defaults to two; most compute
  instructions consume no transfer entry.
- 4PF issues at most one memory operation per cycle. Restoring integer memory
  pairing requires a registered skid/reservation boundary, because coupling
  LSU ready back through sidecar capacity creates a combinational loop.
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
two-entry transfer buffer, architectural FPR, and pipelined FPU to small parent
window, LSU, completion, and ordered-retirement models.  It feeds a
DAXPY-shaped decoded-uop chain and a selective-redirect/slot-reuse sequence.

`make sim-top-4pf` is the fetch-to-retirement test. It runs four private
256-element `sw/fp/daxpy.S` kernels with software unroll factors 1, 4, 16, and
32. It records kernel-only `cycle`/`instret`, accepted/completed FPU requests,
maximum FPU overlap, maximum transfer-buffer occupancy, and average request
interval while checking every FP load, fused arithmetic result, FP store,
flag, and final retirement. The u16 kernel uses the maximum fifteen independent
x/y pairs available after reserving one FPR for alpha; u32 is two fifteen-wide
waves plus a two-wide tail.

A controlled two-entry versus four-entry transfer-buffer run produced
bit-for-bit identical DAXPY cycle, retirement, FPU-overlap, and request-spacing
results. The four-entry run reached occupancy four for u4/u16/u32, so the extra
capacity was used, but it did not shorten execution. The default remains two.
Under the current retire-only FPR wakeup policy, extra completed loads cannot
wake their dependent arithmetic before retirement; capacity alone therefore
does not repair the measured FPU starvation.

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

Phase-scoped DAXPY attribution separates FPU issue-idle cycles by a strict
priority: no unissued compute resident, all blocked operands already available
for forwarding, a producer value still pending, global eligibility, or FPU
input backpressure. For u32, the 5,620 trace-phase cycles contained 256 FPU
issues, 4,586 cycles with no compute candidate resident, 746 with a genuinely
pending producer, and only 32 where forwarding alone could make a resident
compute candidate ready. There was no FPU input backpressure. Separately, the
data-memory request interface was active for 3,792 cycles (768 accepts plus
3,024 wait cycles), memory-order blocking was exposed for 5,196 cycles, and
the nonempty retirement queue had an incomplete head for 4,567 cycles. FP
loads or stores occupied that incomplete head for 4,329 cycles; a completed
head was never blocked by retirement acceptance. These memory and retirement
counts overlap and must not be added as a wall-time decomposition.

This explains the unroll plateau. The u16 wave places 30 loads before its first
FMADD, beyond the 16-entry window. Increasing u16 to u32 removed 830 cycles of
producer-pending issue stalls but added 575 cycles with no compute candidate
resident, for only a 255-cycle net reduction. The batched load/FMAD/store
schedule makes most load values retire before their consumers enter the
window, so it suppresses the very completion-to-retirement interval that FP
forwarding could exploit. A forwarding-oriented experiment therefore also
needs an interleaved load/compute schedule; merely increasing unroll repeats
larger phases of serialized memory traffic.

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
