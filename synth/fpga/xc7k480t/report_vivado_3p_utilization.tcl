# SPDX-License-Identifier: CERN-OHL-P-2.0

if {$argc < 4 || $argc > 5} {
    error "usage: report_vivado_3p_utilization.tcl <input.edif> <constraints.xdc> <output-dir> <part> ?top?"
}

set input_edif [file normalize [lindex $argv 0]]
set input_xdc [file normalize [lindex $argv 1]]
set output_dir [file normalize [lindex $argv 2]]
set part_name [lindex $argv 3]
set top_name [expr {$argc == 5 ? [lindex $argv 4] : "openrv64_xc7k480t_core_3p"}]

if {![file isfile $input_edif] || ([file size $input_edif] == 0)} {
    error "3P core EDIF not found: $input_edif"
}
if {![file isfile $input_xdc] || ([file size $input_xdc] == 0)} {
    error "constraint file not found: $input_xdc"
}
if {[llength [get_parts -quiet $part_name]] == 0} {
    error "Vivado installation does not contain part: $part_name"
}

file mkdir $output_dir
read_edif $input_edif
link_design -mode out_of_context -part $part_name -top $top_name
read_xdc $input_xdc

set unresolved_cells [get_cells -quiet -hierarchical -filter {IS_BLACKBOX}]
if {[llength $unresolved_cells] != 0} {
    error "3P core EDIF contains unresolved cells: $unresolved_cells"
}

report_utilization -file [file join $output_dir utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $output_dir timing_synth.rpt]
write_checkpoint -force [file join $output_dir openrv64_core_3p.dcp]

puts "OPENRV64 XC7K480T 3P VIVADO UTILIZATION PASS part=$part_name report=[file join $output_dir utilization.rpt]"
