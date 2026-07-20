`ifndef OPENRV64_EXEC_FPU_RV64_FD_V
`define OPENRV64_EXEC_FPU_RV64_FD_V
`timescale 1ns/1ps
`include "core/isa/rv64-d.v"
`include "core/exec/fpu/defs.v"

// Standalone, fully backpressured RV64F/RV64D starter pipeline.
//
// Accepted operations can enter every cycle.  Stage 0 captures the request,
// stage 1 executes and rounds, and stage 2 holds the response.  This module is
// deliberately not wired to decode, an F register file, fcsr, retirement, or
// the LSU yet.
//
// Implemented: ADD, SUB, MUL, SGNJ/SGNJN/SGNJX, MIN/MAX, EQ/LT/LE, CLASS,
// FMV.X.{W,D}, and FMV.{W,D}.X.  DIV, SQRT, FMA, and conversions return an
// explicit unsupported response so integration cannot mistake them for valid
// arithmetic.
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

    function automatic [68:0] multiply;
        input is_double;
        input [63:0] source1;
        input [63:0] source2;
        input [2:0] rounding_mode;
        integer p;
        integer fraction_bits;
        integer bias;
        integer exp_a;
        integer exp_b;
        integer exponent;
        integer shift_distance;
        integer normalize_index;
        reg [63:0] a;
        reg [63:0] b;
        reg sign_result;
        reg [10:0] field_a;
        reg [10:0] field_b;
        reg [63:0] fraction_a;
        reg [63:0] fraction_b;
        reg [63:0] sig_a;
        reg [63:0] sig_b;
        reg [127:0] product;
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
            sign_result = a[is_double ? 63 : 31] ^
                          b[is_double ? 63 : 31];
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
                multiply = {special_flags, special_result};
            end else if ((inf_a && zero_b) || (inf_b && zero_a)) begin
                multiply = {`RV64_FP_FFLAG_NV, special_result};
            end else if (inf_a || inf_b) begin
                special_result = is_double ?
                    {sign_result, 11'h7ff, 52'd0} :
                    {32'hffff_ffff, sign_result, 8'hff, 23'd0};
                multiply = {5'd0, special_result};
            end else if (zero_a || zero_b) begin
                special_result = is_double ? {sign_result, 63'd0} :
                    {32'hffff_ffff, sign_result, 31'd0};
                multiply = {5'd0, special_result};
            end else begin
                if (field_a == 0) begin
                    exp_a = 1 - bias;
                    sig_a = fraction_a;
                    for (normalize_index = 0;
                         normalize_index < 64;
                         normalize_index = normalize_index + 1) begin
                        if (!sig_a[p-1]) begin
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
                        if (!sig_b[p-1]) begin
                            sig_b = sig_b << 1;
                            exp_b = exp_b - 1;
                        end
                    end
                end else begin
                    exp_b = field_b;
                    exp_b = exp_b - bias;
                    sig_b = (64'd1 << (p-1)) | fraction_b;
                end

                product = sig_a * sig_b;
                if (product[2*p-1]) begin
                    exponent = exp_a + exp_b + 1;
                    shift_distance = p - 3;
                end else begin
                    exponent = exp_a + exp_b;
                    shift_distance = p - 4;
                end
                ext_result = shift_right_jam(product, shift_distance);
                multiply = round_pack(is_double, sign_result, exponent,
                                      ext_result, rounding_mode);
            end
        end
    endfunction

    function automatic [EXEC_WIDTH-1:0] execute_request;
        input [`OPENRV64_FP_OP_WIDTH-1:0] operation;
        input [1:0] format;
        input [2:0] instruction_rm;
        input [2:0] dynamic_rm;
        input [63:0] source1;
        input [63:0] source2;
        input [63:0] source3;
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
            arithmetic = 69'd0;
            class_result = 10'd0;
            less_than = 1'b0;
            equal = 1'b0;

            case (operation)
                `OPENRV64_FP_OP_ADD,
                `OPENRV64_FP_OP_SUB,
                `OPENRV64_FP_OP_MUL: begin
                    if (effective_rm > `RV64_FP_RM_RMM) begin
                        unsupported = 1'b1;
                    end else if (operation == `OPENRV64_FP_OP_MUL) begin
                        arithmetic = multiply(is_double, source1, source2,
                                              effective_rm);
                        flags = arithmetic[68:64];
                        fp_result = arithmetic[63:0];
                    end else begin
                        arithmetic = add_sub(
                            is_double,
                            operation == `OPENRV64_FP_OP_SUB,
                            source1, source2, effective_rm);
                        flags = arithmetic[68:64];
                        fp_result = arithmetic[63:0];
                    end
                end

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

                `OPENRV64_FP_OP_DIV,
                `OPENRV64_FP_OP_SQRT,
                `OPENRV64_FP_OP_CVT_TO_INT,
                `OPENRV64_FP_OP_CVT_FROM_INT,
                `OPENRV64_FP_OP_CVT_FORMAT,
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

    reg s0_valid_q;
    reg [TAG_WIDTH-1:0] s0_tag_q;
    reg [`OPENRV64_FP_OP_WIDTH-1:0] s0_op_q;
    reg [1:0] s0_fmt_q;
    reg [2:0] s0_rm_q;
    reg [2:0] s0_frm_q;
    reg [63:0] s0_src1_q;
    reg [63:0] s0_src2_q;
    reg [63:0] s0_src3_q;

    reg s1_valid_q;
    reg [TAG_WIDTH-1:0] s1_tag_q;
    reg [EXEC_WIDTH-1:0] s1_exec_q;

    reg s2_valid_q;
    reg [TAG_WIDTH-1:0] s2_tag_q;
    reg [EXEC_WIDTH-1:0] s2_exec_q;

    wire s2_ready = !s2_valid_q || result_ready_i;
    wire s1_ready = !s1_valid_q || s2_ready;
    wire s0_ready = !s0_valid_q || s1_ready;
    wire [EXEC_WIDTH-1:0] s0_execute = execute_request(
        s0_op_q, s0_fmt_q, s0_rm_q, s0_frm_q,
        s0_src1_q, s0_src2_q, s0_src3_q);

    assign ready_o = s0_ready;
    assign result_valid_o = s2_valid_q;
    assign result_tag_o = s2_tag_q;
    assign int_result_o = s2_exec_q[EXEC_INT_LO +: 64];
    assign fp_result_o = s2_exec_q[EXEC_FP_LO +: 64];
    assign fflags_o = s2_exec_q[EXEC_FLAGS_LO +: 5];
    assign result_is_int_o = s2_exec_q[EXEC_IS_INT_BIT];
    assign unsupported_o = s2_exec_q[EXEC_UNSUPPORTED_BIT];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid_q <= 1'b0;
            s1_valid_q <= 1'b0;
            s2_valid_q <= 1'b0;
            s0_tag_q <= {TAG_WIDTH{1'b0}};
            s1_tag_q <= {TAG_WIDTH{1'b0}};
            s2_tag_q <= {TAG_WIDTH{1'b0}};
            s0_op_q <= `OPENRV64_FP_OP_INVALID;
            s0_fmt_q <= `RV64_FP_FMT_S;
            s0_rm_q <= `RV64_FP_RM_RNE;
            s0_frm_q <= `RV64_FP_RM_RNE;
            s0_src1_q <= 64'd0;
            s0_src2_q <= 64'd0;
            s0_src3_q <= 64'd0;
            s1_exec_q <= {EXEC_WIDTH{1'b0}};
            s2_exec_q <= {EXEC_WIDTH{1'b0}};
        end else if (flush_i) begin
            s0_valid_q <= 1'b0;
            s1_valid_q <= 1'b0;
            s2_valid_q <= 1'b0;
        end else begin
            if (s2_ready) begin
                s2_valid_q <= s1_valid_q;
                if (s1_valid_q) begin
                    s2_tag_q <= s1_tag_q;
                    s2_exec_q <= s1_exec_q;
                end
            end

            if (s1_ready) begin
                s1_valid_q <= s0_valid_q;
                if (s0_valid_q) begin
                    s1_tag_q <= s0_tag_q;
                    s1_exec_q <= s0_execute;
                end
            end

            if (s0_ready) begin
                s0_valid_q <= valid_i;
                if (valid_i) begin
                    s0_tag_q <= tag_i;
                    s0_op_q <= op_i;
                    s0_fmt_q <= fmt_i;
                    s0_rm_q <= rm_i;
                    s0_frm_q <= frm_i;
                    s0_src1_q <= src1_i;
                    s0_src2_q <= src2_i;
                    s0_src3_q <= src3_i;
                end
            end
        end
    end

endmodule

`endif
