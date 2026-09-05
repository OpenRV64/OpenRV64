`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

// Sector-indexed frontend control directory.
//
// This is deliberately separate from the execution predictor's indirect
// target BTB.  That table answers an exact-PC JALR target lookup; fetch needs
// the earliest known control at or after an arbitrary halfword within a
// 16-byte sector.  Two ways allow either two controls in one sector or two
// aliased sectors without increasing the 256-entry budget.
//
// The two 128-bit payload arrays are reset-free synchronous memories so FPGA
// tools can infer block RAM.  Resettable validity and replacement state remain
// small sidecars.  Conditional direction is intentionally BTFNT here; the
// full direction predictor may correct it after decode.
module openrv64_fetch_stream_btb #(
    parameter integer ENTRIES = 256,
    parameter integer REQUEST_ID_WIDTH = 32,
    parameter integer SETS = ENTRIES / 2,
    parameter integer SET_INDEX_WIDTH = $clog2(SETS)
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         lookup_valid_i,
    output wire                         lookup_ready_o,
    input  wire [`RV64_XLEN-1:0]        lookup_pc_i,
    input  wire [REQUEST_ID_WIDTH-1:0]  lookup_request_id_i,

    output wire                         response_valid_o,
    input  wire                         response_ready_i,
    output wire [REQUEST_ID_WIDTH-1:0]  response_request_id_o,
    output wire                         response_hit_o,
    output wire [`RV64_XLEN-1:0]        response_control_pc_o,
    output wire [`RV64_XLEN-1:0]        response_control_end_pc_o,
    output wire [`RV64_XLEN-1:0]        response_successor_pc_o,
    output wire                         response_taken_o,
    output wire [REQUEST_ID_WIDTH-1:0]  response_prediction_token_o,

    // Resolution supplies the actual next PC.  For a conditional not-taken
    // result, the encoded B-immediate reconstructs the target BTFNT needs.
    input  wire                         train_valid_i,
    input  wire                         train_conditional_i,
    input  wire                         train_length_32_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] train_instr_i,
    input  wire [`RV64_XLEN-1:0]        train_pc_i,
    input  wire [`RV64_XLEN-1:0]        train_next_pc_i,

    output wire                         diag_lookup_fire_o,
    output wire                         diag_response_fire_o,
    output wire                         diag_response_hit_o,
    output wire                         diag_response_way1_o,
    output wire                         diag_train_fire_o,
    output wire                         diag_train_update_o,
    output wire                         diag_train_insert_o,
    output wire                         diag_train_replacement_o,
    output wire                         diag_train_same_sector_second_o,
    output wire                         diag_train_same_sector_overflow_o
);
    localparam integer SECTOR_SHIFT = 4;
    localparam integer SECTOR_TAG_WIDTH = `RV64_XLEN - SECTOR_SHIFT;
    localparam integer CONTROL_OFFSET_WIDTH = 3;
    localparam integer TARGET_WIDTH = `RV64_XLEN - 1;
    localparam integer PAYLOAD_WIDTH = SECTOR_TAG_WIDTH +
        CONTROL_OFFSET_WIDTH + 1 + 1 + TARGET_WIDTH;

    localparam integer TARGET_LSB = 0;
    localparam integer LENGTH_32_BIT = TARGET_LSB + TARGET_WIDTH;
    localparam integer CONDITIONAL_BIT = LENGTH_32_BIT + 1;
    localparam integer CONTROL_OFFSET_LSB = CONDITIONAL_BIT + 1;
    localparam integer SECTOR_TAG_LSB = CONTROL_OFFSET_LSB +
        CONTROL_OFFSET_WIDTH;

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [PAYLOAD_WIDTH-1:0] way0_mem_q [0:SETS-1];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [PAYLOAD_WIDTH-1:0] way1_mem_q [0:SETS-1];

    reg [SETS-1:0] way0_valid_q;
    reg [SETS-1:0] way1_valid_q;
    reg [SETS-1:0] replace_way_q;

    reg train_pending_q;
    reg [SET_INDEX_WIDTH-1:0] train_pending_index_q;
    reg [SECTOR_TAG_WIDTH-1:0] train_pending_tag_q;
    reg [CONTROL_OFFSET_WIDTH-1:0] train_pending_offset_q;
    reg train_pending_conditional_q;
    reg train_pending_length_32_q;
    reg [`RV64_XLEN-1:0] train_pending_target_q;
    reg [PAYLOAD_WIDTH-1:0] train_way0_data_q;
    reg [PAYLOAD_WIDTH-1:0] train_way1_data_q;

    reg response_valid_q;
    reg [REQUEST_ID_WIDTH-1:0] response_request_id_q;
    reg [`RV64_XLEN-1:0] response_lookup_pc_q;
    reg response_way0_valid_q;
    reg response_way1_valid_q;
    reg [PAYLOAD_WIDTH-1:0] response_way0_data_q;
    reg [PAYLOAD_WIDTH-1:0] response_way1_data_q;

    wire [SET_INDEX_WIDTH-1:0] lookup_index =
        lookup_pc_i[SECTOR_SHIFT +: SET_INDEX_WIDTH];
    wire [SET_INDEX_WIDTH-1:0] incoming_train_index =
        train_pc_i[SECTOR_SHIFT +: SET_INDEX_WIDTH];
    wire [SECTOR_TAG_WIDTH-1:0] incoming_train_tag =
        train_pc_i[`RV64_XLEN-1:SECTOR_SHIFT];
    wire [CONTROL_OFFSET_WIDTH-1:0] incoming_train_offset =
        train_pc_i[SECTOR_SHIFT-1:1];
    wire [`RV64_XLEN-1:0] incoming_train_target =
        train_conditional_i ?
            (train_pc_i + `RV64_IMM_B(train_instr_i)) :
            train_next_pc_i;

    wire [SECTOR_TAG_WIDTH-1:0] train_way0_tag =
        train_way0_data_q[SECTOR_TAG_LSB +: SECTOR_TAG_WIDTH];
    wire [SECTOR_TAG_WIDTH-1:0] train_way1_tag =
        train_way1_data_q[SECTOR_TAG_LSB +: SECTOR_TAG_WIDTH];
    wire [CONTROL_OFFSET_WIDTH-1:0] train_way0_offset =
        train_way0_data_q[CONTROL_OFFSET_LSB +:
                          CONTROL_OFFSET_WIDTH];
    wire [CONTROL_OFFSET_WIDTH-1:0] train_way1_offset =
        train_way1_data_q[CONTROL_OFFSET_LSB +:
                          CONTROL_OFFSET_WIDTH];
    wire train_way0_valid = way0_valid_q[train_pending_index_q];
    wire train_way1_valid = way1_valid_q[train_pending_index_q];
    wire train_way0_sector_match = train_way0_valid &&
        (train_way0_tag == train_pending_tag_q);
    wire train_way1_sector_match = train_way1_valid &&
        (train_way1_tag == train_pending_tag_q);
    wire train_way0_control_match = train_way0_sector_match &&
        (train_way0_offset == train_pending_offset_q);
    wire train_way1_control_match = train_way1_sector_match &&
        (train_way1_offset == train_pending_offset_q);

    wire [PAYLOAD_WIDTH-1:0] train_payload = {
        train_pending_tag_q,
        train_pending_offset_q,
        train_pending_conditional_q,
        train_pending_length_32_q,
        train_pending_target_q[`RV64_XLEN-1:1]
    };

    reg train_write_way0_r;
    reg train_write_way1_r;
    always @* begin
        train_write_way0_r = 1'b0;
        train_write_way1_r = 1'b0;
        if (train_pending_q) begin
            if (train_way0_control_match)
                train_write_way0_r = 1'b1;
            else if (train_way1_control_match)
                train_write_way1_r = 1'b1;
            else if (!train_way0_valid)
                train_write_way0_r = 1'b1;
            else if (!train_way1_valid)
                train_write_way1_r = 1'b1;
            else if (train_way0_sector_match &&
                     !train_way1_sector_match)
                train_write_way1_r = 1'b1;
            else if (!train_way0_sector_match &&
                     train_way1_sector_match)
                train_write_way0_r = 1'b1;
            else if (replace_way_q[train_pending_index_q])
                train_write_way1_r = 1'b1;
            else
                train_write_way0_r = 1'b1;
        end
    end

    wire train_update = train_pending_q &&
        (train_way0_control_match || train_way1_control_match);
    wire train_insert = train_pending_q && !train_update &&
        (!train_way0_valid || !train_way1_valid);
    wire train_replacement = train_pending_q && !train_update &&
        train_way0_valid && train_way1_valid;
    wire train_same_sector_second = train_pending_q && !train_update &&
        (train_way0_sector_match ^ train_way1_sector_match);
    wire train_same_sector_overflow = train_replacement &&
        train_way0_sector_match && train_way1_sector_match;

    // The payload RAMs have one synchronous lookup port and one synchronous
    // training read/write port.  Explicit collision forwarding makes the
    // inferred RAM behavior deterministic.
    always @(posedge clk) begin
        if (train_write_way0_r)
            way0_mem_q[train_pending_index_q] <= train_payload;
        if (train_write_way1_r)
            way1_mem_q[train_pending_index_q] <= train_payload;

        if (lookup_valid_i && lookup_ready_o) begin
            response_way0_data_q <=
                (train_write_way0_r &&
                 (train_pending_index_q == lookup_index)) ?
                    train_payload : way0_mem_q[lookup_index];
            response_way1_data_q <=
                (train_write_way1_r &&
                 (train_pending_index_q == lookup_index)) ?
                    train_payload : way1_mem_q[lookup_index];
        end

        if (train_valid_i) begin
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

    wire lookup_fire = lookup_valid_i && lookup_ready_o;
    wire response_fire = response_valid_q && response_ready_i;
    assign lookup_ready_o = !response_valid_q || response_ready_i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            way0_valid_q <= {SETS{1'b0}};
            way1_valid_q <= {SETS{1'b0}};
            replace_way_q <= {SETS{1'b0}};
            train_pending_q <= 1'b0;
            train_pending_index_q <= {SET_INDEX_WIDTH{1'b0}};
            train_pending_tag_q <= {SECTOR_TAG_WIDTH{1'b0}};
            train_pending_offset_q <= {CONTROL_OFFSET_WIDTH{1'b0}};
            train_pending_conditional_q <= 1'b0;
            train_pending_length_32_q <= 1'b1;
            train_pending_target_q <= {`RV64_XLEN{1'b0}};
            response_valid_q <= 1'b0;
            response_request_id_q <= {REQUEST_ID_WIDTH{1'b0}};
            response_lookup_pc_q <= {`RV64_XLEN{1'b0}};
            response_way0_valid_q <= 1'b0;
            response_way1_valid_q <= 1'b0;
        end else begin
            if (train_write_way0_r) begin
                way0_valid_q[train_pending_index_q] <= 1'b1;
                replace_way_q[train_pending_index_q] <= 1'b1;
            end
            if (train_write_way1_r) begin
                way1_valid_q[train_pending_index_q] <= 1'b1;
                replace_way_q[train_pending_index_q] <= 1'b0;
            end

            train_pending_q <= train_valid_i;
            if (train_valid_i) begin
                train_pending_index_q <= incoming_train_index;
                train_pending_tag_q <= incoming_train_tag;
                train_pending_offset_q <= incoming_train_offset;
                train_pending_conditional_q <= train_conditional_i;
                train_pending_length_32_q <= train_length_32_i;
                train_pending_target_q <= incoming_train_target;
            end

            if (lookup_ready_o) begin
                response_valid_q <= lookup_valid_i;
                if (lookup_valid_i) begin
                    response_request_id_q <= lookup_request_id_i;
                    response_lookup_pc_q <= lookup_pc_i;
                    response_way0_valid_q <=
                        (train_write_way0_r &&
                         (train_pending_index_q == lookup_index)) ?
                            1'b1 : way0_valid_q[lookup_index];
                    response_way1_valid_q <=
                        (train_write_way1_r &&
                         (train_pending_index_q == lookup_index)) ?
                            1'b1 : way1_valid_q[lookup_index];
                end
            end
        end
    end

    wire [SECTOR_TAG_WIDTH-1:0] response_way0_tag =
        response_way0_data_q[SECTOR_TAG_LSB +: SECTOR_TAG_WIDTH];
    wire [SECTOR_TAG_WIDTH-1:0] response_way1_tag =
        response_way1_data_q[SECTOR_TAG_LSB +: SECTOR_TAG_WIDTH];
    wire [CONTROL_OFFSET_WIDTH-1:0] response_way0_offset =
        response_way0_data_q[CONTROL_OFFSET_LSB +:
                             CONTROL_OFFSET_WIDTH];
    wire [CONTROL_OFFSET_WIDTH-1:0] response_way1_offset =
        response_way1_data_q[CONTROL_OFFSET_LSB +:
                             CONTROL_OFFSET_WIDTH];
    wire [SECTOR_TAG_WIDTH-1:0] response_lookup_tag =
        response_lookup_pc_q[`RV64_XLEN-1:SECTOR_SHIFT];
    wire [CONTROL_OFFSET_WIDTH-1:0] response_lookup_offset =
        response_lookup_pc_q[SECTOR_SHIFT-1:1];
    wire response_way0_hit = response_way0_valid_q &&
        (response_way0_tag == response_lookup_tag) &&
        (response_way0_offset >= response_lookup_offset);
    wire response_way1_hit = response_way1_valid_q &&
        (response_way1_tag == response_lookup_tag) &&
        (response_way1_offset >= response_lookup_offset);
    wire response_select_way1 = response_way1_hit &&
        (!response_way0_hit ||
         (response_way1_offset < response_way0_offset));
    wire [PAYLOAD_WIDTH-1:0] response_payload = response_select_way1 ?
        response_way1_data_q : response_way0_data_q;
    wire [SECTOR_TAG_WIDTH-1:0] response_control_tag =
        response_payload[SECTOR_TAG_LSB +: SECTOR_TAG_WIDTH];
    wire [CONTROL_OFFSET_WIDTH-1:0] response_control_offset =
        response_payload[CONTROL_OFFSET_LSB +: CONTROL_OFFSET_WIDTH];
    wire response_conditional = response_payload[CONDITIONAL_BIT];
    wire response_length_32 = response_payload[LENGTH_32_BIT];
    wire [`RV64_XLEN-1:0] response_target = {
        response_payload[TARGET_LSB +: TARGET_WIDTH], 1'b0
    };
    wire [`RV64_XLEN-1:0] response_control_pc = {
        response_control_tag, response_control_offset, 1'b0
    };
    wire [`RV64_XLEN-1:0] response_control_end_pc =
        response_control_pc + (response_length_32 ? 64'd4 : 64'd2);
    wire response_hit = response_way0_hit || response_way1_hit;
    wire response_taken = response_hit &&
        (!response_conditional || (response_target < response_control_pc));

    assign response_valid_o = response_valid_q;
    assign response_request_id_o = response_request_id_q;
    assign response_hit_o = response_hit;
    assign response_control_pc_o = response_hit ? response_control_pc :
                                                  {`RV64_XLEN{1'b0}};
    assign response_control_end_pc_o = response_hit ?
        response_control_end_pc : {`RV64_XLEN{1'b0}};
    assign response_successor_pc_o = response_hit ?
        (response_taken ? response_target : response_control_end_pc) :
        {`RV64_XLEN{1'b0}};
    assign response_taken_o = response_taken;
    assign response_prediction_token_o = response_request_id_q;

    assign diag_lookup_fire_o = lookup_fire;
    assign diag_response_fire_o = response_fire;
    assign diag_response_hit_o = response_fire && response_hit;
    assign diag_response_way1_o = response_fire && response_select_way1;
    assign diag_train_fire_o = train_pending_q;
    assign diag_train_update_o = train_update;
    assign diag_train_insert_o = train_insert;
    assign diag_train_replacement_o = train_replacement;
    assign diag_train_same_sector_second_o = train_same_sector_second;
    assign diag_train_same_sector_overflow_o =
        train_same_sector_overflow;

`ifndef SYNTHESIS
    initial begin
        if ((ENTRIES < 4) || ((ENTRIES & (ENTRIES - 1)) != 0))
            $fatal(1, "stream BTB entries must be a power of two >= 4");
        if (PAYLOAD_WIDTH != 128)
            $fatal(1, "stream BTB payload geometry must remain 128 bits");
    end

    always @(posedge clk) begin
        if (rst_n && lookup_fire && lookup_pc_i[0])
            $error("stream BTB lookup PC is not halfword aligned");
        if (rst_n && train_valid_i &&
            (train_pc_i[0] || train_next_pc_i[0]))
            $error("stream BTB trained with an unaligned PC");
    end
`endif

endmodule
