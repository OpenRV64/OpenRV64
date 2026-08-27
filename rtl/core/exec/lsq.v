`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"

// Compact load transaction table plus a small table of persistent store guards.
//
// There is deliberately no unified load/store queue here.  Loads retain only
// compact transaction records needed to route translation, memory responses,
// and completion state.  Every load slot may have translation or memory in
// flight independently.  Stores retain independent guards until they complete
// so a younger load cannot pass a possibly-aliasing write.  Cacheable guards
// compare a folded cache-line hash; collisions conservatively stall.  This cut
// does not forward store bytes to loads.
module openrv64_lsq #(
    parameter integer RETIRE_SLOT_WIDTH = 3,
    parameter integer META_WIDTH = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH,
    parameter integer LOAD_QUEUE_DEPTH = 4,
    parameter integer STORE_QUEUE_DEPTH = 4,
    parameter integer TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH,
    parameter integer GUARD_HASH_WIDTH = 10,
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
    output wire [`RV64_XLEN-1:0]        atomic_start_vaddr_o,
    output wire [2:0]                   atomic_start_size_o,
    output wire [`RV64_XLEN-1:0]        atomic_start_wdata_o,
    output wire                         atomic_start_access_allowed_o,
    input  wire                         atomic_active_i,
    input  wire [TAG_WIDTH-1:0]         atomic_tag_i,
    input  wire                         atomic_irrevocable_i,
    input  wire                         atomic_done_i,

    output wire                         xlate_req_valid_o,
    input  wire                         xlate_req_ready_i,
    output wire [TAG_WIDTH-1:0]         xlate_req_tag_o,
    output wire                         xlate_req_write_o,
    output wire [2:0]                   xlate_req_size_o,
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
    output wire                         req_pmp_checked_o,
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
    input  wire                         store_done_valid_i,
    output wire                         store_done_ready_o,
    input  wire [TAG_WIDTH-1:0]         store_done_tag_i,

    output wire                         result_valid_o,
    input  wire                         result_ready_i,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] result_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0] result_slot_o,
    output wire [META_WIDTH-1:0]        result_meta_o,
    output wire [`RV64_XLEN-1:0]        result_vaddr_o,
    output wire [`RV64_XLEN-1:0]        result_rdata_o,
    output wire                         result_access_fault_o,
    output wire                         result_page_fault_o,
    output wire                         result_store_o,
    output wire                         store_pending_o,
    output wire                         quiescent_o,
    output wire                         empty_o
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

    function automatic [GUARD_HASH_WIDTH-1:0] cacheline_hash;
        input [`RV64_XLEN-1:0] address;
        integer hash_bit;
        begin
            cacheline_hash = {GUARD_HASH_WIDTH{1'b0}};
            for (hash_bit = 6; hash_bit < `RV64_XLEN;
                 hash_bit = hash_bit + 1)
                cacheline_hash[(hash_bit-6) % GUARD_HASH_WIDTH] =
                    cacheline_hash[(hash_bit-6) % GUARD_HASH_WIDTH] ^
                    address[hash_bit];
        end
    endfunction

    function automatic address_cacheable;
        input [`RV64_XLEN-1:0] address;
        begin
            address_cacheable =
                (CACHEABLE_SIZE != {`RV64_XLEN{1'b0}}) &&
                ((address - CACHEABLE_BASE) < CACHEABLE_SIZE);
        end
    endfunction

    // Four by default.  Each entry is an independently tagged load
    // transaction; there is no store-forwarding data in this table.
    reg load_valid_q [0:LOAD_QUEUE_DEPTH-1];
    reg load_immediate_q [0:LOAD_QUEUE_DEPTH-1];
    reg load_input_access_fault_q [0:LOAD_QUEUE_DEPTH-1];
    reg load_xlate_sent_q [0:LOAD_QUEUE_DEPTH-1];
    reg load_xlate_done_q [0:LOAD_QUEUE_DEPTH-1];
    reg load_pmp_checked_q [0:LOAD_QUEUE_DEPTH-1];
    reg load_xlate_access_fault_q [0:LOAD_QUEUE_DEPTH-1];
    reg load_xlate_page_fault_q [0:LOAD_QUEUE_DEPTH-1];
    reg load_access_sent_q [0:LOAD_QUEUE_DEPTH-1];
    reg load_killed_q [0:LOAD_QUEUE_DEPTH-1];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0]
        load_id_q [0:LOAD_QUEUE_DEPTH-1];
    reg [RETIRE_SLOT_WIDTH-1:0]
        load_retire_q [0:LOAD_QUEUE_DEPTH-1];
    reg [META_WIDTH-1:0] load_meta_q [0:LOAD_QUEUE_DEPTH-1];
    reg [`RV64_XLEN-1:0] load_vaddr_q [0:LOAD_QUEUE_DEPTH-1];
    reg [`RV64_XLEN-1:0] load_paddr_q [0:LOAD_QUEUE_DEPTH-1];
    reg [2:0] load_size_q [0:LOAD_QUEUE_DEPTH-1];

    // Four by default.  These are the only persistent associative entries.
    reg store_valid_q [0:STORE_QUEUE_DEPTH-1];
    reg store_atomic_q [0:STORE_QUEUE_DEPTH-1];
    reg store_immediate_q [0:STORE_QUEUE_DEPTH-1];
    reg store_input_access_fault_q [0:STORE_QUEUE_DEPTH-1];
    reg store_xlate_sent_q [0:STORE_QUEUE_DEPTH-1];
    reg store_xlate_done_q [0:STORE_QUEUE_DEPTH-1];
    reg store_pmp_checked_q [0:STORE_QUEUE_DEPTH-1];
    reg store_xlate_access_fault_q [0:STORE_QUEUE_DEPTH-1];
    reg store_xlate_page_fault_q [0:STORE_QUEUE_DEPTH-1];
    reg store_access_sent_q [0:STORE_QUEUE_DEPTH-1];
    reg store_result_sent_q [0:STORE_QUEUE_DEPTH-1];
    reg store_access_done_q [0:STORE_QUEUE_DEPTH-1];
    reg store_killed_q [0:STORE_QUEUE_DEPTH-1];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0]
        store_id_q [0:STORE_QUEUE_DEPTH-1];
    reg [RETIRE_SLOT_WIDTH-1:0]
        store_retire_q [0:STORE_QUEUE_DEPTH-1];
    reg [META_WIDTH-1:0] store_meta_q [0:STORE_QUEUE_DEPTH-1];
    reg [`RV64_XLEN-1:0] store_vaddr_q [0:STORE_QUEUE_DEPTH-1];
    reg [`RV64_XLEN-1:0] store_paddr_q [0:STORE_QUEUE_DEPTH-1];
    reg [2:0] store_size_q [0:STORE_QUEUE_DEPTH-1];
    reg [`RV64_XLEN-1:0] store_wdata_q [0:STORE_QUEUE_DEPTH-1];
    reg [7:0] store_wstrb_q [0:STORE_QUEUE_DEPTH-1];
    reg [GUARD_HASH_WIDTH-1:0]
        store_guard_hash_q [0:STORE_QUEUE_DEPTH-1];

    wire load_xlate_fault [0:LOAD_QUEUE_DEPTH-1];
    wire load_cacheable [0:LOAD_QUEUE_DEPTH-1];
    wire load_order_match [0:LOAD_QUEUE_DEPTH-1];
    wire [GUARD_HASH_WIDTH-1:0]
        load_guard_hash [0:LOAD_QUEUE_DEPTH-1];
    genvar load_property_gen;
    generate
        for (load_property_gen = 0;
             load_property_gen < LOAD_QUEUE_DEPTH;
             load_property_gen = load_property_gen + 1) begin :
                g_load_properties
            assign load_xlate_fault[load_property_gen] =
                load_xlate_done_q[load_property_gen] &&
                (load_xlate_access_fault_q[load_property_gen] ||
                 load_xlate_page_fault_q[load_property_gen]);
            assign load_cacheable[load_property_gen] =
                address_cacheable(load_paddr_q[load_property_gen]);
            assign load_order_match[load_property_gen] =
                ordered_head_valid_i &&
                (ordered_head_id_i == load_id_q[load_property_gen]) &&
                (ordered_head_slot_i ==
                 load_retire_q[load_property_gen]);
            assign load_guard_hash[load_property_gen] =
                cacheline_hash(load_paddr_q[load_property_gen]);
        end
    endgenerate

    wire store_xlate_fault [0:STORE_QUEUE_DEPTH-1];
    wire store_cacheable [0:STORE_QUEUE_DEPTH-1];
    wire store_order_match [0:STORE_QUEUE_DEPTH-1];
    genvar store_property_gen;
    generate
        for (store_property_gen = 0;
             store_property_gen < STORE_QUEUE_DEPTH;
             store_property_gen = store_property_gen + 1) begin :
                g_store_properties
            assign store_xlate_fault[store_property_gen] =
                store_xlate_done_q[store_property_gen] &&
                (store_xlate_access_fault_q[store_property_gen] ||
                 store_xlate_page_fault_q[store_property_gen]);
            assign store_cacheable[store_property_gen] =
                address_cacheable(store_paddr_q[store_property_gen]);
            assign store_order_match[store_property_gen] =
                ordered_head_valid_i &&
                (ordered_head_id_i == store_id_q[store_property_gen]) &&
                (ordered_head_slot_i ==
                 store_retire_q[store_property_gen]);
        end
    endgenerate

    integer free_scan;
    reg load_free_found_r;
    reg store_free_found_r;
    reg [TAG_WIDTH-1:0] load_free_index_r;
    reg [TAG_WIDTH-1:0] store_free_index_r;
    reg [TAG_WIDTH-1:0] store_free_array_index_r;
    always @* begin
        load_free_found_r = 1'b0;
        store_free_found_r = 1'b0;
        load_free_index_r = {TAG_WIDTH{1'b0}};
        store_free_index_r = LOAD_QUEUE_DEPTH;
        store_free_array_index_r = {TAG_WIDTH{1'b0}};
        for (free_scan = 0; free_scan < LOAD_QUEUE_DEPTH;
             free_scan = free_scan + 1)
            if (!load_valid_q[free_scan] && !load_free_found_r) begin
                load_free_found_r = 1'b1;
                load_free_index_r = free_scan;
            end
        for (free_scan = 0; free_scan < STORE_QUEUE_DEPTH;
             free_scan = free_scan + 1)
            if (!store_valid_q[free_scan] && !store_free_found_r) begin
                store_free_found_r = 1'b1;
                store_free_index_r = LOAD_QUEUE_DEPTH + free_scan;
                store_free_array_index_r = free_scan;
            end
    end
    assign load_alloc_ready_o = load_free_found_r && !squash_younger_i;
    wire load_alloc_fire = load_alloc_valid_i && load_alloc_ready_o;
    assign store_alloc_ready_o = store_free_found_r && !squash_younger_i;
    wire store_alloc_fire = store_alloc_valid_i && store_alloc_ready_o;

    // Each translated load probes only store guards older than itself.
    // Unknown store addresses block.  Device loads block behind every older
    // store.  A hash hit blocks cacheable loads; a collision is deliberately
    // a false stall.
    integer load_guard_scan;
    integer guard_scan;
    reg load_guard_block_r [0:LOAD_QUEUE_DEPTH-1];
    reg load_has_older_store_r [0:LOAD_QUEUE_DEPTH-1];
    always @* begin
        for (load_guard_scan = 0;
             load_guard_scan < LOAD_QUEUE_DEPTH;
             load_guard_scan = load_guard_scan + 1) begin
            load_guard_block_r[load_guard_scan] = 1'b0;
            load_has_older_store_r[load_guard_scan] = 1'b0;
            if (load_valid_q[load_guard_scan] &&
                !load_killed_q[load_guard_scan] &&
                load_xlate_done_q[load_guard_scan] &&
                !load_xlate_fault[load_guard_scan]) begin
                for (guard_scan = 0; guard_scan < STORE_QUEUE_DEPTH;
                     guard_scan = guard_scan + 1) begin
                    if (store_valid_q[guard_scan] &&
                        !store_killed_q[guard_scan] &&
                        id_is_younger(load_id_q[load_guard_scan],
                                      store_id_q[guard_scan])) begin
                        load_has_older_store_r[load_guard_scan] = 1'b1;
                        if (store_atomic_q[guard_scan] ||
                            !store_xlate_done_q[guard_scan] ||
                            store_xlate_fault[guard_scan] ||
                            !load_cacheable[load_guard_scan] ||
                            (store_guard_hash_q[guard_scan] ==
                             load_guard_hash[load_guard_scan]))
                            load_guard_block_r[load_guard_scan] = 1'b1;
                    end
                end
            end
        end
    end

    // Translation selection is an age comparison across the compact load
    // records and the store guards.  Translation is independent of memory
    // access: a second load may translate while an older load awaits data.
    // Allocation can feed the port directly when no queued record is waiting.
    integer xlate_scan;
    reg xlate_request_found_r;
    reg xlate_request_store_r;
    reg [TAG_WIDTH-1:0] xlate_request_index_r;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] xlate_request_id_r;
    always @* begin
        xlate_request_found_r = 1'b0;
        xlate_request_store_r = 1'b0;
        xlate_request_index_r = {TAG_WIDTH{1'b0}};
        xlate_request_id_r = {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        for (xlate_scan = 0; xlate_scan < LOAD_QUEUE_DEPTH;
             xlate_scan = xlate_scan + 1)
            if (load_valid_q[xlate_scan] &&
                !load_killed_q[xlate_scan] &&
                !load_immediate_q[xlate_scan] &&
                !load_xlate_done_q[xlate_scan] &&
                !load_xlate_sent_q[xlate_scan] &&
                (!xlate_request_found_r ||
                 id_is_younger(xlate_request_id_r,
                               load_id_q[xlate_scan]))) begin
                xlate_request_found_r = 1'b1;
                xlate_request_store_r = 1'b0;
                xlate_request_index_r = xlate_scan;
                xlate_request_id_r = load_id_q[xlate_scan];
            end
        for (xlate_scan = 0; xlate_scan < STORE_QUEUE_DEPTH;
             xlate_scan = xlate_scan + 1) begin
            if (store_valid_q[xlate_scan] &&
                !store_killed_q[xlate_scan] &&
                !store_atomic_q[xlate_scan] &&
                !store_immediate_q[xlate_scan] &&
                !store_xlate_done_q[xlate_scan] &&
                !store_xlate_sent_q[xlate_scan] &&
                (!xlate_request_found_r ||
                 id_is_younger(xlate_request_id_r,
                               store_id_q[xlate_scan]))) begin
                xlate_request_found_r = 1'b1;
                xlate_request_store_r = 1'b1;
                xlate_request_index_r = LOAD_QUEUE_DEPTH + xlate_scan;
                xlate_request_id_r = store_id_q[xlate_scan];
            end
        end
    end

    wire load_alloc_needs_xlate =
        load_alloc_fire && !load_alloc_immediate_i;
    wire store_alloc_needs_xlate =
        store_alloc_fire && !store_alloc_immediate_i &&
        !store_alloc_atomic_i;
    wire xlate_alloc_select_load = load_alloc_needs_xlate &&
        (!store_alloc_needs_xlate ||
         id_is_younger(store_alloc_id_i, load_alloc_id_i));
    wire xlate_alloc_select_store = store_alloc_needs_xlate &&
                                    !xlate_alloc_select_load;
    wire xlate_request_from_alloc = !xlate_request_found_r &&
        (xlate_alloc_select_load || xlate_alloc_select_store);
    wire [TAG_WIDTH-1:0] xlate_request_tag =
        xlate_request_found_r ? xlate_request_index_r :
        xlate_alloc_select_load ? load_free_index_r : store_free_index_r;
    wire [TAG_WIDTH-1:0] xlate_request_load_array_index =
        xlate_request_store_r ? {TAG_WIDTH{1'b0}} :
        xlate_request_index_r;
    wire [TAG_WIDTH-1:0] xlate_request_store_array_index =
        xlate_request_store_r ?
        (xlate_request_index_r - LOAD_QUEUE_DEPTH) :
        {TAG_WIDTH{1'b0}};

    assign xlate_req_valid_o =
        (xlate_request_found_r || xlate_request_from_alloc) &&
        !atomic_active_i && !squash_younger_i;
    assign xlate_req_tag_o = xlate_request_tag;
    assign xlate_req_write_o = xlate_request_found_r ?
        xlate_request_store_r : xlate_alloc_select_store;
    assign xlate_req_size_o = xlate_request_found_r ?
        (xlate_request_store_r ?
         store_size_q[xlate_request_store_array_index] :
         load_size_q[xlate_request_load_array_index]) :
        (xlate_alloc_select_load ? load_alloc_size_i : store_alloc_size_i);
    assign xlate_req_vaddr_o = xlate_request_found_r ?
        (xlate_request_store_r ?
         store_vaddr_q[xlate_request_store_array_index] :
         load_vaddr_q[xlate_request_load_array_index]) :
        (xlate_alloc_select_load ? load_alloc_vaddr_i : store_alloc_vaddr_i);
    wire xlate_req_fire = xlate_req_valid_o && xlate_req_ready_i;

    // The memory port selects the oldest translated operation which can make
    // progress.  Multiple loads may remain outstanding behind this one-cycle
    // launch port.
    integer request_scan;
    reg request_found_r;
    reg request_store_r;
    reg [TAG_WIDTH-1:0] request_index_r;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] request_id_r;
    reg request_candidate_r;
    always @* begin
        request_found_r = 1'b0;
        request_store_r = 1'b0;
        request_index_r = {TAG_WIDTH{1'b0}};
        request_id_r = {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        request_candidate_r = 1'b0;
        for (request_scan = 0; request_scan < LOAD_QUEUE_DEPTH;
             request_scan = request_scan + 1) begin
            request_candidate_r =
                load_valid_q[request_scan] &&
                !load_killed_q[request_scan] &&
                !load_immediate_q[request_scan] &&
                load_xlate_done_q[request_scan] &&
                !load_xlate_fault[request_scan] &&
                !load_access_sent_q[request_scan] &&
                !load_guard_block_r[request_scan] &&
                (load_cacheable[request_scan] ||
                 load_order_match[request_scan]);
            if (request_candidate_r &&
                (!request_found_r ||
                 id_is_younger(request_id_r,
                               load_id_q[request_scan]))) begin
                request_found_r = 1'b1;
                request_store_r = 1'b0;
                request_index_r = request_scan;
                request_id_r = load_id_q[request_scan];
            end
        end
        for (request_scan = 0; request_scan < STORE_QUEUE_DEPTH;
             request_scan = request_scan + 1) begin
            request_candidate_r =
                store_valid_q[request_scan] &&
                !store_killed_q[request_scan] &&
                !store_atomic_q[request_scan] &&
                !store_immediate_q[request_scan] &&
                store_xlate_done_q[request_scan] &&
                !store_xlate_fault[request_scan] &&
                !store_access_sent_q[request_scan] &&
                store_order_match[request_scan];
            if (request_candidate_r &&
                (!request_found_r ||
                 id_is_younger(request_id_r, store_id_q[request_scan]))) begin
                request_found_r = 1'b1;
                request_store_r = 1'b1;
                request_index_r = LOAD_QUEUE_DEPTH + request_scan;
                request_id_r = store_id_q[request_scan];
            end
        end
    end
    wire [TAG_WIDTH-1:0] request_store_array_index =
        request_store_r ? (request_index_r - LOAD_QUEUE_DEPTH) :
        {TAG_WIDTH{1'b0}};
    wire [TAG_WIDTH-1:0] request_load_array_index =
        request_store_r ? {TAG_WIDTH{1'b0}} : request_index_r;
    assign req_valid_o = request_found_r && !atomic_active_i &&
                         !squash_younger_i;
    assign req_tag_o = request_index_r;
    assign req_write_o = request_store_r;
    assign req_pmp_checked_o = request_store_r ?
        store_pmp_checked_q[request_store_array_index] :
        load_pmp_checked_q[request_load_array_index];
    assign req_addr_o = request_store_r ?
        store_paddr_q[request_store_array_index] :
        load_paddr_q[request_load_array_index];
    assign req_vaddr_o = request_store_r ?
        store_vaddr_q[request_store_array_index] :
        load_vaddr_q[request_load_array_index];
    assign req_size_o = request_store_r ?
        store_size_q[request_store_array_index] :
        load_size_q[request_load_array_index];
    assign req_wdata_o = request_store_r ?
        store_wdata_q[request_store_array_index] : {`RV64_XLEN{1'b0}};
    assign req_wstrb_o = request_store_r ?
        store_wstrb_q[request_store_array_index] : 8'h00;
    wire req_fire = req_valid_o && req_ready_i;

    // Local results are immediate/fault completions and accepted cacheable
    // stores.  There is no local forwarded-load result in the guard-only cut.
    integer local_scan;
    reg local_found_r;
    reg local_store_r;
    reg [TAG_WIDTH-1:0] local_index_r;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] local_id_r;
    reg local_candidate_r;
    always @* begin
        local_found_r = 1'b0;
        local_store_r = 1'b0;
        local_index_r = {TAG_WIDTH{1'b0}};
        local_id_r = {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        local_candidate_r = 1'b0;
        for (local_scan = 0; local_scan < LOAD_QUEUE_DEPTH;
             local_scan = local_scan + 1) begin
            local_candidate_r = load_valid_q[local_scan] &&
                !load_killed_q[local_scan] &&
                !(squash_younger_i &&
                  id_is_younger(load_id_q[local_scan], squash_id_i)) &&
                (load_immediate_q[local_scan] ||
                 load_xlate_fault[local_scan]);
            if (local_candidate_r &&
                (!local_found_r ||
                 id_is_younger(local_id_r, load_id_q[local_scan]))) begin
                local_found_r = 1'b1;
                local_store_r = 1'b0;
                local_index_r = local_scan;
                local_id_r = load_id_q[local_scan];
            end
        end
        for (local_scan = 0; local_scan < STORE_QUEUE_DEPTH;
             local_scan = local_scan + 1) begin
            local_candidate_r =
                store_valid_q[local_scan] &&
                !store_killed_q[local_scan] &&
                !(squash_younger_i &&
                  id_is_younger(store_id_q[local_scan], squash_id_i)) &&
                !store_atomic_q[local_scan] &&
                (store_immediate_q[local_scan] ||
                 store_xlate_fault[local_scan] ||
                 (store_cacheable[local_scan] &&
                  ((store_access_sent_q[local_scan] &&
                    !store_result_sent_q[local_scan]) ||
                   (req_fire && request_store_r &&
                    (request_store_array_index == local_scan)))));
            if (local_candidate_r &&
                (!local_found_r ||
                 id_is_younger(local_id_r, store_id_q[local_scan]))) begin
                local_found_r = 1'b1;
                local_store_r = 1'b1;
                local_index_r = LOAD_QUEUE_DEPTH + local_scan;
                local_id_r = store_id_q[local_scan];
            end
        end
    end
    wire [TAG_WIDTH-1:0] local_store_array_index =
        local_store_r ? (local_index_r - LOAD_QUEUE_DEPTH) :
        {TAG_WIDTH{1'b0}};
    wire [TAG_WIDTH-1:0] local_load_array_index =
        local_store_r ? {TAG_WIDTH{1'b0}} : local_index_r;

    wire xlate_resp_load_tag_valid =
        xlate_resp_tag_i < LOAD_QUEUE_DEPTH;
    wire [TAG_WIDTH-1:0] xlate_resp_load_index =
        xlate_resp_load_tag_valid ? xlate_resp_tag_i :
        {TAG_WIDTH{1'b0}};
    wire xlate_resp_store_tag_valid =
        (xlate_resp_tag_i >= LOAD_QUEUE_DEPTH) &&
        (xlate_resp_tag_i < DEPTH);
    wire [TAG_WIDTH-1:0] xlate_resp_store_index =
        xlate_resp_store_tag_valid ?
        (xlate_resp_tag_i - LOAD_QUEUE_DEPTH) : {TAG_WIDTH{1'b0}};
    wire xlate_resp_matches_request = xlate_req_fire &&
        (xlate_req_tag_o == xlate_resp_tag_i);
    wire xlate_resp_matches_allocation =
        xlate_resp_matches_request && xlate_request_from_alloc;
    wire xlate_resp_slot_valid = xlate_resp_load_tag_valid ?
        load_valid_q[xlate_resp_load_index] :
        (xlate_resp_store_tag_valid ?
         store_valid_q[xlate_resp_store_index] : 1'b0);
    wire xlate_resp_slot_sent = xlate_resp_load_tag_valid ?
        load_xlate_sent_q[xlate_resp_load_index] :
        (xlate_resp_store_tag_valid ?
         store_xlate_sent_q[xlate_resp_store_index] : 1'b0);
    wire xlate_resp_is_expected =
        (xlate_resp_slot_valid &&
         (xlate_resp_slot_sent || xlate_resp_matches_request)) ||
        xlate_resp_matches_allocation;
    assign xlate_resp_ready_o = 1'b1;
    wire xlate_resp_fire = xlate_resp_valid_i && xlate_resp_is_expected;

    wire resp_load_tag_valid = resp_tag_i < LOAD_QUEUE_DEPTH;
    wire [TAG_WIDTH-1:0] resp_load_index =
        resp_load_tag_valid ? resp_tag_i : {TAG_WIDTH{1'b0}};
    wire resp_store_tag_valid = (resp_tag_i >= LOAD_QUEUE_DEPTH) &&
                                (resp_tag_i < DEPTH);
    wire [TAG_WIDTH-1:0] resp_store_index =
        resp_store_tag_valid ? (resp_tag_i - LOAD_QUEUE_DEPTH) :
        {TAG_WIDTH{1'b0}};
    wire resp_slot_valid = resp_load_tag_valid ?
        load_valid_q[resp_load_index] :
        (resp_store_tag_valid ? store_valid_q[resp_store_index] : 1'b0);
    wire resp_slot_killed = resp_load_tag_valid ?
        load_killed_q[resp_load_index] :
        (resp_store_tag_valid ? store_killed_q[resp_store_index] : 1'b0);
    wire resp_slot_access_sent = resp_load_tag_valid ?
        load_access_sent_q[resp_load_index] :
        (resp_store_tag_valid ?
         store_access_sent_q[resp_store_index] : 1'b0);
    wire resp_is_access = resp_slot_valid && resp_slot_access_sent;
    wire resp_is_store = resp_is_access && resp_store_tag_valid;
    wire resp_is_posted_store = resp_is_store &&
        !store_atomic_q[resp_store_index] &&
        store_cacheable[resp_store_index];
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] resp_id =
        resp_load_tag_valid ? load_id_q[resp_load_index] :
        store_id_q[resp_store_index];
    assign resp_ready_o = resp_is_access ?
        ((resp_slot_killed || resp_is_posted_store) ?
         1'b1 : result_ready_i) : 1'b1;
    wire resp_fire = resp_valid_i && resp_ready_o;
    wire posted_store_resp_fire = resp_fire &&
                                  resp_is_posted_store &&
                                  !resp_slot_killed;

    wire store_done_tag_valid =
        (store_done_tag_i >= LOAD_QUEUE_DEPTH) &&
        (store_done_tag_i < DEPTH);
    wire [TAG_WIDTH-1:0] store_done_index =
        store_done_tag_valid ? (store_done_tag_i - LOAD_QUEUE_DEPTH) :
        {TAG_WIDTH{1'b0}};
    wire store_done_slot_valid = store_done_tag_valid &&
        store_valid_q[store_done_index];
    wire store_done_slot_killed = store_done_slot_valid &&
        store_killed_q[store_done_index];
    wire store_done_is_expected = store_done_slot_valid &&
        store_access_sent_q[store_done_index] &&
        !store_atomic_q[store_done_index] &&
        store_cacheable[store_done_index];
    assign store_done_ready_o = 1'b1;
    wire store_done_fire = store_done_valid_i &&
                           store_done_is_expected &&
                           !store_done_slot_killed;
    wire store_done_killed_fire = store_done_valid_i &&
                                  store_done_is_expected &&
                                  store_done_slot_killed;
    wire posted_store_done_fire =
        store_done_fire || posted_store_resp_fire;
    wire [TAG_WIDTH-1:0] posted_store_done_tag =
        store_done_fire ? store_done_tag_i : resp_tag_i;
    wire [TAG_WIDTH-1:0] posted_store_done_index =
        posted_store_done_tag - LOAD_QUEUE_DEPTH;

    wire access_resp_squashed_now = resp_valid_i && resp_is_access &&
        squash_younger_i && id_is_younger(resp_id, squash_id_i);
    wire access_resp_result = resp_valid_i && resp_is_access &&
        !resp_slot_killed && !resp_is_posted_store &&
        !access_resp_squashed_now;
    assign result_valid_o = access_resp_result || local_found_r;
    wire result_select_resp = access_resp_result;
    wire result_store_select = result_select_resp ?
        resp_is_store : local_store_r;
    wire [TAG_WIDTH-1:0] result_index =
        result_select_resp ? resp_tag_i : local_index_r;
    wire [TAG_WIDTH-1:0] result_store_index =
        result_store_select ? (result_index - LOAD_QUEUE_DEPTH) :
        {TAG_WIDTH{1'b0}};
    wire [TAG_WIDTH-1:0] result_load_index =
        result_store_select ? {TAG_WIDTH{1'b0}} : result_index;
    assign result_id_o = result_store_select ?
        store_id_q[result_store_index] : load_id_q[result_load_index];
    assign result_slot_o = result_store_select ?
        store_retire_q[result_store_index] :
        load_retire_q[result_load_index];
    assign result_meta_o = result_store_select ?
        store_meta_q[result_store_index] : load_meta_q[result_load_index];
    assign result_vaddr_o = result_store_select ?
        store_vaddr_q[result_store_index] :
        load_vaddr_q[result_load_index];
    assign result_store_o = result_store_select;
    assign result_rdata_o = result_select_resp ?
        resp_rdata_i : {`RV64_XLEN{1'b0}};
    assign result_access_fault_o = result_select_resp ?
        resp_access_fault_i :
        (result_store_select ?
         (store_input_access_fault_q[result_store_index] ||
          store_xlate_access_fault_q[result_store_index]) :
         (load_input_access_fault_q[result_load_index] ||
          load_xlate_access_fault_q[result_load_index]));
    assign result_page_fault_o = result_select_resp ?
        resp_page_fault_i :
        (result_store_select ?
         store_xlate_page_fault_q[result_store_index] :
         load_xlate_page_fault_q[result_load_index]);
    wire result_fire = result_valid_o && result_ready_i;
    wire result_is_posted_store = !result_select_resp &&
        local_found_r && local_store_r &&
        store_cacheable[local_store_array_index] &&
        ((store_access_sent_q[local_store_array_index] &&
          !store_result_sent_q[local_store_array_index]) ||
         (req_fire && request_store_r &&
          (request_store_array_index == local_store_array_index)));
    wire posted_store_result_fire = result_fire &&
                                    result_is_posted_store;
    wire posted_store_result_done_same = posted_store_result_fire &&
        posted_store_done_fire &&
        (result_store_index == posted_store_done_index);

    integer atomic_scan;
    reg atomic_start_found_r;
    reg [TAG_WIDTH-1:0] atomic_start_array_index_r;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] atomic_start_id_r;
    always @* begin
        atomic_start_found_r = 1'b0;
        atomic_start_array_index_r = {TAG_WIDTH{1'b0}};
        atomic_start_id_r = {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        for (atomic_scan = 0; atomic_scan < STORE_QUEUE_DEPTH;
             atomic_scan = atomic_scan + 1) begin
            if (store_valid_q[atomic_scan] &&
                !store_killed_q[atomic_scan] &&
                store_atomic_q[atomic_scan] &&
                store_order_match[atomic_scan] &&
                (!atomic_start_found_r ||
                 id_is_younger(atomic_start_id_r,
                               store_id_q[atomic_scan]))) begin
                atomic_start_found_r = 1'b1;
                atomic_start_array_index_r = atomic_scan;
                atomic_start_id_r = store_id_q[atomic_scan];
            end
        end
    end
    assign atomic_start_valid_o = atomic_start_found_r && !atomic_active_i;
    assign atomic_start_tag_o =
        LOAD_QUEUE_DEPTH + atomic_start_array_index_r;
    assign atomic_start_id_o = store_id_q[atomic_start_array_index_r];
    assign atomic_start_slot_o =
        store_retire_q[atomic_start_array_index_r];
    assign atomic_start_meta_o = store_meta_q[atomic_start_array_index_r];
    assign atomic_start_vaddr_o =
        store_vaddr_q[atomic_start_array_index_r];
    assign atomic_start_size_o =
        store_size_q[atomic_start_array_index_r];
    assign atomic_start_wdata_o =
        store_wdata_q[atomic_start_array_index_r];
    assign atomic_start_access_allowed_o =
        !store_input_access_fault_q[atomic_start_array_index_r];

    integer pending_scan;
    reg any_load_valid_r;
    reg any_store_r;
    reg any_store_valid_r;
    reg any_transaction_inflight_r;
    always @* begin
        any_load_valid_r = 1'b0;
        any_store_r = 1'b0;
        any_store_valid_r = 1'b0;
        any_transaction_inflight_r = 1'b0;
        for (pending_scan = 0; pending_scan < LOAD_QUEUE_DEPTH;
             pending_scan = pending_scan + 1) begin
            if (load_valid_q[pending_scan])
                any_load_valid_r = 1'b1;
            if (load_valid_q[pending_scan] &&
                (load_xlate_sent_q[pending_scan] ||
                 load_access_sent_q[pending_scan]))
                any_transaction_inflight_r = 1'b1;
        end
        for (pending_scan = 0; pending_scan < STORE_QUEUE_DEPTH;
             pending_scan = pending_scan + 1) begin
            if (store_valid_q[pending_scan])
                any_store_valid_r = 1'b1;
            if (store_valid_q[pending_scan] &&
                !store_killed_q[pending_scan])
                any_store_r = 1'b1;
            if (store_valid_q[pending_scan] &&
                (store_xlate_sent_q[pending_scan] ||
                 store_access_sent_q[pending_scan]))
                any_transaction_inflight_r = 1'b1;
        end
    end
    assign store_pending_o = any_store_r || atomic_active_i;
    assign quiescent_o = !any_transaction_inflight_r && !atomic_active_i;
    assign empty_o = !any_load_valid_r && !any_store_valid_r &&
                     !atomic_active_i;

    wire atomic_tag_is_store = (atomic_tag_i >= LOAD_QUEUE_DEPTH) &&
                               (atomic_tag_i < DEPTH);
    wire [TAG_WIDTH-1:0] atomic_store_index =
        atomic_tag_is_store ? (atomic_tag_i - LOAD_QUEUE_DEPTH) :
        {TAG_WIDTH{1'b0}};

    integer state_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (state_index = 0; state_index < LOAD_QUEUE_DEPTH;
                 state_index = state_index + 1) begin
                load_valid_q[state_index] <= 1'b0;
                load_immediate_q[state_index] <= 1'b0;
                load_input_access_fault_q[state_index] <= 1'b0;
                load_xlate_sent_q[state_index] <= 1'b0;
                load_xlate_done_q[state_index] <= 1'b0;
                load_pmp_checked_q[state_index] <= 1'b0;
                load_xlate_access_fault_q[state_index] <= 1'b0;
                load_xlate_page_fault_q[state_index] <= 1'b0;
                load_access_sent_q[state_index] <= 1'b0;
                load_killed_q[state_index] <= 1'b0;
                load_id_q[state_index] <=
                    {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
                load_retire_q[state_index] <=
                    {RETIRE_SLOT_WIDTH{1'b0}};
                load_meta_q[state_index] <= {META_WIDTH{1'b0}};
                load_vaddr_q[state_index] <= {`RV64_XLEN{1'b0}};
                load_paddr_q[state_index] <= {`RV64_XLEN{1'b0}};
                load_size_q[state_index] <= 3'd0;
            end
            for (state_index = 0; state_index < STORE_QUEUE_DEPTH;
                 state_index = state_index + 1) begin
                store_valid_q[state_index] <= 1'b0;
                store_atomic_q[state_index] <= 1'b0;
                store_immediate_q[state_index] <= 1'b0;
                store_input_access_fault_q[state_index] <= 1'b0;
                store_xlate_sent_q[state_index] <= 1'b0;
                store_xlate_done_q[state_index] <= 1'b0;
                store_pmp_checked_q[state_index] <= 1'b0;
                store_xlate_access_fault_q[state_index] <= 1'b0;
                store_xlate_page_fault_q[state_index] <= 1'b0;
                store_access_sent_q[state_index] <= 1'b0;
                store_result_sent_q[state_index] <= 1'b0;
                store_access_done_q[state_index] <= 1'b0;
                store_killed_q[state_index] <= 1'b0;
                store_id_q[state_index] <=
                    {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
                store_retire_q[state_index] <=
                    {RETIRE_SLOT_WIDTH{1'b0}};
                store_meta_q[state_index] <= {META_WIDTH{1'b0}};
                store_vaddr_q[state_index] <= {`RV64_XLEN{1'b0}};
                store_paddr_q[state_index] <= {`RV64_XLEN{1'b0}};
                store_size_q[state_index] <= 3'd0;
                store_wdata_q[state_index] <= {`RV64_XLEN{1'b0}};
                store_wstrb_q[state_index] <= 8'h00;
                store_guard_hash_q[state_index] <=
                    {GUARD_HASH_WIDTH{1'b0}};
            end
        end else if (flush_i) begin
            // Full redirects cancel all loads.  ICX owns cancellation of
            // physical loads already in flight and suppresses their responses.
            for (state_index = 0; state_index < LOAD_QUEUE_DEPTH;
                 state_index = state_index + 1) begin
                load_valid_q[state_index] <= 1'b0;
                load_xlate_sent_q[state_index] <= 1'b0;
                load_access_sent_q[state_index] <= 1'b0;
                load_killed_q[state_index] <= 1'b0;
            end
            for (state_index = 0; state_index < STORE_QUEUE_DEPTH;
                 state_index = state_index + 1) begin
                if ((store_valid_q[state_index] &&
                     store_access_sent_q[state_index]) ||
                    (atomic_irrevocable_i && atomic_tag_is_store &&
                     (atomic_store_index == state_index))) begin
                    store_valid_q[state_index] <= 1'b1;
                end else begin
                    store_valid_q[state_index] <= 1'b0;
                    store_xlate_sent_q[state_index] <= 1'b0;
                    store_access_sent_q[state_index] <= 1'b0;
                    store_result_sent_q[state_index] <= 1'b0;
                    store_access_done_q[state_index] <= 1'b0;
                    store_killed_q[state_index] <= 1'b0;
                end
            end
            if (result_fire && result_store_select) begin
                if (result_is_posted_store) begin
                    store_result_sent_q[result_store_index] <= 1'b1;
                    if (store_access_done_q[result_store_index] ||
                        posted_store_result_done_same) begin
                        store_valid_q[result_store_index] <= 1'b0;
                        store_access_sent_q[result_store_index] <= 1'b0;
                        store_result_sent_q[result_store_index] <= 1'b0;
                        store_access_done_q[result_store_index] <= 1'b0;
                    end
                end else begin
                    store_valid_q[result_store_index] <= 1'b0;
                    store_xlate_sent_q[result_store_index] <= 1'b0;
                    store_access_sent_q[result_store_index] <= 1'b0;
                end
            end
            if (posted_store_done_fire) begin
                store_access_done_q[posted_store_done_index] <= 1'b1;
                if (store_result_sent_q[posted_store_done_index] ||
                    posted_store_result_done_same) begin
                    store_valid_q[posted_store_done_index] <= 1'b0;
                    store_access_sent_q[posted_store_done_index] <= 1'b0;
                    store_result_sent_q[posted_store_done_index] <= 1'b0;
                    store_access_done_q[posted_store_done_index] <= 1'b0;
                end
            end
            if (atomic_done_i && atomic_tag_is_store)
                store_valid_q[atomic_store_index] <= 1'b0;
        end else begin
            if (load_alloc_fire) begin
                load_valid_q[load_free_index_r] <= 1'b1;
                load_immediate_q[load_free_index_r] <=
                    load_alloc_immediate_i;
                load_input_access_fault_q[load_free_index_r] <=
                    load_alloc_access_fault_i;
                load_xlate_sent_q[load_free_index_r] <= 1'b0;
                load_xlate_done_q[load_free_index_r] <=
                    load_alloc_immediate_i;
                load_pmp_checked_q[load_free_index_r] <= 1'b0;
                load_xlate_access_fault_q[load_free_index_r] <= 1'b0;
                load_xlate_page_fault_q[load_free_index_r] <= 1'b0;
                load_access_sent_q[load_free_index_r] <= 1'b0;
                load_killed_q[load_free_index_r] <= 1'b0;
                load_id_q[load_free_index_r] <= load_alloc_id_i;
                load_retire_q[load_free_index_r] <= load_alloc_slot_i;
                load_meta_q[load_free_index_r] <= load_alloc_meta_i;
                load_vaddr_q[load_free_index_r] <= load_alloc_vaddr_i;
                load_paddr_q[load_free_index_r] <= translation_bypass_i ?
                    load_alloc_vaddr_i : {`RV64_XLEN{1'b0}};
                load_size_q[load_free_index_r] <= load_alloc_size_i;
            end
            if (store_alloc_fire) begin
                store_valid_q[store_free_array_index_r] <= 1'b1;
                store_atomic_q[store_free_array_index_r] <=
                    store_alloc_atomic_i;
                store_immediate_q[store_free_array_index_r] <=
                    store_alloc_immediate_i;
                store_input_access_fault_q[store_free_array_index_r] <=
                    store_alloc_access_fault_i;
                store_xlate_sent_q[store_free_array_index_r] <= 1'b0;
                store_xlate_done_q[store_free_array_index_r] <=
                    store_alloc_immediate_i || store_alloc_atomic_i;
                store_pmp_checked_q[store_free_array_index_r] <= 1'b0;
                store_xlate_access_fault_q[store_free_array_index_r] <= 1'b0;
                store_xlate_page_fault_q[store_free_array_index_r] <= 1'b0;
                store_access_sent_q[store_free_array_index_r] <= 1'b0;
                store_result_sent_q[store_free_array_index_r] <= 1'b0;
                store_access_done_q[store_free_array_index_r] <= 1'b0;
                store_killed_q[store_free_array_index_r] <= 1'b0;
                store_id_q[store_free_array_index_r] <= store_alloc_id_i;
                store_retire_q[store_free_array_index_r] <=
                    store_alloc_slot_i;
                store_meta_q[store_free_array_index_r] <= store_alloc_meta_i;
                store_vaddr_q[store_free_array_index_r] <=
                    store_alloc_vaddr_i;
                store_paddr_q[store_free_array_index_r] <=
                    translation_bypass_i ? store_alloc_vaddr_i :
                    {`RV64_XLEN{1'b0}};
                store_size_q[store_free_array_index_r] <=
                    store_alloc_size_i;
                store_wdata_q[store_free_array_index_r] <=
                    store_alloc_wdata_i;
                store_wstrb_q[store_free_array_index_r] <=
                    store_alloc_wstrb_i;
                store_guard_hash_q[store_free_array_index_r] <=
                    cacheline_hash(store_alloc_vaddr_i);
            end
            if (xlate_req_fire) begin
                if (xlate_request_tag < LOAD_QUEUE_DEPTH)
                    load_xlate_sent_q[xlate_request_tag] <= 1'b1;
                else
                    store_xlate_sent_q[
                        xlate_request_tag - LOAD_QUEUE_DEPTH] <= 1'b1;
            end
            if (req_fire) begin
                if (request_store_r)
                    store_access_sent_q[request_store_array_index] <= 1'b1;
                else
                    load_access_sent_q[request_load_array_index] <= 1'b1;
            end
            if (xlate_resp_fire) begin
                if (xlate_resp_load_tag_valid) begin
                    load_xlate_sent_q[xlate_resp_load_index] <= 1'b0;
                    load_xlate_done_q[xlate_resp_load_index] <= 1'b1;
                    load_pmp_checked_q[xlate_resp_load_index] <= 1'b1;
                    load_xlate_access_fault_q[xlate_resp_load_index] <=
                        xlate_resp_access_fault_i;
                    load_xlate_page_fault_q[xlate_resp_load_index] <=
                        xlate_resp_page_fault_i;
                    load_paddr_q[xlate_resp_load_index] <=
                        xlate_resp_paddr_i;
                end else begin
                    store_xlate_sent_q[xlate_resp_store_index] <= 1'b0;
                    store_xlate_done_q[xlate_resp_store_index] <= 1'b1;
                    store_pmp_checked_q[xlate_resp_store_index] <= 1'b1;
                    store_xlate_access_fault_q[xlate_resp_store_index] <=
                        xlate_resp_access_fault_i;
                    store_xlate_page_fault_q[xlate_resp_store_index] <=
                        xlate_resp_page_fault_i;
                    store_paddr_q[xlate_resp_store_index] <=
                        xlate_resp_paddr_i;
                    store_guard_hash_q[xlate_resp_store_index] <=
                        cacheline_hash(xlate_resp_paddr_i);
                end
            end
            if (resp_fire && resp_is_access && resp_slot_killed) begin
                if (resp_load_tag_valid) begin
                    load_valid_q[resp_load_index] <= 1'b0;
                    load_killed_q[resp_load_index] <= 1'b0;
                    load_access_sent_q[resp_load_index] <= 1'b0;
                end else begin
                    store_valid_q[resp_store_index] <= 1'b0;
                    store_killed_q[resp_store_index] <= 1'b0;
                    store_access_sent_q[resp_store_index] <= 1'b0;
                    store_result_sent_q[resp_store_index] <= 1'b0;
                    store_access_done_q[resp_store_index] <= 1'b0;
                end
            end
            if (store_done_killed_fire) begin
                store_valid_q[store_done_index] <= 1'b0;
                store_killed_q[store_done_index] <= 1'b0;
                store_access_sent_q[store_done_index] <= 1'b0;
                store_result_sent_q[store_done_index] <= 1'b0;
                store_access_done_q[store_done_index] <= 1'b0;
            end
            if (result_fire) begin
                if (result_store_select) begin
                    if (result_is_posted_store) begin
                        store_result_sent_q[result_store_index] <= 1'b1;
                        if (store_access_done_q[result_store_index] ||
                            posted_store_result_done_same) begin
                            store_valid_q[result_store_index] <= 1'b0;
                            store_access_sent_q[result_store_index] <= 1'b0;
                            store_result_sent_q[result_store_index] <= 1'b0;
                            store_access_done_q[result_store_index] <= 1'b0;
                        end
                    end else begin
                        store_valid_q[result_store_index] <= 1'b0;
                        store_xlate_sent_q[result_store_index] <= 1'b0;
                        store_access_sent_q[result_store_index] <= 1'b0;
                    end
                end else begin
                    load_valid_q[result_load_index] <= 1'b0;
                    load_xlate_sent_q[result_load_index] <= 1'b0;
                    load_access_sent_q[result_load_index] <= 1'b0;
                    load_killed_q[result_load_index] <= 1'b0;
                end
            end
            if (posted_store_done_fire) begin
                store_access_done_q[posted_store_done_index] <= 1'b1;
                if (store_result_sent_q[posted_store_done_index] ||
                    posted_store_result_done_same) begin
                    store_valid_q[posted_store_done_index] <= 1'b0;
                    store_access_sent_q[posted_store_done_index] <= 1'b0;
                    store_result_sent_q[posted_store_done_index] <= 1'b0;
                    store_access_done_q[posted_store_done_index] <= 1'b0;
                end
            end
            if (atomic_done_i && atomic_tag_is_store)
                store_valid_q[atomic_store_index] <= 1'b0;

            if (squash_younger_i) begin
                for (state_index = 0; state_index < LOAD_QUEUE_DEPTH;
                     state_index = state_index + 1) begin
                    if (load_valid_q[state_index] &&
                        id_is_younger(load_id_q[state_index],
                                      squash_id_i)) begin
                        if (load_access_sent_q[state_index] &&
                            !(resp_fire && resp_load_tag_valid &&
                              (resp_load_index == state_index))) begin
                            load_killed_q[state_index] <= 1'b1;
                        end else begin
                            load_valid_q[state_index] <= 1'b0;
                            load_killed_q[state_index] <= 1'b0;
                            load_xlate_sent_q[state_index] <= 1'b0;
                            load_access_sent_q[state_index] <= 1'b0;
                        end
                    end
                end
                for (state_index = 0; state_index < STORE_QUEUE_DEPTH;
                     state_index = state_index + 1) begin
                    if (store_valid_q[state_index] &&
                        id_is_younger(store_id_q[state_index],
                                      squash_id_i)) begin
                        if (store_access_sent_q[state_index] &&
                            !((resp_fire && resp_store_tag_valid &&
                               (resp_store_index == state_index)) ||
                              ((store_done_fire ||
                                store_done_killed_fire) &&
                               (store_done_index == state_index)))) begin
                            store_killed_q[state_index] <= 1'b1;
                        end else begin
                            store_valid_q[state_index] <= 1'b0;
                            store_killed_q[state_index] <= 1'b0;
                            store_xlate_sent_q[state_index] <= 1'b0;
                            store_access_sent_q[state_index] <= 1'b0;
                            store_result_sent_q[state_index] <= 1'b0;
                            store_access_done_q[state_index] <= 1'b0;
                        end
                    end
                end
            end
        end
    end

    // Simulation compatibility view for existing trace tools.  These are
    // aliases, not duplicated storage.
    wire slot_valid_q [0:DEPTH-1];
    wire slot_store_q [0:DEPTH-1];
    wire slot_atomic_q [0:DEPTH-1];
    wire slot_immediate_q [0:DEPTH-1];
    wire slot_input_access_fault_q [0:DEPTH-1];
    wire slot_xlate_sent_q [0:DEPTH-1];
    wire slot_xlate_done_q [0:DEPTH-1];
    wire slot_pmp_checked_q [0:DEPTH-1];
    wire slot_xlate_access_fault_q [0:DEPTH-1];
    wire slot_xlate_page_fault_q [0:DEPTH-1];
    wire slot_access_sent_q [0:DEPTH-1];
    wire slot_store_result_sent_q [0:DEPTH-1];
    wire slot_access_done_q [0:DEPTH-1];
    wire slot_killed_q [0:DEPTH-1];
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] slot_id_q [0:DEPTH-1];
    wire [RETIRE_SLOT_WIDTH-1:0] slot_retire_q [0:DEPTH-1];
    wire [META_WIDTH-1:0] slot_meta_q [0:DEPTH-1];
    wire [`RV64_XLEN-1:0] slot_vaddr_q [0:DEPTH-1];
    wire [`RV64_XLEN-1:0] slot_paddr_q [0:DEPTH-1];
    wire [2:0] slot_size_q [0:DEPTH-1];
    wire [`RV64_XLEN-1:0] slot_wdata_q [0:DEPTH-1];
    wire [7:0] slot_wstrb_q [0:DEPTH-1];
    wire slot_xlate_fault [0:DEPTH-1];
    wire slot_cacheable [0:DEPTH-1];
    wire slot_order_match [0:DEPTH-1];
    wire load_block_r [0:DEPTH-1];
    wire load_forward_r [0:DEPTH-1];

    genvar compatibility_gen;
    generate
        for (compatibility_gen = 0; compatibility_gen < DEPTH;
             compatibility_gen = compatibility_gen + 1) begin :
                g_compatibility_view
            if (compatibility_gen < LOAD_QUEUE_DEPTH) begin : g_load
                assign slot_valid_q[compatibility_gen] =
                    load_valid_q[compatibility_gen];
                assign slot_store_q[compatibility_gen] = 1'b0;
                assign slot_atomic_q[compatibility_gen] = 1'b0;
                assign slot_immediate_q[compatibility_gen] =
                    load_immediate_q[compatibility_gen];
                assign slot_input_access_fault_q[compatibility_gen] =
                    load_input_access_fault_q[compatibility_gen];
                assign slot_xlate_sent_q[compatibility_gen] =
                    load_xlate_sent_q[compatibility_gen];
                assign slot_xlate_done_q[compatibility_gen] =
                    load_xlate_done_q[compatibility_gen];
                assign slot_pmp_checked_q[compatibility_gen] =
                    load_pmp_checked_q[compatibility_gen];
                assign slot_xlate_access_fault_q[compatibility_gen] =
                    load_xlate_access_fault_q[compatibility_gen];
                assign slot_xlate_page_fault_q[compatibility_gen] =
                    load_xlate_page_fault_q[compatibility_gen];
                assign slot_access_sent_q[compatibility_gen] =
                    load_access_sent_q[compatibility_gen];
                assign slot_store_result_sent_q[compatibility_gen] = 1'b0;
                assign slot_access_done_q[compatibility_gen] = 1'b0;
                assign slot_killed_q[compatibility_gen] =
                    load_killed_q[compatibility_gen];
                assign slot_id_q[compatibility_gen] =
                    load_id_q[compatibility_gen];
                assign slot_retire_q[compatibility_gen] =
                    load_retire_q[compatibility_gen];
                assign slot_meta_q[compatibility_gen] =
                    load_meta_q[compatibility_gen];
                assign slot_vaddr_q[compatibility_gen] =
                    load_vaddr_q[compatibility_gen];
                assign slot_paddr_q[compatibility_gen] =
                    load_paddr_q[compatibility_gen];
                assign slot_size_q[compatibility_gen] =
                    load_size_q[compatibility_gen];
                assign slot_wdata_q[compatibility_gen] =
                    {`RV64_XLEN{1'b0}};
                assign slot_wstrb_q[compatibility_gen] = 8'h00;
                assign slot_xlate_fault[compatibility_gen] =
                    load_xlate_fault[compatibility_gen];
                assign slot_cacheable[compatibility_gen] =
                    load_cacheable[compatibility_gen];
                assign slot_order_match[compatibility_gen] =
                    load_order_match[compatibility_gen];
                assign load_block_r[compatibility_gen] =
                    load_guard_block_r[compatibility_gen];
                assign load_forward_r[compatibility_gen] = 1'b0;
            end else if ((compatibility_gen >= LOAD_QUEUE_DEPTH) &&
                         (compatibility_gen < DEPTH)) begin : g_store
                localparam integer STORE_INDEX =
                    compatibility_gen - LOAD_QUEUE_DEPTH;
                assign slot_valid_q[compatibility_gen] =
                    store_valid_q[STORE_INDEX];
                assign slot_store_q[compatibility_gen] = 1'b1;
                assign slot_atomic_q[compatibility_gen] =
                    store_atomic_q[STORE_INDEX];
                assign slot_immediate_q[compatibility_gen] =
                    store_immediate_q[STORE_INDEX];
                assign slot_input_access_fault_q[compatibility_gen] =
                    store_input_access_fault_q[STORE_INDEX];
                assign slot_xlate_sent_q[compatibility_gen] =
                    store_xlate_sent_q[STORE_INDEX];
                assign slot_xlate_done_q[compatibility_gen] =
                    store_xlate_done_q[STORE_INDEX];
                assign slot_pmp_checked_q[compatibility_gen] =
                    store_pmp_checked_q[STORE_INDEX];
                assign slot_xlate_access_fault_q[compatibility_gen] =
                    store_xlate_access_fault_q[STORE_INDEX];
                assign slot_xlate_page_fault_q[compatibility_gen] =
                    store_xlate_page_fault_q[STORE_INDEX];
                assign slot_access_sent_q[compatibility_gen] =
                    store_access_sent_q[STORE_INDEX];
                assign slot_store_result_sent_q[compatibility_gen] =
                    store_result_sent_q[STORE_INDEX];
                assign slot_access_done_q[compatibility_gen] =
                    store_access_done_q[STORE_INDEX];
                assign slot_killed_q[compatibility_gen] =
                    store_killed_q[STORE_INDEX];
                assign slot_id_q[compatibility_gen] =
                    store_id_q[STORE_INDEX];
                assign slot_retire_q[compatibility_gen] =
                    store_retire_q[STORE_INDEX];
                assign slot_meta_q[compatibility_gen] =
                    store_meta_q[STORE_INDEX];
                assign slot_vaddr_q[compatibility_gen] =
                    store_vaddr_q[STORE_INDEX];
                assign slot_paddr_q[compatibility_gen] =
                    store_paddr_q[STORE_INDEX];
                assign slot_size_q[compatibility_gen] =
                    store_size_q[STORE_INDEX];
                assign slot_wdata_q[compatibility_gen] =
                    store_wdata_q[STORE_INDEX];
                assign slot_wstrb_q[compatibility_gen] =
                    store_wstrb_q[STORE_INDEX];
                assign slot_xlate_fault[compatibility_gen] =
                    store_xlate_fault[STORE_INDEX];
                assign slot_cacheable[compatibility_gen] =
                    store_cacheable[STORE_INDEX];
                assign slot_order_match[compatibility_gen] =
                    store_order_match[STORE_INDEX];
                assign load_block_r[compatibility_gen] = 1'b0;
                assign load_forward_r[compatibility_gen] = 1'b0;
            end else begin : g_unused
                assign slot_valid_q[compatibility_gen] = 1'b0;
                assign slot_store_q[compatibility_gen] = 1'b0;
                assign slot_atomic_q[compatibility_gen] = 1'b0;
                assign slot_immediate_q[compatibility_gen] = 1'b0;
                assign slot_input_access_fault_q[compatibility_gen] = 1'b0;
                assign slot_xlate_sent_q[compatibility_gen] = 1'b0;
                assign slot_xlate_done_q[compatibility_gen] = 1'b0;
                assign slot_pmp_checked_q[compatibility_gen] = 1'b0;
                assign slot_xlate_access_fault_q[compatibility_gen] = 1'b0;
                assign slot_xlate_page_fault_q[compatibility_gen] = 1'b0;
                assign slot_access_sent_q[compatibility_gen] = 1'b0;
                assign slot_store_result_sent_q[compatibility_gen] = 1'b0;
                assign slot_access_done_q[compatibility_gen] = 1'b0;
                assign slot_killed_q[compatibility_gen] = 1'b0;
                assign slot_id_q[compatibility_gen] =
                    {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
                assign slot_retire_q[compatibility_gen] =
                    {RETIRE_SLOT_WIDTH{1'b0}};
                assign slot_meta_q[compatibility_gen] = {META_WIDTH{1'b0}};
                assign slot_vaddr_q[compatibility_gen] =
                    {`RV64_XLEN{1'b0}};
                assign slot_paddr_q[compatibility_gen] =
                    {`RV64_XLEN{1'b0}};
                assign slot_size_q[compatibility_gen] = 3'd0;
                assign slot_wdata_q[compatibility_gen] =
                    {`RV64_XLEN{1'b0}};
                assign slot_wstrb_q[compatibility_gen] = 8'h00;
                assign slot_xlate_fault[compatibility_gen] = 1'b0;
                assign slot_cacheable[compatibility_gen] = 1'b0;
                assign slot_order_match[compatibility_gen] = 1'b0;
                assign load_block_r[compatibility_gen] = 1'b0;
                assign load_forward_r[compatibility_gen] = 1'b0;
            end
        end
    endgenerate

`ifndef SYNTHESIS
    wire perf_load_alloc_order_match = ordered_head_valid_i &&
        (ordered_head_id_i == load_alloc_id_i) &&
        (ordered_head_slot_i == load_alloc_slot_i);
    wire perf_store_alloc_order_match = ordered_head_valid_i &&
        (ordered_head_id_i == store_alloc_id_i) &&
        (ordered_head_slot_i == store_alloc_slot_i);
    wire perf_xlate_order_match = xlate_request_from_alloc ?
        (xlate_alloc_select_load ? perf_load_alloc_order_match :
                                   perf_store_alloc_order_match) :
        slot_order_match[xlate_request_index_r];
    wire perf_load_result_fire = result_fire && !result_store_o;
    wire perf_store_result_fire = result_fire && result_store_o;
    wire perf_load_response_fire = resp_fire && resp_is_access &&
                                   !resp_is_store;
    wire perf_load_killed_response_fire = perf_load_response_fire &&
        (resp_slot_killed || access_resp_squashed_now);
    wire perf_store_killed_response_fire = store_done_killed_fire ||
        (resp_fire && resp_is_store && resp_slot_killed);

    integer perf_scan;
    integer perf_load_valid_count_r;
    integer perf_load_spec_count_r;
    integer perf_load_block_count_r;
    integer perf_load_squashed_count_r;
    integer perf_load_squashed_before_xlate_count_r;
    integer perf_load_squashed_xlate_inflight_count_r;
    integer perf_load_squashed_xlate_done_count_r;
    integer perf_load_squashed_access_inflight_count_r;
    integer perf_store_valid_count_r;
    integer perf_store_spec_count_r;
    integer perf_store_order_wait_count_r;
    integer perf_store_squashed_count_r;
    integer perf_store_squashed_before_xlate_count_r;
    integer perf_store_squashed_xlate_inflight_count_r;
    integer perf_store_squashed_xlate_done_count_r;
    integer perf_store_squashed_access_inflight_count_r;
    always @* begin
        perf_load_valid_count_r = 0;
        perf_load_spec_count_r = 0;
        perf_load_block_count_r = 0;
        perf_load_squashed_count_r = 0;
        perf_load_squashed_before_xlate_count_r = 0;
        perf_load_squashed_xlate_inflight_count_r = 0;
        perf_load_squashed_xlate_done_count_r = 0;
        perf_load_squashed_access_inflight_count_r = 0;
        perf_store_valid_count_r = 0;
        perf_store_spec_count_r = 0;
        perf_store_order_wait_count_r = 0;
        perf_store_squashed_count_r = 0;
        perf_store_squashed_before_xlate_count_r = 0;
        perf_store_squashed_xlate_inflight_count_r = 0;
        perf_store_squashed_xlate_done_count_r = 0;
        perf_store_squashed_access_inflight_count_r = 0;
        for (perf_scan = 0; perf_scan < LOAD_QUEUE_DEPTH;
             perf_scan = perf_scan + 1) begin
            if (load_valid_q[perf_scan] && !load_killed_q[perf_scan]) begin
                perf_load_valid_count_r = perf_load_valid_count_r + 1;
                if (!load_order_match[perf_scan])
                    perf_load_spec_count_r = perf_load_spec_count_r + 1;
                if (load_guard_block_r[perf_scan] &&
                    !load_immediate_q[perf_scan] &&
                    !load_input_access_fault_q[perf_scan] &&
                    !load_access_sent_q[perf_scan] &&
                    (load_cacheable[perf_scan] ||
                     load_order_match[perf_scan]))
                    perf_load_block_count_r = perf_load_block_count_r + 1;
            end
            if (squash_younger_i && load_valid_q[perf_scan] &&
                id_is_younger(load_id_q[perf_scan], squash_id_i)) begin
                perf_load_squashed_count_r =
                    perf_load_squashed_count_r + 1;
                if (load_access_sent_q[perf_scan])
                    perf_load_squashed_access_inflight_count_r =
                        perf_load_squashed_access_inflight_count_r + 1;
                else if (load_xlate_sent_q[perf_scan])
                    perf_load_squashed_xlate_inflight_count_r =
                        perf_load_squashed_xlate_inflight_count_r + 1;
                else if (load_xlate_done_q[perf_scan])
                    perf_load_squashed_xlate_done_count_r =
                        perf_load_squashed_xlate_done_count_r + 1;
                else
                    perf_load_squashed_before_xlate_count_r =
                        perf_load_squashed_before_xlate_count_r + 1;
            end
        end
        for (perf_scan = 0; perf_scan < STORE_QUEUE_DEPTH;
             perf_scan = perf_scan + 1) begin
            if (store_valid_q[perf_scan] && !store_killed_q[perf_scan]) begin
                perf_store_valid_count_r = perf_store_valid_count_r + 1;
                if (!store_order_match[perf_scan])
                    perf_store_spec_count_r = perf_store_spec_count_r + 1;
                if (!store_atomic_q[perf_scan] &&
                    store_xlate_done_q[perf_scan] &&
                    !store_xlate_fault[perf_scan] &&
                    !store_access_sent_q[perf_scan] &&
                    !store_order_match[perf_scan])
                    perf_store_order_wait_count_r =
                        perf_store_order_wait_count_r + 1;
            end
            if (squash_younger_i && store_valid_q[perf_scan] &&
                id_is_younger(store_id_q[perf_scan], squash_id_i)) begin
                perf_store_squashed_count_r =
                    perf_store_squashed_count_r + 1;
                if (store_access_sent_q[perf_scan])
                    perf_store_squashed_access_inflight_count_r =
                        perf_store_squashed_access_inflight_count_r + 1;
                else if (store_xlate_sent_q[perf_scan])
                    perf_store_squashed_xlate_inflight_count_r =
                        perf_store_squashed_xlate_inflight_count_r + 1;
                else if (store_xlate_done_q[perf_scan])
                    perf_store_squashed_xlate_done_count_r =
                        perf_store_squashed_xlate_done_count_r + 1;
                else
                    perf_store_squashed_before_xlate_count_r =
                        perf_store_squashed_before_xlate_count_r + 1;
            end
        end
    end

    reg [63:0] perf_load_allocations_q;
    reg [63:0] perf_load_spec_allocations_q;
    reg [63:0] perf_load_ordered_allocations_q;
    reg [63:0] perf_load_alloc_wait_cycles_q;
    reg [63:0] perf_load_queue_full_cycles_q;
    reg [63:0] perf_load_xlate_requests_q;
    reg [63:0] perf_load_spec_xlate_requests_q;
    reg [63:0] perf_load_xlate_wait_cycles_q;
    reg [63:0] perf_load_access_requests_q;
    reg [63:0] perf_load_spec_access_requests_q;
    reg [63:0] perf_load_ordered_access_requests_q;
    reg [63:0] perf_load_access_wait_cycles_q;
    reg [63:0] perf_load_responses_q;
    reg [63:0] perf_load_completions_q;
    reg [63:0] perf_load_forwarded_q;
    reg [63:0] perf_load_faults_q;
    reg [63:0] perf_load_squashed_q;
    reg [63:0] perf_load_squashed_before_xlate_q;
    reg [63:0] perf_load_squashed_xlate_inflight_q;
    reg [63:0] perf_load_squashed_xlate_done_q;
    reg [63:0] perf_load_squashed_access_inflight_q;
    reg [63:0] perf_load_flushed_q;
    reg [63:0] perf_load_killed_responses_q;
    reg [63:0] perf_load_dependency_block_cycles_q;
    reg [63:0] perf_load_dependency_block_entry_cycles_q;
    reg [63:0] perf_load_forward_ready_cycles_q;
    reg [63:0] perf_load_forward_ready_entry_cycles_q;
    reg [63:0] perf_load_occupancy_cycles_q;
    reg [63:0] perf_load_spec_occupancy_cycles_q;
    reg [63:0] perf_load_max_occupancy_q;
    reg [63:0] perf_store_allocations_q;
    reg [63:0] perf_store_spec_allocations_q;
    reg [63:0] perf_store_ordered_allocations_q;
    reg [63:0] perf_store_atomic_allocations_q;
    reg [63:0] perf_store_alloc_wait_cycles_q;
    reg [63:0] perf_store_queue_full_cycles_q;
    reg [63:0] perf_store_xlate_requests_q;
    reg [63:0] perf_store_spec_xlate_requests_q;
    reg [63:0] perf_store_xlate_wait_cycles_q;
    reg [63:0] perf_store_access_requests_q;
    reg [63:0] perf_store_access_wait_cycles_q;
    reg [63:0] perf_store_posted_results_q;
    reg [63:0] perf_store_done_q;
    reg [63:0] perf_store_squashed_q;
    reg [63:0] perf_store_squashed_before_xlate_q;
    reg [63:0] perf_store_squashed_xlate_inflight_q;
    reg [63:0] perf_store_squashed_xlate_done_q;
    reg [63:0] perf_store_squashed_access_inflight_q;
    reg [63:0] perf_store_flushed_q;
    reg [63:0] perf_store_killed_responses_q;
    reg [63:0] perf_store_order_wait_cycles_q;
    reg [63:0] perf_store_order_wait_entry_cycles_q;
    reg [63:0] perf_store_occupancy_cycles_q;
    reg [63:0] perf_store_spec_occupancy_cycles_q;
    reg [63:0] perf_store_max_occupancy_q;
    reg [63:0] perf_atomic_starts_q;
    reg [63:0] perf_atomic_done_q;
    reg [63:0] perf_atomic_active_cycles_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_load_allocations_q <= 0;
            perf_load_spec_allocations_q <= 0;
            perf_load_ordered_allocations_q <= 0;
            perf_load_alloc_wait_cycles_q <= 0;
            perf_load_queue_full_cycles_q <= 0;
            perf_load_xlate_requests_q <= 0;
            perf_load_spec_xlate_requests_q <= 0;
            perf_load_xlate_wait_cycles_q <= 0;
            perf_load_access_requests_q <= 0;
            perf_load_spec_access_requests_q <= 0;
            perf_load_ordered_access_requests_q <= 0;
            perf_load_access_wait_cycles_q <= 0;
            perf_load_responses_q <= 0;
            perf_load_completions_q <= 0;
            perf_load_forwarded_q <= 0;
            perf_load_faults_q <= 0;
            perf_load_squashed_q <= 0;
            perf_load_squashed_before_xlate_q <= 0;
            perf_load_squashed_xlate_inflight_q <= 0;
            perf_load_squashed_xlate_done_q <= 0;
            perf_load_squashed_access_inflight_q <= 0;
            perf_load_flushed_q <= 0;
            perf_load_killed_responses_q <= 0;
            perf_load_dependency_block_cycles_q <= 0;
            perf_load_dependency_block_entry_cycles_q <= 0;
            perf_load_forward_ready_cycles_q <= 0;
            perf_load_forward_ready_entry_cycles_q <= 0;
            perf_load_occupancy_cycles_q <= 0;
            perf_load_spec_occupancy_cycles_q <= 0;
            perf_load_max_occupancy_q <= 0;
            perf_store_allocations_q <= 0;
            perf_store_spec_allocations_q <= 0;
            perf_store_ordered_allocations_q <= 0;
            perf_store_atomic_allocations_q <= 0;
            perf_store_alloc_wait_cycles_q <= 0;
            perf_store_queue_full_cycles_q <= 0;
            perf_store_xlate_requests_q <= 0;
            perf_store_spec_xlate_requests_q <= 0;
            perf_store_xlate_wait_cycles_q <= 0;
            perf_store_access_requests_q <= 0;
            perf_store_access_wait_cycles_q <= 0;
            perf_store_posted_results_q <= 0;
            perf_store_done_q <= 0;
            perf_store_squashed_q <= 0;
            perf_store_squashed_before_xlate_q <= 0;
            perf_store_squashed_xlate_inflight_q <= 0;
            perf_store_squashed_xlate_done_q <= 0;
            perf_store_squashed_access_inflight_q <= 0;
            perf_store_flushed_q <= 0;
            perf_store_killed_responses_q <= 0;
            perf_store_order_wait_cycles_q <= 0;
            perf_store_order_wait_entry_cycles_q <= 0;
            perf_store_occupancy_cycles_q <= 0;
            perf_store_spec_occupancy_cycles_q <= 0;
            perf_store_max_occupancy_q <= 0;
            perf_atomic_starts_q <= 0;
            perf_atomic_done_q <= 0;
            perf_atomic_active_cycles_q <= 0;
        end else begin
            if (load_alloc_fire) begin
                perf_load_allocations_q <= perf_load_allocations_q + 1'b1;
                if (perf_load_alloc_order_match)
                    perf_load_ordered_allocations_q <=
                        perf_load_ordered_allocations_q + 1'b1;
                else
                    perf_load_spec_allocations_q <=
                        perf_load_spec_allocations_q + 1'b1;
            end
            if (load_alloc_valid_i && !load_alloc_ready_o)
                perf_load_alloc_wait_cycles_q <=
                    perf_load_alloc_wait_cycles_q + 1'b1;
            if (load_alloc_valid_i && !load_free_found_r)
                perf_load_queue_full_cycles_q <=
                    perf_load_queue_full_cycles_q + 1'b1;
            if (xlate_req_fire && !xlate_req_write_o) begin
                perf_load_xlate_requests_q <=
                    perf_load_xlate_requests_q + 1'b1;
                if (!perf_xlate_order_match)
                    perf_load_spec_xlate_requests_q <=
                        perf_load_spec_xlate_requests_q + 1'b1;
            end
            if (xlate_req_valid_o && !xlate_req_ready_i &&
                !xlate_req_write_o)
                perf_load_xlate_wait_cycles_q <=
                    perf_load_xlate_wait_cycles_q + 1'b1;
            if (req_fire && !req_write_o) begin
                perf_load_access_requests_q <=
                    perf_load_access_requests_q + 1'b1;
                if (load_order_match[request_load_array_index])
                    perf_load_ordered_access_requests_q <=
                        perf_load_ordered_access_requests_q + 1'b1;
                else
                    perf_load_spec_access_requests_q <=
                        perf_load_spec_access_requests_q + 1'b1;
            end
            if (req_valid_o && !req_ready_i && !req_write_o)
                perf_load_access_wait_cycles_q <=
                    perf_load_access_wait_cycles_q + 1'b1;
            if (perf_load_response_fire)
                perf_load_responses_q <= perf_load_responses_q + 1'b1;
            if (perf_load_result_fire) begin
                perf_load_completions_q <=
                    perf_load_completions_q + 1'b1;
                if (result_access_fault_o || result_page_fault_o)
                    perf_load_faults_q <= perf_load_faults_q + 1'b1;
            end
            perf_load_squashed_q <= perf_load_squashed_q +
                perf_load_squashed_count_r;
            perf_load_squashed_before_xlate_q <=
                perf_load_squashed_before_xlate_q +
                perf_load_squashed_before_xlate_count_r;
            perf_load_squashed_xlate_inflight_q <=
                perf_load_squashed_xlate_inflight_q +
                perf_load_squashed_xlate_inflight_count_r;
            perf_load_squashed_xlate_done_q <=
                perf_load_squashed_xlate_done_q +
                perf_load_squashed_xlate_done_count_r;
            perf_load_squashed_access_inflight_q <=
                perf_load_squashed_access_inflight_q +
                perf_load_squashed_access_inflight_count_r;
            if (flush_i)
                perf_load_flushed_q <= perf_load_flushed_q +
                    perf_load_valid_count_r;
            if (perf_load_killed_response_fire)
                perf_load_killed_responses_q <=
                    perf_load_killed_responses_q + 1'b1;
            if (!atomic_active_i && !squash_younger_i && req_ready_i &&
                (perf_load_block_count_r != 0)) begin
                perf_load_dependency_block_cycles_q <=
                    perf_load_dependency_block_cycles_q + 1'b1;
                perf_load_dependency_block_entry_cycles_q <=
                    perf_load_dependency_block_entry_cycles_q +
                    perf_load_block_count_r;
            end
            perf_load_occupancy_cycles_q <=
                perf_load_occupancy_cycles_q + perf_load_valid_count_r;
            perf_load_spec_occupancy_cycles_q <=
                perf_load_spec_occupancy_cycles_q + perf_load_spec_count_r;
            if (perf_load_valid_count_r > perf_load_max_occupancy_q)
                perf_load_max_occupancy_q <= perf_load_valid_count_r;

            if (store_alloc_fire) begin
                perf_store_allocations_q <=
                    perf_store_allocations_q + 1'b1;
                if (perf_store_alloc_order_match)
                    perf_store_ordered_allocations_q <=
                        perf_store_ordered_allocations_q + 1'b1;
                else
                    perf_store_spec_allocations_q <=
                        perf_store_spec_allocations_q + 1'b1;
                if (store_alloc_atomic_i)
                    perf_store_atomic_allocations_q <=
                        perf_store_atomic_allocations_q + 1'b1;
            end
            if (store_alloc_valid_i && !store_alloc_ready_o)
                perf_store_alloc_wait_cycles_q <=
                    perf_store_alloc_wait_cycles_q + 1'b1;
            if (store_alloc_valid_i && !store_free_found_r)
                perf_store_queue_full_cycles_q <=
                    perf_store_queue_full_cycles_q + 1'b1;
            if (xlate_req_fire && xlate_req_write_o) begin
                perf_store_xlate_requests_q <=
                    perf_store_xlate_requests_q + 1'b1;
                if (!perf_xlate_order_match)
                    perf_store_spec_xlate_requests_q <=
                        perf_store_spec_xlate_requests_q + 1'b1;
            end
            if (xlate_req_valid_o && !xlate_req_ready_i &&
                xlate_req_write_o)
                perf_store_xlate_wait_cycles_q <=
                    perf_store_xlate_wait_cycles_q + 1'b1;
            if (req_fire && req_write_o)
                perf_store_access_requests_q <=
                    perf_store_access_requests_q + 1'b1;
            if (req_valid_o && !req_ready_i && req_write_o)
                perf_store_access_wait_cycles_q <=
                    perf_store_access_wait_cycles_q + 1'b1;
            if (perf_store_result_fire)
                perf_store_posted_results_q <=
                    perf_store_posted_results_q + 1'b1;
            if (posted_store_done_fire)
                perf_store_done_q <= perf_store_done_q + 1'b1;
            perf_store_squashed_q <= perf_store_squashed_q +
                perf_store_squashed_count_r;
            perf_store_squashed_before_xlate_q <=
                perf_store_squashed_before_xlate_q +
                perf_store_squashed_before_xlate_count_r;
            perf_store_squashed_xlate_inflight_q <=
                perf_store_squashed_xlate_inflight_q +
                perf_store_squashed_xlate_inflight_count_r;
            perf_store_squashed_xlate_done_q <=
                perf_store_squashed_xlate_done_q +
                perf_store_squashed_xlate_done_count_r;
            perf_store_squashed_access_inflight_q <=
                perf_store_squashed_access_inflight_q +
                perf_store_squashed_access_inflight_count_r;
            if (flush_i)
                perf_store_flushed_q <= perf_store_flushed_q +
                    perf_store_valid_count_r;
            if (perf_store_killed_response_fire)
                perf_store_killed_responses_q <=
                    perf_store_killed_responses_q + 1'b1;
            if (perf_store_order_wait_count_r != 0)
                perf_store_order_wait_cycles_q <=
                    perf_store_order_wait_cycles_q + 1'b1;
            perf_store_order_wait_entry_cycles_q <=
                perf_store_order_wait_entry_cycles_q +
                perf_store_order_wait_count_r;
            perf_store_occupancy_cycles_q <=
                perf_store_occupancy_cycles_q + perf_store_valid_count_r;
            perf_store_spec_occupancy_cycles_q <=
                perf_store_spec_occupancy_cycles_q + perf_store_spec_count_r;
            if (perf_store_valid_count_r > perf_store_max_occupancy_q)
                perf_store_max_occupancy_q <= perf_store_valid_count_r;
            if (atomic_start_valid_o && !atomic_active_i)
                perf_atomic_starts_q <= perf_atomic_starts_q + 1'b1;
            if (atomic_done_i)
                perf_atomic_done_q <= perf_atomic_done_q + 1'b1;
            if (atomic_active_i)
                perf_atomic_active_cycles_q <=
                    perf_atomic_active_cycles_q + 1'b1;
        end
    end

    integer timeout_index;
    integer slot_timeout_age_q [0:DEPTH-1];
    initial begin
        if (LOAD_QUEUE_DEPTH < 1)
            $fatal(1, "LSQ requires a nonzero legacy store-tag base");
        if (STORE_QUEUE_DEPTH < 1)
            $fatal(1, "LSQ requires at least one store guard");
        if (DEPTH > (1 << TAG_WIDTH))
            $fatal(1, "LSQ tag namespace is too small");
        if (GUARD_HASH_WIDTH < 1)
            $fatal(1, "LSQ guard hash must contain at least one bit");
        if (TIMEOUT_CYCLES < 1)
            $fatal(1, "LSQ timeout must be positive");
    end

    always @(posedge clk) begin
        if (rst_n && posted_store_resp_fire &&
            (resp_access_fault_i || resp_page_fault_i))
            $fatal(1,
                "LSQ posted store received late fault tag=%0d", resp_tag_i);
        if (rst_n && store_done_valid_i && !store_done_is_expected)
            $fatal(1,
                "LSQ received unexpected store completion tag=%0d",
                store_done_tag_i);
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
                    if (slot_timeout_age_q[timeout_index] >= TIMEOUT_CYCLES)
                        $fatal(1,
                            "LSQ state %0d timed out id=%0d store=%b xlate=%b access=%b block=%b",
                            timeout_index, slot_id_q[timeout_index],
                            slot_store_q[timeout_index],
                            slot_xlate_sent_q[timeout_index],
                            slot_access_sent_q[timeout_index],
                            load_block_r[timeout_index]);
                end
            end
        end
    end
`endif

    wire unused = &{1'b0, translation_bypass_i, resp_paddr_i};
endmodule
