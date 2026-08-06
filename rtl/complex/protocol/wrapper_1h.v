`timescale 1ns/1ps
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

// One-hart core-complex protocol wrapper.
//
// Northbound is the current OpenRV64 blocking physical memory port.
// Internally every access crosses the ICX request/response protocol.
// Southbound is AXI4, which is an external transport rather than the internal
// core-complex protocol.
module openrv64_icx_protocol_wrapper_1h #(
    parameter [`OPENRV64_ICX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}},
    parameter [`OPENRV64_ICX_ATTR_WIDTH-1:0] DEFAULT_ATTR =
        `OPENRV64_ICX_ATTR_NONE,
    parameter integer AXI_ADDR_WIDTH = `OPENRV64_AXI_ADDR_WIDTH,
    parameter integer AXI_DATA_WIDTH = `OPENRV64_AXI_DATA_WIDTH,
    parameter integer AXI_ID_WIDTH = `OPENRV64_AXI_ID_WIDTH,
    parameter [AXI_ID_WIDTH-1:0] AXI_ID = {AXI_ID_WIDTH{1'b1}}
) (
    input  wire clk_i,
    input  wire rst_ni,

    input  wire        core_mem_valid_i,
    output wire        core_mem_ready_o,
    input  wire        core_mem_write_i,
    input  wire [63:0] core_mem_addr_i,
    input  wire [63:0] core_mem_wdata_i,
    input  wire [7:0]  core_mem_wstrb_i,
    output wire [63:0] core_mem_rdata_o,
    output wire        core_mem_error_o,

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

    wire icx_req_valid;
    wire icx_req_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op;
    wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order;
    wire [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind;
    wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr;
    wire [2:0] icx_req_size;
    wire [63:0] icx_req_addr;
    wire [63:0] icx_req_wdata;
    wire [7:0] icx_req_wstrb;

    wire icx_resp_valid;
    wire icx_resp_ready;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id;
    wire [63:0] icx_resp_rdata;
    wire icx_resp_error;
    wire icx_resp_sc_success;

    openrv64_icx_hart_legacy_adapter #(
        .HART_ID(HART_ID),
        .DEFAULT_ATTR(DEFAULT_ATTR)
    ) u_hart_adapter (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .core_valid_i(core_mem_valid_i),
        .core_ready_o(core_mem_ready_o),
        .core_write_i(core_mem_write_i),
        .core_addr_i(core_mem_addr_i),
        .core_wdata_i(core_mem_wdata_i),
        .core_wstrb_i(core_mem_wstrb_i),
        .core_rdata_o(core_mem_rdata_o),
        .core_error_o(core_mem_error_o),
        .req_valid_o(icx_req_valid),
        .req_ready_i(icx_req_ready),
        .req_hart_id_o(icx_req_hart_id),
        .req_txn_id_o(icx_req_txn_id),
        .req_op_o(icx_req_op),
        .req_order_o(icx_req_order),
        .req_kind_o(icx_req_kind),
        .req_attr_o(icx_req_attr),
        .req_size_o(icx_req_size),
        .req_addr_o(icx_req_addr),
        .req_wdata_o(icx_req_wdata),
        .req_wstrb_o(icx_req_wstrb),
        .resp_valid_i(icx_resp_valid),
        .resp_ready_o(icx_resp_ready),
        .resp_hart_id_i(icx_resp_hart_id),
        .resp_txn_id_i(icx_resp_txn_id),
        .resp_rdata_i(icx_resp_rdata),
        .resp_error_i(icx_resp_error),
        .resp_sc_success_i(icx_resp_sc_success)
    );

    openrv64_icx_axi_master #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .AXI_ID(AXI_ID)
    ) u_axi_master (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .req_valid_i(icx_req_valid),
        .req_ready_o(icx_req_ready),
        .req_hart_id_i(icx_req_hart_id),
        .req_txn_id_i(icx_req_txn_id),
        .req_op_i(icx_req_op),
        .req_order_i(icx_req_order),
        .req_kind_i(icx_req_kind),
        .req_attr_i(icx_req_attr),
        .req_size_i(icx_req_size),
        .req_addr_i(icx_req_addr),
        .req_wdata_i(icx_req_wdata),
        .req_wstrb_i(icx_req_wstrb),
        .resp_valid_o(icx_resp_valid),
        .resp_ready_i(icx_resp_ready),
        .resp_hart_id_o(icx_resp_hart_id),
        .resp_txn_id_o(icx_resp_txn_id),
        .resp_rdata_o(icx_resp_rdata),
        .resp_error_o(icx_resp_error),
        .resp_sc_success_o(icx_resp_sc_success),
        .m_axi_arid_o(m_axi_arid_o),
        .m_axi_araddr_o(m_axi_araddr_o),
        .m_axi_arlen_o(m_axi_arlen_o),
        .m_axi_arsize_o(m_axi_arsize_o),
        .m_axi_arburst_o(m_axi_arburst_o),
        .m_axi_arlock_o(m_axi_arlock_o),
        .m_axi_arcache_o(m_axi_arcache_o),
        .m_axi_arprot_o(m_axi_arprot_o),
        .m_axi_arqos_o(m_axi_arqos_o),
        .m_axi_arvalid_o(m_axi_arvalid_o),
        .m_axi_arready_i(m_axi_arready_i),
        .m_axi_rid_i(m_axi_rid_i),
        .m_axi_rdata_i(m_axi_rdata_i),
        .m_axi_rresp_i(m_axi_rresp_i),
        .m_axi_rlast_i(m_axi_rlast_i),
        .m_axi_rvalid_i(m_axi_rvalid_i),
        .m_axi_rready_o(m_axi_rready_o),
        .m_axi_awid_o(m_axi_awid_o),
        .m_axi_awaddr_o(m_axi_awaddr_o),
        .m_axi_awlen_o(m_axi_awlen_o),
        .m_axi_awsize_o(m_axi_awsize_o),
        .m_axi_awburst_o(m_axi_awburst_o),
        .m_axi_awlock_o(m_axi_awlock_o),
        .m_axi_awcache_o(m_axi_awcache_o),
        .m_axi_awprot_o(m_axi_awprot_o),
        .m_axi_awqos_o(m_axi_awqos_o),
        .m_axi_awvalid_o(m_axi_awvalid_o),
        .m_axi_awready_i(m_axi_awready_i),
        .m_axi_wdata_o(m_axi_wdata_o),
        .m_axi_wstrb_o(m_axi_wstrb_o),
        .m_axi_wlast_o(m_axi_wlast_o),
        .m_axi_wvalid_o(m_axi_wvalid_o),
        .m_axi_wready_i(m_axi_wready_i),
        .m_axi_bid_i(m_axi_bid_i),
        .m_axi_bresp_i(m_axi_bresp_i),
        .m_axi_bvalid_i(m_axi_bvalid_i),
        .m_axi_bready_o(m_axi_bready_o)
    );

endmodule
