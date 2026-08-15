`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

// Passive simulation visibility boundary for return-stack diagnostics.
`ifndef SYNTHESIS
/* verilator lint_off DECLFILENAME */
module openrv64_ras_debug_stub #(
    parameter integer DEPTH = 8,
    parameter integer INDEX_WIDTH = $clog2(DEPTH),
    parameter integer COUNT_WIDTH = $clog2(DEPTH + 1)
) (
    input wire [`RV64_XLEN-1:0] stack_q [0:DEPTH-1]
        /* verilator public_flat_rd */,
    input wire [INDEX_WIDTH-1:0] sp_q /* verilator public_flat_rd */,
    input wire [COUNT_WIDTH-1:0] count_q /* verilator public_flat_rd */,
    input wire [COUNT_WIDTH-1:0] pending_calls_q
        /* verilator public_flat_rd */,
    input wire [INDEX_WIDTH-1:0] top_index
        /* verilator public_flat_rd */,
    input wire resolve_push /* verilator public_flat_rd */,
    input wire resolve_pop /* verilator public_flat_rd */,
    input wire pending_call_allocate /* verilator public_flat_rd */,
    input wire pending_call_resolve /* verilator public_flat_rd */
);
endmodule
/* verilator lint_on DECLFILENAME */
`endif
