`ifndef OPENRV64_EXEC_BP_ALWAYS_BRANCH_V
`define OPENRV64_EXEC_BP_ALWAYS_BRANCH_V
`timescale 1ns/1ps

module openrv64_exec_bp_always_branch (
    input  wire lookup_branch_i,
    input  wire lookup_jump_i,
    input  wire lookup_indirect_i,
    output wire prediction_taken_o
);

    // Conditional branches are always predicted taken.  Direct jumps are
    // known-taken regardless of direction policy; indirect jumps need a BTB
    // and are therefore left to the wrapper's stall path.
    assign prediction_taken_o = lookup_branch_i ||
                                (lookup_jump_i && !lookup_indirect_i);

endmodule

`endif
