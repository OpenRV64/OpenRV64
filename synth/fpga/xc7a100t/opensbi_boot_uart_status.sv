// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// UART diagnostics while DDR is calibrated and populated before CPU release.

`timescale 1ns/1ps

module openrv64_fpga_opensbi_boot_uart_status #(
    parameter integer CLOCK_HZ           = 100_000_000,
    parameter integer BAUD               = 115_200,
    parameter integer FIRST_DELAY_CYCLES = 100_000,
    parameter integer REPEAT_CYCLES      = 100_000_000
) (
    input  logic       clk_i,
    input  logic       reset_i,
    input  logic [1:0] status_i,
    output logic       tx_o,
    output logic       pass_message_done_o
);

    localparam integer MESSAGE_LENGTH = 25;
    localparam integer WAIT_MAX =
        (FIRST_DELAY_CYCLES > REPEAT_CYCLES) ?
            FIRST_DELAY_CYCLES : REPEAT_CYCLES;
    localparam integer WAIT_COUNT_WIDTH =
        (WAIT_MAX <= 1) ? 1 : $clog2(WAIT_MAX);
    localparam logic [WAIT_COUNT_WIDTH-1:0] FIRST_DELAY_LIMIT =
        WAIT_COUNT_WIDTH'(FIRST_DELAY_CYCLES - 1);
    localparam logic [WAIT_COUNT_WIDTH-1:0] REPEAT_LIMIT =
        WAIT_COUNT_WIDTH'(REPEAT_CYCLES - 1);
    localparam logic [4:0] MESSAGE_LIMIT = 5'(MESSAGE_LENGTH);

    logic [WAIT_COUNT_WIDTH-1:0] wait_count_q;
    logic [4:0] message_index_q;
    logic first_message_q;
    logic sending_q;
    logic [1:0] status_q;
    logic tx_start_q;
    logic [7:0] tx_data_q;
    logic tx_busy;

    function automatic logic [7:0] status_byte(
        input logic [1:0] status,
        input logic [1:0] character
    );
        case (status)
            2'd0: begin
                case (character)
                    2'd0: status_byte = "W";
                    2'd1: status_byte = "A";
                    2'd2: status_byte = "I";
                    default: status_byte = "T";
                endcase
            end
            2'd1: begin
                case (character)
                    2'd0: status_byte = "L";
                    2'd1: status_byte = "O";
                    2'd2: status_byte = "A";
                    default: status_byte = "D";
                endcase
            end
            2'd2: begin
                case (character)
                    2'd0: status_byte = "P";
                    2'd1: status_byte = "A";
                    2'd2: status_byte = "S";
                    default: status_byte = "S";
                endcase
            end
            default: begin
                case (character)
                    2'd0: status_byte = "F";
                    2'd1: status_byte = "A";
                    2'd2: status_byte = "I";
                    default: status_byte = "L";
                endcase
            end
        endcase
    endfunction

    function automatic logic [7:0] message_byte(
        input logic [1:0] status,
        input logic [4:0] index
    );
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
            5'd9:  message_byte = "F";
            5'd10: message_byte = "P";
            5'd11: message_byte = "G";
            5'd12: message_byte = "A";
            5'd13: message_byte = " ";
            5'd14: message_byte = "B";
            5'd15: message_byte = "O";
            5'd16: message_byte = "O";
            5'd17: message_byte = "T";
            5'd18: message_byte = " ";
            5'd19: message_byte = status_byte(status, 2'd0);
            5'd20: message_byte = status_byte(status, 2'd1);
            5'd21: message_byte = status_byte(status, 2'd2);
            5'd22: message_byte = status_byte(status, 2'd3);
            5'd23: message_byte = 8'h0d;
            5'd24: message_byte = 8'h0a;
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
            wait_count_q <= '0;
            message_index_q <= 5'd0;
            first_message_q <= 1'b1;
            sending_q <= 1'b0;
            status_q <= 2'd0;
            tx_start_q <= 1'b0;
            tx_data_q <= 8'h00;
            pass_message_done_o <= 1'b0;
        end else begin
            tx_start_q <= 1'b0;
            pass_message_done_o <= 1'b0;

            if (!sending_q) begin
                if ((first_message_q &&
                     (wait_count_q == FIRST_DELAY_LIMIT)) ||
                    (!first_message_q &&
                     (wait_count_q == REPEAT_LIMIT))) begin
                    wait_count_q <= '0;
                    message_index_q <= 5'd0;
                    first_message_q <= 1'b0;
                    sending_q <= 1'b1;
                    status_q <= status_i;
                end else begin
                    wait_count_q <= wait_count_q + 1'b1;
                end
            end else if (!tx_busy && !tx_start_q) begin
                if (message_index_q < MESSAGE_LIMIT) begin
                    tx_data_q <= message_byte(status_q, message_index_q);
                    tx_start_q <= 1'b1;
                    message_index_q <= message_index_q + 5'd1;
                end else begin
                    wait_count_q <= '0;
                    sending_q <= 1'b0;
                    if (status_q == 2'd2)
                        pass_message_done_o <= 1'b1;
                end
            end
        end
    end

endmodule
