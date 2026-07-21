`timescale 1ns/1ps
`include "core/exec/vec/defs.v"

// FP32 execution lane used by the narrow vector formats.  FP4, FP8 and BF16
// operands are expanded exactly to FP32, operated on here, and then rounded
// to their destination format.  This is faithful for the implemented BF16
// add and multiply operations. The MAC mode keeps narrow products in FP32
// through the add, then rounds once to the accumulator format. FP32 MAC still
// rounds its product before addition and is not an IEEE fused FMA. There is no
// FP64 datapath in this module.
module openrv64_exec_vec_fp32_lane #(
    parameter integer TAG_WIDTH = 2,
    parameter integer PIPELINE_STAGES = 11
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     flush_i,
    input  wire                     valid_i,
    output wire                     ready_o,
    input  wire [TAG_WIDTH-1:0]     tag_i,
    input  wire                     multiply_i,
    input  wire                     mac_i,
    input  wire [31:0]              src1_i,
    input  wire [31:0]              src2_i,
    input  wire [31:0]              src3_i,
    output wire                     result_valid_o,
    input  wire                     result_ready_i,
    output wire [TAG_WIDTH-1:0]     result_tag_o,
    output wire [31:0]              result_o
);

    function automatic [63:0] shift_right_jam;
        input [63:0] value;
        input integer distance;
        reg [63:0] mask;
        reg sticky;
        begin
            if (distance <= 0) begin
                shift_right_jam = value;
            end else if (distance >= 64) begin
                shift_right_jam = {63'd0, |value};
            end else begin
                mask = ({64{1'b1}} >> (64 - distance));
                sticky = |(value & mask);
                shift_right_jam = value >> distance;
                shift_right_jam[0] = shift_right_jam[0] | sticky;
            end
        end
    endfunction

    // sig_ext has the normalized 24-bit significand above three RNE bits.
    function automatic [31:0] round_pack;
        input sign;
        input integer exponent_in;
        input [63:0] sig_ext_in;
        integer exponent;
        integer distance;
        integer biased_exponent;
        reg [63:0] work;
        reg [31:0] main_sig;
        reg guard_bit;
        reg round_bit;
        reg sticky_bit;
        reg increment;
        reg tiny;
        begin
            exponent = exponent_in;
            work = sig_ext_in;
            if (work == 0) begin
                round_pack = {sign, 31'd0};
            end else begin
                if (exponent < -126) begin
                    distance = -126 - exponent;
                    work = shift_right_jam(work, distance);
                    exponent = -126;
                end

                main_sig = work >> 3;
                guard_bit = work[2];
                round_bit = work[1];
                sticky_bit = work[0];
                increment = guard_bit &&
                            (round_bit || sticky_bit || main_sig[0]);
                if (increment)
                    main_sig = main_sig + 1'b1;
                if (main_sig[24]) begin
                    main_sig = main_sig >> 1;
                    exponent = exponent + 1;
                end

                if (exponent > 127) begin
                    round_pack = {sign, 8'hff, 23'd0};
                end else begin
                    tiny = (exponent == -126) && !main_sig[23];
                    biased_exponent = exponent + 127;
                    round_pack = {sign,
                                  tiny ? 8'd0 : biased_exponent[7:0],
                                  main_sig[22:0]};
                end
            end
        end
    endfunction

    function automatic [31:0] add_fp32;
        input [31:0] a;
        input [31:0] b;
        integer exp_a;
        integer exp_b;
        integer exponent;
        integer distance;
        integer normalize_index;
        reg sign_a;
        reg sign_b;
        reg sign_result;
        reg [7:0] field_a;
        reg [7:0] field_b;
        reg [22:0] fraction_a;
        reg [22:0] fraction_b;
        reg [31:0] sig_a;
        reg [31:0] sig_b;
        reg [63:0] ext_a;
        reg [63:0] ext_b;
        reg [63:0] ext_result;
        reg nan_a;
        reg nan_b;
        reg inf_a;
        reg inf_b;
        reg zero_a;
        reg zero_b;
        begin
            sign_a = a[31];
            sign_b = b[31];
            field_a = a[30:23];
            field_b = b[30:23];
            fraction_a = a[22:0];
            fraction_b = b[22:0];
            nan_a = (&field_a) && (fraction_a != 0);
            nan_b = (&field_b) && (fraction_b != 0);
            inf_a = (&field_a) && (fraction_a == 0);
            inf_b = (&field_b) && (fraction_b == 0);
            zero_a = (field_a == 0) && (fraction_a == 0);
            zero_b = (field_b == 0) && (fraction_b == 0);

            if (nan_a || nan_b ||
                (inf_a && inf_b && (sign_a != sign_b))) begin
                add_fp32 = 32'h7fc0_0000;
            end else if (inf_a) begin
                add_fp32 = {sign_a, 8'hff, 23'd0};
            end else if (inf_b) begin
                add_fp32 = {sign_b, 8'hff, 23'd0};
            end else if (zero_a && zero_b) begin
                add_fp32 = {sign_a && sign_b, 31'd0};
            end else if (zero_a) begin
                add_fp32 = b;
            end else if (zero_b) begin
                add_fp32 = a;
            end else begin
                if (field_a == 0) begin
                    exp_a = -126;
                    sig_a = {9'd0, fraction_a};
                    for (normalize_index = 0; normalize_index < 24;
                         normalize_index = normalize_index + 1) begin
                        if ((sig_a != 0) && !sig_a[23]) begin
                            sig_a = sig_a << 1;
                            exp_a = exp_a - 1;
                        end
                    end
                end else begin
                    exp_a = field_a - 127;
                    sig_a = {8'd0, 1'b1, fraction_a};
                end
                if (field_b == 0) begin
                    exp_b = -126;
                    sig_b = {9'd0, fraction_b};
                    for (normalize_index = 0; normalize_index < 24;
                         normalize_index = normalize_index + 1) begin
                        if ((sig_b != 0) && !sig_b[23]) begin
                            sig_b = sig_b << 1;
                            exp_b = exp_b - 1;
                        end
                    end
                end else begin
                    exp_b = field_b - 127;
                    sig_b = {8'd0, 1'b1, fraction_b};
                end

                ext_a = {32'd0, sig_a} << 3;
                ext_b = {32'd0, sig_b} << 3;
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
                    if (ext_result[27]) begin
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
                    sign_result = 1'b0;
                    ext_result = 64'd0;
                end

                if ((sign_a != sign_b) && (ext_result != 0)) begin
                    for (normalize_index = 0; normalize_index < 24;
                         normalize_index = normalize_index + 1) begin
                        if (!ext_result[26]) begin
                            ext_result = ext_result << 1;
                            exponent = exponent - 1;
                        end
                    end
                end
                add_fp32 = round_pack(sign_result, exponent, ext_result);
            end
        end
    endfunction

    function automatic [31:0] multiply_fp32;
        input [31:0] a;
        input [31:0] b;
        integer exp_a;
        integer exp_b;
        integer exponent;
        integer shift_distance;
        integer normalize_index;
        reg sign_result;
        reg [7:0] field_a;
        reg [7:0] field_b;
        reg [22:0] fraction_a;
        reg [22:0] fraction_b;
        reg [31:0] sig_a;
        reg [31:0] sig_b;
        reg [63:0] product;
        reg [63:0] ext_result;
        reg nan_a;
        reg nan_b;
        reg inf_a;
        reg inf_b;
        reg zero_a;
        reg zero_b;
        begin
            sign_result = a[31] ^ b[31];
            field_a = a[30:23];
            field_b = b[30:23];
            fraction_a = a[22:0];
            fraction_b = b[22:0];
            nan_a = (&field_a) && (fraction_a != 0);
            nan_b = (&field_b) && (fraction_b != 0);
            inf_a = (&field_a) && (fraction_a == 0);
            inf_b = (&field_b) && (fraction_b == 0);
            zero_a = (field_a == 0) && (fraction_a == 0);
            zero_b = (field_b == 0) && (fraction_b == 0);

            if (nan_a || nan_b ||
                ((inf_a && zero_b) || (inf_b && zero_a))) begin
                multiply_fp32 = 32'h7fc0_0000;
            end else if (inf_a || inf_b) begin
                multiply_fp32 = {sign_result, 8'hff, 23'd0};
            end else if (zero_a || zero_b) begin
                multiply_fp32 = {sign_result, 31'd0};
            end else if (a == 32'h3f80_0000) begin
                multiply_fp32 = b;
            end else if (b == 32'h3f80_0000) begin
                multiply_fp32 = a;
            end else if (a == 32'hbf80_0000) begin
                multiply_fp32 = {~b[31], b[30:0]};
            end else if (b == 32'hbf80_0000) begin
                multiply_fp32 = {~a[31], a[30:0]};
            end else begin
                if (field_a == 0) begin
                    exp_a = -126;
                    sig_a = {9'd0, fraction_a};
                    for (normalize_index = 0; normalize_index < 24;
                         normalize_index = normalize_index + 1) begin
                        if (!sig_a[23]) begin
                            sig_a = sig_a << 1;
                            exp_a = exp_a - 1;
                        end
                    end
                end else begin
                    exp_a = field_a - 127;
                    sig_a = {8'd0, 1'b1, fraction_a};
                end
                if (field_b == 0) begin
                    exp_b = -126;
                    sig_b = {9'd0, fraction_b};
                    for (normalize_index = 0; normalize_index < 24;
                         normalize_index = normalize_index + 1) begin
                        if (!sig_b[23]) begin
                            sig_b = sig_b << 1;
                            exp_b = exp_b - 1;
                        end
                    end
                end else begin
                    exp_b = field_b - 127;
                    sig_b = {8'd0, 1'b1, fraction_b};
                end

                product = sig_a * sig_b;
                if (product[47]) begin
                    exponent = exp_a + exp_b + 1;
                    shift_distance = 21;
                end else begin
                    exponent = exp_a + exp_b;
                    shift_distance = 20;
                end
                ext_result = shift_right_jam(product, shift_distance);
                multiply_fp32 = round_pack(sign_result, exponent,
                                           ext_result);
            end
        end
    endfunction

    reg [PIPELINE_STAGES-1:0] valid_q;
    reg [PIPELINE_STAGES-1:0] mac_mode_q;
    reg [TAG_WIDTH-1:0] tag_q [0:PIPELINE_STAGES-1];
    reg [31:0] result_q [0:PIPELINE_STAGES-1];
    reg [31:0] acc_q [0:PIPELINE_STAGES-1];
    localparam integer MAC_ADD_STAGE = PIPELINE_STAGES / 2;

    // A globally stalled token pipeline preserves one-slice-per-cycle
    // throughput while keeping tags aligned. MAC tokens compute and register
    // their product at stage zero, then cross a second registered add boundary
    // halfway through the pipe. PIPELINE_STAGES is a timing implementation
    // parameter, not architectural state.
    wire pipeline_advance = !valid_q[PIPELINE_STAGES-1] || result_ready_i;
    assign ready_o = pipeline_advance;
    assign result_valid_o = valid_q[PIPELINE_STAGES-1];
    assign result_tag_o = tag_q[PIPELINE_STAGES-1];
    assign result_o = result_q[PIPELINE_STAGES-1];

    integer pipeline_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_q <= {PIPELINE_STAGES{1'b0}};
            mac_mode_q <= {PIPELINE_STAGES{1'b0}};
            for (pipeline_index = 0; pipeline_index < PIPELINE_STAGES;
                 pipeline_index = pipeline_index + 1) begin
                tag_q[pipeline_index] <= {TAG_WIDTH{1'b0}};
                result_q[pipeline_index] <= 32'd0;
                acc_q[pipeline_index] <= 32'd0;
            end
        end else if (flush_i) begin
            valid_q <= {PIPELINE_STAGES{1'b0}};
            mac_mode_q <= {PIPELINE_STAGES{1'b0}};
        end else if (pipeline_advance) begin
            for (pipeline_index = PIPELINE_STAGES - 1;
                 pipeline_index > 0;
                 pipeline_index = pipeline_index - 1) begin
                valid_q[pipeline_index] <= valid_q[pipeline_index-1];
                mac_mode_q[pipeline_index] <=
                    mac_mode_q[pipeline_index-1];
                tag_q[pipeline_index] <= tag_q[pipeline_index-1];
                result_q[pipeline_index] <= result_q[pipeline_index-1];
                acc_q[pipeline_index] <= acc_q[pipeline_index-1];
            end
            valid_q[0] <= valid_i;
            mac_mode_q[0] <= valid_i && mac_i;
            tag_q[0] <= tag_i;
            if (valid_i) begin
                result_q[0] <= (mac_i || multiply_i) ?
                    multiply_fp32(src1_i, src2_i) :
                    add_fp32(src1_i, src2_i);
                acc_q[0] <= src3_i;
            end
            if (valid_q[MAC_ADD_STAGE-1] &&
                mac_mode_q[MAC_ADD_STAGE-1])
                result_q[MAC_ADD_STAGE] <= add_fp32(
                    acc_q[MAC_ADD_STAGE-1],
                    result_q[MAC_ADD_STAGE-1]);
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (PIPELINE_STAGES < 2)
            $fatal(1, "FP lane pipeline must have at least two stages");
    end
`endif

endmodule

// Isolated 64-bit-per-cycle vector arithmetic engine.  Dispatch supplies only
// vector register indices and a tag.  The local register-file wiring supplies
// operand values; the result leaves this unit only on the private retirement
// writeback port.  A captured command is never requested again from dispatch:
// if its operands are unavailable it remains pending and replay_o is asserted.
module openrv64_exec_vec #(
    parameter integer VLEN = 256,
    parameter integer DATAPATH_WIDTH = 64,
    parameter integer REG_ADDR_WIDTH = 5,
    parameter integer TAG_WIDTH = 8,
    parameter integer NUM_REGS = 32,
    parameter integer MAX_LMUL = 8,
    parameter integer LMUL_WIDTH = 2,
    parameter integer FP_PIPELINE_STAGES = 11,
    parameter integer MAC_PIPELINE_STAGES = 22,
    parameter integer INFLIGHT_DEPTH = 8,
    parameter integer SLICE_ADDR_WIDTH =
        ((VLEN / DATAPATH_WIDTH) <= 1) ? 1 :
        $clog2(VLEN / DATAPATH_WIDTH)
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         dispatch_valid_i,
    output wire                         dispatch_ready_o,
    input  wire [TAG_WIDTH-1:0]         dispatch_tag_i,
    input  wire [`OPENRV64_VEC_OP_WIDTH-1:0] dispatch_op_i,
    input  wire                         dispatch_acc_i,
    input  wire [`OPENRV64_VEC_VTYPE_WIDTH-1:0] dispatch_vtype_i,
    input  wire [REG_ADDR_WIDTH-1:0]    dispatch_vs1_i,
    input  wire [REG_ADDR_WIDTH-1:0]    dispatch_vs2_i,
    input  wire [REG_ADDR_WIDTH-1:0]    dispatch_vd_i,

    output wire [1:0]                   rf_read_valid_o,
    input  wire [1:0]                   rf_read_ready_i,
    output wire [2*REG_ADDR_WIDTH-1:0]  rf_read_addr_o,
    output wire [2*SLICE_ADDR_WIDTH-1:0] rf_read_slice_o,
    input  wire [2*DATAPATH_WIDTH-1:0]  rf_read_data_i,
    input  wire                         operands_ready_i,

    output wire                         complete_valid_o,
    input  wire                         complete_ready_i,
    output wire [TAG_WIDTH-1:0]         complete_tag_o,
    output wire                         complete_unsupported_o,

    // kill may be presented for a pending or executing command.  A normal
    // commit is accepted only after completion has been observed.
    input  wire                         retire_valid_i,
    output wire                         retire_ready_o,
    input  wire [TAG_WIDTH-1:0]         retire_tag_i,
    input  wire                         retire_kill_i,

    output wire                         rf_write_valid_o,
    input  wire                         rf_write_ready_i,
    output wire [REG_ADDR_WIDTH-1:0]    rf_write_addr_o,
    output wire [SLICE_ADDR_WIDTH-1:0]  rf_write_slice_o,
    output wire [DATAPATH_WIDTH-1:0]    rf_write_data_o,

    output wire                         replay_o,
    output wire                         busy_o
);

    localparam integer GROUP_WIDTH = VLEN * MAX_LMUL;
    localparam integer BASE_CHUNKS = VLEN / DATAPATH_WIDTH;
    localparam integer CHUNKS = GROUP_WIDTH / DATAPATH_WIDTH;
    localparam integer CHUNK_INDEX_WIDTH =
        (CHUNKS <= 1) ? 1 : $clog2(CHUNKS);
    localparam integer SLICE_INDEX_WIDTH =
        (BASE_CHUNKS <= 1) ? 1 : $clog2(BASE_CHUNKS);
    localparam integer FP_LANES = DATAPATH_WIDTH / 4;

    localparam [2:0] STATE_IDLE = 3'd0;
    localparam [2:0] STATE_BIT_EXEC = 3'd1;
    localparam [2:0] STATE_FP_FEED = 3'd2;
    localparam [2:0] STATE_FP_DRAIN = 3'd3;
    localparam [2:0] STATE_COMPLETE = 3'd4;
    localparam [2:0] STATE_WRITEBACK = 3'd5;

    function automatic [31:0] fp4_to_fp32;
        input [3:0] value;
        integer exponent;
        integer normalize_index;
        reg [1:0] significand;
        reg [7:0] fp_exponent;
        begin
            if (value[2:0] == 0) begin
                fp4_to_fp32 = {value[3], 31'd0};
            end else begin
                if (value[2:1] == 0) begin
                    exponent = 0;
                    significand = {1'b0, value[0]};
                    for (normalize_index = 0; normalize_index < 2;
                         normalize_index = normalize_index + 1) begin
                        if (!significand[1]) begin
                            significand = significand << 1;
                            exponent = exponent - 1;
                        end
                    end
                end else begin
                    exponent = value[2:1] - 1;
                    significand = {1'b1, value[0]};
                end
                fp_exponent = exponent + 127;
                fp4_to_fp32 = {value[3], fp_exponent,
                               significand[0], 22'd0};
            end
        end
    endfunction

    function automatic [31:0] fp8_to_fp32;
        input [7:0] value;
        integer exponent;
        integer normalize_index;
        reg [3:0] significand;
        reg [7:0] fp_exponent;
        begin
            if ((value[6:3] == 4'hf) && (value[2:0] == 3'h7)) begin
                fp8_to_fp32 = 32'h7fc0_0000;
            end else if (value[6:0] == 0) begin
                fp8_to_fp32 = {value[7], 31'd0};
            end else begin
                if (value[6:3] == 0) begin
                    exponent = -6;
                    significand = {1'b0, value[2:0]};
                    for (normalize_index = 0; normalize_index < 4;
                         normalize_index = normalize_index + 1) begin
                        if (!significand[3]) begin
                            significand = significand << 1;
                            exponent = exponent - 1;
                        end
                    end
                end else begin
                    exponent = value[6:3] - 7;
                    significand = {1'b1, value[2:0]};
                end
                fp_exponent = exponent + 127;
                fp8_to_fp32 = {value[7], fp_exponent,
                               significand[2:0], 20'd0};
            end
        end
    endfunction

    function automatic [24:0] round_shift24;
        input [23:0] value;
        input integer distance;
        reg [24:0] base;
        reg guard_bit;
        reg sticky_bit;
        reg [23:0] lower_mask;
        begin
            base = 25'd0;
            guard_bit = 1'b0;
            sticky_bit = 1'b0;
            lower_mask = 24'd0;
            if (distance <= 0) begin
                base = {1'b0, value} << (-distance);
            end else if (distance > 24) begin
                base = 25'd0;
            end else begin
                base = value >> distance;
                guard_bit = value[distance-1];
                if (distance > 1) begin
                    lower_mask = {24{1'b1}} >> (25 - distance);
                    sticky_bit = |(value & lower_mask);
                end
                if (guard_bit && (sticky_bit || base[0]))
                    base = base + 1'b1;
            end
            round_shift24 = base;
        end
    endfunction

    function automatic [3:0] fp32_to_fp4;
        input [31:0] value;
        integer exponent;
        reg [24:0] rounded;
        reg [2:0] magnitude;
        reg [1:0] encoded_exponent;
        begin
            magnitude = 3'd0;
            if (value[30:23] == 8'hff) begin
                magnitude = 3'b111;
            end else if ((value[30:23] == 0) || (value[30:0] == 0)) begin
                magnitude = 3'd0;
            end else begin
                exponent = value[30:23] - 127;
                if (exponent < 0) begin
                    rounded = round_shift24({1'b1, value[22:0]},
                                            22 - exponent);
                    if (rounded >= 2)
                        magnitude = 3'b010;
                    else
                        magnitude = {2'b00, rounded[0]};
                end else begin
                    rounded = round_shift24({1'b1, value[22:0]}, 22);
                    if (rounded >= 4) begin
                        rounded = rounded >> 1;
                        exponent = exponent + 1;
                    end
                    if (exponent > 2)
                        magnitude = 3'b111;
                    else
                        encoded_exponent = exponent + 1;
                        magnitude = {encoded_exponent, rounded[0]};
                end
            end
            fp32_to_fp4 = {value[31], magnitude};
        end
    endfunction

    function automatic [7:0] fp32_to_fp8;
        input [31:0] value;
        integer exponent;
        reg [24:0] rounded;
        reg [6:0] magnitude;
        reg [3:0] encoded_exponent;
        begin
            magnitude = 7'd0;
            if ((value[30:23] == 8'hff) && (value[22:0] != 0)) begin
                magnitude = 7'h7f;
            end else if (value[30:23] == 8'hff) begin
                magnitude = 7'h7e;
            end else if ((value[30:23] == 0) || (value[30:0] == 0)) begin
                magnitude = 7'd0;
            end else begin
                exponent = value[30:23] - 127;
                if (exponent < -6) begin
                    rounded = round_shift24({1'b1, value[22:0]},
                                            14 - exponent);
                    if (rounded >= 8)
                        magnitude = 7'h08;
                    else
                        magnitude = {4'd0, rounded[2:0]};
                end else begin
                    rounded = round_shift24({1'b1, value[22:0]}, 20);
                    if (rounded >= 16) begin
                        rounded = rounded >> 1;
                        exponent = exponent + 1;
                    end
                    if ((exponent > 8) ||
                        ((exponent == 8) && (rounded > 14))) begin
                        magnitude = 7'h7e;
                    end else begin
                        encoded_exponent = exponent + 7;
                        magnitude = {encoded_exponent, rounded[2:0]};
                    end
                end
            end
            fp32_to_fp8 = {value[31], magnitude};
        end
    endfunction

    function automatic [15:0] fp32_to_bf16;
        input [31:0] value;
        reg [32:0] rounded;
        begin
            if ((value[30:23] == 8'hff) && (value[22:0] != 0)) begin
                fp32_to_bf16 = 16'h7fc0;
            end else begin
                rounded = {1'b0, value} + 33'h0000_07fff + value[16];
                fp32_to_bf16 = rounded[31:16];
            end
        end
    endfunction

    function automatic [31:0] lane_to_fp32;
        input [DATAPATH_WIDTH-1:0] chunk;
        input [`OPENRV64_VEC_FMT_WIDTH-1:0] format;
        input integer lane;
        reg [DATAPATH_WIDTH-1:0] shifted;
        begin
            case (format)
                `OPENRV64_VEC_FMT_FP4_E2M1: begin
                    shifted = chunk >> (lane * 4);
                    lane_to_fp32 = fp4_to_fp32(shifted[3:0]);
                end
                `OPENRV64_VEC_FMT_FP8_E4M3: begin
                    shifted = chunk >> (lane * 8);
                    lane_to_fp32 = (lane < 8) ?
                                   fp8_to_fp32(shifted[7:0]) : 32'd0;
                end
                `OPENRV64_VEC_FMT_BF16: begin
                    shifted = chunk >> (lane * 16);
                    lane_to_fp32 = (lane < 4) ?
                                   {shifted[15:0], 16'd0} : 32'd0;
                end
                `OPENRV64_VEC_FMT_FP32: begin
                    shifted = chunk >> (lane * 32);
                    lane_to_fp32 = (lane < 2) ? shifted[31:0] : 32'd0;
                end
                default: lane_to_fp32 = 32'd0;
            endcase
        end
    endfunction

`ifdef OPENRV64_VEC_SERIAL_CONTROLLER
    reg pending_valid_q;
    reg [TAG_WIDTH-1:0] pending_tag_q;
    reg [`OPENRV64_VEC_OP_WIDTH-1:0] pending_op_q;
    reg [`OPENRV64_VEC_VTYPE_WIDTH-1:0] pending_vtype_q;
    reg [REG_ADDR_WIDTH-1:0] pending_vs1_q;
    reg [REG_ADDR_WIDTH-1:0] pending_vs2_q;
    reg [REG_ADDR_WIDTH-1:0] pending_vd_q;

    reg active_valid_q;
    reg [TAG_WIDTH-1:0] active_tag_q;
    reg [`OPENRV64_VEC_OP_WIDTH-1:0] active_op_q;
    reg [`OPENRV64_VEC_FMT_WIDTH-1:0] active_fmt_q;
    reg [LMUL_WIDTH-1:0] active_lmul_q;
    reg [REG_ADDR_WIDTH-1:0] active_vs1_q;
    reg [REG_ADDR_WIDTH-1:0] active_vs2_q;
    reg [REG_ADDR_WIDTH-1:0] active_vd_q;
    reg active_unsupported_q;
    reg [DATAPATH_WIDTH-1:0] result_slice_q [0:CHUNKS-1];
    reg [CHUNK_INDEX_WIDTH-1:0] feed_index_q;
    reg [CHUNK_INDEX_WIDTH-1:0] bit_index_q;
    reg [CHUNK_INDEX_WIDTH-1:0] write_index_q;
    reg [CHUNK_INDEX_WIDTH:0] fp_result_count_q;
    reg fp_feed_done_q;
    reg [2:0] state_q;
    reg complete_sent_q;

    assign dispatch_ready_o = !pending_valid_q;
    wire dispatch_fire = dispatch_valid_i && dispatch_ready_o;
    wire unit_idle = state_q == STATE_IDLE;
    wire start_pending = pending_valid_q && unit_idle && operands_ready_i;

    wire [2:0] pending_vlmul = pending_vtype_q[
        `OPENRV64_VEC_VTYPE_VLMUL_LSB +: 3];
    wire [LMUL_WIDTH-1:0] pending_lmul =
        pending_vlmul[LMUL_WIDTH-1:0];
    wire pending_bit_op = (pending_op_q == `OPENRV64_VEC_OP_AND) ||
                          (pending_op_q == `OPENRV64_VEC_OP_OR) ||
                          (pending_op_q == `OPENRV64_VEC_OP_XOR) ||
                          (pending_op_q == `OPENRV64_VEC_OP_NOT);
    wire pending_fp_op = (pending_op_q == `OPENRV64_VEC_OP_FADD) ||
                         (pending_op_q == `OPENRV64_VEC_OP_FMUL);
    wire [2:0] pending_vsew = pending_vtype_q[
        `OPENRV64_VEC_VTYPE_VSEW_LSB +: 3];
    wire [`OPENRV64_VEC_VTYPE_XFMT_WIDTH-1:0] pending_xfmt =
        pending_vtype_q[`OPENRV64_VEC_VTYPE_XFMT_LSB +:
                        `OPENRV64_VEC_VTYPE_XFMT_WIDTH];
    reg [`OPENRV64_VEC_FMT_WIDTH-1:0] pending_fmt;
    reg pending_fmt_supported;
    always @* begin
        pending_fmt = `OPENRV64_VEC_FMT_FP4_E2M1;
        pending_fmt_supported = 1'b1;
        case (pending_xfmt)
            `OPENRV64_VEC_XFMT_FP32: begin
                pending_fmt = `OPENRV64_VEC_FMT_FP32;
                pending_fmt_supported = pending_vsew ==
                                        `OPENRV64_VEC_VSEW_E32;
            end
            `OPENRV64_VEC_XFMT_BF16: begin
                pending_fmt = `OPENRV64_VEC_FMT_BF16;
                pending_fmt_supported = pending_vsew ==
                                        `OPENRV64_VEC_VSEW_E16;
            end
            `OPENRV64_VEC_XFMT_FP8_E4M3: begin
                pending_fmt = `OPENRV64_VEC_FMT_FP8_E4M3;
                pending_fmt_supported = pending_vsew ==
                                        `OPENRV64_VEC_VSEW_E8;
            end
            `OPENRV64_VEC_XFMT_FP4_E2M1: begin
                pending_fmt = `OPENRV64_VEC_FMT_FP4_E2M1;
                pending_fmt_supported = pending_vsew ==
                                        `OPENRV64_VEC_VSEW_E8;
            end
            default: pending_fmt_supported = 1'b0;
        endcase
    end

    wire pending_lmul_supported = !pending_vlmul[2];
    wire [REG_ADDR_WIDTH:0] pending_group_count =
        {{REG_ADDR_WIDTH{1'b0}}, 1'b1} << pending_lmul;
    wire [REG_ADDR_WIDTH:0] pending_group_mask =
        pending_group_count - 1'b1;
    wire pending_vs1_valid =
        (({1'b0, pending_vs1_q} & pending_group_mask) == 0) &&
        (({1'b0, pending_vs1_q} + pending_group_count) <= NUM_REGS);
    wire pending_vs2_valid =
        (({1'b0, pending_vs2_q} & pending_group_mask) == 0) &&
        (({1'b0, pending_vs2_q} + pending_group_count) <= NUM_REGS);
    wire pending_vd_valid =
        (({1'b0, pending_vd_q} & pending_group_mask) == 0) &&
        (({1'b0, pending_vd_q} + pending_group_count) <= NUM_REGS);
    wire pending_vtype_common_valid =
        !pending_vtype_q[`OPENRV64_VEC_VTYPE_VILL_BIT] &&
        (pending_vtype_q[62:11] == 0) && pending_lmul_supported;
    wire pending_unsupported = !pending_vtype_common_valid ||
        !pending_vs1_valid || !pending_vs2_valid || !pending_vd_valid ||
        (!pending_bit_op && !(pending_fp_op && pending_fmt_supported));

    wire [CHUNK_INDEX_WIDTH:0] active_chunk_count =
        BASE_CHUNKS << active_lmul_q;
    wire [CHUNK_INDEX_WIDTH-1:0] execution_index =
        (state_q == STATE_BIT_EXEC) ? bit_index_q : feed_index_q;
    wire [REG_ADDR_WIDTH-1:0] execution_reg_offset =
        execution_index / BASE_CHUNKS;
    wire [SLICE_INDEX_WIDTH-1:0] execution_slice =
        execution_index % BASE_CHUNKS;
    wire execution_reads = (state_q == STATE_BIT_EXEC) ||
                           (state_q == STATE_FP_FEED);

    wire [FP_LANES-1:0] lane_ready;
    wire all_lane_ready = &lane_ready;
    wire [DATAPATH_WIDTH-1:0] fp_src1_chunk =
        rf_read_data_i[0*DATAPATH_WIDTH +: DATAPATH_WIDTH];
    wire [DATAPATH_WIDTH-1:0] fp_src2_chunk =
        rf_read_data_i[1*DATAPATH_WIDTH +: DATAPATH_WIDTH];
    // A completely zero slice can complete without entering any FP lane.
    // More general per-lane early completion requires a lane-result merge.
    wire fp_zero_early = (fp_src1_chunk == 0) && (fp_src2_chunk == 0);
    wire bit_needs_src2 = active_op_q != `OPENRV64_VEC_OP_NOT;
    assign rf_read_valid_o[0] = execution_reads &&
        ((state_q == STATE_BIT_EXEC) || fp_zero_early || all_lane_ready);
    assign rf_read_valid_o[1] = rf_read_valid_o[0] &&
        ((state_q == STATE_FP_FEED) || bit_needs_src2);
    assign rf_read_addr_o = {
        active_vs2_q + execution_reg_offset,
        active_vs1_q + execution_reg_offset};
    assign rf_read_slice_o = {2{execution_slice}};
    wire rf_reads_ready = rf_read_ready_i[0] &&
        (!rf_read_valid_o[1] || rf_read_ready_i[1]);
    wire bit_exec_fire = (state_q == STATE_BIT_EXEC) &&
                         rf_read_valid_o[0] && rf_reads_ready;

    wire [DATAPATH_WIDTH-1:0] bit_src1_chunk =
        rf_read_data_i[0*DATAPATH_WIDTH +: DATAPATH_WIDTH];
    wire [DATAPATH_WIDTH-1:0] bit_src2_chunk =
        rf_read_data_i[1*DATAPATH_WIDTH +: DATAPATH_WIDTH];
    reg [DATAPATH_WIDTH-1:0] bit_result_chunk;
    always @* begin
        case (active_op_q)
            `OPENRV64_VEC_OP_AND:
                bit_result_chunk = bit_src1_chunk & bit_src2_chunk;
            `OPENRV64_VEC_OP_OR:
                bit_result_chunk = bit_src1_chunk | bit_src2_chunk;
            `OPENRV64_VEC_OP_XOR:
                bit_result_chunk = bit_src1_chunk ^ bit_src2_chunk;
            `OPENRV64_VEC_OP_NOT:
                bit_result_chunk = ~bit_src1_chunk;
            default:
                bit_result_chunk = {DATAPATH_WIDTH{1'b0}};
        endcase
    end

    wire fp_feed_valid = (state_q == STATE_FP_FEED) && rf_reads_ready &&
                         !fp_zero_early;
    wire fp_multiply = active_op_q == `OPENRV64_VEC_OP_FMUL;
    wire [FP_LANES-1:0] lane_result_valid;
    wire [CHUNK_INDEX_WIDTH-1:0] lane_result_tag [0:FP_LANES-1];
    wire [31:0] lane_result [0:FP_LANES-1];
    wire lane_result_ready = (state_q == STATE_FP_FEED) ||
                             (state_q == STATE_FP_DRAIN);
    wire fp_lane_feed_fire = fp_feed_valid && all_lane_ready;
    wire fp_early_fire = (state_q == STATE_FP_FEED) && rf_reads_ready &&
                         fp_zero_early;
    wire fp_feed_fire = fp_lane_feed_fire || fp_early_fire;
    wire fp_result_fire = lane_result_valid[0] && lane_result_ready;
    wire fp_last_feed = fp_feed_fire &&
        (feed_index_q == active_chunk_count - 1'b1);
    wire [1:0] fp_completion_events = fp_early_fire + fp_result_fire;
    wire [CHUNK_INDEX_WIDTH:0] fp_result_count_next =
        fp_result_count_q + fp_completion_events;
    wire fp_all_results =
        (fp_feed_done_q || fp_last_feed) &&
        (fp_result_count_next == active_chunk_count);
    wire fp_lane_flush;

    genvar lane_index;
    generate
        for (lane_index = 0; lane_index < FP_LANES;
             lane_index = lane_index + 1) begin : g_fp_lane
            wire [31:0] lane_src1 = lane_to_fp32(
                fp_src1_chunk, active_fmt_q, lane_index);
            wire [31:0] lane_src2 = lane_to_fp32(
                fp_src2_chunk, active_fmt_q, lane_index);
            openrv64_exec_vec_fp32_lane #(
                .TAG_WIDTH(CHUNK_INDEX_WIDTH),
                .PIPELINE_STAGES(FP_PIPELINE_STAGES)
            ) u_lane (
                .clk(clk), .rst_n(rst_n), .flush_i(fp_lane_flush),
                .valid_i(fp_feed_valid), .ready_o(lane_ready[lane_index]),
                .tag_i(feed_index_q), .multiply_i(fp_multiply),
                .mac_i(1'b0), .src1_i(lane_src1), .src2_i(lane_src2),
                .src3_i(32'd0),
                .result_valid_o(lane_result_valid[lane_index]),
                .result_ready_i(lane_result_ready),
                .result_tag_o(lane_result_tag[lane_index]),
                .result_o(lane_result[lane_index])
            );
        end
    endgenerate

    reg [DATAPATH_WIDTH-1:0] fp_result_chunk;
    integer pack_index;
    always @* begin
        fp_result_chunk = {DATAPATH_WIDTH{1'b0}};
        case (active_fmt_q)
            `OPENRV64_VEC_FMT_FP4_E2M1: begin
                for (pack_index = 0; pack_index < 16;
                     pack_index = pack_index + 1)
                    fp_result_chunk[pack_index*4 +: 4] =
                        fp32_to_fp4(lane_result[pack_index]);
            end
            `OPENRV64_VEC_FMT_FP8_E4M3: begin
                for (pack_index = 0; pack_index < 8;
                     pack_index = pack_index + 1)
                    fp_result_chunk[pack_index*8 +: 8] =
                        fp32_to_fp8(lane_result[pack_index]);
            end
            `OPENRV64_VEC_FMT_BF16: begin
                for (pack_index = 0; pack_index < 4;
                     pack_index = pack_index + 1)
                    fp_result_chunk[pack_index*16 +: 16] =
                        fp32_to_bf16(lane_result[pack_index]);
            end
            `OPENRV64_VEC_FMT_FP32: begin
                for (pack_index = 0; pack_index < 2;
                     pack_index = pack_index + 1)
                    fp_result_chunk[pack_index*32 +: 32] =
                        lane_result[pack_index];
            end
            default: fp_result_chunk = {DATAPATH_WIDTH{1'b0}};
        endcase
    end

    assign complete_valid_o = active_valid_q &&
                              (state_q == STATE_COMPLETE) &&
                              !complete_sent_q;
    assign complete_tag_o = active_tag_q;
    assign complete_unsupported_o = active_unsupported_q;
    wire complete_fire = complete_valid_o && complete_ready_i;

    wire kill_pending = retire_valid_i && retire_kill_i &&
                        pending_valid_q &&
                        (retire_tag_i == pending_tag_q);
    wire kill_active = retire_valid_i && retire_kill_i &&
                       active_valid_q &&
                       (retire_tag_i == active_tag_q) &&
                       (state_q != STATE_WRITEBACK);
    wire commit_request = retire_valid_i && !retire_kill_i &&
                          active_valid_q &&
                          (retire_tag_i == active_tag_q) && complete_sent_q;

    wire [REG_ADDR_WIDTH-1:0] write_reg_offset =
        write_index_q / BASE_CHUNKS;
    assign rf_write_addr_o = active_vd_q + write_reg_offset;
    assign rf_write_slice_o = write_index_q % BASE_CHUNKS;
    assign rf_write_data_o = result_slice_q[write_index_q];
    assign rf_write_valid_o = (state_q == STATE_WRITEBACK) &&
                              commit_request && !active_unsupported_q;
    wire rf_write_fire = rf_write_valid_o && rf_write_ready_i;
    wire write_last = write_index_q == active_chunk_count - 1'b1;
    wire unsupported_commit = commit_request && active_unsupported_q &&
                              (state_q == STATE_COMPLETE);
    wire final_write_commit = rf_write_fire && write_last;
    assign retire_ready_o = kill_pending || kill_active ||
                            unsupported_commit || final_write_commit;
    wire retire_commit_fire = retire_valid_i && retire_ready_o &&
                              !retire_kill_i;
    assign fp_lane_flush = kill_active;

    // replay_o is informational.  Dispatch has already transferred ownership
    // of pending_tag_q; the vector unit retains and retries it locally.
    assign replay_o = (pending_valid_q &&
                       (!unit_idle || !operands_ready_i)) ||
                      (execution_reads && !rf_reads_ready);
    assign busy_o = pending_valid_q || active_valid_q;

    integer result_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_valid_q <= 1'b0;
            pending_tag_q <= {TAG_WIDTH{1'b0}};
            pending_op_q <= `OPENRV64_VEC_OP_INVALID;
            pending_vtype_q <= {`OPENRV64_VEC_VTYPE_WIDTH{1'b0}};
            pending_vs1_q <= {REG_ADDR_WIDTH{1'b0}};
            pending_vs2_q <= {REG_ADDR_WIDTH{1'b0}};
            pending_vd_q <= {REG_ADDR_WIDTH{1'b0}};
            active_valid_q <= 1'b0;
            active_tag_q <= {TAG_WIDTH{1'b0}};
            active_op_q <= `OPENRV64_VEC_OP_INVALID;
            active_fmt_q <= `OPENRV64_VEC_FMT_FP4_E2M1;
            active_lmul_q <= {LMUL_WIDTH{1'b0}};
            active_vs1_q <= {REG_ADDR_WIDTH{1'b0}};
            active_vs2_q <= {REG_ADDR_WIDTH{1'b0}};
            active_vd_q <= {REG_ADDR_WIDTH{1'b0}};
            active_unsupported_q <= 1'b0;
            feed_index_q <= {CHUNK_INDEX_WIDTH{1'b0}};
            bit_index_q <= {CHUNK_INDEX_WIDTH{1'b0}};
            write_index_q <= {CHUNK_INDEX_WIDTH{1'b0}};
            fp_result_count_q <= {(CHUNK_INDEX_WIDTH+1){1'b0}};
            fp_feed_done_q <= 1'b0;
            state_q <= STATE_IDLE;
            complete_sent_q <= 1'b0;
            for (result_index = 0; result_index < CHUNKS;
                 result_index = result_index + 1)
                result_slice_q[result_index] <=
                    {DATAPATH_WIDTH{1'b0}};
        end else begin
            if (dispatch_fire) begin
                pending_valid_q <= 1'b1;
                pending_tag_q <= dispatch_tag_i;
                pending_op_q <= dispatch_op_i;
                pending_vtype_q <= dispatch_vtype_i;
                pending_vs1_q <= dispatch_vs1_i;
                pending_vs2_q <= dispatch_vs2_i;
                pending_vd_q <= dispatch_vd_i;
            end
            if (kill_pending)
                pending_valid_q <= 1'b0;

            if (kill_active) begin
                active_valid_q <= 1'b0;
                active_unsupported_q <= 1'b0;
                state_q <= STATE_IDLE;
                complete_sent_q <= 1'b0;
            end else begin
                if (start_pending) begin
                    pending_valid_q <= 1'b0;
                    active_valid_q <= 1'b1;
                    active_tag_q <= pending_tag_q;
                    active_op_q <= pending_op_q;
                    active_fmt_q <= pending_fmt;
                    active_lmul_q <= pending_lmul;
                    active_vs1_q <= pending_vs1_q;
                    active_vs2_q <= pending_vs2_q;
                    active_vd_q <= pending_vd_q;
                    active_unsupported_q <= pending_unsupported;
                    feed_index_q <= {CHUNK_INDEX_WIDTH{1'b0}};
                    bit_index_q <= {CHUNK_INDEX_WIDTH{1'b0}};
                    write_index_q <= {CHUNK_INDEX_WIDTH{1'b0}};
                    fp_result_count_q <=
                        {(CHUNK_INDEX_WIDTH+1){1'b0}};
                    fp_feed_done_q <= 1'b0;
                    complete_sent_q <= 1'b0;
                    if (pending_unsupported)
                        state_q <= STATE_COMPLETE;
                    else if (pending_bit_op)
                        state_q <= STATE_BIT_EXEC;
                    else
                        state_q <= STATE_FP_FEED;
                end else begin
                    case (state_q)
                        STATE_BIT_EXEC: begin
                            if (bit_exec_fire) begin
                                result_slice_q[bit_index_q] <=
                                    bit_result_chunk;
                                if (bit_index_q ==
                                    active_chunk_count - 1'b1) begin
                                    state_q <= STATE_COMPLETE;
                                end else begin
                                    bit_index_q <= bit_index_q + 1'b1;
                                end
                            end
                        end
                        STATE_FP_FEED: begin
                            if (fp_feed_fire) begin
                                if (feed_index_q == active_chunk_count - 1'b1) begin
                                    state_q <= STATE_FP_DRAIN;
                                    fp_feed_done_q <= 1'b1;
                                end else begin
                                    feed_index_q <= feed_index_q + 1'b1;
                                end
                            end
                        end
                        STATE_COMPLETE: begin
                            if (commit_request &&
                                !active_unsupported_q) begin
                                state_q <= STATE_WRITEBACK;
                                write_index_q <=
                                    {CHUNK_INDEX_WIDTH{1'b0}};
                            end
                        end
                        STATE_WRITEBACK: begin
                            if (rf_write_fire && !write_last)
                                write_index_q <= write_index_q + 1'b1;
                        end
                        default: begin
                        end
                    endcase
                end

                if (fp_early_fire)
                    result_slice_q[feed_index_q] <=
                        {DATAPATH_WIDTH{1'b0}};
                if (fp_result_fire) begin
                    result_slice_q[lane_result_tag[0]] <= fp_result_chunk;
                end
                if (fp_completion_events != 0)
                    fp_result_count_q <= fp_result_count_next;
                if (((state_q == STATE_FP_FEED) ||
                     (state_q == STATE_FP_DRAIN)) && fp_all_results)
                    state_q <= STATE_COMPLETE;
                if (complete_fire)
                    complete_sent_q <= 1'b1;
                if (retire_commit_fire) begin
                    active_valid_q <= 1'b0;
                    active_unsupported_q <= 1'b0;
                    state_q <= STATE_IDLE;
                    complete_sent_q <= 1'b0;
                end
            end
        end
    end

`ifndef SYNTHESIS
    integer check_lane;
    initial begin
        if (DATAPATH_WIDTH != 64)
            $fatal(1, "initial vector datapath supports exactly 64 bits/cycle");
        if ((VLEN < DATAPATH_WIDTH) || ((VLEN % DATAPATH_WIDTH) != 0))
            $fatal(1, "VLEN must be a positive multiple of DATAPATH_WIDTH");
        if (MAX_LMUL != 8)
            $fatal(1, "initial vector arithmetic requires MAX_LMUL=8");
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (fp_result_fire) begin
                for (check_lane = 1; check_lane < FP_LANES;
                     check_lane = check_lane + 1) begin
                    if (!lane_result_valid[check_lane] ||
                        (lane_result_tag[check_lane] != lane_result_tag[0]))
                        $fatal(1, "vector FP lanes lost pipeline lockstep");
                end
            end
            if (retire_valid_i && !retire_kill_i &&
                ((retire_tag_i == pending_tag_q) && pending_valid_q))
                $fatal(1, "pending vector command cannot commit before completion");
        end
    end
`endif
`else
    // Multiple commands share one 64-bit slice feed and one set of FP lanes.
    // A command remains in its result context through tagged completion and
    // architectural writeback.  The lane token carries both the context slot
    // and slice index, allowing younger independent commands to enter while
    // older results are still crossing the eleven-stage pipeline.
    localparam integer SLOT_WIDTH =
        (INFLIGHT_DEPTH <= 1) ? 1 : $clog2(INFLIGHT_DEPTH);
    localparam integer USED_WIDTH =
        (INFLIGHT_DEPTH <= 1) ? 1 : $clog2(INFLIGHT_DEPTH + 1);
    localparam integer TOKEN_TAG_WIDTH = SLOT_WIDTH + CHUNK_INDEX_WIDTH;

    reg slot_valid_q [0:INFLIGHT_DEPTH-1];
    reg slot_killed_q [0:INFLIGHT_DEPTH-1];
    reg slot_feed_done_q [0:INFLIGHT_DEPTH-1];
    reg slot_complete_sent_q [0:INFLIGHT_DEPTH-1];
    reg [TAG_WIDTH-1:0] slot_tag_q [0:INFLIGHT_DEPTH-1];
    reg [`OPENRV64_VEC_OP_WIDTH-1:0]
        slot_op_q [0:INFLIGHT_DEPTH-1];
    reg [`OPENRV64_VEC_FMT_WIDTH-1:0]
        slot_fmt_q [0:INFLIGHT_DEPTH-1];
    reg [LMUL_WIDTH-1:0] slot_lmul_q [0:INFLIGHT_DEPTH-1];
    reg slot_acc_q [0:INFLIGHT_DEPTH-1];
    reg [REG_ADDR_WIDTH-1:0] slot_vs1_q [0:INFLIGHT_DEPTH-1];
    reg [REG_ADDR_WIDTH-1:0] slot_vs2_q [0:INFLIGHT_DEPTH-1];
    reg [REG_ADDR_WIDTH-1:0] slot_vd_q [0:INFLIGHT_DEPTH-1];
    reg slot_unsupported_q [0:INFLIGHT_DEPTH-1];
    reg [CHUNK_INDEX_WIDTH:0]
        slot_feed_count_q [0:INFLIGHT_DEPTH-1];
    reg [CHUNK_INDEX_WIDTH:0]
        slot_result_count_q [0:INFLIGHT_DEPTH-1];
    reg [DATAPATH_WIDTH-1:0]
        result_slice_q [0:INFLIGHT_DEPTH-1][0:CHUNKS-1];

    // Two private accumulator groups. They are deliberately absent from the
    // architectural vector register namespace and change only at retirement.
    reg acc_valid_q [0:1];
    reg [`OPENRV64_VEC_FMT_WIDTH-1:0] acc_fmt_q [0:1];
    reg [LMUL_WIDTH-1:0] acc_lmul_q [0:1];
    reg [DATAPATH_WIDTH-1:0] acc_slice_q [0:1][0:CHUNKS-1];

    reg [SLOT_WIDTH-1:0] alloc_tail_q;
    reg [SLOT_WIDTH-1:0] retire_head_q;
    reg [USED_WIDTH-1:0] used_count_q;
    reg [CHUNK_INDEX_WIDTH-1:0] write_index_q;
    reg write_started_q;

    wire [2:0] dispatch_vlmul = dispatch_vtype_i[
        `OPENRV64_VEC_VTYPE_VLMUL_LSB +: 3];
    wire [LMUL_WIDTH-1:0] dispatch_lmul =
        dispatch_vlmul[LMUL_WIDTH-1:0];
    wire dispatch_bit_op =
        (dispatch_op_i == `OPENRV64_VEC_OP_AND) ||
        (dispatch_op_i == `OPENRV64_VEC_OP_OR) ||
        (dispatch_op_i == `OPENRV64_VEC_OP_XOR) ||
        (dispatch_op_i == `OPENRV64_VEC_OP_NOT);
    wire dispatch_fp_op =
        (dispatch_op_i == `OPENRV64_VEC_OP_FADD) ||
        (dispatch_op_i == `OPENRV64_VEC_OP_FMUL);
    wire dispatch_vlda = dispatch_op_i == `OPENRV64_VEC_OP_VLDA;
    wire dispatch_vsta = dispatch_op_i == `OPENRV64_VEC_OP_VSTA;
    wire dispatch_vmac = dispatch_op_i == `OPENRV64_VEC_OP_VMAC;
    wire dispatch_acc_op = dispatch_vlda || dispatch_vsta || dispatch_vmac;
    wire [2:0] dispatch_vsew = dispatch_vtype_i[
        `OPENRV64_VEC_VTYPE_VSEW_LSB +: 3];
    wire [`OPENRV64_VEC_VTYPE_XFMT_WIDTH-1:0] dispatch_xfmt =
        dispatch_vtype_i[`OPENRV64_VEC_VTYPE_XFMT_LSB +:
                         `OPENRV64_VEC_VTYPE_XFMT_WIDTH];
    reg [`OPENRV64_VEC_FMT_WIDTH-1:0] dispatch_fmt;
    reg dispatch_fmt_supported;
    always @* begin
        dispatch_fmt = `OPENRV64_VEC_FMT_FP4_E2M1;
        dispatch_fmt_supported = 1'b1;
        case (dispatch_xfmt)
            `OPENRV64_VEC_XFMT_FP32: begin
                dispatch_fmt = `OPENRV64_VEC_FMT_FP32;
                dispatch_fmt_supported = dispatch_vsew ==
                                         `OPENRV64_VEC_VSEW_E32;
            end
            `OPENRV64_VEC_XFMT_BF16: begin
                dispatch_fmt = `OPENRV64_VEC_FMT_BF16;
                dispatch_fmt_supported = dispatch_vsew ==
                                         `OPENRV64_VEC_VSEW_E16;
            end
            `OPENRV64_VEC_XFMT_FP8_E4M3: begin
                dispatch_fmt = `OPENRV64_VEC_FMT_FP8_E4M3;
                dispatch_fmt_supported = dispatch_vsew ==
                                         `OPENRV64_VEC_VSEW_E8;
            end
            `OPENRV64_VEC_XFMT_FP4_E2M1: begin
                dispatch_fmt = `OPENRV64_VEC_FMT_FP4_E2M1;
                dispatch_fmt_supported = dispatch_vsew ==
                                         `OPENRV64_VEC_VSEW_E8;
            end
            default: dispatch_fmt_supported = 1'b0;
        endcase
    end

    wire dispatch_lmul_supported = !dispatch_vlmul[2];
    wire [REG_ADDR_WIDTH:0] dispatch_group_count =
        {{REG_ADDR_WIDTH{1'b0}}, 1'b1} << dispatch_lmul;
    wire [REG_ADDR_WIDTH:0] dispatch_group_mask =
        dispatch_group_count - 1'b1;
    wire dispatch_vs1_valid =
        (({1'b0, dispatch_vs1_i} & dispatch_group_mask) == 0) &&
        (({1'b0, dispatch_vs1_i} + dispatch_group_count) <= NUM_REGS);
    wire dispatch_vs2_valid =
        (({1'b0, dispatch_vs2_i} & dispatch_group_mask) == 0) &&
        (({1'b0, dispatch_vs2_i} + dispatch_group_count) <= NUM_REGS);
    wire dispatch_vd_valid =
        (({1'b0, dispatch_vd_i} & dispatch_group_mask) == 0) &&
        (({1'b0, dispatch_vd_i} + dispatch_group_count) <= NUM_REGS);
    wire dispatch_vtype_common_valid =
        !dispatch_vtype_i[`OPENRV64_VEC_VTYPE_VILL_BIT] &&
        (dispatch_vtype_i[62:11] == 0) && dispatch_lmul_supported;
    wire dispatch_regs_valid = dispatch_vlda ? dispatch_vs1_valid :
        dispatch_vsta ? dispatch_vd_valid :
        dispatch_vmac ? (dispatch_vs1_valid && dispatch_vs2_valid) :
        (dispatch_vs1_valid && dispatch_vs2_valid && dispatch_vd_valid);
    wire dispatch_acc_state_valid = (!dispatch_vsta && !dispatch_vmac) ||
        (acc_valid_q[dispatch_acc_i] &&
         (acc_fmt_q[dispatch_acc_i] == dispatch_fmt) &&
         (acc_lmul_q[dispatch_acc_i] == dispatch_lmul));
    wire dispatch_unsupported = !dispatch_vtype_common_valid ||
        !dispatch_regs_valid ||
        (!dispatch_bit_op &&
         !((dispatch_fp_op || dispatch_acc_op) &&
           dispatch_fmt_supported)) ||
        (dispatch_acc_op && !dispatch_acc_state_valid);

    reg [1:0] acc_op_live;
    integer acc_live_scan;
    always @* begin
        acc_op_live = 2'b00;
        for (acc_live_scan = 0; acc_live_scan < INFLIGHT_DEPTH;
             acc_live_scan = acc_live_scan + 1)
            if (slot_valid_q[acc_live_scan] &&
                ((slot_op_q[acc_live_scan] == `OPENRV64_VEC_OP_VLDA) ||
                 (slot_op_q[acc_live_scan] == `OPENRV64_VEC_OP_VSTA) ||
                 (slot_op_q[acc_live_scan] == `OPENRV64_VEC_OP_VMAC)))
                acc_op_live[slot_acc_q[acc_live_scan]] = 1'b1;
    end

    // Commands serialize only against the same accumulator recurrence. The
    // other accumulator and ordinary vector commands remain independent.
    assign dispatch_ready_o = (used_count_q < INFLIGHT_DEPTH) &&
        (!dispatch_acc_op || !acc_op_live[dispatch_acc_i]);
    wire dispatch_fire = dispatch_valid_i && dispatch_ready_o;

    // Oldest not-yet-fed context owns the shared RF read and lane input.
    reg feed_found;
    reg [SLOT_WIDTH-1:0] feed_slot;
    reg [SLOT_WIDTH-1:0] scan_slot;
    integer scan_index;
    always @* begin
        feed_found = 1'b0;
        feed_slot = retire_head_q;
        scan_slot = retire_head_q;
        for (scan_index = 0; scan_index < INFLIGHT_DEPTH;
             scan_index = scan_index + 1) begin
            scan_slot = retire_head_q + scan_index;
            if (!feed_found && slot_valid_q[scan_slot] &&
                !slot_killed_q[scan_slot] &&
                !slot_feed_done_q[scan_slot] &&
                !slot_unsupported_q[scan_slot]) begin
                feed_found = 1'b1;
                feed_slot = scan_slot;
            end
        end
    end

    wire [CHUNK_INDEX_WIDTH:0] feed_chunk_count =
        BASE_CHUNKS << slot_lmul_q[feed_slot];
    wire [CHUNK_INDEX_WIDTH-1:0] feed_index =
        slot_feed_count_q[feed_slot][CHUNK_INDEX_WIDTH-1:0];
    wire [REG_ADDR_WIDTH-1:0] feed_reg_offset =
        feed_index / BASE_CHUNKS;
    wire [SLICE_INDEX_WIDTH-1:0] feed_slice =
        feed_index % BASE_CHUNKS;
    wire feed_bit_op =
        (slot_op_q[feed_slot] == `OPENRV64_VEC_OP_AND) ||
        (slot_op_q[feed_slot] == `OPENRV64_VEC_OP_OR) ||
        (slot_op_q[feed_slot] == `OPENRV64_VEC_OP_XOR) ||
        (slot_op_q[feed_slot] == `OPENRV64_VEC_OP_NOT);
    wire feed_fp_op =
        (slot_op_q[feed_slot] == `OPENRV64_VEC_OP_FADD) ||
        (slot_op_q[feed_slot] == `OPENRV64_VEC_OP_FMUL);
    wire feed_vlda = slot_op_q[feed_slot] == `OPENRV64_VEC_OP_VLDA;
    wire feed_vsta = slot_op_q[feed_slot] == `OPENRV64_VEC_OP_VSTA;
    wire feed_vmac = slot_op_q[feed_slot] == `OPENRV64_VEC_OP_VMAC;
    wire feed_needs_src1 = !feed_vsta;
    wire feed_needs_src2 =
        (slot_op_q[feed_slot] == `OPENRV64_VEC_OP_AND) ||
        (slot_op_q[feed_slot] == `OPENRV64_VEC_OP_OR) ||
        (slot_op_q[feed_slot] == `OPENRV64_VEC_OP_XOR) ||
        feed_fp_op || feed_vmac;
    wire feed_killed_now = retire_valid_i && retire_kill_i &&
        slot_valid_q[feed_slot] &&
        (retire_tag_i == slot_tag_q[feed_slot]);
    wire execution_reads = feed_found && operands_ready_i &&
                           !feed_killed_now;

    wire [FP_LANES-1:0] lane_ready;
    wire all_lane_ready = &lane_ready;
    wire [FP_LANES-1:0] mac_lane_ready;
    wire all_mac_lane_ready = &mac_lane_ready;
    wire [DATAPATH_WIDTH-1:0] src1_chunk =
        rf_read_data_i[0*DATAPATH_WIDTH +: DATAPATH_WIDTH];
    wire [DATAPATH_WIDTH-1:0] src2_chunk =
        rf_read_data_i[1*DATAPATH_WIDTH +: DATAPATH_WIDTH];
    wire fp_zero_early = feed_fp_op &&
                         (src1_chunk == 0) && (src2_chunk == 0);
    wire feed_engine_ready = feed_bit_op || feed_vlda || feed_vsta ||
        fp_zero_early || (feed_fp_op && all_lane_ready) ||
        (feed_vmac && all_mac_lane_ready);
    assign rf_read_valid_o[0] = execution_reads && feed_needs_src1 &&
                                feed_engine_ready;
    assign rf_read_valid_o[1] = rf_read_valid_o[0] && feed_needs_src2;
    assign rf_read_addr_o = {
        slot_vs2_q[feed_slot] + feed_reg_offset,
        slot_vs1_q[feed_slot] + feed_reg_offset};
    assign rf_read_slice_o = {2{feed_slice}};
    wire rf_reads_ready = (!rf_read_valid_o[0] || rf_read_ready_i[0]) &&
        (!rf_read_valid_o[1] || rf_read_ready_i[1]);

    wire [DATAPATH_WIDTH-1:0] bit_src1_chunk = src1_chunk;
    wire [DATAPATH_WIDTH-1:0] bit_src2_chunk = src2_chunk;
    reg [DATAPATH_WIDTH-1:0] bit_result_chunk;
    always @* begin
        case (slot_op_q[feed_slot])
            `OPENRV64_VEC_OP_AND:
                bit_result_chunk = bit_src1_chunk & bit_src2_chunk;
            `OPENRV64_VEC_OP_OR:
                bit_result_chunk = bit_src1_chunk | bit_src2_chunk;
            `OPENRV64_VEC_OP_XOR:
                bit_result_chunk = bit_src1_chunk ^ bit_src2_chunk;
            `OPENRV64_VEC_OP_NOT:
                bit_result_chunk = ~bit_src1_chunk;
            default:
                bit_result_chunk = {DATAPATH_WIDTH{1'b0}};
        endcase
    end

    wire bit_exec_fire = execution_reads && feed_bit_op &&
                         rf_read_valid_o[0] && rf_reads_ready;
    wire acc_copy_exec_fire = execution_reads && (feed_vlda || feed_vsta) &&
        feed_engine_ready && rf_reads_ready &&
        (!feed_needs_src1 || rf_read_valid_o[0]);
    wire [DATAPATH_WIDTH-1:0] acc_copy_result_chunk =
        feed_vlda ? src1_chunk :
        acc_slice_q[slot_acc_q[feed_slot]][feed_index];
    wire fp_feed_valid = execution_reads && feed_fp_op &&
                         rf_reads_ready && !fp_zero_early;
    wire mac_feed_valid = execution_reads && feed_vmac &&
                          rf_reads_ready;
    wire fp_multiply = slot_op_q[feed_slot] == `OPENRV64_VEC_OP_FMUL;
    wire fp_lane_feed_fire = fp_feed_valid && all_lane_ready;
    wire mac_lane_feed_fire = mac_feed_valid && all_mac_lane_ready;
    wire fp_early_fire = execution_reads && feed_fp_op &&
                         rf_reads_ready && fp_zero_early;
    wire feed_fire = bit_exec_fire || acc_copy_exec_fire ||
                     fp_lane_feed_fire || mac_lane_feed_fire ||
                     fp_early_fire;
    wire feed_last = feed_fire && (feed_index == feed_chunk_count - 1'b1);
    wire [TOKEN_TAG_WIDTH-1:0] feed_token_tag =
        {feed_slot, feed_index};

    wire [FP_LANES-1:0] lane_result_valid;
    wire [TOKEN_TAG_WIDTH-1:0] lane_result_tag [0:FP_LANES-1];
    wire [31:0] lane_result [0:FP_LANES-1];
    wire fp_result_fire = lane_result_valid[0];
    wire [SLOT_WIDTH-1:0] fp_result_slot =
        lane_result_tag[0][TOKEN_TAG_WIDTH-1 -: SLOT_WIDTH];
    wire [CHUNK_INDEX_WIDTH-1:0] fp_result_index =
        lane_result_tag[0][CHUNK_INDEX_WIDTH-1:0];
    wire fp_lane_flush = 1'b0;

    wire [FP_LANES-1:0] mac_lane_result_valid;
    wire [TOKEN_TAG_WIDTH-1:0]
        mac_lane_result_tag [0:FP_LANES-1];
    wire [31:0] mac_lane_result [0:FP_LANES-1];
    wire mac_result_fire = mac_lane_result_valid[0];
    wire [SLOT_WIDTH-1:0] mac_result_slot =
        mac_lane_result_tag[0][TOKEN_TAG_WIDTH-1 -: SLOT_WIDTH];
    wire [CHUNK_INDEX_WIDTH-1:0] mac_result_index =
        mac_lane_result_tag[0][CHUNK_INDEX_WIDTH-1:0];

    genvar lane_index;
    generate
        for (lane_index = 0; lane_index < FP_LANES;
             lane_index = lane_index + 1) begin : g_fp_lane
            wire [31:0] lane_src1 = lane_to_fp32(
                src1_chunk, slot_fmt_q[feed_slot], lane_index);
            wire [31:0] lane_src2 = lane_to_fp32(
                src2_chunk, slot_fmt_q[feed_slot], lane_index);
            wire [31:0] lane_acc = lane_to_fp32(
                acc_slice_q[slot_acc_q[feed_slot]][feed_index],
                slot_fmt_q[feed_slot],
                lane_index);
            openrv64_exec_vec_fp32_lane #(
                .TAG_WIDTH(TOKEN_TAG_WIDTH),
                .PIPELINE_STAGES(FP_PIPELINE_STAGES)
            ) u_lane (
                .clk(clk), .rst_n(rst_n), .flush_i(fp_lane_flush),
                .valid_i(fp_feed_valid), .ready_o(lane_ready[lane_index]),
                .tag_i(feed_token_tag), .multiply_i(fp_multiply),
                .mac_i(1'b0), .src1_i(lane_src1), .src2_i(lane_src2),
                .src3_i(32'd0),
                .result_valid_o(lane_result_valid[lane_index]),
                .result_ready_i(1'b1),
                .result_tag_o(lane_result_tag[lane_index]),
                .result_o(lane_result[lane_index])
            );
            openrv64_exec_vec_fp32_lane #(
                .TAG_WIDTH(TOKEN_TAG_WIDTH),
                .PIPELINE_STAGES(MAC_PIPELINE_STAGES)
            ) u_mac_lane (
                .clk(clk), .rst_n(rst_n), .flush_i(fp_lane_flush),
                .valid_i(mac_feed_valid),
                .ready_o(mac_lane_ready[lane_index]),
                .tag_i(feed_token_tag), .multiply_i(1'b0), .mac_i(1'b1),
                .src1_i(lane_src1), .src2_i(lane_src2),
                .src3_i(lane_acc),
                .result_valid_o(mac_lane_result_valid[lane_index]),
                .result_ready_i(1'b1),
                .result_tag_o(mac_lane_result_tag[lane_index]),
                .result_o(mac_lane_result[lane_index])
            );
        end
    endgenerate

    reg [DATAPATH_WIDTH-1:0] fp_result_chunk;
    integer pack_index;
    always @* begin
        fp_result_chunk = {DATAPATH_WIDTH{1'b0}};
        case (slot_fmt_q[fp_result_slot])
            `OPENRV64_VEC_FMT_FP4_E2M1: begin
                for (pack_index = 0; pack_index < 16;
                     pack_index = pack_index + 1)
                    fp_result_chunk[pack_index*4 +: 4] =
                        fp32_to_fp4(lane_result[pack_index]);
            end
            `OPENRV64_VEC_FMT_FP8_E4M3: begin
                for (pack_index = 0; pack_index < 8;
                     pack_index = pack_index + 1)
                    fp_result_chunk[pack_index*8 +: 8] =
                        fp32_to_fp8(lane_result[pack_index]);
            end
            `OPENRV64_VEC_FMT_BF16: begin
                for (pack_index = 0; pack_index < 4;
                     pack_index = pack_index + 1)
                    fp_result_chunk[pack_index*16 +: 16] =
                        fp32_to_bf16(lane_result[pack_index]);
            end
            `OPENRV64_VEC_FMT_FP32: begin
                for (pack_index = 0; pack_index < 2;
                     pack_index = pack_index + 1)
                    fp_result_chunk[pack_index*32 +: 32] =
                        lane_result[pack_index];
            end
            default:
                fp_result_chunk = {DATAPATH_WIDTH{1'b0}};
        endcase
    end

    reg [DATAPATH_WIDTH-1:0] mac_result_chunk;
    integer mac_pack_index;
    always @* begin
        mac_result_chunk = {DATAPATH_WIDTH{1'b0}};
        case (slot_fmt_q[mac_result_slot])
            `OPENRV64_VEC_FMT_FP4_E2M1: begin
                for (mac_pack_index = 0; mac_pack_index < 16;
                     mac_pack_index = mac_pack_index + 1)
                    mac_result_chunk[mac_pack_index*4 +: 4] =
                        fp32_to_fp4(mac_lane_result[mac_pack_index]);
            end
            `OPENRV64_VEC_FMT_FP8_E4M3: begin
                for (mac_pack_index = 0; mac_pack_index < 8;
                     mac_pack_index = mac_pack_index + 1)
                    mac_result_chunk[mac_pack_index*8 +: 8] =
                        fp32_to_fp8(mac_lane_result[mac_pack_index]);
            end
            `OPENRV64_VEC_FMT_BF16: begin
                for (mac_pack_index = 0; mac_pack_index < 4;
                     mac_pack_index = mac_pack_index + 1)
                    mac_result_chunk[mac_pack_index*16 +: 16] =
                        fp32_to_bf16(mac_lane_result[mac_pack_index]);
            end
            `OPENRV64_VEC_FMT_FP32: begin
                for (mac_pack_index = 0; mac_pack_index < 2;
                     mac_pack_index = mac_pack_index + 1)
                    mac_result_chunk[mac_pack_index*32 +: 32] =
                        mac_lane_result[mac_pack_index];
            end
            default:
                mac_result_chunk = {DATAPATH_WIDTH{1'b0}};
        endcase
    end

    wire head_valid = slot_valid_q[retire_head_q];
    wire head_done = slot_feed_done_q[retire_head_q] &&
        (slot_result_count_q[retire_head_q] ==
         slot_feed_count_q[retire_head_q]);
    assign complete_valid_o = head_valid && head_done &&
        !slot_killed_q[retire_head_q] &&
        !slot_complete_sent_q[retire_head_q];
    assign complete_tag_o = slot_tag_q[retire_head_q];
    assign complete_unsupported_o = slot_unsupported_q[retire_head_q];
    wire complete_fire = complete_valid_o && complete_ready_i;

    reg kill_match_found;
    reg [SLOT_WIDTH-1:0] kill_match_slot;
    integer kill_scan;
    always @* begin
        kill_match_found = 1'b0;
        kill_match_slot = {SLOT_WIDTH{1'b0}};
        for (kill_scan = 0; kill_scan < INFLIGHT_DEPTH;
             kill_scan = kill_scan + 1) begin
            if (!kill_match_found && slot_valid_q[kill_scan] &&
                (slot_tag_q[kill_scan] == retire_tag_i)) begin
                kill_match_found = 1'b1;
                kill_match_slot = kill_scan;
            end
        end
    end

    wire head_tag_match = head_valid &&
                          (retire_tag_i == slot_tag_q[retire_head_q]);
    wire commit_request = retire_valid_i && !retire_kill_i &&
                          head_tag_match &&
                          slot_complete_sent_q[retire_head_q];
    wire [CHUNK_INDEX_WIDTH:0] head_chunk_count =
        BASE_CHUNKS << slot_lmul_q[retire_head_q];
    wire [REG_ADDR_WIDTH-1:0] write_reg_offset =
        write_index_q / BASE_CHUNKS;
    assign rf_write_addr_o = slot_vd_q[retire_head_q] + write_reg_offset;
    assign rf_write_slice_o = write_index_q % BASE_CHUNKS;
    assign rf_write_data_o =
        result_slice_q[retire_head_q][write_index_q];
    wire head_acc_write =
        (slot_op_q[retire_head_q] == `OPENRV64_VEC_OP_VLDA) ||
        (slot_op_q[retire_head_q] == `OPENRV64_VEC_OP_VMAC);
    assign rf_write_valid_o = commit_request && !head_acc_write &&
                              !slot_unsupported_q[retire_head_q];
    wire rf_write_fire = rf_write_valid_o && rf_write_ready_i;
    wire acc_write_fire = commit_request && head_acc_write &&
                          !slot_unsupported_q[retire_head_q];
    wire write_last = write_index_q == head_chunk_count - 1'b1;
    wire final_write_commit = (rf_write_fire || acc_write_fire) &&
                              write_last;
    wire unsupported_commit = commit_request &&
                              slot_unsupported_q[retire_head_q];
    wire kill_ready = retire_valid_i && retire_kill_i &&
                      kill_match_found &&
                      !((kill_match_slot == retire_head_q) &&
                        write_started_q);
    assign retire_ready_o = kill_ready || unsupported_commit ||
                            final_write_commit;
    wire retire_commit_fire = retire_valid_i && retire_ready_o &&
                              !retire_kill_i;
    wire retire_kill_fire = retire_valid_i && retire_ready_o &&
                            retire_kill_i;
    wire killed_head_done = head_valid &&
                            slot_killed_q[retire_head_q] && head_done;
    wire pop_head = retire_commit_fire || killed_head_done;

    assign replay_o = feed_found &&
        (!operands_ready_i || (execution_reads && !rf_reads_ready));
    assign busy_o = used_count_q != 0;

    integer slot_index;
    integer result_index;
    integer acc_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alloc_tail_q <= {SLOT_WIDTH{1'b0}};
            retire_head_q <= {SLOT_WIDTH{1'b0}};
            used_count_q <= {USED_WIDTH{1'b0}};
            write_index_q <= {CHUNK_INDEX_WIDTH{1'b0}};
            write_started_q <= 1'b0;
            for (acc_index = 0; acc_index < 2; acc_index = acc_index + 1) begin
                acc_valid_q[acc_index] <= 1'b0;
                acc_fmt_q[acc_index] <= `OPENRV64_VEC_FMT_FP4_E2M1;
                acc_lmul_q[acc_index] <= {LMUL_WIDTH{1'b0}};
                for (result_index = 0; result_index < CHUNKS;
                     result_index = result_index + 1)
                    acc_slice_q[acc_index][result_index] <=
                        {DATAPATH_WIDTH{1'b0}};
            end
            for (slot_index = 0; slot_index < INFLIGHT_DEPTH;
                 slot_index = slot_index + 1) begin
                slot_valid_q[slot_index] <= 1'b0;
                slot_killed_q[slot_index] <= 1'b0;
                slot_feed_done_q[slot_index] <= 1'b0;
                slot_complete_sent_q[slot_index] <= 1'b0;
                slot_tag_q[slot_index] <= {TAG_WIDTH{1'b0}};
                slot_op_q[slot_index] <= `OPENRV64_VEC_OP_INVALID;
                slot_fmt_q[slot_index] <= `OPENRV64_VEC_FMT_FP4_E2M1;
                slot_lmul_q[slot_index] <= {LMUL_WIDTH{1'b0}};
                slot_acc_q[slot_index] <= 1'b0;
                slot_vs1_q[slot_index] <= {REG_ADDR_WIDTH{1'b0}};
                slot_vs2_q[slot_index] <= {REG_ADDR_WIDTH{1'b0}};
                slot_vd_q[slot_index] <= {REG_ADDR_WIDTH{1'b0}};
                slot_unsupported_q[slot_index] <= 1'b0;
                slot_feed_count_q[slot_index] <=
                    {(CHUNK_INDEX_WIDTH+1){1'b0}};
                slot_result_count_q[slot_index] <=
                    {(CHUNK_INDEX_WIDTH+1){1'b0}};
                for (result_index = 0; result_index < CHUNKS;
                     result_index = result_index + 1)
                    result_slice_q[slot_index][result_index] <=
                        {DATAPATH_WIDTH{1'b0}};
            end
        end else begin
            if (dispatch_fire) begin
                slot_valid_q[alloc_tail_q] <= 1'b1;
                slot_killed_q[alloc_tail_q] <= 1'b0;
                slot_feed_done_q[alloc_tail_q] <= dispatch_unsupported;
                slot_complete_sent_q[alloc_tail_q] <= 1'b0;
                slot_tag_q[alloc_tail_q] <= dispatch_tag_i;
                slot_op_q[alloc_tail_q] <= dispatch_op_i;
                slot_fmt_q[alloc_tail_q] <= dispatch_fmt;
                slot_lmul_q[alloc_tail_q] <= dispatch_lmul;
                slot_acc_q[alloc_tail_q] <= dispatch_acc_i;
                slot_vs1_q[alloc_tail_q] <= dispatch_vs1_i;
                slot_vs2_q[alloc_tail_q] <= dispatch_vs2_i;
                slot_vd_q[alloc_tail_q] <= dispatch_vd_i;
                slot_unsupported_q[alloc_tail_q] <= dispatch_unsupported;
                slot_feed_count_q[alloc_tail_q] <=
                    {(CHUNK_INDEX_WIDTH+1){1'b0}};
                slot_result_count_q[alloc_tail_q] <=
                    {(CHUNK_INDEX_WIDTH+1){1'b0}};
                alloc_tail_q <= alloc_tail_q + 1'b1;
            end

            if (feed_fire) begin
                slot_feed_count_q[feed_slot] <=
                    slot_feed_count_q[feed_slot] + 1'b1;
                if (feed_last)
                    slot_feed_done_q[feed_slot] <= 1'b1;
            end
            if (bit_exec_fire)
                result_slice_q[feed_slot][feed_index] <= bit_result_chunk;
            if (acc_copy_exec_fire)
                result_slice_q[feed_slot][feed_index] <=
                    acc_copy_result_chunk;
            if (fp_early_fire)
                result_slice_q[feed_slot][feed_index] <=
                    {DATAPATH_WIDTH{1'b0}};
            if (fp_result_fire)
                result_slice_q[fp_result_slot][fp_result_index] <=
                    fp_result_chunk;
            if (mac_result_fire)
                result_slice_q[mac_result_slot][mac_result_index] <=
                    mac_result_chunk;

            for (slot_index = 0; slot_index < INFLIGHT_DEPTH;
                 slot_index = slot_index + 1) begin
                case ({
                    fp_result_fire &&
                        (fp_result_slot ==
                         slot_index[SLOT_WIDTH-1:0]),
                    mac_result_fire &&
                        (mac_result_slot ==
                         slot_index[SLOT_WIDTH-1:0]),
                    (fp_early_fire || bit_exec_fire ||
                     acc_copy_exec_fire) &&
                        (feed_slot == slot_index[SLOT_WIDTH-1:0])})
                    3'b001, 3'b010, 3'b100:
                        slot_result_count_q[slot_index] <=
                            slot_result_count_q[slot_index] + 1'b1;
                    3'b011, 3'b101, 3'b110:
                        slot_result_count_q[slot_index] <=
                            slot_result_count_q[slot_index] +
                            {{(CHUNK_INDEX_WIDTH-1){1'b0}}, 2'd2};
                    3'b111:
                        slot_result_count_q[slot_index] <=
                            slot_result_count_q[slot_index] +
                            {{(CHUNK_INDEX_WIDTH-1){1'b0}}, 2'd3};
                    default: begin
                    end
                endcase
            end

            if (complete_fire) begin
                slot_complete_sent_q[retire_head_q] <= 1'b1;
                write_index_q <= {CHUNK_INDEX_WIDTH{1'b0}};
                write_started_q <= 1'b0;
            end
            if (acc_write_fire) begin
                acc_slice_q[slot_acc_q[retire_head_q]][write_index_q] <=
                    result_slice_q[retire_head_q][write_index_q];
                if (write_last) begin
                    acc_valid_q[slot_acc_q[retire_head_q]] <= 1'b1;
                    acc_fmt_q[slot_acc_q[retire_head_q]] <=
                        slot_fmt_q[retire_head_q];
                    acc_lmul_q[slot_acc_q[retire_head_q]] <=
                        slot_lmul_q[retire_head_q];
                end
            end
            if (rf_write_fire || acc_write_fire) begin
                write_started_q <= 1'b1;
                if (!write_last)
                    write_index_q <= write_index_q + 1'b1;
            end

            if (retire_kill_fire) begin
                slot_killed_q[kill_match_slot] <= 1'b1;
                slot_feed_done_q[kill_match_slot] <= 1'b1;
            end

            if (pop_head) begin
                slot_valid_q[retire_head_q] <= 1'b0;
                slot_killed_q[retire_head_q] <= 1'b0;
                slot_complete_sent_q[retire_head_q] <= 1'b0;
                retire_head_q <= retire_head_q + 1'b1;
                write_index_q <= {CHUNK_INDEX_WIDTH{1'b0}};
                write_started_q <= 1'b0;
            end

            case ({dispatch_fire, pop_head})
                2'b10: used_count_q <= used_count_q + 1'b1;
                2'b01: used_count_q <= used_count_q - 1'b1;
                default: used_count_q <= used_count_q;
            endcase
        end
    end

`ifndef SYNTHESIS
    integer check_lane;
    integer tag_check;
    initial begin
        if (DATAPATH_WIDTH != 64)
            $fatal(1, "initial vector datapath supports exactly 64 bits/cycle");
        if ((VLEN < DATAPATH_WIDTH) ||
            ((VLEN % DATAPATH_WIDTH) != 0))
            $fatal(1, "VLEN must be a positive multiple of DATAPATH_WIDTH");
        if (MAX_LMUL != 8)
            $fatal(1, "initial vector arithmetic requires MAX_LMUL=8");
        if ((INFLIGHT_DEPTH < 2) ||
            ((INFLIGHT_DEPTH & (INFLIGHT_DEPTH - 1)) != 0))
            $fatal(1, "vector in-flight depth must be a power of two >= 2");
        if (MAC_PIPELINE_STAGES < 2)
            $fatal(1, "vector MAC pipeline requires at least two stages");
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (fp_result_fire) begin
                if (!slot_valid_q[fp_result_slot])
                    $fatal(1, "vector FP result targeted a free context");
                for (check_lane = 1; check_lane < FP_LANES;
                     check_lane = check_lane + 1) begin
                    if (!lane_result_valid[check_lane] ||
                        (lane_result_tag[check_lane] != lane_result_tag[0]))
                        $fatal(1, "vector FP lanes lost pipeline lockstep");
                end
            end
            if (mac_result_fire) begin
                if (!slot_valid_q[mac_result_slot])
                    $fatal(1, "vector MAC result targeted a free context");
                if (slot_op_q[mac_result_slot] != `OPENRV64_VEC_OP_VMAC)
                    $fatal(1, "vector MAC result targeted a non-MAC context");
                for (check_lane = 1; check_lane < FP_LANES;
                     check_lane = check_lane + 1) begin
                    if (!mac_lane_result_valid[check_lane] ||
                        (mac_lane_result_tag[check_lane] !=
                         mac_lane_result_tag[0]))
                        $fatal(1, "vector MAC lanes lost pipeline lockstep");
                end
            end
            if (dispatch_fire) begin
                for (tag_check = 0; tag_check < INFLIGHT_DEPTH;
                     tag_check = tag_check + 1)
                    if (slot_valid_q[tag_check] &&
                        (slot_tag_q[tag_check] == dispatch_tag_i))
                        $fatal(1, "duplicate live vector tag");
            end
            if (retire_valid_i && !retire_kill_i &&
                (!head_tag_match ||
                 !slot_complete_sent_q[retire_head_q]))
                $fatal(1, "vector commit must target completed queue head");
        end
    end
`endif
`endif

endmodule
