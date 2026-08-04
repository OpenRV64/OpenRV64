`timescale 1ns/1ps
`include "core/exec/fpu/rv64-fd.v"
`timescale 1ns/1ps

module tb_exec_fpu_rv64fd #(
    parameter integer ENABLE_PIPELINED_MULTIPLY = 1
);

    localparam integer TAG_WIDTH = 8;
    localparam integer MAX_EXPECTED = 64;
    localparam integer TAG_COUNT = 1 << TAG_WIDTH;

    reg clk;
    reg rst_n;
    reg flush;
    reg valid;
    wire ready;
    reg [TAG_WIDTH-1:0] tag;
    reg [`OPENRV64_FP_OP_WIDTH-1:0] op;
    reg [1:0] fmt;
    reg [2:0] rm;
    reg [2:0] frm;
    reg [4:0] conversion_type;
    reg [63:0] src1;
    reg [63:0] src2;
    reg [63:0] src3;
    wire result_valid;
    reg result_ready;
    wire [TAG_WIDTH-1:0] result_tag;
    wire result_is_int;
    wire [63:0] fp_result;
    wire [63:0] int_result;
    wire [4:0] fflags;
    wire unsupported;

    reg expected_valid [0:TAG_COUNT-1];
    reg expected_is_int [0:TAG_COUNT-1];
    reg [63:0] expected_fp [0:TAG_COUNT-1];
    reg [63:0] expected_int [0:TAG_COUNT-1];
    reg [4:0] expected_flags [0:TAG_COUNT-1];
    reg expected_unsupported [0:TAG_COUNT-1];
    reg [TAG_WIDTH-1:0] completion_order [0:MAX_EXPECTED-1];
    reg [31:0] acceptance_cycle [0:TAG_COUNT-1];
    reg [31:0] completion_cycle [0:TAG_COUNT-1];
    reg [31:0] cycle_count;
    integer expected_count;
    integer completion_order_tail;
    integer expected_index;
    integer completion_base;

    openrv64_exec_fpu_rv64fd #(
        .TAG_WIDTH(TAG_WIDTH),
        .ENABLE_PIPELINED_MULTIPLY(ENABLE_PIPELINED_MULTIPLY)
    ) dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .valid_i(valid), .ready_o(ready), .tag_i(tag), .op_i(op),
        .fmt_i(fmt), .rm_i(rm), .frm_i(frm),
        .type_i(conversion_type),
        .src1_i(src1), .src2_i(src2), .src3_i(src3),
        .result_valid_o(result_valid), .result_ready_i(result_ready),
        .result_tag_o(result_tag), .result_is_int_o(result_is_int),
        .fp_result_o(fp_result), .int_result_o(int_result),
        .fflags_o(fflags), .unsupported_o(unsupported)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cycle_count <= 32'd0;
        else
            cycle_count <= cycle_count + 32'd1;
    end

    task automatic queue_expected;
        input [TAG_WIDTH-1:0] exp_tag;
        input exp_is_int;
        input [63:0] exp_fp;
        input [63:0] exp_int;
        input [4:0] exp_flags;
        input exp_unsupported;
        begin
            if (expected_count >= MAX_EXPECTED)
                $fatal(1, "expected scoreboard overflow");
            if (expected_valid[exp_tag])
                $fatal(1, "duplicate live FPU tag=%0d", exp_tag);
            expected_valid[exp_tag] = 1'b1;
            expected_is_int[exp_tag] = exp_is_int;
            expected_fp[exp_tag] = exp_fp;
            expected_int[exp_tag] = exp_int;
            expected_flags[exp_tag] = exp_flags;
            expected_unsupported[exp_tag] = exp_unsupported;
            expected_count = expected_count + 1;
        end
    endtask

    task automatic send_multiply;
        input [TAG_WIDTH-1:0] in_tag;
        input [`OPENRV64_FP_OP_WIDTH-1:0] in_op;
        input [1:0] in_fmt;
        input [2:0] in_rm;
        input [2:0] in_frm;
        input [63:0] in_src1;
        input [63:0] in_src2;
        input [63:0] in_src3;
        begin
            if (ENABLE_PIPELINED_MULTIPLY != 0)
                send_unstalled(in_tag, in_op, in_fmt, in_rm, in_frm,
                    in_src1, in_src2, in_src3);
            else
                send(in_tag, in_op, in_fmt, in_rm, in_frm,
                    in_src1, in_src2, in_src3);
        end
    endtask

    task automatic send_typed;
        input [TAG_WIDTH-1:0] in_tag;
        input [`OPENRV64_FP_OP_WIDTH-1:0] in_op;
        input [1:0] in_fmt;
        input [2:0] in_rm;
        input [2:0] in_frm;
        input [4:0] in_type;
        input [63:0] in_src1;
        input [63:0] in_src2;
        input [63:0] in_src3;
        begin
            conversion_type = in_type;
            send(in_tag, in_op, in_fmt, in_rm, in_frm,
                 in_src1, in_src2, in_src3);
            conversion_type = `RV64_FP_RS2_W;
        end
    endtask

    task automatic send_unstalled;
        input [TAG_WIDTH-1:0] in_tag;
        input [`OPENRV64_FP_OP_WIDTH-1:0] in_op;
        input [1:0] in_fmt;
        input [2:0] in_rm;
        input [2:0] in_frm;
        input [63:0] in_src1;
        input [63:0] in_src2;
        input [63:0] in_src3;
        begin
            tag = in_tag;
            op = in_op;
            fmt = in_fmt;
            rm = in_rm;
            frm = in_frm;
            src1 = in_src1;
            src2 = in_src2;
            src3 = in_src3;
            valid = 1'b1;
            #0;
            if (!ready)
                $fatal(1,
                    "pipelined FPU backpressured request tag=%0d without output stall",
                    in_tag);
            @(posedge clk);
            @(negedge clk);
            valid = 1'b0;
        end
    endtask

    task automatic send;
        input [TAG_WIDTH-1:0] in_tag;
        input [`OPENRV64_FP_OP_WIDTH-1:0] in_op;
        input [1:0] in_fmt;
        input [2:0] in_rm;
        input [2:0] in_frm;
        input [63:0] in_src1;
        input [63:0] in_src2;
        input [63:0] in_src3;
        integer timeout;
        begin
            timeout = 0;
            tag = in_tag;
            op = in_op;
            fmt = in_fmt;
            rm = in_rm;
            frm = in_frm;
            src1 = in_src1;
            src2 = in_src2;
            src3 = in_src3;
            valid = 1'b1;
            #0;
            while (!ready) begin
                @(posedge clk);
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout >= 500)
                    $fatal(1,
                        "timeout waiting for FPU input ready tag=%0d op=%0d",
                        in_tag, in_op);
            end
            @(posedge clk);
            @(negedge clk);
            valid = 1'b0;
        end
    endtask

    task automatic wait_empty;
        integer timeout;
        begin
            timeout = 0;
            while ((expected_count != 0) && timeout < 200) begin
                @(posedge clk);
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (expected_count != 0)
                $fatal(1, "timeout draining expected scoreboard count=%0d",
                       expected_count);
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && !flush && valid && ready)
            acceptance_cycle[tag] = cycle_count;
        if (rst_n && !flush && result_valid && result_ready) begin
            if (!expected_valid[result_tag])
                $fatal(1, "unexpected FPU result tag=%0d", result_tag);
            if (result_is_int !== expected_is_int[result_tag] ||
                fp_result !== expected_fp[result_tag] ||
                int_result !== expected_int[result_tag] ||
                fflags !== expected_flags[result_tag] ||
                unsupported !== expected_unsupported[result_tag]) begin
                $fatal(1,
                    "FPU tag=%0d intkind=%0b/%0b fp=%016x/%016x int=%016x/%016x flags=%02x/%02x unsup=%0b/%0b",
                    result_tag,
                    result_is_int, expected_is_int[result_tag],
                    fp_result, expected_fp[result_tag],
                    int_result, expected_int[result_tag],
                    fflags, expected_flags[result_tag],
                    unsupported, expected_unsupported[result_tag]);
            end
            if (completion_order_tail >= MAX_EXPECTED)
                $fatal(1, "completion-order log overflow");
            completion_order[completion_order_tail] = result_tag;
            completion_order_tail = completion_order_tail + 1;
            completion_cycle[result_tag] = cycle_count;
            expected_valid[result_tag] = 1'b0;
            expected_count = expected_count - 1;
        end
    end

    initial begin
        flush = 1'b0;
        valid = 1'b0;
        tag = 8'd0;
        op = `OPENRV64_FP_OP_INVALID;
        fmt = `RV64_FP_FMT_D;
        rm = `RV64_FP_RM_RNE;
        frm = `RV64_FP_RM_RNE;
        conversion_type = `RV64_FP_RS2_W;
        src1 = 64'd0;
        src2 = 64'd0;
        src3 = 64'd0;
        result_ready = 1'b1;
        expected_count = 0;
        completion_order_tail = 0;
        for (expected_index = 0;
             expected_index < TAG_COUNT;
             expected_index = expected_index + 1)
            expected_valid[expected_index] = 1'b0;

        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // A fast result may overtake an older iterative operation.  Tags, not
        // issue order, identify completion.
        completion_base = completion_order_tail;
        queue_expected(8'd1, 1'b0, 64'h400e_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send(8'd1, `OPENRV64_FP_OP_ADD, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff8_0000_0000_0000, 64'h4002_0000_0000_0000, 64'd0);
        queue_expected(8'd2, 1'b0, 64'h400b_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send(8'd2, `OPENRV64_FP_OP_MUL, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff8_0000_0000_0000, 64'h4002_0000_0000_0000, 64'd0);
        queue_expected(8'd3, 1'b1, 64'd0, 64'd1, 5'd0, 1'b0);
        send(8'd3, `OPENRV64_FP_OP_LT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'hbff0_0000_0000_0000, 64'd0, 64'd0);
        wait_empty();
        if ((completion_order[completion_base] != 8'd1) ||
            (completion_order[completion_base+1] != 8'd3) ||
            (completion_order[completion_base+2] != 8'd2))
            $fatal(1,
                "fast completion did not overtake MUL.D: order=%0d,%0d,%0d",
                completion_order[completion_base],
                completion_order[completion_base+1],
                completion_order[completion_base+2]);

        // Isolated requests pin the no-contention latency of each exit.
        queue_expected(8'd48, 1'b0, 64'hffff_ffff_4058_0000,
                       64'd0, 5'd0, 1'b0);
        send(8'd48, `OPENRV64_FP_OP_MUL, `RV64_FP_FMT_S,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'hffff_ffff_3fc0_0000, 64'hffff_ffff_4010_0000,
             64'd0);
        wait_empty();
        if ((completion_cycle[8'd48] - acceptance_cycle[8'd48]) !=
            ((ENABLE_PIPELINED_MULTIPLY != 0) ? 7 : 2))
            $fatal(1, "FMUL.S handshake latency was %0d, expected %0d",
                completion_cycle[8'd48] - acceptance_cycle[8'd48],
                (ENABLE_PIPELINED_MULTIPLY != 0) ? 7 : 2);

        queue_expected(8'd49, 1'b0, 64'hffff_ffff_3fb5_04f3,
                       64'd0, `RV64_FP_FFLAG_NX, 1'b0);
        send(8'd49, `OPENRV64_FP_OP_SQRT, `RV64_FP_FMT_S,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'hffff_ffff_4000_0000, 64'd0, 64'd0);
        wait_empty();
        if ((completion_cycle[8'd49] - acceptance_cycle[8'd49]) != 8)
            $fatal(1, "FSQRT.S handshake latency was %0d, expected 8",
                completion_cycle[8'd49] - acceptance_cycle[8'd49]);

        queue_expected(8'd50, 1'b0, 64'h4000_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send(8'd50, `OPENRV64_FP_OP_ADD, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff0_0000_0000_0000, 64'h3ff0_0000_0000_0000,
             64'd0);
        wait_empty();
        if ((completion_cycle[8'd50] - acceptance_cycle[8'd50]) != 1)
            $fatal(1, "fast-lane latency was %0d, expected 1",
                completion_cycle[8'd50] - acceptance_cycle[8'd50]);

        queue_expected(8'd51, 1'b0, 64'h4002_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send(8'd51, `OPENRV64_FP_OP_MUL, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff8_0000_0000_0000, 64'h3ff8_0000_0000_0000,
             64'd0);
        wait_empty();
        if ((completion_cycle[8'd51] - acceptance_cycle[8'd51]) !=
            ((ENABLE_PIPELINED_MULTIPLY != 0) ? 15 : 5))
            $fatal(1, "FMUL.D handshake latency was %0d, expected %0d",
                completion_cycle[8'd51] - acceptance_cycle[8'd51],
                (ENABLE_PIPELINED_MULTIPLY != 0) ? 15 : 5);

        // The compact lane keeps one-request-per-cycle binary32 throughput,
        // but a binary64 request consumes four partial-product cycles.
        queue_expected(8'd52, 1'b0, 64'hffff_ffff_4058_0000,
                       64'd0, 5'd0, 1'b0);
        send_multiply(8'd52, `OPENRV64_FP_OP_MUL, `RV64_FP_FMT_S,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'hffff_ffff_3fc0_0000, 64'hffff_ffff_4010_0000,
             64'd0);
        queue_expected(8'd53, 1'b0, 64'hffff_ffff_4058_0000,
                       64'd0, 5'd0, 1'b0);
        send_multiply(8'd53, `OPENRV64_FP_OP_MUL, `RV64_FP_FMT_S,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'hffff_ffff_3fc0_0000, 64'hffff_ffff_4010_0000,
             64'd0);
        queue_expected(8'd54, 1'b0, 64'hffff_ffff_4058_0000,
                       64'd0, 5'd0, 1'b0);
        send_multiply(8'd54, `OPENRV64_FP_OP_MUL, `RV64_FP_FMT_S,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'hffff_ffff_3fc0_0000, 64'hffff_ffff_4010_0000,
             64'd0);
        if (((acceptance_cycle[8'd53] - acceptance_cycle[8'd52]) != 1) ||
            ((acceptance_cycle[8'd54] - acceptance_cycle[8'd53]) != 1))
            $fatal(1, "FMUL.S initiation interval was not one cycle");

        queue_expected(8'd55, 1'b0, 64'h4002_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send_multiply(8'd55, `OPENRV64_FP_OP_MUL, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff8_0000_0000_0000, 64'h3ff8_0000_0000_0000,
             64'd0);
        queue_expected(8'd56, 1'b0, 64'h4002_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send_multiply(8'd56, `OPENRV64_FP_OP_MUL, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff8_0000_0000_0000, 64'h3ff8_0000_0000_0000,
             64'd0);
        if ((acceptance_cycle[8'd56] - acceptance_cycle[8'd55]) !=
            ((ENABLE_PIPELINED_MULTIPLY != 0) ? 1 : 4))
            $fatal(1, "FMUL.D initiation interval was %0d, expected %0d",
                acceptance_cycle[8'd56] - acceptance_cycle[8'd55],
                (ENABLE_PIPELINED_MULTIPLY != 0) ? 1 : 4);
        wait_empty();

        queue_expected(8'd4, 1'b0, 64'hffff_ffff_4070_0000,
                       64'd0, 5'd0, 1'b0);
        send(8'd4, `OPENRV64_FP_OP_ADD, `RV64_FP_FMT_S,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'hffff_ffff_3fc0_0000, 64'hffff_ffff_4010_0000, 64'd0);
        queue_expected(8'd5, 1'b0, 64'hffff_ffff_4058_0000,
                       64'd0, 5'd0, 1'b0);
        send(8'd5, `OPENRV64_FP_OP_MUL, `RV64_FP_FMT_S,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'hffff_ffff_3fc0_0000, 64'hffff_ffff_4010_0000, 64'd0);

        // Half-ULP tie: RNE stays even, RUP and RMM increment.
        queue_expected(8'd6, 1'b0, 64'h3ff0_0000_0000_0000,
                       64'd0, `RV64_FP_FFLAG_NX, 1'b0);
        send(8'd6, `OPENRV64_FP_OP_ADD, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff0_0000_0000_0000, 64'h3ca0_0000_0000_0000, 64'd0);
        queue_expected(8'd7, 1'b0, 64'h3ff0_0000_0000_0001,
                       64'd0, `RV64_FP_FFLAG_NX, 1'b0);
        send(8'd7, `OPENRV64_FP_OP_ADD, `RV64_FP_FMT_D,
             `RV64_FP_RM_RUP, `RV64_FP_RM_RNE,
             64'h3ff0_0000_0000_0000, 64'h3ca0_0000_0000_0000, 64'd0);
        queue_expected(8'd8, 1'b0, 64'h3ff0_0000_0000_0001,
                       64'd0, `RV64_FP_FFLAG_NX, 1'b0);
        send(8'd8, `OPENRV64_FP_OP_ADD, `RV64_FP_FMT_D,
             `RV64_FP_RM_DYN, `RV64_FP_RM_RMM,
             64'h3ff0_0000_0000_0000, 64'h3ca0_0000_0000_0000, 64'd0);

        queue_expected(8'd9, 1'b0, 64'h7ff0_0000_0000_0000,
                       64'd0,
                       `RV64_FP_FFLAG_OF | `RV64_FP_FFLAG_NX, 1'b0);
        send(8'd9, `OPENRV64_FP_OP_MUL, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h7fef_ffff_ffff_ffff, 64'h4000_0000_0000_0000, 64'd0);
        queue_expected(8'd10, 1'b0, 64'd0, 64'd0,
                       `RV64_FP_FFLAG_UF | `RV64_FP_FFLAG_NX, 1'b0);
        send(8'd10, `OPENRV64_FP_OP_MUL, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h0000_0000_0000_0001, 64'h3fe0_0000_0000_0000, 64'd0);
        queue_expected(8'd11, 1'b0, `RV64_FP_CANONICAL_NAN_D,
                       64'd0, `RV64_FP_FFLAG_NV, 1'b0);
        send(8'd11, `OPENRV64_FP_OP_MUL, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h7ff0_0000_0000_0000, 64'd0, 64'd0);

        queue_expected(8'd12, 1'b0, 64'h8000_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send(8'd12, `OPENRV64_FP_OP_MIN, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h8000_0000_0000_0000, 64'd0, 64'd0);
        queue_expected(8'd13, 1'b0, 64'd0, 64'd0, 5'd0, 1'b0);
        send(8'd13, `OPENRV64_FP_OP_MAX, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h8000_0000_0000_0000, 64'd0, 64'd0);
        queue_expected(8'd14, 1'b1, 64'd0, 64'h200, 5'd0, 1'b0);
        send(8'd14, `OPENRV64_FP_OP_CLASS, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             `RV64_FP_CANONICAL_NAN_D, 64'd0, 64'd0);
        queue_expected(8'd15, 1'b1, 64'd0, 64'hffff_ffff_8000_0001,
                       5'd0, 1'b0);
        send(8'd15, `OPENRV64_FP_OP_MV_X_F, `RV64_FP_FMT_S,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h1234_5678_8000_0001, 64'd0, 64'd0);
        queue_expected(8'd16, 1'b0, 64'hffff_ffff_1234_5678,
                       64'd0, 5'd0, 1'b0);
        send(8'd16, `OPENRV64_FP_OP_MV_F_X, `RV64_FP_FMT_S,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'hdead_beef_1234_5678, 64'd0, 64'd0);
        queue_expected(8'd17, 1'b0, 64'h3fe0_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send(8'd17, `OPENRV64_FP_OP_DIV, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff0_0000_0000_0000, 64'h4000_0000_0000_0000, 64'd0);
        wait_empty();

        // Divide/square-root requests enter their pipeline on consecutive
        // cycles.  Multiply requests do so only in the pipelined-multiply
        // configuration; the shared configuration backpressures them.
        queue_expected(8'd20, 1'b0, 64'h3ff6_a09e_667f_3bcd,
                       64'd0, `RV64_FP_FFLAG_NX, 1'b0);
        send_unstalled(8'd20, `OPENRV64_FP_OP_SQRT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h4000_0000_0000_0000, 64'd0, 64'd0);
        queue_expected(8'd21, 1'b0, 64'hffff_ffff_3fb5_04f3,
                       64'd0, `RV64_FP_FFLAG_NX, 1'b0);
        send_unstalled(8'd21, `OPENRV64_FP_OP_SQRT, `RV64_FP_FMT_S,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'hffff_ffff_4000_0000, 64'd0, 64'd0);
        queue_expected(8'd22, 1'b0, 64'h400a_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send_multiply(8'd22, `OPENRV64_FP_OP_MADD, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff8_0000_0000_0000, 64'h4000_0000_0000_0000,
             64'h3fd0_0000_0000_0000);
        queue_expected(8'd23, 1'b0, 64'h4006_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send_multiply(8'd23, `OPENRV64_FP_OP_MSUB, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff8_0000_0000_0000, 64'h4000_0000_0000_0000,
             64'h3fd0_0000_0000_0000);
        queue_expected(8'd24, 1'b0, 64'hc006_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send_multiply(8'd24, `OPENRV64_FP_OP_NMSUB, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff8_0000_0000_0000, 64'h4000_0000_0000_0000,
             64'h3fd0_0000_0000_0000);
        queue_expected(8'd25, 1'b0, 64'hc00a_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send_multiply(8'd25, `OPENRV64_FP_OP_NMADD, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff8_0000_0000_0000, 64'h4000_0000_0000_0000,
             64'h3fd0_0000_0000_0000);
        queue_expected(8'd26, 1'b0, 64'h3c9f_ffff_ffff_fffe,
                       64'd0, 5'd0, 1'b0);
        send_multiply(8'd26, `OPENRV64_FP_OP_MADD, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff0_0000_0000_0001, 64'h3fef_ffff_ffff_ffff,
             64'hbff0_0000_0000_0000);
        queue_expected(8'd27, 1'b0, 64'h7ff0_0000_0000_0000,
                       64'd0, `RV64_FP_FFLAG_DZ, 1'b0);
        send_unstalled(8'd27, `OPENRV64_FP_OP_DIV, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff0_0000_0000_0000, 64'd0, 64'd0);
        queue_expected(8'd28, 1'b0, `RV64_FP_CANONICAL_NAN_D,
                       64'd0, `RV64_FP_FFLAG_NV, 1'b0);
        send_unstalled(8'd28, `OPENRV64_FP_OP_SQRT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'hbff0_0000_0000_0000, 64'd0, 64'd0);

        queue_expected(8'd29, 1'b1, 64'd0, 64'd4,
                       `RV64_FP_FFLAG_NX, 1'b0);
        send_typed(8'd29, `OPENRV64_FP_OP_CVT_TO_INT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE, `RV64_FP_RS2_L,
             64'h400e_0000_0000_0000, 64'd0, 64'd0);
        queue_expected(8'd30, 1'b1, 64'd0, 64'd3,
                       `RV64_FP_FFLAG_NX, 1'b0);
        send_typed(8'd30, `OPENRV64_FP_OP_CVT_TO_INT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RTZ, `RV64_FP_RM_RNE, `RV64_FP_RS2_L,
             64'h400e_0000_0000_0000, 64'd0, 64'd0);
        queue_expected(8'd31, 1'b1, 64'd0,
                       64'h7fff_ffff_ffff_ffff,
                       `RV64_FP_FFLAG_NV, 1'b0);
        send_typed(8'd31, `OPENRV64_FP_OP_CVT_TO_INT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE, `RV64_FP_RS2_L,
             `RV64_FP_CANONICAL_NAN_D, 64'd0, 64'd0);
        queue_expected(8'd32, 1'b1, 64'd0, 64'd0,
                       `RV64_FP_FFLAG_NV, 1'b0);
        send_typed(8'd32, `OPENRV64_FP_OP_CVT_TO_INT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE, `RV64_FP_RS2_LU,
             64'hbff0_0000_0000_0000, 64'd0, 64'd0);

        queue_expected(8'd33, 1'b0, 64'h43e0_0000_0000_0000,
                       64'd0, `RV64_FP_FFLAG_NX, 1'b0);
        send_typed(8'd33, `OPENRV64_FP_OP_CVT_FROM_INT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE, `RV64_FP_RS2_L,
             64'h7fff_ffff_ffff_ffff, 64'd0, 64'd0);
        queue_expected(8'd34, 1'b0, 64'h43f0_0000_0000_0000,
                       64'd0, `RV64_FP_FFLAG_NX, 1'b0);
        send_typed(8'd34, `OPENRV64_FP_OP_CVT_FROM_INT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE, `RV64_FP_RS2_LU,
             64'hffff_ffff_ffff_ffff, 64'd0, 64'd0);
        queue_expected(8'd35, 1'b0, 64'hffff_ffff_cf00_0000,
                       64'd0, 5'd0, 1'b0);
        send_typed(8'd35, `OPENRV64_FP_OP_CVT_FROM_INT, `RV64_FP_FMT_S,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE, `RV64_FP_RS2_W,
             64'h0000_0000_8000_0000, 64'd0, 64'd0);

        queue_expected(8'd36, 1'b0, 64'hffff_ffff_3f80_0000,
                       64'd0, `RV64_FP_FFLAG_NX, 1'b0);
        send_typed(8'd36, `OPENRV64_FP_OP_CVT_FORMAT, `RV64_FP_FMT_S,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE, `RV64_FP_RS2_D,
             64'h3ff0_0000_1000_0000, 64'd0, 64'd0);
        queue_expected(8'd37, 1'b0, 64'h3ff8_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send_typed(8'd37, `OPENRV64_FP_OP_CVT_FORMAT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE, `RV64_FP_RS2_S,
             64'hffff_ffff_3fc0_0000, 64'd0, 64'd0);
        queue_expected(8'd38, 1'b1, 64'd0, 64'd3,
                       `RV64_FP_FFLAG_NX, 1'b0);
        send_typed(8'd38, `OPENRV64_FP_OP_CVT_TO_INT, `RV64_FP_FMT_D,
             `RV64_FP_RM_DYN, `RV64_FP_RM_RDN, `RV64_FP_RS2_L,
             64'h400e_0000_0000_0000, 64'd0, 64'd0);
        queue_expected(8'd39, 1'b1, 64'd0, 64'd0, 5'd0, 1'b1);
        send_typed(8'd39, `OPENRV64_FP_OP_CVT_TO_INT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE, 5'd7,
             64'h3ff0_0000_0000_0000, 64'd0, 64'd0);
        queue_expected(8'd40, 1'b0, 64'd0, 64'd0, 5'd0, 1'b1);
        send_typed(8'd40, `OPENRV64_FP_OP_CVT_TO_INT, `RV64_FP_FMT_D,
             3'b101, `RV64_FP_RM_RNE, `RV64_FP_RS2_L,
             64'h3ff0_0000_0000_0000, 64'd0, 64'd0);
        queue_expected(8'd41, 1'b1, 64'd0, 64'd0,
                       `RV64_FP_FFLAG_NX, 1'b0);
        send_typed(8'd41, `OPENRV64_FP_OP_CVT_TO_INT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE, `RV64_FP_RS2_L,
             64'h0000_0000_0000_0001, 64'd0, 64'd0);
        queue_expected(8'd42, 1'b1, 64'd0, 64'hffff_ffff_ffff_ffff,
                       `RV64_FP_FFLAG_NX, 1'b0);
        send_typed(8'd42, `OPENRV64_FP_OP_CVT_TO_INT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RDN, `RV64_FP_RM_RNE, `RV64_FP_RS2_L,
             64'h8000_0000_0000_0001, 64'd0, 64'd0);
        queue_expected(8'd43, 1'b1, 64'd0,
                       64'h7fff_ffff_ffff_ffff,
                       `RV64_FP_FFLAG_NV, 1'b0);
        send_typed(8'd43, `OPENRV64_FP_OP_CVT_TO_INT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE, `RV64_FP_RS2_L,
             64'h43e0_0000_0000_0000, 64'd0, 64'd0);
        queue_expected(8'd44, 1'b1, 64'd0,
                       64'h8000_0000_0000_0000, 5'd0, 1'b0);
        send_typed(8'd44, `OPENRV64_FP_OP_CVT_TO_INT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE, `RV64_FP_RS2_L,
             64'hc3e0_0000_0000_0000, 64'd0, 64'd0);
        queue_expected(8'd45, 1'b1, 64'd0, 64'd0,
                       `RV64_FP_FFLAG_NX, 1'b0);
        send_typed(8'd45, `OPENRV64_FP_OP_CVT_TO_INT, `RV64_FP_FMT_D,
             `RV64_FP_RM_RTZ, `RV64_FP_RM_RNE, `RV64_FP_RS2_LU,
             64'h8000_0000_0000_0001, 64'd0, 64'd0);
        wait_empty();

        // Output state must remain stable under backpressure.
        result_ready = 1'b0;
        queue_expected(8'd18, 1'b0, 64'hbfe8_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send(8'd18, `OPENRV64_FP_OP_SUB, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff8_0000_0000_0000, 64'h4002_0000_0000_0000, 64'd0);
        queue_expected(8'd46, 1'b0, 64'h3fe0_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send(8'd46, `OPENRV64_FP_OP_DIV, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff0_0000_0000_0000, 64'h4000_0000_0000_0000,
             64'd0);
        queue_expected(8'd57, 1'b0, 64'h4002_0000_0000_0000,
                       64'd0, 5'd0, 1'b0);
        send_multiply(8'd57, `OPENRV64_FP_OP_MUL, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff8_0000_0000_0000, 64'h3ff8_0000_0000_0000,
             64'd0);
        while (!result_valid) begin
            @(posedge clk);
            @(negedge clk);
        end
        repeat (18) begin
            reg [63:0] held_fp;
            reg [TAG_WIDTH-1:0] held_tag;
            held_fp = fp_result;
            held_tag = result_tag;
            @(posedge clk);
            @(negedge clk);
            if (!result_valid || fp_result != held_fp || result_tag != held_tag)
                $fatal(1, "FPU result changed under backpressure");
        end
        result_ready = 1'b1;
        wait_empty();

        // Flush discards both the iterative pipeline and fast lane.
        result_ready = 1'b0;
        send(8'd19, `OPENRV64_FP_OP_DIV, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff0_0000_0000_0000, 64'h4000_0000_0000_0000,
             64'd0);
        send(8'd47, `OPENRV64_FP_OP_ADD, `RV64_FP_FMT_D,
             `RV64_FP_RM_RNE, `RV64_FP_RM_RNE,
             64'h3ff0_0000_0000_0000, 64'h3ff0_0000_0000_0000,
             64'd0);
        flush = 1'b1;
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;
        result_ready = 1'b1;
        repeat (18) begin
            @(posedge clk);
            @(negedge clk);
            if (result_valid)
                $fatal(1, "flushed FPU request reached output");
        end

        $display("PASS: standalone RV64F/RV64D execution pipelined_mul=%0d",
            ENABLE_PIPELINED_MULTIPLY);
        $finish;
    end

endmodule
