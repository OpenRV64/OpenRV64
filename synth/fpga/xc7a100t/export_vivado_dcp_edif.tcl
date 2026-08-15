# SPDX-License-Identifier: CERN-OHL-P-2.0

if {$argc != 2} {
    error "usage: export_vivado_dcp_edif.tcl <input.dcp> <output.edif>"
}

set input_dcp [file normalize [lindex $argv 0]]
set output_edif [file normalize [lindex $argv 1]]
if {![file isfile $input_dcp] || ([file size $input_dcp] == 0)} {
    error "input checkpoint not found: $input_dcp"
}

open_checkpoint $input_dcp
set unresolved_cells [get_cells -quiet -hierarchical -filter {IS_BLACKBOX}]
if {[llength $unresolved_cells] != 0} {
    error "checkpoint contains unresolved cells: $unresolved_cells"
}
write_edif -force $output_edif
puts "OPENRV64 VIVADO EDIF EXPORT PASS: $output_edif"
