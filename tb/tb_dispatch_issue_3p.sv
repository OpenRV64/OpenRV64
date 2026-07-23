`timescale 1ns/1ps
`include "core/backend/backend-defs.v"

module tb_dispatch_issue_3p;

    localparam integer SLOT_WIDTH = 3;
    localparam integer PAYLOAD_WIDTH = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;
    localparam integer ID_WIDTH = `OPENRV64_INSTR_ID_WIDTH;

    reg [2:0] candidate_valid;
    reg [2:0] candidate_allow;
    reg [2:0] candidate_free;
    reg [3*`OPENRV64_EXEC_PIPE_WIDTH-1:0] candidate_pipe;
    reg [3*ID_WIDTH-1:0] candidate_id;
    reg [3*SLOT_WIDTH-1:0] candidate_slot;
    reg [3*PAYLOAD_WIDTH-1:0] candidate_payload;
    reg allocation_ready;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_ready;
    wire [2:0] candidate_fire;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*ID_WIDTH-1:0] pipe_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT*SLOT_WIDTH-1:0] pipe_slot;
    wire [`OPENRV64_EXEC_PIPE_COUNT*PAYLOAD_WIDTH-1:0] pipe_payload;

    openrv64_dispatch_issue_3p #(
        .RETIRE_SLOT_WIDTH(SLOT_WIDTH)
    ) dut (
        .candidate_valid_i(candidate_valid),
        .candidate_allow_i(candidate_allow),
        .candidate_free_i(candidate_free),
        .candidate_pipe_i(candidate_pipe),
        .candidate_id_i(candidate_id),
        .candidate_slot_i(candidate_slot),
        .candidate_payload_i(candidate_payload),
        .allocation_ready_i(allocation_ready),
        .pipe_ready_i(pipe_ready),
        .candidate_fire_o(candidate_fire),
        .pipe_valid_o(pipe_valid),
        .pipe_id_o(pipe_id),
        .pipe_slot_o(pipe_slot),
        .pipe_payload_o(pipe_payload)
    );

    task automatic fail;
        input [8*96-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    initial begin
        candidate_valid = 3'b111;
        candidate_allow = 3'b111;
        candidate_free = 3'b000;
        candidate_pipe = {
            `OPENRV64_EXEC_PIPE_EX1,
            `OPENRV64_EXEC_PIPE_EX0,
            `OPENRV64_EXEC_PIPE_MEM
        };
        candidate_id = {ID_WIDTH'(12), ID_WIDTH'(11), ID_WIDTH'(10)};
        candidate_slot = {3'd2, 3'd1, 3'd0};
        candidate_payload = {3*PAYLOAD_WIDTH{1'b0}};
        candidate_payload[0*PAYLOAD_WIDTH +: 64] = 64'h10;
        candidate_payload[1*PAYLOAD_WIDTH +: 64] = 64'h11;
        candidate_payload[2*PAYLOAD_WIDTH +: 64] = 64'h12;
        allocation_ready = 1'b1;
        pipe_ready = 4'b1111;
        #1;

        if ((candidate_fire != 3'b111) || (pipe_valid != 3'b111))
            fail("three distinct ready pipes did not issue together");
        if ((pipe_id[0*ID_WIDTH +: ID_WIDTH] != ID_WIDTH'(11)) ||
            (pipe_id[1*ID_WIDTH +: ID_WIDTH] != ID_WIDTH'(12)) ||
            (pipe_id[2*ID_WIDTH +: ID_WIDTH] != ID_WIDTH'(10))) begin
            fail("program-order candidates were routed to wrong physical pipes");
        end
        if ((pipe_slot[0*SLOT_WIDTH +: SLOT_WIDTH] != 3'd1) ||
            (pipe_slot[1*SLOT_WIDTH +: SLOT_WIDTH] != 3'd2) ||
            (pipe_slot[2*SLOT_WIDTH +: SLOT_WIDTH] != 3'd0)) begin
            fail("retirement slots were not preserved during routing");
        end

        // Candidate zero targets MEM.  When MEM is unavailable, neither idle
        // ALU may accept its younger candidate.
        pipe_ready = 4'b0011;
        #1;
        if ((candidate_fire != 3'b000) || (pipe_valid != 3'b000))
            fail("younger ALU issued around older stalled MEM candidate");

        // Candidate zero can issue, candidate one cannot; candidate two must
        // still wait even though EX1 is idle.
        candidate_pipe = {
            `OPENRV64_EXEC_PIPE_EX1,
            `OPENRV64_EXEC_PIPE_MEM,
            `OPENRV64_EXEC_PIPE_EX0
        };
        pipe_ready = 4'b0011;
        #1;
        if ((candidate_fire != 3'b001) || (pipe_valid != 3'b001))
            fail("issue prefix continued past a stalled middle candidate");

        // Two candidates assigned to the same pipe serialize at the first
        // collision, and the third candidate cannot jump over it.
        candidate_pipe = {
            `OPENRV64_EXEC_PIPE_MEM,
            `OPENRV64_EXEC_PIPE_EX0,
            `OPENRV64_EXEC_PIPE_EX0
        };
        pipe_ready = 4'b1111;
        #1;
        if ((candidate_fire != 3'b001) || (pipe_valid != 3'b001))
            fail("physical-pipe collision did not stop issue prefix");

        candidate_pipe = {
            `OPENRV64_EXEC_PIPE_EX1,
            `OPENRV64_EXEC_PIPE_MEM,
            `OPENRV64_EXEC_PIPE_EX0
        };
        candidate_allow = 3'b011;
        #1;
        if ((candidate_fire != 3'b011) || (pipe_valid != 3'b101))
            fail("hard-order allowance did not terminate issue after candidate one");

        // Candidate zero is an allocation-completed branch.  It must allocate
        // without claiming EX0, allowing the younger EX0 and MEM operations
        // to issue in the same architectural group.
        candidate_pipe = {
            `OPENRV64_EXEC_PIPE_MEM,
            `OPENRV64_EXEC_PIPE_EX0,
            `OPENRV64_EXEC_PIPE_EX0
        };
        candidate_allow = 3'b111;
        candidate_free = 3'b001;
        #1;
        if ((candidate_fire != 3'b111) || (pipe_valid != 3'b101))
            fail("free branch consumed EX0 or terminated issue");
        if ((pipe_id[0*ID_WIDTH +: ID_WIDTH] != ID_WIDTH'(11)) ||
            (pipe_id[2*ID_WIDTH +: ID_WIDTH] != ID_WIDTH'(12))) begin
            fail("younger operations were misrouted around free control");
        end

        // Adjacent free branches are handled as well.  Neither may consume
        // the sole EX0 route needed by the ordinary third candidate.
        candidate_pipe = {
            `OPENRV64_EXEC_PIPE_EX0,
            `OPENRV64_EXEC_PIPE_EX0,
            `OPENRV64_EXEC_PIPE_EX0
        };
        candidate_free = 3'b011;
        #1;
        if ((candidate_fire != 3'b111) || (pipe_valid != 3'b001) ||
            (pipe_id[0*ID_WIDTH +: ID_WIDTH] != ID_WIDTH'(12))) begin
            fail("adjacent free branches serialized the issue group");
        end

        candidate_free = 3'b000;
        candidate_allow = 3'b111;
        allocation_ready = 1'b0;
        #1;
        if (candidate_fire != 3'b000)
            fail("issue proceeded without retirement allocation capacity");

        $display("PASS: 3p issue is a strict in-order prefix across physical pipes");
        $finish;
    end

    wire unused_payload = |pipe_payload;

endmodule
