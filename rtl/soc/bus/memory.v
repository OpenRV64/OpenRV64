`timescale 1ns/1ps

// Target-local SoC RAM with an inference-friendly synchronous read port.
//
// A request is captured on a rising edge and acknowledged for the following
// cycle.  The response pulse is followed by an idle cycle so a requester that
// holds mem_valid_i through completion cannot be accepted twice.  The address
// decoder guarantees that valid requests are inside this target's window and
// supplies a byte offset relative to the RAM base.
module openrv64_soc_memory #(
    parameter integer MEM_BYTES = 256 * 1024 * 1024
) (
    input  wire        clk_i,
    input  wire        rst_ni,

    input  wire        mem_valid_i,
    output wire        mem_ready_o,
    input  wire        mem_write_i,
    input  wire [63:0] mem_addr_i,
    input  wire [63:0] mem_wdata_i,
    input  wire [7:0]  mem_wstrb_i,
    output wire [63:0] mem_rdata_o
);

    localparam integer WORD_COUNT = MEM_BYTES / 8;
    localparam integer WORD_INDEX_WIDTH = $clog2(WORD_COUNT);

    reg [63:0] memory_q [0:WORD_COUNT-1];
    reg pending_q;
    reg response_write_q;
    reg [63:0] read_data_q;

    wire address_in_range = (mem_addr_i < MEM_BYTES);
    wire [WORD_INDEX_WIDTH-1:0] word_index =
        mem_addr_i[WORD_INDEX_WIDTH+2:3];

    integer init_index;
    integer byte_index;

    initial begin
        for (init_index = 0; init_index < WORD_COUNT;
             init_index = init_index + 1) begin
            memory_q[init_index] = 64'h0000_0000_0000_0000;
        end
    end

    wire accept_request = mem_valid_i && !pending_q;

    assign mem_ready_o = pending_q;
    assign mem_rdata_o = (pending_q && !response_write_q) ?
                         read_data_q : 64'h0000_0000_0000_0000;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            pending_q <= 1'b0;
            response_write_q <= 1'b0;
        end else if (pending_q) begin
            pending_q <= 1'b0;
            response_write_q <= 1'b0;
        end else if (mem_valid_i) begin
            pending_q <= 1'b1;
            response_write_q <= mem_write_i;
        end
    end

    always @(posedge clk_i) begin
        if (accept_request && !mem_write_i) begin
            read_data_q <= address_in_range ?
                           memory_q[word_index] :
                           64'h0000_0000_0000_0000;
        end

        if (accept_request && mem_write_i && address_in_range) begin
            for (byte_index = 0; byte_index < 8;
                 byte_index = byte_index + 1) begin
                if (mem_wstrb_i[byte_index]) begin
                    memory_q[word_index][8*byte_index +: 8] <=
                        mem_wdata_i[8*byte_index +: 8];
                end
            end
        end
    end

endmodule
