`timescale 1ns/1ps

// Simple memory-mapped GPIO with optional interrupt generation.
//
// Inputs and outputs are deliberately separate; pin direction and pad
// tri-state control belong in a later I/O wrapper.  All bus addresses are
// target-local offsets supplied by openrv64_soc_bus_decode.
module openrv64_gpio #(
    parameter integer NUM_PINS = 32,
    parameter integer ENABLE_INTERRUPTS = 1
) (
    input  wire                    clk_i,
    input  wire                    rst_ni,

    input  wire [NUM_PINS-1:0]     gpio_in_i,
    output wire [NUM_PINS-1:0]     gpio_out_o,
    output wire                    irq_o,

    input  wire                    mem_valid_i,
    output wire                    mem_ready_o,
    input  wire                    mem_write_i,
    input  wire [63:0]             mem_addr_i,
    input  wire [63:0]             mem_wdata_i,
    input  wire [7:0]              mem_wstrb_i,
    output reg  [63:0]             mem_rdata_o
);

    localparam [63:0] INPUT_OFFSET        = 64'h00;
    localparam [63:0] OUTPUT_OFFSET       = 64'h08;
    localparam [63:0] IRQ_ENABLE_OFFSET   = 64'h10;
    localparam [63:0] IRQ_TYPE_OFFSET     = 64'h18;
    localparam [63:0] IRQ_POLARITY_OFFSET = 64'h20;
    localparam [63:0] IRQ_PENDING_OFFSET  = 64'h28;

    reg [NUM_PINS-1:0] input_sync_1_q;
    reg [NUM_PINS-1:0] input_sync_2_q;
    reg [NUM_PINS-1:0] input_previous_q;
    reg [NUM_PINS-1:0] output_q;
    reg [NUM_PINS-1:0] irq_enable_q;
    // One selects edge-sensitive operation; zero selects level-sensitive.
    reg [NUM_PINS-1:0] irq_type_q;
    // One selects rising/high; zero selects falling/low.
    reg [NUM_PINS-1:0] irq_polarity_q;
    reg [NUM_PINS-1:0] edge_pending_q;

    wire write_accept = mem_valid_i && mem_write_i;
    wire [NUM_PINS-1:0] rising_edges =
        input_sync_2_q & ~input_previous_q;
    wire [NUM_PINS-1:0] falling_edges =
        ~input_sync_2_q & input_previous_q;
    wire [NUM_PINS-1:0] selected_edges =
        (rising_edges & irq_polarity_q) |
        (falling_edges & ~irq_polarity_q);
    wire [NUM_PINS-1:0] edge_events = selected_edges & irq_type_q;
    wire [NUM_PINS-1:0] active_levels =
        (input_sync_2_q & irq_polarity_q) |
        (~input_sync_2_q & ~irq_polarity_q);
    wire [NUM_PINS-1:0] irq_pending =
        (edge_pending_q & irq_type_q) |
        (active_levels & ~irq_type_q);
    wire [NUM_PINS-1:0] routed_irq_pending =
        irq_enable_q & irq_pending;
    wire [63:0] write_strobe_mask = {
        {8{mem_wstrb_i[7]}}, {8{mem_wstrb_i[6]}},
        {8{mem_wstrb_i[5]}}, {8{mem_wstrb_i[4]}},
        {8{mem_wstrb_i[3]}}, {8{mem_wstrb_i[2]}},
        {8{mem_wstrb_i[1]}}, {8{mem_wstrb_i[0]}}
    };
    wire [63:0] strobed_write_data = mem_wdata_i & write_strobe_mask;
    wire [NUM_PINS-1:0] edge_clear_mask =
        strobed_write_data[NUM_PINS-1:0];

    reg [63:0] input_read_data;
    reg [63:0] output_read_data;
    reg [63:0] irq_enable_read_data;
    reg [63:0] irq_type_read_data;
    reg [63:0] irq_polarity_read_data;
    reg [63:0] irq_pending_read_data;

    function [63:0] merge_write_data;
        input [63:0] old_value;
        input [63:0] new_value;
        input [7:0]  write_strobe;
        integer byte_index;
        begin
            merge_write_data = old_value;
            for (byte_index = 0; byte_index < 8;
                 byte_index = byte_index + 1) begin
                if (write_strobe[byte_index]) begin
                    merge_write_data[8*byte_index +: 8] =
                        new_value[8*byte_index +: 8];
                end
            end
        end
    endfunction

    wire [63:0] merged_output_write = merge_write_data(
        output_read_data, mem_wdata_i, mem_wstrb_i);
    wire [63:0] merged_irq_enable_write = merge_write_data(
        irq_enable_read_data, mem_wdata_i, mem_wstrb_i);
    wire [63:0] merged_irq_type_write = merge_write_data(
        irq_type_read_data, mem_wdata_i, mem_wstrb_i);
    wire [63:0] merged_irq_polarity_write = merge_write_data(
        irq_polarity_read_data, mem_wdata_i, mem_wstrb_i);

    always @* begin
        input_read_data = 64'h0;
        output_read_data = 64'h0;
        irq_enable_read_data = 64'h0;
        irq_type_read_data = 64'h0;
        irq_polarity_read_data = 64'h0;
        irq_pending_read_data = 64'h0;

        input_read_data[NUM_PINS-1:0] = input_sync_2_q;
        output_read_data[NUM_PINS-1:0] = output_q;
        irq_enable_read_data[NUM_PINS-1:0] = irq_enable_q;
        irq_type_read_data[NUM_PINS-1:0] = irq_type_q;
        irq_polarity_read_data[NUM_PINS-1:0] = irq_polarity_q;
        irq_pending_read_data[NUM_PINS-1:0] = routed_irq_pending;
    end

    assign mem_ready_o = mem_valid_i;
    assign gpio_out_o = output_q;
    assign irq_o = (ENABLE_INTERRUPTS != 0) &&
                   (|routed_irq_pending);

    always @* begin
        mem_rdata_o = 64'h0;
        case (mem_addr_i[63:3])
            (INPUT_OFFSET >> 3):
                mem_rdata_o = input_read_data;
            (OUTPUT_OFFSET >> 3):
                mem_rdata_o = output_read_data;
            (IRQ_ENABLE_OFFSET >> 3):
                mem_rdata_o = irq_enable_read_data;
            (IRQ_TYPE_OFFSET >> 3):
                mem_rdata_o = irq_type_read_data;
            (IRQ_POLARITY_OFFSET >> 3):
                mem_rdata_o = irq_polarity_read_data;
            (IRQ_PENDING_OFFSET >> 3):
                mem_rdata_o = irq_pending_read_data;
            default: mem_rdata_o = 64'h0;
        endcase
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            input_sync_1_q <= {NUM_PINS{1'b0}};
            input_sync_2_q <= {NUM_PINS{1'b0}};
            input_previous_q <= {NUM_PINS{1'b0}};
            output_q <= {NUM_PINS{1'b0}};
            irq_enable_q <= {NUM_PINS{1'b0}};
            irq_type_q <= {NUM_PINS{1'b0}};
            irq_polarity_q <= {NUM_PINS{1'b0}};
            edge_pending_q <= {NUM_PINS{1'b0}};
        end else begin
            input_sync_1_q <= gpio_in_i;
            input_sync_2_q <= input_sync_1_q;
            input_previous_q <= input_sync_2_q;

            // A coincident edge wins over a software clear so an interrupt
            // event cannot be lost at the W1C boundary.
            if (write_accept &&
                (mem_addr_i[63:3] == (IRQ_PENDING_OFFSET >> 3))) begin
                edge_pending_q <=
                    (edge_pending_q & ~edge_clear_mask) |
                    edge_events;
            end else begin
                edge_pending_q <= edge_pending_q | edge_events;
            end

            if (write_accept) begin
                case (mem_addr_i[63:3])
                    (OUTPUT_OFFSET >> 3):
                        output_q <= merged_output_write[NUM_PINS-1:0];
                    (IRQ_ENABLE_OFFSET >> 3):
                        irq_enable_q <=
                            merged_irq_enable_write[NUM_PINS-1:0];
                    (IRQ_TYPE_OFFSET >> 3):
                        irq_type_q <=
                            merged_irq_type_write[NUM_PINS-1:0];
                    (IRQ_POLARITY_OFFSET >> 3):
                        irq_polarity_q <=
                            merged_irq_polarity_write[NUM_PINS-1:0];
                    default: begin end
                endcase
            end
        end
    end

endmodule
