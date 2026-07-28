`timescale 1ns/1ps

// Testbench AXI4 memory channel with a replaceable timing backend.
//
// The northbound boundary is an AXI4 slave, not the OpenRV64 internal memory
// handshake.  AR, R, AW, W, and B remain independent; address descriptors are
// queued; IDs and bursts are preserved; and response payloads remain stable
// under backpressure.  Accepted reads and complete buffered writes may all
// have complete-burst commands outstanding to the timing backend.  Read and
// write responses are returned in their respective address-acceptance order,
// which is legal AXI ordering for all IDs.
//
// The southbound timing port is intentionally data-free and tagged.  A timing
// model accepts one complete AXI burst and may complete commands out of
// acceptance order.  AXI response ordering remains local to this module.
// openrv64_timing_ddr3,
// openrv64_timing_ddr4, openrv64_timing_gddr6, and
// openrv64_timing_hbm2 implement this contract and can be swapped without
// changing this module.
//
// This module is a behavioral fixture.  The backing array and initialization
// loop are not intended for synthesis.
module openrv64_mem_channel #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 256,
    parameter integer ID_WIDTH = 4,
    parameter [ADDR_WIDTH-1:0] MEM_BASE = {ADDR_WIDTH{1'b0}},
    parameter integer MEM_BYTES = 16 * 1024 * 1024,
    parameter integer READ_QUEUE_DEPTH = 8,
    parameter integer WRITE_QUEUE_DEPTH = 8,
    parameter integer TIMING_TAG_WIDTH = 8,
    parameter integer ZERO_INIT_WORDS = MEM_BYTES / (DATA_WIDTH / 8),
    parameter INIT_FILE = ""
) (
    input  wire                      clk_i,
    input  wire                      rst_ni,

    input  wire [ID_WIDTH-1:0]       s_axi_arid_i,
    input  wire [ADDR_WIDTH-1:0]     s_axi_araddr_i,
    input  wire [7:0]                s_axi_arlen_i,
    input  wire [2:0]                s_axi_arsize_i,
    input  wire [1:0]                s_axi_arburst_i,
    input  wire                      s_axi_arlock_i,
    input  wire [3:0]                s_axi_arcache_i,
    input  wire [2:0]                s_axi_arprot_i,
    input  wire [3:0]                s_axi_arqos_i,
    input  wire                      s_axi_arvalid_i,
    output wire                      s_axi_arready_o,

    output wire [ID_WIDTH-1:0]       s_axi_rid_o,
    output wire [DATA_WIDTH-1:0]     s_axi_rdata_o,
    output wire [1:0]                s_axi_rresp_o,
    output wire                      s_axi_rlast_o,
    output wire                      s_axi_rvalid_o,
    input  wire                      s_axi_rready_i,

    input  wire [ID_WIDTH-1:0]       s_axi_awid_i,
    input  wire [ADDR_WIDTH-1:0]     s_axi_awaddr_i,
    input  wire [7:0]                s_axi_awlen_i,
    input  wire [2:0]                s_axi_awsize_i,
    input  wire [1:0]                s_axi_awburst_i,
    input  wire                      s_axi_awlock_i,
    input  wire [3:0]                s_axi_awcache_i,
    input  wire [2:0]                s_axi_awprot_i,
    input  wire [3:0]                s_axi_awqos_i,
    input  wire                      s_axi_awvalid_i,
    output wire                      s_axi_awready_o,

    input  wire [DATA_WIDTH-1:0]     s_axi_wdata_i,
    input  wire [DATA_WIDTH/8-1:0]   s_axi_wstrb_i,
    input  wire                      s_axi_wlast_i,
    input  wire                      s_axi_wvalid_i,
    output wire                      s_axi_wready_o,

    output wire [ID_WIDTH-1:0]       s_axi_bid_o,
    output wire [1:0]                s_axi_bresp_o,
    output wire                      s_axi_bvalid_o,
    input  wire                      s_axi_bready_i,

    output wire                      timing_cmd_valid_o,
    input  wire                      timing_cmd_ready_i,
    output wire                      timing_cmd_write_o,
    output wire [ADDR_WIDTH-1:0]     timing_cmd_addr_o,
    output wire [15:0]               timing_cmd_bytes_o,
    output wire [TIMING_TAG_WIDTH-1:0] timing_cmd_tag_o,
    input  wire                      timing_resp_valid_i,
    input  wire [TIMING_TAG_WIDTH-1:0] timing_resp_tag_i,
    output wire                      timing_resp_ready_o
);

    localparam integer DATA_BYTES = DATA_WIDTH / 8;
    localparam integer DATA_BYTE_BITS = $clog2(DATA_BYTES);
    localparam integer WORD_COUNT = MEM_BYTES / DATA_BYTES;
    localparam integer WORD_INDEX_WIDTH =
        (WORD_COUNT > 1) ? $clog2(WORD_COUNT) : 1;
    localparam integer READ_PTR_WIDTH =
        (READ_QUEUE_DEPTH > 1) ? $clog2(READ_QUEUE_DEPTH) : 1;
    localparam integer WRITE_PTR_WIDTH =
        (WRITE_QUEUE_DEPTH > 1) ? $clog2(WRITE_QUEUE_DEPTH) : 1;
    localparam integer TIMING_OWNER_DEPTH =
        READ_QUEUE_DEPTH + WRITE_QUEUE_DEPTH;
    localparam integer TIMING_OWNER_COUNT_WIDTH =
        $clog2(TIMING_OWNER_DEPTH + 1);
    localparam integer MAX_BURST_BEATS = 256;
    localparam integer WRITE_DATA_ENTRIES =
        WRITE_QUEUE_DEPTH * MAX_BURST_BEATS;
    localparam [2:0] AXI_MAX_SIZE = 3'(DATA_BYTE_BITS);
    localparam [READ_PTR_WIDTH:0] READ_QUEUE_CAPACITY =
        (READ_PTR_WIDTH + 1)'(READ_QUEUE_DEPTH);
    localparam [READ_PTR_WIDTH-1:0] READ_LAST_PTR =
        READ_PTR_WIDTH'(READ_QUEUE_DEPTH - 1);
    localparam [WRITE_PTR_WIDTH:0] WRITE_QUEUE_CAPACITY =
        (WRITE_PTR_WIDTH + 1)'(WRITE_QUEUE_DEPTH);
    localparam [WRITE_PTR_WIDTH-1:0] WRITE_LAST_PTR =
        WRITE_PTR_WIDTH'(WRITE_QUEUE_DEPTH - 1);
    localparam [TIMING_OWNER_COUNT_WIDTH-1:0] TIMING_OWNER_CAPACITY =
        TIMING_OWNER_COUNT_WIDTH'(TIMING_OWNER_DEPTH);

    localparam [1:0] AXI_RESP_OKAY = 2'b00;
    localparam [1:0] AXI_RESP_SLVERR = 2'b10;
    localparam [1:0] AXI_RESP_DECERR = 2'b11;
    localparam [1:0] AXI_BURST_FIXED = 2'b00;
    localparam [1:0] AXI_BURST_INCR = 2'b01;
    localparam [1:0] AXI_BURST_WRAP = 2'b10;

    reg [DATA_WIDTH-1:0] memory_q [0:WORD_COUNT-1];

    reg [ID_WIDTH-1:0] read_id_fifo_q [0:READ_QUEUE_DEPTH-1];
    reg [ADDR_WIDTH-1:0] read_addr_fifo_q [0:READ_QUEUE_DEPTH-1];
    reg [7:0] read_len_fifo_q [0:READ_QUEUE_DEPTH-1];
    reg [2:0] read_size_fifo_q [0:READ_QUEUE_DEPTH-1];
    reg [1:0] read_burst_fifo_q [0:READ_QUEUE_DEPTH-1];
    reg [1:0] read_resp_fifo_q [0:READ_QUEUE_DEPTH-1];
    reg read_valid_q [0:READ_QUEUE_DEPTH-1];
    reg read_timing_submitted_q [0:READ_QUEUE_DEPTH-1];
    reg read_timing_done_q [0:READ_QUEUE_DEPTH-1];
    reg [7:0] read_beat_q [0:READ_QUEUE_DEPTH-1];
    reg [READ_PTR_WIDTH-1:0] read_head_q;
    reg [READ_PTR_WIDTH-1:0] read_tail_q;
    reg [READ_PTR_WIDTH:0] read_count_q;

    reg [ID_WIDTH-1:0] write_id_fifo_q [0:WRITE_QUEUE_DEPTH-1];
    reg [ADDR_WIDTH-1:0] write_addr_fifo_q [0:WRITE_QUEUE_DEPTH-1];
    reg [7:0] write_len_fifo_q [0:WRITE_QUEUE_DEPTH-1];
    reg [2:0] write_size_fifo_q [0:WRITE_QUEUE_DEPTH-1];
    reg [1:0] write_burst_fifo_q [0:WRITE_QUEUE_DEPTH-1];
    reg [1:0] write_resp_fifo_q [0:WRITE_QUEUE_DEPTH-1];
    reg write_valid_q [0:WRITE_QUEUE_DEPTH-1];
    reg write_data_complete_q [0:WRITE_QUEUE_DEPTH-1];
    reg write_timing_submitted_q [0:WRITE_QUEUE_DEPTH-1];
    reg write_timing_done_q [0:WRITE_QUEUE_DEPTH-1];
    reg [7:0] write_beat_q [0:WRITE_QUEUE_DEPTH-1];
    reg [WRITE_PTR_WIDTH-1:0] write_head_q;
    reg [WRITE_PTR_WIDTH-1:0] write_tail_q;
    reg [WRITE_PTR_WIDTH-1:0] write_data_head_q;
    reg [WRITE_PTR_WIDTH:0] write_count_q;

    reg [DATA_WIDTH-1:0] write_data_q [0:WRITE_DATA_ENTRIES-1];
    reg [DATA_BYTES-1:0] write_strb_q [0:WRITE_DATA_ENTRIES-1];
    reg [DATA_WIDTH-1:0]
        read_data_q [0:READ_QUEUE_DEPTH*MAX_BURST_BEATS-1];

    reg [ID_WIDTH-1:0] read_response_id_q;
    reg [DATA_WIDTH-1:0] read_response_data_q;
    reg [1:0] read_response_resp_q;
    reg read_response_last_q;
    reg read_response_valid_q;

    reg [TIMING_OWNER_COUNT_WIDTH-1:0] timing_owner_count_q;
    reg prefer_write_q;
    reg timing_hold_valid_q;
    reg timing_hold_write_q;
    reg [READ_PTR_WIDTH-1:0] timing_hold_read_slot_q;
    reg [WRITE_PTR_WIDTH-1:0] timing_hold_write_slot_q;

`ifndef SYNTHESIS
    // Simulation performance counters.  A burst is one accepted AXI address
    // transaction; beats are counted separately so width conversion remains
    // visible.  These counters observe the fixture and do not affect protocol
    // state.
    reg [63:0] perf_read_bursts_q;
    reg [63:0] perf_write_bursts_q;
    reg [63:0] perf_read_single_beat_bursts_q;
    reg [63:0] perf_read_two_beat_bursts_q;
    reg [63:0] perf_read_other_bursts_q;
    reg [63:0] perf_write_single_beat_bursts_q;
    reg [63:0] perf_write_two_beat_bursts_q;
    reg [63:0] perf_write_other_bursts_q;
    reg [63:0] perf_read_beats_requested_q;
    reg [63:0] perf_write_beats_requested_q;
    reg [63:0] perf_read_beats_returned_q;
    reg [63:0] perf_write_beats_received_q;
    reg [63:0] perf_read_address_wait_cycles_q;
    reg [63:0] perf_write_address_wait_cycles_q;
    reg [63:0] perf_write_data_wait_cycles_q;
    reg [63:0] perf_read_response_wait_cycles_q;
    reg [63:0] perf_write_response_wait_cycles_q;
    reg [63:0] perf_timing_backend_wait_cycles_q;
    reg [63:0] perf_timing_owner_full_cycles_q;
    reg [63:0] perf_read_timing_wait_cycles_q;
    reg [63:0] perf_write_timing_wait_cycles_q;
    reg [63:0] perf_timing_read_commands_q;
    reg [63:0] perf_timing_write_commands_q;
    reg [63:0] perf_max_read_queue_q;
    reg [63:0] perf_max_write_queue_q;
    reg [63:0] perf_max_timing_owners_q;
`endif

    integer init_index;
    integer reset_read_slot;
    integer reset_write_slot;
    integer read_scan_offset;
    integer read_scan_slot;
    integer write_scan_offset;
    integer write_scan_slot;
    integer write_older_offset;
    integer write_older_slot;
    integer commit_beat;
    integer commit_byte;
    reg write_candidate_blocked;

    function [ADDR_WIDTH:0] transfer_bytes_of;
        input [2:0] size_value;
        begin
            transfer_bytes_of = {{ADDR_WIDTH{1'b0}}, 1'b1} << size_value;
        end
    endfunction

    function [ADDR_WIDTH-1:0] burst_address_at;
        input [ADDR_WIDTH-1:0] base_address;
        input [7:0] burst_len;
        input [2:0] burst_size;
        input [1:0] burst_type;
        input [7:0] beat_index;
        reg [ADDR_WIDTH:0] beat_bytes;
        reg [ADDR_WIDTH:0] burst_bytes;
        reg [ADDR_WIDTH:0] byte_offset;
        reg [ADDR_WIDTH:0] wrap_base;
        reg [ADDR_WIDTH:0] selected_address;
        begin
            beat_bytes = transfer_bytes_of(burst_size);
            burst_bytes = beat_bytes *
                ({{(ADDR_WIDTH-8){1'b0}}, 1'b0, burst_len} + 1'b1);
            byte_offset = beat_bytes *
                {{(ADDR_WIDTH-8){1'b0}}, 1'b0, beat_index};
            selected_address = {1'b0, base_address};
            if (burst_type == AXI_BURST_FIXED) begin
                selected_address = {1'b0, base_address};
            end else if (burst_type == AXI_BURST_WRAP) begin
                wrap_base = {1'b0, base_address} &
                    ~(burst_bytes - 1'b1);
                byte_offset =
                    ({1'b0, base_address} - wrap_base + byte_offset) %
                    burst_bytes;
                selected_address = wrap_base + byte_offset;
            end else begin
                selected_address =
                    {1'b0, base_address} + byte_offset;
            end
            burst_address_at = selected_address[ADDR_WIDTH-1:0];
        end
    endfunction

    function integer write_data_index_of;
        input [WRITE_PTR_WIDTH-1:0] slot;
        input [7:0] beat;
        begin
            write_data_index_of =
                (32'(slot) * MAX_BURST_BEATS) + 32'(beat);
        end
    endfunction

    function integer read_data_index_of;
        input [READ_PTR_WIDTH-1:0] slot;
        input [7:0] beat;
        begin
            read_data_index_of =
                (32'(slot) * MAX_BURST_BEATS) + 32'(beat);
        end
    endfunction

    function [READ_PTR_WIDTH-1:0] next_read_ptr;
        input [READ_PTR_WIDTH-1:0] ptr;
        begin
            if (ptr == READ_LAST_PTR)
                next_read_ptr = {READ_PTR_WIDTH{1'b0}};
            else
                next_read_ptr = ptr + 1'b1;
        end
    endfunction

    function [WRITE_PTR_WIDTH-1:0] next_write_ptr;
        input [WRITE_PTR_WIDTH-1:0] ptr;
        begin
            if (ptr == WRITE_LAST_PTR)
                next_write_ptr = {WRITE_PTR_WIDTH{1'b0}};
            else
                next_write_ptr = ptr + 1'b1;
        end
    endfunction

    function [1:0] request_response;
        input [ADDR_WIDTH-1:0] request_address;
        input [7:0] request_len;
        input [2:0] request_size;
        input [1:0] request_burst;
        input request_lock;
        reg [ADDR_WIDTH:0] beat_bytes;
        reg [ADDR_WIDTH:0] burst_bytes;
        reg [ADDR_WIDTH:0] first_byte;
        reg [ADDR_WIDTH:0] last_byte;
        reg [ADDR_WIDTH:0] wrap_base;
        reg [ADDR_WIDTH:0] memory_first;
        reg [ADDR_WIDTH:0] memory_limit;
        begin
            request_response = AXI_RESP_OKAY;
            beat_bytes = transfer_bytes_of(request_size);
            burst_bytes = beat_bytes *
                ({{(ADDR_WIDTH-8){1'b0}}, 1'b0, request_len} + 1'b1);
            first_byte = {1'b0, request_address};
            last_byte = first_byte + beat_bytes - 1'b1;
            wrap_base = first_byte & ~(burst_bytes - 1'b1);
            memory_first = {1'b0, MEM_BASE};
            memory_limit = memory_first + MEM_BYTES;

            if (request_lock || (request_size > AXI_MAX_SIZE) ||
                (request_burst == 2'b11)) begin
                request_response = AXI_RESP_DECERR;
            end else if ((first_byte & (beat_bytes - 1'b1)) != 0) begin
                // The fixture intentionally rejects unaligned transfers rather
                // than guessing at cross-lane narrow-transfer semantics.
                request_response = AXI_RESP_DECERR;
            end else begin
                case (request_burst)
                    AXI_BURST_FIXED: begin
                        if (request_len > 8'd15)
                            request_response = AXI_RESP_DECERR;
                        last_byte = first_byte + beat_bytes - 1'b1;
                    end
                    AXI_BURST_INCR:
                        last_byte = first_byte + burst_bytes - 1'b1;
                    AXI_BURST_WRAP: begin
                        if (!((request_len == 8'd1) ||
                              (request_len == 8'd3) ||
                              (request_len == 8'd7) ||
                              (request_len == 8'd15)))
                            request_response = AXI_RESP_DECERR;
                        last_byte = wrap_base + burst_bytes - 1'b1;
                    end
                    default:
                        request_response = AXI_RESP_DECERR;
                endcase

                if ((first_byte < memory_first) ||
                    (last_byte >= memory_limit) ||
                    (first_byte[ADDR_WIDTH:12] !=
                     last_byte[ADDR_WIDTH:12]))
                    request_response = AXI_RESP_DECERR;
            end
        end
    endfunction

    function bursts_overlap;
        input [ADDR_WIDTH-1:0] first_addr;
        input [7:0] first_len;
        input [2:0] first_size;
        input [1:0] first_burst;
        input [ADDR_WIDTH-1:0] second_addr;
        input [7:0] second_len;
        input [2:0] second_size;
        input [1:0] second_burst;
        reg [ADDR_WIDTH:0] first_beat_bytes;
        reg [ADDR_WIDTH:0] first_burst_bytes;
        reg [ADDR_WIDTH:0] first_start;
        reg [ADDR_WIDTH:0] first_end;
        reg [ADDR_WIDTH:0] second_beat_bytes;
        reg [ADDR_WIDTH:0] second_burst_bytes;
        reg [ADDR_WIDTH:0] second_start;
        reg [ADDR_WIDTH:0] second_end;
        begin
            first_beat_bytes = transfer_bytes_of(first_size);
            first_burst_bytes = first_beat_bytes *
                ({{(ADDR_WIDTH-8){1'b0}}, 1'b0, first_len} + 1'b1);
            first_start = {1'b0, first_addr};
            if (first_burst == AXI_BURST_FIXED)
                first_end = first_start + first_beat_bytes;
            else if (first_burst == AXI_BURST_WRAP) begin
                first_start = first_start & ~(first_burst_bytes - 1'b1);
                first_end = first_start + first_burst_bytes;
            end else
                first_end = first_start + first_burst_bytes;

            second_beat_bytes = transfer_bytes_of(second_size);
            second_burst_bytes = second_beat_bytes *
                ({{(ADDR_WIDTH-8){1'b0}}, 1'b0, second_len} + 1'b1);
            second_start = {1'b0, second_addr};
            if (second_burst == AXI_BURST_FIXED)
                second_end = second_start + second_beat_bytes;
            else if (second_burst == AXI_BURST_WRAP) begin
                second_start =
                    second_start & ~(second_burst_bytes - 1'b1);
                second_end = second_start + second_burst_bytes;
            end else
                second_end = second_start + second_burst_bytes;

            bursts_overlap =
                (first_start < second_end) &&
                (second_start < first_end);
        end
    endfunction

    function [DATA_BYTES-1:0] transfer_lane_mask;
        input [ADDR_WIDTH-1:0] transfer_address;
        input [2:0] transfer_size;
        integer lane_index;
        integer first_lane;
        integer lane_count;
        begin
            transfer_lane_mask = {DATA_BYTES{1'b0}};
            first_lane = transfer_address & (DATA_BYTES - 1);
            lane_count = 1 << transfer_size;
            for (lane_index = 0; lane_index < DATA_BYTES;
                 lane_index = lane_index + 1) begin
                if ((lane_index >= first_lane) &&
                    (lane_index < (first_lane + lane_count)))
                    transfer_lane_mask[lane_index] = 1'b1;
            end
        end
    endfunction

    function [WORD_INDEX_WIDTH-1:0] memory_index_of;
        input [ADDR_WIDTH-1:0] byte_address;
        reg [ADDR_WIDTH-1:0] local_address;
        begin
            local_address = byte_address - MEM_BASE;
            memory_index_of =
                local_address[DATA_BYTE_BITS +: WORD_INDEX_WIDTH];
        end
    endfunction

    wire [1:0] incoming_read_resp = request_response(
        s_axi_araddr_i, s_axi_arlen_i, s_axi_arsize_i,
        s_axi_arburst_i, s_axi_arlock_i);
    wire [1:0] incoming_write_resp = request_response(
        s_axi_awaddr_i, s_axi_awlen_i, s_axi_awsize_i,
        s_axi_awburst_i, s_axi_awlock_i);

    reg read_candidate_valid;
    reg [READ_PTR_WIDTH-1:0] read_candidate_slot;
    reg write_candidate_valid;
    reg [WRITE_PTR_WIDTH-1:0] write_candidate_slot;
    always @* begin
        read_candidate_valid = 1'b0;
        read_candidate_slot = {READ_PTR_WIDTH{1'b0}};
        for (read_scan_offset = 0;
             read_scan_offset < READ_QUEUE_DEPTH;
             read_scan_offset = read_scan_offset + 1) begin
            read_scan_slot = 32'(read_head_q) + read_scan_offset;
            if (read_scan_slot >= READ_QUEUE_DEPTH)
                read_scan_slot = read_scan_slot - READ_QUEUE_DEPTH;
            if (!read_candidate_valid &&
                read_valid_q[read_scan_slot] &&
                !read_timing_submitted_q[read_scan_slot] &&
                !read_timing_done_q[read_scan_slot] &&
                (read_resp_fifo_q[read_scan_slot] == AXI_RESP_OKAY)) begin
                read_candidate_valid = 1'b1;
                read_candidate_slot = READ_PTR_WIDTH'(read_scan_slot);
            end
        end

        write_candidate_valid = 1'b0;
        write_candidate_slot = {WRITE_PTR_WIDTH{1'b0}};
        for (write_scan_offset = 0;
             write_scan_offset < WRITE_QUEUE_DEPTH;
             write_scan_offset = write_scan_offset + 1) begin
            write_scan_slot = 32'(write_head_q) + write_scan_offset;
            if (write_scan_slot >= WRITE_QUEUE_DEPTH)
                write_scan_slot = write_scan_slot - WRITE_QUEUE_DEPTH;
            write_candidate_blocked = 1'b0;
            for (write_older_offset = 0;
                 write_older_offset < WRITE_QUEUE_DEPTH;
                 write_older_offset = write_older_offset + 1) begin
                write_older_slot =
                    32'(write_head_q) + write_older_offset;
                if (write_older_slot >= WRITE_QUEUE_DEPTH)
                    write_older_slot =
                        write_older_slot - WRITE_QUEUE_DEPTH;
                if ((write_older_offset < write_scan_offset) &&
                    write_valid_q[write_older_slot] &&
                    !write_timing_done_q[write_older_slot] &&
                    (write_resp_fifo_q[write_older_slot] ==
                     AXI_RESP_OKAY) &&
                    bursts_overlap(
                        write_addr_fifo_q[write_older_slot],
                        write_len_fifo_q[write_older_slot],
                        write_size_fifo_q[write_older_slot],
                        write_burst_fifo_q[write_older_slot],
                        write_addr_fifo_q[write_scan_slot],
                        write_len_fifo_q[write_scan_slot],
                        write_size_fifo_q[write_scan_slot],
                        write_burst_fifo_q[write_scan_slot]))
                    write_candidate_blocked = 1'b1;
            end
            if (!write_candidate_valid &&
                !write_candidate_blocked &&
                write_valid_q[write_scan_slot] &&
                write_data_complete_q[write_scan_slot] &&
                !write_timing_submitted_q[write_scan_slot] &&
                !write_timing_done_q[write_scan_slot] &&
                (write_resp_fifo_q[write_scan_slot] ==
                 AXI_RESP_OKAY)) begin
                write_candidate_valid = 1'b1;
                write_candidate_slot =
                    WRITE_PTR_WIDTH'(write_scan_slot);
            end
        end
    end

    wire read_address_fire = s_axi_arvalid_i && s_axi_arready_o;
    wire write_address_fire = s_axi_awvalid_i && s_axi_awready_o;
    wire write_data_fire = s_axi_wvalid_i && s_axi_wready_o;
    wire read_response_fire = s_axi_rvalid_o && s_axi_rready_i;
    wire write_response_fire = s_axi_bvalid_o && s_axi_bready_i;

    wire arbitrate_write_command = write_candidate_valid &&
        (!read_candidate_valid || prefer_write_q);
    wire timing_selected_write = timing_hold_valid_q ?
        timing_hold_write_q : arbitrate_write_command;
    wire [READ_PTR_WIDTH-1:0] timing_selected_read_slot =
        timing_hold_valid_q ?
        timing_hold_read_slot_q : read_candidate_slot;
    wire [WRITE_PTR_WIDTH-1:0] timing_selected_write_slot =
        timing_hold_valid_q ?
        timing_hold_write_slot_q : write_candidate_slot;
    wire timing_command_fire = timing_cmd_valid_o && timing_cmd_ready_i;
    wire timing_response_fire = timing_resp_valid_i &&
                                timing_resp_ready_o;
    wire timing_response_owner_write =
        timing_resp_tag_i[TIMING_TAG_WIDTH-1];
    wire [READ_PTR_WIDTH-1:0] timing_response_read_slot =
        READ_PTR_WIDTH'(timing_resp_tag_i);
    wire [WRITE_PTR_WIDTH-1:0] timing_response_write_slot =
        WRITE_PTR_WIDTH'(timing_resp_tag_i);

    wire [ADDR_WIDTH-1:0] write_data_address = burst_address_at(
        write_addr_fifo_q[write_data_head_q],
        write_len_fifo_q[write_data_head_q],
        write_size_fifo_q[write_data_head_q],
        write_burst_fifo_q[write_data_head_q],
        write_beat_q[write_data_head_q]);
    wire write_data_expected_last =
        write_beat_q[write_data_head_q] ==
        write_len_fifo_q[write_data_head_q];
    wire write_data_finishes =
        s_axi_wlast_i || write_data_expected_last;

    assign s_axi_arready_o = rst_ni &&
        (read_count_q < READ_QUEUE_CAPACITY);
    assign s_axi_awready_o = rst_ni &&
        (write_count_q < WRITE_QUEUE_CAPACITY);
    assign s_axi_wready_o = rst_ni && (write_count_q != 0) &&
        write_valid_q[write_data_head_q] &&
        !write_data_complete_q[write_data_head_q];

    assign s_axi_rid_o = read_response_id_q;
    assign s_axi_rdata_o = read_response_data_q;
    assign s_axi_rresp_o = read_response_resp_q;
    assign s_axi_rlast_o = read_response_last_q;
    assign s_axi_rvalid_o = read_response_valid_q;

    assign s_axi_bid_o = write_id_fifo_q[write_head_q];
    assign s_axi_bresp_o = write_resp_fifo_q[write_head_q];
    assign s_axi_bvalid_o = rst_ni && (write_count_q != 0) &&
        write_valid_q[write_head_q] &&
        write_data_complete_q[write_head_q] &&
        ((write_resp_fifo_q[write_head_q] != AXI_RESP_OKAY) ||
         write_timing_done_q[write_head_q]);

    assign timing_cmd_valid_o = rst_ni &&
        (timing_owner_count_q < TIMING_OWNER_CAPACITY) &&
        (timing_hold_valid_q ||
         read_candidate_valid || write_candidate_valid);
    assign timing_cmd_write_o = timing_selected_write;
    assign timing_cmd_addr_o = timing_selected_write ?
        write_addr_fifo_q[timing_selected_write_slot] :
        read_addr_fifo_q[timing_selected_read_slot];
    wire [15:0] read_burst_bytes =
        ({8'd0, read_len_fifo_q[timing_selected_read_slot]} + 16'd1) <<
        read_size_fifo_q[timing_selected_read_slot];
    wire [15:0] write_burst_bytes =
        ({8'd0, write_len_fifo_q[timing_selected_write_slot]} + 16'd1) <<
        write_size_fifo_q[timing_selected_write_slot];
    assign timing_cmd_bytes_o = timing_selected_write ?
        write_burst_bytes : read_burst_bytes;
    assign timing_cmd_tag_o = timing_selected_write ?
        {1'b1,
         (TIMING_TAG_WIDTH-1)'(timing_selected_write_slot)} :
        {1'b0,
         (TIMING_TAG_WIDTH-1)'(timing_selected_read_slot)};
    assign timing_resp_ready_o = (timing_owner_count_q != 0);

    // These AXI attributes do not alter behavioral storage or timing yet.
    wire unused_axi_attributes = ^{s_axi_arcache_i, s_axi_arprot_i,
        s_axi_arqos_i, s_axi_awcache_i, s_axi_awprot_i, s_axi_awqos_i};

    initial begin
        if ((ADDR_WIDTH < 16) || (ADDR_WIDTH > 64))
            $fatal(1, "memory-channel AXI address width must be 16 through 64");
        if ((DATA_WIDTH < 32) || (DATA_WIDTH > 512) ||
            ((DATA_WIDTH & (DATA_WIDTH - 1)) != 0))
            $fatal(1, "memory-channel AXI data width must be 32, 64, 128, 256, or 512");
        if (ID_WIDTH < 1)
            $fatal(1, "memory-channel AXI ID width must be positive");
        if ((MEM_BYTES < DATA_BYTES) || ((MEM_BYTES % DATA_BYTES) != 0))
            $fatal(1, "memory-channel capacity must contain complete data beats");
        if ((MEM_BASE & (DATA_BYTES - 1)) != 0)
            $fatal(1, "memory-channel base must be data-beat aligned");
        if ((READ_QUEUE_DEPTH < 1) || (WRITE_QUEUE_DEPTH < 1))
            $fatal(1, "memory-channel queue depths must be positive");
        if ((TIMING_TAG_WIDTH < 2) ||
            ((1 << (TIMING_TAG_WIDTH - 1)) < READ_QUEUE_DEPTH) ||
            ((1 << (TIMING_TAG_WIDTH - 1)) < WRITE_QUEUE_DEPTH))
            $fatal(1, "memory-channel timing tag cannot encode queue slots");
        if ((ZERO_INIT_WORDS < 0) || (ZERO_INIT_WORDS > WORD_COUNT))
            $fatal(1, "memory-channel zero-init count exceeds capacity");

        for (init_index = 0; init_index < ZERO_INIT_WORDS;
             init_index = init_index + 1)
            memory_q[init_index] = {DATA_WIDTH{1'b0}};
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, memory_q);
    end

`ifndef SYNTHESIS
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            perf_read_bursts_q <= 64'd0;
            perf_write_bursts_q <= 64'd0;
            perf_read_single_beat_bursts_q <= 64'd0;
            perf_read_two_beat_bursts_q <= 64'd0;
            perf_read_other_bursts_q <= 64'd0;
            perf_write_single_beat_bursts_q <= 64'd0;
            perf_write_two_beat_bursts_q <= 64'd0;
            perf_write_other_bursts_q <= 64'd0;
            perf_read_beats_requested_q <= 64'd0;
            perf_write_beats_requested_q <= 64'd0;
            perf_read_beats_returned_q <= 64'd0;
            perf_write_beats_received_q <= 64'd0;
            perf_read_address_wait_cycles_q <= 64'd0;
            perf_write_address_wait_cycles_q <= 64'd0;
            perf_write_data_wait_cycles_q <= 64'd0;
            perf_read_response_wait_cycles_q <= 64'd0;
            perf_write_response_wait_cycles_q <= 64'd0;
            perf_timing_backend_wait_cycles_q <= 64'd0;
            perf_timing_owner_full_cycles_q <= 64'd0;
            perf_read_timing_wait_cycles_q <= 64'd0;
            perf_write_timing_wait_cycles_q <= 64'd0;
            perf_timing_read_commands_q <= 64'd0;
            perf_timing_write_commands_q <= 64'd0;
            perf_max_read_queue_q <= 64'd0;
            perf_max_write_queue_q <= 64'd0;
            perf_max_timing_owners_q <= 64'd0;
        end else begin
            if (read_address_fire) begin
                perf_read_bursts_q <= perf_read_bursts_q + 64'd1;
                perf_read_beats_requested_q <=
                    perf_read_beats_requested_q +
                    {56'd0, s_axi_arlen_i} + 64'd1;
                if (s_axi_arlen_i == 0)
                    perf_read_single_beat_bursts_q <=
                        perf_read_single_beat_bursts_q + 64'd1;
                else if (s_axi_arlen_i == 1)
                    perf_read_two_beat_bursts_q <=
                        perf_read_two_beat_bursts_q + 64'd1;
                else
                    perf_read_other_bursts_q <=
                        perf_read_other_bursts_q + 64'd1;
            end
            if (write_address_fire) begin
                perf_write_bursts_q <= perf_write_bursts_q + 64'd1;
                perf_write_beats_requested_q <=
                    perf_write_beats_requested_q +
                    {56'd0, s_axi_awlen_i} + 64'd1;
                if (s_axi_awlen_i == 0)
                    perf_write_single_beat_bursts_q <=
                        perf_write_single_beat_bursts_q + 64'd1;
                else if (s_axi_awlen_i == 1)
                    perf_write_two_beat_bursts_q <=
                        perf_write_two_beat_bursts_q + 64'd1;
                else
                    perf_write_other_bursts_q <=
                        perf_write_other_bursts_q + 64'd1;
            end
            if (read_response_fire)
                perf_read_beats_returned_q <=
                    perf_read_beats_returned_q + 64'd1;
            if (write_data_fire)
                perf_write_beats_received_q <=
                    perf_write_beats_received_q + 64'd1;

            if (s_axi_arvalid_i && !s_axi_arready_o)
                perf_read_address_wait_cycles_q <=
                    perf_read_address_wait_cycles_q + 64'd1;
            if (s_axi_awvalid_i && !s_axi_awready_o)
                perf_write_address_wait_cycles_q <=
                    perf_write_address_wait_cycles_q + 64'd1;
            if (s_axi_wvalid_i && !s_axi_wready_o)
                perf_write_data_wait_cycles_q <=
                    perf_write_data_wait_cycles_q + 64'd1;
            if (s_axi_rvalid_o && !s_axi_rready_i)
                perf_read_response_wait_cycles_q <=
                    perf_read_response_wait_cycles_q + 64'd1;
            if (s_axi_bvalid_o && !s_axi_bready_i)
                perf_write_response_wait_cycles_q <=
                    perf_write_response_wait_cycles_q + 64'd1;

            if (timing_cmd_valid_o && !timing_cmd_ready_i)
                perf_timing_backend_wait_cycles_q <=
                    perf_timing_backend_wait_cycles_q + 64'd1;
            if ((timing_owner_count_q == TIMING_OWNER_CAPACITY) &&
                (timing_hold_valid_q ||
                 read_candidate_valid || write_candidate_valid))
                perf_timing_owner_full_cycles_q <=
                    perf_timing_owner_full_cycles_q + 64'd1;
            if (read_candidate_valid &&
                !(timing_command_fire && !timing_selected_write))
                perf_read_timing_wait_cycles_q <=
                    perf_read_timing_wait_cycles_q + 64'd1;
            if (write_candidate_valid &&
                !(timing_command_fire && timing_selected_write))
                perf_write_timing_wait_cycles_q <=
                    perf_write_timing_wait_cycles_q + 64'd1;

            if (timing_command_fire) begin
                if (timing_selected_write)
                    perf_timing_write_commands_q <=
                        perf_timing_write_commands_q + 64'd1;
                else
                    perf_timing_read_commands_q <=
                        perf_timing_read_commands_q + 64'd1;
            end

            if (read_count_q > perf_max_read_queue_q)
                perf_max_read_queue_q <= read_count_q;
            if (write_count_q > perf_max_write_queue_q)
                perf_max_write_queue_q <= write_count_q;
            if (timing_owner_count_q > perf_max_timing_owners_q)
                perf_max_timing_owners_q <= timing_owner_count_q;
        end
    end
`endif

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_head_q <= {READ_PTR_WIDTH{1'b0}};
            read_tail_q <= {READ_PTR_WIDTH{1'b0}};
            read_count_q <= {(READ_PTR_WIDTH+1){1'b0}};
            write_head_q <= {WRITE_PTR_WIDTH{1'b0}};
            write_tail_q <= {WRITE_PTR_WIDTH{1'b0}};
            write_data_head_q <= {WRITE_PTR_WIDTH{1'b0}};
            write_count_q <= {(WRITE_PTR_WIDTH+1){1'b0}};

            read_response_id_q <= {ID_WIDTH{1'b0}};
            read_response_data_q <= {DATA_WIDTH{1'b0}};
            read_response_resp_q <= AXI_RESP_OKAY;
            read_response_last_q <= 1'b0;
            read_response_valid_q <= 1'b0;

            for (reset_read_slot = 0;
                 reset_read_slot < READ_QUEUE_DEPTH;
                 reset_read_slot = reset_read_slot + 1) begin
                read_valid_q[reset_read_slot] <= 1'b0;
                read_timing_submitted_q[reset_read_slot] <= 1'b0;
                read_timing_done_q[reset_read_slot] <= 1'b0;
                read_beat_q[reset_read_slot] <= 8'd0;
            end
            for (reset_write_slot = 0;
                 reset_write_slot < WRITE_QUEUE_DEPTH;
                 reset_write_slot = reset_write_slot + 1) begin
                write_valid_q[reset_write_slot] <= 1'b0;
                write_data_complete_q[reset_write_slot] <= 1'b0;
                write_timing_submitted_q[reset_write_slot] <= 1'b0;
                write_timing_done_q[reset_write_slot] <= 1'b0;
                write_beat_q[reset_write_slot] <= 8'd0;
            end
            timing_owner_count_q <=
                {TIMING_OWNER_COUNT_WIDTH{1'b0}};
            prefer_write_q <= 1'b0;
            timing_hold_valid_q <= 1'b0;
            timing_hold_write_q <= 1'b0;
            timing_hold_read_slot_q <= {READ_PTR_WIDTH{1'b0}};
            timing_hold_write_slot_q <= {WRITE_PTR_WIDTH{1'b0}};
        end else begin
            if (read_address_fire) begin
                read_id_fifo_q[read_tail_q] <= s_axi_arid_i;
                read_addr_fifo_q[read_tail_q] <= s_axi_araddr_i;
                read_len_fifo_q[read_tail_q] <= s_axi_arlen_i;
                read_size_fifo_q[read_tail_q] <= s_axi_arsize_i;
                read_burst_fifo_q[read_tail_q] <= s_axi_arburst_i;
                read_resp_fifo_q[read_tail_q] <= incoming_read_resp;
                read_valid_q[read_tail_q] <= 1'b1;
                read_timing_submitted_q[read_tail_q] <= 1'b0;
                read_timing_done_q[read_tail_q] <= 1'b0;
                read_beat_q[read_tail_q] <= 8'd0;
                read_tail_q <= next_read_ptr(read_tail_q);
            end

            case ({read_address_fire,
                   read_response_fire && read_response_last_q})
                2'b10: read_count_q <= read_count_q + 1'b1;
                2'b01: read_count_q <= read_count_q - 1'b1;
                default: begin end
            endcase

            if (write_address_fire) begin
                write_id_fifo_q[write_tail_q] <= s_axi_awid_i;
                write_addr_fifo_q[write_tail_q] <= s_axi_awaddr_i;
                write_len_fifo_q[write_tail_q] <= s_axi_awlen_i;
                write_size_fifo_q[write_tail_q] <= s_axi_awsize_i;
                write_burst_fifo_q[write_tail_q] <= s_axi_awburst_i;
                write_resp_fifo_q[write_tail_q] <= incoming_write_resp;
                write_valid_q[write_tail_q] <= 1'b1;
                write_data_complete_q[write_tail_q] <= 1'b0;
                write_timing_submitted_q[write_tail_q] <= 1'b0;
                write_timing_done_q[write_tail_q] <= 1'b0;
                write_beat_q[write_tail_q] <= 8'd0;
                write_tail_q <= next_write_ptr(write_tail_q);
            end

            case ({write_address_fire, write_response_fire})
                2'b10: write_count_q <= write_count_q + 1'b1;
                2'b01: write_count_q <= write_count_q - 1'b1;
                default: begin end
            endcase

            if (write_data_fire) begin
                write_data_q[write_data_index_of(
                    write_data_head_q,
                    write_beat_q[write_data_head_q])] <= s_axi_wdata_i;
                write_strb_q[write_data_index_of(
                    write_data_head_q,
                    write_beat_q[write_data_head_q])] <= s_axi_wstrb_i;
                if (((s_axi_wlast_i != write_data_expected_last) ||
                    |(s_axi_wstrb_i &
                      ~transfer_lane_mask(
                          write_data_address,
                          write_size_fifo_q[write_data_head_q]))) &&
                    (write_resp_fifo_q[write_data_head_q] ==
                     AXI_RESP_OKAY))
                    write_resp_fifo_q[write_data_head_q] <=
                        AXI_RESP_SLVERR;
                if (write_data_finishes) begin
                    write_data_complete_q[write_data_head_q] <= 1'b1;
                    write_data_head_q <=
                        next_write_ptr(write_data_head_q);
                end else begin
                    write_beat_q[write_data_head_q] <=
                        write_beat_q[write_data_head_q] + 1'b1;
                end
            end

            if (read_response_fire) begin
                read_response_valid_q <= 1'b0;
                if (read_response_last_q) begin
                    read_valid_q[read_head_q] <= 1'b0;
                    read_timing_submitted_q[read_head_q] <= 1'b0;
                    read_timing_done_q[read_head_q] <= 1'b0;
                    read_head_q <= next_read_ptr(read_head_q);
                end else begin
                    read_beat_q[read_head_q] <=
                        read_beat_q[read_head_q] + 1'b1;
                end
            end

            if (write_response_fire) begin
                write_valid_q[write_head_q] <= 1'b0;
                write_data_complete_q[write_head_q] <= 1'b0;
                write_timing_submitted_q[write_head_q] <= 1'b0;
                write_timing_done_q[write_head_q] <= 1'b0;
                write_head_q <= next_write_ptr(write_head_q);
            end

            // Lock the arbiter selection whenever the backend stalls.  The
            // timing command is a ready/valid channel, so write/address/bytes
            // must remain stable until the selected command is accepted.
            if (!timing_hold_valid_q && timing_cmd_valid_o &&
                !timing_cmd_ready_i) begin
                timing_hold_valid_q <= 1'b1;
                timing_hold_write_q <= arbitrate_write_command;
                timing_hold_read_slot_q <= read_candidate_slot;
                timing_hold_write_slot_q <= write_candidate_slot;
            end

            if (timing_command_fire) begin
                if (timing_hold_valid_q)
                    timing_hold_valid_q <= 1'b0;
                if (timing_selected_write) begin
                    write_timing_submitted_q[
                        timing_selected_write_slot] <= 1'b1;
                end else begin
                    read_timing_submitted_q[
                        timing_selected_read_slot] <= 1'b1;
                end
                prefer_write_q <= !timing_selected_write;
            end

            if (timing_response_fire) begin
                if (timing_response_owner_write) begin
                    if ((32'(timing_response_write_slot) >=
                         WRITE_QUEUE_DEPTH) ||
                        !write_valid_q[timing_response_write_slot] ||
                        !write_timing_submitted_q[
                            timing_response_write_slot])
                        $fatal(1,
                            "memory-channel invalid write timing tag %0d",
                            timing_resp_tag_i);
                    write_timing_submitted_q[
                        timing_response_write_slot] <= 1'b0;
                    write_timing_done_q[
                        timing_response_write_slot] <= 1'b1;
                    for (commit_beat = 0;
                         commit_beat < MAX_BURST_BEATS;
                        commit_beat = commit_beat + 1) begin
                        if (commit_beat <= write_len_fifo_q[
                            timing_response_write_slot]) begin
                            for (commit_byte = 0;
                                 commit_byte < DATA_BYTES;
                                 commit_byte = commit_byte + 1) begin
                                if (write_strb_q[write_data_index_of(
                                        timing_response_write_slot,
                                        8'(commit_beat))][commit_byte])
                                    memory_q[memory_index_of(
                                        burst_address_at(
                                            write_addr_fifo_q[
                                                timing_response_write_slot],
                                            write_len_fifo_q[
                                                timing_response_write_slot],
                                            write_size_fifo_q[
                                                timing_response_write_slot],
                                            write_burst_fifo_q[
                                                timing_response_write_slot],
                                            8'(commit_beat)))]
                                        [8*commit_byte +: 8] <=
                                        write_data_q[write_data_index_of(
                                            timing_response_write_slot,
                                            8'(commit_beat))]
                                                    [8*commit_byte +: 8];
                            end
                        end
                    end
                end else begin
                    if ((32'(timing_response_read_slot) >=
                         READ_QUEUE_DEPTH) ||
                        !read_valid_q[timing_response_read_slot] ||
                        !read_timing_submitted_q[
                            timing_response_read_slot])
                        $fatal(1,
                            "memory-channel invalid read timing tag %0d",
                            timing_resp_tag_i);
                    read_timing_submitted_q[
                        timing_response_read_slot] <= 1'b0;
                    read_timing_done_q[
                        timing_response_read_slot] <= 1'b1;
                    // Snapshot the completed read now.  AXI may drain this
                    // slot much later, after younger nonconflicting writes
                    // have committed.
                    for (commit_beat = 0;
                         commit_beat < MAX_BURST_BEATS;
                         commit_beat = commit_beat + 1) begin
                        if (commit_beat <= read_len_fifo_q[
                            timing_response_read_slot])
                            read_data_q[read_data_index_of(
                                timing_response_read_slot,
                                8'(commit_beat))] <=
                                memory_q[memory_index_of(
                                    burst_address_at(
                                        read_addr_fifo_q[
                                            timing_response_read_slot],
                                        read_len_fifo_q[
                                            timing_response_read_slot],
                                        read_size_fifo_q[
                                            timing_response_read_slot],
                                        read_burst_fifo_q[
                                            timing_response_read_slot],
                                        8'(commit_beat)))];
                    end
                end
            end

            case ({timing_command_fire, timing_response_fire})
                2'b10:
                    timing_owner_count_q <= timing_owner_count_q + 1'b1;
                2'b01:
                    timing_owner_count_q <= timing_owner_count_q - 1'b1;
                default: begin end
            endcase

            // DRAM schedules each complete burst once.  A completed head read
            // then drains AXI beats in address-acceptance order without
            // charging row/column timing again for each controller beat.
            // Decode errors use the same drain path but return zero data and
            // do not consume a timing queue entry.
            if (!read_response_valid_q && (read_count_q != 0) &&
                read_valid_q[read_head_q] &&
                ((read_resp_fifo_q[read_head_q] != AXI_RESP_OKAY) ||
                 read_timing_done_q[read_head_q])) begin
                read_response_id_q <= read_id_fifo_q[read_head_q];
                if (read_resp_fifo_q[read_head_q] == AXI_RESP_OKAY)
                    read_response_data_q <= read_data_q[
                        read_data_index_of(
                            read_head_q, read_beat_q[read_head_q])];
                else
                    read_response_data_q <= {DATA_WIDTH{1'b0}};
                read_response_resp_q <=
                    read_resp_fifo_q[read_head_q];
                read_response_last_q <=
                    read_beat_q[read_head_q] ==
                    read_len_fifo_q[read_head_q];
                read_response_valid_q <= 1'b1;
            end

            if (timing_resp_valid_i && (timing_owner_count_q == 0))
                $fatal(1, "memory-channel timing backend produced an unsolicited response");
        end
    end

endmodule
