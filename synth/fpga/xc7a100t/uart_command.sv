// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// Minimal UART receiver and command/response engine for board bring-up.

`timescale 1ns/1ps

module openrv64_fpga_uart_rx #(
    parameter integer CLOCK_HZ = 200_000_000,
    parameter integer BAUD     = 115_200
) (
    input  logic       clk_i,
    input  logic       reset_i,
    input  logic       rx_i,
    output logic [7:0] data_o,
    output logic       valid_o
);

    localparam integer CLOCKS_PER_BIT = CLOCK_HZ / BAUD;
    localparam integer HALF_BIT       = CLOCKS_PER_BIT / 2;
    localparam integer BAUD_COUNT_W =
        (CLOCKS_PER_BIT <= 1) ? 1 : $clog2(CLOCKS_PER_BIT);

    localparam logic [1:0] RX_IDLE  = 2'd0;
    localparam logic [1:0] RX_START = 2'd1;
    localparam logic [1:0] RX_DATA  = 2'd2;
    localparam logic [1:0] RX_STOP  = 2'd3;

    (* ASYNC_REG = "TRUE" *) logic [1:0] rx_sync_q;
    logic [1:0] state_q;
    logic [2:0] bit_index_q;
    logic [7:0] data_shift_q;
    logic [BAUD_COUNT_W-1:0] baud_count_q;

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            rx_sync_q <= 2'b11;
        end else begin
            rx_sync_q <= {rx_sync_q[0], rx_i};
        end
    end

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            state_q       <= RX_IDLE;
            bit_index_q   <= 3'd0;
            data_shift_q  <= 8'h00;
            baud_count_q  <= '0;
            data_o        <= 8'h00;
            valid_o       <= 1'b0;
        end else begin
            valid_o <= 1'b0;

            case (state_q)
                RX_IDLE: begin
                    if (!rx_sync_q[1]) begin
                        baud_count_q <= HALF_BIT - 1;
                        state_q      <= RX_START;
                    end
                end

                RX_START: begin
                    if (baud_count_q == 0) begin
                        if (!rx_sync_q[1]) begin
                            baud_count_q <= CLOCKS_PER_BIT - 1;
                            bit_index_q  <= 3'd0;
                            state_q      <= RX_DATA;
                        end else begin
                            state_q <= RX_IDLE;
                        end
                    end else begin
                        baud_count_q <= baud_count_q - 1'b1;
                    end
                end

                RX_DATA: begin
                    if (baud_count_q == 0) begin
                        data_shift_q[bit_index_q] <= rx_sync_q[1];
                        baud_count_q <= CLOCKS_PER_BIT - 1;
                        if (bit_index_q == 3'd7) begin
                            state_q <= RX_STOP;
                        end else begin
                            bit_index_q <= bit_index_q + 3'd1;
                        end
                    end else begin
                        baud_count_q <= baud_count_q - 1'b1;
                    end
                end

                RX_STOP: begin
                    if (baud_count_q == 0) begin
                        if (rx_sync_q[1]) begin
                            data_o  <= data_shift_q;
                            valid_o <= 1'b1;
                        end
                        state_q <= RX_IDLE;
                    end else begin
                        baud_count_q <= baud_count_q - 1'b1;
                    end
                end

                default: state_q <= RX_IDLE;
            endcase
        end
    end

endmodule

module openrv64_fpga_uart_command #(
    parameter integer CLOCK_HZ           = 200_000_000,
    parameter integer BAUD               = 115_200,
    parameter integer FIRST_DELAY_CYCLES = 20_000_000
) (
    input  logic clk_i,
    input  logic reset_i,
    input  logic rx_i,
    output logic tx_o
);

    localparam integer READY_LENGTH = 29;
    localparam integer PASS_LENGTH  = 23;
    localparam integer DELAY_COUNT_W =
        (FIRST_DELAY_CYCLES <= 1) ? 1 : $clog2(FIRST_DELAY_CYCLES);

    localparam logic [1:0] WAIT_START = 2'd0;
    localparam logic [1:0] SEND_READY = 2'd1;
    localparam logic [1:0] WAIT_QUERY = 2'd2;
    localparam logic [1:0] SEND_PASS  = 2'd3;

    logic [DELAY_COUNT_W-1:0] delay_count_q;
    logic [5:0] message_index_q;
    logic [1:0] state_q;
    logic tx_start_q;
    logic [7:0] tx_data_q;
    logic tx_busy;
    logic [7:0] rx_data;
    logic rx_valid;

    function automatic logic [7:0] ready_byte(input logic [5:0] index);
        case (index)
            6'd0:  ready_byte = "O";
            6'd1:  ready_byte = "P";
            6'd2:  ready_byte = "E";
            6'd3:  ready_byte = "N";
            6'd4:  ready_byte = "R";
            6'd5:  ready_byte = "V";
            6'd6:  ready_byte = "6";
            6'd7:  ready_byte = "4";
            6'd8:  ready_byte = " ";
            6'd9:  ready_byte = "U";
            6'd10: ready_byte = "A";
            6'd11: ready_byte = "R";
            6'd12: ready_byte = "T";
            6'd13: ready_byte = " ";
            6'd14: ready_byte = "C";
            6'd15: ready_byte = "O";
            6'd16: ready_byte = "M";
            6'd17: ready_byte = "M";
            6'd18: ready_byte = "A";
            6'd19: ready_byte = "N";
            6'd20: ready_byte = "D";
            6'd21: ready_byte = " ";
            6'd22: ready_byte = "R";
            6'd23: ready_byte = "E";
            6'd24: ready_byte = "A";
            6'd25: ready_byte = "D";
            6'd26: ready_byte = "Y";
            6'd27: ready_byte = 8'h0d;
            6'd28: ready_byte = 8'h0a;
            default: ready_byte = 8'h00;
        endcase
    endfunction

    function automatic logic [7:0] pass_byte(input logic [5:0] index);
        case (index)
            6'd0:  pass_byte = "O";
            6'd1:  pass_byte = "P";
            6'd2:  pass_byte = "E";
            6'd3:  pass_byte = "N";
            6'd4:  pass_byte = "R";
            6'd5:  pass_byte = "V";
            6'd6:  pass_byte = "6";
            6'd7:  pass_byte = "4";
            6'd8:  pass_byte = " ";
            6'd9:  pass_byte = "U";
            6'd10: pass_byte = "A";
            6'd11: pass_byte = "R";
            6'd12: pass_byte = "T";
            6'd13: pass_byte = " ";
            6'd14: pass_byte = "R";
            6'd15: pass_byte = "X";
            6'd16: pass_byte = " ";
            6'd17: pass_byte = "P";
            6'd18: pass_byte = "A";
            6'd19: pass_byte = "S";
            6'd20: pass_byte = "S";
            6'd21: pass_byte = 8'h0d;
            6'd22: pass_byte = 8'h0a;
            default: pass_byte = 8'h00;
        endcase
    endfunction

    openrv64_fpga_uart_rx #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD(BAUD)
    ) u_rx (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .rx_i(rx_i),
        .data_o(rx_data),
        .valid_o(rx_valid)
    );

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
            delay_count_q  <= '0;
            message_index_q <= 6'd0;
            state_q         <= WAIT_START;
            tx_start_q      <= 1'b0;
            tx_data_q       <= 8'h00;
        end else begin
            tx_start_q <= 1'b0;

            case (state_q)
                WAIT_START: begin
                    if (delay_count_q == FIRST_DELAY_CYCLES - 1) begin
                        message_index_q <= 6'd0;
                        state_q         <= SEND_READY;
                    end else begin
                        delay_count_q <= delay_count_q + 1'b1;
                    end
                end

                SEND_READY: begin
                    if (!tx_busy && !tx_start_q) begin
                        if (message_index_q < READY_LENGTH) begin
                            tx_data_q       <= ready_byte(message_index_q);
                            tx_start_q      <= 1'b1;
                            message_index_q <= message_index_q + 6'd1;
                        end else begin
                            state_q <= WAIT_QUERY;
                        end
                    end
                end

                WAIT_QUERY: begin
                    if (rx_valid && (rx_data == 8'h3f)) begin
                        message_index_q <= 6'd0;
                        state_q         <= SEND_PASS;
                    end
                end

                SEND_PASS: begin
                    if (!tx_busy && !tx_start_q) begin
                        if (message_index_q < PASS_LENGTH) begin
                            tx_data_q       <= pass_byte(message_index_q);
                            tx_start_q      <= 1'b1;
                            message_index_q <= message_index_q + 6'd1;
                        end else begin
                            state_q <= WAIT_QUERY;
                        end
                    end
                end

                default: state_q <= WAIT_START;
            endcase
        end
    end

endmodule
