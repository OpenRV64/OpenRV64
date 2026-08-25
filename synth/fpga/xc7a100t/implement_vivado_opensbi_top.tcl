# SPDX-License-Identifier: CERN-OHL-P-2.0

if {$argc != 3} {
    error "usage: implement_vivado_opensbi_top.tcl <post-opt.dcp> <output.bit> <report-dir>"
}

set input_dcp [file normalize [lindex $argv 0]]
set output_bit [file normalize [lindex $argv 1]]
set report_dir [file normalize [lindex $argv 2]]
if {![file isfile $input_dcp] || ([file size $input_dcp] == 0)} {
    error "post-optimization OpenSBI checkpoint not found: $input_dcp"
}
file mkdir $report_dir
file delete -force $output_bit

set_param general.maxThreads 8
open_checkpoint $input_dcp

place_design -directive Explore
report_utilization -file [file join $report_dir utilization_post_place.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file [file join $report_dir timing_post_place.rpt]
write_checkpoint -force [file join $report_dir post_place.dcp]

phys_opt_design -directive AggressiveExplore
route_design -directive Explore

# Explore occasionally leaves a single marginal setup endpoint on this dense
# 7-series image even though incremental placement has created positive
# estimated slack. Give that placed/routed result one physical-repair pass
# before rejecting it. This does not relax the timing constraint; the final
# setup and hold checks below still gate bitstream generation.
set initial_setup_path [get_timing_paths -quiet -delay_type max -max_paths 1]
if {[llength $initial_setup_path] == 0} {
    error "missing setup timing path after initial route"
}
set initial_setup_slack [get_property SLACK [lindex $initial_setup_path 0]]
if {$initial_setup_slack < 0.0} {
    puts "OPENRV64 VIVADO ROUTE REPAIR: initial WNS=$initial_setup_slack ns"
    phys_opt_design -directive AggressiveExplore
    route_design -directive Explore
}

report_route_status -file [file join $report_dir route_status.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file [file join $report_dir timing_summary.rpt]
report_clock_interaction -file [file join $report_dir clock_interaction.rpt]
report_utilization -file [file join $report_dir utilization.rpt]
report_drc -file [file join $report_dir drc.rpt]
report_methodology -file [file join $report_dir methodology.rpt]
report_cdc -file [file join $report_dir cdc.rpt]
report_io -file [file join $report_dir io.rpt]
write_checkpoint -force [file join $report_dir post_route.dcp]

set setup_path [get_timing_paths -quiet -delay_type max -max_paths 1]
set hold_path [get_timing_paths -quiet -delay_type min -max_paths 1]
if {([llength $setup_path] == 0) || ([llength $hold_path] == 0)} {
    error "missing setup or hold timing paths"
}
set setup_slack [get_property SLACK [lindex $setup_path 0]]
set hold_slack [get_property SLACK [lindex $hold_path 0]]
if {$setup_slack < 0.0} {
    error "setup timing failed: WNS=$setup_slack ns"
}
if {$hold_slack < 0.0} {
    error "hold timing failed: WHS=$hold_slack ns"
}

write_bitstream -force $output_bit
if {![file isfile $output_bit] || ([file size $output_bit] == 0)} {
    error "bitstream generation did not produce: $output_bit"
}

puts "OPENRV64 MYD-J7A100T OPENSBI NETLIST BITSTREAM BUILD PASS"
puts "Setup WNS: $setup_slack ns"
puts "Hold WHS: $hold_slack ns"
puts "Bitstream: $output_bit"
