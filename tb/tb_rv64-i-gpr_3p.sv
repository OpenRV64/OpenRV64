`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

module tb_rv64i_gpr_3p #(
    parameter integer ALLOW_DUPLICATE_WRITES = 0
);

    reg clk;
    reg rst_n;
    reg [6*`RV64_REG_ADDR_WIDTH-1:0] read_addr;
    wire [6*`RV64_XLEN-1:0] read_data;
    reg [2:0] write_valid;
    reg [3*`RV64_REG_ADDR_WIDTH-1:0] write_addr;
    reg [3*`RV64_XLEN-1:0] write_data;

    openrv64_rv64i_gpr_3p #(
        .ALLOW_DUPLICATE_WRITES(ALLOW_DUPLICATE_WRITES)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .read_req_i(6'b000000),
        .read_addr_i(read_addr),
        .read_data_o(read_data),
        .read_valid_o(),
        .write_valid_i(write_valid),
        .write_addr_i(write_addr),
        .write_data_i(write_data),
        .write_ready_o(),
        .quiescent_o()
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

        // p31 is the final stored default entry. p0 is not stored.
        write_valid = 3'b001;
        write_addr = {5'd0, 5'd0, 5'd31};
        write_data = {64'd0, 64'd0, 64'h3131};
        read_addr = {5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd31};
        #1;
        if ((read_data[0*64 +: 64] != 64'h3131) ||
            (read_data[1*64 +: 64] != 64'd0)) begin
            fail("compact p31 bypass or unstored p0 failed");
        end
        tick();
        write_valid = 3'b000;
        #1;
        if ((read_data[0*64 +: 64] != 64'h3131) ||
            (dut.regs[31] != 64'h3131)) begin
            fail("p31 did not map to final writable PRF entry");
        end

        // Suppressed x0 writes are not duplicate physical destinations.
        write_valid = 3'b111;
        write_addr = {5'd0, 5'd0, 5'd0};
        write_data = {64'h30, 64'h20, 64'h10};
        tick();
        write_valid = 3'b000;

        if (ALLOW_DUPLICATE_WRITES != 0) begin
            write_valid = 3'b111;
            write_addr = {5'd10, 5'd10, 5'd10};
            write_data = {64'h30, 64'h20, 64'h10};
            read_addr = {5'd10, 5'd10, 5'd10,
                         5'd10, 5'd10, 5'd10};
            #1;
            if (read_data[0*64 +: 64] != 64'h30)
                fail("duplicate-write bypass did not select youngest lane");
            tick();
            write_valid = 3'b000;
            #1;
            if (read_data[0*64 +: 64] != 64'h30)
                fail("duplicate retirement writes did not commit in order");
        end

        read_addr[0*5 +: 5] = 5'd0;
        #1;
        if (read_data[0*64 +: 64] != 64'd0)
            fail("x0 did not remain zero");

        $display("PASS: six-read three-write GPR bank");
        $finish;
    end

endmodule
