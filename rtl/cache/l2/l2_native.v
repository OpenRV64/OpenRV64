`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// Native 512-bit, nonblocking shared L2.
//
// The north and south neutral interfaces both move one complete 64-byte line
// per cacheable request.  Width conversion belongs below this module in
// genbus_interface.  A command FIFO feeds a synchronous per-way SRAM lookup
// followed by a registered hit stage, allowing requests to continue behind
// outstanding fills.  Independent per-line MSHRs merge requests to an active
// miss, while an ordered bus tracking FIFO permits multiple writebacks/refills
// to be accepted by the external bus abstraction.
module openrv64_ccx_l2_native #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer CACHE_BYTES = 256 * 1024,
    parameter integer LINE_BYTES = `OPENRV64_CCX_LINE_BYTES,
    parameter integer WAYS = 8,
    parameter integer MSHR_ENTRIES = 8,
    parameter integer WAITERS_PER_MSHR = 8,
    parameter integer COMMAND_ENTRIES = 16,
    parameter integer RESPONSE_ENTRIES = 16,
    parameter integer BUS_TRACK_ENTRIES = MSHR_ENTRIES,
    parameter integer PTE_GENERATION_BITS = 8
) (
    input  wire clk_i,
    input  wire rst_ni,

    input  wire                         req_valid_i,
    output wire                         req_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] req_hart_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] req_txn_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] req_source_id_i,
    input  wire [`OPENRV64_CCX_OP_WIDTH-1:0] req_op_i,
    input  wire                         req_lock_i,
    input  wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] req_order_i,
    input  wire [`OPENRV64_CCX_KIND_WIDTH-1:0] req_kind_i,
    input  wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] req_attr_i,
    input  wire [2:0]                   req_size_i,
    input  wire [63:0]                  req_addr_i,
    input  wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] req_burst_len_i,

    input  wire                         wdata_valid_i,
    output wire                         wdata_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] wdata_hart_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] wdata_txn_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] wdata_source_id_i,
    input  wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] wdata_beat_index_i,
    input  wire                         wdata_last_i,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] wdata_i,
    input  wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] wstrb_i,

    output wire                         resp_valid_o,
    input  wire                         resp_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] resp_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] resp_txn_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] resp_source_id_o,
    output wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] resp_beat_index_o,
    output wire                         resp_last_o,
    output wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] resp_rdata_o,
    output wire                         resp_error_o,
    output wire                         resp_sc_success_o,

    output wire                         bus_req_valid_o,
    input  wire                         bus_req_ready_i,
    output reg                          bus_req_write_o,
    output reg  [63:0]                  bus_req_addr_o,
    output reg  [2:0]                   bus_req_size_o,
    output reg  [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] bus_req_wdata_o,
    output reg  [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] bus_req_wstrb_o,
    output reg                          bus_req_cacheable_o,
    input  wire                         bus_resp_valid_i,
    output wire                         bus_resp_ready_o,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] bus_resp_rdata_i,
    input  wire                         bus_resp_error_i
);

    localparam integer SETS = CACHE_BYTES / (LINE_BYTES * WAYS);
    localparam integer LINE_OFFSET_BITS = $clog2(LINE_BYTES);
    localparam integer SET_BITS = $clog2(SETS);
    localparam integer TAG_BITS = ADDR_WIDTH - LINE_OFFSET_BITS - SET_BITS;
    localparam integer SRAM_TAG_BITS =
        TAG_BITS + PTE_GENERATION_BITS;
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

    localparam [3:0] MSHR_IDLE            = 4'd0;
    localparam [3:0] MSHR_NEED_WB         = 4'd1;
    localparam [3:0] MSHR_WB_INFLIGHT     = 4'd2;
    localparam [3:0] MSHR_NEED_FILL       = 4'd3;
    localparam [3:0] MSHR_FILL_INFLIGHT   = 4'd4;
    localparam [3:0] MSHR_NEED_BYPASS     = 4'd5;
    localparam [3:0] MSHR_BYPASS_INFLIGHT = 4'd6;
    localparam [3:0] MSHR_REPLAY          = 4'd7;
    localparam [3:0] MSHR_ERROR           = 4'd8;

    localparam [1:0] BUS_ACTION_WB     = 2'd0;
    localparam [1:0] BUS_ACTION_FILL   = 2'd1;
    localparam [1:0] BUS_ACTION_BYPASS = 2'd2;

    localparam [2:0] LOOKUP_NONE      = 3'd0;
    localparam [2:0] LOOKUP_IMMEDIATE = 3'd1;
    localparam [2:0] LOOKUP_HIT       = 3'd2;
    localparam [2:0] LOOKUP_MERGE     = 3'd3;
    localparam [2:0] LOOKUP_ALLOC     = 3'd4;
    localparam [2:0] LOOKUP_BYPASS    = 3'd5;
    localparam [2:0] LOOKUP_WRITE_AROUND = 3'd6;
    localparam [2:0] LOOKUP_VICTIM_HIT = 3'd7;

    reg [WAYS-1:0] valid_q [0:SETS-1];
    reg [WAYS-1:0] dirty_q [0:SETS-1];
    // Dirty data is tracked at byte granularity.  A resident line always has
    // complete data, so its eventual eviction may update only the bytes that
    // changed instead of rewriting all 64 bytes.
    reg [WAYS*`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
        dirty_strb_q [0:SETS-1];
    reg [WAYS-1:0] reserved_q [0:SETS-1];
    reg [WAY_INDEX_WIDTH-1:0] replace_q [0:SETS-1];
    reg [PTE_GENERATION_BITS-1:0] pte_generation_q;
    wire [WAYS*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] sram_way_data;
    wire [WAYS*SRAM_TAG_BITS-1:0] sram_way_tag;
    reg sram_write_valid_r;
    reg [SET_INDEX_WIDTH-1:0] sram_write_set_r;
    reg [WAY_INDEX_WIDTH-1:0] sram_write_way_r;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] sram_write_data_r;
    reg sram_write_tag_r;
    reg [SRAM_TAG_BITS-1:0] sram_write_tag_data_r;
    wire lookup_sram_write_blocked;

    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        cmd_hart_id_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        cmd_txn_id_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        cmd_source_id_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_CCX_OP_WIDTH-1:0]
        cmd_op_q [0:COMMAND_ENTRIES-1];
    reg cmd_lock_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_CCX_ORDER_WIDTH-1:0]
        cmd_order_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_CCX_KIND_WIDTH-1:0]
        cmd_kind_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_CCX_ATTR_WIDTH-1:0]
        cmd_attr_q [0:COMMAND_ENTRIES-1];
    reg [2:0] cmd_size_q [0:COMMAND_ENTRIES-1];
    reg [63:0] cmd_addr_q [0:COMMAND_ENTRIES-1];
    reg [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
        cmd_burst_len_q [0:COMMAND_ENTRIES-1];
    reg [COMMAND_INDEX_WIDTH-1:0] cmd_head_q;
    reg [COMMAND_INDEX_WIDTH-1:0] cmd_tail_q;
    reg [COMMAND_COUNT_WIDTH-1:0] cmd_count_q;
    reg [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] cmd_beat_q;
    reg cmd_wdata_valid_q;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] cmd_wdata_q;
    reg [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] cmd_wstrb_q;
    reg cmd_wdata_error_q;

    reg lookup_valid_q;
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] lookup_hart_id_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] lookup_txn_id_q;
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] lookup_source_id_q;
    reg [`OPENRV64_CCX_OP_WIDTH-1:0] lookup_op_q;
    reg lookup_lock_q;
    reg [`OPENRV64_CCX_ORDER_WIDTH-1:0] lookup_order_q;
    reg [`OPENRV64_CCX_KIND_WIDTH-1:0] lookup_kind_q;
    reg [`OPENRV64_CCX_ATTR_WIDTH-1:0] lookup_attr_q;
    reg [2:0] lookup_size_q;
    reg [63:0] lookup_addr_q;
    reg [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] lookup_beat_q;
    reg lookup_last_q;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] lookup_wdata_q;
    reg [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] lookup_wstrb_q;
    reg lookup_protocol_error_q;

    reg hit_valid_q;
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] hit_hart_id_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] hit_txn_id_q;
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] hit_source_id_q;
    reg [`OPENRV64_CCX_OP_WIDTH-1:0] hit_op_q;
    reg hit_lock_q;
    reg [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] hit_beat_q;
    reg hit_last_q;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] hit_data_q;
    reg hit_error_q;
    reg hit_sc_success_q;

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
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        mshr_victim_data_q [0:MSHR_ENTRIES-1];
    reg [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
        mshr_victim_strb_q [0:MSHR_ENTRIES-1];
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        mshr_replay_data_q [0:MSHR_ENTRIES-1];
    reg [WAITER_COUNT_WIDTH-1:0] mshr_waiter_count_q [0:MSHR_ENTRIES-1];
    reg [WAITER_INDEX_WIDTH-1:0] mshr_replay_q [0:MSHR_ENTRIES-1];
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        mshr_bypass_data_q [0:MSHR_ENTRIES-1];
    reg mshr_bus_cacheable_q [0:MSHR_ENTRIES-1];
    reg mshr_error_q [0:MSHR_ENTRIES-1];

    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        waiter_hart_id_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        waiter_txn_id_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        waiter_source_id_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_CCX_OP_WIDTH-1:0]
        waiter_op_q [0:TOTAL_WAITERS-1];
    reg waiter_lock_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_CCX_ORDER_WIDTH-1:0]
        waiter_order_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_CCX_KIND_WIDTH-1:0]
        waiter_kind_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_CCX_ATTR_WIDTH-1:0]
        waiter_attr_q [0:TOTAL_WAITERS-1];
    reg [2:0] waiter_size_q [0:TOTAL_WAITERS-1];
    reg [63:0] waiter_addr_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
        waiter_beat_q [0:TOTAL_WAITERS-1];
    reg waiter_last_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        waiter_wdata_q [0:TOTAL_WAITERS-1];
    reg [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
        waiter_wstrb_q [0:TOTAL_WAITERS-1];

    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        response_hart_id_q [0:RESPONSE_ENTRIES-1];
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        response_txn_id_q [0:RESPONSE_ENTRIES-1];
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
        response_source_id_q [0:RESPONSE_ENTRIES-1];
    reg [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
        response_beat_q [0:RESPONSE_ENTRIES-1];
    reg response_last_q [0:RESPONSE_ENTRIES-1];
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        response_data_q [0:RESPONSE_ENTRIES-1];
    reg response_error_q [0:RESPONSE_ENTRIES-1];
    reg response_sc_success_q [0:RESPONSE_ENTRIES-1];
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
    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] lock_hart_id_q;
    reg [63:0] lock_line_addr_q;

    integer reset_index;
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
    reg [2:0] lookup_action_r;
    reg lookup_dispatch_r;
    reg bus_candidate_found_r;
    reg [MSHR_INDEX_WIDTH-1:0] bus_candidate_mshr_r;
    reg [1:0] bus_candidate_action_r;
    reg replay_candidate_found_r;
    reg [MSHR_INDEX_WIDTH-1:0] replay_candidate_mshr_r;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] lookup_write_data_r;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] replay_write_data_r;

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
        cmd_op_q[cmd_head_q] == `OPENRV64_CCX_OP_WRITE;
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
    wire cmd_head_protocol_error =
        ((cmd_op_q[cmd_head_q] != `OPENRV64_CCX_OP_READ) &&
         (cmd_op_q[cmd_head_q] != `OPENRV64_CCX_OP_WRITE) &&
         (cmd_op_q[cmd_head_q] != `OPENRV64_CCX_OP_FENCE)) ||
        ((cmd_burst_len_q[cmd_head_q] != 0) && !cmd_head_line) ||
        (cmd_head_line &&
         (cmd_addr_q[cmd_head_q][LINE_OFFSET_BITS-1:0] != 0)) ||
        (!cmd_head_line && (cmd_size_q[cmd_head_q] > 3'd3)) ||
        (cmd_lock_q[cmd_head_q] &&
         (cmd_head_line || (cmd_burst_len_q[cmd_head_q] != 0)));
    wire wdata_identity_match =
        (wdata_hart_id_i == cmd_hart_id_q[cmd_head_q]) &&
        (wdata_txn_id_i == cmd_txn_id_q[cmd_head_q]) &&
        (wdata_source_id_i == cmd_source_id_q[cmd_head_q]) &&
        (wdata_beat_index_i == cmd_beat_q);
    assign wdata_ready_o = (cmd_count_q != 0) && cmd_head_write &&
                           !cmd_wdata_valid_q && wdata_identity_match;
    wire wdata_fire = wdata_valid_i && wdata_ready_o;

    wire response_dequeue = resp_valid_o && resp_ready_i;
    wire response_space =
        (response_count_q < RESPONSE_COUNT_WIDTH'(RESPONSE_ENTRIES)) ||
        response_dequeue;
    wire hit_enqueue = hit_valid_q && response_space;
    wire hit_slot_ready = !hit_valid_q || hit_enqueue;

    wire lookup_cacheable =
        |(lookup_attr_q & `OPENRV64_CCX_ATTR_CACHEABLE) &&
        !(|(lookup_attr_q & `OPENRV64_CCX_ATTR_DEVICE));
    wire [63:0] lookup_line_addr =
        {lookup_addr_q[63:LINE_OFFSET_BITS], {LINE_OFFSET_BITS{1'b0}}};
    wire [SET_INDEX_WIDTH-1:0] lookup_set =
        lookup_addr_q[LINE_OFFSET_BITS +: SET_INDEX_WIDTH];
    wire [TAG_BITS-1:0] lookup_tag =
        lookup_addr_q[ADDR_WIDTH-1:LINE_OFFSET_BITS + SET_BITS];
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] lookup_hit_data =
        sram_way_data[
            lookup_hit_way_r*`OPENRV64_CCX_LINE_DATA_WIDTH +:
            `OPENRV64_CCX_LINE_DATA_WIDTH];
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] lookup_shifted_data =
        lookup_hit_data >> (lookup_addr_q[5:3] * 64);
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] lookup_read_data =
        (lookup_size_q == 3'd6) ? lookup_hit_data :
            ({{448{1'b0}}, lookup_shifted_data[63:0]} <<
             (lookup_addr_q[5:3] * 64));
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        lookup_dirty_victim_data =
            mshr_victim_data_q[lookup_dirty_victim_index_r];
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        lookup_dirty_victim_shifted_data =
            lookup_dirty_victim_data >> (lookup_addr_q[5:3] * 64);
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        lookup_dirty_victim_read_data =
            (lookup_size_q == 3'd6) ? lookup_dirty_victim_data :
            ({{448{1'b0}},
              lookup_dirty_victim_shifted_data[63:0]} <<
             (lookup_addr_q[5:3] * 64));
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] lookup_victim_data =
        sram_way_data[
            victim_way_r*`OPENRV64_CCX_LINE_DATA_WIDTH +:
            `OPENRV64_CCX_LINE_DATA_WIDTH];
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
        lookup_kind_q == `OPENRV64_CCX_KIND_PTE;

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
                !mshr_bypass_q[lookup_mshr_scan] &&
                (mshr_line_addr_q[lookup_mshr_scan] ==
                 lookup_line_addr)) begin
                lookup_mshr_match_r = 1'b1;
                lookup_mshr_index_r =
                    lookup_mshr_scan[MSHR_INDEX_WIDTH-1:0];
                lookup_mshr_mergeable_r =
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
        lookup_action_r = LOOKUP_NONE;
        lookup_dispatch_r = 1'b0;
        if (lookup_valid_q) begin
            if (lookup_protocol_error_q) begin
                if (hit_slot_ready) begin
                    lookup_action_r = LOOKUP_IMMEDIATE;
                    lookup_dispatch_r = 1'b1;
                end
            end else if (lookup_op_q == `OPENRV64_CCX_OP_FENCE) begin
                if (fence_drain_complete && hit_slot_ready) begin
                    lookup_action_r = LOOKUP_IMMEDIATE;
                    lookup_dispatch_r = 1'b1;
                end
            end else if (!lookup_cacheable) begin
                if (mshr_free_found_r) begin
                    lookup_action_r = LOOKUP_BYPASS;
                    lookup_dispatch_r = 1'b1;
                end
            end else if (lookup_mshr_match_r) begin
                if (lookup_mshr_mergeable_r) begin
                    lookup_action_r = LOOKUP_MERGE;
                    lookup_dispatch_r = 1'b1;
                end
            end else if (lookup_dirty_victim_match_r) begin
                // Reads consume the complete dirty victim snapshot.  A write
                // waits for writeback completion because data already sent
                // below this cache cannot be modified safely.
                if ((lookup_op_q == `OPENRV64_CCX_OP_READ) &&
                    hit_slot_ready) begin
                    lookup_action_r = LOOKUP_VICTIM_HIT;
                    lookup_dispatch_r = 1'b1;
                end
            end else if (lookup_hit_r) begin
                if (hit_slot_ready &&
                    ((lookup_op_q != `OPENRV64_CCX_OP_WRITE) ||
                     !lookup_sram_write_blocked)) begin
                    lookup_action_r = LOOKUP_HIT;
                    lookup_dispatch_r = 1'b1;
                end
            end else if ((lookup_op_q == `OPENRV64_CCX_OP_WRITE) &&
                         mshr_free_found_r) begin
                // A write miss needs no read-for-ownership.  Preserve its
                // byte enables and let the backing memory merge the partial
                // line.  Resident writes still merge into the L2 SRAM above.
                lookup_action_r = LOOKUP_WRITE_AROUND;
                lookup_dispatch_r = 1'b1;
            end else if (mshr_free_found_r && victim_found_r) begin
                lookup_action_r = LOOKUP_ALLOC;
                lookup_dispatch_r = 1'b1;
            end
        end
    end

    wire lookup_stage_ready = !lookup_valid_q || lookup_dispatch_r;
    wire [31:0] lookup_merge_waiter_index =
        32'(lookup_mshr_index_r) * WAITERS_PER_MSHR +
        32'(mshr_waiter_count_q[lookup_mshr_index_r]);
    wire [31:0] lookup_alloc_waiter_index =
        32'(mshr_free_index_r) * WAITERS_PER_MSHR;
    wire command_source_valid =
        (cmd_count_q != 0) && (!cmd_head_write || cmd_wdata_valid_q);
    wire lookup_capture = command_source_valid && lookup_stage_ready;
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
                    waiter_op_q[bus_waiter_index] ==
                    `OPENRV64_CCX_OP_WRITE;
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

    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] replay_hart_id =
        waiter_hart_id_q[replay_waiter_index];
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] replay_txn_id =
        waiter_txn_id_q[replay_waiter_index];
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] replay_source_id =
        waiter_source_id_q[replay_waiter_index];
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] replay_op =
        waiter_op_q[replay_waiter_index];
    wire replay_lock = waiter_lock_q[replay_waiter_index];
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] replay_beat =
        waiter_beat_q[replay_waiter_index];
    wire replay_last = waiter_last_q[replay_waiter_index];
    wire replay_error =
        (mshr_state_q[replay_mshr] == MSHR_ERROR) ||
        mshr_error_q[replay_mshr];
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] replay_shifted_data =
        mshr_replay_data_q[replay_mshr] >>
        (waiter_addr_q[replay_waiter_index][5:3] * 64);
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] replay_cache_read_data =
        (waiter_size_q[replay_waiter_index] == 3'd6) ?
            mshr_replay_data_q[replay_mshr] :
            ({{448{1'b0}}, replay_shifted_data[63:0]} <<
             (waiter_addr_q[replay_waiter_index][5:3] * 64));
    wire fill_sram_write = bus_response_fire &&
        (bus_response_action == BUS_ACTION_FILL) && !bus_resp_error_i;
    wire replay_needs_sram_write = replay_candidate_found_r &&
        !replay_error && !mshr_bypass_q[replay_mshr] &&
        (replay_op == `OPENRV64_CCX_OP_WRITE);
    wire replay_enqueue = replay_candidate_found_r && response_space &&
        !hit_valid_q && (!replay_needs_sram_write || !fill_sram_write);
    wire response_enqueue = hit_enqueue || replay_enqueue;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] replay_data =
        replay_error ? 512'd0 :
        mshr_bypass_q[replay_mshr] ?
            ((replay_op == `OPENRV64_CCX_OP_READ) ?
             mshr_bypass_data_q[replay_mshr] : 512'd0) :
            ((replay_op == `OPENRV64_CCX_OP_READ) ?
             replay_cache_read_data :
             512'd0);
    wire replay_cache_write = replay_enqueue && !replay_error &&
        !mshr_bypass_q[replay_mshr] &&
        (replay_op == `OPENRV64_CCX_OP_WRITE);

    always @* begin
        lookup_write_data_r = lookup_hit_data;
        for (lookup_write_byte = 0;
             lookup_write_byte < `OPENRV64_CCX_LINE_STRB_WIDTH;
             lookup_write_byte = lookup_write_byte + 1)
            if (lookup_wstrb_q[lookup_write_byte])
                lookup_write_data_r[8*lookup_write_byte +: 8] =
                    lookup_wdata_q[8*lookup_write_byte +: 8];

        replay_write_data_r = mshr_replay_data_q[replay_mshr];
        for (replay_write_byte = 0;
             replay_write_byte < `OPENRV64_CCX_LINE_STRB_WIDTH;
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
        (lookup_op_q == `OPENRV64_CCX_OP_FENCE) &&
        (lookup_kind_q == `OPENRV64_CCX_KIND_PTE);

    // The eight data and tag banks each have one synchronous read port and one
    // full-line write port.  Fill has priority over replay, which has priority
    // over a resident write hit; the lower-priority pipeline stage stalls.
    always @* begin
        sram_write_valid_r = 1'b0;
        sram_write_set_r = 0;
        sram_write_way_r = 0;
        sram_write_data_r = 0;
        sram_write_tag_r = 1'b0;
        sram_write_tag_data_r = 0;

        if (fill_sram_write) begin
            sram_write_valid_r = 1'b1;
            sram_write_set_r = mshr_set_q[bus_response_mshr];
            sram_write_way_r = mshr_way_q[bus_response_mshr];
            sram_write_data_r = bus_resp_rdata_i;
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
        end else if (lookup_dispatch_r &&
                     (lookup_action_r == LOOKUP_HIT) &&
                     (lookup_op_q == `OPENRV64_CCX_OP_WRITE)) begin
            sram_write_valid_r = 1'b1;
            sram_write_set_r = lookup_set;
            sram_write_way_r = lookup_hit_way_r;
            sram_write_data_r = lookup_write_data_r;
        end
    end

    genvar sram_way;
    generate
        for (sram_way = 0; sram_way < WAYS;
             sram_way = sram_way + 1) begin : g_l2_sram_way
            openrv64_l2_sram_way #(
                .SETS(SETS),
                .SET_INDEX_WIDTH(SET_INDEX_WIDTH),
                .DATA_WIDTH(`OPENRV64_CCX_LINE_DATA_WIDTH),
                .TAG_WIDTH(SRAM_TAG_BITS)
            ) u_sram (
                .clk_i(clk_i),
                .read_enable_i(lookup_sram_read),
                .read_set_i(lookup_sram_read_set),
                .read_data_o(sram_way_data[
                    sram_way*`OPENRV64_CCX_LINE_DATA_WIDTH +:
                    `OPENRV64_CCX_LINE_DATA_WIDTH]),
                .read_tag_o(sram_way_tag[
                    sram_way*SRAM_TAG_BITS +: SRAM_TAG_BITS]),
                .write_enable_i(sram_write_valid_r &&
                    (sram_write_way_r == WAY_INDEX_WIDTH'(sram_way))),
                .write_set_i(sram_write_set_r),
                .write_data_i(sram_write_data_r),
                .write_tag_i(sram_write_tag_r),
                .write_tag_data_i(sram_write_tag_data_r)
            );
        end
    endgenerate

    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] enqueue_hart_id =
        hit_enqueue ? hit_hart_id_q : replay_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] enqueue_txn_id =
        hit_enqueue ? hit_txn_id_q : replay_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] enqueue_source_id =
        hit_enqueue ? hit_source_id_q : replay_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] enqueue_op =
        hit_enqueue ? hit_op_q : replay_op;
    wire enqueue_lock = hit_enqueue ? hit_lock_q : replay_lock;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] enqueue_beat =
        hit_enqueue ? hit_beat_q : replay_beat;
    wire enqueue_last = hit_enqueue ? hit_last_q : replay_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] enqueue_data =
        hit_enqueue ? hit_data_q : replay_data;
    wire enqueue_error = hit_enqueue ? hit_error_q : replay_error;
    wire enqueue_sc_success =
        hit_enqueue ? hit_sc_success_q : 1'b0;

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
            cmd_wdata_valid_q <= 1'b0;
            cmd_wdata_q <= 0;
            cmd_wstrb_q <= 0;
            cmd_wdata_error_q <= 1'b0;
            lookup_valid_q <= 1'b0;
            hit_valid_q <= 1'b0;
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
            for (set_reset_index = 0; set_reset_index < SETS;
                 set_reset_index = set_reset_index + 1) begin
                valid_q[set_reset_index] <= 0;
                dirty_q[set_reset_index] <= 0;
                dirty_strb_q[set_reset_index] <= 0;
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
                mshr_pte_generation_q[reset_index] <= 0;
                mshr_bus_cacheable_q[reset_index] <= 1'b0;
                mshr_victim_strb_q[reset_index] <= 0;
            end
        end else begin
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
                if (cmd_tail_q ==
                    COMMAND_INDEX_WIDTH'(COMMAND_ENTRIES - 1))
                    cmd_tail_q <= 0;
                else
                    cmd_tail_q <= cmd_tail_q + 1'b1;
                if (req_lock_i && !lock_active_q &&
                    (req_op_i == `OPENRV64_CCX_OP_READ)) begin
                    lock_active_q <= 1'b1;
                    lock_hart_id_q <= req_hart_id_i;
                    lock_line_addr_q <= incoming_line_addr;
                end
            end

            if (wdata_fire) begin
                cmd_wdata_valid_q <= 1'b1;
                cmd_wdata_q <= wdata_i;
                cmd_wstrb_q <= wstrb_i;
                cmd_wdata_error_q <=
                    (wdata_last_i != cmd_head_last);
            end

            if (command_advance)
                cmd_beat_q <= cmd_beat_q + 1'b1;
            if (command_pop) begin
                cmd_beat_q <= 0;
                if (cmd_head_q ==
                    COMMAND_INDEX_WIDTH'(COMMAND_ENTRIES - 1))
                    cmd_head_q <= 0;
                else
                    cmd_head_q <= cmd_head_q + 1'b1;
            end
            if (lookup_capture && cmd_head_write) begin
                cmd_wdata_valid_q <= 1'b0;
                cmd_wdata_error_q <= 1'b0;
            end

            case ({command_push, command_pop})
                2'b10: cmd_count_q <= cmd_count_q + 1'b1;
                2'b01: cmd_count_q <= cmd_count_q - 1'b1;
                default: cmd_count_q <= cmd_count_q;
            endcase

            if (lookup_capture) begin
                lookup_valid_q <= 1'b1;
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
                lookup_wdata_q <= cmd_wdata_q;
                lookup_wstrb_q <= cmd_wstrb_q;
                lookup_protocol_error_q <= cmd_head_protocol_error |
                                           cmd_wdata_error_q;
            end else if (lookup_dispatch_r) begin
                lookup_valid_q <= 1'b0;
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
                hit_error_q <= lookup_protocol_error_q;
                hit_sc_success_q <= 1'b0;
                if ((lookup_action_r == LOOKUP_HIT) &&
                    (lookup_op_q == `OPENRV64_CCX_OP_READ))
                    hit_data_q <= lookup_read_data;
                else if ((lookup_action_r == LOOKUP_VICTIM_HIT) &&
                         (lookup_op_q == `OPENRV64_CCX_OP_READ))
                    hit_data_q <= lookup_dirty_victim_read_data;
                else
                    hit_data_q <= 0;

                if ((lookup_action_r == LOOKUP_HIT) &&
                    (lookup_op_q == `OPENRV64_CCX_OP_WRITE)) begin
                    dirty_q[lookup_set][lookup_hit_way_r] <= 1'b1;
                    dirty_strb_q[lookup_set][
                        lookup_hit_way_r*
                        `OPENRV64_CCX_LINE_STRB_WIDTH +:
                        `OPENRV64_CCX_LINE_STRB_WIDTH] <=
                        dirty_strb_q[lookup_set][
                            lookup_hit_way_r*
                            `OPENRV64_CCX_LINE_STRB_WIDTH +:
                            `OPENRV64_CCX_LINE_STRB_WIDTH] |
                        lookup_wstrb_q;
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
            end

            if (lookup_dispatch_r &&
                ((lookup_action_r == LOOKUP_ALLOC) ||
                 (lookup_action_r == LOOKUP_BYPASS) ||
                 (lookup_action_r == LOOKUP_WRITE_AROUND))) begin
                mshr_valid_q[mshr_free_index_r] <= 1'b1;
                mshr_bypass_q[mshr_free_index_r] <=
                    (lookup_action_r != LOOKUP_ALLOC);
                mshr_bus_cacheable_q[mshr_free_index_r] <=
                    lookup_cacheable;
                mshr_line_addr_q[mshr_free_index_r] <= lookup_line_addr;
                mshr_waiter_count_q[mshr_free_index_r] <= 1;
                mshr_replay_q[mshr_free_index_r] <= 0;
                mshr_error_q[mshr_free_index_r] <= 1'b0;
                if (lookup_action_r != LOOKUP_ALLOC) begin
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
                        dirty_strb_q[lookup_set][
                            victim_way_r*
                            `OPENRV64_CCX_LINE_STRB_WIDTH +:
                            `OPENRV64_CCX_LINE_STRB_WIDTH];
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
                        dirty_strb_q[mshr_set_q[bus_response_mshr]][
                            mshr_way_q[bus_response_mshr]*
                            `OPENRV64_CCX_LINE_STRB_WIDTH +:
                            `OPENRV64_CCX_LINE_STRB_WIDTH] <= 0;
                        mshr_state_q[bus_response_mshr] <= MSHR_NEED_FILL;
                    end
                end else if (bus_response_action == BUS_ACTION_FILL) begin
                    if (bus_resp_error_i) begin
                        mshr_error_q[bus_response_mshr] <= 1'b1;
                        mshr_state_q[bus_response_mshr] <= MSHR_ERROR;
                    end else begin
                        mshr_replay_data_q[bus_response_mshr] <=
                            bus_resp_rdata_i;
                        valid_q[mshr_set_q[bus_response_mshr]]
                               [mshr_way_q[bus_response_mshr]] <= 1'b1;
                        dirty_q[mshr_set_q[bus_response_mshr]]
                               [mshr_way_q[bus_response_mshr]] <= 1'b0;
                        dirty_strb_q[mshr_set_q[bus_response_mshr]][
                            mshr_way_q[bus_response_mshr]*
                            `OPENRV64_CCX_LINE_STRB_WIDTH +:
                            `OPENRV64_CCX_LINE_STRB_WIDTH] <= 0;
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
                dirty_q[mshr_set_q[replay_mshr]]
                       [mshr_way_q[replay_mshr]] <= 1'b1;
                dirty_strb_q[mshr_set_q[replay_mshr]][
                    mshr_way_q[replay_mshr]*
                    `OPENRV64_CCX_LINE_STRB_WIDTH +:
                    `OPENRV64_CCX_LINE_STRB_WIDTH] <=
                    dirty_strb_q[mshr_set_q[replay_mshr]][
                        mshr_way_q[replay_mshr]*
                        `OPENRV64_CCX_LINE_STRB_WIDTH +:
                        `OPENRV64_CCX_LINE_STRB_WIDTH] |
                    waiter_wstrb_q[replay_waiter_index];
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
                if (response_tail_q ==
                    RESPONSE_INDEX_WIDTH'(RESPONSE_ENTRIES - 1))
                    response_tail_q <= 0;
                else
                    response_tail_q <= response_tail_q + 1'b1;
            end
            if (response_dequeue) begin
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
                ((enqueue_op == `OPENRV64_CCX_OP_WRITE) ||
                 enqueue_error) &&
                (enqueue_hart_id == lock_hart_id_q))
                lock_active_q <= 1'b0;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (rst_ni && command_push && req_lock_i && !lock_active_q &&
            (req_op_i != `OPENRV64_CCX_OP_READ))
            $fatal(1, "native L2 lock sequence must begin with READ");
        if (rst_ni && command_push && req_lock_i &&
            ((req_size_i == 3'd6) || (req_burst_len_i != 0)))
            $fatal(1, "native L2 lock is valid only for scalar operations");
        if (rst_ni && (cmd_count_q != 0) && cmd_head_write &&
            wdata_valid_i && !wdata_identity_match)
            $fatal(1, "native L2 write-data identity mismatch");
        if (rst_ni && bus_request_fire &&
            (bus_candidate_action_r != BUS_ACTION_BYPASS) &&
            ((bus_req_size_o != 3'd6) ||
             (bus_req_addr_o[LINE_OFFSET_BITS-1:0] != 0)))
            $fatal(1, "native L2 emitted a non-line cache bus request");
    end

    initial begin
        if ((ADDR_WIDTH < 32) || (ADDR_WIDTH > 64))
            $fatal(1, "native L2 address width must be 32 through 64");
        if (LINE_BYTES != `OPENRV64_CCX_LINE_BYTES)
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
