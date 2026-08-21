// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// MYD-J7A100T one-pipe OpenSBI smoke-test top.

`timescale 1ns/1ps

module openrv64_myd_j7a100t_opensbi_top #(
    parameter ROM_INIT_FILE        = "",
    parameter TRAMPOLINE_INIT_FILE = "trampoline-fpga.mem",
    parameter FIRMWARE_INIT_FILE   = "fw_jump-fpga-head.mem",
    parameter FIRMWARE_TAIL_INIT_FILE = "fw_jump-fpga-tail.mem",
    parameter PAYLOAD_INIT_FILE    = "payload-fpga.mem",
    parameter FDT_INIT_FILE        = "openrv64-dtb-fpga.mem",
    parameter integer TRAMPOLINE_WORDS = 1,
    parameter integer FIRMWARE_WORDS   = 1,
    parameter integer PAYLOAD_WORDS    = 1,
    parameter integer FDT_WORDS        = 1,
    parameter integer SD_ROM_BOOT_ENABLE = 0
) (
    input  wire        sys_clk_p,
    input  wire        sys_clk_n,
    input  wire        rst_n,
    input  wire        uart_rx_i,

    input  wire        sd_cd_n_i,
    output wire        sd_clk_o,
    output wire        sd_cmd_o,
    input  wire        sd_dat0_i,
    output wire        sd_dat3_o,

    output wire        uart_tx_o,
    input  wire        eth1_rgmii_rx_clk_i,
    input  wire [3:0]  eth1_rgmii_rxd_i,
    input  wire        eth1_rgmii_rx_dv_i,
    output wire        eth1_rgmii_tx_clk_o,
    output wire [3:0]  eth1_rgmii_txd_o,
    output wire        eth1_rgmii_tx_en_o,
    output wire        eth1_mdc_o,
    inout  wire        eth1_mdio_io,
    output wire        eth1_phy_reset_n_o,
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

    logic [15:0] reset_hold_q = 16'h0000;
    always_ff @(posedge sys_clk_200m or negedge rst_n) begin
        if (!rst_n)
            reset_hold_q <= 16'h0000;
        else if (!(&reset_hold_q))
            reset_hold_q <= reset_hold_q + 16'd1;
    end

    wire mig_sys_rst_n = &reset_hold_q;
    wire ui_clk;
    wire ui_clk_sync_rst;
    wire init_calib_complete;

    wire [27:0] app_addr;
    wire [2:0] app_cmd;
    wire app_en;
    wire app_rdy;
    wire [255:0] app_wdf_data;
    wire app_wdf_end;
    wire [31:0] app_wdf_mask;
    wire app_wdf_wren;
    wire app_wdf_rdy;
    wire [255:0] app_rd_data;
    wire app_rd_data_end;
    wire app_rd_data_valid;
    wire app_sr_active;
    wire app_ref_ack;
    wire app_zq_ack;
    wire [11:0] device_temp;

    mig_7series_0 u_mig (
        .ddr3_dq(ddr3_dq),
        .ddr3_dqs_n(ddr3_dqs_n),
        .ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_addr(ddr3_addr),
        .ddr3_ba(ddr3_ba),
        .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n),
        .ddr3_we_n(ddr3_we_n),
        .ddr3_reset_n(ddr3_reset_n),
        .ddr3_ck_p(ddr3_ck_p),
        .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cke(ddr3_cke),
        .ddr3_cs_n(ddr3_cs_n),
        .ddr3_dm(ddr3_dm),
        .ddr3_odt(ddr3_odt),
        .sys_clk_i(sys_clk_200m),
        .app_addr(app_addr),
        .app_cmd(app_cmd),
        .app_en(app_en),
        .app_wdf_data(app_wdf_data),
        .app_wdf_end(app_wdf_end),
        .app_wdf_mask(app_wdf_mask),
        .app_wdf_wren(app_wdf_wren),
        .app_rd_data(app_rd_data),
        .app_rd_data_end(app_rd_data_end),
        .app_rd_data_valid(app_rd_data_valid),
        .app_rdy(app_rdy),
        .app_wdf_rdy(app_wdf_rdy),
        .app_sr_req(1'b0),
        .app_ref_req(1'b0),
        .app_zq_req(1'b0),
        .app_sr_active(app_sr_active),
        .app_ref_ack(app_ref_ack),
        .app_zq_ack(app_zq_ack),
        .ui_clk(ui_clk),
        .ui_clk_sync_rst(ui_clk_sync_rst),
        .init_calib_complete(init_calib_complete),
        .device_temp(device_temp),
        .sys_rst(mig_sys_rst_n)
    );

    // 100 MHz * 7 / 50 = exactly 14 MHz.  The platform UART uses a fractional
    // 14.7456 MHz reference so standard divisor eight remains exact 115200.
    wire core_clock_feedback_unbuffered;
    wire core_clock_feedback;
    wire core_clock_unbuffered;
    wire core_clock;
    wire core_clock_locked;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(7.000),
        .CLKIN1_PERIOD(10.000),
        .CLKOUT0_DIVIDE_F(50.000),
        .DIVCLK_DIVIDE(1),
        .STARTUP_WAIT("FALSE")
    ) u_core_mmcm (
        .CLKIN1(ui_clk),
        .CLKFBIN(core_clock_feedback),
        .RST(ui_clk_sync_rst),
        .PWRDWN(1'b0),
        .CLKFBOUT(core_clock_feedback_unbuffered),
        .CLKOUT0(core_clock_unbuffered),
        .LOCKED(core_clock_locked)
    );

    BUFG u_core_feedback_bufg (
        .I(core_clock_feedback_unbuffered),
        .O(core_clock_feedback)
    );

    BUFG u_core_clock_bufg (
        .I(core_clock_unbuffered),
        .O(core_clock)
    );

    // Fixed 100-Mb/s RGMII clocks.  The MAC changes data on the 0-degree
    // 25-MHz edges.  The forwarded clock uses the 90-degree output so the PHY
    // samples in the center of each 20-ns DDR nibble eye.
    wire eth_clock_feedback_unbuffered;
    wire eth_clock_feedback;
    wire eth_tx_clock_unbuffered;
    wire eth_tx_forward_clock_unbuffered;
    wire eth_tx_clock;
    wire eth_tx_forward_clock;
    wire eth_clock_locked;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(10.000),
        .CLKIN1_PERIOD(10.000),
        .CLKOUT0_DIVIDE_F(40.000),
        .CLKOUT0_PHASE(0.000),
        .CLKOUT1_DIVIDE(40),
        .CLKOUT1_PHASE(90.000),
        .DIVCLK_DIVIDE(1),
        .STARTUP_WAIT("FALSE")
    ) u_eth_mmcm (
        .CLKIN1(ui_clk),
        .CLKFBIN(eth_clock_feedback),
        .RST(ui_clk_sync_rst),
        .PWRDWN(1'b0),
        .CLKFBOUT(eth_clock_feedback_unbuffered),
        .CLKOUT0(eth_tx_clock_unbuffered),
        .CLKOUT1(eth_tx_forward_clock_unbuffered),
        .LOCKED(eth_clock_locked)
    );

    BUFG u_eth_feedback_bufg (
        .I(eth_clock_feedback_unbuffered),
        .O(eth_clock_feedback)
    );

    BUFG u_eth_tx_clock_bufg (
        .I(eth_tx_clock_unbuffered),
        .O(eth_tx_clock)
    );

    BUFG u_eth_tx_forward_clock_bufg (
        .I(eth_tx_forward_clock_unbuffered),
        .O(eth_tx_forward_clock)
    );

    wire boot_release;
    wire [63:0] debug_pc;
    wire sd_cd_n_buffered;
    wire sd_dat0_buffered;
    wire spi_clk;
    wire spi_mosi;
    wire spi_cs_n;
    wire [7:0] eth_tx_data;
    wire eth_tx_valid;
    wire eth_tx_error;
    wire eth_rx_clock;
    wire [7:0] eth_rx_data;
    wire eth_rx_valid;
    wire eth_rx_error;
    wire eth_mdio_out;
    wire eth_mdio_output_enable;
    wire eth_mdio_in;
    wire eth_phy_reset_n;

    IBUF u_sd_cd_ibuf (
        .I(sd_cd_n_i),
        .O(sd_cd_n_buffered)
    );

    IBUF u_sd_dat0_ibuf (
        .I(sd_dat0_i),
        .O(sd_dat0_buffered)
    );

    OBUF u_sd_clk_obuf (
        .I(spi_clk),
        .O(sd_clk_o)
    );

    OBUF u_sd_cmd_obuf (
        .I(spi_mosi),
        .O(sd_cmd_o)
    );

    OBUF u_sd_dat3_obuf (
        .I(spi_cs_n),
        .O(sd_dat3_o)
    );

    IOBUF u_eth_mdio_iobuf (
        .I(eth_mdio_out),
        .T(!eth_mdio_output_enable),
        .O(eth_mdio_in),
        .IO(eth1_mdio_io)
    );

    openrv64_series7_rgmii_io u_eth_rgmii_io (
        .tx_clk_i(eth_tx_clock),
        .tx_forward_clk_i(eth_tx_forward_clock),
        .tx_data_i(eth_tx_data),
        .tx_valid_i(eth_tx_valid),
        .tx_error_i(eth_tx_error),
        .rgmii_rx_clk_i(eth1_rgmii_rx_clk_i),
        .rgmii_rxd_i(eth1_rgmii_rxd_i),
        .rgmii_rx_ctl_i(eth1_rgmii_rx_dv_i),
        .rgmii_tx_clk_o(eth1_rgmii_tx_clk_o),
        .rgmii_txd_o(eth1_rgmii_txd_o),
        .rgmii_tx_ctl_o(eth1_rgmii_tx_en_o),
        .rx_clk_o(eth_rx_clock),
        .rx_data_o(eth_rx_data),
        .rx_valid_o(eth_rx_valid),
        .rx_error_o(eth_rx_error)
    );

`ifdef OPENRV64_FPGA_SYSTEM_NETLIST
    (* DONT_TOUCH = "TRUE" *)
    openrv64_fpga_opensbi_system u_system (
`else
    openrv64_fpga_opensbi_system #(
        .ROM_INIT_FILE(ROM_INIT_FILE),
        .TRAMPOLINE_INIT_FILE(TRAMPOLINE_INIT_FILE),
        .FIRMWARE_INIT_FILE(FIRMWARE_INIT_FILE),
        .FIRMWARE_TAIL_INIT_FILE(FIRMWARE_TAIL_INIT_FILE),
        .PAYLOAD_INIT_FILE(PAYLOAD_INIT_FILE),
        .FDT_INIT_FILE(FDT_INIT_FILE),
        .TRAMPOLINE_WORDS(TRAMPOLINE_WORDS),
        .FIRMWARE_WORDS(FIRMWARE_WORDS),
        .PAYLOAD_WORDS(PAYLOAD_WORDS),
        .FDT_WORDS(FDT_WORDS),
        .SD_ROM_BOOT_ENABLE(SD_ROM_BOOT_ENABLE)
    ) u_system (
`endif
        .ui_clk_i(ui_clk),
        .ui_reset_i(ui_clk_sync_rst),
        .calib_complete_i(init_calib_complete),
        .core_clk_i(core_clock),
        .core_clock_locked_i(core_clock_locked && eth_clock_locked),
        .uart_rx_i(uart_rx_i),
        .uart_tx_o(uart_tx_o),
        .spi_card_present_i(!sd_cd_n_buffered),
        .spi_clk_o(spi_clk),
        .spi_mosi_o(spi_mosi),
        .spi_miso_i(sd_dat0_buffered),
        .spi_cs_n_o(spi_cs_n),
        .eth_tx_clk_i(eth_tx_clock),
        .eth_tx_data_o(eth_tx_data),
        .eth_tx_valid_o(eth_tx_valid),
        .eth_tx_error_o(eth_tx_error),
        .eth_rx_clk_i(eth_rx_clock),
        .eth_rx_data_i(eth_rx_data),
        .eth_rx_valid_i(eth_rx_valid),
        .eth_rx_error_i(eth_rx_error),
        .eth_mdc_o(eth1_mdc_o),
        .eth_mdio_o(eth_mdio_out),
        .eth_mdio_oe_o(eth_mdio_output_enable),
        .eth_mdio_i(eth_mdio_in),
        .eth_phy_reset_no(eth_phy_reset_n),
        .boot_release_o(boot_release),
        .debug_pc_o(debug_pc),
        .app_addr_o(app_addr),
        .app_cmd_o(app_cmd),
        .app_en_o(app_en),
        .app_rdy_i(app_rdy),
        .app_wdf_data_o(app_wdf_data),
        .app_wdf_end_o(app_wdf_end),
        .app_wdf_mask_o(app_wdf_mask),
        .app_wdf_wren_o(app_wdf_wren),
        .app_wdf_rdy_i(app_wdf_rdy),
        .app_rd_data_i(app_rd_data),
        .app_rd_data_end_i(app_rd_data_end),
        .app_rd_data_valid_i(app_rd_data_valid)
    );

    assign eth1_phy_reset_n_o = eth_phy_reset_n;
    assign eth2_phy_reset_n_o = 1'b0;

    wire unused_status = &{
        1'b0,
        app_sr_active,
        app_ref_ack,
        app_zq_ack,
        device_temp,
        boot_release,
        debug_pc
    };

endmodule
