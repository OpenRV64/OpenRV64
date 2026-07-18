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

`endif
