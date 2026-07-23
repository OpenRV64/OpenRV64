`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/br-defs.v"

// Three fixed-capability execution lanes:
//
//   lane 0 / EX0: base ALU and RV64M
//   lane 1 / EX1: base ALU, branch/jump, system/CSR, traps and fences
//   lane 2 / MEM: loads, stores and RV64A
//
// The issue payload already contains captured operand values.  Each lane has
// an independent held completion port, so M and memory latency do not block
// the other ALU lane.  Valid aligned conditional branches resolve as soon as
// their operands are ready.  They still complete into the in-order retirement
// queue, and dispatch normally prevents younger issue beside a resolving
// branch.  The strict path may waive that barrier for BEQ/BNE only after its
// own operand
// comparison proves the prediction correct, so a redirect still never has
// issued younger work to squash.  ordered_head_* continues to authorize every
// other hard-ordered EX1 instruction and is also matched inside MEM before any
// store or atomic side effect is emitted.  A legal aligned direct JAL is also
// safe before the head: its target is deterministic and its link write is
// buffered until retirement.
module openrv64_exec_top_3p #(
    parameter integer RETIRE_SLOT_WIDTH = 3,
    parameter integer ENABLE_RV64M = 1,
    parameter integer ENABLE_LOCAL_FORWARDING = 1,
    parameter integer ENABLE_POSTED_STORES = 1,
    parameter [`RV64_XLEN-1:0] STORE_FORWARD_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] STORE_FORWARD_SIZE = {`RV64_XLEN{1'b0}}
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire [2:0]                   issue_valid_i,
    output wire [2:0]                   issue_ready_o,
    output wire [2:0]                   issue_unsupported_o,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] issue_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] issue_slot_i,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] issue_payload_i,
    input  wire                         branch_forward_valid_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0]
                                        branch_forward_rd_addr_i,
    input  wire [`RV64_XLEN-1:0]        branch_forward_data_i,

    input  wire                         ordered_head_valid_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] ordered_head_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] ordered_head_slot_i,

    output wire [2:0]                   complete_valid_o,
    input  wire [2:0]                   complete_ready_i,
    output wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] complete_id_o,
    output wire [3*RETIRE_SLOT_WIDTH-1:0] complete_slot_o,
    output wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] complete_payload_o,

    output wire                         async_store_fault_o,
    output wire                         async_store_page_fault_o,
    output wire [`RV64_XLEN-1:0]        async_store_fault_pc_o,
    output wire [`RV64_XLEN-1:0]        async_store_fault_addr_o,
    output wire [63:0]                  async_store_fault_trace_o,
    output wire [`RV64_INSTR_WIDTH-1:0] async_store_fault_instr_o,

    output wire                         redirect_valid_o,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] redirect_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0] redirect_slot_o,
    output wire [`RV64_XLEN-1:0]        redirect_target_o,
    output wire                         branch_resolved_o,
    output wire                         branch_conditional_o,
    output wire                         branch_taken_o,
    output wire [`RV64_XLEN-1:0]        branch_pc_o,
    output wire [`RV64_INSTR_WIDTH-1:0] branch_instr_o,

    output wire [`RV64_FUNCT12_WIDTH-1:0] csr_addr_o,
    input  wire [`RV64_XLEN-1:0]        csr_rdata_i,
    input  wire                         csr_valid_i,
    input  wire                         csr_writable_i,

    output wire                         mem_valid_o,
    input  wire                         mem_ready_i,
    output wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_tag_o,
    input  wire                         mem_resp_valid_i,
    output wire                         mem_resp_ready_o,
    input  wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_resp_tag_i,
    input  wire                         mem_error_i,
    input  wire                         mem_page_fault_i,
    input  wire                         mem_access_allowed_i,
    output wire                         mem_lock_o,
    output wire                         mem_write_o,
    output wire [`RV64_XLEN-1:0]        mem_addr_o,
    output wire [`RV64_XLEN-1:0]        mem_wdata_o,
    output wire [7:0]                   mem_wstrb_o,
    output wire                         mem_access_o,
    output wire [`RV64_XLEN-1:0]        mem_effective_addr_o,
    output wire [2:0]                   mem_size_o,
    input  wire [`RV64_XLEN-1:0]        mem_rdata_i
);

    // These low-order payload positions are fixed by backend-defs.v.  Keeping
    // capability decode here gives dispatch one unambiguous physical contract
    // and prevents a lane from silently accepting a misrouted instruction.
    wire [`RV64_ALU_EXT_WIDTH-1:0] ex0_alu_ext =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 32 +:
                        `RV64_ALU_EXT_WIDTH];
    wire [`RV64_ALU_OP_WIDTH-1:0] ex0_alu_op =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 27 +:
                        `RV64_ALU_OP_WIDTH];
    wire ex0_mem_read =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 16];
    wire ex0_mem_write =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 15];
    wire ex0_branch =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 14];
    wire ex0_jump =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 13];
    wire ex0_system =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 10];
    wire ex0_fence =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 9];
    wire ex0_illegal =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 8];
    wire ex0_ebreak =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 7];
    wire ex0_ecall =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 6];
    wire ex0_instr_access_fault =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 5];
    wire ex0_instr_page_fault =
        issue_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 4];

    wire [`RV64_ALU_EXT_WIDTH-1:0] ex1_alu_ext =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 32 +:
                        `RV64_ALU_EXT_WIDTH];
    wire [`RV64_ALU_OP_WIDTH-1:0] ex1_alu_op =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 27 +:
                        `RV64_ALU_OP_WIDTH];
    wire ex1_mem_read =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 16];
    wire ex1_mem_write =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 15];
    wire ex1_branch =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 14];
    wire ex1_jump =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 13];
    wire ex1_system =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 10];
    wire ex1_fence =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 9];
    wire ex1_illegal =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 8];
    wire ex1_ebreak =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 7];
    wire ex1_ecall =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 6];
    wire ex1_instr_access_fault =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 5];
    wire ex1_instr_page_fault =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 4];

    wire mem_mem_read =
        issue_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 16];
    wire mem_mem_write =
        issue_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 15];
    wire mem_branch =
        issue_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 14];
    wire mem_jump =
        issue_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 13];
    wire mem_system =
        issue_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 10];
    wire mem_fence =
        issue_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 9];
    wire mem_illegal =
        issue_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 8];

    wire ex0_alu = ((ex0_alu_ext == `RV64_ALU_EXT_BASE) ||
                    ((ex0_alu_ext == `RV64_ALU_EXT_M) && ENABLE_RV64M)) &&
                   (ex0_alu_op != `RV64_ALU_OP_INVALID);
    wire ex0_control = ex0_branch || ex0_jump || ex0_system || ex0_fence ||
                       ex0_illegal || ex0_ebreak || ex0_ecall ||
                       ex0_instr_access_fault || ex0_instr_page_fault;
    wire ex0_supported = ex0_alu && !ex0_mem_read && !ex0_mem_write &&
                         !ex0_control;

    wire ex1_base = (ex1_alu_ext == `RV64_ALU_EXT_BASE) &&
                    (ex1_alu_op != `RV64_ALU_OP_INVALID);
    wire ex1_control = ex1_branch || ex1_jump || ex1_system || ex1_fence ||
                       ex1_illegal || ex1_ebreak || ex1_ecall ||
                       ex1_instr_access_fault || ex1_instr_page_fault;
    wire ex1_supported = !ex1_mem_read && !ex1_mem_write &&
                         (ex1_base || ex1_control);
    // A direct conditional branch with an aligned target cannot create an
    // architectural side effect or synchronous exception at issue.  Resolve
    // it before retirement so the predictor can be corrected immediately.
    // Payload bit 41 is imm[1]; with 32-bit instruction alignment, zero proves
    // the direct target is aligned.  Faulting/illegal packets remain ordered.
    wire ex1_early_branch = ex1_branch && !ex1_illegal &&
                            !ex1_instr_access_fault &&
                            !ex1_instr_page_fault &&
                            !issue_payload_i[
                                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 41];
    wire [`RV64_BR_OP_WIDTH-1:0] ex1_br_op =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 18 +:
                        `RV64_BR_OP_WIDTH];
    wire ex1_early_jal = ex1_jump &&
                         (ex1_br_op == `RV64_BR_OP_JAL) &&
                         !ex1_illegal && !ex1_instr_access_fault &&
                         !ex1_instr_page_fault &&
                         !issue_payload_i[
                             1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 41];
    wire ex1_requires_order = ex1_control && !ex1_early_branch &&
                              !ex1_early_jal;
    wire [`RV64_INSTR_WIDTH-1:0] ex1_instr =
        issue_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 242 +:
                        `RV64_INSTR_WIDTH];
    wire ex1_satp_access = ex1_system &&
        (`RV64_FUNCT3(ex1_instr) != `RV64_FUNCT3_SYSTEM_PRIV) &&
        (`RV64_CSR(ex1_instr) == `RV64_CSR_SATP);
    wire ex1_translation_barrier =
        ex1_satp_access || `RV64_IS_SFENCE_VMA(ex1_instr);
    wire mem_posted_store_pending;
    wire ex1_order_match = ordered_head_valid_i &&
        (ordered_head_id_i == issue_id_i[
            1*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]) &&
        (ordered_head_slot_i ==
         issue_slot_i[1*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH]);
    // Big-hammer pre-translation barrier: once SATP or SFENCE.VMA reaches
    // ordered head, do not let it execute until every older posted store has
    // received its lower-level completion.  Younger stores cannot be posted
    // before ordered head.
    wire ex1_order_ready =
        (!ex1_requires_order || ex1_order_match) &&
        (!ex1_translation_barrier || !mem_posted_store_pending);
    wire mem_supported = (mem_mem_read || mem_mem_write) &&
                         !mem_branch && !mem_jump && !mem_system &&
                         !mem_fence && !mem_illegal;

    wire ex0_issue_valid = issue_valid_i[0] && ex0_supported;
    wire ex1_issue_valid = issue_valid_i[1] && ex1_supported &&
                           ex1_order_ready;
    wire mem_issue_valid = issue_valid_i[2] && mem_supported;
    wire ex0_issue_ready;
    wire ex1_issue_ready;
    wire mem_issue_ready;

    assign issue_ready_o[0] = ex0_issue_ready && ex0_supported;
    assign issue_ready_o[1] = ex1_issue_ready && ex1_supported &&
                              ex1_order_ready;
    assign issue_ready_o[2] = mem_issue_ready && mem_supported;
    assign issue_unsupported_o = {
        issue_valid_i[2] && !mem_supported,
        issue_valid_i[1] && !ex1_supported,
        issue_valid_i[0] && !ex0_supported
    };

    openrv64_exec_pipe_ex0 #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_LOCAL_FORWARDING(ENABLE_LOCAL_FORWARDING)
    ) u_ex0 (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i),
        .issue_valid_i(ex0_issue_valid),
        .issue_ready_o(ex0_issue_ready),
        .issue_id_i(issue_id_i[
            0*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]),
        .issue_slot_i(issue_slot_i[0*RETIRE_SLOT_WIDTH +:
                                   RETIRE_SLOT_WIDTH]),
        .issue_payload_i(issue_payload_i[
            0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]),
        .complete_valid_o(complete_valid_o[0]),
        .complete_ready_i(complete_ready_i[0]),
        .complete_id_o(complete_id_o[
            0*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]),
        .complete_slot_o(complete_slot_o[0*RETIRE_SLOT_WIDTH +:
                                        RETIRE_SLOT_WIDTH]),
        .complete_payload_o(complete_payload_o[
            0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH])
    );

    openrv64_exec_pipe_ex1 #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .ENABLE_LOCAL_FORWARDING(ENABLE_LOCAL_FORWARDING)
    ) u_ex1 (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i),
        .issue_valid_i(ex1_issue_valid),
        .issue_ready_o(ex1_issue_ready),
        .issue_id_i(issue_id_i[
            1*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]),
        .issue_slot_i(issue_slot_i[1*RETIRE_SLOT_WIDTH +:
                                   RETIRE_SLOT_WIDTH]),
        .issue_payload_i(issue_payload_i[
            1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]),
        .branch_forward_valid_i(branch_forward_valid_i),
        .branch_forward_rd_addr_i(branch_forward_rd_addr_i),
        .branch_forward_data_i(branch_forward_data_i),
        .complete_valid_o(complete_valid_o[1]),
        .complete_ready_i(complete_ready_i[1]),
        .complete_id_o(complete_id_o[
            1*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]),
        .complete_slot_o(complete_slot_o[1*RETIRE_SLOT_WIDTH +:
                                        RETIRE_SLOT_WIDTH]),
        .complete_payload_o(complete_payload_o[
            1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH]),
        .csr_addr_o(csr_addr_o),
        .csr_rdata_i(csr_rdata_i),
        .csr_valid_i(csr_valid_i),
        .csr_writable_i(csr_writable_i),
        .branch_resolved_o(branch_resolved_o),
        .branch_conditional_o(branch_conditional_o),
        .branch_taken_o(branch_taken_o),
        .branch_pc_o(branch_pc_o),
        .branch_instr_o(branch_instr_o),
        .redirect_valid_o(redirect_valid_o),
        .redirect_id_o(redirect_id_o),
        .redirect_slot_o(redirect_slot_o),
        .redirect_target_o(redirect_target_o)
    );

    openrv64_exec_pipe_mem #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH),
        .ENABLE_POSTED_STORES(ENABLE_POSTED_STORES),
        .STORE_FORWARD_BASE(STORE_FORWARD_BASE),
        .STORE_FORWARD_SIZE(STORE_FORWARD_SIZE)
    ) u_mem (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i),
        .issue_valid_i(mem_issue_valid),
        .issue_ready_o(mem_issue_ready),
        .issue_id_i(issue_id_i[
            2*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]),
        .issue_slot_i(issue_slot_i[2*RETIRE_SLOT_WIDTH +:
                                   RETIRE_SLOT_WIDTH]),
        .issue_payload_i(issue_payload_i[
            2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]),
        .ordered_head_valid_i(ordered_head_valid_i),
        .ordered_head_id_i(ordered_head_id_i),
        .ordered_head_slot_i(ordered_head_slot_i),
        .complete_valid_o(complete_valid_o[2]),
        .complete_ready_i(complete_ready_i[2]),
        .complete_id_o(complete_id_o[
            2*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH]),
        .complete_slot_o(complete_slot_o[2*RETIRE_SLOT_WIDTH +:
                                        RETIRE_SLOT_WIDTH]),
        .complete_payload_o(complete_payload_o[
            2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH]),
        .async_store_fault_o(async_store_fault_o),
        .async_store_page_fault_o(async_store_page_fault_o),
        .async_store_fault_pc_o(async_store_fault_pc_o),
        .async_store_fault_addr_o(async_store_fault_addr_o),
        .async_store_fault_trace_o(async_store_fault_trace_o),
        .async_store_fault_instr_o(async_store_fault_instr_o),
        .posted_store_pending_o(mem_posted_store_pending),
        .mem_valid_o(mem_valid_o),
        .mem_ready_i(mem_ready_i),
        .mem_tag_o(mem_tag_o),
        .mem_resp_valid_i(mem_resp_valid_i),
        .mem_resp_ready_o(mem_resp_ready_o),
        .mem_resp_tag_i(mem_resp_tag_i),
        .mem_error_i(mem_error_i),
        .mem_page_fault_i(mem_page_fault_i),
        .mem_access_allowed_i(mem_access_allowed_i),
        .mem_lock_o(mem_lock_o),
        .mem_write_o(mem_write_o),
        .mem_addr_o(mem_addr_o),
        .mem_wdata_o(mem_wdata_o),
        .mem_wstrb_o(mem_wstrb_o),
        .mem_access_o(mem_access_o),
        .mem_effective_addr_o(mem_effective_addr_o),
        .mem_size_o(mem_size_o),
        .mem_rdata_i(mem_rdata_i)
    );

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && !flush_i && (|issue_unsupported_o)) begin
            $fatal(1, "three-pipe dispatch sent an instruction to an unsupported lane");
        end
    end
`endif

endmodule
