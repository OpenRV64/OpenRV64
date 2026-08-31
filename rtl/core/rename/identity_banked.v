`ifndef OPENRV64_RENAME_IDENTITY_BANKED_V
`define OPENRV64_RENAME_IDENTITY_BANKED_V

`timescale 1ns/1ps

// Initial banked-backend identity rename boundary.  Only two instructions
// enter the banked issue path, so there are four source tags and two
// destination tags.  The interface remains physical-tag shaped for a future
// RAT/free-list replacement.
module openrv64_rename_identity_banked #(
    parameter integer ARCH_ADDR_WIDTH = 5,
    parameter integer ARCH_REG_COUNT = 32,
    parameter integer PHYS_ADDR_WIDTH = 5,
    parameter integer PHYS_REG_COUNT = 31
) (
    input  wire [4*ARCH_ADDR_WIDTH-1:0] source_arch_i,
    output wire [4*PHYS_ADDR_WIDTH-1:0] source_phys_o,

    input  wire [1:0]                   destination_valid_i,
    input  wire [2*ARCH_ADDR_WIDTH-1:0] destination_arch_i,
    output wire [2*PHYS_ADDR_WIDTH-1:0] destination_new_phys_o,
    output wire [2*PHYS_ADDR_WIDTH-1:0] destination_old_phys_o
);

    genvar source;
    generate
        for (source = 0; source < 4; source = source + 1) begin : g_source
            wire [ARCH_ADDR_WIDTH-1:0] arch = source_arch_i[
                source*ARCH_ADDR_WIDTH +: ARCH_ADDR_WIDTH];

            assign source_phys_o[
                source*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH] = {
                {(PHYS_ADDR_WIDTH-ARCH_ADDR_WIDTH){1'b0}}, arch
            };
        end
    endgenerate

    genvar lane;
    generate
        for (lane = 0; lane < 2; lane = lane + 1) begin : g_destination
            wire [ARCH_ADDR_WIDTH-1:0] arch = destination_arch_i[
                lane*ARCH_ADDR_WIDTH +: ARCH_ADDR_WIDTH];
            wire [PHYS_ADDR_WIDTH-1:0] identity = {
                {(PHYS_ADDR_WIDTH-ARCH_ADDR_WIDTH){1'b0}}, arch
            };

            assign destination_new_phys_o[
                lane*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH] = identity;
            assign destination_old_phys_o[
                lane*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH] = identity;
        end
    endgenerate

    wire unused_destination_valid = |destination_valid_i;

`ifndef SYNTHESIS
    initial begin
        if (PHYS_ADDR_WIDTH < ARCH_ADDR_WIDTH)
            $fatal(1, "banked identity physical tag is too narrow");
        if (PHYS_REG_COUNT < (ARCH_REG_COUNT - 1))
            $fatal(1, "banked identity has too few physical registers");
        if ((1 << PHYS_ADDR_WIDTH) <= PHYS_REG_COUNT)
            $fatal(1, "banked identity cannot address the physical file");
    end
`endif

endmodule

`endif
