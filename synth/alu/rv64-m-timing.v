`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"

// Timing-only wrapper that makes multiplication unreachable while retaining
// all four divide/remainder operations and RV64/RV64W selection.
module openrv64_timing_rv64m_divide (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         valid_i,
    input  wire [1:0]                   div_op_i,
    input  wire                         word_op_i,
    input  wire [`RV64_XLEN-1:0]        src1_i,
    input  wire [`RV64_XLEN-1:0]        src2_i,
    input  wire                         result_ready_i,
    output wire                         ready_o,
    output wire                         busy_o,
    output wire                         result_valid_o,
    output wire                         illegal_o,
    output wire [`RV64_XLEN-1:0]        result_o
);

    reg [`RV64_ALU_OP_WIDTH-1:0] op_sel;
    always @* begin
        case (div_op_i)
            2'd0: op_sel = `RV64_ALU_OP_DIV;
            2'd1: op_sel = `RV64_ALU_OP_DIVU;
            2'd2: op_sel = `RV64_ALU_OP_REM;
            default: op_sel = `RV64_ALU_OP_REMU;
        endcase
    end

    // A one-bit multiply chunk keeps structurally unreachable multiply
    // recovery logic from masking the divide path in ABC's unconstrained
    // state-space timing report.
    openrv64_exec_rv64m #(
        .MUL_BITS_PER_CYCLE(1),
        .DIV_BITS_PER_CYCLE(2)
    ) u_divide (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i),
        .valid_i(valid_i),
        .ready_o(ready_o),
        .busy_o(busy_o),
        .op_sel_i(op_sel),
        .word_op_i(word_op_i),
        .src1_i(src1_i),
        .src2_i(src2_i),
        .result_valid_o(result_valid_o),
        .result_ready_i(result_ready_i),
        .illegal_o(illegal_o),
        .result_o(result_o)
    );

endmodule
