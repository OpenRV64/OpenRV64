`ifndef OPENRV64_EXEC_BP_REPEAT_LAST_V
`define OPENRV64_EXEC_BP_REPEAT_LAST_V
`timescale 1ns/1ps

module openrv64_exec_bp_repeat_last (
    input  wire clk,
    input  wire rst_n,

    input  wire lookup_branch_i,
    input  wire lookup_jump_i,
    input  wire lookup_indirect_i,

    input  wire resolve_valid_i,
    input  wire resolve_branch_i,
    input  wire resolve_taken_i,

    output wire prediction_taken_o
);

    // One global history entry: the next conditional branch repeats the last
    // resolved conditional branch direction.  Reset starts at not-taken.
    reg last_taken_q;

    assign prediction_taken_o = (lookup_branch_i && last_taken_q) ||
                                (lookup_jump_i && !lookup_indirect_i);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_taken_q <= 1'b0;
        end else if (resolve_valid_i && resolve_branch_i) begin
            last_taken_q <= resolve_taken_i;
        end
    end

endmodule

`endif
