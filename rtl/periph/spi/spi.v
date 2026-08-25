`timescale 1ns/1ps

// Minimal blocking SPI-mode controller for ROM-driven SD-card boot.
//
// Software owns chip select and the SD command protocol.  Blocking transfers
// may be one to 512 bytes.  An SD multi-block receive mode autonomously fills
// two 512-byte buffers so software can drain one while the other is filled.
module openrv64_spi #(
    parameter integer INIT_HALF_PERIOD_CYCLES = 12,
    parameter integer FAST_HALF_PERIOD_CYCLES = 1
) (
    input  wire        clk_i,
    input  wire        rst_ni,

    input  wire        card_present_i,
    output wire        spi_clk_o,
    output wire        spi_mosi_o,
    input  wire        spi_miso_i,
    output wire        spi_cs_n_o,

    input  wire        mem_valid_i,
    output wire        mem_ready_o,
    input  wire        mem_write_i,
    input  wire [63:0] mem_addr_i,
    input  wire [63:0] mem_wdata_i,
    input  wire [7:0]  mem_wstrb_i,
    output reg  [63:0] mem_rdata_o
);

    localparam [63:0] CONTROL_OFFSET = 64'h00;
    localparam [63:0] STATUS_OFFSET  = 64'h08;
    localparam [63:0] XFER_OFFSET    = 64'h10;
    localparam [63:0] TX_LO_OFFSET   = 64'h18;
    localparam [63:0] TX_HI_OFFSET   = 64'h20;
    localparam [63:0] RX_LO_OFFSET   = 64'h28;
    localparam [63:0] RX_HI_OFFSET   = 64'h30;
    localparam [63:0] STREAM_START_OFFSET   = 64'h38;
    localparam [63:0] STREAM_STATUS_OFFSET  = 64'h40;
    localparam [63:0] STREAM_RELEASE_OFFSET = 64'h48;
    localparam [63:0] STREAM_CRC32_OFFSET   = 64'h50;
    localparam [63:0] BUFFER0_BASE   = 64'h100;
    localparam [63:0] BUFFER0_LIMIT  = 64'h300;
    localparam [63:0] BUFFER1_BASE   = 64'h300;
    localparam [63:0] BUFFER1_LIMIT  = 64'h500;

    localparam [2:0] STREAM_TOKEN    = 3'd0;
    localparam [2:0] STREAM_DATA     = 3'd1;
    localparam [2:0] STREAM_CRC      = 3'd2;
    localparam [2:0] STREAM_COMPLETE = 3'd3;
    localparam [2:0] STREAM_WAIT     = 3'd4;
    localparam [2:0] STREAM_ABORT    = 3'd5;

    localparam integer MAX_HALF_PERIOD_CYCLES =
        (INIT_HALF_PERIOD_CYCLES > FAST_HALF_PERIOD_CYCLES) ?
            INIT_HALF_PERIOD_CYCLES : FAST_HALF_PERIOD_CYCLES;
    localparam integer DIVIDER_WIDTH =
        (MAX_HALF_PERIOD_CYCLES <= 1) ? 1 :
        $clog2(MAX_HALF_PERIOD_CYCLES);
    localparam [DIVIDER_WIDTH-1:0] INIT_HALF_PERIOD =
        INIT_HALF_PERIOD_CYCLES;
    localparam [DIVIDER_WIDTH-1:0] FAST_HALF_PERIOD =
        FAST_HALF_PERIOD_CYCLES;

    reg cs_active_q;
    reg fast_clock_q;
    reg busy_q;
    reg done_q;
    reg error_q;
    reg spi_clk_q;
    reg [9:0] length_q;
    reg [9:0] completed_length_q;
    reg [11:0] bit_index_q;
    reg [DIVIDER_WIDTH-1:0] divider_count_q;
    reg [127:0] tx_q;
    reg [127:0] rx_q;
    reg [63:0] rx_shift_q;
    reg card_present_sync_1_q;
    reg card_present_sync_2_q;

    reg stream_active_q;
    reg [1:0] stream_ready_q;
    reg stream_error_q;
    reg stream_fill_bank_q;
    reg [31:0] stream_remaining_q;
    reg [2:0] stream_state_q;
    reg [2:0] stream_token_bit_q;
    reg [7:0] stream_token_shift_q;
    reg [11:0] stream_data_bit_q;
    reg [3:0] stream_crc_bit_q;
    reg [31:0] stream_crc32_q;
    reg [31:0] stream_crc_bytes_remaining_q;

    // Two independent 512-byte sectors.  The SPI engine writes complete
    // 64-bit words; target-bus reads use the synchronous ports below.
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [63:0] buffer0_q [0:63];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [63:0] buffer1_q [0:63];
    reg [63:0] buffer0_read_data_q;
    reg [63:0] buffer1_read_data_q;
    reg buffer_read_response_q;
    reg buffer_read_recover_q;

    wire buffer0_selected =
        (mem_addr_i >= BUFFER0_BASE) && (mem_addr_i < BUFFER0_LIMIT);
    wire buffer1_selected =
        (mem_addr_i >= BUFFER1_BASE) && (mem_addr_i < BUFFER1_LIMIT);
    wire buffer_selected = buffer0_selected || buffer1_selected;
    wire [5:0] buffer0_read_index =
        (mem_addr_i - BUFFER0_BASE) >> 3;
    wire [5:0] buffer1_read_index =
        (mem_addr_i - BUFFER1_BASE) >> 3;
    wire buffer_read_request =
        mem_valid_i && !mem_write_i && buffer_selected;
    wire write_accept = mem_valid_i && mem_write_i;
    wire status_clear = write_accept && mem_wstrb_i[0] &&
        (mem_addr_i[63:3] == (STATUS_OFFSET >> 3));
    wire start_write = write_accept && mem_wstrb_i[1:0] != 2'b00 &&
        (mem_addr_i[63:3] == (XFER_OFFSET >> 3));
    wire stream_start_write = write_accept &&
        (mem_wstrb_i == 8'hff) &&
        (mem_addr_i[63:3] == (STREAM_START_OFFSET >> 3));
    wire stream_release_write = write_accept && mem_wstrb_i[0] &&
        (mem_addr_i[63:3] == (STREAM_RELEASE_OFFSET >> 3));
    wire [9:0] requested_length = mem_wdata_i[9:0];
    wire requested_length_valid =
        (requested_length >= 10'd1) && (requested_length <= 10'd512);
    wire [40:0] requested_stream_capacity =
        {mem_wdata_i[31:0], 9'd0};
    wire requested_stream_valid =
        (mem_wdata_i[31:0] != 32'd0) &&
        (mem_wdata_i[63:32] != 32'd0) &&
        ({9'd0, mem_wdata_i[63:32]} <= requested_stream_capacity);

    wire [DIVIDER_WIDTH-1:0] selected_half_period = fast_clock_q ?
        FAST_HALF_PERIOD : INIT_HALF_PERIOD;
    wire stream_clocking = stream_active_q &&
        (stream_state_q != STREAM_WAIT);
    wire divider_tick = (busy_q || stream_clocking) &&
        (divider_count_q == (selected_half_period - 1'b1));
    wire [6:0] command_buffer_bit =
        {bit_index_q[6:3], ~bit_index_q[2:0]};
    wire transmit_bit = (bit_index_q < 12'd128) ?
        tx_q[command_buffer_bit] : 1'b1;
    wire [12:0] transfer_bit_count = {length_q, 3'b000};
    wire [11:0] final_bit_index = transfer_bit_count[11:0] - 1'b1;
    wire [63:0] received_shift_word = {rx_shift_q[62:0], spi_miso_i};
    wire [7:0] received_token_byte =
        {stream_token_shift_q[6:0], spi_miso_i};
    wire blocking_buffer_write = busy_q && divider_tick && !spi_clk_q &&
        (bit_index_q[5:0] == 6'd63);
    wire stream_buffer_write = stream_clocking && divider_tick &&
        !spi_clk_q && (stream_state_q == STREAM_DATA) &&
        (stream_data_bit_q[5:0] == 6'd63);
    wire buffer0_write = blocking_buffer_write ||
        (stream_buffer_write && !stream_fill_bank_q);
    wire buffer1_write = stream_buffer_write && stream_fill_bank_q;
    wire [5:0] buffer0_write_index = blocking_buffer_write ?
        bit_index_q[11:6] : stream_data_bit_q[11:6];

    wire [63:0] control_read_data =
        {62'd0, fast_clock_q, cs_active_q};
    wire [63:0] status_read_data = {
        39'd0,
        error_q,
        6'd0,
        completed_length_q,
        5'd0,
        card_present_sync_2_q,
        done_q,
        busy_q
    };
    wire [63:0] stream_status_read_data = {
        stream_remaining_q,
        27'd0,
        stream_fill_bank_q,
        stream_error_q,
        stream_ready_q[1],
        stream_ready_q[0],
        stream_active_q
    };

    function [63:0] merge_write_data;
        input [63:0] old_value;
        input [63:0] new_value;
        input [7:0] write_strobe;
        integer byte_index;
        begin
            merge_write_data = old_value;
            for (byte_index = 0; byte_index < 8;
                 byte_index = byte_index + 1) begin
                if (write_strobe[byte_index])
                    merge_write_data[8*byte_index +: 8] =
                        new_value[8*byte_index +: 8];
            end
        end
    endfunction

    function [63:0] reverse_bytes;
        input [63:0] value;
        integer byte_index;
        begin
            for (byte_index = 0; byte_index < 8;
                 byte_index = byte_index + 1)
                reverse_bytes[8*byte_index +: 8] =
                    value[8*(7-byte_index) +: 8];
        end
    endfunction

    // Update reflected IEEE CRC-32 with one complete SD wire byte.  SD sends
    // each byte most-significant bit first, so collect the byte before applying
    // the reflected polynomial rather than updating directly in wire order.
    function [31:0] crc32_update_byte;
        input [31:0] crc;
        input [7:0] data;
        reg [31:0] next_crc;
        integer crc_bit;
        begin
            next_crc = crc ^ {24'd0, data};
            for (crc_bit = 0; crc_bit < 8; crc_bit = crc_bit + 1) begin
                if (next_crc[0])
                    next_crc = (next_crc >> 1) ^ 32'hedb8_8320;
                else
                    next_crc = next_crc >> 1;
            end
            crc32_update_byte = next_crc;
        end
    endfunction

    wire [63:0] merged_control = merge_write_data(
        control_read_data, mem_wdata_i, mem_wstrb_i);
    wire [63:0] merged_tx_lo = merge_write_data(
        tx_q[63:0], mem_wdata_i, mem_wstrb_i);
    wire [63:0] merged_tx_hi = merge_write_data(
        tx_q[127:64], mem_wdata_i, mem_wstrb_i);

    initial begin
        if (INIT_HALF_PERIOD_CYCLES < 1 ||
            FAST_HALF_PERIOD_CYCLES < 1)
            $fatal(1, "SPI half-period parameters must be positive");
    end

    assign mem_ready_o = buffer_read_request ? buffer_read_response_q :
                         mem_valid_i;
    assign spi_clk_o = spi_clk_q;
    assign spi_mosi_o = busy_q ? transmit_bit : 1'b1;
    assign spi_cs_n_o = !cs_active_q;

    always @* begin
        mem_rdata_o = 64'd0;
        if (buffer_selected) begin
            mem_rdata_o = buffer_read_response_q ?
                (buffer0_selected ? buffer0_read_data_q :
                 buffer1_read_data_q) : 64'd0;
        end else begin
            case (mem_addr_i[63:3])
                (CONTROL_OFFSET >> 3): mem_rdata_o = control_read_data;
                (STATUS_OFFSET >> 3):  mem_rdata_o = status_read_data;
                (XFER_OFFSET >> 3):
                    mem_rdata_o = {54'd0, completed_length_q};
                (TX_LO_OFFSET >> 3): mem_rdata_o = tx_q[63:0];
                (TX_HI_OFFSET >> 3): mem_rdata_o = tx_q[127:64];
                (RX_LO_OFFSET >> 3): mem_rdata_o = rx_q[63:0];
                (RX_HI_OFFSET >> 3): mem_rdata_o = rx_q[127:64];
                (STREAM_START_OFFSET >> 3):
                    mem_rdata_o = {32'd0, stream_remaining_q};
                (STREAM_STATUS_OFFSET >> 3):
                    mem_rdata_o = stream_status_read_data;
                (STREAM_RELEASE_OFFSET >> 3):
                    mem_rdata_o = {62'd0, stream_ready_q};
                (STREAM_CRC32_OFFSET >> 3):
                    mem_rdata_o = {32'd0, ~stream_crc32_q};
                default: mem_rdata_o = 64'd0;
            endcase
        end
    end

    // Keep the array read in canonical synchronous-memory form so synthesis
    // can merge this register into the block-memory read port.
    always @(posedge clk_i) begin
        if (buffer_read_request && !buffer_read_response_q &&
            !buffer_read_recover_q) begin
            if (buffer0_selected)
                buffer0_read_data_q <= buffer0_q[buffer0_read_index];
            else
                buffer1_read_data_q <= buffer1_q[buffer1_read_index];
        end
    end

    // Independent SPI-side write port.  A full 64-bit word is committed after
    // every eight received bytes; partial command responses use RX_LO/RX_HI.
    always @(posedge clk_i) begin
        if (buffer0_write)
            buffer0_q[buffer0_write_index] <=
                reverse_bytes(received_shift_word);
        if (buffer1_write)
            buffer1_q[stream_data_bit_q[11:6]] <=
                reverse_bytes(received_shift_word);
    end

    // CPU-side response sequencing.  The recovery cycle keeps a held request
    // from being accepted twice.
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            buffer_read_response_q <= 1'b0;
            buffer_read_recover_q <= 1'b0;
        end else if (buffer_read_response_q) begin
            buffer_read_response_q <= 1'b0;
            buffer_read_recover_q <= 1'b1;
        end else if (buffer_read_recover_q) begin
            buffer_read_recover_q <= 1'b0;
        end else if (buffer_read_request) begin
            buffer_read_response_q <= 1'b1;
        end
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cs_active_q <= 1'b0;
            fast_clock_q <= 1'b0;
            busy_q <= 1'b0;
            done_q <= 1'b0;
            error_q <= 1'b0;
            spi_clk_q <= 1'b0;
            length_q <= 10'd0;
            completed_length_q <= 10'd0;
            bit_index_q <= 12'd0;
            divider_count_q <= 0;
            tx_q <= {128{1'b1}};
            rx_q <= 128'd0;
            rx_shift_q <= 64'd0;
            card_present_sync_1_q <= 1'b0;
            card_present_sync_2_q <= 1'b0;
            stream_active_q <= 1'b0;
            stream_ready_q <= 2'b00;
            stream_error_q <= 1'b0;
            stream_fill_bank_q <= 1'b0;
            stream_remaining_q <= 32'd0;
            stream_state_q <= STREAM_TOKEN;
            stream_token_bit_q <= 3'd0;
            stream_token_shift_q <= 8'hff;
            stream_data_bit_q <= 12'd0;
            stream_crc_bit_q <= 4'd0;
            stream_crc32_q <= 32'hffff_ffff;
            stream_crc_bytes_remaining_q <= 32'd0;
        end else begin
            card_present_sync_1_q <= card_present_i;
            card_present_sync_2_q <= card_present_sync_1_q;

            if (status_clear) begin
                if (mem_wdata_i[1])
                    done_q <= 1'b0;
                if (mem_wdata_i[24])
                    error_q <= 1'b0;
            end

            if (stream_release_write) begin
                if (mem_wdata_i[0])
                    stream_ready_q[0] <= 1'b0;
                if (mem_wdata_i[1])
                    stream_ready_q[1] <= 1'b0;
                if (stream_active_q &&
                    (stream_state_q == STREAM_WAIT) &&
                    mem_wdata_i[stream_fill_bank_q]) begin
                    stream_state_q <= STREAM_TOKEN;
                    stream_token_bit_q <= 3'd0;
                    stream_token_shift_q <= 8'hff;
                    divider_count_q <= 0;
                end
            end

            if (write_accept && !busy_q && !stream_active_q) begin
                case (mem_addr_i[63:3])
                    (CONTROL_OFFSET >> 3): begin
                        cs_active_q <= merged_control[0];
                        fast_clock_q <= merged_control[1];
                    end
                    (TX_LO_OFFSET >> 3): tx_q[63:0] <= merged_tx_lo;
                    (TX_HI_OFFSET >> 3): tx_q[127:64] <= merged_tx_hi;
                    default: begin end
                endcase
            end

            if (start_write) begin
                if (busy_q || stream_active_q ||
                    !requested_length_valid) begin
                    error_q <= 1'b1;
                end else begin
                    busy_q <= 1'b1;
                    done_q <= 1'b0;
                    spi_clk_q <= 1'b0;
                    length_q <= requested_length;
                    completed_length_q <= 10'd0;
                    bit_index_q <= 12'd0;
                    divider_count_q <= 0;
                    rx_q <= 128'd0;
                    rx_shift_q <= 64'd0;
                end
            end else if (stream_start_write) begin
                if (busy_q || stream_active_q || !cs_active_q ||
                    !requested_stream_valid) begin
                    error_q <= 1'b1;
                    stream_error_q <= 1'b1;
                end else begin
                    stream_active_q <= 1'b1;
                    stream_ready_q <= 2'b00;
                    stream_error_q <= 1'b0;
                    stream_fill_bank_q <= 1'b0;
                    stream_remaining_q <= mem_wdata_i[31:0];
                    stream_state_q <= STREAM_TOKEN;
                    stream_token_bit_q <= 3'd0;
                    stream_token_shift_q <= 8'hff;
                    stream_data_bit_q <= 12'd0;
                    stream_crc_bit_q <= 4'd0;
                    stream_crc32_q <= 32'hffff_ffff;
                    stream_crc_bytes_remaining_q <= mem_wdata_i[63:32];
                    spi_clk_q <= 1'b0;
                    divider_count_q <= 0;
                    rx_shift_q <= 64'd0;
                end
            end else if (busy_q) begin
                if (divider_tick) begin
                    divider_count_q <= 0;
                    if (!spi_clk_q) begin
                        // SPI mode 0: sample MISO on the rising edge.
                        spi_clk_q <= 1'b1;
                        rx_shift_q <= received_shift_word;
                        if (bit_index_q < 12'd128)
                            rx_q[command_buffer_bit] <= spi_miso_i;
                    end else begin
                        // Advance MOSI after the falling edge.
                        spi_clk_q <= 1'b0;
                        if (bit_index_q == final_bit_index) begin
                            busy_q <= 1'b0;
                            done_q <= 1'b1;
                            completed_length_q <= length_q;
                        end else begin
                            bit_index_q <= bit_index_q + 1'b1;
                        end
                    end
                end else begin
                    divider_count_q <= divider_count_q + 1'b1;
                end
            end else if (stream_clocking) begin
                if (divider_tick) begin
                    divider_count_q <= 0;
                    if (!spi_clk_q) begin
                        // Autonomous SD receive also uses SPI mode 0.
                        spi_clk_q <= 1'b1;
                        case (stream_state_q)
                            STREAM_TOKEN: begin
                                stream_token_shift_q <=
                                    received_token_byte;
                                if (stream_token_bit_q == 3'd7) begin
                                    stream_token_bit_q <= 3'd0;
                                    if (received_token_byte == 8'hfe) begin
                                        stream_state_q <= STREAM_DATA;
                                        stream_data_bit_q <= 12'd0;
                                        rx_shift_q <= 64'd0;
                                    end else if (received_token_byte !=
                                                 8'hff) begin
                                        stream_error_q <= 1'b1;
                                        stream_state_q <= STREAM_ABORT;
                                    end
                                end else begin
                                    stream_token_bit_q <=
                                        stream_token_bit_q + 1'b1;
                                end
                            end
                            STREAM_DATA: begin
                                rx_shift_q <= received_shift_word;
                                if ((stream_data_bit_q[2:0] == 3'd7) &&
                                    (stream_crc_bytes_remaining_q != 32'd0)) begin
                                    stream_crc32_q <= crc32_update_byte(
                                        stream_crc32_q,
                                        received_shift_word[7:0]);
                                    stream_crc_bytes_remaining_q <=
                                        stream_crc_bytes_remaining_q - 1'b1;
                                end
                                if (stream_data_bit_q == 12'd4095) begin
                                    stream_state_q <= STREAM_CRC;
                                    stream_crc_bit_q <= 4'd0;
                                end else begin
                                    stream_data_bit_q <=
                                        stream_data_bit_q + 1'b1;
                                end
                            end
                            STREAM_CRC: begin
                                if (stream_crc_bit_q == 4'd15)
                                    stream_state_q <= STREAM_COMPLETE;
                                else
                                    stream_crc_bit_q <=
                                        stream_crc_bit_q + 1'b1;
                            end
                            default: begin end
                        endcase
                    end else begin
                        spi_clk_q <= 1'b0;
                        if (stream_state_q == STREAM_COMPLETE) begin
                            stream_ready_q[stream_fill_bank_q] <= 1'b1;
                            stream_remaining_q <=
                                stream_remaining_q - 1'b1;
                            if (stream_remaining_q == 32'd1) begin
                                stream_active_q <= 1'b0;
                                if (stream_crc_bytes_remaining_q != 32'd0)
                                    stream_error_q <= 1'b1;
                            end else begin
                                stream_fill_bank_q <=
                                    !stream_fill_bank_q;
                                stream_token_bit_q <= 3'd0;
                                stream_token_shift_q <= 8'hff;
                                if (!stream_ready_q[!stream_fill_bank_q] ||
                                    (stream_release_write &&
                                     mem_wdata_i[!stream_fill_bank_q]))
                                    stream_state_q <= STREAM_TOKEN;
                                else
                                    stream_state_q <= STREAM_WAIT;
                            end
                        end else if (stream_state_q == STREAM_ABORT) begin
                            stream_active_q <= 1'b0;
                        end
                    end
                end else begin
                    divider_count_q <= divider_count_q + 1'b1;
                end
            end else begin
                spi_clk_q <= 1'b0;
                divider_count_q <= 0;
            end
        end
    end

endmodule
