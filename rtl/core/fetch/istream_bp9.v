`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

// Tomasulo fetch-stream adapter for the synchronous BP9 direction tables.
//
// The stream BTB discovers the next control before decode.  Unconditional
// controls and misses pass through immediately.  A conditional hit is held at
// the BTB response boundary while this adapter issues a direction-only TAGE
// lookup.  The FTQ therefore receives one final successor rather than first
// following BTFNT and later repairing the queued stream.
//
// The ordinary decode lookup remains authoritative for allocation, history,
// RAS state, and training context.  This adapter is observational and may be
// denied the shared read port without affecting correctness; in that case the
// BTB response remains held until the request is accepted.  It is instantiated
// only by the Tomasulo fetch_istream path.
module openrv64_fetch_istream_bp9 (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         cancel_i,
    input  wire                         enable_i,

    input  wire                         btb_valid_i,
    output wire                         btb_ready_o,
    input  wire [31:0]                  btb_request_id_i,
    input  wire                         btb_hit_i,
    input  wire [`RV64_XLEN-1:0]        btb_control_pc_i,
    input  wire [`RV64_XLEN-1:0]        btb_control_end_pc_i,
    input  wire                         btb_conditional_i,
    input  wire [`RV64_XLEN-1:0]        btb_target_pc_i,
    input  wire [`RV64_XLEN-1:0]        btb_successor_pc_i,
    input  wire                         btb_taken_i,
    input  wire [31:0]                  btb_prediction_token_i,

    output wire                         response_valid_o,
    input  wire                         response_ready_i,
    output wire [31:0]                  response_request_id_o,
    output wire                         response_hit_o,
    output wire [`RV64_XLEN-1:0]        response_control_pc_o,
    output wire [`RV64_XLEN-1:0]        response_control_end_pc_o,
    output wire [`RV64_XLEN-1:0]        response_successor_pc_o,
    output wire                         response_taken_o,
    output wire [31:0]                  response_prediction_token_o,

    output wire                         tage_lookup_valid_o,
    input  wire                         tage_lookup_accept_i,
    output wire [`RV64_XLEN-1:0]        tage_lookup_pc_o,
    output wire                         tage_lookup_backward_o,
    input  wire                         tage_response_valid_i,
    input  wire [`RV64_XLEN-1:0]        tage_response_pc_i,
    input  wire                         tage_response_taken_i,

    output wire                         diag_early_candidate_o,
    output wire                         diag_early_lookup_o,
    output wire                         diag_early_response_o,
    output wire                         diag_early_taken_o
);
    reg tage_pending_q;
    reg [`RV64_XLEN-1:0] tage_pending_pc_q;
    reg tage_result_valid_q;
    reg tage_result_taken_q;
    reg tage_candidate_seen_q;

    wire conditional_hit = enable_i && btb_valid_i && btb_hit_i &&
                           btb_conditional_i;
    wire tage_response_match = tage_pending_q && tage_response_valid_i &&
        (tage_response_pc_i == tage_pending_pc_q) &&
        (btb_control_pc_i == tage_pending_pc_q);
    wire tage_result_available = tage_result_valid_q || tage_response_match;
    wire tage_result_taken = tage_result_valid_q ? tage_result_taken_q :
                                                   tage_response_taken_i;
    wire conditional_response_valid = conditional_hit &&
                                      tage_result_available;
    wire passthrough = !conditional_hit;

    assign tage_lookup_valid_o = conditional_hit && !tage_pending_q &&
                                 !cancel_i;
    assign tage_lookup_pc_o = btb_control_pc_i;
    assign tage_lookup_backward_o = btb_target_pc_i < btb_control_pc_i;

    assign response_valid_o = !cancel_i && btb_valid_i &&
        (passthrough || conditional_response_valid);
    assign response_request_id_o = btb_request_id_i;
    assign response_hit_o = btb_hit_i;
    assign response_control_pc_o = btb_control_pc_i;
    assign response_control_end_pc_o = btb_control_end_pc_i;
    assign response_successor_pc_o = conditional_hit ?
        (tage_result_taken ? btb_target_pc_i : btb_control_end_pc_i) :
        btb_successor_pc_i;
    assign response_taken_o = conditional_hit ? tage_result_taken :
                                                btb_taken_i;
    assign response_prediction_token_o = btb_prediction_token_i;

    // The synchronous BTB holds its registered response while ready is low.
    // Retire it only after an unconditional/miss pass-through or the matching
    // TAGE response has been accepted by fetch_istream.
    assign btb_ready_o = cancel_i ||
        (response_valid_o && response_ready_i);

    assign diag_early_candidate_o = conditional_hit &&
                                    !tage_candidate_seen_q;
    assign diag_early_lookup_o = tage_lookup_valid_o &&
                                 tage_lookup_accept_i;
    assign diag_early_response_o = conditional_response_valid &&
                                   response_ready_i;
    assign diag_early_taken_o = diag_early_response_o &&
                                tage_result_taken;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tage_pending_q <= 1'b0;
            tage_pending_pc_q <= {`RV64_XLEN{1'b0}};
            tage_result_valid_q <= 1'b0;
            tage_result_taken_q <= 1'b0;
            tage_candidate_seen_q <= 1'b0;
        end else if (cancel_i) begin
            tage_pending_q <= 1'b0;
            tage_result_valid_q <= 1'b0;
            tage_candidate_seen_q <= 1'b0;
        end else begin
            if (conditional_hit && !tage_candidate_seen_q)
                tage_candidate_seen_q <= 1'b1;
            if (btb_ready_o && btb_valid_i)
                tage_candidate_seen_q <= 1'b0;

            if (tage_lookup_valid_o && tage_lookup_accept_i) begin
                tage_pending_q <= 1'b1;
                tage_pending_pc_q <= btb_control_pc_i;
            end

            // BP9 has no response backpressure.  Bypass its response directly
            // when fetch_istream is ready, otherwise retain the direction until
            // the held stream-BTB response can be consumed.
            if (tage_response_match) begin
                tage_pending_q <= 1'b0;
                tage_result_taken_q <= tage_response_taken_i;
                tage_result_valid_q <= !response_ready_i;
            end else if (tage_result_valid_q && conditional_hit &&
                         response_ready_i) begin
                tage_result_valid_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && tage_pending_q && btb_valid_i &&
            (btb_control_pc_i != tage_pending_pc_q))
            $fatal(1, "istream BP9 adapter lost held BTB response");
        if (rst_n && diag_early_response_o && !btb_conditional_i)
            $fatal(1, "istream BP9 response lost conditional class");
        if (rst_n && tage_result_valid_q && !tage_pending_q &&
            btb_valid_i && (btb_control_pc_i != tage_pending_pc_q))
            $fatal(1, "istream BP9 adapter changed held result identity");
    end
`endif
endmodule
