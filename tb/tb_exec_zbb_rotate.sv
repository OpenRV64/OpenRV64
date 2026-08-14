`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"

module tb_exec_zbb_rotate;
    localparam integer TAG_WIDTH = 8;

    reg clk;
    reg rst_n;
    reg flush;
    reg valid;
    wire ready;
    reg [`RV64_ALU_OP_WIDTH-1:0] op;
    reg word_op;
    reg [63:0] src;
    reg [63:0] amount;
    reg [TAG_WIDTH-1:0] tag;
    wire busy;
    wire result_valid;
    reg result_ready;
    wire [63:0] result;
    wire [TAG_WIDTH-1:0] result_tag;

    reg [63:0] expected [0:255];
    reg expected_valid [0:255];
    integer result_count;
    integer index;
    integer cycle_count;

    openrv64_exec_zbb_rotate #(
        .TAG_WIDTH(TAG_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .valid_i(valid),
        .ready_o(ready),
        .op_sel_i(op),
        .word_op_i(word_op),
        .src_i(src),
        .amount_i(amount),
        .tag_i(tag),
        .busy_o(busy),
        .result_valid_o(result_valid),
        .result_ready_i(result_ready),
        .result_o(result),
        .result_tag_o(result_tag)
    );

    always #5 clk = ~clk;

    function automatic [63:0] reference_rotate;
        input [63:0] value;
        input [63:0] shift_value;
        input left;
        input word_value;
        reg [5:0] shift;
        reg [31:0] word_result;
        begin
            if (word_value) begin
                shift = {1'b0, shift_value[4:0]};
                if (left)
                    word_result = (value[31:0] << shift) |
                        (value[31:0] >> ((32 - shift) & 31));
                else
                    word_result = (value[31:0] >> shift) |
                        (value[31:0] << ((32 - shift) & 31));
                reference_rotate = {{32{word_result[31]}}, word_result};
            end else begin
                shift = shift_value[5:0];
                if (left)
                    reference_rotate = (value << shift) |
                        (value >> ((64 - shift) & 63));
                else
                    reference_rotate = (value >> shift) |
                        (value << ((64 - shift) & 63));
            end
        end
    endfunction

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic expect_request;
        input [7:0] request_tag;
        input [63:0] request_src;
        input [63:0] request_amount;
        input request_left;
        input request_word;
        begin
            expected[request_tag] = reference_rotate(
                request_src, request_amount, request_left, request_word);
            expected_valid[request_tag] = 1'b1;
        end
    endtask

    // Check the value which is actually transferred at this edge, before the
    // elastic output stage advances through nonblocking assignments.
    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (cycle_count > 500)
            $fatal(1,
                "rotate test timeout count=%0d busy=%0b ready=%0b valid=%0b result_valid=%0b tag=%0d",
                result_count, busy, ready, valid, result_valid, result_tag);
        if (rst_n && !flush && result_valid && result_ready) begin
            if (!expected_valid[result_tag])
                $fatal(1, "unexpected rotate result tag=%0d", result_tag);
            if (result !== expected[result_tag])
                $fatal(1,
                    "rotate tag=%0d result=%016x expected=%016x",
                    result_tag, result, expected[result_tag]);
            expected_valid[result_tag] <= 1'b0;
            result_count <= result_count + 1;
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        valid = 1'b0;
        op = `RV64_ALU_OP_INVALID;
        word_op = 1'b0;
        src = 64'd0;
        amount = 64'd0;
        tag = 8'd0;
        result_ready = 1'b1;
        result_count = 0;
        cycle_count = 0;
        for (index = 0; index < 256; index = index + 1) begin
            expected[index] = 64'd0;
            expected_valid[index] = 1'b0;
        end

        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        // Word rotates must accept and preserve one tagged request per cycle.
        word_op = 1'b1;
        for (index = 0; index < 12; index = index + 1) begin
            op = index[0] ? `RV64_ALU_OP_ZBB_ROL :
                            `RV64_ALU_OP_ZBB_ROR;
            src = 64'h8000_0000_89ab_cdef ^ (64'(index) << 7);
            amount = 64'(index * 7);
            tag = 8'(index);
            expect_request(tag, src, amount,
                           op == `RV64_ALU_OP_ZBB_ROL, 1'b1);
            valid = 1'b1;
            #1;
            if (!ready)
                $fatal(1, "word rotate lost II=1 at request %0d", index);
            tick();
        end
        valid = 1'b0;
        while (result_count != 12)
            tick();
        if (busy)
            $fatal(1, "word rotate pipeline remained busy after drain");

        // A wide rotate consumes both shifters for its second cycle.  It must
        // backpressure for exactly that cycle, then accept the next request.
        word_op = 1'b0;
        op = `RV64_ALU_OP_ZBB_ROR;
        src = 64'h0123_4567_89ab_cdef;
        amount = 64'd37;
        tag = 8'd32;
        expect_request(tag, src, amount, 1'b0, 1'b0);
        valid = 1'b1;
        #1;
        if (!ready)
            $fatal(1, "first wide rotate was not accepted");
        tick();
        valid = 1'b0;
        #1;
        if (ready)
            $fatal(1, "wide rotate did not reserve its second shifter cycle");
        tick();
        #1;
        if (!ready)
            $fatal(1, "wide rotate exceeded its II=2 reservation");

        op = `RV64_ALU_OP_ZBB_ROL;
        src = 64'hfedc_ba98_7654_3210;
        amount = 64'd63;
        tag = 8'd33;
        expect_request(tag, src, amount, 1'b1, 1'b0);
        valid = 1'b1;
        tick();
        valid = 1'b0;
        while (result_count != 14)
            tick();

        // Output backpressure must hold both data and tag and propagate back
        // through the two elastic stages without losing queued word rotates.
        result_ready = 1'b0;
        word_op = 1'b1;
        for (index = 40; index < 42; index = index + 1) begin
            op = `RV64_ALU_OP_ZBB_ROR;
            src = 64'hffff_ffff_dead_beef + index;
            amount = index;
            tag = 8'(index);
            expect_request(tag, src, amount, 1'b0, 1'b1);
            valid = 1'b1;
            while (!ready)
                tick();
            tick();
        end
        valid = 1'b0;
        op = `RV64_ALU_OP_ZBB_ROR;
        src = 64'hffff_ffff_dead_beef + 64'd42;
        amount = 64'd42;
        tag = 8'd42;
        expect_request(tag, src, amount, 1'b0, 1'b1);
        valid = 1'b1;
        #1;
        if (ready)
            $fatal(1, "rotate input did not see full-pipeline backpressure");
        valid = 1'b0;
        repeat (3) begin
            if (!result_valid || result_tag != 8'd40 ||
                result != expected[40])
                $fatal(1, "rotate output changed under backpressure");
            tick();
        end
        result_ready = 1'b1;
        while (result_count != 16)
            tick();

        valid = 1'b1;
        while (!ready)
            tick();
        tick();
        valid = 1'b0;
        while (result_count != 17)
            tick();

        // Randomized width/direction/amount coverage exercises the half swap
        // at amount[5], zero intra-half shifts, and word sign extension.
        for (index = 0; index < 40; index = index + 1) begin
            op = index[0] ? `RV64_ALU_OP_ZBB_ROL :
                            `RV64_ALU_OP_ZBB_ROR;
            word_op = index[1];
            src = {$urandom, $urandom};
            amount = {$urandom, $urandom};
            tag = 8'(80 + index);
            expect_request(tag, src, amount,
                           op == `RV64_ALU_OP_ZBB_ROL, word_op);
            valid = 1'b1;
            while (!ready)
                tick();
            tick();
            valid = 1'b0;
        end
        while (result_count != 57)
            tick();

        // Exhaust every architecturally visible shift amount for both widths.
        for (index = 0; index < 64; index = index + 1) begin
            op = index[0] ? `RV64_ALU_OP_ZBB_ROL :
                            `RV64_ALU_OP_ZBB_ROR;
            word_op = 1'b0;
            src = 64'h0123_4567_89ab_cdef ^ (64'(index) << 23);
            amount = 64'(index);
            tag = 8'(128 + index);
            expect_request(tag, src, amount,
                           op == `RV64_ALU_OP_ZBB_ROL, 1'b0);
            valid = 1'b1;
            while (!ready)
                tick();
            tick();
            valid = 1'b0;
        end
        while (result_count != 121)
            tick();
        for (index = 0; index < 32; index = index + 1) begin
            op = index[0] ? `RV64_ALU_OP_ZBB_ROL :
                            `RV64_ALU_OP_ZBB_ROR;
            word_op = 1'b1;
            src = 64'hffff_ffff_89ab_cdef ^ (64'(index) << 11);
            amount = 64'(index);
            tag = 8'(192 + index);
            expect_request(tag, src, amount,
                           op == `RV64_ALU_OP_ZBB_ROL, 1'b1);
            valid = 1'b1;
            while (!ready)
                tick();
            tick();
            valid = 1'b0;
        end
        while (result_count != 153)
            tick();

        // Flush must cancel a wide operation between its two shifter cycles.
        word_op = 1'b0;
        op = `RV64_ALU_OP_ZBB_ROR;
        src = 64'h1111_2222_3333_4444;
        amount = 64'd17;
        tag = 8'd60;
        valid = 1'b1;
        tick();
        valid = 1'b0;
        flush = 1'b1;
        tick();
        flush = 1'b0;
        if (busy || result_valid || !ready)
            $fatal(1, "flush did not empty the rotate pipeline");

        op = `RV64_ALU_OP_ZBB_CPOP;
        #1;
        if (ready)
            $fatal(1, "rotate pipeline accepted a non-rotate operation");

        $display("PASS: Zbb rotate word II=1, wide II=2, tags, backpressure, flush");
        $finish;
    end
endmodule
