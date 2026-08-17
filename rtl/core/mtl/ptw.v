`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "complex/protocol/defs.v"

// MTL-owned Sv39 page-table walker. The legacy module name is retained.
module openrv64_bus_ptw #(
    // The default four-way, 64-entry cache stores 7,808 state bits: 53-bit
    // physical PTE tag, 64-bit PTE, level, recency, and valid state.
    // Set entries to zero to disable.
    parameter integer PTE_CACHE_ENTRIES = 64,
    parameter integer PTE_CACHE_WAYS = 4,
    // Bound a wedged ICX request or response.  Zero disables the watchdog.
    // An unaccepted request can be discarded directly.  An accepted request
    // leaves a response tombstone which must drain before the transaction ID
    // can be reused.
    parameter integer ICX_TIMEOUT_CYCLES = 65536,
    parameter [`OPENRV64_ICX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}},
    parameter [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] TXN_ID =
        {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}}
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         invalidate_i,
    output wire                         invalidate_busy_o,
    // Invalidation and active-walk cancellation happen immediately. This
    // gate delays only the downstream ACQ_REL shootdown transaction so an
    // integration boundary can first expose older posted PTE stores.
    input  wire                         shootdown_ready_i,

    input  wire                         req_valid_i,
    output wire                         req_ready_o,
    input  wire [`RV64_XLEN-1:0]        req_vaddr_i,
    input  wire [1:0]                   req_access_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  req_priv_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] req_vm_mode_i,
    input  wire [`RV64_SATP_ASID_WIDTH-1:0] req_asid_i,
    input  wire [`RV64_SATP_PPN_WIDTH-1:0] req_root_ppn_i,
    input  wire                         req_sum_i,
    input  wire                         req_mxr_i,

    output wire                         resp_valid_o,
    input  wire                         resp_ready_i,
    output wire [`RV64_XLEN-1:0]        resp_paddr_o,
    output wire                         resp_page_fault_o,
    output wire                         resp_access_fault_o,
    output wire                         resp_invalidated_o,
    output wire                         resp_global_o,
    output wire [`RV64_PAGE_LEVEL_WIDTH-1:0] resp_level_o,
    output wire                         resp_readable_o,
    output wire                         resp_writable_o,
    output wire                         resp_executable_o,
    output wire                         resp_user_o,
    output wire                         resp_accessed_o,
    output wire                         resp_dirty_o,

    // Every implicit PTE access is checked as an S-mode 8-byte physical
    // read before the cache lookup result or L2 response is consumed.
    output wire                         pmp_valid_o,
    input  wire                         pmp_ready_i,
    output wire [`RV64_XLEN-1:0]        pmp_addr_o,
    input  wire                         pmp_allow_i,

    // Native ICX PTE client.  Requests are one aligned 64-byte cache line;
    // the selected 8-byte PTE is extracted from the returned line.
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
    input  wire                         icx_resp_error_i
);

    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_WALK = 2'd1;
    localparam [1:0] STATE_RESP = 2'd2;
    localparam [1:0] STATE_ABORT = 2'd3;

    localparam [1:0] BACKEND_PMP  = 2'd0;
    localparam [1:0] BACKEND_SEND = 2'd1;
    localparam [1:0] BACKEND_WAIT = 2'd2;

    localparam [1:0] ACCESS_READ = 2'd0;
    localparam [1:0] ACCESS_WRITE = 2'd1;
    localparam [1:0] ACCESS_EXEC = 2'd2;
    localparam integer PTE_CACHE_ACTIVE_WAYS =
        (PTE_CACHE_ENTRIES > 0) ? PTE_CACHE_WAYS : 1;
    localparam integer PTE_CACHE_SETS =
        (PTE_CACHE_ENTRIES > 0) ?
        (PTE_CACHE_ENTRIES / PTE_CACHE_ACTIVE_WAYS) : 1;
    localparam integer PTE_CACHE_SET_BITS =
        (PTE_CACHE_SETS > 1) ? $clog2(PTE_CACHE_SETS) : 0;
    localparam integer PTE_CACHE_SET_INDEX_WIDTH =
        (PTE_CACHE_SETS > 1) ? PTE_CACHE_SET_BITS : 1;
    localparam integer PTE_CACHE_WAY_BITS =
        (PTE_CACHE_ACTIVE_WAYS > 1) ?
        $clog2(PTE_CACHE_ACTIVE_WAYS) : 0;
    localparam integer PTE_CACHE_WAY_INDEX_WIDTH =
        (PTE_CACHE_ACTIVE_WAYS > 1) ?
        PTE_CACHE_WAY_BITS : 1;
    localparam integer PTE_CACHE_AGE_WIDTH =
        (PTE_CACHE_ACTIVE_WAYS > 1) ?
        $clog2(PTE_CACHE_ACTIVE_WAYS) : 1;
    localparam integer ICX_TIMEOUT_COUNT_WIDTH =
        (ICX_TIMEOUT_CYCLES > 1) ? $clog2(ICX_TIMEOUT_CYCLES) : 1;
    localparam [ICX_TIMEOUT_COUNT_WIDTH-1:0] ICX_TIMEOUT_LAST =
        (ICX_TIMEOUT_CYCLES > 0) ? (ICX_TIMEOUT_CYCLES - 1) :
        {ICX_TIMEOUT_COUNT_WIDTH{1'b0}};
    // Sv39 PTE PPNs form 56-bit physical addresses.  PTEs are 8-byte aligned,
    // so bits [55:3] uniquely identify the cached memory object.
    localparam integer PTE_CACHE_TAG_WIDTH = 53;

    reg [1:0] state_q;
    reg [1:0] backend_state_q;
    reg shootdown_pending_q;
    reg shootdown_inflight_q;
    reg [ICX_TIMEOUT_COUNT_WIDTH-1:0] icx_timeout_count_q;
    reg icx_timeout_drain_q;
    reg [`RV64_XLEN-1:0] vaddr_q;
    reg [1:0] access_q;
    reg [`RV64_PRIV_WIDTH-1:0] priv_q;
    reg sum_q;
    reg mxr_q;
    reg [`RV64_PAGE_LEVEL_WIDTH-1:0] level_q;
    reg [`RV64_XLEN-1:0] table_base_q;
    reg global_q;

    reg [`RV64_XLEN-1:0] resp_paddr_q;
    reg resp_page_fault_q;
    reg resp_access_fault_q;
    reg resp_invalidated_q;
    reg resp_global_q;
    reg [`RV64_PAGE_LEVEL_WIDTH-1:0] resp_level_q;
    reg resp_readable_q;
    reg resp_writable_q;
    reg resp_executable_q;
    reg resp_user_q;
    reg resp_accessed_q;
    reg resp_dirty_q;

    wire [8:0] vpn_0 = vaddr_q[20:12];
    wire [8:0] vpn_1 = vaddr_q[29:21];
    wire [8:0] vpn_2 = vaddr_q[38:30];
    wire [8:0] walk_vpn = (level_q == `RV64_PAGE_LEVEL_1G) ? vpn_2 :
                          (level_q == `RV64_PAGE_LEVEL_2M) ? vpn_1 : vpn_0;
    wire [`RV64_XLEN-1:0] walk_pte_addr =
        table_base_q + {{52{1'b0}}, walk_vpn, 3'b000};

    reg pte_cache_valid_q
        [0:PTE_CACHE_ACTIVE_WAYS-1][0:PTE_CACHE_SETS-1];
    reg [PTE_CACHE_TAG_WIDTH-1:0]
        pte_cache_tag_q
        [0:PTE_CACHE_ACTIVE_WAYS-1][0:PTE_CACHE_SETS-1];
    reg [`RV64_XLEN-1:0]
        pte_cache_data_q
        [0:PTE_CACHE_ACTIVE_WAYS-1][0:PTE_CACHE_SETS-1];
    reg [`RV64_PAGE_LEVEL_WIDTH-1:0]
        pte_cache_level_q
        [0:PTE_CACHE_ACTIVE_WAYS-1][0:PTE_CACHE_SETS-1];
    reg [PTE_CACHE_AGE_WIDTH-1:0]
        pte_cache_age_q
        [0:PTE_CACHE_ACTIVE_WAYS-1][0:PTE_CACHE_SETS-1];

    reg pte_cache_hit_r;
    reg [PTE_CACHE_WAY_INDEX_WIDTH-1:0] pte_cache_hit_way_r;
    reg [`RV64_XLEN-1:0] pte_cache_hit_data_r;
    reg [PTE_CACHE_WAY_INDEX_WIDTH-1:0] pte_cache_victim_way_r;
    reg pte_cache_invalid_victim_r;
    integer pte_cache_lookup_way;
    integer pte_cache_victim_way;
    wire [PTE_CACHE_SET_INDEX_WIDTH-1:0] pte_cache_address_set =
        walk_pte_addr[3 +: PTE_CACHE_SET_INDEX_WIDTH];
    wire [PTE_CACHE_SET_INDEX_WIDTH-1:0] pte_cache_set =
        (PTE_CACHE_SETS > 1) ?
        pte_cache_address_set :
        {PTE_CACHE_SET_INDEX_WIDTH{1'b0}};

    always @* begin
        pte_cache_hit_r = 1'b0;
        pte_cache_hit_way_r =
            {PTE_CACHE_WAY_INDEX_WIDTH{1'b0}};
        pte_cache_hit_data_r = {`RV64_XLEN{1'b0}};
        if ((PTE_CACHE_ENTRIES > 0) && (state_q == STATE_WALK)) begin
            for (pte_cache_lookup_way = 0;
                 pte_cache_lookup_way < PTE_CACHE_ACTIVE_WAYS;
                 pte_cache_lookup_way = pte_cache_lookup_way + 1) begin
                if (!pte_cache_hit_r &&
                    pte_cache_valid_q[
                        pte_cache_lookup_way][pte_cache_set] &&
                    (pte_cache_tag_q[
                        pte_cache_lookup_way][pte_cache_set] ==
                     walk_pte_addr[55:3])) begin
                    pte_cache_hit_r = 1'b1;
                    pte_cache_hit_way_r =
                        pte_cache_lookup_way[
                            PTE_CACHE_WAY_INDEX_WIDTH-1:0];
                    pte_cache_hit_data_r =
                        pte_cache_data_q[
                            pte_cache_lookup_way][pte_cache_set];
                end
            end
        end
    end

    // Prefer an invalid slot.  When full, lower-level non-leaf PTEs are less
    // valuable than root-level PTEs; within one level, replace the entry whose
    // last hit/fill is oldest.
    always @* begin
        pte_cache_victim_way_r =
            {PTE_CACHE_WAY_INDEX_WIDTH{1'b0}};
        pte_cache_invalid_victim_r = 1'b0;
        for (pte_cache_victim_way = 0;
             pte_cache_victim_way < PTE_CACHE_ACTIVE_WAYS;
             pte_cache_victim_way = pte_cache_victim_way + 1) begin
            if (!pte_cache_invalid_victim_r &&
                !pte_cache_valid_q[
                    pte_cache_victim_way][pte_cache_set]) begin
                pte_cache_victim_way_r =
                    pte_cache_victim_way[
                        PTE_CACHE_WAY_INDEX_WIDTH-1:0];
                pte_cache_invalid_victim_r = 1'b1;
            end
        end
        if (!pte_cache_invalid_victim_r &&
            (PTE_CACHE_ENTRIES > 0)) begin
            pte_cache_victim_way_r =
                {PTE_CACHE_WAY_INDEX_WIDTH{1'b0}};
            for (pte_cache_victim_way = 1;
                 pte_cache_victim_way < PTE_CACHE_ACTIVE_WAYS;
                 pte_cache_victim_way = pte_cache_victim_way + 1) begin
                if ((pte_cache_level_q[pte_cache_victim_way]
                         [pte_cache_set] <
                     pte_cache_level_q[pte_cache_victim_way_r]
                         [pte_cache_set]) ||
                    ((pte_cache_level_q[pte_cache_victim_way]
                          [pte_cache_set] ==
                      pte_cache_level_q[pte_cache_victim_way_r]
                          [pte_cache_set]) &&
                     (pte_cache_age_q[pte_cache_victim_way]
                          [pte_cache_set] >
                      pte_cache_age_q[pte_cache_victim_way_r]
                          [pte_cache_set])))
                    pte_cache_victim_way_r =
                        pte_cache_victim_way[
                            PTE_CACHE_WAY_INDEX_WIDTH-1:0];
            end
        end
    end

    wire pmp_fire = pmp_valid_o && pmp_ready_i;
    wire pmp_denied = pmp_fire && !pmp_allow_i;
    wire pte_cache_hit_use = pmp_fire && pmp_allow_i &&
                             pte_cache_hit_r;

    wire walk_icx_req_valid =
        ((state_q == STATE_WALK) || (state_q == STATE_ABORT)) &&
        (backend_state_q == BACKEND_SEND);
    wire shootdown_icx_req_valid =
        (state_q == STATE_IDLE) && shootdown_pending_q &&
        !shootdown_inflight_q && shootdown_ready_i;
    wire icx_req_fire = icx_req_valid_o && icx_req_ready_i;
    wire shootdown_req_fire = shootdown_icx_req_valid && icx_req_ready_i;
    wire icx_resp_owned =
        icx_resp_source_id_i == `OPENRV64_ICX_SOURCE_PTW;
    wire icx_resp_fire = icx_resp_valid_i && icx_resp_ready_o;
    wire walk_backend_pending =
        ((state_q == STATE_WALK) || (state_q == STATE_ABORT)) &&
        ((backend_state_q == BACKEND_SEND) ||
         (backend_state_q == BACKEND_WAIT));
    wire walk_backend_progress =
        ((backend_state_q == BACKEND_SEND) && icx_req_fire) ||
        ((backend_state_q == BACKEND_WAIT) && icx_resp_fire);
    wire walk_backend_timeout =
        (ICX_TIMEOUT_CYCLES != 0) && walk_backend_pending &&
        !walk_backend_progress &&
        (icx_timeout_count_q == ICX_TIMEOUT_LAST);
    wire shootdown_resp_fire = icx_resp_fire && shootdown_inflight_q;
    wire icx_resp_identity_error =
        (icx_resp_hart_id_i != HART_ID) ||
        (icx_resp_txn_id_i != TXN_ID) ||
        (icx_resp_beat_index_i !=
         {`OPENRV64_ICX_BEAT_INDEX_WIDTH{1'b0}}) ||
        !icx_resp_last_i;
    wire [`RV64_XLEN-1:0] icx_pte_data =
        icx_resp_rdata_i[walk_pte_addr[5:3]*`RV64_XLEN +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] walk_pte_data =
        pte_cache_hit_use ? pte_cache_hit_data_r : icx_pte_data;

    // Invalidation is a completion-tracked global translation barrier.  The
    // initiating pulse is included so the core stops post-barrier traffic in
    // the same cycle; pending/inflight retain the barrier until the ICX
    // ACQ_REL fence response has been consumed.  An invalidated active walk
    // also remains covered because shootdown_pending_q cannot issue until the
    // walk has been aborted and drained back to IDLE.
    assign invalidate_busy_o = invalidate_i ||
                               shootdown_pending_q ||
                               shootdown_inflight_q;
    wire walk_pte_ready = pmp_denied || pte_cache_hit_use ||
                          icx_resp_fire;
    wire walk_pte_error = pmp_denied ||
        (icx_resp_fire &&
         (icx_resp_error_i || icx_resp_identity_error));
    wire [PTE_CACHE_AGE_WIDTH-1:0] pte_cache_hit_age =
        pte_cache_age_q[pte_cache_hit_way_r][pte_cache_set];
    wire pte_cache_victim_valid =
        pte_cache_valid_q[pte_cache_victim_way_r][pte_cache_set];
    wire [PTE_CACHE_AGE_WIDTH-1:0] pte_cache_victim_age =
        pte_cache_age_q[pte_cache_victim_way_r][pte_cache_set];

    wire pte_v = walk_pte_data[`RV64_PTE_V_BIT];
    wire pte_r = walk_pte_data[`RV64_PTE_R_BIT];
    wire pte_w = walk_pte_data[`RV64_PTE_W_BIT];
    wire pte_x = walk_pte_data[`RV64_PTE_X_BIT];
    wire pte_u = walk_pte_data[`RV64_PTE_U_BIT];
    wire pte_g = walk_pte_data[`RV64_PTE_G_BIT];
    wire pte_a = walk_pte_data[`RV64_PTE_A_BIT];
    wire pte_d = walk_pte_data[`RV64_PTE_D_BIT];
    wire [`RV64_SATP_PPN_WIDTH-1:0] pte_ppn =
        walk_pte_data[`RV64_PTE_PPN_BITS];
    wire pte_reserved = |walk_pte_data[`RV64_PTE_RESERVED_BITS];
    wire pte_encoding_invalid = !pte_v || (!pte_r && pte_w) ||
                                pte_reserved;
    wire pte_leaf = pte_r || pte_x;
    wire pte_nonleaf_reserved = pte_u || pte_a || pte_d;

    wire canonical_sv39 =
        (req_vaddr_i[63:39] == {25{req_vaddr_i[38]}});
    wire superpage_aligned =
        (level_q == `RV64_PAGE_LEVEL_1G) ? !(|pte_ppn[17:0]) :
        (level_q == `RV64_PAGE_LEVEL_2M) ? !(|pte_ppn[8:0]) : 1'b1;

    wire access_permission =
        (access_q == ACCESS_EXEC) ? pte_x :
        (access_q == ACCESS_WRITE) ? pte_w :
        (access_q == ACCESS_READ) ? (pte_r || (mxr_q && pte_x)) : 1'b0;
    wire privilege_permission =
        (priv_q == `RV64_PRIV_U) ? pte_u :
        (priv_q == `RV64_PRIV_S) ?
            (!pte_u || ((access_q != ACCESS_EXEC) && sum_q)) : 1'b0;
    wire ad_permission = pte_a &&
                         ((access_q != ACCESS_WRITE) || pte_d);
    wire leaf_permission = access_permission && privilege_permission &&
                           ad_permission;

    function [`RV64_XLEN-1:0] compose_paddr;
        input [`RV64_SATP_PPN_WIDTH-1:0] ppn;
        input [`RV64_XLEN-1:0] vaddr;
        input [`RV64_PAGE_LEVEL_WIDTH-1:0] level;
        begin
            case (level)
                `RV64_PAGE_LEVEL_1G:
                    compose_paddr = {8'd0, ppn[43:18], vaddr[29:0]};
                `RV64_PAGE_LEVEL_2M:
                    compose_paddr = {8'd0, ppn[43:9], vaddr[20:0]};
                default:
                    compose_paddr = {8'd0, ppn, vaddr[11:0]};
            endcase
        end
    endfunction

    wire [`RV64_XLEN-1:0] leaf_paddr =
        compose_paddr(pte_ppn, vaddr_q, level_q);

    // Invalidation has priority over admission.  Advertising ready while
    // invalidate_i is asserted would let the requester count a walk that the
    // invalidation branch deliberately does not capture.
    assign req_ready_o = (state_q == STATE_IDLE) && !invalidate_i &&
                         !shootdown_pending_q && !shootdown_inflight_q &&
                         !icx_timeout_drain_q;

    // A stale response is not transferable in the shootdown cycle.  The
    // sequential invalidation path replaces it with an explicit invalidated
    // response after invalidate_i drops.
    assign resp_valid_o = (state_q == STATE_RESP) && !invalidate_i;
    assign resp_paddr_o = resp_paddr_q;
    assign resp_page_fault_o = resp_page_fault_q;
    assign resp_access_fault_o = resp_access_fault_q;
    assign resp_invalidated_o = resp_invalidated_q;
    assign resp_global_o = resp_global_q;
    assign resp_level_o = resp_level_q;
    assign resp_readable_o = resp_readable_q;
    assign resp_writable_o = resp_writable_q;
    assign resp_executable_o = resp_executable_q;
    assign resp_user_o = resp_user_q;
    assign resp_accessed_o = resp_accessed_q;
    assign resp_dirty_o = resp_dirty_q;

    assign pmp_valid_o = (state_q == STATE_WALK) &&
                         (backend_state_q == BACKEND_PMP) &&
                         !invalidate_i;
    assign pmp_addr_o = walk_pte_addr;

    assign icx_req_valid_o = shootdown_icx_req_valid || walk_icx_req_valid;
    assign icx_req_hart_id_o = HART_ID;
    assign icx_req_txn_id_o = TXN_ID;
    assign icx_req_source_id_o = `OPENRV64_ICX_SOURCE_PTW;
    assign icx_req_op_o = shootdown_icx_req_valid ?
                          `OPENRV64_ICX_OP_FENCE :
                          `OPENRV64_ICX_OP_READ;
    assign icx_req_lock_o = 1'b0;
    assign icx_req_order_o = shootdown_icx_req_valid ?
                             `OPENRV64_ICX_ORDER_ACQ_REL :
                             `OPENRV64_ICX_ORDER_NONE;
    assign icx_req_kind_o = `OPENRV64_ICX_KIND_PTE;
    assign icx_req_attr_o = shootdown_icx_req_valid ?
        `OPENRV64_ICX_ATTR_NONE :
        (`OPENRV64_ICX_ATTR_CACHEABLE |
         `OPENRV64_ICX_ATTR_IDEMPOTENT);
    assign icx_req_size_o = shootdown_icx_req_valid ? 3'd0 : 3'd6;
    assign icx_req_addr_o = shootdown_icx_req_valid ? 64'd0 :
        {walk_pte_addr[`RV64_XLEN-1:6], 6'b0};
    assign icx_req_burst_len_o =
        {`OPENRV64_ICX_BURST_LEN_WIDTH{1'b0}};

    assign icx_resp_ready_o =
        icx_resp_owned &&
        (icx_timeout_drain_q || shootdown_inflight_q ||
         (((state_q == STATE_WALK) || (state_q == STATE_ABORT)) &&
          (backend_state_q == BACKEND_WAIT)));

    // This watchdog is deliberately local to an active walk.  A shootdown
    // fence has no originating architectural access to fault and therefore
    // remains governed by the fabric's forward-progress contract.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            icx_timeout_count_q <=
                {ICX_TIMEOUT_COUNT_WIDTH{1'b0}};
        end else if ((ICX_TIMEOUT_CYCLES == 0) ||
                     !walk_backend_pending || walk_backend_progress ||
                     walk_backend_timeout) begin
            icx_timeout_count_q <=
                {ICX_TIMEOUT_COUNT_WIDTH{1'b0}};
        end else begin
            icx_timeout_count_q <= icx_timeout_count_q + 1'b1;
        end
    end

    // SFENCE.VMA and the local shootdown input also invalidate PTE lines which
    // may have survived in the shared L2.  Multiple invalidations coalesce
    // while no new walk is admitted.  An invalidation arriving while a prior
    // shootdown is in flight leaves another transaction pending.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shootdown_pending_q <= 1'b0;
            shootdown_inflight_q <= 1'b0;
        end else begin
            if (shootdown_req_fire) begin
                shootdown_pending_q <= 1'b0;
                shootdown_inflight_q <= 1'b1;
            end
            if (shootdown_resp_fire)
                shootdown_inflight_q <= 1'b0;
            if (invalidate_i)
                shootdown_pending_q <= 1'b1;
        end
    end

    task automatic set_fault_response;
        input page_fault;
        input access_fault;
        begin
            resp_paddr_q <= {`RV64_XLEN{1'b0}};
            resp_page_fault_q <= page_fault;
            resp_access_fault_q <= access_fault;
            resp_invalidated_q <= 1'b0;
            resp_global_q <= 1'b0;
            resp_level_q <= `RV64_PAGE_LEVEL_4K;
            resp_readable_q <= 1'b0;
            resp_writable_q <= 1'b0;
            resp_executable_q <= 1'b0;
            resp_user_q <= 1'b0;
            resp_accessed_q <= 1'b0;
            resp_dirty_q <= 1'b0;
            state_q <= STATE_RESP;
        end
    endtask

    task automatic set_invalidated_response;
        begin
            resp_paddr_q <= {`RV64_XLEN{1'b0}};
            resp_page_fault_q <= 1'b0;
            resp_access_fault_q <= 1'b0;
            resp_invalidated_q <= 1'b1;
            resp_global_q <= 1'b0;
            resp_level_q <= `RV64_PAGE_LEVEL_4K;
            resp_readable_q <= 1'b0;
            resp_writable_q <= 1'b0;
            resp_executable_q <= 1'b0;
            resp_user_q <= 1'b0;
            resp_accessed_q <= 1'b0;
            resp_dirty_q <= 1'b0;
            state_q <= STATE_RESP;
        end
    endtask

    wire pte_cache_fill = (PTE_CACHE_ENTRIES > 0) &&
        (state_q == STATE_WALK) && !pte_cache_hit_r &&
        icx_resp_fire && !walk_pte_error && !pte_encoding_invalid &&
        !pte_leaf && (level_q != `RV64_PAGE_LEVEL_4K) &&
        !pte_nonleaf_reserved;
    integer pte_cache_state_way;
    integer pte_cache_state_set;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (pte_cache_state_way = 0;
                 pte_cache_state_way < PTE_CACHE_ACTIVE_WAYS;
                 pte_cache_state_way = pte_cache_state_way + 1)
                for (pte_cache_state_set = 0;
                     pte_cache_state_set < PTE_CACHE_SETS;
                     pte_cache_state_set = pte_cache_state_set + 1)
                    pte_cache_valid_q[
                        pte_cache_state_way][pte_cache_state_set] <= 1'b0;
        end else if (invalidate_i) begin
            for (pte_cache_state_way = 0;
                 pte_cache_state_way < PTE_CACHE_ACTIVE_WAYS;
                 pte_cache_state_way = pte_cache_state_way + 1)
                for (pte_cache_state_set = 0;
                     pte_cache_state_set < PTE_CACHE_SETS;
                     pte_cache_state_set = pte_cache_state_set + 1)
                    pte_cache_valid_q[
                        pte_cache_state_way][pte_cache_state_set] <= 1'b0;
        end else if (pte_cache_hit_use) begin
            for (pte_cache_state_way = 0;
                 pte_cache_state_way < PTE_CACHE_ACTIVE_WAYS;
                 pte_cache_state_way = pte_cache_state_way + 1) begin
                if (pte_cache_state_way[
                        PTE_CACHE_WAY_INDEX_WIDTH-1:0] ==
                    pte_cache_hit_way_r) begin
                    pte_cache_age_q[
                        pte_cache_state_way][pte_cache_set] <=
                        {PTE_CACHE_AGE_WIDTH{1'b0}};
                end else if (pte_cache_valid_q[
                                 pte_cache_state_way][pte_cache_set] &&
                             (pte_cache_age_q[
                                  pte_cache_state_way][pte_cache_set] <
                              pte_cache_hit_age)) begin
                    pte_cache_age_q[
                        pte_cache_state_way][pte_cache_set] <=
                        pte_cache_age_q[
                            pte_cache_state_way][pte_cache_set] + 1'b1;
                end
            end
        end else if (pte_cache_fill) begin
            for (pte_cache_state_way = 0;
                 pte_cache_state_way < PTE_CACHE_ACTIVE_WAYS;
                 pte_cache_state_way = pte_cache_state_way + 1) begin
                if (pte_cache_state_way[
                        PTE_CACHE_WAY_INDEX_WIDTH-1:0] !=
                    pte_cache_victim_way_r &&
                    pte_cache_valid_q[
                        pte_cache_state_way][pte_cache_set] &&
                    (!pte_cache_victim_valid ||
                     (pte_cache_age_q[
                          pte_cache_state_way][pte_cache_set] <
                      pte_cache_victim_age)))
                    pte_cache_age_q[
                        pte_cache_state_way][pte_cache_set] <=
                        pte_cache_age_q[
                            pte_cache_state_way][pte_cache_set] + 1'b1;
            end
            pte_cache_valid_q[
                pte_cache_victim_way_r][pte_cache_set] <= 1'b1;
            pte_cache_tag_q[
                pte_cache_victim_way_r][pte_cache_set] <=
                walk_pte_addr[55:3];
            pte_cache_data_q[
                pte_cache_victim_way_r][pte_cache_set] <=
                walk_pte_data;
            pte_cache_level_q[
                pte_cache_victim_way_r][pte_cache_set] <= level_q;
            pte_cache_age_q[
                pte_cache_victim_way_r][pte_cache_set] <=
                {PTE_CACHE_AGE_WIDTH{1'b0}};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= STATE_IDLE;
            backend_state_q <= BACKEND_PMP;
            icx_timeout_drain_q <= 1'b0;
            vaddr_q <= {`RV64_XLEN{1'b0}};
            access_q <= ACCESS_READ;
            priv_q <= `RV64_PRIV_M;
            sum_q <= 1'b0;
            mxr_q <= 1'b0;
            level_q <= `RV64_PAGE_LEVEL_1G;
            table_base_q <= {`RV64_XLEN{1'b0}};
            global_q <= 1'b0;
            resp_paddr_q <= {`RV64_XLEN{1'b0}};
            resp_page_fault_q <= 1'b0;
            resp_access_fault_q <= 1'b0;
            resp_invalidated_q <= 1'b0;
            resp_global_q <= 1'b0;
            resp_level_q <= `RV64_PAGE_LEVEL_4K;
            resp_readable_q <= 1'b0;
            resp_writable_q <= 1'b0;
            resp_executable_q <= 1'b0;
            resp_user_q <= 1'b0;
            resp_accessed_q <= 1'b0;
            resp_dirty_q <= 1'b0;
        end else begin
            // A timed-out accepted request owns its transaction identity
            // until a possible late response has been consumed.
            if (icx_timeout_drain_q && icx_resp_fire)
                icx_timeout_drain_q <= 1'b0;

            if (invalidate_i) begin
            case (state_q)
                STATE_WALK: begin
                    case (backend_state_q)
                        BACKEND_PMP: begin
                            set_invalidated_response();
                        end
                        BACKEND_SEND: begin
                            state_q <= STATE_ABORT;
                            if (icx_req_fire)
                                backend_state_q <= BACKEND_WAIT;
                        end
                        BACKEND_WAIT: begin
                            if (icx_resp_fire)
                                set_invalidated_response();
                            else
                                state_q <= STATE_ABORT;
                        end
                        default: begin
                            set_invalidated_response();
                        end
                    endcase
                end
                STATE_ABORT: begin
                    if ((backend_state_q == BACKEND_SEND) &&
                        icx_req_fire)
                        backend_state_q <= BACKEND_WAIT;
                    else if ((backend_state_q == BACKEND_WAIT) &&
                             icx_resp_fire)
                        set_invalidated_response();
                end
                STATE_RESP: begin
                    set_invalidated_response();
                end
                default: begin
                end
            endcase
            end else begin
            case (state_q)
                STATE_IDLE: begin
                    if (req_valid_i && req_ready_o) begin
                        if (req_vm_mode_i == `RV64_SATP_MODE_BARE) begin
                            resp_paddr_q <= req_vaddr_i;
                            resp_page_fault_q <= 1'b0;
                            resp_access_fault_q <= 1'b0;
                            resp_invalidated_q <= 1'b0;
                            resp_global_q <= 1'b1;
                            resp_level_q <= `RV64_PAGE_LEVEL_4K;
                            resp_readable_q <= 1'b1;
                            resp_writable_q <= 1'b1;
                            resp_executable_q <= 1'b1;
                            resp_user_q <= 1'b1;
                            resp_accessed_q <= 1'b1;
                            resp_dirty_q <= 1'b1;
                            state_q <= STATE_RESP;
                        end else if ((req_vm_mode_i !=
                                     `RV64_SATP_MODE_SV39) ||
                                    !canonical_sv39 ||
                                    (req_priv_i == `RV64_PRIV_M)) begin
                            set_fault_response(1'b1, 1'b0);
                        end else begin
                            vaddr_q <= req_vaddr_i;
                            access_q <= req_access_i;
                            priv_q <= req_priv_i;
                            sum_q <= req_sum_i;
                            mxr_q <= req_mxr_i;
                            level_q <= `RV64_PAGE_LEVEL_1G;
                            table_base_q <= {
                                8'd0, req_root_ppn_i, 12'd0
                            };
                            global_q <= 1'b0;
                            resp_invalidated_q <= 1'b0;
                            backend_state_q <= BACKEND_PMP;
                            state_q <= STATE_WALK;
                        end
                    end
                end

                STATE_WALK: begin
                    if ((backend_state_q == BACKEND_PMP) && pmp_fire &&
                        pmp_allow_i && !pte_cache_hit_r)
                        backend_state_q <= BACKEND_SEND;
                    else if ((backend_state_q == BACKEND_SEND) &&
                             icx_req_fire)
                        backend_state_q <= BACKEND_WAIT;

                    if (walk_backend_timeout) begin
                        if (backend_state_q == BACKEND_WAIT)
                            icx_timeout_drain_q <= 1'b1;
                        set_fault_response(1'b0, 1'b1);
                    end else if (walk_pte_ready) begin
                        if (walk_pte_error) begin
                            set_fault_response(1'b0, 1'b1);
                        end else if (pte_encoding_invalid) begin
                            set_fault_response(1'b1, 1'b0);
                        end else if (pte_leaf) begin
                            if (!superpage_aligned || !leaf_permission) begin
                                set_fault_response(1'b1, 1'b0);
                            end else begin
                                resp_paddr_q <= leaf_paddr;
                                resp_page_fault_q <= 1'b0;
                                resp_access_fault_q <= 1'b0;
                                resp_invalidated_q <= 1'b0;
                                resp_global_q <= global_q || pte_g;
                                resp_level_q <= level_q;
                                resp_readable_q <= pte_r;
                                resp_writable_q <= pte_w;
                                resp_executable_q <= pte_x;
                                resp_user_q <= pte_u;
                                resp_accessed_q <= pte_a;
                                resp_dirty_q <= pte_d;
                                state_q <= STATE_RESP;
                            end
                        end else if ((level_q == `RV64_PAGE_LEVEL_4K) ||
                                     pte_nonleaf_reserved) begin
                            set_fault_response(1'b1, 1'b0);
                        end else begin
                            table_base_q <= {8'd0, pte_ppn, 12'd0};
                            level_q <= level_q - 1'b1;
                            global_q <= global_q || pte_g;
                            backend_state_q <= BACKEND_PMP;
                        end
                    end
                end

                STATE_ABORT: begin
                    if (walk_backend_timeout) begin
                        if (backend_state_q == BACKEND_WAIT)
                            icx_timeout_drain_q <= 1'b1;
                        set_invalidated_response();
                    end else if ((backend_state_q == BACKEND_SEND) &&
                        icx_req_fire)
                        backend_state_q <= BACKEND_WAIT;
                    else if ((backend_state_q == BACKEND_WAIT) &&
                             icx_resp_fire)
                        set_invalidated_response();
                end

                STATE_RESP: begin
                    if (resp_ready_i) begin
                        state_q <= STATE_IDLE;
                    end
                end

                default: begin
                    state_q <= STATE_IDLE;
                    backend_state_q <= BACKEND_PMP;
                end
            endcase
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && shootdown_resp_fire &&
            (icx_resp_error_i || icx_resp_identity_error))
            $fatal(1, "PTW L2-generation shootdown response failed");
    end

    initial begin
        if ((PTE_CACHE_ENTRIES < 0) || (PTE_CACHE_WAYS < 1))
            $fatal(1, "invalid non-leaf PTE cache geometry");
        if (ICX_TIMEOUT_CYCLES < 0)
            $fatal(1, "PTW ICX timeout must be nonnegative");
        if ((PTE_CACHE_ENTRIES > 0) &&
            (((PTE_CACHE_WAYS & (PTE_CACHE_WAYS - 1)) != 0) ||
             ((PTE_CACHE_ENTRIES % PTE_CACHE_WAYS) != 0) ||
             ((PTE_CACHE_SETS & (PTE_CACHE_SETS - 1)) != 0)))
            $fatal(1,
                   "PTE cache entries must form power-of-two sets and ways");
    end
`endif

    wire unused_asid = |req_asid_i;

endmodule
