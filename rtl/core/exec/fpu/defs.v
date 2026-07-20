`ifndef OPENRV64_EXEC_FPU_DEFS_V
`define OPENRV64_EXEC_FPU_DEFS_V

`define OPENRV64_FP_OP_WIDTH        5
`define OPENRV64_FP_OP_INVALID      5'd0
`define OPENRV64_FP_OP_ADD          5'd1
`define OPENRV64_FP_OP_SUB          5'd2
`define OPENRV64_FP_OP_MUL          5'd3
`define OPENRV64_FP_OP_DIV          5'd4
`define OPENRV64_FP_OP_SQRT         5'd5
`define OPENRV64_FP_OP_SGNJ         5'd6
`define OPENRV64_FP_OP_SGNJN        5'd7
`define OPENRV64_FP_OP_SGNJX        5'd8
`define OPENRV64_FP_OP_MIN          5'd9
`define OPENRV64_FP_OP_MAX          5'd10
`define OPENRV64_FP_OP_EQ           5'd11
`define OPENRV64_FP_OP_LT           5'd12
`define OPENRV64_FP_OP_LE           5'd13
`define OPENRV64_FP_OP_CLASS        5'd14
`define OPENRV64_FP_OP_MV_X_F       5'd15
`define OPENRV64_FP_OP_MV_F_X       5'd16
`define OPENRV64_FP_OP_CVT_TO_INT   5'd17
`define OPENRV64_FP_OP_CVT_FROM_INT 5'd18
`define OPENRV64_FP_OP_CVT_FORMAT   5'd19
`define OPENRV64_FP_OP_MADD         5'd20
`define OPENRV64_FP_OP_MSUB         5'd21
`define OPENRV64_FP_OP_NMSUB        5'd22
`define OPENRV64_FP_OP_NMADD        5'd23

`define OPENRV64_FP_RESULT_FP       1'b0
`define OPENRV64_FP_RESULT_INT      1'b1

`endif
