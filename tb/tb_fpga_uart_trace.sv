`timescale 1ns/1ps

module tb_fpga_uart_trace;
    localparam integer BUFFER_BYTES = 16384;
    localparam integer FIRST_BYTES = 27;
    localparam integer TOTAL_BYTES = BUFFER_BYTES + 10;

    logic clk;
    logic rst_n;
    logic uart_byte_valid;
    logic [7:0] uart_byte;
    logic [10:0] jtag_index;
    logic jtag_req_toggle;
    logic jtag_ack_toggle;
    logic [255:0] jtag_rdata;
    logic [63:0] jtag_byte_count;

    openrv64_soc_debug_uart_trace_mem dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .uart_byte_valid_i(uart_byte_valid),
        .uart_byte_i(uart_byte),
        .jtag_index_i(jtag_index),
        .jtag_req_toggle_i(jtag_req_toggle),
        .jtag_ack_toggle_o(jtag_ack_toggle),
        .jtag_rdata_o(jtag_rdata),
        .jtag_byte_count_o(jtag_byte_count)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic jtag_read(
        input logic [10:0] index,
        output logic [255:0] data,
        output logic [63:0] count
    );
        begin
            @(negedge clk);
            jtag_index = index;
            jtag_req_toggle = !jtag_req_toggle;
            wait (jtag_ack_toggle == jtag_req_toggle);
            data = jtag_rdata;
            count = jtag_byte_count;
            @(posedge clk);
        end
    endtask

    integer byte_index;
    logic [255:0] value;
    logic [63:0] count;

    initial begin
        rst_n = 1'b0;
        uart_byte_valid = 1'b0;
        uart_byte = 8'd0;
        jtag_index = 11'd0;
        jtag_req_toggle = 1'b0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Sustained one-byte-per-cycle input is intentionally much faster
        // than a real UART. First stop in a partially filled fourth word; this
        // catches both missing upper BRAM banks and trailing-byte loss.
        uart_byte_valid = 1'b1;
        for (byte_index = 0; byte_index < FIRST_BYTES;
             byte_index = byte_index + 1) begin
            uart_byte = byte_index[7:0];
            @(posedge clk);
            @(negedge clk);
        end
        uart_byte_valid = 1'b0;

        jtag_read(11'd0, value, count);
        if (count !== FIRST_BYTES)
            $fatal(1, "UART initial byte counter is %0d, expected %0d",
                   count, FIRST_BYTES);
        if (value[215:0] !== 216'h1a19_1817_1615_1413_1211_100f_0e0d_0c0b_0a09_0807_0605_0403_0201_00)
            $fatal(1, "UART initial partial burst mismatch: %064x", value);

        // Continue through one complete ring wrap.
        @(negedge clk);
        uart_byte_valid = 1'b1;
        for (byte_index = FIRST_BYTES; byte_index < TOTAL_BYTES;
             byte_index = byte_index + 1) begin
            uart_byte = byte_index[7:0];
            @(posedge clk);
            @(negedge clk);
        end
        uart_byte_valid = 1'b0;

        jtag_read(11'd0, value, count);
        if (count !== TOTAL_BYTES)
            $fatal(1, "UART total-byte counter is %0d, expected %0d",
                   count, TOTAL_BYTES);
        if (value !== {64'h1f1e_1d1c_1b1a_1918,
                       64'h1716_1514_1312_1110,
                       64'h0f0e_0d0c_0b0a_0908,
                       64'h0706_0504_0302_0100})
            $fatal(1, "UART wrapped burst zero mismatch: %064x", value);

        jtag_read(11'd2044, value, count);
        if (value[255:192] !== 64'hfffe_fdfc_fbfa_f9f8)
            $fatal(1, "UART final wrapped burst mismatch: %064x", value);

        $display("PASS: FPGA 16 KiB rolling UART transmit trace BRAM");
        $finish;
    end

    initial begin
        repeat (20000) @(posedge clk);
        $fatal(1, "timeout in FPGA UART trace test");
    end

endmodule
