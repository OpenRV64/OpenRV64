`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/bus/bus-defs.v"

// Data-side specialization.  Stores are write-through and no-write-allocate;
// reads use the shared eight-way L1 implementation.
module openrv64_l1d #(
    parameter integer ENABLE = 1,
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 64,
    parameter integer CACHE_BYTES = 8 * 1024,
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
    parameter integer CACHE_BYTES = 8 * 1024,
    parameter integer LINE_BYTES = 64,
    parameter integer WAYS = 8,
    parameter integer FILL_BUFFER_LINES = 8,
    parameter integer STORE_BUFFER_LINES = 8,
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
    always @* begin
        fill_buffer_hit_r = 1'b0;
        fill_buffer_hit_index_r =
            {FILL_BUFFER_INDEX_WIDTH{1'b0}};
        fill_buffer_free_found_r = 1'b0;
        fill_buffer_free_index_r =
            {FILL_BUFFER_INDEX_WIDTH{1'b0}};
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
    wire response_fire = ccx_resp_valid_i && ccx_resp_ready_o;
    wire buffered_store_response = response_fire &&
                                   request_buffered_store_q;
    wire store_completion_fire = store_completion_valid_q &&
                                 store_resp_ready_i;
    wire response_protocol_error =
        (ccx_resp_beat_index_i != 0) || !ccx_resp_last_i;
    wire command_fire = ccx_req_valid_o && ccx_req_ready_i;
    wire wdata_fire = ccx_wdata_valid_o && ccx_wdata_ready_i;

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

    wire response_buffer_available = !request_line_read_q ||
                                     fill_buffer_free_found_r;
    assign ccx_resp_ready_o = (backend_state_q == BACKEND_WAIT) &&
                              response_identity_match &&
                              response_buffer_available;
    assign l1_mem_ready = store_buffer_enqueue || refill_buffer_hit ||
                          (l1_mem_valid && response_fire &&
                           !request_buffered_store_q);
    assign l1_mem_rdata = store_buffer_enqueue ? 64'd0 :
                           refill_buffer_hit ? refill_buffer_word :
                           response_word_data;
    assign l1_mem_error = l1_mem_valid && response_fire &&
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
            for (buffer_reset_index = 0;
                 buffer_reset_index < FILL_BUFFER_LINES;
                 buffer_reset_index = buffer_reset_index + 1) begin
                fill_buffer_valid_q[buffer_reset_index] <= 1'b0;
                fill_buffer_addr_q[buffer_reset_index] <= 64'd0;
                fill_buffer_data_q[buffer_reset_index] <=
                    {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
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

            if (refill_buffer_hit && (l1_mem_word == 3'd7))
                fill_buffer_valid_q[fill_buffer_hit_index_r] <= 1'b0;

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
                    if ((store_buffer_count_q != 0) &&
                        store_buffer_valid_q[store_buffer_head_q] &&
                        !store_completion_valid_q) begin
                        request_txn_id_q <= next_txn_id_q;
                        next_txn_id_q <= next_txn_id_q + 1'b1;
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
                        command_sent_q <= 1'b0;
                        wdata_sent_q <= 1'b0;
                        backend_state_q <= BACKEND_SEND;
                    end else if (l1_mem_valid && !refill_buffer_hit &&
                                 !postable_store) begin
                        request_txn_id_q <= next_txn_id_q;
                        next_txn_id_q <= next_txn_id_q + 1'b1;
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
                        command_sent_q <= 1'b0;
                        wdata_sent_q <= 1'b0;
                        backend_state_q <= BACKEND_SEND;
                    end
                end

                BACKEND_SEND: begin
                    if (command_fire)
                        command_sent_q <= 1'b1;
                    if (wdata_fire)
                        wdata_sent_q <= 1'b1;
                    if ((command_sent_q || command_fire) &&
                        (!request_write_q || wdata_sent_q || wdata_fire))
                        backend_state_q <= BACKEND_WAIT;
                end

                BACKEND_WAIT: begin
                    if (response_fire) begin
                        if (request_line_read_q && (ENABLE != 0) &&
                            !ccx_resp_error_i &&
                            !response_protocol_error) begin
                            fill_buffer_valid_q[
                                fill_buffer_free_index_r] <= 1'b1;
                            fill_buffer_addr_q[
                                fill_buffer_free_index_r] <= request_addr_q;
                            fill_buffer_data_q[
                                fill_buffer_free_index_r] <=
                                ccx_resp_rdata_i;
                        end
                        backend_state_q <= BACKEND_IDLE;
                    end
                end

                default: backend_state_q <= BACKEND_IDLE;
            endcase
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
    end
`endif

endmodule
