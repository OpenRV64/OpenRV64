`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"

// Zbb sequencer for the 3P EX0 long-operation slot.  Shifts, Boolean
// operations, and comparisons are issued as micro-operations to EX0's existing
// RV64I ALU.  This module therefore adds control/state and small count/byte
// helpers, not a second barrel shifter or comparator.  RV64M is independent.
module openrv64_exec_ext_zbb (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire                         valid_i,
    output wire                         ready_o,
    output wire                         busy_o,
    input  wire [`RV64_ALU_OP_WIDTH-1:0] op_sel_i,
    input  wire                         word_op_i,
    input  wire [`RV64_XLEN-1:0]        src1_i,
    input  wire [`RV64_XLEN-1:0]        src2_i,

    // Combinational micro-operation port to the existing EX0 RV64I ALU.
    output reg                          alu_request_o,
    output reg  [`RV64_ALU_OP_WIDTH-1:0] alu_op_o,
    output reg                          alu_word_o,
    output reg  [`RV64_XLEN-1:0]        alu_src1_o,
    output reg  [`RV64_XLEN-1:0]        alu_src2_o,
    input  wire                         alu_valid_i,
    input  wire [`RV64_XLEN-1:0]        alu_result_i,

    output wire                         result_valid_o,
    input  wire                         result_ready_i,
    output wire                         illegal_o,
    output wire [`RV64_XLEN-1:0]        result_o
);

    reg active_q;
    reg result_valid_q;
    reg illegal_q;
    reg [`RV64_ALU_OP_WIDTH-1:0] op_q;
    reg word_q;
    reg [2:0] step_q;
    reg [63:0] work_q;
    reg [63:0] aux_q;
    reg [5:0] amount_q;
    reg [6:0] count_q;

    wire start = valid_i && ready_o;

    function automatic operation_valid;
        input [`RV64_ALU_OP_WIDTH-1:0] op;
        input word_op;
        begin
            case (op)
                `RV64_ALU_OP_ZBB_ANDN,
                `RV64_ALU_OP_ZBB_ORN,
                `RV64_ALU_OP_ZBB_XNOR,
                `RV64_ALU_OP_ZBB_MIN,
                `RV64_ALU_OP_ZBB_MINU,
                `RV64_ALU_OP_ZBB_MAX,
                `RV64_ALU_OP_ZBB_MAXU,
                `RV64_ALU_OP_ZBB_SEXT_B,
                `RV64_ALU_OP_ZBB_SEXT_H,
                `RV64_ALU_OP_ZBB_ORC_B,
                `RV64_ALU_OP_ZBB_REV8:
                    operation_valid = !word_op;
                `RV64_ALU_OP_ZBB_ZEXT_H:
                    operation_valid = word_op;
                `RV64_ALU_OP_ZBB_ROL,
                `RV64_ALU_OP_ZBB_ROR,
                `RV64_ALU_OP_ZBB_CLZ,
                `RV64_ALU_OP_ZBB_CTZ,
                `RV64_ALU_OP_ZBB_CPOP:
                    operation_valid = 1'b1;
                default:
                    operation_valid = 1'b0;
            endcase
        end
    endfunction

    function automatic operation_direct;
        input [`RV64_ALU_OP_WIDTH-1:0] op;
        begin
            operation_direct =
                (op == `RV64_ALU_OP_ZBB_SEXT_B) ||
                (op == `RV64_ALU_OP_ZBB_SEXT_H) ||
                (op == `RV64_ALU_OP_ZBB_ZEXT_H) ||
                (op == `RV64_ALU_OP_ZBB_ORC_B) ||
                (op == `RV64_ALU_OP_ZBB_REV8);
        end
    endfunction

    function automatic [7:0] orc_byte;
        input [7:0] value;
        begin
            orc_byte = (|value) ? 8'hff : 8'h00;
        end
    endfunction

    function automatic [63:0] direct_result;
        input [`RV64_ALU_OP_WIDTH-1:0] op;
        input [63:0] value;
        begin
            case (op)
                `RV64_ALU_OP_ZBB_SEXT_B:
                    direct_result = {{56{value[7]}}, value[7:0]};
                `RV64_ALU_OP_ZBB_SEXT_H:
                    direct_result = {{48{value[15]}}, value[15:0]};
                `RV64_ALU_OP_ZBB_ZEXT_H:
                    direct_result = {48'd0, value[15:0]};
                `RV64_ALU_OP_ZBB_ORC_B:
                    direct_result = {
                        orc_byte(value[63:56]), orc_byte(value[55:48]),
                        orc_byte(value[47:40]), orc_byte(value[39:32]),
                        orc_byte(value[31:24]), orc_byte(value[23:16]),
                        orc_byte(value[15:8]),  orc_byte(value[7:0])
                    };
                `RV64_ALU_OP_ZBB_REV8:
                    direct_result = {
                        value[7:0],   value[15:8],  value[23:16],
                        value[31:24], value[39:32], value[47:40],
                        value[55:48], value[63:56]
                    };
                default:
                    direct_result = 64'd0;
            endcase
        end
    endfunction

    wire start_operation_valid = operation_valid(op_sel_i, word_op_i);
    wire start_operation_direct = operation_direct(op_sel_i);
    wire [63:0] start_direct_result = direct_result(op_sel_i, src1_i);

    // Balanced 16-bit population count.  It is reused four times over four
    // cycles instead of instantiating a 64-bit population-count tree.
    function automatic [4:0] popcount16;
        input [15:0] value;
        reg [1:0] p0, p1, p2, p3, p4, p5, p6, p7;
        reg [2:0] q0, q1, q2, q3;
        reg [3:0] r0, r1;
        begin
            p0 = value[0]  + value[1];
            p1 = value[2]  + value[3];
            p2 = value[4]  + value[5];
            p3 = value[6]  + value[7];
            p4 = value[8]  + value[9];
            p5 = value[10] + value[11];
            p6 = value[12] + value[13];
            p7 = value[14] + value[15];
            q0 = p0 + p1;
            q1 = p2 + p3;
            q2 = p4 + p5;
            q3 = p6 + p7;
            r0 = q0 + q1;
            r1 = q2 + q3;
            popcount16 = r0 + r1;
        end
    endfunction

    wire logic_op = (op_q == `RV64_ALU_OP_ZBB_ANDN) ||
                    (op_q == `RV64_ALU_OP_ZBB_ORN) ||
                    (op_q == `RV64_ALU_OP_ZBB_XNOR);
    wire minmax_op = (op_q == `RV64_ALU_OP_ZBB_MIN) ||
                     (op_q == `RV64_ALU_OP_ZBB_MINU) ||
                     (op_q == `RV64_ALU_OP_ZBB_MAX) ||
                     (op_q == `RV64_ALU_OP_ZBB_MAXU);
    wire rotate_op = (op_q == `RV64_ALU_OP_ZBB_ROL) ||
                     (op_q == `RV64_ALU_OP_ZBB_ROR);
    wire scan_op = (op_q == `RV64_ALU_OP_ZBB_CLZ) ||
                   (op_q == `RV64_ALU_OP_ZBB_CTZ);
    wire pop_op = op_q == `RV64_ALU_OP_ZBB_CPOP;

    reg [5:0] scan_shift;
    reg scan_zero;
    always @* begin
        case (step_q)
            3'd0: scan_shift = 6'd32;
            3'd1: scan_shift = 6'd16;
            3'd2: scan_shift = 6'd8;
            3'd3: scan_shift = 6'd4;
            3'd4: scan_shift = 6'd2;
            default: scan_shift = 6'd1;
        endcase

        if (op_q == `RV64_ALU_OP_ZBB_CLZ) begin
            case (step_q)
                3'd0: scan_zero = !(|work_q[63:32]);
                3'd1: scan_zero = !(|work_q[63:48]);
                3'd2: scan_zero = !(|work_q[63:56]);
                3'd3: scan_zero = !(|work_q[63:60]);
                3'd4: scan_zero = !(|work_q[63:62]);
                default: scan_zero = !work_q[63];
            endcase
        end else begin
            case (step_q)
                3'd0: scan_zero = !(|work_q[31:0]);
                3'd1: scan_zero = !(|work_q[15:0]);
                3'd2: scan_zero = !(|work_q[7:0]);
                3'd3: scan_zero = !(|work_q[3:0]);
                3'd4: scan_zero = !(|work_q[1:0]);
                default: scan_zero = !work_q[0];
            endcase
        end
    end

    wire [6:0] scan_count_next = count_q +
        (scan_zero ? {1'b0, scan_shift} : 7'd0);
    wire [6:0] scan_result = scan_count_next +
        (((step_q == 3'd5) && !(|work_q)) ? 7'd1 : 7'd0);
    wire [6:0] pop_count_next = count_q +
        {2'd0, popcount16(work_q[15:0])};
    wire pop_last = word_q ? (step_q == 3'd1) : (step_q == 3'd3);
    wire [5:0] inverse_amount = word_q ?
        {1'b0, (~amount_q[4:0] + 5'd1)} :
        (~amount_q + 6'd1);

    // Micro-operations consume only resources already present in EX0.
    always @* begin
        alu_request_o = 1'b0;
        alu_op_o = `RV64_ALU_OP_INVALID;
        alu_word_o = 1'b0;
        alu_src1_o = work_q;
        alu_src2_o = aux_q;

        if (active_q && logic_op) begin
            alu_request_o = 1'b1;
            alu_op_o = (op_q == `RV64_ALU_OP_ZBB_ANDN) ?
                       `RV64_ALU_OP_AND :
                       ((op_q == `RV64_ALU_OP_ZBB_ORN) ?
                        `RV64_ALU_OP_OR : `RV64_ALU_OP_XOR);
        end else if (active_q && minmax_op) begin
            alu_request_o = 1'b1;
            alu_op_o = ((op_q == `RV64_ALU_OP_ZBB_MIN) ||
                        (op_q == `RV64_ALU_OP_ZBB_MAX)) ?
                       `RV64_ALU_OP_SLT : `RV64_ALU_OP_SLTU;
        end else if (active_q && rotate_op) begin
            alu_request_o = 1'b1;
            if (step_q == 3'd0) begin
                alu_op_o = (op_q == `RV64_ALU_OP_ZBB_ROR) ?
                           `RV64_ALU_OP_SRL : `RV64_ALU_OP_SLL;
                alu_word_o = word_q;
                alu_src2_o = {58'd0, amount_q};
            end else if (step_q == 3'd1) begin
                alu_op_o = (op_q == `RV64_ALU_OP_ZBB_ROR) ?
                           `RV64_ALU_OP_SLL : `RV64_ALU_OP_SRL;
                alu_word_o = word_q;
                alu_src2_o = {58'd0, inverse_amount};
            end else begin
                alu_op_o = `RV64_ALU_OP_OR;
                alu_src1_o = aux_q;
                alu_src2_o = work_q;
            end
        end else if (active_q && scan_op) begin
            alu_request_o = 1'b1;
            alu_op_o = (op_q == `RV64_ALU_OP_ZBB_CLZ) ?
                       `RV64_ALU_OP_SLL : `RV64_ALU_OP_SRL;
            alu_src2_o = {58'd0, scan_shift};
        end
    end

    assign ready_o = !active_q && (!result_valid_q || result_ready_i);
    assign busy_o = active_q || result_valid_q;
    assign result_valid_o = result_valid_q;
    assign illegal_o = result_valid_q && illegal_q;
    assign result_o = result_valid_q ? work_q : 64'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_q <= 1'b0;
            result_valid_q <= 1'b0;
            illegal_q <= 1'b0;
            op_q <= `RV64_ALU_OP_INVALID;
            word_q <= 1'b0;
            step_q <= 3'd0;
            work_q <= 64'd0;
            aux_q <= 64'd0;
            amount_q <= 6'd0;
            count_q <= 7'd0;
        end else if (flush_i) begin
            active_q <= 1'b0;
            result_valid_q <= 1'b0;
            illegal_q <= 1'b0;
            op_q <= `RV64_ALU_OP_INVALID;
            word_q <= 1'b0;
            step_q <= 3'd0;
            work_q <= 64'd0;
            aux_q <= 64'd0;
            amount_q <= 6'd0;
            count_q <= 7'd0;
        end else begin
            if (result_valid_q && result_ready_i) begin
                result_valid_q <= 1'b0;
                illegal_q <= 1'b0;
            end

            if (active_q) begin
                if (alu_request_o && !alu_valid_i) begin
                    active_q <= 1'b0;
                    result_valid_q <= 1'b1;
                    illegal_q <= 1'b1;
                    work_q <= 64'd0;
                end else if (logic_op) begin
                    active_q <= 1'b0;
                    result_valid_q <= 1'b1;
                    work_q <= (op_q == `RV64_ALU_OP_ZBB_XNOR) ?
                              ~alu_result_i : alu_result_i;
                end else if (minmax_op) begin
                    active_q <= 1'b0;
                    result_valid_q <= 1'b1;
                    if ((op_q == `RV64_ALU_OP_ZBB_MIN) ||
                        (op_q == `RV64_ALU_OP_ZBB_MINU))
                        work_q <= alu_result_i[0] ? work_q : aux_q;
                    else
                        work_q <= alu_result_i[0] ? aux_q : work_q;
                end else if (rotate_op) begin
                    if (step_q == 3'd0) begin
                        aux_q <= alu_result_i;
                        step_q <= 3'd1;
                    end else if (step_q == 3'd1) begin
                        work_q <= alu_result_i;
                        step_q <= 3'd2;
                    end else begin
                        active_q <= 1'b0;
                        result_valid_q <= 1'b1;
                        work_q <= word_q ?
                            {{32{alu_result_i[31]}}, alu_result_i[31:0]} :
                            alu_result_i;
                    end
                end else if (scan_op) begin
                    count_q <= scan_count_next;
                    if (scan_zero)
                        work_q <= alu_result_i;
                    if (step_q == 3'd5) begin
                        active_q <= 1'b0;
                        result_valid_q <= 1'b1;
                        work_q <= {57'd0, scan_result};
                    end else begin
                        step_q <= step_q + 1'b1;
                    end
                end else if (pop_op) begin
                    count_q <= pop_count_next;
                    work_q <= work_q >> 16;
                    if (pop_last) begin
                        active_q <= 1'b0;
                        result_valid_q <= 1'b1;
                        work_q <= {57'd0, pop_count_next};
                    end else begin
                        step_q <= step_q + 1'b1;
                    end
                end else begin
                    active_q <= 1'b0;
                    result_valid_q <= 1'b1;
                    illegal_q <= 1'b1;
                    work_q <= 64'd0;
                end
            end else if (start) begin
                op_q <= op_sel_i;
                word_q <= word_op_i;
                step_q <= 3'd0;
                amount_q <= word_op_i ? {1'b0, src2_i[4:0]} : src2_i[5:0];
                count_q <= 7'd0;
                illegal_q <= 1'b0;
                aux_q <= src2_i;

                if (!start_operation_valid) begin
                    active_q <= 1'b0;
                    result_valid_q <= 1'b1;
                    illegal_q <= 1'b1;
                    work_q <= 64'd0;
                    aux_q <= 64'd0;
                end else if (start_operation_direct) begin
                    active_q <= 1'b0;
                    result_valid_q <= 1'b1;
                    work_q <= start_direct_result;
                    aux_q <= 64'd0;
                end else begin
                    active_q <= 1'b1;
                    result_valid_q <= 1'b0;
                    if ((op_sel_i == `RV64_ALU_OP_ZBB_ANDN) ||
                        (op_sel_i == `RV64_ALU_OP_ZBB_ORN))
                        aux_q <= ~src2_i;

                    if ((op_sel_i == `RV64_ALU_OP_ZBB_CLZ) && word_op_i)
                        work_q <= {src1_i[31:0], 32'hffff_ffff};
                    else if ((op_sel_i == `RV64_ALU_OP_ZBB_CTZ) && word_op_i)
                        work_q <= {32'hffff_ffff, src1_i[31:0]};
                    else if ((op_sel_i == `RV64_ALU_OP_ZBB_CPOP) && word_op_i)
                        work_q <= {32'd0, src1_i[31:0]};
                    else
                        work_q <= src1_i;
                end
            end
        end
    end

endmodule
