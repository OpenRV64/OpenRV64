// This has to be refactored completely.

`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-a.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/except/except-defs.v"

// Three-entry pipelined MEM lane.  Independent loads can be issued and
// launched on consecutive cycles.  AXI responses carry the queue tag back to
// the matching instruction, while the backend retire queue preserves
// architectural order.  Stores launch only at ordered head.  While a posted
// store awaits its response, younger non-overlapping loads may pass and loads
// fully covered by its byte strobes forward from the retained store word.
// Another store or a partially covered load remains interlocked.  By default
// the request handshake completes the store architecturally; a later failed
// response is retained as an imprecise async abort.  RV64A remains deliberately
// serialized, but uses the same decoupled request/response port.
module openrv64_exec_pipe_mem #(
    parameter integer RETIRE_SLOT_WIDTH = 3,
    parameter integer LSU_DEPTH = `OPENRV64_LSU_OUTSTANDING,
    parameter integer LSU_TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH,
    parameter integer ENABLE_POSTED_STORES = 1,
    parameter [`RV64_XLEN-1:0] STORE_FORWARD_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] STORE_FORWARD_SIZE = {`RV64_XLEN{1'b0}}
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire                         issue_valid_i,
    output wire                         issue_ready_o,
    input  wire [63:0]                  issue_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] issue_slot_i,
    input  wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] issue_payload_i,

    input  wire                         ordered_head_valid_i,
    input  wire [63:0]                  ordered_head_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] ordered_head_slot_i,

    output wire                         complete_valid_o,
    input  wire                         complete_ready_i,
    output wire [63:0]                  complete_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0] complete_slot_o,
    output wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] complete_payload_o,

    output wire                         async_store_fault_o,
    output wire                         async_store_page_fault_o,
    output wire [`RV64_XLEN-1:0]        async_store_fault_pc_o,
    output wire [`RV64_XLEN-1:0]        async_store_fault_addr_o,
    output wire [63:0]                  async_store_fault_trace_o,
    output wire [`RV64_INSTR_WIDTH-1:0] async_store_fault_instr_o,

    output wire                         mem_valid_o,
    input  wire                         mem_ready_i,
    output wire [LSU_TAG_WIDTH-1:0]     mem_tag_o,
    input  wire                         mem_resp_valid_i,
    output wire                         mem_resp_ready_o,
    input  wire [LSU_TAG_WIDTH-1:0]     mem_resp_tag_i,
    input  wire                         mem_error_i,
    input  wire                         mem_page_fault_i,
    input  wire                         mem_access_allowed_i,
    output wire                         mem_write_o,
    output wire [`RV64_XLEN-1:0]        mem_addr_o,
    output wire [`RV64_XLEN-1:0]        mem_wdata_o,
    output wire [7:0]                   mem_wstrb_o,
    output wire                         mem_access_o,
    output wire [`RV64_XLEN-1:0]        mem_effective_addr_o,
    output wire [2:0]                   mem_size_o,
    input  wire [`RV64_XLEN-1:0]        mem_rdata_i
);

    localparam integer I_SFENCE_ALLOWED = 0;
    localparam integer I_SRET_ALLOWED = 1;
    localparam integer I_PRIV = 2;
    localparam integer I_INSTR_PAGE_FAULT = 4;
    localparam integer I_INSTR_ACCESS_FAULT = 5;
    localparam integer I_ECALL = 6;
    localparam integer I_EBREAK = 7;
    localparam integer I_ILLEGAL = 8;
    localparam integer I_FENCE = 9;
    localparam integer I_SYSTEM = 10;
    localparam integer I_WORD = 11;
    localparam integer I_PREDICTED = 12;
    localparam integer I_JUMP = 13;
    localparam integer I_BRANCH = 14;
    localparam integer I_MEM_WRITE = 15;
    localparam integer I_MEM_READ = 16;
    localparam integer I_REG_WRITE = 17;
    localparam integer I_BR_OP = 18;
    localparam integer I_LSU_OP = 22;
    localparam integer I_ALU_OP = 27;
    localparam integer I_ALU_EXT = 32;
    localparam integer I_RD = 35;
    localparam integer I_IMM = 40;
    localparam integer I_RS2_DATA = 104;
    localparam integer I_RS1_DATA = 168;
    localparam integer I_RS2 = 232;
    localparam integer I_RS1 = 237;
    localparam integer I_INSTR = 242;
    localparam integer I_PC = 274;
    localparam integer I_TRACE = 338;

    function automatic [LSU_TAG_WIDTH-1:0] next_tag;
        input [LSU_TAG_WIDTH-1:0] tag;
        begin
            next_tag = (tag == LSU_DEPTH - 1) ?
                       {LSU_TAG_WIDTH{1'b0}} : tag + 1'b1;
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

    function automatic payload_is_atomic;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        reg [`RV64_INSTR_WIDTH-1:0] payload_instr;
        begin
            payload_instr = payload[I_INSTR +: `RV64_INSTR_WIDTH];
            payload_is_atomic =
                (`RV64_OPCODE(payload_instr) == `RV64_OPCODE_AMO);
        end
    endfunction

    reg slot_valid_q [0:LSU_DEPTH-1];
    reg slot_sent_q [0:LSU_DEPTH-1];
    reg slot_posted_store_q [0:LSU_DEPTH-1];
    reg [63:0] slot_id_q [0:LSU_DEPTH-1];
    reg [RETIRE_SLOT_WIDTH-1:0] slot_retire_q [0:LSU_DEPTH-1];
    reg [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        slot_payload_q [0:LSU_DEPTH-1];
    reg [LSU_TAG_WIDTH-1:0] issue_tail_q;
    reg [LSU_TAG_WIDTH-1:0] send_head_q;

    reg atomic_active_q;
    reg atomic_started_q;
    reg atomic_req_inflight_q;
    reg [63:0] atomic_id_q;
    reg [RETIRE_SLOT_WIDTH-1:0] atomic_slot_q;
    reg [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] atomic_payload_q;

    reg store_inflight_q;
    reg [LSU_TAG_WIDTH-1:0] store_tag_q;
    reg [`RV64_XLEN-1:0] store_addr_q;
    reg [`RV64_XLEN-1:0] store_wdata_q;
    reg [7:0] store_wstrb_q;

    reg complete_valid_q;
    reg [63:0] complete_id_q;
    reg [RETIRE_SLOT_WIDTH-1:0] complete_slot_q;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] complete_payload_q;
    wire output_available = !complete_valid_q || complete_ready_i;

    wire issue_is_atomic = payload_is_atomic(issue_payload_i);
    wire simple_any_valid = slot_valid_q[0] || slot_valid_q[1] ||
                            slot_valid_q[2];
    assign issue_ready_o = issue_is_atomic ?
        (!atomic_active_q && !simple_any_valid && output_available) :
        (!atomic_active_q && !slot_valid_q[issue_tail_q]);
    wire issue_fire = issue_valid_i && issue_ready_o;
    wire issue_simple_fire = issue_fire && !issue_is_atomic;
    wire issue_atomic_fire = issue_fire && issue_is_atomic;

    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] request_payload =
        slot_payload_q[send_head_q];
    wire request_slot_valid = slot_valid_q[send_head_q] &&
                              !slot_sent_q[send_head_q];
    wire [`RV64_INSTR_WIDTH-1:0] request_instr =
        request_payload[I_INSTR +: `RV64_INSTR_WIDTH];
    wire [`RV64_XLEN-1:0] request_rs1_data =
        request_payload[I_RS1_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] request_rs2_data =
        request_payload[I_RS2_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] request_imm =
        request_payload[I_IMM +: `RV64_XLEN];
    wire [`RV64_LSU_OP_WIDTH-1:0] request_lsu_op =
        request_payload[I_LSU_OP +: `RV64_LSU_OP_WIDTH];
    wire request_mem_read = request_payload[I_MEM_READ];
    wire request_mem_write = request_payload[I_MEM_WRITE];
    wire request_illegal = request_payload[I_ILLEGAL];
    wire request_instr_access_fault = request_payload[I_INSTR_ACCESS_FAULT];
    wire request_instr_page_fault = request_payload[I_INSTR_PAGE_FAULT];
    wire [`RV64_XLEN-1:0] request_effective_addr =
        request_rs1_data + request_imm;
    wire [2:0] request_access_size = {1'b0, request_instr[13:12]};

    wire request_lsu_valid;
    wire request_lsu_illegal;
    wire request_lsu_misaligned;
    wire [`RV64_XLEN-1:0] unused_request_load_data;
    wire request_bus_valid;
    wire request_bus_write;
    wire [`RV64_XLEN-1:0] request_bus_addr;
    wire [`RV64_XLEN-1:0] request_bus_wdata;
    wire [7:0] request_bus_wstrb;
    openrv64_exec_lsu_rv64i u_request_lsu (
        .op_sel_i(request_lsu_op), .base_i(request_rs1_data),
        .offset_i(request_imm), .store_data_i(request_rs2_data),
        .mem_rdata_i({`RV64_XLEN{1'b0}}),
        .valid_o(request_lsu_valid), .illegal_o(request_lsu_illegal),
        .misaligned_o(request_lsu_misaligned),
        .load_data_o(unused_request_load_data),
        .mem_valid_o(request_bus_valid), .mem_write_o(request_bus_write),
        .mem_addr_o(request_bus_addr), .mem_wdata_o(request_bus_wdata),
        .mem_wstrb_o(request_bus_wstrb)
    );

    wire request_order_match = ordered_head_valid_i &&
        (ordered_head_id_i == slot_id_q[send_head_q]) &&
        (ordered_head_slot_i == slot_retire_q[send_head_q]);
    wire normal_resp_fire = !atomic_active_q && mem_resp_valid_i &&
        mem_resp_ready_o && (mem_resp_tag_i < LSU_DEPTH) &&
        slot_valid_q[mem_resp_tag_i] && slot_sent_q[mem_resp_tag_i];
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        posted_response_payload = slot_payload_q[mem_resp_tag_i];
    wire posted_response_fault = normal_resp_fire &&
        slot_posted_store_q[mem_resp_tag_i] &&
        (mem_error_i || mem_page_fault_i);
    assign async_store_fault_o = posted_response_fault;
    assign async_store_page_fault_o = posted_response_fault &&
                                     mem_page_fault_i;
    assign async_store_fault_pc_o = posted_response_payload[
        I_PC +: `RV64_XLEN];
    assign async_store_fault_addr_o =
        posted_response_payload[I_RS1_DATA +: `RV64_XLEN] +
        posted_response_payload[I_IMM +: `RV64_XLEN];
    assign async_store_fault_trace_o = posted_response_payload[I_TRACE +: 64];
    assign async_store_fault_instr_o = posted_response_payload[
        I_INSTR +: `RV64_INSTR_WIDTH];
    wire request_immediate = request_slot_valid &&
        (request_illegal || request_instr_access_fault ||
         request_instr_page_fault ||
         !(request_mem_read || request_mem_write) ||
         !request_lsu_valid || request_lsu_illegal ||
         request_lsu_misaligned || !mem_access_allowed_i);
    wire posted_store_candidate = (ENABLE_POSTED_STORES != 0) &&
                                  request_mem_write;
    wire [7:0] request_load_mask =
        access_byte_mask(request_access_size, request_bus_addr[2:0]);
    wire pending_store_same_word = store_inflight_q &&
        (request_bus_addr[`RV64_XLEN-1:3] ==
         store_addr_q[`RV64_XLEN-1:3]);
    wire pending_store_load_overlap = store_inflight_q &&
        request_mem_read && pending_store_same_word &&
        (|(request_load_mask & store_wstrb_q));
    wire request_store_forwardable =
        (STORE_FORWARD_SIZE != {`RV64_XLEN{1'b0}}) &&
        (request_bus_addr >= STORE_FORWARD_BASE) &&
        (request_bus_addr < (STORE_FORWARD_BASE + STORE_FORWARD_SIZE));
    wire pending_store_load_covered = pending_store_load_overlap &&
        request_store_forwardable &&
        ((request_load_mask & store_wstrb_q) == request_load_mask);
    wire pending_store_order_block = store_inflight_q &&
        (request_mem_write || pending_store_load_overlap);
    wire simple_request_valid = request_slot_valid && !request_immediate &&
        request_bus_valid && !pending_store_order_block &&
        (!request_mem_write || request_order_match) &&
        (!posted_store_candidate ||
         (output_available && !normal_resp_fire));

    wire [`RV64_INSTR_WIDTH-1:0] atomic_instr =
        atomic_payload_q[I_INSTR +: `RV64_INSTR_WIDTH];
    wire [`RV64_XLEN-1:0] atomic_rs1_data =
        atomic_payload_q[I_RS1_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] atomic_rs2_data =
        atomic_payload_q[I_RS2_DATA +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] atomic_imm =
        atomic_payload_q[I_IMM +: `RV64_XLEN];
    wire [`RV64_LSU_OP_WIDTH-1:0] atomic_lsu_op =
        atomic_payload_q[I_LSU_OP +: `RV64_LSU_OP_WIDTH];
    wire [`RV64_XLEN-1:0] atomic_effective_addr =
        atomic_rs1_data + atomic_imm;
    wire [2:0] atomic_access_size = {1'b0, atomic_instr[13:12]};
    wire atomic_order_match = ordered_head_valid_i &&
        (ordered_head_id_i == atomic_id_q) &&
        (ordered_head_slot_i == atomic_slot_q);
    wire atomic_run = atomic_active_q &&
                      (atomic_started_q || atomic_order_match);
    wire atomic_complete;
    wire atomic_illegal;
    wire atomic_misaligned;
    wire atomic_access_fault;
    wire atomic_page_fault;
    wire [`RV64_XLEN-1:0] atomic_result;
    wire atomic_mem_valid;
    wire atomic_mem_write;
    wire [`RV64_XLEN-1:0] atomic_mem_addr;
    wire [`RV64_XLEN-1:0] atomic_mem_wdata;
    wire [7:0] atomic_mem_wstrb;
    wire atomic_resp_fire = atomic_active_q && atomic_req_inflight_q &&
                            mem_resp_valid_i && mem_resp_ready_o;
    wire atomic_finish = atomic_active_q && atomic_complete &&
                         output_available;
    wire clear_atomic_reservation = normal_resp_fire &&
        slot_payload_q[mem_resp_tag_i][I_MEM_WRITE];
    openrv64_exec_lsu_rv64a u_atomic (
        .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
        .valid_i(atomic_run), .consume_i(atomic_finish),
        .clear_reservation_i(clear_atomic_reservation),
        .op_sel_i(atomic_lsu_op),
        .size_sel_i(atomic_access_size[`RV64_LSU_SIZE_WIDTH-1:0]),
        .addr_i(atomic_effective_addr), .store_data_i(atomic_rs2_data),
        .mem_ready_i(atomic_resp_fire), .mem_error_i(mem_error_i),
        .mem_page_fault_i(mem_page_fault_i),
        .mem_access_allowed_i(mem_access_allowed_i),
        .mem_rdata_i(mem_rdata_i), .complete_o(atomic_complete),
        .illegal_o(atomic_illegal), .misaligned_o(atomic_misaligned),
        .access_fault_o(atomic_access_fault),
        .page_fault_o(atomic_page_fault), .result_o(atomic_result),
        .mem_valid_o(atomic_mem_valid), .mem_write_o(atomic_mem_write),
        .mem_addr_o(atomic_mem_addr), .mem_wdata_o(atomic_mem_wdata),
        .mem_wstrb_o(atomic_mem_wstrb)
    );

    wire atomic_request_valid = atomic_active_q && atomic_mem_valid &&
                                !atomic_req_inflight_q;
    assign mem_valid_o = atomic_active_q ? atomic_request_valid :
                         simple_request_valid;
    assign mem_tag_o = atomic_active_q ? {LSU_TAG_WIDTH{1'b0}} : send_head_q;
    assign mem_write_o = atomic_active_q ? atomic_mem_write : request_bus_write;
    assign mem_addr_o = atomic_active_q ? atomic_mem_addr : request_bus_addr;
    assign mem_wdata_o = atomic_active_q ? atomic_mem_wdata : request_bus_wdata;
    assign mem_wstrb_o = atomic_active_q ? atomic_mem_wstrb : request_bus_wstrb;
    assign mem_access_o = atomic_active_q ? atomic_run :
                          request_slot_valid;
    assign mem_effective_addr_o = atomic_active_q ? atomic_effective_addr :
                                  request_effective_addr;
    assign mem_size_o = atomic_active_q ? atomic_access_size :
                        request_access_size;
    wire mem_request_fire = mem_valid_o && mem_ready_i;
    wire simple_request_fire = mem_request_fire && !atomic_active_q;
    wire posted_store_fire = simple_request_fire && posted_store_candidate;
    wire atomic_request_fire = mem_request_fire && atomic_active_q;
    assign mem_resp_ready_o = atomic_active_q ? atomic_req_inflight_q :
                              output_available;

    wire store_forward_completion = request_slot_valid &&
        !request_immediate && request_bus_valid &&
        pending_store_load_covered && output_available &&
        !normal_resp_fire;
    wire local_completion =
        (request_immediate || store_forward_completion) &&
        output_available && !normal_resp_fire;
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] response_payload =
        slot_payload_q[mem_resp_tag_i];
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] completion_source =
        normal_resp_fire ? response_payload :
        atomic_finish ? atomic_payload_q : request_payload;
    wire completion_is_atomic = atomic_finish;
    wire [`RV64_INSTR_WIDTH-1:0] completion_instr =
        completion_source[I_INSTR +: `RV64_INSTR_WIDTH];
    wire [`RV64_XLEN-1:0] completion_pc =
        completion_source[I_PC +: `RV64_XLEN];
    wire [63:0] completion_trace = completion_source[I_TRACE +: 64];
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
        .op_sel_i(completion_lsu_op), .base_i(completion_rs1_data),
        .offset_i(completion_imm), .store_data_i(completion_rs2_data),
        .mem_rdata_i(store_forward_completion ? store_wdata_q : mem_rdata_i),
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
                                completion_lsu_misaligned);
    wire store_misaligned = completion_mem_write &&
        (completion_is_atomic ? atomic_misaligned :
                                completion_lsu_misaligned);
    wire load_access_fault = completion_mem_read &&
        (completion_is_atomic ? atomic_access_fault :
         ((!mem_access_allowed_i && completion_lsu_valid &&
           !completion_lsu_misaligned) ||
          (normal_resp_fire && mem_error_i)));
    wire store_access_fault = completion_mem_write &&
        (completion_is_atomic ? atomic_access_fault :
         ((!mem_access_allowed_i && completion_lsu_valid &&
           !completion_lsu_misaligned) ||
          (normal_resp_fire && mem_error_i)));
    wire load_page_fault = completion_mem_read &&
        (completion_is_atomic ? atomic_page_fault :
         (normal_resp_fire && mem_page_fault_i));
    wire store_page_fault = completion_mem_write &&
        (completion_is_atomic ? atomic_page_fault :
         (normal_resp_fire && mem_page_fault_i));
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
        .ecall_i(completion_ecall), .ebreak_i(completion_ebreak),
        .priv_mode_i(completion_priv), .pc_i(completion_pc),
        .instr_i(completion_instr), .badaddr_i(completion_effective_addr),
        .exception_o(exception), .halt_o(halt), .cause_o(cause),
        .tval_o(tval)
    );

    wire [`RV64_XLEN-1:0] result_data = completion_is_atomic ? atomic_result :
        (completion_mem_read ? completion_load_data : {`RV64_XLEN{1'b0}});
    wire completion_reg_write = completion_reg_write_intent &&
                                (!completion_mem_write ||
                                 completion_is_atomic);
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

    assign complete_valid_o = complete_valid_q;
    assign complete_id_o = complete_id_q;
    assign complete_slot_o = complete_slot_q;
    assign complete_payload_o = complete_payload_q;

    integer slot_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_tail_q <= {LSU_TAG_WIDTH{1'b0}};
            send_head_q <= {LSU_TAG_WIDTH{1'b0}};
            atomic_active_q <= 1'b0;
            atomic_started_q <= 1'b0;
            atomic_req_inflight_q <= 1'b0;
            atomic_id_q <= 64'd0;
            atomic_slot_q <= {RETIRE_SLOT_WIDTH{1'b0}};
            atomic_payload_q <= {`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
            store_inflight_q <= 1'b0;
            store_tag_q <= {LSU_TAG_WIDTH{1'b0}};
            store_addr_q <= {`RV64_XLEN{1'b0}};
            store_wdata_q <= {`RV64_XLEN{1'b0}};
            store_wstrb_q <= 8'h00;
            complete_valid_q <= 1'b0;
            complete_id_q <= 64'd0;
            complete_slot_q <= {RETIRE_SLOT_WIDTH{1'b0}};
            complete_payload_q <=
                {`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH{1'b0}};
            for (slot_index = 0; slot_index < LSU_DEPTH;
                 slot_index = slot_index + 1) begin
                slot_valid_q[slot_index] <= 1'b0;
                slot_sent_q[slot_index] <= 1'b0;
                slot_posted_store_q[slot_index] <= 1'b0;
                slot_id_q[slot_index] <= 64'd0;
                slot_retire_q[slot_index] <= {RETIRE_SLOT_WIDTH{1'b0}};
                slot_payload_q[slot_index] <=
                    {`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
            end
        end else if (flush_i) begin
            issue_tail_q <= {LSU_TAG_WIDTH{1'b0}};
            send_head_q <= {LSU_TAG_WIDTH{1'b0}};
            atomic_active_q <= 1'b0;
            atomic_started_q <= 1'b0;
            atomic_req_inflight_q <= 1'b0;
            store_inflight_q <= 1'b0;
            complete_valid_q <= 1'b0;
            for (slot_index = 0; slot_index < LSU_DEPTH;
                 slot_index = slot_index + 1) begin
                slot_valid_q[slot_index] <= 1'b0;
                slot_sent_q[slot_index] <= 1'b0;
                slot_posted_store_q[slot_index] <= 1'b0;
            end

            // An ordered posted store is already architecturally committed
            // and cannot be cancelled by a younger redirect.  Keep its tag
            // and metadata live until the response arrives so a delayed bus
            // error can become an imprecise abort.  Speculative younger loads
            // are cancelled and drained by the bus; retain only the already
            // committed store in this execution queue.
            if (store_inflight_q && slot_posted_store_q[store_tag_q] &&
                !normal_resp_fire) begin
                issue_tail_q <= next_tag(store_tag_q);
                send_head_q <= next_tag(store_tag_q);
                store_inflight_q <= 1'b1;
                slot_valid_q[store_tag_q] <= 1'b1;
                slot_sent_q[store_tag_q] <= 1'b1;
                slot_posted_store_q[store_tag_q] <= 1'b1;
            end
        end else begin
            if (complete_valid_q && complete_ready_i)
                complete_valid_q <= 1'b0;

            if (issue_simple_fire) begin
                slot_valid_q[issue_tail_q] <= 1'b1;
                slot_sent_q[issue_tail_q] <= 1'b0;
                slot_posted_store_q[issue_tail_q] <= 1'b0;
                slot_id_q[issue_tail_q] <= issue_id_i;
                slot_retire_q[issue_tail_q] <= issue_slot_i;
                slot_payload_q[issue_tail_q] <= issue_payload_i;
                issue_tail_q <= next_tag(issue_tail_q);
            end

            if (issue_atomic_fire) begin
                atomic_active_q <= 1'b1;
                atomic_started_q <= 1'b0;
                atomic_req_inflight_q <= 1'b0;
                atomic_id_q <= issue_id_i;
                atomic_slot_q <= issue_slot_i;
                atomic_payload_q <= issue_payload_i;
            end

            if (atomic_active_q && !atomic_started_q && atomic_order_match)
                atomic_started_q <= 1'b1;

            if (simple_request_fire) begin
                slot_sent_q[send_head_q] <= 1'b1;
                send_head_q <= next_tag(send_head_q);
                if (request_mem_write) begin
                    store_inflight_q <= 1'b1;
                    store_tag_q <= send_head_q;
                    store_addr_q <= request_bus_addr;
                    store_wdata_q <= request_bus_wdata;
                    store_wstrb_q <= request_bus_wstrb;
                    if (ENABLE_POSTED_STORES != 0)
                        slot_posted_store_q[send_head_q] <= 1'b1;
                end
            end

            if (atomic_request_fire)
                atomic_req_inflight_q <= 1'b1;
            if (atomic_resp_fire)
                atomic_req_inflight_q <= 1'b0;

            if (normal_resp_fire) begin
                slot_valid_q[mem_resp_tag_i] <= 1'b0;
                slot_sent_q[mem_resp_tag_i] <= 1'b0;
                slot_posted_store_q[mem_resp_tag_i] <= 1'b0;
                if (store_inflight_q && (store_tag_q == mem_resp_tag_i))
                    store_inflight_q <= 1'b0;
                if (!slot_posted_store_q[mem_resp_tag_i]) begin
                    complete_valid_q <= 1'b1;
                    complete_id_q <= slot_id_q[mem_resp_tag_i];
                    complete_slot_q <= slot_retire_q[mem_resp_tag_i];
                    complete_payload_q <= completion_data;
                end
            end else if (posted_store_fire) begin
                // The ordered request handshake is architectural completion.
                // The eventual response releases the LSU tag; a response
                // fault is reported separately as an imprecise async abort.
                complete_valid_q <= 1'b1;
                complete_id_q <= slot_id_q[send_head_q];
                complete_slot_q <= slot_retire_q[send_head_q];
                complete_payload_q <= completion_data;
            end else if (local_completion) begin
                slot_valid_q[send_head_q] <= 1'b0;
                slot_sent_q[send_head_q] <= 1'b0;
                send_head_q <= next_tag(send_head_q);
                complete_valid_q <= 1'b1;
                complete_id_q <= slot_id_q[send_head_q];
                complete_slot_q <= slot_retire_q[send_head_q];
                complete_payload_q <= completion_data;
            end else if (atomic_finish) begin
                atomic_active_q <= 1'b0;
                atomic_started_q <= 1'b0;
                atomic_req_inflight_q <= 1'b0;
                complete_valid_q <= 1'b1;
                complete_id_q <= atomic_id_q;
                complete_slot_q <= atomic_slot_q;
                complete_payload_q <= completion_data;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (LSU_DEPTH != 3)
            $fatal(1, "pipelined LSU currently requires exactly three tags");
    end

    always @(posedge clk) begin
        if (rst_n && !flush_i && mem_resp_valid_i && mem_resp_ready_o &&
            !atomic_active_q &&
            ((mem_resp_tag_i >= LSU_DEPTH) ||
             !slot_valid_q[mem_resp_tag_i] ||
             !slot_sent_q[mem_resp_tag_i]))
            $fatal(1, "MEM response tag does not name an outstanding request");
    end
`endif

    wire unused_controls = |{
        completion_source[I_ALU_EXT +: `RV64_ALU_EXT_WIDTH],
        completion_source[I_ALU_OP +: `RV64_ALU_OP_WIDTH],
        completion_source[I_BR_OP +: `RV64_BR_OP_WIDTH],
        completion_source[I_BRANCH], completion_source[I_JUMP],
        completion_source[I_PREDICTED], completion_source[I_WORD],
        completion_source[I_SYSTEM], completion_source[I_FENCE],
        completion_source[I_SRET_ALLOWED],
        completion_source[I_SFENCE_ALLOWED]
    };

endmodule
