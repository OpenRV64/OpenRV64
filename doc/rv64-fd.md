# RV64F/RV64D ISA and standalone execution pipeline

This document defines the floating-point ISA contract added to OpenRV64 and
the deliberately unintegrated first execution pipeline.  The encoding headers
cover the ratified F and D instruction spaces.  The execution block is a
smaller, synthesizable implementation subset; the core does **not** advertise
F or D yet.

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

The Verilog encoding contract is in `rtl/core/isa/rv64-f.v` and
`rtl/core/isa/rv64-d.v`.

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
fixed-latency pipeline:

1. The input stage classifies operands, handles architectural special cases,
   and initializes the arithmetic state.
2. Fourteen iteration stages advance four significand bits per stage for
   multiply, fused multiply-add, divide, and square root.  Multiply consumes a
   radix-16 digit; divide and square root unroll four radix-2 steps in each
   stage.  Simple operations and conversions traverse the same stages to
   preserve request order.
3. The final stage rounds and formats the result.  Its state remains stable
   until the consumer accepts it.

With no stalls, response valid appears 14 cycles after request acceptance and
the unit accepts one request per cycle.  A blocked output backpressures all
earlier stages without overwriting state, and `flush_i` discards every
in-flight request.  This is intentionally a deep,
low-combinational-complexity-per-stage implementation, not a short
combinational divide/square-root path.  The throughput is not free: arithmetic
state and iteration logic are replicated across all fourteen stages rather
than shared by one blocking engine.

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
- Full valid/ready backpressure, response tags, and flush.

### Rejected requests

`unsupported_o` is reserved for an invalid operation enum, a format other than
S or D, a reserved static or dynamic rounding mode, or an invalid conversion
type selector.  Architecturally defined F/D computational operations do not
return an unsupported placeholder.

## Deliberately not integrated

The following core work is still required before F/D can be advertised:

- decode and illegal-instruction qualification;
- the 32-entry, 64-bit floating-point register file and its read/write ports;
- `mstatus.FS`, `fcsr`, accrued flag updates, and state-dirty tracking;
- floating load/store routing, alignment, and fault behavior through the LSU;
- dispatch hazards, producer ownership, forwarding, and writeback selection;
- precise retirement and exception behavior;
- context/debug exposure and architectural compliance tests;
- an instruction decoder that maps encoded operation and conversion selectors
  onto the standalone unit interface.

The standalone block is intentionally absent from `CORE_SRCS` and `EXEC_SRCS`.
Its focused checks are `make sim-isa-fp` and
`make sim-exec-fpu-rv64-fd`; the aggregate regression runs both without wiring
the FPU into either core.
