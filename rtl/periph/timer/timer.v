`timescale 1ns/1ps

// Simple programmable one-shot/periodic down-counter.
//
// This block intentionally has no waveform output or PWM behavior. All bus
// addresses are target-local offsets supplied by openrv64_soc_bus_decode.
module openrv64_timer #(
    parameter integer ENABLE_INTERRUPTS = 1
) (
    input  wire        clk_i,
    input  wire        rst_ni,

    output wire        irq_o,

    input  wire        mem_valid_i,
    output wire        mem_ready_o,
    input  wire        mem_write_i,
    input  wire [63:0] mem_addr_i,
    input  wire [63:0] mem_wdata_i,
    input  wire [7:0]  mem_wstrb_i,
    output reg  [63:0] mem_rdata_o
);

    localparam [63:0] CONTROL_OFFSET = 64'h00;
    localparam [63:0] DIVIDER_OFFSET = 64'h08;
    localparam [63:0] LOAD_OFFSET    = 64'h10;
    localparam [63:0] VALUE_OFFSET   = 64'h18;
    localparam [63:0] STATUS_OFFSET  = 64'h20;

    reg        enable_q;
    reg        periodic_q;
    reg        irq_enable_q;
    reg [31:0] divider_q;
    reg [31:0] divider_count_q;
    reg [63:0] reload_q;
    reg [63:0] count_q;
    reg        irq_pending_q;

    wire write_accept = mem_valid_i && mem_write_i;
    wire divider_tick = enable_q && (divider_count_q >= divider_q);
    wire expire_now = divider_tick && (count_q == 64'd1);

    wire [63:0] control_read_data =
        {61'h0, irq_enable_q, periodic_q, enable_q};
    wire [63:0] divider_read_data = {32'h0, divider_q};
    wire [63:0] status_read_data =
        {62'h0, enable_q, irq_pending_q};

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

    wire [63:0] merged_control_write = merge_write_data(
        control_read_data, mem_wdata_i, mem_wstrb_i);
    wire [63:0] merged_divider_write = merge_write_data(
        divider_read_data, mem_wdata_i, mem_wstrb_i);
    wire [63:0] merged_load_write = merge_write_data(
        reload_q, mem_wdata_i, mem_wstrb_i);
    wire [63:0] merged_value_write = merge_write_data(
        count_q, mem_wdata_i, mem_wstrb_i);

    assign mem_ready_o = mem_valid_i;
    assign irq_o = (ENABLE_INTERRUPTS != 0) &&
                   irq_enable_q && irq_pending_q;

    always @* begin
        mem_rdata_o = 64'h0;
        case (mem_addr_i[63:3])
            (CONTROL_OFFSET >> 3): mem_rdata_o = control_read_data;
            (DIVIDER_OFFSET >> 3): mem_rdata_o = divider_read_data;
            (LOAD_OFFSET >> 3):    mem_rdata_o = reload_q;
            (VALUE_OFFSET >> 3):   mem_rdata_o = count_q;
            (STATUS_OFFSET >> 3):  mem_rdata_o = status_read_data;
            default: mem_rdata_o = 64'h0;
        endcase
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            enable_q <= 1'b0;
            periodic_q <= 1'b0;
            irq_enable_q <= 1'b0;
            divider_q <= 32'd0;
            divider_count_q <= 32'd0;
            reload_q <= 64'd0;
            count_q <= 64'd0;
            irq_pending_q <= 1'b0;
        end else begin
            // Disabled timers restart at the beginning of a divider period.
            if (!enable_q) begin
                divider_count_q <= 32'd0;
            end else if (divider_tick) begin
                divider_count_q <= 32'd0;
                if (count_q > 64'd1) begin
                    count_q <= count_q - 64'd1;
                end else if (count_q == 64'd1) begin
                    if (periodic_q) begin
                        count_q <= reload_q;
                    end else begin
                        count_q <= 64'd0;
                        enable_q <= 1'b0;
                    end
                end
            end else begin
                divider_count_q <= divider_count_q + 32'd1;
            end

            if (write_accept &&
                (mem_addr_i[63:3] == (STATUS_OFFSET >> 3)) &&
                mem_wstrb_i[0] && mem_wdata_i[0]) begin
                irq_pending_q <= 1'b0;
            end

            if (write_accept) begin
                case (mem_addr_i[63:3])
                    (CONTROL_OFFSET >> 3): begin
                        enable_q <= merged_control_write[0];
                        periodic_q <= merged_control_write[1];
                        irq_enable_q <= merged_control_write[2];
                        if (!enable_q && merged_control_write[0] &&
                            (count_q == 64'd0)) begin
                            count_q <= reload_q;
                        end
                        if (!merged_control_write[0]) begin
                            divider_count_q <= 32'd0;
                        end
                    end
                    (DIVIDER_OFFSET >> 3): begin
                        divider_q <= merged_divider_write[31:0];
                        divider_count_q <= 32'd0;
                    end
                    (LOAD_OFFSET >> 3): begin
                        reload_q <= merged_load_write;
                        count_q <= merged_load_write;
                        divider_count_q <= 32'd0;
                    end
                    (VALUE_OFFSET >> 3): begin
                        count_q <= merged_value_write;
                        divider_count_q <= 32'd0;
                    end
                    default: begin end
                endcase
            end

            // Expiry has priority over a coincident W1C so an interrupt event
            // cannot be lost at the software-clear boundary.
            if (expire_now) begin
                irq_pending_q <= 1'b1;
            end
        end
    end

endmodule
