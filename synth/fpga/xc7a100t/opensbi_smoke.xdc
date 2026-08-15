# SPDX-License-Identifier: CERN-OHL-P-2.0
#
# Non-DDR constraints for the one-pipe OpenSBI smoke image. The regenerated
# board-supplied MIG owns DDR3 I/O, placement, and PHY timing constraints.

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

set_property PACKAGE_PIN R18 [get_ports uart_rx_i]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx_i]
set_property PULLUP true [get_ports uart_rx_i]

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

set_false_path -from [get_ports rst_n]
set_false_path -from [get_ports uart_rx_i]
set_false_path -to [get_ports uart_tx_o]

# The 9.216 MHz core and 100 MHz MIG UI communicate only through the
# single-entry toggle mailbox. Its payload is held stable until the matching
# response returns; the two toggle synchronizers carry the event ordering.
set_clock_groups -asynchronous \
    -group [get_clocks -quiet -of_objects [get_pins u_core_mmcm/CLKOUT0]] \
    -group [get_clocks -quiet clk_pll_i]
