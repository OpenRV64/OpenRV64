// FPGA RV64M implementation.  Multiplication is deliberately expressed as a
// single '*' operation so FPGA synthesis can map it to DSP blocks.  Division
// retains the latency-heavy iterative implementation used by rv64-m.v.

`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"

module openrv64_exec_rv64m #(
    // Retained for source compatibility with the generic implementation.
    // FPGA multiplication has one worker cycle regardless of this value.
    parameter MUL_BITS_PER_CYCLE = 4,
    parameter DIV_BITS_PER_CYCLE = 2
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          flush_i,

    input  wire                          valid_i,
    output wire                          ready_o,
    output wire                          busy_o,
    input  wire [`RV64_ALU_OP_WIDTH-1:0] op_sel_i,
    input  wire                          word_op_i,
    input  wire [`RV64_XLEN-1:0]         src1_i,
    input  wire [`RV64_XLEN-1:0]         src2_i,

    output wire                          result_valid_o,
    input  wire                          result_ready_i,
    output wire                          illegal_o,
    output wire [`RV64_XLEN-1:0]         result_o
);

    localparam WORK_KIND_MUL = 1'b0;
    localparam WORK_KIND_DIV = 1'b1;
    localparam integer DIV_CHUNK_WIDTH = (DIV_BITS_PER_CYCLE < 1) ? 1 :
                                         (DIV_BITS_PER_CYCLE > 16) ? 16 :
                                         DIV_BITS_PER_CYCLE;
    localparam [7:0] DIV_CHUNK_WIDTH_VALUE = DIV_CHUNK_WIDTH;

    reg active_q;
    reg work_kind_q;
    reg word_q;
    reg [`RV64_ALU_OP_WIDTH-1:0] op_q;

    // The operands are registered before the multiplier.  The following '*'
    // is the sole multiplication operator in the implementation and is the
    // intended DSP inference point.
    reg [63:0] mul_src1_q;
    reg [63:0] mul_src2_q;
    wire [127:0] mul_product =
        {64'h0000_0000_0000_0000, mul_src1_q} *
        {64'h0000_0000_0000_0000, mul_src2_q};

    // A single unsigned 64x64 product implements every RV64 multiply form.
    // Signed high halves differ only by the two's-complement corrections.
    wire [63:0] mul_high_ss =
        mul_product[127:64] -
        (mul_src1_q[63] ? mul_src2_q : 64'd0) -
        (mul_src2_q[63] ? mul_src1_q : 64'd0);
    wire [63:0] mul_high_su =
        mul_product[127:64] -
        (mul_src1_q[63] ? mul_src2_q : 64'd0);

    reg [7:0] div_bits_left_q;
    reg [63:0] div_dividend_q;
    reg [63:0] div_divisor_q;
    reg [64:0] div_remainder_q;
    reg [63:0] div_quotient_q;
    reg div_neg_quot_q;
    reg div_neg_rem_q;
    reg div_finalize_q;

    reg result_valid_q;
    reg illegal_q;
    reg [`RV64_XLEN-1:0] result_q;

    wire start = valid_i && ready_o;
    wire start_mul_op = (op_sel_i == `RV64_ALU_OP_MUL) ||
                        (op_sel_i == `RV64_ALU_OP_MULH) ||
                        (op_sel_i == `RV64_ALU_OP_MULHSU) ||
                        (op_sel_i == `RV64_ALU_OP_MULHU);
    wire start_div_op = (op_sel_i == `RV64_ALU_OP_DIV) ||
                        (op_sel_i == `RV64_ALU_OP_DIVU) ||
                        (op_sel_i == `RV64_ALU_OP_REM) ||
                        (op_sel_i == `RV64_ALU_OP_REMU);
    wire start_signed_div_op = (op_sel_i == `RV64_ALU_OP_DIV) ||
                               (op_sel_i == `RV64_ALU_OP_REM);
    wire start_invalid_mul_word = word_op_i &&
                                  ((op_sel_i == `RV64_ALU_OP_MULH) ||
                                   (op_sel_i == `RV64_ALU_OP_MULHSU) ||
                                   (op_sel_i == `RV64_ALU_OP_MULHU));
    wire start_mul_valid = start_mul_op && !start_invalid_mul_word;
    wire start_div_valid = start_div_op;
    wire start_divisor_zero = word_op_i ?
                              (src2_i[31:0] == 32'h0000_0000) :
                              (src2_i == {`RV64_XLEN{1'b0}});
    wire start_div_overflow = start_signed_div_op &&
                              !start_divisor_zero &&
                              (word_op_i ?
                               ((src1_i[31:0] == 32'h8000_0000) &&
                                (src2_i[31:0] == 32'hffff_ffff)) :
                               ((src1_i == 64'h8000_0000_0000_0000) &&
                                (src2_i == 64'hffff_ffff_ffff_ffff)));

    wire [200:0] div_step_value = div_stage_step(
        div_remainder_q,
        div_quotient_q,
        div_dividend_q,
        div_divisor_q,
        div_bits_left_q
    );
    wire [64:0] div_remainder_next = div_step_value[200:136];
    wire [63:0] div_quotient_next = div_step_value[135:72];
    wire [63:0] div_dividend_next = div_step_value[71:8];
    wire [7:0] div_bits_left_next = div_step_value[7:0];

    assign ready_o = !active_q && (!result_valid_q || result_ready_i);
    assign busy_o = active_q || result_valid_q;
    assign result_valid_o = result_valid_q;
    assign illegal_o = result_valid_q && illegal_q;
    assign result_o = result_valid_q ? result_q : {`RV64_XLEN{1'b0}};

    function [`RV64_XLEN-1:0] sext_word;
        input [31:0] value;
        begin
            sext_word = {{32{value[31]}}, value};
        end
    endfunction

    function [63:0] abs64;
        input [63:0] value;
        begin
            abs64 = value[63] ? (~value + 64'd1) : value;
        end
    endfunction

    function [31:0] abs32;
        input [31:0] value;
        begin
            abs32 = value[31] ? (~value + 32'd1) : value;
        end
    endfunction

    function [200:0] div_stage_step;
        input [64:0] remainder;
        input [63:0] quotient;
        input [63:0] dividend;
        input [63:0] divisor;
        input [7:0] bits_left;
        integer bit_idx;
        reg [7:0] step_bits;
        reg [64:0] remainder_next;
        reg [63:0] quotient_next;
        reg [63:0] dividend_next;
        reg [7:0] bits_left_next;
        reg [64:0] divisor_ext;
        begin
            step_bits = (bits_left < DIV_CHUNK_WIDTH_VALUE) ?
                        bits_left : DIV_CHUNK_WIDTH_VALUE;
            remainder_next = remainder;
            quotient_next = quotient;
            dividend_next = dividend;
            bits_left_next = bits_left;
            divisor_ext = {1'b0, divisor};

            for (bit_idx = 0; bit_idx < DIV_CHUNK_WIDTH;
                 bit_idx = bit_idx + 1) begin
                if (bit_idx < step_bits) begin
                    remainder_next = {
                        remainder_next[63:0], dividend_next[63]
                    };
                    dividend_next = {dividend_next[62:0], 1'b0};

                    if (remainder_next >= divisor_ext) begin
                        remainder_next = remainder_next - divisor_ext;
                        quotient_next = {quotient_next[62:0], 1'b1};
                    end else begin
                        quotient_next = {quotient_next[62:0], 1'b0};
                    end
                end
            end

            bits_left_next = (bits_left > DIV_CHUNK_WIDTH_VALUE) ?
                             (bits_left - DIV_CHUNK_WIDTH_VALUE) : 8'd0;
            div_stage_step = {
                remainder_next,
                quotient_next,
                dividend_next,
                bits_left_next
            };
        end
    endfunction

    function [`RV64_XLEN-1:0] finish_mul_result;
        input [127:0] product;
        input [63:0] high_ss;
        input [63:0] high_su;
        input [`RV64_ALU_OP_WIDTH-1:0] op_sel;
        input word_op;
        begin
            if (word_op) begin
                finish_mul_result = sext_word(product[31:0]);
            end else begin
                case (op_sel)
                    `RV64_ALU_OP_MULH:
                        finish_mul_result = high_ss;
                    `RV64_ALU_OP_MULHSU:
                        finish_mul_result = high_su;
                    `RV64_ALU_OP_MULHU:
                        finish_mul_result = product[127:64];
                    default:
                        finish_mul_result = product[63:0];
                endcase
            end
        end
    endfunction

    function [`RV64_XLEN-1:0] finish_div_result;
        input [`RV64_ALU_OP_WIDTH-1:0] op_sel;
        input word_op;
        input [63:0] quotient;
        input [63:0] remainder;
        input neg_quot;
        input neg_rem;
        reg [63:0] quotient_signed;
        reg [63:0] remainder_signed;
        reg [31:0] quotient_word;
        reg [31:0] remainder_word;
        begin
            quotient_signed = neg_quot ? (~quotient + 64'd1) : quotient;
            remainder_signed = neg_rem ? (~remainder + 64'd1) : remainder;
            quotient_word = neg_quot ?
                            (~quotient[31:0] + 32'd1) : quotient[31:0];
            remainder_word = neg_rem ?
                             (~remainder[31:0] + 32'd1) : remainder[31:0];

            case (op_sel)
                `RV64_ALU_OP_DIV,
                `RV64_ALU_OP_DIVU:
                    finish_div_result = word_op ?
                                        sext_word(quotient_word) :
                                        quotient_signed;
                `RV64_ALU_OP_REM,
                `RV64_ALU_OP_REMU:
                    finish_div_result = word_op ?
                                        sext_word(remainder_word) :
                                        remainder_signed;
                default:
                    finish_div_result = {`RV64_XLEN{1'b0}};
            endcase
        end
    endfunction

    function [`RV64_XLEN-1:0] div_zero_result;
        input [`RV64_ALU_OP_WIDTH-1:0] op_sel;
        input word_op;
        input [`RV64_XLEN-1:0] dividend;
        begin
            case (op_sel)
                `RV64_ALU_OP_DIV,
                `RV64_ALU_OP_DIVU:
                    div_zero_result = word_op ?
                                      sext_word(32'hffff_ffff) :
                                      {`RV64_XLEN{1'b1}};
                `RV64_ALU_OP_REM,
                `RV64_ALU_OP_REMU:
                    div_zero_result = word_op ?
                                      sext_word(dividend[31:0]) : dividend;
                default:
                    div_zero_result = {`RV64_XLEN{1'b0}};
            endcase
        end
    endfunction

    function [`RV64_XLEN-1:0] div_overflow_result;
        input [`RV64_ALU_OP_WIDTH-1:0] op_sel;
        input word_op;
        begin
            case (op_sel)
                `RV64_ALU_OP_DIV:
                    div_overflow_result = word_op ?
                                          sext_word(32'h8000_0000) :
                                          64'h8000_0000_0000_0000;
                `RV64_ALU_OP_REM:
                    div_overflow_result = {`RV64_XLEN{1'b0}};
                default:
                    div_overflow_result = {`RV64_XLEN{1'b0}};
            endcase
        end
    endfunction

    function [63:0] div_start_dividend;
        input signed_op;
        input word_op;
        input [`RV64_XLEN-1:0] value;
        begin
            if (word_op) begin
                div_start_dividend = {
                    (signed_op ? abs32(value[31:0]) : value[31:0]),
                    32'h0000_0000
                };
            end else begin
                div_start_dividend = signed_op ? abs64(value) : value;
            end
        end
    endfunction

    function [63:0] div_start_divisor;
        input signed_op;
        input word_op;
        input [`RV64_XLEN-1:0] value;
        begin
            if (word_op) begin
                div_start_divisor = {
                    32'h0000_0000,
                    (signed_op ? abs32(value[31:0]) : value[31:0])
                };
            end else begin
                div_start_divisor = signed_op ? abs64(value) : value;
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_q <= 1'b0;
            work_kind_q <= WORK_KIND_MUL;
            word_q <= 1'b0;
            op_q <= `RV64_ALU_OP_INVALID;
            mul_src1_q <= 64'd0;
            mul_src2_q <= 64'd0;
            div_bits_left_q <= 8'd0;
            div_dividend_q <= 64'd0;
            div_divisor_q <= 64'd0;
            div_remainder_q <= 65'd0;
            div_quotient_q <= 64'd0;
            div_neg_quot_q <= 1'b0;
            div_neg_rem_q <= 1'b0;
            div_finalize_q <= 1'b0;
            result_valid_q <= 1'b0;
            illegal_q <= 1'b0;
            result_q <= {`RV64_XLEN{1'b0}};
        end else if (flush_i) begin
            active_q <= 1'b0;
            work_kind_q <= WORK_KIND_MUL;
            word_q <= 1'b0;
            op_q <= `RV64_ALU_OP_INVALID;
            mul_src1_q <= 64'd0;
            mul_src2_q <= 64'd0;
            div_bits_left_q <= 8'd0;
            div_dividend_q <= 64'd0;
            div_divisor_q <= 64'd0;
            div_remainder_q <= 65'd0;
            div_quotient_q <= 64'd0;
            div_neg_quot_q <= 1'b0;
            div_neg_rem_q <= 1'b0;
            div_finalize_q <= 1'b0;
            result_valid_q <= 1'b0;
            illegal_q <= 1'b0;
            result_q <= {`RV64_XLEN{1'b0}};
        end else begin
            if (result_valid_q && result_ready_i) begin
                result_valid_q <= 1'b0;
                illegal_q <= 1'b0;
                result_q <= {`RV64_XLEN{1'b0}};
            end

            if (active_q && (work_kind_q == WORK_KIND_MUL)) begin
                active_q <= 1'b0;
                result_valid_q <= 1'b1;
                illegal_q <= 1'b0;
                result_q <= finish_mul_result(
                    mul_product,
                    mul_high_ss,
                    mul_high_su,
                    op_q,
                    word_q
                );
            end else if (active_q && (work_kind_q == WORK_KIND_DIV)) begin
                if (div_finalize_q) begin
                    active_q <= 1'b0;
                    div_finalize_q <= 1'b0;
                    result_valid_q <= 1'b1;
                    illegal_q <= 1'b0;
                    result_q <= finish_div_result(
                        op_q,
                        word_q,
                        div_quotient_q,
                        div_remainder_q[63:0],
                        div_neg_quot_q,
                        div_neg_rem_q
                    );
                end else begin
                    div_remainder_q <= div_remainder_next;
                    div_quotient_q <= div_quotient_next;
                    div_dividend_q <= div_dividend_next;
                    div_bits_left_q <= div_bits_left_next;
                    if (div_bits_left_next == 8'd0)
                        div_finalize_q <= 1'b1;
                end
            end else if (start) begin
                word_q <= word_op_i;
                op_q <= op_sel_i;

                if (start_mul_valid) begin
                    active_q <= 1'b1;
                    work_kind_q <= WORK_KIND_MUL;
                    mul_src1_q <= src1_i;
                    mul_src2_q <= src2_i;
                end else if (start_div_valid &&
                             !start_divisor_zero &&
                             !start_div_overflow) begin
                    active_q <= 1'b1;
                    work_kind_q <= WORK_KIND_DIV;
                    div_bits_left_q <= word_op_i ? 8'd32 : 8'd64;
                    div_dividend_q <= div_start_dividend(
                        start_signed_div_op,
                        word_op_i,
                        src1_i
                    );
                    div_divisor_q <= div_start_divisor(
                        start_signed_div_op,
                        word_op_i,
                        src2_i
                    );
                    div_remainder_q <= 65'd0;
                    div_quotient_q <= 64'd0;
                    div_neg_quot_q <= start_signed_div_op &&
                                      (word_op_i ?
                                       (src1_i[31] ^ src2_i[31]) :
                                       (src1_i[63] ^ src2_i[63]));
                    div_neg_rem_q <= start_signed_div_op &&
                                     (word_op_i ? src1_i[31] : src1_i[63]);
                    div_finalize_q <= 1'b0;
                end else begin
                    active_q <= 1'b0;
                    div_finalize_q <= 1'b0;
                    result_valid_q <= 1'b1;
                    illegal_q <= !start_div_valid;
                    result_q <= start_divisor_zero ?
                                div_zero_result(op_sel_i, word_op_i, src1_i) :
                                start_div_overflow ?
                                div_overflow_result(op_sel_i, word_op_i) :
                                {`RV64_XLEN{1'b0}};
                end
            end
        end
    end

endmodule
