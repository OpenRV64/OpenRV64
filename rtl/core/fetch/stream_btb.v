`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/fetch/fetch-defs.v"

// Stream-start-indexed run-length frontend predictor.
//
// A lookup names the first instruction of a dynamic instruction stream.  A
// hit returns the sequential run from that PC through its next control, the
// control class and target, and a local two-bit direction prediction.  The
// selected successor is immediately looked up as the next stream key.
// Predictions accumulate in a small elastic queue, so synchronous BRAM reads
// may continue through a burst of short streams while FTQ admission pauses.
// A miss terminates the autonomous chain and is returned to fetch explicitly.
//
// TODO(istream): this queue is deliberately provisional.  The FTQ already
// buffers admitted runs.  Retain this second queue only if occupancy and
// full-stall counters show that autonomous RLE chaining usefully runs ahead of
// FTQ admission; otherwise remove it and keep the single-result bypass.
//
// The payload arrays are reset-free synchronous memories so FPGA tools can
// infer block RAM.  Resettable validity, replacement, and queue state are
// sidecars.  Training is keyed by the stream start captured when the dynamic
// control was admitted; train_pc_i remains the resolved control PC.
module openrv64_fetch_stream_btb #(
    parameter integer ENTRIES = 256,
    parameter integer REQUEST_ID_WIDTH = 32,
    parameter integer RUN_HALFWORD_WIDTH = 16,
    parameter integer RESPONSE_QUEUE_DEPTH = 4,
    parameter integer SETS = ENTRIES / 2,
    parameter integer SET_INDEX_WIDTH = $clog2(SETS),
    parameter integer RESPONSE_QUEUE_INDEX_WIDTH =
        $clog2(RESPONSE_QUEUE_DEPTH),
    parameter integer RESPONSE_QUEUE_COUNT_WIDTH =
        $clog2(RESPONSE_QUEUE_DEPTH + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         cancel_i,

    input  wire                         lookup_valid_i,
    output wire                         lookup_ready_o,
    input  wire [`RV64_XLEN-1:0]        lookup_pc_i,
    input  wire [REQUEST_ID_WIDTH-1:0]  lookup_request_id_i,

    output wire                         response_valid_o,
    input  wire                         response_ready_i,
    output wire [REQUEST_ID_WIDTH-1:0]  response_request_id_o,
    output wire [`RV64_XLEN-1:0]        response_stream_pc_o,
    output wire                         response_hit_o,
    output wire [`RV64_XLEN-1:0]        response_control_pc_o,
    output wire [`RV64_XLEN-1:0]        response_control_end_pc_o,
    output wire [2:0]                   response_control_class_o,
    output wire                         response_conditional_o,
    output wire [`RV64_XLEN-1:0]        response_target_pc_o,
    output wire [`RV64_XLEN-1:0]        response_successor_pc_o,
    output wire                         response_taken_o,
    output wire [REQUEST_ID_WIDTH-1:0]  response_prediction_token_o,

    input  wire                         train_valid_i,
    input  wire [`RV64_XLEN-1:0]        train_stream_pc_i,
    input  wire                         train_conditional_i,
    input  wire                         train_taken_i,
    input  wire                         train_length_32_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] train_instr_i,
    input  wire [`RV64_XLEN-1:0]        train_pc_i,
    input  wire [`RV64_XLEN-1:0]        train_next_pc_i,

    output wire                         diag_lookup_fire_o,
    output wire                         diag_root_lookup_o,
    output wire                         diag_chain_lookup_o,
    output wire                         diag_response_fire_o,
    output wire                         diag_response_hit_o,
    output wire                         diag_response_way1_o,
    output wire                         diag_queue_enqueue_o,
    output wire                         diag_queue_dequeue_o,
    output wire                         diag_queue_full_stall_o,
    output wire [RESPONSE_QUEUE_COUNT_WIDTH-1:0]
                                            diag_queue_count_o,
    output wire                         diag_train_fire_o,
    output wire                         diag_train_update_o,
    output wire                         diag_train_insert_o,
    output wire                         diag_train_replacement_o,
    output wire                         diag_train_shorter_o,
    output wire                         diag_train_later_ignored_o,
    output wire                         diag_train_run_overflow_o,
    output wire                         diag_train_conditional_o,
    output wire                         diag_train_taken_o
);
    localparam integer KEY_SHIFT = 1;
    localparam integer KEY_TAG_WIDTH = `RV64_XLEN - KEY_SHIFT -
        SET_INDEX_WIDTH;
    localparam integer TARGET_WIDTH = `RV64_XLEN - 1;
    localparam integer DIRECTION_WIDTH = 2;
    localparam integer PAYLOAD_WIDTH = KEY_TAG_WIDTH +
        RUN_HALFWORD_WIDTH + 3 + 1 + TARGET_WIDTH + DIRECTION_WIDTH;

    localparam integer DIRECTION_LSB = 0;
    localparam integer TARGET_LSB = DIRECTION_LSB + DIRECTION_WIDTH;
    localparam integer LENGTH_32_BIT = TARGET_LSB + TARGET_WIDTH;
    localparam integer CONTROL_CLASS_LSB = LENGTH_32_BIT + 1;
    localparam integer RUN_LSB = CONTROL_CLASS_LSB + 3;
    localparam integer KEY_TAG_LSB = RUN_LSB + RUN_HALFWORD_WIDTH;

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [PAYLOAD_WIDTH-1:0] way0_mem_q [0:SETS-1];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [PAYLOAD_WIDTH-1:0] way1_mem_q [0:SETS-1];
    reg [SETS-1:0] way0_valid_q;
    reg [SETS-1:0] way1_valid_q;
    reg [SETS-1:0] replace_way_q;

    reg train_pending_q;
    reg [SET_INDEX_WIDTH-1:0] train_pending_index_q;
    reg [KEY_TAG_WIDTH-1:0] train_pending_tag_q;
    reg [RUN_HALFWORD_WIDTH-1:0] train_pending_run_q;
    reg [2:0] train_pending_class_q;
    reg train_pending_length_32_q;
    reg [`RV64_XLEN-1:0] train_pending_target_q;
    reg train_pending_taken_q;
    reg [PAYLOAD_WIDTH-1:0] train_way0_data_q;
    reg [PAYLOAD_WIDTH-1:0] train_way1_data_q;

    // One synchronous RAM result sits in front of the response queue.  It is
    // also the source of the next autonomous lookup on a hit.
    reg read_valid_q;
    reg [REQUEST_ID_WIDTH-1:0] read_request_id_q;
    reg [REQUEST_ID_WIDTH-1:0] read_prediction_token_q;
    reg [`RV64_XLEN-1:0] read_stream_pc_q;
    reg [KEY_TAG_WIDTH-1:0] read_lookup_tag_q;
    reg read_way0_valid_q;
    reg read_way1_valid_q;
    reg [PAYLOAD_WIDTH-1:0] read_way0_data_q;
    reg [PAYLOAD_WIDTH-1:0] read_way1_data_q;

    reg chain_active_q;
    reg [REQUEST_ID_WIDTH-1:0] chain_request_id_q;
    reg [REQUEST_ID_WIDTH-1:0] next_prediction_token_q;

    reg response_hit_q [0:RESPONSE_QUEUE_DEPTH-1];
    reg [REQUEST_ID_WIDTH-1:0]
        response_request_id_q [0:RESPONSE_QUEUE_DEPTH-1];
    reg [REQUEST_ID_WIDTH-1:0]
        response_prediction_token_q [0:RESPONSE_QUEUE_DEPTH-1];
    reg [`RV64_XLEN-1:0]
        response_stream_pc_q [0:RESPONSE_QUEUE_DEPTH-1];
    reg [`RV64_XLEN-1:0]
        response_control_pc_q [0:RESPONSE_QUEUE_DEPTH-1];
    reg [`RV64_XLEN-1:0]
        response_control_end_pc_q [0:RESPONSE_QUEUE_DEPTH-1];
    reg [2:0] response_control_class_q [0:RESPONSE_QUEUE_DEPTH-1];
    reg [`RV64_XLEN-1:0]
        response_target_pc_q [0:RESPONSE_QUEUE_DEPTH-1];
    reg [`RV64_XLEN-1:0]
        response_successor_pc_q [0:RESPONSE_QUEUE_DEPTH-1];
    reg response_taken_q [0:RESPONSE_QUEUE_DEPTH-1];
    reg response_way1_q [0:RESPONSE_QUEUE_DEPTH-1];
    reg [RESPONSE_QUEUE_INDEX_WIDTH-1:0] response_head_q;
    reg [RESPONSE_QUEUE_INDEX_WIDTH-1:0] response_tail_q;
    reg [RESPONSE_QUEUE_COUNT_WIDTH-1:0] response_count_q;

    wire [SET_INDEX_WIDTH-1:0] incoming_train_index =
        train_stream_pc_i[KEY_SHIFT +: SET_INDEX_WIDTH];
    wire [KEY_TAG_WIDTH-1:0] incoming_train_tag =
        train_stream_pc_i[`RV64_XLEN-1 -: KEY_TAG_WIDTH];
    wire [`RV64_XLEN-1:0] incoming_run_halfwords_full =
        (train_pc_i - train_stream_pc_i) >> 1;
    wire incoming_run_valid = !train_stream_pc_i[0] && !train_pc_i[0] &&
        (train_pc_i >= train_stream_pc_i) &&
        !(|incoming_run_halfwords_full[`RV64_XLEN-1:
                                      RUN_HALFWORD_WIDTH]);
    wire [RUN_HALFWORD_WIDTH-1:0] incoming_train_run =
        incoming_run_halfwords_full[RUN_HALFWORD_WIDTH-1:0];

    wire incoming_is_jal =
        `RV64_OPCODE(train_instr_i) == `RV64_OPCODE_JAL;
    wire incoming_is_jalr =
        `RV64_OPCODE(train_instr_i) == `RV64_OPCODE_JALR;
    wire incoming_rd_link = (`RV64_RD(train_instr_i) == 5'd1) ||
                            (`RV64_RD(train_instr_i) == 5'd5);
    wire incoming_rs1_link = (`RV64_RS1(train_instr_i) == 5'd1) ||
                             (`RV64_RS1(train_instr_i) == 5'd5);
    wire incoming_is_return = incoming_is_jalr &&
        (`RV64_RD(train_instr_i) == 5'd0) && incoming_rs1_link &&
        (`RV64_IMM_I(train_instr_i) == 64'd0);
    wire [2:0] incoming_train_class = train_conditional_i ?
        `OPENRV64_STREAM_CONTROL_CONDITIONAL : incoming_is_return ?
        `OPENRV64_STREAM_CONTROL_RETURN : incoming_is_jal ?
        (incoming_rd_link ? `OPENRV64_STREAM_CONTROL_DIRECT_CALL :
                            `OPENRV64_STREAM_CONTROL_DIRECT_JUMP) :
        (incoming_rd_link ? `OPENRV64_STREAM_CONTROL_INDIRECT_CALL :
                            `OPENRV64_STREAM_CONTROL_INDIRECT_JUMP);
    wire [`RV64_XLEN-1:0] incoming_train_target =
        train_conditional_i ?
            (train_pc_i + `RV64_IMM_B(train_instr_i)) :
            train_next_pc_i;

    wire [KEY_TAG_WIDTH-1:0] train_way0_tag =
        train_way0_data_q[KEY_TAG_LSB +: KEY_TAG_WIDTH];
    wire [KEY_TAG_WIDTH-1:0] train_way1_tag =
        train_way1_data_q[KEY_TAG_LSB +: KEY_TAG_WIDTH];
    wire train_way0_valid = way0_valid_q[train_pending_index_q];
    wire train_way1_valid = way1_valid_q[train_pending_index_q];
    wire train_way0_match = train_way0_valid &&
        (train_way0_tag == train_pending_tag_q);
    wire train_way1_match = train_way1_valid &&
        (train_way1_tag == train_pending_tag_q);
    wire [PAYLOAD_WIDTH-1:0] train_old_payload = train_way1_match ?
        train_way1_data_q : train_way0_data_q;
    wire [RUN_HALFWORD_WIDTH-1:0] train_old_run =
        train_old_payload[RUN_LSB +: RUN_HALFWORD_WIDTH];
    wire train_tag_match = train_way0_match || train_way1_match;
    wire train_same_control = train_tag_match &&
        (train_pending_run_q == train_old_run);
    wire train_shorter_control = train_tag_match &&
        (train_pending_run_q < train_old_run);
    wire train_later_control = train_tag_match &&
        (train_pending_run_q > train_old_run);

    function automatic [DIRECTION_WIDTH-1:0] update_direction;
        input [DIRECTION_WIDTH-1:0] counter;
        input taken;
        begin
            if (taken)
                update_direction = (&counter) ? counter : counter + 1'b1;
            else
                update_direction = (|counter) ? counter - 1'b1 : counter;
        end
    endfunction

    wire [DIRECTION_WIDTH-1:0] train_old_direction =
        train_old_payload[DIRECTION_LSB +: DIRECTION_WIDTH];
    wire [DIRECTION_WIDTH-1:0] train_new_direction =
        train_same_control ?
            update_direction(train_old_direction,
                             train_pending_taken_q) :
            {train_pending_taken_q, 1'b0};
    wire [PAYLOAD_WIDTH-1:0] train_payload = {
        train_pending_tag_q,
        train_pending_run_q,
        train_pending_class_q,
        train_pending_length_32_q,
        train_pending_target_q[`RV64_XLEN-1:1],
        train_new_direction
    };

    reg train_write_way0_r;
    reg train_write_way1_r;
    always @* begin
        train_write_way0_r = 1'b0;
        train_write_way1_r = 1'b0;
        if (train_pending_q) begin
            // Several controls can resolve from the same cold, still-open
            // stream.  Only the nearest control belongs in an RLE entry.
            // Resolution order is not program order, so replace an observed
            // farther control when a shorter run arrives and ignore later
            // controls once the nearest run is known.
            if (train_tag_match) begin
                if (train_way0_match && !train_later_control)
                    train_write_way0_r = 1'b1;
                else if (train_way1_match && !train_later_control)
                    train_write_way1_r = 1'b1;
            end else if (!train_way0_valid)
                train_write_way0_r = 1'b1;
            else if (!train_way1_valid)
                train_write_way1_r = 1'b1;
            else if (replace_way_q[train_pending_index_q])
                train_write_way1_r = 1'b1;
            else
                train_write_way0_r = 1'b1;
        end
    end

    wire train_update = train_pending_q && train_same_control;
    wire train_shorten = train_pending_q && train_shorter_control;
    wire train_ignored_later = train_pending_q && train_later_control;
    wire train_insert = train_pending_q && !train_tag_match &&
        (!train_way0_valid || !train_way1_valid);
    wire train_replacement = train_pending_q && !train_tag_match &&
        train_way0_valid && train_way1_valid;

    wire [KEY_TAG_WIDTH-1:0] read_way0_tag =
        read_way0_data_q[KEY_TAG_LSB +: KEY_TAG_WIDTH];
    wire [KEY_TAG_WIDTH-1:0] read_way1_tag =
        read_way1_data_q[KEY_TAG_LSB +: KEY_TAG_WIDTH];
    wire read_way0_hit = read_way0_valid_q &&
        (read_way0_tag == read_lookup_tag_q);
    wire read_way1_hit = read_way1_valid_q &&
        (read_way1_tag == read_lookup_tag_q);
    wire read_select_way1 = read_way1_hit;
    wire read_hit = read_way0_hit || read_way1_hit;
    wire [PAYLOAD_WIDTH-1:0] read_payload = read_select_way1 ?
        read_way1_data_q : read_way0_data_q;
    wire [RUN_HALFWORD_WIDTH-1:0] read_run =
        read_payload[RUN_LSB +: RUN_HALFWORD_WIDTH];
    wire [2:0] read_class =
        read_payload[CONTROL_CLASS_LSB +: 3];
    wire read_length_32 = read_payload[LENGTH_32_BIT];
    wire [`RV64_XLEN-1:0] read_target = {
        read_payload[TARGET_LSB +: TARGET_WIDTH], 1'b0
    };
    wire [DIRECTION_WIDTH-1:0] read_direction =
        read_payload[DIRECTION_LSB +: DIRECTION_WIDTH];
    wire [`RV64_XLEN-1:0] read_control_pc =
        read_stream_pc_q +
        {{(`RV64_XLEN-RUN_HALFWORD_WIDTH-1){1'b0}}, read_run, 1'b0};
    wire [`RV64_XLEN-1:0] read_control_end_pc =
        read_control_pc + (read_length_32 ? 64'd4 : 64'd2);
    wire read_conditional = read_class ==
        `OPENRV64_STREAM_CONTROL_CONDITIONAL;
    wire read_taken = read_hit &&
        (!read_conditional || read_direction[DIRECTION_WIDTH-1]);
    wire [`RV64_XLEN-1:0] read_successor_pc = read_taken ?
        read_target : read_control_end_pc;

    wire response_dequeue = (response_count_q != 0) && response_ready_i;
    wire read_direct = read_valid_q && (response_count_q == 0) &&
                       response_ready_i;
    wire response_queue_room =
        (response_count_q < RESPONSE_QUEUE_DEPTH) || response_dequeue;
    wire read_enqueue = read_valid_q && !read_direct &&
                        response_queue_room && !cancel_i;
    wire read_retire = read_direct || read_enqueue;
    wire chain_lookup = read_retire && read_hit && !cancel_i;
    assign lookup_ready_o = !cancel_i && !chain_active_q && !read_valid_q &&
        (response_count_q == 0);
    wire root_lookup = lookup_valid_i && lookup_ready_o;
    wire ram_lookup_fire = root_lookup || chain_lookup;
    wire [`RV64_XLEN-1:0] ram_lookup_pc = root_lookup ?
        lookup_pc_i : read_successor_pc;
    wire [SET_INDEX_WIDTH-1:0] ram_lookup_index =
        ram_lookup_pc[KEY_SHIFT +: SET_INDEX_WIDTH];
    wire [KEY_TAG_WIDTH-1:0] ram_lookup_tag =
        ram_lookup_pc[`RV64_XLEN-1 -: KEY_TAG_WIDTH];
    wire [REQUEST_ID_WIDTH-1:0] ram_lookup_request_id = root_lookup ?
        lookup_request_id_i : chain_request_id_q;

    // The RAMs have synchronous predictor and training ports.  Collision
    // forwarding makes simultaneous training and prediction deterministic.
    always @(posedge clk) begin
        if (train_write_way0_r)
            way0_mem_q[train_pending_index_q] <= train_payload;
        if (train_write_way1_r)
            way1_mem_q[train_pending_index_q] <= train_payload;

        if (ram_lookup_fire) begin
            read_way0_data_q <=
                (train_write_way0_r &&
                 (train_pending_index_q == ram_lookup_index)) ?
                    train_payload : way0_mem_q[ram_lookup_index];
            read_way1_data_q <=
                (train_write_way1_r &&
                 (train_pending_index_q == ram_lookup_index)) ?
                    train_payload : way1_mem_q[ram_lookup_index];
        end

        if (train_valid_i && incoming_run_valid) begin
            train_way0_data_q <=
                (train_write_way0_r &&
                 (train_pending_index_q == incoming_train_index)) ?
                    train_payload : way0_mem_q[incoming_train_index];
            train_way1_data_q <=
                (train_write_way1_r &&
                 (train_pending_index_q == incoming_train_index)) ?
                    train_payload : way1_mem_q[incoming_train_index];
        end
    end

    integer reset_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            way0_valid_q <= {SETS{1'b0}};
            way1_valid_q <= {SETS{1'b0}};
            replace_way_q <= {SETS{1'b0}};
            train_pending_q <= 1'b0;
            train_pending_index_q <= {SET_INDEX_WIDTH{1'b0}};
            train_pending_tag_q <= {KEY_TAG_WIDTH{1'b0}};
            train_pending_run_q <= {RUN_HALFWORD_WIDTH{1'b0}};
            train_pending_class_q <=
                `OPENRV64_STREAM_CONTROL_CONDITIONAL;
            train_pending_length_32_q <= 1'b1;
            train_pending_target_q <= {`RV64_XLEN{1'b0}};
            train_pending_taken_q <= 1'b0;
            read_valid_q <= 1'b0;
            read_request_id_q <= {REQUEST_ID_WIDTH{1'b0}};
            read_prediction_token_q <= {REQUEST_ID_WIDTH{1'b0}};
            read_stream_pc_q <= {`RV64_XLEN{1'b0}};
            read_lookup_tag_q <= {KEY_TAG_WIDTH{1'b0}};
            read_way0_valid_q <= 1'b0;
            read_way1_valid_q <= 1'b0;
            chain_active_q <= 1'b0;
            chain_request_id_q <= {REQUEST_ID_WIDTH{1'b0}};
            next_prediction_token_q <= {{(REQUEST_ID_WIDTH-1){1'b0}}, 1'b1};
            response_head_q <= {RESPONSE_QUEUE_INDEX_WIDTH{1'b0}};
            response_tail_q <= {RESPONSE_QUEUE_INDEX_WIDTH{1'b0}};
            response_count_q <= {RESPONSE_QUEUE_COUNT_WIDTH{1'b0}};
            for (reset_index = 0; reset_index < RESPONSE_QUEUE_DEPTH;
                 reset_index = reset_index + 1) begin
                response_hit_q[reset_index] <= 1'b0;
                response_request_id_q[reset_index] <=
                    {REQUEST_ID_WIDTH{1'b0}};
                response_prediction_token_q[reset_index] <=
                    {REQUEST_ID_WIDTH{1'b0}};
                response_stream_pc_q[reset_index] <= 64'd0;
                response_control_pc_q[reset_index] <= 64'd0;
                response_control_end_pc_q[reset_index] <= 64'd0;
                response_control_class_q[reset_index] <= 3'd0;
                response_target_pc_q[reset_index] <= 64'd0;
                response_successor_pc_q[reset_index] <= 64'd0;
                response_taken_q[reset_index] <= 1'b0;
                response_way1_q[reset_index] <= 1'b0;
            end
        end else begin
            if (train_write_way0_r) begin
                way0_valid_q[train_pending_index_q] <= 1'b1;
                replace_way_q[train_pending_index_q] <= 1'b1;
            end
            if (train_write_way1_r) begin
                way1_valid_q[train_pending_index_q] <= 1'b1;
                replace_way_q[train_pending_index_q] <= 1'b0;
            end

            train_pending_q <= train_valid_i && incoming_run_valid;
            if (train_valid_i && incoming_run_valid) begin
                train_pending_index_q <= incoming_train_index;
                train_pending_tag_q <= incoming_train_tag;
                train_pending_run_q <= incoming_train_run;
                train_pending_class_q <= incoming_train_class;
                train_pending_length_32_q <= train_length_32_i;
                train_pending_target_q <= incoming_train_target;
                train_pending_taken_q <= train_taken_i;
            end

            if (cancel_i) begin
                read_valid_q <= 1'b0;
                chain_active_q <= 1'b0;
                response_head_q <= {RESPONSE_QUEUE_INDEX_WIDTH{1'b0}};
                response_tail_q <= {RESPONSE_QUEUE_INDEX_WIDTH{1'b0}};
                response_count_q <= {RESPONSE_QUEUE_COUNT_WIDTH{1'b0}};
            end else begin
                if (read_enqueue) begin
                    response_hit_q[response_tail_q] <= read_hit;
                    response_request_id_q[response_tail_q] <=
                        read_request_id_q;
                    response_prediction_token_q[response_tail_q] <=
                        read_prediction_token_q;
                    response_stream_pc_q[response_tail_q] <=
                        read_stream_pc_q;
                    response_control_pc_q[response_tail_q] <=
                        read_control_pc;
                    response_control_end_pc_q[response_tail_q] <=
                        read_control_end_pc;
                    response_control_class_q[response_tail_q] <= read_class;
                    response_target_pc_q[response_tail_q] <= read_target;
                    response_successor_pc_q[response_tail_q] <=
                        read_successor_pc;
                    response_taken_q[response_tail_q] <= read_taken;
                    response_way1_q[response_tail_q] <= read_select_way1;
                    response_tail_q <= (response_tail_q + 1'b1) &
                                       (RESPONSE_QUEUE_DEPTH - 1);
                end
                if (read_retire && !read_hit)
                    chain_active_q <= 1'b0;
                if (response_dequeue)
                    response_head_q <= (response_head_q + 1'b1) &
                                       (RESPONSE_QUEUE_DEPTH - 1);
                case ({read_enqueue, response_dequeue})
                    2'b10: response_count_q <= response_count_q + 1'b1;
                    2'b01: response_count_q <= response_count_q - 1'b1;
                    default: begin
                    end
                endcase

                if (read_retire && !ram_lookup_fire)
                    read_valid_q <= 1'b0;
                if (ram_lookup_fire) begin
                    read_valid_q <= 1'b1;
                    read_request_id_q <= ram_lookup_request_id;
                    read_prediction_token_q <= next_prediction_token_q;
                    read_stream_pc_q <= ram_lookup_pc;
                    read_lookup_tag_q <= ram_lookup_tag;
                    read_way0_valid_q <=
                        (train_write_way0_r &&
                         (train_pending_index_q == ram_lookup_index)) ?
                            1'b1 : way0_valid_q[ram_lookup_index];
                    read_way1_valid_q <=
                        (train_write_way1_r &&
                         (train_pending_index_q == ram_lookup_index)) ?
                            1'b1 : way1_valid_q[ram_lookup_index];
                    next_prediction_token_q <=
                        next_prediction_token_q + 1'b1;
                end
                if (root_lookup) begin
                    chain_active_q <= 1'b1;
                    chain_request_id_q <= lookup_request_id_i;
                end
            end
        end
    end

    wire response_from_queue = response_count_q != 0;
    assign response_valid_o = response_from_queue || read_valid_q;
    assign response_request_id_o = response_from_queue ?
        response_request_id_q[response_head_q] : read_request_id_q;
    assign response_stream_pc_o = response_from_queue ?
        response_stream_pc_q[response_head_q] : read_stream_pc_q;
    assign response_hit_o = response_from_queue ?
        response_hit_q[response_head_q] : read_hit;
    assign response_control_pc_o = response_from_queue ?
        response_control_pc_q[response_head_q] : read_control_pc;
    assign response_control_end_pc_o = response_from_queue ?
        response_control_end_pc_q[response_head_q] : read_control_end_pc;
    assign response_control_class_o = response_from_queue ?
        response_control_class_q[response_head_q] : read_class;
    assign response_conditional_o = response_valid_o && response_hit_o &&
        (response_control_class_o ==
         `OPENRV64_STREAM_CONTROL_CONDITIONAL);
    assign response_target_pc_o = response_from_queue ?
        response_target_pc_q[response_head_q] : read_target;
    assign response_successor_pc_o = response_from_queue ?
        response_successor_pc_q[response_head_q] : read_successor_pc;
    assign response_taken_o = response_from_queue ?
        response_taken_q[response_head_q] : read_taken;
    assign response_prediction_token_o = response_from_queue ?
        response_prediction_token_q[response_head_q] :
        read_prediction_token_q;

    assign diag_lookup_fire_o = ram_lookup_fire;
    assign diag_root_lookup_o = root_lookup;
    assign diag_chain_lookup_o = chain_lookup;
    assign diag_response_fire_o = read_retire;
    assign diag_response_hit_o = read_retire && read_hit;
    assign diag_response_way1_o = read_retire && read_select_way1;
    assign diag_queue_enqueue_o = read_enqueue;
    assign diag_queue_dequeue_o = response_dequeue;
    assign diag_queue_full_stall_o = read_valid_q && !response_queue_room;
    assign diag_queue_count_o = response_count_q;
    assign diag_train_fire_o = train_pending_q;
    assign diag_train_update_o = train_update;
    assign diag_train_insert_o = train_insert;
    assign diag_train_replacement_o = train_replacement;
    assign diag_train_shorter_o = train_shorten;
    assign diag_train_later_ignored_o = train_ignored_later;
    assign diag_train_run_overflow_o = train_valid_i && !incoming_run_valid;
    assign diag_train_conditional_o = train_pending_q &&
                                      train_pending_class_q ==
                                      `OPENRV64_STREAM_CONTROL_CONDITIONAL;
    assign diag_train_taken_o = train_pending_q && train_pending_taken_q;

`ifndef SYNTHESIS
    initial begin
        if ((ENTRIES < 4) || ((ENTRIES & (ENTRIES - 1)) != 0))
            $fatal(1, "stream RLE entries must be a power of two >= 4");
        if ((RUN_HALFWORD_WIDTH < 4) || (RUN_HALFWORD_WIDTH >= `RV64_XLEN))
            $fatal(1, "stream RLE run width is invalid");
        if ((RESPONSE_QUEUE_DEPTH < 2) ||
            ((RESPONSE_QUEUE_DEPTH & (RESPONSE_QUEUE_DEPTH - 1)) != 0))
            $fatal(1, "stream RLE response queue must be a power of two >= 2");
    end

    always @(posedge clk) begin
        if (rst_n && root_lookup && lookup_pc_i[0])
            $error("stream RLE lookup PC is not halfword aligned");
        if (rst_n && chain_lookup && read_successor_pc[0])
            $error("stream RLE chained to an unaligned successor");
        if (rst_n && train_valid_i &&
            (train_stream_pc_i[0] || train_pc_i[0] ||
             train_next_pc_i[0]))
            $error("stream RLE trained with an unaligned PC");
        if (rst_n && train_valid_i && !incoming_run_valid)
            $error("stream RLE run does not fit the encoded length");
        if (rst_n && response_count_q > RESPONSE_QUEUE_DEPTH)
            $fatal(1, "stream RLE response queue overflow");
    end
`endif

endmodule
