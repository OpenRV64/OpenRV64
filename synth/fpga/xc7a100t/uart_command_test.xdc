# SPDX-License-Identifier: CERN-OHL-P-2.0
#
# Intentional asynchronous interfaces in the UART command test.

# rst_n asynchronously asserts only the first two reset synchronizer flops;
# its release is sampled through the 200 MHz synchronizer.
set_false_path -from [get_ports rst_n]

# The remote USB-UART has no clock relationship with the board clock.  RX is
# synchronized before mid-bit sampling; TX timing comes from a clocked divider.
set_false_path -from [get_ports uart_rx_i]
set_false_path -to [get_ports uart_tx_o]
