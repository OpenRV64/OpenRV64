`timescale 1ns/1ps
`include "core/exec/alu/rv64-m.v"
`timescale 1ns/1ps

module tb_exec_rv64m;

    localparam int unsigned MUL_BITS_PER_CYCLE = 4;
    localparam int unsigned DIV_BITS_PER_CYCLE = 2;
    localparam int unsigned MUL_ITER_CYCLES =
        (64 + MUL_BITS_PER_CYCLE - 1) / MUL_BITS_PER_CYCLE;
    localparam int unsigned DIV_ITER_CYCLES =
        (64 + DIV_BITS_PER_CYCLE - 1) / DIV_BITS_PER_CYCLE;

    logic clk;
    logic rst_n;
    logic flush;
    logic valid;
    logic ready;
    logic busy;
    logic [`RV64_ALU_OP_WIDTH-1:0] op_sel;
    logic                          word_op;
    logic [`RV64_XLEN-1:0]         src1;
    logic [`RV64_XLEN-1:0]         src2;
    logic                          result_valid;
    logic                          result_ready;
    logic                          illegal;
    logic [`RV64_XLEN-1:0]         result;

    openrv64_exec_rv64m #(
        .MUL_BITS_PER_CYCLE(MUL_BITS_PER_CYCLE),
        .DIV_BITS_PER_CYCLE(DIV_BITS_PER_CYCLE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .valid_i(valid),
        .ready_o(ready),
        .busy_o(busy),
        .op_sel_i(op_sel),
        .word_op_i(word_op),
        .src1_i(src1),
        .src2_i(src2),
        .result_valid_o(result_valid),
        .result_ready_i(result_ready),
        .illegal_o(illegal),
        .result_o(result)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic clear_inputs;
        begin
            flush = 1'b0;
            valid = 1'b0;
            op_sel = `RV64_ALU_OP_INVALID;
            word_op = 1'b0;
            src1 = {`RV64_XLEN{1'b0}};
            src2 = {`RV64_XLEN{1'b0}};
            result_ready = 1'b0;
        end
    endtask

    task automatic check;
        input [`RV64_ALU_OP_WIDTH-1:0] in_op_sel;
        input                          in_word_op;
        input [`RV64_XLEN-1:0]         in_src1;
        input [`RV64_XLEN-1:0]         in_src2;
        input                          exp_valid;
        input                          exp_illegal;
        input [`RV64_XLEN-1:0]         exp_result;
        input [8*48-1:0]               label;
        integer timeout;
        integer busy_cycles;
        integer exp_busy_cycles;
        begin
            @(negedge clk);

            if ((in_op_sel == `RV64_ALU_OP_MUL) ||
                (in_op_sel == `RV64_ALU_OP_MULH) ||
                (in_op_sel == `RV64_ALU_OP_MULHSU) ||
                (in_op_sel == `RV64_ALU_OP_MULHU)) begin
                exp_busy_cycles = (in_word_op &&
                                   (in_op_sel != `RV64_ALU_OP_MUL)) ?
                                  0 :
                                  (in_word_op ?
                                   ((32 + MUL_BITS_PER_CYCLE - 1) /
                                    MUL_BITS_PER_CYCLE) :
                                   MUL_ITER_CYCLES);
            end else if ((in_op_sel == `RV64_ALU_OP_DIV) ||
                         (in_op_sel == `RV64_ALU_OP_DIVU) ||
                         (in_op_sel == `RV64_ALU_OP_REM) ||
                         (in_op_sel == `RV64_ALU_OP_REMU)) begin
                if ((in_word_op && (in_src2[31:0] == 32'd0)) ||
                    (!in_word_op && (in_src2 == 64'd0)) ||
                    (((in_op_sel == `RV64_ALU_OP_DIV) ||
                      (in_op_sel == `RV64_ALU_OP_REM)) &&
                     (in_word_op ?
                      ((in_src1[31:0] == 32'h8000_0000) &&
                       (in_src2[31:0] == 32'hffff_ffff)) :
                      ((in_src1 == 64'h8000_0000_0000_0000) &&
                       (in_src2 == 64'hffff_ffff_ffff_ffff))))) begin
                    exp_busy_cycles = 0;
                end else begin
                    exp_busy_cycles = in_word_op ?
                                      ((32 + DIV_BITS_PER_CYCLE - 1) /
                                       DIV_BITS_PER_CYCLE) + 1 :
                                      DIV_ITER_CYCLES + 1;
                end
            end else begin
                exp_busy_cycles = 0;
            end

            if (!ready || busy || result_valid) begin
                $fatal(1,
                    "%0s: unit not ready before issue ready=%0b busy=%0b result_valid=%0b",
                    label, ready, busy, result_valid);
            end

            op_sel = in_op_sel;
            word_op = in_word_op;
            src1 = in_src1;
            src2 = in_src2;
            valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            valid = 1'b0;

            if (!result_valid && ready) begin
                $fatal(1, "%0s: iterative unit remained ready after issue", label);
            end

            timeout = 0;
            busy_cycles = 0;
            while (!result_valid && timeout < 128) begin
                if (!busy) begin
                    $fatal(1, "%0s: neither busy nor result_valid after issue", label);
                end

                busy_cycles = busy_cycles + 1;
                @(posedge clk);
                @(negedge clk);
                timeout = timeout + 1;
            end

            if (!result_valid) begin
                $fatal(1, "%0s: timeout waiting for result", label);
            end

            if (busy_cycles != exp_busy_cycles) begin
                $fatal(1,
                    "%0s: unexpected latency busy_cycles=%0d expected=%0d",
                    label, busy_cycles, exp_busy_cycles);
            end

            if (!busy || ready) begin
                $fatal(1,
                    "%0s: bad result hold state ready=%0b busy=%0b",
                    label, ready, busy);
            end

            if (result_valid !== exp_valid ||
                illegal !== exp_illegal ||
                result !== exp_result) begin
                $fatal(1,
                    "%0s: result_valid=%0b/%0b illegal=%0b/%0b result=%016x/%016x",
                    label, result_valid, exp_valid, illegal, exp_illegal, result, exp_result);
            end

            @(posedge clk);
            @(negedge clk);

            if (!result_valid || result !== exp_result) begin
                $fatal(1, "%0s: result did not hold without result_ready", label);
            end

            result_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            result_ready = 1'b0;

            if (!ready || busy || result_valid) begin
                $fatal(1,
                    "%0s: unit did not return ready after result_ready ready=%0b busy=%0b result_valid=%0b",
                    label, ready, busy, result_valid);
            end
        end
    endtask

    initial begin
        clear_inputs();

        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        check(`RV64_ALU_OP_MUL, 1'b0,
              64'd7, 64'd6,
              1'b1, 1'b0, 64'd42, "mul");

        check(`RV64_ALU_OP_MULH, 1'b0,
              64'hffff_ffff_ffff_fffe, 64'd3,
              1'b1, 1'b0, 64'hffff_ffff_ffff_ffff, "mulh signed high");

        check(`RV64_ALU_OP_MULHSU, 1'b0,
              64'hffff_ffff_ffff_fffe, 64'd3,
              1'b1, 1'b0, 64'hffff_ffff_ffff_ffff, "mulhsu high");

        check(`RV64_ALU_OP_MULHU, 1'b0,
              64'hffff_ffff_ffff_ffff, 64'd2,
              1'b1, 1'b0, 64'h0000_0000_0000_0001, "mulhu high");

        check(`RV64_ALU_OP_MUL, 1'b1,
              64'h0000_0000_7fff_ffff, 64'd2,
              1'b1, 1'b0, 64'hffff_ffff_ffff_fffe, "mulw sign extend");

        check(`RV64_ALU_OP_DIV, 1'b0,
              64'hffff_ffff_ffff_fff9, 64'd3,
              1'b1, 1'b0, 64'hffff_ffff_ffff_fffe, "div signed");

        check(`RV64_ALU_OP_DIVU, 1'b0,
              64'd7, 64'd3,
              1'b1, 1'b0, 64'd2, "divu");

        check(`RV64_ALU_OP_REM, 1'b0,
              64'hffff_ffff_ffff_fff9, 64'd3,
              1'b1, 1'b0, 64'hffff_ffff_ffff_ffff, "rem signed");

        check(`RV64_ALU_OP_REMU, 1'b0,
              64'd7, 64'd3,
              1'b1, 1'b0, 64'd1, "remu");

        check(`RV64_ALU_OP_DIV, 1'b0,
              64'd123, 64'd0,
              1'b1, 1'b0, 64'hffff_ffff_ffff_ffff, "div by zero");

        check(`RV64_ALU_OP_REM, 1'b0,
              64'd123, 64'd0,
              1'b1, 1'b0, 64'd123, "rem by zero");

        check(`RV64_ALU_OP_DIV, 1'b0,
              64'h8000_0000_0000_0000, 64'hffff_ffff_ffff_ffff,
              1'b1, 1'b0, 64'h8000_0000_0000_0000, "div overflow");

        check(`RV64_ALU_OP_REM, 1'b0,
              64'h8000_0000_0000_0000, 64'hffff_ffff_ffff_ffff,
              1'b1, 1'b0, 64'h0000_0000_0000_0000, "rem overflow");

        check(`RV64_ALU_OP_DIV, 1'b1,
              64'h0000_0000_ffff_fff9, 64'd3,
              1'b1, 1'b0, 64'hffff_ffff_ffff_fffe, "divw signed");

        check(`RV64_ALU_OP_DIVU, 1'b1,
              64'h0000_0000_ffff_ffff, 64'd2,
              1'b1, 1'b0, 64'h0000_0000_7fff_ffff, "divuw sign extend");

        check(`RV64_ALU_OP_REMU, 1'b1,
              64'h0000_0000_ffff_ffff, 64'd2,
              1'b1, 1'b0, 64'h0000_0000_0000_0001, "remuw sign extend");

        check(`RV64_ALU_OP_REM, 1'b1,
              64'h0000_0000_8000_0000, 64'd0,
              1'b1, 1'b0, 64'hffff_ffff_8000_0000, "remw by zero");

        check(`RV64_ALU_OP_MULH, 1'b1,
              64'd2, 64'd3,
              1'b1, 1'b1, 64'h0000_0000_0000_0000, "invalid mulhw");

        check(`RV64_ALU_OP_ADD, 1'b0,
              64'd2, 64'd3,
              1'b1, 1'b1, 64'h0000_0000_0000_0000, "invalid op");

        @(negedge clk);
        valid = 1'b1;
        op_sel = `RV64_ALU_OP_DIV;
        src1 = 64'd99;
        src2 = 64'd3;
        @(posedge clk);
        @(negedge clk);
        valid = 1'b0;

        if (!busy) begin
            $fatal(1, "flush test: unit did not become busy");
        end

        flush = 1'b1;
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;

        if (!ready || busy || result_valid) begin
            $fatal(1,
                "flush test: unit did not clear ready=%0b busy=%0b result_valid=%0b",
                ready, busy, result_valid);
        end

        check(`RV64_ALU_OP_MUL, 1'b0,
              64'd2, 64'd3,
              1'b1, 1'b0, 64'd6, "post-flush mul");
        check(`RV64_ALU_OP_DIVU, 1'b0,
              64'd84, 64'd2,
              1'b1, 1'b0, 64'd42, "serialized divu");

        $display("PASS: iterative RV64M execute busy/ready");
        $finish;
    end

endmodule
