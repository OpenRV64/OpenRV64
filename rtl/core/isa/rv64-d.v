`ifndef OPENRV64_RV64_D_V
`define OPENRV64_RV64_D_V

`include "core/isa/rv64-f.v"

// D depends on F and reuses the common OP-FP funct5 values with fmt=D.
`define RV64_FP_FUNCT3_FLD_FSD      3'b011

// RV64-only moves between a 64-bit floating-point datum and an x register.
// They use the MV_X_CLASS/MV_F_X funct5 values with fmt=D, rs2=0, funct3=0.
`define RV64_FP_FUNCT7_FMV_X_D      7'b1110001
`define RV64_FP_FUNCT7_FMV_D_X      7'b1111001

`endif
