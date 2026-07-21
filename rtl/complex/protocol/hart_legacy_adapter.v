`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// Compatibility endpoint for one current OpenRV64 physical memory port.
//
// The core side retains the existing blocking request/completion contract.
// The complex side is a decoupled, explicitly identified transaction.  Only
// one request may be outstanding because the legacy core port has no tag and
// cannot accept an out-of-order completion.
module openrv64_ccx_hart_legacy_adapter #(
    parameter [`OPENRV64_CCX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}},
    parameter [`OPENRV64_CCX_ATTR_WIDTH-1:0] DEFAULT_ATTR =
        `OPENRV64_CCX_ATTR_NONE
) (
    input  wire clk_i,
    input  wire rst_ni,

    input  wire        core_valid_i,
    output wire        core_ready_o,
    input  wire        core_write_i,
    input  wire [63:0] core_addr_i,
    input  wire [63:0] core_wdata_i,
    input  wire [7:0]  core_wstrb_i,
    output wire [63:0] core_rdata_o,
    output wire        core_error_o,

    output wire                         req_valid_o,
    input  wire                         req_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] req_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]  req_txn_id_o,
    output wire [`OPENRV64_CCX_OP_WIDTH-1:0]      req_op_o,
    output wire [`OPENRV64_CCX_ORDER_WIDTH-1:0]   req_order_o,
    output wire [`OPENRV64_CCX_KIND_WIDTH-1:0]    req_kind_o,
    output wire [`OPENRV64_CCX_ATTR_WIDTH-1:0]    req_attr_o,
    output wire [2:0]                   req_size_o,
    output wire [63:0]                  req_addr_o,
    output wire [63:0]                  req_wdata_o,
    output wire [7:0]                   req_wstrb_o,

    input  wire                         resp_valid_i,
    output wire                         resp_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] resp_hart_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]  resp_txn_id_i,
    input  wire [63:0]                  resp_rdata_i,
    input  wire                         resp_error_i,
    input  wire                         resp_sc_success_i
);

    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_SEND = 2'd1;
    localparam [1:0] STATE_WAIT = 2'd2;

    reg [1:0] state_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] next_txn_id_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] request_txn_id_q;
    reg request_write_q;
    reg [63:0] request_addr_q;
    reg [63:0] request_wdata_q;
    reg [7:0] request_wstrb_q;

    wire request_fire = req_valid_o && req_ready_i;
    wire response_match = resp_valid_i &&
        (resp_hart_id_i == HART_ID) &&
        (resp_txn_id_i == request_txn_id_q);
    wire response_fire = resp_ready_o && resp_valid_i;

    assign req_valid_o = (state_q == STATE_SEND);
    assign req_hart_id_o = HART_ID;
    assign req_txn_id_o = request_txn_id_q;
    assign req_op_o = request_write_q ? `OPENRV64_CCX_OP_WRITE :
                                        `OPENRV64_CCX_OP_READ;
    assign req_order_o = `OPENRV64_CCX_ORDER_NONE;
    assign req_kind_o = `OPENRV64_CCX_KIND_LEGACY;
    assign req_attr_o = DEFAULT_ATTR;

    // The old physical port always transfers one aligned 64-bit memory word.
    // Narrow data semantics are represented by address low bits and strobes
    // and are completed inside the core LSU.
    assign req_size_o = 3'd3;
    assign req_addr_o = request_addr_q;
    assign req_wdata_o = request_wdata_q;
    assign req_wstrb_o = request_wstrb_q;

    // A response with the wrong source or transaction identity is not
    // consumed.  A later fabric must route it to its actual endpoint.
    assign resp_ready_o = (state_q == STATE_WAIT) && response_match;
    assign core_ready_o = core_valid_i && response_fire;
    assign core_rdata_o = resp_rdata_i;
    assign core_error_o = core_valid_i && response_fire && resp_error_i;

    // Reserved by the protocol but unused by the READ/WRITE compatibility
    // endpoint.  Referencing it keeps lint from treating the future field as
    // an accidental dangling input.
    wire unused_resp_sc_success = resp_sc_success_i;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= STATE_IDLE;
            next_txn_id_q <= {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
            request_txn_id_q <= {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
            request_write_q <= 1'b0;
            request_addr_q <= 64'd0;
            request_wdata_q <= 64'd0;
            request_wstrb_q <= 8'd0;
        end else begin
            case (state_q)
                STATE_IDLE: begin
                    if (core_valid_i) begin
                        request_txn_id_q <= next_txn_id_q;
                        next_txn_id_q <= next_txn_id_q + 1'b1;
                        request_write_q <= core_write_i;
                        request_addr_q <= core_addr_i;
                        request_wdata_q <= core_wdata_i;
                        request_wstrb_q <= core_wstrb_i;
                        state_q <= STATE_SEND;
                    end
                end

                STATE_SEND: begin
                    if (request_fire)
                        state_q <= STATE_WAIT;
                end

                STATE_WAIT: begin
                    if (response_fire)
                        state_q <= STATE_IDLE;
                end

                default: state_q <= STATE_IDLE;
            endcase
        end
    end

endmodule
