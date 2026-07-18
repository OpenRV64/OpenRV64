`timescale 1ns/1ps

module tb_reset_sequencer;

    logic clk;
    logic rst_n;
    logic soc_rst_n;
    logic core_rst_n;

    openrv64_reset_sequencer #(
        .SOC_HOLD_CYCLES(3),
        .CORE_DELAY_CYCLES(2)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .soc_rst_no(soc_rst_n),
        .core_rst_no(core_rst_n)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic expect_resets;
        input logic expected_soc;
        input logic expected_core;
        input [8*48-1:0] label;
        begin
            #1;
            if (soc_rst_n !== expected_soc ||
                core_rst_n !== expected_core) begin
                $fatal(1, "%0s: soc_rst_n=%b core_rst_n=%b expected=%b/%b",
                       label, soc_rst_n, core_rst_n,
                       expected_soc, expected_core);
            end
        end
    endtask

    initial begin
        integer cycle_index;

        rst_n = 1'b0;
        #1;
        expect_resets(1'b0, 1'b0, "initial asynchronous assertion");
        repeat (2) @(posedge clk);

        // Deassert away from a clock edge.  Two synchronizer clocks followed
        // by three hold clocks release the platform on the fifth edge.
        @(negedge clk);
        #2 rst_n = 1'b1;
        for (cycle_index = 0; cycle_index < 4;
             cycle_index = cycle_index + 1) begin
            @(posedge clk);
            expect_resets(1'b0, 1'b0, "conditioned reset hold");
        end

        @(posedge clk);
        expect_resets(1'b1, 1'b0, "platform released first");
        @(posedge clk);
        expect_resets(1'b1, 1'b0, "core settling delay");
        @(posedge clk);
        expect_resets(1'b1, 1'b1, "core released second");

        // Assertion is deliberately not clock-aligned and must propagate
        // without waiting for a rising edge.
        @(negedge clk);
        #2 rst_n = 1'b0;
        expect_resets(1'b0, 1'b0, "warm reset asynchronous assertion");

        // A short release that does not complete the sequence must never
        // leak either generated reset high.
        #2 rst_n = 1'b1;
        repeat (2) @(posedge clk);
        #2 rst_n = 1'b0;
        expect_resets(1'b0, 1'b0, "aborted reset release");

        $display("PASS: reset assertion, synchronized release, and platform/core ordering");
        $finish;
    end

    initial begin
        repeat (64) @(posedge clk);
        $fatal(1, "timeout in reset sequencer test");
    end

endmodule
