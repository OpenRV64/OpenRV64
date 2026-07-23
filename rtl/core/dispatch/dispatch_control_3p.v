`timescale 1ns/1ps
`include "core/backend/backend-defs.v"

// Backend-facing control core for dispatch_3p.  Decode-window construction,
// register hazards, and flexible ALU pipe selection sit in front of this
// module.  Everything leaving it is both a strict in-order prefix and subject
// to the persistent hard-order barrier.
module openrv64_dispatch_control_3p #(
    parameter integer RETIRE_SLOT_WIDTH = 3
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire [2:0]                   candidate_valid_i,
    input  wire [2:0]                   candidate_free_i,
    input  wire [2:0]                   candidate_barrier_free_i,
    input  wire [2:0]                   candidate_hazard_free_i,
    input  wire [3*`OPENRV64_EXEC_PIPE_WIDTH-1:0] candidate_pipe_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] candidate_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] candidate_slot_i,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        candidate_payload_i,

    input  wire                         allocation_ready_i,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_ready_i,
    input  wire [2:0]                   retire_valid_i,
    input  wire [2:0]                   retire_hard_i,

    output wire [2:0]                   candidate_hard_o,
    output wire [2:0]                   candidate_fire_o,
    output wire                         barrier_active_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_valid_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0] pipe_id_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH-1:0]
                                        pipe_slot_o,
    output wire [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        pipe_payload_o
);

    wire [2:0] barrier_allow;
    wire [2:0] candidate_allow = barrier_allow &
                                 candidate_hazard_free_i;

    openrv64_dispatch_barrier_3p u_barrier (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i),
        .candidate_valid_i(candidate_valid_i),
        .candidate_free_i(candidate_free_i),
        .candidate_barrier_free_i(candidate_barrier_free_i),
        .candidate_payload_i(candidate_payload_i),
        .candidate_hard_o(candidate_hard_o),
        .allocation_allow_o(barrier_allow),
        .allocation_fire_i(candidate_fire_o),
        .retire_valid_i(retire_valid_i),
        .retire_hard_i(retire_hard_i),
        .barrier_active_o(barrier_active_o)
    );

    openrv64_dispatch_issue_3p #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH)
    ) u_issue (
        .candidate_valid_i(candidate_valid_i),
        .candidate_allow_i(candidate_allow),
        .candidate_free_i(candidate_free_i),
        .candidate_pipe_i(candidate_pipe_i),
        .candidate_id_i(candidate_id_i),
        .candidate_slot_i(candidate_slot_i),
        .candidate_payload_i(candidate_payload_i),
        .allocation_ready_i(allocation_ready_i),
        .pipe_ready_i(pipe_ready_i),
        .candidate_fire_o(candidate_fire_o),
        .pipe_valid_o(pipe_valid_o),
        .pipe_id_o(pipe_id_o),
        .pipe_slot_o(pipe_slot_o),
        .pipe_payload_o(pipe_payload_o)
    );

endmodule
