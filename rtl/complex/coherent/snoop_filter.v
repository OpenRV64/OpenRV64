`timescale 1ns/1ps

// Independently tagged directory for a non-inclusive coherent hierarchy.
//
// L2 residency is irrelevant to this table.  A valid entry records a
// conservative superset of private I$ and D$ sharers for one physical line.
// Clean private evictions may leave stale bits.  Before a valid victim entry
// is reused, the coherence frontend must probe every recorded sharer and wait
// for all responses; only then may it assert write_allocate_i for that entry.
module openrv64_ccx_snoop_filter #(
    parameter integer NUM_HARTS = 2,
    parameter integer ADDR_WIDTH = 64,
    parameter integer LINE_BYTES = 64,
    parameter integer ENTRIES = 256,
    parameter integer WAYS = 4,
    parameter integer SETS = ENTRIES / WAYS,
    parameter integer LINE_OFFSET_BITS = $clog2(LINE_BYTES),
    parameter integer SET_WIDTH = (SETS > 1) ? $clog2(SETS) : 1,
    parameter integer WAY_WIDTH = (WAYS > 1) ? $clog2(WAYS) : 1,
    parameter integer ENTRY_WIDTH =
        (ENTRIES > 1) ? $clog2(ENTRIES) : 1,
    parameter integer TAG_WIDTH =
        ADDR_WIDTH - LINE_OFFSET_BITS - $clog2(SETS)
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,

    input  wire [ADDR_WIDTH-1:0]        lookup_line_addr_i,
    output reg                          lookup_hit_o,
    output reg  [ENTRY_WIDTH-1:0]       lookup_entry_o,
    output reg  [NUM_HARTS-1:0]         lookup_i_sharers_o,
    output reg  [NUM_HARTS-1:0]         lookup_d_sharers_o,

    output reg                          victim_valid_o,
    output reg  [ENTRY_WIDTH-1:0]       victim_entry_o,
    output reg  [ADDR_WIDTH-1:0]        victim_line_addr_o,
    output reg  [NUM_HARTS-1:0]         victim_i_sharers_o,
    output reg  [NUM_HARTS-1:0]         victim_d_sharers_o,

    input  wire                         write_valid_i,
    input  wire                         write_allocate_i,
    input  wire [ENTRY_WIDTH-1:0]       write_entry_i,
    input  wire [ADDR_WIDTH-1:0]        write_line_addr_i,
    input  wire [NUM_HARTS-1:0]         write_add_i_sharers_i,
    input  wire [NUM_HARTS-1:0]         write_add_d_sharers_i,
    input  wire [NUM_HARTS-1:0]         write_clear_i_sharers_i,
    input  wire [NUM_HARTS-1:0]         write_clear_d_sharers_i
);

    reg valid_q [0:ENTRIES-1];
    reg [TAG_WIDTH-1:0] tag_q [0:ENTRIES-1];
    reg [NUM_HARTS-1:0] i_sharers_q [0:ENTRIES-1];
    reg [NUM_HARTS-1:0] d_sharers_q [0:ENTRIES-1];
    reg [WAY_WIDTH-1:0] replace_q [0:SETS-1];

    wire [SET_WIDTH-1:0] lookup_set =
        lookup_line_addr_i[LINE_OFFSET_BITS +: SET_WIDTH];
    wire [TAG_WIDTH-1:0] lookup_tag =
        lookup_line_addr_i[
            ADDR_WIDTH-1 -: TAG_WIDTH];
    wire [SET_WIDTH-1:0] write_set =
        write_line_addr_i[LINE_OFFSET_BITS +: SET_WIDTH];
    wire [TAG_WIDTH-1:0] write_tag =
        write_line_addr_i[
            ADDR_WIDTH-1 -: TAG_WIDTH];

    integer lookup_way;
    integer lookup_flat_index;
    integer victim_way;
    integer victim_flat_index;
    integer reset_entry;
    integer reset_set;
    reg victim_invalid_found;

    always @* begin
        lookup_hit_o = 1'b0;
        lookup_entry_o = {ENTRY_WIDTH{1'b0}};
        lookup_i_sharers_o = {NUM_HARTS{1'b0}};
        lookup_d_sharers_o = {NUM_HARTS{1'b0}};

        victim_valid_o = 1'b0;
        victim_entry_o = {ENTRY_WIDTH{1'b0}};
        victim_line_addr_o = {ADDR_WIDTH{1'b0}};
        victim_i_sharers_o = {NUM_HARTS{1'b0}};
        victim_d_sharers_o = {NUM_HARTS{1'b0}};
        victim_flat_index = 0;
        victim_invalid_found = 1'b0;

        // Prefer an invalid way for allocation.  If every way is valid, use
        // the per-set round-robin victim.
        victim_way = 32'(replace_q[lookup_set]);
        for (lookup_way = 0; lookup_way < WAYS;
             lookup_way = lookup_way + 1) begin
            lookup_flat_index = (32'(lookup_set) * WAYS) + lookup_way;
            if (valid_q[lookup_flat_index] &&
                (tag_q[lookup_flat_index] == lookup_tag) &&
                !lookup_hit_o) begin
                lookup_hit_o = 1'b1;
                lookup_entry_o =
                    ENTRY_WIDTH'(lookup_flat_index);
                lookup_i_sharers_o =
                    i_sharers_q[lookup_flat_index];
                lookup_d_sharers_o =
                    d_sharers_q[lookup_flat_index];
            end
            if (!valid_q[lookup_flat_index] &&
                !victim_invalid_found) begin
                victim_invalid_found = 1'b1;
                victim_way = lookup_way;
            end
        end

        victim_flat_index = (32'(lookup_set) * WAYS) + victim_way;
        victim_entry_o = ENTRY_WIDTH'(victim_flat_index);
        victim_valid_o = valid_q[victim_flat_index];
        if (valid_q[victim_flat_index]) begin
            victim_line_addr_o = {
                tag_q[victim_flat_index],
                lookup_set,
                {LINE_OFFSET_BITS{1'b0}}
            };
            victim_i_sharers_o = i_sharers_q[victim_flat_index];
            victim_d_sharers_o = d_sharers_q[victim_flat_index];
        end
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (reset_entry = 0; reset_entry < ENTRIES;
                 reset_entry = reset_entry + 1)
                valid_q[reset_entry] <= 1'b0;
            for (reset_set = 0; reset_set < SETS;
                 reset_set = reset_set + 1)
                replace_q[reset_set] <= {WAY_WIDTH{1'b0}};
        end else if (write_valid_i) begin
            if (write_allocate_i) begin
                valid_q[write_entry_i] <= 1'b1;
                tag_q[write_entry_i] <= write_tag;
                i_sharers_q[write_entry_i] <=
                    write_add_i_sharers_i &
                    ~write_clear_i_sharers_i;
                d_sharers_q[write_entry_i] <=
                    write_add_d_sharers_i &
                    ~write_clear_d_sharers_i;
                if (write_entry_i ==
                    ENTRY_WIDTH'((32'(write_set) * WAYS) +
                                 (WAYS - 1)))
                    replace_q[write_set] <= {WAY_WIDTH{1'b0}};
                else
                    replace_q[write_set] <=
                        write_entry_i[WAY_WIDTH-1:0] + 1'b1;
            end else begin
                i_sharers_q[write_entry_i] <=
                    (i_sharers_q[write_entry_i] |
                     write_add_i_sharers_i) &
                    ~write_clear_i_sharers_i;
                d_sharers_q[write_entry_i] <=
                    (d_sharers_q[write_entry_i] |
                     write_add_d_sharers_i) &
                    ~write_clear_d_sharers_i;
            end
        end
    end

    generate
        if ((NUM_HARTS != 2) && (NUM_HARTS != 4)) begin : g_bad_harts
            initial
                $fatal(1, "snoop filter supports NUM_HARTS=2 or 4");
        end
        if ((ENTRIES < 1) || (WAYS < 1) || (SETS < 2) ||
            ((ENTRIES % WAYS) != 0) ||
            ((WAYS & (WAYS - 1)) != 0) ||
            ((SETS & (SETS - 1)) != 0)) begin : g_bad_geometry
            initial
                $fatal(1,
                       "snoop filter requires power-of-two sets/ways");
        end
        if (LINE_BYTES != 64) begin : g_bad_line
            initial
                $fatal(1, "coherent protocol requires 64-byte lines");
        end
    endgenerate

endmodule
