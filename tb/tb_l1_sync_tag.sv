`timescale 1ns/1ps

module tb_l1_sync_tag;
    localparam integer TAG_WIDTH = 4;
    localparam [63:0] BASE = 64'h0000_0000_8000_0000;

    reg clk;
    reg rst_n;
    reg req_valid;
    wire req_ready;
    reg [TAG_WIDTH-1:0] req_tag;
    reg [63:0] req_addr;
    wire resp_valid;
    wire [TAG_WIDTH-1:0] resp_tag;
    wire [63:0] resp_data;
    wire resp_error;
    wire miss_valid;
    wire [TAG_WIDTH-1:0] miss_tag;
    wire [63:0] miss_addr;
    reg fill_valid;
    wire fill_ready;
    reg [63:0] fill_addr;
    reg [511:0] fill_data;
    reg invalidate_valid;
    wire invalidate_ready;
    reg [63:0] invalidate_addr;

    integer cycle_count;
    integer accept_count;
    integer response_count;
    integer first_accept_cycle;
    integer last_accept_cycle;
    integer first_response_cycle;
    integer last_response_cycle;

    openrv64_l1_cache #(
        .DATA_WIDTH(64),
        .REFILL_DATA_WIDTH(512),
        .REQ_TAG_WIDTH(TAG_WIDTH),
        .DETACH_READ_MISSES(1),
        .SYNC_TAG_LOOKUP(1),
        .CACHE_BYTES(1024),
        .LINE_BYTES(64),
        .WAYS(4)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_tag_i(req_tag),
        .req_write_i(1'b0),
        .req_cacheable_i(1'b1),
        .req_addr_i(req_addr),
        .req_phys_addr_i(req_addr),
        .req_prefetch_i(1'b0),
        .req_aged_i(1'b0),
        .req_separate_write_resp_i(1'b0),
        .req_wdata_i(64'd0),
        .req_wstrb_i(8'd0),
        .resp_valid_o(resp_valid),
        .resp_ready_i(1'b1),
        .resp_tag_o(resp_tag),
        .req_rdata_o(resp_data),
        .req_error_o(resp_error),
        .write_resp_valid_o(),
        .write_resp_ready_i(1'b1),
        .write_resp_tag_o(),
        .miss_valid_o(miss_valid),
        .miss_ready_i(1'b1),
        .miss_tag_o(miss_tag),
        .miss_addr_o(miss_addr),
        .miss_aged_o(),
        .fill_valid_i(fill_valid),
        .fill_ready_o(fill_ready),
        .fill_addr_i(fill_addr),
        .fill_data_i(fill_data),
        .fill_aged_i(1'b0),
        .invalidate_valid_i(invalidate_valid),
        .invalidate_ready_o(invalidate_ready),
        .invalidate_all_i(1'b0),
        .invalidate_addr_i(invalidate_addr),
        .age_valid_i(4'b0000),
        .age_addr_i(256'd0),
        .mem_valid_o(),
        .mem_ready_i(1'b0),
        .mem_write_o(),
        .mem_addr_o(),
        .mem_wdata_o(),
        .mem_wstrb_o(),
        .mem_rdata_i(512'd0),
        .mem_error_i(1'b0),
        .ideal_refill_valid_i(1'b0),
        .ideal_refill_data_i(64'd0)
    );

    always begin
        clk = 1'b0;
        #5;
        clk = 1'b1;
        #5;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= 0;
            accept_count <= 0;
            response_count <= 0;
            first_accept_cycle <= -1;
            last_accept_cycle <= -1;
            first_response_cycle <= -1;
            last_response_cycle <= -1;
        end else begin
            cycle_count <= cycle_count + 1;
            if (req_valid && req_ready) begin
                if (accept_count < 8) begin
                    if (accept_count == 0)
                        first_accept_cycle <= cycle_count;
                    else if (cycle_count != last_accept_cycle + 1)
                        $fatal(1, "synchronous-tag hit requests were not accepted every cycle");
                    last_accept_cycle <= cycle_count;
                end
                accept_count <= accept_count + 1;
            end
            if (resp_valid) begin
                if (resp_error)
                    $fatal(1, "resident synchronous-tag hit returned an error");
                if (resp_data !== (64'h1000 + resp_tag))
                    $fatal(1,
                        "hit tag=%0d data=%016x expected=%016x",
                        resp_tag, resp_data, 64'h1000 + resp_tag);
                if (response_count == 0)
                    first_response_cycle <= cycle_count;
                else if (cycle_count != last_response_cycle + 1)
                    $fatal(1, "synchronous-tag hit responses were not one per cycle");
                last_response_cycle <= cycle_count;
                response_count <= response_count + 1;
            end
        end
    end

    integer word_index;
    integer wait_cycles;
    initial begin
        rst_n = 1'b0;
        req_valid = 1'b0;
        req_tag = 0;
        req_addr = 0;
        fill_valid = 1'b0;
        fill_addr = BASE;
        fill_data = 512'd0;
        invalidate_valid = 1'b0;
        invalidate_addr = BASE;
        for (word_index = 0; word_index < 8;
             word_index = word_index + 1)
            fill_data[word_index*64 +: 64] = 64'h1000 + word_index;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        fill_valid = 1'b1;
        wait_cycles = 0;
        while (!fill_ready && wait_cycles < 8) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!fill_ready)
            $fatal(1, "synchronous tag fill probe timed out");
        @(posedge clk);
        @(negedge clk);
        fill_valid = 1'b0;

        req_valid = 1'b1;
        for (word_index = 0; word_index < 8;
             word_index = word_index + 1) begin
            req_tag = word_index[TAG_WIDTH-1:0];
            req_addr = BASE + word_index * 8;
            #1;
            if (!req_ready)
                $fatal(1, "resident hit %0d was backpressured", word_index);
            @(posedge clk);
            @(negedge clk);
        end
        req_valid = 1'b0;
        req_addr = 0;
        repeat (3) @(posedge clk);
        if ((accept_count != 8) || (response_count != 8))
            $fatal(1, "hit stream accepted=%0d responded=%0d",
                   accept_count, response_count);
        if (first_response_cycle != first_accept_cycle + 1)
            $fatal(1, "hit latency=%0d cycles expected=1",
                   first_response_cycle - first_accept_cycle);

        @(negedge clk);
        invalidate_valid = 1'b1;
        wait_cycles = 0;
        while (!invalidate_ready && wait_cycles < 8) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!invalidate_ready)
            $fatal(1, "synchronous target-invalidate probe timed out");
        @(posedge clk);
        @(negedge clk);
        invalidate_valid = 1'b0;

        req_valid = 1'b1;
        req_tag = 4'he;
        req_addr = BASE;
        while (!req_ready)
            @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        #1;
        if (!miss_valid || (miss_tag != 4'he) || (miss_addr != BASE))
            $fatal(1, "invalidated line did not become a tagged miss");
        @(posedge clk);

        $display("PASS: synchronous L1 tags sustain one hit/cycle at one-cycle array latency; fill and invalidate probes pass");
        $finish;
    end

    initial begin
        repeat (200) @(posedge clk);
        $fatal(1, "synchronous-tag L1 test timed out");
    end
endmodule
