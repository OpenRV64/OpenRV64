`timescale 1ns/1ps
`include "core/backend/backend-defs.v"

// Converts three program-ordered candidates into four physical pipe inputs.
// A candidate fires only if every older valid candidate fires in the same
// cycle.  This is the central in-order issue rule: an idle ALU cannot accept a
// younger instruction around an older dependency, full pipe, or MEM stall.
module openrv64_dispatch_issue_3p #(
    parameter integer RETIRE_SLOT_WIDTH = 3
) (
    input  wire [2:0]                   candidate_valid_i,
    input  wire [2:0]                   candidate_allow_i,
    input  wire [2:0]                   candidate_free_i,
    input  wire [3*`OPENRV64_EXEC_PIPE_WIDTH-1:0] candidate_pipe_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] candidate_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] candidate_slot_i,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        candidate_payload_i,

    input  wire                         allocation_ready_i,
    input  wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_ready_i,

    output wire [2:0]                   candidate_fire_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_valid_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0] pipe_id_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH-1:0]
                                        pipe_slot_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
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
                (pipe_select == `OPENRV64_EXEC_PIPE_MEM0) ||
                (pipe_select == `OPENRV64_EXEC_PIPE_MEM1);
        end
    endfunction

    function automatic selected_pipe_ready;
        input [`OPENRV64_EXEC_PIPE_WIDTH-1:0] pipe_select;
        input [`OPENRV64_EXEC_PIPE_COUNT-1:0] ready_mask;
        begin
            case (pipe_select)
                `OPENRV64_EXEC_PIPE_EX0:
                    selected_pipe_ready = ready_mask[0];
                `OPENRV64_EXEC_PIPE_EX1:
                    selected_pipe_ready = ready_mask[1];
                `OPENRV64_EXEC_PIPE_MEM0:
                    selected_pipe_ready = ready_mask[2];
                `OPENRV64_EXEC_PIPE_MEM1:
                    selected_pipe_ready = ready_mask[3];
                default:
                    selected_pipe_ready = 1'b0;
            endcase
        end
    endfunction

    wire candidate0_fire = candidate_valid_i[0] &&
                           candidate_allow_i[0] &&
                           allocation_ready_i &&
                           (candidate_free_i[0] ||
                            (pipe_select_valid(candidate_pipe0) &&
                             selected_pipe_ready(candidate_pipe0,
                                                 pipe_ready_i)));
    wire candidate1_pipe_free = !candidate0_fire || candidate_free_i[0] ||
                                (candidate_pipe1 != candidate_pipe0);
    wire candidate1_fire = candidate_valid_i[1] &&
                           candidate0_fire &&
                           candidate_allow_i[1] &&
                           candidate1_pipe_free &&
                           (candidate_free_i[1] ||
                            (pipe_select_valid(candidate_pipe1) &&
                             selected_pipe_ready(candidate_pipe1,
                                                 pipe_ready_i)));
    wire candidate2_pipe_free =
        (!candidate0_fire || candidate_free_i[0] ||
         (candidate_pipe2 != candidate_pipe0)) &&
        (!candidate1_fire || candidate_free_i[1] ||
         (candidate_pipe2 != candidate_pipe1));
    wire candidate2_fire = candidate_valid_i[2] &&
                           candidate1_fire &&
                           candidate_allow_i[2] &&
                           candidate2_pipe_free &&
                           (candidate_free_i[2] ||
                            (pipe_select_valid(candidate_pipe2) &&
                             selected_pipe_ready(candidate_pipe2,
                                                 pipe_ready_i)));

    assign candidate_fire_o = {
        candidate2_fire,
        candidate1_fire,
        candidate0_fire
    };

    integer payload_candidate_idx;
    reg [`OPENRV64_EXEC_PIPE_WIDTH-1:0] payload_selected_pipe;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0] payload_route_claimed;
    always @* begin
        payload_route_claimed = {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        pipe_id_o =
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_INSTR_ID_WIDTH{1'b0}};
        pipe_slot_o =
            {`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH{1'b0}};
        pipe_payload_o =
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};

        for (payload_candidate_idx = 0;
             payload_candidate_idx < 3;
             payload_candidate_idx = payload_candidate_idx + 1) begin
            payload_selected_pipe = candidate_pipe_i[
                payload_candidate_idx*`OPENRV64_EXEC_PIPE_WIDTH +:
                `OPENRV64_EXEC_PIPE_WIDTH];

            // Route payload and identity independently of candidate_fire_o.
            // Execution-lane ready may depend on the routed operation, so
            // combining this with the valid mux creates a process-level
            // ready -> fire -> payload loop in synthesis and Verilator.
            if (candidate_valid_i[payload_candidate_idx] &&
                !candidate_free_i[payload_candidate_idx] &&
                pipe_select_valid(payload_selected_pipe) &&
                !payload_route_claimed[payload_selected_pipe]) begin
                payload_route_claimed[payload_selected_pipe] = 1'b1;
                pipe_id_o[
                    payload_selected_pipe*`OPENRV64_INSTR_ID_WIDTH +:
                    `OPENRV64_INSTR_ID_WIDTH] =
                    candidate_id_i[
                        payload_candidate_idx*`OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH];
                pipe_slot_o[
                    payload_selected_pipe*RETIRE_SLOT_WIDTH +:
                    RETIRE_SLOT_WIDTH] =
                    candidate_slot_i[
                        payload_candidate_idx*RETIRE_SLOT_WIDTH +:
                        RETIRE_SLOT_WIDTH];
                pipe_payload_o[
                    payload_selected_pipe*
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] =
                    candidate_payload_i[
                        payload_candidate_idx*
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
            end
        end
    end

    integer valid_candidate_idx;
    reg [`OPENRV64_EXEC_PIPE_WIDTH-1:0] valid_selected_pipe;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0] valid_route_claimed;
    always @* begin
        pipe_valid_o = {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        valid_route_claimed = {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};

        for (valid_candidate_idx = 0;
             valid_candidate_idx < 3;
             valid_candidate_idx = valid_candidate_idx + 1) begin
            valid_selected_pipe = candidate_pipe_i[
                valid_candidate_idx*`OPENRV64_EXEC_PIPE_WIDTH +:
                `OPENRV64_EXEC_PIPE_WIDTH];
            if (candidate_valid_i[valid_candidate_idx] &&
                !candidate_free_i[valid_candidate_idx] &&
                pipe_select_valid(valid_selected_pipe) &&
                !valid_route_claimed[valid_selected_pipe]) begin
                valid_route_claimed[valid_selected_pipe] = 1'b1;
                pipe_valid_o[valid_selected_pipe] =
                    candidate_fire_o[valid_candidate_idx];
            end
        end
    end

endmodule
