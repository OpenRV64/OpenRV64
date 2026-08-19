`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

// Passive simulation visibility boundary for the three-wide frontend.
/* verilator lint_off DECLFILENAME */
module openrv64_fetch_debug_stub #(
    parameter integer LINE_DEPTH = 4,
    parameter integer INGRESS_DEPTH = 4,
    parameter integer FETCH_SECTORS = 2
) (
    input wire [`RV64_XLEN-1:0] consume_pc_q
        /* verilator public_flat_rd */,
    input wire [`RV64_XLEN-1:0] next_req_addr_q
        /* verilator public_flat_rd */,
    input wire pending_valid_q /* verilator public_flat_rd */,
    input wire [`RV64_XLEN-1:0] pending_addr_q
        /* verilator public_flat_rd */,
    input wire pair_request_select /* verilator public_flat_rd */,
    input wire demand_request_needed /* verilator public_flat_rd */,
    input wire request_line_hit /* verilator public_flat_rd */,
    input wire request_line_pending /* verilator public_flat_rd */,
    input wire redirect_req_fire /* verilator public_flat_rd */,
    input wire pair_req_fire /* verilator public_flat_rd */,
    input wire redirect_line_pending_q /* verilator public_flat_rd */,
    input wire [`RV64_XLEN-1:0] redirect_line_addr_q
        /* verilator public_flat_rd */,
    input wire fal_line_pending_q /* verilator public_flat_rd */,
    input wire [`RV64_XLEN-1:0] fal_line_addr_q
        /* verilator public_flat_rd */,
    input wire alt_restart_context_match_r
        /* verilator public_flat_rd */,
    input wire alt_restart_target_pending_r
        /* verilator public_flat_rd */,
    input wire pair_predicted_valid_q /* verilator public_flat_rd */,
    input wire [`RV64_XLEN-1:0] pair_predicted_addr_q
        /* verilator public_flat_rd */,
    input wire pair_unpredicted_valid_q /* verilator public_flat_rd */,
    input wire [`RV64_XLEN-1:0] pair_unpredicted_addr_q
        /* verilator public_flat_rd */,
    input wire line_valid_q [0:LINE_DEPTH-1]
        /* verilator public_flat_rd */,
    input wire [FETCH_SECTORS-1:0]
        line_sector_valid_q [0:LINE_DEPTH-1]
        /* verilator public_flat_rd */,
    input wire [`RV64_XLEN-1:0] line_addr_q [0:LINE_DEPTH-1]
        /* verilator public_flat_rd */,
    input wire carousel_pending_valid_q [0:LINE_DEPTH-1]
        /* verilator public_flat_rd */,
    input wire [`RV64_XLEN-1:0]
        carousel_pending_addr_q [0:LINE_DEPTH-1]
        /* verilator public_flat_rd */,
    input wire ingress_valid_q [0:INGRESS_DEPTH-1]
        /* verilator public_flat_rd */,
    input wire [1:0] ingress_origin_q [0:INGRESS_DEPTH-1]
        /* verilator public_flat_rd */,
    input wire [`RV64_XLEN-1:0] ingress_addr_q [0:INGRESS_DEPTH-1]
        /* verilator public_flat_rd */
);
endmodule
/* verilator lint_on DECLFILENAME */
