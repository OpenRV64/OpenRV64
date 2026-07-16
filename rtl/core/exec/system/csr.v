`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

module openrv64_exec_system_csr (
    input  wire                         valid_i,
    input  wire [`RV64_FUNCT3_WIDTH-1:0] funct3_i,
    input  wire [`RV64_FUNCT12_WIDTH-1:0] csr_addr_i,
    input  wire [`RV64_XLEN-1:0]        rs1_data_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] zimm_i,
    input  wire [`RV64_XLEN-1:0]        csr_rdata_i,

    output wire                         ready_o,
    output wire                         illegal_o,
    output wire                         csr_read_o,
    output wire                         csr_write_o,
    output wire [`RV64_FUNCT12_WIDTH-1:0] csr_addr_o,
    output wire [`RV64_XLEN-1:0]        csr_wdata_o,
    output wire [`RV64_XLEN-1:0]        rd_data_o
);

    wire unused_inputs = |{funct3_i, csr_addr_i, rs1_data_i, zimm_i, csr_rdata_i};

    assign ready_o     = 1'b1;
    assign illegal_o   = valid_i;
    assign csr_read_o  = 1'b0;
    assign csr_write_o = 1'b0;
    assign csr_addr_o  = {`RV64_FUNCT12_WIDTH{1'b0}};
    assign csr_wdata_o = {`RV64_XLEN{1'b0}};
    assign rd_data_o   = {`RV64_XLEN{1'b0}};

endmodule
