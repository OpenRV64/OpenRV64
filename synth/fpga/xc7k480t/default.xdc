# SPDX-License-Identifier: CERN-OHL-P-2.0
#
# Generic out-of-context constraint for an OpenRV64 core on a Kintex-7
# XC7K480T. There is intentionally no pinout here: package pins and I/O
# standards belong to a specific board, not to the FPGA device.

create_clock -name core_clk -period 20.000 [get_ports clk]
set_clock_uncertainty 0.250 [get_clocks core_clk]
