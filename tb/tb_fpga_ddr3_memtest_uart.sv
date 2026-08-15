`timescale 1ns/1ps

module tb_fpga_ddr3_memtest_uart;
    localparam integer CLOCKS_PER_BIT = 10;

    logic clk = 1'b0;
    logic reset;
    logic [2:0] status;
    logic [27:0] fail_addr;
    logic [2:0] fail_lane;
    logic [31:0] fail_expected;
    logic [31:0] fail_actual;
    logic [2:0] fail_reason;
    wire tx;
    logic [7:0] received [0:63];

    always #5 clk = !clk;

    openrv64_fpga_ddr3_memtest_uart_status #(
        .CLOCK_HZ(100),
        .BAUD(10),
        .FIRST_DELAY_CYCLES(5),
        .REPEAT_CYCLES(50)
    ) dut (
        .clk_i(clk),
        .reset_i(reset),
        .status_i(status),
        .fail_addr_i(fail_addr),
        .fail_lane_i(fail_lane),
        .fail_expected_i(fail_expected),
        .fail_actual_i(fail_actual),
        .fail_reason_i(fail_reason),
        .tx_o(tx)
    );

    task automatic receive_byte(output logic [7:0] value);
        integer bit_index;
        begin
            @(negedge tx);
            repeat (CLOCKS_PER_BIT + (CLOCKS_PER_BIT / 2)) @(posedge clk);
            value[0] = tx;
            for (bit_index = 1; bit_index < 8; bit_index = bit_index + 1) begin
                repeat (CLOCKS_PER_BIT) @(posedge clk);
                value[bit_index] = tx;
            end
            repeat (CLOCKS_PER_BIT) @(posedge clk);
            if (!tx)
                $fatal(1, "UART stop bit was low");
        end
    endtask

    task automatic receive_line(input integer length);
        integer byte_index;
        logic [7:0] value;
        begin
            for (byte_index = 0; byte_index < length; byte_index = byte_index + 1) begin
                receive_byte(value);
                received[byte_index] = value;
            end
        end
    endtask

    task automatic expect_status_line(
        input logic [7:0] c18,
        input logic [7:0] c19,
        input logic [7:0] c20,
        input logic [7:0] c21
    );
        begin
            if ({received[0], received[1], received[2], received[3],
                 received[4], received[5], received[6], received[7],
                 received[8], received[9], received[10], received[11],
                 received[12], received[13], received[14], received[15],
                 received[16], received[17]} != "OPENRV64 DDR3 MEM " ||
                received[18] != c18 || received[19] != c19 ||
                received[20] != c20 || received[21] != c21 ||
                received[22] != 8'h0d || received[23] != 8'h0a)
                begin
                    integer dump_index;
                    $write("bad status bytes:");
                    for (dump_index = 0; dump_index < 24;
                         dump_index = dump_index + 1)
                        $write(" %02x", received[dump_index]);
                    $write("\n");
                    $fatal(1, "bad status line");
                end
        end
    endtask

    initial begin
        reset         = 1'b1;
        status        = 3'd0;
        fail_addr     = 28'h0;
        fail_lane     = 3'd0;
        fail_expected = 32'h0;
        fail_actual   = 32'h0;
        fail_reason   = 3'd0;
        repeat (4) @(posedge clk);
        reset = 1'b0;

        receive_line(24);
        expect_status_line("W", "A", "I", "T");

        status = 3'd5;
        receive_line(24);
        expect_status_line("P", "A", "S", "S");

        status        = 3'd6;
        fail_addr     = 28'h123_4567;
        fail_lane     = 3'd3;
        fail_expected = 32'h89ab_cdef;
        fail_actual   = 32'h0123_4567;
        fail_reason   = 3'd1;
        receive_line(64);
        if ({received[0], received[1], received[2], received[3],
             received[4], received[5], received[6], received[7],
             received[8], received[9], received[10], received[11],
             received[12], received[13], received[14], received[15],
             received[16], received[17], received[18], received[19],
             received[20], received[21]} != "OPENRV64 DDR3 MEM FAIL" ||
            received[22] != " " || received[23] != "A" ||
            received[24] != "=" ||
            {received[25], received[26], received[27], received[28],
             received[29], received[30], received[31]} != "1234567" ||
            received[32] != " " || received[33] != "L" ||
            received[34] != "=" || received[35] != "3" ||
            received[36] != " " || received[37] != "E" ||
            received[38] != "=" ||
            {received[39], received[40], received[41], received[42],
             received[43], received[44], received[45], received[46]} !=
                "89abcdef" ||
            received[47] != " " || received[48] != "G" ||
            received[49] != "=" ||
            {received[50], received[51], received[52], received[53],
             received[54], received[55], received[56], received[57]} !=
                "01234567" ||
            received[58] != " " || received[59] != "R" ||
            received[60] != "=" || received[61] != "1" ||
            received[62] != 8'h0d || received[63] != 8'h0a)
            begin
                integer dump_index;
                $write("bad FAIL bytes:");
                for (dump_index = 0; dump_index < 64;
                     dump_index = dump_index + 1)
                    $write(" %02x", received[dump_index]);
                $write("\n");
                $fatal(1, "bad FAIL line");
            end

        $display("OPENRV64 FPGA DDR3 MEMTEST UART PASS");
        $finish;
    end

endmodule
