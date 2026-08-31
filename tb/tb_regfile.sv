`timescale 1ns/1ps
`include "util/regfile.v"

module tb_regfile;

    localparam integer REG_WIDTH = 16;
    localparam integer REG_COUNT = 8;
    localparam integer READ_PORTS = 2;
    localparam integer WRITE_PORTS = 2;
    localparam integer NUM_BANKS = 2;
    localparam integer BANK_SIZE = REG_COUNT / NUM_BANKS;
    localparam integer ADDR_WIDTH = $clog2(REG_COUNT);

    reg clk;
    reg rst_n;

    reg  [ADDR_WIDTH-1:0] rp_addr [READ_PORTS-1:0];
    wire [REG_WIDTH-1:0] rp_data [READ_PORTS-1:0];
    reg                  rp_req [READ_PORTS-1:0];
    wire                 rp_valid [READ_PORTS-1:0];

    reg  [ADDR_WIDTH-1:0] wp_addr [WRITE_PORTS-1:0];
    reg  [REG_WIDTH-1:0] wp_data [WRITE_PORTS-1:0];
    reg                  wp_req [WRITE_PORTS-1:0];
    wire                 wp_valid [WRITE_PORTS-1:0];

    cmn_reg_file #(
        .REG_WIDTH(REG_WIDTH),
        .REG_COUNT(REG_COUNT),
        .READ_PORTS(READ_PORTS),
        .WRITE_PORTS(WRITE_PORTS),
        .BANK_SIZE(BANK_SIZE),
        .NUM_BANKS(NUM_BANKS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .rp_addr_i(rp_addr),
        .rp_data_o(rp_data),
        .rp_req_i(rp_req),
        .rp_valid_o(rp_valid),
        .wp_addr_i(wp_addr),
        .wp_data_i(wp_data),
        .wp_req_i(wp_req),
        .wp_valid_o(wp_valid)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic write_pair_and_wait;
        input [ADDR_WIDTH-1:0] address_0;
        input [REG_WIDTH-1:0] value_0;
        input [ADDR_WIDTH-1:0] address_1;
        input [REG_WIDTH-1:0] value_1;
        input expect_same_cycle;
        input [8*64-1:0] label;

        reg seen_0;
        reg seen_1;
        integer cycles;
        begin
            @(negedge clk);
            rp_req[0] = 1'b0;
            rp_req[1] = 1'b0;
            wp_addr[0] = address_0;
            wp_data[0] = value_0;
            wp_addr[1] = address_1;
            wp_data[1] = value_1;
            wp_req[0] = 1'b1;
            wp_req[1] = 1'b1;

            seen_0 = 1'b0;
            seen_1 = 1'b0;
            cycles = 0;

            @(posedge clk);
            #1;

            while ((!seen_0 || !seen_1) && (cycles < 6)) begin
                if (wp_valid[0] && !seen_0) begin
                    seen_0 = 1'b1;
                    wp_req[0] = 1'b0;
                end
                if (wp_valid[1] && !seen_1) begin
                    seen_1 = 1'b1;
                    wp_req[1] = 1'b0;
                end

                if ((cycles == 0) && expect_same_cycle &&
                    (!wp_valid[0] || !wp_valid[1])) begin
                    $fatal(1,
                           "%0s: different-bank writes did not complete together",
                           label);
                end

                if ((cycles == 0) && !expect_same_cycle &&
                    (wp_valid[0] == wp_valid[1])) begin
                    $fatal(1,
                           "%0s: same-bank writes did not serialize",
                           label);
                end

                if (!seen_0 || !seen_1) begin
                    @(posedge clk);
                    #1;
                end
                cycles = cycles + 1;
            end

            if (!seen_0 || !seen_1)
                $fatal(1, "%0s: timed out waiting for writes", label);

            // Completion is a one-cycle pulse.  Leave the logical ports idle
            // until it has cleared before starting another transaction.
            @(posedge clk);
            #1;
            if (wp_valid[0] || wp_valid[1])
                $fatal(1, "%0s: write valid did not clear", label);
        end
    endtask

    task automatic read_pair_and_expect;
        input [ADDR_WIDTH-1:0] address_0;
        input [REG_WIDTH-1:0] expected_0;
        input [ADDR_WIDTH-1:0] address_1;
        input [REG_WIDTH-1:0] expected_1;
        input expect_same_cycle;
        input [8*64-1:0] label;

        reg seen_0;
        reg seen_1;
        integer cycles;
        begin
            @(negedge clk);
            wp_req[0] = 1'b0;
            wp_req[1] = 1'b0;
            rp_addr[0] = address_0;
            rp_addr[1] = address_1;
            rp_req[0] = 1'b1;
            rp_req[1] = 1'b1;

            seen_0 = 1'b0;
            seen_1 = 1'b0;
            cycles = 0;

            @(posedge clk);
            #1;

            while ((!seen_0 || !seen_1) && (cycles < 6)) begin
                if (rp_valid[0] && !seen_0) begin
                    if (rp_data[0] !== expected_0) begin
                        $fatal(1, "%0s: port 0 expected %h, got %h",
                               label, expected_0, rp_data[0]);
                    end
                    seen_0 = 1'b1;
                    rp_req[0] = 1'b0;
                end

                if (rp_valid[1] && !seen_1) begin
                    if (rp_data[1] !== expected_1) begin
                        $fatal(1, "%0s: port 1 expected %h, got %h",
                               label, expected_1, rp_data[1]);
                    end
                    seen_1 = 1'b1;
                    rp_req[1] = 1'b0;
                end

                if ((cycles == 0) && expect_same_cycle &&
                    (!rp_valid[0] || !rp_valid[1])) begin
                    $fatal(1,
                           "%0s: different-bank reads did not complete together",
                           label);
                end

                if ((cycles == 0) && !expect_same_cycle &&
                    (rp_valid[0] == rp_valid[1])) begin
                    $fatal(1,
                           "%0s: same-bank reads did not serialize",
                           label);
                end

                if (!seen_0 || !seen_1) begin
                    @(posedge clk);
                    #1;
                end
                cycles = cycles + 1;
            end

            if (!seen_0 || !seen_1)
                $fatal(1, "%0s: timed out waiting for reads", label);

            @(posedge clk);
            #1;
            if (rp_valid[0] || rp_valid[1])
                $fatal(1, "%0s: read valid did not clear", label);
        end
    endtask

    initial begin
        rst_n = 1'b0;
        rp_addr[0] = {ADDR_WIDTH{1'b0}};
        rp_addr[1] = {ADDR_WIDTH{1'b0}};
        rp_req[0] = 1'b0;
        rp_req[1] = 1'b0;
        wp_addr[0] = {ADDR_WIDTH{1'b0}};
        wp_addr[1] = {ADDR_WIDTH{1'b0}};
        wp_data[0] = {REG_WIDTH{1'b0}};
        wp_data[1] = {REG_WIDTH{1'b0}};
        wp_req[0] = 1'b0;
        wp_req[1] = 1'b0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Low address bit selects the bank, so these pairs can write in
        // parallel despite there being only one physical write port per bank.
        write_pair_and_wait(
            3'd0, 16'h1000,
            3'd1, 16'h1001,
            1'b1,
            "initialize registers 0 and 1");
        write_pair_and_wait(
            3'd2, 16'h1002,
            3'd3, 16'h1003,
            1'b1,
            "initialize registers 2 and 3");
        write_pair_and_wait(
            3'd6, 16'h1006,
            3'd7, 16'h1007,
            1'b1,
            "initialize registers 6 and 7");

        read_pair_and_expect(
            3'd2, 16'h1002,
            3'd3, 16'h1003,
            1'b1,
            "different-bank reads");

        // Registers 0 and 6 both map to bank 0.  The loser remains asserted
        // until it receives its completion on the following cycle.
        read_pair_and_expect(
            3'd0, 16'h1000,
            3'd6, 16'h1006,
            1'b0,
            "same-bank read conflict");

        // Exercise the corresponding write arbitration, then read both
        // locations back through the same bank.
        write_pair_and_wait(
            3'd4, 16'h4444,
            3'd6, 16'h6666,
            1'b0,
            "same-bank write conflict");
        read_pair_and_expect(
            3'd4, 16'h4444,
            3'd6, 16'h6666,
            1'b0,
            "same-bank writeback verification");

        $display("tb_regfile: PASS");
        $finish;
    end

    // Same-address read/write behavior is intentionally not exercised here;
    // dispatch is expected to forbid that hazard.

    initial begin
        #2000;
        $fatal(1, "tb_regfile: timeout");
    end

endmodule
