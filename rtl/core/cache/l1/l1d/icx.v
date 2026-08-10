`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// ICX wire-format adapter for the L1D backend.
//
// Request selection, transaction ownership, and response routing deliberately
// remain outside this module.  This module owns only the protocol-facing
// command/data channel encoding and their independent ready/valid handshakes.
// That keeps the cache policy state out of the ICX pin-level implementation.
module openrv64_l1d_icx_interface #(
    parameter integer COHERENT_ATOMICS = 0,
    parameter [`OPENRV64_ICX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}}
) (
    input  wire                      send_valid_i,
    input  wire                      suppress_read_i,
    input  wire                      command_sent_i,
    input  wire                      wdata_sent_i,
    input  wire                      request_fence_i,
    input  wire                      request_write_i,
    input  wire                      request_atomic_i,
    input  wire                      request_cacheable_i,
    input  wire                      request_line_read_i,
    input  wire [2:0]                request_size_i,
    input  wire [63:0]               request_addr_i,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                     request_txn_id_i,
    input  wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
                                     request_wdata_i,
    input  wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
                                     request_wstrb_i,

    output wire                      command_fire_o,
    output wire                      wdata_fire_o,

    output wire                      icx_req_valid_o,
    input  wire                      icx_req_ready_i,
    output wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                     icx_req_hart_id_o,
    output wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                     icx_req_txn_id_o,
    output wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                     icx_req_source_id_o,
    output wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op_o,
    output wire                      icx_req_lock_o,
    output wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order_o,
    output wire [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind_o,
    output wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr_o,
    output wire [2:0]                icx_req_size_o,
    output wire [63:0]               icx_req_addr_o,
    output wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
                                     icx_req_burst_len_o,

    output wire                      icx_wdata_valid_o,
    input  wire                      icx_wdata_ready_i,
    output wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                     icx_wdata_hart_id_o,
    output wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                     icx_wdata_txn_id_o,
    output wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                     icx_wdata_source_id_o,
    output wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
                                     icx_wdata_beat_index_o,
    output wire                      icx_wdata_last_o,
    output wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
                                     icx_wdata_o,
    output wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0]
                                     icx_wstrb_o,

    input  wire                      response_ready_i,
    input  wire                      icx_resp_valid_i,
    output wire                      icx_resp_ready_o,
    input  wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                     icx_resp_hart_id_i,
    input  wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                     icx_resp_source_id_i,
    input  wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
                                     icx_resp_beat_index_i,
    input  wire                      icx_resp_last_i,
    output wire                      response_fire_o,
    output wire                      response_for_dcache_o,
    output wire                      response_protocol_error_o
);

    assign icx_req_valid_o = send_valid_i && !command_sent_i &&
                             !(suppress_read_i && !request_write_i &&
                               !request_fence_i);
    assign icx_req_hart_id_o = HART_ID;
    assign icx_req_txn_id_o = request_txn_id_i;
    assign icx_req_source_id_o = `OPENRV64_ICX_SOURCE_DCACHE;
    // A coherent home owns the reservation used by a marked read/modify/write
    // sequence. Keep this opt-in: the single-hart native L2 still consumes
    // the established READ/WRITE compatibility encoding.
    assign icx_req_op_o =
        request_fence_i ? `OPENRV64_ICX_OP_FENCE :
        (COHERENT_ATOMICS != 0) && request_atomic_i ?
            (request_write_i ? `OPENRV64_ICX_OP_SC :
                               `OPENRV64_ICX_OP_LR) :
            (request_write_i ? `OPENRV64_ICX_OP_WRITE :
                               `OPENRV64_ICX_OP_READ);
    assign icx_req_lock_o = 1'b0;
    assign icx_req_order_o = request_fence_i ?
        `OPENRV64_ICX_ORDER_ACQ_REL : `OPENRV64_ICX_ORDER_NONE;
    assign icx_req_kind_o = `OPENRV64_ICX_KIND_DATA;
    assign icx_req_attr_o = request_fence_i ?
        `OPENRV64_ICX_ATTR_NONE : request_cacheable_i ?
        `OPENRV64_ICX_ATTR_CACHEABLE : `OPENRV64_ICX_ATTR_DEVICE;
    assign icx_req_size_o = request_fence_i ? 3'd0 :
                            request_line_read_i ? 3'd6 : request_size_i;
    assign icx_req_addr_o = request_addr_i;
    assign icx_req_burst_len_o =
        {`OPENRV64_ICX_BURST_LEN_WIDTH{1'b0}};

    assign icx_wdata_valid_o = send_valid_i && request_write_i &&
                               !wdata_sent_i;
    assign icx_wdata_hart_id_o = HART_ID;
    assign icx_wdata_txn_id_o = request_txn_id_i;
    assign icx_wdata_source_id_o = `OPENRV64_ICX_SOURCE_DCACHE;
    assign icx_wdata_beat_index_o =
        {`OPENRV64_ICX_BEAT_INDEX_WIDTH{1'b0}};
    assign icx_wdata_last_o = 1'b1;
    assign icx_wdata_o = request_wdata_i;
    assign icx_wstrb_o = request_wstrb_i;

    assign command_fire_o = icx_req_valid_o && icx_req_ready_i;
    assign wdata_fire_o = icx_wdata_valid_o && icx_wdata_ready_i;

    assign icx_resp_ready_o = response_ready_i;
    assign response_fire_o = icx_resp_valid_i && icx_resp_ready_o;
    assign response_for_dcache_o =
        (icx_resp_hart_id_i == HART_ID) &&
        (icx_resp_source_id_i == `OPENRV64_ICX_SOURCE_DCACHE);
    assign response_protocol_error_o =
        (icx_resp_beat_index_i !=
         {`OPENRV64_ICX_BEAT_INDEX_WIDTH{1'b0}}) ||
        !icx_resp_last_i;

endmodule
