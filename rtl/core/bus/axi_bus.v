`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

// Core memory boundary with native private-cache CCX ports and a residual AXI
// path for page-table walks and cacheless instruction fetch.  With ENABLE_L1I
// set, translated and PMP-approved fetches enter a blocking native-CCX L1I.
// Scalar LSU requests always use the precise translation/PMP slot and then a
// blocking L1D with a native CCX backend; no LSU request can enter AXI.
module openrv64_core_axi_bus #(
    parameter integer TLB_ENTRIES = 16,
    parameter integer ENABLE_L1I = 1,
    parameter integer ENABLE_L1D = 1,
    parameter [`RV64_XLEN-1:0] L1D_CACHEABLE_BASE =
        {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] L1D_CACHEABLE_SIZE =
        {`RV64_XLEN{1'b1}},
    parameter [`OPENRV64_CCX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}},
    parameter integer AXI_ADDR_WIDTH = `OPENRV64_AXI_ADDR_WIDTH,
    parameter integer AXI_DATA_WIDTH = `OPENRV64_AXI_DATA_WIDTH,
    parameter integer AXI_ID_WIDTH = `OPENRV64_AXI_ID_WIDTH
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         fetch_req_valid_i,
    output wire                         fetch_req_ready_o,
    input  wire [`RV64_XLEN-1:0]        fetch_req_addr_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  fetch_req_priv_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] fetch_req_vm_mode_i,
    input  wire [`RV64_SATP_ASID_WIDTH-1:0] fetch_req_asid_i,
    input  wire [`RV64_SATP_PPN_WIDTH-1:0] fetch_req_root_ppn_i,
    input  wire                         fetch_req_sum_i,
    input  wire                         fetch_req_mxr_i,
    input  wire                         fetch_cancel_i,
    output wire                         fetch_resp_valid_o,
    input  wire                         fetch_resp_ready_i,
    output wire [`RV64_XLEN-1:0]        fetch_resp_addr_o,
    output wire [AXI_DATA_WIDTH-1:0]    fetch_resp_data_o,
    output wire                         fetch_resp_access_fault_o,
    output wire                         fetch_resp_page_fault_o,

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
    input  wire                         icache_invalidate_i,
    input  wire                         icache_prefetch_valid_i,
    input  wire [`RV64_XLEN-1:0]        icache_prefetch_taken_addr_i,
    input  wire [`RV64_XLEN-1:0]        icache_prefetch_fallthrough_addr_i,
    input  wire [2:0]                   icache_age_valid_i,
    input  wire [3*`RV64_XLEN-1:0]      icache_age_addr_i,

    // One physical protection probe is presented for the transaction which
    // would be launched this cycle.  Denials complete locally as access
    // faults and never escape onto AXI.
    output wire                         pmp_valid_o,
    output wire [`RV64_XLEN-1:0]        pmp_addr_o,
    output wire [`RV64_PRIV_WIDTH-1:0]  pmp_priv_o,
    output wire [2:0]                   pmp_size_o,
    output wire                         pmp_write_o,
    output wire                         pmp_exec_o,
    input  wire                         pmp_allow_i,

    output wire                         ccx_req_valid_o,
    input  wire                         ccx_req_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_req_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_req_txn_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_req_source_id_o,
    output wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op_o,
    output wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order_o,
    output wire [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind_o,
    output wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr_o,
    output wire [2:0]                   ccx_req_size_o,
    output wire [63:0]                  ccx_req_addr_o,
    output wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
                                        ccx_req_burst_len_o,
    output wire                         ccx_wdata_valid_o,
    input  wire                         ccx_wdata_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_wdata_hart_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_wdata_txn_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_wdata_source_id_o,
    output wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                        ccx_wdata_beat_index_o,
    output wire                         ccx_wdata_last_o,
    output wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                        ccx_wdata_o,
    output wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0]
                                        ccx_wstrb_o,
    input  wire                         ccx_resp_valid_i,
    output wire                         ccx_resp_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_resp_hart_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_resp_txn_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_resp_source_id_i,
    input  wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                        ccx_resp_beat_index_i,
    input  wire                         ccx_resp_last_i,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                        ccx_resp_rdata_i,
    input  wire                         ccx_resp_error_i,
    input  wire                         ccx_resp_sc_success_i,

    output wire [AXI_ID_WIDTH-1:0]      m_axi_arid_o,
    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_araddr_o,
    output wire [7:0]                   m_axi_arlen_o,
    output wire [2:0]                   m_axi_arsize_o,
    output wire [1:0]                   m_axi_arburst_o,
    output wire                         m_axi_arlock_o,
    output wire [3:0]                   m_axi_arcache_o,
    output wire [2:0]                   m_axi_arprot_o,
    output wire [3:0]                   m_axi_arqos_o,
    output wire                         m_axi_arvalid_o,
    input  wire                         m_axi_arready_i,

    input  wire [AXI_ID_WIDTH-1:0]      m_axi_rid_i,
    input  wire [AXI_DATA_WIDTH-1:0]    m_axi_rdata_i,
    input  wire [1:0]                   m_axi_rresp_i,
    input  wire                         m_axi_rlast_i,
    input  wire                         m_axi_rvalid_i,
    output wire                         m_axi_rready_o,

    output wire [AXI_ID_WIDTH-1:0]      m_axi_awid_o,
    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_awaddr_o,
    output wire [7:0]                   m_axi_awlen_o,
    output wire [2:0]                   m_axi_awsize_o,
    output wire [1:0]                   m_axi_awburst_o,
    output wire                         m_axi_awlock_o,
    output wire [3:0]                   m_axi_awcache_o,
    output wire [2:0]                   m_axi_awprot_o,
    output wire [3:0]                   m_axi_awqos_o,
    output wire                         m_axi_awvalid_o,
    input  wire                         m_axi_awready_i,

    output wire [AXI_DATA_WIDTH-1:0]    m_axi_wdata_o,
    output wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb_o,
    output wire                         m_axi_wlast_o,
    output wire                         m_axi_wvalid_o,
    input  wire                         m_axi_wready_i,

    input  wire [AXI_ID_WIDTH-1:0]      m_axi_bid_i,
    input  wire [1:0]                   m_axi_bresp_i,
    input  wire                         m_axi_bvalid_i,
    output wire                         m_axi_bready_o
);

    localparam integer AXI_BYTES = AXI_DATA_WIDTH / 8;
    localparam integer AXI_BYTE_BITS = $clog2(AXI_BYTES);
    localparam [AXI_ID_WIDTH-1:0] DATA_AXI_ID = {AXI_ID_WIDTH{1'b1}};

    localparam [2:0] FETCH_EMPTY = 3'd0;
    localparam [2:0] FETCH_TRANSLATE = 3'd1;
    localparam [2:0] FETCH_MISS = 3'd2;
    localparam [2:0] FETCH_WAIT_R = 3'd3;
    localparam [2:0] FETCH_COMPLETE = 3'd4;
    localparam [2:0] FETCH_WAIT_L1I = 3'd5;

    localparam [2:0] LSU_IDLE = 3'd0;
    localparam [2:0] LSU_TRANSLATE = 3'd1;
    localparam [2:0] LSU_MISS = 3'd2;
    localparam [2:0] LSU_ACCESS = 3'd3;
    localparam [2:0] LSU_WAIT = 3'd4;
    localparam [2:0] LSU_RESP = 3'd5;

    localparam [1:0] PHYS_IDLE = 2'd0;
    localparam [1:0] PHYS_WRITE = 2'd1;
    localparam [1:0] PHYS_WAIT_R = 2'd2;
    localparam [1:0] PHYS_WAIT_B = 2'd3;

    localparam [1:0] OWNER_FETCH = 2'd0;
    localparam [1:0] OWNER_LSU = 2'd1;
    localparam [1:0] OWNER_PREFETCH = 2'd2;
    localparam PHYS_OWNER_PTW = 1'b0;
    localparam PHYS_OWNER_LSU = 1'b1;
    localparam [1:0] ACCESS_READ = 2'd0;
    localparam [1:0] ACCESS_WRITE = 2'd1;
    localparam [1:0] ACCESS_EXEC = 2'd2;

    localparam [2:0] PREFETCH_XLATE_IDLE = 3'd0;
    localparam [2:0] PREFETCH_XLATE_LOOKUP = 3'd1;
    localparam [2:0] PREFETCH_XLATE_MISS = 3'd2;
    localparam [2:0] PREFETCH_XLATE_PMP = 3'd3;
    localparam [2:0] PREFETCH_XLATE_RESP = 3'd4;

    // Fetch presents one cache-line request at a time.  This slot owns only
    // translation, protection, and response delivery; L1I owns cache misses
    // and any future multiple-outstanding or prefetch machinery.
    reg [2:0] fetch_state_q;
    reg [`RV64_XLEN-1:0] fetch_vaddr_q;
    reg [`RV64_PRIV_WIDTH-1:0] fetch_priv_q;
    reg [`RV64_SATP_MODE_WIDTH-1:0] fetch_vm_mode_q;
    reg [`RV64_SATP_ASID_WIDTH-1:0] fetch_asid_q;
    reg [`RV64_SATP_PPN_WIDTH-1:0] fetch_root_ppn_q;
    reg fetch_sum_q;
    reg fetch_mxr_q;
    reg fetch_cancelled_q;
    reg [AXI_DATA_WIDTH-1:0] fetch_data_q;
    reg fetch_access_fault_q;
    reg fetch_page_fault_q;

    wire fetch_xlate_found = (fetch_state_q == FETCH_TRANSLATE) &&
                             !fetch_cancelled_q;

    wire fetch_accept = fetch_req_valid_i && fetch_req_ready_o;
    wire fetch_incoming_lookup = fetch_req_valid_i && fetch_req_ready_o;
    wire [`RV64_XLEN-1:0] fetch_incoming_vaddr = {
        fetch_req_addr_i[`RV64_XLEN-1:AXI_BYTE_BITS],
        {AXI_BYTE_BITS{1'b0}}
    };
    wire fetch_complete = (fetch_state_q == FETCH_COMPLETE);
    wire fetch_drop = fetch_complete && fetch_cancelled_q;
    wire fetch_resp_fire = fetch_resp_valid_o && fetch_resp_ready_i;
    wire fetch_pop = fetch_drop || fetch_resp_fire;

    assign fetch_req_ready_o = rst_n && !fetch_cancel_i &&
                               (fetch_state_q == FETCH_EMPTY);
    assign fetch_resp_valid_o = fetch_complete && !fetch_cancelled_q;
    assign fetch_resp_addr_o = fetch_vaddr_q;
    assign fetch_resp_data_o = fetch_data_q;
    assign fetch_resp_access_fault_o = fetch_access_fault_q;
    assign fetch_resp_page_fault_o = fetch_page_fault_q;

    wire itlb_lookup_hit;
    wire [`RV64_XLEN-1:0] itlb_lookup_paddr;
    wire itlb_lookup_page_fault;
    wire fetch_xlate_bare = fetch_xlate_found &&
        (fetch_vm_mode_q == `RV64_SATP_MODE_BARE);
    wire fetch_lookup_valid = fetch_xlate_found || fetch_incoming_lookup;
    wire [`RV64_XLEN-1:0] fetch_lookup_vaddr = fetch_xlate_found ?
        fetch_vaddr_q : fetch_incoming_vaddr;
    wire [`RV64_PRIV_WIDTH-1:0] fetch_lookup_priv = fetch_xlate_found ?
        fetch_priv_q : fetch_req_priv_i;
    wire [`RV64_SATP_MODE_WIDTH-1:0] fetch_lookup_vm_mode =
        fetch_xlate_found ? fetch_vm_mode_q : fetch_req_vm_mode_i;
    wire fetch_lookup_bare = fetch_lookup_valid &&
        (fetch_lookup_vm_mode == `RV64_SATP_MODE_BARE);
    wire fetch_lookup_ready = fetch_lookup_bare || itlb_lookup_hit;
    wire [`RV64_XLEN-1:0] fetch_lookup_paddr = fetch_lookup_bare ?
        fetch_lookup_vaddr : itlb_lookup_paddr;

    // L1I owns speculative virtual jobs.  This blocking side service shares
    // the existing ITLB/PTW/PMP resources, always below architectural demand
    // traffic.  Its faults return only to L1I and are discarded there.
    reg [2:0] prefetch_xlate_state_q;
    reg [`RV64_XLEN-1:0] prefetch_xlate_vaddr_q;
    reg [`RV64_XLEN-1:0] prefetch_xlate_paddr_q;
    reg [`RV64_PRIV_WIDTH-1:0] prefetch_xlate_priv_q;
    reg [`RV64_SATP_MODE_WIDTH-1:0] prefetch_xlate_vm_mode_q;
    reg [`RV64_SATP_ASID_WIDTH-1:0] prefetch_xlate_asid_q;
    reg [`RV64_SATP_PPN_WIDTH-1:0] prefetch_xlate_root_ppn_q;
    reg prefetch_xlate_sum_q;
    reg prefetch_xlate_mxr_q;
    reg prefetch_xlate_fault_q;
    wire l1i_xlate_req_valid;
    wire l1i_xlate_req_ready;
    wire [`RV64_XLEN-1:0] l1i_xlate_req_vaddr;
    wire [`RV64_PRIV_WIDTH-1:0] l1i_xlate_req_priv;
    wire [`RV64_SATP_MODE_WIDTH-1:0] l1i_xlate_req_vm_mode;
    wire [`RV64_SATP_ASID_WIDTH-1:0] l1i_xlate_req_asid;
    wire [`RV64_SATP_PPN_WIDTH-1:0] l1i_xlate_req_root_ppn;
    wire l1i_xlate_req_sum;
    wire l1i_xlate_req_mxr;
    wire l1i_xlate_resp_valid;
    wire l1i_xlate_resp_ready;
    wire [`RV64_XLEN-1:0] l1i_xlate_resp_paddr;
    wire l1i_xlate_resp_fault;

    assign l1i_xlate_req_ready =
        (prefetch_xlate_state_q == PREFETCH_XLATE_IDLE) && !tlbi_i;
    assign l1i_xlate_resp_valid =
        (prefetch_xlate_state_q == PREFETCH_XLATE_RESP);
    assign l1i_xlate_resp_paddr = prefetch_xlate_paddr_q;
    assign l1i_xlate_resp_fault = prefetch_xlate_fault_q;
    wire prefetch_xlate_lookup =
        (prefetch_xlate_state_q == PREFETCH_XLATE_LOOKUP) &&
        !fetch_lookup_valid;
    wire prefetch_xlate_bare = prefetch_xlate_lookup &&
        (prefetch_xlate_vm_mode_q == `RV64_SATP_MODE_BARE);

    reg [2:0] lsu_state_q;
    reg lsu_write_q;
    reg [`RV64_XLEN-1:0] lsu_vaddr_q;
    reg [`RV64_XLEN-1:0] lsu_paddr_q;
    reg [`RV64_XLEN-1:0] lsu_wdata_q;
    reg [7:0] lsu_wstrb_q;
    reg [2:0] lsu_size_q;
    reg [`RV64_PRIV_WIDTH-1:0] lsu_priv_q;
    reg [`RV64_SATP_MODE_WIDTH-1:0] lsu_vm_mode_q;
    reg [`RV64_SATP_ASID_WIDTH-1:0] lsu_asid_q;
    reg [`RV64_SATP_PPN_WIDTH-1:0] lsu_root_ppn_q;
    reg lsu_sum_q;
    reg lsu_mxr_q;
    reg [`RV64_XLEN-1:0] lsu_rdata_q;
    reg lsu_access_fault_q;
    reg lsu_page_fault_q;
    reg pipe_fallback_active_q;
    reg pipe_fallback_cancelled_q;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] pipe_fallback_tag_q;

    wire pipe_req_tag_valid =
        lsu_pipe_req_tag_i < `OPENRV64_LSU_OUTSTANDING;

    wire dtlb_lookup_hit;
    wire [`RV64_XLEN-1:0] dtlb_lookup_paddr;
    wire dtlb_lookup_page_fault;
    wire lsu_xlate_bare = (lsu_state_q == LSU_TRANSLATE) &&
                          (lsu_vm_mode_q == `RV64_SATP_MODE_BARE);

    assign lsu_ready_o = (lsu_state_q == LSU_RESP) &&
                         !pipe_fallback_active_q;
    assign lsu_rdata_o = lsu_rdata_q;
    assign lsu_access_fault_o = lsu_ready_o && lsu_access_fault_q;
    assign lsu_page_fault_o = lsu_ready_o && lsu_page_fault_q;

    // A single PTW serves I- and D-side misses.  TLB hits and already-issued
    // AXI reads continue while a walk is active.
    reg miss_active_q;
    reg [1:0] miss_owner_q;
    reg miss_invalidated_q;

    wire ptw_req_ready;
    wire ptw_resp_valid;
    wire [`RV64_XLEN-1:0] ptw_resp_paddr;
    wire ptw_resp_page_fault;
    wire ptw_resp_access_fault;
    wire ptw_resp_global;
    wire [`RV64_PAGE_LEVEL_WIDTH-1:0] ptw_resp_level;
    wire ptw_resp_readable;
    wire ptw_resp_writable;
    wire ptw_resp_executable;
    wire ptw_resp_user;
    wire ptw_resp_accessed;
    wire ptw_resp_dirty;
    wire ptw_mem_valid;
    wire ptw_mem_write;
    wire [`RV64_XLEN-1:0] ptw_mem_addr;
    wire [`RV64_XLEN-1:0] ptw_mem_wdata;
    wire [7:0] ptw_mem_wstrb;
    wire ptw_mem_ready;
    wire [`RV64_XLEN-1:0] ptw_mem_rdata;
    wire ptw_mem_error;

    wire lsu_needs_walk = (lsu_state_q == LSU_TRANSLATE) &&
                          !lsu_xlate_bare && !dtlb_lookup_hit;
    wire fetch_needs_walk = fetch_xlate_found &&
                            !fetch_xlate_bare && !itlb_lookup_hit;
    wire prefetch_needs_walk = prefetch_xlate_lookup &&
        !prefetch_xlate_bare && !itlb_lookup_hit;
    wire start_lsu_walk = !miss_active_q && ptw_req_ready &&
                          lsu_needs_walk;
    wire start_fetch_walk = !miss_active_q && ptw_req_ready &&
                            !lsu_needs_walk && fetch_needs_walk;
    wire start_prefetch_walk = !miss_active_q && ptw_req_ready &&
        !lsu_needs_walk && !fetch_needs_walk && prefetch_needs_walk;
    wire ptw_req_valid = start_lsu_walk || start_fetch_walk ||
                         start_prefetch_walk;
    wire [1:0] ptw_req_owner = start_lsu_walk ? OWNER_LSU :
        start_fetch_walk ? OWNER_FETCH : OWNER_PREFETCH;
    wire [`RV64_XLEN-1:0] ptw_req_vaddr = start_lsu_walk ?
        lsu_vaddr_q : start_fetch_walk ? fetch_vaddr_q :
        prefetch_xlate_vaddr_q;
    wire [1:0] ptw_req_access = start_lsu_walk ?
        (lsu_write_q ? ACCESS_WRITE : ACCESS_READ) : ACCESS_EXEC;
    wire [`RV64_PRIV_WIDTH-1:0] ptw_req_priv = start_lsu_walk ?
        lsu_priv_q : start_fetch_walk ? fetch_priv_q :
        prefetch_xlate_priv_q;
    wire [`RV64_SATP_MODE_WIDTH-1:0] ptw_req_vm_mode = start_lsu_walk ?
        lsu_vm_mode_q : start_fetch_walk ? fetch_vm_mode_q :
        prefetch_xlate_vm_mode_q;
    wire [`RV64_SATP_ASID_WIDTH-1:0] ptw_req_asid = start_lsu_walk ?
        lsu_asid_q : start_fetch_walk ? fetch_asid_q :
        prefetch_xlate_asid_q;
    wire [`RV64_SATP_PPN_WIDTH-1:0] ptw_req_root_ppn = start_lsu_walk ?
        lsu_root_ppn_q : start_fetch_walk ? fetch_root_ppn_q :
        prefetch_xlate_root_ppn_q;
    wire ptw_req_sum = start_lsu_walk ?
        lsu_sum_q : start_fetch_walk ? fetch_sum_q :
        prefetch_xlate_sum_q;
    wire ptw_req_mxr = start_lsu_walk ?
        lsu_mxr_q : start_fetch_walk ? fetch_mxr_q :
        prefetch_xlate_mxr_q;

    wire itlb_fill_for_fetch = (miss_owner_q == OWNER_FETCH) &&
                               !fetch_cancelled_q;
    wire itlb_fill_for_prefetch = (miss_owner_q == OWNER_PREFETCH);
    wire itlb_fill_valid = ptw_resp_valid && miss_active_q &&
        (itlb_fill_for_fetch || itlb_fill_for_prefetch) &&
        !miss_invalidated_q &&
        !ptw_resp_page_fault && !ptw_resp_access_fault && !tlbi_i;
    wire dtlb_fill_valid = ptw_resp_valid && miss_active_q &&
        (miss_owner_q == OWNER_LSU) && !miss_invalidated_q &&
        !ptw_resp_page_fault && !ptw_resp_access_fault && !tlbi_i;

    wire itlb_lookup_is_prefetch = prefetch_xlate_lookup;
    wire [`RV64_XLEN-1:0] itlb_lookup_vaddr =
        itlb_lookup_is_prefetch ? prefetch_xlate_vaddr_q :
        fetch_lookup_vaddr;
    wire [`RV64_SATP_MODE_WIDTH-1:0] itlb_lookup_vm_mode =
        itlb_lookup_is_prefetch ? prefetch_xlate_vm_mode_q :
        fetch_lookup_vm_mode;
    wire [`RV64_SATP_ASID_WIDTH-1:0] itlb_lookup_asid =
        itlb_lookup_is_prefetch ? prefetch_xlate_asid_q :
        (fetch_xlate_found ? fetch_asid_q : fetch_req_asid_i);
    wire [`RV64_PRIV_WIDTH-1:0] itlb_lookup_priv =
        itlb_lookup_is_prefetch ? prefetch_xlate_priv_q :
        fetch_lookup_priv;
    wire itlb_lookup_sum =
        itlb_lookup_is_prefetch ? prefetch_xlate_sum_q :
        (fetch_xlate_found ? fetch_sum_q : fetch_req_sum_i);
    wire itlb_lookup_mxr =
        itlb_lookup_is_prefetch ? prefetch_xlate_mxr_q :
        (fetch_xlate_found ? fetch_mxr_q : fetch_req_mxr_i);
    wire [`RV64_XLEN-1:0] itlb_fill_vaddr = itlb_fill_for_prefetch ?
        prefetch_xlate_vaddr_q : fetch_vaddr_q;
    wire [`RV64_SATP_MODE_WIDTH-1:0] itlb_fill_vm_mode =
        itlb_fill_for_prefetch ? prefetch_xlate_vm_mode_q : fetch_vm_mode_q;
    wire [`RV64_SATP_ASID_WIDTH-1:0] itlb_fill_asid =
        itlb_fill_for_prefetch ? prefetch_xlate_asid_q : fetch_asid_q;

    openrv64_bus_tlb #(
        .ENTRIES(TLB_ENTRIES), .ASID_WIDTH(`RV64_SATP_ASID_WIDTH)
    ) u_itlb (
        .clk(clk), .rst_n(rst_n), .tlbi_i(tlbi_i),
        .lookup_valid_i((fetch_lookup_valid && !fetch_lookup_bare) ||
                        (prefetch_xlate_lookup && !prefetch_xlate_bare)),
        .lookup_vaddr_i(itlb_lookup_vaddr),
        .lookup_vm_mode_i(itlb_lookup_vm_mode),
        .lookup_asid_i(itlb_lookup_asid),
        .lookup_access_i(ACCESS_EXEC),
        .lookup_priv_i(itlb_lookup_priv),
        .lookup_sum_i(itlb_lookup_sum),
        .lookup_mxr_i(itlb_lookup_mxr),
        .lookup_hit_o(itlb_lookup_hit),
        .lookup_paddr_o(itlb_lookup_paddr),
        .lookup_page_fault_o(itlb_lookup_page_fault),
        .fill_valid_i(itlb_fill_valid),
        .fill_vaddr_i(itlb_fill_vaddr),
        .fill_paddr_i(ptw_resp_paddr),
        .fill_vm_mode_i(itlb_fill_vm_mode),
        .fill_asid_i(itlb_fill_asid),
        .fill_global_i(ptw_resp_global), .fill_level_i(ptw_resp_level),
        .fill_readable_i(ptw_resp_readable),
        .fill_writable_i(ptw_resp_writable),
        .fill_executable_i(ptw_resp_executable),
        .fill_user_i(ptw_resp_user), .fill_accessed_i(ptw_resp_accessed),
        .fill_dirty_i(ptw_resp_dirty)
    );

    openrv64_bus_tlb #(
        .ENTRIES(TLB_ENTRIES), .ASID_WIDTH(`RV64_SATP_ASID_WIDTH)
    ) u_dtlb (
        .clk(clk), .rst_n(rst_n), .tlbi_i(tlbi_i),
        .lookup_valid_i((lsu_state_q == LSU_TRANSLATE) &&
                        !lsu_xlate_bare),
        .lookup_vaddr_i(lsu_vaddr_q), .lookup_vm_mode_i(lsu_vm_mode_q),
        .lookup_asid_i(lsu_asid_q),
        .lookup_access_i(lsu_write_q ? ACCESS_WRITE : ACCESS_READ),
        .lookup_priv_i(lsu_priv_q), .lookup_sum_i(lsu_sum_q),
        .lookup_mxr_i(lsu_mxr_q), .lookup_hit_o(dtlb_lookup_hit),
        .lookup_paddr_o(dtlb_lookup_paddr),
        .lookup_page_fault_o(dtlb_lookup_page_fault),
        .fill_valid_i(dtlb_fill_valid), .fill_vaddr_i(lsu_vaddr_q),
        .fill_paddr_i(ptw_resp_paddr), .fill_vm_mode_i(lsu_vm_mode_q),
        .fill_asid_i(lsu_asid_q), .fill_global_i(ptw_resp_global),
        .fill_level_i(ptw_resp_level),
        .fill_readable_i(ptw_resp_readable),
        .fill_writable_i(ptw_resp_writable),
        .fill_executable_i(ptw_resp_executable),
        .fill_user_i(ptw_resp_user), .fill_accessed_i(ptw_resp_accessed),
        .fill_dirty_i(ptw_resp_dirty)
    );

    openrv64_bus_ptw u_ptw (
        .clk(clk), .rst_n(rst_n), .req_valid_i(ptw_req_valid),
        .req_ready_o(ptw_req_ready), .req_vaddr_i(ptw_req_vaddr),
        .req_access_i(ptw_req_access), .req_priv_i(ptw_req_priv),
        .req_vm_mode_i(ptw_req_vm_mode), .req_asid_i(ptw_req_asid),
        .req_root_ppn_i(ptw_req_root_ppn), .req_sum_i(ptw_req_sum),
        .req_mxr_i(ptw_req_mxr), .resp_valid_o(ptw_resp_valid),
        .resp_ready_i(1'b1), .resp_paddr_o(ptw_resp_paddr),
        .resp_page_fault_o(ptw_resp_page_fault),
        .resp_access_fault_o(ptw_resp_access_fault),
        .resp_global_o(ptw_resp_global), .resp_level_o(ptw_resp_level),
        .resp_readable_o(ptw_resp_readable),
        .resp_writable_o(ptw_resp_writable),
        .resp_executable_o(ptw_resp_executable),
        .resp_user_o(ptw_resp_user), .resp_accessed_o(ptw_resp_accessed),
        .resp_dirty_o(ptw_resp_dirty), .mem_valid_o(ptw_mem_valid),
        .mem_ready_i(ptw_mem_ready), .mem_write_o(ptw_mem_write),
        .mem_addr_o(ptw_mem_addr), .mem_wdata_o(ptw_mem_wdata),
        .mem_wstrb_o(ptw_mem_wstrb), .mem_rdata_i(ptw_mem_rdata),
        .mem_error_i(ptw_mem_error)
    );

    // Blocking PTW physical transaction slot.  Scalar LSU traffic leaves
    // through L1D/CCX and never enters this AXI slot.
    reg [1:0] phys_state_q;
    reg phys_owner_q;
    reg [`RV64_XLEN-1:0] phys_addr_q;
    reg [2:0] phys_size_q;
    reg [`RV64_PRIV_WIDTH-1:0] phys_priv_q;
    reg phys_exec_q;
    reg [AXI_DATA_WIDTH-1:0] phys_wdata_q;
    reg [AXI_BYTES-1:0] phys_wstrb_q;
    reg phys_aw_sent_q;
    reg phys_w_sent_q;

    // Until the DTLB itself is multiported/tagged, serialize every tagged
    // scalar request through the precise translation/PTW state machine and
    // return its result under the original backend tag.
    wire pipe_fallback_candidate = lsu_pipe_req_valid_i &&
        pipe_req_tag_valid && !lsu_pipe_cancel_i &&
        !pipe_fallback_active_q &&
        !lsu_valid_i && (lsu_state_q == LSU_IDLE) &&
        !miss_active_q;

    wire phys_candidate_valid = (phys_state_q == PHYS_IDLE) &&
                                ptw_mem_valid;
    wire phys_candidate_owner = PHYS_OWNER_PTW;
    wire phys_candidate_write = ptw_mem_write;
    wire [`RV64_XLEN-1:0] phys_candidate_addr = ptw_mem_addr;
    wire [`RV64_XLEN-1:0] phys_candidate_wdata = ptw_mem_wdata;
    wire [7:0] phys_candidate_wstrb = ptw_mem_wstrb;
    wire [2:0] phys_candidate_size = 3'd3;
    wire [`RV64_PRIV_WIDTH-1:0] phys_candidate_priv = `RV64_PRIV_S;
    wire [1:0] phys_candidate_word =
        phys_candidate_addr[AXI_BYTE_BITS-1:3];
    wire [AXI_DATA_WIDTH-1:0] phys_candidate_axi_wdata =
        {{(AXI_DATA_WIDTH-`RV64_XLEN){1'b0}}, phys_candidate_wdata} <<
        (phys_candidate_word * `RV64_XLEN);
    wire [AXI_BYTES-1:0] phys_candidate_axi_wstrb =
        {{(AXI_BYTES-8){1'b0}}, phys_candidate_wstrb} <<
        (phys_candidate_word * 8);

    wire fetch_axi_candidate = fetch_lookup_valid && fetch_lookup_ready &&
                               !itlb_lookup_page_fault &&
                               !fetch_cancel_i;
    wire [`RV64_XLEN-1:0] fetch_axi_addr = {
        fetch_lookup_paddr[`RV64_XLEN-1:AXI_BYTE_BITS],
        {AXI_BYTE_BITS{1'b0}}
    };

    // The current L1I is deliberately blocking.  It accepts one translated,
    // PMP-approved 256-bit frontend line at a time and stores native 64-byte
    // lines.  A cold line is exactly one 512-bit native CCX transaction.
    reg l1i_req_active_q;
    reg [`RV64_XLEN-1:0] l1i_req_vaddr_q;
    reg [`RV64_XLEN-1:0] l1i_req_paddr_q;
    reg l1i_invalidate_pending_q;
    wire l1i_invalidate_ready;
    wire l1i_invalidate_valid = icache_invalidate_i ||
                                l1i_invalidate_pending_q;
    wire l1i_req_ready;
    wire [AXI_DATA_WIDTH-1:0] l1i_req_rdata;
    wire l1i_req_error;
    wire axi_r_error;
    wire l1i_enabled = (ENABLE_L1I != 0);
    wire fetch_cache_candidate = fetch_axi_candidate &&
        (!l1i_enabled || (!l1i_req_active_q && l1i_invalidate_ready &&
                          !l1i_invalidate_valid));

    // Scalar data gets the single PMP probe first.  Once approved it remains
    // active inside L1D while the probe is free for PTW or instruction fetch.
    wire select_lsu_probe = (lsu_state_q == LSU_ACCESS);
    wire select_phys_probe = !select_lsu_probe &&
                             phys_candidate_valid;
    wire select_fetch_probe = !select_lsu_probe &&
                              !select_phys_probe && fetch_cache_candidate;
    wire select_prefetch_probe = !select_lsu_probe &&
        !select_phys_probe && !select_fetch_probe &&
        (prefetch_xlate_state_q == PREFETCH_XLATE_PMP);
    assign pmp_valid_o = select_lsu_probe || select_phys_probe ||
                         select_fetch_probe || select_prefetch_probe;
    assign pmp_addr_o = select_lsu_probe ? lsu_paddr_q :
                        select_phys_probe ? phys_candidate_addr :
                        select_fetch_probe ? fetch_axi_addr :
                        prefetch_xlate_paddr_q;
    assign pmp_priv_o = select_lsu_probe ? lsu_priv_q :
                        select_phys_probe ? phys_candidate_priv :
                        select_fetch_probe ? fetch_lookup_priv :
                        prefetch_xlate_priv_q;
    assign pmp_size_o = select_lsu_probe ? lsu_size_q :
                        select_phys_probe ? phys_candidate_size : 3'd5;
    assign pmp_write_o = select_lsu_probe ? lsu_write_q :
                         select_phys_probe && phys_candidate_write;
    assign pmp_exec_o = select_fetch_probe || select_prefetch_probe;

    wire lsu_pmp_denied = select_lsu_probe && !pmp_allow_i;
    wire phys_pmp_denied = select_phys_probe && !pmp_allow_i;
    wire fetch_pmp_denied = select_fetch_probe && !pmp_allow_i;
    wire prefetch_pmp_complete = select_prefetch_probe;
    wire fetch_l1i_launch = l1i_enabled && select_fetch_probe && pmp_allow_i;
    wire l1i_req_valid = l1i_enabled &&
                         (l1i_req_active_q || fetch_l1i_launch);
    wire [`RV64_XLEN-1:0] l1i_req_vaddr = l1i_req_active_q ?
        l1i_req_vaddr_q : fetch_lookup_vaddr;
    wire [`RV64_XLEN-1:0] l1i_req_paddr = l1i_req_active_q ?
        l1i_req_paddr_q : fetch_axi_addr;

    wire l1d_launch = select_lsu_probe && pmp_allow_i;
    wire l1d_req_valid = (lsu_state_q == LSU_WAIT) || l1d_launch;
    wire l1d_req_ready;
    wire [`RV64_XLEN-1:0] l1d_req_rdata;
    wire l1d_req_error;
    wire l1d_req_cacheable = (L1D_CACHEABLE_SIZE != 0) &&
        ((lsu_paddr_q - L1D_CACHEABLE_BASE) < L1D_CACHEABLE_SIZE);

    wire l1d_ccx_req_valid;
    wire l1d_ccx_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l1d_ccx_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l1d_ccx_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l1d_ccx_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] l1d_ccx_req_op;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] l1d_ccx_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] l1d_ccx_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] l1d_ccx_req_attr;
    wire [2:0] l1d_ccx_req_size;
    wire [63:0] l1d_ccx_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] l1d_ccx_req_burst_len;
    wire l1d_ccx_wdata_valid;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l1d_ccx_wdata_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l1d_ccx_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l1d_ccx_wdata_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] l1d_ccx_wdata_beat_index;
    wire l1d_ccx_wdata_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] l1d_ccx_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] l1d_ccx_wstrb;
    wire l1d_ccx_resp_valid = ccx_resp_valid_i &&
        (ccx_resp_source_id_i == `OPENRV64_CCX_SOURCE_DCACHE);
    wire l1d_ccx_resp_ready;

    wire l1i_ccx_req_valid;
    wire l1i_ccx_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] l1i_ccx_req_hart_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] l1i_ccx_req_source_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] l1i_ccx_req_txn_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] l1i_ccx_req_op;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] l1i_ccx_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] l1i_ccx_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] l1i_ccx_req_attr;
    wire [2:0] l1i_ccx_req_size;
    wire [63:0] l1i_ccx_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] l1i_ccx_req_burst_len;
    wire l1i_ccx_resp_valid = ccx_resp_valid_i &&
        (ccx_resp_source_id_i == `OPENRV64_CCX_SOURCE_ICACHE);
    wire l1i_ccx_resp_ready;

    openrv64_l1d_ccx #(
        .ENABLE(ENABLE_L1D),
        .ADDR_WIDTH(`RV64_XLEN),
        .CACHE_BYTES(8 * 1024),
        .LINE_BYTES(64),
        .WAYS(4),
        .HART_ID(HART_ID)
    ) u_l1d (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(l1d_req_valid),
        .req_ready_o(l1d_req_ready),
        .req_write_i(lsu_write_q),
        .req_cacheable_i(l1d_req_cacheable),
        .req_addr_i(lsu_paddr_q),
        .req_size_i(lsu_size_q),
        .req_wdata_i(lsu_wdata_q),
        .req_wstrb_i(lsu_wstrb_q),
        .req_rdata_o(l1d_req_rdata),
        .req_error_o(l1d_req_error),
        .invalidate_valid_i(1'b0),
        .invalidate_ready_o(),
        .invalidate_all_i(1'b0),
        .invalidate_addr_i({`RV64_XLEN{1'b0}}),
        .ccx_req_valid_o(l1d_ccx_req_valid),
        .ccx_req_ready_i(l1d_ccx_req_ready),
        .ccx_req_hart_id_o(l1d_ccx_req_hart_id),
        .ccx_req_txn_id_o(l1d_ccx_req_txn_id),
        .ccx_req_source_id_o(l1d_ccx_req_source_id),
        .ccx_req_op_o(l1d_ccx_req_op),
        .ccx_req_order_o(l1d_ccx_req_order),
        .ccx_req_kind_o(l1d_ccx_req_kind),
        .ccx_req_attr_o(l1d_ccx_req_attr),
        .ccx_req_size_o(l1d_ccx_req_size),
        .ccx_req_addr_o(l1d_ccx_req_addr),
        .ccx_req_burst_len_o(l1d_ccx_req_burst_len),
        .ccx_wdata_valid_o(l1d_ccx_wdata_valid),
        .ccx_wdata_ready_i(ccx_wdata_ready_i),
        .ccx_wdata_hart_id_o(l1d_ccx_wdata_hart_id),
        .ccx_wdata_txn_id_o(l1d_ccx_wdata_txn_id),
        .ccx_wdata_source_id_o(l1d_ccx_wdata_source_id),
        .ccx_wdata_beat_index_o(l1d_ccx_wdata_beat_index),
        .ccx_wdata_last_o(l1d_ccx_wdata_last),
        .ccx_wdata_o(l1d_ccx_wdata),
        .ccx_wstrb_o(l1d_ccx_wstrb),
        .ccx_resp_valid_i(l1d_ccx_resp_valid),
        .ccx_resp_ready_o(l1d_ccx_resp_ready),
        .ccx_resp_hart_id_i(ccx_resp_hart_id_i),
        .ccx_resp_txn_id_i(ccx_resp_txn_id_i),
        .ccx_resp_source_id_i(ccx_resp_source_id_i),
        .ccx_resp_beat_index_i(ccx_resp_beat_index_i),
        .ccx_resp_last_i(ccx_resp_last_i),
        .ccx_resp_rdata_i(ccx_resp_rdata_i),
        .ccx_resp_error_i(ccx_resp_error_i),
        .ccx_resp_sc_success_i(ccx_resp_sc_success_i)
    );

    openrv64_l1i_ccx #(
        .ENABLE(ENABLE_L1I),
        .ADDR_WIDTH(`RV64_XLEN),
        .HART_ID(HART_ID)
    ) u_l1i (
        .clk_i(clk),
        .rst_ni(rst_n),
        .req_valid_i(l1i_req_valid),
        .req_ready_o(l1i_req_ready),
        .req_cacheable_i(1'b1),
        .req_addr_i(l1i_req_vaddr),
        .req_phys_addr_i(l1i_req_paddr),
        .req_rdata_o(l1i_req_rdata),
        .req_error_o(l1i_req_error),
        .prefetch_valid_i(icache_prefetch_valid_i),
        .prefetch_taken_addr_i(icache_prefetch_taken_addr_i),
        .prefetch_fallthrough_addr_i(
            icache_prefetch_fallthrough_addr_i),
        .prefetch_priv_i(fetch_req_priv_i),
        .prefetch_vm_mode_i(fetch_req_vm_mode_i),
        .prefetch_asid_i(fetch_req_asid_i),
        .prefetch_root_ppn_i(fetch_req_root_ppn_i),
        .prefetch_sum_i(fetch_req_sum_i),
        .prefetch_mxr_i(fetch_req_mxr_i),
        .retire_age_valid_i(icache_age_valid_i),
        .retire_age_addr_i(icache_age_addr_i),
        .prefetch_flush_i(tlbi_i || icache_invalidate_i),
        .xlate_req_valid_o(l1i_xlate_req_valid),
        .xlate_req_ready_i(l1i_xlate_req_ready),
        .xlate_req_vaddr_o(l1i_xlate_req_vaddr),
        .xlate_req_priv_o(l1i_xlate_req_priv),
        .xlate_req_vm_mode_o(l1i_xlate_req_vm_mode),
        .xlate_req_asid_o(l1i_xlate_req_asid),
        .xlate_req_root_ppn_o(l1i_xlate_req_root_ppn),
        .xlate_req_sum_o(l1i_xlate_req_sum),
        .xlate_req_mxr_o(l1i_xlate_req_mxr),
        .xlate_resp_valid_i(l1i_xlate_resp_valid),
        .xlate_resp_ready_o(l1i_xlate_resp_ready),
        .xlate_resp_paddr_i(l1i_xlate_resp_paddr),
        .xlate_resp_fault_i(l1i_xlate_resp_fault),
        .invalidate_valid_i(l1i_invalidate_valid),
        .invalidate_ready_o(l1i_invalidate_ready),
        .invalidate_all_i(1'b1),
        .invalidate_addr_i({`RV64_XLEN{1'b0}}),
        .ccx_req_valid_o(l1i_ccx_req_valid),
        .ccx_req_ready_i(l1i_ccx_req_ready),
        .ccx_req_hart_id_o(l1i_ccx_req_hart_id),
        .ccx_req_source_id_o(l1i_ccx_req_source_id),
        .ccx_req_txn_id_o(l1i_ccx_req_txn_id),
        .ccx_req_op_o(l1i_ccx_req_op),
        .ccx_req_order_o(l1i_ccx_req_order),
        .ccx_req_kind_o(l1i_ccx_req_kind),
        .ccx_req_attr_o(l1i_ccx_req_attr),
        .ccx_req_size_o(l1i_ccx_req_size),
        .ccx_req_addr_o(l1i_ccx_req_addr),
        .ccx_req_burst_len_o(l1i_ccx_req_burst_len),
        .ccx_resp_valid_i(l1i_ccx_resp_valid),
        .ccx_resp_ready_o(l1i_ccx_resp_ready),
        .ccx_resp_hart_id_i(ccx_resp_hart_id_i),
        .ccx_resp_source_id_i(ccx_resp_source_id_i),
        .ccx_resp_txn_id_i(ccx_resp_txn_id_i),
        .ccx_resp_rdata_i(ccx_resp_rdata_i),
        .ccx_resp_beat_index_i(ccx_resp_beat_index_i),
        .ccx_resp_last_i(ccx_resp_last_i),
        .ccx_resp_error_i(ccx_resp_error_i),
        .ccx_resp_sc_success_i(ccx_resp_sc_success_i)
    );

    // The hart exposes one native CCX command port.  I- and D-cache endpoint
    // tags are independent, so response routing uses source_id as required by
    // the native protocol.  Command arbitration is round-robin and holds its
    // grant across downstream backpressure.
    reg ccx_cmd_grant_valid_q;
    reg ccx_cmd_grant_l1d_q;
    reg ccx_cmd_last_l1d_q;
    wire ccx_cmd_selected_valid = ccx_cmd_grant_l1d_q ?
        l1d_ccx_req_valid : l1i_ccx_req_valid;

    assign ccx_req_valid_o = ccx_cmd_grant_valid_q &&
                             ccx_cmd_selected_valid;
    assign ccx_req_hart_id_o = ccx_cmd_grant_l1d_q ?
        l1d_ccx_req_hart_id : l1i_ccx_req_hart_id;
    assign ccx_req_txn_id_o = ccx_cmd_grant_l1d_q ?
        l1d_ccx_req_txn_id : l1i_ccx_req_txn_id;
    assign ccx_req_source_id_o = ccx_cmd_grant_l1d_q ?
        l1d_ccx_req_source_id : l1i_ccx_req_source_id;
    assign ccx_req_op_o = ccx_cmd_grant_l1d_q ?
        l1d_ccx_req_op : l1i_ccx_req_op;
    assign ccx_req_order_o = ccx_cmd_grant_l1d_q ?
        l1d_ccx_req_order : l1i_ccx_req_order;
    assign ccx_req_kind_o = ccx_cmd_grant_l1d_q ?
        l1d_ccx_req_kind : l1i_ccx_req_kind;
    assign ccx_req_attr_o = ccx_cmd_grant_l1d_q ?
        l1d_ccx_req_attr : l1i_ccx_req_attr;
    assign ccx_req_size_o = ccx_cmd_grant_l1d_q ?
        l1d_ccx_req_size : l1i_ccx_req_size;
    assign ccx_req_addr_o = ccx_cmd_grant_l1d_q ?
        l1d_ccx_req_addr : l1i_ccx_req_addr;
    assign ccx_req_burst_len_o = ccx_cmd_grant_l1d_q ?
        l1d_ccx_req_burst_len : l1i_ccx_req_burst_len;
    assign l1d_ccx_req_ready = ccx_cmd_grant_valid_q &&
        ccx_cmd_grant_l1d_q && ccx_req_ready_i;
    assign l1i_ccx_req_ready = ccx_cmd_grant_valid_q &&
        !ccx_cmd_grant_l1d_q && ccx_req_ready_i;

    assign ccx_wdata_valid_o = l1d_ccx_wdata_valid;
    assign ccx_wdata_hart_id_o = l1d_ccx_wdata_hart_id;
    assign ccx_wdata_txn_id_o = l1d_ccx_wdata_txn_id;
    assign ccx_wdata_source_id_o = l1d_ccx_wdata_source_id;
    assign ccx_wdata_beat_index_o = l1d_ccx_wdata_beat_index;
    assign ccx_wdata_last_o = l1d_ccx_wdata_last;
    assign ccx_wdata_o = l1d_ccx_wdata;
    assign ccx_wstrb_o = l1d_ccx_wstrb;

    assign ccx_resp_ready_o =
        (ccx_resp_source_id_i == `OPENRV64_CCX_SOURCE_DCACHE) ?
        l1d_ccx_resp_ready :
        (ccx_resp_source_id_i == `OPENRV64_CCX_SOURCE_ICACHE) ?
        l1i_ccx_resp_ready : 1'b0;

    wire phys_read_arvalid = select_phys_probe && !phys_candidate_write &&
                             pmp_allow_i;
    wire direct_fetch_arvalid = !l1i_enabled && select_fetch_probe &&
                                pmp_allow_i;
    wire fetch_arvalid = direct_fetch_arvalid;
    wire select_phys_ar = phys_read_arvalid;

    assign m_axi_arvalid_o = phys_read_arvalid || fetch_arvalid;
    assign m_axi_arid_o = select_phys_ar ? DATA_AXI_ID :
                          {AXI_ID_WIDTH{1'b0}};
    assign m_axi_araddr_o = select_phys_ar ? phys_candidate_addr :
                            fetch_axi_addr;
    assign m_axi_arlen_o = 8'd0;
    assign m_axi_arsize_o = select_phys_ar ? phys_candidate_size : 3'd5;
    assign m_axi_arburst_o = 2'b01;
    assign m_axi_arlock_o = 1'b0;
    assign m_axi_arcache_o = select_phys_ar ? 4'b0010 : 4'b1110;
    assign m_axi_arprot_o = {
        select_phys_ar ? 1'b0 : 1'b1,
        1'b0,
        (select_phys_ar ? phys_candidate_priv :
         fetch_priv_q) == `RV64_PRIV_U
    };
    assign m_axi_arqos_o = 4'd0;
    wire axi_ar_fire = m_axi_arvalid_o && m_axi_arready_i;
    wire phys_ar_fire = axi_ar_fire && select_phys_ar;
    wire fetch_ar_fire = axi_ar_fire && !select_phys_ar;
    wire direct_fetch_ar_fire = fetch_ar_fire;

    assign lsu_pipe_req_ready_o = pipe_fallback_candidate;

    assign m_axi_awid_o = DATA_AXI_ID;
    assign m_axi_awaddr_o = phys_addr_q;
    assign m_axi_awlen_o = 8'd0;
    assign m_axi_awsize_o = phys_size_q;
    assign m_axi_awburst_o = 2'b01;
    assign m_axi_awlock_o = 1'b0;
    assign m_axi_awcache_o = 4'b0010;
    assign m_axi_awprot_o = {
        phys_exec_q,
        1'b0,
        (phys_priv_q == `RV64_PRIV_U)
    };
    assign m_axi_awqos_o = 4'd0;
    assign m_axi_awvalid_o = (phys_state_q == PHYS_WRITE) &&
                             !phys_aw_sent_q;
    assign m_axi_wdata_o = phys_wdata_q;
    assign m_axi_wstrb_o = phys_wstrb_q;
    assign m_axi_wlast_o = 1'b1;
    assign m_axi_wvalid_o = (phys_state_q == PHYS_WRITE) &&
                            !phys_w_sent_q;
    wire axi_aw_fire = m_axi_awvalid_o && m_axi_awready_i;
    wire axi_w_fire = m_axi_wvalid_o && m_axi_wready_i;
    wire phys_aw_fire = axi_aw_fire;
    wire phys_w_fire = axi_w_fire;

    assign m_axi_bready_o = (phys_state_q == PHYS_WAIT_B) &&
                             (m_axi_bid_i == DATA_AXI_ID);
    wire phys_b_fire = m_axi_bvalid_i && m_axi_bready_o;

    wire r_is_data = (m_axi_rid_i == DATA_AXI_ID);
    wire r_is_fetch = (m_axi_rid_i == {AXI_ID_WIDTH{1'b0}});
    assign m_axi_rready_o = r_is_data ? (phys_state_q == PHYS_WAIT_R) :
        r_is_fetch && !l1i_enabled && (fetch_state_q == FETCH_WAIT_R);
    wire axi_r_fire = m_axi_rvalid_i && m_axi_rready_o;
    assign axi_r_error = m_axi_rresp_i[1] || !m_axi_rlast_i;
    wire [1:0] phys_response_word =
        phys_addr_q[AXI_BYTE_BITS-1:3];
    wire [AXI_DATA_WIDTH-1:0] phys_shifted_rdata =
        m_axi_rdata_i >> (phys_response_word * `RV64_XLEN);
    wire [`RV64_XLEN-1:0] phys_rdata =
        phys_shifted_rdata[`RV64_XLEN-1:0];

    wire pipe_fallback_visible = pipe_fallback_active_q &&
        !pipe_fallback_cancelled_q && (lsu_state_q == LSU_RESP);
    assign lsu_pipe_resp_valid_o = pipe_fallback_visible;
    assign lsu_pipe_resp_tag_o = pipe_fallback_tag_q;
    assign lsu_pipe_resp_rdata_o = pipe_fallback_visible ? lsu_rdata_q :
                                    {`RV64_XLEN{1'b0}};
    assign lsu_pipe_resp_access_fault_o = pipe_fallback_visible &&
                                           lsu_access_fault_q;
    assign lsu_pipe_resp_page_fault_o =
        pipe_fallback_visible && lsu_page_fault_q;

    assign ptw_mem_ready = phys_pmp_denied &&
                           (phys_candidate_owner == PHYS_OWNER_PTW) ||
                           (axi_r_fire && r_is_data &&
                            (phys_owner_q == PHYS_OWNER_PTW)) ||
                           (phys_b_fire &&
                            (phys_owner_q == PHYS_OWNER_PTW));
    assign ptw_mem_rdata = (axi_r_fire && r_is_data) ?
                           phys_rdata : {`RV64_XLEN{1'b0}};
    assign ptw_mem_error = (phys_pmp_denied &&
                            (phys_candidate_owner == PHYS_OWNER_PTW)) ||
                           (axi_r_fire && r_is_data && axi_r_error) ||
                           (phys_b_fire && m_axi_bresp_i[1]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l1i_req_active_q <= 1'b0;
            l1i_req_vaddr_q <= {`RV64_XLEN{1'b0}};
            l1i_req_paddr_q <= {`RV64_XLEN{1'b0}};
            l1i_invalidate_pending_q <= 1'b0;
        end else begin
            if (fetch_l1i_launch) begin
                l1i_req_active_q <= 1'b1;
                l1i_req_vaddr_q <= fetch_lookup_vaddr;
                l1i_req_paddr_q <= fetch_axi_addr;
            end
            if (l1i_req_active_q && l1i_req_ready)
                l1i_req_active_q <= 1'b0;

            if (icache_invalidate_i)
                l1i_invalidate_pending_q <= 1'b1;
            if (l1i_invalidate_valid && l1i_invalidate_ready)
                l1i_invalidate_pending_q <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prefetch_xlate_state_q <= PREFETCH_XLATE_IDLE;
            prefetch_xlate_vaddr_q <= {`RV64_XLEN{1'b0}};
            prefetch_xlate_paddr_q <= {`RV64_XLEN{1'b0}};
            prefetch_xlate_priv_q <= `RV64_PRIV_M;
            prefetch_xlate_vm_mode_q <= `RV64_SATP_MODE_BARE;
            prefetch_xlate_asid_q <=
                {`RV64_SATP_ASID_WIDTH{1'b0}};
            prefetch_xlate_root_ppn_q <=
                {`RV64_SATP_PPN_WIDTH{1'b0}};
            prefetch_xlate_sum_q <= 1'b0;
            prefetch_xlate_mxr_q <= 1'b0;
            prefetch_xlate_fault_q <= 1'b0;
        end else begin
            case (prefetch_xlate_state_q)
                PREFETCH_XLATE_IDLE: begin
                    if (l1i_xlate_req_valid && l1i_xlate_req_ready) begin
                        prefetch_xlate_vaddr_q <= l1i_xlate_req_vaddr;
                        prefetch_xlate_priv_q <= l1i_xlate_req_priv;
                        prefetch_xlate_vm_mode_q <=
                            l1i_xlate_req_vm_mode;
                        prefetch_xlate_asid_q <= l1i_xlate_req_asid;
                        prefetch_xlate_root_ppn_q <=
                            l1i_xlate_req_root_ppn;
                        prefetch_xlate_sum_q <= l1i_xlate_req_sum;
                        prefetch_xlate_mxr_q <= l1i_xlate_req_mxr;
                        prefetch_xlate_fault_q <= 1'b0;
                        prefetch_xlate_state_q <= PREFETCH_XLATE_LOOKUP;
                    end
                end

                PREFETCH_XLATE_LOOKUP: begin
                    if (prefetch_xlate_bare) begin
                        prefetch_xlate_paddr_q <= prefetch_xlate_vaddr_q;
                        prefetch_xlate_state_q <= PREFETCH_XLATE_PMP;
                    end else if (prefetch_xlate_lookup && itlb_lookup_hit) begin
                        if (itlb_lookup_page_fault) begin
                            prefetch_xlate_fault_q <= 1'b1;
                            prefetch_xlate_state_q <= PREFETCH_XLATE_RESP;
                        end else begin
                            prefetch_xlate_paddr_q <= itlb_lookup_paddr;
                            prefetch_xlate_state_q <= PREFETCH_XLATE_PMP;
                        end
                    end else if (start_prefetch_walk) begin
                        prefetch_xlate_state_q <= PREFETCH_XLATE_MISS;
                    end
                end

                PREFETCH_XLATE_MISS: begin
                    if (ptw_resp_valid && miss_active_q &&
                        (miss_owner_q == OWNER_PREFETCH)) begin
                        if (miss_invalidated_q || tlbi_i) begin
                            prefetch_xlate_state_q <=
                                PREFETCH_XLATE_LOOKUP;
                        end else if (ptw_resp_page_fault ||
                                     ptw_resp_access_fault) begin
                            prefetch_xlate_fault_q <= 1'b1;
                            prefetch_xlate_state_q <= PREFETCH_XLATE_RESP;
                        end else begin
                            prefetch_xlate_paddr_q <= ptw_resp_paddr;
                            prefetch_xlate_state_q <= PREFETCH_XLATE_PMP;
                        end
                    end
                end

                PREFETCH_XLATE_PMP: begin
                    if (prefetch_pmp_complete) begin
                        prefetch_xlate_fault_q <= !pmp_allow_i;
                        prefetch_xlate_state_q <= PREFETCH_XLATE_RESP;
                    end
                end

                PREFETCH_XLATE_RESP: begin
                    if (l1i_xlate_resp_valid && l1i_xlate_resp_ready)
                        prefetch_xlate_state_q <= PREFETCH_XLATE_IDLE;
                end

                default:
                    prefetch_xlate_state_q <= PREFETCH_XLATE_IDLE;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ccx_cmd_grant_valid_q <= 1'b0;
            ccx_cmd_grant_l1d_q <= 1'b0;
            ccx_cmd_last_l1d_q <= 1'b0;
        end else begin
            if (ccx_cmd_grant_valid_q) begin
                if (ccx_req_valid_o && ccx_req_ready_i) begin
                    ccx_cmd_grant_valid_q <= 1'b0;
                    ccx_cmd_last_l1d_q <= ccx_cmd_grant_l1d_q;
                end
            end else if (l1d_ccx_req_valid && l1i_ccx_req_valid) begin
                ccx_cmd_grant_valid_q <= 1'b1;
                ccx_cmd_grant_l1d_q <= !ccx_cmd_last_l1d_q;
            end else if (l1d_ccx_req_valid) begin
                ccx_cmd_grant_valid_q <= 1'b1;
                ccx_cmd_grant_l1d_q <= 1'b1;
            end else if (l1i_ccx_req_valid) begin
                ccx_cmd_grant_valid_q <= 1'b1;
                ccx_cmd_grant_l1d_q <= 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_state_q <= FETCH_EMPTY;
            fetch_vaddr_q <= {`RV64_XLEN{1'b0}};
            fetch_priv_q <= `RV64_PRIV_M;
            fetch_vm_mode_q <= `RV64_SATP_MODE_BARE;
            fetch_asid_q <= {`RV64_SATP_ASID_WIDTH{1'b0}};
            fetch_root_ppn_q <= {`RV64_SATP_PPN_WIDTH{1'b0}};
            fetch_sum_q <= 1'b0;
            fetch_mxr_q <= 1'b0;
            fetch_cancelled_q <= 1'b0;
            fetch_data_q <= {AXI_DATA_WIDTH{1'b0}};
            fetch_access_fault_q <= 1'b0;
            fetch_page_fault_q <= 1'b0;
        end else begin
            if (fetch_accept) begin
                fetch_state_q <= FETCH_TRANSLATE;
                fetch_vaddr_q <= {
                    fetch_req_addr_i[`RV64_XLEN-1:AXI_BYTE_BITS],
                    {AXI_BYTE_BITS{1'b0}}
                };
                fetch_priv_q <= fetch_req_priv_i;
                fetch_vm_mode_q <= fetch_req_vm_mode_i;
                fetch_asid_q <= fetch_req_asid_i;
                fetch_root_ppn_q <= fetch_req_root_ppn_i;
                fetch_sum_q <= fetch_req_sum_i;
                fetch_mxr_q <= fetch_req_mxr_i;
                fetch_cancelled_q <= 1'b0;
                fetch_data_q <= {AXI_DATA_WIDTH{1'b0}};
                fetch_access_fault_q <= 1'b0;
                fetch_page_fault_q <= 1'b0;
            end
            if (fetch_pop) begin
                fetch_state_q <= FETCH_EMPTY;
                fetch_cancelled_q <= 1'b0;
            end

            if (fetch_cancel_i && (fetch_state_q != FETCH_EMPTY)) begin
                fetch_cancelled_q <= 1'b1;
                if (fetch_state_q == FETCH_TRANSLATE)
                    fetch_state_q <= FETCH_COMPLETE;
            end

            if (fetch_lookup_valid && fetch_lookup_ready &&
                itlb_lookup_page_fault) begin
                fetch_state_q <= FETCH_COMPLETE;
                fetch_page_fault_q <= 1'b1;
            end else if (fetch_pmp_denied) begin
                fetch_state_q <= FETCH_COMPLETE;
                fetch_access_fault_q <= 1'b1;
            end else if (fetch_l1i_launch) begin
                fetch_state_q <= FETCH_WAIT_L1I;
            end else if (direct_fetch_ar_fire) begin
                fetch_state_q <= FETCH_WAIT_R;
            end

            if (start_fetch_walk)
                fetch_state_q <= FETCH_MISS;
            if (ptw_resp_valid && miss_active_q &&
                (miss_owner_q == OWNER_FETCH)) begin
                if (fetch_cancelled_q) begin
                    fetch_state_q <= FETCH_COMPLETE;
                end else if (miss_invalidated_q || tlbi_i) begin
                    fetch_state_q <= FETCH_TRANSLATE;
                end else if (ptw_resp_page_fault ||
                             ptw_resp_access_fault) begin
                    fetch_state_q <= FETCH_COMPLETE;
                    fetch_page_fault_q <= ptw_resp_page_fault;
                    fetch_access_fault_q <= ptw_resp_access_fault;
                end else begin
                    fetch_state_q <= FETCH_TRANSLATE;
                end
            end

            if (!l1i_enabled && axi_r_fire && r_is_fetch) begin
                fetch_state_q <= FETCH_COMPLETE;
                fetch_data_q <= m_axi_rdata_i;
                fetch_access_fault_q <= axi_r_error;
                fetch_page_fault_q <= 1'b0;
            end
            if (l1i_enabled && l1i_req_active_q && l1i_req_ready) begin
                fetch_state_q <= FETCH_COMPLETE;
                fetch_data_q <= l1i_req_rdata;
                fetch_access_fault_q <= l1i_req_error;
                fetch_page_fault_q <= 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lsu_state_q <= LSU_IDLE;
            lsu_write_q <= 1'b0;
            lsu_vaddr_q <= {`RV64_XLEN{1'b0}};
            lsu_paddr_q <= {`RV64_XLEN{1'b0}};
            lsu_wdata_q <= {`RV64_XLEN{1'b0}};
            lsu_wstrb_q <= 8'd0;
            lsu_size_q <= 3'd0;
            lsu_priv_q <= `RV64_PRIV_M;
            lsu_vm_mode_q <= `RV64_SATP_MODE_BARE;
            lsu_asid_q <= {`RV64_SATP_ASID_WIDTH{1'b0}};
            lsu_root_ppn_q <= {`RV64_SATP_PPN_WIDTH{1'b0}};
            lsu_sum_q <= 1'b0;
            lsu_mxr_q <= 1'b0;
            lsu_rdata_q <= {`RV64_XLEN{1'b0}};
            lsu_access_fault_q <= 1'b0;
            lsu_page_fault_q <= 1'b0;
            pipe_fallback_active_q <= 1'b0;
            pipe_fallback_cancelled_q <= 1'b0;
            pipe_fallback_tag_q <=
                {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
        end else begin
            // A translated posted store is equally irrevocable once the
            // tagged request has been accepted.  Preserve its translation,
            // physical write, and eventual error response across redirects.
            if (lsu_pipe_cancel_i && pipe_fallback_active_q && !lsu_write_q)
                pipe_fallback_cancelled_q <= 1'b1;
            case (lsu_state_q)
                LSU_IDLE: begin
                    if (lsu_valid_i || pipe_fallback_candidate) begin
                        lsu_write_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_write_i : lsu_write_i;
                        lsu_vaddr_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_addr_i : lsu_addr_i;
                        lsu_wdata_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_wdata_i : lsu_wdata_i;
                        lsu_wstrb_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_wstrb_i : lsu_wstrb_i;
                        lsu_size_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_size_i : lsu_size_i;
                        lsu_priv_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_priv_i : lsu_priv_i;
                        lsu_vm_mode_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_vm_mode_i : lsu_vm_mode_i;
                        lsu_asid_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_asid_i : lsu_asid_i;
                        lsu_root_ppn_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_root_ppn_i : lsu_root_ppn_i;
                        lsu_sum_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_sum_i : lsu_sum_i;
                        lsu_mxr_q <= pipe_fallback_candidate ?
                            lsu_pipe_req_mxr_i : lsu_mxr_i;
                        lsu_rdata_q <= {`RV64_XLEN{1'b0}};
                        lsu_access_fault_q <= 1'b0;
                        lsu_page_fault_q <= 1'b0;
                        if (pipe_fallback_candidate) begin
                            pipe_fallback_active_q <= 1'b1;
                            pipe_fallback_cancelled_q <= 1'b0;
                            pipe_fallback_tag_q <= lsu_pipe_req_tag_i;
                        end
                        lsu_state_q <= LSU_TRANSLATE;
                    end
                end

                LSU_TRANSLATE: begin
                    if (lsu_xlate_bare) begin
                        lsu_paddr_q <= lsu_vaddr_q;
                        lsu_state_q <= LSU_ACCESS;
                    end else if (dtlb_lookup_hit) begin
                        if (dtlb_lookup_page_fault) begin
                            lsu_page_fault_q <= 1'b1;
                            lsu_state_q <= LSU_RESP;
                        end else begin
                            lsu_paddr_q <= dtlb_lookup_paddr;
                            lsu_state_q <= LSU_ACCESS;
                        end
                    end else if (start_lsu_walk) begin
                        lsu_state_q <= LSU_MISS;
                    end
                end

                LSU_MISS: begin
                    if (ptw_resp_valid && miss_active_q &&
                        (miss_owner_q == OWNER_LSU)) begin
                        if (miss_invalidated_q || tlbi_i) begin
                            lsu_state_q <= LSU_TRANSLATE;
                        end else if (ptw_resp_page_fault ||
                                     ptw_resp_access_fault) begin
                            lsu_page_fault_q <= ptw_resp_page_fault;
                            lsu_access_fault_q <= ptw_resp_access_fault;
                            lsu_state_q <= LSU_RESP;
                        end else begin
                            lsu_state_q <= LSU_TRANSLATE;
                        end
                    end
                end

                LSU_ACCESS: begin
                    if (lsu_pmp_denied) begin
                        lsu_access_fault_q <= 1'b1;
                        lsu_state_q <= LSU_RESP;
                    end else if (l1d_launch) begin
                        lsu_state_q <= LSU_WAIT;
                    end
                end

                LSU_WAIT: begin
                    if (l1d_req_ready) begin
                        lsu_rdata_q <= l1d_req_rdata;
                        lsu_access_fault_q <= l1d_req_error;
                        lsu_state_q <= LSU_RESP;
                    end
                end

                LSU_RESP: begin
                    if (!pipe_fallback_active_q ||
                        pipe_fallback_cancelled_q ||
                        lsu_pipe_resp_ready_i) begin
                        lsu_state_q <= LSU_IDLE;
                        pipe_fallback_active_q <= 1'b0;
                        pipe_fallback_cancelled_q <= 1'b0;
                    end
                end

                default: lsu_state_q <= LSU_IDLE;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            miss_active_q <= 1'b0;
            miss_owner_q <= OWNER_FETCH;
            miss_invalidated_q <= 1'b0;
        end else begin
            if (ptw_req_valid && ptw_req_ready) begin
                miss_active_q <= 1'b1;
                miss_owner_q <= ptw_req_owner;
                miss_invalidated_q <= 1'b0;
            end
            if (tlbi_i && miss_active_q)
                miss_invalidated_q <= 1'b1;
            if (ptw_resp_valid) begin
                miss_active_q <= 1'b0;
                miss_invalidated_q <= 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phys_state_q <= PHYS_IDLE;
            phys_owner_q <= PHYS_OWNER_PTW;
            phys_addr_q <= {`RV64_XLEN{1'b0}};
            phys_size_q <= 3'd0;
            phys_priv_q <= `RV64_PRIV_M;
            phys_exec_q <= 1'b0;
            phys_wdata_q <= {AXI_DATA_WIDTH{1'b0}};
            phys_wstrb_q <= {AXI_BYTES{1'b0}};
            phys_aw_sent_q <= 1'b0;
            phys_w_sent_q <= 1'b0;
        end else begin
            case (phys_state_q)
                PHYS_IDLE: begin
                    if (select_phys_probe && pmp_allow_i) begin
                        phys_owner_q <= phys_candidate_owner;
                        phys_addr_q <= phys_candidate_addr;
                        phys_size_q <= phys_candidate_size;
                        phys_priv_q <= phys_candidate_priv;
                        phys_exec_q <= 1'b0;
                        if (phys_candidate_write) begin
                            phys_wdata_q <= phys_candidate_axi_wdata;
                            phys_wstrb_q <= phys_candidate_axi_wstrb;
                            phys_aw_sent_q <= 1'b0;
                            phys_w_sent_q <= 1'b0;
                            phys_state_q <= PHYS_WRITE;
                        end else if (phys_ar_fire) begin
                            phys_state_q <= PHYS_WAIT_R;
                        end
                    end
                end

                PHYS_WRITE: begin
                    if (phys_aw_fire)
                        phys_aw_sent_q <= 1'b1;
                    if (phys_w_fire)
                        phys_w_sent_q <= 1'b1;
                    if ((phys_aw_sent_q || phys_aw_fire) &&
                        (phys_w_sent_q || phys_w_fire)) begin
                        phys_state_q <= PHYS_WAIT_B;
                    end
                end

                PHYS_WAIT_R: begin
                    if (axi_r_fire && r_is_data)
                        phys_state_q <= PHYS_IDLE;
                end

                PHYS_WAIT_B: begin
                    if (phys_b_fire)
                        phys_state_q <= PHYS_IDLE;
                end

                default: phys_state_q <= PHYS_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (AXI_DATA_WIDTH != 256)
            $fatal(1, "openrv64_core_axi_bus currently requires 256-bit AXI");
    end

    always @(posedge clk) begin
        if (rst_n && !l1i_enabled && axi_r_fire && r_is_fetch &&
            (fetch_state_q != FETCH_WAIT_R))
            $fatal(1, "AXI fetch response arrived without a pending request");
    end
`endif

endmodule
