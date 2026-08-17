`timescale 1ns/1ps

// Minimal blocking SPI-mode controller for ROM-driven SD-card boot.
//
// Software owns chip select and the SD command protocol.  Transfers may be
// one to 512 bytes.  The first sixteen received bytes are mirrored in scalar
// registers for command responses, while every complete transfer is captured
// in a 512-byte synchronous read buffer for sector copies.
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
    localparam [63:0] BUFFER_BASE    = 64'h100;
    localparam [63:0] BUFFER_LIMIT   = 64'h300;

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

    // One 512-byte sector.  The SPI engine writes complete 64-bit words;
    // target-bus reads use the independent synchronous port below.
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [63:0] buffer_q [0:63];
    reg [63:0] buffer_read_data_q;
    reg buffer_read_response_q;
    reg buffer_read_recover_q;

    wire buffer_selected =
        (mem_addr_i >= BUFFER_BASE) && (mem_addr_i < BUFFER_LIMIT);
    wire [5:0] buffer_read_index =
        (mem_addr_i - BUFFER_BASE) >> 3;
    wire buffer_read_request =
        mem_valid_i && !mem_write_i && buffer_selected;
    wire write_accept = mem_valid_i && mem_write_i;
    wire status_clear = write_accept && mem_wstrb_i[0] &&
        (mem_addr_i[63:3] == (STATUS_OFFSET >> 3));
    wire start_write = write_accept && mem_wstrb_i[1:0] != 2'b00 &&
        (mem_addr_i[63:3] == (XFER_OFFSET >> 3));
    wire [9:0] requested_length = mem_wdata_i[9:0];
    wire requested_length_valid =
        (requested_length >= 10'd1) && (requested_length <= 10'd512);

    wire [DIVIDER_WIDTH-1:0] selected_half_period = fast_clock_q ?
        FAST_HALF_PERIOD : INIT_HALF_PERIOD;
    wire divider_tick = busy_q &&
        (divider_count_q == (selected_half_period - 1'b1));
    wire [6:0] command_buffer_bit =
        {bit_index_q[6:3], ~bit_index_q[2:0]};
    wire transmit_bit = (bit_index_q < 12'd128) ?
        tx_q[command_buffer_bit] : 1'b1;
    wire [12:0] transfer_bit_count = {length_q, 3'b000};
    wire [11:0] final_bit_index = transfer_bit_count[11:0] - 1'b1;
    wire [63:0] received_shift_word = {rx_shift_q[62:0], spi_miso_i};

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
                buffer_read_data_q : 64'd0;
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
                default: mem_rdata_o = 64'd0;
            endcase
        end
    end

    // Keep the array read in canonical synchronous-memory form so synthesis
    // can merge this register into the block-memory read port.
    always @(posedge clk_i) begin
        if (buffer_read_request && !buffer_read_response_q &&
            !buffer_read_recover_q)
            buffer_read_data_q <= buffer_q[buffer_read_index];
    end

    // Independent SPI-side write port.  A full 64-bit word is committed after
    // every eight received bytes; partial command responses use RX_LO/RX_HI.
    always @(posedge clk_i) begin
        if (busy_q && divider_tick && !spi_clk_q &&
            (bit_index_q[5:0] == 6'd63))
            buffer_q[bit_index_q[11:6]] <=
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
        end else begin
            card_present_sync_1_q <= card_present_i;
            card_present_sync_2_q <= card_present_sync_1_q;

            if (status_clear) begin
                if (mem_wdata_i[1])
                    done_q <= 1'b0;
                if (mem_wdata_i[24])
                    error_q <= 1'b0;
            end

            if (write_accept && !busy_q) begin
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
                if (busy_q || !requested_length_valid) begin
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
            end else begin
                spi_clk_q <= 1'b0;
                divider_count_q <= 0;
            end
        end
    end

endmodule
