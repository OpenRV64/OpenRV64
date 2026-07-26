`timescale 1ns/1ps

// Selection policy at the frontend completion-table boundary.
//
// Demand completions win over speculative prefetch bookkeeping. Within each
// class the lowest table index wins; architectural request age is represented
// by the caller's tags and is not reconstructed here.
module openrv64_l1i_frontend_select #(
    parameter integer DEPTH = 8,
    parameter integer INDEX_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  wire [DEPTH-1:0] valid_i,
    input  wire [DEPTH-1:0] complete_i,
    input  wire [DEPTH-1:0] prefetch_i,
    output reg free_found_o,
    output reg [INDEX_WIDTH-1:0] free_index_o,
    output reg complete_found_o,
    output reg [INDEX_WIDTH-1:0] complete_index_o
);

    integer scan;

    always @* begin
        free_found_o = 1'b0;
        free_index_o = {INDEX_WIDTH{1'b0}};
        complete_found_o = 1'b0;
        complete_index_o = {INDEX_WIDTH{1'b0}};

        for (scan = 0; scan < DEPTH; scan = scan + 1) begin
            if (!free_found_o && !valid_i[scan]) begin
                free_found_o = 1'b1;
                free_index_o = INDEX_WIDTH'(scan);
            end
            if (!complete_found_o && valid_i[scan] &&
                complete_i[scan] && !prefetch_i[scan]) begin
                complete_found_o = 1'b1;
                complete_index_o = INDEX_WIDTH'(scan);
            end
        end

        if (!complete_found_o) begin
            for (scan = 0; scan < DEPTH; scan = scan + 1) begin
                if (!complete_found_o && valid_i[scan] &&
                    complete_i[scan]) begin
                    complete_found_o = 1'b1;
                    complete_index_o = INDEX_WIDTH'(scan);
                end
            end
        end
    end

endmodule
