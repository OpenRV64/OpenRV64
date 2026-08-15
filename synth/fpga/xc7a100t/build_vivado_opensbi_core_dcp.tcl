# SPDX-License-Identifier: CERN-OHL-P-2.0

if {$argc < 2 || $argc > 3} {
    error "usage: build_vivado_opensbi_core_dcp.tcl <input.edif> <output.dcp> ?top?"
}

set core_edif [file normalize [lindex $argv 0]]
set core_dcp [file normalize [lindex $argv 1]]
set top_name [expr {$argc == 3 ? [lindex $argv 2] : "openrv64_fpga_core"}]
set part_name xc7a100tfgg484-2

if {![file isfile $core_edif] || ([file size $core_edif] == 0)} {
    error "fixed FPGA core EDIF not found: $core_edif"
}

read_edif $core_edif
link_design -mode out_of_context -part $part_name -top $top_name

set unresolved_cells [get_cells -quiet -hierarchical -filter {IS_BLACKBOX}]
if {[llength $unresolved_cells] != 0} {
    error "core EDIF contains unresolved cells: $unresolved_cells"
}

# This block is already technology mapped by Yosys.  Preserve it as a compiled
# partition so the top-level Vivado synthesis run cannot globally re-optimize
# the imported primitive graph.
set_property DONT_TOUCH true [get_cells -hierarchical *]

report_utilization -file ${core_dcp}.utilization.rpt
write_checkpoint -force $core_dcp
puts "OPENRV64 VIVADO CHECKPOINT PASS ($top_name): $core_dcp"
