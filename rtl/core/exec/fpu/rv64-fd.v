`ifndef OPENRV64_EXEC_FPU_RV64_FD_V
`define OPENRV64_EXEC_FPU_RV64_FD_V
`timescale 1ns/1ps
`include "core/isa/rv64-d.v"
`include "core/exec/fpu/defs.v"

// Standalone, fully backpressured RV64F/RV64D execution unit.
//
// This implementation deliberately favors low combinational complexity per
// stage.  The iterative pipeline accepts one request per cycle when unstalled.
// Four significand bits advance per stage for multiply, fused multiply-add,
// divide, and square root.  Simple operations and resolved arithmetic special
// cases use a one-entry fast lane, while binary32 multiply and square root tap
// the iterative pipeline as soon as their arithmetic state is complete.
// Tagged responses may complete out of issue order.  The selected response
// remains stable under backpressure.
// Sustaining that throughput replicates arithmetic state and iteration logic
// across the deep pipeline; this is not a small shared iterative unit.  This
// module is deliberately not wired to decode, an F register file, fcsr,
// retirement, or the LSU yet.
//
// type_i carries the instruction rs2 type selector for conversions:
// W/WU/L/LU for integer conversions and S/D for format conversions.  It is
// ignored by other operations.
module openrv64_exec_fpu_rv64fd #(
    parameter integer TAG_WIDTH = 8
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire                         valid_i,
    output wire                         ready_o,
    input  wire [TAG_WIDTH-1:0]         tag_i,
    input  wire [`OPENRV64_FP_OP_WIDTH-1:0] op_i,
    input  wire [1:0]                   fmt_i,
    input  wire [2:0]                   rm_i,
    input  wire [2:0]                   frm_i,
    input  wire [4:0]                   type_i,
    input  wire [63:0]                  src1_i,
    input  wire [63:0]                  src2_i,
    input  wire [63:0]                  src3_i,

    output wire                         result_valid_o,
    input  wire                         result_ready_i,
    output wire [TAG_WIDTH-1:0]         result_tag_o,
    output wire                         result_is_int_o,
    output wire [63:0]                  fp_result_o,
    output wire [63:0]                  int_result_o,
    output wire [4:0]                   fflags_o,
    output wire                         unsupported_o
);

    localparam integer EXEC_WIDTH = 135;
    localparam integer EXEC_INT_LO = 0;
    localparam integer EXEC_FP_LO = 64;
    localparam integer EXEC_FLAGS_LO = 128;
    localparam integer EXEC_IS_INT_BIT = 133;
    localparam integer EXEC_UNSUPPORTED_BIT = 134;
    localparam integer UNPACK_WIDTH = 85;
    localparam integer UNPACK_SIG_LO = 0;
    localparam integer UNPACK_EXP_LO = 64;
    localparam integer UNPACK_SIGN_BIT = 80;
    localparam integer UNPACK_ZERO_BIT = 81;
    localparam integer UNPACK_INF_BIT = 82;
    localparam integer UNPACK_SNAN_BIT = 83;
    localparam integer UNPACK_NAN_BIT = 84;

    localparam integer PIPELINE_ITER_BITS = 4;
    localparam integer PIPELINE_ITER_STAGES = 14;
    localparam integer MUL_S_RESULT_STAGE = 6;
    localparam integer SQRT_S_RESULT_STAGE = 7;
    localparam [1:0] RESULT_SOURCE_FAST = 2'd0;
    localparam [1:0] RESULT_SOURCE_MUL_S = 2'd1;
    localparam [1:0] RESULT_SOURCE_SQRT_S = 2'd2;
    localparam [1:0] RESULT_SOURCE_FINAL = 2'd3;
    localparam integer PAY_EXEC_LO = 0;
    localparam integer PAY_STATE0_LO = PAY_EXEC_LO + EXEC_WIDTH;
    localparam integer PAY_STATE1_LO = PAY_STATE0_LO + 128;
    localparam integer PAY_STATE2_LO = PAY_STATE1_LO + 128;
    localparam integer PAY_SRC3_LO = PAY_STATE2_LO + 128;
    localparam integer PAY_EXP_LO = PAY_SRC3_LO + 64;
    localparam integer PAY_OP_LO = PAY_EXP_LO + 16;
    localparam integer PAY_RM_LO = PAY_OP_LO +
                                   `OPENRV64_FP_OP_WIDTH;
    localparam integer PAY_IS_DOUBLE_BIT = PAY_RM_LO + 3;
    localparam integer PAY_SIGN_BIT = PAY_IS_DOUBLE_BIT + 1;
    localparam integer PAY_C_INVERT_BIT = PAY_SIGN_BIT + 1;
    localparam integer PAY_COUNT_LO = PAY_C_INVERT_BIT + 1;
    localparam integer PAY_LONG_BIT = PAY_COUNT_LO + 7;
    localparam integer PAYLOAD_WIDTH = PAY_LONG_BIT + 1;

    function automatic [127:0] shift_right_jam;
        input [127:0] value;
        input integer distance;
        reg [127:0] mask;
        reg sticky;
        begin
            if (distance <= 0) begin
                shift_right_jam = value;
            end else if (distance >= 128) begin
                shift_right_jam = {127'd0, |value};
            end else begin
                mask = ({128{1'b1}} >> (128 - distance));
                sticky = |(value & mask);
                shift_right_jam = value >> distance;
                shift_right_jam[0] = shift_right_jam[0] | sticky;
            end
        end
    endfunction

    function automatic [31:0] sanitize_single;
        input [63:0] value;
        begin
            sanitize_single = (value[63:32] == 32'hffff_ffff) ?
                              value[31:0] :
                              `RV64_FP_CANONICAL_NAN_S;
        end
    endfunction

    // Input sig_ext has three rounding bits below a p-bit normalized
    // significand.  exponent is unbiased and names the hidden-bit position.
    function automatic [68:0] round_pack;
        input is_double;
        input sign;
        input integer exponent_in;
        input [127:0] sig_ext_in;
        input [2:0] rounding_mode;
        integer p;
        integer bias;
        integer minimum_exponent;
        integer maximum_exponent;
        integer exponent;
        integer distance;
        integer biased_exponent;
        reg [127:0] work;
        reg [127:0] main_sig;
        reg [63:0] result;
        reg [4:0] flags;
        reg guard_bit;
        reg round_bit;
        reg sticky_bit;
        reg inexact;
        reg increment;
        reg overflow_to_infinity;
        reg [10:0] exponent_field;
        reg tiny_after_rounding;
        begin
            p = is_double ? 53 : 24;
            bias = is_double ? 1023 : 127;
            minimum_exponent = 1 - bias;
            maximum_exponent = bias;
            exponent = exponent_in;
            work = sig_ext_in;
            result = 64'd0;
            flags = 5'd0;

            if (work == 0) begin
                result = is_double ? {sign, 63'd0} :
                         {32'hffff_ffff, sign, 31'd0};
            end else begin
                if (exponent < minimum_exponent) begin
                    distance = minimum_exponent - exponent;
                    work = shift_right_jam(work, distance);
                    exponent = minimum_exponent;
                end

                main_sig = work >> 3;
                guard_bit = work[2];
                round_bit = work[1];
                sticky_bit = work[0];
                inexact = guard_bit || round_bit || sticky_bit;

                case (rounding_mode)
                    `RV64_FP_RM_RNE:
                        increment = guard_bit &&
                                    (round_bit || sticky_bit || main_sig[0]);
                    `RV64_FP_RM_RTZ: increment = 1'b0;
                    `RV64_FP_RM_RDN: increment = sign && inexact;
                    `RV64_FP_RM_RUP: increment = !sign && inexact;
                    `RV64_FP_RM_RMM: increment = guard_bit;
                    default: increment = 1'b0;
                endcase

                if (increment)
                    main_sig = main_sig + 1'b1;

                if (main_sig[p]) begin
                    main_sig = main_sig >> 1;
                    exponent = exponent + 1;
                end

                if (exponent > maximum_exponent) begin
                    flags = `RV64_FP_FFLAG_OF | `RV64_FP_FFLAG_NX;
                    case (rounding_mode)
                        `RV64_FP_RM_RTZ:
                            overflow_to_infinity = 1'b0;
                        `RV64_FP_RM_RDN:
                            overflow_to_infinity = sign;
                        `RV64_FP_RM_RUP:
                            overflow_to_infinity = !sign;
                        default:
                            overflow_to_infinity = 1'b1;
                    endcase
                    if (is_double) begin
                        result = overflow_to_infinity ?
                            {sign, 11'h7ff, 52'd0} :
                            {sign, 11'h7fe, {52{1'b1}}};
                    end else begin
                        result = overflow_to_infinity ?
                            {32'hffff_ffff, sign, 8'hff, 23'd0} :
                            {32'hffff_ffff, sign, 8'hfe, {23{1'b1}}};
                    end
                end else begin
                    tiny_after_rounding =
                        (exponent == minimum_exponent) && !main_sig[p-1];
                    biased_exponent = exponent + bias;
                    exponent_field = tiny_after_rounding ? 11'd0 :
                                     biased_exponent[10:0];
                    if (is_double)
                        result = {sign, exponent_field[10:0],
                                  main_sig[51:0]};
                    else
                        result = {32'hffff_ffff, sign,
                                  exponent_field[7:0],
                                  main_sig[22:0]};
                    if (inexact)
                        flags = flags | `RV64_FP_FFLAG_NX;
                    if (tiny_after_rounding && inexact)
                        flags = flags | `RV64_FP_FFLAG_UF;
                end
            end
            round_pack = {flags, result};
        end
    endfunction

    function automatic [68:0] add_sub;
        input is_double;
        input subtract;
        input [63:0] source1;
        input [63:0] source2;
        input [2:0] rounding_mode;
        integer p;
        integer fraction_bits;
        integer bias;
        integer exp_a;
        integer exp_b;
        integer exponent;
        integer distance;
        integer normalize_index;
        reg [63:0] a;
        reg [63:0] b;
        reg sign_a;
        reg sign_b;
        reg sign_result;
        reg [10:0] field_a;
        reg [10:0] field_b;
        reg [63:0] fraction_a;
        reg [63:0] fraction_b;
        reg [63:0] sig_a;
        reg [63:0] sig_b;
        reg [127:0] ext_a;
        reg [127:0] ext_b;
        reg [127:0] ext_result;
        reg nan_a;
        reg nan_b;
        reg snan_a;
        reg snan_b;
        reg inf_a;
        reg inf_b;
        reg zero_a;
        reg zero_b;
        reg [63:0] special_result;
        reg [4:0] special_flags;
        begin
            p = is_double ? 53 : 24;
            fraction_bits = is_double ? 52 : 23;
            bias = is_double ? 1023 : 127;
            a = is_double ? source1 : {32'd0, sanitize_single(source1)};
            b = is_double ? source2 : {32'd0, sanitize_single(source2)};
            sign_a = a[is_double ? 63 : 31];
            sign_b = b[is_double ? 63 : 31] ^ subtract;
            field_a = is_double ? a[62:52] : {3'd0, a[30:23]};
            field_b = is_double ? b[62:52] : {3'd0, b[30:23]};
            fraction_a = is_double ? {12'd0, a[51:0]} :
                                     {41'd0, a[22:0]};
            fraction_b = is_double ? {12'd0, b[51:0]} :
                                     {41'd0, b[22:0]};
            nan_a = (is_double ? (&field_a[10:0]) :
                       (&field_a[7:0])) && (fraction_a != 0);
            nan_b = (is_double ? (&field_b[10:0]) :
                       (&field_b[7:0])) && (fraction_b != 0);
            snan_a = nan_a && !fraction_a[fraction_bits-1];
            snan_b = nan_b && !fraction_b[fraction_bits-1];
            inf_a = (is_double ? (&field_a[10:0]) :
                       (&field_a[7:0])) && (fraction_a == 0);
            inf_b = (is_double ? (&field_b[10:0]) :
                       (&field_b[7:0])) && (fraction_b == 0);
            zero_a = (field_a == 0) && (fraction_a == 0);
            zero_b = (field_b == 0) && (fraction_b == 0);
            special_result = is_double ? `RV64_FP_CANONICAL_NAN_D :
                             `RV64_FP_NANBOX_S(`RV64_FP_CANONICAL_NAN_S);
            special_flags = 5'd0;

            if (nan_a || nan_b) begin
                if (snan_a || snan_b)
                    special_flags = `RV64_FP_FFLAG_NV;
                add_sub = {special_flags, special_result};
            end else if (inf_a && inf_b && (sign_a != sign_b)) begin
                add_sub = {`RV64_FP_FFLAG_NV, special_result};
            end else if (inf_a || inf_b) begin
                if (inf_a)
                    special_result = is_double ? {sign_a, 11'h7ff, 52'd0} :
                        {32'hffff_ffff, sign_a, 8'hff, 23'd0};
                else
                    special_result = is_double ? {sign_b, 11'h7ff, 52'd0} :
                        {32'hffff_ffff, sign_b, 8'hff, 23'd0};
                add_sub = {5'd0, special_result};
            end else if (zero_a && zero_b) begin
                sign_result = (sign_a == sign_b) ? sign_a :
                              (rounding_mode == `RV64_FP_RM_RDN);
                special_result = is_double ? {sign_result, 63'd0} :
                    {32'hffff_ffff, sign_result, 31'd0};
                add_sub = {5'd0, special_result};
            end else begin
                if (field_a == 0) begin
                    exp_a = 1 - bias;
                    sig_a = fraction_a;
                    for (normalize_index = 0;
                         normalize_index < 64;
                         normalize_index = normalize_index + 1) begin
                        if ((sig_a != 0) && !sig_a[p-1]) begin
                            sig_a = sig_a << 1;
                            exp_a = exp_a - 1;
                        end
                    end
                end else begin
                    exp_a = field_a;
                    exp_a = exp_a - bias;
                    sig_a = (64'd1 << (p-1)) | fraction_a;
                end
                if (field_b == 0) begin
                    exp_b = 1 - bias;
                    sig_b = fraction_b;
                    for (normalize_index = 0;
                         normalize_index < 64;
                         normalize_index = normalize_index + 1) begin
                        if ((sig_b != 0) && !sig_b[p-1]) begin
                            sig_b = sig_b << 1;
                            exp_b = exp_b - 1;
                        end
                    end
                end else begin
                    exp_b = field_b;
                    exp_b = exp_b - bias;
                    sig_b = (64'd1 << (p-1)) | fraction_b;
                end

                ext_a = {64'd0, sig_a} << 3;
                ext_b = {64'd0, sig_b} << 3;
                if (exp_a > exp_b) begin
                    distance = exp_a - exp_b;
                    ext_b = shift_right_jam(ext_b, distance);
                    exponent = exp_a;
                end else if (exp_b > exp_a) begin
                    distance = exp_b - exp_a;
                    ext_a = shift_right_jam(ext_a, distance);
                    exponent = exp_b;
                end else begin
                    exponent = exp_a;
                end

                if (sign_a == sign_b) begin
                    sign_result = sign_a;
                    ext_result = ext_a + ext_b;
                    if (ext_result[p+3]) begin
                        ext_result = shift_right_jam(ext_result, 1);
                        exponent = exponent + 1;
                    end
                end else if (ext_a > ext_b) begin
                    sign_result = sign_a;
                    ext_result = ext_a - ext_b;
                end else if (ext_b > ext_a) begin
                    sign_result = sign_b;
                    ext_result = ext_b - ext_a;
                end else begin
                    sign_result =
                        (rounding_mode == `RV64_FP_RM_RDN);
                    ext_result = 128'd0;
                end

                if ((sign_a != sign_b) && (ext_result != 0)) begin
                    for (normalize_index = 0;
                         normalize_index < 64;
                         normalize_index = normalize_index + 1) begin
                        if (!ext_result[p+2]) begin
                            ext_result = ext_result << 1;
                            exponent = exponent - 1;
                        end
                    end
                end
                add_sub = round_pack(is_double, sign_result, exponent,
                                     ext_result, rounding_mode);
            end
        end
    endfunction

    // Normalized finite operands have sig[p-1]=1 and an unbiased exponent.
    // Specials retain their sign/classification and leave exponent/sig zero.
    function automatic [UNPACK_WIDTH-1:0] unpack_fp;
        input is_double;
        input [63:0] source;
        integer p;
        integer fraction_bits;
        integer bias;
        integer normalize_index;
        reg [63:0] value;
        reg sign;
        reg [10:0] exponent_field;
        reg [63:0] fraction;
        reg [63:0] significand;
        reg signed [15:0] exponent;
        reg is_zero;
        reg is_inf;
        reg is_snan;
        reg is_nan;
        begin
            p = is_double ? 53 : 24;
            fraction_bits = is_double ? 52 : 23;
            bias = is_double ? 1023 : 127;
            value = is_double ? source : {32'd0, sanitize_single(source)};
            sign = value[is_double ? 63 : 31];
            exponent_field = is_double ? value[62:52] :
                             {3'd0, value[30:23]};
            fraction = is_double ? {12'd0, value[51:0]} :
                       {41'd0, value[22:0]};
            significand = 64'd0;
            exponent = 16'sd0;
            is_zero = 1'b0;
            is_inf = 1'b0;
            is_snan = 1'b0;
            is_nan = 1'b0;

            if (is_double ? (&exponent_field[10:0]) :
                            (&exponent_field[7:0])) begin
                if (fraction == 0)
                    is_inf = 1'b1;
                else begin
                    is_nan = 1'b1;
                    is_snan = !fraction[fraction_bits-1];
                end
            end else if (exponent_field == 0) begin
                if (fraction == 0) begin
                    is_zero = 1'b1;
                end else begin
                    significand = fraction;
                    exponent = 1 - bias;
                    for (normalize_index = 0;
                         normalize_index < 64;
                         normalize_index = normalize_index + 1) begin
                        if (!significand[p-1]) begin
                            significand = significand << 1;
                            exponent = exponent - 16'sd1;
                        end
                    end
                end
            end else begin
                significand = (64'd1 << (p-1)) | fraction;
                exponent = $signed({1'b0, exponent_field}) - bias;
            end

            unpack_fp = {
                is_nan,
                is_snan,
                is_inf,
                is_zero,
                sign,
                exponent,
                significand
            };
        end
    endfunction

    function automatic [63:0] fp_canonical_nan;
        input is_double;
        begin
            fp_canonical_nan = is_double ? `RV64_FP_CANONICAL_NAN_D :
                `RV64_FP_NANBOX_S(`RV64_FP_CANONICAL_NAN_S);
        end
    endfunction

    function automatic [63:0] fp_infinity;
        input is_double;
        input sign;
        begin
            fp_infinity = is_double ? {sign, 11'h7ff, 52'd0} :
                {32'hffff_ffff, sign, 8'hff, 23'd0};
        end
    endfunction

    function automatic [63:0] fp_zero;
        input is_double;
        input sign;
        begin
            fp_zero = is_double ? {sign, 63'd0} :
                {32'hffff_ffff, sign, 31'd0};
        end
    endfunction

    function automatic [68:0] round_product;
        input is_double;
        input sign;
        input signed [15:0] exponent_sum;
        input [127:0] product;
        input [2:0] rounding_mode;
        integer p;
        integer shift_distance;
        integer result_exponent;
        reg [127:0] ext_result;
        begin
            p = is_double ? 53 : 24;
            if (is_double ? product[105] : product[47]) begin
                result_exponent = exponent_sum + 1;
                shift_distance = p - 3;
            end else begin
                result_exponent = exponent_sum;
                shift_distance = p - 4;
            end
            ext_result = shift_right_jam(product, shift_distance);
            round_product = round_pack(
                is_double,
                sign,
                result_exponent,
                ext_result,
                rounding_mode
            );
        end
    endfunction

    // Add an exact, unrounded product to the third FMA operand.  Bit 120 is
    // the common hidden-bit anchor; this leaves enough low bits to retain all
    // 106 bits of a binary64 product through cancellation.
    function automatic [68:0] add_product;
        input is_double;
        input product_sign;
        input c_sign_invert;
        input signed [15:0] exponent_sum;
        input [127:0] product;
        input [63:0] source3;
        input [2:0] rounding_mode;
        localparam integer ANCHOR = 120;
        integer p;
        integer product_top;
        integer product_shift;
        integer c_shift;
        integer exponent_product;
        integer exponent_c;
        integer exponent_result;
        integer distance;
        integer normalize_index;
        reg [UNPACK_WIDTH-1:0] c_info;
        reg c_sign;
        reg [63:0] c_sig;
        reg [127:0] product_mag;
        reg [127:0] c_mag;
        reg [127:0] result_mag;
        reg result_sign;
        reg [127:0] ext_result;
        begin
            p = is_double ? 53 : 24;
            c_info = unpack_fp(is_double, source3);
            c_sign = c_info[UNPACK_SIGN_BIT] ^ c_sign_invert;
            c_sig = c_info[UNPACK_SIG_LO +: 64];
            exponent_c = $signed(
                c_info[UNPACK_EXP_LO +: 16]
            );

            if (is_double ? product[105] : product[47]) begin
                product_top = is_double ? 105 : 47;
                exponent_product = exponent_sum + 1;
            end else begin
                product_top = is_double ? 104 : 46;
                exponent_product = exponent_sum;
            end
            product_shift = ANCHOR - product_top;
            c_shift = ANCHOR - (p-1);
            product_mag = product << product_shift;
            c_mag = {64'd0, c_sig} << c_shift;

            if (exponent_product > exponent_c) begin
                distance = exponent_product - exponent_c;
                c_mag = shift_right_jam(c_mag, distance);
                exponent_result = exponent_product;
            end else if (exponent_c > exponent_product) begin
                distance = exponent_c - exponent_product;
                product_mag = shift_right_jam(product_mag, distance);
                exponent_result = exponent_c;
            end else begin
                exponent_result = exponent_product;
            end

            if (product_sign == c_sign) begin
                result_sign = product_sign;
                result_mag = product_mag + c_mag;
                if (result_mag[ANCHOR+1]) begin
                    result_mag = shift_right_jam(result_mag, 1);
                    exponent_result = exponent_result + 1;
                end
            end else if (product_mag > c_mag) begin
                result_sign = product_sign;
                result_mag = product_mag - c_mag;
            end else if (c_mag > product_mag) begin
                result_sign = c_sign;
                result_mag = c_mag - product_mag;
            end else begin
                result_sign =
                    (rounding_mode == `RV64_FP_RM_RDN);
                result_mag = 128'd0;
            end

            if ((product_sign != c_sign) && (result_mag != 0)) begin
                for (normalize_index = 0;
                     normalize_index < 121;
                     normalize_index = normalize_index + 1) begin
                    if (!result_mag[ANCHOR]) begin
                        result_mag = result_mag << 1;
                        exponent_result = exponent_result - 1;
                    end
                end
            end

            ext_result = shift_right_jam(
                result_mag,
                ANCHOR - (p+2)
            );
            add_product = round_pack(
                is_double,
                result_sign,
                exponent_result,
                ext_result,
                rounding_mode
            );
        end
    endfunction

    function automatic [EXEC_WIDTH-1:0] convert_to_integer;
        input is_double;
        input [4:0] integer_type;
        input [63:0] source;
        input [2:0] rounding_mode;
        integer p;
        integer integer_bits;
        integer shift_distance;
        reg integer_unsigned;
        reg type_valid;
        reg [UNPACK_WIDTH-1:0] info;
        reg sign;
        reg is_nan;
        reg is_inf;
        reg is_zero;
        reg signed [15:0] exponent;
        reg [63:0] significand;
        reg [127:0] magnitude;
        reg [127:0] rounded_magnitude;
        reg [127:0] remainder;
        reg [127:0] remainder_mask;
        reg [127:0] halfway;
        reg [127:0] maximum;
        reg inexact;
        reg increment;
        reg invalid;
        reg too_large;
        reg [63:0] result;
        reg [4:0] flags;
        begin
            p = is_double ? 53 : 24;
            integer_bits = 64;
            integer_unsigned = 1'b0;
            type_valid = 1'b1;
            case (integer_type)
                `RV64_FP_RS2_W: begin
                    integer_bits = 32;
                    integer_unsigned = 1'b0;
                end
                `RV64_FP_RS2_WU: begin
                    integer_bits = 32;
                    integer_unsigned = 1'b1;
                end
                `RV64_FP_RS2_L: begin
                    integer_bits = 64;
                    integer_unsigned = 1'b0;
                end
                `RV64_FP_RS2_LU: begin
                    integer_bits = 64;
                    integer_unsigned = 1'b1;
                end
                default: type_valid = 1'b0;
            endcase

            info = unpack_fp(is_double, source);
            sign = info[UNPACK_SIGN_BIT];
            is_zero = info[UNPACK_ZERO_BIT];
            is_inf = info[UNPACK_INF_BIT];
            is_nan = info[UNPACK_NAN_BIT];
            exponent = $signed(info[UNPACK_EXP_LO +: 16]);
            significand = info[UNPACK_SIG_LO +: 64];
            magnitude = 128'd0;
            rounded_magnitude = 128'd0;
            remainder = 128'd0;
            remainder_mask = 128'd0;
            halfway = 128'd0;
            maximum = 128'd0;
            inexact = 1'b0;
            increment = 1'b0;
            invalid = is_nan || is_inf;
            too_large = 1'b0;
            result = 64'd0;
            flags = 5'd0;

            if (!invalid && !is_zero) begin
                if (exponent >= (p-1)) begin
                    shift_distance = exponent - (p-1);
                    if (shift_distance >= 128) begin
                        too_large = 1'b1;
                    end else begin
                        magnitude = {64'd0, significand} <<
                                    shift_distance;
                    end
                end else begin
                    shift_distance = (p-1) - exponent;
                    if (shift_distance >= 128) begin
                        magnitude = 128'd0;
                        remainder = {64'd0, significand};
                        halfway = 128'd0;
                    end else begin
                        magnitude = {64'd0, significand} >>
                                    shift_distance;
                        remainder_mask =
                            {128{1'b1}} >> (128-shift_distance);
                        remainder = {64'd0, significand} &
                                    remainder_mask;
                        halfway = 128'd1 << (shift_distance-1);
                    end
                    inexact = remainder != 0;
                    case (rounding_mode)
                        `RV64_FP_RM_RNE:
                            increment = (halfway != 0) &&
                                ((remainder > halfway) ||
                                 ((remainder == halfway) &&
                                  magnitude[0]));
                        `RV64_FP_RM_RTZ: increment = 1'b0;
                        `RV64_FP_RM_RDN: increment = sign && inexact;
                        `RV64_FP_RM_RUP: increment = !sign && inexact;
                        `RV64_FP_RM_RMM:
                            increment = (halfway != 0) &&
                                        (remainder >= halfway);
                        default: increment = 1'b0;
                    endcase
                end
                rounded_magnitude = magnitude + increment;
            end

            if (integer_unsigned) begin
                maximum = (integer_bits == 32) ?
                    128'h0000_0000_0000_0000_0000_0000_ffff_ffff :
                    128'h0000_0000_0000_0000_ffff_ffff_ffff_ffff;
                if (too_large || (rounded_magnitude > maximum) ||
                    (sign && (rounded_magnitude != 0)))
                    invalid = 1'b1;
                if (invalid)
                    result = (sign && !is_nan) ? 64'd0 :
                             maximum[63:0];
                else
                    result = rounded_magnitude[63:0];
            end else begin
                maximum = 128'd1 << (integer_bits-1);
                if (too_large ||
                    (!sign && (rounded_magnitude >= maximum)) ||
                    (sign && (rounded_magnitude > maximum)))
                    invalid = 1'b1;
                if (invalid) begin
                    if (sign && !is_nan)
                        result = (integer_bits == 32) ?
                            64'h0000_0000_8000_0000 :
                            64'h8000_0000_0000_0000;
                    else
                        result = (integer_bits == 32) ?
                            64'h0000_0000_7fff_ffff :
                            64'h7fff_ffff_ffff_ffff;
                end else if (sign) begin
                    result = (~rounded_magnitude[63:0]) + 1'b1;
                end else begin
                    result = rounded_magnitude[63:0];
                end
            end

            if (integer_bits == 32)
                result = {{32{result[31]}}, result[31:0]};
            if (invalid)
                flags = `RV64_FP_FFLAG_NV;
            else if (inexact)
                flags = `RV64_FP_FFLAG_NX;

            convert_to_integer = {
                !type_valid,
                `OPENRV64_FP_RESULT_INT,
                type_valid ? flags : 5'd0,
                64'd0,
                type_valid ? result : 64'd0
            };
        end
    endfunction

    function automatic [EXEC_WIDTH-1:0] convert_from_integer;
        input is_double;
        input [4:0] integer_type;
        input [63:0] source;
        input [2:0] rounding_mode;
        integer p;
        integer highest_bit;
        integer scan_index;
        integer shift_distance;
        reg type_valid;
        reg sign;
        reg [63:0] magnitude;
        reg [127:0] ext_result;
        reg [68:0] rounded;
        begin
            p = is_double ? 53 : 24;
            type_valid = 1'b1;
            sign = 1'b0;
            magnitude = 64'd0;
            case (integer_type)
                `RV64_FP_RS2_W: begin
                    sign = source[31];
                    magnitude = source[31] ?
                        {32'd0, (~source[31:0]) + 1'b1} :
                        {32'd0, source[31:0]};
                end
                `RV64_FP_RS2_WU:
                    magnitude = {32'd0, source[31:0]};
                `RV64_FP_RS2_L: begin
                    sign = source[63];
                    magnitude = source[63] ? (~source) + 1'b1 : source;
                end
                `RV64_FP_RS2_LU:
                    magnitude = source;
                default: type_valid = 1'b0;
            endcase

            highest_bit = 0;
            for (scan_index = 0; scan_index < 64;
                 scan_index = scan_index + 1) begin
                if (magnitude[scan_index])
                    highest_bit = scan_index;
            end
            ext_result = 128'd0;
            rounded = {5'd0, fp_zero(is_double, sign)};
            if (magnitude != 0) begin
                if (highest_bit > (p+2)) begin
                    shift_distance = highest_bit - (p+2);
                    ext_result = shift_right_jam(
                        {64'd0, magnitude},
                        shift_distance
                    );
                end else begin
                    shift_distance = (p+2) - highest_bit;
                    ext_result = {64'd0, magnitude} << shift_distance;
                end
                rounded = round_pack(
                    is_double,
                    sign,
                    highest_bit,
                    ext_result,
                    rounding_mode
                );
            end

            convert_from_integer = {
                !type_valid,
                `OPENRV64_FP_RESULT_FP,
                type_valid ? rounded[68:64] : 5'd0,
                type_valid ? rounded[63:0] : 64'd0,
                64'd0
            };
        end
    endfunction

    function automatic [EXEC_WIDTH-1:0] convert_fp_format;
        input [1:0] destination_format;
        input [4:0] source_type;
        input [63:0] source;
        input [2:0] rounding_mode;
        integer source_p;
        integer destination_p;
        integer shift_distance;
        reg destination_double;
        reg source_double;
        reg type_valid;
        reg [UNPACK_WIDTH-1:0] info;
        reg sign;
        reg is_zero;
        reg is_inf;
        reg is_snan;
        reg is_nan;
        reg signed [15:0] exponent;
        reg [63:0] significand;
        reg [127:0] ext_result;
        reg [68:0] rounded;
        begin
            destination_double =
                destination_format == `RV64_FP_FMT_D;
            source_double = source_type == `RV64_FP_RS2_D;
            type_valid =
                ((source_type == `RV64_FP_RS2_S) ||
                 (source_type == `RV64_FP_RS2_D)) &&
                (source_double != destination_double);
            source_p = source_double ? 53 : 24;
            destination_p = destination_double ? 53 : 24;
            info = unpack_fp(source_double, source);
            sign = info[UNPACK_SIGN_BIT];
            is_zero = info[UNPACK_ZERO_BIT];
            is_inf = info[UNPACK_INF_BIT];
            is_snan = info[UNPACK_SNAN_BIT];
            is_nan = info[UNPACK_NAN_BIT];
            exponent = $signed(info[UNPACK_EXP_LO +: 16]);
            significand = info[UNPACK_SIG_LO +: 64];
            ext_result = 128'd0;
            rounded = {5'd0, fp_zero(destination_double, sign)};

            if (is_nan) begin
                rounded = {
                    is_snan ? `RV64_FP_FFLAG_NV : 5'd0,
                    fp_canonical_nan(destination_double)
                };
            end else if (is_inf) begin
                rounded = {
                    5'd0,
                    fp_infinity(destination_double, sign)
                };
            end else if (!is_zero) begin
                shift_distance =
                    (source_p-1) - (destination_p+2);
                if (shift_distance > 0)
                    ext_result = shift_right_jam(
                        {64'd0, significand},
                        shift_distance
                    );
                else
                    ext_result = {64'd0, significand} <<
                                 (-shift_distance);
                rounded = round_pack(
                    destination_double,
                    sign,
                    exponent,
                    ext_result,
                    rounding_mode
                );
            end

            convert_fp_format = {
                !type_valid,
                `OPENRV64_FP_RESULT_FP,
                type_valid ? rounded[68:64] : 5'd0,
                type_valid ? rounded[63:0] : 64'd0,
                64'd0
            };
        end
    endfunction

    function automatic [EXEC_WIDTH-1:0] execute_request;
        input [`OPENRV64_FP_OP_WIDTH-1:0] operation;
        input [1:0] format;
        input [2:0] instruction_rm;
        input [2:0] dynamic_rm;
        input [4:0] conversion_type;
        input [63:0] source1;
        input [63:0] source2;
        reg is_double;
        reg [2:0] effective_rm;
        reg [63:0] a;
        reg [63:0] b;
        reg sign_a;
        reg sign_b;
        reg [10:0] exponent_a;
        reg [10:0] exponent_b;
        reg [63:0] fraction_a;
        reg [63:0] fraction_b;
        reg nan_a;
        reg nan_b;
        reg snan_a;
        reg snan_b;
        reg zero_a;
        reg zero_b;
        reg less_than;
        reg equal;
        reg [9:0] class_result;
        reg [68:0] arithmetic;
        reg [63:0] fp_result;
        reg [63:0] int_result;
        reg [4:0] flags;
        reg result_is_int;
        reg unsupported;
        reg [EXEC_WIDTH-1:0] conversion_result;
        begin
            is_double = format == `RV64_FP_FMT_D;
            effective_rm = (instruction_rm == `RV64_FP_RM_DYN) ?
                           dynamic_rm : instruction_rm;
            a = is_double ? source1 : {32'd0, sanitize_single(source1)};
            b = is_double ? source2 : {32'd0, sanitize_single(source2)};
            sign_a = a[is_double ? 63 : 31];
            sign_b = b[is_double ? 63 : 31];
            exponent_a = is_double ? a[62:52] : {3'd0, a[30:23]};
            exponent_b = is_double ? b[62:52] : {3'd0, b[30:23]};
            fraction_a = is_double ? {12'd0, a[51:0]} :
                                     {41'd0, a[22:0]};
            fraction_b = is_double ? {12'd0, b[51:0]} :
                                     {41'd0, b[22:0]};
            nan_a = (is_double ? (&exponent_a[10:0]) :
                       (&exponent_a[7:0])) && (fraction_a != 0);
            nan_b = (is_double ? (&exponent_b[10:0]) :
                       (&exponent_b[7:0])) && (fraction_b != 0);
            snan_a = nan_a && !fraction_a[is_double ? 51 : 22];
            snan_b = nan_b && !fraction_b[is_double ? 51 : 22];
            zero_a = (exponent_a == 0) && (fraction_a == 0);
            zero_b = (exponent_b == 0) && (fraction_b == 0);
            fp_result = 64'd0;
            int_result = 64'd0;
            flags = 5'd0;
            result_is_int = `OPENRV64_FP_RESULT_FP;
            unsupported = (format != `RV64_FP_FMT_S) &&
                          (format != `RV64_FP_FMT_D);
            conversion_result = {EXEC_WIDTH{1'b0}};
            arithmetic = 69'd0;
            class_result = 10'd0;
            less_than = 1'b0;
            equal = 1'b0;

            case (operation)
                `OPENRV64_FP_OP_ADD,
                `OPENRV64_FP_OP_SUB: begin
                    if (effective_rm > `RV64_FP_RM_RMM) begin
                        unsupported = 1'b1;
                    end else begin
                        arithmetic = add_sub(
                            is_double,
                            operation == `OPENRV64_FP_OP_SUB,
                            source1, source2, effective_rm);
                        flags = arithmetic[68:64];
                        fp_result = arithmetic[63:0];
                    end
                end

                `OPENRV64_FP_OP_MUL:
                    unsupported = 1'b1;

                `OPENRV64_FP_OP_SGNJ,
                `OPENRV64_FP_OP_SGNJN,
                `OPENRV64_FP_OP_SGNJX: begin
                    if (operation == `OPENRV64_FP_OP_SGNJN)
                        sign_b = !sign_b;
                    else if (operation == `OPENRV64_FP_OP_SGNJX)
                        sign_b = sign_a ^ sign_b;
                    if (is_double)
                        fp_result = {sign_b, a[62:0]};
                    else
                        fp_result = {32'hffff_ffff, sign_b, a[30:0]};
                end

                `OPENRV64_FP_OP_MIN,
                `OPENRV64_FP_OP_MAX: begin
                    if (snan_a || snan_b)
                        flags = `RV64_FP_FFLAG_NV;
                    if (nan_a && nan_b) begin
                        fp_result = is_double ?
                            `RV64_FP_CANONICAL_NAN_D :
                            `RV64_FP_NANBOX_S(`RV64_FP_CANONICAL_NAN_S);
                    end else if (nan_a) begin
                        fp_result = is_double ? b :
                                    {32'hffff_ffff, b[31:0]};
                    end else if (nan_b) begin
                        fp_result = is_double ? a :
                                    {32'hffff_ffff, a[31:0]};
                    end else begin
                        if (zero_a && zero_b) begin
                            less_than = sign_a && !sign_b;
                            equal = 1'b1;
                        end else if (sign_a != sign_b) begin
                            less_than = sign_a;
                            equal = 1'b0;
                        end else begin
                            equal = a == b;
                            less_than = sign_a ? (a > b) : (a < b);
                        end
                        if (operation == `OPENRV64_FP_OP_MIN)
                            fp_result = less_than ? source1 :
                                        (equal && sign_a ? source1 : source2);
                        else
                            fp_result = less_than ? source2 :
                                        (equal && !sign_a ? source1 : source2);
                        if (!is_double)
                            fp_result[63:32] = 32'hffff_ffff;
                    end
                end

                `OPENRV64_FP_OP_EQ,
                `OPENRV64_FP_OP_LT,
                `OPENRV64_FP_OP_LE: begin
                    result_is_int = `OPENRV64_FP_RESULT_INT;
                    if (nan_a || nan_b) begin
                        int_result = 64'd0;
                        if ((operation != `OPENRV64_FP_OP_EQ) ||
                            snan_a || snan_b)
                            flags = `RV64_FP_FFLAG_NV;
                    end else begin
                        equal = (a == b) || (zero_a && zero_b);
                        if (zero_a && zero_b)
                            less_than = 1'b0;
                        else if (sign_a != sign_b)
                            less_than = sign_a;
                        else
                            less_than = sign_a ? (a > b) : (a < b);
                        case (operation)
                            `OPENRV64_FP_OP_EQ:
                                int_result = {63'd0, equal};
                            `OPENRV64_FP_OP_LT:
                                int_result = {63'd0, less_than};
                            default:
                                int_result = {63'd0,
                                              less_than || equal};
                        endcase
                    end
                end

                `OPENRV64_FP_OP_CLASS: begin
                    result_is_int = `OPENRV64_FP_RESULT_INT;
                    if (is_double ? (&exponent_a[10:0]) :
                                    (&exponent_a[7:0])) begin
                        if (fraction_a == 0)
                            class_result[sign_a ? 0 : 7] = 1'b1;
                        else if (fraction_a[is_double ? 51 : 22])
                            class_result[9] = 1'b1;
                        else
                            class_result[8] = 1'b1;
                    end else if (exponent_a == 0) begin
                        if (fraction_a == 0)
                            class_result[sign_a ? 3 : 4] = 1'b1;
                        else
                            class_result[sign_a ? 2 : 5] = 1'b1;
                    end else begin
                        class_result[sign_a ? 1 : 6] = 1'b1;
                    end
                    int_result = {54'd0, class_result};
                end

                `OPENRV64_FP_OP_MV_X_F: begin
                    result_is_int = `OPENRV64_FP_RESULT_INT;
                    int_result = is_double ? source1 :
                                 {{32{source1[31]}}, source1[31:0]};
                end

                `OPENRV64_FP_OP_MV_F_X: begin
                    fp_result = is_double ? source1 :
                                {32'hffff_ffff, source1[31:0]};
                end

                `OPENRV64_FP_OP_CVT_TO_INT: begin
                    if (effective_rm > `RV64_FP_RM_RMM) begin
                        unsupported = 1'b1;
                    end else begin
                        conversion_result = convert_to_integer(
                            is_double,
                            conversion_type,
                            source1,
                            effective_rm
                        );
                        unsupported =
                            conversion_result[EXEC_UNSUPPORTED_BIT];
                        result_is_int =
                            conversion_result[EXEC_IS_INT_BIT];
                        flags =
                            conversion_result[EXEC_FLAGS_LO +: 5];
                        fp_result =
                            conversion_result[EXEC_FP_LO +: 64];
                        int_result =
                            conversion_result[EXEC_INT_LO +: 64];
                    end
                end

                `OPENRV64_FP_OP_CVT_FROM_INT: begin
                    if (effective_rm > `RV64_FP_RM_RMM) begin
                        unsupported = 1'b1;
                    end else begin
                        conversion_result = convert_from_integer(
                            is_double,
                            conversion_type,
                            source1,
                            effective_rm
                        );
                        unsupported =
                            conversion_result[EXEC_UNSUPPORTED_BIT];
                        result_is_int =
                            conversion_result[EXEC_IS_INT_BIT];
                        flags =
                            conversion_result[EXEC_FLAGS_LO +: 5];
                        fp_result =
                            conversion_result[EXEC_FP_LO +: 64];
                        int_result =
                            conversion_result[EXEC_INT_LO +: 64];
                    end
                end

                `OPENRV64_FP_OP_CVT_FORMAT: begin
                    if (effective_rm > `RV64_FP_RM_RMM) begin
                        unsupported = 1'b1;
                    end else begin
                        conversion_result = convert_fp_format(
                            format,
                            conversion_type,
                            source1,
                            effective_rm
                        );
                        unsupported =
                            conversion_result[EXEC_UNSUPPORTED_BIT];
                        result_is_int =
                            conversion_result[EXEC_IS_INT_BIT];
                        flags =
                            conversion_result[EXEC_FLAGS_LO +: 5];
                        fp_result =
                            conversion_result[EXEC_FP_LO +: 64];
                        int_result =
                            conversion_result[EXEC_INT_LO +: 64];
                    end
                end

                `OPENRV64_FP_OP_DIV,
                `OPENRV64_FP_OP_SQRT,
                `OPENRV64_FP_OP_MADD,
                `OPENRV64_FP_OP_MSUB,
                `OPENRV64_FP_OP_NMSUB,
                `OPENRV64_FP_OP_NMADD: begin
                    unsupported = 1'b1;
                end

                default: begin
                    unsupported = 1'b1;
                end
            endcase

            execute_request = {
                unsupported,
                result_is_int,
                flags,
                fp_result,
                int_result
            };
        end
    endfunction

    function automatic [PAYLOAD_WIDTH-1:0] setup_request;
        input [`OPENRV64_FP_OP_WIDTH-1:0] operation;
        input [1:0] format;
        input [2:0] instruction_rm;
        input [2:0] dynamic_rm;
        input [4:0] conversion_type;
        input [63:0] source1;
        input [63:0] source2;
        input [63:0] source3;
        integer p;
        integer radicand_shift;
        reg is_double;
        reg [2:0] effective_rm;
        reg [UNPACK_WIDTH-1:0] a_info;
        reg [UNPACK_WIDTH-1:0] b_info;
        reg [UNPACK_WIDTH-1:0] c_info;
        reg sign_a;
        reg sign_b;
        reg sign_c;
        reg zero_a;
        reg zero_b;
        reg zero_c;
        reg inf_a;
        reg inf_b;
        reg inf_c;
        reg snan_a;
        reg snan_b;
        reg snan_c;
        reg nan_a;
        reg nan_b;
        reg nan_c;
        reg signed [15:0] exp_a;
        reg signed [15:0] exp_b;
        reg signed [15:0] work_exp;
        reg [63:0] sig_a;
        reg [63:0] sig_b;
        reg product_sign;
        reg c_sign_invert;
        reg effective_c_sign;
        reg invalid_multiply;
        reg [63:0] special_fp;
        reg [4:0] special_flags;
        reg [63:0] adjusted_sig;
        reg [31:0] sanitized_c;
        reg [PAYLOAD_WIDTH-1:0] payload;
        reg [EXEC_WIDTH-1:0] simple_exec;
        begin
            is_double = format == `RV64_FP_FMT_D;
            p = is_double ? 53 : 24;
            effective_rm = (instruction_rm == `RV64_FP_RM_DYN) ?
                           dynamic_rm : instruction_rm;
            a_info = unpack_fp(is_double, source1);
            b_info = unpack_fp(is_double, source2);
            c_info = unpack_fp(is_double, source3);
            sign_a = a_info[UNPACK_SIGN_BIT];
            sign_b = b_info[UNPACK_SIGN_BIT];
            sign_c = c_info[UNPACK_SIGN_BIT];
            zero_a = a_info[UNPACK_ZERO_BIT];
            zero_b = b_info[UNPACK_ZERO_BIT];
            zero_c = c_info[UNPACK_ZERO_BIT];
            inf_a = a_info[UNPACK_INF_BIT];
            inf_b = b_info[UNPACK_INF_BIT];
            inf_c = c_info[UNPACK_INF_BIT];
            snan_a = a_info[UNPACK_SNAN_BIT];
            snan_b = b_info[UNPACK_SNAN_BIT];
            snan_c = c_info[UNPACK_SNAN_BIT];
            nan_a = a_info[UNPACK_NAN_BIT];
            nan_b = b_info[UNPACK_NAN_BIT];
            nan_c = c_info[UNPACK_NAN_BIT];
            exp_a = $signed(a_info[UNPACK_EXP_LO +: 16]);
            exp_b = $signed(b_info[UNPACK_EXP_LO +: 16]);
            sig_a = a_info[UNPACK_SIG_LO +: 64];
            sig_b = b_info[UNPACK_SIG_LO +: 64];
            product_sign = sign_a ^ sign_b;
            c_sign_invert = 1'b0;
            effective_c_sign = sign_c;
            invalid_multiply =
                (inf_a && zero_b) || (zero_a && inf_b);
            special_fp = 64'd0;
            special_flags = 5'd0;
            adjusted_sig = 64'd0;
            sanitized_c = sanitize_single(source3);
            work_exp = 16'sd0;

            simple_exec = {
                1'b1,
                `OPENRV64_FP_RESULT_FP,
                5'd0,
                64'd0,
                64'd0
            };
            payload = {PAYLOAD_WIDTH{1'b0}};
            payload[PAY_EXEC_LO +: EXEC_WIDTH] = simple_exec;
            payload[PAY_SRC3_LO +: 64] = source3;
            payload[PAY_OP_LO +: `OPENRV64_FP_OP_WIDTH] = operation;
            payload[PAY_RM_LO +: 3] = effective_rm;
            payload[PAY_IS_DOUBLE_BIT] = is_double;

            if ((format == `RV64_FP_FMT_S ||
                 format == `RV64_FP_FMT_D) &&
                (effective_rm <= `RV64_FP_RM_RMM)) begin
                case (operation)
                    `OPENRV64_FP_OP_MUL: begin
                        payload[PAY_EXEC_LO +: EXEC_WIDTH] =
                            {EXEC_WIDTH{1'b0}};
                        if (nan_a || nan_b) begin
                            special_flags = (snan_a || snan_b) ?
                                `RV64_FP_FFLAG_NV : 5'd0;
                            special_fp = fp_canonical_nan(is_double);
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                special_flags,
                                special_fp,
                                64'd0
                            };
                        end else if (invalid_multiply) begin
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                `RV64_FP_FFLAG_NV,
                                fp_canonical_nan(is_double),
                                64'd0
                            };
                        end else if (inf_a || inf_b) begin
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                5'd0,
                                fp_infinity(is_double, product_sign),
                                64'd0
                            };
                        end else if (zero_a || zero_b) begin
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                5'd0,
                                fp_zero(is_double, product_sign),
                                64'd0
                            };
                        end else begin
                            payload[PAY_LONG_BIT] = 1'b1;
                            payload[PAY_SIGN_BIT] = product_sign;
                            payload[PAY_EXP_LO +: 16] =
                                exp_a + exp_b;
                            payload[PAY_STATE1_LO +: 128] =
                                {64'd0, sig_a};
                            payload[PAY_STATE2_LO +: 128] =
                                {64'd0, sig_b};
                        end
                    end

                    `OPENRV64_FP_OP_MADD,
                    `OPENRV64_FP_OP_MSUB,
                    `OPENRV64_FP_OP_NMSUB,
                    `OPENRV64_FP_OP_NMADD: begin
                        if ((operation == `OPENRV64_FP_OP_NMSUB) ||
                            (operation == `OPENRV64_FP_OP_NMADD))
                            product_sign = !product_sign;
                        c_sign_invert =
                            (operation == `OPENRV64_FP_OP_MSUB) ||
                            (operation == `OPENRV64_FP_OP_NMADD);
                        effective_c_sign = sign_c ^ c_sign_invert;
                        payload[PAY_EXEC_LO +: EXEC_WIDTH] =
                            {EXEC_WIDTH{1'b0}};
                        if (nan_a || nan_b || nan_c ||
                            invalid_multiply) begin
                            special_flags =
                                (snan_a || snan_b || snan_c ||
                                 invalid_multiply) ?
                                `RV64_FP_FFLAG_NV : 5'd0;
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                special_flags,
                                fp_canonical_nan(is_double),
                                64'd0
                            };
                        end else if ((inf_a || inf_b) && inf_c &&
                                     (product_sign != effective_c_sign)) begin
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                `RV64_FP_FFLAG_NV,
                                fp_canonical_nan(is_double),
                                64'd0
                            };
                        end else if (inf_a || inf_b) begin
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                5'd0,
                                fp_infinity(is_double, product_sign),
                                64'd0
                            };
                        end else if (inf_c) begin
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                5'd0,
                                fp_infinity(
                                    is_double,
                                    effective_c_sign
                                ),
                                64'd0
                            };
                        end else if (zero_a || zero_b) begin
                            if (zero_c) begin
                                special_fp = fp_zero(
                                    is_double,
                                    (product_sign ==
                                     effective_c_sign) ?
                                        product_sign :
                                        (effective_rm ==
                                         `RV64_FP_RM_RDN)
                                );
                            end else if (is_double) begin
                                special_fp = {
                                    effective_c_sign,
                                    source3[62:0]
                                };
                            end else begin
                                special_fp = {
                                    32'hffff_ffff,
                                    effective_c_sign,
                                    sanitized_c[30:0]
                                };
                            end
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                5'd0,
                                special_fp,
                                64'd0
                            };
                        end else begin
                            payload[PAY_LONG_BIT] = 1'b1;
                            payload[PAY_SIGN_BIT] = product_sign;
                            payload[PAY_C_INVERT_BIT] = c_sign_invert;
                            payload[PAY_EXP_LO +: 16] =
                                exp_a + exp_b;
                            payload[PAY_STATE1_LO +: 128] =
                                {64'd0, sig_a};
                            payload[PAY_STATE2_LO +: 128] =
                                {64'd0, sig_b};
                        end
                    end

                    `OPENRV64_FP_OP_DIV: begin
                        payload[PAY_EXEC_LO +: EXEC_WIDTH] =
                            {EXEC_WIDTH{1'b0}};
                        if (nan_a || nan_b) begin
                            special_flags = (snan_a || snan_b) ?
                                `RV64_FP_FFLAG_NV : 5'd0;
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                special_flags,
                                fp_canonical_nan(is_double),
                                64'd0
                            };
                        end else if ((inf_a && inf_b) ||
                                     (zero_a && zero_b)) begin
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                `RV64_FP_FFLAG_NV,
                                fp_canonical_nan(is_double),
                                64'd0
                            };
                        end else if (inf_a) begin
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                5'd0,
                                fp_infinity(
                                    is_double,
                                    sign_a ^ sign_b
                                ),
                                64'd0
                            };
                        end else if (inf_b || zero_a) begin
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                5'd0,
                                fp_zero(
                                    is_double,
                                    sign_a ^ sign_b
                                ),
                                64'd0
                            };
                        end else if (zero_b) begin
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                `RV64_FP_FFLAG_DZ,
                                fp_infinity(
                                    is_double,
                                    sign_a ^ sign_b
                                ),
                                64'd0
                            };
                        end else begin
                            work_exp = exp_a - exp_b;
                            payload[PAY_LONG_BIT] = 1'b1;
                            payload[PAY_SIGN_BIT] = sign_a ^ sign_b;
                            payload[PAY_STATE1_LO +: 128] =
                                {64'd0, sig_b};
                            if (sig_a < sig_b) begin
                                payload[PAY_STATE0_LO +: 128] =
                                    {63'd0, sig_a, 1'b0};
                                work_exp = work_exp - 16'sd1;
                            end else begin
                                payload[PAY_STATE0_LO +: 128] =
                                    {64'd0, sig_a};
                            end
                            payload[PAY_EXP_LO +: 16] = work_exp;
                            payload[PAY_COUNT_LO +: 7] = p + 2;
                        end
                    end

                    `OPENRV64_FP_OP_SQRT: begin
                        payload[PAY_EXEC_LO +: EXEC_WIDTH] =
                            {EXEC_WIDTH{1'b0}};
                        if (nan_a) begin
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                snan_a ? `RV64_FP_FFLAG_NV : 5'd0,
                                fp_canonical_nan(is_double),
                                64'd0
                            };
                        end else if (sign_a && !zero_a) begin
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                `RV64_FP_FFLAG_NV,
                                fp_canonical_nan(is_double),
                                64'd0
                            };
                        end else if (inf_a) begin
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                5'd0,
                                fp_infinity(is_double, 1'b0),
                                64'd0
                            };
                        end else if (zero_a) begin
                            payload[PAY_EXEC_LO +: EXEC_WIDTH] = {
                                1'b0,
                                `OPENRV64_FP_RESULT_FP,
                                5'd0,
                                fp_zero(is_double, sign_a),
                                64'd0
                            };
                        end else begin
                            adjusted_sig = sig_a;
                            work_exp = exp_a;
                            if (work_exp[0]) begin
                                adjusted_sig = adjusted_sig << 1;
                                work_exp = work_exp - 16'sd1;
                            end
                            radicand_shift = 127 - p;
                            payload[PAY_LONG_BIT] = 1'b1;
                            payload[PAY_SIGN_BIT] = 1'b0;
                            payload[PAY_EXP_LO +: 16] =
                                $signed(work_exp) >>> 1;
                            payload[PAY_STATE1_LO +: 128] =
                                {64'd0, adjusted_sig} <<
                                radicand_shift;
                            payload[PAY_COUNT_LO +: 7] = p + 2;
                        end
                    end

                    default: begin
                        simple_exec = execute_request(
                            operation,
                            format,
                            instruction_rm,
                            dynamic_rm,
                            conversion_type,
                            source1,
                            source2
                        );
                        payload[PAY_EXEC_LO +: EXEC_WIDTH] =
                            simple_exec;
                    end
                endcase
            end

            setup_request = payload;
        end
    endfunction

    function automatic [PAYLOAD_WIDTH-1:0] advance_iteration;
        input [PAYLOAD_WIDTH-1:0] payload_in;
        integer iteration;
        reg [`OPENRV64_FP_OP_WIDTH-1:0] operation;
        reg [127:0] state0;
        reg [127:0] state1;
        reg [127:0] state2;
        reg [127:0] partial;
        reg [127:0] shifted_remainder;
        reg [127:0] trial;
        reg [6:0] count;
        reg [3:0] digit;
        reg [1:0] radicand_pair;
        reg [PAYLOAD_WIDTH-1:0] payload;
        begin
            payload = payload_in;
            operation =
                payload_in[PAY_OP_LO +: `OPENRV64_FP_OP_WIDTH];
            state0 = payload_in[PAY_STATE0_LO +: 128];
            state1 = payload_in[PAY_STATE1_LO +: 128];
            state2 = payload_in[PAY_STATE2_LO +: 128];
            count = payload_in[PAY_COUNT_LO +: 7];

            if (payload_in[PAY_LONG_BIT]) begin
                case (operation)
                    `OPENRV64_FP_OP_MUL,
                    `OPENRV64_FP_OP_MADD,
                    `OPENRV64_FP_OP_MSUB,
                    `OPENRV64_FP_OP_NMSUB,
                    `OPENRV64_FP_OP_NMADD: begin
                        digit = state2[3:0];
                        partial = 128'd0;
                        if (digit[0])
                            partial = partial + state1;
                        if (digit[1])
                            partial = partial + (state1 << 1);
                        if (digit[2])
                            partial = partial + (state1 << 2);
                        if (digit[3])
                            partial = partial + (state1 << 3);
                        state0 = state0 + partial;
                        state1 = state1 << PIPELINE_ITER_BITS;
                        state2 = state2 >> PIPELINE_ITER_BITS;
                    end

                    `OPENRV64_FP_OP_DIV: begin
                        for (iteration = 0;
                             iteration < PIPELINE_ITER_BITS;
                             iteration = iteration + 1) begin
                            if (count != 0) begin
                                if (state0 >= state1) begin
                                    state0 = state0 - state1;
                                    state2[count] = 1'b1;
                                end
                                if (count > 1)
                                    state0 = state0 << 1;
                                else
                                    state2[0] = state0 != 0;
                                count = count - 1'b1;
                            end
                        end
                    end

                    `OPENRV64_FP_OP_SQRT: begin
                        for (iteration = 0;
                             iteration < PIPELINE_ITER_BITS;
                             iteration = iteration + 1) begin
                            if (count != 0) begin
                                radicand_pair = state1[127:126];
                                state1 = state1 << 2;
                                shifted_remainder =
                                    (state0 << 2) |
                                    {126'd0, radicand_pair};
                                trial = (state2 << 2) | 128'd1;
                                if (shifted_remainder >= trial) begin
                                    state0 =
                                        shifted_remainder - trial;
                                    state2 = (state2 << 1) | 128'd1;
                                end else begin
                                    state0 = shifted_remainder;
                                    state2 = state2 << 1;
                                end
                                count = count - 1'b1;
                            end
                        end
                    end

                    default: begin
                    end
                endcase
            end

            payload[PAY_STATE0_LO +: 128] = state0;
            payload[PAY_STATE1_LO +: 128] = state1;
            payload[PAY_STATE2_LO +: 128] = state2;
            payload[PAY_COUNT_LO +: 7] = count;
            advance_iteration = payload;
        end
    endfunction

    function automatic [EXEC_WIDTH-1:0] finalize_payload;
        input [PAYLOAD_WIDTH-1:0] payload;
        reg [`OPENRV64_FP_OP_WIDTH-1:0] operation;
        reg is_double;
        reg sign;
        reg c_sign_invert;
        reg signed [15:0] exponent;
        reg [2:0] rounding_mode;
        reg [127:0] state0;
        reg [127:0] state2;
        reg [127:0] ext_result;
        reg [68:0] rounded;
        begin
            operation =
                payload[PAY_OP_LO +: `OPENRV64_FP_OP_WIDTH];
            is_double = payload[PAY_IS_DOUBLE_BIT];
            sign = payload[PAY_SIGN_BIT];
            c_sign_invert = payload[PAY_C_INVERT_BIT];
            exponent = $signed(payload[PAY_EXP_LO +: 16]);
            rounding_mode = payload[PAY_RM_LO +: 3];
            state0 = payload[PAY_STATE0_LO +: 128];
            state2 = payload[PAY_STATE2_LO +: 128];
            rounded = 69'd0;
            ext_result = 128'd0;

            if (!payload[PAY_LONG_BIT]) begin
                finalize_payload =
                    payload[PAY_EXEC_LO +: EXEC_WIDTH];
            end else begin
                case (operation)
                    `OPENRV64_FP_OP_MUL:
                        rounded = round_product(
                            is_double,
                            sign,
                            exponent,
                            state0,
                            rounding_mode
                        );

                    `OPENRV64_FP_OP_MADD,
                    `OPENRV64_FP_OP_MSUB,
                    `OPENRV64_FP_OP_NMSUB,
                    `OPENRV64_FP_OP_NMADD:
                        rounded = add_product(
                            is_double,
                            sign,
                            c_sign_invert,
                            exponent,
                            state0,
                            payload[PAY_SRC3_LO +: 64],
                            rounding_mode
                        );

                    `OPENRV64_FP_OP_DIV:
                        rounded = round_pack(
                            is_double,
                            sign,
                            exponent,
                            state2,
                            rounding_mode
                        );

                    `OPENRV64_FP_OP_SQRT: begin
                        ext_result = state2 << 1;
                        ext_result[0] =
                            ext_result[0] | (state0 != 0);
                        rounded = round_pack(
                            is_double,
                            sign,
                            exponent,
                            ext_result,
                            rounding_mode
                        );
                    end

                    default:
                        rounded = 69'd0;
                endcase
                finalize_payload = {
                    1'b0,
                    `OPENRV64_FP_RESULT_FP,
                    rounded[68:64],
                    rounded[63:0],
                    64'd0
                };
            end
        end
    endfunction

    reg [PIPELINE_ITER_STAGES:0] pipeline_valid_q;
    reg [TAG_WIDTH-1:0] pipeline_tag_q
        [0:PIPELINE_ITER_STAGES];
    reg [PAYLOAD_WIDTH-1:0] pipeline_payload_q
        [0:PIPELINE_ITER_STAGES];
    wire [PIPELINE_ITER_STAGES:0] pipeline_ready;
    wire [PIPELINE_ITER_STAGES-1:0] pipeline_forward_valid;
    wire [PAYLOAD_WIDTH-1:0] advanced_payload
        [0:PIPELINE_ITER_STAGES-1];
    wire [PAYLOAD_WIDTH-1:0] input_payload = setup_request(
        op_i,
        fmt_i,
        rm_i,
        frm_i,
        type_i,
        src1_i,
        src2_i,
        src3_i
    );
    wire input_needs_iteration = input_payload[PAY_LONG_BIT];
    wire [EXEC_WIDTH-1:0] input_exec =
        input_payload[PAY_EXEC_LO +: EXEC_WIDTH];

    wire [EXEC_WIDTH-1:0] final_exec = finalize_payload(
        pipeline_payload_q[PIPELINE_ITER_STAGES]
    );

    wire mul_s_result_valid =
        pipeline_valid_q[MUL_S_RESULT_STAGE] &&
        (pipeline_payload_q[MUL_S_RESULT_STAGE][
            PAY_OP_LO +: `OPENRV64_FP_OP_WIDTH] ==
         `OPENRV64_FP_OP_MUL) &&
        !pipeline_payload_q[MUL_S_RESULT_STAGE][PAY_IS_DOUBLE_BIT];
    wire sqrt_s_result_valid =
        pipeline_valid_q[SQRT_S_RESULT_STAGE] &&
        (pipeline_payload_q[SQRT_S_RESULT_STAGE][
            PAY_OP_LO +: `OPENRV64_FP_OP_WIDTH] ==
         `OPENRV64_FP_OP_SQRT) &&
        !pipeline_payload_q[SQRT_S_RESULT_STAGE][PAY_IS_DOUBLE_BIT];
    wire [68:0] mul_s_rounded = round_product(
        1'b0,
        pipeline_payload_q[MUL_S_RESULT_STAGE][PAY_SIGN_BIT],
        $signed(pipeline_payload_q[MUL_S_RESULT_STAGE][
            PAY_EXP_LO +: 16]),
        pipeline_payload_q[MUL_S_RESULT_STAGE][
            PAY_STATE0_LO +: 128],
        pipeline_payload_q[MUL_S_RESULT_STAGE][PAY_RM_LO +: 3]
    );
    wire [EXEC_WIDTH-1:0] mul_s_exec = {
        1'b0,
        `OPENRV64_FP_RESULT_FP,
        mul_s_rounded[68:64],
        mul_s_rounded[63:0],
        64'd0
    };
    wire [127:0] sqrt_s_ext_shifted =
        pipeline_payload_q[SQRT_S_RESULT_STAGE][
            PAY_STATE2_LO +: 128] << 1;
    wire [127:0] sqrt_s_ext = {
        sqrt_s_ext_shifted[127:1],
        sqrt_s_ext_shifted[0] |
            (pipeline_payload_q[SQRT_S_RESULT_STAGE][
                PAY_STATE0_LO +: 128] != 0)
    };
    wire [68:0] sqrt_s_rounded = round_pack(
        1'b0,
        pipeline_payload_q[SQRT_S_RESULT_STAGE][PAY_SIGN_BIT],
        $signed(pipeline_payload_q[SQRT_S_RESULT_STAGE][
            PAY_EXP_LO +: 16]),
        sqrt_s_ext,
        pipeline_payload_q[SQRT_S_RESULT_STAGE][PAY_RM_LO +: 3]
    );
    wire [EXEC_WIDTH-1:0] sqrt_s_exec = {
        1'b0,
        `OPENRV64_FP_RESULT_FP,
        sqrt_s_rounded[68:64],
        sqrt_s_rounded[63:0],
        64'd0
    };

    reg fast_valid_q;
    reg [TAG_WIDTH-1:0] fast_tag_q;
    reg [EXEC_WIDTH-1:0] fast_exec_q;

    wire [3:0] result_source_valid = {
        pipeline_valid_q[PIPELINE_ITER_STAGES],
        sqrt_s_result_valid,
        mul_s_result_valid,
        fast_valid_q
    };
    reg [1:0] result_prefer_q;
    reg result_lock_q;
    reg [1:0] result_lock_source_q;
    reg result_unlocked_valid;
    reg [1:0] result_unlocked_source;

    always @* begin
        result_unlocked_valid = 1'b0;
        result_unlocked_source = RESULT_SOURCE_FAST;
        case (result_prefer_q)
            RESULT_SOURCE_FAST: begin
                if (result_source_valid[RESULT_SOURCE_FAST]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_FAST;
                end else if (result_source_valid[RESULT_SOURCE_MUL_S]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_MUL_S;
                end else if (result_source_valid[RESULT_SOURCE_SQRT_S]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_SQRT_S;
                end else if (result_source_valid[RESULT_SOURCE_FINAL]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_FINAL;
                end
            end

            RESULT_SOURCE_MUL_S: begin
                if (result_source_valid[RESULT_SOURCE_MUL_S]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_MUL_S;
                end else if (result_source_valid[RESULT_SOURCE_SQRT_S]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_SQRT_S;
                end else if (result_source_valid[RESULT_SOURCE_FINAL]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_FINAL;
                end else if (result_source_valid[RESULT_SOURCE_FAST]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_FAST;
                end
            end

            RESULT_SOURCE_SQRT_S: begin
                if (result_source_valid[RESULT_SOURCE_SQRT_S]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_SQRT_S;
                end else if (result_source_valid[RESULT_SOURCE_FINAL]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_FINAL;
                end else if (result_source_valid[RESULT_SOURCE_FAST]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_FAST;
                end else if (result_source_valid[RESULT_SOURCE_MUL_S]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_MUL_S;
                end
            end

            default: begin
                if (result_source_valid[RESULT_SOURCE_FINAL]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_FINAL;
                end else if (result_source_valid[RESULT_SOURCE_FAST]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_FAST;
                end else if (result_source_valid[RESULT_SOURCE_MUL_S]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_MUL_S;
                end else if (result_source_valid[RESULT_SOURCE_SQRT_S]) begin
                    result_unlocked_valid = 1'b1;
                    result_unlocked_source = RESULT_SOURCE_SQRT_S;
                end
            end
        endcase
    end

    wire [1:0] result_source = result_lock_q ?
        result_lock_source_q : result_unlocked_source;
    wire result_valid = result_lock_q || result_unlocked_valid;
    reg [TAG_WIDTH-1:0] selected_result_tag;
    reg [EXEC_WIDTH-1:0] selected_result_exec;

    always @* begin
        selected_result_tag = {TAG_WIDTH{1'b0}};
        selected_result_exec = {EXEC_WIDTH{1'b0}};
        case (result_source)
            RESULT_SOURCE_FAST: begin
                selected_result_tag = fast_tag_q;
                selected_result_exec = fast_exec_q;
            end
            RESULT_SOURCE_MUL_S: begin
                selected_result_tag =
                    pipeline_tag_q[MUL_S_RESULT_STAGE];
                selected_result_exec = mul_s_exec;
            end
            RESULT_SOURCE_SQRT_S: begin
                selected_result_tag =
                    pipeline_tag_q[SQRT_S_RESULT_STAGE];
                selected_result_exec = sqrt_s_exec;
            end
            default: begin
                selected_result_tag =
                    pipeline_tag_q[PIPELINE_ITER_STAGES];
                selected_result_exec = final_exec;
            end
        endcase
    end

    wire result_fire = result_valid && result_ready_i && !flush_i;
    wire fast_result_pop =
        result_fire && (result_source == RESULT_SOURCE_FAST);
    wire mul_s_result_pop =
        result_fire && (result_source == RESULT_SOURCE_MUL_S);
    wire sqrt_s_result_pop =
        result_fire && (result_source == RESULT_SOURCE_SQRT_S);
    wire final_result_pop =
        result_fire && (result_source == RESULT_SOURCE_FINAL);
    wire fast_ready = !fast_valid_q || fast_result_pop;

    assign pipeline_ready[PIPELINE_ITER_STAGES] =
        !pipeline_valid_q[PIPELINE_ITER_STAGES] || final_result_pop;

    genvar pipeline_stage;
    generate
        for (pipeline_stage = 0;
             pipeline_stage < PIPELINE_ITER_STAGES;
             pipeline_stage = pipeline_stage + 1) begin : g_fpu_pipeline
            if (pipeline_stage == MUL_S_RESULT_STAGE) begin : g_mul_s_tap
                assign pipeline_ready[pipeline_stage] =
                    !pipeline_valid_q[pipeline_stage] ||
                    (mul_s_result_valid ? mul_s_result_pop :
                     pipeline_ready[pipeline_stage+1]);
                assign pipeline_forward_valid[pipeline_stage] =
                    pipeline_valid_q[pipeline_stage] &&
                    !mul_s_result_valid;
            end else if (pipeline_stage == SQRT_S_RESULT_STAGE) begin : g_sqrt_s_tap
                assign pipeline_ready[pipeline_stage] =
                    !pipeline_valid_q[pipeline_stage] ||
                    (sqrt_s_result_valid ? sqrt_s_result_pop :
                     pipeline_ready[pipeline_stage+1]);
                assign pipeline_forward_valid[pipeline_stage] =
                    pipeline_valid_q[pipeline_stage] &&
                    !sqrt_s_result_valid;
            end else begin : g_regular_stage
                assign pipeline_ready[pipeline_stage] =
                    !pipeline_valid_q[pipeline_stage] ||
                    pipeline_ready[pipeline_stage+1];
                assign pipeline_forward_valid[pipeline_stage] =
                    pipeline_valid_q[pipeline_stage];
            end
            assign advanced_payload[pipeline_stage] =
                advance_iteration(pipeline_payload_q[pipeline_stage]);
        end
    endgenerate

    assign ready_o = !flush_i && (input_needs_iteration ?
        pipeline_ready[0] : fast_ready);
    wire iterative_input_fire =
        valid_i && ready_o && input_needs_iteration;
    wire fast_input_fire =
        valid_i && ready_o && !input_needs_iteration;

    assign result_valid_o = result_valid && !flush_i;
    assign result_tag_o = selected_result_tag;
    assign int_result_o = selected_result_exec[EXEC_INT_LO +: 64];
    assign fp_result_o = selected_result_exec[EXEC_FP_LO +: 64];
    assign fflags_o = selected_result_exec[EXEC_FLAGS_LO +: 5];
    assign result_is_int_o = selected_result_exec[EXEC_IS_INT_BIT];
    assign unsupported_o =
        selected_result_exec[EXEC_UNSUPPORTED_BIT];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fast_valid_q <= 1'b0;
            fast_tag_q <= {TAG_WIDTH{1'b0}};
            fast_exec_q <= {EXEC_WIDTH{1'b0}};
        end else if (flush_i) begin
            fast_valid_q <= 1'b0;
        end else if (fast_ready) begin
            fast_valid_q <= fast_input_fire;
            if (fast_input_fire) begin
                fast_tag_q <= tag_i;
                fast_exec_q <= input_exec;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_prefer_q <= RESULT_SOURCE_FAST;
            result_lock_q <= 1'b0;
            result_lock_source_q <= RESULT_SOURCE_FAST;
        end else if (flush_i) begin
            result_prefer_q <= RESULT_SOURCE_FAST;
            result_lock_q <= 1'b0;
        end else begin
            if (result_lock_q) begin
                if (result_fire)
                    result_lock_q <= 1'b0;
            end else if (result_valid && !result_ready_i) begin
                result_lock_q <= 1'b1;
                result_lock_source_q <= result_unlocked_source;
            end

            if (result_fire)
                result_prefer_q <= result_source + 2'd1;
        end
    end

    integer pipeline_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipeline_valid_q <=
                {(PIPELINE_ITER_STAGES+1){1'b0}};
            for (pipeline_index = 0;
                 pipeline_index <= PIPELINE_ITER_STAGES;
                 pipeline_index = pipeline_index + 1) begin
                pipeline_tag_q[pipeline_index] <=
                    {TAG_WIDTH{1'b0}};
                pipeline_payload_q[pipeline_index] <=
                    {PAYLOAD_WIDTH{1'b0}};
            end
        end else if (flush_i) begin
            pipeline_valid_q <=
                {(PIPELINE_ITER_STAGES+1){1'b0}};
        end else begin
            for (pipeline_index = PIPELINE_ITER_STAGES;
                 pipeline_index > 0;
                 pipeline_index = pipeline_index - 1) begin
                if (pipeline_ready[pipeline_index]) begin
                    pipeline_valid_q[pipeline_index] <=
                        pipeline_forward_valid[pipeline_index-1];
                    if (pipeline_forward_valid[pipeline_index-1]) begin
                        pipeline_tag_q[pipeline_index] <=
                            pipeline_tag_q[pipeline_index-1];
                        pipeline_payload_q[pipeline_index] <=
                            advanced_payload[pipeline_index-1];
                    end
                end
            end

            if (pipeline_ready[0]) begin
                pipeline_valid_q[0] <= iterative_input_fire;
                if (iterative_input_fire) begin
                    pipeline_tag_q[0] <= tag_i;
                    pipeline_payload_q[0] <= input_payload;
                end
            end
        end
    end

endmodule

`endif
