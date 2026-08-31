`timescale 1ns/1ps
`include "util/reg_bank.v"

module tb_reg_bank;

    localparam integer REG_WIDTH = 16;
    localparam integer REG_NUM = 8;
    localparam integer READ_PORTS = 2;
    localparam integer WRITE_PORTS = 2;
    localparam integer REG_SEL_WIDTH = $clog2(REG_NUM);

    reg clk;

    wire [READ_PORTS-1:0][REG_WIDTH-1:0] read_val;
    reg  [READ_PORTS-1:0][REG_SEL_WIDTH-1:0] read_sel;
    reg  [READ_PORTS-1:0] read_req;

    reg  [WRITE_PORTS-1:0][REG_WIDTH-1:0] write_val;
    reg  [WRITE_PORTS-1:0][REG_SEL_WIDTH-1:0] write_sel;
    reg  [WRITE_PORTS-1:0] write_req;

    cmn_reg_bank #(
        .REG_WIDTH(REG_WIDTH),
        .REG_NUM(REG_NUM),
        .READ_PORTS(READ_PORTS),
        .WRITE_PORTS(WRITE_PORTS),
        .REG_SEL_WIDTH(REG_SEL_WIDTH)
    ) dut (
        .clk(clk),
        .read_val_o(read_val),
        .read_sel_i(read_sel),
        .read_req_i(read_req),
        .write_val_i(write_val),
        .write_sel_i(write_sel),
        .write_req_i(write_req)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic clear_requests;
        begin
            read_req = {READ_PORTS{1'b0}};
            write_req = {WRITE_PORTS{1'b0}};
        end
    endtask

    task automatic write_two;
        input [REG_SEL_WIDTH-1:0] address_0;
        input [REG_WIDTH-1:0] value_0;
        input [REG_SEL_WIDTH-1:0] address_1;
        input [REG_WIDTH-1:0] value_1;
        begin
            @(negedge clk);
            read_req = {READ_PORTS{1'b0}};
            write_req = 2'b11;
            write_sel[0] = address_0;
            write_val[0] = value_0;
            write_sel[1] = address_1;
            write_val[1] = value_1;
            @(posedge clk);
            #1;
            write_req = {WRITE_PORTS{1'b0}};
        end
    endtask

    task automatic write_port_one;
        input [REG_SEL_WIDTH-1:0] address;
        input [REG_WIDTH-1:0] value;
        begin
            @(negedge clk);
            read_req = {READ_PORTS{1'b0}};
            write_req = 2'b10;
            write_sel[1] = address;
            write_val[1] = value;
            @(posedge clk);
            #1;
            write_req = {WRITE_PORTS{1'b0}};
        end
    endtask

    task automatic read_two_and_expect;
        input [REG_SEL_WIDTH-1:0] address_0;
        input [REG_WIDTH-1:0] expected_0;
        input [REG_SEL_WIDTH-1:0] address_1;
        input [REG_WIDTH-1:0] expected_1;
        input [8*64-1:0] label;
        begin
            @(negedge clk);
            write_req = {WRITE_PORTS{1'b0}};
            read_req = 2'b11;
            read_sel[0] = address_0;
            read_sel[1] = address_1;
            @(posedge clk);
            #1;
            if (read_val[0] !== expected_0)
                $fatal(1, "%0s: port 0 expected %h, got %h",
                       label, expected_0, read_val[0]);
            if (read_val[1] !== expected_1)
                $fatal(1, "%0s: port 1 expected %h, got %h",
                       label, expected_1, read_val[1]);
            read_req = {READ_PORTS{1'b0}};
        end
    endtask

    initial begin
        clear_requests();
        read_sel[0] = {REG_SEL_WIDTH{1'b0}};
        read_sel[1] = {REG_SEL_WIDTH{1'b0}};
        write_sel[0] = {REG_SEL_WIDTH{1'b0}};
        write_sel[1] = {REG_SEL_WIDTH{1'b0}};
        write_val[0] = {REG_WIDTH{1'b0}};
        write_val[1] = {REG_WIDTH{1'b0}};

        // There is no reset input, so initialize every location used below.
        write_two(3'd1, 16'h1111, 3'd6, 16'h6666);
        write_two(3'd2, 16'h2222, 3'd5, 16'h5555);

        // Both read ports can independently select the bank.
        read_two_and_expect(
            3'd1, 16'h1111,
            3'd6, 16'h6666,
            "independent read ports");

        // Swap the selected registers to catch port/register index reversal.
        read_two_and_expect(
            3'd5, 16'h5555,
            3'd2, 16'h2222,
            "swapped read selections");

        // Confirm that write port 1 works without write port 0 participating.
        write_port_one(3'd3, 16'h3333);
        read_two_and_expect(
            3'd3, 16'h3333,
            3'd1, 16'h1111,
            "independent write port");

        // A disabled read port should hold its previously registered result.
        @(negedge clk);
        read_req = 2'b01;
        read_sel[0] = 3'd2;
        read_sel[1] = 3'd6;
        @(posedge clk);
        #1;
        if (read_val[0] !== 16'h2222)
            $fatal(1, "enabled read port did not update");
        if (read_val[1] !== 16'h1111)
            $fatal(1, "disabled read port did not hold its value");

        clear_requests();
        $display("tb_reg_bank: PASS");
        $finish;
    end

    // Intentionally unspecified by this testbench:
    //   * two write ports targeting the same register;
    //   * a read and write targeting the same register on one edge;
    //   * out-of-range addresses when REG_NUM is not a power of two.
    // Add directed checks once the bank's policy for those cases is chosen.

    initial begin
        #1000;
        $fatal(1, "tb_reg_bank: timeout");
    end

endmodule
