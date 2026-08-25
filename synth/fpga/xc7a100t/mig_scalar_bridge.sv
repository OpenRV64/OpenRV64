// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// One-request blocking 64-bit memory port onto the 256-bit native MIG UI.
// Reads allocate complete native 32-byte beats in a direct-mapped cache.
// Writes remain blocking and write through to MIG; accepting a write
// invalidates the matching cache line.

`timescale 1ns/1ps

module openrv64_fpga_mig_scalar_bridge #(
    parameter logic [63:0] MEMORY_BYTES = 64'h0000_0000_1000_0000,
    parameter integer CACHE_ENABLE = 1,
    parameter integer CACHE_BYTES = 32 * 1024
) (
    input  logic         clk_i,
    input  logic         reset_i,
    input  logic         calib_complete_i,

    input  logic         req_valid_i,
    output logic         req_ready_o,
    input  logic         req_write_i,
    input  logic [63:0]  req_addr_i,
    input  logic [63:0]  req_wdata_i,
    input  logic [7:0]   req_wstrb_i,

    output logic         resp_valid_o,
    input  logic         resp_ready_i,
    output logic [63:0]  resp_rdata_o,
    output logic         resp_error_o,

    output logic [27:0]  app_addr_o,
    output logic [2:0]   app_cmd_o,
    output logic         app_en_o,
    input  logic         app_rdy_i,
    output logic [255:0] app_wdf_data_o,
    output logic         app_wdf_end_o,
    output logic [31:0]  app_wdf_mask_o,
    output logic         app_wdf_wren_o,
    input  logic         app_wdf_rdy_i,
    input  logic [255:0] app_rd_data_i,
    input  logic         app_rd_data_end_i,
    input  logic         app_rd_data_valid_i,

    // Non-intrusive indexed cache inspection. Functional lookups have
    // priority; a debug request waits for the bridge to become idle and then
    // reuses the cache's existing synchronous read port.
    input  logic [9:0]   debug_cache_index_i,
    input  logic         debug_cache_req_toggle_i,
    output logic         debug_cache_ack_toggle_o,
    output logic [9:0]   debug_cache_result_index_o,
    output logic         debug_cache_valid_o,
    output logic [63:0]  debug_cache_tag_o,
    output logic [255:0] debug_cache_data_o
);

    localparam integer CACHE_LINE_BYTES = 32;
    localparam integer CACHE_OFFSET_BITS = 5;
    localparam integer CACHE_LINES = CACHE_BYTES / CACHE_LINE_BYTES;
    localparam integer CACHE_INDEX_BITS = $clog2(CACHE_LINES);
    localparam integer MEMORY_ADDR_BITS = $clog2(MEMORY_BYTES);
    localparam integer CACHE_TAG_BITS = MEMORY_ADDR_BITS -
                                         CACHE_OFFSET_BITS -
                                         CACHE_INDEX_BITS;

    localparam logic [2:0] STATE_CLEAR       = 3'd0;
    localparam logic [2:0] STATE_IDLE        = 3'd1;
    localparam logic [2:0] STATE_CACHE_LOOKUP = 3'd2;
    localparam logic [2:0] STATE_WRITE       = 3'd3;
    localparam logic [2:0] STATE_READ_CMD    = 3'd4;
    localparam logic [2:0] STATE_READ_DATA   = 3'd5;
    localparam logic [2:0] STATE_RESPONSE    = 3'd6;

    logic [2:0] state_q;
    logic [63:0] addr_q;
    logic [63:0] wdata_q;
    logic [7:0] wstrb_q;
    logic command_sent_q;
    logic data_sent_q;
    logic [63:0] response_data_q;
    logic response_error_q;

    (* ram_style = "block" *)
    logic [255:0] cache_data [0:CACHE_LINES-1];
    (* ram_style = "block" *)
    logic [CACHE_TAG_BITS:0] cache_meta [0:CACHE_LINES-1];
    logic [255:0] cache_read_data_q;
    logic [CACHE_TAG_BITS:0] cache_read_meta_q;
    logic [CACHE_INDEX_BITS-1:0] clear_index_q;
    logic cache_meta_write_en;
    logic [CACHE_INDEX_BITS-1:0] cache_meta_write_index;
    logic [CACHE_TAG_BITS:0] cache_meta_write_data;
    (* ASYNC_REG = "TRUE" *) logic debug_req_meta_q;
    (* ASYNC_REG = "TRUE" *) logic debug_req_sync_q;
    logic debug_req_seen_q;
    logic [CACHE_INDEX_BITS-1:0] debug_index_meta_q;
    logic [CACHE_INDEX_BITS-1:0] debug_index_sync_q;
    logic [CACHE_INDEX_BITS-1:0] debug_index_read_q;
    logic debug_read_pending_q;

    wire request_in_range = req_addr_i < MEMORY_BYTES;
    wire [CACHE_INDEX_BITS-1:0] request_cache_index =
        req_addr_i[CACHE_OFFSET_BITS +: CACHE_INDEX_BITS];
    wire [CACHE_INDEX_BITS-1:0] saved_cache_index =
        addr_q[CACHE_OFFSET_BITS +: CACHE_INDEX_BITS];
    wire [CACHE_TAG_BITS-1:0] saved_cache_tag =
        addr_q[MEMORY_ADDR_BITS-1 -: CACHE_TAG_BITS];
    wire cache_hit = (CACHE_ENABLE != 0) &&
                     cache_read_meta_q[CACHE_TAG_BITS] &&
                     (cache_read_meta_q[CACHE_TAG_BITS-1:0] ==
                      saved_cache_tag);
    wire command_fire = app_en_o && app_rdy_i;
    wire data_fire = app_wdf_wren_o && app_wdf_rdy_i;
    wire write_complete = (command_sent_q || command_fire) &&
                          (data_sent_q || data_fire);
    wire cache_lookup_start = (CACHE_ENABLE != 0) &&
                              (state_q == STATE_IDLE) && req_valid_i &&
                              request_in_range && calib_complete_i &&
                              !req_write_i;
    wire debug_cache_lookup_start = (state_q == STATE_IDLE) &&
        !cache_lookup_start && (debug_req_sync_q != debug_req_seen_q);
    wire cache_read_start = cache_lookup_start || debug_cache_lookup_start;
    wire [CACHE_INDEX_BITS-1:0] cache_read_index = cache_lookup_start ?
        request_cache_index : debug_index_sync_q;

    function automatic logic [63:0] select_cache_word(
        input logic [255:0] line,
        input logic [1:0] word_index
    );
        begin
            case (word_index)
                2'd0: select_cache_word = line[63:0];
                2'd1: select_cache_word = line[127:64];
                2'd2: select_cache_word = line[191:128];
                default: select_cache_word = line[255:192];
            endcase
        end
    endfunction

    always_comb begin
        req_ready_o = (state_q == STATE_IDLE);
        resp_valid_o = (state_q == STATE_RESPONSE);
        resp_rdata_o = response_data_q;
        resp_error_o = response_error_q;

        app_addr_o = {addr_q[29:5], 3'b000};
        app_cmd_o = (state_q == STATE_WRITE) ? 3'b000 : 3'b001;
        app_en_o = ((state_q == STATE_WRITE) && !command_sent_q) ||
                   (state_q == STATE_READ_CMD);
        app_wdf_data_o = 256'd0;
        app_wdf_mask_o = 32'hffff_ffff;
        case (addr_q[4:3])
            2'd0: begin
                app_wdf_data_o[63:0] = wdata_q;
                app_wdf_mask_o[7:0] = ~wstrb_q;
            end
            2'd1: begin
                app_wdf_data_o[127:64] = wdata_q;
                app_wdf_mask_o[15:8] = ~wstrb_q;
            end
            2'd2: begin
                app_wdf_data_o[191:128] = wdata_q;
                app_wdf_mask_o[23:16] = ~wstrb_q;
            end
            default: begin
                app_wdf_data_o[255:192] = wdata_q;
                app_wdf_mask_o[31:24] = ~wstrb_q;
            end
        endcase
        app_wdf_wren_o = (state_q == STATE_WRITE) && !data_sent_q;
        app_wdf_end_o = app_wdf_wren_o;
    end

    always_comb begin
        cache_meta_write_en = 1'b0;
        cache_meta_write_index = '0;
        cache_meta_write_data = '0;
        if (state_q == STATE_CLEAR) begin
            cache_meta_write_en = 1'b1;
            cache_meta_write_index = clear_index_q;
        end else if ((CACHE_ENABLE != 0) &&
                     (state_q == STATE_IDLE) && req_valid_i &&
                     request_in_range && calib_complete_i && req_write_i) begin
            cache_meta_write_en = 1'b1;
            cache_meta_write_index = request_cache_index;
        end else if ((CACHE_ENABLE != 0) &&
                     (state_q == STATE_READ_DATA) &&
                     app_rd_data_valid_i && app_rd_data_end_i) begin
            cache_meta_write_en = 1'b1;
            cache_meta_write_index = saved_cache_index;
            cache_meta_write_data = {1'b1, saved_cache_tag};
        end
    end

    // Keep each inferred memory to one synchronous read and one write port.
    // Expressing clear, invalidate and fill as separate procedural writes makes
    // Yosys replicate the tag RAM.
    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            cache_read_data_q <= 256'd0;
            cache_read_meta_q <= '0;
        end else begin
            if (cache_read_start) begin
                cache_read_data_q <= cache_data[cache_read_index];
                cache_read_meta_q <= cache_meta[cache_read_index];
            end
            if ((CACHE_ENABLE != 0) &&
                (state_q == STATE_READ_DATA) && app_rd_data_valid_i &&
                app_rd_data_end_i)
                cache_data[saved_cache_index] <= app_rd_data_i;
            if (cache_meta_write_en)
                cache_meta[cache_meta_write_index] <= cache_meta_write_data;
        end
    end

    // The index is stable before the request toggle changes. Synchronizing it
    // as a bus is sufficient for this manually paced debug interface; the
    // double-flopped toggle establishes when the synchronized index is used.
    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            debug_req_meta_q <= 1'b0;
            debug_req_sync_q <= 1'b0;
            debug_req_seen_q <= 1'b0;
            debug_index_meta_q <= '0;
            debug_index_sync_q <= '0;
            debug_index_read_q <= '0;
            debug_read_pending_q <= 1'b0;
            debug_cache_ack_toggle_o <= 1'b0;
            debug_cache_result_index_o <= 10'd0;
            debug_cache_valid_o <= 1'b0;
            debug_cache_tag_o <= 64'd0;
            debug_cache_data_o <= 256'd0;
        end else begin
            debug_req_meta_q <= debug_cache_req_toggle_i;
            debug_req_sync_q <= debug_req_meta_q;
            debug_index_meta_q <= debug_cache_index_i[CACHE_INDEX_BITS-1:0];
            debug_index_sync_q <= debug_index_meta_q;

            if (debug_cache_lookup_start) begin
                debug_req_seen_q <= debug_req_sync_q;
                debug_index_read_q <= debug_index_sync_q;
                debug_read_pending_q <= 1'b1;
            end else if (debug_read_pending_q) begin
                debug_read_pending_q <= 1'b0;
                debug_cache_ack_toggle_o <= debug_req_seen_q;
                debug_cache_result_index_o <=
                    {{(10-CACHE_INDEX_BITS){1'b0}}, debug_index_read_q};
                debug_cache_valid_o <= cache_read_meta_q[CACHE_TAG_BITS];
                debug_cache_tag_o <=
                    {{(64-CACHE_TAG_BITS){1'b0}},
                     cache_read_meta_q[CACHE_TAG_BITS-1:0]};
                debug_cache_data_o <= cache_read_data_q;
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            state_q <= (CACHE_ENABLE != 0) ? STATE_CLEAR : STATE_IDLE;
            addr_q <= 64'd0;
            wdata_q <= 64'd0;
            wstrb_q <= 8'd0;
            command_sent_q <= 1'b0;
            data_sent_q <= 1'b0;
            response_data_q <= 64'd0;
            response_error_q <= 1'b0;
            clear_index_q <= '0;
        end else begin
            case (state_q)
                STATE_CLEAR: begin
                    if (clear_index_q == CACHE_LINES - 1) begin
                        clear_index_q <= '0;
                        state_q <= STATE_IDLE;
                    end else begin
                        clear_index_q <= clear_index_q + 1'b1;
                    end
                end

                STATE_IDLE: begin
                    command_sent_q <= 1'b0;
                    data_sent_q <= 1'b0;
                    if (req_valid_i) begin
                        addr_q <= req_addr_i;
                        wdata_q <= req_wdata_i;
                        wstrb_q <= req_wstrb_i;
                        response_data_q <= 64'd0;
                        response_error_q <= 1'b0;
                        if (!request_in_range || !calib_complete_i) begin
                            response_error_q <= 1'b1;
                            state_q <= STATE_RESPONSE;
                        end else if (req_write_i) begin
                            state_q <= STATE_WRITE;
                        end else if (CACHE_ENABLE != 0) begin
                            state_q <= STATE_CACHE_LOOKUP;
                        end else begin
                            state_q <= STATE_READ_CMD;
                        end
                    end
                end

                STATE_CACHE_LOOKUP: begin
                    if (!calib_complete_i) begin
                        response_error_q <= 1'b1;
                        state_q <= STATE_RESPONSE;
                    end else if (cache_hit) begin
                        response_data_q <=
                            select_cache_word(cache_read_data_q,
                                              addr_q[4:3]);
                        state_q <= STATE_RESPONSE;
                    end else begin
                        state_q <= STATE_READ_CMD;
                    end
                end

                STATE_WRITE: begin
                    if (!calib_complete_i) begin
                        response_error_q <= 1'b1;
                        state_q <= STATE_RESPONSE;
                    end else if (write_complete) begin
                        command_sent_q <= 1'b0;
                        data_sent_q <= 1'b0;
                        state_q <= STATE_RESPONSE;
                    end else begin
                        if (command_fire)
                            command_sent_q <= 1'b1;
                        if (data_fire)
                            data_sent_q <= 1'b1;
                    end
                end

                STATE_READ_CMD: begin
                    if (!calib_complete_i) begin
                        response_error_q <= 1'b1;
                        state_q <= STATE_RESPONSE;
                    end else if (command_fire) begin
                        state_q <= STATE_READ_DATA;
                    end
                end

                STATE_READ_DATA: begin
                    if (!calib_complete_i) begin
                        response_error_q <= 1'b1;
                        state_q <= STATE_RESPONSE;
                    end else if (app_rd_data_valid_i) begin
                        response_data_q <=
                            select_cache_word(app_rd_data_i, addr_q[4:3]);
                        response_error_q <= !app_rd_data_end_i;
                        state_q <= STATE_RESPONSE;
                    end
                end

                STATE_RESPONSE: begin
                    if (resp_ready_i)
                        state_q <= STATE_IDLE;
                end

                default: state_q <= STATE_CLEAR;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (CACHE_ENABLE != 0 && CACHE_ENABLE != 1)
            $fatal(1, "CACHE_ENABLE must be 0 or 1");
        if (CACHE_BYTES < 2 * CACHE_LINE_BYTES)
            $fatal(1, "CACHE_BYTES must contain at least two cache lines");
        if ((CACHE_BYTES % CACHE_LINE_BYTES) != 0 ||
            (CACHE_LINES & (CACHE_LINES - 1)) != 0)
            $fatal(1, "CACHE_BYTES must be a power-of-two line count");
        if (CACHE_TAG_BITS <= 0)
            $fatal(1, "cache must be smaller than MEMORY_BYTES");
    end
`endif

endmodule
