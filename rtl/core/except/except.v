`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

`ifndef OPENRV64_EXCEPT_DEFS_V
`define OPENRV64_EXCEPT_DEFS_V

`define RV64_EXCEPT_CAUSE_WIDTH 5
`define RV64_EXCEPT_CAUSE_INSTR_ADDR_MISALIGNED 5'd0
`define RV64_EXCEPT_CAUSE_ILLEGAL_INSTR 5'd2
`define RV64_EXCEPT_CAUSE_BREAKPOINT 5'd3
`define RV64_EXCEPT_CAUSE_LOAD_ADDR_MISALIGNED 5'd4
`define RV64_EXCEPT_CAUSE_STORE_ADDR_MISALIGNED 5'd6
`define RV64_EXCEPT_CAUSE_ECALL_M 5'd11

`endif

module openrv64_except (
    input  wire                         illegal_instr_i,
    input  wire                         instr_misaligned_i,
    input  wire                         load_misaligned_i,
    input  wire                         store_misaligned_i,
    input  wire                         ecall_i,
    input  wire                         ebreak_i,
    input  wire [`RV64_XLEN-1:0]        pc_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] instr_i,
    input  wire [`RV64_XLEN-1:0]        badaddr_i,

    output reg                          exception_o,
    output reg                          halt_o,
    output reg [`RV64_EXCEPT_CAUSE_WIDTH-1:0] cause_o,
    output reg [`RV64_XLEN-1:0]         tval_o
);

    always @* begin
        exception_o = 1'b0;
        halt_o      = 1'b0;
        cause_o     = `RV64_EXCEPT_CAUSE_INSTR_ADDR_MISALIGNED;
        tval_o      = {`RV64_XLEN{1'b0}};

        if (instr_misaligned_i) begin
            exception_o = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_INSTR_ADDR_MISALIGNED;
            tval_o      = pc_i;
        end else if (illegal_instr_i) begin
            exception_o = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_ILLEGAL_INSTR;
            tval_o      = {{32{1'b0}}, instr_i};
        end else if (load_misaligned_i) begin
            exception_o = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_LOAD_ADDR_MISALIGNED;
            tval_o      = badaddr_i;
        end else if (store_misaligned_i) begin
            exception_o = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_STORE_ADDR_MISALIGNED;
            tval_o      = badaddr_i;
        end else if (ecall_i) begin
            exception_o = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_ECALL_M;
        end else if (ebreak_i) begin
            exception_o = 1'b1;
            halt_o      = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_BREAKPOINT;
        end
    end

endmodule
