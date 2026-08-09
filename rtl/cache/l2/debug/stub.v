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
    input wire [MSHR_INDEX_WIDTH-1:0] active_probe_mshr
        /* verilator public_flat_rd */,
    input wire [COMMAND_COUNT_WIDTH-1:0] cmd_count
        /* verilator public_flat_rd */,
    input wire coherence_hart_error /* verilator public_flat_rd */,
    input wire coherence_probe_completion /* verilator public_flat_rd */,
    input wire [NUM_HARTS-1:0] probe_issue_pending
        /* verilator public_flat_rd */,
    input wire [NUM_HARTS-1:0] probe_ack_pending
        /* verilator public_flat_rd */,
    input wire [3:0] lookup_action /* verilator public_flat_rd */,
    input wire [3:0] lookup_coh_probe /* verilator public_flat_rd */,
    input wire lookup_dispatch /* verilator public_flat_rd */,
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
endmodule
/* verilator lint_on DECLFILENAME */
