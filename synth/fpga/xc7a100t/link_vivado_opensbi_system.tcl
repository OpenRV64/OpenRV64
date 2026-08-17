# SPDX-License-Identifier: CERN-OHL-P-2.0

if {$argc != 3} {
    error "usage: link_vivado_opensbi_system.tcl <system.edif> <core.dcp> <output.dcp>"
}

set system_edif [file normalize [lindex $argv 0]]
set core_dcp [file normalize [lindex $argv 1]]
set output_dcp [file normalize [lindex $argv 2]]
set part_name xc7a100tfgg484-2

foreach artifact [list $system_edif $core_dcp] {
    if {![file isfile $artifact] || ([file size $artifact] == 0)} {
        error "required system-link artifact not found: $artifact"
    }
}

read_edif $system_edif
read_checkpoint $core_dcp
link_design -mode out_of_context -part $part_name \
    -top openrv64_fpga_opensbi_system

set core_cells [get_cells -quiet -hierarchical \
    -filter {REF_NAME == openrv64_fpga_core}]
if {[llength $core_cells] != 1} {
    error "expected one openrv64_fpga_core cell, found: $core_cells"
}
if {[get_property IS_BLACKBOX [lindex $core_cells 0]]} {
    error "core checkpoint did not resolve u_platform.u_core"
}
set unresolved_cells [get_cells -quiet -hierarchical -filter {IS_BLACKBOX}]
if {[llength $unresolved_cells] != 0} {
    error "system EDIF contains unresolved cells: $unresolved_cells"
}
write_checkpoint -force $output_dcp
puts "OPENRV64 VIVADO SD SYSTEM LINK PASS: $output_dcp"
