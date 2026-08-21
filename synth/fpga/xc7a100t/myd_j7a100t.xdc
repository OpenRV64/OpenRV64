# SPDX-License-Identifier: CERN-OHL-P-2.0
#
# MYIR MYD-J7A100T-32Q512D-I board-level constraints.
# Target device: XC7A100T-2FGG484I (Vivado: xc7a100tfgg484-2).
#
# This file is an independently authored transcription of package-pin and
# voltage facts.  It contains no vendor HDL, generated IP, or generated MIG
# timing/placement constraints.  Sources used to verify the facts:
#
#   - MYIR MYC-J7A100T Pinouts Description, version 1.0, 2024-04-17:
#     UART, microSD, and both copper Ethernet RGMII interfaces.
#   - The user-supplied MYIR 07_ddr_test project:
#     system clock/reset and DDR3 package pins.
#
# The generated MIG XDC must still supply the controller's internal placement
# and timing constraints.  RGMII input/output delays also remain deliberately
# absent until the PHY model and its strapped internal-delay mode are verified.

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]

# 200 MHz differential system oscillator.  R4 is the positive package pin;
# Vivado assigns the complementary pin through the differential input buffer.
set_property PACKAGE_PIN R4 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_p]
create_clock -name sys_clk_200m -period 5.000 [get_ports sys_clk_p]

# KEY_2 is used as the active-low board reset.
set_property PACKAGE_PIN P15 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
set_property PULLUP true [get_ports rst_n]

# USB-to-UART remote console.  DEBUG_RXD is received by the FPGA and DEBUG_TXD
# is transmitted by the FPGA.  Both are explicitly 3.3 V LVCMOS.
set_property PACKAGE_PIN R18 [get_ports uart_rx_i]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx_i]
set_property PULLUP true [get_ports uart_rx_i]

set_property PACKAGE_PIN T18 [get_ports uart_tx_o]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx_o]
set_property DRIVE 8 [get_ports uart_tx_o]
set_property SLEW SLOW [get_ports uart_tx_o]

# microSD / TF socket, native one-bit or four-bit SD mode.
set_property PACKAGE_PIN AA19 [get_ports sd_cd_n_i]
set_property PACKAGE_PIN V20 [get_ports sd_clk_o]
set_property PACKAGE_PIN Y21 [get_ports sd_cmd_io]
set_property PACKAGE_PIN P19 [get_ports {sd_dat_io[0]}]
set_property PACKAGE_PIN R19 [get_ports {sd_dat_io[1]}]
set_property PACKAGE_PIN U17 [get_ports {sd_dat_io[2]}]
set_property PACKAGE_PIN U18 [get_ports {sd_dat_io[3]}]

set_property IOSTANDARD LVCMOS33 [get_ports {
    sd_cd_n_i sd_clk_o sd_cmd_io sd_dat_io[*]
}]
set_property PULLUP true [get_ports {
    sd_cd_n_i sd_cmd_io sd_dat_io[*]
}]
set_property DRIVE 8 [get_ports {sd_clk_o sd_cmd_io sd_dat_io[*]}]
set_property SLEW FAST [get_ports {sd_clk_o sd_cmd_io sd_dat_io[*]}]

# Copper Ethernet port 1.  This is RGMII, not SGMII or XGMII.
set_property PACKAGE_PIN W19 [get_ports eth1_rgmii_rx_clk_i]
set_property PACKAGE_PIN U22 [get_ports {eth1_rgmii_rxd_i[0]}]
set_property PACKAGE_PIN V22 [get_ports {eth1_rgmii_rxd_i[1]}]
set_property PACKAGE_PIN T21 [get_ports {eth1_rgmii_rxd_i[2]}]
set_property PACKAGE_PIN U21 [get_ports {eth1_rgmii_rxd_i[3]}]
set_property PACKAGE_PIN V18 [get_ports eth1_rgmii_rx_dv_i]

set_property PACKAGE_PIN W20 [get_ports eth1_rgmii_tx_clk_o]
set_property PACKAGE_PIN W21 [get_ports {eth1_rgmii_txd_o[0]}]
set_property PACKAGE_PIN W22 [get_ports {eth1_rgmii_txd_o[1]}]
set_property PACKAGE_PIN AA20 [get_ports {eth1_rgmii_txd_o[2]}]
set_property PACKAGE_PIN AA21 [get_ports {eth1_rgmii_txd_o[3]}]
set_property PACKAGE_PIN U20 [get_ports eth1_rgmii_tx_en_o]

set_property PACKAGE_PIN W17 [get_ports eth1_mdc_o]
set_property PACKAGE_PIN V17 [get_ports eth1_mdio_io]
set_property PACKAGE_PIN Y22 [get_ports eth1_phy_reset_n_o]

set_property IOSTANDARD LVCMOS33 [get_ports {
    eth1_rgmii_rx_clk_i eth1_rgmii_rxd_i[*] eth1_rgmii_rx_dv_i
    eth1_rgmii_tx_clk_o eth1_rgmii_txd_o[*] eth1_rgmii_tx_en_o
    eth1_mdc_o eth1_mdio_io eth1_phy_reset_n_o
}]
set_property DRIVE 8 [get_ports {
    eth1_rgmii_tx_clk_o eth1_rgmii_txd_o[*] eth1_rgmii_tx_en_o
    eth1_mdc_o eth1_mdio_io eth1_phy_reset_n_o
}]
set_property SLEW FAST [get_ports {
    eth1_rgmii_tx_clk_o eth1_rgmii_txd_o[*] eth1_rgmii_tx_en_o
}]
set_property SLEW SLOW [get_ports {
    eth1_mdc_o eth1_mdio_io eth1_phy_reset_n_o
}]
set_property PULLUP true [get_ports eth1_mdio_io]
create_clock -name eth1_rgmii_rx_clk -period 8.000 \
    [get_ports eth1_rgmii_rx_clk_i]

# Copper Ethernet port 2.  It is exposed by the footprint so its reset can be
# controlled; the first functional OpenRV64 top is expected to use port 1 only.
set_property PACKAGE_PIN Y18 [get_ports eth2_rgmii_rx_clk_i]
set_property PACKAGE_PIN AB21 [get_ports {eth2_rgmii_rxd_i[0]}]
set_property PACKAGE_PIN AB22 [get_ports {eth2_rgmii_rxd_i[1]}]
set_property PACKAGE_PIN AA18 [get_ports {eth2_rgmii_rxd_i[2]}]
set_property PACKAGE_PIN AB18 [get_ports {eth2_rgmii_rxd_i[3]}]
set_property PACKAGE_PIN V19 [get_ports eth2_rgmii_rx_dv_i]

set_property PACKAGE_PIN Y19 [get_ports eth2_rgmii_tx_clk_o]
set_property PACKAGE_PIN N13 [get_ports {eth2_rgmii_txd_o[0]}]
set_property PACKAGE_PIN N14 [get_ports {eth2_rgmii_txd_o[1]}]
set_property PACKAGE_PIN P16 [get_ports {eth2_rgmii_txd_o[2]}]
set_property PACKAGE_PIN R17 [get_ports {eth2_rgmii_txd_o[3]}]
set_property PACKAGE_PIN P20 [get_ports eth2_rgmii_tx_en_o]

set_property PACKAGE_PIN R14 [get_ports eth2_mdc_o]
set_property PACKAGE_PIN P14 [get_ports eth2_mdio_io]
set_property PACKAGE_PIN AB20 [get_ports eth2_phy_reset_n_o]

set_property IOSTANDARD LVCMOS33 [get_ports {
    eth2_rgmii_rx_clk_i eth2_rgmii_rxd_i[*] eth2_rgmii_rx_dv_i
    eth2_rgmii_tx_clk_o eth2_rgmii_txd_o[*] eth2_rgmii_tx_en_o
    eth2_mdc_o eth2_mdio_io eth2_phy_reset_n_o
}]
set_property DRIVE 8 [get_ports {
    eth2_rgmii_tx_clk_o eth2_rgmii_txd_o[*] eth2_rgmii_tx_en_o
    eth2_mdc_o eth2_mdio_io eth2_phy_reset_n_o
}]
set_property SLEW FAST [get_ports {
    eth2_rgmii_tx_clk_o eth2_rgmii_txd_o[*] eth2_rgmii_tx_en_o
}]
set_property SLEW SLOW [get_ports {
    eth2_mdc_o eth2_mdio_io eth2_phy_reset_n_o
}]
set_property PULLUP true [get_ports eth2_mdio_io]
create_clock -name eth2_rgmii_rx_clk -period 8.000 \
    [get_ports eth2_rgmii_rx_clk_i]

# DDR3: two MT41J128M16-class x16 components, 32-bit data path, 512 MiB.
# The board XDC owns package locations and electrical standards.  A generated
# MIG XDC must additionally own IDELAYCTRL, byte-lane placement, internal
# false paths, and other implementation constraints.
set_property PACKAGE_PIN V2 [get_ports {ddr3_addr[0]}]
set_property PACKAGE_PIN Y4 [get_ports {ddr3_addr[1]}]
set_property PACKAGE_PIN Y3 [get_ports {ddr3_addr[2]}]
set_property PACKAGE_PIN AB5 [get_ports {ddr3_addr[3]}]
set_property PACKAGE_PIN AB3 [get_ports {ddr3_addr[4]}]
set_property PACKAGE_PIN AA4 [get_ports {ddr3_addr[5]}]
set_property PACKAGE_PIN AA1 [get_ports {ddr3_addr[6]}]
set_property PACKAGE_PIN AA3 [get_ports {ddr3_addr[7]}]
set_property PACKAGE_PIN AB1 [get_ports {ddr3_addr[8]}]
set_property PACKAGE_PIN W2 [get_ports {ddr3_addr[9]}]
set_property PACKAGE_PIN W5 [get_ports {ddr3_addr[10]}]
set_property PACKAGE_PIN W1 [get_ports {ddr3_addr[11]}]
set_property PACKAGE_PIN AB6 [get_ports {ddr3_addr[12]}]
set_property PACKAGE_PIN Y2 [get_ports {ddr3_addr[13]}]

set_property PACKAGE_PIN AA5 [get_ports {ddr3_ba[0]}]
set_property PACKAGE_PIN W4 [get_ports {ddr3_ba[1]}]
set_property PACKAGE_PIN AB7 [get_ports {ddr3_ba[2]}]
set_property PACKAGE_PIN Y8 [get_ports ddr3_ras_n]
set_property PACKAGE_PIN AA8 [get_ports ddr3_cas_n]
set_property PACKAGE_PIN AA6 [get_ports ddr3_we_n]
set_property PACKAGE_PIN AB2 [get_ports ddr3_reset_n]
set_property PACKAGE_PIN T5 [get_ports {ddr3_ck_p[0]}]
set_property PACKAGE_PIN U5 [get_ports {ddr3_ck_n[0]}]
set_property PACKAGE_PIN Y9 [get_ports {ddr3_cke[0]}]
set_property PACKAGE_PIN Y7 [get_ports {ddr3_cs_n[0]}]
set_property PACKAGE_PIN AB8 [get_ports {ddr3_odt[0]}]

set_property PACKAGE_PIN M6 [get_ports {ddr3_dm[0]}]
set_property PACKAGE_PIN J4 [get_ports {ddr3_dm[1]}]
set_property PACKAGE_PIN H2 [get_ports {ddr3_dm[2]}]
set_property PACKAGE_PIN B1 [get_ports {ddr3_dm[3]}]

set_property PACKAGE_PIN R1 [get_ports {ddr3_dq[0]}]
set_property PACKAGE_PIN M5 [get_ports {ddr3_dq[1]}]
set_property PACKAGE_PIN P2 [get_ports {ddr3_dq[2]}]
set_property PACKAGE_PIN P6 [get_ports {ddr3_dq[3]}]
set_property PACKAGE_PIN N4 [get_ports {ddr3_dq[4]}]
set_property PACKAGE_PIN N5 [get_ports {ddr3_dq[5]}]
set_property PACKAGE_PIN N2 [get_ports {ddr3_dq[6]}]
set_property PACKAGE_PIN P1 [get_ports {ddr3_dq[7]}]
set_property PACKAGE_PIN L5 [get_ports {ddr3_dq[8]}]
set_property PACKAGE_PIN K3 [get_ports {ddr3_dq[9]}]
set_property PACKAGE_PIN K6 [get_ports {ddr3_dq[10]}]
set_property PACKAGE_PIN J6 [get_ports {ddr3_dq[11]}]
set_property PACKAGE_PIN M2 [get_ports {ddr3_dq[12]}]
set_property PACKAGE_PIN L3 [get_ports {ddr3_dq[13]}]
set_property PACKAGE_PIN M3 [get_ports {ddr3_dq[14]}]
set_property PACKAGE_PIN L4 [get_ports {ddr3_dq[15]}]
set_property PACKAGE_PIN G4 [get_ports {ddr3_dq[16]}]
set_property PACKAGE_PIN G3 [get_ports {ddr3_dq[17]}]
set_property PACKAGE_PIN J5 [get_ports {ddr3_dq[18]}]
set_property PACKAGE_PIN H3 [get_ports {ddr3_dq[19]}]
set_property PACKAGE_PIN H4 [get_ports {ddr3_dq[20]}]
set_property PACKAGE_PIN K1 [get_ports {ddr3_dq[21]}]
set_property PACKAGE_PIN H5 [get_ports {ddr3_dq[22]}]
set_property PACKAGE_PIN G2 [get_ports {ddr3_dq[23]}]
set_property PACKAGE_PIN E2 [get_ports {ddr3_dq[24]}]
set_property PACKAGE_PIN A1 [get_ports {ddr3_dq[25]}]
set_property PACKAGE_PIN G1 [get_ports {ddr3_dq[26]}]
set_property PACKAGE_PIN B2 [get_ports {ddr3_dq[27]}]
set_property PACKAGE_PIN F1 [get_ports {ddr3_dq[28]}]
set_property PACKAGE_PIN C2 [get_ports {ddr3_dq[29]}]
set_property PACKAGE_PIN F3 [get_ports {ddr3_dq[30]}]
set_property PACKAGE_PIN D2 [get_ports {ddr3_dq[31]}]

set_property PACKAGE_PIN P5 [get_ports {ddr3_dqs_p[0]}]
set_property PACKAGE_PIN M1 [get_ports {ddr3_dqs_p[1]}]
set_property PACKAGE_PIN K2 [get_ports {ddr3_dqs_p[2]}]
set_property PACKAGE_PIN E1 [get_ports {ddr3_dqs_p[3]}]
set_property PACKAGE_PIN P4 [get_ports {ddr3_dqs_n[0]}]
set_property PACKAGE_PIN L1 [get_ports {ddr3_dqs_n[1]}]
set_property PACKAGE_PIN J2 [get_ports {ddr3_dqs_n[2]}]
set_property PACKAGE_PIN D1 [get_ports {ddr3_dqs_n[3]}]

set_property IOSTANDARD SSTL15 [get_ports {
    ddr3_addr[*] ddr3_ba[*] ddr3_ras_n ddr3_cas_n ddr3_we_n
    ddr3_cke[*] ddr3_cs_n[*] ddr3_odt[*] ddr3_dm[*] ddr3_dq[*]
}]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {
    ddr3_ck_p[*] ddr3_ck_n[*] ddr3_dqs_p[*] ddr3_dqs_n[*]
}]
set_property IOSTANDARD LVCMOS15 [get_ports ddr3_reset_n]
