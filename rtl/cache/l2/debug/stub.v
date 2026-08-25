`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "complex/coherent/protocol/defs.v"

// Passive simulation visibility boundary for native L2/coherence state.
/* verilator lint_off DECLFILENAME */
module openrv64_l2_debug_stub #(
    parameter integer NUM_HARTS = 4,
    parameter integer MSHR_ENTRIES = 8,
    parameter integer WAITERS_PER_MSHR = 4,
    parameter integer COMMAND_ENTRIES = 8,
    parameter integer RESPONSE_ENTRIES = 8,
    parameter integer BUS_TRACK_ENTRIES = 8,
    parameter integer TOTAL_WAITERS = MSHR_ENTRIES * WAITERS_PER_MSHR,
    parameter integer MSHR_INDEX_WIDTH =
        (MSHR_ENTRIES > 1) ? $clog2(MSHR_ENTRIES) : 1,
    parameter integer COMMAND_COUNT_WIDTH = $clog2(COMMAND_ENTRIES + 1),
    parameter integer RESPONSE_COUNT_WIDTH = $clog2(RESPONSE_ENTRIES + 1),
    parameter integer TRACK_INDEX_WIDTH =
        (BUS_TRACK_ENTRIES > 1) ? $clog2(BUS_TRACK_ENTRIES) : 1,
    parameter integer WAY_INDEX_WIDTH = 3,
    parameter integer SRAM_PAYLOAD_WIDTH =
        `OPENRV64_ICX_LINE_DATA_WIDTH +
        `OPENRV64_ICX_LINE_STRB_WIDTH
) (
    input wire clk_i,
    input wire rst_ni,
    input wire [MSHR_INDEX_WIDTH-1:0] active_probe_mshr
        /* verilator public_flat_rd */,
    input wire [COMMAND_COUNT_WIDTH-1:0] cmd_count
        /* verilator public_flat_rd */,
    input wire coherence_hart_error /* verilator public_flat_rd */,
    input wire coherence_probe_completion /* verilator public_flat_rd */,
    input wire coherence_probe_start_fire /* verilator public_flat_rd */,
    input wire [NUM_HARTS-1:0] coherence_probe_start_target
        /* verilator public_flat_rd */,
    input wire [NUM_HARTS-1:0] probe_valid_o
        /* verilator public_flat_rd */,
    input wire [NUM_HARTS-1:0] probe_ready_i
        /* verilator public_flat_rd */,
    input wire [NUM_HARTS-1:0] probe_resp_valid_i
        /* verilator public_flat_rd */,
    input wire [NUM_HARTS-1:0] probe_resp_ready_o
        /* verilator public_flat_rd */,
    input wire [NUM_HARTS-1:0] probe_resp_error_i
        /* verilator public_flat_rd */,
    input wire [NUM_HARTS-1:0] probe_issue_pending
        /* verilator public_flat_rd */,
    input wire [NUM_HARTS-1:0] probe_ack_pending
        /* verilator public_flat_rd */,
    input wire [3:0] lookup_action /* verilator public_flat_rd */,
    input wire [3:0] lookup_coh_probe /* verilator public_flat_rd */,
    input wire lookup_dispatch /* verilator public_flat_rd */,
    input wire lookup_stall /* verilator public_flat_rd */,
    input wire mshr_free_found_r /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] lookup_hart_id
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] lookup_txn_id
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] lookup_source_id
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_OP_WIDTH-1:0] lookup_op
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_KIND_WIDTH-1:0] lookup_kind
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] lookup_attr
        /* verilator public_flat_rd */,
    input wire [2:0] lookup_size /* verilator public_flat_rd */,
    input wire [63:0] lookup_addr /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] lookup_wdata
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] lookup_wstrb
        /* verilator public_flat_rd */,
    input wire lookup_protocol_error /* verilator public_flat_rd */,
    input wire lookup_sc_failed /* verilator public_flat_rd */,
    input wire mshr_valid [0:MSHR_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire [3:0] mshr_state [0:MSHR_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire [63:0] mshr_line_addr [0:MSHR_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire [NUM_HARTS-1:0] mshr_probe_target [0:MSHR_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_PROBE_CACHE_WIDTH-1:0]
        mshr_probe_cache_mask [0:MSHR_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        waiter_hart_id [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        waiter_txn_id [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        waiter_source_id [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_OP_WIDTH-1:0]
        waiter_op [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_KIND_WIDTH-1:0]
        waiter_kind [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_ATTR_WIDTH-1:0]
        waiter_attr [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [2:0] waiter_size [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [63:0] waiter_addr [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        waiter_wdata [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        waiter_wstrb [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [RESPONSE_COUNT_WIDTH-1:0] response_count
        /* verilator public_flat_rd */,

    // Detailed fields consumed by targeted Verilator diagnostics.
    input wire [MSHR_INDEX_WIDTH-1:0] active_probe_mshr_q
        /* verilator public_flat_rd */,
    input wire [COMMAND_COUNT_WIDTH-1:0] cmd_count_q
        /* verilator public_flat_rd */,
    input wire [3:0] lookup_action_r /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] lookup_hart_id_q
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] lookup_txn_id_q
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] lookup_source_id_q
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_OP_WIDTH-1:0] lookup_op_q
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_KIND_WIDTH-1:0] lookup_kind_q
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] lookup_attr_q
        /* verilator public_flat_rd */,
    input wire [2:0] lookup_size_q /* verilator public_flat_rd */,
    input wire [63:0] lookup_addr_q /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] lookup_wdata_q
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] lookup_wstrb_q
        /* verilator public_flat_rd */,
    input wire lookup_protocol_error_q /* verilator public_flat_rd */,
    input wire mshr_valid_q [0:MSHR_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire [3:0] mshr_state_q [0:MSHR_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire [63:0] mshr_line_addr_q [0:MSHR_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire [NUM_HARTS-1:0] mshr_probe_target_q [0:MSHR_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_PROBE_CACHE_WIDTH-1:0]
        mshr_probe_cache_mask_q [0:MSHR_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        waiter_hart_id_q [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        waiter_source_id_q [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_OP_WIDTH-1:0]
        waiter_op_q [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [2:0] waiter_size_q [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [63:0] waiter_addr_q [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [RESPONSE_COUNT_WIDTH-1:0] response_count_q
        /* verilator public_flat_rd */,
    input wire bus_request_fire /* verilator public_flat_rd */,
    input wire bus_response_fire /* verilator public_flat_rd */,
    input wire [MSHR_INDEX_WIDTH-1:0] bus_candidate_mshr_r
        /* verilator public_flat_rd */,
    input wire [1:0] bus_candidate_action_r
        /* verilator public_flat_rd */,
    input wire [TRACK_INDEX_WIDTH-1:0] bus_track_head_q
        /* verilator public_flat_rd */,
    input wire [MSHR_INDEX_WIDTH-1:0]
        bus_track_mshr_q [0:BUS_TRACK_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire [1:0] bus_track_action_q [0:BUS_TRACK_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire response_enqueue /* verilator public_flat_rd */,
    input wire hit_enqueue /* verilator public_flat_rd */,
    input wire replay_enqueue /* verilator public_flat_rd */,
    input wire replay_final /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] hit_data_q
        /* verilator public_flat_rd */,
    input wire [63:0] enqueue_addr /* verilator public_flat_rd */,
    input wire lookup_valid_q /* verilator public_flat_rd */,
    input wire lookup_dispatch_r /* verilator public_flat_rd */,
    input wire lookup_hit_r /* verilator public_flat_rd */,
    input wire [WAY_INDEX_WIDTH-1:0] lookup_hit_way_r
        /* verilator public_flat_rd */,
    input wire [SRAM_PAYLOAD_WIDTH-1:0] lookup_hit_payload
        /* verilator public_flat_rd */,
    input wire lookup_mshr_match_r /* verilator public_flat_rd */,
    input wire [MSHR_INDEX_WIDTH-1:0] lookup_mshr_index_r
        /* verilator public_flat_rd */,
    input wire [MSHR_INDEX_WIDTH-1:0] mshr_free_index_r
        /* verilator public_flat_rd */,
    input wire [MSHR_INDEX_WIDTH-1:0] replay_candidate_mshr_r
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        mshr_replay_data_q [0:MSHR_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire mshr_bypass_q [0:MSHR_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire mshr_bus_cacheable_q [0:MSHR_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire mshr_coh_action_q [0:MSHR_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire [3:0] mshr_post_probe_state_q [0:MSHR_ENTRIES-1]
        /* verilator public_flat_rd */,
    input wire waiter_lock_q [0:TOTAL_WAITERS-1]
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_PROBE_ID_WIDTH-1:0] probe_id_q
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_PROBE_CMD_WIDTH-1:0] probe_command_q
        /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_PROBE_CACHE_WIDTH-1:0] probe_cache_mask_q
        /* verilator public_flat_rd */,
    input wire [63:0] probe_line_addr_q /* verilator public_flat_rd */
);
    reg [63:0] perf_lookup_dispatch_q /* verilator public_flat_rd */;
    reg [63:0] perf_lookup_immediate_q /* verilator public_flat_rd */;
    reg [63:0] perf_lookup_hit_q /* verilator public_flat_rd */;
    reg [63:0] perf_lookup_merge_q /* verilator public_flat_rd */;
    reg [63:0] perf_lookup_alloc_q /* verilator public_flat_rd */;
    reg [63:0] perf_lookup_bypass_q /* verilator public_flat_rd */;
    reg [63:0] perf_lookup_write_around_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lookup_victim_hit_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lookup_probe_q /* verilator public_flat_rd */;
    reg [63:0] perf_bus_request_q /* verilator public_flat_rd */;
    reg [63:0] perf_bus_response_q /* verilator public_flat_rd */;
    reg [63:0] perf_response_enqueue_q /* verilator public_flat_rd */;
    reg [63:0] perf_hit_enqueue_q /* verilator public_flat_rd */;
    reg [63:0] perf_probe_issue_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_probe_ack_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_probe_completion_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_probe_start_q /* verilator public_flat_rd */;
    reg [63:0] perf_probe_target_q /* verilator public_flat_rd */;
    reg [63:0] perf_probe_send_q /* verilator public_flat_rd */;
    reg [63:0] perf_probe_send_wait_entry_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_probe_ack_q /* verilator public_flat_rd */;
    reg [63:0] perf_probe_ack_wait_entry_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_probe_error_q /* verilator public_flat_rd */;
    // Count the home reservation decision for every valid SC.  This includes
    // both architectural SC instructions and the conditional write half of a
    // decomposed AMO; failed AMO writes are retried by the core sequencer.
    reg [63:0] perf_atomic_store_success_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_atomic_store_failed_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_occupancy_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_full_cycles_q /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_max_occupancy_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_alloc_q /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_complete_q /* verilator public_flat_rd */;
    reg [63:0] perf_lookup_stall_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_no_free_stall_cycles_q
        /* verilator public_flat_rd */;
    integer perf_mshr_scan;
    integer perf_mshr_occupancy_r;

    always @* begin
        perf_mshr_occupancy_r = 0;
        for (perf_mshr_scan = 0; perf_mshr_scan < MSHR_ENTRIES;
             perf_mshr_scan = perf_mshr_scan + 1)
            if (mshr_valid[perf_mshr_scan])
                perf_mshr_occupancy_r = perf_mshr_occupancy_r + 1;
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            perf_lookup_dispatch_q <= 64'd0;
            perf_lookup_immediate_q <= 64'd0;
            perf_lookup_hit_q <= 64'd0;
            perf_lookup_merge_q <= 64'd0;
            perf_lookup_alloc_q <= 64'd0;
            perf_lookup_bypass_q <= 64'd0;
            perf_lookup_write_around_q <= 64'd0;
            perf_lookup_victim_hit_q <= 64'd0;
            perf_lookup_probe_q <= 64'd0;
            perf_bus_request_q <= 64'd0;
            perf_bus_response_q <= 64'd0;
            perf_response_enqueue_q <= 64'd0;
            perf_hit_enqueue_q <= 64'd0;
            perf_probe_issue_cycles_q <= 64'd0;
            perf_probe_ack_cycles_q <= 64'd0;
            perf_probe_completion_q <= 64'd0;
            perf_probe_start_q <= 64'd0;
            perf_probe_target_q <= 64'd0;
            perf_probe_send_q <= 64'd0;
            perf_probe_send_wait_entry_cycles_q <= 64'd0;
            perf_probe_ack_q <= 64'd0;
            perf_probe_ack_wait_entry_cycles_q <= 64'd0;
            perf_probe_error_q <= 64'd0;
            perf_atomic_store_success_q <= 64'd0;
            perf_atomic_store_failed_q <= 64'd0;
            perf_mshr_occupancy_cycles_q <= 64'd0;
            perf_mshr_full_cycles_q <= 64'd0;
            perf_mshr_max_occupancy_q <= 64'd0;
            perf_mshr_alloc_q <= 64'd0;
            perf_mshr_complete_q <= 64'd0;
            perf_lookup_stall_cycles_q <= 64'd0;
            perf_mshr_no_free_stall_cycles_q <= 64'd0;
        end else begin
            if (lookup_dispatch) begin
                perf_lookup_dispatch_q <= perf_lookup_dispatch_q + 1'b1;
                case (lookup_action)
                    4'd1: perf_lookup_immediate_q <=
                        perf_lookup_immediate_q + 1'b1;
                    4'd2: perf_lookup_hit_q <= perf_lookup_hit_q + 1'b1;
                    4'd3: perf_lookup_merge_q <=
                        perf_lookup_merge_q + 1'b1;
                    4'd4: perf_lookup_alloc_q <=
                        perf_lookup_alloc_q + 1'b1;
                    4'd5: perf_lookup_bypass_q <=
                        perf_lookup_bypass_q + 1'b1;
                    4'd6: perf_lookup_write_around_q <=
                        perf_lookup_write_around_q + 1'b1;
                    4'd7: perf_lookup_victim_hit_q <=
                        perf_lookup_victim_hit_q + 1'b1;
                    4'd8: perf_lookup_probe_q <=
                        perf_lookup_probe_q + 1'b1;
                    default: begin end
                endcase
            end
            if (bus_request_fire)
                perf_bus_request_q <= perf_bus_request_q + 1'b1;
            if (bus_response_fire)
                perf_bus_response_q <= perf_bus_response_q + 1'b1;
            if (response_enqueue)
                perf_response_enqueue_q <=
                    perf_response_enqueue_q + 1'b1;
            if (hit_enqueue)
                perf_hit_enqueue_q <= perf_hit_enqueue_q + 1'b1;
            if (|probe_issue_pending)
                perf_probe_issue_cycles_q <=
                    perf_probe_issue_cycles_q + 1'b1;
            if (|probe_ack_pending)
                perf_probe_ack_cycles_q <=
                    perf_probe_ack_cycles_q + 1'b1;
            if (coherence_probe_completion)
                perf_probe_completion_q <=
                    perf_probe_completion_q + 1'b1;
            if (coherence_probe_start_fire) begin
                perf_probe_start_q <= perf_probe_start_q + 1'b1;
                perf_probe_target_q <= perf_probe_target_q +
                    $countones(coherence_probe_start_target);
            end
            perf_probe_send_q <= perf_probe_send_q +
                $countones(probe_valid_o & probe_ready_i);
            perf_probe_send_wait_entry_cycles_q <=
                perf_probe_send_wait_entry_cycles_q +
                $countones(probe_valid_o & ~probe_ready_i);
            perf_probe_ack_q <= perf_probe_ack_q +
                $countones(probe_resp_valid_i & probe_resp_ready_o);
            perf_probe_ack_wait_entry_cycles_q <=
                perf_probe_ack_wait_entry_cycles_q +
                $countones(probe_resp_valid_i & ~probe_resp_ready_o);
            perf_probe_error_q <= perf_probe_error_q +
                $countones(probe_resp_valid_i & probe_resp_ready_o &
                           probe_resp_error_i);
            if (lookup_dispatch &&
                (lookup_op == `OPENRV64_ICX_OP_SC) &&
                !lookup_protocol_error && !coherence_hart_error) begin
                if (lookup_sc_failed)
                    perf_atomic_store_failed_q <=
                        perf_atomic_store_failed_q + 1'b1;
                else
                    perf_atomic_store_success_q <=
                        perf_atomic_store_success_q + 1'b1;
            end
            perf_mshr_occupancy_cycles_q <=
                perf_mshr_occupancy_cycles_q + perf_mshr_occupancy_r;
            if (perf_mshr_occupancy_r == MSHR_ENTRIES)
                perf_mshr_full_cycles_q <=
                    perf_mshr_full_cycles_q + 1'b1;
            if (perf_mshr_occupancy_r > perf_mshr_max_occupancy_q)
                perf_mshr_max_occupancy_q <= perf_mshr_occupancy_r;
            if (lookup_dispatch &&
                ((lookup_action == 4'd4) ||
                 (lookup_action == 4'd5) ||
                 (lookup_action == 4'd6) ||
                 (lookup_action == 4'd8)))
                perf_mshr_alloc_q <= perf_mshr_alloc_q + 1'b1;
            if (replay_enqueue && replay_final)
                perf_mshr_complete_q <= perf_mshr_complete_q + 1'b1;
            if (lookup_stall)
                perf_lookup_stall_cycles_q <=
                    perf_lookup_stall_cycles_q + 1'b1;
            if (lookup_stall && !mshr_free_found_r)
                perf_mshr_no_free_stall_cycles_q <=
                    perf_mshr_no_free_stall_cycles_q + 1'b1;
        end
    end
endmodule
/* verilator lint_on DECLFILENAME */
