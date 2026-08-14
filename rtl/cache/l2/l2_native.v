`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "complex/coherent/protocol/defs.v"
`include "soc/bus/mem_map.v"

// Native 512-bit, nonblocking shared L2.
//
// Cache fills and evictions move complete 64-byte lines.  A cacheable write
// miss may instead write around as one naturally aligned scalar request with
// line-relative data and strobes.  Width conversion belongs below this module
// in genbus_interface.  A command FIFO feeds a synchronous per-way SRAM lookup
// followed by a registered hit stage, allowing requests to continue behind
// outstanding fills.  Independent per-line MSHRs merge requests to an active
// miss, while an ordered bus tracking FIFO permits multiple writebacks/refills
// to be accepted by the external bus abstraction.
module openrv64_icx_l2_native #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer CACHE_BYTES = 256 * 1024,
    parameter integer LINE_BYTES = `OPENRV64_ICX_LINE_BYTES,
    parameter integer WAYS = 8,
    parameter integer MSHR_ENTRIES = 8,
    parameter integer WAITERS_PER_MSHR = 8,
    parameter integer COMMAND_ENTRIES = 16,
    parameter integer RESPONSE_ENTRIES = 16,
    parameter integer BUS_TRACK_ENTRIES = MSHR_ENTRIES,
    parameter integer PTE_GENERATION_BITS = 8,
    parameter [63:0] INVARIANT_BASE = `OPENRV64_SOC_INVARIANT_BASE,
    parameter integer ENABLE_COHERENCE = 0,
    parameter integer NUM_HARTS = 1,
    parameter integer HART_ID_BASE = 0,
    parameter integer DIRECTORY_ENTRIES = 256,
    parameter integer DIRECTORY_WAYS = 4,
    parameter integer DIRECTORY_ENTRY_WIDTH =
        (DIRECTORY_ENTRIES > 1) ? $clog2(DIRECTORY_ENTRIES) : 1
) (
    input  wire clk_i,
    input  wire rst_ni,

    input  wire                         req_valid_i,
    output wire                         req_ready_o,
    input  wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] req_hart_id_i,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] req_txn_id_i,
    input  wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] req_source_id_i,
    input  wire [`OPENRV64_ICX_OP_WIDTH-1:0] req_op_i,
    input  wire                         req_lock_i,
    input  wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] req_order_i,
    input  wire [`OPENRV64_ICX_KIND_WIDTH-1:0] req_kind_i,
    input  wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] req_attr_i,
    input  wire [2:0]                   req_size_i,
    input  wire [63:0]                  req_addr_i,
    input  wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] req_burst_len_i,

    input  wire                         wdata_valid_i,
    output wire                         wdata_ready_o,
    input  wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] wdata_hart_id_i,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] wdata_txn_id_i,
    input  wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] wdata_source_id_i,
    input  wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] wdata_beat_index_i,
    input  wire                         wdata_last_i,
    input  wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] wdata_i,
    input  wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] wstrb_i,

    output wire                         resp_valid_o,
    input  wire                         resp_ready_i,
    output wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] resp_hart_id_o,
    output wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] resp_txn_id_o,
    output wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] resp_source_id_o,
    output wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] resp_beat_index_o,
    output wire                         resp_last_o,
    output wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] resp_rdata_o,
    output wire                         resp_error_o,
    output wire                         resp_sc_success_o,

    output wire [NUM_HARTS-1:0]         probe_valid_o,
    input  wire [NUM_HARTS-1:0]         probe_ready_i,
    output wire [NUM_HARTS*`OPENRV64_ICX_PROBE_ID_WIDTH-1:0]
                                               probe_id_o,
    output wire [NUM_HARTS*`OPENRV64_ICX_PROBE_CMD_WIDTH-1:0]
                                               probe_command_o,
    output wire [NUM_HARTS*`OPENRV64_ICX_PROBE_CACHE_WIDTH-1:0]
                                               probe_cache_mask_o,
    output wire [NUM_HARTS*64-1:0]      probe_line_addr_o,
    input  wire [NUM_HARTS-1:0]         probe_resp_valid_i,
    output wire [NUM_HARTS-1:0]         probe_resp_ready_o,
    input  wire [NUM_HARTS*`OPENRV64_ICX_PROBE_ID_WIDTH-1:0]
                                               probe_resp_id_i,
    input  wire [NUM_HARTS*`OPENRV64_ICX_PROBE_RESP_WIDTH-1:0]
                                               probe_resp_kind_i,
    input  wire [NUM_HARTS*`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
                                               probe_resp_data_i,
    input  wire [NUM_HARTS-1:0]         probe_resp_error_i,
    input  wire                         protocol_error_clear_i,
    output wire                         protocol_error_o,

    output wire                         bus_req_valid_o,
    input  wire                         bus_req_ready_i,
    output reg                          bus_req_write_o,
    output reg  [63:0]                  bus_req_addr_o,
    output reg  [2:0]                   bus_req_size_o,
    output reg  [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] bus_req_wdata_o,
    output reg  [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] bus_req_wstrb_o,
    output reg                          bus_req_cacheable_o,
    input  wire                         bus_resp_valid_i,
    output wire                         bus_resp_ready_o,
    input  wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] bus_resp_rdata_i,
    input  wire                         bus_resp_error_i
);

    localparam integer SETS = CACHE_BYTES / (LINE_BYTES * WAYS);
    localparam integer LINE_OFFSET_BITS = $clog2(LINE_BYTES);
    localparam integer SET_BITS = $clog2(SETS);
    localparam integer TAG_BITS = ADDR_WIDTH - LINE_OFFSET_BITS - SET_BITS;
    localparam integer SRAM_TAG_BITS =
        TAG_BITS + PTE_GENERATION_BITS;
    localparam integer SRAM_PAYLOAD_WIDTH =
        `OPENRV64_ICX_LINE_DATA_WIDTH +
        `OPENRV64_ICX_LINE_STRB_WIDTH;
    localparam integer SET_INDEX_WIDTH = (SETS > 1) ? $clog2(SETS) : 1;
    localparam integer WAY_INDEX_WIDTH = (WAYS > 1) ? $clog2(WAYS) : 1;
    localparam integer MSHR_INDEX_WIDTH =
        (MSHR_ENTRIES > 1) ? $clog2(MSHR_ENTRIES) : 1;
    localparam integer MSHR_COUNT_WIDTH = $clog2(MSHR_ENTRIES + 1);
    localparam integer WAITER_INDEX_WIDTH =
        (WAITERS_PER_MSHR > 1) ? $clog2(WAITERS_PER_MSHR) : 1;
    localparam integer WAITER_COUNT_WIDTH =
        $clog2(WAITERS_PER_MSHR + 1);
    localparam integer TOTAL_WAITERS = MSHR_ENTRIES * WAITERS_PER_MSHR;
    localparam integer COMMAND_INDEX_WIDTH =
        (COMMAND_ENTRIES > 1) ? $clog2(COMMAND_ENTRIES) : 1;
    localparam integer COMMAND_COUNT_WIDTH = $clog2(COMMAND_ENTRIES + 1);
    localparam integer RESPONSE_INDEX_WIDTH =
        (RESPONSE_ENTRIES > 1) ? $clog2(RESPONSE_ENTRIES) : 1;
    localparam integer RESPONSE_COUNT_WIDTH =
        $clog2(RESPONSE_ENTRIES + 1);
    localparam integer TRACK_INDEX_WIDTH =
        (BUS_TRACK_ENTRIES > 1) ? $clog2(BUS_TRACK_ENTRIES) : 1;
    localparam integer TRACK_COUNT_WIDTH =
        $clog2(BUS_TRACK_ENTRIES + 1);
    localparam integer DIRECTORY_SETS =
        DIRECTORY_ENTRIES / DIRECTORY_WAYS;
    localparam integer DIRECTORY_SET_WIDTH =
        (DIRECTORY_SETS > 1) ? $clog2(DIRECTORY_SETS) : 1;

    localparam [3:0] MSHR_IDLE            = 4'd0;
    localparam [3:0] MSHR_NEED_WB         = 4'd1;
    localparam [3:0] MSHR_WB_INFLIGHT     = 4'd2;
    localparam [3:0] MSHR_NEED_FILL       = 4'd3;
    localparam [3:0] MSHR_FILL_INFLIGHT   = 4'd4;
    localparam [3:0] MSHR_NEED_BYPASS     = 4'd5;
    localparam [3:0] MSHR_BYPASS_INFLIGHT = 4'd6;
    localparam [3:0] MSHR_REPLAY          = 4'd7;
    localparam [3:0] MSHR_ERROR           = 4'd8;
    localparam [3:0] MSHR_NEED_PROBE      = 4'd9;
    localparam [3:0] MSHR_PROBE_INFLIGHT  = 4'd10;

    localparam [1:0] BUS_ACTION_WB     = 2'd0;
    localparam [1:0] BUS_ACTION_FILL   = 2'd1;
    localparam [1:0] BUS_ACTION_BYPASS = 2'd2;

    localparam [3:0] LOOKUP_NONE      = 4'd0;
    localparam [3:0] LOOKUP_IMMEDIATE = 4'd1;
    localparam [3:0] LOOKUP_HIT       = 4'd2;
    localparam [3:0] LOOKUP_MERGE     = 4'd3;
    localparam [3:0] LOOKUP_ALLOC     = 4'd4;
    localparam [3:0] LOOKUP_BYPASS    = 4'd5;
    localparam [3:0] LOOKUP_WRITE_AROUND = 4'd6;
    localparam [3:0] LOOKUP_VICTIM_HIT = 4'd7;
    localparam [3:0] LOOKUP_COH_PROBE = 4'd8;

    localparam COH_ACTION_ALLOCATE = 1'b0;
    localparam COH_ACTION_CLEAR = 1'b1;

    reg [WAYS-1:0] valid_q [0:SETS-1];
    reg [WAYS-1:0] dirty_q [0:SETS-1];
    // dirty_q is the fast summary bit.  The exact byte mask is stored beside
    // the complete line in the data SRAM payload.
    reg [WAYS-1:0] reserved_q [0:SETS-1];
    reg [WAY_INDEX_WIDTH-1:0] replace_q [0:SETS-1];
    reg [PTE_GENERATION_BITS-1:0] pte_generation_q;
    wire [WAYS*SRAM_PAYLOAD_WIDTH-1:0] sram_way_payload;
    wire [WAYS*SRAM_TAG_BITS-1:0] sram_way_tag;
    reg sram_write_valid_r;
    reg [SET_INDEX_WIDTH-1:0] sram_write_set_r;
    reg [WAY_INDEX_WIDTH-1:0] sram_write_way_r;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] sram_write_data_r;
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] sram_write_strb_r;
    reg sram_write_tag_r;
    reg [SRAM_TAG_BITS-1:0] sram_write_tag_data_r;
    wire lookup_sram_write_blocked;

    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        cmd_hart_id_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        cmd_txn_id_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        cmd_source_id_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_ICX_OP_WIDTH-1:0]
        cmd_op_q [0:COMMAND_ENTRIES-1];
    reg cmd_lock_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_ICX_ORDER_WIDTH-1:0]
        cmd_order_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_ICX_KIND_WIDTH-1:0]
        cmd_kind_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_ICX_ATTR_WIDTH-1:0]
        cmd_attr_q [0:COMMAND_ENTRIES-1];
    reg [2:0] cmd_size_q [0:COMMAND_ENTRIES-1];
    reg [63:0] cmd_addr_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
        cmd_burst_len_q [0:COMMAND_ENTRIES-1];
    reg cmd_entry_valid_q [0:COMMAND_ENTRIES-1];
    reg [COMMAND_INDEX_WIDTH-1:0] cmd_head_q;
    reg [COMMAND_INDEX_WIDTH-1:0] cmd_tail_q;
    reg [COMMAND_COUNT_WIDTH-1:0] cmd_count_q;
    reg [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] cmd_beat_q;
    reg cmd_wdata_valid_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        cmd_wdata_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        cmd_wstrb_q [0:COMMAND_ENTRIES-1];
    reg cmd_wdata_error_q [0:COMMAND_ENTRIES-1];

    reg lookup_valid_q;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] lookup_hart_id_q;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] lookup_txn_id_q;
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] lookup_source_id_q;
    reg [`OPENRV64_ICX_OP_WIDTH-1:0] lookup_op_q;
    reg lookup_lock_q;
    reg [`OPENRV64_ICX_ORDER_WIDTH-1:0] lookup_order_q;
    reg [`OPENRV64_ICX_KIND_WIDTH-1:0] lookup_kind_q;
    reg [`OPENRV64_ICX_ATTR_WIDTH-1:0] lookup_attr_q;
    reg [2:0] lookup_size_q;
    reg [63:0] lookup_addr_q;
    reg [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] lookup_beat_q;
    reg lookup_last_q;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] lookup_wdata_q;
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] lookup_wstrb_q;
    reg lookup_protocol_error_q;

    reg hit_valid_q;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] hit_hart_id_q;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] hit_txn_id_q;
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] hit_source_id_q;
    reg [`OPENRV64_ICX_OP_WIDTH-1:0] hit_op_q;
    reg hit_lock_q;
    reg [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] hit_beat_q;
    reg hit_last_q;
    reg [63:0] hit_addr_q;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] hit_data_q;
    reg hit_error_q;
    reg hit_sc_success_q;
    reg hit_private_fill_q;

    reg mshr_valid_q [0:MSHR_ENTRIES-1];
    reg mshr_bypass_q [0:MSHR_ENTRIES-1];
    reg [3:0] mshr_state_q [0:MSHR_ENTRIES-1];
    reg [63:0] mshr_line_addr_q [0:MSHR_ENTRIES-1];
    reg [SET_INDEX_WIDTH-1:0] mshr_set_q [0:MSHR_ENTRIES-1];
    reg [TAG_BITS-1:0] mshr_tag_q [0:MSHR_ENTRIES-1];
    reg [WAY_INDEX_WIDTH-1:0] mshr_way_q [0:MSHR_ENTRIES-1];
    reg [PTE_GENERATION_BITS-1:0]
        mshr_pte_generation_q [0:MSHR_ENTRIES-1];
    reg [63:0] mshr_victim_addr_q [0:MSHR_ENTRIES-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        mshr_victim_data_q [0:MSHR_ENTRIES-1];
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        mshr_victim_strb_q [0:MSHR_ENTRIES-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        mshr_replay_data_q [0:MSHR_ENTRIES-1];
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        mshr_replay_strb_q [0:MSHR_ENTRIES-1];
    reg [WAITER_COUNT_WIDTH-1:0] mshr_waiter_count_q [0:MSHR_ENTRIES-1];
    reg [WAITER_INDEX_WIDTH-1:0] mshr_replay_q [0:MSHR_ENTRIES-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        mshr_bypass_data_q [0:MSHR_ENTRIES-1];
    reg mshr_bus_cacheable_q [0:MSHR_ENTRIES-1];
    reg mshr_error_q [0:MSHR_ENTRIES-1];
    reg mshr_private_fill_q [0:MSHR_ENTRIES-1];
    reg mshr_coh_action_q [0:MSHR_ENTRIES-1];
    reg [3:0] mshr_post_probe_state_q [0:MSHR_ENTRIES-1];
    reg [DIRECTORY_ENTRY_WIDTH-1:0]
        mshr_directory_entry_q [0:MSHR_ENTRIES-1];
    reg [NUM_HARTS-1:0] mshr_probe_target_q [0:MSHR_ENTRIES-1];
    reg [`OPENRV64_ICX_PROBE_CACHE_WIDTH-1:0]
        mshr_probe_cache_mask_q [0:MSHR_ENTRIES-1];
    reg [63:0] mshr_probe_line_addr_q [0:MSHR_ENTRIES-1];
    reg [NUM_HARTS-1:0] mshr_directory_add_i_q [0:MSHR_ENTRIES-1];
    reg [NUM_HARTS-1:0] mshr_directory_add_d_q [0:MSHR_ENTRIES-1];
    reg [NUM_HARTS-1:0] mshr_directory_clear_d_q [0:MSHR_ENTRIES-1];

    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        waiter_hart_id_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        waiter_txn_id_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        waiter_source_id_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_ICX_OP_WIDTH-1:0]
        waiter_op_q [0:TOTAL_WAITERS-1];
    reg waiter_lock_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_ICX_ORDER_WIDTH-1:0]
        waiter_order_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_ICX_KIND_WIDTH-1:0]
        waiter_kind_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_ICX_ATTR_WIDTH-1:0]
        waiter_attr_q [0:TOTAL_WAITERS-1];
    reg [2:0] waiter_size_q [0:TOTAL_WAITERS-1];
    reg [63:0] waiter_addr_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        waiter_beat_q [0:TOTAL_WAITERS-1];
    reg waiter_last_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        waiter_wdata_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        waiter_wstrb_q [0:TOTAL_WAITERS-1];

    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
        response_hart_id_q [0:RESPONSE_ENTRIES-1];
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        response_txn_id_q [0:RESPONSE_ENTRIES-1];
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
        response_source_id_q [0:RESPONSE_ENTRIES-1];
    reg [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
        response_beat_q [0:RESPONSE_ENTRIES-1];
    reg response_last_q [0:RESPONSE_ENTRIES-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        response_data_q [0:RESPONSE_ENTRIES-1];
    reg response_error_q [0:RESPONSE_ENTRIES-1];
    reg response_sc_success_q [0:RESPONSE_ENTRIES-1];
    reg response_private_fill_q [0:RESPONSE_ENTRIES-1];
    reg [DIRECTORY_SET_WIDTH-1:0]
        response_directory_set_q [0:RESPONSE_ENTRIES-1];
    reg [RESPONSE_INDEX_WIDTH-1:0] response_head_q;
    reg [RESPONSE_INDEX_WIDTH-1:0] response_tail_q;
    reg [RESPONSE_COUNT_WIDTH-1:0] response_count_q;

    reg [MSHR_INDEX_WIDTH-1:0]
        bus_track_mshr_q [0:BUS_TRACK_ENTRIES-1];
    reg [1:0] bus_track_action_q [0:BUS_TRACK_ENTRIES-1];
    reg [TRACK_INDEX_WIDTH-1:0] bus_track_head_q;
    reg [TRACK_INDEX_WIDTH-1:0] bus_track_tail_q;
    reg [TRACK_COUNT_WIDTH-1:0] bus_track_count_q;
    reg [MSHR_INDEX_WIDTH-1:0] bus_round_robin_q;
    reg [MSHR_INDEX_WIDTH-1:0] replay_round_robin_q;

    reg lock_active_q;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] lock_hart_id_q;
    reg [63:0] lock_line_addr_q;

    integer reset_index;
    integer command_reset_index;
    integer response_reset_index;
    integer set_reset_index;
    integer active_scan;
    integer lookup_way_scan;
    integer lookup_mshr_scan;
    integer lookup_candidate_index;
    integer bus_scan;
    integer bus_candidate_index;
    integer replay_scan;
    integer replay_candidate_index;
    integer lookup_write_byte;
    integer replay_write_byte;
    integer bus_waiter_index;
    integer replay_waiter_index;
    integer wdata_scan;

    reg lookup_hit_r;
    reg [WAY_INDEX_WIDTH-1:0] lookup_hit_way_r;
    reg lookup_stale_pte_r;
    reg [WAY_INDEX_WIDTH-1:0] lookup_stale_pte_way_r;
    reg lookup_mshr_match_r;
    reg [MSHR_INDEX_WIDTH-1:0] lookup_mshr_index_r;
    reg lookup_mshr_mergeable_r;
    reg lookup_dirty_victim_match_r;
    reg [MSHR_INDEX_WIDTH-1:0] lookup_dirty_victim_index_r;
    reg mshr_free_found_r;
    reg [MSHR_INDEX_WIDTH-1:0] mshr_free_index_r;
    reg victim_found_r;
    reg [WAY_INDEX_WIDTH-1:0] victim_way_r;
    reg [3:0] lookup_action_r;
    reg [3:0] lookup_base_action_r;
    reg lookup_dispatch_r;
    reg bus_candidate_found_r;
    reg [MSHR_INDEX_WIDTH-1:0] bus_candidate_mshr_r;
    reg [1:0] bus_candidate_action_r;
    reg replay_candidate_found_r;
    reg [MSHR_INDEX_WIDTH-1:0] replay_candidate_mshr_r;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] lookup_write_data_r;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] replay_write_data_r;
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] replay_write_strb_r;
    reg wdata_match_found_r;
    reg wdata_match_multiple_r;
    reg [COMMAND_INDEX_WIDTH-1:0] wdata_match_index_r;
    reg lookup_request_hart_valid_r;
    reg [NUM_HARTS-1:0] lookup_request_hart_mask_r;
    reg lookup_sc_reservation_match_r;
    reg coherence_set_locked_r;
    reg coherence_pending_fill_set_locked_r;
    reg probe_candidate_found_r;
    reg [MSHR_INDEX_WIDTH-1:0] probe_candidate_mshr_r;
    reg [NUM_HARTS-1:0] bad_probe_response_r;
    reg protocol_error_q;
    reg lookup_coh_response_seen_q;
    reg [MSHR_INDEX_WIDTH-1:0] active_probe_mshr_q;
    reg [`OPENRV64_ICX_PROBE_ID_WIDTH-1:0] next_probe_id_q;
    reg [NUM_HARTS-1:0] reservation_valid_q;
    reg [63:0] reservation_line_q [0:NUM_HARTS-1];
    integer lookup_hart_scan;
    integer coherence_lock_scan;
    integer coherence_response_lock_scan;
    integer probe_scan;
    integer probe_candidate_index;
    integer bad_probe_scan;
    integer reservation_scan;
    wire lookup_capture;

    wire command_queue_full =
        (cmd_count_q == COMMAND_COUNT_WIDTH'(COMMAND_ENTRIES));
    wire [63:0] incoming_line_addr =
        {req_addr_i[63:LINE_OFFSET_BITS], {LINE_OFFSET_BITS{1'b0}}};
    wire incoming_lock_allowed = !lock_active_q ||
        (req_lock_i && (req_hart_id_i == lock_hart_id_q) &&
         (incoming_line_addr == lock_line_addr_q));
    assign req_ready_o = !command_queue_full && incoming_lock_allowed;
    wire command_push = req_valid_i && req_ready_o;

    wire cmd_head_write =
        (cmd_op_q[cmd_head_q] == `OPENRV64_ICX_OP_WRITE) ||
        ((ENABLE_COHERENCE != 0) &&
         (cmd_op_q[cmd_head_q] == `OPENRV64_ICX_OP_SC));
    wire cmd_head_line = cmd_size_q[cmd_head_q] == 3'd6;
    wire cmd_head_last = cmd_beat_q == cmd_burst_len_q[cmd_head_q];
    wire [63:0] cmd_head_line_addr =
        {cmd_addr_q[cmd_head_q][63:LINE_OFFSET_BITS],
         {LINE_OFFSET_BITS{1'b0}}} + (cmd_beat_q * LINE_BYTES);
    wire [63:0] cmd_head_effective_addr =
        cmd_head_line ? cmd_head_line_addr : cmd_addr_q[cmd_head_q];
    wire [SET_INDEX_WIDTH-1:0] cmd_head_set =
        cmd_head_effective_addr[
            LINE_OFFSET_BITS +: SET_INDEX_WIDTH];
    wire cmd_head_op_supported =
        (cmd_op_q[cmd_head_q] == `OPENRV64_ICX_OP_READ) ||
        (cmd_op_q[cmd_head_q] == `OPENRV64_ICX_OP_WRITE) ||
        (cmd_op_q[cmd_head_q] == `OPENRV64_ICX_OP_FENCE) ||
        ((ENABLE_COHERENCE != 0) &&
         ((cmd_op_q[cmd_head_q] == `OPENRV64_ICX_OP_LR) ||
          (cmd_op_q[cmd_head_q] == `OPENRV64_ICX_OP_SC)));
    wire cmd_head_protocol_error =
        !cmd_head_op_supported ||
        ((cmd_burst_len_q[cmd_head_q] != 0) && !cmd_head_line) ||
        (cmd_head_line &&
         (cmd_addr_q[cmd_head_q][LINE_OFFSET_BITS-1:0] != 0)) ||
        (!cmd_head_line && (cmd_size_q[cmd_head_q] > 3'd3)) ||
        (cmd_lock_q[cmd_head_q] &&
         (cmd_head_line || (cmd_burst_len_q[cmd_head_q] != 0)));
    // Write data is independently backpressured and tagged.  Buffer one
    // pending beat with every queued command so a stalled head does not block
    // data belonging to a later command.  Only the head can have advanced
    // beyond beat zero.
    always @* begin
        wdata_match_found_r = 1'b0;
        wdata_match_multiple_r = 1'b0;
        wdata_match_index_r = 0;
        for (wdata_scan = 0; wdata_scan < COMMAND_ENTRIES;
             wdata_scan = wdata_scan + 1) begin
            if (cmd_entry_valid_q[wdata_scan] &&
                ((cmd_op_q[wdata_scan] == `OPENRV64_ICX_OP_WRITE) ||
                 ((ENABLE_COHERENCE != 0) &&
                  (cmd_op_q[wdata_scan] == `OPENRV64_ICX_OP_SC))) &&
                !cmd_wdata_valid_q[wdata_scan] &&
                (wdata_hart_id_i == cmd_hart_id_q[wdata_scan]) &&
                (wdata_txn_id_i == cmd_txn_id_q[wdata_scan]) &&
                (wdata_source_id_i == cmd_source_id_q[wdata_scan]) &&
                (wdata_beat_index_i ==
                    ((COMMAND_INDEX_WIDTH'(wdata_scan) == cmd_head_q) ?
                        cmd_beat_q :
                        `OPENRV64_ICX_BEAT_INDEX_WIDTH'(0)))) begin
                if (wdata_match_found_r)
                    wdata_match_multiple_r = 1'b1;
                else
                    wdata_match_index_r =
                        COMMAND_INDEX_WIDTH'(wdata_scan);
                wdata_match_found_r = 1'b1;
            end
        end
    end
    assign wdata_ready_o =
        wdata_match_found_r && !wdata_match_multiple_r;
    wire wdata_fire = wdata_valid_i && wdata_ready_o;

    wire response_dequeue = resp_valid_o && resp_ready_i;
    wire response_space =
        (response_count_q < RESPONSE_COUNT_WIDTH'(RESPONSE_ENTRIES)) ||
        response_dequeue;
    wire hit_enqueue = hit_valid_q && response_space;
    wire hit_slot_ready = !hit_valid_q || hit_enqueue;

    wire lookup_cacheable =
        |(lookup_attr_q & `OPENRV64_ICX_ATTR_CACHEABLE) &&
        !(|(lookup_attr_q & `OPENRV64_ICX_ATTR_DEVICE));
    wire [63:0] lookup_line_addr =
        {lookup_addr_q[63:LINE_OFFSET_BITS], {LINE_OFFSET_BITS{1'b0}}};
    wire [SET_INDEX_WIDTH-1:0] lookup_set =
        lookup_addr_q[LINE_OFFSET_BITS +: SET_INDEX_WIDTH];
    wire [TAG_BITS-1:0] lookup_tag =
        lookup_addr_q[ADDR_WIDTH-1:LINE_OFFSET_BITS + SET_BITS];
    wire [SRAM_PAYLOAD_WIDTH-1:0] lookup_hit_payload =
        sram_way_payload[
            lookup_hit_way_r*SRAM_PAYLOAD_WIDTH +:
            SRAM_PAYLOAD_WIDTH];
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] lookup_hit_data =
        lookup_hit_payload[0 +: `OPENRV64_ICX_LINE_DATA_WIDTH];
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] lookup_hit_dirty_strb =
        lookup_hit_payload[`OPENRV64_ICX_LINE_DATA_WIDTH +:
                           `OPENRV64_ICX_LINE_STRB_WIDTH];
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] lookup_shifted_data =
        lookup_hit_data >> (lookup_addr_q[5:3] * 64);
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] lookup_read_data =
        (lookup_size_q == 3'd6) ? lookup_hit_data :
            ({{448{1'b0}}, lookup_shifted_data[63:0]} <<
             (lookup_addr_q[5:3] * 64));
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        lookup_dirty_victim_data =
            mshr_victim_data_q[lookup_dirty_victim_index_r];
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        lookup_dirty_victim_shifted_data =
            lookup_dirty_victim_data >> (lookup_addr_q[5:3] * 64);
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        lookup_dirty_victim_read_data =
            (lookup_size_q == 3'd6) ? lookup_dirty_victim_data :
            ({{448{1'b0}},
              lookup_dirty_victim_shifted_data[63:0]} <<
             (lookup_addr_q[5:3] * 64));
    wire [SRAM_PAYLOAD_WIDTH-1:0] lookup_victim_payload =
        sram_way_payload[
            victim_way_r*SRAM_PAYLOAD_WIDTH +:
            SRAM_PAYLOAD_WIDTH];
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] lookup_victim_data =
        lookup_victim_payload[0 +: `OPENRV64_ICX_LINE_DATA_WIDTH];
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        lookup_victim_dirty_strb =
            lookup_victim_payload[`OPENRV64_ICX_LINE_DATA_WIDTH +:
                                  `OPENRV64_ICX_LINE_STRB_WIDTH];
    wire [TAG_BITS-1:0] lookup_victim_tag =
        sram_way_tag[victim_way_r*SRAM_TAG_BITS +: TAG_BITS];

    reg [MSHR_COUNT_WIDTH-1:0] active_mshr_count_r;
    always @* begin
        active_mshr_count_r = 0;
        for (active_scan = 0; active_scan < MSHR_ENTRIES;
             active_scan = active_scan + 1)
            if (mshr_valid_q[active_scan])
                active_mshr_count_r = active_mshr_count_r + 1'b1;
    end

    wire fence_drain_complete =
        (active_mshr_count_r == 0) &&
        (bus_track_count_q == 0) &&
        (response_count_q == 0) &&
        !hit_valid_q;
    wire lookup_is_pte =
        lookup_kind_q == `OPENRV64_ICX_KIND_PTE;
    wire lookup_is_read =
        (lookup_op_q == `OPENRV64_ICX_OP_READ) ||
        ((ENABLE_COHERENCE != 0) &&
         (lookup_op_q == `OPENRV64_ICX_OP_LR));
    wire lookup_is_write =
        (lookup_op_q == `OPENRV64_ICX_OP_WRITE) ||
        ((ENABLE_COHERENCE != 0) &&
         (lookup_op_q == `OPENRV64_ICX_OP_SC));

    wire lookup_invariant_match;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] lookup_invariant_data;
    wire lookup_invariant_read_fire;
    openrv64_l2_invariant_pages #(
        .BASE(INVARIANT_BASE)
    ) u_invariant_pages (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .addr_i(lookup_addr_q),
        .read_fire_i(lookup_invariant_read_fire),
        .match_o(lookup_invariant_match),
        .random_match_o(),
        .rdata_o(lookup_invariant_data)
    );
    wire lookup_private_fill =
        (ENABLE_COHERENCE != 0) && !lookup_invariant_match &&
        lookup_cacheable && lookup_is_read &&
        ((lookup_source_id_q == `OPENRV64_ICX_SOURCE_ICACHE) ||
         (lookup_source_id_q == `OPENRV64_ICX_SOURCE_DCACHE));
    wire lookup_coherent_write =
        (ENABLE_COHERENCE != 0) && !lookup_invariant_match &&
        lookup_cacheable && lookup_is_write;

    always @* begin
        lookup_request_hart_valid_r = 1'b0;
        lookup_request_hart_mask_r = {NUM_HARTS{1'b0}};
        lookup_sc_reservation_match_r = 1'b0;
        for (lookup_hart_scan = 0; lookup_hart_scan < NUM_HARTS;
             lookup_hart_scan = lookup_hart_scan + 1) begin
            if (lookup_hart_id_q ==
                `OPENRV64_ICX_HART_ID_WIDTH'(
                    HART_ID_BASE + lookup_hart_scan)) begin
                lookup_request_hart_valid_r = 1'b1;
                lookup_request_hart_mask_r[lookup_hart_scan] = 1'b1;
                lookup_sc_reservation_match_r =
                    reservation_valid_q[lookup_hart_scan] &&
                    (reservation_line_q[lookup_hart_scan] ==
                     lookup_line_addr);
            end
        end
    end

    wire coherence_hart_error =
        (ENABLE_COHERENCE != 0) && !lookup_request_hart_valid_r;
    assign lookup_invariant_read_fire = lookup_dispatch_r &&
        lookup_invariant_match &&
        (lookup_op_q == `OPENRV64_ICX_OP_READ) &&
        !lookup_protocol_error_q && !coherence_hart_error;
    wire lookup_sc_failed =
        (ENABLE_COHERENCE != 0) &&
        (lookup_op_q == `OPENRV64_ICX_OP_SC) &&
        !lookup_sc_reservation_match_r;

    wire coherence_directory_lookup_ready;
    wire coherence_directory_lookup_response_valid;
    wire coherence_directory_init_busy;
    wire coherence_directory_lookup_hit;
    wire [DIRECTORY_ENTRY_WIDTH-1:0]
        coherence_directory_lookup_entry;
    wire [NUM_HARTS-1:0] coherence_directory_lookup_i_sharers;
    wire [NUM_HARTS-1:0] coherence_directory_lookup_d_sharers;
    wire coherence_directory_victim_valid;
    wire [DIRECTORY_ENTRY_WIDTH-1:0]
        coherence_directory_victim_entry;
    wire [63:0] coherence_directory_victim_line_addr;
    wire [NUM_HARTS-1:0] coherence_directory_victim_i_sharers;
    wire [NUM_HARTS-1:0] coherence_directory_victim_d_sharers;

    wire [NUM_HARTS-1:0] coherence_write_probe_targets =
        coherence_directory_lookup_d_sharers &
        ~lookup_request_hart_mask_r;
    wire coherence_private_probe_needed =
        lookup_private_fill && !coherence_directory_lookup_hit &&
        coherence_directory_victim_valid &&
        (|(coherence_directory_victim_i_sharers |
           coherence_directory_victim_d_sharers));
    wire coherence_write_probe_needed =
        lookup_coherent_write && !lookup_sc_failed &&
        coherence_directory_lookup_hit &&
        (|coherence_write_probe_targets);
    wire coherence_probe_needed =
        coherence_private_probe_needed || coherence_write_probe_needed;
    wire coherence_lookup_result_ready =
        (ENABLE_COHERENCE == 0) ||
        coherence_directory_lookup_response_valid ||
        lookup_coh_response_seen_q;

    always @* begin
        coherence_set_locked_r = 1'b0;
        for (coherence_lock_scan = 0;
             coherence_lock_scan < MSHR_ENTRIES;
             coherence_lock_scan = coherence_lock_scan + 1) begin
            if (mshr_valid_q[coherence_lock_scan] &&
                (mshr_private_fill_q[coherence_lock_scan] ||
                 (mshr_state_q[coherence_lock_scan] == MSHR_NEED_PROBE) ||
                 (mshr_state_q[coherence_lock_scan] ==
                  MSHR_PROBE_INFLIGHT)) &&
                (mshr_line_addr_q[coherence_lock_scan][
                    LINE_OFFSET_BITS +: DIRECTORY_SET_WIDTH] ==
                 lookup_line_addr[
                    LINE_OFFSET_BITS +: DIRECTORY_SET_WIDTH]) &&
                (mshr_line_addr_q[coherence_lock_scan] !=
                 lookup_line_addr))
                coherence_set_locked_r = 1'b1;
        end
    end

    // A directory record becomes visible before its private-cache response.
    // Keep that directory set unavailable until the response is accepted, or
    // a victim probe could ACK "not present" immediately before the delayed
    // fill installs an untracked copy.
    always @* begin
        coherence_pending_fill_set_locked_r =
            hit_valid_q && hit_private_fill_q &&
            (hit_addr_q[LINE_OFFSET_BITS +: DIRECTORY_SET_WIDTH] ==
             lookup_line_addr[
                LINE_OFFSET_BITS +: DIRECTORY_SET_WIDTH]);
        for (coherence_response_lock_scan = 0;
             coherence_response_lock_scan < RESPONSE_ENTRIES;
            coherence_response_lock_scan =
                 coherence_response_lock_scan + 1) begin
            if (response_private_fill_q[coherence_response_lock_scan] &&
                (response_directory_set_q[
                    coherence_response_lock_scan] ==
                 lookup_line_addr[
                    LINE_OFFSET_BITS +: DIRECTORY_SET_WIDTH]))
                coherence_pending_fill_set_locked_r = 1'b1;
        end
    end

    wire coherence_probe_tracker_start_ready;
    wire coherence_probe_tracker_done;
    wire coherence_probe_tracker_protocol_error;
`ifndef SYNTHESIS
    wire [NUM_HARTS-1:0] debug_probe_issue_pending;
    wire [NUM_HARTS-1:0] debug_probe_ack_pending;
    wire [`OPENRV64_ICX_PROBE_ID_WIDTH-1:0] debug_probe_id;
    wire [`OPENRV64_ICX_PROBE_CMD_WIDTH-1:0] debug_probe_command;
    wire [`OPENRV64_ICX_PROBE_CACHE_WIDTH-1:0]
        debug_probe_cache_mask;
    wire [63:0] debug_probe_line_addr;
`endif
    wire [NUM_HARTS-1:0] coherence_probe_ack_valid =
        probe_resp_valid_i & ~bad_probe_response_r;
    wire coherence_probe_start_fire =
        probe_candidate_found_r && coherence_probe_tracker_start_ready;

    always @* begin
        bad_probe_response_r = {NUM_HARTS{1'b0}};
        for (bad_probe_scan = 0; bad_probe_scan < NUM_HARTS;
             bad_probe_scan = bad_probe_scan + 1) begin
            if (probe_resp_valid_i[bad_probe_scan] &&
                ((probe_resp_kind_i[
                    bad_probe_scan*`OPENRV64_ICX_PROBE_RESP_WIDTH +:
                    `OPENRV64_ICX_PROBE_RESP_WIDTH] !=
                  `OPENRV64_ICX_PROBE_RESP_ACK) ||
                 probe_resp_error_i[bad_probe_scan]))
                bad_probe_response_r[bad_probe_scan] = 1'b1;
        end
    end

    always @* begin
        probe_candidate_found_r = 1'b0;
        probe_candidate_mshr_r = 0;
        probe_candidate_index = 0;
        for (probe_scan = 0; probe_scan < MSHR_ENTRIES;
             probe_scan = probe_scan + 1) begin
            probe_candidate_index = probe_scan;
            if (!probe_candidate_found_r &&
                mshr_valid_q[probe_candidate_index] &&
                (mshr_state_q[probe_candidate_index] ==
                 MSHR_NEED_PROBE)) begin
                probe_candidate_found_r = 1'b1;
                probe_candidate_mshr_r =
                    probe_candidate_index[MSHR_INDEX_WIDTH-1:0];
            end
        end
    end

    wire coherence_probe_completion =
        (ENABLE_COHERENCE != 0) && coherence_probe_tracker_done;
    wire lookup_directory_write =
        (ENABLE_COHERENCE != 0) && lookup_dispatch_r &&
        !lookup_protocol_error_q && !coherence_hart_error &&
        !coherence_probe_completion &&
        ((lookup_private_fill && !coherence_private_probe_needed) ||
         ((lookup_op_q == `OPENRV64_ICX_OP_SC) &&
          !lookup_sc_failed && coherence_directory_lookup_hit &&
          !(|coherence_write_probe_targets)));
    wire coherence_directory_write_valid =
        coherence_probe_completion || lookup_directory_write;
    wire coherence_directory_write_allocate =
        coherence_probe_completion ?
            (mshr_coh_action_q[active_probe_mshr_q] ==
             COH_ACTION_ALLOCATE) :
            (lookup_private_fill &&
             !coherence_directory_lookup_hit);
    wire coherence_directory_write_overwrite =
        coherence_probe_completion &&
        (mshr_coh_action_q[active_probe_mshr_q] ==
         COH_ACTION_CLEAR);
    wire [DIRECTORY_ENTRY_WIDTH-1:0]
        coherence_directory_write_entry =
            coherence_probe_completion ?
                mshr_directory_entry_q[active_probe_mshr_q] :
            coherence_directory_lookup_hit ?
                coherence_directory_lookup_entry :
                coherence_directory_victim_entry;
    wire [63:0] coherence_directory_write_line_addr =
        coherence_probe_completion ?
            mshr_line_addr_q[active_probe_mshr_q] :
            lookup_line_addr;
    wire [NUM_HARTS-1:0] coherence_directory_write_add_i =
        coherence_probe_completion ?
            mshr_directory_add_i_q[active_probe_mshr_q] :
        (lookup_private_fill &&
         (lookup_source_id_q == `OPENRV64_ICX_SOURCE_ICACHE)) ?
            lookup_request_hart_mask_r : {NUM_HARTS{1'b0}};
    wire [NUM_HARTS-1:0] coherence_directory_write_add_d =
        coherence_probe_completion ?
            mshr_directory_add_d_q[active_probe_mshr_q] :
        (lookup_private_fill &&
         (lookup_source_id_q == `OPENRV64_ICX_SOURCE_DCACHE)) ?
            lookup_request_hart_mask_r : {NUM_HARTS{1'b0}};
    wire [NUM_HARTS-1:0] coherence_directory_write_clear_d =
        coherence_probe_completion ?
            mshr_directory_clear_d_q[active_probe_mshr_q] :
        ((lookup_op_q == `OPENRV64_ICX_OP_SC) ?
            {NUM_HARTS{1'b1}} : {NUM_HARTS{1'b0}});

    generate
        if (ENABLE_COHERENCE != 0) begin : g_coherent_home
            openrv64_icx_snoop_filter #(
                .NUM_HARTS(NUM_HARTS),
                .ENTRIES(DIRECTORY_ENTRIES),
                .WAYS(DIRECTORY_WAYS),
                .ENTRY_WIDTH(DIRECTORY_ENTRY_WIDTH)
            ) u_snoop_filter (
                .clk_i(clk_i),
                .rst_ni(rst_ni),
                .lookup_valid_i(lookup_capture),
                .lookup_ready_o(coherence_directory_lookup_ready),
                .lookup_line_addr_i(cmd_head_effective_addr),
                .lookup_response_valid_o(
                    coherence_directory_lookup_response_valid),
                .init_busy_o(coherence_directory_init_busy),
                .lookup_hit_o(coherence_directory_lookup_hit),
                .lookup_entry_o(coherence_directory_lookup_entry),
                .lookup_i_sharers_o(
                    coherence_directory_lookup_i_sharers),
                .lookup_d_sharers_o(
                    coherence_directory_lookup_d_sharers),
                .victim_valid_o(coherence_directory_victim_valid),
                .victim_entry_o(coherence_directory_victim_entry),
                .victim_line_addr_o(
                    coherence_directory_victim_line_addr),
                .victim_i_sharers_o(
                    coherence_directory_victim_i_sharers),
                .victim_d_sharers_o(
                    coherence_directory_victim_d_sharers),
                .write_valid_i(coherence_directory_write_valid),
                .write_allocate_i(coherence_directory_write_allocate),
                .write_overwrite_i(
                    coherence_directory_write_overwrite),
                .write_entry_i(coherence_directory_write_entry),
                .write_line_addr_i(
                    coherence_directory_write_line_addr),
                .write_add_i_sharers_i(
                    coherence_directory_write_add_i),
                .write_add_d_sharers_i(
                    coherence_directory_write_add_d),
                .write_clear_i_sharers_i({NUM_HARTS{1'b0}}),
                .write_clear_d_sharers_i(
                    coherence_directory_write_clear_d)
            );

            openrv64_icx_probe_tracker #(
                .NUM_HARTS(NUM_HARTS)
            ) u_probe_tracker (
                .clk_i(clk_i),
                .rst_ni(rst_ni),
                .start_valid_i(probe_candidate_found_r),
                .start_ready_o(coherence_probe_tracker_start_ready),
                .start_target_harts_i(
                    mshr_probe_target_q[probe_candidate_mshr_r]),
                .start_probe_id_i(next_probe_id_q),
                .start_command_i(`OPENRV64_ICX_PROBE_INV),
                .start_cache_mask_i(
                    mshr_probe_cache_mask_q[probe_candidate_mshr_r]),
                .start_line_addr_i(
                    mshr_probe_line_addr_q[probe_candidate_mshr_r]),
                .probe_valid_o(probe_valid_o),
                .probe_ready_i(probe_ready_i),
                .probe_id_o(probe_id_o),
                .probe_command_o(probe_command_o),
                .probe_cache_mask_o(probe_cache_mask_o),
                .probe_line_addr_o(probe_line_addr_o),
                .probe_ack_valid_i(coherence_probe_ack_valid),
                .probe_ack_ready_o(probe_resp_ready_o),
                .probe_ack_id_i(probe_resp_id_i),
                .busy_o(),
                .done_valid_o(coherence_probe_tracker_done),
                .done_ready_i(1'b1),
                .done_probe_id_o(),
                .protocol_error_clear_i(protocol_error_clear_i),
                .protocol_error_o(
                    coherence_probe_tracker_protocol_error)
            );
`ifndef SYNTHESIS
            assign debug_probe_issue_pending =
                u_probe_tracker.issue_pending_q;
            assign debug_probe_ack_pending =
                u_probe_tracker.ack_pending_q;
            assign debug_probe_id = u_probe_tracker.probe_id_q;
            assign debug_probe_command = u_probe_tracker.command_q;
            assign debug_probe_cache_mask = u_probe_tracker.cache_mask_q;
            assign debug_probe_line_addr = u_probe_tracker.line_addr_q;
`endif
        end else begin : g_no_coherent_home
            assign coherence_directory_lookup_ready = 1'b1;
            assign coherence_directory_lookup_response_valid = 1'b0;
            assign coherence_directory_init_busy = 1'b0;
            assign coherence_directory_lookup_hit = 1'b0;
            assign coherence_directory_lookup_entry = 0;
            assign coherence_directory_lookup_i_sharers = 0;
            assign coherence_directory_lookup_d_sharers = 0;
            assign coherence_directory_victim_valid = 1'b0;
            assign coherence_directory_victim_entry = 0;
            assign coherence_directory_victim_line_addr = 0;
            assign coherence_directory_victim_i_sharers = 0;
            assign coherence_directory_victim_d_sharers = 0;
            assign coherence_probe_tracker_start_ready = 1'b0;
            assign coherence_probe_tracker_done = 1'b0;
            assign coherence_probe_tracker_protocol_error = 1'b0;
`ifndef SYNTHESIS
            assign debug_probe_issue_pending = 0;
            assign debug_probe_ack_pending = 0;
            assign debug_probe_id = 0;
            assign debug_probe_command = 0;
            assign debug_probe_cache_mask = 0;
            assign debug_probe_line_addr = 0;
`endif
            assign probe_valid_o = 0;
            assign probe_id_o = 0;
            assign probe_command_o = 0;
            assign probe_cache_mask_o = 0;
            assign probe_line_addr_o = 0;
            assign probe_resp_ready_o = 0;
        end
    endgenerate

    assign protocol_error_o =
        protocol_error_q | coherence_probe_tracker_protocol_error;

    always @* begin
        lookup_hit_r = 1'b0;
        lookup_hit_way_r = 0;
        lookup_stale_pte_r = 1'b0;
        lookup_stale_pte_way_r = 0;
        lookup_candidate_index = 0;
        for (lookup_way_scan = 0; lookup_way_scan < WAYS;
             lookup_way_scan = lookup_way_scan + 1) begin
            if (valid_q[lookup_set][lookup_way_scan] &&
                !reserved_q[lookup_set][lookup_way_scan] &&
                (sram_way_tag[lookup_way_scan*SRAM_TAG_BITS +:
                              TAG_BITS] == lookup_tag)) begin
                if (lookup_is_pte &&
                    (sram_way_tag[
                         lookup_way_scan*SRAM_TAG_BITS + TAG_BITS +:
                         PTE_GENERATION_BITS] !=
                     pte_generation_q)) begin
                    if (!lookup_stale_pte_r) begin
                        lookup_stale_pte_r = 1'b1;
                        lookup_stale_pte_way_r =
                            lookup_way_scan[WAY_INDEX_WIDTH-1:0];
                    end
                end else if (!lookup_hit_r) begin
                    lookup_hit_r = 1'b1;
                    lookup_hit_way_r =
                        lookup_way_scan[WAY_INDEX_WIDTH-1:0];
                end
            end
        end

        lookup_mshr_match_r = 1'b0;
        lookup_mshr_index_r = 0;
        lookup_mshr_mergeable_r = 1'b0;
        lookup_dirty_victim_match_r = 1'b0;
        lookup_dirty_victim_index_r = 0;
        mshr_free_found_r = 1'b0;
        mshr_free_index_r = 0;
        for (lookup_mshr_scan = 0;
             lookup_mshr_scan < MSHR_ENTRIES;
             lookup_mshr_scan = lookup_mshr_scan + 1) begin
            if (!mshr_free_found_r &&
                !mshr_valid_q[lookup_mshr_scan]) begin
                mshr_free_found_r = 1'b1;
                mshr_free_index_r =
                    lookup_mshr_scan[MSHR_INDEX_WIDTH-1:0];
            end
            if (!lookup_mshr_match_r &&
                mshr_valid_q[lookup_mshr_scan] &&
                // Cacheable write-around entries do not carry refill data,
                // but they still own their line until the backing write
                // completes.  Match them as hazards and refuse merging below
                // so a later read/write cannot race a second transaction.
                (!mshr_bypass_q[lookup_mshr_scan] ||
                 mshr_bus_cacheable_q[lookup_mshr_scan]) &&
                (mshr_line_addr_q[lookup_mshr_scan] ==
                 lookup_line_addr)) begin
                lookup_mshr_match_r = 1'b1;
                lookup_mshr_index_r =
                    lookup_mshr_scan[MSHR_INDEX_WIDTH-1:0];
                lookup_mshr_mergeable_r =
                    !mshr_bypass_q[lookup_mshr_scan] &&
                    !(((mshr_state_q[lookup_mshr_scan] ==
                        MSHR_NEED_PROBE) ||
                       (mshr_state_q[lookup_mshr_scan] ==
                        MSHR_PROBE_INFLIGHT)) &&
                      (mshr_coh_action_q[lookup_mshr_scan] ==
                       COH_ACTION_CLEAR)) &&
                    (mshr_state_q[lookup_mshr_scan] != MSHR_REPLAY) &&
                    (mshr_state_q[lookup_mshr_scan] != MSHR_ERROR) &&
                    (mshr_waiter_count_q[lookup_mshr_scan] <
                     WAITER_COUNT_WIDTH'(WAITERS_PER_MSHR));
            end
            // Reservation removes a victim way from ordinary SRAM hits, but
            // its dirty snapshot remains authoritative until the writeback
            // response.  Match that address explicitly so a later read
            // cannot allocate a second miss and consume stale memory.
            if (!lookup_dirty_victim_match_r &&
                mshr_valid_q[lookup_mshr_scan] &&
                !mshr_bypass_q[lookup_mshr_scan] &&
                ((mshr_state_q[lookup_mshr_scan] == MSHR_NEED_WB) ||
                 (mshr_state_q[lookup_mshr_scan] ==
                  MSHR_WB_INFLIGHT)) &&
                (mshr_victim_addr_q[lookup_mshr_scan] ==
                 lookup_line_addr)) begin
                lookup_dirty_victim_match_r = 1'b1;
                lookup_dirty_victim_index_r =
                    lookup_mshr_scan[MSHR_INDEX_WIDTH-1:0];
            end
        end

        victim_found_r = 1'b0;
        victim_way_r = 0;
        if (lookup_stale_pte_r) begin
            victim_found_r = 1'b1;
            victim_way_r = lookup_stale_pte_way_r;
        end
        for (lookup_way_scan = 0; lookup_way_scan < WAYS;
             lookup_way_scan = lookup_way_scan + 1) begin
            if (!victim_found_r &&
                !valid_q[lookup_set][lookup_way_scan] &&
                !reserved_q[lookup_set][lookup_way_scan]) begin
                victim_found_r = 1'b1;
                victim_way_r =
                    lookup_way_scan[WAY_INDEX_WIDTH-1:0];
            end
        end
        for (lookup_way_scan = 0; lookup_way_scan < WAYS;
             lookup_way_scan = lookup_way_scan + 1) begin
            lookup_candidate_index =
                32'(replace_q[lookup_set]) + lookup_way_scan;
            if (lookup_candidate_index >= WAYS)
                lookup_candidate_index =
                    lookup_candidate_index - WAYS;
            if (!victim_found_r &&
                !reserved_q[lookup_set][lookup_candidate_index]) begin
                victim_found_r = 1'b1;
                victim_way_r =
                    lookup_candidate_index[WAY_INDEX_WIDTH-1:0];
            end
        end
    end

    always @* begin
        lookup_base_action_r = LOOKUP_NONE;
        lookup_action_r = LOOKUP_NONE;
        lookup_dispatch_r = 1'b0;
        if (lookup_valid_q && coherence_lookup_result_ready &&
            !coherence_probe_completion &&
            !coherence_pending_fill_set_locked_r &&
            (!coherence_set_locked_r || lookup_mshr_match_r)) begin
            if (lookup_protocol_error_q || coherence_hart_error) begin
                if (hit_slot_ready) begin
                    lookup_base_action_r = LOOKUP_IMMEDIATE;
                end
            end else if (lookup_invariant_match) begin
                // Invariant pages terminate here.  They neither consume an
                // L2 SRAM way nor generate a backing-memory transaction.
                if (hit_slot_ready)
                    lookup_base_action_r = LOOKUP_IMMEDIATE;
            end else if (lookup_sc_failed) begin
                if (hit_slot_ready)
                    lookup_base_action_r = LOOKUP_IMMEDIATE;
            end else if (lookup_op_q == `OPENRV64_ICX_OP_FENCE) begin
                if (fence_drain_complete && hit_slot_ready) begin
                    lookup_base_action_r = LOOKUP_IMMEDIATE;
                end
            end else if (!lookup_cacheable) begin
                if (mshr_free_found_r) begin
                    lookup_base_action_r = LOOKUP_BYPASS;
                end
            end else if (lookup_mshr_match_r) begin
                if (lookup_mshr_mergeable_r &&
                    (!lookup_coherent_write ||
                     (ENABLE_COHERENCE == 0)) &&
                    (!coherence_probe_needed ||
                     (coherence_private_probe_needed &&
                      (mshr_coh_action_q[lookup_mshr_index_r] ==
                       COH_ACTION_ALLOCATE) &&
                      ((mshr_state_q[lookup_mshr_index_r] ==
                        MSHR_NEED_PROBE) ||
                       (mshr_state_q[lookup_mshr_index_r] ==
                        MSHR_PROBE_INFLIGHT)))))
                    lookup_base_action_r = LOOKUP_MERGE;
            end else if (lookup_dirty_victim_match_r) begin
                // Reads consume the complete dirty victim snapshot.  A write
                // waits for writeback completion because data already sent
                // below this cache cannot be modified safely.
                if (lookup_is_read &&
                    hit_slot_ready) begin
                    lookup_base_action_r = LOOKUP_VICTIM_HIT;
                end
            end else if (lookup_hit_r) begin
                if (hit_slot_ready &&
                    (!lookup_is_write ||
                     !lookup_sram_write_blocked)) begin
                    lookup_base_action_r = LOOKUP_HIT;
                end
            end else if (lookup_is_write &&
                         !((ENABLE_COHERENCE != 0) &&
                           (lookup_op_q == `OPENRV64_ICX_OP_SC)) &&
                         mshr_free_found_r) begin
                // A write miss needs no read-for-ownership.  Preserve its
                // byte enables and let the backing memory merge the partial
                // line.  A successful SC is excluded: it allocates and fills
                // the line before replaying the atomic write.  Resident
                // writes still merge into the L2 SRAM above.
                lookup_base_action_r = LOOKUP_WRITE_AROUND;
            end else if (mshr_free_found_r && victim_found_r) begin
                lookup_base_action_r = LOOKUP_ALLOC;
            end

            lookup_action_r = lookup_base_action_r;
            if (coherence_probe_needed &&
                (lookup_base_action_r != LOOKUP_NONE)) begin
                if (lookup_base_action_r == LOOKUP_MERGE) begin
                    lookup_action_r = LOOKUP_MERGE;
                end else if (mshr_free_found_r &&
                             ((lookup_base_action_r == LOOKUP_HIT) ||
                              (lookup_base_action_r == LOOKUP_ALLOC) ||
                              (lookup_base_action_r ==
                               LOOKUP_WRITE_AROUND))) begin
                    lookup_action_r = LOOKUP_COH_PROBE;
                end else begin
                    lookup_action_r = LOOKUP_NONE;
                end
            end

            lookup_dispatch_r = lookup_action_r != LOOKUP_NONE;
        end
    end

    wire lookup_stage_ready = !lookup_valid_q || lookup_dispatch_r;
    wire [31:0] lookup_merge_waiter_index =
        32'(lookup_mshr_index_r) * WAITERS_PER_MSHR +
        32'(mshr_waiter_count_q[lookup_mshr_index_r]);
    wire [31:0] lookup_alloc_waiter_index =
        32'(mshr_free_index_r) * WAITERS_PER_MSHR;
    wire command_source_valid =
        (cmd_count_q != 0) &&
        (!cmd_head_write || cmd_wdata_valid_q[cmd_head_q]);
    assign lookup_capture =
        command_source_valid && lookup_stage_ready &&
        coherence_directory_lookup_ready &&
        !coherence_directory_write_valid;
    wire command_pop = lookup_capture && cmd_head_last;
    wire command_advance = lookup_capture && !cmd_head_last;
    wire lookup_sram_read = lookup_capture ||
        (lookup_valid_q && !lookup_dispatch_r);
    wire [SET_INDEX_WIDTH-1:0] lookup_sram_read_set =
        lookup_capture ? cmd_head_set : lookup_set;

    always @* begin
        bus_candidate_found_r = 1'b0;
        bus_candidate_mshr_r = bus_round_robin_q;
        bus_candidate_action_r = BUS_ACTION_FILL;
        bus_candidate_index = 0;
        for (bus_scan = 0; bus_scan < MSHR_ENTRIES;
             bus_scan = bus_scan + 1) begin
            bus_candidate_index = 32'(bus_round_robin_q) + bus_scan;
            if (bus_candidate_index >= MSHR_ENTRIES)
                bus_candidate_index =
                    bus_candidate_index - MSHR_ENTRIES;
            if (!bus_candidate_found_r &&
                mshr_valid_q[bus_candidate_index]) begin
                if (mshr_state_q[bus_candidate_index] ==
                    MSHR_NEED_WB) begin
                    bus_candidate_found_r = 1'b1;
                    bus_candidate_mshr_r =
                        bus_candidate_index[MSHR_INDEX_WIDTH-1:0];
                    bus_candidate_action_r = BUS_ACTION_WB;
                end else if (mshr_state_q[bus_candidate_index] ==
                             MSHR_NEED_FILL) begin
                    bus_candidate_found_r = 1'b1;
                    bus_candidate_mshr_r =
                        bus_candidate_index[MSHR_INDEX_WIDTH-1:0];
                    bus_candidate_action_r = BUS_ACTION_FILL;
                end else if (mshr_state_q[bus_candidate_index] ==
                             MSHR_NEED_BYPASS) begin
                    bus_candidate_found_r = 1'b1;
                    bus_candidate_mshr_r =
                        bus_candidate_index[MSHR_INDEX_WIDTH-1:0];
                    bus_candidate_action_r = BUS_ACTION_BYPASS;
                end
            end
        end
    end

    wire bus_response_fire = bus_resp_valid_i && bus_resp_ready_o;
    wire bus_track_space =
        (bus_track_count_q < TRACK_COUNT_WIDTH'(BUS_TRACK_ENTRIES)) ||
        bus_response_fire;
    assign bus_req_valid_o = bus_candidate_found_r && bus_track_space;
    wire bus_request_fire = bus_req_valid_o && bus_req_ready_i;
    wire [MSHR_INDEX_WIDTH-1:0] bus_response_mshr =
        bus_track_mshr_q[bus_track_head_q];
    wire [1:0] bus_response_action =
        bus_track_action_q[bus_track_head_q];
    assign bus_resp_ready_o = (bus_track_count_q != 0);

    always @* begin
        bus_req_write_o = 1'b0;
        bus_req_addr_o = 0;
        bus_req_size_o = 3'd6;
        bus_req_wdata_o = 0;
        bus_req_wstrb_o = 0;
        bus_req_cacheable_o = 1'b1;
        bus_waiter_index = 0;
        if (bus_candidate_found_r) begin
            if (bus_candidate_action_r == BUS_ACTION_WB) begin
                bus_req_write_o = 1'b1;
                bus_req_addr_o =
                    mshr_victim_addr_q[bus_candidate_mshr_r];
                bus_req_wdata_o =
                    mshr_victim_data_q[bus_candidate_mshr_r];
                bus_req_wstrb_o =
                    mshr_victim_strb_q[bus_candidate_mshr_r];
            end else if (bus_candidate_action_r == BUS_ACTION_FILL) begin
                bus_req_addr_o =
                    mshr_line_addr_q[bus_candidate_mshr_r];
            end else begin
                bus_waiter_index =
                    32'(bus_candidate_mshr_r) * WAITERS_PER_MSHR;
                bus_req_write_o =
                    (waiter_op_q[bus_waiter_index] ==
                     `OPENRV64_ICX_OP_WRITE) ||
                    ((ENABLE_COHERENCE != 0) &&
                     (waiter_op_q[bus_waiter_index] ==
                      `OPENRV64_ICX_OP_SC));
                bus_req_addr_o = waiter_addr_q[bus_waiter_index];
                bus_req_size_o = waiter_size_q[bus_waiter_index];
                bus_req_wdata_o = waiter_wdata_q[bus_waiter_index];
                bus_req_wstrb_o = waiter_wstrb_q[bus_waiter_index];
                bus_req_cacheable_o =
                    mshr_bus_cacheable_q[bus_candidate_mshr_r];
            end
        end
    end

    always @* begin
        replay_candidate_found_r = 1'b0;
        replay_candidate_mshr_r = replay_round_robin_q;
        replay_candidate_index = 0;
        for (replay_scan = 0; replay_scan < MSHR_ENTRIES;
             replay_scan = replay_scan + 1) begin
            replay_candidate_index =
                32'(replay_round_robin_q) + replay_scan;
            if (replay_candidate_index >= MSHR_ENTRIES)
                replay_candidate_index =
                    replay_candidate_index - MSHR_ENTRIES;
            if (!replay_candidate_found_r &&
                mshr_valid_q[replay_candidate_index] &&
                ((mshr_state_q[replay_candidate_index] ==
                  MSHR_REPLAY) ||
                 (mshr_state_q[replay_candidate_index] ==
                  MSHR_ERROR))) begin
                replay_candidate_found_r = 1'b1;
                replay_candidate_mshr_r =
                    replay_candidate_index[MSHR_INDEX_WIDTH-1:0];
            end
        end
    end

    wire [MSHR_INDEX_WIDTH-1:0] replay_mshr = replay_candidate_mshr_r;
    wire [WAITER_INDEX_WIDTH-1:0] replay_index =
        mshr_replay_q[replay_mshr];
    wire replay_final =
        (WAITER_COUNT_WIDTH'(replay_index) + 1'b1 >=
         mshr_waiter_count_q[replay_mshr]);

    always @* begin
        replay_waiter_index =
            32'(replay_mshr) * WAITERS_PER_MSHR +
            32'(replay_index);
    end

    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] replay_hart_id =
        waiter_hart_id_q[replay_waiter_index];
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] replay_txn_id =
        waiter_txn_id_q[replay_waiter_index];
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] replay_source_id =
        waiter_source_id_q[replay_waiter_index];
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] replay_op =
        waiter_op_q[replay_waiter_index];
    wire replay_lock = waiter_lock_q[replay_waiter_index];
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] replay_beat =
        waiter_beat_q[replay_waiter_index];
    wire replay_last = waiter_last_q[replay_waiter_index];
    wire replay_error =
        (mshr_state_q[replay_mshr] == MSHR_ERROR) ||
        mshr_error_q[replay_mshr];
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] replay_shifted_data =
        mshr_replay_data_q[replay_mshr] >>
        (waiter_addr_q[replay_waiter_index][5:3] * 64);
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] replay_cache_read_data =
        (waiter_size_q[replay_waiter_index] == 3'd6) ?
            mshr_replay_data_q[replay_mshr] :
            ({{448{1'b0}}, replay_shifted_data[63:0]} <<
             (waiter_addr_q[replay_waiter_index][5:3] * 64));
    wire fill_sram_write = bus_response_fire &&
        (bus_response_action == BUS_ACTION_FILL) && !bus_resp_error_i;
    wire replay_needs_sram_write = replay_candidate_found_r &&
        !replay_error && !mshr_bypass_q[replay_mshr] &&
        ((replay_op == `OPENRV64_ICX_OP_WRITE) ||
         ((ENABLE_COHERENCE != 0) &&
          (replay_op == `OPENRV64_ICX_OP_SC)));
    wire replay_enqueue = replay_candidate_found_r && response_space &&
        !hit_valid_q && (!replay_needs_sram_write || !fill_sram_write);
    wire response_enqueue = hit_enqueue || replay_enqueue;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] replay_data =
        replay_error ? 512'd0 :
        mshr_bypass_q[replay_mshr] ?
            (((replay_op == `OPENRV64_ICX_OP_READ) ||
              ((ENABLE_COHERENCE != 0) &&
               (replay_op == `OPENRV64_ICX_OP_LR))) ?
             mshr_bypass_data_q[replay_mshr] : 512'd0) :
            (((replay_op == `OPENRV64_ICX_OP_READ) ||
              ((ENABLE_COHERENCE != 0) &&
               (replay_op == `OPENRV64_ICX_OP_LR))) ?
             replay_cache_read_data :
             512'd0);
    wire replay_cache_write = replay_enqueue && !replay_error &&
        !mshr_bypass_q[replay_mshr] &&
        ((replay_op == `OPENRV64_ICX_OP_WRITE) ||
         ((ENABLE_COHERENCE != 0) &&
          (replay_op == `OPENRV64_ICX_OP_SC)));

    always @* begin
        lookup_write_data_r = lookup_hit_data;
        for (lookup_write_byte = 0;
             lookup_write_byte < `OPENRV64_ICX_LINE_STRB_WIDTH;
             lookup_write_byte = lookup_write_byte + 1)
            if (lookup_wstrb_q[lookup_write_byte])
                lookup_write_data_r[8*lookup_write_byte +: 8] =
                    lookup_wdata_q[8*lookup_write_byte +: 8];

        replay_write_data_r = mshr_replay_data_q[replay_mshr];
        replay_write_strb_r = mshr_replay_strb_q[replay_mshr] |
            waiter_wstrb_q[replay_waiter_index];
        for (replay_write_byte = 0;
             replay_write_byte < `OPENRV64_ICX_LINE_STRB_WIDTH;
             replay_write_byte = replay_write_byte + 1)
            if (waiter_wstrb_q[replay_waiter_index][replay_write_byte])
                replay_write_data_r[8*replay_write_byte +: 8] =
                    waiter_wdata_q[replay_waiter_index]
                        [8*replay_write_byte +: 8];
    end

    assign lookup_sram_write_blocked =
        fill_sram_write || replay_cache_write;
    wire pte_generation_advance =
        lookup_dispatch_r &&
        (lookup_action_r == LOOKUP_IMMEDIATE) &&
        !lookup_protocol_error_q &&
        (lookup_op_q == `OPENRV64_ICX_OP_FENCE) &&
        (lookup_kind_q == `OPENRV64_ICX_KIND_PTE);

    // The eight data and tag banks each have one synchronous read port and one
    // full-line write port.  Fill has priority over replay, which has priority
    // over a resident write hit; the lower-priority pipeline stage stalls.
    always @* begin
        sram_write_valid_r = 1'b0;
        sram_write_set_r = 0;
        sram_write_way_r = 0;
        sram_write_data_r = 0;
        sram_write_strb_r = 0;
        sram_write_tag_r = 1'b0;
        sram_write_tag_data_r = 0;

        if (fill_sram_write) begin
            sram_write_valid_r = 1'b1;
            sram_write_set_r = mshr_set_q[bus_response_mshr];
            sram_write_way_r = mshr_way_q[bus_response_mshr];
            sram_write_data_r = bus_resp_rdata_i;
            sram_write_strb_r = 0;
            sram_write_tag_r = 1'b1;
            sram_write_tag_data_r = {
                mshr_pte_generation_q[bus_response_mshr],
                mshr_tag_q[bus_response_mshr]
            };
        end else if (replay_cache_write) begin
            sram_write_valid_r = 1'b1;
            sram_write_set_r = mshr_set_q[replay_mshr];
            sram_write_way_r = mshr_way_q[replay_mshr];
            sram_write_data_r = replay_write_data_r;
            sram_write_strb_r = replay_write_strb_r;
        end else if (lookup_dispatch_r &&
                     (lookup_action_r == LOOKUP_HIT) &&
                     lookup_is_write) begin
            sram_write_valid_r = 1'b1;
            sram_write_set_r = lookup_set;
            sram_write_way_r = lookup_hit_way_r;
            sram_write_data_r = lookup_write_data_r;
            sram_write_strb_r = lookup_hit_dirty_strb |
                lookup_wstrb_q;
        end
    end

    genvar sram_way;
    generate
        for (sram_way = 0; sram_way < WAYS;
             sram_way = sram_way + 1) begin : g_l2_sram_way
            openrv64_l2_sram_way #(
                .SETS(SETS),
                .SET_INDEX_WIDTH(SET_INDEX_WIDTH),
                .DATA_WIDTH(SRAM_PAYLOAD_WIDTH),
                .TAG_WIDTH(SRAM_TAG_BITS)
            ) u_sram (
                .clk_i(clk_i),
                .read_enable_i(lookup_sram_read),
                .read_set_i(lookup_sram_read_set),
                .read_data_o(sram_way_payload[
                    sram_way*SRAM_PAYLOAD_WIDTH +:
                    SRAM_PAYLOAD_WIDTH]),
                .read_tag_o(sram_way_tag[
                    sram_way*SRAM_TAG_BITS +: SRAM_TAG_BITS]),
                .write_enable_i(sram_write_valid_r &&
                    (sram_write_way_r == WAY_INDEX_WIDTH'(sram_way))),
                .write_set_i(sram_write_set_r),
                .write_data_i({sram_write_strb_r, sram_write_data_r}),
                .write_tag_i(sram_write_tag_r),
                .write_tag_data_i(sram_write_tag_data_r)
            );
        end
    endgenerate

    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] enqueue_hart_id =
        hit_enqueue ? hit_hart_id_q : replay_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] enqueue_txn_id =
        hit_enqueue ? hit_txn_id_q : replay_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] enqueue_source_id =
        hit_enqueue ? hit_source_id_q : replay_source_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] enqueue_op =
        hit_enqueue ? hit_op_q : replay_op;
    wire enqueue_lock = hit_enqueue ? hit_lock_q : replay_lock;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] enqueue_beat =
        hit_enqueue ? hit_beat_q : replay_beat;
    wire enqueue_last = hit_enqueue ? hit_last_q : replay_last;
    wire [63:0] enqueue_addr =
        hit_enqueue ? hit_addr_q :
        waiter_addr_q[replay_waiter_index];
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] enqueue_data =
        hit_enqueue ? hit_data_q : replay_data;
    wire enqueue_error = hit_enqueue ? hit_error_q : replay_error;
    wire enqueue_sc_success =
        hit_enqueue ? hit_sc_success_q :
        ((ENABLE_COHERENCE != 0) &&
         (replay_op == `OPENRV64_ICX_OP_SC) && !replay_error);
    wire replay_private_fill =
        (ENABLE_COHERENCE != 0) &&
        mshr_bus_cacheable_q[replay_mshr] &&
        ((replay_op == `OPENRV64_ICX_OP_READ) ||
         (replay_op == `OPENRV64_ICX_OP_LR)) &&
        ((replay_source_id == `OPENRV64_ICX_SOURCE_ICACHE) ||
         (replay_source_id == `OPENRV64_ICX_SOURCE_DCACHE));
    wire enqueue_private_fill =
        !enqueue_error &&
        (hit_enqueue ? hit_private_fill_q : replay_private_fill);

    assign resp_valid_o = (response_count_q != 0);
    assign resp_hart_id_o = response_hart_id_q[response_head_q];
    assign resp_txn_id_o = response_txn_id_q[response_head_q];
    assign resp_source_id_o = response_source_id_q[response_head_q];
    assign resp_beat_index_o = response_beat_q[response_head_q];
    assign resp_last_o = response_last_q[response_head_q];
    assign resp_rdata_o = response_data_q[response_head_q];
    assign resp_error_o = response_error_q[response_head_q];
    assign resp_sc_success_o =
        response_sc_success_q[response_head_q];

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cmd_head_q <= 0;
            cmd_tail_q <= 0;
            cmd_count_q <= 0;
            cmd_beat_q <= 0;
            lookup_valid_q <= 1'b0;
            hit_valid_q <= 1'b0;
            hit_addr_q <= 0;
            hit_private_fill_q <= 1'b0;
            response_head_q <= 0;
            response_tail_q <= 0;
            response_count_q <= 0;
            bus_track_head_q <= 0;
            bus_track_tail_q <= 0;
            bus_track_count_q <= 0;
            bus_round_robin_q <= 0;
            replay_round_robin_q <= 0;
            pte_generation_q <= 0;
            lock_active_q <= 1'b0;
            lock_hart_id_q <= 0;
            lock_line_addr_q <= 0;
            protocol_error_q <= 1'b0;
            lookup_coh_response_seen_q <= 1'b0;
            active_probe_mshr_q <= 0;
            next_probe_id_q <= 0;
            reservation_valid_q <= {NUM_HARTS{1'b0}};
            for (reservation_scan = 0; reservation_scan < NUM_HARTS;
                 reservation_scan = reservation_scan + 1)
                reservation_line_q[reservation_scan] <= 0;
            for (command_reset_index = 0;
                 command_reset_index < COMMAND_ENTRIES;
                 command_reset_index = command_reset_index + 1) begin
                cmd_entry_valid_q[command_reset_index] <= 1'b0;
                cmd_wdata_valid_q[command_reset_index] <= 1'b0;
                cmd_wdata_error_q[command_reset_index] <= 1'b0;
            end
            for (response_reset_index = 0;
                 response_reset_index < RESPONSE_ENTRIES;
                response_reset_index = response_reset_index + 1) begin
                response_private_fill_q[response_reset_index] <= 1'b0;
                response_directory_set_q[response_reset_index] <= 0;
            end
            for (set_reset_index = 0; set_reset_index < SETS;
                 set_reset_index = set_reset_index + 1) begin
                valid_q[set_reset_index] <= 0;
                dirty_q[set_reset_index] <= 0;
                reserved_q[set_reset_index] <= 0;
                replace_q[set_reset_index] <= 0;
            end
            for (reset_index = 0; reset_index < MSHR_ENTRIES;
                 reset_index = reset_index + 1) begin
                mshr_valid_q[reset_index] <= 1'b0;
                mshr_bypass_q[reset_index] <= 1'b0;
                mshr_state_q[reset_index] <= MSHR_IDLE;
                mshr_waiter_count_q[reset_index] <= 0;
                mshr_replay_q[reset_index] <= 0;
                mshr_error_q[reset_index] <= 1'b0;
                mshr_private_fill_q[reset_index] <= 1'b0;
                mshr_pte_generation_q[reset_index] <= 0;
                mshr_bus_cacheable_q[reset_index] <= 1'b0;
                mshr_victim_strb_q[reset_index] <= 0;
                mshr_replay_strb_q[reset_index] <= 0;
                mshr_coh_action_q[reset_index] <= COH_ACTION_ALLOCATE;
                mshr_post_probe_state_q[reset_index] <= MSHR_IDLE;
                mshr_directory_entry_q[reset_index] <= 0;
                mshr_probe_target_q[reset_index] <= 0;
                mshr_probe_cache_mask_q[reset_index] <=
                    `OPENRV64_ICX_PROBE_CACHE_NONE;
                mshr_probe_line_addr_q[reset_index] <= 0;
                mshr_directory_add_i_q[reset_index] <= 0;
                mshr_directory_add_d_q[reset_index] <= 0;
                mshr_directory_clear_d_q[reset_index] <= 0;
            end
        end else begin
            if (protocol_error_clear_i)
                protocol_error_q <= 1'b0;
            if (|(bad_probe_response_r & probe_resp_ready_o))
                protocol_error_q <= 1'b1;
            if (pte_generation_advance)
                pte_generation_q <= pte_generation_q + 1'b1;

            if (command_push) begin
                cmd_hart_id_q[cmd_tail_q] <= req_hart_id_i;
                cmd_txn_id_q[cmd_tail_q] <= req_txn_id_i;
                cmd_source_id_q[cmd_tail_q] <= req_source_id_i;
                cmd_op_q[cmd_tail_q] <= req_op_i;
                cmd_lock_q[cmd_tail_q] <= req_lock_i;
                cmd_order_q[cmd_tail_q] <= req_order_i;
                cmd_kind_q[cmd_tail_q] <= req_kind_i;
                cmd_attr_q[cmd_tail_q] <= req_attr_i;
                cmd_size_q[cmd_tail_q] <= req_size_i;
                cmd_addr_q[cmd_tail_q] <= req_addr_i;
                cmd_burst_len_q[cmd_tail_q] <= req_burst_len_i;
                cmd_entry_valid_q[cmd_tail_q] <= 1'b1;
                cmd_wdata_valid_q[cmd_tail_q] <= 1'b0;
                cmd_wdata_error_q[cmd_tail_q] <= 1'b0;
                if (cmd_tail_q ==
                    COMMAND_INDEX_WIDTH'(COMMAND_ENTRIES - 1))
                    cmd_tail_q <= 0;
                else
                    cmd_tail_q <= cmd_tail_q + 1'b1;
                if (req_lock_i && !lock_active_q &&
                    (req_op_i == `OPENRV64_ICX_OP_READ)) begin
                    lock_active_q <= 1'b1;
                    lock_hart_id_q <= req_hart_id_i;
                    lock_line_addr_q <= incoming_line_addr;
                end
            end

            if (wdata_fire) begin
                cmd_wdata_valid_q[wdata_match_index_r] <= 1'b1;
                cmd_wdata_q[wdata_match_index_r] <= wdata_i;
                cmd_wstrb_q[wdata_match_index_r] <= wstrb_i;
                cmd_wdata_error_q[wdata_match_index_r] <=
                    (wdata_last_i !=
                     (wdata_beat_index_i ==
                      cmd_burst_len_q[wdata_match_index_r]));
            end

            if (command_advance)
                cmd_beat_q <= cmd_beat_q + 1'b1;
            if (command_pop) begin
                cmd_beat_q <= 0;
                if (!(command_push && (cmd_tail_q == cmd_head_q))) begin
                    cmd_entry_valid_q[cmd_head_q] <= 1'b0;
                    cmd_wdata_valid_q[cmd_head_q] <= 1'b0;
                    cmd_wdata_error_q[cmd_head_q] <= 1'b0;
                end
                if (cmd_head_q ==
                    COMMAND_INDEX_WIDTH'(COMMAND_ENTRIES - 1))
                    cmd_head_q <= 0;
                else
                    cmd_head_q <= cmd_head_q + 1'b1;
            end
            if (lookup_capture && cmd_head_write) begin
                cmd_wdata_valid_q[cmd_head_q] <= 1'b0;
                cmd_wdata_error_q[cmd_head_q] <= 1'b0;
            end

            case ({command_push, command_pop})
                2'b10: cmd_count_q <= cmd_count_q + 1'b1;
                2'b01: cmd_count_q <= cmd_count_q - 1'b1;
                default: cmd_count_q <= cmd_count_q;
            endcase

            if (lookup_capture) begin
                lookup_valid_q <= 1'b1;
                lookup_coh_response_seen_q <= 1'b0;
                lookup_hart_id_q <= cmd_hart_id_q[cmd_head_q];
                lookup_txn_id_q <= cmd_txn_id_q[cmd_head_q];
                lookup_source_id_q <= cmd_source_id_q[cmd_head_q];
                lookup_op_q <= cmd_op_q[cmd_head_q];
                lookup_lock_q <= cmd_lock_q[cmd_head_q];
                lookup_order_q <= cmd_order_q[cmd_head_q];
                lookup_kind_q <= cmd_kind_q[cmd_head_q];
                lookup_attr_q <= cmd_attr_q[cmd_head_q];
                lookup_size_q <= cmd_size_q[cmd_head_q];
                lookup_addr_q <= cmd_head_effective_addr;
                lookup_beat_q <= cmd_beat_q;
                lookup_last_q <= cmd_head_last;
                lookup_wdata_q <= cmd_wdata_q[cmd_head_q];
                lookup_wstrb_q <= cmd_wstrb_q[cmd_head_q];
                lookup_protocol_error_q <= cmd_head_protocol_error |
                                           cmd_wdata_error_q[cmd_head_q];
            end else if (lookup_dispatch_r) begin
                lookup_valid_q <= 1'b0;
                lookup_coh_response_seen_q <= 1'b0;
            end else if (lookup_valid_q &&
                         coherence_directory_lookup_response_valid) begin
                lookup_coh_response_seen_q <= 1'b1;
            end

            // An LR reserves only after its data response has completed without
            // error.  A younger coherent write dispatched in this same cycle is
            // ordered after the LR completion and therefore clears it below.
            if ((ENABLE_COHERENCE != 0) && response_enqueue &&
                !enqueue_error &&
                (enqueue_op == `OPENRV64_ICX_OP_LR)) begin
                for (reservation_scan = 0;
                     reservation_scan < NUM_HARTS;
                     reservation_scan = reservation_scan + 1) begin
                    if (enqueue_hart_id ==
                        `OPENRV64_ICX_HART_ID_WIDTH'(
                            HART_ID_BASE + reservation_scan)) begin
                        reservation_valid_q[reservation_scan] <= 1'b1;
                        reservation_line_q[reservation_scan] <=
                            {enqueue_addr[63:6], 6'b0};
                    end
                end
            end

            if ((ENABLE_COHERENCE != 0) && lookup_dispatch_r &&
                !lookup_protocol_error_q && !coherence_hart_error) begin
                if (lookup_op_q == `OPENRV64_ICX_OP_SC) begin
                    for (reservation_scan = 0;
                         reservation_scan < NUM_HARTS;
                         reservation_scan = reservation_scan + 1)
                        if (lookup_hart_id_q ==
                            `OPENRV64_ICX_HART_ID_WIDTH'(
                                HART_ID_BASE + reservation_scan))
                            reservation_valid_q[reservation_scan] <= 1'b0;
                end

                if (lookup_coherent_write &&
                    ((lookup_op_q != `OPENRV64_ICX_OP_SC) ||
                     lookup_sc_reservation_match_r)) begin
                    for (reservation_scan = 0;
                         reservation_scan < NUM_HARTS;
                         reservation_scan = reservation_scan + 1)
                        if (reservation_valid_q[reservation_scan] &&
                            (reservation_line_q[reservation_scan] ==
                             lookup_line_addr))
                            reservation_valid_q[reservation_scan] <= 1'b0;
                end
            end

            if (lookup_dispatch_r &&
                ((lookup_action_r == LOOKUP_IMMEDIATE) ||
                 (lookup_action_r == LOOKUP_HIT) ||
                 (lookup_action_r == LOOKUP_VICTIM_HIT))) begin
                hit_valid_q <= 1'b1;
                hit_hart_id_q <= lookup_hart_id_q;
                hit_txn_id_q <= lookup_txn_id_q;
                hit_source_id_q <= lookup_source_id_q;
                hit_op_q <= lookup_op_q;
                hit_lock_q <= lookup_lock_q;
                hit_beat_q <= lookup_beat_q;
                hit_last_q <= lookup_last_q;
                hit_addr_q <= lookup_addr_q;
                hit_error_q <=
                    lookup_protocol_error_q | coherence_hart_error |
                    (lookup_invariant_match &&
                     (lookup_op_q != `OPENRV64_ICX_OP_READ) &&
                     (lookup_op_q != `OPENRV64_ICX_OP_WRITE));
                hit_private_fill_q <= lookup_private_fill &&
                    !lookup_protocol_error_q && !coherence_hart_error;
                hit_sc_success_q <=
                    (ENABLE_COHERENCE != 0) &&
                    (lookup_op_q == `OPENRV64_ICX_OP_SC) &&
                    lookup_sc_reservation_match_r;
                if ((lookup_action_r == LOOKUP_IMMEDIATE) &&
                    lookup_invariant_match &&
                    (lookup_op_q == `OPENRV64_ICX_OP_READ))
                    hit_data_q <= lookup_invariant_data;
                else if ((lookup_action_r == LOOKUP_HIT) &&
                    lookup_is_read)
                    hit_data_q <= lookup_read_data;
                else if ((lookup_action_r == LOOKUP_VICTIM_HIT) &&
                         lookup_is_read)
                    hit_data_q <= lookup_dirty_victim_read_data;
                else
                    hit_data_q <= 0;

                if ((lookup_action_r == LOOKUP_HIT) &&
                    lookup_is_write) begin
                    dirty_q[lookup_set][lookup_hit_way_r] <= 1'b1;
                end
            end else if (hit_enqueue) begin
                hit_valid_q <= 1'b0;
            end

            if (lookup_dispatch_r &&
                (lookup_action_r == LOOKUP_MERGE)) begin
                waiter_hart_id_q[lookup_merge_waiter_index] <=
                    lookup_hart_id_q;
                waiter_txn_id_q[lookup_merge_waiter_index] <=
                    lookup_txn_id_q;
                waiter_source_id_q[lookup_merge_waiter_index] <=
                    lookup_source_id_q;
                waiter_op_q[lookup_merge_waiter_index] <= lookup_op_q;
                waiter_lock_q[lookup_merge_waiter_index] <= lookup_lock_q;
                waiter_order_q[lookup_merge_waiter_index] <=
                    lookup_order_q;
                waiter_kind_q[lookup_merge_waiter_index] <= lookup_kind_q;
                waiter_attr_q[lookup_merge_waiter_index] <= lookup_attr_q;
                waiter_size_q[lookup_merge_waiter_index] <= lookup_size_q;
                waiter_addr_q[lookup_merge_waiter_index] <= lookup_addr_q;
                waiter_beat_q[lookup_merge_waiter_index] <= lookup_beat_q;
                waiter_last_q[lookup_merge_waiter_index] <= lookup_last_q;
                waiter_wdata_q[lookup_merge_waiter_index] <=
                    lookup_wdata_q;
                waiter_wstrb_q[lookup_merge_waiter_index] <=
                    lookup_wstrb_q;
                mshr_waiter_count_q[lookup_mshr_index_r] <=
                    mshr_waiter_count_q[lookup_mshr_index_r] + 1'b1;
                if (lookup_private_fill)
                    mshr_private_fill_q[lookup_mshr_index_r] <= 1'b1;
                if (coherence_private_probe_needed) begin
                    if (lookup_source_id_q ==
                        `OPENRV64_ICX_SOURCE_ICACHE)
                        mshr_directory_add_i_q[lookup_mshr_index_r] <=
                            mshr_directory_add_i_q[
                                lookup_mshr_index_r] |
                            lookup_request_hart_mask_r;
                    if (lookup_source_id_q ==
                        `OPENRV64_ICX_SOURCE_DCACHE)
                        mshr_directory_add_d_q[lookup_mshr_index_r] <=
                            mshr_directory_add_d_q[
                                lookup_mshr_index_r] |
                            lookup_request_hart_mask_r;
                end
            end

            if (lookup_dispatch_r &&
                ((lookup_action_r == LOOKUP_ALLOC) ||
                 (lookup_action_r == LOOKUP_BYPASS) ||
                 (lookup_action_r == LOOKUP_WRITE_AROUND) ||
                 (lookup_action_r == LOOKUP_COH_PROBE))) begin
                mshr_valid_q[mshr_free_index_r] <= 1'b1;
                mshr_bypass_q[mshr_free_index_r] <=
                    (lookup_action_r == LOOKUP_BYPASS) ||
                    (lookup_action_r == LOOKUP_WRITE_AROUND) ||
                    ((lookup_action_r == LOOKUP_COH_PROBE) &&
                     (lookup_base_action_r == LOOKUP_WRITE_AROUND));
                mshr_bus_cacheable_q[mshr_free_index_r] <=
                    lookup_cacheable;
                mshr_line_addr_q[mshr_free_index_r] <= lookup_line_addr;
                mshr_waiter_count_q[mshr_free_index_r] <= 1;
                mshr_replay_q[mshr_free_index_r] <= 0;
                mshr_error_q[mshr_free_index_r] <= 1'b0;
                mshr_replay_strb_q[mshr_free_index_r] <= 0;
                mshr_private_fill_q[mshr_free_index_r] <=
                    lookup_private_fill;
                if (lookup_action_r == LOOKUP_COH_PROBE) begin
                    mshr_state_q[mshr_free_index_r] <= MSHR_NEED_PROBE;
                    if (lookup_base_action_r == LOOKUP_HIT) begin
                        mshr_set_q[mshr_free_index_r] <= lookup_set;
                        mshr_tag_q[mshr_free_index_r] <= lookup_tag;
                        mshr_way_q[mshr_free_index_r] <= lookup_hit_way_r;
                        mshr_pte_generation_q[mshr_free_index_r] <=
                            pte_generation_q;
                        mshr_replay_data_q[mshr_free_index_r] <=
                            lookup_hit_data;
                        mshr_replay_strb_q[mshr_free_index_r] <=
                            lookup_hit_dirty_strb;
                        mshr_post_probe_state_q[mshr_free_index_r] <=
                            MSHR_REPLAY;
                        reserved_q[lookup_set][lookup_hit_way_r] <= 1'b1;
                    end else if (lookup_base_action_r == LOOKUP_ALLOC) begin
                        mshr_set_q[mshr_free_index_r] <= lookup_set;
                        mshr_tag_q[mshr_free_index_r] <= lookup_tag;
                        mshr_way_q[mshr_free_index_r] <= victim_way_r;
                        mshr_pte_generation_q[mshr_free_index_r] <=
                            pte_generation_q;
                        mshr_victim_addr_q[mshr_free_index_r] <=
                            {lookup_victim_tag, lookup_set,
                             {LINE_OFFSET_BITS{1'b0}}};
                        mshr_victim_data_q[mshr_free_index_r] <=
                            lookup_victim_data;
                        mshr_victim_strb_q[mshr_free_index_r] <=
                            lookup_victim_dirty_strb;
                        reserved_q[lookup_set][victim_way_r] <= 1'b1;
                        if (valid_q[lookup_set][victim_way_r] &&
                            dirty_q[lookup_set][victim_way_r])
                            mshr_post_probe_state_q[
                                mshr_free_index_r] <= MSHR_NEED_WB;
                        else
                            mshr_post_probe_state_q[
                                mshr_free_index_r] <= MSHR_NEED_FILL;
                    end else begin
                        mshr_post_probe_state_q[mshr_free_index_r] <=
                            MSHR_NEED_BYPASS;
                    end

                    if (coherence_private_probe_needed) begin
                        mshr_coh_action_q[mshr_free_index_r] <=
                            COH_ACTION_ALLOCATE;
                        mshr_directory_entry_q[mshr_free_index_r] <=
                            coherence_directory_victim_entry;
                        mshr_probe_target_q[mshr_free_index_r] <=
                            coherence_directory_victim_i_sharers |
                            coherence_directory_victim_d_sharers;
                        mshr_probe_cache_mask_q[mshr_free_index_r] <= {
                            |coherence_directory_victim_d_sharers,
                            |coherence_directory_victim_i_sharers
                        };
                        mshr_probe_line_addr_q[mshr_free_index_r] <=
                            coherence_directory_victim_line_addr;
                        mshr_directory_add_i_q[mshr_free_index_r] <=
                            (lookup_source_id_q ==
                             `OPENRV64_ICX_SOURCE_ICACHE) ?
                                lookup_request_hart_mask_r :
                                {NUM_HARTS{1'b0}};
                        mshr_directory_add_d_q[mshr_free_index_r] <=
                            (lookup_source_id_q ==
                             `OPENRV64_ICX_SOURCE_DCACHE) ?
                                lookup_request_hart_mask_r :
                                {NUM_HARTS{1'b0}};
                        mshr_directory_clear_d_q[mshr_free_index_r] <=
                            {NUM_HARTS{1'b0}};
                    end else begin
                        mshr_coh_action_q[mshr_free_index_r] <=
                            COH_ACTION_CLEAR;
                        mshr_directory_entry_q[mshr_free_index_r] <=
                            coherence_directory_lookup_entry;
                        mshr_probe_target_q[mshr_free_index_r] <=
                            coherence_write_probe_targets;
                        mshr_probe_cache_mask_q[mshr_free_index_r] <=
                            `OPENRV64_ICX_PROBE_CACHE_D;
                        mshr_probe_line_addr_q[mshr_free_index_r] <=
                            lookup_line_addr;
                        // Probe completion may occur after unrelated
                        // directory lookups.  Preserve the complete lookup
                        // snapshot so the deferred write can overwrite this
                        // entry without consuming another set's registered
                        // SRAM read word.
                        mshr_directory_add_i_q[mshr_free_index_r] <=
                            coherence_directory_lookup_i_sharers;
                        mshr_directory_add_d_q[mshr_free_index_r] <=
                            coherence_directory_lookup_d_sharers;
                        mshr_directory_clear_d_q[mshr_free_index_r] <=
                            (lookup_op_q == `OPENRV64_ICX_OP_SC) ?
                                {NUM_HARTS{1'b1}} :
                                coherence_write_probe_targets;
                    end
                end else if (lookup_action_r != LOOKUP_ALLOC) begin
                    mshr_state_q[mshr_free_index_r] <= MSHR_NEED_BYPASS;
                end else begin
                    mshr_set_q[mshr_free_index_r] <= lookup_set;
                    mshr_tag_q[mshr_free_index_r] <= lookup_tag;
                    mshr_way_q[mshr_free_index_r] <= victim_way_r;
                    mshr_pte_generation_q[mshr_free_index_r] <=
                        pte_generation_q;
                    mshr_victim_addr_q[mshr_free_index_r] <=
                        {lookup_victim_tag, lookup_set,
                         {LINE_OFFSET_BITS{1'b0}}};
                    mshr_victim_data_q[mshr_free_index_r] <=
                        lookup_victim_data;
                    mshr_victim_strb_q[mshr_free_index_r] <=
                        lookup_victim_dirty_strb;
                    reserved_q[lookup_set][victim_way_r] <= 1'b1;
                    if (valid_q[lookup_set][victim_way_r] &&
                        dirty_q[lookup_set][victim_way_r])
                        mshr_state_q[mshr_free_index_r] <= MSHR_NEED_WB;
                    else
                        mshr_state_q[mshr_free_index_r] <= MSHR_NEED_FILL;
                end
                waiter_hart_id_q[lookup_alloc_waiter_index] <=
                    lookup_hart_id_q;
                waiter_txn_id_q[lookup_alloc_waiter_index] <=
                    lookup_txn_id_q;
                waiter_source_id_q[lookup_alloc_waiter_index] <=
                    lookup_source_id_q;
                waiter_op_q[lookup_alloc_waiter_index] <= lookup_op_q;
                waiter_lock_q[lookup_alloc_waiter_index] <= lookup_lock_q;
                waiter_order_q[lookup_alloc_waiter_index] <=
                    lookup_order_q;
                waiter_kind_q[lookup_alloc_waiter_index] <= lookup_kind_q;
                waiter_attr_q[lookup_alloc_waiter_index] <= lookup_attr_q;
                waiter_size_q[lookup_alloc_waiter_index] <= lookup_size_q;
                waiter_addr_q[lookup_alloc_waiter_index] <= lookup_addr_q;
                waiter_beat_q[lookup_alloc_waiter_index] <= lookup_beat_q;
                waiter_last_q[lookup_alloc_waiter_index] <= lookup_last_q;
                waiter_wdata_q[lookup_alloc_waiter_index] <=
                    lookup_wdata_q;
                waiter_wstrb_q[lookup_alloc_waiter_index] <=
                    lookup_wstrb_q;
            end

            if (coherence_probe_start_fire) begin
                active_probe_mshr_q <= probe_candidate_mshr_r;
                next_probe_id_q <= next_probe_id_q + 1'b1;
                mshr_state_q[probe_candidate_mshr_r] <=
                    MSHR_PROBE_INFLIGHT;
            end

            if (coherence_probe_completion) begin
                mshr_state_q[active_probe_mshr_q] <=
                    mshr_post_probe_state_q[active_probe_mshr_q];
            end

            if (bus_request_fire) begin
                bus_track_mshr_q[bus_track_tail_q] <=
                    bus_candidate_mshr_r;
                bus_track_action_q[bus_track_tail_q] <=
                    bus_candidate_action_r;
                if (bus_track_tail_q ==
                    TRACK_INDEX_WIDTH'(BUS_TRACK_ENTRIES - 1))
                    bus_track_tail_q <= 0;
                else
                    bus_track_tail_q <= bus_track_tail_q + 1'b1;
                if (bus_candidate_action_r == BUS_ACTION_WB)
                    mshr_state_q[bus_candidate_mshr_r] <=
                        MSHR_WB_INFLIGHT;
                else if (bus_candidate_action_r == BUS_ACTION_FILL)
                    mshr_state_q[bus_candidate_mshr_r] <=
                        MSHR_FILL_INFLIGHT;
                else
                    mshr_state_q[bus_candidate_mshr_r] <=
                        MSHR_BYPASS_INFLIGHT;
                if (bus_candidate_mshr_r ==
                    MSHR_INDEX_WIDTH'(MSHR_ENTRIES - 1))
                    bus_round_robin_q <= 0;
                else
                    bus_round_robin_q <= bus_candidate_mshr_r + 1'b1;
            end

            if (bus_response_fire) begin
                if (bus_track_head_q ==
                    TRACK_INDEX_WIDTH'(BUS_TRACK_ENTRIES - 1))
                    bus_track_head_q <= 0;
                else
                    bus_track_head_q <= bus_track_head_q + 1'b1;

                if (bus_response_action == BUS_ACTION_WB) begin
                    if (bus_resp_error_i) begin
                        mshr_error_q[bus_response_mshr] <= 1'b1;
                        mshr_state_q[bus_response_mshr] <= MSHR_ERROR;
                    end else begin
                        valid_q[mshr_set_q[bus_response_mshr]]
                               [mshr_way_q[bus_response_mshr]] <= 1'b0;
                        dirty_q[mshr_set_q[bus_response_mshr]]
                               [mshr_way_q[bus_response_mshr]] <= 1'b0;
                        mshr_state_q[bus_response_mshr] <= MSHR_NEED_FILL;
                    end
                end else if (bus_response_action == BUS_ACTION_FILL) begin
                    if (bus_resp_error_i) begin
                        mshr_error_q[bus_response_mshr] <= 1'b1;
                        mshr_state_q[bus_response_mshr] <= MSHR_ERROR;
                    end else begin
                        mshr_replay_data_q[bus_response_mshr] <=
                            bus_resp_rdata_i;
                        mshr_replay_strb_q[bus_response_mshr] <= 0;
                        valid_q[mshr_set_q[bus_response_mshr]]
                               [mshr_way_q[bus_response_mshr]] <= 1'b1;
                        dirty_q[mshr_set_q[bus_response_mshr]]
                               [mshr_way_q[bus_response_mshr]] <= 1'b0;
                        replace_q[mshr_set_q[bus_response_mshr]] <=
                            (mshr_way_q[bus_response_mshr] ==
                             WAY_INDEX_WIDTH'(WAYS - 1)) ? 0 :
                            mshr_way_q[bus_response_mshr] + 1'b1;
                        mshr_state_q[bus_response_mshr] <= MSHR_REPLAY;
                    end
                end else begin
                    mshr_bypass_data_q[bus_response_mshr] <=
                        bus_resp_rdata_i;
                    if (bus_resp_error_i) begin
                        mshr_error_q[bus_response_mshr] <= 1'b1;
                        mshr_state_q[bus_response_mshr] <= MSHR_ERROR;
                    end else begin
                        mshr_state_q[bus_response_mshr] <= MSHR_REPLAY;
                    end
                end
            end

            case ({bus_request_fire, bus_response_fire})
                2'b10: bus_track_count_q <= bus_track_count_q + 1'b1;
                2'b01: bus_track_count_q <= bus_track_count_q - 1'b1;
                default: bus_track_count_q <= bus_track_count_q;
            endcase

            if (replay_cache_write) begin
                mshr_replay_data_q[replay_mshr] <= replay_write_data_r;
                mshr_replay_strb_q[replay_mshr] <= replay_write_strb_r;
                dirty_q[mshr_set_q[replay_mshr]]
                       [mshr_way_q[replay_mshr]] <= 1'b1;
            end

            if (replay_enqueue) begin
                if (replay_final) begin
                    if (!mshr_bypass_q[replay_mshr])
                        reserved_q[mshr_set_q[replay_mshr]]
                                  [mshr_way_q[replay_mshr]] <= 1'b0;
                    mshr_valid_q[replay_mshr] <= 1'b0;
                    mshr_state_q[replay_mshr] <= MSHR_IDLE;
                    mshr_waiter_count_q[replay_mshr] <= 0;
                    mshr_replay_q[replay_mshr] <= 0;
                end else begin
                    mshr_replay_q[replay_mshr] <=
                        mshr_replay_q[replay_mshr] + 1'b1;
                end
                if (replay_mshr ==
                    MSHR_INDEX_WIDTH'(MSHR_ENTRIES - 1))
                    replay_round_robin_q <= 0;
                else
                    replay_round_robin_q <= replay_mshr + 1'b1;
            end

            if (response_enqueue) begin
                response_hart_id_q[response_tail_q] <= enqueue_hart_id;
                response_txn_id_q[response_tail_q] <= enqueue_txn_id;
                response_source_id_q[response_tail_q] <= enqueue_source_id;
                response_beat_q[response_tail_q] <= enqueue_beat;
                response_last_q[response_tail_q] <= enqueue_last;
                response_data_q[response_tail_q] <= enqueue_data;
                response_error_q[response_tail_q] <= enqueue_error;
                response_sc_success_q[response_tail_q] <=
                    enqueue_sc_success;
                response_private_fill_q[response_tail_q] <=
                    enqueue_private_fill;
                response_directory_set_q[response_tail_q] <=
                    enqueue_addr[
                        LINE_OFFSET_BITS +: DIRECTORY_SET_WIDTH];
                if (response_tail_q ==
                    RESPONSE_INDEX_WIDTH'(RESPONSE_ENTRIES - 1))
                    response_tail_q <= 0;
                else
                    response_tail_q <= response_tail_q + 1'b1;
            end
            if (response_dequeue) begin
                if (!(response_enqueue &&
                      (response_tail_q == response_head_q)))
                    response_private_fill_q[response_head_q] <= 1'b0;
                if (response_head_q ==
                    RESPONSE_INDEX_WIDTH'(RESPONSE_ENTRIES - 1))
                    response_head_q <= 0;
                else
                    response_head_q <= response_head_q + 1'b1;
            end
            case ({response_enqueue, response_dequeue})
                2'b10: response_count_q <= response_count_q + 1'b1;
                2'b01: response_count_q <= response_count_q - 1'b1;
                default: response_count_q <= response_count_q;
            endcase

            if (response_enqueue && enqueue_lock &&
                ((enqueue_op == `OPENRV64_ICX_OP_WRITE) ||
                 enqueue_error) &&
                (enqueue_hart_id == lock_hart_id_q))
                lock_active_q <= 1'b0;
        end
    end

`ifndef SYNTHESIS
    openrv64_l2_debug_stub #(
        .NUM_HARTS(NUM_HARTS),
        .MSHR_ENTRIES(MSHR_ENTRIES),
        .WAITERS_PER_MSHR(WAITERS_PER_MSHR),
        .COMMAND_ENTRIES(COMMAND_ENTRIES),
        .RESPONSE_ENTRIES(RESPONSE_ENTRIES),
        .BUS_TRACK_ENTRIES(BUS_TRACK_ENTRIES),
        .TOTAL_WAITERS(TOTAL_WAITERS),
        .MSHR_INDEX_WIDTH(MSHR_INDEX_WIDTH),
        .COMMAND_COUNT_WIDTH(COMMAND_COUNT_WIDTH),
        .RESPONSE_COUNT_WIDTH(RESPONSE_COUNT_WIDTH),
        .TRACK_INDEX_WIDTH(TRACK_INDEX_WIDTH),
        .WAY_INDEX_WIDTH(WAY_INDEX_WIDTH),
        .SRAM_PAYLOAD_WIDTH(SRAM_PAYLOAD_WIDTH)
    ) u_debug (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .active_probe_mshr(active_probe_mshr_q),
        .cmd_count(cmd_count_q),
        .coherence_hart_error(coherence_hart_error),
        .coherence_probe_completion(coherence_probe_completion),
        .probe_issue_pending(debug_probe_issue_pending),
        .probe_ack_pending(debug_probe_ack_pending),
        .lookup_action(lookup_action_r),
        .lookup_coh_probe(LOOKUP_COH_PROBE),
        .lookup_dispatch(lookup_dispatch_r),
        .lookup_hart_id(lookup_hart_id_q),
        .lookup_txn_id(lookup_txn_id_q),
        .lookup_source_id(lookup_source_id_q),
        .lookup_op(lookup_op_q),
        .lookup_kind(lookup_kind_q),
        .lookup_attr(lookup_attr_q),
        .lookup_size(lookup_size_q),
        .lookup_addr(lookup_addr_q),
        .lookup_wdata(lookup_wdata_q),
        .lookup_wstrb(lookup_wstrb_q),
        .lookup_protocol_error(lookup_protocol_error_q),
        .lookup_sc_failed(lookup_sc_failed),
        .mshr_valid(mshr_valid_q),
        .mshr_state(mshr_state_q),
        .mshr_line_addr(mshr_line_addr_q),
        .mshr_probe_target(mshr_probe_target_q),
        .mshr_probe_cache_mask(mshr_probe_cache_mask_q),
        .waiter_hart_id(waiter_hart_id_q),
        .waiter_txn_id(waiter_txn_id_q),
        .waiter_source_id(waiter_source_id_q),
        .waiter_op(waiter_op_q),
        .waiter_kind(waiter_kind_q),
        .waiter_attr(waiter_attr_q),
        .waiter_size(waiter_size_q),
        .waiter_addr(waiter_addr_q),
        .waiter_wdata(waiter_wdata_q),
        .waiter_wstrb(waiter_wstrb_q),
        .response_count(response_count_q),
        .active_probe_mshr_q(active_probe_mshr_q),
        .cmd_count_q(cmd_count_q),
        .lookup_action_r(lookup_action_r),
        .lookup_hart_id_q(lookup_hart_id_q),
        .lookup_txn_id_q(lookup_txn_id_q),
        .lookup_source_id_q(lookup_source_id_q),
        .lookup_op_q(lookup_op_q),
        .lookup_kind_q(lookup_kind_q),
        .lookup_attr_q(lookup_attr_q),
        .lookup_size_q(lookup_size_q),
        .lookup_addr_q(lookup_addr_q),
        .lookup_wdata_q(lookup_wdata_q),
        .lookup_wstrb_q(lookup_wstrb_q),
        .lookup_protocol_error_q(lookup_protocol_error_q),
        .mshr_valid_q(mshr_valid_q),
        .mshr_state_q(mshr_state_q),
        .mshr_line_addr_q(mshr_line_addr_q),
        .mshr_probe_target_q(mshr_probe_target_q),
        .mshr_probe_cache_mask_q(mshr_probe_cache_mask_q),
        .waiter_hart_id_q(waiter_hart_id_q),
        .waiter_source_id_q(waiter_source_id_q),
        .waiter_op_q(waiter_op_q),
        .waiter_size_q(waiter_size_q),
        .waiter_addr_q(waiter_addr_q),
        .response_count_q(response_count_q),
        .bus_request_fire(bus_request_fire),
        .bus_response_fire(bus_response_fire),
        .bus_candidate_mshr_r(bus_candidate_mshr_r),
        .bus_candidate_action_r(bus_candidate_action_r),
        .bus_track_head_q(bus_track_head_q),
        .bus_track_mshr_q(bus_track_mshr_q),
        .bus_track_action_q(bus_track_action_q),
        .response_enqueue(response_enqueue),
        .hit_enqueue(hit_enqueue),
        .hit_data_q(hit_data_q),
        .enqueue_addr(enqueue_addr),
        .lookup_valid_q(lookup_valid_q),
        .lookup_dispatch_r(lookup_dispatch_r),
        .lookup_hit_r(lookup_hit_r),
        .lookup_hit_way_r(lookup_hit_way_r),
        .lookup_hit_payload(lookup_hit_payload),
        .lookup_mshr_match_r(lookup_mshr_match_r),
        .lookup_mshr_index_r(lookup_mshr_index_r),
        .mshr_free_index_r(mshr_free_index_r),
        .replay_candidate_mshr_r(replay_candidate_mshr_r),
        .mshr_replay_data_q(mshr_replay_data_q),
        .mshr_bypass_q(mshr_bypass_q),
        .mshr_bus_cacheable_q(mshr_bus_cacheable_q),
        .mshr_coh_action_q(mshr_coh_action_q),
        .mshr_post_probe_state_q(mshr_post_probe_state_q),
        .waiter_lock_q(waiter_lock_q),
        .probe_id_q(debug_probe_id),
        .probe_command_q(debug_probe_command),
        .probe_cache_mask_q(debug_probe_cache_mask),
        .probe_line_addr_q(debug_probe_line_addr)
    );

    always @(posedge clk_i) begin
        if (rst_ni && command_push && req_lock_i && !lock_active_q &&
            (req_op_i != `OPENRV64_ICX_OP_READ))
            $fatal(1, "native L2 lock sequence must begin with READ");
        if (rst_ni && command_push && req_lock_i &&
            ((req_size_i == 3'd6) || (req_burst_len_i != 0)))
            $fatal(1, "native L2 lock is valid only for scalar operations");
        if (rst_ni && wdata_valid_i && wdata_match_multiple_r)
            $fatal(1, "native L2 has duplicate write-data identities");
        if (rst_ni && bus_request_fire &&
            (bus_candidate_action_r != BUS_ACTION_BYPASS) &&
            ((bus_req_size_o != 3'd6) ||
             (bus_req_addr_o[LINE_OFFSET_BITS-1:0] != 0)))
            $fatal(1, "native L2 emitted a non-line cache bus request");
        if (rst_ni && bus_request_fire &&
            (bus_candidate_action_r == BUS_ACTION_BYPASS) &&
            mshr_bus_cacheable_q[bus_candidate_mshr_r] &&
            (waiter_op_q[bus_waiter_index] == `OPENRV64_ICX_OP_SC))
            $fatal(1, "native L2 emitted a cacheable SC write-around");
    end

    initial begin
        if ((ADDR_WIDTH < 32) || (ADDR_WIDTH > 64))
            $fatal(1, "native L2 address width must be 32 through 64");
        if (LINE_BYTES != `OPENRV64_ICX_LINE_BYTES)
            $fatal(1, "native L2 line size must be 64 bytes");
        if ((CACHE_BYTES < 256 * 1024) ||
            (CACHE_BYTES > 1024 * 1024) ||
            ((CACHE_BYTES & (CACHE_BYTES - 1)) != 0))
            $fatal(1,
                "native L2 capacity must be a power of two from 256 KiB through 1 MiB");
        if ((WAYS < 1) || ((WAYS & (WAYS - 1)) != 0))
            $fatal(1, "native L2 ways must be a power of two");
        if ((MSHR_ENTRIES < 2) || (MSHR_ENTRIES > 16))
            $fatal(1, "native L2 MSHR entries must be 2 through 16");
        if ((WAITERS_PER_MSHR < 1) || (WAITERS_PER_MSHR > 16))
            $fatal(1, "native L2 waiter depth must be 1 through 16");
        if ((COMMAND_ENTRIES < 2) || (COMMAND_ENTRIES > 32))
            $fatal(1, "native L2 command entries must be 2 through 32");
        if ((RESPONSE_ENTRIES < 2) || (RESPONSE_ENTRIES > 32))
            $fatal(1, "native L2 response entries must be 2 through 32");
        if ((PTE_GENERATION_BITS < 1) || (PTE_GENERATION_BITS > 16))
            $fatal(1, "native L2 PTE generation width must be 1 through 16");
        if ((BUS_TRACK_ENTRIES < 2) ||
            (BUS_TRACK_ENTRIES > MSHR_ENTRIES))
            $fatal(1,
                "native L2 bus tracking entries must be 2 through MSHR entries");
    end
`endif

    // Keep these fields in the waiter record for the coherent ordering stage.
    wire unused_waiter_order = ^waiter_order_q[0];
    wire unused_waiter_kind = ^waiter_kind_q[0];
    wire unused_waiter_attr = ^waiter_attr_q[0];
    wire unused_lookup_way = ^lookup_hit_way_r;

endmodule
