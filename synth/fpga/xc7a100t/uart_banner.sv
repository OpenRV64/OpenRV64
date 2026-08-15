// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// Fixed-message UART transmitter for board clock/reset bring-up.

`timescale 1ns/1ps

module openrv64_fpga_uart_tx #(
    parameter integer CLOCK_HZ = 200_000_000,
    parameter integer BAUD     = 115_200
) (
    input  logic       clk_i,
    input  logic       reset_i,
    input  logic       start_i,
    input  logic [7:0] data_i,
    output logic       tx_o,
    output logic       busy_o
);

    localparam integer CLOCKS_PER_BIT = CLOCK_HZ / BAUD;
    localparam integer BAUD_COUNT_W =
        (CLOCKS_PER_BIT <= 1) ? 1 : $clog2(CLOCKS_PER_BIT);
    localparam logic [BAUD_COUNT_W-1:0] BAUD_COUNT_LIMIT =
        CLOCKS_PER_BIT[BAUD_COUNT_W-1:0] - 1'b1;

    logic [9:0] frame_q;
    logic [3:0] bit_index_q;
    logic [BAUD_COUNT_W-1:0] baud_count_q;

    assign tx_o = busy_o ? frame_q[bit_index_q] : 1'b1;

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            frame_q      <= 10'h3ff;
            bit_index_q  <= 4'd0;
            baud_count_q <= '0;
            busy_o       <= 1'b0;
        end else if (start_i && !busy_o) begin
            // One start bit, eight data bits least-significant bit first, and
            // one stop bit.
            frame_q      <= {1'b1, data_i, 1'b0};
            bit_index_q  <= 4'd0;
            baud_count_q <= '0;
            busy_o       <= 1'b1;
        end else if (busy_o) begin
            if (baud_count_q == BAUD_COUNT_LIMIT) begin
                baud_count_q <= '0;
                if (bit_index_q == 4'd9) begin
                    busy_o <= 1'b0;
                end else begin
                    bit_index_q <= bit_index_q + 4'd1;
                end
            end else begin
                baud_count_q <= baud_count_q + 1'b1;
            end
        end
    end

endmodule

module openrv64_fpga_uart_banner #(
    parameter integer CLOCK_HZ           = 200_000_000,
    parameter integer BAUD               = 115_200,
    parameter integer FIRST_DELAY_CYCLES = 20_000_000,
    parameter integer REPEAT_CYCLES      = 200_000_000
) (
    input  logic clk_i,
    input  logic reset_i,
    output logic tx_o
);

    localparam integer MESSAGE_LENGTH = 26;
    localparam integer WAIT_MAX =
        (FIRST_DELAY_CYCLES > REPEAT_CYCLES) ?
        FIRST_DELAY_CYCLES : REPEAT_CYCLES;
    localparam integer WAIT_COUNT_W = (WAIT_MAX <= 1) ? 1 : $clog2(WAIT_MAX);

    logic [WAIT_COUNT_W-1:0] wait_count_q;
    logic [4:0] message_index_q;
    logic first_message_q;
    logic sending_q;
    logic tx_start_q;
    logic [7:0] tx_data_q;
    logic tx_busy;

    function automatic logic [7:0] message_byte(input logic [4:0] index);
        case (index)
            5'd0:  message_byte = "O";
            5'd1:  message_byte = "P";
            5'd2:  message_byte = "E";
            5'd3:  message_byte = "N";
            5'd4:  message_byte = "R";
            5'd5:  message_byte = "V";
            5'd6:  message_byte = "6";
            5'd7:  message_byte = "4";
            5'd8:  message_byte = " ";
            5'd9:  message_byte = "C";
            5'd10: message_byte = "L";
            5'd11: message_byte = "O";
            5'd12: message_byte = "C";
            5'd13: message_byte = "K";
            5'd14: message_byte = " ";
            5'd15: message_byte = "U";
            5'd16: message_byte = "A";
            5'd17: message_byte = "R";
            5'd18: message_byte = "T";
            5'd19: message_byte = " ";
            5'd20: message_byte = "P";
            5'd21: message_byte = "A";
            5'd22: message_byte = "S";
            5'd23: message_byte = "S";
            5'd24: message_byte = 8'h0d;
            5'd25: message_byte = 8'h0a;
            default: message_byte = 8'h00;
        endcase
    endfunction

    openrv64_fpga_uart_tx #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD(BAUD)
    ) u_tx (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .start_i(tx_start_q),
        .data_i(tx_data_q),
        .tx_o(tx_o),
        .busy_o(tx_busy)
    );

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            wait_count_q    <= '0;
            message_index_q <= 5'd0;
            first_message_q <= 1'b1;
            sending_q       <= 1'b0;
            tx_start_q      <= 1'b0;
            tx_data_q       <= 8'h00;
        end else begin
            tx_start_q <= 1'b0;

            if (!sending_q) begin
                if ((first_message_q &&
                     (wait_count_q == FIRST_DELAY_CYCLES - 1)) ||
                    (!first_message_q &&
                     (wait_count_q == REPEAT_CYCLES - 1))) begin
                    wait_count_q    <= '0;
                    message_index_q <= 5'd0;
                    first_message_q <= 1'b0;
                    sending_q       <= 1'b1;
                end else begin
                    wait_count_q <= wait_count_q + 1'b1;
                end
            end else if (!tx_busy && !tx_start_q) begin
                if (message_index_q < MESSAGE_LENGTH) begin
                    tx_data_q       <= message_byte(message_index_q);
                    tx_start_q      <= 1'b1;
                    message_index_q <= message_index_q + 5'd1;
                end else begin
                    wait_count_q <= '0;
                    sending_q    <= 1'b0;
                end
            end
        end
    end

endmodule
