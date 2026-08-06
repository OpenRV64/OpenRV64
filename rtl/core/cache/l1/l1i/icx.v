`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// ICX wire-format adapter for the L1I miss path.
//
// Demand-MSHR ownership and issue selection remain cache policy. This module
// owns the read-command encoding, command handshake, and response identity /
// geometry checks at the protocol boundary.
module openrv64_l1i_icx_interface #(
    parameter integer ADDR_WIDTH = 64,
    parameter [`OPENRV64_ICX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}}
) (
    input  wire                      issue_valid_i,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] issue_txn_id_i,
    input  wire [ADDR_WIDTH-1:0]     issue_addr_i,
    output wire                      issue_fire_o,

    output wire                      icx_req_valid_o,
    input  wire                      icx_req_ready_i,
    output wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                     icx_req_hart_id_o,
    output wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                     icx_req_source_id_o,
    output wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                     icx_req_txn_id_o,
    output wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op_o,
    output wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order_o,
    output wire [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind_o,
    output wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr_o,
    output wire [2:0]                icx_req_size_o,
    output wire [ADDR_WIDTH-1:0]     icx_req_addr_o,
    output wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
                                     icx_req_burst_len_o,

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
    input  wire                      icx_resp_sc_success_i,
    output wire                      response_fire_o,
    output wire                      response_for_icache_o,
    output wire                      response_geometry_error_o
);

    assign icx_req_valid_o = issue_valid_i;
    assign icx_req_hart_id_o = HART_ID;
    assign icx_req_source_id_o = `OPENRV64_ICX_SOURCE_ICACHE;
    assign icx_req_txn_id_o = issue_txn_id_i;
    assign icx_req_op_o = `OPENRV64_ICX_OP_READ;
    assign icx_req_order_o = `OPENRV64_ICX_ORDER_NONE;
    assign icx_req_kind_o = `OPENRV64_ICX_KIND_FETCH;
    assign icx_req_attr_o = `OPENRV64_ICX_ATTR_CACHEABLE |
                            `OPENRV64_ICX_ATTR_EXECUTABLE;
    assign icx_req_size_o = 3'd6;
    assign icx_req_addr_o = issue_addr_i;
    assign icx_req_burst_len_o =
        {`OPENRV64_ICX_BURST_LEN_WIDTH{1'b0}};
    assign issue_fire_o = icx_req_valid_o && icx_req_ready_i;

    assign icx_resp_ready_o = response_ready_i;
    assign response_fire_o = icx_resp_valid_i && icx_resp_ready_o;
    assign response_for_icache_o =
        (icx_resp_hart_id_i == HART_ID) &&
        (icx_resp_source_id_i == `OPENRV64_ICX_SOURCE_ICACHE);
    assign response_geometry_error_o =
        (icx_resp_beat_index_i !=
         {`OPENRV64_ICX_BEAT_INDEX_WIDTH{1'b0}}) ||
        !icx_resp_last_i || icx_resp_sc_success_i;

endmodule
