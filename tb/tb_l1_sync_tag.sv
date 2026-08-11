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
    reg req_write;
    reg req_separate_write_resp;
    reg [63:0] req_wdata;
    reg [7:0] req_wstrb;
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
    reg mem_ready;
    wire mem_valid;
    wire mem_write;
    wire [63:0] mem_addr;
    wire [63:0] mem_wdata;
    wire [7:0] mem_wstrb;
    wire write_resp_valid;
    wire [TAG_WIDTH-1:0] write_resp_tag;
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
    integer store_extension_count;

    openrv64_l1_cache #(
        .DATA_WIDTH(64),
        .REFILL_DATA_WIDTH(512),
        .REQ_TAG_WIDTH(TAG_WIDTH),
        .DETACH_READ_MISSES(1),
        .SYNC_TAG_LOOKUP(1),
        .SYNC_STORE_EXTENSION(1),
        .CACHE_BYTES(1024),
        .LINE_BYTES(64),
        .WAYS(4)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
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
        .resp_tag_o(resp_tag),
        .req_rdata_o(resp_data),
        .req_error_o(resp_error),
        .write_resp_valid_o(write_resp_valid),
        .write_resp_ready_i(1'b1),
        .write_resp_tag_o(write_resp_tag),
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
        .mem_valid_o(mem_valid),
        .mem_ready_i(mem_ready),
        .mem_write_o(mem_write),
        .mem_addr_o(mem_addr),
        .mem_wdata_o(mem_wdata),
        .mem_wstrb_o(mem_wstrb),
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
            store_extension_count <= 0;
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
                if (response_count < 8) begin
                    if (resp_data !== (64'h1000 + resp_tag))
                        $fatal(1,
                            "hit tag=%0d data=%016x expected=%016x",
                            resp_tag, resp_data, 64'h1000 + resp_tag);
                    if (response_count == 0)
                        first_response_cycle <= cycle_count;
                    else if (cycle_count != last_response_cycle + 1)
                        $fatal(1, "synchronous-tag hit responses were not one per cycle");
                    last_response_cycle <= cycle_count;
                end
                response_count <= response_count + 1;
            end
            if (dut.sync_store_extension_fire)
                store_extension_count <= store_extension_count + 1;
        end
    end

    task automatic issue_posted_store;
        input [63:0] address;
        input [63:0] data;
        input [7:0] strb;
        input [TAG_WIDTH-1:0] tag;
        integer local_wait;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_write = 1'b1;
            req_separate_write_resp = 1'b1;
            req_tag = tag;
            req_addr = address;
            req_wdata = data;
            req_wstrb = strb;
            local_wait = 0;
            while (!req_ready && local_wait < 12) begin
                @(negedge clk);
                local_wait = local_wait + 1;
            end
            if (!req_ready)
                $fatal(1, "posted store timed out addr=%h", address);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            local_wait = 0;
            while (!write_resp_valid && local_wait < 12) begin
                @(negedge clk);
                local_wait = local_wait + 1;
            end
            if (!write_resp_valid || (write_resp_tag != tag))
                $fatal(1,
                       "posted store completion failed addr=%h tag=%0d got=%0d",
                       address, tag, write_resp_tag);
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic check_resident_word;
        input [63:0] address;
        input [63:0] expected;
        input [TAG_WIDTH-1:0] tag;
        integer local_wait;
        begin
            req_valid = 1'b1;
            req_write = 1'b0;
            req_separate_write_resp = 1'b0;
            req_tag = tag;
            req_addr = address;
            req_wdata = 64'd0;
            req_wstrb = 8'd0;
            local_wait = 0;
            while (!req_ready && local_wait < 12) begin
                @(negedge clk);
                local_wait = local_wait + 1;
            end
            if (!req_ready)
                $fatal(1, "resident read timed out addr=%h", address);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            local_wait = 0;
            while (!resp_valid && local_wait < 12) begin
                @(negedge clk);
                local_wait = local_wait + 1;
            end
            if (!resp_valid || (resp_tag != tag) ||
                (resp_data !== expected))
                $fatal(1,
                       "resident word mismatch addr=%h tag=%0d data=%h expected=%h",
                       address, tag, resp_data, expected);
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    integer word_index;
    integer wait_cycles;
    initial begin
        rst_n = 1'b0;
        req_valid = 1'b0;
        req_tag = 0;
        req_addr = 0;
        req_write = 1'b0;
        req_separate_write_resp = 1'b0;
        req_wdata = 64'd0;
        req_wstrb = 8'd0;
        fill_valid = 1'b0;
        fill_addr = BASE;
        fill_data = 512'd0;
        mem_ready = 1'b0;
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

        // A valid-hit store establishes the extension context.  Consecutive
        // stores to other words of the same VA line reuse that context.  A
        // fill, invalidate, or intervening load must terminate the chain.
        mem_ready = 1'b1;
        issue_posted_store(BASE, 64'h1111_1111_1111_1111,
                           8'hff, 4'h8);
        issue_posted_store(BASE + 8, 64'h2222_2222_2222_2222,
                           8'h0f, 4'h9);
        if (store_extension_count != 1)
            $fatal(1, "same-line store did not extend count=%0d",
                   store_extension_count);

        fill_addr = BASE + 64'h100;
        fill_data = {8{64'h5555_aaaa_5555_aaaa}};
        fill_valid = 1'b1;
        while (!fill_ready)
            @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        fill_valid = 1'b0;
        if (dut.sync_store_extension_valid_q)
            $fatal(1, "detached fill did not break the store extension");
        issue_posted_store(BASE + 16, 64'h3333_3333_3333_3333,
                           8'hff, 4'ha);
        if (store_extension_count != 1)
            $fatal(1, "store crossed a detached-fill boundary");
        issue_posted_store(BASE + 24, 64'h4444_4444_4444_4444,
                           8'hff, 4'hb);
        if (store_extension_count != 2)
            $fatal(1, "store did not reestablish extension after fill");

        invalidate_addr = BASE + 64'h100;
        invalidate_valid = 1'b1;
        while (!invalidate_ready)
            @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        invalidate_valid = 1'b0;
        if (dut.sync_store_extension_valid_q)
            $fatal(1, "target invalidate did not break the store extension");
        issue_posted_store(BASE + 32, 64'h5555_5555_5555_5555,
                           8'hff, 4'hc);
        if (store_extension_count != 2)
            $fatal(1, "store crossed an invalidate boundary");
        issue_posted_store(BASE + 40, 64'h6666_6666_6666_6666,
                           8'hff, 4'hd);
        if (store_extension_count != 3)
            $fatal(1, "store did not reestablish extension after invalidate");

        check_resident_word(BASE, 64'h1111_1111_1111_1111, 4'h8);
        issue_posted_store(BASE + 48, 64'h7777_7777_7777_7777,
                           8'hff, 4'he);
        if (store_extension_count != 3)
            $fatal(1, "store crossed an intervening-load boundary");
        issue_posted_store(BASE + 56, 64'h8888_8888_8888_8888,
                           8'hff, 4'hf);
        if (store_extension_count != 4)
            $fatal(1, "store did not reestablish extension after load");

        check_resident_word(BASE + 8, 64'h0000_0000_2222_2222, 4'h9);
        check_resident_word(BASE + 16, 64'h3333_3333_3333_3333, 4'ha);
        check_resident_word(BASE + 24, 64'h4444_4444_4444_4444, 4'hb);
        check_resident_word(BASE + 32, 64'h5555_5555_5555_5555, 4'hc);
        check_resident_word(BASE + 40, 64'h6666_6666_6666_6666, 4'hd);
        check_resident_word(BASE + 48, 64'h7777_7777_7777_7777, 4'he);
        check_resident_word(BASE + 56, 64'h8888_8888_8888_8888, 4'hf);

        // Reproduce the write-port collision which occurs when a detached
        // fill probe launches as a synchronous posted-store lookup enters
        // STATE_ACCESS.  The fill must wait; otherwise its SRAM write wins
        // the mux and the acknowledged resident-line store disappears.
        @(negedge clk);
        req_valid = 1'b1;
        req_write = 1'b1;
        req_separate_write_resp = 1'b1;
        req_tag = 4'hd;
        req_addr = BASE + 24;
        req_wdata = 64'hfeed_face_cafe_beef;
        req_wstrb = 8'hff;
        mem_ready = 1'b1;
        while (!req_ready)
            @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        fill_addr = BASE + 64'h100;
        fill_data = {8{64'h5555_aaaa_5555_aaaa}};
        fill_valid = 1'b1;
        wait_cycles = 0;
        while (!(mem_valid && mem_write) && wait_cycles < 8) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!mem_valid || !mem_write ||
            (mem_addr != BASE + 24) ||
            (mem_wdata != 64'hfeed_face_cafe_beef) ||
            (mem_wstrb != 8'hff))
            $fatal(1, "colliding posted store lower-memory request changed");
        if (fill_ready)
            $fatal(1, "detached fill consumed the store SRAM write cycle");
        @(posedge clk);
        @(negedge clk);
        if (!write_resp_valid || (write_resp_tag != 4'hd))
            $fatal(1, "colliding posted store did not complete");
        wait_cycles = 0;
        while (!fill_ready && wait_cycles < 8) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!fill_ready)
            $fatal(1, "fill did not resume after posted store completion");
        @(posedge clk);
        @(negedge clk);
        fill_valid = 1'b0;
        mem_ready = 1'b0;
        req_write = 1'b0;
        req_separate_write_resp = 1'b0;
        req_wdata = 64'd0;
        req_wstrb = 8'd0;

        req_valid = 1'b1;
        req_tag = 4'h3;
        req_addr = BASE + 24;
        while (!req_ready)
            @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        wait_cycles = 0;
        while (!resp_valid && wait_cycles < 8) begin
            @(negedge clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!resp_valid || (resp_tag != 4'h3) ||
            (resp_data != 64'hfeed_face_cafe_beef))
            $fatal(1,
                "resident store lost across fill collision data=%016x",
                resp_data);
        @(posedge clk);

        @(negedge clk);
        invalidate_addr = BASE;
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

        $display("PASS: synchronous L1 hits, same-line store extension data, side-effect breaks, fill collision, and invalidation");
        $finish;
    end

    initial begin
        repeat (200) @(posedge clk);
        $fatal(1, "synchronous-tag L1 test timed out");
    end
endmodule
