`timescale 1ns/1ps

module tb_soc_memory;

    localparam integer MEM_BYTES = 16 * 1024 * 1024;

    logic        clk;
    logic        rst_n;
    logic        mem_valid;
    logic        mem_ready;
    logic        mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0]  mem_wstrb;
    logic [63:0] mem_rdata;

    openrv64_soc_memory #(
        .MEM_BYTES(MEM_BYTES)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .mem_valid_i(mem_valid),
        .mem_ready_o(mem_ready),
        .mem_write_i(mem_write),
        .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata),
        .mem_wstrb_i(mem_wstrb),
        .mem_rdata_o(mem_rdata)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic bus_write;
        input logic [63:0] address;
        input logic [63:0] data;
        input logic [7:0] strobe;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b1;
            mem_addr = address;
            mem_wdata = data;
            mem_wstrb = strobe;
            #1;
            if (mem_ready) begin
                $fatal(1, "memory write completed combinationally at %016x",
                       address);
            end
            @(posedge clk);
            @(negedge clk);
            #1;
            if (!mem_ready || mem_rdata !== 64'h0) begin
                $fatal(1, "memory write response invalid at %016x", address);
            end
            @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
            mem_write = 1'b0;
            mem_addr = 64'h0;
            mem_wdata = 64'h0;
            mem_wstrb = 8'h00;
        end
    endtask

    task automatic expect_read;
        input logic [63:0] address;
        input logic [63:0] expected;
        input [8*56-1:0] label;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b0;
            mem_addr = address;
            #1;
            if (mem_ready) begin
                $fatal(1, "%0s: read completed combinationally", label);
            end
            @(posedge clk);
            @(negedge clk);
            #1;
            if (!mem_ready || mem_rdata !== expected) begin
                $fatal(1, "%0s: read %016x, expected %016x",
                       label, mem_rdata, expected);
            end
            @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
            mem_addr = 64'h0;
        end
    endtask

    initial begin
        mem_valid = 1'b0;
        rst_n = 1'b0;
        mem_write = 1'b0;
        mem_addr = 64'h0;
        mem_wdata = 64'h0;
        mem_wstrb = 8'h00;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;
        if (mem_ready || mem_rdata !== 64'h0) begin
            $fatal(1, "idle memory produced a response");
        end

        expect_read(64'h0000, 64'h0, "zero-initialized first word");
        expect_read(MEM_BYTES - 8, 64'h0,
                    "zero-initialized final word");

        bus_write(64'h0000, 64'h0123_4567_89ab_cdef, 8'hff);
        expect_read(64'h0000, 64'h0123_4567_89ab_cdef,
                    "full-width write");

        bus_write(64'h0008, 64'h1122_3344_5566_7788, 8'ha5);
        expect_read(64'h0008, 64'h1100_3300_0066_0088,
                    "byte-strobe write");

        // Low address bits select the containing 64-bit word. Lane placement
        // remains encoded in wdata/wstrb by the requester.
        expect_read(64'h000b, 64'h1100_3300_0066_0088,
                    "unaligned address selects aligned word");

        bus_write(MEM_BYTES - 8, 64'hfeed_face_cafe_beef, 8'hff);
        expect_read(MEM_BYTES - 8, 64'hfeed_face_cafe_beef,
                    "final word write");

        // Out-of-range local requests should never be issued by the decoder;
        // the RAM nevertheless returns zero and ignores writes defensively.
        bus_write(MEM_BYTES, 64'hffff_ffff_ffff_ffff, 8'hff);
        expect_read(MEM_BYTES, 64'h0, "out-of-range local request");

        $display("tb_soc_memory: PASS");
        $finish;
    end

endmodule
