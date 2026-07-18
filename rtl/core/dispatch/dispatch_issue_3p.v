`timescale 1ns/1ps
`include "core/backend/backend-defs.v"

// Converts three program-ordered candidates into three physical pipe inputs.
// A candidate fires only if every older valid candidate fires in the same
// cycle.  This is the central in-order issue rule: an idle ALU cannot accept a
// younger instruction around an older dependency, full pipe, or MEM stall.
module openrv64_dispatch_issue_3p #(
    parameter integer RETIRE_SLOT_WIDTH = 3
) (
    input  wire [2:0]                   candidate_valid_i,
    input  wire [2:0]                   candidate_allow_i,
    input  wire [3*`OPENRV64_EXEC_PIPE_WIDTH-1:0] candidate_pipe_i,
    input  wire [3*64-1:0]              candidate_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] candidate_slot_i,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        candidate_payload_i,

    input  wire                         allocation_ready_i,
    input  wire [2:0]                   pipe_ready_i,

    output wire [2:0]                   candidate_fire_o,
    output reg  [2:0]                   pipe_valid_o,
    output reg  [3*64-1:0]              pipe_id_o,
    output reg  [3*RETIRE_SLOT_WIDTH-1:0] pipe_slot_o,
    output reg  [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        pipe_payload_o
);

    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] candidate_pipe0 =
        candidate_pipe_i[0*`OPENRV64_EXEC_PIPE_WIDTH +:
                         `OPENRV64_EXEC_PIPE_WIDTH];
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] candidate_pipe1 =
        candidate_pipe_i[1*`OPENRV64_EXEC_PIPE_WIDTH +:
                         `OPENRV64_EXEC_PIPE_WIDTH];
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] candidate_pipe2 =
        candidate_pipe_i[2*`OPENRV64_EXEC_PIPE_WIDTH +:
                         `OPENRV64_EXEC_PIPE_WIDTH];

    function automatic pipe_select_valid;
        input [`OPENRV64_EXEC_PIPE_WIDTH-1:0] pipe_select;
        begin
            pipe_select_valid =
                (pipe_select == `OPENRV64_EXEC_PIPE_EX0) ||
                (pipe_select == `OPENRV64_EXEC_PIPE_EX1) ||
                (pipe_select == `OPENRV64_EXEC_PIPE_MEM);
        end
    endfunction

    function automatic selected_pipe_ready;
        input [`OPENRV64_EXEC_PIPE_WIDTH-1:0] pipe_select;
        input [2:0] ready_mask;
        begin
            case (pipe_select)
                `OPENRV64_EXEC_PIPE_EX0:
                    selected_pipe_ready = ready_mask[0];
                `OPENRV64_EXEC_PIPE_EX1:
                    selected_pipe_ready = ready_mask[1];
                `OPENRV64_EXEC_PIPE_MEM:
                    selected_pipe_ready = ready_mask[2];
                default:
                    selected_pipe_ready = 1'b0;
            endcase
        end
    endfunction

    wire candidate0_fire = candidate_valid_i[0] &&
                           candidate_allow_i[0] &&
                           allocation_ready_i &&
                           pipe_select_valid(candidate_pipe0) &&
                           selected_pipe_ready(candidate_pipe0, pipe_ready_i);
    wire candidate1_pipe_free = !candidate0_fire ||
                                (candidate_pipe1 != candidate_pipe0);
    wire candidate1_fire = candidate_valid_i[1] &&
                           candidate0_fire &&
                           candidate_allow_i[1] &&
                           candidate1_pipe_free &&
                           pipe_select_valid(candidate_pipe1) &&
                           selected_pipe_ready(candidate_pipe1, pipe_ready_i);
    wire candidate2_pipe_free =
        (!candidate0_fire || (candidate_pipe2 != candidate_pipe0)) &&
        (!candidate1_fire || (candidate_pipe2 != candidate_pipe1));
    wire candidate2_fire = candidate_valid_i[2] &&
                           candidate1_fire &&
                           candidate_allow_i[2] &&
                           candidate2_pipe_free &&
                           pipe_select_valid(candidate_pipe2) &&
                           selected_pipe_ready(candidate_pipe2, pipe_ready_i);

    assign candidate_fire_o = {
        candidate2_fire,
        candidate1_fire,
        candidate0_fire
    };

    integer candidate_idx;
    reg [`OPENRV64_EXEC_PIPE_WIDTH-1:0] selected_pipe;
    reg [2:0] route_claimed;
    always @* begin
        pipe_valid_o = 3'b000;
        route_claimed = 3'b000;
        pipe_id_o = {3*64{1'b0}};
        pipe_slot_o = {3*RETIRE_SLOT_WIDTH{1'b0}};
        pipe_payload_o =
            {3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};

        for (candidate_idx = 0;
             candidate_idx < 3;
             candidate_idx = candidate_idx + 1) begin
            selected_pipe = candidate_pipe_i[
                candidate_idx*`OPENRV64_EXEC_PIPE_WIDTH +:
                `OPENRV64_EXEC_PIPE_WIDTH];

            // Route the oldest candidate payload speculatively so each lane
            // can compute capability/order-sensitive ready without a
            // ready->fire->payload combinational loop.  pipe_valid_o remains
            // the only acceptance qualifier.
            if (candidate_valid_i[candidate_idx] &&
                pipe_select_valid(selected_pipe) &&
                !route_claimed[selected_pipe]) begin
                route_claimed[selected_pipe] = 1'b1;
                case (selected_pipe)
                    `OPENRV64_EXEC_PIPE_EX0: begin
                        pipe_valid_o[0] = candidate_fire_o[candidate_idx];
                        pipe_id_o[0*64 +: 64] =
                            candidate_id_i[candidate_idx*64 +: 64];
                        pipe_slot_o[0*RETIRE_SLOT_WIDTH +:
                                    RETIRE_SLOT_WIDTH] =
                            candidate_slot_i[
                                candidate_idx*RETIRE_SLOT_WIDTH +:
                                RETIRE_SLOT_WIDTH];
                        pipe_payload_o[
                            0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] =
                            candidate_payload_i[
                                candidate_idx*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
                    end

                    `OPENRV64_EXEC_PIPE_EX1: begin
                        pipe_valid_o[1] = candidate_fire_o[candidate_idx];
                        pipe_id_o[1*64 +: 64] =
                            candidate_id_i[candidate_idx*64 +: 64];
                        pipe_slot_o[1*RETIRE_SLOT_WIDTH +:
                                    RETIRE_SLOT_WIDTH] =
                            candidate_slot_i[
                                candidate_idx*RETIRE_SLOT_WIDTH +:
                                RETIRE_SLOT_WIDTH];
                        pipe_payload_o[
                            1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] =
                            candidate_payload_i[
                                candidate_idx*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
                    end

                    `OPENRV64_EXEC_PIPE_MEM: begin
                        pipe_valid_o[2] = candidate_fire_o[candidate_idx];
                        pipe_id_o[2*64 +: 64] =
                            candidate_id_i[candidate_idx*64 +: 64];
                        pipe_slot_o[2*RETIRE_SLOT_WIDTH +:
                                    RETIRE_SLOT_WIDTH] =
                            candidate_slot_i[
                                candidate_idx*RETIRE_SLOT_WIDTH +:
                                RETIRE_SLOT_WIDTH];
                        pipe_payload_o[
                            2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] =
                            candidate_payload_i[
                                candidate_idx*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

endmodule
