`timescale 1ns/1ps
`include "core/exec/fpu/fpr.v"
`timescale 1ns/1ps

module tb_rv64fd_fpr;

    localparam integer FLEN = 64;

    reg clk;
    reg rst_n;
    reg [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr;
    wire [FLEN-1:0] rs1_data;
    reg [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr;
    wire [FLEN-1:0] rs2_data;
    reg [`RV64_REG_ADDR_WIDTH-1:0] rs3_addr;
    wire [FLEN-1:0] rs3_data;
    reg rd_write;
    reg [`RV64_REG_ADDR_WIDTH-1:0] rd_addr;
    reg [FLEN-1:0] rd_data;

    openrv64_rv64fd_fpr #(
        .FLEN(FLEN)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .rs1_addr_i(rs1_addr),
        .rs1_data_o(rs1_data),
        .rs2_addr_i(rs2_addr),
        .rs2_data_o(rs2_data),
        .rs3_addr_i(rs3_addr),
        .rs3_data_o(rs3_data),
        .rd_write_i(rd_write),
        .rd_addr_i(rd_addr),
        .rd_data_i(rd_data)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic expect_reads;
        input [FLEN-1:0] expected1;
        input [FLEN-1:0] expected2;
        input [FLEN-1:0] expected3;
        input [8*48-1:0] label;
        begin
            #1;
            if ((rs1_data !== expected1) ||
                (rs2_data !== expected2) ||
                (rs3_data !== expected3)) begin
                $fatal(1,
                    "%0s: rs1=%016x/%016x rs2=%016x/%016x rs3=%016x/%016x",
                    label, rs1_data, expected1, rs2_data, expected2,
                    rs3_data, expected3);
            end
        end
    endtask

    task automatic write_reg;
        input [`RV64_REG_ADDR_WIDTH-1:0] address;
        input [FLEN-1:0] value;
        begin
            @(negedge clk);
            rd_write = 1'b1;
            rd_addr = address;
            rd_data = value;
            @(posedge clk);
            @(negedge clk);
            rd_write = 1'b0;
            rd_addr = {`RV64_REG_ADDR_WIDTH{1'b0}};
            rd_data = {FLEN{1'b0}};
        end
    endtask

    initial begin
        rst_n = 1'b0;
        rs1_addr = 5'd0;
        rs2_addr = 5'd1;
        rs3_addr = 5'd31;
        rd_write = 1'b0;
        rd_addr = 5'd0;
        rd_data = 64'd0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        expect_reads(64'd0, 64'd0, 64'd0, "reset");

        // f0 is ordinary architectural state, not a hardwired zero.
        write_reg(5'd0, 64'h3ff0_0000_0000_0000);
        rs1_addr = 5'd0;
        expect_reads(64'h3ff0_0000_0000_0000, 64'd0, 64'd0,
                     "writable f0");

        // Preserve both NaN-boxed binary32 values and arbitrary binary64
        // payloads exactly as supplied by writeback.
        write_reg(5'd1, 64'hffff_ffff_3fc0_0000);
        write_reg(5'd2, 64'h4002_0000_0000_0000);
        write_reg(5'd31, 64'h7ff8_0000_0000_1234);
        rs1_addr = 5'd1;
        rs2_addr = 5'd2;
        rs3_addr = 5'd31;
        expect_reads(64'hffff_ffff_3fc0_0000,
                     64'h4002_0000_0000_0000,
                     64'h7ff8_0000_0000_1234,
                     "three architectural sources");

        // Ordered writeback may forward to any of the three source selectors
        // in the acceptance cycle.
        @(negedge clk);
        rs1_addr = 5'd7;
        rs2_addr = 5'd7;
        rs3_addr = 5'd7;
        rd_write = 1'b1;
        rd_addr = 5'd7;
        rd_data = 64'hc008_0000_0000_0000;
        expect_reads(64'hc008_0000_0000_0000,
                     64'hc008_0000_0000_0000,
                     64'hc008_0000_0000_0000,
                     "three-port write bypass");
        @(posedge clk);
        @(negedge clk);
        rd_write = 1'b0;
        expect_reads(64'hc008_0000_0000_0000,
                     64'hc008_0000_0000_0000,
                     64'hc008_0000_0000_0000,
                     "committed writeback");

        if ((dut.regs[0] !== 64'h3ff0_0000_0000_0000) ||
            (dut.regs[31] !== 64'h7ff8_0000_0000_1234))
            $fatal(1, "FPR hierarchy compatibility view is wrong");

        $display("PASS: architectural three-read one-write RV64F/D FPR");
        $finish;
    end

endmodule
