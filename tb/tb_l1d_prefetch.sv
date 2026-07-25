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

    wire ccx_req_valid;
    wire ccx_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op;
    wire ccx_req_lock;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr;
    wire [2:0] ccx_req_size;
    wire [63:0] ccx_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] ccx_req_burst_len;

    wire ccx_wdata_valid;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_wdata_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_wdata_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_wdata_beat_index;
    wire ccx_wdata_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] ccx_wstrb;

    reg ccx_resp_valid;
    wire ccx_resp_ready;
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id;
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata;

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
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        response_slot_hart_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        response_slot_txn_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
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
    integer useful_prefetches;
    integer late_prefetches;
    integer dropped_prefetches;
    integer useless_prefetches;
    integer out_of_order_responses;
    integer max_prefetch_outstanding;
    integer prefetch_wait_cycles;
    integer demand_before_barrier;
    integer useful_before_barrier;
    reg [63:0] last_prefetch_addr;
    reg [63:0] prefetch_command_addr [0:63];
    integer cycles;
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

    function automatic [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] memory_line;
        input [63:0] address;
        integer word_index;
        begin
            memory_line = {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
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
                        .valid_q[resident_line] &&
                    (dut.u_l1d.u_l1.g_cache.u_cache
                        .tag_q[resident_line] == address[63:8]))
                    l1_contains_line = 1'b1;
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

    openrv64_l1d_ccx #(
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
        .invalidate_valid_i(invalidate_valid),
        .invalidate_ready_o(invalidate_ready),
        .invalidate_all_i(invalidate_all),
        .invalidate_addr_i(invalidate_addr),
        .ccx_req_valid_o(ccx_req_valid),
        .ccx_req_ready_i(ccx_req_ready),
        .ccx_req_hart_id_o(ccx_req_hart_id),
        .ccx_req_txn_id_o(ccx_req_txn_id),
        .ccx_req_source_id_o(ccx_req_source_id),
        .ccx_req_op_o(ccx_req_op),
        .ccx_req_lock_o(ccx_req_lock),
        .ccx_req_order_o(ccx_req_order),
        .ccx_req_kind_o(ccx_req_kind),
        .ccx_req_attr_o(ccx_req_attr),
        .ccx_req_size_o(ccx_req_size),
        .ccx_req_addr_o(ccx_req_addr),
        .ccx_req_burst_len_o(ccx_req_burst_len),
        .ccx_wdata_valid_o(ccx_wdata_valid),
        .ccx_wdata_ready_i(1'b1),
        .ccx_wdata_hart_id_o(ccx_wdata_hart_id),
        .ccx_wdata_txn_id_o(ccx_wdata_txn_id),
        .ccx_wdata_source_id_o(ccx_wdata_source_id),
        .ccx_wdata_beat_index_o(ccx_wdata_beat_index),
        .ccx_wdata_last_o(ccx_wdata_last),
        .ccx_wdata_o(ccx_wdata),
        .ccx_wstrb_o(ccx_wstrb),
        .ccx_resp_valid_i(ccx_resp_valid),
        .ccx_resp_ready_o(ccx_resp_ready),
        .ccx_resp_hart_id_i(ccx_resp_hart_id),
        .ccx_resp_txn_id_i(ccx_resp_txn_id),
        .ccx_resp_source_id_i(ccx_resp_source_id),
        .ccx_resp_beat_index_i(
            {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}}),
        .ccx_resp_last_i(1'b1),
        .ccx_resp_rdata_i(ccx_resp_rdata),
        .ccx_resp_error_i(1'b0),
        .ccx_resp_sc_success_i(1'b0)
    );

    assign ccx_req_ready = response_slot_free_found_r;

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
                if (ccx_resp_valid &&
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
            ccx_resp_valid <= 1'b0;
            response_active_slot_q <= 3'd0;
            ccx_resp_hart_id <=
                {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}};
            ccx_resp_txn_id <=
                {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
            ccx_resp_source_id <=
                `OPENRV64_CCX_SOURCE_DCACHE;
            ccx_resp_rdata <=
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            total_commands <= 0;
            demand_commands <= 0;
            prefetch_commands <= 0;
            useful_prefetches <= 0;
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
                    {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}};
                response_slot_txn_q[response_seq_scan] <=
                    {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
                response_slot_source_q[response_seq_scan] <=
                    {`OPENRV64_CCX_SOURCE_ID_WIDTH{1'b0}};
                response_slot_sequence_q[response_seq_scan] <= 0;
            end
        end else begin
            if (prefetch_useful)
                useful_prefetches <= useful_prefetches + 1;
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

            if (ccx_req_valid && ccx_req_ready) begin
                if (ccx_req_op != `OPENRV64_CCX_OP_READ &&
                    ccx_req_op != `OPENRV64_CCX_OP_WRITE)
                    $fatal(1, "unexpected CCX operation in prefetch test");
                if (dut.request_prefetch_q &&
                    (ccx_req_size != 3'd6 || ccx_req_addr[5:0] != 0))
                    $fatal(1, "CCX prefetch is not one aligned cacheline");
                if (ccx_req_lock)
                    $fatal(1, "L1D leaked its local atomic marker to CCX");
                if (ccx_req_source_id != `OPENRV64_CCX_SOURCE_DCACHE)
                    $fatal(1, "CCX read has wrong source");
                total_commands <= total_commands + 1;
                if (dut.request_prefetch_q) begin
                    prefetch_commands <= prefetch_commands + 1;
                    last_prefetch_addr <= ccx_req_addr;
                    prefetch_command_addr[prefetch_commands] <=
                        ccx_req_addr;
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
                    response_slot_free_index_r] <= ccx_req_addr;
                response_slot_hart_q[
                    response_slot_free_index_r] <= ccx_req_hart_id;
                response_slot_txn_q[
                    response_slot_free_index_r] <= ccx_req_txn_id;
                response_slot_source_q[
                    response_slot_free_index_r] <= ccx_req_source_id;
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

            if (!ccx_resp_valid && response_slot_ready_found_r) begin
                response_active_slot_q <= response_slot_ready_index_r;
                ccx_resp_hart_id <=
                    response_slot_hart_q[response_slot_ready_index_r];
                ccx_resp_txn_id <=
                    response_slot_txn_q[response_slot_ready_index_r];
                ccx_resp_source_id <=
                    response_slot_source_q[response_slot_ready_index_r];
                ccx_resp_rdata <=
                    memory_line(response_slot_addr_q[
                        response_slot_ready_index_r]);
                ccx_resp_valid <= 1'b1;
            end

            if (ccx_resp_valid && ccx_resp_ready) begin
                if (response_older_pending_r)
                    out_of_order_responses <=
                        out_of_order_responses + 1;
                response_slot_valid_q[response_active_slot_q] <= 1'b0;
                ccx_resp_valid <= 1'b0;
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
                    "atomic load response timed out addr=%016x backend=%0d l1mem=%0d ccxresp=%0d pending=%0d commands=%0d demand=%0d prefetch=%0d tags=%0d l1resp=%0d active=%0d invalidated=%0d",
                    address, dut.backend_state_q, dut.l1_mem_valid,
                    ccx_resp_valid, response_pending_r, total_commands,
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
            while ((response_pending_r || ccx_resp_valid ||
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
            while ((response_pending_r || ccx_resp_valid ||
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

        // A first demand creates a next-line candidate.  The following demand
        // must consume that buffered line without another demand CCX read.
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
        // architectural read-miss buffer which already crossed CCX must
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
        // already accepted by CCX before the marked read arrived.
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
            $fatal(1, "prefetch CCX path never had multiple requests live");
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
            $fatal(1, "staggered CCX responses never exercised ID matching");
        if (useless_prefetches < 2 || prefetch_depth > 2)
            $fatal(1,
                "unused speculative replacements did not reduce depth useless=%0d depth=%0d",
                useless_prefetches, prefetch_depth);

        $display("PASS: L1D two-stream adaptive prefetch, CCX MSHRs, and decay");
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
