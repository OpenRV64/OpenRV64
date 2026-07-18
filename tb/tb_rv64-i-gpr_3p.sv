`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

module tb_rv64i_gpr_3p;

    reg clk;
    reg rst_n;
    reg [6*`RV64_REG_ADDR_WIDTH-1:0] read_addr;
    wire [6*`RV64_XLEN-1:0] read_data;
    reg [2:0] write_valid;
    reg [3*`RV64_REG_ADDR_WIDTH-1:0] write_addr;
    reg [3*`RV64_XLEN-1:0] write_data;

    openrv64_rv64i_gpr_3p dut (
        .clk(clk),
        .rst_n(rst_n),
        .read_addr_i(read_addr),
        .read_data_o(read_data),
        .write_valid_i(write_valid),
        .write_addr_i(write_addr),
        .write_data_i(write_data)
    );

    always #5 clk = ~clk;

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic fail;
        input [8*96-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        read_addr = {6*`RV64_REG_ADDR_WIDTH{1'b0}};
        write_valid = 3'b000;
        write_addr = {3*`RV64_REG_ADDR_WIDTH{1'b0}};
        write_data = {3*`RV64_XLEN{1'b0}};

        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        write_valid = 3'b111;
        write_addr = {5'd9, 5'd7, 5'd5};
        write_data = {64'h99, 64'h77, 64'h55};
        read_addr = {5'd9, 5'd7, 5'd5, 5'd9, 5'd7, 5'd5};
        #1;
        if ((read_data[0*64 +: 64] != 64'h55) ||
            (read_data[1*64 +: 64] != 64'h77) ||
            (read_data[2*64 +: 64] != 64'h99) ||
            (read_data[3*64 +: 64] != 64'h55) ||
            (read_data[4*64 +: 64] != 64'h77) ||
            (read_data[5*64 +: 64] != 64'h99)) begin
            fail("three-write bypass did not feed all six selectors");
        end
        tick();

        write_valid = 3'b000;
        #1;
        if ((read_data[0*64 +: 64] != 64'h55) ||
            (read_data[1*64 +: 64] != 64'h77) ||
            (read_data[2*64 +: 64] != 64'h99)) begin
            fail("three retirement writes were not stored");
        end

        read_addr[0*5 +: 5] = 5'd0;
        #1;
        if (read_data[0*64 +: 64] != 64'd0)
            fail("x0 did not remain zero");

        $display("PASS: six-read three-write GPR bank");
        $finish;
    end

endmodule
