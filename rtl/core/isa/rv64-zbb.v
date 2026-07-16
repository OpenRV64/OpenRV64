`ifndef OPENRV64_RV64_ZBB_V
`define OPENRV64_RV64_ZBB_V

`ifndef OPENRV64_RV64_V
`include "core/isa/rv64-i.v"
`endif

// Zbb: basic bit-manipulation instructions.
`define RV64_ZBB_OPCODE_REG `RV64_OPCODE_OP
`define RV64_ZBB_OPCODE_REG_32 `RV64_OPCODE_OP_32
`define RV64_ZBB_OPCODE_IMM `RV64_OPCODE_OP_IMM
`define RV64_ZBB_OPCODE_IMM_32 `RV64_OPCODE_OP_IMM_32

// Logical-with-negate register forms: andn, orn, xnor.
`define RV64_ZBB_FUNCT7_LOGIC_N 7'b0100000
`define RV64_ZBB_FUNCT3_ANDN 3'b111
`define RV64_ZBB_FUNCT3_ORN 3'b110
`define RV64_ZBB_FUNCT3_XNOR 3'b100

// Min/max register forms.
`define RV64_ZBB_FUNCT7_MINMAX 7'b0000101
`define RV64_ZBB_FUNCT3_MIN 3'b100
`define RV64_ZBB_FUNCT3_MINU 3'b101
`define RV64_ZBB_FUNCT3_MAX 3'b110
`define RV64_ZBB_FUNCT3_MAXU 3'b111

// Rotate register and immediate forms.
`define RV64_ZBB_FUNCT7_ROTATE 7'b0110000
`define RV64_ZBB_FUNCT6_RORI 6'b011000
`define RV64_ZBB_FUNCT3_ROL 3'b001
`define RV64_ZBB_FUNCT3_ROR 3'b101
`define RV64_ZBB_FUNCT3_RORI 3'b101

// Unary count/sign-extension forms.
`define RV64_ZBB_FUNCT3_UNARY 3'b001
`define RV64_ZBB_FUNCT12_CLZ 12'h600
`define RV64_ZBB_FUNCT12_CTZ 12'h601
`define RV64_ZBB_FUNCT12_CPOP 12'h602
`define RV64_ZBB_FUNCT12_SEXT_B 12'h604
`define RV64_ZBB_FUNCT12_SEXT_H 12'h605

// RV64 word-count forms reuse the same funct12 values under OP-IMM-32.
`define RV64_ZBB_FUNCT12_CLZW `RV64_ZBB_FUNCT12_CLZ
`define RV64_ZBB_FUNCT12_CTZW `RV64_ZBB_FUNCT12_CTZ
`define RV64_ZBB_FUNCT12_CPOPW `RV64_ZBB_FUNCT12_CPOP

// Byte-granular immediate forms.
`define RV64_ZBB_FUNCT3_ORC_B 3'b101
`define RV64_ZBB_FUNCT12_ORC_B 12'h287
`define RV64_ZBB_FUNCT3_REV8 3'b101
`define RV64_ZBB_FUNCT12_REV8 12'h6b8

// RV64 zext.h is encoded as packw with rs2=x0.
`define RV64_ZBB_OPCODE_ZEXT_H `RV64_OPCODE_OP_32
`define RV64_ZBB_FUNCT7_ZEXT_H 7'b0000100
`define RV64_ZBB_FUNCT3_ZEXT_H 3'b100
`define RV64_ZBB_RS2_ZEXT_H `RV64_REG_X0

`endif
