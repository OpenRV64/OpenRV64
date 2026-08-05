`ifndef OPENRV64_DECODE_ALU_DEFS_V
`define OPENRV64_DECODE_ALU_DEFS_V

`define RV64_ALU_EXT_WIDTH 3
`define RV64_ALU_EXT_INVALID 3'd0
`define RV64_ALU_EXT_BASE 3'd1
`define RV64_ALU_EXT_M 3'd2
`define RV64_ALU_EXT_ZBB 3'd3

`define RV64_ALU_OP_WIDTH 5
`define RV64_ALU_OP_INVALID 5'd0
`define RV64_ALU_OP_ADD 5'd1
`define RV64_ALU_OP_SUB 5'd2
`define RV64_ALU_OP_SLL 5'd3
`define RV64_ALU_OP_SLT 5'd4
`define RV64_ALU_OP_SLTU 5'd5
`define RV64_ALU_OP_XOR 5'd6
`define RV64_ALU_OP_SRL 5'd7
`define RV64_ALU_OP_SRA 5'd8
`define RV64_ALU_OP_OR 5'd9
`define RV64_ALU_OP_AND 5'd10
`define RV64_ALU_OP_LUI 5'd11
`define RV64_ALU_OP_AUIPC 5'd12
`define RV64_ALU_OP_MUL 5'd13
`define RV64_ALU_OP_MULH 5'd14
`define RV64_ALU_OP_MULHSU 5'd15
`define RV64_ALU_OP_MULHU 5'd16
`define RV64_ALU_OP_DIV 5'd17
`define RV64_ALU_OP_DIVU 5'd18
`define RV64_ALU_OP_REM 5'd19
`define RV64_ALU_OP_REMU 5'd20

// Operation values are interpreted within their extension class.  Zbb uses
// the same five-bit payload field without widening every dispatch and retire
// queue entry.
`define RV64_ALU_OP_ZBB_ANDN 5'd1
`define RV64_ALU_OP_ZBB_ORN 5'd2
`define RV64_ALU_OP_ZBB_XNOR 5'd3
`define RV64_ALU_OP_ZBB_MIN 5'd4
`define RV64_ALU_OP_ZBB_MINU 5'd5
`define RV64_ALU_OP_ZBB_MAX 5'd6
`define RV64_ALU_OP_ZBB_MAXU 5'd7
`define RV64_ALU_OP_ZBB_ROL 5'd8
`define RV64_ALU_OP_ZBB_ROR 5'd9
`define RV64_ALU_OP_ZBB_CLZ 5'd10
`define RV64_ALU_OP_ZBB_CTZ 5'd11
`define RV64_ALU_OP_ZBB_CPOP 5'd12
`define RV64_ALU_OP_ZBB_SEXT_B 5'd13
`define RV64_ALU_OP_ZBB_SEXT_H 5'd14
`define RV64_ALU_OP_ZBB_ZEXT_H 5'd15
`define RV64_ALU_OP_ZBB_ORC_B 5'd16
`define RV64_ALU_OP_ZBB_REV8 5'd17

`endif
