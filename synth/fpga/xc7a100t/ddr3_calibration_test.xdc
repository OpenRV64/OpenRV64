# SPDX-License-Identifier: CERN-OHL-P-2.0
#
# Non-DDR board constraints for the MIG calibration test.  The generated MIG
# XDC owns every DDR3 pin and all controller placement/timing constraints.

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLNONE [current_design]

set_property PACKAGE_PIN R4 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_p]
create_clock -name sys_clk_200m -period 5.000 [get_ports sys_clk_p]

set_property PACKAGE_PIN P17 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
set_property PULLUP true [get_ports rst_n]

set_property PACKAGE_PIN T18 [get_ports uart_tx_o]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx_o]
set_property DRIVE 8 [get_ports uart_tx_o]
set_property SLEW SLOW [get_ports uart_tx_o]

set_property PACKAGE_PIN Y22 [get_ports eth1_phy_reset_n_o]
set_property PACKAGE_PIN AB20 [get_ports eth2_phy_reset_n_o]
set_property IOSTANDARD LVCMOS33 [get_ports {
    eth1_phy_reset_n_o eth2_phy_reset_n_o
}]
set_property DRIVE 8 [get_ports {
    eth1_phy_reset_n_o eth2_phy_reset_n_o
}]
set_property SLEW SLOW [get_ports {
    eth1_phy_reset_n_o eth2_phy_reset_n_o
}]

# rst_n only asynchronously asserts the input-clock reset-hold register.
set_false_path -from [get_ports rst_n]

# The USB-UART receiver is asynchronous to the 200 MHz board clock.
set_false_path -to [get_ports uart_tx_o]
