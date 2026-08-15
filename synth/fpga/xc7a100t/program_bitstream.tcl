# SPDX-License-Identifier: CERN-OHL-P-2.0

if {$argc != 2} {
    error "usage: vivado -mode batch -source program_bitstream.tcl -tclargs SERVER_URL BITFILE"
}

set server_url [lindex $argv 0]
set bitfile [file normalize [lindex $argv 1]]
set expected_part "xc7a100t"

if {![file isfile $bitfile]} {
    error "bitstream not found: $bitfile"
}

puts "OPENRV64 PROGRAM: connecting to $server_url"
open_hw_manager
connect_hw_server -url $server_url

set targets [get_hw_targets -quiet]
if {[llength $targets] != 1} {
    error "expected exactly one JTAG target, found [llength $targets]: $targets"
}

set target [lindex $targets 0]
current_hw_target $target
open_hw_target

set devices [get_hw_devices -quiet -filter "PART == $expected_part"]
if {[llength $devices] != 1} {
    error "expected exactly one $expected_part, found [llength $devices]: $devices"
}

set device [lindex $devices 0]
current_hw_device $device
refresh_hw_device -update_hw_probes false $device

puts "OPENRV64 PROGRAM: target=$target device=$device part=[get_property PART $device]"
puts "OPENRV64 PROGRAM: bitstream=$bitfile"
set_property PROGRAM.FILE $bitfile $device
program_hw_devices $device
refresh_hw_device -update_hw_probes false $device
puts "OPENRV64 FPGA PROGRAM PASS"

close_hw_target
disconnect_hw_server
close_hw_manager
