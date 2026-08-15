// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// Periodic UART status and first-failure detail for the DDR3 memory test.

`timescale 1ns/1ps

module openrv64_fpga_ddr3_memtest_uart_status #(
    parameter integer CLOCK_HZ           = 100_000_000,
    parameter integer BAUD               = 115_200,
    parameter integer FIRST_DELAY_CYCLES = 1_000_000,
    parameter integer REPEAT_CYCLES      = 100_000_000
) (
    input  logic        clk_i,
    input  logic        reset_i,
    input  logic [2:0]  status_i,
    input  logic [27:0] fail_addr_i,
    input  logic [2:0]  fail_lane_i,
    input  logic [31:0] fail_expected_i,
    input  logic [31:0] fail_actual_i,
    input  logic [2:0]  fail_reason_i,
    output logic        tx_o
);

    localparam logic [2:0] STATUS_FAIL = 3'd6;
    localparam integer WAIT_MAX =
        (FIRST_DELAY_CYCLES > REPEAT_CYCLES) ?
        FIRST_DELAY_CYCLES : REPEAT_CYCLES;
    localparam integer WAIT_COUNT_W = (WAIT_MAX <= 1) ? 1 : $clog2(WAIT_MAX);
    localparam logic [WAIT_COUNT_W-1:0] FIRST_DELAY_LIMIT =
        FIRST_DELAY_CYCLES[WAIT_COUNT_W-1:0] - 1'b1;
    localparam logic [WAIT_COUNT_W-1:0] REPEAT_LIMIT =
        REPEAT_CYCLES[WAIT_COUNT_W-1:0] - 1'b1;

    logic [WAIT_COUNT_W-1:0] wait_count_q;
    logic [6:0] message_index_q;
    logic [6:0] message_length_q;
    logic first_message_q;
    logic sending_q;
    logic tx_start_q;
    logic [7:0] tx_data_q;
    logic tx_busy;

    logic [2:0]  status_q;
    logic [27:0] fail_addr_q;
    logic [2:0]  fail_lane_q;
    logic [31:0] fail_expected_q;
    logic [31:0] fail_actual_q;
    logic [2:0]  fail_reason_q;

    function automatic logic [7:0] hex_digit(input logic [3:0] nibble);
        begin
            hex_digit = (nibble < 10) ?
                (8'h30 + {4'b0000, nibble}) :
                (8'h61 + ({4'b0000, nibble} - 8'd10));
        end
    endfunction

    function automatic logic [7:0] status_character(
        input logic [2:0] status,
        input logic [6:0] offset
    );
        begin
            case (status)
                3'd0: case (offset)
                    0: status_character = "W";
                    1: status_character = "A";
                    2: status_character = "I";
                    default: status_character = "T";
                endcase
                3'd1: case (offset)
                    0: status_character = "P";
                    1: status_character = "0";
                    2: status_character = "W";
                    default: status_character = " ";
                endcase
                3'd2: case (offset)
                    0: status_character = "P";
                    1: status_character = "0";
                    2: status_character = "R";
                    default: status_character = " ";
                endcase
                3'd3: case (offset)
                    0: status_character = "P";
                    1: status_character = "1";
                    2: status_character = "W";
                    default: status_character = " ";
                endcase
                3'd4: case (offset)
                    0: status_character = "P";
                    1: status_character = "1";
                    2: status_character = "R";
                    default: status_character = " ";
                endcase
                3'd5: case (offset)
                    0: status_character = "P";
                    1: status_character = "A";
                    2: status_character = "S";
                    default: status_character = "S";
                endcase
                default: case (offset)
                    0: status_character = "F";
                    1: status_character = "A";
                    2: status_character = "I";
                    default: status_character = "L";
                endcase
            endcase
        end
    endfunction

    function automatic logic [7:0] address_digit(
        input logic [27:0] value,
        input logic [6:0]  offset
    );
        begin
            case (offset)
                0: address_digit = hex_digit(value[27:24]);
                1: address_digit = hex_digit(value[23:20]);
                2: address_digit = hex_digit(value[19:16]);
                3: address_digit = hex_digit(value[15:12]);
                4: address_digit = hex_digit(value[11:8]);
                5: address_digit = hex_digit(value[7:4]);
                default: address_digit = hex_digit(value[3:0]);
            endcase
        end
    endfunction

    function automatic logic [7:0] word_digit(
        input logic [31:0] value,
        input logic [6:0]  offset
    );
        begin
            case (offset)
                0: word_digit = hex_digit(value[31:28]);
                1: word_digit = hex_digit(value[27:24]);
                2: word_digit = hex_digit(value[23:20]);
                3: word_digit = hex_digit(value[19:16]);
                4: word_digit = hex_digit(value[15:12]);
                5: word_digit = hex_digit(value[11:8]);
                6: word_digit = hex_digit(value[7:4]);
                default: word_digit = hex_digit(value[3:0]);
            endcase
        end
    endfunction

    function automatic logic [7:0] message_byte(input logic [6:0] index);
        begin
            case (index)
                0: message_byte = "O";
                1: message_byte = "P";
                2: message_byte = "E";
                3: message_byte = "N";
                4: message_byte = "R";
                5: message_byte = "V";
                6: message_byte = "6";
                7: message_byte = "4";
                8: message_byte = " ";
                9: message_byte = "D";
                10: message_byte = "D";
                11: message_byte = "R";
                12: message_byte = "3";
                13: message_byte = " ";
                14: message_byte = "M";
                15: message_byte = "E";
                16: message_byte = "M";
                17: message_byte = " ";
                18, 19, 20, 21:
                    message_byte = status_character(status_q, index - 18);
                22: message_byte = (status_q == STATUS_FAIL) ? " " : 8'h0d;
                23: message_byte = (status_q == STATUS_FAIL) ? "A" : 8'h0a;
                24: message_byte = "=";
                25, 26, 27, 28, 29, 30, 31:
                    message_byte = address_digit(fail_addr_q, index - 25);
                32: message_byte = " ";
                33: message_byte = "L";
                34: message_byte = "=";
                35: message_byte = hex_digit({1'b0, fail_lane_q});
                36: message_byte = " ";
                37: message_byte = "E";
                38: message_byte = "=";
                39, 40, 41, 42, 43, 44, 45, 46:
                    message_byte = word_digit(fail_expected_q, index - 39);
                47: message_byte = " ";
                48: message_byte = "G";
                49: message_byte = "=";
                50, 51, 52, 53, 54, 55, 56, 57:
                    message_byte = word_digit(fail_actual_q, index - 50);
                58: message_byte = " ";
                59: message_byte = "R";
                60: message_byte = "=";
                61: message_byte = hex_digit({1'b0, fail_reason_q});
                62: message_byte = 8'h0d;
                63: message_byte = 8'h0a;
                default: message_byte = 8'h00;
            endcase
        end
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
            wait_count_q     <= '0;
            message_index_q  <= '0;
            message_length_q <= 7'd24;
            first_message_q  <= 1'b1;
            sending_q        <= 1'b0;
            tx_start_q       <= 1'b0;
            tx_data_q        <= 8'h00;
            status_q         <= 3'd0;
            fail_addr_q      <= '0;
            fail_lane_q      <= '0;
            fail_expected_q  <= '0;
            fail_actual_q    <= '0;
            fail_reason_q    <= '0;
        end else begin
            tx_start_q <= 1'b0;

            if (!sending_q) begin
                if ((first_message_q &&
                     (wait_count_q == FIRST_DELAY_LIMIT)) ||
                    (!first_message_q &&
                     (wait_count_q == REPEAT_LIMIT))) begin
                    wait_count_q     <= '0;
                    message_index_q  <= '0;
                    first_message_q  <= 1'b0;
                    sending_q        <= 1'b1;
                    status_q         <= status_i;
                    fail_addr_q      <= fail_addr_i;
                    fail_lane_q      <= fail_lane_i;
                    fail_expected_q  <= fail_expected_i;
                    fail_actual_q    <= fail_actual_i;
                    fail_reason_q    <= fail_reason_i;
                    message_length_q <=
                        (status_i == STATUS_FAIL) ? 7'd64 : 7'd24;
                end else begin
                    wait_count_q <= wait_count_q + 1'b1;
                end
            end else if (!tx_busy && !tx_start_q) begin
                if (message_index_q < message_length_q) begin
                    tx_data_q       <= message_byte(message_index_q);
                    tx_start_q      <= 1'b1;
                    message_index_q <= message_index_q + 1'b1;
                end else begin
                    wait_count_q <= '0;
                    sending_q    <= 1'b0;
                end
            end
        end
    end

endmodule
