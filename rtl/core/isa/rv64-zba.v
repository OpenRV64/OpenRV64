`ifndef OPENRV64_RV64_ZBA_V
`define OPENRV64_RV64_ZBA_V

`ifndef OPENRV64_RV64_V
`include "core/isa/rv64-i.v"
`endif

// Zba: address generation bit-manipulation instructions.
// Common forms use OP; RV64 .uw forms use OP-32.
`define RV64_ZBA_OPCODE_SHADD `RV64_OPCODE_OP
`define RV64_ZBA_OPCODE_UW `RV64_OPCODE_OP_32
`define RV64_ZBA_OPCODE_SLLI_UW `RV64_OPCODE_OP_IMM_32

`define RV64_ZBA_FUNCT7_SHADD 7'b0010000
`define RV64_ZBA_FUNCT7_ADD_UW 7'b0000100
`define RV64_ZBA_FUNCT6_SLLI_UW 6'b000010

`define RV64_ZBA_FUNCT3_ADD_UW 3'b000
`define RV64_ZBA_FUNCT3_SLLI_UW 3'b001
`define RV64_ZBA_FUNCT3_SH1ADD 3'b010
`define RV64_ZBA_FUNCT3_SH2ADD 3'b100
`define RV64_ZBA_FUNCT3_SH3ADD 3'b110

`endif
