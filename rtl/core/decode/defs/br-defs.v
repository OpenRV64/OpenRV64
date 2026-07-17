`ifndef OPENRV64_DECODE_BR_DEFS_V
`define OPENRV64_DECODE_BR_DEFS_V

`define RV64_BR_OP_WIDTH 4
`define RV64_BR_OP_INVALID 4'd0
`define RV64_BR_OP_BEQ 4'd1
`define RV64_BR_OP_BNE 4'd2
`define RV64_BR_OP_BLT 4'd3
`define RV64_BR_OP_BGE 4'd4
`define RV64_BR_OP_BLTU 4'd5
`define RV64_BR_OP_BGEU 4'd6
`define RV64_BR_OP_JAL 4'd7
`define RV64_BR_OP_JALR 4'd8

`endif
