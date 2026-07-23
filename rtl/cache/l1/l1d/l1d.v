`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/bus/bus-defs.v"

// Data-side specialization.  Stores are write-through and no-write-allocate;
// reads use the shared eight-way L1 implementation.
module openrv64_l1d #(
    parameter integer ENABLE = 1,
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 64,
    parameter integer REFILL_DATA_WIDTH = DATA_WIDTH,
    parameter integer CACHE_BYTES = 16 * 1024,
    parameter integer LINE_BYTES = 64,
    parameter integer WAYS = 8,
    parameter integer WRITEBACK_TIMEOUT_CYCLES = 128,
    parameter integer DIRTY_TIMESTAMP_WIDTH =
        (WRITEBACK_TIMEOUT_CYCLES < 2) ? 1 :
        $clog2(WRITEBACK_TIMEOUT_CYCLES + 1)
) (
    input  wire                      clk_i,
    input  wire                      rst_ni,
    input  wire                      req_valid_i,
    output wire                      req_ready_o,
    input  wire                      req_write_i,
    input  wire                      req_cacheable_i,
    input  wire [ADDR_WIDTH-1:0]     req_addr_i,
    input  wire [DATA_WIDTH-1:0]     req_wdata_i,
    input  wire [DATA_WIDTH/8-1:0]   req_wstrb_i,
    output wire                      resp_valid_o,
    input  wire                      resp_ready_i,
    output wire [DATA_WIDTH-1:0]     req_rdata_o,
    output wire                      req_error_o,
    input  wire                      invalidate_valid_i,
    output wire                      invalidate_ready_o,
    input  wire                      invalidate_all_i,
    input  wire [ADDR_WIDTH-1:0]     invalidate_addr_i,
    input  wire [3:0]                age_valid_i,
    input  wire [4*ADDR_WIDTH-1:0]   age_addr_i,
    output wire                      mem_valid_o,
    input  wire                      mem_ready_i,
    output wire                      mem_write_o,
    output wire [ADDR_WIDTH-1:0]     mem_addr_o,
    output wire [DATA_WIDTH-1:0]     mem_wdata_o,
    output wire [DATA_WIDTH/8-1:0]   mem_wstrb_o,
    input  wire [REFILL_DATA_WIDTH-1:0] mem_rdata_i,
    input  wire                      mem_error_i
);

    openrv64_l1 #(
        .ENABLE(ENABLE),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .REFILL_DATA_WIDTH(REFILL_DATA_WIDTH),
        .CACHE_BYTES(CACHE_BYTES),
        .LINE_BYTES(LINE_BYTES),
        .WAYS(WAYS),
        .WRITEBACK_TIMEOUT_CYCLES(WRITEBACK_TIMEOUT_CYCLES),
        .DIRTY_TIMESTAMP_WIDTH(DIRTY_TIMESTAMP_WIDTH)
    ) u_l1 (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .req_valid_i(req_valid_i),
        .req_ready_o(req_ready_o),
        .req_write_i(req_write_i),
        .req_cacheable_i(req_cacheable_i),
        .req_addr_i(req_addr_i),
        .req_phys_addr_i(req_addr_i),
        .req_prefetch_i(1'b0),
        .req_aged_i(1'b0),
        .req_wdata_i(req_wdata_i),
        .req_wstrb_i(req_wstrb_i),
        .resp_valid_o(resp_valid_o),
        .resp_ready_i(resp_ready_i),
        .req_rdata_o(req_rdata_o),
        .req_error_o(req_error_o),
        .invalidate_valid_i(invalidate_valid_i),
        .invalidate_ready_o(invalidate_ready_o),
        .invalidate_all_i(invalidate_all_i),
        .invalidate_addr_i(invalidate_addr_i),
        .age_valid_i(age_valid_i),
        .age_addr_i(age_addr_i),
        .mem_valid_o(mem_valid_o),
        .mem_ready_i(mem_ready_i),
        .mem_write_o(mem_write_o),
        .mem_addr_o(mem_addr_o),
        .mem_wdata_o(mem_wdata_o),
        .mem_wstrb_o(mem_wstrb_o),
        .mem_rdata_i(mem_rdata_i),
        .mem_error_i(mem_error_i)
    );

endmodule

// Native 512-bit data-cache endpoint for the core-complex protocol.
//
// The shared L1 controller still writes its SRAM a 64-bit word per cycle.
// This wrapper converts one cacheable miss into one 64-byte CCX read, buffers
// the returned line, and supplies its eight words to that internal refill
// port.  Scalar write-through and uncached operations remain sub-line CCX
// commands but are lane-positioned on the same 512-bit datapath.
module openrv64_l1d_ccx #(
    parameter integer ENABLE = 1,
    parameter integer ADDR_WIDTH = 64,
    parameter integer CACHE_BYTES = 16 * 1024,
    parameter integer LINE_BYTES = 64,
    parameter integer WAYS = 8,
    parameter integer FILL_BUFFER_LINES = 8,
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
    parameter integer ATOMIC_HOT_LINES = 16,
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
    parameter [`OPENRV64_CCX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}}
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

    // A posted store completes northbound when it enters the byte-masked
    // line FIFO.  Its ordered lower-level completion is returned here so the
    // core can release the original LSU tag and report a deferred bus fault.
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
    // The same barrier forces every older posted store through its CCX
    // response. Busy covers the initiating cycle and remains asserted until
    // no buffered or in-flight store remains.
    output wire                      store_barrier_busy_o,

    input  wire                      invalidate_valid_i,
    output wire                      invalidate_ready_o,
    input  wire                      invalidate_all_i,
    input  wire [ADDR_WIDTH-1:0]     invalidate_addr_i,

    output wire                      ccx_req_valid_o,
    input  wire                      ccx_req_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                     ccx_req_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                     ccx_req_txn_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                     ccx_req_source_id_o,
    output wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op_o,
    output wire                      ccx_req_lock_o,
    output wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order_o,
    output wire [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind_o,
    output wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr_o,
    output wire [2:0]                ccx_req_size_o,
    output wire [63:0]               ccx_req_addr_o,
    output wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
                                     ccx_req_burst_len_o,

    output wire                      ccx_wdata_valid_o,
    input  wire                      ccx_wdata_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                     ccx_wdata_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                     ccx_wdata_txn_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                     ccx_wdata_source_id_o,
    output wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                     ccx_wdata_beat_index_o,
    output wire                      ccx_wdata_last_o,
    output wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                     ccx_wdata_o,
    output wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
                                     ccx_wstrb_o,

    input  wire                      ccx_resp_valid_i,
    output wire                      ccx_resp_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                     ccx_resp_hart_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                     ccx_resp_txn_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                     ccx_resp_source_id_i,
    input  wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                     ccx_resp_beat_index_i,
    input  wire                      ccx_resp_last_i,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                     ccx_resp_rdata_i,
    input  wire                      ccx_resp_error_i,
    input  wire                      ccx_resp_sc_success_i
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
    localparam integer PREFETCH_WINDOW_INDEX_WIDTH =
        (PREFETCH_MAX_DISTANCE > 1) ?
        $clog2(PREFETCH_MAX_DISTANCE) : 1;
    localparam integer ATOMIC_HOT_INDEX_WIDTH =
        (ATOMIC_HOT_LINES > 1) ? $clog2(ATOMIC_HOT_LINES) : 1;
    localparam [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] PREFETCH_TXN_BASE =
        1 << (`OPENRV64_CCX_TXN_ID_WIDTH - 1);
    localparam [4:0] PREFETCH_INITIAL_DEPTH = 5'(PREFETCH_DISTANCE);
    localparam [4:0] PREFETCH_MAX_DEPTH_VALUE =
        5'(PREFETCH_MAX_DISTANCE);
    localparam signed [63:0] PREFETCH_NEXT_LINE_STRIDE =
        $signed(64'(LINE_BYTES));
    localparam integer REQ_INDEX_WIDTH =
        (REQ_DEPTH > 1) ? $clog2(REQ_DEPTH) : 1;
    localparam integer REQ_COUNT_WIDTH = $clog2(REQ_DEPTH + 1);
    localparam integer FREELOADER_STAGES =
        (FREELOADER_LATENCY > 2) ? FREELOADER_LATENCY - 2 : 1;

    wire l1_mem_valid;
    wire l1_mem_ready;
    wire l1_mem_write;
    wire [ADDR_WIDTH-1:0] l1_mem_addr;
    wire [63:0] l1_mem_wdata;
    wire [7:0] l1_mem_wstrb;
    wire [511:0] l1_mem_rdata;
    wire l1_mem_error;

    reg [1:0] backend_state_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] next_txn_id_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] request_txn_id_q;
    reg request_write_q;
    reg request_lock_q;
    reg request_cacheable_q;
    reg request_line_read_q;
    reg [2:0] request_size_q;
    reg [63:0] request_addr_q;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] request_wdata_q;
    reg [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] request_wstrb_q;
    reg request_buffered_store_q;
    reg request_reissue_q;
    reg [SPECULATION_EPOCH_WIDTH-1:0] request_epoch_q;
    reg command_sent_q;
    reg wdata_sent_q;
    reg [SPECULATION_EPOCH_WIDTH-1:0] speculation_epoch_q;

    // Native line buffers retain complete speculative CCX responses until
    // the banked SRAM can install the full line in one cycle.
    reg fill_buffer_valid_q [0:FILL_BUFFER_LINES-1];
    reg [63:0] fill_buffer_addr_q [0:FILL_BUFFER_LINES-1];
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
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
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        store_buffer_data_q [0:STORE_BUFFER_LINES-1];
    reg [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
        store_buffer_strb_q [0:STORE_BUFFER_LINES-1];
    reg [STORE_BUFFER_AGE_WIDTH-1:0]
        store_buffer_age_q [0:STORE_BUFFER_LINES-1];
    reg [STORE_BUFFER_INDEX_WIDTH-1:0] store_buffer_head_q;
    reg [STORE_BUFFER_INDEX_WIDTH-1:0] store_buffer_tail_q;
    reg [STORE_BUFFER_COUNT_WIDTH-1:0] store_buffer_count_q;
    reg store_buffer_drain_active_q;
    reg store_barrier_active_q;
    reg store_completion_valid_q;
    reg store_completion_error_q;
    integer store_buffer_merge_byte;

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
    reg [REQ_TAG_WIDTH-1:0] response_tag_q [0:REQ_DEPTH-1];
    reg [REQ_INDEX_WIDTH-1:0] response_tag_head_q;
    reg [REQ_INDEX_WIDTH-1:0] response_tag_tail_q;
    reg [REQ_COUNT_WIDTH-1:0] response_tag_count_q;
    integer response_tag_reset_index;

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
    wire l1_invalidate_ready;
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
    wire lock_invalidate_request = req_valid_i && req_lock_i &&
        !locked_line_invalidated_q;
    wire lock_invalidate_fire = lock_invalidate_request &&
        !invalidate_valid_i && l1_invalidate_ready;
    wire lock_barrier_request = req_valid_i && req_lock_i &&
                                !lock_barrier_seen_q;
    wire speculation_barrier_event =
        speculation_barrier_i || lock_barrier_request;
    wire l1_invalidate_valid = invalidate_valid_i ||
        lock_invalidate_request;
    wire l1_invalidate_all = invalidate_valid_i && invalidate_all_i;
    wire [ADDR_WIDTH-1:0] l1_invalidate_addr = invalidate_valid_i ?
        invalidate_addr_i : req_addr_i;
    wire response_tag_full =
        response_tag_count_q == REQ_COUNT_WIDTH'(REQ_DEPTH);
    // The single-hart atomic marker remains a strong local serialization
    // point even though it no longer acquires a CCX/L2 home lock.  Invalidate
    // early and admit the marked request only after all older stores and the
    // current backend command have drained.
    wire lock_backend_quiescent =
        (store_buffer_count_q == 0) &&
        !store_completion_valid_q &&
        (backend_state_q == BACKEND_IDLE);
    wire lock_request_ready = !req_lock_i ||
        (locked_line_invalidated_q && lock_backend_quiescent);
    wire freeloader_response_valid =
        freeloader_valid_q[FREELOADER_STAGES-1];
    wire normal_response_valid = l1_resp_valid &&
        (response_tag_count_q != 0);
    wire freeloader_response_ready =
        resp_ready_i && !normal_response_valid;
    wire freeloader_pipe_advance =
        !freeloader_response_valid || freeloader_response_ready;
    wire freeloader_order_safe =
        !freeloader_pending_store_valid_q ||
        freeloader_pending_store_posted_q;
    wire freeloader_request = (FREELOADER != 0) && req_valid_i &&
        !req_write_i && !req_lock_i && req_cacheable_i &&
        freeloader_oracle_valid;
    wire freeloader_request_ready =
        freeloader_pipe_advance && freeloader_order_safe &&
        !demand_load_store_conflict_r;
    wire freeloader_request_fire =
        freeloader_request && freeloader_request_ready;
    wire l1_req_valid = req_valid_i && !freeloader_request &&
        !response_tag_full && lock_request_ready &&
        !demand_load_store_conflict_r;
    wire l1_req_cacheable = req_cacheable_i && !req_lock_i;
    wire l1_request_fire = l1_req_valid && l1_req_ready;
    wire l1_resp_ready = resp_ready_i && (response_tag_count_q != 0);
    wire l1_response_fire = l1_resp_valid && l1_resp_ready;
    wire demand_request_fire =
        l1_request_fire || freeloader_request_fire;
    wire [63:0] demand_line_addr = {req_addr_i[63:6], 6'b0};
    wire atomic_hot_demand_match = atomic_hot_match(demand_line_addr);
    wire prefetch_train_access = (PREFETCH_ENABLE != 0) &&
        (ENABLE != 0) && demand_request_fire && !req_write_i &&
        l1_req_cacheable && !req_lock_i && !atomic_hot_demand_match;

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
                !prefetch_train_valid_q[prefetch_train_stream_scan]) begin
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
         (prefetch_train_valid_q[prefetch_train_index_r] &&
          !prefetch_stride_match));

    // A posted store is architecturally complete northbound before it reaches
    // CCX.  A later load to the same line must therefore hold at the L1 input
    // until every older matching FIFO entry has completed below the cache.
    // The backend already drains the FIFO in order; this conflict turns that
    // ordinary draining into a forced write without globally serializing
    // unrelated loads behind the store buffer.
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

    // The normal L1 and the simulation-only load pipeline share one tagged
    // response port. Normal responses win arbitration so a continuous ideal
    // load stream cannot prevent posted-store tags from being released.
    assign req_ready_o = freeloader_request ?
                         freeloader_request_ready :
                         (l1_req_ready && !response_tag_full &&
                          lock_request_ready &&
                          !demand_load_store_conflict_r);
    assign resp_valid_o = normal_response_valid ||
                          freeloader_response_valid;
    assign resp_tag_o = normal_response_valid ?
        response_tag_q[response_tag_head_q] :
        freeloader_tag_q[FREELOADER_STAGES-1];
    assign req_rdata_o = normal_response_valid ? l1_req_rdata :
        freeloader_data_q[FREELOADER_STAGES-1];
    assign req_error_o = normal_response_valid ? l1_req_error : 1'b0;
    assign invalidate_ready_o = l1_invalidate_ready &&
        !lock_invalidate_request && (store_buffer_count_q == 0);

    // The RAM oracle is older than stores which have completed northbound but
    // are still queued for CCX. Overlay those bytes in FIFO order, then the
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
                (ccx_resp_hart_id_i == HART_ID) &&
                (ccx_resp_source_id_i ==
                 `OPENRV64_CCX_SOURCE_DCACHE) &&
                (ccx_resp_txn_id_i ==
                 (PREFETCH_TXN_BASE +
                  `OPENRV64_CCX_TXN_ID_WIDTH'(prefetch_mshr_scan)))) begin
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
                    !(prefetch_train_event &&
                      (prefetch_train_index_r ==
                       PREFETCH_STREAM_INDEX_WIDTH'(
                           prefetch_generate_stream_scan))) &&
                    !prefetch_invalidate_fire &&
                    (prefetch_depth_scan <= prefetch_depth_q) &&
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

    // Atomic phases never consume speculative data.  They bypass both the
    // resident L1 and the prefetch fill buffers and obtain the current value
    // from the L2/CCX path.
    wire refill_buffer_hit = fill_buffer_hit_r && l1_mem_valid &&
        !l1_mem_write && active_req_cacheable_q && !active_req_lock_q &&
        !speculation_barrier_event &&
        (fill_buffer_epoch_q[fill_buffer_hit_index_r] ==
         speculation_epoch_q);
    wire [511:0] refill_buffer_data =
        fill_buffer_data_q[fill_buffer_hit_index_r];
    wire [511:0] response_refill_data = ccx_resp_rdata_i;
    wire [63:0] response_access_data =
        ccx_resp_rdata_i[request_addr_q[5:3]*64 +: 64];
    wire [511:0] response_mem_data = request_line_read_q ?
        response_refill_data : {{448{1'b0}}, response_access_data};

    wire store_buffer_full =
        (store_buffer_count_q ==
         STORE_BUFFER_COUNT_WIDTH'(STORE_BUFFER_LINES));
    wire postable_store = l1_mem_valid && l1_mem_write &&
                          active_req_cacheable_q && active_req_posted_q;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        posted_store_line_data =
            {{(`OPENRV64_CCX_LINE_DATA_WIDTH-64){1'b0}}, l1_mem_wdata}
            << (l1_mem_addr[5:3] * 64);
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
        posted_store_line_strb =
            {{(`OPENRV64_CCX_LINE_STRB_WIDTH-8){1'b0}}, l1_mem_wstrb}
            << (l1_mem_addr[5:3] * 8);
    wire store_completion_fire = store_completion_valid_q &&
                                 store_resp_ready_i;
    wire [STORE_BUFFER_INDEX_WIDTH-1:0] store_buffer_newest_index =
        (store_buffer_tail_q == 0) ?
        STORE_BUFFER_INDEX_WIDTH'(STORE_BUFFER_LINES - 1) :
        store_buffer_tail_q - 1'b1;
    wire store_buffer_newest_is_head =
        store_buffer_newest_index == store_buffer_head_q;
    wire store_buffer_head_reserved =
        store_buffer_newest_is_head && request_buffered_store_q &&
        ((backend_state_q != BACKEND_IDLE) ||
         store_completion_valid_q);
    wire store_buffer_merge = postable_store &&
        (store_buffer_count_q != 0) &&
        store_buffer_valid_q[store_buffer_newest_index] &&
        !store_buffer_head_reserved &&
        (store_buffer_addr_q[store_buffer_newest_index] ==
         {l1_mem_addr[63:6], 6'b0});
    wire store_buffer_allocate = postable_store && !store_buffer_merge &&
        (!store_buffer_full || store_completion_fire);
    wire store_buffer_accept =
        store_buffer_merge || store_buffer_allocate;
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
    wire store_buffer_force_drain =
        demand_load_store_conflict_r || invalidate_valid_i ||
        speculation_barrier_i || store_barrier_active_q ||
        (req_valid_i && req_lock_i);
    assign store_barrier_busy_o =
        speculation_barrier_i || store_barrier_active_q;
    // When draining catches the FIFO tail, leave a partial newest line open
    // for adjacent stores to finish it. A different-line allocation makes
    // this entry no longer newest and therefore immediately drainable.
    // Timeout and correctness-forced drains override the hold.
    wire store_buffer_hold_partial_newest =
        store_buffer_newest_is_head &&
        (store_buffer_strb_q[store_buffer_head_q] !=
         {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b1}}) &&
        !store_buffer_head_timeout && !store_buffer_force_drain;
    wire store_buffer_drain_request =
        (store_buffer_count_q != 0) &&
        store_buffer_valid_q[store_buffer_head_q] &&
        !store_completion_valid_q &&
        (store_buffer_drain_active_q || store_buffer_watermark ||
         store_buffer_head_timeout || store_buffer_force_drain) &&
        !(store_buffer_merge && store_buffer_newest_is_head) &&
        !store_buffer_hold_partial_newest;

    wire response_identity_match =
        (ccx_resp_hart_id_i == HART_ID) &&
        (ccx_resp_source_id_i == `OPENRV64_CCX_SOURCE_DCACHE) &&
        (ccx_resp_txn_id_i == request_txn_id_q);
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] next_main_txn_id =
        (next_txn_id_q == (PREFETCH_TXN_BASE - 1'b1)) ?
        {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}} :
        next_txn_id_q + 1'b1;
    wire response_fire = ccx_resp_valid_i && ccx_resp_ready_o;
    wire main_response_fire = response_fire &&
        (backend_state_q == BACKEND_WAIT) && response_identity_match;
    wire prefetch_response_fire = response_fire &&
        prefetch_mshr_response_match_r;
    wire buffered_store_response = main_response_fire &&
                                   request_buffered_store_q;
    wire response_protocol_error =
        (ccx_resp_beat_index_i != 0) || !ccx_resp_last_i;
    wire command_fire = ccx_req_valid_o && ccx_req_ready_i;
    wire wdata_fire = ccx_wdata_valid_o && ccx_wdata_ready_i;
    wire prefetch_slot_available =
        (fill_buffer_free_count_r > PREFETCH_DEMAND_RESERVE) ||
        fill_buffer_prefetch_found_r;
    wire prefetch_response_uses_free =
        fill_buffer_free_count_r > PREFETCH_DEMAND_RESERVE;
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
        !demand_load_store_conflict_r &&
        !(l1_mem_valid && !refill_buffer_hit && !postable_store) &&
        !atomic_hot_match(prefetch_launch_addr_r) &&
        prefetch_launch_found_r && prefetch_slot_available &&
        prefetch_mshr_free_found_r;
    wire prefetch_candidate_queue = prefetch_generate_valid_r &&
        prefetch_candidate_free_found_r;
    wire prefetch_candidate_drop = prefetch_generate_valid_r &&
        !prefetch_candidate_free_found_r;
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
    wire prefetch_current_stored = prefetch_command_inflight &&
        l1_request_fire && req_write_i &&
        (demand_line_addr == request_addr_q);
    wire prefetch_mshr_response_invalidated =
        prefetch_mshr_response_match_r && prefetch_invalidate_fire &&
        (l1_invalidate_all ||
         ({l1_invalidate_addr[63:6], 6'b0} ==
          prefetch_mshr_addr_q[prefetch_mshr_response_index_r]));
    wire prefetch_mshr_response_stored =
        prefetch_mshr_response_match_r && l1_request_fire && req_write_i &&
        (demand_line_addr ==
         prefetch_mshr_addr_q[prefetch_mshr_response_index_r]);
    wire prefetch_response_discard =
        prefetch_mshr_discard_q[prefetch_mshr_response_index_r] ||
        speculation_barrier_event ||
        (prefetch_mshr_epoch_q[prefetch_mshr_response_index_r] !=
         speculation_epoch_q) ||
        prefetch_mshr_response_invalidated ||
        prefetch_mshr_response_stored;
    wire prefetch_useless_replace = prefetch_response_fire &&
        !prefetch_response_discard &&
        !ccx_resp_error_i && !response_protocol_error &&
        !prefetch_response_uses_free && fill_buffer_prefetch_found_r;

    // A read which has not crossed CCX at the barrier is simply held and
    // relabelled with the new epoch. An accepted old read is handled by the
    // read-miss replay path below.
    assign ccx_req_valid_o = (backend_state_q == BACKEND_SEND) &&
                             !command_sent_q &&
                             !(!request_write_q &&
                               speculation_barrier_event);
    assign ccx_req_hart_id_o = HART_ID;
    assign ccx_req_txn_id_o = request_txn_id_q;
    assign ccx_req_source_id_o = `OPENRV64_CCX_SOURCE_DCACHE;
    assign ccx_req_op_o = request_write_q ? `OPENRV64_CCX_OP_WRITE :
                                             `OPENRV64_CCX_OP_READ;
    // Single-hart mode keeps the atomic phase marker local.  It still
    // serializes translation and forces the operation around L1D, but it does
    // not acquire the shared L2/home lock.  Multi-hart atomics require a
    // coherence-aware protocol rather than this temporary read/write lock.
    assign ccx_req_lock_o = 1'b0;
    assign ccx_req_order_o = `OPENRV64_CCX_ORDER_NONE;
    assign ccx_req_kind_o = `OPENRV64_CCX_KIND_DATA;
    assign ccx_req_attr_o = request_cacheable_q ?
        `OPENRV64_CCX_ATTR_CACHEABLE : `OPENRV64_CCX_ATTR_DEVICE;
    assign ccx_req_size_o = request_line_read_q ? 3'd6 : request_size_q;
    assign ccx_req_addr_o = request_addr_q;
    assign ccx_req_burst_len_o =
        {`OPENRV64_CCX_BURST_LEN_WIDTH{1'b0}};

    assign ccx_wdata_valid_o = (backend_state_q == BACKEND_SEND) &&
                               request_write_q && !wdata_sent_q;
    assign ccx_wdata_hart_id_o = HART_ID;
    assign ccx_wdata_txn_id_o = request_txn_id_q;
    assign ccx_wdata_source_id_o = `OPENRV64_CCX_SOURCE_DCACHE;
    assign ccx_wdata_beat_index_o =
        {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}};
    assign ccx_wdata_last_o = 1'b1;
    assign ccx_wdata_o = request_wdata_q;
    assign ccx_wstrb_o = request_wstrb_q;

    assign store_resp_valid_o = store_completion_valid_q;
    assign store_resp_error_o = store_completion_error_q;
    assign prefetch_issued_o = command_fire && request_prefetch_q;
    assign prefetch_useful_o = refill_buffer_hit && l1_mem_valid &&
        !l1_mem_write && fill_buffer_prefetch_q[fill_buffer_hit_index_r];
    assign prefetch_late_o = prefetch_late_match;
    assign prefetch_dropped_o = prefetch_candidate_drop;
    assign prefetch_useless_o = prefetch_useless_replace;
    assign prefetch_depth_o = prefetch_depth_q;

    wire main_response_reissue = main_response_fire &&
        !request_write_q &&
        (request_reissue_q ||
         (request_epoch_q != speculation_epoch_q) ||
         speculation_barrier_event);
    wire prefetch_response_buffer_available =
        prefetch_response_discard || ccx_resp_error_i ||
        response_protocol_error || prefetch_slot_available;
    assign ccx_resp_ready_o =
        ((backend_state_q == BACKEND_WAIT) &&
         response_identity_match) ||
        (prefetch_mshr_response_match_r &&
         prefetch_response_buffer_available);
    assign l1_mem_ready = store_buffer_accept || refill_buffer_hit ||
                          (l1_mem_valid && main_response_fire &&
                           !request_buffered_store_q &&
                           !main_response_reissue);
    assign l1_mem_rdata = store_buffer_accept ? 512'd0 :
                           refill_buffer_hit ? refill_buffer_data :
                           response_mem_data;
    assign l1_mem_error = l1_mem_valid && main_response_fire &&
                          !request_buffered_store_q &&
                          !main_response_reissue &&
                          (ccx_resp_error_i || response_protocol_error);

    openrv64_l1d #(
        .ENABLE(ENABLE),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(64),
        .REFILL_DATA_WIDTH(512),
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
        .req_write_i(req_write_i),
        .req_cacheable_i(l1_req_cacheable),
        .req_addr_i(req_addr_i),
        .req_wdata_i(req_wdata_i),
        .req_wstrb_i(req_wstrb_i),
        .resp_valid_o(l1_resp_valid),
        .resp_ready_i(l1_resp_ready),
        .req_rdata_o(l1_req_rdata),
        .req_error_o(l1_req_error),
        .invalidate_valid_i(l1_invalidate_valid),
        .invalidate_ready_o(l1_invalidate_ready),
        .invalidate_all_i(l1_invalidate_all),
        .invalidate_addr_i(l1_invalidate_addr),
        .age_valid_i(4'b0000),
        .age_addr_i({4*ADDR_WIDTH{1'b0}}),
        .mem_valid_o(l1_mem_valid),
        .mem_ready_i(l1_mem_ready),
        .mem_write_o(l1_mem_write),
        .mem_addr_o(l1_mem_addr),
        .mem_wdata_o(l1_mem_wdata),
        .mem_wstrb_o(l1_mem_wstrb),
        .mem_rdata_i(l1_mem_rdata),
        .mem_error_i(l1_mem_error)
    );

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            backend_state_q <= BACKEND_IDLE;
            next_txn_id_q <= {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
            request_txn_id_q <= {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
            request_write_q <= 1'b0;
            request_lock_q <= 1'b0;
            request_cacheable_q <= 1'b0;
            request_line_read_q <= 1'b0;
            request_size_q <= 3'd0;
            request_addr_q <= 64'd0;
            request_wdata_q <=
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            request_wstrb_q <=
                {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b0}};
            request_buffered_store_q <= 1'b0;
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
            store_buffer_head_q <=
                {STORE_BUFFER_INDEX_WIDTH{1'b0}};
            store_buffer_tail_q <=
                {STORE_BUFFER_INDEX_WIDTH{1'b0}};
            store_buffer_count_q <=
                {STORE_BUFFER_COUNT_WIDTH{1'b0}};
            store_buffer_drain_active_q <= 1'b0;
            store_barrier_active_q <= 1'b0;
            store_completion_valid_q <= 1'b0;
            store_completion_error_q <= 1'b0;
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
            response_tag_head_q <= {REQ_INDEX_WIDTH{1'b0}};
            response_tag_tail_q <= {REQ_INDEX_WIDTH{1'b0}};
            response_tag_count_q <= {REQ_COUNT_WIDTH{1'b0}};
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
                    {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
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
                    {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
                store_buffer_strb_q[buffer_reset_index] <=
                    {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b0}};
                store_buffer_age_q[buffer_reset_index] <=
                    {STORE_BUFFER_AGE_WIDTH{1'b0}};
            end
            for (response_tag_reset_index = 0;
                 response_tag_reset_index < REQ_DEPTH;
                 response_tag_reset_index =
                     response_tag_reset_index + 1)
                response_tag_q[response_tag_reset_index] <=
                    {REQ_TAG_WIDTH{1'b0}};
        end else begin
            if (!req_valid_i || !req_lock_i)
                lock_barrier_seen_q <= 1'b0;
            else if (lock_barrier_request)
                lock_barrier_seen_q <= 1'b1;

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
                if (!prefetch_train_valid_q[
                        prefetch_train_index_r] ||
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
            end
            if (prefetch_candidate_drop)
                prefetch_window_issued_q[
                    prefetch_generate_stream_r][
                        prefetch_generate_index_r] <= 1'b1;
            if (prefetch_inflight_late_match)
                prefetch_late_reported_q <= 1'b1;
            if (prefetch_mshr_late_match_r)
                prefetch_mshr_late_reported_q[
                    prefetch_mshr_late_index_r] <= 1'b1;
            if (prefetch_current_invalidated || prefetch_current_stored)
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
                active_req_lock_q <= req_lock_i;
                active_req_posted_q <= req_posted_i;
                // A locked operation bypasses this L1 after invalidating its
                // resident copy, but it remains cacheable at the coherent
                // home.  Marking it uncacheable here would let the L2 bypass
                // a newer dirty line and perform the RMW on stale backing
                // memory.
                active_req_cacheable_q <= req_cacheable_i;
                active_req_size_q <= req_size_i;
                response_tag_q[response_tag_tail_q] <= req_tag_i;
                response_tag_tail_q <=
                    (response_tag_tail_q ==
                     REQ_INDEX_WIDTH'(REQ_DEPTH - 1)) ?
                    {REQ_INDEX_WIDTH{1'b0}} :
                    response_tag_tail_q + 1'b1;
                if (req_lock_i && !req_write_i)
                    begin
                        atomic_active_q <= 1'b1;
                        atomic_active_line_q <=
                            {req_addr_i[63:6], 6'b0};
                    end
            end

            // A marked read begins the local AMO interval.  Preserve learned
            // stream state and queued unrelated candidates, but do not issue
            // or generate speculative traffic until the marked write has
            // completed.  A failed read has no write phase.
            if (main_response_fire && request_lock_q &&
                ((request_write_q) || ccx_resp_error_i ||
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
                        {req_addr_i[63:6], 6'b0};
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
                         {req_addr_i[63:6], 6'b0})) begin
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

            if (l1_response_fire)
                response_tag_head_q <=
                    (response_tag_head_q ==
                     REQ_INDEX_WIDTH'(REQ_DEPTH - 1)) ?
                    {REQ_INDEX_WIDTH{1'b0}} :
                    response_tag_head_q + 1'b1;

            case ({l1_request_fire, l1_response_fire})
                2'b10: response_tag_count_q <=
                    response_tag_count_q + 1'b1;
                2'b01: response_tag_count_q <=
                    response_tag_count_q - 1'b1;
                default: response_tag_count_q <= response_tag_count_q;
            endcase

            if (refill_buffer_hit) begin
                fill_buffer_valid_q[fill_buffer_hit_index_r] <= 1'b0;
                fill_buffer_prefetch_q[fill_buffer_hit_index_r] <= 1'b0;
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
                store_buffer_head_q <=
                    (store_buffer_head_q ==
                     STORE_BUFFER_INDEX_WIDTH'(STORE_BUFFER_LINES - 1)) ?
                    {STORE_BUFFER_INDEX_WIDTH{1'b0}} :
                    store_buffer_head_q + 1'b1;
            end

            if (store_buffer_merge) begin
                for (store_buffer_merge_byte = 0;
                     store_buffer_merge_byte <
                         `OPENRV64_CCX_LINE_STRB_WIDTH;
                     store_buffer_merge_byte =
                         store_buffer_merge_byte + 1) begin
                    if (posted_store_line_strb[store_buffer_merge_byte])
                        store_buffer_data_q[store_buffer_newest_index][
                            store_buffer_merge_byte*8 +: 8] <=
                            posted_store_line_data[
                                store_buffer_merge_byte*8 +: 8];
                end
                store_buffer_strb_q[store_buffer_newest_index] <=
                    store_buffer_strb_q[store_buffer_newest_index] |
                    posted_store_line_strb;
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
                store_buffer_tail_q <=
                    (store_buffer_tail_q ==
                     STORE_BUFFER_INDEX_WIDTH'(STORE_BUFFER_LINES - 1)) ?
                    {STORE_BUFFER_INDEX_WIDTH{1'b0}} :
                    store_buffer_tail_q + 1'b1;
            end

            if (buffered_store_response) begin
                store_completion_valid_q <= 1'b1;
                store_completion_error_q <= ccx_resp_error_i ||
                                            response_protocol_error;
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

            if (speculation_barrier_i)
                store_barrier_active_q <= 1'b1;
            else if (store_barrier_active_q &&
                     (store_buffer_count_q == 0) &&
                     !store_buffer_allocate &&
                     !store_completion_valid_q &&
                     (backend_state_q == BACKEND_IDLE))
                store_barrier_active_q <= 1'b0;

            case (backend_state_q)
                BACKEND_IDLE: begin
                    if (store_buffer_drain_request) begin
                        request_txn_id_q <= next_txn_id_q;
                        next_txn_id_q <= next_main_txn_id;
                        request_write_q <= 1'b1;
                        request_lock_q <= 1'b0;
                        request_cacheable_q <= 1'b1;
                        request_line_read_q <= 1'b0;
                        request_size_q <= 3'd6;
                        request_addr_q <=
                            store_buffer_addr_q[store_buffer_head_q];
                        request_wdata_q <=
                            store_buffer_data_q[store_buffer_head_q];
                        request_wstrb_q <=
                            store_buffer_strb_q[store_buffer_head_q];
                        request_buffered_store_q <= 1'b1;
                        request_reissue_q <= 1'b0;
                        request_epoch_q <= speculation_epoch_q;
                        request_prefetch_q <= 1'b0;
                        request_discard_q <= 1'b0;
                        prefetch_late_reported_q <= 1'b0;
                        command_sent_q <= 1'b0;
                        wdata_sent_q <= 1'b0;
                        backend_state_q <= BACKEND_SEND;
                    end else if (prefetch_launch) begin
                        request_txn_id_q <= PREFETCH_TXN_BASE +
                            `OPENRV64_CCX_TXN_ID_WIDTH'(
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
                            {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
                        request_wstrb_q <=
                            {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b0}};
                        request_buffered_store_q <= 1'b0;
                        request_reissue_q <= 1'b0;
                        request_epoch_q <= speculation_epoch_q;
                        request_prefetch_q <= 1'b1;
                        request_discard_q <= 1'b0;
                        prefetch_late_reported_q <= 1'b0;
                        command_sent_q <= 1'b0;
                        wdata_sent_q <= 1'b0;
                        backend_state_q <= BACKEND_SEND;
                    end else if (l1_mem_valid && !refill_buffer_hit &&
                                 !postable_store &&
                                 !speculation_barrier_event &&
                                 !prefetch_mshr_demand_wait_r) begin
                        request_txn_id_q <= next_txn_id_q;
                        next_txn_id_q <= next_main_txn_id;
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
                            {{(`OPENRV64_CCX_LINE_DATA_WIDTH-64){1'b0}},
                              l1_mem_wdata} << (l1_mem_addr[5:3] * 64);
                        request_wstrb_q <=
                            {{(`OPENRV64_CCX_LINE_STRB_WIDTH-8){1'b0}},
                              l1_mem_wstrb} << (l1_mem_addr[5:3] * 8);
                        request_buffered_store_q <= 1'b0;
                        request_reissue_q <= 1'b0;
                        request_epoch_q <= speculation_epoch_q;
                        request_prefetch_q <= 1'b0;
                        request_discard_q <= 1'b0;
                        prefetch_late_reported_q <= 1'b0;
                        command_sent_q <= 1'b0;
                        wdata_sent_q <= 1'b0;
                        backend_state_q <= BACKEND_SEND;
                    end
                end

                BACKEND_SEND: begin
                    if (request_prefetch_q && command_fire) begin
                        prefetch_mshr_valid_q[
                            request_prefetch_mshr_q] <= 1'b1;
                        prefetch_mshr_addr_q[
                            request_prefetch_mshr_q] <= request_addr_q;
                        prefetch_mshr_discard_q[
                            request_prefetch_mshr_q] <=
                            request_discard_q ||
                            prefetch_current_invalidated ||
                            prefetch_current_stored;
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
                    if (!request_prefetch_q && wdata_fire)
                        wdata_sent_q <= 1'b1;
                    if (!request_prefetch_q &&
                        (command_sent_q || command_fire) &&
                        (!request_write_q || wdata_sent_q || wdata_fire))
                        backend_state_q <= BACKEND_WAIT;
                end

                BACKEND_WAIT: begin
                    if (main_response_fire) begin
                        if (main_response_reissue) begin
                            request_txn_id_q <= next_txn_id_q;
                            next_txn_id_q <= next_main_txn_id;
                            request_reissue_q <= 1'b0;
                            request_epoch_q <=
                                speculation_barrier_event ?
                                speculation_epoch_q + 1'b1 :
                                speculation_epoch_q;
                            command_sent_q <= 1'b0;
                            wdata_sent_q <= 1'b0;
                            backend_state_q <= BACKEND_SEND;
                        end else begin
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
                if (!prefetch_response_discard &&
                    !ccx_resp_error_i &&
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
                        ccx_resp_rdata_i;
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
            // prefetches must still consume their CCX responses, but cannot
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
                         prefetch_reset_stream_index + 1)
                    prefetch_generation_active_q[
                        prefetch_reset_stream_index] <= 1'b0;
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
                if (!lock_invalidate_fire) begin
                    for (prefetch_reset_stream_index = 0;
                         prefetch_reset_stream_index < PREFETCH_STREAMS;
                         prefetch_reset_stream_index =
                             prefetch_reset_stream_index + 1)
                        prefetch_generation_active_q[
                            prefetch_reset_stream_index] <= 1'b0;
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

            if (l1_request_fire && req_write_i) begin
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
    wire unused_ccx_resp_sc_success = ccx_resp_sc_success_i;

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (rst_ni && (store_buffer_count_q != 0) &&
            !store_buffer_valid_q[store_buffer_head_q])
            $fatal(1, "L1D store-buffer count/head validity mismatch");
    end

    initial begin
        if (ADDR_WIDTH != 64)
            $fatal(1, "L1D CCX currently requires a 64-bit address");
        if (LINE_BYTES != 64)
            $fatal(1, "L1D CCX currently requires a 64-byte cache line");
        if ((FILL_BUFFER_LINES < 1) || (FILL_BUFFER_LINES > 16))
            $fatal(1, "L1D fill buffers must contain 1 through 16 cachelines");
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
            (PREFETCH_OUTSTANDING > PREFETCH_TXN_BASE))
            $fatal(1, "L1D prefetch outstanding count exceeds reserved transaction IDs");
        if ((ATOMIC_HOT_LINES < 1) || (ATOMIC_HOT_LINES > 64))
            $fatal(1, "L1D atomic-hot directory must contain 1 through 64 lines");
        if ((PREFETCH_DEMAND_RESERVE < 0) ||
            (PREFETCH_DEMAND_RESERVE >= FILL_BUFFER_LINES))
            $fatal(1, "L1D prefetch demand reserve must leave at least one speculative slot");
    end
`endif

endmodule
