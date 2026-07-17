`ifndef OPENRV64_EXEC_BP_STALL_V
`define OPENRV64_EXEC_BP_STALL_V
`timescale 1ns/1ps

// No speculation.  The wrapper interlocks every control transfer until EX.
module openrv64_exec_bp_stall (
    output wire prediction_taken_o
);

    assign prediction_taken_o = 1'b0;

endmodule

`endif
