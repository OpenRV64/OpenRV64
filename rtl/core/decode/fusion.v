`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/decode/defs/br-defs.v"
`include "core/decode/defs/fusion-defs.v"

// One-entry macro-fusion candidate buffer.
//
// A bundle adapter presents an ordered candidate and its immediate successor.
// When the successor is not yet available, the candidate is retained across
// the bundle boundary.  A decision returns both original records so dispatch
// can either release them unchanged or suppress them and admit one compound
// operation.  This module deliberately owns no rename, ROB, or scheduler
// state.
//
// The first supported form is the canonical PC-relative call:
//
//     auipc rd, upper
//     jalr  rd, lower(rd)
//
// It becomes a long-range branch-and-link with link PC first_pc + 8.  JALR
// still clears target bit zero in execution.  Any remaining instruction
// alignment check is an execution/ISA-configuration concern, not a fusion
// predicate.
module openrv64_decode_fusion #(
    parameter integer ID_WIDTH = 32,
    parameter integer PAYLOAD_WIDTH = 1
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire                         candidate_valid_i,
    output wire                         candidate_ready_o,
    input  wire [`OPENRV64_FUSION_CANDIDATE_WIDTH-1:0]
                                        candidate_class_i,
    input  wire [`RV64_XLEN-1:0]        candidate_pc_i,
    input  wire [ID_WIDTH-1:0]          candidate_id_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] candidate_instr_i,
    input  wire [2:0]                   candidate_instr_bytes_i,
    input  wire [PAYLOAD_WIDTH-1:0]     candidate_payload_i,

    input  wire                         successor_valid_i,
    output wire                         successor_ready_o,
    input  wire [`RV64_XLEN-1:0]        successor_pc_i,
    input  wire [ID_WIDTH-1:0]          successor_id_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] successor_instr_i,
    input  wire [2:0]                   successor_instr_bytes_i,
    input  wire [PAYLOAD_WIDTH-1:0]     successor_payload_i,

    output wire                         decision_valid_o,
    input  wire                         decision_ready_i,
    output wire                         decision_fused_o,
    output wire                         release_candidate_o,
    output wire                         release_successor_o,
    output wire                         squash_candidate_o,
    output wire                         squash_successor_o,
    output wire [`OPENRV64_FUSION_OP_WIDTH-1:0] fusion_op_o,
    output wire [1:0]                   fused_instruction_count_o,

    output wire [`RV64_XLEN-1:0]        first_pc_o,
    output wire [ID_WIDTH-1:0]          first_id_o,
    output wire [`RV64_INSTR_WIDTH-1:0] first_instr_o,
    output wire [2:0]                   first_instr_bytes_o,
    output wire [PAYLOAD_WIDTH-1:0]     first_payload_o,
    output wire [`RV64_XLEN-1:0]        second_pc_o,
    output wire [ID_WIDTH-1:0]          second_id_o,
    output wire [`RV64_INSTR_WIDTH-1:0] second_instr_o,
    output wire [2:0]                   second_instr_bytes_o,
    output wire [PAYLOAD_WIDTH-1:0]     second_payload_o,

    output wire [`RV64_XLEN-1:0]        fused_pc_relative_offset_o,
    output wire [`RV64_XLEN-1:0]        fused_link_pc_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] fused_rd_o,
    output wire                         candidate_pending_o
);

    reg                                 candidate_valid_q;
    reg [`OPENRV64_FUSION_CANDIDATE_WIDTH-1:0]
                                        candidate_class_q;
    reg [`RV64_XLEN-1:0]                candidate_pc_q;
    reg [ID_WIDTH-1:0]                  candidate_id_q;
    reg [`RV64_INSTR_WIDTH-1:0]         candidate_instr_q;
    reg [2:0]                           candidate_instr_bytes_q;
    reg [PAYLOAD_WIDTH-1:0]             candidate_payload_q;

    wire candidate_available = candidate_valid_q || candidate_valid_i;
    wire [`OPENRV64_FUSION_CANDIDATE_WIDTH-1:0] selected_class =
        candidate_valid_q ? candidate_class_q : candidate_class_i;
    wire [`RV64_XLEN-1:0] selected_pc =
        candidate_valid_q ? candidate_pc_q : candidate_pc_i;
    wire [ID_WIDTH-1:0] selected_id =
        candidate_valid_q ? candidate_id_q : candidate_id_i;
    wire [`RV64_INSTR_WIDTH-1:0] selected_instr =
        candidate_valid_q ? candidate_instr_q : candidate_instr_i;
    wire [2:0] selected_instr_bytes = candidate_valid_q ?
        candidate_instr_bytes_q : candidate_instr_bytes_i;
    wire [PAYLOAD_WIDTH-1:0] selected_payload = candidate_valid_q ?
        candidate_payload_q : candidate_payload_i;

    wire [`RV64_XLEN-1:0] selected_next_pc =
        selected_pc + {{(`RV64_XLEN-3){1'b0}}, selected_instr_bytes};
    wire [ID_WIDTH-1:0] selected_next_id =
        selected_id + {{(ID_WIDTH-1){1'b0}}, 1'b1};
    wire [`RV64_REG_ADDR_WIDTH-1:0] selected_rd =
        `RV64_RD(selected_instr);

    wire pcrel_call_match =
        (selected_class == `OPENRV64_FUSION_CANDIDATE_PCREL_CALL) &&
        `RV64_INSTR_IS_AUIPC(selected_instr) &&
        `RV64_INSTR_IS_JALR(successor_instr_i) &&
        (selected_instr_bytes == 3'd4) &&
        (successor_instr_bytes_i == 3'd4) &&
        (selected_rd != `RV64_REG_X0) &&
        (`RV64_RS1(successor_instr_i) == selected_rd) &&
        (`RV64_RD(successor_instr_i) == selected_rd) &&
        (successor_pc_i == selected_next_pc) &&
        (successor_id_i == selected_next_id);

    assign decision_valid_o = !flush_i && candidate_available &&
                              successor_valid_i;
    assign decision_fused_o = decision_valid_o && pcrel_call_match;
    assign release_candidate_o = decision_valid_o && !pcrel_call_match;
    assign release_successor_o = release_candidate_o;
    assign squash_candidate_o = decision_fused_o;
    assign squash_successor_o = decision_fused_o;
    assign fusion_op_o = decision_fused_o ?
        `OPENRV64_FUSION_OP_PCREL_CALL : `OPENRV64_FUSION_OP_NONE;
    assign fused_instruction_count_o = decision_fused_o ? 2'd2 : 2'd0;

    // An empty buffer can resolve a same-bundle pair by bypass.  Otherwise it
    // accepts and retains the candidate until the successor becomes visible.
    assign candidate_ready_o = !flush_i && !candidate_valid_q &&
        (!successor_valid_i || decision_ready_i);
    assign successor_ready_o = decision_valid_o && decision_ready_i;

    assign first_pc_o = selected_pc;
    assign first_id_o = selected_id;
    assign first_instr_o = selected_instr;
    assign first_instr_bytes_o = selected_instr_bytes;
    assign first_payload_o = selected_payload;
    assign second_pc_o = successor_pc_i;
    assign second_id_o = successor_id_i;
    assign second_instr_o = successor_instr_i;
    assign second_instr_bytes_o = successor_instr_bytes_i;
    assign second_payload_o = successor_payload_i;

    assign fused_pc_relative_offset_o =
        `RV64_IMM_U(selected_instr) + `RV64_IMM_I(successor_instr_i);
    assign fused_link_pc_o = successor_pc_i +
        {{(`RV64_XLEN-3){1'b0}}, successor_instr_bytes_i};
    assign fused_rd_o = decision_fused_o ? selected_rd : `RV64_REG_X0;
    assign candidate_pending_o = candidate_valid_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            candidate_valid_q       <= 1'b0;
            candidate_class_q       <= `OPENRV64_FUSION_CANDIDATE_NONE;
            candidate_pc_q          <= {`RV64_XLEN{1'b0}};
            candidate_id_q          <= {ID_WIDTH{1'b0}};
            candidate_instr_q       <= {`RV64_INSTR_WIDTH{1'b0}};
            candidate_instr_bytes_q <= 3'd0;
            candidate_payload_q     <= {PAYLOAD_WIDTH{1'b0}};
        end else if (flush_i) begin
            candidate_valid_q       <= 1'b0;
        end else if (candidate_valid_q) begin
            if (decision_valid_o && decision_ready_i)
                candidate_valid_q <= 1'b0;
        end else if (candidate_valid_i && candidate_ready_o &&
                     !successor_valid_i) begin
            candidate_valid_q       <= 1'b1;
            candidate_class_q       <= candidate_class_i;
            candidate_pc_q          <= candidate_pc_i;
            candidate_id_q          <= candidate_id_i;
            candidate_instr_q       <= candidate_instr_i;
            candidate_instr_bytes_q <= candidate_instr_bytes_i;
            candidate_payload_q     <= candidate_payload_i;
        end
    end

endmodule

// Three-lane decode-stream adapter.  A final candidate is retained until its
// immediate successor becomes visible; all other records remain combinational
// to the backend.  This avoids adding a pipeline stage to ordinary decode.
// A fused pair remains two ROB records.  The candidate executes normally at
// its original PC and the successor becomes the executed macro-op.  The
// successor no longer names the producer as a source because its direct target
// or compare constant is already embedded in the rewritten payload.  This
// preserves the producer operation while isolating the dependency-elision
// benefit from the storage/retirement changes of full macro-op fusion.
// A fused PC-relative call's successor record has:
//
//   * PC and instruction identity attributed to JALR,
//   * a direct PC-relative target measured from the JALR PC,
//   * no source-register dependency, and
//   * the payload fused bit set.
//
// A fused ADDI-x0/conditional-branch pair keeps the branch identity and target,
// embeds the immediate in the consumed source operand, and retains only the
// other original branch dependency.  The separate ADDI record produces the
// architectural destination.
module openrv64_decode_fusion_3p #(
    parameter integer PAYLOAD_WIDTH = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire [2:0]                   input_valid_i,
    output reg  [2:0]                   input_ready_o,
    input  wire [3*PAYLOAD_WIDTH-1:0]   input_payload_i,
    input  wire [2:0]                   input_uses_rs1_i,
    input  wire [2:0]                   input_uses_rs2_i,
    input  wire [2:0]                   input_candidate_i,
    input  wire [3*`OPENRV64_FUSION_CANDIDATE_WIDTH-1:0]
                                        input_candidate_class_i,

    output reg  [2:0]                   output_valid_o,
    input  wire [2:0]                   output_ready_i,
    output reg  [3*PAYLOAD_WIDTH-1:0]   output_payload_o,
    output reg  [2:0]                   output_uses_rs1_o,
    output reg  [2:0]                   output_uses_rs2_o,
    output reg  [2:0]                   output_fused_o,

    // For predictor sideband bookkeeping: each accepted input record which
    // reaches the backend maps to its output lane named here.
    output reg  [2:0]                   input_output_valid_o,
    output reg  [3*2-1:0]               input_output_lane_o,

    output wire [1:0]                   candidate_accept_count_o,
    output wire [1:0]                   pcrel_candidate_accept_count_o,
    output wire [1:0]                   li_candidate_accept_count_o,
    output reg  [1:0]                   fused_accept_count_o,
    output reg  [1:0]                   pcrel_fused_accept_count_o,
    output reg  [1:0]                   li_fused_accept_count_o,
    output wire                         candidate_pending_o
);

    reg pending_valid_q;
    reg [PAYLOAD_WIDTH-1:0] pending_payload_q;
    reg pending_uses_rs1_q;
    reg pending_uses_rs2_q;
    reg [`OPENRV64_FUSION_CANDIDATE_WIDTH-1:0]
        pending_candidate_class_q;

    reg [PAYLOAD_WIDTH-1:0] seq_payload_r [0:3];
    reg seq_uses_rs1_r [0:3];
    reg seq_uses_rs2_r [0:3];
    reg seq_candidate_r [0:3];
    reg [`OPENRV64_FUSION_CANDIDATE_WIDTH-1:0]
        seq_candidate_class_r [0:3];
    reg seq_pair_match_r [0:3];
    reg seq_is_input_r [0:3];
    reg [1:0] seq_input_lane_r [0:3];
    reg [2:0] output_end_r [0:2];

    integer input_count_r;
    integer seq_count_r;
    integer parse_index_r;
    integer parse_start_r;
    integer accepted_seq_count_r;
    integer accepted_input_count_r;
    integer output_index_r;
    integer seq_index_r;
    reg tail_store_r;
    reg [PAYLOAD_WIDTH-1:0] tail_payload_r;
    reg tail_uses_rs1_r;
    reg tail_uses_rs2_r;
    reg [`OPENRV64_FUSION_CANDIDATE_WIDTH-1:0]
        tail_candidate_class_r;

    wire input_fire0 = input_valid_i[0] && input_ready_o[0];
    wire input_fire1 = input_valid_i[1] && input_ready_o[1] && input_fire0;
    wire input_fire2 = input_valid_i[2] && input_ready_o[2] && input_fire1;
    wire [2:0] input_fire = {input_fire2, input_fire1, input_fire0};

    assign candidate_accept_count_o =
        {1'b0, input_fire[0] && input_candidate_i[0]} +
        {1'b0, input_fire[1] && input_candidate_i[1]} +
        {1'b0, input_fire[2] && input_candidate_i[2]};
    assign pcrel_candidate_accept_count_o =
        {1'b0, input_fire[0] && input_candidate_i[0] &&
         (input_candidate_class_i[
             0*`OPENRV64_FUSION_CANDIDATE_WIDTH +:
             `OPENRV64_FUSION_CANDIDATE_WIDTH] ==
          `OPENRV64_FUSION_CANDIDATE_PCREL_CALL)} +
        {1'b0, input_fire[1] && input_candidate_i[1] &&
         (input_candidate_class_i[
             1*`OPENRV64_FUSION_CANDIDATE_WIDTH +:
             `OPENRV64_FUSION_CANDIDATE_WIDTH] ==
          `OPENRV64_FUSION_CANDIDATE_PCREL_CALL)} +
        {1'b0, input_fire[2] && input_candidate_i[2] &&
         (input_candidate_class_i[
             2*`OPENRV64_FUSION_CANDIDATE_WIDTH +:
             `OPENRV64_FUSION_CANDIDATE_WIDTH] ==
          `OPENRV64_FUSION_CANDIDATE_PCREL_CALL)};
    assign li_candidate_accept_count_o =
        {1'b0, input_fire[0] && input_candidate_i[0] &&
         (input_candidate_class_i[
             0*`OPENRV64_FUSION_CANDIDATE_WIDTH +:
             `OPENRV64_FUSION_CANDIDATE_WIDTH] ==
          `OPENRV64_FUSION_CANDIDATE_LI_BRANCH)} +
        {1'b0, input_fire[1] && input_candidate_i[1] &&
         (input_candidate_class_i[
             1*`OPENRV64_FUSION_CANDIDATE_WIDTH +:
             `OPENRV64_FUSION_CANDIDATE_WIDTH] ==
          `OPENRV64_FUSION_CANDIDATE_LI_BRANCH)} +
        {1'b0, input_fire[2] && input_candidate_i[2] &&
         (input_candidate_class_i[
             2*`OPENRV64_FUSION_CANDIDATE_WIDTH +:
             `OPENRV64_FUSION_CANDIDATE_WIDTH] ==
          `OPENRV64_FUSION_CANDIDATE_LI_BRANCH)};
    assign candidate_pending_o = pending_valid_q;

    function automatic pcrel_call_match;
        input [PAYLOAD_WIDTH-1:0] candidate_payload;
        input [`OPENRV64_FUSION_CANDIDATE_WIDTH-1:0] candidate_class;
        input [PAYLOAD_WIDTH-1:0] successor_payload;
        reg [`RV64_INSTR_WIDTH-1:0] candidate_instr;
        reg [`RV64_INSTR_WIDTH-1:0] successor_instr;
        reg [`RV64_XLEN-1:0] candidate_pc;
        reg [`RV64_XLEN-1:0] successor_pc;
        reg [`RV64_XLEN-1:0] raw_target;
        reg [`RV64_XLEN-1:0] jalr_target;
        begin
            candidate_instr = candidate_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +:
                `RV64_INSTR_WIDTH];
            successor_instr = successor_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +:
                `RV64_INSTR_WIDTH];
            candidate_pc = candidate_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_PC_LSB +: `RV64_XLEN];
            successor_pc = successor_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_PC_LSB +: `RV64_XLEN];
            raw_target = candidate_pc + candidate_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_IMM_LSB +: `RV64_XLEN] +
                successor_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_IMM_LSB +: `RV64_XLEN];
            jalr_target = raw_target & ~64'd1;
            pcrel_call_match =
                (candidate_class ==
                 `OPENRV64_FUSION_CANDIDATE_PCREL_CALL) &&
                `RV64_INSTR_IS_AUIPC(candidate_instr) &&
                `RV64_INSTR_IS_JALR(successor_instr) &&
                (`RV64_RD(candidate_instr) != `RV64_REG_X0) &&
                (`RV64_RS1(successor_instr) ==
                 `RV64_RD(candidate_instr)) &&
                (`RV64_RD(successor_instr) ==
                 `RV64_RD(candidate_instr)) &&
                (successor_pc == (candidate_pc + 64'd4)) &&
                !candidate_payload[8] && !candidate_payload[5] &&
                !candidate_payload[4] &&
                !successor_payload[8] && !successor_payload[5] &&
                !successor_payload[4] &&
                !jalr_target[1];
        end
    endfunction

    function automatic li_branch_rs1_match;
        input [PAYLOAD_WIDTH-1:0] candidate_payload;
        input [PAYLOAD_WIDTH-1:0] successor_payload;
        reg [`RV64_INSTR_WIDTH-1:0] candidate_instr;
        reg [`RV64_INSTR_WIDTH-1:0] successor_instr;
        begin
            candidate_instr = candidate_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +:
                `RV64_INSTR_WIDTH];
            successor_instr = successor_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +:
                `RV64_INSTR_WIDTH];
            li_branch_rs1_match =
                (`RV64_RD(candidate_instr) != `RV64_REG_X0) &&
                (`RV64_RS1(successor_instr) ==
                 `RV64_RD(candidate_instr));
        end
    endfunction

    function automatic li_branch_rs2_match;
        input [PAYLOAD_WIDTH-1:0] candidate_payload;
        input [PAYLOAD_WIDTH-1:0] successor_payload;
        reg [`RV64_INSTR_WIDTH-1:0] candidate_instr;
        reg [`RV64_INSTR_WIDTH-1:0] successor_instr;
        begin
            candidate_instr = candidate_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +:
                `RV64_INSTR_WIDTH];
            successor_instr = successor_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +:
                `RV64_INSTR_WIDTH];
            li_branch_rs2_match =
                (`RV64_RD(candidate_instr) != `RV64_REG_X0) &&
                (`RV64_RS2(successor_instr) ==
                 `RV64_RD(candidate_instr));
        end
    endfunction

    function automatic li_branch_match;
        input [PAYLOAD_WIDTH-1:0] candidate_payload;
        input [`OPENRV64_FUSION_CANDIDATE_WIDTH-1:0] candidate_class;
        input [PAYLOAD_WIDTH-1:0] successor_payload;
        reg [`RV64_INSTR_WIDTH-1:0] candidate_instr;
        reg [`RV64_INSTR_WIDTH-1:0] successor_instr;
        reg [`RV64_XLEN-1:0] candidate_pc;
        reg [`RV64_XLEN-1:0] successor_pc;
        reg [`RV64_XLEN-1:0] branch_target;
        begin
            candidate_instr = candidate_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +:
                `RV64_INSTR_WIDTH];
            successor_instr = successor_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +:
                `RV64_INSTR_WIDTH];
            candidate_pc = candidate_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_PC_LSB +: `RV64_XLEN];
            successor_pc = successor_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_PC_LSB +: `RV64_XLEN];
            branch_target = successor_pc + successor_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_IMM_LSB +: `RV64_XLEN];
            li_branch_match =
                (candidate_class ==
                 `OPENRV64_FUSION_CANDIDATE_LI_BRANCH) &&
                `RV64_INSTR_IS_ADDI(candidate_instr) &&
                (`RV64_RS1(candidate_instr) == `RV64_REG_X0) &&
                (`RV64_RD(candidate_instr) != `RV64_REG_X0) &&
                (`RV64_OPCODE(successor_instr) == `RV64_OPCODE_BRANCH) &&
                successor_payload[
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_BRANCH_BIT] &&
                !successor_payload[
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_JUMP_BIT] &&
                (li_branch_rs1_match(candidate_payload,
                                     successor_payload) ||
                 li_branch_rs2_match(candidate_payload,
                                     successor_payload)) &&
                (successor_pc == (candidate_pc + 64'd4)) &&
                !candidate_payload[
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_ILLEGAL_BIT] &&
                !candidate_payload[
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_ACCESS_FAULT_BIT] &&
                !candidate_payload[
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_PAGE_FAULT_BIT] &&
                !successor_payload[
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_ILLEGAL_BIT] &&
                !successor_payload[
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_ACCESS_FAULT_BIT] &&
                !successor_payload[
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_PAGE_FAULT_BIT] &&
                !(|branch_target[1:0]);
        end
    endfunction

    function automatic [PAYLOAD_WIDTH-1:0] make_pcrel_call;
        input [PAYLOAD_WIDTH-1:0] candidate_payload;
        input [PAYLOAD_WIDTH-1:0] successor_payload;
        reg [`RV64_XLEN-1:0] candidate_pc;
        reg [`RV64_XLEN-1:0] successor_pc;
        reg [`RV64_XLEN-1:0] raw_target;
        reg [`RV64_XLEN-1:0] jalr_target;
        reg [PAYLOAD_WIDTH-1:0] result;
        begin
            candidate_pc = candidate_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_PC_LSB +: `RV64_XLEN];
            successor_pc = successor_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_PC_LSB +: `RV64_XLEN];
            raw_target = candidate_pc + candidate_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_IMM_LSB +: `RV64_XLEN] +
                successor_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_IMM_LSB +: `RV64_XLEN];
            jalr_target = raw_target & ~64'd1;
            result = successor_payload;
            result[`OPENRV64_EXEC_ISSUE_PAYLOAD_FUSED_BIT] = 1'b1;
            result[`OPENRV64_EXEC_ISSUE_PAYLOAD_IMM_LSB +:
                   `RV64_XLEN] = jalr_target - successor_pc;
            result[`OPENRV64_EXEC_ISSUE_PAYLOAD_BR_OP_LSB +:
                   `RV64_BR_OP_WIDTH] = `RV64_BR_OP_JAL;
            make_pcrel_call = result;
        end
    endfunction

    function automatic [PAYLOAD_WIDTH-1:0] make_fused_producer;
        input [PAYLOAD_WIDTH-1:0] candidate_payload;
        reg [PAYLOAD_WIDTH-1:0] result;
        begin
            // Preserve the complete decoded AUIPC/LI operation.  The fused
            // bit only records its relationship to the following macro; it
            // must not suppress the producer's register write or execution.
            result = candidate_payload;
            result[`OPENRV64_EXEC_ISSUE_PAYLOAD_FUSED_BIT] = 1'b1;
            make_fused_producer = result;
        end
    endfunction

    function automatic [PAYLOAD_WIDTH-1:0] make_li_branch;
        input [PAYLOAD_WIDTH-1:0] candidate_payload;
        input [PAYLOAD_WIDTH-1:0] successor_payload;
        reg [`RV64_INSTR_WIDTH-1:0] candidate_instr;
        reg [`RV64_XLEN-1:0] candidate_imm;
        reg [PAYLOAD_WIDTH-1:0] result;
        begin
            candidate_instr = candidate_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +:
                `RV64_INSTR_WIDTH];
            candidate_imm = candidate_payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_IMM_LSB +: `RV64_XLEN];
            result = successor_payload;
            result[`OPENRV64_EXEC_ISSUE_PAYLOAD_FUSED_BIT] = 1'b1;
            result[`OPENRV64_EXEC_ISSUE_PAYLOAD_RD_LSB +:
                   `RV64_REG_ADDR_WIDTH] = `RV64_RD(candidate_instr);
            // The producer now performs LI's architectural write.  rd remains
            // a marker selecting the embedded compare operand, but the fused
            // branch must not perform a duplicate register write.
            result[`OPENRV64_EXEC_ISSUE_PAYLOAD_REG_WRITE_BIT] = 1'b0;
            if (li_branch_rs1_match(candidate_payload, successor_payload))
                result[`OPENRV64_EXEC_ISSUE_PAYLOAD_RS1_DATA_LSB +:
                       `RV64_XLEN] = candidate_imm;
            if (li_branch_rs2_match(candidate_payload, successor_payload))
                result[`OPENRV64_EXEC_ISSUE_PAYLOAD_RS2_DATA_LSB +:
                       `RV64_XLEN] = candidate_imm;
            make_li_branch = result;
        end
    endfunction

    function automatic fused_payload_is_li_branch;
        input [PAYLOAD_WIDTH-1:0] payload;
        reg [`RV64_INSTR_WIDTH-1:0] instruction;
        begin
            instruction = payload[
                `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +:
                `RV64_INSTR_WIDTH];
            fused_payload_is_li_branch =
                payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_FUSED_BIT] &&
                (`RV64_OPCODE(instruction) == `RV64_OPCODE_BRANCH);
        end
    endfunction

    function automatic payload_is_fused_producer;
        input [PAYLOAD_WIDTH-1:0] payload;
        begin
            payload_is_fused_producer =
                payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_FUSED_BIT] &&
                payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_REG_WRITE_BIT] &&
                !payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_MEM_READ_BIT] &&
                !payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_MEM_WRITE_BIT] &&
                !payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_BRANCH_BIT] &&
                !payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_JUMP_BIT] &&
                !payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_SYSTEM_BIT] &&
                !payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_FENCE_BIT] &&
                !payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_ILLEGAL_BIT] &&
                !payload[
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_ACCESS_FAULT_BIT] &&
                !payload[
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_PAGE_FAULT_BIT];
        end
    endfunction

    always @* begin
        input_ready_o = 3'b000;
        output_valid_o = 3'b000;
        output_payload_o = {3*PAYLOAD_WIDTH{1'b0}};
        output_uses_rs1_o = 3'b000;
        output_uses_rs2_o = 3'b000;
        output_fused_o = 3'b000;
        input_output_valid_o = 3'b000;
        input_output_lane_o = 6'd0;
        fused_accept_count_o = 2'd0;
        pcrel_fused_accept_count_o = 2'd0;
        li_fused_accept_count_o = 2'd0;
        accepted_seq_count_r = 0;
        accepted_input_count_r = 0;
        tail_store_r = 1'b0;
        tail_payload_r = {PAYLOAD_WIDTH{1'b0}};
        tail_uses_rs1_r = 1'b0;
        tail_uses_rs2_r = 1'b0;
        tail_candidate_class_r = `OPENRV64_FUSION_CANDIDATE_NONE;

        case (input_valid_i)
            3'b000: input_count_r = 0;
            3'b001: input_count_r = 1;
            3'b011: input_count_r = 2;
            3'b111: input_count_r = 3;
            default: input_count_r = 0;
        endcase
        seq_count_r = input_count_r + (pending_valid_q ? 1 : 0);

        for (seq_index_r = 0; seq_index_r < 4;
             seq_index_r = seq_index_r + 1) begin
            seq_payload_r[seq_index_r] = {PAYLOAD_WIDTH{1'b0}};
            seq_uses_rs1_r[seq_index_r] = 1'b0;
            seq_uses_rs2_r[seq_index_r] = 1'b0;
            seq_candidate_r[seq_index_r] = 1'b0;
            seq_candidate_class_r[seq_index_r] =
                `OPENRV64_FUSION_CANDIDATE_NONE;
            seq_pair_match_r[seq_index_r] = 1'b0;
            seq_is_input_r[seq_index_r] = 1'b0;
            seq_input_lane_r[seq_index_r] = 2'd0;
        end

        if (pending_valid_q) begin
            seq_payload_r[0] = pending_payload_q;
            seq_uses_rs1_r[0] = pending_uses_rs1_q;
            seq_uses_rs2_r[0] = pending_uses_rs2_q;
            seq_candidate_r[0] = 1'b1;
            seq_candidate_class_r[0] = pending_candidate_class_q;
            for (seq_index_r = 0; seq_index_r < 3;
                 seq_index_r = seq_index_r + 1) begin
                seq_payload_r[seq_index_r + 1] = input_payload_i[
                    seq_index_r*PAYLOAD_WIDTH +: PAYLOAD_WIDTH];
                seq_uses_rs1_r[seq_index_r + 1] =
                    input_uses_rs1_i[seq_index_r];
                seq_uses_rs2_r[seq_index_r + 1] =
                    input_uses_rs2_i[seq_index_r];
                seq_candidate_r[seq_index_r + 1] =
                    input_candidate_i[seq_index_r];
                seq_candidate_class_r[seq_index_r + 1] =
                    input_candidate_class_i[
                        seq_index_r*`OPENRV64_FUSION_CANDIDATE_WIDTH +:
                        `OPENRV64_FUSION_CANDIDATE_WIDTH];
                seq_is_input_r[seq_index_r + 1] = 1'b1;
                seq_input_lane_r[seq_index_r + 1] = seq_index_r[1:0];
            end
        end else begin
            for (seq_index_r = 0; seq_index_r < 3;
                 seq_index_r = seq_index_r + 1) begin
                seq_payload_r[seq_index_r] = input_payload_i[
                    seq_index_r*PAYLOAD_WIDTH +: PAYLOAD_WIDTH];
                seq_uses_rs1_r[seq_index_r] =
                    input_uses_rs1_i[seq_index_r];
                seq_uses_rs2_r[seq_index_r] =
                    input_uses_rs2_i[seq_index_r];
                seq_candidate_r[seq_index_r] =
                    input_candidate_i[seq_index_r];
                seq_candidate_class_r[seq_index_r] =
                    input_candidate_class_i[
                        seq_index_r*`OPENRV64_FUSION_CANDIDATE_WIDTH +:
                        `OPENRV64_FUSION_CANDIDATE_WIDTH];
                seq_is_input_r[seq_index_r] = 1'b1;
                seq_input_lane_r[seq_index_r] = seq_index_r[1:0];
            end
        end

        for (seq_index_r = 0; seq_index_r < 3;
             seq_index_r = seq_index_r + 1)
            if ((seq_index_r + 1) < seq_count_r)
                seq_pair_match_r[seq_index_r] =
                    seq_candidate_r[seq_index_r] &&
                    (pcrel_call_match(
                         seq_payload_r[seq_index_r],
                         seq_candidate_class_r[seq_index_r],
                         seq_payload_r[seq_index_r + 1]) ||
                     li_branch_match(
                         seq_payload_r[seq_index_r],
                         seq_candidate_class_r[seq_index_r],
                         seq_payload_r[seq_index_r + 1]));

        parse_index_r = 0;
        for (output_index_r = 0; output_index_r < 3;
             output_index_r = output_index_r + 1) begin
            output_end_r[output_index_r] = parse_index_r[2:0];
            parse_start_r = parse_index_r;
            if (parse_index_r < seq_count_r) begin
                // A candidate without its successor is the only record which
                // enters the boundary buffer.
                if (!(seq_candidate_r[parse_index_r] &&
                      (((parse_index_r + 1) >= seq_count_r) ||
                       ((output_index_r == 2) &&
                        seq_pair_match_r[parse_index_r])))) begin
                    output_valid_o[output_index_r] = 1'b1;
                    // A matching pair emits two records.  Preserve the
                    // candidate as an executing producer, then rewrite its
                    // successor as the executable macro-op.  Advancing one
                    // record per output preserves both PCs and IDs.
                    if ((parse_index_r > 0) &&
                        seq_candidate_r[parse_index_r - 1] &&
                        pcrel_call_match(
                            seq_payload_r[parse_index_r - 1],
                            seq_candidate_class_r[parse_index_r - 1],
                            seq_payload_r[parse_index_r])) begin
                        output_payload_o[
                            output_index_r*PAYLOAD_WIDTH +:
                            PAYLOAD_WIDTH] = make_pcrel_call(
                                seq_payload_r[parse_index_r - 1],
                                seq_payload_r[parse_index_r]);
                        // The direct target is complete; the original JALR
                        // base no longer participates in execution.
                        output_uses_rs1_o[output_index_r] = 1'b0;
                        output_uses_rs2_o[output_index_r] =
                            seq_uses_rs2_r[parse_index_r];
                        output_fused_o[output_index_r] = 1'b1;
                        parse_index_r = parse_index_r + 1;
                    end else if ((parse_index_r > 0) &&
                        seq_candidate_r[parse_index_r - 1] &&
                        li_branch_match(
                            seq_payload_r[parse_index_r - 1],
                            seq_candidate_class_r[parse_index_r - 1],
                            seq_payload_r[parse_index_r])) begin
                        output_payload_o[
                            output_index_r*PAYLOAD_WIDTH +:
                            PAYLOAD_WIDTH] = make_li_branch(
                                seq_payload_r[parse_index_r - 1],
                                seq_payload_r[parse_index_r]);
                        output_uses_rs1_o[output_index_r] =
                            seq_uses_rs1_r[parse_index_r] &&
                            !li_branch_rs1_match(
                                seq_payload_r[parse_index_r - 1],
                                seq_payload_r[parse_index_r]);
                        output_uses_rs2_o[output_index_r] =
                            seq_uses_rs2_r[parse_index_r] &&
                            !li_branch_rs2_match(
                                seq_payload_r[parse_index_r - 1],
                                seq_payload_r[parse_index_r]);
                        output_fused_o[output_index_r] = 1'b1;
                        parse_index_r = parse_index_r + 1;
                    end else if (seq_candidate_r[parse_index_r] &&
                        (pcrel_call_match(
                            seq_payload_r[parse_index_r],
                            seq_candidate_class_r[parse_index_r],
                            seq_payload_r[parse_index_r + 1]) ||
                         li_branch_match(
                            seq_payload_r[parse_index_r],
                            seq_candidate_class_r[parse_index_r],
                            seq_payload_r[parse_index_r + 1]))) begin
                        output_payload_o[
                            output_index_r*PAYLOAD_WIDTH +:
                            PAYLOAD_WIDTH] = make_fused_producer(
                                seq_payload_r[parse_index_r]);
                        output_uses_rs1_o[output_index_r] =
                            seq_uses_rs1_r[parse_index_r];
                        output_uses_rs2_o[output_index_r] =
                            seq_uses_rs2_r[parse_index_r];
                        parse_index_r = parse_index_r + 1;
                    end else begin
                        output_payload_o[
                            output_index_r*PAYLOAD_WIDTH +:
                            PAYLOAD_WIDTH] =
                                seq_payload_r[parse_index_r];
                        output_uses_rs1_o[output_index_r] =
                            seq_uses_rs1_r[parse_index_r];
                        output_uses_rs2_o[output_index_r] =
                            seq_uses_rs2_r[parse_index_r];
                        parse_index_r = parse_index_r + 1;
                    end
                    output_end_r[output_index_r] = parse_index_r[2:0];
                    for (seq_index_r = 0; seq_index_r < 4;
                         seq_index_r = seq_index_r + 1) begin
                        if ((seq_index_r >= parse_start_r) &&
                            (seq_index_r < parse_index_r) &&
                            seq_is_input_r[seq_index_r]) begin
                            input_output_valid_o[
                                seq_input_lane_r[seq_index_r]] = 1'b1;
                            input_output_lane_o[
                                seq_input_lane_r[seq_index_r]*2 +: 2] =
                                output_index_r[1:0];
                        end
                    end
                end
            end
        end

        if (output_valid_o[0] && output_ready_i[0]) begin
            accepted_seq_count_r = output_end_r[0];
            if (output_fused_o[0]) begin
                fused_accept_count_o = fused_accept_count_o + 1'b1;
                if (fused_payload_is_li_branch(
                    output_payload_o[0*PAYLOAD_WIDTH +: PAYLOAD_WIDTH]))
                    li_fused_accept_count_o =
                        li_fused_accept_count_o + 1'b1;
                else
                    pcrel_fused_accept_count_o =
                        pcrel_fused_accept_count_o + 1'b1;
            end
            if (output_valid_o[1] && output_ready_i[1]) begin
                accepted_seq_count_r = output_end_r[1];
                if (output_fused_o[1]) begin
                    fused_accept_count_o = fused_accept_count_o + 1'b1;
                    if (fused_payload_is_li_branch(
                        output_payload_o[1*PAYLOAD_WIDTH +: PAYLOAD_WIDTH]))
                        li_fused_accept_count_o =
                            li_fused_accept_count_o + 1'b1;
                    else
                        pcrel_fused_accept_count_o =
                            pcrel_fused_accept_count_o + 1'b1;
                end
                if (output_valid_o[2] && output_ready_i[2]) begin
                    accepted_seq_count_r = output_end_r[2];
                    if (output_fused_o[2]) begin
                        fused_accept_count_o =
                            fused_accept_count_o + 1'b1;
                        if (fused_payload_is_li_branch(
                            output_payload_o[
                                2*PAYLOAD_WIDTH +: PAYLOAD_WIDTH]))
                            li_fused_accept_count_o =
                                li_fused_accept_count_o + 1'b1;
                        else
                            pcrel_fused_accept_count_o =
                                pcrel_fused_accept_count_o + 1'b1;
                    end
                end
            end
        end

        // If every record before an un-emitted input candidate was accepted,
        // consume it into the one-entry boundary buffer.  This covers both a
        // trailing candidate and a pair which begins in output lane two;
        // the successor remains at the frontend until the buffered candidate
        // can emit alongside its macro on the next cycle.
        if ((parse_index_r < seq_count_r) &&
            seq_candidate_r[parse_index_r] &&
            seq_is_input_r[parse_index_r] &&
            (accepted_seq_count_r == parse_index_r) &&
            (((parse_index_r + 1) >= seq_count_r) ||
             seq_pair_match_r[parse_index_r])) begin
            tail_store_r = 1'b1;
            tail_payload_r = seq_payload_r[parse_index_r];
            tail_uses_rs1_r = seq_uses_rs1_r[parse_index_r];
            tail_uses_rs2_r = seq_uses_rs2_r[parse_index_r];
            tail_candidate_class_r =
                seq_candidate_class_r[parse_index_r];
            accepted_seq_count_r = accepted_seq_count_r + 1;
        end

        accepted_input_count_r = accepted_seq_count_r -
            (pending_valid_q ? 1 : 0);
        if (accepted_input_count_r > 0)
            input_ready_o[0] = 1'b1;
        if (accepted_input_count_r > 1)
            input_ready_o[1] = 1'b1;
        if (accepted_input_count_r > 2)
            input_ready_o[2] = 1'b1;

        // Empty-input readiness avoids making valid depend on ready at the
        // producer.  Once valid is present, the exact output map above
        // determines the accepted prefix.
        if (!input_valid_i[0])
            input_ready_o[0] = output_ready_i[0] || !pending_valid_q;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_valid_q <= 1'b0;
            pending_payload_q <= {PAYLOAD_WIDTH{1'b0}};
            pending_uses_rs1_q <= 1'b0;
            pending_uses_rs2_q <= 1'b0;
            pending_candidate_class_q <=
                `OPENRV64_FUSION_CANDIDATE_NONE;
        end else if (flush_i) begin
            pending_valid_q <= 1'b0;
        end else begin
            if (pending_valid_q && (accepted_seq_count_r > 0)) begin
                pending_valid_q <= 1'b0;
            end
            if (tail_store_r) begin
                pending_valid_q <= 1'b1;
                pending_payload_q <= tail_payload_r;
                pending_uses_rs1_q <= tail_uses_rs1_r;
                pending_uses_rs2_q <= tail_uses_rs2_r;
                pending_candidate_class_q <= tail_candidate_class_r;
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && ((input_valid_i != 3'b000) &&
                      (input_valid_i != 3'b001) &&
                      (input_valid_i != 3'b011) &&
                      (input_valid_i != 3'b111)))
            $fatal(1, "fusion input valid is not a packed prefix: %b",
                   input_valid_i);
        if (rst_n && ((output_ready_i[1] && !output_ready_i[0]) ||
                      (output_ready_i[2] && !output_ready_i[1])))
            $fatal(1, "fusion output ready is not a packed prefix: %b",
                   output_ready_i);
        if (rst_n && output_valid_o[0] && output_ready_i[0] &&
            payload_is_fused_producer(
                output_payload_o[0*PAYLOAD_WIDTH +: PAYLOAD_WIDTH]) &&
            !(output_valid_o[1] && output_ready_i[1] &&
              output_fused_o[1]))
            $fatal(1, "fusion consumer split lane-zero producer/macro pair");
        if (rst_n && output_valid_o[1] && output_ready_i[1] &&
            payload_is_fused_producer(
                output_payload_o[1*PAYLOAD_WIDTH +: PAYLOAD_WIDTH]) &&
            !(output_valid_o[2] && output_ready_i[2] &&
              output_fused_o[2]))
            $fatal(1, "fusion consumer split lane-one producer/macro pair");
        if (rst_n && output_valid_o[2] &&
            payload_is_fused_producer(
                output_payload_o[2*PAYLOAD_WIDTH +: PAYLOAD_WIDTH]))
            $fatal(1, "fusion emitted a producer without an output macro lane");
    end
`endif

endmodule
