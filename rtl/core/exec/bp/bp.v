`include "core/exec/bp/defs.v"
`include "core/exec/bp/stall.v"
`include "core/exec/bp/always_branch.v"
`include "core/exec/bp/always_decline.v"
`include "core/exec/bp/repeat_last.v"
`include "core/exec/bp/btfnt.v"
`include "core/exec/bp/bimodal.v"
`include "core/exec/bp/gshare_btb.v"
`include "core/exec/bp/ras.v"
`timescale 1ns/1ps

// Parameter-selected branch predictor wrapper.  Direction policies live in
// separate files above; this wrapper owns the common unresolved-control stall
// used by the no-speculation policy and by targetless indirect jumps.
module openrv64_exec_bp #(
    parameter [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE = `OPENRV64_BP_STALL,
    parameter integer ENABLE_RAS = 1,
    parameter integer RAS_DEPTH = 8,
    parameter integer BIMODAL_ENTRIES = 32,
    parameter integer BIMODAL_COUNTER_BITS = 3,
    parameter integer BIMODAL_UPDATE_DEPTH = 4,
    parameter integer GSHARE_ENTRIES = 256,
    parameter integer GSHARE_COUNTER_BITS = 3,
    parameter integer BTB_ENTRIES = 256,
    parameter integer BTB_TAG_BITS = 16,
    parameter integer INFLIGHT_DEPTH = 16,
    parameter integer ENABLE_TAGGED_RESOLUTION = 0
) (
    input  wire clk,
    input  wire rst_n,
    input  wire flush_i,
    input  wire squash_i,

    input  wire lookup_valid_i,
    input  wire lookup_branch_i,
    input  wire lookup_jump_i,
    input  wire lookup_indirect_i,
    input  wire lookup_backward_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] lookup_instr_i,
    input  wire [`RV64_XLEN-1:0]        lookup_pc_i,
    input  wire [63:0]                  lookup_id_i,
    input  wire lookup_allocate_i,

    input  wire resolve_valid_i,
    input  wire resolve_branch_i,
    input  wire resolve_taken_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] resolve_instr_i,
    input  wire [`RV64_XLEN-1:0]        resolve_pc_i,
    input  wire [`RV64_XLEN-1:0]        resolve_target_i,
    input  wire [63:0]                  resolve_id_i,

    input  wire [2:0]                   train_valid_i,
    input  wire [2:0]                   train_branch_i,
    input  wire [2:0]                   train_taken_i,
    input  wire [3*`RV64_XLEN-1:0]      train_pc_i,

    output wire prediction_taken_o,
    output wire prediction_target_valid_o,
    output wire [`RV64_XLEN-1:0] prediction_target_o,
    output wire target_mispredict_o,
    output wire update_overflow_o,
    output wire fetch_stall_o,
    output wire decode_stall_o
);

    localparam BP_TYPE_VALID =
        (BP_TYPE == `OPENRV64_BP_STALL) ||
        (BP_TYPE == `OPENRV64_BP_ALWAYS_BRANCH) ||
        (BP_TYPE == `OPENRV64_BP_ALWAYS_DECLINE) ||
        (BP_TYPE == `OPENRV64_BP_REPEAT_LAST) ||
        (BP_TYPE == `OPENRV64_BP_BTFNT) ||
        (BP_TYPE == `OPENRV64_BP_BIMODAL) ||
        (BP_TYPE == `OPENRV64_BP_GSHARE_BTB);

    wire policy_stalls_all = !BP_TYPE_VALID ||
                             (BP_TYPE == `OPENRV64_BP_STALL);
    wire ras_prediction_valid_raw;
    wire [`RV64_XLEN-1:0] ras_prediction_target;
    generate
        if (ENABLE_RAS != 0) begin : g_ras
            openrv64_exec_bp_ras #(.DEPTH(RAS_DEPTH)) u_ras (
                .clk(clk), .rst_n(rst_n), .flush_i(flush_i || squash_i),
                .lookup_valid_i(lookup_valid_i),
                .lookup_indirect_i(lookup_indirect_i),
                .lookup_instr_i(lookup_instr_i),
                .lookup_allocate_i(lookup_allocate_i),
                .resolve_valid_i(resolve_valid_i),
                .resolve_instr_i(resolve_instr_i),
                .resolve_pc_i(resolve_pc_i),
                .prediction_valid_o(ras_prediction_valid_raw),
                .prediction_target_o(ras_prediction_target)
            );
        end else begin : g_no_ras
            assign ras_prediction_valid_raw = 1'b0;
            assign ras_prediction_target = {`RV64_XLEN{1'b0}};
        end
    endgenerate
    wire ras_prediction_valid = !policy_stalls_all &&
                                ras_prediction_valid_raw;
    reg unresolved_q;
    reg ras_outstanding_q;
    reg [`RV64_XLEN-1:0] ras_outstanding_target_q;
    wire policy_prediction_taken;
    wire policy_update_overflow;
    wire advanced_prediction_taken;
    wire advanced_prediction_target_valid;
    wire [`RV64_XLEN-1:0] advanced_prediction_target;
    wire advanced_target_mispredict;
    wire advanced_allocation_stall;
    wire advanced_update_overflow;

    generate
        if (BP_TYPE == `OPENRV64_BP_GSHARE_BTB) begin : g_advanced
            openrv64_exec_bp_gshare_btb #(
                .PHT_ENTRIES(GSHARE_ENTRIES),
                .COUNTER_BITS(GSHARE_COUNTER_BITS),
                .BTB_ENTRIES(BTB_ENTRIES),
                .BTB_TAG_BITS(BTB_TAG_BITS),
                .INFLIGHT_DEPTH(INFLIGHT_DEPTH),
                .ENABLE_TAGGED_RESOLUTION(ENABLE_TAGGED_RESOLUTION)
            ) u_advanced (
                .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
                .squash_i(squash_i),
                .lookup_valid_i(lookup_valid_i),
                .lookup_branch_i(lookup_branch_i),
                .lookup_jump_i(lookup_jump_i),
                .lookup_indirect_i(lookup_indirect_i),
                .lookup_backward_i(lookup_backward_i),
                .lookup_instr_i(lookup_instr_i),
                .lookup_pc_i(lookup_pc_i),
                .lookup_id_i(lookup_id_i),
                .lookup_allocate_i(lookup_allocate_i),
                .ras_prediction_valid_i(ras_prediction_valid),
                .ras_prediction_target_i(ras_prediction_target),
                .resolve_valid_i(resolve_valid_i),
                .resolve_branch_i(resolve_branch_i),
                .resolve_taken_i(resolve_taken_i),
                .resolve_instr_i(resolve_instr_i),
                .resolve_pc_i(resolve_pc_i),
                .resolve_target_i(resolve_target_i),
                .resolve_id_i(resolve_id_i),
                .prediction_taken_o(advanced_prediction_taken),
                .prediction_target_valid_o(
                    advanced_prediction_target_valid),
                .prediction_target_o(advanced_prediction_target),
                .target_mispredict_o(advanced_target_mispredict),
                .allocation_stall_o(advanced_allocation_stall),
                .update_overflow_o(advanced_update_overflow)
            );
        end else begin : g_no_advanced
            assign advanced_prediction_taken = 1'b0;
            assign advanced_prediction_target_valid = 1'b0;
            assign advanced_prediction_target = {`RV64_XLEN{1'b0}};
            assign advanced_target_mispredict = 1'b0;
            assign advanced_allocation_stall = 1'b0;
            assign advanced_update_overflow = 1'b0;
        end
    endgenerate

    generate
        if (BP_TYPE == `OPENRV64_BP_ALWAYS_BRANCH) begin : g_always_branch
            assign policy_update_overflow = 1'b0;
            openrv64_exec_bp_always_branch u_policy (
                .lookup_branch_i(lookup_branch_i),
                .lookup_jump_i(lookup_jump_i),
                .lookup_indirect_i(lookup_indirect_i),
                .prediction_taken_o(policy_prediction_taken)
            );
        end else if (BP_TYPE == `OPENRV64_BP_ALWAYS_DECLINE) begin : g_always_decline
            assign policy_update_overflow = 1'b0;
            openrv64_exec_bp_always_decline u_policy (
                .lookup_jump_i(lookup_jump_i),
                .lookup_indirect_i(lookup_indirect_i),
                .prediction_taken_o(policy_prediction_taken)
            );
        end else if (BP_TYPE == `OPENRV64_BP_REPEAT_LAST) begin : g_repeat_last
            assign policy_update_overflow = 1'b0;
            openrv64_exec_bp_repeat_last u_policy (
                .clk(clk),
                .rst_n(rst_n),
                .lookup_branch_i(lookup_branch_i),
                .lookup_jump_i(lookup_jump_i),
                .lookup_indirect_i(lookup_indirect_i),
                .resolve_valid_i(resolve_valid_i),
                .resolve_branch_i(resolve_branch_i),
                .resolve_taken_i(resolve_taken_i),
                .prediction_taken_o(policy_prediction_taken)
            );
        end else if (BP_TYPE == `OPENRV64_BP_BTFNT) begin : g_btfnt
            assign policy_update_overflow = 1'b0;
            openrv64_exec_bp_btfnt u_policy (
                .lookup_branch_i(lookup_branch_i),
                .lookup_jump_i(lookup_jump_i),
                .lookup_indirect_i(lookup_indirect_i),
                .lookup_backward_i(lookup_backward_i),
                .prediction_taken_o(policy_prediction_taken)
            );
        end else if (BP_TYPE == `OPENRV64_BP_BIMODAL) begin : g_bimodal
            openrv64_exec_bp_bimodal #(
                .ENTRIES(BIMODAL_ENTRIES),
                .COUNTER_BITS(BIMODAL_COUNTER_BITS),
                .UPDATE_DEPTH(BIMODAL_UPDATE_DEPTH)
            ) u_policy (
                .clk(clk), .rst_n(rst_n),
                .lookup_branch_i(lookup_branch_i),
                .lookup_jump_i(lookup_jump_i),
                .lookup_indirect_i(lookup_indirect_i),
                .lookup_backward_i(lookup_backward_i),
                .lookup_pc_i(lookup_pc_i),
                .train_valid_i(train_valid_i),
                .train_branch_i(train_branch_i),
                .train_taken_i(train_taken_i),
                .train_pc_i(train_pc_i),
                .prediction_taken_o(policy_prediction_taken),
                .update_overflow_o(policy_update_overflow)
            );
        end else begin : g_stall
            assign policy_update_overflow = 1'b0;
            openrv64_exec_bp_stall u_policy (
                .prediction_taken_o(policy_prediction_taken)
            );
        end
    endgenerate

    wire use_advanced = BP_TYPE == `OPENRV64_BP_GSHARE_BTB;
    wire selected_target_valid = use_advanced ?
        advanced_prediction_target_valid : ras_prediction_valid;
    wire effective_lookup_requires_stall = lookup_valid_i &&
        (policy_stalls_all ||
         (lookup_indirect_i && !selected_target_valid));
    assign prediction_taken_o = use_advanced ? advanced_prediction_taken :
        (lookup_valid_i &&
         (ras_prediction_valid ||
          (!lookup_indirect_i && policy_prediction_taken)));
    assign prediction_target_valid_o = use_advanced ?
        advanced_prediction_target_valid :
        (lookup_valid_i && ras_prediction_valid);
    assign prediction_target_o = use_advanced ?
        advanced_prediction_target : ras_prediction_target;
    assign update_overflow_o = use_advanced ? advanced_update_overflow :
                               policy_update_overflow;
    assign target_mispredict_o = use_advanced ? advanced_target_mispredict :
        (resolve_valid_i && ras_outstanding_q && resolve_taken_i &&
         (resolve_target_i != ras_outstanding_target_q));
    assign fetch_stall_o = effective_lookup_requires_stall || unresolved_q ||
                           advanced_allocation_stall;
    assign decode_stall_o = unresolved_q || advanced_allocation_stall;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            unresolved_q <= 1'b0;
            ras_outstanding_q <= 1'b0;
            ras_outstanding_target_q <= {`RV64_XLEN{1'b0}};
        end else if (flush_i || squash_i) begin
            unresolved_q <= 1'b0;
            ras_outstanding_q <= 1'b0;
        end else begin
            if (resolve_valid_i) begin
                // Allocation and resolution can coincide with a bypassed
                // ID/EX; a new accepted lookup below wins ownership.
                unresolved_q <= 1'b0;
                ras_outstanding_q <= 1'b0;
            end
            if (lookup_allocate_i && effective_lookup_requires_stall)
                unresolved_q <= 1'b1;
            if (!use_advanced && lookup_allocate_i && ras_prediction_valid) begin
                ras_outstanding_q <= 1'b1;
                ras_outstanding_target_q <= ras_prediction_target;
            end
        end
    end

endmodule
