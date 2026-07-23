`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "complex/bus/defs.v"

// Generated 1-16 hart core complex.  Each legacy northbound port receives a
// fixed HART_ID_BASE + slice number, requests arbitrate onto CCX, and the
// shared L2 terminates CCX before the selected external bus backend.
module openrv64_core_complex_nh #(
    parameter integer NUM_HARTS = 2,
    parameter integer HART_ID_BASE = 0,
    parameter [`OPENRV64_CCX_ATTR_WIDTH-1:0] DEFAULT_ATTR =
        `OPENRV64_CCX_ATTR_CACHEABLE,
    parameter integer L2_BYTES = 256 * 1024,
    parameter integer L2_LINE_BYTES = 64,
    parameter integer L2_WAYS = 8,
    parameter integer L2_MERGE_ENTRIES = 16,
    parameter integer L2_BUS_DATA_WIDTH = 256,
    parameter integer BUS_TYPE = `OPENRV64_COMPLEX_BUS_AXI,
    parameter integer BUS_ADDR_WIDTH = 64,
    parameter integer BUS_DATA_WIDTH = 256,
    parameter integer GENBUS_READ_BUFFER_DEPTH = 4,
    parameter integer GENBUS_WRITE_BUFFER_DEPTH = 4,
    parameter integer AXI_ID_WIDTH = 3,
    parameter [AXI_ID_WIDTH-1:0] AXI_ID = {AXI_ID_WIDTH{1'b1}},
    parameter integer WB_ADDR_SHIFT = $clog2(BUS_DATA_WIDTH / 8),
    parameter integer WB_MAX_RETRIES = 8
) (
    input  wire clk_i,
    input  wire rst_ni,

    input  wire [NUM_HARTS-1:0]    core_mem_valid_i,
    output wire [NUM_HARTS-1:0]    core_mem_ready_o,
    input  wire [NUM_HARTS-1:0]    core_mem_write_i,
    input  wire [NUM_HARTS*64-1:0] core_mem_addr_i,
    input  wire [NUM_HARTS*64-1:0] core_mem_wdata_i,
    input  wire [NUM_HARTS*8-1:0]  core_mem_wstrb_i,
    output wire [NUM_HARTS*64-1:0] core_mem_rdata_o,
    output wire [NUM_HARTS-1:0]    core_mem_error_o,

    output wire [AXI_ID_WIDTH-1:0]     m_axi_arid_o,
    output wire [BUS_ADDR_WIDTH-1:0]   m_axi_araddr_o,
    output wire [7:0]                  m_axi_arlen_o,
    output wire [2:0]                  m_axi_arsize_o,
    output wire [1:0]                  m_axi_arburst_o,
    output wire                        m_axi_arlock_o,
    output wire [3:0]                  m_axi_arcache_o,
    output wire [2:0]                  m_axi_arprot_o,
    output wire [3:0]                  m_axi_arqos_o,
    output wire                        m_axi_arvalid_o,
    input  wire                        m_axi_arready_i,
    input  wire [AXI_ID_WIDTH-1:0]     m_axi_rid_i,
    input  wire [BUS_DATA_WIDTH-1:0]   m_axi_rdata_i,
    input  wire [1:0]                  m_axi_rresp_i,
    input  wire                        m_axi_rlast_i,
    input  wire                        m_axi_rvalid_i,
    output wire                        m_axi_rready_o,

    output wire [AXI_ID_WIDTH-1:0]     m_axi_awid_o,
    output wire [BUS_ADDR_WIDTH-1:0]   m_axi_awaddr_o,
    output wire [7:0]                  m_axi_awlen_o,
    output wire [2:0]                  m_axi_awsize_o,
    output wire [1:0]                  m_axi_awburst_o,
    output wire                        m_axi_awlock_o,
    output wire [3:0]                  m_axi_awcache_o,
    output wire [2:0]                  m_axi_awprot_o,
    output wire [3:0]                  m_axi_awqos_o,
    output wire                        m_axi_awvalid_o,
    input  wire                        m_axi_awready_i,
    output wire [BUS_DATA_WIDTH-1:0]   m_axi_wdata_o,
    output wire [BUS_DATA_WIDTH/8-1:0] m_axi_wstrb_o,
    output wire                        m_axi_wlast_o,
    output wire                        m_axi_wvalid_o,
    input  wire                        m_axi_wready_i,
    input  wire [AXI_ID_WIDTH-1:0]     m_axi_bid_i,
    input  wire [1:0]                  m_axi_bresp_i,
    input  wire                        m_axi_bvalid_i,
    output wire                        m_axi_bready_o,

    output wire                        wb_cyc_o,
    output wire                        wb_stb_o,
    output wire                        wb_we_o,
    output wire [BUS_ADDR_WIDTH-1:0]   wb_adr_o,
    output wire [BUS_DATA_WIDTH-1:0]   wb_dat_o,
    output wire [BUS_DATA_WIDTH/8-1:0] wb_sel_o,
    output wire [2:0]                  wb_cti_o,
    output wire [1:0]                  wb_bte_o,
    output wire                        wb_lock_o,
    input  wire                        wb_stall_i,
    input  wire                        wb_ack_i,
    input  wire                        wb_err_i,
    input  wire                        wb_rty_i,
    input  wire [BUS_DATA_WIDTH-1:0]   wb_dat_i
);

    wire [NUM_HARTS-1:0] ccx_req_valid;
    wire [NUM_HARTS-1:0] ccx_req_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart_id;
    wire [NUM_HARTS*`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id;
    wire [NUM_HARTS*`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op;
    wire [NUM_HARTS-1:0] ccx_req_lock;
    wire [NUM_HARTS*`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order;
    wire [NUM_HARTS*`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind;
    wire [NUM_HARTS*`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr;
    wire [NUM_HARTS*3-1:0] ccx_req_size;
    wire [NUM_HARTS*64-1:0] ccx_req_addr;
    wire [NUM_HARTS*64-1:0] ccx_req_wdata;
    wire [NUM_HARTS*8-1:0] ccx_req_wstrb;

    wire [NUM_HARTS-1:0] ccx_resp_valid;
    wire [NUM_HARTS-1:0] ccx_resp_ready;
    wire [NUM_HARTS*`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id;
    wire [NUM_HARTS*`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id;
    wire [NUM_HARTS*64-1:0] ccx_resp_rdata;
    wire [NUM_HARTS-1:0] ccx_resp_error;
    wire [NUM_HARTS-1:0] ccx_resp_sc_success;

    wire shared_req_valid;
    wire shared_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] shared_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] shared_req_txn_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] shared_req_op;
    wire shared_req_lock;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] shared_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] shared_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] shared_req_attr;
    wire [2:0] shared_req_size;
    wire [63:0] shared_req_addr;
    wire [63:0] shared_req_wdata;
    wire [7:0] shared_req_wstrb;
    wire shared_resp_valid;
    wire shared_resp_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] shared_resp_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] shared_resp_txn_id;
    wire [63:0] shared_resp_rdata;
    wire shared_resp_error;
    wire shared_resp_sc_success;

    wire bus_req_valid;
    wire bus_req_ready;
    wire bus_req_write;
    wire [63:0] bus_req_addr;
    wire [2:0] bus_req_size;
    wire [L2_BUS_DATA_WIDTH-1:0] bus_req_wdata;
    wire [L2_BUS_DATA_WIDTH/8-1:0] bus_req_wstrb;
    wire bus_req_cacheable;
    wire bus_resp_valid;
    wire bus_resp_ready;
    wire [L2_BUS_DATA_WIDTH-1:0] bus_resp_rdata;
    wire bus_resp_error;

    genvar hart_index;
    generate
        for (hart_index = 0; hart_index < NUM_HARTS;
             hart_index = hart_index + 1) begin : g_harts
            localparam [`OPENRV64_CCX_HART_ID_WIDTH-1:0] THIS_HART_ID =
                `OPENRV64_CCX_HART_ID_WIDTH'(HART_ID_BASE + hart_index);

            openrv64_ccx_hart_legacy_adapter #(
                .HART_ID(THIS_HART_ID),
                .DEFAULT_ATTR(DEFAULT_ATTR)
            ) u_hart_adapter (
                .clk_i(clk_i),
                .rst_ni(rst_ni),
                .core_valid_i(core_mem_valid_i[hart_index]),
                .core_ready_o(core_mem_ready_o[hart_index]),
                .core_write_i(core_mem_write_i[hart_index]),
                .core_addr_i(core_mem_addr_i[hart_index*64 +: 64]),
                .core_wdata_i(core_mem_wdata_i[hart_index*64 +: 64]),
                .core_wstrb_i(core_mem_wstrb_i[hart_index*8 +: 8]),
                .core_rdata_o(core_mem_rdata_o[hart_index*64 +: 64]),
                .core_error_o(core_mem_error_o[hart_index]),
                .req_valid_o(ccx_req_valid[hart_index]),
                .req_ready_i(ccx_req_ready[hart_index]),
                .req_hart_id_o(ccx_req_hart_id[
                    hart_index*`OPENRV64_CCX_HART_ID_WIDTH +:
                    `OPENRV64_CCX_HART_ID_WIDTH]),
                .req_txn_id_o(ccx_req_txn_id[
                    hart_index*`OPENRV64_CCX_TXN_ID_WIDTH +:
                    `OPENRV64_CCX_TXN_ID_WIDTH]),
                .req_op_o(ccx_req_op[
                    hart_index*`OPENRV64_CCX_OP_WIDTH +:
                    `OPENRV64_CCX_OP_WIDTH]),
                .req_lock_o(ccx_req_lock[hart_index]),
                .req_order_o(ccx_req_order[
                    hart_index*`OPENRV64_CCX_ORDER_WIDTH +:
                    `OPENRV64_CCX_ORDER_WIDTH]),
                .req_kind_o(ccx_req_kind[
                    hart_index*`OPENRV64_CCX_KIND_WIDTH +:
                    `OPENRV64_CCX_KIND_WIDTH]),
                .req_attr_o(ccx_req_attr[
                    hart_index*`OPENRV64_CCX_ATTR_WIDTH +:
                    `OPENRV64_CCX_ATTR_WIDTH]),
                .req_size_o(ccx_req_size[hart_index*3 +: 3]),
                .req_addr_o(ccx_req_addr[hart_index*64 +: 64]),
                .req_wdata_o(ccx_req_wdata[hart_index*64 +: 64]),
                .req_wstrb_o(ccx_req_wstrb[hart_index*8 +: 8]),
                .resp_valid_i(ccx_resp_valid[hart_index]),
                .resp_ready_o(ccx_resp_ready[hart_index]),
                .resp_hart_id_i(ccx_resp_hart_id[
                    hart_index*`OPENRV64_CCX_HART_ID_WIDTH +:
                    `OPENRV64_CCX_HART_ID_WIDTH]),
                .resp_txn_id_i(ccx_resp_txn_id[
                    hart_index*`OPENRV64_CCX_TXN_ID_WIDTH +:
                    `OPENRV64_CCX_TXN_ID_WIDTH]),
                .resp_rdata_i(ccx_resp_rdata[hart_index*64 +: 64]),
                .resp_error_i(ccx_resp_error[hart_index]),
                .resp_sc_success_i(ccx_resp_sc_success[hart_index])
            );
        end
    endgenerate

    openrv64_ccx_crossbar #(
        .NUM_HARTS(NUM_HARTS)
    ) u_crossbar (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .hart_req_valid_i(ccx_req_valid),
        .hart_req_ready_o(ccx_req_ready),
        .hart_req_hart_id_i(ccx_req_hart_id),
        .hart_req_txn_id_i(ccx_req_txn_id),
        .hart_req_op_i(ccx_req_op),
        .hart_req_lock_i(ccx_req_lock),
        .hart_req_order_i(ccx_req_order),
        .hart_req_kind_i(ccx_req_kind),
        .hart_req_attr_i(ccx_req_attr),
        .hart_req_size_i(ccx_req_size),
        .hart_req_addr_i(ccx_req_addr),
        .hart_req_wdata_i(ccx_req_wdata),
        .hart_req_wstrb_i(ccx_req_wstrb),
        .mem_req_valid_o(shared_req_valid),
        .mem_req_ready_i(shared_req_ready),
        .mem_req_hart_id_o(shared_req_hart_id),
        .mem_req_txn_id_o(shared_req_txn_id),
        .mem_req_op_o(shared_req_op),
        .mem_req_lock_o(shared_req_lock),
        .mem_req_order_o(shared_req_order),
        .mem_req_kind_o(shared_req_kind),
        .mem_req_attr_o(shared_req_attr),
        .mem_req_size_o(shared_req_size),
        .mem_req_addr_o(shared_req_addr),
        .mem_req_wdata_o(shared_req_wdata),
        .mem_req_wstrb_o(shared_req_wstrb),
        .mem_resp_valid_i(shared_resp_valid),
        .mem_resp_ready_o(shared_resp_ready),
        .mem_resp_hart_id_i(shared_resp_hart_id),
        .mem_resp_txn_id_i(shared_resp_txn_id),
        .mem_resp_rdata_i(shared_resp_rdata),
        .mem_resp_error_i(shared_resp_error),
        .mem_resp_sc_success_i(shared_resp_sc_success),
        .hart_resp_valid_o(ccx_resp_valid),
        .hart_resp_ready_i(ccx_resp_ready),
        .hart_resp_hart_id_o(ccx_resp_hart_id),
        .hart_resp_txn_id_o(ccx_resp_txn_id),
        .hart_resp_rdata_o(ccx_resp_rdata),
        .hart_resp_error_o(ccx_resp_error),
        .hart_resp_sc_success_o(ccx_resp_sc_success)
    );

    openrv64_ccx_l2 #(
        .ADDR_WIDTH(BUS_ADDR_WIDTH),
        .BUS_DATA_WIDTH(L2_BUS_DATA_WIDTH),
        .CACHE_BYTES(L2_BYTES),
        .LINE_BYTES(L2_LINE_BYTES),
        .WAYS(L2_WAYS),
        .MERGE_ENTRIES(L2_MERGE_ENTRIES)
    ) u_l2 (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .req_valid_i(shared_req_valid),
        .req_ready_o(shared_req_ready),
        .req_hart_id_i(shared_req_hart_id),
        .req_txn_id_i(shared_req_txn_id),
        .req_op_i(shared_req_op),
        .req_lock_i(shared_req_lock),
        .req_order_i(shared_req_order),
        .req_kind_i(shared_req_kind),
        .req_attr_i(shared_req_attr),
        .req_size_i(shared_req_size),
        .req_addr_i(shared_req_addr),
        .req_wdata_i(shared_req_wdata),
        .req_wstrb_i(shared_req_wstrb),
        .resp_valid_o(shared_resp_valid),
        .resp_ready_i(shared_resp_ready),
        .resp_hart_id_o(shared_resp_hart_id),
        .resp_txn_id_o(shared_resp_txn_id),
        .resp_rdata_o(shared_resp_rdata),
        .resp_error_o(shared_resp_error),
        .resp_sc_success_o(shared_resp_sc_success),
        .bus_req_valid_o(bus_req_valid),
        .bus_req_ready_i(bus_req_ready),
        .bus_req_write_o(bus_req_write),
        .bus_req_addr_o(bus_req_addr),
        .bus_req_size_o(bus_req_size),
        .bus_req_wdata_o(bus_req_wdata),
        .bus_req_wstrb_o(bus_req_wstrb),
        .bus_req_cacheable_o(bus_req_cacheable),
        .bus_resp_valid_i(bus_resp_valid),
        .bus_resp_ready_o(bus_resp_ready),
        .bus_resp_rdata_i(bus_resp_rdata),
        .bus_resp_error_i(bus_resp_error)
    );

    genbus_interface #(
        .BUS_TYPE(BUS_TYPE),
        .ADDR_WIDTH(BUS_ADDR_WIDTH),
        .UPSTREAM_DATA_WIDTH(L2_BUS_DATA_WIDTH),
        .DOWNSTREAM_DATA_WIDTH(BUS_DATA_WIDTH),
        .READ_BUFFER_DEPTH(GENBUS_READ_BUFFER_DEPTH),
        .WRITE_BUFFER_DEPTH(GENBUS_WRITE_BUFFER_DEPTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .AXI_ID(AXI_ID),
        .WB_ADDR_SHIFT(WB_ADDR_SHIFT),
        .WB_MAX_RETRIES(WB_MAX_RETRIES)
    ) u_genbus (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .upstream_req_valid_i(bus_req_valid),
        .upstream_req_ready_o(bus_req_ready),
        .upstream_req_write_i(bus_req_write),
        .upstream_req_addr_i(bus_req_addr),
        .upstream_req_size_i(bus_req_size),
        .upstream_req_burst_i(8'd0),
        .upstream_req_wdata_i(bus_req_wdata),
        .upstream_req_wstrb_i(bus_req_wstrb),
        .upstream_req_cacheable_i(bus_req_cacheable),
        .upstream_resp_valid_o(bus_resp_valid),
        .upstream_resp_ready_i(bus_resp_ready),
        .upstream_resp_rdata_o(bus_resp_rdata),
        .upstream_resp_error_o(bus_resp_error),
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
        .m_axi_bready_o(m_axi_bready_o),
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

    generate
        if ((NUM_HARTS < 1) || (NUM_HARTS > 16)) begin : g_bad_harts
            initial $fatal(1, "core complex supports 1 through 16 harts");
        end
        if ((HART_ID_BASE < 0) ||
            ((HART_ID_BASE + NUM_HARTS) > 16)) begin : g_bad_ids
            initial $fatal(1, "core-complex hart IDs exceed four bits");
        end
        if ((L2_BUS_DATA_WIDTH < 32) ||
            (L2_BUS_DATA_WIDTH > 256) ||
            ((L2_BUS_DATA_WIDTH & (L2_BUS_DATA_WIDTH - 1)) != 0)) begin :
                g_bad_l2_bus_width
            initial $fatal(1,
                "core-complex L2 producer width must be 32 through 256 bits");
        end
    endgenerate

endmodule
