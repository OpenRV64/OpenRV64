`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/exec/bp/defs.v"

module tb_exec_bp_gshare_btb;
    logic clk;
    logic rst_n;
    logic flush;
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
    logic prediction_taken;
    logic prediction_weak;
    logic prediction_target_valid;
    logic [63:0] prediction_target;
    logic target_mispredict;
    logic update_overflow;
    logic fetch_stall;
    logic decode_stall;
    integer fill_index;

    localparam logic [31:0] JAL_X0 = 32'h0000_006f;
    localparam logic [31:0] JALR_CALL_X10 = 32'h0005_00e7;
    localparam logic [31:0] RET_X1 = 32'h0000_8067;

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_GSHARE_BTB),
        .ENABLE_RAS(1), .RAS_DEPTH(4),
        .GSHARE_ENTRIES(8), .GSHARE_COUNTER_BITS(3),
        .BTB_ENTRIES(8), .BTB_TAG_BITS(8), .INFLIGHT_DEPTH(4)
    ) dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush), .squash_i(1'b0),
        .recovery_i(1'b0), .recovery_id_i(10'd0),
        .ras_context_flush_i(1'b0),
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
        .train_valid_i(3'b000), .train_branch_i(3'b000),
        .train_taken_i(3'b000), .train_pc_i(192'd0),
        .prediction_taken_o(prediction_taken),
        .prediction_weak_o(prediction_weak),
        .prediction_target_valid_o(prediction_target_valid),
        .prediction_target_o(prediction_target),
        .target_mispredict_o(target_mispredict),
        .update_overflow_o(update_overflow),
        .fetch_stall_o(fetch_stall), .decode_stall_o(decode_stall)
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

    task automatic allocate_control;
        begin
            lookup_allocate = 1'b1;
            @(posedge clk);
            @(negedge clk);
            clear_lookup();
        end
    endtask

    task automatic resolve_control;
        input logic do_flush;
        begin
            flush = do_flush;
            @(posedge clk);
            @(negedge clk);
            flush = 1'b0;
            clear_resolve();
        end
    endtask

    initial begin
        flush = 1'b0;
        clear_lookup();
        clear_resolve();
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Invalid PHT entries retain the useful BTFNT cold policy.
        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        lookup_pc = 64'h100;
        lookup_backward = 1'b0;
        #1;
        if (prediction_taken || !prediction_weak ||
            fetch_stall || decode_stall)
            $fatal(1, "cold forward gshare prediction is not BTFNT");
        lookup_backward = 1'b1;
        #1;
        if (!prediction_taken || !prediction_weak)
            $fatal(1, "cold backward gshare prediction is not BTFNT");

        // Three correct outcomes move a cold three-bit counter from weak
        // not-taken through the low-confidence middle half to strong
        // not-taken.  Confidence is direction-only.
        lookup_pc = 64'h104;
        lookup_backward = 1'b0;
        allocate_control();
        resolve_valid = 1'b1;
        resolve_branch = 1'b1;
        resolve_taken = 1'b0;
        resolve_instr = 32'h0000_0063;
        resolve_pc = 64'h104;
        resolve_target = 64'h108;
        resolve_control(1'b1);
        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        lookup_pc = 64'h104;
        #1;
        if (prediction_taken || !prediction_weak)
            $fatal(1, "new gshare entry did not report weak not-taken");
        allocate_control();
        resolve_valid = 1'b1;
        resolve_branch = 1'b1;
        resolve_taken = 1'b0;
        resolve_instr = 32'h0000_0063;
        resolve_pc = 64'h104;
        resolve_target = 64'h108;
        resolve_control(1'b1);
        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        lookup_pc = 64'h104;
        #1;
        if (prediction_taken || !prediction_weak)
            $fatal(1, "middle gshare state reported strong not-taken");
        allocate_control();
        resolve_valid = 1'b1;
        resolve_branch = 1'b1;
        resolve_taken = 1'b0;
        resolve_instr = 32'h0000_0063;
        resolve_pc = 64'h104;
        resolve_target = 64'h108;
        resolve_control(1'b1);
        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        lookup_pc = 64'h104;
        #1;
        if (prediction_taken || prediction_weak)
            $fatal(1, "trained gshare entry did not report strong not-taken");

        // A direction miss restores speculative history to checkpoint+actual.
        lookup_pc = 64'h120;
        lookup_backward = 1'b0;
        allocate_control();
        resolve_valid = 1'b1;
        resolve_branch = 1'b1;
        resolve_taken = 1'b1;
        resolve_instr = 32'h0000_0063; // BEQ x0,x0,0
        resolve_pc = 64'h120;
        resolve_target = 64'h120;
        resolve_control(1'b1);
        if (dut.g_advanced.u_advanced.speculative_ghr_q !== 3'b001)
            $fatal(1, "gshare history rollback did not install actual bit");

        // A cold indirect call has no target and uses the legacy one-control
        // interlock.  Resolution installs a tagged BTB entry.
        lookup_valid = 1'b1;
        lookup_jump = 1'b1;
        lookup_indirect = 1'b1;
        lookup_instr = JALR_CALL_X10;
        lookup_pc = 64'h200;
        #1;
        if (prediction_taken || prediction_target_valid || !fetch_stall ||
            decode_stall)
            $fatal(1, "cold indirect call did not expose a BTB miss");
        allocate_control();
        if (!decode_stall)
            $fatal(1, "allocated targetless indirect did not interlock");
        resolve_valid = 1'b1;
        resolve_taken = 1'b1;
        resolve_instr = JALR_CALL_X10;
        resolve_pc = 64'h200;
        resolve_target = 64'h900;
        resolve_control(1'b1);

        lookup_valid = 1'b1;
        lookup_jump = 1'b1;
        lookup_indirect = 1'b1;
        lookup_instr = JALR_CALL_X10;
        lookup_pc = 64'h200;
        #1;
        if (!prediction_taken || !prediction_target_valid ||
            prediction_target != 64'h900 || fetch_stall || decode_stall)
            $fatal(1, "trained indirect call missed its tagged BTB entry");

        // A hit carries an exact target prediction record.  A changed target
        // must redirect and retrain the entry.
        allocate_control();
        resolve_valid = 1'b1;
        resolve_taken = 1'b1;
        resolve_instr = JALR_CALL_X10;
        resolve_pc = 64'h200;
        resolve_target = 64'h980;
        #1;
        if (!target_mispredict)
            $fatal(1, "BTB failed to report a target mismatch");
        resolve_control(1'b1);

        // The architectural return hint chooses the RAS over the BTB.  Both
        // resolved calls above pushed PC+4.
        lookup_valid = 1'b1;
        lookup_jump = 1'b1;
        lookup_indirect = 1'b1;
        lookup_instr = RET_X1;
        lookup_pc = 64'h300;
        #1;
        if (!prediction_taken || !prediction_target_valid ||
            prediction_target != 64'h204)
            $fatal(1, "RAS did not take priority for return prediction");

        // Queue a direct jump ahead of that return.  Resolving the direct jump
        // must not compare against the younger return's target (the old
        // untagged outstanding-RAS implementation did exactly that).
        clear_lookup();
        lookup_valid = 1'b1;
        lookup_jump = 1'b1;
        lookup_instr = JAL_X0;
        lookup_pc = 64'h2f0;
        allocate_control();
        lookup_valid = 1'b1;
        lookup_jump = 1'b1;
        lookup_indirect = 1'b1;
        lookup_instr = RET_X1;
        lookup_pc = 64'h300;
        allocate_control();
        resolve_valid = 1'b1;
        resolve_taken = 1'b1;
        resolve_instr = JAL_X0;
        resolve_pc = 64'h2f0;
        resolve_target = 64'h700;
        #1;
        if (target_mispredict)
            $fatal(1, "younger RAS target contaminated older resolution");
        resolve_control(1'b0);

        resolve_valid = 1'b1;
        resolve_taken = 1'b1;
        resolve_instr = RET_X1;
        resolve_pc = 64'h300;
        resolve_target = 64'h204;
        #1;
        if (target_mispredict)
            $fatal(1, "matching RAS return target was rejected");
        resolve_control(1'b0);

        // Fill all prediction records without resolving them.  The next
        // control must backpressure decode before an untracked prediction can
        // be allocated, and normal operation must not set overflow.
        for (fill_index = 0; fill_index < 4;
             fill_index = fill_index + 1) begin
            lookup_valid = 1'b1;
            lookup_jump = 1'b1;
            lookup_instr = JAL_X0;
            lookup_pc = 64'h400 + (fill_index * 4);
            allocate_control();
        end
        lookup_valid = 1'b1;
        lookup_jump = 1'b1;
        lookup_instr = JAL_X0;
        lookup_pc = 64'h410;
        #1;
        if (!fetch_stall || !decode_stall)
            $fatal(1, "full prediction-record queue did not backpressure");
        if (update_overflow)
            $fatal(1, "gshare/BTB in-flight record queue overflowed");
        clear_lookup();
        flush = 1'b1;
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;

        $display("PASS: 256-entry-class gshare/BTB/RAS predictor behavior");
        $finish;
    end
endmodule
