`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "complex/protocol/defs.v"

module openrv64_core_gen_bus #(
    parameter TLB_ENTRIES = 16,
    parameter integer PTW_PTE_CACHE_ENTRIES = 64,
    parameter integer PTW_ICX_TIMEOUT_CYCLES = 65536,
    parameter [`OPENRV64_ICX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}}
) (
    input  wire                         clk,
    input  wire                         rst_n,

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

    input  wire                         tlbi_i,
    output wire                         tlbi_busy_o,

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

    output wire                         pmp_valid_o,
    output wire [`RV64_XLEN-1:0]        pmp_addr_o,
    output wire [`RV64_PRIV_WIDTH-1:0]  pmp_priv_o,
    output wire [2:0]                   pmp_size_o,
    output wire                         pmp_write_o,
    output wire                         pmp_exec_o,
    input  wire                         pmp_allow_i,

    output wire                         icx_req_valid_o,
    input  wire                         icx_req_ready_i,
    output wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                        icx_req_hart_id_o,
    output wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                        icx_req_txn_id_o,
    output wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                        icx_req_source_id_o,
    output wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op_o,
    output wire                         icx_req_lock_o,
    output wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order_o,
    output wire [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind_o,
    output wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr_o,
    output wire [2:0]                   icx_req_size_o,
    output wire [63:0]                  icx_req_addr_o,
    output wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
                                        icx_req_burst_len_o,
    input  wire                         icx_resp_valid_i,
    output wire                         icx_resp_ready_o,
    input  wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                        icx_resp_hart_id_i,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                        icx_resp_txn_id_i,
    input  wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                        icx_resp_source_id_i,
    input  wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
                                        icx_resp_beat_index_i,
    input  wire                         icx_resp_last_i,
    input  wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
                                        icx_resp_rdata_i,
    input  wire                         icx_resp_error_i,

    // Successor request accepted by the fetch queue on the same edge that
    // the current fetch completes.  This sideband avoids an otherwise
    // unavoidable trip through IDLE; fetch_valid_i still describes the
    // currently active fetch request until that completion edge.
    input  wire                         fetch_next_valid_i,
    input  wire [`RV64_XLEN-1:0]        fetch_next_addr_i
);

    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_TRANSLATE = 2'd1;
    localparam [1:0] STATE_ACCESS = 2'd2;

    localparam OWNER_FETCH = 1'b0;
    localparam OWNER_LSU = 1'b1;

    localparam [1:0] ACCESS_READ = 2'd0;
    localparam [1:0] ACCESS_WRITE = 2'd1;
    localparam [1:0] ACCESS_EXEC = 2'd2;
    reg [1:0] state_q;
    reg owner_q;
    reg cancelled_q;
    reg write_q;
    reg [`RV64_XLEN-1:0] vaddr_q;
    reg [`RV64_XLEN-1:0] paddr_q;
    reg [`RV64_XLEN-1:0] wdata_q;
    reg [7:0] wstrb_q;
    reg [2:0] size_q;
    reg [`RV64_PRIV_WIDTH-1:0] priv_q;
    reg [`RV64_SATP_MODE_WIDTH-1:0] vm_mode_q;
    reg [`RV64_SATP_ASID_WIDTH-1:0] asid_q;
    reg [`RV64_SATP_PPN_WIDTH-1:0] root_ppn_q;
    reg sum_q;
    reg mxr_q;
    reg walk_invalidated_q;

    wire owner_is_fetch = (owner_q == OWNER_FETCH);
    wire fetch_cancelled = owner_is_fetch &&
                           (cancelled_q || fetch_cancel_i);

    wire ptw_req_valid;
    wire ptw_req_ready;
    wire [1:0] ptw_req_access = owner_is_fetch ? ACCESS_EXEC :
                                 write_q ? ACCESS_WRITE : ACCESS_READ;
    wire ptw_resp_valid;
    wire [`RV64_XLEN-1:0] ptw_resp_paddr;
    wire ptw_resp_page_fault;
    wire ptw_resp_access_fault;
    wire ptw_resp_invalidated;
    wire ptw_resp_global;
    wire [`RV64_PAGE_LEVEL_WIDTH-1:0] ptw_resp_level;
    wire ptw_resp_readable;
    wire ptw_resp_writable;
    wire ptw_resp_executable;
    wire ptw_resp_user;
    wire ptw_resp_accessed;
    wire ptw_resp_dirty;
    wire ptw_pmp_valid;
    wire [`RV64_XLEN-1:0] ptw_pmp_addr;

    wire translation_bare = (vm_mode_q == `RV64_SATP_MODE_BARE);

    wire tlb_lookup_hit;
    wire [`RV64_XLEN-1:0] tlb_lookup_paddr;
    wire tlb_lookup_page_fault;
    wire tlb_fill_valid;

    wire translation_fault = ptw_resp_page_fault ||
                             ptw_resp_access_fault;
    wire ptw_translation_complete = (state_q == STATE_TRANSLATE) &&
                                    ptw_resp_valid;
    wire tlb_fault_complete = (state_q == STATE_TRANSLATE) &&
                              tlb_lookup_hit &&
                              tlb_lookup_page_fault;
    wire ptw_response_usable = ptw_translation_complete &&
                               !walk_invalidated_q &&
                               !ptw_resp_invalidated && !tlbi_i;
    wire translation_page_fault = tlb_fault_complete ||
                                  (ptw_response_usable &&
                                   ptw_resp_page_fault);
    wire translation_access_fault = ptw_response_usable &&
                                    ptw_resp_access_fault;
    wire access_complete = (state_q == STATE_ACCESS) && req_ready_i;
    wire owner_completion = translation_page_fault ||
                            translation_access_fault;

    assign ptw_req_valid = (state_q == STATE_TRANSLATE) &&
                           !translation_bare &&
                           !tlb_lookup_hit;
    assign tlb_fill_valid = ptw_response_usable &&
                            !translation_fault &&
                            !fetch_cancelled;

    // Final instruction/data accesses retain the legacy scalar port.  PTE
    // traffic is structurally absent from this interface and leaves only on
    // the PTW's native ICX client below.
    assign req_valid_o = (state_q == STATE_ACCESS);
    assign req_write_o = write_q;
    assign req_addr_o = owner_is_fetch ?
                        {paddr_q[`RV64_XLEN-1:3], 3'b000} : paddr_q;
    assign req_pmp_addr_o = owner_is_fetch ?
                            {paddr_q[`RV64_XLEN-1:3], 3'b000} : paddr_q;
    assign req_priv_o = priv_q;
    assign req_size_o = owner_is_fetch ? 3'd3 : size_q;
    assign req_exec_o = owner_is_fetch;
    assign req_wdata_o = wdata_q;
    assign req_wstrb_o = wstrb_q;

    assign pmp_valid_o = ptw_pmp_valid || (state_q == STATE_ACCESS);
    assign pmp_addr_o = ptw_pmp_valid ? ptw_pmp_addr :
                        req_pmp_addr_o;
    assign pmp_priv_o = ptw_pmp_valid ? `RV64_PRIV_S : priv_q;
    assign pmp_size_o = ptw_pmp_valid ? 3'd3 : req_size_o;
    assign pmp_write_o = ptw_pmp_valid ? 1'b0 : write_q;
    assign pmp_exec_o = !ptw_pmp_valid && owner_is_fetch;

    assign fetch_ready_o = owner_is_fetch &&
                           !fetch_cancelled &&
                           (owner_completion || access_complete);
    assign fetch_rdata_o = req_rdata_i;
    assign fetch_access_fault_o = fetch_ready_o &&
                                  (translation_access_fault ||
                                   (access_complete && req_error_i));
    assign fetch_page_fault_o = fetch_ready_o && translation_page_fault;

    assign lsu_ready_o = !owner_is_fetch &&
                         (owner_completion || access_complete);
    assign lsu_rdata_o = req_rdata_i;
    assign lsu_access_fault_o = lsu_ready_o &&
                                (translation_access_fault ||
                                 (access_complete && req_error_i));
    assign lsu_page_fault_o = lsu_ready_o && translation_page_fault;

    openrv64_bus_tlb #(
        .ENTRIES(TLB_ENTRIES),
        .ASID_WIDTH(`RV64_SATP_ASID_WIDTH)
    ) u_tlb (
        .clk(clk),
        .rst_n(rst_n),
        .tlbi_i(tlbi_i),
        .prefer_asid_valid_i(1'b0),
        .prefer_asid_i({`RV64_SATP_ASID_WIDTH{1'b0}}),
        .lookup_valid_i((state_q == STATE_TRANSLATE) &&
                        !translation_bare),
        .lookup_vaddr_i(vaddr_q),
        .lookup_vm_mode_i(vm_mode_q),
        .lookup_asid_i(asid_q),
        .lookup_access_i(ptw_req_access),
        .lookup_priv_i(priv_q),
        .lookup_sum_i(sum_q),
        .lookup_mxr_i(mxr_q),
        .lookup_hit_o(tlb_lookup_hit),
        .lookup_paddr_o(tlb_lookup_paddr),
        .lookup_page_fault_o(tlb_lookup_page_fault),
        .fill_valid_i(tlb_fill_valid),
        .fill_vaddr_i(vaddr_q),
        .fill_paddr_i(ptw_resp_paddr),
        .fill_vm_mode_i(vm_mode_q),
        .fill_asid_i(asid_q),
        .fill_global_i(ptw_resp_global),
        .fill_level_i(ptw_resp_level),
        .fill_readable_i(ptw_resp_readable),
        .fill_writable_i(ptw_resp_writable),
        .fill_executable_i(ptw_resp_executable),
        .fill_user_i(ptw_resp_user),
        .fill_accessed_i(ptw_resp_accessed),
        .fill_dirty_i(ptw_resp_dirty),
        .fill_evict_valid_o(),
        .fill_evict_preferred_o()
    );

    openrv64_bus_ptw #(
        .PTE_CACHE_ENTRIES(PTW_PTE_CACHE_ENTRIES),
        .ICX_TIMEOUT_CYCLES(PTW_ICX_TIMEOUT_CYCLES),
        .HART_ID(HART_ID)
    ) u_ptw (
        .clk(clk),
        .rst_n(rst_n),
        .invalidate_i(tlbi_i),
        .invalidate_busy_o(tlbi_busy_o),
        .shootdown_ready_i(1'b1),
        .req_valid_i(ptw_req_valid),
        .req_ready_o(ptw_req_ready),
        .req_vaddr_i(vaddr_q),
        .req_access_i(ptw_req_access),
        .req_priv_i(priv_q),
        .req_vm_mode_i(vm_mode_q),
        .req_asid_i(asid_q),
        .req_root_ppn_i(root_ppn_q),
        .req_sum_i(sum_q),
        .req_mxr_i(mxr_q),
        .resp_valid_o(ptw_resp_valid),
        .resp_ready_i(state_q == STATE_TRANSLATE),
        .resp_paddr_o(ptw_resp_paddr),
        .resp_page_fault_o(ptw_resp_page_fault),
        .resp_access_fault_o(ptw_resp_access_fault),
        .resp_invalidated_o(ptw_resp_invalidated),
        .resp_global_o(ptw_resp_global),
        .resp_level_o(ptw_resp_level),
        .resp_readable_o(ptw_resp_readable),
        .resp_writable_o(ptw_resp_writable),
        .resp_executable_o(ptw_resp_executable),
        .resp_user_o(ptw_resp_user),
        .resp_accessed_o(ptw_resp_accessed),
        .resp_dirty_o(ptw_resp_dirty),
        .pmp_valid_o(ptw_pmp_valid),
        .pmp_ready_i(ptw_pmp_valid),
        .pmp_addr_o(ptw_pmp_addr),
        .pmp_allow_i(pmp_allow_i),
        .icx_req_valid_o(icx_req_valid_o),
        .icx_req_ready_i(icx_req_ready_i),
        .icx_req_hart_id_o(icx_req_hart_id_o),
        .icx_req_txn_id_o(icx_req_txn_id_o),
        .icx_req_source_id_o(icx_req_source_id_o),
        .icx_req_op_o(icx_req_op_o),
        .icx_req_lock_o(icx_req_lock_o),
        .icx_req_order_o(icx_req_order_o),
        .icx_req_kind_o(icx_req_kind_o),
        .icx_req_attr_o(icx_req_attr_o),
        .icx_req_size_o(icx_req_size_o),
        .icx_req_addr_o(icx_req_addr_o),
        .icx_req_burst_len_o(icx_req_burst_len_o),
        .icx_resp_valid_i(icx_resp_valid_i),
        .icx_resp_ready_o(icx_resp_ready_o),
        .icx_resp_hart_id_i(icx_resp_hart_id_i),
        .icx_resp_txn_id_i(icx_resp_txn_id_i),
        .icx_resp_source_id_i(icx_resp_source_id_i),
        .icx_resp_beat_index_i(icx_resp_beat_index_i),
        .icx_resp_last_i(icx_resp_last_i),
        .icx_resp_rdata_i(icx_resp_rdata_i),
        .icx_resp_error_i(icx_resp_error_i)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= STATE_IDLE;
            owner_q <= OWNER_FETCH;
            cancelled_q <= 1'b0;
            write_q <= 1'b0;
            vaddr_q <= {`RV64_XLEN{1'b0}};
            paddr_q <= {`RV64_XLEN{1'b0}};
            wdata_q <= {`RV64_XLEN{1'b0}};
            wstrb_q <= 8'h00;
            size_q <= 3'd0;
            priv_q <= `RV64_PRIV_M;
            vm_mode_q <= `RV64_SATP_MODE_BARE;
            asid_q <= {`RV64_SATP_ASID_WIDTH{1'b0}};
            root_ppn_q <= {`RV64_SATP_PPN_WIDTH{1'b0}};
            sum_q <= 1'b0;
            mxr_q <= 1'b0;
            walk_invalidated_q <= 1'b0;
        end else begin
            if ((state_q != STATE_IDLE) && owner_is_fetch &&
                fetch_cancel_i) begin
                cancelled_q <= 1'b1;
            end
            // A post-shootdown request is a fresh walk.  This also covers the
            // case where TLBI arrived while the PTW was idle: req_ready is
            // suppressed during TLBI, then the first real handshake clears
            // the marker.
            if (ptw_req_valid && ptw_req_ready)
                walk_invalidated_q <= 1'b0;
            if (tlbi_i && (state_q == STATE_TRANSLATE)) begin
                walk_invalidated_q <= 1'b1;
            end

            case (state_q)
                STATE_IDLE: begin
                    cancelled_q <= 1'b0;
                    walk_invalidated_q <= 1'b0;

                    if (lsu_valid_i) begin
                        owner_q <= OWNER_LSU;
                        write_q <= lsu_write_i;
                        vaddr_q <= lsu_addr_i;
                        wdata_q <= lsu_write_i ? lsu_wdata_i :
                                   {`RV64_XLEN{1'b0}};
                        wstrb_q <= lsu_write_i ? lsu_wstrb_i : 8'h00;
                        size_q <= lsu_size_i;
                        priv_q <= lsu_priv_i;
                        vm_mode_q <= lsu_vm_mode_i;
                        asid_q <= lsu_asid_i;
                        root_ppn_q <= lsu_root_ppn_i;
                        sum_q <= lsu_sum_i;
                        mxr_q <= lsu_mxr_i;
                        state_q <= STATE_TRANSLATE;
                    end else if (fetch_valid_i && !fetch_cancel_i) begin
                        owner_q <= OWNER_FETCH;
                        write_q <= 1'b0;
                        vaddr_q <= fetch_addr_i;
                        wdata_q <= {`RV64_XLEN{1'b0}};
                        wstrb_q <= 8'h00;
                        size_q <= 3'd3;
                        priv_q <= fetch_priv_i;
                        vm_mode_q <= fetch_vm_mode_i;
                        asid_q <= fetch_asid_i;
                        root_ppn_q <= fetch_root_ppn_i;
                        sum_q <= fetch_sum_i;
                        mxr_q <= fetch_mxr_i;
                        state_q <= STATE_TRANSLATE;
                    end
                end

                STATE_TRANSLATE: begin
                    if (translation_bare) begin
                        if (fetch_cancelled) begin
                            state_q <= STATE_IDLE;
                        end else begin
                            paddr_q <= vaddr_q;
                            state_q <= STATE_ACCESS;
                        end
                    end else if (tlb_lookup_hit) begin
                        if (fetch_cancelled || tlb_lookup_page_fault) begin
                            state_q <= STATE_IDLE;
                        end else begin
                            paddr_q <= tlb_lookup_paddr;
                            state_q <= STATE_ACCESS;
                        end
                    end else if (ptw_resp_valid) begin
                        if (walk_invalidated_q || ptw_resp_invalidated ||
                            tlbi_i) begin
                            walk_invalidated_q <= tlbi_i;
                        end else if (translation_fault || fetch_cancelled) begin
                            state_q <= STATE_IDLE;
                        end else begin
                            paddr_q <= ptw_resp_paddr;
                            state_q <= STATE_ACCESS;
                        end
                    end
                end

                STATE_ACCESS: begin
                    if (req_ready_i) begin
                        // An LSU waiting behind a fetch retains the same
                        // priority it would receive in IDLE.  Otherwise, take
                        // the fetch successor sideband and begin its
                        // translation immediately.  All sideband context is
                        // sampled on this completion edge.
                        if (owner_is_fetch && lsu_valid_i) begin
                            owner_q <= OWNER_LSU;
                            write_q <= lsu_write_i;
                            vaddr_q <= lsu_addr_i;
                            wdata_q <= lsu_write_i ? lsu_wdata_i :
                                       {`RV64_XLEN{1'b0}};
                            wstrb_q <= lsu_write_i ? lsu_wstrb_i : 8'h00;
                            size_q <= lsu_size_i;
                            priv_q <= lsu_priv_i;
                            vm_mode_q <= lsu_vm_mode_i;
                            asid_q <= lsu_asid_i;
                            root_ppn_q <= lsu_root_ppn_i;
                            sum_q <= lsu_sum_i;
                            mxr_q <= lsu_mxr_i;
                            cancelled_q <= 1'b0;
                            walk_invalidated_q <= 1'b0;
                            state_q <= STATE_TRANSLATE;
                        end else if (owner_is_fetch &&
                                     !fetch_cancelled &&
                                     fetch_next_valid_i) begin
                            owner_q <= OWNER_FETCH;
                            write_q <= 1'b0;
                            vaddr_q <= fetch_next_addr_i;
                            wdata_q <= {`RV64_XLEN{1'b0}};
                            wstrb_q <= 8'h00;
                            size_q <= 3'd3;
                            priv_q <= fetch_priv_i;
                            vm_mode_q <= fetch_vm_mode_i;
                            asid_q <= fetch_asid_i;
                            root_ppn_q <= fetch_root_ppn_i;
                            sum_q <= fetch_sum_i;
                            mxr_q <= fetch_mxr_i;
                            cancelled_q <= 1'b0;
                            walk_invalidated_q <= 1'b0;
                            state_q <= STATE_TRANSLATE;
                        end else begin
                            state_q <= STATE_IDLE;
                        end
                    end
                end

                default: begin
                    state_q <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
