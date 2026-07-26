`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// Combinational ownership/selection logic for the demand MSHR bank.
//
// State mutation remains in the L1D composition block for now. Keeping every
// selector in one module establishes a single definition of entry eligibility
// before the state RAM and event updates are moved behind this interface.
module openrv64_l1d_demand_mshr_select #(
    parameter integer ENTRIES = 3,
    parameter integer INDEX_WIDTH = (ENTRIES > 1) ? $clog2(ENTRIES) : 1,
    parameter integer EPOCH_WIDTH = 8
) (
    input  wire [ENTRIES-1:0] valid_i,
    input  wire [ENTRIES-1:0] issued_i,
    input  wire [ENTRIES-1:0] complete_i,
    input  wire [ENTRIES-1:0] fill_done_i,
    input  wire [ENTRIES-1:0] error_i,
    input  wire [ENTRIES-1:0] wait_prefetch_i,
    input  wire [ENTRIES*64-1:0] addr_i,
    input  wire [ENTRIES*`OPENRV64_CCX_TXN_ID_WIDTH-1:0] txn_id_i,
    input  wire [ENTRIES*EPOCH_WIDTH-1:0] epoch_i,

    input  wire [63:0] miss_addr_i,
    input  wire [EPOCH_WIDTH-1:0] current_epoch_i,
    input  wire response_for_dcache_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] response_txn_id_i,
    input  wire prefetch_response_match_i,
    input  wire [63:0] prefetch_response_addr_i,

    output reg match_found_o,
    output reg [INDEX_WIDTH-1:0] match_index_o,
    output reg free_found_o,
    output reg [INDEX_WIDTH-1:0] free_index_o,
    output reg issue_found_o,
    output reg [INDEX_WIDTH-1:0] issue_index_o,
    output reg response_match_o,
    output reg [INDEX_WIDTH-1:0] response_index_o,
    output reg fill_found_o,
    output reg [INDEX_WIDTH-1:0] fill_index_o,
    output reg prefetch_response_match_o,
    output reg [INDEX_WIDTH-1:0] prefetch_response_index_o,
    output reg any_valid_o
);

    integer scan;
    reg [63:0] scan_addr;
    reg [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] scan_txn_id;
    reg [EPOCH_WIDTH-1:0] scan_epoch;

    always @* begin
        match_found_o = 1'b0;
        match_index_o = {INDEX_WIDTH{1'b0}};
        free_found_o = 1'b0;
        free_index_o = {INDEX_WIDTH{1'b0}};
        issue_found_o = 1'b0;
        issue_index_o = {INDEX_WIDTH{1'b0}};
        response_match_o = 1'b0;
        response_index_o = {INDEX_WIDTH{1'b0}};
        fill_found_o = 1'b0;
        fill_index_o = {INDEX_WIDTH{1'b0}};
        prefetch_response_match_o = 1'b0;
        prefetch_response_index_o = {INDEX_WIDTH{1'b0}};
        any_valid_o = 1'b0;
        scan_addr = 64'd0;
        scan_txn_id = {`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}};
        scan_epoch = {EPOCH_WIDTH{1'b0}};

        for (scan = 0; scan < ENTRIES; scan = scan + 1) begin
            scan_addr = addr_i[scan*64 +: 64];
            scan_txn_id =
                txn_id_i[scan*`OPENRV64_CCX_TXN_ID_WIDTH +:
                         `OPENRV64_CCX_TXN_ID_WIDTH];
            scan_epoch =
                epoch_i[scan*EPOCH_WIDTH +: EPOCH_WIDTH];

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
                !complete_i[scan] && !wait_prefetch_i[scan]) begin
                issue_found_o = 1'b1;
                issue_index_o = INDEX_WIDTH'(scan);
            end
            if (!response_match_o && valid_i[scan] && issued_i[scan] &&
                !complete_i[scan] && response_for_dcache_i &&
                (scan_txn_id == response_txn_id_i)) begin
                response_match_o = 1'b1;
                response_index_o = INDEX_WIDTH'(scan);
            end
            if (!fill_found_o && valid_i[scan] && complete_i[scan] &&
                !fill_done_i[scan] && !error_i[scan] &&
                (scan_epoch == current_epoch_i)) begin
                fill_found_o = 1'b1;
                fill_index_o = INDEX_WIDTH'(scan);
            end
            if (!prefetch_response_match_o &&
                prefetch_response_match_i && valid_i[scan] &&
                wait_prefetch_i[scan] &&
                (scan_addr == prefetch_response_addr_i)) begin
                prefetch_response_match_o = 1'b1;
                prefetch_response_index_o = INDEX_WIDTH'(scan);
            end
        end
    end

endmodule
