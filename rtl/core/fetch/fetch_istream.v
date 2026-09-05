`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/fetch/fetch-defs.v"

// Throughput-oriented instruction-stream frontend.
//
// Unlike fetch_3w, this block does not treat a prediction as a late restart.
// The predictor describes the next control in an open stream segment.  A hit
// closes that segment at the exclusive end PC of the control and appends the
// selected successor as a new segment in the fetch-target queue (FTQ).  Decode
// can see all halfwords of the control, but never its sequential suffix.  When
// decode consumes through the control end, presentation moves directly to the
// already-prefetched successor segment.
//
// Predictor contract:
//   * lookup_pc_o names the first halfword to search within a 16-byte sector.
//   * a hit returns the earliest control in that sector at or after lookup PC.
//   * control_end_pc_i is exclusive and is control_pc_i + 2 or + 4.
//   * successor_pc_i is the already-selected next PC (taken or fallthrough).
//   * prediction_token_i is carried beside the control to decode/ROB.
//
// Presentation is a raw, contiguous halfword window.  Fetch never inspects an
// instruction encoding.  Decode owns instruction-length discovery,
// decompression, and its two-byte partial-instruction stash.  Decode reports
// the number of halfwords removed; complete undispatched instructions remain
// in this module's presentation buffer.
module openrv64_fetch_istream #(
    parameter integer FETCH_DATA_WIDTH = 256,
    parameter integer BLOCK_DEPTH = 16,
    parameter integer PENDING_DEPTH = 8,
    parameter integer FTQ_DEPTH = 8,
    parameter integer LOOKAHEAD_BLOCKS = 4,
    parameter integer PREDICT_LOOKAHEAD_SECTORS = 8,
    parameter integer PREDICTION_TOKEN_WIDTH = 32,
    parameter integer GENERATION_WIDTH = 16,
    parameter integer DECODE_WIDTH = 3,
    parameter integer ISTREAM_HALFWORDS = DECODE_WIDTH * 2,
    parameter integer BLOCK_INDEX_WIDTH = $clog2(BLOCK_DEPTH),
    parameter integer PENDING_INDEX_WIDTH = $clog2(PENDING_DEPTH),
    parameter integer FTQ_INDEX_WIDTH = $clog2(FTQ_DEPTH),
    parameter integer FTQ_COUNT_WIDTH = $clog2(FTQ_DEPTH + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,

    // restart_i installs a new architectural stream.  invalidate_i also drops
    // buffered instruction data.  redirect_i is a speculative correction: it
    // rebuilds the FTQ but preserves address-tagged instruction data.
    input  wire                         restart_i,
    input  wire [`RV64_XLEN-1:0]        restart_pc_i,
    input  wire                         redirect_i,
    input  wire [`RV64_XLEN-1:0]        redirect_pc_i,
    input  wire                         invalidate_i,
    input  wire                         flush_i,
    input  wire                         stall_i,
    output wire                         cancel_o,

    // Tagged-by-address instruction-block interface.  Several requests may be
    // outstanding.  Future FTQ segment starts are stash/prefetch requests;
    // active-stream and sequential-lookahead requests are demand qualified.
    output wire                         req_valid_o,
    input  wire                         req_ready_i,
    output wire [`RV64_XLEN-1:0]        req_addr_o,
    output wire                         req_stash_o,
    output wire                         req_demand_o,
    input  wire                         resp_valid_i,
    output wire                         resp_ready_o,
    input  wire [`RV64_XLEN-1:0]        resp_addr_i,
    input  wire [FETCH_DATA_WIDTH-1:0] resp_data_i,
    input  wire                         resp_access_fault_i,
    input  wire                         resp_page_fault_i,

    // Direct next-control predictor interface.
    output wire                         btb_lookup_valid_o,
    input  wire                         btb_lookup_ready_i,
    output wire [`RV64_XLEN-1:0]        btb_lookup_pc_o,
    output wire [31:0]                  btb_lookup_request_id_o,
    input  wire                         btb_response_valid_i,
    input  wire [31:0]                  btb_response_request_id_i,
    input  wire                         btb_response_hit_i,
    input  wire [`RV64_XLEN-1:0]        btb_response_control_pc_i,
    input  wire [`RV64_XLEN-1:0]        btb_response_control_end_pc_i,
    input  wire [`RV64_XLEN-1:0]        btb_response_successor_pc_i,
    input  wire                         btb_response_taken_i,
    input  wire [PREDICTION_TOKEN_WIDTH-1:0]
                                            btb_response_prediction_token_i,
    output wire                         btb_response_ready_o,

    // Raw decode window.  Valid is a contiguous prefix from stream_pc_o.
    // Decode may remove zero through ISTREAM_HALFWORDS parcels.  A final
    // lower half of a 32-bit instruction is consumed into decode's two-byte
    // stash; its upper half then arrives as window halfword zero.
    output wire                         istream_valid_o,
    output wire [ISTREAM_HALFWORDS*16-1:0] istream_data_o,
    output wire [ISTREAM_HALFWORDS-1:0]  istream_halfword_valid_o,
    output wire [ISTREAM_HALFWORDS-1:0]  istream_access_fault_o,
    output wire [ISTREAM_HALFWORDS-1:0]  istream_page_fault_o,
    // Full-width, all-compressed fast path.  This consumes DECODE_WIDTH
    // halfwords.  Mixed or partially accepted groups instead use the exact
    // count below; the two inputs must not be asserted together.
    input  wire                         istream_advance_half_i,
    input  wire [3:0]                   istream_consume_halfwords_i,
    output wire [`RV64_XLEN-1:0]        stream_pc_o,

    // Prediction metadata describes the active segment boundary.  It remains
    // valid while a split control is completed from decode's partial stash.
    output wire                         istream_prediction_valid_o,
    output wire [`RV64_XLEN-1:0]        istream_control_pc_o,
    output wire [`RV64_XLEN-1:0]        istream_control_end_pc_o,
    output wire [`RV64_XLEN-1:0]        istream_prediction_successor_o,
    output wire                         istream_prediction_taken_o,
    output wire [PREDICTION_TOKEN_WIDTH-1:0]
                                            istream_prediction_token_o,
    // Decode must validate that the predicted boundary is an actual control.
    // A rejection resumes sequentially at the boundary end and discards the
    // predicted suffix; this makes stale/code-aliased BTB contents safe.
    input  wire                         istream_prediction_accept_i,

    output wire [GENERATION_WIDTH-1:0]  stream_generation_o,
    output wire [FTQ_COUNT_WIDTH-1:0]   ftq_count_o,
    output wire                         presentation_ready_o,
    output wire                         demand_pending_any_o,
    output wire                         current_block_pending_o,
    output wire                         predicted_transfer_valid_o,
    output wire                         predicted_reject_valid_o,
    output wire [`RV64_XLEN-1:0]        predicted_transfer_source_pc_o,
    output wire [`RV64_XLEN-1:0]        predicted_transfer_target_pc_o,
    output wire [PREDICTION_TOKEN_WIDTH-1:0]
                                            predicted_transfer_token_o
);

    localparam integer BLOCK_BYTES = FETCH_DATA_WIDTH / 8;
    localparam integer BLOCK_BYTE_BITS = $clog2(BLOCK_BYTES);
    localparam integer SECTOR_BYTES = 16;
    localparam integer SECTOR_BYTE_BITS = 4;
    localparam integer SECTORS_PER_BLOCK = BLOCK_BYTES / SECTOR_BYTES;
    localparam integer PRESENT_BYTES = 32;
    localparam integer PRESENT_COUNT_WIDTH = $clog2(PRESENT_BYTES + 1);
    localparam integer REQUEST_CANDIDATES =
        1 + (FTQ_DEPTH - 1) + LOOKAHEAD_BLOCKS;

    reg active_q;
    reg [GENERATION_WIDTH-1:0] generation_q;

    // The arrays are deliberately address tagged and independent of FTQ
    // lifetime.  A corrected stream may reuse data fetched by a wrong path.
    reg block_valid_q [0:BLOCK_DEPTH-1];
    reg [`RV64_XLEN-1:0] block_addr_q [0:BLOCK_DEPTH-1];
    reg [FETCH_DATA_WIDTH-1:0] block_data_q [0:BLOCK_DEPTH-1];
    reg block_access_fault_q [0:BLOCK_DEPTH-1];
    reg block_page_fault_q [0:BLOCK_DEPTH-1];
    reg [BLOCK_INDEX_WIDTH-1:0] block_replace_q;

    reg pending_valid_q [0:PENDING_DEPTH-1];
    reg [`RV64_XLEN-1:0] pending_addr_q [0:PENDING_DEPTH-1];

    // Every valid entry describes one dynamic stream segment.  Exactly the
    // tail entry is open (end_valid=0); all older entries end at a predicted
    // control and name the selected next segment.
    reg ftq_valid_q [0:FTQ_DEPTH-1];
    reg ftq_end_valid_q [0:FTQ_DEPTH-1];
    reg [`RV64_XLEN-1:0] ftq_start_pc_q [0:FTQ_DEPTH-1];
    reg [`RV64_XLEN-1:0] ftq_control_pc_q [0:FTQ_DEPTH-1];
    reg [`RV64_XLEN-1:0] ftq_control_end_pc_q [0:FTQ_DEPTH-1];
    reg [`RV64_XLEN-1:0] ftq_successor_pc_q [0:FTQ_DEPTH-1];
    reg ftq_prediction_taken_q [0:FTQ_DEPTH-1];
    reg [PREDICTION_TOKEN_WIDTH-1:0]
        ftq_prediction_token_q [0:FTQ_DEPTH-1];
    reg [GENERATION_WIDTH-1:0] ftq_generation_q [0:FTQ_DEPTH-1];
    reg [FTQ_INDEX_WIDTH-1:0] ftq_head_q;
    reg [FTQ_INDEX_WIDTH-1:0] ftq_tail_q;
    reg [FTQ_COUNT_WIDTH-1:0] ftq_count_q;

    // One predictor request may be outstanding.  The request ID and captured
    // FTQ identity make late responses harmless after a redirect or slot reuse.
    reg [`RV64_XLEN-1:0] btb_scan_pc_q;
    reg [31:0] btb_next_request_id_q;
    reg btb_outstanding_q;
    reg [31:0] btb_outstanding_request_id_q;
    reg [`RV64_XLEN-1:0] btb_outstanding_pc_q;
    reg [FTQ_INDEX_WIDTH-1:0] btb_outstanding_slot_q;
    reg [GENERATION_WIDTH-1:0] btb_outstanding_generation_q;

    // Low bytes always begin at present_pc_q.  The absolute byte immediately
    // after the skid contents is sector aligned except for an empty buffer
    // immediately after restart/redirect.
    reg [`RV64_XLEN-1:0] present_pc_q;
    reg [PRESENT_BYTES*8-1:0] present_data_q;
    reg [PRESENT_BYTES-1:0] present_access_fault_q;
    reg [PRESENT_BYTES-1:0] present_page_fault_q;
    reg [PRESENT_COUNT_WIDTH-1:0] present_count_q;

    assign cancel_o = restart_i || invalidate_i || flush_i;
    assign resp_ready_o = 1'b1;
    assign btb_response_ready_o = 1'b1;
    assign stream_pc_o = present_pc_q;
    assign stream_generation_o = generation_q;
    assign ftq_count_o = ftq_count_q;
    assign presentation_ready_o = istream_valid_o;

    reg demand_pending_any_r;
    reg current_block_pending_r;
    integer debug_pending_index;
    always @* begin
        demand_pending_any_r = 1'b0;
        current_block_pending_r = 1'b0;
        for (debug_pending_index = 0;
             debug_pending_index < PENDING_DEPTH;
             debug_pending_index = debug_pending_index + 1) begin
            if (pending_valid_q[debug_pending_index]) begin
                demand_pending_any_r = 1'b1;
                if (pending_addr_q[debug_pending_index][
                        `RV64_XLEN-1:BLOCK_BYTE_BITS] ==
                    present_pc_q[`RV64_XLEN-1:BLOCK_BYTE_BITS])
                    current_block_pending_r = 1'b1;
            end
        end
    end
    assign demand_pending_any_o = demand_pending_any_r;
    assign current_block_pending_o = current_block_pending_r;

    wire active_segment_end_valid = active_q && (ftq_count_q != 0) &&
        ftq_valid_q[ftq_head_q] && ftq_end_valid_q[ftq_head_q];
    wire [`RV64_XLEN-1:0] active_segment_control_pc =
        ftq_control_pc_q[ftq_head_q];
    wire [`RV64_XLEN-1:0] active_segment_control_end_pc =
        ftq_control_end_pc_q[ftq_head_q];
    wire [`RV64_XLEN-1:0] active_segment_last_byte_pc =
        active_segment_control_end_pc - 1'b1;
    wire [`RV64_XLEN-1:0] active_segment_successor_pc =
        ftq_successor_pc_q[ftq_head_q];
    wire active_segment_prediction_taken =
        ftq_prediction_taken_q[ftq_head_q];
    wire [PREDICTION_TOKEN_WIDTH-1:0] active_segment_prediction_token =
        ftq_prediction_token_q[ftq_head_q];

    // Qualify a raw halfword prefix.  This is boundary clipping only;
    // no instruction bits participate.  The exclusive end PC lets a 32-bit
    // control span two presentations without exposing its fallthrough suffix.
    reg [ISTREAM_HALFWORDS-1:0] istream_halfword_valid_r;
    reg [ISTREAM_HALFWORDS-1:0] istream_access_fault_r;
    reg [ISTREAM_HALFWORDS-1:0] istream_page_fault_r;
    reg [3:0] istream_halfword_count_r;
    integer halfword_index;
    always @* begin
        istream_halfword_valid_r = {ISTREAM_HALFWORDS{1'b0}};
        istream_access_fault_r = {ISTREAM_HALFWORDS{1'b0}};
        istream_page_fault_r = {ISTREAM_HALFWORDS{1'b0}};
        istream_halfword_count_r = 4'd0;
        for (halfword_index = 0; halfword_index < ISTREAM_HALFWORDS;
             halfword_index = halfword_index + 1) begin
            if (active_q && !flush_i &&
                (present_count_q >= ((halfword_index + 1) * 2)) &&
                (!active_segment_end_valid ||
                 ((present_pc_q + (halfword_index * 2)) <
                  active_segment_control_end_pc))) begin
                istream_halfword_valid_r[halfword_index] = 1'b1;
                istream_access_fault_r[halfword_index] =
                    present_access_fault_q[halfword_index*2] |
                    present_access_fault_q[halfword_index*2 + 1];
                istream_page_fault_r[halfword_index] =
                    present_page_fault_q[halfword_index*2] |
                    present_page_fault_q[halfword_index*2 + 1];
                istream_halfword_count_r = halfword_index + 1;
            end
        end
    end

    assign istream_valid_o = istream_halfword_valid_r[0];
    assign istream_data_o =
        present_data_q[ISTREAM_HALFWORDS*16-1:0];
    assign istream_halfword_valid_o = istream_halfword_valid_r;
    assign istream_access_fault_o = istream_access_fault_r;
    assign istream_page_fault_o = istream_page_fault_r;
    assign istream_prediction_valid_o = active_segment_end_valid;
    assign istream_control_pc_o = active_segment_control_pc;
    assign istream_control_end_pc_o = active_segment_control_end_pc;
    assign istream_prediction_successor_o = active_segment_successor_pc;
    assign istream_prediction_taken_o = active_segment_prediction_taken;
    assign istream_prediction_token_o = active_segment_prediction_token;

    localparam [3:0] ISTREAM_HALF_ADVANCE = DECODE_WIDTH;
    wire [3:0] istream_requested_halfwords = istream_advance_half_i ?
        ISTREAM_HALF_ADVANCE : istream_consume_halfwords_i;
    wire istream_consume_valid = istream_valid_o &&
        (istream_requested_halfwords != 0) &&
        (istream_requested_halfwords <= istream_halfword_count_r);
    wire [4:0] istream_consumed_bytes = istream_consume_valid ?
        {istream_requested_halfwords, 1'b0} : 5'd0;
    wire [`RV64_XLEN-1:0] istream_consumed_pc =
        present_pc_q + istream_consumed_bytes;
    wire predicted_boundary_fire = istream_consume_valid &&
        active_segment_end_valid &&
        (istream_consumed_pc == active_segment_control_end_pc);
    wire predicted_transfer_fire = predicted_boundary_fire &&
        istream_prediction_accept_i;
    wire predicted_reject_fire = predicted_boundary_fire &&
        !istream_prediction_accept_i;

    assign predicted_transfer_valid_o = predicted_transfer_fire;
    assign predicted_reject_valid_o = predicted_reject_fire;
    assign predicted_transfer_source_pc_o = active_segment_control_pc;
    assign predicted_transfer_target_pc_o = active_segment_successor_pc;
    assign predicted_transfer_token_o = active_segment_prediction_token;

    // Predictor scanning is independent of instruction-data readiness.  It
    // walks the open tail segment a sector at a time, but stops at a bounded
    // horizon until that segment becomes active and advances.
    wire [`RV64_XLEN-1:0] tail_scan_base =
        (ftq_tail_q == ftq_head_q) ? present_pc_q :
            ftq_start_pc_q[ftq_tail_q];
    wire [`RV64_XLEN-1:0] tail_scan_limit = tail_scan_base +
        ((PREDICT_LOOKAHEAD_SECTORS - 1) * SECTOR_BYTES);
    wire btb_tail_open = active_q && (ftq_count_q != 0) &&
        ftq_valid_q[ftq_tail_q] && !ftq_end_valid_q[ftq_tail_q];
    wire btb_response_match = btb_response_valid_i && btb_outstanding_q &&
        (btb_response_request_id_i == btb_outstanding_request_id_q);
    wire btb_response_slot_live =
        ftq_valid_q[btb_outstanding_slot_q] &&
        !ftq_end_valid_q[btb_outstanding_slot_q] &&
        (ftq_tail_q == btb_outstanding_slot_q) &&
        (ftq_generation_q[btb_outstanding_slot_q] ==
         btb_outstanding_generation_q) &&
        (generation_q == btb_outstanding_generation_q);
    wire btb_response_control_in_sector =
        (btb_response_control_pc_i[`RV64_XLEN-1:SECTOR_BYTE_BITS] ==
         btb_outstanding_pc_q[`RV64_XLEN-1:SECTOR_BYTE_BITS]);
    wire btb_response_not_behind =
        (btb_response_control_pc_i >=
         ftq_start_pc_q[btb_outstanding_slot_q]) &&
        ((btb_outstanding_slot_q != ftq_head_q) ||
         // Decode and the synchronous BTB response can advance on the same
         // edge.  Compare against post-consumption progress so a late hit
         // cannot install a boundary for a control already consumed.
         (btb_response_control_pc_i >= istream_consumed_pc));
    wire [`RV64_XLEN-1:0] btb_response_control_bytes =
        btb_response_control_end_pc_i - btb_response_control_pc_i;
    wire btb_response_control_length_valid =
        (btb_response_control_bytes == 2) ||
        (btb_response_control_bytes == 4);
    wire btb_append_segment = btb_response_match &&
        btb_response_hit_i && btb_response_slot_live &&
        btb_response_control_in_sector && btb_response_not_behind &&
        !btb_response_control_pc_i[0] &&
        !btb_response_control_end_pc_i[0] &&
        btb_response_control_length_valid &&
        !btb_response_successor_pc_i[0] &&
        (ftq_count_q < FTQ_DEPTH);

    // The directory itself accepts a lookup every cycle.  Retire its current
    // synchronous miss and launch the next sector on the same cycle, instead
    // of imposing an artificial empty cycle between requests.  A hit creates
    // a new FTQ segment.  It may chain directly only when closing the sole FTQ
    // entry; once a speculative segment is already queued, hit chaining waits
    // for registered topology rather than recursively outrunning recovery.
    wire btb_pipeline_response = btb_response_match &&
        btb_response_slot_live && !predicted_reject_fire &&
        (!btb_append_segment || (ftq_count_q == 1));
    wire [`RV64_XLEN-1:0] btb_pipeline_next_pc = btb_append_segment ?
        btb_response_successor_pc_i :
        ({btb_outstanding_pc_q[`RV64_XLEN-1:SECTOR_BYTE_BITS],
          {SECTOR_BYTE_BITS{1'b0}}} + SECTOR_BYTES);
    wire [FTQ_INDEX_WIDTH-1:0] btb_pipeline_next_slot =
        btb_append_segment ?
            ((ftq_tail_q + 1'b1) & (FTQ_DEPTH - 1)) :
            btb_outstanding_slot_q;
    wire [`RV64_XLEN-1:0] btb_pipeline_scan_base =
        btb_append_segment ? btb_response_successor_pc_i : tail_scan_base;
    wire [`RV64_XLEN-1:0] btb_pipeline_scan_limit =
        btb_pipeline_scan_base +
        ((PREDICT_LOOKAHEAD_SECTORS - 1) * SECTOR_BYTES);
    wire btb_pipeline_room = btb_append_segment ?
        (predicted_transfer_fire ||
         (ftq_count_q < (FTQ_DEPTH - 1))) :
        (predicted_transfer_fire || (ftq_count_q < FTQ_DEPTH));
    wire btb_pipeline_lookup = btb_pipeline_response &&
        btb_pipeline_room &&
        (btb_pipeline_next_pc <= btb_pipeline_scan_limit);
    wire btb_idle_lookup = btb_tail_open && !btb_outstanding_q &&
        (ftq_count_q < FTQ_DEPTH) && (btb_scan_pc_q <= tail_scan_limit);
    assign btb_lookup_valid_o =
        (btb_pipeline_lookup || btb_idle_lookup) &&
        !restart_i && !redirect_i && !flush_i && !stall_i;
    assign btb_lookup_pc_o = btb_pipeline_lookup ?
        btb_pipeline_next_pc : btb_scan_pc_q;
    assign btb_lookup_request_id_o = btb_next_request_id_q;
    wire [FTQ_INDEX_WIDTH-1:0] btb_lookup_slot =
        btb_pipeline_lookup ? btb_pipeline_next_slot : ftq_tail_q;
    wire btb_lookup_fire = btb_lookup_valid_o && btb_lookup_ready_i;
    wire [`RV64_XLEN-1:0] stream_rebuild_pc = restart_i ?
        restart_pc_i : redirect_pc_i;
    wire [`RV64_XLEN-1:0] consumed_sector_pc = {
        istream_consumed_pc[`RV64_XLEN-1:SECTOR_BYTE_BITS],
        {SECTOR_BYTE_BITS{1'b0}}
    };

    // Build ordered request candidates: current demand first, then the start
    // of each predicted future segment, then sequential active-stream depth.
    reg request_candidate_valid_r [0:REQUEST_CANDIDATES-1];
    reg request_candidate_stash_r [0:REQUEST_CANDIDATES-1];
    reg [`RV64_XLEN-1:0]
        request_candidate_addr_r [0:REQUEST_CANDIDATES-1];
    integer candidate_index;
    integer candidate_slot;
    integer future_index;
    integer lookahead_index;
    always @* begin
        for (candidate_index = 0;
             candidate_index < REQUEST_CANDIDATES;
             candidate_index = candidate_index + 1) begin
            request_candidate_valid_r[candidate_index] = 1'b0;
            request_candidate_stash_r[candidate_index] = 1'b0;
            request_candidate_addr_r[candidate_index] =
                {`RV64_XLEN{1'b0}};
        end

        request_candidate_valid_r[0] = active_q;
        request_candidate_addr_r[0] = {
            present_pc_q[`RV64_XLEN-1:BLOCK_BYTE_BITS],
            {BLOCK_BYTE_BITS{1'b0}}
        };

        for (future_index = 1; future_index < FTQ_DEPTH;
             future_index = future_index + 1) begin
            candidate_slot = (ftq_head_q + future_index) &
                             (FTQ_DEPTH - 1);
            request_candidate_valid_r[future_index] =
                (future_index < ftq_count_q) &&
                ftq_valid_q[candidate_slot];
            request_candidate_stash_r[future_index] = 1'b1;
            request_candidate_addr_r[future_index] = {
                ftq_start_pc_q[candidate_slot][
                    `RV64_XLEN-1:BLOCK_BYTE_BITS],
                {BLOCK_BYTE_BITS{1'b0}}
            };
        end

        for (lookahead_index = 0;
             lookahead_index < LOOKAHEAD_BLOCKS;
             lookahead_index = lookahead_index + 1) begin
            request_candidate_addr_r[FTQ_DEPTH + lookahead_index] =
                {present_pc_q[`RV64_XLEN-1:BLOCK_BYTE_BITS],
                 {BLOCK_BYTE_BITS{1'b0}}} +
                ((lookahead_index + 1) * BLOCK_BYTES);
            request_candidate_valid_r[FTQ_DEPTH + lookahead_index] =
                active_q &&
                (!active_segment_end_valid ||
                 (request_candidate_addr_r[
                    FTQ_DEPTH + lookahead_index] <=
                  {active_segment_last_byte_pc[
                    `RV64_XLEN-1:BLOCK_BYTE_BITS],
                   {BLOCK_BYTE_BITS{1'b0}}}));
            request_candidate_stash_r[FTQ_DEPTH + lookahead_index] = 1'b0;
        end
    end

    reg pending_free_valid_r;
    reg [PENDING_INDEX_WIDTH-1:0] pending_free_index_r;
    integer pending_free_scan;
    always @* begin
        pending_free_valid_r = 1'b0;
        pending_free_index_r = {PENDING_INDEX_WIDTH{1'b0}};
        for (pending_free_scan = 0; pending_free_scan < PENDING_DEPTH;
             pending_free_scan = pending_free_scan + 1) begin
            if (!pending_free_valid_r &&
                !pending_valid_q[pending_free_scan]) begin
                pending_free_valid_r = 1'b1;
                pending_free_index_r = pending_free_scan;
            end
        end
    end

    reg request_select_valid_r;
    reg request_select_stash_r;
    reg [`RV64_XLEN-1:0] request_select_addr_r;
    reg candidate_resident_r;
    reg candidate_pending_r;
    integer request_select_scan;
    integer request_block_scan;
    integer request_pending_scan;
    always @* begin
        request_select_valid_r = 1'b0;
        request_select_stash_r = 1'b0;
        request_select_addr_r = {`RV64_XLEN{1'b0}};
        candidate_resident_r = 1'b0;
        candidate_pending_r = 1'b0;
        for (request_select_scan = 0;
             request_select_scan < REQUEST_CANDIDATES;
             request_select_scan = request_select_scan + 1) begin
            candidate_resident_r = 1'b0;
            candidate_pending_r = 1'b0;
            for (request_block_scan = 0;
                 request_block_scan < BLOCK_DEPTH;
                 request_block_scan = request_block_scan + 1) begin
                if (block_valid_q[request_block_scan] &&
                    (block_addr_q[request_block_scan][
                        `RV64_XLEN-1:BLOCK_BYTE_BITS] ==
                     request_candidate_addr_r[request_select_scan][
                        `RV64_XLEN-1:BLOCK_BYTE_BITS]))
                    candidate_resident_r = 1'b1;
            end
            for (request_pending_scan = 0;
                 request_pending_scan < PENDING_DEPTH;
                 request_pending_scan = request_pending_scan + 1) begin
                if (pending_valid_q[request_pending_scan] &&
                    (pending_addr_q[request_pending_scan][
                        `RV64_XLEN-1:BLOCK_BYTE_BITS] ==
                     request_candidate_addr_r[request_select_scan][
                        `RV64_XLEN-1:BLOCK_BYTE_BITS]))
                    candidate_pending_r = 1'b1;
            end
            if (!request_select_valid_r &&
                request_candidate_valid_r[request_select_scan] &&
                !candidate_resident_r && !candidate_pending_r) begin
                request_select_valid_r = 1'b1;
                request_select_stash_r =
                    request_candidate_stash_r[request_select_scan];
                request_select_addr_r =
                    request_candidate_addr_r[request_select_scan];
            end
        end
    end

    assign req_valid_o = active_q && pending_free_valid_r &&
        request_select_valid_r && !restart_i && !invalidate_i &&
        !redirect_i && !flush_i && !stall_i;
    assign req_addr_o = request_select_addr_r;
    assign req_stash_o = request_select_stash_r;
    assign req_demand_o = !request_select_stash_r;
    wire req_fire = req_valid_o && req_ready_i;

    // Match a response to its outstanding address and locate its destination
    // block entry.  Responses from canceled architectural contexts are ignored.
    reg response_pending_hit_r;
    reg [PENDING_INDEX_WIDTH-1:0] response_pending_index_r;
    reg response_block_hit_r;
    reg [BLOCK_INDEX_WIDTH-1:0] response_block_index_r;
    reg response_block_free_found_r;
    integer response_pending_scan;
    integer response_block_scan;
    always @* begin
        response_pending_hit_r = 1'b0;
        response_pending_index_r = {PENDING_INDEX_WIDTH{1'b0}};
        for (response_pending_scan = 0;
             response_pending_scan < PENDING_DEPTH;
             response_pending_scan = response_pending_scan + 1) begin
            if (!response_pending_hit_r &&
                pending_valid_q[response_pending_scan] &&
                (pending_addr_q[response_pending_scan][
                    `RV64_XLEN-1:BLOCK_BYTE_BITS] ==
                 resp_addr_i[`RV64_XLEN-1:BLOCK_BYTE_BITS])) begin
                response_pending_hit_r = 1'b1;
                response_pending_index_r = response_pending_scan;
            end
        end

        response_block_hit_r = 1'b0;
        response_block_free_found_r = 1'b0;
        response_block_index_r = block_replace_q;
        for (response_block_scan = 0;
             response_block_scan < BLOCK_DEPTH;
             response_block_scan = response_block_scan + 1) begin
            if (!response_block_hit_r && block_valid_q[response_block_scan] &&
                (block_addr_q[response_block_scan][
                    `RV64_XLEN-1:BLOCK_BYTE_BITS] ==
                 resp_addr_i[`RV64_XLEN-1:BLOCK_BYTE_BITS])) begin
                response_block_hit_r = 1'b1;
                response_block_index_r = response_block_scan;
            end
        end
        for (response_block_scan = 0;
             response_block_scan < BLOCK_DEPTH;
             response_block_scan = response_block_scan + 1) begin
            if (!response_block_hit_r && !response_block_free_found_r &&
                !block_valid_q[response_block_scan]) begin
                response_block_free_found_r = 1'b1;
                response_block_index_r = response_block_scan;
            end
        end
    end

    // Select the sector which should be appended to the presentation skid.
    // On a predicted transfer this is the successor sector; otherwise it is
    // the byte immediately following the post-consumption skid contents.
    reg [PRESENT_BYTES*8-1:0] present_after_data_r;
    reg [PRESENT_BYTES-1:0] present_after_access_fault_r;
    reg [PRESENT_BYTES-1:0] present_after_page_fault_r;
    reg [PRESENT_COUNT_WIDTH-1:0] present_after_count_r;
    reg [`RV64_XLEN-1:0] present_after_pc_r;
    reg refill_wanted_r;
    reg [`RV64_XLEN-1:0] refill_byte_pc_r;
    reg [`RV64_XLEN-1:0] refill_sector_addr_r;
    always @* begin
        present_after_data_r = present_data_q >>
                               (istream_consumed_bytes * 8);
        present_after_access_fault_r = present_access_fault_q >>
                                       istream_consumed_bytes;
        present_after_page_fault_r = present_page_fault_q >>
                                     istream_consumed_bytes;
        present_after_count_r = present_count_q - istream_consumed_bytes;
        present_after_pc_r = present_pc_q + istream_consumed_bytes;
        if (predicted_transfer_fire || redirect_i) begin
            present_after_data_r = {PRESENT_BYTES*8{1'b0}};
            present_after_access_fault_r = {PRESENT_BYTES{1'b0}};
            present_after_page_fault_r = {PRESENT_BYTES{1'b0}};
            present_after_count_r = {PRESENT_COUNT_WIDTH{1'b0}};
            present_after_pc_r = redirect_i ? redirect_pc_i :
                                               active_segment_successor_pc;
        end
        refill_wanted_r = active_q &&
                          (present_after_count_r <= SECTOR_BYTES);
        refill_byte_pc_r = present_after_pc_r + present_after_count_r;
        refill_sector_addr_r = {
            refill_byte_pc_r[`RV64_XLEN-1:SECTOR_BYTE_BITS],
            {SECTOR_BYTE_BITS{1'b0}}
        };
    end

    reg refill_sector_valid_r;
    reg [127:0] refill_sector_data_r;
    reg refill_sector_access_fault_r;
    reg refill_sector_page_fault_r;
    integer refill_block_scan;
    integer refill_sector_select;
    always @* begin
        refill_sector_valid_r = 1'b0;
        refill_sector_data_r = 128'd0;
        refill_sector_access_fault_r = 1'b0;
        refill_sector_page_fault_r = 1'b0;
        refill_sector_select = refill_sector_addr_r[SECTOR_BYTE_BITS +:
                                                     $clog2(SECTORS_PER_BLOCK)];
        for (refill_block_scan = 0;
             refill_block_scan < BLOCK_DEPTH;
             refill_block_scan = refill_block_scan + 1) begin
            if (!refill_sector_valid_r && block_valid_q[refill_block_scan] &&
                (block_addr_q[refill_block_scan][
                    `RV64_XLEN-1:BLOCK_BYTE_BITS] ==
                 refill_sector_addr_r[
                    `RV64_XLEN-1:BLOCK_BYTE_BITS])) begin
                refill_sector_valid_r = 1'b1;
                refill_sector_data_r = block_data_q[refill_block_scan][
                    refill_sector_select*128 +: 128];
                refill_sector_access_fault_r =
                    block_access_fault_q[refill_block_scan];
                refill_sector_page_fault_r =
                    block_page_fault_q[refill_block_scan];
            end
        end
        // A returning demand or lookahead block can feed presentation on the
        // same edge it is installed in the address-tagged block buffer.
        // Without this bypass every local-buffer miss adds a gratuitous cycle
        // after the L1I response is already available.
        if (resp_valid_i && response_pending_hit_r &&
            (resp_addr_i[`RV64_XLEN-1:BLOCK_BYTE_BITS] ==
             refill_sector_addr_r[`RV64_XLEN-1:BLOCK_BYTE_BITS])) begin
            refill_sector_valid_r = 1'b1;
            refill_sector_data_r = resp_data_i[
                refill_sector_select*128 +: 128];
            refill_sector_access_fault_r = resp_access_fault_i;
            refill_sector_page_fault_r = resp_page_fault_i;
        end
    end

    // A control target may begin in the final halfword of a sector.  Loading
    // only that sector would expose a short decode window for one cycle on
    // every such transfer even when the following bytes are already resident.
    // Read the immediately following sector in parallel and use it to finish
    // the presentation window.  The instruction block store is already an
    // asynchronously selected multi-entry buffer, so this adds no state or
    // response latency.
    wire [`RV64_XLEN-1:0] refill_second_sector_addr =
        refill_sector_addr_r + SECTOR_BYTES;
    reg refill_second_sector_valid_r;
    reg [127:0] refill_second_sector_data_r;
    reg refill_second_sector_access_fault_r;
    reg refill_second_sector_page_fault_r;
    integer refill_second_block_scan;
    integer refill_second_sector_select;
    always @* begin
        refill_second_sector_valid_r = 1'b0;
        refill_second_sector_data_r = 128'd0;
        refill_second_sector_access_fault_r = 1'b0;
        refill_second_sector_page_fault_r = 1'b0;
        refill_second_sector_select =
            refill_second_sector_addr[SECTOR_BYTE_BITS +:
                                      $clog2(SECTORS_PER_BLOCK)];
        for (refill_second_block_scan = 0;
             refill_second_block_scan < BLOCK_DEPTH;
             refill_second_block_scan = refill_second_block_scan + 1) begin
            if (!refill_second_sector_valid_r &&
                block_valid_q[refill_second_block_scan] &&
                (block_addr_q[refill_second_block_scan][
                    `RV64_XLEN-1:BLOCK_BYTE_BITS] ==
                 refill_second_sector_addr[
                    `RV64_XLEN-1:BLOCK_BYTE_BITS])) begin
                refill_second_sector_valid_r = 1'b1;
                refill_second_sector_data_r =
                    block_data_q[refill_second_block_scan][
                        refill_second_sector_select*128 +: 128];
                refill_second_sector_access_fault_r =
                    block_access_fault_q[refill_second_block_scan];
                refill_second_sector_page_fault_r =
                    block_page_fault_q[refill_second_block_scan];
            end
        end
        if (resp_valid_i && response_pending_hit_r &&
            (resp_addr_i[`RV64_XLEN-1:BLOCK_BYTE_BITS] ==
             refill_second_sector_addr[
                `RV64_XLEN-1:BLOCK_BYTE_BITS])) begin
            refill_second_sector_valid_r = 1'b1;
            refill_second_sector_data_r = resp_data_i[
                refill_second_sector_select*128 +: 128];
            refill_second_sector_access_fault_r = resp_access_fault_i;
            refill_second_sector_page_fault_r = resp_page_fault_i;
        end
    end

    wire [3:0] refill_byte_offset = refill_byte_pc_r[3:0];
    wire [4:0] refill_byte_count = SECTOR_BYTES - refill_byte_offset;
    wire [127:0] refill_shifted_data = refill_sector_data_r >>
                                      (refill_byte_offset * 8);
    wire [15:0] refill_shifted_byte_mask = 16'hffff >>
                                           refill_byte_offset;
    wire [PRESENT_COUNT_WIDTH-1:0] refill_first_total_count =
        present_after_count_r + refill_byte_count;
    wire [PRESENT_COUNT_WIDTH-1:0] refill_second_capacity =
        PRESENT_BYTES - refill_first_total_count;
    wire [PRESENT_COUNT_WIDTH-1:0] refill_second_byte_count =
        (refill_second_capacity > SECTOR_BYTES) ? SECTOR_BYTES :
                                                 refill_second_capacity;
    wire refill_second_append = refill_second_sector_valid_r &&
                                (refill_second_byte_count != 0);
    wire [PRESENT_BYTES*8-1:0] refill_second_shifted_data =
        {{(PRESENT_BYTES*8-128){1'b0}}, refill_second_sector_data_r}
            << (refill_first_total_count * 8);
    wire [PRESENT_BYTES-1:0] refill_second_shifted_byte_mask =
        {{(PRESENT_BYTES-16){1'b0}}, 16'hffff}
            << refill_first_total_count;

    integer reset_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_q <= 1'b0;
            generation_q <= {GENERATION_WIDTH{1'b0}};
            ftq_head_q <= {FTQ_INDEX_WIDTH{1'b0}};
            ftq_tail_q <= {FTQ_INDEX_WIDTH{1'b0}};
            ftq_count_q <= {FTQ_COUNT_WIDTH{1'b0}};
            btb_scan_pc_q <= {`RV64_XLEN{1'b0}};
            btb_next_request_id_q <= 32'd1;
            btb_outstanding_q <= 1'b0;
            btb_outstanding_request_id_q <= 32'd0;
            btb_outstanding_pc_q <= {`RV64_XLEN{1'b0}};
            btb_outstanding_slot_q <= {FTQ_INDEX_WIDTH{1'b0}};
            btb_outstanding_generation_q <= {GENERATION_WIDTH{1'b0}};
            for (reset_index = 0; reset_index < FTQ_DEPTH;
                 reset_index = reset_index + 1) begin
                ftq_valid_q[reset_index] <= 1'b0;
                ftq_end_valid_q[reset_index] <= 1'b0;
                ftq_start_pc_q[reset_index] <= {`RV64_XLEN{1'b0}};
                ftq_control_pc_q[reset_index] <= {`RV64_XLEN{1'b0}};
                ftq_control_end_pc_q[reset_index] <=
                    {`RV64_XLEN{1'b0}};
                ftq_successor_pc_q[reset_index] <= {`RV64_XLEN{1'b0}};
                ftq_prediction_taken_q[reset_index] <= 1'b0;
                ftq_prediction_token_q[reset_index] <=
                    {PREDICTION_TOKEN_WIDTH{1'b0}};
                ftq_generation_q[reset_index] <=
                    {GENERATION_WIDTH{1'b0}};
            end
        end else if (restart_i || redirect_i) begin
            active_q <= 1'b1;
            generation_q <= generation_q + 1'b1;
            ftq_head_q <= {FTQ_INDEX_WIDTH{1'b0}};
            ftq_tail_q <= {FTQ_INDEX_WIDTH{1'b0}};
            ftq_count_q <= {{(FTQ_COUNT_WIDTH-1){1'b0}}, 1'b1};
            ftq_valid_q[0] <= 1'b1;
            ftq_end_valid_q[0] <= 1'b0;
            ftq_start_pc_q[0] <= stream_rebuild_pc;
            ftq_generation_q[0] <= generation_q + 1'b1;
            btb_scan_pc_q <= stream_rebuild_pc;
            btb_outstanding_q <= 1'b0;
            for (reset_index = 1; reset_index < FTQ_DEPTH;
                 reset_index = reset_index + 1) begin
                ftq_valid_q[reset_index] <= 1'b0;
                ftq_end_valid_q[reset_index] <= 1'b0;
            end
        end else if (flush_i) begin
            active_q <= 1'b0;
            ftq_count_q <= {FTQ_COUNT_WIDTH{1'b0}};
            btb_outstanding_q <= 1'b0;
            for (reset_index = 0; reset_index < FTQ_DEPTH;
                 reset_index = reset_index + 1) begin
                ftq_valid_q[reset_index] <= 1'b0;
                ftq_end_valid_q[reset_index] <= 1'b0;
            end
        end else if (predicted_reject_fire) begin
            // A BTB may be stale or may alias code changed at the same VA.
            // Decode proved the claimed boundary is not a control.  Keep the
            // already-consumed sequential PC, but discard every speculative
            // segment derived from the rejected entry.
            generation_q <= generation_q + 1'b1;
            ftq_head_q <= {FTQ_INDEX_WIDTH{1'b0}};
            ftq_tail_q <= {FTQ_INDEX_WIDTH{1'b0}};
            ftq_count_q <= {{(FTQ_COUNT_WIDTH-1){1'b0}}, 1'b1};
            ftq_valid_q[0] <= 1'b1;
            ftq_end_valid_q[0] <= 1'b0;
            ftq_start_pc_q[0] <= active_segment_control_end_pc;
            ftq_generation_q[0] <= generation_q + 1'b1;
            btb_scan_pc_q <= active_segment_control_end_pc;
            btb_outstanding_q <= 1'b0;
            for (reset_index = 1; reset_index < FTQ_DEPTH;
                 reset_index = reset_index + 1) begin
                ftq_valid_q[reset_index] <= 1'b0;
                ftq_end_valid_q[reset_index] <= 1'b0;
            end
        end else begin
            if (btb_response_match) begin
                btb_outstanding_q <= 1'b0;
                if (btb_append_segment) begin
                    ftq_end_valid_q[ftq_tail_q] <= 1'b1;
                    ftq_control_pc_q[ftq_tail_q] <=
                        btb_response_control_pc_i;
                    ftq_control_end_pc_q[ftq_tail_q] <=
                        btb_response_control_end_pc_i;
                    ftq_successor_pc_q[ftq_tail_q] <=
                        btb_response_successor_pc_i;
                    ftq_prediction_taken_q[ftq_tail_q] <=
                        btb_response_taken_i;
                    ftq_prediction_token_q[ftq_tail_q] <=
                        btb_response_prediction_token_i;
                    ftq_valid_q[(ftq_tail_q + 1'b1) &
                                (FTQ_DEPTH - 1)] <= 1'b1;
                    ftq_end_valid_q[(ftq_tail_q + 1'b1) &
                                    (FTQ_DEPTH - 1)] <= 1'b0;
                    ftq_start_pc_q[(ftq_tail_q + 1'b1) &
                                   (FTQ_DEPTH - 1)] <=
                        btb_response_successor_pc_i;
                    ftq_generation_q[(ftq_tail_q + 1'b1) &
                                     (FTQ_DEPTH - 1)] <= generation_q;
                    ftq_tail_q <= (ftq_tail_q + 1'b1) & (FTQ_DEPTH - 1);
                    btb_scan_pc_q <= btb_response_successor_pc_i;
                end else begin
                    btb_scan_pc_q <= {
                        btb_outstanding_pc_q[
                            `RV64_XLEN-1:SECTOR_BYTE_BITS],
                        {SECTOR_BYTE_BITS{1'b0}}
                    } + SECTOR_BYTES;
                end
            end
            // This follows response retirement deliberately: a pipelined
            // response/lookup pair leaves the newly launched request live.
            if (btb_lookup_fire) begin
                btb_outstanding_q <= 1'b1;
                btb_outstanding_request_id_q <= btb_next_request_id_q;
                btb_outstanding_pc_q <= btb_lookup_pc_o;
                btb_outstanding_slot_q <= btb_lookup_slot;
                btb_outstanding_generation_q <= generation_q;
                btb_next_request_id_q <= btb_next_request_id_q + 1'b1;
            end

            if (predicted_transfer_fire) begin
                ftq_valid_q[ftq_head_q] <= 1'b0;
                ftq_head_q <= (ftq_head_q + 1'b1) & (FTQ_DEPTH - 1);
            end

            case ({btb_append_segment, predicted_transfer_fire})
                2'b10: ftq_count_q <= ftq_count_q + 1'b1;
                2'b01: ftq_count_q <= ftq_count_q - 1'b1;
                default: begin
                end
            endcase

            // Once an open active segment consumes beyond a previously scanned
            // sector, move the lookup cursor forward rather than querying stale
            // addresses behind decode.
            if (!btb_outstanding_q && !btb_response_match &&
                (ftq_tail_q == ftq_head_q) &&
                !ftq_end_valid_q[ftq_tail_q] &&
                (consumed_sector_pc > btb_scan_pc_q))
                btb_scan_pc_q <= consumed_sector_pc;
        end
    end

    // Presentation state.  A ready successor sector is loaded on the transfer
    // edge, which is the FAL fast path.  Otherwise the empty skid waits for the
    // ordinary instruction-buffer fill and resumes without a stream restart.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            present_pc_q <= {`RV64_XLEN{1'b0}};
            present_data_q <= {PRESENT_BYTES*8{1'b0}};
            present_access_fault_q <= {PRESENT_BYTES{1'b0}};
            present_page_fault_q <= {PRESENT_BYTES{1'b0}};
            present_count_q <= {PRESENT_COUNT_WIDTH{1'b0}};
        end else if (restart_i) begin
            present_pc_q <= restart_pc_i;
            present_data_q <= {PRESENT_BYTES*8{1'b0}};
            present_access_fault_q <= {PRESENT_BYTES{1'b0}};
            present_page_fault_q <= {PRESENT_BYTES{1'b0}};
            present_count_q <= {PRESENT_COUNT_WIDTH{1'b0}};
        end else if (redirect_i) begin
            // A predictor correction stays in the same architectural fetch
            // context.  Reuse a resident target sector on the redirect edge;
            // outstanding address-tagged requests continue to completion.
            present_pc_q <= redirect_pc_i;
            present_data_q <= {PRESENT_BYTES*8{1'b0}};
            present_access_fault_q <= {PRESENT_BYTES{1'b0}};
            present_page_fault_q <= {PRESENT_BYTES{1'b0}};
            present_count_q <= {PRESENT_COUNT_WIDTH{1'b0}};
            if (refill_sector_valid_r) begin
                present_data_q <=
                    {{(PRESENT_BYTES*8-128){1'b0}}, refill_shifted_data};
                present_access_fault_q <=
                    {{(PRESENT_BYTES-16){1'b0}},
                     refill_shifted_byte_mask} &
                    {PRESENT_BYTES{refill_sector_access_fault_r}};
                present_page_fault_q <=
                    {{(PRESENT_BYTES-16){1'b0}},
                     refill_shifted_byte_mask} &
                    {PRESENT_BYTES{refill_sector_page_fault_r}};
                present_count_q <= refill_byte_count;
                if (refill_second_append) begin
                    present_data_q <=
                        {{(PRESENT_BYTES*8-128){1'b0}},
                          refill_shifted_data} |
                        refill_second_shifted_data;
                    present_access_fault_q <=
                        ({{(PRESENT_BYTES-16){1'b0}},
                           refill_shifted_byte_mask} &
                         {PRESENT_BYTES{refill_sector_access_fault_r}}) |
                        (refill_second_shifted_byte_mask &
                         {PRESENT_BYTES{
                            refill_second_sector_access_fault_r}});
                    present_page_fault_q <=
                        ({{(PRESENT_BYTES-16){1'b0}},
                           refill_shifted_byte_mask} &
                         {PRESENT_BYTES{refill_sector_page_fault_r}}) |
                        (refill_second_shifted_byte_mask &
                         {PRESENT_BYTES{
                            refill_second_sector_page_fault_r}});
                    present_count_q <= refill_first_total_count +
                                       refill_second_byte_count;
                end
            end
        end else if (flush_i || invalidate_i) begin
            present_access_fault_q <= {PRESENT_BYTES{1'b0}};
            present_page_fault_q <= {PRESENT_BYTES{1'b0}};
            present_count_q <= {PRESENT_COUNT_WIDTH{1'b0}};
        end else begin
            present_pc_q <= present_after_pc_r;
            present_data_q <= present_after_data_r;
            present_access_fault_q <= present_after_access_fault_r;
            present_page_fault_q <= present_after_page_fault_r;
            present_count_q <= present_after_count_r;
            if (refill_wanted_r && refill_sector_valid_r) begin
                present_data_q <= present_after_data_r |
                    ({{(PRESENT_BYTES*8-128){1'b0}}, refill_shifted_data}
                     << (present_after_count_r * 8));
                present_access_fault_q <= present_after_access_fault_r |
                    (({{(PRESENT_BYTES-16){1'b0}},
                       refill_shifted_byte_mask} &
                      {PRESENT_BYTES{refill_sector_access_fault_r}})
                     << present_after_count_r);
                present_page_fault_q <= present_after_page_fault_r |
                    (({{(PRESENT_BYTES-16){1'b0}},
                       refill_shifted_byte_mask} &
                      {PRESENT_BYTES{refill_sector_page_fault_r}})
                     << present_after_count_r);
                present_count_q <= present_after_count_r +
                                   refill_byte_count;
                if (refill_second_append) begin
                    present_data_q <= present_after_data_r |
                        ({{(PRESENT_BYTES*8-128){1'b0}},
                           refill_shifted_data}
                         << (present_after_count_r * 8)) |
                        refill_second_shifted_data;
                    present_access_fault_q <=
                        present_after_access_fault_r |
                        (({{(PRESENT_BYTES-16){1'b0}},
                            refill_shifted_byte_mask} &
                           {PRESENT_BYTES{refill_sector_access_fault_r}})
                         << present_after_count_r) |
                        (refill_second_shifted_byte_mask &
                         {PRESENT_BYTES{
                            refill_second_sector_access_fault_r}});
                    present_page_fault_q <=
                        present_after_page_fault_r |
                        (({{(PRESENT_BYTES-16){1'b0}},
                            refill_shifted_byte_mask} &
                           {PRESENT_BYTES{refill_sector_page_fault_r}})
                         << present_after_count_r) |
                        (refill_second_shifted_byte_mask &
                         {PRESENT_BYTES{
                            refill_second_sector_page_fault_r}});
                    present_count_q <= refill_first_total_count +
                                       refill_second_byte_count;
                end
            end
        end
    end

    // Instruction-block storage and address-tagged outstanding requests.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            block_replace_q <= {BLOCK_INDEX_WIDTH{1'b0}};
            for (reset_index = 0; reset_index < BLOCK_DEPTH;
                 reset_index = reset_index + 1) begin
                block_valid_q[reset_index] <= 1'b0;
                block_addr_q[reset_index] <= {`RV64_XLEN{1'b0}};
                block_data_q[reset_index] <= {FETCH_DATA_WIDTH{1'b0}};
                block_access_fault_q[reset_index] <= 1'b0;
                block_page_fault_q[reset_index] <= 1'b0;
            end
            for (reset_index = 0; reset_index < PENDING_DEPTH;
                 reset_index = reset_index + 1) begin
                pending_valid_q[reset_index] <= 1'b0;
                pending_addr_q[reset_index] <= {`RV64_XLEN{1'b0}};
            end
        end else begin
            if (invalidate_i || flush_i) begin
                for (reset_index = 0; reset_index < BLOCK_DEPTH;
                     reset_index = reset_index + 1)
                    block_valid_q[reset_index] <= 1'b0;
            end
            if (restart_i || invalidate_i || flush_i) begin
                for (reset_index = 0; reset_index < PENDING_DEPTH;
                     reset_index = reset_index + 1)
                    pending_valid_q[reset_index] <= 1'b0;
            end else begin
                if (req_fire) begin
                    pending_valid_q[pending_free_index_r] <= 1'b1;
                    pending_addr_q[pending_free_index_r] <= req_addr_o;
                end
                if (resp_valid_i && response_pending_hit_r) begin
                    pending_valid_q[response_pending_index_r] <= 1'b0;
                    block_valid_q[response_block_index_r] <= 1'b1;
                    block_addr_q[response_block_index_r] <= {
                        resp_addr_i[`RV64_XLEN-1:BLOCK_BYTE_BITS],
                        {BLOCK_BYTE_BITS{1'b0}}
                    };
                    block_data_q[response_block_index_r] <= resp_data_i;
                    block_access_fault_q[response_block_index_r] <=
                        resp_access_fault_i;
                    block_page_fault_q[response_block_index_r] <=
                        resp_page_fault_i;
                    if (!response_block_hit_r &&
                        !response_block_free_found_r)
                        block_replace_q <= block_replace_q + 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((FETCH_DATA_WIDTH < 256) ||
            ((FETCH_DATA_WIDTH & (FETCH_DATA_WIDTH - 1)) != 0) ||
            ((FETCH_DATA_WIDTH % 128) != 0))
            $fatal(1,
                "fetch_istream requires power-of-two blocks of at least 256 bits");
        if ((BLOCK_DEPTH < 2) ||
            ((BLOCK_DEPTH & (BLOCK_DEPTH - 1)) != 0))
            $fatal(1, "fetch_istream BLOCK_DEPTH must be a power of two");
        if ((PENDING_DEPTH < 1) ||
            ((PENDING_DEPTH & (PENDING_DEPTH - 1)) != 0))
            $fatal(1, "fetch_istream PENDING_DEPTH must be a power of two");
        if ((FTQ_DEPTH < 2) || ((FTQ_DEPTH & (FTQ_DEPTH - 1)) != 0))
            $fatal(1, "fetch_istream FTQ_DEPTH must be a power of two");
        if (PREDICT_LOOKAHEAD_SECTORS < 1)
            $fatal(1, "fetch_istream predictor lookahead must be positive");
        if ((DECODE_WIDTH < 1) || (ISTREAM_HALFWORDS != DECODE_WIDTH * 2) ||
            (ISTREAM_HALFWORDS > 15))
            $fatal(1, "fetch_istream invalid decode window geometry");
    end

    always @(posedge clk) begin
        if (rst_n && predicted_transfer_fire && (ftq_count_q < 2))
            $fatal(1, "fetch_istream transfer has no successor segment");
        if (rst_n && predicted_boundary_fire &&
            !(predicted_transfer_fire ^ predicted_reject_fire))
            $fatal(1, "fetch_istream prediction validation is ambiguous");
        if (rst_n && predicted_transfer_fire &&
            (ftq_start_pc_q[(ftq_head_q + 1'b1) & (FTQ_DEPTH - 1)] !=
             active_segment_successor_pc))
            $fatal(1, "fetch_istream FTQ successor ordering mismatch");
        if (rst_n && (present_count_q > PRESENT_BYTES))
            $fatal(1, "fetch_istream presentation skid overflow");
        if (rst_n && istream_advance_half_i &&
            (istream_consume_halfwords_i != 0))
            $fatal(1, "fetch_istream ambiguous half and exact advance");
        if (rst_n && (istream_requested_halfwords != 0) &&
            (!istream_valid_o ||
             (istream_requested_halfwords > istream_halfword_count_r)))
            $fatal(1, "fetch_istream decode consumed outside valid prefix");
        if (rst_n && istream_consume_valid && active_segment_end_valid &&
            (istream_consumed_pc > active_segment_control_end_pc))
            $fatal(1, "fetch_istream decode consumed past control boundary");
        if (rst_n && btb_response_match && btb_response_hit_i &&
            !btb_response_control_in_sector)
            $error("fetch_istream BTB returned control outside query sector");
        if (rst_n && btb_response_match && btb_response_hit_i &&
            !btb_response_control_length_valid)
            $error("fetch_istream BTB returned invalid control length");
    end
`endif

endmodule
