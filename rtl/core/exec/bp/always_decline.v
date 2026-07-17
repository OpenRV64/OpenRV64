`ifndef OPENRV64_EXEC_BP_ALWAYS_DECLINE_V
`define OPENRV64_EXEC_BP_ALWAYS_DECLINE_V
`timescale 1ns/1ps

module openrv64_exec_bp_always_decline (
    input  wire lookup_jump_i,
    input  wire lookup_indirect_i,
    output wire prediction_taken_o
);

    // Conditional branches are always predicted not-taken.  A direct jump is
    // unconditional and has a decode-visible target, so it remains known-taken.
    assign prediction_taken_o = lookup_jump_i && !lookup_indirect_i;

endmodule

`endif
