`timescale 1ns/1ps

// Passive simulation visibility boundary for the generic L1 array engine.
/* verilator lint_off DECLFILENAME */
module openrv64_l1_debug_stub #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 64,
    parameter integer REFILL_DATA_WIDTH = DATA_WIDTH,
    parameter integer REQ_TAG_WIDTH = 1,
    parameter integer CACHE_BYTES = 16 * 1024,
    parameter integer LINE_BYTES = 64,
    parameter integer WAYS = 8,
    parameter integer SETS = CACHE_BYTES / (LINE_BYTES * WAYS),
    parameter integer TOTAL_LINES = CACHE_BYTES / LINE_BYTES,
    parameter integer REFILLS_PER_LINE =
        LINE_BYTES / (REFILL_DATA_WIDTH / 8),
    parameter integer WORDS_PER_REFILL = REFILL_DATA_WIDTH / DATA_WIDTH,
    parameter integer REFILLS_PER_WAY = SETS * REFILLS_PER_LINE,
    parameter integer SET_INDEX_WIDTH = (SETS > 1) ? $clog2(SETS) : 1,
    parameter integer WAY_INDEX_WIDTH = (WAYS > 1) ? $clog2(WAYS) : 1,
    parameter integer LINE_INDEX_WIDTH =
        (TOTAL_LINES > 1) ? $clog2(TOTAL_LINES) : 1,
    parameter integer TAG_BITS =
        ADDR_WIDTH - $clog2(LINE_BYTES) - $clog2(SETS)
) (
    input wire [1:0] state_q /* verilator public_flat_rd */,
    input wire request_fire /* verilator public_flat_rd */,
    input wire [REQ_TAG_WIDTH-1:0] response_tag_q
        /* verilator public_flat_rd */,
    input wire response_valid_q /* verilator public_flat_rd */,
    input wire access_updates_line_q /* verilator public_flat_rd */,
    input wire [SET_INDEX_WIDTH-1:0] access_set_q
        /* verilator public_flat_rd */,
    input wire [WAY_INDEX_WIDTH-1:0] access_way_q
        /* verilator public_flat_rd */,
    input wire fill_fire /* verilator public_flat_rd */,
    input wire [SET_INDEX_WIDTH-1:0] fill_set
        /* verilator public_flat_rd */,
    input wire [WAY_INDEX_WIDTH-1:0] fill_way
        /* verilator public_flat_rd */,
    input wire [LINE_INDEX_WIDTH-1:0] fill_line
        /* verilator public_flat_rd */,
    input wire [DATA_WIDTH-1:0] response_data_q
        /* verilator public_flat_rd */,
    input wire response_hit_q /* verilator public_flat_rd */,
    input wire [WAY_INDEX_WIDTH-1:0] response_way_q
        /* verilator public_flat_rd */,
    input wire sync_lookup_valid_q /* verilator public_flat_rd */,
    input wire sync_lookup_hit_comb /* verilator public_flat_rd */,
    input wire [DATA_WIDTH-1:0] sync_lookup_hit_data
        /* verilator public_flat_rd */,
    input wire sync_lookup_hit_response /* verilator public_flat_rd */,
    input wire [SET_INDEX_WIDTH-1:0] sync_lookup_set_q
        /* verilator public_flat_rd */,
    input wire [TAG_BITS-1:0] sync_lookup_tag_q
        /* verilator public_flat_rd */,
    input wire [WAYS-1:0] sync_lookup_valid_bits_q
        /* verilator public_flat_rd */,
    input wire [WAY_INDEX_WIDTH-1:0] sync_lookup_way_comb
        /* verilator public_flat_rd */,
    input wire sync_invalidate_launch /* verilator public_flat_rd */,
    input wire sync_invalidate_probe_q /* verilator public_flat_rd */,
    input wire sync_tag_read_fire /* verilator public_flat_rd */,
    input wire [SET_INDEX_WIDTH-1:0] sync_tag_read_set
        /* verilator public_flat_rd */,
    input wire [ADDR_WIDTH-1:0] sync_invalidate_addr_q
        /* verilator public_flat_rd */,
    input wire [SET_INDEX_WIDTH-1:0] sync_invalidate_set_q
        /* verilator public_flat_rd */,
    input wire [TAG_BITS-1:0] sync_invalidate_tag_q
        /* verilator public_flat_rd */,
    input wire [WAYS-1:0] sync_invalidate_valid_bits_q
        /* verilator public_flat_rd */,
    input wire [TAG_BITS-1:0] sync_tag_read_q [0:WAYS-1]
        /* verilator public_flat_rd */,
    input wire valid_q [0:TOTAL_LINES-1]
        /* verilator public_flat_rd */,
    input wire [TAG_BITS-1:0] tag_mem [0:WAYS-1][0:SETS-1]
        /* verilator public_flat_rd */,
    input wire [DATA_WIDTH-1:0] data_mem
        [0:WAYS-1][0:WORDS_PER_REFILL-1][0:REFILLS_PER_WAY-1]
        /* verilator public_flat_rd */
);
endmodule
/* verilator lint_on DECLFILENAME */
