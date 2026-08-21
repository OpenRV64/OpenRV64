# SPDX-License-Identifier: CERN-OHL-P-2.0

set script_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $script_dir ../../..]]
set output_dir [file join $repo_root build fpga xc7a100t emaclite-ooc]
set part_name xc7a100tfgg484-2

file mkdir $output_dir
create_project -in_memory -part $part_name
set_property verilog_define OPENRV64_XILINX_PACKET_RAM [current_fileset]
read_verilog -sv [list \
    [file join $repo_root rtl periph ethernet packet_ram.sv] \
    [file join $repo_root rtl periph ethernet emaclite.sv]]

synth_design -mode out_of_context -flatten_hierarchy rebuilt \
    -part $part_name -top openrv64_emaclite

create_clock -name core -period 90.909 [get_ports clk_i]
create_clock -name tx -period 40.000 [get_ports tx_clk_i]
create_clock -name rx -period 8.000 [get_ports rx_clk_i]
set_clock_groups -asynchronous \
    -group [get_clocks core] \
    -group [get_clocks tx] \
    -group [get_clocks rx]

report_utilization -file [file join $output_dir utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $output_dir timing_summary.rpt]
report_cdc -file [file join $output_dir cdc.rpt]
write_checkpoint -force [file join $output_dir emaclite_ooc.dcp]

puts "OPENRV64 EMACLITE OOC SYNTHESIS PASS"
