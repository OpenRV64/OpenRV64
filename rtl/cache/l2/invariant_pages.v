`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "soc/bus/mem_map.v"

// A 16 MiB physical aperture whose contents are generated at the shared L2.
// It has no SRAM allocation and no backing-memory representation.  The first
// three pages have defined read values; all writes are ignored, and the
// remaining reserved space is RAZ/WI.
//
// The random page is a deterministic pseudorandom test/data source, not an
// entropy source.  Its 64-bit xorshift state advances once for each dispatched
// read.  Rotations expose eight distinct lanes without eight PRNG datapaths.
module openrv64_l2_invariant_pages #(
    parameter [63:0] BASE = `OPENRV64_SOC_INVARIANT_BASE
) (
    input  wire clk_i,
    input  wire rst_ni,
    input  wire [63:0] addr_i,
    input  wire read_fire_i,
    output wire match_o,
    output wire random_match_o,
    output reg  [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] rdata_o
);

    // BASE is 16 MiB aligned.  One high-address equality covers the whole
    // aperture; only the low page number distinguishes defined pages.
    wire region_match = addr_i[63:24] == BASE[63:24];
    wire one_match = region_match && (addr_i[23:12] == 12'd1);
    assign random_match_o =
        region_match && (addr_i[23:12] == 12'd2);
    assign match_o = region_match;

    function automatic [63:0] xorshift64;
        input [63:0] value;
        reg [63:0] next_value;
        begin
            next_value = value;
            next_value = next_value ^ (next_value << 13);
            next_value = next_value ^ (next_value >> 7);
            next_value = next_value ^ (next_value << 17);
            xorshift64 = next_value;
        end
    endfunction

    reg [63:0] random_state_q;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            random_state_q <= 64'h4f50_454e_5256_3634;
        else if (read_fire_i && random_match_o)
            random_state_q <= xorshift64(random_state_q);
    end

    reg [63:0] random_word_r;
    always @* begin
        random_word_r = random_state_q ^
            {52'd0, addr_i[11:6], 6'd0};
        rdata_o = 0;

        if (one_match) begin
            rdata_o = {8{64'd1}};
        end else if (random_match_o) begin
            rdata_o[0*64 +: 64] = random_word_r;
            rdata_o[1*64 +: 64] = {random_word_r[55:0],
                                    random_word_r[63:56]};
            rdata_o[2*64 +: 64] = {random_word_r[47:0],
                                    random_word_r[63:48]};
            rdata_o[3*64 +: 64] = {random_word_r[39:0],
                                    random_word_r[63:40]};
            rdata_o[4*64 +: 64] = {random_word_r[31:0],
                                    random_word_r[63:32]};
            rdata_o[5*64 +: 64] = {random_word_r[23:0],
                                    random_word_r[63:24]};
            rdata_o[6*64 +: 64] = {random_word_r[15:0],
                                    random_word_r[63:16]};
            rdata_o[7*64 +: 64] = {random_word_r[7:0],
                                    random_word_r[63:8]};
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (BASE[23:0] != 0)
            $fatal(1, "L2 invariant aperture must be 16 MiB aligned");
    end
`endif

endmodule
