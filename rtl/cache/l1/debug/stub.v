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
        ADDR_WIDTH - $clog2(LINE_BYTES) - $clog2(SETS),
    parameter integer SYNC_TAG_LOOKUP = 0,
    parameter integer SYNC_STORE_EXTENSION = 0
) (
    input wire clk_i,
    input wire rst_ni,
    input wire [1:0] state_q /* verilator public_flat_rd */,
    input wire req_valid_i /* verilator public_flat_rd */,
    input wire req_ready_o /* verilator public_flat_rd */,
    input wire req_write_i /* verilator public_flat_rd */,
    input wire access_write /* verilator public_flat_rd */,
    input wire request_fire /* verilator public_flat_rd */,
    input wire response_fire /* verilator public_flat_rd */,
    input wire response_hit_fire /* verilator public_flat_rd */,
    input wire miss_fire /* verilator public_flat_rd */,
    input wire fill_valid_i /* verilator public_flat_rd */,
    input wire fill_ready_o /* verilator public_flat_rd */,
    input wire invalidate_valid_i /* verilator public_flat_rd */,
    input wire invalidate_ready_o /* verilator public_flat_rd */,
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
    input wire sync_fill_launch /* verilator public_flat_rd */,
    input wire sync_fill_probe_q /* verilator public_flat_rd */,
    input wire sync_store_extension_fire /* verilator public_flat_rd */,
    input wire sync_lookup_slot_available /* verilator public_flat_rd */,
    input wire sync_tag_port_available /* verilator public_flat_rd */,
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
    // Cumulative simulation-only event accounting. Reasons for a blocked
    // request are deliberately non-exclusive: the report must preserve
    // simultaneous pressure instead of assigning an arbitrary priority.
    reg [63:0] perf_cycles_q /* verilator public_flat_rd */;
    reg [63:0] perf_request_valid_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_request_wait_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_read_wait_cycles_q /* verilator public_flat_rd */;
    reg [63:0] perf_write_wait_cycles_q /* verilator public_flat_rd */;
    reg [63:0] perf_request_fire_q /* verilator public_flat_rd */;
    reg [63:0] perf_read_fire_q /* verilator public_flat_rd */;
    reg [63:0] perf_write_fire_q /* verilator public_flat_rd */;
    reg [63:0] perf_response_fire_q /* verilator public_flat_rd */;
    reg [63:0] perf_hit_response_q /* verilator public_flat_rd */;
    reg [63:0] perf_miss_fire_q /* verilator public_flat_rd */;
    reg [63:0] perf_fill_fire_q /* verilator public_flat_rd */;
    reg [63:0] perf_fill_wait_cycles_q /* verilator public_flat_rd */;
    reg [63:0] perf_fill_probe_launch_q /* verilator public_flat_rd */;
    reg [63:0] perf_fill_probe_cycles_q /* verilator public_flat_rd */;
    reg [63:0] perf_invalidate_fire_q /* verilator public_flat_rd */;
    reg [63:0] perf_invalidate_wait_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_invalidate_probe_launch_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_invalidate_probe_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lookup_occupied_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_access_cycles_q /* verilator public_flat_rd */;
    reg [63:0] perf_access_write_cycles_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_store_extension_fire_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_wait_fill_probe_q /* verilator public_flat_rd */;
    reg [63:0] perf_wait_invalidate_probe_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_wait_lookup_slot_q /* verilator public_flat_rd */;
    reg [63:0] perf_wait_tag_port_q /* verilator public_flat_rd */;
    reg [63:0] perf_wait_access_state_q /* verilator public_flat_rd */;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            perf_cycles_q <= 64'd0;
            perf_request_valid_cycles_q <= 64'd0;
            perf_request_wait_cycles_q <= 64'd0;
            perf_read_wait_cycles_q <= 64'd0;
            perf_write_wait_cycles_q <= 64'd0;
            perf_request_fire_q <= 64'd0;
            perf_read_fire_q <= 64'd0;
            perf_write_fire_q <= 64'd0;
            perf_response_fire_q <= 64'd0;
            perf_hit_response_q <= 64'd0;
            perf_miss_fire_q <= 64'd0;
            perf_fill_fire_q <= 64'd0;
            perf_fill_wait_cycles_q <= 64'd0;
            perf_fill_probe_launch_q <= 64'd0;
            perf_fill_probe_cycles_q <= 64'd0;
            perf_invalidate_fire_q <= 64'd0;
            perf_invalidate_wait_cycles_q <= 64'd0;
            perf_invalidate_probe_launch_q <= 64'd0;
            perf_invalidate_probe_cycles_q <= 64'd0;
            perf_lookup_occupied_cycles_q <= 64'd0;
            perf_access_cycles_q <= 64'd0;
            perf_access_write_cycles_q <= 64'd0;
            perf_store_extension_fire_q <= 64'd0;
            perf_wait_fill_probe_q <= 64'd0;
            perf_wait_invalidate_probe_q <= 64'd0;
            perf_wait_lookup_slot_q <= 64'd0;
            perf_wait_tag_port_q <= 64'd0;
            perf_wait_access_state_q <= 64'd0;
        end else begin
            perf_cycles_q <= perf_cycles_q + 1'b1;
            if (req_valid_i)
                perf_request_valid_cycles_q <=
                    perf_request_valid_cycles_q + 1'b1;
            if (req_valid_i && !req_ready_o) begin
                perf_request_wait_cycles_q <=
                    perf_request_wait_cycles_q + 1'b1;
                if (req_write_i)
                    perf_write_wait_cycles_q <=
                        perf_write_wait_cycles_q + 1'b1;
                else
                    perf_read_wait_cycles_q <=
                        perf_read_wait_cycles_q + 1'b1;
                if (sync_fill_probe_q)
                    perf_wait_fill_probe_q <=
                        perf_wait_fill_probe_q + 1'b1;
                if (sync_invalidate_probe_q)
                    perf_wait_invalidate_probe_q <=
                        perf_wait_invalidate_probe_q + 1'b1;
                if (!sync_lookup_slot_available)
                    perf_wait_lookup_slot_q <=
                        perf_wait_lookup_slot_q + 1'b1;
                if (!sync_tag_port_available)
                    perf_wait_tag_port_q <=
                        perf_wait_tag_port_q + 1'b1;
                if (state_q != 2'd0)
                    perf_wait_access_state_q <=
                        perf_wait_access_state_q + 1'b1;
            end
            if (request_fire) begin
                perf_request_fire_q <= perf_request_fire_q + 1'b1;
                if (req_write_i)
                    perf_write_fire_q <= perf_write_fire_q + 1'b1;
                else
                    perf_read_fire_q <= perf_read_fire_q + 1'b1;
            end
            if (response_fire)
                perf_response_fire_q <= perf_response_fire_q + 1'b1;
            if (response_hit_fire)
                perf_hit_response_q <= perf_hit_response_q + 1'b1;
            if (miss_fire)
                perf_miss_fire_q <= perf_miss_fire_q + 1'b1;
            if (fill_valid_i && !fill_ready_o)
                perf_fill_wait_cycles_q <=
                    perf_fill_wait_cycles_q + 1'b1;
            if (fill_valid_i && fill_ready_o)
                perf_fill_fire_q <= perf_fill_fire_q + 1'b1;
            if (sync_fill_launch)
                perf_fill_probe_launch_q <=
                    perf_fill_probe_launch_q + 1'b1;
            if (sync_fill_probe_q)
                perf_fill_probe_cycles_q <=
                    perf_fill_probe_cycles_q + 1'b1;
            if (invalidate_valid_i && !invalidate_ready_o)
                perf_invalidate_wait_cycles_q <=
                    perf_invalidate_wait_cycles_q + 1'b1;
            if (invalidate_valid_i && invalidate_ready_o)
                perf_invalidate_fire_q <=
                    perf_invalidate_fire_q + 1'b1;
            if (sync_invalidate_launch)
                perf_invalidate_probe_launch_q <=
                    perf_invalidate_probe_launch_q + 1'b1;
            if (sync_invalidate_probe_q)
                perf_invalidate_probe_cycles_q <=
                    perf_invalidate_probe_cycles_q + 1'b1;
            if (sync_lookup_valid_q)
                perf_lookup_occupied_cycles_q <=
                    perf_lookup_occupied_cycles_q + 1'b1;
            if (state_q == 2'd2) begin
                perf_access_cycles_q <= perf_access_cycles_q + 1'b1;
                if (access_write)
                    perf_access_write_cycles_q <=
                        perf_access_write_cycles_q + 1'b1;
            end
            if (sync_store_extension_fire)
                perf_store_extension_fire_q <=
                    perf_store_extension_fire_q + 1'b1;
        end
    end
endmodule
/* verilator lint_on DECLFILENAME */
