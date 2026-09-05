`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/exec/bp/defs.v"

module tb_exec_bp_modes78;
    reg clk;
    reg rst_n;
    reg flush;
    reg squash;
    reg recovery;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] recovery_id;
    reg lookup_valid;
    reg lookup_branch;
    reg lookup_jump;
    reg lookup_indirect;
    reg lookup_backward;
    reg [31:0] lookup_instr;
    reg [63:0] lookup_pc;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] lookup_id;
    reg lookup_allocate;
    reg resolve_valid;
    reg resolve_branch_kind;
    reg resolve_taken;
    reg [31:0] resolve_instr;
    reg [63:0] resolve_pc;
    reg [63:0] resolve_target;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] resolve_id;
    wire mode7_prediction_taken;
    wire mode7_prediction_weak;
    wire mode8_prediction_taken;
    wire mode8_prediction_weak;
    wire mode7_target_valid;
    wire mode8_target_valid;
    wire [63:0] mode7_target;
    wire [63:0] mode8_target;
    wire mode7_fetch_stall;
    wire mode8_fetch_stall;
    wire mode7_overflow;
    wire mode8_overflow;

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_GSHARE_BTB_512),
        // Mode 7 must ignore the mode-6 geometry knobs.
        .GSHARE_ENTRIES(8), .GSHARE_COUNTER_BITS(2),
        .ENABLE_RAS(0), .BTB_ENTRIES(8), .BTB_TAG_BITS(8),
        .INFLIGHT_DEPTH(4), .ENABLE_TAGGED_RESOLUTION(1)
    ) dut7 (
        .clk(clk), .rst_n(rst_n), .flush_i(flush), .squash_i(squash),
        .recovery_i(recovery), .recovery_id_i(recovery_id),
        .ras_context_flush_i(1'b0),
        .lookup_valid_i(lookup_valid), .lookup_branch_i(lookup_branch),
        .lookup_jump_i(lookup_jump), .lookup_indirect_i(lookup_indirect),
        .lookup_backward_i(lookup_backward),
        .lookup_instr_i(lookup_instr), .lookup_pc_i(lookup_pc),
        .lookup_id_i(lookup_id), .lookup_observational_i(1'b0),
        .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid),
        .resolve_branch_i(resolve_branch_kind),
        .resolve_taken_i(resolve_taken), .resolve_instr_i(resolve_instr),
        .resolve_pc_i(resolve_pc), .resolve_target_i(resolve_target),
        .resolve_id_i(resolve_id),
        .train_valid_i(3'b000), .train_branch_i(3'b000),
        .train_taken_i(3'b000), .train_pc_i(192'd0),
        .prediction_taken_o(mode7_prediction_taken),
        .prediction_weak_o(mode7_prediction_weak),
        .prediction_target_valid_o(mode7_target_valid),
        .prediction_target_o(mode7_target),
        .target_mispredict_o(), .update_overflow_o(mode7_overflow),
        .fetch_stall_o(mode7_fetch_stall), .decode_stall_o()
    );

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_TOURNAMENT_BTB),
        .TOURNAMENT_GLOBAL_ENTRIES(8),
        .TOURNAMENT_GLOBAL_COUNTER_BITS(3),
        .TOURNAMENT_GLOBAL_HISTORY_BITS(3),
        .TOURNAMENT_LOCAL_HISTORY_ENTRIES(4),
        .TOURNAMENT_LOCAL_HISTORY_BITS(2),
        .TOURNAMENT_LOCAL_PHT_ENTRIES(4),
        .TOURNAMENT_LOCAL_COUNTER_BITS(3),
        .TOURNAMENT_CHOOSER_ENTRIES(4),
        .TOURNAMENT_CHOOSER_COUNTER_BITS(2),
        .ENABLE_RAS(0), .BTB_ENTRIES(8), .BTB_TAG_BITS(8),
        .INFLIGHT_DEPTH(4), .ENABLE_TAGGED_RESOLUTION(1)
    ) dut8 (
        .clk(clk), .rst_n(rst_n), .flush_i(flush), .squash_i(squash),
        .recovery_i(recovery), .recovery_id_i(recovery_id),
        .ras_context_flush_i(1'b0),
        .lookup_valid_i(lookup_valid), .lookup_branch_i(lookup_branch),
        .lookup_jump_i(lookup_jump), .lookup_indirect_i(lookup_indirect),
        .lookup_backward_i(lookup_backward),
        .lookup_instr_i(lookup_instr), .lookup_pc_i(lookup_pc),
        .lookup_id_i(lookup_id), .lookup_observational_i(1'b0),
        .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid),
        .resolve_branch_i(resolve_branch_kind),
        .resolve_taken_i(resolve_taken), .resolve_instr_i(resolve_instr),
        .resolve_pc_i(resolve_pc), .resolve_target_i(resolve_target),
        .resolve_id_i(resolve_id),
        .train_valid_i(3'b000), .train_branch_i(3'b000),
        .train_taken_i(3'b000), .train_pc_i(192'd0),
        .prediction_taken_o(mode8_prediction_taken),
        .prediction_weak_o(mode8_prediction_weak),
        .prediction_target_valid_o(mode8_target_valid),
        .prediction_target_o(mode8_target),
        .target_mispredict_o(), .update_overflow_o(mode8_overflow),
        .fetch_stall_o(mode8_fetch_stall), .decode_stall_o()
    );

    always #5 clk = ~clk;

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic allocate_branch;
        input [`OPENRV64_INSTR_ID_WIDTH-1:0] id;
        input [63:0] pc;
        begin
            lookup_valid = 1'b1;
            lookup_branch = 1'b1;
            lookup_jump = 1'b0;
            lookup_indirect = 1'b0;
            lookup_backward = 1'b0;
            lookup_instr = 32'h0000_0063;
            lookup_pc = pc;
            lookup_id = id;
            lookup_allocate = 1'b1;
            #1;
            tick();
            lookup_valid = 1'b0;
            lookup_allocate = 1'b0;
        end
    endtask

    task automatic resolve_branch;
        input [`OPENRV64_INSTR_ID_WIDTH-1:0] id;
        input [63:0] pc;
        input taken;
        input do_squash;
        begin
            resolve_valid = 1'b1;
            resolve_branch_kind = 1'b1;
            resolve_taken = taken;
            resolve_instr = 32'h0000_0063;
            resolve_pc = pc;
            resolve_target = pc - 64'd4;
            resolve_id = id;
            squash = do_squash;
            tick();
            resolve_valid = 1'b0;
            squash = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        squash = 1'b0;
        recovery = 1'b0;
        recovery_id = {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        lookup_valid = 1'b0;
        lookup_branch = 1'b0;
        lookup_jump = 1'b0;
        lookup_indirect = 1'b0;
        lookup_backward = 1'b0;
        lookup_instr = 32'd0;
        lookup_pc = 64'd0;
        lookup_id = {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        lookup_allocate = 1'b0;
        resolve_valid = 1'b0;
        resolve_branch_kind = 1'b0;
        resolve_taken = 1'b0;
        resolve_instr = 32'd0;
        resolve_pc = 64'd0;
        resolve_target = 64'd0;
        resolve_id = {`OPENRV64_INSTR_ID_WIDTH{1'b0}};

        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        if (dut7.g_advanced.u_advanced.PHT_ENTRIES != 512 ||
            dut7.g_advanced.u_advanced.HISTORY_BITS != 9 ||
            dut7.g_advanced.u_advanced.COUNTER_BITS != 3)
            $fatal(1, "mode 7 did not elaborate as fixed 512x3/9b gshare");

        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        lookup_pc = 64'h100;
        lookup_backward = 1'b0;
        #1;
        if (mode7_prediction_taken || !mode7_prediction_weak ||
            mode8_prediction_taken || !mode8_prediction_weak)
            $fatal(1, "modes 7/8 did not preserve cold forward BTFNT");

        // Agreement is still weak until the global entry, this branch's local
        // history, and the selected local PHT entry are all valid.
        dut8.g_tournament.u_tournament.global_valid_q[0] = 1'b1;
        dut8.g_tournament.u_tournament.global_counter_q[0] = 3'b010;
        dut8.g_tournament.u_tournament.local_valid_q[0] = 1'b1;
        dut8.g_tournament.u_tournament.local_counter_q[0] = 3'b000;
        dut8.g_tournament.u_tournament.chooser_valid_q[0] = 1'b1;
        dut8.g_tournament.u_tournament.chooser_counter_q[0] = 2'b01;
        #1;
        if (mode8_prediction_taken || !mode8_prediction_weak)
            $fatal(1, "invalid local history did not report weak");
        dut8.g_tournament.u_tournament.local_history_q[0] = 2'b00;
        dut8.g_tournament.u_tournament.local_history_valid_q[0] = 1'b1;
        #1;
        if (mode8_prediction_taken || mode8_prediction_weak)
            $fatal(1, "tournament agreement incorrectly reported weak");

        // Force the two trained tournament components to disagree. The
        // weak-global chooser must select global, then move toward local when
        // only the local component predicts the actual taken outcome.
        dut8.g_tournament.u_tournament.local_counter_q[0] = 3'b111;
        #1;
        if (mode8_prediction_taken || !mode8_prediction_weak)
            $fatal(1, "tournament disagreement did not report weak");

        allocate_branch(10'd10, 64'h100);
        resolve_branch(10'd10, 64'h100, 1'b1, 1'b1);
        if (dut8.g_tournament.u_tournament.chooser_counter_q[0] != 2'b10)
            $fatal(1, "tournament chooser did not train toward local");

        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        lookup_pc = 64'h100;
        lookup_backward = 1'b0;
        dut8.g_tournament.u_tournament.global_valid_q[1] = 1'b1;
        dut8.g_tournament.u_tournament.global_counter_q[1] = 3'b000;
        dut8.g_tournament.u_tournament.local_valid_q[1] = 1'b1;
        dut8.g_tournament.u_tournament.local_counter_q[1] = 3'b111;
        #1;
        if (!mode8_prediction_taken || !mode8_prediction_weak)
            $fatal(1, "weak chooser hid component disagreement");
        dut8.g_tournament.u_tournament.chooser_counter_q[0] = 2'b11;
        #1;
        if (!mode8_prediction_taken || !mode8_prediction_weak)
            $fatal(1, "strong chooser hid component disagreement");
        dut8.g_tournament.u_tournament.local_counter_q[1] = 3'b101;
        #1;
        if (!mode8_prediction_taken || !mode8_prediction_weak)
            $fatal(1, "counter strength hid component disagreement");
        dut8.g_tournament.u_tournament.global_counter_q[1] = 3'b111;
        #1;
        if (!mode8_prediction_taken || mode8_prediction_weak)
            $fatal(1, "component agreement reported weak");
        lookup_valid = 1'b0;

        // Tagged mode must retain its older checkpoint, allow a younger
        // resolution to wait, and discard that younger record on recovery.
        allocate_branch(10'd20, 64'h200);
        allocate_branch(10'd21, 64'h300);
        resolve_branch(10'd21, 64'h300, 1'b1, 1'b0);
        if (dut8.g_tournament.u_tournament.inflight_count_q != 2)
            $fatal(1, "tournament popped an out-of-order resolution");
        resolve_branch(10'd20, 64'h200, 1'b0, 1'b1);
        if (dut8.g_tournament.u_tournament.inflight_count_q != 1)
            $fatal(1, "tournament selective squash retained a younger record");
        tick();
        if (dut8.g_tournament.u_tournament.inflight_count_q != 0 ||
            mode7_overflow || mode8_overflow)
            $fatal(1, "modes 7/8 did not drain cleanly");

        // Recovery at a non-control ID can discard a resolved predictor head.
        // That head is not part of the retained prefix and must not be
        // subtracted from the zero keep count.
        allocate_branch(10'd24, 64'h380);
        resolve_valid = 1'b1;
        resolve_branch_kind = 1'b1;
        resolve_taken = 1'b0;
        resolve_instr = 32'h0000_0063;
        resolve_pc = 64'h380;
        resolve_target = 64'h384;
        resolve_id = 10'd24;
        recovery = 1'b1;
        recovery_id = 10'd23;
        tick();
        resolve_valid = 1'b0;
        recovery = 1'b0;
        if ((dut7.g_advanced.u_advanced.inflight_count_q != 0) ||
            (dut8.g_tournament.u_tournament.inflight_count_q != 0))
            $fatal(1, "modes 7/8 underflowed an all-discard recovery");

        // The tournament module owns a separate copy of the target machinery,
        // so validate it directly rather than relying on the mode-6 test.
        lookup_valid = 1'b1;
        lookup_branch = 1'b0;
        lookup_jump = 1'b1;
        lookup_indirect = 1'b1;
        lookup_instr = 32'h0005_00e7; // JALR x1,x10,0
        lookup_pc = 64'h400;
        lookup_id = 10'd30;
        #1;
        if (mode7_target_valid || mode8_target_valid ||
            !mode7_fetch_stall || !mode8_fetch_stall)
            $fatal(1, "modes 7/8 cold JALR did not expose a BTB miss");
        lookup_allocate = 1'b1;
        tick();
        lookup_valid = 1'b0;
        lookup_allocate = 1'b0;

        resolve_valid = 1'b1;
        resolve_branch_kind = 1'b0;
        resolve_taken = 1'b1;
        resolve_instr = 32'h0005_00e7;
        resolve_pc = 64'h400;
        resolve_target = 64'h900;
        resolve_id = 10'd30;
        tick();
        resolve_valid = 1'b0;

        lookup_valid = 1'b1;
        lookup_jump = 1'b1;
        lookup_indirect = 1'b1;
        lookup_instr = 32'h0005_00e7;
        lookup_pc = 64'h400;
        #1;
        if (!mode7_prediction_taken || !mode8_prediction_taken ||
            !mode7_target_valid || !mode8_target_valid ||
            mode7_target != 64'h900 || mode8_target != 64'h900 ||
            mode7_fetch_stall || mode8_fetch_stall)
            $fatal(1, "modes 7/8 trained JALR missed the BTB target");

        $display("PASS: fixed mode-7 geometry and mode-8 tournament direction/target recovery");
        $finish;
    end
endmodule
