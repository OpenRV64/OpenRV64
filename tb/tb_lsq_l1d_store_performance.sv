`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"

// Store-pressure benchmark spanning the architectural LSQ boundary and the
// complete L1D controller.  Sparse traffic tests whether the queues hide tag
// latency; dense traffic tests sustained ordered-store admission.  The
// page-clear phase uses consecutive 8-byte stores into cold lines, matching
// the kernel __memset fallback used when Zicboz is not advertised.
module lsq_l1d_store_performance_runner #(
    parameter integer SYNC_TAG_LOOKUP = 0,
    parameter integer ITERATIONS = 4096
) (
    input  wire clk_i,
    input  wire rst_ni,
    output reg  done_o,
    output integer sparse_cycles_o,
    output integer sparse_access_wait_o,
    output integer sparse_queue_full_o,
    output integer sparse_lsq_max_o,
    output integer sparse_store_buffer_max_o,
    output integer dense_cycles_o,
    output integer dense_access_wait_o,
    output integer dense_queue_full_o,
    output integer dense_lsq_max_o,
    output integer dense_store_buffer_max_o,
    output integer clear_cycles_o,
    output integer clear_access_wait_o,
    output integer clear_queue_full_o,
    output integer clear_lsq_max_o,
    output integer clear_store_buffer_max_o,
    output integer clear_store_extensions_o,
    output integer clear_fast_merges_o,
    output integer clear_icx_writes_o
);
    localparam integer ID_WIDTH = `OPENRV64_INSTR_ID_WIDTH;
    localparam integer TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH;
    localparam integer RETIRE_SLOT_WIDTH = 3;
    localparam integer META_WIDTH = 1;
    localparam integer LOAD_QUEUE_DEPTH = 4;
    localparam integer STORE_QUEUE_DEPTH = 4;
    localparam integer RESPONSE_SLOTS = 16;
    localparam integer RESPONSE_DELAY = 6;
    localparam integer SPARSE_GAP = 7;
    localparam [63:0] BASE = 64'h0000_0000_8000_0000;
    localparam [63:0] CACHEABLE_SIZE = 64'h0000_0000_0010_0000;

    reg local_rst_n;
    wire dut_rst_n = rst_ni && local_rst_n;
    reg phase_active;
    reg phase_page_clear;
    integer phase_gap;
    integer phase_allocated_q;
    integer phase_retired_q;
    integer issue_cooldown_q;
    integer cycle_count_q;
    integer store_buffer_max_q;
    integer icx_write_count_q;
    integer icx_response_count_q;
    integer page_clear_word;

    wire store_alloc_valid = phase_active &&
                             (phase_allocated_q < ITERATIONS) &&
                             (issue_cooldown_q == 0);
    wire store_alloc_ready;
    wire store_alloc_fire = store_alloc_valid && store_alloc_ready;
    wire [ID_WIDTH-1:0] store_alloc_id =
        ID_WIDTH'(phase_allocated_q);
    wire [63:0] store_alloc_addr = BASE +
        (phase_page_clear ?
         (phase_allocated_q * 8) :
         ((phase_allocated_q & 63) * 64));
    wire [63:0] store_alloc_data =
        64'h5a00_0000_0000_0000 ^ 64'(phase_allocated_q);
    wire ordered_head_valid = phase_active &&
                              (phase_retired_q < phase_allocated_q);
    wire [ID_WIDTH-1:0] ordered_head_id = ID_WIDTH'(phase_retired_q);

    wire lsq_req_valid;
    wire lsq_req_ready;
    wire [TAG_WIDTH-1:0] lsq_req_tag;
    wire lsq_req_write;
    wire [63:0] lsq_req_addr;
    wire [63:0] lsq_req_wdata;
    wire [7:0] lsq_req_wstrb;
    wire lsq_resp_ready;
    wire lsq_store_done_ready;
    wire lsq_result_valid;
    wire [ID_WIDTH-1:0] lsq_result_id;
    wire lsq_result_access_fault;
    wire lsq_result_page_fault;
    wire lsq_result_store;
    wire lsq_posted_complete_valid;
    wire [ID_WIDTH-1:0] lsq_posted_complete_id;
    wire [RETIRE_SLOT_WIDTH-1:0] lsq_posted_complete_slot;
    wire lsq_empty;
    wire result_fire = lsq_posted_complete_valid;
    wire xlate_req_valid;
    wire [TAG_WIDTH-1:0] xlate_req_tag;
    wire xlate_req_write;
    wire [2:0] xlate_req_size;
    wire [63:0] xlate_req_vaddr;

    wire l1d_resp_valid;
    wire [TAG_WIDTH-1:0] l1d_resp_tag;
    wire [63:0] l1d_resp_data;
    wire l1d_resp_error;
    wire l1d_posted_resp_valid;
    wire [TAG_WIDTH-1:0] l1d_posted_resp_tag;
    wire l1d_store_resp_valid;
    wire l1d_store_resp_error;
    reg speculation_barrier;
    wire store_barrier_busy;

    wire icx_req_valid;
    wire icx_req_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    wire [2:0] icx_req_size;
    wire [63:0] icx_req_addr;
    wire icx_wdata_valid;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_wdata;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_wstrb;
    wire icx_resp_valid;
    wire icx_resp_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id;

    reg response_slot_valid_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        response_hart_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        response_txn_q [0:RESPONSE_SLOTS-1];
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        response_source_q [0:RESPONSE_SLOTS-1];
    integer response_due_q [0:RESPONSE_SLOTS-1];
    reg response_free_found_r;
    integer response_free_slot_r;
    reg response_due_found_r;
    integer response_due_slot_r;
    integer response_scan;

    wire icx_req_fire = icx_req_valid && icx_req_ready;
    wire icx_resp_fire = icx_resp_valid && icx_resp_ready;

    always @* begin
        response_free_found_r = 1'b0;
        response_free_slot_r = 0;
        response_due_found_r = 1'b0;
        response_due_slot_r = 0;
        for (response_scan = 0; response_scan < RESPONSE_SLOTS;
             response_scan = response_scan + 1) begin
            if (!response_free_found_r &&
                !response_slot_valid_q[response_scan]) begin
                response_free_found_r = 1'b1;
                response_free_slot_r = response_scan;
            end
            if (!response_due_found_r &&
                response_slot_valid_q[response_scan] &&
                (response_due_q[response_scan] <= cycle_count_q)) begin
                response_due_found_r = 1'b1;
                response_due_slot_r = response_scan;
            end
        end
    end

    assign icx_req_ready = response_free_found_r;
    assign icx_resp_valid = response_due_found_r;
    assign icx_resp_hart_id = response_hart_q[response_due_slot_r];
    assign icx_resp_txn_id = response_txn_q[response_due_slot_r];
    assign icx_resp_source_id = response_source_q[response_due_slot_r];

    openrv64_lsq #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .META_WIDTH(META_WIDTH),
        .LOAD_QUEUE_DEPTH(LOAD_QUEUE_DEPTH),
        .STORE_QUEUE_DEPTH(STORE_QUEUE_DEPTH),
        .TAG_WIDTH(TAG_WIDTH),
        .CACHEABLE_BASE(BASE),
        .CACHEABLE_SIZE(CACHEABLE_SIZE)
    ) u_lsq (
        .clk(clk_i),
        .rst_n(dut_rst_n),
        .flush_i(1'b0),
        .squash_younger_i(1'b0),
        .squash_inclusive_i(1'b0),
        .squash_id_i({ID_WIDTH{1'b0}}),
        .translation_bypass_i(1'b1),
        .inhibit_load_speculation_i(1'b0),
        .load_alloc_valid_i(1'b0),
        .load_alloc_ready_o(),
        .load_alloc_id_i({ID_WIDTH{1'b0}}),
        .load_alloc_slot_i({RETIRE_SLOT_WIDTH{1'b0}}),
        .load_alloc_meta_i({META_WIDTH{1'b0}}),
        .load_alloc_immediate_i(1'b0),
        .load_alloc_access_fault_i(1'b0),
        .load_alloc_vaddr_i(64'd0),
        .load_alloc_size_i(3'd3),
        .store_alloc_valid_i(store_alloc_valid),
        .store_alloc_ready_o(store_alloc_ready),
        .store_alloc_id_i(store_alloc_id),
        .store_alloc_slot_i({RETIRE_SLOT_WIDTH{1'b0}}),
        .store_alloc_meta_i({META_WIDTH{1'b0}}),
        .store_alloc_immediate_i(1'b0),
        .store_alloc_access_fault_i(1'b0),
        .store_alloc_atomic_i(1'b0),
        .store_alloc_vaddr_i(store_alloc_addr),
        .store_alloc_size_i(3'd3),
        .store_alloc_wdata_i(store_alloc_data),
        .store_alloc_wstrb_i(8'hff),
        .ordered_head_valid_i(ordered_head_valid),
        .ordered_head_id_i(ordered_head_id),
        .ordered_head_slot_i({RETIRE_SLOT_WIDTH{1'b0}}),
        .atomic_start_valid_o(),
        .atomic_start_tag_o(),
        .atomic_start_id_o(),
        .atomic_start_slot_o(),
        .atomic_start_meta_o(),
        .atomic_start_access_allowed_o(),
        .atomic_active_i(1'b0),
        .atomic_tag_i({TAG_WIDTH{1'b0}}),
        .atomic_irrevocable_i(1'b0),
        .atomic_done_i(1'b0),
        .xlate_req_valid_o(xlate_req_valid),
        .xlate_req_ready_i(1'b1),
        .xlate_req_tag_o(xlate_req_tag),
        .xlate_req_write_o(xlate_req_write),
        .xlate_req_size_o(xlate_req_size),
        .xlate_req_vaddr_o(xlate_req_vaddr),
        // Bare mode is an identity translation but still returns address
        // clearance. Model a zero-latency PMP-allowed response here so this
        // benchmark remains focused on LSQ/L1D store throughput.
        .xlate_resp_valid_i(xlate_req_valid),
        .xlate_resp_ready_o(),
        .xlate_resp_tag_i(xlate_req_tag),
        .xlate_resp_paddr_i(xlate_req_vaddr),
        .xlate_resp_access_fault_i(1'b0),
        .xlate_resp_page_fault_i(1'b0),
        .req_valid_o(lsq_req_valid),
        .req_ready_i(lsq_req_ready),
        .req_tag_o(lsq_req_tag),
        .req_write_o(lsq_req_write),
        .req_addr_o(lsq_req_addr),
        .req_vaddr_o(),
        .req_size_o(),
        .req_wdata_o(lsq_req_wdata),
        .req_wstrb_o(lsq_req_wstrb),
        .posted_store_complete_valid_o(lsq_posted_complete_valid),
        .posted_store_complete_id_o(lsq_posted_complete_id),
        .posted_store_complete_slot_o(lsq_posted_complete_slot),
        .resp_valid_i(l1d_resp_valid),
        .resp_ready_o(lsq_resp_ready),
        .resp_tag_i(l1d_resp_tag),
        .resp_paddr_i(64'd0),
        .resp_rdata_i(l1d_resp_data),
        .resp_access_fault_i(l1d_resp_error),
        .resp_page_fault_i(1'b0),
        .store_done_valid_i(l1d_posted_resp_valid),
        .store_done_ready_o(lsq_store_done_ready),
        .store_done_tag_i(l1d_posted_resp_tag),
        .result_valid_o(lsq_result_valid),
        .result_ready_i(1'b1),
        .result_id_o(lsq_result_id),
        .result_slot_o(),
        .result_meta_o(),
        .result_rdata_o(),
        .result_access_fault_o(lsq_result_access_fault),
        .result_page_fault_o(lsq_result_page_fault),
        .result_store_o(lsq_result_store),
        .store_pending_o(),
        .quiescent_o(),
        .empty_o(lsq_empty)
    );

    openrv64_l1d_icx #(
        .ENABLE(1),
        .CACHE_BYTES(1024),
        .LINE_BYTES(64),
        .WAYS(4),
        .SYNC_TAG_LOOKUP(SYNC_TAG_LOOKUP),
        .FILL_BUFFER_LINES(2),
        .DEMAND_MSHRS(3),
        .STORE_BUFFER_LINES(8),
        .STORE_BUFFER_DRAIN_WATERMARK(4),
        .STORE_BUFFER_TIMEOUT_CYCLES(64),
        .PREFETCH_ENABLE(0),
        .PREFETCH_OUTSTANDING(1),
        .PREFETCH_DEMAND_RESERVE(1),
        .REQ_TAG_WIDTH(TAG_WIDTH),
        .REQ_DEPTH(8)
    ) u_l1d (
        .clk_i(clk_i),
        .rst_ni(dut_rst_n),
        .req_valid_i(lsq_req_valid),
        .req_ready_o(lsq_req_ready),
        .req_tag_i(lsq_req_tag),
        .req_lock_i(1'b0),
        .req_posted_i(lsq_req_write),
        .req_write_i(lsq_req_write),
        .req_cacheable_i(1'b1),
        .req_addr_i(lsq_req_addr),
        .req_size_i(3'd3),
        .req_wdata_i(lsq_req_wdata),
        .req_wstrb_i(lsq_req_wstrb),
        .req_rdata_o(l1d_resp_data),
        .req_error_o(l1d_resp_error),
        .resp_valid_o(l1d_resp_valid),
        .resp_ready_i(lsq_resp_ready),
        .resp_tag_o(l1d_resp_tag),
        .posted_resp_valid_o(l1d_posted_resp_valid),
        .posted_resp_ready_i(lsq_store_done_ready),
        .posted_resp_tag_o(l1d_posted_resp_tag),
        .store_resp_valid_o(l1d_store_resp_valid),
        .store_resp_ready_i(1'b1),
        .store_resp_error_o(l1d_store_resp_error),
        .prefetch_issued_o(),
        .prefetch_useful_o(),
        .prefetch_late_o(),
        .prefetch_dropped_o(),
        .prefetch_useless_o(),
        .prefetch_depth_o(),
        .speculation_barrier_i(speculation_barrier),
        .completion_fence_i(1'b0),
        .store_barrier_busy_o(store_barrier_busy),
        .invalidate_valid_i(1'b0),
        .invalidate_ready_o(),
        .invalidate_all_i(1'b0),
        .invalidate_addr_i(64'd0),
        .icx_req_valid_o(icx_req_valid),
        .icx_req_ready_i(icx_req_ready),
        .icx_req_hart_id_o(icx_req_hart_id),
        .icx_req_txn_id_o(icx_req_txn_id),
        .icx_req_source_id_o(icx_req_source_id),
        .icx_req_op_o(icx_req_op),
        .icx_req_lock_o(),
        .icx_req_order_o(),
        .icx_req_kind_o(),
        .icx_req_attr_o(),
        .icx_req_size_o(icx_req_size),
        .icx_req_addr_o(icx_req_addr),
        .icx_req_burst_len_o(),
        .icx_wdata_valid_o(icx_wdata_valid),
        .icx_wdata_ready_i(icx_req_ready),
        .icx_wdata_hart_id_o(),
        .icx_wdata_txn_id_o(),
        .icx_wdata_source_id_o(),
        .icx_wdata_beat_index_o(),
        .icx_wdata_last_o(),
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
        .icx_resp_rdata_i({`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}}),
        .icx_resp_error_i(1'b0),
        .icx_resp_sc_success_i(1'b0)
    );

    always @(posedge clk_i or negedge dut_rst_n) begin
        if (!dut_rst_n) begin
            phase_allocated_q <= 0;
            phase_retired_q <= 0;
            issue_cooldown_q <= 0;
            cycle_count_q <= 0;
            store_buffer_max_q <= 0;
            icx_write_count_q <= 0;
            icx_response_count_q <= 0;
            for (response_scan = 0; response_scan < RESPONSE_SLOTS;
                 response_scan = response_scan + 1) begin
                response_slot_valid_q[response_scan] <= 1'b0;
                response_hart_q[response_scan] <= 0;
                response_txn_q[response_scan] <= 0;
                response_source_q[response_scan] <= 0;
                response_due_q[response_scan] <= 0;
            end
        end else begin
            cycle_count_q <= cycle_count_q + 1;

            if (phase_active && (issue_cooldown_q != 0))
                issue_cooldown_q <= issue_cooldown_q - 1;
            if (store_alloc_fire) begin
                phase_allocated_q <= phase_allocated_q + 1;
                issue_cooldown_q <= phase_gap;
            end
            if (result_fire) begin
                if (!phase_active ||
                    (lsq_posted_complete_id !==
                     ID_WIDTH'(phase_retired_q)) ||
                    (lsq_posted_complete_slot !==
                     {RETIRE_SLOT_WIDTH{1'b0}}))
                    $fatal(1,
                           "mode=%0d bad store sideband id=%0d expected=%0d slot=%0d",
                           SYNC_TAG_LOOKUP, lsq_posted_complete_id,
                           ID_WIDTH'(phase_retired_q),
                           lsq_posted_complete_slot);
                phase_retired_q <= phase_retired_q + 1;
            end
            if (lsq_result_valid)
                $fatal(1,
                    "mode=%0d cacheable store used full result path id=%0d store=%0b access=%0b page=%0b",
                    SYNC_TAG_LOOKUP, lsq_result_id, lsq_result_store,
                    lsq_result_access_fault, lsq_result_page_fault);

            if (u_l1d.store_buffer_count_q > store_buffer_max_q)
                store_buffer_max_q <= u_l1d.store_buffer_count_q;

            if (icx_req_fire) begin
                if (icx_req_op != `OPENRV64_ICX_OP_WRITE ||
                    !icx_wdata_valid || (icx_req_size != 3'd6) ||
                    !(|icx_wstrb))
                    $fatal(1,
                           "mode=%0d malformed buffered store command op=%0d size=%0d wvalid=%0b strb=%h addr=%h",
                           SYNC_TAG_LOOKUP, icx_req_op, icx_req_size,
                           icx_wdata_valid, icx_wstrb, icx_req_addr);
                if (phase_page_clear) begin
                    if ((icx_req_addr !=
                         BASE + icx_write_count_q * 64) ||
                        (icx_wstrb !=
                         {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b1}}))
                        $fatal(1,
                            "mode=%0d page-clear line geometry mismatch write=%0d addr=%h strb=%h",
                            SYNC_TAG_LOOKUP, icx_write_count_q,
                            icx_req_addr, icx_wstrb);
                    for (page_clear_word = 0;
                         page_clear_word < 8;
                         page_clear_word = page_clear_word + 1)
                        if (icx_wdata[page_clear_word*64 +: 64] !==
                            (64'h5a00_0000_0000_0000 ^
                             64'(icx_write_count_q * 8 +
                                 page_clear_word)))
                            $fatal(1,
                                "mode=%0d page-clear data mismatch write=%0d word=%0d data=%h",
                                SYNC_TAG_LOOKUP, icx_write_count_q,
                                page_clear_word,
                                icx_wdata[page_clear_word*64 +: 64]);
                end
                if (!response_free_found_r)
                    $fatal(1, "mode=%0d ICX response model overflow",
                           SYNC_TAG_LOOKUP);
                response_slot_valid_q[response_free_slot_r] <= 1'b1;
                response_hart_q[response_free_slot_r] <= icx_req_hart_id;
                response_txn_q[response_free_slot_r] <= icx_req_txn_id;
                response_source_q[response_free_slot_r] <=
                    icx_req_source_id;
                response_due_q[response_free_slot_r] <=
                    cycle_count_q + RESPONSE_DELAY;
                icx_write_count_q <= icx_write_count_q + 1;
            end
            if (icx_resp_fire) begin
                response_slot_valid_q[response_due_slot_r] <= 1'b0;
                icx_response_count_q <= icx_response_count_q + 1;
            end
            if (l1d_store_resp_valid && l1d_store_resp_error)
                $fatal(1, "mode=%0d L1D reported a store-buffer error",
                       SYNC_TAG_LOOKUP);
        end
    end

    task automatic reset_phase;
        begin
            phase_active = 1'b0;
            speculation_barrier = 1'b0;
            local_rst_n = 1'b0;
            repeat (3) @(posedge clk_i);
            @(negedge clk_i);
            local_rst_n = 1'b1;
            repeat (2) @(posedge clk_i);
        end
    endtask

    task automatic run_phase;
        input integer gap;
        input integer page_clear;
        output integer measured_cycles;
        output integer measured_access_wait;
        output integer measured_queue_full;
        output integer measured_lsq_max;
        output integer measured_store_buffer_max;
        integer start_cycle;
        integer wait_cycles;
        begin
            phase_gap = gap;
            phase_page_clear = page_clear != 0;
            @(negedge clk_i);
            start_cycle = cycle_count_q;
            phase_active = 1'b1;
            wait_cycles = 0;
            while ((phase_retired_q < ITERATIONS) &&
                   (wait_cycles < ITERATIONS * 16)) begin
                @(negedge clk_i);
                wait_cycles = wait_cycles + 1;
            end
            if (phase_retired_q != ITERATIONS)
                $fatal(1,
                       "mode=%0d store phase timed out gap=%0d allocated=%0d retired=%0d",
                       SYNC_TAG_LOOKUP, gap, phase_allocated_q,
                       phase_retired_q);
            phase_active = 1'b0;
            measured_cycles = cycle_count_q - start_cycle;
            measured_access_wait =
                u_lsq.perf_store_access_wait_cycles_q;
            measured_queue_full =
                u_lsq.perf_store_queue_full_cycles_q;
            measured_lsq_max = u_lsq.perf_store_max_occupancy_q;
            measured_store_buffer_max = store_buffer_max_q;

            @(negedge clk_i);
            speculation_barrier = 1'b1;
            @(posedge clk_i);
            @(negedge clk_i);
            speculation_barrier = 1'b0;
            wait_cycles = 0;
            while ((!lsq_empty ||
                    (u_l1d.store_buffer_count_q != 0) ||
                    (u_l1d.backend_state_q != 0) ||
                    (icx_write_count_q != icx_response_count_q)) &&
                   (wait_cycles < ITERATIONS * 4)) begin
                @(negedge clk_i);
                wait_cycles = wait_cycles + 1;
            end
            if (!lsq_empty || (u_l1d.store_buffer_count_q != 0) ||
                (u_l1d.backend_state_q != 0) ||
                (icx_write_count_q != icx_response_count_q))
                $fatal(1,
                       "mode=%0d phase failed to drain empty=%0b sb=%0d backend=%0d writes=%0d responses=%0d",
                       SYNC_TAG_LOOKUP, lsq_empty,
                       u_l1d.store_buffer_count_q,
                       u_l1d.backend_state_q, icx_write_count_q,
                       icx_response_count_q);
        end
    endtask

    initial begin
        done_o = 1'b0;
        sparse_cycles_o = 0;
        sparse_access_wait_o = 0;
        sparse_queue_full_o = 0;
        sparse_lsq_max_o = 0;
        sparse_store_buffer_max_o = 0;
        dense_cycles_o = 0;
        dense_access_wait_o = 0;
        dense_queue_full_o = 0;
        dense_lsq_max_o = 0;
        dense_store_buffer_max_o = 0;
        clear_cycles_o = 0;
        clear_access_wait_o = 0;
        clear_queue_full_o = 0;
        clear_lsq_max_o = 0;
        clear_store_buffer_max_o = 0;
        clear_store_extensions_o = 0;
        clear_fast_merges_o = 0;
        clear_icx_writes_o = 0;
        local_rst_n = 1'b0;
        phase_active = 1'b0;
        phase_page_clear = 1'b0;
        phase_gap = 0;
        speculation_barrier = 1'b0;

        wait (rst_ni);
        reset_phase();
        run_phase(SPARSE_GAP, 0, sparse_cycles_o, sparse_access_wait_o,
                  sparse_queue_full_o, sparse_lsq_max_o,
                  sparse_store_buffer_max_o);
        reset_phase();
        run_phase(0, 0, dense_cycles_o, dense_access_wait_o,
                  dense_queue_full_o, dense_lsq_max_o,
                  dense_store_buffer_max_o);
        reset_phase();
        run_phase(0, 1, clear_cycles_o, clear_access_wait_o,
                  clear_queue_full_o, clear_lsq_max_o,
                  clear_store_buffer_max_o);
        clear_store_extensions_o =
            u_l1d.u_l1d.u_l1.g_cache.u_cache.u_debug.
                perf_store_extension_fire_q;
        clear_fast_merges_o =
            u_l1d.u_debug.perf_fast_store_merge_q;
        clear_icx_writes_o = icx_write_count_q;
        done_o = 1'b1;
    end
endmodule

module tb_lsq_l1d_store_performance;
    localparam integer ITERATIONS = 4096;
    localparam integer STORE_QUEUE_DEPTH = 4;
    reg clk;
    reg rst_n;
    wire legacy_done;
    wire sync_done;
    integer legacy_sparse_cycles;
    integer legacy_sparse_access_wait;
    integer legacy_sparse_queue_full;
    integer legacy_sparse_lsq_max;
    integer legacy_sparse_store_buffer_max;
    integer legacy_dense_cycles;
    integer legacy_dense_access_wait;
    integer legacy_dense_queue_full;
    integer legacy_dense_lsq_max;
    integer legacy_dense_store_buffer_max;
    integer legacy_clear_cycles;
    integer legacy_clear_access_wait;
    integer legacy_clear_queue_full;
    integer legacy_clear_lsq_max;
    integer legacy_clear_store_buffer_max;
    integer legacy_clear_store_extensions;
    integer legacy_clear_fast_merges;
    integer legacy_clear_icx_writes;
    integer sync_sparse_cycles;
    integer sync_sparse_access_wait;
    integer sync_sparse_queue_full;
    integer sync_sparse_lsq_max;
    integer sync_sparse_store_buffer_max;
    integer sync_dense_cycles;
    integer sync_dense_access_wait;
    integer sync_dense_queue_full;
    integer sync_dense_lsq_max;
    integer sync_dense_store_buffer_max;
    integer sync_clear_cycles;
    integer sync_clear_access_wait;
    integer sync_clear_queue_full;
    integer sync_clear_lsq_max;
    integer sync_clear_store_buffer_max;
    integer sync_clear_store_extensions;
    integer sync_clear_fast_merges;
    integer sync_clear_icx_writes;

    lsq_l1d_store_performance_runner #(
        .SYNC_TAG_LOOKUP(0),
        .ITERATIONS(ITERATIONS)
    ) legacy_runner (
        .clk_i(clk),
        .rst_ni(rst_n),
        .done_o(legacy_done),
        .sparse_cycles_o(legacy_sparse_cycles),
        .sparse_access_wait_o(legacy_sparse_access_wait),
        .sparse_queue_full_o(legacy_sparse_queue_full),
        .sparse_lsq_max_o(legacy_sparse_lsq_max),
        .sparse_store_buffer_max_o(legacy_sparse_store_buffer_max),
        .dense_cycles_o(legacy_dense_cycles),
        .dense_access_wait_o(legacy_dense_access_wait),
        .dense_queue_full_o(legacy_dense_queue_full),
        .dense_lsq_max_o(legacy_dense_lsq_max),
        .dense_store_buffer_max_o(legacy_dense_store_buffer_max),
        .clear_cycles_o(legacy_clear_cycles),
        .clear_access_wait_o(legacy_clear_access_wait),
        .clear_queue_full_o(legacy_clear_queue_full),
        .clear_lsq_max_o(legacy_clear_lsq_max),
        .clear_store_buffer_max_o(legacy_clear_store_buffer_max),
        .clear_store_extensions_o(legacy_clear_store_extensions),
        .clear_fast_merges_o(legacy_clear_fast_merges),
        .clear_icx_writes_o(legacy_clear_icx_writes)
    );

    lsq_l1d_store_performance_runner #(
        .SYNC_TAG_LOOKUP(1),
        .ITERATIONS(ITERATIONS)
    ) sync_runner (
        .clk_i(clk),
        .rst_ni(rst_n),
        .done_o(sync_done),
        .sparse_cycles_o(sync_sparse_cycles),
        .sparse_access_wait_o(sync_sparse_access_wait),
        .sparse_queue_full_o(sync_sparse_queue_full),
        .sparse_lsq_max_o(sync_sparse_lsq_max),
        .sparse_store_buffer_max_o(sync_sparse_store_buffer_max),
        .dense_cycles_o(sync_dense_cycles),
        .dense_access_wait_o(sync_dense_access_wait),
        .dense_queue_full_o(sync_dense_queue_full),
        .dense_lsq_max_o(sync_dense_lsq_max),
        .dense_store_buffer_max_o(sync_dense_store_buffer_max),
        .clear_cycles_o(sync_clear_cycles),
        .clear_access_wait_o(sync_clear_access_wait),
        .clear_queue_full_o(sync_clear_queue_full),
        .clear_lsq_max_o(sync_clear_lsq_max),
        .clear_store_buffer_max_o(sync_clear_store_buffer_max),
        .clear_store_extensions_o(sync_clear_store_extensions),
        .clear_fast_merges_o(sync_clear_fast_merges),
        .clear_icx_writes_o(sync_clear_icx_writes)
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
        repeat (ITERATIONS * 40) @(posedge clk);
        $fatal(1, "LSQ/L1D store performance benchmark timed out");
    end

    initial begin
        wait (legacy_done && sync_done);
        if ((legacy_sparse_cycles != sync_sparse_cycles) ||
            (legacy_sparse_access_wait != 0) ||
            (sync_sparse_access_wait != 0) ||
            (legacy_sparse_queue_full != 0) ||
            (sync_sparse_queue_full != 0) ||
            (legacy_sparse_lsq_max != 1) ||
            (sync_sparse_lsq_max != 1))
            $fatal(1,
                   "sparse stores were not fully hidden by the LSQ/L1D queues");
        if ((legacy_dense_lsq_max != STORE_QUEUE_DEPTH) ||
            (sync_dense_lsq_max != STORE_QUEUE_DEPTH) ||
            (legacy_dense_queue_full == 0) ||
            (sync_dense_queue_full == 0))
            $fatal(1, "dense phase did not saturate the store queue");
        if ((sync_dense_cycles <= legacy_dense_cycles) ||
            (sync_dense_access_wait <= legacy_dense_access_wait))
            $fatal(1,
                   "dense registered-tag store pressure was not observable");
        if ((legacy_clear_lsq_max != STORE_QUEUE_DEPTH) ||
            (sync_clear_lsq_max != STORE_QUEUE_DEPTH) ||
            (legacy_clear_queue_full == 0) ||
            (sync_clear_queue_full == 0))
            $fatal(1, "page-clear phase did not saturate the store queue");
        if ((legacy_clear_store_extensions != 0) ||
            (sync_clear_store_extensions != 0))
            $fatal(1,
                   "cold page-clear unexpectedly used the valid-hit store extension");
        if ((legacy_clear_fast_merges != 0) ||
            (sync_clear_fast_merges != (ITERATIONS - ITERATIONS / 8)))
            $fatal(1,
                   "cold page-clear fast-merge count mismatch legacy=%0d sync=%0d",
                   legacy_clear_fast_merges, sync_clear_fast_merges);
        if (sync_clear_cycles > legacy_clear_cycles)
            $fatal(1,
                   "same-line fast path did not remove the synchronous page-clear penalty");
        $display("PERF: mode=legacy phase=sparse stores=%0d cycles=%0d access_wait=%0d queue_full=%0d lsq_max=%0d store_buffer_max=%0d",
                 ITERATIONS, legacy_sparse_cycles,
                 legacy_sparse_access_wait, legacy_sparse_queue_full,
                 legacy_sparse_lsq_max, legacy_sparse_store_buffer_max);
        $display("PERF: mode=sync phase=sparse stores=%0d cycles=%0d access_wait=%0d queue_full=%0d lsq_max=%0d store_buffer_max=%0d",
                 ITERATIONS, sync_sparse_cycles,
                 sync_sparse_access_wait, sync_sparse_queue_full,
                 sync_sparse_lsq_max, sync_sparse_store_buffer_max);
        $display("PERF: delta phase=sparse cycles=%0d access_wait=%0d queue_full=%0d",
                 sync_sparse_cycles - legacy_sparse_cycles,
                 sync_sparse_access_wait - legacy_sparse_access_wait,
                 sync_sparse_queue_full - legacy_sparse_queue_full);
        $display("PERF: mode=legacy phase=dense stores=%0d cycles=%0d access_wait=%0d queue_full=%0d lsq_max=%0d store_buffer_max=%0d",
                 ITERATIONS, legacy_dense_cycles,
                 legacy_dense_access_wait, legacy_dense_queue_full,
                 legacy_dense_lsq_max, legacy_dense_store_buffer_max);
        $display("PERF: mode=sync phase=dense stores=%0d cycles=%0d access_wait=%0d queue_full=%0d lsq_max=%0d store_buffer_max=%0d",
                 ITERATIONS, sync_dense_cycles,
                 sync_dense_access_wait, sync_dense_queue_full,
                 sync_dense_lsq_max, sync_dense_store_buffer_max);
        $display("PERF: delta phase=dense cycles=%0d access_wait=%0d queue_full=%0d",
                 sync_dense_cycles - legacy_dense_cycles,
                 sync_dense_access_wait - legacy_dense_access_wait,
                 sync_dense_queue_full - legacy_dense_queue_full);
        $display("PERF: mode=legacy phase=page_clear stores=%0d cycles=%0d access_wait=%0d queue_full=%0d lsq_max=%0d store_buffer_max=%0d extensions=%0d fast_merges=%0d icx_writes=%0d",
                 ITERATIONS, legacy_clear_cycles,
                 legacy_clear_access_wait, legacy_clear_queue_full,
                 legacy_clear_lsq_max, legacy_clear_store_buffer_max,
                 legacy_clear_store_extensions, legacy_clear_fast_merges,
                 legacy_clear_icx_writes);
        $display("PERF: mode=sync phase=page_clear stores=%0d cycles=%0d access_wait=%0d queue_full=%0d lsq_max=%0d store_buffer_max=%0d extensions=%0d fast_merges=%0d icx_writes=%0d",
                 ITERATIONS, sync_clear_cycles,
                 sync_clear_access_wait, sync_clear_queue_full,
                 sync_clear_lsq_max, sync_clear_store_buffer_max,
                 sync_clear_store_extensions, sync_clear_fast_merges,
                 sync_clear_icx_writes);
        $display("PERF: delta phase=page_clear cycles=%0d access_wait=%0d queue_full=%0d icx_writes=%0d",
                 sync_clear_cycles - legacy_clear_cycles,
                 sync_clear_access_wait - legacy_clear_access_wait,
                 sync_clear_queue_full - legacy_clear_queue_full,
                 sync_clear_icx_writes - legacy_clear_icx_writes);
        $display("PASS: LSQ/L1D sparse, dense, and cold page-clear store behavior/performance comparison");
        $finish;
    end
endmodule
