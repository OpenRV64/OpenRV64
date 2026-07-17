`timescale 1ns/1ps
`include "core/arith/prefix-addsub.v"

module tb_prefix_addsub;

    logic [63:0] a;
    logic [63:0] b;
    logic        sub;
    wire  [63:0] result;

    integer test_index;
    logic [63:0] expected;

    openrv64_prefix_addsub dut (
        .a_i(a),
        .b_i(b),
        .sub_i(sub),
        .result_o(result)
    );

    task automatic check;
        input [63:0] in_a;
        input [63:0] in_b;
        input        in_sub;
        begin
            a = in_a;
            b = in_b;
            sub = in_sub;
            expected = in_sub ? (in_a - in_b) : (in_a + in_b);
            #1;
            if (result !== expected) begin
                $fatal(1,
                    "prefix addsub mismatch: sub=%0b a=%016x b=%016x result=%016x expected=%016x",
                    in_sub, in_a, in_b, result, expected);
            end
        end
    endtask

    initial begin
        check(64'd0, 64'd0, 1'b0);
        check(64'hffff_ffff_ffff_ffff, 64'd1, 1'b0);
        check(64'h7fff_ffff_ffff_ffff, 64'd1, 1'b0);
        check(64'd0, 64'd1, 1'b1);
        check(64'h8000_0000_0000_0000, 64'd1, 1'b1);
        check(64'hffff_ffff_ffff_ffff, 64'hffff_ffff_ffff_ffff, 1'b1);

        for (test_index = 0; test_index < 10000; test_index = test_index + 1) begin
            check({$urandom, $urandom}, {$urandom, $urandom}, 1'b0);
            check({$urandom, $urandom}, {$urandom, $urandom}, 1'b1);
        end

        $display("PASS: 64-bit parallel-prefix add/sub");
        $finish;
    end

endmodule
