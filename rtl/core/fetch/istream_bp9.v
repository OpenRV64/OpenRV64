`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

// Nonblocking Tomasulo stream-RLE to BP9 refinement adapter.
//
// Every RLE result passes to the FTQ immediately.  A conditional hit may also
// borrow the BP9 direction read port.  The eventual result is returned as a
// token-tagged refinement.  Fetch currently accepts only exact-path
// confirmation on an unconsumed FTQ boundary; a changed path is left to the
// authoritative decode prediction because the frontend does not yet carry an
// emitted/decoded generation watermark.  Predictor-port contention can delay
// or drop refinement, but can never stop RLE/FTQ progress.
//
// A small FIFO decouples bursty autonomous RLE output from the shared TAGE
// read port.  One issued request may be outstanding; its response may retire
// while the next queued request launches, sustaining one refinement per cycle
// when the predictor port is available.  This is advisory state, not
// correctness state, and overflow still cannot block RLE/FTQ progress.
module openrv64_fetch_istream_bp9 #(
    parameter integer CANDIDATE_DEPTH = 8,
    parameter integer CANDIDATE_INDEX_WIDTH = $clog2(CANDIDATE_DEPTH),
    parameter integer CANDIDATE_COUNT_WIDTH = $clog2(CANDIDATE_DEPTH + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         cancel_i,
    input  wire                         enable_i,

    input  wire                         btb_valid_i,
    output wire                         btb_ready_o,
    input  wire [31:0]                  btb_request_id_i,
    input  wire [`RV64_XLEN-1:0]        btb_stream_pc_i,
    input  wire                         btb_hit_i,
    input  wire [`RV64_XLEN-1:0]        btb_control_pc_i,
    input  wire [`RV64_XLEN-1:0]        btb_control_end_pc_i,
    input  wire [2:0]                   btb_control_class_i,
    input  wire                         btb_conditional_i,
    input  wire [`RV64_XLEN-1:0]        btb_target_pc_i,
    input  wire [`RV64_XLEN-1:0]        btb_successor_pc_i,
    input  wire                         btb_taken_i,
    input  wire [31:0]                  btb_prediction_token_i,

    output wire                         response_valid_o,
    input  wire                         response_ready_i,
    output wire [31:0]                  response_request_id_o,
    output wire [`RV64_XLEN-1:0]        response_stream_pc_o,
    output wire                         response_hit_o,
    output wire [`RV64_XLEN-1:0]        response_control_pc_o,
    output wire [`RV64_XLEN-1:0]        response_control_end_pc_o,
    output wire [2:0]                   response_control_class_o,
    output wire [`RV64_XLEN-1:0]        response_successor_pc_o,
    output wire                         response_taken_o,
    output wire [31:0]                  response_prediction_token_o,

    output wire                         tage_lookup_valid_o,
    input  wire                         tage_lookup_accept_i,
    output wire [`RV64_XLEN-1:0]        tage_lookup_pc_o,
    output wire                         tage_lookup_backward_o,
    output wire [31:0]                  tage_lookup_token_o,
    input  wire                         tage_response_valid_i,
    input  wire [`RV64_XLEN-1:0]        tage_response_pc_i,
    input  wire                         tage_response_taken_i,

    output wire                         refinement_valid_o,
    output wire [31:0]                  refinement_prediction_token_o,
    output wire [`RV64_XLEN-1:0]        refinement_control_pc_o,
    output wire                         refinement_taken_o,
    output wire [`RV64_XLEN-1:0]        refinement_successor_pc_o,

    output wire                         diag_early_candidate_o,
    output wire                         diag_early_lookup_o,
    output wire                         diag_early_response_o,
    output wire                         diag_early_taken_o,
    output wire                         diag_early_busy_skip_o,
    output wire [CANDIDATE_COUNT_WIDTH-1:0]
                                            diag_early_queue_count_o
);
    reg [`RV64_XLEN-1:0]
        candidate_control_pc_q [0:CANDIDATE_DEPTH-1];
    reg [`RV64_XLEN-1:0]
        candidate_control_end_pc_q [0:CANDIDATE_DEPTH-1];
    reg [`RV64_XLEN-1:0]
        candidate_target_pc_q [0:CANDIDATE_DEPTH-1];
    reg [31:0] candidate_prediction_token_q [0:CANDIDATE_DEPTH-1];
    reg [CANDIDATE_INDEX_WIDTH-1:0] candidate_head_q;
    reg [CANDIDATE_INDEX_WIDTH-1:0] candidate_tail_q;
    reg [CANDIDATE_COUNT_WIDTH-1:0] candidate_count_q;

    reg inflight_valid_q;
    reg [`RV64_XLEN-1:0] inflight_control_pc_q;
    reg [`RV64_XLEN-1:0] inflight_control_end_pc_q;
    reg [`RV64_XLEN-1:0] inflight_target_pc_q;
    reg [31:0] inflight_prediction_token_q;

    wire response_fire = btb_valid_i && btb_ready_o;
    wire incoming_candidate = enable_i && !cancel_i && response_fire &&
                              btb_hit_i &&
                              btb_conditional_i;
    wire tage_response_match = inflight_valid_q &&
        tage_response_valid_i &&
        (tage_response_pc_i == inflight_control_pc_q);
    wire inflight_slot_available = !inflight_valid_q ||
                                   tage_response_match;
    wire candidate_available = candidate_count_q != 0;
    wire candidate_pop = !cancel_i && candidate_available &&
        inflight_slot_available && tage_lookup_accept_i;
    wire candidate_space = candidate_count_q != CANDIDATE_DEPTH;
    wire candidate_enqueue = incoming_candidate &&
        (candidate_space || candidate_pop);

    assign response_valid_o = btb_valid_i && !cancel_i;
    assign btb_ready_o = cancel_i || response_ready_i;
    assign response_request_id_o = btb_request_id_i;
    assign response_stream_pc_o = btb_stream_pc_i;
    assign response_hit_o = btb_hit_i;
    assign response_control_pc_o = btb_control_pc_i;
    assign response_control_end_pc_o = btb_control_end_pc_i;
    assign response_control_class_o = btb_control_class_i;
    assign response_successor_pc_o = btb_successor_pc_i;
    assign response_taken_o = btb_taken_i;
    assign response_prediction_token_o = btb_prediction_token_i;

    // Incoming RLE results always enter the FIFO first.  This keeps the new
    // request off the RLE response-ready path while allowing a completed
    // inflight response and the next registered candidate to overlap.
    assign tage_lookup_valid_o = !cancel_i && candidate_available &&
                                 inflight_slot_available;
    assign tage_lookup_pc_o =
        candidate_control_pc_q[candidate_head_q];
    assign tage_lookup_backward_o =
        candidate_target_pc_q[candidate_head_q] <
        candidate_control_pc_q[candidate_head_q];
    assign tage_lookup_token_o =
        candidate_prediction_token_q[candidate_head_q];

    assign refinement_valid_o = !cancel_i && tage_response_match;
    assign refinement_prediction_token_o = inflight_prediction_token_q;
    assign refinement_control_pc_o = inflight_control_pc_q;
    assign refinement_taken_o = tage_response_taken_i;
    assign refinement_successor_pc_o = tage_response_taken_i ?
        inflight_target_pc_q : inflight_control_end_pc_q;

    assign diag_early_candidate_o = incoming_candidate;
    assign diag_early_lookup_o = tage_lookup_valid_o &&
                                 tage_lookup_accept_i;
    assign diag_early_response_o = refinement_valid_o;
    assign diag_early_taken_o = refinement_valid_o &&
                                tage_response_taken_i;
    assign diag_early_busy_skip_o = incoming_candidate &&
                                    !candidate_space && !candidate_pop;
    assign diag_early_queue_count_o = candidate_count_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            candidate_head_q <= {CANDIDATE_INDEX_WIDTH{1'b0}};
            candidate_tail_q <= {CANDIDATE_INDEX_WIDTH{1'b0}};
            candidate_count_q <= {CANDIDATE_COUNT_WIDTH{1'b0}};
            inflight_valid_q <= 1'b0;
            inflight_control_pc_q <= {`RV64_XLEN{1'b0}};
            inflight_control_end_pc_q <= {`RV64_XLEN{1'b0}};
            inflight_target_pc_q <= {`RV64_XLEN{1'b0}};
            inflight_prediction_token_q <= 32'd0;
        end else if (cancel_i) begin
            candidate_head_q <= {CANDIDATE_INDEX_WIDTH{1'b0}};
            candidate_tail_q <= {CANDIDATE_INDEX_WIDTH{1'b0}};
            candidate_count_q <= {CANDIDATE_COUNT_WIDTH{1'b0}};
            inflight_valid_q <= 1'b0;
        end else begin
            if (tage_response_match)
                inflight_valid_q <= 1'b0;

            if (candidate_pop) begin
                candidate_head_q <= candidate_head_q + 1'b1;
                inflight_valid_q <= 1'b1;
                inflight_control_pc_q <=
                    candidate_control_pc_q[candidate_head_q];
                inflight_control_end_pc_q <=
                    candidate_control_end_pc_q[candidate_head_q];
                inflight_target_pc_q <=
                    candidate_target_pc_q[candidate_head_q];
                inflight_prediction_token_q <=
                    candidate_prediction_token_q[candidate_head_q];
            end

            if (candidate_enqueue) begin
                candidate_control_pc_q[candidate_tail_q] <=
                    btb_control_pc_i;
                candidate_control_end_pc_q[candidate_tail_q] <=
                    btb_control_end_pc_i;
                candidate_target_pc_q[candidate_tail_q] <=
                    btb_target_pc_i;
                candidate_prediction_token_q[candidate_tail_q] <=
                    btb_prediction_token_i;
                candidate_tail_q <= candidate_tail_q + 1'b1;
            end

            case ({candidate_enqueue, candidate_pop})
                2'b10: candidate_count_q <= candidate_count_q + 1'b1;
                2'b01: candidate_count_q <= candidate_count_q - 1'b1;
                default: begin
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((CANDIDATE_DEPTH < 2) ||
            ((1 << CANDIDATE_INDEX_WIDTH) != CANDIDATE_DEPTH))
            $fatal(1, "istream BP9 candidate depth must be a power of two");
    end

    always @(posedge clk) begin
        if (rst_n && refinement_valid_o &&
            !inflight_valid_q)
            $fatal(1, "istream BP9 refined an unissued candidate");
        if (rst_n && response_fire && !cancel_i && !response_valid_o)
            $fatal(1, "istream BP9 blocked the RLE pass-through");
        if (rst_n && (candidate_count_q > CANDIDATE_DEPTH))
            $fatal(1, "istream BP9 candidate FIFO overflow");
    end
`endif
endmodule
