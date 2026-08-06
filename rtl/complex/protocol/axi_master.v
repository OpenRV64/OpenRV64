`timescale 1ns/1ps
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

// Single-outstanding ICX-to-AXI4 bridge.
//
// AXI is deliberately below the core-complex protocol.  This bridge consumes
// one explicit ICX request, performs one 64-bit single-beat AXI transaction on
// the wider external data bus, and returns the completion with its original
// hart and transaction identity.
module openrv64_icx_axi_master #(
    parameter integer AXI_ADDR_WIDTH = `OPENRV64_AXI_ADDR_WIDTH,
    parameter integer AXI_DATA_WIDTH = `OPENRV64_AXI_DATA_WIDTH,
    parameter integer AXI_ID_WIDTH = `OPENRV64_AXI_ID_WIDTH,
    parameter [AXI_ID_WIDTH-1:0] AXI_ID = {AXI_ID_WIDTH{1'b1}}
) (
    input  wire clk_i,
    input  wire rst_ni,

    input  wire                         req_valid_i,
    output wire                         req_ready_o,
    input  wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] req_hart_id_i,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]  req_txn_id_i,
    input  wire [`OPENRV64_ICX_OP_WIDTH-1:0]      req_op_i,
    input  wire [`OPENRV64_ICX_ORDER_WIDTH-1:0]   req_order_i,
    input  wire [`OPENRV64_ICX_KIND_WIDTH-1:0]    req_kind_i,
    input  wire [`OPENRV64_ICX_ATTR_WIDTH-1:0]    req_attr_i,
    input  wire [2:0]                   req_size_i,
    input  wire [63:0]                  req_addr_i,
    input  wire [63:0]                  req_wdata_i,
    input  wire [7:0]                   req_wstrb_i,

    output wire                         resp_valid_o,
    input  wire                         resp_ready_i,
    output wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] resp_hart_id_o,
    output wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]  resp_txn_id_o,
    output wire [63:0]                  resp_rdata_o,
    output wire                         resp_error_o,
    output wire                         resp_sc_success_o,

    output wire [AXI_ID_WIDTH-1:0]   m_axi_arid_o,
    output wire [AXI_ADDR_WIDTH-1:0] m_axi_araddr_o,
    output wire [7:0]                m_axi_arlen_o,
    output wire [2:0]                m_axi_arsize_o,
    output wire [1:0]                m_axi_arburst_o,
    output wire                      m_axi_arlock_o,
    output wire [3:0]                m_axi_arcache_o,
    output wire [2:0]                m_axi_arprot_o,
    output wire [3:0]                m_axi_arqos_o,
    output wire                      m_axi_arvalid_o,
    input  wire                      m_axi_arready_i,

    input  wire [AXI_ID_WIDTH-1:0]   m_axi_rid_i,
    input  wire [AXI_DATA_WIDTH-1:0] m_axi_rdata_i,
    input  wire [1:0]                m_axi_rresp_i,
    input  wire                      m_axi_rlast_i,
    input  wire                      m_axi_rvalid_i,
    output wire                      m_axi_rready_o,

    output wire [AXI_ID_WIDTH-1:0]   m_axi_awid_o,
    output wire [AXI_ADDR_WIDTH-1:0] m_axi_awaddr_o,
    output wire [7:0]                m_axi_awlen_o,
    output wire [2:0]                m_axi_awsize_o,
    output wire [1:0]                m_axi_awburst_o,
    output wire                      m_axi_awlock_o,
    output wire [3:0]                m_axi_awcache_o,
    output wire [2:0]                m_axi_awprot_o,
    output wire [3:0]                m_axi_awqos_o,
    output wire                      m_axi_awvalid_o,
    input  wire                      m_axi_awready_i,

    output wire [AXI_DATA_WIDTH-1:0] m_axi_wdata_o,
    output wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb_o,
    output wire                      m_axi_wlast_o,
    output wire                      m_axi_wvalid_o,
    input  wire                      m_axi_wready_i,

    input  wire [AXI_ID_WIDTH-1:0]   m_axi_bid_i,
    input  wire [1:0]                m_axi_bresp_i,
    input  wire                      m_axi_bvalid_i,
    output wire                      m_axi_bready_o
);

    localparam integer AXI_BYTES = AXI_DATA_WIDTH / 8;
    localparam integer AXI_LANES = AXI_DATA_WIDTH / 64;
    localparam integer AXI_STRB_WIDTH = AXI_DATA_WIDTH / 8;
    localparam integer AXI_LANE_INDEX_WIDTH =
        (AXI_LANES > 1) ? $clog2(AXI_LANES) : 1;

    localparam [2:0] STATE_IDLE = 3'd0;
    localparam [2:0] STATE_READ_ADDR = 3'd1;
    localparam [2:0] STATE_READ_DATA = 3'd2;
    localparam [2:0] STATE_WRITE_SEND = 3'd3;
    localparam [2:0] STATE_WRITE_RESP = 3'd4;
    localparam [2:0] STATE_RESPONSE = 3'd5;

    reg [2:0] state_q;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] request_hart_id_q;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] request_txn_id_q;
    reg [`OPENRV64_ICX_KIND_WIDTH-1:0] request_kind_q;
    reg [`OPENRV64_ICX_ATTR_WIDTH-1:0] request_attr_q;
    reg [2:0] request_size_q;
    reg [63:0] request_addr_q;
    reg [63:0] request_wdata_q;
    reg [7:0] request_wstrb_q;
    reg aw_done_q;
    reg w_done_q;
    reg [63:0] response_rdata_q;
    reg response_error_q;

    wire request_fire = req_valid_i && req_ready_o;
    wire read_addr_fire = m_axi_arvalid_o && m_axi_arready_i;
    wire read_data_fire = m_axi_rvalid_i && m_axi_rready_o;
    wire write_addr_fire = m_axi_awvalid_o && m_axi_awready_i;
    wire write_data_fire = m_axi_wvalid_o && m_axi_wready_i;
    wire write_resp_fire = m_axi_bvalid_i && m_axi_bready_o;
    wire response_fire = resp_valid_o && resp_ready_i;

    wire [AXI_LANE_INDEX_WIDTH-1:0] lane_index =
        (AXI_LANES == 1) ? {AXI_LANE_INDEX_WIDTH{1'b0}} :
        request_addr_q[3 +: AXI_LANE_INDEX_WIDTH];
    wire [AXI_DATA_WIDTH-1:0] expanded_wdata =
        {{(AXI_DATA_WIDTH-64){1'b0}}, request_wdata_q};
    wire [AXI_STRB_WIDTH-1:0] expanded_wstrb =
        {{(AXI_STRB_WIDTH-8){1'b0}}, request_wstrb_q};
    wire [AXI_DATA_WIDTH-1:0] shifted_wdata =
        expanded_wdata << (lane_index * 64);
    wire [AXI_STRB_WIDTH-1:0] shifted_wstrb =
        expanded_wstrb << (lane_index * 8);
    wire [63:0] selected_rdata =
        m_axi_rdata_i[lane_index * 64 +: 64];

    wire request_cacheable =
        |(request_attr_q & `OPENRV64_ICX_ATTR_CACHEABLE);
    wire request_is_fetch =
        (request_kind_q == `OPENRV64_ICX_KIND_FETCH);
    wire read_id_match = (m_axi_rid_i == AXI_ID);
    wire write_id_match = (m_axi_bid_i == AXI_ID);
    wire read_response_error = (m_axi_rresp_i == 2'b10) ||
                               (m_axi_rresp_i == 2'b11);
    wire write_response_error = (m_axi_bresp_i == 2'b10) ||
                                (m_axi_bresp_i == 2'b11);
    wire [2:0] unused_request_byte_offset = request_addr_q[2:0];

    assign req_ready_o = (state_q == STATE_IDLE);

    assign resp_valid_o = (state_q == STATE_RESPONSE);
    assign resp_hart_id_o = request_hart_id_q;
    assign resp_txn_id_o = request_txn_id_q;
    assign resp_rdata_o = response_rdata_q;
    assign resp_error_o = response_error_q;
    assign resp_sc_success_o = 1'b0;

    assign m_axi_arid_o = AXI_ID;
    assign m_axi_araddr_o = {request_addr_q[AXI_ADDR_WIDTH-1:3], 3'b000};
    assign m_axi_arlen_o = 8'd0;
    assign m_axi_arsize_o = request_size_q;
    assign m_axi_arburst_o = 2'b01;
    assign m_axi_arlock_o = 1'b0;
    assign m_axi_arcache_o = request_cacheable ? 4'b0011 : 4'b0000;
    assign m_axi_arprot_o = {request_is_fetch, 2'b00};
    assign m_axi_arqos_o = 4'd0;
    assign m_axi_arvalid_o = (state_q == STATE_READ_ADDR);
    assign m_axi_rready_o = (state_q == STATE_READ_DATA) && read_id_match;

    assign m_axi_awid_o = AXI_ID;
    assign m_axi_awaddr_o = {request_addr_q[AXI_ADDR_WIDTH-1:3], 3'b000};
    assign m_axi_awlen_o = 8'd0;
    assign m_axi_awsize_o = request_size_q;
    assign m_axi_awburst_o = 2'b01;
    assign m_axi_awlock_o = 1'b0;
    assign m_axi_awcache_o = request_cacheable ? 4'b0011 : 4'b0000;
    assign m_axi_awprot_o = {request_is_fetch, 2'b00};
    assign m_axi_awqos_o = 4'd0;
    assign m_axi_awvalid_o = (state_q == STATE_WRITE_SEND) && !aw_done_q;
    assign m_axi_wdata_o = shifted_wdata;
    assign m_axi_wstrb_o = shifted_wstrb;
    assign m_axi_wlast_o = 1'b1;
    assign m_axi_wvalid_o = (state_q == STATE_WRITE_SEND) && !w_done_q;
    assign m_axi_bready_o = (state_q == STATE_WRITE_RESP) && write_id_match;

    // Acquire/release is carried by ICX and consumed at a future ordering
    // point.  This one-request-at-a-time bridge is already strictly ordered.
    wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] unused_request_order = req_order_i;

    initial begin
        if ((AXI_ADDR_WIDTH < 4) || (AXI_ADDR_WIDTH > 64))
            $fatal(1, "ICX AXI address width must be from 4 through 64");
        if ((AXI_DATA_WIDTH < 64) || ((AXI_DATA_WIDTH % 64) != 0) ||
            ((AXI_BYTES & (AXI_BYTES - 1)) != 0))
            $fatal(1, "ICX AXI data width must be a power-of-two byte multiple of 64 bits");
        if (AXI_ID_WIDTH < 1)
            $fatal(1, "ICX AXI ID width must be positive");
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= STATE_IDLE;
            request_hart_id_q <= {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}};
            request_txn_id_q <= {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
            request_kind_q <= `OPENRV64_ICX_KIND_LEGACY;
            request_attr_q <= `OPENRV64_ICX_ATTR_NONE;
            request_size_q <= 3'd3;
            request_addr_q <= 64'd0;
            request_wdata_q <= 64'd0;
            request_wstrb_q <= 8'd0;
            aw_done_q <= 1'b0;
            w_done_q <= 1'b0;
            response_rdata_q <= 64'd0;
            response_error_q <= 1'b0;
        end else begin
            case (state_q)
                STATE_IDLE: begin
                    if (request_fire) begin
                        request_hart_id_q <= req_hart_id_i;
                        request_txn_id_q <= req_txn_id_i;
                        request_kind_q <= req_kind_i;
                        request_attr_q <= req_attr_i;
                        request_size_q <= req_size_i;
                        request_addr_q <= req_addr_i;
                        request_wdata_q <= req_wdata_i;
                        request_wstrb_q <= req_wstrb_i;
                        response_rdata_q <= 64'd0;
                        response_error_q <= 1'b0;
                        aw_done_q <= 1'b0;
                        w_done_q <= 1'b0;
                        if ((req_op_i == `OPENRV64_ICX_OP_READ) &&
                            (req_size_i == 3'd3)) begin
                            state_q <= STATE_READ_ADDR;
                        end else if ((req_op_i == `OPENRV64_ICX_OP_WRITE) &&
                                     (req_size_i == 3'd3)) begin
                            state_q <= STATE_WRITE_SEND;
                        end else begin
                            // Reserved operations must not silently degrade to
                            // non-atomic AXI reads and writes.
                            response_error_q <= 1'b1;
                            state_q <= STATE_RESPONSE;
                        end
                    end
                end

                STATE_READ_ADDR: begin
                    if (read_addr_fire)
                        state_q <= STATE_READ_DATA;
                end

                STATE_READ_DATA: begin
                    if (read_data_fire) begin
                        response_rdata_q <= selected_rdata;
                        response_error_q <= read_response_error ||
                                            !m_axi_rlast_i;
                        state_q <= STATE_RESPONSE;
                    end
                end

                STATE_WRITE_SEND: begin
                    if (write_addr_fire)
                        aw_done_q <= 1'b1;
                    if (write_data_fire)
                        w_done_q <= 1'b1;
                    if ((aw_done_q || write_addr_fire) &&
                        (w_done_q || write_data_fire))
                        state_q <= STATE_WRITE_RESP;
                end

                STATE_WRITE_RESP: begin
                    if (write_resp_fire) begin
                        response_error_q <= write_response_error;
                        state_q <= STATE_RESPONSE;
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

endmodule
