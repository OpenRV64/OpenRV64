`ifndef OPENRV64_RENAME_IDENTITY_V
`define OPENRV64_RENAME_IDENTITY_V

`timescale 1ns/1ps

// Stateless architectural-to-physical rename layer.
//
// This is deliberately an identity implementation, not a partial dynamic
// renamer.  It establishes physical-tag interfaces and ROB identities while
// preserving the current machine exactly: architectural xN maps to physical
// pN.  A future RAT/free-list implementation can replace this module without
// changing the PRF-facing widths or the retirement record.
module openrv64_rename_identity #(
    parameter integer ARCH_ADDR_WIDTH = 5,
    parameter integer ARCH_REG_COUNT = 32,
    parameter integer PHYS_ADDR_WIDTH = 5,
    parameter integer PHYS_REG_COUNT = 31,
    parameter integer LANES = 3,
    parameter integer SOURCES_PER_LANE = 2
) (
    input  wire [LANES*SOURCES_PER_LANE*ARCH_ADDR_WIDTH-1:0]
                                                source_arch_i,
    output wire [LANES*SOURCES_PER_LANE*PHYS_ADDR_WIDTH-1:0]
                                                source_phys_o,

    input  wire [LANES-1:0]                    destination_valid_i,
    input  wire [LANES*ARCH_ADDR_WIDTH-1:0]    destination_arch_i,
    output wire [LANES*PHYS_ADDR_WIDTH-1:0]    destination_new_phys_o,
    output wire [LANES*PHYS_ADDR_WIDTH-1:0]    destination_old_phys_o
);

    initial begin
        if (PHYS_ADDR_WIDTH < ARCH_ADDR_WIDTH) begin
            $fatal(1,
                "identity rename physical tag is narrower than architectural tag");
        end
        if (PHYS_REG_COUNT < (ARCH_REG_COUNT - 1)) begin
            $fatal(1,
                "identity rename has fewer writable physical registers than architectural registers");
        end
        if ((1 << PHYS_ADDR_WIDTH) <= PHYS_REG_COUNT) begin
            $fatal(1, "identity rename physical tag cannot address the PRF");
        end
    end

    genvar source;
    generate
        for (source = 0; source < LANES*SOURCES_PER_LANE;
             source = source + 1) begin : g_source
            wire [ARCH_ADDR_WIDTH-1:0] arch =
                source_arch_i[source*ARCH_ADDR_WIDTH +: ARCH_ADDR_WIDTH];
            assign source_phys_o[
                source*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH] = {
                {(PHYS_ADDR_WIDTH-ARCH_ADDR_WIDTH){1'b0}}, arch
            };
        end
    endgenerate

    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : g_destination
            wire [ARCH_ADDR_WIDTH-1:0] arch =
                destination_arch_i[lane*ARCH_ADDR_WIDTH +: ARCH_ADDR_WIDTH];
            wire [PHYS_ADDR_WIDTH-1:0] identity = {
                {(PHYS_ADDR_WIDTH-ARCH_ADDR_WIDTH){1'b0}}, arch
            };
            wire [PHYS_ADDR_WIDTH-1:0] selected =
                destination_valid_i[lane] ? identity :
                {PHYS_ADDR_WIDTH{1'b0}};

            assign destination_new_phys_o[
                lane*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH] = selected;
            assign destination_old_phys_o[
                lane*PHYS_ADDR_WIDTH +: PHYS_ADDR_WIDTH] = selected;
        end
    endgenerate

endmodule

`endif
