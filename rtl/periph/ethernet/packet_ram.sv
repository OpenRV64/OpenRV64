// SPDX-License-Identifier: CERN-OHL-P-2.0

`timescale 1ns/1ps

// 8 KiB true-dual-port packet RAM.  The Xilinx implementation is explicit so
// a second write clock cannot make synthesis expand packet storage into LUTs
// or flip-flops.  Generic simulation retains an equivalent behavioral model.
module openrv64_ethernet_packet_ram (
    input  wire        a_clk_i,
    input  wire        a_enable_i,
    input  wire [7:0]  a_write_enable_i,
    input  wire [9:0]  a_addr_i,
    input  wire [63:0] a_wdata_i,
    output wire [63:0] a_rdata_o,

    input  wire        b_clk_i,
    input  wire        b_enable_i,
    input  wire [7:0]  b_write_enable_i,
    input  wire [9:0]  b_addr_i,
    input  wire [63:0] b_wdata_i,
    output wire [63:0] b_rdata_o
);

`ifdef OPENRV64_XILINX_PACKET_RAM
    wire [15:0] a_primitive_addr = {1'b1, a_addr_i, 5'b11111};
    wire [15:0] b_primitive_addr = {1'b1, b_addr_i, 5'b11111};

    RAMB36E1 #(
        .DOA_REG(0),
        .DOB_REG(0),
        .EN_ECC_READ("FALSE"),
        .EN_ECC_WRITE("FALSE"),
        .RAM_MODE("TDP"),
        .READ_WIDTH_A(36),
        .READ_WIDTH_B(36),
        .SIM_COLLISION_CHECK("NONE"),
        .SIM_DEVICE("7SERIES"),
        .WRITE_MODE_A("READ_FIRST"),
        .WRITE_MODE_B("READ_FIRST"),
        .WRITE_WIDTH_A(36),
        .WRITE_WIDTH_B(36)
    ) u_low (
        .DOADO(a_rdata_o[31:0]),
        .DOBDO(b_rdata_o[31:0]),
        .DOPADOP(),
        .DOPBDOP(),
        .CASCADEOUTA(),
        .CASCADEOUTB(),
        .DBITERR(),
        .ECCPARITY(),
        .RDADDRECC(),
        .SBITERR(),
        .ADDRARDADDR(a_primitive_addr),
        .ADDRBWRADDR(b_primitive_addr),
        .CLKARDCLK(a_clk_i),
        .CLKBWRCLK(b_clk_i),
        .DIADI(a_wdata_i[31:0]),
        .DIBDI(b_wdata_i[31:0]),
        .DIPADIP(4'd0),
        .DIPBDIP(4'd0),
        .ENARDEN(a_enable_i),
        .ENBWREN(b_enable_i),
        .WEA(a_write_enable_i[3:0]),
        .WEBWE({4'd0, b_write_enable_i[3:0]}),
        .CASCADEINA(1'b0),
        .CASCADEINB(1'b0),
        .INJECTDBITERR(1'b0),
        .INJECTSBITERR(1'b0),
        .REGCEAREGCE(1'b0),
        .REGCEB(1'b0),
        .RSTRAMARSTRAM(1'b0),
        .RSTRAMB(1'b0),
        .RSTREGARSTREG(1'b0),
        .RSTREGB(1'b0)
    );

    RAMB36E1 #(
        .DOA_REG(0),
        .DOB_REG(0),
        .EN_ECC_READ("FALSE"),
        .EN_ECC_WRITE("FALSE"),
        .RAM_MODE("TDP"),
        .READ_WIDTH_A(36),
        .READ_WIDTH_B(36),
        .SIM_COLLISION_CHECK("NONE"),
        .SIM_DEVICE("7SERIES"),
        .WRITE_MODE_A("READ_FIRST"),
        .WRITE_MODE_B("READ_FIRST"),
        .WRITE_WIDTH_A(36),
        .WRITE_WIDTH_B(36)
    ) u_high (
        .DOADO(a_rdata_o[63:32]),
        .DOBDO(b_rdata_o[63:32]),
        .DOPADOP(),
        .DOPBDOP(),
        .CASCADEOUTA(),
        .CASCADEOUTB(),
        .DBITERR(),
        .ECCPARITY(),
        .RDADDRECC(),
        .SBITERR(),
        .ADDRARDADDR(a_primitive_addr),
        .ADDRBWRADDR(b_primitive_addr),
        .CLKARDCLK(a_clk_i),
        .CLKBWRCLK(b_clk_i),
        .DIADI(a_wdata_i[63:32]),
        .DIBDI(b_wdata_i[63:32]),
        .DIPADIP(4'd0),
        .DIPBDIP(4'd0),
        .ENARDEN(a_enable_i),
        .ENBWREN(b_enable_i),
        .WEA(a_write_enable_i[7:4]),
        .WEBWE({4'd0, b_write_enable_i[7:4]}),
        .CASCADEINA(1'b0),
        .CASCADEINB(1'b0),
        .INJECTDBITERR(1'b0),
        .INJECTSBITERR(1'b0),
        .REGCEAREGCE(1'b0),
        .REGCEB(1'b0),
        .RSTRAMARSTRAM(1'b0),
        .RSTRAMB(1'b0),
        .RSTREGARSTREG(1'b0),
        .RSTREGB(1'b0)
    );
`else
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [63:0] memory [0:1023];
    reg [63:0] a_rdata_q;
    reg [63:0] b_rdata_q;
    integer a_byte_index;
    integer b_byte_index;

    always @(posedge a_clk_i) begin
        if (a_enable_i) begin
            a_rdata_q <= memory[a_addr_i];
            for (a_byte_index = 0; a_byte_index < 8;
                 a_byte_index = a_byte_index + 1)
                if (a_write_enable_i[a_byte_index])
                    memory[a_addr_i][8*a_byte_index +: 8] <=
                        a_wdata_i[8*a_byte_index +: 8];
        end
    end

    always @(posedge b_clk_i) begin
        if (b_enable_i) begin
            b_rdata_q <= memory[b_addr_i];
            for (b_byte_index = 0; b_byte_index < 8;
                 b_byte_index = b_byte_index + 1)
                if (b_write_enable_i[b_byte_index])
                    memory[b_addr_i][8*b_byte_index +: 8] <=
                        b_wdata_i[8*b_byte_index +: 8];
        end
    end

    assign a_rdata_o = a_rdata_q;
    assign b_rdata_o = b_rdata_q;
`endif

endmodule
