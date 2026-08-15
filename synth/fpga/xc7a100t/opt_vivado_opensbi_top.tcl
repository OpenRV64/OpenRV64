# SPDX-License-Identifier: CERN-OHL-P-2.0

if {$argc != 5} {
    error "usage: opt_vivado_opensbi_top.tcl <input.dcp> <mig.xdc> <board.xdc> <output.dcp> <report-dir>"
}

set input_dcp [file normalize [lindex $argv 0]]
set mig_xdc [file normalize [lindex $argv 1]]
set board_xdc [file normalize [lindex $argv 2]]
set output_dcp [file normalize [lindex $argv 3]]
set report_dir [file normalize [lindex $argv 4]]

foreach artifact [list $input_dcp $mig_xdc $board_xdc] {
    if {![file isfile $artifact] || ([file size $artifact] == 0)} {
        error "required OpenSBI optimization artifact not found: $artifact"
    }
}
file mkdir $report_dir

open_checkpoint $input_dcp

# The partitions were preserved while they crossed tool boundaries.  Once the
# complete netlist is linked, allow Vivado to combine paired Yosys LUT5/LUT6
# primitives and remap logic.  Do not disturb any MIG preservation property.
set system_cells [get_cells -quiet -hierarchical -filter {NAME =~ u_system*}]
if {[llength $system_cells] == 0} {
    error "linked design has no OpenRV64 system cells"
}
reset_property DONT_TOUCH $system_cells

# EDIF represents a one-bit Verilog vector as a scalar top-level port.  MIG's
# generated XDC spells those five ports with [0] (and uses [*] for the clock),
# so derive a build-local XDC with only those selectors scalarized.  The pin,
# I/O-standard, placement, and PHY timing contents remain otherwise exact.
set mig_file [open $mig_xdc r]
set mig_text [read $mig_file]
close $mig_file
set mig_scalar_xdc [file join $report_dir mig_7series_0_scalar_ports.xdc]
set mig_text [string map [list \
    {ddr3_ck_n[*]} {ddr3_ck_n} \
    {ddr3_ck_n[0]} {ddr3_ck_n} \
    {ddr3_ck_p[*]} {ddr3_ck_p} \
    {ddr3_ck_p[0]} {ddr3_ck_p} \
    {ddr3_cke[0]} {ddr3_cke} \
    {ddr3_cs_n[0]} {ddr3_cs_n} \
    {ddr3_odt[0]} {ddr3_odt}] $mig_text]
set mig_scalar_file [open $mig_scalar_xdc w]
puts -nonewline $mig_scalar_file $mig_text
close $mig_scalar_file

read_xdc $mig_scalar_xdc
read_xdc $board_xdc

set odt_pin [get_pins -quiet {u_mig/ddr3_odt[0]}]
set odt_port [get_ports -quiet ddr3_odt]
if {([llength $odt_pin] != 1) || ([llength $odt_port] != 1) ||
    ([get_nets -quiet -of_objects $odt_pin] ne
     [get_nets -quiet -of_objects $odt_port])} {
    error "MIG DDR3 ODT is not connected to the board port"
}

report_clocks -file [file join $report_dir clocks_pre_opt.rpt]
report_utilization -file [file join $report_dir utilization_pre_opt.rpt]
opt_design -directive ExploreWithRemap
report_utilization -file [file join $report_dir utilization_post_opt.rpt]
report_drc -file [file join $report_dir drc_post_opt.rpt]
write_checkpoint -force $output_dcp
puts "OPENRV64 VIVADO TOP OPT PASS: $output_dcp"
