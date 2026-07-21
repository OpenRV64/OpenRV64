`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// Shared physically addressed L2 cache and per-line ordering point.
//
// This first implementation is deliberately narrow: one line miss may be in
// progress, while up to MERGE_ENTRIES requests for that same line are accepted
// and replayed in acceptance order after refill.  Requests for other lines wait.
// That is real same-line miss merging without claiming a banked, hit-under-miss
// MSHR fabric.  The cache is write-back/write-allocate and emits one neutral
// external-bus beat at a time.
module openrv64_ccx_l2 #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer BUS_DATA_WIDTH = 256,
    parameter integer CACHE_BYTES = 256 * 1024,
    parameter integer LINE_BYTES = 64,
    parameter integer WAYS = 8,
    parameter integer MERGE_ENTRIES = 16
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,

    input  wire                         req_valid_i,
    output wire                         req_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] req_hart_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]  req_txn_id_i,
    input  wire [`OPENRV64_CCX_OP_WIDTH-1:0]      req_op_i,
    input  wire [`OPENRV64_CCX_ORDER_WIDTH-1:0]   req_order_i,
    input  wire [`OPENRV64_CCX_KIND_WIDTH-1:0]    req_kind_i,
    input  wire [`OPENRV64_CCX_ATTR_WIDTH-1:0]    req_attr_i,
    input  wire [2:0]                   req_size_i,
    input  wire [63:0]                  req_addr_i,
    input  wire [63:0]                  req_wdata_i,
    input  wire [7:0]                   req_wstrb_i,

    output wire                         resp_valid_o,
    input  wire                         resp_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] resp_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]  resp_txn_id_o,
    output wire [63:0]                  resp_rdata_o,
    output wire                         resp_error_o,
    output wire                         resp_sc_success_o,

    output wire                         bus_req_valid_o,
    input  wire                         bus_req_ready_i,
    output reg                          bus_req_write_o,
    output reg  [63:0]                  bus_req_addr_o,
    output reg  [2:0]                   bus_req_size_o,
    output reg  [BUS_DATA_WIDTH-1:0]    bus_req_wdata_o,
    output reg  [BUS_DATA_WIDTH/8-1:0]  bus_req_wstrb_o,
    output wire                         bus_req_cacheable_o,
    input  wire                         bus_resp_valid_i,
    output wire                         bus_resp_ready_o,
    input  wire [BUS_DATA_WIDTH-1:0]    bus_resp_rdata_i,
    input  wire                         bus_resp_error_i
);

    localparam integer BUS_BYTES = BUS_DATA_WIDTH / 8;
    localparam integer BUS_SIZE = $clog2(BUS_BYTES);
    localparam integer ARRAY_DATA_WIDTH = 256;
    localparam integer ARRAY_BYTES = ARRAY_DATA_WIDTH / 8;
    localparam integer SETS = CACHE_BYTES / (LINE_BYTES * WAYS);
    localparam integer TOTAL_LINES = CACHE_BYTES / LINE_BYTES;
    localparam integer ARRAY_WORDS = CACHE_BYTES / ARRAY_BYTES;
    localparam integer ARRAY_WORDS_PER_LINE = LINE_BYTES / ARRAY_BYTES;
    localparam integer LINE_OFFSET_BITS = $clog2(LINE_BYTES);
    localparam integer SET_BITS = $clog2(SETS);
    localparam integer TAG_BITS = ADDR_WIDTH - LINE_OFFSET_BITS - SET_BITS;
    localparam integer SET_INDEX_WIDTH = (SETS > 1) ? $clog2(SETS) : 1;
    localparam integer LINE_INDEX_WIDTH =
        (TOTAL_LINES > 1) ? $clog2(TOTAL_LINES) : 1;
    localparam integer ARRAY_INDEX_WIDTH =
        (ARRAY_WORDS > 1) ? $clog2(ARRAY_WORDS) : 1;
    localparam integer WAY_INDEX_WIDTH = (WAYS > 1) ? $clog2(WAYS) : 1;
    localparam integer LINE_BEATS = LINE_BYTES / BUS_BYTES;
    localparam integer BEAT_INDEX_WIDTH =
        (LINE_BEATS > 1) ? $clog2(LINE_BEATS) : 1;
    localparam integer MERGE_COUNT_WIDTH = $clog2(MERGE_ENTRIES + 1);
    localparam integer MERGE_INDEX_WIDTH =
        (MERGE_ENTRIES > 1) ? $clog2(MERGE_ENTRIES) : 1;

    localparam [4:0] STATE_IDLE         = 5'd0;
    localparam [4:0] STATE_LOOKUP       = 5'd1;
    localparam [4:0] STATE_RESPONSE     = 5'd2;
    localparam [4:0] STATE_WB_REQ       = 5'd3;
    localparam [4:0] STATE_WB_RESP      = 5'd4;
    localparam [4:0] STATE_REFILL_REQ   = 5'd5;
    localparam [4:0] STATE_REFILL_RESP  = 5'd6;
    localparam [4:0] STATE_REPLAY       = 5'd7;
    localparam [4:0] STATE_REPLAY_RESP  = 5'd8;
    localparam [4:0] STATE_ERROR_REPLAY = 5'd9;
    localparam [4:0] STATE_ERROR_RESP   = 5'd10;
    localparam [4:0] STATE_BYPASS_REQ   = 5'd11;
    localparam [4:0] STATE_BYPASS_RESP  = 5'd12;
    localparam [4:0] STATE_HIT_READ     = 5'd13;
    localparam [4:0] STATE_WB_LOAD      = 5'd14;
    localparam [4:0] STATE_REPLAY_LOAD  = 5'd15;

    localparam [WAY_INDEX_WIDTH-1:0] LAST_WAY =
        WAY_INDEX_WIDTH'(WAYS - 1);
    localparam [BEAT_INDEX_WIDTH-1:0] LAST_LINE_BEAT =
        BEAT_INDEX_WIDTH'(LINE_BEATS - 1);

    reg [4:0] state_q;

    reg valid_q [0:TOTAL_LINES-1];
    reg dirty_q [0:TOTAL_LINES-1];
    reg [TAG_BITS-1:0] tag_q [0:TOTAL_LINES-1];
    reg [WAY_INDEX_WIDTH-1:0] replace_q [0:SETS-1];
    // One 256-bit internal data port also defines the widest L2 producer beat.
    // genbus_interface independently converts that beat to the selected
    // external width and protocol. All controller states serialize data-array
    // operations so this remains a single-read, single-write SRAM boundary
    // rather than a giant asynchronous mux.
    reg [ARRAY_DATA_WIDTH-1:0] data_q [0:ARRAY_WORDS-1];
    reg [ARRAY_DATA_WIDTH-1:0] data_read_q;
    reg [ARRAY_INDEX_WIDTH-1:0] data_read_index;
    reg data_write_enable;
    reg [ARRAY_INDEX_WIDTH-1:0] data_write_index;
    reg [ARRAY_DATA_WIDTH-1:0] data_write_data;
    reg [ARRAY_BYTES-1:0] data_write_mask;

    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] request_hart_id_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] request_txn_id_q;
    reg [`OPENRV64_CCX_OP_WIDTH-1:0] request_op_q;
    reg [`OPENRV64_CCX_ATTR_WIDTH-1:0] request_attr_q;
    reg [2:0] request_size_q;
    reg [63:0] request_addr_q;
    reg [63:0] request_wdata_q;
    reg [7:0] request_wstrb_q;

    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
        merge_hart_id_q [0:MERGE_ENTRIES-1];
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
        merge_txn_id_q [0:MERGE_ENTRIES-1];
    reg [`OPENRV64_CCX_OP_WIDTH-1:0]
        merge_op_q [0:MERGE_ENTRIES-1];
    reg [63:0] merge_addr_q [0:MERGE_ENTRIES-1];
    reg [63:0] merge_wdata_q [0:MERGE_ENTRIES-1];
    reg [7:0] merge_wstrb_q [0:MERGE_ENTRIES-1];
    reg [MERGE_COUNT_WIDTH-1:0] merge_count_q;
    reg [MERGE_INDEX_WIDTH-1:0] replay_index_q;

    reg [63:0] miss_line_addr_q;
    reg [SET_INDEX_WIDTH-1:0] miss_set_q;
    reg [WAY_INDEX_WIDTH-1:0] miss_way_q;
    reg [LINE_INDEX_WIDTH-1:0] miss_line_index_q;
    reg [TAG_BITS-1:0] miss_tag_q;
    reg [63:0] victim_line_addr_q;
    reg [BEAT_INDEX_WIDTH-1:0] line_beat_q;

    reg [1:0] bypass_total_beats_q;
    reg [1:0] bypass_beat_q;
    reg [63:0] bypass_read_data_q;

    reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] response_hart_id_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] response_txn_id_q;
    reg [63:0] response_data_q;
    reg response_error_q;

    reg [SET_INDEX_WIDTH-1:0] lookup_set;
    reg [TAG_BITS-1:0] lookup_tag;
    reg lookup_hit;
    reg [WAY_INDEX_WIDTH-1:0] lookup_way;
    reg [WAY_INDEX_WIDTH-1:0] victim_way;
    reg invalid_way_found;
    reg [LINE_INDEX_WIDTH-1:0] lookup_line;
    reg [LINE_INDEX_WIDTH-1:0] victim_line;
    reg [63:0] bypass_combined_data;
    integer lookup_way_index;
    integer set_index;
    integer line_index;
    integer bypass_byte_index;
    integer array_byte_index;
    integer data_mask_index;
    integer output_byte_index;
    integer response_byte_index;
    integer lookup_array_index;
    integer replay_array_index;
    integer transfer_array_index;
    integer transfer_array_lane;
    integer scalar_array_lane;
    integer replay_array_lane;
    integer bypass_lane_bytes;
    integer bypass_transfer_bytes;

    function [LINE_INDEX_WIDTH-1:0] line_index_of;
        input [SET_INDEX_WIDTH-1:0] set_value;
        input [WAY_INDEX_WIDTH-1:0] way_value;
        begin
            line_index_of = LINE_INDEX_WIDTH'(set_value) *
                            LINE_INDEX_WIDTH'(WAYS) +
                            LINE_INDEX_WIDTH'(way_value);
        end
    endfunction

    wire request_cacheable =
        |(request_attr_q & `OPENRV64_CCX_ATTR_CACHEABLE) &&
        !(|(request_attr_q & `OPENRV64_CCX_ATTR_DEVICE));
    wire incoming_cacheable =
        |(req_attr_i & `OPENRV64_CCX_ATTR_CACHEABLE) &&
        !(|(req_attr_i & `OPENRV64_CCX_ATTR_DEVICE));
    wire incoming_supported =
        ((req_op_i == `OPENRV64_CCX_OP_READ) ||
         (req_op_i == `OPENRV64_CCX_OP_WRITE)) && (req_size_i <= 3);
    wire [63:0] incoming_line_addr =
        {req_addr_i[63:LINE_OFFSET_BITS], {LINE_OFFSET_BITS{1'b0}}};
    wire miss_accept_state =
        (state_q == STATE_WB_LOAD) || (state_q == STATE_WB_REQ) ||
        (state_q == STATE_WB_RESP) ||
        (state_q == STATE_REFILL_REQ) ||
        (state_q == STATE_REFILL_RESP);
    wire merge_space =
        (merge_count_q < MERGE_COUNT_WIDTH'(MERGE_ENTRIES));
    wire merge_request = miss_accept_state && incoming_cacheable &&
                         incoming_supported &&
                         (incoming_line_addr == miss_line_addr_q) &&
                         merge_space;
    wire request_fire = req_valid_i && req_ready_o;
    wire bus_request_fire = bus_req_valid_o && bus_req_ready_i;
    wire bus_response_fire = bus_resp_valid_i && bus_resp_ready_o;
    wire response_fire = resp_valid_o && resp_ready_i;
    wire line_beat_last = (line_beat_q == LAST_LINE_BEAT);
    wire replay_last = (MERGE_COUNT_WIDTH'(replay_index_q) + 1'b1 >=
                        merge_count_q);
    wire bypass_last = (bypass_beat_q + 1'b1 >= bypass_total_beats_q);

    assign req_ready_o = (state_q == STATE_IDLE) || merge_request;
    assign resp_valid_o = (state_q == STATE_RESPONSE) ||
                          (state_q == STATE_REPLAY_RESP) ||
                          (state_q == STATE_ERROR_RESP);
    assign resp_hart_id_o = response_hart_id_q;
    assign resp_txn_id_o = response_txn_id_q;
    assign resp_rdata_o = response_data_q;
    assign resp_error_o = response_error_q;
    assign resp_sc_success_o = 1'b0;

    assign bus_req_valid_o = (state_q == STATE_WB_REQ) ||
                             (state_q == STATE_REFILL_REQ) ||
                             (state_q == STATE_BYPASS_REQ);
    assign bus_resp_ready_o = (state_q == STATE_WB_RESP) ||
                              (state_q == STATE_REFILL_RESP) ||
                              (state_q == STATE_BYPASS_RESP);
    assign bus_req_cacheable_o = (state_q != STATE_BYPASS_REQ);

    initial begin
        if ((ADDR_WIDTH < 32) || (ADDR_WIDTH > 64))
            $fatal(1, "L2 address width must be from 32 through 64");
        if ((BUS_DATA_WIDTH < 32) || (BUS_DATA_WIDTH > 256) ||
            ((BUS_DATA_WIDTH & (BUS_DATA_WIDTH - 1)) != 0))
            $fatal(1, "L2 bus width must be 32, 64, 128, or 256");
        if ((CACHE_BYTES < 256 * 1024) ||
            (CACHE_BYTES > 1024 * 1024) ||
            ((CACHE_BYTES & (CACHE_BYTES - 1)) != 0))
            $fatal(1, "L2 capacity must be a power of two from 256 KiB through 1 MiB");
        if ((LINE_BYTES < ARRAY_BYTES) || (LINE_BYTES < BUS_BYTES) ||
            ((LINE_BYTES & (LINE_BYTES - 1)) != 0) ||
            ((LINE_BYTES % ARRAY_BYTES) != 0) ||
            ((LINE_BYTES % BUS_BYTES) != 0))
            $fatal(1, "L2 line size must contain whole 256-bit array words and bus beats");
        if ((WAYS < 1) || ((WAYS & (WAYS - 1)) != 0))
            $fatal(1, "L2 ways must be a power of two");
        if ((CACHE_BYTES % (LINE_BYTES * WAYS)) != 0)
            $fatal(1, "L2 capacity must contain an integer number of sets");
        if ((MERGE_ENTRIES < 1) || (MERGE_ENTRIES > 16))
            $fatal(1, "L2 merge entries must be from 1 through 16");
    end

    always @* begin
        lookup_set = request_addr_q[LINE_OFFSET_BITS +: SET_INDEX_WIDTH];
        if (SETS == 1)
            lookup_set = 0;
        lookup_tag = request_addr_q[ADDR_WIDTH-1:
                                    LINE_OFFSET_BITS + SET_BITS];
        lookup_hit = 1'b0;
        lookup_way = {WAY_INDEX_WIDTH{1'b0}};
        for (lookup_way_index = 0; lookup_way_index < WAYS;
             lookup_way_index = lookup_way_index + 1) begin
            lookup_line = line_index_of(
                lookup_set, lookup_way_index[WAY_INDEX_WIDTH-1:0]);
            if (valid_q[lookup_line] &&
                (tag_q[lookup_line] == lookup_tag)) begin
                lookup_hit = 1'b1;
                lookup_way = lookup_way_index[WAY_INDEX_WIDTH-1:0];
            end
        end
        lookup_line = line_index_of(lookup_set, lookup_way);

        victim_way = replace_q[lookup_set];
        invalid_way_found = 1'b0;
        for (lookup_way_index = 0; lookup_way_index < WAYS;
             lookup_way_index = lookup_way_index + 1) begin
            victim_line = line_index_of(
                lookup_set, lookup_way_index[WAY_INDEX_WIDTH-1:0]);
            if (!invalid_way_found && !valid_q[victim_line]) begin
                victim_way = lookup_way_index[WAY_INDEX_WIDTH-1:0];
                invalid_way_found = 1'b1;
            end
        end
        victim_line = line_index_of(lookup_set, victim_way);

        lookup_array_index = (lookup_line * ARRAY_WORDS_PER_LINE) +
            32'((request_addr_q >> 5) &
                64'(ARRAY_WORDS_PER_LINE - 1));
        replay_array_index =
            (miss_line_index_q * ARRAY_WORDS_PER_LINE) +
            32'((merge_addr_q[replay_index_q] >> 5) &
                64'(ARRAY_WORDS_PER_LINE - 1));
        transfer_array_index =
            (miss_line_index_q * ARRAY_WORDS_PER_LINE) +
            ((line_beat_q * BUS_BYTES) / ARRAY_BYTES);
        transfer_array_lane = (line_beat_q * BUS_BYTES) % ARRAY_BYTES;
        scalar_array_lane = 32'(request_addr_q[4:0]);
        replay_array_lane = 32'(merge_addr_q[replay_index_q][4:0]);

        bypass_transfer_bytes = (1 << request_size_q);
        bypass_lane_bytes = 32'(request_addr_q[BUS_SIZE-1:0]);
        bypass_combined_data = bypass_read_data_q;
        if (BUS_BYTES < 8) begin
            for (bypass_byte_index = 0; bypass_byte_index < BUS_BYTES;
                 bypass_byte_index = bypass_byte_index + 1)
                if (((bypass_beat_q * BUS_BYTES) + bypass_byte_index) < 8)
                    bypass_combined_data[
                        8*((bypass_beat_q * BUS_BYTES) + bypass_byte_index) +: 8] =
                        bus_resp_rdata_i[8*bypass_byte_index +: 8];
        end else begin
            for (bypass_byte_index = 0; bypass_byte_index < 8;
                 bypass_byte_index = bypass_byte_index + 1)
                if (bypass_byte_index < bypass_transfer_bytes)
                    bypass_combined_data[8*bypass_byte_index +: 8] =
                        bus_resp_rdata_i[
                            8*(bypass_lane_bytes + bypass_byte_index) +: 8];
        end
    end

    always @* begin
        data_read_index = ARRAY_INDEX_WIDTH'(lookup_array_index);
        if (state_q == STATE_WB_LOAD)
            data_read_index = ARRAY_INDEX_WIDTH'(transfer_array_index);
        else if (state_q == STATE_REPLAY_LOAD)
            data_read_index = ARRAY_INDEX_WIDTH'(replay_array_index);

        data_write_enable = 1'b0;
        data_write_index = {ARRAY_INDEX_WIDTH{1'b0}};
        data_write_data = {ARRAY_DATA_WIDTH{1'b0}};
        data_write_mask = {ARRAY_BYTES{1'b0}};

        if ((state_q == STATE_LOOKUP) && request_cacheable && lookup_hit &&
            (request_op_q == `OPENRV64_CCX_OP_WRITE)) begin
            data_write_enable = 1'b1;
            data_write_index = ARRAY_INDEX_WIDTH'(lookup_array_index);
            for (array_byte_index = 0; array_byte_index < 8;
                 array_byte_index = array_byte_index + 1) begin
                if (request_wstrb_q[array_byte_index]) begin
                    data_write_data[
                        8*(scalar_array_lane + array_byte_index) +: 8] =
                        request_wdata_q[8*array_byte_index +: 8];
                    data_write_mask[scalar_array_lane + array_byte_index] = 1'b1;
                end
            end
        end else if ((state_q == STATE_REFILL_RESP) &&
                     bus_response_fire && !bus_resp_error_i) begin
            data_write_enable = 1'b1;
            data_write_index = ARRAY_INDEX_WIDTH'(transfer_array_index);
            for (array_byte_index = 0; array_byte_index < BUS_BYTES;
                 array_byte_index = array_byte_index + 1) begin
                data_write_data[
                    8*(transfer_array_lane + array_byte_index) +: 8] =
                    bus_resp_rdata_i[8*array_byte_index +: 8];
                data_write_mask[transfer_array_lane + array_byte_index] = 1'b1;
            end
        end else if ((state_q == STATE_REPLAY) &&
                     (merge_op_q[replay_index_q] ==
                      `OPENRV64_CCX_OP_WRITE)) begin
            data_write_enable = 1'b1;
            data_write_index = ARRAY_INDEX_WIDTH'(replay_array_index);
            for (array_byte_index = 0; array_byte_index < 8;
                 array_byte_index = array_byte_index + 1) begin
                if (merge_wstrb_q[replay_index_q][array_byte_index]) begin
                    data_write_data[
                        8*(replay_array_lane + array_byte_index) +: 8] =
                        merge_wdata_q[replay_index_q]
                            [8*array_byte_index +: 8];
                    data_write_mask[replay_array_lane + array_byte_index] =
                        1'b1;
                end
            end
        end
    end

    always @(posedge clk_i) begin
        data_read_q <= data_q[data_read_index];
        if (data_write_enable) begin
            for (data_mask_index = 0; data_mask_index < ARRAY_BYTES;
                 data_mask_index = data_mask_index + 1)
                if (data_write_mask[data_mask_index])
                    data_q[data_write_index][8*data_mask_index +: 8] <=
                        data_write_data[8*data_mask_index +: 8];
        end
    end

    always @* begin
        bus_req_write_o = 1'b0;
        bus_req_addr_o = 64'd0;
        bus_req_size_o = BUS_SIZE[2:0];
        bus_req_wdata_o = {BUS_DATA_WIDTH{1'b0}};
        bus_req_wstrb_o = {BUS_BYTES{1'b0}};

        if (state_q == STATE_WB_REQ) begin
            bus_req_write_o = 1'b1;
            bus_req_addr_o = victim_line_addr_q +
                             (line_beat_q * BUS_BYTES);
            bus_req_size_o = BUS_SIZE[2:0];
            bus_req_wstrb_o = {BUS_BYTES{1'b1}};
            for (output_byte_index = 0; output_byte_index < BUS_BYTES;
                 output_byte_index = output_byte_index + 1)
                bus_req_wdata_o[8*output_byte_index +: 8] =
                    data_read_q[
                        8*(transfer_array_lane + output_byte_index) +: 8];
        end else if (state_q == STATE_REFILL_REQ) begin
            bus_req_addr_o = miss_line_addr_q +
                             (line_beat_q * BUS_BYTES);
            bus_req_size_o = BUS_SIZE[2:0];
        end else if (state_q == STATE_BYPASS_REQ) begin
            bus_req_write_o = (request_op_q == `OPENRV64_CCX_OP_WRITE);
            if (bypass_transfer_bytes > BUS_BYTES) begin
                bus_req_addr_o = request_addr_q +
                                 (bypass_beat_q * BUS_BYTES);
                bus_req_size_o = BUS_SIZE[2:0];
                for (output_byte_index = 0;
                     output_byte_index < BUS_BYTES;
                     output_byte_index = output_byte_index + 1) begin
                    if (((bypass_beat_q * BUS_BYTES) +
                         output_byte_index) < 8) begin
                        bus_req_wdata_o[8*output_byte_index +: 8] =
                            request_wdata_q[
                                8*((bypass_beat_q * BUS_BYTES) +
                                   output_byte_index) +: 8];
                        bus_req_wstrb_o[output_byte_index] =
                            request_wstrb_q[
                                (bypass_beat_q * BUS_BYTES) +
                                output_byte_index];
                    end
                end
            end else begin
                bus_req_addr_o = request_addr_q;
                bus_req_size_o = request_size_q;
                for (output_byte_index = 0; output_byte_index < 8;
                     output_byte_index = output_byte_index + 1) begin
                    if ((output_byte_index < bypass_transfer_bytes) &&
                        ((bypass_lane_bytes + output_byte_index) < BUS_BYTES)) begin
                        bus_req_wdata_o[
                            8*(bypass_lane_bytes + output_byte_index) +: 8] =
                            request_wdata_q[8*output_byte_index +: 8];
                        bus_req_wstrb_o[
                            bypass_lane_bytes + output_byte_index] =
                            request_wstrb_q[output_byte_index];
                    end
                end
            end
        end
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= STATE_IDLE;
            request_hart_id_q <= 0;
            request_txn_id_q <= 0;
            request_op_q <= `OPENRV64_CCX_OP_READ;
            request_attr_q <= `OPENRV64_CCX_ATTR_NONE;
            request_size_q <= 0;
            request_addr_q <= 0;
            request_wdata_q <= 0;
            request_wstrb_q <= 0;
            merge_count_q <= 0;
            replay_index_q <= 0;
            miss_line_addr_q <= 0;
            miss_set_q <= 0;
            miss_way_q <= 0;
            miss_line_index_q <= 0;
            miss_tag_q <= 0;
            victim_line_addr_q <= 0;
            line_beat_q <= 0;
            bypass_total_beats_q <= 0;
            bypass_beat_q <= 0;
            bypass_read_data_q <= 0;
            response_hart_id_q <= 0;
            response_txn_id_q <= 0;
            response_data_q <= 0;
            response_error_q <= 0;
            for (set_index = 0; set_index < SETS;
                 set_index = set_index + 1)
                replace_q[set_index] <= 0;
            for (line_index = 0; line_index < TOTAL_LINES;
                 line_index = line_index + 1) begin
                valid_q[line_index] <= 1'b0;
                dirty_q[line_index] <= 1'b0;
            end
        end else begin
            // A request accepted while a fill is active is necessarily for
            // the same line (req_ready_o enforces this) and joins its FIFO.
            if (request_fire && miss_accept_state) begin
                merge_hart_id_q[
                    merge_count_q[MERGE_INDEX_WIDTH-1:0]] <= req_hart_id_i;
                merge_txn_id_q[
                    merge_count_q[MERGE_INDEX_WIDTH-1:0]] <= req_txn_id_i;
                merge_op_q[
                    merge_count_q[MERGE_INDEX_WIDTH-1:0]] <= req_op_i;
                merge_addr_q[
                    merge_count_q[MERGE_INDEX_WIDTH-1:0]] <= req_addr_i;
                merge_wdata_q[
                    merge_count_q[MERGE_INDEX_WIDTH-1:0]] <= req_wdata_i;
                merge_wstrb_q[
                    merge_count_q[MERGE_INDEX_WIDTH-1:0]] <= req_wstrb_i;
                merge_count_q <= merge_count_q + 1'b1;
            end

            case (state_q)
                STATE_IDLE: begin
                    response_error_q <= 1'b0;
                    if (request_fire) begin
                        request_hart_id_q <= req_hart_id_i;
                        request_txn_id_q <= req_txn_id_i;
                        request_op_q <= req_op_i;
                        request_attr_q <= req_attr_i;
                        request_size_q <= req_size_i;
                        request_addr_q <= req_addr_i;
                        request_wdata_q <= req_wdata_i;
                        request_wstrb_q <= req_wstrb_i;
                        state_q <= STATE_LOOKUP;
                    end
                end

                STATE_LOOKUP: begin
                    response_hart_id_q <= request_hart_id_q;
                    response_txn_id_q <= request_txn_id_q;
                    response_data_q <= 64'd0;
                    response_error_q <= 1'b0;

                    if (request_op_q == `OPENRV64_CCX_OP_FENCE) begin
                        state_q <= STATE_RESPONSE;
                    end else if (((request_op_q != `OPENRV64_CCX_OP_READ) &&
                                  (request_op_q != `OPENRV64_CCX_OP_WRITE)) ||
                                 (request_size_q > 3)) begin
                        response_error_q <= 1'b1;
                        state_q <= STATE_RESPONSE;
                    end else if (!request_cacheable) begin
                        bypass_beat_q <= 0;
                        bypass_read_data_q <= 0;
                        if (bypass_transfer_bytes > BUS_BYTES)
                            bypass_total_beats_q <=
                                2'(bypass_transfer_bytes / BUS_BYTES);
                        else
                            bypass_total_beats_q <= 1;
                        if ((bypass_transfer_bytes <= BUS_BYTES) &&
                            ((bypass_lane_bytes + bypass_transfer_bytes) >
                             BUS_BYTES)) begin
                            response_error_q <= 1'b1;
                            state_q <= STATE_RESPONSE;
                        end else begin
                            state_q <= STATE_BYPASS_REQ;
                        end
                    end else if (lookup_hit) begin
                        replace_q[lookup_set] <=
                            (lookup_way == LAST_WAY) ? 0 : lookup_way + 1'b1;
                        if (request_op_q == `OPENRV64_CCX_OP_WRITE) begin
                            dirty_q[lookup_line] <= 1'b1;
                            state_q <= STATE_RESPONSE;
                        end else begin
                            state_q <= STATE_HIT_READ;
                        end
                    end else begin
                        merge_hart_id_q[0] <= request_hart_id_q;
                        merge_txn_id_q[0] <= request_txn_id_q;
                        merge_op_q[0] <= request_op_q;
                        merge_addr_q[0] <= request_addr_q;
                        merge_wdata_q[0] <= request_wdata_q;
                        merge_wstrb_q[0] <= request_wstrb_q;
                        merge_count_q <= 1;
                        replay_index_q <= 0;
                        miss_line_addr_q <=
                            {request_addr_q[63:LINE_OFFSET_BITS],
                             {LINE_OFFSET_BITS{1'b0}}};
                        miss_set_q <= lookup_set;
                        miss_way_q <= victim_way;
                        miss_line_index_q <= victim_line;
                        miss_tag_q <= lookup_tag;
                        victim_line_addr_q <=
                            {tag_q[victim_line], lookup_set,
                             {LINE_OFFSET_BITS{1'b0}}};
                        line_beat_q <= 0;
                        if (valid_q[victim_line] && dirty_q[victim_line]) begin
                            state_q <= STATE_WB_LOAD;
                        end else begin
                            valid_q[victim_line] <= 1'b0;
                            dirty_q[victim_line] <= 1'b0;
                            state_q <= STATE_REFILL_REQ;
                        end
                    end
                end

                STATE_HIT_READ: begin
                    for (response_byte_index = 0; response_byte_index < 8;
                         response_byte_index = response_byte_index + 1)
                        response_data_q[8*response_byte_index +: 8] <=
                            data_read_q[
                                8*(scalar_array_lane + response_byte_index) +: 8];
                    state_q <= STATE_RESPONSE;
                end

                STATE_WB_LOAD: state_q <= STATE_WB_REQ;

                STATE_WB_REQ: begin
                    if (bus_request_fire)
                        state_q <= STATE_WB_RESP;
                end

                STATE_WB_RESP: begin
                    if (bus_response_fire) begin
                        if (bus_resp_error_i) begin
                            replay_index_q <= 0;
                            state_q <= STATE_ERROR_REPLAY;
                        end else if (line_beat_last) begin
                            valid_q[miss_line_index_q] <= 1'b0;
                            dirty_q[miss_line_index_q] <= 1'b0;
                            line_beat_q <= 0;
                            state_q <= STATE_REFILL_REQ;
                        end else begin
                            line_beat_q <= line_beat_q + 1'b1;
                            state_q <= STATE_WB_LOAD;
                        end
                    end
                end

                STATE_REFILL_REQ: begin
                    if (bus_request_fire)
                        state_q <= STATE_REFILL_RESP;
                end

                STATE_REFILL_RESP: begin
                    if (bus_response_fire) begin
                        if (bus_resp_error_i) begin
                            valid_q[miss_line_index_q] <= 1'b0;
                            dirty_q[miss_line_index_q] <= 1'b0;
                            replay_index_q <= 0;
                            state_q <= STATE_ERROR_REPLAY;
                        end else begin
                            if (line_beat_last) begin
                                tag_q[miss_line_index_q] <= miss_tag_q;
                                valid_q[miss_line_index_q] <= 1'b1;
                                dirty_q[miss_line_index_q] <= 1'b0;
                                replace_q[miss_set_q] <=
                                    (miss_way_q == LAST_WAY) ? 0 :
                                    miss_way_q + 1'b1;
                                replay_index_q <= 0;
                                state_q <= STATE_REPLAY_LOAD;
                            end else begin
                                line_beat_q <= line_beat_q + 1'b1;
                                state_q <= STATE_REFILL_REQ;
                            end
                        end
                    end
                end

                STATE_REPLAY_LOAD: state_q <= STATE_REPLAY;

                STATE_REPLAY: begin
                    response_hart_id_q <= merge_hart_id_q[replay_index_q];
                    response_txn_id_q <= merge_txn_id_q[replay_index_q];
                    response_data_q <= 64'd0;
                    response_error_q <= 1'b0;
                    if (merge_op_q[replay_index_q] ==
                        `OPENRV64_CCX_OP_WRITE) begin
                        dirty_q[miss_line_index_q] <= 1'b1;
                    end else begin
                        for (response_byte_index = 0;
                             response_byte_index < 8;
                             response_byte_index = response_byte_index + 1)
                            response_data_q[8*response_byte_index +: 8] <=
                                data_read_q[
                                    8*(replay_array_lane +
                                       response_byte_index) +: 8];
                    end
                    state_q <= STATE_REPLAY_RESP;
                end

                STATE_REPLAY_RESP: begin
                    if (response_fire) begin
                        if (replay_last) begin
                            merge_count_q <= 0;
                            state_q <= STATE_IDLE;
                        end else begin
                            replay_index_q <= replay_index_q + 1'b1;
                            state_q <= STATE_REPLAY_LOAD;
                        end
                    end
                end

                STATE_ERROR_REPLAY: begin
                    response_hart_id_q <= merge_hart_id_q[replay_index_q];
                    response_txn_id_q <= merge_txn_id_q[replay_index_q];
                    response_data_q <= 64'd0;
                    response_error_q <= 1'b1;
                    state_q <= STATE_ERROR_RESP;
                end

                STATE_ERROR_RESP: begin
                    if (response_fire) begin
                        if (replay_last) begin
                            merge_count_q <= 0;
                            state_q <= STATE_IDLE;
                        end else begin
                            replay_index_q <= replay_index_q + 1'b1;
                            state_q <= STATE_ERROR_REPLAY;
                        end
                    end
                end

                STATE_BYPASS_REQ: begin
                    if (bus_request_fire)
                        state_q <= STATE_BYPASS_RESP;
                end

                STATE_BYPASS_RESP: begin
                    if (bus_response_fire) begin
                        if (bus_resp_error_i) begin
                            response_data_q <= 64'd0;
                            response_error_q <= 1'b1;
                            state_q <= STATE_RESPONSE;
                        end else begin
                            if (request_op_q == `OPENRV64_CCX_OP_READ)
                                bypass_read_data_q <= bypass_combined_data;
                            if (bypass_last) begin
                                response_data_q <=
                                    (request_op_q == `OPENRV64_CCX_OP_READ) ?
                                    bypass_combined_data : 64'd0;
                                response_error_q <= 1'b0;
                                state_q <= STATE_RESPONSE;
                            end else begin
                                bypass_beat_q <= bypass_beat_q + 1'b1;
                                state_q <= STATE_BYPASS_REQ;
                            end
                        end
                    end
                end

                STATE_RESPONSE: begin
                    if (response_fire)
                        state_q <= STATE_IDLE;
                end

                default: state_q <= STATE_IDLE;
            endcase
        end
    end

    // The first controller is globally ordered, so these fields do not yet
    // alter scheduling.  They remain explicit at the CCX boundary.
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] unused_req_order = req_order_i;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] unused_req_kind = req_kind_i;

endmodule
