`timescale 1ns/1ps
`include "core/stage/stage.v"
`include "core/stage/elastic_buffer.v"
`timescale 1ns/1ps

module tb_stage;

    logic        clk;
    logic        rst_n;

    logic        r_flush;
    logic        r_in_valid;
    logic        r_in_clear;
    logic [7:0]  r_in_data;
    logic        r_out_valid;
    logic        r_out_clear;
    logic [7:0]  r_out_data;

    logic        b_flush;
    logic        b_in_valid;
    logic        b_in_clear;
    logic [7:0]  b_in_data;
    logic        b_out_valid;
    logic        b_out_clear;
    logic [7:0]  b_out_data;

    logic        q_flush;
    logic        q_in_valid;
    logic        q_in_clear;
    logic [7:0]  q_in_data;
    logic        q_out_valid;
    logic        q_out_clear;
    logic [7:0]  q_out_data;

    openrv64_stage #(
        .WIDTH(8),
        .REGISTERED(1)
    ) dut_registered (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(r_flush),
        .in_valid_i(r_in_valid),
        .in_clear_o(r_in_clear),
        .in_data_i(r_in_data),
        .out_valid_o(r_out_valid),
        .out_clear_i(r_out_clear),
        .out_data_o(r_out_data)
    );

    openrv64_stage #(
        .WIDTH(8),
        .REGISTERED(0)
    ) dut_bypass (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(b_flush),
        .in_valid_i(b_in_valid),
        .in_clear_o(b_in_clear),
        .in_data_i(b_in_data),
        .out_valid_o(b_out_valid),
        .out_clear_i(b_out_clear),
        .out_data_o(b_out_data)
    );

    openrv64_elastic_buffer #(
        .WIDTH(8)
    ) dut_elastic (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(q_flush),
        .in_valid_i(q_in_valid),
        .in_clear_o(q_in_clear),
        .in_data_i(q_in_data),
        .out_valid_o(q_out_valid),
        .out_clear_i(q_out_clear),
        .out_data_o(q_out_data)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic expect_registered;
        input exp_in_clear;
        input exp_out_valid;
        input [7:0] exp_out_data;
        input [8*32-1:0] label;
        begin
            #1;
            if (r_in_clear !== exp_in_clear ||
                r_out_valid !== exp_out_valid ||
                r_out_data !== exp_out_data) begin
                $fatal(1,
                    "%0s: registered in_clear=%0b/%0b out_valid=%0b/%0b out_data=%02x/%02x",
                    label, r_in_clear, exp_in_clear,
                    r_out_valid, exp_out_valid,
                    r_out_data, exp_out_data);
            end
        end
    endtask

    task automatic expect_elastic;
        input exp_in_clear;
        input exp_out_valid;
        input [7:0] exp_out_data;
        input [8*32-1:0] label;
        begin
            #1;
            if (q_in_clear !== exp_in_clear ||
                q_out_valid !== exp_out_valid ||
                q_out_data !== exp_out_data) begin
                $fatal(1,
                    "%0s: elastic in_clear=%0b/%0b out_valid=%0b/%0b out_data=%02x/%02x",
                    label, q_in_clear, exp_in_clear,
                    q_out_valid, exp_out_valid,
                    q_out_data, exp_out_data);
            end
        end
    endtask

    task automatic expect_bypass;
        input exp_in_clear;
        input exp_out_valid;
        input [7:0] exp_out_data;
        input [8*32-1:0] label;
        begin
            #1;
            if (b_in_clear !== exp_in_clear ||
                b_out_valid !== exp_out_valid ||
                b_out_data !== exp_out_data) begin
                $fatal(1,
                    "%0s: bypass in_clear=%0b/%0b out_valid=%0b/%0b out_data=%02x/%02x",
                    label, b_in_clear, exp_in_clear,
                    b_out_valid, exp_out_valid,
                    b_out_data, exp_out_data);
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        r_flush = 1'b0;
        r_in_valid = 1'b0;
        r_in_data = 8'h00;
        r_out_clear = 1'b1;
        b_flush = 1'b0;
        b_in_valid = 1'b0;
        b_in_data = 8'h00;
        b_out_clear = 1'b1;
        q_flush = 1'b0;
        q_in_valid = 1'b0;
        q_in_data = 8'h00;
        q_out_clear = 1'b0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        expect_registered(1'b1, 1'b0, 8'h00, "registered reset clear");

        r_in_valid = 1'b1;
        r_in_data = 8'ha5;
        r_out_clear = 1'b1;
        expect_registered(1'b1, 1'b0, 8'h00, "registered accepts input");
        @(posedge clk);
        expect_registered(1'b1, 1'b1, 8'ha5, "registered captured input");

        @(negedge clk);
        r_in_valid = 1'b1;
        r_in_data = 8'h5a;
        r_out_clear = 1'b0;
        expect_registered(1'b0, 1'b1, 8'ha5, "registered holds when uncleared");
        @(posedge clk);
        expect_registered(1'b0, 1'b1, 8'ha5, "registered no overwrite while held");

        @(negedge clk);
        r_out_clear = 1'b1;
        expect_registered(1'b1, 1'b1, 8'ha5, "registered releases hold");
        @(posedge clk);
        expect_registered(1'b1, 1'b1, 8'h5a, "registered captures after release");

        @(negedge clk);
        r_in_valid = 1'b0;
        r_out_clear = 1'b1;
        expect_registered(1'b1, 1'b1, 8'h5a, "registered accepts bubble");
        @(posedge clk);
        expect_registered(1'b1, 1'b0, 8'h5a,
                          "registered bubble clears valid and retains payload");

        @(negedge clk);
        r_in_valid = 1'b1;
        r_in_data = 8'hc3;
        r_out_clear = 1'b1;
        @(posedge clk);
        expect_registered(1'b1, 1'b1, 8'hc3, "registered recaptured before flush");

        @(negedge clk);
        r_flush = 1'b1;
        r_out_clear = 1'b0;
        expect_registered(1'b0, 1'b1, 8'hc3,
                          "registered flush leaves current cycle unchanged");
        @(posedge clk);
        @(negedge clk);
        r_flush = 1'b0;
        r_in_valid = 1'b0;
        r_out_clear = 1'b1;
        expect_registered(1'b1, 1'b0, 8'hc3,
                          "registered empty on cycle after flush");

        b_in_valid = 1'b1;
        b_in_data = 8'h11;
        b_out_clear = 1'b0;
        b_flush = 1'b0;
        expect_bypass(1'b0, 1'b1, 8'h11, "bypass presents uncleared payload");

        b_out_clear = 1'b1;
        expect_bypass(1'b1, 1'b1, 8'h11, "bypass clears when downstream clears");

        b_in_valid = 1'b0;
        expect_bypass(1'b1, 1'b0, 8'h00, "bypass bubble");

        b_in_valid = 1'b1;
        b_in_data = 8'h22;
        b_out_clear = 1'b0;
        b_flush = 1'b1;
        expect_bypass(1'b1, 1'b0, 8'h00, "bypass flush kills output and clears input");

        q_flush = 1'b0;
        q_in_valid = 1'b0;
        q_out_clear = 1'b0;
        expect_elastic(1'b1, 1'b0, 8'h00, "elastic reset clear");

        q_in_valid = 1'b1;
        q_in_data = 8'ha1;
        @(posedge clk);
        @(negedge clk);
        expect_elastic(1'b1, 1'b1, 8'ha1, "elastic first entry");

        // At occupancy one, simultaneous pop and push must sustain one item
        // per cycle without a bubble.
        q_out_clear = 1'b1;
        q_in_data = 8'hb2;
        @(posedge clk);
        @(negedge clk);
        expect_elastic(1'b1, 1'b1, 8'hb2, "elastic full throughput");

        // Hold the head and fill the second slot.  Upstream readiness must
        // then remain low even when downstream clears during the full cycle.
        q_out_clear = 1'b0;
        q_in_data = 8'hc3;
        @(posedge clk);
        @(negedge clk);
        expect_elastic(1'b0, 1'b1, 8'hb2, "elastic full hold");

        q_out_clear = 1'b1;
        q_in_data = 8'hd4;
        @(posedge clk);
        @(negedge clk);
        expect_elastic(1'b1, 1'b1, 8'hc3,
                       "elastic full pop rejects same-cycle push");

        @(posedge clk);
        @(negedge clk);
        expect_elastic(1'b1, 1'b1, 8'hd4,
                       "elastic accepts after registered capacity");

        q_flush = 1'b1;
        q_out_clear = 1'b0;
        @(posedge clk);
        @(negedge clk);
        expect_elastic(1'b1, 1'b0, 8'hd4, "elastic flush clears valid");

        $display("PASS: stage interlock primitive");
        $finish;
    end

endmodule
