`timescale 1ns/1ps
`include "complex/bus/defs.v"

// Elaboration-time selector for the external transport below the L2.  The
// cache sees only the neutral beat request/response channel at the top of this
// port list.  The inactive external interface is driven to benign values.
module openrv64_complex_external_bus #(
    parameter integer BUS_TYPE = `OPENRV64_COMPLEX_BUS_AXI,
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 256,
    parameter integer AXI_ID_WIDTH = 3,
    parameter [AXI_ID_WIDTH-1:0] AXI_ID = {AXI_ID_WIDTH{1'b1}},
    parameter integer WB_ADDR_SHIFT = $clog2(DATA_WIDTH / 8),
    parameter integer WB_MAX_RETRIES = 8
) (
    input  wire                      clk_i,
    input  wire                      rst_ni,

    input  wire                      req_valid_i,
    output wire                      req_ready_o,
    input  wire                      req_write_i,
    input  wire [63:0]               req_addr_i,
    input  wire [2:0]                req_size_i,
    input  wire [DATA_WIDTH-1:0]     req_wdata_i,
    input  wire [DATA_WIDTH/8-1:0]   req_wstrb_i,
    input  wire                      req_cacheable_i,
    output wire                      resp_valid_o,
    input  wire                      resp_ready_i,
    output wire [DATA_WIDTH-1:0]     resp_rdata_o,
    output wire                      resp_error_o,

    output wire [AXI_ID_WIDTH-1:0]   m_axi_arid_o,
    output wire [ADDR_WIDTH-1:0]     m_axi_araddr_o,
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
    input  wire [DATA_WIDTH-1:0]     m_axi_rdata_i,
    input  wire [1:0]                m_axi_rresp_i,
    input  wire                      m_axi_rlast_i,
    input  wire                      m_axi_rvalid_i,
    output wire                      m_axi_rready_o,

    output wire [AXI_ID_WIDTH-1:0]   m_axi_awid_o,
    output wire [ADDR_WIDTH-1:0]     m_axi_awaddr_o,
    output wire [7:0]                m_axi_awlen_o,
    output wire [2:0]                m_axi_awsize_o,
    output wire [1:0]                m_axi_awburst_o,
    output wire                      m_axi_awlock_o,
    output wire [3:0]                m_axi_awcache_o,
    output wire [2:0]                m_axi_awprot_o,
    output wire [3:0]                m_axi_awqos_o,
    output wire                      m_axi_awvalid_o,
    input  wire                      m_axi_awready_i,
    output wire [DATA_WIDTH-1:0]     m_axi_wdata_o,
    output wire [DATA_WIDTH/8-1:0]   m_axi_wstrb_o,
    output wire                      m_axi_wlast_o,
    output wire                      m_axi_wvalid_o,
    input  wire                      m_axi_wready_i,
    input  wire [AXI_ID_WIDTH-1:0]   m_axi_bid_i,
    input  wire [1:0]                m_axi_bresp_i,
    input  wire                      m_axi_bvalid_i,
    output wire                      m_axi_bready_o,

    output wire                      wb_cyc_o,
    output wire                      wb_stb_o,
    output wire                      wb_we_o,
    output wire [ADDR_WIDTH-1:0]     wb_adr_o,
    output wire [DATA_WIDTH-1:0]     wb_dat_o,
    output wire [DATA_WIDTH/8-1:0]   wb_sel_o,
    output wire [2:0]                wb_cti_o,
    output wire [1:0]                wb_bte_o,
    output wire                      wb_lock_o,
    input  wire                      wb_stall_i,
    input  wire                      wb_ack_i,
    input  wire                      wb_err_i,
    input  wire                      wb_rty_i,
    input  wire [DATA_WIDTH-1:0]     wb_dat_i
);

    generate
        if (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) begin : g_axi
            openrv64_complex_axi_backend #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH),
                .ID_WIDTH(AXI_ID_WIDTH),
                .AXI_ID(AXI_ID)
            ) u_backend (
                .clk_i(clk_i),
                .rst_ni(rst_ni),
                .req_valid_i(req_valid_i),
                .req_ready_o(req_ready_o),
                .req_write_i(req_write_i),
                .req_addr_i(req_addr_i),
                .req_size_i(req_size_i),
                .req_wdata_i(req_wdata_i),
                .req_wstrb_i(req_wstrb_i),
                .req_cacheable_i(req_cacheable_i),
                .resp_valid_o(resp_valid_o),
                .resp_ready_i(resp_ready_i),
                .resp_rdata_o(resp_rdata_o),
                .resp_error_o(resp_error_o),
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

            assign wb_cyc_o = 1'b0;
            assign wb_stb_o = 1'b0;
            assign wb_we_o = 1'b0;
            assign wb_adr_o = {ADDR_WIDTH{1'b0}};
            assign wb_dat_o = {DATA_WIDTH{1'b0}};
            assign wb_sel_o = {DATA_WIDTH/8{1'b0}};
            assign wb_cti_o = 3'b000;
            assign wb_bte_o = 2'b00;
            assign wb_lock_o = 1'b0;
        end else if (BUS_TYPE == `OPENRV64_COMPLEX_BUS_WISHBONE) begin : g_wb
            openrv64_complex_wishbone_backend #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_SHIFT(WB_ADDR_SHIFT),
                .MAX_RETRIES(WB_MAX_RETRIES)
            ) u_backend (
                .clk_i(clk_i),
                .rst_ni(rst_ni),
                .req_valid_i(req_valid_i),
                .req_ready_o(req_ready_o),
                .req_write_i(req_write_i),
                .req_addr_i(req_addr_i),
                .req_size_i(req_size_i),
                .req_wdata_i(req_wdata_i),
                .req_wstrb_i(req_wstrb_i),
                .req_cacheable_i(req_cacheable_i),
                .resp_valid_o(resp_valid_o),
                .resp_ready_i(resp_ready_i),
                .resp_rdata_o(resp_rdata_o),
                .resp_error_o(resp_error_o),
                .wb_cyc_o(wb_cyc_o),
                .wb_stb_o(wb_stb_o),
                .wb_we_o(wb_we_o),
                .wb_adr_o(wb_adr_o),
                .wb_dat_o(wb_dat_o),
                .wb_sel_o(wb_sel_o),
                .wb_cti_o(wb_cti_o),
                .wb_bte_o(wb_bte_o),
                .wb_lock_o(wb_lock_o),
                .wb_stall_i(wb_stall_i),
                .wb_ack_i(wb_ack_i),
                .wb_err_i(wb_err_i),
                .wb_rty_i(wb_rty_i),
                .wb_dat_i(wb_dat_i)
            );

            assign m_axi_arid_o = {AXI_ID_WIDTH{1'b0}};
            assign m_axi_araddr_o = {ADDR_WIDTH{1'b0}};
            assign m_axi_arlen_o = 8'd0;
            assign m_axi_arsize_o = 3'd0;
            assign m_axi_arburst_o = 2'b01;
            assign m_axi_arlock_o = 1'b0;
            assign m_axi_arcache_o = 4'd0;
            assign m_axi_arprot_o = 3'd0;
            assign m_axi_arqos_o = 4'd0;
            assign m_axi_arvalid_o = 1'b0;
            assign m_axi_rready_o = 1'b0;
            assign m_axi_awid_o = {AXI_ID_WIDTH{1'b0}};
            assign m_axi_awaddr_o = {ADDR_WIDTH{1'b0}};
            assign m_axi_awlen_o = 8'd0;
            assign m_axi_awsize_o = 3'd0;
            assign m_axi_awburst_o = 2'b01;
            assign m_axi_awlock_o = 1'b0;
            assign m_axi_awcache_o = 4'd0;
            assign m_axi_awprot_o = 3'd0;
            assign m_axi_awqos_o = 4'd0;
            assign m_axi_awvalid_o = 1'b0;
            assign m_axi_wdata_o = {DATA_WIDTH{1'b0}};
            assign m_axi_wstrb_o = {DATA_WIDTH/8{1'b0}};
            assign m_axi_wlast_o = 1'b1;
            assign m_axi_wvalid_o = 1'b0;
            assign m_axi_bready_o = 1'b0;
        end else begin : g_bad_bus
            initial $fatal(1, "unsupported core-complex BUS_TYPE");

            assign req_ready_o = 1'b0;
            assign resp_valid_o = 1'b0;
            assign resp_rdata_o = {DATA_WIDTH{1'b0}};
            assign resp_error_o = 1'b1;
            assign m_axi_arid_o = {AXI_ID_WIDTH{1'b0}};
            assign m_axi_araddr_o = {ADDR_WIDTH{1'b0}};
            assign m_axi_arlen_o = 8'd0;
            assign m_axi_arsize_o = 3'd0;
            assign m_axi_arburst_o = 2'b01;
            assign m_axi_arlock_o = 1'b0;
            assign m_axi_arcache_o = 4'd0;
            assign m_axi_arprot_o = 3'd0;
            assign m_axi_arqos_o = 4'd0;
            assign m_axi_arvalid_o = 1'b0;
            assign m_axi_rready_o = 1'b0;
            assign m_axi_awid_o = {AXI_ID_WIDTH{1'b0}};
            assign m_axi_awaddr_o = {ADDR_WIDTH{1'b0}};
            assign m_axi_awlen_o = 8'd0;
            assign m_axi_awsize_o = 3'd0;
            assign m_axi_awburst_o = 2'b01;
            assign m_axi_awlock_o = 1'b0;
            assign m_axi_awcache_o = 4'd0;
            assign m_axi_awprot_o = 3'd0;
            assign m_axi_awqos_o = 4'd0;
            assign m_axi_awvalid_o = 1'b0;
            assign m_axi_wdata_o = {DATA_WIDTH{1'b0}};
            assign m_axi_wstrb_o = {DATA_WIDTH/8{1'b0}};
            assign m_axi_wlast_o = 1'b1;
            assign m_axi_wvalid_o = 1'b0;
            assign m_axi_bready_o = 1'b0;
            assign wb_cyc_o = 1'b0;
            assign wb_stb_o = 1'b0;
            assign wb_we_o = 1'b0;
            assign wb_adr_o = {ADDR_WIDTH{1'b0}};
            assign wb_dat_o = {DATA_WIDTH{1'b0}};
            assign wb_sel_o = {DATA_WIDTH/8{1'b0}};
            assign wb_cti_o = 3'b000;
            assign wb_bte_o = 2'b00;
            assign wb_lock_o = 1'b0;
        end
    endgenerate

endmodule
