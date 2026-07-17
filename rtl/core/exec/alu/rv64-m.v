`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"

module openrv64_exec_rv64m #(
    parameter MUL_BITS_PER_CYCLE = 11,
    parameter DIV_BITS_PER_CYCLE = 11
) (
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

    output wire                         result_valid_o,
    input  wire                         result_ready_i,
    output wire                         illegal_o,
    output wire [`RV64_XLEN-1:0]        result_o
);

    localparam PIPE_KIND_RESULT = 2'd0;
    localparam PIPE_KIND_MUL    = 2'd1;
    localparam PIPE_KIND_DIV    = 2'd2;
    localparam integer MUL_CHUNK_WIDTH = (MUL_BITS_PER_CYCLE < 1) ? 1 :
                                         (MUL_BITS_PER_CYCLE > 16) ? 16 :
                                         MUL_BITS_PER_CYCLE;
    localparam integer DIV_CHUNK_WIDTH = (DIV_BITS_PER_CYCLE < 1) ? 1 :
                                         (DIV_BITS_PER_CYCLE > 16) ? 16 :
                                         DIV_BITS_PER_CYCLE;
    localparam integer MUL_PIPE_STAGES = (64 + MUL_CHUNK_WIDTH - 1) /
                                         MUL_CHUNK_WIDTH;
    localparam integer DIV_PIPE_STAGES = (64 + DIV_CHUNK_WIDTH - 1) /
                                         DIV_CHUNK_WIDTH;
    localparam integer M_PIPE_STAGES = (MUL_PIPE_STAGES > DIV_PIPE_STAGES) ?
                                       MUL_PIPE_STAGES :
                                       DIV_PIPE_STAGES;
    localparam integer PIPE_LAST = M_PIPE_STAGES - 1;
    localparam [7:0] MUL_CHUNK_WIDTH_VALUE = MUL_CHUNK_WIDTH;
    localparam [7:0] DIV_CHUNK_WIDTH_VALUE = DIV_CHUNK_WIDTH;

    reg [M_PIPE_STAGES-1:0] pipe_active_q;
    reg [1:0] pipe_kind_q [0:PIPE_LAST];
    reg pipe_illegal_q [0:PIPE_LAST];
    reg pipe_word_q [0:PIPE_LAST];
    reg [`RV64_ALU_OP_WIDTH-1:0] pipe_op_q [0:PIPE_LAST];
    reg [`RV64_XLEN-1:0] pipe_result_q [0:PIPE_LAST];

    reg [7:0] pipe_mul_bits_left_q [0:PIPE_LAST];
    reg [127:0] pipe_mul_acc_q [0:PIPE_LAST];
    reg [127:0] pipe_mul_multiplicand_q [0:PIPE_LAST];
    reg [63:0] pipe_mul_multiplier_q [0:PIPE_LAST];
    reg pipe_mul_negate_q [0:PIPE_LAST];

    reg [7:0] pipe_div_bits_left_q [0:PIPE_LAST];
    reg [63:0] pipe_div_dividend_q [0:PIPE_LAST];
    reg [63:0] pipe_div_divisor_q [0:PIPE_LAST];
    reg [64:0] pipe_div_remainder_q [0:PIPE_LAST];
    reg [63:0] pipe_div_quotient_q [0:PIPE_LAST];
    reg pipe_div_neg_quot_q [0:PIPE_LAST];
    reg pipe_div_neg_rem_q [0:PIPE_LAST];

    reg result_valid_q;
    reg illegal_q;
    reg [`RV64_XLEN-1:0] result_q;

    integer stage_idx;
    reg [327:0] mul_step_value;
    reg [200:0] div_step_value;

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

    reg [127:0] start_mul_multiplicand;
    reg [63:0] start_mul_multiplier;
    reg start_mul_negate;
    wire [327:0] start_mul_step_value = mul_stage_step(
        128'h0000_0000_0000_0000_0000_0000_0000_0000,
        start_mul_multiplicand,
        start_mul_multiplier,
        word_op_i ? 8'd32 : 8'd64
    );
    wire [200:0] start_div_step_value = div_stage_step(
        65'h0_0000_0000_0000_0000,
        64'h0000_0000_0000_0000,
        div_start_dividend(start_signed_div_op, word_op_i, src1_i),
        div_start_divisor(start_signed_div_op, word_op_i, src2_i),
        word_op_i ? 8'd32 : 8'd64
    );

    wire [1:0] final_pipe_kind = pipe_kind_q[PIPE_LAST];
    wire final_pipe_illegal = pipe_illegal_q[PIPE_LAST];
    wire final_pipe_word = pipe_word_q[PIPE_LAST];
    wire [`RV64_ALU_OP_WIDTH-1:0] final_pipe_op = pipe_op_q[PIPE_LAST];
    wire [`RV64_XLEN-1:0] final_pipe_result = pipe_result_q[PIPE_LAST];
    wire [127:0] final_pipe_mul_acc = pipe_mul_acc_q[PIPE_LAST];
    wire final_pipe_mul_negate = pipe_mul_negate_q[PIPE_LAST];
    wire [63:0] final_pipe_div_quotient = pipe_div_quotient_q[PIPE_LAST];
    wire [63:0] final_pipe_div_remainder = pipe_div_remainder_q[PIPE_LAST][63:0];
    wire final_pipe_div_neg_quot = pipe_div_neg_quot_q[PIPE_LAST];
    wire final_pipe_div_neg_rem = pipe_div_neg_rem_q[PIPE_LAST];
    wire [127:0] final_mul_product = final_pipe_mul_negate ?
                                     (~final_pipe_mul_acc + 128'd1) :
                                     final_pipe_mul_acc;
    reg final_illegal;
    reg [`RV64_XLEN-1:0] final_result;

    assign ready_o = !result_valid_q || result_ready_i;
    assign busy_o = (|pipe_active_q) || result_valid_q;
    assign result_valid_o = result_valid_q;
    assign illegal_o = result_valid_q && illegal_q;
    assign result_o = result_valid_q ? result_q : {`RV64_XLEN{1'b0}};

    always @* begin
        start_mul_multiplicand = 128'h0000_0000_0000_0000_0000_0000_0000_0000;
        start_mul_multiplier = 64'h0000_0000_0000_0000;
        start_mul_negate = 1'b0;

        case (op_sel_i)
            `RV64_ALU_OP_MULH: begin
                start_mul_multiplicand = {64'h0000_0000_0000_0000, abs64(src1_i)};
                start_mul_multiplier = abs64(src2_i);
                start_mul_negate = src1_i[63] ^ src2_i[63];
            end

            `RV64_ALU_OP_MULHSU: begin
                start_mul_multiplicand = {64'h0000_0000_0000_0000, abs64(src1_i)};
                start_mul_multiplier = src2_i;
                start_mul_negate = src1_i[63];
            end

            default: begin
                if (word_op_i) begin
                    start_mul_multiplicand = {
                        96'h0000_0000_0000_0000_0000_0000,
                        src1_i[31:0]
                    };
                    start_mul_multiplier = {32'h0000_0000, src2_i[31:0]};
                end else begin
                    start_mul_multiplicand = {64'h0000_0000_0000_0000, src1_i};
                    start_mul_multiplier = src2_i;
                end
            end
        endcase
    end

    always @* begin
        final_illegal = final_pipe_illegal;
        final_result = final_pipe_result;

        if (pipe_active_q[PIPE_LAST]) begin
            case (final_pipe_kind)
                PIPE_KIND_MUL: begin
                    final_result = finish_mul_result(
                        final_mul_product,
                        final_pipe_op,
                        final_pipe_word
                    );
                    final_illegal = 1'b0;
                end

                PIPE_KIND_DIV: begin
                    final_result = finish_div_result(
                        final_pipe_op,
                        final_pipe_word,
                        final_pipe_div_quotient,
                        final_pipe_div_remainder,
                        final_pipe_div_neg_quot,
                        final_pipe_div_neg_rem
                    );
                    final_illegal = 1'b0;
                end

                default: begin
                end
            endcase
        end
    end

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

    function [127:0] mul_chunk_addend;
        input [127:0] multiplicand;
        input [63:0] multiplier;
        integer bit_idx;
        reg [127:0] addend;
        begin
            addend = 128'h0000_0000_0000_0000_0000_0000_0000_0000;

            for (bit_idx = 0; bit_idx < MUL_CHUNK_WIDTH; bit_idx = bit_idx + 1) begin
                if (multiplier[bit_idx]) begin
                    addend = addend + (multiplicand << bit_idx);
                end
            end

            mul_chunk_addend = addend;
        end
    endfunction

    function [327:0] mul_stage_step;
        input [127:0] acc;
        input [127:0] multiplicand;
        input [63:0] multiplier;
        input [7:0] bits_left;
        reg [127:0] acc_next;
        reg [127:0] multiplicand_next;
        reg [63:0] multiplier_next;
        reg [7:0] bits_left_next;
        begin
            acc_next = acc;
            multiplicand_next = multiplicand;
            multiplier_next = multiplier;
            bits_left_next = bits_left;

            if (bits_left != 8'd0) begin
                acc_next = acc + mul_chunk_addend(multiplicand, multiplier);
                multiplicand_next = multiplicand << MUL_CHUNK_WIDTH;
                multiplier_next = multiplier >> MUL_CHUNK_WIDTH;
                bits_left_next = (bits_left > MUL_CHUNK_WIDTH_VALUE) ?
                                 (bits_left - MUL_CHUNK_WIDTH_VALUE) :
                                 8'd0;
            end

            mul_stage_step = {
                acc_next,
                multiplicand_next,
                multiplier_next,
                bits_left_next
            };
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
                        bits_left :
                        DIV_CHUNK_WIDTH_VALUE;
            remainder_next = remainder;
            quotient_next = quotient;
            dividend_next = dividend;
            bits_left_next = bits_left;
            divisor_ext = {1'b0, divisor};

            for (bit_idx = 0; bit_idx < DIV_CHUNK_WIDTH; bit_idx = bit_idx + 1) begin
                if (bit_idx < step_bits) begin
                    remainder_next = {remainder_next[63:0], dividend_next[63]};
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
                             (bits_left - DIV_CHUNK_WIDTH_VALUE) :
                             8'd0;

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
        input [`RV64_ALU_OP_WIDTH-1:0] op_sel;
        input word_op;
        begin
            if (word_op) begin
                finish_mul_result = sext_word(product[31:0]);
            end else begin
                case (op_sel)
                    `RV64_ALU_OP_MULH,
                    `RV64_ALU_OP_MULHSU,
                    `RV64_ALU_OP_MULHU: begin
                        finish_mul_result = product[127:64];
                    end

                    default: begin
                        finish_mul_result = product[63:0];
                    end
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
            quotient_word = neg_quot ? (~quotient[31:0] + 32'd1) : quotient[31:0];
            remainder_word = neg_rem ? (~remainder[31:0] + 32'd1) : remainder[31:0];

            case (op_sel)
                `RV64_ALU_OP_DIV,
                `RV64_ALU_OP_DIVU: begin
                    finish_div_result = word_op ?
                                        sext_word(quotient_word) :
                                        quotient_signed;
                end

                `RV64_ALU_OP_REM,
                `RV64_ALU_OP_REMU: begin
                    finish_div_result = word_op ?
                                        sext_word(remainder_word) :
                                        remainder_signed;
                end

                default: begin
                    finish_div_result = {`RV64_XLEN{1'b0}};
                end
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
                `RV64_ALU_OP_DIVU: begin
                    div_zero_result = word_op ?
                                      sext_word(32'hffff_ffff) :
                                      {`RV64_XLEN{1'b1}};
                end

                `RV64_ALU_OP_REM,
                `RV64_ALU_OP_REMU: begin
                    div_zero_result = word_op ?
                                      sext_word(dividend[31:0]) :
                                      dividend;
                end

                default: begin
                    div_zero_result = {`RV64_XLEN{1'b0}};
                end
            endcase
        end
    endfunction

    function [`RV64_XLEN-1:0] div_overflow_result;
        input [`RV64_ALU_OP_WIDTH-1:0] op_sel;
        input word_op;
        begin
            case (op_sel)
                `RV64_ALU_OP_DIV: begin
                    div_overflow_result = word_op ?
                                          sext_word(32'h8000_0000) :
                                          64'h8000_0000_0000_0000;
                end

                `RV64_ALU_OP_REM: begin
                    div_overflow_result = {`RV64_XLEN{1'b0}};
                end

                default: begin
                    div_overflow_result = {`RV64_XLEN{1'b0}};
                end
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
            pipe_active_q <= {M_PIPE_STAGES{1'b0}};
            result_valid_q <= 1'b0;
            illegal_q <= 1'b0;
            result_q <= {`RV64_XLEN{1'b0}};

            for (stage_idx = 0; stage_idx < M_PIPE_STAGES; stage_idx = stage_idx + 1) begin
                pipe_kind_q[stage_idx] <= PIPE_KIND_RESULT;
                pipe_illegal_q[stage_idx] <= 1'b0;
                pipe_word_q[stage_idx] <= 1'b0;
                pipe_op_q[stage_idx] <= `RV64_ALU_OP_INVALID;
                pipe_result_q[stage_idx] <= {`RV64_XLEN{1'b0}};
                pipe_mul_bits_left_q[stage_idx] <= 8'd0;
                pipe_mul_acc_q[stage_idx] <= 128'h0000_0000_0000_0000_0000_0000_0000_0000;
                pipe_mul_multiplicand_q[stage_idx] <= 128'h0000_0000_0000_0000_0000_0000_0000_0000;
                pipe_mul_multiplier_q[stage_idx] <= 64'h0000_0000_0000_0000;
                pipe_mul_negate_q[stage_idx] <= 1'b0;
                pipe_div_bits_left_q[stage_idx] <= 8'd0;
                pipe_div_dividend_q[stage_idx] <= 64'h0000_0000_0000_0000;
                pipe_div_divisor_q[stage_idx] <= 64'h0000_0000_0000_0000;
                pipe_div_remainder_q[stage_idx] <= 65'h0_0000_0000_0000_0000;
                pipe_div_quotient_q[stage_idx] <= 64'h0000_0000_0000_0000;
                pipe_div_neg_quot_q[stage_idx] <= 1'b0;
                pipe_div_neg_rem_q[stage_idx] <= 1'b0;
            end
        end else if (flush_i) begin
            pipe_active_q <= {M_PIPE_STAGES{1'b0}};
            result_valid_q <= 1'b0;
            illegal_q <= 1'b0;
            result_q <= {`RV64_XLEN{1'b0}};

            for (stage_idx = 0; stage_idx < M_PIPE_STAGES; stage_idx = stage_idx + 1) begin
                pipe_kind_q[stage_idx] <= PIPE_KIND_RESULT;
                pipe_illegal_q[stage_idx] <= 1'b0;
                pipe_word_q[stage_idx] <= 1'b0;
                pipe_op_q[stage_idx] <= `RV64_ALU_OP_INVALID;
                pipe_result_q[stage_idx] <= {`RV64_XLEN{1'b0}};
                pipe_mul_bits_left_q[stage_idx] <= 8'd0;
                pipe_mul_acc_q[stage_idx] <= 128'h0000_0000_0000_0000_0000_0000_0000_0000;
                pipe_mul_multiplicand_q[stage_idx] <= 128'h0000_0000_0000_0000_0000_0000_0000_0000;
                pipe_mul_multiplier_q[stage_idx] <= 64'h0000_0000_0000_0000;
                pipe_mul_negate_q[stage_idx] <= 1'b0;
                pipe_div_bits_left_q[stage_idx] <= 8'd0;
                pipe_div_dividend_q[stage_idx] <= 64'h0000_0000_0000_0000;
                pipe_div_divisor_q[stage_idx] <= 64'h0000_0000_0000_0000;
                pipe_div_remainder_q[stage_idx] <= 65'h0_0000_0000_0000_0000;
                pipe_div_quotient_q[stage_idx] <= 64'h0000_0000_0000_0000;
                pipe_div_neg_quot_q[stage_idx] <= 1'b0;
                pipe_div_neg_rem_q[stage_idx] <= 1'b0;
            end
        end else begin
            if (result_valid_q && result_ready_i) begin
                result_valid_q <= 1'b0;
                illegal_q <= 1'b0;
                result_q <= {`RV64_XLEN{1'b0}};
            end

            if (pipe_active_q[PIPE_LAST]) begin
                result_valid_q <= 1'b1;
                illegal_q <= final_illegal;
                result_q <= final_result;
            end

            for (stage_idx = PIPE_LAST; stage_idx > 0; stage_idx = stage_idx - 1) begin
                pipe_active_q[stage_idx] <= pipe_active_q[stage_idx - 1];
                pipe_kind_q[stage_idx] <= pipe_kind_q[stage_idx - 1];
                pipe_illegal_q[stage_idx] <= pipe_illegal_q[stage_idx - 1];
                pipe_word_q[stage_idx] <= pipe_word_q[stage_idx - 1];
                pipe_op_q[stage_idx] <= pipe_op_q[stage_idx - 1];
                pipe_result_q[stage_idx] <= pipe_result_q[stage_idx - 1];
                pipe_mul_negate_q[stage_idx] <= pipe_mul_negate_q[stage_idx - 1];
                pipe_div_neg_quot_q[stage_idx] <= pipe_div_neg_quot_q[stage_idx - 1];
                pipe_div_neg_rem_q[stage_idx] <= pipe_div_neg_rem_q[stage_idx - 1];
                pipe_div_divisor_q[stage_idx] <= pipe_div_divisor_q[stage_idx - 1];

                if (pipe_kind_q[stage_idx - 1] == PIPE_KIND_MUL) begin
                    mul_step_value = mul_stage_step(
                        pipe_mul_acc_q[stage_idx - 1],
                        pipe_mul_multiplicand_q[stage_idx - 1],
                        pipe_mul_multiplier_q[stage_idx - 1],
                        pipe_mul_bits_left_q[stage_idx - 1]
                    );
                    pipe_mul_acc_q[stage_idx] <= mul_step_value[327:200];
                    pipe_mul_multiplicand_q[stage_idx] <= mul_step_value[199:72];
                    pipe_mul_multiplier_q[stage_idx] <= mul_step_value[71:8];
                    pipe_mul_bits_left_q[stage_idx] <= mul_step_value[7:0];
                    pipe_div_remainder_q[stage_idx] <= pipe_div_remainder_q[stage_idx - 1];
                    pipe_div_quotient_q[stage_idx] <= pipe_div_quotient_q[stage_idx - 1];
                    pipe_div_dividend_q[stage_idx] <= pipe_div_dividend_q[stage_idx - 1];
                    pipe_div_bits_left_q[stage_idx] <= pipe_div_bits_left_q[stage_idx - 1];
                end else if (pipe_kind_q[stage_idx - 1] == PIPE_KIND_DIV) begin
                    div_step_value = div_stage_step(
                        pipe_div_remainder_q[stage_idx - 1],
                        pipe_div_quotient_q[stage_idx - 1],
                        pipe_div_dividend_q[stage_idx - 1],
                        pipe_div_divisor_q[stage_idx - 1],
                        pipe_div_bits_left_q[stage_idx - 1]
                    );
                    pipe_div_remainder_q[stage_idx] <= div_step_value[200:136];
                    pipe_div_quotient_q[stage_idx] <= div_step_value[135:72];
                    pipe_div_dividend_q[stage_idx] <= div_step_value[71:8];
                    pipe_div_bits_left_q[stage_idx] <= div_step_value[7:0];
                    pipe_mul_acc_q[stage_idx] <= pipe_mul_acc_q[stage_idx - 1];
                    pipe_mul_multiplicand_q[stage_idx] <= pipe_mul_multiplicand_q[stage_idx - 1];
                    pipe_mul_multiplier_q[stage_idx] <= pipe_mul_multiplier_q[stage_idx - 1];
                    pipe_mul_bits_left_q[stage_idx] <= pipe_mul_bits_left_q[stage_idx - 1];
                end else begin
                    pipe_mul_acc_q[stage_idx] <= pipe_mul_acc_q[stage_idx - 1];
                    pipe_mul_multiplicand_q[stage_idx] <= pipe_mul_multiplicand_q[stage_idx - 1];
                    pipe_mul_multiplier_q[stage_idx] <= pipe_mul_multiplier_q[stage_idx - 1];
                    pipe_mul_bits_left_q[stage_idx] <= pipe_mul_bits_left_q[stage_idx - 1];
                    pipe_div_remainder_q[stage_idx] <= pipe_div_remainder_q[stage_idx - 1];
                    pipe_div_quotient_q[stage_idx] <= pipe_div_quotient_q[stage_idx - 1];
                    pipe_div_dividend_q[stage_idx] <= pipe_div_dividend_q[stage_idx - 1];
                    pipe_div_bits_left_q[stage_idx] <= pipe_div_bits_left_q[stage_idx - 1];
                end
            end

            pipe_active_q[0] <= start;
            pipe_word_q[0] <= word_op_i;
            pipe_op_q[0] <= op_sel_i;
            pipe_result_q[0] <= {`RV64_XLEN{1'b0}};
            pipe_illegal_q[0] <= 1'b0;
            pipe_mul_negate_q[0] <= 1'b0;
            pipe_div_neg_quot_q[0] <= 1'b0;
            pipe_div_neg_rem_q[0] <= 1'b0;
            pipe_div_divisor_q[0] <= 64'h0000_0000_0000_0000;
            pipe_mul_acc_q[0] <= 128'h0000_0000_0000_0000_0000_0000_0000_0000;
            pipe_mul_multiplicand_q[0] <= 128'h0000_0000_0000_0000_0000_0000_0000_0000;
            pipe_mul_multiplier_q[0] <= 64'h0000_0000_0000_0000;
            pipe_mul_bits_left_q[0] <= 8'd0;
            pipe_div_remainder_q[0] <= 65'h0_0000_0000_0000_0000;
            pipe_div_quotient_q[0] <= 64'h0000_0000_0000_0000;
            pipe_div_dividend_q[0] <= 64'h0000_0000_0000_0000;
            pipe_div_bits_left_q[0] <= 8'd0;

            if (start) begin
                if (start_mul_valid) begin
                    pipe_kind_q[0] <= PIPE_KIND_MUL;
                    pipe_mul_acc_q[0] <= start_mul_step_value[327:200];
                    pipe_mul_multiplicand_q[0] <= start_mul_step_value[199:72];
                    pipe_mul_multiplier_q[0] <= start_mul_step_value[71:8];
                    pipe_mul_bits_left_q[0] <= start_mul_step_value[7:0];
                    pipe_mul_negate_q[0] <= start_mul_negate;
                end else if (start_div_valid && !start_divisor_zero && !start_div_overflow) begin
                    pipe_kind_q[0] <= PIPE_KIND_DIV;
                    pipe_div_remainder_q[0] <= start_div_step_value[200:136];
                    pipe_div_quotient_q[0] <= start_div_step_value[135:72];
                    pipe_div_dividend_q[0] <= start_div_step_value[71:8];
                    pipe_div_bits_left_q[0] <= start_div_step_value[7:0];
                    pipe_div_divisor_q[0] <= div_start_divisor(
                        start_signed_div_op,
                        word_op_i,
                        src2_i
                    );
                    pipe_div_neg_quot_q[0] <= start_signed_div_op &&
                                               (word_op_i ?
                                                (src1_i[31] ^ src2_i[31]) :
                                                (src1_i[63] ^ src2_i[63]));
                    pipe_div_neg_rem_q[0] <= start_signed_div_op &&
                                              (word_op_i ? src1_i[31] : src1_i[63]);
                end else begin
                    pipe_kind_q[0] <= PIPE_KIND_RESULT;
                    pipe_illegal_q[0] <= !start_div_valid;
                    pipe_result_q[0] <= start_divisor_zero ?
                                        div_zero_result(op_sel_i, word_op_i, src1_i) :
                                        start_div_overflow ?
                                        div_overflow_result(op_sel_i, word_op_i) :
                                        {`RV64_XLEN{1'b0}};
                end
            end else begin
                pipe_kind_q[0] <= PIPE_KIND_RESULT;
            end
        end
    end

endmodule
