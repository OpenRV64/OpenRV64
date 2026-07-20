`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/bus/bus-defs.v"

// AXI4 core bus with a decoupled, ordered instruction-line interface.
// Fetch requests are translated one per cycle on Bare/TLB-hit paths and may
// have multiple 256-bit reads outstanding.  The request slot is carried as
// the AXI ID, allowing responses to complete out of order while the frontend
// observes them in request order.  Bare-mode three-pipe LSU requests use
// three independent AXI IDs.  Translated LSU and page-table accesses fall
// back to the precise blocking translation slot.
module openrv64_core_axi_bus #(
    parameter integer TLB_ENTRIES = 16,
    parameter integer FETCH_OUTSTANDING = 4,
    parameter integer AXI_ADDR_WIDTH = `OPENRV64_AXI_ADDR_WIDTH,
    parameter integer AXI_DATA_WIDTH = `OPENRV64_AXI_DATA_WIDTH,
    parameter integer AXI_ID_WIDTH = `OPENRV64_AXI_ID_WIDTH,
    parameter integer FETCH_SLOT_WIDTH = $clog2(FETCH_OUTSTANDING),
    parameter integer FETCH_COUNT_WIDTH = $clog2(FETCH_OUTSTANDING + 1)
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

    localparam OWNER_FETCH = 1'b0;
    localparam OWNER_LSU = 1'b1;
    localparam PHYS_OWNER_PTW = 1'b0;
    localparam PHYS_OWNER_LSU = 1'b1;
    localparam [1:0] ACCESS_READ = 2'd0;
    localparam [1:0] ACCESS_WRITE = 2'd1;
    localparam [1:0] ACCESS_EXEC = 2'd2;

    reg [2:0] fetch_state_q [0:FETCH_OUTSTANDING-1];
    reg [`RV64_XLEN-1:0] fetch_vaddr_q [0:FETCH_OUTSTANDING-1];
    reg [`RV64_PRIV_WIDTH-1:0] fetch_priv_q [0:FETCH_OUTSTANDING-1];
    reg [`RV64_SATP_MODE_WIDTH-1:0]
        fetch_vm_mode_q [0:FETCH_OUTSTANDING-1];
    reg [`RV64_SATP_ASID_WIDTH-1:0]
        fetch_asid_q [0:FETCH_OUTSTANDING-1];
    reg [`RV64_SATP_PPN_WIDTH-1:0]
        fetch_root_ppn_q [0:FETCH_OUTSTANDING-1];
    reg fetch_sum_q [0:FETCH_OUTSTANDING-1];
    reg fetch_mxr_q [0:FETCH_OUTSTANDING-1];
    reg fetch_cancelled_q [0:FETCH_OUTSTANDING-1];
    reg [AXI_DATA_WIDTH-1:0] fetch_data_q [0:FETCH_OUTSTANDING-1];
    reg fetch_access_fault_q [0:FETCH_OUTSTANDING-1];
    reg fetch_page_fault_q [0:FETCH_OUTSTANDING-1];
    reg [FETCH_SLOT_WIDTH-1:0] fetch_head_q;
    reg [FETCH_SLOT_WIDTH-1:0] fetch_tail_q;
    reg [FETCH_COUNT_WIDTH-1:0] fetch_count_q;

    reg fetch_xlate_found_r;
    reg [FETCH_SLOT_WIDTH-1:0] fetch_xlate_slot_r;
    integer fetch_scan;
    always @* begin
        fetch_xlate_found_r = 1'b0;
        fetch_xlate_slot_r = {FETCH_SLOT_WIDTH{1'b0}};
        for (fetch_scan = 0; fetch_scan < FETCH_OUTSTANDING;
             fetch_scan = fetch_scan + 1) begin
            if (!fetch_xlate_found_r &&
                (fetch_state_q[fetch_scan] == FETCH_TRANSLATE) &&
                !fetch_cancelled_q[fetch_scan]) begin
                fetch_xlate_found_r = 1'b1;
                fetch_xlate_slot_r = fetch_scan[FETCH_SLOT_WIDTH-1:0];
            end
        end
    end

    wire fetch_accept = fetch_req_valid_i && fetch_req_ready_o;
    wire fetch_head_complete = (fetch_count_q != 0) &&
        (fetch_state_q[fetch_head_q] == FETCH_COMPLETE);
    wire fetch_head_drop = fetch_head_complete &&
                           fetch_cancelled_q[fetch_head_q];
    wire fetch_resp_fire = fetch_resp_valid_o && fetch_resp_ready_i;
    wire fetch_pop = fetch_head_drop || fetch_resp_fire;

    assign fetch_req_ready_o = rst_n && !fetch_cancel_i &&
                               (fetch_count_q < FETCH_OUTSTANDING);
    assign fetch_resp_valid_o = fetch_head_complete &&
                                !fetch_cancelled_q[fetch_head_q];
    assign fetch_resp_addr_o = fetch_vaddr_q[fetch_head_q];
    assign fetch_resp_data_o = fetch_data_q[fetch_head_q];
    assign fetch_resp_access_fault_o =
        fetch_access_fault_q[fetch_head_q];
    assign fetch_resp_page_fault_o = fetch_page_fault_q[fetch_head_q];

    wire itlb_lookup_hit;
    wire [`RV64_XLEN-1:0] itlb_lookup_paddr;
    wire itlb_lookup_page_fault;
    wire fetch_xlate_bare = fetch_xlate_found_r &&
        (fetch_vm_mode_q[fetch_xlate_slot_r] == `RV64_SATP_MODE_BARE);
    wire fetch_xlate_ready = fetch_xlate_bare || itlb_lookup_hit;
    wire [`RV64_XLEN-1:0] fetch_xlate_paddr = fetch_xlate_bare ?
        fetch_vaddr_q[fetch_xlate_slot_r] : itlb_lookup_paddr;

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

    // Bare/TLB-independent fast path for the tagged three-pipe LSU.  Three
    // tags map directly to AXI IDs 4, 5, and 6; ID 7 remains owned by the
    // blocking translation/PTW path below.
    reg pipe_inflight_q [0:`OPENRV64_LSU_OUTSTANDING-1];
    reg pipe_cancelled_q [0:`OPENRV64_LSU_OUTSTANDING-1];
    reg [`RV64_XLEN-1:0]
        pipe_addr_q [0:`OPENRV64_LSU_OUTSTANDING-1];
    reg pipe_local_resp_valid_q;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] pipe_local_resp_tag_q;
    reg pipe_local_resp_fault_q;
    reg pipe_store_valid_q;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] pipe_store_tag_q;
    reg [`RV64_XLEN-1:0] pipe_store_addr_q;
    reg [2:0] pipe_store_size_q;
    reg [`RV64_PRIV_WIDTH-1:0] pipe_store_priv_q;
    reg [AXI_DATA_WIDTH-1:0] pipe_store_wdata_q;
    reg [AXI_BYTES-1:0] pipe_store_wstrb_q;
    reg pipe_store_aw_sent_q;
    reg pipe_store_w_sent_q;

    wire pipe_req_tag_valid =
        lsu_pipe_req_tag_i < `OPENRV64_LSU_OUTSTANDING;
    wire pipe_req_tag_busy = pipe_req_tag_valid &&
        (pipe_inflight_q[lsu_pipe_req_tag_i] ||
         (pipe_local_resp_valid_q &&
          (pipe_local_resp_tag_q == lsu_pipe_req_tag_i)));
    wire pipe_req_bare =
        lsu_pipe_req_vm_mode_i == `RV64_SATP_MODE_BARE;
    wire pipe_fast_candidate = lsu_pipe_req_valid_i && pipe_req_bare &&
        pipe_req_tag_valid && !pipe_req_tag_busy &&
        (!lsu_pipe_req_write_i || !pipe_store_valid_q) &&
        !pipe_local_resp_valid_q && !lsu_pipe_cancel_i;
    wire pipe_any_inflight = pipe_inflight_q[0] || pipe_inflight_q[1] ||
                             pipe_inflight_q[2];
    wire [1:0] pipe_req_word =
        lsu_pipe_req_addr_i[AXI_BYTE_BITS-1:3];
    wire [AXI_DATA_WIDTH-1:0] pipe_req_axi_wdata =
        {{(AXI_DATA_WIDTH-`RV64_XLEN){1'b0}}, lsu_pipe_req_wdata_i} <<
        (pipe_req_word * `RV64_XLEN);
    wire [AXI_BYTES-1:0] pipe_req_axi_wstrb =
        {{(AXI_BYTES-8){1'b0}}, lsu_pipe_req_wstrb_i} <<
        (pipe_req_word * 8);

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
    reg miss_owner_q;
    reg [FETCH_SLOT_WIDTH-1:0] miss_fetch_slot_q;
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
    wire fetch_needs_walk = fetch_xlate_found_r &&
                            !fetch_xlate_bare && !itlb_lookup_hit;
    wire start_lsu_walk = !miss_active_q && ptw_req_ready &&
                          lsu_needs_walk;
    wire start_fetch_walk = !miss_active_q && ptw_req_ready &&
                            !lsu_needs_walk && fetch_needs_walk;
    wire ptw_req_valid = start_lsu_walk || start_fetch_walk;
    wire ptw_req_owner = start_lsu_walk ? OWNER_LSU : OWNER_FETCH;
    wire [`RV64_XLEN-1:0] ptw_req_vaddr = start_lsu_walk ?
        lsu_vaddr_q : fetch_vaddr_q[fetch_xlate_slot_r];
    wire [1:0] ptw_req_access = start_lsu_walk ?
        (lsu_write_q ? ACCESS_WRITE : ACCESS_READ) : ACCESS_EXEC;
    wire [`RV64_PRIV_WIDTH-1:0] ptw_req_priv = start_lsu_walk ?
        lsu_priv_q : fetch_priv_q[fetch_xlate_slot_r];
    wire [`RV64_SATP_MODE_WIDTH-1:0] ptw_req_vm_mode = start_lsu_walk ?
        lsu_vm_mode_q : fetch_vm_mode_q[fetch_xlate_slot_r];
    wire [`RV64_SATP_ASID_WIDTH-1:0] ptw_req_asid = start_lsu_walk ?
        lsu_asid_q : fetch_asid_q[fetch_xlate_slot_r];
    wire [`RV64_SATP_PPN_WIDTH-1:0] ptw_req_root_ppn = start_lsu_walk ?
        lsu_root_ppn_q : fetch_root_ppn_q[fetch_xlate_slot_r];
    wire ptw_req_sum = start_lsu_walk ?
        lsu_sum_q : fetch_sum_q[fetch_xlate_slot_r];
    wire ptw_req_mxr = start_lsu_walk ?
        lsu_mxr_q : fetch_mxr_q[fetch_xlate_slot_r];

    wire itlb_fill_valid = ptw_resp_valid && miss_active_q &&
        (miss_owner_q == OWNER_FETCH) && !miss_invalidated_q &&
        !fetch_cancelled_q[miss_fetch_slot_q] &&
        !ptw_resp_page_fault && !ptw_resp_access_fault && !tlbi_i;
    wire dtlb_fill_valid = ptw_resp_valid && miss_active_q &&
        (miss_owner_q == OWNER_LSU) && !miss_invalidated_q &&
        !ptw_resp_page_fault && !ptw_resp_access_fault && !tlbi_i;

    openrv64_bus_tlb #(
        .ENTRIES(TLB_ENTRIES), .ASID_WIDTH(`RV64_SATP_ASID_WIDTH)
    ) u_itlb (
        .clk(clk), .rst_n(rst_n), .tlbi_i(tlbi_i),
        .lookup_valid_i(fetch_xlate_found_r && !fetch_xlate_bare),
        .lookup_vaddr_i(fetch_vaddr_q[fetch_xlate_slot_r]),
        .lookup_vm_mode_i(fetch_vm_mode_q[fetch_xlate_slot_r]),
        .lookup_asid_i(fetch_asid_q[fetch_xlate_slot_r]),
        .lookup_access_i(ACCESS_EXEC),
        .lookup_priv_i(fetch_priv_q[fetch_xlate_slot_r]),
        .lookup_sum_i(fetch_sum_q[fetch_xlate_slot_r]),
        .lookup_mxr_i(fetch_mxr_q[fetch_xlate_slot_r]),
        .lookup_hit_o(itlb_lookup_hit),
        .lookup_paddr_o(itlb_lookup_paddr),
        .lookup_page_fault_o(itlb_lookup_page_fault),
        .fill_valid_i(itlb_fill_valid),
        .fill_vaddr_i(fetch_vaddr_q[miss_fetch_slot_q]),
        .fill_paddr_i(ptw_resp_paddr),
        .fill_vm_mode_i(fetch_vm_mode_q[miss_fetch_slot_q]),
        .fill_asid_i(fetch_asid_q[miss_fetch_slot_q]),
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

    // Blocking data/PTW physical transaction slot.
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

    // The tagged interface must remain correct when translation is enabled.
    // Until the DTLB itself is multiported/tagged, serialize a translated
    // request through the legacy translation/PTW state machine and return its
    // result under the original tag.
    wire pipe_fallback_candidate = lsu_pipe_req_valid_i && !pipe_req_bare &&
        pipe_req_tag_valid && !pipe_req_tag_busy && !lsu_pipe_cancel_i &&
        !pipe_any_inflight && !pipe_store_valid_q &&
        !pipe_local_resp_valid_q && !pipe_fallback_active_q &&
        !lsu_valid_i && (lsu_state_q == LSU_IDLE) &&
        (phys_state_q == PHYS_IDLE) && !miss_active_q;

    wire phys_candidate_valid = (phys_state_q == PHYS_IDLE) &&
                                !pipe_store_valid_q &&
                                (ptw_mem_valid ||
                                 (lsu_state_q == LSU_ACCESS));
    wire phys_candidate_owner = ptw_mem_valid ?
        PHYS_OWNER_PTW : PHYS_OWNER_LSU;
    wire phys_candidate_write = ptw_mem_valid ?
        ptw_mem_write : lsu_write_q;
    wire [`RV64_XLEN-1:0] phys_candidate_addr = ptw_mem_valid ?
        ptw_mem_addr : lsu_paddr_q;
    wire [`RV64_XLEN-1:0] phys_candidate_wdata = ptw_mem_valid ?
        ptw_mem_wdata : lsu_wdata_q;
    wire [7:0] phys_candidate_wstrb = ptw_mem_valid ?
        ptw_mem_wstrb : lsu_wstrb_q;
    wire [2:0] phys_candidate_size = ptw_mem_valid ? 3'd3 : lsu_size_q;
    wire [`RV64_PRIV_WIDTH-1:0] phys_candidate_priv = ptw_mem_valid ?
        `RV64_PRIV_S : lsu_priv_q;
    wire [1:0] phys_candidate_word =
        phys_candidate_addr[AXI_BYTE_BITS-1:3];
    wire [AXI_DATA_WIDTH-1:0] phys_candidate_axi_wdata =
        {{(AXI_DATA_WIDTH-`RV64_XLEN){1'b0}}, phys_candidate_wdata} <<
        (phys_candidate_word * `RV64_XLEN);
    wire [AXI_BYTES-1:0] phys_candidate_axi_wstrb =
        {{(AXI_BYTES-8){1'b0}}, phys_candidate_wstrb} <<
        (phys_candidate_word * 8);

    wire fetch_axi_candidate = fetch_xlate_found_r && fetch_xlate_ready &&
                               !itlb_lookup_page_fault &&
                               !fetch_cancel_i;
    wire [`RV64_XLEN-1:0] fetch_axi_addr = {
        fetch_xlate_paddr[`RV64_XLEN-1:AXI_BYTE_BITS],
        {AXI_BYTE_BITS{1'b0}}
    };

    // Tagged data gets the single PMP probe and AR channel first, followed by
    // PTW/legacy data and then instruction fetch.
    wire select_pipe_probe = pipe_fast_candidate;
    wire select_phys_probe = !select_pipe_probe && phys_candidate_valid;
    wire select_fetch_probe = !select_pipe_probe && !select_phys_probe &&
                              fetch_axi_candidate;
    assign pmp_valid_o = select_pipe_probe || select_phys_probe ||
                         select_fetch_probe;
    assign pmp_addr_o = select_pipe_probe ? lsu_pipe_req_addr_i :
                        select_phys_probe ? phys_candidate_addr :
                        fetch_axi_addr;
    assign pmp_priv_o = select_pipe_probe ? lsu_pipe_req_priv_i :
                        select_phys_probe ? phys_candidate_priv :
                        fetch_priv_q[fetch_xlate_slot_r];
    assign pmp_size_o = select_pipe_probe ? lsu_pipe_req_size_i :
                        select_phys_probe ? phys_candidate_size : 3'd5;
    assign pmp_write_o = select_pipe_probe ? lsu_pipe_req_write_i :
                         select_phys_probe && phys_candidate_write;
    assign pmp_exec_o = select_fetch_probe;

    wire pipe_pmp_denied = select_pipe_probe && !pmp_allow_i;
    wire phys_pmp_denied = select_phys_probe && !pmp_allow_i;
    wire fetch_pmp_denied = select_fetch_probe && !pmp_allow_i;
    wire pipe_read_arvalid = select_pipe_probe &&
                             !lsu_pipe_req_write_i && pmp_allow_i;
    wire phys_read_arvalid = select_phys_probe && !phys_candidate_write &&
                             pmp_allow_i;
    wire fetch_arvalid = select_fetch_probe && pmp_allow_i;
    wire select_phys_ar = phys_read_arvalid;

    assign m_axi_arvalid_o = pipe_read_arvalid || phys_read_arvalid ||
                             fetch_arvalid;
    assign m_axi_arid_o = pipe_read_arvalid ?
                          {1'b1, lsu_pipe_req_tag_i} :
                          select_phys_ar ? DATA_AXI_ID :
                          {{(AXI_ID_WIDTH-FETCH_SLOT_WIDTH){1'b0}},
                           fetch_xlate_slot_r};
    assign m_axi_araddr_o = pipe_read_arvalid ? lsu_pipe_req_addr_i :
                            select_phys_ar ? phys_candidate_addr :
                            fetch_axi_addr;
    assign m_axi_arlen_o = 8'd0;
    assign m_axi_arsize_o = pipe_read_arvalid ? lsu_pipe_req_size_i :
                            select_phys_ar ? phys_candidate_size : 3'd5;
    assign m_axi_arburst_o = 2'b01;
    assign m_axi_arlock_o = 1'b0;
    assign m_axi_arcache_o = (pipe_read_arvalid || select_phys_ar) ?
                             4'b0010 : 4'b1110;
    assign m_axi_arprot_o = {
        (pipe_read_arvalid || select_phys_ar) ? 1'b0 : 1'b1,
        1'b0,
        (pipe_read_arvalid ? lsu_pipe_req_priv_i :
         select_phys_ar ? phys_candidate_priv :
         fetch_priv_q[fetch_xlate_slot_r]) == `RV64_PRIV_U
    };
    assign m_axi_arqos_o = 4'd0;
    wire axi_ar_fire = m_axi_arvalid_o && m_axi_arready_i;
    wire pipe_ar_fire = axi_ar_fire && pipe_read_arvalid;
    wire phys_ar_fire = axi_ar_fire && !pipe_read_arvalid && select_phys_ar;
    wire fetch_ar_fire = axi_ar_fire && !pipe_read_arvalid && !select_phys_ar;

    wire pipe_write_accept = select_pipe_probe && lsu_pipe_req_write_i &&
                             pmp_allow_i && !pipe_store_valid_q;
    assign lsu_pipe_req_ready_o =
        (pipe_fast_candidate &&
         (pipe_pmp_denied || (lsu_pipe_req_write_i ? pipe_write_accept :
                                                        pipe_ar_fire))) ||
        pipe_fallback_candidate;
    wire pipe_req_fire = lsu_pipe_req_valid_i && lsu_pipe_req_ready_o;

    wire select_pipe_write = pipe_store_valid_q;
    assign m_axi_awid_o = select_pipe_write ?
                          {1'b1, pipe_store_tag_q} : DATA_AXI_ID;
    assign m_axi_awaddr_o = select_pipe_write ? pipe_store_addr_q :
                            phys_addr_q;
    assign m_axi_awlen_o = 8'd0;
    assign m_axi_awsize_o = select_pipe_write ? pipe_store_size_q :
                            phys_size_q;
    assign m_axi_awburst_o = 2'b01;
    assign m_axi_awlock_o = 1'b0;
    assign m_axi_awcache_o = 4'b0010;
    assign m_axi_awprot_o = {
        select_pipe_write ? 1'b0 : phys_exec_q,
        1'b0,
        ((select_pipe_write ? pipe_store_priv_q : phys_priv_q) ==
         `RV64_PRIV_U)
    };
    assign m_axi_awqos_o = 4'd0;
    assign m_axi_awvalid_o = select_pipe_write ? !pipe_store_aw_sent_q :
        ((phys_state_q == PHYS_WRITE) && !phys_aw_sent_q);
    assign m_axi_wdata_o = select_pipe_write ? pipe_store_wdata_q :
                            phys_wdata_q;
    assign m_axi_wstrb_o = select_pipe_write ? pipe_store_wstrb_q :
                            phys_wstrb_q;
    assign m_axi_wlast_o = 1'b1;
    assign m_axi_wvalid_o = select_pipe_write ? !pipe_store_w_sent_q :
        ((phys_state_q == PHYS_WRITE) && !phys_w_sent_q);
    wire axi_aw_fire = m_axi_awvalid_o && m_axi_awready_i;
    wire axi_w_fire = m_axi_wvalid_o && m_axi_wready_i;
    wire pipe_aw_fire = axi_aw_fire && select_pipe_write;
    wire pipe_w_fire = axi_w_fire && select_pipe_write;
    wire phys_aw_fire = axi_aw_fire && !select_pipe_write;
    wire phys_w_fire = axi_w_fire && !select_pipe_write;

    wire b_is_pipe = pipe_store_valid_q &&
        (m_axi_bid_i == {1'b1, pipe_store_tag_q});
    wire pipe_store_cancelled = pipe_cancelled_q[pipe_store_tag_q];
    assign m_axi_bready_o = b_is_pipe ?
        (!pipe_local_resp_valid_q &&
         (pipe_store_cancelled || lsu_pipe_resp_ready_i)) :
        ((phys_state_q == PHYS_WAIT_B) && (m_axi_bid_i == DATA_AXI_ID));
    wire pipe_b_fire = m_axi_bvalid_i && m_axi_bready_o && b_is_pipe;
    wire phys_b_fire = m_axi_bvalid_i && m_axi_bready_o && !b_is_pipe;

    wire r_is_data = (m_axi_rid_i == DATA_AXI_ID);
    wire r_is_pipe = (m_axi_rid_i >= 3'd4) && (m_axi_rid_i <= 3'd6);
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] r_pipe_tag =
        m_axi_rid_i[`OPENRV64_LSU_TAG_WIDTH-1:0];
    wire r_is_fetch = (m_axi_rid_i < FETCH_OUTSTANDING);
    wire [FETCH_SLOT_WIDTH-1:0] r_fetch_slot =
        m_axi_rid_i[FETCH_SLOT_WIDTH-1:0];
    wire pipe_r_cancelled = r_is_pipe && pipe_cancelled_q[r_pipe_tag];
    assign m_axi_rready_o = r_is_pipe ?
        (!pipe_local_resp_valid_q && pipe_inflight_q[r_pipe_tag] &&
         (pipe_r_cancelled || lsu_pipe_resp_ready_i)) :
        r_is_data ?
        (phys_state_q == PHYS_WAIT_R) :
        r_is_fetch && (fetch_state_q[r_fetch_slot] == FETCH_WAIT_R);
    wire axi_r_fire = m_axi_rvalid_i && m_axi_rready_o;
    wire pipe_r_fire = axi_r_fire && r_is_pipe;
    wire axi_r_error = m_axi_rresp_i[1] || !m_axi_rlast_i;
    wire [1:0] phys_response_word =
        phys_addr_q[AXI_BYTE_BITS-1:3];
    wire [AXI_DATA_WIDTH-1:0] phys_shifted_rdata =
        m_axi_rdata_i >> (phys_response_word * `RV64_XLEN);
    wire [`RV64_XLEN-1:0] phys_rdata =
        phys_shifted_rdata[`RV64_XLEN-1:0];

    wire [1:0] pipe_response_word =
        pipe_addr_q[r_pipe_tag][AXI_BYTE_BITS-1:3];
    wire [AXI_DATA_WIDTH-1:0] pipe_shifted_rdata =
        m_axi_rdata_i >> (pipe_response_word * `RV64_XLEN);
    wire [`RV64_XLEN-1:0] pipe_rdata =
        pipe_shifted_rdata[`RV64_XLEN-1:0];
    wire pipe_local_resp_fire = pipe_local_resp_valid_q &&
                                lsu_pipe_resp_ready_i;
    wire pipe_r_visible = m_axi_rvalid_i && r_is_pipe &&
                          pipe_inflight_q[r_pipe_tag] &&
                          !pipe_cancelled_q[r_pipe_tag] &&
                          !pipe_local_resp_valid_q;
    wire pipe_b_visible = m_axi_bvalid_i && b_is_pipe &&
                          pipe_inflight_q[pipe_store_tag_q] &&
                          !pipe_cancelled_q[pipe_store_tag_q] &&
                          !pipe_local_resp_valid_q;
    wire pipe_fallback_visible = pipe_fallback_active_q &&
        !pipe_fallback_cancelled_q && (lsu_state_q == LSU_RESP) &&
        !pipe_local_resp_valid_q;
    assign lsu_pipe_resp_valid_o = pipe_local_resp_valid_q ||
                                   pipe_r_visible || pipe_b_visible ||
                                   pipe_fallback_visible;
    assign lsu_pipe_resp_tag_o = pipe_local_resp_valid_q ?
        pipe_local_resp_tag_q : pipe_r_visible ? r_pipe_tag :
        pipe_b_visible ? pipe_store_tag_q : pipe_fallback_tag_q;
    assign lsu_pipe_resp_rdata_o = pipe_r_visible ? pipe_rdata :
        pipe_fallback_visible ? lsu_rdata_q : {`RV64_XLEN{1'b0}};
    assign lsu_pipe_resp_access_fault_o = pipe_local_resp_valid_q ?
        pipe_local_resp_fault_q : pipe_r_visible ? axi_r_error :
        pipe_b_visible ? m_axi_bresp_i[1] :
        pipe_fallback_visible && lsu_access_fault_q;
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

    integer pipe_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_local_resp_valid_q <= 1'b0;
            pipe_local_resp_tag_q <=
                {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
            pipe_local_resp_fault_q <= 1'b0;
            pipe_store_valid_q <= 1'b0;
            pipe_store_tag_q <= {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
            pipe_store_addr_q <= {`RV64_XLEN{1'b0}};
            pipe_store_size_q <= 3'd0;
            pipe_store_priv_q <= `RV64_PRIV_M;
            pipe_store_wdata_q <= {AXI_DATA_WIDTH{1'b0}};
            pipe_store_wstrb_q <= {AXI_BYTES{1'b0}};
            pipe_store_aw_sent_q <= 1'b0;
            pipe_store_w_sent_q <= 1'b0;
            for (pipe_index = 0;
                 pipe_index < `OPENRV64_LSU_OUTSTANDING;
                 pipe_index = pipe_index + 1) begin
                pipe_inflight_q[pipe_index] <= 1'b0;
                pipe_cancelled_q[pipe_index] <= 1'b0;
                pipe_addr_q[pipe_index] <= {`RV64_XLEN{1'b0}};
            end
        end else begin
            if (lsu_pipe_cancel_i) begin
                pipe_local_resp_valid_q <= 1'b0;
                for (pipe_index = 0;
                     pipe_index < `OPENRV64_LSU_OUTSTANDING;
                     pipe_index = pipe_index + 1) begin
                    // Reads are speculative and are drained invisibly after
                    // a redirect.  An accepted write is irrevocable and its
                    // B response must remain visible for posted-store error
                    // reporting.
                    if (pipe_inflight_q[pipe_index] &&
                        !(pipe_store_valid_q &&
                          (pipe_store_tag_q == pipe_index)))
                        pipe_cancelled_q[pipe_index] <= 1'b1;
                end
            end

            if (pipe_req_fire && pipe_pmp_denied) begin
                pipe_local_resp_valid_q <= 1'b1;
                pipe_local_resp_tag_q <= lsu_pipe_req_tag_i;
                pipe_local_resp_fault_q <= 1'b1;
            end else if (pipe_local_resp_fire) begin
                pipe_local_resp_valid_q <= 1'b0;
            end

            if (pipe_ar_fire) begin
                pipe_inflight_q[lsu_pipe_req_tag_i] <= 1'b1;
                pipe_cancelled_q[lsu_pipe_req_tag_i] <= 1'b0;
                pipe_addr_q[lsu_pipe_req_tag_i] <= lsu_pipe_req_addr_i;
            end

            if (pipe_write_accept) begin
                pipe_inflight_q[lsu_pipe_req_tag_i] <= 1'b1;
                pipe_cancelled_q[lsu_pipe_req_tag_i] <= 1'b0;
                pipe_addr_q[lsu_pipe_req_tag_i] <= lsu_pipe_req_addr_i;
                pipe_store_valid_q <= 1'b1;
                pipe_store_tag_q <= lsu_pipe_req_tag_i;
                pipe_store_addr_q <= lsu_pipe_req_addr_i;
                pipe_store_size_q <= lsu_pipe_req_size_i;
                pipe_store_priv_q <= lsu_pipe_req_priv_i;
                pipe_store_wdata_q <= pipe_req_axi_wdata;
                pipe_store_wstrb_q <= pipe_req_axi_wstrb;
                pipe_store_aw_sent_q <= 1'b0;
                pipe_store_w_sent_q <= 1'b0;
            end

            if (pipe_aw_fire)
                pipe_store_aw_sent_q <= 1'b1;
            if (pipe_w_fire)
                pipe_store_w_sent_q <= 1'b1;

            if (pipe_r_fire) begin
                pipe_inflight_q[r_pipe_tag] <= 1'b0;
                pipe_cancelled_q[r_pipe_tag] <= 1'b0;
            end
            if (pipe_b_fire) begin
                pipe_inflight_q[pipe_store_tag_q] <= 1'b0;
                pipe_cancelled_q[pipe_store_tag_q] <= 1'b0;
                pipe_store_valid_q <= 1'b0;
                pipe_store_aw_sent_q <= 1'b0;
                pipe_store_w_sent_q <= 1'b0;
            end
        end
    end

    integer fetch_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_head_q <= {FETCH_SLOT_WIDTH{1'b0}};
            fetch_tail_q <= {FETCH_SLOT_WIDTH{1'b0}};
            fetch_count_q <= {FETCH_COUNT_WIDTH{1'b0}};
            for (fetch_index = 0; fetch_index < FETCH_OUTSTANDING;
                 fetch_index = fetch_index + 1) begin
                fetch_state_q[fetch_index] <= FETCH_EMPTY;
                fetch_vaddr_q[fetch_index] <= {`RV64_XLEN{1'b0}};
                fetch_priv_q[fetch_index] <= `RV64_PRIV_M;
                fetch_vm_mode_q[fetch_index] <= `RV64_SATP_MODE_BARE;
                fetch_asid_q[fetch_index] <=
                    {`RV64_SATP_ASID_WIDTH{1'b0}};
                fetch_root_ppn_q[fetch_index] <=
                    {`RV64_SATP_PPN_WIDTH{1'b0}};
                fetch_sum_q[fetch_index] <= 1'b0;
                fetch_mxr_q[fetch_index] <= 1'b0;
                fetch_cancelled_q[fetch_index] <= 1'b0;
                fetch_data_q[fetch_index] <= {AXI_DATA_WIDTH{1'b0}};
                fetch_access_fault_q[fetch_index] <= 1'b0;
                fetch_page_fault_q[fetch_index] <= 1'b0;
            end
        end else begin
            case ({fetch_accept, fetch_pop})
                2'b10: fetch_count_q <= fetch_count_q + 1'b1;
                2'b01: fetch_count_q <= fetch_count_q - 1'b1;
                default: begin
                end
            endcase
            if (fetch_accept) begin
                fetch_state_q[fetch_tail_q] <= FETCH_TRANSLATE;
                fetch_vaddr_q[fetch_tail_q] <= {
                    fetch_req_addr_i[`RV64_XLEN-1:AXI_BYTE_BITS],
                    {AXI_BYTE_BITS{1'b0}}
                };
                fetch_priv_q[fetch_tail_q] <= fetch_req_priv_i;
                fetch_vm_mode_q[fetch_tail_q] <= fetch_req_vm_mode_i;
                fetch_asid_q[fetch_tail_q] <= fetch_req_asid_i;
                fetch_root_ppn_q[fetch_tail_q] <= fetch_req_root_ppn_i;
                fetch_sum_q[fetch_tail_q] <= fetch_req_sum_i;
                fetch_mxr_q[fetch_tail_q] <= fetch_req_mxr_i;
                fetch_cancelled_q[fetch_tail_q] <= 1'b0;
                fetch_data_q[fetch_tail_q] <= {AXI_DATA_WIDTH{1'b0}};
                fetch_access_fault_q[fetch_tail_q] <= 1'b0;
                fetch_page_fault_q[fetch_tail_q] <= 1'b0;
                fetch_tail_q <= fetch_tail_q + 1'b1;
            end
            if (fetch_pop) begin
                fetch_state_q[fetch_head_q] <= FETCH_EMPTY;
                fetch_cancelled_q[fetch_head_q] <= 1'b0;
                fetch_head_q <= fetch_head_q + 1'b1;
            end

            if (fetch_cancel_i) begin
                for (fetch_index = 0; fetch_index < FETCH_OUTSTANDING;
                     fetch_index = fetch_index + 1) begin
                    if (fetch_state_q[fetch_index] != FETCH_EMPTY) begin
                        fetch_cancelled_q[fetch_index] <= 1'b1;
                        if (fetch_state_q[fetch_index] == FETCH_TRANSLATE)
                            fetch_state_q[fetch_index] <= FETCH_COMPLETE;
                    end
                end
            end

            if (fetch_xlate_found_r && fetch_xlate_ready &&
                itlb_lookup_page_fault) begin
                fetch_state_q[fetch_xlate_slot_r] <= FETCH_COMPLETE;
                fetch_page_fault_q[fetch_xlate_slot_r] <= 1'b1;
            end else if (fetch_pmp_denied) begin
                fetch_state_q[fetch_xlate_slot_r] <= FETCH_COMPLETE;
                fetch_access_fault_q[fetch_xlate_slot_r] <= 1'b1;
            end else if (fetch_ar_fire) begin
                fetch_state_q[fetch_xlate_slot_r] <= FETCH_WAIT_R;
            end

            if (start_fetch_walk) begin
                fetch_state_q[fetch_xlate_slot_r] <= FETCH_MISS;
            end
            if (ptw_resp_valid && miss_active_q &&
                (miss_owner_q == OWNER_FETCH)) begin
                if (miss_invalidated_q || tlbi_i) begin
                    fetch_state_q[miss_fetch_slot_q] <= FETCH_TRANSLATE;
                end else if (fetch_cancelled_q[miss_fetch_slot_q]) begin
                    fetch_state_q[miss_fetch_slot_q] <= FETCH_COMPLETE;
                end else if (ptw_resp_page_fault ||
                             ptw_resp_access_fault) begin
                    fetch_state_q[miss_fetch_slot_q] <= FETCH_COMPLETE;
                    fetch_page_fault_q[miss_fetch_slot_q] <=
                        ptw_resp_page_fault;
                    fetch_access_fault_q[miss_fetch_slot_q] <=
                        ptw_resp_access_fault;
                end else begin
                    fetch_state_q[miss_fetch_slot_q] <= FETCH_TRANSLATE;
                end
            end

            if (axi_r_fire && r_is_fetch) begin
                fetch_state_q[r_fetch_slot] <= FETCH_COMPLETE;
                fetch_data_q[r_fetch_slot] <= m_axi_rdata_i;
                fetch_access_fault_q[r_fetch_slot] <= axi_r_error;
                fetch_page_fault_q[r_fetch_slot] <= 1'b0;
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
                    if (phys_pmp_denied &&
                        (phys_candidate_owner == PHYS_OWNER_LSU)) begin
                        lsu_access_fault_q <= 1'b1;
                        lsu_state_q <= LSU_RESP;
                    end else if ((phys_ar_fire &&
                                  (phys_candidate_owner == PHYS_OWNER_LSU)) ||
                                 (select_phys_probe &&
                                  phys_candidate_write && pmp_allow_i &&
                                  (phys_candidate_owner ==
                                   PHYS_OWNER_LSU))) begin
                        lsu_state_q <= LSU_WAIT;
                    end
                end

                LSU_WAIT: begin
                    if (axi_r_fire && r_is_data &&
                        (phys_owner_q == PHYS_OWNER_LSU)) begin
                        lsu_rdata_q <= phys_rdata;
                        lsu_access_fault_q <= axi_r_error;
                        lsu_state_q <= LSU_RESP;
                    end else if (phys_b_fire &&
                                 (phys_owner_q == PHYS_OWNER_LSU)) begin
                        lsu_access_fault_q <= m_axi_bresp_i[1];
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
            miss_fetch_slot_q <= {FETCH_SLOT_WIDTH{1'b0}};
            miss_invalidated_q <= 1'b0;
        end else begin
            if (ptw_req_valid && ptw_req_ready) begin
                miss_active_q <= 1'b1;
                miss_owner_q <= ptw_req_owner;
                miss_fetch_slot_q <= fetch_xlate_slot_r;
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
        if ((FETCH_OUTSTANDING < 2) ||
            ((1 << FETCH_SLOT_WIDTH) != FETCH_OUTSTANDING))
            $fatal(1, "FETCH_OUTSTANDING must be a power of two >= 2");
        if (AXI_ID_WIDTH <= FETCH_SLOT_WIDTH)
            $fatal(1, "AXI ID width must reserve a data transaction ID");
    end

    always @(posedge clk) begin
        if (rst_n && axi_r_fire && r_is_fetch &&
            (fetch_state_q[r_fetch_slot] != FETCH_WAIT_R))
            $fatal(1, "AXI fetch response ID does not name an outstanding read");
    end
`endif

endmodule
