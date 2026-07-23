`timescale 1ns/1ps
`include "core/backend/backend-defs.v"

module tb_retire_queue_3p #(
    parameter integer DEPTH = 8
);

    localparam ID_WIDTH = `OPENRV64_INSTR_ID_WIDTH;
    localparam META_WIDTH = 8;
    localparam RESULT_WIDTH = 16;
    localparam INDEX_WIDTH = $clog2(DEPTH);
    localparam COUNT_WIDTH = $clog2(DEPTH + 1);

    logic clk;
    logic rst_n;
    logic flush;
    logic squash_younger;
    logic [ID_WIDTH-1:0] squash_id;
    logic [INDEX_WIDTH-1:0] squash_slot;
    logic [2:0] alloc_valid;
    wire alloc_ready;
    logic [3*META_WIDTH-1:0] alloc_meta;
    logic [2:0] alloc_complete;
    logic [3*RESULT_WIDTH-1:0] alloc_result;
    wire [3*ID_WIDTH-1:0] alloc_id;
    wire [3*INDEX_WIDTH-1:0] alloc_slot;
    logic [2:0] complete_valid;
    logic [3*ID_WIDTH-1:0] complete_id;
    logic [3*INDEX_WIDTH-1:0] complete_slot;
    logic [3*RESULT_WIDTH-1:0] complete_result;
    wire [2:0] retire_valid;
    logic [2:0] retire_accept;
    wire [3*ID_WIDTH-1:0] retire_id;
    wire [3*META_WIDTH-1:0] retire_meta;
    wire [3*RESULT_WIDTH-1:0] retire_result;
    wire [COUNT_WIDTH-1:0] occupancy;
    wire [ID_WIDTH-1:0] next_retire_id;

    logic [ID_WIDTH-1:0] saved_id [0:2];
    logic [INDEX_WIDTH-1:0] saved_slot [0:2];
    logic [ID_WIDTH-1:0] stale_id;
    logic [INDEX_WIDTH-1:0] stale_slot;
    logic [ID_WIDTH-1:0] recovered_id;
    logic [INDEX_WIDTH-1:0] recovered_slot;

    openrv64_retire_queue_3p #(
        .DEPTH(DEPTH),
        .ID_WIDTH(ID_WIDTH),
        .META_WIDTH(META_WIDTH),
        .RESULT_WIDTH(RESULT_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .squash_younger_i(squash_younger),
        .squash_id_i(squash_id),
        .squash_slot_i(squash_slot),
        .alloc_valid_i(alloc_valid),
        .alloc_ready_o(alloc_ready),
        .alloc_meta_i(alloc_meta),
        .alloc_complete_i(alloc_complete),
        .alloc_result_i(alloc_result),
        .alloc_id_o(alloc_id),
        .alloc_slot_o(alloc_slot),
        .complete_valid_i(complete_valid),
        .complete_id_i(complete_id),
        .complete_slot_i(complete_slot),
        .complete_result_i(complete_result),
        .retire_valid_o(retire_valid),
        .retire_accept_i(retire_accept),
        .retire_id_o(retire_id),
        .retire_meta_o(retire_meta),
        .retire_result_o(retire_result),
        .occupancy_o(occupancy),
        .next_retire_id_o(next_retire_id)
    );

    always #5 clk = ~clk;

    task automatic clear_inputs;
        begin
            flush = 1'b0;
            alloc_valid = 3'b000;
            alloc_meta = 24'd0;
            alloc_complete = 3'b000;
            alloc_result = 48'd0;
            complete_valid = 3'b000;
            complete_id = {3*ID_WIDTH{1'b0}};
            complete_slot = {3*INDEX_WIDTH{1'b0}};
            complete_result = 48'd0;
            retire_accept = 3'b000;
        end
    endtask

    task automatic allocate_three;
        input [7:0] meta0;
        input [7:0] meta1;
        input [7:0] meta2;
        begin
            @(negedge clk);
            alloc_valid = 3'b111;
            alloc_meta = {meta2, meta1, meta0};
            #1;
            if (!alloc_ready) begin
                $fatal(1, "three-entry allocation was not ready");
            end
            saved_id[0] = alloc_id[0 +: ID_WIDTH];
            saved_id[1] = alloc_id[ID_WIDTH +: ID_WIDTH];
            saved_id[2] = alloc_id[2*ID_WIDTH +: ID_WIDTH];
            saved_slot[0] = alloc_slot[0 +: INDEX_WIDTH];
            saved_slot[1] = alloc_slot[INDEX_WIDTH +: INDEX_WIDTH];
            saved_slot[2] = alloc_slot[2*INDEX_WIDTH +: INDEX_WIDTH];
            @(posedge clk);
            #1;
            alloc_valid = 3'b000;
            alloc_meta = 24'd0;
        end
    endtask

    task automatic complete_one;
        input [ID_WIDTH-1:0] id;
        input [INDEX_WIDTH-1:0] slot;
        input [RESULT_WIDTH-1:0] result_value;
        begin
            @(negedge clk);
            complete_valid = 3'b001;
            complete_id[0 +: ID_WIDTH] = id;
            complete_slot[0 +: INDEX_WIDTH] = slot;
            complete_result[0 +: RESULT_WIDTH] = result_value;
            @(posedge clk);
            #1;
            complete_valid = 3'b000;
            complete_id = {3*ID_WIDTH{1'b0}};
            complete_slot = {3*INDEX_WIDTH{1'b0}};
            complete_result = 48'd0;
        end
    endtask

    integer fill_idx;
    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        clear_inputs();

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Prove that the selected depth is usable, not just wide enough to
        // elaborate.  Hold completion/retirement off and fill every slot.
        for (fill_idx = 0; fill_idx < DEPTH; fill_idx = fill_idx + 1) begin
            @(negedge clk);
            alloc_valid = 3'b001;
            alloc_meta[0 +: META_WIDTH] = fill_idx;
            #1;
            if (!alloc_ready)
                $fatal(1, "queue stopped accepting at entry %0d of %0d",
                       fill_idx, DEPTH);
            @(posedge clk);
            #1;
            alloc_valid = 3'b000;
        end
        if (occupancy != DEPTH)
            $fatal(1, "queue occupancy=%0d expected depth=%0d",
                   occupancy, DEPTH);
        @(negedge clk);
        alloc_valid = 3'b001;
        #1;
        if (alloc_ready)
            $fatal(1, "full queue accepted an additional entry");
        alloc_valid = 3'b000;
        flush = 1'b1;
        @(posedge clk);
        #1;
        flush = 1'b0;
        squash_younger = 1'b0;
        squash_id = {ID_WIDTH{1'b0}};
        squash_slot = {INDEX_WIDTH{1'b0}};
        if (occupancy != 0)
            $fatal(1, "flush did not drain full queue");

        // Allocation-time completion is used by experimental zero-execute
        // operations.  It must preserve normal in-order visibility and its
        // supplied result without consuming a completion port.
        @(negedge clk);
        alloc_valid = 3'b011;
        alloc_meta = {8'd0, 8'h92, 8'h91};
        alloc_complete = 3'b011;
        alloc_result = {16'd0, 16'h9292, 16'h9191};
        @(posedge clk);
        #1;
        alloc_valid = 3'b000;
        alloc_complete = 3'b000;
        if ((retire_valid !== 3'b011) ||
            (retire_result[0 +: RESULT_WIDTH] !== 16'h9191) ||
            (retire_result[RESULT_WIDTH +: RESULT_WIDTH] !== 16'h9292)) begin
            $fatal(1, "allocation-time completion was not immediately visible");
        end
        @(negedge clk);
        retire_accept = 3'b011;
        @(posedge clk);
        #1;
        retire_accept = 3'b000;
        alloc_result = 48'd0;
        if (occupancy != 0)
            $fatal(1, "allocation-time completed entries did not drain");

        allocate_three(8'ha0, 8'ha1, 8'ha2);
        if (occupancy !== 4'd3 || next_retire_id !== saved_id[0]) begin
            $fatal(1, "allocation state mismatch");
        end

        // Younger completions cannot bypass an incomplete queue head.
        @(negedge clk);
        complete_valid = 3'b011;
        complete_id = {{ID_WIDTH{1'b0}}, saved_id[1], saved_id[2]};
        complete_slot = {
            {INDEX_WIDTH{1'b0}}, saved_slot[1], saved_slot[2]
        };
        complete_result = {16'd0, 16'h1111, 16'h2222};
        @(posedge clk);
        #1;
        complete_valid = 3'b000;
        if (retire_valid !== 3'b000) begin
            $fatal(1, "younger completions retired around an incomplete head");
        end

        complete_one(saved_id[0], saved_slot[0], 16'h0000);
        if (retire_valid !== 3'b111) begin
            $fatal(1, "three completed head entries were not exposed together");
        end
        if (retire_meta !== {8'ha2, 8'ha1, 8'ha0} ||
            retire_result !== {16'h2222, 16'h1111, 16'h0000}) begin
            $fatal(1, "retirement payload order mismatch");
        end

        // Retirement may consume any contiguous prefix of the offered prefix.
        @(negedge clk);
        retire_accept = 3'b011;
        @(posedge clk);
        #1;
        retire_accept = 3'b000;
        if (retire_valid !== 3'b001 ||
            retire_id[0 +: ID_WIDTH] !== saved_id[2] ||
            occupancy !== 4'd1) begin
            $fatal(1, "partial prefix retirement did not preserve the third entry");
        end

        @(negedge clk);
        retire_accept = 3'b001;
        @(posedge clk);
        #1;
        retire_accept = 3'b000;
        if (occupancy !== 4'd0 || retire_valid !== 3'b000) begin
            $fatal(1, "queue did not drain");
        end

        // Flushed work must not match a new occupant of the same slot.
        @(negedge clk);
        alloc_valid = 3'b001;
        alloc_meta[0 +: META_WIDTH] = 8'hb0;
        #1;
        stale_id = alloc_id[0 +: ID_WIDTH];
        stale_slot = alloc_slot[0 +: INDEX_WIDTH];
        @(posedge clk);
        #1;
        alloc_valid = 3'b000;

        @(negedge clk);
        flush = 1'b1;
        @(posedge clk);
        #1;
        flush = 1'b0;

        @(negedge clk);
        alloc_valid = 3'b001;
        alloc_meta[0 +: META_WIDTH] = 8'hc0;
        #1;
        saved_id[0] = alloc_id[0 +: ID_WIDTH];
        saved_slot[0] = alloc_slot[0 +: INDEX_WIDTH];
        @(posedge clk);
        #1;
        alloc_valid = 3'b000;

        complete_one(stale_id, stale_slot, 16'hdead);
        if (retire_valid !== 3'b000) begin
            $fatal(1, "stale completion matched a post-flush queue entry");
        end

        complete_one(saved_id[0], saved_slot[0], 16'hcafe);
        if (retire_valid !== 3'b001 ||
            retire_result[0 +: RESULT_WIDTH] !== 16'hcafe) begin
            $fatal(1, "post-flush completion did not retire");
        end

        // A branch recovery retains the branch and its older prefix, drops
        // only younger entries, and does not rewind IDs.  The gap prevents a
        // late completion from a squashed operation from matching new work in
        // the same physical slot.
        @(negedge clk);
        retire_accept = 3'b001;
        @(posedge clk);
        #1;
        retire_accept = 3'b000;
        allocate_three(8'hd0, 8'hd1, 8'hd2);
        @(negedge clk);
        alloc_valid = 3'b011;
        alloc_meta[0 +: META_WIDTH] = 8'hd3;
        alloc_meta[META_WIDTH +: META_WIDTH] = 8'hd4;
        #1;
        stale_id = alloc_id[0 +: ID_WIDTH];
        stale_slot = alloc_slot[0 +: INDEX_WIDTH];
        @(posedge clk);
        #1;
        alloc_valid = 3'b000;
        if (occupancy != 5)
            $fatal(1, "five-entry speculation setup failed");

        @(negedge clk);
        squash_younger = 1'b1;
        squash_id = saved_id[2];
        squash_slot = saved_slot[2];
        @(posedge clk);
        #1;
        squash_younger = 1'b0;
        if (occupancy != 3)
            $fatal(1, "selective recovery did not retain branch prefix");

        @(negedge clk);
        alloc_valid = 3'b001;
        alloc_meta[0 +: META_WIDTH] = 8'he0;
        #1;
        if (alloc_id[0 +: ID_WIDTH] <= stale_id)
            $fatal(1, "selective recovery rewound instruction IDs");
        recovered_id = alloc_id[0 +: ID_WIDTH];
        recovered_slot = alloc_slot[0 +: INDEX_WIDTH];
        @(posedge clk);
        #1;
        alloc_valid = 3'b000;
        complete_one(stale_id, stale_slot, 16'hdead);
        if (occupancy != 4)
            $fatal(1, "stale wrong-path completion changed occupancy");

        // Complete the retained prefix and then the new post-recovery entry.
        @(negedge clk);
        complete_valid = 3'b111;
        complete_id = {saved_id[2], saved_id[1], saved_id[0]};
        complete_slot = {saved_slot[2], saved_slot[1], saved_slot[0]};
        complete_result = {16'hd2d2, 16'hd1d1, 16'hd0d0};
        @(posedge clk);
        #1;
        complete_valid = 3'b000;
        if (retire_valid != 3'b111)
            $fatal(1, "retained prefix did not complete in order");
        @(negedge clk);
        retire_accept = 3'b111;
        @(posedge clk);
        #1;
        retire_accept = 3'b000;
        complete_one(recovered_id, recovered_slot, 16'he0e0);
        if (retire_valid != 3'b001)
            $fatal(1, "post-recovery ID gap blocked retirement");

        // Exercise the actual modular boundary.  IDs 1022, 1023, and 0 are
        // consecutive in a 10-bit namespace; squashing at 1023 must retain
        // the first two and discard only ID 0.
        @(negedge clk);
        retire_accept = 3'b001;
        @(posedge clk);
        #1;
        retire_accept = 3'b000;
        if (occupancy != 0)
            $fatal(1, "queue did not drain before modular wrap test");

        @(negedge clk);
        dut.next_alloc_id_q = {ID_WIDTH{1'b1}} - 1'b1;
        allocate_three(8'hf0, 8'hf1, 8'hf2);
        if ((saved_id[0] != ({ID_WIDTH{1'b1}} - 1'b1)) ||
            (saved_id[1] != {ID_WIDTH{1'b1}}) ||
            (saved_id[2] != {ID_WIDTH{1'b0}}))
            $fatal(1, "allocation IDs did not wrap modulo ID width");

        @(negedge clk);
        squash_younger = 1'b1;
        squash_id = saved_id[1];
        squash_slot = saved_slot[1];
        @(posedge clk);
        #1;
        squash_younger = 1'b0;
        if (occupancy != 2)
            $fatal(1, "modular squash misclassified entries across ID wrap");

        $display("PASS: depth-%0d completion queue, retirement, and selective recovery",
                 DEPTH);
        $finish;
    end

endmodule
