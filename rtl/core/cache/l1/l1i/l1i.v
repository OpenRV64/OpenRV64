`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/isa/rv64-priv.v"

// Public composition for the 256-bit frontend view of a native 512-bit ICX
// instruction-cache endpoint.
//
// The private cache stores a complete 64-byte line in one data word.  A
// frontend request selects either 256-bit half of that resident line.  A miss
// emits one native ICX command and consumes one native 512-bit response beat;
// it is never decomposed into scalar compatibility requests.
module openrv64_l1i_icx #(
    parameter integer ENABLE = 1,
    parameter integer ADDR_WIDTH = 64,
    parameter integer CACHE_BYTES = 16 * 1024,
    parameter integer WAYS = 4,
    parameter integer FILL_BUFFER_LINES = 8,
    parameter integer PREFETCH_SLOTS = FILL_BUFFER_LINES,
    parameter integer DEMAND_DEPTH = 8,
    parameter integer DEMAND_MSHRS = 4,
    parameter integer REQ_TAG_WIDTH = 1,
    parameter integer WRITEBACK_TIMEOUT_CYCLES = 128,
    parameter integer DIRTY_TIMESTAMP_WIDTH =
        (WRITEBACK_TIMEOUT_CYCLES < 2) ? 1 :
        $clog2(WRITEBACK_TIMEOUT_CYCLES + 1),
    parameter [`OPENRV64_ICX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}}
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,

    input  wire                         req_valid_i,
    output wire                         req_ready_o,
    input  wire                         req_cacheable_i,
    input  wire [REQ_TAG_WIDTH-1:0]     req_tag_i,
    input  wire [ADDR_WIDTH-1:0]        req_addr_i,
    input  wire [ADDR_WIDTH-1:0]        req_phys_addr_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  req_priv_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] req_vm_mode_i,
    input  wire [`RV64_SATP_ASID_WIDTH-1:0] req_asid_i,
    input  wire [`RV64_SATP_PPN_WIDTH-1:0] req_root_ppn_i,
    input  wire                         req_sum_i,
    input  wire                         req_mxr_i,
    output wire                         resp_valid_o,
    input  wire                         resp_ready_i,
    output wire [REQ_TAG_WIDTH-1:0]     resp_tag_o,
    output wire [255:0]                 req_rdata_o,
    output wire                         req_error_o,

    // Conditional-branch hints are virtual.  L1I retains both paths and
    // requests translation below; no speculative fault is architectural.
    input  wire                         m_mode_prefetch_enable_i,
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

    output wire                         icx_req_valid_o,
    input  wire                         icx_req_ready_i,
    output wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                        icx_req_hart_id_o,
    output wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                        icx_req_source_id_o,
    output wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                        icx_req_txn_id_o,
    output wire [`OPENRV64_ICX_OP_WIDTH-1:0]
                                        icx_req_op_o,
    output wire [`OPENRV64_ICX_ORDER_WIDTH-1:0]
                                        icx_req_order_o,
    output wire [`OPENRV64_ICX_KIND_WIDTH-1:0]
                                        icx_req_kind_o,
    output wire [`OPENRV64_ICX_ATTR_WIDTH-1:0]
                                        icx_req_attr_o,
    output wire [2:0]                   icx_req_size_o,
    output wire [ADDR_WIDTH-1:0]        icx_req_addr_o,
    output wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0]
                                        icx_req_burst_len_o,

    input  wire                         icx_resp_valid_i,
    output wire                         icx_resp_ready_o,
    input  wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0]
                                        icx_resp_hart_id_i,
    input  wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                        icx_resp_source_id_i,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0]
                                        icx_resp_txn_id_i,
    input  wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
                                        icx_resp_rdata_i,
    input  wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
                                        icx_resp_beat_index_i,
    input  wire                         icx_resp_last_i,
    input  wire                         icx_resp_error_i,
    input  wire                         icx_resp_sc_success_i
);

    localparam integer PREFETCH_INDEX_WIDTH =
        (PREFETCH_SLOTS > 1) ? $clog2(PREFETCH_SLOTS) : 1;
    localparam integer DEMAND_INDEX_WIDTH =
        (DEMAND_DEPTH > 1) ? $clog2(DEMAND_DEPTH) : 1;
    localparam integer DEMAND_COUNT_WIDTH =
        $clog2(DEMAND_DEPTH + 1);
    localparam integer DEMAND_MSHR_INDEX_WIDTH =
        (DEMAND_MSHRS > 1) ? $clog2(DEMAND_MSHRS) : 1;
    localparam integer ICX_TXN_COUNT =
        1 << `OPENRV64_ICX_TXN_ID_WIDTH;

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
        if ((DEMAND_MSHRS < 1) || (DEMAND_MSHRS > ICX_TXN_COUNT))
            $fatal(1,
                   "L1I demand MSHRs must fit native ICX transaction IDs");
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

    // A short rolling filter prevents hot branches from repeatedly probing a
    // line that their earlier hint already covered.  It is deliberately only
    // PREFETCH_SLOTS deep: old lines become eligible again as the instruction
    // working set moves, rather than being suppressed until eviction.
    reg recent_valid_q [0:PREFETCH_SLOTS-1];
    reg [ADDR_WIDTH-1:0] recent_vaddr_q [0:PREFETCH_SLOTS-1];
    reg [`RV64_SATP_MODE_WIDTH-1:0]
        recent_vm_mode_q [0:PREFETCH_SLOTS-1];
    reg [`RV64_SATP_ASID_WIDTH-1:0]
        recent_asid_q [0:PREFETCH_SLOTS-1];
    reg [`RV64_SATP_PPN_WIDTH-1:0]
        recent_root_ppn_q [0:PREFETCH_SLOTS-1];
    reg [PREFETCH_INDEX_WIDTH-1:0] recent_replace_q;
    wire [PREFETCH_INDEX_WIDTH-1:0] recent_replace_next =
        (recent_replace_q ==
         PREFETCH_INDEX_WIDTH'(PREFETCH_SLOTS - 1)) ?
        {PREFETCH_INDEX_WIDTH{1'b0}} : recent_replace_q + 1'b1;
    wire [PREFETCH_INDEX_WIDTH-1:0] recent_replace_next2 =
        (recent_replace_next ==
         PREFETCH_INDEX_WIDTH'(PREFETCH_SLOTS - 1)) ?
        {PREFETCH_INDEX_WIDTH{1'b0}} : recent_replace_next + 1'b1;
    wire [PREFETCH_INDEX_WIDTH-1:0] recent_replace_next3 =
        (recent_replace_next2 ==
         PREFETCH_INDEX_WIDTH'(PREFETCH_SLOTS - 1)) ?
        {PREFETCH_INDEX_WIDTH{1'b0}} : recent_replace_next2 + 1'b1;

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
    reg enqueue_sequential_r;
    reg enqueue_taken_r;
    reg enqueue_fallthrough_r;
    reg [PREFETCH_INDEX_WIDTH-1:0] enqueue_sequential_slot_r;
    reg [PREFETCH_INDEX_WIDTH-1:0] enqueue_taken_slot_r;
    reg [PREFETCH_INDEX_WIDTH-1:0] enqueue_fallthrough_slot_r;
    reg [2:0] enqueue_age_r;
    reg [3*PREFETCH_INDEX_WIDTH-1:0] enqueue_age_slot_r;
    reg sequential_duplicate_r;
    reg taken_duplicate_r;
    reg fallthrough_duplicate_r;
    reg [2:0] age_duplicate_r;
    reg free_found_r;
    integer enqueue_index;
    integer enqueue_age_port;
    wire next_line_consume;
    wire [ADDR_WIDTH-1:0] next_line_vaddr;
    wire [`RV64_PRIV_WIDTH-1:0] next_line_priv;
    wire [`RV64_SATP_MODE_WIDTH-1:0] next_line_vm_mode;
    wire [`RV64_SATP_ASID_WIDTH-1:0] next_line_asid;
    wire [`RV64_SATP_PPN_WIDTH-1:0] next_line_root_ppn;
    wire next_line_sum;
    wire next_line_mxr;
    wire [PREFETCH_INDEX_WIDTH-1:0] recent_taken_index =
        enqueue_sequential_r ? recent_replace_next : recent_replace_q;
    wire [PREFETCH_INDEX_WIDTH-1:0] recent_fallthrough_index =
        enqueue_sequential_r ?
            (enqueue_taken_r ? recent_replace_next2 :
                               recent_replace_next) :
            (enqueue_taken_r ? recent_replace_next : recent_replace_q);

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
    reg response_valid_q [0:DEMAND_DEPTH-1];
    reg response_complete_q [0:DEMAND_DEPTH-1];
    reg response_prefetch_q [0:DEMAND_DEPTH-1];
    reg response_cacheable_q [0:DEMAND_DEPTH-1];
    reg [REQ_TAG_WIDTH-1:0] response_tag_q [0:DEMAND_DEPTH-1];
    reg [ADDR_WIDTH-1:0] response_vaddr_q [0:DEMAND_DEPTH-1];
    reg [`RV64_PRIV_WIDTH-1:0]
        response_priv_q [0:DEMAND_DEPTH-1];
    reg [`RV64_SATP_MODE_WIDTH-1:0]
        response_vm_mode_q [0:DEMAND_DEPTH-1];
    reg [`RV64_SATP_ASID_WIDTH-1:0]
        response_asid_q [0:DEMAND_DEPTH-1];
    reg [`RV64_SATP_PPN_WIDTH-1:0]
        response_root_ppn_q [0:DEMAND_DEPTH-1];
    reg response_sum_q [0:DEMAND_DEPTH-1];
    reg response_mxr_q [0:DEMAND_DEPTH-1];
    reg response_upper_half_q [0:DEMAND_DEPTH-1];
    reg response_wait_mshr_q [0:DEMAND_DEPTH-1];
    reg [DEMAND_MSHR_INDEX_WIDTH-1:0]
        response_mshr_q [0:DEMAND_DEPTH-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        response_data_q [0:DEMAND_DEPTH-1];
    reg response_error_q [0:DEMAND_DEPTH-1];
    reg [DEMAND_COUNT_WIDTH-1:0] response_count_q;
    wire response_free_found_r;
    wire [DEMAND_INDEX_WIDTH-1:0] response_free_index_r;
    wire response_complete_found_r;
    wire [DEMAND_INDEX_WIDTH-1:0] response_complete_index_r;
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

    function same_context;
        input [`RV64_SATP_MODE_WIDTH-1:0] left_vm_mode;
        input [`RV64_SATP_ASID_WIDTH-1:0] left_asid;
        input [`RV64_SATP_PPN_WIDTH-1:0] left_root_ppn;
        input [`RV64_SATP_MODE_WIDTH-1:0] right_vm_mode;
        input [`RV64_SATP_ASID_WIDTH-1:0] right_asid;
        input [`RV64_SATP_PPN_WIDTH-1:0] right_root_ppn;
        begin
            same_context =
                (left_vm_mode == right_vm_mode) &&
                (left_asid == right_asid) &&
                (left_root_ppn == right_root_ppn);
        end
    endfunction

    always @* begin
        enqueue_reserved_r = {PREFETCH_SLOTS{1'b0}};
        for (enqueue_index = 0; enqueue_index < PREFETCH_SLOTS;
             enqueue_index = enqueue_index + 1)
            enqueue_reserved_r[enqueue_index] = slot_valid_q[enqueue_index];

        sequential_duplicate_r = cache_active_q && cache_prefetch_q &&
            same_line(cache_vaddr_q, next_line_vaddr) &&
            same_context(cache_vm_mode_q, cache_asid_q,
                         cache_root_ppn_q, next_line_vm_mode,
                         next_line_asid, next_line_root_ppn);
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
                same_context(slot_vm_mode_q[enqueue_index],
                             slot_asid_q[enqueue_index],
                             slot_root_ppn_q[enqueue_index],
                             next_line_vm_mode, next_line_asid,
                             next_line_root_ppn) &&
                same_line(slot_vaddr_q[enqueue_index],
                          next_line_vaddr))
                sequential_duplicate_r = 1'b1;
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
            if (recent_valid_q[enqueue_index] &&
                same_context(recent_vm_mode_q[enqueue_index],
                             recent_asid_q[enqueue_index],
                             recent_root_ppn_q[enqueue_index],
                             next_line_vm_mode, next_line_asid,
                             next_line_root_ppn) &&
                same_line(recent_vaddr_q[enqueue_index],
                          next_line_vaddr))
                sequential_duplicate_r = 1'b1;
            if (recent_valid_q[enqueue_index] &&
                same_current_context(recent_vm_mode_q[enqueue_index],
                                     recent_asid_q[enqueue_index],
                                     recent_root_ppn_q[enqueue_index])) begin
                if (same_line(recent_vaddr_q[enqueue_index],
                              prefetch_taken_addr_i))
                    taken_duplicate_r = 1'b1;
                if (same_line(recent_vaddr_q[enqueue_index],
                              prefetch_fallthrough_addr_i))
                    fallthrough_duplicate_r = 1'b1;
            end
        end

        enqueue_sequential_r = 1'b0;
        enqueue_sequential_slot_r = {PREFETCH_INDEX_WIDTH{1'b0}};
        free_found_r = 1'b0;
        if (next_line_consume && !sequential_duplicate_r) begin
            for (enqueue_index = 0; enqueue_index < PREFETCH_SLOTS;
                 enqueue_index = enqueue_index + 1) begin
                if (!free_found_r && !enqueue_reserved_r[enqueue_index]) begin
                    enqueue_sequential_r = 1'b1;
                    enqueue_sequential_slot_r =
                        enqueue_index[PREFETCH_INDEX_WIDTH-1:0];
                    enqueue_reserved_r[enqueue_index] = 1'b1;
                    free_found_r = 1'b1;
                end
            end
        end

        if (enqueue_sequential_r &&
            same_context(next_line_vm_mode, next_line_asid,
                         next_line_root_ppn, prefetch_vm_mode_i,
                         prefetch_asid_i, prefetch_root_ppn_i)) begin
            if (same_line(next_line_vaddr, prefetch_taken_addr_i))
                taken_duplicate_r = 1'b1;
            if (same_line(next_line_vaddr, prefetch_fallthrough_addr_i))
                fallthrough_duplicate_r = 1'b1;
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
            if (enqueue_sequential_r &&
                same_context(next_line_vm_mode, next_line_asid,
                             next_line_root_ppn, prefetch_vm_mode_i,
                             prefetch_asid_i, prefetch_root_ppn_i) &&
                same_line(next_line_vaddr,
                    retire_age_addr_i[
                        enqueue_age_port*ADDR_WIDTH +: ADDR_WIDTH]))
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
    wire [DEMAND_INDEX_WIDTH-1:0] l1_resp_tag;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] l1_req_rdata;
    wire l1_req_error;
    wire l1_miss_valid;
    wire l1_miss_ready;
    wire [DEMAND_INDEX_WIDTH-1:0] l1_miss_tag;
    wire [ADDR_WIDTH-1:0] l1_miss_addr;
    wire l1_miss_aged;
    wire l1_fill_valid;
    wire l1_fill_ready;
    wire [ADDR_WIDTH-1:0] l1_fill_addr;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] l1_fill_data;
    wire l1_fill_aged;
    wire l1_invalidate_valid;
    wire l1_invalidate_ready;
    wire l1_mem_valid;
    wire l1_mem_ready;
    wire l1_mem_write;
    wire [ADDR_WIDTH-1:0] l1_mem_addr;
    wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] l1_mem_wdata;
    wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] l1_mem_wstrb;
    wire l1_mem_error;
    wire icx_issue_fire;
    wire icx_response_ready;
    wire response_fire;
    wire icx_response_for_icache;
    wire response_geometry_error;

    reg demand_mshr_valid_q [0:DEMAND_MSHRS-1];
    reg demand_mshr_issued_q [0:DEMAND_MSHRS-1];
    reg demand_mshr_complete_q [0:DEMAND_MSHRS-1];
    reg demand_mshr_fill_done_q [0:DEMAND_MSHRS-1];
    reg [ADDR_WIDTH-1:0] demand_mshr_addr_q [0:DEMAND_MSHRS-1];
    reg [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0]
        demand_mshr_data_q [0:DEMAND_MSHRS-1];
    reg demand_mshr_error_q [0:DEMAND_MSHRS-1];
    reg demand_mshr_aged_q [0:DEMAND_MSHRS-1];

    wire demand_mshr_match_found_r;
    wire [DEMAND_MSHR_INDEX_WIDTH-1:0] demand_mshr_match_index_r;
    wire demand_mshr_free_found_r;
    wire [DEMAND_MSHR_INDEX_WIDTH-1:0] demand_mshr_free_index_r;
    wire demand_mshr_issue_found_r;
    wire [DEMAND_MSHR_INDEX_WIDTH-1:0] demand_mshr_issue_index_r;
    wire demand_mshr_fill_found_r;
    wire [DEMAND_MSHR_INDEX_WIDTH-1:0] demand_mshr_fill_index_r;
    wire demand_mshr_finalize_found_r;
    wire [DEMAND_MSHR_INDEX_WIDTH-1:0] demand_mshr_finalize_index_r;
    wire demand_mshr_response_match_r;
    wire [DEMAND_MSHR_INDEX_WIDTH-1:0] demand_mshr_response_index_r;
    wire demand_mshr_any_valid_r;
    integer response_waiter_scan;
    integer demand_mshr_reset_index;

    reg issue_active_q;
    reg [DEMAND_MSHR_INDEX_WIDTH-1:0] issue_mshr_q;
    wire issue_valid = issue_active_q || demand_mshr_issue_found_r;
    wire [DEMAND_MSHR_INDEX_WIDTH-1:0] issue_index =
        issue_active_q ? issue_mshr_q : demand_mshr_issue_index_r;

    wire [DEMAND_MSHRS-1:0] demand_mshr_valid_vec;
    wire [DEMAND_MSHRS-1:0] demand_mshr_issued_vec;
    wire [DEMAND_MSHRS-1:0] demand_mshr_complete_vec;
    wire [DEMAND_MSHRS-1:0] demand_mshr_fill_done_vec;
    wire [DEMAND_MSHRS-1:0] demand_mshr_error_vec;
    wire [DEMAND_MSHRS*ADDR_WIDTH-1:0] demand_mshr_addr_vec;
    genvar demand_mshr_pack_index;
    generate
        for (demand_mshr_pack_index = 0;
             demand_mshr_pack_index < DEMAND_MSHRS;
             demand_mshr_pack_index = demand_mshr_pack_index + 1) begin :
                g_demand_mshr_pack
            assign demand_mshr_valid_vec[demand_mshr_pack_index] =
                demand_mshr_valid_q[demand_mshr_pack_index];
            assign demand_mshr_issued_vec[demand_mshr_pack_index] =
                demand_mshr_issued_q[demand_mshr_pack_index];
            assign demand_mshr_complete_vec[demand_mshr_pack_index] =
                demand_mshr_complete_q[demand_mshr_pack_index];
            assign demand_mshr_fill_done_vec[demand_mshr_pack_index] =
                demand_mshr_fill_done_q[demand_mshr_pack_index];
            assign demand_mshr_error_vec[demand_mshr_pack_index] =
                demand_mshr_error_q[demand_mshr_pack_index];
            assign demand_mshr_addr_vec[
                demand_mshr_pack_index*ADDR_WIDTH +: ADDR_WIDTH] =
                demand_mshr_addr_q[demand_mshr_pack_index];
        end
    endgenerate

    openrv64_l1i_demand_mshr_select #(
        .ENTRIES(DEMAND_MSHRS),
        .INDEX_WIDTH(DEMAND_MSHR_INDEX_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_demand_mshr_select (
        .valid_i(demand_mshr_valid_vec),
        .issued_i(demand_mshr_issued_vec),
        .complete_i(demand_mshr_complete_vec),
        .fill_done_i(demand_mshr_fill_done_vec),
        .error_i(demand_mshr_error_vec),
        .addr_i(demand_mshr_addr_vec),
        .miss_addr_i(l1_miss_addr),
        .response_for_icache_i(icx_response_for_icache),
        .response_txn_id_i(icx_resp_txn_id_i),
        .match_found_o(demand_mshr_match_found_r),
        .match_index_o(demand_mshr_match_index_r),
        .free_found_o(demand_mshr_free_found_r),
        .free_index_o(demand_mshr_free_index_r),
        .issue_found_o(demand_mshr_issue_found_r),
        .issue_index_o(demand_mshr_issue_index_r),
        .fill_found_o(demand_mshr_fill_found_r),
        .fill_index_o(demand_mshr_fill_index_r),
        .finalize_found_o(demand_mshr_finalize_found_r),
        .finalize_index_o(demand_mshr_finalize_index_r),
        .response_match_o(demand_mshr_response_match_r),
        .response_index_o(demand_mshr_response_index_r),
        .any_valid_o(demand_mshr_any_valid_r)
    );

    wire [DEMAND_DEPTH-1:0] response_valid_vec;
    wire [DEMAND_DEPTH-1:0] response_complete_vec;
    wire [DEMAND_DEPTH-1:0] response_prefetch_vec;
    genvar response_pack_index;
    generate
        for (response_pack_index = 0;
             response_pack_index < DEMAND_DEPTH;
             response_pack_index = response_pack_index + 1) begin :
                g_response_pack
            assign response_valid_vec[response_pack_index] =
                response_valid_q[response_pack_index];
            assign response_complete_vec[response_pack_index] =
                response_complete_q[response_pack_index];
            assign response_prefetch_vec[response_pack_index] =
                response_prefetch_q[response_pack_index];
        end
    endgenerate

    openrv64_l1i_frontend_select #(
        .DEPTH(DEMAND_DEPTH),
        .INDEX_WIDTH(DEMAND_INDEX_WIDTH)
    ) u_frontend_select (
        .valid_i(response_valid_vec),
        .complete_i(response_complete_vec),
        .prefetch_i(response_prefetch_vec),
        .free_found_o(response_free_found_r),
        .free_index_o(response_free_index_r),
        .complete_found_o(response_complete_found_r),
        .complete_index_o(response_complete_index_r)
    );

    wire response_selected_prefetch = response_complete_found_r &&
        response_prefetch_q[response_complete_index_r];
    wire stored_response_pop = response_complete_found_r &&
        (response_selected_prefetch || resp_ready_i);
    wire cache_can_launch = !cache_active_q &&
        (response_count_q < DEMAND_COUNT_WIDTH'(DEMAND_DEPTH - 1)) &&
        !invalidate_valid_i;
    wire launch_prefetch = cache_can_launch && !req_valid_i &&
                           fill_slot_found_r && !prefetch_flush_i;
    wire select_demand = req_valid_i;
    wire select_prefetch = !select_demand && cache_active_q &&
                           !l1_request_sent_q;
    wire l1_input_valid = (select_demand || select_prefetch) &&
                          response_free_found_r && !invalidate_valid_i;
    wire l1_request_fire = l1_input_valid && l1_req_ready;
    wire l1_miss_fire = l1_miss_valid && l1_miss_ready;
    wire l1_resp_ready = 1'b1;
    wire l1_response_fire = l1_resp_valid && l1_resp_ready;
    wire l1_response_known = l1_resp_valid &&
        response_valid_q[l1_resp_tag];
    wire l1_response_prefetch = l1_response_known &&
        response_prefetch_q[l1_resp_tag];
    // Preserve the original L1I-hit latency: when no older completed response
    // is waiting, forward the tagged SRAM hit directly instead of registering
    // it through the completion table.
    wire direct_response_selected =
        !response_complete_found_r && l1_response_known;
    wire direct_response_pop = direct_response_selected &&
        (l1_response_prefetch || resp_ready_i);
    wire response_pop = stored_response_pop || direct_response_pop;
    wire [DEMAND_INDEX_WIDTH-1:0] response_pop_index =
        stored_response_pop ? response_complete_index_r : l1_resp_tag;
    wire output_stored_response = response_complete_found_r &&
                                  !response_selected_prefetch;
    wire output_direct_response = !response_complete_found_r &&
                                  l1_response_known &&
                                  !l1_response_prefetch;
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
    wire prefetch_complete_age = l1_response_prefetch &&
        (cache_aged_q || cache_age_match_now);
    wire [3:0] l1_age_valid = {2'b00, prefetch_complete_age,
                               age_slot_found_r};
    wire [4*ADDR_WIDTH-1:0] l1_age_addr = {
        {2*ADDR_WIDTH{1'b0}}, cache_paddr_q,
        slot_paddr_q[age_slot_r]
    };

    assign req_ready_o = l1_req_ready && response_free_found_r &&
                         !invalidate_valid_i;
    assign resp_valid_o = output_stored_response ||
                          output_direct_response;
    assign resp_tag_o = output_stored_response ?
        response_tag_q[response_complete_index_r] :
        response_tag_q[l1_resp_tag];
    assign req_rdata_o = output_stored_response ?
        (response_upper_half_q[response_complete_index_r] ?
         response_data_q[response_complete_index_r][511:256] :
         response_data_q[response_complete_index_r][255:0]) :
        (response_upper_half_q[l1_resp_tag] ?
         l1_req_rdata[511:256] : l1_req_rdata[255:0]);
    assign req_error_o = output_stored_response ?
        response_error_q[response_complete_index_r] :
        (output_direct_response && l1_req_error);

    // A frontend response handshake is the cache's consumed-line event.  Queue
    // the following 64-byte virtual line through the same best-effort
    // translation/PMP/fill path as branch hints.  The rolling recent filter
    // suppresses the second 256-bit half and repeated fetches of the same line.
    assign next_line_consume = response_pop &&
        !response_prefetch_q[response_pop_index] &&
        response_cacheable_q[response_pop_index] && !req_error_o &&
        ((response_vm_mode_q[response_pop_index] ==
            `RV64_SATP_MODE_SV39) ||
         (m_mode_prefetch_enable_i &&
          (response_priv_q[response_pop_index] == `RV64_PRIV_M) &&
          (response_vm_mode_q[response_pop_index] ==
              `RV64_SATP_MODE_BARE))) &&
        !prefetch_flush_i && !invalidate_valid_i;
    assign next_line_vaddr =
        {response_vaddr_q[response_pop_index][ADDR_WIDTH-1:6], 6'b000000} +
        ADDR_WIDTH'(64);
    assign next_line_priv = response_priv_q[response_pop_index];
    assign next_line_vm_mode =
        response_vm_mode_q[response_pop_index];
    assign next_line_asid = response_asid_q[response_pop_index];
    assign next_line_root_ppn =
        response_root_ppn_q[response_pop_index];
    assign next_line_sum = response_sum_q[response_pop_index];
    assign next_line_mxr = response_mxr_q[response_pop_index];

    assign icx_response_ready = demand_mshr_response_match_r;

    openrv64_l1i_icx_interface #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .HART_ID(HART_ID)
    ) u_icx_interface (
        .issue_valid_i(issue_valid),
        .issue_txn_id_i(
            `OPENRV64_ICX_TXN_ID_WIDTH'(issue_index)),
        .issue_addr_i(demand_mshr_addr_q[issue_index]),
        .issue_fire_o(icx_issue_fire),
        .icx_req_valid_o(icx_req_valid_o),
        .icx_req_ready_i(icx_req_ready_i),
        .icx_req_hart_id_o(icx_req_hart_id_o),
        .icx_req_source_id_o(icx_req_source_id_o),
        .icx_req_txn_id_o(icx_req_txn_id_o),
        .icx_req_op_o(icx_req_op_o),
        .icx_req_order_o(icx_req_order_o),
        .icx_req_kind_o(icx_req_kind_o),
        .icx_req_attr_o(icx_req_attr_o),
        .icx_req_size_o(icx_req_size_o),
        .icx_req_addr_o(icx_req_addr_o),
        .icx_req_burst_len_o(icx_req_burst_len_o),
        .response_ready_i(icx_response_ready),
        .icx_resp_valid_i(icx_resp_valid_i),
        .icx_resp_ready_o(icx_resp_ready_o),
        .icx_resp_hart_id_i(icx_resp_hart_id_i),
        .icx_resp_source_id_i(icx_resp_source_id_i),
        .icx_resp_beat_index_i(icx_resp_beat_index_i),
        .icx_resp_last_i(icx_resp_last_i),
        .icx_resp_sc_success_i(icx_resp_sc_success_i),
        .response_fire_o(response_fire),
        .response_for_icache_o(icx_response_for_icache),
        .response_geometry_error_o(response_geometry_error)
    );

    assign l1_miss_ready = demand_mshr_match_found_r ?
        !(demand_mshr_finalize_found_r &&
          (demand_mshr_match_index_r ==
           demand_mshr_finalize_index_r)) :
        demand_mshr_free_found_r;
    assign l1_fill_valid = demand_mshr_fill_found_r;
    assign l1_fill_addr =
        demand_mshr_addr_q[demand_mshr_fill_index_r];
    assign l1_fill_data =
        demand_mshr_data_q[demand_mshr_fill_index_r];
    assign l1_fill_aged =
        demand_mshr_aged_q[demand_mshr_fill_index_r];

    wire l1_fill_fire = l1_fill_valid && l1_fill_ready;
    wire wrapper_quiescent = !demand_mshr_any_valid_r &&
        !issue_active_q && (response_count_q == 0) && !cache_active_q;
    assign l1_invalidate_valid = invalidate_valid_i &&
                                 wrapper_quiescent;
    assign invalidate_ready_o = wrapper_quiescent &&
                                l1_invalidate_ready;

    // Every request entering this native endpoint is cacheable.  Detached
    // misses use the explicit miss/fill ports; the shared L1 blocking memory
    // port must therefore remain idle.
    assign l1_mem_ready = 1'b0;
    assign l1_mem_error = 1'b0;

    openrv64_l1i #(
        .ENABLE(ENABLE),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(`OPENRV64_ICX_LINE_DATA_WIDTH),
        .REQ_TAG_WIDTH(DEMAND_INDEX_WIDTH),
        .DETACH_READ_MISSES(1),
        .CACHE_BYTES(CACHE_BYTES),
        .LINE_BYTES(`OPENRV64_ICX_LINE_BYTES),
        .WAYS(WAYS),
        .WRITEBACK_TIMEOUT_CYCLES(WRITEBACK_TIMEOUT_CYCLES),
        .DIRTY_TIMESTAMP_WIDTH(DIRTY_TIMESTAMP_WIDTH)
    ) u_l1i (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .req_valid_i(l1_input_valid),
        .req_ready_o(l1_req_ready),
        .req_tag_i(response_free_index_r),
        .req_cacheable_i(select_demand ? req_cacheable_i :
                                           cache_cacheable_q),
        .req_addr_i(select_demand ? req_addr_i : cache_vaddr_q),
        .req_phys_addr_i(select_demand ? req_phys_addr_i : cache_paddr_q),
        .req_prefetch_i(select_prefetch),
        .req_aged_i(select_prefetch &&
                    (cache_aged_q || cache_age_match_now)),
        .resp_valid_o(l1_resp_valid),
        .resp_ready_i(l1_resp_ready),
        .resp_tag_o(l1_resp_tag),
        .req_rdata_o(l1_req_rdata),
        .req_error_o(l1_req_error),
        .miss_valid_o(l1_miss_valid),
        .miss_ready_i(l1_miss_ready),
        .miss_tag_o(l1_miss_tag),
        .miss_addr_o(l1_miss_addr),
        .miss_aged_o(l1_miss_aged),
        .fill_valid_i(l1_fill_valid),
        .fill_ready_o(l1_fill_ready),
        .fill_addr_i(l1_fill_addr),
        .fill_data_i(l1_fill_data),
        .fill_aged_i(l1_fill_aged),
        .invalidate_valid_i(l1_invalidate_valid),
        .invalidate_ready_o(l1_invalidate_ready),
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
        .mem_rdata_i(icx_resp_rdata_i),
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
            response_count_q <= {DEMAND_COUNT_WIDTH{1'b0}};
            xlate_active_q <= 1'b0;
            xlate_active_slot_q <=
                {PREFETCH_INDEX_WIDTH{1'b0}};
            recent_replace_q <= {PREFETCH_INDEX_WIDTH{1'b0}};
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
                recent_valid_q[slot_index] <= 1'b0;
                recent_vaddr_q[slot_index] <= {ADDR_WIDTH{1'b0}};
                recent_vm_mode_q[slot_index] <=
                    `RV64_SATP_MODE_BARE;
                recent_asid_q[slot_index] <=
                    {`RV64_SATP_ASID_WIDTH{1'b0}};
                recent_root_ppn_q[slot_index] <=
                    {`RV64_SATP_PPN_WIDTH{1'b0}};
            end
            for (response_reset_index = 0;
                 response_reset_index < DEMAND_DEPTH;
                 response_reset_index = response_reset_index + 1) begin
                response_valid_q[response_reset_index] <= 1'b0;
                response_complete_q[response_reset_index] <= 1'b0;
                response_prefetch_q[response_reset_index] <= 1'b0;
                response_cacheable_q[response_reset_index] <= 1'b0;
                response_tag_q[response_reset_index] <=
                    {REQ_TAG_WIDTH{1'b0}};
                response_vaddr_q[response_reset_index] <=
                    {ADDR_WIDTH{1'b0}};
                response_priv_q[response_reset_index] <= `RV64_PRIV_M;
                response_vm_mode_q[response_reset_index] <=
                    `RV64_SATP_MODE_BARE;
                response_asid_q[response_reset_index] <=
                    {`RV64_SATP_ASID_WIDTH{1'b0}};
                response_root_ppn_q[response_reset_index] <=
                    {`RV64_SATP_PPN_WIDTH{1'b0}};
                response_sum_q[response_reset_index] <= 1'b0;
                response_mxr_q[response_reset_index] <= 1'b0;
                response_upper_half_q[response_reset_index] <= 1'b0;
                response_wait_mshr_q[response_reset_index] <= 1'b0;
                response_mshr_q[response_reset_index] <=
                    {DEMAND_MSHR_INDEX_WIDTH{1'b0}};
                response_data_q[response_reset_index] <=
                    {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
                response_error_q[response_reset_index] <= 1'b0;
            end
        end else begin
            if (l1_request_fire) begin
                response_valid_q[response_free_index_r] <= 1'b1;
                response_complete_q[response_free_index_r] <= 1'b0;
                response_prefetch_q[response_free_index_r] <=
                    select_prefetch;
                response_cacheable_q[response_free_index_r] <=
                    select_demand ? req_cacheable_i : cache_cacheable_q;
                response_tag_q[response_free_index_r] <= req_tag_i;
                response_vaddr_q[response_free_index_r] <=
                    select_demand ? req_addr_i : cache_vaddr_q;
                response_priv_q[response_free_index_r] <=
                    select_demand ? req_priv_i : `RV64_PRIV_M;
                response_vm_mode_q[response_free_index_r] <=
                    select_demand ? req_vm_mode_i :
                                    `RV64_SATP_MODE_BARE;
                response_asid_q[response_free_index_r] <=
                    select_demand ? req_asid_i :
                                    {`RV64_SATP_ASID_WIDTH{1'b0}};
                response_root_ppn_q[response_free_index_r] <=
                    select_demand ? req_root_ppn_i :
                                    {`RV64_SATP_PPN_WIDTH{1'b0}};
                response_sum_q[response_free_index_r] <=
                    select_demand && req_sum_i;
                response_mxr_q[response_free_index_r] <=
                    select_demand && req_mxr_i;
                response_upper_half_q[response_free_index_r] <=
                    select_demand ? req_addr_i[5] : cache_vaddr_q[5];
                response_wait_mshr_q[response_free_index_r] <=
                    l1_miss_fire;
                response_mshr_q[response_free_index_r] <=
                    demand_mshr_match_found_r ?
                    demand_mshr_match_index_r :
                    demand_mshr_free_index_r;
                response_error_q[response_free_index_r] <= 1'b0;
                if (select_prefetch)
                    l1_request_sent_q <= 1'b1;
            end

            if (l1_response_fire) begin
                response_complete_q[l1_resp_tag] <= 1'b1;
                response_wait_mshr_q[l1_resp_tag] <= 1'b0;
                response_data_q[l1_resp_tag] <= l1_req_rdata;
                response_error_q[l1_resp_tag] <= l1_req_error;
            end

            if (demand_mshr_finalize_found_r) begin
                for (response_waiter_scan = 0;
                     response_waiter_scan < DEMAND_DEPTH;
                     response_waiter_scan =
                         response_waiter_scan + 1) begin
                    if (response_valid_q[response_waiter_scan] &&
                        response_wait_mshr_q[response_waiter_scan] &&
                        (response_mshr_q[response_waiter_scan] ==
                         demand_mshr_finalize_index_r)) begin
                        response_complete_q[response_waiter_scan] <=
                            1'b1;
                        response_wait_mshr_q[response_waiter_scan] <=
                            1'b0;
                        response_data_q[response_waiter_scan] <=
                            demand_mshr_data_q[
                                demand_mshr_finalize_index_r];
                        response_error_q[response_waiter_scan] <=
                            demand_mshr_error_q[
                                demand_mshr_finalize_index_r];
                    end
                end
            end

            if (response_pop) begin
                response_valid_q[response_pop_index] <= 1'b0;
                response_complete_q[response_pop_index] <= 1'b0;
                response_wait_mshr_q[response_pop_index] <= 1'b0;
            end

            case ({l1_request_fire, response_pop})
                2'b10: response_count_q <= response_count_q + 1'b1;
                2'b01: response_count_q <= response_count_q - 1'b1;
                default: response_count_q <= response_count_q;
            endcase

            if (response_pop &&
                response_prefetch_q[response_pop_index]) begin
                cache_active_q <= 1'b0;
                l1_request_sent_q <= 1'b0;
            end
            if ((prefetch_flush_i || invalidate_valid_i) &&
                cache_active_q && !l1_request_sent_q)
                cache_active_q <= 1'b0;

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

            if (enqueue_sequential_r) begin
                slot_valid_q[enqueue_sequential_slot_r] <= 1'b1;
                slot_age_only_q[enqueue_sequential_slot_r] <= 1'b0;
                slot_translating_q[enqueue_sequential_slot_r] <= 1'b0;
                slot_translated_q[enqueue_sequential_slot_r] <= 1'b0;
                slot_aged_q[enqueue_sequential_slot_r] <= 1'b0;
                slot_vaddr_q[enqueue_sequential_slot_r] <=
                    next_line_vaddr;
                slot_paddr_q[enqueue_sequential_slot_r] <=
                    {ADDR_WIDTH{1'b0}};
                slot_priv_q[enqueue_sequential_slot_r] <= next_line_priv;
                slot_vm_mode_q[enqueue_sequential_slot_r] <=
                    next_line_vm_mode;
                slot_asid_q[enqueue_sequential_slot_r] <= next_line_asid;
                slot_root_ppn_q[enqueue_sequential_slot_r] <=
                    next_line_root_ppn;
                slot_sum_q[enqueue_sequential_slot_r] <= next_line_sum;
                slot_mxr_q[enqueue_sequential_slot_r] <= next_line_mxr;
                recent_valid_q[recent_replace_q] <= 1'b1;
                recent_vaddr_q[recent_replace_q] <= next_line_vaddr;
                recent_vm_mode_q[recent_replace_q] <= next_line_vm_mode;
                recent_asid_q[recent_replace_q] <= next_line_asid;
                recent_root_ppn_q[recent_replace_q] <= next_line_root_ppn;
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
                recent_valid_q[recent_taken_index] <= 1'b1;
                recent_vaddr_q[recent_taken_index] <=
                    {prefetch_taken_addr_i[ADDR_WIDTH-1:6], 6'b000000};
                recent_vm_mode_q[recent_taken_index] <= prefetch_vm_mode_i;
                recent_asid_q[recent_taken_index] <= prefetch_asid_i;
                recent_root_ppn_q[recent_taken_index] <=
                    prefetch_root_ppn_i;
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
                recent_valid_q[recent_fallthrough_index] <= 1'b1;
                recent_vaddr_q[recent_fallthrough_index] <=
                    {prefetch_fallthrough_addr_i[ADDR_WIDTH-1:6],
                     6'b000000};
                recent_vm_mode_q[recent_fallthrough_index] <=
                    prefetch_vm_mode_i;
                recent_asid_q[recent_fallthrough_index] <=
                    prefetch_asid_i;
                recent_root_ppn_q[recent_fallthrough_index] <=
                    prefetch_root_ppn_i;
            end
            case ({enqueue_sequential_r, enqueue_taken_r,
                   enqueue_fallthrough_r})
                3'b001,
                3'b010,
                3'b100: recent_replace_q <= recent_replace_next;
                3'b011,
                3'b101,
                3'b110: recent_replace_q <= recent_replace_next2;
                3'b111: recent_replace_q <= recent_replace_next3;
                default: recent_replace_q <= recent_replace_q;
            endcase
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
                     slot_index = slot_index + 1) begin
                    slot_valid_q[slot_index] <= 1'b0;
                    recent_valid_q[slot_index] <= 1'b0;
                end
            end
        end
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            issue_active_q <= 1'b0;
            issue_mshr_q <= {DEMAND_MSHR_INDEX_WIDTH{1'b0}};
            for (demand_mshr_reset_index = 0;
                 demand_mshr_reset_index < DEMAND_MSHRS;
                 demand_mshr_reset_index =
                     demand_mshr_reset_index + 1) begin
                demand_mshr_valid_q[demand_mshr_reset_index] <= 1'b0;
                demand_mshr_issued_q[demand_mshr_reset_index] <= 1'b0;
                demand_mshr_complete_q[demand_mshr_reset_index] <= 1'b0;
                demand_mshr_fill_done_q[demand_mshr_reset_index] <= 1'b0;
                demand_mshr_addr_q[demand_mshr_reset_index] <=
                    {ADDR_WIDTH{1'b0}};
                demand_mshr_data_q[demand_mshr_reset_index] <=
                    {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
                demand_mshr_error_q[demand_mshr_reset_index] <= 1'b0;
                demand_mshr_aged_q[demand_mshr_reset_index] <= 1'b0;
            end
        end else begin
            if (!issue_active_q && demand_mshr_issue_found_r &&
                !icx_issue_fire) begin
                issue_active_q <= 1'b1;
                issue_mshr_q <= demand_mshr_issue_index_r;
            end
            if (icx_issue_fire) begin
                issue_active_q <= 1'b0;
                demand_mshr_issued_q[issue_index] <= 1'b1;
            end

            if (l1_miss_fire) begin
                if (demand_mshr_match_found_r) begin
                    demand_mshr_aged_q[demand_mshr_match_index_r] <=
                        demand_mshr_aged_q[
                            demand_mshr_match_index_r] ||
                        l1_miss_aged;
                end else begin
                    demand_mshr_valid_q[demand_mshr_free_index_r] <=
                        1'b1;
                    demand_mshr_issued_q[demand_mshr_free_index_r] <=
                        1'b0;
                    demand_mshr_complete_q[demand_mshr_free_index_r] <=
                        1'b0;
                    demand_mshr_fill_done_q[demand_mshr_free_index_r] <=
                        1'b0;
                    demand_mshr_addr_q[demand_mshr_free_index_r] <=
                        l1_miss_addr;
                    demand_mshr_data_q[demand_mshr_free_index_r] <=
                        {`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}};
                    demand_mshr_error_q[demand_mshr_free_index_r] <=
                        1'b0;
                    demand_mshr_aged_q[demand_mshr_free_index_r] <=
                        l1_miss_aged;
                end
            end

            if (response_fire) begin
                demand_mshr_complete_q[
                    demand_mshr_response_index_r] <= 1'b1;
                demand_mshr_data_q[
                    demand_mshr_response_index_r] <= icx_resp_rdata_i;
                demand_mshr_error_q[
                    demand_mshr_response_index_r] <=
                    icx_resp_error_i || response_geometry_error;
            end

            if (l1_fill_fire)
                demand_mshr_fill_done_q[
                    demand_mshr_fill_index_r] <= 1'b1;

            if (demand_mshr_finalize_found_r) begin
                demand_mshr_valid_q[
                    demand_mshr_finalize_index_r] <= 1'b0;
                demand_mshr_issued_q[
                    demand_mshr_finalize_index_r] <= 1'b0;
                demand_mshr_complete_q[
                    demand_mshr_finalize_index_r] <= 1'b0;
                demand_mshr_fill_done_q[
                    demand_mshr_finalize_index_r] <= 1'b0;
                demand_mshr_error_q[
                    demand_mshr_finalize_index_r] <= 1'b0;
                demand_mshr_aged_q[
                    demand_mshr_finalize_index_r] <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    openrv64_l1i_debug_stub #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .REQ_TAG_WIDTH(REQ_TAG_WIDTH),
        .DEMAND_DEPTH(DEMAND_DEPTH),
        .DEMAND_MSHRS(DEMAND_MSHRS),
        .DEMAND_INDEX_WIDTH(DEMAND_INDEX_WIDTH),
        .DEMAND_COUNT_WIDTH(DEMAND_COUNT_WIDTH),
        .DEMAND_MSHR_INDEX_WIDTH(DEMAND_MSHR_INDEX_WIDTH)
    ) u_debug (
        .icx_issue_fire(icx_issue_fire),
        .issue_active_q(issue_active_q),
        .issue_index(issue_index),
        .issue_mshr_q(issue_mshr_q),
        .l1_input_valid(l1_input_valid),
        .l1_miss_fire(l1_miss_fire),
        .response_pop(response_pop),
        .response_pop_index(response_pop_index),
        .response_valid_vec(response_valid_vec),
        .response_complete_vec(response_complete_vec),
        .response_prefetch_vec(response_prefetch_vec),
        .response_count_q(response_count_q),
        .response_free_found_r(response_free_found_r),
        .response_free_index_r(response_free_index_r),
        .response_complete_found_r(response_complete_found_r),
        .response_complete_index_r(response_complete_index_r),
        .response_valid_q(response_valid_q),
        .response_complete_q(response_complete_q),
        .response_prefetch_q(response_prefetch_q),
        .response_tag_q(response_tag_q),
        .response_vaddr_q(response_vaddr_q),
        .response_wait_mshr_q(response_wait_mshr_q),
        .response_mshr_q(response_mshr_q),
        .demand_mshr_valid_vec(demand_mshr_valid_vec),
        .demand_mshr_issued_vec(demand_mshr_issued_vec),
        .demand_mshr_complete_vec(demand_mshr_complete_vec),
        .demand_mshr_fill_done_vec(demand_mshr_fill_done_vec),
        .demand_mshr_valid_q(demand_mshr_valid_q),
        .demand_mshr_issued_q(demand_mshr_issued_q),
        .demand_mshr_complete_q(demand_mshr_complete_q),
        .demand_mshr_fill_done_q(demand_mshr_fill_done_q),
        .demand_mshr_aged_q(demand_mshr_aged_q),
        .demand_mshr_addr_q(demand_mshr_addr_q),
        .demand_mshr_issue_found_r(demand_mshr_issue_found_r),
        .demand_mshr_issue_index_r(demand_mshr_issue_index_r)
    );

    always @(posedge clk_i) begin
        if (rst_ni && l1_mem_write)
            $fatal(1, "L1I attempted a native ICX line write");
        if (rst_ni && l1_mem_valid)
            $fatal(1,
                   "L1I used blocking memory instead of detached miss port");
        if (rst_ni && l1_resp_valid &&
            !response_valid_q[l1_resp_tag])
            $fatal(1, "L1I returned an unknown tagged hit response");
        if (rst_ni && icx_resp_valid_i &&
            icx_response_for_icache &&
            !demand_mshr_response_match_r)
            $fatal(1, "L1I received an unknown ICX miss response");
    end
`endif

endmodule
