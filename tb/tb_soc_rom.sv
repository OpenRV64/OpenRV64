`timescale 1ns/1ps

module tb_soc_rom;

    localparam integer ROM_BYTES = 4 * 1024;

    logic        clk;
    logic        rst_n;
    logic        mem_valid;
    logic        mem_ready;
    logic        mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0]  mem_wstrb;
    logic [63:0] mem_rdata;

    openrv64_soc_rom #(
        .ROM_BYTES(ROM_BYTES)
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

    task automatic expect_read;
        input logic [63:0] address;
        input logic [63:0] expected;
        input [8*56-1:0] label;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b0;
            mem_addr = address;

            @(posedge clk);
            #1;
            if (mem_ready || mem_rdata !== 64'h0)
                $fatal(1, "%0s: ROM responded in request cycle", label);

            @(posedge clk);
            #1;
            if (!mem_ready || mem_rdata !== expected) begin
                $fatal(1, "%0s: read %016x, expected %016x",
                       label, mem_rdata, expected);
            end

            // The response is consumed on this edge.  The following recovery
            // cycle deliberately prevents an immediate new acceptance.
            @(posedge clk);
            #1;
            if (mem_ready || mem_rdata !== 64'h0)
                $fatal(1, "%0s: response lasted more than one cycle", label);
            mem_valid = 1'b0;
            @(posedge clk);
            #1;
            if (mem_ready)
                $fatal(1, "%0s: ROM responded during recovery", label);
        end
    endtask

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        mem_valid = 1'b0;
        mem_write = 1'b0;
        mem_addr = 64'h0;
        mem_wdata = 64'h0;
        mem_wstrb = 8'h00;

        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        if (mem_ready || mem_rdata !== 64'h0) begin
            $fatal(1, "idle ROM produced a response");
        end

        expect_read(64'h0, 64'h0010_0093_f140_2573,
                    "MHARTID and LI boot instructions");
        expect_read(64'h4, 64'h0010_0093_f140_2573,
                    "upper instruction uses containing word");
        expect_read(64'h8, 64'h0000_8067_01f0_9093,
                    "SLLI and JR boot instructions");
        expect_read(64'h10, 64'h0, "unused ROM is zero");
        expect_read(ROM_BYTES - 8, 64'h0, "final ROM word is zero");

        @(negedge clk);
        mem_valid = 1'b1;
        mem_write = 1'b1;
        mem_addr = 64'h0;
        mem_wdata = 64'hffff_ffff_ffff_ffff;
        mem_wstrb = 8'hff;
        @(posedge clk);
        #1;
        if (mem_ready)
            $fatal(1, "ROM write responded in request cycle");
        @(posedge clk);
        #1;
        if (!mem_ready || mem_rdata !== 64'h0) begin
            $fatal(1, "ROM write response invalid");
        end
        @(posedge clk);
        #1;
        mem_valid = 1'b0;
        mem_write = 1'b0;
        @(posedge clk);
        expect_read(64'h0, 64'h0010_0093_f140_2573,
                    "ROM write was ignored");

        expect_read(ROM_BYTES, 64'h0, "out-of-range local request");

        // Keep valid asserted and change the address immediately after the
        // first response handshake.  RECOVER must reject the new request for
        // one cycle before IDLE accepts it.
        @(negedge clk);
        mem_valid = 1'b1;
        mem_addr = 64'h0;
        @(posedge clk);
        @(posedge clk);
        #1;
        if (!mem_ready ||
            mem_rdata !== 64'h0010_0093_f140_2573)
            $fatal(1, "first sustained-valid response invalid");
        @(posedge clk);
        #1;
        mem_addr = 64'h8;
        if (mem_ready)
            $fatal(1, "ready remained asserted after response");
        @(posedge clk);
        #1;
        if (mem_ready)
            $fatal(1, "new request accepted during recovery");
        @(posedge clk);
        #1;
        if (mem_ready)
            $fatal(1, "new request responded in its capture cycle");
        @(posedge clk);
        #1;
        if (!mem_ready || mem_rdata !== 64'h0000_8067_01f0_9093)
            $fatal(1, "sustained-valid second response invalid");
        @(posedge clk);
        #1;
        mem_valid = 1'b0;

        $display("tb_soc_rom: PASS");
        $finish;
    end

endmodule
