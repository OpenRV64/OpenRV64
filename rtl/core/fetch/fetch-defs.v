`ifndef OPENRV64_FETCH_DEFS_V
`define OPENRV64_FETCH_DEFS_V

`define RV64_FETCH_DECODE_BUS_WIDTH 120
`define RV64_FETCH_DECODE_BUS_INSTR_BITS 31:0
`define RV64_FETCH_DECODE_BUS_PC_BITS 95:32
`define RV64_FETCH_DECODE_BUS_ACCESS_FAULT_BIT 96
`define RV64_FETCH_DECODE_BUS_PAGE_FAULT_BIT 97
// Direct-control displacement with the architecturally-zero bit 0 omitted.
// Twenty bits cover the full signed JAL range; branch displacements are sign
// extended into the same encoding.
`define RV64_FETCH_DECODE_BUS_PREDECODE_OFFSET_BITS 117:98
`define RV64_FETCH_DECODE_BUS_PREDECODE_VALID_BIT 118
`define RV64_FETCH_DECODE_BUS_PREDECODE_CONDITIONAL_BIT 119

// Stream-RLE control classification.  Direction refinement is meaningful for
// conditionals; only direct jumps/calls have an intrinsically known successor.
`define OPENRV64_STREAM_CONTROL_CONDITIONAL  3'd0
`define OPENRV64_STREAM_CONTROL_DIRECT_JUMP  3'd1
`define OPENRV64_STREAM_CONTROL_DIRECT_CALL  3'd2
`define OPENRV64_STREAM_CONTROL_INDIRECT_JUMP 3'd3
`define OPENRV64_STREAM_CONTROL_INDIRECT_CALL 3'd4
`define OPENRV64_STREAM_CONTROL_RETURN       3'd5

`endif
