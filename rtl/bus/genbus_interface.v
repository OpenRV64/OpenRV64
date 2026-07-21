`timescale 1ns/1ps
`include "complex/bus/defs.v"

// Shared buffered width and protocol boundary for cache-like producers.
//
// One neutral upstream request describes at most one UPSTREAM_DATA_WIDTH beat.
// AXI requests wider than the downstream port become INCR bursts. Narrow
// requests remain one correctly lane-positioned transfer. Independent read
// and write buffers allow multiple same-ID AXI transactions to be outstanding;
// the untagged upstream response stream is restored to acceptance order.
// Cross-direction requests with overlapping byte ranges are not issued past
// one another. Non-overlapping reads and writes may execute concurrently.
//
// WISHBONE uses the same admission and response buffers but drains requests in
// global order through one Classic-cycle backend. Its RTY policy remains in
// openrv64_complex_wishbone_backend.
module genbus_interface #(
    parameter integer BUS_TYPE = `OPENRV64_COMPLEX_BUS_AXI,
    parameter integer ADDR_WIDTH = 64,
    parameter integer UPSTREAM_DATA_WIDTH = 256,
    parameter integer DOWNSTREAM_DATA_WIDTH = 256,
    parameter integer READ_BUFFER_DEPTH = 4,
    parameter integer WRITE_BUFFER_DEPTH = 4,
    parameter integer AXI_ID_WIDTH = 3,
    parameter [AXI_ID_WIDTH-1:0] AXI_ID = {AXI_ID_WIDTH{1'b1}},
    parameter integer WB_ADDR_SHIFT =
        $clog2(DOWNSTREAM_DATA_WIDTH / 8),
    parameter integer WB_MAX_RETRIES = 8
) (
    input  wire                                      clk_i,
    input  wire                                      rst_ni,

    input  wire                                      upstream_req_valid_i,
    output wire                                      upstream_req_ready_o,
    input  wire                                      upstream_req_write_i,
    input  wire [63:0]                               upstream_req_addr_i,
    input  wire [2:0]                                upstream_req_size_i,
    // AXI-LEN convention over following neutral read requests: zero means
    // this request only, N means coalesce this request plus the next N.
    input  wire [7:0]                                upstream_req_burst_i,
    input  wire [UPSTREAM_DATA_WIDTH-1:0]            upstream_req_wdata_i,
    input  wire [UPSTREAM_DATA_WIDTH/8-1:0]          upstream_req_wstrb_i,
    input  wire                                      upstream_req_cacheable_i,
    output wire                                      upstream_resp_valid_o,
    input  wire                                      upstream_resp_ready_i,
    output wire [UPSTREAM_DATA_WIDTH-1:0]            upstream_resp_rdata_o,
    output wire                                      upstream_resp_error_o,

    output wire [AXI_ID_WIDTH-1:0]                   m_axi_arid_o,
    output wire [ADDR_WIDTH-1:0]                     m_axi_araddr_o,
    output wire [7:0]                                m_axi_arlen_o,
    output wire [2:0]                                m_axi_arsize_o,
    output wire [1:0]                                m_axi_arburst_o,
    output wire                                      m_axi_arlock_o,
    output wire [3:0]                                m_axi_arcache_o,
    output wire [2:0]                                m_axi_arprot_o,
    output wire [3:0]                                m_axi_arqos_o,
    output wire                                      m_axi_arvalid_o,
    input  wire                                      m_axi_arready_i,
    input  wire [AXI_ID_WIDTH-1:0]                   m_axi_rid_i,
    input  wire [DOWNSTREAM_DATA_WIDTH-1:0]          m_axi_rdata_i,
    input  wire [1:0]                                m_axi_rresp_i,
    input  wire                                      m_axi_rlast_i,
    input  wire                                      m_axi_rvalid_i,
    output wire                                      m_axi_rready_o,

    output wire [AXI_ID_WIDTH-1:0]                   m_axi_awid_o,
    output wire [ADDR_WIDTH-1:0]                     m_axi_awaddr_o,
    output wire [7:0]                                m_axi_awlen_o,
    output wire [2:0]                                m_axi_awsize_o,
    output wire [1:0]                                m_axi_awburst_o,
    output wire                                      m_axi_awlock_o,
    output wire [3:0]                                m_axi_awcache_o,
    output wire [2:0]                                m_axi_awprot_o,
    output wire [3:0]                                m_axi_awqos_o,
    output wire                                      m_axi_awvalid_o,
    input  wire                                      m_axi_awready_i,
    output wire [DOWNSTREAM_DATA_WIDTH-1:0]          m_axi_wdata_o,
    output wire [DOWNSTREAM_DATA_WIDTH/8-1:0]        m_axi_wstrb_o,
    output wire                                      m_axi_wlast_o,
    output wire                                      m_axi_wvalid_o,
    input  wire                                      m_axi_wready_i,
    input  wire [AXI_ID_WIDTH-1:0]                   m_axi_bid_i,
    input  wire [1:0]                                m_axi_bresp_i,
    input  wire                                      m_axi_bvalid_i,
    output wire                                      m_axi_bready_o,

    output wire                                      wb_cyc_o,
    output wire                                      wb_stb_o,
    output wire                                      wb_we_o,
    output wire [ADDR_WIDTH-1:0]                     wb_adr_o,
    output wire [DOWNSTREAM_DATA_WIDTH-1:0]          wb_dat_o,
    output wire [DOWNSTREAM_DATA_WIDTH/8-1:0]        wb_sel_o,
    output wire [2:0]                                wb_cti_o,
    output wire [1:0]                                wb_bte_o,
    output wire                                      wb_lock_o,
    input  wire                                      wb_stall_i,
    input  wire                                      wb_ack_i,
    input  wire                                      wb_err_i,
    input  wire                                      wb_rty_i,
    input  wire [DOWNSTREAM_DATA_WIDTH-1:0]          wb_dat_i
);

    localparam integer UPSTREAM_BYTES = UPSTREAM_DATA_WIDTH / 8;
    localparam integer DOWNSTREAM_BYTES = DOWNSTREAM_DATA_WIDTH / 8;
    localparam integer DOWNSTREAM_SIZE = $clog2(DOWNSTREAM_BYTES);
    localparam integer MAX_BEATS =
        (UPSTREAM_BYTES > DOWNSTREAM_BYTES) ?
        (UPSTREAM_BYTES / DOWNSTREAM_BYTES) : 1;
    localparam integer BEAT_INDEX_WIDTH =
        (MAX_BEATS > 1) ? $clog2(MAX_BEATS) : 1;
    localparam integer READ_INDEX_WIDTH =
        (READ_BUFFER_DEPTH > 1) ? $clog2(READ_BUFFER_DEPTH) : 1;
    localparam integer WRITE_INDEX_WIDTH =
        (WRITE_BUFFER_DEPTH > 1) ? $clog2(WRITE_BUFFER_DEPTH) : 1;
    localparam integer READ_COUNT_WIDTH =
        $clog2(READ_BUFFER_DEPTH + 1);
    localparam integer WRITE_COUNT_WIDTH =
        $clog2(WRITE_BUFFER_DEPTH + 1);
    localparam integer ORDER_DEPTH =
        READ_BUFFER_DEPTH + WRITE_BUFFER_DEPTH;
    localparam integer ORDER_INDEX_WIDTH =
        (ORDER_DEPTH > 1) ? $clog2(ORDER_DEPTH) : 1;
    localparam integer ORDER_COUNT_WIDTH = $clog2(ORDER_DEPTH + 1);
    localparam integer SLOT_INDEX_WIDTH =
        (READ_INDEX_WIDTH > WRITE_INDEX_WIDTH) ?
        READ_INDEX_WIDTH : WRITE_INDEX_WIDTH;

    reg read_valid_q [0:READ_BUFFER_DEPTH-1];
    reg read_completed_q [0:READ_BUFFER_DEPTH-1];
    reg [63:0] read_addr_q [0:READ_BUFFER_DEPTH-1];
    reg [2:0] read_size_q [0:READ_BUFFER_DEPTH-1];
    reg [7:0] read_burst_q [0:READ_BUFFER_DEPTH-1];
    reg read_cacheable_q [0:READ_BUFFER_DEPTH-1];
    reg [UPSTREAM_DATA_WIDTH-1:0]
        read_data_q [0:READ_BUFFER_DEPTH-1];
    reg read_error_q [0:READ_BUFFER_DEPTH-1];

    reg write_valid_q [0:WRITE_BUFFER_DEPTH-1];
    reg write_completed_q [0:WRITE_BUFFER_DEPTH-1];
    reg write_aw_issued_q [0:WRITE_BUFFER_DEPTH-1];
    reg write_w_done_q [0:WRITE_BUFFER_DEPTH-1];
    reg [63:0] write_addr_q [0:WRITE_BUFFER_DEPTH-1];
    reg [2:0] write_size_q [0:WRITE_BUFFER_DEPTH-1];
    reg [UPSTREAM_DATA_WIDTH-1:0]
        write_data_q [0:WRITE_BUFFER_DEPTH-1];
    reg [UPSTREAM_BYTES-1:0]
        write_strobe_q [0:WRITE_BUFFER_DEPTH-1];
    reg write_cacheable_q [0:WRITE_BUFFER_DEPTH-1];
    reg write_error_q [0:WRITE_BUFFER_DEPTH-1];

    reg order_is_write_q [0:ORDER_DEPTH-1];
    reg [SLOT_INDEX_WIDTH-1:0] order_slot_q [0:ORDER_DEPTH-1];

    reg [READ_INDEX_WIDTH-1:0] read_tail_q;
    reg [READ_INDEX_WIDTH-1:0] read_issue_q;
    reg [READ_INDEX_WIDTH-1:0] read_response_q;
    reg [WRITE_INDEX_WIDTH-1:0] write_tail_q;
    reg [WRITE_INDEX_WIDTH-1:0] write_aw_issue_q;
    reg [WRITE_INDEX_WIDTH-1:0] write_data_issue_q;
    reg [WRITE_INDEX_WIDTH-1:0] write_response_q;
    reg [ORDER_INDEX_WIDTH-1:0] order_head_q;
    reg [ORDER_INDEX_WIDTH-1:0] order_tail_q;

    reg [READ_COUNT_WIDTH-1:0] read_count_q;
    reg [READ_COUNT_WIDTH-1:0] read_unissued_q;
    reg [READ_COUNT_WIDTH-1:0] read_axi_outstanding_q;
    reg [WRITE_COUNT_WIDTH-1:0] write_count_q;
    reg [WRITE_COUNT_WIDTH-1:0] write_unissued_q;
    reg [WRITE_COUNT_WIDTH-1:0] write_axi_outstanding_q;
    reg [ORDER_COUNT_WIDTH-1:0] order_count_q;

    reg [BEAT_INDEX_WIDTH-1:0] read_beat_q;
    reg [BEAT_INDEX_WIDTH-1:0] write_beat_q;
    reg [BEAT_INDEX_WIDTH-1:0] wb_beat_q;
    reg read_overrun_q;
    reg [8:0] read_group_remaining_q;
    reg [8:0] read_collect_remaining_q;
    reg [63:0] read_collect_next_addr_q;
    reg [2:0] read_collect_size_q;
    reg read_collect_cacheable_q;

    integer reset_index;
    integer map_byte;
    integer scan_position;
    integer scan_index;
    integer scan_slot;
    integer read_issue_bytes;
    integer read_issue_beats;
    integer read_declared_requests;
    integer read_issue_requests;
    integer read_issue_total_beats;
    integer read_max_axi_requests;
    integer read_max_4k_requests;
    integer read_remaining_requests;
    integer write_issue_bytes;
    integer write_issue_beats;
    integer read_response_bytes;
    integer read_response_beats;
    integer read_response_offset;
    integer read_response_up_lane;
    integer read_response_down_lane;
    integer read_response_up_byte;
    integer read_response_down_byte;
    integer read_response_group_remaining;
    integer read_response_advance;
    integer fault_member;
    integer fault_slot;
    integer write_data_bytes;
    integer write_data_beats;
    integer write_data_offset;
    integer write_data_up_lane;
    integer write_data_down_lane;
    integer write_data_up_byte;
    integer write_data_down_byte;
    integer wb_transfer_bytes;
    integer wb_transfer_beats;
    integer wb_beat_offset;
    integer wb_up_lane;
    integer wb_down_lane;
    integer wb_up_byte;
    integer wb_down_byte;

    reg read_issue_hazard;
    reg write_issue_hazard;
    reg read_candidate_seen;
    reg write_candidate_seen;
    reg [UPSTREAM_DATA_WIDTH-1:0] read_merged_data;
    reg [DOWNSTREAM_DATA_WIDTH-1:0] write_mapped_data;
    reg [DOWNSTREAM_BYTES-1:0] write_mapped_strobe;
    reg [63:0] wb_req_addr;
    reg [2:0] wb_req_size;
    reg [DOWNSTREAM_DATA_WIDTH-1:0] wb_req_wdata;
    reg [DOWNSTREAM_BYTES-1:0] wb_req_wstrb;
    reg [UPSTREAM_DATA_WIDTH-1:0] wb_merged_read_data;
    wire wb_backend_req_ready;
    wire wb_backend_resp_valid;
    wire [DOWNSTREAM_DATA_WIDTH-1:0] wb_backend_resp_rdata;
    wire wb_backend_resp_error;

    wire order_head_is_write = order_is_write_q[order_head_q];
    wire [SLOT_INDEX_WIDTH-1:0] order_head_slot =
        order_slot_q[order_head_q];
    wire [READ_INDEX_WIDTH-1:0] order_head_read_slot =
        order_head_slot[READ_INDEX_WIDTH-1:0];
    wire [WRITE_INDEX_WIDTH-1:0] order_head_write_slot =
        order_head_slot[WRITE_INDEX_WIDTH-1:0];
    wire order_head_completed = (order_count_q != 0) &&
        (order_head_is_write ?
         write_completed_q[order_head_write_slot] :
         read_completed_q[order_head_read_slot]);

    wire collecting_read_group = (read_collect_remaining_q != 0);
    wire read_group_member_matches = !upstream_req_write_i &&
        (upstream_req_addr_i == read_collect_next_addr_q) &&
        (upstream_req_size_i == read_collect_size_q) &&
        (upstream_req_cacheable_i == read_collect_cacheable_q);
    wire [9:0] read_reservation_count =
        {{(10-READ_COUNT_WIDTH){1'b0}}, read_count_q} +
        {2'd0, upstream_req_burst_i} + 10'd1;
    wire [9:0] order_reservation_count =
        {{(10-ORDER_COUNT_WIDTH){1'b0}}, order_count_q} +
        {2'd0, upstream_req_burst_i} + 10'd1;
    wire read_leader_fits =
        (read_reservation_count <=
         READ_BUFFER_DEPTH) &&
        (order_reservation_count <= ORDER_DEPTH);
    assign upstream_req_ready_o = collecting_read_group ?
        read_group_member_matches :
        ((order_count_q < ORDER_COUNT_WIDTH'(ORDER_DEPTH)) &&
         (upstream_req_write_i ?
          (write_count_q < WRITE_COUNT_WIDTH'(WRITE_BUFFER_DEPTH)) :
          ((read_count_q < READ_COUNT_WIDTH'(READ_BUFFER_DEPTH)) &&
           read_leader_fits)));
    assign upstream_resp_valid_o = order_head_completed;
    assign upstream_resp_rdata_o = order_head_is_write ?
        {UPSTREAM_DATA_WIDTH{1'b0}} : read_data_q[order_head_read_slot];
    assign upstream_resp_error_o = order_head_is_write ?
        write_error_q[order_head_write_slot] :
        read_error_q[order_head_read_slot];

    wire upstream_request_fire =
        upstream_req_valid_i && upstream_req_ready_o;
    wire read_accept = upstream_request_fire && !upstream_req_write_i;
    wire write_accept = upstream_request_fire && upstream_req_write_i;
    wire upstream_response_fire =
        upstream_resp_valid_o && upstream_resp_ready_i;
    wire read_release = upstream_response_fire && !order_head_is_write;
    wire write_release = upstream_response_fire && order_head_is_write;

    function automatic ranges_overlap;
        input [63:0] first_addr;
        input [2:0] first_size;
        input [63:0] second_addr;
        input [2:0] second_size;
        reg [64:0] first_end;
        reg [64:0] second_end;
        begin
            first_end = {1'b0, first_addr} +
                        (65'd1 << first_size);
            second_end = {1'b0, second_addr} +
                         (65'd1 << second_size);
            ranges_overlap = ({1'b0, first_addr} < second_end) &&
                             ({1'b0, second_addr} < first_end);
        end
    endfunction

    function automatic ranges_overlap_length;
        input [63:0] first_addr;
        input [64:0] first_length;
        input [63:0] second_addr;
        input [2:0] second_size;
        reg [64:0] first_end;
        reg [64:0] second_end;
        begin
            first_end = {1'b0, first_addr} + first_length;
            second_end = {1'b0, second_addr} +
                         (65'd1 << second_size);
            ranges_overlap_length =
                ({1'b0, first_addr} < second_end) &&
                ({1'b0, second_addr} < first_end);
        end
    endfunction

    // Only an older, incomplete request in the opposite direction can block
    // the next AXI address. Same-direction ordering follows the fixed AXI ID.
    always @* begin
        read_issue_hazard = 1'b0;
        write_issue_hazard = 1'b0;
        read_candidate_seen = 1'b0;
        write_candidate_seen = 1'b0;
        scan_index = 0;
        scan_slot = 0;
        for (scan_position = 0; scan_position < ORDER_DEPTH;
             scan_position = scan_position + 1) begin
            scan_index = order_head_q + scan_position;
            if (scan_index >= ORDER_DEPTH)
                scan_index = scan_index - ORDER_DEPTH;
            scan_slot = order_slot_q[scan_index];
            if (scan_position < order_count_q) begin
                if (!read_candidate_seen) begin
                    if (!order_is_write_q[scan_index] &&
                        (scan_slot == read_issue_q))
                        read_candidate_seen = 1'b1;
                    else if (order_is_write_q[scan_index] &&
                             write_valid_q[scan_slot] &&
                             !write_completed_q[scan_slot] &&
                             ranges_overlap_length(
                                 read_addr_q[read_issue_q],
                                 (read_burst_q[read_issue_q] + 1'b1) *
                                     (65'd1 <<
                                      read_size_q[read_issue_q]),
                                 write_addr_q[scan_slot],
                                 write_size_q[scan_slot]))
                        read_issue_hazard = 1'b1;
                end
                if (!write_candidate_seen) begin
                    if (order_is_write_q[scan_index] &&
                        (scan_slot == write_aw_issue_q))
                        write_candidate_seen = 1'b1;
                    else if (!order_is_write_q[scan_index] &&
                             read_valid_q[scan_slot] &&
                             !read_completed_q[scan_slot] &&
                             ranges_overlap(
                                 write_addr_q[write_aw_issue_q],
                                 write_size_q[write_aw_issue_q],
                                 read_addr_q[scan_slot],
                                 read_size_q[scan_slot]))
                        write_issue_hazard = 1'b1;
                end
            end
        end
    end

    always @* begin
        read_issue_bytes = 1 << read_size_q[read_issue_q];
        read_issue_beats = (read_issue_bytes > DOWNSTREAM_BYTES) ?
            (read_issue_bytes / DOWNSTREAM_BYTES) : 1;
        read_declared_requests = read_burst_q[read_issue_q] + 1;
        read_max_axi_requests = 256 / read_issue_beats;
        read_max_4k_requests =
            (4096 - (read_addr_q[read_issue_q] & 12'hfff)) /
            read_issue_bytes;
        read_issue_requests = read_declared_requests;
        if (read_issue_requests > read_max_axi_requests)
            read_issue_requests = read_max_axi_requests;
        if (read_issue_requests > read_max_4k_requests)
            read_issue_requests = read_max_4k_requests;
        if (read_issue_requests < 1)
            read_issue_requests = 1;
        read_remaining_requests =
            read_declared_requests - read_issue_requests;
        read_issue_total_beats =
            read_issue_beats * read_issue_requests;
        write_issue_bytes = 1 << write_size_q[write_aw_issue_q];
        write_issue_beats = (write_issue_bytes > DOWNSTREAM_BYTES) ?
            (write_issue_bytes / DOWNSTREAM_BYTES) : 1;
    end

    // Assemble the current AXI R beat into its upstream buffer slot.
    always @* begin
        read_response_bytes = 1 << read_size_q[read_response_q];
        read_response_beats =
            (read_response_bytes > DOWNSTREAM_BYTES) ?
            (read_response_bytes / DOWNSTREAM_BYTES) : 1;
        read_response_group_remaining =
            (read_group_remaining_q == 0) ?
            (read_burst_q[read_response_q] + 1) :
            read_group_remaining_q;
        read_response_offset =
            (read_response_bytes > DOWNSTREAM_BYTES) ?
            (read_beat_q * DOWNSTREAM_BYTES) : 0;
        read_response_up_lane =
            read_addr_q[read_response_q] & (UPSTREAM_BYTES - 1);
        read_response_down_lane =
            (read_addr_q[read_response_q] + read_response_offset) &
            (DOWNSTREAM_BYTES - 1);
        read_merged_data = read_data_q[read_response_q];
        for (map_byte = 0; map_byte < UPSTREAM_BYTES;
             map_byte = map_byte + 1) begin
            read_response_up_byte = read_response_up_lane + map_byte;
            read_response_down_byte =
                read_response_down_lane + map_byte - read_response_offset;
            if (!read_overrun_q &&
                (map_byte < read_response_bytes) &&
                (map_byte >= read_response_offset) &&
                (map_byte <
                 (read_response_offset + DOWNSTREAM_BYTES)) &&
                (read_response_up_byte < UPSTREAM_BYTES) &&
                (read_response_down_byte >= 0) &&
                (read_response_down_byte < DOWNSTREAM_BYTES))
                read_merged_data[8*read_response_up_byte +: 8] =
                    m_axi_rdata_i[8*read_response_down_byte +: 8];
        end
    end

    wire read_expected_last =
        (read_beat_q + 1'b1 >= read_response_beats);
    wire read_expected_axi_last = read_expected_last &&
        (read_response_group_remaining == 1);
    wire axi_read_address_fire =
        m_axi_arvalid_o && m_axi_arready_i;
    wire axi_read_data_fire = m_axi_rvalid_i && m_axi_rready_o;

    // Select the current W beat from its buffered upstream request.
    always @* begin
        write_data_bytes = 1 << write_size_q[write_data_issue_q];
        write_data_beats = (write_data_bytes > DOWNSTREAM_BYTES) ?
            (write_data_bytes / DOWNSTREAM_BYTES) : 1;
        write_data_offset = (write_data_bytes > DOWNSTREAM_BYTES) ?
            (write_beat_q * DOWNSTREAM_BYTES) : 0;
        write_data_up_lane =
            write_addr_q[write_data_issue_q] & (UPSTREAM_BYTES - 1);
        write_data_down_lane =
            (write_addr_q[write_data_issue_q] + write_data_offset) &
            (DOWNSTREAM_BYTES - 1);
        write_mapped_data = {DOWNSTREAM_DATA_WIDTH{1'b0}};
        write_mapped_strobe = {DOWNSTREAM_BYTES{1'b0}};
        for (map_byte = 0; map_byte < UPSTREAM_BYTES;
             map_byte = map_byte + 1) begin
            write_data_up_byte = write_data_up_lane + map_byte;
            write_data_down_byte =
                write_data_down_lane + map_byte - write_data_offset;
            if ((map_byte < write_data_bytes) &&
                (map_byte >= write_data_offset) &&
                (map_byte < (write_data_offset + DOWNSTREAM_BYTES)) &&
                (write_data_up_byte < UPSTREAM_BYTES) &&
                (write_data_down_byte >= 0) &&
                (write_data_down_byte < DOWNSTREAM_BYTES)) begin
                write_mapped_data[8*write_data_down_byte +: 8] =
                    write_data_q[write_data_issue_q]
                        [8*write_data_up_byte +: 8];
                write_mapped_strobe[write_data_down_byte] =
                    write_strobe_q[write_data_issue_q]
                        [write_data_up_byte];
            end
        end
    end

    wire write_expected_last =
        (write_beat_q + 1'b1 >= write_data_beats);
    wire axi_write_address_fire =
        m_axi_awvalid_o && m_axi_awready_i;
    wire axi_write_data_fire = m_axi_wvalid_o && m_axi_wready_i;
    wire axi_write_response_fire = m_axi_bvalid_i && m_axi_bready_o;

    // WISHBONE maps only the globally oldest request. The backend supplies
    // STALL/ACK/ERR/RTY sequencing for each decomposed beat.
    wire wb_head_pending = (order_count_q != 0) && !order_head_completed;
    always @* begin
        if (order_head_is_write) begin
            wb_transfer_bytes = 1 <<
                write_size_q[order_head_write_slot];
            wb_up_lane = write_addr_q[order_head_write_slot] &
                         (UPSTREAM_BYTES - 1);
            wb_req_addr = write_addr_q[order_head_write_slot];
        end else begin
            wb_transfer_bytes = 1 << read_size_q[order_head_read_slot];
            wb_up_lane = read_addr_q[order_head_read_slot] &
                         (UPSTREAM_BYTES - 1);
            wb_req_addr = read_addr_q[order_head_read_slot];
        end
        wb_transfer_beats = (wb_transfer_bytes > DOWNSTREAM_BYTES) ?
            (wb_transfer_bytes / DOWNSTREAM_BYTES) : 1;
        wb_beat_offset = (wb_transfer_bytes > DOWNSTREAM_BYTES) ?
            (wb_beat_q * DOWNSTREAM_BYTES) : 0;
        wb_req_addr = wb_req_addr + wb_beat_offset;
        wb_down_lane = wb_req_addr & (DOWNSTREAM_BYTES - 1);
        wb_req_size = (wb_transfer_bytes > DOWNSTREAM_BYTES) ?
            DOWNSTREAM_SIZE[2:0] :
            (order_head_is_write ?
             write_size_q[order_head_write_slot] :
             read_size_q[order_head_read_slot]);
        wb_req_wdata = {DOWNSTREAM_DATA_WIDTH{1'b0}};
        wb_req_wstrb = {DOWNSTREAM_BYTES{1'b0}};
        wb_merged_read_data = read_data_q[order_head_read_slot];
        for (map_byte = 0; map_byte < UPSTREAM_BYTES;
             map_byte = map_byte + 1) begin
            wb_up_byte = wb_up_lane + map_byte;
            wb_down_byte = wb_down_lane + map_byte - wb_beat_offset;
            if ((map_byte < wb_transfer_bytes) &&
                (map_byte >= wb_beat_offset) &&
                (map_byte < (wb_beat_offset + DOWNSTREAM_BYTES)) &&
                (wb_up_byte < UPSTREAM_BYTES) &&
                (wb_down_byte >= 0) &&
                (wb_down_byte < DOWNSTREAM_BYTES)) begin
                if (order_head_is_write) begin
                    wb_req_wdata[8*wb_down_byte +: 8] =
                        write_data_q[order_head_write_slot]
                            [8*wb_up_byte +: 8];
                    wb_req_wstrb[wb_down_byte] =
                        write_strobe_q[order_head_write_slot][wb_up_byte];
                end else begin
                    wb_merged_read_data[8*wb_up_byte +: 8] =
                        wb_backend_resp_rdata[8*wb_down_byte +: 8];
                end
            end
        end
    end

    wire wb_expected_last = (wb_beat_q + 1'b1 >= wb_transfer_beats);
    wire wb_backend_resp_fire = wb_backend_resp_valid;

    generate
        if (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) begin : g_axi
            assign m_axi_arid_o = AXI_ID;
            assign m_axi_araddr_o =
                read_addr_q[read_issue_q][ADDR_WIDTH-1:0];
            assign m_axi_arlen_o = read_issue_total_beats - 1;
            assign m_axi_arsize_o =
                (read_issue_bytes > DOWNSTREAM_BYTES) ?
                DOWNSTREAM_SIZE[2:0] : read_size_q[read_issue_q];
            assign m_axi_arburst_o = 2'b01;
            assign m_axi_arlock_o = 1'b0;
            assign m_axi_arcache_o =
                read_cacheable_q[read_issue_q] ? 4'b0011 : 4'b0000;
            assign m_axi_arprot_o = 3'b000;
            assign m_axi_arqos_o = 4'b0000;
            assign m_axi_arvalid_o =
                (read_unissued_q >=
                 READ_COUNT_WIDTH'(read_issue_requests)) &&
                !read_issue_hazard;
            assign m_axi_rready_o = (read_axi_outstanding_q != 0);

            assign m_axi_awid_o = AXI_ID;
            assign m_axi_awaddr_o =
                write_addr_q[write_aw_issue_q][ADDR_WIDTH-1:0];
            assign m_axi_awlen_o = write_issue_beats - 1;
            assign m_axi_awsize_o =
                (write_issue_bytes > DOWNSTREAM_BYTES) ?
                DOWNSTREAM_SIZE[2:0] : write_size_q[write_aw_issue_q];
            assign m_axi_awburst_o = 2'b01;
            assign m_axi_awlock_o = 1'b0;
            assign m_axi_awcache_o =
                write_cacheable_q[write_aw_issue_q] ? 4'b0011 : 4'b0000;
            assign m_axi_awprot_o = 3'b000;
            assign m_axi_awqos_o = 4'b0000;
            assign m_axi_awvalid_o = (write_unissued_q != 0) &&
                                         !write_issue_hazard;
            assign m_axi_wdata_o = write_mapped_data;
            assign m_axi_wstrb_o = write_mapped_strobe;
            assign m_axi_wlast_o = write_expected_last;
            assign m_axi_wvalid_o =
                write_valid_q[write_data_issue_q] &&
                write_aw_issued_q[write_data_issue_q] &&
                !write_w_done_q[write_data_issue_q];
            assign m_axi_bready_o = (write_axi_outstanding_q != 0);

            assign wb_cyc_o = 1'b0;
            assign wb_stb_o = 1'b0;
            assign wb_we_o = 1'b0;
            assign wb_adr_o = {ADDR_WIDTH{1'b0}};
            assign wb_dat_o = {DOWNSTREAM_DATA_WIDTH{1'b0}};
            assign wb_sel_o = {DOWNSTREAM_BYTES{1'b0}};
            assign wb_cti_o = 3'b000;
            assign wb_bte_o = 2'b00;
            assign wb_lock_o = 1'b0;
            assign wb_backend_req_ready = 1'b0;
            assign wb_backend_resp_valid = 1'b0;
            assign wb_backend_resp_rdata =
                {DOWNSTREAM_DATA_WIDTH{1'b0}};
            assign wb_backend_resp_error = 1'b0;
        end else if (BUS_TYPE == `OPENRV64_COMPLEX_BUS_WISHBONE) begin :
                g_wishbone
            openrv64_complex_wishbone_backend #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .DATA_WIDTH(DOWNSTREAM_DATA_WIDTH),
                .ADDR_SHIFT(WB_ADDR_SHIFT),
                .MAX_RETRIES(WB_MAX_RETRIES)
            ) u_backend (
                .clk_i(clk_i), .rst_ni(rst_ni),
                .req_valid_i(wb_head_pending),
                .req_ready_o(wb_backend_req_ready),
                .req_write_i(order_head_is_write),
                .req_addr_i(wb_req_addr), .req_size_i(wb_req_size),
                .req_wdata_i(wb_req_wdata), .req_wstrb_i(wb_req_wstrb),
                .req_cacheable_i(order_head_is_write ?
                    write_cacheable_q[order_head_write_slot] :
                    read_cacheable_q[order_head_read_slot]),
                .resp_valid_o(wb_backend_resp_valid),
                .resp_ready_i(1'b1),
                .resp_rdata_o(wb_backend_resp_rdata),
                .resp_error_o(wb_backend_resp_error),
                .wb_cyc_o(wb_cyc_o), .wb_stb_o(wb_stb_o),
                .wb_we_o(wb_we_o), .wb_adr_o(wb_adr_o),
                .wb_dat_o(wb_dat_o), .wb_sel_o(wb_sel_o),
                .wb_cti_o(wb_cti_o), .wb_bte_o(wb_bte_o),
                .wb_lock_o(wb_lock_o), .wb_stall_i(wb_stall_i),
                .wb_ack_i(wb_ack_i), .wb_err_i(wb_err_i),
                .wb_rty_i(wb_rty_i), .wb_dat_i(wb_dat_i)
            );

            assign m_axi_arid_o = {AXI_ID_WIDTH{1'b0}};
            assign m_axi_araddr_o = {ADDR_WIDTH{1'b0}};
            assign m_axi_arlen_o = 8'd0;
            assign m_axi_arsize_o = 3'd0;
            assign m_axi_arburst_o = 2'b01;
            assign m_axi_arlock_o = 1'b0;
            assign m_axi_arcache_o = 4'd0;
            assign m_axi_arprot_o = 3'd0;
            assign m_axi_arqos_o = 4'd0;
            assign m_axi_arvalid_o = 1'b0;
            assign m_axi_rready_o = 1'b0;
            assign m_axi_awid_o = {AXI_ID_WIDTH{1'b0}};
            assign m_axi_awaddr_o = {ADDR_WIDTH{1'b0}};
            assign m_axi_awlen_o = 8'd0;
            assign m_axi_awsize_o = 3'd0;
            assign m_axi_awburst_o = 2'b01;
            assign m_axi_awlock_o = 1'b0;
            assign m_axi_awcache_o = 4'd0;
            assign m_axi_awprot_o = 3'd0;
            assign m_axi_awqos_o = 4'd0;
            assign m_axi_awvalid_o = 1'b0;
            assign m_axi_wdata_o = {DOWNSTREAM_DATA_WIDTH{1'b0}};
            assign m_axi_wstrb_o = {DOWNSTREAM_BYTES{1'b0}};
            assign m_axi_wlast_o = 1'b1;
            assign m_axi_wvalid_o = 1'b0;
            assign m_axi_bready_o = 1'b0;
        end else begin : g_bad_bus
            initial $fatal(1, "unsupported genbus BUS_TYPE");
            assign m_axi_arid_o = {AXI_ID_WIDTH{1'b0}};
            assign m_axi_araddr_o = {ADDR_WIDTH{1'b0}};
            assign m_axi_arlen_o = 8'd0;
            assign m_axi_arsize_o = 3'd0;
            assign m_axi_arburst_o = 2'b01;
            assign m_axi_arlock_o = 1'b0;
            assign m_axi_arcache_o = 4'd0;
            assign m_axi_arprot_o = 3'd0;
            assign m_axi_arqos_o = 4'd0;
            assign m_axi_arvalid_o = 1'b0;
            assign m_axi_rready_o = 1'b0;
            assign m_axi_awid_o = {AXI_ID_WIDTH{1'b0}};
            assign m_axi_awaddr_o = {ADDR_WIDTH{1'b0}};
            assign m_axi_awlen_o = 8'd0;
            assign m_axi_awsize_o = 3'd0;
            assign m_axi_awburst_o = 2'b01;
            assign m_axi_awlock_o = 1'b0;
            assign m_axi_awcache_o = 4'd0;
            assign m_axi_awprot_o = 3'd0;
            assign m_axi_awqos_o = 4'd0;
            assign m_axi_awvalid_o = 1'b0;
            assign m_axi_wdata_o = {DOWNSTREAM_DATA_WIDTH{1'b0}};
            assign m_axi_wstrb_o = {DOWNSTREAM_BYTES{1'b0}};
            assign m_axi_wlast_o = 1'b1;
            assign m_axi_wvalid_o = 1'b0;
            assign m_axi_bready_o = 1'b0;
            assign wb_cyc_o = 1'b0;
            assign wb_stb_o = 1'b0;
            assign wb_we_o = 1'b0;
            assign wb_adr_o = {ADDR_WIDTH{1'b0}};
            assign wb_dat_o = {DOWNSTREAM_DATA_WIDTH{1'b0}};
            assign wb_sel_o = {DOWNSTREAM_BYTES{1'b0}};
            assign wb_cti_o = 3'b000;
            assign wb_bte_o = 2'b00;
            assign wb_lock_o = 1'b0;
            assign wb_backend_req_ready = 1'b0;
            assign wb_backend_resp_valid = 1'b0;
            assign wb_backend_resp_rdata =
                {DOWNSTREAM_DATA_WIDTH{1'b0}};
            assign wb_backend_resp_error = 1'b1;
        end
    endgenerate

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_tail_q <= 0;
            read_issue_q <= 0;
            read_response_q <= 0;
            write_tail_q <= 0;
            write_aw_issue_q <= 0;
            write_data_issue_q <= 0;
            write_response_q <= 0;
            order_head_q <= 0;
            order_tail_q <= 0;
            read_count_q <= 0;
            read_unissued_q <= 0;
            read_axi_outstanding_q <= 0;
            write_count_q <= 0;
            write_unissued_q <= 0;
            write_axi_outstanding_q <= 0;
            order_count_q <= 0;
            read_beat_q <= 0;
            write_beat_q <= 0;
            wb_beat_q <= 0;
            read_overrun_q <= 1'b0;
            read_group_remaining_q <= 0;
            read_collect_remaining_q <= 0;
            read_collect_next_addr_q <= 0;
            read_collect_size_q <= 0;
            read_collect_cacheable_q <= 1'b0;
            for (reset_index = 0; reset_index < READ_BUFFER_DEPTH;
                 reset_index = reset_index + 1) begin
                read_valid_q[reset_index] <= 1'b0;
                read_completed_q[reset_index] <= 1'b0;
                read_addr_q[reset_index] <= 0;
                read_size_q[reset_index] <= 0;
                read_burst_q[reset_index] <= 0;
                read_cacheable_q[reset_index] <= 1'b0;
                read_data_q[reset_index] <= 0;
                read_error_q[reset_index] <= 1'b0;
            end
            for (reset_index = 0; reset_index < WRITE_BUFFER_DEPTH;
                 reset_index = reset_index + 1) begin
                write_valid_q[reset_index] <= 1'b0;
                write_completed_q[reset_index] <= 1'b0;
                write_aw_issued_q[reset_index] <= 1'b0;
                write_w_done_q[reset_index] <= 1'b0;
                write_addr_q[reset_index] <= 0;
                write_size_q[reset_index] <= 0;
                write_data_q[reset_index] <= 0;
                write_strobe_q[reset_index] <= 0;
                write_cacheable_q[reset_index] <= 1'b0;
                write_error_q[reset_index] <= 1'b0;
            end
            for (reset_index = 0; reset_index < ORDER_DEPTH;
                 reset_index = reset_index + 1) begin
                order_is_write_q[reset_index] <= 1'b0;
                order_slot_q[reset_index] <= 0;
            end
        end else begin
            if (read_accept) begin
                read_valid_q[read_tail_q] <= 1'b1;
                read_completed_q[read_tail_q] <= 1'b0;
                read_addr_q[read_tail_q] <= upstream_req_addr_i;
                read_size_q[read_tail_q] <= upstream_req_size_i;
                read_burst_q[read_tail_q] <=
                    collecting_read_group ? 8'd0 :
                    upstream_req_burst_i;
                read_cacheable_q[read_tail_q] <=
                    upstream_req_cacheable_i;
                read_data_q[read_tail_q] <= 0;
                read_error_q[read_tail_q] <= 1'b0;
                if (collecting_read_group) begin
                    read_collect_remaining_q <=
                        read_collect_remaining_q - 1'b1;
                    read_collect_next_addr_q <=
                        read_collect_next_addr_q +
                        (64'd1 << read_collect_size_q);
                end else if (upstream_req_burst_i != 0) begin
                    read_collect_remaining_q <= upstream_req_burst_i;
                    read_collect_next_addr_q <=
                        upstream_req_addr_i +
                        (64'd1 << upstream_req_size_i);
                    read_collect_size_q <= upstream_req_size_i;
                    read_collect_cacheable_q <=
                        upstream_req_cacheable_i;
                end
                if (read_tail_q ==
                    READ_INDEX_WIDTH'(READ_BUFFER_DEPTH - 1))
                    read_tail_q <= 0;
                else
                    read_tail_q <= read_tail_q + 1'b1;
            end
            if (write_accept) begin
                write_valid_q[write_tail_q] <= 1'b1;
                write_completed_q[write_tail_q] <= 1'b0;
                write_aw_issued_q[write_tail_q] <= 1'b0;
                write_w_done_q[write_tail_q] <= 1'b0;
                write_addr_q[write_tail_q] <= upstream_req_addr_i;
                write_size_q[write_tail_q] <= upstream_req_size_i;
                write_data_q[write_tail_q] <= upstream_req_wdata_i;
                write_strobe_q[write_tail_q] <= upstream_req_wstrb_i;
                write_cacheable_q[write_tail_q] <=
                    upstream_req_cacheable_i;
                write_error_q[write_tail_q] <= 1'b0;
                if (write_tail_q ==
                    WRITE_INDEX_WIDTH'(WRITE_BUFFER_DEPTH - 1))
                    write_tail_q <= 0;
                else
                    write_tail_q <= write_tail_q + 1'b1;
            end
            if (upstream_request_fire) begin
                order_is_write_q[order_tail_q] <= upstream_req_write_i;
                order_slot_q[order_tail_q] <= upstream_req_write_i ?
                    SLOT_INDEX_WIDTH'(write_tail_q) :
                    SLOT_INDEX_WIDTH'(read_tail_q);
                if (order_tail_q == ORDER_INDEX_WIDTH'(ORDER_DEPTH - 1))
                    order_tail_q <= 0;
                else
                    order_tail_q <= order_tail_q + 1'b1;
            end

            if (read_release) begin
                read_valid_q[order_head_read_slot] <= 1'b0;
                read_completed_q[order_head_read_slot] <= 1'b0;
            end
            if (write_release) begin
                write_valid_q[order_head_write_slot] <= 1'b0;
                write_completed_q[order_head_write_slot] <= 1'b0;
                write_aw_issued_q[order_head_write_slot] <= 1'b0;
                write_w_done_q[order_head_write_slot] <= 1'b0;
            end
            if (upstream_response_fire) begin
                if (order_head_q == ORDER_INDEX_WIDTH'(ORDER_DEPTH - 1))
                    order_head_q <= 0;
                else
                    order_head_q <= order_head_q + 1'b1;
            end

            case ({read_accept, read_release})
                2'b10: read_count_q <= read_count_q + 1'b1;
                2'b01: read_count_q <= read_count_q - 1'b1;
                default: read_count_q <= read_count_q;
            endcase
            case ({write_accept, write_release})
                2'b10: write_count_q <= write_count_q + 1'b1;
                2'b01: write_count_q <= write_count_q - 1'b1;
                default: write_count_q <= write_count_q;
            endcase
            case ({upstream_request_fire, upstream_response_fire})
                2'b10: order_count_q <= order_count_q + 1'b1;
                2'b01: order_count_q <= order_count_q - 1'b1;
                default: order_count_q <= order_count_q;
            endcase

            if (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) begin
                case ({read_accept, axi_read_address_fire})
                    2'b10: read_unissued_q <= read_unissued_q + 1'b1;
                    2'b01: read_unissued_q <= read_unissued_q -
                        READ_COUNT_WIDTH'(read_issue_requests);
                    2'b11: read_unissued_q <= read_unissued_q + 1'b1 -
                        READ_COUNT_WIDTH'(read_issue_requests);
                    default: read_unissued_q <= read_unissued_q;
                endcase
                case ({write_accept, axi_write_address_fire})
                    2'b10: write_unissued_q <= write_unissued_q + 1'b1;
                    2'b01: write_unissued_q <= write_unissued_q - 1'b1;
                    default: write_unissued_q <= write_unissued_q;
                endcase

                if (axi_read_address_fire) begin
                    read_response_advance =
                        read_issue_q + read_issue_requests;
                    if (read_response_advance >= READ_BUFFER_DEPTH)
                        read_response_advance = read_response_advance -
                                                READ_BUFFER_DEPTH;
                    // AXI bursts may not exceed 256 beats or cross a 4 KiB
                    // boundary. Split one declared neutral group when needed
                    // by terminating this leader and promoting the first
                    // unissued follower to lead the remainder.
                    if (read_remaining_requests != 0) begin
                        read_burst_q[read_issue_q] <=
                            read_issue_requests - 1;
                        read_burst_q[read_response_advance] <=
                            read_remaining_requests - 1;
                    end
                    read_issue_q <=
                        READ_INDEX_WIDTH'(read_response_advance);
                end
                if (axi_write_address_fire) begin
                    write_aw_issued_q[write_aw_issue_q] <= 1'b1;
                    if (write_aw_issue_q ==
                        WRITE_INDEX_WIDTH'(WRITE_BUFFER_DEPTH - 1))
                        write_aw_issue_q <= 0;
                    else
                        write_aw_issue_q <= write_aw_issue_q + 1'b1;
                end

                case ({axi_read_address_fire,
                       axi_read_data_fire && m_axi_rlast_i})
                    2'b10: read_axi_outstanding_q <=
                        read_axi_outstanding_q + 1'b1;
                    2'b01: read_axi_outstanding_q <=
                        read_axi_outstanding_q - 1'b1;
                    default: read_axi_outstanding_q <=
                        read_axi_outstanding_q;
                endcase
                case ({axi_write_address_fire,
                       axi_write_response_fire})
                    2'b10: write_axi_outstanding_q <=
                        write_axi_outstanding_q + 1'b1;
                    2'b01: write_axi_outstanding_q <=
                        write_axi_outstanding_q - 1'b1;
                    default: write_axi_outstanding_q <=
                        write_axi_outstanding_q;
                endcase

                if (axi_read_data_fire) begin
                    if (!read_overrun_q)
                        read_data_q[read_response_q] <= read_merged_data;
                    read_error_q[read_response_q] <=
                        read_error_q[read_response_q] |
                        (m_axi_rid_i != AXI_ID) |
                        (m_axi_rresp_i != 2'b00) |
                        (m_axi_rlast_i != read_expected_axi_last);
                    if (m_axi_rlast_i && !read_expected_axi_last) begin
                        read_completed_q[read_response_q] <= 1'b1;
                        read_beat_q <= 0;
                        read_overrun_q <= 1'b0;
                        for (fault_member = 1;
                             fault_member < READ_BUFFER_DEPTH;
                             fault_member = fault_member + 1) begin
                            fault_slot = read_response_q + fault_member;
                            if (fault_slot >= READ_BUFFER_DEPTH)
                                fault_slot = fault_slot -
                                             READ_BUFFER_DEPTH;
                            if (fault_member <
                                read_response_group_remaining) begin
                                read_completed_q[fault_slot] <= 1'b1;
                                read_error_q[fault_slot] <= 1'b1;
                            end
                        end
                        read_response_advance = read_response_q +
                            read_response_group_remaining;
                        if (read_response_advance >= READ_BUFFER_DEPTH)
                            read_response_advance = read_response_advance -
                                                    READ_BUFFER_DEPTH;
                        read_response_q <=
                            READ_INDEX_WIDTH'(read_response_advance);
                        read_group_remaining_q <= 0;
                    end else if (read_expected_axi_last &&
                                 m_axi_rlast_i) begin
                        read_completed_q[read_response_q] <= 1'b1;
                        read_beat_q <= 0;
                        read_overrun_q <= 1'b0;
                        read_group_remaining_q <= 0;
                        if (read_response_q ==
                            READ_INDEX_WIDTH'(READ_BUFFER_DEPTH - 1))
                            read_response_q <= 0;
                        else
                            read_response_q <= read_response_q + 1'b1;
                    end else if (read_expected_axi_last) begin
                        read_overrun_q <= 1'b1;
                    end else if (read_expected_last) begin
                        read_completed_q[read_response_q] <= 1'b1;
                        read_beat_q <= 0;
                        read_group_remaining_q <=
                            read_response_group_remaining - 1;
                        if (read_response_q ==
                            READ_INDEX_WIDTH'(READ_BUFFER_DEPTH - 1))
                            read_response_q <= 0;
                        else
                            read_response_q <= read_response_q + 1'b1;
                    end else begin
                        read_beat_q <= read_beat_q + 1'b1;
                    end
                end

                if (axi_write_data_fire) begin
                    if (write_expected_last) begin
                        write_w_done_q[write_data_issue_q] <= 1'b1;
                        write_beat_q <= 0;
                        if (write_data_issue_q ==
                            WRITE_INDEX_WIDTH'(WRITE_BUFFER_DEPTH - 1))
                            write_data_issue_q <= 0;
                        else
                            write_data_issue_q <=
                                write_data_issue_q + 1'b1;
                    end else begin
                        write_beat_q <= write_beat_q + 1'b1;
                    end
                end
                if (axi_write_response_fire) begin
                    write_completed_q[write_response_q] <= 1'b1;
                    write_error_q[write_response_q] <=
                        (m_axi_bid_i != AXI_ID) |
                        (m_axi_bresp_i != 2'b00) |
                        !(write_w_done_q[write_response_q] ||
                          (axi_write_data_fire && write_expected_last &&
                           (write_data_issue_q == write_response_q)));
                    if (write_response_q ==
                        WRITE_INDEX_WIDTH'(WRITE_BUFFER_DEPTH - 1))
                        write_response_q <= 0;
                    else
                        write_response_q <= write_response_q + 1'b1;
                end
            end else begin
                read_unissued_q <= 0;
                write_unissued_q <= 0;
                read_axi_outstanding_q <= 0;
                write_axi_outstanding_q <= 0;
                if (wb_backend_resp_fire) begin
                    if (!order_head_is_write)
                        read_data_q[order_head_read_slot] <=
                            wb_merged_read_data;
                    if (wb_backend_resp_error || wb_expected_last) begin
                        wb_beat_q <= 0;
                        if (order_head_is_write) begin
                            write_completed_q[order_head_write_slot] <=
                                1'b1;
                            write_error_q[order_head_write_slot] <=
                                wb_backend_resp_error;
                        end else begin
                            read_completed_q[order_head_read_slot] <= 1'b1;
                            read_error_q[order_head_read_slot] <=
                                wb_backend_resp_error;
                        end
                    end else begin
                        wb_beat_q <= wb_beat_q + 1'b1;
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((UPSTREAM_DATA_WIDTH < 32) ||
            (UPSTREAM_DATA_WIDTH > 1024) ||
            ((UPSTREAM_DATA_WIDTH & (UPSTREAM_DATA_WIDTH - 1)) != 0))
            $fatal(1,
                "genbus upstream width must be a power of two from 32 through 1024 bits");
        if ((DOWNSTREAM_DATA_WIDTH < 32) ||
            (DOWNSTREAM_DATA_WIDTH > 512) ||
            ((DOWNSTREAM_DATA_WIDTH & (DOWNSTREAM_DATA_WIDTH - 1)) != 0))
            $fatal(1,
                "genbus downstream width must be a power of two from 32 through 512 bits");
        if ((READ_BUFFER_DEPTH < 1) || (READ_BUFFER_DEPTH > 32))
            $fatal(1, "genbus read buffer depth must be 1 through 32");
        if ((WRITE_BUFFER_DEPTH < 1) || (WRITE_BUFFER_DEPTH > 32))
            $fatal(1, "genbus write buffer depth must be 1 through 32");
    end

    always @(posedge clk_i) begin
        if (rst_ni && upstream_request_fire) begin
            if (upstream_req_size_i > $clog2(UPSTREAM_BYTES))
                $fatal(1, "genbus request exceeds upstream beat width");
            if ((upstream_req_addr_i &
                 ((64'd1 << upstream_req_size_i) - 1'b1)) != 0)
                $fatal(1, "genbus request is not naturally aligned");
            if (upstream_req_write_i && (upstream_req_burst_i != 0))
                $fatal(1,
                    "genbus declared coalescing bursts are read-only");
            if (collecting_read_group &&
                (upstream_req_burst_i != 0))
                $fatal(1,
                    "genbus burst followers must carry a zero burst count");
        end
    end
`endif

endmodule
