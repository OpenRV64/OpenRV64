`timescale 1ns/1ps
`include "core/regs/rv64-i-gpr.v"
`timescale 1ns/1ps

module tb_rv64i_gpr;

    logic                             clk;
    logic                             rst_n;
    logic [`RV64_REG_ADDR_WIDTH-1:0]  rs1_addr;
    logic [`RV64_XLEN-1:0]            rs1_data;
    logic [`RV64_REG_ADDR_WIDTH-1:0]  rs2_addr;
    logic [`RV64_XLEN-1:0]            rs2_data;
    logic                             rd_write;
    logic [`RV64_REG_ADDR_WIDTH-1:0]  rd_addr;
    logic [`RV64_XLEN-1:0]            rd_data;

    openrv64_rv64i_gpr dut (
        .clk(clk),
        .rst_n(rst_n),
        .rs1_addr_i(rs1_addr),
        .rs1_data_o(rs1_data),
        .rs2_addr_i(rs2_addr),
        .rs2_data_o(rs2_data),
        .rd_write_i(rd_write),
        .rd_addr_i(rd_addr),
        .rd_data_i(rd_data)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic expect_reads;
        input [`RV64_XLEN-1:0] exp_rs1;
        input [`RV64_XLEN-1:0] exp_rs2;
        input [8*32-1:0] label;
        begin
            #1;
            if (rs1_data !== exp_rs1 || rs2_data !== exp_rs2) begin
                $fatal(1,
                    "%0s: rs1=%016x expected=%016x rs2=%016x expected=%016x",
                    label, rs1_data, exp_rs1, rs2_data, exp_rs2);
            end
        end
    endtask

    task automatic write_reg;
        input [`RV64_REG_ADDR_WIDTH-1:0] addr;
        input [`RV64_XLEN-1:0] data;
        begin
            @(negedge clk);
            rd_write = 1'b1;
            rd_addr = addr;
            rd_data = data;
            @(posedge clk);
            @(negedge clk);
            rd_write = 1'b0;
            rd_addr = `RV64_REG_X0;
            rd_data = {`RV64_XLEN{1'b0}};
        end
    endtask

    initial begin
        rst_n = 1'b0;
        rs1_addr = `RV64_REG_X0;
        rs2_addr = `RV64_REG_X0;
        rd_write = 1'b0;
        rd_addr = `RV64_REG_X0;
        rd_data = {`RV64_XLEN{1'b0}};

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        rs1_addr = `RV64_REG_X0;
        rs2_addr = `RV64_REG_X5;
        expect_reads(64'h0000_0000_0000_0000,
                     64'h0000_0000_0000_0000,
                     "reset and x0 read");

        write_reg(`RV64_REG_X5, 64'h0123_4567_89ab_cdef);
        rs1_addr = `RV64_REG_X5;
        rs2_addr = `RV64_REG_X0;
        expect_reads(64'h0123_4567_89ab_cdef,
                     64'h0000_0000_0000_0000,
                     "write x5 and read x0");

        write_reg(`RV64_REG_X0, 64'hffff_ffff_ffff_ffff);
        rs1_addr = `RV64_REG_X0;
        rs2_addr = `RV64_REG_X5;
        expect_reads(64'h0000_0000_0000_0000,
                     64'h0123_4567_89ab_cdef,
                     "ignore x0 write");

        @(negedge clk);
        rs1_addr = `RV64_REG_X6;
        rs2_addr = `RV64_REG_X5;
        rd_write = 1'b1;
        rd_addr = `RV64_REG_X6;
        rd_data = 64'hfedc_ba98_7654_3210;
        expect_reads(64'hfedc_ba98_7654_3210,
                     64'h0123_4567_89ab_cdef,
                     "same-cycle bypass");

        @(posedge clk);
        @(negedge clk);
        rd_write = 1'b0;
        rd_addr = `RV64_REG_X0;
        rd_data = {`RV64_XLEN{1'b0}};
        rs1_addr = `RV64_REG_X6;
        rs2_addr = `RV64_REG_X5;
        expect_reads(64'hfedc_ba98_7654_3210,
                     64'h0123_4567_89ab_cdef,
                     "committed bypass write");

        $display("PASS: RV64I GPR register file");
        $finish;
    end

endmodule
