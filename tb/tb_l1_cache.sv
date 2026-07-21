`timescale 1ns/1ps

module tb_l1_cache;

    logic clk;
    logic rst_n;

    logic req_valid;
    wire req_ready;
    logic req_write;
    logic req_cacheable;
    logic [63:0] req_addr;
    logic [63:0] req_wdata;
    logic [7:0] req_wstrb;
    wire [63:0] req_rdata;
    wire req_error;

    logic invalidate_valid;
    wire invalidate_ready;
    logic invalidate_all;
    logic [63:0] invalidate_addr;

    wire mem_valid;
    logic mem_stall;
    wire mem_ready;
    wire mem_write;
    wire [63:0] mem_addr;
    wire [63:0] mem_wdata;
    wire [7:0] mem_wstrb;
    wire [63:0] mem_rdata;
    wire mem_error;

    logic fail_enable;
    logic [63:0] fail_addr;
    logic [63:0] memory [0:4095];
    integer memory_requests;
    integer index;
    integer byte_index;
    logic [63:0] stalled_mem_addr;
    logic stalled_mem_write;
    logic [63:0] stalled_mem_wdata;
    logic [7:0] stalled_mem_wstrb;

    logic bypass_req_valid;
    wire bypass_req_ready;
    logic bypass_req_write;
    logic [63:0] bypass_req_addr;
    logic [63:0] bypass_req_wdata;
    logic [7:0] bypass_req_wstrb;
    wire [63:0] bypass_req_rdata;
    wire bypass_req_error;
    wire bypass_invalidate_ready;
    wire bypass_mem_valid;
    wire bypass_mem_write;
    wire [63:0] bypass_mem_addr;
    wire [63:0] bypass_mem_wdata;
    wire [7:0] bypass_mem_wstrb;
    logic bypass_mem_error;

    openrv64_l1d #(
        .CACHE_BYTES(1024),
        .LINE_BYTES(64),
        .WAYS(8)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_write_i(req_write),
        .req_cacheable_i(req_cacheable),
        .req_addr_i(req_addr),
        .req_wdata_i(req_wdata),
        .req_wstrb_i(req_wstrb),
        .req_rdata_o(req_rdata),
        .req_error_o(req_error),
        .invalidate_valid_i(invalidate_valid),
        .invalidate_ready_o(invalidate_ready),
        .invalidate_all_i(invalidate_all),
        .invalidate_addr_i(invalidate_addr),
        .mem_valid_o(mem_valid),
        .mem_ready_i(mem_ready),
        .mem_write_o(mem_write),
        .mem_addr_o(mem_addr),
        .mem_wdata_o(mem_wdata),
        .mem_wstrb_o(mem_wstrb),
        .mem_rdata_i(mem_rdata),
        .mem_error_i(mem_error)
    );

    // A second instance proves that ENABLE=0 is a structural pass-through.
    openrv64_l1d #(
        .ENABLE(0),
        .CACHE_BYTES(32 * 1024)
    ) bypass_dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(bypass_req_valid),
        .req_ready_o(bypass_req_ready),
        .req_write_i(bypass_req_write),
        .req_cacheable_i(1'b1),
        .req_addr_i(bypass_req_addr),
        .req_wdata_i(bypass_req_wdata),
        .req_wstrb_i(bypass_req_wstrb),
        .req_rdata_o(bypass_req_rdata),
        .req_error_o(bypass_req_error),
        .invalidate_valid_i(1'b0),
        .invalidate_ready_o(bypass_invalidate_ready),
        .invalidate_all_i(1'b0),
        .invalidate_addr_i(64'd0),
        .mem_valid_o(bypass_mem_valid),
        .mem_ready_i(bypass_mem_valid),
        .mem_write_o(bypass_mem_write),
        .mem_addr_o(bypass_mem_addr),
        .mem_wdata_o(bypass_mem_wdata),
        .mem_wstrb_o(bypass_mem_wstrb),
        .mem_rdata_i(64'hdead_beef_cafe_f00d),
        .mem_error_i(bypass_mem_error)
    );

    assign mem_ready = mem_valid && !mem_stall;
    assign mem_rdata = memory[mem_addr[14:3]];
    assign mem_error = fail_enable &&
                       ({mem_addr[63:3], 3'b000} == fail_addr);

    always begin
        clk = 1'b0;
        #5;
        clk = 1'b1;
        #5;
    end

    always @(posedge clk) begin
        if (rst_n && mem_valid && mem_ready) begin
            memory_requests <= memory_requests + 1;
            if (mem_write && !mem_error) begin
                for (byte_index = 0; byte_index < 8;
                     byte_index = byte_index + 1) begin
                    if (mem_wstrb[byte_index])
                        memory[mem_addr[14:3]][8*byte_index +: 8] <=
                            mem_wdata[8*byte_index +: 8];
                end
            end
        end
    end

    task automatic issue_request;
        input write;
        input cacheable;
        input [63:0] address;
        input [63:0] write_data;
        input [7:0] write_strobes;
        input [63:0] expected_data;
        input expected_error;
        input [8*48-1:0] label;
        integer cycles;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_write = write;
            req_cacheable = cacheable;
            req_addr = address;
            req_wdata = write_data;
            req_wstrb = write_strobes;
            cycles = 0;
            while (!req_ready && cycles < 200) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            #1;
            if (!req_ready)
                $fatal(1, "%0s timed out", label);
            if (req_error !== expected_error)
                $fatal(1, "%0s error=%b expected=%b", label,
                       req_error, expected_error);
            if (!write && !expected_error && req_rdata !== expected_data)
                $fatal(1, "%0s data=%016x expected=%016x", label,
                       req_rdata, expected_data);
            req_valid = 1'b0;
            req_write = 1'b0;
            req_cacheable = 1'b0;
            req_addr = 64'd0;
            req_wdata = 64'd0;
            req_wstrb = 8'd0;
        end
    endtask

    task automatic invalidate;
        input all_lines;
        input [63:0] address;
        integer cycles;
        begin
            @(negedge clk);
            invalidate_valid = 1'b1;
            invalidate_all = all_lines;
            invalidate_addr = address;
            cycles = 0;
            while (!invalidate_ready && cycles < 200) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!invalidate_ready)
                $fatal(1, "invalidation timed out");
            @(posedge clk);
            @(negedge clk);
            invalidate_valid = 1'b0;
            invalidate_all = 1'b0;
            invalidate_addr = 64'd0;
        end
    endtask

    task automatic expect_request_delta;
        input integer before_count;
        input integer expected_delta;
        input [8*48-1:0] label;
        begin
            if ((memory_requests - before_count) != expected_delta)
                $fatal(1, "%0s memory requests=%0d expected=%0d", label,
                       memory_requests - before_count, expected_delta);
        end
    endtask

    integer before_count;

    initial begin
        rst_n = 1'b0;
        req_valid = 1'b0;
        req_write = 1'b0;
        req_cacheable = 1'b0;
        req_addr = 64'd0;
        req_wdata = 64'd0;
        req_wstrb = 8'd0;
        invalidate_valid = 1'b0;
        invalidate_all = 1'b0;
        invalidate_addr = 64'd0;
        mem_stall = 1'b0;
        fail_enable = 1'b0;
        fail_addr = 64'd0;
        memory_requests = 0;
        bypass_req_valid = 1'b0;
        bypass_req_write = 1'b0;
        bypass_req_addr = 64'd0;
        bypass_req_wdata = 64'd0;
        bypass_req_wstrb = 8'd0;
        bypass_mem_error = 1'b0;
        for (index = 0; index < 4096; index = index + 1)
            memory[index] = 64'h1000_0000_0000_0000 + index;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        if ($bits(dut.u_l1.g_cache.u_cache.dirty_timestamp_q[0]) != 8 ||
            dut.u_l1.g_cache.u_cache.WRITEBACK_TIMEOUT_CYCLES != 128)
            $fatal(1, "default dirty timestamp/timeout geometry is wrong");

        before_count = memory_requests;
        mem_stall = 1'b1;
        fork
            issue_request(1'b0, 1'b1, 64'h118, 64'd0, 8'd0,
                          64'h1000_0000_0000_0023, 1'b0,
                          "read miss");
            begin
                wait (mem_valid);
                stalled_mem_addr = mem_addr;
                stalled_mem_write = mem_write;
                stalled_mem_wdata = mem_wdata;
                stalled_mem_wstrb = mem_wstrb;
                repeat (3) begin
                    @(negedge clk);
                    if (!mem_valid || mem_addr !== stalled_mem_addr ||
                        mem_write !== stalled_mem_write ||
                        mem_wdata !== stalled_mem_wdata ||
                        mem_wstrb !== stalled_mem_wstrb)
                        $fatal(1, "stalled memory request changed");
                end
                mem_stall = 1'b0;
            end
        join
        expect_request_delta(before_count, 8, "full-line refill");
        if (dut.u_l1.g_cache.u_cache.mesi_q[0] !== 2'b10 ||
            dut.u_l1.g_cache.u_cache.dirty_timestamp_q[0] !== 8'd0)
            $fatal(1, "refill did not initialize MESI/timestamp metadata");

        before_count = memory_requests;
        issue_request(1'b0, 1'b1, 64'h120, 64'd0, 8'd0,
                      64'h1000_0000_0000_0024, 1'b0,
                      "same-line read hit");
        expect_request_delta(before_count, 0, "read hit");

        before_count = memory_requests;
        issue_request(1'b1, 1'b1, 64'h11b,
                      64'h0000_0000_aa00_0000, 8'h08, 64'd0, 1'b0,
                      "partial write hit");
        expect_request_delta(before_count, 1, "write-through hit");
        issue_request(1'b0, 1'b1, 64'h118, 64'd0, 8'd0,
                      64'h1000_0000_aa00_0023, 1'b0,
                      "updated write-hit line");
        expect_request_delta(before_count, 1, "post-write read hit");
        if (dut.u_l1.g_cache.u_cache.mesi_q[0] !== 2'b10 ||
            dut.u_l1.g_cache.u_cache.dirty_timestamp_q[0] !== 8'd0)
            $fatal(1, "write-through store marked the line dirty");

        // A failed write-through must not change either lower memory or the
        // cached word.
        fail_enable = 1'b1;
        fail_addr = 64'h118;
        issue_request(1'b1, 1'b1, 64'h118,
                      64'h0000_0000_0000_0055, 8'h01, 64'd0, 1'b1,
                      "failed write hit");
        fail_enable = 1'b0;
        issue_request(1'b0, 1'b1, 64'h118, 64'd0, 8'd0,
                      64'h1000_0000_aa00_0023, 1'b0,
                      "failed write leaves line unchanged");

        before_count = memory_requests;
        issue_request(1'b1, 1'b1, 64'h208,
                      64'h0123_4567_89ab_cdef, 8'hff, 64'd0, 1'b0,
                      "write miss");
        expect_request_delta(before_count, 1, "write miss forwards once");
        before_count = memory_requests;
        issue_request(1'b0, 1'b1, 64'h208, 64'd0, 8'd0,
                      64'h0123_4567_89ab_cdef, 1'b0,
                      "read after no-write-allocate");
        expect_request_delta(before_count, 8, "write miss did not allocate");

        before_count = memory_requests;
        issue_request(1'b0, 1'b0, 64'h118, 64'd0, 8'd0,
                      64'h1000_0000_aa00_0023, 1'b0,
                      "uncacheable read");
        expect_request_delta(before_count, 1, "per-request bypass");

        invalidate(1'b0, 64'h100);
        if (dut.u_l1.g_cache.u_cache.mesi_q[0] !== 2'b00 ||
            dut.u_l1.g_cache.u_cache.dirty_timestamp_q[0] !== 8'd0)
            $fatal(1, "line invalidation did not clear metadata");
        before_count = memory_requests;
        issue_request(1'b0, 1'b1, 64'h118, 64'd0, 8'd0,
                      64'h1000_0000_aa00_0023, 1'b0,
                      "line invalidation");
        expect_request_delta(before_count, 8, "line invalidation refills");

        invalidate(1'b1, 64'd0);
        before_count = memory_requests;
        issue_request(1'b0, 1'b1, 64'h208, 64'd0, 8'd0,
                      64'h0123_4567_89ab_cdef, 1'b0,
                      "full invalidation");
        expect_request_delta(before_count, 8, "full invalidation refills");

        fail_enable = 1'b1;
        fail_addr = 64'h300;
        before_count = memory_requests;
        issue_request(1'b0, 1'b1, 64'h318, 64'd0, 8'd0,
                      64'd0, 1'b1, "refill error");
        expect_request_delta(before_count, 1, "refill stops on error");
        fail_enable = 1'b0;
        before_count = memory_requests;
        issue_request(1'b0, 1'b1, 64'h318, 64'd0, 8'd0,
                      64'h1000_0000_0000_0063, 1'b0,
                      "retry failed refill");
        expect_request_delta(before_count, 8, "failed line stayed invalid");

        // 1 KiB / 64-byte / eight-way has two sets.  Addresses 128 bytes
        // apart map to one set; the ninth distinct line must replace one of
        // the first eight.
        invalidate(1'b1, 64'd0);
        before_count = memory_requests;
        for (index = 0; index < 9; index = index + 1) begin
            issue_request(1'b0, 1'b1, 64'h400 + index * 64'h80,
                          64'd0, 8'd0,
                          memory[(64'h400 + index * 64'h80) >> 3],
                          1'b0, "eight-way set fill");
        end
        expect_request_delta(before_count, 72, "nine line fills");
        before_count = memory_requests;
        issue_request(1'b0, 1'b1, 64'h400, 64'd0, 8'd0,
                      memory[64'h400 >> 3], 1'b0,
                      "round-robin victim");
        expect_request_delta(before_count, 8, "ninth line evicted first way");

        // Cacheless mode preserves every request field and response.
        @(negedge clk);
        bypass_req_valid = 1'b1;
        bypass_req_write = 1'b1;
        bypass_req_addr = 64'h1234_5678_9abc_def3;
        bypass_req_wdata = 64'h1122_3344_5566_7788;
        bypass_req_wstrb = 8'h18;
        #1;
        if (!bypass_req_ready || !bypass_mem_valid || !bypass_mem_write ||
            bypass_mem_addr !== bypass_req_addr ||
            bypass_mem_wdata !== bypass_req_wdata ||
            bypass_mem_wstrb !== bypass_req_wstrb ||
            bypass_req_rdata !== 64'hdead_beef_cafe_f00d ||
            bypass_req_error || !bypass_invalidate_ready)
            $fatal(1, "cacheless wrapper is not transparent");
        bypass_req_valid = 1'b0;

        @(negedge clk);
        bypass_mem_error = 1'b1;
        bypass_req_valid = 1'b1;
        bypass_req_write = 1'b0;
        #1;
        if (!bypass_req_ready || !bypass_req_error)
            $fatal(1, "cacheless wrapper dropped a memory error");
        bypass_req_valid = 1'b0;
        bypass_mem_error = 1'b0;

        $display("L1 cache tests passed");
        $finish;
    end

endmodule
