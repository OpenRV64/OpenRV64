# Private vector unit contract

This block is an OpenRV64-specific coprocessor experiment. It borrows the RVV
`vtype` layout and integer LMUL grouping, but it is not an RVV implementation.
There is no `vl`, `vstart`, mask execution, vector CSR state, standard vector
instruction decode, or element-precise trap restart.

## Blocks

- `rtl/core/regs/rv64-i-vec.v` is a private 32 by `VLEN` register file split
  into even- and odd-register banks. Every physical port is 64 bits: there are
  four logical reads, limited to two reads per parity bank, and two logical
  writes, limited to one write per parity bank. Bank conflicts return ready
  low. There is no scalar GPR path.
- `rtl/core/exec/vec/rv64-vec.v` implements group-wide AND, OR, XOR and NOT,
  plus floating lane ADD and MUL. It consumes and produces one 64-bit slice per
  cycle. LMUL changes the number of slices, never the port width.
- `rtl/core/exec/vec/rv64-vec-lsu.v` implements aligned register-group loads
  and stores over an exclusive tagged port. It uses the same `DATAPATH_WIDTH`
  parameter as the arithmetic engine for both its register-file slices and
  exclusive memory beats. Store data is gathered and load data is retired
  through the register file in `DATAPATH_WIDTH` slices. A `READ_ONLY`
  parameter makes a secondary instance reject stores.

The LSU dispatch carries a scalar base-register index rather than a resolved
address. After accepting the command, the LSU obtains that pointer through a
read-only ready/valid GPR sideband and retries the read internally on a port
conflict. There is deliberately no GPR write sideband yet; compare reduction
or lane extraction can add one when their semantics are defined.

The operation selectors in `rtl/core/exec/vec/defs.v` are private interface
values, not instruction encodings.

## Instruction-stream test top

`rtl/openrv64_vec_test_top.sv` is a test-only replacement for the production
top. It fetches one instruction from a 64-bit instruction-beat port, reuses the
production RV64I decoder plus one integer ALU and branch unit, and instantiates
the private vector register file, arithmetic pipe, and two LSUs. Scalar
instructions and the primary LSU remain blocking. Arithmetic dispatch is
nonblocking into an eight-context queue by default, and the frontend may
continue issuing scalar, LSU, and independent arithmetic instructions. A load
is sent preferentially to an idle read-only LSU and may remain in flight while
the front end issues following instructions. A second load falls back to the
primary LSU. The LSUs arbitrate the one exclusive memory stream round-robin;
the top memory-tag bit routes responses back to the originating LSU. Scalar
loads/stores, CSRs, traps, interrupts, prediction, and normal production-core
integration are intentionally absent.

The custom instruction definitions live in
`rtl/core/exec/vec/instr-defs.v`. They use RISC-V custom opcode space solely so
short test programs can exercise the blocks; they are not RVV encodings:

| Opcode | `funct3` | Operation | Operands |
| --- | ---: | --- | --- |
| custom-0 `0001011` | 000 | set private `vtype` | `rs1` names the scalar GPR containing the complete command; `rd=rs2=0` |
| custom-0 `0001011` | 001-110 | AND, OR, XOR, NOT, FADD, FMUL | `rd=vd`, `rs1=vs1`, `rs2=vs2` |
| custom-0 `0001011` | 111 | `VSYNC` | `rs1` names the vector register to wait for; `rd=rs2=0` |
| custom-1 `0101011` | 000 | vector load | `rd=vd`, `rs1` names the pointer GPR, `rs2=0` |
| custom-1 `0101011` | 001 | vector store | `rs2=vs3`, `rs1` names the pointer GPR, `rd=0` |

The LSU requests its pointer through a ready/valid GPR read sideband after
dispatch and owns any replay caused by that read stalling. Neither vector unit
has a GPR write path. The scalar ALU can still update the harness's ordinary
GPR file so a program can construct pointers and loop counters.

There is no implicit vector RAW, WAR, or WAW issue scoreboard. Software must
avoid hazards. Every accepted writer contributes its complete LMUL destination
group to an outstanding-write set. `VSYNC vN` blocks until the named register
is absent from that set, meaning every arithmetic, primary-load, and
background-load writer covering `vN` has completed its last register-file
write. Multiple writes covering the same register remain visible until all
owners retire. Ordinary vector instructions do not inspect this set; omitting
a required `VSYNC` can intentionally read stale data.

`make sim-vec-test-top` runs a ROM-style instruction stream that performs a
vector load/XOR/store sequence, an FP32 load/add/store sequence, an internally
retried memory beat, and a scalar countdown branch loop before halting on
`EBREAK`. `make sim-vec` includes this test along with the three block-level
vector tests.

`sw/vector/matmul.S` is an assembled FP32 matrix-multiply workload for this
top. It uses the existing scalar RV64I ALU/branch path for PC-relative pointer
setup, 32-byte pointer increments, nested loop counts, call, and return; no new
scalar opcode was required. At VLEN=256 it processes eight output columns per
vector and accepts any positive number of eight-column blocks. Since the ISA
has no scalar broadcast, A is explicitly prepacked with eight copies of each
logical scalar and B is stored in `[N/8][K][8]` block-major order. This is a
software layout constraint, not a hidden vector-to-GPR or GPR-to-lane path.
The column-block loop is unrolled by two. One loaded A vector feeds independent
products and accumulators for two adjacent output vectors; odd vector-column
counts use a one-block tail. The two products and two accumulator updates can
overlap without reassociating either reduction, which keeps BF16 rounding in K
source order. Product and accumulator registers use opposite parity to fit the
split vector-register banks. `make sim-vec-matmul` links the program and
verifies a 2x3 by 3x16 result in the RTL harness, including an injected LSU
retry.

`sw/matmul_bf16.S` applies the same blocked algorithm to sixteen BF16 lanes per
256-bit vector. Its ABI uses `a5=N/16`, packed `A[M][K][16]`, block-major
`B[N/16][K][16]`, and row-major `C[M][N]`. It deliberately emits separate
FMUL and FADD operations, so the intermediate product is rounded to BF16; it
does not pretend to provide a fused MAC. `make sim-vec-matmul-bf16` verifies a
larger 4x8 by 8x32 assembled workload and all 128 result elements.

## `vtype` command

Arithmetic and LSU dispatch carry a 64-bit `vtype`-shaped command:

| Bits | Field | Current behavior |
| --- | --- | --- |
| 2:0 | `vlmul` | RVV integer encodings for m1, m2, m4, and m8 |
| 5:3 | `vsew` | RVV SEW encoding; checked against floating format |
| 6 | `vta` | Carried in the command but inert without `vl` |
| 7 | `vma` | Carried in the command but inert without masks |
| 10:8 | `xfmt` | Private FP32, BF16, FP8 E4M3, or FP4 E2M1 selector |
| 62:11 | reserved | Must be zero |
| 63 | `vill` | Rejects the command when set |

Standard RVV `vtype` cannot distinguish BF16 from FP16 and cannot encode FP8
or FP4. Bits 10:8 are therefore an explicit private extension, not a claim of
standard compatibility. Packed FP4 uses `vsew=8` because there is no standard
SEW=4 encoding.

Fractional LMUL is rejected. Group bases must be naturally aligned: m2 starts
on an even register, m4 on a multiple of four, and m8 on a multiple of eight.
The current operations are same-width, so source and destination groups have
the same LMUL. A future widening operation will need an independently derived
destination EMUL.

Arithmetic dispatch has `vs1`, `vs2`, and `vd` group indices. A future MAC/FMA
is intentionally not modeled as a third source on this pipe. The intended
shape is a multiplier pipe forwarding its group stream into a separately
scheduled accumulator pipe; the intermediate product is not an architectural
vector-register write. No fused-pipe protocol or widening multiply opcode is
implemented yet.

The arithmetic engine stores speculative results in parameterized tagged
contexts, each an array of 64-bit slices. The shared feed engine sends all
slices of the oldest unfed command and then advances immediately to the next
command; an m1 256-bit command therefore has a four-cycle initiation interval
when the RF is ready, independent of the default eleven-stage lane latency.
Lane tags contain both context and slice indices, so returning commands cannot
alias their result buffers. Completion and matching retirement remain in
dispatch order. A commit drains one slice per cycle into the register file and
asserts retirement ready with the final accepted write. The unit never
constructs a `MAX_LMUL*VLEN` register-file transfer.

## Floating formats

The initial arithmetic formats are:

| `xfmt` | Format | Required `vsew` | Lanes per 64-bit slice |
| ---: | --- | --- | ---: |
| 0 | FP32 / IEEE binary32 | 32 | 2 |
| 1 | BF16 | 16 | 4 |
| 2 | FP8 E4M3FN | 8 | 8 |
| 3 | FP4 E2M1 | 8, packed | 16 |

Arithmetic uses round-to-nearest, ties-to-even. FP4 and FP8 finite overflow
saturates to the largest finite magnitude. BF16/FP32 use infinities and a
canonical quiet NaN. There is no `fflags` output. FP64 is deliberately absent.

FP4, FP8, and BF16 operands expand exactly into the internal FP32 lanes and
round back once. That route is faithful for the implemented BF16 add and
multiply operations. A future fused BF16 multiply-add cannot insert an
intermediate FP32 rounding and will need a fused implementation.

The FP lane pipeline accepts one 64-bit vector slice every cycle and has a
configurable latency, defaulting to eleven stages. Context-plus-slice tags
travel with every token, allowing slices from younger commands to follow an
older command before its first result returns. If both complete input slices
are positive zero, the result is deposited directly in the tagged context
without entering the lane pipelines. Other
exact-zero add/multiply cases and multiply-by-one use shorter combinational
paths inside a lane but retain its fixed token latency. More general per-lane
early completion would require merging early and pipelined lanes back into one
tagged result slice.

## Dispatch, replay, and retirement

Dispatch transfers a command once. The arithmetic unit owns it in one of
`INFLIGHT_DEPTH` contexts after the ready/valid handshake; the two LSU
instances retain their private command slots. If an integration holds
`operands_ready_i` low, the oldest unfed arithmetic command remains queued and
`replay_o` is asserted. This input is not driven by a vector-register
scoreboard in the test top. The scalar core observes replay but does not resend
the operation.

Completed load and arithmetic data remain in the vector unit. A matching
retirement commit causes a sequence of private 64-bit vector-register writes;
a tagged retirement kill discards a pending, executing, or completed
speculative command. Thus the main retirement queue carries only the tag and
status, never vector result data.

Stores additionally require `ordered_valid_i` with the matching tag before any
memory request is emitted. This prevents a speculative store from escaping the
unit.

## Exclusive memory stream

The LSU port is a tagged request/response stream rather than AXI channel
signals:

- a request contains tag, read/write direction, address, write data, and byte
  strobes;
- every accepted request receives one tagged response;
- `mem_resp_retry_i` means the request did not take effect and must be retried;
- `mem_resp_error_i` completes the vector instruction with a fault.

The retry bit is important: the LSU clears only that beat's sent state and
reissues it internally. AXI has no equivalent standard response, so an
eventual exclusive AXI adapter must define where retry comes from instead of
treating SLVERR or DECERR as retryable.

The maximum m8 register group must be an integer multiple of
`DATAPATH_WIDTH`. The active beat count is `VLEN * LMUL / DATAPATH_WIDTH`.
With the current 64-bit datapath, m1 is four beats and m8 is 32. Increasing
the vector width later widens the arithmetic, register-file slice, and LSU
memory beat together rather than exposing divergent width controls.

There is intentionally no GPR load/store forwarding or compare-to-GPR
sideband. Those crossings can later be expressed through the proposed magic
memory aperture without changing the private register file.
