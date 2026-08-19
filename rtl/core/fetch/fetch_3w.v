`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/fetch/fetch-defs.v"
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

// Three-wide frontend for the 256-bit AXI fetch path.
//
// The default four-entry carousel forms a direct-mapped 128-byte resident
// window and permits one replacement request per entry. A rolling cursor keeps
// the current block and next three blocks requested. ENABLE_CAROUSEL=0 retains
// the two-block, single-request bridge as a control configuration.
//
// A conditional-branch hint may additionally launch two qualified requests,
// predicted side first, for the redirect stash. L1I owns cache residency while
// the carousel hides its request/response latency from the frontend.
module openrv64_fetch_3w #(
    parameter integer ENABLE_CAROUSEL = 1,
    parameter integer LINE_DEPTH = ENABLE_CAROUSEL ? 4 : 2,
    parameter integer FETCH_DATA_WIDTH = `OPENRV64_AXI_DATA_WIDTH,
    parameter integer ENABLE_TRACE = 0,
    parameter integer ENABLE_PREDECODE_TARGETS = 1,
    parameter integer ENABLE_ALT_LOOKASIDE = 0,
    parameter integer ENABLE_ALT_ARB_PRIORITY = 0,
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
    input  wire [FETCH_DATA_WIDTH-1:0] resp_data_i,
    input  wire                         resp_access_fault_i,
    input  wire                         resp_page_fault_i,
    input  wire                         resp_stash_i,
    input  wire                         resp_demand_i,

    input  wire                         branch_pair_valid_i,
    input  wire [`RV64_XLEN-1:0]        branch_predicted_addr_i,
    input  wire [`RV64_XLEN-1:0]        branch_unpredicted_addr_i,

    // A predicted redirect is an architectural replacement, not a
    // cache-warming hint. Launch its demand on the restart edge and mark it
    // as qualified stash work so the bus cancels older fetches without
    // cancelling this replacement.
    input  wire                         redirect_fetch_valid_i,
    input  wire [`RV64_XLEN-1:0]        redirect_fetch_addr_i,

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
    input  wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
                                            pair1024_resp_predicted_data_i,
    input  wire [`RV64_XLEN-1:0]        pair1024_resp_unpredicted_addr_i,
    input  wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
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

    localparam integer LINE_BYTES = FETCH_DATA_WIDTH / 8;
    localparam integer LINE_BYTE_BITS = $clog2(LINE_BYTES);
    localparam integer FETCH_SECTORS = FETCH_DATA_WIDTH / 128;
    localparam integer FETCH_SECTOR_INDEX_WIDTH =
        (FETCH_SECTORS > 1) ? $clog2(FETCH_SECTORS) : 1;
    localparam integer FETCH_ALT_CANDIDATE_WIDTH =
        FETCH_DATA_WIDTH + FETCH_SECTORS;
    localparam integer ALT_LOOKASIDE_LINES = 2;
    localparam integer ALT_SECTOR_BYTES = 16;
    localparam integer ALT_SECTOR_BYTE_BITS = $clog2(ALT_SECTOR_BYTES);
    localparam integer CACHE_LINE_BYTES =
        `OPENRV64_ICX_LINE_DATA_WIDTH / 8;
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
    localparam integer INGRESS_DEPTH = 4;
    localparam integer INGRESS_INDEX_WIDTH = $clog2(INGRESS_DEPTH);
    localparam [1:0] INGRESS_ORIGIN_DEMAND = 2'd0;
    localparam [1:0] INGRESS_ORIGIN_REDIRECT = 2'd1;
    localparam [1:0] INGRESS_ORIGIN_FAL = 2'd2;

    reg active_q;
    reg [`RV64_XLEN-1:0] consume_pc_q;
    reg [`RV64_XLEN-1:0] next_req_addr_q;
    reg line_valid_q [0:LINE_DEPTH-1];
    reg [`RV64_XLEN-1:0] line_addr_q [0:LINE_DEPTH-1];
    reg [FETCH_DATA_WIDTH-1:0] line_data_q [0:LINE_DEPTH-1];
    reg [FETCH_SECTORS-1:0] line_sector_valid_q [0:LINE_DEPTH-1];
    reg line_access_fault_q [0:LINE_DEPTH-1];
    reg line_page_fault_q [0:LINE_DEPTH-1];
    reg pending_valid_q /* verilator public_flat_rd */;
    reg [`RV64_XLEN-1:0]
        pending_addr_q /* verilator public_flat_rd */;
    reg carousel_pending_valid_q [0:LINE_DEPTH-1]
        /* verilator public_flat_rd */;
    reg [`RV64_XLEN-1:0]
        carousel_pending_addr_q [0:LINE_DEPTH-1]
        /* verilator public_flat_rd */;
    // Eight 8x32-bit fetch blocks split into two banks.  The four direct
    // entries above are populated only by fetch demand.  Every response first
    // enters this four-entry associative ingress bank, then is promoted to the
    // direct bank when the demand cursor or decoder consumes it. Redirect/FAL
    // remain independent request-owner tags, not fixed resident slots; this
    // permits two FAL halves from two back-to-back branch contexts to remain
    // resident concurrently.  They are not the two sides of one branch.
    reg ingress_valid_q [0:INGRESS_DEPTH-1]
        /* verilator public_flat_rd */;
    reg [`RV64_XLEN-1:0]
        ingress_addr_q [0:INGRESS_DEPTH-1]
        /* verilator public_flat_rd */;
    reg [FETCH_DATA_WIDTH-1:0]
        ingress_data_q [0:INGRESS_DEPTH-1]
        /* verilator public_flat_rd */;
    reg ingress_access_fault_q [0:INGRESS_DEPTH-1]
        /* verilator public_flat_rd */;
    reg ingress_page_fault_q [0:INGRESS_DEPTH-1]
        /* verilator public_flat_rd */;
    reg [1:0] ingress_origin_q [0:INGRESS_DEPTH-1]
        /* verilator public_flat_rd */;
    reg [INGRESS_INDEX_WIDTH-1:0]
        ingress_replace_q /* verilator public_flat_rd */;
    reg redirect_line_pending_q;
    reg [`RV64_XLEN-1:0] redirect_line_addr_q;
    reg fal_line_pending_q;
    reg [`RV64_XLEN-1:0] fal_line_addr_q;
    wire measurement_carousel_enabled /* verilator public_flat_rd */ =
        ENABLE_CAROUSEL != 0;

    reg pair_predicted_valid_q;
    reg pair_unpredicted_valid_q;
    reg [`RV64_XLEN-1:0] pair_predicted_addr_q;
    reg [`RV64_XLEN-1:0] pair_unpredicted_addr_q;

    reg alt_valid_q [0:ALT_LOOKASIDE_LINES-1];
    reg [`RV64_XLEN-1:0] alt_addr_q [0:ALT_LOOKASIDE_LINES-1];
    reg [FETCH_DATA_WIDTH-1:0]
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
    reg fal_prefetch_aged_r;
    reg ingress_fal_aged_r [0:INGRESS_DEPTH-1];
    integer branch_stash_index;
    integer branch_sector_index;
    integer branch_line_index;

    function automatic [ALT_PREVIEW_BITS-1:0] select_preview;
        input [FETCH_DATA_WIDTH-1:0] data;
        input [`RV64_XLEN-1:0] addr;
        reg [FETCH_SECTOR_INDEX_WIDTH-1:0] sector;
        begin
            sector = addr[ALT_SECTOR_BYTE_BITS +:
                          FETCH_SECTOR_INDEX_WIDTH];
            if (ENABLE_ALT_LOOKASIDE == 5)
                select_preview = {ALT_PREVIEW_BITS{1'b0}};
            else if (ENABLE_ALT_LOOKASIDE == 4)
                select_preview = data[255:0];
            else
                select_preview = data[sector*128 +: 128];
        end
    endfunction

    function automatic [`OPENRV64_AXI_DATA_WIDTH-1:0]
        select_cache_line_block;
        input [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] data;
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
                        branch_predicted_addr_i[ALT_SECTOR_BYTE_BITS +:
                                                FETCH_SECTOR_INDEX_WIDTH]]))) begin
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
                        branch_unpredicted_addr_i[ALT_SECTOR_BYTE_BITS +:
                                                  FETCH_SECTOR_INDEX_WIDTH]]))) begin
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

    // The live slots and alternate-path storage are one logical fetch buffer.
    // Keep the arrays physically separate, then generate a per-sector selector
    // from their tags.  Those selector bits are the mux controls feeding
    // decode.  A redirect changes consume_pc_q and therefore the selected path;
    // it does not copy alternate data into a live slot.
    //
    // The high FETCH_SECTORS bits are the alternate-resident sector mask;
    // the low FETCH_DATA_WIDTH bits are the alternate candidate block.
    function automatic [FETCH_ALT_CANDIDATE_WIDTH-1:0]
        overlay_alt_preview;
        input [FETCH_ALT_CANDIDATE_WIDTH-1:0] current;
        input source_valid;
        input [`RV64_XLEN-1:0] source_addr;
        input [ALT_PREVIEW_BITS-1:0] source_data;
        input [`RV64_XLEN-1:0] target_addr;
        reg [FETCH_SECTORS-1:0] sector_valid;
        reg [FETCH_DATA_WIDTH-1:0] block_data;
        reg [`OPENRV64_AXI_DATA_WIDTH-1:0] selected_source_block;
        reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] widened_source_data;
        reg [FETCH_SECTOR_INDEX_WIDTH-1:0] source_sector;
        begin
            sector_valid = current[FETCH_ALT_CANDIDATE_WIDTH-1 -:
                                   FETCH_SECTORS];
            block_data = current[FETCH_DATA_WIDTH-1:0];
            widened_source_data =
                {{(`OPENRV64_ICX_LINE_DATA_WIDTH-ALT_PREVIEW_BITS){1'b0}},
                 source_data};
            selected_source_block =
                select_cache_line_block(widened_source_data, target_addr);
            source_sector = source_addr[ALT_SECTOR_BYTE_BITS +:
                                        FETCH_SECTOR_INDEX_WIDTH];

            if (source_valid) begin
                if ((ENABLE_ALT_LOOKASIDE == 3) &&
                    (source_addr[`RV64_XLEN-1:LINE_BYTE_BITS] ==
                     target_addr[`RV64_XLEN-1:LINE_BYTE_BITS])) begin
                    if (!sector_valid[source_sector]) begin
                        block_data[source_sector*128 +: 128] =
                            source_data[127:0];
                        sector_valid[source_sector] = 1'b1;
                    end
                end else if ((ENABLE_ALT_LOOKASIDE == 4) &&
                             (source_addr[
                                `RV64_XLEN-1:LINE_BYTE_BITS] ==
                              target_addr[
                                `RV64_XLEN-1:LINE_BYTE_BITS])) begin
                    if (!sector_valid[0]) begin
                        block_data[127:0] = source_data[127:0];
                        sector_valid[0] = 1'b1;
                    end
                    if (!sector_valid[1]) begin
                        block_data[255:128] = source_data[255:128];
                        sector_valid[1] = 1'b1;
                    end
                end else if ((ENABLE_ALT_LOOKASIDE == 5) &&
                             (source_addr[
                                `RV64_XLEN-1:CACHE_LINE_BYTE_BITS] ==
                              target_addr[
                                `RV64_XLEN-1:CACHE_LINE_BYTE_BITS])) begin
                    if (!sector_valid[0]) begin
                        block_data[127:0] =
                            selected_source_block[127:0];
                        sector_valid[0] = 1'b1;
                    end
                    if (!sector_valid[1]) begin
                        block_data[255:128] =
                            selected_source_block[255:128];
                        sector_valid[1] = 1'b1;
                    end
                end
            end
            overlay_alt_preview = {sector_valid, block_data};
        end
    endfunction

    reg [FETCH_ALT_CANDIDATE_WIDTH-1:0] fetch_alt_candidate_r [0:1];
    reg [`RV64_XLEN-1:0] fetch_select_addr_r [0:1];
    integer fetch_select_block;
    integer fetch_select_context;
    integer fetch_select_stash;
    always @* begin
        fetch_select_addr_r[0] = consume_line_addr;
        fetch_select_addr_r[1] = following_line_addr;

        for (fetch_select_block = 0; fetch_select_block < 2;
             fetch_select_block = fetch_select_block + 1) begin
            fetch_alt_candidate_r[fetch_select_block] =
                {FETCH_ALT_CANDIDATE_WIDTH{1'b0}};

            if ((ENABLE_ALT_LOOKASIDE != 0) &&
                (ENABLE_ALT_LOOKASIDE < 3)) begin
                for (fetch_select_stash = 0;
                     fetch_select_stash < ALT_LOOKASIDE_LINES;
                     fetch_select_stash = fetch_select_stash + 1) begin
                    if (alt_valid_q[fetch_select_stash] &&
                        (alt_addr_q[fetch_select_stash][
                            `RV64_XLEN-1:LINE_BYTE_BITS] ==
                         fetch_select_addr_r[fetch_select_block][
                            `RV64_XLEN-1:LINE_BYTE_BITS]) &&
                        (fetch_alt_candidate_r[fetch_select_block][
                            FETCH_ALT_CANDIDATE_WIDTH-1 -:
                            FETCH_SECTORS] !=
                         {FETCH_SECTORS{1'b1}})) begin
                        fetch_alt_candidate_r[
                            fetch_select_block][
                                FETCH_ALT_CANDIDATE_WIDTH-1 -:
                                FETCH_SECTORS] =
                            {FETCH_SECTORS{1'b1}};
                        fetch_alt_candidate_r[
                            fetch_select_block][FETCH_DATA_WIDTH-1:0] =
                            alt_data_q[fetch_select_stash];
                    end
                end
            end else if (ENABLE_ALT_LOOKASIDE >= 3) begin
                for (fetch_select_context = 0;
                     fetch_select_context < ALT_SECTOR_CONTEXTS;
                     fetch_select_context = fetch_select_context + 1) begin
                    if (alt_sector_context_valid_q[
                            fetch_select_context]) begin
                        fetch_alt_candidate_r[fetch_select_block] =
                            overlay_alt_preview(
                                fetch_alt_candidate_r[fetch_select_block],
                                alt_sector_predicted_valid_q[
                                    fetch_select_context],
                                alt_sector_predicted_addr_q[
                                    fetch_select_context],
                                alt_sector_predicted_data_q[
                                    fetch_select_context],
                                fetch_select_addr_r[fetch_select_block]);
                        fetch_alt_candidate_r[fetch_select_block] =
                            overlay_alt_preview(
                                fetch_alt_candidate_r[fetch_select_block],
                                alt_sector_unpredicted_valid_q[
                                    fetch_select_context],
                                alt_sector_unpredicted_addr_q[
                                    fetch_select_context],
                                alt_sector_unpredicted_data_q[
                                    fetch_select_context],
                                fetch_select_addr_r[fetch_select_block]);
                    end
                end
            end
        end
    end

    wire [FETCH_SECTORS-1:0] consume_live_sector_valid =
        consume_line_tag_hit ? line_sector_valid_q[consume_slot] :
        {FETCH_SECTORS{1'b0}};
    wire [FETCH_SECTORS-1:0] following_live_sector_valid =
        following_line_tag_hit ? line_sector_valid_q[following_slot] :
        {FETCH_SECTORS{1'b0}};
    reg consume_ingress_hit_r;
    reg following_ingress_hit_r;
    reg [INGRESS_INDEX_WIDTH-1:0] consume_ingress_index_r;
    reg [INGRESS_INDEX_WIDTH-1:0] following_ingress_index_r;
    integer ingress_lookup_index;
    always @* begin
        consume_ingress_hit_r = 1'b0;
        following_ingress_hit_r = 1'b0;
        consume_ingress_index_r = {INGRESS_INDEX_WIDTH{1'b0}};
        following_ingress_index_r = {INGRESS_INDEX_WIDTH{1'b0}};
        for (ingress_lookup_index = 0;
             ingress_lookup_index < INGRESS_DEPTH;
             ingress_lookup_index = ingress_lookup_index + 1) begin
            if (!consume_ingress_hit_r &&
                ingress_valid_q[ingress_lookup_index] &&
                (ingress_addr_q[ingress_lookup_index][
                    `RV64_XLEN-1:LINE_BYTE_BITS] ==
                 consume_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS])) begin
                consume_ingress_hit_r = 1'b1;
                consume_ingress_index_r = ingress_lookup_index;
            end
            if (!following_ingress_hit_r &&
                ingress_valid_q[ingress_lookup_index] &&
                (ingress_addr_q[ingress_lookup_index][
                    `RV64_XLEN-1:LINE_BYTE_BITS] ==
                 following_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS])) begin
                following_ingress_hit_r = 1'b1;
                following_ingress_index_r = ingress_lookup_index;
            end
        end
    end
    wire [FETCH_SECTORS-1:0] consume_ingress_sector_valid =
        consume_ingress_hit_r ? {FETCH_SECTORS{1'b1}} :
        {FETCH_SECTORS{1'b0}};
    wire [FETCH_SECTORS-1:0] following_ingress_sector_valid =
        following_ingress_hit_r ? {FETCH_SECTORS{1'b1}} :
        {FETCH_SECTORS{1'b0}};
    wire [FETCH_SECTORS-1:0] consume_alt_sector_valid =
        fetch_alt_candidate_r[0][FETCH_ALT_CANDIDATE_WIDTH-1 -:
                                 FETCH_SECTORS];
    wire [FETCH_SECTORS-1:0] following_alt_sector_valid =
        fetch_alt_candidate_r[1][FETCH_ALT_CANDIDATE_WIDTH-1 -:
                                 FETCH_SECTORS];
    wire [FETCH_SECTORS-1:0] consume_ingress_select =
        (~consume_live_sector_valid) & consume_ingress_sector_valid;
    wire [FETCH_SECTORS-1:0] following_ingress_select =
        (~following_live_sector_valid) & following_ingress_sector_valid;
    wire [FETCH_SECTORS-1:0] consume_alt_select =
        (~consume_live_sector_valid) & (~consume_ingress_sector_valid) &
        consume_alt_sector_valid;
    wire [FETCH_SECTORS-1:0] following_alt_select =
        (~following_live_sector_valid) &
        (~following_ingress_sector_valid) & following_alt_sector_valid;
    wire [FETCH_SECTORS-1:0]
        consume_fetch_select /* verilator public_flat_rd */ =
        consume_ingress_select | consume_alt_select;
    wire [FETCH_SECTORS-1:0] following_fetch_select =
        following_ingress_select | following_alt_select;
    wire [FETCH_DATA_WIDTH-1:0] consume_line_data;
    wire [FETCH_DATA_WIDTH-1:0] following_line_data;
    genvar fetch_data_sector;
    generate
        for (fetch_data_sector = 0;
             fetch_data_sector < FETCH_SECTORS;
             fetch_data_sector = fetch_data_sector + 1) begin :
                g_fetch_data_sector
            assign consume_line_data[fetch_data_sector*128 +: 128] =
                consume_ingress_select[fetch_data_sector] ?
                    ingress_data_q[consume_ingress_index_r][
                        fetch_data_sector*128 +: 128] :
                consume_alt_select[fetch_data_sector] ?
                    fetch_alt_candidate_r[0][
                        fetch_data_sector*128 +: 128] :
                    line_data_q[consume_slot][
                        fetch_data_sector*128 +: 128];
            assign following_line_data[fetch_data_sector*128 +: 128] =
                following_ingress_select[fetch_data_sector] ?
                    ingress_data_q[following_ingress_index_r][
                        fetch_data_sector*128 +: 128] :
                following_alt_select[fetch_data_sector] ?
                    fetch_alt_candidate_r[1][
                        fetch_data_sector*128 +: 128] :
                    line_data_q[following_slot][
                        fetch_data_sector*128 +: 128];
        end
    endgenerate
    wire [FETCH_SECTORS-1:0] consume_sector_valid =
        consume_live_sector_valid | consume_ingress_sector_valid |
        consume_alt_sector_valid;
    wire [FETCH_SECTORS-1:0] following_sector_valid =
        following_live_sector_valid | following_ingress_sector_valid |
        following_alt_sector_valid;
    wire consume_line_hit =
        consume_sector_valid[consume_pc_q[ALT_SECTOR_BYTE_BITS +:
                                           FETCH_SECTOR_INDEX_WIDTH]];
    wire following_line_hit = following_sector_valid[0];
    wire consume_line_full = &consume_sector_valid;
    wire following_line_full = &following_sector_valid;
    // Ingress is response storage, not long-lived demand storage. Once an
    // ingress entry supplies the current fetch line, promote the full block
    // into the direct demand bank.
    wire consume_ingress_demand = |consume_ingress_select;

    // The carousel cursor walks from the consumed block through the next three
    // blocks, and each direct-mapped slot may have an independent replacement
    // pending. The selectable bridge requests only the current block and one
    // following block with a single architectural request outstanding.
    wire bridge_request_current_line = !consume_line_full;
    wire [`RV64_XLEN-1:0] bridge_request_line_addr =
        bridge_request_current_line ? consume_line_addr :
                                      following_line_addr;
    wire bridge_request_line_hit = bridge_request_current_line ?
        consume_line_full : following_line_full;
    wire [`RV64_XLEN-1:0] carousel_last_addr =
        consume_line_addr + ((LINE_DEPTH - 1) * LINE_BYTES);
    wire [LINE_INDEX_WIDTH-1:0] carousel_request_slot =
        next_req_addr_q[LINE_INDEX_MSB:LINE_INDEX_LSB];
    wire carousel_request_resident =
        line_valid_q[carousel_request_slot] &&
        (&line_sector_valid_q[carousel_request_slot]) &&
        (line_addr_q[carousel_request_slot][
            `RV64_XLEN-1:LINE_BYTE_BITS] ==
         next_req_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire carousel_request_pending =
        carousel_pending_valid_q[carousel_request_slot] &&
        (carousel_pending_addr_q[carousel_request_slot][
            `RV64_XLEN-1:LINE_BYTE_BITS] ==
         next_req_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire carousel_request_slot_busy =
        carousel_pending_valid_q[carousel_request_slot];
    reg request_ingress_hit_r;
    reg [INGRESS_INDEX_WIDTH-1:0] request_ingress_index_r;
    integer request_ingress_index;
    always @* begin
        request_ingress_hit_r = 1'b0;
        request_ingress_index_r = {INGRESS_INDEX_WIDTH{1'b0}};
        for (request_ingress_index = 0;
             request_ingress_index < INGRESS_DEPTH;
             request_ingress_index = request_ingress_index + 1) begin
            if (!request_ingress_hit_r &&
                ingress_valid_q[request_ingress_index] &&
                (ingress_addr_q[request_ingress_index][
                    `RV64_XLEN-1:LINE_BYTE_BITS] ==
                 next_req_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS])) begin
                request_ingress_hit_r = 1'b1;
                request_ingress_index_r = request_ingress_index;
            end
        end
    end
    wire redirect_request_line_pending = redirect_line_pending_q &&
        (redirect_line_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS] ==
         next_req_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire carousel_request_in_window =
        next_req_addr_q <= carousel_last_addr;
    // An ingress hit at the demand cursor satisfies a future block in the
    // active four-line window. Promote it before speculative aging or later
    // ingress traffic can remove the only copy.
    wire ingress_cursor_demand = carousel_request_in_window &&
        !carousel_request_resident && request_ingress_hit_r;
    wire [LINE_INDEX_WIDTH-1:0] consume_ingress_line_slot =
        ingress_addr_q[consume_ingress_index_r][
            LINE_INDEX_MSB:LINE_INDEX_LSB];
    wire [LINE_INDEX_WIDTH-1:0] request_ingress_line_slot =
        ingress_addr_q[request_ingress_index_r][
            LINE_INDEX_MSB:LINE_INDEX_LSB];
    wire [`RV64_XLEN-1:0] request_line_addr = ENABLE_CAROUSEL ?
        next_req_addr_q : bridge_request_line_addr;
    wire request_line_hit = ENABLE_CAROUSEL ?
        (carousel_request_resident || request_ingress_hit_r) :
        bridge_request_line_hit;
    // A stash-only FAL may be canceled or aged below this interface without
    // producing a response.  It therefore cannot satisfy demand ownership.
    wire request_line_pending = ENABLE_CAROUSEL ?
        (carousel_request_pending || redirect_request_line_pending) :
        pending_valid_q;
    wire pair_request_valid = pair_predicted_valid_q ||
                              pair_unpredicted_valid_q;
    wire [`RV64_XLEN-1:0] pair_request_addr =
        pair_predicted_valid_q ? pair_predicted_addr_q :
                                 pair_unpredicted_addr_q;
    wire pair_request_is_demand = pair_request_valid &&
        !request_line_pending && !request_line_hit &&
        (!ENABLE_CAROUSEL || !carousel_request_slot_busy) &&
        (pair_request_addr[`RV64_XLEN-1:LINE_BYTE_BITS] ==
         request_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire [`RV64_XLEN-1:0] redirect_request_addr = {
        redirect_fetch_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS],
        {LINE_BYTE_BITS{1'b0}}
    };
    wire [LINE_INDEX_WIDTH-1:0] redirect_request_slot =
        redirect_request_addr[LINE_INDEX_MSB:LINE_INDEX_LSB];
    wire redirect_request_line_hit =
        line_valid_q[redirect_request_slot] &&
        (&line_sector_valid_q[redirect_request_slot]) &&
        (line_addr_q[redirect_request_slot][
            `RV64_XLEN-1:LINE_BYTE_BITS] ==
         redirect_request_addr[`RV64_XLEN-1:LINE_BYTE_BITS]);
    reg redirect_request_ingress_hit_r;
    reg pair_request_ingress_hit_r;
    integer side_ingress_index;
    always @* begin
        redirect_request_ingress_hit_r = 1'b0;
        pair_request_ingress_hit_r = 1'b0;
        for (side_ingress_index = 0;
             side_ingress_index < INGRESS_DEPTH;
             side_ingress_index = side_ingress_index + 1) begin
            if (ingress_valid_q[side_ingress_index] &&
                (ingress_addr_q[side_ingress_index][
                    `RV64_XLEN-1:LINE_BYTE_BITS] ==
                 redirect_request_addr[`RV64_XLEN-1:LINE_BYTE_BITS]))
                redirect_request_ingress_hit_r = 1'b1;
            if (ingress_valid_q[side_ingress_index] &&
                (ingress_addr_q[side_ingress_index][
                    `RV64_XLEN-1:LINE_BYTE_BITS] ==
                 pair_request_addr[`RV64_XLEN-1:LINE_BYTE_BITS]))
                pair_request_ingress_hit_r = 1'b1;
        end
    end
    wire redirect_request_side_hit = redirect_request_ingress_hit_r;
    wire redirect_request_side_pending =
        redirect_line_pending_q &&
        (redirect_line_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS] ==
         redirect_request_addr[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire redirect_request_valid = redirect_fetch_valid_i && restart_i &&
                                  !invalidate_i && !flush_i && !stall_i &&
                                  !redirect_request_line_hit &&
                                  !redirect_request_side_hit &&
                                  !redirect_request_side_pending;
    wire incoming_pair_line_hit =
        ((ENABLE_ALT_LOOKASIDE == 4) && pair512_resp_valid_i &&
         ((pair512_resp_predicted_addr_i[
            `RV64_XLEN-1:LINE_BYTE_BITS] ==
           request_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS]) ||
          (pair512_resp_unpredicted_addr_i[
            `RV64_XLEN-1:LINE_BYTE_BITS] ==
           request_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS]))) ||
        ((ENABLE_ALT_LOOKASIDE == 5) && pair1024_resp_valid_i &&
         ((pair1024_resp_predicted_addr_i[
            `RV64_XLEN-1:CACHE_LINE_BYTE_BITS] ==
           request_line_addr[`RV64_XLEN-1:CACHE_LINE_BYTE_BITS]) ||
          (pair1024_resp_unpredicted_addr_i[
            `RV64_XLEN-1:CACHE_LINE_BYTE_BITS] ==
           request_line_addr[`RV64_XLEN-1:CACHE_LINE_BYTE_BITS])));
    wire demand_request_needed =
                                 (!ENABLE_CAROUSEL ||
                                  carousel_request_in_window) &&
                                 !request_line_pending &&
                                 (!ENABLE_CAROUSEL ||
                                  !carousel_request_slot_busy) &&
                                 !request_line_hit &&
                                 !incoming_pair_line_hit;
    wire pair_request_side_match =
        pair_request_ingress_hit_r ||
        (redirect_line_pending_q &&
         (redirect_line_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS] ==
          pair_request_addr[`RV64_XLEN-1:LINE_BYTE_BITS])) ||
        (fal_line_pending_q &&
         (fal_line_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS] ==
          pair_request_addr[`RV64_XLEN-1:LINE_BYTE_BITS]));
    wire pair_request_coalesced = pair_request_valid &&
                                  pair_request_side_match;
    wire fal_line_busy_for_pair = fal_line_pending_q &&
        (fal_line_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS] !=
         pair_request_addr[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire pair_request_select = pair_request_valid &&
        !pair_request_coalesced && !fal_line_busy_for_pair &&
        ((ENABLE_ALT_LOOKASIDE < 3) || ENABLE_ALT_ARB_PRIORITY ||
         !demand_request_needed ||
         pair_request_is_demand);
    wire demand_request_valid = !pair_request_select &&
                                demand_request_needed;
    assign req_valid_o = active_q &&
        (redirect_request_valid ||
         (!restart_i && !invalidate_i && !flush_i && !stall_i &&
          (pair_request_select || demand_request_valid)));
    assign req_addr_o = redirect_request_valid ? redirect_request_addr :
                        (pair_request_select ? pair_request_addr :
                                               request_line_addr);
    assign req_stash_o = redirect_request_valid || pair_request_select;
    assign req_demand_o = redirect_request_valid ||
                          !pair_request_select ||
                          pair_request_is_demand;
    wire req_fire = req_valid_o && req_ready_i;
    wire redirect_req_fire = req_fire && redirect_request_valid;
    wire pair_req_fire = req_fire && pair_request_select;
    wire pair_req_done = pair_req_fire || pair_request_coalesced;
    wire request_line_issued = req_fire && req_demand_o &&
        (req_addr_o[`RV64_XLEN-1:LINE_BYTE_BITS] ==
         request_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire carousel_advance = ENABLE_CAROUSEL && active_q &&
        !restart_i && !invalidate_i && !flush_i && !stall_i &&
        carousel_request_in_window &&
        (request_line_hit || request_line_pending ||
         incoming_pair_line_hit || request_line_issued);
    wire alt_sector_background_deferred =
        (ENABLE_ALT_LOOKASIDE == 3) && pair_request_valid &&
        demand_request_needed && !pair_request_is_demand &&
        !pair_request_select;
    wire pair_predicted_after_fire = pair_predicted_valid_q &&
        !(pair_req_done && pair_predicted_valid_q);
    wire pair_unpredicted_after_fire = pair_unpredicted_valid_q &&
        !(pair_req_done && !pair_predicted_valid_q &&
          pair_unpredicted_valid_q);
    wire pair_remains_after_fire = pair_predicted_after_fire ||
                                   pair_unpredicted_after_fire;
    wire [LINE_COUNT_WIDTH-1:0] bridge_line_count =
        {{(LINE_COUNT_WIDTH-1){1'b0}}, consume_line_hit} +
        {{(LINE_COUNT_WIDTH-1){1'b0}}, following_line_hit} +
        {{(LINE_COUNT_WIDTH-1){1'b0}}, pending_valid_q};
    reg [LINE_COUNT_WIDTH-1:0] carousel_line_count_r;
    reg carousel_pending_any_r;
    integer carousel_count_index;
    always @* begin
        carousel_line_count_r = {LINE_COUNT_WIDTH{1'b0}};
        carousel_pending_any_r = 1'b0;
        for (carousel_count_index = 0;
             carousel_count_index < LINE_DEPTH;
             carousel_count_index = carousel_count_index + 1) begin
            if (line_valid_q[carousel_count_index] ||
                carousel_pending_valid_q[carousel_count_index])
                carousel_line_count_r = carousel_line_count_r + 1'b1;
            if (carousel_pending_valid_q[carousel_count_index])
                carousel_pending_any_r = 1'b1;
        end
    end
    assign line_count_o = ENABLE_CAROUSEL ?
        carousel_line_count_r : bridge_line_count;
    wire demand_pending_any = ENABLE_CAROUSEL ?
        carousel_pending_any_r : pending_valid_q;
    wire consume_line_pending = ENABLE_CAROUSEL ?
        (carousel_pending_valid_q[consume_slot] &&
         (carousel_pending_addr_q[consume_slot][
            `RV64_XLEN-1:LINE_BYTE_BITS] ==
          consume_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS])) :
        (pending_valid_q &&
         (pending_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS] ==
          consume_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS]));

    reg [2:0] lane_found_r;
    reg [3*`RV64_INSTR_WIDTH-1:0] lane_instr_r;
    reg [2:0] lane_access_fault_r;
    reg [2:0] lane_page_fault_r;
    reg [`RV64_XLEN-1:0] lane_pc_r [0:2];
    integer lane_index;
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
                consume_sector_valid[
                    lane_pc_r[lane_index][ALT_SECTOR_BYTE_BITS +:
                                           FETCH_SECTOR_INDEX_WIDTH]]) begin
                lane_found_r[lane_index] = 1'b1;
                lane_instr_r[lane_index*`RV64_INSTR_WIDTH +:
                             `RV64_INSTR_WIDTH] =
                    ((consume_ingress_select[
                        lane_pc_r[lane_index][ALT_SECTOR_BYTE_BITS +:
                                               FETCH_SECTOR_INDEX_WIDTH]] &&
                      (ingress_access_fault_q[consume_ingress_index_r] ||
                       ingress_page_fault_q[consume_ingress_index_r])) ||
                     (!consume_fetch_select[
                        lane_pc_r[lane_index][ALT_SECTOR_BYTE_BITS +:
                                               FETCH_SECTOR_INDEX_WIDTH]] &&
                      (line_access_fault_q[consume_slot] ||
                       line_page_fault_q[consume_slot]))) ?
                    `RV64_INSTR_NOP : consume_line_data[
                        lane_pc_r[lane_index][LINE_BYTE_BITS-1:2] *
                        `RV64_INSTR_WIDTH +: `RV64_INSTR_WIDTH];
                lane_access_fault_r[lane_index] =
                    (consume_ingress_select[
                        lane_pc_r[lane_index][ALT_SECTOR_BYTE_BITS +:
                                               FETCH_SECTOR_INDEX_WIDTH]] &&
                     ingress_access_fault_q[consume_ingress_index_r]) ||
                    (!consume_fetch_select[
                        lane_pc_r[lane_index][ALT_SECTOR_BYTE_BITS +:
                                               FETCH_SECTOR_INDEX_WIDTH]] &&
                     line_access_fault_q[consume_slot]);
                lane_page_fault_r[lane_index] =
                    (consume_ingress_select[
                        lane_pc_r[lane_index][ALT_SECTOR_BYTE_BITS +:
                                               FETCH_SECTOR_INDEX_WIDTH]] &&
                     ingress_page_fault_q[consume_ingress_index_r]) ||
                    (!consume_fetch_select[
                        lane_pc_r[lane_index][ALT_SECTOR_BYTE_BITS +:
                                               FETCH_SECTOR_INDEX_WIDTH]] &&
                     line_page_fault_q[consume_slot]);
            end else if ((lane_pc_r[lane_index][
                           `RV64_XLEN-1:LINE_BYTE_BITS] ==
                          following_line_addr[
                           `RV64_XLEN-1:LINE_BYTE_BITS]) &&
                         following_sector_valid[
                            lane_pc_r[lane_index][
                                ALT_SECTOR_BYTE_BITS +:
                                FETCH_SECTOR_INDEX_WIDTH]]) begin
                lane_found_r[lane_index] = 1'b1;
                lane_instr_r[lane_index*`RV64_INSTR_WIDTH +:
                             `RV64_INSTR_WIDTH] =
                    ((following_ingress_select[
                        lane_pc_r[lane_index][ALT_SECTOR_BYTE_BITS +:
                                               FETCH_SECTOR_INDEX_WIDTH]] &&
                      (ingress_access_fault_q[
                            following_ingress_index_r] ||
                       ingress_page_fault_q[
                            following_ingress_index_r])) ||
                     (!following_fetch_select[
                        lane_pc_r[lane_index][ALT_SECTOR_BYTE_BITS +:
                                               FETCH_SECTOR_INDEX_WIDTH]] &&
                      (line_access_fault_q[following_slot] ||
                       line_page_fault_q[following_slot]))) ?
                    `RV64_INSTR_NOP : following_line_data[
                        lane_pc_r[lane_index][LINE_BYTE_BITS-1:2] *
                        `RV64_INSTR_WIDTH +: `RV64_INSTR_WIDTH];
                lane_access_fault_r[lane_index] =
                    (following_ingress_select[
                        lane_pc_r[lane_index][ALT_SECTOR_BYTE_BITS +:
                                               FETCH_SECTOR_INDEX_WIDTH]] &&
                     ingress_access_fault_q[
                        following_ingress_index_r]) ||
                    (!following_fetch_select[
                        lane_pc_r[lane_index][ALT_SECTOR_BYTE_BITS +:
                                               FETCH_SECTOR_INDEX_WIDTH]] &&
                     line_access_fault_q[following_slot]);
                lane_page_fault_r[lane_index] =
                    (following_ingress_select[
                        lane_pc_r[lane_index][ALT_SECTOR_BYTE_BITS +:
                                               FETCH_SECTOR_INDEX_WIDTH]] &&
                     ingress_page_fault_q[
                        following_ingress_index_r]) ||
                    (!following_fetch_select[
                        lane_pc_r[lane_index][ALT_SECTOR_BYTE_BITS +:
                                               FETCH_SECTOR_INDEX_WIDTH]] &&
                     line_page_fault_q[following_slot]);
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
    wire bridge_resp_match = resp_demand_i && pending_valid_q &&
        (pending_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS] ==
         resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire carousel_resp_match = resp_demand_i &&
        carousel_pending_valid_q[resp_slot] &&
        (carousel_pending_addr_q[resp_slot][
            `RV64_XLEN-1:LINE_BYTE_BITS] ==
         resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire redirect_resp_match = ENABLE_CAROUSEL && resp_stash_i &&
        resp_demand_i && redirect_line_pending_q &&
        (redirect_line_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS] ==
         resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire fal_resp_match = ENABLE_CAROUSEL && resp_stash_i &&
        !redirect_resp_match &&
        fal_line_pending_q &&
        (fal_line_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS] ==
         resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire [`RV64_XLEN-1:0] resp_line_addr = {
        resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS],
        {LINE_BYTE_BITS{1'b0}}
    };
    wire carousel_resp_in_window /* verilator public_flat_rd */ = active_q &&
        (resp_line_addr >= consume_line_addr) &&
        (resp_line_addr <= carousel_last_addr);
    wire orphan_forced_demand_in_window = ENABLE_CAROUSEL &&
        resp_stash_i && resp_demand_i &&
        !redirect_resp_match && !fal_resp_match &&
        carousel_resp_in_window;
    wire resp_match /* verilator public_flat_rd */ =
        ENABLE_CAROUSEL ?
            (carousel_resp_match || redirect_resp_match || fal_resp_match ||
             orphan_forced_demand_in_window) :
            bridge_resp_match;

    // All carousel responses land in the associative ingress bank. Prefer an
    // existing tag, then an invalid entry, then an entry outside the current
    // demand window. Never evict a live-window ingress line for speculative or
    // late traffic; four distinct live-window lines already cover the whole
    // demand window, so a useful fifth line cannot exist without a tag match.
    reg ingress_alloc_valid_r;
    reg ingress_alloc_new_r;
    reg [INGRESS_INDEX_WIDTH-1:0] ingress_alloc_index_r;
    reg [1:0] ingress_resp_origin_r;
    integer ingress_alloc_scan;
    integer ingress_alloc_candidate;
    always @* begin
        ingress_alloc_valid_r = 1'b0;
        ingress_alloc_new_r = 1'b0;
        ingress_alloc_index_r = {INGRESS_INDEX_WIDTH{1'b0}};
        // One completion may satisfy both a speculative FAL owner and the
        // durable demand owner installed when that line reached the cursor.
        // Demand wins that simultaneous match; otherwise later FAL aging
        // could discard a line whose demand request already completed.
        ingress_resp_origin_r =
            carousel_resp_match ? INGRESS_ORIGIN_DEMAND :
            (redirect_resp_match ? INGRESS_ORIGIN_REDIRECT :
             (fal_resp_match ? INGRESS_ORIGIN_FAL :
                               INGRESS_ORIGIN_DEMAND));

        for (ingress_alloc_scan = 0;
             ingress_alloc_scan < INGRESS_DEPTH;
             ingress_alloc_scan = ingress_alloc_scan + 1) begin
            if (!ingress_alloc_valid_r &&
                ingress_valid_q[ingress_alloc_scan] &&
                (ingress_addr_q[ingress_alloc_scan][
                    `RV64_XLEN-1:LINE_BYTE_BITS] ==
                 resp_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS])) begin
                ingress_alloc_valid_r = 1'b1;
                ingress_alloc_index_r = ingress_alloc_scan;
            end
        end

        for (ingress_alloc_scan = 0;
             ingress_alloc_scan < INGRESS_DEPTH;
             ingress_alloc_scan = ingress_alloc_scan + 1) begin
            ingress_alloc_candidate =
                (ingress_replace_q + ingress_alloc_scan) &
                (INGRESS_DEPTH - 1);
            if (!ingress_alloc_valid_r &&
                !ingress_valid_q[ingress_alloc_candidate]) begin
                ingress_alloc_valid_r = 1'b1;
                ingress_alloc_new_r = 1'b1;
                ingress_alloc_index_r = ingress_alloc_candidate;
            end
        end

        for (ingress_alloc_scan = 0;
             ingress_alloc_scan < INGRESS_DEPTH;
             ingress_alloc_scan = ingress_alloc_scan + 1) begin
            ingress_alloc_candidate =
                (ingress_replace_q + ingress_alloc_scan) &
                (INGRESS_DEPTH - 1);
            if (!ingress_alloc_valid_r &&
                (!active_q ||
                 (ingress_addr_q[ingress_alloc_candidate] <
                    consume_line_addr) ||
                 (ingress_addr_q[ingress_alloc_candidate] >
                    carousel_last_addr))) begin
                ingress_alloc_valid_r = 1'b1;
                ingress_alloc_new_r = 1'b1;
                ingress_alloc_index_r = ingress_alloc_candidate;
            end
        end

        // A later duplicate response may have weaker ownership than the copy
        // already resident under the same tag.  In particular, a speculative
        // FAL response must not downgrade demanded data back to FAL, because
        // the next branch-age event would then discard the only useful copy.
        // Demand is strongest, redirect ownership is non-ageable, and FAL is
        // weakest.
        if (ingress_alloc_valid_r && !ingress_alloc_new_r) begin
            if ((ingress_origin_q[ingress_alloc_index_r] ==
                    INGRESS_ORIGIN_DEMAND) ||
                (ingress_resp_origin_r == INGRESS_ORIGIN_DEMAND))
                ingress_resp_origin_r = INGRESS_ORIGIN_DEMAND;
            else if ((ingress_origin_q[ingress_alloc_index_r] ==
                        INGRESS_ORIGIN_REDIRECT) ||
                     (ingress_resp_origin_r == INGRESS_ORIGIN_REDIRECT))
                ingress_resp_origin_r = INGRESS_ORIGIN_REDIRECT;
            else
                ingress_resp_origin_r = INGRESS_ORIGIN_FAL;
        end
    end

    reg alt_restart_hit_r;
    reg alt_restart_context_match_r;
    reg alt_restart_target_pending_r;
    reg alt_fill_match_r;
    reg alt_fill_slot_r;
    reg alt_free_found_r;
    integer alt_index;
    integer alt_age_port;
    integer fal_age_port;
    integer ingress_age_index;
    integer alt_pending_index;
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

        // FAL ownership is speculative. Retirement may age the downstream
        // stash request without returning a fetch response. Resident FAL
        // lines are aged independently so back-to-back branch contexts may
        // coexist in ingress.
        fal_prefetch_aged_r = 1'b0;
        for (ingress_age_index = 0;
             ingress_age_index < INGRESS_DEPTH;
             ingress_age_index = ingress_age_index + 1)
            ingress_fal_aged_r[ingress_age_index] = 1'b0;
        for (fal_age_port = 0; fal_age_port < 3;
             fal_age_port = fal_age_port + 1) begin
            if (prefetch_age_valid_i[fal_age_port] &&
                (prefetch_age_addr_i[
                    fal_age_port*`RV64_XLEN + 6 +:
                    `RV64_XLEN-6] ==
                 fal_line_addr_q[6 +: `RV64_XLEN-6]))
                fal_prefetch_aged_r = 1'b1;
            for (ingress_age_index = 0;
                 ingress_age_index < INGRESS_DEPTH;
                 ingress_age_index = ingress_age_index + 1) begin
                if (prefetch_age_valid_i[fal_age_port] &&
                    ingress_valid_q[ingress_age_index] &&
                    (ingress_origin_q[ingress_age_index] ==
                        INGRESS_ORIGIN_FAL) &&
                    (prefetch_age_addr_i[
                        fal_age_port*`RV64_XLEN + 6 +:
                        `RV64_XLEN-6] ==
                     ingress_addr_q[ingress_age_index][
                        6 +: `RV64_XLEN-6]))
                    ingress_fal_aged_r[ingress_age_index] = 1'b1;
            end
        end

        alt_restart_hit_r = 1'b0;
        alt_restart_context_match_r = 1'b0;
        alt_restart_target_pending_r = 1'b0;
        if (fal_line_pending_q &&
            (fal_line_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS] ==
             restart_pc_i[`RV64_XLEN-1:LINE_BYTE_BITS]))
            alt_restart_target_pending_r = 1'b1;
        for (alt_pending_index = 0;
             alt_pending_index < LINE_DEPTH;
             alt_pending_index = alt_pending_index + 1) begin
            if (carousel_pending_valid_q[alt_pending_index] &&
                (carousel_pending_addr_q[alt_pending_index][
                    `RV64_XLEN-1:LINE_BYTE_BITS] ==
                 restart_pc_i[`RV64_XLEN-1:LINE_BYTE_BITS]))
                alt_restart_target_pending_r = 1'b1;
        end
        if ((ENABLE_ALT_LOOKASIDE != 0) && alt_restart_eligible_i &&
            !invalidate_i && !flush_i) begin
            if (ENABLE_ALT_LOOKASIDE >= 3) begin
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
                            `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS])))
                        alt_restart_context_match_r = 1'b1;
                    if (alt_sector_context_valid_q[alt_index] &&
                        alt_sector_predicted_valid_q[alt_index] &&
                        (alt_sector_predicted_addr_q[alt_index][
                            `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS] ==
                         restart_pc_i[
                            `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS]))
                        alt_restart_hit_r = 1'b1;
                    if (alt_sector_context_valid_q[alt_index] &&
                        alt_sector_unpredicted_valid_q[alt_index] &&
                        (alt_sector_unpredicted_addr_q[alt_index][
                            `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS] ==
                         restart_pc_i[
                            `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS]))
                        alt_restart_hit_r = 1'b1;
                end
                // A tracked sector arriving on the redirect edge is selected
                // from alternate storage after this edge.
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
                                `RV64_XLEN-1:ALT_PREVIEW_BYTE_BITS])))
                            alt_restart_hit_r = 1'b1;
                    end
                end
                if ((ENABLE_ALT_LOOKASIDE == 4) &&
                    pair512_resp_valid_i &&
                    (pair512_resp_predicted_addr_i[
                        `RV64_XLEN-1:LINE_BYTE_BITS] ==
                     restart_pc_i[
                        `RV64_XLEN-1:LINE_BYTE_BITS]))
                    alt_restart_hit_r = 1'b1;
                if ((ENABLE_ALT_LOOKASIDE == 4) &&
                    pair512_resp_valid_i &&
                    (pair512_resp_unpredicted_addr_i[
                        `RV64_XLEN-1:LINE_BYTE_BITS] ==
                     restart_pc_i[
                        `RV64_XLEN-1:LINE_BYTE_BITS]))
                    alt_restart_hit_r = 1'b1;
                if ((ENABLE_ALT_LOOKASIDE == 5) &&
                    pair1024_resp_valid_i &&
                    (pair1024_resp_predicted_addr_i[
                        `RV64_XLEN-1:CACHE_LINE_BYTE_BITS] ==
                     restart_pc_i[
                        `RV64_XLEN-1:CACHE_LINE_BYTE_BITS]))
                    alt_restart_hit_r = 1'b1;
                if ((ENABLE_ALT_LOOKASIDE == 5) &&
                    pair1024_resp_valid_i &&
                    (pair1024_resp_unpredicted_addr_i[
                        `RV64_XLEN-1:CACHE_LINE_BYTE_BITS] ==
                     restart_pc_i[
                        `RV64_XLEN-1:CACHE_LINE_BYTE_BITS]))
                    alt_restart_hit_r = 1'b1;
            end else begin
                for (alt_index = 0; alt_index < ALT_LOOKASIDE_LINES;
                    alt_index = alt_index + 1) begin
                    if (alt_valid_q[alt_index] &&
                        (alt_addr_q[alt_index][`RV64_XLEN-1:
                                                    LINE_BYTE_BITS] ==
                         restart_pc_i[
                            `RV64_XLEN-1:LINE_BYTE_BITS]))
                        alt_restart_hit_r = 1'b1;
                end
                // A qualified standard response coincident with the redirect
                // enters alternate storage on the redirect edge.
                if (resp_valid_i && resp_stash_i &&
                    !resp_access_fault_i && !resp_page_fault_i &&
                    !alt_prefetch_aged_r &&
                    (resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS] ==
                     restart_pc_i[`RV64_XLEN-1:LINE_BYTE_BITS]))
                    alt_restart_hit_r = 1'b1;
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
                    {FETCH_DATA_WIDTH{1'b0}};
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
                    if (pair_req_done) begin
                        if (pair_predicted_valid_q)
                            pair_predicted_valid_q <= 1'b0;
                        else
                            pair_unpredicted_valid_q <= 1'b0;
                    end
                    if ((ENABLE_ALT_LOOKASIDE != 0) &&
                        branch_pair_valid_i) begin
                        // Mode 3 explicitly launches the missing predicted
                        // block as demand.  After a predicted redirect it
                        // matches request_line_addr and therefore wins over
                        // the background alternate request; its response
                        // populates normal fetch storage as well as the FAL
                        // context.  The unpredicted side remains stash work.
                        pair_predicted_valid_q <=
                            (ENABLE_ALT_LOOKASIDE == 3) ?
                                (!branch_sector_context_match_r &&
                                 !branch_predicted_sector_source_valid_r) :
                            (ENABLE_ALT_LOOKASIDE >= 4) ?
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
                    // Keep the stacked-pair implementation identical to the
                    // single-pair path: mode 3 fetches the missing predicted
                    // block as demand and defers the alternate as stash work.
                    pair_predicted_valid_q <=
                        (ENABLE_ALT_LOOKASIDE == 3) ?
                            (!branch_sector_context_match_r &&
                             !branch_predicted_sector_source_valid_r) :
                        (ENABLE_ALT_LOOKASIDE >= 4) ?
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
                end else if (pair_req_done) begin
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
            next_req_addr_q <= {`RV64_XLEN{1'b0}};
            pending_valid_q <= 1'b0;
            pending_addr_q <= {`RV64_XLEN{1'b0}};
            redirect_line_pending_q <= 1'b0;
            redirect_line_addr_q <= {`RV64_XLEN{1'b0}};
            fal_line_pending_q <= 1'b0;
            fal_line_addr_q <= {`RV64_XLEN{1'b0}};
            ingress_replace_q <= {INGRESS_INDEX_WIDTH{1'b0}};
            for (reset_index = 0; reset_index < LINE_DEPTH;
                 reset_index = reset_index + 1) begin
                line_valid_q[reset_index] <= 1'b0;
                line_addr_q[reset_index] <= {`RV64_XLEN{1'b0}};
                line_data_q[reset_index] <=
                    {FETCH_DATA_WIDTH{1'b0}};
                line_sector_valid_q[reset_index] <=
                    {FETCH_SECTORS{1'b0}};
                line_access_fault_q[reset_index] <= 1'b0;
                line_page_fault_q[reset_index] <= 1'b0;
                carousel_pending_valid_q[reset_index] <= 1'b0;
                carousel_pending_addr_q[reset_index] <=
                    {`RV64_XLEN{1'b0}};
            end
            for (reset_index = 0; reset_index < INGRESS_DEPTH;
                 reset_index = reset_index + 1) begin
                ingress_valid_q[reset_index] <= 1'b0;
                ingress_addr_q[reset_index] <= {`RV64_XLEN{1'b0}};
                ingress_data_q[reset_index] <=
                    {FETCH_DATA_WIDTH{1'b0}};
                ingress_access_fault_q[reset_index] <= 1'b0;
                ingress_page_fault_q[reset_index] <= 1'b0;
                ingress_origin_q[reset_index] <= INGRESS_ORIGIN_DEMAND;
            end
        end else if (restart_i) begin
            active_q <= 1'b1;
            consume_pc_q <= restart_pc_i;
            next_req_addr_q <= {
                restart_pc_i[`RV64_XLEN-1:LINE_BYTE_BITS],
                {LINE_BYTE_BITS{1'b0}}
            };
            pending_valid_q <= !ENABLE_CAROUSEL && redirect_req_fire;
            if (!ENABLE_CAROUSEL && redirect_req_fire)
                pending_addr_q <= redirect_request_addr;
            // Redirect only changes the logical fetch selection.  Tag lookup
            // above chooses live or alternate storage for the new PC.  A
            // context-changing restart still invalidates every resident path.
            if (invalidate_i || flush_i) begin
                redirect_line_pending_q <= 1'b0;
                fal_line_pending_q <= 1'b0;
                for (reset_index = 0; reset_index < LINE_DEPTH;
                     reset_index = reset_index + 1) begin
                    line_valid_q[reset_index] <= 1'b0;
                    line_sector_valid_q[reset_index] <=
                        {FETCH_SECTORS{1'b0}};
                end
                for (reset_index = 0; reset_index < INGRESS_DEPTH;
                     reset_index = reset_index + 1)
                    ingress_valid_q[reset_index] <= 1'b0;
            end
            for (reset_index = 0; reset_index < LINE_DEPTH;
                 reset_index = reset_index + 1)
                carousel_pending_valid_q[reset_index] <= 1'b0;
            if (ENABLE_CAROUSEL && !invalidate_i && !flush_i) begin
                redirect_line_pending_q <= redirect_req_fire;
                if (redirect_req_fire)
                    redirect_line_addr_q <= redirect_request_addr;
            end
        end else if (flush_i || invalidate_i) begin
            if (flush_i)
                active_q <= 1'b0;
            pending_valid_q <= 1'b0;
            redirect_line_pending_q <= 1'b0;
            fal_line_pending_q <= 1'b0;
            for (reset_index = 0; reset_index < LINE_DEPTH;
                 reset_index = reset_index + 1) begin
                line_valid_q[reset_index] <= 1'b0;
                line_sector_valid_q[reset_index] <=
                    {FETCH_SECTORS{1'b0}};
                carousel_pending_valid_q[reset_index] <= 1'b0;
            end
            for (reset_index = 0; reset_index < INGRESS_DEPTH;
                 reset_index = reset_index + 1)
                ingress_valid_q[reset_index] <= 1'b0;
        end else begin
            if (ENABLE_CAROUSEL && consume_ingress_demand) begin
                line_valid_q[consume_ingress_line_slot] <= 1'b1;
                line_addr_q[consume_ingress_line_slot] <=
                    ingress_addr_q[consume_ingress_index_r];
                line_data_q[consume_ingress_line_slot] <=
                    ingress_data_q[consume_ingress_index_r];
                line_sector_valid_q[consume_ingress_line_slot] <=
                    {FETCH_SECTORS{1'b1}};
                line_access_fault_q[consume_ingress_line_slot] <=
                    ingress_access_fault_q[consume_ingress_index_r];
                line_page_fault_q[consume_ingress_line_slot] <=
                    ingress_page_fault_q[consume_ingress_index_r];
                ingress_valid_q[consume_ingress_index_r] <= 1'b0;
            end
            if (ENABLE_CAROUSEL && ingress_cursor_demand) begin
                line_valid_q[request_ingress_line_slot] <= 1'b1;
                line_addr_q[request_ingress_line_slot] <=
                    ingress_addr_q[request_ingress_index_r];
                line_data_q[request_ingress_line_slot] <=
                    ingress_data_q[request_ingress_index_r];
                line_sector_valid_q[request_ingress_line_slot] <=
                    {FETCH_SECTORS{1'b1}};
                line_access_fault_q[request_ingress_line_slot] <=
                    ingress_access_fault_q[request_ingress_index_r];
                line_page_fault_q[request_ingress_line_slot] <=
                    ingress_page_fault_q[request_ingress_index_r];
                ingress_valid_q[request_ingress_index_r] <= 1'b0;
            end
            for (reset_index = 0; reset_index < INGRESS_DEPTH;
                 reset_index = reset_index + 1) begin
                if (ENABLE_CAROUSEL &&
                    ingress_fal_aged_r[reset_index])
                    ingress_valid_q[reset_index] <= 1'b0;
            end
            if (ENABLE_CAROUSEL && fal_prefetch_aged_r)
                fal_line_pending_q <= 1'b0;
            if (req_fire && req_demand_o &&
                (!ENABLE_CAROUSEL ||
                 !redirect_req_fire)) begin
                if (ENABLE_CAROUSEL) begin
                    carousel_pending_valid_q[
                        req_addr_o[
                            LINE_INDEX_MSB:LINE_INDEX_LSB]] <= 1'b1;
                    carousel_pending_addr_q[
                        req_addr_o[
                            LINE_INDEX_MSB:LINE_INDEX_LSB]] <= req_addr_o;
                end else begin
                    pending_valid_q <= 1'b1;
                    pending_addr_q <= req_addr_o;
                end
            end
            if (ENABLE_CAROUSEL && pair_req_fire) begin
                fal_line_pending_q <= 1'b1;
                fal_line_addr_q <= req_addr_o;
            end
            if (carousel_advance)
                next_req_addr_q <= next_req_addr_q + LINE_BYTES;
            if (resp_valid_i) begin
                if (ENABLE_CAROUSEL && redirect_resp_match) begin
                    redirect_line_pending_q <= 1'b0;
                    redirect_line_addr_q <= resp_line_addr;
                end
                if (ENABLE_CAROUSEL && fal_resp_match) begin
                    fal_line_pending_q <= 1'b0;
                    fal_line_addr_q <= resp_line_addr;
                end
                if (ENABLE_CAROUSEL && carousel_resp_match)
                    carousel_pending_valid_q[resp_slot] <= 1'b0;
                if (ENABLE_CAROUSEL && resp_match &&
                    ingress_alloc_valid_r) begin
                    ingress_valid_q[ingress_alloc_index_r] <= 1'b1;
                    ingress_addr_q[ingress_alloc_index_r] <=
                        resp_line_addr;
                    ingress_data_q[ingress_alloc_index_r] <= resp_data_i;
                    ingress_access_fault_q[ingress_alloc_index_r] <=
                        resp_access_fault_i;
                    ingress_page_fault_q[ingress_alloc_index_r] <=
                        resp_page_fault_i;
                    ingress_origin_q[ingress_alloc_index_r] <=
                        ingress_resp_origin_r;
                    if (ingress_alloc_new_r)
                        ingress_replace_q <=
                            ingress_alloc_index_r + 1'b1;
                end else if (!ENABLE_CAROUSEL &&
                             bridge_resp_match) begin
                    pending_valid_q <= 1'b0;
                    line_valid_q[resp_slot] <= 1'b1;
                    line_addr_q[resp_slot] <= resp_line_addr;
                    line_data_q[resp_slot] <= resp_data_i;
                    line_sector_valid_q[resp_slot] <=
                        {FETCH_SECTORS{1'b1}};
                    line_access_fault_q[resp_slot] <=
                        resp_access_fault_i;
                    line_page_fault_q[resp_slot] <=
                        resp_page_fault_i;
                end
            end
            if (decode_count != 0)
                consume_pc_q <= next_consume_pc;
        end
    end

`ifndef SYNTHESIS
    openrv64_fetch_debug_stub #(
        .LINE_DEPTH(LINE_DEPTH),
        .INGRESS_DEPTH(INGRESS_DEPTH),
        .FETCH_SECTORS(FETCH_SECTORS)
    ) u_debug (
        .consume_pc_q(consume_pc_q),
        .next_req_addr_q(next_req_addr_q),
        .pending_valid_q(pending_valid_q),
        .pending_addr_q(pending_addr_q),
        .pair_request_select(pair_request_select),
        .demand_request_needed(demand_request_needed),
        .request_line_hit(request_line_hit),
        .request_line_pending(request_line_pending),
        .redirect_req_fire(redirect_req_fire),
        .pair_req_fire(pair_req_fire),
        .redirect_line_pending_q(redirect_line_pending_q),
        .redirect_line_addr_q(redirect_line_addr_q),
        .fal_line_pending_q(fal_line_pending_q),
        .fal_line_addr_q(fal_line_addr_q),
        .alt_restart_context_match_r(alt_restart_context_match_r),
        .alt_restart_target_pending_r(alt_restart_target_pending_r),
        .pair_predicted_valid_q(pair_predicted_valid_q),
        .pair_predicted_addr_q(pair_predicted_addr_q),
        .pair_unpredicted_valid_q(pair_unpredicted_valid_q),
        .pair_unpredicted_addr_q(pair_unpredicted_addr_q),
        .line_valid_q(line_valid_q),
        .line_sector_valid_q(line_sector_valid_q),
        .line_addr_q(line_addr_q),
        .carousel_pending_valid_q(carousel_pending_valid_q),
        .carousel_pending_addr_q(carousel_pending_addr_q),
        .ingress_valid_q(ingress_valid_q),
        .ingress_origin_q(ingress_origin_q),
        .ingress_addr_q(ingress_addr_q)
    );

    initial begin
        if ((!ENABLE_CAROUSEL && (LINE_DEPTH != 2)) ||
            (ENABLE_CAROUSEL && (LINE_DEPTH != 4)))
            $fatal(1,
                "fetch_3w depth must be 2 for bridge or 4 for carousel");
        if (BRANCH_PAIR_STACK_DEPTH < 1)
            $fatal(1, "fetch_3w branch-pair stack depth must be positive");
        if ((FETCH_DATA_WIDTH != 256) && (FETCH_DATA_WIDTH != 512))
            $fatal(1, "fetch_3w data width must be 256 or 512 bits");
        if ((ENABLE_ALT_LOOKASIDE >= 4) && (FETCH_DATA_WIDTH != 256))
            $fatal(1,
                "fetch_3w pair modes require the 256-bit fetch block");
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
        if (rst_n && !ENABLE_CAROUSEL &&
            resp_valid_i && resp_demand_i &&
            !restart_i && !invalidate_i &&
            !flush_i && !resp_match)
            $fatal(1,
                "fetch_3w response addr=%h does not match pending valid=%b addr=%h",
                resp_addr_i, pending_valid_q, pending_addr_q);
        // Carousel ownership is deliberately tolerant of late responses.
        // An aged redirect/FAL response is installed only by the active-window
        // path above; an out-of-window response has no current consumer.
        if (rst_n && (decode_valid_o != 3'b000) &&
            (decode_valid_o != 3'b001) &&
            (decode_valid_o != 3'b011) &&
            (decode_valid_o != 3'b111))
            $fatal(1, "fetch_3w decode output is not a contiguous prefix");
    end
`endif

endmodule
