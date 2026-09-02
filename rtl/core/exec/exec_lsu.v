`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-a.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/except/except-defs.v"

// Backend-facing LSU containing the unified LSQ.
//
// The LSQ owns ordering and transaction state.  This wrapper owns address
// generation, memory/result arbitration, exception construction, and conversion
// between opaque backend packets and completion packets.  RV64A sequencing lives
// in lsu/atomics.v.
module openrv64_exec_lsu #(
    parameter integer RETIRE_SLOT_WIDTH = 3,
    parameter integer LOAD_QUEUE_DEPTH = 4,
    parameter integer STORE_QUEUE_DEPTH = 4,
    parameter integer LSU_TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH,
    parameter integer ENABLE_ZICCLSM = 1,
    parameter integer COHERENT_ATOMICS = 0,
    parameter integer ENABLE_MEMORY_DISAMBIGUATION = 0,
    parameter [`RV64_XLEN-1:0] CACHEABLE_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] CACHEABLE_SIZE = {`RV64_XLEN{1'b0}}
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_younger_i,
    input  wire                         squash_inclusive_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] squash_id_i,
    input  wire                         coherent_reservation_clear_i,
    input  wire                         translation_bypass_i,
    input  wire                         inhibit_load_speculation_i,

    input  wire                         load_issue_valid_i,
    output wire                         load_issue_ready_o,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] load_issue_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] load_issue_slot_i,
    input  wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        load_issue_payload_i,

    // Generic notification that a load has crossed the LSU allocation
    // boundary.  Extensions may use the exact identity and architectural
    // destination to confirm private-register reservations; the LSU does not
    // interpret which register file owns rd.
    output wire                         load_assignment_valid_o,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0]
                                        load_assignment_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0]
                                        load_assignment_slot_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0]
                                        load_assignment_rd_o,
    output wire [2:0]                   load_assignment_size_o,

    input  wire                         store_issue_valid_i,
    output wire                         store_issue_ready_o,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] store_issue_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] store_issue_slot_i,
    input  wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        store_issue_payload_i,

    input  wire                         ordered_head_valid_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] ordered_head_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] ordered_head_slot_i,

    output wire                         complete_valid_o,
    input  wire                         complete_ready_i,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] complete_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0] complete_slot_o,
    output wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                                        complete_payload_o,

    output wire                         mem_valid_o,
    input  wire                         mem_ready_i,
    output wire [LSU_TAG_WIDTH-1:0]     mem_tag_o,
    output wire                         mem_xlate_only_o,
    output wire                         mem_physical_o,
    output wire                         mem_pmp_checked_o,
    output wire                         mem_lock_o,
    output wire                         mem_write_o,
    output wire [`RV64_XLEN-1:0]        mem_addr_o,
    output wire [`RV64_XLEN-1:0]        mem_wdata_o,
    output wire [7:0]                   mem_wstrb_o,
    output wire                         mem_access_o,
    output wire [`RV64_XLEN-1:0]        mem_effective_addr_o,
    output wire [2:0]                   mem_size_o,

    output wire                         xlate_valid_o,
    input  wire                         xlate_ready_i,
    output wire [`OPENRV64_LSU_XLATE_TAG_WIDTH-1:0]
                                        xlate_tag_o,
    output wire                         xlate_write_o,
    output wire [2:0]                   xlate_size_o,
    output wire [`RV64_XLEN-1:0]        xlate_vaddr_o,
    input  wire                         xlate_resp_valid_i,
    output wire                         xlate_resp_ready_o,
    input  wire [`OPENRV64_LSU_XLATE_TAG_WIDTH-1:0]
                                        xlate_resp_tag_i,
    input  wire [`RV64_XLEN-1:0]        xlate_resp_paddr_i,
    input  wire                         xlate_resp_access_fault_i,
    input  wire                         xlate_resp_page_fault_i,

    input  wire                         mem_resp_valid_i,
    output wire                         mem_resp_ready_o,
    input  wire [LSU_TAG_WIDTH-1:0]     mem_resp_tag_i,
    input  wire [`RV64_XLEN-1:0]        mem_resp_paddr_i,
    input  wire [`RV64_XLEN-1:0]        mem_rdata_i,
    input  wire                         mem_error_i,
    input  wire                         mem_page_fault_i,
    input  wire                         mem_store_done_valid_i,
    output wire                         mem_store_done_ready_o,
    input  wire [LSU_TAG_WIDTH-1:0]     mem_store_done_tag_i,

    output wire                         store_pending_o,
    output wire                         load_access_valid_o,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] load_access_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0] load_access_slot_o,
    output wire [`RV64_XLEN-1:0]        load_access_pc_o,
    output wire [`RV64_XLEN-1:0]        load_access_paddr_o,
    output wire                         store_address_valid_o,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] store_address_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0] store_address_slot_o,
    output wire [`RV64_XLEN-1:0]        store_address_pc_o,
    output wire                         store_address_compressed_o,
    output wire [`RV64_XLEN-1:0]        store_address_paddr_o,
    output wire                         store_address_cacheable_o
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

    // The LSQ's resident-entry squash cannot see an allocation made on the
    // same edge as a redirect: its state loop observes the pre-edge valid
    // bits.  Sink a killed issue at this ingress boundary instead.  Ready is
    // forced high for the killed packet so the upstream output latch can be
    // discarded without waiting for LSQ or misaligned-engine capacity.
    wire load_issue_squashed = load_issue_valid_i && squash_younger_i &&
        ((squash_inclusive_i && (load_issue_id_i == squash_id_i)) ||
         id_is_younger(load_issue_id_i, squash_id_i));
    wire store_issue_squashed = store_issue_valid_i && squash_younger_i &&
        ((squash_inclusive_i && (store_issue_id_i == squash_id_i)) ||
         id_is_younger(store_issue_id_i, squash_id_i));
    wire load_issue_live = load_issue_valid_i && !load_issue_squashed;
    wire store_issue_live = store_issue_valid_i && !store_issue_squashed;

    localparam integer I_PRIV = 2;
    localparam integer I_INSTR_PAGE_FAULT = 4;
    localparam integer I_INSTR_ACCESS_FAULT = 5;
    localparam integer I_ECALL = 6;
    localparam integer I_EBREAK = 7;
    localparam integer I_ILLEGAL = 8;
    localparam integer I_MEM_WRITE = 15;
    localparam integer I_MEM_READ = 16;
    localparam integer I_REG_WRITE = 17;
    localparam integer I_LSU_OP = 22;
    localparam integer I_RD = 35;
    localparam integer I_IMM = 40;
    localparam integer I_RS2_DATA = 104;
    localparam integer I_RS1_DATA = 168;
    localparam integer I_RS2 = 232;
    localparam integer I_RS1 = 237;
    localparam integer I_INSTR = 242;
    localparam integer I_PC = 274;
    localparam integer I_TRACE = 338;

    // The retirement slot owns architectural source identity.  LSQ state
    // keeps the fields needed to route the transaction, format its result,
    // construct a precise exception, and preserve the optional trace ID while
    // a posted store outlives its ROB entry.  When tracing is disabled the
    // issue-payload trace field is constant zero and this storage optimizes
    // away.
    localparam integer LSQ_M_PRIV = 0;
    localparam integer LSQ_M_INSTR_PAGE_FAULT = 2;
    localparam integer LSQ_M_INSTR_ACCESS_FAULT = 3;
    localparam integer LSQ_M_ECALL = 4;
    localparam integer LSQ_M_EBREAK = 5;
    localparam integer LSQ_M_ILLEGAL = 6;
    localparam integer LSQ_M_MEM_WRITE = 7;
    localparam integer LSQ_M_MEM_READ = 8;
    localparam integer LSQ_M_REG_WRITE = 9;
    localparam integer LSQ_M_LSU_OP = 10;
    localparam integer LSQ_M_RD = 15;
    localparam integer LSQ_M_INSTR = 20;
    localparam integer LSQ_M_PC = 52;
    localparam integer LSQ_M_TRACE = 116;
    localparam integer LSQ_META_WIDTH = 180;

    function automatic payload_is_atomic;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        reg [`RV64_INSTR_WIDTH-1:0] instr;
        begin
            instr = payload[I_INSTR +: `RV64_INSTR_WIDTH];
            payload_is_atomic =
                (`RV64_OPCODE(instr) == `RV64_OPCODE_AMO);
        end
    endfunction

    function automatic [`RV64_XLEN-1:0] format_misaligned_load;
        input [`RV64_LSU_OP_WIDTH-1:0] op;
        input [`RV64_XLEN-1:0] data;
        begin
            case (op)
                `RV64_LSU_OP_LH:
                    format_misaligned_load = {{48{data[15]}}, data[15:0]};
                `RV64_LSU_OP_LHU:
                    format_misaligned_load = {{48{1'b0}}, data[15:0]};
                `RV64_LSU_OP_LW:
                    format_misaligned_load = {{32{data[31]}}, data[31:0]};
                `RV64_LSU_OP_LWU:
                    format_misaligned_load = {{32{1'b0}}, data[31:0]};
                default:
                    format_misaligned_load = data;
            endcase
        end
    endfunction

    wire [`RV64_INSTR_WIDTH-1:0] load_instr =
        load_issue_payload_i[I_INSTR +: `RV64_INSTR_WIDTH];
    wire [`RV64_LSU_OP_WIDTH-1:0] load_lsu_op =
        load_issue_payload_i[I_LSU_OP +: `RV64_LSU_OP_WIDTH];
    wire [`RV64_XLEN-1:0] load_rs1_data =
        load_issue_payload_i[I_RS1_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] load_rs2_data =
        load_issue_payload_i[I_RS2_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] load_imm =
        load_issue_payload_i[I_IMM +: `RV64_XLEN];
    wire load_lsu_valid;
    wire load_lsu_illegal;
    wire load_lsu_misaligned;
    wire [`RV64_XLEN-1:0] unused_load_data;
    wire load_bus_valid;
    wire load_bus_write;
    wire [`RV64_XLEN-1:0] load_bus_addr;
    wire [`RV64_XLEN-1:0] unused_load_wdata;
    wire [7:0] unused_load_wstrb;
    openrv64_exec_lsu_rv64i u_load_address (
        .op_sel_i(load_lsu_op),
        .base_i(load_rs1_data),
        .offset_i(load_imm),
        .store_data_i(load_rs2_data),
        .mem_rdata_i({`RV64_XLEN{1'b0}}),
        .valid_o(load_lsu_valid),
        .illegal_o(load_lsu_illegal),
        .misaligned_o(load_lsu_misaligned),
        .load_data_o(unused_load_data),
        .mem_valid_o(load_bus_valid),
        .mem_write_o(load_bus_write),
        .mem_addr_o(load_bus_addr),
        .mem_wdata_o(unused_load_wdata),
        .mem_wstrb_o(unused_load_wstrb)
    );

    wire [`RV64_INSTR_WIDTH-1:0] store_instr =
        store_issue_payload_i[I_INSTR +: `RV64_INSTR_WIDTH];
    wire [`RV64_LSU_OP_WIDTH-1:0] store_lsu_op =
        store_issue_payload_i[I_LSU_OP +: `RV64_LSU_OP_WIDTH];
    wire [`RV64_XLEN-1:0] store_rs1_data =
        store_issue_payload_i[I_RS1_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] store_rs2_data =
        store_issue_payload_i[I_RS2_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] store_imm =
        store_issue_payload_i[I_IMM +: `RV64_XLEN];
    wire store_is_atomic = payload_is_atomic(store_issue_payload_i);
    wire store_lsu_valid;
    wire store_lsu_illegal;
    wire store_lsu_misaligned;
    wire [`RV64_XLEN-1:0] unused_store_load_data;
    wire store_bus_valid;
    wire store_bus_write;
    wire [`RV64_XLEN-1:0] store_bus_addr;
    wire [`RV64_XLEN-1:0] store_bus_wdata;
    wire [7:0] store_bus_wstrb;
    openrv64_exec_lsu_rv64i u_store_address (
        .op_sel_i(store_lsu_op),
        .base_i(store_rs1_data),
        .offset_i(store_imm),
        .store_data_i(store_rs2_data),
        .mem_rdata_i({`RV64_XLEN{1'b0}}),
        .valid_o(store_lsu_valid),
        .illegal_o(store_lsu_illegal),
        .misaligned_o(store_lsu_misaligned),
        .load_data_o(unused_store_load_data),
        .mem_valid_o(store_bus_valid),
        .mem_write_o(store_bus_write),
        .mem_addr_o(store_bus_addr),
        .mem_wdata_o(store_bus_wdata),
        .mem_wstrb_o(store_bus_wstrb)
    );

    wire load_immediate =
        load_issue_payload_i[I_ILLEGAL] ||
        load_issue_payload_i[I_INSTR_ACCESS_FAULT] ||
        load_issue_payload_i[I_INSTR_PAGE_FAULT] ||
        !load_issue_payload_i[I_MEM_READ] ||
        load_issue_payload_i[I_MEM_WRITE] ||
        !load_lsu_valid || load_lsu_illegal || load_lsu_misaligned ||
        !load_bus_valid || load_bus_write;
    wire store_immediate =
        store_issue_payload_i[I_ILLEGAL] ||
        store_issue_payload_i[I_INSTR_ACCESS_FAULT] ||
        store_issue_payload_i[I_INSTR_PAGE_FAULT] ||
        !(store_issue_payload_i[I_MEM_WRITE] || store_is_atomic) ||
        (!store_is_atomic &&
         (!store_lsu_valid || store_lsu_illegal ||
          store_lsu_misaligned || !store_bus_valid || !store_bus_write));
    wire [`RV64_XLEN-1:0] store_effective_addr =
        store_rs1_data + store_imm;

    // Zicclsm is implemented only in this 3P LSU. Ordinary naturally
    // misaligned scalar accesses bypass the speculative LSQ and enter one
    // component-serial engine at ordered retirement. Atomics retain their
    // required alignment faults.
    wire load_requires_misaligned =
        (ENABLE_ZICCLSM != 0) &&
        !load_issue_payload_i[I_ILLEGAL] &&
        !load_issue_payload_i[I_INSTR_ACCESS_FAULT] &&
        !load_issue_payload_i[I_INSTR_PAGE_FAULT] &&
        load_issue_payload_i[I_MEM_READ] &&
        !load_issue_payload_i[I_MEM_WRITE] &&
        load_lsu_valid && !load_lsu_illegal && load_lsu_misaligned;
    wire store_requires_misaligned =
        (ENABLE_ZICCLSM != 0) &&
        !store_is_atomic &&
        !store_issue_payload_i[I_ILLEGAL] &&
        !store_issue_payload_i[I_INSTR_ACCESS_FAULT] &&
        !store_issue_payload_i[I_INSTR_PAGE_FAULT] &&
        store_issue_payload_i[I_MEM_WRITE] &&
        store_lsu_valid && !store_lsu_illegal && store_lsu_misaligned;
    wire load_order_match = ordered_head_valid_i &&
        (ordered_head_id_i == load_issue_id_i) &&
        (ordered_head_slot_i == load_issue_slot_i);
    wire store_order_match = ordered_head_valid_i &&
        (ordered_head_id_i == store_issue_id_i) &&
        (ordered_head_slot_i == store_issue_slot_i);
    wire lsq_req_valid;
    wire lsq_req_ready;
    wire [LSU_TAG_WIDTH-1:0] lsq_req_tag;
    wire lsq_req_write;
    wire lsq_req_pmp_checked;
    wire [`RV64_XLEN-1:0] lsq_req_addr;
    wire [`RV64_XLEN-1:0] lsq_req_vaddr;
    wire [2:0] lsq_req_size;
    wire [`RV64_XLEN-1:0] lsq_req_wdata;
    wire [7:0] lsq_req_wstrb;
    wire lsq_resp_valid;
    wire lsq_resp_ready;
    wire lsq_result_valid;
    wire lsq_result_ready;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] lsq_result_id;
    wire [RETIRE_SLOT_WIDTH-1:0] lsq_result_slot;
    wire [LSQ_META_WIDTH-1:0] lsq_result_meta;
    wire [`RV64_XLEN-1:0] lsq_result_vaddr;
    wire [`RV64_XLEN-1:0] lsq_result_rdata;
    wire lsq_result_access_fault;
    wire lsq_result_page_fault;
    wire lsq_result_store;
    wire lsq_result_posted_store;
    wire lsq_load_alloc_ready;
    wire lsq_store_alloc_ready;
    wire lsq_store_pending;
    wire lsq_quiescent;
    wire lsq_load_access_valid;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] lsq_load_access_id;
    wire [RETIRE_SLOT_WIDTH-1:0] lsq_load_access_slot;
    wire [LSQ_META_WIDTH-1:0] lsq_load_access_meta;
    wire [`RV64_XLEN-1:0] lsq_load_access_paddr;
    wire lsq_store_address_valid;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] lsq_store_address_id;
    wire [RETIRE_SLOT_WIDTH-1:0] lsq_store_address_slot;
    wire [LSQ_META_WIDTH-1:0] lsq_store_address_meta;
    wire [`RV64_XLEN-1:0] lsq_store_address_paddr;
    wire lsq_store_address_cacheable;

    wire atomic_start_valid;
    wire [LSU_TAG_WIDTH-1:0] atomic_start_tag;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] atomic_start_id;
    wire [RETIRE_SLOT_WIDTH-1:0] atomic_start_slot;
    wire [LSQ_META_WIDTH-1:0] atomic_start_meta;
    wire [`RV64_XLEN-1:0] atomic_start_vaddr;
    wire [2:0] atomic_start_size;
    wire [`RV64_XLEN-1:0] atomic_start_wdata;
    wire atomic_start_access_allowed;
    wire atomic_start_ready;
    wire atomic_active;
    wire atomic_irrevocable;
    wire [LSU_TAG_WIDTH-1:0] atomic_tag;
    wire atomic_done;

    wire atomic_mem_valid;
    wire [LSU_TAG_WIDTH-1:0] atomic_mem_tag;
    wire atomic_mem_lock;
    wire atomic_mem_write;
    wire [`RV64_XLEN-1:0] atomic_mem_addr;
    wire [`RV64_XLEN-1:0] atomic_mem_wdata;
    wire [7:0] atomic_mem_wstrb;
    wire [`RV64_XLEN-1:0] atomic_effective_addr;
    wire [2:0] atomic_access_size;
    wire atomic_resp_claim;
    wire atomic_resp_ready;

    wire atomic_result_valid;
    wire atomic_result_ready;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] atomic_result_id;
    wire [RETIRE_SLOT_WIDTH-1:0] atomic_result_slot;
    wire [LSQ_META_WIDTH-1:0] atomic_result_meta;
    wire [`RV64_XLEN-1:0] atomic_result;
    wire atomic_illegal;
    wire atomic_misaligned;
    wire atomic_access_fault;
    wire atomic_page_fault;

    wire misaligned_active;
    wire misaligned_start_ready;
    wire misaligned_result_valid;
    wire misaligned_result_ready;
    wire [`RV64_XLEN-1:0] misaligned_result_rdata;
    wire misaligned_result_access_fault;
    wire misaligned_result_page_fault;
    wire [`RV64_XLEN-1:0] misaligned_result_fault_addr;
    wire misaligned_xlate_valid;
    wire misaligned_xlate_ready;
    wire [LSU_TAG_WIDTH-1:0] misaligned_xlate_tag;
    wire misaligned_xlate_write;
    wire [2:0] misaligned_xlate_size;
    wire [`RV64_XLEN-1:0] misaligned_xlate_vaddr;
    wire misaligned_xlate_resp_ready;
    wire misaligned_mem_valid;
    wire misaligned_mem_ready;
    wire [LSU_TAG_WIDTH-1:0] misaligned_mem_tag;
    wire misaligned_mem_write;
    wire [`RV64_XLEN-1:0] misaligned_mem_addr;
    wire [`RV64_XLEN-1:0] misaligned_mem_wdata;
    wire [7:0] misaligned_mem_wstrb;
    wire [`RV64_XLEN-1:0] misaligned_mem_effective_addr;
    wire [2:0] misaligned_mem_size;
    wire misaligned_mem_resp_ready;
    wire misaligned_store_done_ready;

    wire lsq_xlate_valid;
    wire lsq_xlate_ready;
    wire [LSU_TAG_WIDTH-1:0] lsq_xlate_tag;
    wire lsq_xlate_write;
    wire [2:0] lsq_xlate_size;
    wire [`RV64_XLEN-1:0] lsq_xlate_vaddr;
    wire lsq_xlate_resp_ready;
    wire lsq_store_done_ready;
    wire [LSU_TAG_WIDTH-1:0] xlate_resp_slot =
        xlate_resp_tag_i[LSU_TAG_WIDTH-1:0];
    wire [`OPENRV64_LSU_XLATE_GENERATION_WIDTH-1:0]
        xlate_resp_generation =
            xlate_resp_tag_i[`OPENRV64_LSU_XLATE_TAG_WIDTH-1 -:
                             `OPENRV64_LSU_XLATE_GENERATION_WIDTH];
    wire xlate_resp_generation_match;
    wire xlate_resp_filtered_valid =
        xlate_resp_valid_i && xlate_resp_generation_match;

    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] misaligned_id_q;
    wire [RETIRE_SLOT_WIDTH-1:0] misaligned_slot_q;
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] misaligned_meta_q;
    wire misaligned_pending_q;
    wire misaligned_store_q;
    wire misaligned_translation_bypass_q;
    wire [`RV64_XLEN-1:0] misaligned_addr_q;
    wire [2:0] misaligned_size_q;
    wire [`RV64_XLEN-1:0] misaligned_wdata_q;

    wire misaligned_load_accept = load_issue_live &&
                                  load_issue_ready_o &&
                                  load_requires_misaligned;
    wire misaligned_store_accept = store_issue_live &&
                                   store_issue_ready_o &&
                                   store_requires_misaligned;
    wire misaligned_accept =
        misaligned_load_accept || misaligned_store_accept;
    wire misaligned_load_candidate =
        load_requires_misaligned && load_order_match;
    wire misaligned_store_candidate =
        store_requires_misaligned && store_order_match;
    wire misaligned_can_start = misaligned_pending_q && lsq_quiescent &&
                                !atomic_active && !misaligned_active;
    wire misaligned_start_valid = misaligned_can_start;
    wire misaligned_start_fire =
        misaligned_start_valid && misaligned_start_ready;

    // A single registered pending slot breaks the dispatch ready/valid path.
    // Do not admit an operation on the other LSQ port in the same cycle as an
    // ordered misaligned candidate.  Once pending is registered, existing
    // entries remain allocated but new LSQ launches are frozen until accepted
    // transactions drain and the component engine takes port ownership.
    assign load_issue_ready_o = load_issue_squashed ? 1'b1 :
        (misaligned_active || misaligned_pending_q) ? 1'b0 :
        misaligned_store_candidate ? 1'b0 :
        load_requires_misaligned ?
        load_order_match : lsq_load_alloc_ready;
    assign store_issue_ready_o = store_issue_squashed ? 1'b1 :
        (misaligned_active || misaligned_pending_q) ? 1'b0 :
        misaligned_load_candidate ? 1'b0 :
        store_requires_misaligned ?
        store_order_match : lsq_store_alloc_ready;

    assign load_assignment_valid_o =
        load_issue_live && load_issue_ready_o;
    assign load_assignment_id_o = load_issue_id_i;
    assign load_assignment_slot_o = load_issue_slot_i;
    assign load_assignment_rd_o =
        load_issue_payload_i[I_RD +: `RV64_REG_ADDR_WIDTH];
    assign load_assignment_size_o = {1'b0, load_instr[13:12]};

    wire [LSQ_META_WIDTH-1:0] load_lsq_meta = {
        load_issue_payload_i[I_TRACE +: 64],
        load_issue_payload_i[I_PC +: `RV64_XLEN],
        load_issue_payload_i[I_INSTR +: `RV64_INSTR_WIDTH],
        load_issue_payload_i[I_RD +: `RV64_REG_ADDR_WIDTH],
        load_issue_payload_i[I_LSU_OP +: `RV64_LSU_OP_WIDTH],
        load_issue_payload_i[I_REG_WRITE],
        load_issue_payload_i[I_MEM_READ],
        load_issue_payload_i[I_MEM_WRITE],
        load_issue_payload_i[I_ILLEGAL],
        load_issue_payload_i[I_EBREAK],
        load_issue_payload_i[I_ECALL],
        load_issue_payload_i[I_INSTR_ACCESS_FAULT],
        load_issue_payload_i[I_INSTR_PAGE_FAULT],
        load_issue_payload_i[I_PRIV +: `RV64_PRIV_WIDTH]
    };
    wire [LSQ_META_WIDTH-1:0] store_lsq_meta = {
        store_issue_payload_i[I_TRACE +: 64],
        store_issue_payload_i[I_PC +: `RV64_XLEN],
        store_issue_payload_i[I_INSTR +: `RV64_INSTR_WIDTH],
        store_issue_payload_i[I_RD +: `RV64_REG_ADDR_WIDTH],
        store_issue_payload_i[I_LSU_OP +: `RV64_LSU_OP_WIDTH],
        store_issue_payload_i[I_REG_WRITE],
        store_issue_payload_i[I_MEM_READ],
        store_issue_payload_i[I_MEM_WRITE],
        store_issue_payload_i[I_ILLEGAL],
        store_issue_payload_i[I_EBREAK],
        store_issue_payload_i[I_ECALL],
        store_issue_payload_i[I_INSTR_ACCESS_FAULT],
        store_issue_payload_i[I_INSTR_PAGE_FAULT],
        store_issue_payload_i[I_PRIV +: `RV64_PRIV_WIDTH]
    };

    openrv64_lsq #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .META_WIDTH(LSQ_META_WIDTH),
        .LOAD_QUEUE_DEPTH(LOAD_QUEUE_DEPTH),
        .STORE_QUEUE_DEPTH(STORE_QUEUE_DEPTH),
        .TAG_WIDTH(LSU_TAG_WIDTH),
        .ALLOW_UNRESOLVED_STORE_SPECULATION(
            ENABLE_MEMORY_DISAMBIGUATION),
        .CACHEABLE_BASE(CACHEABLE_BASE),
        .CACHEABLE_SIZE(CACHEABLE_SIZE)
    ) u_lsq (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i),
        .squash_younger_i(squash_younger_i),
        .squash_inclusive_i(squash_inclusive_i),
        .squash_id_i(squash_id_i),
        .translation_bypass_i(translation_bypass_i),
        .inhibit_load_speculation_i(inhibit_load_speculation_i),
        .load_alloc_valid_i(load_issue_live &&
                            !load_requires_misaligned &&
                            !misaligned_store_candidate &&
                            !misaligned_active &&
                            !misaligned_pending_q),
        .load_alloc_ready_o(lsq_load_alloc_ready),
        .load_alloc_id_i(load_issue_id_i),
        .load_alloc_slot_i(load_issue_slot_i),
        .load_alloc_meta_i(load_lsq_meta),
        .load_alloc_immediate_i(load_immediate),
        // Translation and PMP status belongs to the tagged response.  There
        // is no valid access verdict at LSQ allocation time.
        .load_alloc_access_fault_i(1'b0),
        .load_alloc_vaddr_i(load_bus_addr),
        .load_alloc_size_i({1'b0, load_instr[13:12]}),
        .store_alloc_valid_i(store_issue_live &&
                             !store_requires_misaligned &&
                             !misaligned_load_candidate &&
                             !misaligned_active &&
                             !misaligned_pending_q),
        .store_alloc_ready_o(lsq_store_alloc_ready),
        .store_alloc_id_i(store_issue_id_i),
        .store_alloc_slot_i(store_issue_slot_i),
        .store_alloc_meta_i(store_lsq_meta),
        .store_alloc_immediate_i(store_immediate),
        .store_alloc_access_fault_i(1'b0),
        .store_alloc_atomic_i(store_is_atomic),
        .store_alloc_vaddr_i(store_is_atomic ?
                             store_effective_addr : store_bus_addr),
        .store_alloc_size_i({1'b0, store_instr[13:12]}),
        .store_alloc_wdata_i(store_is_atomic ?
                             store_rs2_data : store_bus_wdata),
        .store_alloc_wstrb_i(store_bus_wstrb),
        .ordered_head_valid_i(ordered_head_valid_i),
        .ordered_head_id_i(ordered_head_id_i),
        .ordered_head_slot_i(ordered_head_slot_i),
        .atomic_start_valid_o(atomic_start_valid),
        .atomic_start_tag_o(atomic_start_tag),
        .atomic_start_id_o(atomic_start_id),
        .atomic_start_slot_o(atomic_start_slot),
        .atomic_start_meta_o(atomic_start_meta),
        .atomic_start_vaddr_o(atomic_start_vaddr),
        .atomic_start_size_o(atomic_start_size),
        .atomic_start_wdata_o(atomic_start_wdata),
        .atomic_start_access_allowed_o(atomic_start_access_allowed),
        .atomic_active_i(atomic_active),
        .atomic_tag_i(atomic_tag),
        .atomic_irrevocable_i(atomic_irrevocable),
        .atomic_done_i(atomic_done),
        .xlate_req_valid_o(lsq_xlate_valid),
        .xlate_req_ready_i(lsq_xlate_ready),
        .xlate_req_tag_o(lsq_xlate_tag),
        .xlate_req_write_o(lsq_xlate_write),
        .xlate_req_size_o(lsq_xlate_size),
        .xlate_req_vaddr_o(lsq_xlate_vaddr),
        .xlate_resp_valid_i(xlate_resp_filtered_valid &&
                            !misaligned_active),
        .xlate_resp_ready_o(lsq_xlate_resp_ready),
        .xlate_resp_tag_i(xlate_resp_slot),
        .xlate_resp_paddr_i(xlate_resp_paddr_i),
        .xlate_resp_access_fault_i(xlate_resp_access_fault_i),
        .xlate_resp_page_fault_i(xlate_resp_page_fault_i),
        .req_valid_o(lsq_req_valid),
        .req_ready_i(lsq_req_ready),
        .req_tag_o(lsq_req_tag),
        .req_write_o(lsq_req_write),
        .req_pmp_checked_o(lsq_req_pmp_checked),
        .req_addr_o(lsq_req_addr),
        .req_vaddr_o(lsq_req_vaddr),
        .req_size_o(lsq_req_size),
        .req_wdata_o(lsq_req_wdata),
        .req_wstrb_o(lsq_req_wstrb),
        .load_access_valid_o(lsq_load_access_valid),
        .load_access_id_o(lsq_load_access_id),
        .load_access_slot_o(lsq_load_access_slot),
        .load_access_meta_o(lsq_load_access_meta),
        .load_access_paddr_o(lsq_load_access_paddr),
        .store_address_valid_o(lsq_store_address_valid),
        .store_address_id_o(lsq_store_address_id),
        .store_address_slot_o(lsq_store_address_slot),
        .store_address_meta_o(lsq_store_address_meta),
        .store_address_paddr_o(lsq_store_address_paddr),
        .store_address_cacheable_o(lsq_store_address_cacheable),
        .resp_valid_i(lsq_resp_valid),
        .resp_ready_o(lsq_resp_ready),
        .resp_tag_i(mem_resp_tag_i),
        .resp_paddr_i(mem_resp_paddr_i),
        .resp_rdata_i(mem_rdata_i),
        .resp_access_fault_i(mem_error_i),
        .resp_page_fault_i(mem_page_fault_i),
        .store_done_valid_i(mem_store_done_valid_i && !misaligned_active),
        .store_done_ready_o(lsq_store_done_ready),
        .store_done_tag_i(mem_store_done_tag_i),
        .result_valid_o(lsq_result_valid),
        .result_ready_i(lsq_result_ready),
        .result_id_o(lsq_result_id),
        .result_slot_o(lsq_result_slot),
        .result_meta_o(lsq_result_meta),
        .result_vaddr_o(lsq_result_vaddr),
        .result_rdata_o(lsq_result_rdata),
        .result_access_fault_o(lsq_result_access_fault),
        .result_page_fault_o(lsq_result_page_fault),
        .result_store_o(lsq_result_store),
        .result_posted_store_o(lsq_result_posted_store),
        .store_pending_o(lsq_store_pending),
        .quiescent_o(lsq_quiescent),
        .empty_o()
    );

    assign load_access_valid_o = (ENABLE_MEMORY_DISAMBIGUATION != 0) &&
                                 lsq_load_access_valid;
    assign load_access_id_o = lsq_load_access_id;
    assign load_access_slot_o = lsq_load_access_slot;
    assign load_access_pc_o =
        lsq_load_access_meta[LSQ_M_PC +: `RV64_XLEN];
    assign load_access_paddr_o = lsq_load_access_paddr;
    generate
        if (ENABLE_ZICCLSM != 0) begin : g_zicclsm
            reg [`OPENRV64_INSTR_ID_WIDTH-1:0] id_q;
            reg [RETIRE_SLOT_WIDTH-1:0] slot_q;
            reg [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] meta_q;
            reg pending_q;
            reg store_q;
            reg translation_bypass_q;
            reg [`RV64_XLEN-1:0] addr_q;
            reg [2:0] size_q;
            reg [`RV64_XLEN-1:0] wdata_q;

            assign misaligned_id_q = id_q;
            assign misaligned_slot_q = slot_q;
            assign misaligned_meta_q = meta_q;
            assign misaligned_pending_q = pending_q;
            assign misaligned_store_q = store_q;
            assign misaligned_translation_bypass_q =
                translation_bypass_q;
            assign misaligned_addr_q = addr_q;
            assign misaligned_size_q = size_q;
            assign misaligned_wdata_q = wdata_q;

            openrv64_lsu_misaligned #(
                .TAG_WIDTH(LSU_TAG_WIDTH),
                .CACHEABLE_BASE(CACHEABLE_BASE),
                .CACHEABLE_SIZE(CACHEABLE_SIZE)
            ) u_misaligned (
                .clk(clk),
                .rst_n(rst_n),
                .flush_i(flush_i),
                .start_valid_i(misaligned_start_valid),
                .start_ready_o(misaligned_start_ready),
                .start_write_i(misaligned_store_q),
                .start_addr_i(misaligned_addr_q),
                .start_size_i(misaligned_size_q),
                .start_wdata_i(misaligned_wdata_q),
                .translation_bypass_i(misaligned_translation_bypass_q),
                .active_o(misaligned_active),
                .result_valid_o(misaligned_result_valid),
                .result_ready_i(misaligned_result_ready),
                .result_rdata_o(misaligned_result_rdata),
                .result_access_fault_o(misaligned_result_access_fault),
                .result_page_fault_o(misaligned_result_page_fault),
                .result_fault_addr_o(misaligned_result_fault_addr),
                .xlate_valid_o(misaligned_xlate_valid),
                .xlate_ready_i(misaligned_xlate_ready),
                .xlate_tag_o(misaligned_xlate_tag),
                .xlate_write_o(misaligned_xlate_write),
                .xlate_size_o(misaligned_xlate_size),
                .xlate_vaddr_o(misaligned_xlate_vaddr),
                .xlate_resp_valid_i(xlate_resp_filtered_valid &&
                                    misaligned_active),
                .xlate_resp_ready_o(misaligned_xlate_resp_ready),
                .xlate_resp_tag_i(xlate_resp_slot),
                .xlate_resp_paddr_i(xlate_resp_paddr_i),
                .xlate_resp_access_fault_i(xlate_resp_access_fault_i),
                .xlate_resp_page_fault_i(xlate_resp_page_fault_i),
                .mem_valid_o(misaligned_mem_valid),
                .mem_ready_i(misaligned_mem_ready),
                .mem_tag_o(misaligned_mem_tag),
                .mem_write_o(misaligned_mem_write),
                .mem_addr_o(misaligned_mem_addr),
                .mem_wdata_o(misaligned_mem_wdata),
                .mem_wstrb_o(misaligned_mem_wstrb),
                .mem_effective_addr_o(misaligned_mem_effective_addr),
                .mem_size_o(misaligned_mem_size),
                .mem_resp_valid_i(mem_resp_valid_i &&
                                  misaligned_active),
                .mem_resp_ready_o(misaligned_mem_resp_ready),
                .mem_resp_tag_i(mem_resp_tag_i),
                .mem_rdata_i(mem_rdata_i),
                .mem_error_i(mem_error_i),
                .mem_page_fault_i(mem_page_fault_i),
                .mem_store_done_valid_i(mem_store_done_valid_i &&
                                        misaligned_active),
                .mem_store_done_ready_o(misaligned_store_done_ready),
                .mem_store_done_tag_i(mem_store_done_tag_i)
            );

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    id_q <=
                        {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
                    slot_q <= {RETIRE_SLOT_WIDTH{1'b0}};
                    meta_q <=
                        {`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
                    pending_q <= 1'b0;
                    store_q <= 1'b0;
                    translation_bypass_q <= 1'b0;
                    addr_q <= {`RV64_XLEN{1'b0}};
                    size_q <= 3'd0;
                    wdata_q <= {`RV64_XLEN{1'b0}};
                end else begin
                    if (misaligned_accept) begin
                        pending_q <= 1'b1;
                        id_q <= misaligned_store_accept ?
                            store_issue_id_i : load_issue_id_i;
                        slot_q <= misaligned_store_accept ?
                            store_issue_slot_i : load_issue_slot_i;
                        meta_q <= misaligned_store_accept ?
                            store_issue_payload_i :
                            load_issue_payload_i;
                        store_q <= misaligned_store_accept;
                        translation_bypass_q <=
                            translation_bypass_i;
                        addr_q <= misaligned_store_accept ?
                            store_effective_addr :
                            (load_rs1_data + load_imm);
                        size_q <= misaligned_store_accept ?
                            {1'b0, store_instr[13:12]} :
                            {1'b0, load_instr[13:12]};
                        wdata_q <= store_rs2_data;
                    end
                    if (misaligned_start_fire)
                        pending_q <= 1'b0;
                end
            end
        end else begin : g_no_zicclsm
            assign misaligned_start_ready = 1'b0;
            assign misaligned_active = 1'b0;
            assign misaligned_result_valid = 1'b0;
            assign misaligned_result_rdata = {`RV64_XLEN{1'b0}};
            assign misaligned_result_access_fault = 1'b0;
            assign misaligned_result_page_fault = 1'b0;
            assign misaligned_result_fault_addr = {`RV64_XLEN{1'b0}};
            assign misaligned_xlate_valid = 1'b0;
            assign misaligned_xlate_tag = {LSU_TAG_WIDTH{1'b0}};
            assign misaligned_xlate_write = 1'b0;
            assign misaligned_xlate_size = 3'd0;
            assign misaligned_xlate_vaddr = {`RV64_XLEN{1'b0}};
            assign misaligned_xlate_resp_ready = 1'b0;
            assign misaligned_mem_valid = 1'b0;
            assign misaligned_mem_tag = {LSU_TAG_WIDTH{1'b0}};
            assign misaligned_mem_write = 1'b0;
            assign misaligned_mem_addr = {`RV64_XLEN{1'b0}};
            assign misaligned_mem_wdata = {`RV64_XLEN{1'b0}};
            assign misaligned_mem_wstrb = 8'h00;
            assign misaligned_mem_effective_addr =
                {`RV64_XLEN{1'b0}};
            assign misaligned_mem_size = 3'd0;
            assign misaligned_mem_resp_ready = 1'b0;
            assign misaligned_store_done_ready = 1'b0;

            assign misaligned_id_q =
                {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            assign misaligned_slot_q = {RETIRE_SLOT_WIDTH{1'b0}};
            assign misaligned_meta_q =
                {`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
            assign misaligned_pending_q = 1'b0;
            assign misaligned_store_q = 1'b0;
            assign misaligned_translation_bypass_q = 1'b0;
            assign misaligned_addr_q = {`RV64_XLEN{1'b0}};
            assign misaligned_size_q = 3'd0;
            assign misaligned_wdata_q = {`RV64_XLEN{1'b0}};
        end
    endgenerate

    // An address-unknown ordinary store may be crossed by younger cacheable
    // loads in Tomasulo mode.  Naturally aligned stores report their physical
    // address through the LSQ.  A Zicclsm store reports every translated
    // component instead; comparing at 8-byte granularity covers every byte it
    // may modify.  Translation-bypass components have no response phase, so
    // report their accepted memory address phase.
    wire misaligned_store_xlate_address_valid =
        misaligned_active && misaligned_store_q &&
        !misaligned_translation_bypass_q &&
        xlate_resp_filtered_valid && misaligned_xlate_resp_ready &&
        !xlate_resp_access_fault_i && !xlate_resp_page_fault_i;
    wire misaligned_store_bypass_address_valid =
        misaligned_active && misaligned_store_q &&
        misaligned_translation_bypass_q &&
        misaligned_mem_valid && misaligned_mem_ready &&
        misaligned_mem_write;
    wire misaligned_store_address_valid =
        misaligned_store_xlate_address_valid ||
        misaligned_store_bypass_address_valid;
    wire [`RV64_XLEN-1:0] misaligned_store_address_paddr =
        misaligned_store_xlate_address_valid ? xlate_resp_paddr_i :
                                               misaligned_mem_addr;
    wire [`RV64_XLEN-1:0] misaligned_store_address_offset =
        misaligned_store_address_paddr - CACHEABLE_BASE;
    wire misaligned_store_address_cacheable =
        (CACHEABLE_SIZE != {`RV64_XLEN{1'b0}}) &&
        (misaligned_store_address_offset < CACHEABLE_SIZE);

    assign store_address_valid_o = (ENABLE_MEMORY_DISAMBIGUATION != 0) &&
        (lsq_store_address_valid || misaligned_store_address_valid);
    assign store_address_id_o = misaligned_store_address_valid ?
        misaligned_id_q : lsq_store_address_id;
    assign store_address_slot_o = misaligned_store_address_valid ?
        misaligned_slot_q : lsq_store_address_slot;
    assign store_address_pc_o = misaligned_store_address_valid ?
        misaligned_meta_q[I_PC +: `RV64_XLEN] :
        lsq_store_address_meta[LSQ_M_PC +: `RV64_XLEN];
    assign store_address_compressed_o = misaligned_store_address_valid ?
        (misaligned_meta_q[I_INSTR +: 2] != 2'b11) :
        (lsq_store_address_meta[LSQ_M_INSTR +: 2] != 2'b11);
    assign store_address_paddr_o = misaligned_store_address_valid ?
        misaligned_store_address_paddr : lsq_store_address_paddr;
    assign store_address_cacheable_o =
        (ENABLE_MEMORY_DISAMBIGUATION != 0) &&
        (misaligned_store_address_valid ?
         misaligned_store_address_cacheable : lsq_store_address_cacheable);

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && misaligned_load_accept &&
            misaligned_store_accept)
            $fatal(1,
                "3P LSU accepted two ordered misaligned operations");
    end
`endif

    wire lsq_launch_enable =
        !misaligned_pending_q && !misaligned_active;
    wire [LSU_TAG_WIDTH-1:0] xlate_request_slot =
        misaligned_active ? misaligned_xlate_tag : lsq_xlate_tag;
    reg [`OPENRV64_LSU_XLATE_GENERATION_WIDTH-1:0]
        xlate_generation_q [0:(1 << LSU_TAG_WIDTH)-1];
    reg [`OPENRV64_LSU_XLATE_GENERATION_WIDTH-1:0]
        xlate_expected_generation_q [0:(1 << LSU_TAG_WIDTH)-1];
    wire [`OPENRV64_LSU_XLATE_GENERATION_WIDTH-1:0]
        xlate_request_generation = xlate_generation_q[xlate_request_slot];
    assign xlate_valid_o = misaligned_active ?
                           misaligned_xlate_valid :
                           (lsq_launch_enable && lsq_xlate_valid);
    assign xlate_tag_o = {xlate_request_generation, xlate_request_slot};
    assign xlate_write_o = misaligned_active ?
                           misaligned_xlate_write : lsq_xlate_write;
    assign xlate_size_o = misaligned_active ?
                          misaligned_xlate_size : lsq_xlate_size;
    assign xlate_vaddr_o = misaligned_active ?
                           misaligned_xlate_vaddr : lsq_xlate_vaddr;
    assign misaligned_xlate_ready = misaligned_active && xlate_ready_i;
    assign lsq_xlate_ready = lsq_launch_enable && xlate_ready_i;
    wire xlate_request_fire = xlate_valid_o && xlate_ready_i;
    // Prefer the generation on a currently presented same-slot request.  This
    // handles a zero-cycle screen response and prevents an older response from
    // matching a newly reused slot while that request is backpressured.
    wire xlate_response_matches_presented_request = xlate_valid_o &&
        (xlate_resp_slot == xlate_request_slot);
    wire [`OPENRV64_LSU_XLATE_GENERATION_WIDTH-1:0]
        xlate_response_expected_generation =
            xlate_response_matches_presented_request ?
                xlate_request_generation :
                xlate_expected_generation_q[xlate_resp_slot];
    assign xlate_resp_generation_match =
        xlate_resp_generation == xlate_response_expected_generation;
    wire selected_xlate_resp_ready = misaligned_active ?
        misaligned_xlate_resp_ready : lsq_xlate_resp_ready;
    // Generation-mismatched responses are stale and are consumed locally.
    assign xlate_resp_ready_o =
        (xlate_resp_valid_i && !xlate_resp_generation_match) ?
            1'b1 : selected_xlate_resp_ready;

    integer xlate_generation_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (xlate_generation_index = 0;
                 xlate_generation_index < (1 << LSU_TAG_WIDTH);
                 xlate_generation_index = xlate_generation_index + 1) begin
                xlate_generation_q[xlate_generation_index] <=
                    {`OPENRV64_LSU_XLATE_GENERATION_WIDTH{1'b0}};
                xlate_expected_generation_q[xlate_generation_index] <=
                    {`OPENRV64_LSU_XLATE_GENERATION_WIDTH{1'b0}};
            end
        end else if (xlate_request_fire) begin
            xlate_expected_generation_q[xlate_request_slot] <=
                xlate_request_generation;
            xlate_generation_q[xlate_request_slot] <=
                xlate_request_generation + 1'b1;
        end
    end

    assign store_pending_o = lsq_store_pending ||
        ((misaligned_pending_q || misaligned_active) &&
         misaligned_store_q);

    wire clear_atomic_reservation =
        (lsq_result_valid && lsq_result_ready && lsq_result_store) ||
        ((COHERENT_ATOMICS != 0) &&
         coherent_reservation_clear_i);

    openrv64_lsu_atomics #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .LSU_TAG_WIDTH(LSU_TAG_WIDTH),
        .META_WIDTH(LSQ_META_WIDTH),
        .COHERENT_ATOMICS(COHERENT_ATOMICS)
    ) u_atomics (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i),
        .start_valid_i(atomic_start_valid),
        .start_ready_o(atomic_start_ready),
        .start_tag_i(atomic_start_tag),
        .start_id_i(atomic_start_id),
        .start_slot_i(atomic_start_slot),
        .start_meta_i(atomic_start_meta),
        .start_op_i(atomic_start_meta[
            LSQ_M_LSU_OP +: `RV64_LSU_OP_WIDTH]),
        .start_addr_i(atomic_start_vaddr),
        .start_size_i(atomic_start_size),
        .start_wdata_i(atomic_start_wdata),
        .start_access_allowed_i(atomic_start_access_allowed),
        .clear_reservation_i(clear_atomic_reservation),
        .active_o(atomic_active),
        .irrevocable_o(atomic_irrevocable),
        .active_tag_o(atomic_tag),
        .mem_valid_o(atomic_mem_valid),
        .mem_ready_i(mem_ready_i),
        .mem_tag_o(atomic_mem_tag),
        .mem_lock_o(atomic_mem_lock),
        .mem_write_o(atomic_mem_write),
        .mem_addr_o(atomic_mem_addr),
        .mem_wdata_o(atomic_mem_wdata),
        .mem_wstrb_o(atomic_mem_wstrb),
        .mem_effective_addr_o(atomic_effective_addr),
        .mem_size_o(atomic_access_size),
        .mem_resp_valid_i(mem_resp_valid_i && !misaligned_active),
        .mem_resp_claim_o(atomic_resp_claim),
        .mem_resp_ready_o(atomic_resp_ready),
        .mem_resp_tag_i(mem_resp_tag_i),
        .mem_rdata_i(mem_rdata_i),
        .mem_error_i(mem_error_i),
        .mem_page_fault_i(mem_page_fault_i),
        .result_valid_o(atomic_result_valid),
        .result_ready_i(atomic_result_ready),
        .result_id_o(atomic_result_id),
        .result_slot_o(atomic_result_slot),
        .result_meta_o(atomic_result_meta),
        .result_data_o(atomic_result),
        .result_illegal_o(atomic_illegal),
        .result_misaligned_o(atomic_misaligned),
        .result_access_fault_o(atomic_access_fault),
        .result_page_fault_o(atomic_page_fault),
        .done_o(atomic_done)
    );

    assign lsq_resp_valid = mem_resp_valid_i &&
                            !misaligned_active &&
                            !atomic_resp_claim;
    assign mem_resp_ready_o = misaligned_active ?
        misaligned_mem_resp_ready :
        atomic_resp_claim ? atomic_resp_ready : lsq_resp_ready;
    assign mem_store_done_ready_o = misaligned_active ?
        misaligned_store_done_ready : lsq_store_done_ready;

    assign mem_valid_o = misaligned_active ? misaligned_mem_valid :
                         atomic_active ? atomic_mem_valid :
                         (lsq_launch_enable && lsq_req_valid);
    assign mem_tag_o = misaligned_active ? misaligned_mem_tag :
                       atomic_active ? atomic_mem_tag : lsq_req_tag;
    assign mem_xlate_only_o = 1'b0;
    assign mem_physical_o = misaligned_active || !atomic_active;
    assign mem_pmp_checked_o = misaligned_active ?
        !misaligned_translation_bypass_q :
        atomic_active ? 1'b0 : lsq_req_pmp_checked;
    assign mem_lock_o = misaligned_active ? 1'b0 :
                        atomic_active ? atomic_mem_lock : 1'b0;
    assign mem_write_o = misaligned_active ? misaligned_mem_write :
                         atomic_active ? atomic_mem_write : lsq_req_write;
    assign mem_addr_o = misaligned_active ? misaligned_mem_addr :
                        atomic_active ? atomic_mem_addr : lsq_req_addr;
    assign mem_wdata_o = misaligned_active ? misaligned_mem_wdata :
                         atomic_active ? atomic_mem_wdata : lsq_req_wdata;
    assign mem_wstrb_o = misaligned_active ? misaligned_mem_wstrb :
                         atomic_active ? atomic_mem_wstrb : lsq_req_wstrb;
    assign mem_access_o = mem_valid_o;
    assign mem_effective_addr_o = misaligned_active ?
        misaligned_mem_effective_addr :
        atomic_active ? atomic_effective_addr : lsq_req_vaddr;
    assign mem_size_o = misaligned_active ? misaligned_mem_size :
                        atomic_active ? atomic_access_size : lsq_req_size;
    assign misaligned_mem_ready = misaligned_active && mem_ready_i;
    assign lsq_req_ready = lsq_launch_enable &&
                           !atomic_active && mem_ready_i;

    reg complete_valid_q;
    reg complete_store_q;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] complete_id_q;
    reg [RETIRE_SLOT_WIDTH-1:0] complete_slot_q;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] complete_payload_q;
    wire output_available = !complete_valid_q || complete_ready_i;
    assign atomic_result_ready = output_available;
    wire atomic_result_fire = atomic_result_valid && atomic_result_ready;
    assign misaligned_result_ready = output_available &&
                                     !atomic_result_valid;
    wire misaligned_result_fire =
        misaligned_result_valid && misaligned_result_ready;
    assign lsq_result_ready = output_available &&
                              !atomic_result_valid &&
                              !misaligned_result_valid;
    wire lsq_result_fire = lsq_result_valid && lsq_result_ready;

    wire completion_is_atomic = atomic_result_valid;
    wire completion_is_misaligned =
        !completion_is_atomic && misaligned_result_valid;
    wire [LSQ_META_WIDTH-1:0] compact_completion_meta =
        completion_is_atomic ? atomic_result_meta : lsq_result_meta;
    wire [`RV64_XLEN-1:0] compact_completion_vaddr =
        completion_is_atomic ? atomic_effective_addr : lsq_result_vaddr;
    reg [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        compact_completion_source_r;
    always @* begin
        compact_completion_source_r =
            {`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
        compact_completion_source_r[I_PRIV +: `RV64_PRIV_WIDTH] =
            compact_completion_meta[LSQ_M_PRIV +: `RV64_PRIV_WIDTH];
        compact_completion_source_r[I_INSTR_PAGE_FAULT] =
            compact_completion_meta[LSQ_M_INSTR_PAGE_FAULT];
        compact_completion_source_r[I_INSTR_ACCESS_FAULT] =
            compact_completion_meta[LSQ_M_INSTR_ACCESS_FAULT];
        compact_completion_source_r[I_ECALL] =
            compact_completion_meta[LSQ_M_ECALL];
        compact_completion_source_r[I_EBREAK] =
            compact_completion_meta[LSQ_M_EBREAK];
        compact_completion_source_r[I_ILLEGAL] =
            compact_completion_meta[LSQ_M_ILLEGAL];
        compact_completion_source_r[I_MEM_WRITE] =
            compact_completion_meta[LSQ_M_MEM_WRITE];
        compact_completion_source_r[I_MEM_READ] =
            compact_completion_meta[LSQ_M_MEM_READ];
        compact_completion_source_r[I_REG_WRITE] =
            compact_completion_meta[LSQ_M_REG_WRITE];
        compact_completion_source_r[I_LSU_OP +: `RV64_LSU_OP_WIDTH] =
            compact_completion_meta[
                LSQ_M_LSU_OP +: `RV64_LSU_OP_WIDTH];
        compact_completion_source_r[I_RD +: `RV64_REG_ADDR_WIDTH] =
            compact_completion_meta[LSQ_M_RD +: `RV64_REG_ADDR_WIDTH];
        compact_completion_source_r[I_INSTR +: `RV64_INSTR_WIDTH] =
            compact_completion_meta[LSQ_M_INSTR +: `RV64_INSTR_WIDTH];
        compact_completion_source_r[I_PC +: `RV64_XLEN] =
            compact_completion_meta[LSQ_M_PC +: `RV64_XLEN];
        compact_completion_source_r[I_TRACE +: 64] =
            compact_completion_meta[LSQ_M_TRACE +: 64];
        // Reuse the effective-address field as base+zero.  The LSU completion
        // decoder needs the address for misalignment and tval, not the
        // original operand decomposition.
        compact_completion_source_r[I_RS1_DATA +: `RV64_XLEN] =
            compact_completion_vaddr;
        compact_completion_source_r[I_IMM +: `RV64_XLEN] =
            {`RV64_XLEN{1'b0}};
    end
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] completion_source =
        completion_is_misaligned ? misaligned_meta_q :
                                   compact_completion_source_r;
    wire [`RV64_INSTR_WIDTH-1:0] completion_instr =
        completion_source[I_INSTR +: `RV64_INSTR_WIDTH];
    wire [`RV64_XLEN-1:0] completion_pc =
        completion_source[I_PC +: `RV64_XLEN];
    wire [63:0] completion_trace =
        completion_source[I_TRACE +: 64];
    wire [`RV64_REG_ADDR_WIDTH-1:0] completion_rs1 =
        completion_source[I_RS1 +: `RV64_REG_ADDR_WIDTH];
    wire [`RV64_REG_ADDR_WIDTH-1:0] completion_rs2 =
        completion_source[I_RS2 +: `RV64_REG_ADDR_WIDTH];
    wire [`RV64_XLEN-1:0] completion_rs1_data =
        completion_source[I_RS1_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] completion_rs2_data =
        completion_source[I_RS2_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] completion_imm =
        completion_source[I_IMM +: `RV64_XLEN];
    wire [`RV64_REG_ADDR_WIDTH-1:0] completion_rd =
        completion_source[I_RD +: `RV64_REG_ADDR_WIDTH];
    wire [`RV64_LSU_OP_WIDTH-1:0] completion_lsu_op =
        completion_source[I_LSU_OP +: `RV64_LSU_OP_WIDTH];
    wire completion_mem_read = completion_source[I_MEM_READ];
    wire completion_mem_write = completion_source[I_MEM_WRITE];
    wire completion_reg_write_intent = completion_source[I_REG_WRITE];
    wire completion_illegal_input = completion_source[I_ILLEGAL];
    wire completion_ebreak = completion_source[I_EBREAK];
    wire completion_ecall = completion_source[I_ECALL];
    wire completion_instr_access_fault =
        completion_source[I_INSTR_ACCESS_FAULT];
    wire completion_instr_page_fault =
        completion_source[I_INSTR_PAGE_FAULT];
    wire [`RV64_PRIV_WIDTH-1:0] completion_priv =
        completion_source[I_PRIV +: `RV64_PRIV_WIDTH];
    wire [`RV64_XLEN-1:0] completion_effective_addr =
        completion_rs1_data + completion_imm;

    wire completion_lsu_valid;
    wire completion_lsu_illegal;
    wire completion_lsu_misaligned;
    wire [`RV64_XLEN-1:0] completion_load_data;
    wire unused_completion_mem_valid;
    wire unused_completion_mem_write;
    wire [`RV64_XLEN-1:0] unused_completion_mem_addr;
    wire [`RV64_XLEN-1:0] unused_completion_mem_wdata;
    wire [7:0] unused_completion_mem_wstrb;
    openrv64_exec_lsu_rv64i u_completion_lsu (
        .op_sel_i(completion_lsu_op),
        .base_i(completion_rs1_data),
        .offset_i(completion_imm),
        .store_data_i(completion_rs2_data),
        .mem_rdata_i(lsq_result_rdata),
        .valid_o(completion_lsu_valid),
        .illegal_o(completion_lsu_illegal),
        .misaligned_o(completion_lsu_misaligned),
        .load_data_o(completion_load_data),
        .mem_valid_o(unused_completion_mem_valid),
        .mem_write_o(unused_completion_mem_write),
        .mem_addr_o(unused_completion_mem_addr),
        .mem_wdata_o(unused_completion_mem_wdata),
        .mem_wstrb_o(unused_completion_mem_wstrb)
    );

    wire load_misaligned = completion_mem_read &&
        (completion_is_atomic ? atomic_misaligned :
         completion_is_misaligned ? 1'b0 :
                                completion_lsu_misaligned);
    wire store_misaligned = completion_mem_write &&
        (completion_is_atomic ? atomic_misaligned :
         completion_is_misaligned ? 1'b0 :
                                completion_lsu_misaligned);
    wire load_access_fault = completion_mem_read &&
        (completion_is_atomic ? atomic_access_fault :
         completion_is_misaligned ? misaligned_result_access_fault :
                                lsq_result_access_fault);
    wire store_access_fault = completion_mem_write &&
        (completion_is_atomic ? atomic_access_fault :
         completion_is_misaligned ? misaligned_result_access_fault :
                                lsq_result_access_fault);
    wire load_page_fault = completion_mem_read &&
        (completion_is_atomic ? atomic_page_fault :
         completion_is_misaligned ? misaligned_result_page_fault :
                                lsq_result_page_fault);
    wire store_page_fault = completion_mem_write &&
        (completion_is_atomic ? atomic_page_fault :
         completion_is_misaligned ? misaligned_result_page_fault :
                                lsq_result_page_fault);
    wire result_illegal = completion_illegal_input ||
        (completion_is_atomic ? atomic_illegal :
         (!completion_lsu_valid || completion_lsu_illegal));

    wire exception;
    wire halt;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] cause;
    wire [`RV64_XLEN-1:0] tval;
    openrv64_except u_except (
        .illegal_instr_i(result_illegal),
        .instr_misaligned_i(|completion_pc[1:0]),
        .instr_access_fault_i(completion_instr_access_fault),
        .instr_page_fault_i(completion_instr_page_fault),
        .load_misaligned_i(load_misaligned),
        .load_access_fault_i(load_access_fault),
        .load_page_fault_i(load_page_fault),
        .store_misaligned_i(store_misaligned),
        .store_access_fault_i(store_access_fault),
        .store_page_fault_i(store_page_fault),
        .ecall_i(completion_ecall),
        .ebreak_i(completion_ebreak),
        .priv_mode_i(completion_priv),
        .pc_i(completion_pc),
        .instr_i(completion_instr),
        .badaddr_i((completion_is_misaligned &&
                    (misaligned_result_access_fault ||
                     misaligned_result_page_fault)) ?
                   misaligned_result_fault_addr :
                   completion_effective_addr),
        .exception_o(exception),
        .halt_o(halt),
        .cause_o(cause),
        .tval_o(tval)
    );

    wire [`RV64_XLEN-1:0] result_data =
        completion_is_atomic ? atomic_result :
        completion_is_misaligned && completion_mem_read ?
        format_misaligned_load(completion_lsu_op,
                               misaligned_result_rdata) :
        completion_mem_read ? completion_load_data :
        {`RV64_XLEN{1'b0}};
    wire completion_reg_write = completion_reg_write_intent &&
        (!completion_mem_write || completion_is_atomic);
    wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] completion_data = {
        completion_trace,
        completion_pc,
        completion_pc + 64'd4,
        completion_instr,
        result_data,
        completion_rs1,
        completion_rs2,
        completion_rd,
        completion_reg_write,
        result_illegal,
        completion_ebreak,
        completion_ecall,
        exception,
        halt,
        cause,
        tval,
        1'b0,
        1'b0,
        1'b0,
        {`RV64_FUNCT12_WIDTH{1'b0}},
        {`RV64_XLEN{1'b0}}
    };

    // An accepted cacheable posted store cannot report a precise fault after
    // the request handshake.  Fall its completion through to the ROB instead
    // of always paying this generic output register.  The LSQ retains the
    // store guard and tag until L1D returns store_done.  If the ROB cannot
    // accept the fall-through result, complete_valid_q remains its skid
    // buffer.
    //
    // Keep the registered path during flush.  Accepted stores are
    // irrevocable, while the ROB may be changing its live prefix on that
    // edge.
    wire posted_store_complete_bypass =
        !flush_i && !complete_valid_q &&
        !atomic_result_valid && !misaligned_result_valid &&
        lsq_result_valid && lsq_result_store &&
        lsq_result_posted_store;
    wire posted_store_complete_bypass_fire =
        posted_store_complete_bypass && complete_ready_i;

    assign complete_valid_o = complete_valid_q ||
                              posted_store_complete_bypass;
    assign complete_id_o = posted_store_complete_bypass ?
                           lsq_result_id : complete_id_q;
    assign complete_slot_o = posted_store_complete_bypass ?
                             lsq_result_slot : complete_slot_q;
    assign complete_payload_o = posted_store_complete_bypass ?
                                completion_data : complete_payload_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            complete_valid_q <= 1'b0;
            complete_store_q <= 1'b0;
            complete_id_q <= {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            complete_slot_q <= {RETIRE_SLOT_WIDTH{1'b0}};
            complete_payload_q <=
                {`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH{1'b0}};
        end else if (flush_i) begin
            // An accepted ordinary store (or completed atomic) is
            // irrevocable. Keep an already-buffered completion across a
            // younger redirect until the backend consumes it.
            complete_valid_q <= complete_valid_q && complete_store_q &&
                                !complete_ready_i;
            complete_store_q <= complete_valid_q && complete_store_q &&
                                !complete_ready_i;
            if (lsq_result_fire && lsq_result_store) begin
                complete_valid_q <= 1'b1;
                complete_id_q <= lsq_result_id;
                complete_slot_q <= lsq_result_slot;
                complete_payload_q <= completion_data;
                complete_store_q <= 1'b1;
            end else if (atomic_result_fire) begin
                complete_valid_q <= 1'b1;
                complete_id_q <= atomic_result_id;
                complete_slot_q <= atomic_result_slot;
                complete_payload_q <= completion_data;
                complete_store_q <= 1'b1;
            end else if (misaligned_result_fire) begin
                complete_valid_q <= 1'b1;
                complete_id_q <= misaligned_id_q;
                complete_slot_q <= misaligned_slot_q;
                complete_payload_q <= completion_data;
                // The ordered component sequence is irrevocable once started.
                complete_store_q <= 1'b1;
            end
        end else begin
            if (complete_valid_q && complete_ready_i) begin
                complete_valid_q <= 1'b0;
                complete_store_q <= 1'b0;
            end

            if (atomic_result_fire) begin
                complete_valid_q <= 1'b1;
                complete_id_q <= atomic_result_id;
                complete_slot_q <= atomic_result_slot;
                complete_payload_q <= completion_data;
                complete_store_q <= 1'b1;
            end else if (misaligned_result_fire) begin
                complete_valid_q <= 1'b1;
                complete_id_q <= misaligned_id_q;
                complete_slot_q <= misaligned_slot_q;
                complete_payload_q <= completion_data;
                complete_store_q <= 1'b1;
            end else if (lsq_result_fire &&
                         !posted_store_complete_bypass_fire) begin
                complete_valid_q <= 1'b1;
                complete_id_q <= lsq_result_id;
                complete_slot_q <= lsq_result_slot;
                complete_payload_q <= completion_data;
                complete_store_q <= lsq_result_store;
            end
        end
    end

endmodule
