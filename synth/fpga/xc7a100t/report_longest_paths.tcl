set script_dir [file dirname [file normalize [info script]]]
set output_dir [file join $script_dir build]
set route_checkpoint [file join $output_dir post_route.dcp]

if {![file exists $route_checkpoint]} {
    error "missing routed checkpoint: $route_checkpoint"
}

set_param general.maxThreads 8
open_checkpoint $route_checkpoint

set core_clock [get_clocks -quiet clk_out2_myir_mig_clk_wiz]
if {[llength $core_clock] != 1} {
    error "expected one core clock, found [llength $core_clock]"
}
set core_registers [all_registers -clock $core_clock]
if {[llength $core_registers] == 0} {
    error "no registers found on core clock $core_clock"
}

set overall_paths [
    get_timing_paths \
        -delay_type max \
        -max_paths 100 \
        -nworst 1 \
        -sort_by slack
]
set core_paths [
    get_timing_paths \
        -from $core_registers \
        -to $core_registers \
        -delay_type max \
        -max_paths 100 \
        -nworst 1 \
        -sort_by slack
]

report_timing \
    -delay_type max \
    -max_paths 100 \
    -nworst 1 \
    -sort_by slack \
    -path_type full_clock_expanded \
    -input_pins \
    -significant_digits 3 \
    -file [file join $output_dir post_route_longest_paths.rpt]

report_timing \
    -from $core_registers \
    -to $core_registers \
    -delay_type max \
    -max_paths 100 \
    -nworst 1 \
    -sort_by slack \
    -path_type full_clock_expanded \
    -input_pins \
    -significant_digits 3 \
    -file [file join $output_dir post_route_core_longest_paths.rpt]

proc write_path_rows {channel scope paths} {
    set rank 0
    foreach path $paths {
        incr rank
        puts $channel [join [list \
            $scope \
            $rank \
            [get_property SLACK $path] \
            [get_property DATAPATH_DELAY $path] \
            [get_property LOGIC_LEVELS $path] \
            [get_property STARTPOINT_PIN $path] \
            [get_property ENDPOINT_PIN $path] \
        ] ","]
    }
}

set csv_path [file join $output_dir post_route_longest_paths.csv]
set csv_channel [open $csv_path w]
puts $csv_channel \
    "scope,rank,slack_ns,datapath_delay_ns,logic_levels,startpoint,endpoint"
write_path_rows $csv_channel overall $overall_paths
write_path_rows $csv_channel core $core_paths
close $csv_channel

puts "OPENRV64_FPGA_OVERALL_PATH_COUNT=[llength $overall_paths]"
puts "OPENRV64_FPGA_CORE_PATH_COUNT=[llength $core_paths]"
puts "OPENRV64_FPGA_LONGEST_PATH_REPORT=PASS"
exit 0
