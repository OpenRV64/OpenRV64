# SPDX-License-Identifier: CERN-OHL-P-2.0

if {$argc != 2} {
    error "usage: inventory_vivado_debug_nets.tcl <checkpoint.dcp> <output.txt>"
}

set input_dcp [file normalize [lindex $argv 0]]
set output_txt [file normalize [lindex $argv 1]]
if {![file isfile $input_dcp] || ([file size $input_dcp] == 0)} {
    error "checkpoint not found: $input_dcp"
}

file mkdir [file dirname $output_txt]
open_checkpoint $input_dcp

set output [open $output_txt w]
foreach pattern {
    *trace* *pc* *fetch* *redirect* *flush* *cancel* *mem_addr*
    *mem_valid* *mem_ready* *mem_exec* *debug_serial* *core_clk* *clk_i*
} {
    puts $output "PATTERN $pattern"
    foreach net [lsort [get_nets -quiet -hierarchical $pattern]] {
        set drivers [get_pins -quiet -of_objects $net -filter {DIRECTION == OUT}]
        puts $output "NET $net DRIVERS $drivers"
    }
}
close $output

puts "OPENRV64 FPGA DEBUG NET INVENTORY PASS path=$output_txt"
