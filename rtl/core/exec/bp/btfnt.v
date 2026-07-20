`ifndef OPENRV64_EXEC_BP_BTFNT_V
`define OPENRV64_EXEC_BP_BTFNT_V
`timescale 1ns/1ps

// Static direction prediction: backward conditional branches are taken and
// forward conditional branches are not taken.  Direct jumps remain known
// taken; targetless indirect jumps are stalled by the common BP wrapper.
module openrv64_exec_bp_btfnt (
    input  wire lookup_branch_i,
    input  wire lookup_jump_i,
    input  wire lookup_indirect_i,
    input  wire lookup_backward_i,

    output wire prediction_taken_o
);

    assign prediction_taken_o =
        (lookup_branch_i && lookup_backward_i) ||
        (lookup_jump_i && !lookup_indirect_i);

endmodule

`endif
