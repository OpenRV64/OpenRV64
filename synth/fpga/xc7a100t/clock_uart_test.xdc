# SPDX-License-Identifier: CERN-OHL-P-2.0
#
# Intentional asynchronous interfaces in the clock/reset/UART test.

# rst_n asynchronously asserts only the first two reset synchronizer flops;
# its release is sampled through the 200 MHz synchronizer.
set_false_path -from [get_ports rst_n]

# UART is asynchronous to the remote USB-UART receiver.  Baud timing is
# defined by the registered 200 MHz divider, not by an external source clock.
set_false_path -to [get_ports uart_tx_o]
