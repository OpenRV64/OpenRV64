`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

module openrv64_retire (
    input  wire                             valid_i,
    input  wire                             clear_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr_i,
    input  wire                             reg_write_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr_i,

    output wire                             release_valid_o,
    output wire                             release_uses_rs1_o,
    output wire                             release_uses_rs2_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] release_rs1_addr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] release_rs2_addr_o,
    output wire                             release_reg_write_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] release_rd_addr_o
);

    assign release_valid_o = valid_i && clear_i;
    assign release_uses_rs1_o = release_valid_o && (rs1_addr_i != `RV64_REG_X0);
    assign release_uses_rs2_o = release_valid_o && (rs2_addr_i != `RV64_REG_X0);
    assign release_rs1_addr_o = rs1_addr_i;
    assign release_rs2_addr_o = rs2_addr_i;
    assign release_reg_write_o = release_valid_o &&
                                 reg_write_i &&
                                 (rd_addr_i != `RV64_REG_X0);
    assign release_rd_addr_o = rd_addr_i;

endmodule
