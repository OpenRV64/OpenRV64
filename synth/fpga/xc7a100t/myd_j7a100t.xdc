# MYIR MYD-J7A100T / MYC-J7A100T board constraints.
#
# Clock/reset and DDR geometry come from MYIR's 07_ddr_test project. MIG's
# generated XDC owns all DDR3 package pins from the imported .prj file.
# UART pins come from MYIR's MYC-J7A100T-PinList-V1.0.xlsx.

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]

create_clock -name sys_clk_200m -period 5.000 [get_ports sys_clk_p]
set_property -dict {
    PACKAGE_PIN R4
    IOSTANDARD DIFF_SSTL15
} [get_ports sys_clk_p]

set_property -dict {
    PACKAGE_PIN P17
    IOSTANDARD LVCMOS33
} [get_ports rst_n]

# Preserved from MYIR's routed reference design. The on-module R4 oscillator
# path reaches the MMCM over backbone routing rather than a dedicated route.
set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets sys_clk]

# DEBUG_RXD is data received by the FPGA from the carrier's USB-UART bridge.
# DEBUG_TXD is data transmitted by the FPGA to the bridge.

set_property -dict {
    PACKAGE_PIN R18
    IOSTANDARD LVCMOS33
} [get_ports uart_rx_i]

set_property -dict {
    PACKAGE_PIN T18
    IOSTANDARD LVCMOS33
    SLEW SLOW
    DRIVE 8
} [get_ports uart_tx_o]

set_property PULLUP true [get_ports uart_rx_i]
