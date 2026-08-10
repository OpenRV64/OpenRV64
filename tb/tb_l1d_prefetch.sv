`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/bus/bus-defs.v"

module tb_l1d_prefetch;

    localparam [63:0] MEMORY_BASE = 64'h0000_0000_8000_0000;
    localparam [63:0] MEMORY_SIZE = 64'h0000_0000_0001_0000;

    reg clk;
    reg rst_n;

    reg req_valid;
    wire req_ready;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] req_tag;
    reg req_lock;
    reg req_posted;
    reg req_write;
    reg req_cacheable;
    reg [63:0] req_addr;
    reg [2:0] req_size;
    reg [63:0] req_wdata;
    reg [7:0] req_wstrb;
    wire [63:0] req_rdata;
    wire req_error;
    wire resp_valid;
    reg resp_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] resp_tag;

    wire store_resp_valid;
    wire store_resp_error;
    wire invalidate_ready;
    reg invalidate_valid;
    reg invalidate_all;
    reg [63:0] invalidate_addr;
    reg speculation_barrier;

    wire icx_req_valid;
    wire icx_req_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    wire icx_req_lock;
    wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order;
    wire [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind;
    wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr;
    wire [2:0] icx_req_size;
    wire [63:0] icx_req_addr;
    wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_req_burst_len;

    wire icx_wdata_valid;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_wdata_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_wdata_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_wdata_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_wdata_beat_index;
    wire icx_wdata_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_wdata;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_wstrb;

    reg icx_resp_valid;
    wire icx_resp_ready;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id;
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;

    wire prefetch_issued;
    wire prefetch_useful;
    wire prefetch_late;
    wire prefetch_dropped;
    wire prefetch_useless;
    wire [4:0] prefetch_depth;

    localparam integer RESPONSE_SLOTS = 8;
    reg response_slot_valid_q [0:RESPONSE_SLOTS-1];
    integer response_slot_delay_q [0:RESPONSE_SLOTS-1];
    reg [63:0] response_slot_addr_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        response_slot_hart_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        response_slot_txn_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        response_slot_source_q [0:RESPONSE_SLOTS-1];
    integer response_slot_sequence_q [0:RESPONSE_SLOTS-1];
    reg response_slot_free_found_r;
    reg [2:0] response_slot_free_index_r;
    reg response_slot_ready_found_r;
    reg [2:0] response_slot_ready_index_r;
    reg response_pending_r;
    reg response_older_pending_r;
    reg [2:0] response_active_slot_q;
    integer response_latency_cycles;
    integer response_delay_mode;
    integer response_comb_scan;
    integer response_seq_scan;
    integer total_commands;
    integer demand_commands;
    integer prefetch_commands;
    integer fence_commands;
    integer useful_prefetches;
    integer on_time_useful_prefetches;
    integer late_useful_prefetches;
    integer late_prefetches;
    integer dropped_prefetches;
    integer useless_prefetches;
    integer out_of_order_responses;
    integer max_prefetch_outstanding;
    integer prefetch_wait_cycles;
    integer demand_before_barrier;
    integer useful_before_barrier;
    integer race_response_slot;
    reg race_response_found;
    reg [63:0] last_prefetch_addr;
    reg [63:0] prefetch_command_addr [0:127];
    integer cycles;
    integer long_walk_index;
    integer test_epoch;
    wire [2:0] prefetch_outstanding_count =
        dut.prefetch_mshr_valid_q[0] +
        dut.prefetch_mshr_valid_q[1] +
        dut.prefetch_mshr_valid_q[2] +
        dut.prefetch_mshr_valid_q[3];

    function automatic [63:0] memory_word;
        input [63:0] address;
        begin
            memory_word = address ^ 64'h6d65_6d6f_7279_5a5a;
        end
    endfunction

    function automatic fill_buffer_contains_line;
        input [63:0] address;
        integer fill_index;
        begin
            fill_buffer_contains_line = 1'b0;
            for (fill_index = 0; fill_index < 4;
                 fill_index = fill_index + 1)
                if (dut.fill_buffer_valid_q[fill_index] &&
                    (dut.fill_buffer_addr_q[fill_index] ==
                     {address[63:6], 6'b0}))
                    fill_buffer_contains_line = 1'b1;
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
                    memory_word({address[63:6], 6'b0} + word_index * 8);
        end
    endfunction

    // This instance is 1 KiB, four-way, with four 64-byte sets.  Speculative
    // lines must remain outside the shared L1 until an architectural demand
    // consumes their fill-buffer entry.
    function automatic l1_contains_line;
        input [63:0] address;
        integer resident_way;
        integer resident_line;
        begin
            l1_contains_line = 1'b0;
            for (resident_way = 0; resident_way < 4;
                 resident_way = resident_way + 1) begin
                resident_line = (address[7:6] * 4) + resident_way;
                if (dut.u_l1d.u_l1.g_cache.u_cache
                        .valid_q[resident_line]) begin
                    case (resident_way)
                        0: l1_contains_line =
                            dut.u_l1d.u_l1.g_cache.u_cache
                                .g_sync_tag_storage.g_tag_ways[0]
                                .tag_q[address[7:6]] == address[63:8];
                        1: l1_contains_line =
                            dut.u_l1d.u_l1.g_cache.u_cache
                                .g_sync_tag_storage.g_tag_ways[1]
                                .tag_q[address[7:6]] == address[63:8];
                        2: l1_contains_line =
                            dut.u_l1d.u_l1.g_cache.u_cache
                                .g_sync_tag_storage.g_tag_ways[2]
                                .tag_q[address[7:6]] == address[63:8];
                        3: l1_contains_line =
                            dut.u_l1d.u_l1.g_cache.u_cache
                                .g_sync_tag_storage.g_tag_ways[3]
                                .tag_q[address[7:6]] == address[63:8];
                        default: l1_contains_line = 1'b0;
                    endcase
                end
            end
        end
    endfunction

    function automatic prefetch_command_seen;
        input [63:0] address;
        integer command_index;
        begin
            prefetch_command_seen = 1'b0;
            for (command_index = 0;
                 command_index < prefetch_commands;
                 command_index = command_index + 1)
                if (prefetch_command_addr[command_index] == address)
                    prefetch_command_seen = 1'b1;
        end
    endfunction

    openrv64_l1d_icx #(
        .ENABLE(1),
        .CACHE_BYTES(1024),
        .LINE_BYTES(64),
        .WAYS(4),
        .FILL_BUFFER_LINES(4),
        .STORE_BUFFER_LINES(2),
        .PREFETCH_ENABLE(1),
        .PREFETCH_CACHEABLE_BASE(MEMORY_BASE),
        .PREFETCH_CACHEABLE_SIZE(MEMORY_SIZE),
        .PREFETCH_MAX_STRIDE_LINES(64),
        .PREFETCH_STREAMS(2),
        .PREFETCH_DISTANCE(1),
        .PREFETCH_ADAPTIVE_ENABLE(1),
        .PREFETCH_MAX_DISTANCE(4),
        .PREFETCH_QUEUE_LINES(4),
        .PREFETCH_OUTSTANDING(4),
        .PREFETCH_DEMAND_RESERVE(2),
        .REQ_TAG_WIDTH(`OPENRV64_LSU_TAG_WIDTH),
        .REQ_DEPTH(4)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_tag_i(req_tag),
        .req_lock_i(req_lock),
        .req_posted_i(req_posted),
        .req_write_i(req_write),
        .req_cacheable_i(req_cacheable),
        .req_addr_i(req_addr),
        .req_size_i(req_size),
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
        .store_resp_valid_o(store_resp_valid),
        .store_resp_ready_i(1'b1),
        .store_resp_error_o(store_resp_error),
        .prefetch_issued_o(prefetch_issued),
        .prefetch_useful_o(prefetch_useful),
        .prefetch_late_o(prefetch_late),
        .prefetch_dropped_o(prefetch_dropped),
        .prefetch_useless_o(prefetch_useless),
        .prefetch_depth_o(prefetch_depth),
        .speculation_barrier_i(speculation_barrier),
        .completion_fence_i(1'b0),
        .invalidate_valid_i(invalidate_valid),
        .invalidate_ready_o(invalidate_ready),
        .invalidate_all_i(invalidate_all),
        .invalidate_addr_i(invalidate_addr),
        .icx_req_valid_o(icx_req_valid),
        .icx_req_ready_i(icx_req_ready),
        .icx_req_hart_id_o(icx_req_hart_id),
        .icx_req_txn_id_o(icx_req_txn_id),
        .icx_req_source_id_o(icx_req_source_id),
        .icx_req_op_o(icx_req_op),
        .icx_req_lock_o(icx_req_lock),
        .icx_req_order_o(icx_req_order),
        .icx_req_kind_o(icx_req_kind),
        .icx_req_attr_o(icx_req_attr),
        .icx_req_size_o(icx_req_size),
        .icx_req_addr_o(icx_req_addr),
        .icx_req_burst_len_o(icx_req_burst_len),
        .icx_wdata_valid_o(icx_wdata_valid),
        .icx_wdata_ready_i(1'b1),
        .icx_wdata_hart_id_o(icx_wdata_hart_id),
        .icx_wdata_txn_id_o(icx_wdata_txn_id),
        .icx_wdata_source_id_o(icx_wdata_source_id),
        .icx_wdata_beat_index_o(icx_wdata_beat_index),
        .icx_wdata_last_o(icx_wdata_last),
        .icx_wdata_o(icx_wdata),
        .icx_wstrb_o(icx_wstrb),
        .icx_resp_valid_i(icx_resp_valid),
        .icx_resp_ready_o(icx_resp_ready),
        .icx_resp_hart_id_i(icx_resp_hart_id),
        .icx_resp_txn_id_i(icx_resp_txn_id),
        .icx_resp_source_id_i(icx_resp_source_id),
        .icx_resp_beat_index_i(
            {`OPENRV64_ICX_BEAT_INDEX_WIDTH{1'b0}}),
        .icx_resp_last_i(1'b1),
        .icx_resp_rdata_i(icx_resp_rdata),
        .icx_resp_error_i(1'b0),
        .icx_resp_sc_success_i(1'b0)
    );

    assign icx_req_ready = response_slot_free_found_r;

    always begin
        clk = 1'b0;
        #5;
        clk = 1'b1;
        #5;
    end

    always @* begin
        response_slot_free_found_r = 1'b0;
        response_slot_free_index_r = 3'd0;
        response_slot_ready_found_r = 1'b0;
        response_slot_ready_index_r = 3'd0;
        response_pending_r = 1'b0;
        response_older_pending_r = 1'b0;
        for (response_comb_scan = 0;
             response_comb_scan < RESPONSE_SLOTS;
             response_comb_scan = response_comb_scan + 1) begin
            if (!response_slot_free_found_r &&
                !response_slot_valid_q[response_comb_scan]) begin
                response_slot_free_found_r = 1'b1;
                response_slot_free_index_r = response_comb_scan[2:0];
            end
            if (response_slot_valid_q[response_comb_scan]) begin
                response_pending_r = 1'b1;
                if (icx_resp_valid &&
                    (response_comb_scan != response_active_slot_q) &&
                    (response_slot_sequence_q[response_comb_scan] <
                     response_slot_sequence_q[
                         response_active_slot_q]))
                    response_older_pending_r = 1'b1;
                // Deliberately select the highest ready slot.  With the
                // optional reverse delay this returns prefetches out of order.
                if (response_slot_delay_q[response_comb_scan] == 0) begin
                    response_slot_ready_found_r = 1'b1;
                    response_slot_ready_index_r =
                        response_comb_scan[2:0];
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            icx_resp_valid <= 1'b0;
            response_active_slot_q <= 3'd0;
            icx_resp_hart_id <=
                {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}};
            icx_resp_txn_id <=
                {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
            icx_resp_source_id <=
                `OPENRV64_ICX_SOURCE_DCACHE;
            icx_resp_rdata <=
                {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
            total_commands <= 0;
            demand_commands <= 0;
            prefetch_commands <= 0;
            fence_commands <= 0;
            useful_prefetches <= 0;
            on_time_useful_prefetches <= 0;
            late_useful_prefetches <= 0;
            late_prefetches <= 0;
            dropped_prefetches <= 0;
            useless_prefetches <= 0;
            out_of_order_responses <= 0;
            max_prefetch_outstanding <= 0;
            last_prefetch_addr <= 64'd0;
            for (response_seq_scan = 0;
                 response_seq_scan < RESPONSE_SLOTS;
                 response_seq_scan = response_seq_scan + 1) begin
                response_slot_valid_q[response_seq_scan] <= 1'b0;
                response_slot_delay_q[response_seq_scan] <= 0;
                response_slot_addr_q[response_seq_scan] <= 64'd0;
                response_slot_hart_q[response_seq_scan] <=
                    {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}};
                response_slot_txn_q[response_seq_scan] <=
                    {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
                response_slot_source_q[response_seq_scan] <=
                    {`OPENRV64_ICX_SOURCE_ID_WIDTH{1'b0}};
                response_slot_sequence_q[response_seq_scan] <= 0;
            end
        end else begin
            if (prefetch_useful)
                useful_prefetches <= useful_prefetches + 1;
            if (dut.prefetch_on_time_useful)
                on_time_useful_prefetches <=
                    on_time_useful_prefetches + 1;
            if (dut.prefetch_late_useful)
                late_useful_prefetches <=
                    late_useful_prefetches + 1;
            if (prefetch_late)
                late_prefetches <= late_prefetches + 1;
            if (prefetch_dropped)
                dropped_prefetches <= dropped_prefetches + 1;
            if (prefetch_useless)
                useless_prefetches <= useless_prefetches + 1;
            if (prefetch_outstanding_count >
                max_prefetch_outstanding)
                max_prefetch_outstanding <=
                    prefetch_outstanding_count;

            if (icx_req_valid && icx_req_ready) begin
                if (icx_req_op != `OPENRV64_ICX_OP_READ &&
                    icx_req_op != `OPENRV64_ICX_OP_WRITE &&
                    icx_req_op != `OPENRV64_ICX_OP_FENCE)
                    $fatal(1, "unexpected ICX operation in prefetch test");
                if ((icx_req_op == `OPENRV64_ICX_OP_FENCE) &&
                    (icx_req_size != 3'd0 || icx_wdata_valid))
                    $fatal(1, "malformed ICX fence in prefetch test");
                if (dut.request_prefetch_q &&
                    (icx_req_size != 3'd6 || icx_req_addr[5:0] != 0))
                    $fatal(1, "ICX prefetch is not one aligned cacheline");
                if (icx_req_lock)
                    $fatal(1, "L1D leaked its local atomic marker to ICX");
                if (icx_req_source_id != `OPENRV64_ICX_SOURCE_DCACHE)
                    $fatal(1, "ICX read has wrong source");
                total_commands <= total_commands + 1;
                if (icx_req_op == `OPENRV64_ICX_OP_FENCE) begin
                    fence_commands <= fence_commands + 1;
                end else if (dut.request_prefetch_q) begin
                    prefetch_commands <= prefetch_commands + 1;
                    last_prefetch_addr <= icx_req_addr;
                    prefetch_command_addr[prefetch_commands] <=
                        icx_req_addr;
                end else begin
                    demand_commands <= demand_commands + 1;
                end
                response_slot_valid_q[
                    response_slot_free_index_r] <= 1'b1;
                response_slot_delay_q[
                    response_slot_free_index_r] <=
                    response_latency_cycles +
                    ((response_delay_mode == 1) ?
                     (response_slot_free_index_r * 24) :
                     ((response_delay_mode == 2) ?
                      ((RESPONSE_SLOTS - 1 -
                        response_slot_free_index_r) * 8) : 0));
                response_slot_addr_q[
                    response_slot_free_index_r] <= icx_req_addr;
                response_slot_hart_q[
                    response_slot_free_index_r] <= icx_req_hart_id;
                response_slot_txn_q[
                    response_slot_free_index_r] <= icx_req_txn_id;
                response_slot_source_q[
                    response_slot_free_index_r] <= icx_req_source_id;
                response_slot_sequence_q[
                    response_slot_free_index_r] <= total_commands;
            end

            for (response_seq_scan = 0;
                 response_seq_scan < RESPONSE_SLOTS;
                 response_seq_scan = response_seq_scan + 1)
                if (response_slot_valid_q[response_seq_scan] &&
                    (response_slot_delay_q[response_seq_scan] != 0))
                    response_slot_delay_q[response_seq_scan] <=
                        response_slot_delay_q[response_seq_scan] - 1;

            if (!icx_resp_valid && response_slot_ready_found_r) begin
                response_active_slot_q <= response_slot_ready_index_r;
                icx_resp_hart_id <=
                    response_slot_hart_q[response_slot_ready_index_r];
                icx_resp_txn_id <=
                    response_slot_txn_q[response_slot_ready_index_r];
                icx_resp_source_id <=
                    response_slot_source_q[response_slot_ready_index_r];
                icx_resp_rdata <=
                    memory_line(response_slot_addr_q[
                        response_slot_ready_index_r]);
                icx_resp_valid <= 1'b1;
            end

            if (icx_resp_valid && icx_resp_ready) begin
                if (response_older_pending_r)
                    out_of_order_responses <=
                        out_of_order_responses + 1;
                response_slot_valid_q[response_active_slot_q] <= 1'b0;
                icx_resp_valid <= 1'b0;
            end
        end
    end

    task automatic reset_dut;
        begin
            rst_n = 1'b0;
            req_valid = 1'b0;
            req_tag = {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
            req_lock = 1'b0;
            req_posted = 1'b0;
            req_write = 1'b0;
            req_cacheable = 1'b0;
            req_addr = 64'd0;
            req_size = 3'd3;
            req_wdata = 64'd0;
            req_wstrb = 8'd0;
            resp_ready = 1'b1;
            invalidate_valid = 1'b0;
            invalidate_all = 1'b0;
            invalidate_addr = 64'd0;
            speculation_barrier = 1'b0;
            response_latency_cycles = 4;
            response_delay_mode = 0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            test_epoch = test_epoch + 1;
        end
    endtask

    task automatic issue_locked_store;
        input [63:0] address;
        integer wait_cycles;
        begin
            @(negedge clk);
            resp_ready = 1'b0;
            req_valid = 1'b1;
            req_lock = 1'b1;
            req_write = 1'b1;
            req_cacheable = 1'b1;
            req_addr = address;
            req_wdata = 64'h0123_4567_89ab_cdef;
            req_wstrb = 8'hff;
            req_tag = test_epoch[`OPENRV64_LSU_TAG_WIDTH-1:0];
            wait_cycles = 0;
            #1;
            while (!req_ready && wait_cycles < 400) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "atomic store acceptance timed out addr=%016x",
                       address);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_lock = 1'b0;
            req_write = 1'b0;
            req_cacheable = 1'b0;
            req_addr = 64'd0;
            req_wdata = 64'd0;
            req_wstrb = 8'd0;
            wait_cycles = 0;
            while (!resp_valid && wait_cycles < 400) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            #1;
            if (!resp_valid || req_error)
                $fatal(1, "atomic store response failed addr=%016x",
                       address);
            resp_ready = 1'b1;
            @(posedge clk);
        end
    endtask

    task automatic issue_locked_load;
        input [63:0] address;
        integer wait_cycles;
        begin
            @(negedge clk);
            resp_ready = 1'b0;
            req_valid = 1'b1;
            req_lock = 1'b1;
            req_write = 1'b0;
            req_cacheable = 1'b1;
            req_addr = address;
            req_tag = test_epoch[`OPENRV64_LSU_TAG_WIDTH-1:0];
            wait_cycles = 0;
            #1;
            while (!req_ready && wait_cycles < 400) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "atomic load acceptance timed out addr=%016x",
                       address);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_lock = 1'b0;
            req_cacheable = 1'b0;
            req_addr = 64'd0;
            wait_cycles = 0;
            while (!resp_valid && wait_cycles < 400) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            #1;
            if (!resp_valid)
                $fatal(1,
                    "atomic load response timed out addr=%016x backend=%0d l1mem=%0d icxresp=%0d pending=%0d commands=%0d demand=%0d prefetch=%0d tags=%0d l1resp=%0d active=%0d invalidated=%0d",
                    address, dut.backend_state_q, dut.l1_mem_valid,
                    icx_resp_valid, response_pending_r, total_commands,
                    demand_commands, prefetch_commands,
                    dut.response_tag_count_q, dut.l1_resp_valid,
                    dut.atomic_active_q, dut.locked_line_invalidated_q);
            if (req_error || req_rdata !== memory_word(address))
                $fatal(1,
                    "atomic load data=%016x expected=%016x error=%0d",
                    req_rdata, memory_word(address), req_error);
            resp_ready = 1'b1;
            @(posedge clk);
        end
    endtask

    task automatic issue_load;
        input [63:0] address;
        integer wait_cycles;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_write = 1'b0;
            req_cacheable = 1'b1;
            req_addr = address;
            req_tag = test_epoch[`OPENRV64_LSU_TAG_WIDTH-1:0];
            wait_cycles = 0;
            #1;
            while (!req_ready && wait_cycles < 200) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "load acceptance timed out addr=%016x", address);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_cacheable = 1'b0;
            req_addr = 64'd0;
            wait_cycles = 0;
            while (!resp_valid && wait_cycles < 400) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            #1;
            if (!resp_valid)
                $fatal(1, "load response timed out addr=%016x", address);
            if (req_error)
                $fatal(1, "load returned error addr=%016x", address);
            if (req_rdata !== memory_word(address))
                $fatal(1,
                    "load data=%016x expected=%016x addr=%016x",
                    req_rdata, memory_word(address), address);
            @(posedge clk);
        end
    endtask

    task automatic issue_posted_store;
        input [63:0] address;
        input [63:0] data;
        integer wait_cycles;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_posted = 1'b1;
            req_write = 1'b1;
            req_cacheable = 1'b1;
            req_addr = address;
            req_wdata = data;
            req_wstrb = 8'hff;
            req_tag = test_epoch[`OPENRV64_LSU_TAG_WIDTH-1:0];
            wait_cycles = 0;
            #1;
            while (!req_ready && wait_cycles < 400) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!req_ready)
                $fatal(1, "posted store acceptance timed out addr=%016x",
                       address);
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_posted = 1'b0;
            req_write = 1'b0;
            req_cacheable = 1'b0;
            req_addr = 64'd0;
            req_wdata = 64'd0;
            req_wstrb = 8'd0;
        end
    endtask

    task automatic wait_for_prefetch;
        input [63:0] expected_address;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (((prefetch_commands == 0) ||
                    (last_prefetch_addr != expected_address)) &&
                   wait_cycles < 400) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (last_prefetch_addr != expected_address)
                $fatal(1,
                    "prefetch address=%016x expected=%016x",
                    last_prefetch_addr, expected_address);
            while ((response_pending_r || icx_resp_valid ||
                    (dut.backend_state_q != 0)) &&
                   wait_cycles < 800) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles >= 800)
                $fatal(1, "prefetch completion timed out");
        end
    endtask

    task automatic wait_for_prefetch_quiescence;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while ((response_pending_r || icx_resp_valid ||
                    (dut.backend_state_q != 0) ||
                    (prefetch_outstanding_count != 0) ||
                    dut.prefetch_candidate_valid_q[0] ||
                    dut.prefetch_candidate_valid_q[1] ||
                    dut.prefetch_candidate_valid_q[2] ||
                    dut.prefetch_candidate_valid_q[3]) &&
                   (wait_cycles < 2000)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles >= 2000)
                $fatal(1, "adaptive prefetch quiescence timed out");
        end
    endtask

    task automatic invalidate_line;
        input [63:0] address;
        integer wait_cycles;
        begin
            @(negedge clk);
            invalidate_valid = 1'b1;
            invalidate_all = 1'b0;
            invalidate_addr = address;
            wait_cycles = 0;
            while (!invalidate_ready && wait_cycles < 200) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!invalidate_ready)
                $fatal(1, "invalidation timed out");
            @(posedge clk);
            @(negedge clk);
            invalidate_valid = 1'b0;
            invalidate_addr = 64'd0;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        test_epoch = 0;
        if ((dut.MAIN_TXN_COUNT != 12) ||
            (dut.PREFETCH_TXN_BASE != 4'd12))
            $fatal(1,
                "4-bit transaction IDs did not partition as 12 main / 4 prefetch");

        // A store can be accepted on the exact cycle that a queued same-line
        // prefetch launches.  Both operations may cross their interfaces;
        // the prefetch transaction must be poisoned so its old line cannot
        // enter the speculative fill buffer.
        reset_dut();
        response_latency_cycles = 16;
        @(negedge clk);
        req_valid = 1'b1;
        req_write = 1'b0;
        req_cacheable = 1'b1;
        req_addr = MEMORY_BASE + 64'h0d00;
        req_tag = test_epoch[`OPENRV64_LSU_TAG_WIDTH-1:0];
        prefetch_wait_cycles = 0;
        #1;
        while (!req_ready && prefetch_wait_cycles < 200) begin
            @(negedge clk);
            prefetch_wait_cycles = prefetch_wait_cycles + 1;
        end
        if (!req_ready)
            $fatal(1, "prefetch/store collision seed load timed out");
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        req_cacheable = 1'b0;
        req_addr = 64'd0;
        prefetch_wait_cycles = 0;
        while (!dut.prefetch_launch &&
               prefetch_wait_cycles < 200) begin
            @(negedge clk);
            prefetch_wait_cycles = prefetch_wait_cycles + 1;
        end
        if (!dut.prefetch_launch ||
            (dut.prefetch_launch_addr_r !=
             MEMORY_BASE + 64'h0d40))
            $fatal(1,
                "same-line collision candidate missing launch=%0d addr=%016x",
                dut.prefetch_launch, dut.prefetch_launch_addr_r);
        req_valid = 1'b1;
        req_posted = 1'b1;
        req_write = 1'b1;
        req_cacheable = 1'b1;
        req_addr = MEMORY_BASE + 64'h0d40;
        req_wdata = 64'h0123_4567_89ab_cdef;
        req_wstrb = 8'hff;
        req_tag = test_epoch + 1;
        #1;
        if (!req_ready)
            $fatal(1, "same-line collision store was not ready");
        if (!dut.prefetch_launch)
            $fatal(1,
                "parallel prefetch/store race did not launch both sides");
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        req_posted = 1'b0;
        req_write = 1'b0;
        req_cacheable = 1'b0;
        req_addr = 64'd0;
        req_wdata = 64'd0;
        req_wstrb = 8'd0;
        repeat (80) @(negedge clk);
        if (!prefetch_command_seen(MEMORY_BASE + 64'h0d40))
            $fatal(1,
                "parallel same-line prefetch did not reach ICX");
        if (fill_buffer_contains_line(MEMORY_BASE + 64'h0d40))
            $fatal(1,
                "parallel prefetch/store response installed stale fill");

        // A full line FIFO must backpressure another posted store rather
        // than retaining it as hidden state in the shared L1.  A same-line
        // prefetch which is already in flight may complete while that store
        // remains pending; the response must be discarded immediately.
        reset_dut();
        response_latency_cycles = 400;
        issue_posted_store(MEMORY_BASE + 64'h0e00,
                           64'h1111_1111_1111_1111);
        issue_posted_store(MEMORY_BASE + 64'h0e40,
                           64'h2222_2222_2222_2222);
        prefetch_wait_cycles = 0;
        while ((dut.store_buffer_count_q != 2) &&
               (prefetch_wait_cycles < 100)) begin
            @(negedge clk);
            prefetch_wait_cycles = prefetch_wait_cycles + 1;
        end
        if (dut.store_buffer_count_q != 2)
            $fatal(1, "prefetch race setup did not fill store buffer");

        // Train the next-line candidate without waiting for the detached
        // demand miss to return.
        @(negedge clk);
        req_valid = 1'b1;
        req_write = 1'b0;
        req_cacheable = 1'b1;
        req_addr = MEMORY_BASE + 64'h0f00;
        req_tag = test_epoch[`OPENRV64_LSU_TAG_WIDTH-1:0];
        prefetch_wait_cycles = 0;
        #1;
        while (!req_ready && prefetch_wait_cycles < 100) begin
            @(negedge clk);
            prefetch_wait_cycles = prefetch_wait_cycles + 1;
        end
        if (!req_ready)
            $fatal(1, "held-store prefetch seed load timed out");
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        req_cacheable = 1'b0;
        req_addr = 64'd0;

        prefetch_wait_cycles = 0;
        while (!prefetch_command_seen(MEMORY_BASE + 64'h0f40) &&
               (prefetch_wait_cycles < 200)) begin
            @(negedge clk);
            prefetch_wait_cycles = prefetch_wait_cycles + 1;
        end
        if (!prefetch_command_seen(MEMORY_BASE + 64'h0f40))
            $fatal(1,
                "backpressured-store race has no in-flight prefetch");

        @(negedge clk);
        req_valid = 1'b1;
        req_posted = 1'b1;
        req_write = 1'b1;
        req_cacheable = 1'b1;
        req_addr = MEMORY_BASE + 64'h0f40;
        req_wdata = 64'h3333_3333_3333_3333;
        req_wstrb = 8'hff;
        req_tag = test_epoch[`OPENRV64_LSU_TAG_WIDTH-1:0];
        #1;
        if (req_ready)
            $fatal(1, "full store buffer accepted a hidden store");

        // Force the old prefetch line back while the store is visibly valid
        // but still unaccepted.
        race_response_found = 1'b0;
        race_response_slot = 0;
        for (cycles = 0; cycles < RESPONSE_SLOTS;
             cycles = cycles + 1) begin
            if (response_slot_valid_q[cycles] &&
                (response_slot_addr_q[cycles] ==
                 MEMORY_BASE + 64'h0f40)) begin
                response_slot_delay_q[cycles] = 0;
                race_response_found = 1'b1;
                race_response_slot = cycles;
            end
        end
        if (!race_response_found)
            $fatal(1, "could not locate in-flight prefetch response");
        prefetch_wait_cycles = 0;
        while ((response_slot_valid_q[race_response_slot] ||
                (icx_resp_valid &&
                 (icx_resp_txn_id ==
                  response_slot_txn_q[race_response_slot]))) &&
               (prefetch_wait_cycles < 20)) begin
            @(negedge clk);
            prefetch_wait_cycles = prefetch_wait_cycles + 1;
            #1;
            if (req_ready)
                $fatal(1,
                    "store became ready before poisoned fill returned");
        end
        if (prefetch_wait_cycles >= 20)
            $fatal(1, "forced prefetch response did not complete");
        if (fill_buffer_contains_line(MEMORY_BASE + 64'h0f40))
            $fatal(1,
                "backpressured store allowed stale prefetch fill");

        // Release the older store responses and hold the request until the
        // newly available explicit FIFO slot accepts it.
        for (cycles = 0; cycles < RESPONSE_SLOTS;
             cycles = cycles + 1)
            if (response_slot_valid_q[cycles])
                response_slot_delay_q[cycles] = 0;
        prefetch_wait_cycles = 0;
        while (!req_ready && (prefetch_wait_cycles < 400)) begin
            @(negedge clk);
            prefetch_wait_cycles = prefetch_wait_cycles + 1;
        end
        if (!req_ready)
            $fatal(1, "backpressured posted store never obtained a slot");
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        req_posted = 1'b0;
        req_write = 1'b0;
        req_cacheable = 1'b0;
        req_addr = 64'd0;
        req_wdata = 64'd0;
        req_wstrb = 8'd0;

        // A first demand creates a next-line candidate.  The following demand
        // must consume that buffered line without another demand ICX read.
        reset_dut();
        issue_load(MEMORY_BASE + 64'h0000);
        wait_for_prefetch(MEMORY_BASE + 64'h0040);
        if (demand_commands != 1 || prefetch_commands != 1)
            $fatal(1, "unexpected next-line command counts d=%0d p=%0d",
                   demand_commands, prefetch_commands);
        if (l1_contains_line(MEMORY_BASE + 64'h0040))
            $fatal(1, "speculative line polluted L1 before core demand");
        issue_load(MEMORY_BASE + 64'h0040);
        if (demand_commands != 1 || useful_prefetches != 1 ||
            !l1_contains_line(MEMORY_BASE + 64'h0040))
            $fatal(1, "next-line prefetch was not consumed");
        issue_load(MEMORY_BASE + 64'h0040);
        if (demand_commands != 1 || useful_prefetches != 1)
            $fatal(1, "demand-promoted prefetch did not become an L1 hit");

        // A stream may probe exactly one line across a physical 4 KiB
        // boundary. Deeper lines remain held until an architectural demand
        // consumes that probe as a useful prefetch; then the complete
        // preserved depth window is restored.
        reset_dut();
        issue_load(MEMORY_BASE + 64'h3f00);
        issue_load(MEMORY_BASE + 64'h3f40);
        issue_load(MEMORY_BASE + 64'h3f80);
        issue_load(MEMORY_BASE + 64'h3fc0);
        wait_for_prefetch(MEMORY_BASE + 64'h4000);
        repeat (40) @(posedge clk);
        if (prefetch_depth != 4)
            $fatal(1,
                "boundary stream did not reach full adaptive depth depth=%0d",
                prefetch_depth);
        if (!prefetch_command_seen(MEMORY_BASE + 64'h4000) ||
            prefetch_command_seen(MEMORY_BASE + 64'h4040) ||
            prefetch_command_seen(MEMORY_BASE + 64'h4080))
            $fatal(1,
                "forward boundary probe did not hold deeper predictions");
        if (!dut.prefetch_train_valid_q[0] ||
            !dut.prefetch_stride_valid_q[0] ||
            !dut.prefetch_generation_active_q[0] ||
            !dut.prefetch_stream_page_end[0] ||
            !dut.prefetch_boundary_probe_wait_q[0] ||
            dut.prefetch_stream_long_q[0] ||
            (dut.prefetch_last_line_q[0] !=
             MEMORY_BASE + 64'h3fc0))
            $fatal(1, "forward stream was not paused at page boundary");
        useful_before_barrier = useful_prefetches;
        issue_load(MEMORY_BASE + 64'h4000);
        wait_for_prefetch_quiescence();
        if (useful_prefetches != useful_before_barrier + 1)
            $fatal(1, "forward boundary probe was not useful");
        if (!prefetch_command_seen(MEMORY_BASE + 64'h4040) ||
            !prefetch_command_seen(MEMORY_BASE + 64'h4080) ||
            !prefetch_command_seen(MEMORY_BASE + 64'h40c0) ||
            !prefetch_command_seen(MEMORY_BASE + 64'h4100))
            $fatal(1,
                "boundary resume did not restore full depth window depth=%0d",
                prefetch_depth);
        if (!dut.prefetch_train_valid_q[0] ||
            dut.prefetch_stream_page_end[0] ||
            dut.prefetch_boundary_probe_wait_q[0] ||
            !dut.prefetch_stream_long_q[0] ||
            (dut.prefetch_last_line_q[0] !=
             MEMORY_BASE + 64'h4000))
            $fatal(1, "forward stream did not resume after demand");

        // Once a stream earns long status, a later page crossing restores
        // the full current distance immediately instead of probing again.
        for (long_walk_index = 0; long_walk_index < 61;
             long_walk_index = long_walk_index + 1)
            issue_load(MEMORY_BASE + 64'h4040 +
                       long_walk_index * 64);
        wait_for_prefetch_quiescence();
        if (!prefetch_command_seen(MEMORY_BASE + 64'h5000) ||
            !prefetch_command_seen(MEMORY_BASE + 64'h5040) ||
            dut.prefetch_boundary_probe_wait_q[0] ||
            !dut.prefetch_stream_long_q[0])
            $fatal(1,
                "long second crossing seen5000=%0d seen5040=%0d wait=%0d/%0d long=%0d/%0d depth=%0d last=%016x/%016x valid=%0d/%0d prefetches=%0d useful=%0d useless=%0d",
                prefetch_command_seen(MEMORY_BASE + 64'h5000),
                prefetch_command_seen(MEMORY_BASE + 64'h5040),
                dut.prefetch_boundary_probe_wait_q[0],
                dut.prefetch_boundary_probe_wait_q[1],
                dut.prefetch_stream_long_q[0],
                dut.prefetch_stream_long_q[1], prefetch_depth,
                dut.prefetch_last_line_q[0],
                dut.prefetch_last_line_q[1],
                dut.prefetch_train_valid_q[0],
                dut.prefetch_train_valid_q[1], prefetch_commands,
                useful_prefetches, useless_prefetches);
        issue_load(MEMORY_BASE + 64'h4f80);
        issue_load(MEMORY_BASE + 64'h4fc0);
        issue_load(MEMORY_BASE + 64'h5000);
        issue_load(MEMORY_BASE + 64'h5040);
        if (!dut.prefetch_stream_long_q[0] ||
            !dut.prefetch_stride_valid_q[0] ||
            (dut.prefetch_stride_q[0] != 64))
            $fatal(1,
                "later boundary demand restarted long stream long=%0d stride_valid=%0d stride=%0d",
                dut.prefetch_stream_long_q[0],
                dut.prefetch_stride_valid_q[0],
                dut.prefetch_stride_q[0]);
        issue_load(MEMORY_BASE + 64'h5200);
        if (dut.prefetch_stream_long_q[0])
            $fatal(1,
                "stride change retained long permission last=%016x stride=%0d valid=%0d confidence=%0d",
                dut.prefetch_last_line_q[0],
                dut.prefetch_stride_q[0],
                dut.prefetch_stride_valid_q[0],
                dut.prefetch_confidence_q[0]);

        // The same probe/hold/release rule applies to a negative stride.
        reset_dut();
        issue_load(MEMORY_BASE + 64'h4080);
        issue_load(MEMORY_BASE + 64'h4040);
        issue_load(MEMORY_BASE + 64'h4000);
        wait_for_prefetch(MEMORY_BASE + 64'h3fc0);
        repeat (40) @(posedge clk);
        if (!prefetch_command_seen(MEMORY_BASE + 64'h3fc0) ||
            prefetch_command_seen(MEMORY_BASE + 64'h3f80))
            $fatal(1,
                "reverse boundary probe did not hold deeper predictions");
        if (!dut.prefetch_train_valid_q[0] ||
            !dut.prefetch_stream_page_end[0] ||
            !dut.prefetch_boundary_probe_wait_q[0] ||
            dut.prefetch_stream_long_q[0])
            $fatal(1, "reverse stream was not paused at page boundary");
        useful_before_barrier = useful_prefetches;
        issue_load(MEMORY_BASE + 64'h3fc0);
        wait_for_prefetch_quiescence();
        if (useful_prefetches != useful_before_barrier + 1)
            $fatal(1, "reverse boundary probe was not useful");
        if (!dut.prefetch_stream_long_q[0])
            $fatal(1, "reverse useful probe did not earn long status");
        if (!prefetch_command_seen(MEMORY_BASE + 64'h3f80))
            wait_for_prefetch(MEMORY_BASE + 64'h3f80);

        // Two equal non-unit deltas train one history entry.  Earlier
        // observations use the conservative next-line fallback.
        reset_dut();
        issue_load(MEMORY_BASE + 64'h1000);
        wait_for_prefetch(MEMORY_BASE + 64'h1040);
        issue_load(MEMORY_BASE + 64'h1100);
        wait_for_prefetch(MEMORY_BASE + 64'h1140);
        issue_load(MEMORY_BASE + 64'h1200);
        wait_for_prefetch(MEMORY_BASE + 64'h1300);
        issue_load(MEMORY_BASE + 64'h1300);
        if (useful_prefetches != 1)
            $fatal(1, "trained stride prefetch was not consumed");

        // Speculative data must not survive an accepted invalidation.
        reset_dut();
        issue_load(MEMORY_BASE + 64'h2000);
        wait_for_prefetch(MEMORY_BASE + 64'h2040);
        invalidate_line(MEMORY_BASE + 64'h2040);
        issue_load(MEMORY_BASE + 64'h2040);
        if (demand_commands != 2 || useful_prefetches != 0)
            $fatal(1, "invalidation did not discard prefetched line");

        // A translation/speculation barrier cuts the read epoch. An
        // architectural read-miss buffer which already crossed ICX must
        // consume its old response without completing L1 and then reissue.
        reset_dut();
        response_latency_cycles = 24;
        fork
            issue_load(MEMORY_BASE + 64'h2400);
            begin
                while (demand_commands < 1)
                    @(negedge clk);
                repeat (2) @(negedge clk);
                speculation_barrier = 1'b1;
                @(posedge clk);
                @(negedge clk);
                speculation_barrier = 1'b0;
            end
        join
        if ((demand_commands != 2) ||
            (dut.speculation_epoch_q != 1))
            $fatal(1,
                "barrier did not reissue old RMB commands=%0d epoch=%0d",
                demand_commands, dut.speculation_epoch_q);

        // An old speculative MSHR still consumes its response, but the
        // response cannot populate a fill buffer or satisfy a later demand.
        reset_dut();
        response_latency_cycles = 32;
        issue_load(MEMORY_BASE + 64'h2800);
        while (prefetch_commands < 1)
            @(negedge clk);
        speculation_barrier = 1'b1;
        @(posedge clk);
        @(negedge clk);
        speculation_barrier = 1'b0;
        wait_for_prefetch_quiescence();
        issue_load(MEMORY_BASE + 64'h2840);
        if ((demand_commands != 2) || (useful_prefetches != 0))
            $fatal(1,
                "old-epoch prefetch survived barrier d=%0d useful=%0d",
                demand_commands, useful_prefetches);

        // The address aperture prevents next-line speculation into MMIO or an
        // adjacent physical region.
        reset_dut();
        issue_load(MEMORY_BASE + MEMORY_SIZE - 64);
        repeat (40) @(posedge clk);
        if (prefetch_commands != 0)
            $fatal(1, "prefetch escaped configured cacheable aperture");

        // AMO admission is the same epoch barrier as a translation
        // shootdown. It must discard unrelated speculative reads which were
        // already accepted by ICX before the marked read arrived.
        reset_dut();
        response_latency_cycles = 32;
        issue_load(MEMORY_BASE + 64'h7000);
        while (prefetch_commands < 1)
            @(negedge clk);
        issue_locked_load(MEMORY_BASE + 64'h6008);
        issue_locked_store(MEMORY_BASE + 64'h6008);
        wait_for_prefetch_quiescence();
        demand_before_barrier = demand_commands;
        useful_before_barrier = useful_prefetches;
        issue_load(MEMORY_BASE + 64'h7040);
        if ((demand_commands != demand_before_barrier + 1) ||
            (useful_prefetches != useful_before_barrier))
            $fatal(1,
                "AMO barrier retained old speculative fill d=%0d/%0d useful=%0d/%0d",
                demand_commands, demand_before_barrier,
                useful_prefetches, useful_before_barrier);

        // A synchronization access pauses prefetch issue through its complete
        // read/write interval and marks its line as atomic-hot.  A later
        // ordinary stream must not train or speculate into that line.
        reset_dut();
        issue_locked_load(MEMORY_BASE + 64'h6008);
        repeat (40) @(posedge clk);
        if (prefetch_commands != 0 || !dut.atomic_active_q ||
            (dut.atomic_active_line_q != MEMORY_BASE + 64'h6000))
            $fatal(1, "prefetch did not remain paused between AMO phases");
        if (!dut.atomic_hot_match(MEMORY_BASE + 64'h6000))
            $fatal(1, "atomic line was not entered in hot-line metadata");
        issue_locked_store(MEMORY_BASE + 64'h6008);
        if (dut.atomic_active_q)
            $fatal(1, "prefetch remained paused after AMO write completion");
        issue_load(MEMORY_BASE + 64'h5fc0);
        repeat (40) @(posedge clk);
        if (prefetch_commands != 0)
            $fatal(1, "prefetch speculated into an atomic-hot line");

        // Alternate two disjoint +4-line read streams.  A single global
        // history observes large cross-array deltas here and cannot train
        // either stride.  The two-entry table must preserve both histories
        // and issue the next address from each.
        reset_dut();
        issue_load(MEMORY_BASE + 64'h4000);
        issue_load(MEMORY_BASE + 64'h8000);
        issue_load(MEMORY_BASE + 64'h4100);
        issue_load(MEMORY_BASE + 64'h8100);
        issue_load(MEMORY_BASE + 64'h4200);
        issue_load(MEMORY_BASE + 64'h8200);
        wait_for_prefetch_quiescence();
        if (!(dut.prefetch_train_valid_q[0] &&
              dut.prefetch_train_valid_q[1] &&
              dut.prefetch_stride_valid_q[0] &&
              dut.prefetch_stride_valid_q[1] &&
              (dut.prefetch_stride_q[0] == 64'sh100) &&
              (dut.prefetch_stride_q[1] == 64'sh100) &&
              (((dut.prefetch_last_line_q[0] ==
                  MEMORY_BASE + 64'h4200) &&
                (dut.prefetch_last_line_q[1] ==
                  MEMORY_BASE + 64'h8200)) ||
               ((dut.prefetch_last_line_q[1] ==
                  MEMORY_BASE + 64'h4200) &&
                (dut.prefetch_last_line_q[0] ==
                  MEMORY_BASE + 64'h8200)))))
            $fatal(1, "interleaved loads did not retain two stride histories");
        if (!prefetch_command_seen(MEMORY_BASE + 64'h4300) ||
            !prefetch_command_seen(MEMORY_BASE + 64'h8300))
            $fatal(1,
                "interleaved streams did not prefetch both next addresses");
        issue_load(MEMORY_BASE + 64'h4300);
        issue_load(MEMORY_BASE + 64'h8300);
        if (useful_prefetches != 2)
            $fatal(1,
                "interleaved stream prefetches were not both useful count=%0d",
                useful_prefetches);

        // The first late demand raises depth 1->2.  Detached demand misses
        // then let the next two prefetches launch while that demand remains
        // live.  With staggered response slots the younger 0x3080 prefetch
        // returns before 0x3040, so the second access is useful rather than
        // late.  This checks that an older demand no longer blocks independent
        // prefetch MSHRs and that the depth-two rolling window retains every
        // nearer line.
        reset_dut();
        response_latency_cycles = 16;
        response_delay_mode = 1;
        issue_load(MEMORY_BASE + 64'h3000);
        issue_load(MEMORY_BASE + 64'h3040);
        if (prefetch_depth != 2 || late_prefetches != 1)
            $fatal(1,
                "first late prefetch did not raise depth to two depth=%0d late=%0d",
                prefetch_depth, late_prefetches);
        issue_load(MEMORY_BASE + 64'h3080);
        if (prefetch_depth != 2 || late_prefetches != 1 ||
            useful_prefetches != 2)
            $fatal(1,
                "independent prefetch did not get ahead depth=%0d late=%0d useful=%0d",
                prefetch_depth, late_prefetches, useful_prefetches);
        if (max_prefetch_outstanding < 2)
            $fatal(1, "prefetch ICX path never had multiple requests live");
        prefetch_wait_cycles = 0;
        while ((prefetch_commands < 4) &&
               (prefetch_wait_cycles < 100)) begin
            @(negedge clk);
            prefetch_wait_cycles = prefetch_wait_cycles + 1;
        end
        if (prefetch_commands < 4 ||
            prefetch_command_addr[0] != MEMORY_BASE + 64'h3040 ||
            prefetch_command_addr[1] != MEMORY_BASE + 64'h3080 ||
            prefetch_command_addr[2] != MEMORY_BASE + 64'h30c0 ||
            prefetch_command_addr[3] != MEMORY_BASE + 64'h3100)
            $fatal(1,
                "adaptive window skipped/reordered a near line p=%0d %x %x %x %x depth=%0d active=%0d candidates=%b%b%b%b outstanding=%0d backend=%0d",
                prefetch_commands, prefetch_command_addr[0],
                prefetch_command_addr[1], prefetch_command_addr[2],
                prefetch_command_addr[3], prefetch_depth,
                dut.atomic_active_q,
                dut.prefetch_candidate_valid_q[3],
                dut.prefetch_candidate_valid_q[2],
                dut.prefetch_candidate_valid_q[1],
                dut.prefetch_candidate_valid_q[0],
                prefetch_outstanding_count, dut.backend_state_q);
        wait_for_prefetch_quiescence();
        // Leave several unrelated next-line predictions unused so the
        // bounded fill buffer must replace speculative lines and exercise
        // adaptive-depth decay even though the deeper rolling window got
        // ahead of the second demand above.
        issue_load(MEMORY_BASE + 64'h9000);
        wait_for_prefetch_quiescence();
        issue_load(MEMORY_BASE + 64'ha000);
        wait_for_prefetch_quiescence();
        issue_load(MEMORY_BASE + 64'hb000);
        wait_for_prefetch_quiescence();
        issue_load(MEMORY_BASE + 64'hc000);
        wait_for_prefetch_quiescence();
        $display("adaptive stats p=%0d useful=%0d late=%0d useless=%0d depth=%0d ooo=%0d",
                 prefetch_commands, useful_prefetches, late_prefetches,
                 useless_prefetches, prefetch_depth,
                 out_of_order_responses);
        if (out_of_order_responses == 0)
            $fatal(1, "staggered ICX responses never exercised ID matching");
        if (useless_prefetches < 2 || prefetch_depth > 2)
            $fatal(1,
                "unused speculative replacements did not reduce depth useless=%0d depth=%0d",
                useless_prefetches, prefetch_depth);
        if (useful_prefetches !=
            on_time_useful_prefetches + late_useful_prefetches)
            $fatal(1,
                "prefetch useful categories do not sum total=%0d ontime=%0d late=%0d",
                useful_prefetches, on_time_useful_prefetches,
                late_useful_prefetches);

        $display("PASS: L1D two-stream adaptive prefetch, ICX MSHRs, and decay");
        $finish;
    end

    initial begin
        cycles = 0;
        forever begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cycles > 5000)
                $fatal(1, "L1D prefetch test timeout");
        end
    end

endmodule
