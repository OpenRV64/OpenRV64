`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// Passive simulation visibility boundary for an L1D probe endpoint.
/* verilator lint_off DECLFILENAME */
module openrv64_probe_endpoint_debug_stub #(
    parameter integer TIMEOUT_WIDTH = 11
) (
    input wire invalidate_pending_q /* verilator public_flat_rd */,
    input wire response_valid_q /* verilator public_flat_rd */,
    input wire [`OPENRV64_ICX_PROBE_ID_WIDTH-1:0] response_id_q
        /* verilator public_flat_rd */,
    input wire [TIMEOUT_WIDTH-1:0] timeout_q
        /* verilator public_flat_rd */
);
endmodule
/* verilator lint_on DECLFILENAME */
