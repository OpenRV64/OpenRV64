`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

module openrv64_except_vector #(
    parameter [`RV64_XLEN-1:0] RESET_VECTOR = {`RV64_XLEN{1'b0}}
) (
    input  wire                         reset_i,
    input  wire                         trap_i,
    input  wire                         irq_i,
    input  wire                         mret_i,
    input  wire                         sret_i,
    input  wire                         restart_i,
    input  wire                         redirect_i,
    input  wire [`RV64_XLEN-1:0]        trap_vector_i,
    input  wire [`RV64_XLEN-1:0]        mepc_i,
    input  wire [`RV64_XLEN-1:0]        sepc_i,
    input  wire [`RV64_XLEN-1:0]        restart_target_i,
    input  wire [`RV64_XLEN-1:0]        redirect_target_i,

    output reg                          vector_valid_o,
    output reg  [`RV64_XLEN-1:0]        vector_target_o
);

    always @* begin
        vector_valid_o  = 1'b0;
        vector_target_o = {`RV64_XLEN{1'b0}};

        if (reset_i) begin
            vector_valid_o  = 1'b1;
            vector_target_o = RESET_VECTOR;
        end else if (trap_i || irq_i) begin
            vector_valid_o  = 1'b1;
            vector_target_o = trap_vector_i;
        end else if (mret_i) begin
            vector_valid_o  = 1'b1;
            vector_target_o = mepc_i;
        end else if (sret_i) begin
            vector_valid_o  = 1'b1;
            vector_target_o = sepc_i;
        end else if (restart_i) begin
            vector_valid_o  = 1'b1;
            vector_target_o = restart_target_i;
        end else if (redirect_i) begin
            vector_valid_o  = 1'b1;
            vector_target_o = redirect_target_i;
        end
    end

endmodule
