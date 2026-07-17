`include "core/exec/bp/defs.v"
`include "core/exec/bp/stall.v"
`include "core/exec/bp/always_branch.v"
`include "core/exec/bp/always_decline.v"
`include "core/exec/bp/repeat_last.v"
`timescale 1ns/1ps

// Parameter-selected branch predictor wrapper.  Direction policies live in
// separate files above; this wrapper owns the common unresolved-control stall
// used by the no-speculation policy and by targetless indirect jumps.
module openrv64_exec_bp #(
    parameter [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE = `OPENRV64_BP_STALL
) (
    input  wire clk,
    input  wire rst_n,
    input  wire flush_i,

    input  wire lookup_valid_i,
    input  wire lookup_branch_i,
    input  wire lookup_jump_i,
    input  wire lookup_indirect_i,
    input  wire lookup_allocate_i,

    input  wire resolve_valid_i,
    input  wire resolve_branch_i,
    input  wire resolve_taken_i,

    output wire prediction_taken_o,
    output wire fetch_stall_o,
    output wire decode_stall_o
);

    localparam BP_TYPE_VALID =
        (BP_TYPE == `OPENRV64_BP_STALL) ||
        (BP_TYPE == `OPENRV64_BP_ALWAYS_BRANCH) ||
        (BP_TYPE == `OPENRV64_BP_ALWAYS_DECLINE) ||
        (BP_TYPE == `OPENRV64_BP_REPEAT_LAST);

    wire policy_stalls_all = !BP_TYPE_VALID ||
                             (BP_TYPE == `OPENRV64_BP_STALL);
    wire lookup_requires_stall = lookup_valid_i &&
                                 (policy_stalls_all || lookup_indirect_i);
    wire allocate_requires_stall = lookup_allocate_i &&
                                   lookup_requires_stall;
    reg unresolved_q;
    wire policy_prediction_taken;

    generate
        if (BP_TYPE == `OPENRV64_BP_ALWAYS_BRANCH) begin : g_always_branch
            openrv64_exec_bp_always_branch u_policy (
                .lookup_branch_i(lookup_branch_i),
                .lookup_jump_i(lookup_jump_i),
                .lookup_indirect_i(lookup_indirect_i),
                .prediction_taken_o(policy_prediction_taken)
            );
        end else if (BP_TYPE == `OPENRV64_BP_ALWAYS_DECLINE) begin : g_always_decline
            openrv64_exec_bp_always_decline u_policy (
                .lookup_jump_i(lookup_jump_i),
                .lookup_indirect_i(lookup_indirect_i),
                .prediction_taken_o(policy_prediction_taken)
            );
        end else if (BP_TYPE == `OPENRV64_BP_REPEAT_LAST) begin : g_repeat_last
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
        end else begin : g_stall
            openrv64_exec_bp_stall u_policy (
                .prediction_taken_o(policy_prediction_taken)
            );
        end
    endgenerate

    assign prediction_taken_o = lookup_valid_i &&
                                !lookup_indirect_i &&
                                policy_prediction_taken;
    assign fetch_stall_o = lookup_requires_stall || unresolved_q;
    assign decode_stall_o = unresolved_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            unresolved_q <= 1'b0;
        end else if (flush_i) begin
            unresolved_q <= 1'b0;
        end else if (resolve_valid_i) begin
            // Allocation and resolution can coincide with a bypassed ID/EX.
            unresolved_q <= 1'b0;
        end else if (allocate_requires_stall) begin
            unresolved_q <= 1'b1;
        end
    end

endmodule
