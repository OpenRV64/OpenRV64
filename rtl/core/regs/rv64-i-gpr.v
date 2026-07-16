`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

module openrv64_rv64i_gpr #(
    parameter RESET_REGS = 1,
    parameter READ_WRITE_BYPASS = 1
) (
    input  wire                             clk,
    input  wire                             rst_n,

    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr_i,
    output wire [`RV64_XLEN-1:0]           rs1_data_o,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr_i,
    output wire [`RV64_XLEN-1:0]           rs2_data_o,

    input  wire                             rd_write_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr_i,
    input  wire [`RV64_XLEN-1:0]           rd_data_i
);

    reg [`RV64_XLEN-1:0] regs [1:31];

    wire rd_writes_gpr = rd_write_i && (rd_addr_i != `RV64_REG_X0);

    wire rs1_reads_x0 = (rs1_addr_i == `RV64_REG_X0);
    wire rs2_reads_x0 = (rs2_addr_i == `RV64_REG_X0);

    wire rs1_bypass = READ_WRITE_BYPASS &&
                      rd_writes_gpr &&
                      (rs1_addr_i == rd_addr_i);
    wire rs2_bypass = READ_WRITE_BYPASS &&
                      rd_writes_gpr &&
                      (rs2_addr_i == rd_addr_i);

    assign rs1_data_o = rs1_reads_x0 ? {`RV64_XLEN{1'b0}} :
                        rs1_bypass ? rd_data_i :
                        regs[rs1_addr_i];
    assign rs2_data_o = rs2_reads_x0 ? {`RV64_XLEN{1'b0}} :
                        rs2_bypass ? rd_data_i :
                        regs[rs2_addr_i];

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if (RESET_REGS) begin
                for (i = 1; i < 32; i = i + 1) begin
                    regs[i] <= {`RV64_XLEN{1'b0}};
                end
            end
        end else if (rd_writes_gpr) begin
            regs[rd_addr_i] <= rd_data_i;
        end
    end

endmodule
