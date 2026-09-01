`ifndef OPENRV64_RENAME_TOMASULO_V
`define OPENRV64_RENAME_TOMASULO_V

`timescale 1ns/1ps

// Speculative integer register renaming for the 3P backend.
//
// RAT updates happen when decode/dispatch allocation fires.  RRAT updates
// happen only at architectural retirement.  Every live control allocation
// may snapshot the post-allocation RAT and free bitmap in its ROB slot.  A
// selective redirect restores that snapshot while retaining tags returned by
// older retirement after the snapshot was taken.
//
// Bitmap recovery combines the checkpoint free image, the current free state,
// and every tag allocated after the checkpoint.  The allocation bitmap is
// required when a tag was busy at the checkpoint, retired while the branch
// was live, and was then reused by younger work.  Allocation begins at a
// rotating cursor to avoid permanently concentrating traffic in low banks.
module openrv64_rename_tomasulo #(
    parameter integer ARCH_ADDR_WIDTH = 5,
    parameter integer ARCH_REG_COUNT = 32,
    parameter integer PHYS_ADDR_WIDTH = 6,
    parameter integer PHYS_REG_COUNT = 63,
    parameter integer LANES = 3,
    parameter integer SOURCES_PER_LANE = 2,
    parameter integer FREE_PORTS = 2,
    parameter integer WRITE_PORTS = 3,
    parameter integer COMMIT_PORTS = 3,
    parameter integer CHECKPOINT_DEPTH = 16,
    parameter integer CHECKPOINT_SLOT_WIDTH = $clog2(CHECKPOINT_DEPTH),
    parameter integer FREE_COUNT_WIDTH = $clog2(PHYS_REG_COUNT + 1)
) (
    input  wire                                  clk,
    input  wire                                  rst_n,
    input  wire                                  flush_i,

    input  wire [LANES*SOURCES_PER_LANE*ARCH_ADDR_WIDTH-1:0]
                                                source_arch_i,
    output wire [LANES*SOURCES_PER_LANE*PHYS_ADDR_WIDTH-1:0]
                                                source_phys_o,
    output wire [LANES*SOURCES_PER_LANE-1:0]    source_ready_o,

    // request describes the offered group; valid is the accepted subset.
    input  wire [LANES-1:0]                    destination_request_i,
    input  wire [LANES-1:0]                    destination_valid_i,
    input  wire [LANES*ARCH_ADDR_WIDTH-1:0]    destination_arch_i,
    output wire                                destination_ready_o,
    output wire [LANES*PHYS_ADDR_WIDTH-1:0]    destination_new_phys_o,
    output wire [LANES*PHYS_ADDR_WIDTH-1:0]    destination_old_phys_o,

    input  wire [FREE_PORTS-1:0]               free_valid_i,
    input  wire [FREE_PORTS*PHYS_ADDR_WIDTH-1:0] free_tag_i,
    input  wire [WRITE_PORTS-1:0]              write_valid_i,
    input  wire [WRITE_PORTS*PHYS_ADDR_WIDTH-1:0] write_tag_i,

    input  wire [COMMIT_PORTS-1:0]             commit_valid_i,
    input  wire [COMMIT_PORTS*ARCH_ADDR_WIDTH-1:0] commit_arch_i,
    input  wire [COMMIT_PORTS*PHYS_ADDR_WIDTH-1:0] commit_phys_i,

    input  wire [LANES-1:0]                    checkpoint_valid_i,
    input  wire [LANES*CHECKPOINT_SLOT_WIDTH-1:0] checkpoint_slot_i,
    input  wire                                 recovery_valid_i,
    input  wire [CHECKPOINT_SLOT_WIDTH-1:0]     recovery_slot_i,

    output wire [ARCH_REG_COUNT*PHYS_ADDR_WIDTH-1:0]
                                                committed_map_o,
    output wire [FREE_COUNT_WIDTH-1:0]          free_count_o
);

    reg [PHYS_ADDR_WIDTH-1:0] rat_q [0:ARCH_REG_COUNT-1];
    reg [PHYS_ADDR_WIDTH-1:0] rrat_q [0:ARCH_REG_COUNT-1];
    reg [PHYS_REG_COUNT:0] phys_ready_q;
    reg [PHYS_REG_COUNT:0] free_q;
    reg [PHYS_ADDR_WIDTH-1:0] alloc_cursor_q;

    reg [ARCH_REG_COUNT*PHYS_ADDR_WIDTH-1:0]
        checkpoint_rat_q [0:CHECKPOINT_DEPTH-1];
    reg [PHYS_REG_COUNT:0]
        checkpoint_free_q [0:CHECKPOINT_DEPTH-1];
    reg [PHYS_ADDR_WIDTH-1:0]
        checkpoint_cursor_q [0:CHECKPOINT_DEPTH-1];
    // A free-list snapshot alone cannot recover a tag which was busy at the
    // checkpoint, retired later, and then reused by younger work.  Record all
    // post-checkpoint allocations so selective recovery can reclaim that tag
    // regardless of its state in the original snapshot.
    reg [PHYS_REG_COUNT:0]
        checkpoint_allocated_q [0:CHECKPOINT_DEPTH-1];
    reg [CHECKPOINT_DEPTH-1:0] checkpoint_live_q;

    reg [LANES*SOURCES_PER_LANE*PHYS_ADDR_WIDTH-1:0] source_phys_r;
    reg [LANES*SOURCES_PER_LANE-1:0] source_ready_r;
    reg [LANES*PHYS_ADDR_WIDTH-1:0] destination_new_phys_r;
    reg [LANES*PHYS_ADDR_WIDTH-1:0] destination_old_phys_r;
    reg [LANES-1:0] allocation_found_r;
    reg [PHYS_REG_COUNT:0] free_offer_r;
    reg [PHYS_REG_COUNT:0] free_after_lane_r [0:LANES-1];
    reg [ARCH_REG_COUNT*PHYS_ADDR_WIDTH-1:0]
        rat_after_lane_r [0:LANES-1];
    reg [PHYS_ADDR_WIDTH-1:0] cursor_after_lane_r [0:LANES-1];
    reg [PHYS_REG_COUNT:0] allocated_after_lane_r [0:LANES-1];

    integer lane;
    integer source;
    integer prior_lane;
    integer scan;
    integer tag_index;
    integer arch_index;
    integer free_port;
    integer commit_port;
    integer free_count_r;
    reg [ARCH_ADDR_WIDTH-1:0] source_arch;
    reg [ARCH_ADDR_WIDTH-1:0] destination_arch;
    reg [PHYS_ADDR_WIDTH-1:0] mapped_phys;
    reg [PHYS_ADDR_WIDTH-1:0] selected_phys;
    reg mapped_from_candidate;
    reg selected_found;
    reg [PHYS_REG_COUNT:0] allocation_free_view;
    reg [ARCH_REG_COUNT*PHYS_ADDR_WIDTH-1:0] allocation_rat_view;
    reg [PHYS_ADDR_WIDTH-1:0] allocation_cursor_view;

    always @* begin
        source_phys_r =
            {LANES*SOURCES_PER_LANE*PHYS_ADDR_WIDTH{1'b0}};
        source_ready_r = {LANES*SOURCES_PER_LANE{1'b0}};
        destination_new_phys_r = {LANES*PHYS_ADDR_WIDTH{1'b0}};
        destination_old_phys_r = {LANES*PHYS_ADDR_WIDTH{1'b0}};
        allocation_found_r = {LANES{1'b0}};
        free_offer_r = free_q;

        // Tags returned by retirement are immediately available to rename.
        for (free_port = 0; free_port < FREE_PORTS;
             free_port = free_port + 1) begin
            selected_phys = free_tag_i[
                free_port*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH];
            if (free_valid_i[free_port] &&
                (selected_phys != {PHYS_ADDR_WIDTH{1'b0}}) &&
                (selected_phys <= PHYS_REG_COUNT))
                free_offer_r[selected_phys] = 1'b1;
        end
        free_offer_r[0] = 1'b0;

        allocation_free_view = free_offer_r;
        allocation_cursor_view = alloc_cursor_q;
        allocation_rat_view =
            {ARCH_REG_COUNT*PHYS_ADDR_WIDTH{1'b0}};
        for (arch_index = 0; arch_index < ARCH_REG_COUNT;
             arch_index = arch_index + 1)
            allocation_rat_view[
                arch_index*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH] =
                rat_q[arch_index];

        // Select one free tag for every offered destination, in lane order.
        // The rotating cursor changes only after an accepted allocation.
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            destination_arch = destination_arch_i[
                lane*ARCH_ADDR_WIDTH +: ARCH_ADDR_WIDTH];
            mapped_phys = allocation_rat_view[
                destination_arch*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH];
            destination_old_phys_r[
                lane*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH] = mapped_phys;

            selected_found = 1'b0;
            selected_phys = {PHYS_ADDR_WIDTH{1'b0}};
            if (destination_request_i[lane]) begin
                for (scan = 0; scan < PHYS_REG_COUNT; scan = scan + 1) begin
                    tag_index = alloc_cursor_q + scan;
                    if (tag_index > PHYS_REG_COUNT)
                        tag_index = tag_index - PHYS_REG_COUNT;
                    if (tag_index == 0)
                        tag_index = PHYS_REG_COUNT;
                    if (!selected_found && allocation_free_view[tag_index]) begin
                        selected_found = 1'b1;
                        selected_phys = tag_index[PHYS_ADDR_WIDTH-1:0];
                    end
                end
                if (selected_found) begin
                    allocation_free_view[selected_phys] = 1'b0;
                    allocation_rat_view[
                        destination_arch*PHYS_ADDR_WIDTH +:
                        PHYS_ADDR_WIDTH] = selected_phys;
                    allocation_cursor_view =
                        (selected_phys == PHYS_REG_COUNT) ?
                        PHYS_ADDR_WIDTH'(1) : selected_phys + 1'b1;
                end
            end
            allocation_found_r[lane] =
                !destination_request_i[lane] || selected_found;
            destination_new_phys_r[
                lane*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH] = selected_phys;
            free_after_lane_r[lane] = allocation_free_view;
            rat_after_lane_r[lane] = allocation_rat_view;
            cursor_after_lane_r[lane] = allocation_cursor_view;
        end

        // A checkpoint is post-rename for its own lane.  Destinations in
        // later lanes of the same accepted bundle are already younger and
        // therefore seed its allocation-since-checkpoint bitmap.
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            allocated_after_lane_r[lane] =
                {(PHYS_REG_COUNT + 1){1'b0}};
            for (prior_lane = lane + 1; prior_lane < LANES;
                 prior_lane = prior_lane + 1) begin
                if (destination_valid_i[prior_lane]) begin
                    selected_phys = destination_new_phys_r[
                        prior_lane*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH];
                    allocated_after_lane_r[lane][selected_phys] = 1'b1;
                end
            end
        end

        // Younger sources observe earlier accepted/offered lanes exactly as
        // sequential program-order rename would.
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
                    allocation_found_r[prior_lane] &&
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
            source_ready_r[source] =
                (source_arch == {ARCH_ADDR_WIDTH{1'b0}}) ||
                (!mapped_from_candidate && phys_ready_q[mapped_phys]);
            for (free_port = 0; free_port < WRITE_PORTS;
                 free_port = free_port + 1) begin
                if (!mapped_from_candidate &&
                    write_valid_i[free_port] &&
                    (write_tag_i[
                        free_port*PHYS_ADDR_WIDTH +:
                        PHYS_ADDR_WIDTH] == mapped_phys))
                    source_ready_r[source] = 1'b1;
            end
        end

        free_count_r = 0;
        for (tag_index = 1; tag_index <= PHYS_REG_COUNT;
             tag_index = tag_index + 1) begin
            if (free_q[tag_index])
                free_count_r = free_count_r + 1;
        end
    end

    assign destination_ready_o = &allocation_found_r;
    assign source_phys_o = source_phys_r;
    assign source_ready_o = source_ready_r;
    assign destination_new_phys_o = destination_new_phys_r;
    assign destination_old_phys_o = destination_old_phys_r;
    assign free_count_o = free_count_r[FREE_COUNT_WIDTH-1:0];

    genvar committed_arch;
    generate
        for (committed_arch = 0; committed_arch < ARCH_REG_COUNT;
             committed_arch = committed_arch + 1) begin : g_committed_map
            assign committed_map_o[
                committed_arch*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH] =
                rrat_q[committed_arch];
        end
    endgenerate

    integer reset_arch;
    integer reset_tag;
    integer update_lane;
    integer write_port;
    integer checkpoint_lane;
    integer checkpoint_slot;
    reg [ARCH_REG_COUNT*PHYS_ADDR_WIDTH-1:0] committed_view;
    reg [PHYS_REG_COUNT:0] full_flush_free_view;
    reg [PHYS_ADDR_WIDTH-1:0] committed_tag;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (reset_arch = 0; reset_arch < ARCH_REG_COUNT;
                 reset_arch = reset_arch + 1) begin
                rat_q[reset_arch] <= PHYS_ADDR_WIDTH'(reset_arch);
                rrat_q[reset_arch] <= PHYS_ADDR_WIDTH'(reset_arch);
            end
            phys_ready_q <= {(PHYS_REG_COUNT + 1){1'b0}};
            for (reset_tag = 0; reset_tag < ARCH_REG_COUNT;
                 reset_tag = reset_tag + 1)
                phys_ready_q[reset_tag] <= 1'b1;
            free_q <= {(PHYS_REG_COUNT + 1){1'b0}};
            for (reset_tag = ARCH_REG_COUNT;
                 reset_tag <= PHYS_REG_COUNT; reset_tag = reset_tag + 1)
                free_q[reset_tag] <= 1'b1;
            alloc_cursor_q <= PHYS_ADDR_WIDTH'(ARCH_REG_COUNT);
            checkpoint_live_q <= {CHECKPOINT_DEPTH{1'b0}};
            for (checkpoint_slot = 0;
                 checkpoint_slot < CHECKPOINT_DEPTH;
                 checkpoint_slot = checkpoint_slot + 1)
                checkpoint_allocated_q[checkpoint_slot] <=
                    {(PHYS_REG_COUNT + 1){1'b0}};
        end else begin
            committed_view =
                {ARCH_REG_COUNT*PHYS_ADDR_WIDTH{1'b0}};
            for (arch_index = 0; arch_index < ARCH_REG_COUNT;
                 arch_index = arch_index + 1)
                committed_view[
                    arch_index*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH] =
                    rrat_q[arch_index];
            for (commit_port = 0; commit_port < COMMIT_PORTS;
                 commit_port = commit_port + 1) begin
                if (commit_valid_i[commit_port]) begin
                    committed_view[
                        commit_arch_i[
                            commit_port*ARCH_ADDR_WIDTH +:
                            ARCH_ADDR_WIDTH]*PHYS_ADDR_WIDTH +:
                        PHYS_ADDR_WIDTH] = commit_phys_i[
                            commit_port*PHYS_ADDR_WIDTH +:
                            PHYS_ADDR_WIDTH];
                    rrat_q[commit_arch_i[
                        commit_port*ARCH_ADDR_WIDTH +:
                        ARCH_ADDR_WIDTH]] <= commit_phys_i[
                            commit_port*PHYS_ADDR_WIDTH +:
                            PHYS_ADDR_WIDTH];
                end
            end

            // Completion writes make physical operands schedulable only on
            // the actual PRF write-ack edge.
            for (write_port = 0; write_port < WRITE_PORTS;
                 write_port = write_port + 1) begin
                if (write_valid_i[write_port])
                    phys_ready_q[write_tag_i[
                        write_port*PHYS_ADDR_WIDTH +:
                        PHYS_ADDR_WIDTH]] <= 1'b1;
            end

            if (flush_i) begin
                full_flush_free_view =
                    {(PHYS_REG_COUNT + 1){1'b1}};
                full_flush_free_view[0] = 1'b0;
                for (arch_index = 0; arch_index < ARCH_REG_COUNT;
                     arch_index = arch_index + 1) begin
                    committed_tag = committed_view[
                        arch_index*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH];
                    rat_q[arch_index] <= committed_tag;
                    full_flush_free_view[committed_tag] = 1'b0;
                end
                free_q <= full_flush_free_view;
                checkpoint_live_q <= {CHECKPOINT_DEPTH{1'b0}};
                for (checkpoint_slot = 0;
                     checkpoint_slot < CHECKPOINT_DEPTH;
                     checkpoint_slot = checkpoint_slot + 1)
                    checkpoint_allocated_q[checkpoint_slot] <=
                        {(PHYS_REG_COUNT + 1){1'b0}};
                alloc_cursor_q <= PHYS_ADDR_WIDTH'(ARCH_REG_COUNT);
            end else if (recovery_valid_i) begin
                for (arch_index = 0; arch_index < ARCH_REG_COUNT;
                     arch_index = arch_index + 1)
                    rat_q[arch_index] <= checkpoint_rat_q[
                        recovery_slot_i][
                        arch_index*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH];
                free_q <= free_offer_r |
                    checkpoint_free_q[recovery_slot_i] |
                    checkpoint_allocated_q[recovery_slot_i];
                alloc_cursor_q <= checkpoint_cursor_q[recovery_slot_i];
                checkpoint_live_q[recovery_slot_i] <= 1'b1;
            end else begin
                free_q <= free_offer_r;
                if (destination_ready_o &&
                    ((|destination_valid_i) || (|checkpoint_valid_i))) begin
                    // Every currently live checkpoint observes all newly
                    // allocated destinations as younger than its cut.
                    for (checkpoint_slot = 0;
                         checkpoint_slot < CHECKPOINT_DEPTH;
                         checkpoint_slot = checkpoint_slot + 1) begin
                        if (checkpoint_live_q[checkpoint_slot]) begin
                            for (update_lane = 0; update_lane < LANES;
                                 update_lane = update_lane + 1) begin
                                if (destination_valid_i[update_lane])
                                    checkpoint_allocated_q[
                                        checkpoint_slot][
                                        destination_new_phys_r[
                                            update_lane*PHYS_ADDR_WIDTH +:
                                            PHYS_ADDR_WIDTH]] <= 1'b1;
                            end
                        end
                    end
                    for (update_lane = 0; update_lane < LANES;
                         update_lane = update_lane + 1) begin
                        if (destination_valid_i[update_lane]) begin
                            rat_q[destination_arch_i[
                                update_lane*ARCH_ADDR_WIDTH +:
                                ARCH_ADDR_WIDTH]] <=
                                destination_new_phys_r[
                                    update_lane*PHYS_ADDR_WIDTH +:
                                    PHYS_ADDR_WIDTH];
                            phys_ready_q[destination_new_phys_r[
                                update_lane*PHYS_ADDR_WIDTH +:
                                PHYS_ADDR_WIDTH]] <= 1'b0;
                            free_q[destination_new_phys_r[
                                update_lane*PHYS_ADDR_WIDTH +:
                                PHYS_ADDR_WIDTH]] <= 1'b0;
                            alloc_cursor_q <=
                                (destination_new_phys_r[
                                    update_lane*PHYS_ADDR_WIDTH +:
                                    PHYS_ADDR_WIDTH] == PHYS_REG_COUNT) ?
                                PHYS_ADDR_WIDTH'(1) :
                                destination_new_phys_r[
                                    update_lane*PHYS_ADDR_WIDTH +:
                                    PHYS_ADDR_WIDTH] + 1'b1;
                        end
                    end
                    for (checkpoint_lane = 0;
                         checkpoint_lane < LANES;
                         checkpoint_lane = checkpoint_lane + 1) begin
                        if (checkpoint_valid_i[checkpoint_lane]) begin
                            checkpoint_slot = checkpoint_slot_i[
                                checkpoint_lane*CHECKPOINT_SLOT_WIDTH +:
                                CHECKPOINT_SLOT_WIDTH];
                            checkpoint_rat_q[checkpoint_slot] <=
                                rat_after_lane_r[checkpoint_lane];
                            checkpoint_free_q[checkpoint_slot] <=
                                free_after_lane_r[checkpoint_lane];
                            checkpoint_cursor_q[checkpoint_slot] <=
                                cursor_after_lane_r[checkpoint_lane];
                            checkpoint_allocated_q[checkpoint_slot] <=
                                allocated_after_lane_r[checkpoint_lane];
                            checkpoint_live_q[checkpoint_slot] <= 1'b1;
                        end
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    integer check_lane;
    integer check_free;
    always @(posedge clk) begin
        if (rst_n) begin
            if ((|destination_valid_i) && !destination_ready_o)
                $fatal(1,
                    "tomasulo rename fired without enough free physical tags");
            for (check_lane = 0; check_lane < LANES;
                 check_lane = check_lane + 1) begin
                if (destination_valid_i[check_lane] &&
                    (destination_arch_i[
                        check_lane*ARCH_ADDR_WIDTH +:
                        ARCH_ADDR_WIDTH] == 0))
                    $fatal(1, "tomasulo rename attempted to allocate x0");
            end
            if (recovery_valid_i &&
                !checkpoint_live_q[recovery_slot_i])
                $fatal(1, "tomasulo recovery named a missing RAT checkpoint");
            if (free_q[0])
                $fatal(1, "tomasulo free bitmap exposed p0");
            for (check_free = 1; check_free <= PHYS_REG_COUNT;
                 check_free = check_free + 1) begin
                if (free_q[check_free] && !phys_ready_q[check_free]) begin
                    // A free tag may carry any stale ready value, but an
                    // unavailable value is harmless and is cleared again on
                    // allocation.  Keep this loop for hierarchy visibility.
                end
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
        if (CHECKPOINT_DEPTH < 2)
            $fatal(1, "tomasulo rename checkpoint depth is too small");
    end
`endif

endmodule

`endif
