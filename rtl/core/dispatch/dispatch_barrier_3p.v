`timescale 1ns/1ps
`include "core/backend/backend-defs.v"

// Hard-order admission barrier for a three-wide, in-order dispatch prefix.
//
// A hard instruction may be the last instruction allocated in a cycle.  Most
// hard instructions block every later instruction until retirement or flush.
// An aligned conditional branch resolves as it issues and does not need a
// persistent barrier after that edge.  Dispatch may also prove a BEQ/BNE
// prediction correct and waive its same-cycle issue-group barrier.
// The in-order issue gate may hold it at the front of dispatch while older
// work retires; exec_top_3p requires the same ordered-head match.
module openrv64_dispatch_barrier_3p (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire [2:0]                   candidate_valid_i,
    input  wire [2:0]                   candidate_free_i,
    input  wire [2:0]                   candidate_barrier_free_i,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        candidate_payload_i,
    output wire [2:0]                   candidate_hard_o,
    output wire [2:0]                   allocation_allow_o,
    input  wire [2:0]                   allocation_fire_i,

    input  wire [2:0]                   retire_valid_i,
    input  wire [2:0]                   retire_hard_i,

    output wire                         barrier_active_o
);

    function automatic is_hard_order;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            // Payload bit positions are defined by backend-defs.v.  Register
            // dependencies and memory ordering are not barriers: in-order
            // prefix dispatch and write ownership handle those separately.
            is_hard_order = payload[14] || // branch
                            payload[13] || // jump
                            payload[10] || // system, including CSR/returns
                            payload[9]  || // fence
                            payload[8]  || // decode-illegal
                            payload[7]  || // ebreak
                            payload[6]  || // ecall
                            payload[5]  || // instruction access fault
                            payload[4];    // instruction page fault
        end
    endfunction

    function automatic is_persistent_order;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            // The immediate starts at payload bit 40.  With an RV64I-aligned
            // PC, imm[1]==0 proves a direct conditional target is 4-byte
            // aligned.  Such a branch cannot raise a target-alignment fault,
            // and EX0 resolves it on the allocation edge.  Illegal/faulting
            // packets retain the conservative persistent barrier.
            is_persistent_order = is_hard_order(payload) &&
                !(payload[14] && !payload[8] && !payload[5] &&
                  !payload[4] && !payload[41]);
        end
    endfunction

    wire hard0 = candidate_valid_i[0] && !candidate_free_i[0] && is_hard_order(
        candidate_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]);
    wire hard1 = candidate_valid_i[1] && !candidate_free_i[1] && is_hard_order(
        candidate_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]);
    wire hard2 = candidate_valid_i[2] && !candidate_free_i[2] && is_hard_order(
        candidate_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]);
    wire persistent0 = candidate_valid_i[0] && !candidate_free_i[0] &&
        is_persistent_order(
        candidate_payload_i[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]);
    wire persistent1 = candidate_valid_i[1] && !candidate_free_i[1] &&
        is_persistent_order(
        candidate_payload_i[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]);
    wire persistent2 = candidate_valid_i[2] && !candidate_free_i[2] &&
        is_persistent_order(
        candidate_payload_i[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]);

    reg barrier_active_q;
    wire [2:0] candidate_persistent = {
        persistent2, persistent1, persistent0
    };
    wire barrier_allocate = |(allocation_fire_i & candidate_persistent);
    wire barrier_retire = |(retire_valid_i & retire_hard_i);

    assign candidate_hard_o = {hard2, hard1, hard0};
    assign allocation_allow_o[0] = !barrier_active_q;
    // A proved-correct BEQ/BNE may waive only the same-cycle issue-group
    // barrier.  It remains hard in retirement metadata and still executes in
    // EX0; this is deliberately distinct from the diagnostic free-branch
    // path, which removes the branch's pipe claim and hard classification.
    assign allocation_allow_o[1] = !barrier_active_q &&
                                    !(candidate_valid_i[0] && hard0 &&
                                      !candidate_barrier_free_i[0]);
    assign allocation_allow_o[2] = !barrier_active_q &&
                                    !(candidate_valid_i[0] && hard0 &&
                                      !candidate_barrier_free_i[0]) &&
                                    !(candidate_valid_i[1] && hard1 &&
                                      !candidate_barrier_free_i[1]);
    assign barrier_active_o = barrier_active_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            barrier_active_q <= 1'b0;
        end else if (flush_i) begin
            barrier_active_q <= 1'b0;
        end else begin
            if (barrier_retire) begin
                barrier_active_q <= 1'b0;
            end

            // Allocation wins if an old barrier retires in the same cycle and
            // a new barrier is admitted by a future zero-bubble implementation.
            if (barrier_allocate) begin
                barrier_active_q <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && !flush_i) begin
            if ((candidate_valid_i != 3'b000) &&
                (candidate_valid_i != 3'b001) &&
                (candidate_valid_i != 3'b011) &&
                (candidate_valid_i != 3'b111)) begin
                $fatal(1, "3p dispatch candidates must be a contiguous in-order prefix");
            end

            if ((allocation_fire_i & ~candidate_valid_i) != 3'b000) begin
                $fatal(1, "3p dispatch allocated an invalid candidate");
            end

            if ((allocation_fire_i & ~allocation_allow_o) != 3'b000) begin
                $fatal(1, "3p dispatch allocated through an active hard-order barrier");
            end

            if ((allocation_fire_i != 3'b000) &&
                (allocation_fire_i != 3'b001) &&
                (allocation_fire_i != 3'b011) &&
                (allocation_fire_i != 3'b111)) begin
                $fatal(1, "3p dispatch allocation must be a contiguous prefix");
            end

        end
    end
`endif

endmodule
