// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// Rough MYD-J7A100T board shell.
//
// This module establishes the physical top-level interface and deliberately
// leaves every stateful peripheral in a safe condition.  It is suitable for
// checking port names and package constraints; it is not a usable OpenRV64
// system and must not be turned into a board bitstream as-is.
//
// The final top will replace the safe assignments below with:
//   - generated 7-series MIG and an AXI/native bridge for DDR3;
//   - an SD/MMC host controller for sd_*;
//   - the existing platform UART for uart_*;
//   - an RGMII MAC, MDIO controller, clock I/O, and reset sequencer for ETH1.
// ETH2 is exposed so it can be held in reset until a second MAC is wanted.

`timescale 1ns/1ps

module openrv64_myd_j7a100t_top (
    input  wire        sys_clk_p,
    input  wire        sys_clk_n,
    input  wire        rst_n,

    input  wire        uart_rx_i,
    output wire        uart_tx_o,

    input  wire        sd_cd_n_i,
    output wire        sd_clk_o,
    inout  wire        sd_cmd_io,
    inout  wire [3:0]  sd_dat_io,

    input  wire        eth1_rgmii_rx_clk_i,
    input  wire [3:0]  eth1_rgmii_rxd_i,
    input  wire        eth1_rgmii_rx_dv_i,
    output wire        eth1_rgmii_tx_clk_o,
    output wire [3:0]  eth1_rgmii_txd_o,
    output wire        eth1_rgmii_tx_en_o,
    output wire        eth1_mdc_o,
    inout  wire        eth1_mdio_io,
    output wire        eth1_phy_reset_n_o,

    input  wire        eth2_rgmii_rx_clk_i,
    input  wire [3:0]  eth2_rgmii_rxd_i,
    input  wire        eth2_rgmii_rx_dv_i,
    output wire        eth2_rgmii_tx_clk_o,
    output wire [3:0]  eth2_rgmii_txd_o,
    output wire        eth2_rgmii_tx_en_o,
    output wire        eth2_mdc_o,
    inout  wire        eth2_mdio_io,
    output wire        eth2_phy_reset_n_o,

    inout  wire [31:0] ddr3_dq,
    inout  wire [3:0]  ddr3_dqs_n,
    inout  wire [3:0]  ddr3_dqs_p,
    output wire [13:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_reset_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_cke,
    output wire [0:0]  ddr3_cs_n,
    output wire [3:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt
);

    // Preserve the differential board-clock input structure in this shell so
    // Vivado can validate R4 and its complementary package pin as a pair.
    wire sys_clk_200m;
    (* DONT_TOUCH = "TRUE" *)
    IBUFDS #(
        .DIFF_TERM("FALSE"),
        .IBUF_LOW_PWR("TRUE"),
        .IOSTANDARD("DIFF_SSTL15")
    ) u_sys_clk_ibuf (
        .I(sys_clk_p),
        .IB(sys_clk_n),
        .O(sys_clk_200m)
    );

    // Useful before the SoC is connected: the USB-UART path is a transparent
    // electrical loopback.  This must become the platform UART TX signal.
    assign uart_tx_o = uart_rx_i;

    // Release no SD bus driver until an SD/MMC controller is present.
    assign sd_clk_o = 1'b0;
    assign sd_cmd_io = 1'bz;
    assign sd_dat_io = 4'bzzzz;

    // Hold both PHYs in reset and leave MDIO undriven.  The functional top
    // should release ETH1 only after its reference/management clocks are
    // stable and the board-specific minimum reset time has elapsed.
    assign eth1_rgmii_tx_clk_o = 1'b0;
    assign eth1_rgmii_txd_o = 4'b0000;
    assign eth1_rgmii_tx_en_o = 1'b0;
    assign eth1_mdc_o = 1'b0;
    assign eth1_mdio_io = 1'bz;
    assign eth1_phy_reset_n_o = 1'b0;

    assign eth2_rgmii_tx_clk_o = 1'b0;
    assign eth2_rgmii_txd_o = 4'b0000;
    assign eth2_rgmii_tx_en_o = 1'b0;
    assign eth2_mdc_o = 1'b0;
    assign eth2_mdio_io = 1'bz;
    assign eth2_phy_reset_n_o = 1'b0;

    // Keep DDR3 inert until MIG owns these pins.  In particular, assert the
    // DRAM reset and do not attempt to infer a DDR PHY from generic RTL.
    assign ddr3_dq = 32'hzzzz_zzzz;
    assign ddr3_dqs_n = 4'bzzzz;
    assign ddr3_dqs_p = 4'bzzzz;
    assign ddr3_addr = 14'h0000;
    assign ddr3_ba = 3'b000;
    assign ddr3_ras_n = 1'b1;
    assign ddr3_cas_n = 1'b1;
    assign ddr3_we_n = 1'b1;
    assign ddr3_reset_n = 1'b0;
    assign ddr3_ck_p = 1'b0;
    assign ddr3_ck_n = 1'b0;
    assign ddr3_cke = 1'b0;
    assign ddr3_cs_n = 1'b1;
    assign ddr3_dm = 4'b0000;
    assign ddr3_odt = 1'b0;

endmodule
