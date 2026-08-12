# SPDX-License-Identifier: CERN-OHL-P-2.0

set script_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $script_dir ../../..]]
set report_dir [file join $repo_root build fpga xc7a100t io-check]
set top_name openrv64_myd_j7a100t_top
set part_name xc7a100tfgg484-2

file mkdir $report_dir
set_msg_config -id {Synth 8-3917} -suppress
set_msg_config -id {Synth 8-7129} -suppress

read_verilog -sv [file join $script_dir ${top_name}.sv]
synth_design -rtl -top $top_name -part $part_name
read_xdc [file join $script_dir myd_j7a100t.xdc]

set missing_pin_ports [get_ports -quiet -filter {PACKAGE_PIN == ""}]
set default_io_ports [get_ports -quiet -filter {IOSTANDARD == "DEFAULT"}]

if {[llength $missing_pin_ports] != 0} {
    error "ports without PACKAGE_PIN: $missing_pin_ports"
}
if {[llength $default_io_ports] != 0} {
    error "ports with DEFAULT IOSTANDARD: $default_io_ports"
}

set io_checks [get_drc_checks {NSTD-1 UCIO-1 BIVC-1}]
report_io -file [file join $report_dir io.rpt]
report_clocks -file [file join $report_dir clocks.rpt]
report_drc -checks $io_checks -file [file join $report_dir drc.rpt]

set io_violations [get_drc_violations -quiet {
    NSTD-1#* UCIO-1#* BIVC-1#*
}]
if {[llength $io_violations] != 0} {
    error "I/O DRC violations: $io_violations"
}

puts "OPENRV64 MYD-J7A100T IO CHECK PASS: [llength [get_ports]] ports"
puts "Reports: $report_dir"
