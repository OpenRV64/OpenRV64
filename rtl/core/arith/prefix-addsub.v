`ifndef OPENRV64_PREFIX_ADDSUB_V
`define OPENRV64_PREFIX_ADDSUB_V

`timescale 1ns/1ps

// Fixed-width parallel-prefix adder/subtractor.  This deliberately spends
// wiring and prefix cells to keep carry propagation logarithmic.  sub_i
// selects a_i + ~b_i + 1; add is selected otherwise.
module openrv64_prefix_addsub (
    input  wire [63:0] a_i,
    input  wire [63:0] b_i,
    input  wire        sub_i,
    output wire [63:0] result_o
);

    wire [63:0] b_xor = b_i ^ {64{sub_i}};
    wire [63:0] p0 = a_i ^ b_xor;
    wire [63:0] g0 = a_i & b_xor;

    // Six Kogge-Stone-style prefix levels cover 64 bits.  Ones in the
    // propagate padding preserve groups below the distance of each level.
    wire [63:0] g1 = g0 | (p0 & {g0[62:0], 1'b0});
    wire [63:0] p1 = p0 & {p0[62:0], 1'b1};
    wire [63:0] g2 = g1 | (p1 & {g1[61:0], 2'b00});
    wire [63:0] p2 = p1 & {p1[61:0], 2'b11};
    wire [63:0] g3 = g2 | (p2 & {g2[59:0], 4'b0000});
    wire [63:0] p3 = p2 & {p2[59:0], 4'b1111};
    wire [63:0] g4 = g3 | (p3 & {g3[55:0], 8'h00});
    wire [63:0] p4 = p3 & {p3[55:0], 8'hff};
    wire [63:0] g5 = g4 | (p4 & {g4[47:0], 16'h0000});
    wire [63:0] p5 = p4 & {p4[47:0], 16'hffff};
    wire [63:0] g6 = g5 | (p5 & {g5[31:0], 32'h0000_0000});
    wire [63:0] p6 = p5 & {p5[31:0], 32'hffff_ffff};

    wire [64:0] carry;
    assign carry[0] = sub_i;

    genvar bit_index;
    generate
        for (bit_index = 0; bit_index < 64; bit_index = bit_index + 1) begin : gen_carry
            assign carry[bit_index + 1] =
                g6[bit_index] | (p6[bit_index] & sub_i);
        end
    endgenerate

    assign result_o = p0 ^ carry[63:0];

endmodule

`endif
