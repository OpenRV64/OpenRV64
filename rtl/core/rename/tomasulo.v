`ifndef OPENRV64_RENAME_TOMASULO_V
`define OPENRV64_RENAME_TOMASULO_V

`timescale 1ns/1ps

// Dynamic architectural-to-physical rename layer: speculative RAT plus a
// physical-tag free list.  destination_valid_i is an issue/allocation fire,
// not an offer.  The caller must wait for destination_ready_o before firing a
// group with register destinations.
//
// Sources and destinations are ordered by lane.  A source in lane N observes
// an older destination in lane 0..N-1, and repeated destinations return the
// mapping installed by the preceding lane as their old tag.  This makes one
// three-wide call equivalent to three program-order scalar rename operations.
module openrv64_rename_tomasulo #(
    parameter integer ARCH_ADDR_WIDTH = 5,
    parameter integer ARCH_REG_COUNT = 32,
    parameter integer PHYS_ADDR_WIDTH = 6,
    // Writable physical tags p1..pPHYS_REG_COUNT; p0 remains structural zero.
    parameter integer PHYS_REG_COUNT = 63,
    parameter integer LANES = 3,
    parameter integer SOURCES_PER_LANE = 2,
    parameter integer FREE_PORTS = 2,
    parameter integer FREE_LIST_DEPTH = 64,
    parameter integer FREE_COUNT_WIDTH = $clog2(FREE_LIST_DEPTH + 1)
) (
    input  wire                                  clk,
    input  wire                                  rst_n,

    input  wire [LANES*SOURCES_PER_LANE*ARCH_ADDR_WIDTH-1:0]
                                                source_arch_i,
    output wire [LANES*SOURCES_PER_LANE*PHYS_ADDR_WIDTH-1:0]
                                                source_phys_o,
    output wire [LANES*SOURCES_PER_LANE-1:0]    source_ready_o,

    // request is the candidate group used for capacity; valid is the subset
    // that actually fires on this edge.
    input  wire [LANES-1:0]                    destination_request_i,
    input  wire [LANES-1:0]                    destination_valid_i,
    input  wire [LANES*ARCH_ADDR_WIDTH-1:0]    destination_arch_i,
    output wire                                destination_ready_o,
    output wire [LANES*PHYS_ADDR_WIDTH-1:0]    destination_new_phys_o,
    output wire [LANES*PHYS_ADDR_WIDTH-1:0]    destination_old_phys_o,

    input  wire [FREE_PORTS-1:0]               free_valid_i,
    input  wire [FREE_PORTS*PHYS_ADDR_WIDTH-1:0] free_tag_i,
    input  wire [FREE_PORTS-1:0]               write_valid_i,
    input  wire [FREE_PORTS*PHYS_ADDR_WIDTH-1:0] write_tag_i,
    output wire [FREE_COUNT_WIDTH-1:0]         free_count_o
);

    localparam integer INITIAL_FREE_BASE = ARCH_REG_COUNT;
    localparam integer INITIAL_FREE_COUNT =
        PHYS_REG_COUNT - (ARCH_REG_COUNT - 1);

    reg [PHYS_ADDR_WIDTH-1:0] rat_q [0:ARCH_REG_COUNT-1];
    reg [PHYS_REG_COUNT:0] phys_ready_q;
    wire [LANES-1:0] free_pop_valid;
    wire [LANES*PHYS_ADDR_WIDTH-1:0] free_pop_tag;
    reg [LANES-1:0] free_pop_req;
    wire [FREE_COUNT_WIDTH-1:0] free_count;

    reg [LANES*SOURCES_PER_LANE*PHYS_ADDR_WIDTH-1:0] source_phys_r;
    reg [LANES*SOURCES_PER_LANE-1:0] source_ready_r;
    reg [LANES*PHYS_ADDR_WIDTH-1:0] destination_new_phys_r;
    reg [LANES*PHYS_ADDR_WIDTH-1:0] destination_old_phys_r;
    integer lane;
    integer source;
    integer prior_lane;
    integer allocation_rank;
    integer destination_request_count;
    integer destination_fire_count;
    reg [ARCH_ADDR_WIDTH-1:0] source_arch;
    reg [ARCH_ADDR_WIDTH-1:0] destination_arch;
    reg [PHYS_ADDR_WIDTH-1:0] mapped_phys;
    reg mapped_from_candidate;

    always @* begin
        source_phys_r =
            {LANES*SOURCES_PER_LANE*PHYS_ADDR_WIDTH{1'b0}};
        source_ready_r = {LANES*SOURCES_PER_LANE{1'b0}};
        destination_new_phys_r = {LANES*PHYS_ADDR_WIDTH{1'b0}};
        destination_old_phys_r = {LANES*PHYS_ADDR_WIDTH{1'b0}};
        free_pop_req = {LANES{1'b0}};
        destination_request_count = 0;
        destination_fire_count = 0;

        // Allocate packed free-list entries to the valid destination lanes.
        // destination_valid_i is already the fire mask, so this pop mask is a
        // contiguous prefix even when non-writing lanes create holes.
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            destination_arch = destination_arch_i[
                lane*ARCH_ADDR_WIDTH +: ARCH_ADDR_WIDTH];
            allocation_rank = 0;
            for (prior_lane = 0; prior_lane < lane;
                 prior_lane = prior_lane + 1) begin
                if (destination_request_i[prior_lane])
                    allocation_rank = allocation_rank + 1;
            end

            destination_new_phys_r[
                lane*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH] = free_pop_tag[
                    allocation_rank*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH];

            mapped_phys = rat_q[destination_arch];
            for (prior_lane = 0; prior_lane < lane;
                 prior_lane = prior_lane + 1) begin
                if (destination_request_i[prior_lane] &&
                    (destination_arch_i[
                        prior_lane*ARCH_ADDR_WIDTH +: ARCH_ADDR_WIDTH] ==
                     destination_arch)) begin
                    mapped_phys = destination_new_phys_r[
                        prior_lane*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH];
                end
            end
            destination_old_phys_r[
                lane*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH] = mapped_phys;

            if (destination_request_i[lane])
                destination_request_count = destination_request_count + 1;
            if (destination_valid_i[lane])
                destination_fire_count = destination_fire_count + 1;
        end

        if (free_count >=
            destination_request_count[FREE_COUNT_WIDTH-1:0]) begin
            for (lane = 0; lane < LANES; lane = lane + 1) begin
                if (lane < destination_fire_count)
                    free_pop_req[lane] = 1'b1;
            end
        end

        // Apply older lanes' just-allocated mappings to younger sources.
        for (source = 0; source < LANES*SOURCES_PER_LANE;
             source = source + 1) begin
            source_arch = source_arch_i[
                source*ARCH_ADDR_WIDTH +: ARCH_ADDR_WIDTH];
            mapped_phys = rat_q[source_arch];
            mapped_from_candidate = 1'b0;
            for (prior_lane = 0;
                 prior_lane < (source / SOURCES_PER_LANE);
                 prior_lane = prior_lane + 1) begin
                if (destination_request_i[prior_lane] &&
                    (destination_arch_i[
                        prior_lane*ARCH_ADDR_WIDTH +: ARCH_ADDR_WIDTH] ==
                     source_arch)) begin
                    mapped_phys = destination_new_phys_r[
                        prior_lane*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH];
                    mapped_from_candidate = 1'b1;
                end
            end
            source_phys_r[source*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH] =
                mapped_phys;
            source_ready_r[source] = !mapped_from_candidate &&
                ((mapped_phys == {PHYS_ADDR_WIDTH{1'b0}}) ||
                 phys_ready_q[mapped_phys]);
        end
    end

    assign destination_ready_o =
        free_count >=
            destination_request_count[FREE_COUNT_WIDTH-1:0];
    assign source_phys_o = source_phys_r;
    assign source_ready_o = source_ready_r;
    assign destination_new_phys_o = destination_new_phys_r;
    assign destination_old_phys_o = destination_old_phys_r;
    assign free_count_o = free_count;

    openrv64_rename_freelist #(
        .TAG_WIDTH(PHYS_ADDR_WIDTH),
        .DEPTH(FREE_LIST_DEPTH),
        .PUSH_PORTS(FREE_PORTS),
        .POP_PORTS(LANES),
        .INIT_BASE(INITIAL_FREE_BASE),
        .INIT_COUNT(INITIAL_FREE_COUNT),
        .STRICT_CONSERVATION(1),
        .COUNT_WIDTH(FREE_COUNT_WIDTH)
    ) u_freelist (
        .clk(clk),
        .rst_n(rst_n),
        .push_valid_i(free_valid_i),
        .push_tag_i(free_tag_i),
        .pop_req_i(free_pop_req),
        .pop_valid_o(free_pop_valid),
        .pop_tag_o(free_pop_tag),
        .count_o(free_count)
    );

    integer reset_arch;
    integer update_lane;
    integer ready_tag;
    integer write_port;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (reset_arch = 0; reset_arch < ARCH_REG_COUNT;
                 reset_arch = reset_arch + 1) begin
                rat_q[reset_arch] <= PHYS_ADDR_WIDTH'(reset_arch);
            end
            phys_ready_q <= {(PHYS_REG_COUNT + 1){1'b0}};
            for (ready_tag = 0; ready_tag < ARCH_REG_COUNT;
                 ready_tag = ready_tag + 1)
                phys_ready_q[ready_tag] <= 1'b1;
        end else if (destination_ready_o) begin
            // Increasing loop order gives the youngest same-cycle WAW writer
            // the final speculative mapping.
            for (update_lane = 0; update_lane < LANES;
                 update_lane = update_lane + 1) begin
                if (destination_valid_i[update_lane]) begin
                    rat_q[destination_arch_i[
                        update_lane*ARCH_ADDR_WIDTH +:
                        ARCH_ADDR_WIDTH]] <= destination_new_phys_r[
                            update_lane*PHYS_ADDR_WIDTH +:
                            PHYS_ADDR_WIDTH];
                    phys_ready_q[destination_new_phys_r[
                        update_lane*PHYS_ADDR_WIDTH +:
                        PHYS_ADDR_WIDTH]] <= 1'b0;
                end
            end
            for (write_port = 0; write_port < FREE_PORTS;
                 write_port = write_port + 1) begin
                if (write_valid_i[write_port])
                    phys_ready_q[write_tag_i[
                        write_port*PHYS_ADDR_WIDTH +:
                        PHYS_ADDR_WIDTH]] <= 1'b1;
            end
        end else begin
            for (write_port = 0; write_port < FREE_PORTS;
                 write_port = write_port + 1) begin
                if (write_valid_i[write_port])
                    phys_ready_q[write_tag_i[
                        write_port*PHYS_ADDR_WIDTH +:
                        PHYS_ADDR_WIDTH]] <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    integer check_lane;
    always @(posedge clk) begin
        if (rst_n) begin
            if ((|destination_valid_i) && !destination_ready_o)
                $fatal(1,
                    "tomasulo rename fired without enough free physical tags");
            for (check_lane = 0; check_lane < LANES;
                 check_lane = check_lane + 1) begin
                if (destination_valid_i[check_lane] &&
                    (destination_arch_i[
                        check_lane*ARCH_ADDR_WIDTH +: ARCH_ADDR_WIDTH] == 0))
                    $fatal(1, "tomasulo rename attempted to allocate x0");
            end
        end
    end

    initial begin
        if (PHYS_ADDR_WIDTH < ARCH_ADDR_WIDTH)
            $fatal(1,
                "tomasulo rename physical tag is narrower than architectural tag");
        if (PHYS_REG_COUNT < ARCH_REG_COUNT)
            $fatal(1,
                "tomasulo rename requires at least one extra physical register");
        if ((1 << PHYS_ADDR_WIDTH) <= PHYS_REG_COUNT)
            $fatal(1, "tomasulo rename physical tag cannot address the PRF");
        if (INITIAL_FREE_COUNT > FREE_LIST_DEPTH)
            $fatal(1, "tomasulo rename free registers exceed free-list depth");
    end
`endif

    wire unused_free_pop_valid = |free_pop_valid;

endmodule

`endif
