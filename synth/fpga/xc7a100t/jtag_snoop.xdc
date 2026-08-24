# SPDX-License-Identifier: CERN-OHL-P-2.0
#
# USER1 is driven by the external JTAG cable, not by a fabric clock. Model the
# gated data-register clock and Update-DR pulse independently at 10 MHz. The
# transport protocol holds payloads stable across Update-DR, and all crossings
# into the SoC use explicit synchronizers, so the two JTAG clocks and the
# functional clocks are intentionally asynchronous timing groups.

set jtag_bscan_cells [get_cells -hier -filter {REF_NAME == BSCANE2}]
set jtag_drck_pin [get_pins -of_objects $jtag_bscan_cells \
    -filter {REF_PIN_NAME == DRCK}]
set jtag_update_pin [get_pins -of_objects $jtag_bscan_cells \
    -filter {REF_PIN_NAME == UPDATE}]
create_clock -name jtag_user1_drck -period 100.000 $jtag_drck_pin
create_clock -name jtag_user1_update -period 100.000 $jtag_update_pin

set jtag_non_user_clocks \
    [get_clocks -quiet -filter {NAME !~ jtag_user1_*}]
set_clock_groups -asynchronous \
    -group [get_clocks jtag_user1_drck] \
    -group [get_clocks jtag_user1_update] \
    -group $jtag_non_user_clocks
