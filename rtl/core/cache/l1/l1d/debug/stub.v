`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// Passive simulation visibility boundary for the coherent L1D wrapper.
/* verilator lint_off DECLFILENAME */
module openrv64_l1d_debug_stub #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer REQ_TAG_WIDTH = 3,
    parameter integer FILL_BUFFER_LINES = 8,
    parameter integer STORE_BUFFER_LINES = 8,
    parameter integer DEMAND_MSHRS = 3,
    parameter integer PREFETCH_OUTSTANDING = 4,
    parameter integer FREELOADER_STAGES = 1,
    parameter integer STORE_BUFFER_COUNT_WIDTH =
        $clog2(STORE_BUFFER_LINES + 1),
    parameter integer DEMAND_MSHR_INDEX_WIDTH =
        (DEMAND_MSHRS > 1) ? $clog2(DEMAND_MSHRS) : 1,
    parameter integer PREFETCH_MSHR_INDEX_WIDTH =
        (PREFETCH_OUTSTANDING > 1) ? $clog2(PREFETCH_OUTSTANDING) : 1,
    parameter integer DEMAND_WAITER_COUNT = 1 << REQ_TAG_WIDTH,
    parameter integer TAG_OVERLAY_EPOCH_WIDTH = 4,
    parameter integer L1_REQ_TAG_WIDTH =
        REQ_TAG_WIDTH + TAG_OVERLAY_EPOCH_WIDTH,
    parameter integer TAG_OVERLAY_WIDTH =
        `OPENRV64_ICX_LINE_DATA_WIDTH +
        `OPENRV64_ICX_LINE_STRB_WIDTH
) (
    input wire clk_i,
    input wire rst_ni,
    // Stable summary fields used by the common testbench.
    input wire [1:0] backend_state /* verilator public_flat_rd */,
    input wire coherent_lr_reservation_done /* verilator public_flat_rd */,
    input wire req_valid /* verilator public_flat_rd */,
    input wire req_ready /* verilator public_flat_rd */,
    input wire req_write /* verilator public_flat_rd */,
    input wire l1_req_valid /* verilator public_flat_rd */,
    input wire l1_req_ready /* verilator public_flat_rd */,
    input wire l1_miss_valid /* verilator public_flat_rd */,
    input wire l1_miss_ready /* verilator public_flat_rd */,
    input wire l1_miss_fire /* verilator public_flat_rd */,
    input wire demand_mshr_match_found_r /* verilator public_flat_rd */,
    input wire demand_mshr_response_fire /* verilator public_flat_rd */,
    input wire demand_response_fire /* verilator public_flat_rd */,
    input wire l1_fill_valid /* verilator public_flat_rd */,
    input wire l1_fill_ready /* verilator public_flat_rd */,
    input wire l1_fill_fire /* verilator public_flat_rd */,
    input wire fast_store_fire /* verilator public_flat_rd */,
    input wire normal_overlay_wait /* verilator public_flat_rd */,
    input wire demand_overlay_wait /* verilator public_flat_rd */,
    input wire store_buffer_block /* verilator public_flat_rd */,
    input wire demand_load_store_block /* verilator public_flat_rd */,
    input wire request_reservation /* verilator public_flat_rd */,
    input wire [STORE_BUFFER_COUNT_WIDTH-1:0] store_buffer_count
        /* verilator public_flat_rd */,
    input wire [DEMAND_MSHRS-1:0] demand_mshr_valid
        /* verilator public_flat_rd */,
    input wire [ADDR_WIDTH-1:0] request_addr
        /* verilator public_flat_rd */,
    input wire invalidate_valid_i /* verilator public_flat_rd */,
    input wire invalidate_ready_o /* verilator public_flat_rd */,
    input wire [ADDR_WIDTH-1:0] invalidate_addr_i
        /* verilator public_flat_rd */,
    input wire invalidate_txn_valid_q /* verilator public_flat_rd */,
    input wire invalidate_txn_external_q /* verilator public_flat_rd */,
    input wire invalidate_txn_all_q /* verilator public_flat_rd */,
    input wire [ADDR_WIDTH-1:0] invalidate_txn_addr_q
        /* verilator public_flat_rd */,
    input wire capture_external_invalidate /* verilator public_flat_rd */,
    input wire capture_lock_invalidate /* verilator public_flat_rd */,
    input wire lock_invalidate_request /* verilator public_flat_rd */,
    input wire lock_invalidate_fire /* verilator public_flat_rd */,
    input wire l1_invalidate_valid /* verilator public_flat_rd */,
    input wire l1_invalidate_ready /* verilator public_flat_rd */,

    // Detailed request, MSHR, overlay, and buffer state for targeted traces.
    input wire command_fire /* verilator public_flat_rd */,
    input wire response_fire /* verilator public_flat_rd */,
    input wire l1_response_fire /* verilator public_flat_rd */,
    input wire [ADDR_WIDTH-1:0] request_addr_q
        /* verilator public_flat_rd */,
    input wire request_write_q /* verilator public_flat_rd */,
    input wire request_demand_q /* verilator public_flat_rd */,
    input wire [DEMAND_MSHR_INDEX_WIDTH-1:0] request_demand_mshr_q
        /* verilator public_flat_rd */,
    input wire request_prefetch_q /* verilator public_flat_rd */,
    input wire [PREFETCH_MSHR_INDEX_WIDTH-1:0] request_prefetch_mshr_q
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] request_txn_id_q
        /* verilator public_flat_rd */,
    input wire demand_mshr_valid_q [0:DEMAND_MSHRS-1]
        /* verilator public_flat_rd */,
    input wire demand_mshr_issued_q [0:DEMAND_MSHRS-1]
        /* verilator public_flat_rd */,
    input wire demand_mshr_complete_q [0:DEMAND_MSHRS-1]
        /* verilator public_flat_rd */,
    input wire demand_mshr_fill_done_q [0:DEMAND_MSHRS-1]
        /* verilator public_flat_rd */,
    input wire [ADDR_WIDTH-1:0] demand_mshr_addr_q [0:DEMAND_MSHRS-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        demand_mshr_data_q [0:DEMAND_MSHRS-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        demand_mshr_store_data_q [0:DEMAND_MSHRS-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        demand_mshr_store_strb_q [0:DEMAND_MSHRS-1]
        /* verilator public_flat_rd */,
    input wire demand_mshr_response_match_r
        /* verilator public_flat_rd */,
    input wire [DEMAND_MSHR_INDEX_WIDTH-1:0]
        demand_mshr_response_index_r /* verilator public_flat_rd */,
    input wire demand_mshr_fill_found_r /* verilator public_flat_rd */,
    input wire [DEMAND_MSHR_INDEX_WIDTH-1:0]
        demand_mshr_fill_index_r /* verilator public_flat_rd */,
    input wire demand_mshr_prefetch_response_match_r
        /* verilator public_flat_rd */,
    input wire demand_waiter_response_found_r
        /* verilator public_flat_rd */,
    input wire [REQ_TAG_WIDTH-1:0] demand_waiter_response_tag_r
        /* verilator public_flat_rd */,
    input wire [DEMAND_MSHR_INDEX_WIDTH-1:0]
        demand_waiter_response_mshr_r /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        demand_response_data_r /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        demand_fill_data_r /* verilator public_flat_rd */,
    input wire demand_response_valid /* verilator public_flat_rd */,
    input wire fill_buffer_valid_q [0:FILL_BUFFER_LINES-1]
        /* verilator public_flat_rd */,
    input wire [ADDR_WIDTH-1:0] fill_buffer_addr_q [0:FILL_BUFFER_LINES-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        fill_buffer_data_q [0:FILL_BUFFER_LINES-1]
        /* verilator public_flat_rd */,
    input wire store_buffer_valid_q [0:STORE_BUFFER_LINES-1]
        /* verilator public_flat_rd */,
    input wire [ADDR_WIDTH-1:0]
        store_buffer_addr_q [0:STORE_BUFFER_LINES-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        store_buffer_data_q [0:STORE_BUFFER_LINES-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        store_buffer_strb_q [0:STORE_BUFFER_LINES-1]
        /* verilator public_flat_rd */,
    input wire freeloader_valid_q [0:FREELOADER_STAGES-1]
        /* verilator public_flat_rd */,
    input wire [REQ_TAG_WIDTH-1:0]
        freeloader_tag_q [0:FREELOADER_STAGES-1]
        /* verilator public_flat_rd */,
    input wire [63:0] freeloader_data_q [0:FREELOADER_STAGES-1]
        /* verilator public_flat_rd */,
    input wire [ADDR_WIDTH-1:0] l1_fill_addr
        /* verilator public_flat_rd */,
    input wire l1_mem_valid /* verilator public_flat_rd */,
    input wire l1_mem_ready /* verilator public_flat_rd */,
    input wire l1_mem_write /* verilator public_flat_rd */,
    input wire [ADDR_WIDTH-1:0] l1_mem_addr
        /* verilator public_flat_rd */,
    input wire [63:0] l1_mem_wdata /* verilator public_flat_rd */,
    input wire [7:0] l1_mem_wstrb /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] l1_mem_rdata
        /* verilator public_flat_rd */,
    input wire [L1_REQ_TAG_WIDTH-1:0] l1_resp_identity
        /* verilator public_flat_rd */,
    input wire normal_response_valid /* verilator public_flat_rd */,
    input wire [63:0] normal_response_merged_data_r
        /* verilator public_flat_rd */,
    input wire normal_overlay_owner_match /* verilator public_flat_rd */,
    input wire normal_overlay_needed /* verilator public_flat_rd */,
    input wire normal_overlay_read_match /* verilator public_flat_rd */,
    input wire normal_overlay_bypass_match /* verilator public_flat_rd */,
    input wire normal_overlay_ready /* verilator public_flat_rd */,
    input wire [TAG_OVERLAY_WIDTH-1:0] normal_overlay_data
        /* verilator public_flat_rd */,
    input wire [TAG_OVERLAY_EPOCH_WIDTH-1:0] tag_overlay_epoch_q
        /* verilator public_flat_rd */,
    input wire [TAG_OVERLAY_EPOCH_WIDTH-1:0]
        tag_overlay_mem_epoch_q [0:DEMAND_WAITER_COUNT-1]
        /* verilator public_flat_rd */,
    input wire [TAG_OVERLAY_EPOCH_WIDTH-1:0]
        tag_overlay_owner_epoch_q [0:DEMAND_WAITER_COUNT-1]
        /* verilator public_flat_rd */,
    input wire [2:0] tag_overlay_word_q [0:DEMAND_WAITER_COUNT-1]
        /* verilator public_flat_rd */,
    input wire [REQ_TAG_WIDTH-1:0] tag_overlay_read_tag_q
        /* verilator public_flat_rd */,
    input wire [TAG_OVERLAY_EPOCH_WIDTH-1:0] tag_overlay_read_epoch_q
        /* verilator public_flat_rd */,
    input wire [TAG_OVERLAY_EPOCH_WIDTH-1:0]
        tag_overlay_read_mem_epoch_q /* verilator public_flat_rd */,
    input wire [ADDR_WIDTH-1:0]
        prefetch_mshr_addr_q [0:PREFETCH_OUTSTANDING-1]
        /* verilator public_flat_rd */,
    input wire [PREFETCH_MSHR_INDEX_WIDTH-1:0]
        prefetch_mshr_response_index_r /* verilator public_flat_rd */,
    input wire prefetch_response_fire /* verilator public_flat_rd */,
    input wire prefetch_response_claim_existing
        /* verilator public_flat_rd */,
    input wire prefetch_response_claim_new /* verilator public_flat_rd */
);
    reg [63:0] perf_req_wait_cycles_q /* verilator public_flat_rd */;
    reg [63:0] perf_read_wait_cycles_q /* verilator public_flat_rd */;
    reg [63:0] perf_write_wait_cycles_q /* verilator public_flat_rd */;
    reg [63:0] perf_l1_req_wait_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_l1_miss_q /* verilator public_flat_rd */;
    reg [63:0] perf_l1_miss_wait_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_l1_fill_q /* verilator public_flat_rd */;
    reg [63:0] perf_l1_fill_wait_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fast_store_merge_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_command_q /* verilator public_flat_rd */;
    reg [63:0] perf_response_q /* verilator public_flat_rd */;
    reg [63:0] perf_l1_response_q /* verilator public_flat_rd */;
    reg [63:0] perf_prefetch_response_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_normal_overlay_wait_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_demand_overlay_wait_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_store_buffer_block_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_load_store_block_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_store_buffer_occupancy_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_store_buffer_max_occupancy_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_demand_mshr_occupancy_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_demand_mshr_full_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_demand_mshr_max_occupancy_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_demand_mshr_alloc_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_demand_mshr_merge_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_demand_mshr_issue_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_demand_mshr_lower_response_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_demand_mshr_waiter_response_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_invalidate_capture_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_external_invalidate_capture_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lock_invalidate_capture_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_external_invalidate_wait_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lock_invalidate_wait_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_invalidate_hold_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_invalidate_complete_q
        /* verilator public_flat_rd */;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            perf_req_wait_cycles_q <= 64'd0;
            perf_read_wait_cycles_q <= 64'd0;
            perf_write_wait_cycles_q <= 64'd0;
            perf_l1_req_wait_cycles_q <= 64'd0;
            perf_l1_miss_q <= 64'd0;
            perf_l1_miss_wait_cycles_q <= 64'd0;
            perf_l1_fill_q <= 64'd0;
            perf_l1_fill_wait_cycles_q <= 64'd0;
            perf_fast_store_merge_q <= 64'd0;
            perf_command_q <= 64'd0;
            perf_response_q <= 64'd0;
            perf_l1_response_q <= 64'd0;
            perf_prefetch_response_q <= 64'd0;
            perf_normal_overlay_wait_cycles_q <= 64'd0;
            perf_demand_overlay_wait_cycles_q <= 64'd0;
            perf_store_buffer_block_cycles_q <= 64'd0;
            perf_load_store_block_cycles_q <= 64'd0;
            perf_store_buffer_occupancy_cycles_q <= 64'd0;
            perf_store_buffer_max_occupancy_q <= 64'd0;
            perf_demand_mshr_occupancy_cycles_q <= 64'd0;
            perf_demand_mshr_full_cycles_q <= 64'd0;
            perf_demand_mshr_max_occupancy_q <= 64'd0;
            perf_demand_mshr_alloc_q <= 64'd0;
            perf_demand_mshr_merge_q <= 64'd0;
            perf_demand_mshr_issue_q <= 64'd0;
            perf_demand_mshr_lower_response_q <= 64'd0;
            perf_demand_mshr_waiter_response_q <= 64'd0;
            perf_invalidate_capture_q <= 64'd0;
            perf_external_invalidate_capture_q <= 64'd0;
            perf_lock_invalidate_capture_q <= 64'd0;
            perf_external_invalidate_wait_cycles_q <= 64'd0;
            perf_lock_invalidate_wait_cycles_q <= 64'd0;
            perf_invalidate_hold_cycles_q <= 64'd0;
            perf_invalidate_complete_q <= 64'd0;
        end else begin
            if (req_valid && !req_ready) begin
                perf_req_wait_cycles_q <= perf_req_wait_cycles_q + 1'b1;
                if (req_write)
                    perf_write_wait_cycles_q <=
                        perf_write_wait_cycles_q + 1'b1;
                else
                    perf_read_wait_cycles_q <=
                        perf_read_wait_cycles_q + 1'b1;
            end
            if (l1_req_valid && !l1_req_ready)
                perf_l1_req_wait_cycles_q <=
                    perf_l1_req_wait_cycles_q + 1'b1;
            if (l1_miss_fire)
                perf_l1_miss_q <= perf_l1_miss_q + 1'b1;
            if (l1_miss_valid && !l1_miss_ready)
                perf_l1_miss_wait_cycles_q <=
                    perf_l1_miss_wait_cycles_q + 1'b1;
            if (l1_fill_fire)
                perf_l1_fill_q <= perf_l1_fill_q + 1'b1;
            if (l1_fill_valid && !l1_fill_ready)
                perf_l1_fill_wait_cycles_q <=
                    perf_l1_fill_wait_cycles_q + 1'b1;
            if (fast_store_fire)
                perf_fast_store_merge_q <=
                    perf_fast_store_merge_q + 1'b1;
            if (command_fire)
                perf_command_q <= perf_command_q + 1'b1;
            if (response_fire)
                perf_response_q <= perf_response_q + 1'b1;
            if (l1_response_fire)
                perf_l1_response_q <= perf_l1_response_q + 1'b1;
            if (prefetch_response_fire)
                perf_prefetch_response_q <=
                    perf_prefetch_response_q + 1'b1;
            if (normal_overlay_wait)
                perf_normal_overlay_wait_cycles_q <=
                    perf_normal_overlay_wait_cycles_q + 1'b1;
            if (demand_overlay_wait)
                perf_demand_overlay_wait_cycles_q <=
                    perf_demand_overlay_wait_cycles_q + 1'b1;
            if (store_buffer_block)
                perf_store_buffer_block_cycles_q <=
                    perf_store_buffer_block_cycles_q + 1'b1;
            if (demand_load_store_block)
                perf_load_store_block_cycles_q <=
                    perf_load_store_block_cycles_q + 1'b1;
            perf_store_buffer_occupancy_cycles_q <=
                perf_store_buffer_occupancy_cycles_q + store_buffer_count;
            if (store_buffer_count > perf_store_buffer_max_occupancy_q)
                perf_store_buffer_max_occupancy_q <= store_buffer_count;
            perf_demand_mshr_occupancy_cycles_q <=
                perf_demand_mshr_occupancy_cycles_q +
                $countones(demand_mshr_valid);
            if (&demand_mshr_valid)
                perf_demand_mshr_full_cycles_q <=
                    perf_demand_mshr_full_cycles_q + 1'b1;
            if ($countones(demand_mshr_valid) >
                perf_demand_mshr_max_occupancy_q)
                perf_demand_mshr_max_occupancy_q <=
                    $countones(demand_mshr_valid);
            if (l1_miss_fire && demand_mshr_match_found_r)
                perf_demand_mshr_merge_q <=
                    perf_demand_mshr_merge_q + 1'b1;
            if (l1_miss_fire && !demand_mshr_match_found_r)
                perf_demand_mshr_alloc_q <=
                    perf_demand_mshr_alloc_q + 1'b1;
            if (command_fire && request_demand_q)
                perf_demand_mshr_issue_q <=
                    perf_demand_mshr_issue_q + 1'b1;
            if (demand_mshr_response_fire)
                perf_demand_mshr_lower_response_q <=
                    perf_demand_mshr_lower_response_q + 1'b1;
            if (demand_response_fire)
                perf_demand_mshr_waiter_response_q <=
                    perf_demand_mshr_waiter_response_q + 1'b1;
            if (capture_external_invalidate || capture_lock_invalidate)
                perf_invalidate_capture_q <=
                    perf_invalidate_capture_q + 1'b1;
            if (capture_external_invalidate)
                perf_external_invalidate_capture_q <=
                    perf_external_invalidate_capture_q + 1'b1;
            if (capture_lock_invalidate)
                perf_lock_invalidate_capture_q <=
                    perf_lock_invalidate_capture_q + 1'b1;
            if (invalidate_valid_i && !invalidate_ready_o)
                perf_external_invalidate_wait_cycles_q <=
                    perf_external_invalidate_wait_cycles_q + 1'b1;
            if (lock_invalidate_request && !lock_invalidate_fire)
                perf_lock_invalidate_wait_cycles_q <=
                    perf_lock_invalidate_wait_cycles_q + 1'b1;
            if (invalidate_txn_valid_q)
                perf_invalidate_hold_cycles_q <=
                    perf_invalidate_hold_cycles_q + 1'b1;
            if (l1_invalidate_valid && l1_invalidate_ready)
                perf_invalidate_complete_q <=
                    perf_invalidate_complete_q + 1'b1;
        end
    end
endmodule
/* verilator lint_on DECLFILENAME */
