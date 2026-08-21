`timescale 1ns/1ps

// Basic NS16550-compatible UART.
//
// The programming model is the standard eight-byte 16550 register bank.  It
// is presented as one aligned word on the OpenRV64 64-bit blocking bus. The
// SoC decoder presents a target-local offset; byte stores use the corresponding
// mem_wdata_i/mem_wstrb_i lane and mem_addr_i[2:0] selects read side effects.
module openrv64_uart16550 #(
    // REFERENCE_CLOCK_HZ is the frequency exposed to software for divisor
    // calculation.  When it differs from INPUT_CLOCK_HZ, a fractional
    // prescaler advances the ordinary 16550 divider by zero, one, or two
    // reference-clock ticks per input-clock cycle.  Zero keeps the original
    // one-tick-per-cycle behavior.
    parameter integer INPUT_CLOCK_HZ = 0,
    parameter integer REFERENCE_CLOCK_HZ = 0
) (
    input  wire         clk_i,
    input  wire         rst_ni,

    input  wire         rx_i,
    output wire         tx_o,

    // Modem signals use the polarity of the original 16550 pins.  Tie the
    // active-low inputs high when modem control is not used.
    input  wire         cts_ni,
    input  wire         dsr_ni,
    input  wire         ri_ni,
    input  wire         dcd_ni,
    output wire         dtr_no,
    output wire         rts_no,
    output wire         out1_no,
    output wire         out2_no,

    input  wire         mem_valid_i,
    output wire         mem_ready_o,
    input  wire         mem_write_i,
    input  wire [63:0]  mem_addr_i,
    input  wire [63:0]  mem_wdata_i,
    input  wire [7:0]   mem_wstrb_i,
    output wire [63:0]  mem_rdata_o,

    // The 16550 has one prioritized interrupt output.  Connect this
    // active-high signal to one PLIC source input.
    output wire         irq_o
);

    localparam [2:0] TX_IDLE   = 3'd0;
    localparam [2:0] TX_START  = 3'd1;
    localparam [2:0] TX_DATA   = 3'd2;
    localparam [2:0] TX_PARITY = 3'd3;
    localparam [2:0] TX_STOP   = 3'd4;

    localparam [2:0] RX_IDLE      = 3'd0;
    localparam [2:0] RX_START     = 3'd1;
    localparam [2:0] RX_DATA      = 3'd2;
    localparam [2:0] RX_PARITY    = 3'd3;
    localparam [2:0] RX_STOP      = 3'd4;
    localparam [2:0] RX_WAIT_MARK = 3'd5;

    reg [7:0] ier_q;
    reg [7:0] lcr_q;
    reg [7:0] mcr_q;
    reg [7:0] scr_q;
    reg [7:0] dll_q;
    reg [7:0] dlm_q;

    reg       fifo_enable_q;
    reg       fifo_dma_q;
    reg [1:0] fifo_trigger_q;

    reg [7:0] tx_fifo_q [0:15];
    reg [3:0] tx_read_pointer_q;
    reg [3:0] tx_write_pointer_q;
    reg [4:0] tx_count_q;

    reg [7:0] rx_fifo_q [0:15];
    // One parity, framing, and break flag accompanies each received byte.
    reg [2:0] rx_error_fifo_q [0:15];
    reg [3:0] rx_read_pointer_q;
    reg [3:0] rx_write_pointer_q;
    reg [4:0] rx_count_q;
    reg       rx_overrun_q;

    reg [15:0] baud_counter_q;
    reg [31:0] baud_reference_phase_q;

    reg [2:0] tx_state_q;
    reg [3:0] tx_phase_count_q;
    reg [2:0] tx_data_index_q;
    reg [7:0] tx_shift_q;
    reg [3:0] tx_word_bits_q;
    reg       tx_parity_enable_q;
    reg       tx_parity_bit_q;
    reg [5:0] tx_stop_total_q;
    reg [5:0] tx_stop_remaining_q;
    reg       tx_serial_q;

    reg [2:0] rx_state_q;
    reg [3:0] rx_phase_count_q;
    reg [2:0] rx_data_index_q;
    reg [7:0] rx_shift_q;
    reg [3:0] rx_word_bits_q;
    reg       rx_parity_enable_q;
    reg       rx_even_parity_q;
    reg       rx_stick_parity_q;
    reg       rx_parity_xor_q;
    reg       rx_parity_error_q;
    reg       rx_framing_error_q;
    reg       rx_break_q;
    reg [1:0] rx_mark_count_q;

    reg       thre_interrupt_q;
    reg [9:0] rx_timeout_counter_q;
    reg       rx_timeout_q;

    reg rx_sync_1_q;
    reg rx_sync_2_q;
    reg cts_sync_1_q;
    reg cts_sync_2_q;
    reg dsr_sync_1_q;
    reg dsr_sync_2_q;
    reg ri_sync_1_q;
    reg ri_sync_2_q;
    reg dcd_sync_1_q;
    reg dcd_sync_2_q;

    // {DCD, RI, DSR, CTS}; a set bit means that the active-low pin is
    // asserted.  The low nibble holds the corresponding MSR change flags.
    reg [3:0] modem_status_previous_q;
    reg [3:0] modem_delta_q;

    integer tx_fifo_index;
    integer rx_fifo_index;
    integer error_index;

    function [3:0] word_bits;
        input [1:0] word_length_select;
        begin
            case (word_length_select)
                2'b00: word_bits = 4'd5;
                2'b01: word_bits = 4'd6;
                2'b10: word_bits = 4'd7;
                default: word_bits = 4'd8;
            endcase
        end
    endfunction

    function data_parity;
        input [7:0] data;
        input [3:0] data_bits;
        input       even_parity;
        input       stick_parity;
        reg         data_xor;
        begin
            case (data_bits)
                4'd5: data_xor = ^data[4:0];
                4'd6: data_xor = ^data[5:0];
                4'd7: data_xor = ^data[6:0];
                default: data_xor = ^data[7:0];
            endcase

            // With stick parity, EPS selects a permanently-low parity bit;
            // otherwise EPS selects even rather than odd parity.
            if (stick_parity) begin
                data_parity = ~even_parity;
            end else if (even_parity) begin
                data_parity = data_xor;
            end else begin
                data_parity = ~data_xor;
            end
        end
    endfunction

    function [5:0] stop_ticks;
        input [3:0] data_bits;
        input       two_stop_bits;
        begin
            if (!two_stop_bits) begin
                stop_ticks = 6'd16;
            end else if (data_bits == 4'd5) begin
                stop_ticks = 6'd24;
            end else begin
                stop_ticks = 6'd32;
            end
        end
    endfunction

    function [9:0] timeout_ticks;
        input [3:0] data_bits;
        input       parity_enable;
        input       two_stop_bits;
        reg [7:0]   character_ticks;
        begin
            // Four complete character times, measured using the internal
            // 16x baud clock.  A five-bit word with STB set has 1.5 stops.
            character_ticks = 8'd16 + (data_bits * 8'd16);
            if (parity_enable) begin
                character_ticks = character_ticks + 8'd16;
            end
            character_ticks = character_ticks +
                              stop_ticks(data_bits, two_stop_bits);
            timeout_ticks = character_ticks * 4;
        end
    endfunction

    wire register_word_selected = (mem_addr_i[63:3] == 61'd0);
    wire read_accept = mem_valid_i && !mem_write_i &&
                       register_word_selected;
    wire write_accept = mem_valid_i && mem_write_i &&
                        register_word_selected;

    wire write_thr = write_accept && mem_wstrb_i[0] && !lcr_q[7];
    wire write_dll = write_accept && mem_wstrb_i[0] && lcr_q[7];
    wire write_ier = write_accept && mem_wstrb_i[1] && !lcr_q[7];
    wire write_dlm = write_accept && mem_wstrb_i[1] && lcr_q[7];
    wire write_fcr = write_accept && mem_wstrb_i[2];
    wire write_lcr = write_accept && mem_wstrb_i[3];
    wire write_mcr = write_accept && mem_wstrb_i[4];
    wire write_scr = write_accept && mem_wstrb_i[7];

    wire read_rbr = read_accept && (mem_addr_i[2:0] == 3'd0) &&
                    !lcr_q[7];
    wire read_iir = read_accept && (mem_addr_i[2:0] == 3'd2);
    wire read_lsr = read_accept && (mem_addr_i[2:0] == 3'd5);
    wire read_msr = read_accept && (mem_addr_i[2:0] == 3'd6);

    wire [7:0] thr_write_data = mem_wdata_i[7:0];
    wire [7:0] ier_write_data = mem_wdata_i[15:8];
    wire [7:0] fcr_write_data = mem_wdata_i[23:16];
    wire [7:0] mcr_write_data = mem_wdata_i[39:32];

    wire fifo_mode_change = write_fcr &&
                            (fcr_write_data[0] != fifo_enable_q);
    wire rx_fifo_reset = write_fcr &&
                         (fifo_mode_change ||
                          (fcr_write_data[0] && fcr_write_data[1]));
    wire tx_fifo_reset = write_fcr &&
                         (fifo_mode_change ||
                          (fcr_write_data[0] && fcr_write_data[2]));

    wire [4:0] fifo_capacity = fifo_enable_q ? 5'd16 : 5'd1;
    reg  [4:0] receive_trigger_level;

    always @* begin
        if (!fifo_enable_q) begin
            receive_trigger_level = 5'd1;
        end else begin
            case (fifo_trigger_q)
                2'b00: receive_trigger_level = 5'd1;
                2'b01: receive_trigger_level = 5'd4;
                2'b10: receive_trigger_level = 5'd8;
                default: receive_trigger_level = 5'd14;
            endcase
        end
    end

    wire [15:0] baud_divisor = {dlm_q, dll_q};

    localparam FRACTIONAL_BAUD_REFERENCE =
        (INPUT_CLOCK_HZ > 0) && (REFERENCE_CLOCK_HZ > 0) &&
        (INPUT_CLOCK_HZ != REFERENCE_CLOCK_HZ);
    localparam [32:0] INPUT_CLOCK_HZ_EXT = INPUT_CLOCK_HZ;
    localparam [32:0] REFERENCE_CLOCK_HZ_EXT = REFERENCE_CLOCK_HZ;

    wire [32:0] baud_reference_sum =
        {1'b0, baud_reference_phase_q} + REFERENCE_CLOCK_HZ_EXT;
    wire [1:0] baud_counter_advance = !FRACTIONAL_BAUD_REFERENCE ? 2'd1 :
        ((baud_reference_sum >= (INPUT_CLOCK_HZ_EXT << 1)) ? 2'd2 :
         ((baud_reference_sum >= INPUT_CLOCK_HZ_EXT) ? 2'd1 : 2'd0));
    wire [31:0] baud_reference_phase_next =
        !FRACTIONAL_BAUD_REFERENCE ? 32'd0 :
        ((baud_reference_sum >= (INPUT_CLOCK_HZ_EXT << 1)) ?
            (baud_reference_sum - (INPUT_CLOCK_HZ_EXT << 1)) :
         ((baud_reference_sum >= INPUT_CLOCK_HZ_EXT) ?
            (baud_reference_sum - INPUT_CLOCK_HZ_EXT) :
            baud_reference_sum[31:0]));

    wire [16:0] baud_counter_sum = {1'b0, baud_counter_q} +
                                    baud_counter_advance;
    wire baud16_tick = (baud_divisor != 16'd0) &&
                       (baud_counter_advance != 2'd0) &&
                       (baud_counter_sum >= {1'b0, baud_divisor}) &&
                       !write_dll && !write_dlm;

    // Internal and physical serial paths differ in diagnostic loopback mode:
    // the external transmitter stays marking while the internal stream feeds
    // the receiver.
    wire tx_internal = lcr_q[6] ? 1'b0 : tx_serial_q;
    wire rx_serial = mcr_q[4] ? tx_internal : rx_sync_2_q;
    assign tx_o = mcr_q[4] ? 1'b1 : tx_internal;

    wire [3:0] modem_status_now = mcr_q[4]
        ? {mcr_q[3], mcr_q[2], mcr_q[0], mcr_q[1]}
        : {~dcd_sync_2_q, ~ri_sync_2_q,
           ~dsr_sync_2_q, ~cts_sync_2_q};

    wire auto_rts_asserted = mcr_q[5] && mcr_q[1] &&
                             fifo_enable_q &&
                             (rx_count_q < receive_trigger_level);
    assign dtr_no  = mcr_q[4] ? 1'b1 : ~mcr_q[0];
    assign rts_no  = mcr_q[4] ? 1'b1 :
                     (mcr_q[5] && fifo_enable_q
                        ? ~auto_rts_asserted : ~mcr_q[1]);
    assign out1_no = mcr_q[4] ? 1'b1 : ~mcr_q[2];
    assign out2_no = mcr_q[4] ? 1'b1 : ~mcr_q[3];

    wire tx_start_allowed = !mcr_q[5] || modem_status_now[0];
    wire tx_last_stop_tick = (tx_state_q == TX_STOP) &&
                             (tx_stop_remaining_q == 6'd1);
    wire tx_pop = baud16_tick && (tx_count_q != 5'd0) &&
                  tx_start_allowed &&
                  ((tx_state_q == TX_IDLE) || tx_last_stop_tick);
    wire tx_push = write_thr &&
                   ((tx_count_q < fifo_capacity) || tx_pop);

    wire rx_pop = read_rbr && (rx_count_q != 5'd0);
    wire rx_complete = baud16_tick && (rx_state_q == RX_STOP) &&
                       (rx_phase_count_q == 4'd15);
    // In character mode, a newly completed character overwrites an unread
    // RBR and sets OE.  In FIFO mode, a seventeenth character is discarded.
    wire rx_replace = rx_complete && !fifo_enable_q &&
                      (rx_count_q == 5'd1) && !rx_pop;
    wire rx_push = rx_complete &&
                   ((rx_count_q < fifo_capacity) || rx_pop);
    wire rx_overrun = rx_complete && !rx_push;
    wire [2:0] rx_complete_error =
        {rx_break_q, rx_framing_error_q, rx_parity_error_q};

    wire [2:0] rx_head_error = (rx_count_q != 5'd0)
        ? rx_error_fifo_q[rx_read_pointer_q] : 3'b000;
    reg rx_fifo_error_any;
    always @* begin
        rx_fifo_error_any = 1'b0;
        for (error_index = 0; error_index < 16;
             error_index = error_index + 1) begin
            rx_fifo_error_any = rx_fifo_error_any |
                                (|rx_error_fifo_q[error_index]);
        end
    end

    wire transmitter_holding_empty = (tx_count_q == 5'd0);
    wire transmitter_empty = transmitter_holding_empty &&
                             (tx_state_q == TX_IDLE);
    wire [7:0] lsr_value = {
        fifo_enable_q && rx_fifo_error_any,
        transmitter_empty,
        transmitter_holding_empty,
        rx_head_error[2],
        rx_head_error[1],
        rx_head_error[0],
        rx_overrun_q,
        (rx_count_q != 5'd0)
    };
    wire [7:0] msr_value = {modem_status_now, modem_delta_q};

    wire line_status_interrupt = ier_q[2] &&
                                 (rx_overrun_q || (|rx_head_error));
    wire received_data_interrupt = ier_q[0] &&
        (fifo_enable_q
            ? (rx_count_q >= receive_trigger_level)
            : (rx_count_q != 5'd0));
    wire receive_timeout_interrupt = ier_q[0] && fifo_enable_q &&
                                     rx_timeout_q;
    wire transmitter_empty_interrupt = ier_q[1] && thre_interrupt_q;
    wire modem_status_interrupt = ier_q[3] && (|modem_delta_q);

    reg [7:0] iir_value;
    always @* begin
        iir_value = fifo_enable_q ? 8'hc1 : 8'h01;
        if (line_status_interrupt) begin
            iir_value = (fifo_enable_q ? 8'hc0 : 8'h00) | 8'h06;
        end else if (received_data_interrupt) begin
            iir_value = (fifo_enable_q ? 8'hc0 : 8'h00) | 8'h04;
        end else if (receive_timeout_interrupt) begin
            iir_value = (fifo_enable_q ? 8'hc0 : 8'h00) | 8'h0c;
        end else if (transmitter_empty_interrupt) begin
            iir_value = (fifo_enable_q ? 8'hc0 : 8'h00) | 8'h02;
        end else if (modem_status_interrupt) begin
            iir_value = fifo_enable_q ? 8'hc0 : 8'h00;
        end
    end

    assign irq_o = !iir_value[0];
    assign mem_ready_o = mem_valid_i;
    wire [63:0] register_read_data = {
        scr_q,
        msr_value,
        lsr_value,
        mcr_q,
        lcr_q,
        iir_value,
        lcr_q[7] ? dlm_q : ier_q,
        lcr_q[7] ? dll_q :
            ((rx_count_q != 5'd0)
                ? rx_fifo_q[rx_read_pointer_q] : 8'h00)
    };
    assign mem_rdata_o = register_word_selected ? register_read_data : 64'h0;

    // Programmer-visible control registers.
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            ier_q <= 8'h00;
            lcr_q <= 8'h00;
            mcr_q <= 8'h00;
            scr_q <= 8'h00;
            dll_q <= 8'h00;
            dlm_q <= 8'h00;
            fifo_enable_q <= 1'b0;
            fifo_dma_q <= 1'b0;
            fifo_trigger_q <= 2'b00;
        end else begin
            if (write_ier) begin
                ier_q <= {4'b0000, ier_write_data[3:0]};
            end
            if (write_lcr) begin
                lcr_q <= mem_wdata_i[31:24];
            end
            if (write_mcr) begin
                mcr_q <= {2'b00, mcr_write_data[5:0]};
            end
            if (write_scr) begin
                scr_q <= mem_wdata_i[63:56];
            end
            if (write_dll) begin
                dll_q <= mem_wdata_i[7:0];
            end
            if (write_dlm) begin
                dlm_q <= mem_wdata_i[15:8];
            end
            if (write_fcr) begin
                fifo_enable_q <= fcr_write_data[0];
                if (fcr_write_data[0]) begin
                    fifo_dma_q <= fcr_write_data[3];
                    fifo_trigger_q <= fcr_write_data[7:6];
                end else begin
                    fifo_dma_q <= 1'b0;
                    fifo_trigger_q <= 2'b00;
                end
            end
        end
    end

    // Loading either divisor latch restarts the 16x baud divider.  A divisor
    // of zero stops both serial engines until software programs a valid rate.
    // Preserve fractional overshoot so the average reference frequency is
    // exact even when two reference ticks land in one input-clock cycle.
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            baud_counter_q <= 16'd0;
            baud_reference_phase_q <= 32'd0;
        end else if (write_dll || write_dlm || (baud_divisor == 16'd0)) begin
            baud_counter_q <= 16'd0;
            baud_reference_phase_q <= 32'd0;
        end else if (baud16_tick) begin
            baud_counter_q <= baud_counter_sum - baud_divisor;
            baud_reference_phase_q <= baud_reference_phase_next;
        end else begin
            baud_counter_q <= baud_counter_sum[15:0];
            baud_reference_phase_q <= baud_reference_phase_next;
        end
    end

    // Transmit FIFO.  Character mode uses the same storage with a capacity
    // of one byte, matching the visible 16550 behavior without duplicating
    // holding-register logic.
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            tx_read_pointer_q <= 4'd0;
            tx_write_pointer_q <= 4'd0;
            tx_count_q <= 5'd0;
            for (tx_fifo_index = 0; tx_fifo_index < 16;
                 tx_fifo_index = tx_fifo_index + 1) begin
                tx_fifo_q[tx_fifo_index] <= 8'h00;
            end
        end else if (tx_fifo_reset) begin
            tx_read_pointer_q <= 4'd0;
            tx_write_pointer_q <= 4'd0;
            tx_count_q <= 5'd0;
        end else begin
            case ({tx_push, tx_pop})
                2'b10: tx_count_q <= tx_count_q + 5'd1;
                2'b01: tx_count_q <= tx_count_q - 5'd1;
                default: tx_count_q <= tx_count_q;
            endcase

            if (tx_push) begin
                tx_fifo_q[tx_write_pointer_q] <= thr_write_data;
                tx_write_pointer_q <= tx_write_pointer_q + 4'd1;
            end
            if (tx_pop) begin
                tx_read_pointer_q <= tx_read_pointer_q + 4'd1;
            end
        end
    end

    // The THRE interrupt is edge-latched so reading IIR can clear it while
    // THRE itself remains set.  A new empty transition or enabling ETBEI on
    // an already-empty transmitter raises it again.
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            thre_interrupt_q <= 1'b1;
        end else if (tx_fifo_reset) begin
            thre_interrupt_q <= 1'b1;
        end else begin
            if (tx_push ||
                (read_iir && (iir_value[3:0] == 4'h2))) begin
                thre_interrupt_q <= 1'b0;
            end
            if ((write_ier && ier_write_data[1] && !ier_q[1] &&
                 (tx_count_q == 5'd0)) ||
                (tx_pop && !tx_push && (tx_count_q == 5'd1))) begin
                thre_interrupt_q <= 1'b1;
            end
        end
    end

    // Transmit serializer.  The format is captured at the start of each
    // character so a software LCR update cannot corrupt an in-flight byte.
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            tx_state_q <= TX_IDLE;
            tx_phase_count_q <= 4'd0;
            tx_data_index_q <= 3'd0;
            tx_shift_q <= 8'h00;
            tx_word_bits_q <= 4'd5;
            tx_parity_enable_q <= 1'b0;
            tx_parity_bit_q <= 1'b0;
            tx_stop_total_q <= 6'd16;
            tx_stop_remaining_q <= 6'd0;
            tx_serial_q <= 1'b1;
        end else if (baud16_tick) begin
            case (tx_state_q)
                TX_IDLE: begin
                    tx_serial_q <= 1'b1;
                    if (tx_pop) begin
                        tx_shift_q <= tx_fifo_q[tx_read_pointer_q];
                        tx_word_bits_q <= word_bits(lcr_q[1:0]);
                        tx_parity_enable_q <= lcr_q[3];
                        tx_parity_bit_q <= data_parity(
                            tx_fifo_q[tx_read_pointer_q],
                            word_bits(lcr_q[1:0]), lcr_q[4], lcr_q[5]);
                        tx_stop_total_q <= stop_ticks(
                            word_bits(lcr_q[1:0]), lcr_q[2]);
                        tx_data_index_q <= 3'd0;
                        tx_phase_count_q <= 4'd0;
                        tx_serial_q <= 1'b0;
                        tx_state_q <= TX_START;
                    end
                end

                TX_START: begin
                    if (tx_phase_count_q == 4'd15) begin
                        tx_phase_count_q <= 4'd0;
                        tx_data_index_q <= 3'd0;
                        tx_serial_q <= tx_shift_q[0];
                        tx_state_q <= TX_DATA;
                    end else begin
                        tx_phase_count_q <= tx_phase_count_q + 4'd1;
                    end
                end

                TX_DATA: begin
                    if (tx_phase_count_q == 4'd15) begin
                        tx_phase_count_q <= 4'd0;
                        if (tx_data_index_q == (tx_word_bits_q - 4'd1)) begin
                            if (tx_parity_enable_q) begin
                                tx_serial_q <= tx_parity_bit_q;
                                tx_state_q <= TX_PARITY;
                            end else begin
                                tx_serial_q <= 1'b1;
                                tx_stop_remaining_q <= tx_stop_total_q;
                                tx_state_q <= TX_STOP;
                            end
                        end else begin
                            tx_data_index_q <= tx_data_index_q + 3'd1;
                            tx_serial_q <= tx_shift_q[tx_data_index_q + 3'd1];
                        end
                    end else begin
                        tx_phase_count_q <= tx_phase_count_q + 4'd1;
                    end
                end

                TX_PARITY: begin
                    if (tx_phase_count_q == 4'd15) begin
                        tx_phase_count_q <= 4'd0;
                        tx_serial_q <= 1'b1;
                        tx_stop_remaining_q <= tx_stop_total_q;
                        tx_state_q <= TX_STOP;
                    end else begin
                        tx_phase_count_q <= tx_phase_count_q + 4'd1;
                    end
                end

                TX_STOP: begin
                    tx_serial_q <= 1'b1;
                    if (tx_stop_remaining_q > 6'd1) begin
                        tx_stop_remaining_q <= tx_stop_remaining_q - 6'd1;
                    end else if (tx_pop) begin
                        tx_shift_q <= tx_fifo_q[tx_read_pointer_q];
                        tx_word_bits_q <= word_bits(lcr_q[1:0]);
                        tx_parity_enable_q <= lcr_q[3];
                        tx_parity_bit_q <= data_parity(
                            tx_fifo_q[tx_read_pointer_q],
                            word_bits(lcr_q[1:0]), lcr_q[4], lcr_q[5]);
                        tx_stop_total_q <= stop_ticks(
                            word_bits(lcr_q[1:0]), lcr_q[2]);
                        tx_data_index_q <= 3'd0;
                        tx_phase_count_q <= 4'd0;
                        tx_serial_q <= 1'b0;
                        tx_state_q <= TX_START;
                    end else begin
                        tx_state_q <= TX_IDLE;
                    end
                end

                default: begin
                    tx_state_q <= TX_IDLE;
                    tx_serial_q <= 1'b1;
                end
            endcase
        end
    end

    // Synchronize asynchronous serial and modem inputs.
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rx_sync_1_q <= 1'b1;
            rx_sync_2_q <= 1'b1;
            cts_sync_1_q <= 1'b1;
            cts_sync_2_q <= 1'b1;
            dsr_sync_1_q <= 1'b1;
            dsr_sync_2_q <= 1'b1;
            ri_sync_1_q <= 1'b1;
            ri_sync_2_q <= 1'b1;
            dcd_sync_1_q <= 1'b1;
            dcd_sync_2_q <= 1'b1;
        end else begin
            rx_sync_1_q <= rx_i;
            rx_sync_2_q <= rx_sync_1_q;
            cts_sync_1_q <= cts_ni;
            cts_sync_2_q <= cts_sync_1_q;
            dsr_sync_1_q <= dsr_ni;
            dsr_sync_2_q <= dsr_sync_1_q;
            ri_sync_1_q <= ri_ni;
            ri_sync_2_q <= ri_sync_1_q;
            dcd_sync_1_q <= dcd_ni;
            dcd_sync_2_q <= dcd_sync_1_q;
        end
    end

    // Receiver oversamples at 16x and samples each field at its midpoint.
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rx_state_q <= RX_IDLE;
            rx_phase_count_q <= 4'd0;
            rx_data_index_q <= 3'd0;
            rx_shift_q <= 8'h00;
            rx_word_bits_q <= 4'd5;
            rx_parity_enable_q <= 1'b0;
            rx_even_parity_q <= 1'b0;
            rx_stick_parity_q <= 1'b0;
            rx_parity_xor_q <= 1'b0;
            rx_parity_error_q <= 1'b0;
            rx_framing_error_q <= 1'b0;
            rx_break_q <= 1'b0;
            rx_mark_count_q <= 2'd0;
        end else if (baud16_tick) begin
            case (rx_state_q)
                RX_IDLE: begin
                    if (!rx_serial) begin
                        rx_state_q <= RX_START;
                        rx_phase_count_q <= 4'd0;
                        rx_data_index_q <= 3'd0;
                        rx_shift_q <= 8'h00;
                        rx_word_bits_q <= word_bits(lcr_q[1:0]);
                        rx_parity_enable_q <= lcr_q[3];
                        rx_even_parity_q <= lcr_q[4];
                        rx_stick_parity_q <= lcr_q[5];
                        rx_parity_xor_q <= 1'b0;
                        rx_parity_error_q <= 1'b0;
                        rx_framing_error_q <= 1'b0;
                        rx_break_q <= 1'b0;
                    end
                end

                RX_START: begin
                    if ((rx_phase_count_q == 4'd7) && rx_serial) begin
                        // False start: the line returned high before the
                        // center of the candidate start bit.
                        rx_state_q <= RX_IDLE;
                    end else if (rx_phase_count_q == 4'd15) begin
                        rx_phase_count_q <= 4'd0;
                        rx_state_q <= RX_DATA;
                    end else begin
                        rx_phase_count_q <= rx_phase_count_q + 4'd1;
                    end
                end

                RX_DATA: begin
                    if (rx_phase_count_q == 4'd7) begin
                        rx_shift_q[rx_data_index_q] <= rx_serial;
                        rx_parity_xor_q <= rx_parity_xor_q ^ rx_serial;
                    end

                    if (rx_phase_count_q == 4'd15) begin
                        rx_phase_count_q <= 4'd0;
                        if (rx_data_index_q == (rx_word_bits_q - 4'd1)) begin
                            if (rx_parity_enable_q) begin
                                rx_state_q <= RX_PARITY;
                            end else begin
                                rx_state_q <= RX_STOP;
                            end
                        end else begin
                            rx_data_index_q <= rx_data_index_q + 3'd1;
                        end
                    end else begin
                        rx_phase_count_q <= rx_phase_count_q + 4'd1;
                    end
                end

                RX_PARITY: begin
                    if (rx_phase_count_q == 4'd7) begin
                        if (rx_stick_parity_q) begin
                            rx_parity_error_q <=
                                (rx_serial != ~rx_even_parity_q);
                        end else if (rx_even_parity_q) begin
                            rx_parity_error_q <=
                                (rx_serial != rx_parity_xor_q);
                        end else begin
                            rx_parity_error_q <=
                                (rx_serial != ~rx_parity_xor_q);
                        end
                    end

                    if (rx_phase_count_q == 4'd15) begin
                        rx_phase_count_q <= 4'd0;
                        rx_state_q <= RX_STOP;
                    end else begin
                        rx_phase_count_q <= rx_phase_count_q + 4'd1;
                    end
                end

                RX_STOP: begin
                    if (rx_phase_count_q == 4'd7) begin
                        rx_framing_error_q <= !rx_serial;
                        rx_break_q <= !rx_serial && (rx_shift_q == 8'h00);
                    end

                    if (rx_phase_count_q == 4'd15) begin
                        rx_phase_count_q <= 4'd0;
                        if (rx_break_q) begin
                            rx_mark_count_q <= 2'd0;
                            rx_state_q <= RX_WAIT_MARK;
                        end else if (!rx_framing_error_q && !rx_serial) begin
                            // A legal stop bit may be followed immediately by
                            // the next start bit.  Re-entering RX_IDLE here
                            // would defer detection by one 16x tick on every
                            // back-to-back character, accumulating enough
                            // phase error to sample the next stop as data.
                            rx_state_q <= RX_START;
                            rx_data_index_q <= 3'd0;
                            rx_shift_q <= 8'h00;
                            rx_word_bits_q <= word_bits(lcr_q[1:0]);
                            rx_parity_enable_q <= lcr_q[3];
                            rx_even_parity_q <= lcr_q[4];
                            rx_stick_parity_q <= lcr_q[5];
                            rx_parity_xor_q <= 1'b0;
                            rx_parity_error_q <= 1'b0;
                            rx_framing_error_q <= 1'b0;
                            rx_break_q <= 1'b0;
                        end else begin
                            rx_state_q <= RX_IDLE;
                        end
                    end else begin
                        rx_phase_count_q <= rx_phase_count_q + 4'd1;
                    end
                end

                RX_WAIT_MARK: begin
                    if (rx_serial) begin
                        if (rx_mark_count_q == 2'd1) begin
                            rx_mark_count_q <= 2'd0;
                            rx_state_q <= RX_IDLE;
                        end else begin
                            rx_mark_count_q <= rx_mark_count_q + 2'd1;
                        end
                    end else begin
                        rx_mark_count_q <= 2'd0;
                    end
                end

                default: rx_state_q <= RX_IDLE;
            endcase
        end
    end

    // Receive FIFO and per-character error storage.
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rx_read_pointer_q <= 4'd0;
            rx_write_pointer_q <= 4'd0;
            rx_count_q <= 5'd0;
            rx_overrun_q <= 1'b0;
            for (rx_fifo_index = 0; rx_fifo_index < 16;
                 rx_fifo_index = rx_fifo_index + 1) begin
                rx_fifo_q[rx_fifo_index] <= 8'h00;
                rx_error_fifo_q[rx_fifo_index] <= 3'b000;
            end
        end else if (rx_fifo_reset) begin
            rx_read_pointer_q <= 4'd0;
            rx_write_pointer_q <= 4'd0;
            rx_count_q <= 5'd0;
            rx_overrun_q <= 1'b0;
            for (rx_fifo_index = 0; rx_fifo_index < 16;
                 rx_fifo_index = rx_fifo_index + 1) begin
                rx_error_fifo_q[rx_fifo_index] <= 3'b000;
            end
        end else begin
            case ({rx_push, rx_pop})
                2'b10: rx_count_q <= rx_count_q + 5'd1;
                2'b01: rx_count_q <= rx_count_q - 5'd1;
                default: rx_count_q <= rx_count_q;
            endcase

            if (read_lsr) begin
                rx_overrun_q <= 1'b0;
                if (rx_count_q != 5'd0) begin
                    rx_error_fifo_q[rx_read_pointer_q] <= 3'b000;
                end
            end
            if (rx_overrun) begin
                rx_overrun_q <= 1'b1;
            end

            if (rx_pop) begin
                rx_error_fifo_q[rx_read_pointer_q] <= 3'b000;
                rx_read_pointer_q <= rx_read_pointer_q + 4'd1;
            end
            if (rx_replace) begin
                rx_fifo_q[rx_read_pointer_q] <= rx_shift_q;
                rx_error_fifo_q[rx_read_pointer_q] <= rx_complete_error;
            end
            if (rx_push) begin
                rx_fifo_q[rx_write_pointer_q] <= rx_shift_q;
                rx_error_fifo_q[rx_write_pointer_q] <= rx_complete_error;
                rx_write_pointer_q <= rx_write_pointer_q + 4'd1;
            end
        end
    end

    // FIFO timeout indication: at least one byte remains below the trigger
    // level and neither the serial receiver nor software has touched the FIFO
    // for four character times.
    wire [9:0] receive_timeout_ticks = timeout_ticks(
        word_bits(lcr_q[1:0]), lcr_q[3], lcr_q[2]);
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rx_timeout_counter_q <= 10'd0;
            rx_timeout_q <= 1'b0;
        end else if (rx_fifo_reset || rx_complete || rx_pop ||
                     !fifo_enable_q || (rx_count_q == 5'd0) ||
                     (rx_count_q >= receive_trigger_level)) begin
            rx_timeout_counter_q <= 10'd0;
            rx_timeout_q <= 1'b0;
        end else if (baud16_tick && !rx_timeout_q) begin
            if (rx_timeout_counter_q >= (receive_timeout_ticks - 10'd1)) begin
                rx_timeout_q <= 1'b1;
            end else begin
                rx_timeout_counter_q <= rx_timeout_counter_q + 10'd1;
            end
        end
    end

    // Modem state/change reporting, including the standard diagnostic
    // loopback mapping from MCR outputs into MSR inputs.
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            modem_status_previous_q <= 4'b0000;
            modem_delta_q <= 4'b0000;
        end else begin
            modem_status_previous_q <= modem_status_now;

            if (read_msr) begin
                modem_delta_q <= 4'b0000;
            end
            if ((modem_status_now[0] != modem_status_previous_q[0]) &&
                !mcr_q[5] && !(write_mcr && mcr_write_data[5])) begin
                modem_delta_q[0] <= 1'b1;
            end
            if (modem_status_now[1] != modem_status_previous_q[1]) begin
                modem_delta_q[1] <= 1'b1;
            end
            // TERI records only the trailing (asserted-to-deasserted) edge.
            if (modem_status_previous_q[2] && !modem_status_now[2]) begin
                modem_delta_q[2] <= 1'b1;
            end
            if (modem_status_now[3] != modem_status_previous_q[3]) begin
                modem_delta_q[3] <= 1'b1;
            end
            if (write_mcr && mcr_write_data[5]) begin
                modem_delta_q[0] <= 1'b0;
            end
        end
    end

    // fifo_dma_q intentionally has no external request pins: it is retained
    // so FCR programming is faithful, while this SoC-facing interface remains
    // a simple programmed-I/O/interrupt peripheral.
    wire unused_fifo_dma = fifo_dma_q;

endmodule
