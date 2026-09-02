`timescale 1ns/1ps

module tb_rename_tomasulo;

    localparam integer ARCH_WIDTH = 5;
    localparam integer PHYS_WIDTH = 6;
    localparam integer LANES = 3;

    reg clk;
    reg rst_n;
    reg flush;
    reg [LANES*2*ARCH_WIDTH-1:0] source_arch;
    wire [LANES*2*PHYS_WIDTH-1:0] source_phys;
    wire [LANES*2-1:0] source_ready;
    reg [LANES-1:0] destination_valid;
    reg [LANES*ARCH_WIDTH-1:0] destination_arch;
    wire destination_ready;
    wire [LANES*PHYS_WIDTH-1:0] destination_new_phys;
    wire [LANES*PHYS_WIDTH-1:0] destination_old_phys;
    reg [1:0] free_valid;
    reg [2*PHYS_WIDTH-1:0] free_tag;
    reg [2:0] write_valid;
    reg [3*PHYS_WIDTH-1:0] write_tag;
    reg [2:0] commit_valid;
    reg [3*ARCH_WIDTH-1:0] commit_arch;
    reg [3*PHYS_WIDTH-1:0] commit_phys;
    reg [2:0] checkpoint_valid;
    reg [3*4-1:0] checkpoint_slot;
    reg recovery_valid;
    reg [3:0] recovery_slot;
    wire [32*PHYS_WIDTH-1:0] committed_map;
    wire [5:0] free_count;
    integer drain_group;

    openrv64_rename_tomasulo #(
        .ARCH_ADDR_WIDTH(ARCH_WIDTH),
        .ARCH_REG_COUNT(32),
        .PHYS_ADDR_WIDTH(PHYS_WIDTH),
        .PHYS_REG_COUNT(63),
        .LANES(LANES),
        .SOURCES_PER_LANE(2),
        .FREE_PORTS(2)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .source_arch_i(source_arch),
        .source_phys_o(source_phys),
        .source_ready_o(source_ready),
        .destination_request_i(destination_valid),
        .destination_valid_i(destination_valid),
        .destination_arch_i(destination_arch),
        .destination_ready_o(destination_ready),
        .destination_new_phys_o(destination_new_phys),
        .destination_old_phys_o(destination_old_phys),
        .free_valid_i(free_valid),
        .free_tag_i(free_tag),
        .write_valid_i(write_valid),
        .write_tag_i(write_tag),
        .commit_valid_i(commit_valid),
        .commit_arch_i(commit_arch),
        .commit_phys_i(commit_phys),
        .checkpoint_valid_i(checkpoint_valid),
        .checkpoint_slot_i(checkpoint_slot),
        .recovery_valid_i(recovery_valid),
        .recovery_slot_i(recovery_slot),
        .committed_map_o(committed_map),
        .free_count_o(free_count)
    );

    task automatic tick;
        begin
            #5 clk = 1'b1;
            #5 clk = 1'b0;
        end
    endtask

    task automatic fail;
        input [8*120-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        source_arch = {LANES*2*ARCH_WIDTH{1'b0}};
        destination_valid = 3'b000;
        destination_arch = {LANES*ARCH_WIDTH{1'b0}};
        free_valid = 2'b00;
        free_tag = {2*PHYS_WIDTH{1'b0}};
        write_valid = 3'b000;
        write_tag = {3*PHYS_WIDTH{1'b0}};
        commit_valid = 3'b000;
        commit_arch = {3*ARCH_WIDTH{1'b0}};
        commit_phys = {3*PHYS_WIDTH{1'b0}};
        checkpoint_valid = 3'b000;
        checkpoint_slot = 12'd0;
        recovery_valid = 1'b0;
        recovery_slot = 4'd0;

        tick();
        tick();
        rst_n = 1'b1;
        #1;

        if (free_count != 32)
            fail("reset did not expose p32-p63 as free tags");

        // First three-wide issue group: x1, x2, and x3 receive consecutive
        // physical destinations while all x0 sources remain p0.
        source_arch = {5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0};
        destination_arch = {5'd3, 5'd2, 5'd1};
        destination_valid = 3'b111;
        #1;
        if (!destination_ready ||
            (destination_new_phys != {6'd34, 6'd33, 6'd32}) ||
            (destination_old_phys != {6'd3, 6'd2, 6'd1}) ||
            (source_phys != 0))
            fail("first issue group did not allocate from the initial RAT");
        tick();

        // Lane 1 consumes lane 0's new x4.  Lane 2 consumes lane 1's new x1.
        // The lane-2 x4 WAW must return lane 0's p35 as its dead old mapping.
        source_arch = {5'd1, 5'd4, 5'd3, 5'd4, 5'd2, 5'd1};
        destination_arch = {5'd4, 5'd1, 5'd4};
        destination_valid = 3'b111;
        #1;
        if (destination_new_phys != {6'd37, 6'd36, 6'd35})
            fail("second issue group did not allocate consecutive tags");
        if (destination_old_phys != {6'd35, 6'd32, 6'd4})
            fail("same-group WAW old mappings were not program ordered");
        if ((source_phys[0*PHYS_WIDTH +: PHYS_WIDTH] != 6'd32) ||
            (source_phys[1*PHYS_WIDTH +: PHYS_WIDTH] != 6'd33) ||
            (source_phys[2*PHYS_WIDTH +: PHYS_WIDTH] != 6'd35) ||
            (source_phys[3*PHYS_WIDTH +: PHYS_WIDTH] != 6'd34) ||
            (source_phys[4*PHYS_WIDTH +: PHYS_WIDTH] != 6'd35) ||
            (source_phys[5*PHYS_WIDTH +: PHYS_WIDTH] != 6'd36))
            fail("younger sources did not observe the correct issue-time RAT");
        tick();

        destination_valid = 3'b000;
        source_arch = {5'd0, 5'd0, 5'd0, 5'd0, 5'd4, 5'd1};
        #1;
        if ((source_phys[0*PHYS_WIDTH +: PHYS_WIDTH] != 6'd36) ||
            (source_phys[1*PHYS_WIDTH +: PHYS_WIDTH] != 6'd37))
            fail("RAT did not retain the youngest issued mappings");
        if (free_count != 26)
            fail("six issued destinations did not consume six free tags");

        // Snapshot the current RAT/free state in ROB slot 5, allocate two
        // younger wrong-path destinations, and recover them.  Both mappings
        // and free-tag conservation must return to the checkpoint image.
        checkpoint_valid = 3'b001;
        checkpoint_slot[0 +: 4] = 4'd5;
        tick();
        checkpoint_valid = 3'b000;
        destination_arch = {5'd0, 5'd11, 5'd10};
        destination_valid = 3'b011;
        tick();
        destination_valid = 3'b000;
        if (free_count != 24)
            fail("wrong-path allocations did not consume two physical tags");
        recovery_slot = 4'd5;
        recovery_valid = 1'b1;
        tick();
        recovery_valid = 1'b0;
        source_arch[0 +: ARCH_WIDTH] = 5'd10;
        source_arch[ARCH_WIDTH +: ARCH_WIDTH] = 5'd11;
        #1;
        if ((source_phys[0 +: PHYS_WIDTH] != 6'd10) ||
            (source_phys[PHYS_WIDTH +: PHYS_WIDTH] != 6'd11) ||
            (free_count != 26))
            fail("checkpoint recovery did not restore RAT and free bitmap");

        $display("PASS: tomasulo rename instruction stream issued with ordered physical mappings");

        // Retire the first issue group through the two-wide free interface.
        // Its dead mappings are p1, p2, and p3.  They append behind the 26
        // untouched initial free tags and must eventually become allocatable.
        free_tag = {6'd2, 6'd1};
        free_valid = 2'b11;
        tick();
        if (free_count != 28)
            fail("two-wide retirement did not return two old physical tags");

        free_tag = {6'd0, 6'd3};
        free_valid = 2'b01;
        tick();
        free_valid = 2'b00;
        free_tag = {2*PHYS_WIDTH{1'b0}};
        if (free_count != 29)
            fail("single-lane retirement did not return its old physical tag");

        // Consume p38-p63 and then p1.  Repeated WAWs are intentional: every
        // issue remains live, so no other tags may enter the free list.
        source_arch = {LANES*2*ARCH_WIDTH{1'b0}};
        destination_arch = {5'd31, 5'd31, 5'd31};
        destination_valid = 3'b111;
        for (drain_group = 0; drain_group < 9;
             drain_group = drain_group + 1) begin
            #1;
            if (!destination_ready)
                fail("returned-tag drain stalled before consuming live free tags");
            tick();
        end
        if (free_count != 2)
            fail("free-list drain did not leave exactly two retired tags");

        // The final two allocations must be the retired p2 and p3 tags.  This
        // proves retirement is recycling physical tags, not merely increasing
        // an occupancy counter.
        destination_arch = {5'd0, 5'd30, 5'd30};
        destination_valid = 3'b011;
        #1;
        if (!destination_ready ||
            (destination_new_phys[0*PHYS_WIDTH +: PHYS_WIDTH] != 6'd2) ||
            (destination_new_phys[1*PHYS_WIDTH +: PHYS_WIDTH] != 6'd3))
            fail("retired physical tags were not reused in FIFO order");
        tick();
        destination_valid = 3'b000;
        if (free_count != 0)
            fail("physical free list did not reach the expected empty state");

        // Slot 5 was checkpointed while p1-p3 were still busy.  They retired
        // after that checkpoint and were then reused by younger WAWs above.
        // A snapshot-only free bitmap loses those recycled tags; allocation
        // tracking must reclaim them along with p38-p63 on recovery.
        recovery_slot = 4'd5;
        recovery_valid = 1'b1;
        tick();
        recovery_valid = 1'b0;
        if (free_count != 29)
            fail("recovery leaked tags recycled after the checkpoint");

        // A full architectural flush restores the speculative RAT from the
        // retirement map, not from reset identity.  Commit x1->p32, then
        // overwrite x1 speculatively and verify that flush returns to p32.
        rst_n = 1'b0;
        tick();
        rst_n = 1'b1;
        destination_arch = {5'd0, 5'd0, 5'd1};
        destination_valid = 3'b001;
        tick();
        destination_valid = 3'b000;
        write_valid = 3'b001;
        write_tag[0 +: PHYS_WIDTH] = 6'd32;
        commit_valid = 3'b001;
        commit_arch[0 +: ARCH_WIDTH] = 5'd1;
        commit_phys[0 +: PHYS_WIDTH] = 6'd32;
        free_valid = 2'b01;
        free_tag[0 +: PHYS_WIDTH] = 6'd1;
        tick();
        write_valid = 3'b000;
        commit_valid = 3'b000;
        free_valid = 2'b00;
        destination_arch = {5'd0, 5'd0, 5'd1};
        destination_valid = 3'b001;
        tick();
        destination_valid = 3'b000;
        flush = 1'b1;
        tick();
        flush = 1'b0;
        source_arch = {LANES*2*ARCH_WIDTH{1'b0}};
        source_arch[0 +: ARCH_WIDTH] = 5'd1;
        #1;
        if ((source_phys[0 +: PHYS_WIDTH] != 6'd32) ||
            !source_ready[0] ||
            (committed_map[1*PHYS_WIDTH +: PHYS_WIDTH] != 6'd32) ||
            (free_count != 32))
            fail("full flush did not rebuild RAT/free state from the RRAT");

        $display("PASS: tomasulo retirement recycled dead physical mappings");
        $finish;
    end

endmodule
