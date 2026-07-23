`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/fetch/fetch-defs.v"
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

// Three-wide frontend for the 256-bit AXI fetch path.
//
// Fetch consumes one 256-bit block at a time and keeps only the immediately
// following block requested for architectural demand.  A conditional-branch
// hint may additionally launch two ordinary requests, predicted side first,
// with a qualifier asking that their responses be retained in a two-entry
// redirect stash.  L1I still owns cache residency and refill concurrency.
module openrv64_fetch_3w #(
    parameter integer LINE_DEPTH = 2,
    parameter integer ENABLE_TRACE = 0,
    parameter integer ENABLE_PREDECODE_TARGETS = 1,
    parameter integer ENABLE_ALT_LOOKASIDE = 0,
    parameter integer BRANCH_PAIR_STACK_DEPTH = 2,
    parameter integer LINE_INDEX_WIDTH = $clog2(LINE_DEPTH),
    parameter integer LINE_COUNT_WIDTH = $clog2(LINE_DEPTH + 1),
    parameter integer PAIR_STACK_COUNT_WIDTH =
        $clog2(BRANCH_PAIR_STACK_DEPTH + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         restart_i,
    input  wire [`RV64_XLEN-1:0]        restart_pc_i,
    input  wire                         invalidate_i,
    input  wire                         stall_i,
    input  wire                         flush_i,
    output wire                         cancel_o,
    output wire                         cancel_stash_o,

    output wire                         req_valid_o,
    input  wire                         req_ready_i,
    output wire [`RV64_XLEN-1:0]        req_addr_o,
    output wire                         req_stash_o,
    output wire                         req_demand_o,
    input  wire                         resp_valid_i,
    output wire                         resp_ready_o,
    input  wire [`RV64_XLEN-1:0]        resp_addr_i,
    input  wire [`OPENRV64_AXI_DATA_WIDTH-1:0] resp_data_i,
    input  wire                         resp_access_fault_i,
    input  wire                         resp_page_fault_i,
    input  wire                         resp_stash_i,
    input  wire                         resp_demand_i,

    input  wire                         branch_pair_valid_i,
    input  wire [`RV64_XLEN-1:0]        branch_predicted_addr_i,
    input  wire [`RV64_XLEN-1:0]        branch_unpredicted_addr_i,

    // Experimental mode 4 models a dual-address 512-bit L1I return: one
    // 256-bit fetch block from each branch side in a single transaction.
    output wire                         pair512_req_valid_o,
    input  wire                         pair512_req_ready_i,
    output wire [`RV64_XLEN-1:0]        pair512_req_predicted_addr_o,
    output wire [`RV64_XLEN-1:0]        pair512_req_unpredicted_addr_o,
    input  wire                         pair512_resp_valid_i,
    input  wire [`RV64_XLEN-1:0]        pair512_resp_predicted_addr_i,
    input  wire [`OPENRV64_AXI_DATA_WIDTH-1:0]
                                            pair512_resp_predicted_data_i,
    input  wire [`RV64_XLEN-1:0]        pair512_resp_unpredicted_addr_i,
    input  wire [`OPENRV64_AXI_DATA_WIDTH-1:0]
                                            pair512_resp_unpredicted_data_i,

    // Experimental mode 5 returns two complete 512-bit cache lines in one
    // dual-address transaction and installs both blocks of the selected line.
    output wire                         pair1024_req_valid_o,
    input  wire                         pair1024_req_ready_i,
    output wire [`RV64_XLEN-1:0]        pair1024_req_predicted_addr_o,
    output wire [`RV64_XLEN-1:0]        pair1024_req_unpredicted_addr_o,
    input  wire                         pair1024_resp_valid_i,
    input  wire [`RV64_XLEN-1:0]        pair1024_resp_predicted_addr_i,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                            pair1024_resp_predicted_data_i,
    input  wire [`RV64_XLEN-1:0]        pair1024_resp_unpredicted_addr_i,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                            pair1024_resp_unpredicted_data_i,

    // Retirement ages the unchosen 64-byte L1I line.  Apply the same policy
    // to the two 256-bit fetch-path stash entries.
    input  wire [2:0]                   prefetch_age_valid_i,
    input  wire [3*`RV64_XLEN-1:0]      prefetch_age_addr_i,
    input  wire                         alt_restart_eligible_i,

    output wire [2:0]                   decode_valid_o,
    input  wire [2:0]                   decode_ready_i,
    output wire [3*`RV64_FETCH_DECODE_BUS_WIDTH-1:0] decode_bus_o,
    input  wire [63:0]                  trace_id_i,
    output wire [3*64-1:0]              trace_id_o,

    output wire [`RV64_XLEN-1:0]        stream_pc_o,
    output wire [LINE_COUNT_WIDTH-1:0]  line_count_o,
    output wire                         alt_restart_hit_o
);

    localparam integer LINE_BYTES = `OPENRV64_AXI_DATA_WIDTH / 8;
    localparam integer LINE_BYTE_BITS = $clog2(LINE_BYTES);
    localparam integer ALT_LOOKASIDE_LINES = 2;
    localparam integer ALT_SECTOR_BYTES = 16;
    localparam integer ALT_SECTOR_BYTE_BITS = $clog2(ALT_SECTOR_BYTES);
    localparam integer CACHE_LINE_BYTES =
        `OPENRV64_CCX_LINE_DATA_WIDTH / 8;
    localparam integer CACHE_LINE_BYTE_BITS = $clog2(CACHE_LINE_BYTES);
    localparam integer ALT_PREVIEW_BYTES =
        (ENABLE_ALT_LOOKASIDE == 5) ? CACHE_LINE_BYTES :
        (ENABLE_ALT_LOOKASIDE == 4) ? LINE_BYTES : ALT_SECTOR_BYTES;
    localparam integer ALT_PREVIEW_BITS = ALT_PREVIEW_BYTES * 8;
    localparam integer ALT_PREVIEW_BYTE_BITS = $clog2(ALT_PREVIEW_BYTES);
    localparam integer ALT_SECTOR_CONTEXTS = BRANCH_PAIR_STACK_DEPTH;
    localparam integer ALT_SECTOR_CONTEXT_INDEX_WIDTH =
        (ALT_SECTOR_CONTEXTS > 1) ?
            $clog2(ALT_SECTOR_CONTEXTS) : 1;

    reg active_q;
    reg [`RV64_XLEN-1:0] consume_pc_q;
    reg line_valid_q [0:LINE_DEPTH-1];
    reg [`RV64_XLEN-1:0] line_addr_q [0:LINE_DEPTH-1];
    reg [`OPENRV64_AXI_DATA_WIDTH-1:0] line_data_q [0:LINE_DEPTH-1];
    reg [1:0] line_sector_valid_q [0:LINE_DEPTH-1];
    reg line_access_fault_q [0:LINE_DEPTH-1];
    reg line_page_fault_q [0:LINE_DEPTH-1];
    reg pending_valid_q;
    reg [`RV64_XLEN-1:0] pending_addr_q;

    reg pair_predicted_valid_q;
    reg pair_unpredicted_valid_q;
    reg [`RV64_XLEN-1:0] pair_predicted_addr_q;
    reg [`RV64_XLEN-1:0] pair_unpredicted_addr_q;

    reg alt_valid_q [0:ALT_LOOKASIDE_LINES-1];
    reg [`RV64_XLEN-1:0] alt_addr_q [0:ALT_LOOKASIDE_LINES-1];
    reg [`OPENRV64_AXI_DATA_WIDTH-1:0]
        alt_data_q [0:ALT_LOOKASIDE_LINES-1];
    reg alt_replace_q;

    // FAL mode 3 keeps a 128-bit preview for each branch side.  Experimental
    // modes 4/5 widen each side to a 256-bit block or complete 512-bit line.
    reg alt_sector_context_valid_q [0:ALT_SECTOR_CONTEXTS-1];
    reg [`RV64_XLEN-1:0]
        alt_sector_predicted_addr_q [0:ALT_SECTOR_CONTEXTS-1];
    reg [`RV64_XLEN-1:0]
        alt_sector_unpredicted_addr_q [0:ALT_SECTOR_CONTEXTS-1];
    reg alt_sector_predicted_valid_q [0:ALT_SECTOR_CONTEXTS-1];
    reg alt_sector_unpredicted_valid_q [0:ALT_SECTOR_CONTEXTS-1];
    reg [ALT_PREVIEW_BITS-1:0]
        alt_sector_predicted_data_q [0:ALT_SECTOR_CONTEXTS-1];
    reg [ALT_PREVIEW_BITS-1:0]
        alt_sector_unpredicted_data_q [0:ALT_SECTOR_CONTEXTS-1];
    reg [ALT_SECTOR_CONTEXT_INDEX_WIDTH-1:0]
        alt_sector_replace_q;

    reg branch_predicted_stashed_r;
    reg branch_unpredicted_stashed_r;
    reg branch_sector_context_match_r;
    reg branch_predicted_sector_source_valid_r;
    reg branch_unpredicted_sector_source_valid_r;
    reg [ALT_PREVIEW_BITS-1:0] branch_predicted_sector_source_data_r;
    reg [ALT_PREVIEW_BITS-1:0] branch_unpredicted_sector_source_data_r;
    reg alt_prefetch_aged_r;
    integer branch_stash_index;
    integer branch_sector_index;
    integer branch_line_index;

    function automatic [ALT_PREVIEW_BITS-1:0] select_preview;
        input [`OPENRV64_AXI_DATA_WIDTH-1:0] data;
        input [`RV64_XLEN-1:0] addr;
        begin
            if (ENABLE_ALT_LOOKASIDE == 5)
                select_preview = {ALT_PREVIEW_BITS{1'b0}};
            else if (ENABLE_ALT_LOOKASIDE == 4)
                select_preview = data;
            else if (addr[ALT_SECTOR_BYTE_BITS])
                select_preview = data[255:128];
            else
                select_preview = data[127:0];
        end
    endfunction

    function automatic [`OPENRV64_AXI_DATA_WIDTH-1:0]
        select_cache_line_block;
        input [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] data;
        input [`RV64_XLEN-1:0] addr;
        begin
            if (addr[LINE_BYTE_BITS])
                select_cache_line_block = data[511:256];
            else
                select_cache_line_block = data[255:0];
        end
    endfunction

    always @* begin
        branch_predicted_stashed_r = 1'b0;
        branch_unpredicted_stashed_r = 1'b0;
        branch_sector_context_match_r = 1'b0;
        branch_predicted_sector_source_valid_r = 1'b0;
        branch_unpredicted_sector_source_valid_r = 1'b0;
        branch_predicted_sector_source_data_r =
            {ALT_PREVIEW_BITS{1'b0}};
        branch_unpredicted_sector_source_data_r =
            {ALT_PREVIEW_BITS{1'b0}};

        if (ENABLE_ALT_LOOKASIDE < 3) begin
            for (branch_stash_index = 0;
                 branch_stash_index < ALT_LOOKASIDE_LINES;
                 branch_stash_index = branch_stash_index + 1) begin
                if (alt_valid_q[branch_stash_index] &&
                    (alt_addr_q[branch_stash_index][
                        `RV64_XLEN-1:LINE_BYTE_BITS] ==
                     branch_predicted_addr_i[
                        `RV64_XLEN-1:LINE_BYTE_BITS]))
                    branch_predicted_stashed_r = 1'b1;
                if (alt_valid_q[branch_stash_index] &&
                    (alt_addr_q[branch_stash_index][
                        `RV64_XLEN-1:LINE_BYTE_BITS] ==
                     branch_unpredicted_addr_i[
                        `RV64_XLEN-1:LINE_BYTE_BITS]))
                    branch_unpredicted_stashed_r = 1'b1;
            end
        end else begin
            for (branch_sector_index = 0;
                 branch_sector_index < ALT_SECTOR_CONTEXTS;
                 branch_sector_index = branch_sector_index + 1) begin
                if (alt_sector_context_valid_q[branch_sector_index] &&
                    (alt_sector_predicted_addr_q[branch_sector_index][
                        `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS] ==
                     branch_predicted_addr_i[
                        `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS]) &&
                    (alt_sector_unpredicted_addr_q[branch_sector_index][
                        `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS] ==
                     branch_unpredicted_addr_i[
                        `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS]))
                    branch_sector_context_match_r = 1'b1;

                if (alt_sector_context_valid_q[branch_sector_index] &&
                    alt_sector_predicted_valid_q[branch_sector_index] &&
                    (alt_sector_predicted_addr_q[branch_sector_index][
                        `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS] ==
                     branch_predicted_addr_i[
                        `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS])) begin
                    branch_predicted_sector_source_valid_r = 1'b1;
                    branch_predicted_sector_source_data_r =
                        alt_sector_predicted_data_q[branch_sector_index];
                end
                if (alt_sector_context_valid_q[branch_sector_index] &&
                    alt_sector_unpredicted_valid_q[branch_sector_index] &&
                    (alt_sector_unpredicted_addr_q[branch_sector_index][
                        `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS] ==
                     branch_unpredicted_addr_i[
                        `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS])) begin
                    branch_unpredicted_sector_source_valid_r = 1'b1;
                    branch_unpredicted_sector_source_data_r =
                        alt_sector_unpredicted_data_q[branch_sector_index];
                end
            end

            // Reuse any fetch-resident sector.  This includes the line which
            // contained the allocating branch and the one-block lookahead.
            for (branch_line_index = 0;
                 branch_line_index < LINE_DEPTH;
                 branch_line_index = branch_line_index + 1) begin
                if (line_valid_q[branch_line_index] &&
                    (line_addr_q[branch_line_index][
                        `RV64_XLEN-1:LINE_BYTE_BITS] ==
                     branch_predicted_addr_i[
                        `RV64_XLEN-1:LINE_BYTE_BITS]) &&
                    (((ENABLE_ALT_LOOKASIDE == 4) &&
                      (&line_sector_valid_q[branch_line_index])) ||
                     ((ENABLE_ALT_LOOKASIDE == 3) &&
                      line_sector_valid_q[branch_line_index][
                        branch_predicted_addr_i[
                            ALT_SECTOR_BYTE_BITS]]))) begin
                    branch_predicted_sector_source_valid_r = 1'b1;
                    branch_predicted_sector_source_data_r =
                        select_preview(
                            line_data_q[branch_line_index],
                            branch_predicted_addr_i);
                end
                if (line_valid_q[branch_line_index] &&
                    (line_addr_q[branch_line_index][
                        `RV64_XLEN-1:LINE_BYTE_BITS] ==
                     branch_unpredicted_addr_i[
                        `RV64_XLEN-1:LINE_BYTE_BITS]) &&
                    (((ENABLE_ALT_LOOKASIDE == 4) &&
                      (&line_sector_valid_q[branch_line_index])) ||
                     ((ENABLE_ALT_LOOKASIDE == 3) &&
                      line_sector_valid_q[branch_line_index][
                        branch_unpredicted_addr_i[
                            ALT_SECTOR_BYTE_BITS]]))) begin
                    branch_unpredicted_sector_source_valid_r = 1'b1;
                    branch_unpredicted_sector_source_data_r =
                        select_preview(
                            line_data_q[branch_line_index],
                            branch_unpredicted_addr_i);
                end
            end

            // A response coincident with allocation is another free source.
            if ((ENABLE_ALT_LOOKASIDE != 5) &&
                resp_valid_i && !resp_access_fault_i &&
                !resp_page_fault_i &&
                (resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS] ==
                 branch_predicted_addr_i[
                    `RV64_XLEN-1:LINE_BYTE_BITS])) begin
                branch_predicted_sector_source_valid_r = 1'b1;
                branch_predicted_sector_source_data_r =
                    select_preview(resp_data_i,
                                   branch_predicted_addr_i);
            end
            if ((ENABLE_ALT_LOOKASIDE != 5) &&
                resp_valid_i && !resp_access_fault_i &&
                !resp_page_fault_i &&
                (resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS] ==
                 branch_unpredicted_addr_i[
                    `RV64_XLEN-1:LINE_BYTE_BITS])) begin
                branch_unpredicted_sector_source_valid_r = 1'b1;
                branch_unpredicted_sector_source_data_r =
                    select_preview(resp_data_i,
                                   branch_unpredicted_addr_i);
            end

            // Both sides of a same-sector branch use the same preview.
            if (branch_predicted_addr_i[
                    `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS] ==
                branch_unpredicted_addr_i[
                    `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS]) begin
                if (branch_predicted_sector_source_valid_r) begin
                    branch_unpredicted_sector_source_valid_r = 1'b1;
                    branch_unpredicted_sector_source_data_r =
                        branch_predicted_sector_source_data_r;
                end else if (branch_unpredicted_sector_source_valid_r) begin
                    branch_predicted_sector_source_valid_r = 1'b1;
                    branch_predicted_sector_source_data_r =
                        branch_unpredicted_sector_source_data_r;
                end
            end

            branch_predicted_stashed_r =
                branch_predicted_sector_source_valid_r;
            branch_unpredicted_stashed_r =
                branch_unpredicted_sector_source_valid_r;
        end
    end

    reg alt_sector_response_tap_r;
    reg alt_sector_predicted_tap_r;
    reg alt_sector_unpredicted_tap_r;
    integer alt_sector_tap_index;
    always @* begin
        alt_sector_response_tap_r = 1'b0;
        alt_sector_predicted_tap_r = 1'b0;
        alt_sector_unpredicted_tap_r = 1'b0;
        if ((ENABLE_ALT_LOOKASIDE >= 3) &&
            (ENABLE_ALT_LOOKASIDE != 5) && resp_valid_i &&
            !resp_access_fault_i && !resp_page_fault_i &&
            !alt_prefetch_aged_r) begin
            for (alt_sector_tap_index = 0;
                 alt_sector_tap_index < ALT_SECTOR_CONTEXTS;
                 alt_sector_tap_index = alt_sector_tap_index + 1) begin
                if (alt_sector_context_valid_q[alt_sector_tap_index] &&
                    (alt_sector_predicted_addr_q[
                        alt_sector_tap_index][
                            `RV64_XLEN-1:LINE_BYTE_BITS] ==
                     resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS])) begin
                    alt_sector_response_tap_r = 1'b1;
                    alt_sector_predicted_tap_r = 1'b1;
                end
                if (alt_sector_context_valid_q[alt_sector_tap_index] &&
                    (alt_sector_unpredicted_addr_q[
                        alt_sector_tap_index][
                            `RV64_XLEN-1:LINE_BYTE_BITS] ==
                     resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS])) begin
                    alt_sector_response_tap_r = 1'b1;
                    alt_sector_unpredicted_tap_r = 1'b1;
                end
            end
        end
    end

    assign pair512_req_valid_o = (ENABLE_ALT_LOOKASIDE == 4) &&
        branch_pair_valid_i && !branch_sector_context_match_r &&
        !(branch_predicted_sector_source_valid_r &&
          branch_unpredicted_sector_source_valid_r);
    assign pair512_req_predicted_addr_o = {
        branch_predicted_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS],
        {LINE_BYTE_BITS{1'b0}}
    };
    assign pair512_req_unpredicted_addr_o = {
        branch_unpredicted_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS],
        {LINE_BYTE_BITS{1'b0}}
    };
    assign pair1024_req_valid_o = (ENABLE_ALT_LOOKASIDE == 5) &&
        branch_pair_valid_i && !branch_sector_context_match_r &&
        !(branch_predicted_sector_source_valid_r &&
          branch_unpredicted_sector_source_valid_r);
    assign pair1024_req_predicted_addr_o = {
        branch_predicted_addr_i[`RV64_XLEN-1:CACHE_LINE_BYTE_BITS],
        {CACHE_LINE_BYTE_BITS{1'b0}}
    };
    assign pair1024_req_unpredicted_addr_o = {
        branch_unpredicted_addr_i[`RV64_XLEN-1:CACHE_LINE_BYTE_BITS],
        {CACHE_LINE_BYTE_BITS{1'b0}}
    };
    assign cancel_o = restart_i || invalidate_i || flush_i;
    assign cancel_stash_o = invalidate_i || flush_i;
    assign resp_ready_o = 1'b1;
    assign stream_pc_o = consume_pc_q;

    localparam integer LINE_INDEX_LSB = LINE_BYTE_BITS;
    localparam integer LINE_INDEX_MSB = LINE_BYTE_BITS + LINE_INDEX_WIDTH - 1;

    wire [`RV64_XLEN-1:0] consume_line_addr = {
        consume_pc_q[`RV64_XLEN-1:LINE_BYTE_BITS],
        {LINE_BYTE_BITS{1'b0}}
    };
    wire [LINE_INDEX_WIDTH-1:0] consume_slot =
        consume_line_addr[LINE_INDEX_MSB:LINE_INDEX_LSB];
    wire [`RV64_XLEN-1:0] following_line_addr =
        consume_line_addr + LINE_BYTES;
    wire [LINE_INDEX_WIDTH-1:0] following_slot =
        following_line_addr[LINE_INDEX_MSB:LINE_INDEX_LSB];
    wire consume_line_tag_hit = line_valid_q[consume_slot] &&
        (line_addr_q[consume_slot][`RV64_XLEN-1:LINE_BYTE_BITS] ==
         consume_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire following_line_tag_hit = line_valid_q[following_slot] &&
        (line_addr_q[following_slot][`RV64_XLEN-1:LINE_BYTE_BITS] ==
         following_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire consume_line_hit = consume_line_tag_hit &&
        line_sector_valid_q[consume_slot][
            consume_pc_q[ALT_SECTOR_BYTE_BITS]];
    wire following_line_hit = following_line_tag_hit &&
        line_sector_valid_q[following_slot][0];
    wire consume_line_full = consume_line_tag_hit &&
                             (&line_sector_valid_q[consume_slot]);
    wire following_line_full = following_line_tag_hit &&
                               (&line_sector_valid_q[following_slot]);

    // Demand the current line first.  Once it is resident, request exactly
    // the following line and stop there until consumption crosses the line.
    // L1I may satisfy either request as a hit and later owns any deeper
    // prefetching or multiple-refill policy.
    wire request_current_line = !consume_line_full;
    wire [`RV64_XLEN-1:0] request_line_addr = request_current_line ?
        consume_line_addr : following_line_addr;
    wire request_line_hit = request_current_line ? consume_line_full :
                                                   following_line_full;
    wire pair_request_valid = pair_predicted_valid_q ||
                              pair_unpredicted_valid_q;
    wire [`RV64_XLEN-1:0] pair_request_addr =
        pair_predicted_valid_q ? pair_predicted_addr_q :
                                 pair_unpredicted_addr_q;
    wire pair_request_is_demand = pair_request_valid &&
        !pending_valid_q && !request_line_hit &&
        (pair_request_addr[`RV64_XLEN-1:LINE_BYTE_BITS] ==
         request_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire demand_request_needed = !pending_valid_q &&
                                 !request_line_hit;
    wire pair_request_select = pair_request_valid &&
        ((ENABLE_ALT_LOOKASIDE < 3) || !demand_request_needed ||
         pair_request_is_demand);
    wire demand_request_valid = !pair_request_select &&
                                demand_request_needed;
    assign req_valid_o = active_q && !restart_i && !invalidate_i &&
                         !flush_i && !stall_i &&
                         (pair_request_select || demand_request_valid);
    assign req_addr_o = pair_request_select ? pair_request_addr :
                                             request_line_addr;
    assign req_stash_o = pair_request_select;
    assign req_demand_o = !pair_request_select ||
                          pair_request_is_demand;
    wire req_fire = req_valid_o && req_ready_i;
    wire pair_req_fire = req_fire && pair_request_select;
    wire alt_sector_background_deferred =
        (ENABLE_ALT_LOOKASIDE == 3) && pair_request_valid &&
        demand_request_needed && !pair_request_is_demand;
    wire pair_predicted_after_fire = pair_predicted_valid_q &&
        !(pair_req_fire && pair_predicted_valid_q);
    wire pair_unpredicted_after_fire = pair_unpredicted_valid_q &&
        !(pair_req_fire && !pair_predicted_valid_q &&
          pair_unpredicted_valid_q);
    wire pair_remains_after_fire = pair_predicted_after_fire ||
                                   pair_unpredicted_after_fire;
    assign line_count_o =
        {{(LINE_COUNT_WIDTH-1){1'b0}}, consume_line_hit} +
        {{(LINE_COUNT_WIDTH-1){1'b0}}, following_line_hit} +
        {{(LINE_COUNT_WIDTH-1){1'b0}}, pending_valid_q};

    reg [2:0] lane_found_r;
    reg [3*`RV64_INSTR_WIDTH-1:0] lane_instr_r;
    reg [2:0] lane_access_fault_r;
    reg [2:0] lane_page_fault_r;
    reg [`RV64_XLEN-1:0] lane_pc_r [0:2];
    integer lane_index;
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] consume_line_data =
        line_data_q[consume_slot];
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] following_line_data =
        line_data_q[following_slot];
    always @* begin
        lane_found_r = 3'b000;
        lane_instr_r = {3*`RV64_INSTR_WIDTH{1'b0}};
        lane_access_fault_r = 3'b000;
        lane_page_fault_r = 3'b000;
        for (lane_index = 0; lane_index < 3;
            lane_index = lane_index + 1) begin
            lane_pc_r[lane_index] = consume_pc_q + (lane_index * 4);
            if ((lane_pc_r[lane_index][`RV64_XLEN-1:LINE_BYTE_BITS] ==
                 consume_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS]) &&
                consume_line_tag_hit &&
                line_sector_valid_q[consume_slot][
                    lane_pc_r[lane_index][ALT_SECTOR_BYTE_BITS]]) begin
                lane_found_r[lane_index] = 1'b1;
                lane_instr_r[lane_index*`RV64_INSTR_WIDTH +:
                             `RV64_INSTR_WIDTH] =
                    (line_access_fault_q[consume_slot] ||
                     line_page_fault_q[consume_slot]) ?
                    `RV64_INSTR_NOP : consume_line_data[
                        lane_pc_r[lane_index][LINE_BYTE_BITS-1:2] *
                        `RV64_INSTR_WIDTH +: `RV64_INSTR_WIDTH];
                lane_access_fault_r[lane_index] =
                    line_access_fault_q[consume_slot];
                lane_page_fault_r[lane_index] =
                    line_page_fault_q[consume_slot];
            end else if ((lane_pc_r[lane_index][
                           `RV64_XLEN-1:LINE_BYTE_BITS] ==
                          following_line_addr[
                           `RV64_XLEN-1:LINE_BYTE_BITS]) &&
                         following_line_tag_hit &&
                         line_sector_valid_q[following_slot][
                            lane_pc_r[lane_index][
                                ALT_SECTOR_BYTE_BITS]]) begin
                lane_found_r[lane_index] = 1'b1;
                lane_instr_r[lane_index*`RV64_INSTR_WIDTH +:
                             `RV64_INSTR_WIDTH] =
                    (line_access_fault_q[following_slot] ||
                     line_page_fault_q[following_slot]) ?
                    `RV64_INSTR_NOP : following_line_data[
                        lane_pc_r[lane_index][LINE_BYTE_BITS-1:2] *
                        `RV64_INSTR_WIDTH +: `RV64_INSTR_WIDTH];
                lane_access_fault_r[lane_index] =
                    line_access_fault_q[following_slot];
                lane_page_fault_r[lane_index] =
                    line_page_fault_q[following_slot];
            end
        end
    end

    // A predicted redirect may be generated by the instruction currently on
    // this interface.  Keep that bundle valid during restart_i; the restart
    // wins the sequential state update at the edge after the bundle is
    // accepted.  Top-level ready masking suppresses stale acceptance for
    // execute-time redirects and context changes.
    assign decode_valid_o[0] = active_q && !flush_i && lane_found_r[0];
    assign decode_valid_o[1] = decode_valid_o[0] && lane_found_r[1];
    assign decode_valid_o[2] = decode_valid_o[1] && lane_found_r[2];
    wire decode_fire0 = decode_valid_o[0] && decode_ready_i[0];
    wire decode_fire1 = decode_valid_o[1] && decode_fire0 &&
                        decode_ready_i[1];
    wire decode_fire2 = decode_valid_o[2] && decode_fire1 &&
                        decode_ready_i[2];
    wire [1:0] decode_count = {1'b0, decode_fire0} +
                              {1'b0, decode_fire1} +
                              {1'b0, decode_fire2};
    wire [`RV64_XLEN-1:0] next_consume_pc =
        consume_pc_q + ({62'd0, decode_count} << 2);

    function automatic direct_control_valid;
        input [`RV64_INSTR_WIDTH-1:0] instr;
        begin
            direct_control_valid = 1'b0;
            case (`RV64_OPCODE(instr))
                `RV64_OPCODE_JAL: direct_control_valid = 1'b1;
                `RV64_OPCODE_BRANCH: begin
                    case (`RV64_FUNCT3(instr))
                        `RV64_FUNCT3_BEQ,
                        `RV64_FUNCT3_BNE,
                        `RV64_FUNCT3_BLT,
                        `RV64_FUNCT3_BGE,
                        `RV64_FUNCT3_BLTU,
                        `RV64_FUNCT3_BGEU:
                            direct_control_valid = 1'b1;
                        default: begin
                        end
                    endcase
                end
                default: begin
                end
            endcase
        end
    endfunction

    genvar output_lane;
    generate
        for (output_lane = 0; output_lane < 3;
             output_lane = output_lane + 1) begin : g_decode_output
            wire [`RV64_INSTR_WIDTH-1:0] lane_instr = lane_instr_r[
                output_lane*`RV64_INSTR_WIDTH +: `RV64_INSTR_WIDTH];
            wire direct_valid = ENABLE_PREDECODE_TARGETS &&
                                direct_control_valid(lane_instr);
            wire direct_conditional = direct_valid &&
                (`RV64_OPCODE(lane_instr) == `RV64_OPCODE_BRANCH);
            wire [`RV64_XLEN-1:0] direct_imm =
                (`RV64_OPCODE(lane_instr) == `RV64_OPCODE_JAL) ?
                `RV64_IMM_J(lane_instr) : `RV64_IMM_B(lane_instr);
            assign decode_bus_o[
                output_lane*`RV64_FETCH_DECODE_BUS_WIDTH +:
                `RV64_FETCH_DECODE_BUS_WIDTH] = {
                direct_conditional,
                direct_valid,
                direct_valid ? direct_imm[20:1] : 20'd0,
                lane_page_fault_r[output_lane],
                lane_access_fault_r[output_lane],
                lane_pc_r[output_lane],
                lane_instr
            };
            assign trace_id_o[output_lane*64 +: 64] = ENABLE_TRACE ?
                trace_id_i + output_lane : 64'd0;
        end
    endgenerate

    wire [LINE_INDEX_WIDTH-1:0] resp_slot =
        resp_addr_i[LINE_INDEX_MSB:LINE_INDEX_LSB];
    wire resp_match = resp_demand_i && pending_valid_q &&
        (pending_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS] ==
         resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS]);

    reg alt_restart_hit_r;
    reg [`OPENRV64_AXI_DATA_WIDTH-1:0] alt_restart_data_r;
    reg alt_restart_cache_line_valid_r;
    reg [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
        alt_restart_cache_line_data_r;
    reg [1:0] alt_restart_sector_mask_r;
    reg alt_fill_match_r;
    reg alt_fill_slot_r;
    reg alt_free_found_r;
    integer alt_index;
    integer alt_age_port;
    always @* begin
        alt_prefetch_aged_r = 1'b0;
        for (alt_age_port = 0; alt_age_port < 3;
             alt_age_port = alt_age_port + 1) begin
            if (prefetch_age_valid_i[alt_age_port] &&
                (prefetch_age_addr_i[
                    alt_age_port*`RV64_XLEN + 6 +:
                    `RV64_XLEN-6] ==
                 resp_addr_i[6 +: `RV64_XLEN-6]))
                alt_prefetch_aged_r = 1'b1;
        end

        alt_restart_hit_r = 1'b0;
        alt_restart_data_r = {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
        alt_restart_cache_line_valid_r = 1'b0;
        alt_restart_cache_line_data_r =
            {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
        alt_restart_sector_mask_r = 2'b00;
        if ((ENABLE_ALT_LOOKASIDE != 0) && alt_restart_eligible_i &&
            !invalidate_i && !flush_i) begin
            if (ENABLE_ALT_LOOKASIDE >= 3) begin
                for (alt_index = 0;
                     alt_index < ALT_SECTOR_CONTEXTS;
                     alt_index = alt_index + 1) begin
                    if (alt_sector_context_valid_q[alt_index] &&
                        alt_sector_predicted_valid_q[alt_index] &&
                        (alt_sector_predicted_addr_q[alt_index][
                            `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS] ==
                         restart_pc_i[
                            `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS])) begin
                        alt_restart_hit_r = 1'b1;
                        if (ENABLE_ALT_LOOKASIDE == 5) begin
                            alt_restart_sector_mask_r = 2'b11;
                            alt_restart_cache_line_valid_r = 1'b1;
                            alt_restart_cache_line_data_r =
                                alt_sector_predicted_data_q[alt_index];
                            alt_restart_data_r = select_cache_line_block(
                                alt_sector_predicted_data_q[alt_index],
                                restart_pc_i);
                        end else if (ENABLE_ALT_LOOKASIDE == 4) begin
                            alt_restart_sector_mask_r = 2'b11;
                            alt_restart_data_r =
                                alt_sector_predicted_data_q[alt_index];
                        end else begin
                            alt_restart_sector_mask_r =
                                restart_pc_i[ALT_SECTOR_BYTE_BITS] ?
                                2'b10 : 2'b01;
                            if (restart_pc_i[ALT_SECTOR_BYTE_BITS])
                                alt_restart_data_r[255:128] =
                                    alt_sector_predicted_data_q[alt_index];
                            else
                                alt_restart_data_r[127:0] =
                                    alt_sector_predicted_data_q[alt_index];
                        end
                    end
                    if (alt_sector_context_valid_q[alt_index] &&
                        alt_sector_unpredicted_valid_q[alt_index] &&
                        (alt_sector_unpredicted_addr_q[alt_index][
                            `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS] ==
                         restart_pc_i[
                            `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS])) begin
                        alt_restart_hit_r = 1'b1;
                        if (ENABLE_ALT_LOOKASIDE == 5) begin
                            alt_restart_sector_mask_r = 2'b11;
                            alt_restart_cache_line_valid_r = 1'b1;
                            alt_restart_cache_line_data_r =
                                alt_sector_unpredicted_data_q[alt_index];
                            alt_restart_data_r = select_cache_line_block(
                                alt_sector_unpredicted_data_q[alt_index],
                                restart_pc_i);
                        end else if (ENABLE_ALT_LOOKASIDE == 4) begin
                            alt_restart_sector_mask_r = 2'b11;
                            alt_restart_data_r =
                                alt_sector_unpredicted_data_q[alt_index];
                        end else begin
                            alt_restart_sector_mask_r =
                                restart_pc_i[ALT_SECTOR_BYTE_BITS] ?
                                2'b10 : 2'b01;
                            if (restart_pc_i[ALT_SECTOR_BYTE_BITS])
                                alt_restart_data_r[255:128] =
                                    alt_sector_unpredicted_data_q[alt_index];
                            else
                                alt_restart_data_r[127:0] =
                                    alt_sector_unpredicted_data_q[alt_index];
                        end
                    end
                end
                // A tracked sector arriving on the redirect edge bypasses
                // the preview registers.
                if ((ENABLE_ALT_LOOKASIDE != 5) &&
                    resp_valid_i && !resp_access_fault_i &&
                    !resp_page_fault_i &&
                    (resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS] ==
                     restart_pc_i[`RV64_XLEN-1:LINE_BYTE_BITS])) begin
                    for (alt_index = 0;
                         alt_index < ALT_SECTOR_CONTEXTS;
                         alt_index = alt_index + 1) begin
                        if (alt_sector_context_valid_q[alt_index] &&
                            ((alt_sector_predicted_addr_q[alt_index][
                                `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS] ==
                              restart_pc_i[
                                `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS]) ||
                             (alt_sector_unpredicted_addr_q[alt_index][
                                `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS] ==
                              restart_pc_i[
                                `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS]))) begin
                            alt_restart_hit_r = 1'b1;
                            if (ENABLE_ALT_LOOKASIDE == 4) begin
                                alt_restart_sector_mask_r = 2'b11;
                                alt_restart_data_r = resp_data_i;
                            end else begin
                                alt_restart_sector_mask_r =
                                    restart_pc_i[ALT_SECTOR_BYTE_BITS] ?
                                    2'b10 : 2'b01;
                                if (restart_pc_i[ALT_SECTOR_BYTE_BITS])
                                    alt_restart_data_r[255:128] =
                                        resp_data_i[255:128];
                                else
                                    alt_restart_data_r[127:0] =
                                        resp_data_i[127:0];
                            end
                        end
                    end
                end
                if ((ENABLE_ALT_LOOKASIDE == 4) &&
                    pair512_resp_valid_i &&
                    (pair512_resp_predicted_addr_i[
                        `RV64_XLEN-1:LINE_BYTE_BITS] ==
                     restart_pc_i[
                        `RV64_XLEN-1:LINE_BYTE_BITS])) begin
                    alt_restart_hit_r = 1'b1;
                    alt_restart_sector_mask_r = 2'b11;
                    alt_restart_data_r =
                        pair512_resp_predicted_data_i;
                end
                if ((ENABLE_ALT_LOOKASIDE == 4) &&
                    pair512_resp_valid_i &&
                    (pair512_resp_unpredicted_addr_i[
                        `RV64_XLEN-1:LINE_BYTE_BITS] ==
                     restart_pc_i[
                        `RV64_XLEN-1:LINE_BYTE_BITS])) begin
                    alt_restart_hit_r = 1'b1;
                    alt_restart_sector_mask_r = 2'b11;
                    alt_restart_data_r =
                        pair512_resp_unpredicted_data_i;
                end
                if ((ENABLE_ALT_LOOKASIDE == 5) &&
                    pair1024_resp_valid_i &&
                    (pair1024_resp_predicted_addr_i[
                        `RV64_XLEN-1:CACHE_LINE_BYTE_BITS] ==
                     restart_pc_i[
                        `RV64_XLEN-1:CACHE_LINE_BYTE_BITS])) begin
                    alt_restart_hit_r = 1'b1;
                    alt_restart_sector_mask_r = 2'b11;
                    alt_restart_cache_line_valid_r = 1'b1;
                    alt_restart_cache_line_data_r =
                        pair1024_resp_predicted_data_i;
                    alt_restart_data_r = select_cache_line_block(
                        pair1024_resp_predicted_data_i,
                        restart_pc_i);
                end
                if ((ENABLE_ALT_LOOKASIDE == 5) &&
                    pair1024_resp_valid_i &&
                    (pair1024_resp_unpredicted_addr_i[
                        `RV64_XLEN-1:CACHE_LINE_BYTE_BITS] ==
                     restart_pc_i[
                        `RV64_XLEN-1:CACHE_LINE_BYTE_BITS])) begin
                    alt_restart_hit_r = 1'b1;
                    alt_restart_sector_mask_r = 2'b11;
                    alt_restart_cache_line_valid_r = 1'b1;
                    alt_restart_cache_line_data_r =
                        pair1024_resp_unpredicted_data_i;
                    alt_restart_data_r = select_cache_line_block(
                        pair1024_resp_unpredicted_data_i,
                        restart_pc_i);
                end
            end else begin
                for (alt_index = 0; alt_index < ALT_LOOKASIDE_LINES;
                    alt_index = alt_index + 1) begin
                    if (alt_valid_q[alt_index] &&
                        (alt_addr_q[alt_index][`RV64_XLEN-1:
                                                    LINE_BYTE_BITS] ==
                         restart_pc_i[
                            `RV64_XLEN-1:LINE_BYTE_BITS])) begin
                        alt_restart_hit_r = 1'b1;
                        alt_restart_data_r = alt_data_q[alt_index];
                        alt_restart_sector_mask_r = 2'b11;
                    end
                end
                // A qualified standard response coincident with the redirect
                // need not wait one extra cycle to enter the two-entry store.
                if (resp_valid_i && resp_stash_i &&
                    !resp_access_fault_i && !resp_page_fault_i &&
                    !alt_prefetch_aged_r &&
                    (resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS] ==
                     restart_pc_i[`RV64_XLEN-1:LINE_BYTE_BITS])) begin
                    alt_restart_hit_r = 1'b1;
                    alt_restart_data_r = resp_data_i;
                    alt_restart_sector_mask_r = 2'b11;
                end
            end
        end

        alt_fill_match_r = 1'b0;
        alt_fill_slot_r = alt_replace_q;
        alt_free_found_r = 1'b0;
        for (alt_index = 0; alt_index < ALT_LOOKASIDE_LINES;
             alt_index = alt_index + 1) begin
            if (alt_valid_q[alt_index] &&
                (alt_addr_q[alt_index][`RV64_XLEN-1:
                                            LINE_BYTE_BITS] ==
                 resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS])) begin
                alt_fill_match_r = 1'b1;
                alt_fill_slot_r = alt_index[0];
            end
            if (!alt_fill_match_r && !alt_free_found_r &&
                !alt_valid_q[alt_index]) begin
                alt_fill_slot_r = alt_index[0];
                alt_free_found_r = 1'b1;
            end
        end

    end

    assign alt_restart_hit_o = restart_i && alt_restart_hit_r;

    integer alt_reset_index;
    integer alt_age_seq_port;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alt_replace_q <= 1'b0;
            for (alt_reset_index = 0;
                 alt_reset_index < ALT_LOOKASIDE_LINES;
                 alt_reset_index = alt_reset_index + 1) begin
                alt_valid_q[alt_reset_index] <= 1'b0;
                alt_addr_q[alt_reset_index] <= {`RV64_XLEN{1'b0}};
                alt_data_q[alt_reset_index] <=
                    {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
            end
        end else if (invalidate_i || flush_i) begin
            alt_replace_q <= 1'b0;
            for (alt_reset_index = 0;
                 alt_reset_index < ALT_LOOKASIDE_LINES;
                 alt_reset_index = alt_reset_index + 1)
                alt_valid_q[alt_reset_index] <= 1'b0;
        end else if ((ENABLE_ALT_LOOKASIDE != 0) &&
                     (ENABLE_ALT_LOOKASIDE < 3)) begin
            for (alt_age_seq_port = 0; alt_age_seq_port < 3;
                 alt_age_seq_port = alt_age_seq_port + 1) begin
                if (prefetch_age_valid_i[alt_age_seq_port]) begin
                    for (alt_reset_index = 0;
                         alt_reset_index < ALT_LOOKASIDE_LINES;
                         alt_reset_index = alt_reset_index + 1) begin
                        if (alt_valid_q[alt_reset_index] &&
                            (alt_addr_q[alt_reset_index][
                                `RV64_XLEN-1:6] ==
                             prefetch_age_addr_i[
                                alt_age_seq_port*`RV64_XLEN +
                                6 +: `RV64_XLEN-6]))
                            alt_valid_q[alt_reset_index] <= 1'b0;
                    end
                end
            end
            if (resp_valid_i && resp_stash_i &&
                !resp_access_fault_i && !resp_page_fault_i &&
                !alt_prefetch_aged_r) begin
                alt_valid_q[alt_fill_slot_r] <= 1'b1;
                alt_addr_q[alt_fill_slot_r] <= {
                    resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS],
                    {LINE_BYTE_BITS{1'b0}}
                };
                alt_data_q[alt_fill_slot_r] <= resp_data_i;
                if (!alt_fill_match_r)
                    alt_replace_q <= ~alt_fill_slot_r;
            end
        end
    end

    integer alt_sector_reset_index;
    integer alt_sector_age_port;
    integer alt_sector_fill_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alt_sector_replace_q <=
                {ALT_SECTOR_CONTEXT_INDEX_WIDTH{1'b0}};
            for (alt_sector_reset_index = 0;
                 alt_sector_reset_index < ALT_SECTOR_CONTEXTS;
                 alt_sector_reset_index =
                    alt_sector_reset_index + 1) begin
                alt_sector_context_valid_q[
                    alt_sector_reset_index] <= 1'b0;
                alt_sector_predicted_addr_q[
                    alt_sector_reset_index] <=
                        {`RV64_XLEN{1'b0}};
                alt_sector_unpredicted_addr_q[
                    alt_sector_reset_index] <=
                        {`RV64_XLEN{1'b0}};
                alt_sector_predicted_valid_q[
                    alt_sector_reset_index] <= 1'b0;
                alt_sector_unpredicted_valid_q[
                    alt_sector_reset_index] <= 1'b0;
                alt_sector_predicted_data_q[
                    alt_sector_reset_index] <=
                        {ALT_PREVIEW_BITS{1'b0}};
                alt_sector_unpredicted_data_q[
                    alt_sector_reset_index] <=
                        {ALT_PREVIEW_BITS{1'b0}};
            end
        end else if (invalidate_i || flush_i) begin
            alt_sector_replace_q <=
                {ALT_SECTOR_CONTEXT_INDEX_WIDTH{1'b0}};
            for (alt_sector_reset_index = 0;
                 alt_sector_reset_index < ALT_SECTOR_CONTEXTS;
                 alt_sector_reset_index =
                    alt_sector_reset_index + 1) begin
                alt_sector_context_valid_q[
                    alt_sector_reset_index] <= 1'b0;
                alt_sector_predicted_valid_q[
                    alt_sector_reset_index] <= 1'b0;
                alt_sector_unpredicted_valid_q[
                    alt_sector_reset_index] <= 1'b0;
            end
        end else if (ENABLE_ALT_LOOKASIDE >= 3) begin
            // Retirement identifies the completed branch by its discarded
            // line.  Drop the complete pair context so a later dynamic
            // instance may allocate and refill normally.
            for (alt_sector_age_port = 0;
                 alt_sector_age_port < 3;
                 alt_sector_age_port = alt_sector_age_port + 1) begin
                if (prefetch_age_valid_i[alt_sector_age_port]) begin
                    for (alt_sector_fill_index = 0;
                         alt_sector_fill_index < ALT_SECTOR_CONTEXTS;
                         alt_sector_fill_index =
                            alt_sector_fill_index + 1) begin
                        if (alt_sector_context_valid_q[
                                alt_sector_fill_index] &&
                            ((alt_sector_predicted_addr_q[
                                alt_sector_fill_index][
                                    `RV64_XLEN-1:6] ==
                              prefetch_age_addr_i[
                                alt_sector_age_port*`RV64_XLEN +
                                6 +: `RV64_XLEN-6]) ||
                             (alt_sector_unpredicted_addr_q[
                                alt_sector_fill_index][
                                    `RV64_XLEN-1:6] ==
                              prefetch_age_addr_i[
                                alt_sector_age_port*`RV64_XLEN +
                                6 +: `RV64_XLEN-6]))) begin
                            alt_sector_context_valid_q[
                                alt_sector_fill_index] <= 1'b0;
                            alt_sector_predicted_valid_q[
                                alt_sector_fill_index] <= 1'b0;
                            alt_sector_unpredicted_valid_q[
                                alt_sector_fill_index] <= 1'b0;
                        end
                    end
                end
            end

            if ((ENABLE_ALT_LOOKASIDE == 4) &&
                pair512_resp_valid_i) begin
                for (alt_sector_fill_index = 0;
                     alt_sector_fill_index < ALT_SECTOR_CONTEXTS;
                     alt_sector_fill_index =
                        alt_sector_fill_index + 1) begin
                    if (alt_sector_context_valid_q[
                            alt_sector_fill_index] &&
                        (alt_sector_predicted_addr_q[
                            alt_sector_fill_index][
                                `RV64_XLEN-1:LINE_BYTE_BITS] ==
                         pair512_resp_predicted_addr_i[
                            `RV64_XLEN-1:LINE_BYTE_BITS]) &&
                        (alt_sector_unpredicted_addr_q[
                            alt_sector_fill_index][
                                `RV64_XLEN-1:LINE_BYTE_BITS] ==
                         pair512_resp_unpredicted_addr_i[
                            `RV64_XLEN-1:LINE_BYTE_BITS])) begin
                        alt_sector_predicted_valid_q[
                            alt_sector_fill_index] <= 1'b1;
                        alt_sector_unpredicted_valid_q[
                            alt_sector_fill_index] <= 1'b1;
                        alt_sector_predicted_data_q[
                            alt_sector_fill_index] <=
                                pair512_resp_predicted_data_i;
                        alt_sector_unpredicted_data_q[
                            alt_sector_fill_index] <=
                                pair512_resp_unpredicted_data_i;
                    end
                end
            end

            if ((ENABLE_ALT_LOOKASIDE == 5) &&
                pair1024_resp_valid_i) begin
                for (alt_sector_fill_index = 0;
                     alt_sector_fill_index < ALT_SECTOR_CONTEXTS;
                     alt_sector_fill_index =
                        alt_sector_fill_index + 1) begin
                    if (alt_sector_context_valid_q[
                            alt_sector_fill_index] &&
                        (alt_sector_predicted_addr_q[
                            alt_sector_fill_index][
                                `RV64_XLEN-1:CACHE_LINE_BYTE_BITS] ==
                         pair1024_resp_predicted_addr_i[
                            `RV64_XLEN-1:CACHE_LINE_BYTE_BITS]) &&
                        (alt_sector_unpredicted_addr_q[
                            alt_sector_fill_index][
                                `RV64_XLEN-1:CACHE_LINE_BYTE_BITS] ==
                         pair1024_resp_unpredicted_addr_i[
                            `RV64_XLEN-1:CACHE_LINE_BYTE_BITS])) begin
                        alt_sector_predicted_valid_q[
                            alt_sector_fill_index] <= 1'b1;
                        alt_sector_unpredicted_valid_q[
                            alt_sector_fill_index] <= 1'b1;
                        alt_sector_predicted_data_q[
                            alt_sector_fill_index] <=
                                pair1024_resp_predicted_data_i;
                        alt_sector_unpredicted_data_q[
                            alt_sector_fill_index] <=
                                pair1024_resp_unpredicted_data_i;
                    end
                end
            end

            // Tap every successful standard response.  Architectural demand
            // is therefore the source of the predicted preview in the common
            // case; a qualified alternate response fills only the other side.
            if ((ENABLE_ALT_LOOKASIDE != 5) &&
                resp_valid_i && !resp_access_fault_i &&
                !resp_page_fault_i && !alt_prefetch_aged_r) begin
                for (alt_sector_fill_index = 0;
                     alt_sector_fill_index < ALT_SECTOR_CONTEXTS;
                     alt_sector_fill_index =
                        alt_sector_fill_index + 1) begin
                    if (alt_sector_context_valid_q[
                            alt_sector_fill_index] &&
                        (alt_sector_predicted_addr_q[
                            alt_sector_fill_index][
                                `RV64_XLEN-1:LINE_BYTE_BITS] ==
                         resp_addr_i[
                            `RV64_XLEN-1:LINE_BYTE_BITS])) begin
                        alt_sector_predicted_valid_q[
                            alt_sector_fill_index] <= 1'b1;
                        alt_sector_predicted_data_q[
                            alt_sector_fill_index] <=
                            select_preview(
                                resp_data_i,
                                alt_sector_predicted_addr_q[
                                    alt_sector_fill_index]);
                    end
                    if (alt_sector_context_valid_q[
                            alt_sector_fill_index] &&
                        (alt_sector_unpredicted_addr_q[
                            alt_sector_fill_index][
                                `RV64_XLEN-1:LINE_BYTE_BITS] ==
                         resp_addr_i[
                            `RV64_XLEN-1:LINE_BYTE_BITS])) begin
                        alt_sector_unpredicted_valid_q[
                            alt_sector_fill_index] <= 1'b1;
                        alt_sector_unpredicted_data_q[
                            alt_sector_fill_index] <=
                            select_preview(
                                resp_data_i,
                                alt_sector_unpredicted_addr_q[
                                    alt_sector_fill_index]);
                    end
                end
            end

            if (branch_pair_valid_i &&
                !branch_sector_context_match_r) begin
                alt_sector_context_valid_q[
                    alt_sector_replace_q] <= 1'b1;
                alt_sector_predicted_addr_q[
                    alt_sector_replace_q] <= {
                        branch_predicted_addr_i[
                            `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS],
                        {ALT_PREVIEW_BYTE_BITS{1'b0}}
                    };
                alt_sector_unpredicted_addr_q[
                    alt_sector_replace_q] <= {
                        branch_unpredicted_addr_i[
                            `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS],
                        {ALT_PREVIEW_BYTE_BITS{1'b0}}
                    };
                alt_sector_predicted_valid_q[
                    alt_sector_replace_q] <=
                        branch_predicted_sector_source_valid_r;
                alt_sector_unpredicted_valid_q[
                    alt_sector_replace_q] <=
                        branch_unpredicted_sector_source_valid_r;
                alt_sector_predicted_data_q[
                    alt_sector_replace_q] <=
                        branch_predicted_sector_source_data_r;
                alt_sector_unpredicted_data_q[
                    alt_sector_replace_q] <=
                        branch_unpredicted_sector_source_data_r;
                if (alt_sector_replace_q ==
                    ALT_SECTOR_CONTEXTS - 1)
                    alt_sector_replace_q <=
                        {ALT_SECTOR_CONTEXT_INDEX_WIDTH{1'b0}};
                else
                    alt_sector_replace_q <=
                        alt_sector_replace_q + 1'b1;
            end else if (branch_pair_valid_i &&
                         branch_sector_context_match_r) begin
                // Repeated tight-loop allocation refreshes from fetch
                // residency without allocating another context or request.
                for (alt_sector_fill_index = 0;
                     alt_sector_fill_index < ALT_SECTOR_CONTEXTS;
                     alt_sector_fill_index =
                        alt_sector_fill_index + 1) begin
                    if (alt_sector_context_valid_q[
                            alt_sector_fill_index] &&
                        (alt_sector_predicted_addr_q[
                            alt_sector_fill_index][
                                `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS] ==
                         branch_predicted_addr_i[
                            `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS]) &&
                        (alt_sector_unpredicted_addr_q[
                            alt_sector_fill_index][
                                `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS] ==
                         branch_unpredicted_addr_i[
                            `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS])) begin
                        if (branch_predicted_sector_source_valid_r) begin
                            alt_sector_predicted_valid_q[
                                alt_sector_fill_index] <= 1'b1;
                            alt_sector_predicted_data_q[
                                alt_sector_fill_index] <=
                                branch_predicted_sector_source_data_r;
                        end
                        if (branch_unpredicted_sector_source_valid_r) begin
                            alt_sector_unpredicted_valid_q[
                                alt_sector_fill_index] <= 1'b1;
                            alt_sector_unpredicted_data_q[
                                alt_sector_fill_index] <=
                                branch_unpredicted_sector_source_data_r;
                        end
                    end
                end
            end
        end
    end

    // Modes 1/2 emit ordinary predicted/unpredicted requests.  Mode 3 emits
    // only a missing unpredicted block.  Modes 4/5 use pair512/pair1024.
    wire pair_context_overlap = branch_pair_valid_i &&
                                pair_remains_after_fire;
    wire pair_stack_overflow;
    wire [PAIR_STACK_COUNT_WIDTH-1:0] pair_saved_count;
    generate
        if (BRANCH_PAIR_STACK_DEPTH == 1) begin : g_single_pair
            assign pair_stack_overflow = 1'b0;
            assign pair_saved_count = {PAIR_STACK_COUNT_WIDTH{1'b0}};
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pair_predicted_valid_q <= 1'b0;
                    pair_unpredicted_valid_q <= 1'b0;
                    pair_predicted_addr_q <= {`RV64_XLEN{1'b0}};
                    pair_unpredicted_addr_q <= {`RV64_XLEN{1'b0}};
                end else if (invalidate_i || flush_i) begin
                    pair_predicted_valid_q <= 1'b0;
                    pair_unpredicted_valid_q <= 1'b0;
                end else begin
                    if (pair_req_fire) begin
                        if (pair_predicted_valid_q)
                            pair_predicted_valid_q <= 1'b0;
                        else
                            pair_unpredicted_valid_q <= 1'b0;
                    end
                    if ((ENABLE_ALT_LOOKASIDE != 0) &&
                        branch_pair_valid_i) begin
                        pair_predicted_valid_q <=
                            (ENABLE_ALT_LOOKASIDE >= 3) ?
                                1'b0 :
                                !branch_predicted_stashed_r;
                        pair_unpredicted_valid_q <=
                            (ENABLE_ALT_LOOKASIDE == 3) ?
                                (!branch_sector_context_match_r &&
                                 !branch_unpredicted_sector_source_valid_r &&
                                 (branch_predicted_addr_i[
                                    `RV64_XLEN-1:
                                        ALT_SECTOR_BYTE_BITS] !=
                                  branch_unpredicted_addr_i[
                                    `RV64_XLEN-1:
                                        ALT_SECTOR_BYTE_BITS])) :
                            (ENABLE_ALT_LOOKASIDE >= 4) ?
                                1'b0 :
                                (!branch_unpredicted_stashed_r &&
                                 (branch_predicted_addr_i[
                                    `RV64_XLEN-1:LINE_BYTE_BITS] !=
                                  branch_unpredicted_addr_i[
                                    `RV64_XLEN-1:LINE_BYTE_BITS]));
                        pair_predicted_addr_q <= {
                            branch_predicted_addr_i[
                                `RV64_XLEN-1:LINE_BYTE_BITS],
                            {LINE_BYTE_BITS{1'b0}}
                        };
                        pair_unpredicted_addr_q <= {
                            branch_unpredicted_addr_i[
                                `RV64_XLEN-1:LINE_BYTE_BITS],
                            {LINE_BYTE_BITS{1'b0}}
                        };
                    end
                end
            end
        end else begin : g_pair_stack
            reg saved_predicted_valid_q [0:BRANCH_PAIR_STACK_DEPTH-2];
            reg saved_unpredicted_valid_q [0:BRANCH_PAIR_STACK_DEPTH-2];
            reg [`RV64_XLEN-1:0]
                saved_predicted_addr_q [0:BRANCH_PAIR_STACK_DEPTH-2];
            reg [`RV64_XLEN-1:0]
                saved_unpredicted_addr_q [0:BRANCH_PAIR_STACK_DEPTH-2];
            reg [PAIR_STACK_COUNT_WIDTH-1:0] saved_count_q;
            integer saved_index;

            assign pair_saved_count = saved_count_q;
            assign pair_stack_overflow =
                (ENABLE_ALT_LOOKASIDE != 0) && branch_pair_valid_i &&
                pair_remains_after_fire &&
                (saved_count_q == BRANCH_PAIR_STACK_DEPTH - 1);

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pair_predicted_valid_q <= 1'b0;
                    pair_unpredicted_valid_q <= 1'b0;
                    pair_predicted_addr_q <= {`RV64_XLEN{1'b0}};
                    pair_unpredicted_addr_q <= {`RV64_XLEN{1'b0}};
                    saved_count_q <= {PAIR_STACK_COUNT_WIDTH{1'b0}};
                    for (saved_index = 0;
                         saved_index < BRANCH_PAIR_STACK_DEPTH - 1;
                         saved_index = saved_index + 1) begin
                        saved_predicted_valid_q[saved_index] <= 1'b0;
                        saved_unpredicted_valid_q[saved_index] <= 1'b0;
                        saved_predicted_addr_q[saved_index] <=
                            {`RV64_XLEN{1'b0}};
                        saved_unpredicted_addr_q[saved_index] <=
                            {`RV64_XLEN{1'b0}};
                    end
                end else if (invalidate_i || flush_i) begin
                    pair_predicted_valid_q <= 1'b0;
                    pair_unpredicted_valid_q <= 1'b0;
                    saved_count_q <= {PAIR_STACK_COUNT_WIDTH{1'b0}};
                end else if ((ENABLE_ALT_LOOKASIDE != 0) &&
                             branch_pair_valid_i) begin
                    // The request selected before this edge still launches.
                    // Preserve only the portion of the displaced pair which
                    // remains afterward.
                    if (pair_remains_after_fire) begin
                        if (saved_count_q <
                            BRANCH_PAIR_STACK_DEPTH - 1) begin
                            saved_predicted_valid_q[saved_count_q] <=
                                pair_predicted_after_fire;
                            saved_unpredicted_valid_q[saved_count_q] <=
                                pair_unpredicted_after_fire;
                            saved_predicted_addr_q[saved_count_q] <=
                                pair_predicted_addr_q;
                            saved_unpredicted_addr_q[saved_count_q] <=
                                pair_unpredicted_addr_q;
                            saved_count_q <= saved_count_q + 1'b1;
                        end else begin
                            // Keep the newest contexts when full.
                            for (saved_index = 0;
                                 saved_index <
                                     BRANCH_PAIR_STACK_DEPTH - 2;
                                 saved_index = saved_index + 1) begin
                                saved_predicted_valid_q[saved_index] <=
                                    saved_predicted_valid_q[
                                        saved_index + 1];
                                saved_unpredicted_valid_q[saved_index] <=
                                    saved_unpredicted_valid_q[
                                        saved_index + 1];
                                saved_predicted_addr_q[saved_index] <=
                                    saved_predicted_addr_q[
                                        saved_index + 1];
                                saved_unpredicted_addr_q[saved_index] <=
                                    saved_unpredicted_addr_q[
                                        saved_index + 1];
                            end
                            saved_predicted_valid_q[
                                BRANCH_PAIR_STACK_DEPTH - 2] <=
                                    pair_predicted_after_fire;
                            saved_unpredicted_valid_q[
                                BRANCH_PAIR_STACK_DEPTH - 2] <=
                                    pair_unpredicted_after_fire;
                            saved_predicted_addr_q[
                                BRANCH_PAIR_STACK_DEPTH - 2] <=
                                    pair_predicted_addr_q;
                            saved_unpredicted_addr_q[
                                BRANCH_PAIR_STACK_DEPTH - 2] <=
                                    pair_unpredicted_addr_q;
                        end
                    end
                    pair_predicted_valid_q <=
                        (ENABLE_ALT_LOOKASIDE >= 3) ?
                            1'b0 :
                            !branch_predicted_stashed_r;
                    pair_unpredicted_valid_q <=
                        (ENABLE_ALT_LOOKASIDE == 3) ?
                            (!branch_sector_context_match_r &&
                             !branch_unpredicted_sector_source_valid_r &&
                             (branch_predicted_addr_i[
                                `RV64_XLEN-1:ALT_SECTOR_BYTE_BITS] !=
                              branch_unpredicted_addr_i[
                                `RV64_XLEN-1:ALT_SECTOR_BYTE_BITS])) :
                        (ENABLE_ALT_LOOKASIDE >= 4) ?
                            1'b0 :
                            (!branch_unpredicted_stashed_r &&
                             (branch_predicted_addr_i[
                                `RV64_XLEN-1:LINE_BYTE_BITS] !=
                              branch_unpredicted_addr_i[
                                `RV64_XLEN-1:LINE_BYTE_BITS]));
                    pair_predicted_addr_q <= {
                        branch_predicted_addr_i[
                            `RV64_XLEN-1:LINE_BYTE_BITS],
                        {LINE_BYTE_BITS{1'b0}}
                    };
                    pair_unpredicted_addr_q <= {
                        branch_unpredicted_addr_i[
                            `RV64_XLEN-1:LINE_BYTE_BITS],
                        {LINE_BYTE_BITS{1'b0}}
                    };
                end else if (pair_req_fire) begin
                    if (pair_remains_after_fire) begin
                        pair_predicted_valid_q <=
                            pair_predicted_after_fire;
                        pair_unpredicted_valid_q <=
                            pair_unpredicted_after_fire;
                    end else if (saved_count_q != 0) begin
                        pair_predicted_valid_q <=
                            saved_predicted_valid_q[saved_count_q - 1'b1];
                        pair_unpredicted_valid_q <=
                            saved_unpredicted_valid_q[
                                saved_count_q - 1'b1];
                        pair_predicted_addr_q <=
                            saved_predicted_addr_q[saved_count_q - 1'b1];
                        pair_unpredicted_addr_q <=
                            saved_unpredicted_addr_q[
                                saved_count_q - 1'b1];
                        saved_count_q <= saved_count_q - 1'b1;
                    end else begin
                        pair_predicted_valid_q <= 1'b0;
                        pair_unpredicted_valid_q <= 1'b0;
                    end
                end else if (!pair_request_valid &&
                             (saved_count_q != 0)) begin
                    pair_predicted_valid_q <=
                        saved_predicted_valid_q[saved_count_q - 1'b1];
                    pair_unpredicted_valid_q <=
                        saved_unpredicted_valid_q[saved_count_q - 1'b1];
                    pair_predicted_addr_q <=
                        saved_predicted_addr_q[saved_count_q - 1'b1];
                    pair_unpredicted_addr_q <=
                        saved_unpredicted_addr_q[saved_count_q - 1'b1];
                    saved_count_q <= saved_count_q - 1'b1;
                end
            end
        end
    endgenerate

    integer reset_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_q <= 1'b0;
            consume_pc_q <= {`RV64_XLEN{1'b0}};
            pending_valid_q <= 1'b0;
            pending_addr_q <= {`RV64_XLEN{1'b0}};
            for (reset_index = 0; reset_index < LINE_DEPTH;
                 reset_index = reset_index + 1) begin
                line_valid_q[reset_index] <= 1'b0;
                line_addr_q[reset_index] <= {`RV64_XLEN{1'b0}};
                line_data_q[reset_index] <=
                    {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
                line_sector_valid_q[reset_index] <= 2'b00;
                line_access_fault_q[reset_index] <= 1'b0;
                line_page_fault_q[reset_index] <= 1'b0;
            end
        end else if (restart_i) begin
            active_q <= 1'b1;
            consume_pc_q <= restart_pc_i;
            pending_valid_q <= 1'b0;
            if (alt_restart_hit_r) begin
                for (reset_index = 0; reset_index < LINE_DEPTH;
                     reset_index = reset_index + 1) begin
                    line_valid_q[reset_index] <= 1'b0;
                    line_sector_valid_q[reset_index] <= 2'b00;
                end
                if ((ENABLE_ALT_LOOKASIDE == 5) &&
                    alt_restart_cache_line_valid_r) begin
                    line_valid_q[0] <= 1'b1;
                    line_addr_q[0] <= {
                        restart_pc_i[
                            `RV64_XLEN-1:CACHE_LINE_BYTE_BITS],
                        {CACHE_LINE_BYTE_BITS{1'b0}}
                    };
                    line_data_q[0] <=
                        alt_restart_cache_line_data_r[255:0];
                    line_sector_valid_q[0] <= 2'b11;
                    line_access_fault_q[0] <= 1'b0;
                    line_page_fault_q[0] <= 1'b0;
                    line_valid_q[1] <= 1'b1;
                    line_addr_q[1] <= {
                        restart_pc_i[
                            `RV64_XLEN-1:CACHE_LINE_BYTE_BITS],
                        {CACHE_LINE_BYTE_BITS{1'b0}}
                    } + LINE_BYTES;
                    line_data_q[1] <=
                        alt_restart_cache_line_data_r[511:256];
                    line_sector_valid_q[1] <= 2'b11;
                    line_access_fault_q[1] <= 1'b0;
                    line_page_fault_q[1] <= 1'b0;
                end else begin
                    line_valid_q[restart_pc_i[LINE_BYTE_BITS]] <= 1'b1;
                    line_addr_q[restart_pc_i[LINE_BYTE_BITS]] <= {
                        restart_pc_i[`RV64_XLEN-1:LINE_BYTE_BITS],
                        {LINE_BYTE_BITS{1'b0}}
                    };
                    line_data_q[restart_pc_i[LINE_BYTE_BITS]] <=
                        alt_restart_data_r;
                    line_sector_valid_q[
                        restart_pc_i[LINE_BYTE_BITS]] <=
                            alt_restart_sector_mask_r;
                    line_access_fault_q[
                        restart_pc_i[LINE_BYTE_BITS]] <= 1'b0;
                    line_page_fault_q[
                        restart_pc_i[LINE_BYTE_BITS]] <= 1'b0;
                end
            end else begin
                for (reset_index = 0; reset_index < LINE_DEPTH;
                     reset_index = reset_index + 1) begin
                    line_valid_q[reset_index] <= 1'b0;
                    line_sector_valid_q[reset_index] <= 2'b00;
                end
            end
        end else if (flush_i || invalidate_i) begin
            if (flush_i)
                active_q <= 1'b0;
            pending_valid_q <= 1'b0;
            for (reset_index = 0; reset_index < LINE_DEPTH;
                 reset_index = reset_index + 1) begin
                line_valid_q[reset_index] <= 1'b0;
                line_sector_valid_q[reset_index] <= 2'b00;
            end
        end else begin
            if (req_fire && req_demand_o) begin
                pending_valid_q <= 1'b1;
                pending_addr_q <= req_addr_o;
            end
            if (resp_valid_i && resp_match) begin
                pending_valid_q <= 1'b0;
                line_valid_q[resp_slot] <= 1'b1;
                line_addr_q[resp_slot] <= {
                    resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS],
                    {LINE_BYTE_BITS{1'b0}}
                };
                line_data_q[resp_slot] <= resp_data_i;
                line_sector_valid_q[resp_slot] <= 2'b11;
                line_access_fault_q[resp_slot] <=
                    resp_access_fault_i;
                line_page_fault_q[resp_slot] <=
                    resp_page_fault_i;
            end
            if (decode_count != 0)
                consume_pc_q <= next_consume_pc;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (LINE_DEPTH != 2)
            $fatal(1, "fetch_3w LINE_DEPTH is fixed at current plus next");
        if (BRANCH_PAIR_STACK_DEPTH < 1)
            $fatal(1, "fetch_3w branch-pair stack depth must be positive");
    end

    always @(posedge clk) begin
        if (rst_n && (ENABLE_ALT_LOOKASIDE == 4) &&
            pair512_req_valid_o && !pair512_req_ready_i)
            $fatal(1,
                "fetch_3w experimental pair512 response model must be always-ready");
        if (rst_n && (ENABLE_ALT_LOOKASIDE == 5) &&
            pair1024_req_valid_o && !pair1024_req_ready_i)
            $fatal(1,
                "fetch_3w experimental pair1024 response model must be always-ready");
    end

    always @(posedge clk) begin
        if (rst_n && resp_valid_i && resp_demand_i &&
            !restart_i && !invalidate_i &&
            !flush_i && !resp_match)
            $fatal(1,
                "fetch_3w response addr=%h does not match pending valid=%b addr=%h",
                resp_addr_i, pending_valid_q, pending_addr_q);
        if (rst_n && (decode_valid_o != 3'b000) &&
            (decode_valid_o != 3'b001) &&
            (decode_valid_o != 3'b011) &&
            (decode_valid_o != 3'b111))
            $fatal(1, "fetch_3w decode output is not a contiguous prefix");
    end
`endif

endmodule
