`timescale 1ns/1ps

module tb_rv64i_vec;

    localparam integer VLEN = 256;
    localparam integer SLICE_WIDTH = 64;
    localparam integer SLICE_ADDR_WIDTH = 2;
    localparam integer REG_ADDR_WIDTH = 5;

    reg clk;
    reg rst_n;
    reg [3:0] read_valid;
    wire [3:0] read_ready;
    reg [4*REG_ADDR_WIDTH-1:0] read_addr;
    reg [4*SLICE_ADDR_WIDTH-1:0] read_slice;
    wire [4*SLICE_WIDTH-1:0] read_data;
    reg [1:0] write_valid;
    wire [1:0] write_ready;
    reg [2*REG_ADDR_WIDTH-1:0] write_addr;
    reg [2*SLICE_ADDR_WIDTH-1:0] write_slice;
    reg [2*SLICE_WIDTH-1:0] write_data;

    openrv64_rv64i_vec #(
        .VLEN(VLEN), .SLICE_WIDTH(SLICE_WIDTH),
        .REG_ADDR_WIDTH(REG_ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .read_valid_i(read_valid), .read_ready_o(read_ready),
        .read_addr_i(read_addr), .read_slice_i(read_slice),
        .read_data_o(read_data),
        .write_valid_i(write_valid), .write_ready_o(write_ready),
        .write_addr_i(write_addr), .write_slice_i(write_slice),
        .write_data_i(write_data)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst_n = 1'b0;
        read_valid = 4'b0000;
        read_addr = 20'd0;
        read_slice = 8'd0;
        write_valid = 2'b00;
        write_addr = 10'd0;
        write_slice = 4'd0;
        write_data = 128'd0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // One write per parity bank can commit together and bypass reads.
        write_valid = 2'b11;
        write_addr = {5'd3, 5'd2};
        write_slice = {2'd1, 2'd1};
        write_data = {64'h3333_3333_3333_3333,
                      64'h2222_2222_2222_2222};
        read_valid = 4'b0011;
        read_addr = {5'd0, 5'd0, 5'd3, 5'd2};
        read_slice = {2'd0, 2'd0, 2'd1, 2'd1};
        #1;
        if (write_ready !== 2'b11 || read_ready[1:0] !== 2'b11 ||
            read_data[0*SLICE_WIDTH +: SLICE_WIDTH] !==
                64'h2222_2222_2222_2222 ||
            read_data[1*SLICE_WIDTH +: SLICE_WIDTH] !==
                64'h3333_3333_3333_3333)
            $fatal(1, "banked dual-write bypass failed");
        @(posedge clk);
        @(negedge clk);
        write_valid = 2'b00;

        // Same-parity writes collide even when the rows differ.
        write_valid = 2'b11;
        write_addr = {5'd4, 5'd2};
        write_slice = {2'd0, 2'd0};
        write_data = {64'h4444_4444_4444_4444,
                      64'haaaa_aaaa_aaaa_aaaa};
        #1;
        if (write_ready !== 2'b01)
            $fatal(1, "same-bank write was not backpressured");
        @(posedge clk);
        @(negedge clk);
        write_valid = 2'b00;

        // Each parity bank has two physical read slots.  A third even-bank
        // request stalls while an odd-bank request remains independent.
        read_valid = 4'b1111;
        read_addr = {5'd3, 5'd6, 5'd4, 5'd2};
        read_slice = {2'd1, 2'd0, 2'd0, 2'd0};
        #1;
        if (read_ready !== 4'b1011)
            $fatal(1, "read-bank arbitration wrong: ready=%b", read_ready);
        if (read_data[0*SLICE_WIDTH +: SLICE_WIDTH] !==
                64'haaaa_aaaa_aaaa_aaaa ||
            read_data[3*SLICE_WIDTH +: SLICE_WIDTH] !==
                64'h3333_3333_3333_3333)
            $fatal(1, "banked slice data mismatch");

        $display("PASS: even/odd 64-bit-slice vector register banks");
        $finish;
    end

endmodule
