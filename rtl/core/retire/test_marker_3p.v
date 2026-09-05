`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/except/except-defs.v"

// Retirement-side recognition for repository-local test-control sequences:
//
//     addi x0, x0, marker_id
//     ebreak
//
// Recognition happens only across accepted, adjacent architectural PCs.  A
// wrong-path HINT therefore cannot affect measurement state.  The EBREAK is
// still classified as a persistent hard-order instruction by dispatch, but
// its exception/halt result is cleared before retirement so it releases that
// barrier as an ordinary no-effect instruction.
module openrv64_test_marker_3p #(
    parameter integer ENABLE = 0,
    parameter integer META_WIDTH = `OPENRV64_RETIRE_ALLOC_WIDTH,
    parameter integer RESULT_WIDTH = `OPENRV64_RETIRE_RESULT_WIDTH
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire [2:0]                   queue_valid_i,
    input  wire [2:0]                   queue_accept_i,
    input  wire [3*META_WIDTH-1:0]      queue_meta_i,
    input  wire [3*RESULT_WIDTH-1:0]    queue_result_i,
    output wire [3*RESULT_WIDTH-1:0]    queue_result_o,
    output wire                         start_test_o,
    output wire                         start_trace_o,
    output wire                         end_trace_o
);

    localparam integer META_PC = `OPENRV64_RETIRE_ALLOC_PC_LSB;
    localparam integer META_INSTR = `OPENRV64_RETIRE_ALLOC_INSTR_LSB;
    localparam integer RESULT_CAUSE = `OPENRV64_RETIRE_RESULT_CAUSE_LSB;
    localparam integer RESULT_HALT = `OPENRV64_RETIRE_RESULT_HALT_BIT;
    localparam integer RESULT_EXCEPTION =
        `OPENRV64_RETIRE_RESULT_EXCEPTION_BIT;

    localparam [1:0] MARKER_NONE = 2'd0;
    localparam [1:0] MARKER_START_TEST = 2'd1;
    localparam [1:0] MARKER_START_TRACE = 2'd2;
    localparam [1:0] MARKER_END_TRACE = 2'd3;

    reg [1:0] pending_hint_kind_q;
    reg [`RV64_XLEN-1:0] pending_hint_pc_q;
    reg start_test_q;
    reg start_trace_q;
    reg end_trace_q;

    wire [`RV64_XLEN-1:0] pc0 = queue_meta_i[
        0*META_WIDTH + META_PC +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] pc1 = queue_meta_i[
        1*META_WIDTH + META_PC +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] pc2 = queue_meta_i[
        2*META_WIDTH + META_PC +: `RV64_XLEN];
    wire [`RV64_INSTR_WIDTH-1:0] instr0 = queue_meta_i[
        0*META_WIDTH + META_INSTR +: `RV64_INSTR_WIDTH];
    wire [`RV64_INSTR_WIDTH-1:0] instr1 = queue_meta_i[
        1*META_WIDTH + META_INSTR +: `RV64_INSTR_WIDTH];
    wire [`RV64_INSTR_WIDTH-1:0] instr2 = queue_meta_i[
        2*META_WIDTH + META_INSTR +: `RV64_INSTR_WIDTH];

    function automatic [1:0] marker_hint_kind;
        input [`RV64_INSTR_WIDTH-1:0] instr;
        begin
            case (instr)
                `OPENRV64_INSTR_START_TEST_HINT:
                    marker_hint_kind = MARKER_START_TEST;
                `OPENRV64_INSTR_START_TRACE_HINT:
                    marker_hint_kind = MARKER_START_TRACE;
                `OPENRV64_INSTR_END_TRACE_HINT:
                    marker_hint_kind = MARKER_END_TRACE;
                default: marker_hint_kind = MARKER_NONE;
            endcase
        end
    endfunction

    wire [1:0] hint_kind0 = queue_valid_i[0] ?
        marker_hint_kind(instr0) : MARKER_NONE;
    wire [1:0] hint_kind1 = queue_valid_i[1] ?
        marker_hint_kind(instr1) : MARKER_NONE;
    wire [1:0] hint_kind2 = queue_valid_i[2] ?
        marker_hint_kind(instr2) : MARKER_NONE;
    wire ebreak0 = queue_valid_i[0] &&
        (instr0 == `RV64_INSTR_EBREAK);
    wire ebreak1 = queue_valid_i[1] &&
        (instr1 == `RV64_INSTR_EBREAK);
    wire ebreak2 = queue_valid_i[2] &&
        (instr2 == `RV64_INSTR_EBREAK);

    wire tagged0 = (ENABLE != 0) &&
        (pending_hint_kind_q != MARKER_NONE) && ebreak0 &&
        (pc0 == (pending_hint_pc_q + 64'd4));
    wire tagged1 = (ENABLE != 0) && (hint_kind0 != MARKER_NONE) && ebreak1 &&
        (pc1 == (pc0 + 64'd4));
    wire tagged2 = (ENABLE != 0) && (hint_kind1 != MARKER_NONE) && ebreak2 &&
        (pc2 == (pc1 + 64'd4));
    wire [2:0] tagged_ebreak = {tagged2, tagged1, tagged0};
    wire start_test_accept =
        (tagged0 && queue_accept_i[0] &&
         (pending_hint_kind_q == MARKER_START_TEST)) ||
        (tagged1 && queue_accept_i[1] &&
         (hint_kind0 == MARKER_START_TEST)) ||
        (tagged2 && queue_accept_i[2] &&
         (hint_kind1 == MARKER_START_TEST));
    wire start_trace_accept =
        (tagged0 && queue_accept_i[0] &&
         (pending_hint_kind_q == MARKER_START_TRACE)) ||
        (tagged1 && queue_accept_i[1] &&
         (hint_kind0 == MARKER_START_TRACE)) ||
        (tagged2 && queue_accept_i[2] &&
         (hint_kind1 == MARKER_START_TRACE));
    wire end_trace_accept =
        (tagged0 && queue_accept_i[0] &&
         (pending_hint_kind_q == MARKER_END_TRACE)) ||
        (tagged1 && queue_accept_i[1] &&
         (hint_kind0 == MARKER_END_TRACE)) ||
        (tagged2 && queue_accept_i[2] &&
         (hint_kind1 == MARKER_END_TRACE));

    function automatic [RESULT_WIDTH-1:0] marker_result;
        input [RESULT_WIDTH-1:0] raw_result;
        input is_tagged;
        begin
            marker_result = raw_result;
            if (is_tagged) begin
                marker_result[RESULT_EXCEPTION] = 1'b0;
                marker_result[RESULT_HALT] = 1'b0;
                marker_result[
                    RESULT_CAUSE +: `RV64_EXCEPT_CAUSE_WIDTH] =
                    {`RV64_EXCEPT_CAUSE_WIDTH{1'b0}};
            end
        end
    endfunction

    assign queue_result_o[0*RESULT_WIDTH +: RESULT_WIDTH] =
        marker_result(queue_result_i[
            0*RESULT_WIDTH +: RESULT_WIDTH], tagged0);
    assign queue_result_o[1*RESULT_WIDTH +: RESULT_WIDTH] =
        marker_result(queue_result_i[
            1*RESULT_WIDTH +: RESULT_WIDTH], tagged1);
    assign queue_result_o[2*RESULT_WIDTH +: RESULT_WIDTH] =
        marker_result(queue_result_i[
            2*RESULT_WIDTH +: RESULT_WIDTH], tagged2);
    assign start_test_o = (ENABLE != 0) && start_test_q;
    assign start_trace_o = (ENABLE != 0) && start_trace_q;
    assign end_trace_o = (ENABLE != 0) && end_trace_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_i) begin
            pending_hint_kind_q <= MARKER_NONE;
            pending_hint_pc_q <= {`RV64_XLEN{1'b0}};
            start_test_q <= 1'b0;
            start_trace_q <= 1'b0;
            end_trace_q <= 1'b0;
        end else begin
            start_test_q <= start_test_accept;
            start_trace_q <= start_trace_accept;
            end_trace_q <= end_trace_accept;

            // The youngest accepted instruction determines split-group state.
            // This preserves a new lane-2 hint when an older marker also
            // completes in lanes 0-1 of the same retirement group.
            if (queue_accept_i[2]) begin
                pending_hint_kind_q <= hint_kind2;
                pending_hint_pc_q <= pc2;
            end else if (queue_accept_i[1]) begin
                pending_hint_kind_q <= hint_kind1;
                pending_hint_pc_q <= pc1;
            end else if (queue_accept_i[0]) begin
                pending_hint_kind_q <= hint_kind0;
                pending_hint_pc_q <= pc0;
            end
        end
    end

endmodule
