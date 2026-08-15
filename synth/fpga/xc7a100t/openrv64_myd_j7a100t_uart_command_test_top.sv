// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// MYD-J7A100T UART receive/command-response test.

`timescale 1ns/1ps

module openrv64_myd_j7a100t_uart_command_test_top (
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

    wire sys_clk_200m_unbuffered;
    wire sys_clk_200m;

    IBUFDS #(
        .DIFF_TERM("FALSE"),
        .IBUF_LOW_PWR("TRUE"),
        .IOSTANDARD("DIFF_SSTL15")
    ) u_sys_clk_ibuf (
        .I(sys_clk_p),
        .IB(sys_clk_n),
        .O(sys_clk_200m_unbuffered)
    );

    BUFG u_sys_clk_bufg (
        .I(sys_clk_200m_unbuffered),
        .O(sys_clk_200m)
    );

    logic [1:0] reset_sync_q = 2'b00;
    always_ff @(posedge sys_clk_200m or negedge rst_n) begin
        if (!rst_n) begin
            reset_sync_q <= 2'b00;
        end else begin
            reset_sync_q <= {reset_sync_q[0], 1'b1};
        end
    end
    wire reset_200m = !reset_sync_q[1];

    openrv64_fpga_uart_command #(
        .CLOCK_HZ(200_000_000),
        .BAUD(115_200),
        .FIRST_DELAY_CYCLES(20_000_000)
    ) u_command (
        .clk_i(sys_clk_200m),
        .reset_i(reset_200m),
        .rx_i(uart_rx_i),
        .tx_o(uart_tx_o)
    );

    assign sd_clk_o = 1'b0;
    assign sd_cmd_io = 1'bz;
    assign sd_dat_io = 4'bzzzz;

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

    assign ddr3_dq = 32'hzzzz_zzzz;
    assign ddr3_dqs_n = 4'bzzzz;
    assign ddr3_dqs_p = 4'bzzzz;
    assign ddr3_addr = 14'h0000;
    assign ddr3_ba = 3'b000;
    assign ddr3_ras_n = 1'b1;
    assign ddr3_cas_n = 1'b1;
    assign ddr3_we_n = 1'b1;
    assign ddr3_reset_n = 1'b0;

    OBUFDS #(
        .IOSTANDARD("DIFF_SSTL15"),
        .SLEW("SLOW")
    ) u_ddr3_ck_obuf (
        .I(1'b0),
        .O(ddr3_ck_p[0]),
        .OB(ddr3_ck_n[0])
    );

    assign ddr3_cke = 1'b0;
    assign ddr3_cs_n = 1'b1;
    assign ddr3_dm = 4'b0000;
    assign ddr3_odt = 1'b0;

    wire unused_inputs = &{
        1'b0,
        sd_cd_n_i,
        eth1_rgmii_rx_clk_i,
        eth1_rgmii_rxd_i,
        eth1_rgmii_rx_dv_i,
        eth2_rgmii_rx_clk_i,
        eth2_rgmii_rxd_i,
        eth2_rgmii_rx_dv_i
    };

endmodule
