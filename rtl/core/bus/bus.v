`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/bus/bus-defs.v"

// Core-bus geometry selector.  The generic path preserves the original
// blocking 64-bit requester.  The AXI path exposes a decoupled 256-bit fetch
// line interface plus the same blocking LSU contract.
module openrv64_core_bus #(
    parameter [`OPENRV64_BUS_CONFIG_WIDTH-1:0] BUS_CONFIG =
        `OPENRV64_BUS_GEN,
    parameter integer TLB_ENTRIES = 16,
    parameter integer FETCH_OUTSTANDING = 4
) (
    input  wire                         clk,
    input  wire                         rst_n,

    // Legacy blocking fetch interface.
    input  wire                         fetch_valid_i,
    input  wire                         fetch_cancel_i,
    input  wire [`RV64_XLEN-1:0]        fetch_addr_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  fetch_priv_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] fetch_vm_mode_i,
    input  wire [`RV64_SATP_ASID_WIDTH-1:0] fetch_asid_i,
    input  wire [`RV64_SATP_PPN_WIDTH-1:0] fetch_root_ppn_i,
    input  wire                         fetch_sum_i,
    input  wire                         fetch_mxr_i,
    output wire                         fetch_ready_o,
    output wire [`RV64_XLEN-1:0]        fetch_rdata_o,
    output wire                         fetch_access_fault_o,
    output wire                         fetch_page_fault_o,

    // Pipelined wide-line fetch interface used by fetch_3w.v.
    input  wire                         fetch_pipe_req_valid_i,
    output wire                         fetch_pipe_req_ready_o,
    input  wire [`RV64_XLEN-1:0]        fetch_pipe_req_addr_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  fetch_pipe_req_priv_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] fetch_pipe_req_vm_mode_i,
    input  wire [`RV64_SATP_ASID_WIDTH-1:0] fetch_pipe_req_asid_i,
    input  wire [`RV64_SATP_PPN_WIDTH-1:0] fetch_pipe_req_root_ppn_i,
    input  wire                         fetch_pipe_req_sum_i,
    input  wire                         fetch_pipe_req_mxr_i,
    output wire                         fetch_pipe_resp_valid_o,
    input  wire                         fetch_pipe_resp_ready_i,
    output wire [`RV64_XLEN-1:0]        fetch_pipe_resp_addr_o,
    output wire [`OPENRV64_AXI_DATA_WIDTH-1:0]
                                        fetch_pipe_resp_data_o,
    output wire                         fetch_pipe_resp_access_fault_o,
    output wire                         fetch_pipe_resp_page_fault_o,

    input  wire                         lsu_valid_i,
    input  wire                         lsu_write_i,
    input  wire [`RV64_XLEN-1:0]        lsu_addr_i,
    input  wire [`RV64_XLEN-1:0]        lsu_wdata_i,
    input  wire [7:0]                   lsu_wstrb_i,
    input  wire [2:0]                   lsu_size_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  lsu_priv_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] lsu_vm_mode_i,
    input  wire [`RV64_SATP_ASID_WIDTH-1:0] lsu_asid_i,
    input  wire [`RV64_SATP_PPN_WIDTH-1:0] lsu_root_ppn_i,
    input  wire                         lsu_sum_i,
    input  wire                         lsu_mxr_i,
    output wire                         lsu_ready_o,
    output wire [`RV64_XLEN-1:0]        lsu_rdata_o,
    output wire                         lsu_access_fault_o,
    output wire                         lsu_page_fault_o,

    // Tagged, decoupled LSU interface used by the three-pipe backend.
    input  wire                         lsu_pipe_req_valid_i,
    output wire                         lsu_pipe_req_ready_o,
    input  wire [`OPENRV64_LSU_TAG_WIDTH-1:0] lsu_pipe_req_tag_i,
    input  wire                         lsu_pipe_req_write_i,
    input  wire [`RV64_XLEN-1:0]        lsu_pipe_req_addr_i,
    input  wire [`RV64_XLEN-1:0]        lsu_pipe_req_wdata_i,
    input  wire [7:0]                   lsu_pipe_req_wstrb_i,
    input  wire [2:0]                   lsu_pipe_req_size_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  lsu_pipe_req_priv_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] lsu_pipe_req_vm_mode_i,
    input  wire [`RV64_SATP_ASID_WIDTH-1:0] lsu_pipe_req_asid_i,
    input  wire [`RV64_SATP_PPN_WIDTH-1:0] lsu_pipe_req_root_ppn_i,
    input  wire                         lsu_pipe_req_sum_i,
    input  wire                         lsu_pipe_req_mxr_i,
    input  wire                         lsu_pipe_cancel_i,
    output wire                         lsu_pipe_resp_valid_o,
    input  wire                         lsu_pipe_resp_ready_i,
    output wire [`OPENRV64_LSU_TAG_WIDTH-1:0] lsu_pipe_resp_tag_o,
    output wire [`RV64_XLEN-1:0]        lsu_pipe_resp_rdata_o,
    output wire                         lsu_pipe_resp_access_fault_o,
    output wire                         lsu_pipe_resp_page_fault_o,

    input  wire                         tlbi_i,

    // Generic physical request port.  It is active only in BUS_GEN mode.
    output wire                         req_valid_o,
    input  wire                         req_ready_i,
    output wire                         req_write_o,
    output wire [`RV64_XLEN-1:0]        req_addr_o,
    output wire [`RV64_XLEN-1:0]        req_pmp_addr_o,
    output wire [`RV64_PRIV_WIDTH-1:0]  req_priv_o,
    output wire [2:0]                   req_size_o,
    output wire                         req_exec_o,
    output wire [`RV64_XLEN-1:0]        req_wdata_o,
    output wire [7:0]                   req_wstrb_o,
    input  wire [`RV64_XLEN-1:0]        req_rdata_i,
    input  wire                         req_error_i,
    input  wire                         fetch_next_valid_i,
    input  wire [`RV64_XLEN-1:0]        fetch_next_addr_i,

    // Post-translation PMP probe shared by both bus implementations.
    output wire                         pmp_valid_o,
    output wire [`RV64_XLEN-1:0]        pmp_addr_o,
    output wire [`RV64_PRIV_WIDTH-1:0]  pmp_priv_o,
    output wire [2:0]                   pmp_size_o,
    output wire                         pmp_write_o,
    output wire                         pmp_exec_o,
    input  wire                         pmp_allow_i,

    output wire [`OPENRV64_AXI_ID_WIDTH-1:0] m_axi_arid_o,
    output wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] m_axi_araddr_o,
    output wire [7:0]                   m_axi_arlen_o,
    output wire [2:0]                   m_axi_arsize_o,
    output wire [1:0]                   m_axi_arburst_o,
    output wire                         m_axi_arlock_o,
    output wire [3:0]                   m_axi_arcache_o,
    output wire [2:0]                   m_axi_arprot_o,
    output wire [3:0]                   m_axi_arqos_o,
    output wire                         m_axi_arvalid_o,
    input  wire                         m_axi_arready_i,
    input  wire [`OPENRV64_AXI_ID_WIDTH-1:0] m_axi_rid_i,
    input  wire [`OPENRV64_AXI_DATA_WIDTH-1:0] m_axi_rdata_i,
    input  wire [1:0]                   m_axi_rresp_i,
    input  wire                         m_axi_rlast_i,
    input  wire                         m_axi_rvalid_i,
    output wire                         m_axi_rready_o,
    output wire [`OPENRV64_AXI_ID_WIDTH-1:0] m_axi_awid_o,
    output wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] m_axi_awaddr_o,
    output wire [7:0]                   m_axi_awlen_o,
    output wire [2:0]                   m_axi_awsize_o,
    output wire [1:0]                   m_axi_awburst_o,
    output wire                         m_axi_awlock_o,
    output wire [3:0]                   m_axi_awcache_o,
    output wire [2:0]                   m_axi_awprot_o,
    output wire [3:0]                   m_axi_awqos_o,
    output wire                         m_axi_awvalid_o,
    input  wire                         m_axi_awready_i,
    output wire [`OPENRV64_AXI_DATA_WIDTH-1:0] m_axi_wdata_o,
    output wire [`OPENRV64_AXI_STRB_WIDTH-1:0] m_axi_wstrb_o,
    output wire                         m_axi_wlast_o,
    output wire                         m_axi_wvalid_o,
    input  wire                         m_axi_wready_i,
    input  wire [`OPENRV64_AXI_ID_WIDTH-1:0] m_axi_bid_i,
    input  wire [1:0]                   m_axi_bresp_i,
    input  wire                         m_axi_bvalid_i,
    output wire                         m_axi_bready_o
);

    generate
        if (BUS_CONFIG == `OPENRV64_BUS_GEN) begin : g_gen
            wire raw_req_valid;
            wire raw_req_ready = (raw_req_valid && !pmp_allow_i) ||
                                 req_ready_i;
            wire raw_req_error = (raw_req_valid && !pmp_allow_i) ||
                                 req_error_i;
            wire raw_req_write;
            wire [`RV64_XLEN-1:0] raw_req_addr;
            wire [`RV64_XLEN-1:0] raw_req_pmp_addr;
            wire [`RV64_PRIV_WIDTH-1:0] raw_req_priv;
            wire [2:0] raw_req_size;
            wire raw_req_exec;
            wire [`RV64_XLEN-1:0] raw_req_wdata;
            wire [7:0] raw_req_wstrb;

            reg pipe_active_q;
            reg pipe_resp_valid_q;
            reg [`OPENRV64_LSU_TAG_WIDTH-1:0] pipe_tag_q;
            reg pipe_write_q;
            reg [`RV64_XLEN-1:0] pipe_addr_q;
            reg [`RV64_XLEN-1:0] pipe_wdata_q;
            reg [7:0] pipe_wstrb_q;
            reg [2:0] pipe_size_q;
            reg [`RV64_PRIV_WIDTH-1:0] pipe_priv_q;
            reg [`RV64_SATP_MODE_WIDTH-1:0] pipe_vm_mode_q;
            reg [`RV64_SATP_ASID_WIDTH-1:0] pipe_asid_q;
            reg [`RV64_SATP_PPN_WIDTH-1:0] pipe_root_ppn_q;
            reg pipe_sum_q;
            reg pipe_mxr_q;
            reg [`RV64_XLEN-1:0] pipe_resp_rdata_q;
            reg pipe_resp_access_fault_q;
            reg pipe_resp_page_fault_q;
            wire gen_lsu_valid = pipe_active_q || lsu_valid_i;
            wire gen_lsu_write = pipe_active_q ? pipe_write_q : lsu_write_i;
            wire [`RV64_XLEN-1:0] gen_lsu_addr =
                pipe_active_q ? pipe_addr_q : lsu_addr_i;
            wire [`RV64_XLEN-1:0] gen_lsu_wdata =
                pipe_active_q ? pipe_wdata_q : lsu_wdata_i;
            wire [7:0] gen_lsu_wstrb =
                pipe_active_q ? pipe_wstrb_q : lsu_wstrb_i;
            wire [2:0] gen_lsu_size =
                pipe_active_q ? pipe_size_q : lsu_size_i;
            wire [`RV64_PRIV_WIDTH-1:0] gen_lsu_priv =
                pipe_active_q ? pipe_priv_q : lsu_priv_i;
            wire [`RV64_SATP_MODE_WIDTH-1:0] gen_lsu_vm_mode =
                pipe_active_q ? pipe_vm_mode_q : lsu_vm_mode_i;
            wire [`RV64_SATP_ASID_WIDTH-1:0] gen_lsu_asid =
                pipe_active_q ? pipe_asid_q : lsu_asid_i;
            wire [`RV64_SATP_PPN_WIDTH-1:0] gen_lsu_root_ppn =
                pipe_active_q ? pipe_root_ppn_q : lsu_root_ppn_i;
            wire gen_lsu_sum = pipe_active_q ? pipe_sum_q : lsu_sum_i;
            wire gen_lsu_mxr = pipe_active_q ? pipe_mxr_q : lsu_mxr_i;
            wire gen_lsu_ready;
            wire [`RV64_XLEN-1:0] gen_lsu_rdata;
            wire gen_lsu_access_fault;
            wire gen_lsu_page_fault;

            openrv64_core_gen_bus #(.TLB_ENTRIES(TLB_ENTRIES)) u_bus (
                .clk(clk), .rst_n(rst_n), .fetch_valid_i(fetch_valid_i),
                .fetch_cancel_i(fetch_cancel_i),
                .fetch_addr_i(fetch_addr_i), .fetch_priv_i(fetch_priv_i),
                .fetch_vm_mode_i(fetch_vm_mode_i),
                .fetch_asid_i(fetch_asid_i),
                .fetch_root_ppn_i(fetch_root_ppn_i),
                .fetch_sum_i(fetch_sum_i), .fetch_mxr_i(fetch_mxr_i),
                .fetch_ready_o(fetch_ready_o),
                .fetch_rdata_o(fetch_rdata_o),
                .fetch_access_fault_o(fetch_access_fault_o),
                .fetch_page_fault_o(fetch_page_fault_o),
                .lsu_valid_i(gen_lsu_valid), .lsu_write_i(gen_lsu_write),
                .lsu_addr_i(gen_lsu_addr), .lsu_wdata_i(gen_lsu_wdata),
                .lsu_wstrb_i(gen_lsu_wstrb), .lsu_size_i(gen_lsu_size),
                .lsu_priv_i(gen_lsu_priv), .lsu_vm_mode_i(gen_lsu_vm_mode),
                .lsu_asid_i(gen_lsu_asid),
                .lsu_root_ppn_i(gen_lsu_root_ppn),
                .lsu_sum_i(gen_lsu_sum), .lsu_mxr_i(gen_lsu_mxr),
                .lsu_ready_o(gen_lsu_ready), .lsu_rdata_o(gen_lsu_rdata),
                .lsu_access_fault_o(gen_lsu_access_fault),
                .lsu_page_fault_o(gen_lsu_page_fault), .tlbi_i(tlbi_i),
                .req_valid_o(raw_req_valid), .req_ready_i(raw_req_ready),
                .req_write_o(raw_req_write), .req_addr_o(raw_req_addr),
                .req_pmp_addr_o(raw_req_pmp_addr),
                .req_priv_o(raw_req_priv), .req_size_o(raw_req_size),
                .req_exec_o(raw_req_exec), .req_wdata_o(raw_req_wdata),
                .req_wstrb_o(raw_req_wstrb), .req_rdata_i(req_rdata_i),
                .req_error_i(raw_req_error),
                .fetch_next_valid_i(fetch_next_valid_i),
                .fetch_next_addr_i(fetch_next_addr_i)
            );

            assign req_valid_o = raw_req_valid && pmp_allow_i;
            assign req_write_o = raw_req_write;
            assign req_addr_o = raw_req_addr;
            assign req_pmp_addr_o = raw_req_pmp_addr;
            assign req_priv_o = raw_req_priv;
            assign req_size_o = raw_req_size;
            assign req_exec_o = raw_req_exec;
            assign req_wdata_o = raw_req_wdata;
            assign req_wstrb_o = raw_req_wstrb;
            assign pmp_valid_o = raw_req_valid;
            assign pmp_addr_o = raw_req_pmp_addr;
            assign pmp_priv_o = raw_req_priv;
            assign pmp_size_o = raw_req_size;
            assign pmp_write_o = raw_req_write;
            assign pmp_exec_o = raw_req_exec;

            assign fetch_pipe_req_ready_o = 1'b0;
            assign fetch_pipe_resp_valid_o = 1'b0;
            assign fetch_pipe_resp_addr_o = {`RV64_XLEN{1'b0}};
            assign fetch_pipe_resp_data_o =
                {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
            assign fetch_pipe_resp_access_fault_o = 1'b0;
            assign fetch_pipe_resp_page_fault_o = 1'b0;
            assign lsu_ready_o = gen_lsu_ready && !pipe_active_q;
            assign lsu_rdata_o = gen_lsu_rdata;
            assign lsu_access_fault_o = gen_lsu_access_fault &&
                                        !pipe_active_q;
            assign lsu_page_fault_o = gen_lsu_page_fault && !pipe_active_q;
            assign lsu_pipe_req_ready_o = !pipe_active_q &&
                                          !pipe_resp_valid_q &&
                                          !lsu_valid_i;
            assign lsu_pipe_resp_valid_o = pipe_resp_valid_q;
            assign lsu_pipe_resp_tag_o = pipe_tag_q;
            assign lsu_pipe_resp_rdata_o = pipe_resp_rdata_q;
            assign lsu_pipe_resp_access_fault_o =
                pipe_resp_access_fault_q;
            assign lsu_pipe_resp_page_fault_o = pipe_resp_page_fault_q;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pipe_active_q <= 1'b0;
                    pipe_resp_valid_q <= 1'b0;
                    pipe_tag_q <= {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
                    pipe_write_q <= 1'b0;
                    pipe_addr_q <= {`RV64_XLEN{1'b0}};
                    pipe_wdata_q <= {`RV64_XLEN{1'b0}};
                    pipe_wstrb_q <= 8'd0;
                    pipe_size_q <= 3'd0;
                    pipe_priv_q <= `RV64_PRIV_M;
                    pipe_vm_mode_q <= `RV64_SATP_MODE_BARE;
                    pipe_asid_q <= {`RV64_SATP_ASID_WIDTH{1'b0}};
                    pipe_root_ppn_q <= {`RV64_SATP_PPN_WIDTH{1'b0}};
                    pipe_sum_q <= 1'b0;
                    pipe_mxr_q <= 1'b0;
                    pipe_resp_rdata_q <= {`RV64_XLEN{1'b0}};
                    pipe_resp_access_fault_q <= 1'b0;
                    pipe_resp_page_fault_q <= 1'b0;
                end else begin
                    if (lsu_pipe_cancel_i) begin
                        pipe_active_q <= 1'b0;
                        pipe_resp_valid_q <= 1'b0;
                    end
                    if (lsu_pipe_req_valid_i && lsu_pipe_req_ready_o) begin
                        pipe_active_q <= 1'b1;
                        pipe_tag_q <= lsu_pipe_req_tag_i;
                        pipe_write_q <= lsu_pipe_req_write_i;
                        pipe_addr_q <= lsu_pipe_req_addr_i;
                        pipe_wdata_q <= lsu_pipe_req_wdata_i;
                        pipe_wstrb_q <= lsu_pipe_req_wstrb_i;
                        pipe_size_q <= lsu_pipe_req_size_i;
                        pipe_priv_q <= lsu_pipe_req_priv_i;
                        pipe_vm_mode_q <= lsu_pipe_req_vm_mode_i;
                        pipe_asid_q <= lsu_pipe_req_asid_i;
                        pipe_root_ppn_q <= lsu_pipe_req_root_ppn_i;
                        pipe_sum_q <= lsu_pipe_req_sum_i;
                        pipe_mxr_q <= lsu_pipe_req_mxr_i;
                    end
                    if (pipe_active_q && gen_lsu_ready) begin
                        pipe_active_q <= 1'b0;
                        pipe_resp_valid_q <= 1'b1;
                        pipe_resp_rdata_q <= gen_lsu_rdata;
                        pipe_resp_access_fault_q <= gen_lsu_access_fault;
                        pipe_resp_page_fault_q <= gen_lsu_page_fault;
                    end
                    if (pipe_resp_valid_q && lsu_pipe_resp_ready_i)
                        pipe_resp_valid_q <= 1'b0;
                end
            end
            assign m_axi_arid_o = {`OPENRV64_AXI_ID_WIDTH{1'b0}};
            assign m_axi_araddr_o = {`OPENRV64_AXI_ADDR_WIDTH{1'b0}};
            assign m_axi_arlen_o = 8'd0;
            assign m_axi_arsize_o = 3'd0;
            assign m_axi_arburst_o = 2'd0;
            assign m_axi_arlock_o = 1'b0;
            assign m_axi_arcache_o = 4'd0;
            assign m_axi_arprot_o = 3'd0;
            assign m_axi_arqos_o = 4'd0;
            assign m_axi_arvalid_o = 1'b0;
            assign m_axi_rready_o = 1'b0;
            assign m_axi_awid_o = {`OPENRV64_AXI_ID_WIDTH{1'b0}};
            assign m_axi_awaddr_o = {`OPENRV64_AXI_ADDR_WIDTH{1'b0}};
            assign m_axi_awlen_o = 8'd0;
            assign m_axi_awsize_o = 3'd0;
            assign m_axi_awburst_o = 2'd0;
            assign m_axi_awlock_o = 1'b0;
            assign m_axi_awcache_o = 4'd0;
            assign m_axi_awprot_o = 3'd0;
            assign m_axi_awqos_o = 4'd0;
            assign m_axi_awvalid_o = 1'b0;
            assign m_axi_wdata_o = {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
            assign m_axi_wstrb_o = {`OPENRV64_AXI_STRB_WIDTH{1'b0}};
            assign m_axi_wlast_o = 1'b0;
            assign m_axi_wvalid_o = 1'b0;
            assign m_axi_bready_o = 1'b0;
        end else begin : g_axi
            openrv64_core_axi_bus #(
                .TLB_ENTRIES(TLB_ENTRIES),
                .FETCH_OUTSTANDING(FETCH_OUTSTANDING)
            ) u_bus (
                .clk(clk), .rst_n(rst_n),
                .fetch_req_valid_i(fetch_pipe_req_valid_i),
                .fetch_req_ready_o(fetch_pipe_req_ready_o),
                .fetch_req_addr_i(fetch_pipe_req_addr_i),
                .fetch_req_priv_i(fetch_pipe_req_priv_i),
                .fetch_req_vm_mode_i(fetch_pipe_req_vm_mode_i),
                .fetch_req_asid_i(fetch_pipe_req_asid_i),
                .fetch_req_root_ppn_i(fetch_pipe_req_root_ppn_i),
                .fetch_req_sum_i(fetch_pipe_req_sum_i),
                .fetch_req_mxr_i(fetch_pipe_req_mxr_i),
                .fetch_cancel_i(fetch_cancel_i),
                .fetch_resp_valid_o(fetch_pipe_resp_valid_o),
                .fetch_resp_ready_i(fetch_pipe_resp_ready_i),
                .fetch_resp_addr_o(fetch_pipe_resp_addr_o),
                .fetch_resp_data_o(fetch_pipe_resp_data_o),
                .fetch_resp_access_fault_o(
                    fetch_pipe_resp_access_fault_o),
                .fetch_resp_page_fault_o(fetch_pipe_resp_page_fault_o),
                .lsu_valid_i(lsu_valid_i), .lsu_write_i(lsu_write_i),
                .lsu_addr_i(lsu_addr_i), .lsu_wdata_i(lsu_wdata_i),
                .lsu_wstrb_i(lsu_wstrb_i), .lsu_size_i(lsu_size_i),
                .lsu_priv_i(lsu_priv_i), .lsu_vm_mode_i(lsu_vm_mode_i),
                .lsu_asid_i(lsu_asid_i),
                .lsu_root_ppn_i(lsu_root_ppn_i), .lsu_sum_i(lsu_sum_i),
                .lsu_mxr_i(lsu_mxr_i), .lsu_ready_o(lsu_ready_o),
                .lsu_rdata_o(lsu_rdata_o),
                .lsu_access_fault_o(lsu_access_fault_o),
                .lsu_page_fault_o(lsu_page_fault_o), .tlbi_i(tlbi_i),
                .lsu_pipe_req_valid_i(lsu_pipe_req_valid_i),
                .lsu_pipe_req_ready_o(lsu_pipe_req_ready_o),
                .lsu_pipe_req_tag_i(lsu_pipe_req_tag_i),
                .lsu_pipe_req_write_i(lsu_pipe_req_write_i),
                .lsu_pipe_req_addr_i(lsu_pipe_req_addr_i),
                .lsu_pipe_req_wdata_i(lsu_pipe_req_wdata_i),
                .lsu_pipe_req_wstrb_i(lsu_pipe_req_wstrb_i),
                .lsu_pipe_req_size_i(lsu_pipe_req_size_i),
                .lsu_pipe_req_priv_i(lsu_pipe_req_priv_i),
                .lsu_pipe_req_vm_mode_i(lsu_pipe_req_vm_mode_i),
                .lsu_pipe_req_asid_i(lsu_pipe_req_asid_i),
                .lsu_pipe_req_root_ppn_i(lsu_pipe_req_root_ppn_i),
                .lsu_pipe_req_sum_i(lsu_pipe_req_sum_i),
                .lsu_pipe_req_mxr_i(lsu_pipe_req_mxr_i),
                .lsu_pipe_cancel_i(lsu_pipe_cancel_i),
                .lsu_pipe_resp_valid_o(lsu_pipe_resp_valid_o),
                .lsu_pipe_resp_ready_i(lsu_pipe_resp_ready_i),
                .lsu_pipe_resp_tag_o(lsu_pipe_resp_tag_o),
                .lsu_pipe_resp_rdata_o(lsu_pipe_resp_rdata_o),
                .lsu_pipe_resp_access_fault_o(
                    lsu_pipe_resp_access_fault_o),
                .lsu_pipe_resp_page_fault_o(lsu_pipe_resp_page_fault_o),
                .pmp_valid_o(pmp_valid_o), .pmp_addr_o(pmp_addr_o),
                .pmp_priv_o(pmp_priv_o), .pmp_size_o(pmp_size_o),
                .pmp_write_o(pmp_write_o), .pmp_exec_o(pmp_exec_o),
                .pmp_allow_i(pmp_allow_i),
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
                .m_axi_rid_i(m_axi_rid_i), .m_axi_rdata_i(m_axi_rdata_i),
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
                .m_axi_bid_i(m_axi_bid_i), .m_axi_bresp_i(m_axi_bresp_i),
                .m_axi_bvalid_i(m_axi_bvalid_i),
                .m_axi_bready_o(m_axi_bready_o)
            );

            assign fetch_ready_o = 1'b0;
            assign fetch_rdata_o = {`RV64_XLEN{1'b0}};
            assign fetch_access_fault_o = 1'b0;
            assign fetch_page_fault_o = 1'b0;
            assign req_valid_o = 1'b0;
            assign req_write_o = 1'b0;
            assign req_addr_o = {`RV64_XLEN{1'b0}};
            assign req_pmp_addr_o = {`RV64_XLEN{1'b0}};
            assign req_priv_o = {`RV64_PRIV_WIDTH{1'b0}};
            assign req_size_o = 3'd0;
            assign req_exec_o = 1'b0;
            assign req_wdata_o = {`RV64_XLEN{1'b0}};
            assign req_wstrb_o = 8'd0;
        end
    endgenerate

endmodule
