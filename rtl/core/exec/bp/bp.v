`include "core/backend/backend-defs.v"
`include "core/exec/bp/defs.v"
`include "core/exec/bp/stall.v"
`include "core/exec/bp/always_branch.v"
`include "core/exec/bp/always_decline.v"
`include "core/exec/bp/repeat_last.v"
`include "core/exec/bp/btfnt.v"
`include "core/exec/bp/bimodal.v"
`include "core/exec/bp/gshare_btb.v"
`include "core/exec/bp/tournament_btb.v"
`include "core/exec/bp/tage_btb.v"
`include "core/exec/bp/debug/stub.v"
`include "core/exec/bp/ras.v"
`timescale 1ns/1ps

// Parameter-selected branch predictor wrapper.  Direction policies live in
// separate files above; this wrapper owns the common unresolved-control stall
// used by the no-speculation policy and by targetless indirect jumps.
module openrv64_exec_bp #(
    parameter [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE = `OPENRV64_BP_DEFAULT,
    parameter integer ENABLE_RAS = 1,
    parameter integer RAS_DEPTH = 8,
    parameter integer BIMODAL_ENTRIES = 32,
    parameter integer BIMODAL_COUNTER_BITS = 3,
    parameter integer BIMODAL_UPDATE_DEPTH = 4,
    parameter integer GSHARE_ENTRIES = 256,
    parameter integer GSHARE_COUNTER_BITS = 3,
    parameter integer TOURNAMENT_GLOBAL_ENTRIES = 2048,
    parameter integer TOURNAMENT_GLOBAL_COUNTER_BITS = 3,
    parameter integer TOURNAMENT_GLOBAL_HISTORY_BITS = 11,
    parameter integer TOURNAMENT_LOCAL_HISTORY_ENTRIES = 512,
    parameter integer TOURNAMENT_LOCAL_HISTORY_BITS = 10,
    parameter integer TOURNAMENT_LOCAL_PHT_ENTRIES = 1024,
    parameter integer TOURNAMENT_LOCAL_COUNTER_BITS = 3,
    parameter integer TOURNAMENT_CHOOSER_ENTRIES = 512,
    parameter integer TOURNAMENT_CHOOSER_COUNTER_BITS = 2,
    parameter integer TAGE_BASE_ENTRIES = 2048,
    parameter integer TAGE_BASE_COUNTER_BITS = 2,
    parameter integer TAGE_TABLE_ENTRIES = 512,
    parameter integer TAGE_TABLE_COUNTER_BITS = 3,
    parameter integer TAGE_USEFUL_BITS = 2,
    parameter integer TAGE_HISTORY_BITS = 96,
    parameter integer TAGE_HISTORY0_BITS = 4,
    parameter integer TAGE_HISTORY1_BITS = 12,
    parameter integer TAGE_HISTORY2_BITS = 32,
    parameter integer TAGE_HISTORY3_BITS = 96,
    parameter integer TAGE_TAG0_BITS = 8,
    parameter integer TAGE_TAG1_BITS = 9,
    parameter integer TAGE_TAG2_BITS = 10,
    parameter integer TAGE_TAG3_BITS = 11,
    parameter integer TAGE_USE_ALT_COUNTER_BITS = 4,
    parameter integer TAGE_AGE_INTERVAL = 32768,
    parameter integer BTB_ENTRIES = 256,
    parameter integer BTB_TAG_BITS = 16,
    parameter integer INFLIGHT_DEPTH = 16,
    parameter integer ENABLE_TAGGED_RESOLUTION = 0
) (
    input  wire clk,
    input  wire rst_n,
    input  wire flush_i,
    input  wire squash_i,
    input  wire recovery_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] recovery_id_i,
    input  wire ras_context_flush_i,

    input  wire lookup_valid_i,
    input  wire lookup_branch_i,
    input  wire lookup_jump_i,
    input  wire lookup_indirect_i,
    input  wire lookup_backward_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] lookup_instr_i,
    input  wire [`RV64_XLEN-1:0]        lookup_pc_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] lookup_id_i,
    input  wire lookup_allocate_i,

    input  wire resolve_valid_i,
    input  wire resolve_branch_i,
    input  wire resolve_taken_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] resolve_instr_i,
    input  wire [`RV64_XLEN-1:0]        resolve_pc_i,
    input  wire [`RV64_XLEN-1:0]        resolve_target_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] resolve_id_i,

    input  wire [2:0]                   train_valid_i,
    input  wire [2:0]                   train_branch_i,
    input  wire [2:0]                   train_taken_i,
    input  wire [3*`RV64_XLEN-1:0]      train_pc_i,

    output wire prediction_taken_o,
    output wire prediction_weak_o,
    output wire prediction_target_valid_o,
    output wire [`RV64_XLEN-1:0] prediction_target_o,
    output wire target_mispredict_o,
    output wire update_overflow_o,
    output wire fetch_stall_o,
    output wire decode_stall_o,
    output wire background_stall_o,
    output wire capacity_stall_o,
    output wire unresolved_target_stall_o,
    output wire inhibit_load_speculation_o
);

    localparam BP_TYPE_VALID =
        (BP_TYPE == `OPENRV64_BP_STALL) ||
        (BP_TYPE == `OPENRV64_BP_ALWAYS_BRANCH) ||
        (BP_TYPE == `OPENRV64_BP_ALWAYS_DECLINE) ||
        (BP_TYPE == `OPENRV64_BP_REPEAT_LAST) ||
        (BP_TYPE == `OPENRV64_BP_BTFNT) ||
        (BP_TYPE == `OPENRV64_BP_BIMODAL) ||
        (BP_TYPE == `OPENRV64_BP_GSHARE_BTB) ||
        (BP_TYPE == `OPENRV64_BP_GSHARE_BTB_512) ||
        (BP_TYPE == `OPENRV64_BP_TOURNAMENT_BTB) ||
        (BP_TYPE == `OPENRV64_BP_TAGE_BTB);

    wire policy_stalls_all = !BP_TYPE_VALID ||
                             (BP_TYPE == `OPENRV64_BP_STALL);
    wire ras_prediction_valid_raw;
    wire [`RV64_XLEN-1:0] ras_prediction_target;
    wire ras_inhibit_load_speculation;
    generate
        if (ENABLE_RAS != 0) begin : g_ras
            openrv64_exec_bp_ras #(.DEPTH(RAS_DEPTH)) u_ras (
                .clk(clk), .rst_n(rst_n),
                .flush_i(ras_context_flush_i),
                .squash_i(flush_i || squash_i || recovery_i),
                .lookup_valid_i(lookup_valid_i),
                .lookup_indirect_i(lookup_indirect_i),
                .lookup_instr_i(lookup_instr_i),
                .lookup_allocate_i(lookup_allocate_i),
                .resolve_valid_i(resolve_valid_i),
                .resolve_instr_i(resolve_instr_i),
                .resolve_pc_i(resolve_pc_i),
                .prediction_valid_o(ras_prediction_valid_raw),
                .prediction_target_o(ras_prediction_target),
                .inhibit_load_speculation_o(
                    ras_inhibit_load_speculation)
            );
        end else begin : g_no_ras
            assign ras_prediction_valid_raw = 1'b0;
            assign ras_prediction_target = {`RV64_XLEN{1'b0}};
            assign ras_inhibit_load_speculation = 1'b0;
        end
    endgenerate
    assign inhibit_load_speculation_o = ras_inhibit_load_speculation;
    wire ras_prediction_valid = !policy_stalls_all &&
                                ras_prediction_valid_raw;
    reg unresolved_q;
    reg ras_outstanding_q;
    reg [`RV64_XLEN-1:0] ras_outstanding_target_q;
    wire policy_prediction_taken;
    wire policy_prediction_weak;
    wire policy_update_overflow;
    wire advanced_prediction_taken;
    wire advanced_prediction_weak;
    wire advanced_prediction_target_valid;
    wire [`RV64_XLEN-1:0] advanced_prediction_target;
    wire advanced_target_mispredict;
    wire advanced_allocation_stall;
    wire advanced_update_overflow;
    wire tournament_prediction_taken;
    wire tournament_prediction_weak;
    wire tournament_prediction_target_valid;
    wire [`RV64_XLEN-1:0] tournament_prediction_target;
    wire tournament_target_mispredict;
    wire tournament_allocation_stall;
    wire tournament_update_overflow;
    wire tage_prediction_taken;
    wire tage_prediction_weak;
    wire tage_prediction_target_valid;
    wire [`RV64_XLEN-1:0] tage_prediction_target;
    wire tage_target_mispredict;
    wire tage_allocation_stall;
    wire tage_capacity_stall;
    wire tage_update_overflow;
    wire [2:0] tage_lookup_provider;
    wire [2:0] tage_lookup_alternate;
    wire tage_lookup_use_alt;
    wire tage_train_valid;
    wire tage_train_mispredict;
    wire [2:0] tage_train_allocation;
    wire tage_train_allocation_failed;

    localparam integer SELECTED_GSHARE_ENTRIES =
        (BP_TYPE == `OPENRV64_BP_GSHARE_BTB_512) ? 512 :
                                                        GSHARE_ENTRIES;
    localparam integer SELECTED_GSHARE_COUNTER_BITS =
        (BP_TYPE == `OPENRV64_BP_GSHARE_BTB_512) ? 3 :
                                                        GSHARE_COUNTER_BITS;
    localparam integer SELECTED_GSHARE_HISTORY_BITS =
        (BP_TYPE == `OPENRV64_BP_GSHARE_BTB_512) ? 9 :
                                  $clog2(SELECTED_GSHARE_ENTRIES);

    generate
        if ((BP_TYPE == `OPENRV64_BP_GSHARE_BTB) ||
            (BP_TYPE == `OPENRV64_BP_GSHARE_BTB_512)) begin : g_advanced
            openrv64_exec_bp_gshare_btb #(
                .PHT_ENTRIES(SELECTED_GSHARE_ENTRIES),
                .COUNTER_BITS(SELECTED_GSHARE_COUNTER_BITS),
                .HISTORY_BITS(SELECTED_GSHARE_HISTORY_BITS),
                .BTB_ENTRIES(BTB_ENTRIES),
                .BTB_TAG_BITS(BTB_TAG_BITS),
                .INFLIGHT_DEPTH(INFLIGHT_DEPTH),
                .ENABLE_TAGGED_RESOLUTION(ENABLE_TAGGED_RESOLUTION)
            ) u_advanced (
                .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
                .squash_i(squash_i),
                .recovery_i(recovery_i),
                .recovery_id_i(recovery_id_i),
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
                .prediction_weak_o(advanced_prediction_weak),
                .prediction_target_valid_o(
                    advanced_prediction_target_valid),
                .prediction_target_o(advanced_prediction_target),
                .target_mispredict_o(advanced_target_mispredict),
                .allocation_stall_o(advanced_allocation_stall),
                .update_overflow_o(advanced_update_overflow)
            );
        end else begin : g_no_advanced
            assign advanced_prediction_taken = 1'b0;
            assign advanced_prediction_weak = 1'b0;
            assign advanced_prediction_target_valid = 1'b0;
            assign advanced_prediction_target = {`RV64_XLEN{1'b0}};
            assign advanced_target_mispredict = 1'b0;
            assign advanced_allocation_stall = 1'b0;
            assign advanced_update_overflow = 1'b0;
        end
    endgenerate

    generate
        if (BP_TYPE == `OPENRV64_BP_TAGE_BTB) begin : g_tage
            openrv64_exec_bp_tage_btb #(
                .BASE_ENTRIES(TAGE_BASE_ENTRIES),
                .BASE_COUNTER_BITS(TAGE_BASE_COUNTER_BITS),
                .TABLE_ENTRIES(TAGE_TABLE_ENTRIES),
                .TABLE_COUNTER_BITS(TAGE_TABLE_COUNTER_BITS),
                .USEFUL_BITS(TAGE_USEFUL_BITS),
                .HISTORY_BITS(TAGE_HISTORY_BITS),
                .HISTORY0_BITS(TAGE_HISTORY0_BITS),
                .HISTORY1_BITS(TAGE_HISTORY1_BITS),
                .HISTORY2_BITS(TAGE_HISTORY2_BITS),
                .HISTORY3_BITS(TAGE_HISTORY3_BITS),
                .TAG0_BITS(TAGE_TAG0_BITS),
                .TAG1_BITS(TAGE_TAG1_BITS),
                .TAG2_BITS(TAGE_TAG2_BITS),
                .TAG3_BITS(TAGE_TAG3_BITS),
                .USE_ALT_COUNTER_BITS(TAGE_USE_ALT_COUNTER_BITS),
                .AGE_INTERVAL(TAGE_AGE_INTERVAL),
                .BTB_ENTRIES(BTB_ENTRIES),
                .BTB_TAG_BITS(BTB_TAG_BITS),
                .INFLIGHT_DEPTH(INFLIGHT_DEPTH),
                .ENABLE_TAGGED_RESOLUTION(ENABLE_TAGGED_RESOLUTION)
            ) u_tage (
                .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
                .squash_i(squash_i),
                .recovery_i(recovery_i),
                .recovery_id_i(recovery_id_i),
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
                .prediction_taken_o(tage_prediction_taken),
                .prediction_weak_o(tage_prediction_weak),
                .prediction_target_valid_o(tage_prediction_target_valid),
                .prediction_target_o(tage_prediction_target),
                .target_mispredict_o(tage_target_mispredict),
                .allocation_stall_o(tage_allocation_stall),
                .capacity_stall_o(tage_capacity_stall),
                .update_overflow_o(tage_update_overflow),
                .diag_lookup_provider_o(tage_lookup_provider),
                .diag_lookup_alternate_o(tage_lookup_alternate),
                .diag_lookup_use_alt_o(tage_lookup_use_alt),
                .diag_train_valid_o(tage_train_valid),
                .diag_train_mispredict_o(tage_train_mispredict),
                .diag_train_allocation_o(tage_train_allocation),
                .diag_train_allocation_failed_o(
                    tage_train_allocation_failed)
            );
        end else begin : g_no_tage
            assign tage_prediction_taken = 1'b0;
            assign tage_prediction_weak = 1'b0;
            assign tage_prediction_target_valid = 1'b0;
            assign tage_prediction_target = {`RV64_XLEN{1'b0}};
            assign tage_target_mispredict = 1'b0;
            assign tage_allocation_stall = 1'b0;
            assign tage_capacity_stall = 1'b0;
            assign tage_update_overflow = 1'b0;
            assign tage_lookup_provider = 3'd0;
            assign tage_lookup_alternate = 3'd0;
            assign tage_lookup_use_alt = 1'b0;
            assign tage_train_valid = 1'b0;
            assign tage_train_mispredict = 1'b0;
            assign tage_train_allocation = 3'd0;
            assign tage_train_allocation_failed = 1'b0;
        end
    endgenerate

    generate
        if (BP_TYPE == `OPENRV64_BP_TOURNAMENT_BTB) begin : g_tournament
            openrv64_exec_bp_tournament_btb #(
                .GLOBAL_PHT_ENTRIES(TOURNAMENT_GLOBAL_ENTRIES),
                .GLOBAL_COUNTER_BITS(TOURNAMENT_GLOBAL_COUNTER_BITS),
                .GLOBAL_HISTORY_BITS(TOURNAMENT_GLOBAL_HISTORY_BITS),
                .LOCAL_HISTORY_ENTRIES(
                    TOURNAMENT_LOCAL_HISTORY_ENTRIES),
                .LOCAL_HISTORY_BITS(TOURNAMENT_LOCAL_HISTORY_BITS),
                .LOCAL_PHT_ENTRIES(TOURNAMENT_LOCAL_PHT_ENTRIES),
                .LOCAL_COUNTER_BITS(TOURNAMENT_LOCAL_COUNTER_BITS),
                .CHOOSER_ENTRIES(TOURNAMENT_CHOOSER_ENTRIES),
                .CHOOSER_COUNTER_BITS(
                    TOURNAMENT_CHOOSER_COUNTER_BITS),
                .BTB_ENTRIES(BTB_ENTRIES),
                .BTB_TAG_BITS(BTB_TAG_BITS),
                .INFLIGHT_DEPTH(INFLIGHT_DEPTH),
                .ENABLE_TAGGED_RESOLUTION(ENABLE_TAGGED_RESOLUTION)
            ) u_tournament (
                .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
                .squash_i(squash_i),
                .recovery_i(recovery_i),
                .recovery_id_i(recovery_id_i),
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
                .prediction_taken_o(tournament_prediction_taken),
                .prediction_weak_o(tournament_prediction_weak),
                .prediction_target_valid_o(
                    tournament_prediction_target_valid),
                .prediction_target_o(tournament_prediction_target),
                .target_mispredict_o(tournament_target_mispredict),
                .allocation_stall_o(tournament_allocation_stall),
                .update_overflow_o(tournament_update_overflow)
            );
        end else begin : g_no_tournament
            assign tournament_prediction_taken = 1'b0;
            assign tournament_prediction_weak = 1'b0;
            assign tournament_prediction_target_valid = 1'b0;
            assign tournament_prediction_target = {`RV64_XLEN{1'b0}};
            assign tournament_target_mispredict = 1'b0;
            assign tournament_allocation_stall = 1'b0;
            assign tournament_update_overflow = 1'b0;
        end
    endgenerate

    generate
        if (BP_TYPE == `OPENRV64_BP_ALWAYS_BRANCH) begin : g_always_branch
            assign policy_update_overflow = 1'b0;
            assign policy_prediction_weak = 1'b1;
            openrv64_exec_bp_always_branch u_policy (
                .lookup_branch_i(lookup_branch_i),
                .lookup_jump_i(lookup_jump_i),
                .lookup_indirect_i(lookup_indirect_i),
                .prediction_taken_o(policy_prediction_taken)
            );
        end else if (BP_TYPE == `OPENRV64_BP_ALWAYS_DECLINE) begin : g_always_decline
            assign policy_update_overflow = 1'b0;
            assign policy_prediction_weak = 1'b1;
            openrv64_exec_bp_always_decline u_policy (
                .lookup_jump_i(lookup_jump_i),
                .lookup_indirect_i(lookup_indirect_i),
                .prediction_taken_o(policy_prediction_taken)
            );
        end else if (BP_TYPE == `OPENRV64_BP_REPEAT_LAST) begin : g_repeat_last
            assign policy_update_overflow = 1'b0;
            assign policy_prediction_weak = 1'b1;
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
            assign policy_prediction_weak = 1'b1;
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
                .prediction_weak_o(policy_prediction_weak),
                .update_overflow_o(policy_update_overflow)
            );
        end else begin : g_stall
            assign policy_update_overflow = 1'b0;
            assign policy_prediction_weak = 1'b0;
            openrv64_exec_bp_stall u_policy (
                .prediction_taken_o(policy_prediction_taken)
            );
        end
    endgenerate

    wire use_advanced =
        (BP_TYPE == `OPENRV64_BP_GSHARE_BTB) ||
        (BP_TYPE == `OPENRV64_BP_GSHARE_BTB_512);
    wire use_tournament = BP_TYPE == `OPENRV64_BP_TOURNAMENT_BTB;
    wire use_tage = BP_TYPE == `OPENRV64_BP_TAGE_BTB;
    wire use_table_predictor = use_advanced || use_tournament || use_tage;
    wire selected_target_valid = use_advanced ?
        advanced_prediction_target_valid :
        (use_tournament ? tournament_prediction_target_valid :
         (use_tage ? tage_prediction_target_valid :
                     ras_prediction_valid));
    wire selected_allocation_stall = use_advanced ?
        advanced_allocation_stall :
        (use_tournament ? tournament_allocation_stall :
         (use_tage ? tage_allocation_stall : 1'b0));
    wire effective_lookup_requires_stall = lookup_valid_i &&
        (policy_stalls_all ||
         (lookup_indirect_i && !selected_target_valid));
    assign prediction_taken_o = use_advanced ? advanced_prediction_taken :
        (use_tournament ? tournament_prediction_taken :
         (use_tage ? tage_prediction_taken :
          (lookup_valid_i &&
           (ras_prediction_valid ||
            (!lookup_indirect_i && policy_prediction_taken)))));
    assign prediction_weak_o = lookup_valid_i && lookup_branch_i &&
        (use_advanced ? advanced_prediction_weak :
         (use_tournament ? tournament_prediction_weak :
          (use_tage ? tage_prediction_weak : policy_prediction_weak)));
    assign prediction_target_valid_o = use_advanced ?
        advanced_prediction_target_valid :
        (use_tournament ? tournament_prediction_target_valid :
         (use_tage ? tage_prediction_target_valid :
                     (lookup_valid_i && ras_prediction_valid)));
    assign prediction_target_o = use_advanced ?
        advanced_prediction_target :
        (use_tournament ? tournament_prediction_target :
         (use_tage ? tage_prediction_target : ras_prediction_target));
    assign update_overflow_o = use_advanced ? advanced_update_overflow :
        (use_tournament ? tournament_update_overflow :
         (use_tage ? tage_update_overflow : policy_update_overflow));
    assign target_mispredict_o = use_advanced ? advanced_target_mispredict :
        (use_tournament ? tournament_target_mispredict :
         (use_tage ? tage_target_mispredict :
          (resolve_valid_i && ras_outstanding_q && resolve_taken_i &&
           (resolve_target_i != ras_outstanding_target_q))));
    assign fetch_stall_o = effective_lookup_requires_stall || unresolved_q ||
                           selected_allocation_stall;
    assign decode_stall_o = unresolved_q || selected_allocation_stall;
    // Unlike the synchronous lookup-response wait, these conditions remain
    // architectural backpressure when a caller prelaunches a lookup into an
    // elastic dispatch register.
    assign capacity_stall_o = use_tage ? tage_capacity_stall :
                                        selected_allocation_stall;
    assign unresolved_target_stall_o = unresolved_q;
    assign background_stall_o = unresolved_target_stall_o ||
                                capacity_stall_o;

    // Simulation-visible target-predictor events.  These deliberately remain
    // internal wires rather than architectural counters or public RTL ports.
    // A lookup is counted only when the frontend accepts the control record,
    // so a stalled indirect does not count repeatedly.
    wire diag_lookup_is_jalr =
        `RV64_OPCODE(lookup_instr_i) == `RV64_OPCODE_JALR;
    wire diag_lookup_rs1_link =
        (`RV64_RS1(lookup_instr_i) == 5'd1) ||
        (`RV64_RS1(lookup_instr_i) == 5'd5);
    wire diag_lookup_rd_link =
        (`RV64_RD(lookup_instr_i) == 5'd1) ||
        (`RV64_RD(lookup_instr_i) == 5'd5);
    wire diag_lookup_return = lookup_indirect_i &&
        diag_lookup_is_jalr && diag_lookup_rs1_link &&
        !diag_lookup_rd_link;
    wire diag_resolve_is_jalr =
        `RV64_OPCODE(resolve_instr_i) == `RV64_OPCODE_JALR;
    wire diag_resolve_rs1_link =
        (`RV64_RS1(resolve_instr_i) == 5'd1) ||
        (`RV64_RS1(resolve_instr_i) == 5'd5);
    wire diag_resolve_rd_link =
        (`RV64_RD(resolve_instr_i) == 5'd1) ||
        (`RV64_RD(resolve_instr_i) == 5'd5);
    wire diag_resolve_return = diag_resolve_is_jalr &&
        diag_resolve_rs1_link && !diag_resolve_rd_link;
    wire diag_btb_lookup = use_table_predictor &&
        lookup_allocate_i && lookup_indirect_i && !diag_lookup_return;
    wire diag_btb_hit = diag_btb_lookup && selected_target_valid;
    wire diag_btb_miss = diag_btb_lookup && !selected_target_valid;
    wire diag_ras_lookup = (ENABLE_RAS != 0) &&
        lookup_allocate_i && diag_lookup_return;
    wire diag_ras_hit = diag_ras_lookup && ras_prediction_valid;
    wire diag_ras_miss = diag_ras_lookup && !ras_prediction_valid;
    wire diag_btb_wrong_target = target_mispredict_o &&
        diag_resolve_is_jalr && !diag_resolve_return;
    wire diag_ras_wrong_target = target_mispredict_o &&
        diag_resolve_return;
    wire diag_tage_lookup = use_tage && lookup_allocate_i &&
                            lookup_branch_i;
    wire diag_tage_use_alt = use_tage && tage_lookup_use_alt;
    wire diag_tage_train = use_tage && tage_train_valid;
    wire diag_tage_train_mispredict = use_tage && tage_train_mispredict;
    wire [2:0] diag_tage_provider = tage_lookup_provider;
    wire [2:0] diag_tage_alternate = tage_lookup_alternate;
    wire [2:0] diag_tage_allocation = tage_train_allocation;
    wire diag_tage_allocation_failed = use_tage &&
                                       tage_train_allocation_failed;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            unresolved_q <= 1'b0;
            ras_outstanding_q <= 1'b0;
            ras_outstanding_target_q <= {`RV64_XLEN{1'b0}};
        end else if (flush_i || squash_i || recovery_i) begin
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
            if (!use_table_predictor &&
                lookup_allocate_i && ras_prediction_valid) begin
                ras_outstanding_q <= 1'b1;
                ras_outstanding_target_q <= ras_prediction_target;
            end
        end
    end

endmodule
