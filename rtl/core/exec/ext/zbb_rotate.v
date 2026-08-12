`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"

// Pipelined Zbb rotate datapath built from two 32-bit barrel shifters.
//
// Word rotates use both shifters in parallel and may start every cycle.  A
// 64-bit rotate uses the same pair twice: the first cycle produces the direct
// term for both 32-bit halves and the second produces the wrap term.  Wide
// rotates therefore have an intentional initiation interval of two cycles.
// The final OR is isolated in an elastic output stage.
module openrv64_exec_zbb_rotate #(
    parameter integer TAG_WIDTH = 1
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire                         valid_i,
    output wire                         ready_o,
    input  wire [`RV64_ALU_OP_WIDTH-1:0] op_sel_i,
    input  wire                         word_op_i,
    input  wire [`RV64_XLEN-1:0]        src_i,
    input  wire [`RV64_XLEN-1:0]        amount_i,
    input  wire [TAG_WIDTH-1:0]         tag_i,

    output wire                         busy_o,
    output wire                         result_valid_o,
    input  wire                         result_ready_i,
    output wire [`RV64_XLEN-1:0]        result_o,
    output wire [TAG_WIDTH-1:0]         result_tag_o
);

    wire rotate_left_i = op_sel_i == `RV64_ALU_OP_ZBB_ROL;
    wire [4:0] shift_i = amount_i[4:0];
    wire [4:0] inverse_shift_i = -shift_i;

    // First elastic stage: the two terms which the final OR consumes.
    reg stage0_valid_q;
    reg [63:0] stage0_term0_q;
    reg [63:0] stage0_term1_q;
    reg stage0_word_q;
    reg [TAG_WIDTH-1:0] stage0_tag_q;

    // Final elastic stage.
    reg stage1_valid_q;
    reg [63:0] stage1_result_q;
    reg [TAG_WIDTH-1:0] stage1_tag_q;

    wire stage1_ready = !stage1_valid_q || result_ready_i;
    wire stage0_ready = !stage0_valid_q || stage1_ready;

    // A wide rotate holds its direct terms and operands for the second use of
    // the two shifters.  No new operation may enter during that second cycle.
    reg wide_active_q;
    reg wide_left_q;
    reg [31:0] wide_hi_q;
    reg [31:0] wide_lo_q;
    reg [4:0] wide_inverse_shift_q;
    reg [31:0] wide_direct_hi_q;
    reg [31:0] wide_direct_lo_q;
    reg [TAG_WIDTH-1:0] wide_tag_q;

    function automatic [31:0] reverse32;
        input [31:0] value;
        integer bit_index;
        begin
            for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1)
                reverse32[bit_index] = value[31-bit_index];
        end
    endfunction

    wire [31:0] input_hi = amount_i[5] ? src_i[31:0] : src_i[63:32];
    wire [31:0] input_lo = amount_i[5] ? src_i[63:32] : src_i[31:0];

    // The only variable shifts in this module.  Operand/direction muxes feed
    // exactly two 32-bit bidirectional shifter lanes; a wide operation reuses
    // those lanes on its second cycle rather than replicating them.
    wire shifters_do_wide_wrap = wide_active_q;
    wire [31:0] shifter0_src = shifters_do_wide_wrap ? wide_lo_q :
        (word_op_i ? src_i[31:0] : input_hi);
    wire [31:0] shifter1_src = shifters_do_wide_wrap ? wide_hi_q :
        (word_op_i ? src_i[31:0] : input_lo);
    wire [4:0] shifter0_amount = shifters_do_wide_wrap ?
        wide_inverse_shift_q : shift_i;
    wire [4:0] shifter1_amount = shifters_do_wide_wrap ?
        wide_inverse_shift_q : (word_op_i ? inverse_shift_i : shift_i);
    wire shifter0_left = shifters_do_wide_wrap ? !wide_left_q :
        rotate_left_i;
    wire shifter1_left = shifters_do_wide_wrap ? !wide_left_q :
        (word_op_i ? !rotate_left_i : rotate_left_i);
    // Normalize left shifts into right shifts through bit reversal.  This is
    // intentionally written as two shift expressions total: otherwise common
    // synthesis flows infer separate left and right barrel networks per lane.
    wire [31:0] shifter0_normalized_src = shifter0_left ?
        reverse32(shifter0_src) : shifter0_src;
    wire [31:0] shifter1_normalized_src = shifter1_left ?
        reverse32(shifter1_src) : shifter1_src;
    wire [31:0] shifter0_shifted =
        shifter0_normalized_src >> shifter0_amount;
    wire [31:0] shifter1_shifted =
        shifter1_normalized_src >> shifter1_amount;
    wire [31:0] shifter0_result = shifter0_left ?
        reverse32(shifter0_shifted) : shifter0_shifted;
    wire [31:0] shifter1_result = shifter1_left ?
        reverse32(shifter1_shifted) : shifter1_shifted;

    wire [31:0] word_term0 = shifter0_result;
    wire [31:0] word_term1 = shifter1_result;
    wire [31:0] wide_direct_hi = shifter0_result;
    wire [31:0] wide_direct_lo = shifter1_result;
    wire [31:0] wide_wrap_hi_raw = shifter0_result;
    wire [31:0] wide_wrap_lo_raw = shifter1_result;
    // With a zero intra-half shift, the mathematical wrap shift is by 32 and
    // must contribute zero.  A five-bit hardware shift amount would alias it
    // to zero, so suppress that term explicitly.
    wire [31:0] wide_wrap_hi = (wide_inverse_shift_q == 5'd0) ?
        32'd0 : wide_wrap_hi_raw;
    wire [31:0] wide_wrap_lo = (wide_inverse_shift_q == 5'd0) ?
        32'd0 : wide_wrap_lo_raw;

    wire input_valid_op = (op_sel_i == `RV64_ALU_OP_ZBB_ROL) ||
                          (op_sel_i == `RV64_ALU_OP_ZBB_ROR);
    // A word request writes stage 0 immediately.  A wide request first writes
    // only the private wide holding registers, so it need not wait for an
    // older stage-0 word to advance.
    assign ready_o = !wide_active_q && input_valid_op &&
                     (!word_op_i || stage0_ready);
    wire start = valid_i && ready_o;

    assign busy_o = wide_active_q || stage0_valid_q || stage1_valid_q;
    assign result_valid_o = stage1_valid_q;
    assign result_o = stage1_result_q;
    assign result_tag_o = stage1_tag_q;

    wire [31:0] stage0_word_result = stage0_term0_q[31:0] |
                                     stage0_term1_q[31:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage0_valid_q <= 1'b0;
            stage0_term0_q <= 64'd0;
            stage0_term1_q <= 64'd0;
            stage0_word_q <= 1'b0;
            stage0_tag_q <= {TAG_WIDTH{1'b0}};
            stage1_valid_q <= 1'b0;
            stage1_result_q <= 64'd0;
            stage1_tag_q <= {TAG_WIDTH{1'b0}};
            wide_active_q <= 1'b0;
            wide_left_q <= 1'b0;
            wide_hi_q <= 32'd0;
            wide_lo_q <= 32'd0;
            wide_inverse_shift_q <= 5'd0;
            wide_direct_hi_q <= 32'd0;
            wide_direct_lo_q <= 32'd0;
            wide_tag_q <= {TAG_WIDTH{1'b0}};
        end else if (flush_i) begin
            stage0_valid_q <= 1'b0;
            stage1_valid_q <= 1'b0;
            wide_active_q <= 1'b0;
        end else begin
            if (stage1_ready) begin
                stage1_valid_q <= stage0_valid_q;
                if (stage0_valid_q) begin
                    if (stage0_word_q)
                        stage1_result_q <= {
                            {32{stage0_word_result[31]}},
                            stage0_word_result
                        };
                    else
                        stage1_result_q <= stage0_term0_q |
                                           stage0_term1_q;
                    stage1_tag_q <= stage0_tag_q;
                end
            end

            if (stage0_ready)
                stage0_valid_q <= 1'b0;

            if (wide_active_q && stage0_ready) begin
                stage0_valid_q <= 1'b1;
                stage0_term0_q <= {wide_direct_hi_q,
                                    wide_direct_lo_q};
                stage0_term1_q <= {wide_wrap_hi, wide_wrap_lo};
                stage0_word_q <= 1'b0;
                stage0_tag_q <= wide_tag_q;
                wide_active_q <= 1'b0;
            end else if (start && word_op_i) begin
                stage0_valid_q <= 1'b1;
                stage0_term0_q <= {32'd0, word_term0};
                stage0_term1_q <= {32'd0, word_term1};
                stage0_word_q <= 1'b1;
                stage0_tag_q <= tag_i;
            end else if (start) begin
                wide_active_q <= 1'b1;
                wide_left_q <= rotate_left_i;
                wide_hi_q <= input_hi;
                wide_lo_q <= input_lo;
                wide_inverse_shift_q <= inverse_shift_i;
                wide_direct_hi_q <= wide_direct_hi;
                wide_direct_lo_q <= wide_direct_lo;
                wide_tag_q <= tag_i;
            end
        end
    end

endmodule
