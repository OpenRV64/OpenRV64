`ifndef OPENRV64_EXEC_VEC_DEFS_V
`define OPENRV64_EXEC_VEC_DEFS_V

// This is intentionally a private OpenRV64 coprocessor interface, not an RVV
// encoding.  Decode may translate any future custom instruction encoding into
// these operations without exposing the vector register contents to the scalar
// core.
`define OPENRV64_VEC_OP_WIDTH 3
`define OPENRV64_VEC_OP_INVALID 3'd0
`define OPENRV64_VEC_OP_AND     3'd1
`define OPENRV64_VEC_OP_OR      3'd2
`define OPENRV64_VEC_OP_XOR     3'd3
`define OPENRV64_VEC_OP_NOT     3'd4
`define OPENRV64_VEC_OP_FADD    3'd5
`define OPENRV64_VEC_OP_FMUL    3'd6

// vtype command layout.  Bits 7:0 and vill match architectural RVV vtype:
//   [2:0] vlmul, [5:3] vsew, [6] vta, [7] vma, [63] vill.
// RVV vtype does not distinguish BF16 from FP16 and has no sub-byte SEW.
// This private experiment therefore uses otherwise-reserved bits [10:8] as an
// explicit numeric-format class.  A future standard encoding can translate at
// dispatch without changing the vector execution interface below this point.
`define OPENRV64_VEC_VTYPE_WIDTH 64
`define OPENRV64_VEC_VTYPE_VLMUL_LSB 0
`define OPENRV64_VEC_VTYPE_VSEW_LSB 3
`define OPENRV64_VEC_VTYPE_VTA_BIT 6
`define OPENRV64_VEC_VTYPE_VMA_BIT 7
`define OPENRV64_VEC_VTYPE_XFMT_LSB 8
`define OPENRV64_VEC_VTYPE_XFMT_WIDTH 3
`define OPENRV64_VEC_VTYPE_VILL_BIT 63

`define OPENRV64_VEC_VLMUL_M1 3'b000
`define OPENRV64_VEC_VLMUL_M2 3'b001
`define OPENRV64_VEC_VLMUL_M4 3'b010
`define OPENRV64_VEC_VLMUL_M8 3'b011

`define OPENRV64_VEC_VSEW_E8  3'b000
`define OPENRV64_VEC_VSEW_E16 3'b001
`define OPENRV64_VEC_VSEW_E32 3'b010
`define OPENRV64_VEC_VSEW_E64 3'b011

`define OPENRV64_VEC_XFMT_FP32     3'd0
`define OPENRV64_VEC_XFMT_BF16     3'd1
`define OPENRV64_VEC_XFMT_FP8_E4M3 3'd2
`define OPENRV64_VEC_XFMT_FP4_E2M1 3'd3

// Internal execution format after vtype validation.
`define OPENRV64_VEC_FMT_WIDTH 3
`define OPENRV64_VEC_FMT_FP4_E2M1 3'd0
`define OPENRV64_VEC_FMT_FP8_E4M3 3'd1
`define OPENRV64_VEC_FMT_BF16     3'd2
`define OPENRV64_VEC_FMT_FP32     3'd3

`define OPENRV64_VEC_LSU_OP_WIDTH 2
`define OPENRV64_VEC_LSU_INVALID 2'd0
`define OPENRV64_VEC_LSU_LOAD    2'd1
`define OPENRV64_VEC_LSU_STORE   2'd2

`endif
