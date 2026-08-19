# SPDX-License-Identifier: CERN-OHL-P-2.0

if {$argc != 2} {
    error "usage: link_vivado_opensbi_core.tcl <core.edif> <output.dcp>"
}

set core_edif [file normalize [lindex $argv 0]]
set output_dcp [file normalize [lindex $argv 1]]
set part_name xc7a100tfgg484-2

if {![file isfile $core_edif] || ([file size $core_edif] == 0)} {
    error "required core EDIF not found: $core_edif"
}

read_edif $core_edif
link_design -mode out_of_context -part $part_name -top openrv64_fpga_core

set unresolved_cells [get_cells -quiet -hierarchical -filter {IS_BLACKBOX}]
if {[llength $unresolved_cells] != 0} {
    error "core EDIF contains unresolved cells: $unresolved_cells"
}

set_property DONT_TOUCH true [get_cells -hierarchical *]
report_utilization -file ${output_dcp}.utilization.rpt
write_checkpoint -force $output_dcp
puts "OPENRV64 VIVADO CORE LINK PASS: $output_dcp"
