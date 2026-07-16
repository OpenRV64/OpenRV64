`timescale 1ns/1ps
`include "core/exec/system/csr.v"
`timescale 1ns/1ps

module tb_exec_system_csr;

    logic valid;
    logic [`RV64_FUNCT3_WIDTH-1:0] funct3;
    logic [`RV64_FUNCT12_WIDTH-1:0] csr_addr;
    logic [`RV64_XLEN-1:0] rs1_data;
    logic [`RV64_REG_ADDR_WIDTH-1:0] zimm;
    logic [`RV64_XLEN-1:0] csr_rdata;
    logic ready;
    logic illegal;
    logic csr_read;
    logic csr_write;
    logic [`RV64_FUNCT12_WIDTH-1:0] csr_addr_out;
    logic [`RV64_XLEN-1:0] csr_wdata;
    logic [`RV64_XLEN-1:0] rd_data;

    openrv64_exec_system_csr dut (
        .valid_i(valid),
        .funct3_i(funct3),
        .csr_addr_i(csr_addr),
        .rs1_data_i(rs1_data),
        .zimm_i(zimm),
        .csr_rdata_i(csr_rdata),
        .ready_o(ready),
        .illegal_o(illegal),
        .csr_read_o(csr_read),
        .csr_write_o(csr_write),
        .csr_addr_o(csr_addr_out),
        .csr_wdata_o(csr_wdata),
        .rd_data_o(rd_data)
    );

    initial begin
        valid = 1'b0;
        funct3 = 3'b001;
        csr_addr = 12'h300;
        rs1_data = 64'hffff_ffff_ffff_ffff;
        zimm = 5'd31;
        csr_rdata = 64'h1234;
        #1;

        if (!ready || illegal || csr_read || csr_write || csr_addr_out != 12'h000 ||
            csr_wdata != 64'h0 || rd_data != 64'h0) begin
            $fatal(1, "inactive CSR stub mismatch");
        end

        valid = 1'b1;
        #1;

        if (!ready || !illegal || csr_read || csr_write || csr_addr_out != 12'h000 ||
            csr_wdata != 64'h0 || rd_data != 64'h0) begin
            $fatal(1, "active CSR stub mismatch");
        end

        $display("PASS: system CSR stub");
        $finish;
    end

endmodule
