`ifndef OPENRV64_RV64_ZBC_V
`define OPENRV64_RV64_ZBC_V

`ifndef OPENRV64_RV64_V
`include "core/isa/rv64-i.v"
`endif

// Zbc: carry-less multiplication bit-manipulation instructions.
`define RV64_ZBC_OPCODE `RV64_OPCODE_OP
`define RV64_ZBC_FUNCT7_CLMUL 7'b0000101

`define RV64_ZBC_FUNCT3_CLMUL 3'b001
`define RV64_ZBC_FUNCT3_CLMULR 3'b010
`define RV64_ZBC_FUNCT3_CLMULH 3'b011

`endif
