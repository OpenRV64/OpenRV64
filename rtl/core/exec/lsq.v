`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"

// Parameterized unified load/store queue.
//
// This module owns memory-order state only.  The containing LSU supplies
// address-generation results and opaque backend metadata, sequences atomics,
// and formats architectural completions and exceptions.
module openrv64_lsq #(
    parameter integer RETIRE_SLOT_WIDTH = 3,
    parameter integer META_WIDTH = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH,
    parameter integer LOAD_QUEUE_DEPTH = 4,
    parameter integer STORE_QUEUE_DEPTH = 4,
    parameter integer TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH,
    parameter [`RV64_XLEN-1:0] CACHEABLE_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] CACHEABLE_SIZE = {`RV64_XLEN{1'b0}},
    parameter integer TIMEOUT_CYCLES = 10000,
    parameter integer DEPTH = LOAD_QUEUE_DEPTH + STORE_QUEUE_DEPTH
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_younger_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] squash_id_i,
    input  wire                         translation_bypass_i,

    input  wire                         load_alloc_valid_i,
    output wire                         load_alloc_ready_o,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] load_alloc_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] load_alloc_slot_i,
    input  wire [META_WIDTH-1:0]        load_alloc_meta_i,
    input  wire                         load_alloc_immediate_i,
    input  wire                         load_alloc_access_fault_i,
    input  wire [`RV64_XLEN-1:0]        load_alloc_vaddr_i,
    input  wire [2:0]                   load_alloc_size_i,

    input  wire                         store_alloc_valid_i,
    output wire                         store_alloc_ready_o,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] store_alloc_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] store_alloc_slot_i,
    input  wire [META_WIDTH-1:0]        store_alloc_meta_i,
    input  wire                         store_alloc_immediate_i,
    input  wire                         store_alloc_access_fault_i,
    input  wire                         store_alloc_atomic_i,
    input  wire [`RV64_XLEN-1:0]        store_alloc_vaddr_i,
    input  wire [2:0]                   store_alloc_size_i,
    input  wire [`RV64_XLEN-1:0]        store_alloc_wdata_i,
    input  wire [7:0]                   store_alloc_wstrb_i,

    input  wire                         ordered_head_valid_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] ordered_head_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] ordered_head_slot_i,

    output wire                         atomic_start_valid_o,
    output wire [TAG_WIDTH-1:0]         atomic_start_tag_o,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] atomic_start_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0] atomic_start_slot_o,
    output wire [META_WIDTH-1:0]        atomic_start_meta_o,
    output wire                         atomic_start_access_allowed_o,
    input  wire                         atomic_active_i,
    input  wire [TAG_WIDTH-1:0]         atomic_tag_i,
    input  wire                         atomic_irrevocable_i,
    input  wire                         atomic_done_i,

    output wire                         xlate_req_valid_o,
    input  wire                         xlate_req_ready_i,
    output wire [TAG_WIDTH-1:0]         xlate_req_tag_o,
    output wire                         xlate_req_write_o,
    output wire [`RV64_XLEN-1:0]        xlate_req_vaddr_o,
    input  wire                         xlate_resp_valid_i,
    output wire                         xlate_resp_ready_o,
    input  wire [TAG_WIDTH-1:0]         xlate_resp_tag_i,
    input  wire [`RV64_XLEN-1:0]        xlate_resp_paddr_i,
    input  wire                         xlate_resp_access_fault_i,
    input  wire                         xlate_resp_page_fault_i,

    output wire                         req_valid_o,
    input  wire                         req_ready_i,
    output wire [TAG_WIDTH-1:0]         req_tag_o,
    output wire                         req_write_o,
    output wire [`RV64_XLEN-1:0]        req_addr_o,
    output wire [`RV64_XLEN-1:0]        req_vaddr_o,
    output wire [2:0]                   req_size_o,
    output wire [`RV64_XLEN-1:0]        req_wdata_o,
    output wire [7:0]                   req_wstrb_o,

    input  wire                         resp_valid_i,
    output wire                         resp_ready_o,
    input  wire [TAG_WIDTH-1:0]         resp_tag_i,
    input  wire [`RV64_XLEN-1:0]        resp_paddr_i,
    input  wire [`RV64_XLEN-1:0]        resp_rdata_i,
    input  wire                         resp_access_fault_i,
    input  wire                         resp_page_fault_i,

    output wire                         result_valid_o,
    input  wire                         result_ready_i,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] result_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0] result_slot_o,
    output wire [META_WIDTH-1:0]        result_meta_o,
    output wire [`RV64_XLEN-1:0]        result_rdata_o,
    output wire                         result_access_fault_o,
    output wire                         result_page_fault_o,
    output wire                         result_store_o,
    output wire                         store_pending_o
);

    function automatic id_is_younger;
        input [`OPENRV64_INSTR_ID_WIDTH-1:0] candidate;
        input [`OPENRV64_INSTR_ID_WIDTH-1:0] reference;
        reg [`OPENRV64_INSTR_ID_WIDTH-1:0] distance;
        begin
            distance = candidate - reference;
            id_is_younger =
                (distance != {`OPENRV64_INSTR_ID_WIDTH{1'b0}}) &&
                !distance[`OPENRV64_INSTR_ID_WIDTH-1];
        end
    endfunction

    function automatic [7:0] access_byte_mask;
        input [2:0] size;
        input [2:0] byte_offset;
        reg [7:0] base_mask;
        begin
            case (size)
                3'd0: base_mask = 8'h01;
                3'd1: base_mask = 8'h03;
                3'd2: base_mask = 8'h0f;
                default: base_mask = 8'hff;
            endcase
            access_byte_mask = base_mask << byte_offset;
        end
    endfunction

    reg slot_valid_q [0:DEPTH-1];
    reg slot_store_q [0:DEPTH-1];
    reg slot_atomic_q [0:DEPTH-1];
    reg slot_immediate_q [0:DEPTH-1];
    reg slot_input_access_fault_q [0:DEPTH-1];
    reg slot_xlate_sent_q [0:DEPTH-1];
    reg slot_xlate_done_q [0:DEPTH-1];
    reg slot_xlate_access_fault_q [0:DEPTH-1];
    reg slot_xlate_page_fault_q [0:DEPTH-1];
    reg slot_access_sent_q [0:DEPTH-1];
    reg slot_killed_q [0:DEPTH-1];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] slot_id_q [0:DEPTH-1];
    reg [RETIRE_SLOT_WIDTH-1:0] slot_retire_q [0:DEPTH-1];
    reg [META_WIDTH-1:0] slot_meta_q [0:DEPTH-1];
    reg [`RV64_XLEN-1:0] slot_vaddr_q [0:DEPTH-1];
    reg [`RV64_XLEN-1:0] slot_paddr_q [0:DEPTH-1];
    reg [2:0] slot_size_q [0:DEPTH-1];
    reg [`RV64_XLEN-1:0] slot_wdata_q [0:DEPTH-1];
    reg [7:0] slot_wstrb_q [0:DEPTH-1];

    wire [7:0] slot_load_mask [0:DEPTH-1];
    wire slot_xlate_fault [0:DEPTH-1];
    wire slot_cacheable [0:DEPTH-1];
    wire slot_order_match [0:DEPTH-1];
    genvar property_gen;
    generate
        for (property_gen = 0; property_gen < DEPTH;
             property_gen = property_gen + 1) begin : g_properties
            assign slot_load_mask[property_gen] =
                access_byte_mask(slot_size_q[property_gen],
                                 slot_paddr_q[property_gen][2:0]);
            assign slot_xlate_fault[property_gen] =
                slot_xlate_done_q[property_gen] &&
                (slot_xlate_access_fault_q[property_gen] ||
                 slot_xlate_page_fault_q[property_gen]);
            assign slot_cacheable[property_gen] =
                (CACHEABLE_SIZE != {`RV64_XLEN{1'b0}}) &&
                ((slot_paddr_q[property_gen] - CACHEABLE_BASE) <
                 CACHEABLE_SIZE);
            assign slot_order_match[property_gen] =
                ordered_head_valid_i &&
                (ordered_head_id_i == slot_id_q[property_gen]) &&
                (ordered_head_slot_i == slot_retire_q[property_gen]);
        end
    endgenerate

    // Keep independent LQ and SQ capacity within the unified age-ordered
    // array.  Fixed slot partitions make both allocation-ready signals
    // independent; coupling one ready signal to the other port's fire creates
    // a combinational loop through dispatch.
    integer free_index;
    reg load_free_found_r;
    reg store_free_found_r;
    reg [TAG_WIDTH-1:0] load_free_index_r;
    reg [TAG_WIDTH-1:0] store_free_index_r;
    always @* begin
        load_free_found_r = 1'b0;
        store_free_found_r = 1'b0;
        load_free_index_r = {TAG_WIDTH{1'b0}};
        store_free_index_r = TAG_WIDTH'(LOAD_QUEUE_DEPTH);
        for (free_index = 0; free_index < LOAD_QUEUE_DEPTH;
             free_index = free_index + 1)
            if (!slot_valid_q[free_index] && !load_free_found_r) begin
                load_free_found_r = 1'b1;
                load_free_index_r = free_index[TAG_WIDTH-1:0];
            end
        for (free_index = LOAD_QUEUE_DEPTH; free_index < DEPTH;
             free_index = free_index + 1)
            if (!slot_valid_q[free_index] && !store_free_found_r) begin
                store_free_found_r = 1'b1;
                store_free_index_r = free_index[TAG_WIDTH-1:0];
            end
    end

    assign load_alloc_ready_o = load_free_found_r && !squash_younger_i;
    wire load_alloc_fire = load_alloc_valid_i && load_alloc_ready_o;
    assign store_alloc_ready_o = store_free_found_r && !squash_younger_i;
    wire store_alloc_fire = store_alloc_valid_i && store_alloc_ready_o;

    // Physical-address store/load disambiguation and byte forwarding.
    reg load_block_r [0:DEPTH-1];
    reg load_forward_r [0:DEPTH-1];
    reg [`RV64_XLEN-1:0] load_forward_word_r [0:DEPTH-1];
    reg [7:0] load_cover_mask_r [0:DEPTH-1];
    reg load_older_store_r [0:DEPTH-1];
    reg byte_owner_valid_r [0:DEPTH-1][0:7];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0]
        byte_owner_id_r [0:DEPTH-1][0:7];
    integer load_scan;
    integer store_scan;
    integer byte_scan;
    always @* begin
        for (load_scan = 0; load_scan < DEPTH;
             load_scan = load_scan + 1) begin
            load_block_r[load_scan] = 1'b0;
            load_forward_r[load_scan] = 1'b0;
            load_forward_word_r[load_scan] = {`RV64_XLEN{1'b0}};
            load_cover_mask_r[load_scan] = 8'h00;
            load_older_store_r[load_scan] = 1'b0;
            for (byte_scan = 0; byte_scan < 8;
                 byte_scan = byte_scan + 1) begin
                byte_owner_valid_r[load_scan][byte_scan] = 1'b0;
                byte_owner_id_r[load_scan][byte_scan] =
                    {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            end

            if (slot_valid_q[load_scan] &&
                !slot_killed_q[load_scan] &&
                !slot_store_q[load_scan] &&
                slot_xlate_done_q[load_scan] &&
                !slot_xlate_fault[load_scan]) begin
                for (store_scan = 0; store_scan < DEPTH;
                     store_scan = store_scan + 1) begin
                    if (slot_valid_q[store_scan] &&
                        !slot_killed_q[store_scan] &&
                        slot_store_q[store_scan] &&
                        id_is_younger(slot_id_q[load_scan],
                                      slot_id_q[store_scan])) begin
                        load_older_store_r[load_scan] = 1'b1;
                        if (slot_atomic_q[store_scan] ||
                            !slot_xlate_done_q[store_scan] ||
                            slot_xlate_fault[store_scan]) begin
                            load_block_r[load_scan] = 1'b1;
                        end else begin
                            if (slot_paddr_q[
                                    load_scan][`RV64_XLEN-1:3] ==
                                slot_paddr_q[
                                    store_scan][`RV64_XLEN-1:3]) begin
                                for (byte_scan = 0; byte_scan < 8;
                                     byte_scan = byte_scan + 1) begin
                                    if (slot_load_mask[
                                            load_scan][byte_scan] &&
                                        slot_wstrb_q[
                                            store_scan][byte_scan] &&
                                        (!byte_owner_valid_r[
                                            load_scan][byte_scan] ||
                                         id_is_younger(
                                            slot_id_q[store_scan],
                                            byte_owner_id_r[
                                                load_scan][byte_scan]))) begin
                                        byte_owner_valid_r[
                                            load_scan][byte_scan] = 1'b1;
                                        byte_owner_id_r[
                                            load_scan][byte_scan] =
                                            slot_id_q[store_scan];
                                        load_forward_word_r[
                                            load_scan][byte_scan*8 +: 8] =
                                            slot_wdata_q[
                                                store_scan][byte_scan*8 +: 8];
                                    end
                                end
                            end
                        end
                    end
                end

                for (byte_scan = 0; byte_scan < 8;
                     byte_scan = byte_scan + 1)
                    if (byte_owner_valid_r[load_scan][byte_scan])
                        load_cover_mask_r[load_scan][byte_scan] = 1'b1;

                // Disjoint byte ranges, including different words in one
                // cache line, are independent.  A partially covered overlap
                // must wait because this LSQ does not yet merge forwarded
                // bytes with returned cache data.
                if (|(load_cover_mask_r[load_scan] &
                      slot_load_mask[load_scan])) begin
                    if ((load_cover_mask_r[load_scan] &
                         slot_load_mask[load_scan]) ==
                        slot_load_mask[load_scan])
                        load_forward_r[load_scan] =
                            !load_block_r[load_scan];
                    else
                        load_block_r[load_scan] = 1'b1;
                end

                // Device/uncacheable reads do not pass any older store.
                if (load_older_store_r[load_scan] &&
                    !slot_cacheable[load_scan]) begin
                    load_block_r[load_scan] = 1'b1;
                    load_forward_r[load_scan] = 1'b0;
                end
            end
        end
    end

    // Translation is independent of L1D access.  One untranslated non-atomic
    // entry may probe the D micro-TLB while a different translated entry uses
    // the physical cache port.
    reg xlate_request_found_r;
    reg [TAG_WIDTH-1:0] xlate_request_index_r;
    integer xlate_request_scan;
    always @* begin
        xlate_request_found_r = 1'b0;
        xlate_request_index_r = {TAG_WIDTH{1'b0}};
        for (xlate_request_scan = 0; xlate_request_scan < DEPTH;
             xlate_request_scan = xlate_request_scan + 1) begin
            if (slot_valid_q[xlate_request_scan] &&
                !slot_killed_q[xlate_request_scan] &&
                !slot_atomic_q[xlate_request_scan] &&
                !slot_immediate_q[xlate_request_scan] &&
                !slot_xlate_done_q[xlate_request_scan] &&
                !slot_xlate_sent_q[xlate_request_scan] &&
                (!xlate_request_found_r ||
                 id_is_younger(
                    slot_id_q[xlate_request_index_r],
                    slot_id_q[xlate_request_scan]))) begin
                xlate_request_found_r = 1'b1;
                xlate_request_index_r =
                    xlate_request_scan[TAG_WIDTH-1:0];
            end
        end
    end

    // If no queued translation is older, launch translation directly from
    // the allocation port. This makes a micro-TLB hit part of LSQ admission
    // rather than imposing a mandatory queue/readback cycle.
    wire load_alloc_needs_xlate =
        load_alloc_fire && !translation_bypass_i &&
        !load_alloc_immediate_i;
    wire store_alloc_needs_xlate =
        store_alloc_fire && !translation_bypass_i &&
        !store_alloc_immediate_i && !store_alloc_atomic_i;
    wire xlate_alloc_select_load = load_alloc_needs_xlate &&
        (!store_alloc_needs_xlate ||
         id_is_younger(store_alloc_id_i, load_alloc_id_i));
    wire xlate_alloc_select_store = store_alloc_needs_xlate &&
                                    !xlate_alloc_select_load;
    wire xlate_request_from_alloc = !xlate_request_found_r &&
        (xlate_alloc_select_load || xlate_alloc_select_store);
    wire [TAG_WIDTH-1:0] xlate_request_tag =
        xlate_request_found_r ? xlate_request_index_r :
        xlate_alloc_select_load ? load_free_index_r :
        store_free_index_r;

    assign xlate_req_valid_o =
        (xlate_request_found_r || xlate_request_from_alloc) &&
                               !atomic_active_i &&
                               !squash_younger_i;
    assign xlate_req_tag_o = xlate_request_tag;
    assign xlate_req_write_o = xlate_request_found_r ?
        slot_store_q[xlate_request_index_r] :
        xlate_alloc_select_store;
    assign xlate_req_vaddr_o = xlate_request_found_r ?
        slot_vaddr_q[xlate_request_index_r] :
        xlate_alloc_select_load ? load_alloc_vaddr_i :
        store_alloc_vaddr_i;
    wire xlate_req_fire = xlate_req_valid_o && xlate_req_ready_i;

    // The physical L1D launch port chooses the oldest translated operation
    // which can make progress. Store access remains ordered at retirement.
    reg request_found_r;
    reg [TAG_WIDTH-1:0] request_index_r;
    integer request_scan;
    reg request_candidate_r;
    always @* begin
        request_found_r = 1'b0;
        request_index_r = {TAG_WIDTH{1'b0}};
        for (request_scan = 0; request_scan < DEPTH;
             request_scan = request_scan + 1) begin
            request_candidate_r = 1'b0;
            if (slot_valid_q[request_scan] &&
                !slot_killed_q[request_scan] &&
                !slot_atomic_q[request_scan] &&
                !slot_immediate_q[request_scan] &&
                !slot_xlate_fault[request_scan] &&
                slot_xlate_done_q[request_scan] &&
                !slot_access_sent_q[request_scan]) begin
                    if (slot_store_q[request_scan])
                        request_candidate_r =
                            slot_order_match[request_scan];
                    else
                        request_candidate_r =
                            !load_block_r[request_scan] &&
                            !load_forward_r[request_scan] &&
                            (slot_cacheable[request_scan] ||
                             slot_order_match[request_scan]);
            end
            if (request_candidate_r &&
                (!request_found_r ||
                 id_is_younger(slot_id_q[request_index_r],
                               slot_id_q[request_scan]))) begin
                request_found_r = 1'b1;
                request_index_r = request_scan[TAG_WIDTH-1:0];
            end
        end
    end

    assign req_valid_o = request_found_r && !atomic_active_i &&
                         !squash_younger_i;
    assign req_tag_o = request_index_r;
    assign req_write_o = slot_store_q[request_index_r];
    assign req_addr_o = slot_paddr_q[request_index_r];
    assign req_vaddr_o = slot_vaddr_q[request_index_r];
    assign req_size_o = slot_size_q[request_index_r];
    assign req_wdata_o = slot_wdata_q[request_index_r];
    assign req_wstrb_o = slot_wstrb_q[request_index_r];
    wire req_fire = req_valid_o && req_ready_i;

    // Local completions cover decode/address faults, translation faults, and
    // loads whose bytes are fully supplied by older stores.
    reg local_found_r;
    reg [TAG_WIDTH-1:0] local_index_r;
    integer local_scan;
    reg local_candidate_r;
    always @* begin
        local_found_r = 1'b0;
        local_index_r = {TAG_WIDTH{1'b0}};
        for (local_scan = 0; local_scan < DEPTH;
             local_scan = local_scan + 1) begin
            local_candidate_r = slot_valid_q[local_scan] &&
                !slot_killed_q[local_scan] &&
                !(squash_younger_i &&
                  id_is_younger(slot_id_q[local_scan], squash_id_i)) &&
                !slot_atomic_q[local_scan] &&
                (slot_immediate_q[local_scan] ||
                 slot_xlate_fault[local_scan] ||
                 load_forward_r[local_scan]);
            if (local_candidate_r &&
                (!local_found_r ||
                 id_is_younger(slot_id_q[local_index_r],
                               slot_id_q[local_scan]))) begin
                local_found_r = 1'b1;
                local_index_r = local_scan[TAG_WIDTH-1:0];
            end
        end
    end

    wire xlate_resp_tag_valid = xlate_resp_tag_i < DEPTH;
    wire xlate_resp_slot_valid = xlate_resp_tag_valid &&
                                 slot_valid_q[xlate_resp_tag_i];
    wire xlate_resp_matches_request = xlate_req_fire &&
        (xlate_req_tag_o == xlate_resp_tag_i);
    wire xlate_resp_matches_allocation =
        xlate_resp_matches_request && xlate_request_from_alloc;
    wire xlate_resp_is_expected =
        (xlate_resp_slot_valid &&
         (slot_xlate_sent_q[xlate_resp_tag_i] ||
          xlate_resp_matches_request)) ||
        xlate_resp_matches_allocation;
    assign xlate_resp_ready_o = 1'b1;
    wire xlate_resp_fire = xlate_resp_valid_i && xlate_resp_ready_o &&
                           xlate_resp_is_expected;

    wire resp_tag_valid = resp_tag_i < DEPTH;
    wire resp_slot_valid = resp_tag_valid && slot_valid_q[resp_tag_i];
    wire resp_slot_killed = resp_slot_valid && slot_killed_q[resp_tag_i];
    wire resp_is_access = resp_slot_valid &&
                          slot_access_sent_q[resp_tag_i];
    assign resp_ready_o = resp_is_access ? result_ready_i : 1'b1;
    wire resp_fire = resp_valid_i && resp_ready_o;
    wire access_resp_visible = resp_valid_i && resp_is_access;
    wire access_resp_squashed_now = access_resp_visible &&
        squash_younger_i &&
        id_is_younger(slot_id_q[resp_tag_i], squash_id_i);

    wire access_resp_result = access_resp_visible &&
                              !resp_slot_killed &&
                              !access_resp_squashed_now;
    assign result_valid_o = access_resp_result || local_found_r;
    wire result_select_resp = access_resp_result;
    wire [TAG_WIDTH-1:0] result_index =
        result_select_resp ? resp_tag_i : local_index_r;
    assign result_id_o = slot_id_q[result_index];
    assign result_slot_o = slot_retire_q[result_index];
    assign result_meta_o = slot_meta_q[result_index];
    assign result_store_o = slot_store_q[result_index];
    assign result_rdata_o = result_select_resp ? resp_rdata_i :
                            load_forward_r[local_index_r] ?
                            load_forward_word_r[local_index_r] :
                            {`RV64_XLEN{1'b0}};
    assign result_access_fault_o = result_select_resp ?
        resp_access_fault_i :
        (slot_input_access_fault_q[local_index_r] ||
         slot_xlate_access_fault_q[local_index_r]);
    assign result_page_fault_o = result_select_resp ?
        resp_page_fault_i :
        slot_xlate_page_fault_q[local_index_r];
    wire result_fire = result_valid_o && result_ready_i;

    reg atomic_start_found_r;
    reg [TAG_WIDTH-1:0] atomic_start_index_r;
    integer atomic_scan;
    always @* begin
        atomic_start_found_r = 1'b0;
        atomic_start_index_r = {TAG_WIDTH{1'b0}};
        for (atomic_scan = 0; atomic_scan < DEPTH;
             atomic_scan = atomic_scan + 1) begin
            if (slot_valid_q[atomic_scan] &&
                !slot_killed_q[atomic_scan] &&
                slot_atomic_q[atomic_scan] &&
                slot_order_match[atomic_scan] &&
                (!atomic_start_found_r ||
                 id_is_younger(slot_id_q[atomic_start_index_r],
                               slot_id_q[atomic_scan]))) begin
                atomic_start_found_r = 1'b1;
                atomic_start_index_r = atomic_scan[TAG_WIDTH-1:0];
            end
        end
    end
    assign atomic_start_valid_o =
        atomic_start_found_r && !atomic_active_i;
    assign atomic_start_tag_o = atomic_start_index_r;
    assign atomic_start_id_o = slot_id_q[atomic_start_index_r];
    assign atomic_start_slot_o = slot_retire_q[atomic_start_index_r];
    assign atomic_start_meta_o = slot_meta_q[atomic_start_index_r];
    assign atomic_start_access_allowed_o =
        !slot_input_access_fault_q[atomic_start_index_r];

    reg any_store_r;
    integer pending_scan;
    always @* begin
        any_store_r = 1'b0;
        for (pending_scan = 0; pending_scan < DEPTH;
             pending_scan = pending_scan + 1)
            if (slot_valid_q[pending_scan] &&
                !slot_killed_q[pending_scan] &&
                slot_store_q[pending_scan])
                any_store_r = 1'b1;
    end
    assign store_pending_o = any_store_r || atomic_active_i;

    integer slot_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (slot_index = 0; slot_index < DEPTH;
                 slot_index = slot_index + 1) begin
                slot_valid_q[slot_index] <= 1'b0;
                slot_store_q[slot_index] <= 1'b0;
                slot_atomic_q[slot_index] <= 1'b0;
                slot_immediate_q[slot_index] <= 1'b0;
                slot_input_access_fault_q[slot_index] <= 1'b0;
                slot_xlate_sent_q[slot_index] <= 1'b0;
                slot_xlate_done_q[slot_index] <= 1'b0;
                slot_xlate_access_fault_q[slot_index] <= 1'b0;
                slot_xlate_page_fault_q[slot_index] <= 1'b0;
                slot_access_sent_q[slot_index] <= 1'b0;
                slot_killed_q[slot_index] <= 1'b0;
                slot_id_q[slot_index] <=
                    {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
                slot_retire_q[slot_index] <=
                    {RETIRE_SLOT_WIDTH{1'b0}};
                slot_meta_q[slot_index] <= {META_WIDTH{1'b0}};
                slot_vaddr_q[slot_index] <= {`RV64_XLEN{1'b0}};
                slot_paddr_q[slot_index] <= {`RV64_XLEN{1'b0}};
                slot_size_q[slot_index] <= 3'd0;
                slot_wdata_q[slot_index] <= {`RV64_XLEN{1'b0}};
                slot_wstrb_q[slot_index] <= 8'h00;
            end
        end else if (flush_i) begin
            for (slot_index = 0; slot_index < DEPTH;
                 slot_index = slot_index + 1) begin
                if (slot_valid_q[slot_index] &&
                    slot_store_q[slot_index] &&
                    slot_access_sent_q[slot_index]) begin
                    // A store can enter this state only after ordered-head
                    // authorization.  Preserve it until L1D admission responds.
                    slot_valid_q[slot_index] <= 1'b1;
                end else if (atomic_irrevocable_i &&
                             (atomic_tag_i ==
                              slot_index[TAG_WIDTH-1:0])) begin
                    slot_valid_q[slot_index] <= 1'b1;
                end else begin
                    slot_valid_q[slot_index] <= 1'b0;
                    slot_xlate_sent_q[slot_index] <= 1'b0;
                    slot_access_sent_q[slot_index] <= 1'b0;
                    slot_killed_q[slot_index] <= 1'b0;
                end
            end
            if (result_fire) begin
                slot_valid_q[result_index] <= 1'b0;
                slot_xlate_sent_q[result_index] <= 1'b0;
                slot_access_sent_q[result_index] <= 1'b0;
            end
            if (atomic_done_i)
                slot_valid_q[atomic_tag_i] <= 1'b0;
        end else begin
            if (load_alloc_fire) begin
                slot_valid_q[load_free_index_r] <= 1'b1;
                slot_store_q[load_free_index_r] <= 1'b0;
                slot_atomic_q[load_free_index_r] <= 1'b0;
                slot_immediate_q[load_free_index_r] <=
                    load_alloc_immediate_i;
                slot_input_access_fault_q[load_free_index_r] <=
                    load_alloc_access_fault_i;
                slot_xlate_sent_q[load_free_index_r] <= 1'b0;
                slot_xlate_done_q[load_free_index_r] <=
                    translation_bypass_i;
                slot_xlate_access_fault_q[load_free_index_r] <= 1'b0;
                slot_xlate_page_fault_q[load_free_index_r] <= 1'b0;
                slot_access_sent_q[load_free_index_r] <= 1'b0;
                slot_killed_q[load_free_index_r] <= 1'b0;
                slot_id_q[load_free_index_r] <= load_alloc_id_i;
                slot_retire_q[load_free_index_r] <= load_alloc_slot_i;
                slot_meta_q[load_free_index_r] <= load_alloc_meta_i;
                slot_vaddr_q[load_free_index_r] <= load_alloc_vaddr_i;
                slot_paddr_q[load_free_index_r] <=
                    translation_bypass_i ? load_alloc_vaddr_i :
                    {`RV64_XLEN{1'b0}};
                slot_size_q[load_free_index_r] <= load_alloc_size_i;
                slot_wdata_q[load_free_index_r] <= {`RV64_XLEN{1'b0}};
                slot_wstrb_q[load_free_index_r] <= 8'h00;
            end

            if (store_alloc_fire) begin
                slot_valid_q[store_free_index_r] <= 1'b1;
                slot_store_q[store_free_index_r] <= 1'b1;
                slot_atomic_q[store_free_index_r] <= store_alloc_atomic_i;
                slot_immediate_q[store_free_index_r] <=
                    store_alloc_immediate_i;
                slot_input_access_fault_q[store_free_index_r] <=
                    store_alloc_access_fault_i;
                slot_xlate_sent_q[store_free_index_r] <= 1'b0;
                slot_xlate_done_q[store_free_index_r] <=
                    translation_bypass_i;
                slot_xlate_access_fault_q[store_free_index_r] <= 1'b0;
                slot_xlate_page_fault_q[store_free_index_r] <= 1'b0;
                slot_access_sent_q[store_free_index_r] <= 1'b0;
                slot_killed_q[store_free_index_r] <= 1'b0;
                slot_id_q[store_free_index_r] <= store_alloc_id_i;
                slot_retire_q[store_free_index_r] <= store_alloc_slot_i;
                slot_meta_q[store_free_index_r] <= store_alloc_meta_i;
                slot_vaddr_q[store_free_index_r] <= store_alloc_vaddr_i;
                slot_paddr_q[store_free_index_r] <=
                    translation_bypass_i ? store_alloc_vaddr_i :
                    {`RV64_XLEN{1'b0}};
                slot_size_q[store_free_index_r] <= store_alloc_size_i;
                slot_wdata_q[store_free_index_r] <= store_alloc_wdata_i;
                slot_wstrb_q[store_free_index_r] <= store_alloc_wstrb_i;
            end

            if (xlate_req_fire)
                slot_xlate_sent_q[xlate_request_tag] <= 1'b1;

            if (req_fire)
                slot_access_sent_q[request_index_r] <= 1'b1;

            if (xlate_resp_fire) begin
                if (slot_killed_q[xlate_resp_tag_i]) begin
                    slot_valid_q[xlate_resp_tag_i] <= 1'b0;
                    slot_killed_q[xlate_resp_tag_i] <= 1'b0;
                    slot_xlate_sent_q[xlate_resp_tag_i] <= 1'b0;
                end else begin
                    slot_xlate_sent_q[xlate_resp_tag_i] <= 1'b0;
                    slot_xlate_done_q[xlate_resp_tag_i] <= 1'b1;
                    slot_xlate_access_fault_q[xlate_resp_tag_i] <=
                        xlate_resp_access_fault_i;
                    slot_xlate_page_fault_q[xlate_resp_tag_i] <=
                        xlate_resp_page_fault_i;
                    slot_paddr_q[xlate_resp_tag_i] <= xlate_resp_paddr_i;
                end
            end

            if (resp_fire && resp_is_access &&
                slot_killed_q[resp_tag_i]) begin
                slot_valid_q[resp_tag_i] <= 1'b0;
                slot_killed_q[resp_tag_i] <= 1'b0;
                slot_access_sent_q[resp_tag_i] <= 1'b0;
            end

            if (result_fire) begin
                slot_valid_q[result_index] <= 1'b0;
                slot_xlate_sent_q[result_index] <= 1'b0;
                slot_access_sent_q[result_index] <= 1'b0;
            end
            if (atomic_done_i)
                slot_valid_q[atomic_tag_i] <= 1'b0;

            // Selective branch recovery removes younger memory operations.
            // An entry with an accepted request retains its tag as a killed
            // quarantine slot until that response is consumed; immediate reuse
            // would let the stale response complete a new instruction.
            if (squash_younger_i) begin
                for (slot_index = 0; slot_index < DEPTH;
                     slot_index = slot_index + 1) begin
                    if (slot_valid_q[slot_index] &&
                        id_is_younger(slot_id_q[slot_index], squash_id_i)) begin
                        if ((slot_xlate_sent_q[slot_index] ||
                             slot_access_sent_q[slot_index]) &&
                            !((resp_fire &&
                               (resp_tag_i ==
                                slot_index[TAG_WIDTH-1:0])) ||
                              (xlate_resp_fire &&
                               (xlate_resp_tag_i ==
                                slot_index[TAG_WIDTH-1:0])))) begin
                            slot_killed_q[slot_index] <= 1'b1;
                        end else begin
                            slot_valid_q[slot_index] <= 1'b0;
                            slot_killed_q[slot_index] <= 1'b0;
                            slot_xlate_sent_q[slot_index] <= 1'b0;
                            slot_access_sent_q[slot_index] <= 1'b0;
                        end
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    integer timeout_index;
    integer slot_timeout_age_q [0:DEPTH-1];
    initial begin
        if (LOAD_QUEUE_DEPTH < 1)
            $fatal(1, "LSQ requires at least one load entry");
        if (STORE_QUEUE_DEPTH < 1)
            $fatal(1, "LSQ requires at least one store entry");
        if (DEPTH > (1 << TAG_WIDTH))
            $fatal(1, "LSQ depth exceeds LSU tag namespace");
        if (TIMEOUT_CYCLES < 1)
            $fatal(1, "LSQ timeout must be positive");
    end

    always @(posedge clk) begin
        if (!rst_n || flush_i) begin
            for (timeout_index = 0; timeout_index < DEPTH;
                 timeout_index = timeout_index + 1)
                slot_timeout_age_q[timeout_index] <= 0;
        end else begin
            for (timeout_index = 0; timeout_index < DEPTH;
                 timeout_index = timeout_index + 1) begin
                if (!slot_valid_q[timeout_index])
                    slot_timeout_age_q[timeout_index] <= 0;
                else begin
                    slot_timeout_age_q[timeout_index] <=
                        slot_timeout_age_q[timeout_index] + 1;
                    if (slot_timeout_age_q[timeout_index] >=
                        TIMEOUT_CYCLES)
                        $fatal(1,
                            "LSQ entry %0d exceeded timeout id=%0d store=%b atomic=%b killed=%b xlate_sent=%b xlate_done=%b access_sent=%b order=%b block=%b forward=%b vaddr=%h paddr=%h head_valid=%b head_id=%0d head_slot=%0d",
                            timeout_index, slot_id_q[timeout_index],
                            slot_store_q[timeout_index],
                            slot_atomic_q[timeout_index],
                            slot_killed_q[timeout_index],
                            slot_xlate_sent_q[timeout_index],
                            slot_xlate_done_q[timeout_index],
                            slot_access_sent_q[timeout_index],
                            slot_order_match[timeout_index],
                            load_block_r[timeout_index],
                            load_forward_r[timeout_index],
                            slot_vaddr_q[timeout_index],
                            slot_paddr_q[timeout_index],
                            ordered_head_valid_i, ordered_head_id_i,
                            ordered_head_slot_i);
                end
            end
        end
    end
`endif

endmodule
