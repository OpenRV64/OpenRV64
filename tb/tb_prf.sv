`timescale 1ns/1ps

module tb_prf;

    localparam integer DATA_WIDTH = 32;
    localparam integer NUM_REGS = 70;
    localparam integer REG_ADDR_WIDTH = 7;
    localparam integer NUM_SLICES = 2;
    localparam integer SLICE_ADDR_WIDTH = 1;

    reg clk;
    reg rst_n;
    reg [3:0] read_valid;
    wire [3:0] read_ready;
    reg [4*REG_ADDR_WIDTH-1:0] read_addr;
    reg [4*SLICE_ADDR_WIDTH-1:0] read_slice;
    wire [4*DATA_WIDTH-1:0] read_data;
    reg [1:0] write_valid;
    wire [1:0] write_ready;
    reg [2*REG_ADDR_WIDTH-1:0] write_addr;
    reg [2*SLICE_ADDR_WIDTH-1:0] write_slice;
    reg [2*DATA_WIDTH-1:0] write_data;
    wire [NUM_REGS*NUM_SLICES*DATA_WIDTH-1:0] debug_regs;

    openrv64_prf #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_REGS(NUM_REGS),
        .REG_ADDR_WIDTH(REG_ADDR_WIDTH),
        .NUM_SLICES(NUM_SLICES),
        .SLICE_ADDR_WIDTH(SLICE_ADDR_WIDTH),
        .NUM_BANKS(2),
        .READ_PORTS(4),
        .WRITE_PORTS(2),
        .READ_PORTS_PER_BANK(2),
        .WRITE_PORTS_PER_BANK(1),
        .ZERO_REG_ENABLE(0)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .read_valid_i(read_valid),
        .read_ready_o(read_ready),
        .read_addr_i(read_addr),
        .read_slice_i(read_slice),
        .read_data_o(read_data),
        .write_valid_i(write_valid),
        .write_ready_o(write_ready),
        .write_addr_i(write_addr),
        .write_slice_i(write_slice),
        .write_data_i(write_data),
        .debug_regs_o(debug_regs)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst_n = 1'b0;
        read_valid = 4'b0000;
        read_addr = {4*REG_ADDR_WIDTH{1'b0}};
        read_slice = {4*SLICE_ADDR_WIDTH{1'b0}};
        write_valid = 2'b00;
        write_addr = {2*REG_ADDR_WIDTH{1'b0}};
        write_slice = {2*SLICE_ADDR_WIDTH{1'b0}};
        write_data = {2*DATA_WIDTH{1'b0}};

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Exercise physical tags above 63, distinct slices, both banks, and
        // same-cycle write-to-read forwarding.
        write_valid = 2'b11;
        write_addr = {7'd69, 7'd68};
        write_slice = {1'b1, 1'b0};
        write_data = {32'h6969_0001, 32'h6868_0000};
        read_valid = 4'b0011;
        read_addr = {7'd0, 7'd0, 7'd69, 7'd68};
        read_slice = {1'b0, 1'b0, 1'b1, 1'b0};
        #1;
        if (write_ready !== 2'b11 ||
            read_data[0*DATA_WIDTH +: DATA_WIDTH] !== 32'h6868_0000 ||
            read_data[1*DATA_WIDTH +: DATA_WIDTH] !== 32'h6969_0001)
            $fatal(1, "multi-bank high-tag bypass failed");
        @(posedge clk);
        @(negedge clk);
        write_valid = 2'b00;
        #1;
        if (read_data[0*DATA_WIDTH +: DATA_WIDTH] !== 32'h6868_0000 ||
            read_data[1*DATA_WIDTH +: DATA_WIDTH] !== 32'h6969_0001)
            $fatal(1, "multi-bank high-tag write did not persist");
        if (debug_regs[(69*NUM_SLICES + 1)*DATA_WIDTH +: DATA_WIDTH] !==
            32'h6969_0001)
            $fatal(1, "flattened debug register mapping is wrong");

        // With one physical write slot per bank, the later even-bank write is
        // backpressured and must not modify its row.
        write_valid = 2'b11;
        write_addr = {7'd66, 7'd64};
        write_slice = 2'b00;
        write_data = {32'h6666_0000, 32'h6464_0000};
        #1;
        if (write_ready !== 2'b01)
            $fatal(1, "same-bank write arbitration is wrong: %b",
                   write_ready);
        @(posedge clk);
        @(negedge clk);
        write_valid = 2'b00;
        read_valid = 4'b0011;
        read_addr = {7'd0, 7'd0, 7'd66, 7'd64};
        read_slice = 4'b0000;
        #1;
        if (read_data[0*DATA_WIDTH +: DATA_WIDTH] !== 32'h6464_0000 ||
            read_data[1*DATA_WIDTH +: DATA_WIDTH] !== 32'h0000_0000)
            $fatal(1, "backpressured write modified storage");

        // A bank admits at most two reads; an independent bank retains its
        // own capacity.
        read_valid = 4'b1111;
        read_addr = {7'd2, 7'd68, 7'd66, 7'd64};
        #1;
        if (read_ready !== 4'b0011)
            $fatal(1, "same-bank read arbitration is wrong: %b",
                   read_ready);
        read_addr = {7'd67, 7'd69, 7'd66, 7'd64};
        #1;
        if (read_ready !== 4'b1111)
            $fatal(1, "independent read banks interfered: %b",
                   read_ready);

        // Slices of the same physical tag remain independent.
        write_valid = 2'b01;
        write_addr = {7'd0, 7'd68};
        write_slice = 2'b01;
        write_data = {32'd0, 32'h6868_0001};
        @(posedge clk);
        @(negedge clk);
        write_valid = 2'b00;
        read_valid = 4'b0011;
        read_addr = {7'd0, 7'd0, 7'd68, 7'd68};
        read_slice = 4'b0010;
        #1;
        if (read_data[0*DATA_WIDTH +: DATA_WIDTH] !== 32'h6868_0000 ||
            read_data[1*DATA_WIDTH +: DATA_WIDTH] !== 32'h6868_0001)
            $fatal(1, "independent slice storage failed");

        $display("PASS: parameterized banked and sliced PRF");
        $finish;
    end

endmodule
