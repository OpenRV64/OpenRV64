# SPDX-License-Identifier: CERN-OHL-P-2.0

if {$argc != 4} {
    error "usage: link_vivado_opensbi_top.tcl <top.edif> <system.dcp> <mig.dcp> <output.dcp>"
}

set top_edif [file normalize [lindex $argv 0]]
set system_dcp [file normalize [lindex $argv 1]]
set mig_dcp [file normalize [lindex $argv 2]]
set output_dcp [file normalize [lindex $argv 3]]
set part_name xc7a100tfgg484-2
set top_name openrv64_myd_j7a100t_opensbi_top

foreach artifact [list $top_edif $system_dcp $mig_dcp] {
    if {![file isfile $artifact] || ([file size $artifact] == 0)} {
        error "required linked-top artifact not found: $artifact"
    }
}

read_edif $top_edif
read_checkpoint $mig_dcp
link_design -part $part_name -top $top_name

# Yosys places a referenced black box in its EDIF LIB library, while Vivado
# exports the implemented partition in DESIGN. Reading the two EDIF files
# together therefore does not reliably bind u_system. Load the compiled OOC
# checkpoint into the already-linked black-box cell instead.
set system_cells [get_cells -quiet -hierarchical \
    -filter {REF_NAME == openrv64_fpga_opensbi_system}]
if {[llength $system_cells] != 1} {
    error "expected one openrv64_fpga_opensbi_system cell, found: $system_cells"
}
read_checkpoint -cell [lindex $system_cells 0] $system_dcp
# read_checkpoint invalidates every previously returned design-object handle.
set system_cells [get_cells -quiet -hierarchical \
    -filter {REF_NAME == openrv64_fpga_opensbi_system}]
if {[llength $system_cells] != 1} {
    error "system cell disappeared after checkpoint load: $system_cells"
}
if {[get_property IS_BLACKBOX [lindex $system_cells 0]]} {
    error "OpenRV64 FPGA system checkpoint did not resolve u_system"
}

set unresolved_cells [get_cells -quiet -hierarchical -filter {IS_BLACKBOX}]
if {[llength $unresolved_cells] != 0} {
    error "linked top contains unresolved cells: $unresolved_cells"
}

report_utilization -file ${output_dcp}.utilization.rpt
report_clocks -file ${output_dcp}.clocks.rpt
write_checkpoint -force $output_dcp
puts "OPENRV64 VIVADO LINKED TOP PASS: $output_dcp"
