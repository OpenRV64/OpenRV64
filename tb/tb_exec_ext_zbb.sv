`timescale 1ns/1ps
`include "core/exec/ext/zbb.v"
`include "core/exec/alu/rv64-i.v"

module tb_exec_ext_zbb;
    reg clk;
    reg rst_n;
    reg flush;
    reg valid;
    wire ready;
    wire busy;
    reg [`RV64_ALU_OP_WIDTH-1:0] op;
    reg word_op;
    reg [63:0] src1;
    reg [63:0] src2;
    wire result_valid;
    reg result_ready;
    wire illegal;
    wire [63:0] result;
    wire alu_request;
    wire [`RV64_ALU_OP_WIDTH-1:0] alu_op;
    wire alu_word;
    wire [63:0] alu_src1;
    wire [63:0] alu_src2;
    wire alu_valid;
    wire alu_illegal;
    wire [63:0] alu_result;
    integer test_index;
    reg [63:0] random_a;
    reg [63:0] random_b;

    openrv64_exec_ext_zbb dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .valid_i(valid), .ready_o(ready), .busy_o(busy),
        .op_sel_i(op), .word_op_i(word_op),
        .src1_i(src1), .src2_i(src2),
        .alu_request_o(alu_request), .alu_op_o(alu_op),
        .alu_word_o(alu_word), .alu_src1_o(alu_src1),
        .alu_src2_o(alu_src2), .alu_valid_i(alu_valid),
        .alu_result_i(alu_result),
        .result_valid_o(result_valid), .result_ready_i(result_ready),
        .illegal_o(illegal), .result_o(result)
    );

    openrv64_exec_alu_rv64i reused_alu (
        .op_sel_i(alu_op), .word_op_i(alu_word),
        .src1_i(alu_src1), .src2_i(alu_src2), .pc_i(64'd0),
        .valid_o(alu_valid), .illegal_o(alu_illegal),
        .result_o(alu_result)
    );

    always #5 clk = ~clk;

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    function automatic [63:0] ref_clz;
        input [63:0] value;
        input word_value;
        integer bit_index;
        integer width;
        reg found;
        reg [6:0] total;
        begin
            width = word_value ? 32 : 64;
            found = 1'b0;
            total = 7'd0;
            for (bit_index = width - 1; bit_index >= 0;
                 bit_index = bit_index - 1) begin
                if (!found) begin
                    if (value[bit_index])
                        found = 1'b1;
                    else
                        total = total + 1'b1;
                end
            end
            ref_clz = {57'd0, total};
        end
    endfunction

    function automatic [63:0] ref_ctz;
        input [63:0] value;
        input word_value;
        integer bit_index;
        integer width;
        reg found;
        reg [6:0] total;
        begin
            width = word_value ? 32 : 64;
            found = 1'b0;
            total = 7'd0;
            for (bit_index = 0; bit_index < width;
                 bit_index = bit_index + 1) begin
                if (!found) begin
                    if (value[bit_index])
                        found = 1'b1;
                    else
                        total = total + 1'b1;
                end
            end
            ref_ctz = {57'd0, total};
        end
    endfunction

    function automatic [63:0] ref_cpop;
        input [63:0] value;
        input word_value;
        integer bit_index;
        integer width;
        reg [6:0] total;
        begin
            width = word_value ? 32 : 64;
            total = 7'd0;
            for (bit_index = 0; bit_index < width;
                 bit_index = bit_index + 1)
                total = total + value[bit_index];
            ref_cpop = {57'd0, total};
        end
    endfunction

    function automatic [63:0] ref_ror;
        input [63:0] value;
        input [63:0] amount;
        input word_value;
        reg [5:0] shamt;
        reg [31:0] word_result;
        begin
            if (word_value) begin
                shamt = {1'b0, amount[4:0]};
                if (shamt == 0)
                    word_result = value[31:0];
                else
                    word_result = (value[31:0] >> shamt) |
                                  (value[31:0] << (32 - shamt));
                ref_ror = {{32{word_result[31]}}, word_result};
            end else begin
                shamt = amount[5:0];
                if (shamt == 0)
                    ref_ror = value;
                else
                    ref_ror = (value >> shamt) | (value << (64 - shamt));
            end
        end
    endfunction

    function automatic [63:0] ref_rol;
        input [63:0] value;
        input [63:0] amount;
        input word_value;
        reg [5:0] shamt;
        reg [31:0] word_result;
        begin
            if (word_value) begin
                shamt = {1'b0, amount[4:0]};
                if (shamt == 0)
                    word_result = value[31:0];
                else
                    word_result = (value[31:0] << shamt) |
                                  (value[31:0] >> (32 - shamt));
                ref_rol = {{32{word_result[31]}}, word_result};
            end else begin
                shamt = amount[5:0];
                if (shamt == 0)
                    ref_rol = value;
                else
                    ref_rol = (value << shamt) | (value >> (64 - shamt));
            end
        end
    endfunction

    function automatic [63:0] ref_orc_b;
        input [63:0] value;
        integer byte_index;
        begin
            ref_orc_b = 64'd0;
            for (byte_index = 0; byte_index < 8;
                 byte_index = byte_index + 1)
                ref_orc_b[byte_index*8 +: 8] =
                    (|value[byte_index*8 +: 8]) ? 8'hff : 8'h00;
        end
    endfunction

    function automatic [63:0] ref_rev8;
        input [63:0] value;
        integer byte_index;
        begin
            for (byte_index = 0; byte_index < 8;
                 byte_index = byte_index + 1)
                ref_rev8[byte_index*8 +: 8] =
                    value[(7-byte_index)*8 +: 8];
        end
    endfunction

    task automatic run_op;
        input [`RV64_ALU_OP_WIDTH-1:0] test_op;
        input test_word;
        input [63:0] test_src1;
        input [63:0] test_src2;
        input [63:0] expected;
        input integer max_latency;
        input [8*24-1:0] name;
        integer latency;
        reg [63:0] held_result;
        begin
            while (!ready)
                tick();
            op = test_op;
            word_op = test_word;
            src1 = test_src1;
            src2 = test_src2;
            valid = 1'b1;
            #1;
            if (!ready)
                $fatal(1, "%0s request was not accepted", name);
            tick();
            valid = 1'b0;

            latency = 0;
            while (!result_valid && (latency <= max_latency)) begin
                if (!busy)
                    $fatal(1, "%0s dropped busy before result", name);
                tick();
                latency = latency + 1;
            end
            if (!result_valid)
                $fatal(1, "%0s exceeded latency bound %0d", name,
                       max_latency);
            if (illegal)
                $fatal(1, "%0s returned illegal", name);
            if (result !== expected)
                $fatal(1, "%0s result=%016x expected=%016x",
                       name, result, expected);

            held_result = result;
            repeat (2) begin
                if (!result_valid || !busy || ready || result != held_result)
                    $fatal(1, "%0s result backpressure was not held", name);
                tick();
            end
            result_ready = 1'b1;
            tick();
            result_ready = 1'b0;
            if (result_valid || busy || !ready)
                $fatal(1, "%0s result did not release", name);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        valid = 1'b0;
        op = `RV64_ALU_OP_INVALID;
        word_op = 1'b0;
        src1 = 64'd0;
        src2 = 64'd0;
        result_ready = 1'b0;
        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        run_op(`RV64_ALU_OP_ZBB_ANDN, 1'b0,
               64'h0123_4567_89ab_cdef, 64'h00ff_0f0f_f0f0_55aa,
               64'h0123_4567_89ab_cdef &
               ~64'h00ff_0f0f_f0f0_55aa, 4, "andn");
        run_op(`RV64_ALU_OP_ZBB_ORN, 1'b0,
               64'h0123_4567_89ab_cdef, 64'h00ff_0f0f_f0f0_55aa,
               64'h0123_4567_89ab_cdef |
               ~64'h00ff_0f0f_f0f0_55aa, 4, "orn");
        run_op(`RV64_ALU_OP_ZBB_XNOR, 1'b0,
               64'h0123_4567_89ab_cdef, 64'h00ff_0f0f_f0f0_55aa,
               ~(64'h0123_4567_89ab_cdef ^ 64'h00ff_0f0f_f0f0_55aa),
               4, "xnor");

        run_op(`RV64_ALU_OP_ZBB_MIN, 1'b0,
               64'hffff_ffff_ffff_fffe, 64'd7,
               64'hffff_ffff_ffff_fffe, 4, "min");
        run_op(`RV64_ALU_OP_ZBB_MAX, 1'b0,
               64'hffff_ffff_ffff_fffe, 64'd7, 64'd7, 4, "max");
        run_op(`RV64_ALU_OP_ZBB_MINU, 1'b0,
               64'hffff_ffff_ffff_fffe, 64'd7, 64'd7, 4, "minu");
        run_op(`RV64_ALU_OP_ZBB_MAXU, 1'b0,
               64'hffff_ffff_ffff_fffe, 64'd7,
               64'hffff_ffff_ffff_fffe, 4, "maxu");

        run_op(`RV64_ALU_OP_ZBB_CLZ, 1'b0, 64'd0, 64'd0,
               64'd64, 6, "clz-zero");
        run_op(`RV64_ALU_OP_ZBB_CLZ, 1'b0,
               64'h0000_0000_0010_0000, 64'd0, 64'd43, 6, "clz");
        run_op(`RV64_ALU_OP_ZBB_CTZ, 1'b0, 64'd0, 64'd0,
               64'd64, 6, "ctz-zero");
        run_op(`RV64_ALU_OP_ZBB_CTZ, 1'b0,
               64'h1000_0000_0000_0400, 64'd0, 64'd10, 6, "ctz");
        run_op(`RV64_ALU_OP_ZBB_CPOP, 1'b0,
               64'hf0f0_8000_0000_0001, 64'd0, 64'd10, 4, "cpop");
        run_op(`RV64_ALU_OP_ZBB_CLZ, 1'b1,
               64'hffff_ffff_0000_0100, 64'd0, 64'd23, 6, "clzw");
        run_op(`RV64_ALU_OP_ZBB_CTZ, 1'b1,
               64'hffff_ffff_8000_0100, 64'd0, 64'd8, 6, "ctzw");
        run_op(`RV64_ALU_OP_ZBB_CPOP, 1'b1,
               64'hffff_ffff_f000_0001, 64'd0, 64'd5, 2, "cpopw");

        run_op(`RV64_ALU_OP_ZBB_SEXT_B, 1'b0,
               64'h1234_5678_9abc_de80, 64'd0,
               64'hffff_ffff_ffff_ff80, 0, "sext.b");
        run_op(`RV64_ALU_OP_ZBB_SEXT_H, 1'b0,
               64'h1234_5678_9abc_8001, 64'd0,
               64'hffff_ffff_ffff_8001, 0, "sext.h");
        run_op(`RV64_ALU_OP_ZBB_ZEXT_H, 1'b1,
               64'hffff_ffff_abcd_8001, 64'd0,
               64'h0000_0000_0000_8001, 0, "zext.h");
        run_op(`RV64_ALU_OP_ZBB_ORC_B, 1'b0,
               64'h0001_8000_ff00_0200, 64'd0,
               64'h00ff_ff00_ff00_ff00, 4, "orc.b");
        run_op(`RV64_ALU_OP_ZBB_REV8, 1'b0,
               64'h0123_4567_89ab_cdef, 64'd0,
               64'hefcd_ab89_6745_2301, 4, "rev8");

        run_op(`RV64_ALU_OP_ZBB_ROR, 1'b0,
               64'h0123_4567_89ab_cdef, 64'd63,
               ref_ror(64'h0123_4567_89ab_cdef, 64'd63, 1'b0),
               9, "ror-63");
        run_op(`RV64_ALU_OP_ZBB_ROL, 1'b0,
               64'h0123_4567_89ab_cdef, 64'd37,
               ref_rol(64'h0123_4567_89ab_cdef, 64'd37, 1'b0),
               9, "rol-37");
        run_op(`RV64_ALU_OP_ZBB_ROR, 1'b1,
               64'hffff_ffff_89ab_cdef, 64'd31,
               ref_ror(64'hffff_ffff_89ab_cdef, 64'd31, 1'b1),
               7, "rorw-31");
        run_op(`RV64_ALU_OP_ZBB_ROL, 1'b1,
               64'hffff_ffff_89ab_cdef, 64'd13,
               ref_rol(64'hffff_ffff_89ab_cdef, 64'd13, 1'b1),
               7, "rolw-13");

        for (test_index = 0; test_index < 20;
             test_index = test_index + 1) begin
            random_a = {$urandom, $urandom};
            random_b = {$urandom, $urandom};
            run_op(`RV64_ALU_OP_ZBB_CPOP, 1'b0, random_a, 64'd0,
                   ref_cpop(random_a, 1'b0), 4, "random-cpop");
            run_op(`RV64_ALU_OP_ZBB_CLZ, 1'b0, random_a, 64'd0,
                   ref_clz(random_a, 1'b0), 6, "random-clz");
            run_op(`RV64_ALU_OP_ZBB_CTZ, 1'b0, random_a, 64'd0,
                   ref_ctz(random_a, 1'b0), 6, "random-ctz");
            run_op(`RV64_ALU_OP_ZBB_ROR, 1'b0, random_a, random_b,
                   ref_ror(random_a, random_b, 1'b0), 9, "random-ror");
            run_op(`RV64_ALU_OP_ZBB_ROL, 1'b0, random_a, random_b,
                   ref_rol(random_a, random_b, 1'b0), 9, "random-rol");
            run_op(`RV64_ALU_OP_ZBB_ORC_B, 1'b0, random_a, 64'd0,
                   ref_orc_b(random_a), 4, "random-orc.b");
            run_op(`RV64_ALU_OP_ZBB_REV8, 1'b0, random_a, 64'd0,
                   ref_rev8(random_a), 4, "random-rev8");
        end

        // Flush must cancel an active multi-cycle operation and expose ready.
        while (!ready) tick();
        op = `RV64_ALU_OP_ZBB_ROR;
        word_op = 1'b0;
        src1 = 64'h0123_4567_89ab_cdef;
        src2 = 64'd63;
        valid = 1'b1;
        tick();
        valid = 1'b0;
        repeat (2) tick();
        flush = 1'b1;
        tick();
        flush = 1'b0;
        if (busy || result_valid || !ready)
            $fatal(1, "flush did not cancel active Zbb operation");

        // A word form that does not exist must report an illegal result.
        op = `RV64_ALU_OP_ZBB_ANDN;
        word_op = 1'b1;
        src1 = 64'd1;
        src2 = 64'd2;
        valid = 1'b1;
        tick();
        valid = 1'b0;
        if (!result_valid || !illegal)
            $fatal(1, "invalid Zbb word form did not report illegal");
        result_ready = 1'b1;
        tick();

        $display("PASS: iterative Zbb results, latency, backpressure, and flush");
        $finish;
    end
endmodule
