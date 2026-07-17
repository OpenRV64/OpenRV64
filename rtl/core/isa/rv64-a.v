`ifndef OPENRV64_RV64_A_V
`define OPENRV64_RV64_A_V

`include "core/isa/rv64-i.v"

// RV64A encodes the atomic operation in funct5.  aq/rl are accepted by the
// decoder but require no extra action while the core has one strictly ordered,
// blocking memory request in flight at a time.
`define RV64_OPCODE_AMO 7'b0101111

`define RV64_AMO_FUNCT5_BITS 31:27
`define RV64_AMO_AQ_BIT 26
`define RV64_AMO_RL_BIT 25
`define RV64_AMO_FUNCT5(instr) instr[`RV64_AMO_FUNCT5_BITS]

`define RV64_AMO_FUNCT3_W 3'b010
`define RV64_AMO_FUNCT3_D 3'b011

`define RV64_AMO_FUNCT5_ADD  5'b00000
`define RV64_AMO_FUNCT5_SWAP 5'b00001
`define RV64_AMO_FUNCT5_LR   5'b00010
`define RV64_AMO_FUNCT5_SC   5'b00011
`define RV64_AMO_FUNCT5_XOR  5'b00100
`define RV64_AMO_FUNCT5_OR   5'b01000
`define RV64_AMO_FUNCT5_AND  5'b01100
`define RV64_AMO_FUNCT5_MIN  5'b10000
`define RV64_AMO_FUNCT5_MAX  5'b10100
`define RV64_AMO_FUNCT5_MINU 5'b11000
`define RV64_AMO_FUNCT5_MAXU 5'b11100

`endif
