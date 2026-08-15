# SPDX-License-Identifier: CERN-OHL-P-2.0

set script_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $script_dir ../../..]]
set output_dir [file join $repo_root build fpga xc7a100t clock-uart-test]
set top_name openrv64_myd_j7a100t_clock_uart_test_top
set part_name xc7a100tfgg484-2

file mkdir $output_dir
set_param general.maxThreads 8

read_verilog -sv [file join $script_dir uart_banner.sv]
read_verilog -sv [file join $script_dir ${top_name}.sv]
read_xdc [file join $script_dir myd_j7a100t.xdc]
read_xdc [file join $script_dir clock_uart_test.xdc]

synth_design -top $top_name -part $part_name -flatten_hierarchy rebuilt
write_checkpoint -force [file join $output_dir post_synth.dcp]
report_utilization -file [file join $output_dir post_synth_utilization.rpt]

opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force [file join $output_dir post_route.dcp]
report_route_status -file [file join $output_dir route_status.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file [file join $output_dir timing_summary.rpt]
report_utilization -file [file join $output_dir utilization.rpt]
report_drc -file [file join $output_dir drc.rpt]

set setup_path [get_timing_paths -quiet -delay_type max -max_paths 1]
if {[llength $setup_path] == 0} {
    error "no setup timing path found"
}
set setup_slack [get_property SLACK [lindex $setup_path 0]]
if {$setup_slack < 0.0} {
    error "setup timing failed: WNS=$setup_slack ns"
}

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force [file join $output_dir ${top_name}.bit]

puts "OPENRV64 MYD-J7A100T CLOCK/UART BITSTREAM BUILD PASS"
puts "Setup WNS: $setup_slack ns"
puts "Bitstream: [file join $output_dir ${top_name}.bit]"
