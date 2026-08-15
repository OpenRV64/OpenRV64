# SPDX-License-Identifier: CERN-OHL-P-2.0

set script_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $script_dir ../../..]]
set output_dir [file join $repo_root build fpga xc7a100t ddr3-memtest]
set project_dir [file join $output_dir project]
set vendor_dir [file join $output_dir vendor]
set generated_ip_dir [file join $project_dir generated-ip]
set archive [file join $repo_root 07_ddr_test.zip]
set vendor_prj [file join $vendor_dir 07_ddr_test ddr_test.srcs sources_1 ip \
    mig_7series_0 mig_a.prj]
set generated_prj [file join $project_dir mig_a_xc7a100t_2.prj]
set top_name openrv64_myd_j7a100t_ddr3_memtest_top
set part_name xc7a100tfgg484-2
set output_bit [file join $output_dir ${top_name}.bit]

if {![file isfile $archive]} {
    error "required user-supplied MIG archive not found: $archive"
}

file mkdir $output_dir
file delete -force $output_bit
if {![file isfile $vendor_prj]} {
    file mkdir $vendor_dir
    exec unzip -q $archive -d $vendor_dir
}

create_project -force ddr3_memtest $project_dir -part $part_name
set_param general.maxThreads 8

# Recreate the board-supplied MIG for the actual -2 FPGA.  Do not check in
# generated vendor HDL or import the supplied locked -1 checkpoint.
set source_file [open $vendor_prj r]
set prj_text [read $source_file]
close $source_file
set old_target "xc7a100t-fgg484/-1"
set new_target "xc7a100t-fgg484/-2"
if {[regexp -all $old_target $prj_text] != 1} {
    error "expected exactly one $old_target in supplied MIG project"
}
set prj_text [string map [list $old_target $new_target] $prj_text]
set generated_file [open $generated_prj w]
puts -nonewline $generated_file $prj_text
close $generated_file

file delete -force $generated_ip_dir
file mkdir $generated_ip_dir
create_ip -name mig_7series -vendor xilinx.com -library ip -version 4.2 \
    -module_name mig_7series_0 -dir $generated_ip_dir
set mig_ip [get_ips mig_7series_0]
set_property -dict [list CONFIG.XML_INPUT_FILE $generated_prj] $mig_ip
if {[get_property IS_LOCKED $mig_ip]} {
    error "newly generated MIG is unexpectedly locked"
}
generate_target all $mig_ip

add_files -norecurse [list \
    [file join $script_dir uart_banner.sv] \
    [file join $script_dir ddr3_memtest.sv] \
    [file join $script_dir ddr3_memtest_uart_status.sv] \
    [file join $script_dir ${top_name}.sv]]
add_files -fileset constrs_1 -norecurse \
    [file join $script_dir ddr3_calibration_test.xdc]
set_property top $top_name [current_fileset]
update_compile_order -fileset sources_1

create_ip_run $mig_ip
launch_runs mig_7series_0_synth_1 -jobs 8
wait_on_run mig_7series_0_synth_1
if {[get_property PROGRESS [get_runs mig_7series_0_synth_1]] ne "100%"} {
    error "MIG synthesis did not complete"
}

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "top-level synthesis did not complete"
}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "implementation did not complete"
}

open_run impl_1
report_route_status -file [file join $output_dir route_status.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file [file join $output_dir timing_summary.rpt]
report_utilization -file [file join $output_dir utilization.rpt]
report_drc -file [file join $output_dir drc.rpt]
report_methodology -file [file join $output_dir methodology.rpt]
report_cdc -file [file join $output_dir cdc.rpt]
report_io -file [file join $output_dir io.rpt]

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

set run_bit [file join $project_dir ddr3_memtest.runs impl_1 ${top_name}.bit]
if {![file isfile $run_bit]} {
    error "implementation completed without bitstream: $run_bit"
}
file copy -force $run_bit $output_bit

puts "OPENRV64 MYD-J7A100T DDR3 FULL-MEMORY TEST BITSTREAM BUILD PASS"
puts "Setup WNS: $setup_slack ns"
puts "Hold WHS: $hold_slack ns"
puts "Bitstream: $output_bit"
