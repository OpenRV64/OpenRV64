`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "complex/bus/defs.v"
`include "soc/bus/mem_map.v"

// Single-hart native CCX home with a shared L2 and a selectable external-bus
// backend.  The private L1I, L1D, and PTW sources are already arbitrated onto
// the one CCX port by openrv64_ccx_bus.  This block retains that native
// identity through the L2, selects AXI or Wishbone in the neutral genbus
// converter, then terminates that external protocol onto the platform's
// existing 64-bit simulation decoder.
module openrv64_soc_ccx_l2_bridge #(
    parameter integer L2_BYTES = 256 * 1024,
    parameter integer L2_WAYS = 8,
    parameter integer L2_MERGE_ENTRIES = 8,
    parameter integer L2_WAITERS_PER_MSHR = 8,
    parameter integer L2_COMMAND_ENTRIES = 16,
    parameter integer L2_RESPONSE_ENTRIES = 16,
    parameter integer GENBUS_READ_BUFFER_DEPTH = 8,
    parameter integer GENBUS_WRITE_BUFFER_DEPTH = 8,
    parameter integer BUS_TYPE = `OPENRV64_COMPLEX_BUS_AXI,
    parameter integer BUS_DATA_WIDTH = 256,
    parameter integer DDR3_ENABLE = 0,
    parameter integer DDR3_READ_QUEUE_DEPTH = 8,
    parameter integer DDR3_WRITE_QUEUE_DEPTH = 8,
    parameter integer DDR3_COMMAND_QUEUE_DEPTH = 16,
    parameter integer MEMORY_TIMING_MODEL = 0,
    parameter integer MEMORY_BYTES = `OPENRV64_SOC_MEMORY_SIZE
) (
    input  wire clk_i,
    input  wire rst_ni,

    input  wire                         ccx_req_valid_i,
    output wire                         ccx_req_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_req_hart_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_req_txn_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_req_source_id_i,
    input  wire [`OPENRV64_CCX_OP_WIDTH-1:0]
                                        ccx_req_op_i,
    input  wire                         ccx_req_lock_i,
    input  wire [`OPENRV64_CCX_ORDER_WIDTH-1:0]
                                        ccx_req_order_i,
    input  wire [`OPENRV64_CCX_KIND_WIDTH-1:0]
                                        ccx_req_kind_i,
    input  wire [`OPENRV64_CCX_ATTR_WIDTH-1:0]
                                        ccx_req_attr_i,
    input  wire [2:0]                   ccx_req_size_i,
    input  wire [63:0]                  ccx_req_addr_i,
    input  wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
                                        ccx_req_burst_len_i,

    input  wire                         ccx_wdata_valid_i,
    output wire                         ccx_wdata_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_wdata_hart_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_wdata_txn_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_wdata_source_id_i,
    input  wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                        ccx_wdata_beat_index_i,
    input  wire                         ccx_wdata_last_i,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                        ccx_wdata_i,
    input  wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
                                        ccx_wstrb_i,

    output wire                         ccx_resp_valid_o,
    input  wire                         ccx_resp_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_resp_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_resp_txn_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_resp_source_id_o,
    output wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                        ccx_resp_beat_index_o,
    output wire                         ccx_resp_last_o,
    output wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                        ccx_resp_rdata_o,
    output wire                         ccx_resp_error_o,
    output wire                         ccx_resp_sc_success_o,

    output wire                         mem_valid_o,
    input  wire                         mem_ready_i,
    output wire                         mem_write_o,
    output wire [63:0]                  mem_addr_o,
    output wire [63:0]                  mem_wdata_o,
    output wire [7:0]                   mem_wstrb_o,
    input  wire [63:0]                  mem_rdata_i,
    input  wire                         mem_error_i,

    output wire                         ram_valid_o,
    input  wire                         ram_ready_i,
    output wire                         ram_write_o,
    output wire [63:0]                  ram_addr_o,
    output wire [BUS_DATA_WIDTH-1:0]    ram_wdata_o,
    output wire [BUS_DATA_WIDTH/8-1:0]  ram_wstrb_o,
    input  wire [BUS_DATA_WIDTH-1:0]    ram_rdata_i,
    input  wire                         ram_error_i
);

    localparam integer AXI_ID_WIDTH = 3;

    wire [AXI_ID_WIDTH-1:0] axi_arid;
    wire [63:0] axi_araddr;
    wire [7:0] axi_arlen;
    wire [2:0] axi_arsize;
    wire [1:0] axi_arburst;
    wire axi_arlock;
    wire [3:0] axi_arcache;
    wire [2:0] axi_arprot;
    wire [3:0] axi_arqos;
    wire axi_arvalid;
    wire axi_arready;
    wire [AXI_ID_WIDTH-1:0] axi_rid;
    wire [BUS_DATA_WIDTH-1:0] axi_rdata;
    wire [1:0] axi_rresp;
    wire axi_rlast;
    wire axi_rvalid;
    wire axi_rready;

    wire [AXI_ID_WIDTH-1:0] axi_awid;
    wire [63:0] axi_awaddr;
    wire [7:0] axi_awlen;
    wire [2:0] axi_awsize;
    wire [1:0] axi_awburst;
    wire axi_awlock;
    wire [3:0] axi_awcache;
    wire [2:0] axi_awprot;
    wire [3:0] axi_awqos;
    wire axi_awvalid;
    wire axi_awready;
    wire [BUS_DATA_WIDTH-1:0] axi_wdata;
    wire [BUS_DATA_WIDTH/8-1:0] axi_wstrb;
    wire axi_wlast;
    wire axi_wvalid;
    wire axi_wready;
    wire [AXI_ID_WIDTH-1:0] axi_bid;
    wire [1:0] axi_bresp;
    wire axi_bvalid;
    wire axi_bready;

    wire scalar_arready;
    wire [AXI_ID_WIDTH-1:0] scalar_rid;
    wire [BUS_DATA_WIDTH-1:0] scalar_rdata;
    wire [1:0] scalar_rresp;
    wire scalar_rlast;
    wire scalar_rvalid;
    wire scalar_awready;
    wire scalar_wready;
    wire [AXI_ID_WIDTH-1:0] scalar_bid;
    wire [1:0] scalar_bresp;
    wire scalar_bvalid;

    wire wide_arready;
    wire [AXI_ID_WIDTH-1:0] wide_rid;
    wire [BUS_DATA_WIDTH-1:0] wide_rdata;
    wire [1:0] wide_rresp;
    wire wide_rlast;
    wire wide_rvalid;
    wire wide_awready;
    wire wide_wready;
    wire [AXI_ID_WIDTH-1:0] wide_bid;
    wire [1:0] wide_bresp;
    wire wide_bvalid;

    reg read_route_active_q;
    reg read_route_ram_q;
    reg write_route_active_q;
    reg write_route_ram_q;

    wire ar_targets_ram =
        (axi_araddr >= `OPENRV64_SOC_MEMORY_BASE) &&
        (axi_araddr < (`OPENRV64_SOC_MEMORY_BASE + MEMORY_BYTES));
    wire aw_targets_ram =
        (axi_awaddr >= `OPENRV64_SOC_MEMORY_BASE) &&
        (axi_awaddr < (`OPENRV64_SOC_MEMORY_BASE + MEMORY_BYTES));
    wire scalar_arvalid = axi_arvalid && !read_route_active_q &&
                          !ar_targets_ram;
    wire wide_arvalid = axi_arvalid && !read_route_active_q &&
                        ar_targets_ram;
    wire scalar_awvalid = axi_awvalid && !write_route_active_q &&
                          !aw_targets_ram;
    wire wide_awvalid = axi_awvalid && !write_route_active_q &&
                        aw_targets_ram;
    wire scalar_wvalid = axi_wvalid && write_route_active_q &&
                         !write_route_ram_q;
    wire wide_wvalid = axi_wvalid && write_route_active_q &&
                       write_route_ram_q;
    wire scalar_rready = axi_rready && read_route_active_q &&
                         !read_route_ram_q;
    wire wide_rready = axi_rready && read_route_active_q &&
                       read_route_ram_q;
    wire scalar_bready = axi_bready && write_route_active_q &&
                         !write_route_ram_q;
    wire wide_bready = axi_bready && write_route_active_q &&
                       write_route_ram_q;
    wire axi_ar_fire = axi_arvalid && axi_arready;
    wire axi_r_fire = axi_rvalid && axi_rready;
    wire axi_aw_fire = axi_awvalid && axi_awready;
    wire axi_b_fire = axi_bvalid && axi_bready;

    assign axi_arready = !read_route_active_q &&
        (ar_targets_ram ? wide_arready : scalar_arready);
    assign axi_rid = read_route_ram_q ? wide_rid : scalar_rid;
    assign axi_rdata = read_route_ram_q ? wide_rdata : scalar_rdata;
    assign axi_rresp = read_route_ram_q ? wide_rresp : scalar_rresp;
    assign axi_rlast = read_route_ram_q ? wide_rlast : scalar_rlast;
    assign axi_rvalid = read_route_active_q &&
        (read_route_ram_q ? wide_rvalid : scalar_rvalid);

    assign axi_awready = !write_route_active_q &&
        (aw_targets_ram ? wide_awready : scalar_awready);
    assign axi_wready = write_route_active_q &&
        (write_route_ram_q ? wide_wready : scalar_wready);
    assign axi_bid = write_route_ram_q ? wide_bid : scalar_bid;
    assign axi_bresp = write_route_ram_q ? wide_bresp : scalar_bresp;
    assign axi_bvalid = write_route_active_q &&
        (write_route_ram_q ? wide_bvalid : scalar_bvalid);

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_route_active_q <= 1'b0;
            read_route_ram_q <= 1'b0;
            write_route_active_q <= 1'b0;
            write_route_ram_q <= 1'b0;
        end else begin
            if (axi_ar_fire) begin
                read_route_active_q <= 1'b1;
                read_route_ram_q <= ar_targets_ram;
            end
            if (axi_r_fire && axi_rlast)
                read_route_active_q <= 1'b0;

            if (axi_aw_fire) begin
                write_route_active_q <= 1'b1;
                write_route_ram_q <= aw_targets_ram;
            end
            if (axi_b_fire)
                write_route_active_q <= 1'b0;
        end
    end

    wire wb_cyc;
    wire wb_stb;
    wire wb_we;
    wire [63:0] wb_adr;
    wire [63:0] wb_dat_o;
    wire [7:0] wb_sel;
    wire [2:0] wb_cti;
    wire [1:0] wb_bte;
    wire wb_lock;
    wire wb_request = wb_cyc && wb_stb;
    wire wb_complete = wb_request && mem_ready_i;

    wire axi_scalar_mem_valid;
    wire axi_scalar_mem_write;
    wire [63:0] axi_scalar_mem_addr;
    wire [63:0] axi_scalar_mem_wdata;
    wire [7:0] axi_scalar_mem_wstrb;
    wire axi_wide_mem_valid;
    wire axi_wide_mem_write;
    wire [63:0] axi_wide_mem_addr;
    wire [BUS_DATA_WIDTH-1:0] axi_wide_mem_wdata;
    wire [BUS_DATA_WIDTH/8-1:0] axi_wide_mem_wstrb;

    assign mem_valid_o =
        (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) ?
        axi_scalar_mem_valid : wb_request;
    assign mem_write_o =
        (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) ?
        axi_scalar_mem_write : wb_we;
    assign mem_addr_o =
        (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) ?
        axi_scalar_mem_addr : (wb_adr << 3);
    assign mem_wdata_o =
        (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) ?
        axi_scalar_mem_wdata : wb_dat_o;
    assign mem_wstrb_o =
        (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) ?
        axi_scalar_mem_wstrb : wb_sel;

    assign ram_valid_o =
        (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) ?
        axi_wide_mem_valid : 1'b0;
    assign ram_write_o = axi_wide_mem_write;
    assign ram_addr_o = axi_wide_mem_addr;
    assign ram_wdata_o = axi_wide_mem_wdata;
    assign ram_wstrb_o = axi_wide_mem_wstrb;

    openrv64_core_complex_nh #(
        .NUM_HARTS(1),
        .HART_ID_BASE(0),
        .L2_BYTES(L2_BYTES),
        .L2_LINE_BYTES(`OPENRV64_CCX_LINE_BYTES),
        .L2_WAYS(L2_WAYS),
        .L2_MERGE_ENTRIES(L2_MERGE_ENTRIES),
        .L2_WAITERS_PER_MSHR(L2_WAITERS_PER_MSHR),
        .L2_COMMAND_ENTRIES(L2_COMMAND_ENTRIES),
        .L2_RESPONSE_ENTRIES(L2_RESPONSE_ENTRIES),
        .L2_BUS_DATA_WIDTH(`OPENRV64_CCX_LINE_DATA_WIDTH),
        .BUS_TYPE(BUS_TYPE),
        .BUS_ADDR_WIDTH(64),
        .BUS_DATA_WIDTH(BUS_DATA_WIDTH),
        .GENBUS_READ_BUFFER_DEPTH(GENBUS_READ_BUFFER_DEPTH),
        .GENBUS_WRITE_BUFFER_DEPTH(GENBUS_WRITE_BUFFER_DEPTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .WB_ADDR_SHIFT(3),
        .WB_MAX_RETRIES(0)
    ) u_complex (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .ccx_req_valid_i(ccx_req_valid_i),
        .ccx_req_ready_o(ccx_req_ready_o),
        .ccx_req_hart_id_i(ccx_req_hart_id_i),
        .ccx_req_txn_id_i(ccx_req_txn_id_i),
        .ccx_req_source_id_i(ccx_req_source_id_i),
        .ccx_req_op_i(ccx_req_op_i),
        .ccx_req_lock_i(ccx_req_lock_i),
        .ccx_req_order_i(ccx_req_order_i),
        .ccx_req_kind_i(ccx_req_kind_i),
        .ccx_req_attr_i(ccx_req_attr_i),
        .ccx_req_size_i(ccx_req_size_i),
        .ccx_req_addr_i(ccx_req_addr_i),
        .ccx_req_burst_len_i(ccx_req_burst_len_i),
        .ccx_wdata_valid_i(ccx_wdata_valid_i),
        .ccx_wdata_ready_o(ccx_wdata_ready_o),
        .ccx_wdata_hart_id_i(ccx_wdata_hart_id_i),
        .ccx_wdata_txn_id_i(ccx_wdata_txn_id_i),
        .ccx_wdata_source_id_i(ccx_wdata_source_id_i),
        .ccx_wdata_beat_index_i(ccx_wdata_beat_index_i),
        .ccx_wdata_last_i(ccx_wdata_last_i),
        .ccx_wdata_i(ccx_wdata_i),
        .ccx_wstrb_i(ccx_wstrb_i),
        .ccx_resp_valid_o(ccx_resp_valid_o),
        .ccx_resp_ready_i(ccx_resp_ready_i),
        .ccx_resp_hart_id_o(ccx_resp_hart_id_o),
        .ccx_resp_txn_id_o(ccx_resp_txn_id_o),
        .ccx_resp_source_id_o(ccx_resp_source_id_o),
        .ccx_resp_beat_index_o(ccx_resp_beat_index_o),
        .ccx_resp_last_o(ccx_resp_last_o),
        .ccx_resp_rdata_o(ccx_resp_rdata_o),
        .ccx_resp_error_o(ccx_resp_error_o),
        .ccx_resp_sc_success_o(ccx_resp_sc_success_o),
        .m_axi_arid_o(axi_arid),
        .m_axi_araddr_o(axi_araddr),
        .m_axi_arlen_o(axi_arlen),
        .m_axi_arsize_o(axi_arsize),
        .m_axi_arburst_o(axi_arburst),
        .m_axi_arlock_o(axi_arlock),
        .m_axi_arcache_o(axi_arcache),
        .m_axi_arprot_o(axi_arprot),
        .m_axi_arqos_o(axi_arqos),
        .m_axi_arvalid_o(axi_arvalid),
        .m_axi_arready_i(axi_arready),
        .m_axi_rid_i(axi_rid),
        .m_axi_rdata_i(axi_rdata),
        .m_axi_rresp_i(axi_rresp),
        .m_axi_rlast_i(axi_rlast),
        .m_axi_rvalid_i(axi_rvalid),
        .m_axi_rready_o(axi_rready),
        .m_axi_awid_o(axi_awid),
        .m_axi_awaddr_o(axi_awaddr),
        .m_axi_awlen_o(axi_awlen),
        .m_axi_awsize_o(axi_awsize),
        .m_axi_awburst_o(axi_awburst),
        .m_axi_awlock_o(axi_awlock),
        .m_axi_awcache_o(axi_awcache),
        .m_axi_awprot_o(axi_awprot),
        .m_axi_awqos_o(axi_awqos),
        .m_axi_awvalid_o(axi_awvalid),
        .m_axi_awready_i(axi_awready),
        .m_axi_wdata_o(axi_wdata),
        .m_axi_wstrb_o(axi_wstrb),
        .m_axi_wlast_o(axi_wlast),
        .m_axi_wvalid_o(axi_wvalid),
        .m_axi_wready_i(axi_wready),
        .m_axi_bid_i(axi_bid),
        .m_axi_bresp_i(axi_bresp),
        .m_axi_bvalid_i(axi_bvalid),
        .m_axi_bready_o(axi_bready),
        .wb_cyc_o(wb_cyc),
        .wb_stb_o(wb_stb),
        .wb_we_o(wb_we),
        .wb_adr_o(wb_adr),
        .wb_dat_o(wb_dat_o),
        .wb_sel_o(wb_sel),
        .wb_cti_o(wb_cti),
        .wb_bte_o(wb_bte),
        .wb_lock_o(wb_lock),
        .wb_stall_i((BUS_TYPE == `OPENRV64_COMPLEX_BUS_WISHBONE) &&
                    wb_request && !mem_ready_i),
        .wb_ack_i((BUS_TYPE == `OPENRV64_COMPLEX_BUS_WISHBONE) &&
                  wb_complete && !mem_error_i),
        .wb_err_i((BUS_TYPE == `OPENRV64_COMPLEX_BUS_WISHBONE) &&
                  wb_complete && mem_error_i),
        .wb_rty_i(1'b0),
        .wb_dat_i(mem_rdata_i)
    );

    openrv64_soc_axi_to_scalar #(
        .ADDR_WIDTH(64),
        .DATA_WIDTH(BUS_DATA_WIDTH),
        .ID_WIDTH(AXI_ID_WIDTH)
    ) u_axi_termination (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .s_axi_arid_i(axi_arid),
        .s_axi_araddr_i(axi_araddr),
        .s_axi_arlen_i(axi_arlen),
        .s_axi_arsize_i(axi_arsize),
        .s_axi_arburst_i(axi_arburst),
        .s_axi_arvalid_i(scalar_arvalid),
        .s_axi_arready_o(scalar_arready),
        .s_axi_rid_o(scalar_rid),
        .s_axi_rdata_o(scalar_rdata),
        .s_axi_rresp_o(scalar_rresp),
        .s_axi_rlast_o(scalar_rlast),
        .s_axi_rvalid_o(scalar_rvalid),
        .s_axi_rready_i(scalar_rready),
        .s_axi_awid_i(axi_awid),
        .s_axi_awaddr_i(axi_awaddr),
        .s_axi_awlen_i(axi_awlen),
        .s_axi_awsize_i(axi_awsize),
        .s_axi_awburst_i(axi_awburst),
        .s_axi_awvalid_i(scalar_awvalid),
        .s_axi_awready_o(scalar_awready),
        .s_axi_wdata_i(axi_wdata),
        .s_axi_wstrb_i(axi_wstrb),
        .s_axi_wlast_i(axi_wlast),
        .s_axi_wvalid_i(scalar_wvalid),
        .s_axi_wready_o(scalar_wready),
        .s_axi_bid_o(scalar_bid),
        .s_axi_bresp_o(scalar_bresp),
        .s_axi_bvalid_o(scalar_bvalid),
        .s_axi_bready_i(scalar_bready),
        .mem_valid_o(axi_scalar_mem_valid),
        .mem_ready_i((BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) ?
                     mem_ready_i : 1'b0),
        .mem_write_o(axi_scalar_mem_write),
        .mem_addr_o(axi_scalar_mem_addr),
        .mem_wdata_o(axi_scalar_mem_wdata),
        .mem_wstrb_o(axi_scalar_mem_wstrb),
        .mem_rdata_i(mem_rdata_i),
        .mem_error_i(mem_error_i)
    );

    generate
        if (DDR3_ENABLE != 0) begin : g_ddr3_ram
            openrv64_axi_ddr3 #(
                .ADDR_WIDTH(64),
                .DATA_WIDTH(BUS_DATA_WIDTH),
                .ID_WIDTH(AXI_ID_WIDTH),
                .MEM_BASE(`OPENRV64_SOC_MEMORY_BASE),
                .MEM_BYTES(MEMORY_BYTES),
                .READ_QUEUE_DEPTH(DDR3_READ_QUEUE_DEPTH),
                .WRITE_QUEUE_DEPTH(DDR3_WRITE_QUEUE_DEPTH),
                .ZERO_INIT_WORDS(0),
                .COMMAND_QUEUE_DEPTH(DDR3_COMMAND_QUEUE_DEPTH),
                .TIMING_MODEL(MEMORY_TIMING_MODEL)
            ) u_ddr3 (
                .clk_i(clk_i),
                .rst_ni(rst_ni),
                .s_axi_arid_i(axi_arid),
                .s_axi_araddr_i(axi_araddr),
                .s_axi_arlen_i(axi_arlen),
                .s_axi_arsize_i(axi_arsize),
                .s_axi_arburst_i(axi_arburst),
                .s_axi_arlock_i(axi_arlock),
                .s_axi_arcache_i(axi_arcache),
                .s_axi_arprot_i(axi_arprot),
                .s_axi_arqos_i(axi_arqos),
                .s_axi_arvalid_i(wide_arvalid),
                .s_axi_arready_o(wide_arready),
                .s_axi_rid_o(wide_rid),
                .s_axi_rdata_o(wide_rdata),
                .s_axi_rresp_o(wide_rresp),
                .s_axi_rlast_o(wide_rlast),
                .s_axi_rvalid_o(wide_rvalid),
                .s_axi_rready_i(wide_rready),
                .s_axi_awid_i(axi_awid),
                .s_axi_awaddr_i(axi_awaddr),
                .s_axi_awlen_i(axi_awlen),
                .s_axi_awsize_i(axi_awsize),
                .s_axi_awburst_i(axi_awburst),
                .s_axi_awlock_i(axi_awlock),
                .s_axi_awcache_i(axi_awcache),
                .s_axi_awprot_i(axi_awprot),
                .s_axi_awqos_i(axi_awqos),
                .s_axi_awvalid_i(wide_awvalid),
                .s_axi_awready_o(wide_awready),
                .s_axi_wdata_i(axi_wdata),
                .s_axi_wstrb_i(axi_wstrb),
                .s_axi_wlast_i(axi_wlast),
                .s_axi_wvalid_i(wide_wvalid),
                .s_axi_wready_o(wide_wready),
                .s_axi_bid_o(wide_bid),
                .s_axi_bresp_o(wide_bresp),
                .s_axi_bvalid_o(wide_bvalid),
                .s_axi_bready_i(wide_bready)
            );

            assign axi_wide_mem_valid = 1'b0;
            assign axi_wide_mem_write = 1'b0;
            assign axi_wide_mem_addr = 64'd0;
            assign axi_wide_mem_wdata = {BUS_DATA_WIDTH{1'b0}};
            assign axi_wide_mem_wstrb =
                {(BUS_DATA_WIDTH/8){1'b0}};
        end else begin : g_sram_ram
            openrv64_soc_axi_to_wide #(
                .ADDR_WIDTH(64),
                .DATA_WIDTH(BUS_DATA_WIDTH),
                .ID_WIDTH(AXI_ID_WIDTH)
            ) u_axi_ram (
                .clk_i(clk_i),
                .rst_ni(rst_ni),
                .s_axi_arid_i(axi_arid),
                .s_axi_araddr_i(axi_araddr),
                .s_axi_arlen_i(axi_arlen),
                .s_axi_arsize_i(axi_arsize),
                .s_axi_arburst_i(axi_arburst),
                .s_axi_arvalid_i(wide_arvalid),
                .s_axi_arready_o(wide_arready),
                .s_axi_rid_o(wide_rid),
                .s_axi_rdata_o(wide_rdata),
                .s_axi_rresp_o(wide_rresp),
                .s_axi_rlast_o(wide_rlast),
                .s_axi_rvalid_o(wide_rvalid),
                .s_axi_rready_i(wide_rready),
                .s_axi_awid_i(axi_awid),
                .s_axi_awaddr_i(axi_awaddr),
                .s_axi_awlen_i(axi_awlen),
                .s_axi_awsize_i(axi_awsize),
                .s_axi_awburst_i(axi_awburst),
                .s_axi_awvalid_i(wide_awvalid),
                .s_axi_awready_o(wide_awready),
                .s_axi_wdata_i(axi_wdata),
                .s_axi_wstrb_i(axi_wstrb),
                .s_axi_wlast_i(axi_wlast),
                .s_axi_wvalid_i(wide_wvalid),
                .s_axi_wready_o(wide_wready),
                .s_axi_bid_o(wide_bid),
                .s_axi_bresp_o(wide_bresp),
                .s_axi_bvalid_o(wide_bvalid),
                .s_axi_bready_i(wide_bready),
                .mem_valid_o(axi_wide_mem_valid),
                .mem_ready_i(
                    (BUS_TYPE == `OPENRV64_COMPLEX_BUS_AXI) ?
                    ram_ready_i : 1'b0),
                .mem_write_o(axi_wide_mem_write),
                .mem_addr_o(axi_wide_mem_addr),
                .mem_wdata_o(axi_wide_mem_wdata),
                .mem_wstrb_o(axi_wide_mem_wstrb),
                .mem_rdata_i(ram_rdata_i),
                .mem_error_i(ram_error_i)
            );
        end
    endgenerate

    wire unused_bus_attributes = ^{
        wb_cti, wb_bte, wb_lock
    };

`ifndef SYNTHESIS
    initial begin
        if ((DDR3_ENABLE != 0) &&
            (BUS_TYPE != `OPENRV64_COMPLEX_BUS_AXI))
            $fatal(1, "DDR3 platform memory requires the AXI backend");
    end
`endif

endmodule
