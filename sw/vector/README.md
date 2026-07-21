# Private-vector software

`matmul.S` contains a callable FP32 matrix multiply for the private OpenRV64
vector experiment. It uses the custom test-harness instructions, not RVV. `N`
must be a multiple of eight.

The routine computes eight output columns per 256-bit vector:

```text
C[M][N] = A[M][K] x B[K][N]
```

Because the current unit has no scalar-to-vector broadcast or lane-extract
operation, `A` uses a packed representation. Each logical `A[i][k]` occupies
one 32-byte vector containing eight copies of the scalar. `B` is stored in
eight-column blocks with shape `[N/8][K][8]`; each block remains contiguous
through the reduction loop. `C` is ordinary row-major FP32.

The calling convention is:

| Register | Value |
| --- | --- |
| `a0` | Packed `A[M][K][8]` pointer |
| `a1` | Block-major `B[N/8][K][8]` pointer |
| `a2` | Row-major `C[M][N]` pointer |
| `a3` | `M` |
| `a4` | `K` |
| `a5` | `N/8` vector-column count |

The routine clobbers `t0`-`t6` and vector registers `v2`-`v9`.
Vector loads obtain their pointers through the read-only GPR sideband; the
vector unit never writes a scalar register.

The assembly macro set also exposes `VLDA vs`, `VMAC vs1,vs2`, and `VSTA vd`.
They operate on two private, type-tagged accumulators selected by instruction
bit 25: load an initial vector, apply implicit `acc += vs1*vs2` updates, then
export it to an architectural vector register. Commands serialize per selected
accumulator, while acc0 and acc1 can overlap. `VSTA` follows the same dependency
discipline as any other vector-register writer.

The test top has a preferred read-only LSU plus the primary load/store LSU.
Consecutive loads can therefore overlap on the shared 64-bit memory stream.
There is no automatic vector hazard scoreboard. The assembly processes two
adjacent output-column vectors together. It loads one packed A vector into
`v2`, loads the two corresponding B vectors into `v3`/`v7`, and updates acc0
and acc1 with overlapping VMAC commands before exporting to `v8`/`v9`. Each `VSYNC vA,vB`
waits for both named registers, allowing adjacent dependency waits to share an
instruction. Explicit waits protect only actual load, product, accumulator,
and store dependencies. An odd vector-column count falls through a one-block
tail.

Run `make sim-vec-matmul` to assemble the included 2-by-3 by 3-by-16 example,
load the ELF-derived memory image into the vector test top, and check
all thirty-two FP32 outputs.

`sw/matmul_bf16.S` is the BF16 counterpart. A 256-bit vector holds sixteen
BF16 columns, so its `a5` argument is `N/16` and its packed layouts are
`A[M][K][16]` and `B[N/16][K][16]`. VMAC retains FP32 product/add precision
until rounding each update back to BF16. The
`sim-vec-matmul-bf16` target executes a larger 4-by-8 by 8-by-32 case and
checks all 128 results.
