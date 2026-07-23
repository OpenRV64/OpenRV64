`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/isa/rv64-priv.v"

// 256-bit frontend view of a native 512-bit CCX instruction-cache endpoint.
//
// The private cache stores a complete 64-byte line in one data word.  A
// frontend request selects either 256-bit half of that resident line.  A miss
// emits one native CCX command and consumes one native 512-bit response beat;
// it is never decomposed into scalar compatibility requests.
module openrv64_l1i_ccx #(
    parameter integer ENABLE = 1,
    parameter integer ADDR_WIDTH = 64,
    parameter integer CACHE_BYTES = 8 * 1024,
    parameter integer WAYS = 4,
    parameter integer FILL_BUFFER_LINES = 8,
    parameter integer PREFETCH_SLOTS = FILL_BUFFER_LINES,
    parameter integer DEMAND_DEPTH = 8,
    parameter integer WRITEBACK_TIMEOUT_CYCLES = 128,
    parameter integer DIRTY_TIMESTAMP_WIDTH =
        (WRITEBACK_TIMEOUT_CYCLES < 2) ? 1 :
        $clog2(WRITEBACK_TIMEOUT_CYCLES + 1),
    parameter [`OPENRV64_CCX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}}
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,

    input  wire                         req_valid_i,
    output wire                         req_ready_o,
    input  wire                         req_cacheable_i,
    input  wire [ADDR_WIDTH-1:0]        req_addr_i,
    input  wire [ADDR_WIDTH-1:0]        req_phys_addr_i,
    output wire                         resp_valid_o,
    input  wire                         resp_ready_i,
    output wire [255:0]                 req_rdata_o,
    output wire                         req_error_o,

    // Conditional-branch hints are virtual.  L1I retains both paths and
    // requests translation below; no speculative fault is architectural.
    input  wire                         prefetch_valid_i,
    input  wire [ADDR_WIDTH-1:0]        prefetch_taken_addr_i,
    input  wire [ADDR_WIDTH-1:0]        prefetch_fallthrough_addr_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  prefetch_priv_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] prefetch_vm_mode_i,
    input  wire [`RV64_SATP_ASID_WIDTH-1:0] prefetch_asid_i,
    input  wire [`RV64_SATP_PPN_WIDTH-1:0] prefetch_root_ppn_i,
    input  wire                         prefetch_sum_i,
    input  wire                         prefetch_mxr_i,
    input  wire [2:0]                   retire_age_valid_i,
    input  wire [3*ADDR_WIDTH-1:0]      retire_age_addr_i,
    input  wire                         prefetch_flush_i,

    output wire                         xlate_req_valid_o,
    input  wire                         xlate_req_ready_i,
    output wire [ADDR_WIDTH-1:0]        xlate_req_vaddr_o,
    output wire [`RV64_PRIV_WIDTH-1:0]  xlate_req_priv_o,
    output wire [`RV64_SATP_MODE_WIDTH-1:0] xlate_req_vm_mode_o,
    output wire [`RV64_SATP_ASID_WIDTH-1:0] xlate_req_asid_o,
    output wire [`RV64_SATP_PPN_WIDTH-1:0] xlate_req_root_ppn_o,
    output wire                         xlate_req_sum_o,
    output wire                         xlate_req_mxr_o,
    input  wire                         xlate_resp_valid_i,
    output wire                         xlate_resp_ready_o,
    input  wire [ADDR_WIDTH-1:0]        xlate_resp_paddr_i,
    input  wire                         xlate_resp_fault_i,

    input  wire                         invalidate_valid_i,
    output wire                         invalidate_ready_o,
    input  wire                         invalidate_all_i,
    input  wire [ADDR_WIDTH-1:0]        invalidate_addr_i,

    output wire                         ccx_req_valid_o,
    input  wire                         ccx_req_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_req_hart_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_req_source_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_req_txn_id_o,
    output wire [`OPENRV64_CCX_OP_WIDTH-1:0]
                                        ccx_req_op_o,
    output wire [`OPENRV64_CCX_ORDER_WIDTH-1:0]
                                        ccx_req_order_o,
    output wire [`OPENRV64_CCX_KIND_WIDTH-1:0]
                                        ccx_req_kind_o,
    output wire [`OPENRV64_CCX_ATTR_WIDTH-1:0]
                                        ccx_req_attr_o,
    output wire [2:0]                   ccx_req_size_o,
    output wire [ADDR_WIDTH-1:0]        ccx_req_addr_o,
    output wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
                                        ccx_req_burst_len_o,

    input  wire                         ccx_resp_valid_i,
    output wire                         ccx_resp_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_resp_hart_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_resp_source_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_resp_txn_id_i,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                        ccx_resp_rdata_i,
    input  wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                        ccx_resp_beat_index_i,
    input  wire                         ccx_resp_last_i,
    input  wire                         ccx_resp_error_i,
    input  wire                         ccx_resp_sc_success_i
);

    localparam [1:0] BACKEND_IDLE = 2'd0;
    localparam [1:0] BACKEND_SEND = 2'd1;
    localparam [1:0] BACKEND_WAIT = 2'd2;
    localparam integer PREFETCH_INDEX_WIDTH =
        (PREFETCH_SLOTS > 1) ? $clog2(PREFETCH_SLOTS) : 1;
    localparam integer DEMAND_INDEX_WIDTH =
        (DEMAND_DEPTH > 1) ? $clog2(DEMAND_DEPTH) : 1;
    localparam integer DEMAND_COUNT_WIDTH =
        $clog2(DEMAND_DEPTH + 1);

    initial begin
        if ((PREFETCH_SLOTS < 2) || (PREFETCH_SLOTS > 16))
            $fatal(1,
                   "L1I fill/prefetch slots must contain 2 through 16 cachelines");
        // VIPT is synonym-safe only while every way spans no more than the
        // minimum 4 KiB page; all set bits then come from the page offset.
        if ((CACHE_BYTES / WAYS) > 4096)
            $fatal(1, "L1I VIPT way size exceeds the 4 KiB page offset");
        if ((DEMAND_DEPTH < 2) || (DEMAND_DEPTH > 16))
            $fatal(1, "L1I demand depth must contain 2 through 16 requests");
    end

    reg slot_valid_q [0:PREFETCH_SLOTS-1];
    reg slot_age_only_q [0:PREFETCH_SLOTS-1];
    reg slot_translating_q [0:PREFETCH_SLOTS-1];
    reg slot_translated_q [0:PREFETCH_SLOTS-1];
    reg slot_aged_q [0:PREFETCH_SLOTS-1];
    reg [ADDR_WIDTH-1:0] slot_vaddr_q [0:PREFETCH_SLOTS-1];
    reg [ADDR_WIDTH-1:0] slot_paddr_q [0:PREFETCH_SLOTS-1];
    reg [`RV64_PRIV_WIDTH-1:0] slot_priv_q [0:PREFETCH_SLOTS-1];
    reg [`RV64_SATP_MODE_WIDTH-1:0]
        slot_vm_mode_q [0:PREFETCH_SLOTS-1];
    reg [`RV64_SATP_ASID_WIDTH-1:0]
        slot_asid_q [0:PREFETCH_SLOTS-1];
    reg [`RV64_SATP_PPN_WIDTH-1:0]
        slot_root_ppn_q [0:PREFETCH_SLOTS-1];
    reg slot_sum_q [0:PREFETCH_SLOTS-1];
    reg slot_mxr_q [0:PREFETCH_SLOTS-1];

    reg xlate_slot_found_r;
    reg [PREFETCH_INDEX_WIDTH-1:0] xlate_slot_r;
    reg fill_slot_found_r;
    reg [PREFETCH_INDEX_WIDTH-1:0] fill_slot_r;
    reg age_slot_found_r;
    reg [PREFETCH_INDEX_WIDTH-1:0] age_slot_r;
    integer schedule_index;

    always @* begin
        xlate_slot_found_r = 1'b0;
        xlate_slot_r = {PREFETCH_INDEX_WIDTH{1'b0}};
        fill_slot_found_r = 1'b0;
        fill_slot_r = {PREFETCH_INDEX_WIDTH{1'b0}};
        age_slot_found_r = 1'b0;
        age_slot_r = {PREFETCH_INDEX_WIDTH{1'b0}};
        for (schedule_index = 0; schedule_index < PREFETCH_SLOTS;
             schedule_index = schedule_index + 1) begin
            if (!xlate_slot_found_r && slot_valid_q[schedule_index] &&
                !slot_translating_q[schedule_index] &&
                !slot_translated_q[schedule_index]) begin
                xlate_slot_found_r = 1'b1;
                xlate_slot_r = schedule_index[PREFETCH_INDEX_WIDTH-1:0];
            end
            if (!fill_slot_found_r && slot_valid_q[schedule_index] &&
                slot_translated_q[schedule_index] &&
                !slot_age_only_q[schedule_index]) begin
                fill_slot_found_r = 1'b1;
                fill_slot_r = schedule_index[PREFETCH_INDEX_WIDTH-1:0];
            end
            if (!age_slot_found_r && slot_valid_q[schedule_index] &&
                slot_translated_q[schedule_index] &&
                slot_age_only_q[schedule_index]) begin
                age_slot_found_r = 1'b1;
                age_slot_r = schedule_index[PREFETCH_INDEX_WIDTH-1:0];
            end
        end
    end

    reg [PREFETCH_SLOTS-1:0] enqueue_reserved_r;
    reg enqueue_taken_r;
    reg enqueue_fallthrough_r;
    reg [PREFETCH_INDEX_WIDTH-1:0] enqueue_taken_slot_r;
    reg [PREFETCH_INDEX_WIDTH-1:0] enqueue_fallthrough_slot_r;
    reg [2:0] enqueue_age_r;
    reg [3*PREFETCH_INDEX_WIDTH-1:0] enqueue_age_slot_r;
    reg taken_duplicate_r;
    reg fallthrough_duplicate_r;
    reg [2:0] age_duplicate_r;
    reg free_found_r;
    integer enqueue_index;
    integer enqueue_age_port;

    reg cache_active_q;
    reg cache_prefetch_q;
    reg cache_cacheable_q;
    reg cache_aged_q;
    reg l1_request_sent_q;
    reg [ADDR_WIDTH-1:0] cache_vaddr_q;
    reg [ADDR_WIDTH-1:0] cache_paddr_q;
    reg [`RV64_SATP_MODE_WIDTH-1:0] cache_vm_mode_q;
    reg [`RV64_SATP_ASID_WIDTH-1:0] cache_asid_q;
    reg [`RV64_SATP_PPN_WIDTH-1:0] cache_root_ppn_q;
    reg response_prefetch_q [0:DEMAND_DEPTH-1];
    reg response_upper_half_q [0:DEMAND_DEPTH-1];
    reg [DEMAND_INDEX_WIDTH-1:0] response_head_q;
    reg [DEMAND_INDEX_WIDTH-1:0] response_tail_q;
    reg [DEMAND_COUNT_WIDTH-1:0] response_count_q;
    integer response_reset_index;

    function same_line;
        input [ADDR_WIDTH-1:0] left;
        input [ADDR_WIDTH-1:0] right;
        begin
            same_line = left[ADDR_WIDTH-1:6] == right[ADDR_WIDTH-1:6];
        end
    endfunction

    function same_current_context;
        input [`RV64_SATP_MODE_WIDTH-1:0] vm_mode;
        input [`RV64_SATP_ASID_WIDTH-1:0] asid;
        input [`RV64_SATP_PPN_WIDTH-1:0] root_ppn;
        begin
            same_current_context =
                (vm_mode == prefetch_vm_mode_i) &&
                (asid == prefetch_asid_i) &&
                (root_ppn == prefetch_root_ppn_i);
        end
    endfunction

    always @* begin
        enqueue_reserved_r = {PREFETCH_SLOTS{1'b0}};
        for (enqueue_index = 0; enqueue_index < PREFETCH_SLOTS;
             enqueue_index = enqueue_index + 1)
            enqueue_reserved_r[enqueue_index] = slot_valid_q[enqueue_index];

        taken_duplicate_r = cache_active_q &&
            same_line(cache_vaddr_q, prefetch_taken_addr_i) &&
            same_current_context(cache_vm_mode_q, cache_asid_q,
                                 cache_root_ppn_q);
        fallthrough_duplicate_r = cache_active_q &&
            same_line(cache_vaddr_q, prefetch_fallthrough_addr_i) &&
            same_current_context(cache_vm_mode_q, cache_asid_q,
                                 cache_root_ppn_q);
        for (enqueue_index = 0; enqueue_index < PREFETCH_SLOTS;
             enqueue_index = enqueue_index + 1) begin
            if (slot_valid_q[enqueue_index] &&
                !slot_age_only_q[enqueue_index] &&
                same_current_context(slot_vm_mode_q[enqueue_index],
                                     slot_asid_q[enqueue_index],
                                     slot_root_ppn_q[enqueue_index])) begin
                if (same_line(slot_vaddr_q[enqueue_index],
                              prefetch_taken_addr_i))
                    taken_duplicate_r = 1'b1;
                if (same_line(slot_vaddr_q[enqueue_index],
                              prefetch_fallthrough_addr_i))
                    fallthrough_duplicate_r = 1'b1;
            end
        end

        enqueue_taken_r = 1'b0;
        enqueue_taken_slot_r = {PREFETCH_INDEX_WIDTH{1'b0}};
        free_found_r = 1'b0;
        if (prefetch_valid_i && !taken_duplicate_r) begin
            for (enqueue_index = 0; enqueue_index < PREFETCH_SLOTS;
                 enqueue_index = enqueue_index + 1) begin
                if (!free_found_r && !enqueue_reserved_r[enqueue_index]) begin
                    enqueue_taken_r = 1'b1;
                    enqueue_taken_slot_r =
                        enqueue_index[PREFETCH_INDEX_WIDTH-1:0];
                    enqueue_reserved_r[enqueue_index] = 1'b1;
                    free_found_r = 1'b1;
                end
            end
        end

        enqueue_fallthrough_r = 1'b0;
        enqueue_fallthrough_slot_r = {PREFETCH_INDEX_WIDTH{1'b0}};
        free_found_r = 1'b0;
        if (prefetch_valid_i && !fallthrough_duplicate_r &&
            !same_line(prefetch_taken_addr_i,
                       prefetch_fallthrough_addr_i)) begin
            for (enqueue_index = 0; enqueue_index < PREFETCH_SLOTS;
                 enqueue_index = enqueue_index + 1) begin
                if (!free_found_r && !enqueue_reserved_r[enqueue_index]) begin
                    enqueue_fallthrough_r = 1'b1;
                    enqueue_fallthrough_slot_r =
                        enqueue_index[PREFETCH_INDEX_WIDTH-1:0];
                    enqueue_reserved_r[enqueue_index] = 1'b1;
                    free_found_r = 1'b1;
                end
            end
        end

        enqueue_age_r = 3'b000;
        enqueue_age_slot_r =
            {3*PREFETCH_INDEX_WIDTH{1'b0}};
        age_duplicate_r = 3'b000;
        for (enqueue_age_port = 0; enqueue_age_port < 3;
             enqueue_age_port = enqueue_age_port + 1) begin
            if (cache_active_q && cache_prefetch_q &&
                same_line(cache_vaddr_q,
                    retire_age_addr_i[enqueue_age_port*ADDR_WIDTH +:
                                      ADDR_WIDTH]) &&
                same_current_context(cache_vm_mode_q, cache_asid_q,
                                     cache_root_ppn_q))
                age_duplicate_r[enqueue_age_port] = 1'b1;
            for (enqueue_index = 0; enqueue_index < PREFETCH_SLOTS;
                 enqueue_index = enqueue_index + 1) begin
                if (slot_valid_q[enqueue_index] &&
                    same_current_context(slot_vm_mode_q[enqueue_index],
                                         slot_asid_q[enqueue_index],
                                         slot_root_ppn_q[enqueue_index]) &&
                    same_line(slot_vaddr_q[enqueue_index],
                        retire_age_addr_i[
                            enqueue_age_port*ADDR_WIDTH +: ADDR_WIDTH]))
                    age_duplicate_r[enqueue_age_port] = 1'b1;
            end
            if (prefetch_valid_i &&
                (same_line(prefetch_taken_addr_i,
                    retire_age_addr_i[
                        enqueue_age_port*ADDR_WIDTH +: ADDR_WIDTH]) ||
                 same_line(prefetch_fallthrough_addr_i,
                    retire_age_addr_i[
                        enqueue_age_port*ADDR_WIDTH +: ADDR_WIDTH])))
                age_duplicate_r[enqueue_age_port] = 1'b1;

            free_found_r = 1'b0;
            if (retire_age_valid_i[enqueue_age_port] &&
                !age_duplicate_r[enqueue_age_port]) begin
                for (enqueue_index = 0; enqueue_index < PREFETCH_SLOTS;
                     enqueue_index = enqueue_index + 1) begin
                    if (!free_found_r &&
                        !enqueue_reserved_r[enqueue_index]) begin
                        enqueue_age_r[enqueue_age_port] = 1'b1;
                        enqueue_age_slot_r[
                            enqueue_age_port*PREFETCH_INDEX_WIDTH +:
                            PREFETCH_INDEX_WIDTH] =
                            enqueue_index[PREFETCH_INDEX_WIDTH-1:0];
                        enqueue_reserved_r[enqueue_index] = 1'b1;
                        free_found_r = 1'b1;
                    end
                end
            end
        end
    end

    reg xlate_active_q;
    reg [PREFETCH_INDEX_WIDTH-1:0] xlate_active_slot_q;

    assign xlate_req_valid_o = !xlate_active_q && xlate_slot_found_r &&
                               !prefetch_flush_i;
    assign xlate_req_vaddr_o = slot_vaddr_q[xlate_slot_r];
    assign xlate_req_priv_o = slot_priv_q[xlate_slot_r];
    assign xlate_req_vm_mode_o = slot_vm_mode_q[xlate_slot_r];
    assign xlate_req_asid_o = slot_asid_q[xlate_slot_r];
    assign xlate_req_root_ppn_o = slot_root_ppn_q[xlate_slot_r];
    assign xlate_req_sum_o = slot_sum_q[xlate_slot_r];
    assign xlate_req_mxr_o = slot_mxr_q[xlate_slot_r];
    assign xlate_resp_ready_o = xlate_active_q;

    wire l1_req_ready;
    wire l1_resp_valid;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] l1_req_rdata;
    wire l1_req_error;
    wire l1_mem_valid;
    wire l1_mem_ready;
    wire l1_mem_write;
    wire [ADDR_WIDTH-1:0] l1_mem_addr;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] l1_mem_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] l1_mem_wstrb;
    wire l1_mem_error;

    reg [1:0] backend_state_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] next_txn_id_q;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] request_txn_id_q;
    reg [ADDR_WIDTH-1:0] request_addr_q;

    wire response_identity_match =
        (ccx_resp_hart_id_i == HART_ID) &&
        (ccx_resp_source_id_i == `OPENRV64_CCX_SOURCE_ICACHE) &&
        (ccx_resp_txn_id_i == request_txn_id_q);
    wire response_geometry_error =
        (ccx_resp_beat_index_i !=
         {`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}}) ||
        !ccx_resp_last_i || ccx_resp_sc_success_i;
    wire response_fire = ccx_resp_valid_i && ccx_resp_ready_o;

    wire response_full =
        response_count_q == DEMAND_COUNT_WIDTH'(DEMAND_DEPTH);
    wire cache_can_launch = !cache_active_q &&
                            (response_count_q == 0) &&
                            invalidate_ready_o && !invalidate_valid_i;
    wire launch_prefetch = cache_can_launch && !req_valid_i &&
                           fill_slot_found_r;
    wire select_demand = req_valid_i;
    wire select_prefetch = !select_demand && cache_active_q &&
                           !l1_request_sent_q;
    wire l1_input_valid = (select_demand || select_prefetch) &&
                          !response_full;
    wire l1_request_fire = l1_input_valid && l1_req_ready;
    wire response_is_prefetch = (response_count_q != 0) &&
        response_prefetch_q[response_head_q];
    wire l1_resp_ready = (response_count_q != 0) &&
        (response_is_prefetch || resp_ready_i);
    wire l1_response_fire = l1_resp_valid && l1_resp_ready;
    wire cache_age_match_now = cache_active_q && cache_prefetch_q &&
        same_current_context(cache_vm_mode_q, cache_asid_q,
                             cache_root_ppn_q) &&
        ((retire_age_valid_i[0] &&
          same_line(cache_vaddr_q, retire_age_addr_i[0*ADDR_WIDTH +:
                                                     ADDR_WIDTH])) ||
         (retire_age_valid_i[1] &&
          same_line(cache_vaddr_q, retire_age_addr_i[1*ADDR_WIDTH +:
                                                     ADDR_WIDTH])) ||
         (retire_age_valid_i[2] &&
          same_line(cache_vaddr_q, retire_age_addr_i[2*ADDR_WIDTH +:
                                                     ADDR_WIDTH])));
    wire fill_age_match_now = fill_slot_found_r &&
        same_current_context(slot_vm_mode_q[fill_slot_r],
                             slot_asid_q[fill_slot_r],
                             slot_root_ppn_q[fill_slot_r]) &&
        ((retire_age_valid_i[0] &&
          same_line(slot_vaddr_q[fill_slot_r],
                    retire_age_addr_i[0*ADDR_WIDTH +: ADDR_WIDTH])) ||
         (retire_age_valid_i[1] &&
          same_line(slot_vaddr_q[fill_slot_r],
                    retire_age_addr_i[1*ADDR_WIDTH +: ADDR_WIDTH])) ||
         (retire_age_valid_i[2] &&
          same_line(slot_vaddr_q[fill_slot_r],
                    retire_age_addr_i[2*ADDR_WIDTH +: ADDR_WIDTH])));
    wire prefetch_complete_age = response_is_prefetch &&
        (cache_aged_q || cache_age_match_now) && l1_resp_valid;
    wire [3:0] l1_age_valid = {2'b00, prefetch_complete_age,
                               age_slot_found_r};
    wire [4*ADDR_WIDTH-1:0] l1_age_addr = {
        {2*ADDR_WIDTH{1'b0}}, cache_paddr_q,
        slot_paddr_q[age_slot_r]
    };

    assign req_ready_o = l1_req_ready && !response_full &&
                         !invalidate_valid_i;
    assign resp_valid_o = l1_resp_valid &&
                          (response_count_q != 0) &&
                          !response_is_prefetch;
    assign req_rdata_o = response_upper_half_q[response_head_q] ?
                         l1_req_rdata[511:256] :
                         l1_req_rdata[255:0];
    assign req_error_o = resp_valid_o && l1_req_error;

    assign ccx_req_valid_o = (backend_state_q == BACKEND_SEND);
    assign ccx_req_hart_id_o = HART_ID;
    assign ccx_req_source_id_o = `OPENRV64_CCX_SOURCE_ICACHE;
    assign ccx_req_txn_id_o = request_txn_id_q;
    assign ccx_req_op_o = `OPENRV64_CCX_OP_READ;
    assign ccx_req_order_o = `OPENRV64_CCX_ORDER_NONE;
    assign ccx_req_kind_o = `OPENRV64_CCX_KIND_FETCH;
    assign ccx_req_attr_o = `OPENRV64_CCX_ATTR_CACHEABLE |
                            `OPENRV64_CCX_ATTR_EXECUTABLE;
    assign ccx_req_size_o = 3'd6;
    assign ccx_req_addr_o = request_addr_q;
    assign ccx_req_burst_len_o =
        {`OPENRV64_CCX_BURST_LEN_WIDTH{1'b0}};

    assign ccx_resp_ready_o = (backend_state_q == BACKEND_WAIT) &&
                              response_identity_match;
    assign l1_mem_ready = response_fire;
    assign l1_mem_error = response_fire &&
                          (ccx_resp_error_i || response_geometry_error);

    openrv64_l1i #(
        .ENABLE(ENABLE),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(`OPENRV64_CCX_LINE_DATA_WIDTH),
        .CACHE_BYTES(CACHE_BYTES),
        .LINE_BYTES(`OPENRV64_CCX_LINE_BYTES),
        .WAYS(WAYS),
        .WRITEBACK_TIMEOUT_CYCLES(WRITEBACK_TIMEOUT_CYCLES),
        .DIRTY_TIMESTAMP_WIDTH(DIRTY_TIMESTAMP_WIDTH)
    ) u_l1i (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .req_valid_i(l1_input_valid),
        .req_ready_o(l1_req_ready),
        .req_cacheable_i(select_demand ? req_cacheable_i :
                                           cache_cacheable_q),
        .req_addr_i(select_demand ? req_addr_i : cache_vaddr_q),
        .req_phys_addr_i(select_demand ? req_phys_addr_i : cache_paddr_q),
        .req_prefetch_i(select_prefetch),
        .req_aged_i(select_prefetch &&
                    (cache_aged_q || cache_age_match_now)),
        .resp_valid_o(l1_resp_valid),
        .resp_ready_i(l1_resp_ready),
        .req_rdata_o(l1_req_rdata),
        .req_error_o(l1_req_error),
        .invalidate_valid_i(invalidate_valid_i),
        .invalidate_ready_o(invalidate_ready_o),
        .invalidate_all_i(invalidate_all_i),
        .invalidate_addr_i(invalidate_addr_i),
        .age_valid_i(l1_age_valid),
        .age_addr_i(l1_age_addr),
        .mem_valid_o(l1_mem_valid),
        .mem_ready_i(l1_mem_ready),
        .mem_write_o(l1_mem_write),
        .mem_addr_o(l1_mem_addr),
        .mem_wdata_o(l1_mem_wdata),
        .mem_wstrb_o(l1_mem_wstrb),
        .mem_rdata_i(ccx_resp_rdata_i),
        .mem_error_i(l1_mem_error)
    );

    integer slot_index;
    integer retire_age_port;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cache_active_q <= 1'b0;
            cache_prefetch_q <= 1'b0;
            cache_cacheable_q <= 1'b0;
            cache_aged_q <= 1'b0;
            l1_request_sent_q <= 1'b0;
            cache_vaddr_q <= {ADDR_WIDTH{1'b0}};
            cache_paddr_q <= {ADDR_WIDTH{1'b0}};
            cache_vm_mode_q <= `RV64_SATP_MODE_BARE;
            cache_asid_q <= {`RV64_SATP_ASID_WIDTH{1'b0}};
            cache_root_ppn_q <= {`RV64_SATP_PPN_WIDTH{1'b0}};
            response_head_q <= {DEMAND_INDEX_WIDTH{1'b0}};
            response_tail_q <= {DEMAND_INDEX_WIDTH{1'b0}};
            response_count_q <= {DEMAND_COUNT_WIDTH{1'b0}};
            xlate_active_q <= 1'b0;
            xlate_active_slot_q <=
                {PREFETCH_INDEX_WIDTH{1'b0}};
            for (slot_index = 0; slot_index < PREFETCH_SLOTS;
                 slot_index = slot_index + 1) begin
                slot_valid_q[slot_index] <= 1'b0;
                slot_age_only_q[slot_index] <= 1'b0;
                slot_translating_q[slot_index] <= 1'b0;
                slot_translated_q[slot_index] <= 1'b0;
                slot_aged_q[slot_index] <= 1'b0;
                slot_vaddr_q[slot_index] <= {ADDR_WIDTH{1'b0}};
                slot_paddr_q[slot_index] <= {ADDR_WIDTH{1'b0}};
                slot_priv_q[slot_index] <= `RV64_PRIV_M;
                slot_vm_mode_q[slot_index] <= `RV64_SATP_MODE_BARE;
                slot_asid_q[slot_index] <=
                    {`RV64_SATP_ASID_WIDTH{1'b0}};
                slot_root_ppn_q[slot_index] <=
                    {`RV64_SATP_PPN_WIDTH{1'b0}};
                slot_sum_q[slot_index] <= 1'b0;
                slot_mxr_q[slot_index] <= 1'b0;
            end
            for (response_reset_index = 0;
                 response_reset_index < DEMAND_DEPTH;
                 response_reset_index = response_reset_index + 1) begin
                response_prefetch_q[response_reset_index] <= 1'b0;
                response_upper_half_q[response_reset_index] <= 1'b0;
            end
        end else begin
            if (l1_request_fire) begin
                response_prefetch_q[response_tail_q] <= select_prefetch;
                response_upper_half_q[response_tail_q] <=
                    select_demand ? req_addr_i[5] : cache_vaddr_q[5];
                response_tail_q <=
                    (response_tail_q ==
                     DEMAND_INDEX_WIDTH'(DEMAND_DEPTH - 1)) ?
                    {DEMAND_INDEX_WIDTH{1'b0}} :
                    response_tail_q + 1'b1;
                if (select_prefetch)
                    l1_request_sent_q <= 1'b1;
            end

            if (l1_response_fire) begin
                response_head_q <=
                    (response_head_q ==
                     DEMAND_INDEX_WIDTH'(DEMAND_DEPTH - 1)) ?
                    {DEMAND_INDEX_WIDTH{1'b0}} :
                    response_head_q + 1'b1;
            end

            case ({l1_request_fire, l1_response_fire})
                2'b10: response_count_q <= response_count_q + 1'b1;
                2'b01: response_count_q <= response_count_q - 1'b1;
                default: response_count_q <= response_count_q;
            endcase

            if (l1_response_fire && response_is_prefetch) begin
                cache_active_q <= 1'b0;
                l1_request_sent_q <= 1'b0;
            end

            if (launch_prefetch) begin
                cache_active_q <= 1'b1;
                l1_request_sent_q <= 1'b0;
                cache_prefetch_q <= 1'b1;
                cache_cacheable_q <= 1'b1;
                cache_aged_q <= slot_aged_q[fill_slot_r] ||
                                 fill_age_match_now;
                cache_vaddr_q <= slot_vaddr_q[fill_slot_r];
                cache_paddr_q <= slot_paddr_q[fill_slot_r];
                cache_vm_mode_q <= slot_vm_mode_q[fill_slot_r];
                cache_asid_q <= slot_asid_q[fill_slot_r];
                cache_root_ppn_q <= slot_root_ppn_q[fill_slot_r];
                slot_valid_q[fill_slot_r] <= 1'b0;
            end

            if (cache_age_match_now)
                cache_aged_q <= 1'b1;

            if (age_slot_found_r)
                slot_valid_q[age_slot_r] <= 1'b0;

            if (xlate_req_valid_o && xlate_req_ready_i) begin
                xlate_active_q <= 1'b1;
                xlate_active_slot_q <= xlate_slot_r;
                slot_translating_q[xlate_slot_r] <= 1'b1;
            end
            if (xlate_resp_valid_i && xlate_resp_ready_o) begin
                xlate_active_q <= 1'b0;
                if (slot_valid_q[xlate_active_slot_q]) begin
                    slot_translating_q[xlate_active_slot_q] <= 1'b0;
                    if (xlate_resp_fault_i) begin
                        slot_valid_q[xlate_active_slot_q] <= 1'b0;
                    end else begin
                        slot_paddr_q[xlate_active_slot_q] <=
                            xlate_resp_paddr_i;
                        slot_translated_q[xlate_active_slot_q] <= 1'b1;
                    end
                end
            end

            for (retire_age_port = 0; retire_age_port < 3;
                 retire_age_port = retire_age_port + 1) begin
                if (retire_age_valid_i[retire_age_port]) begin
                    for (slot_index = 0; slot_index < PREFETCH_SLOTS;
                         slot_index = slot_index + 1) begin
                        if (slot_valid_q[slot_index] &&
                            !slot_age_only_q[slot_index] &&
                            same_current_context(
                                slot_vm_mode_q[slot_index],
                                slot_asid_q[slot_index],
                                slot_root_ppn_q[slot_index]) &&
                            same_line(slot_vaddr_q[slot_index],
                                retire_age_addr_i[
                                    retire_age_port*ADDR_WIDTH +:
                                    ADDR_WIDTH]))
                            slot_aged_q[slot_index] <= 1'b1;
                    end
                end
            end

            if (enqueue_taken_r) begin
                slot_valid_q[enqueue_taken_slot_r] <= 1'b1;
                slot_age_only_q[enqueue_taken_slot_r] <= 1'b0;
                slot_translating_q[enqueue_taken_slot_r] <= 1'b0;
                slot_translated_q[enqueue_taken_slot_r] <= 1'b0;
                slot_aged_q[enqueue_taken_slot_r] <=
                    (retire_age_valid_i[0] &&
                     same_line(prefetch_taken_addr_i,
                               retire_age_addr_i[0*ADDR_WIDTH +:
                                                  ADDR_WIDTH])) ||
                    (retire_age_valid_i[1] &&
                     same_line(prefetch_taken_addr_i,
                               retire_age_addr_i[1*ADDR_WIDTH +:
                                                  ADDR_WIDTH])) ||
                    (retire_age_valid_i[2] &&
                     same_line(prefetch_taken_addr_i,
                               retire_age_addr_i[2*ADDR_WIDTH +:
                                                  ADDR_WIDTH]));
                slot_vaddr_q[enqueue_taken_slot_r] <=
                    {prefetch_taken_addr_i[ADDR_WIDTH-1:6], 6'b000000};
                slot_paddr_q[enqueue_taken_slot_r] <= {ADDR_WIDTH{1'b0}};
                slot_priv_q[enqueue_taken_slot_r] <= prefetch_priv_i;
                slot_vm_mode_q[enqueue_taken_slot_r] <= prefetch_vm_mode_i;
                slot_asid_q[enqueue_taken_slot_r] <= prefetch_asid_i;
                slot_root_ppn_q[enqueue_taken_slot_r] <=
                    prefetch_root_ppn_i;
                slot_sum_q[enqueue_taken_slot_r] <= prefetch_sum_i;
                slot_mxr_q[enqueue_taken_slot_r] <= prefetch_mxr_i;
            end
            if (enqueue_fallthrough_r) begin
                slot_valid_q[enqueue_fallthrough_slot_r] <= 1'b1;
                slot_age_only_q[enqueue_fallthrough_slot_r] <= 1'b0;
                slot_translating_q[enqueue_fallthrough_slot_r] <= 1'b0;
                slot_translated_q[enqueue_fallthrough_slot_r] <= 1'b0;
                slot_aged_q[enqueue_fallthrough_slot_r] <=
                    (retire_age_valid_i[0] &&
                     same_line(prefetch_fallthrough_addr_i,
                               retire_age_addr_i[0*ADDR_WIDTH +:
                                                  ADDR_WIDTH])) ||
                    (retire_age_valid_i[1] &&
                     same_line(prefetch_fallthrough_addr_i,
                               retire_age_addr_i[1*ADDR_WIDTH +:
                                                  ADDR_WIDTH])) ||
                    (retire_age_valid_i[2] &&
                     same_line(prefetch_fallthrough_addr_i,
                               retire_age_addr_i[2*ADDR_WIDTH +:
                                                  ADDR_WIDTH]));
                slot_vaddr_q[enqueue_fallthrough_slot_r] <=
                    {prefetch_fallthrough_addr_i[ADDR_WIDTH-1:6],
                     6'b000000};
                slot_paddr_q[enqueue_fallthrough_slot_r] <=
                    {ADDR_WIDTH{1'b0}};
                slot_priv_q[enqueue_fallthrough_slot_r] <= prefetch_priv_i;
                slot_vm_mode_q[enqueue_fallthrough_slot_r] <=
                    prefetch_vm_mode_i;
                slot_asid_q[enqueue_fallthrough_slot_r] <= prefetch_asid_i;
                slot_root_ppn_q[enqueue_fallthrough_slot_r] <=
                    prefetch_root_ppn_i;
                slot_sum_q[enqueue_fallthrough_slot_r] <= prefetch_sum_i;
                slot_mxr_q[enqueue_fallthrough_slot_r] <= prefetch_mxr_i;
            end
            for (retire_age_port = 0; retire_age_port < 3;
                 retire_age_port = retire_age_port + 1) begin
                if (enqueue_age_r[retire_age_port]) begin
                    slot_valid_q[enqueue_age_slot_r[
                        retire_age_port*PREFETCH_INDEX_WIDTH +:
                        PREFETCH_INDEX_WIDTH]] <= 1'b1;
                    slot_age_only_q[enqueue_age_slot_r[
                        retire_age_port*PREFETCH_INDEX_WIDTH +:
                        PREFETCH_INDEX_WIDTH]] <= 1'b1;
                    slot_translating_q[enqueue_age_slot_r[
                        retire_age_port*PREFETCH_INDEX_WIDTH +:
                        PREFETCH_INDEX_WIDTH]] <= 1'b0;
                    slot_translated_q[enqueue_age_slot_r[
                        retire_age_port*PREFETCH_INDEX_WIDTH +:
                        PREFETCH_INDEX_WIDTH]] <= 1'b0;
                    slot_aged_q[enqueue_age_slot_r[
                        retire_age_port*PREFETCH_INDEX_WIDTH +:
                        PREFETCH_INDEX_WIDTH]] <= 1'b1;
                    slot_vaddr_q[enqueue_age_slot_r[
                        retire_age_port*PREFETCH_INDEX_WIDTH +:
                        PREFETCH_INDEX_WIDTH]] <= {
                            retire_age_addr_i[
                                retire_age_port*ADDR_WIDTH + 6 +:
                                ADDR_WIDTH-6], 6'b000000};
                    slot_paddr_q[enqueue_age_slot_r[
                        retire_age_port*PREFETCH_INDEX_WIDTH +:
                        PREFETCH_INDEX_WIDTH]] <= {ADDR_WIDTH{1'b0}};
                    slot_priv_q[enqueue_age_slot_r[
                        retire_age_port*PREFETCH_INDEX_WIDTH +:
                        PREFETCH_INDEX_WIDTH]] <= prefetch_priv_i;
                    slot_vm_mode_q[enqueue_age_slot_r[
                        retire_age_port*PREFETCH_INDEX_WIDTH +:
                        PREFETCH_INDEX_WIDTH]] <= prefetch_vm_mode_i;
                    slot_asid_q[enqueue_age_slot_r[
                        retire_age_port*PREFETCH_INDEX_WIDTH +:
                        PREFETCH_INDEX_WIDTH]] <= prefetch_asid_i;
                    slot_root_ppn_q[enqueue_age_slot_r[
                        retire_age_port*PREFETCH_INDEX_WIDTH +:
                        PREFETCH_INDEX_WIDTH]] <= prefetch_root_ppn_i;
                    slot_sum_q[enqueue_age_slot_r[
                        retire_age_port*PREFETCH_INDEX_WIDTH +:
                        PREFETCH_INDEX_WIDTH]] <= prefetch_sum_i;
                    slot_mxr_q[enqueue_age_slot_r[
                        retire_age_port*PREFETCH_INDEX_WIDTH +:
                        PREFETCH_INDEX_WIDTH]] <= prefetch_mxr_i;
                end
            end

            if (prefetch_flush_i) begin
                for (slot_index = 0; slot_index < PREFETCH_SLOTS;
                     slot_index = slot_index + 1)
                    slot_valid_q[slot_index] <= 1'b0;
            end
        end
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            backend_state_q <= BACKEND_IDLE;
            next_txn_id_q <= {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
            request_txn_id_q <= {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
            request_addr_q <= {ADDR_WIDTH{1'b0}};
        end else begin
            case (backend_state_q)
                BACKEND_IDLE: begin
                    if (l1_mem_valid) begin
                        request_txn_id_q <= next_txn_id_q;
                        request_addr_q <= {
                            l1_mem_addr[ADDR_WIDTH-1:6], 6'b000000
                        };
                        backend_state_q <= BACKEND_SEND;
                    end
                end

                BACKEND_SEND: begin
                    if (ccx_req_valid_o && ccx_req_ready_i) begin
                        next_txn_id_q <= next_txn_id_q + 1'b1;
                        backend_state_q <= BACKEND_WAIT;
                    end
                end

                BACKEND_WAIT: begin
                    if (response_fire)
                        backend_state_q <= BACKEND_IDLE;
                end

                default: backend_state_q <= BACKEND_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (rst_ni && l1_mem_write)
            $fatal(1, "L1I attempted a native CCX line write");
        if (rst_ni && (backend_state_q != BACKEND_IDLE) && !l1_mem_valid)
            $fatal(1, "L1I dropped a line miss before CCX completion");
    end
`endif

endmodule
