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

# microSD socket in SPI mode: CMD=MOSI, DAT0=MISO, DAT3=CS_n.  DAT1 and DAT2
# remain high-impedance in the top-level wrapper.
set_property PACKAGE_PIN AA19 [get_ports sd_cd_n_i]
set_property PACKAGE_PIN V20 [get_ports sd_clk_o]
set_property PACKAGE_PIN Y21 [get_ports sd_cmd_o]
set_property PACKAGE_PIN P19 [get_ports sd_dat0_i]
set_property PACKAGE_PIN U18 [get_ports sd_dat3_o]
set_property IOSTANDARD LVCMOS33 [get_ports {
    sd_cd_n_i sd_clk_o sd_cmd_o sd_dat0_i sd_dat3_o
}]
set_property PULLUP true [get_ports {
    sd_cd_n_i sd_dat0_i
}]
set_property DRIVE 8 [get_ports {sd_clk_o sd_cmd_o sd_dat3_o}]
set_property SLEW FAST [get_ports {sd_clk_o sd_cmd_o sd_dat3_o}]

# In fast mode the card launches MISO after the preceding SCK falling edge and
# the controller samples it one 9.216 MHz core cycle later.  Reserve 50 ns of
# the 108.507 ns cycle for card clock-to-out and PCB delay.
set sd_core_clock [get_clocks -quiet -of_objects \
    [get_pins u_core_mmcm/CLKOUT0]]
set_input_delay -clock $sd_core_clock -max 50.000 \
    [get_ports sd_dat0_i]
set_input_delay -clock $sd_core_clock -min 0.000 \
    [get_ports sd_dat0_i]
set_output_delay -clock $sd_core_clock -max 50.000 \
    [get_ports {sd_cmd_o sd_dat3_o}]
set_output_delay -clock $sd_core_clock -min 0.000 \
    [get_ports {sd_cmd_o sd_dat3_o}]

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
set_false_path -from [get_ports sd_cd_n_i]
# SCK is a divided, software-gated data output rather than a fabric clock.
set_false_path -to [get_ports sd_clk_o]
# The MIG reset output is an asynchronous board control, not sampled data.
set_false_path -to [get_ports ddr3_reset_n]

# The 9.216 MHz core and 100 MHz MIG UI communicate only through the
# single-entry toggle mailbox. Its payload is held stable until the matching
# response returns; the two toggle synchronizers carry the event ordering.
set_clock_groups -asynchronous \
    -group [get_clocks -quiet -of_objects [get_pins u_core_mmcm/CLKOUT0]] \
    -group [get_clocks -quiet clk_pll_i]
