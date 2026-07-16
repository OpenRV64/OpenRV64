`ifndef OPENRV64_RV64_M_V
`define OPENRV64_RV64_M_V

`ifndef OPENRV64_RV64_V
`include "core/isa/rv64-i.v"
`endif

// RV64M shares the OP and OP-32 opcodes with base integer R-type instructions.
`define RV64_M_FUNCT7 7'b0000001

`define RV64_M_FUNCT3_MUL 3'b000
`define RV64_M_FUNCT3_MULH 3'b001
`define RV64_M_FUNCT3_MULHSU 3'b010
`define RV64_M_FUNCT3_MULHU 3'b011
`define RV64_M_FUNCT3_DIV 3'b100
`define RV64_M_FUNCT3_DIVU 3'b101
`define RV64_M_FUNCT3_REM 3'b110
`define RV64_M_FUNCT3_REMU 3'b111

// W-form RV64M operations use the same funct3 values under RV64_OPCODE_OP_32:
// MULW, DIVW, DIVUW, REMW, and REMUW.

`endif
