set script_dir [file dirname [file normalize [info script]]]
set output_dir [file join $script_dir build]
set synth_checkpoint [file join $output_dir post_synth.dcp]

if {![file exists $synth_checkpoint]} {
    error "missing synthesis checkpoint: $synth_checkpoint"
}

set_param general.maxThreads 8
open_checkpoint $synth_checkpoint

opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force [file join $output_dir post_route.dcp]
report_utilization -file [file join $output_dir post_route_utilization.rpt]
report_methodology -file [file join $output_dir post_route_methodology.rpt]
report_timing_summary -file [file join $output_dir post_route_timing.rpt]
report_route_status -file [file join $output_dir post_route_status.rpt]
report_clock_interaction \
    -file [file join $output_dir post_route_clock_interaction.rpt]
report_cdc -details \
    -file [file join $output_dir post_route_cdc.rpt]
report_drc -file [file join $output_dir post_route_drc.rpt]
write_bitstream -force [file join $output_dir openrv64_myd_j7a100t.bit]

puts "OPENRV64_FPGA_BITSTREAM=PASS"
exit 0
