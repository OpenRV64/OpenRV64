`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/bus/bus-defs.v"

module tb_l1d_demand_mshr #(
    parameter integer RETIRED_STORE_MSHR_CANONICAL = 0
);

    localparam [63:0] MEMORY_BASE = 64'h0000_0000_8000_0000;
    localparam integer DEMAND_MSHRS = 3;
    localparam integer TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH;
    localparam integer TAG_COUNT = 1 << TAG_WIDTH;

    reg clk;
    reg rst_n;

    reg req_valid;
    wire req_ready;
    reg [TAG_WIDTH-1:0] req_tag;
    reg req_write;
    reg [63:0] req_addr;
    reg [63:0] req_wdata;
    reg [7:0] req_wstrb;
    wire [63:0] req_rdata;
    wire req_error;
    wire resp_valid;
    reg resp_ready;
    wire [TAG_WIDTH-1:0] resp_tag;

    reg icx_resp_valid;
    wire icx_resp_ready;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;

    wire icx_req_valid;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    wire [2:0] icx_req_size;
    wire [63:0] icx_req_addr;

    wire unused_store_resp_valid;
    wire unused_store_resp_error;
    wire unused_store_barrier_busy;
    wire unused_invalidate_ready;
    wire unused_prefetch_issued;
    wire unused_prefetch_useful;
    wire unused_prefetch_late;
    wire unused_prefetch_dropped;
    wire unused_prefetch_useless;
    wire [4:0] unused_prefetch_depth;
    wire unused_icx_req_lock;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        unused_icx_req_hart_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        unused_icx_req_source_id;
    wire [`OPENRV64_ICX_ORDER_WIDTH-1:0]
        unused_icx_req_order;
    wire [`OPENRV64_ICX_KIND_WIDTH-1:0]
        unused_icx_req_kind;
    wire [`OPENRV64_ICX_ATTR_WIDTH-1:0]
        unused_icx_req_attr;
    wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
        unused_icx_req_burst_len;
    wire unused_icx_wdata_valid;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        unused_icx_wdata_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        unused_icx_wdata_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        unused_icx_wdata_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        unused_icx_wdata_beat_index;
    wire unused_icx_wdata_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        unused_icx_wdata;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        unused_icx_wstrb;

    integer command_count;
    reg [63:0] command_addr [0:15];
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] command_txn [0:15];
    integer store_command_count;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] store_command_txn;
    integer completion_count;
    reg expected_valid [0:TAG_COUNT-1];
    reg [63:0] expected_data [0:TAG_COUNT-1];
    reg completion_seen [0:TAG_COUNT-1];
    integer reset_index;
    integer cycles;
    reg [TAG_WIDTH-1:0] held_resp_tag;
    reg [63:0] held_resp_data;
    reg overlay_fill_seen;
    localparam [63:0] OVERLAY_STORE_DATA =
        64'hfeed_face_0123_4567;

    function automatic [63:0] memory_word;
        input [63:0] address;
        begin
            memory_word = address ^ 64'h4d53_4852_5f44_4154;
        end
    endfunction

    function automatic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] memory_line;
        input [63:0] address;
        integer word_index;
        begin
            memory_line = {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
            for (word_index = 0; word_index < 8;
                 word_index = word_index + 1)
                memory_line[word_index*64 +: 64] =
                    memory_word({address[63:6], 6'b0} +
                                word_index * 8);
        end
    endfunction

    openrv64_l1d_icx #(
        .ENABLE(1),
        .CACHE_BYTES(1024),
        .LINE_BYTES(64),
        .WAYS(4),
        .FILL_BUFFER_LINES(4),
        .DEMAND_MSHRS(DEMAND_MSHRS),
        .RETIRED_STORE_MSHR_CANONICAL(
            RETIRED_STORE_MSHR_CANONICAL),
        .STORE_BUFFER_LINES(2),
        .PREFETCH_ENABLE(0),
        .REQ_TAG_WIDTH(TAG_WIDTH),
        .REQ_DEPTH(TAG_COUNT)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_tag_i(req_tag),
        .req_lock_i(1'b0),
        .req_posted_i(1'b0),
        .req_write_i(req_write),
        .req_cacheable_i(1'b1),
        .req_addr_i(req_addr),
        .req_size_i(3'd3),
        .req_wdata_i(req_wdata),
        .req_wstrb_i(req_wstrb),
        .req_rdata_o(req_rdata),
        .req_error_o(req_error),
        .resp_valid_o(resp_valid),
        .resp_ready_i(resp_ready),
        .resp_tag_o(resp_tag),
        .posted_resp_valid_o(),
        .posted_resp_ready_i(1'b1),
        .posted_resp_tag_o(),
        .store_resp_valid_o(unused_store_resp_valid),
        .store_resp_ready_i(1'b1),
        .store_resp_error_o(unused_store_resp_error),
        .prefetch_issued_o(unused_prefetch_issued),
        .prefetch_useful_o(unused_prefetch_useful),
        .prefetch_late_o(unused_prefetch_late),
        .prefetch_dropped_o(unused_prefetch_dropped),
        .prefetch_useless_o(unused_prefetch_useless),
        .prefetch_depth_o(unused_prefetch_depth),
        .speculation_barrier_i(1'b0),
        .completion_fence_i(1'b0),
        .store_barrier_busy_o(unused_store_barrier_busy),
        .invalidate_valid_i(1'b0),
        .invalidate_ready_o(unused_invalidate_ready),
        .invalidate_all_i(1'b0),
        .invalidate_addr_i(64'd0),
        .icx_req_valid_o(icx_req_valid),
        .icx_req_ready_i(1'b1),
        .icx_req_hart_id_o(unused_icx_req_hart_id),
        .icx_req_txn_id_o(icx_req_txn_id),
        .icx_req_source_id_o(unused_icx_req_source_id),
        .icx_req_op_o(icx_req_op),
        .icx_req_lock_o(unused_icx_req_lock),
        .icx_req_order_o(unused_icx_req_order),
        .icx_req_kind_o(unused_icx_req_kind),
        .icx_req_attr_o(unused_icx_req_attr),
        .icx_req_size_o(icx_req_size),
        .icx_req_addr_o(icx_req_addr),
        .icx_req_burst_len_o(unused_icx_req_burst_len),
        .icx_wdata_valid_o(unused_icx_wdata_valid),
        .icx_wdata_ready_i(1'b1),
        .icx_wdata_hart_id_o(unused_icx_wdata_hart_id),
        .icx_wdata_txn_id_o(unused_icx_wdata_txn_id),
        .icx_wdata_source_id_o(unused_icx_wdata_source_id),
        .icx_wdata_beat_index_o(unused_icx_wdata_beat_index),
        .icx_wdata_last_o(unused_icx_wdata_last),
        .icx_wdata_o(unused_icx_wdata),
        .icx_wstrb_o(unused_icx_wstrb),
        .icx_resp_valid_i(icx_resp_valid),
        .icx_resp_ready_o(icx_resp_ready),
        .icx_resp_hart_id_i(
            {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}}),
        .icx_resp_txn_id_i(icx_resp_txn_id),
        .icx_resp_source_id_i(`OPENRV64_ICX_SOURCE_DCACHE),
        .icx_resp_beat_index_i(
            {`OPENRV64_ICX_BEAT_INDEX_WIDTH{1'b0}}),
        .icx_resp_last_i(1'b1),
        .icx_resp_rdata_i(icx_resp_rdata),
        .icx_resp_error_i(1'b0),
        .icx_resp_sc_success_i(1'b0)
    );

    always begin
        clk = 1'b0;
        #5;
        clk = 1'b1;
        #5;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            command_count <= 0;
            store_command_count <= 0;
            completion_count <= 0;
            overlay_fill_seen <= 1'b0;
            for (reset_index = 0; reset_index < TAG_COUNT;
                 reset_index = reset_index + 1) begin
                expected_valid[reset_index] <= 1'b0;
                expected_data[reset_index] <= 64'd0;
                completion_seen[reset_index] <= 1'b0;
            end
        end else begin
            if (icx_req_valid) begin
                if (icx_req_size != 3'd6 ||
                    icx_req_addr[5:0] != 0)
                    $fatal(1, "L1D emitted malformed ICX command");
                if (icx_req_op == `OPENRV64_ICX_OP_READ) begin
                    command_addr[command_count] <= icx_req_addr;
                    command_txn[command_count] <= icx_req_txn_id;
                    command_count <= command_count + 1;
                end else if (icx_req_op ==
                             `OPENRV64_ICX_OP_WRITE) begin
                    store_command_txn <= icx_req_txn_id;
                    store_command_count <= store_command_count + 1;
                end else begin
                    $fatal(1, "L1D emitted unexpected ICX operation");
                end
            end
            if (resp_valid && resp_ready) begin
                if (!expected_valid[resp_tag])
                    $fatal(1,
                        "unexpected or duplicate response tag=%0d",
                        resp_tag);
                if (req_error)
                    $fatal(1, "demand response tag=%0d returned error",
                           resp_tag);
                if (req_rdata !== expected_data[resp_tag])
                    $fatal(1,
                        "response tag=%0d data=%016x expected=%016x",
                        resp_tag, req_rdata, expected_data[resp_tag]);
                expected_valid[resp_tag] <= 1'b0;
                completion_seen[resp_tag] <= 1'b1;
                completion_count <= completion_count + 1;
            end
            if (dut.l1_fill_fire &&
                (dut.l1_fill_addr == MEMORY_BASE) &&
                (dut.l1_fill_data[63:0] !== OVERLAY_STORE_DATA))
                $fatal(1,
                    "late same-line store was absent from installed fill");
            if (dut.l1_fill_fire &&
                (dut.l1_fill_addr == MEMORY_BASE))
                overlay_fill_seen <= 1'b1;
        end
    end

    task automatic issue_load;
        input [TAG_WIDTH-1:0] tag;
        input [63:0] address;
        integer wait_cycles;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_tag = tag;
            req_write = 1'b0;
            req_addr = address;
            req_wdata = 64'd0;
            req_wstrb = 8'd0;
            expected_valid[tag] = 1'b1;
            expected_data[tag] = memory_word(address);
            completion_seen[tag] = 1'b0;
            wait_cycles = 0;
            #1;
            while (!req_ready && wait_cycles < 100) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "load tag=%0d acceptance timed out", tag);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_addr = 64'd0;
        end
    endtask

    task automatic issue_store;
        input [TAG_WIDTH-1:0] tag;
        input [63:0] address;
        input [63:0] data;
        integer wait_cycles;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_tag = tag;
            req_write = 1'b1;
            req_addr = address;
            req_wdata = data;
            req_wstrb = 8'hff;
            expected_valid[tag] = 1'b1;
            expected_data[tag] = 64'd0;
            completion_seen[tag] = 1'b0;
            wait_cycles = 0;
            #1;
            while (!req_ready && wait_cycles < 100) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "store tag=%0d acceptance timed out", tag);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_write = 1'b0;
            req_addr = 64'd0;
            req_wdata = 64'd0;
            req_wstrb = 8'd0;
        end
    endtask

    task automatic wait_for_commands;
        input integer expected;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (command_count < expected && wait_cycles < 100) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (command_count != expected)
                $fatal(1, "ICX commands=%0d expected=%0d",
                       command_count, expected);
        end
    endtask

    task automatic return_command;
        input integer command_index;
        integer wait_cycles;
        begin
            @(negedge clk);
            icx_resp_valid = 1'b1;
            icx_resp_txn_id = command_txn[command_index];
            icx_resp_rdata = memory_line(command_addr[command_index]);
            wait_cycles = 0;
            #1;
            while (!icx_resp_ready && wait_cycles < 100) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!icx_resp_ready)
                $fatal(1, "ICX response %0d was not accepted",
                       command_index);
            @(posedge clk);
            @(negedge clk);
            icx_resp_valid = 1'b0;
            icx_resp_txn_id =
                {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
            icx_resp_rdata =
                {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
        end
    endtask

    task automatic return_store;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (store_command_count == 0 &&
                   wait_cycles < 100) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (store_command_count != 1)
                $fatal(1, "store commands=%0d expected=1",
                       store_command_count);
            @(negedge clk);
            icx_resp_valid = 1'b1;
            icx_resp_txn_id = store_command_txn;
            icx_resp_rdata =
                {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
            wait_cycles = 0;
            #1;
            while (!icx_resp_ready && wait_cycles < 100) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!icx_resp_ready)
                $fatal(1, "store ICX response was not accepted");
            @(posedge clk);
            @(negedge clk);
            icx_resp_valid = 1'b0;
            icx_resp_txn_id =
                {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
        end
    endtask

    task automatic wait_for_completions;
        input integer expected;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (completion_count < expected &&
                   wait_cycles < 200) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (completion_count != expected)
                $fatal(1, "completions=%0d expected=%0d",
                       completion_count, expected);
        end
    endtask

    task check_retired_store_mshr_canonical;
        reg [63:0] line_addr;
        reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] initial_overlay;
        reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] initial_strb;
        reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] expected_line;
        begin
            line_addr = MEMORY_BASE + 64'ha040;
            initial_overlay =
                {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
            initial_overlay[2*64 +: 64] = OVERLAY_STORE_DATA;
            initial_strb =
                {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b0}};
            initial_strb[2*8 +: 8] = 8'hff;
            expected_line = memory_line(line_addr);
            expected_line[2*64 +: 64] = OVERLAY_STORE_DATA;

            // Model a load miss behind an older retirement-authorized store.
            // The store-buffer snapshot is folded into the newly allocated
            // MSHR while the lower response remains outstanding.
            resp_ready = 1'b0;
            force dut.l1_fill_fire = 1'b0;
            force dut.l1_miss_fire = 1'b1;
            force dut.l1_miss_tag = TAG_WIDTH'(0);
            force dut.l1_miss_epoch = 0;
            force dut.l1_miss_addr = line_addr;
            force dut.l1_miss_store_data = initial_overlay;
            force dut.l1_miss_store_strb = initial_strb;
            force dut.demand_mshr_match_found_r = 1'b0;
            force dut.demand_mshr_free_index_r = 0;
            force dut.demand_prefetch_fill_hit_r = 1'b0;
            force dut.prefetch_response_claim_new = 1'b0;
            @(posedge clk);
            #1;
            release dut.l1_miss_fire;
            release dut.l1_miss_tag;
            release dut.l1_miss_epoch;
            release dut.l1_miss_addr;
            release dut.l1_miss_store_data;
            release dut.l1_miss_store_strb;
            release dut.demand_mshr_match_found_r;
            release dut.demand_mshr_free_index_r;
            release dut.demand_prefetch_fill_hit_r;
            release dut.prefetch_response_claim_new;
            if (!dut.demand_mshr_valid_q[0] ||
                (dut.demand_mshr_data_q[0][2*64 +: 64] !==
                 OVERLAY_STORE_DATA) ||
                (dut.demand_mshr_store_strb_q[0] !== initial_strb))
                $fatal(1,
                    "canonical MSHR allocation lost the older-store snapshot");

            // The already-authorized store can have reached the L1 write stage
            // before the load but complete there after the miss allocation.
            // That delayed fragment must update the canonical MSHR payload,
            // not allocate another line-sized overlay.
            dut.active_req_cacheable_q = 1'b1;
            dut.active_req_lock_q = 1'b0;
            force dut.l1_mem_valid = 1'b1;
            force dut.l1_mem_write = 1'b1;
            force dut.l1_mem_ready = 1'b1;
            force dut.l1_mem_error = 1'b0;
            force dut.l1_mem_addr = line_addr + 64'd24;
            force dut.l1_mem_wdata = 64'h0123_4567_89ab_cdef;
            force dut.l1_mem_wstrb = 8'hff;
            @(posedge clk);
            #1;
            release dut.l1_mem_valid;
            release dut.l1_mem_write;
            release dut.l1_mem_ready;
            release dut.l1_mem_error;
            release dut.l1_mem_addr;
            release dut.l1_mem_wdata;
            release dut.l1_mem_wstrb;
            initial_strb[3*8 +: 8] = 8'hff;
            expected_line[3*64 +: 64] = 64'h0123_4567_89ab_cdef;
            if ((dut.demand_mshr_data_q[0][3*64 +: 64] !==
                 64'h0123_4567_89ab_cdef) ||
                (dut.demand_mshr_store_strb_q[0] !== initial_strb))
                $fatal(1,
                    "delayed retired store did not update canonical MSHR state");

            // A stale lower line must preserve both captured store words and
            // consume the temporary byte-valid mask exactly once.
            icx_resp_rdata = memory_line(line_addr);
            dut.demand_mshr_issued_q[0] = 1'b1;
            dut.demand_mshr_reissue_q[0] = 1'b0;
            dut.demand_mshr_epoch_q[0] = dut.speculation_epoch_q;
            dut.demand_mshr_txn_id_q[0] = 0;
            dut.main_txn_in_use_q[0] = 1'b1;
            force dut.demand_mshr_response_fire = 1'b1;
            force dut.demand_mshr_response_index_r = 0;
            @(posedge clk);
            #1;
            release dut.demand_mshr_response_fire;
            release dut.demand_mshr_response_index_r;
            if (!dut.demand_mshr_complete_q[0] ||
                (dut.demand_mshr_data_q[0] !== expected_line) ||
                (dut.demand_mshr_store_strb_q[0] !== 0))
                $fatal(1,
                    "canonical MSHR lower-response merge was incorrect");

            dut.demand_mshr_fill_done_q[0] = 1'b1;
            dut.tag_overlay_word_q[0] = 3'd2;
            #1;
            if (!dut.demand_response_valid ||
                dut.demand_overlay_needed ||
                (req_rdata !== OVERLAY_STORE_DATA))
                $fatal(1,
                    "canonical MSHR response still depended on per-waiter overlay");
            dut.tag_overlay_word_q[0] = 3'd3;
            #1;
            if ((req_rdata !== 64'h0123_4567_89ab_cdef))
                $fatal(1,
                    "canonical MSHR response lost the delayed store word");

            release dut.l1_fill_fire;
            $display(
                "PASS: retirement-authorized stores use one canonical MSHR data line");
        end
    endtask

    initial begin
        rst_n = 1'b0;
        req_valid = 1'b0;
        req_tag = {TAG_WIDTH{1'b0}};
        req_write = 1'b0;
        req_addr = 64'd0;
        req_wdata = 64'd0;
        req_wstrb = 8'd0;
        resp_ready = 1'b1;
        icx_resp_valid = 1'b0;
        icx_resp_txn_id =
            {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
        icx_resp_rdata =
            {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        if (RETIRED_STORE_MSHR_CANONICAL != 0) begin
            check_retired_store_mshr_canonical();
            $finish;
        end

        // Three independent lines allocate all three demand MSHRs before any
        // lower-level response returns.
        issue_load(TAG_WIDTH'(0), MEMORY_BASE + 64'h0000);
        issue_load(TAG_WIDTH'(1), MEMORY_BASE + 64'h1040);
        issue_load(TAG_WIDTH'(2), MEMORY_BASE + 64'h2080);
        wait_for_commands(3);
        if (command_addr[0] != MEMORY_BASE + 64'h0000 ||
            command_addr[1] != MEMORY_BASE + 64'h1040 ||
            command_addr[2] != MEMORY_BASE + 64'h2080)
            $fatal(1, "demand commands were reordered or misaddressed");
        if (command_txn[0] == command_txn[1] ||
            command_txn[0] == command_txn[2] ||
            command_txn[1] == command_txn[2])
            $fatal(1, "concurrent demand MSHRs reused a transaction ID");

        // A fourth unique line must backpressure while all entries remain
        // live.  The request is deliberately withdrawn without a handshake.
        @(negedge clk);
        req_valid = 1'b1;
        req_tag = TAG_WIDTH'(3);
        req_addr = MEMORY_BASE + 64'h30c0;
        #1;
        repeat (4) begin
            if (req_ready)
                $fatal(1, "fourth unique miss bypassed a full MSHR set");
            @(negedge clk);
            #1;
        end
        req_valid = 1'b0;
        req_addr = 64'd0;

        // Free one MSHR first, but leave the MEMORY_BASE miss outstanding.
        // This keeps the store test focused on same-line fill integration
        // rather than coupling it to full-MSHR backpressure.
        return_command(2);
        wait_for_completions(1);

        // A younger store to an outstanding line must update eventual cache
        // installation without forwarding into the older load response.
        issue_store(TAG_WIDTH'(3), MEMORY_BASE, OVERLAY_STORE_DATA);
        return_store();
        wait_for_completions(2);

        // Return the lines in reverse/mixed order.  Tag-qualified completion
        // must still associate each word with its original requester.
        return_command(0);
        return_command(1);
        wait_for_completions(4);
        if (!completion_seen[0] || !completion_seen[1] ||
            !completion_seen[2])
            $fatal(1, "not every independent demand completed");
        if (!overlay_fill_seen)
            $fatal(1, "same-line store overlay was never installed");

        // Two words from one absent line share one ICX transaction but retain
        // independent response tags and word selection.
        issue_load(TAG_WIDTH'(4), MEMORY_BASE + 64'h4000);
        issue_load(TAG_WIDTH'(5), MEMORY_BASE + 64'h4008);
        wait_for_commands(4);
        repeat (4) @(negedge clk);
        if (command_count != 4)
            $fatal(1, "same-line demands launched duplicate ICX reads");
        return_command(3);
        wait_for_completions(6);
        if (!completion_seen[4] || !completion_seen[5])
            $fatal(1, "same-line merged waiters did not both complete");

        // A completed miss may install its line while the northbound response
        // is backpressured, but tag and data must remain stable.
        resp_ready = 1'b0;
        issue_load(TAG_WIDTH'(6), MEMORY_BASE + 64'h5040);
        wait_for_commands(5);
        return_command(4);
        while (!resp_valid)
            @(negedge clk);
        held_resp_tag = resp_tag;
        held_resp_data = req_rdata;
        repeat (4) begin
            @(negedge clk);
            if (!resp_valid || resp_tag != held_resp_tag ||
                req_rdata !== held_resp_data)
                $fatal(1,
                    "backpressured demand response was not held stable");
        end
        resp_ready = 1'b1;
        wait_for_completions(7);

        // The installed line must subsequently hit without another ICX read.
        issue_load(TAG_WIDTH'(7), MEMORY_BASE + 64'h5048);
        wait_for_completions(8);
        if (command_count != 5)
            $fatal(1, "resident line reissued a demand ICX read");

        // A synchronous fill probe must reserve its MSHR selection. Reproduce
        // the Linux failure: entry 1 starts the probe, then lower-index entry
        // 0 completes before ready. Address and data must remain from entry 1
        // through the handshake.
        @(negedge clk);
        rst_n = 1'b0;
        req_valid = 1'b0;
        resp_ready = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        dut.demand_mshr_valid_q[0] = 1'b0;
        dut.demand_mshr_issued_q[0] = 1'b1;
        dut.demand_mshr_complete_q[0] = 1'b0;
        dut.demand_mshr_fill_done_q[0] = 1'b0;
        dut.demand_mshr_wait_prefetch_q[0] = 1'b0;
        dut.demand_mshr_error_q[0] = 1'b0;
        dut.demand_mshr_epoch_q[0] = 0;
        dut.demand_mshr_addr_q[0] = MEMORY_BASE + 64'h7040;
        dut.demand_mshr_data_q[0] =
            memory_line(MEMORY_BASE + 64'h7040);
        dut.demand_mshr_store_data_q[0] =
            {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
        dut.demand_mshr_store_strb_q[0] =
            {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b0}};
        dut.demand_mshr_valid_q[1] = 1'b1;
        dut.demand_mshr_issued_q[1] = 1'b1;
        dut.demand_mshr_complete_q[1] = 1'b1;
        dut.demand_mshr_fill_done_q[1] = 1'b0;
        dut.demand_mshr_wait_prefetch_q[1] = 1'b0;
        dut.demand_mshr_error_q[1] = 1'b0;
        dut.demand_mshr_epoch_q[1] = 0;
        dut.demand_mshr_addr_q[1] = MEMORY_BASE + 64'h8040;
        dut.demand_mshr_data_q[1] =
            memory_line(MEMORY_BASE + 64'h8040);
        dut.demand_mshr_store_data_q[1] =
            {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
        dut.demand_mshr_store_strb_q[1] =
            {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b0}};
        @(posedge clk);
        #1;
        if (!dut.demand_mshr_fill_hold_valid_q ||
            (dut.demand_mshr_fill_hold_index_q != 1))
            $fatal(1, "fill did not reserve initial MSHR selection");
        @(negedge clk);
        dut.demand_mshr_valid_q[0] = 1'b1;
        dut.demand_mshr_complete_q[0] = 1'b1;
        #1;
        if (!dut.l1_fill_valid ||
            (dut.l1_fill_addr != MEMORY_BASE + 64'h8040) ||
            (dut.l1_fill_data !== memory_line(MEMORY_BASE + 64'h8040)))
            $fatal(1, "younger completion replaced held fill payload");
        while (!dut.l1_fill_fire) begin
            @(negedge clk);
            #1;
            if (dut.l1_fill_addr != MEMORY_BASE + 64'h8040 ||
                dut.l1_fill_data !== memory_line(MEMORY_BASE + 64'h8040))
                $fatal(1, "fill payload changed while awaiting ready");
        end
        @(posedge clk);
        #1;
        if (dut.demand_mshr_fill_hold_valid_q)
            $fatal(1, "fill reservation remained busy after handshake");

        // Response retirement and a younger same-line miss can coincide.
        // The registered other-waiter scan cannot see the waiter being
        // attached on that edge, so response cleanup must not free its MSHR.
        // Construct the exact internal boundary directly: the surrounding
        // request/fill machinery is covered above, while this regression is
        // specifically about nonblocking allocation/cleanup priority.
        @(negedge clk);
        rst_n = 1'b0;
        req_valid = 1'b0;
        resp_ready = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        dut.demand_mshr_valid_q[0] = 1'b1;
        dut.demand_mshr_issued_q[0] = 1'b0;
        dut.demand_mshr_complete_q[0] = 1'b1;
        dut.demand_mshr_fill_done_q[0] = 1'b1;
        dut.demand_mshr_wait_prefetch_q[0] = 1'b0;
        dut.demand_mshr_addr_q[0] = MEMORY_BASE + 64'h6040;
        dut.demand_mshr_data_q[0] =
            memory_line(MEMORY_BASE + 64'h6040);
        dut.demand_mshr_store_data_q[0] =
            {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
        dut.demand_mshr_store_strb_q[0] =
            {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b0}};
        dut.demand_waiter_valid_q[3] = 1'b1;
        dut.demand_waiter_mshr_q[3] = 0;
        dut.demand_waiter_epoch_q[3] = 0;
        force dut.l1_miss_fire = 1'b1;
        force dut.l1_miss_tag = TAG_WIDTH'(0);
        force dut.l1_miss_epoch = 4'd1;
        force dut.l1_miss_addr = MEMORY_BASE + 64'h6040;
        force dut.l1_miss_store_data =
            {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
        force dut.l1_miss_store_strb =
            {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b0}};
        force dut.demand_mshr_match_found_r = 1'b1;
        force dut.demand_mshr_match_index_r = 0;
        force dut.demand_response_fire = 1'b1;
        force dut.demand_waiter_response_tag_r = TAG_WIDTH'(3);
        force dut.demand_waiter_response_mshr_r = 0;
        force dut.demand_waiter_other_found_r = 1'b0;
        force dut.l1_fill_fire = 1'b0;
        @(posedge clk);
        #1;
        release dut.l1_miss_fire;
        release dut.l1_miss_tag;
        release dut.l1_miss_epoch;
        release dut.l1_miss_addr;
        release dut.l1_miss_store_data;
        release dut.l1_miss_store_strb;
        release dut.demand_mshr_match_found_r;
        release dut.demand_mshr_match_index_r;
        release dut.demand_response_fire;
        release dut.demand_waiter_response_tag_r;
        release dut.demand_waiter_response_mshr_r;
        release dut.demand_waiter_other_found_r;
        release dut.l1_fill_fire;
        if (!dut.demand_mshr_valid_q[0] ||
            !dut.demand_waiter_valid_q[0] ||
            (dut.demand_waiter_mshr_q[0] != 0) ||
            dut.demand_waiter_valid_q[3])
            $fatal(1,
                "same-cycle response cleanup dropped incoming waiter");

        $display(
            "PASS: demand MSHRs, OOO matching, merge, store overlay, stable fill selection, hold, and response/attach race");
        $finish;
    end

    initial begin
        cycles = 0;
        forever begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cycles > 2000)
                $fatal(1, "L1D demand MSHR test timed out");
        end
    end

endmodule
