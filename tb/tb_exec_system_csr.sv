`timescale 1ns/1ps
`include "core/exec/system/csr.v"
`timescale 1ns/1ps

module tb_exec_system_csr;

    logic valid;
    logic [`RV64_FUNCT3_WIDTH-1:0] funct3;
    logic [`RV64_FUNCT12_WIDTH-1:0] csr_addr;
    logic [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr;
    logic [`RV64_XLEN-1:0] rs1_data;
    logic [`RV64_REG_ADDR_WIDTH-1:0] zimm;
    logic [`RV64_XLEN-1:0] csr_rdata;
    logic csr_valid;
    logic csr_writable;
    logic ready;
    logic illegal;
    logic csr_write;
    logic [`RV64_FUNCT12_WIDTH-1:0] csr_addr_out;
    logic [`RV64_XLEN-1:0] csr_wdata;
    logic [`RV64_XLEN-1:0] rd_data;

    openrv64_exec_system_csr dut (
        .valid_i(valid),
        .funct3_i(funct3),
        .csr_addr_i(csr_addr),
        .rs1_addr_i(rs1_addr),
        .rs1_data_i(rs1_data),
        .zimm_i(zimm),
        .csr_rdata_i(csr_rdata),
        .csr_valid_i(csr_valid),
        .csr_writable_i(csr_writable),
        .ready_o(ready),
        .illegal_o(illegal),
        .csr_write_o(csr_write),
        .csr_addr_o(csr_addr_out),
        .csr_wdata_o(csr_wdata),
        .rd_data_o(rd_data)
    );

    task automatic check;
        input exp_illegal;
        input exp_write;
        input [`RV64_FUNCT12_WIDTH-1:0] exp_addr;
        input [`RV64_XLEN-1:0] exp_wdata;
        input [`RV64_XLEN-1:0] exp_rd_data;
        input [8*40-1:0] label;
        begin
            #1;

            if (!ready ||
                illegal !== exp_illegal ||
                csr_write !== exp_write ||
                csr_addr_out !== exp_addr ||
                csr_wdata !== exp_wdata ||
                rd_data !== exp_rd_data) begin
                $fatal(1,
                    "%0s: ready=%0b illegal=%0b/%0b write=%0b/%0b addr=%03x/%03x wdata=%016x/%016x rd=%016x/%016x",
                    label, ready, illegal, exp_illegal, csr_write, exp_write,
                    csr_addr_out, exp_addr, csr_wdata, exp_wdata,
                    rd_data, exp_rd_data);
            end
        end
    endtask

    initial begin
        valid = 1'b0;
        funct3 = `RV64_ZICSR_FUNCT3_CSRRW;
        csr_addr = 12'h300;
        rs1_addr = 5'd4;
        rs1_data = 64'h00ff_00ff_00ff_00ff;
        zimm = 5'd5;
        csr_rdata = 64'h1234_5678_9abc_def0;
        csr_valid = 1'b1;
        csr_writable = 1'b1;
        check(1'b0, 1'b0, 12'h000, 64'h0, 64'h0, "inactive");

        valid = 1'b1;
        check(1'b0, 1'b1, 12'h300, rs1_data, csr_rdata, "csrrw");

        funct3 = `RV64_ZICSR_FUNCT3_CSRRS;
        rs1_addr = `RV64_REG_X0;
        csr_writable = 1'b0;
        check(1'b0, 1'b0, 12'h300, 64'h0, csr_rdata,
              "csrrs read-only read");

        rs1_addr = 5'd4;
        check(1'b1, 1'b0, 12'h300, 64'h0, csr_rdata,
              "csrrs read-only write");

        csr_writable = 1'b1;
        funct3 = `RV64_ZICSR_FUNCT3_CSRRC;
        check(1'b0, 1'b1, 12'h300, rs1_data, csr_rdata,
              "csrrc");

        rs1_addr = `RV64_REG_X0;
        csr_writable = 1'b0;
        check(1'b0, 1'b0, 12'h300, 64'h0, csr_rdata,
              "csrrc read-only read");
        rs1_addr = 5'd4;
        csr_writable = 1'b1;

        funct3 = `RV64_ZICSR_FUNCT3_CSRRWI;
        check(1'b0, 1'b1, 12'h300, 64'd5, csr_rdata, "csrrwi");

        funct3 = `RV64_ZICSR_FUNCT3_CSRRSI;
        zimm = 5'd0;
        csr_writable = 1'b0;
        check(1'b0, 1'b0, 12'h300, 64'h0, csr_rdata,
              "csrrsi zero read-only read");

        zimm = 5'd7;
        csr_writable = 1'b1;
        check(1'b0, 1'b1, 12'h300, 64'd7, csr_rdata,
              "csrrsi raw operand");

        funct3 = `RV64_ZICSR_FUNCT3_CSRRCI;
        zimm = 5'd0;
        csr_writable = 1'b0;
        check(1'b0, 1'b0, 12'h300, 64'h0, csr_rdata,
              "csrrci zero read-only read");

        zimm = 5'd7;
        csr_writable = 1'b1;
        check(1'b0, 1'b1, 12'h300, 64'd7, csr_rdata,
              "csrrci raw operand");

        csr_valid = 1'b0;
        check(1'b1, 1'b0, 12'h300, 64'h0, 64'h0, "unimplemented csr");

        csr_valid = 1'b1;
        funct3 = `RV64_FUNCT3_SYSTEM_PRIV;
        check(1'b1, 1'b0, 12'h300, 64'h0, 64'h0, "invalid csr funct3");

        $display("PASS: system CSR execution semantics");
        $finish;
    end

endmodule
