// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// Pre-boot UART receiver that writes a Linux Image directly through the
// native 256-bit MIG application port.  The CPU remains in reset throughout.

`timescale 1ns/1ps

module openrv64_fpga_uart_rx #(
    parameter integer CLOCK_HZ = 100_000_000,
    parameter integer BAUD = 115_200
) (
    input  logic       clk_i,
    input  logic       reset_i,
    input  logic       rx_i,
    output logic [7:0] data_o,
    output logic       valid_o
);

    localparam integer BIT_CYCLES = (CLOCK_HZ + (BAUD / 2)) / BAUD;
    localparam integer HALF_BIT_CYCLES = BIT_CYCLES / 2;
    localparam integer COUNT_WIDTH =
        (BIT_CYCLES <= 2) ? 1 : $clog2(BIT_CYCLES);

    localparam logic [1:0] RX_IDLE  = 2'd0;
    localparam logic [1:0] RX_START = 2'd1;
    localparam logic [1:0] RX_DATA  = 2'd2;
    localparam logic [1:0] RX_STOP  = 2'd3;

    logic rx_meta_q;
    logic rx_sync_q;
    logic [1:0] state_q;
    logic [COUNT_WIDTH-1:0] count_q;
    logic [2:0] bit_index_q;
    logic [7:0] shift_q;

    initial begin
        if (BIT_CYCLES < 8)
            $fatal(1, "UART receiver clock must be at least 8x baud");
    end

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            rx_meta_q <= 1'b1;
            rx_sync_q <= 1'b1;
        end else begin
            rx_meta_q <= rx_i;
            rx_sync_q <= rx_meta_q;
        end
    end

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            state_q <= RX_IDLE;
            count_q <= '0;
            bit_index_q <= 3'd0;
            shift_q <= 8'h00;
            data_o <= 8'h00;
            valid_o <= 1'b0;
        end else begin
            valid_o <= 1'b0;
            case (state_q)
                RX_IDLE: begin
                    if (!rx_sync_q) begin
                        count_q <= COUNT_WIDTH'(HALF_BIT_CYCLES - 1);
                        state_q <= RX_START;
                    end
                end
                RX_START: begin
                    if (count_q != 0) begin
                        count_q <= count_q - 1'b1;
                    end else if (rx_sync_q) begin
                        state_q <= RX_IDLE;
                    end else begin
                        count_q <= COUNT_WIDTH'(BIT_CYCLES - 1);
                        bit_index_q <= 3'd0;
                        state_q <= RX_DATA;
                    end
                end
                RX_DATA: begin
                    if (count_q != 0) begin
                        count_q <= count_q - 1'b1;
                    end else begin
                        shift_q[bit_index_q] <= rx_sync_q;
                        count_q <= COUNT_WIDTH'(BIT_CYCLES - 1);
                        if (bit_index_q == 3'd7)
                            state_q <= RX_STOP;
                        else
                            bit_index_q <= bit_index_q + 1'b1;
                    end
                end
                default: begin
                    if (count_q != 0) begin
                        count_q <= count_q - 1'b1;
                    end else begin
                        if (rx_sync_q) begin
                            data_o <= shift_q;
                            valid_o <= 1'b1;
                        end
                        state_q <= RX_IDLE;
                    end
                end
            endcase
        end
    end

endmodule

module openrv64_fpga_uart_ddr_loader #(
    parameter integer CLOCK_HZ = 100_000_000,
    parameter integer BAUD = 115_200,
    parameter integer TIMEOUT_CYCLES = 100_000_000
) (
    input  logic         clk_i,
    input  logic         reset_i,
    input  logic         start_i,
    input  logic         calib_complete_i,
    input  logic         uart_rx_i,
    output logic         uart_tx_o,

    output logic [27:0]  app_addr_o,
    output logic [2:0]   app_cmd_o,
    output logic         app_en_o,
    input  logic         app_rdy_i,
    output logic [255:0] app_wdf_data_o,
    output logic         app_wdf_end_o,
    output logic [31:0]  app_wdf_mask_o,
    output logic         app_wdf_wren_o,
    input  logic         app_wdf_rdy_i,

    output logic         active_o,
    output logic         done_o,
    output logic         failed_o
);

    localparam logic [3:0] STATE_WAIT       = 4'd0;
    localparam logic [3:0] STATE_MSG_READY  = 4'd1;
    localparam logic [3:0] STATE_HEADER     = 4'd2;
    localparam logic [3:0] STATE_LENGTH     = 4'd3;
    localparam logic [3:0] STATE_CRC        = 4'd4;
    localparam logic [3:0] STATE_MSG_START  = 4'd5;
    localparam logic [3:0] STATE_PAYLOAD    = 4'd6;
    localparam logic [3:0] STATE_WRITE      = 4'd7;
    localparam logic [3:0] STATE_MSG_PASS   = 4'd8;
    localparam logic [3:0] STATE_MSG_FAIL   = 4'd9;
    localparam logic [3:0] STATE_DONE       = 4'd10;
    localparam logic [3:0] STATE_FAIL       = 4'd11;

    localparam logic [1:0] MESSAGE_READY = 2'd0;
    localparam logic [1:0] MESSAGE_START = 2'd1;
    localparam logic [1:0] MESSAGE_PASS  = 2'd2;
    localparam logic [1:0] MESSAGE_FAIL  = 2'd3;

    // Native MIG addresses count 32-bit words. 0x8020_0000 is therefore
    // 0x0080_0000 in the 256-bit application-port address convention.
    localparam logic [27:0] LINUX_BASE = 28'h008_0000;
    localparam logic [31:0] MAX_IMAGE_BYTES = 32'h0fd0_0000;
    localparam integer TIMEOUT_WIDTH =
        (TIMEOUT_CYCLES <= 1) ? 1 : $clog2(TIMEOUT_CYCLES);
    localparam logic [TIMEOUT_WIDTH-1:0] TIMEOUT_LIMIT =
        TIMEOUT_WIDTH'(TIMEOUT_CYCLES - 1);

    logic [7:0] rx_data;
    logic rx_valid;
    logic tx_start_q;
    logic [7:0] tx_data_q;
    logic tx_busy;

    logic [3:0] state_q;
    logic [3:0] magic_index_q;
    logic [1:0] header_index_q;
    logic [31:0] length_q;
    logic [31:0] expected_crc_q;
    logic [31:0] remaining_q;
    logic [31:0] crc_q;
    logic [4:0] line_byte_index_q;
    logic [255:0] line_data_q;
    logic [255:0] write_data_q;
    logic [31:0] write_mask_q;
    logic [27:0] write_addr_q;
    logic command_sent_q;
    logic data_sent_q;
    logic [TIMEOUT_WIDTH-1:0] timeout_q;

    logic message_start_q;
    logic [1:0] message_request_q;
    logic message_active_q;
    logic [1:0] message_id_q;
    logic [5:0] message_index_q;
    logic message_done_q;

    function automatic logic [7:0] magic_byte(input logic [3:0] index);
        case (index)
            4'd0: magic_byte = "O";
            4'd1: magic_byte = "R";
            4'd2: magic_byte = "V";
            4'd3: magic_byte = "6";
            4'd4: magic_byte = "4";
            4'd5: magic_byte = "L";
            4'd6: magic_byte = "N";
            default: magic_byte = "X";
        endcase
    endfunction

    function automatic logic [5:0] message_length(input logic [1:0] id);
        case (id)
            MESSAGE_READY: message_length = 6'd25;
            MESSAGE_START: message_length = 6'd25;
            MESSAGE_PASS:  message_length = 6'd24;
            default:       message_length = 6'd28;
        endcase
    endfunction

    function automatic logic [7:0] message_byte(
        input logic [1:0] id,
        input logic [5:0] index
    );
        begin
            case (index)
                6'd0:  message_byte = "O";
                6'd1:  message_byte = "P";
                6'd2:  message_byte = "E";
                6'd3:  message_byte = "N";
                6'd4:  message_byte = "R";
                6'd5:  message_byte = "V";
                6'd6:  message_byte = "6";
                6'd7:  message_byte = "4";
                6'd8:  message_byte = " ";
                6'd9:  message_byte = "D";
                6'd10: message_byte = "D";
                6'd11: message_byte = "R";
                6'd12: message_byte = " ";
                6'd13: message_byte = "L";
                6'd14: message_byte = "O";
                6'd15: message_byte = "A";
                6'd16: message_byte = "D";
                6'd17: message_byte = " ";
                default: begin
                    case (id)
                        MESSAGE_READY: begin
                            case (index)
                                6'd18: message_byte = "R";
                                6'd19: message_byte = "E";
                                6'd20: message_byte = "A";
                                6'd21: message_byte = "D";
                                6'd22: message_byte = "Y";
                                6'd23: message_byte = 8'h0d;
                                default: message_byte = 8'h0a;
                            endcase
                        end
                        MESSAGE_START: begin
                            case (index)
                                6'd18: message_byte = "S";
                                6'd19: message_byte = "T";
                                6'd20: message_byte = "A";
                                6'd21: message_byte = "R";
                                6'd22: message_byte = "T";
                                6'd23: message_byte = 8'h0d;
                                default: message_byte = 8'h0a;
                            endcase
                        end
                        MESSAGE_PASS: begin
                            case (index)
                                6'd18: message_byte = "P";
                                6'd19: message_byte = "A";
                                6'd20: message_byte = "S";
                                6'd21: message_byte = "S";
                                6'd22: message_byte = 8'h0d;
                                default: message_byte = 8'h0a;
                            endcase
                        end
                        default: begin
                            case (index)
                                6'd18: message_byte = "C";
                                6'd19: message_byte = "R";
                                6'd20: message_byte = "C";
                                6'd21: message_byte = " ";
                                6'd22: message_byte = "F";
                                6'd23: message_byte = "A";
                                6'd24: message_byte = "I";
                                6'd25: message_byte = "L";
                                6'd26: message_byte = 8'h0d;
                                default: message_byte = 8'h0a;
                            endcase
                        end
                    endcase
                end
            endcase
        end
    endfunction

    function automatic logic [31:0] crc32_byte(
        input logic [31:0] crc,
        input logic [7:0] data
    );
        logic [31:0] value;
        integer bit_index;
        begin
            value = crc ^ {24'd0, data};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                value = value[0] ? ((value >> 1) ^ 32'hedb8_8320) :
                                   (value >> 1);
            crc32_byte = value;
        end
    endfunction

    function automatic logic [255:0] insert_line_byte(
        input logic [255:0] line,
        input logic [4:0] index,
        input logic [7:0] data
    );
        logic [255:0] value;
        begin
            value = line;
            value[index*8 +: 8] = data;
            insert_line_byte = value;
        end
    endfunction

    function automatic logic [31:0] final_mask(input logic [4:0] index);
        logic [31:0] value;
        integer byte_index;
        begin
            for (byte_index = 0; byte_index < 32; byte_index = byte_index + 1)
                value[byte_index] = (byte_index > index);
            final_mask = value;
        end
    endfunction

    wire [31:0] header_word =
        (state_q == STATE_LENGTH ? length_q : expected_crc_q) |
        ({24'd0, rx_data} << (header_index_q * 8));
    wire command_fire = app_en_o && app_rdy_i;
    wire data_fire = app_wdf_wren_o && app_wdf_rdy_i;
    wire write_complete = (command_sent_q || command_fire) &&
                          (data_sent_q || data_fire);

    openrv64_fpga_uart_rx #(
        .CLOCK_HZ(CLOCK_HZ),
        .BAUD(BAUD)
    ) u_rx (
        .clk_i(clk_i),
        .reset_i(reset_i),
        .rx_i(uart_rx_i),
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
        .tx_o(uart_tx_o),
        .busy_o(tx_busy)
    );

    always_comb begin
        app_addr_o = write_addr_q;
        app_cmd_o = 3'b000;
        app_en_o = (state_q == STATE_WRITE) && !command_sent_q;
        app_wdf_data_o = write_data_q;
        app_wdf_mask_o = write_mask_q;
        app_wdf_wren_o = (state_q == STATE_WRITE) && !data_sent_q;
        app_wdf_end_o = app_wdf_wren_o;
        active_o = start_i && state_q != STATE_DONE && state_q != STATE_FAIL;
        done_o = state_q == STATE_DONE;
        failed_o = state_q == STATE_FAIL;
    end

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            tx_start_q <= 1'b0;
            tx_data_q <= 8'h00;
            message_active_q <= 1'b0;
            message_id_q <= MESSAGE_READY;
            message_index_q <= 6'd0;
            message_done_q <= 1'b0;
        end else begin
            tx_start_q <= 1'b0;
            message_done_q <= 1'b0;
            if (message_start_q && !message_active_q) begin
                message_active_q <= 1'b1;
                message_id_q <= message_request_q;
                message_index_q <= 6'd0;
            end else if (message_active_q && !tx_busy && !tx_start_q) begin
                if (message_index_q < message_length(message_id_q)) begin
                    tx_data_q <= message_byte(message_id_q, message_index_q);
                    tx_start_q <= 1'b1;
                    message_index_q <= message_index_q + 1'b1;
                end else begin
                    message_active_q <= 1'b0;
                    message_done_q <= 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            state_q <= STATE_WAIT;
            magic_index_q <= 4'd0;
            header_index_q <= 2'd0;
            length_q <= 32'd0;
            expected_crc_q <= 32'd0;
            remaining_q <= 32'd0;
            crc_q <= 32'hffff_ffff;
            line_byte_index_q <= 5'd0;
            line_data_q <= 256'd0;
            write_data_q <= 256'd0;
            write_mask_q <= 32'hffff_ffff;
            write_addr_q <= LINUX_BASE;
            command_sent_q <= 1'b0;
            data_sent_q <= 1'b0;
            timeout_q <= '0;
            message_start_q <= 1'b0;
            message_request_q <= MESSAGE_READY;
        end else begin
            message_start_q <= 1'b0;
            case (state_q)
                STATE_WAIT: begin
                    if (start_i && calib_complete_i) begin
                        message_request_q <= MESSAGE_READY;
                        message_start_q <= 1'b1;
                        state_q <= STATE_MSG_READY;
                    end
                end
                STATE_MSG_READY: begin
                    if (!calib_complete_i) begin
                        state_q <= STATE_FAIL;
                    end else if (message_done_q) begin
                        magic_index_q <= 4'd0;
                        state_q <= STATE_HEADER;
                    end
                end
                STATE_HEADER: begin
                    if (!calib_complete_i) begin
                        state_q <= STATE_FAIL;
                    end else if (rx_valid) begin
                        if (rx_data == magic_byte(magic_index_q)) begin
                            if (magic_index_q == 4'd7) begin
                                length_q <= 32'd0;
                                header_index_q <= 2'd0;
                                state_q <= STATE_LENGTH;
                            end else begin
                                magic_index_q <= magic_index_q + 1'b1;
                            end
                        end else begin
                            magic_index_q <= (rx_data == "O") ? 4'd1 : 4'd0;
                        end
                    end
                end
                STATE_LENGTH: begin
                    if (rx_valid) begin
                        length_q <= header_word;
                        if (header_index_q == 2'd3) begin
                            if (header_word == 0 ||
                                header_word > MAX_IMAGE_BYTES ||
                                header_word[1:0] != 2'b00) begin
                                magic_index_q <= 4'd0;
                                state_q <= STATE_HEADER;
                            end else begin
                                expected_crc_q <= 32'd0;
                                header_index_q <= 2'd0;
                                state_q <= STATE_CRC;
                            end
                        end else begin
                            header_index_q <= header_index_q + 1'b1;
                        end
                    end
                end
                STATE_CRC: begin
                    if (rx_valid) begin
                        expected_crc_q <= header_word;
                        if (header_index_q == 2'd3) begin
                            message_request_q <= MESSAGE_START;
                            message_start_q <= 1'b1;
                            state_q <= STATE_MSG_START;
                        end else begin
                            header_index_q <= header_index_q + 1'b1;
                        end
                    end
                end
                STATE_MSG_START: begin
                    if (message_done_q) begin
                        remaining_q <= length_q;
                        crc_q <= 32'hffff_ffff;
                        line_byte_index_q <= 5'd0;
                        line_data_q <= 256'd0;
                        write_addr_q <= LINUX_BASE;
                        state_q <= STATE_PAYLOAD;
                    end
                end
                STATE_PAYLOAD: begin
                    if (!calib_complete_i) begin
                        state_q <= STATE_FAIL;
                    end else if (rx_valid) begin
                        line_data_q <= insert_line_byte(
                            line_data_q, line_byte_index_q, rx_data);
                        crc_q <= crc32_byte(crc_q, rx_data);
                        remaining_q <= remaining_q - 1'b1;
                        if (line_byte_index_q == 5'd31 || remaining_q == 1) begin
                            write_data_q <= insert_line_byte(
                                line_data_q, line_byte_index_q, rx_data);
                            write_mask_q <= (remaining_q == 1) ?
                                final_mask(line_byte_index_q) : 32'd0;
                            command_sent_q <= 1'b0;
                            data_sent_q <= 1'b0;
                            timeout_q <= '0;
                            state_q <= STATE_WRITE;
                        end else begin
                            line_byte_index_q <= line_byte_index_q + 1'b1;
                        end
                    end
                end
                STATE_WRITE: begin
                    if (!calib_complete_i) begin
                        state_q <= STATE_FAIL;
                    end else if (TIMEOUT_CYCLES > 0 &&
                                 timeout_q == TIMEOUT_LIMIT) begin
                        state_q <= STATE_FAIL;
                    end else if (write_complete) begin
                        command_sent_q <= 1'b0;
                        data_sent_q <= 1'b0;
                        timeout_q <= '0;
                        if (remaining_q == 0) begin
                            if ((~crc_q) == expected_crc_q) begin
                                message_request_q <= MESSAGE_PASS;
                                message_start_q <= 1'b1;
                                state_q <= STATE_MSG_PASS;
                            end else begin
                                message_request_q <= MESSAGE_FAIL;
                                message_start_q <= 1'b1;
                                state_q <= STATE_MSG_FAIL;
                            end
                        end else begin
                            write_addr_q <= write_addr_q + 28'd8;
                            line_byte_index_q <= 5'd0;
                            line_data_q <= 256'd0;
                            state_q <= STATE_PAYLOAD;
                        end
                    end else begin
                        if (command_fire)
                            command_sent_q <= 1'b1;
                        if (data_fire)
                            data_sent_q <= 1'b1;
                        timeout_q <= timeout_q + 1'b1;
                    end
                end
                STATE_MSG_PASS: begin
                    if (message_done_q)
                        state_q <= STATE_DONE;
                end
                STATE_MSG_FAIL: begin
                    if (message_done_q)
                        state_q <= STATE_FAIL;
                end
                STATE_DONE: begin
                    if (!calib_complete_i)
                        state_q <= STATE_FAIL;
                end
                default: state_q <= STATE_FAIL;
            endcase
        end
    end

endmodule
