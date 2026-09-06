`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/fetch/fetch-defs.v"

// Throughput-oriented instruction-stream frontend.
//
// Unlike fetch_3w, this block does not treat a prediction as a late restart.
// The predictor describes the next control in an open stream segment.  A hit
// closes that segment at the exclusive end PC of the control and appends the
// selected successor as a new segment in the fetch-target queue (FTQ).  When
// both sides of the boundary are resident, one raw window may contain the
// control followed by parcels from its predicted successor.  The splice index
// and the control's existing prediction context let decode reconstruct PCs
// without putting a second PC into every backend lane.
//
// Predictor contract:
//   * lookup_pc_o names the exact start of one dynamic instruction stream.
//   * a hit returns the run through the next control and autonomously looks up
//     the selected successor using the same request ID.
//   * a miss terminates that autonomous chain.
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
    // Per-stream request depth.  Known future runs expose this many blocks
    // immediately; the active stream uses the same bound ahead of its current
    // presentation point.  The bound prevents a malformed or very long run
    // from displacing the entire finite block buffer.
    parameter integer LOOKAHEAD_BLOCKS = 4,
    // Keep the immediate successor's first blocks resident until it becomes
    // active.  The current stream receives an equal protected window, so a
    // head transfer exchanges the two logical stream buffers without copying
    // the wide block data.
    parameter integer SUCCESSOR_PREFILL_BLOCKS = 4,
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
    output wire                         btb_cancel_o,

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
    input  wire [`RV64_XLEN-1:0]        btb_response_stream_pc_i,
    input  wire                         btb_response_hit_i,
    input  wire [`RV64_XLEN-1:0]        btb_response_control_pc_i,
    input  wire [`RV64_XLEN-1:0]        btb_response_control_end_pc_i,
    input  wire [2:0]                   btb_response_control_class_i,
    input  wire [`RV64_XLEN-1:0]        btb_response_successor_pc_i,
    input  wire                         btb_response_taken_i,
    input  wire [PREDICTION_TOKEN_WIDTH-1:0]
                                            btb_response_prediction_token_i,
    output wire                         btb_response_ready_o,

    // Optional late direction refinement.  The token identifies an RLE
    // boundary already admitted to the FTQ.  Only exact-path confirmation is
    // accepted; changed-path and absent-token responses are counted late and
    // remain the decode predictor's responsibility.
    input  wire                         refinement_valid_i,
    input  wire [PREDICTION_TOKEN_WIDTH-1:0]
                                            refinement_prediction_token_i,
    input  wire [`RV64_XLEN-1:0]        refinement_control_pc_i,
    input  wire                         refinement_taken_i,
    input  wire [`RV64_XLEN-1:0]        refinement_successor_pc_i,
    output wire                         refinement_accept_o,
    output wire                         refinement_changed_o,
    output wire                         refinement_late_o,

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
    // PC immediately after the accepted raw prefix.  Unlike stream_pc plus a
    // byte count, this remains correct when the prefix crosses a predicted
    // control boundary into a noncontiguous successor.
    output wire [`RV64_XLEN-1:0]        istream_next_pc_o,
    output wire [`RV64_XLEN-1:0]        istream_segment_start_pc_o,

    // The first splice_halfword parcels belong to stream_pc_o.  Remaining
    // valid parcels begin at istream_prediction_successor_o.  This is frontend
    // alignment metadata only; ordinary backend instructions retain their
    // normal per-instruction PC and do not carry another stream PC.
    output wire                         istream_splice_valid_o,
    output wire [3:0]                   istream_splice_halfword_o,

    // Prediction metadata describes the active segment boundary.  It remains
    // valid while a split control is completed from decode's partial stash.
    output wire                         istream_prediction_valid_o,
    output wire [`RV64_XLEN-1:0]        istream_control_pc_o,
    output wire [`RV64_XLEN-1:0]        istream_control_end_pc_o,
    output wire [`RV64_XLEN-1:0]        istream_prediction_successor_o,
    output wire                         istream_prediction_taken_o,
    // Set only when the optional direction predictor, rather than the RLE
    // entry's fast counter, selected this boundary's direction.
    output wire                         istream_prediction_refined_o,
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
    localparam integer FUTURE_RUN_CANDIDATES =
        (FTQ_DEPTH - 1) * LOOKAHEAD_BLOCKS;
    localparam integer ACTIVE_LOOKAHEAD_BASE =
        1 + FUTURE_RUN_CANDIDATES;
    localparam integer REQUEST_CANDIDATES =
        ACTIVE_LOOKAHEAD_BASE + LOOKAHEAD_BLOCKS;

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

    // Logical double buffering over the shared address-tagged block store.
    // These are replacement qualifications, not duplicated data arrays: four
    // near-term active blocks and four immediate-successor blocks are pinned,
    // while deeper FTQ lookahead competes only for the remaining entries.
    reg block_active_prefill_r [0:BLOCK_DEPTH-1];
    reg block_successor_prefill_r [0:BLOCK_DEPTH-1];
    reg block_prefill_protected_r [0:BLOCK_DEPTH-1];
    reg [31:0] successor_prefill_resident_count_r;
    reg [31:0] successor_prefill_pending_count_r;
    reg response_successor_prefill_match_r;

    reg pending_valid_q [0:PENDING_DEPTH-1];
    reg [`RV64_XLEN-1:0] pending_addr_q [0:PENDING_DEPTH-1];

    // Every valid entry describes one dynamic stream segment.  Exactly the
    // tail entry is open (end_valid=0); all older entries end at a predicted
    // control and name the selected next segment.
    reg ftq_valid_q [0:FTQ_DEPTH-1];
    reg ftq_end_valid_q [0:FTQ_DEPTH-1];
    // Set once the predictor has accepted this stream start.  It remains set
    // after a terminating miss so an open sequential stream is not retried on
    // every cycle.
    reg ftq_lookup_done_q [0:FTQ_DEPTH-1];
    reg [`RV64_XLEN-1:0] ftq_start_pc_q [0:FTQ_DEPTH-1];
    reg [`RV64_XLEN-1:0] ftq_control_pc_q [0:FTQ_DEPTH-1];
    reg [`RV64_XLEN-1:0] ftq_control_end_pc_q [0:FTQ_DEPTH-1];
    reg [2:0] ftq_control_class_q [0:FTQ_DEPTH-1];
    reg [`RV64_XLEN-1:0] ftq_successor_pc_q [0:FTQ_DEPTH-1];
    reg ftq_prediction_taken_q [0:FTQ_DEPTH-1];
    reg ftq_prediction_refined_q [0:FTQ_DEPTH-1];
    reg [PREDICTION_TOKEN_WIDTH-1:0]
        ftq_prediction_token_q [0:FTQ_DEPTH-1];
    reg [GENERATION_WIDTH-1:0] ftq_generation_q [0:FTQ_DEPTH-1];
    reg [FTQ_INDEX_WIDTH-1:0] ftq_head_q;
    reg [FTQ_INDEX_WIDTH-1:0] ftq_tail_q;
    reg [FTQ_COUNT_WIDTH-1:0] ftq_count_q;

    // One predictor request may be outstanding.  The request ID and captured
    // FTQ identity make late responses harmless after a redirect or slot reuse.
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
    assign stream_pc_o = present_pc_q;
    assign istream_segment_start_pc_o = (active_q && (ftq_count_q != 0)) ?
        ftq_start_pc_q[ftq_head_q] : present_pc_q;
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

    // Declared before the target-sector bypass logic; its combinational match
    // is produced with the other response routing below.
    reg response_pending_hit_r;

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
    wire active_segment_prediction_refined =
        ftq_prediction_refined_q[ftq_head_q];
    wire [2:0] active_segment_control_class =
        ftq_control_class_q[ftq_head_q];
    wire active_segment_direct_control =
        (active_segment_control_class ==
         `OPENRV64_STREAM_CONTROL_DIRECT_JUMP) ||
        (active_segment_control_class ==
         `OPENRV64_STREAM_CONTROL_DIRECT_CALL);
    wire [PREDICTION_TOKEN_WIDTH-1:0] active_segment_prediction_token =
        ftq_prediction_token_q[ftq_head_q];

    // Read up to two target sectors for a cross-control presentation.  The
    // current sequential skid is preferred for a fallthrough successor; a
    // taken successor comes from the address-tagged block buffer.  No
    // instruction bits participate in this operation.
    wire [FTQ_INDEX_WIDTH-1:0] active_successor_slot =
        (ftq_head_q + 1'b1) & (FTQ_DEPTH - 1);
    wire active_successor_queued = (ftq_count_q > 1) &&
        ftq_valid_q[active_successor_slot] &&
        (ftq_start_pc_q[active_successor_slot] ==
         active_segment_successor_pc);
    wire [`RV64_XLEN-1:0] active_prefill_base = {
        present_pc_q[`RV64_XLEN-1:BLOCK_BYTE_BITS],
        {BLOCK_BYTE_BITS{1'b0}}
    };
    wire [`RV64_XLEN-1:0] successor_prefill_base = {
        ftq_start_pc_q[active_successor_slot][
            `RV64_XLEN-1:BLOCK_BYTE_BITS],
        {BLOCK_BYTE_BITS{1'b0}}
    };
    integer prefill_block_scan;
    integer prefill_offset_scan;
    integer prefill_pending_scan;
    reg successor_prefill_offset_valid_r;
    reg successor_prefill_offset_resident_r;
    reg successor_prefill_offset_pending_r;
    always @* begin
        successor_prefill_resident_count_r = 32'd0;
        successor_prefill_pending_count_r = 32'd0;
        response_successor_prefill_match_r = 1'b0;
        for (prefill_block_scan = 0;
             prefill_block_scan < BLOCK_DEPTH;
             prefill_block_scan = prefill_block_scan + 1) begin
            block_active_prefill_r[prefill_block_scan] = 1'b0;
            block_successor_prefill_r[prefill_block_scan] = 1'b0;
            for (prefill_offset_scan = 0;
                 prefill_offset_scan < SUCCESSOR_PREFILL_BLOCKS;
                 prefill_offset_scan = prefill_offset_scan + 1) begin
                if (active_q &&
                    (block_addr_q[prefill_block_scan] ==
                     (active_prefill_base +
                      (prefill_offset_scan * BLOCK_BYTES))))
                    block_active_prefill_r[prefill_block_scan] = 1'b1;
                if (active_successor_queued &&
                    (block_addr_q[prefill_block_scan] ==
                     (successor_prefill_base +
                      (prefill_offset_scan * BLOCK_BYTES))))
                    block_successor_prefill_r[prefill_block_scan] = 1'b1;
            end
            block_prefill_protected_r[prefill_block_scan] =
                block_valid_q[prefill_block_scan] &&
                (block_active_prefill_r[prefill_block_scan] ||
                 block_successor_prefill_r[prefill_block_scan]);
        end

        // Diagnostics count only blocks which are actually inside the known
        // successor run.  Its first block is always eligible; later blocks
        // require a closed segment whose control lies beyond their base.
        for (prefill_offset_scan = 0;
             prefill_offset_scan < SUCCESSOR_PREFILL_BLOCKS;
             prefill_offset_scan = prefill_offset_scan + 1) begin
            successor_prefill_offset_valid_r = active_successor_queued &&
                ((prefill_offset_scan == 0) ||
                 (ftq_end_valid_q[active_successor_slot] &&
                  ((successor_prefill_base +
                    (prefill_offset_scan * BLOCK_BYTES)) <
                   ftq_control_end_pc_q[active_successor_slot])));
            successor_prefill_offset_resident_r = 1'b0;
            successor_prefill_offset_pending_r = 1'b0;
            for (prefill_block_scan = 0;
                 prefill_block_scan < BLOCK_DEPTH;
                 prefill_block_scan = prefill_block_scan + 1) begin
                if (block_valid_q[prefill_block_scan] &&
                    (block_addr_q[prefill_block_scan] ==
                     (successor_prefill_base +
                      (prefill_offset_scan * BLOCK_BYTES))))
                    successor_prefill_offset_resident_r = 1'b1;
            end
            for (prefill_pending_scan = 0;
                 prefill_pending_scan < PENDING_DEPTH;
                 prefill_pending_scan = prefill_pending_scan + 1) begin
                if (pending_valid_q[prefill_pending_scan] &&
                    (pending_addr_q[prefill_pending_scan] ==
                     (successor_prefill_base +
                      (prefill_offset_scan * BLOCK_BYTES))))
                    successor_prefill_offset_pending_r = 1'b1;
            end
            if (successor_prefill_offset_valid_r &&
                successor_prefill_offset_resident_r)
                successor_prefill_resident_count_r =
                    successor_prefill_resident_count_r + 1'b1;
            if (successor_prefill_offset_valid_r &&
                successor_prefill_offset_pending_r)
                successor_prefill_pending_count_r =
                    successor_prefill_pending_count_r + 1'b1;
            if (active_successor_queued &&
                ({resp_addr_i[`RV64_XLEN-1:BLOCK_BYTE_BITS],
                  {BLOCK_BYTE_BITS{1'b0}}} ==
                 (successor_prefill_base +
                  (prefill_offset_scan * BLOCK_BYTES))))
                response_successor_prefill_match_r = 1'b1;
        end
    end
    wire [`RV64_XLEN-1:0] splice_first_sector_addr = {
        active_segment_successor_pc[`RV64_XLEN-1:SECTOR_BYTE_BITS],
        {SECTOR_BYTE_BITS{1'b0}}
    };
    wire [`RV64_XLEN-1:0] splice_second_sector_addr =
        splice_first_sector_addr + SECTOR_BYTES;
    reg splice_first_sector_valid_r;
    reg [127:0] splice_first_sector_data_r;
    reg splice_first_sector_access_fault_r;
    reg splice_first_sector_page_fault_r;
    reg splice_second_sector_valid_r;
    reg [127:0] splice_second_sector_data_r;
    reg splice_second_sector_access_fault_r;
    reg splice_second_sector_page_fault_r;
    integer splice_block_scan;
    integer splice_first_sector_select;
    integer splice_second_sector_select;
    always @* begin
        splice_first_sector_valid_r = 1'b0;
        splice_first_sector_data_r = 128'd0;
        splice_first_sector_access_fault_r = 1'b0;
        splice_first_sector_page_fault_r = 1'b0;
        splice_second_sector_valid_r = 1'b0;
        splice_second_sector_data_r = 128'd0;
        splice_second_sector_access_fault_r = 1'b0;
        splice_second_sector_page_fault_r = 1'b0;
        splice_first_sector_select = splice_first_sector_addr[
            SECTOR_BYTE_BITS +: $clog2(SECTORS_PER_BLOCK)];
        splice_second_sector_select = splice_second_sector_addr[
            SECTOR_BYTE_BITS +: $clog2(SECTORS_PER_BLOCK)];
        for (splice_block_scan = 0; splice_block_scan < BLOCK_DEPTH;
             splice_block_scan = splice_block_scan + 1) begin
            if (!splice_first_sector_valid_r &&
                block_valid_q[splice_block_scan] &&
                (block_addr_q[splice_block_scan][
                    `RV64_XLEN-1:BLOCK_BYTE_BITS] ==
                 splice_first_sector_addr[
                    `RV64_XLEN-1:BLOCK_BYTE_BITS])) begin
                splice_first_sector_valid_r = 1'b1;
                splice_first_sector_data_r = block_data_q[splice_block_scan][
                    splice_first_sector_select*128 +: 128];
                splice_first_sector_access_fault_r =
                    block_access_fault_q[splice_block_scan];
                splice_first_sector_page_fault_r =
                    block_page_fault_q[splice_block_scan];
            end
            if (!splice_second_sector_valid_r &&
                block_valid_q[splice_block_scan] &&
                (block_addr_q[splice_block_scan][
                    `RV64_XLEN-1:BLOCK_BYTE_BITS] ==
                 splice_second_sector_addr[
                    `RV64_XLEN-1:BLOCK_BYTE_BITS])) begin
                splice_second_sector_valid_r = 1'b1;
                splice_second_sector_data_r = block_data_q[splice_block_scan][
                    splice_second_sector_select*128 +: 128];
                splice_second_sector_access_fault_r =
                    block_access_fault_q[splice_block_scan];
                splice_second_sector_page_fault_r =
                    block_page_fault_q[splice_block_scan];
            end
        end
        // Same-edge response bypass matches the ordinary presentation refill.
        if (resp_valid_i && response_pending_hit_r &&
            (resp_addr_i[`RV64_XLEN-1:BLOCK_BYTE_BITS] ==
             splice_first_sector_addr[`RV64_XLEN-1:BLOCK_BYTE_BITS])) begin
            splice_first_sector_valid_r = 1'b1;
            splice_first_sector_data_r = resp_data_i[
                splice_first_sector_select*128 +: 128];
            splice_first_sector_access_fault_r = resp_access_fault_i;
            splice_first_sector_page_fault_r = resp_page_fault_i;
        end
        if (resp_valid_i && response_pending_hit_r &&
            (resp_addr_i[`RV64_XLEN-1:BLOCK_BYTE_BITS] ==
             splice_second_sector_addr[`RV64_XLEN-1:BLOCK_BYTE_BITS])) begin
            splice_second_sector_valid_r = 1'b1;
            splice_second_sector_data_r = resp_data_i[
                splice_second_sector_select*128 +: 128];
            splice_second_sector_access_fault_r = resp_access_fault_i;
            splice_second_sector_page_fault_r = resp_page_fault_i;
        end
    end

    wire splice_successor_in_present =
        (active_segment_successor_pc >= present_pc_q) &&
        (active_segment_successor_pc < (present_pc_q + present_count_q));
    wire [PRESENT_COUNT_WIDTH-1:0] splice_present_byte_offset =
        active_segment_successor_pc - present_pc_q;
    wire [4:0] splice_sector_byte_offset =
        active_segment_successor_pc[SECTOR_BYTE_BITS-1:0];
    wire [4:0] splice_first_sector_bytes =
        SECTOR_BYTES - splice_sector_byte_offset;
    reg [ISTREAM_HALFWORDS*16-1:0] splice_successor_data_r;
    reg [ISTREAM_HALFWORDS-1:0] splice_successor_access_fault_r;
    reg [ISTREAM_HALFWORDS-1:0] splice_successor_page_fault_r;
    reg [3:0] splice_successor_halfwords_r;
    integer splice_halfword_index;
    integer splice_successor_byte_index;
    always @* begin
        splice_successor_data_r = {ISTREAM_HALFWORDS*16{1'b0}};
        splice_successor_access_fault_r = {ISTREAM_HALFWORDS{1'b0}};
        splice_successor_page_fault_r = {ISTREAM_HALFWORDS{1'b0}};
        splice_successor_halfwords_r = 4'd0;
        splice_successor_byte_index = 0;
        if (splice_successor_in_present) begin
            splice_successor_data_r = present_data_q >>
                (splice_present_byte_offset * 8);
            for (splice_halfword_index = 0;
                 splice_halfword_index < ISTREAM_HALFWORDS;
                 splice_halfword_index = splice_halfword_index + 1) begin
                splice_successor_byte_index = splice_present_byte_offset +
                                              (splice_halfword_index * 2);
                if ((splice_successor_byte_index + 1) < present_count_q) begin
                    splice_successor_halfwords_r =
                        splice_halfword_index + 1;
                    splice_successor_access_fault_r[splice_halfword_index] =
                        present_access_fault_q[splice_successor_byte_index] |
                        present_access_fault_q[splice_successor_byte_index + 1];
                    splice_successor_page_fault_r[splice_halfword_index] =
                        present_page_fault_q[splice_successor_byte_index] |
                        present_page_fault_q[splice_successor_byte_index + 1];
                end
            end
        end else if (splice_first_sector_valid_r) begin
            splice_successor_data_r = splice_first_sector_data_r >>
                (splice_sector_byte_offset * 8);
            if (splice_second_sector_valid_r)
                splice_successor_data_r = splice_successor_data_r |
                    (splice_second_sector_data_r <<
                     (splice_first_sector_bytes * 8));
            for (splice_halfword_index = 0;
                 splice_halfword_index < ISTREAM_HALFWORDS;
                 splice_halfword_index = splice_halfword_index + 1) begin
                splice_successor_byte_index = splice_halfword_index * 2;
                if (((splice_successor_byte_index + 1) <
                     splice_first_sector_bytes) ||
                    (splice_second_sector_valid_r &&
                     ((splice_successor_byte_index + 1) <
                      (splice_first_sector_bytes + SECTOR_BYTES)))) begin
                    splice_successor_halfwords_r =
                        splice_halfword_index + 1;
                    if (splice_successor_byte_index <
                        splice_first_sector_bytes) begin
                        splice_successor_access_fault_r[splice_halfword_index] =
                            splice_first_sector_access_fault_r;
                        splice_successor_page_fault_r[splice_halfword_index] =
                            splice_first_sector_page_fault_r;
                    end else begin
                        splice_successor_access_fault_r[splice_halfword_index] =
                            splice_second_sector_access_fault_r;
                        splice_successor_page_fault_r[splice_halfword_index] =
                            splice_second_sector_page_fault_r;
                    end
                end
            end
        end
    end

    wire [`RV64_XLEN-1:0] active_boundary_bytes =
        active_segment_control_end_pc - present_pc_q;
    wire [3:0] active_boundary_halfwords = active_boundary_bytes[4:1];
    wire istream_splice_available = active_segment_end_valid &&
        (active_segment_prediction_refined ||
         active_segment_direct_control) &&
        active_successor_queued &&
        (active_segment_control_end_pc > present_pc_q) &&
        !active_boundary_bytes[0] &&
        (active_boundary_bytes < (ISTREAM_HALFWORDS * 2)) &&
        (present_count_q >= active_boundary_bytes) &&
        (splice_successor_halfwords_r != 0) && active_q &&
        !restart_i && !redirect_i && !invalidate_i && !flush_i;

    // Qualify a composite raw-halfword prefix.  Bytes before the exclusive
    // control end come from the current stream; bytes after it come from the
    // selected successor.  Decode validates and admission-gates the splice.
    reg [ISTREAM_HALFWORDS*16-1:0] istream_data_r;
    reg [ISTREAM_HALFWORDS-1:0] istream_halfword_valid_r;
    reg [ISTREAM_HALFWORDS-1:0] istream_access_fault_r;
    reg [ISTREAM_HALFWORDS-1:0] istream_page_fault_r;
    reg [3:0] istream_halfword_count_r;
    integer halfword_index;
    always @* begin
        istream_data_r = present_data_q[ISTREAM_HALFWORDS*16-1:0];
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
            end else if (istream_splice_available &&
                         (halfword_index >= active_boundary_halfwords) &&
                         ((halfword_index - active_boundary_halfwords) <
                          splice_successor_halfwords_r)) begin
                istream_data_r[halfword_index*16 +: 16] =
                    splice_successor_data_r[
                        (halfword_index-active_boundary_halfwords)*16 +: 16];
                istream_halfword_valid_r[halfword_index] = 1'b1;
                istream_access_fault_r[halfword_index] =
                    splice_successor_access_fault_r[
                        halfword_index-active_boundary_halfwords];
                istream_page_fault_r[halfword_index] =
                    splice_successor_page_fault_r[
                        halfword_index-active_boundary_halfwords];
                istream_halfword_count_r = halfword_index + 1;
            end
        end
    end

    assign istream_valid_o = istream_halfword_valid_r[0];
    assign istream_data_o = istream_data_r;
    assign istream_halfword_valid_o = istream_halfword_valid_r;
    assign istream_access_fault_o = istream_access_fault_r;
    assign istream_page_fault_o = istream_page_fault_r;
    assign istream_prediction_valid_o = active_segment_end_valid;
    assign istream_control_pc_o = active_segment_control_pc;
    assign istream_control_end_pc_o = active_segment_control_end_pc;
    assign istream_prediction_successor_o = active_segment_successor_pc;
    assign istream_prediction_taken_o = active_segment_prediction_taken;
    assign istream_prediction_refined_o =
        active_segment_prediction_refined;
    assign istream_prediction_token_o = active_segment_prediction_token;
    assign istream_splice_valid_o = istream_splice_available;
    assign istream_splice_halfword_o = istream_splice_available ?
        active_boundary_halfwords : 4'd0;

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
        (istream_splice_available ?
            ((present_pc_q < active_segment_control_end_pc) &&
             (istream_requested_halfwords >= active_boundary_halfwords)) :
            (istream_consumed_pc == active_segment_control_end_pc));
    wire predicted_transfer_fire = predicted_boundary_fire &&
        istream_prediction_accept_i;
    wire predicted_reject_fire = predicted_boundary_fire &&
        !istream_prediction_accept_i;
    wire [3:0] istream_successor_consumed_halfwords =
        (predicted_transfer_fire && istream_splice_available) ?
            (istream_requested_halfwords - active_boundary_halfwords) : 4'd0;
    wire [`RV64_XLEN-1:0] istream_transfer_next_pc =
        active_segment_successor_pc +
        ({60'd0, istream_successor_consumed_halfwords} << 1);
    assign istream_next_pc_o = predicted_transfer_fire ?
        istream_transfer_next_pc : istream_consumed_pc;

    assign predicted_transfer_valid_o = predicted_transfer_fire;
    assign predicted_reject_valid_o = predicted_reject_fire;
    assign predicted_transfer_source_pc_o = active_segment_control_pc;
    assign predicted_transfer_target_pc_o = active_segment_successor_pc;
    assign predicted_transfer_token_o = active_segment_prediction_token;

    reg refinement_match_r;
    reg [FTQ_INDEX_WIDTH-1:0] refinement_match_slot_r;
    reg [FTQ_COUNT_WIDTH-1:0] refinement_match_offset_r;
    integer refinement_scan;
    integer refinement_scan_slot;
    always @* begin
        refinement_match_r = 1'b0;
        refinement_match_slot_r = {FTQ_INDEX_WIDTH{1'b0}};
        refinement_match_offset_r = {FTQ_COUNT_WIDTH{1'b0}};
        for (refinement_scan = 0; refinement_scan < FTQ_DEPTH;
             refinement_scan = refinement_scan + 1) begin
            refinement_scan_slot = (ftq_head_q + refinement_scan) &
                                   (FTQ_DEPTH - 1);
            if (!refinement_match_r && (refinement_scan < ftq_count_q) &&
                ftq_valid_q[refinement_scan_slot] &&
                ftq_end_valid_q[refinement_scan_slot] &&
                (ftq_prediction_token_q[refinement_scan_slot] ==
                 refinement_prediction_token_i) &&
                (ftq_control_pc_q[refinement_scan_slot] ==
                 refinement_control_pc_i)) begin
                refinement_match_r = 1'b1;
                refinement_match_slot_r = refinement_scan_slot;
                refinement_match_offset_r = refinement_scan;
            end
        end
    end

    // Refinement may annotate a future segment only when it confirms the exact
    // path already selected by the RLE predictor.  Being behind the active FTQ
    // head is not sufficient proof that no bytes from that segment's old
    // successor have crossed into decode: autonomous chaining and block-buffer
    // lookahead can run ahead of FTQ presentation.  A changed-path response
    // therefore remains a normal decode-side redirect until the frontend has
    // an explicit emitted/decoded generation watermark.
    assign refinement_accept_o = refinement_valid_i &&
        refinement_match_r && (refinement_match_offset_r != 0) &&
        (ftq_prediction_taken_q[refinement_match_slot_r] ==
         refinement_taken_i) &&
        (ftq_successor_pc_q[refinement_match_slot_r] ==
         refinement_successor_pc_i) &&
        !restart_i && !redirect_i && !invalidate_i && !flush_i;
    // Kept as an interface diagnostic.  Unsafe path-changing refinement is
    // deliberately not accepted, so this cannot assert in this implementation.
    assign refinement_changed_o = 1'b0;
    assign refinement_late_o = refinement_valid_i &&
                               !refinement_accept_o;

    // One external lookup starts a chain.  The RLE predictor then returns one
    // response per predicted control and performs successor lookups itself.
    // Every response in the chain retains the root request ID and names the
    // exact stream start that it describes.
    wire btb_tail_open = active_q && (ftq_count_q != 0) &&
        ftq_valid_q[ftq_tail_q] && !ftq_end_valid_q[ftq_tail_q] &&
        !ftq_lookup_done_q[ftq_tail_q];
    wire btb_response_match = btb_response_valid_i && btb_outstanding_q &&
        (btb_response_request_id_i == btb_outstanding_request_id_q);
    wire btb_response_slot_live =
        ftq_valid_q[ftq_tail_q] && !ftq_end_valid_q[ftq_tail_q] &&
        (ftq_generation_q[ftq_tail_q] ==
         btb_outstanding_generation_q) &&
        (generation_q == btb_outstanding_generation_q);
    wire btb_response_stream_match =
        btb_response_stream_pc_i == ftq_start_pc_q[ftq_tail_q];
    wire btb_response_not_behind =
        (btb_response_control_pc_i >=
         ftq_start_pc_q[ftq_tail_q]) &&
        ((ftq_tail_q != ftq_head_q) ||
         // Decode and the synchronous BTB response can advance on the same
         // edge.  Compare against post-consumption progress so a late hit
         // cannot install a boundary for a control already consumed.
         (btb_response_control_pc_i >= istream_consumed_pc));
    wire [`RV64_XLEN-1:0] btb_response_control_bytes =
        btb_response_control_end_pc_i - btb_response_control_pc_i;
    wire btb_response_control_length_valid =
        (btb_response_control_bytes == 2) ||
        (btb_response_control_bytes == 4);
    wire btb_response_room = (ftq_count_q < FTQ_DEPTH) ||
        predicted_transfer_fire;
    // Mismatched, stale, malformed, and miss responses must always drain so a
    // canceled chain cannot deadlock behind a full FTQ.  Only a valid hit that
    // needs another FTQ entry is backpressured.
    wire btb_response_candidate_hit = btb_response_match &&
        btb_response_hit_i && btb_response_slot_live &&
        btb_response_stream_match && btb_response_not_behind &&
        !btb_response_control_pc_i[0] &&
        !btb_response_control_end_pc_i[0] &&
        btb_response_control_length_valid &&
        !btb_response_successor_pc_i[0];
    assign btb_response_ready_o = !btb_response_candidate_hit ||
        btb_response_room;
    wire btb_response_fire = btb_response_valid_i &&
        btb_response_ready_o;
    wire btb_append_segment = btb_response_match &&
        btb_response_fire && btb_response_candidate_hit &&
        btb_response_room;
    // At full occupancy, a simultaneous head transfer makes exactly one
    // physical slot available and the tail append reuses that old head slot.
    // Do not let the ordinary pop-side valid clear erase the new entry.
    wire btb_append_reuses_head = btb_append_segment &&
        predicted_transfer_fire && (ftq_count_q == FTQ_DEPTH);
    wire btb_response_abort = btb_response_fire &&
        (!btb_response_match ||
         (btb_response_match && btb_response_hit_i &&
          !btb_response_candidate_hit));
    assign btb_cancel_o = restart_i || redirect_i || invalidate_i || flush_i ||
        predicted_reject_fire || btb_response_abort;
    wire btb_idle_lookup = btb_tail_open && !btb_outstanding_q &&
        (ftq_count_q < FTQ_DEPTH);
    assign btb_lookup_valid_o = btb_idle_lookup &&
        !restart_i && !redirect_i && !flush_i && !stall_i;
    assign btb_lookup_pc_o = ftq_start_pc_q[ftq_tail_q];
    assign btb_lookup_request_id_o = btb_next_request_id_q;
    wire btb_lookup_fire = btb_lookup_valid_o && btb_lookup_ready_i;
    wire [`RV64_XLEN-1:0] stream_rebuild_pc = restart_i ?
        restart_pc_i : redirect_pc_i;

    // Build ordered request candidates: current demand first, then the start
    // of each predicted future segment, then sequential active-stream depth.
    reg request_candidate_valid_r [0:REQUEST_CANDIDATES-1];
    reg request_candidate_stash_r [0:REQUEST_CANDIDATES-1];
    reg [`RV64_XLEN-1:0]
        request_candidate_addr_r [0:REQUEST_CANDIDATES-1];
    integer candidate_index;
    integer candidate_slot;
    integer future_index;
    integer future_block_index;
    integer future_candidate_index;
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

        // Once an RLE result closes a future segment, expose the run's block
        // addresses immediately rather than waiting for that segment to
        // become active.  The open tail has no known end, so only its first
        // block is eligible until its predictor result arrives.
        for (future_index = 1; future_index < FTQ_DEPTH;
             future_index = future_index + 1) begin
            candidate_slot = (ftq_head_q + future_index) &
                             (FTQ_DEPTH - 1);
            for (future_block_index = 0;
                 future_block_index < LOOKAHEAD_BLOCKS;
                 future_block_index = future_block_index + 1) begin
                future_candidate_index = 1 +
                    ((future_index - 1) * LOOKAHEAD_BLOCKS) +
                    future_block_index;
                request_candidate_addr_r[future_candidate_index] = {
                    ftq_start_pc_q[candidate_slot][
                        `RV64_XLEN-1:BLOCK_BYTE_BITS],
                    {BLOCK_BYTE_BITS{1'b0}}
                } + (future_block_index * BLOCK_BYTES);
                request_candidate_valid_r[future_candidate_index] =
                    (future_index < ftq_count_q) &&
                    ftq_valid_q[candidate_slot] &&
                    ((future_block_index == 0) ||
                     (ftq_end_valid_q[candidate_slot] &&
                      (request_candidate_addr_r[future_candidate_index] <
                       ftq_control_end_pc_q[candidate_slot])));
                request_candidate_stash_r[future_candidate_index] = 1'b1;
            end
        end

        for (lookahead_index = 0;
             lookahead_index < LOOKAHEAD_BLOCKS;
             lookahead_index = lookahead_index + 1) begin
            request_candidate_addr_r[
                ACTIVE_LOOKAHEAD_BASE + lookahead_index] =
                {present_pc_q[`RV64_XLEN-1:BLOCK_BYTE_BITS],
                 {BLOCK_BYTE_BITS{1'b0}}} +
                ((lookahead_index + 1) * BLOCK_BYTES);
            request_candidate_valid_r[
                ACTIVE_LOOKAHEAD_BASE + lookahead_index] =
                active_q &&
                (!active_segment_end_valid ||
                 (request_candidate_addr_r[
                    ACTIVE_LOOKAHEAD_BASE + lookahead_index] <=
                  {active_segment_last_byte_pc[
                    `RV64_XLEN-1:BLOCK_BYTE_BITS],
                   {BLOCK_BYTE_BITS{1'b0}}}));
            request_candidate_stash_r[
                ACTIVE_LOOKAHEAD_BASE + lookahead_index] = 1'b0;
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
    reg [PENDING_INDEX_WIDTH-1:0] response_pending_index_r;
    reg response_block_hit_r;
    reg [BLOCK_INDEX_WIDTH-1:0] response_block_index_r;
    reg response_block_free_found_r;
    reg response_block_replacement_found_r;
    reg response_block_destination_valid_r;
    integer response_pending_scan;
    integer response_block_scan;
    integer response_replace_index;
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
        response_block_replacement_found_r = 1'b0;
        response_block_destination_valid_r = 1'b0;
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
        for (response_block_scan = 0;
             response_block_scan < BLOCK_DEPTH;
             response_block_scan = response_block_scan + 1) begin
            response_replace_index =
                (block_replace_q + response_block_scan) & (BLOCK_DEPTH - 1);
            if (!response_block_hit_r && !response_block_free_found_r &&
                !response_block_replacement_found_r &&
                !block_prefill_protected_r[response_replace_index]) begin
                response_block_replacement_found_r = 1'b1;
                response_block_index_r = response_replace_index;
            end
        end
        response_block_destination_valid_r = response_block_hit_r ||
            response_block_free_found_r ||
            response_block_replacement_found_r;
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
                                               istream_transfer_next_pc;
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
    reg refill_successor_prefill_hit_r;
    reg refill_response_bypass_hit_r;
    reg [127:0] refill_sector_data_r;
    reg refill_sector_access_fault_r;
    reg refill_sector_page_fault_r;
    integer refill_block_scan;
    integer refill_sector_select;
    always @* begin
        refill_sector_valid_r = 1'b0;
        refill_successor_prefill_hit_r = 1'b0;
        refill_response_bypass_hit_r = 1'b0;
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
                refill_successor_prefill_hit_r =
                    block_successor_prefill_r[refill_block_scan];
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
            refill_successor_prefill_hit_r =
                response_successor_prefill_match_r;
            refill_response_bypass_hit_r = 1'b1;
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
                ftq_lookup_done_q[reset_index] <= 1'b0;
                ftq_start_pc_q[reset_index] <= {`RV64_XLEN{1'b0}};
                ftq_control_pc_q[reset_index] <= {`RV64_XLEN{1'b0}};
                ftq_control_end_pc_q[reset_index] <=
                    {`RV64_XLEN{1'b0}};
                ftq_control_class_q[reset_index] <=
                    `OPENRV64_STREAM_CONTROL_CONDITIONAL;
                ftq_successor_pc_q[reset_index] <= {`RV64_XLEN{1'b0}};
                ftq_prediction_taken_q[reset_index] <= 1'b0;
                ftq_prediction_refined_q[reset_index] <= 1'b0;
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
            ftq_lookup_done_q[0] <= 1'b0;
            ftq_start_pc_q[0] <= stream_rebuild_pc;
            ftq_generation_q[0] <= generation_q + 1'b1;
            btb_outstanding_q <= 1'b0;
            for (reset_index = 1; reset_index < FTQ_DEPTH;
                 reset_index = reset_index + 1) begin
                ftq_valid_q[reset_index] <= 1'b0;
                ftq_end_valid_q[reset_index] <= 1'b0;
                ftq_lookup_done_q[reset_index] <= 1'b0;
            end
        end else if (flush_i) begin
            active_q <= 1'b0;
            ftq_count_q <= {FTQ_COUNT_WIDTH{1'b0}};
            btb_outstanding_q <= 1'b0;
            for (reset_index = 0; reset_index < FTQ_DEPTH;
                 reset_index = reset_index + 1) begin
                ftq_valid_q[reset_index] <= 1'b0;
                ftq_end_valid_q[reset_index] <= 1'b0;
                ftq_lookup_done_q[reset_index] <= 1'b0;
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
            ftq_lookup_done_q[0] <= 1'b0;
            ftq_start_pc_q[0] <= active_segment_control_end_pc;
            ftq_generation_q[0] <= generation_q + 1'b1;
            btb_outstanding_q <= 1'b0;
            for (reset_index = 1; reset_index < FTQ_DEPTH;
                 reset_index = reset_index + 1) begin
                ftq_valid_q[reset_index] <= 1'b0;
                ftq_end_valid_q[reset_index] <= 1'b0;
                ftq_lookup_done_q[reset_index] <= 1'b0;
            end
        end else begin
            if (refinement_accept_o)
                ftq_prediction_taken_q[refinement_match_slot_r] <=
                    refinement_taken_i;
            if (refinement_accept_o)
                ftq_prediction_refined_q[refinement_match_slot_r] <= 1'b1;
            if (btb_response_fire) begin
                if (btb_append_segment) begin
                    ftq_end_valid_q[ftq_tail_q] <= 1'b1;
                    ftq_lookup_done_q[ftq_tail_q] <= 1'b1;
                    ftq_control_pc_q[ftq_tail_q] <=
                        btb_response_control_pc_i;
                    ftq_control_end_pc_q[ftq_tail_q] <=
                        btb_response_control_end_pc_i;
                    ftq_control_class_q[ftq_tail_q] <=
                        btb_response_control_class_i;
                    ftq_successor_pc_q[ftq_tail_q] <=
                        btb_response_successor_pc_i;
                    ftq_prediction_taken_q[ftq_tail_q] <=
                        btb_response_taken_i;
                    ftq_prediction_refined_q[ftq_tail_q] <= 1'b0;
                    ftq_prediction_token_q[ftq_tail_q] <=
                        btb_response_prediction_token_i;
                    ftq_valid_q[(ftq_tail_q + 1'b1) &
                                (FTQ_DEPTH - 1)] <= 1'b1;
                    ftq_end_valid_q[(ftq_tail_q + 1'b1) &
                                    (FTQ_DEPTH - 1)] <= 1'b0;
                    // The predictor has already issued the successor lookup
                    // internally as part of this root chain.
                    ftq_lookup_done_q[(ftq_tail_q + 1'b1) &
                                      (FTQ_DEPTH - 1)] <= 1'b1;
                    ftq_start_pc_q[(ftq_tail_q + 1'b1) &
                                   (FTQ_DEPTH - 1)] <=
                        btb_response_successor_pc_i;
                    ftq_generation_q[(ftq_tail_q + 1'b1) &
                                     (FTQ_DEPTH - 1)] <= generation_q;
                    ftq_tail_q <= (ftq_tail_q + 1'b1) & (FTQ_DEPTH - 1);
                end
                // A miss ends a valid chain.  A malformed/stale response also
                // ends it, but permits a fresh root lookup for the live tail.
                if (btb_response_match && !btb_response_hit_i)
                    btb_outstanding_q <= 1'b0;
                if (btb_response_abort) begin
                    btb_outstanding_q <= 1'b0;
                    ftq_lookup_done_q[ftq_tail_q] <= 1'b0;
                end
            end
            if (btb_lookup_fire) begin
                btb_outstanding_q <= 1'b1;
                btb_outstanding_request_id_q <= btb_next_request_id_q;
                btb_outstanding_pc_q <= btb_lookup_pc_o;
                btb_outstanding_slot_q <= ftq_tail_q;
                btb_outstanding_generation_q <= generation_q;
                btb_next_request_id_q <= btb_next_request_id_q + 1'b1;
                ftq_lookup_done_q[ftq_tail_q] <= 1'b1;
            end

            if (predicted_transfer_fire) begin
                if (!btb_append_reuses_head) begin
                    ftq_valid_q[ftq_head_q] <= 1'b0;
                    ftq_lookup_done_q[ftq_head_q] <= 1'b0;
                end
                ftq_head_q <= (ftq_head_q + 1'b1) & (FTQ_DEPTH - 1);
            end

            case ({btb_append_segment, predicted_transfer_fire})
                2'b10: ftq_count_q <= ftq_count_q + 1'b1;
                2'b01: ftq_count_q <= ftq_count_q - 1'b1;
                default: begin
                end
            endcase

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
                    if (response_block_destination_valid_r) begin
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
                        if (response_block_replacement_found_r)
                            block_replace_q <= response_block_index_r + 1'b1;
                    end
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
        if ((SUCCESSOR_PREFILL_BLOCKS < 1) ||
            (SUCCESSOR_PREFILL_BLOCKS > LOOKAHEAD_BLOCKS) ||
            (BLOCK_DEPTH < (2 * SUCCESSOR_PREFILL_BLOCKS)))
            $fatal(1,
                "fetch_istream prefill requires two protected lookahead windows");
        if ((DECODE_WIDTH < 1) || (ISTREAM_HALFWORDS != DECODE_WIDTH * 2) ||
            (ISTREAM_HALFWORDS > 15))
            $fatal(1, "fetch_istream invalid decode window geometry");
    end

    always @(posedge clk) begin
        if (rst_n && predicted_transfer_fire && (ftq_count_q < 2))
            $fatal(1, "fetch_istream transfer has no successor segment");
        if (rst_n && resp_valid_i && response_pending_hit_r &&
            !response_block_destination_valid_r)
            $fatal(1, "fetch_istream protected prefill exhausted block store");
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
            !istream_splice_available &&
            (istream_consumed_pc > active_segment_control_end_pc))
            $fatal(1, "fetch_istream decode consumed past control boundary");
        if (rst_n && istream_splice_available &&
            ((active_boundary_halfwords == 0) ||
             (active_boundary_halfwords >= ISTREAM_HALFWORDS)))
            $fatal(1, "fetch_istream invalid cross-control splice index");
        if (rst_n && predicted_reject_fire &&
            (istream_requested_halfwords > active_boundary_halfwords))
            $fatal(1, "fetch_istream consumed unvalidated successor parcels");
        if (rst_n && btb_response_match && btb_response_hit_i &&
            !btb_response_stream_match)
            $error("fetch_istream RLE response stream key mismatch");
        if (rst_n && btb_response_match && btb_response_hit_i &&
            !btb_response_control_length_valid)
            $error("fetch_istream BTB returned invalid control length");
    end
`endif

endmodule
