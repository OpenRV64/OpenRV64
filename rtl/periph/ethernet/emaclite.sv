// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// Small, programmed-I/O Ethernet MAC with a Xilinx EmacLite-compatible
// software interface.  The compatibility aperture exposes the two standard
// 2-KiB TX/RX ping-pong windows.  Four private 8-KiB aliases retain the full
// packet RAM depth for diagnostics and a future queued driver:
//
//   0x2000..0x3fff  TX0   0x4000..0x5fff  TX1
//   0x6000..0x7fff  RX0   0x8000..0x9fff  RX1
//
// The four 8-KiB, 64-bit-wide, true-dual-port memories consume eight 36-Kb
// block-RAM tiles on Series-7.  The MAC is deliberately limited to 100 Mb/s;
// tx_clk_i must be 25 MHz.  PHY management is Clause 22 MDIO.

`timescale 1ns/1ps

module openrv64_emaclite #(
    parameter integer MDC_HALF_PERIOD_CYCLES = 2,
    parameter integer PHY_RESET_CYCLES = 100000
) (
    input  wire        clk_i,
    input  wire        rst_ni,

    input  wire        tx_clk_i,
    output reg  [7:0]  tx_data_o,
    output reg         tx_valid_o,
    output wire        tx_error_o,

    input  wire        rx_clk_i,
    input  wire [7:0]  rx_data_i,
    input  wire        rx_valid_i,
    input  wire        rx_error_i,

    output reg         mdc_o,
    output wire        mdio_o,
    output wire        mdio_oe_o,
    input  wire        mdio_i,
    output wire        phy_reset_no,

    output wire        irq_o,

    input  wire        mem_valid_i,
    output wire        mem_ready_o,
    input  wire        mem_write_i,
    input  wire [63:0] mem_addr_i,
    input  wire [63:0] mem_wdata_i,
    input  wire [7:0]  mem_wstrb_i,
    output reg  [63:0] mem_rdata_o
);

    localparam integer PACKET_BYTES = 8192;
    localparam integer PACKET_WORDS = PACKET_BYTES / 8;
    localparam integer PACKET_WORD_BITS = $clog2(PACKET_WORDS);
    localparam integer MAX_FRAME_BYTES = 1518;

    localparam [15:0] MDIOADDR_OFFSET = 16'h07e4;
    localparam [15:0] MDIOWR_OFFSET   = 16'h07e8;
    localparam [15:0] MDIORD_OFFSET   = 16'h07ec;
    localparam [15:0] MDIOCTRL_OFFSET = 16'h07f0;
    localparam [15:0] TPLR0_OFFSET    = 16'h07f4;
    localparam [15:0] GIER_OFFSET     = 16'h07f8;
    localparam [15:0] TSR0_OFFSET     = 16'h07fc;
    localparam [15:0] TPLR1_OFFSET    = 16'h0ff4;
    localparam [15:0] TSR1_OFFSET     = 16'h0ffc;
    localparam [15:0] RSR0_OFFSET     = 16'h17fc;
    localparam [15:0] RSR1_OFFSET     = 16'h1ffc;

    localparam [2:0] TX_IDLE     = 3'd0;
    localparam [2:0] TX_PREAMBLE = 3'd1;
    localparam [2:0] TX_DATA     = 3'd2;
    localparam [2:0] TX_PAD      = 3'd3;
    localparam [2:0] TX_FCS      = 3'd4;
    localparam [2:0] TX_END      = 3'd5;
    localparam [2:0] TX_IFG      = 3'd6;

    function automatic [63:0] merge_write_data;
        input [63:0] old_value;
        input [63:0] new_value;
        input [7:0] write_strobe;
        integer byte_index;
        begin
            merge_write_data = old_value;
            for (byte_index = 0; byte_index < 8;
                 byte_index = byte_index + 1)
                if (write_strobe[byte_index])
                    merge_write_data[8*byte_index +: 8] =
                        new_value[8*byte_index +: 8];
        end
    endfunction

    function automatic [31:0] crc32_byte;
        input [31:0] crc;
        input [7:0] data;
        reg [31:0] value;
        integer bit_index;
        begin
            value = crc;
            for (bit_index = 0; bit_index < 8;
                 bit_index = bit_index + 1) begin
                if (value[0] ^ data[bit_index])
                    value = (value >> 1) ^ 32'hedb8_8320;
                else
                    value = value >> 1;
            end
            crc32_byte = value;
        end
    endfunction

    function automatic [63:0] insert_byte;
        input [63:0] word_value;
        input [7:0] byte_value;
        input [2:0] byte_lane;
        reg [63:0] next_value;
        begin
            next_value = word_value;
            next_value[8*byte_lane +: 8] = byte_value;
            insert_byte = next_value;
        end
    endfunction

    function automatic [7:0] select_byte;
        input [63:0] word_value;
        input [2:0] byte_lane;
        begin
            select_byte = word_value[8*byte_lane +: 8];
        end
    endfunction

    initial begin
        if (MDC_HALF_PERIOD_CYCLES < 1)
            $fatal(1, "Ethernet MDC half-period must be positive");
        if (PHY_RESET_CYCLES < 1)
            $fatal(1, "Ethernet PHY reset interval must be positive");
    end

    reg        buffer_selected;
    reg [1:0]  buffer_bank;
    reg [PACKET_WORD_BITS-1:0] buffer_word_index;

    // Compatibility windows alias the low 2 KiB.  Exact register words take
    // precedence over the packet-memory aliases.
    always @* begin
        buffer_selected = 1'b0;
        buffer_bank = 2'd0;
        buffer_word_index = {PACKET_WORD_BITS{1'b0}};

        if ((mem_addr_i[15:0] < 16'h07e0)) begin
            buffer_selected = 1'b1;
            buffer_bank = 2'd0;
            buffer_word_index = mem_addr_i[12:3];
        end else if ((mem_addr_i[15:0] >= 16'h0800) &&
                     (mem_addr_i[15:0] < 16'h0ff0)) begin
            buffer_selected = 1'b1;
            buffer_bank = 2'd1;
            buffer_word_index = (mem_addr_i[15:0] - 16'h0800) >> 3;
        end else if ((mem_addr_i[15:0] >= 16'h1000) &&
                     (mem_addr_i[15:0] < 16'h17f8)) begin
            buffer_selected = 1'b1;
            buffer_bank = 2'd2;
            buffer_word_index = (mem_addr_i[15:0] - 16'h1000) >> 3;
        end else if ((mem_addr_i[15:0] >= 16'h1800) &&
                     (mem_addr_i[15:0] < 16'h1ff8)) begin
            buffer_selected = 1'b1;
            buffer_bank = 2'd3;
            buffer_word_index = (mem_addr_i[15:0] - 16'h1800) >> 3;
        end else if ((mem_addr_i[15:0] >= 16'h2000) &&
                     (mem_addr_i[15:0] < 16'h4000)) begin
            buffer_selected = 1'b1;
            buffer_bank = 2'd0;
            buffer_word_index = (mem_addr_i[15:0] - 16'h2000) >> 3;
        end else if ((mem_addr_i[15:0] >= 16'h4000) &&
                     (mem_addr_i[15:0] < 16'h6000)) begin
            buffer_selected = 1'b1;
            buffer_bank = 2'd1;
            buffer_word_index = (mem_addr_i[15:0] - 16'h4000) >> 3;
        end else if ((mem_addr_i[15:0] >= 16'h6000) &&
                     (mem_addr_i[15:0] < 16'h8000)) begin
            buffer_selected = 1'b1;
            buffer_bank = 2'd2;
            buffer_word_index = (mem_addr_i[15:0] - 16'h6000) >> 3;
        end else if ((mem_addr_i[15:0] >= 16'h8000) &&
                     (mem_addr_i[15:0] < 16'ha000)) begin
            buffer_selected = 1'b1;
            buffer_bank = 2'd3;
            buffer_word_index = (mem_addr_i[15:0] - 16'h8000) >> 3;
        end
    end

    wire buffer_read_request = mem_valid_i && !mem_write_i &&
        buffer_selected;
    wire buffer_write_accept = mem_valid_i && mem_write_i &&
        buffer_selected;
    reg buffer_read_response_q;
    reg buffer_read_recover_q;

    reg [63:0] tx0_mac_shadow_q;
    reg [63:0] tx1_mac_shadow_q;

    wire [63:0] tx0_cpu_read_data;
    wire [63:0] tx1_cpu_read_data;
    wire [63:0] rx0_cpu_read_data;
    wire [63:0] rx1_cpu_read_data;
    wire [63:0] tx0_mac_read_data;
    wire [63:0] tx1_mac_read_data;

    reg [12:0] tx_read_byte_addr_q;
    wire [PACKET_WORD_BITS-1:0] tx_read_word_address =
        tx_read_byte_addr_q[12:3];

    wire rx_memory_write;
    wire rx_memory_bank;
    wire [9:0] rx_memory_addr;
    wire [63:0] rx_memory_data;

    wire [7:0] cpu_ram_write_enable = buffer_write_accept ?
        mem_wstrb_i : 8'd0;

    openrv64_ethernet_packet_ram u_tx0_ram (
        .a_clk_i(clk_i),
        .a_enable_i(mem_valid_i && buffer_selected &&
                    (buffer_bank == 2'd0)),
        .a_write_enable_i(cpu_ram_write_enable),
        .a_addr_i(buffer_word_index),
        .a_wdata_i(mem_wdata_i),
        .a_rdata_o(tx0_cpu_read_data),
        .b_clk_i(tx_clk_i),
        .b_enable_i(1'b1),
        .b_write_enable_i(8'd0),
        .b_addr_i(tx_read_word_address),
        .b_wdata_i(64'd0),
        .b_rdata_o(tx0_mac_read_data)
    );

    openrv64_ethernet_packet_ram u_tx1_ram (
        .a_clk_i(clk_i),
        .a_enable_i(mem_valid_i && buffer_selected &&
                    (buffer_bank == 2'd1)),
        .a_write_enable_i(cpu_ram_write_enable),
        .a_addr_i(buffer_word_index),
        .a_wdata_i(mem_wdata_i),
        .a_rdata_o(tx1_cpu_read_data),
        .b_clk_i(tx_clk_i),
        .b_enable_i(1'b1),
        .b_write_enable_i(8'd0),
        .b_addr_i(tx_read_word_address),
        .b_wdata_i(64'd0),
        .b_rdata_o(tx1_mac_read_data)
    );

    openrv64_ethernet_packet_ram u_rx0_ram (
        .a_clk_i(clk_i),
        .a_enable_i(mem_valid_i && buffer_selected &&
                    (buffer_bank == 2'd2)),
        .a_write_enable_i(cpu_ram_write_enable),
        .a_addr_i(buffer_word_index),
        .a_wdata_i(mem_wdata_i),
        .a_rdata_o(rx0_cpu_read_data),
        .b_clk_i(rx_clk_i),
        .b_enable_i(rx_memory_write && !rx_memory_bank),
        .b_write_enable_i({8{rx_memory_write && !rx_memory_bank}}),
        .b_addr_i(rx_memory_addr),
        .b_wdata_i(rx_memory_data),
        .b_rdata_o()
    );

    openrv64_ethernet_packet_ram u_rx1_ram (
        .a_clk_i(clk_i),
        .a_enable_i(mem_valid_i && buffer_selected &&
                    (buffer_bank == 2'd3)),
        .a_write_enable_i(cpu_ram_write_enable),
        .a_addr_i(buffer_word_index),
        .a_wdata_i(mem_wdata_i),
        .a_rdata_o(rx1_cpu_read_data),
        .b_clk_i(rx_clk_i),
        .b_enable_i(rx_memory_write && rx_memory_bank),
        .b_write_enable_i({8{rx_memory_write && rx_memory_bank}}),
        .b_addr_i(rx_memory_addr),
        .b_wdata_i(rx_memory_data),
        .b_rdata_o()
    );

    reg [63:0] selected_buffer_read_data;
    always @* begin
        case (buffer_bank)
            2'd0: selected_buffer_read_data = tx0_cpu_read_data;
            2'd1: selected_buffer_read_data = tx1_cpu_read_data;
            2'd2: selected_buffer_read_data = rx0_cpu_read_data;
            default: selected_buffer_read_data = rx1_cpu_read_data;
        endcase
    end

    integer write_byte;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            tx0_mac_shadow_q <= 64'd0;
            tx1_mac_shadow_q <= 64'd0;
        end else if (buffer_write_accept &&
                     (buffer_word_index == 0)) begin
            for (write_byte = 0; write_byte < 8;
                 write_byte = write_byte + 1) begin
                if (mem_wstrb_i[write_byte]) begin
                    if (buffer_bank == 2'd0)
                        tx0_mac_shadow_q[8*write_byte +: 8] <=
                            mem_wdata_i[8*write_byte +: 8];
                    else if (buffer_bank == 2'd1)
                        tx1_mac_shadow_q[8*write_byte +: 8] <=
                            mem_wdata_i[8*write_byte +: 8];
                end
            end
        end
    end

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

    reg [15:0] tx_length_q [0:1];
    reg [1:0] tx_busy_q;
    reg [1:0] tx_active_q;
    reg [1:0] tx_ie_q;
    reg [1:0] tx_start_toggle_q;
    reg [47:0] mac_address_q;
    reg global_irq_enable_q;
    reg [1:0] rx_ie_q;
    reg [1:0] rx_clear_toggle_q;

    reg [10:0] mdio_address_q;
    reg [15:0] mdio_write_data_q;
    reg mdio_enable_q;
    reg mdio_start_q;
    reg [15:0] mdio_read_data_q;
    reg mdio_busy_q;

    (* ASYNC_REG = "TRUE" *) reg [1:0] tx_done_sync0_q;
    (* ASYNC_REG = "TRUE" *) reg [1:0] tx_done_sync1_q;
    reg [1:0] tx_done_seen_q;
    reg [1:0] tx_done_toggle_q;

    (* ASYNC_REG = "TRUE" *) reg [1:0] rx_done_sync0_q;
    (* ASYNC_REG = "TRUE" *) reg [1:0] rx_done_sync1_q;
    reg [1:0] rx_done_q;

    wire [31:0] tx_status0 = {
        tx_active_q[0], 27'd0, tx_ie_q[0], 2'd0, tx_busy_q[0]
    };
    wire [31:0] tx_status1 = {
        tx_active_q[1], 27'd0, tx_ie_q[1], 2'd0, tx_busy_q[1]
    };
    wire [31:0] rx_status0 = {28'd0, rx_ie_q[0], 2'd0,
                              rx_done_sync1_q[0]};
    wire [31:0] rx_status1 = {28'd0, rx_ie_q[1], 2'd0,
                              rx_done_sync1_q[1]};
    wire [31:0] mdio_control = {28'd0, mdio_enable_q, 2'd0,
                                mdio_busy_q};

    reg [63:0] register_read_data;
    always @* begin
        register_read_data = 64'd0;
        case (mem_addr_i[15:3])
            13'h00fc: register_read_data =
                {21'd0, mdio_address_q, 32'd0};
            13'h00fd: register_read_data =
                {16'd0, mdio_read_data_q, 16'd0, mdio_write_data_q};
            13'h00fe: register_read_data =
                {16'd0, tx_length_q[0], mdio_control};
            13'h00ff: register_read_data =
                {tx_status0, global_irq_enable_q, 31'd0};
            13'h01fe: register_read_data =
                {16'd0, tx_length_q[1], 32'd0};
            13'h01ff: register_read_data = {tx_status1, 32'd0};
            13'h02ff: register_read_data = {rx_status0, 32'd0};
            13'h03ff: register_read_data = {rx_status1, 32'd0};
            default: register_read_data = 64'd0;
        endcase
    end

    wire [63:0] merged_register_write = merge_write_data(
        register_read_data, mem_wdata_i, mem_wstrb_i);
    wire register_write_accept = mem_valid_i && mem_write_i &&
        !buffer_selected;

    // Register writes and completion synchronization are entirely in the
    // software clock domain.  The toggles are single-event mailboxes whose
    // payload (length or stable packet RAM) is held until completion.
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            tx_length_q[0] <= 16'd0;
            tx_length_q[1] <= 16'd0;
            tx_busy_q <= 2'b00;
            tx_active_q <= 2'b00;
            tx_ie_q <= 2'b00;
            tx_start_toggle_q <= 2'b00;
            tx_done_sync0_q <= 2'b00;
            tx_done_sync1_q <= 2'b00;
            tx_done_seen_q <= 2'b00;
            rx_done_sync0_q <= 2'b00;
            rx_done_sync1_q <= 2'b00;
            rx_ie_q <= 2'b00;
            rx_clear_toggle_q <= 2'b00;
            global_irq_enable_q <= 1'b0;
            mac_address_q <= 48'h02_00_00_00_00_01;
            mdio_address_q <= 11'd0;
            mdio_write_data_q <= 16'd0;
            mdio_enable_q <= 1'b0;
            mdio_start_q <= 1'b0;
        end else begin
            tx_done_sync0_q <= tx_done_toggle_q;
            tx_done_sync1_q <= tx_done_sync0_q;
            rx_done_sync0_q <= rx_done_q;
            rx_done_sync1_q <= rx_done_sync0_q;
            mdio_start_q <= 1'b0;

            if (tx_done_sync1_q != tx_done_seen_q) begin
                tx_busy_q <= tx_busy_q &
                    ~(tx_done_sync1_q ^ tx_done_seen_q);
                tx_done_seen_q <= tx_done_sync1_q;
            end

            if (register_write_accept) begin
                case (mem_addr_i[15:3])
                    13'h00fc:
                        mdio_address_q <= merged_register_write[42:32];
                    13'h00fd:
                        mdio_write_data_q <= merged_register_write[15:0];
                    13'h00fe: begin
                        mdio_enable_q <= merged_register_write[3];
                        tx_length_q[0] <= merged_register_write[47:32];
                        if (merged_register_write[0] &&
                            merged_register_write[3] && !mdio_busy_q)
                            mdio_start_q <= 1'b1;
                    end
                    13'h00ff: begin
                        global_irq_enable_q <= merged_register_write[31];
                        tx_ie_q[0] <= merged_register_write[35];
                        tx_active_q[0] <= merged_register_write[63];
                        if (merged_register_write[33] &&
                            merged_register_write[32]) begin
                            mac_address_q <= tx0_mac_shadow_q[47:0];
                            tx_busy_q[0] <= 1'b0;
                            tx_active_q[0] <= 1'b0;
                        end else if (merged_register_write[32] &&
                                     !tx_busy_q[0]) begin
                            tx_busy_q[0] <= 1'b1;
                            tx_start_toggle_q[0] <=
                                ~tx_start_toggle_q[0];
                        end
                    end
                    13'h01fe:
                        tx_length_q[1] <= merged_register_write[47:32];
                    13'h01ff: begin
                        tx_ie_q[1] <= merged_register_write[35];
                        tx_active_q[1] <= merged_register_write[63];
                        if (merged_register_write[33] &&
                            merged_register_write[32]) begin
                            mac_address_q <= tx1_mac_shadow_q[47:0];
                            tx_busy_q[1] <= 1'b0;
                            tx_active_q[1] <= 1'b0;
                        end else if (merged_register_write[32] &&
                                     !tx_busy_q[1]) begin
                            tx_busy_q[1] <= 1'b1;
                            tx_start_toggle_q[1] <=
                                ~tx_start_toggle_q[1];
                        end
                    end
                    13'h02ff: begin
                        rx_ie_q[0] <= merged_register_write[35];
                        if (!merged_register_write[32] &&
                            rx_done_sync1_q[0])
                            rx_clear_toggle_q[0] <=
                                ~rx_clear_toggle_q[0];
                    end
                    13'h03ff: begin
                        rx_ie_q[1] <= merged_register_write[35];
                        if (!merged_register_write[32] &&
                            rx_done_sync1_q[1])
                            rx_clear_toggle_q[1] <=
                                ~rx_clear_toggle_q[1];
                    end
                    default: begin end
                endcase
            end
        end
    end

    assign mem_ready_o = buffer_read_request ? buffer_read_response_q :
                         mem_valid_i;
    always @* begin
        if (buffer_selected)
            mem_rdata_o = buffer_read_response_q ?
                selected_buffer_read_data : 64'd0;
        else
            mem_rdata_o = register_read_data;
    end

    // Buffer-zero enables cover both ping-pong buffers, matching the Linux
    // EmacLite driver's interrupt programming sequence.
    wire tx_irq_pending = tx_ie_q[0] &&
        (|(tx_active_q & ~tx_busy_q));
    wire rx_irq_pending = rx_ie_q[0] && (|rx_done_sync1_q);
    assign irq_o = global_irq_enable_q &&
        (tx_irq_pending || rx_irq_pending);

    // PHY reset is long relative to the SoC reset sequencer and independent of
    // Linux.  The counter saturates, so the pin stays released thereafter.
    localparam integer PHY_RESET_COUNTER_BITS =
        (PHY_RESET_CYCLES <= 1) ? 1 : $clog2(PHY_RESET_CYCLES + 1);
    reg [PHY_RESET_COUNTER_BITS-1:0] phy_reset_count_q;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            phy_reset_count_q <= {PHY_RESET_COUNTER_BITS{1'b0}};
        else if (phy_reset_count_q < PHY_RESET_CYCLES)
            phy_reset_count_q <= phy_reset_count_q + 1'b1;
    end
    assign phy_reset_no = (phy_reset_count_q >= PHY_RESET_CYCLES);

    // Clause 22 MDIO controller.  Board integration must choose the divider
    // so MDC does not exceed 2.5 MHz; the 11-MHz FPGA build uses three core
    // cycles per half-period and therefore produces 1.833-MHz MDC.
    localparam integer MDC_DIVIDER_BITS =
        (MDC_HALF_PERIOD_CYCLES <= 1) ? 1 :
        $clog2(MDC_HALF_PERIOD_CYCLES);
    reg [MDC_DIVIDER_BITS-1:0] mdc_divider_q;
    reg [5:0] mdio_bit_index_q;
    reg [15:0] mdio_read_shift_q;

    wire mdio_read_operation = mdio_address_q[10];
    reg mdio_frame_bit;
    always @* begin
        if (mdio_bit_index_q < 6'd32)
            mdio_frame_bit = 1'b1;
        else begin
            case (mdio_bit_index_q)
                6'd32: mdio_frame_bit = 1'b0;
                6'd33: mdio_frame_bit = 1'b1;
                6'd34: mdio_frame_bit = mdio_read_operation;
                6'd35: mdio_frame_bit = !mdio_read_operation;
                6'd36: mdio_frame_bit = mdio_address_q[9];
                6'd37: mdio_frame_bit = mdio_address_q[8];
                6'd38: mdio_frame_bit = mdio_address_q[7];
                6'd39: mdio_frame_bit = mdio_address_q[6];
                6'd40: mdio_frame_bit = mdio_address_q[5];
                6'd41: mdio_frame_bit = mdio_address_q[4];
                6'd42: mdio_frame_bit = mdio_address_q[3];
                6'd43: mdio_frame_bit = mdio_address_q[2];
                6'd44: mdio_frame_bit = mdio_address_q[1];
                6'd45: mdio_frame_bit = mdio_address_q[0];
                6'd46: mdio_frame_bit = 1'b1;
                6'd47: mdio_frame_bit = 1'b0;
                default:
                    mdio_frame_bit = mdio_write_data_q[63-mdio_bit_index_q];
            endcase
        end
    end

    assign mdio_oe_o = mdio_busy_q &&
        (!mdio_read_operation || (mdio_bit_index_q < 6'd46));
    assign mdio_o = mdio_frame_bit;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            mdc_o <= 1'b0;
            mdc_divider_q <= {MDC_DIVIDER_BITS{1'b0}};
            mdio_bit_index_q <= 6'd0;
            mdio_read_shift_q <= 16'd0;
            mdio_read_data_q <= 16'd0;
            mdio_busy_q <= 1'b0;
        end else if (mdio_start_q && !mdio_busy_q) begin
            mdc_o <= 1'b0;
            mdc_divider_q <= {MDC_DIVIDER_BITS{1'b0}};
            mdio_bit_index_q <= 6'd0;
            mdio_read_shift_q <= 16'd0;
            mdio_busy_q <= 1'b1;
        end else if (mdio_busy_q) begin
            if (mdc_divider_q == MDC_HALF_PERIOD_CYCLES-1) begin
                mdc_divider_q <= {MDC_DIVIDER_BITS{1'b0}};
                if (!mdc_o) begin
                    mdc_o <= 1'b1;
                    if (mdio_read_operation &&
                        (mdio_bit_index_q >= 6'd48))
                        mdio_read_shift_q <=
                            {mdio_read_shift_q[14:0], mdio_i};
                end else begin
                    mdc_o <= 1'b0;
                    if (mdio_bit_index_q == 6'd63) begin
                        mdio_busy_q <= 1'b0;
                        if (mdio_read_operation)
                            mdio_read_data_q <= mdio_read_shift_q;
                    end else begin
                        mdio_bit_index_q <= mdio_bit_index_q + 1'b1;
                    end
                end
            end else begin
                mdc_divider_q <= mdc_divider_q + 1'b1;
            end
        end else begin
            mdc_o <= 1'b0;
            mdc_divider_q <= {MDC_DIVIDER_BITS{1'b0}};
        end
    end

    // TX clock-domain reset and request mailbox.
    (* ASYNC_REG = "TRUE" *) reg [1:0] tx_reset_sync_q;
    (* ASYNC_REG = "TRUE" *) reg [1:0] tx_start_sync0_q;
    (* ASYNC_REG = "TRUE" *) reg [1:0] tx_start_sync1_q;
    reg [1:0] tx_start_seen_q;
    reg [1:0] tx_pending_q;
    reg [15:0] tx_length_sync0_q [0:1];
    reg [15:0] tx_length_sync1_q [0:1];
    wire tx_rst_n = tx_reset_sync_q[1];

    reg [2:0] tx_state_q;
    reg tx_buffer_q;
    reg [2:0] tx_preamble_count_q;
    reg [15:0] tx_frame_length_q;
    reg [15:0] tx_byte_index_q;
    reg [6:0] tx_pad_remaining_q;
    reg [1:0] tx_fcs_index_q;
    reg [3:0] tx_ifg_count_q;
    reg [31:0] tx_crc_q;
    reg [31:0] tx_fcs_q;

    reg [2:0] tx_read_lane_q;
    wire [63:0] tx_read_word = tx_buffer_q ?
        tx1_mac_read_data : tx0_mac_read_data;
    wire [7:0] tx_stream_byte = select_byte(
        tx_read_word, tx_read_lane_q);
    wire [31:0] tx_stream_crc = crc32_byte(tx_crc_q, tx_stream_byte);
    wire [31:0] tx_zero_crc = crc32_byte(tx_crc_q, 8'h00);

    always @(posedge tx_clk_i or negedge rst_ni) begin
        if (!rst_ni)
            tx_reset_sync_q <= 2'b00;
        else
            tx_reset_sync_q <= {tx_reset_sync_q[0], 1'b1};
    end

    always @(posedge tx_clk_i) begin
        tx_read_lane_q <= tx_read_byte_addr_q[2:0];
    end

    always @(posedge tx_clk_i or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            tx_start_sync0_q <= 2'b00;
            tx_start_sync1_q <= 2'b00;
            tx_start_seen_q <= 2'b00;
            tx_pending_q <= 2'b00;
            tx_length_sync0_q[0] <= 16'd0;
            tx_length_sync0_q[1] <= 16'd0;
            tx_length_sync1_q[0] <= 16'd0;
            tx_length_sync1_q[1] <= 16'd0;
            tx_done_toggle_q <= 2'b00;
            tx_state_q <= TX_IDLE;
            tx_buffer_q <= 1'b0;
            tx_preamble_count_q <= 3'd0;
            tx_frame_length_q <= 16'd0;
            tx_byte_index_q <= 16'd0;
            tx_pad_remaining_q <= 7'd0;
            tx_fcs_index_q <= 2'd0;
            tx_ifg_count_q <= 4'd0;
            tx_crc_q <= 32'hffff_ffff;
            tx_fcs_q <= 32'd0;
            tx_read_byte_addr_q <= 13'd0;
            tx_data_o <= 8'd0;
            tx_valid_o <= 1'b0;
        end else begin
            tx_start_sync0_q <= tx_start_toggle_q;
            tx_start_sync1_q <= tx_start_sync0_q;
            tx_length_sync0_q[0] <= tx_length_q[0];
            tx_length_sync0_q[1] <= tx_length_q[1];
            tx_length_sync1_q[0] <= tx_length_sync0_q[0];
            tx_length_sync1_q[1] <= tx_length_sync0_q[1];

            tx_pending_q <= tx_pending_q |
                (tx_start_sync1_q ^ tx_start_seen_q);
            if (tx_start_sync1_q != tx_start_seen_q)
                tx_start_seen_q <= tx_start_sync1_q;

            case (tx_state_q)
                TX_IDLE: begin
                    tx_valid_o <= 1'b0;
                    tx_data_o <= 8'd0;
                    tx_read_byte_addr_q <= 13'd0;
                    if (tx_pending_q[0] || tx_pending_q[1]) begin
                        tx_buffer_q <= !tx_pending_q[0];
                        if (tx_pending_q[0]) begin
                            tx_pending_q[0] <= 1'b0;
                            tx_frame_length_q <=
                                (tx_length_sync1_q[0] > MAX_FRAME_BYTES) ?
                                    MAX_FRAME_BYTES : tx_length_sync1_q[0];
                        end else begin
                            tx_pending_q[1] <= 1'b0;
                            tx_frame_length_q <=
                                (tx_length_sync1_q[1] > MAX_FRAME_BYTES) ?
                                    MAX_FRAME_BYTES : tx_length_sync1_q[1];
                        end
                        tx_crc_q <= 32'hffff_ffff;
                        tx_preamble_count_q <= 3'd1;
                        tx_valid_o <= 1'b1;
                        tx_data_o <= 8'h55;
                        tx_state_q <= TX_PREAMBLE;
                    end
                end
                TX_PREAMBLE: begin
                    tx_valid_o <= 1'b1;
                    if (tx_preamble_count_q < 3'd7) begin
                        tx_data_o <= 8'h55;
                        tx_preamble_count_q <=
                            tx_preamble_count_q + 1'b1;
                    end else begin
                        tx_data_o <= 8'hd5;
                        tx_byte_index_q <= 16'd0;
                        tx_read_byte_addr_q <= 13'd1;
                        tx_state_q <= TX_DATA;
                    end
                end
                TX_DATA: begin
                    tx_valid_o <= 1'b1;
                    tx_data_o <= tx_stream_byte;
                    tx_crc_q <= tx_stream_crc;
                    tx_read_byte_addr_q <= tx_byte_index_q + 16'd2;
                    if ((tx_frame_length_q == 0) ||
                        (tx_byte_index_q + 1'b1 >= tx_frame_length_q)) begin
                        if (tx_frame_length_q < 16'd60) begin
                            tx_pad_remaining_q <=
                                16'd60 - tx_frame_length_q;
                            tx_state_q <= TX_PAD;
                        end else begin
                            tx_fcs_q <= ~tx_stream_crc;
                            tx_fcs_index_q <= 2'd0;
                            tx_state_q <= TX_FCS;
                        end
                    end else begin
                        tx_byte_index_q <= tx_byte_index_q + 1'b1;
                    end
                end
                TX_PAD: begin
                    tx_valid_o <= 1'b1;
                    tx_data_o <= 8'h00;
                    tx_crc_q <= tx_zero_crc;
                    if (tx_pad_remaining_q == 7'd1) begin
                        tx_fcs_q <= ~tx_zero_crc;
                        tx_fcs_index_q <= 2'd0;
                        tx_state_q <= TX_FCS;
                    end else begin
                        tx_pad_remaining_q <= tx_pad_remaining_q - 1'b1;
                    end
                end
                TX_FCS: begin
                    tx_valid_o <= 1'b1;
                    case (tx_fcs_index_q)
                        2'd0: tx_data_o <= tx_fcs_q[7:0];
                        2'd1: tx_data_o <= tx_fcs_q[15:8];
                        2'd2: tx_data_o <= tx_fcs_q[23:16];
                        default: tx_data_o <= tx_fcs_q[31:24];
                    endcase
                    if (tx_fcs_index_q == 2'd3)
                        tx_state_q <= TX_END;
                    else
                        tx_fcs_index_q <= tx_fcs_index_q + 1'b1;
                end
                TX_END: begin
                    tx_valid_o <= 1'b0;
                    tx_data_o <= 8'd0;
                    tx_done_toggle_q[tx_buffer_q] <=
                        ~tx_done_toggle_q[tx_buffer_q];
                    tx_ifg_count_q <= 4'd0;
                    tx_state_q <= TX_IFG;
                end
                default: begin
                    tx_valid_o <= 1'b0;
                    if (tx_ifg_count_q == 4'd11)
                        tx_state_q <= TX_IDLE;
                    else
                        tx_ifg_count_q <= tx_ifg_count_q + 1'b1;
                end
            endcase
        end
    end

    assign tx_error_o = 1'b0;

    // RX packet engine.  It strips preamble/SFD, retains the Ethernet FCS in
    // packet RAM as expected by the Linux driver, validates CRC, and filters
    // unicast/broadcast destination addresses.
    (* ASYNC_REG = "TRUE" *) reg [1:0] rx_reset_sync_q;
    (* ASYNC_REG = "TRUE" *) reg [1:0] rx_clear_sync0_q;
    (* ASYNC_REG = "TRUE" *) reg [1:0] rx_clear_sync1_q;
    reg [1:0] rx_clear_seen_q;
    reg [47:0] mac_address_sync0_q;
    reg [47:0] mac_address_sync1_q;
    wire rx_rst_n = rx_reset_sync_q[1];

    reg [3:0] rx_preamble_count_q;
    reg rx_payload_q;
    reg rx_drop_q;
    reg rx_buffer_q;
    reg rx_next_buffer_q;
    reg [15:0] rx_byte_count_q;
    reg [63:0] rx_pack_q;
    reg [31:0] rx_crc_q;
    reg [47:0] rx_destination_q;
    reg [15:0] rx_length_q [0:1];

    wire [63:0] rx_pack_with_byte = insert_byte(
        rx_pack_q, rx_data_i, rx_byte_count_q[2:0]);
    wire [31:0] rx_crc_with_byte = crc32_byte(rx_crc_q, rx_data_i);
    wire rx_destination_match =
        (rx_destination_q == mac_address_sync1_q) ||
        (&rx_destination_q);

    wire rx_full_word_write = rx_valid_i && rx_payload_q &&
        !rx_drop_q && (rx_byte_count_q < PACKET_BYTES) &&
        (rx_byte_count_q[2:0] == 3'd7);
    wire rx_partial_word_write = !rx_valid_i && rx_payload_q &&
        !rx_drop_q && (rx_byte_count_q[2:0] != 0);
    assign rx_memory_write = rx_full_word_write || rx_partial_word_write;
    assign rx_memory_bank = rx_buffer_q;
    assign rx_memory_addr = rx_byte_count_q[12:3];
    assign rx_memory_data = rx_full_word_write ?
        rx_pack_with_byte : rx_pack_q;

    always @(posedge rx_clk_i or negedge rst_ni) begin
        if (!rst_ni)
            rx_reset_sync_q <= 2'b00;
        else
            rx_reset_sync_q <= {rx_reset_sync_q[0], 1'b1};
    end

    always @(posedge rx_clk_i or negedge rx_rst_n) begin
        if (!rx_rst_n) begin
            rx_clear_sync0_q <= 2'b00;
            rx_clear_sync1_q <= 2'b00;
            rx_clear_seen_q <= 2'b00;
            mac_address_sync0_q <= 48'h02_00_00_00_00_01;
            mac_address_sync1_q <= 48'h02_00_00_00_00_01;
            rx_done_q <= 2'b00;
            rx_length_q[0] <= 16'd0;
            rx_length_q[1] <= 16'd0;
            rx_preamble_count_q <= 4'd0;
            rx_payload_q <= 1'b0;
            rx_drop_q <= 1'b0;
            rx_buffer_q <= 1'b0;
            rx_next_buffer_q <= 1'b0;
            rx_byte_count_q <= 16'd0;
            rx_pack_q <= 64'd0;
            rx_crc_q <= 32'hffff_ffff;
            rx_destination_q <= 48'd0;
        end else begin
            rx_clear_sync0_q <= rx_clear_toggle_q;
            rx_clear_sync1_q <= rx_clear_sync0_q;
            mac_address_sync0_q <= mac_address_q;
            mac_address_sync1_q <= mac_address_sync0_q;

            if (rx_clear_sync1_q != rx_clear_seen_q) begin
                rx_done_q <= rx_done_q &
                    ~(rx_clear_sync1_q ^ rx_clear_seen_q);
                rx_clear_seen_q <= rx_clear_sync1_q;
            end

            if (rx_valid_i) begin
                if (!rx_payload_q) begin
                    if (rx_data_i == 8'h55) begin
                        if (rx_preamble_count_q != 4'hf)
                            rx_preamble_count_q <=
                                rx_preamble_count_q + 1'b1;
                    end else if ((rx_data_i == 8'hd5) &&
                                 (rx_preamble_count_q != 0)) begin
                        rx_payload_q <= 1'b1;
                        rx_byte_count_q <= 16'd0;
                        rx_pack_q <= 64'd0;
                        rx_crc_q <= 32'hffff_ffff;
                        rx_destination_q <= 48'd0;
                        if (!rx_done_q[rx_next_buffer_q]) begin
                            rx_buffer_q <= rx_next_buffer_q;
                            rx_next_buffer_q <= ~rx_next_buffer_q;
                            rx_drop_q <= 1'b0;
                        end else if (!rx_done_q[~rx_next_buffer_q]) begin
                            rx_buffer_q <= ~rx_next_buffer_q;
                            rx_drop_q <= 1'b0;
                        end else begin
                            rx_drop_q <= 1'b1;
                        end
                    end else begin
                        rx_preamble_count_q <= 4'd0;
                    end
                end else begin
                    if (rx_byte_count_q < PACKET_BYTES) begin
                        rx_pack_q <= rx_pack_with_byte;
                        if (rx_byte_count_q < 16'd6)
                            rx_destination_q[8*rx_byte_count_q +: 8] <=
                                rx_data_i;
                        rx_crc_q <= rx_crc_with_byte;
                        if (rx_byte_count_q[2:0] == 3'd7) begin
                            rx_pack_q <= 64'd0;
                        end
                        rx_byte_count_q <= rx_byte_count_q + 1'b1;
                    end else begin
                        rx_drop_q <= 1'b1;
                    end
                    if (rx_error_i)
                        rx_drop_q <= 1'b1;
                end
            end else if (rx_payload_q) begin
                if (!rx_drop_q &&
                    (rx_byte_count_q >= 16'd64) &&
                    (rx_byte_count_q <= MAX_FRAME_BYTES) &&
                    (rx_crc_q == 32'hdebb_20e3) &&
                    rx_destination_match) begin
                    rx_done_q[rx_buffer_q] <= 1'b1;
                    rx_length_q[rx_buffer_q] <= rx_byte_count_q;
                end

                rx_payload_q <= 1'b0;
                rx_drop_q <= 1'b0;
                rx_preamble_count_q <= 4'd0;
                rx_byte_count_q <= 16'd0;
                rx_pack_q <= 64'd0;
                rx_crc_q <= 32'hffff_ffff;
            end
        end
    end

    wire unused_lengths = &{1'b0, rx_length_q[0], rx_length_q[1]};

endmodule
