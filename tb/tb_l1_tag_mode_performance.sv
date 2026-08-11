`timescale 1ns/1ps

// Paired behavioral/performance probe for the two L1 tag organizations.  Each
// runner receives the same operation stream and reports cycles from request
// presentation through the externally visible completion of that operation.
module l1_tag_mode_performance_runner #(
    parameter integer SYNC_TAG_LOOKUP = 0,
    parameter integer SYNC_STORE_EXTENSION = 1,
    parameter integer ITERATIONS = 4096
) (
    input  wire clk_i,
    input  wire rst_ni,
    output reg  done_o,
    output integer hit_cycles_o,
    output integer miss_cycles_o,
    output integer fill_cycles_o,
    output integer invalidate_cycles_o,
    output integer store_cycles_o,
    output integer store_extensions_o,
    output integer total_cycles_o
);
    localparam integer TAG_WIDTH = 8;
    localparam integer OP_TIMEOUT = 64;
    localparam integer STORE_LINES = 16;
    localparam [63:0] HIT_ADDR = 64'h0000_0000_8000_0000;
    localparam [63:0] MISS_ADDR = 64'h0000_0000_8100_0000;
    localparam [63:0] FILL_ADDR = 64'h0000_0000_8200_0000;
    localparam [63:0] INVALIDATE_ADDR = 64'h0000_0000_8300_0000;
    localparam [63:0] STORE_ADDR = 64'h0000_0000_8400_0000;
    localparam [63:0] HIT_DATA = 64'h0123_4567_89ab_cdef;

    reg req_valid;
    wire req_ready;
    reg [TAG_WIDTH-1:0] req_tag;
    reg req_write;
    reg [63:0] req_addr;
    reg req_separate_write_resp;
    reg [63:0] req_wdata;
    reg [7:0] req_wstrb;
    wire resp_valid;
    wire [63:0] resp_data;
    wire resp_error;
    wire write_resp_valid;
    wire miss_valid;
    reg fill_valid;
    wire fill_ready;
    reg [63:0] fill_addr;
    reg invalidate_valid;
    wire invalidate_ready;
    reg [63:0] invalidate_addr;
    wire mem_valid;
    wire mem_write;
    wire [7:0] mem_wstrb;

    integer cycle_count;
    integer accept_count;
    integer response_count;
    integer miss_count;
    integer write_response_count;
    integer memory_write_count;
    integer benchmark_index;
    integer elapsed;

    openrv64_l1_cache #(
        .DATA_WIDTH(64),
        .REFILL_DATA_WIDTH(512),
        .REQ_TAG_WIDTH(TAG_WIDTH),
        .DETACH_READ_MISSES(1),
        .SYNC_TAG_LOOKUP(SYNC_TAG_LOOKUP),
        .SYNC_STORE_EXTENSION(SYNC_STORE_EXTENSION),
        .CACHE_BYTES(1024),
        .LINE_BYTES(64),
        .WAYS(4)
    ) dut (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_tag_i(req_tag),
        .req_write_i(req_write),
        .req_cacheable_i(1'b1),
        .req_addr_i(req_addr),
        .req_phys_addr_i(req_addr),
        .req_prefetch_i(1'b0),
        .req_aged_i(1'b0),
        .req_separate_write_resp_i(req_separate_write_resp),
        .req_wdata_i(req_wdata),
        .req_wstrb_i(req_wstrb),
        .resp_valid_o(resp_valid),
        .resp_ready_i(1'b1),
        .resp_tag_o(),
        .req_rdata_o(resp_data),
        .req_error_o(resp_error),
        .write_resp_valid_o(write_resp_valid),
        .write_resp_ready_i(1'b1),
        .write_resp_tag_o(),
        .miss_valid_o(miss_valid),
        .miss_ready_i(1'b1),
        .miss_tag_o(),
        .miss_addr_o(),
        .miss_aged_o(),
        .fill_valid_i(fill_valid),
        .fill_ready_o(fill_ready),
        .fill_addr_i(fill_addr),
        .fill_data_i({8{HIT_DATA}}),
        .fill_aged_i(1'b0),
        .invalidate_valid_i(invalidate_valid),
        .invalidate_ready_o(invalidate_ready),
        .invalidate_all_i(1'b0),
        .invalidate_addr_i(invalidate_addr),
        .age_valid_i(4'b0000),
        .age_addr_i(256'd0),
        .mem_valid_o(mem_valid),
        .mem_ready_i(1'b1),
        .mem_write_o(mem_write),
        .mem_addr_o(),
        .mem_wdata_o(),
        .mem_wstrb_o(mem_wstrb),
        .mem_rdata_i(512'd0),
        .mem_error_i(1'b0),
        .ideal_refill_valid_i(1'b0),
        .ideal_refill_data_i(64'd0)
    );

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cycle_count <= 0;
            accept_count <= 0;
            response_count <= 0;
            miss_count <= 0;
            write_response_count <= 0;
            memory_write_count <= 0;
            store_extensions_o <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (req_valid && req_ready)
                accept_count <= accept_count + 1;
            if (resp_valid) begin
                if (resp_error || (resp_data !== HIT_DATA))
                    $fatal(1, "mode=%0d bad resident response data=%016x error=%0d",
                           SYNC_TAG_LOOKUP, resp_data, resp_error);
                response_count <= response_count + 1;
            end
            if (miss_valid)
                miss_count <= miss_count + 1;
            if (write_resp_valid)
                write_response_count <= write_response_count + 1;
            if (mem_valid) begin
                if (!mem_write || (mem_wstrb !== 8'hff))
                    $fatal(1, "mode=%0d store emitted malformed memory write",
                           SYNC_TAG_LOOKUP);
                memory_write_count <= memory_write_count + 1;
            end
            if (dut.sync_store_extension_fire)
                store_extensions_o <= store_extensions_o + 1;
        end
    end

    task automatic fill_one;
        input [63:0] address;
        output integer operation_cycles;
        integer start_cycle;
        integer wait_cycles;
        begin
            @(negedge clk_i);
            start_cycle = cycle_count;
            fill_addr = address;
            fill_valid = 1'b1;
            wait_cycles = 0;
            while (!fill_ready && (wait_cycles < OP_TIMEOUT)) begin
                @(negedge clk_i);
                wait_cycles = wait_cycles + 1;
            end
            if (!fill_ready)
                $fatal(1, "mode=%0d fill timed out", SYNC_TAG_LOOKUP);
            @(posedge clk_i);
            @(negedge clk_i);
            fill_valid = 1'b0;
            operation_cycles = cycle_count - start_cycle;
        end
    endtask

    task automatic invalidate_one;
        input [63:0] address;
        output integer operation_cycles;
        integer start_cycle;
        integer wait_cycles;
        begin
            @(negedge clk_i);
            start_cycle = cycle_count;
            invalidate_addr = address;
            invalidate_valid = 1'b1;
            wait_cycles = 0;
            while (!invalidate_ready && (wait_cycles < OP_TIMEOUT)) begin
                @(negedge clk_i);
                wait_cycles = wait_cycles + 1;
            end
            if (!invalidate_ready)
                $fatal(1, "mode=%0d invalidate timed out", SYNC_TAG_LOOKUP);
            @(posedge clk_i);
            @(negedge clk_i);
            invalidate_valid = 1'b0;
            operation_cycles = cycle_count - start_cycle;
        end
    endtask

    task automatic issue_miss;
        input [63:0] address;
        output integer operation_cycles;
        integer start_cycle;
        integer target_misses;
        integer wait_cycles;
        begin
            @(negedge clk_i);
            start_cycle = cycle_count;
            target_misses = miss_count + 1;
            req_addr = address;
            req_tag = 0;
            req_write = 1'b0;
            req_separate_write_resp = 1'b0;
            req_wstrb = 8'd0;
            req_valid = 1'b1;
            wait_cycles = 0;
            while (!req_ready && (wait_cycles < OP_TIMEOUT)) begin
                @(negedge clk_i);
                wait_cycles = wait_cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "mode=%0d miss request timed out", SYNC_TAG_LOOKUP);
            @(posedge clk_i);
            @(negedge clk_i);
            req_valid = 1'b0;
            wait_cycles = 0;
            while ((miss_count < target_misses) &&
                   (wait_cycles < OP_TIMEOUT)) begin
                @(negedge clk_i);
                wait_cycles = wait_cycles + 1;
            end
            if (miss_count < target_misses)
                $fatal(1, "mode=%0d miss completion timed out", SYNC_TAG_LOOKUP);
            operation_cycles = cycle_count - start_cycle;
        end
    endtask

    task automatic issue_store;
        input [63:0] address;
        input [63:0] data;
        output integer operation_cycles;
        integer start_cycle;
        integer target_responses;
        integer wait_cycles;
        begin
            @(negedge clk_i);
            start_cycle = cycle_count;
            target_responses = write_response_count + 1;
            req_addr = address;
            req_tag = 0;
            req_write = 1'b1;
            req_separate_write_resp = 1'b1;
            req_wdata = data;
            req_wstrb = 8'hff;
            req_valid = 1'b1;
            wait_cycles = 0;
            while (!req_ready && (wait_cycles < OP_TIMEOUT)) begin
                @(negedge clk_i);
                wait_cycles = wait_cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "mode=%0d store request timed out", SYNC_TAG_LOOKUP);
            @(posedge clk_i);
            @(negedge clk_i);
            req_valid = 1'b0;
            wait_cycles = 0;
            while ((write_response_count < target_responses) &&
                   (wait_cycles < OP_TIMEOUT)) begin
                @(negedge clk_i);
                wait_cycles = wait_cycles + 1;
            end
            if (write_response_count < target_responses)
                $fatal(1, "mode=%0d store completion timed out", SYNC_TAG_LOOKUP);
            operation_cycles = cycle_count - start_cycle;
        end
    endtask

    task automatic run_hit_stream;
        output integer operation_cycles;
        integer start_cycle;
        integer start_responses;
        integer wait_cycles;
        begin
            @(negedge clk_i);
            start_cycle = cycle_count;
            start_responses = response_count;
            req_write = 1'b0;
            req_separate_write_resp = 1'b0;
            req_wstrb = 8'd0;
            req_valid = 1'b1;
            for (benchmark_index = 0; benchmark_index < ITERATIONS;
                 benchmark_index = benchmark_index + 1) begin
                req_tag = benchmark_index[TAG_WIDTH-1:0];
                req_addr = HIT_ADDR + ((benchmark_index & 7) * 8);
                #1;
                if (!req_ready)
                    $fatal(1, "mode=%0d resident hit %0d was backpressured",
                           SYNC_TAG_LOOKUP, benchmark_index);
                @(posedge clk_i);
                @(negedge clk_i);
            end
            req_valid = 1'b0;
            wait_cycles = 0;
            while ((response_count < start_responses + ITERATIONS) &&
                   (wait_cycles < OP_TIMEOUT)) begin
                @(negedge clk_i);
                wait_cycles = wait_cycles + 1;
            end
            if (response_count != start_responses + ITERATIONS)
                $fatal(1, "mode=%0d hit responses=%0d expected=%0d",
                       SYNC_TAG_LOOKUP, response_count - start_responses,
                       ITERATIONS);
            operation_cycles = cycle_count - start_cycle;
        end
    endtask

    initial begin
        done_o = 1'b0;
        hit_cycles_o = 0;
        miss_cycles_o = 0;
        fill_cycles_o = 0;
        invalidate_cycles_o = 0;
        store_cycles_o = 0;
        store_extensions_o = 0;
        total_cycles_o = 0;
        req_valid = 1'b0;
        req_tag = 0;
        req_write = 1'b0;
        req_addr = 0;
        req_separate_write_resp = 1'b0;
        req_wdata = 0;
        req_wstrb = 0;
        fill_valid = 1'b0;
        fill_addr = 0;
        invalidate_valid = 1'b0;
        invalidate_addr = 0;

        wait (rst_ni);
        fill_one(HIT_ADDR, elapsed);
        run_hit_stream(hit_cycles_o);

        for (benchmark_index = 0; benchmark_index < ITERATIONS;
             benchmark_index = benchmark_index + 1) begin
            issue_miss(MISS_ADDR, elapsed);
            miss_cycles_o = miss_cycles_o + elapsed;
        end

        for (benchmark_index = 0; benchmark_index < ITERATIONS;
             benchmark_index = benchmark_index + 1) begin
            fill_one(FILL_ADDR + ((benchmark_index & 15) * 64), elapsed);
            fill_cycles_o = fill_cycles_o + elapsed;
        end

        for (benchmark_index = 0; benchmark_index < ITERATIONS;
             benchmark_index = benchmark_index + 1) begin
            fill_one(INVALIDATE_ADDR, elapsed);
            invalidate_one(INVALIDATE_ADDR, elapsed);
            invalidate_cycles_o = invalidate_cycles_o + elapsed;
        end

        for (benchmark_index = 0; benchmark_index < STORE_LINES;
             benchmark_index = benchmark_index + 1)
            fill_one(STORE_ADDR + benchmark_index * 64, elapsed);
        for (benchmark_index = 0; benchmark_index < ITERATIONS;
             benchmark_index = benchmark_index + 1) begin
            issue_store(STORE_ADDR +
                        ((benchmark_index &
                          (STORE_LINES * 8 - 1)) * 8),
                        benchmark_index, elapsed);
            store_cycles_o = store_cycles_o + elapsed;
        end
        if (memory_write_count != ITERATIONS)
            $fatal(1, "mode=%0d memory writes=%0d expected=%0d",
                   SYNC_TAG_LOOKUP, memory_write_count, ITERATIONS);
        if (accept_count != ITERATIONS * 3)
            $fatal(1, "mode=%0d accepted requests=%0d expected=%0d",
                   SYNC_TAG_LOOKUP, accept_count, ITERATIONS * 3);
        if ((response_count != ITERATIONS) ||
            (miss_count != ITERATIONS) ||
            (write_response_count != ITERATIONS))
            $fatal(1,
                   "mode=%0d completions hit=%0d miss=%0d store=%0d expected=%0d",
                   SYNC_TAG_LOOKUP, response_count, miss_count,
                   write_response_count, ITERATIONS);

        total_cycles_o = hit_cycles_o + miss_cycles_o + fill_cycles_o +
                         invalidate_cycles_o + store_cycles_o;
        done_o = 1'b1;
    end
endmodule

module tb_l1_tag_mode_performance;
    localparam integer ITERATIONS = 4096;
    reg clk;
    reg rst_n;
    wire legacy_done;
    wire sync_control_done;
    wire sync_done;
    integer legacy_hit_cycles;
    integer legacy_miss_cycles;
    integer legacy_fill_cycles;
    integer legacy_invalidate_cycles;
    integer legacy_store_cycles;
    integer legacy_store_extensions;
    integer legacy_total_cycles;
    integer sync_control_hit_cycles;
    integer sync_control_miss_cycles;
    integer sync_control_fill_cycles;
    integer sync_control_invalidate_cycles;
    integer sync_control_store_cycles;
    integer sync_control_store_extensions;
    integer sync_control_total_cycles;
    integer sync_hit_cycles;
    integer sync_miss_cycles;
    integer sync_fill_cycles;
    integer sync_invalidate_cycles;
    integer sync_store_cycles;
    integer sync_store_extensions;
    integer sync_total_cycles;

    l1_tag_mode_performance_runner #(
        .SYNC_TAG_LOOKUP(0),
        .SYNC_STORE_EXTENSION(0),
        .ITERATIONS(ITERATIONS)
    ) legacy_runner (
        .clk_i(clk),
        .rst_ni(rst_n),
        .done_o(legacy_done),
        .hit_cycles_o(legacy_hit_cycles),
        .miss_cycles_o(legacy_miss_cycles),
        .fill_cycles_o(legacy_fill_cycles),
        .invalidate_cycles_o(legacy_invalidate_cycles),
        .store_cycles_o(legacy_store_cycles),
        .store_extensions_o(legacy_store_extensions),
        .total_cycles_o(legacy_total_cycles)
    );

    l1_tag_mode_performance_runner #(
        .SYNC_TAG_LOOKUP(1),
        .SYNC_STORE_EXTENSION(0),
        .ITERATIONS(ITERATIONS)
    ) sync_control_runner (
        .clk_i(clk),
        .rst_ni(rst_n),
        .done_o(sync_control_done),
        .hit_cycles_o(sync_control_hit_cycles),
        .miss_cycles_o(sync_control_miss_cycles),
        .fill_cycles_o(sync_control_fill_cycles),
        .invalidate_cycles_o(sync_control_invalidate_cycles),
        .store_cycles_o(sync_control_store_cycles),
        .store_extensions_o(sync_control_store_extensions),
        .total_cycles_o(sync_control_total_cycles)
    );

    l1_tag_mode_performance_runner #(
        .SYNC_TAG_LOOKUP(1),
        .SYNC_STORE_EXTENSION(1),
        .ITERATIONS(ITERATIONS)
    ) sync_runner (
        .clk_i(clk),
        .rst_ni(rst_n),
        .done_o(sync_done),
        .hit_cycles_o(sync_hit_cycles),
        .miss_cycles_o(sync_miss_cycles),
        .fill_cycles_o(sync_fill_cycles),
        .invalidate_cycles_o(sync_invalidate_cycles),
        .store_cycles_o(sync_store_cycles),
        .store_extensions_o(sync_store_extensions),
        .total_cycles_o(sync_total_cycles)
    );

    always begin
        clk = 1'b0;
        #5;
        clk = 1'b1;
        #5;
    end

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    initial begin
        repeat (ITERATIONS * 32 + 1000) @(posedge clk);
        $fatal(1, "L1 tag-mode performance benchmark timed out");
    end

    initial begin
        wait (legacy_done && sync_control_done && sync_done);
        if (legacy_hit_cycles != sync_hit_cycles)
            $fatal(1, "resident hit totals differ: legacy=%0d sync=%0d",
                   legacy_hit_cycles, sync_hit_cycles);
        if ((legacy_hit_cycles != ITERATIONS + 1) ||
            (legacy_miss_cycles != ITERATIONS) ||
            (legacy_fill_cycles != ITERATIONS) ||
            (legacy_invalidate_cycles != ITERATIONS) ||
            (legacy_store_cycles != ITERATIONS * 3))
            $fatal(1, "legacy tag timing contract changed");
        if ((sync_control_hit_cycles != ITERATIONS + 1) ||
            (sync_control_miss_cycles != ITERATIONS * 2) ||
            (sync_control_fill_cycles != ITERATIONS * 2) ||
            (sync_control_invalidate_cycles != ITERATIONS * 2) ||
            (sync_control_store_cycles != ITERATIONS * 4) ||
            (sync_control_store_extensions != 0))
            $fatal(1, "registered-tag control timing contract changed");
        if ((sync_hit_cycles != sync_control_hit_cycles) ||
            (sync_miss_cycles != sync_control_miss_cycles) ||
            (sync_fill_cycles != sync_control_fill_cycles) ||
            (sync_invalidate_cycles != sync_control_invalidate_cycles) ||
            (sync_store_cycles !=
             ITERATIONS * 4 - (ITERATIONS - ITERATIONS / 8)) ||
            (sync_store_extensions !=
             ITERATIONS - ITERATIONS / 8))
            $fatal(1,
                   "registered-tag store-extension timing contract changed");

        $display("PERF: mode=legacy iterations=%0d hits=%0d misses=%0d fills=%0d invalidates=%0d stores=%0d total=%0d",
                 ITERATIONS, legacy_hit_cycles, legacy_miss_cycles,
                 legacy_fill_cycles, legacy_invalidate_cycles,
                 legacy_store_cycles, legacy_total_cycles);
        $display("PERF: mode=sync-control iterations=%0d hits=%0d misses=%0d fills=%0d invalidates=%0d stores=%0d extensions=%0d total=%0d",
                 ITERATIONS, sync_control_hit_cycles,
                 sync_control_miss_cycles, sync_control_fill_cycles,
                 sync_control_invalidate_cycles,
                 sync_control_store_cycles,
                 sync_control_store_extensions,
                 sync_control_total_cycles);
        $display("PERF: mode=sync-extension iterations=%0d hits=%0d misses=%0d fills=%0d invalidates=%0d stores=%0d extensions=%0d total=%0d",
                 ITERATIONS, sync_hit_cycles, sync_miss_cycles,
                 sync_fill_cycles, sync_invalidate_cycles,
                 sync_store_cycles, sync_store_extensions,
                 sync_total_cycles);
        $display("PERF: extension-delta stores=%0d total=%0d",
                 sync_store_cycles - sync_control_store_cycles,
                 sync_total_cycles - sync_control_total_cycles);
        $display("PASS: legacy, registered-tag control, and same-line store-extension performance comparison");
        $finish;
    end
endmodule
