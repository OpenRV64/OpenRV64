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
    input wire clk_i,
    input wire rst_ni,
    input wire icx_issue_fire /* verilator public_flat_rd */,
    input wire issue_active_q /* verilator public_flat_rd */,
    input wire [DEMAND_MSHR_INDEX_WIDTH-1:0] issue_index
        /* verilator public_flat_rd */,
    input wire [DEMAND_MSHR_INDEX_WIDTH-1:0] issue_mshr_q
        /* verilator public_flat_rd */,
    input wire l1_input_valid /* verilator public_flat_rd */,
    input wire l1_miss_valid /* verilator public_flat_rd */,
    input wire l1_miss_ready /* verilator public_flat_rd */,
    input wire l1_miss_fire /* verilator public_flat_rd */,
    input wire demand_mshr_match_found_r /* verilator public_flat_rd */,
    input wire response_fire /* verilator public_flat_rd */,
    input wire l1_fill_valid /* verilator public_flat_rd */,
    input wire l1_fill_ready /* verilator public_flat_rd */,
    input wire l1_fill_fire /* verilator public_flat_rd */,
    input wire demand_mshr_finalize_found_r
        /* verilator public_flat_rd */,
    input wire invalidate_valid_i /* verilator public_flat_rd */,
    input wire invalidate_ready_o /* verilator public_flat_rd */,
    input wire l1_invalidate_valid /* verilator public_flat_rd */,
    input wire l1_invalidate_ready /* verilator public_flat_rd */,
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
    reg [63:0] perf_mshr_alloc_q /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_merge_q /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_miss_wait_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_occupancy_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_full_cycles_q /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_max_occupancy_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_issue_q /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_lower_response_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_fill_q /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_fill_wait_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_mshr_finalize_q /* verilator public_flat_rd */;
    reg [63:0] perf_invalidate_wait_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_invalidate_launch_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_invalidate_inner_wait_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_invalidate_complete_q
        /* verilator public_flat_rd */;
    reg invalidate_active_q;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            perf_mshr_alloc_q <= 64'd0;
            perf_mshr_merge_q <= 64'd0;
            perf_mshr_miss_wait_cycles_q <= 64'd0;
            perf_mshr_occupancy_cycles_q <= 64'd0;
            perf_mshr_full_cycles_q <= 64'd0;
            perf_mshr_max_occupancy_q <= 64'd0;
            perf_mshr_issue_q <= 64'd0;
            perf_mshr_lower_response_q <= 64'd0;
            perf_mshr_fill_q <= 64'd0;
            perf_mshr_fill_wait_cycles_q <= 64'd0;
            perf_mshr_finalize_q <= 64'd0;
            perf_invalidate_wait_cycles_q <= 64'd0;
            perf_invalidate_launch_q <= 64'd0;
            perf_invalidate_inner_wait_cycles_q <= 64'd0;
            perf_invalidate_complete_q <= 64'd0;
            invalidate_active_q <= 1'b0;
        end else begin
            if (l1_miss_fire && demand_mshr_match_found_r)
                perf_mshr_merge_q <= perf_mshr_merge_q + 1'b1;
            if (l1_miss_fire && !demand_mshr_match_found_r)
                perf_mshr_alloc_q <= perf_mshr_alloc_q + 1'b1;
            if (l1_miss_valid && !l1_miss_ready)
                perf_mshr_miss_wait_cycles_q <=
                    perf_mshr_miss_wait_cycles_q + 1'b1;
            perf_mshr_occupancy_cycles_q <=
                perf_mshr_occupancy_cycles_q +
                $countones(demand_mshr_valid_vec);
            if (&demand_mshr_valid_vec)
                perf_mshr_full_cycles_q <=
                    perf_mshr_full_cycles_q + 1'b1;
            if ($countones(demand_mshr_valid_vec) >
                perf_mshr_max_occupancy_q)
                perf_mshr_max_occupancy_q <=
                    $countones(demand_mshr_valid_vec);
            if (icx_issue_fire)
                perf_mshr_issue_q <= perf_mshr_issue_q + 1'b1;
            if (response_fire)
                perf_mshr_lower_response_q <=
                    perf_mshr_lower_response_q + 1'b1;
            if (l1_fill_fire)
                perf_mshr_fill_q <= perf_mshr_fill_q + 1'b1;
            if (l1_fill_valid && !l1_fill_ready)
                perf_mshr_fill_wait_cycles_q <=
                    perf_mshr_fill_wait_cycles_q + 1'b1;
            if (demand_mshr_finalize_found_r)
                perf_mshr_finalize_q <= perf_mshr_finalize_q + 1'b1;
            if (invalidate_valid_i && !invalidate_ready_o)
                perf_invalidate_wait_cycles_q <=
                    perf_invalidate_wait_cycles_q + 1'b1;
            if (l1_invalidate_valid && !invalidate_active_q) begin
                perf_invalidate_launch_q <=
                    perf_invalidate_launch_q + 1'b1;
                invalidate_active_q <= 1'b1;
            end
            if (l1_invalidate_valid && !l1_invalidate_ready)
                perf_invalidate_inner_wait_cycles_q <=
                    perf_invalidate_inner_wait_cycles_q + 1'b1;
            if (l1_invalidate_valid && l1_invalidate_ready) begin
                perf_invalidate_complete_q <=
                    perf_invalidate_complete_q + 1'b1;
                invalidate_active_q <= 1'b0;
            end else if (!l1_invalidate_valid) begin
                invalidate_active_q <= 1'b0;
            end
        end
    end
endmodule
/* verilator lint_on DECLFILENAME */
