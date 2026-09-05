`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"

module tb_test_marker_3p;
    localparam integer META_WIDTH = `OPENRV64_RETIRE_ALLOC_WIDTH;
    localparam integer RESULT_WIDTH = `OPENRV64_RETIRE_RESULT_WIDTH;

    reg clk;
    reg rst_n;
    reg flush;
    reg [2:0] queue_valid;
    reg [2:0] queue_accept;
    reg [3*META_WIDTH-1:0] queue_meta;
    reg [3*RESULT_WIDTH-1:0] queue_result;
    wire [3*RESULT_WIDTH-1:0] marker_result;
    wire [3*RESULT_WIDTH-1:0] disabled_result;
    wire start_test;
    wire start_trace;
    wire end_trace;
    wire disabled_start_test;
    wire disabled_start_trace;
    wire disabled_end_trace;

    openrv64_test_marker_3p #(
        .ENABLE(1),
        .META_WIDTH(META_WIDTH),
        .RESULT_WIDTH(RESULT_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .queue_valid_i(queue_valid), .queue_accept_i(queue_accept),
        .queue_meta_i(queue_meta), .queue_result_i(queue_result),
        .queue_result_o(marker_result), .start_test_o(start_test),
        .start_trace_o(start_trace), .end_trace_o(end_trace)
    );

    openrv64_test_marker_3p #(
        .ENABLE(0),
        .META_WIDTH(META_WIDTH),
        .RESULT_WIDTH(RESULT_WIDTH)
    ) dut_disabled (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .queue_valid_i(queue_valid), .queue_accept_i(queue_accept),
        .queue_meta_i(queue_meta), .queue_result_i(queue_result),
        .queue_result_o(disabled_result),
        .start_test_o(disabled_start_test),
        .start_trace_o(disabled_start_trace),
        .end_trace_o(disabled_end_trace)
    );

    always #5 clk = ~clk;

    task automatic clear_inputs;
        begin
            queue_valid = 3'b000;
            queue_accept = 3'b000;
            queue_meta = {3*META_WIDTH{1'b0}};
            queue_result = {3*RESULT_WIDTH{1'b0}};
        end
    endtask

    task automatic set_lane;
        input integer lane;
        input [63:0] pc;
        input [31:0] instr;
        input exception_value;
        input halt_value;
        begin
            queue_meta[
                lane*META_WIDTH + `OPENRV64_RETIRE_ALLOC_PC_LSB +: 64] = pc;
            queue_meta[
                lane*META_WIDTH + `OPENRV64_RETIRE_ALLOC_INSTR_LSB +: 32] =
                instr;
            queue_result[
                lane*RESULT_WIDTH +
                `OPENRV64_RETIRE_RESULT_EXCEPTION_BIT] = exception_value;
            queue_result[
                lane*RESULT_WIDTH + `OPENRV64_RETIRE_RESULT_HALT_BIT] =
                halt_value;
            queue_result[
                lane*RESULT_WIDTH + `OPENRV64_RETIRE_RESULT_CAUSE_LSB +:
                `RV64_EXCEPT_CAUSE_WIDTH] = 5'd3;
        end
    endtask

    task automatic check_masked;
        input integer lane;
        begin
            #1;
            if (marker_result[
                    lane*RESULT_WIDTH +
                    `OPENRV64_RETIRE_RESULT_EXCEPTION_BIT] ||
                marker_result[
                    lane*RESULT_WIDTH +
                    `OPENRV64_RETIRE_RESULT_HALT_BIT] ||
                (marker_result[
                    lane*RESULT_WIDTH +
                    `OPENRV64_RETIRE_RESULT_CAUSE_LSB +:
                    `RV64_EXCEPT_CAUSE_WIDTH] != 0))
                $fatal(1, "tagged test-control EBREAK was not masked");
            if (disabled_result !== queue_result)
                $fatal(1, "disabled marker recognizer changed result");
        end
    endtask

    task automatic check_unmasked;
        input integer lane;
        begin
            #1;
            if (!marker_result[
                    lane*RESULT_WIDTH +
                    `OPENRV64_RETIRE_RESULT_EXCEPTION_BIT] ||
                !marker_result[
                    lane*RESULT_WIDTH +
                    `OPENRV64_RETIRE_RESULT_HALT_BIT])
                $fatal(1, "ordinary EBREAK was incorrectly masked");
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        clear_inputs();
        repeat (2) @(posedge clk);
        rst_n = 1'b1;

        // An untagged EBREAK retains its exception and halt behavior.
        @(negedge clk);
        clear_inputs();
        queue_valid = 3'b001;
        set_lane(0, 64'h100, `RV64_INSTR_EBREAK, 1'b1, 1'b1);
        check_unmasked(0);
        @(posedge clk);
        #1;
        if (start_test || start_trace || end_trace ||
            disabled_start_test || disabled_start_trace ||
            disabled_end_trace)
            $fatal(1, "ordinary EBREAK emitted a test-control marker");

        // HINT and EBREAK may retire in the same three-wide group.
        @(negedge clk);
        clear_inputs();
        queue_valid = 3'b011;
        queue_accept = 3'b011;
        set_lane(0, 64'h200, `OPENRV64_INSTR_START_TEST_HINT, 1'b0, 1'b0);
        set_lane(1, 64'h204, `RV64_INSTR_EBREAK, 1'b1, 1'b1);
        check_masked(1);
        @(posedge clk);
        #1;
        if (!start_test || start_trace || end_trace ||
            disabled_start_test || disabled_start_trace ||
            disabled_end_trace)
            $fatal(1, "same-group START_TEST pulse missing");

        // The pulse is one cycle wide.
        @(negedge clk);
        clear_inputs();
        @(posedge clk);
        #1;
        if (start_test || start_trace || end_trace)
            $fatal(1, "test-control pulse did not clear");

        // A lane-boundary split preserves the accepted HINT until the next
        // adjacent architectural instruction is visible.
        @(negedge clk);
        clear_inputs();
        queue_valid = 3'b001;
        queue_accept = 3'b001;
        set_lane(0, 64'h300, `OPENRV64_INSTR_START_TEST_HINT, 1'b0, 1'b0);
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        queue_valid = 3'b001;
        queue_accept = 3'b001;
        set_lane(0, 64'h304, `RV64_INSTR_EBREAK, 1'b1, 1'b1);
        check_masked(0);
        @(posedge clk);
        #1;
        if (!start_test || start_trace || end_trace)
            $fatal(1, "split-group START_TEST pulse missing");

        // An older completed marker must not discard a younger lane-2 hint.
        @(negedge clk);
        clear_inputs();
        queue_valid = 3'b111;
        queue_accept = 3'b111;
        set_lane(0, 64'h340, `OPENRV64_INSTR_START_TEST_HINT,
                 1'b0, 1'b0);
        set_lane(1, 64'h344, `RV64_INSTR_EBREAK, 1'b1, 1'b1);
        set_lane(2, 64'h348, `OPENRV64_INSTR_START_TRACE_HINT,
                 1'b0, 1'b0);
        check_masked(1);
        @(posedge clk);
        #1;
        if (!start_test || start_trace || end_trace)
            $fatal(1, "older marker pulse or younger hint preservation failed");

        @(negedge clk);
        clear_inputs();
        queue_valid = 3'b001;
        queue_accept = 3'b001;
        set_lane(0, 64'h34c, `RV64_INSTR_EBREAK, 1'b1, 1'b1);
        check_masked(0);
        @(posedge clk);
        #1;
        if (start_test || !start_trace || end_trace)
            $fatal(1, "lane-2 marker hint was not preserved");

        // START_TRACE and END_TRACE use the same retired adjacency contract
        // and produce distinct one-cycle pulses.
        @(negedge clk);
        clear_inputs();
        queue_valid = 3'b011;
        queue_accept = 3'b011;
        set_lane(0, 64'h380, `OPENRV64_INSTR_START_TRACE_HINT,
                 1'b0, 1'b0);
        set_lane(1, 64'h384, `RV64_INSTR_EBREAK, 1'b1, 1'b1);
        check_masked(1);
        @(posedge clk);
        #1;
        if (start_test || !start_trace || end_trace)
            $fatal(1, "START_TRACE pulse missing or misclassified");

        @(negedge clk);
        clear_inputs();
        queue_valid = 3'b011;
        queue_accept = 3'b011;
        set_lane(0, 64'h3a0, `OPENRV64_INSTR_END_TRACE_HINT,
                 1'b0, 1'b0);
        set_lane(1, 64'h3a4, `RV64_INSTR_EBREAK, 1'b1, 1'b1);
        check_masked(1);
        @(posedge clk);
        #1;
        if (start_test || start_trace || !end_trace)
            $fatal(1, "END_TRACE pulse missing or misclassified");

        // An intervening retired instruction consumes the pending tag.
        @(negedge clk);
        clear_inputs();
        queue_valid = 3'b001;
        queue_accept = 3'b001;
        set_lane(0, 64'h400, `OPENRV64_INSTR_START_TEST_HINT, 1'b0, 1'b0);
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        queue_valid = 3'b001;
        queue_accept = 3'b001;
        set_lane(0, 64'h404, `RV64_INSTR_NOP, 1'b0, 1'b0);
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        queue_valid = 3'b001;
        set_lane(0, 64'h408, `RV64_INSTR_EBREAK, 1'b1, 1'b1);
        check_unmasked(0);

        // A flush also invalidates a split marker sequence.
        @(negedge clk);
        clear_inputs();
        queue_valid = 3'b001;
        queue_accept = 3'b001;
        set_lane(0, 64'h500, `OPENRV64_INSTR_START_TEST_HINT, 1'b0, 1'b0);
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        flush = 1'b1;
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;
        queue_valid = 3'b001;
        set_lane(0, 64'h504, `RV64_INSTR_EBREAK, 1'b1, 1'b1);
        check_unmasked(0);

        $display("PASS: 3P retirement test-control markers");
        $finish;
    end
endmodule
