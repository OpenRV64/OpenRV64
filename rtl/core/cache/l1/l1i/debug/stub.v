`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// Passive simulation visibility boundary for L1I request and MSHR state.
/* verilator lint_off DECLFILENAME */
module openrv64_l1i_debug_stub #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer REQ_TAG_WIDTH = 1,
    parameter integer DEMAND_DEPTH = 8,
    parameter integer DEMAND_MSHRS = 4,
    parameter integer DEMAND_INDEX_WIDTH =
        (DEMAND_DEPTH > 1) ? $clog2(DEMAND_DEPTH) : 1,
    parameter integer DEMAND_COUNT_WIDTH = $clog2(DEMAND_DEPTH + 1),
    parameter integer DEMAND_MSHR_INDEX_WIDTH =
        (DEMAND_MSHRS > 1) ? $clog2(DEMAND_MSHRS) : 1,
    parameter integer LINE_DATA_WIDTH = `OPENRV64_ICX_LINE_DATA_WIDTH
) (
    input wire icx_issue_fire /* verilator public_flat_rd */,
    input wire issue_active_q /* verilator public_flat_rd */,
    input wire [DEMAND_MSHR_INDEX_WIDTH-1:0] issue_index
        /* verilator public_flat_rd */,
    input wire [DEMAND_MSHR_INDEX_WIDTH-1:0] issue_mshr_q
        /* verilator public_flat_rd */,
    input wire l1_input_valid /* verilator public_flat_rd */,
    input wire l1_miss_fire /* verilator public_flat_rd */,
    input wire response_pop /* verilator public_flat_rd */,
    input wire [DEMAND_INDEX_WIDTH-1:0] response_pop_index
        /* verilator public_flat_rd */,
    input wire [DEMAND_DEPTH-1:0] response_valid_vec
        /* verilator public_flat_rd */,
    input wire [DEMAND_DEPTH-1:0] response_complete_vec
        /* verilator public_flat_rd */,
    input wire [DEMAND_DEPTH-1:0] response_prefetch_vec
        /* verilator public_flat_rd */,
    input wire [DEMAND_COUNT_WIDTH-1:0] response_count_q
        /* verilator public_flat_rd */,
    input wire response_free_found_r /* verilator public_flat_rd */,
    input wire [DEMAND_INDEX_WIDTH-1:0] response_free_index_r
        /* verilator public_flat_rd */,
    input wire response_complete_found_r /* verilator public_flat_rd */,
    input wire [DEMAND_INDEX_WIDTH-1:0] response_complete_index_r
        /* verilator public_flat_rd */,
    input wire output_stored_response /* verilator public_flat_rd */,
    input wire output_direct_response /* verilator public_flat_rd */,
    input wire l1_resp_valid /* verilator public_flat_rd */,
    input wire [DEMAND_INDEX_WIDTH-1:0] l1_resp_tag
        /* verilator public_flat_rd */,
    input wire [LINE_DATA_WIDTH-1:0] l1_req_rdata
        /* verilator public_flat_rd */,
    input wire [LINE_DATA_WIDTH-1:0] req_rdata_o
        /* verilator public_flat_rd */,
    input wire response_valid_q [0:DEMAND_DEPTH-1]
        /* verilator public_flat_rd */,
    input wire response_complete_q [0:DEMAND_DEPTH-1]
        /* verilator public_flat_rd */,
    input wire response_prefetch_q [0:DEMAND_DEPTH-1]
        /* verilator public_flat_rd */,
    input wire [REQ_TAG_WIDTH-1:0] response_tag_q [0:DEMAND_DEPTH-1]
        /* verilator public_flat_rd */,
    input wire [ADDR_WIDTH-1:0] response_vaddr_q [0:DEMAND_DEPTH-1]
        /* verilator public_flat_rd */,
    input wire response_wait_mshr_q [0:DEMAND_DEPTH-1]
        /* verilator public_flat_rd */,
    input wire [DEMAND_MSHR_INDEX_WIDTH-1:0]
        response_mshr_q [0:DEMAND_DEPTH-1]
        /* verilator public_flat_rd */,
    input wire [DEMAND_MSHRS-1:0] demand_mshr_valid_vec
        /* verilator public_flat_rd */,
    input wire [DEMAND_MSHRS-1:0] demand_mshr_issued_vec
        /* verilator public_flat_rd */,
    input wire [DEMAND_MSHRS-1:0] demand_mshr_complete_vec
        /* verilator public_flat_rd */,
    input wire [DEMAND_MSHRS-1:0] demand_mshr_fill_done_vec
        /* verilator public_flat_rd */,
    input wire demand_mshr_valid_q [0:DEMAND_MSHRS-1]
        /* verilator public_flat_rd */,
    input wire demand_mshr_issued_q [0:DEMAND_MSHRS-1]
        /* verilator public_flat_rd */,
    input wire demand_mshr_complete_q [0:DEMAND_MSHRS-1]
        /* verilator public_flat_rd */,
    input wire demand_mshr_fill_done_q [0:DEMAND_MSHRS-1]
        /* verilator public_flat_rd */,
    input wire demand_mshr_aged_q [0:DEMAND_MSHRS-1]
        /* verilator public_flat_rd */,
    input wire [ADDR_WIDTH-1:0] demand_mshr_addr_q [0:DEMAND_MSHRS-1]
        /* verilator public_flat_rd */,
    input wire demand_mshr_issue_found_r /* verilator public_flat_rd */,
    input wire [DEMAND_MSHR_INDEX_WIDTH-1:0] demand_mshr_issue_index_r
        /* verilator public_flat_rd */
);
endmodule
/* verilator lint_on DECLFILENAME */
