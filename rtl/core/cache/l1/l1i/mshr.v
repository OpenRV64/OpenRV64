`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// Combinational ownership/selection logic for the L1I demand-MSHR bank.
//
// State mutation remains in the L1I composition so existing verification can
// observe the bank at its current hierarchy. This module centralizes entry
// eligibility before the state updates are moved behind an event interface.
module openrv64_l1i_demand_mshr_select #(
    parameter integer ENTRIES = 4,
    parameter integer INDEX_WIDTH = (ENTRIES > 1) ? $clog2(ENTRIES) : 1,
    parameter integer ADDR_WIDTH = 64
) (
    input  wire [ENTRIES-1:0] valid_i,
    input  wire [ENTRIES-1:0] issued_i,
    input  wire [ENTRIES-1:0] complete_i,
    input  wire [ENTRIES-1:0] fill_done_i,
    input  wire [ENTRIES-1:0] error_i,
    input  wire [ENTRIES*ADDR_WIDTH-1:0] addr_i,
    input  wire [ADDR_WIDTH-1:0] miss_addr_i,
    input  wire response_for_icache_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] response_txn_id_i,

    output reg match_found_o,
    output reg [INDEX_WIDTH-1:0] match_index_o,
    output reg free_found_o,
    output reg [INDEX_WIDTH-1:0] free_index_o,
    output reg issue_found_o,
    output reg [INDEX_WIDTH-1:0] issue_index_o,
    output reg fill_found_o,
    output reg [INDEX_WIDTH-1:0] fill_index_o,
    output reg finalize_found_o,
    output reg [INDEX_WIDTH-1:0] finalize_index_o,
    output reg response_match_o,
    output reg [INDEX_WIDTH-1:0] response_index_o,
    output reg any_valid_o
);

    integer scan;
    reg [ADDR_WIDTH-1:0] scan_addr;

    always @* begin
        match_found_o = 1'b0;
        match_index_o = {INDEX_WIDTH{1'b0}};
        free_found_o = 1'b0;
        free_index_o = {INDEX_WIDTH{1'b0}};
        issue_found_o = 1'b0;
        issue_index_o = {INDEX_WIDTH{1'b0}};
        fill_found_o = 1'b0;
        fill_index_o = {INDEX_WIDTH{1'b0}};
        finalize_found_o = 1'b0;
        finalize_index_o = {INDEX_WIDTH{1'b0}};
        response_match_o = 1'b0;
        response_index_o = {INDEX_WIDTH{1'b0}};
        any_valid_o = 1'b0;
        scan_addr = {ADDR_WIDTH{1'b0}};

        for (scan = 0; scan < ENTRIES; scan = scan + 1) begin
            scan_addr = addr_i[scan*ADDR_WIDTH +: ADDR_WIDTH];

            if (valid_i[scan])
                any_valid_o = 1'b1;
            if (!match_found_o && valid_i[scan] &&
                (scan_addr == miss_addr_i)) begin
                match_found_o = 1'b1;
                match_index_o = INDEX_WIDTH'(scan);
            end
            if (!free_found_o && !valid_i[scan]) begin
                free_found_o = 1'b1;
                free_index_o = INDEX_WIDTH'(scan);
            end
            if (!issue_found_o && valid_i[scan] && !issued_i[scan] &&
                !complete_i[scan]) begin
                issue_found_o = 1'b1;
                issue_index_o = INDEX_WIDTH'(scan);
            end
            if (!fill_found_o && valid_i[scan] && complete_i[scan] &&
                !fill_done_i[scan] && !error_i[scan]) begin
                fill_found_o = 1'b1;
                fill_index_o = INDEX_WIDTH'(scan);
            end
            if (!finalize_found_o && valid_i[scan] && complete_i[scan] &&
                (fill_done_i[scan] || error_i[scan])) begin
                finalize_found_o = 1'b1;
                finalize_index_o = INDEX_WIDTH'(scan);
            end
            if (!response_match_o && valid_i[scan] && issued_i[scan] &&
                !complete_i[scan] && response_for_icache_i &&
                (response_txn_id_i ==
                 `OPENRV64_CCX_TXN_ID_WIDTH'(scan))) begin
                response_match_o = 1'b1;
                response_index_o = INDEX_WIDTH'(scan);
            end
        end
    end

endmodule
