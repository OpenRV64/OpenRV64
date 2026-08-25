`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/bus/bus-defs.v"
`include "soc/bus/mem_map.v"

// Native 512-bit data-cache endpoint for the core-complex protocol.
//
// The shared L1 controller still writes its SRAM a 64-bit word per cycle.
// This wrapper converts one cacheable miss into one 64-byte ICX read, buffers
// the returned line, and supplies its eight words to that internal refill
// port.  Scalar write-through and uncached operations remain sub-line ICX
// commands but are lane-positioned on the same 512-bit datapath.
module openrv64_l1d_icx #(
    parameter integer ENABLE = 1,
    parameter integer ADDR_WIDTH = 64,
    parameter integer CACHE_BYTES = 16 * 1024,
    parameter integer LINE_BYTES = 64,
    parameter integer WAYS = 8,
    parameter integer SYNC_TAG_LOOKUP = 1,
    parameter integer SYNC_STORE_EXTENSION = 1,
    parameter integer FILL_BUFFER_LINES = 8,
    parameter integer DEMAND_MSHRS = 3,
    parameter integer STORE_BUFFER_LINES = 8,
    parameter integer STORE_BUFFER_DRAIN_WATERMARK =
        (STORE_BUFFER_LINES < 4) ? STORE_BUFFER_LINES : 4,
    parameter integer STORE_BUFFER_TIMEOUT_CYCLES = 1024,
    parameter integer PREFETCH_ENABLE = 1,
    parameter [ADDR_WIDTH-1:0] PREFETCH_CACHEABLE_BASE =
        {ADDR_WIDTH{1'b0}},
    parameter [ADDR_WIDTH-1:0] PREFETCH_CACHEABLE_SIZE =
        {ADDR_WIDTH{1'b1}},
    parameter integer PREFETCH_MAX_STRIDE_LINES = 64,
    parameter integer PREFETCH_STREAMS = 2,
    parameter integer PREFETCH_DISTANCE = 1,
    parameter integer PREFETCH_ADAPTIVE_ENABLE = 1,
    parameter integer PREFETCH_MAX_DISTANCE = 4,
    parameter integer PREFETCH_QUEUE_LINES = 4,
    parameter integer PREFETCH_OUTSTANDING = 4,
    parameter integer PREFETCH_DEMAND_RESERVE = 2,
    // 0: unrestricted, 1: 4 KiB probation, 2: 64 KiB probation.
    parameter integer PREFETCH_PAGE_GATING = 1,
    parameter integer ATOMIC_HOT_LINES = 16,
    parameter integer COHERENT_ATOMICS = 0,
    parameter integer SPECULATION_EPOCH_WIDTH = 8,
    // Simulation-only upper-bound mode. Cacheable, unlocked demand loads
    // complete from the testbench RAM oracle at a fixed MEM-issue-to-result
    // latency. The surrounding MEM lane contributes two registered crossings,
    // so three cycles selects the L1D's one-cycle response path.
    // Stores and all architecturally sensitive traffic retain the real path.
    parameter integer FREELOADER = 0,
    parameter integer FREELOADER_LATENCY = 3,
    parameter integer REQ_TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH,
    parameter integer REQ_DEPTH = `OPENRV64_LSU_OUTSTANDING,
    parameter integer WRITEBACK_TIMEOUT_CYCLES = 128,
    parameter integer DIRTY_TIMESTAMP_WIDTH =
        (WRITEBACK_TIMEOUT_CYCLES < 2) ? 1 :
        $clog2(WRITEBACK_TIMEOUT_CYCLES + 1),
    parameter [`OPENRV64_ICX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}}
) (
    input  wire                      clk_i,
    input  wire                      rst_ni,

    input  wire                      req_valid_i,
    output wire                      req_ready_o,
    input  wire [REQ_TAG_WIDTH-1:0]  req_tag_i,
    input  wire                      req_lock_i,
    input  wire                      req_posted_i,
    input  wire                      req_write_i,
    input  wire                      req_cacheable_i,
    input  wire [ADDR_WIDTH-1:0]     req_addr_i,
    input  wire [2:0]                req_size_i,
    input  wire [63:0]               req_wdata_i,
    input  wire [7:0]                req_wstrb_i,
    output wire [63:0]               req_rdata_o,
    output wire                      req_error_o,
    output wire                      resp_valid_o,
    input  wire                      resp_ready_i,
    output wire [REQ_TAG_WIDTH-1:0]  resp_tag_o,

    // Original-tag completion when a posted store enters the byte-masked
    // line FIFO.  This is independent of the normal load response channel.
    output wire                      posted_resp_valid_o,
    input  wire                      posted_resp_ready_i,
    output wire [REQ_TAG_WIDTH-1:0]  posted_resp_tag_o,

    // Ordered lower-level completion of the oldest coalesced store-buffer
    // line.  Coalescing means this event has no original requester tag.
    output wire                      store_resp_valid_o,
    input  wire                      store_resp_ready_i,
    output wire                      store_resp_error_o,
    output wire                      prefetch_issued_o,
    output wire                      prefetch_useful_o,
    output wire                      prefetch_late_o,
    output wire                      prefetch_dropped_o,
    output wire                      prefetch_useless_o,
    output wire [4:0]                prefetch_depth_o,

    // A translation or other architectural speculation barrier advances the
    // read epoch. Speculative reads from an older epoch are consumed and
    // discarded; an architectural read miss is consumed and reissued.
    input  wire                      speculation_barrier_i,
    // Ordinary FENCE additionally requires an acknowledged ICX/L2 fence after
    // the local drain. Translation barriers leave this low because their PTW
    // path issues the generation-changing fence after this drain completes.
    input  wire                      completion_fence_i,
    // Every barrier forces older posted stores through their ICX responses.
    // Busy covers the initiating cycle and, when completion_fence_i is set,
    // remains asserted until the explicit ICX fence response returns.
    output wire                      store_barrier_busy_o,

    input  wire                      invalidate_valid_i,
    output wire                      invalidate_ready_o,
    output wire                      invalidate_hit_o,
    output wire                      quiescent_o,
    input  wire                      invalidate_all_i,
    input  wire [ADDR_WIDTH-1:0]     invalidate_addr_i,

    output wire                      icx_req_valid_o,
    input  wire                      icx_req_ready_i,
    output wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                     icx_req_hart_id_o,
    output wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                     icx_req_txn_id_o,
    output wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                     icx_req_source_id_o,
    output wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op_o,
    output wire                      icx_req_lock_o,
    output wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order_o,
    output wire [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind_o,
    output wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr_o,
    output wire [2:0]                icx_req_size_o,
    output wire [63:0]               icx_req_addr_o,
    output wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
                                     icx_req_burst_len_o,

    output wire                      icx_wdata_valid_o,
    input  wire                      icx_wdata_ready_i,
    output wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                     icx_wdata_hart_id_o,
    output wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                     icx_wdata_txn_id_o,
    output wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                     icx_wdata_source_id_o,
    output wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
                                     icx_wdata_beat_index_o,
    output wire                      icx_wdata_last_o,
    output wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
                                     icx_wdata_o,
    output wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
                                     icx_wstrb_o,

    input  wire                      icx_resp_valid_i,
    output wire                      icx_resp_ready_o,
    input  wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                     icx_resp_hart_id_i,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                     icx_resp_txn_id_i,
    input  wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                     icx_resp_source_id_i,
    input  wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
                                     icx_resp_beat_index_i,
    input  wire                      icx_resp_last_i,
    input  wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
                                     icx_resp_rdata_i,
    input  wire                      icx_resp_error_i,
    input  wire                      icx_resp_sc_success_i
);

    localparam [1:0] BACKEND_IDLE = 2'd0;
    localparam [1:0] BACKEND_SEND = 2'd1;
    localparam [1:0] BACKEND_WAIT = 2'd2;
    localparam integer FILL_BUFFER_INDEX_WIDTH =
        (FILL_BUFFER_LINES > 1) ? $clog2(FILL_BUFFER_LINES) : 1;
    localparam integer STORE_BUFFER_INDEX_WIDTH =
        (STORE_BUFFER_LINES > 1) ? $clog2(STORE_BUFFER_LINES) : 1;
    localparam integer STORE_BUFFER_COUNT_WIDTH =
        $clog2(STORE_BUFFER_LINES + 1);
    localparam integer STORE_BUFFER_AGE_WIDTH =
        (STORE_BUFFER_TIMEOUT_CYCLES > 1) ?
        $clog2(STORE_BUFFER_TIMEOUT_CYCLES) : 1;
    localparam [STORE_BUFFER_AGE_WIDTH-1:0]
        STORE_BUFFER_TIMEOUT_LAST =
            STORE_BUFFER_AGE_WIDTH'(STORE_BUFFER_TIMEOUT_CYCLES - 1);
    localparam integer PREFETCH_QUEUE_INDEX_WIDTH =
        (PREFETCH_QUEUE_LINES > 1) ? $clog2(PREFETCH_QUEUE_LINES) : 1;
    localparam integer PREFETCH_STREAM_INDEX_WIDTH =
        (PREFETCH_STREAMS > 1) ? $clog2(PREFETCH_STREAMS) : 1;
    localparam integer PREFETCH_MSHR_INDEX_WIDTH =
        (PREFETCH_OUTSTANDING > 1) ? $clog2(PREFETCH_OUTSTANDING) : 1;
    localparam integer DEMAND_MSHR_INDEX_WIDTH =
        (DEMAND_MSHRS > 1) ? $clog2(DEMAND_MSHRS) : 1;
    localparam integer DEMAND_WAITER_COUNT = 1 << REQ_TAG_WIDTH;
    // The LSU tag is deliberately small and may be recycled immediately
    // after a response. Carry a separate epoch through the synchronous L1
    // lookup so line-sized dirty-overlay state cannot be selected by numeric
    // tag alone. The epoch is not relied upon to avoid wrap: matching bypass
    // ownership is cleared when its response is consumed.
    localparam integer TAG_OVERLAY_EPOCH_WIDTH = 4;
    localparam integer L1_REQ_TAG_WIDTH =
        REQ_TAG_WIDTH + TAG_OVERLAY_EPOCH_WIDTH;
    localparam integer PREFETCH_WINDOW_INDEX_WIDTH =
        (PREFETCH_MAX_DISTANCE > 1) ?
        $clog2(PREFETCH_MAX_DISTANCE) : 1;
    localparam integer ATOMIC_HOT_INDEX_WIDTH =
        (ATOMIC_HOT_LINES > 1) ? $clog2(ATOMIC_HOT_LINES) : 1;
    localparam integer TOTAL_TXN_COUNT =
        1 << `OPENRV64_ICX_TXN_ID_WIDTH;
    // Reserve exactly the IDs which the prefetch MSHRs can occupy.  The old
    // MSB split reserved eight of sixteen IDs even though this configuration
    // has only four prefetch MSHRs, leaving IDs 12 through 15 unusable while
    // demand and store traffic contended for the lower eight.
    localparam integer MAIN_TXN_COUNT =
        TOTAL_TXN_COUNT - PREFETCH_OUTSTANDING;
    localparam [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] PREFETCH_TXN_BASE =
        `OPENRV64_ICX_TXN_ID_WIDTH'(MAIN_TXN_COUNT);
    localparam [4:0] PREFETCH_INITIAL_DEPTH = 5'(PREFETCH_DISTANCE);
    localparam [4:0] PREFETCH_MAX_DEPTH_VALUE =
        5'(PREFETCH_MAX_DISTANCE);
    localparam [4:0] PREFETCH_SHORT_MAX_DEPTH_VALUE =
        (PREFETCH_MAX_DISTANCE < 4) ?
        5'(PREFETCH_MAX_DISTANCE) : 5'd4;
    localparam signed [63:0] PREFETCH_NEXT_LINE_STRIDE =
        $signed(64'(LINE_BYTES));
    localparam integer REQ_COUNT_WIDTH = $clog2(REQ_DEPTH + 1);
    localparam integer FREELOADER_STAGES =
        (FREELOADER_LATENCY > 2) ? FREELOADER_LATENCY - 2 : 1;

    wire l1_mem_valid;
    wire l1_mem_ready;
    wire l1_mem_write;
    wire l1_mem_resident;
    wire [ADDR_WIDTH-1:0] l1_mem_addr;
    wire [63:0] l1_mem_wdata;
    wire [7:0] l1_mem_wstrb;
    wire [511:0] l1_mem_rdata;
    wire l1_mem_error;
    wire l1_miss_valid;
    wire l1_miss_ready;
    wire [L1_REQ_TAG_WIDTH-1:0] l1_miss_identity;
    wire [REQ_TAG_WIDTH-1:0] l1_miss_tag =
        l1_miss_identity[REQ_TAG_WIDTH-1:0];
    wire [TAG_OVERLAY_EPOCH_WIDTH-1:0] l1_miss_epoch =
        l1_miss_identity[L1_REQ_TAG_WIDTH-1:REQ_TAG_WIDTH];
    wire [ADDR_WIDTH-1:0] l1_miss_addr;
    wire l1_miss_aged;
    wire l1_fill_valid;
    wire l1_fill_ready;
    wire [ADDR_WIDTH-1:0] l1_fill_addr /* verilator public_flat_rd */;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] l1_fill_data;
    wire l1_fill_aged;
    wire [L1_REQ_TAG_WIDTH-1:0] l1_resp_identity;
    wire command_fire;
    wire wdata_fire;
    wire icx_response_ready;
    wire response_fire;
    wire icx_response_for_dcache;
    wire response_protocol_error;

    reg [1:0] backend_state_q;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] request_txn_id_q;
    reg request_fence_q;
    reg request_write_q;
    reg request_lock_q;
    reg request_cacheable_q;
    reg request_line_read_q;
    reg [2:0] request_size_q;
    reg [63:0] request_addr_q;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] request_wdata_q;
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] request_wstrb_q;
    reg request_buffered_store_q;
    reg request_demand_q;
    reg [DEMAND_MSHR_INDEX_WIDTH-1:0] request_demand_mshr_q;
    reg request_reservation_q;
    reg request_reissue_q;
    reg [SPECULATION_EPOCH_WIDTH-1:0] request_epoch_q;
    reg command_sent_q;
    reg wdata_sent_q;
    reg [SPECULATION_EPOCH_WIDTH-1:0] speculation_epoch_q;

    // Demand MSHRs own detached cacheable read misses.  Each unique line gets
    // one ICX transaction and any same-line loads become tagged waiters.  The
    // aggregate overlay is used only for line installation; every waiter also
    // retains its own older-store snapshot for architecturally correct data.
    reg demand_mshr_valid_q [0:DEMAND_MSHRS-1];
    reg demand_mshr_issued_q [0:DEMAND_MSHRS-1];
    reg demand_mshr_complete_q [0:DEMAND_MSHRS-1];
    reg demand_mshr_fill_done_q [0:DEMAND_MSHRS-1];
    reg demand_mshr_reissue_q [0:DEMAND_MSHRS-1];
    // A late demand may adopt an already-issued prefetch rather than launch
    // a duplicate ICX read.  Until that prefetch returns, the demand MSHR is
    // valid but deliberately ineligible for the demand command selector.
    reg demand_mshr_wait_prefetch_q [0:DEMAND_MSHRS-1];
    reg [63:0] demand_mshr_addr_q [0:DEMAND_MSHRS-1];
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        demand_mshr_txn_id_q [0:DEMAND_MSHRS-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        demand_mshr_data_q [0:DEMAND_MSHRS-1];
    reg demand_mshr_error_q [0:DEMAND_MSHRS-1];
    reg [SPECULATION_EPOCH_WIDTH-1:0]
        demand_mshr_epoch_q [0:DEMAND_MSHRS-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        demand_mshr_store_data_q [0:DEMAND_MSHRS-1];
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        demand_mshr_store_strb_q [0:DEMAND_MSHRS-1];

    reg demand_waiter_valid_q [0:DEMAND_WAITER_COUNT-1];
    reg [DEMAND_MSHR_INDEX_WIDTH-1:0]
        demand_waiter_mshr_q [0:DEMAND_WAITER_COUNT-1];
    reg [TAG_OVERLAY_EPOCH_WIDTH-1:0]
        demand_waiter_epoch_q [0:DEMAND_WAITER_COUNT-1];
    reg tag_reservation_error_q [0:DEMAND_WAITER_COUNT-1];

    // A request's older-store snapshot is owned by its global LSU tag, not by
    // every response stage it traverses.  The payload has no reset and uses a
    // synchronous read so synthesis can retain one small 1R/1W memory.  The
    // resettable metadata below determines whether the RAM contents exist.
    localparam integer TAG_OVERLAY_WIDTH =
        `OPENRV64_ICX_LINE_DATA_WIDTH +
        `OPENRV64_ICX_LINE_STRB_WIDTH;
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [TAG_OVERLAY_WIDTH-1:0]
        tag_overlay_mem_q [0:DEMAND_WAITER_COUNT-1];
    reg [TAG_OVERLAY_EPOCH_WIDTH-1:0]
        tag_overlay_mem_epoch_q [0:DEMAND_WAITER_COUNT-1];
    reg tag_overlay_needed_q [0:DEMAND_WAITER_COUNT-1];
    reg [TAG_OVERLAY_EPOCH_WIDTH-1:0]
        tag_overlay_owner_epoch_q [0:DEMAND_WAITER_COUNT-1];
    reg [2:0] tag_overlay_word_q [0:DEMAND_WAITER_COUNT-1];
    reg tag_overlay_read_valid_q;
    reg [REQ_TAG_WIDTH-1:0] tag_overlay_read_tag_q;
    reg [TAG_OVERLAY_EPOCH_WIDTH-1:0]
        tag_overlay_read_epoch_q;
    reg [TAG_OVERLAY_EPOCH_WIDTH-1:0]
        tag_overlay_read_mem_epoch_q;
    reg [TAG_OVERLAY_WIDTH-1:0] tag_overlay_read_data_q;
    reg tag_overlay_bypass_valid_q;
    reg [REQ_TAG_WIDTH-1:0] tag_overlay_bypass_tag_q;
    reg [TAG_OVERLAY_EPOCH_WIDTH-1:0]
        tag_overlay_bypass_epoch_q;
    reg [TAG_OVERLAY_WIDTH-1:0] tag_overlay_bypass_data_q;
    reg [TAG_OVERLAY_EPOCH_WIDTH-1:0] tag_overlay_epoch_q;

    wire demand_mshr_match_found_r;
    wire [DEMAND_MSHR_INDEX_WIDTH-1:0] demand_mshr_match_index_r;
    wire demand_mshr_free_found_r;
    wire [DEMAND_MSHR_INDEX_WIDTH-1:0] demand_mshr_free_index_r;
    wire demand_mshr_issue_found_r;
    wire [DEMAND_MSHR_INDEX_WIDTH-1:0] demand_mshr_issue_index_r;
    wire demand_mshr_response_match_r;
    wire [DEMAND_MSHR_INDEX_WIDTH-1:0] demand_mshr_response_index_r;
    wire demand_mshr_fill_found_r;
    wire [DEMAND_MSHR_INDEX_WIDTH-1:0] demand_mshr_fill_index_r;
    // The synchronous L1 array probes its tags before accepting a fill. Pin
    // the selected complete MSHR across that busy cycle so a newly completed
    // lower-index entry cannot replace the address/data under asserted valid.
    // TODO: make fill arbitration a proper queued/reserved interface shared
    // with the eventual unified L1/L2 MSHR machinery.
    reg demand_mshr_fill_hold_valid_q;
    reg [DEMAND_MSHR_INDEX_WIDTH-1:0]
        demand_mshr_fill_hold_index_q;
    wire [DEMAND_MSHR_INDEX_WIDTH-1:0]
        demand_mshr_fill_selected_index =
            demand_mshr_fill_hold_valid_q ?
            demand_mshr_fill_hold_index_q : demand_mshr_fill_index_r;
    wire demand_mshr_prefetch_response_match_r;
    wire [DEMAND_MSHR_INDEX_WIDTH-1:0]
        demand_mshr_prefetch_response_index_r;
    reg demand_waiter_response_found_r;
    reg [REQ_TAG_WIDTH-1:0] demand_waiter_response_tag_r;
    reg [DEMAND_MSHR_INDEX_WIDTH-1:0]
        demand_waiter_response_mshr_r;
    reg demand_waiter_other_found_r;
    reg demand_fill_waiter_found_r;
    wire demand_mshr_any_valid_r;
    reg demand_prefetch_fill_hit_r;
    reg [FILL_BUFFER_INDEX_WIDTH-1:0]
        demand_prefetch_fill_index_r;
    reg prefetch_inflight_demand_match_r;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        demand_response_data_r;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        demand_fill_data_r;
    integer demand_waiter_scan;
    integer demand_waiter_other_scan;
    integer demand_fill_waiter_scan;
    integer demand_prefetch_fill_scan;
    integer demand_prefetch_inflight_scan;
    integer demand_merge_byte;
    integer demand_fill_merge_byte;
    integer demand_alloc_merge_byte;
    integer demand_store_merge_mshr;
    integer demand_store_merge_byte;
    integer demand_reset_index;
    integer demand_waiter_reset_index;

    // Native line buffers retain complete speculative ICX responses until
    // the banked SRAM can install the full line in one cycle.
    reg fill_buffer_valid_q [0:FILL_BUFFER_LINES-1];
    reg [63:0] fill_buffer_addr_q [0:FILL_BUFFER_LINES-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        fill_buffer_data_q [0:FILL_BUFFER_LINES-1];
    reg fill_buffer_prefetch_q [0:FILL_BUFFER_LINES-1];
    reg [SPECULATION_EPOCH_WIDTH-1:0]
        fill_buffer_epoch_q [0:FILL_BUFFER_LINES-1];

    // Posted stores are cacheline records with per-byte validity. Consecutive
    // stores to the newest undrained line merge here; limiting combination to
    // the FIFO tail prevents a younger store from moving ahead of an
    // intervening store to another line. Draining begins at the high
    // watermark or oldest-entry timeout and continues until the FIFO empties.
    reg store_buffer_valid_q [0:STORE_BUFFER_LINES-1];
    reg [63:0] store_buffer_addr_q [0:STORE_BUFFER_LINES-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        store_buffer_data_q [0:STORE_BUFFER_LINES-1];
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        store_buffer_strb_q [0:STORE_BUFFER_LINES-1];
    reg [STORE_BUFFER_AGE_WIDTH-1:0]
        store_buffer_age_q [0:STORE_BUFFER_LINES-1];
    reg store_buffer_issued_q [0:STORE_BUFFER_LINES-1];
    // A cold first store may authorize immediately following stores to merge
    // into this still-partial line without repeating tag resolution.  Any
    // fill or coherence event revokes the carried-forward nonresident result.
    reg store_buffer_fast_merge_q [0:STORE_BUFFER_LINES-1];
    reg store_buffer_completed_q [0:STORE_BUFFER_LINES-1];
    reg store_buffer_error_q [0:STORE_BUFFER_LINES-1];
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        store_buffer_txn_id_q [0:STORE_BUFFER_LINES-1];
    reg [STORE_BUFFER_INDEX_WIDTH-1:0] store_buffer_head_q;
    reg [STORE_BUFFER_INDEX_WIDTH-1:0] store_buffer_tail_q;
    reg [STORE_BUFFER_COUNT_WIDTH-1:0] store_buffer_count_q;
    reg store_buffer_drain_active_q;
    reg store_barrier_active_q;
    reg store_barrier_fence_pending_q;
    reg store_completion_valid_q;
    reg store_completion_error_q;
    reg [MAIN_TXN_COUNT-1:0] main_txn_in_use_q;
    reg main_txn_free_found_r;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] main_txn_free_id_r;
    reg store_buffer_issue_found_r;
    reg [STORE_BUFFER_INDEX_WIDTH-1:0] store_buffer_issue_index_r;
    reg store_response_match_r;
    reg [STORE_BUFFER_INDEX_WIDTH-1:0] store_response_index_r;
    integer store_buffer_merge_byte;
    integer main_txn_scan;
    integer store_buffer_issue_scan;
    integer store_buffer_issue_slot;
    integer store_response_scan;

    reg freeloader_valid_q [0:FREELOADER_STAGES-1];
    reg [REQ_TAG_WIDTH-1:0]
        freeloader_tag_q [0:FREELOADER_STAGES-1];
    reg [63:0] freeloader_data_q [0:FREELOADER_STAGES-1];
    reg freeloader_pending_store_valid_q;
    reg freeloader_pending_store_posted_q;
    reg [63:0] freeloader_pending_store_addr_q;
    reg [63:0] freeloader_pending_store_data_q;
    reg [7:0] freeloader_pending_store_strb_q;
    reg [63:0] freeloader_merged_data_r;
    integer freeloader_stage_index;
    integer freeloader_store_age;
    integer freeloader_store_index;
    integer freeloader_store_byte;

    reg fill_buffer_hit_r;
    reg [FILL_BUFFER_INDEX_WIDTH-1:0] fill_buffer_hit_index_r;
    reg fill_buffer_free_found_r;
    reg [FILL_BUFFER_INDEX_WIDTH-1:0] fill_buffer_free_index_r;
    reg fill_buffer_prefetch_found_r;
    reg [FILL_BUFFER_INDEX_WIDTH-1:0] fill_buffer_prefetch_index_r;
    reg [FILL_BUFFER_INDEX_WIDTH-1:0]
        fill_buffer_prefetch_replace_q;
    integer fill_buffer_free_count_r;
    integer fill_buffer_scan;
    integer fill_buffer_prefetch_scan;
    integer fill_buffer_prefetch_candidate_r;
    integer buffer_reset_index;
    reg locked_line_invalidated_q;
    reg lock_barrier_seen_q;
    // The generic L1 invalidate completion is delayed.  Preserve both the
    // request payload and its source until that completion returns; otherwise
    // a newly-arriving coherence probe can consume a local atomic invalidate's
    // ready pulse without ever reaching the tag array.
    reg invalidate_txn_valid_q;
    reg invalidate_txn_external_q;
    reg invalidate_txn_all_q;
    reg [ADDR_WIDTH-1:0] invalidate_txn_addr_q;
    reg coherent_lr_reservation_done_q;
    reg coherent_lr_reservation_error_q;
    reg active_req_lock_q;
    // atomic_active_q is correctness state: a future snoop must retry or wait
    // while the local RMW owns this line.  atomic_hot_* is only evictable
    // prefetch history and must never be used to prove atomicity.
    reg atomic_active_q;
    reg [63:0] atomic_active_line_q;
    reg atomic_hot_valid_q [0:ATOMIC_HOT_LINES-1];
    reg [63:0] atomic_hot_line_q [0:ATOMIC_HOT_LINES-1];
    reg [ATOMIC_HOT_INDEX_WIDTH-1:0] atomic_hot_replace_q;
    reg atomic_hot_match_found_r;
    reg [ATOMIC_HOT_INDEX_WIDTH-1:0] atomic_hot_match_index_r;
    reg atomic_hot_invalid_found_r;
    reg [ATOMIC_HOT_INDEX_WIDTH-1:0] atomic_hot_invalid_index_r;
    integer atomic_hot_scan;
    integer atomic_hot_reset_index;
    reg active_req_posted_q;
    reg active_req_cacheable_q;
    reg [2:0] active_req_size_q;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        demand_store_data_r;
    reg [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        demand_store_strb_r;
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        l1_mem_merged_data_r;
    reg [63:0] normal_response_merged_data_r;
    integer demand_store_age;
    integer demand_store_index;
    integer demand_store_byte;
    integer l1_mem_merge_byte;
    integer normal_response_merge_byte;
    reg fast_store_demand_mshr_match_r;
    integer fast_store_demand_mshr_scan;

    // A small address-trained stream table.  Repeated accesses to a line are
    // ignored, so an ordinary scalar word loop appears as a +1-line stream.
    // Exact stride matches win; otherwise the nearest eligible prior line is
    // selected.  This lets interleaved array loads retain separate histories
    // without bringing the load PC into the cache interface.
    reg prefetch_train_valid_q [0:PREFETCH_STREAMS-1];
    reg [63:0] prefetch_last_line_q [0:PREFETCH_STREAMS-1];
    reg prefetch_stride_valid_q [0:PREFETCH_STREAMS-1];
    reg signed [63:0] prefetch_stride_q [0:PREFETCH_STREAMS-1];
    reg [1:0] prefetch_confidence_q [0:PREFETCH_STREAMS-1];
    reg signed [63:0]
        prefetch_generate_stride_q [0:PREFETCH_STREAMS-1];
    reg prefetch_generation_active_q [0:PREFETCH_STREAMS-1];
    // A boundary probe is the single predicted line allowed into the next
    // region.  Deeper generation remains blocked until an architectural
    // demand actually consumes that speculative line.
    reg prefetch_boundary_probe_wait_q [0:PREFETCH_STREAMS-1];
    reg [63:0] prefetch_boundary_probe_addr_q [0:PREFETCH_STREAMS-1];
    // A stream earns unrestricted page transit only after its first
    // cross-boundary probe is consumed by architectural demand.
    reg prefetch_stream_long_q [0:PREFETCH_STREAMS-1];
    localparam integer PREFETCH_PAGE_OFFSET_BITS =
        (PREFETCH_PAGE_GATING == 2) ? 16 : 12;
    wire [PREFETCH_STREAMS-1:0] prefetch_stream_page_end;
    wire [63:0] prefetch_stream_next_line [0:PREFETCH_STREAMS-1];
    genvar prefetch_page_stream;
    generate
        for (prefetch_page_stream = 0;
             prefetch_page_stream < PREFETCH_STREAMS;
             prefetch_page_stream = prefetch_page_stream + 1) begin :
                g_prefetch_page_end
            assign prefetch_stream_next_line[prefetch_page_stream] =
                $unsigned($signed(prefetch_last_line_q[
                    prefetch_page_stream]) +
                    prefetch_generate_stride_q[prefetch_page_stream]);
            assign prefetch_stream_page_end[prefetch_page_stream] =
                (PREFETCH_PAGE_GATING != 0) &&
                prefetch_train_valid_q[prefetch_page_stream] &&
                prefetch_generation_active_q[prefetch_page_stream] &&
                (prefetch_stream_next_line[prefetch_page_stream][
                     63:PREFETCH_PAGE_OFFSET_BITS] !=
                 prefetch_last_line_q[prefetch_page_stream][
                     63:PREFETCH_PAGE_OFFSET_BITS]);
        end
    endgenerate
    reg [PREFETCH_STREAM_INDEX_WIDTH-1:0] prefetch_replace_q;
    reg [4:0] prefetch_depth_q;
    reg [1:0] prefetch_waste_q;
    reg prefetch_candidate_valid_q [0:PREFETCH_QUEUE_LINES-1];
    reg [63:0] prefetch_candidate_addr_q [0:PREFETCH_QUEUE_LINES-1];
    reg [PREFETCH_STREAM_INDEX_WIDTH-1:0]
        prefetch_candidate_stream_q [0:PREFETCH_QUEUE_LINES-1];
    reg prefetch_window_issued_q
        [0:PREFETCH_STREAMS-1][0:PREFETCH_MAX_DISTANCE-1];
    reg prefetch_mshr_valid_q [0:PREFETCH_OUTSTANDING-1];
    reg [63:0] prefetch_mshr_addr_q [0:PREFETCH_OUTSTANDING-1];
    reg prefetch_mshr_discard_q [0:PREFETCH_OUTSTANDING-1];
    reg [SPECULATION_EPOCH_WIDTH-1:0]
        prefetch_mshr_epoch_q [0:PREFETCH_OUTSTANDING-1];
    reg prefetch_mshr_late_reported_q [0:PREFETCH_OUTSTANDING-1];
    reg [PREFETCH_MSHR_INDEX_WIDTH-1:0] request_prefetch_mshr_q;
    reg request_prefetch_q;
    reg request_discard_q;
    reg prefetch_late_reported_q;
    reg prefetch_candidate_free_found_r;
    reg [PREFETCH_QUEUE_INDEX_WIDTH-1:0]
        prefetch_candidate_free_index_r;
    reg prefetch_generate_valid_r;
    reg [63:0] prefetch_generate_addr_r;
    reg [PREFETCH_WINDOW_INDEX_WIDTH-1:0]
        prefetch_generate_index_r;
    reg [PREFETCH_STREAM_INDEX_WIDTH-1:0]
        prefetch_generate_stream_r;
    reg prefetch_launch_found_r;
    reg [PREFETCH_QUEUE_INDEX_WIDTH-1:0] prefetch_launch_index_r;
    reg [63:0] prefetch_launch_addr_r;
    reg prefetch_queued_demand_match_r;
    reg prefetch_mshr_free_found_r;
    reg [PREFETCH_MSHR_INDEX_WIDTH-1:0] prefetch_mshr_free_index_r;
    reg prefetch_mshr_response_match_r;
    reg [PREFETCH_MSHR_INDEX_WIDTH-1:0] prefetch_mshr_response_index_r;
    reg prefetch_mshr_late_match_r;
    reg [PREFETCH_MSHR_INDEX_WIDTH-1:0] prefetch_mshr_late_index_r;
    reg prefetch_mshr_demand_wait_r;
    reg prefetch_generate_duplicate_r;
    reg prefetch_launch_store_conflict_r;
    reg demand_load_store_conflict_r;
    reg signed [63:0] prefetch_generate_window_advance_r;
    reg [63:0] prefetch_generate_window_addr_r;
    reg signed [63:0] prefetch_launch_window_advance_r;
    reg [63:0] prefetch_launch_window_addr_r;
    reg prefetch_train_same_line_found_r;
    reg prefetch_train_exact_found_r;
    reg [PREFETCH_STREAM_INDEX_WIDTH-1:0]
        prefetch_train_exact_index_r;
    reg prefetch_train_eligible_found_r;
    reg [PREFETCH_STREAM_INDEX_WIDTH-1:0]
        prefetch_train_eligible_index_r;
    reg [63:0] prefetch_train_eligible_abs_r;
    reg prefetch_train_invalid_found_r;
    reg [PREFETCH_STREAM_INDEX_WIDTH-1:0]
        prefetch_train_invalid_index_r;
    reg [PREFETCH_STREAM_INDEX_WIDTH-1:0]
        prefetch_train_index_r;
    reg prefetch_train_replacement_r;
    reg signed [63:0] prefetch_train_scan_delta_r;
    reg [63:0] prefetch_train_scan_abs_r;
    integer prefetch_queue_scan;
    integer prefetch_train_stream_scan;
    integer prefetch_generate_stream_scan;
    integer prefetch_launch_stream_scan;
    integer prefetch_reset_stream_index;
    integer prefetch_depth_scan;
    integer prefetch_duplicate_scan;
    integer prefetch_duplicate_fill_scan;
    integer prefetch_duplicate_mshr_scan;
    integer prefetch_launch_depth_scan;
    integer prefetch_launch_queue_scan;
    integer prefetch_launch_store_scan;
    integer demand_load_store_scan;
    integer prefetch_reset_index;
    integer prefetch_mshr_scan;
    reg background_work_r;
    integer quiescent_fill_scan;
    integer quiescent_waiter_scan;
    integer quiescent_prefetch_queue_scan;
    integer quiescent_prefetch_mshr_scan;
    integer quiescent_freeloader_scan;

    function automatic atomic_hot_match;
        input [63:0] address;
        integer match_index;
        begin
            atomic_hot_match = 1'b0;
            for (match_index = 0; match_index < ATOMIC_HOT_LINES;
                 match_index = match_index + 1)
                if (atomic_hot_valid_q[match_index] &&
                    (atomic_hot_line_q[match_index] ==
                     {address[63:6], 6'b0}))
                    atomic_hot_match = 1'b1;
        end
    endfunction

    wire l1_req_ready;
    wire l1_resp_valid;
    wire [63:0] l1_req_rdata;
    wire l1_req_error;
    wire l1_posted_resp_valid;
    wire [L1_REQ_TAG_WIDTH-1:0] l1_posted_resp_identity;
    reg fast_posted_resp_valid_q;
    reg [REQ_TAG_WIDTH-1:0] fast_posted_resp_tag_q;
    wire postable_store;
    wire store_buffer_accept;
    wire posted_store_request_ready;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        posted_store_line_data;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        posted_store_line_strb;
    wire l1_invalidate_ready;
    wire l1_invalidate_hit;
    wire l1_array_quiescent;
    wire freeloader_oracle_valid;
    wire [63:0] freeloader_oracle_data;
    generate
        if (FREELOADER != 0) begin : g_freeloader_oracle
            // The performance testbench drives the existing ideal-refill
            // input with its backing-RAM word. Keeping the oracle connection
            // hierarchical avoids adding a simulation port to production
            // cache and core interfaces.
            assign freeloader_oracle_valid =
                u_l1d.u_l1.g_cache.u_cache.ideal_refill_valid_i;
            assign freeloader_oracle_data =
                u_l1d.u_l1.g_cache.u_cache.ideal_refill_data_i;
        end else begin : g_no_freeloader_oracle
            assign freeloader_oracle_valid = 1'b0;
            assign freeloader_oracle_data = 64'd0;
        end
    endgenerate
    /*
     * A coherent marked read is LR.  Its home reservation is established
     * before the ordinary cached lookup is admitted.  Reserving afterward
     * could pair stale resident data with a new reservation if a write
     * interleaved between the lookup and the home transaction.
     *
     * Marked writes (SC and the write half of a decomposed AMO) remain held
     * in the L1 access state until the home returns their disposition.  A
     * sole-owner success updates the resident line; a shared-owner success
     * revokes it before the architectural response is released.
     */
    wire coherent_atomic_read =
        (COHERENT_ATOMICS != 0) && req_lock_i && !req_write_i;
    wire coherent_lr_reservation_request =
        req_valid_i && coherent_atomic_read &&
        !coherent_lr_reservation_done_q;
    wire lock_invalidate_request;
    wire lock_barrier_request = req_valid_i && req_lock_i &&
                                !lock_barrier_seen_q;
    wire speculation_barrier_event =
        speculation_barrier_i || lock_barrier_request;
    wire targeted_external_invalidate =
        invalidate_valid_i && !invalidate_all_i;
    // A targeted snoop is permitted through unrelated traffic.  Full-cache
    // maintenance retains the old quiescence rule.  If a full invalidate and
    // local atomic invalidate coincide, service the local operation first so
    // neither side waits on the other's global-quiescence condition.
    wire external_invalidate_admissible = invalidate_valid_i &&
        (targeted_external_invalidate ||
         (!lock_invalidate_request && (store_buffer_count_q == 0) &&
          !demand_mshr_any_valid_r));
    wire capture_external_invalidate = !invalidate_txn_valid_q &&
        external_invalidate_admissible;
    wire capture_lock_invalidate = !invalidate_txn_valid_q &&
        !capture_external_invalidate && lock_invalidate_request &&
        !demand_mshr_any_valid_r;
    wire l1_invalidate_valid = invalidate_txn_valid_q;
    wire l1_invalidate_all = invalidate_txn_all_q;
    wire [ADDR_WIDTH-1:0] l1_invalidate_addr = invalidate_txn_addr_q;
    wire l1_invalidate_complete = invalidate_txn_valid_q &&
        l1_invalidate_ready;
    wire lock_invalidate_fire = l1_invalidate_complete &&
        !invalidate_txn_external_q;
    wire response_tag_full;
    wire response_tag_empty;
    wire store_buffer_full =
        (store_buffer_count_q ==
         STORE_BUFFER_COUNT_WIDTH'(STORE_BUFFER_LINES));
    // Kept at this hierarchy for existing simulation diagnostics. Queue
    // ownership is in lsu_if.v.
    wire [REQ_COUNT_WIDTH-1:0] response_tag_count_q;
    wire request_needs_normal_response =
        !(req_write_i && req_posted_i);
    // The atomic marker remains a strong local serialization point.  A
    // coherent marked write retains its private line until the home returns
    // the SC disposition.  The legacy noncoherent marker has no such
    // disposition and must preserve the original early-invalidate contract.
    wire lock_backend_quiescent =
        (store_buffer_count_q == 0) &&
        !store_completion_valid_q &&
        !demand_mshr_any_valid_r &&
        (backend_state_q == BACKEND_IDLE);
    wire lock_request_ready = !req_lock_i ||
        (coherent_atomic_read ?
         (coherent_lr_reservation_done_q && lock_backend_quiescent) :
         (((COHERENT_ATOMICS != 0) || locked_line_invalidated_q) &&
          lock_backend_quiescent));
    wire freeloader_response_valid =
        freeloader_valid_q[FREELOADER_STAGES-1];
    wire demand_response_valid;
    wire demand_response_fire;
    wire response_tag_available = (SYNC_TAG_LOOKUP != 0) ||
                                  !response_tag_empty;
    wire normal_response_candidate = l1_resp_valid &&
                                     response_tag_available;
    wire [L1_REQ_TAG_WIDTH-1:0] normal_response_identity;
    wire [REQ_TAG_WIDTH-1:0] normal_response_tag;
    wire [TAG_OVERLAY_EPOCH_WIDTH-1:0] normal_response_epoch;
    wire [L1_REQ_TAG_WIDTH-1:0] response_fifo_head_identity;
    assign normal_response_identity = (SYNC_TAG_LOOKUP != 0) ?
        l1_resp_identity : response_fifo_head_identity;
    assign normal_response_tag =
        normal_response_identity[REQ_TAG_WIDTH-1:0];
    assign normal_response_epoch = normal_response_identity[
        L1_REQ_TAG_WIDTH-1:REQ_TAG_WIDTH];
    wire [TAG_OVERLAY_EPOCH_WIDTH-1:0] demand_overlay_epoch =
        demand_waiter_epoch_q[demand_waiter_response_tag_r];
    wire demand_overlay_owner_match =
        tag_overlay_owner_epoch_q[demand_waiter_response_tag_r] ==
        demand_overlay_epoch;
    wire normal_overlay_owner_match =
        tag_overlay_owner_epoch_q[normal_response_tag] ==
        normal_response_epoch;
    wire demand_overlay_needed =
        demand_waiter_response_found_r &&
        demand_overlay_owner_match &&
        tag_overlay_needed_q[demand_waiter_response_tag_r];
    wire normal_overlay_needed =
        normal_response_candidate &&
        normal_overlay_owner_match &&
        tag_overlay_needed_q[normal_response_tag];
    wire demand_overlay_read_match =
        tag_overlay_read_valid_q &&
        (tag_overlay_read_tag_q == demand_waiter_response_tag_r) &&
        (tag_overlay_read_epoch_q == demand_overlay_epoch) &&
        (tag_overlay_read_mem_epoch_q == demand_overlay_epoch);
    wire normal_overlay_read_match =
        tag_overlay_read_valid_q &&
        (tag_overlay_read_tag_q == normal_response_tag) &&
        (tag_overlay_read_epoch_q == normal_response_epoch) &&
        (tag_overlay_read_mem_epoch_q == normal_response_epoch);
    wire demand_overlay_bypass_match =
        tag_overlay_bypass_valid_q &&
        (tag_overlay_bypass_tag_q == demand_waiter_response_tag_r) &&
        (tag_overlay_bypass_epoch_q == demand_overlay_epoch);
    wire normal_overlay_bypass_match =
        tag_overlay_bypass_valid_q &&
        (tag_overlay_bypass_tag_q == normal_response_tag) &&
        (tag_overlay_bypass_epoch_q == normal_response_epoch);
    wire demand_overlay_ready =
        !demand_overlay_needed ||
        demand_overlay_read_match ||
        demand_overlay_bypass_match;
    wire normal_overlay_ready =
        !normal_overlay_needed ||
        normal_overlay_read_match ||
        normal_overlay_bypass_match;
    wire tag_overlay_read_demand =
        demand_waiter_response_found_r && demand_overlay_needed &&
        !demand_overlay_read_match;
    wire tag_overlay_read_normal =
        !tag_overlay_read_demand &&
        normal_response_candidate && normal_overlay_needed &&
        !normal_overlay_read_match;
    wire tag_overlay_read_request =
        tag_overlay_read_demand || tag_overlay_read_normal;
    wire [REQ_TAG_WIDTH-1:0] tag_overlay_read_request_tag =
        tag_overlay_read_demand ?
        demand_waiter_response_tag_r : normal_response_tag;
    wire [TAG_OVERLAY_EPOCH_WIDTH-1:0]
        tag_overlay_read_request_epoch = tag_overlay_read_demand ?
        demand_overlay_epoch : normal_response_epoch;
    wire [TAG_OVERLAY_WIDTH-1:0] demand_overlay_data =
        demand_overlay_bypass_match ?
        tag_overlay_bypass_data_q : tag_overlay_read_data_q;
    wire [TAG_OVERLAY_WIDTH-1:0] normal_overlay_data =
        normal_overlay_bypass_match ?
        tag_overlay_bypass_data_q : tag_overlay_read_data_q;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        demand_overlay_line =
        demand_overlay_data[TAG_OVERLAY_WIDTH-1 -:
                            `OPENRV64_ICX_LINE_DATA_WIDTH];
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        demand_overlay_strb =
        demand_overlay_data[`OPENRV64_ICX_LINE_STRB_WIDTH-1:0];
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        normal_overlay_line =
        normal_overlay_data[TAG_OVERLAY_WIDTH-1 -:
                            `OPENRV64_ICX_LINE_DATA_WIDTH];
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        normal_overlay_strb =
        normal_overlay_data[`OPENRV64_ICX_LINE_STRB_WIDTH-1:0];
    // In synchronous-tag mode the miss leaves the shared array one cycle
    // after admission, when req_* may already describe a younger operation.
    // The admission-time overlay bypass is therefore the authoritative dirty
    // snapshot for MSHR allocation.
    wire l1_miss_overlay_needed =
        tag_overlay_needed_q[l1_miss_tag] &&
        (tag_overlay_owner_epoch_q[l1_miss_tag] == l1_miss_epoch);
    wire l1_miss_overlay_bypass_match =
        l1_miss_overlay_needed && tag_overlay_bypass_valid_q &&
        (tag_overlay_bypass_tag_q == l1_miss_tag) &&
        (tag_overlay_bypass_epoch_q == l1_miss_epoch);
    wire [TAG_OVERLAY_WIDTH-1:0] l1_miss_overlay_data =
        (SYNC_TAG_LOOKUP != 0) ?
            (l1_miss_overlay_bypass_match ?
                tag_overlay_bypass_data_q :
                {TAG_OVERLAY_WIDTH{1'b0}}) :
            {demand_store_data_r, demand_store_strb_r};
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        l1_miss_store_data =
        l1_miss_overlay_data[TAG_OVERLAY_WIDTH-1 -:
                             `OPENRV64_ICX_LINE_DATA_WIDTH];
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        l1_miss_store_strb =
        l1_miss_overlay_data[`OPENRV64_ICX_LINE_STRB_WIDTH-1:0];
    wire normal_response_valid =
        normal_response_candidate && normal_overlay_ready;
    wire freeloader_response_ready =
        resp_ready_i && !demand_response_valid &&
        !normal_response_valid;
    wire freeloader_pipe_advance =
        !freeloader_response_valid || freeloader_response_ready;
    wire freeloader_order_safe =
        !freeloader_pending_store_valid_q ||
        freeloader_pending_store_posted_q;
    wire freeloader_request = (FREELOADER != 0) && req_valid_i &&
        !req_write_i && !req_lock_i && req_cacheable_i &&
        freeloader_oracle_valid;
    // Dirty-line forwarding is a cacheable-memory operation.  Device or
    // otherwise uncached aliases retain the conservative drain-before-read
    // behavior instead of treating buffered cache data as an MMIO response.
    wire demand_load_store_block =
        demand_load_store_conflict_r &&
        (!req_cacheable_i || req_lock_i);
    wire [STORE_BUFFER_INDEX_WIDTH-1:0] store_buffer_newest_index =
        (store_buffer_tail_q == 0) ?
        STORE_BUFFER_INDEX_WIDTH'(STORE_BUFFER_LINES - 1) :
        store_buffer_tail_q - 1'b1;
    wire store_buffer_force_drain =
        demand_load_store_block ||
        (invalidate_valid_i && invalidate_all_i) ||
        speculation_barrier_i ||
        store_barrier_active_q ||
        (req_valid_i && req_lock_i);
    wire fast_posted_resp_pop = fast_posted_resp_valid_q &&
                                posted_resp_ready_i;
    // An older shared-L1 response may drain on the accepting edge.  Once a
    // fast response is queued it remains ahead of any younger shared-L1
    // response, so do not replace it while that younger response is pending.
    wire fast_posted_resp_slot_available =
        (!fast_posted_resp_valid_q &&
         (!l1_posted_resp_valid || posted_resp_ready_i)) ||
        (fast_posted_resp_valid_q && !l1_posted_resp_valid &&
         posted_resp_ready_i);
    // A cacheable store which traverses the shared L1 path is folded into an
    // active demand MSHR for the same line.  The direct store-buffer shortcut
    // bypasses that merge point, so it is unsafe while a read fill can still
    // install an older copy of the line.  Fall back to normal tag resolution
    // for both an allocated MSHR and a miss being classified this cycle.
    always @* begin
        fast_store_demand_mshr_match_r = 1'b0;
        for (fast_store_demand_mshr_scan = 0;
             fast_store_demand_mshr_scan < DEMAND_MSHRS;
             fast_store_demand_mshr_scan =
                 fast_store_demand_mshr_scan + 1)
            if (demand_mshr_valid_q[fast_store_demand_mshr_scan] &&
                (demand_mshr_addr_q[fast_store_demand_mshr_scan] ==
                 {req_addr_i[63:6], 6'b0}))
                fast_store_demand_mshr_match_r = 1'b1;
    end
    wire fast_store_incoming_miss_match =
        l1_miss_valid &&
        (l1_miss_addr == {req_addr_i[63:6], 6'b0});
    wire fast_store_match =
        (SYNC_TAG_LOOKUP != 0) && (SYNC_STORE_EXTENSION != 0) &&
        req_valid_i && req_write_i && req_posted_i &&
        req_cacheable_i && !req_lock_i &&
        (store_buffer_count_q != 0) &&
        store_buffer_valid_q[store_buffer_newest_index] &&
        !store_buffer_issued_q[store_buffer_newest_index] &&
        store_buffer_fast_merge_q[store_buffer_newest_index] &&
        (store_buffer_addr_q[store_buffer_newest_index] ==
         {req_addr_i[63:6], 6'b0}) &&
        (store_buffer_strb_q[store_buffer_newest_index] !=
         {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b1}}) &&
        (store_buffer_age_q[store_buffer_newest_index] !=
         STORE_BUFFER_TIMEOUT_LAST) &&
        !fast_store_demand_mshr_match_r &&
        !fast_store_incoming_miss_match &&
        !store_buffer_force_drain;
    wire fast_store_ready = fast_posted_resp_slot_available &&
                            !invalidate_valid_i && !l1_fill_valid &&
                            !(l1_mem_valid && l1_mem_write);
    wire fast_store_fire = fast_store_match && fast_store_ready;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        fast_store_line_data =
            {{(`OPENRV64_ICX_LINE_DATA_WIDTH-64){1'b0}}, req_wdata_i}
            << (req_addr_i[5:3] * 64);
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        fast_store_line_strb =
            {{(`OPENRV64_ICX_LINE_STRB_WIDTH-8){1'b0}}, req_wstrb_i}
            << (req_addr_i[5:3] * 8);
    wire freeloader_request_ready =
        freeloader_pipe_advance && freeloader_order_safe;
    wire freeloader_request_fire =
        freeloader_request && freeloader_request_ready;
    /*
     * Do not let a posted store enter the internal L1 write-through stage
     * while its downstream FIFO is full.  That stage cannot accept a snoop;
     * if it waits for a store-buffer drain while the coherence home waits for
     * its snoop ACK, both sides deadlock.  Backpressure at admission keeps the
     * internal L1 in STATE_RUN so targeted invalidation remains independent.
     */
    wire posted_store_admission_ready =
        !(req_write_i && req_posted_i && req_cacheable_i &&
          !req_lock_i) ||
        !store_buffer_full;
    wire l1_req_valid = req_valid_i && !fast_store_match &&
        !freeloader_request &&
        !invalidate_valid_i &&
        (!request_needs_normal_response ||
         (SYNC_TAG_LOOKUP != 0) || !response_tag_full) &&
        posted_store_admission_ready &&
        lock_request_ready &&
        posted_store_request_ready &&
        !demand_load_store_block;
    wire l1_req_cacheable =
        req_cacheable_i &&
        (!req_lock_i || (COHERENT_ATOMICS != 0));
    wire req_invariant =
        ((req_addr_i - `OPENRV64_SOC_INVARIANT_BASE) <
         `OPENRV64_SOC_INVARIANT_SIZE);
    // Invariant stores remain cacheable at ICX/L2 so they can use the posted
    // store path, but must not update or forward a private-cache copy.
    wire l1_array_req_cacheable =
        l1_req_cacheable && !(req_write_i && req_invariant);
    wire l1_mem_invariant =
        ((l1_mem_addr - `OPENRV64_SOC_INVARIANT_BASE) <
         `OPENRV64_SOC_INVARIANT_SIZE);
    wire l1_request_fire = l1_req_valid && l1_req_ready;
    wire [TAG_OVERLAY_EPOCH_WIDTH-1:0] tag_overlay_next_epoch =
        tag_overlay_epoch_q + 1'b1;
    wire [L1_REQ_TAG_WIDTH-1:0] l1_request_identity =
        {tag_overlay_next_epoch, req_tag_i};
    wire request_overlay_needed =
        !req_write_i && !req_lock_i && req_cacheable_i && !req_invariant &&
        (|demand_store_strb_r);
    wire tag_overlay_write =
        l1_request_fire && request_overlay_needed;
    wire l1_resp_ready = resp_ready_i && !demand_response_valid &&
        response_tag_available && normal_overlay_ready;
    wire l1_response_fire = l1_resp_valid && l1_resp_ready;
    wire demand_request_fire =
        l1_request_fire || freeloader_request_fire;
    wire [63:0] demand_line_addr = {req_addr_i[63:6], 6'b0};
    wire store_request_pending = req_valid_i && req_write_i;
    wire atomic_hot_demand_match = atomic_hot_match(demand_line_addr);
    wire prefetch_train_access = (PREFETCH_ENABLE != 0) &&
        (ENABLE != 0) && demand_request_fire && !req_write_i &&
        l1_req_cacheable && !req_lock_i && !atomic_hot_demand_match &&
        !req_invariant;

    // Deliberately no reset on the RAM, its read payload, or the bypass
    // payload. Resetting any of them would turn line-sized storage back into
    // thousands of flops. The RAM read register has no alternate input so
    // synthesis can absorb it into a synchronous SRAM port. The separate
    // last-write bypass preserves the common resident-hit latency.
    always @(posedge clk_i) begin
        if (tag_overlay_write) begin
            tag_overlay_mem_q[req_tag_i] <=
                {demand_store_data_r, demand_store_strb_r};
            tag_overlay_mem_epoch_q[req_tag_i] <=
                tag_overlay_next_epoch;
        end
        if (tag_overlay_read_request) begin
            tag_overlay_read_data_q <=
                tag_overlay_mem_q[tag_overlay_read_request_tag];
            tag_overlay_read_mem_epoch_q <=
                tag_overlay_mem_epoch_q[tag_overlay_read_request_tag];
        end
        if (tag_overlay_write) begin
            tag_overlay_bypass_data_q <=
                {demand_store_data_r, demand_store_strb_r};
            tag_overlay_bypass_epoch_q <= tag_overlay_next_epoch;
        end
    end

    always @* begin
        atomic_hot_match_found_r = 1'b0;
        atomic_hot_match_index_r =
            {ATOMIC_HOT_INDEX_WIDTH{1'b0}};
        atomic_hot_invalid_found_r = 1'b0;
        atomic_hot_invalid_index_r =
            {ATOMIC_HOT_INDEX_WIDTH{1'b0}};
        for (atomic_hot_scan = 0; atomic_hot_scan < ATOMIC_HOT_LINES;
             atomic_hot_scan = atomic_hot_scan + 1) begin
            if (!atomic_hot_match_found_r &&
                atomic_hot_valid_q[atomic_hot_scan] &&
                (atomic_hot_line_q[atomic_hot_scan] ==
                 {req_addr_i[63:6], 6'b0})) begin
                atomic_hot_match_found_r = 1'b1;
                atomic_hot_match_index_r =
                    atomic_hot_scan[ATOMIC_HOT_INDEX_WIDTH-1:0];
            end
            if (!atomic_hot_invalid_found_r &&
                !atomic_hot_valid_q[atomic_hot_scan]) begin
                atomic_hot_invalid_found_r = 1'b1;
                atomic_hot_invalid_index_r =
                    atomic_hot_scan[ATOMIC_HOT_INDEX_WIDTH-1:0];
            end
        end
    end
    localparam signed [63:0] PREFETCH_MAX_STRIDE_BYTES =
        PREFETCH_MAX_STRIDE_LINES * LINE_BYTES;
    always @* begin
        prefetch_train_same_line_found_r = 1'b0;
        prefetch_train_exact_found_r = 1'b0;
        prefetch_train_exact_index_r =
            {PREFETCH_STREAM_INDEX_WIDTH{1'b0}};
        prefetch_train_eligible_found_r = 1'b0;
        prefetch_train_eligible_index_r =
            {PREFETCH_STREAM_INDEX_WIDTH{1'b0}};
        prefetch_train_eligible_abs_r = {64{1'b1}};
        prefetch_train_invalid_found_r = 1'b0;
        prefetch_train_invalid_index_r =
            {PREFETCH_STREAM_INDEX_WIDTH{1'b0}};
        prefetch_train_scan_delta_r = 64'sd0;
        prefetch_train_scan_abs_r = 64'd0;
        for (prefetch_train_stream_scan = 0;
             prefetch_train_stream_scan < PREFETCH_STREAMS;
             prefetch_train_stream_scan =
                 prefetch_train_stream_scan + 1) begin
            prefetch_train_scan_delta_r =
                $signed(demand_line_addr) -
                $signed(prefetch_last_line_q[
                    prefetch_train_stream_scan]);
            prefetch_train_scan_abs_r =
                prefetch_train_scan_delta_r < 0 ?
                $unsigned(-prefetch_train_scan_delta_r) :
                $unsigned(prefetch_train_scan_delta_r);
            if (prefetch_train_valid_q[prefetch_train_stream_scan] &&
                (demand_line_addr ==
                 prefetch_last_line_q[prefetch_train_stream_scan]))
                prefetch_train_same_line_found_r = 1'b1;
            if (!prefetch_train_exact_found_r &&
                prefetch_train_valid_q[prefetch_train_stream_scan] &&
                (prefetch_stream_page_end[
                     prefetch_train_stream_scan] ||
                 prefetch_stream_long_q[
                     prefetch_train_stream_scan] ||
                 (PREFETCH_PAGE_GATING == 0) ||
                 (demand_line_addr[63:PREFETCH_PAGE_OFFSET_BITS] ==
                  prefetch_last_line_q[prefetch_train_stream_scan][
                      63:PREFETCH_PAGE_OFFSET_BITS])) &&
                prefetch_stride_valid_q[prefetch_train_stream_scan] &&
                (prefetch_train_scan_delta_r != 0) &&
                (prefetch_train_scan_delta_r <=
                 PREFETCH_MAX_STRIDE_BYTES) &&
                (prefetch_train_scan_delta_r >=
                 -PREFETCH_MAX_STRIDE_BYTES) &&
                (prefetch_train_scan_delta_r ==
                 prefetch_stride_q[prefetch_train_stream_scan])) begin
                prefetch_train_exact_found_r = 1'b1;
                prefetch_train_exact_index_r =
                    PREFETCH_STREAM_INDEX_WIDTH'(
                        prefetch_train_stream_scan);
            end
            if (prefetch_train_valid_q[prefetch_train_stream_scan] &&
                (!prefetch_stream_page_end[
                     prefetch_train_stream_scan] ||
                 prefetch_stream_long_q[
                     prefetch_train_stream_scan]) &&
                ((PREFETCH_PAGE_GATING == 0) ||
                 prefetch_stream_long_q[
                     prefetch_train_stream_scan] ||
                 (demand_line_addr[63:PREFETCH_PAGE_OFFSET_BITS] ==
                  prefetch_last_line_q[prefetch_train_stream_scan][
                      63:PREFETCH_PAGE_OFFSET_BITS])) &&
                (prefetch_train_scan_delta_r != 0) &&
                (prefetch_train_scan_delta_r <=
                 PREFETCH_MAX_STRIDE_BYTES) &&
                (prefetch_train_scan_delta_r >=
                 -PREFETCH_MAX_STRIDE_BYTES) &&
                (!prefetch_train_eligible_found_r ||
                 (prefetch_train_scan_abs_r <
                  prefetch_train_eligible_abs_r))) begin
                prefetch_train_eligible_found_r = 1'b1;
                prefetch_train_eligible_index_r =
                    PREFETCH_STREAM_INDEX_WIDTH'(
                        prefetch_train_stream_scan);
                prefetch_train_eligible_abs_r =
                    prefetch_train_scan_abs_r;
            end
            if (!prefetch_train_invalid_found_r &&
                (!prefetch_train_valid_q[prefetch_train_stream_scan] ||
                 (prefetch_stream_page_end[
                      prefetch_train_stream_scan] &&
                  !prefetch_stream_long_q[
                      prefetch_train_stream_scan]))) begin
                prefetch_train_invalid_found_r = 1'b1;
                prefetch_train_invalid_index_r =
                    PREFETCH_STREAM_INDEX_WIDTH'(
                        prefetch_train_stream_scan);
            end
        end
        prefetch_train_replacement_r = 1'b0;
        if (prefetch_train_exact_found_r)
            prefetch_train_index_r = prefetch_train_exact_index_r;
        else if (prefetch_train_eligible_found_r)
            prefetch_train_index_r = prefetch_train_eligible_index_r;
        else if (prefetch_train_invalid_found_r)
            prefetch_train_index_r = prefetch_train_invalid_index_r;
        else begin
            prefetch_train_index_r = prefetch_replace_q;
            prefetch_train_replacement_r = 1'b1;
        end
    end
    wire prefetch_train_event = prefetch_train_access &&
        !prefetch_train_same_line_found_r;
    wire prefetch_train_boundary_probe_match =
        prefetch_train_event &&
        prefetch_train_exact_found_r &&
        prefetch_stream_page_end[prefetch_train_exact_index_r] &&
        !prefetch_stream_long_q[prefetch_train_exact_index_r];
    wire signed [63:0] prefetch_observed_delta =
        $signed(demand_line_addr) -
        $signed(prefetch_last_line_q[prefetch_train_index_r]);
    wire prefetch_delta_eligible =
        (prefetch_observed_delta != 0) &&
        (prefetch_observed_delta <= PREFETCH_MAX_STRIDE_BYTES) &&
        (prefetch_observed_delta >= -PREFETCH_MAX_STRIDE_BYTES);
    wire prefetch_stride_match =
        prefetch_train_valid_q[prefetch_train_index_r] &&
        prefetch_stride_valid_q[prefetch_train_index_r] &&
        prefetch_delta_eligible &&
        (prefetch_observed_delta ==
         prefetch_stride_q[prefetch_train_index_r]);
    wire prefetch_stream_change = prefetch_train_event &&
        (prefetch_train_replacement_r ||
         (!prefetch_train_boundary_probe_match &&
          prefetch_train_valid_q[prefetch_train_index_r] &&
          !prefetch_stride_match));

    // Identify same-line posted stores for prefetch suppression and
    // observability.  Architectural demand loads do not wait for these
    // entries: the complete dirty-line overlay below is snapshotted when the
    // load enters the L1.
    always @* begin
        demand_load_store_conflict_r = 1'b0;
        if (req_valid_i && !req_write_i) begin
            for (demand_load_store_scan = 0;
                 demand_load_store_scan < STORE_BUFFER_LINES;
                 demand_load_store_scan =
                     demand_load_store_scan + 1) begin
                if (store_buffer_valid_q[demand_load_store_scan] &&
                    (store_buffer_addr_q[demand_load_store_scan] ==
                     {req_addr_i[63:6], 6'b0}))
                    demand_load_store_conflict_r = 1'b1;
            end
        end
    end

    // CAM the retained dirty fragments in FIFO age order.  Newer entries
    // overwrite older bytes.  The result is a complete line-shaped overlay,
    // not merely the requested word, because a load miss may install all 64
    // bytes in L1 while an older store is still buffered.
    always @* begin
        demand_store_data_r =
            {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
        demand_store_strb_r =
            {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b0}};
        demand_store_index = 0;
        for (demand_store_age = 0;
             demand_store_age < STORE_BUFFER_LINES;
             demand_store_age = demand_store_age + 1) begin
            demand_store_index =
                32'(store_buffer_head_q) + demand_store_age;
            if (demand_store_index >= STORE_BUFFER_LINES)
                demand_store_index =
                    demand_store_index - STORE_BUFFER_LINES;
            if ((demand_store_age < store_buffer_count_q) &&
                store_buffer_valid_q[demand_store_index] &&
                (store_buffer_addr_q[demand_store_index] ==
                 {req_addr_i[63:6], 6'b0})) begin
                for (demand_store_byte = 0;
                     demand_store_byte <
                         `OPENRV64_ICX_LINE_STRB_WIDTH;
                     demand_store_byte = demand_store_byte + 1) begin
                    if (store_buffer_strb_q[demand_store_index][
                            demand_store_byte]) begin
                        demand_store_data_r[
                            demand_store_byte*8 +: 8] =
                            store_buffer_data_q[demand_store_index][
                                demand_store_byte*8 +: 8];
                        demand_store_strb_r[demand_store_byte] = 1'b1;
                    end
                end
            end
        end
        // A posted store can still occupy the shared L1 write-through stage
        // while this load uses the SRAM read port.  The registered FIFO scan
        // above does not yet contain that fragment, so fold the pending store
        // into the same dirty-line snapshot explicitly.
        if (postable_store &&
            ({l1_mem_addr[63:6], 6'b0} ==
             {req_addr_i[63:6], 6'b0})) begin
            for (demand_store_byte = 0;
                 demand_store_byte <
                     `OPENRV64_ICX_LINE_STRB_WIDTH;
                 demand_store_byte = demand_store_byte + 1) begin
                if (posted_store_line_strb[demand_store_byte]) begin
                    demand_store_data_r[
                        demand_store_byte*8 +: 8] =
                        posted_store_line_data[
                            demand_store_byte*8 +: 8];
                    demand_store_strb_r[demand_store_byte] = 1'b1;
                end
            end
        end
        if (req_invariant) begin
            demand_store_data_r =
                {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
            demand_store_strb_r =
                {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b0}};
        end
    end

    // Completed demand misses win one response cycle.  A held resident-hit
    // response then blocks new L1 lookups, so neither side can starve the
    // other.  The simulation-only freeloader remains last priority.
    assign req_ready_o = fast_store_match ? fast_store_ready :
                         freeloader_request ?
                         (freeloader_request_ready &&
                          !invalidate_valid_i) :
                         (l1_req_ready &&
                          !invalidate_valid_i &&
                          (!request_needs_normal_response ||
                           !response_tag_full) &&
                          posted_store_admission_ready &&
                          lock_request_ready &&
                          posted_store_request_ready &&
                          !demand_load_store_block);
    assign resp_valid_o = demand_response_valid ||
                          normal_response_valid ||
                          freeloader_response_valid;
    assign resp_tag_o = demand_response_valid ?
        demand_waiter_response_tag_r : normal_response_valid ?
        normal_response_tag :
        freeloader_tag_q[FREELOADER_STAGES-1];
    assign req_rdata_o = demand_response_valid ?
        demand_response_data_r[
            tag_overlay_word_q[demand_waiter_response_tag_r]*64 +: 64] :
        normal_response_valid ?
        normal_response_merged_data_r :
        freeloader_data_q[FREELOADER_STAGES-1];
    assign req_error_o = demand_response_valid ?
        (demand_mshr_error_q[demand_waiter_response_mshr_r] ||
         tag_reservation_error_q[demand_waiter_response_tag_r]) :
        normal_response_valid ?
        (l1_req_error || tag_reservation_error_q[normal_response_tag]) :
        1'b0;
    assign posted_resp_valid_o = fast_posted_resp_valid_q ||
                                 l1_posted_resp_valid;
    assign posted_resp_tag_o = fast_posted_resp_valid_q ?
        fast_posted_resp_tag_q :
        l1_posted_resp_identity[REQ_TAG_WIDTH-1:0];
    wire l1_posted_resp_ready = posted_resp_ready_i &&
                                !fast_posted_resp_valid_q;
    // Completion is routed only to the source which owns the captured
    // invalidate transaction.  It must never be inferred from the current
    // value of the two request-valid inputs.
    assign invalidate_ready_o = l1_invalidate_complete &&
        invalidate_txn_external_q;
    assign invalidate_hit_o = invalidate_ready_o &&
                              l1_invalidate_hit;

    // Apply the request's snapshotted dirty bytes to a resident-hit response.
    // The same overlay is applied to refill data below, so subsequent hits
    // retain the value after the store-buffer entry has drained.
    always @* begin
        normal_response_merged_data_r = l1_req_rdata;
        for (normal_response_merge_byte = 0;
             normal_response_merge_byte < 8;
             normal_response_merge_byte =
                 normal_response_merge_byte + 1) begin
            if (normal_overlay_needed &&
                normal_overlay_strb[
                    (tag_overlay_word_q[normal_response_tag] * 8) +
                    normal_response_merge_byte])
                normal_response_merged_data_r[
                    normal_response_merge_byte*8 +: 8] =
                    normal_overlay_line[
                        ((tag_overlay_word_q[normal_response_tag] *
                          8) + normal_response_merge_byte)*8 +: 8];
        end
    end

    // The RAM oracle is older than stores which have completed northbound but
    // are still queued for ICX. Overlay those bytes in FIFO order, then the
    // store currently crossing the shared L1. This preserves load-after-store
    // semantics even though the freeloader bypasses the cache lookup.
    always @* begin
        freeloader_merged_data_r = freeloader_oracle_data;
        freeloader_store_index = 0;
        for (freeloader_store_age = 0;
             freeloader_store_age < STORE_BUFFER_LINES;
             freeloader_store_age = freeloader_store_age + 1) begin
            freeloader_store_index =
                32'(store_buffer_head_q) + freeloader_store_age;
            if (freeloader_store_index >= STORE_BUFFER_LINES)
                freeloader_store_index =
                    freeloader_store_index - STORE_BUFFER_LINES;
            if ((freeloader_store_age < store_buffer_count_q) &&
                store_buffer_valid_q[freeloader_store_index] &&
                (store_buffer_addr_q[freeloader_store_index] ==
                 {req_addr_i[63:6], 6'b0})) begin
                for (freeloader_store_byte = 0;
                     freeloader_store_byte < 8;
                     freeloader_store_byte =
                         freeloader_store_byte + 1) begin
                    if (store_buffer_strb_q[freeloader_store_index][
                            (req_addr_i[5:3] * 8) +
                            freeloader_store_byte])
                        freeloader_merged_data_r[
                            freeloader_store_byte*8 +: 8] =
                            store_buffer_data_q[
                                freeloader_store_index][
                                ((req_addr_i[5:3] * 8) +
                                 freeloader_store_byte)*8 +: 8];
                end
            end
        end
        if (freeloader_pending_store_valid_q &&
            freeloader_pending_store_posted_q &&
            (freeloader_pending_store_addr_q[63:3] ==
             req_addr_i[63:3])) begin
            for (freeloader_store_byte = 0;
                 freeloader_store_byte < 8;
                 freeloader_store_byte = freeloader_store_byte + 1) begin
                if (freeloader_pending_store_strb_q[
                        freeloader_store_byte])
                    freeloader_merged_data_r[
                        freeloader_store_byte*8 +: 8] =
                        freeloader_pending_store_data_q[
                            freeloader_store_byte*8 +: 8];
            end
        end
    end

    wire prefetch_command_inflight = request_prefetch_q &&
        (backend_state_q != BACKEND_IDLE);
    wire prefetch_invalidate_fire = l1_invalidate_valid &&
                                    l1_invalidate_ready;
    always @* begin
        prefetch_mshr_free_found_r = 1'b0;
        prefetch_mshr_free_index_r =
            {PREFETCH_MSHR_INDEX_WIDTH{1'b0}};
        prefetch_mshr_response_match_r = 1'b0;
        prefetch_mshr_response_index_r =
            {PREFETCH_MSHR_INDEX_WIDTH{1'b0}};
        prefetch_mshr_late_match_r = 1'b0;
        prefetch_mshr_late_index_r =
            {PREFETCH_MSHR_INDEX_WIDTH{1'b0}};
        prefetch_mshr_demand_wait_r = 1'b0;
        for (prefetch_mshr_scan = 0;
             prefetch_mshr_scan < PREFETCH_OUTSTANDING;
             prefetch_mshr_scan = prefetch_mshr_scan + 1) begin
            if (!prefetch_mshr_free_found_r &&
                !prefetch_mshr_valid_q[prefetch_mshr_scan]) begin
                prefetch_mshr_free_found_r = 1'b1;
                prefetch_mshr_free_index_r =
                    prefetch_mshr_scan[PREFETCH_MSHR_INDEX_WIDTH-1:0];
            end
            if (!prefetch_mshr_response_match_r &&
                prefetch_mshr_valid_q[prefetch_mshr_scan] &&
                icx_response_for_dcache &&
                (icx_resp_txn_id_i ==
                 (PREFETCH_TXN_BASE +
                  `OPENRV64_ICX_TXN_ID_WIDTH'(prefetch_mshr_scan)))) begin
                prefetch_mshr_response_match_r = 1'b1;
                prefetch_mshr_response_index_r =
                    prefetch_mshr_scan[
                        PREFETCH_MSHR_INDEX_WIDTH-1:0];
            end
            if (!prefetch_mshr_late_match_r &&
                prefetch_mshr_valid_q[prefetch_mshr_scan] &&
                !prefetch_mshr_late_reported_q[prefetch_mshr_scan] &&
                demand_request_fire && !req_write_i && l1_req_cacheable &&
                (prefetch_mshr_addr_q[prefetch_mshr_scan] ==
                 demand_line_addr)) begin
                prefetch_mshr_late_match_r = 1'b1;
                prefetch_mshr_late_index_r =
                    prefetch_mshr_scan[
                        PREFETCH_MSHR_INDEX_WIDTH-1:0];
            end
            if (prefetch_mshr_valid_q[prefetch_mshr_scan] &&
                l1_mem_valid && !l1_mem_write &&
                active_req_cacheable_q &&
                (prefetch_mshr_addr_q[prefetch_mshr_scan] ==
                 {l1_mem_addr[63:6], 6'b0}))
                prefetch_mshr_demand_wait_r = 1'b1;
        end
    end
    always @* begin
        fill_buffer_hit_r = 1'b0;
        fill_buffer_hit_index_r =
            {FILL_BUFFER_INDEX_WIDTH{1'b0}};
        fill_buffer_free_found_r = 1'b0;
        fill_buffer_free_index_r =
            {FILL_BUFFER_INDEX_WIDTH{1'b0}};
        fill_buffer_prefetch_found_r = 1'b0;
        fill_buffer_prefetch_index_r =
            {FILL_BUFFER_INDEX_WIDTH{1'b0}};
        fill_buffer_prefetch_candidate_r = 0;
        fill_buffer_free_count_r = 0;
        for (fill_buffer_scan = 0;
             fill_buffer_scan < FILL_BUFFER_LINES;
             fill_buffer_scan = fill_buffer_scan + 1) begin
            if (!fill_buffer_hit_r &&
                fill_buffer_valid_q[fill_buffer_scan] &&
                ({l1_mem_addr[63:6], 6'b0} ==
                 fill_buffer_addr_q[fill_buffer_scan])) begin
                fill_buffer_hit_r = 1'b1;
                fill_buffer_hit_index_r =
                    fill_buffer_scan[FILL_BUFFER_INDEX_WIDTH-1:0];
            end
            if (!fill_buffer_free_found_r &&
                !fill_buffer_valid_q[fill_buffer_scan]) begin
                fill_buffer_free_found_r = 1'b1;
                fill_buffer_free_index_r =
                    fill_buffer_scan[FILL_BUFFER_INDEX_WIDTH-1:0];
            end
            if (!fill_buffer_valid_q[fill_buffer_scan])
                fill_buffer_free_count_r = fill_buffer_free_count_r + 1;
        end
        for (fill_buffer_prefetch_scan = 0;
             fill_buffer_prefetch_scan < FILL_BUFFER_LINES;
             fill_buffer_prefetch_scan =
                 fill_buffer_prefetch_scan + 1) begin
            fill_buffer_prefetch_candidate_r =
                32'(fill_buffer_prefetch_replace_q) +
                fill_buffer_prefetch_scan;
            if (fill_buffer_prefetch_candidate_r >= FILL_BUFFER_LINES)
                fill_buffer_prefetch_candidate_r =
                    fill_buffer_prefetch_candidate_r -
                    FILL_BUFFER_LINES;
            if (!fill_buffer_prefetch_found_r &&
                fill_buffer_valid_q[
                    fill_buffer_prefetch_candidate_r] &&
                fill_buffer_prefetch_q[
                    fill_buffer_prefetch_candidate_r]) begin
                fill_buffer_prefetch_found_r = 1'b1;
                fill_buffer_prefetch_index_r =
                    FILL_BUFFER_INDEX_WIDTH'(
                        fill_buffer_prefetch_candidate_r);
            end
        end
    end

    wire [DEMAND_MSHRS-1:0] demand_mshr_valid_vec;
    wire [DEMAND_MSHRS-1:0] demand_mshr_issued_vec;
    wire [DEMAND_MSHRS-1:0] demand_mshr_complete_vec;
    wire [DEMAND_MSHRS-1:0] demand_mshr_fill_done_vec;
    wire [DEMAND_MSHRS-1:0] demand_mshr_error_vec;
    wire [DEMAND_MSHRS-1:0] demand_mshr_wait_prefetch_vec;
    wire [DEMAND_MSHRS*64-1:0] demand_mshr_addr_vec;
    wire [DEMAND_MSHRS*`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
        demand_mshr_txn_id_vec;
    wire [DEMAND_MSHRS*SPECULATION_EPOCH_WIDTH-1:0]
        demand_mshr_epoch_vec;
    genvar demand_mshr_pack_index;
    generate
        for (demand_mshr_pack_index = 0;
             demand_mshr_pack_index < DEMAND_MSHRS;
             demand_mshr_pack_index = demand_mshr_pack_index + 1) begin :
                g_demand_mshr_pack
            assign demand_mshr_valid_vec[demand_mshr_pack_index] =
                demand_mshr_valid_q[demand_mshr_pack_index];
            assign demand_mshr_issued_vec[demand_mshr_pack_index] =
                demand_mshr_issued_q[demand_mshr_pack_index];
            assign demand_mshr_complete_vec[demand_mshr_pack_index] =
                demand_mshr_complete_q[demand_mshr_pack_index];
            assign demand_mshr_fill_done_vec[demand_mshr_pack_index] =
                demand_mshr_fill_done_q[demand_mshr_pack_index];
            assign demand_mshr_error_vec[demand_mshr_pack_index] =
                demand_mshr_error_q[demand_mshr_pack_index];
            assign demand_mshr_wait_prefetch_vec[
                demand_mshr_pack_index] =
                demand_mshr_wait_prefetch_q[demand_mshr_pack_index];
            assign demand_mshr_addr_vec[
                demand_mshr_pack_index*64 +: 64] =
                demand_mshr_addr_q[demand_mshr_pack_index];
            assign demand_mshr_txn_id_vec[
                demand_mshr_pack_index*
                    `OPENRV64_ICX_TXN_ID_WIDTH +:
                    `OPENRV64_ICX_TXN_ID_WIDTH] =
                demand_mshr_txn_id_q[demand_mshr_pack_index];
            assign demand_mshr_epoch_vec[
                demand_mshr_pack_index*SPECULATION_EPOCH_WIDTH +:
                    SPECULATION_EPOCH_WIDTH] =
                demand_mshr_epoch_q[demand_mshr_pack_index];
        end
    endgenerate

    openrv64_l1d_demand_mshr_select #(
        .ENTRIES(DEMAND_MSHRS),
        .INDEX_WIDTH(DEMAND_MSHR_INDEX_WIDTH),
        .EPOCH_WIDTH(SPECULATION_EPOCH_WIDTH)
    ) u_demand_mshr_select (
        .valid_i(demand_mshr_valid_vec),
        .issued_i(demand_mshr_issued_vec),
        .complete_i(demand_mshr_complete_vec),
        .fill_done_i(demand_mshr_fill_done_vec),
        .error_i(demand_mshr_error_vec),
        .wait_prefetch_i(demand_mshr_wait_prefetch_vec),
        .addr_i(demand_mshr_addr_vec),
        .txn_id_i(demand_mshr_txn_id_vec),
        .epoch_i(demand_mshr_epoch_vec),
        .miss_addr_i(l1_miss_addr),
        .current_epoch_i(speculation_epoch_q),
        .response_for_dcache_i(icx_response_for_dcache),
        .response_txn_id_i(icx_resp_txn_id_i),
        .prefetch_response_match_i(prefetch_mshr_response_match_r),
        .prefetch_response_addr_i(
            prefetch_mshr_addr_q[prefetch_mshr_response_index_r]),
        .match_found_o(demand_mshr_match_found_r),
        .match_index_o(demand_mshr_match_index_r),
        .free_found_o(demand_mshr_free_found_r),
        .free_index_o(demand_mshr_free_index_r),
        .issue_found_o(demand_mshr_issue_found_r),
        .issue_index_o(demand_mshr_issue_index_r),
        .response_match_o(demand_mshr_response_match_r),
        .response_index_o(demand_mshr_response_index_r),
        .fill_found_o(demand_mshr_fill_found_r),
        .fill_index_o(demand_mshr_fill_index_r),
        .prefetch_response_match_o(
            demand_mshr_prefetch_response_match_r),
        .prefetch_response_index_o(
            demand_mshr_prefetch_response_index_r),
        .any_valid_o(demand_mshr_any_valid_r)
    );

    always @* begin
        demand_prefetch_fill_hit_r = 1'b0;
        demand_prefetch_fill_index_r =
            {FILL_BUFFER_INDEX_WIDTH{1'b0}};
        for (demand_prefetch_fill_scan = 0;
             demand_prefetch_fill_scan < FILL_BUFFER_LINES;
             demand_prefetch_fill_scan =
                 demand_prefetch_fill_scan + 1) begin
            if (!demand_prefetch_fill_hit_r &&
                fill_buffer_valid_q[demand_prefetch_fill_scan] &&
                (fill_buffer_addr_q[demand_prefetch_fill_scan] ==
                 l1_miss_addr)) begin
                demand_prefetch_fill_hit_r = 1'b1;
                demand_prefetch_fill_index_r =
                    FILL_BUFFER_INDEX_WIDTH'(
                        demand_prefetch_fill_scan);
            end
        end
    end

    always @* begin
        prefetch_inflight_demand_match_r =
            prefetch_command_inflight &&
            (request_addr_q == l1_miss_addr);
        for (demand_prefetch_inflight_scan = 0;
             demand_prefetch_inflight_scan < PREFETCH_OUTSTANDING;
             demand_prefetch_inflight_scan =
                 demand_prefetch_inflight_scan + 1) begin
            if (prefetch_mshr_valid_q[demand_prefetch_inflight_scan] &&
                (prefetch_mshr_addr_q[demand_prefetch_inflight_scan] ==
                 l1_miss_addr))
                prefetch_inflight_demand_match_r = 1'b1;
        end
    end

    always @* begin
        demand_waiter_response_found_r = 1'b0;
        demand_waiter_response_tag_r = {REQ_TAG_WIDTH{1'b0}};
        demand_waiter_response_mshr_r =
            {DEMAND_MSHR_INDEX_WIDTH{1'b0}};
        for (demand_waiter_scan = 0;
             demand_waiter_scan < DEMAND_WAITER_COUNT;
             demand_waiter_scan = demand_waiter_scan + 1) begin
            if (!demand_waiter_response_found_r &&
                demand_waiter_valid_q[demand_waiter_scan] &&
                demand_mshr_complete_q[
                    demand_waiter_mshr_q[demand_waiter_scan]] &&
                (demand_mshr_fill_done_q[
                     demand_waiter_mshr_q[demand_waiter_scan]] ||
                 demand_mshr_error_q[
                     demand_waiter_mshr_q[demand_waiter_scan]]) &&
                (demand_mshr_epoch_q[
                    demand_waiter_mshr_q[demand_waiter_scan]] ==
                 speculation_epoch_q)) begin
                demand_waiter_response_found_r = 1'b1;
                demand_waiter_response_tag_r =
                    REQ_TAG_WIDTH'(demand_waiter_scan);
                demand_waiter_response_mshr_r =
                    demand_waiter_mshr_q[demand_waiter_scan];
            end
        end
    end

    always @* begin
        demand_waiter_other_found_r = 1'b0;
        for (demand_waiter_other_scan = 0;
             demand_waiter_other_scan < DEMAND_WAITER_COUNT;
             demand_waiter_other_scan =
                 demand_waiter_other_scan + 1) begin
            if (demand_waiter_valid_q[demand_waiter_other_scan] &&
                (REQ_TAG_WIDTH'(demand_waiter_other_scan) !=
                 demand_waiter_response_tag_r) &&
                (demand_waiter_mshr_q[demand_waiter_other_scan] ==
                 demand_waiter_response_mshr_r))
                demand_waiter_other_found_r = 1'b1;
        end
    end

    always @* begin
        demand_fill_waiter_found_r = 1'b0;
        for (demand_fill_waiter_scan = 0;
             demand_fill_waiter_scan < DEMAND_WAITER_COUNT;
             demand_fill_waiter_scan =
                 demand_fill_waiter_scan + 1) begin
            if (demand_waiter_valid_q[demand_fill_waiter_scan] &&
                (demand_waiter_mshr_q[demand_fill_waiter_scan] ==
                 demand_mshr_fill_selected_index))
                demand_fill_waiter_found_r = 1'b1;
        end
    end

    always @* begin
        demand_response_data_r =
            demand_mshr_data_q[demand_waiter_response_mshr_r];
        for (demand_merge_byte = 0;
             demand_merge_byte < `OPENRV64_ICX_LINE_STRB_WIDTH;
             demand_merge_byte = demand_merge_byte + 1) begin
            if (demand_overlay_needed &&
                demand_overlay_strb[demand_merge_byte])
                demand_response_data_r[demand_merge_byte*8 +: 8] =
                    demand_overlay_line[demand_merge_byte*8 +: 8];
        end
    end

    always @* begin
        demand_fill_data_r =
            demand_mshr_data_q[demand_mshr_fill_selected_index];
        for (demand_fill_merge_byte = 0;
             demand_fill_merge_byte < `OPENRV64_ICX_LINE_STRB_WIDTH;
             demand_fill_merge_byte = demand_fill_merge_byte + 1) begin
            if (demand_mshr_store_strb_q[
                    demand_mshr_fill_selected_index][
                        demand_fill_merge_byte])
                demand_fill_data_r[demand_fill_merge_byte*8 +: 8] =
                    demand_mshr_store_data_q[
                        demand_mshr_fill_selected_index][
                        demand_fill_merge_byte*8 +: 8];
        end
    end

    wire l1_miss_fire = l1_miss_valid && l1_miss_ready;
    // The synchronous array response carries its own stable request tag, so
    // it does not need admission-time ordering state.  This also avoids the
    // invalid operation of trying to remove a newly classified miss from the
    // tail of a FIFO while an older backpressured hit remains at its head.
    wire l1_response_tag_push =
        (SYNC_TAG_LOOKUP == 0) && l1_request_fire &&
        request_needs_normal_response && !l1_miss_fire;
    wire l1_response_tag_pop = (SYNC_TAG_LOOKUP == 0) &&
                               l1_response_fire;
    openrv64_l1d_lsu_order #(
        .TAG_WIDTH(L1_REQ_TAG_WIDTH),
        .DEPTH(REQ_DEPTH)
    ) u_lsu_order (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .push_i(l1_response_tag_push),
        .push_tag_i(l1_request_identity),
        .pop_i(l1_response_tag_pop),
        .full_o(response_tag_full),
        .empty_o(response_tag_empty),
        .head_tag_o(response_fifo_head_identity),
        .count_o(response_tag_count_q)
    );
    assign l1_miss_ready =
        !demand_waiter_valid_q[l1_miss_tag] &&
        (demand_mshr_match_found_r || demand_mshr_free_found_r);
    assign demand_response_valid =
        demand_waiter_response_found_r && demand_overlay_ready &&
        !speculation_barrier_event;
    assign demand_response_fire = demand_response_valid && resp_ready_i;
    assign l1_fill_valid = demand_mshr_fill_hold_valid_q;
    assign l1_fill_addr =
        demand_mshr_addr_q[demand_mshr_fill_selected_index];
    assign l1_fill_data = demand_fill_data_r;
    assign l1_fill_aged = 1'b0;
    wire l1_fill_fire = l1_fill_valid && l1_fill_ready;

    // Keep a small unordered candidate pool, but select and launch entries by
    // distance from the current stream anchor.  Reusing the lowest-numbered
    // free slot therefore cannot reorder line +3 ahead of line +2.
    always @* begin
        prefetch_candidate_free_found_r = 1'b0;
        prefetch_candidate_free_index_r =
            {PREFETCH_QUEUE_INDEX_WIDTH{1'b0}};
        prefetch_queued_demand_match_r = 1'b0;
        for (prefetch_queue_scan = 0;
             prefetch_queue_scan < PREFETCH_QUEUE_LINES;
             prefetch_queue_scan = prefetch_queue_scan + 1) begin
            if (!prefetch_candidate_free_found_r &&
                !prefetch_candidate_valid_q[prefetch_queue_scan]) begin
                prefetch_candidate_free_found_r = 1'b1;
                prefetch_candidate_free_index_r =
                    prefetch_queue_scan[PREFETCH_QUEUE_INDEX_WIDTH-1:0];
            end
            if (prefetch_candidate_valid_q[prefetch_queue_scan] &&
                demand_request_fire && !req_write_i && l1_req_cacheable &&
                !req_lock_i &&
                (prefetch_candidate_addr_q[prefetch_queue_scan] ==
                 demand_line_addr))
                prefetch_queued_demand_match_r = 1'b1;
        end
    end

    // Refill the candidate pool autonomously, one address per cycle, from the
    // nearest missing line in the adaptive window.  This is a depth/degree
    // window: increasing it retains +1 and adds +2..+N instead of replacing the
    // nearest request with one farther request.
    always @* begin
        prefetch_generate_valid_r = 1'b0;
        prefetch_generate_addr_r = 64'd0;
        prefetch_generate_index_r =
            {PREFETCH_WINDOW_INDEX_WIDTH{1'b0}};
        prefetch_generate_stream_r =
            {PREFETCH_STREAM_INDEX_WIDTH{1'b0}};
        prefetch_generate_duplicate_r = 1'b0;
        prefetch_generate_window_advance_r = 64'sd0;
        prefetch_generate_window_addr_r = 64'd0;
        for (prefetch_depth_scan = 1;
             prefetch_depth_scan <= PREFETCH_MAX_DISTANCE;
             prefetch_depth_scan = prefetch_depth_scan + 1) begin
            for (prefetch_generate_stream_scan = 0;
                 prefetch_generate_stream_scan < PREFETCH_STREAMS;
                 prefetch_generate_stream_scan =
                     prefetch_generate_stream_scan + 1) begin
                prefetch_generate_window_advance_r =
                    prefetch_generate_stride_q[
                        prefetch_generate_stream_scan] *
                    prefetch_depth_scan;
                prefetch_generate_window_addr_r =
                    $unsigned($signed(prefetch_last_line_q[
                        prefetch_generate_stream_scan]) +
                        prefetch_generate_window_advance_r);
                prefetch_generate_duplicate_r = 1'b0;
                if (prefetch_command_inflight &&
                    (request_addr_q == prefetch_generate_window_addr_r))
                    prefetch_generate_duplicate_r = 1'b1;
                for (prefetch_duplicate_mshr_scan = 0;
                     prefetch_duplicate_mshr_scan < PREFETCH_OUTSTANDING;
                     prefetch_duplicate_mshr_scan =
                         prefetch_duplicate_mshr_scan + 1) begin
                    if (prefetch_mshr_valid_q[
                            prefetch_duplicate_mshr_scan] &&
                        (prefetch_mshr_addr_q[
                             prefetch_duplicate_mshr_scan] ==
                         prefetch_generate_window_addr_r))
                        prefetch_generate_duplicate_r = 1'b1;
                end
                if (l1_mem_valid && !l1_mem_write &&
                    active_req_cacheable_q &&
                    ({l1_mem_addr[63:6], 6'b0} ==
                     prefetch_generate_window_addr_r))
                    prefetch_generate_duplicate_r = 1'b1;
                for (prefetch_duplicate_scan = 0;
                     prefetch_duplicate_scan < PREFETCH_QUEUE_LINES;
                     prefetch_duplicate_scan =
                         prefetch_duplicate_scan + 1) begin
                    if (prefetch_candidate_valid_q[
                            prefetch_duplicate_scan] &&
                        (prefetch_candidate_addr_q[
                             prefetch_duplicate_scan] ==
                         prefetch_generate_window_addr_r))
                        prefetch_generate_duplicate_r = 1'b1;
                end
                for (prefetch_duplicate_fill_scan = 0;
                     prefetch_duplicate_fill_scan < FILL_BUFFER_LINES;
                     prefetch_duplicate_fill_scan =
                         prefetch_duplicate_fill_scan + 1) begin
                    if (fill_buffer_valid_q[
                            prefetch_duplicate_fill_scan] &&
                        (fill_buffer_addr_q[
                             prefetch_duplicate_fill_scan] ==
                         prefetch_generate_window_addr_r))
                        prefetch_generate_duplicate_r = 1'b1;
                end
                if (!prefetch_generate_valid_r &&
                    (PREFETCH_ENABLE != 0) && (ENABLE != 0) &&
                    !speculation_barrier_event &&
                    !atomic_active_q &&
                    !(req_valid_i && req_lock_i) &&
                    prefetch_train_valid_q[
                        prefetch_generate_stream_scan] &&
                    prefetch_generation_active_q[
                        prefetch_generate_stream_scan] &&
                    !prefetch_boundary_probe_wait_q[
                        prefetch_generate_stream_scan] &&
                    (!prefetch_stream_page_end[
                         prefetch_generate_stream_scan] ||
                     prefetch_stream_long_q[
                         prefetch_generate_stream_scan] ||
                     (prefetch_depth_scan == 1)) &&
                    !(prefetch_train_event &&
                      (prefetch_train_index_r ==
                       PREFETCH_STREAM_INDEX_WIDTH'(
                           prefetch_generate_stream_scan))) &&
                    !prefetch_invalidate_fire &&
                    (prefetch_depth_scan <= prefetch_depth_q) &&
                    ((PREFETCH_PAGE_GATING == 0) ||
                     prefetch_stream_long_q[
                         prefetch_generate_stream_scan] ||
                     (prefetch_depth_scan <=
                      PREFETCH_SHORT_MAX_DEPTH_VALUE)) &&
                    ((PREFETCH_PAGE_GATING == 0) ||
                     prefetch_stream_long_q[
                         prefetch_generate_stream_scan] ||
                     (prefetch_generate_window_addr_r[
                          63:PREFETCH_PAGE_OFFSET_BITS] ==
                      prefetch_last_line_q[
                          prefetch_generate_stream_scan][
                              63:PREFETCH_PAGE_OFFSET_BITS]) ||
                     (prefetch_stream_page_end[
                          prefetch_generate_stream_scan] &&
                      (prefetch_depth_scan == 1))) &&
                    !prefetch_window_issued_q[
                        prefetch_generate_stream_scan][
                            prefetch_depth_scan - 1] &&
                    (PREFETCH_CACHEABLE_SIZE != 0) &&
                    ((prefetch_generate_window_addr_r -
                      PREFETCH_CACHEABLE_BASE) <
                     PREFETCH_CACHEABLE_SIZE) &&
                    !atomic_hot_match(prefetch_generate_window_addr_r) &&
                    !prefetch_generate_duplicate_r) begin
                    prefetch_generate_valid_r = 1'b1;
                    prefetch_generate_addr_r =
                        prefetch_generate_window_addr_r;
                    prefetch_generate_index_r =
                        PREFETCH_WINDOW_INDEX_WIDTH'(
                            prefetch_depth_scan - 1);
                    prefetch_generate_stream_r =
                        PREFETCH_STREAM_INDEX_WIDTH'(
                            prefetch_generate_stream_scan);
                end
            end
        end
    end

    always @* begin
        prefetch_launch_found_r = 1'b0;
        prefetch_launch_index_r =
            {PREFETCH_QUEUE_INDEX_WIDTH{1'b0}};
        prefetch_launch_addr_r = 64'd0;
        prefetch_launch_store_conflict_r = 1'b0;
        prefetch_launch_window_advance_r = 64'sd0;
        prefetch_launch_window_addr_r = 64'd0;
        for (prefetch_launch_depth_scan = 1;
             prefetch_launch_depth_scan <= PREFETCH_MAX_DISTANCE;
             prefetch_launch_depth_scan =
                 prefetch_launch_depth_scan + 1) begin
            for (prefetch_launch_stream_scan = 0;
                 prefetch_launch_stream_scan < PREFETCH_STREAMS;
                 prefetch_launch_stream_scan =
                     prefetch_launch_stream_scan + 1) begin
                prefetch_launch_window_advance_r =
                    prefetch_generate_stride_q[
                        prefetch_launch_stream_scan] *
                    prefetch_launch_depth_scan;
                prefetch_launch_window_addr_r =
                    $unsigned($signed(prefetch_last_line_q[
                        prefetch_launch_stream_scan]) +
                        prefetch_launch_window_advance_r);
                for (prefetch_launch_queue_scan = 0;
                     prefetch_launch_queue_scan < PREFETCH_QUEUE_LINES;
                     prefetch_launch_queue_scan =
                         prefetch_launch_queue_scan + 1) begin
                    prefetch_launch_store_conflict_r = 1'b0;
                    for (prefetch_launch_store_scan = 0;
                         prefetch_launch_store_scan < STORE_BUFFER_LINES;
                         prefetch_launch_store_scan =
                             prefetch_launch_store_scan + 1) begin
                        if (store_buffer_valid_q[
                                prefetch_launch_store_scan] &&
                            (store_buffer_addr_q[
                                 prefetch_launch_store_scan] ==
                             prefetch_candidate_addr_q[
                                 prefetch_launch_queue_scan]))
                            prefetch_launch_store_conflict_r = 1'b1;
                    end
                    if (!prefetch_launch_found_r &&
                        prefetch_candidate_valid_q[
                            prefetch_launch_queue_scan] &&
                        (prefetch_candidate_stream_q[
                             prefetch_launch_queue_scan] ==
                         PREFETCH_STREAM_INDEX_WIDTH'(
                             prefetch_launch_stream_scan)) &&
                        (prefetch_candidate_addr_q[
                            prefetch_launch_queue_scan] ==
                         prefetch_launch_window_addr_r) &&
                        ((PREFETCH_PAGE_GATING == 0) ||
                         prefetch_stream_long_q[
                             prefetch_launch_stream_scan] ||
                         (prefetch_candidate_addr_q[
                              prefetch_launch_queue_scan][
                                  63:PREFETCH_PAGE_OFFSET_BITS] ==
                          prefetch_last_line_q[
                              prefetch_launch_stream_scan][
                                  63:PREFETCH_PAGE_OFFSET_BITS]) ||
                         (prefetch_stream_page_end[
                              prefetch_launch_stream_scan] &&
                          (prefetch_candidate_addr_q[
                               prefetch_launch_queue_scan] ==
                           prefetch_stream_next_line[
                               prefetch_launch_stream_scan]))) &&
                        !prefetch_launch_store_conflict_r) begin
                        prefetch_launch_found_r = 1'b1;
                        prefetch_launch_index_r =
                            prefetch_launch_queue_scan[
                                PREFETCH_QUEUE_INDEX_WIDTH-1:0];
                        prefetch_launch_addr_r =
                            prefetch_candidate_addr_q[
                                prefetch_launch_queue_scan];
                    end
                end
            end
        end
    end

    // Atomic phases never consume speculative fill-buffer data.  A coherent
    // LR establishes its home reservation before this lookup.  It may use a
    // resident clean L1 line; a miss becomes an ordinary shared read because
    // the reservation already exists.  Marked writes retain a resident hit
    // pending the L2 SC disposition.
    wire refill_buffer_hit = fill_buffer_hit_r && l1_mem_valid &&
        !l1_mem_write && active_req_cacheable_q && !active_req_lock_q &&
        !speculation_barrier_event &&
        (fill_buffer_epoch_q[fill_buffer_hit_index_r] ==
         speculation_epoch_q);
    wire [511:0] refill_buffer_data =
        fill_buffer_data_q[fill_buffer_hit_index_r];
    wire [511:0] response_refill_data = icx_resp_rdata_i;
    wire [63:0] response_access_data =
        ((COHERENT_ATOMICS != 0) && request_lock_q &&
         request_write_q) ?
            {63'd0, !icx_resp_sc_success_i} :
            icx_resp_rdata_i[request_addr_q[5:3]*64 +: 64];
    wire [511:0] response_mem_data = request_line_read_q ?
        response_refill_data : {{448{1'b0}}, response_access_data};

    // Low-half transaction IDs are a shared credit pool for demand traffic
    // and posted-store drains.  Prefetches retain the upper half so their
    // existing MSHR index remains encoded directly in the transaction ID.
    always @* begin
        main_txn_free_found_r = 1'b0;
        main_txn_free_id_r =
            {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
        for (main_txn_scan = 0; main_txn_scan < MAIN_TXN_COUNT;
             main_txn_scan = main_txn_scan + 1) begin
            if (!main_txn_free_found_r &&
                !main_txn_in_use_q[main_txn_scan]) begin
                main_txn_free_found_r = 1'b1;
                main_txn_free_id_r =
                    `OPENRV64_ICX_TXN_ID_WIDTH'(main_txn_scan);
            end
        end
    end

    // Select the oldest valid entry which has not already crossed into the
    // ICX request stage.  Completed and in-flight older entries remain in the
    // FIFO for ordering and forwarding but do not block younger independent
    // stores from issuing.
    always @* begin
        store_buffer_issue_found_r = 1'b0;
        store_buffer_issue_index_r =
            {STORE_BUFFER_INDEX_WIDTH{1'b0}};
        store_buffer_issue_slot = 0;
        for (store_buffer_issue_scan = 0;
             store_buffer_issue_scan < STORE_BUFFER_LINES;
             store_buffer_issue_scan = store_buffer_issue_scan + 1) begin
            store_buffer_issue_slot =
                32'(store_buffer_head_q) + store_buffer_issue_scan;
            if (store_buffer_issue_slot >= STORE_BUFFER_LINES)
                store_buffer_issue_slot =
                    store_buffer_issue_slot - STORE_BUFFER_LINES;
            if (!store_buffer_issue_found_r &&
                (store_buffer_issue_scan < store_buffer_count_q) &&
                store_buffer_valid_q[store_buffer_issue_slot] &&
                !store_buffer_issued_q[store_buffer_issue_slot]) begin
                store_buffer_issue_found_r = 1'b1;
                store_buffer_issue_index_r =
                    store_buffer_issue_slot[
                        STORE_BUFFER_INDEX_WIDTH-1:0];
            end
        end
    end

    // Store responses may return independently of the single demand request.
    // Their transaction IDs identify the retained store-buffer entry.
    always @* begin
        store_response_match_r = 1'b0;
        store_response_index_r =
            {STORE_BUFFER_INDEX_WIDTH{1'b0}};
        for (store_response_scan = 0;
             store_response_scan < STORE_BUFFER_LINES;
             store_response_scan = store_response_scan + 1) begin
            if (!store_response_match_r &&
                store_buffer_valid_q[store_response_scan] &&
                store_buffer_issued_q[store_response_scan] &&
                !store_buffer_completed_q[store_response_scan] &&
                icx_response_for_dcache &&
                (icx_resp_txn_id_i ==
                 store_buffer_txn_id_q[store_response_scan])) begin
                store_response_match_r = 1'b1;
                store_response_index_r =
                    store_response_scan[
                        STORE_BUFFER_INDEX_WIDTH-1:0];
            end
        end
    end

    assign postable_store = l1_mem_valid && l1_mem_write &&
                            active_req_cacheable_q && active_req_posted_q;
    assign posted_store_line_data =
            {{(`OPENRV64_ICX_LINE_DATA_WIDTH-64){1'b0}}, l1_mem_wdata}
            << (l1_mem_addr[5:3] * 64);
    assign posted_store_line_strb =
            {{(`OPENRV64_ICX_LINE_STRB_WIDTH-8){1'b0}}, l1_mem_wstrb}
            << (l1_mem_addr[5:3] * 8);
    wire store_completion_fire = store_completion_valid_q &&
                                 store_resp_ready_i;
    wire store_buffer_merge = postable_store &&
        (store_buffer_count_q != 0) &&
        store_buffer_valid_q[store_buffer_newest_index] &&
        !store_buffer_issued_q[store_buffer_newest_index] &&
        (store_buffer_addr_q[store_buffer_newest_index] ==
         {l1_mem_addr[63:6], 6'b0});
    wire store_buffer_allocate = postable_store && !store_buffer_merge &&
        (!store_buffer_full || store_completion_fire);
    wire store_buffer_any_merge = store_buffer_merge || fast_store_fire;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        store_buffer_merge_data = fast_store_fire ?
            fast_store_line_data : posted_store_line_data;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
        store_buffer_merge_strb = fast_store_fire ?
            fast_store_line_strb : posted_store_line_strb;
    assign store_buffer_accept =
        store_buffer_merge || store_buffer_allocate;
    // Do not retain an accepted posted store as hidden state in the shared
    // L1.  A merge into the newest entry does not make a full FIFO ready:
    // the drain arbiter can issue that entry on this same edge, before the
    // store reaches l1_mem_valid.  Require a real slot, including one freed
    // by completion on the accepting edge.
    assign posted_store_request_ready =
        !(req_write_i && req_posted_i && req_cacheable_i &&
          !req_lock_i) ||
        !store_buffer_full ||
        store_completion_fire;
    wire store_buffer_watermark =
        store_buffer_count_q >=
        STORE_BUFFER_COUNT_WIDTH'(STORE_BUFFER_DRAIN_WATERMARK);
    wire store_buffer_watermark_on_allocate = store_buffer_allocate &&
        (store_buffer_count_q ==
         STORE_BUFFER_COUNT_WIDTH'(STORE_BUFFER_DRAIN_WATERMARK - 1));
    wire store_buffer_head_timeout =
        (store_buffer_count_q != 0) &&
        store_buffer_valid_q[store_buffer_head_q] &&
        (store_buffer_age_q[store_buffer_head_q] ==
         STORE_BUFFER_TIMEOUT_LAST);
    assign store_barrier_busy_o =
        speculation_barrier_i || store_barrier_active_q;
    // When draining catches the FIFO tail, leave a partial newest line open
    // for adjacent stores to finish it. A different-line allocation makes
    // this entry no longer newest and therefore immediately drainable.
    // Timeout and correctness-forced drains override the hold.
    wire store_buffer_issue_is_newest =
        store_buffer_issue_index_r == store_buffer_newest_index;
    wire store_buffer_issue_timeout =
        store_buffer_issue_found_r &&
        (store_buffer_age_q[store_buffer_issue_index_r] ==
         STORE_BUFFER_TIMEOUT_LAST);
    wire store_buffer_hold_partial_newest =
        store_buffer_issue_found_r && store_buffer_issue_is_newest &&
        (store_buffer_strb_q[store_buffer_issue_index_r] !=
         {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b1}}) &&
        !store_buffer_issue_timeout && !store_buffer_force_drain;
    wire store_buffer_drain_request =
        store_buffer_issue_found_r &&
        (store_buffer_drain_active_q || store_buffer_watermark ||
         store_buffer_head_timeout || store_buffer_force_drain) &&
        !(store_buffer_any_merge && store_buffer_issue_is_newest) &&
        !store_buffer_hold_partial_newest;

    wire main_response_identity_match =
        icx_response_for_dcache &&
        (icx_resp_txn_id_i == request_txn_id_q);
    wire main_sc_response_pending = (COHERENT_ATOMICS != 0) &&
        icx_resp_valid_i &&
        (backend_state_q == BACKEND_WAIT) &&
        main_response_identity_match && request_lock_q && request_write_q;
    wire [`OPENRV64_ICX_SC_RESULT_WIDTH-1:0] main_sc_result =
        icx_resp_rdata_i[`OPENRV64_ICX_SC_RESULT_WIDTH-1:0];
    wire main_sc_success_exclusive = main_sc_response_pending &&
        icx_resp_sc_success_i &&
        (main_sc_result == `OPENRV64_ICX_SC_SUCCESS_EXCLUSIVE);
    // Unknown successful dispositions are also dropped.  Only the explicit
    // exclusive code is allowed to retain a private copy.
    wire main_sc_success_drop = main_sc_response_pending &&
        icx_resp_sc_success_i && !main_sc_success_exclusive;
    assign lock_invalidate_request = !locked_line_invalidated_q &&
        (((COHERENT_ATOMICS == 0) && req_valid_i && req_lock_i) ||
         main_sc_success_drop);
    wire main_response_fire = response_fire &&
        (backend_state_q == BACKEND_WAIT) &&
        main_response_identity_match;
    wire demand_mshr_response_fire = response_fire &&
        demand_mshr_response_match_r;
    wire prefetch_response_fire = response_fire &&
        prefetch_mshr_response_match_r;
    wire store_response_fire = response_fire && store_response_match_r;
    wire prefetch_response_claim_existing =
        prefetch_response_fire &&
        demand_mshr_prefetch_response_match_r;
    wire prefetch_response_claim_new =
        prefetch_response_fire && l1_miss_fire &&
        !demand_mshr_match_found_r &&
        (prefetch_mshr_addr_q[prefetch_mshr_response_index_r] ==
         l1_miss_addr);
    wire prefetch_response_claimed =
        prefetch_response_claim_existing ||
        prefetch_response_claim_new;
    wire prefetch_slot_available =
        (fill_buffer_free_count_r > PREFETCH_DEMAND_RESERVE) ||
        fill_buffer_prefetch_found_r;
    wire prefetch_response_uses_free =
        fill_buffer_free_count_r > PREFETCH_DEMAND_RESERVE;
    // A prefetch may launch alongside a store.  The store poisons that
    // transaction below, so the returned pre-store line cannot enter a fill
    // buffer even if the store remains backpressured for many cycles.
    wire prefetch_launch_store_pending =
        store_request_pending &&
        (prefetch_launch_addr_r == demand_line_addr);
    wire [FILL_BUFFER_INDEX_WIDTH-1:0]
        next_fill_buffer_prefetch_replace =
            (fill_buffer_prefetch_index_r ==
             FILL_BUFFER_INDEX_WIDTH'(FILL_BUFFER_LINES - 1)) ?
            {FILL_BUFFER_INDEX_WIDTH{1'b0}} :
            fill_buffer_prefetch_index_r + 1'b1;
    wire prefetch_launch = (PREFETCH_ENABLE != 0) &&
        (ENABLE != 0) && (backend_state_q == BACKEND_IDLE) &&
        !speculation_barrier_event &&
        !(req_valid_i && req_lock_i) &&
        !atomic_active_q &&
        !coherent_lr_reservation_request &&
        !store_buffer_drain_request &&
        !demand_mshr_issue_found_r &&
        !demand_load_store_conflict_r &&
        !l1_mem_valid &&
        !atomic_hot_match(prefetch_launch_addr_r) &&
        prefetch_launch_found_r && prefetch_slot_available &&
        prefetch_mshr_free_found_r;
    wire prefetch_candidate_queue = prefetch_generate_valid_r &&
        prefetch_candidate_free_found_r;
    wire prefetch_candidate_drop = prefetch_generate_valid_r &&
        !prefetch_candidate_free_found_r;
    wire prefetch_generate_boundary_probe =
        prefetch_generate_valid_r &&
        prefetch_stream_page_end[prefetch_generate_stream_r] &&
        !prefetch_stream_long_q[prefetch_generate_stream_r] &&
        (prefetch_generate_index_r ==
         {PREFETCH_WINDOW_INDEX_WIDTH{1'b0}}) &&
        (prefetch_generate_addr_r ==
         prefetch_stream_next_line[prefetch_generate_stream_r]);
    wire prefetch_inflight_late_match = prefetch_command_inflight &&
        !prefetch_late_reported_q && demand_request_fire && !req_write_i &&
        l1_req_cacheable && (demand_line_addr == request_addr_q);
    wire prefetch_late_match = prefetch_inflight_late_match ||
                               prefetch_mshr_late_match_r ||
                               prefetch_queued_demand_match_r;
    wire prefetch_current_invalidated = prefetch_command_inflight &&
        prefetch_invalidate_fire &&
        (l1_invalidate_all ||
         ({l1_invalidate_addr[63:6], 6'b0} == request_addr_q));
    wire prefetch_current_store_pending = prefetch_command_inflight &&
        store_request_pending &&
        (demand_line_addr == request_addr_q);
    wire prefetch_mshr_response_invalidated =
        prefetch_mshr_response_match_r && prefetch_invalidate_fire &&
        (l1_invalidate_all ||
         ({l1_invalidate_addr[63:6], 6'b0} ==
          prefetch_mshr_addr_q[prefetch_mshr_response_index_r]));
    wire prefetch_mshr_response_store_pending =
        prefetch_mshr_response_match_r && store_request_pending &&
        (demand_line_addr ==
         prefetch_mshr_addr_q[prefetch_mshr_response_index_r]);
    wire prefetch_response_discard =
        prefetch_mshr_discard_q[prefetch_mshr_response_index_r] ||
        speculation_barrier_event ||
        (prefetch_mshr_epoch_q[prefetch_mshr_response_index_r] !=
         speculation_epoch_q) ||
        prefetch_mshr_response_invalidated ||
        prefetch_mshr_response_store_pending;
    // Attribute the speculative state actually destroyed by a visible store.
    // Counts exclude state which was already marked for discard, so a held
    // store request does not repeatedly count the same object on every cycle.
    // A demand MSHR waiting on a prefetch is counted separately because
    // poisoning that prefetch exposes demand latency even though the demand
    // MSHR itself remains valid and can issue a normal read.
    integer store_poison_queue_scan;
    integer store_poison_mshr_scan;
    integer store_poison_fill_scan;
    integer store_poison_demand_scan;
    integer store_overlay_demand_scan;
    integer store_poison_prefetch_queue_count_r;
    integer store_poison_prefetch_command_count_r;
    integer store_poison_prefetch_mshr_count_r;
    integer store_poison_prefetch_fill_count_r;
    integer store_poison_demand_wait_prefetch_count_r;
    integer store_poison_demand_fill_count_r;
    integer store_overlay_demand_mshr_count_r;
    reg store_poison_prefetch_event_r;
    reg store_poison_demand_event_r;
    reg store_poison_any_event_r;
    always @* begin
        store_poison_prefetch_queue_count_r = 0;
        store_poison_prefetch_command_count_r = 0;
        store_poison_prefetch_mshr_count_r = 0;
        store_poison_prefetch_fill_count_r = 0;
        store_poison_demand_wait_prefetch_count_r = 0;
        store_poison_demand_fill_count_r = 0;
        store_overlay_demand_mshr_count_r = 0;

        if (store_request_pending) begin
            for (store_poison_queue_scan = 0;
                 store_poison_queue_scan < PREFETCH_QUEUE_LINES;
                 store_poison_queue_scan =
                     store_poison_queue_scan + 1)
                if (prefetch_candidate_valid_q[
                        store_poison_queue_scan] &&
                    (prefetch_candidate_addr_q[
                         store_poison_queue_scan] ==
                     demand_line_addr))
                    store_poison_prefetch_queue_count_r =
                        store_poison_prefetch_queue_count_r + 1;

            if ((prefetch_current_store_pending &&
                 !request_discard_q) ||
                (prefetch_launch &&
                 prefetch_launch_store_pending))
                store_poison_prefetch_command_count_r = 1;

            for (store_poison_mshr_scan = 0;
                 store_poison_mshr_scan < PREFETCH_OUTSTANDING;
                 store_poison_mshr_scan =
                     store_poison_mshr_scan + 1) begin
                if (prefetch_mshr_valid_q[store_poison_mshr_scan] &&
                    !prefetch_mshr_discard_q[store_poison_mshr_scan] &&
                    (prefetch_mshr_addr_q[store_poison_mshr_scan] ==
                     demand_line_addr)) begin
                    store_poison_prefetch_mshr_count_r =
                        store_poison_prefetch_mshr_count_r + 1;
                    for (store_poison_demand_scan = 0;
                         store_poison_demand_scan < DEMAND_MSHRS;
                         store_poison_demand_scan =
                             store_poison_demand_scan + 1)
                        if (demand_mshr_valid_q[
                                store_poison_demand_scan] &&
                            demand_mshr_wait_prefetch_q[
                                store_poison_demand_scan] &&
                            (demand_mshr_addr_q[
                                 store_poison_demand_scan] ==
                             demand_line_addr))
                            store_poison_demand_wait_prefetch_count_r =
                                store_poison_demand_wait_prefetch_count_r +
                                1;
                end
            end

            if (prefetch_current_store_pending &&
                !request_discard_q) begin
                for (store_poison_demand_scan = 0;
                     store_poison_demand_scan < DEMAND_MSHRS;
                     store_poison_demand_scan =
                         store_poison_demand_scan + 1)
                    if (demand_mshr_valid_q[
                            store_poison_demand_scan] &&
                        demand_mshr_wait_prefetch_q[
                            store_poison_demand_scan] &&
                        (demand_mshr_addr_q[
                             store_poison_demand_scan] ==
                         demand_line_addr))
                        store_poison_demand_wait_prefetch_count_r =
                            store_poison_demand_wait_prefetch_count_r + 1;
            end

            for (store_poison_fill_scan = 0;
                 store_poison_fill_scan < FILL_BUFFER_LINES;
                 store_poison_fill_scan =
                     store_poison_fill_scan + 1) begin
                if (fill_buffer_valid_q[store_poison_fill_scan] &&
                    (fill_buffer_addr_q[store_poison_fill_scan] ==
                     demand_line_addr)) begin
                    if (fill_buffer_prefetch_q[store_poison_fill_scan])
                        store_poison_prefetch_fill_count_r =
                            store_poison_prefetch_fill_count_r + 1;
                    else
                        store_poison_demand_fill_count_r =
                            store_poison_demand_fill_count_r + 1;
                end
            end
        end

        if (l1_mem_valid && l1_mem_write && l1_mem_ready &&
            !l1_mem_error && active_req_cacheable_q &&
            !active_req_lock_q && !l1_mem_invariant) begin
            for (store_overlay_demand_scan = 0;
                 store_overlay_demand_scan < DEMAND_MSHRS;
                 store_overlay_demand_scan =
                     store_overlay_demand_scan + 1)
                if (demand_mshr_valid_q[store_overlay_demand_scan] &&
                    (demand_mshr_addr_q[store_overlay_demand_scan] ==
                     {l1_mem_addr[63:6], 6'b0}))
                    store_overlay_demand_mshr_count_r =
                        store_overlay_demand_mshr_count_r + 1;
        end

        store_poison_prefetch_event_r =
            (store_poison_prefetch_queue_count_r != 0) ||
            (store_poison_prefetch_command_count_r != 0) ||
            (store_poison_prefetch_mshr_count_r != 0) ||
            (store_poison_prefetch_fill_count_r != 0);
        store_poison_demand_event_r =
            (store_poison_demand_wait_prefetch_count_r != 0) ||
            (store_poison_demand_fill_count_r != 0);
        store_poison_any_event_r =
            store_poison_prefetch_event_r ||
            store_poison_demand_event_r;
    end
    wire prefetch_useless_replace = prefetch_response_fire &&
        !prefetch_response_discard &&
        !prefetch_response_claimed &&
        !icx_resp_error_i && !response_protocol_error &&
        !prefetch_response_uses_free && fill_buffer_prefetch_found_r;

    // A read which has not crossed ICX at the barrier is held and relabelled
    // with the new epoch.  The protocol-facing encoding and independent
    // command/data handshakes live in icx.v.
    openrv64_l1d_icx_interface #(
        .COHERENT_ATOMICS(COHERENT_ATOMICS),
        .HART_ID(HART_ID)
    ) u_icx_interface (
        .send_valid_i(backend_state_q == BACKEND_SEND),
        .suppress_read_i(speculation_barrier_event),
        .command_sent_i(command_sent_q),
        .wdata_sent_i(wdata_sent_q),
        .request_fence_i(request_fence_q),
        .request_write_i(request_write_q),
        .request_atomic_i(request_lock_q),
        .request_cacheable_i(request_cacheable_q),
        .request_line_read_i(request_line_read_q),
        .request_size_i(request_size_q),
        .request_addr_i(request_addr_q),
        .request_txn_id_i(request_txn_id_q),
        .request_wdata_i(request_wdata_q),
        .request_wstrb_i(request_wstrb_q),
        .command_fire_o(command_fire),
        .wdata_fire_o(wdata_fire),
        .icx_req_valid_o(icx_req_valid_o),
        .icx_req_ready_i(icx_req_ready_i),
        .icx_req_hart_id_o(icx_req_hart_id_o),
        .icx_req_txn_id_o(icx_req_txn_id_o),
        .icx_req_source_id_o(icx_req_source_id_o),
        .icx_req_op_o(icx_req_op_o),
        .icx_req_lock_o(icx_req_lock_o),
        .icx_req_order_o(icx_req_order_o),
        .icx_req_kind_o(icx_req_kind_o),
        .icx_req_attr_o(icx_req_attr_o),
        .icx_req_size_o(icx_req_size_o),
        .icx_req_addr_o(icx_req_addr_o),
        .icx_req_burst_len_o(icx_req_burst_len_o),
        .icx_wdata_valid_o(icx_wdata_valid_o),
        .icx_wdata_ready_i(icx_wdata_ready_i),
        .icx_wdata_hart_id_o(icx_wdata_hart_id_o),
        .icx_wdata_txn_id_o(icx_wdata_txn_id_o),
        .icx_wdata_source_id_o(icx_wdata_source_id_o),
        .icx_wdata_beat_index_o(icx_wdata_beat_index_o),
        .icx_wdata_last_o(icx_wdata_last_o),
        .icx_wdata_o(icx_wdata_o),
        .icx_wstrb_o(icx_wstrb_o),
        .response_ready_i(icx_response_ready),
        .icx_resp_valid_i(icx_resp_valid_i),
        .icx_resp_ready_o(icx_resp_ready_o),
        .icx_resp_hart_id_i(icx_resp_hart_id_i),
        .icx_resp_source_id_i(icx_resp_source_id_i),
        .icx_resp_beat_index_i(icx_resp_beat_index_i),
        .icx_resp_last_i(icx_resp_last_i),
        .response_fire_o(response_fire),
        .response_for_dcache_o(icx_response_for_dcache),
        .response_protocol_error_o(response_protocol_error)
    );

    assign store_resp_valid_o = store_completion_valid_q;
    assign store_resp_error_o = store_completion_error_q;
    assign prefetch_issued_o = command_fire && request_prefetch_q;
    // "Useful" alone does not say whether prefetching hid demand latency.
    // Split it into a completed prefetched-buffer hit and a demand which had
    // to claim an arriving/inflight prefetch after taking the miss path.
    wire prefetch_on_time_useful =
        (refill_buffer_hit && l1_mem_valid && !l1_mem_write &&
         fill_buffer_prefetch_q[fill_buffer_hit_index_r]) ||
        (l1_miss_fire && demand_prefetch_fill_hit_r);
    wire prefetch_late_useful =
        l1_miss_fire && prefetch_inflight_demand_match_r;
    assign prefetch_useful_o =
        prefetch_on_time_useful || prefetch_late_useful;
    wire [63:0] prefetch_useful_line_addr =
        l1_miss_fire ? l1_miss_addr : {l1_mem_addr[63:6], 6'b0};
    assign prefetch_late_o = prefetch_late_match;
    assign prefetch_dropped_o = prefetch_candidate_drop;
    assign prefetch_useless_o = prefetch_useless_replace;
    assign prefetch_depth_o = prefetch_depth_q;

    wire main_response_reissue = main_response_fire &&
        !request_fence_q &&
        !request_reservation_q &&
        !request_write_q &&
        (request_reissue_q ||
         (request_epoch_q != speculation_epoch_q) ||
         speculation_barrier_event);
    wire prefetch_response_buffer_available =
        prefetch_response_discard || icx_resp_error_i ||
        response_protocol_error ||
        demand_mshr_prefetch_response_match_r ||
        (l1_miss_fire &&
         (prefetch_mshr_addr_q[prefetch_mshr_response_index_r] ==
          l1_miss_addr)) ||
        prefetch_slot_available;
    wire main_response_overlay_ready =
        request_fence_q || request_reservation_q || request_write_q ||
        request_buffered_store_q ||
        normal_overlay_ready;
    assign icx_response_ready =
        ((backend_state_q == BACKEND_WAIT) &&
         main_response_identity_match &&
         main_response_overlay_ready &&
         (!main_sc_success_drop || locked_line_invalidated_q)) ||
        demand_mshr_response_match_r ||
        store_response_match_r ||
        (prefetch_mshr_response_match_r &&
         prefetch_response_buffer_available);
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] l1_mem_base_data =
        refill_buffer_hit ? refill_buffer_data : response_mem_data;
    always @* begin
        l1_mem_merged_data_r = l1_mem_base_data;
        for (l1_mem_merge_byte = 0;
             l1_mem_merge_byte < `OPENRV64_ICX_LINE_STRB_WIDTH;
             l1_mem_merge_byte = l1_mem_merge_byte + 1) begin
            if (normal_overlay_needed &&
                normal_overlay_strb[l1_mem_merge_byte])
                l1_mem_merged_data_r[l1_mem_merge_byte*8 +: 8] =
                    normal_overlay_line[l1_mem_merge_byte*8 +: 8];
        end
    end

    assign l1_mem_ready = store_buffer_accept ||
                          (refill_buffer_hit && normal_overlay_ready) ||
                          (l1_mem_valid && main_response_fire &&
                           !request_buffered_store_q &&
                           !main_response_reissue);
    assign l1_mem_rdata = store_buffer_accept ? 512'd0 :
                           l1_mem_merged_data_r;
    assign l1_mem_error = l1_mem_valid && main_response_fire &&
                          !request_buffered_store_q &&
                          !main_response_reissue &&
                          (icx_resp_error_i || response_protocol_error);
    wire l1_mem_write_commit = (COHERENT_ATOMICS == 0) ||
        !active_req_lock_q ||
        (main_response_fire && main_sc_success_exclusive);

    // Clock-gating is permitted only after every controller which can make
    // autonomous progress has drained.  Resident cache lines and predictor
    // metadata are state, not work, and deliberately do not keep the clock
    // running.  Incoming probes are handled by the parent gate controller.
    always @* begin
        background_work_r = 1'b0;
        for (quiescent_fill_scan = 0;
             quiescent_fill_scan < FILL_BUFFER_LINES;
             quiescent_fill_scan = quiescent_fill_scan + 1)
            if (fill_buffer_valid_q[quiescent_fill_scan])
                background_work_r = 1'b1;
        for (quiescent_waiter_scan = 0;
             quiescent_waiter_scan < DEMAND_WAITER_COUNT;
             quiescent_waiter_scan = quiescent_waiter_scan + 1)
            if (demand_waiter_valid_q[quiescent_waiter_scan])
                background_work_r = 1'b1;
        for (quiescent_prefetch_queue_scan = 0;
             quiescent_prefetch_queue_scan < PREFETCH_QUEUE_LINES;
             quiescent_prefetch_queue_scan =
                 quiescent_prefetch_queue_scan + 1)
            if (prefetch_candidate_valid_q[
                    quiescent_prefetch_queue_scan])
                background_work_r = 1'b1;
        for (quiescent_prefetch_mshr_scan = 0;
             quiescent_prefetch_mshr_scan < PREFETCH_OUTSTANDING;
             quiescent_prefetch_mshr_scan =
                 quiescent_prefetch_mshr_scan + 1)
            if (prefetch_mshr_valid_q[quiescent_prefetch_mshr_scan])
                background_work_r = 1'b1;
        for (quiescent_freeloader_scan = 0;
             quiescent_freeloader_scan < FREELOADER_STAGES;
             quiescent_freeloader_scan = quiescent_freeloader_scan + 1)
            if (freeloader_valid_q[quiescent_freeloader_scan])
                background_work_r = 1'b1;
    end

    assign quiescent_o = l1_array_quiescent &&
        (backend_state_q == BACKEND_IDLE) &&
        !req_valid_i && !resp_valid_o && !posted_resp_valid_o &&
        !store_resp_valid_o && !l1_mem_valid && !l1_miss_valid &&
        !l1_fill_valid && !invalidate_txn_valid_q &&
        !demand_mshr_any_valid_r && !demand_mshr_fill_hold_valid_q &&
        (store_buffer_count_q == 0) && !store_buffer_drain_active_q &&
        !store_barrier_active_q && !store_barrier_fence_pending_q &&
        (main_txn_in_use_q == 0) && !freeloader_pending_store_valid_q &&
        !background_work_r;

    openrv64_l1d #(
        .ENABLE(ENABLE),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(64),
        .REFILL_DATA_WIDTH(512),
        .REQ_TAG_WIDTH(L1_REQ_TAG_WIDTH),
        .DETACH_READ_MISSES(1),
        .SYNC_TAG_LOOKUP(SYNC_TAG_LOOKUP),
        .SYNC_STORE_EXTENSION(SYNC_STORE_EXTENSION),
        .CACHE_BYTES(CACHE_BYTES),
        .LINE_BYTES(LINE_BYTES),
        .WAYS(WAYS),
        .WRITEBACK_TIMEOUT_CYCLES(WRITEBACK_TIMEOUT_CYCLES),
        .DIRTY_TIMESTAMP_WIDTH(DIRTY_TIMESTAMP_WIDTH)
    ) u_l1d (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .req_valid_i(l1_req_valid),
        .req_ready_o(l1_req_ready),
        .req_tag_i(l1_request_identity),
        .req_write_i(req_write_i),
        .req_posted_i(req_posted_i),
        .req_cacheable_i(l1_array_req_cacheable),
        .req_addr_i(req_addr_i),
        .req_wdata_i(req_wdata_i),
        .req_wstrb_i(req_wstrb_i),
        .resp_valid_o(l1_resp_valid),
        .resp_ready_i(l1_resp_ready),
        .resp_tag_o(l1_resp_identity),
        .req_rdata_o(l1_req_rdata),
        .req_error_o(l1_req_error),
        .posted_resp_valid_o(l1_posted_resp_valid),
        .posted_resp_ready_i(l1_posted_resp_ready),
        .posted_resp_tag_o(l1_posted_resp_identity),
        .miss_valid_o(l1_miss_valid),
        .miss_ready_i(l1_miss_ready),
        .miss_tag_o(l1_miss_identity),
        .miss_addr_o(l1_miss_addr),
        .miss_aged_o(l1_miss_aged),
        .fill_valid_i(l1_fill_valid),
        .fill_ready_o(l1_fill_ready),
        .fill_addr_i(l1_fill_addr),
        .fill_data_i(l1_fill_data),
        .fill_aged_i(l1_fill_aged),
        .invalidate_valid_i(l1_invalidate_valid),
        .invalidate_ready_o(l1_invalidate_ready),
        .invalidate_hit_o(l1_invalidate_hit),
        .quiescent_o(l1_array_quiescent),
        .invalidate_all_i(l1_invalidate_all),
        .invalidate_addr_i(l1_invalidate_addr),
        .age_valid_i(4'b0000),
        .age_addr_i({4*ADDR_WIDTH{1'b0}}),
        .mem_valid_o(l1_mem_valid),
        .mem_ready_i(l1_mem_ready),
        .mem_write_o(l1_mem_write),
        .mem_resident_o(l1_mem_resident),
        .mem_addr_o(l1_mem_addr),
        .mem_wdata_o(l1_mem_wdata),
        .mem_wstrb_o(l1_mem_wstrb),
        .mem_rdata_i(l1_mem_rdata),
        .mem_error_i(l1_mem_error),
        .mem_write_commit_i(l1_mem_write_commit)
    );

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            backend_state_q <= BACKEND_IDLE;
            request_txn_id_q <= {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
            request_fence_q <= 1'b0;
            request_write_q <= 1'b0;
            request_lock_q <= 1'b0;
            request_cacheable_q <= 1'b0;
            request_line_read_q <= 1'b0;
            request_size_q <= 3'd0;
            request_addr_q <= 64'd0;
            request_wdata_q <=
                {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
            request_wstrb_q <=
                {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b0}};
            request_buffered_store_q <= 1'b0;
            request_demand_q <= 1'b0;
            request_demand_mshr_q <=
                {DEMAND_MSHR_INDEX_WIDTH{1'b0}};
            request_reservation_q <= 1'b0;
            request_reissue_q <= 1'b0;
            request_epoch_q <=
                {SPECULATION_EPOCH_WIDTH{1'b0}};
            request_prefetch_q <= 1'b0;
            request_prefetch_mshr_q <=
                {PREFETCH_MSHR_INDEX_WIDTH{1'b0}};
            request_discard_q <= 1'b0;
            prefetch_late_reported_q <= 1'b0;
            command_sent_q <= 1'b0;
            wdata_sent_q <= 1'b0;
            speculation_epoch_q <=
                {SPECULATION_EPOCH_WIDTH{1'b0}};
            demand_mshr_fill_hold_valid_q <= 1'b0;
            demand_mshr_fill_hold_index_q <=
                {DEMAND_MSHR_INDEX_WIDTH{1'b0}};
            store_buffer_head_q <=
                {STORE_BUFFER_INDEX_WIDTH{1'b0}};
            store_buffer_tail_q <=
                {STORE_BUFFER_INDEX_WIDTH{1'b0}};
            store_buffer_count_q <=
                {STORE_BUFFER_COUNT_WIDTH{1'b0}};
            store_buffer_drain_active_q <= 1'b0;
            store_barrier_active_q <= 1'b0;
            store_barrier_fence_pending_q <= 1'b0;
            store_completion_valid_q <= 1'b0;
            store_completion_error_q <= 1'b0;
            fast_posted_resp_valid_q <= 1'b0;
            fast_posted_resp_tag_q <= {REQ_TAG_WIDTH{1'b0}};
            main_txn_in_use_q <= {MAIN_TXN_COUNT{1'b0}};
            for (demand_reset_index = 0;
                 demand_reset_index < DEMAND_MSHRS;
                 demand_reset_index = demand_reset_index + 1) begin
                demand_mshr_valid_q[demand_reset_index] <= 1'b0;
                demand_mshr_issued_q[demand_reset_index] <= 1'b0;
                demand_mshr_complete_q[demand_reset_index] <= 1'b0;
                demand_mshr_fill_done_q[demand_reset_index] <= 1'b0;
                demand_mshr_reissue_q[demand_reset_index] <= 1'b0;
                demand_mshr_wait_prefetch_q[
                    demand_reset_index] <= 1'b0;
                demand_mshr_addr_q[demand_reset_index] <= 64'd0;
                demand_mshr_txn_id_q[demand_reset_index] <=
                    {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
                demand_mshr_data_q[demand_reset_index] <=
                    {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
                demand_mshr_error_q[demand_reset_index] <= 1'b0;
                demand_mshr_epoch_q[demand_reset_index] <=
                    {SPECULATION_EPOCH_WIDTH{1'b0}};
                demand_mshr_store_data_q[demand_reset_index] <=
                    {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
                demand_mshr_store_strb_q[demand_reset_index] <=
                    {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b0}};
            end
            for (demand_waiter_reset_index = 0;
                 demand_waiter_reset_index < DEMAND_WAITER_COUNT;
                 demand_waiter_reset_index =
                     demand_waiter_reset_index + 1) begin
                demand_waiter_valid_q[demand_waiter_reset_index] <= 1'b0;
                demand_waiter_mshr_q[demand_waiter_reset_index] <=
                    {DEMAND_MSHR_INDEX_WIDTH{1'b0}};
                demand_waiter_epoch_q[demand_waiter_reset_index] <=
                    {TAG_OVERLAY_EPOCH_WIDTH{1'b0}};
                tag_reservation_error_q[
                    demand_waiter_reset_index] <= 1'b0;
                tag_overlay_needed_q[demand_waiter_reset_index] <= 1'b0;
                tag_overlay_owner_epoch_q[
                    demand_waiter_reset_index] <=
                    {TAG_OVERLAY_EPOCH_WIDTH{1'b0}};
                tag_overlay_word_q[demand_waiter_reset_index] <= 3'd0;
            end
            tag_overlay_read_valid_q <= 1'b0;
            tag_overlay_read_tag_q <= {REQ_TAG_WIDTH{1'b0}};
            tag_overlay_read_epoch_q <=
                {TAG_OVERLAY_EPOCH_WIDTH{1'b0}};
            tag_overlay_bypass_valid_q <= 1'b0;
            tag_overlay_bypass_tag_q <= {REQ_TAG_WIDTH{1'b0}};
            tag_overlay_epoch_q <=
                {TAG_OVERLAY_EPOCH_WIDTH{1'b0}};
            freeloader_pending_store_valid_q <= 1'b0;
            freeloader_pending_store_posted_q <= 1'b0;
            freeloader_pending_store_addr_q <= 64'd0;
            freeloader_pending_store_data_q <= 64'd0;
            freeloader_pending_store_strb_q <= 8'd0;
            for (freeloader_stage_index = 0;
                 freeloader_stage_index < FREELOADER_STAGES;
                 freeloader_stage_index =
                     freeloader_stage_index + 1) begin
                freeloader_valid_q[freeloader_stage_index] <= 1'b0;
                freeloader_tag_q[freeloader_stage_index] <=
                    {REQ_TAG_WIDTH{1'b0}};
                freeloader_data_q[freeloader_stage_index] <= 64'd0;
            end
            locked_line_invalidated_q <= 1'b0;
            lock_barrier_seen_q <= 1'b0;
            invalidate_txn_valid_q <= 1'b0;
            invalidate_txn_external_q <= 1'b0;
            invalidate_txn_all_q <= 1'b0;
            invalidate_txn_addr_q <= {ADDR_WIDTH{1'b0}};
            coherent_lr_reservation_done_q <= 1'b0;
            coherent_lr_reservation_error_q <= 1'b0;
            active_req_lock_q <= 1'b0;
            atomic_active_q <= 1'b0;
            atomic_active_line_q <= 64'd0;
            atomic_hot_replace_q <=
                {ATOMIC_HOT_INDEX_WIDTH{1'b0}};
            for (atomic_hot_reset_index = 0;
                 atomic_hot_reset_index < ATOMIC_HOT_LINES;
                 atomic_hot_reset_index =
                     atomic_hot_reset_index + 1) begin
                atomic_hot_valid_q[atomic_hot_reset_index] <= 1'b0;
                atomic_hot_line_q[atomic_hot_reset_index] <= 64'd0;
            end
            active_req_posted_q <= 1'b0;
            active_req_cacheable_q <= 1'b0;
            active_req_size_q <= 3'd0;
            fill_buffer_prefetch_replace_q <=
                {FILL_BUFFER_INDEX_WIDTH{1'b0}};
            prefetch_replace_q <=
                {PREFETCH_STREAM_INDEX_WIDTH{1'b0}};
            prefetch_depth_q <= PREFETCH_INITIAL_DEPTH;
            prefetch_waste_q <= 2'd0;
            for (prefetch_reset_stream_index = 0;
                 prefetch_reset_stream_index < PREFETCH_STREAMS;
                 prefetch_reset_stream_index =
                     prefetch_reset_stream_index + 1) begin
                prefetch_train_valid_q[
                    prefetch_reset_stream_index] <= 1'b0;
                prefetch_last_line_q[
                    prefetch_reset_stream_index] <= 64'd0;
                prefetch_stride_valid_q[
                    prefetch_reset_stream_index] <= 1'b0;
                prefetch_stride_q[
                    prefetch_reset_stream_index] <= 64'sd0;
                prefetch_confidence_q[
                    prefetch_reset_stream_index] <= 2'd0;
                prefetch_generate_stride_q[
                    prefetch_reset_stream_index] <=
                    PREFETCH_NEXT_LINE_STRIDE;
                prefetch_generation_active_q[
                    prefetch_reset_stream_index] <= 1'b0;
                prefetch_boundary_probe_wait_q[
                    prefetch_reset_stream_index] <= 1'b0;
                prefetch_boundary_probe_addr_q[
                    prefetch_reset_stream_index] <= 64'd0;
                prefetch_stream_long_q[
                    prefetch_reset_stream_index] <= 1'b0;
                for (prefetch_reset_index = 0;
                     prefetch_reset_index < PREFETCH_MAX_DISTANCE;
                     prefetch_reset_index =
                         prefetch_reset_index + 1)
                    prefetch_window_issued_q[
                        prefetch_reset_stream_index][
                            prefetch_reset_index] <= 1'b0;
            end
            for (prefetch_reset_index = 0;
                 prefetch_reset_index < PREFETCH_QUEUE_LINES;
                 prefetch_reset_index = prefetch_reset_index + 1) begin
                prefetch_candidate_valid_q[prefetch_reset_index] <= 1'b0;
                prefetch_candidate_addr_q[prefetch_reset_index] <= 64'd0;
                prefetch_candidate_stream_q[
                    prefetch_reset_index] <=
                    {PREFETCH_STREAM_INDEX_WIDTH{1'b0}};
            end
            for (prefetch_reset_index = 0;
                 prefetch_reset_index < PREFETCH_OUTSTANDING;
                 prefetch_reset_index = prefetch_reset_index + 1) begin
                prefetch_mshr_valid_q[prefetch_reset_index] <= 1'b0;
                prefetch_mshr_addr_q[prefetch_reset_index] <= 64'd0;
                prefetch_mshr_discard_q[prefetch_reset_index] <= 1'b0;
                prefetch_mshr_epoch_q[prefetch_reset_index] <=
                    {SPECULATION_EPOCH_WIDTH{1'b0}};
                prefetch_mshr_late_reported_q[
                    prefetch_reset_index] <= 1'b0;
            end
            for (buffer_reset_index = 0;
                 buffer_reset_index < FILL_BUFFER_LINES;
                 buffer_reset_index = buffer_reset_index + 1) begin
                fill_buffer_valid_q[buffer_reset_index] <= 1'b0;
                fill_buffer_addr_q[buffer_reset_index] <= 64'd0;
                fill_buffer_data_q[buffer_reset_index] <=
                    {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
                fill_buffer_prefetch_q[buffer_reset_index] <= 1'b0;
                fill_buffer_epoch_q[buffer_reset_index] <=
                    {SPECULATION_EPOCH_WIDTH{1'b0}};
            end
            for (buffer_reset_index = 0;
                 buffer_reset_index < STORE_BUFFER_LINES;
                 buffer_reset_index = buffer_reset_index + 1) begin
                store_buffer_valid_q[buffer_reset_index] <= 1'b0;
                store_buffer_addr_q[buffer_reset_index] <= 64'd0;
                store_buffer_data_q[buffer_reset_index] <=
                    {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
                store_buffer_strb_q[buffer_reset_index] <=
                    {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b0}};
                store_buffer_age_q[buffer_reset_index] <=
                    {STORE_BUFFER_AGE_WIDTH{1'b0}};
                store_buffer_issued_q[buffer_reset_index] <= 1'b0;
                store_buffer_fast_merge_q[buffer_reset_index] <= 1'b0;
                store_buffer_completed_q[buffer_reset_index] <= 1'b0;
                store_buffer_error_q[buffer_reset_index] <= 1'b0;
                store_buffer_txn_id_q[buffer_reset_index] <=
                    {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
            end
        end else begin
            case ({fast_store_fire, fast_posted_resp_pop})
                2'b10: begin
                    fast_posted_resp_valid_q <= 1'b1;
                    fast_posted_resp_tag_q <= req_tag_i;
                end
                2'b01: fast_posted_resp_valid_q <= 1'b0;
                2'b11: begin
                    fast_posted_resp_valid_q <= 1'b1;
                    fast_posted_resp_tag_q <= req_tag_i;
                end
                default: fast_posted_resp_valid_q <=
                    fast_posted_resp_valid_q;
            endcase
            if (l1_fill_fire) begin
                demand_mshr_fill_hold_valid_q <= 1'b0;
            end else if (!demand_mshr_fill_hold_valid_q &&
                         demand_mshr_fill_found_r) begin
                demand_mshr_fill_hold_valid_q <= 1'b1;
                demand_mshr_fill_hold_index_q <=
                    demand_mshr_fill_index_r;
            end

            if ((l1_response_fire && normal_overlay_bypass_match) ||
                (demand_response_fire && demand_overlay_bypass_match) ||
                (l1_request_fire && tag_overlay_bypass_valid_q &&
                 (tag_overlay_bypass_tag_q == req_tag_i)))
                tag_overlay_bypass_valid_q <= 1'b0;
            if (tag_overlay_read_request) begin
                if (tag_overlay_write &&
                    (req_tag_i == tag_overlay_read_request_tag))
                    // A read/write collision on a recycled tag has
                    // macro-specific data semantics. The bypass is valid,
                    // but the SRAM output must be refetched before it can
                    // replace that bypass under backpressure.
                    tag_overlay_read_valid_q <= 1'b0;
                else begin
                    tag_overlay_read_valid_q <= 1'b1;
                    tag_overlay_read_tag_q <=
                        tag_overlay_read_request_tag;
                    tag_overlay_read_epoch_q <=
                        tag_overlay_read_request_epoch;
                end
            end else if (tag_overlay_write &&
                         tag_overlay_read_valid_q &&
                         (req_tag_i == tag_overlay_read_tag_q))
                tag_overlay_read_valid_q <= 1'b0;
            if (tag_overlay_write) begin
                tag_overlay_bypass_valid_q <= 1'b1;
                tag_overlay_bypass_tag_q <= req_tag_i;
            end

            if (!req_valid_i || !req_lock_i)
                lock_barrier_seen_q <= 1'b0;
            else if (lock_barrier_request)
                lock_barrier_seen_q <= 1'b1;

            if (!invalidate_txn_valid_q) begin
                if (capture_external_invalidate) begin
                    invalidate_txn_valid_q <= 1'b1;
                    invalidate_txn_external_q <= 1'b1;
                    invalidate_txn_all_q <= invalidate_all_i;
                    invalidate_txn_addr_q <= invalidate_addr_i;
                end else if (capture_lock_invalidate) begin
                    invalidate_txn_valid_q <= 1'b1;
                    invalidate_txn_external_q <= 1'b0;
                    invalidate_txn_all_q <= 1'b0;
                    invalidate_txn_addr_q <= (COHERENT_ATOMICS != 0) ?
                        request_addr_q : req_addr_i;
                end
            end else if (l1_invalidate_complete) begin
                invalidate_txn_valid_q <= 1'b0;
            end

            if (!req_valid_i || !coherent_atomic_read) begin
                coherent_lr_reservation_done_q <= 1'b0;
                coherent_lr_reservation_error_q <= 1'b0;
            end
            if (l1_request_fire && coherent_atomic_read) begin
                coherent_lr_reservation_done_q <= 1'b0;
                coherent_lr_reservation_error_q <= 1'b0;
            end

            if (freeloader_pipe_advance) begin
                for (freeloader_stage_index = FREELOADER_STAGES - 1;
                     freeloader_stage_index > 0;
                     freeloader_stage_index =
                         freeloader_stage_index - 1) begin
                    freeloader_valid_q[freeloader_stage_index] <=
                        freeloader_valid_q[freeloader_stage_index - 1];
                    freeloader_tag_q[freeloader_stage_index] <=
                        freeloader_tag_q[freeloader_stage_index - 1];
                    freeloader_data_q[freeloader_stage_index] <=
                        freeloader_data_q[freeloader_stage_index - 1];
                end
                freeloader_valid_q[0] <= freeloader_request_fire;
                if (freeloader_request_fire) begin
                    freeloader_tag_q[0] <= req_tag_i;
                    freeloader_data_q[0] <= freeloader_merged_data_r;
                end
            end

            if (store_buffer_accept ||
                (l1_response_fire &&
                 freeloader_pending_store_valid_q &&
                 !freeloader_pending_store_posted_q)) begin
                freeloader_pending_store_valid_q <= 1'b0;
                freeloader_pending_store_posted_q <= 1'b0;
            end
            if (l1_request_fire && req_write_i) begin
                freeloader_pending_store_valid_q <= 1'b1;
                freeloader_pending_store_posted_q <=
                    req_posted_i && l1_req_cacheable;
                freeloader_pending_store_addr_q <= req_addr_i;
                freeloader_pending_store_data_q <= req_wdata_i;
                freeloader_pending_store_strb_q <= req_wstrb_i;
            end

            // At a gated boundary, retain only the first predicted line in
            // the next region. Once that probe launches, deeper generation
            // waits until a demand consumes it as a useful prefetch.
            for (prefetch_reset_index = 0;
                 prefetch_reset_index < PREFETCH_QUEUE_LINES;
                 prefetch_reset_index = prefetch_reset_index + 1) begin
                if (prefetch_candidate_valid_q[prefetch_reset_index] &&
                    prefetch_stream_page_end[
                        prefetch_candidate_stream_q[
                            prefetch_reset_index]] &&
                    !prefetch_stream_long_q[
                        prefetch_candidate_stream_q[
                            prefetch_reset_index]] &&
                    (prefetch_candidate_addr_q[prefetch_reset_index] !=
                     prefetch_stream_next_line[
                         prefetch_candidate_stream_q[
                             prefetch_reset_index]]))
                    prefetch_candidate_valid_q[
                        prefetch_reset_index] <= 1'b0;
            end

            if (prefetch_train_event) begin
                prefetch_train_valid_q[
                    prefetch_train_index_r] <= 1'b1;
                prefetch_last_line_q[
                    prefetch_train_index_r] <= demand_line_addr;
                prefetch_generation_active_q[
                    prefetch_train_index_r] <= 1'b1;
                prefetch_generate_stride_q[
                    prefetch_train_index_r] <=
                    prefetch_stride_match ?
                        prefetch_observed_delta :
                        PREFETCH_NEXT_LINE_STRIDE;
                for (prefetch_reset_index = 0;
                     prefetch_reset_index < PREFETCH_MAX_DISTANCE;
                     prefetch_reset_index =
                         prefetch_reset_index + 1)
                    prefetch_window_issued_q[
                        prefetch_train_index_r][
                            prefetch_reset_index] <= 1'b0;
                if (prefetch_train_boundary_probe_match) begin
                    prefetch_boundary_probe_wait_q[
                        prefetch_train_index_r] <= 1'b1;
                    prefetch_boundary_probe_addr_q[
                        prefetch_train_index_r] <= demand_line_addr;
                end
                if (!prefetch_train_valid_q[
                        prefetch_train_index_r] ||
                    (prefetch_stream_page_end[
                         prefetch_train_index_r] &&
                     !prefetch_stream_long_q[
                         prefetch_train_index_r] &&
                     !prefetch_train_boundary_probe_match) ||
                    prefetch_train_replacement_r) begin
                    prefetch_stride_valid_q[
                        prefetch_train_index_r] <= 1'b0;
                    prefetch_confidence_q[
                        prefetch_train_index_r] <= 2'd0;
                    prefetch_replace_q <=
                        (prefetch_train_index_r ==
                         PREFETCH_STREAM_INDEX_WIDTH'(
                             PREFETCH_STREAMS - 1)) ?
                        {PREFETCH_STREAM_INDEX_WIDTH{1'b0}} :
                        prefetch_train_index_r + 1'b1;
                end else begin
                    if (!prefetch_delta_eligible) begin
                        prefetch_stride_valid_q[
                            prefetch_train_index_r] <= 1'b0;
                        prefetch_confidence_q[
                            prefetch_train_index_r] <= 2'd0;
                    end else if (!prefetch_stride_valid_q[
                                     prefetch_train_index_r]) begin
                        prefetch_stride_valid_q[
                            prefetch_train_index_r] <= 1'b1;
                        prefetch_stride_q[
                            prefetch_train_index_r] <=
                            prefetch_observed_delta;
                        prefetch_confidence_q[
                            prefetch_train_index_r] <= 2'd0;
                    end else if (prefetch_observed_delta ==
                                 prefetch_stride_q[
                                     prefetch_train_index_r]) begin
                        if (prefetch_confidence_q[
                                prefetch_train_index_r] != 2'b11)
                            prefetch_confidence_q[
                                prefetch_train_index_r] <=
                                prefetch_confidence_q[
                                    prefetch_train_index_r] + 1'b1;
                    end else if (prefetch_confidence_q[
                                     prefetch_train_index_r] != 0) begin
                        prefetch_confidence_q[
                            prefetch_train_index_r] <=
                            prefetch_confidence_q[
                                prefetch_train_index_r] - 1'b1;
                    end else begin
                        prefetch_stride_q[
                            prefetch_train_index_r] <=
                            prefetch_observed_delta;
                        prefetch_confidence_q[
                            prefetch_train_index_r] <= 2'd0;
                    end
                end
            end

            if (prefetch_launch)
                prefetch_candidate_valid_q[
                    prefetch_launch_index_r] <= 1'b0;
            if (demand_request_fire) begin
                for (prefetch_reset_index = 0;
                     prefetch_reset_index < PREFETCH_QUEUE_LINES;
                     prefetch_reset_index =
                         prefetch_reset_index + 1) begin
                    if (prefetch_candidate_valid_q[
                            prefetch_reset_index] &&
                        ((prefetch_candidate_addr_q[
                              prefetch_reset_index] ==
                          demand_line_addr) ||
                         (prefetch_stream_change &&
                          (prefetch_candidate_stream_q[
                               prefetch_reset_index] ==
                           prefetch_train_index_r))))
                        prefetch_candidate_valid_q[
                            prefetch_reset_index] <= 1'b0;
                end
            end
            if (prefetch_candidate_queue) begin
                prefetch_candidate_valid_q[
                    prefetch_candidate_free_index_r] <= 1'b1;
                prefetch_candidate_addr_q[
                    prefetch_candidate_free_index_r] <=
                    prefetch_generate_addr_r;
                prefetch_candidate_stream_q[
                    prefetch_candidate_free_index_r] <=
                    prefetch_generate_stream_r;
                prefetch_window_issued_q[
                    prefetch_generate_stream_r][
                        prefetch_generate_index_r] <= 1'b1;
                if (prefetch_generate_boundary_probe) begin
                    prefetch_boundary_probe_wait_q[
                        prefetch_generate_stream_r] <= 1'b1;
                    prefetch_boundary_probe_addr_q[
                        prefetch_generate_stream_r] <=
                        prefetch_generate_addr_r;
                end
            end
            if (prefetch_candidate_drop &&
                !prefetch_generate_boundary_probe)
                prefetch_window_issued_q[
                    prefetch_generate_stream_r][
                        prefetch_generate_index_r] <= 1'b1;
            if (prefetch_inflight_late_match)
                prefetch_late_reported_q <= 1'b1;
            if (prefetch_mshr_late_match_r)
                prefetch_mshr_late_reported_q[
                    prefetch_mshr_late_index_r] <= 1'b1;
            if (prefetch_current_invalidated ||
                prefetch_current_store_pending)
                request_discard_q <= 1'b1;

            if (prefetch_useful_o)
                prefetch_waste_q <= 2'd0;
            if (prefetch_useless_replace) begin
                if (prefetch_waste_q == 2'd1) begin
                    prefetch_waste_q <= 2'd0;
                    if ((PREFETCH_ADAPTIVE_ENABLE != 0) &&
                        (prefetch_depth_q >
                         PREFETCH_INITIAL_DEPTH)) begin
                        if ((prefetch_depth_q >> 1) <
                            PREFETCH_INITIAL_DEPTH)
                            prefetch_depth_q <=
                                PREFETCH_INITIAL_DEPTH;
                        else
                            prefetch_depth_q <= prefetch_depth_q >> 1;
                    end
                end else begin
                    prefetch_waste_q <= prefetch_waste_q + 1'b1;
                end
            end
            if (prefetch_stream_change) begin
                prefetch_depth_q <= PREFETCH_INITIAL_DEPTH;
                prefetch_waste_q <= 2'd0;
                prefetch_boundary_probe_wait_q[
                    prefetch_train_index_r] <= 1'b0;
                prefetch_stream_long_q[
                    prefetch_train_index_r] <= 1'b0;
            end
            if (prefetch_useful_o) begin
                for (prefetch_reset_stream_index = 0;
                     prefetch_reset_stream_index < PREFETCH_STREAMS;
                     prefetch_reset_stream_index =
                         prefetch_reset_stream_index + 1)
                    if (prefetch_boundary_probe_wait_q[
                            prefetch_reset_stream_index] &&
                        (prefetch_boundary_probe_addr_q[
                             prefetch_reset_stream_index] ==
                         prefetch_useful_line_addr)) begin
                        prefetch_boundary_probe_wait_q[
                            prefetch_reset_stream_index] <= 1'b0;
                        prefetch_stream_long_q[
                            prefetch_reset_stream_index] <= 1'b1;
                    end
            end
            if (prefetch_late_match) begin
                prefetch_waste_q <= 2'd0;
                if ((PREFETCH_ADAPTIVE_ENABLE != 0) &&
                    (prefetch_depth_q <
                     PREFETCH_MAX_DEPTH_VALUE)) begin
                    if ((prefetch_depth_q << 1) >
                        PREFETCH_MAX_DEPTH_VALUE)
                        prefetch_depth_q <=
                            PREFETCH_MAX_DEPTH_VALUE;
                    else
                        prefetch_depth_q <= prefetch_depth_q << 1;
                end
            end

            if (lock_invalidate_fire)
                locked_line_invalidated_q <= 1'b1;
            if (l1_request_fire)
                locked_line_invalidated_q <= 1'b0;

            if (l1_request_fire) begin
                tag_overlay_epoch_q <= tag_overlay_next_epoch;
                tag_overlay_owner_epoch_q[req_tag_i] <=
                    tag_overlay_next_epoch;
                // The shared L1 may admit cacheable reads through its SRAM
                // read port while a posted store is held in STATE_ACCESS
                // waiting for store-buffer space.  Those overlapping reads
                // do not replace the lower-memory operation, so they must not
                // replace the metadata which classifies l1_mem_* either.
                // Otherwise the held store stops being postable after the
                // first younger read and disappears from dirty forwarding.
                if (!(l1_mem_valid && l1_mem_write)) begin
                    // The home already performed a coherent LR. A private
                    // miss is an ordinary shared-line fill, not a second LR.
                    active_req_lock_q <=
                        req_lock_i && !coherent_atomic_read;
                    active_req_posted_q <= req_posted_i;
                    // Marked writes remain cacheable at the coherent home and
                    // may update a resident hit after an exclusive response.
                    active_req_cacheable_q <= req_cacheable_i;
                    active_req_size_q <= req_size_i;
                end
                tag_reservation_error_q[req_tag_i] <=
                    coherent_atomic_read &&
                    coherent_lr_reservation_error_q;
                tag_overlay_needed_q[req_tag_i] <=
                    request_overlay_needed;
                tag_overlay_word_q[req_tag_i] <= req_addr_i[5:3];
                if (req_lock_i && !req_write_i &&
                    (!coherent_atomic_read ||
                     !coherent_lr_reservation_error_q))
                    begin
                        atomic_active_q <= 1'b1;
                        atomic_active_line_q <=
                            {req_addr_i[63:6], 6'b0};
                    end
            end

            if (l1_miss_fire) begin
                demand_waiter_valid_q[l1_miss_tag] <= 1'b1;
                demand_waiter_mshr_q[l1_miss_tag] <=
                    demand_mshr_match_found_r ?
                    demand_mshr_match_index_r :
                    demand_mshr_free_index_r;
                demand_waiter_epoch_q[l1_miss_tag] <= l1_miss_epoch;
                if (demand_mshr_match_found_r) begin
                    for (demand_alloc_merge_byte = 0;
                         demand_alloc_merge_byte <
                             `OPENRV64_ICX_LINE_STRB_WIDTH;
                         demand_alloc_merge_byte =
                             demand_alloc_merge_byte + 1) begin
                        if (l1_miss_store_strb[
                                demand_alloc_merge_byte]) begin
                            demand_mshr_store_data_q[
                                demand_mshr_match_index_r][
                                demand_alloc_merge_byte*8 +: 8] <=
                                l1_miss_store_data[
                                    demand_alloc_merge_byte*8 +: 8];
                            demand_mshr_store_strb_q[
                                demand_mshr_match_index_r][
                                demand_alloc_merge_byte] <= 1'b1;
                        end
                    end
                end else begin
                    demand_mshr_valid_q[
                        demand_mshr_free_index_r] <= 1'b1;
                    demand_mshr_issued_q[
                        demand_mshr_free_index_r] <= 1'b0;
                    demand_mshr_complete_q[
                        demand_mshr_free_index_r] <=
                        demand_prefetch_fill_hit_r ||
                        (prefetch_response_claim_new &&
                         !prefetch_response_discard &&
                         !icx_resp_error_i &&
                         !response_protocol_error);
                    demand_mshr_fill_done_q[
                        demand_mshr_free_index_r] <= 1'b0;
                    demand_mshr_reissue_q[
                        demand_mshr_free_index_r] <= 1'b0;
                    demand_mshr_wait_prefetch_q[
                        demand_mshr_free_index_r] <=
                        prefetch_inflight_demand_match_r &&
                        !prefetch_response_claim_new;
                    demand_mshr_addr_q[
                        demand_mshr_free_index_r] <= l1_miss_addr;
                    demand_mshr_txn_id_q[
                        demand_mshr_free_index_r] <=
                        {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
                    demand_mshr_data_q[
                        demand_mshr_free_index_r] <=
                        demand_prefetch_fill_hit_r ?
                        fill_buffer_data_q[
                            demand_prefetch_fill_index_r] :
                        prefetch_response_claim_new ?
                        icx_resp_rdata_i :
                        {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
                    demand_mshr_error_q[
                        demand_mshr_free_index_r] <= 1'b0;
                    demand_mshr_epoch_q[
                        demand_mshr_free_index_r] <=
                        speculation_epoch_q;
                    demand_mshr_store_data_q[
                        demand_mshr_free_index_r] <=
                        l1_miss_store_data;
                    demand_mshr_store_strb_q[
                        demand_mshr_free_index_r] <=
                        l1_miss_store_strb;
                    if (demand_prefetch_fill_hit_r) begin
                        fill_buffer_valid_q[
                            demand_prefetch_fill_index_r] <= 1'b0;
                        fill_buffer_prefetch_q[
                            demand_prefetch_fill_index_r] <= 1'b0;
                    end
                end
            end

            // A store admitted after an older same-line miss must not alter
            // that older waiter's captured response, but it must be present
            // in the line eventually installed by the MSHR. Merge only when
            // the shared L1 completes the cacheable store against its lower
            // memory path; before that point the store is not yet committed
            // to this cache endpoint. Posted stores reach this point at FIFO
            // admission, while non-posted stores reach it on their ICX reply.
            if (l1_mem_valid && l1_mem_write && l1_mem_ready &&
                !l1_mem_error && active_req_cacheable_q &&
                !active_req_lock_q && !l1_mem_invariant) begin
                for (demand_store_merge_mshr = 0;
                     demand_store_merge_mshr < DEMAND_MSHRS;
                     demand_store_merge_mshr =
                         demand_store_merge_mshr + 1) begin
                    if (demand_mshr_valid_q[
                            demand_store_merge_mshr] &&
                        (demand_mshr_addr_q[
                             demand_store_merge_mshr] ==
                         {l1_mem_addr[63:6], 6'b0})) begin
                        for (demand_store_merge_byte = 0;
                             demand_store_merge_byte < 8;
                             demand_store_merge_byte =
                                 demand_store_merge_byte + 1) begin
                            if (l1_mem_wstrb[
                                    demand_store_merge_byte]) begin
                                demand_mshr_store_data_q[
                                    demand_store_merge_mshr][
                                    (l1_mem_addr[5:3] * 64) +
                                    (demand_store_merge_byte * 8) +:
                                    8] <= l1_mem_wdata[
                                        demand_store_merge_byte*8 +:
                                        8];
                                demand_mshr_store_strb_q[
                                    demand_store_merge_mshr][
                                    (l1_mem_addr[5:3] * 8) +
                                    demand_store_merge_byte] <= 1'b1;
                            end
                        end
                    end
                end
            end

            // A marked read begins the local AMO interval.  Preserve learned
            // stream state and queued unrelated candidates, but do not issue
            // or generate speculative traffic until the marked write has
            // completed.  A failed read has no write phase.
            if (main_response_fire && request_lock_q &&
                ((request_write_q) || icx_resp_error_i ||
                 response_protocol_error))
                atomic_active_q <= 1'b0;

            if (lock_invalidate_fire) begin
                if (!atomic_hot_match_found_r) begin
                    atomic_hot_valid_q[
                        atomic_hot_invalid_found_r ?
                        atomic_hot_invalid_index_r :
                        atomic_hot_replace_q] <= 1'b1;
                    atomic_hot_line_q[
                        atomic_hot_invalid_found_r ?
                        atomic_hot_invalid_index_r :
                        atomic_hot_replace_q] <=
                        {l1_invalidate_addr[63:6], 6'b0};
                    atomic_hot_replace_q <=
                        ((atomic_hot_invalid_found_r ?
                          atomic_hot_invalid_index_r :
                          atomic_hot_replace_q) ==
                         ATOMIC_HOT_INDEX_WIDTH'(
                             ATOMIC_HOT_LINES - 1)) ?
                        {ATOMIC_HOT_INDEX_WIDTH{1'b0}} :
                        (atomic_hot_invalid_found_r ?
                         atomic_hot_invalid_index_r :
                         atomic_hot_replace_q) + 1'b1;
                end
                for (prefetch_reset_stream_index = 0;
                     prefetch_reset_stream_index < PREFETCH_STREAMS;
                     prefetch_reset_stream_index =
                         prefetch_reset_stream_index + 1) begin
                    if (prefetch_train_valid_q[
                            prefetch_reset_stream_index] &&
                        (prefetch_last_line_q[
                             prefetch_reset_stream_index] ==
                         {l1_invalidate_addr[63:6], 6'b0})) begin
                        prefetch_train_valid_q[
                            prefetch_reset_stream_index] <= 1'b0;
                        prefetch_stride_valid_q[
                            prefetch_reset_stream_index] <= 1'b0;
                        prefetch_confidence_q[
                            prefetch_reset_stream_index] <= 2'd0;
                        prefetch_generation_active_q[
                            prefetch_reset_stream_index] <= 1'b0;
                    end
                end
            end

            if (l1_response_fire) begin
                if (!(l1_request_fire &&
                      (req_tag_i == normal_response_tag)))
                    tag_overlay_needed_q[normal_response_tag] <= 1'b0;
                if (!(l1_request_fire &&
                      (req_tag_i == normal_response_tag)))
                    tag_reservation_error_q[
                        normal_response_tag] <= 1'b0;
            end

            if (demand_response_fire &&
                !(l1_request_fire &&
                  (req_tag_i == demand_waiter_response_tag_r)))
                tag_reservation_error_q[
                    demand_waiter_response_tag_r] <= 1'b0;

            if (refill_buffer_hit) begin
                fill_buffer_valid_q[fill_buffer_hit_index_r] <= 1'b0;
                fill_buffer_prefetch_q[fill_buffer_hit_index_r] <= 1'b0;
            end

            if (demand_mshr_response_fire) begin
                main_txn_in_use_q[
                    demand_mshr_txn_id_q[
                        demand_mshr_response_index_r]] <= 1'b0;
                if (demand_mshr_reissue_q[
                        demand_mshr_response_index_r] ||
                    (demand_mshr_epoch_q[
                        demand_mshr_response_index_r] !=
                     speculation_epoch_q) ||
                    speculation_barrier_event) begin
                    demand_mshr_issued_q[
                        demand_mshr_response_index_r] <= 1'b0;
                    demand_mshr_complete_q[
                        demand_mshr_response_index_r] <= 1'b0;
                    demand_mshr_fill_done_q[
                        demand_mshr_response_index_r] <= 1'b0;
                    demand_mshr_reissue_q[
                        demand_mshr_response_index_r] <= 1'b0;
                    demand_mshr_wait_prefetch_q[
                        demand_mshr_response_index_r] <= 1'b0;
                    demand_mshr_epoch_q[
                        demand_mshr_response_index_r] <=
                        speculation_barrier_event ?
                        speculation_epoch_q + 1'b1 :
                        speculation_epoch_q;
                end else begin
                    demand_mshr_complete_q[
                        demand_mshr_response_index_r] <= 1'b1;
                    demand_mshr_data_q[
                        demand_mshr_response_index_r] <=
                        icx_resp_rdata_i;
                    demand_mshr_error_q[
                        demand_mshr_response_index_r] <=
                        icx_resp_error_i || response_protocol_error;
                    if (icx_resp_error_i || response_protocol_error)
                        demand_mshr_fill_done_q[
                            demand_mshr_response_index_r] <= 1'b1;
                end
            end

            if (l1_fill_fire) begin
                demand_mshr_fill_done_q[
                    demand_mshr_fill_selected_index] <= 1'b1;
                // A miss accepted on this edge is not visible in the
                // registered waiter scan yet.  Do not free the filled MSHR
                // out from under that new waiter.
                if (!demand_fill_waiter_found_r &&
                    !(l1_miss_fire &&
                      ((demand_mshr_match_found_r ?
                        demand_mshr_match_index_r :
                        demand_mshr_free_index_r) ==
                       demand_mshr_fill_selected_index))) begin
                    demand_mshr_valid_q[
                        demand_mshr_fill_selected_index] <= 1'b0;
                    demand_mshr_complete_q[
                        demand_mshr_fill_selected_index] <= 1'b0;
                    demand_mshr_wait_prefetch_q[
                        demand_mshr_fill_selected_index] <= 1'b0;
                end
            end

            if (demand_response_fire) begin
                // A response may release an LSU tag while a new miss using
                // that tag is admitted on the same edge. Preserve the new
                // waiter's mapping instead of letting response cleanup win
                // the nonblocking assignment ordering.
                if (!(l1_miss_fire &&
                      (l1_miss_tag ==
                       demand_waiter_response_tag_r)))
                    demand_waiter_valid_q[
                        demand_waiter_response_tag_r] <= 1'b0;
                if (!(l1_request_fire &&
                      (req_tag_i == demand_waiter_response_tag_r)))
                    tag_overlay_needed_q[
                        demand_waiter_response_tag_r] <= 1'b0;
                // As with fill completion, the registered other-waiter scan
                // cannot see a miss attaching on this edge. Keep the MSHR
                // alive when that incoming waiter selects it.
                if (!demand_waiter_other_found_r &&
                    !(l1_miss_fire &&
                      ((demand_mshr_match_found_r ?
                        demand_mshr_match_index_r :
                        demand_mshr_free_index_r) ==
                       demand_waiter_response_mshr_r)) &&
                    (demand_mshr_fill_done_q[
                         demand_waiter_response_mshr_r] ||
                     (l1_fill_fire &&
                      (demand_mshr_fill_selected_index ==
                       demand_waiter_response_mshr_r)))) begin
                    demand_mshr_valid_q[
                        demand_waiter_response_mshr_r] <= 1'b0;
                    demand_mshr_issued_q[
                        demand_waiter_response_mshr_r] <= 1'b0;
                    demand_mshr_complete_q[
                        demand_waiter_response_mshr_r] <= 1'b0;
                    demand_mshr_fill_done_q[
                        demand_waiter_response_mshr_r] <= 1'b0;
                    demand_mshr_reissue_q[
                        demand_waiter_response_mshr_r] <= 1'b0;
                    demand_mshr_wait_prefetch_q[
                        demand_waiter_response_mshr_r] <= 1'b0;
                end
            end

            for (buffer_reset_index = 0;
                 buffer_reset_index < STORE_BUFFER_LINES;
                 buffer_reset_index = buffer_reset_index + 1) begin
                if (store_buffer_valid_q[buffer_reset_index] &&
                    (store_buffer_age_q[buffer_reset_index] !=
                     STORE_BUFFER_TIMEOUT_LAST))
                    store_buffer_age_q[buffer_reset_index] <=
                        store_buffer_age_q[buffer_reset_index] + 1'b1;
            end

            if (store_completion_fire) begin
                store_completion_valid_q <= 1'b0;
                store_completion_error_q <= 1'b0;
                store_buffer_valid_q[store_buffer_head_q] <= 1'b0;
                store_buffer_age_q[store_buffer_head_q] <=
                    {STORE_BUFFER_AGE_WIDTH{1'b0}};
                store_buffer_issued_q[store_buffer_head_q] <= 1'b0;
                store_buffer_fast_merge_q[store_buffer_head_q] <= 1'b0;
                store_buffer_completed_q[store_buffer_head_q] <= 1'b0;
                store_buffer_error_q[store_buffer_head_q] <= 1'b0;
                store_buffer_txn_id_q[store_buffer_head_q] <=
                    {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
                store_buffer_head_q <=
                    (store_buffer_head_q ==
                     STORE_BUFFER_INDEX_WIDTH'(STORE_BUFFER_LINES - 1)) ?
                    {STORE_BUFFER_INDEX_WIDTH{1'b0}} :
                    store_buffer_head_q + 1'b1;
            end

            if (store_buffer_any_merge) begin
                for (store_buffer_merge_byte = 0;
                     store_buffer_merge_byte <
                         `OPENRV64_ICX_LINE_STRB_WIDTH;
                     store_buffer_merge_byte =
                         store_buffer_merge_byte + 1) begin
                    if (store_buffer_merge_strb[store_buffer_merge_byte])
                        store_buffer_data_q[store_buffer_newest_index][
                            store_buffer_merge_byte*8 +: 8] <=
                            store_buffer_merge_data[
                                store_buffer_merge_byte*8 +: 8];
                end
                store_buffer_strb_q[store_buffer_newest_index] <=
                    store_buffer_strb_q[store_buffer_newest_index] |
                    store_buffer_merge_strb;
                if (store_buffer_merge)
                    store_buffer_fast_merge_q[
                        store_buffer_newest_index] <=
                        store_buffer_fast_merge_q[
                            store_buffer_newest_index] &&
                        !l1_mem_resident;
            end else if (store_buffer_allocate) begin
                store_buffer_valid_q[store_buffer_tail_q] <= 1'b1;
                store_buffer_addr_q[store_buffer_tail_q] <=
                    {l1_mem_addr[63:6], 6'b0};
                store_buffer_data_q[store_buffer_tail_q] <=
                    posted_store_line_data;
                store_buffer_strb_q[store_buffer_tail_q] <=
                    posted_store_line_strb;
                store_buffer_age_q[store_buffer_tail_q] <=
                    {STORE_BUFFER_AGE_WIDTH{1'b0}};
                store_buffer_issued_q[store_buffer_tail_q] <= 1'b0;
                store_buffer_fast_merge_q[store_buffer_tail_q] <=
                    (SYNC_TAG_LOOKUP != 0) &&
                    (SYNC_STORE_EXTENSION != 0) &&
                    !l1_mem_resident;
                store_buffer_completed_q[store_buffer_tail_q] <= 1'b0;
                store_buffer_error_q[store_buffer_tail_q] <= 1'b0;
                store_buffer_txn_id_q[store_buffer_tail_q] <=
                    {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
                store_buffer_tail_q <=
                    (store_buffer_tail_q ==
                     STORE_BUFFER_INDEX_WIDTH'(STORE_BUFFER_LINES - 1)) ?
                    {STORE_BUFFER_INDEX_WIDTH{1'b0}} :
                    store_buffer_tail_q + 1'b1;
            end

            // A fill can make a previously absent line resident; a snoop or
            // ordering event can similarly invalidate the carried-forward
            // lookup result.  Revoke all cold-line shortcuts rather than
            // depending on line-select timing across those control paths.
            if (l1_fill_fire || capture_external_invalidate ||
                capture_lock_invalidate || speculation_barrier_i)
                for (buffer_reset_index = 0;
                     buffer_reset_index < STORE_BUFFER_LINES;
                     buffer_reset_index = buffer_reset_index + 1)
                    store_buffer_fast_merge_q[buffer_reset_index] <= 1'b0;

            if (store_response_fire) begin
                store_buffer_completed_q[store_response_index_r] <=
                    1'b1;
                store_buffer_error_q[store_response_index_r] <=
                    icx_resp_error_i || response_protocol_error;
                main_txn_in_use_q[
                    store_buffer_txn_id_q[store_response_index_r]] <=
                    1'b0;
            end

            // Present completed stores to the existing ordered completion
            // port only when they reach the FIFO head.  Younger responses may
            // arrive first, but cannot release their entries early.
            if (!store_completion_valid_q &&
                (store_buffer_count_q != 0) &&
                store_buffer_valid_q[store_buffer_head_q] &&
                store_buffer_completed_q[store_buffer_head_q]) begin
                store_completion_valid_q <= 1'b1;
                store_completion_error_q <=
                    store_buffer_error_q[store_buffer_head_q];
            end

            case ({store_buffer_allocate, store_completion_fire})
                2'b10: store_buffer_count_q <=
                    store_buffer_count_q + 1'b1;
                2'b01: store_buffer_count_q <=
                    store_buffer_count_q - 1'b1;
                default: store_buffer_count_q <= store_buffer_count_q;
            endcase

            if (store_buffer_watermark ||
                store_buffer_watermark_on_allocate ||
                store_buffer_head_timeout ||
                store_buffer_force_drain)
                store_buffer_drain_active_q <=
                    (store_buffer_count_q != 0) ||
                    store_buffer_allocate;
            if (store_completion_fire &&
                (store_buffer_count_q == 1) &&
                !store_buffer_allocate)
                store_buffer_drain_active_q <= 1'b0;
            if ((store_buffer_count_q == 0) &&
                !store_buffer_allocate)
                store_buffer_drain_active_q <= 1'b0;

            if (main_response_fire && request_fence_q &&
                !icx_resp_error_i && !response_protocol_error) begin
                store_barrier_active_q <= speculation_barrier_i;
                store_barrier_fence_pending_q <=
                    speculation_barrier_i && completion_fence_i;
            end else if (speculation_barrier_i) begin
                store_barrier_active_q <= 1'b1;
                store_barrier_fence_pending_q <= completion_fence_i;
            end else if (store_barrier_active_q &&
                         !store_barrier_fence_pending_q &&
                         (store_buffer_count_q == 0) &&
                         !store_buffer_allocate &&
                         !store_completion_valid_q &&
                         (backend_state_q == BACKEND_IDLE)) begin
                store_barrier_active_q <= 1'b0;
            end

            case (backend_state_q)
                BACKEND_IDLE: begin
                    if (coherent_lr_reservation_request &&
                        lock_backend_quiescent &&
                        main_txn_free_found_r) begin
                        // This first phase establishes the home reservation
                        // and conservatively records this L1D as a sharer.  Its
                        // returned line is deliberately ignored: the second
                        // phase must exercise the resident L1 line so snoop
                        // invalidation failures remain observable.
                        request_txn_id_q <= main_txn_free_id_r;
                        request_write_q <= 1'b0;
                        request_lock_q <= 1'b1;
                        request_cacheable_q <= req_cacheable_i;
                        request_line_read_q <= 1'b0;
                        request_size_q <= req_size_i;
                        request_addr_q <= req_addr_i;
                        request_wdata_q <=
                            {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
                        request_wstrb_q <=
                            {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b0}};
                        request_buffered_store_q <= 1'b0;
                        request_demand_q <= 1'b0;
                        request_reservation_q <= 1'b1;
                        request_reissue_q <= 1'b0;
                        request_epoch_q <= speculation_barrier_event ?
                            speculation_epoch_q + 1'b1 :
                            speculation_epoch_q;
                        request_prefetch_q <= 1'b0;
                        request_discard_q <= 1'b0;
                        prefetch_late_reported_q <= 1'b0;
                        command_sent_q <= 1'b0;
                        wdata_sent_q <= 1'b0;
                        main_txn_in_use_q[main_txn_free_id_r] <= 1'b1;
                        backend_state_q <= BACKEND_SEND;
                    end else if (store_buffer_drain_request &&
                        main_txn_free_found_r) begin
                        request_txn_id_q <= main_txn_free_id_r;
                        request_write_q <= 1'b1;
                        request_lock_q <= 1'b0;
                        request_cacheable_q <= 1'b1;
                        request_line_read_q <= 1'b0;
                        request_size_q <= 3'd6;
                        request_addr_q <=
                            store_buffer_addr_q[
                                store_buffer_issue_index_r];
                        request_wdata_q <=
                            store_buffer_data_q[
                                store_buffer_issue_index_r];
                        request_wstrb_q <=
                            store_buffer_strb_q[
                                store_buffer_issue_index_r];
                        request_buffered_store_q <= 1'b1;
                        request_demand_q <= 1'b0;
                        request_reservation_q <= 1'b0;
                        request_reissue_q <= 1'b0;
                        request_epoch_q <= speculation_epoch_q;
                        request_prefetch_q <= 1'b0;
                        request_discard_q <= 1'b0;
                        prefetch_late_reported_q <= 1'b0;
                        command_sent_q <= 1'b0;
                        wdata_sent_q <= 1'b0;
                        main_txn_in_use_q[main_txn_free_id_r] <= 1'b1;
                        store_buffer_issued_q[
                            store_buffer_issue_index_r] <= 1'b1;
                        store_buffer_fast_merge_q[
                            store_buffer_issue_index_r] <= 1'b0;
                        store_buffer_txn_id_q[
                            store_buffer_issue_index_r] <=
                            main_txn_free_id_r;
                        backend_state_q <= BACKEND_SEND;
                    end else if (store_barrier_fence_pending_q &&
                                 (store_buffer_count_q == 0) &&
                                 !store_buffer_allocate &&
                                 !store_completion_valid_q &&
                                 main_txn_free_found_r) begin
                        // Local queue drain is not the architectural completion
                        // point.  Retain the barrier until an explicit fence
                        // has crossed the coherent fabric and L2 responds.
                        request_txn_id_q <= main_txn_free_id_r;
                        request_fence_q <= 1'b1;
                        request_write_q <= 1'b0;
                        request_lock_q <= 1'b0;
                        request_cacheable_q <= 1'b0;
                        request_line_read_q <= 1'b0;
                        request_size_q <= 3'd0;
                        request_addr_q <= 64'd0;
                        request_wdata_q <=
                            {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
                        request_wstrb_q <=
                            {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b0}};
                        request_buffered_store_q <= 1'b0;
                        request_demand_q <= 1'b0;
                        request_reservation_q <= 1'b0;
                        request_reissue_q <= 1'b0;
                        request_epoch_q <= speculation_epoch_q;
                        request_prefetch_q <= 1'b0;
                        request_discard_q <= 1'b0;
                        prefetch_late_reported_q <= 1'b0;
                        command_sent_q <= 1'b0;
                        wdata_sent_q <= 1'b0;
                        main_txn_in_use_q[main_txn_free_id_r] <= 1'b1;
                        backend_state_q <= BACKEND_SEND;
                    end else if (demand_mshr_issue_found_r &&
                                 !speculation_barrier_event &&
                                 main_txn_free_found_r) begin
                        request_txn_id_q <= main_txn_free_id_r;
                        request_write_q <= 1'b0;
                        request_lock_q <= 1'b0;
                        request_cacheable_q <= 1'b1;
                        request_line_read_q <= 1'b1;
                        request_size_q <= 3'd6;
                        request_addr_q <= demand_mshr_addr_q[
                            demand_mshr_issue_index_r];
                        request_wdata_q <=
                            {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
                        request_wstrb_q <=
                            {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b0}};
                        request_buffered_store_q <= 1'b0;
                        request_demand_q <= 1'b1;
                        request_reservation_q <= 1'b0;
                        request_demand_mshr_q <=
                            demand_mshr_issue_index_r;
                        request_reissue_q <= 1'b0;
                        request_epoch_q <= demand_mshr_epoch_q[
                            demand_mshr_issue_index_r];
                        request_prefetch_q <= 1'b0;
                        request_discard_q <= 1'b0;
                        prefetch_late_reported_q <= 1'b0;
                        command_sent_q <= 1'b0;
                        wdata_sent_q <= 1'b0;
                        main_txn_in_use_q[main_txn_free_id_r] <= 1'b1;
                        backend_state_q <= BACKEND_SEND;
                    end else if (prefetch_launch) begin
                        request_txn_id_q <= PREFETCH_TXN_BASE +
                            `OPENRV64_ICX_TXN_ID_WIDTH'(
                                prefetch_mshr_free_index_r);
                        request_prefetch_mshr_q <=
                            prefetch_mshr_free_index_r;
                        request_write_q <= 1'b0;
                        request_lock_q <= 1'b0;
                        request_cacheable_q <= 1'b1;
                        request_line_read_q <= 1'b1;
                        request_size_q <= 3'd6;
                        request_addr_q <= prefetch_launch_addr_r;
                        request_wdata_q <=
                            {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
                        request_wstrb_q <=
                            {`OPENRV64_ICX_LINE_STRB_WIDTH{1'b0}};
                        request_buffered_store_q <= 1'b0;
                        request_demand_q <= 1'b0;
                        request_reservation_q <= 1'b0;
                        request_reissue_q <= 1'b0;
                        request_epoch_q <= speculation_epoch_q;
                        request_prefetch_q <= 1'b1;
                        request_discard_q <=
                            prefetch_launch_store_pending;
                        prefetch_late_reported_q <= 1'b0;
                        command_sent_q <= 1'b0;
                        wdata_sent_q <= 1'b0;
                        backend_state_q <= BACKEND_SEND;
                    end else if (l1_mem_valid && !refill_buffer_hit &&
                                 !postable_store &&
                                 !speculation_barrier_event &&
                                 !prefetch_mshr_demand_wait_r &&
                                 main_txn_free_found_r) begin
                        request_txn_id_q <= main_txn_free_id_r;
                        request_write_q <= l1_mem_write;
                        request_lock_q <= active_req_lock_q;
                        request_cacheable_q <= active_req_cacheable_q;
                        request_line_read_q <=
                            active_req_cacheable_q && !active_req_lock_q &&
                            !l1_mem_write;
                        request_size_q <=
                            (active_req_cacheable_q && !active_req_lock_q) ?
                            3'd6 : active_req_size_q;
                        request_addr_q <=
                            (active_req_cacheable_q && !active_req_lock_q) ?
                            {l1_mem_addr[63:6], 6'b0} : l1_mem_addr;
                        request_wdata_q <=
                            {{(`OPENRV64_ICX_LINE_DATA_WIDTH-64){1'b0}},
                              l1_mem_wdata} << (l1_mem_addr[5:3] * 64);
                        request_wstrb_q <=
                            {{(`OPENRV64_ICX_LINE_STRB_WIDTH-8){1'b0}},
                              l1_mem_wstrb} << (l1_mem_addr[5:3] * 8);
                        request_buffered_store_q <= 1'b0;
                        request_demand_q <= 1'b0;
                        request_reservation_q <= 1'b0;
                        request_reissue_q <= 1'b0;
                        request_epoch_q <= speculation_epoch_q;
                        request_prefetch_q <= 1'b0;
                        request_discard_q <= 1'b0;
                        prefetch_late_reported_q <= 1'b0;
                        command_sent_q <= 1'b0;
                        wdata_sent_q <= 1'b0;
                        main_txn_in_use_q[main_txn_free_id_r] <= 1'b1;
                        backend_state_q <= BACKEND_SEND;
                    end
                end

                BACKEND_SEND: begin
                    if (request_demand_q && command_fire) begin
                        demand_mshr_issued_q[
                            request_demand_mshr_q] <= 1'b1;
                        demand_mshr_txn_id_q[
                            request_demand_mshr_q] <= request_txn_id_q;
                        demand_mshr_epoch_q[
                            request_demand_mshr_q] <= request_epoch_q;
                        request_demand_q <= 1'b0;
                        command_sent_q <= 1'b0;
                        backend_state_q <= BACKEND_IDLE;
                    end else if (request_prefetch_q && command_fire) begin
                        prefetch_mshr_valid_q[
                            request_prefetch_mshr_q] <= 1'b1;
                        prefetch_mshr_addr_q[
                            request_prefetch_mshr_q] <= request_addr_q;
                        prefetch_mshr_discard_q[
                            request_prefetch_mshr_q] <=
                            request_discard_q ||
                            prefetch_current_invalidated ||
                            prefetch_current_store_pending;
                        prefetch_mshr_epoch_q[
                            request_prefetch_mshr_q] <= request_epoch_q;
                        prefetch_mshr_late_reported_q[
                            request_prefetch_mshr_q] <=
                            prefetch_late_reported_q;
                        request_prefetch_q <= 1'b0;
                        command_sent_q <= 1'b0;
                        backend_state_q <= BACKEND_IDLE;
                    end else if (command_fire) begin
                        command_sent_q <= 1'b1;
                    end
                    if (!request_demand_q && !request_prefetch_q &&
                        wdata_fire)
                        wdata_sent_q <= 1'b1;
                    if (!request_demand_q && !request_prefetch_q &&
                        (command_sent_q || command_fire) &&
                        (!request_write_q || wdata_sent_q || wdata_fire)) begin
                        if (request_buffered_store_q) begin
                            request_buffered_store_q <= 1'b0;
                            command_sent_q <= 1'b0;
                            wdata_sent_q <= 1'b0;
                            backend_state_q <= BACKEND_IDLE;
                        end else begin
                            backend_state_q <= BACKEND_WAIT;
                        end
                    end
                end

                BACKEND_WAIT: begin
                    if (main_response_fire) begin
                        if (request_reservation_q) begin
                            main_txn_in_use_q[request_txn_id_q] <= 1'b0;
                            request_reservation_q <= 1'b0;
                            coherent_lr_reservation_done_q <= 1'b1;
                            coherent_lr_reservation_error_q <=
                                icx_resp_error_i ||
                                response_protocol_error;
                            request_reissue_q <= 1'b0;
                            backend_state_q <= BACKEND_IDLE;
                        end else if (main_response_reissue) begin
                            request_reissue_q <= 1'b0;
                            request_epoch_q <=
                                speculation_barrier_event ?
                                speculation_epoch_q + 1'b1 :
                                speculation_epoch_q;
                            command_sent_q <= 1'b0;
                            wdata_sent_q <= 1'b0;
                            backend_state_q <= BACKEND_SEND;
                        end else begin
                            main_txn_in_use_q[request_txn_id_q] <= 1'b0;
                            request_fence_q <= 1'b0;
                            request_reissue_q <= 1'b0;
                            backend_state_q <= BACKEND_IDLE;
                        end
                    end
                end

                default: backend_state_q <= BACKEND_IDLE;
            endcase

            if (prefetch_response_fire) begin
                prefetch_mshr_valid_q[
                    prefetch_mshr_response_index_r] <= 1'b0;
                prefetch_mshr_discard_q[
                    prefetch_mshr_response_index_r] <= 1'b0;
                prefetch_mshr_late_reported_q[
                    prefetch_mshr_response_index_r] <= 1'b0;
                if (prefetch_response_claim_existing) begin
                    demand_mshr_wait_prefetch_q[
                        demand_mshr_prefetch_response_index_r] <=
                        1'b0;
                    if (!prefetch_response_discard &&
                        !icx_resp_error_i &&
                        !response_protocol_error) begin
                        demand_mshr_complete_q[
                            demand_mshr_prefetch_response_index_r] <=
                            1'b1;
                        demand_mshr_data_q[
                            demand_mshr_prefetch_response_index_r] <=
                            icx_resp_rdata_i;
                        demand_mshr_error_q[
                            demand_mshr_prefetch_response_index_r] <=
                            1'b0;
                    end
                end
                if (!prefetch_response_claimed &&
                    !prefetch_response_discard &&
                    !icx_resp_error_i &&
                    !response_protocol_error) begin
                    fill_buffer_valid_q[
                        prefetch_response_uses_free ?
                        fill_buffer_free_index_r :
                        fill_buffer_prefetch_index_r] <= 1'b1;
                    fill_buffer_addr_q[
                        prefetch_response_uses_free ?
                        fill_buffer_free_index_r :
                        fill_buffer_prefetch_index_r] <=
                        prefetch_mshr_addr_q[
                            prefetch_mshr_response_index_r];
                    fill_buffer_data_q[
                        prefetch_response_uses_free ?
                        fill_buffer_free_index_r :
                        fill_buffer_prefetch_index_r] <=
                        icx_resp_rdata_i;
                    fill_buffer_prefetch_q[
                        prefetch_response_uses_free ?
                        fill_buffer_free_index_r :
                        fill_buffer_prefetch_index_r] <= 1'b1;
                    fill_buffer_epoch_q[
                        prefetch_response_uses_free ?
                        fill_buffer_free_index_r :
                        fill_buffer_prefetch_index_r] <=
                        prefetch_mshr_epoch_q[
                            prefetch_mshr_response_index_r];
                    if (!prefetch_response_uses_free)
                        fill_buffer_prefetch_replace_q <=
                            next_fill_buffer_prefetch_replace;
                end
            end

            // Translation changes and atomic admission are speculation
            // cut-points. Queued work has not escaped and is canceled. Issued
            // prefetches must still consume their ICX responses, but cannot
            // create a fill. The architectural read-miss buffer is retained
            // and reissued after its old response is consumed.
            if (speculation_barrier_event) begin
                speculation_epoch_q <= speculation_epoch_q + 1'b1;
                if ((backend_state_q == BACKEND_WAIT) &&
                    !request_write_q && !main_response_fire)
                    request_reissue_q <= 1'b1;
                if ((backend_state_q == BACKEND_SEND) &&
                    !request_write_q)
                    request_epoch_q <= speculation_epoch_q + 1'b1;
                for (demand_reset_index = 0;
                     demand_reset_index < DEMAND_MSHRS;
                     demand_reset_index =
                         demand_reset_index + 1) begin
                    if (demand_mshr_valid_q[demand_reset_index] &&
                        demand_mshr_issued_q[demand_reset_index] &&
                        !demand_mshr_complete_q[demand_reset_index] &&
                        !(demand_mshr_response_fire &&
                          (demand_mshr_response_index_r ==
                           DEMAND_MSHR_INDEX_WIDTH'(
                               demand_reset_index))))
                        demand_mshr_reissue_q[
                            demand_reset_index] <= 1'b1;
                    if (demand_mshr_valid_q[demand_reset_index] &&
                        !demand_mshr_issued_q[demand_reset_index] &&
                        !demand_mshr_complete_q[demand_reset_index]) begin
                        demand_mshr_epoch_q[
                            demand_reset_index] <=
                            speculation_epoch_q + 1'b1;
                        demand_mshr_wait_prefetch_q[
                            demand_reset_index] <= 1'b0;
                    end
                    if (demand_mshr_valid_q[demand_reset_index] &&
                        demand_mshr_complete_q[demand_reset_index]) begin
                        demand_mshr_issued_q[
                            demand_reset_index] <= 1'b0;
                        demand_mshr_complete_q[
                            demand_reset_index] <= 1'b0;
                        demand_mshr_fill_done_q[
                            demand_reset_index] <= 1'b0;
                        demand_mshr_reissue_q[
                            demand_reset_index] <= 1'b0;
                        demand_mshr_wait_prefetch_q[
                            demand_reset_index] <= 1'b0;
                        demand_mshr_error_q[
                            demand_reset_index] <= 1'b0;
                        demand_mshr_epoch_q[
                            demand_reset_index] <=
                            speculation_epoch_q + 1'b1;
                    end
                end
                if ((backend_state_q == BACKEND_SEND) &&
                    request_prefetch_q) begin
                    request_prefetch_q <= 1'b0;
                    request_discard_q <= 1'b0;
                    command_sent_q <= 1'b0;
                    backend_state_q <= BACKEND_IDLE;
                end
                for (prefetch_reset_stream_index = 0;
                     prefetch_reset_stream_index < PREFETCH_STREAMS;
                     prefetch_reset_stream_index =
                         prefetch_reset_stream_index + 1) begin
                    prefetch_generation_active_q[
                        prefetch_reset_stream_index] <= 1'b0;
                    prefetch_boundary_probe_wait_q[
                        prefetch_reset_stream_index] <= 1'b0;
                    prefetch_stream_long_q[
                        prefetch_reset_stream_index] <= 1'b0;
                end
                for (prefetch_reset_index = 0;
                     prefetch_reset_index < PREFETCH_QUEUE_LINES;
                     prefetch_reset_index =
                         prefetch_reset_index + 1)
                    prefetch_candidate_valid_q[
                        prefetch_reset_index] <= 1'b0;
                for (prefetch_reset_index = 0;
                     prefetch_reset_index < PREFETCH_OUTSTANDING;
                     prefetch_reset_index =
                         prefetch_reset_index + 1)
                    if (prefetch_mshr_valid_q[prefetch_reset_index])
                        prefetch_mshr_discard_q[
                            prefetch_reset_index] <= 1'b1;
                for (buffer_reset_index = 0;
                     buffer_reset_index < FILL_BUFFER_LINES;
                     buffer_reset_index = buffer_reset_index + 1) begin
                    if (fill_buffer_prefetch_q[buffer_reset_index]) begin
                        fill_buffer_valid_q[buffer_reset_index] <= 1'b0;
                        fill_buffer_prefetch_q[buffer_reset_index] <=
                            1'b0;
                    end
                end
            end

            if (prefetch_invalidate_fire) begin
                for (prefetch_reset_stream_index = 0;
                     prefetch_reset_stream_index < PREFETCH_STREAMS;
                     prefetch_reset_stream_index =
                         prefetch_reset_stream_index + 1)
                    if (l1_invalidate_all || !lock_invalidate_fire ||
                        (prefetch_boundary_probe_addr_q[
                             prefetch_reset_stream_index] ==
                         {l1_invalidate_addr[63:6], 6'b0}))
                        prefetch_boundary_probe_wait_q[
                            prefetch_reset_stream_index] <= 1'b0;
                if (!lock_invalidate_fire) begin
                    for (prefetch_reset_stream_index = 0;
                         prefetch_reset_stream_index < PREFETCH_STREAMS;
                         prefetch_reset_stream_index =
                             prefetch_reset_stream_index + 1) begin
                        prefetch_generation_active_q[
                            prefetch_reset_stream_index] <= 1'b0;
                        prefetch_stream_long_q[
                            prefetch_reset_stream_index] <= 1'b0;
                    end
                end
                if (l1_invalidate_all) begin
                    for (prefetch_reset_stream_index = 0;
                         prefetch_reset_stream_index < PREFETCH_STREAMS;
                         prefetch_reset_stream_index =
                             prefetch_reset_stream_index + 1) begin
                        prefetch_train_valid_q[
                            prefetch_reset_stream_index] <= 1'b0;
                        prefetch_stride_valid_q[
                            prefetch_reset_stream_index] <= 1'b0;
                        prefetch_confidence_q[
                            prefetch_reset_stream_index] <= 2'd0;
                    end
                    prefetch_depth_q <= PREFETCH_INITIAL_DEPTH;
                    prefetch_waste_q <= 2'd0;
                    for (atomic_hot_reset_index = 0;
                         atomic_hot_reset_index < ATOMIC_HOT_LINES;
                         atomic_hot_reset_index =
                             atomic_hot_reset_index + 1)
                        atomic_hot_valid_q[
                            atomic_hot_reset_index] <= 1'b0;
                end else if (!lock_invalidate_fire) begin
                    for (atomic_hot_reset_index = 0;
                         atomic_hot_reset_index < ATOMIC_HOT_LINES;
                         atomic_hot_reset_index =
                             atomic_hot_reset_index + 1)
                        if (atomic_hot_valid_q[
                                atomic_hot_reset_index] &&
                            (atomic_hot_line_q[
                                 atomic_hot_reset_index] ==
                             {l1_invalidate_addr[63:6], 6'b0}))
                            atomic_hot_valid_q[
                                atomic_hot_reset_index] <= 1'b0;
                end
                // A targeted snoop is a generation boundary for matching
                // detached demand misses.  Completed or simultaneously
                // returning data is discarded and reissued; an older
                // outstanding response is consumed by transaction ID before
                // the MSHR becomes eligible again.  Waiters and their
                // age-correct store overlays remain attached.
                for (demand_reset_index = 0;
                     demand_reset_index < DEMAND_MSHRS;
                     demand_reset_index = demand_reset_index + 1) begin
                    if (demand_mshr_valid_q[demand_reset_index] &&
                        (l1_invalidate_all ||
                         (demand_mshr_addr_q[demand_reset_index] ==
                          {l1_invalidate_addr[63:6], 6'b0}))) begin
                        demand_mshr_wait_prefetch_q[
                            demand_reset_index] <= 1'b0;
                        if (demand_mshr_complete_q[
                                demand_reset_index] ||
                            (demand_mshr_response_fire &&
                             (demand_mshr_response_index_r ==
                              DEMAND_MSHR_INDEX_WIDTH'(
                                  demand_reset_index)))) begin
                            demand_mshr_issued_q[
                                demand_reset_index] <= 1'b0;
                            demand_mshr_complete_q[
                                demand_reset_index] <= 1'b0;
                            demand_mshr_fill_done_q[
                                demand_reset_index] <= 1'b0;
                            demand_mshr_reissue_q[
                                demand_reset_index] <= 1'b0;
                            demand_mshr_error_q[
                                demand_reset_index] <= 1'b0;
                            demand_mshr_epoch_q[
                                demand_reset_index] <=
                                speculation_epoch_q;
                        end else if (demand_mshr_issued_q[
                                         demand_reset_index]) begin
                            demand_mshr_reissue_q[
                                demand_reset_index] <= 1'b1;
                        end
                    end
                end
                for (prefetch_reset_index = 0;
                     prefetch_reset_index < PREFETCH_QUEUE_LINES;
                     prefetch_reset_index =
                         prefetch_reset_index + 1) begin
                    if (prefetch_candidate_valid_q[
                            prefetch_reset_index] &&
                        (l1_invalidate_all ||
                         (prefetch_candidate_addr_q[
                              prefetch_reset_index] ==
                          {l1_invalidate_addr[63:6], 6'b0})))
                        prefetch_candidate_valid_q[
                            prefetch_reset_index] <= 1'b0;
                end
                for (prefetch_reset_index = 0;
                     prefetch_reset_index < PREFETCH_OUTSTANDING;
                     prefetch_reset_index =
                         prefetch_reset_index + 1) begin
                    if (prefetch_mshr_valid_q[prefetch_reset_index] &&
                        (l1_invalidate_all ||
                         (prefetch_mshr_addr_q[prefetch_reset_index] ==
                          {l1_invalidate_addr[63:6], 6'b0})))
                        prefetch_mshr_discard_q[
                            prefetch_reset_index] <= 1'b1;
                end
                for (buffer_reset_index = 0;
                     buffer_reset_index < FILL_BUFFER_LINES;
                     buffer_reset_index = buffer_reset_index + 1) begin
                    if (fill_buffer_valid_q[buffer_reset_index] &&
                        (l1_invalidate_all ||
                         (fill_buffer_addr_q[buffer_reset_index] ==
                          {l1_invalidate_addr[63:6], 6'b0}))) begin
                        fill_buffer_valid_q[buffer_reset_index] <= 1'b0;
                        fill_buffer_prefetch_q[buffer_reset_index] <= 1'b0;
                    end
                end
            end

            // A visible store request poisons all speculative copies before
            // admission.  This is intentionally based on valid, not fire:
            // a full store buffer can hold the request at this interface
            // while an older same-line prefetch response arrives.
            if (store_request_pending) begin
                for (prefetch_reset_index = 0;
                     prefetch_reset_index < PREFETCH_QUEUE_LINES;
                     prefetch_reset_index =
                         prefetch_reset_index + 1) begin
                    if (prefetch_candidate_valid_q[
                            prefetch_reset_index] &&
                        (demand_line_addr ==
                         prefetch_candidate_addr_q[
                             prefetch_reset_index]))
                        prefetch_candidate_valid_q[
                            prefetch_reset_index] <= 1'b0;
                end
                for (prefetch_reset_index = 0;
                     prefetch_reset_index < PREFETCH_OUTSTANDING;
                     prefetch_reset_index =
                         prefetch_reset_index + 1) begin
                    if (prefetch_mshr_valid_q[prefetch_reset_index] &&
                        (demand_line_addr ==
                         prefetch_mshr_addr_q[prefetch_reset_index]))
                        prefetch_mshr_discard_q[
                            prefetch_reset_index] <= 1'b1;
                end
                for (buffer_reset_index = 0;
                     buffer_reset_index < FILL_BUFFER_LINES;
                     buffer_reset_index = buffer_reset_index + 1) begin
                    if (fill_buffer_valid_q[buffer_reset_index] &&
                        (fill_buffer_addr_q[buffer_reset_index] ==
                         demand_line_addr)) begin
                        fill_buffer_valid_q[buffer_reset_index] <= 1'b0;
                        fill_buffer_prefetch_q[buffer_reset_index] <= 1'b0;
                    end
                end
            end
        end
    end

    // Reserved for native atomic responses; READ/WRITE L1D traffic ignores it.
`ifndef SYNTHESIS
    openrv64_l1d_debug_stub #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .REQ_TAG_WIDTH(REQ_TAG_WIDTH),
        .FILL_BUFFER_LINES(FILL_BUFFER_LINES),
        .STORE_BUFFER_LINES(STORE_BUFFER_LINES),
        .DEMAND_MSHRS(DEMAND_MSHRS),
        .PREFETCH_OUTSTANDING(PREFETCH_OUTSTANDING),
        .FREELOADER_STAGES(FREELOADER_STAGES),
        .STORE_BUFFER_COUNT_WIDTH(STORE_BUFFER_COUNT_WIDTH),
        .DEMAND_MSHR_INDEX_WIDTH(DEMAND_MSHR_INDEX_WIDTH),
        .PREFETCH_MSHR_INDEX_WIDTH(PREFETCH_MSHR_INDEX_WIDTH),
        .DEMAND_WAITER_COUNT(DEMAND_WAITER_COUNT),
        .TAG_OVERLAY_EPOCH_WIDTH(TAG_OVERLAY_EPOCH_WIDTH),
        .L1_REQ_TAG_WIDTH(L1_REQ_TAG_WIDTH),
        .TAG_OVERLAY_WIDTH(TAG_OVERLAY_WIDTH)
    ) u_debug (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .backend_state(backend_state_q),
        .coherent_lr_reservation_done(coherent_lr_reservation_done_q),
        .req_valid(req_valid_i),
        .req_ready(req_ready_o),
        .req_write(req_write_i),
        .l1_req_valid(l1_req_valid),
        .l1_req_ready(l1_req_ready),
        .l1_miss_valid(l1_miss_valid),
        .l1_miss_ready(l1_miss_ready),
        .l1_miss_fire(l1_miss_fire),
        .demand_mshr_match_found_r(demand_mshr_match_found_r),
        .demand_mshr_response_fire(demand_mshr_response_fire),
        .demand_response_fire(demand_response_fire),
        .l1_fill_valid(l1_fill_valid),
        .l1_fill_ready(l1_fill_ready),
        .l1_fill_fire(l1_fill_fire),
        .fast_store_fire(fast_store_fire),
        .normal_overlay_wait(
            normal_response_candidate && !normal_overlay_ready),
        .demand_overlay_wait(
            demand_waiter_response_found_r && !demand_overlay_ready),
        .store_buffer_block(req_valid_i && !posted_store_admission_ready),
        .demand_load_store_block(req_valid_i && demand_load_store_block),
        .request_reservation(request_reservation_q),
        .store_buffer_count(store_buffer_count_q),
        .demand_mshr_valid(demand_mshr_valid_vec),
        .request_addr(request_addr_q),
        .invalidate_valid_i(invalidate_valid_i),
        .invalidate_ready_o(invalidate_ready_o),
        .invalidate_addr_i(invalidate_addr_i),
        .invalidate_txn_valid_q(invalidate_txn_valid_q),
        .invalidate_txn_external_q(invalidate_txn_external_q),
        .invalidate_txn_all_q(invalidate_txn_all_q),
        .invalidate_txn_addr_q(invalidate_txn_addr_q),
        .capture_external_invalidate(capture_external_invalidate),
        .capture_lock_invalidate(capture_lock_invalidate),
        .lock_invalidate_request(lock_invalidate_request),
        .lock_invalidate_fire(lock_invalidate_fire),
        .l1_invalidate_valid(l1_invalidate_valid),
        .l1_invalidate_ready(l1_invalidate_ready),
        .command_fire(command_fire),
        .response_fire(response_fire),
        .l1_response_fire(l1_response_fire),
        .request_addr_q(request_addr_q),
        .request_write_q(request_write_q),
        .request_demand_q(request_demand_q),
        .request_demand_mshr_q(request_demand_mshr_q),
        .request_prefetch_q(request_prefetch_q),
        .request_prefetch_mshr_q(request_prefetch_mshr_q),
        .request_txn_id_q(request_txn_id_q),
        .demand_mshr_valid_q(demand_mshr_valid_q),
        .demand_mshr_issued_q(demand_mshr_issued_q),
        .demand_mshr_complete_q(demand_mshr_complete_q),
        .demand_mshr_fill_done_q(demand_mshr_fill_done_q),
        .demand_mshr_addr_q(demand_mshr_addr_q),
        .demand_mshr_data_q(demand_mshr_data_q),
        .demand_mshr_store_data_q(demand_mshr_store_data_q),
        .demand_mshr_store_strb_q(demand_mshr_store_strb_q),
        .demand_mshr_response_match_r(demand_mshr_response_match_r),
        .demand_mshr_response_index_r(demand_mshr_response_index_r),
        .demand_mshr_fill_found_r(demand_mshr_fill_found_r),
        .demand_mshr_fill_index_r(demand_mshr_fill_index_r),
        .demand_mshr_prefetch_response_match_r(
            demand_mshr_prefetch_response_match_r),
        .demand_waiter_response_found_r(demand_waiter_response_found_r),
        .demand_waiter_response_tag_r(demand_waiter_response_tag_r),
        .demand_waiter_response_mshr_r(demand_waiter_response_mshr_r),
        .demand_response_data_r(demand_response_data_r),
        .demand_fill_data_r(demand_fill_data_r),
        .demand_response_valid(demand_response_valid),
        .fill_buffer_valid_q(fill_buffer_valid_q),
        .fill_buffer_addr_q(fill_buffer_addr_q),
        .fill_buffer_data_q(fill_buffer_data_q),
        .store_buffer_valid_q(store_buffer_valid_q),
        .store_buffer_addr_q(store_buffer_addr_q),
        .store_buffer_data_q(store_buffer_data_q),
        .store_buffer_strb_q(store_buffer_strb_q),
        .freeloader_valid_q(freeloader_valid_q),
        .freeloader_tag_q(freeloader_tag_q),
        .freeloader_data_q(freeloader_data_q),
        .l1_fill_addr(l1_fill_addr),
        .l1_mem_valid(l1_mem_valid),
        .l1_mem_ready(l1_mem_ready),
        .l1_mem_write(l1_mem_write),
        .l1_mem_addr(l1_mem_addr),
        .l1_mem_wdata(l1_mem_wdata),
        .l1_mem_wstrb(l1_mem_wstrb),
        .l1_mem_rdata(l1_mem_rdata),
        .l1_resp_identity(l1_resp_identity),
        .normal_response_valid(normal_response_valid),
        .normal_response_merged_data_r(normal_response_merged_data_r),
        .normal_overlay_owner_match(normal_overlay_owner_match),
        .normal_overlay_needed(normal_overlay_needed),
        .normal_overlay_read_match(normal_overlay_read_match),
        .normal_overlay_bypass_match(normal_overlay_bypass_match),
        .normal_overlay_ready(normal_overlay_ready),
        .normal_overlay_data(normal_overlay_data),
        .tag_overlay_epoch_q(tag_overlay_epoch_q),
        .tag_overlay_mem_epoch_q(tag_overlay_mem_epoch_q),
        .tag_overlay_owner_epoch_q(tag_overlay_owner_epoch_q),
        .tag_overlay_word_q(tag_overlay_word_q),
        .tag_overlay_read_tag_q(tag_overlay_read_tag_q),
        .tag_overlay_read_epoch_q(tag_overlay_read_epoch_q),
        .tag_overlay_read_mem_epoch_q(tag_overlay_read_mem_epoch_q),
        .prefetch_mshr_addr_q(prefetch_mshr_addr_q),
        .prefetch_mshr_response_index_r(prefetch_mshr_response_index_r),
        .prefetch_response_fire(prefetch_response_fire),
        .prefetch_response_claim_existing(prefetch_response_claim_existing),
        .prefetch_response_claim_new(prefetch_response_claim_new)
    );

    integer store_assert_first;
    integer store_assert_second;
    integer demand_assert_first;
    integer demand_assert_second;
    integer demand_assert_waiter;
    reg response_hold_valid_q;
    reg [REQ_TAG_WIDTH-1:0] response_hold_tag_q;
    reg [63:0] response_hold_data_q;
    reg response_hold_error_q;
    reg [63:0] perf_demand_reissues_q;
    reg [63:0] perf_prefetch_page_ends_q;
    reg [PREFETCH_STREAMS-1:0] perf_prefetch_page_end_active_q;
    integer perf_prefetch_page_scan;
    integer perf_prefetch_page_track_scan;
    integer perf_prefetch_page_end_count_r;
    integer perf_demand_reissue_count_r;
    always @* begin
        perf_prefetch_page_end_count_r = 0;
        for (perf_prefetch_page_scan = 0;
             perf_prefetch_page_scan < PREFETCH_STREAMS;
             perf_prefetch_page_scan =
                 perf_prefetch_page_scan + 1)
            if (prefetch_stream_page_end[perf_prefetch_page_scan] &&
                !perf_prefetch_page_end_active_q[
                    perf_prefetch_page_scan])
                perf_prefetch_page_end_count_r =
                    perf_prefetch_page_end_count_r + 1;
        perf_demand_reissue_count_r = main_response_reissue ? 1 : 0;
        if (demand_mshr_response_fire) begin
            if (demand_mshr_reissue_q[
                    demand_mshr_response_index_r] ||
                (demand_mshr_epoch_q[
                    demand_mshr_response_index_r] !=
                 speculation_epoch_q) ||
                speculation_barrier_event)
                perf_demand_reissue_count_r =
                    perf_demand_reissue_count_r + 1;
        end
    end
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            perf_demand_reissues_q <= 64'd0;
            perf_prefetch_page_ends_q <= 64'd0;
            perf_prefetch_page_end_active_q <=
                {PREFETCH_STREAMS{1'b0}};
        end else begin
            perf_demand_reissues_q <= perf_demand_reissues_q +
                perf_demand_reissue_count_r;
            perf_prefetch_page_ends_q <= perf_prefetch_page_ends_q +
                perf_prefetch_page_end_count_r;
            for (perf_prefetch_page_track_scan = 0;
                 perf_prefetch_page_track_scan < PREFETCH_STREAMS;
                 perf_prefetch_page_track_scan =
                     perf_prefetch_page_track_scan + 1)
                perf_prefetch_page_end_active_q[
                    perf_prefetch_page_track_scan] <=
                    prefetch_stream_page_end[
                        perf_prefetch_page_track_scan];
        end
    end
    always @(posedge clk_i) begin
        if (!rst_ni) begin
            response_hold_valid_q <= 1'b0;
            response_hold_tag_q <= {REQ_TAG_WIDTH{1'b0}};
            response_hold_data_q <= 64'd0;
            response_hold_error_q <= 1'b0;
        end else begin
            if (response_hold_valid_q &&
                (!resp_valid_o ||
                 (resp_tag_o != response_hold_tag_q) ||
                 (req_rdata_o !== response_hold_data_q) ||
                 (req_error_o != response_hold_error_q)))
                $fatal(1,
                    "L1D response changed while held by backpressure");
            response_hold_valid_q <= resp_valid_o && !resp_ready_i;
            if (resp_valid_o && !resp_ready_i) begin
                response_hold_tag_q <= resp_tag_o;
                response_hold_data_q <= req_rdata_o;
                response_hold_error_q <= req_error_o;
            end
        end
        if (rst_ni && (store_buffer_count_q != 0) &&
            !store_buffer_valid_q[store_buffer_head_q])
            $fatal(1, "L1D store-buffer count/head validity mismatch");
        if (rst_ni && (backend_state_q != BACKEND_IDLE) &&
            !request_prefetch_q &&
            ((request_txn_id_q >= PREFETCH_TXN_BASE) ||
             !main_txn_in_use_q[request_txn_id_q]))
            $fatal(1, "L1D main request lacks a reserved transaction ID");
        if (rst_ni && main_sc_response_pending &&
            !icx_resp_error_i && !response_protocol_error &&
            ((icx_resp_sc_success_i &&
              (main_sc_result != `OPENRV64_ICX_SC_SUCCESS_DROP) &&
              (main_sc_result != `OPENRV64_ICX_SC_SUCCESS_EXCLUSIVE)) ||
             (!icx_resp_sc_success_i &&
              (main_sc_result != `OPENRV64_ICX_SC_FAIL))))
            $fatal(1, "L1D SC success/result disagreement");
        if (rst_ni && (SYNC_TAG_LOOKUP == 0) && l1_resp_valid &&
            !response_tag_empty &&
            (l1_resp_identity != response_fifo_head_identity))
            $fatal(1, "L1D resident response tag/FIFO mismatch");
        if (rst_ni && demand_waiter_response_found_r &&
            tag_overlay_needed_q[demand_waiter_response_tag_r] &&
            !demand_overlay_owner_match)
            $fatal(1,
                "L1D demand overlay owner epoch changed while live");
        if (rst_ni && normal_response_candidate &&
            tag_overlay_needed_q[normal_response_tag] &&
            !normal_overlay_owner_match)
            $fatal(1,
                "L1D resident overlay owner epoch changed while live");
        if (rst_ni && (SYNC_TAG_LOOKUP != 0) && l1_miss_fire &&
            l1_miss_overlay_needed && !l1_miss_overlay_bypass_match)
            $fatal(1,
                "L1D synchronous miss lost its dirty-overlay snapshot");
        if (rst_ni && fast_store_fire && l1_request_fire)
            $fatal(1,
                "L1D fast store also entered the shared L1 lookup path");
        if (rst_ni && fast_store_fire &&
            (!store_buffer_valid_q[store_buffer_newest_index] ||
             store_buffer_issued_q[store_buffer_newest_index] ||
             !store_buffer_fast_merge_q[store_buffer_newest_index] ||
             (store_buffer_addr_q[store_buffer_newest_index] !=
              {req_addr_i[63:6], 6'b0}) ||
             store_buffer_force_drain))
            $fatal(1,
                "L1D fast store fired without a valid same-line merge context");
        if (rst_ni && fast_store_fire &&
            (store_buffer_age_q[store_buffer_newest_index] ==
             STORE_BUFFER_TIMEOUT_LAST))
            $fatal(1,
                "L1D fast store extended a timed-out store-buffer entry");
        for (demand_assert_first = 0;
             demand_assert_first < DEMAND_MSHRS;
             demand_assert_first = demand_assert_first + 1) begin
            if (rst_ni &&
                demand_mshr_valid_q[demand_assert_first]) begin
                if (demand_mshr_wait_prefetch_q[
                        demand_assert_first] &&
                    (demand_mshr_issued_q[demand_assert_first] ||
                     demand_mshr_complete_q[demand_assert_first]))
                    $fatal(1,
                        "L1D prefetch-owned demand MSHR changed owner state");
                if (demand_mshr_issued_q[demand_assert_first] &&
                    !demand_mshr_complete_q[demand_assert_first] &&
                    ((demand_mshr_txn_id_q[demand_assert_first] >=
                      PREFETCH_TXN_BASE) ||
                     !main_txn_in_use_q[
                         demand_mshr_txn_id_q[
                             demand_assert_first]]))
                    $fatal(1,
                        "L1D in-flight demand lacks a reserved transaction ID");
                for (demand_assert_second = demand_assert_first + 1;
                     demand_assert_second < DEMAND_MSHRS;
                     demand_assert_second =
                         demand_assert_second + 1) begin
                    if (demand_mshr_valid_q[demand_assert_second] &&
                        (demand_mshr_addr_q[demand_assert_first] ==
                         demand_mshr_addr_q[demand_assert_second]))
                        $fatal(1,
                            "L1D allocated duplicate same-line demand MSHRs");
                    if (demand_mshr_issued_q[demand_assert_first] &&
                        !demand_mshr_complete_q[demand_assert_first] &&
                        demand_mshr_valid_q[demand_assert_second] &&
                        demand_mshr_issued_q[demand_assert_second] &&
                        !demand_mshr_complete_q[demand_assert_second] &&
                        (demand_mshr_txn_id_q[demand_assert_first] ==
                         demand_mshr_txn_id_q[demand_assert_second]))
                        $fatal(1,
                            "L1D in-flight demands reused a transaction ID");
                end
            end
        end
        for (demand_assert_waiter = 0;
             demand_assert_waiter < DEMAND_WAITER_COUNT;
             demand_assert_waiter = demand_assert_waiter + 1)
            if (rst_ni &&
                demand_waiter_valid_q[demand_assert_waiter] &&
                !demand_mshr_valid_q[
                    demand_waiter_mshr_q[demand_assert_waiter]])
                $fatal(1, "L1D demand waiter references a free MSHR");
        for (store_assert_first = 0;
             store_assert_first < STORE_BUFFER_LINES;
             store_assert_first = store_assert_first + 1) begin
            if (rst_ni &&
                store_buffer_valid_q[store_assert_first] &&
                store_buffer_issued_q[store_assert_first] &&
                !store_buffer_completed_q[store_assert_first]) begin
                if ((store_buffer_txn_id_q[store_assert_first] >=
                     PREFETCH_TXN_BASE) ||
                    !main_txn_in_use_q[
                        store_buffer_txn_id_q[store_assert_first]])
                    $fatal(1,
                        "L1D in-flight store lacks a reserved transaction ID");
                for (store_assert_second = store_assert_first + 1;
                     store_assert_second < STORE_BUFFER_LINES;
                     store_assert_second = store_assert_second + 1)
                    if (store_buffer_valid_q[store_assert_second] &&
                        store_buffer_issued_q[store_assert_second] &&
                        !store_buffer_completed_q[store_assert_second] &&
                        (store_buffer_txn_id_q[store_assert_first] ==
                         store_buffer_txn_id_q[store_assert_second]))
                        $fatal(1,
                            "L1D in-flight stores reused a transaction ID");
            end
        end
    end

    initial begin
        if (ADDR_WIDTH != 64)
            $fatal(1, "L1D ICX currently requires a 64-bit address");
        if (LINE_BYTES != 64)
            $fatal(1, "L1D ICX currently requires a 64-byte cache line");
        if ((FILL_BUFFER_LINES < 1) || (FILL_BUFFER_LINES > 16))
            $fatal(1, "L1D fill buffers must contain 1 through 16 cachelines");
        if ((DEMAND_MSHRS < 1) ||
            (DEMAND_MSHRS > MAIN_TXN_COUNT) ||
            (DEMAND_MSHRS > DEMAND_WAITER_COUNT))
            $fatal(1,
                "L1D demand MSHRs must fit main transaction IDs and request tags");
        if ((STORE_BUFFER_LINES < 1) || (STORE_BUFFER_LINES > 16))
            $fatal(1, "L1D store buffers must contain 1 through 16 cachelines");
        if ((SPECULATION_EPOCH_WIDTH < 2) ||
            (SPECULATION_EPOCH_WIDTH > 16))
            $fatal(1,
                "L1D speculation epoch width must be 2 through 16 bits");
        if ((STORE_BUFFER_DRAIN_WATERMARK < 1) ||
            (STORE_BUFFER_DRAIN_WATERMARK > STORE_BUFFER_LINES))
            $fatal(1, "L1D store-buffer drain watermark must fit the FIFO");
        if (STORE_BUFFER_TIMEOUT_CYCLES < 1)
            $fatal(1, "L1D store-buffer timeout must be at least one cycle");
        if ((REQ_DEPTH < 1) || (REQ_DEPTH > (1 << REQ_TAG_WIDTH)))
            $fatal(1, "L1D request depth must fit its tag width");
        if ((FREELOADER != 0) && (FREELOADER != 1))
            $fatal(1, "L1D freeloader must be zero or one");
        if ((FREELOADER_LATENCY < 3) ||
            (FREELOADER_LATENCY > (REQ_DEPTH + 2)))
            $fatal(1, "L1D freeloader latency must be 3 through request depth plus two");
        if ((FREELOADER != 0) && (ENABLE == 0))
            $fatal(1, "L1D freeloader requires the native L1D wrapper");
        if ((PREFETCH_ENABLE != 0) && (PREFETCH_ENABLE != 1))
            $fatal(1, "L1D prefetch enable must be zero or one");
        if ((PREFETCH_ADAPTIVE_ENABLE != 0) &&
            (PREFETCH_ADAPTIVE_ENABLE != 1))
            $fatal(1, "L1D adaptive prefetch enable must be zero or one");
        if ((PREFETCH_PAGE_GATING < 0) ||
            (PREFETCH_PAGE_GATING > 2))
            $fatal(1,
                "L1D prefetch page gating must be 0, 1, or 2");
        if ((PREFETCH_MAX_STRIDE_LINES < 1) ||
            (PREFETCH_MAX_STRIDE_LINES > 1048576))
            $fatal(1, "L1D prefetch maximum stride must be 1 through 1048576 lines");
        if ((PREFETCH_STREAMS < 1) || (PREFETCH_STREAMS > 4))
            $fatal(1, "L1D prefetch stream count must be 1 through 4");
        if ((PREFETCH_DISTANCE < 1) || (PREFETCH_DISTANCE > 16))
            $fatal(1, "L1D prefetch distance must be 1 through 16");
        if ((PREFETCH_MAX_DISTANCE < PREFETCH_DISTANCE) ||
            (PREFETCH_MAX_DISTANCE > 16))
            $fatal(1, "L1D adaptive maximum distance must be initial distance through 16");
        if ((PREFETCH_QUEUE_LINES < 1) ||
            (PREFETCH_QUEUE_LINES > PREFETCH_MAX_DISTANCE))
            $fatal(1, "L1D prefetch queue must contain 1 through maximum-distance entries");
        if ((PREFETCH_OUTSTANDING < 1) ||
            (PREFETCH_OUTSTANDING >= TOTAL_TXN_COUNT))
            $fatal(1, "L1D prefetch outstanding count exceeds reserved transaction IDs");
        if ((ATOMIC_HOT_LINES < 1) || (ATOMIC_HOT_LINES > 64))
            $fatal(1, "L1D atomic-hot directory must contain 1 through 64 lines");
        if ((PREFETCH_DEMAND_RESERVE < 0) ||
            (PREFETCH_DEMAND_RESERVE >= FILL_BUFFER_LINES))
            $fatal(1, "L1D prefetch demand reserve must leave at least one speculative slot");
    end
`endif

endmodule
