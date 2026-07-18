`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/fetch/fetch-defs.v"
`include "core/bus/bus-defs.v"

// Three-wide frontend for the 256-bit AXI fetch path.
//
// The four data entries form a direct-mapped 128-byte resident window.  The
// PC line index selects exactly one entry; there is no associative data/tag
// search.  Pending request state is separate from resident state so an
// ordinary redirect can cancel the sequential stream without destroying a
// warm loop.  Context-changing invalidations clear the resident valid bits.
// A bundle may cross a line boundary when both direct-mapped lines are warm.
module openrv64_fetch_3w #(
    parameter integer LINE_DEPTH = 4,
    parameter integer ENABLE_TRACE = 0,
    parameter integer ENABLE_PREDECODE_TARGETS = 1,
    parameter integer LINE_INDEX_WIDTH = $clog2(LINE_DEPTH),
    parameter integer LINE_COUNT_WIDTH = $clog2(LINE_DEPTH + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         restart_i,
    input  wire [`RV64_XLEN-1:0]        restart_pc_i,
    input  wire                         invalidate_i,
    input  wire                         stall_i,
    input  wire                         flush_i,
    output wire                         cancel_o,

    output wire                         req_valid_o,
    input  wire                         req_ready_i,
    output wire [`RV64_XLEN-1:0]        req_addr_o,
    input  wire                         resp_valid_i,
    output wire                         resp_ready_o,
    input  wire [`RV64_XLEN-1:0]        resp_addr_i,
    input  wire [`OPENRV64_AXI_DATA_WIDTH-1:0] resp_data_i,
    input  wire                         resp_access_fault_i,
    input  wire                         resp_page_fault_i,

    output wire [2:0]                   decode_valid_o,
    input  wire [2:0]                   decode_ready_i,
    output wire [3*`RV64_FETCH_DECODE_BUS_WIDTH-1:0] decode_bus_o,
    input  wire [63:0]                  trace_id_i,
    output wire [3*64-1:0]              trace_id_o,

    output wire [`RV64_XLEN-1:0]        stream_pc_o,
    output wire [LINE_COUNT_WIDTH-1:0]  line_count_o
);

    localparam integer LINE_BYTES = `OPENRV64_AXI_DATA_WIDTH / 8;
    localparam integer LINE_BYTE_BITS = $clog2(LINE_BYTES);

    reg active_q;
    reg [`RV64_XLEN-1:0] consume_pc_q;
    reg [`RV64_XLEN-1:0] next_req_addr_q;
    reg line_valid_q [0:LINE_DEPTH-1];
    reg [`RV64_XLEN-1:0] line_addr_q [0:LINE_DEPTH-1];
    reg [`OPENRV64_AXI_DATA_WIDTH-1:0] line_data_q [0:LINE_DEPTH-1];
    reg line_access_fault_q [0:LINE_DEPTH-1];
    reg line_page_fault_q [0:LINE_DEPTH-1];
    reg pending_valid_q [0:LINE_DEPTH-1];
    reg [`RV64_XLEN-1:0] pending_addr_q [0:LINE_DEPTH-1];

    assign cancel_o = restart_i || flush_i;
    assign resp_ready_o = 1'b1;
    assign stream_pc_o = consume_pc_q;

    localparam integer LINE_INDEX_LSB = LINE_BYTE_BITS;
    localparam integer LINE_INDEX_MSB = LINE_BYTE_BITS + LINE_INDEX_WIDTH - 1;

    wire [`RV64_XLEN-1:0] consume_line_addr = {
        consume_pc_q[`RV64_XLEN-1:LINE_BYTE_BITS],
        {LINE_BYTE_BITS{1'b0}}
    };
    wire [`RV64_XLEN-1:0] prefetch_last_addr = consume_line_addr +
        ((LINE_DEPTH - 1) * LINE_BYTES);
    wire [LINE_INDEX_WIDTH-1:0] prefetch_slot =
        next_req_addr_q[LINE_INDEX_MSB:LINE_INDEX_LSB];
    wire prefetch_resident = line_valid_q[prefetch_slot] &&
        (line_addr_q[prefetch_slot][`RV64_XLEN-1:LINE_BYTE_BITS] ==
         next_req_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire prefetch_pending = pending_valid_q[prefetch_slot] &&
        (pending_addr_q[prefetch_slot][`RV64_XLEN-1:LINE_BYTE_BITS] ==
         next_req_addr_q[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire prefetch_in_window = next_req_addr_q <= prefetch_last_addr;
    wire prefetch_covered = prefetch_resident || prefetch_pending;

    // One direct-mapped lookup advances the prefetch cursor.  A request may
    // replace the resident line only when its response arrives, leaving the
    // old loop line usable if a redirect cancels the pending replacement.
    assign req_valid_o = active_q && !restart_i && !flush_i && !stall_i &&
                         prefetch_in_window && !prefetch_covered &&
                         !pending_valid_q[prefetch_slot];
    assign req_addr_o = next_req_addr_q;
    wire req_fire = req_valid_o && req_ready_i;
    wire prefetch_advance = active_q && !restart_i && !flush_i && !stall_i &&
                            prefetch_in_window &&
                            (prefetch_covered || req_fire);

    reg [LINE_COUNT_WIDTH-1:0] line_count_r;
    integer count_index;
    always @* begin
        line_count_r = {LINE_COUNT_WIDTH{1'b0}};
        for (count_index = 0; count_index < LINE_DEPTH;
             count_index = count_index + 1)
            if (line_valid_q[count_index] || pending_valid_q[count_index])
                line_count_r = line_count_r + 1'b1;
    end
    assign line_count_o = line_count_r;

    reg [2:0] lane_found_r;
    reg [3*`RV64_INSTR_WIDTH-1:0] lane_instr_r;
    reg [2:0] lane_access_fault_r;
    reg [2:0] lane_page_fault_r;
    reg [`RV64_XLEN-1:0] lane_pc_r [0:2];
    integer lane_index;
    wire [LINE_INDEX_WIDTH-1:0] consume_slot =
        consume_line_addr[LINE_INDEX_MSB:LINE_INDEX_LSB];
    wire [`RV64_XLEN-1:0] following_line_addr =
        consume_line_addr + LINE_BYTES;
    wire [LINE_INDEX_WIDTH-1:0] following_slot =
        following_line_addr[LINE_INDEX_MSB:LINE_INDEX_LSB];
    wire consume_line_hit = line_valid_q[consume_slot] &&
        (line_addr_q[consume_slot][`RV64_XLEN-1:LINE_BYTE_BITS] ==
         consume_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire following_line_hit = line_valid_q[following_slot] &&
        (line_addr_q[following_slot][`RV64_XLEN-1:LINE_BYTE_BITS] ==
         following_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS]);
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] consume_line_data =
        line_data_q[consume_slot];
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] following_line_data =
        line_data_q[following_slot];
    always @* begin
        lane_found_r = 3'b000;
        lane_instr_r = {3*`RV64_INSTR_WIDTH{1'b0}};
        lane_access_fault_r = 3'b000;
        lane_page_fault_r = 3'b000;
        for (lane_index = 0; lane_index < 3;
             lane_index = lane_index + 1) begin
            lane_pc_r[lane_index] = consume_pc_q + (lane_index * 4);
            if ((lane_pc_r[lane_index][`RV64_XLEN-1:LINE_BYTE_BITS] ==
                 consume_line_addr[`RV64_XLEN-1:LINE_BYTE_BITS]) &&
                consume_line_hit) begin
                lane_found_r[lane_index] = 1'b1;
                lane_instr_r[lane_index*`RV64_INSTR_WIDTH +:
                             `RV64_INSTR_WIDTH] =
                    (line_access_fault_q[consume_slot] ||
                     line_page_fault_q[consume_slot]) ?
                    `RV64_INSTR_NOP : consume_line_data[
                        lane_pc_r[lane_index][LINE_BYTE_BITS-1:2] *
                        `RV64_INSTR_WIDTH +: `RV64_INSTR_WIDTH];
                lane_access_fault_r[lane_index] =
                    line_access_fault_q[consume_slot];
                lane_page_fault_r[lane_index] =
                    line_page_fault_q[consume_slot];
            end else if ((lane_pc_r[lane_index][
                           `RV64_XLEN-1:LINE_BYTE_BITS] ==
                          following_line_addr[
                           `RV64_XLEN-1:LINE_BYTE_BITS]) &&
                         following_line_hit) begin
                lane_found_r[lane_index] = 1'b1;
                lane_instr_r[lane_index*`RV64_INSTR_WIDTH +:
                             `RV64_INSTR_WIDTH] =
                    (line_access_fault_q[following_slot] ||
                     line_page_fault_q[following_slot]) ?
                    `RV64_INSTR_NOP : following_line_data[
                        lane_pc_r[lane_index][LINE_BYTE_BITS-1:2] *
                        `RV64_INSTR_WIDTH +: `RV64_INSTR_WIDTH];
                lane_access_fault_r[lane_index] =
                    line_access_fault_q[following_slot];
                lane_page_fault_r[lane_index] =
                    line_page_fault_q[following_slot];
            end
        end
    end

    // A predicted redirect may be generated by the instruction currently on
    // this interface.  Keep that bundle valid during restart_i; the restart
    // wins the sequential state update at the edge after the bundle is
    // accepted.  Top-level ready masking suppresses stale acceptance for
    // execute-time redirects and context changes.
    assign decode_valid_o[0] = active_q && !flush_i && lane_found_r[0];
    assign decode_valid_o[1] = decode_valid_o[0] && lane_found_r[1];
    assign decode_valid_o[2] = decode_valid_o[1] && lane_found_r[2];
    wire decode_fire0 = decode_valid_o[0] && decode_ready_i[0];
    wire decode_fire1 = decode_valid_o[1] && decode_fire0 &&
                        decode_ready_i[1];
    wire decode_fire2 = decode_valid_o[2] && decode_fire1 &&
                        decode_ready_i[2];
    wire [1:0] decode_count = {1'b0, decode_fire0} +
                              {1'b0, decode_fire1} +
                              {1'b0, decode_fire2};
    wire [`RV64_XLEN-1:0] next_consume_pc =
        consume_pc_q + ({62'd0, decode_count} << 2);

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
                lane_pc_r[output_lane],
                lane_instr
            };
            assign trace_id_o[output_lane*64 +: 64] = ENABLE_TRACE ?
                trace_id_i + output_lane : 64'd0;
        end
    endgenerate

    wire [LINE_INDEX_WIDTH-1:0] resp_slot =
        resp_addr_i[LINE_INDEX_MSB:LINE_INDEX_LSB];
    wire resp_match = pending_valid_q[resp_slot] &&
        (pending_addr_q[resp_slot][`RV64_XLEN-1:LINE_BYTE_BITS] ==
         resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS]);

    integer reset_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_q <= 1'b0;
            consume_pc_q <= {`RV64_XLEN{1'b0}};
            next_req_addr_q <= {`RV64_XLEN{1'b0}};
            for (reset_index = 0; reset_index < LINE_DEPTH;
                 reset_index = reset_index + 1) begin
                line_valid_q[reset_index] <= 1'b0;
                line_addr_q[reset_index] <= {`RV64_XLEN{1'b0}};
                line_data_q[reset_index] <=
                    {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
                line_access_fault_q[reset_index] <= 1'b0;
                line_page_fault_q[reset_index] <= 1'b0;
                pending_valid_q[reset_index] <= 1'b0;
                pending_addr_q[reset_index] <= {`RV64_XLEN{1'b0}};
            end
        end else if (restart_i) begin
            active_q <= 1'b1;
            consume_pc_q <= restart_pc_i;
            next_req_addr_q <= {
                restart_pc_i[`RV64_XLEN-1:LINE_BYTE_BITS],
                {LINE_BYTE_BITS{1'b0}}
            };
            for (reset_index = 0; reset_index < LINE_DEPTH;
                 reset_index = reset_index + 1) begin
                if (invalidate_i)
                    line_valid_q[reset_index] <= 1'b0;
                pending_valid_q[reset_index] <= 1'b0;
            end
        end else if (flush_i) begin
            active_q <= 1'b0;
            for (reset_index = 0; reset_index < LINE_DEPTH;
                 reset_index = reset_index + 1)
                pending_valid_q[reset_index] <= 1'b0;
        end else begin
            if (req_fire) begin
                pending_valid_q[prefetch_slot] <= 1'b1;
                pending_addr_q[prefetch_slot] <= next_req_addr_q;
            end
            if (prefetch_advance)
                next_req_addr_q <= next_req_addr_q + LINE_BYTES;
            if (resp_valid_i && resp_match) begin
                pending_valid_q[resp_slot] <= 1'b0;
                line_valid_q[resp_slot] <= 1'b1;
                line_addr_q[resp_slot] <= {
                    resp_addr_i[`RV64_XLEN-1:LINE_BYTE_BITS],
                    {LINE_BYTE_BITS{1'b0}}
                };
                line_data_q[resp_slot] <= resp_data_i;
                line_access_fault_q[resp_slot] <=
                    resp_access_fault_i;
                line_page_fault_q[resp_slot] <=
                    resp_page_fault_i;
            end
            if (decode_count != 0)
                consume_pc_q <= next_consume_pc;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((LINE_DEPTH < 2) ||
            ((1 << LINE_INDEX_WIDTH) != LINE_DEPTH))
            $fatal(1, "fetch_3w LINE_DEPTH must be a power of two >= 2");
    end

    always @(posedge clk) begin
        if (rst_n && resp_valid_i && !restart_i && !flush_i && !resp_match)
            $fatal(1, "fetch_3w response does not match a pending direct-mapped line");
        if (rst_n && (decode_valid_o != 3'b000) &&
            (decode_valid_o != 3'b001) &&
            (decode_valid_o != 3'b011) &&
            (decode_valid_o != 3'b111))
            $fatal(1, "fetch_3w decode output is not a contiguous prefix");
    end
`endif

endmodule
