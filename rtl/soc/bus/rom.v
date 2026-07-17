`timescale 1ns/1ps

// Small target-local boot ROM.
//
// The initial program constructs the RAM base (0x8000_0000) in x1 and jumps
// to it:
//
//     addi x1, x0, 1       // li x1, 1
//     slli x1, x1, 31
//     jalr x0, 0(x1)       // jr x1
module openrv64_soc_rom #(
    parameter integer ROM_BYTES = 64 * 1024
) (
    input  wire        mem_valid_i,
    output wire        mem_ready_o,
    input  wire        mem_write_i,
    input  wire [63:0] mem_addr_i,
    input  wire [63:0] mem_wdata_i,
    input  wire [7:0]  mem_wstrb_i,
    output wire [63:0] mem_rdata_o
);

    localparam integer WORD_COUNT = ROM_BYTES / 8;
    localparam integer WORD_INDEX_WIDTH = $clog2(WORD_COUNT);

    reg [63:0] rom_q [0:WORD_COUNT-1];

    wire address_in_range = (mem_addr_i < ROM_BYTES);
    wire [WORD_INDEX_WIDTH-1:0] word_index =
        mem_addr_i[WORD_INDEX_WIDTH+2:3];

    integer init_index;

    initial begin
        for (init_index = 0; init_index < WORD_COUNT;
             init_index = init_index + 1) begin
            rom_q[init_index] = 64'h0000_0000_0000_0000;
        end

        // Two little-endian 32-bit instructions per 64-bit bus word.
        rom_q[0] = 64'h01f0_9093_0010_0093;
        rom_q[1] = 64'h0000_0000_0000_8067;
    end

    assign mem_ready_o = mem_valid_i;
    assign mem_rdata_o = (mem_valid_i && !mem_write_i && address_in_range) ?
                         rom_q[word_index] :
                         64'h0000_0000_0000_0000;

    // Writes are acknowledged and ignored. Keep the request payload in the
    // interface so ROM and RAM use the same target-side bus contract.
    wire unused_write_payload = |{mem_wdata_i, mem_wstrb_i};

endmodule
