`timescale 1ns/1ps
`include "core/exec/vec/defs.v"

module tb_exec_vec;

    localparam integer VLEN = 256;
    localparam integer MAX_LMUL = 8;
    localparam integer LMUL_WIDTH = 2;
    localparam integer GROUP_WIDTH = VLEN * MAX_LMUL;
    localparam integer SLICE_WIDTH = 64;
    localparam integer SLICE_ADDR_WIDTH = 2;
    localparam integer SLICES_PER_REG = VLEN / SLICE_WIDTH;
    localparam integer REG_ADDR_WIDTH = 5;
    localparam integer TAG_WIDTH = 8;
    localparam [63:0] VTYPE_BIT_M1 = 64'h000;
    localparam [63:0] VTYPE_BIT_M2 = 64'h001;
    localparam [63:0] VTYPE_FP32_M1 = 64'h010;
    localparam [63:0] VTYPE_BF16_M1 = 64'h108;
    localparam [63:0] VTYPE_FP8_M1 = 64'h200;
    localparam [63:0] VTYPE_FP4_M1 = 64'h300;

    reg clk;
    reg rst_n;
    reg dispatch_valid;
    wire dispatch_ready;
    reg [TAG_WIDTH-1:0] dispatch_tag;
    reg [`OPENRV64_VEC_OP_WIDTH-1:0] dispatch_op;
    reg dispatch_acc;
    reg [63:0] dispatch_vtype;
    reg [REG_ADDR_WIDTH-1:0] dispatch_vs1;
    reg [REG_ADDR_WIDTH-1:0] dispatch_vs2;
    reg [REG_ADDR_WIDTH-1:0] dispatch_vd;
    wire [1:0] alu_read_valid;
    wire [1:0] alu_read_ready;
    wire [2*REG_ADDR_WIDTH-1:0] alu_read_addr;
    wire [2*SLICE_ADDR_WIDTH-1:0] alu_read_slice;
    wire [2*SLICE_WIDTH-1:0] alu_read_data;
    reg operands_ready;
    wire complete_valid;
    reg complete_ready;
    wire [TAG_WIDTH-1:0] complete_tag;
    wire complete_unsupported;
    reg retire_valid;
    wire retire_ready;
    reg [TAG_WIDTH-1:0] retire_tag;
    reg retire_kill;
    wire alu_write_valid;
    wire alu_write_ready;
    wire [REG_ADDR_WIDTH-1:0] alu_write_addr;
    wire [SLICE_ADDR_WIDTH-1:0] alu_write_slice;
    wire [SLICE_WIDTH-1:0] alu_write_data;
    wire replay;
    wire busy;

    reg lane_test_valid;
    wire lane_test_ready;
    reg [1:0] lane_test_tag;
    reg lane_test_multiply;
    reg lane_test_mac;
    reg [31:0] lane_test_src1;
    reg [31:0] lane_test_src2;
    reg [31:0] lane_test_src3;
    wire lane_test_result_valid;
    wire [1:0] lane_test_result_tag;
    wire [31:0] lane_test_result;

    reg [REG_ADDR_WIDTH-1:0] test_read_addr;
    reg [SLICE_ADDR_WIDTH-1:0] test_read_slice;
    reg test_read_valid;
    wire [3:0] rf_read_valid =
        {test_read_valid, 1'b0, alu_read_valid};
    wire [3:0] rf_read_ready;
    wire [4*REG_ADDR_WIDTH-1:0] rf_read_addr =
        {test_read_addr, {REG_ADDR_WIDTH{1'b0}}, alu_read_addr};
    wire [4*SLICE_ADDR_WIDTH-1:0] rf_read_slice =
        {test_read_slice, {SLICE_ADDR_WIDTH{1'b0}}, alu_read_slice};
    wire [4*SLICE_WIDTH-1:0] rf_read_data;
    reg test_write_valid;
    wire [1:0] rf_write_ready;
    reg [REG_ADDR_WIDTH-1:0] test_write_addr;
    reg [SLICE_ADDR_WIDTH-1:0] test_write_slice;
    reg [SLICE_WIDTH-1:0] test_write_data;
    wire [1:0] rf_write_valid = {test_write_valid, alu_write_valid};
    wire [2*REG_ADDR_WIDTH-1:0] rf_write_addr =
        {test_write_addr, alu_write_addr};
    wire [2*SLICE_ADDR_WIDTH-1:0] rf_write_slice =
        {test_write_slice, alu_write_slice};
    wire [2*SLICE_WIDTH-1:0] rf_write_data =
        {test_write_data, alu_write_data};
    assign alu_read_ready = rf_read_ready[1:0];
    assign alu_read_data = rf_read_data[0*SLICE_WIDTH +: 2*SLICE_WIDTH];
    assign alu_write_ready = rf_write_ready[0];

    openrv64_rv64i_vec #(
        .VLEN(VLEN), .SLICE_WIDTH(SLICE_WIDTH),
        .REG_ADDR_WIDTH(REG_ADDR_WIDTH)
    ) u_regs (
        .clk(clk), .rst_n(rst_n),
        .read_valid_i(rf_read_valid), .read_ready_o(rf_read_ready),
        .read_addr_i(rf_read_addr), .read_slice_i(rf_read_slice),
        .read_data_o(rf_read_data),
        .write_valid_i(rf_write_valid), .write_ready_o(rf_write_ready),
        .write_addr_i(rf_write_addr), .write_slice_i(rf_write_slice),
        .write_data_i(rf_write_data)
    );

    openrv64_exec_vec #(
        .VLEN(VLEN), .DATAPATH_WIDTH(64),
        .REG_ADDR_WIDTH(REG_ADDR_WIDTH), .TAG_WIDTH(TAG_WIDTH),
        .MAX_LMUL(MAX_LMUL), .LMUL_WIDTH(LMUL_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .dispatch_valid_i(dispatch_valid),
        .dispatch_ready_o(dispatch_ready),
        .dispatch_tag_i(dispatch_tag), .dispatch_op_i(dispatch_op),
        .dispatch_acc_i(dispatch_acc),
        .dispatch_vtype_i(dispatch_vtype), .dispatch_vs1_i(dispatch_vs1),
        .dispatch_vs2_i(dispatch_vs2), .dispatch_vd_i(dispatch_vd),
        .rf_read_valid_o(alu_read_valid),
        .rf_read_ready_i(alu_read_ready),
        .rf_read_addr_o(alu_read_addr), .rf_read_slice_o(alu_read_slice),
        .rf_read_data_i(alu_read_data),
        .operands_ready_i(operands_ready),
        .complete_valid_o(complete_valid),
        .complete_ready_i(complete_ready), .complete_tag_o(complete_tag),
        .complete_unsupported_o(complete_unsupported),
        .retire_valid_i(retire_valid), .retire_ready_o(retire_ready),
        .retire_tag_i(retire_tag), .retire_kill_i(retire_kill),
        .rf_write_valid_o(alu_write_valid),
        .rf_write_ready_i(alu_write_ready),
        .rf_write_addr_o(alu_write_addr),
        .rf_write_slice_o(alu_write_slice),
        .rf_write_data_o(alu_write_data),
        .replay_o(replay), .busy_o(busy)
    );

    openrv64_exec_vec_fp32_lane #(
        .TAG_WIDTH(2), .ADD_LATENCY(4), .MUL_LATENCY(7),
        .MAC_LATENCY(11)
    ) u_lane_timing (
        .clk(clk), .rst_n(rst_n), .flush_i(1'b0),
        .valid_i(lane_test_valid), .ready_o(lane_test_ready),
        .tag_i(lane_test_tag), .multiply_i(lane_test_multiply),
        .mac_i(lane_test_mac), .src1_i(lane_test_src1),
        .src2_i(lane_test_src2), .src3_i(lane_test_src3),
        .result_valid_o(lane_test_result_valid), .result_ready_i(1'b1),
        .result_tag_o(lane_test_result_tag), .result_o(lane_test_result)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic write_group;
        input [REG_ADDR_WIDTH-1:0] addr;
        input [LMUL_WIDTH-1:0] lmul;
        input [GROUP_WIDTH-1:0] data;
        integer slice;
        integer slice_count;
        begin
            slice_count = SLICES_PER_REG << lmul;
            for (slice = 0; slice < slice_count; slice = slice + 1) begin
                @(negedge clk);
                test_write_addr = addr + (slice / SLICES_PER_REG);
                test_write_slice = slice % SLICES_PER_REG;
                test_write_data = data[slice*SLICE_WIDTH +: SLICE_WIDTH];
                test_write_valid = 1'b1;
                #1;
                while (!rf_write_ready[1]) begin
                    @(posedge clk);
                    @(negedge clk);
                    #1;
                end
                @(posedge clk);
            end
            @(negedge clk);
            test_write_valid = 1'b0;
        end
    endtask

    task automatic write_vec;
        input [REG_ADDR_WIDTH-1:0] addr;
        input [VLEN-1:0] data;
        reg [GROUP_WIDTH-1:0] group_data;
        begin
            group_data = {GROUP_WIDTH{1'b0}};
            group_data[VLEN-1:0] = data;
            write_group(addr, 2'd0, group_data);
        end
    endtask

    task automatic check_group;
        input [REG_ADDR_WIDTH-1:0] addr;
        input [LMUL_WIDTH-1:0] lmul;
        input [GROUP_WIDTH-1:0] expected;
        input [8*40-1:0] label;
        integer slice;
        integer slice_count;
        begin
            slice_count = SLICES_PER_REG << lmul;
            test_read_valid = 1'b1;
            for (slice = 0; slice < slice_count; slice = slice + 1) begin
                test_read_addr = addr + (slice / SLICES_PER_REG);
                test_read_slice = slice % SLICES_PER_REG;
                #1;
                if (!rf_read_ready[3])
                    $fatal(1, "%0s: test read bank was blocked", label);
                if (rf_read_data[3*SLICE_WIDTH +: SLICE_WIDTH] !==
                    expected[slice*SLICE_WIDTH +: SLICE_WIDTH])
                    $fatal(1, "%0s: slice %0d mismatch", label, slice);
            end
            test_read_valid = 1'b0;
        end
    endtask

    task automatic check_vec;
        input [REG_ADDR_WIDTH-1:0] addr;
        input [VLEN-1:0] expected;
        input [8*40-1:0] label;
        reg [GROUP_WIDTH-1:0] group_data;
        begin
            group_data = {GROUP_WIDTH{1'b0}};
            group_data[VLEN-1:0] = expected;
            check_group(addr, 2'd0, group_data, label);
        end
    endtask

    task automatic send_acc;
        input [TAG_WIDTH-1:0] tag;
        input [`OPENRV64_VEC_OP_WIDTH-1:0] op;
        input [63:0] vtype;
        input [REG_ADDR_WIDTH-1:0] vs1;
        input [REG_ADDR_WIDTH-1:0] vs2;
        input [REG_ADDR_WIDTH-1:0] vd;
        input acc;
        reg accepted;
        begin
            // Operation is part of the ready calculation: accumulator
            // commands may be blocked while an ordinary command is accepted.
            // Drive the complete request before waiting for ready.
            dispatch_tag = tag;
            dispatch_op = op;
            dispatch_acc = acc;
            dispatch_vtype = vtype;
            dispatch_vs1 = vs1;
            dispatch_vs2 = vs2;
            dispatch_vd = vd;
            dispatch_valid = 1'b1;
            accepted = 1'b0;
            while (!accepted) begin
                @(posedge clk);
                accepted = dispatch_ready;
                @(negedge clk);
            end
            dispatch_valid = 1'b0;
        end
    endtask

    task automatic send;
        input [TAG_WIDTH-1:0] tag;
        input [`OPENRV64_VEC_OP_WIDTH-1:0] op;
        input [63:0] vtype;
        input [REG_ADDR_WIDTH-1:0] vs1;
        input [REG_ADDR_WIDTH-1:0] vs2;
        input [REG_ADDR_WIDTH-1:0] vd;
        begin
            send_acc(tag, op, vtype, vs1, vs2, vd, 1'b0);
        end
    endtask

    task automatic finish_command;
        input [TAG_WIDTH-1:0] tag;
        input expected_unsupported;
        integer timeout;
        begin
            timeout = 0;
            while (!complete_valid && timeout < 200) begin
                @(posedge clk);
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!complete_valid)
                $fatal(1, "tag %0d timed out waiting for vector completion", tag);
            if (complete_tag !== tag ||
                complete_unsupported !== expected_unsupported)
                $fatal(1, "tag %0d bad completion tag=%0d unsupported=%0b",
                       tag, complete_tag, complete_unsupported);

            complete_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            complete_ready = 1'b0;

            retire_tag = tag;
            retire_kill = 1'b0;
            retire_valid = 1'b1;
            timeout = 0;
            #1;
            while (!retire_ready && timeout < 200) begin
                @(posedge clk);
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!retire_ready)
                $fatal(1, "tag %0d vector retirement timed out", tag);
            @(posedge clk);
            @(negedge clk);
            retire_valid = 1'b0;
        end
    endtask

    task automatic check_lane_latency;
        input multiply;
        input mac;
        input [1:0] tag;
        input [31:0] expected_result;
        input integer expected_latency;
        integer cycles;
        begin
            @(negedge clk);
            lane_test_valid = 1'b1;
            lane_test_tag = tag;
            lane_test_multiply = multiply;
            lane_test_mac = mac;
            lane_test_src1 = 32'h4000_0000;
            lane_test_src2 = 32'h4000_0000;
            lane_test_src3 = 32'h3f80_0000;
            #1;
            if (!lane_test_ready)
                $fatal(1, "timing-test lane did not accept an idle token");
            @(posedge clk);
            @(negedge clk);
            lane_test_valid = 1'b0;
            cycles = 0;
            while (!lane_test_result_valid && cycles < 32) begin
                @(posedge clk);
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!lane_test_result_valid)
                $fatal(1, "timing-test lane result timed out");
            if (cycles != expected_latency)
                $fatal(1, "lane latency was %0d cycles, expected %0d",
                       cycles, expected_latency);
            if ((lane_test_result_tag !== tag) ||
                (lane_test_result !== expected_result))
                $fatal(1, "timing-test lane result/tag mismatch");
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    reg [GROUP_WIDTH-1:0] group_a;
    reg [GROUP_WIDTH-1:0] group_b;
    reg [GROUP_WIDTH-1:0] group_expected;
    integer overlap_timeout;
    integer overlap_scan;
    reg overlap_first_fed;
    reg overlap_second_fed;
    initial begin
        dispatch_valid = 1'b0;
        dispatch_tag = 8'd0;
        dispatch_op = `OPENRV64_VEC_OP_INVALID;
        dispatch_acc = 1'b0;
        dispatch_vtype = VTYPE_BIT_M1;
        dispatch_vs1 = 5'd0;
        dispatch_vs2 = 5'd0;
        dispatch_vd = 5'd0;
        operands_ready = 1'b1;
        complete_ready = 1'b0;
        retire_valid = 1'b0;
        retire_tag = 8'd0;
        retire_kill = 1'b0;
        test_read_addr = 5'd0;
        test_read_slice = 2'd0;
        test_read_valid = 1'b0;
        test_write_valid = 1'b0;
        test_write_addr = 5'd0;
        test_write_slice = 2'd0;
        test_write_data = 64'd0;
        lane_test_valid = 1'b0;
        lane_test_tag = 2'd0;
        lane_test_multiply = 1'b0;
        lane_test_mac = 1'b0;
        lane_test_src1 = 32'd0;
        lane_test_src2 = 32'd0;
        lane_test_src3 = 32'd0;
        group_a = {GROUP_WIDTH{1'b0}};
        group_b = {GROUP_WIDTH{1'b0}};
        group_expected = {GROUP_WIDTH{1'b0}};

        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        check_lane_latency(1'b0, 1'b0, 2'd1, 32'h4080_0000, 4);
        check_lane_latency(1'b1, 1'b0, 2'd2, 32'h4080_0000, 7);
        check_lane_latency(1'b0, 1'b1, 2'd3, 32'h40a0_0000, 11);

        write_vec(5'd1, {4{64'hff00_ff00_aaaa_5555}});
        write_vec(5'd2, {4{64'h0f0f_f0f0_1234_ffff}});
        send(8'd1, `OPENRV64_VEC_OP_XOR, VTYPE_BIT_M1,
             5'd1, 5'd2, 5'd3);
        finish_command(8'd1, 1'b0);
        check_vec(5'd3,
                  {4{(64'hff00_ff00_aaaa_5555 ^
                       64'h0f0f_f0f0_1234_ffff)}}, "xor");

        write_vec(5'd4, {8{32'h3f80_0000}});
        write_vec(5'd5, {8{32'h4000_0000}});
        send(8'd2, `OPENRV64_VEC_OP_FADD, VTYPE_FP32_M1,
             5'd4, 5'd5, 5'd6);
        finish_command(8'd2, 1'b0);
        check_vec(5'd6, {8{32'h4040_0000}}, "fp32 add");

        write_vec(5'd7, {16{16'h3fc0}});
        write_vec(5'd8, {16{16'h4000}});
        send(8'd3, `OPENRV64_VEC_OP_FMUL, VTYPE_BF16_M1,
             5'd7, 5'd8, 5'd9);
        finish_command(8'd3, 1'b0);
        check_vec(5'd9, {16{16'h4040}}, "bf16 multiply");

        write_vec(5'd10, {32{8'h38}});
        write_vec(5'd11, {32{8'h40}});
        send(8'd4, `OPENRV64_VEC_OP_FADD, VTYPE_FP8_M1,
             5'd10, 5'd11, 5'd12);
        finish_command(8'd4, 1'b0);
        check_vec(5'd12, {32{8'h44}}, "fp8 add");

        write_vec(5'd13, {64{4'h2}});
        write_vec(5'd14, {64{4'h4}});
        send(8'd5, `OPENRV64_VEC_OP_FADD, VTYPE_FP4_M1,
             5'd13, 5'd14, 5'd15);
        finish_command(8'd5, 1'b0);
        check_vec(5'd15, {64{4'h5}}, "fp4 add");

        operands_ready = 1'b0;
        send(8'd6, `OPENRV64_VEC_OP_NOT, VTYPE_BIT_M1,
             5'd1, 5'd0, 5'd16);
        #1;
        if (!replay)
            $fatal(1, "vector operand replay was not visible");
        repeat (2) @(posedge clk);
        @(negedge clk);
        operands_ready = 1'b1;
        finish_command(8'd6, 1'b0);
        check_vec(5'd16, ~{4{64'hff00_ff00_aaaa_5555}},
                  "internal replay");

        // FP64 remains absent: xfmt=FP32 with vsew=64 is rejected.
        write_vec(5'd17, {4{64'h1717_1717_1717_1717}});
        send(8'd7, `OPENRV64_VEC_OP_FADD, 64'h018,
             5'd4, 5'd5, 5'd17);
        finish_command(8'd7, 1'b1);
        check_vec(5'd17, {4{64'h1717_1717_1717_1717}}, "no fp64");

        // LMUL=2 consumes and produces v-register groups.
        group_a = {GROUP_WIDTH{1'b0}};
        group_b = {GROUP_WIDTH{1'b0}};
        group_expected = {GROUP_WIDTH{1'b0}};
        group_a[0*VLEN +: VLEN] = {4{64'h1111_0000_ffff_aaaa}};
        group_a[1*VLEN +: VLEN] = {4{64'h2222_3333_4444_5555}};
        group_b[0*VLEN +: VLEN] = {4{64'h00ff_0f0f_f0f0_5555}};
        group_b[1*VLEN +: VLEN] = {4{64'haaaa_5555_3333_cccc}};
        group_expected[0*VLEN +: VLEN] =
            group_a[0*VLEN +: VLEN] ^ group_b[0*VLEN +: VLEN];
        group_expected[1*VLEN +: VLEN] =
            group_a[1*VLEN +: VLEN] ^ group_b[1*VLEN +: VLEN];
        write_group(5'd20, 2'd1, group_a);
        write_group(5'd22, 2'd1, group_b);
        send(8'd8, `OPENRV64_VEC_OP_XOR, VTYPE_BIT_M2,
             5'd20, 5'd22, 5'd24);
        finish_command(8'd8, 1'b0);
        check_group(5'd24, 2'd1, group_expected, "m2 xor");

        // A tagged kill cannot expose a partial group result.
        send(8'd9, `OPENRV64_VEC_OP_XOR, VTYPE_BIT_M2,
             5'd20, 5'd22, 5'd26);
        repeat (2) @(posedge clk);
        @(negedge clk);
        retire_tag = 8'd9;
        retire_kill = 1'b1;
        retire_valid = 1'b1;
        #1;
        if (!retire_ready)
            $fatal(1, "executing vector kill was not accepted");
        @(posedge clk);
        @(negedge clk);
        retire_valid = 1'b0;
        retire_kill = 1'b0;
        repeat (12) @(posedge clk);
        @(negedge clk);
        if (complete_valid || busy)
            $fatal(1, "killed vector command remained live");
        check_group(5'd26, 2'd1, {GROUP_WIDTH{1'b0}},
                    "killed group isolation");

        // Exact-zero paths bypass significand alignment/multiplication logic
        // inside each FP32 lane while retaining tagged pipeline ordering.
        write_vec(5'd28, 256'd0);
        write_vec(5'd29, {8{32'h4000_0000}});
        send(8'd10, `OPENRV64_VEC_OP_FADD, VTYPE_FP32_M1,
             5'd28, 5'd29, 5'd30);
        finish_command(8'd10, 1'b0);
        check_vec(5'd30, {8{32'h4000_0000}}, "fp32 zero add");
        send(8'd11, `OPENRV64_VEC_OP_FMUL, VTYPE_FP32_M1,
             5'd28, 5'd29, 5'd31);
        finish_command(8'd11, 1'b0);
        check_vec(5'd31, 256'd0, "fp32 zero multiply");

        // When both complete 64-bit source slices are +0, the slice is
        // deposited directly into the tagged result buffer without occupying
        // an FP lane token. Exercise all four slices of an m1 register.
        send(8'd12, `OPENRV64_VEC_OP_FADD, VTYPE_FP32_M1,
             5'd28, 5'd28, 5'd27);
        finish_command(8'd12, 1'b0);
        check_vec(5'd27, 256'd0, "fp32 all-zero slice bypass");

        // Two independent commands must both feed the shared FP lanes while
        // both contexts remain live. A four-cycle ADD can legitimately finish
        // before all four slices of the following MUL have entered.
        send(8'd13, `OPENRV64_VEC_OP_FADD, VTYPE_FP32_M1,
             5'd4, 5'd5, 5'd18);
        send(8'd14, `OPENRV64_VEC_OP_FMUL, VTYPE_FP32_M1,
             5'd4, 5'd5, 5'd19);
        overlap_timeout = 0;
        overlap_first_fed = 1'b0;
        overlap_second_fed = 1'b0;
        while (!(overlap_first_fed && overlap_second_fed) &&
               (overlap_timeout < 40)) begin
            @(negedge clk);
            overlap_first_fed = 1'b0;
            overlap_second_fed = 1'b0;
            for (overlap_scan = 0; overlap_scan < 8;
                 overlap_scan = overlap_scan + 1) begin
                if (dut.slot_valid_q[overlap_scan] &&
                    (dut.slot_tag_q[overlap_scan] == 8'd13) &&
                    dut.slot_feed_done_q[overlap_scan])
                    overlap_first_fed = 1'b1;
                if (dut.slot_valid_q[overlap_scan] &&
                    (dut.slot_tag_q[overlap_scan] == 8'd14) &&
                    dut.slot_feed_done_q[overlap_scan])
                    overlap_second_fed = 1'b1;
            end
            overlap_timeout = overlap_timeout + 1;
        end
        if (!(overlap_first_fed && overlap_second_fed))
            $fatal(1, "independent vector commands did not both feed");
        finish_command(8'd13, 1'b0);
        finish_command(8'd14, 1'b0);
        check_vec(5'd18, {8{32'h4040_0000}}, "overlapped fp32 add");
        check_vec(5'd19, {8{32'h4000_0000}}, "overlapped fp32 multiply");

        // A private accumulator is loaded and exported explicitly, but a
        // MAC names only its two multiplicands. 1.0 + 1.0*2.0 = 3.0.
        send(8'd15, `OPENRV64_VEC_OP_VLDA, VTYPE_FP32_M1,
             5'd4, 5'd0, 5'd0);
        finish_command(8'd15, 1'b0);
        send(8'd16, `OPENRV64_VEC_OP_VMAC, VTYPE_FP32_M1,
             5'd4, 5'd5, 5'd0);
        // The accumulator recurrence blocks another accumulator command, not
        // independent vector work. This FADD feeds while the 11-cycle VMAC is
        // still live and completes into its own tagged result context.
        send(8'd17, `OPENRV64_VEC_OP_FADD, VTYPE_FP32_M1,
             5'd4, 5'd5, 5'd23);
        finish_command(8'd16, 1'b0);
        finish_command(8'd17, 1'b0);
        check_vec(5'd23, {8{32'h4040_0000}}, "MAC overlap add");
        send(8'd18, `OPENRV64_VEC_OP_VSTA, VTYPE_FP32_M1,
             5'd0, 5'd0, 5'd20);
        finish_command(8'd18, 1'b0);
        check_vec(5'd20, {8{32'h4040_0000}}, "fp32 private MAC");

        // Narrow products remain FP32 through the addition and round once on
        // the way back into the native-format accumulator.
        send(8'd19, `OPENRV64_VEC_OP_VLDA, VTYPE_BF16_M1,
             5'd7, 5'd0, 5'd0);
        finish_command(8'd19, 1'b0);
        send(8'd20, `OPENRV64_VEC_OP_VMAC, VTYPE_BF16_M1,
             5'd7, 5'd8, 5'd0);
        finish_command(8'd20, 1'b0);
        send(8'd21, `OPENRV64_VEC_OP_VSTA, VTYPE_BF16_M1,
             5'd0, 5'd0, 5'd21);
        finish_command(8'd21, 1'b0);
        check_vec(5'd21, {16{16'h4090}}, "bf16 private MAC");

        // A completed but killed VMAC must not leak into private state. Reload
        // 1.0, kill the pending +2.0 update, then export and observe 1.0.
        send(8'd22, `OPENRV64_VEC_OP_VLDA, VTYPE_FP32_M1,
             5'd4, 5'd0, 5'd0);
        finish_command(8'd22, 1'b0);
        send(8'd23, `OPENRV64_VEC_OP_VMAC, VTYPE_FP32_M1,
             5'd4, 5'd5, 5'd0);
        overlap_timeout = 0;
        while (!complete_valid && (overlap_timeout < 200)) begin
            @(posedge clk);
            @(negedge clk);
            overlap_timeout = overlap_timeout + 1;
        end
        if (!complete_valid || (complete_tag != 8'd23))
            $fatal(1, "killed VMAC did not reach tagged completion");
        retire_tag = 8'd23;
        retire_kill = 1'b1;
        retire_valid = 1'b1;
        #1;
        if (!retire_ready)
            $fatal(1, "completed VMAC kill was not accepted");
        @(posedge clk);
        @(negedge clk);
        retire_valid = 1'b0;
        retire_kill = 1'b0;
        send(8'd24, `OPENRV64_VEC_OP_VSTA, VTYPE_FP32_M1,
             5'd0, 5'd0, 5'd22);
        finish_command(8'd24, 1'b0);
        check_vec(5'd22, {8{32'h3f80_0000}}, "killed private MAC");

        send(8'd25, `OPENRV64_VEC_OP_VLDA, VTYPE_FP8_M1,
             5'd10, 5'd0, 5'd0);
        finish_command(8'd25, 1'b0);
        send(8'd26, `OPENRV64_VEC_OP_VMAC, VTYPE_FP8_M1,
             5'd10, 5'd11, 5'd0);
        finish_command(8'd26, 1'b0);
        send(8'd27, `OPENRV64_VEC_OP_VSTA, VTYPE_FP8_M1,
             5'd0, 5'd0, 5'd24);
        finish_command(8'd27, 1'b0);
        check_vec(5'd24, {32{8'h44}}, "fp8 private MAC");

        send(8'd28, `OPENRV64_VEC_OP_VLDA, VTYPE_FP4_M1,
             5'd13, 5'd0, 5'd0);
        finish_command(8'd28, 1'b0);
        send(8'd29, `OPENRV64_VEC_OP_VMAC, VTYPE_FP4_M1,
             5'd13, 5'd14, 5'd0);
        finish_command(8'd29, 1'b0);
        send(8'd30, `OPENRV64_VEC_OP_VSTA, VTYPE_FP4_M1,
             5'd0, 5'd0, 5'd25);
        finish_command(8'd30, 1'b0);
        check_vec(5'd25, {64{4'h5}}, "fp4 private MAC");

        // Different accumulator contexts are independent recurrences. Their
        // VMAC commands must both feed before the first 11-cycle result exits.
        send_acc(8'd31, `OPENRV64_VEC_OP_VLDA, VTYPE_FP32_M1,
                 5'd4, 5'd0, 5'd0, 1'b0);
        send_acc(8'd32, `OPENRV64_VEC_OP_VLDA, VTYPE_FP32_M1,
                 5'd5, 5'd0, 5'd0, 1'b1);
        finish_command(8'd31, 1'b0);
        finish_command(8'd32, 1'b0);
        send_acc(8'd33, `OPENRV64_VEC_OP_VMAC, VTYPE_FP32_M1,
                 5'd4, 5'd5, 5'd0, 1'b0);
        send_acc(8'd34, `OPENRV64_VEC_OP_VMAC, VTYPE_FP32_M1,
                 5'd5, 5'd5, 5'd0, 1'b1);
        overlap_timeout = 0;
        overlap_first_fed = 1'b0;
        overlap_second_fed = 1'b0;
        while (!(overlap_first_fed && overlap_second_fed) &&
               (overlap_timeout < 40)) begin
            @(posedge clk);
            @(negedge clk);
            overlap_first_fed = 1'b0;
            overlap_second_fed = 1'b0;
            for (overlap_scan = 0; overlap_scan < 8;
                 overlap_scan = overlap_scan + 1) begin
                if (dut.slot_valid_q[overlap_scan] &&
                    (dut.slot_tag_q[overlap_scan] == 8'd33) &&
                    dut.slot_feed_done_q[overlap_scan])
                    overlap_first_fed = 1'b1;
                if (dut.slot_valid_q[overlap_scan] &&
                    (dut.slot_tag_q[overlap_scan] == 8'd34) &&
                    dut.slot_feed_done_q[overlap_scan])
                    overlap_second_fed = 1'b1;
            end
            overlap_timeout = overlap_timeout + 1;
        end
        if (!(overlap_first_fed && overlap_second_fed))
            $fatal(1, "dual accumulator VMACs did not overlap");
        if (complete_valid)
            $fatal(1, "dual accumulator VMAC completed before both fed");
        finish_command(8'd33, 1'b0);
        finish_command(8'd34, 1'b0);
        send_acc(8'd35, `OPENRV64_VEC_OP_VSTA, VTYPE_FP32_M1,
                 5'd0, 5'd0, 5'd26, 1'b0);
        send_acc(8'd36, `OPENRV64_VEC_OP_VSTA, VTYPE_FP32_M1,
                 5'd0, 5'd0, 5'd27, 1'b1);
        finish_command(8'd35, 1'b0);
        finish_command(8'd36, 1'b0);
        check_vec(5'd26, {8{32'h4040_0000}}, "dual MAC acc0");
        check_vec(5'd27, {8{32'h40c0_0000}}, "dual MAC acc1");

        $display("PASS: overlapping vector arithmetic and dual private MAC");
        $finish;
    end

endmodule
