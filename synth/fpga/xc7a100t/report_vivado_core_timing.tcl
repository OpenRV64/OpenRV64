if {$argc < 2 || $argc > 4} {
    error "usage: report_vivado_core_timing.tcl <post-route.dcp> <report-dir> ?max-paths? ?report-name?"
}

set input_dcp [file normalize [lindex $argv 0]]
set report_dir [file normalize [lindex $argv 1]]
set max_paths [expr {$argc >= 3 ? [lindex $argv 2] : 10}]
set report_name [expr {$argc >= 4 ? [lindex $argv 3] : "timing_strict_core.rpt"}]

if {![string is integer -strict $max_paths] || ($max_paths < 1)} {
    error "max-paths must be a positive integer: $max_paths"
}
if {[file tail $report_name] ne $report_name} {
    error "report-name must be a basename: $report_name"
}

if {![file isfile $input_dcp] || ([file size $input_dcp] == 0)} {
    error "routed checkpoint not found: $input_dcp"
}

file mkdir $report_dir
open_checkpoint $input_dcp

set core_clock [get_clocks -quiet core_clock_unbuffered]
if {[llength $core_clock] != 1} {
    error "expected one core_clock_unbuffered clock, found: $core_clock"
}

set core_startpoints [filter [all_registers -clock $core_clock] {
    NAME =~ "u_system/u_platform.u_core/*"
}]
set core_endpoints [filter [all_registers -clock $core_clock -data_pins] {
    NAME =~ "u_system/u_platform.u_core/*"
}]
if {([llength $core_startpoints] == 0) ||
    ([llength $core_endpoints] == 0)} {
    error "no core register timing endpoints found"
}

set strict_report [file join $report_dir $report_name]
report_timing -delay_type max \
    -from $core_startpoints -to $core_endpoints \
    -max_paths $max_paths -file $strict_report

if {![file isfile $strict_report] || ([file size $strict_report] == 0)} {
    error "core timing report was not produced: $strict_report"
}

puts "OPENRV64 FPGA CORE TIMING REPORT PASS path=$strict_report"
