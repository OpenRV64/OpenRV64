`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

module tb_icx_bus #(
    parameter integer L1D_FILL_BUFFER_LINES = 8,
    parameter integer L1D_STORE_BUFFER_LINES = 8
);
    logic clk;
    logic rst_n;
    logic fetch_req_valid;
    wire fetch_req_ready;
    logic [63:0] fetch_req_addr;
    logic fetch_req_stash;
    logic fetch_req_demand;
    logic [`RV64_PRIV_WIDTH-1:0] fetch_req_priv;
    logic [`RV64_SATP_MODE_WIDTH-1:0] fetch_req_vm_mode;
    logic [`RV64_SATP_PPN_WIDTH-1:0] fetch_req_root_ppn;
    logic fetch_cancel;
    wire fetch_resp_valid;
    logic fetch_resp_ready;
    wire [63:0] fetch_resp_addr;
    wire [255:0] fetch_resp_data;
    wire fetch_resp_access_fault;
    wire fetch_resp_page_fault;
    wire fetch_resp_stash;
    wire fetch_resp_demand;
    logic [2:0] icache_age_valid;
    logic [3*64-1:0] icache_age_addr;

    logic lsu_valid;
    logic lsu_write;
    logic [63:0] lsu_addr;
    logic [63:0] lsu_wdata;
    logic [7:0] lsu_wstrb;
    logic [2:0] lsu_size;
    wire lsu_ready;
    wire [63:0] lsu_rdata;
    wire lsu_access_fault;
    wire lsu_page_fault;

    logic pipe_req_valid;
    logic pipe_req_lock;
    logic pipe_req_xlate_only;
    logic pipe_req_physical;
    wire pipe_req_ready;
    logic [`OPENRV64_LSU_TAG_WIDTH-1:0] pipe_req_tag;
    logic pipe_req_write;
    logic [63:0] pipe_req_addr;
    logic [63:0] pipe_req_wdata;
    logic [7:0] pipe_req_wstrb;
    logic [2:0] pipe_req_size;
    logic [1:0] pipe_req_priv;
    logic [3:0] pipe_req_vm_mode;
    logic [43:0] pipe_req_root_ppn;
    logic pipe_cancel;
    wire pipe_req_translation_hit;
    wire [63:0] pipe_req_translation_paddr;
    wire pipe_req_translation_page_fault;
    logic tlbi;
    logic context_flush;
    logic [`RV64_SATP_ASID_WIDTH-1:0] current_asid;
    wire tlbi_busy;
    wire pipe_resp_valid;
    logic pipe_resp_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] pipe_resp_tag;
    wire [63:0] pipe_resp_paddr;
    wire [63:0] pipe_resp_rdata;
    wire pipe_resp_access_fault;
    wire pipe_resp_page_fault;
    wire pipe_store_done_valid;
    logic pipe_store_done_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] pipe_store_done_tag;
    logic xlate_req_valid;
    wire xlate_req_ready;
    logic [`OPENRV64_LSU_TAG_WIDTH-1:0] xlate_req_tag;
    logic xlate_req_write;
    logic [63:0] xlate_req_vaddr;
    logic [1:0] xlate_req_priv;
    logic [3:0] xlate_req_vm_mode;
    logic [43:0] xlate_req_root_ppn;
    wire xlate_resp_valid;
    logic xlate_resp_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] xlate_resp_tag;
    wire [63:0] xlate_resp_paddr;
    wire xlate_resp_access_fault;
    wire xlate_resp_page_fault;

    wire pmp_valid;
    wire [63:0] pmp_addr;
    wire [1:0] pmp_priv;
    wire [2:0] pmp_size;
    wire pmp_write;
    wire pmp_exec;
    logic pmp_allow;

    wire [2:0] arid;
    wire [63:0] araddr;
    wire [7:0] arlen;
    wire [2:0] arsize;
    wire [1:0] arburst;
    wire arvalid;
    logic arready;
    logic [2:0] rid;
    logic [255:0] rdata;
    logic [1:0] rresp;
    logic rlast;
    logic rvalid;
    wire rready;
    wire [2:0] awid;
    wire [63:0] awaddr;
    wire [2:0] awsize;
    wire awvalid;
    logic awready;
    wire [255:0] wdata;
    wire [31:0] wstrb;
    wire wlast;
    wire wvalid;
    logic wready;
    logic [2:0] bid;
    logic [1:0] bresp;
    logic bvalid;
    wire bready;

    wire icx_req_valid;
    wire icx_req_ready;
    wire [3:0] icx_req_hart_id;
    wire [3:0] icx_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    wire [3:0] icx_req_op;
    wire icx_req_lock;
    wire [1:0] icx_req_order;
    wire [1:0] icx_req_kind;
    wire [3:0] icx_req_attr;
    wire [2:0] icx_req_size;
    wire [63:0] icx_req_addr;
    wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_req_burst_len;
    wire icx_wdata_valid;
    wire icx_wdata_ready;
    wire [3:0] icx_wdata_hart_id;
    wire [3:0] icx_wdata_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_wdata_source_id;
    wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_wdata_beat_index;
    wire icx_wdata_last;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_wdata;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_wstrb;
    logic icx_resp_valid;
    wire icx_resp_ready;
    logic [3:0] icx_resp_hart_id;
    logic [3:0] icx_resp_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id;
    logic [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_resp_beat_index;
    logic icx_resp_last;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata;
    logic icx_resp_error;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_memory [0:255];
    logic icx_cmd_pending;
    logic [3:0] icx_cmd_hart_id;
    logic [3:0] icx_cmd_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_cmd_source_id;
    logic [3:0] icx_cmd_op;
    logic [2:0] icx_cmd_size;
    logic [63:0] icx_cmd_addr;
    logic icx_data_pending;
    logic [3:0] icx_data_hart_id;
    logic [3:0] icx_data_txn_id;
    logic [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_data_source_id;
    logic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_data;
    logic [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_data_strb;
    logic icx_fail_enable;
    logic [63:0] icx_fail_addr;
    logic icx_allow_cmd;
    logic icx_allow_wdata;
    integer icx_reads;
    integer icx_writes;
    integer icx_fences;
    integer icx_locked_reads;
    integer icx_locked_writes;
    integer icx_byte;
    integer icx_index;
    integer icx_word_index;

    integer ar_count;
    integer wait_count;
    integer channel_wait;
    integer ptw_wait;
    integer cancel_fetch_slot;
    integer locked_reads_before;
    integer fences_before;
    integer translated_fast_fires;
    integer translated_fast_store_fires;
    integer l2_tlb_hits;
    integer l2_tlb_way;
    integer l2_tlb_set;
    reg [63:0] locked_old_word;
    reg [2:0] seen_id [0:15];
    reg [63:0] seen_addr [0:15];

    always @(posedge clk) begin
        if (!rst_n) begin
            translated_fast_fires <= 0;
            translated_fast_store_fires <= 0;
            l2_tlb_hits <= 0;
        end else begin
            if (dut.pipe_fast_request_fire) begin
                translated_fast_fires <= translated_fast_fires + 1;
                if (dut.l1d_req_write)
                    translated_fast_store_fires <=
                        translated_fast_store_fires + 1;
            end
            if (dut.u_l2_tlb.diag_hit)
                l2_tlb_hits <= l2_tlb_hits + 1;
        end
    end

    openrv64_core_icx_bus #(
        .ENABLE_L1I(0),
        .L1D_PREFETCH_ENABLE(0),
        .L1D_FILL_BUFFER_LINES(L1D_FILL_BUFFER_LINES),
        .L1D_STORE_BUFFER_LINES(L1D_STORE_BUFFER_LINES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .fetch_req_valid_i(fetch_req_valid),
        .fetch_req_ready_o(fetch_req_ready),
        .fetch_req_addr_i(fetch_req_addr),
        .fetch_req_stash_i(fetch_req_stash),
        .fetch_req_demand_i(fetch_req_demand),
        .fetch_req_priv_i(fetch_req_priv),
        .fetch_req_vm_mode_i(fetch_req_vm_mode),
        .fetch_req_asid_i(current_asid),
        .fetch_req_root_ppn_i(fetch_req_root_ppn),
        .fetch_req_sum_i(1'b0), .fetch_req_mxr_i(1'b0),
        .fetch_cancel_i(fetch_cancel),
        .fetch_cancel_stash_i(1'b1),
        .fetch_resp_valid_o(fetch_resp_valid),
        .fetch_resp_ready_i(fetch_resp_ready),
        .fetch_resp_addr_o(fetch_resp_addr),
        .fetch_resp_data_o(fetch_resp_data),
        .fetch_resp_access_fault_o(fetch_resp_access_fault),
        .fetch_resp_page_fault_o(fetch_resp_page_fault),
        .fetch_resp_stash_o(fetch_resp_stash),
        .fetch_resp_demand_o(fetch_resp_demand),
        .lsu_valid_i(lsu_valid), .lsu_lock_i(1'b0),
        .lsu_write_i(lsu_write),
        .lsu_addr_i(lsu_addr), .lsu_wdata_i(lsu_wdata),
        .lsu_wstrb_i(lsu_wstrb), .lsu_size_i(lsu_size),
        .lsu_priv_i(`RV64_PRIV_M),
        .lsu_vm_mode_i(`RV64_SATP_MODE_BARE),
        .lsu_asid_i(current_asid), .lsu_root_ppn_i(44'd0),
        .lsu_sum_i(1'b0), .lsu_mxr_i(1'b0),
        .lsu_ready_o(lsu_ready), .lsu_rdata_o(lsu_rdata),
        .lsu_access_fault_o(lsu_access_fault),
        .lsu_page_fault_o(lsu_page_fault), .tlbi_i(tlbi),
        .context_flush_i(context_flush),
        .tlbi_busy_o(tlbi_busy),
        .store_barrier_i(1'b0),
        .icache_invalidate_i(1'b0),
        .m_mode_prefetch_enable_i(1'b0),
        .icache_prefetch_valid_i(1'b0),
        .icache_prefetch_taken_addr_i(64'd0),
        .icache_prefetch_fallthrough_addr_i(64'd0),
        .icache_age_valid_i(icache_age_valid),
        .icache_age_addr_i(icache_age_addr),
        .lsu_pipe_req_valid_i(pipe_req_valid),
        .lsu_pipe_req_ready_o(pipe_req_ready),
        .lsu_pipe_req_tag_i(pipe_req_tag),
        .lsu_pipe_req_xlate_only_i(pipe_req_xlate_only),
        .lsu_pipe_req_physical_i(pipe_req_physical),
        .lsu_pipe_req_lock_i(pipe_req_lock),
        .lsu_pipe_req_write_i(pipe_req_write),
        .lsu_pipe_req_addr_i(pipe_req_addr),
        .lsu_pipe_req_wdata_i(pipe_req_wdata),
        .lsu_pipe_req_wstrb_i(pipe_req_wstrb),
        .lsu_pipe_req_size_i(pipe_req_size),
        .lsu_pipe_req_priv_i(pipe_req_priv),
        .lsu_pipe_req_vm_mode_i(pipe_req_vm_mode),
        .lsu_pipe_req_asid_i(current_asid),
        .lsu_pipe_req_root_ppn_i(pipe_req_root_ppn),
        .lsu_pipe_req_sum_i(1'b0), .lsu_pipe_req_mxr_i(1'b0),
        .lsu_pipe_req_translation_hit_o(pipe_req_translation_hit),
        .lsu_pipe_req_translation_paddr_o(
            pipe_req_translation_paddr),
        .lsu_pipe_req_translation_page_fault_o(
            pipe_req_translation_page_fault),
        .lsu_pipe_cancel_i(pipe_cancel),
        .lsu_pipe_resp_valid_o(pipe_resp_valid),
        .lsu_pipe_resp_ready_i(pipe_resp_ready),
        .lsu_pipe_resp_tag_o(pipe_resp_tag),
        .lsu_pipe_resp_paddr_o(pipe_resp_paddr),
        .lsu_pipe_resp_rdata_o(pipe_resp_rdata),
        .lsu_pipe_resp_access_fault_o(pipe_resp_access_fault),
        .lsu_pipe_resp_page_fault_o(pipe_resp_page_fault),
        .lsu_pipe_store_done_valid_o(pipe_store_done_valid),
        .lsu_pipe_store_done_ready_i(pipe_store_done_ready),
        .lsu_pipe_store_done_tag_o(pipe_store_done_tag),
        .lsu_xlate_req_valid_i(xlate_req_valid),
        .lsu_xlate_req_ready_o(xlate_req_ready),
        .lsu_xlate_req_tag_i(xlate_req_tag),
        .lsu_xlate_req_write_i(xlate_req_write),
        .lsu_xlate_req_vaddr_i(xlate_req_vaddr),
        .lsu_xlate_req_priv_i(xlate_req_priv),
        .lsu_xlate_req_vm_mode_i(xlate_req_vm_mode),
        .lsu_xlate_req_asid_i(current_asid),
        .lsu_xlate_req_root_ppn_i(xlate_req_root_ppn),
        .lsu_xlate_req_sum_i(1'b0),
        .lsu_xlate_req_mxr_i(1'b0),
        .lsu_xlate_resp_valid_o(xlate_resp_valid),
        .lsu_xlate_resp_ready_i(xlate_resp_ready),
        .lsu_xlate_resp_tag_o(xlate_resp_tag),
        .lsu_xlate_resp_paddr_o(xlate_resp_paddr),
        .lsu_xlate_resp_access_fault_o(xlate_resp_access_fault),
        .lsu_xlate_resp_page_fault_o(xlate_resp_page_fault),
        .pmp_valid_o(pmp_valid), .pmp_addr_o(pmp_addr),
        .pmp_priv_o(pmp_priv), .pmp_size_o(pmp_size),
        .pmp_write_o(pmp_write), .pmp_exec_o(pmp_exec),
        .pmp_allow_i(pmp_allow),
        .icx_req_valid_o(icx_req_valid),
        .icx_req_ready_i(icx_req_ready),
        .icx_req_hart_id_o(icx_req_hart_id),
        .icx_req_txn_id_o(icx_req_txn_id),
        .icx_req_source_id_o(icx_req_source_id),
        .icx_req_op_o(icx_req_op),
        .icx_req_lock_o(icx_req_lock),
        .icx_req_order_o(icx_req_order),
        .icx_req_kind_o(icx_req_kind),
        .icx_req_attr_o(icx_req_attr),
        .icx_req_size_o(icx_req_size),
        .icx_req_addr_o(icx_req_addr),
        .icx_req_burst_len_o(icx_req_burst_len),
        .icx_wdata_valid_o(icx_wdata_valid),
        .icx_wdata_ready_i(icx_wdata_ready),
        .icx_wdata_hart_id_o(icx_wdata_hart_id),
        .icx_wdata_txn_id_o(icx_wdata_txn_id),
        .icx_wdata_source_id_o(icx_wdata_source_id),
        .icx_wdata_beat_index_o(icx_wdata_beat_index),
        .icx_wdata_last_o(icx_wdata_last),
        .icx_wdata_o(icx_wdata),
        .icx_wstrb_o(icx_wstrb),
        .icx_resp_valid_i(icx_resp_valid),
        .icx_resp_ready_o(icx_resp_ready),
        .icx_resp_hart_id_i(icx_resp_hart_id),
        .icx_resp_txn_id_i(icx_resp_txn_id),
        .icx_resp_source_id_i(icx_resp_source_id),
        .icx_resp_beat_index_i(icx_resp_beat_index),
        .icx_resp_last_i(icx_resp_last),
        .icx_resp_rdata_i(icx_resp_rdata),
        .icx_resp_error_i(icx_resp_error),
        .icx_resp_sc_success_i(1'b0),
        .m_axi_arid_o(arid), .m_axi_araddr_o(araddr),
        .m_axi_arlen_o(arlen), .m_axi_arsize_o(arsize),
        .m_axi_arburst_o(arburst), .m_axi_arlock_o(),
        .m_axi_arcache_o(), .m_axi_arprot_o(), .m_axi_arqos_o(),
        .m_axi_arvalid_o(arvalid), .m_axi_arready_i(arready),
        .m_axi_rid_i(rid), .m_axi_rdata_i(rdata),
        .m_axi_rresp_i(rresp), .m_axi_rlast_i(rlast),
        .m_axi_rvalid_i(rvalid), .m_axi_rready_o(rready),
        .m_axi_awid_o(awid), .m_axi_awaddr_o(awaddr),
        .m_axi_awlen_o(), .m_axi_awsize_o(awsize),
        .m_axi_awburst_o(), .m_axi_awlock_o(), .m_axi_awcache_o(),
        .m_axi_awprot_o(), .m_axi_awqos_o(),
        .m_axi_awvalid_o(awvalid), .m_axi_awready_i(awready),
        .m_axi_wdata_o(wdata), .m_axi_wstrb_o(wstrb),
        .m_axi_wlast_o(wlast), .m_axi_wvalid_o(wvalid),
        .m_axi_wready_i(wready), .m_axi_bid_i(bid),
        .m_axi_bresp_i(bresp), .m_axi_bvalid_i(bvalid),
        .m_axi_bready_o(bready)
    );

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (rst_n && arvalid && arready) begin
            seen_id[ar_count] <= arid;
            seen_addr[ar_count] <= araddr;
            ar_count <= ar_count + 1;
        end
    end

    assign icx_req_ready = rst_n && icx_allow_cmd &&
                           !icx_cmd_pending && !icx_resp_valid;
    assign icx_wdata_ready = rst_n && icx_allow_wdata &&
                              !icx_data_pending && !icx_resp_valid;

    function automatic [63:0] icx_memory_word(input [63:0] addr);
        icx_memory_word = icx_memory[addr[13:6]][addr[5:3]*64 +: 64];
    endfunction

    function automatic [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        icx_read_response(
            input [63:0] addr,
            input [2:0] size
        );
        begin
            if (size == 3'd6) begin
                icx_read_response = icx_memory[addr[13:6]];
            end else begin
                icx_read_response = 0;
                icx_read_response[addr[5:3]*64 +: 64] =
                    icx_memory_word(addr);
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            icx_cmd_pending <= 1'b0;
            icx_cmd_hart_id <= 4'd0;
            icx_cmd_txn_id <= 4'd0;
            icx_cmd_source_id <= 0;
            icx_cmd_op <= 0;
            icx_cmd_size <= 0;
            icx_cmd_addr <= 0;
            icx_data_pending <= 1'b0;
            icx_data_hart_id <= 0;
            icx_data_txn_id <= 0;
            icx_data_source_id <= 0;
            icx_data <= 0;
            icx_data_strb <= 0;
            icx_resp_valid <= 1'b0;
            icx_resp_hart_id <= 4'd0;
            icx_resp_txn_id <= 4'd0;
            icx_resp_source_id <= 0;
            icx_resp_beat_index <= 0;
            icx_resp_last <= 1'b0;
            icx_resp_rdata <= 0;
            icx_resp_error <= 1'b0;
            icx_reads <= 0;
            icx_writes <= 0;
            icx_fences <= 0;
            icx_locked_reads <= 0;
            icx_locked_writes <= 0;
        end else begin
            if (icx_resp_valid && icx_resp_ready)
                icx_resp_valid <= 1'b0;

            if (icx_req_valid && icx_req_ready) begin
                if (icx_req_hart_id != 0 || icx_req_burst_len != 0)
                    $fatal(1, "hart emitted malformed ICX command");
                if (icx_req_source_id == `OPENRV64_ICX_SOURCE_PTW) begin
                    if (icx_req_op == `OPENRV64_ICX_OP_FENCE) begin
                        if (icx_req_kind != `OPENRV64_ICX_KIND_PTE ||
                            icx_req_order !=
                                `OPENRV64_ICX_ORDER_ACQ_REL ||
                            icx_req_lock || (icx_req_size != 0) ||
                            (icx_req_addr != 0) ||
                            (icx_req_attr !=
                             `OPENRV64_ICX_ATTR_NONE))
                            $fatal(1,
                                   "PTW emitted malformed shootdown fence");
                        if ((dut.u_l1d.store_buffer_count_q != 0) ||
                            dut.u_l1d.store_completion_valid_q ||
                            (dut.u_l1d.backend_state_q != 0))
                            $fatal(1,
                                   "PTW shootdown passed an older L1D store");
                    end else if (
                        icx_req_kind != `OPENRV64_ICX_KIND_PTE ||
                        icx_req_op != `OPENRV64_ICX_OP_READ ||
                        icx_req_order != `OPENRV64_ICX_ORDER_NONE ||
                        icx_req_lock || icx_req_size != 3'd6 ||
                        icx_req_addr[5:0] != 0 ||
                        icx_req_attr !=
                            (`OPENRV64_ICX_ATTR_CACHEABLE |
                             `OPENRV64_ICX_ATTR_IDEMPOTENT)) begin
                        $fatal(1, "PTW emitted malformed PTE ICX command");
                    end
                end else begin
                    if (icx_req_source_id !=
                            `OPENRV64_ICX_SOURCE_DCACHE ||
                        icx_req_kind != `OPENRV64_ICX_KIND_DATA ||
                        icx_req_order != `OPENRV64_ICX_ORDER_NONE)
                        $fatal(1, "L1D emitted malformed ICX command");
                    if ((icx_req_attr ==
                         `OPENRV64_ICX_ATTR_CACHEABLE) &&
                        (icx_req_op == `OPENRV64_ICX_OP_READ) &&
                        ((icx_req_size != 3'd6) ||
                         (icx_req_addr[5:0] != 0)) &&
                        !((icx_req_size == 3'd3) &&
                          (icx_req_addr == 64'h108)))
                        $fatal(1,
                               "L1D read had invalid line/scalar geometry");
                    if ((icx_req_attr ==
                         `OPENRV64_ICX_ATTR_CACHEABLE) &&
                        (icx_req_op == `OPENRV64_ICX_OP_WRITE) &&
                        ((icx_req_size != 3'd6) ||
                         (icx_req_addr[5:0] != 0)) &&
                        !((icx_req_size == 3'd3) &&
                          ((icx_req_addr == 64'h108) ||
                           (icx_req_addr == 64'h118))))
                        $fatal(1,
                               "L1D write had invalid line/scalar geometry");
                end
                icx_cmd_pending <= 1'b1;
                icx_cmd_hart_id <= icx_req_hart_id;
                icx_cmd_txn_id <= icx_req_txn_id;
                icx_cmd_source_id <= icx_req_source_id;
                icx_cmd_op <= icx_req_op;
                icx_cmd_size <= icx_req_size;
                icx_cmd_addr <= icx_req_addr;
                if (icx_req_lock &&
                    (icx_req_op == `OPENRV64_ICX_OP_READ)) begin
                    if ((icx_req_addr != 64'h108) ||
                        (icx_req_size != 3'd3))
                        $fatal(1,
                               "locked L1D read lost sub-line geometry addr=%h size=%0d",
                               icx_req_addr, icx_req_size);
                    icx_locked_reads <= icx_locked_reads + 1;
                end
                if (icx_req_lock &&
                    (icx_req_op == `OPENRV64_ICX_OP_WRITE))
                    icx_locked_writes <= icx_locked_writes + 1;
            end

            if (icx_wdata_valid && icx_wdata_ready) begin
                if (icx_wdata_beat_index != 0 || !icx_wdata_last)
                    $fatal(1, "L1D emitted malformed write-data beat");
                icx_data_pending <= 1'b1;
                icx_data_hart_id <= icx_wdata_hart_id;
                icx_data_txn_id <= icx_wdata_txn_id;
                icx_data_source_id <= icx_wdata_source_id;
                icx_data <= icx_wdata;
                icx_data_strb <= icx_wstrb;
            end

            if (icx_cmd_pending && !icx_resp_valid &&
                ((icx_cmd_op == `OPENRV64_ICX_OP_READ) ||
                 (icx_cmd_op == `OPENRV64_ICX_OP_FENCE) ||
                 ((icx_cmd_op == `OPENRV64_ICX_OP_WRITE) &&
                  icx_data_pending))) begin
                if ((icx_cmd_op == `OPENRV64_ICX_OP_WRITE) &&
                    ((icx_data_hart_id != icx_cmd_hart_id) ||
                     (icx_data_txn_id != icx_cmd_txn_id) ||
                     (icx_data_source_id != icx_cmd_source_id)))
                    $fatal(1, "ICX command/data identity mismatch");
                icx_resp_valid <= 1'b1;
                icx_resp_hart_id <= icx_cmd_hart_id;
                icx_resp_txn_id <= icx_cmd_txn_id;
                icx_resp_source_id <= icx_cmd_source_id;
                icx_resp_beat_index <= 0;
                icx_resp_last <= 1'b1;
                icx_resp_rdata <= icx_read_response(
                    icx_cmd_addr, icx_cmd_size);
                icx_resp_error <= icx_fail_enable &&
                                  (icx_cmd_addr == icx_fail_addr);
                icx_cmd_pending <= 1'b0;
                if (icx_cmd_op == `OPENRV64_ICX_OP_READ) begin
                    icx_reads <= icx_reads + 1;
                end else if (icx_cmd_op ==
                             `OPENRV64_ICX_OP_WRITE) begin
                    icx_writes <= icx_writes + 1;
                    icx_data_pending <= 1'b0;
                    if (!(icx_fail_enable &&
                          (icx_cmd_addr == icx_fail_addr))) begin
                        for (icx_byte = 0; icx_byte < 64;
                             icx_byte = icx_byte + 1) begin
                            if (icx_data_strb[icx_byte])
                                icx_memory[icx_cmd_addr[13:6]]
                                    [8*icx_byte +: 8] <=
                                    icx_data[8*icx_byte +: 8];
                            end
                    end
                end else if (icx_cmd_op ==
                             `OPENRV64_ICX_OP_FENCE) begin
                    icx_fences <= icx_fences + 1;
                end else begin
                    $fatal(1, "unsupported ICX command in test memory");
                end
            end
        end
    end

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic expect_pipe_store_done(
        input [`OPENRV64_LSU_TAG_WIDTH-1:0] tag
    );
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!pipe_store_done_valid && wait_cycles < 300) begin
                tick();
                wait_cycles = wait_cycles + 1;
            end
            if (!pipe_store_done_valid)
                $fatal(1,
                    "tagged posted-store completion timeout tag=%0d", tag);
            if (pipe_store_done_tag != tag)
                $fatal(1,
                    "tagged posted-store completion mismatch tag=%0d got=%0d",
                    tag, pipe_store_done_tag);
            if (pipe_resp_valid && (pipe_resp_tag == tag))
                $fatal(1,
                    "posted store also appeared on normal response tag=%0d",
                    tag);
            tick();
            #1;
            if (pipe_store_done_valid && (pipe_store_done_tag == tag))
                $fatal(1,
                    "duplicate tagged posted-store completion tag=%0d", tag);
        end
    endtask

    task automatic push_fetch(input [63:0] addr);
        begin
            fetch_req_addr = addr;
            fetch_req_valid = 1'b1;
            while (!fetch_req_ready) tick();
            tick();
            fetch_req_valid = 1'b0;
        end
    endtask

    task automatic push_pipe_request(
        input [`OPENRV64_LSU_TAG_WIDTH-1:0] tag,
        input write,
        input [63:0] addr,
        input [63:0] write_data,
        input [7:0] write_strobe
    );
        integer wait_cycles;
        reg completed;
        begin
            pipe_req_tag = tag;
            pipe_req_write = write;
            pipe_req_addr = addr;
            pipe_req_wdata = write_data;
            pipe_req_wstrb = write_strobe;
            pipe_req_valid = 1'b1;
            wait_cycles = 0;
            completed = 1'b0;
            while (!completed && wait_cycles < 100) begin
                @(posedge clk);
                if (pipe_req_ready)
                    completed = 1'b1;
                #1;
                wait_cycles = wait_cycles + 1;
            end
            if (!completed)
                $fatal(1,
                    "tagged LSU request timeout tag=%0d ready=%b pmp=%b icx=%b/%b",
                    tag, pipe_req_ready, pmp_allow,
                    icx_req_valid, icx_req_ready);
            pipe_req_valid = 1'b0;
        end
    endtask

    task automatic push_xlate_request(
        input [`OPENRV64_LSU_TAG_WIDTH-1:0] tag,
        input write,
        input [63:0] vaddr
    );
        integer wait_cycles;
        reg completed;
        reg saved_resp_ready;
        begin
            // Hold the response while the task drives the request. Fast
            // micro/main-TLB hits may respond on the acceptance cycle.
            saved_resp_ready = xlate_resp_ready;
            xlate_resp_ready = 1'b0;
            xlate_req_tag = tag;
            xlate_req_write = write;
            xlate_req_vaddr = vaddr;
            xlate_req_valid = 1'b1;
            wait_cycles = 0;
            completed = 1'b0;
            while (!completed && wait_cycles < 100) begin
                @(posedge clk);
                if (xlate_req_ready)
                    completed = 1'b1;
                #1;
                wait_cycles = wait_cycles + 1;
            end
            if (!completed)
                $fatal(1,
                    "tagged translation request timeout tag=%0d lsu=%0d miss=%b dtlb_sel=%b dtlb_hit=%b l2_sel=%b l2_hit=%b pipe_fb=%b xlate_fb=%b",
                    tag, dut.lsu_state_q, dut.miss_active_q,
                    dut.dtlb_lookup_is_xlate, dut.dtlb_lookup_hit,
                    dut.l2_tlb_select_xlate, dut.l2_tlb_lookup_hit,
                    dut.pipe_fallback_active_q,
                    dut.xlate_fallback_active_q);
            xlate_req_valid = 1'b0;
            xlate_resp_ready = saved_resp_ready;
        end
    endtask

    task automatic expect_xlate_response(
        input [`OPENRV64_LSU_TAG_WIDTH-1:0] tag,
        input [63:0] expected_paddr,
        input expected_access_fault,
        input expected_page_fault
    );
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!xlate_resp_valid && wait_cycles < 300) begin
                tick();
                wait_cycles = wait_cycles + 1;
            end
            if (!xlate_resp_valid)
                $fatal(1, "tagged translation response timeout tag=%0d",
                       tag);
            if (xlate_resp_tag != tag ||
                xlate_resp_paddr != expected_paddr ||
                xlate_resp_access_fault != expected_access_fault ||
                xlate_resp_page_fault != expected_page_fault)
                $fatal(1,
                    "translation response mismatch tag=%0d/%0d paddr=%h/%h faults=%b/%b expected=%b/%b",
                    xlate_resp_tag, tag, xlate_resp_paddr, expected_paddr,
                    xlate_resp_access_fault, xlate_resp_page_fault,
                    expected_access_fault, expected_page_fault);
            tick();
        end
    endtask

    task automatic send_pipe_read_response(
        input [`OPENRV64_LSU_TAG_WIDTH-1:0] tag,
        input [255:0] response_data,
        input [63:0] expected_data
    );
        begin
            rid = {`OPENRV64_AXI_ID_WIDTH{1'b1}};
            rdata = response_data;
            rresp = 2'b00;
            rlast = 1'b1;
            rvalid = 1'b1;
            #1;
            if (!rready || !pipe_resp_valid || pipe_resp_tag != tag ||
                pipe_resp_rdata != expected_data ||
                pipe_resp_access_fault || pipe_resp_page_fault)
                $fatal(1,
                    "tagged response mismatch tag=%0d got_tag=%0d data=%h ready=%b",
                    tag, pipe_resp_tag, pipe_resp_rdata, rready);
            tick();
            rvalid = 1'b0;
        end
    endtask

    task automatic expect_pipe_response(
        input [`OPENRV64_LSU_TAG_WIDTH-1:0] tag,
        input [63:0] expected_data,
        input expected_access_fault,
        input expected_page_fault
    );
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!pipe_resp_valid && wait_cycles < 300) begin
                tick();
                wait_cycles = wait_cycles + 1;
            end
            if (!pipe_resp_valid)
                $fatal(1, "tagged L1D response timeout tag=%0d", tag);
            if (pipe_resp_tag != tag ||
                pipe_resp_rdata != expected_data ||
                pipe_resp_access_fault != expected_access_fault ||
                pipe_resp_page_fault != expected_page_fault)
                $fatal(1,
                    "tagged L1D response mismatch tag=%0d got=%0d data=%h expected=%h faults=%b/%b expected=%b/%b",
                    tag, pipe_resp_tag, pipe_resp_rdata, expected_data,
                    pipe_resp_access_fault, pipe_resp_page_fault,
                    expected_access_fault, expected_page_fault);
            tick();
        end
    endtask

    task automatic send_read_response(
        input [2:0] response_id,
        input [255:0] response_data,
        input [1:0] response_code
    );
        integer wait_cycles;
        reg completed;
        begin
            rid = response_id;
            rdata = response_data;
            rresp = response_code;
            rlast = 1'b1;
            rvalid = 1'b1;
            wait_cycles = 0;
            completed = 1'b0;
            while (!completed && wait_cycles < 30) begin
                @(posedge clk);
                if (rready)
                    completed = 1'b1;
                #1;
                wait_cycles = wait_cycles + 1;
            end
            if (!completed)
                $fatal(1,
                    "R channel timeout id=%0d fetch_count=%0d",
                    response_id, dut.fetch_count_q);
            rvalid = 1'b0;
        end
    endtask

    task automatic expect_fetch(
        input [63:0] addr,
        input [255:0] data,
        input access_fault,
        input stash,
        input demand
    );
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!fetch_resp_valid && wait_cycles < 30) begin
                tick();
                wait_cycles = wait_cycles + 1;
            end
            if (!fetch_resp_valid)
                $fatal(1, "fetch response timeout count=%0d head=%0d",
                    dut.fetch_count_q, dut.fetch_head_q);
            if (fetch_resp_addr != addr || fetch_resp_data != data ||
                fetch_resp_access_fault != access_fault ||
                fetch_resp_page_fault ||
                fetch_resp_stash != stash ||
                fetch_resp_demand != demand)
                $fatal(1,
                       "fetch response mismatch addr=%h data=%h fault=%b stash=%b demand=%b",
                       fetch_resp_addr, fetch_resp_data,
                       fetch_resp_access_fault, fetch_resp_stash,
                       fetch_resp_demand);
            tick();
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        fetch_req_valid = 0;
        fetch_req_addr = 0;
        fetch_req_stash = 0;
        fetch_req_demand = 1;
        fetch_req_priv = `RV64_PRIV_M;
        fetch_req_vm_mode = `RV64_SATP_MODE_BARE;
        fetch_req_root_ppn = 0;
        fetch_cancel = 0;
        fetch_resp_ready = 1;
        lsu_valid = 0;
        lsu_write = 0;
        lsu_addr = 0;
        lsu_wdata = 0;
        lsu_wstrb = 0;
        lsu_size = 3;
        pipe_req_valid = 0;
        pipe_req_lock = 0;
        pipe_req_xlate_only = 0;
        pipe_req_physical = 0;
        pipe_req_tag = 0;
        pipe_req_write = 0;
        pipe_req_addr = 0;
        pipe_req_wdata = 0;
        pipe_req_wstrb = 0;
        pipe_req_size = 3;
        pipe_req_priv = `RV64_PRIV_M;
        pipe_req_vm_mode = `RV64_SATP_MODE_BARE;
        pipe_req_root_ppn = 0;
        pipe_cancel = 0;
        tlbi = 0;
        context_flush = 0;
        current_asid = 0;
        pipe_resp_ready = 1;
        pipe_store_done_ready = 1;
        xlate_req_valid = 0;
        xlate_req_tag = 0;
        xlate_req_write = 0;
        xlate_req_vaddr = 0;
        xlate_req_priv = `RV64_PRIV_M;
        xlate_req_vm_mode = `RV64_SATP_MODE_BARE;
        xlate_req_root_ppn = 0;
        xlate_resp_ready = 1;
        pmp_allow = 1;
        arready = 1;
        rid = 0;
        rdata = 0;
        rresp = 0;
        rlast = 1;
        rvalid = 0;
        awready = 1;
        wready = 1;
        bid = 3'b111;
        bresp = 0;
        bvalid = 0;
        icx_resp_valid = 0;
        icx_resp_hart_id = 0;
        icx_resp_txn_id = 0;
        icx_resp_source_id = 0;
        icx_resp_beat_index = 0;
        icx_resp_last = 0;
        icx_resp_rdata = 0;
        icx_resp_error = 0;
        icx_fail_enable = 0;
        icx_fail_addr = 0;
        icx_allow_cmd = 1;
        icx_allow_wdata = 1;
        icache_age_valid = 3'b000;
        icache_age_addr = 192'd0;
        for (icx_index = 0; icx_index < 256;
             icx_index = icx_index + 1) begin
            for (icx_word_index = 0; icx_word_index < 8;
                 icx_word_index = icx_word_index + 1)
                icx_memory[icx_index][icx_word_index*64 +: 64] =
                    64'h0101_0101_0101_0101 *
                    (icx_index * 8 + icx_word_index);
        end
        ar_count = 0;
        repeat (3) tick();
        rst_n = 1;
        tick();

        // A client may withdraw speculative work after arbitration but
        // before the downstream ICX handshake.  The saved grant must not
        // block a different client indefinitely.
        icx_allow_cmd = 0;
        force dut.l1d_icx_req_valid = 1'b1;
        tick();
        if (!dut.icx_cmd_grant_valid_q ||
            (dut.icx_cmd_grant_client_q != 2'd1))
            $fatal(1, "ICX cancellation test did not grant L1D");
        force dut.l1d_icx_req_valid = 1'b0;
        force dut.l1i_icx_req_valid = 1'b1;
        tick();
        if (!dut.icx_cmd_grant_valid_q ||
            (dut.icx_cmd_grant_client_q != 2'd0))
            $fatal(1,
                "ICX arbiter retained a withdrawn client grant valid=%b client=%0d",
                dut.icx_cmd_grant_valid_q,
                dut.icx_cmd_grant_client_q);
        force dut.l1i_icx_req_valid = 1'b0;
        tick();
        if (dut.icx_cmd_grant_valid_q)
            $fatal(1, "ICX arbiter retained final withdrawn grant");
        release dut.l1d_icx_req_valid;
        release dut.l1i_icx_req_valid;
        icx_allow_cmd = 1;

        // Four fetches enter before any response.  AXI may return them out of
        // order, while the frontend must still observe request order.
        fetch_resp_ready = 0;
        push_fetch(64'h0000);
        push_fetch(64'h0020);
        push_fetch(64'h0040);
        push_fetch(64'h0060);
        send_read_response(3'd2, 256'h3333, 2'b00);
        send_read_response(3'd0, 256'h1111, 2'b00);
        send_read_response(3'd3, 256'h4444, 2'b00);
        send_read_response(3'd1, 256'h2222, 2'b00);
        fetch_resp_ready = 1;
        expect_fetch(64'h0, 256'h1111, 0, 0, 1);
        expect_fetch(64'h20, 256'h2222, 0, 0, 1);
        expect_fetch(64'h40, 256'h3333, 0, 0, 1);
        expect_fetch(64'h60, 256'h4444, 0, 0, 1);
        if (ar_count != 4)
            $fatal(1, "expected four sequential AR requests, got %0d", ar_count);
        if (seen_addr[0] != 64'h0 || seen_addr[1] != 64'h20 ||
            seen_addr[2] != 64'h40 || seen_addr[3] != 64'h60 ||
            seen_id[0] != 0 || seen_id[1] != 1 ||
            seen_id[2] != 2 || seen_id[3] != 3)
            $fatal(1, "fetch AR address/ID sequence mismatch");
        if (arlen != 0 || arburst != 2'b01)
            $fatal(1, "AXI read must be a one-beat INCR transaction");

        // PMP denial terminates locally and never launches AR.
        pmp_allow = 0;
        fetch_resp_ready = 0;
        push_fetch(64'h0080);
        repeat (2) tick();
        if (ar_count != 4 || !fetch_resp_valid ||
            !fetch_resp_access_fault || fetch_resp_addr != 64'h80)
            $fatal(1, "fetch PMP denial did not become a local fault");
        tick();
        fetch_resp_ready = 1;
        pmp_allow = 1;

        // A branch alternate can also be the next sequential line.  Such a
        // request is both stash and architectural demand; retirement aging
        // may discard a stash-only transaction but must preserve this one.
        fetch_req_stash = 1;
        fetch_req_demand = 1;
        push_fetch(64'h00c0);
        while (ar_count != 5) tick();
        icache_age_addr[0*64 +: 64] = 64'h00c0;
        icache_age_valid = 3'b001;
        tick();
        icache_age_valid = 3'b000;
        send_read_response(seen_id[4], 256'h5555, 2'b00);
        expect_fetch(64'h00c0, 256'h5555, 0, 1, 1);
        fetch_req_stash = 0;
        if ($test$plusargs("fetch_stash_aging_only")) begin
            $display("PASS: ICX preserves aged stash+demand fetch");
            $finish;
        end

        // A miss is one native 512-bit ICX line read.  A second word in that
        // line is a local hit; scalar data must not leak onto AXI.
        wait_count = icx_reads;
        locked_old_word = icx_memory_word(64'h100);
        push_pipe_request(2'd0, 1'b0, 64'h100, 64'd0, 8'd0);
        expect_pipe_response(2'd0, locked_old_word, 1'b0, 1'b0);
        if ((icx_reads - wait_count) != 1)
            $fatal(1, "L1D miss used %0d ICX reads instead of 1",
                   icx_reads - wait_count);

        wait_count = icx_reads;
        locked_old_word = icx_memory_word(64'h108);
        push_pipe_request(2'd1, 1'b0, 64'h108, 64'd0, 8'd0);
        expect_pipe_response(2'd1, locked_old_word, 1'b0, 1'b0);
        if (icx_reads != wait_count)
            $fatal(1, "L1D hit unexpectedly reached ICX");
        if (ar_count != 5 || awvalid || wvalid)
            $fatal(1, "scalar LSU traffic leaked onto AXI");

        // A bring-up AMO phase must bypass and invalidate a resident L1D
        // line while retaining cacheable PMA attributes at ICX.
        wait_count = icx_reads;
        icx_allow_cmd = 1'b0;
        pipe_req_lock = 1'b1;
        locked_old_word = icx_memory_word(64'h108);
        push_pipe_request(2'd2, 1'b0, 64'h108, 64'd0, 8'd0);
        pipe_req_lock = 1'b0;
        while (!icx_req_valid) tick();
        pipe_cancel = 1'b1;
        tick();
        pipe_cancel = 1'b0;
        if (!icx_req_valid || icx_req_lock)
            $fatal(1,
                "redirect cancelled AMO read or leaked its marker to ICX");
        icx_allow_cmd = 1'b1;
        expect_pipe_response(2'd2, locked_old_word, 1'b0, 1'b0);
        if ((icx_reads - wait_count) != 1 || icx_locked_reads != 0)
            $fatal(1,
                "atomic L1D read did not bypass L1 or leaked a ICX lock");

        wait_count = icx_reads;
        locked_old_word = icx_memory_word(64'h108);
        push_pipe_request(2'd0, 1'b0, 64'h108, 64'd0, 8'd0);
        expect_pipe_response(2'd0, locked_old_word, 1'b0, 1'b0);
        if ((icx_reads - wait_count) != 1)
            $fatal(1, "locked L1D access did not invalidate resident line");

        wait_count = icx_writes;
        locked_old_word = icx_memory_word(64'h118);
        pipe_req_lock = 1'b1;
        push_pipe_request(2'd2, 1'b1, 64'h118,
                          64'hcafe_babe_dead_beef, 8'hff);
        pipe_req_lock = 1'b0;
        expect_pipe_response(2'd2, locked_old_word, 1'b0, 1'b0);
        if ((icx_writes - wait_count) != 1 || icx_locked_writes != 0)
            $fatal(1, "atomic L1D write leaked a ICX lock");

        // A tagged store is irrevocable after L1 admission.  Architectural
        // completion reports that admission, not the later ICX drain result.
        // Deferred write faults therefore cannot be attributed to the posted
        // LSU tag and are intentionally not returned on this interface.
        locked_old_word = icx_memory_word(64'h180);
        push_pipe_request(2'd0, 1'b0, 64'h180, 64'd0, 8'd0);
        expect_pipe_response(2'd0, locked_old_word, 1'b0, 1'b0);
        pipe_store_done_ready = 0;
        icx_fail_enable = 1;
        icx_fail_addr = 64'h100;
        icx_allow_cmd = 0;
        icx_allow_wdata = 1;
        wait_count = icx_writes;
        push_pipe_request(2'd1, 1'b1, 64'h114,
            64'haabb_ccdd_0000_0000, 8'hf0);
        channel_wait = 0;
        while (!pipe_store_done_valid && channel_wait < 20) begin
            tick();
            channel_wait = channel_wait + 1;
        end
        if (!pipe_store_done_valid || pipe_store_done_tag != 2'd1)
            $fatal(1,
                "held posted-store completion setup failed valid=%b tag=%0d",
                pipe_store_done_valid, pipe_store_done_tag);
        // Keep the independent store response backpressured while a resident
        // load completes through the normal response path.
        locked_old_word = icx_memory_word(64'h180);
        push_pipe_request(2'd0, 1'b0, 64'h180, 64'd0, 8'd0);
        expect_pipe_response(2'd0, locked_old_word, 1'b0, 1'b0);
        if (!pipe_store_done_valid || pipe_store_done_tag != 2'd1)
            $fatal(1,
                "load displaced held posted-store completion valid=%b tag=%0d",
                pipe_store_done_valid, pipe_store_done_tag);
        channel_wait = 0;
        // A lone posted store may remain coalescible until the default
        // 1024-cycle L1D store-buffer timeout.  This test is about independent
        // ICX command/data backpressure, so wait through that policy interval
        // instead of assuming an immediate drain.
        while (!icx_data_pending && channel_wait < 1200) begin
            tick();
            channel_wait = channel_wait + 1;
        end
        if (!icx_data_pending)
            $fatal(1,
                "ICX write data did not advance independently lsu=%0d l1count=%0d valid=%b complete=%b l1backend=%0d l1mem=%b/%b icx=%b/%b wdata=%b/%b",
                dut.lsu_state_q, dut.u_l1d.store_buffer_count_q,
                dut.u_l1d.store_buffer_valid_q[
                    dut.u_l1d.store_buffer_head_q],
                dut.u_l1d.store_completion_valid_q,
                dut.u_l1d.backend_state_q, dut.u_l1d.l1_mem_valid,
                dut.u_l1d.l1_mem_write, icx_req_valid, icx_req_ready,
                icx_wdata_valid, icx_wdata_ready);
        if (!icx_req_valid)
            $fatal(1, "ICX command was not held after write data accepted");
        pipe_cancel = 1'b1;
        tick();
        pipe_cancel = 1'b0;
        while (!pipe_store_done_valid)
            tick();
        if (pipe_store_done_tag != 2'd1)
            $fatal(1, "posted store admission response changed across cancel");
        pipe_store_done_ready = 1;
        tick();
        icx_allow_cmd = 1;
        while ((icx_writes - wait_count) != 1)
            tick();
        if ((icx_writes - wait_count) != 1 || awvalid || wvalid)
            $fatal(1, "L1D store did not use exactly one ICX write");
        icx_fail_enable = 0;

        // Stores complete architecturally at bus admission, then queue as
        // aligned 64-byte records with byte enables.  These eight writes
        // cover one line and must coalesce into one stalled buffer entry.
        icx_memory[6'h0c] = 512'd0;
        wait_count = icx_writes;
        icx_allow_cmd = 0;
        icx_allow_wdata = 1;
        push_pipe_request(2'd0, 1'b1, 64'h300,
                          64'h1122_3344_5566_7788, 8'h0f);
        expect_pipe_store_done(2'd0);
        push_pipe_request(2'd1, 1'b1, 64'h308,
                          64'haabb_ccdd_eeff_0011, 8'hf0);
        expect_pipe_store_done(2'd1);
        push_pipe_request(2'd2, 1'b1, 64'h310,
                          64'h0123_4567_89ab_cdef, 8'h81);
        expect_pipe_store_done(2'd2);
        push_pipe_request(3'd3, 1'b1, 64'h318,
                          64'h1020_3040_5060_7080, 8'hff);
        expect_pipe_store_done(3'd3);
        push_pipe_request(3'd4, 1'b1, 64'h320,
                          64'hfedc_ba98_7654_3210, 8'h33);
        expect_pipe_store_done(3'd4);
        push_pipe_request(3'd5, 1'b1, 64'h328,
                          64'h0f1e_2d3c_4b5a_6978, 8'hcc);
        expect_pipe_store_done(3'd5);
        push_pipe_request(3'd6, 1'b1, 64'h330,
                          64'h8877_6655_4433_2211, 8'h55);
        expect_pipe_store_done(3'd6);
        push_pipe_request(3'd7, 1'b1, 64'h338,
                          64'h99aa_bbcc_ddee_ff00, 8'haa);
        expect_pipe_store_done(3'd7);
        channel_wait = 0;
        while ((dut.u_l1d.store_buffer_count_q != 1) &&
               channel_wait < 150) begin
            tick();
            channel_wait = channel_wait + 1;
        end
        if (dut.u_l1d.store_buffer_count_q != 1)
            $fatal(1, "L1D did not coalesce one line of stalled stores data=%0d",
                   dut.u_l1d.store_buffer_count_q);

        // The marked read is the first half of the serialized single-hart AMO
        // sequence.  It must remain outside L1D until every older posted store
        // has reached ICX.  The marker is deliberately not forwarded as a
        // shared-home lock.
        locked_reads_before = icx_reads;
        pipe_req_lock = 1'b1;
        push_pipe_request(3'd0, 1'b0, 64'h108, 64'd0, 8'd0);
        pipe_req_lock = 1'b0;
        if (icx_reads != locked_reads_before)
            $fatal(1, "atomic read reached ICX ahead of buffered stores");
        icx_allow_cmd = 1;
        channel_wait = 0;
        while ((icx_reads == locked_reads_before) &&
               (channel_wait < 300)) begin
            tick();
            channel_wait = channel_wait + 1;
        end
        if (icx_reads == locked_reads_before)
            $fatal(1, "atomic read did not force store-buffer drain");
        if ((icx_writes - wait_count) != 1)
            $fatal(1, "atomic read admitted before coalesced store reached ICX");
        locked_old_word = icx_memory_word(64'h108);
        expect_pipe_response(3'd0, locked_old_word, 1'b0, 1'b0);
        if (icx_reads != locked_reads_before + 1 ||
            icx_locked_reads != 0)
            $fatal(1, "post-drain atomic read leaked a ICX lock");
        if ((icx_writes - wait_count) != 1 ||
            icx_memory_word(64'h300) != 64'h0000_0000_5566_7788 ||
            icx_memory_word(64'h308) != 64'haabb_ccdd_0000_0000 ||
            icx_memory_word(64'h310) != 64'h0100_0000_0000_00ef ||
            icx_memory_word(64'h318) != 64'h1020_3040_5060_7080 ||
            icx_memory_word(64'h320) != 64'h0000_ba98_0000_3210 ||
            icx_memory_word(64'h328) != 64'h0f1e_0000_4b5a_0000 ||
            icx_memory_word(64'h330) != 64'h0077_0055_0033_0011 ||
            icx_memory_word(64'h338) != 64'h9900_bb00_dd00_ff00)
            $fatal(1, "L1D byte-masked store coalescing/drain mismatch");

        // Complete the serialized atomic read/write pair before issuing
        // unrelated traffic.  Single-hart mode intentionally does not acquire
        // a ICX/L2 home lock.
        wait_count = icx_writes;
        pipe_req_lock = 1'b1;
        push_pipe_request(3'd1, 1'b1, 64'h108, locked_old_word, 8'hff);
        pipe_req_lock = 1'b0;
        expect_pipe_response(3'd1, locked_old_word, 1'b0, 1'b0);
        if (icx_writes != wait_count + 1 || icx_locked_writes != 0)
            $fatal(1, "post-drain atomic write leaked a ICX lock");

        // SFENCE.VMA/SATP share a full translation barrier. A partial posted
        // PTE store must reach ICX and receive its write response before the
        // PTW may issue the ordered shootdown fence.
        wait_count = icx_writes;
        fences_before = icx_fences;
        icx_allow_cmd = 1'b0;
        push_pipe_request(3'd2, 1'b1, 64'h388,
                          64'h0000_0000_23ff_fce7, 8'hff);
        expect_pipe_store_done(3'd2);
        if (dut.u_l1d.store_buffer_count_q != 1)
            $fatal(1, "translation-barrier setup store was not buffered");
        tlbi = 1'b1;
        #1;
        if (!tlbi_busy)
            $fatal(1, "translation barrier was not immediate");
        tick();
        tlbi = 1'b0;
        repeat (3) tick();
        if ((icx_writes != wait_count) ||
            (icx_fences != fences_before) || !tlbi_busy)
            $fatal(1, "translation barrier escaped blocked PTE store");
        icx_allow_cmd = 1'b1;
        channel_wait = 0;
        while (tlbi_busy && (channel_wait < 300)) begin
            tick();
            channel_wait = channel_wait + 1;
        end
        if (tlbi_busy || (icx_writes != wait_count + 1) ||
            (icx_fences != fences_before + 1) ||
            (icx_memory_word(64'h388) != 64'h0000_0000_23ff_fce7))
            $fatal(1,
                   "translation barrier did not order store then shootdown");

        // Translation-only tagged traffic uses a cacheable PTE line read on
        // ICX and returns the page fault under the original request tag.  It
        // must not perform an L1D access.  An invalid root PTE is sufficient to
        // exercise the fallback without a full map.
        xlate_req_vm_mode = `RV64_SATP_MODE_SV39;
        xlate_req_priv = `RV64_PRIV_S;
        xlate_resp_ready = 0;
        wait_count = icx_reads;
        channel_wait = ar_count;
        push_xlate_request(2'd2, 1'b0, 64'h1000);
        ptw_wait = 0;
        while (!xlate_resp_valid && ptw_wait < 50) begin
            tick();
            ptw_wait = ptw_wait + 1;
        end
        if (ptw_wait == 50)
            $fatal(1,
                   "translated PTE ICX response timeout lsu=%0d miss=%b req=%b resp=%b",
                   dut.lsu_state_q, dut.miss_active_q,
                   dut.u_ptw.state_q,
                   dut.u_ptw.backend_state_q);
        if (xlate_resp_tag != 2'd2 || !xlate_resp_page_fault ||
            xlate_resp_access_fault)
            $fatal(1, "translated tagged LSU fallback mismatch");
        if ((icx_reads - wait_count) != 1 ||
            ar_count != channel_wait)
            $fatal(1,
                   "translated PTW did not use exactly one ICX PTE line");
        xlate_resp_ready = 1;
        tick();

        // Walk a complete three-level mapping.  Each dependent PTE fetch is a
        // line read on ICX, with the walker selecting its original 64-bit
        // lane, followed by one data-cache line read at the translated PA.
        icx_memory[64'h0000 >> 6][0*64 +: 64] = 64'h0000_0000_0000_0401;
        icx_memory[64'h1000 >> 6][0*64 +: 64] = 64'h0000_0000_0000_0801;
        icx_memory[64'h2000 >> 6][4*64 +: 64] = 64'h0000_0000_0000_0ccf;
        icx_memory[64'h3000 >> 6][0*64 +: 64] = 64'h5a17_c0de_cafe_1234;
        icx_memory[64'h3000 >> 6][1*64 +: 64] = 64'h1357_9bdf_2468_ace0;

        // A redirect on the exact edge of a successful PTW response must win.
        // Otherwise the old cancelled bit lets the slot re-enter TRANSLATE,
        // where the translation selector can never consume it.
        fetch_req_priv = `RV64_PRIV_S;
        fetch_req_vm_mode = `RV64_SATP_MODE_SV39;
        fetch_req_root_ppn = 0;
        fetch_req_stash = 0;
        fetch_req_demand = 1;
        channel_wait = ar_count;
        push_fetch(64'h4000);
        ptw_wait = 0;
        while (!dut.ptw_resp_valid && ptw_wait < 100) begin
            tick();
            ptw_wait = ptw_wait + 1;
        end
        if (!dut.ptw_resp_valid || !dut.miss_active_q ||
            (dut.miss_owner_q != 0))
            $fatal(1, "fetch PTW/cancel race setup did not reach response");
        cancel_fetch_slot = dut.miss_fetch_slot_q;
        fetch_cancel = 1'b1;
        tick();
        fetch_cancel = 1'b0;
        if (!dut.fetch_cancelled_q[cancel_fetch_slot] ||
            (dut.fetch_state_q[cancel_fetch_slot] != 4))
            $fatal(1,
                "same-cycle cancellation lost to PTW completion state=%0d cancelled=%b",
                dut.fetch_state_q[cancel_fetch_slot],
                dut.fetch_cancelled_q[cancel_fetch_slot]);
        tick();
        if (dut.fetch_count_q != 0 || fetch_resp_valid ||
            (ar_count != channel_wait))
            $fatal(1,
                "cancelled translated fetch was not dropped locally count=%0d response=%b ar_delta=%0d",
                dut.fetch_count_q, fetch_resp_valid,
                ar_count - channel_wait);
        // Keep the following walk-count test independent of the non-leaf PTEs
        // cached by this fetch walk.
        tlbi = 1'b1;
        tick();
        tlbi = 1'b0;
        while (tlbi_busy) tick();
        fetch_req_priv = `RV64_PRIV_M;
        fetch_req_vm_mode = `RV64_SATP_MODE_BARE;

        wait_count = icx_reads;
        channel_wait = ar_count;
        push_xlate_request(3'd3, 1'b0, 64'h4000);
        expect_xlate_response(3'd3, 64'h3000, 1'b0, 1'b0);
        pipe_req_physical = 1'b1;
        push_pipe_request(3'd3, 1'b0, 64'h3000, 64'd0, 8'd0);
        expect_pipe_response(3'd3, 64'h5a17_c0de_cafe_1234,
                             1'b0, 1'b0);
        if ((icx_reads - wait_count) != 4)
            $fatal(1,
                   "three-level walk plus translated load used %0d ICX reads",
                   icx_reads - wait_count);
        if (ar_count != channel_wait)
            $fatal(1, "translated PTW or L1D request escaped onto AXI");

        /*
         * SATP selects a new current address space. It must flush the untagged
         * micro-TLBs and cancel old walk state, but an ASID-tagged L2 entry
         * must survive switches away from and back to its ASID.
         */
        current_asid = 16'h0001;
        context_flush = 1'b1;
        #1;
        if (!dut.micro_tlbi)
            $fatal(1, "SATP context flush did not reach micro-TLBs");
        tick();
        context_flush = 1'b0;
        while (tlbi_busy)
            tick();
        if ((|dut.u_itlb.valid_q) || (|dut.u_dtlb.valid_q))
            $fatal(1, "SATP context flush did not clear micro-TLBs");

        current_asid = 16'h0000;
        context_flush = 1'b1;
        tick();
        context_flush = 1'b0;
        while (tlbi_busy)
            tick();
        wait_count = icx_reads;
        fences_before = l2_tlb_hits;
        push_xlate_request(3'd4, 1'b0, 64'h4008);
        expect_xlate_response(3'd4, 64'h3008, 1'b0, 1'b0);
        if ((l2_tlb_hits != fences_before + 1) ||
            (icx_reads != wait_count))
            $fatal(1,
                "SATP switch lost tagged L2 entry hits=%0d reads=%0d",
                l2_tlb_hits - fences_before, icx_reads - wait_count);

        // Model independent micro-ITLB/DTLB capacity evictions while retaining
        // the shared L2 entry. Present I-side and D-side misses together:
        // LSU wins the first indexed lookup, fetch wins the next, and neither
        // request may start another page walk.  L2 replacement is deliberately
        // independent of micro replacement.
        @(negedge clk);
        dut.u_itlb.valid_q = 0;
        dut.u_dtlb.valid_q = 0;
        fetch_req_priv = `RV64_PRIV_S;
        fetch_req_vm_mode = `RV64_SATP_MODE_SV39;
        fetch_req_root_ppn = 0;
        fetch_req_stash = 0;
        fetch_req_demand = 1;
        fetch_req_addr = 64'h4000;
        fetch_resp_ready = 0;
        xlate_resp_ready = 0;
        xlate_req_tag = 3'd4;
        xlate_req_write = 0;
        xlate_req_vaddr = 64'h4008;
        fetch_req_valid = 1;
        xlate_req_valid = 1;
        #1;
        if (!fetch_req_ready || !xlate_req_ready)
            $fatal(1, "simultaneous L2 TLB test requests not accepted");
        if (!dut.l2_tlb_select_xlate || !dut.l2_tlb_lookup_hit)
            $fatal(1, "shared L2 TLB did not fast-path live LSU lookup");
        wait_count = l2_tlb_hits;
        channel_wait = ar_count;
        locked_reads_before = icx_reads;
        tick();
        fetch_req_valid = 0;
        xlate_req_valid = 0;
        #1;
        if (!dut.l2_tlb_select_fetch || !dut.l2_tlb_lookup_hit)
            $fatal(1, "shared L2 TLB lost waiting fetch lookup");
        tick();
        ptw_wait = 0;
        while ((ar_count == channel_wait) && (ptw_wait < 30)) begin
            tick();
            ptw_wait = ptw_wait + 1;
        end
        if (ar_count != channel_wait + 1)
            $fatal(1, "translated L2-hit fetch did not launch one AXI read");
        send_read_response(seen_id[channel_wait], 256'h1234, 2'b00);
        xlate_resp_ready = 1;
        expect_xlate_response(3'd4, 64'h3008, 1'b0, 1'b0);
        push_pipe_request(3'd4, 1'b0, 64'h3008, 64'd0, 8'd0);
        expect_pipe_response(3'd4, 64'h1357_9bdf_2468_ace0,
                             1'b0, 1'b0);
        fetch_resp_ready = 1;
        expect_fetch(64'h4000, 256'h1234, 1'b0, 1'b0, 1'b1);
        if ((l2_tlb_hits - wait_count) != 2 ||
            (icx_reads != locked_reads_before))
            $fatal(1,
                "shared L2 TLB arbitration hit/walk mismatch hits=%0d icx_reads=%0d",
                l2_tlb_hits - wait_count,
                icx_reads - locked_reads_before);
        fetch_req_priv = `RV64_PRIV_M;
        fetch_req_vm_mode = `RV64_SATP_MODE_BARE;

        // An L2-hit store translation completes locally with its physical
        // address and refills the L1 DTLB.  A second store translation then
        // consumes that L1 hit on the immediately following cycle.  Neither
        // translation-only admission may read or write L1D, consume ICX, or
        // enter the serial LSU slot.
        @(negedge clk);
        dut.u_dtlb.valid_q = 0;
        wait_count = icx_reads;
        channel_wait = icx_writes;
        locked_reads_before = dut.u_l1d.store_buffer_count_q;
        fences_before = l2_tlb_hits;
        xlate_resp_ready = 1'b1;
        xlate_req_tag = 3'd5;
        xlate_req_write = 1'b1;
        xlate_req_vaddr = 64'h4010;
        xlate_req_valid = 1'b1;
        #1;
        if (!xlate_req_ready || !dut.xlate_l2_hit)
            $fatal(1, "L2-hit store translation did not fast-path");
        tick();
        if (!xlate_resp_valid || xlate_resp_tag != 3'd5 ||
            xlate_resp_paddr != 64'h3010 ||
            xlate_resp_access_fault || xlate_resp_page_fault)
            $fatal(1,
                "L2-hit translation-only response mismatch tag=%0d paddr=%h faults=%b/%b",
                xlate_resp_tag, xlate_resp_paddr,
                xlate_resp_access_fault, xlate_resp_page_fault);
        xlate_req_tag = 3'd6;
        xlate_req_vaddr = 64'h4018;
        #1;
        if (!xlate_req_ready || !dut.xlate_l1_hit)
            $fatal(1,
                   "L1-hit store translation did not accept behind response");
        tick();
        xlate_req_valid = 1'b0;
        if (!xlate_resp_valid || xlate_resp_tag != 3'd6 ||
            xlate_resp_paddr != 64'h3018 ||
            xlate_resp_access_fault || xlate_resp_page_fault)
            $fatal(1,
                "L1-hit translation-only response mismatch tag=%0d paddr=%h faults=%b/%b",
                xlate_resp_tag, xlate_resp_paddr,
                xlate_resp_access_fault, xlate_resp_page_fault);
        tick();
        if (icx_reads != wait_count || icx_writes != channel_wait ||
            dut.u_l1d.store_buffer_count_q != locked_reads_before ||
            dut.lsu_state_q != 0 ||
            (l2_tlb_hits - fences_before) != 1)
            $fatal(1,
                "translation-only stores serialized or touched memory l2_hits=%0d state=%0d",
                l2_tlb_hits - fences_before, dut.lsu_state_q);

        // The completed walk populated DTLB and L1D state.  Hold an unrelated
        // instruction walk at ICX, then require translated load and store hits
        // to pass it through the native tagged path without consuming the
        // serial LSU slot.  The following load also proves that dirty-store
        // overlay remains visible before the posted store can drain.
        icx_memory[64'h2040 >> 6][0*64 +: 64] = 64'd0;
        fetch_req_priv = `RV64_PRIV_S;
        fetch_req_vm_mode = `RV64_SATP_MODE_SV39;
        fetch_req_root_ppn = 0;
        fetch_resp_ready = 0;
        icx_allow_cmd = 0;
        push_fetch(64'h8000);
        ptw_wait = 0;
        while ((!dut.miss_active_q || (dut.miss_owner_q != 0)) &&
               ptw_wait < 50) begin
            tick();
            ptw_wait = ptw_wait + 1;
        end
        if (!dut.miss_active_q || (dut.miss_owner_q != 0))
            $fatal(1, "translated fast-hit test did not hold fetch PTW");

        // Evict the L1 DTLB entry while the unrelated fetch walk remains
        // active.  The first load must consume the retained L2 hit directly;
        // it may not wait for the walker.
        @(negedge clk);
        dut.u_dtlb.valid_q = 0;
        wait_count = translated_fast_fires;
        channel_wait = translated_fast_store_fires;
        fences_before = l2_tlb_hits;
        push_xlate_request(3'd4, 1'b0, 64'h4008);
        expect_xlate_response(3'd4, 64'h3008, 1'b0, 1'b0);
        push_pipe_request(3'd4, 1'b0, 64'h3008, 64'd0, 8'd0);
        expect_pipe_response(3'd4, 64'h1357_9bdf_2468_ace0,
                             1'b0, 1'b0);
        push_xlate_request(3'd5, 1'b1, 64'h4010);
        expect_xlate_response(3'd5, 64'h3010, 1'b0, 1'b0);
        push_pipe_request(3'd5, 1'b1, 64'h3010,
                          64'hdeaf_beef_cafe_f00d, 8'hff);
        expect_pipe_store_done(3'd5);
        push_xlate_request(3'd6, 1'b0, 64'h4010);
        expect_xlate_response(3'd6, 64'h3010, 1'b0, 1'b0);
        push_pipe_request(3'd6, 1'b0, 64'h3010, 64'd0, 8'd0);
        expect_pipe_response(3'd6, 64'hdeaf_beef_cafe_f00d,
                             1'b0, 1'b0);
        if ((translated_fast_fires - wait_count) != 3 ||
            (translated_fast_store_fires - channel_wait) != 1 ||
            (l2_tlb_hits - fences_before) != 1 ||
            !dut.miss_active_q)
            $fatal(1,
                "L1/L2 DTLB hits did not pass active PTW fast=%0d stores=%0d l2=%0d miss=%b state=%0d",
                translated_fast_fires - wait_count,
                translated_fast_store_fires - channel_wait,
                l2_tlb_hits - fences_before,
                dut.miss_active_q, dut.lsu_state_q);

        icx_allow_cmd = 1;
        ptw_wait = 0;
        while (!fetch_resp_valid && ptw_wait < 100) begin
            tick();
            ptw_wait = ptw_wait + 1;
        end
        if (!fetch_resp_valid || !fetch_resp_page_fault ||
            fetch_resp_access_fault || fetch_resp_addr != 64'h8000)
            $fatal(1, "held fetch PTW did not complete as a page fault");
        fetch_resp_ready = 1;
        tick();
        fetch_req_priv = `RV64_PRIV_M;
        fetch_req_vm_mode = `RV64_SATP_MODE_BARE;

        // A read-only leaf may populate DTLB through a load, but a subsequent
        // store hit must use write permissions and return a precise page
        // fault rather than entering the fast store path.
        icx_memory[64'h2000 >> 6][5*64 +: 64] =
            64'h0000_0000_0000_0c43;
        ptw_wait = 0;
        while ((dut.u_l1d.store_buffer_count_q != 0) &&
               (ptw_wait < 1400)) begin
            tick();
            ptw_wait = ptw_wait + 1;
        end
        if (dut.u_l1d.store_buffer_count_q != 0)
            $fatal(1, "translated fast store did not drain");
        push_xlate_request(3'd7, 1'b0, 64'h5000);
        expect_xlate_response(3'd7, 64'h3000, 1'b0, 1'b0);
        push_pipe_request(3'd7, 1'b0, 64'h3000, 64'd0, 8'd0);
        expect_pipe_response(3'd7, 64'h5a17_c0de_cafe_1234,
                             1'b0, 1'b0);
        wait_count = translated_fast_store_fires;
        channel_wait = icx_writes;
        push_xlate_request(3'd0, 1'b1, 64'h5000);
        expect_xlate_response(3'd0, 64'h3000, 1'b0, 1'b1);
        if ((translated_fast_store_fires != wait_count) ||
            (icx_writes != channel_wait) ||
            (icx_memory_word(64'h3000) !=
             64'h5a17_c0de_cafe_1234))
            $fatal(1, "read-only DTLB store hit escaped precise fault path");

        // Exercise the ugly shootdown edge.  The old translation exists in
        // ITLB and L2, while DTLB has been capacity-evicted.  Raise TLBI after
        // the live LSU lookup exposes the old L2 hit but before its acceptance
        // edge, while a replacement PTE is already visible.  Invalidation
        // must suppress that hit/fill, capture the held request on the
        // fallback path, clear both L1s and L2, then walk to the replacement
        // physical page.
        @(negedge clk);
        dut.u_dtlb.valid_q = 0;
        xlate_resp_ready = 0;
        wait_count = icx_reads;
        xlate_req_tag = 3'd1;
        xlate_req_write = 1'b0;
        xlate_req_vaddr = 64'h4008;
        xlate_req_valid = 1'b1;
        #1;
        if (!xlate_req_ready || !dut.l2_tlb_select_xlate ||
            !dut.l2_tlb_lookup_hit ||
            !dut.dtlb_l2_fill_valid)
            $fatal(1, "shootdown race setup did not expose stale L2 hit");
        icx_memory[64'h2000 >> 6][4*64 +: 64] =
            64'h0000_0000_0000_04cf;
        icx_memory[64'h1000 >> 6][1*64 +: 64] =
            64'hfeed_face_1234_5678;
        tlbi = 1'b1;
        #1;
        if (dut.l2_tlb_lookup_hit || dut.dtlb_l2_fill_valid ||
            dut.itlb_l2_fill_valid || dut.l2_tlb_fill_valid)
            $fatal(1, "TLBI did not suppress same-cycle translation fill");
        tick();
        if ((|dut.u_itlb.valid_q) || (|dut.u_dtlb.valid_q))
            $fatal(1, "shootdown did not clear both L1 TLBs");
        for (l2_tlb_way = 0; l2_tlb_way < 4;
             l2_tlb_way = l2_tlb_way + 1)
            for (l2_tlb_set = 0; l2_tlb_set < 64;
                 l2_tlb_set = l2_tlb_set + 1)
                if (dut.u_l2_tlb.valid_q[l2_tlb_way][l2_tlb_set])
                    $fatal(1, "shootdown left an L2 TLB entry valid");
        tlbi = 1'b0;
        ptw_wait = 0;
        while (tlbi_busy && (ptw_wait < 300)) begin
            tick();
            ptw_wait = ptw_wait + 1;
        end
        if (tlbi_busy)
            $fatal(1, "shootdown race barrier did not complete");
        channel_wait = 0;
        while (xlate_req_valid && (channel_wait < 100)) begin
            @(posedge clk);
            if (xlate_req_ready) begin
                #1;
                xlate_req_valid = 1'b0;
            end else begin
                #1;
            end
            channel_wait = channel_wait + 1;
        end
        if (xlate_req_valid)
            $fatal(1,
                "shootdown replacement translation not accepted state=%0d ready=%b resp=%b local=%b fallback=%b miss=%b",
                dut.lsu_state_q, xlate_req_ready, xlate_resp_valid,
                dut.xlate_local_resp_valid_q,
                dut.xlate_fallback_active_q, dut.miss_active_q);
        xlate_resp_ready = 1;
        expect_xlate_response(3'd1, 64'h1008, 1'b0, 1'b0);
        push_pipe_request(3'd1, 1'b0, 64'h1008, 64'd0, 8'd0);
        expect_pipe_response(3'd1, 64'hfeed_face_1234_5678,
                             1'b0, 1'b0);
        if ((icx_reads - wait_count) != 4)
            $fatal(1,
                "post-shootdown request did not perform fresh walk/data read count=%0d",
                icx_reads - wait_count);

        pipe_req_vm_mode = `RV64_SATP_MODE_BARE;
        pipe_req_priv = `RV64_PRIV_M;

        // The legacy scalar LSU frontend now terminates at L1D as well.  Its
        // load selects one 64-bit word from the returned 512-bit line.
        wait_count = icx_reads;
        lsu_addr = 64'h248;
        lsu_write = 0;
        lsu_size = 3;
        lsu_valid = 1;
        while (!lsu_ready) tick();
        if (lsu_rdata != icx_memory_word(64'h248) ||
            lsu_access_fault || lsu_page_fault)
            $fatal(1, "LSU read lane steering mismatch: %h", lsu_rdata);
        if ((icx_reads - wait_count) != 1 || awvalid || wvalid)
            $fatal(1, "scalar LSU load did not use one native ICX line read");
        tick();
        lsu_valid = 0;
        tick();

        // A scalar store is lane-positioned on the independent 512-bit ICX
        // write-data channel and never reaches AXI.
        icx_memory[64'h250 >> 6][(64'h250 >> 3 & 7)*64 +: 64] = 64'd0;
        wait_count = icx_writes;
        icx_allow_cmd = 1;
        icx_allow_wdata = 0;
        lsu_addr = 64'h254;
        lsu_write = 1;
        lsu_size = 2;
        lsu_wdata = 64'haabb_ccdd_0000_0000;
        lsu_wstrb = 8'hf0;
        lsu_valid = 1;
        channel_wait = 0;
        while (!icx_cmd_pending && channel_wait < 50) begin
            tick();
            channel_wait = channel_wait + 1;
        end
        if (!icx_cmd_pending)
            $fatal(1, "ICX command did not advance independently");
        if (!icx_wdata_valid)
            $fatal(1, "ICX write data was not held after command accepted");
        icx_allow_wdata = 1;
        while (!lsu_ready) tick();
        if (lsu_access_fault || (icx_writes - wait_count) != 1 ||
            icx_memory_word(64'h250) != 64'haabb_ccdd_0000_0000 ||
            awvalid || wvalid)
            $fatal(1, "scalar ICX write lane steering mismatch");
        tick();
        lsu_valid = 0;

        // A full backend flush cancels an accepted ordinary load at this
        // boundary.  The old L1D response must be consumed invisibly, and
        // the physical tag must remain busy until that drain so a new LSQ
        // owner cannot receive the stale data.
        wait_count = icx_reads;
        icx_allow_cmd = 1'b0;
        push_pipe_request(3'd3, 1'b0, 64'h200, 64'd0, 8'd0);
        while (!icx_req_valid)
            tick();
        pipe_cancel = 1'b1;
        tick();
        pipe_cancel = 1'b0;
        pipe_req_tag = 3'd3;
        pipe_req_write = 1'b0;
        pipe_req_addr = 64'h280;
        pipe_req_wdata = 64'd0;
        pipe_req_wstrb = 8'd0;
        pipe_req_valid = 1'b1;
        repeat (2) begin
            #1;
            if (pipe_req_ready || pipe_resp_valid)
                $fatal(1,
                    "cancelled load released tag before physical drain ready=%b resp=%b",
                    pipe_req_ready, pipe_resp_valid);
            tick();
        end
        icx_allow_cmd = 1'b1;
        channel_wait = 0;
        while (!pipe_req_ready && channel_wait < 300) begin
            if (pipe_resp_valid)
                $fatal(1, "cancelled load response became visible");
            tick();
            channel_wait = channel_wait + 1;
        end
        if (!pipe_req_ready)
            $fatal(1, "cancelled physical tag did not drain");
        tick();
        pipe_req_valid = 1'b0;
        locked_old_word = icx_memory_word(64'h280);
        expect_pipe_response(3'd3, locked_old_word, 1'b0, 1'b0);
        if ((icx_reads - wait_count) != 2)
            $fatal(1,
                "cancel/reuse sequence used %0d ICX reads instead of 2",
                icx_reads - wait_count);

        $display("PASS: core ICX memory path and cacheless AXI fetch");
        $finish;
    end
endmodule
