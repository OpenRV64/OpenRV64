`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/bus/bus-defs.v"

// Data-side specialization.  Stores are write-through and no-write-allocate;
// reads use the shared eight-way L1 implementation.
module openrv64_l1d #(
    parameter integer ENABLE = 1,
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 64,
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
    input  wire [DATA_WIDTH-1:0]     mem_rdata_i,
    input  wire                      mem_error_i
);

    openrv64_l1 #(
        .ENABLE(ENABLE),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
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
    parameter integer PREFETCH_ENABLE = 1,
    parameter [ADDR_WIDTH-1:0] PREFETCH_CACHEABLE_BASE =
        {ADDR_WIDTH{1'b0}},
    parameter [ADDR_WIDTH-1:0] PREFETCH_CACHEABLE_SIZE =
        {ADDR_WIDTH{1'b1}},
    parameter integer PREFETCH_MAX_STRIDE_LINES = 64,
    parameter integer PREFETCH_DISTANCE = 1,
    parameter integer PREFETCH_ADAPTIVE_ENABLE = 1,
    parameter integer PREFETCH_MAX_DISTANCE = 4,
    parameter integer PREFETCH_QUEUE_LINES = 4,
    parameter integer PREFETCH_OUTSTANDING = 4,
    parameter integer PREFETCH_DEMAND_RESERVE = 2,
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
    localparam integer PREFETCH_QUEUE_INDEX_WIDTH =
        (PREFETCH_QUEUE_LINES > 1) ? $clog2(PREFETCH_QUEUE_LINES) : 1;
    localparam integer PREFETCH_MSHR_INDEX_WIDTH =
        (PREFETCH_OUTSTANDING > 1) ? $clog2(PREFETCH_OUTSTANDING) : 1;
    localparam integer PREFETCH_WINDOW_INDEX_WIDTH =
        (PREFETCH_MAX_DISTANCE > 1) ?
        $clog2(PREFETCH_MAX_DISTANCE) : 1;
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

    wire l1_mem_valid;
    wire l1_mem_ready;
    wire l1_mem_write;
    wire [ADDR_WIDTH-1:0] l1_mem_addr;
    wire [63:0] l1_mem_wdata;
    wire [7:0] l1_mem_wstrb;
    wire [63:0] l1_mem_rdata;
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
    reg [63:0] request_l1_addr_q;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] request_wdata_q;
    reg [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] request_wstrb_q;
    reg request_buffered_store_q;
    reg command_sent_q;
    reg wdata_sent_q;

    // Native line buffers retain complete CCX responses while the shared
    // 64-bit SRAM controller consumes the line one word at a time.
    reg fill_buffer_valid_q [0:FILL_BUFFER_LINES-1];
    reg [63:0] fill_buffer_addr_q [0:FILL_BUFFER_LINES-1];
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        fill_buffer_data_q [0:FILL_BUFFER_LINES-1];
    reg fill_buffer_prefetch_q [0:FILL_BUFFER_LINES-1];

    // Posted stores are cacheline records with per-byte validity.  Scalar
    // stores occupy the addressed 64-bit lane; L2 or the memory controller may
    // merge the masked line write later.  FIFO order is retained locally.
    reg store_buffer_valid_q [0:STORE_BUFFER_LINES-1];
    reg [63:0] store_buffer_addr_q [0:STORE_BUFFER_LINES-1];
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        store_buffer_data_q [0:STORE_BUFFER_LINES-1];
    reg [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
        store_buffer_strb_q [0:STORE_BUFFER_LINES-1];
    reg [STORE_BUFFER_INDEX_WIDTH-1:0] store_buffer_head_q;
    reg [STORE_BUFFER_INDEX_WIDTH-1:0] store_buffer_tail_q;
    reg [STORE_BUFFER_COUNT_WIDTH-1:0] store_buffer_count_q;
    reg store_completion_valid_q;
    reg store_completion_error_q;

    reg fill_buffer_hit_r;
    reg [FILL_BUFFER_INDEX_WIDTH-1:0] fill_buffer_hit_index_r;
    reg fill_buffer_free_found_r;
    reg [FILL_BUFFER_INDEX_WIDTH-1:0] fill_buffer_free_index_r;
    reg fill_buffer_prefetch_found_r;
    reg [FILL_BUFFER_INDEX_WIDTH-1:0] fill_buffer_prefetch_index_r;
    integer fill_buffer_free_count_r;
    integer fill_buffer_scan;
    integer buffer_reset_index;
    reg locked_line_invalidated_q;
    reg active_req_lock_q;
    reg active_req_posted_q;
    reg active_req_cacheable_q;
    reg [2:0] active_req_size_q;
    reg [REQ_TAG_WIDTH-1:0] response_tag_q [0:REQ_DEPTH-1];
    reg [REQ_INDEX_WIDTH-1:0] response_tag_head_q;
    reg [REQ_INDEX_WIDTH-1:0] response_tag_tail_q;
    reg [REQ_COUNT_WIDTH-1:0] response_tag_count_q;
    integer response_tag_reset_index;

    // A deliberately small address-trained predictor.  Repeated accesses to
    // the same line are ignored, so an ordinary scalar word loop appears as a
    // stable +1 line stream rather than seven zero deltas followed by +1.
    reg prefetch_train_valid_q;
    reg [63:0] prefetch_last_line_q;
    reg prefetch_stride_valid_q;
    reg signed [63:0] prefetch_stride_q;
    reg [1:0] prefetch_confidence_q;
    reg signed [63:0] prefetch_generate_stride_q;
    reg prefetch_generation_active_q;
    reg [4:0] prefetch_depth_q;
    reg [1:0] prefetch_waste_q;
    reg prefetch_candidate_valid_q [0:PREFETCH_QUEUE_LINES-1];
    reg [63:0] prefetch_candidate_addr_q [0:PREFETCH_QUEUE_LINES-1];
    reg prefetch_window_issued_q [0:PREFETCH_MAX_DISTANCE-1];
    reg prefetch_mshr_valid_q [0:PREFETCH_OUTSTANDING-1];
    reg [63:0] prefetch_mshr_addr_q [0:PREFETCH_OUTSTANDING-1];
    reg prefetch_mshr_discard_q [0:PREFETCH_OUTSTANDING-1];
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
    reg signed [63:0] prefetch_generate_window_advance_r;
    reg [63:0] prefetch_generate_window_addr_r;
    reg signed [63:0] prefetch_launch_window_advance_r;
    reg [63:0] prefetch_launch_window_addr_r;
    integer prefetch_queue_scan;
    integer prefetch_depth_scan;
    integer prefetch_duplicate_scan;
    integer prefetch_duplicate_fill_scan;
    integer prefetch_duplicate_mshr_scan;
    integer prefetch_launch_depth_scan;
    integer prefetch_launch_queue_scan;
    integer prefetch_launch_store_scan;
    integer prefetch_reset_index;
    integer prefetch_mshr_scan;

    wire l1_req_ready;
    wire l1_resp_valid;
    wire l1_invalidate_ready;
    wire lock_invalidate_request = req_valid_i && req_lock_i &&
        !locked_line_invalidated_q;
    wire lock_invalidate_fire = lock_invalidate_request &&
        !invalidate_valid_i && l1_invalidate_ready;
    wire l1_invalidate_valid = invalidate_valid_i ||
        lock_invalidate_request;
    wire l1_invalidate_all = invalidate_valid_i && invalidate_all_i;
    wire [ADDR_WIDTH-1:0] l1_invalidate_addr = invalidate_valid_i ?
        invalidate_addr_i : req_addr_i;
    wire response_tag_full =
        response_tag_count_q == REQ_COUNT_WIDTH'(REQ_DEPTH);
    wire lock_request_ready = !req_lock_i || locked_line_invalidated_q;
    wire l1_req_valid = req_valid_i && !response_tag_full &&
        lock_request_ready;
    wire l1_req_cacheable = req_cacheable_i && !req_lock_i;
    wire l1_request_fire = l1_req_valid && l1_req_ready;
    wire l1_resp_ready = resp_ready_i && (response_tag_count_q != 0);
    wire l1_response_fire = l1_resp_valid && l1_resp_ready;
    wire [63:0] demand_line_addr = {req_addr_i[63:6], 6'b0};
    wire prefetch_train_event = (PREFETCH_ENABLE != 0) &&
        (ENABLE != 0) && l1_request_fire && !req_write_i &&
        l1_req_cacheable && !req_lock_i &&
        (!prefetch_train_valid_q ||
         (demand_line_addr != prefetch_last_line_q));
    wire signed [63:0] prefetch_observed_delta =
        $signed(demand_line_addr) - $signed(prefetch_last_line_q);
    localparam signed [63:0] PREFETCH_MAX_STRIDE_BYTES =
        PREFETCH_MAX_STRIDE_LINES * LINE_BYTES;
    wire prefetch_delta_eligible =
        (prefetch_observed_delta != 0) &&
        (prefetch_observed_delta <= PREFETCH_MAX_STRIDE_BYTES) &&
        (prefetch_observed_delta >= -PREFETCH_MAX_STRIDE_BYTES);
    wire prefetch_stride_match = prefetch_train_valid_q &&
        prefetch_stride_valid_q && prefetch_delta_eligible &&
        (prefetch_observed_delta == prefetch_stride_q);
    wire prefetch_stream_change = prefetch_train_event &&
        prefetch_train_valid_q && !prefetch_stride_match;

    // Preserve the LSU tag at acceptance.  Misses can block the lower side,
    // but resident hits retain the shared L1's one-request-per-cycle contract.
    assign req_ready_o = l1_req_ready && !response_tag_full &&
                         lock_request_ready;
    assign resp_valid_o = l1_resp_valid &&
                          (response_tag_count_q != 0);
    assign resp_tag_o = response_tag_q[response_tag_head_q];
    assign invalidate_ready_o = l1_invalidate_ready &&
        !lock_invalidate_request && (store_buffer_count_q == 0);

    wire [2:0] l1_mem_word = l1_mem_addr[5:3];
    wire [2:0] response_word = request_l1_addr_q[5:3];
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
                l1_request_fire && !req_write_i && l1_req_cacheable &&
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
            if (!fill_buffer_prefetch_found_r &&
                fill_buffer_valid_q[fill_buffer_scan] &&
                fill_buffer_prefetch_q[fill_buffer_scan]) begin
                fill_buffer_prefetch_found_r = 1'b1;
                fill_buffer_prefetch_index_r =
                    fill_buffer_scan[FILL_BUFFER_INDEX_WIDTH-1:0];
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
                l1_request_fire && !req_write_i && l1_req_cacheable &&
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
        prefetch_generate_duplicate_r = 1'b0;
        prefetch_generate_window_advance_r = 64'sd0;
        prefetch_generate_window_addr_r = 64'd0;
        for (prefetch_depth_scan = 1;
             prefetch_depth_scan <= PREFETCH_MAX_DISTANCE;
             prefetch_depth_scan = prefetch_depth_scan + 1) begin
            prefetch_generate_window_advance_r =
                prefetch_generate_stride_q * prefetch_depth_scan;
            prefetch_generate_window_addr_r =
                $unsigned($signed(prefetch_last_line_q) +
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
                if (prefetch_candidate_valid_q[prefetch_duplicate_scan] &&
                    (prefetch_candidate_addr_q[prefetch_duplicate_scan] ==
                     prefetch_generate_window_addr_r))
                    prefetch_generate_duplicate_r = 1'b1;
            end
            for (prefetch_duplicate_fill_scan = 0;
                 prefetch_duplicate_fill_scan < FILL_BUFFER_LINES;
                 prefetch_duplicate_fill_scan =
                     prefetch_duplicate_fill_scan + 1) begin
                if (fill_buffer_valid_q[prefetch_duplicate_fill_scan] &&
                    (fill_buffer_addr_q[prefetch_duplicate_fill_scan] ==
                     prefetch_generate_window_addr_r))
                    prefetch_generate_duplicate_r = 1'b1;
            end
            if (!prefetch_generate_valid_r &&
                (PREFETCH_ENABLE != 0) && (ENABLE != 0) &&
                prefetch_train_valid_q && prefetch_generation_active_q &&
                !prefetch_train_event &&
                !prefetch_invalidate_fire &&
                (prefetch_depth_scan <= prefetch_depth_q) &&
                !prefetch_window_issued_q[prefetch_depth_scan - 1] &&
                (PREFETCH_CACHEABLE_SIZE != 0) &&
                ((prefetch_generate_window_addr_r -
                  PREFETCH_CACHEABLE_BASE) <
                 PREFETCH_CACHEABLE_SIZE) &&
                !prefetch_generate_duplicate_r) begin
                prefetch_generate_valid_r = 1'b1;
                prefetch_generate_addr_r =
                    prefetch_generate_window_addr_r;
                prefetch_generate_index_r =
                    PREFETCH_WINDOW_INDEX_WIDTH'(
                        prefetch_depth_scan - 1);
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
            prefetch_launch_window_advance_r =
                prefetch_generate_stride_q * prefetch_launch_depth_scan;
            prefetch_launch_window_addr_r =
                $unsigned($signed(prefetch_last_line_q) +
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
                    if (store_buffer_valid_q[prefetch_launch_store_scan] &&
                        (store_buffer_addr_q[prefetch_launch_store_scan] ==
                         prefetch_candidate_addr_q[
                             prefetch_launch_queue_scan]))
                        prefetch_launch_store_conflict_r = 1'b1;
                end
                if (!prefetch_launch_found_r &&
                    prefetch_candidate_valid_q[
                        prefetch_launch_queue_scan] &&
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

    wire refill_buffer_hit = fill_buffer_hit_r && l1_mem_valid &&
        !l1_mem_write && active_req_cacheable_q;
    wire [63:0] refill_buffer_word =
        fill_buffer_data_q[fill_buffer_hit_index_r]
            [l1_mem_word*64 +: 64];
    wire [63:0] response_word_data =
        ccx_resp_rdata_i[response_word*64 +: 64];

    wire store_buffer_full =
        (store_buffer_count_q ==
         STORE_BUFFER_COUNT_WIDTH'(STORE_BUFFER_LINES));
    wire postable_store = l1_mem_valid && l1_mem_write &&
                          active_req_cacheable_q && active_req_posted_q;
    wire store_buffer_enqueue = postable_store && !store_buffer_full;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        posted_store_line_data =
            {{(`OPENRV64_CCX_LINE_DATA_WIDTH-64){1'b0}}, l1_mem_wdata}
            << (l1_mem_addr[5:3] * 64);
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
        posted_store_line_strb =
            {{(`OPENRV64_CCX_LINE_STRB_WIDTH-8){1'b0}}, l1_mem_wstrb}
            << (l1_mem_addr[5:3] * 8);

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
    wire store_completion_fire = store_completion_valid_q &&
                                 store_resp_ready_i;
    wire response_protocol_error =
        (ccx_resp_beat_index_i != 0) || !ccx_resp_last_i;
    wire command_fire = ccx_req_valid_o && ccx_req_ready_i;
    wire wdata_fire = ccx_wdata_valid_o && ccx_wdata_ready_i;
    wire line_response_slot_available = fill_buffer_free_found_r ||
                                        fill_buffer_prefetch_found_r;
    wire prefetch_slot_available =
        (fill_buffer_free_count_r > PREFETCH_DEMAND_RESERVE) ||
        fill_buffer_prefetch_found_r;
    wire prefetch_response_uses_free =
        fill_buffer_free_count_r > PREFETCH_DEMAND_RESERVE;
    wire prefetch_launch = (PREFETCH_ENABLE != 0) &&
        (ENABLE != 0) && (backend_state_q == BACKEND_IDLE) &&
        !(l1_mem_valid && !refill_buffer_hit && !postable_store) &&
        prefetch_launch_found_r && prefetch_slot_available &&
        prefetch_mshr_free_found_r;
    wire prefetch_candidate_queue = prefetch_generate_valid_r &&
        prefetch_candidate_free_found_r;
    wire prefetch_candidate_drop = prefetch_generate_valid_r &&
        !prefetch_candidate_free_found_r;
    wire prefetch_inflight_late_match = prefetch_command_inflight &&
        !prefetch_late_reported_q && l1_request_fire && !req_write_i &&
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
        prefetch_mshr_response_invalidated ||
        prefetch_mshr_response_stored;
    wire prefetch_useless_replace = prefetch_response_fire &&
        !prefetch_response_discard &&
        !ccx_resp_error_i && !response_protocol_error &&
        !prefetch_response_uses_free && fill_buffer_prefetch_found_r;

    assign ccx_req_valid_o = (backend_state_q == BACKEND_SEND) &&
                             !command_sent_q;
    assign ccx_req_hart_id_o = HART_ID;
    assign ccx_req_txn_id_o = request_txn_id_q;
    assign ccx_req_source_id_o = `OPENRV64_CCX_SOURCE_DCACHE;
    assign ccx_req_op_o = request_write_q ? `OPENRV64_CCX_OP_WRITE :
                                             `OPENRV64_CCX_OP_READ;
    assign ccx_req_lock_o = request_lock_q;
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
        !l1_mem_write && fill_buffer_prefetch_q[fill_buffer_hit_index_r] &&
        (l1_mem_word == 3'd0);
    assign prefetch_late_o = prefetch_late_match;
    assign prefetch_dropped_o = prefetch_candidate_drop;
    assign prefetch_useless_o = prefetch_useless_replace;
    assign prefetch_depth_o = prefetch_depth_q;

    wire main_response_buffer_available = !request_line_read_q ||
        ccx_resp_error_i ||
        response_protocol_error || line_response_slot_available;
    wire prefetch_response_buffer_available =
        prefetch_response_discard || ccx_resp_error_i ||
        response_protocol_error || prefetch_slot_available;
    assign ccx_resp_ready_o =
        ((backend_state_q == BACKEND_WAIT) &&
         response_identity_match && main_response_buffer_available) ||
        (prefetch_mshr_response_match_r &&
         prefetch_response_buffer_available);
    assign l1_mem_ready = store_buffer_enqueue || refill_buffer_hit ||
                          (l1_mem_valid && main_response_fire &&
                           !request_buffered_store_q);
    assign l1_mem_rdata = store_buffer_enqueue ? 64'd0 :
                           refill_buffer_hit ? refill_buffer_word :
                           response_word_data;
    assign l1_mem_error = l1_mem_valid && main_response_fire &&
                          !request_buffered_store_q &&
                          (ccx_resp_error_i || response_protocol_error);

    openrv64_l1d #(
        .ENABLE(ENABLE),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(64),
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
        .req_rdata_o(req_rdata_o),
        .req_error_o(req_error_o),
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
            request_l1_addr_q <= 64'd0;
            request_wdata_q <=
                {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
            request_wstrb_q <=
                {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b0}};
            request_buffered_store_q <= 1'b0;
            request_prefetch_q <= 1'b0;
            request_prefetch_mshr_q <=
                {PREFETCH_MSHR_INDEX_WIDTH{1'b0}};
            request_discard_q <= 1'b0;
            prefetch_late_reported_q <= 1'b0;
            command_sent_q <= 1'b0;
            wdata_sent_q <= 1'b0;
            store_buffer_head_q <=
                {STORE_BUFFER_INDEX_WIDTH{1'b0}};
            store_buffer_tail_q <=
                {STORE_BUFFER_INDEX_WIDTH{1'b0}};
            store_buffer_count_q <=
                {STORE_BUFFER_COUNT_WIDTH{1'b0}};
            store_completion_valid_q <= 1'b0;
            store_completion_error_q <= 1'b0;
            locked_line_invalidated_q <= 1'b0;
            active_req_lock_q <= 1'b0;
            active_req_posted_q <= 1'b0;
            active_req_cacheable_q <= 1'b0;
            active_req_size_q <= 3'd0;
            response_tag_head_q <= {REQ_INDEX_WIDTH{1'b0}};
            response_tag_tail_q <= {REQ_INDEX_WIDTH{1'b0}};
            response_tag_count_q <= {REQ_COUNT_WIDTH{1'b0}};
            prefetch_train_valid_q <= 1'b0;
            prefetch_last_line_q <= 64'd0;
            prefetch_stride_valid_q <= 1'b0;
            prefetch_stride_q <= 64'sd0;
            prefetch_confidence_q <= 2'd0;
            prefetch_generate_stride_q <= PREFETCH_NEXT_LINE_STRIDE;
            prefetch_generation_active_q <= 1'b0;
            prefetch_depth_q <= PREFETCH_INITIAL_DEPTH;
            prefetch_waste_q <= 2'd0;
            for (prefetch_reset_index = 0;
                 prefetch_reset_index < PREFETCH_QUEUE_LINES;
                 prefetch_reset_index = prefetch_reset_index + 1) begin
                prefetch_candidate_valid_q[prefetch_reset_index] <= 1'b0;
                prefetch_candidate_addr_q[prefetch_reset_index] <= 64'd0;
            end
            for (prefetch_reset_index = 0;
                 prefetch_reset_index < PREFETCH_MAX_DISTANCE;
                 prefetch_reset_index = prefetch_reset_index + 1)
                prefetch_window_issued_q[prefetch_reset_index] <= 1'b0;
            for (prefetch_reset_index = 0;
                 prefetch_reset_index < PREFETCH_OUTSTANDING;
                 prefetch_reset_index = prefetch_reset_index + 1) begin
                prefetch_mshr_valid_q[prefetch_reset_index] <= 1'b0;
                prefetch_mshr_addr_q[prefetch_reset_index] <= 64'd0;
                prefetch_mshr_discard_q[prefetch_reset_index] <= 1'b0;
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
            end
            for (response_tag_reset_index = 0;
                 response_tag_reset_index < REQ_DEPTH;
                 response_tag_reset_index =
                     response_tag_reset_index + 1)
                response_tag_q[response_tag_reset_index] <=
                    {REQ_TAG_WIDTH{1'b0}};
        end else begin
            if (prefetch_train_event) begin
                prefetch_train_valid_q <= 1'b1;
                prefetch_last_line_q <= demand_line_addr;
                prefetch_generation_active_q <= 1'b1;
                prefetch_generate_stride_q <= prefetch_stride_match ?
                    prefetch_observed_delta :
                    PREFETCH_NEXT_LINE_STRIDE;
                for (prefetch_reset_index = 0;
                     prefetch_reset_index < PREFETCH_MAX_DISTANCE;
                     prefetch_reset_index =
                         prefetch_reset_index + 1)
                    prefetch_window_issued_q[
                        prefetch_reset_index] <= 1'b0;
                if (prefetch_train_valid_q) begin
                    if (!prefetch_delta_eligible) begin
                        prefetch_stride_valid_q <= 1'b0;
                        prefetch_confidence_q <= 2'd0;
                    end else if (!prefetch_stride_valid_q) begin
                        prefetch_stride_valid_q <= 1'b1;
                        prefetch_stride_q <= prefetch_observed_delta;
                        prefetch_confidence_q <= 2'd0;
                    end else if (prefetch_observed_delta ==
                                 prefetch_stride_q) begin
                        if (prefetch_confidence_q != 2'b11)
                            prefetch_confidence_q <=
                                prefetch_confidence_q + 1'b1;
                    end else if (prefetch_confidence_q != 0) begin
                        prefetch_confidence_q <=
                            prefetch_confidence_q - 1'b1;
                    end else begin
                        prefetch_stride_q <= prefetch_observed_delta;
                        prefetch_confidence_q <= 2'd0;
                    end
                end
            end

            if (prefetch_launch)
                prefetch_candidate_valid_q[
                    prefetch_launch_index_r] <= 1'b0;
            if (l1_request_fire || prefetch_stream_change) begin
                for (prefetch_reset_index = 0;
                     prefetch_reset_index < PREFETCH_QUEUE_LINES;
                     prefetch_reset_index =
                         prefetch_reset_index + 1) begin
                    if (prefetch_stream_change ||
                        (prefetch_candidate_valid_q[
                             prefetch_reset_index] &&
                         (prefetch_candidate_addr_q[
                              prefetch_reset_index] ==
                          demand_line_addr)))
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
                prefetch_window_issued_q[
                    prefetch_generate_index_r] <= 1'b1;
            end
            if (prefetch_candidate_drop)
                prefetch_window_issued_q[
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
                active_req_cacheable_q <= l1_req_cacheable;
                active_req_size_q <= req_size_i;
                response_tag_q[response_tag_tail_q] <= req_tag_i;
                response_tag_tail_q <=
                    (response_tag_tail_q ==
                     REQ_INDEX_WIDTH'(REQ_DEPTH - 1)) ?
                    {REQ_INDEX_WIDTH{1'b0}} :
                    response_tag_tail_q + 1'b1;
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

            if (refill_buffer_hit && (l1_mem_word == 3'd7)) begin
                fill_buffer_valid_q[fill_buffer_hit_index_r] <= 1'b0;
                fill_buffer_prefetch_q[fill_buffer_hit_index_r] <= 1'b0;
            end

            if (store_buffer_enqueue) begin
                store_buffer_valid_q[store_buffer_tail_q] <= 1'b1;
                store_buffer_addr_q[store_buffer_tail_q] <=
                    {l1_mem_addr[63:6], 6'b0};
                store_buffer_data_q[store_buffer_tail_q] <=
                    posted_store_line_data;
                store_buffer_strb_q[store_buffer_tail_q] <=
                    posted_store_line_strb;
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

            if (store_completion_fire) begin
                store_completion_valid_q <= 1'b0;
                store_completion_error_q <= 1'b0;
                store_buffer_valid_q[store_buffer_head_q] <= 1'b0;
                store_buffer_head_q <=
                    (store_buffer_head_q ==
                     STORE_BUFFER_INDEX_WIDTH'(STORE_BUFFER_LINES - 1)) ?
                    {STORE_BUFFER_INDEX_WIDTH{1'b0}} :
                    store_buffer_head_q + 1'b1;
            end

            case ({store_buffer_enqueue, store_completion_fire})
                2'b10: store_buffer_count_q <=
                    store_buffer_count_q + 1'b1;
                2'b01: store_buffer_count_q <=
                    store_buffer_count_q - 1'b1;
                default: store_buffer_count_q <= store_buffer_count_q;
            endcase

            case (backend_state_q)
                BACKEND_IDLE: begin
                    if (prefetch_launch) begin
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
                        request_l1_addr_q <= prefetch_launch_addr_r;
                        request_wdata_q <=
                            {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
                        request_wstrb_q <=
                            {`OPENRV64_CCX_LINE_STRB_WIDTH{1'b0}};
                        request_buffered_store_q <= 1'b0;
                        request_prefetch_q <= 1'b1;
                        request_discard_q <= 1'b0;
                        prefetch_late_reported_q <= 1'b0;
                        command_sent_q <= 1'b0;
                        wdata_sent_q <= 1'b0;
                        backend_state_q <= BACKEND_SEND;
                    end else if ((store_buffer_count_q != 0) &&
                        store_buffer_valid_q[store_buffer_head_q] &&
                        !store_completion_valid_q) begin
                        request_txn_id_q <= next_txn_id_q;
                        next_txn_id_q <= next_main_txn_id;
                        request_write_q <= 1'b1;
                        request_lock_q <= 1'b0;
                        request_cacheable_q <= 1'b1;
                        request_line_read_q <= 1'b0;
                        request_size_q <= 3'd6;
                        request_addr_q <=
                            store_buffer_addr_q[store_buffer_head_q];
                        request_l1_addr_q <=
                            store_buffer_addr_q[store_buffer_head_q];
                        request_wdata_q <=
                            store_buffer_data_q[store_buffer_head_q];
                        request_wstrb_q <=
                            store_buffer_strb_q[store_buffer_head_q];
                        request_buffered_store_q <= 1'b1;
                        request_prefetch_q <= 1'b0;
                        request_discard_q <= 1'b0;
                        prefetch_late_reported_q <= 1'b0;
                        command_sent_q <= 1'b0;
                        wdata_sent_q <= 1'b0;
                        backend_state_q <= BACKEND_SEND;
                    end else if (l1_mem_valid && !refill_buffer_hit &&
                                 !postable_store &&
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
                        request_l1_addr_q <= l1_mem_addr;
                        request_wdata_q <=
                            {{(`OPENRV64_CCX_LINE_DATA_WIDTH-64){1'b0}},
                              l1_mem_wdata} << (l1_mem_addr[5:3] * 64);
                        request_wstrb_q <=
                            {{(`OPENRV64_CCX_LINE_STRB_WIDTH-8){1'b0}},
                              l1_mem_wstrb} << (l1_mem_addr[5:3] * 8);
                        request_buffered_store_q <= 1'b0;
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
                        if (request_line_read_q && (ENABLE != 0) &&
                            !ccx_resp_error_i &&
                            !response_protocol_error) begin
                            fill_buffer_valid_q[
                                fill_buffer_free_found_r ?
                                fill_buffer_free_index_r :
                                fill_buffer_prefetch_index_r] <= 1'b1;
                            fill_buffer_addr_q[
                                fill_buffer_free_found_r ?
                                fill_buffer_free_index_r :
                                fill_buffer_prefetch_index_r] <=
                                request_addr_q;
                            fill_buffer_data_q[
                                fill_buffer_free_found_r ?
                                fill_buffer_free_index_r :
                                fill_buffer_prefetch_index_r] <=
                                ccx_resp_rdata_i;
                            fill_buffer_prefetch_q[
                                fill_buffer_free_found_r ?
                                fill_buffer_free_index_r :
                                fill_buffer_prefetch_index_r] <=
                                1'b0;
                        end
                        backend_state_q <= BACKEND_IDLE;
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
                end
            end

            if (prefetch_invalidate_fire) begin
                prefetch_generation_active_q <= 1'b0;
                if (l1_invalidate_all) begin
                    prefetch_train_valid_q <= 1'b0;
                    prefetch_stride_valid_q <= 1'b0;
                    prefetch_confidence_q <= 2'd0;
                    prefetch_depth_q <= PREFETCH_INITIAL_DEPTH;
                    prefetch_waste_q <= 2'd0;
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
                prefetch_generation_active_q <= 1'b0;
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
        if ((REQ_DEPTH < 1) || (REQ_DEPTH > (1 << REQ_TAG_WIDTH)))
            $fatal(1, "L1D request depth must fit its tag width");
        if ((PREFETCH_ENABLE != 0) && (PREFETCH_ENABLE != 1))
            $fatal(1, "L1D prefetch enable must be zero or one");
        if ((PREFETCH_ADAPTIVE_ENABLE != 0) &&
            (PREFETCH_ADAPTIVE_ENABLE != 1))
            $fatal(1, "L1D adaptive prefetch enable must be zero or one");
        if ((PREFETCH_MAX_STRIDE_LINES < 1) ||
            (PREFETCH_MAX_STRIDE_LINES > 1048576))
            $fatal(1, "L1D prefetch maximum stride must be 1 through 1048576 lines");
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
        if ((PREFETCH_DEMAND_RESERVE < 0) ||
            (PREFETCH_DEMAND_RESERVE >= FILL_BUFFER_LINES))
            $fatal(1, "L1D prefetch demand reserve must leave at least one speculative slot");
    end
`endif

endmodule
