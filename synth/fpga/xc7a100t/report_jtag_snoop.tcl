# SPDX-License-Identifier: CERN-OHL-P-2.0

if {($argc != 1) && ($argc != 2)} {
    error "usage: report_jtag_snoop.tcl <post-route.dcp> ?jtag.xdc?"
}

open_checkpoint [file normalize [lindex $argv 0]]
if {$argc == 2} {
    read_xdc [file normalize [lindex $argv 1]]
}
set bscan_cells [get_cells -quiet -hier -filter {REF_NAME == BSCANE2}]
puts "BSCAN cells: $bscan_cells"
foreach cell $bscan_cells {
    foreach pin_name {TCK DRCK UPDATE} {
        set pin [get_pins -quiet $cell/$pin_name]
        puts "$pin_name pin=$pin clocks=[get_clocks -quiet -of_objects $pin]"
    }
}
set report_root /tmp/openrv64-jtag-snoop-constraint-check
file mkdir $report_root
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file [file join $report_root timing.rpt]
report_methodology -file [file join $report_root methodology.rpt]
puts "JTAG snoop constraint reports: $report_root"
