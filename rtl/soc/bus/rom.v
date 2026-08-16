`timescale 1ns/1ps

// Small target-local boot ROM.
//
// The initial program forwards the architectural hart ID in a0, constructs
// the RAM base (0x8000_0000) in x1, and jumps to it:
//
//     csrr a0, mhartid
//     addi x1, x0, 1       // li x1, 1
//     slli x1, x1, 31
//     jalr x0, 0(x1)       // jr x1
module openrv64_soc_rom #(
    parameter integer ROM_BYTES = 4 * 1024
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

    localparam integer WORD_COUNT = ROM_BYTES / 8;
    localparam integer WORD_INDEX_WIDTH = $clog2(WORD_COUNT);

    (* rom_style = "block", ram_style = "block" *)
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
        rom_q[0] = 64'h0010_0093_f140_2573;
        rom_q[1] = 64'h0000_8067_01f0_9093;
    end

    localparam [1:0] STATE_IDLE     = 2'd0;
    localparam [1:0] STATE_WAIT     = 2'd1;
    localparam [1:0] STATE_RESPONSE = 2'd2;
    localparam [1:0] STATE_RECOVER  = 2'd3;

    reg [1:0] state_q;
    reg response_has_data_q;
    reg [63:0] rom_data_q;

    // Keep the memory read in the canonical synchronous-ROM form.  In
    // particular, do not fold write/out-of-range zero selection into this
    // register: that mux prevents Yosys from merging the output register into
    // the block-memory read port.
    always @(posedge clk_i) begin
        if ((state_q == STATE_IDLE) && mem_valid_i && !mem_write_i &&
            address_in_range)
            rom_data_q <= rom_q[word_index];
    end

    // The ROM is intentionally not a zero-latency target.  IDLE captures one
    // request and performs a synchronous array read.  WAIT supplies a full
    // dead cycle before RESPONSE acknowledges the transaction.  RECOVER then
    // prevents a continuously asserted valid from being accepted back to
    // back.  The blocking bus holds the request stable until RESPONSE.
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= STATE_IDLE;
            response_has_data_q <= 1'b0;
        end else begin
            case (state_q)
                STATE_IDLE: begin
                    if (mem_valid_i) begin
                        response_has_data_q <=
                            !mem_write_i && address_in_range;
                        state_q <= STATE_WAIT;
                    end
                end
                STATE_WAIT:
                    state_q <= STATE_RESPONSE;
                STATE_RESPONSE:
                    state_q <= STATE_RECOVER;
                default:
                    state_q <= STATE_IDLE;
            endcase
        end
    end

    assign mem_ready_o = (state_q == STATE_RESPONSE);
    assign mem_rdata_o = (mem_ready_o && response_has_data_q) ? rom_data_q :
                         64'h0000_0000_0000_0000;

    // Writes are acknowledged and ignored. Keep the request payload in the
    // interface so ROM and RAM use the same target-side bus contract.
    wire unused_write_payload = |{mem_wdata_i, mem_wstrb_i};

endmodule
