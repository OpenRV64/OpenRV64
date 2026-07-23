`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/exec/bp/defs.v"

module tb_exec_bp_tagged_speculation;
    reg clk;
    reg rst_n;
    reg flush;
    reg squash;
    reg lookup_valid;
    reg lookup_branch;
    reg lookup_backward;
    reg [31:0] lookup_instr;
    reg [63:0] lookup_pc;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] lookup_id;
    reg lookup_allocate;
    reg resolve_valid;
    reg resolve_taken;
    reg [31:0] resolve_instr;
    reg [63:0] resolve_pc;
    reg [63:0] resolve_target;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] resolve_id;
    wire prediction_taken;
    wire overflow;

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_GSHARE_BTB),
        .ENABLE_RAS(0), .GSHARE_ENTRIES(8),
        .BTB_ENTRIES(8), .BTB_TAG_BITS(8),
        .INFLIGHT_DEPTH(4), .ENABLE_TAGGED_RESOLUTION(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush), .squash_i(squash),
        .lookup_valid_i(lookup_valid), .lookup_branch_i(lookup_branch),
        .lookup_jump_i(1'b0), .lookup_indirect_i(1'b0),
        .lookup_backward_i(lookup_backward),
        .lookup_instr_i(lookup_instr), .lookup_pc_i(lookup_pc),
        .lookup_id_i(lookup_id), .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid), .resolve_branch_i(1'b1),
        .resolve_taken_i(resolve_taken), .resolve_instr_i(resolve_instr),
        .resolve_pc_i(resolve_pc), .resolve_target_i(resolve_target),
        .resolve_id_i(resolve_id),
        .train_valid_i(3'b000), .train_branch_i(3'b000),
        .train_taken_i(3'b000), .train_pc_i(192'd0),
        .prediction_taken_o(prediction_taken),
        .prediction_target_valid_o(), .prediction_target_o(),
        .target_mispredict_o(), .update_overflow_o(overflow),
        .fetch_stall_o(), .decode_stall_o()
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
            lookup_backward = 1'b1;
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
        lookup_valid = 1'b0;
        lookup_branch = 1'b0;
        lookup_backward = 1'b0;
        lookup_instr = 32'd0;
        lookup_pc = 64'd0;
        lookup_id = {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        lookup_allocate = 1'b0;
        resolve_valid = 1'b0;
        resolve_taken = 1'b0;
        resolve_instr = 32'd0;
        resolve_pc = 64'd0;
        resolve_target = 64'd0;
        resolve_id = {`OPENRV64_INSTR_ID_WIDTH{1'b0}};

        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        allocate_branch(64'd10, 64'h100);
        allocate_branch(64'd11, 64'h200);
        if (dut.g_advanced.u_advanced.inflight_count_q != 2)
            $fatal(1, "tagged predictor did not allocate two checkpoints");

        // Resolve the younger branch first.  It may train immediately, but it
        // remains ordered behind ID 10 for committed-history advancement.
        resolve_branch(64'd11, 64'h200, 1'b1, 1'b0);
        if (dut.g_advanced.u_advanced.inflight_count_q != 2)
            $fatal(1, "out-of-order resolution incorrectly popped the queue");

        // ID 10 was predicted taken and resolves not-taken.  Recovery keeps
        // it, removes ID 11, and restores history from ID 10's checkpoint.
        resolve_branch(64'd10, 64'h100, 1'b0, 1'b1);
        if (dut.g_advanced.u_advanced.inflight_count_q != 1)
            $fatal(1, "tagged squash did not truncate the younger checkpoint");
        tick();
        if (dut.g_advanced.u_advanced.inflight_count_q != 0)
            $fatal(1, "resolved recovery head did not commit");

        allocate_branch(64'd20, 64'h300);
        resolve_branch(64'd20, 64'h300, 1'b1, 1'b0);
        tick();
        if (dut.g_advanced.u_advanced.inflight_count_q != 0 || overflow)
            $fatal(1, "post-recovery checkpoint did not drain cleanly");

        // IDs remain age-ordered across 1023 -> 0.  Resolving 1023 must retain
        // 1022 and 1023 while discarding the younger ID 0 checkpoint.
        allocate_branch(10'd1022, 64'h400);
        allocate_branch(10'd1023, 64'h500);
        allocate_branch(10'd0, 64'h600);
        resolve_branch(10'd1023, 64'h500, 1'b0, 1'b1);
        if (dut.g_advanced.u_advanced.inflight_count_q != 2)
            $fatal(1, "tagged predictor misordered modular IDs at wrap");

        $display("PASS: tagged predictor out-of-order resolve and selective rollback");
        $finish;
    end
endmodule
