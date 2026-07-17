`timescale 1ns/1ps

module tb_clint;

    localparam logic [63:0] MSIP_ADDR = 64'h0000;
    localparam logic [63:0] MTIMECMP0_ADDR = 64'h4000;
    localparam logic [63:0] MTIMECMP1_ADDR = 64'h4008;
    localparam logic [63:0] MTIME_ADDR = 64'hbff8;

    logic        clk;
    logic        rst_n;
    logic        mtime_tick;
    logic        mem_valid;
    logic        mem_ready;
    logic        mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0]  mem_wstrb;
    logic [63:0] mem_rdata;
    logic [1:0]  msip;
    logic [1:0]  mtip;
    logic [63:0] mtime;

    openrv64_clint #(
        .NUM_HARTS(2)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .mtime_tick_i(mtime_tick),
        .mem_valid_i(mem_valid),
        .mem_ready_o(mem_ready),
        .mem_write_i(mem_write),
        .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata),
        .mem_wstrb_i(mem_wstrb),
        .mem_rdata_o(mem_rdata),
        .msip_o(msip),
        .mtip_o(mtip),
        .mtime_o(mtime)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic bus_read;
        input  logic [63:0] address;
        output logic [63:0] data;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b0;
            mem_addr = address;
            mem_wdata = 64'h0000_0000_0000_0000;
            mem_wstrb = 8'h00;
            #1;
            if (!mem_ready) begin
                $fatal(1, "CLINT did not accept read at %016x", address);
            end
            data = mem_rdata;
            @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
            mem_addr = 64'h0000_0000_0000_0000;
        end
    endtask

    task automatic bus_write;
        input logic [63:0] address;
        input logic [63:0] data;
        input logic [7:0]  strobe;
        begin
            @(negedge clk);
            mem_valid = 1'b1;
            mem_write = 1'b1;
            mem_addr = address;
            mem_wdata = data;
            mem_wstrb = strobe;
            #1;
            if (!mem_ready) begin
                $fatal(1, "CLINT did not accept write at %016x", address);
            end
            @(posedge clk);
            @(negedge clk);
            mem_valid = 1'b0;
            mem_write = 1'b0;
            mem_addr = 64'h0000_0000_0000_0000;
            mem_wdata = 64'h0000_0000_0000_0000;
            mem_wstrb = 8'h00;
        end
    endtask

    task automatic timer_tick;
        begin
            @(negedge clk);
            mtime_tick = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mtime_tick = 1'b0;
        end
    endtask

    task automatic expect_read;
        input logic [63:0] address;
        input logic [63:0] expected;
        input [8*48-1:0] label;
        logic [63:0] actual;
        begin
            bus_read(address, actual);
            if (actual !== expected) begin
                $fatal(1, "%0s: read %016x, expected %016x",
                       label, actual, expected);
            end
        end
    endtask

    task automatic expect_state;
        input logic [1:0]  expected_msip;
        input logic [1:0]  expected_mtip;
        input logic [63:0] expected_mtime;
        input [8*48-1:0] label;
        begin
            #1;
            if (msip !== expected_msip ||
                mtip !== expected_mtip ||
                mtime !== expected_mtime) begin
                $fatal(1,
                       "%0s: msip=%02b/%02b mtip=%02b/%02b mtime=%016x/%016x",
                       label, msip, expected_msip, mtip, expected_mtip,
                       mtime, expected_mtime);
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        mtime_tick = 1'b0;
        mem_valid = 1'b0;
        mem_write = 1'b0;
        mem_addr = 64'h0000_0000_0000_0000;
        mem_wdata = 64'h0000_0000_0000_0000;
        mem_wstrb = 8'h00;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        expect_state(2'b00, 2'b00, 64'h0, "reset state");
        expect_read(MSIP_ADDR, 64'h0, "reset MSIP");
        expect_read(MTIMECMP0_ADDR, 64'hffff_ffff_ffff_ffff,
                    "reset MTIMECMP0");
        expect_read(MTIMECMP1_ADDR, 64'hffff_ffff_ffff_ffff,
                    "reset MTIMECMP1");
        expect_read(MTIME_ADDR, 64'h0, "reset MTIME");

        // The SoC decoder owns the global window; the CLINT itself receives
        // local offsets and acknowledges reserved ones with zero data.
        expect_read(64'h2000, 64'h0, "reserved local offset");

        // One aligned bus word contains MSIP0 and MSIP1. Only bit zero of
        // each 32-bit register is writable and readable.
        bus_write(MSIP_ADDR, 64'h0000_0001_0000_0001, 8'h11);
        expect_state(2'b11, 2'b00, 64'h0, "set both software interrupts");
        expect_read(MSIP_ADDR, 64'h0000_0001_0000_0001,
                    "packed MSIP read");

        bus_write(MSIP_ADDR, 64'hffff_fffe_ffff_fffe, 8'hff);
        expect_state(2'b00, 2'b00, 64'h0, "WARL-zero MSIP upper bits");
        expect_read(MSIP_ADDR, 64'h0, "MSIP upper bits read zero");

        bus_write(MSIP_ADDR, 64'h0000_0001_0000_0000, 8'hf0);
        bus_write(MSIP_ADDR, 64'h0, 8'h20);
        expect_state(2'b10, 2'b00, 64'h0,
                     "upper MSIP bytes do not alter bit zero");
        bus_write(MSIP_ADDR, 64'h0, 8'h10);
        expect_state(2'b00, 2'b00, 64'h0, "clear MSIP1");

        // Full and byte-masked 64-bit compare writes.
        bus_write(MTIMECMP0_ADDR, 64'h1122_3344_5566_7788, 8'hff);
        bus_write(MTIMECMP0_ADDR, 64'haabb_ccdd_eeff_0011, 8'h81);
        expect_read(MTIMECMP0_ADDR, 64'haa22_3344_5566_7711,
                    "partial MTIMECMP write");

        bus_write(MTIMECMP0_ADDR, 64'd3, 8'hff);
        bus_write(MTIMECMP1_ADDR, 64'd5, 8'hff);
        expect_state(2'b00, 2'b00, 64'd0, "program timer deadlines");

        timer_tick();
        timer_tick();
        expect_state(2'b00, 2'b00, 64'd2, "timer below deadlines");
        timer_tick();
        expect_state(2'b00, 2'b01, 64'd3, "MTIP0 at equality");
        timer_tick();
        timer_tick();
        expect_state(2'b00, 2'b11, 64'd5, "MTIP1 at equality");

        bus_write(MTIMECMP0_ADDR, 64'd10, 8'hff);
        expect_state(2'b00, 2'b10, 64'd5,
                     "raising compare clears timer interrupt");

        // MTIME is writable and honors byte strobes just like MTIMECMP.
        bus_write(MTIME_ADDR, 64'h1122_3344_5566_7788, 8'hff);
        bus_write(MTIME_ADDR, 64'haabb_ccdd_eeff_0011, 8'h81);
        expect_read(MTIME_ADDR, 64'haa22_3344_5566_7711,
                    "partial MTIME write");
        bus_write(MTIME_ADDR, 64'h0, 8'hff);
        expect_state(2'b00, 2'b00, 64'h0,
                     "writing MTIME clears compare results");

        // Reset restores deterministic, non-pending timer state.
        @(negedge clk);
        rst_n = 1'b0;
        #1;
        expect_state(2'b00, 2'b00, 64'h0, "asynchronous reset");
        rst_n = 1'b1;
        expect_read(MTIMECMP0_ADDR, 64'hffff_ffff_ffff_ffff,
                    "MTIMECMP reset restore");

        $display("PASS: CLINT register map, timer, interrupts, and byte strobes");
        $finish;
    end

    initial begin
        repeat (256) @(posedge clk);
        $fatal(1, "timeout in CLINT test");
    end

endmodule
