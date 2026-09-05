`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/exec/bp/defs.v"

module tb_exec_bp;

    logic clk;
    logic rst_n;
    logic flush;
    logic ras_context_flush;
    logic lookup_valid;
    logic lookup_branch;
    logic lookup_jump;
    logic lookup_indirect;
    logic lookup_backward;
    logic [31:0] lookup_instr;
    logic [63:0] lookup_pc;
    logic lookup_allocate;
    logic resolve_valid;
    logic resolve_branch;
    logic resolve_taken;
    logic [31:0] resolve_instr;
    logic [63:0] resolve_pc;
    logic [63:0] resolve_target;
    logic [2:0] train_valid;
    logic [2:0] train_branch;
    logic [2:0] train_taken;
    logic [191:0] train_pc;

    logic stall_prediction;
    logic stall_weak;
    logic stall_fetch;
    logic stall_decode;
    logic always_branch_prediction;
    logic always_branch_weak;
    logic always_branch_fetch;
    logic always_branch_decode;
    logic always_decline_prediction;
    logic always_decline_weak;
    logic always_decline_fetch;
    logic always_decline_decode;
    logic repeat_last_prediction;
    logic repeat_last_weak;
    logic repeat_last_fetch;
    logic repeat_last_decode;
    logic btfnt_prediction;
    logic btfnt_weak;
    logic btfnt_fetch;
    logic btfnt_decode;
    logic btfnt_target_valid;
    logic [63:0] btfnt_target;
    logic btfnt_target_mispredict;
    logic no_ras_prediction;
    logic no_ras_fetch;
    logic no_ras_decode;
    logic no_ras_target_valid;
    logic ras4_prediction;
    logic ras4_fetch;
    logic ras4_decode;
    logic ras4_target_valid;
    logic [63:0] ras4_target;
    logic ras4_load_inhibit;
    logic bimodal_prediction;
    logic bimodal_weak;
    logic bimodal_fetch;
    logic bimodal_decode;

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_STALL)
    ) u_stall (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .squash_i(1'b0),
        .recovery_i(1'b0), .recovery_id_i(10'd0),
        .ras_context_flush_i(ras_context_flush),
        .lookup_valid_i(lookup_valid),
        .lookup_branch_i(lookup_branch),
        .lookup_jump_i(lookup_jump),
        .lookup_indirect_i(lookup_indirect),
        .lookup_backward_i(lookup_backward),
        .lookup_instr_i(lookup_instr),
        .lookup_pc_i(lookup_pc),
        .lookup_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .lookup_observational_i(1'b0),
        .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid),
        .resolve_branch_i(resolve_branch),
        .resolve_taken_i(resolve_taken),
        .resolve_instr_i(resolve_instr),
        .resolve_pc_i(resolve_pc),
        .resolve_target_i(resolve_target),
        .resolve_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .train_valid_i(train_valid), .train_branch_i(train_branch),
        .train_taken_i(train_taken), .train_pc_i(train_pc),
        .prediction_taken_o(stall_prediction),
        .prediction_weak_o(stall_weak),
        .fetch_stall_o(stall_fetch),
        .decode_stall_o(stall_decode)
    );

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_ALWAYS_BRANCH)
    ) u_always_branch (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .squash_i(1'b0),
        .recovery_i(1'b0), .recovery_id_i(10'd0),
        .ras_context_flush_i(ras_context_flush),
        .lookup_valid_i(lookup_valid),
        .lookup_branch_i(lookup_branch),
        .lookup_jump_i(lookup_jump),
        .lookup_indirect_i(lookup_indirect),
        .lookup_backward_i(lookup_backward),
        .lookup_instr_i(lookup_instr),
        .lookup_pc_i(lookup_pc),
        .lookup_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .lookup_observational_i(1'b0),
        .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid),
        .resolve_branch_i(resolve_branch),
        .resolve_taken_i(resolve_taken),
        .resolve_instr_i(resolve_instr),
        .resolve_pc_i(resolve_pc),
        .resolve_target_i(resolve_target),
        .resolve_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .train_valid_i(train_valid), .train_branch_i(train_branch),
        .train_taken_i(train_taken), .train_pc_i(train_pc),
        .prediction_taken_o(always_branch_prediction),
        .prediction_weak_o(always_branch_weak),
        .fetch_stall_o(always_branch_fetch),
        .decode_stall_o(always_branch_decode)
    );

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_ALWAYS_DECLINE)
    ) u_always_decline (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .squash_i(1'b0),
        .recovery_i(1'b0), .recovery_id_i(10'd0),
        .ras_context_flush_i(ras_context_flush),
        .lookup_valid_i(lookup_valid),
        .lookup_branch_i(lookup_branch),
        .lookup_jump_i(lookup_jump),
        .lookup_indirect_i(lookup_indirect),
        .lookup_backward_i(lookup_backward),
        .lookup_instr_i(lookup_instr),
        .lookup_pc_i(lookup_pc),
        .lookup_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .lookup_observational_i(1'b0),
        .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid),
        .resolve_branch_i(resolve_branch),
        .resolve_taken_i(resolve_taken),
        .resolve_instr_i(resolve_instr),
        .resolve_pc_i(resolve_pc),
        .resolve_target_i(resolve_target),
        .resolve_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .train_valid_i(train_valid), .train_branch_i(train_branch),
        .train_taken_i(train_taken), .train_pc_i(train_pc),
        .prediction_taken_o(always_decline_prediction),
        .prediction_weak_o(always_decline_weak),
        .fetch_stall_o(always_decline_fetch),
        .decode_stall_o(always_decline_decode)
    );

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_REPEAT_LAST)
    ) u_repeat_last (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .squash_i(1'b0),
        .recovery_i(1'b0), .recovery_id_i(10'd0),
        .ras_context_flush_i(ras_context_flush),
        .lookup_valid_i(lookup_valid),
        .lookup_branch_i(lookup_branch),
        .lookup_jump_i(lookup_jump),
        .lookup_indirect_i(lookup_indirect),
        .lookup_backward_i(lookup_backward),
        .lookup_instr_i(lookup_instr),
        .lookup_pc_i(lookup_pc),
        .lookup_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .lookup_observational_i(1'b0),
        .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid),
        .resolve_branch_i(resolve_branch),
        .resolve_taken_i(resolve_taken),
        .resolve_instr_i(resolve_instr),
        .resolve_pc_i(resolve_pc),
        .resolve_target_i(resolve_target),
        .resolve_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .train_valid_i(train_valid), .train_branch_i(train_branch),
        .train_taken_i(train_taken), .train_pc_i(train_pc),
        .prediction_taken_o(repeat_last_prediction),
        .prediction_weak_o(repeat_last_weak),
        .fetch_stall_o(repeat_last_fetch),
        .decode_stall_o(repeat_last_decode)
    );

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_BTFNT)
    ) u_btfnt (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .squash_i(1'b0),
        .recovery_i(1'b0), .recovery_id_i(10'd0),
        .ras_context_flush_i(ras_context_flush),
        .lookup_valid_i(lookup_valid),
        .lookup_branch_i(lookup_branch),
        .lookup_jump_i(lookup_jump),
        .lookup_indirect_i(lookup_indirect),
        .lookup_backward_i(lookup_backward),
        .lookup_instr_i(lookup_instr),
        .lookup_pc_i(lookup_pc),
        .lookup_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .lookup_observational_i(1'b0),
        .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid),
        .resolve_branch_i(resolve_branch),
        .resolve_taken_i(resolve_taken),
        .resolve_instr_i(resolve_instr),
        .resolve_pc_i(resolve_pc),
        .resolve_target_i(resolve_target),
        .resolve_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .train_valid_i(train_valid), .train_branch_i(train_branch),
        .train_taken_i(train_taken), .train_pc_i(train_pc),
        .prediction_taken_o(btfnt_prediction),
        .prediction_weak_o(btfnt_weak),
        .prediction_target_valid_o(btfnt_target_valid),
        .prediction_target_o(btfnt_target),
        .target_mispredict_o(btfnt_target_mispredict),
        .fetch_stall_o(btfnt_fetch),
        .decode_stall_o(btfnt_decode)
    );

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_BTFNT),
        .ENABLE_RAS(0),
        .RAS_DEPTH(4)
    ) u_btfnt_no_ras (
        .clk(clk), .rst_n(rst_n), .flush_i(flush), .squash_i(1'b0),
        .recovery_i(1'b0), .recovery_id_i(10'd0),
        .ras_context_flush_i(ras_context_flush),
        .lookup_valid_i(lookup_valid),
        .lookup_branch_i(lookup_branch), .lookup_jump_i(lookup_jump),
        .lookup_indirect_i(lookup_indirect),
        .lookup_backward_i(lookup_backward),
        .lookup_instr_i(lookup_instr),
        .lookup_pc_i(lookup_pc),
        .lookup_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .lookup_observational_i(1'b0),
        .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid),
        .resolve_branch_i(resolve_branch),
        .resolve_taken_i(resolve_taken),
        .resolve_instr_i(resolve_instr), .resolve_pc_i(resolve_pc),
        .resolve_target_i(resolve_target),
        .resolve_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .train_valid_i(train_valid), .train_branch_i(train_branch),
        .train_taken_i(train_taken), .train_pc_i(train_pc),
        .prediction_taken_o(no_ras_prediction),
        .prediction_target_valid_o(no_ras_target_valid),
        .prediction_target_o(), .target_mispredict_o(),
        .fetch_stall_o(no_ras_fetch),
        .decode_stall_o(no_ras_decode)
    );

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_BTFNT),
        .ENABLE_RAS(1),
        .RAS_DEPTH(4)
    ) u_btfnt_ras4 (
        .clk(clk), .rst_n(rst_n), .flush_i(flush), .squash_i(1'b0),
        .recovery_i(1'b0), .recovery_id_i(10'd0),
        .ras_context_flush_i(ras_context_flush),
        .lookup_valid_i(lookup_valid),
        .lookup_branch_i(lookup_branch), .lookup_jump_i(lookup_jump),
        .lookup_indirect_i(lookup_indirect),
        .lookup_backward_i(lookup_backward),
        .lookup_instr_i(lookup_instr),
        .lookup_pc_i(lookup_pc),
        .lookup_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .lookup_observational_i(1'b0),
        .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid),
        .resolve_branch_i(resolve_branch),
        .resolve_taken_i(resolve_taken),
        .resolve_instr_i(resolve_instr), .resolve_pc_i(resolve_pc),
        .resolve_target_i(resolve_target),
        .resolve_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .train_valid_i(train_valid), .train_branch_i(train_branch),
        .train_taken_i(train_taken), .train_pc_i(train_pc),
        .prediction_taken_o(ras4_prediction),
        .prediction_target_valid_o(ras4_target_valid),
        .prediction_target_o(ras4_target), .target_mispredict_o(),
        .fetch_stall_o(ras4_fetch), .decode_stall_o(ras4_decode),
        .inhibit_load_speculation_o(ras4_load_inhibit)
    );

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_BIMODAL),
        .ENABLE_RAS(0),
        .BIMODAL_ENTRIES(32),
        .BIMODAL_COUNTER_BITS(3),
        .BIMODAL_UPDATE_DEPTH(4)
    ) u_bimodal (
        .clk(clk), .rst_n(rst_n), .flush_i(flush), .squash_i(1'b0),
        .recovery_i(1'b0), .recovery_id_i(10'd0),
        .ras_context_flush_i(ras_context_flush),
        .lookup_valid_i(lookup_valid),
        .lookup_branch_i(lookup_branch), .lookup_jump_i(lookup_jump),
        .lookup_indirect_i(lookup_indirect),
        .lookup_backward_i(lookup_backward),
        .lookup_instr_i(lookup_instr), .lookup_pc_i(lookup_pc),
        .lookup_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .lookup_observational_i(1'b0),
        .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid),
        .resolve_branch_i(resolve_branch),
        .resolve_taken_i(resolve_taken),
        .resolve_instr_i(resolve_instr), .resolve_pc_i(resolve_pc),
        .resolve_target_i(resolve_target),
        .resolve_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .train_valid_i(train_valid), .train_branch_i(train_branch),
        .train_taken_i(train_taken), .train_pc_i(train_pc),
        .prediction_taken_o(bimodal_prediction),
        .prediction_weak_o(bimodal_weak),
        .prediction_target_valid_o(), .prediction_target_o(),
        .target_mispredict_o(), .fetch_stall_o(bimodal_fetch),
        .decode_stall_o(bimodal_decode)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic clear_lookup;
        begin
            lookup_valid = 1'b0;
            lookup_branch = 1'b0;
            lookup_jump = 1'b0;
            lookup_indirect = 1'b0;
            lookup_backward = 1'b0;
            lookup_instr = `RV64_INSTR_NOP;
            lookup_pc = 64'd0;
            lookup_allocate = 1'b0;
        end
    endtask

    task automatic clear_train;
        begin
            train_valid = 3'b000;
            train_branch = 3'b000;
            train_taken = 3'b000;
            train_pc = 192'd0;
        end
    endtask

    task automatic clear_resolve;
        begin
            resolve_valid = 1'b0;
            resolve_branch = 1'b0;
            resolve_taken = 1'b0;
            resolve_instr = `RV64_INSTR_NOP;
            resolve_pc = 64'd0;
            resolve_target = 64'd0;
        end
    endtask

    task automatic check_outputs;
        input logic [2:0] exp_stall;
        input logic [2:0] exp_always_branch;
        input logic [2:0] exp_always_decline;
        input logic [2:0] exp_repeat_last;
        input logic [2:0] exp_btfnt;
        input string label;
        begin
            #1;
            if ({stall_prediction, stall_fetch, stall_decode} !== exp_stall ||
                {always_branch_prediction, always_branch_fetch,
                 always_branch_decode} !== exp_always_branch ||
                {always_decline_prediction, always_decline_fetch,
                 always_decline_decode} !== exp_always_decline ||
                {repeat_last_prediction, repeat_last_fetch,
                 repeat_last_decode} !== exp_repeat_last ||
                {btfnt_prediction, btfnt_fetch,
                 btfnt_decode} !== exp_btfnt) begin
                $fatal(1,
                    "%0s: stall=%03b/%03b branch=%03b/%03b decline=%03b/%03b repeat=%03b/%03b btfnt=%03b/%03b",
                    label,
                    {stall_prediction, stall_fetch, stall_decode}, exp_stall,
                    {always_branch_prediction, always_branch_fetch,
                     always_branch_decode}, exp_always_branch,
                    {always_decline_prediction, always_decline_fetch,
                     always_decline_decode}, exp_always_decline,
                    {repeat_last_prediction, repeat_last_fetch,
                     repeat_last_decode}, exp_repeat_last,
                    {btfnt_prediction, btfnt_fetch, btfnt_decode}, exp_btfnt);
            end
        end
    endtask

    initial begin
        flush = 1'b0;
        ras_context_flush = 1'b0;
        clear_lookup();
        clear_resolve();
        clear_train();
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        check_outputs(3'b000, 3'b000, 3'b000, 3'b000, 3'b000,
                      "reset idle");

        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        check_outputs(3'b010, 3'b100, 3'b000, 3'b000, 3'b000,
                      "initial conditional prediction");
        if ({stall_weak, always_branch_weak, always_decline_weak,
             repeat_last_weak, btfnt_weak, bimodal_weak} !== 6'b011111)
            $fatal(1, "cold/static confidence classification mismatch");

        lookup_backward = 1'b1;
        check_outputs(3'b010, 3'b100, 3'b000, 3'b000, 3'b100,
                      "backward conditional prediction");
        lookup_backward = 1'b0;

        lookup_allocate = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear_lookup();
        check_outputs(3'b011, 3'b000, 3'b000, 3'b000, 3'b000,
                      "stall policy holds unresolved branch");

        resolve_valid = 1'b1;
        resolve_branch = 1'b1;
        resolve_taken = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear_resolve();
        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        check_outputs(3'b010, 3'b100, 3'b000, 3'b100, 3'b000,
                      "repeat-last learns taken");

        clear_lookup();
        resolve_valid = 1'b1;
        resolve_branch = 1'b1;
        resolve_taken = 1'b0;
        @(posedge clk);
        @(negedge clk);
        clear_resolve();
        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        check_outputs(3'b010, 3'b100, 3'b000, 3'b000, 3'b000,
                      "repeat-last learns not-taken");

        lookup_branch = 1'b0;
        lookup_jump = 1'b1;
        check_outputs(3'b010, 3'b100, 3'b100, 3'b100, 3'b100,
                      "direct jumps are known taken");
        if (stall_weak || always_branch_weak || always_decline_weak ||
            repeat_last_weak || btfnt_weak || bimodal_weak)
            $fatal(1, "direct jump incorrectly reported weak direction");

        lookup_indirect = 1'b1;
        check_outputs(3'b010, 3'b010, 3'b010, 3'b010, 3'b010,
                      "indirect jump stalls without target table");

        lookup_allocate = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear_lookup();
        check_outputs(3'b011, 3'b011, 3'b011, 3'b011, 3'b011,
                      "indirect jump remains held until resolve");

        flush = 1'b1;
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;
        check_outputs(3'b000, 3'b000, 3'b000, 3'b000, 3'b000,
                      "flush releases unresolved jump");

        // A resolved JAL x1 pushes PC+4.  The ordinary RET hint then uses
        // the RAS in every predictive policy while stall mode remains a
        // strict no-speculation baseline.
        clear_lookup();
        resolve_valid = 1'b1;
        resolve_taken = 1'b1;
        resolve_instr = 32'h0000_00ef; // JAL x1, 0
        resolve_pc = 64'h100;
        resolve_target = 64'h100;
        @(posedge clk);
        @(negedge clk);
        clear_resolve();
        lookup_valid = 1'b1;
        lookup_jump = 1'b1;
        lookup_indirect = 1'b1;
        lookup_instr = 32'h0000_8067; // JALR x0, 0(x1)
        check_outputs(3'b010, 3'b100, 3'b100, 3'b100, 3'b100,
                      "RAS predicts return");
        if (!btfnt_target_valid || btfnt_target != 64'h104)
            $fatal(1, "RAS target mismatch: valid=%0b target=%016x",
                   btfnt_target_valid, btfnt_target);
        if ({ras4_prediction, ras4_fetch, ras4_decode} !== 3'b100 ||
            !ras4_target_valid || ras4_target != 64'h104)
            $fatal(1,
                   "parameterized RAS mismatch: state=%03b valid=%0b target=%016x",
                   {ras4_prediction, ras4_fetch, ras4_decode},
                   ras4_target_valid, ras4_target);
        if ({no_ras_prediction, no_ras_fetch, no_ras_decode} !== 3'b010 ||
            no_ras_target_valid)
            $fatal(1,
                   "disabled RAS predicted return: state=%03b target_valid=%0b",
                   {no_ras_prediction, no_ras_fetch, no_ras_decode},
                   no_ras_target_valid);

        // A trap/return/address-space flush must discard resolved RAS state.
        // Otherwise a return in the new context can fetch an old virtual
        // address as a BARE physical address.  It must instead wait for the
        // backend to resolve the indirect target.
        ras_context_flush = 1'b1;
        @(posedge clk);
        @(negedge clk);
        ras_context_flush = 1'b0;
        check_outputs(3'b010, 3'b010, 3'b010, 3'b010, 3'b010,
                      "architectural flush invalidates RAS context");
        if (btfnt_target_valid || ras4_target_valid)
            $fatal(1,
                   "architectural flush retained RAS target: default=%0b ras4=%0b",
                   btfnt_target_valid, ras4_target_valid);

        // Restore the entry for target-mismatch and pop coverage below.
        clear_lookup();
        resolve_valid = 1'b1;
        resolve_taken = 1'b1;
        resolve_instr = 32'h0000_00ef; // JAL x1, 0
        resolve_pc = 64'h100;
        resolve_target = 64'h100;
        @(posedge clk);
        @(negedge clk);
        clear_resolve();
        lookup_valid = 1'b1;
        lookup_jump = 1'b1;
        lookup_indirect = 1'b1;
        lookup_instr = 32'h0000_8067;

        lookup_allocate = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear_lookup();
        resolve_valid = 1'b1;
        resolve_taken = 1'b1;
        resolve_instr = 32'h0000_8067;
        resolve_pc = 64'h200;
        resolve_target = 64'h108;
        #1;
        if (!btfnt_target_mispredict)
            $fatal(1, "RAS failed to flag target mismatch");
        resolve_target = 64'h104;
        #1;
        if (btfnt_target_mispredict)
            $fatal(1, "RAS falsely flagged matching target");
        @(posedge clk);
        @(negedge clk);
        clear_resolve();

        // The resolved RET holds the conservative LSU hint for exactly four
        // complete cycles.  The resolve edge itself loads the interval.
        if (!ras4_load_inhibit)
            $fatal(1, "resolved RET did not start load-speculation inhibit");
        repeat (3) begin
            @(posedge clk);
            @(negedge clk);
            if (!ras4_load_inhibit)
                $fatal(1, "RET load-speculation inhibit ended early");
        end
        @(posedge clk);
        @(negedge clk);
        if (ras4_load_inhibit)
            $fatal(1, "RET load-speculation inhibit exceeded four cycles");

        lookup_valid = 1'b1;
        lookup_jump = 1'b1;
        lookup_indirect = 1'b1;
        lookup_instr = 32'h0000_8067;
        check_outputs(3'b010, 3'b010, 3'b010, 3'b010, 3'b010,
                      "empty RAS stalls return");

        // Reset the learned direction state, then verify cold BTFNT behavior,
        // three-wide update capture, and genuine three-bit hysteresis.
        clear_lookup();
        clear_resolve();
        clear_train();
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        lookup_pc = 64'h80;
        lookup_backward = 1'b0;
        #1;
        if (bimodal_prediction || bimodal_fetch || bimodal_decode ||
            !bimodal_weak)
            $fatal(1, "bimodal cold forward branch did not use BTFNT");
        lookup_pc = 64'h100;
        lookup_backward = 1'b1;
        #1;
        if (!bimodal_prediction)
            $fatal(1, "bimodal cold backward branch did not use BTFNT");

        clear_lookup();
        train_valid = 3'b111;
        train_branch = 3'b111;
        train_taken = 3'b101;
        train_pc = {64'h88, 64'h84, 64'h80};
        @(posedge clk);
        @(negedge clk);
        clear_train();
        repeat (4) @(posedge clk);
        @(negedge clk);
        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        lookup_backward = 1'b0;
        lookup_pc = 64'h80;
        #1;
        if (!bimodal_prediction || !bimodal_weak)
            $fatal(1, "bimodal failed to learn lane 0 taken");
        lookup_pc = 64'h84;
        #1;
        if (bimodal_prediction)
            $fatal(1, "bimodal failed to learn lane 1 not-taken");
        lookup_pc = 64'h88;
        #1;
        if (!bimodal_prediction)
            $fatal(1, "bimodal failed to learn lane 2 taken");

        // Saturate PC 0x80 taken, then prove three contrary updates do not
        // flip it while the fourth one does.
        clear_lookup();
        repeat (4) begin
            train_valid = 3'b001;
            train_branch = 3'b001;
            train_taken = 3'b001;
            train_pc = {128'd0, 64'h80};
            @(posedge clk);
            @(negedge clk);
            clear_train();
        end
        repeat (2) @(posedge clk);
        @(negedge clk);
        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        lookup_pc = 64'h80;
        #1;
        if (!bimodal_prediction || bimodal_weak)
            $fatal(1, "saturated bimodal entry did not report strong taken");
        clear_lookup();
        train_valid = 3'b111;
        train_branch = 3'b111;
        train_taken = 3'b000;
        train_pc = {64'h80, 64'h80, 64'h80};
        @(posedge clk);
        @(negedge clk);
        clear_train();
        repeat (4) @(posedge clk);
        @(negedge clk);
        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        lookup_pc = 64'h80;
        #1;
        if (!bimodal_prediction || !bimodal_weak)
            $fatal(1, "three-bit counter flipped before fourth miss");

        clear_lookup();
        train_valid = 3'b001;
        train_branch = 3'b001;
        train_taken = 3'b000;
        train_pc = {128'd0, 64'h80};
        @(posedge clk);
        @(negedge clk);
        clear_train();
        repeat (2) @(posedge clk);
        @(negedge clk);
        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        lookup_pc = 64'h80;
        #1;
        if (bimodal_prediction || !bimodal_weak)
            $fatal(1, "three-bit counter failed to flip on fourth miss");
        if (u_bimodal.g_bimodal.u_policy.update_overflow_o)
            $fatal(1, "bimodal update FIFO overflowed in directed test");

        $display("PASS: modular branch predictor policies");
        $finish;
    end

endmodule
