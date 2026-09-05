`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/fetch/fetch-defs.v"

// Convert fetch_istream's raw halfword prefix into the existing three-lane
// fetch/decode contract.  Instruction length is discovered here, not in
// fetch.  A lone lower parcel of a 32-bit instruction may be consumed into a
// two-byte stash so the next raw window can complete it without retaining a
// whole fetch block.
//
// This block aligns compressed instructions but does not, by itself, enable
// the C extension.  The architectural decoder and all PC/fallthrough state
// must consume instruction length before ENABLE_RV64C can be asserted safely.
module openrv64_decode_istream_3w #(
    parameter integer ENABLE_TRACE = 0,
    parameter integer ENABLE_PREDECODE_TARGETS = 1
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire                         istream_valid_i,
    input  wire [95:0]                  istream_data_i,
    input  wire [5:0]                   istream_halfword_valid_i,
    input  wire [5:0]                   istream_access_fault_i,
    input  wire [5:0]                   istream_page_fault_i,
    input  wire [`RV64_XLEN-1:0]        stream_pc_i,
    output wire                         istream_advance_half_o,
    output wire [3:0]                   istream_consume_halfwords_o,
    output wire [3:0]                   consumed_halfwords_o,

    output wire [2:0]                   decode_valid_o,
    input  wire [2:0]                   decode_ready_i,
    output wire [3*`RV64_FETCH_DECODE_BUS_WIDTH-1:0] decode_bus_o,
    input  wire [63:0]                  trace_id_i,
    output wire [3*64-1:0]              trace_id_o
);

    reg stash_valid_q;
    reg [15:0] stash_lower_q;
    reg [`RV64_XLEN-1:0] stash_pc_q;
    reg stash_access_fault_q;
    reg stash_page_fault_q;

    reg [2:0] lane_valid_r;
    reg [3*`RV64_INSTR_WIDTH-1:0] lane_instr_r;
    reg [3*`RV64_XLEN-1:0] lane_pc_r;
    reg [2:0] lane_access_fault_r;
    reg [2:0] lane_page_fault_r;
    reg [1:0] lane_input_halfwords_r [0:2];
    reg [2:0] lane_compressed_r;
    reg incomplete_valid_r;
    reg [15:0] incomplete_lower_r;
    reg [`RV64_XLEN-1:0] incomplete_pc_r;

    integer parse_lane;
    integer parcel_cursor;
    reg parse_open;
    reg [15:0] parse_lower;
    reg parse_lower_access_fault;
    reg parse_lower_page_fault;
    reg parse_upper_access_fault;
    reg parse_upper_page_fault;
    reg [`RV64_XLEN-1:0] parse_pc;

    // A fault terminates the presented prefix.  The faulting instruction is
    // represented as a 32-bit NOP with the original PC and fault metadata,
    // matching the legacy frontend's contract without trusting faulted data
    // to determine instruction length.
    always @* begin
        lane_valid_r = 3'b000;
        lane_instr_r = {3*`RV64_INSTR_WIDTH{1'b0}};
        lane_pc_r = {3*`RV64_XLEN{1'b0}};
        lane_access_fault_r = 3'b000;
        lane_page_fault_r = 3'b000;
        lane_compressed_r = 3'b000;
        incomplete_valid_r = 1'b0;
        incomplete_lower_r = 16'd0;
        incomplete_pc_r = {`RV64_XLEN{1'b0}};
        parcel_cursor = 0;
        parse_open = istream_valid_i;
        parse_lower = 16'd0;
        parse_lower_access_fault = 1'b0;
        parse_lower_page_fault = 1'b0;
        parse_upper_access_fault = 1'b0;
        parse_upper_page_fault = 1'b0;
        parse_pc = stream_pc_i;
        for (parse_lane = 0; parse_lane < 3;
             parse_lane = parse_lane + 1) begin
            lane_input_halfwords_r[parse_lane] = 2'd0;
            if (parse_open) begin
                if ((parse_lane == 0) && stash_valid_q) begin
                    if (istream_halfword_valid_i[0]) begin
                        parse_upper_access_fault =
                            istream_access_fault_i[0];
                        parse_upper_page_fault =
                            istream_page_fault_i[0];
                        lane_valid_r[parse_lane] = 1'b1;
                        lane_pc_r[parse_lane*`RV64_XLEN +:
                                  `RV64_XLEN] = stash_pc_q;
                        lane_access_fault_r[parse_lane] =
                            stash_access_fault_q |
                            parse_upper_access_fault;
                        lane_page_fault_r[parse_lane] =
                            stash_page_fault_q |
                            parse_upper_page_fault;
                        lane_instr_r[parse_lane*`RV64_INSTR_WIDTH +:
                                     `RV64_INSTR_WIDTH] =
                            (stash_access_fault_q |
                             parse_upper_access_fault |
                             stash_page_fault_q |
                             parse_upper_page_fault) ?
                                `RV64_INSTR_NOP :
                                {istream_data_i[15:0], stash_lower_q};
                        lane_input_halfwords_r[parse_lane] = 2'd1;
                        parcel_cursor = 1;
                        if (stash_access_fault_q |
                            parse_upper_access_fault |
                            stash_page_fault_q |
                            parse_upper_page_fault)
                            parse_open = 1'b0;
                    end else begin
                        parse_open = 1'b0;
                    end
                end else if ((parcel_cursor < 6) &&
                             istream_halfword_valid_i[parcel_cursor]) begin
                    parse_lower = istream_data_i[
                        parcel_cursor*16 +: 16];
                    parse_lower_access_fault =
                        istream_access_fault_i[parcel_cursor];
                    parse_lower_page_fault =
                        istream_page_fault_i[parcel_cursor];
                    parse_pc = stream_pc_i + (parcel_cursor * 2);
                    if (parse_lower_access_fault |
                        parse_lower_page_fault) begin
                        lane_valid_r[parse_lane] = 1'b1;
                        lane_instr_r[parse_lane*`RV64_INSTR_WIDTH +:
                                     `RV64_INSTR_WIDTH] =
                            `RV64_INSTR_NOP;
                        lane_pc_r[parse_lane*`RV64_XLEN +:
                                  `RV64_XLEN] = parse_pc;
                        lane_access_fault_r[parse_lane] =
                            parse_lower_access_fault;
                        lane_page_fault_r[parse_lane] =
                            parse_lower_page_fault;
                        lane_input_halfwords_r[parse_lane] = 2'd1;
                        parcel_cursor = parcel_cursor + 1;
                        parse_open = 1'b0;
                    end else if (parse_lower[1:0] != 2'b11) begin
                        lane_valid_r[parse_lane] = 1'b1;
                        lane_instr_r[parse_lane*`RV64_INSTR_WIDTH +:
                                     `RV64_INSTR_WIDTH] =
                            {16'd0, parse_lower};
                        lane_pc_r[parse_lane*`RV64_XLEN +:
                                  `RV64_XLEN] = parse_pc;
                        lane_input_halfwords_r[parse_lane] = 2'd1;
                        lane_compressed_r[parse_lane] = 1'b1;
                        parcel_cursor = parcel_cursor + 1;
                    end else if (((parcel_cursor + 1) < 6) &&
                                 istream_halfword_valid_i[
                                     parcel_cursor + 1]) begin
                        parse_upper_access_fault =
                            istream_access_fault_i[parcel_cursor + 1];
                        parse_upper_page_fault =
                            istream_page_fault_i[parcel_cursor + 1];
                        lane_valid_r[parse_lane] = 1'b1;
                        lane_instr_r[parse_lane*`RV64_INSTR_WIDTH +:
                                     `RV64_INSTR_WIDTH] =
                            (parse_upper_access_fault |
                             parse_upper_page_fault) ?
                                `RV64_INSTR_NOP :
                                istream_data_i[parcel_cursor*16 +: 32];
                        lane_pc_r[parse_lane*`RV64_XLEN +:
                                  `RV64_XLEN] = parse_pc;
                        lane_access_fault_r[parse_lane] =
                            parse_upper_access_fault;
                        lane_page_fault_r[parse_lane] =
                            parse_upper_page_fault;
                        lane_input_halfwords_r[parse_lane] = 2'd2;
                        parcel_cursor = parcel_cursor + 2;
                        if (parse_upper_access_fault |
                            parse_upper_page_fault)
                            parse_open = 1'b0;
                    end else begin
                        incomplete_valid_r = 1'b1;
                        incomplete_lower_r = parse_lower;
                        incomplete_pc_r = parse_pc;
                        parse_open = 1'b0;
                    end
                end else begin
                    parse_open = 1'b0;
                end
            end
        end
    end

    assign decode_valid_o[0] = lane_valid_r[0];
    assign decode_valid_o[1] = lane_valid_r[0] && lane_valid_r[1];
    assign decode_valid_o[2] = lane_valid_r[0] && lane_valid_r[1] &&
                               lane_valid_r[2];

    wire decode_fire0 = decode_valid_o[0] && decode_ready_i[0];
    wire decode_fire1 = decode_valid_o[1] && decode_fire0 &&
                        decode_ready_i[1];
    wire decode_fire2 = decode_valid_o[2] && decode_fire1 &&
                        decode_ready_i[2];
    wire [3:0] accepted_halfwords =
        (decode_fire0 ? {2'd0, lane_input_halfwords_r[0]} : 4'd0) +
        (decode_fire1 ? {2'd0, lane_input_halfwords_r[1]} : 4'd0) +
        (decode_fire2 ? {2'd0, lane_input_halfwords_r[2]} : 4'd0);
    wire all_presented_fire =
        (!decode_valid_o[0] || decode_fire0) &&
        (!decode_valid_o[1] || decode_fire1) &&
        (!decode_valid_o[2] || decode_fire2);
    wire stash_capture = !stash_valid_q && incomplete_valid_r &&
                         all_presented_fire;
    wire [3:0] total_consumed_halfwords = accepted_halfwords +
                                          {3'd0, stash_capture};
    wire compressed_fast_advance = !stash_valid_q && !stash_capture &&
        decode_fire2 && (&lane_compressed_r);

    assign istream_advance_half_o = compressed_fast_advance;
    assign istream_consume_halfwords_o = compressed_fast_advance ? 4'd0 :
                                         total_consumed_halfwords;
    assign consumed_halfwords_o = total_consumed_halfwords;

    function automatic direct_control_valid;
        input [`RV64_INSTR_WIDTH-1:0] instr;
        begin
            direct_control_valid = 1'b0;
            case (`RV64_OPCODE(instr))
                `RV64_OPCODE_JAL: direct_control_valid = 1'b1;
                `RV64_OPCODE_BRANCH: begin
                    case (`RV64_FUNCT3(instr))
                        `RV64_FUNCT3_BEQ,
                        `RV64_FUNCT3_BNE,
                        `RV64_FUNCT3_BLT,
                        `RV64_FUNCT3_BGE,
                        `RV64_FUNCT3_BLTU,
                        `RV64_FUNCT3_BGEU:
                            direct_control_valid = 1'b1;
                        default: begin
                        end
                    endcase
                end
                default: begin
                end
            endcase
        end
    endfunction

    genvar output_lane;
    generate
        for (output_lane = 0; output_lane < 3;
             output_lane = output_lane + 1) begin : g_decode_output
            wire [`RV64_INSTR_WIDTH-1:0] lane_instr = lane_instr_r[
                output_lane*`RV64_INSTR_WIDTH +: `RV64_INSTR_WIDTH];
            wire direct_valid = ENABLE_PREDECODE_TARGETS &&
                !lane_compressed_r[output_lane] &&
                !lane_access_fault_r[output_lane] &&
                !lane_page_fault_r[output_lane] &&
                direct_control_valid(lane_instr);
            wire direct_conditional = direct_valid &&
                (`RV64_OPCODE(lane_instr) == `RV64_OPCODE_BRANCH);
            wire [`RV64_XLEN-1:0] direct_imm =
                (`RV64_OPCODE(lane_instr) == `RV64_OPCODE_JAL) ?
                    `RV64_IMM_J(lane_instr) : `RV64_IMM_B(lane_instr);
            assign decode_bus_o[
                output_lane*`RV64_FETCH_DECODE_BUS_WIDTH +:
                `RV64_FETCH_DECODE_BUS_WIDTH] = {
                direct_conditional,
                direct_valid,
                direct_valid ? direct_imm[20:1] : 20'd0,
                lane_page_fault_r[output_lane],
                lane_access_fault_r[output_lane],
                lane_pc_r[output_lane*`RV64_XLEN +: `RV64_XLEN],
                lane_instr
            };
            assign trace_id_o[output_lane*64 +: 64] = ENABLE_TRACE ?
                trace_id_i + output_lane : 64'd0;
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stash_valid_q <= 1'b0;
            stash_lower_q <= 16'd0;
            stash_pc_q <= {`RV64_XLEN{1'b0}};
            stash_access_fault_q <= 1'b0;
            stash_page_fault_q <= 1'b0;
        end else if (flush_i) begin
            stash_valid_q <= 1'b0;
        end else begin
            if (stash_valid_q && decode_fire0)
                stash_valid_q <= 1'b0;
            if (stash_capture) begin
                stash_valid_q <= 1'b1;
                stash_lower_q <= incomplete_lower_r;
                stash_pc_q <= incomplete_pc_r;
                stash_access_fault_q <= 1'b0;
                stash_page_fault_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && (decode_fire1 && !decode_fire0))
            $fatal(1, "istream decode accepted lane 1 without lane 0");
        if (rst_n && (decode_fire2 && !decode_fire1))
            $fatal(1, "istream decode accepted lane 2 without lane 1");
        if (rst_n && stash_capture &&
            (incomplete_lower_r[1:0] != 2'b11))
            $fatal(1, "istream decode stashed a non-32-bit parcel");
    end
`endif

endmodule
