`timescale 1ns/1ps

module cmn_reg_port #(
    parameter integer REG_WIDTH     = 64,
    parameter integer REG_COUNT     = 32,
    parameter integer REG_BITS = $clog2(REG_COUNT)
) (
    input wire clk,
    input wire rst_n,

    input wire [REG_BITS-1:0] addr_i,
    input wire req_i,
    output wire valid_o
);


endmodule
