`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// Round-robin N-to-one ICX request arbiter with identity-based response
// routing.  The crossbar does not impose an outstanding limit: downstream
// logic applies backpressure at its actual capacity, and responses route by
// the explicit hart ID carried by ICX.  This permits an L2 to accept a second
// hart's request while the first hart's line fill is active.
module openrv64_icx_crossbar #(
    parameter integer NUM_HARTS = 2,
    parameter integer HART_INDEX_WIDTH =
        (NUM_HARTS > 1) ? $clog2(NUM_HARTS) : 1
) (
    input  wire clk_i,
    input  wire rst_ni,

    input  wire [NUM_HARTS-1:0] hart_req_valid_i,
    output reg  [NUM_HARTS-1:0] hart_req_ready_o,
    input  wire [NUM_HARTS*`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                         hart_req_hart_id_i,
    input  wire [NUM_HARTS*`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                         hart_req_txn_id_i,
    input  wire [NUM_HARTS*`OPENRV64_ICX_OP_WIDTH-1:0]
                                         hart_req_op_i,
    input  wire [NUM_HARTS-1:0]         hart_req_lock_i,
    input  wire [NUM_HARTS*`OPENRV64_ICX_ORDER_WIDTH-1:0]
                                         hart_req_order_i,
    input  wire [NUM_HARTS*`OPENRV64_ICX_KIND_WIDTH-1:0]
                                         hart_req_kind_i,
    input  wire [NUM_HARTS*`OPENRV64_ICX_ATTR_WIDTH-1:0]
                                         hart_req_attr_i,
    input  wire [NUM_HARTS*3-1:0]       hart_req_size_i,
    input  wire [NUM_HARTS*64-1:0]      hart_req_addr_i,
    input  wire [NUM_HARTS*64-1:0]      hart_req_wdata_i,
    input  wire [NUM_HARTS*8-1:0]       hart_req_wstrb_i,

    output reg                          mem_req_valid_o,
    input  wire                         mem_req_ready_i,
    output reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] mem_req_hart_id_o,
    output reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]  mem_req_txn_id_o,
    output reg [`OPENRV64_ICX_OP_WIDTH-1:0]      mem_req_op_o,
    output reg                          mem_req_lock_o,
    output reg [`OPENRV64_ICX_ORDER_WIDTH-1:0]   mem_req_order_o,
    output reg [`OPENRV64_ICX_KIND_WIDTH-1:0]    mem_req_kind_o,
    output reg [`OPENRV64_ICX_ATTR_WIDTH-1:0]    mem_req_attr_o,
    output reg [2:0]                    mem_req_size_o,
    output reg [63:0]                   mem_req_addr_o,
    output reg [63:0]                   mem_req_wdata_o,
    output reg [7:0]                    mem_req_wstrb_o,

    input  wire                         mem_resp_valid_i,
    output reg                          mem_resp_ready_o,
    input  wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] mem_resp_hart_id_i,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]  mem_resp_txn_id_i,
    input  wire [63:0]                  mem_resp_rdata_i,
    input  wire                         mem_resp_error_i,
    input  wire                         mem_resp_sc_success_i,

    output reg  [NUM_HARTS-1:0]        hart_resp_valid_o,
    input  wire [NUM_HARTS-1:0]        hart_resp_ready_i,
    output reg  [NUM_HARTS*`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                         hart_resp_hart_id_o,
    output reg  [NUM_HARTS*`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                         hart_resp_txn_id_o,
    output reg  [NUM_HARTS*64-1:0]     hart_resp_rdata_o,
    output reg  [NUM_HARTS-1:0]        hart_resp_error_o,
    output reg  [NUM_HARTS-1:0]        hart_resp_sc_success_o
);

    reg [HART_INDEX_WIDTH-1:0] round_robin_q;
    reg grant_valid;
    reg [HART_INDEX_WIDTH-1:0] grant_hart;
    reg response_match;
    reg [HART_INDEX_WIDTH-1:0] response_hart;
    localparam [HART_INDEX_WIDTH-1:0] LAST_HART =
        HART_INDEX_WIDTH'(NUM_HARTS - 1);
    integer scan_index;
    integer candidate_index;
    integer response_index;

    wire mem_request_fire = mem_req_valid_o && mem_req_ready_i;
    generate
        if ((NUM_HARTS < 1) || (NUM_HARTS > 16)) begin : g_bad_hart_count
            initial
            $fatal(1, "ICX crossbar NUM_HARTS must be from 1 through 16");
        end
    endgenerate

    always @* begin
        grant_valid = 1'b0;
        grant_hart = round_robin_q;
        candidate_index = 0;

        for (scan_index = 0; scan_index < NUM_HARTS;
             scan_index = scan_index + 1) begin
            candidate_index = 32'(round_robin_q);
            candidate_index = candidate_index + scan_index;
            if (candidate_index >= NUM_HARTS)
                candidate_index = candidate_index - NUM_HARTS;
            if (!grant_valid && hart_req_valid_i[candidate_index]) begin
                grant_valid = 1'b1;
                grant_hart = candidate_index[HART_INDEX_WIDTH-1:0];
            end
        end

        mem_req_valid_o = 1'b0;
        mem_req_hart_id_o = {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}};
        mem_req_txn_id_o = {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
        mem_req_op_o = `OPENRV64_ICX_OP_READ;
        mem_req_lock_o = 1'b0;
        mem_req_order_o = `OPENRV64_ICX_ORDER_NONE;
        mem_req_kind_o = `OPENRV64_ICX_KIND_LEGACY;
        mem_req_attr_o = `OPENRV64_ICX_ATTR_NONE;
        mem_req_size_o = 3'd0;
        mem_req_addr_o = 64'd0;
        mem_req_wdata_o = 64'd0;
        mem_req_wstrb_o = 8'd0;

        if (grant_valid) begin
            mem_req_valid_o = 1'b1;
            mem_req_hart_id_o = hart_req_hart_id_i[
                grant_hart*`OPENRV64_ICX_HART_ID_WIDTH +:
                `OPENRV64_ICX_HART_ID_WIDTH];
            mem_req_txn_id_o = hart_req_txn_id_i[
                grant_hart*`OPENRV64_ICX_TXN_ID_WIDTH +:
                `OPENRV64_ICX_TXN_ID_WIDTH];
            mem_req_op_o = hart_req_op_i[
                grant_hart*`OPENRV64_ICX_OP_WIDTH +:
                `OPENRV64_ICX_OP_WIDTH];
            mem_req_lock_o = hart_req_lock_i[grant_hart];
            mem_req_order_o = hart_req_order_i[
                grant_hart*`OPENRV64_ICX_ORDER_WIDTH +:
                `OPENRV64_ICX_ORDER_WIDTH];
            mem_req_kind_o = hart_req_kind_i[
                grant_hart*`OPENRV64_ICX_KIND_WIDTH +:
                `OPENRV64_ICX_KIND_WIDTH];
            mem_req_attr_o = hart_req_attr_i[
                grant_hart*`OPENRV64_ICX_ATTR_WIDTH +:
                `OPENRV64_ICX_ATTR_WIDTH];
            mem_req_size_o = hart_req_size_i[grant_hart*3 +: 3];
            mem_req_addr_o = hart_req_addr_i[grant_hart*64 +: 64];
            mem_req_wdata_o = hart_req_wdata_i[grant_hart*64 +: 64];
            mem_req_wstrb_o = hart_req_wstrb_i[grant_hart*8 +: 8];
        end
    end

    always @* begin
        hart_req_ready_o = {NUM_HARTS{1'b0}};
        if (grant_valid)
            hart_req_ready_o[grant_hart] = mem_req_ready_i;
    end

    always @* begin
        hart_resp_valid_o = {NUM_HARTS{1'b0}};
        hart_resp_hart_id_o =
            {NUM_HARTS*`OPENRV64_ICX_HART_ID_WIDTH{1'b0}};
        hart_resp_txn_id_o =
            {NUM_HARTS*`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
        hart_resp_rdata_o = {NUM_HARTS*64{1'b0}};
        hart_resp_error_o = {NUM_HARTS{1'b0}};
        hart_resp_sc_success_o = {NUM_HARTS{1'b0}};
        response_match = 1'b0;
        response_hart = {HART_INDEX_WIDTH{1'b0}};
        for (response_index = 0; response_index < NUM_HARTS;
             response_index = response_index + 1) begin
            if (!response_match &&
                (mem_resp_hart_id_i == hart_req_hart_id_i[
                    response_index*`OPENRV64_ICX_HART_ID_WIDTH +:
                    `OPENRV64_ICX_HART_ID_WIDTH])) begin
                response_match = 1'b1;
                response_hart = response_index[HART_INDEX_WIDTH-1:0];
            end
        end

        if (response_match) begin
            hart_resp_valid_o[response_hart] = mem_resp_valid_i;
            hart_resp_hart_id_o[
                response_hart*`OPENRV64_ICX_HART_ID_WIDTH +:
                `OPENRV64_ICX_HART_ID_WIDTH] = mem_resp_hart_id_i;
            hart_resp_txn_id_o[
                response_hart*`OPENRV64_ICX_TXN_ID_WIDTH +:
                `OPENRV64_ICX_TXN_ID_WIDTH] = mem_resp_txn_id_i;
            hart_resp_rdata_o[response_hart*64 +: 64] =
                mem_resp_rdata_i;
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
        end else begin
            if (mem_request_fire) begin
                if (grant_hart == LAST_HART)
                    round_robin_q <= {HART_INDEX_WIDTH{1'b0}};
                else
                    round_robin_q <= grant_hart + 1'b1;
            end
        end
    end

endmodule
