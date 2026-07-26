`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// Round-robin arbiter for the native cache-line CCX interface.
//
// Commands and write data are separate channels.  A write-data owner is
// retained from command acceptance through the final declared line beat so a
// second hart cannot splice data into the active transaction.  Responses route
// from the physical hart ID; source and transaction IDs remain untouched.
module openrv64_ccx_line_crossbar #(
    parameter integer NUM_HARTS = 1,
    parameter integer HART_ID_BASE = 0,
    parameter integer HART_INDEX_WIDTH =
        (NUM_HARTS > 1) ? $clog2(NUM_HARTS) : 1
) (
    input  wire clk_i,
    input  wire rst_ni,

    input  wire [NUM_HARTS-1:0] hart_req_valid_i,
    output reg  [NUM_HARTS-1:0] hart_req_ready_o,
    input  wire [NUM_HARTS*`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                         hart_req_hart_id_i,
    input  wire [NUM_HARTS*`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                         hart_req_txn_id_i,
    input  wire [NUM_HARTS*`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                         hart_req_source_id_i,
    input  wire [NUM_HARTS*`OPENRV64_CCX_OP_WIDTH-1:0]
                                         hart_req_op_i,
    input  wire [NUM_HARTS-1:0]         hart_req_lock_i,
    input  wire [NUM_HARTS*`OPENRV64_CCX_ORDER_WIDTH-1:0]
                                         hart_req_order_i,
    input  wire [NUM_HARTS*`OPENRV64_CCX_KIND_WIDTH-1:0]
                                         hart_req_kind_i,
    input  wire [NUM_HARTS*`OPENRV64_CCX_ATTR_WIDTH-1:0]
                                         hart_req_attr_i,
    input  wire [NUM_HARTS*3-1:0]       hart_req_size_i,
    input  wire [NUM_HARTS*64-1:0]      hart_req_addr_i,
    input  wire [NUM_HARTS*`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
                                         hart_req_burst_len_i,

    output reg                          mem_req_valid_o,
    input  wire                         mem_req_ready_i,
    output reg [`OPENRV64_CCX_HART_ID_WIDTH-1:0] mem_req_hart_id_o,
    output reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] mem_req_txn_id_o,
    output reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] mem_req_source_id_o,
    output reg [`OPENRV64_CCX_OP_WIDTH-1:0] mem_req_op_o,
    output reg                          mem_req_lock_o,
    output reg [`OPENRV64_CCX_ORDER_WIDTH-1:0] mem_req_order_o,
    output reg [`OPENRV64_CCX_KIND_WIDTH-1:0] mem_req_kind_o,
    output reg [`OPENRV64_CCX_ATTR_WIDTH-1:0] mem_req_attr_o,
    output reg [2:0]                    mem_req_size_o,
    output reg [63:0]                   mem_req_addr_o,
    output reg [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
                                          mem_req_burst_len_o,

    input  wire [NUM_HARTS-1:0] hart_wdata_valid_i,
    output reg  [NUM_HARTS-1:0] hart_wdata_ready_o,
    input  wire [NUM_HARTS*`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                         hart_wdata_hart_id_i,
    input  wire [NUM_HARTS*`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                         hart_wdata_txn_id_i,
    input  wire [NUM_HARTS*`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                         hart_wdata_source_id_i,
    input  wire [NUM_HARTS*`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                         hart_wdata_beat_index_i,
    input  wire [NUM_HARTS-1:0]         hart_wdata_last_i,
    input  wire [NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                         hart_wdata_i,
    input  wire [NUM_HARTS*`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
                                         hart_wstrb_i,

    output wire                         mem_wdata_valid_o,
    input  wire                         mem_wdata_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] mem_wdata_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] mem_wdata_txn_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                          mem_wdata_source_id_o,
    output wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                          mem_wdata_beat_index_o,
    output wire                         mem_wdata_last_o,
    output wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] mem_wdata_o,
    output wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] mem_wstrb_o,

    input  wire                         mem_resp_valid_i,
    output reg                          mem_resp_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] mem_resp_hart_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] mem_resp_txn_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                          mem_resp_source_id_i,
    input  wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                          mem_resp_beat_index_i,
    input  wire                         mem_resp_last_i,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] mem_resp_rdata_i,
    input  wire                         mem_resp_error_i,
    input  wire                         mem_resp_sc_success_i,

    output reg  [NUM_HARTS-1:0]        hart_resp_valid_o,
    input  wire [NUM_HARTS-1:0]        hart_resp_ready_i,
    output reg  [NUM_HARTS*`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                         hart_resp_hart_id_o,
    output reg  [NUM_HARTS*`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                         hart_resp_txn_id_o,
    output reg  [NUM_HARTS*`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                         hart_resp_source_id_o,
    output reg  [NUM_HARTS*`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                         hart_resp_beat_index_o,
    output reg  [NUM_HARTS-1:0]        hart_resp_last_o,
    output reg  [NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                         hart_resp_rdata_o,
    output reg  [NUM_HARTS-1:0]        hart_resp_error_o,
    output reg  [NUM_HARTS-1:0]        hart_resp_sc_success_o
);

    reg [HART_INDEX_WIDTH-1:0] round_robin_q;
    reg grant_valid;
    reg [HART_INDEX_WIDTH-1:0] grant_hart;
    reg response_match;
    reg [HART_INDEX_WIDTH-1:0] response_hart;
    reg wdata_active_q;
    reg [HART_INDEX_WIDTH-1:0] wdata_hart_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] wdata_txn_id_q;
    reg [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] wdata_source_id_q;
    reg [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] wdata_burst_len_q;
    reg [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] wdata_beat_q;

    integer scan_index;
    integer candidate_index;
    integer response_index;

    localparam [HART_INDEX_WIDTH-1:0] LAST_HART =
        HART_INDEX_WIDTH'(NUM_HARTS - 1);

    wire command_fire = mem_req_valid_o && mem_req_ready_i;
    wire selected_wdata_valid = wdata_active_q &&
        hart_wdata_valid_i[wdata_hart_q];
    wire selected_wdata_identity_match =
        (hart_wdata_hart_id_i[
            wdata_hart_q*`OPENRV64_CCX_HART_ID_WIDTH +:
            `OPENRV64_CCX_HART_ID_WIDTH] ==
         `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE + wdata_hart_q)) &&
        (hart_wdata_txn_id_i[
            wdata_hart_q*`OPENRV64_CCX_TXN_ID_WIDTH +:
            `OPENRV64_CCX_TXN_ID_WIDTH] == wdata_txn_id_q) &&
        (hart_wdata_source_id_i[
            wdata_hart_q*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
            `OPENRV64_CCX_SOURCE_ID_WIDTH] == wdata_source_id_q) &&
        (hart_wdata_beat_index_i[
            wdata_hart_q*`OPENRV64_CCX_BEAT_INDEX_WIDTH +:
            `OPENRV64_CCX_BEAT_INDEX_WIDTH] == wdata_beat_q);
    wire wdata_fire = mem_wdata_valid_o && mem_wdata_ready_i;

    always @* begin
        grant_valid = 1'b0;
        grant_hart = round_robin_q;
        candidate_index = 0;
        for (scan_index = 0; scan_index < NUM_HARTS;
             scan_index = scan_index + 1) begin
            candidate_index = 32'(round_robin_q) + scan_index;
            if (candidate_index >= NUM_HARTS)
                candidate_index = candidate_index - NUM_HARTS;
            if (!grant_valid && hart_req_valid_i[candidate_index] &&
                (!wdata_active_q ||
                 ((hart_req_op_i[
                     candidate_index*`OPENRV64_CCX_OP_WIDTH +:
                     `OPENRV64_CCX_OP_WIDTH] !=
                   `OPENRV64_CCX_OP_WRITE) &&
                  (hart_req_op_i[
                     candidate_index*`OPENRV64_CCX_OP_WIDTH +:
                     `OPENRV64_CCX_OP_WIDTH] !=
                   `OPENRV64_CCX_OP_SC)))) begin
                grant_valid = 1'b1;
                grant_hart = candidate_index[HART_INDEX_WIDTH-1:0];
            end
        end

        mem_req_valid_o = grant_valid;
        mem_req_hart_id_o = `OPENRV64_CCX_HART_ID_WIDTH'(
            HART_ID_BASE + grant_hart);
        mem_req_txn_id_o = hart_req_txn_id_i[
            grant_hart*`OPENRV64_CCX_TXN_ID_WIDTH +:
            `OPENRV64_CCX_TXN_ID_WIDTH];
        mem_req_source_id_o = hart_req_source_id_i[
            grant_hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
            `OPENRV64_CCX_SOURCE_ID_WIDTH];
        mem_req_op_o = hart_req_op_i[
            grant_hart*`OPENRV64_CCX_OP_WIDTH +:
            `OPENRV64_CCX_OP_WIDTH];
        mem_req_lock_o = hart_req_lock_i[grant_hart];
        mem_req_order_o = hart_req_order_i[
            grant_hart*`OPENRV64_CCX_ORDER_WIDTH +:
            `OPENRV64_CCX_ORDER_WIDTH];
        mem_req_kind_o = hart_req_kind_i[
            grant_hart*`OPENRV64_CCX_KIND_WIDTH +:
            `OPENRV64_CCX_KIND_WIDTH];
        mem_req_attr_o = hart_req_attr_i[
            grant_hart*`OPENRV64_CCX_ATTR_WIDTH +:
            `OPENRV64_CCX_ATTR_WIDTH];
        mem_req_size_o = hart_req_size_i[grant_hart*3 +: 3];
        mem_req_addr_o = hart_req_addr_i[grant_hart*64 +: 64];
        mem_req_burst_len_o = hart_req_burst_len_i[
            grant_hart*`OPENRV64_CCX_BURST_LEN_WIDTH +:
            `OPENRV64_CCX_BURST_LEN_WIDTH];

    end

    always @* begin
        hart_req_ready_o = {NUM_HARTS{1'b0}};
        if (grant_valid)
            hart_req_ready_o[grant_hart] = mem_req_ready_i;
    end

    assign mem_wdata_valid_o = selected_wdata_valid &&
                               selected_wdata_identity_match;
    assign mem_wdata_hart_id_o = `OPENRV64_CCX_HART_ID_WIDTH'(
        HART_ID_BASE + wdata_hart_q);
    assign mem_wdata_txn_id_o = wdata_txn_id_q;
    assign mem_wdata_source_id_o = wdata_source_id_q;
    assign mem_wdata_beat_index_o = wdata_beat_q;
    assign mem_wdata_last_o = hart_wdata_last_i[wdata_hart_q];
    assign mem_wdata_o = hart_wdata_i[
        wdata_hart_q*`OPENRV64_CCX_LINE_DATA_WIDTH +:
        `OPENRV64_CCX_LINE_DATA_WIDTH];
    assign mem_wstrb_o = hart_wstrb_i[
        wdata_hart_q*`OPENRV64_CCX_LINE_STRB_WIDTH +:
        `OPENRV64_CCX_LINE_STRB_WIDTH];

    always @* begin
        hart_wdata_ready_o = {NUM_HARTS{1'b0}};
        if (wdata_active_q && selected_wdata_identity_match)
            hart_wdata_ready_o[wdata_hart_q] = mem_wdata_ready_i;
    end

    always @* begin
        hart_resp_valid_o = {NUM_HARTS{1'b0}};
        hart_resp_hart_id_o =
            {NUM_HARTS*`OPENRV64_CCX_HART_ID_WIDTH{1'b0}};
        hart_resp_txn_id_o =
            {NUM_HARTS*`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
        hart_resp_source_id_o =
            {NUM_HARTS*`OPENRV64_CCX_SOURCE_ID_WIDTH{1'b0}};
        hart_resp_beat_index_o =
            {NUM_HARTS*`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}};
        hart_resp_last_o = {NUM_HARTS{1'b0}};
        hart_resp_rdata_o =
            {NUM_HARTS*`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}};
        hart_resp_error_o = {NUM_HARTS{1'b0}};
        hart_resp_sc_success_o = {NUM_HARTS{1'b0}};
        response_match = 1'b0;
        response_hart = {HART_INDEX_WIDTH{1'b0}};

        for (response_index = 0; response_index < NUM_HARTS;
             response_index = response_index + 1) begin
            if (!response_match &&
                (mem_resp_hart_id_i ==
                 `OPENRV64_CCX_HART_ID_WIDTH'(
                     HART_ID_BASE + response_index))) begin
                response_match = 1'b1;
                response_hart =
                    response_index[HART_INDEX_WIDTH-1:0];
            end
        end

        if (response_match) begin
            hart_resp_valid_o[response_hart] = mem_resp_valid_i;
            hart_resp_hart_id_o[
                response_hart*`OPENRV64_CCX_HART_ID_WIDTH +:
                `OPENRV64_CCX_HART_ID_WIDTH] = mem_resp_hart_id_i;
            hart_resp_txn_id_o[
                response_hart*`OPENRV64_CCX_TXN_ID_WIDTH +:
                `OPENRV64_CCX_TXN_ID_WIDTH] = mem_resp_txn_id_i;
            hart_resp_source_id_o[
                response_hart*`OPENRV64_CCX_SOURCE_ID_WIDTH +:
                `OPENRV64_CCX_SOURCE_ID_WIDTH] = mem_resp_source_id_i;
            hart_resp_beat_index_o[
                response_hart*`OPENRV64_CCX_BEAT_INDEX_WIDTH +:
                `OPENRV64_CCX_BEAT_INDEX_WIDTH] =
                    mem_resp_beat_index_i;
            hart_resp_last_o[response_hart] = mem_resp_last_i;
            hart_resp_rdata_o[
                response_hart*`OPENRV64_CCX_LINE_DATA_WIDTH +:
                `OPENRV64_CCX_LINE_DATA_WIDTH] = mem_resp_rdata_i;
            hart_resp_error_o[response_hart] = mem_resp_error_i;
            hart_resp_sc_success_o[response_hart] =
                mem_resp_sc_success_i;
        end
    end

    always @* begin
        mem_resp_ready_o = 1'b0;
        if (response_match)
            mem_resp_ready_o = hart_resp_ready_i[response_hart];
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            round_robin_q <= {HART_INDEX_WIDTH{1'b0}};
            wdata_active_q <= 1'b0;
            wdata_hart_q <= {HART_INDEX_WIDTH{1'b0}};
            wdata_txn_id_q <= 0;
            wdata_source_id_q <= 0;
            wdata_burst_len_q <= 0;
            wdata_beat_q <= 0;
        end else begin
            if (command_fire) begin
                if (grant_hart == LAST_HART)
                    round_robin_q <= {HART_INDEX_WIDTH{1'b0}};
                else
                    round_robin_q <= grant_hart + 1'b1;

                if ((mem_req_op_o == `OPENRV64_CCX_OP_WRITE) ||
                    (mem_req_op_o == `OPENRV64_CCX_OP_SC)) begin
                    wdata_active_q <= 1'b1;
                    wdata_hart_q <= grant_hart;
                    wdata_txn_id_q <= mem_req_txn_id_o;
                    wdata_source_id_q <= mem_req_source_id_o;
                    wdata_burst_len_q <= mem_req_burst_len_o;
                    wdata_beat_q <= 0;
                end
            end

            if (wdata_fire) begin
                if (wdata_beat_q >= wdata_burst_len_q) begin
                    wdata_active_q <= 1'b0;
                    wdata_beat_q <= 0;
                end else begin
                    wdata_beat_q <= wdata_beat_q + 1'b1;
                end
            end
        end
    end

    always @(posedge clk_i) begin
        if (rst_ni && command_fire &&
            (hart_req_hart_id_i[
                grant_hart*`OPENRV64_CCX_HART_ID_WIDTH +:
                `OPENRV64_CCX_HART_ID_WIDTH] !=
             `OPENRV64_CCX_HART_ID_WIDTH'(
                 HART_ID_BASE + grant_hart)))
            $fatal(1, "native CCX hart port carries the wrong strapped hart ID");

        if (rst_ni && command_fire && wdata_active_q &&
            ((mem_req_op_o == `OPENRV64_CCX_OP_WRITE) ||
             (mem_req_op_o == `OPENRV64_CCX_OP_SC)))
            $fatal(1,
                "native CCX crossbar accepted overlapping write-data owners");

        if (rst_ni && wdata_active_q && selected_wdata_valid &&
            !selected_wdata_identity_match)
            $fatal(1, "native CCX write-data identity or beat mismatch");

        if (rst_ni && wdata_fire &&
            (mem_wdata_last_o !=
             (wdata_beat_q == wdata_burst_len_q)))
            $fatal(1, "native CCX write-data last does not match burst length");
    end

    generate
        if ((NUM_HARTS < 1) || (NUM_HARTS > 16)) begin : g_bad_harts
            initial $fatal(1,
                "native CCX crossbar supports 1 through 16 harts");
        end
        if ((HART_ID_BASE < 0) ||
            ((HART_ID_BASE + NUM_HARTS) > 16)) begin : g_bad_ids
            initial $fatal(1,
                "native CCX crossbar hart IDs exceed four bits");
        end
    endgenerate

endmodule
