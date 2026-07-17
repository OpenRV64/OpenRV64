`timescale 1ns/1ps
`include "core/exec/bp/defs.v"

module tb_exec_bp;

    logic clk;
    logic rst_n;
    logic flush;
    logic lookup_valid;
    logic lookup_branch;
    logic lookup_jump;
    logic lookup_indirect;
    logic lookup_allocate;
    logic resolve_valid;
    logic resolve_branch;
    logic resolve_taken;

    logic stall_prediction;
    logic stall_fetch;
    logic stall_decode;
    logic always_branch_prediction;
    logic always_branch_fetch;
    logic always_branch_decode;
    logic always_decline_prediction;
    logic always_decline_fetch;
    logic always_decline_decode;
    logic repeat_last_prediction;
    logic repeat_last_fetch;
    logic repeat_last_decode;

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_STALL)
    ) u_stall (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .lookup_valid_i(lookup_valid),
        .lookup_branch_i(lookup_branch),
        .lookup_jump_i(lookup_jump),
        .lookup_indirect_i(lookup_indirect),
        .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid),
        .resolve_branch_i(resolve_branch),
        .resolve_taken_i(resolve_taken),
        .prediction_taken_o(stall_prediction),
        .fetch_stall_o(stall_fetch),
        .decode_stall_o(stall_decode)
    );

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_ALWAYS_BRANCH)
    ) u_always_branch (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .lookup_valid_i(lookup_valid),
        .lookup_branch_i(lookup_branch),
        .lookup_jump_i(lookup_jump),
        .lookup_indirect_i(lookup_indirect),
        .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid),
        .resolve_branch_i(resolve_branch),
        .resolve_taken_i(resolve_taken),
        .prediction_taken_o(always_branch_prediction),
        .fetch_stall_o(always_branch_fetch),
        .decode_stall_o(always_branch_decode)
    );

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_ALWAYS_DECLINE)
    ) u_always_decline (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .lookup_valid_i(lookup_valid),
        .lookup_branch_i(lookup_branch),
        .lookup_jump_i(lookup_jump),
        .lookup_indirect_i(lookup_indirect),
        .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid),
        .resolve_branch_i(resolve_branch),
        .resolve_taken_i(resolve_taken),
        .prediction_taken_o(always_decline_prediction),
        .fetch_stall_o(always_decline_fetch),
        .decode_stall_o(always_decline_decode)
    );

    openrv64_exec_bp #(
        .BP_TYPE(`OPENRV64_BP_REPEAT_LAST)
    ) u_repeat_last (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .lookup_valid_i(lookup_valid),
        .lookup_branch_i(lookup_branch),
        .lookup_jump_i(lookup_jump),
        .lookup_indirect_i(lookup_indirect),
        .lookup_allocate_i(lookup_allocate),
        .resolve_valid_i(resolve_valid),
        .resolve_branch_i(resolve_branch),
        .resolve_taken_i(resolve_taken),
        .prediction_taken_o(repeat_last_prediction),
        .fetch_stall_o(repeat_last_fetch),
        .decode_stall_o(repeat_last_decode)
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
            lookup_allocate = 1'b0;
        end
    endtask

    task automatic clear_resolve;
        begin
            resolve_valid = 1'b0;
            resolve_branch = 1'b0;
            resolve_taken = 1'b0;
        end
    endtask

    task automatic check_outputs;
        input logic [2:0] exp_stall;
        input logic [2:0] exp_always_branch;
        input logic [2:0] exp_always_decline;
        input logic [2:0] exp_repeat_last;
        input string label;
        begin
            #1;
            if ({stall_prediction, stall_fetch, stall_decode} !== exp_stall ||
                {always_branch_prediction, always_branch_fetch,
                 always_branch_decode} !== exp_always_branch ||
                {always_decline_prediction, always_decline_fetch,
                 always_decline_decode} !== exp_always_decline ||
                {repeat_last_prediction, repeat_last_fetch,
                 repeat_last_decode} !== exp_repeat_last) begin
                $fatal(1,
                    "%0s: stall=%03b/%03b branch=%03b/%03b decline=%03b/%03b repeat=%03b/%03b",
                    label,
                    {stall_prediction, stall_fetch, stall_decode}, exp_stall,
                    {always_branch_prediction, always_branch_fetch,
                     always_branch_decode}, exp_always_branch,
                    {always_decline_prediction, always_decline_fetch,
                     always_decline_decode}, exp_always_decline,
                    {repeat_last_prediction, repeat_last_fetch,
                     repeat_last_decode}, exp_repeat_last);
            end
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
        check_outputs(3'b000, 3'b000, 3'b000, 3'b000, "reset idle");

        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        check_outputs(3'b010, 3'b100, 3'b000, 3'b000,
                      "initial conditional prediction");

        lookup_allocate = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear_lookup();
        check_outputs(3'b011, 3'b000, 3'b000, 3'b000,
                      "stall policy holds unresolved branch");

        resolve_valid = 1'b1;
        resolve_branch = 1'b1;
        resolve_taken = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear_resolve();
        lookup_valid = 1'b1;
        lookup_branch = 1'b1;
        check_outputs(3'b010, 3'b100, 3'b000, 3'b100,
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
        check_outputs(3'b010, 3'b100, 3'b000, 3'b000,
                      "repeat-last learns not-taken");

        lookup_branch = 1'b0;
        lookup_jump = 1'b1;
        check_outputs(3'b010, 3'b100, 3'b100, 3'b100,
                      "direct jumps are known taken");

        lookup_indirect = 1'b1;
        check_outputs(3'b010, 3'b010, 3'b010, 3'b010,
                      "indirect jump stalls without target table");

        lookup_allocate = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear_lookup();
        check_outputs(3'b011, 3'b011, 3'b011, 3'b011,
                      "indirect jump remains held until resolve");

        flush = 1'b1;
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;
        check_outputs(3'b000, 3'b000, 3'b000, 3'b000,
                      "flush releases unresolved jump");

        $display("PASS: modular branch predictor policies");
        $finish;
    end

endmodule
