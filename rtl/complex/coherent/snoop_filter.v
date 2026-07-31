`timescale 1ns/1ps

module openrv64_ccx_snoop_filter_way #(
    parameter integer SETS = 64,
    parameter integer SET_WIDTH = (SETS > 1) ? $clog2(SETS) : 1,
    parameter integer WORD_WIDTH = 1
) (
    input  wire                     clk_i,
    input  wire                     read_valid_i,
    input  wire [SET_WIDTH-1:0]     read_set_i,
    output reg  [WORD_WIDTH-1:0]    read_word_o,
    input  wire                     write_valid_i,
    input  wire [SET_WIDTH-1:0]     write_set_i,
    input  wire [WORD_WIDTH-1:0]    write_word_i
);

    reg [WORD_WIDTH-1:0] mem_q [0:SETS-1];
    reg [SET_WIDTH-1:0] read_set_q;

    always @(posedge clk_i) begin
        if (read_valid_i) begin
            read_set_q <= read_set_i;
            read_word_o <= mem_q[read_set_i];
        end
        if (write_valid_i) begin
            mem_q[write_set_i] <= write_word_i;
            // Keep the registered lookup image coherent with later
            // allocate/clear/record operations on that entry.
            if (read_set_q == write_set_i)
                read_word_o <= write_word_i;
        end
    end

endmodule

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

    input  wire                         lookup_valid_i,
    output wire                         lookup_ready_o,
    input  wire [ADDR_WIDTH-1:0]        lookup_line_addr_i,
    output wire                         lookup_response_valid_o,
    output wire                         init_busy_o,
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
    input  wire                         write_overwrite_i,
    input  wire [ENTRY_WIDTH-1:0]       write_entry_i,
    input  wire [ADDR_WIDTH-1:0]        write_line_addr_i,
    input  wire [NUM_HARTS-1:0]         write_add_i_sharers_i,
    input  wire [NUM_HARTS-1:0]         write_add_d_sharers_i,
    input  wire [NUM_HARTS-1:0]         write_clear_i_sharers_i,
    input  wire [NUM_HARTS-1:0]         write_clear_d_sharers_i
);

    localparam integer WORD_WIDTH =
        1 + TAG_WIDTH + (2 * NUM_HARTS);
    localparam integer D_SHARERS_LSB = 0;
    localparam integer I_SHARERS_LSB = NUM_HARTS;
    localparam integer TAG_LSB = 2 * NUM_HARTS;
    localparam integer VALID_BIT = WORD_WIDTH - 1;

    wire [WAYS*WORD_WIDTH-1:0] way_read_word;
    wire [WAY_WIDTH-1:0] replace_read;
    reg [SET_WIDTH-1:0] lookup_set_q;
    reg [TAG_WIDTH-1:0] lookup_tag_q;
    reg lookup_response_valid_q;
    reg init_busy_q;
    reg [SET_WIDTH-1:0] init_set_q;

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
    wire [WAY_WIDTH-1:0] write_way =
        write_entry_i[WAY_WIDTH-1:0];
    wire [WAY_WIDTH-1:0] replace_write =
        (write_way == WAY_WIDTH'(WAYS - 1)) ?
            {WAY_WIDTH{1'b0}} : write_way + 1'b1;
    wire lookup_fire = lookup_valid_i && lookup_ready_o;

    integer lookup_way;
    integer victim_way;
    integer victim_flat_index;
    reg victim_invalid_found;
    reg [WORD_WIDTH-1:0] lookup_way_word;
    reg [WORD_WIDTH-1:0] victim_way_word;
    reg [WORD_WIDTH-1:0] selected_write_way_word;
    reg [WORD_WIDTH-1:0] normal_write_word;

    assign lookup_ready_o = !init_busy_q && !write_valid_i;
    assign lookup_response_valid_o = lookup_response_valid_q;
    assign init_busy_o = init_busy_q;

    always @* begin
        selected_write_way_word =
            way_read_word[32'(write_way)*WORD_WIDTH +: WORD_WIDTH];
        if (write_allocate_i || write_overwrite_i) begin
            normal_write_word = {
                1'b1,
                write_tag,
                write_add_i_sharers_i &
                    ~write_clear_i_sharers_i,
                write_add_d_sharers_i &
                    ~write_clear_d_sharers_i
            };
        end else begin
            normal_write_word = selected_write_way_word;
            normal_write_word[
                I_SHARERS_LSB +: NUM_HARTS] =
                (selected_write_way_word[
                    I_SHARERS_LSB +: NUM_HARTS] |
                 write_add_i_sharers_i) &
                ~write_clear_i_sharers_i;
            normal_write_word[
                D_SHARERS_LSB +: NUM_HARTS] =
                (selected_write_way_word[
                    D_SHARERS_LSB +: NUM_HARTS] |
                 write_add_d_sharers_i) &
                ~write_clear_d_sharers_i;
        end
    end

    genvar way;
    generate
        for (way = 0; way < WAYS; way = way + 1) begin : g_way
            wire way_write_valid =
                init_busy_q ||
                (write_valid_i &&
                 (write_way == WAY_WIDTH'(way)));
            wire [SET_WIDTH-1:0] way_write_set =
                init_busy_q ? init_set_q : write_set;
            wire [WORD_WIDTH-1:0] way_write_word =
                init_busy_q ? {WORD_WIDTH{1'b0}} :
                              normal_write_word;

            openrv64_ccx_snoop_filter_way #(
                .SETS(SETS),
                .SET_WIDTH(SET_WIDTH),
                .WORD_WIDTH(WORD_WIDTH)
            ) u_way (
                .clk_i(clk_i),
                .read_valid_i(lookup_fire),
                .read_set_i(lookup_set),
                .read_word_o(
                    way_read_word[way*WORD_WIDTH +: WORD_WIDTH]),
                .write_valid_i(way_write_valid),
                .write_set_i(way_write_set),
                .write_word_i(way_write_word)
            );
        end
    endgenerate

    openrv64_ccx_snoop_filter_way #(
        .SETS(SETS),
        .SET_WIDTH(SET_WIDTH),
        .WORD_WIDTH(WAY_WIDTH)
    ) u_replace (
        .clk_i(clk_i),
        .read_valid_i(lookup_fire),
        .read_set_i(lookup_set),
        .read_word_o(replace_read),
        .write_valid_i(
            !init_busy_q && write_valid_i && write_allocate_i),
        .write_set_i(write_set),
        .write_word_i(replace_write)
    );

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
        victim_way = 32'(replace_read);
        for (lookup_way = 0; lookup_way < WAYS;
             lookup_way = lookup_way + 1) begin
            lookup_way_word =
                way_read_word[lookup_way*WORD_WIDTH +: WORD_WIDTH];
            if (lookup_way_word[VALID_BIT] &&
                (lookup_way_word[TAG_LSB +: TAG_WIDTH] ==
                 lookup_tag_q) &&
                !lookup_hit_o) begin
                lookup_hit_o = 1'b1;
                lookup_entry_o =
                    ENTRY_WIDTH'(
                        (32'(lookup_set_q) * WAYS) + lookup_way);
                lookup_i_sharers_o =
                    lookup_way_word[
                        I_SHARERS_LSB +: NUM_HARTS];
                lookup_d_sharers_o =
                    lookup_way_word[
                        D_SHARERS_LSB +: NUM_HARTS];
            end
            if (!lookup_way_word[VALID_BIT] &&
                !victim_invalid_found) begin
                victim_invalid_found = 1'b1;
                victim_way = lookup_way;
            end
        end

        victim_flat_index =
            (32'(lookup_set_q) * WAYS) + victim_way;
        victim_way_word =
            way_read_word[victim_way*WORD_WIDTH +: WORD_WIDTH];
        victim_entry_o = ENTRY_WIDTH'(victim_flat_index);
        victim_valid_o = victim_way_word[VALID_BIT];
        if (victim_way_word[VALID_BIT]) begin
            victim_line_addr_o = {
                victim_way_word[TAG_LSB +: TAG_WIDTH],
                lookup_set_q,
                {LINE_OFFSET_BITS{1'b0}}
            };
            victim_i_sharers_o =
                victim_way_word[I_SHARERS_LSB +: NUM_HARTS];
            victim_d_sharers_o =
                victim_way_word[D_SHARERS_LSB +: NUM_HARTS];
        end
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            lookup_response_valid_q <= 1'b0;
            lookup_set_q <= {SET_WIDTH{1'b0}};
            lookup_tag_q <= {TAG_WIDTH{1'b0}};
            init_busy_q <= 1'b1;
            init_set_q <= {SET_WIDTH{1'b0}};
        end else begin
            lookup_response_valid_q <= lookup_fire;
            if (lookup_fire) begin
                lookup_set_q <= lookup_set;
                lookup_tag_q <= lookup_tag;
            end

            if (init_busy_q) begin
                if (init_set_q == SET_WIDTH'(SETS - 1))
                    init_busy_q <= 1'b0;
                else
                    init_set_q <= init_set_q + 1'b1;
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
