`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "complex/bus/defs.v"

// Single-hart native CCX home with a shared L2 and a scalar platform-bus
// backend.  The private L1I, L1D, and PTW sources are already arbitrated onto
// the one CCX port by openrv64_ccx_bus.  This block retains that native
// identity through the L2, then uses the neutral genbus width converter and
// its 64-bit WISHBONE backend to reach the platform decoder.
module openrv64_soc_ccx_l2_bridge #(
    parameter integer L2_BYTES = 256 * 1024,
    parameter integer L2_WAYS = 8,
    parameter integer L2_MERGE_ENTRIES = 8,
    parameter integer L2_WAITERS_PER_MSHR = 8,
    parameter integer L2_COMMAND_ENTRIES = 16,
    parameter integer L2_RESPONSE_ENTRIES = 16
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
    input  wire                         mem_error_i
);

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

    assign mem_valid_o = wb_request;
    assign mem_write_o = wb_we;
    assign mem_addr_o = wb_adr << 3;
    assign mem_wdata_o = wb_dat_o;
    assign mem_wstrb_o = wb_sel;

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
        .BUS_TYPE(`OPENRV64_COMPLEX_BUS_WISHBONE),
        .BUS_ADDR_WIDTH(64),
        .BUS_DATA_WIDTH(64),
        .GENBUS_READ_BUFFER_DEPTH(4),
        .GENBUS_WRITE_BUFFER_DEPTH(4),
        .AXI_ID_WIDTH(3),
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
        .m_axi_arready_i(1'b0),
        .m_axi_rid_i(3'd0),
        .m_axi_rdata_i(64'd0),
        .m_axi_rresp_i(2'b00),
        .m_axi_rlast_i(1'b0),
        .m_axi_rvalid_i(1'b0),
        .m_axi_awready_i(1'b0),
        .m_axi_wready_i(1'b0),
        .m_axi_bid_i(3'd0),
        .m_axi_bresp_i(2'b00),
        .m_axi_bvalid_i(1'b0),
        .wb_cyc_o(wb_cyc),
        .wb_stb_o(wb_stb),
        .wb_we_o(wb_we),
        .wb_adr_o(wb_adr),
        .wb_dat_o(wb_dat_o),
        .wb_sel_o(wb_sel),
        .wb_cti_o(wb_cti),
        .wb_bte_o(wb_bte),
        .wb_lock_o(wb_lock),
        .wb_stall_i(wb_request && !mem_ready_i),
        .wb_ack_i(wb_complete && !mem_error_i),
        .wb_err_i(wb_complete && mem_error_i),
        .wb_rty_i(1'b0),
        .wb_dat_i(mem_rdata_i)
    );

    wire [5:0] unused_wb_control = {wb_cti, wb_bte, wb_lock};

endmodule
