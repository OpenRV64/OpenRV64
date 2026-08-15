# SPDX-License-Identifier: CERN-OHL-P-2.0

if {$argc != 5} {
    error "usage: build_vivado_opensbi_system_dcp.tcl <system.edif> <system.dcp> <core.edif> <loader.edif> <linked.edif>"
}

set system_edif [file normalize [lindex $argv 0]]
set system_dcp [file normalize [lindex $argv 1]]
set core_edif [file normalize [lindex $argv 2]]
set loader_edif [file normalize [lindex $argv 3]]
set linked_edif [file normalize [lindex $argv 4]]
set part_name xc7a100tfgg484-2

foreach artifact [list $system_edif $core_edif $loader_edif] {
    if {![file isfile $artifact] || ([file size $artifact] == 0)} {
        error "required OpenSBI system partition artifact not found: $artifact"
    }
}

read_edif [list $system_edif $core_edif $loader_edif]
link_design -mode out_of_context -part $part_name \
    -top openrv64_fpga_opensbi_system

set unresolved_cells [get_cells -quiet -hierarchical -filter {IS_BLACKBOX}]
if {[llength $unresolved_cells] != 0} {
    error "system checkpoint contains unresolved cells: $unresolved_cells"
}

set_property DONT_TOUCH true [get_cells -hierarchical *]
report_utilization -file ${system_dcp}.utilization.rpt
write_edif -force $linked_edif
write_checkpoint -force $system_dcp
puts "OPENRV64 VIVADO SYSTEM CHECKPOINT PASS: $system_dcp"
