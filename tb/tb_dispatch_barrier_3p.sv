`timescale 1ns/1ps
`include "core/backend/backend-defs.v"

module tb_dispatch_barrier_3p;

    localparam integer PAYLOAD_WIDTH = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;

    reg clk;
    reg rst_n;
    reg flush;
    reg [2:0] candidate_valid;
    reg [2:0] candidate_free;
    reg [2:0] candidate_barrier_free;
    reg [3*PAYLOAD_WIDTH-1:0] candidate_payload;
    wire [2:0] candidate_hard;
    wire [2:0] allocation_allow;
    reg [2:0] allocation_fire;
    reg [2:0] retire_valid;
    reg [2:0] retire_hard;
    wire barrier_active;

    openrv64_dispatch_barrier_3p dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .candidate_valid_i(candidate_valid),
        .candidate_free_i(candidate_free),
        .candidate_barrier_free_i(candidate_barrier_free),
        .candidate_payload_i(candidate_payload),
        .candidate_hard_o(candidate_hard),
        .allocation_allow_o(allocation_allow),
        .allocation_fire_i(allocation_fire),
        .retire_valid_i(retire_valid),
        .retire_hard_i(retire_hard),
        .barrier_active_o(barrier_active)
    );

    always #5 clk = ~clk;

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic fail;
        input [8*96-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    task automatic clear_inputs;
        begin
            candidate_valid = 3'b000;
            candidate_free = 3'b000;
            candidate_barrier_free = 3'b000;
            candidate_payload = {3*PAYLOAD_WIDTH{1'b0}};
            allocation_fire = 3'b000;
            retire_valid = 3'b000;
            retire_hard = 3'b000;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        clear_inputs();

        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        candidate_valid = 3'b111;
        #1;
        if ((candidate_hard != 3'b000) ||
            (allocation_allow != 3'b111)) begin
            fail("normal three-wide prefix was restricted");
        end

        // Branch in position one: the older instruction and branch may
        // allocate, but position two is younger than the barrier.
        candidate_payload[1*PAYLOAD_WIDTH + 14] = 1'b1;
        #1;
        if (candidate_hard != 3'b010)
            fail("branch was not classified as hard order");
        if (allocation_allow != 3'b011)
            fail("allocation did not stop immediately after branch");
        allocation_fire = 3'b011;
        tick();
        clear_inputs();
        #1;
        if (barrier_active || (allocation_allow != 3'b111))
            fail("resolved aligned branch retained a persistent barrier");

        // A potentially misaligned branch remains conservative until retire.
        candidate_valid = 3'b001;
        candidate_payload[0*PAYLOAD_WIDTH + 14] = 1'b1;
        candidate_payload[0*PAYLOAD_WIDTH + 41] = 1'b1;
        allocation_fire = 3'b001;
        tick();
        clear_inputs();
        if (!barrier_active)
            fail("potentially misaligned branch did not retain barrier");

        // Retiring unrelated older work cannot open the barrier.
        retire_valid = 3'b001;
        retire_hard = 3'b000;
        tick();
        clear_inputs();
        if (!barrier_active)
            fail("normal retirement incorrectly cleared barrier");

        retire_valid = 3'b001;
        retire_hard = 3'b001;
        tick();
        clear_inputs();
        #1;
        if (barrier_active || (allocation_allow != 3'b111))
            fail("hard-order retirement did not reopen dispatch");

        // A fence in position two permits the entire prefix, then blocks the
        // next cycle.  This covers the last slot without special casing.
        candidate_valid = 3'b111;
        candidate_payload[2*PAYLOAD_WIDTH + 9] = 1'b1;
        #1;
        if ((candidate_hard != 3'b100) ||
            (allocation_allow != 3'b111)) begin
            fail("last-slot fence barrier mask mismatch");
        end
        allocation_fire = 3'b111;
        tick();
        clear_inputs();
        if (!barrier_active)
            fail("fence did not activate barrier");

        flush = 1'b1;
        tick();
        flush = 1'b0;
        #1;
        if (barrier_active)
            fail("flush did not clear barrier");

        // A free branch is neither an issue-group terminator nor a
        // retirement barrier.  The instruction still allocates separately.
        candidate_valid = 3'b111;
        candidate_free = 3'b010;
        candidate_payload[1*PAYLOAD_WIDTH + 14] = 1'b1;
        #1;
        if ((candidate_hard != 3'b000) ||
            (allocation_allow != 3'b111)) begin
            fail("free branch still acted as a hard-order barrier");
        end
        clear_inputs();

        // A proved-correct equality branch remains hard retirement metadata,
        // but no longer terminates this issue group.
        candidate_valid = 3'b111;
        candidate_barrier_free = 3'b010;
        candidate_payload[1*PAYLOAD_WIDTH + 14] = 1'b1;
        #1;
        if ((candidate_hard != 3'b010) ||
            (allocation_allow != 3'b111)) begin
            fail("paired equality branch lost hard metadata or blocked issue");
        end
        clear_inputs();

        // A trap in the first position excludes both younger candidates.
        candidate_valid = 3'b111;
        candidate_payload[0*PAYLOAD_WIDTH + 6] = 1'b1;
        #1;
        if ((candidate_hard != 3'b001) ||
            (allocation_allow != 3'b001)) begin
            fail("first-slot trap did not terminate allocation prefix");
        end

        $display("PASS: 3p hard-order barriers terminate and hold in-order dispatch");
        $finish;
    end

endmodule
