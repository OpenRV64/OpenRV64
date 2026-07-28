set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../../..]]
set rtl_root [file join $repo_root rtl]
set output_dir [file join $script_dir build]

set part xc7a100tfgg484-2
set top openrv64_myd_j7a100t_top
set top_file [file join $script_dir openrv64_myd_j7a100t_top.sv]
set constraints_file [file join $script_dir myd_j7a100t.xdc]
set sources_makefile [file join $script_dir platform-sources.mk]
set mig_config_file [
    file join \
        $script_dir \
        vendor \
        mig_7series_0 \
        mig_a_xc7a100t_2.prj
]

set flow rtl
set requested_core_clock_mhz 10.000
if {$argc > 0} {
    set flow [lindex $argv 0]
}
if {$argc > 1} {
    set requested_core_clock_mhz [lindex $argv 1]
}
if {($argc > 2) ||
    ($flow ni {rtl synth bitstream}) ||
    ![string is double -strict $requested_core_clock_mhz] ||
    ($requested_core_clock_mhz <= 0.0)} {
    error "usage: build.tcl <rtl|synth|bitstream> ?core_clock_mhz?"
}

file mkdir $output_dir
set_param general.maxThreads 8
create_project -in_memory -part $part
set_property target_language Verilog [current_project]

set generated_ip_dir [file join $output_dir ip]
file mkdir $generated_ip_dir

set clock_xci [
    file join $generated_ip_dir myir_mig_clk_wiz myir_mig_clk_wiz.xci
]
if {[file exists $clock_xci]} {
    read_ip $clock_xci
} else {
    create_ip \
        -name clk_wiz \
        -vendor xilinx.com \
        -library ip \
        -module_name myir_mig_clk_wiz \
        -dir $generated_ip_dir
}
set clock_ip [get_ips myir_mig_clk_wiz]
set_property CONFIG.CLKOUT2_USED {true} $clock_ip
set_property CONFIG.NUM_OUT_CLKS {2} $clock_ip
set_property -dict [list \
    CONFIG.PRIMITIVE {MMCM} \
    CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.PRIM_IN_FREQ {200.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ $requested_core_clock_mhz \
    CONFIG.USE_PHASE_ALIGNMENT {true} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.USE_RESET {false} \
] $clock_ip
set mig_input_clock_mhz [
    get_property CONFIG.CLKOUT1_REQUESTED_OUT_FREQ $clock_ip
]
set core_clock_mhz [
    get_property CONFIG.CLKOUT2_REQUESTED_OUT_FREQ $clock_ip
]
if {([get_property CONFIG.CLKOUT2_USED $clock_ip] ne "true") ||
    (abs($mig_input_clock_mhz - 200.0) > 0.001) ||
    (abs($core_clock_mhz - $requested_core_clock_mhz) > 0.001)} {
    error "clock wizard configuration did not accept requested outputs"
}
puts "OPENRV64_FPGA_MIG_INPUT_CLOCK_MHZ=$mig_input_clock_mhz"
puts "OPENRV64_FPGA_CORE_CLOCK_MHZ=$core_clock_mhz"
generate_target synthesis $clock_ip

set mig_xci [
    file join $generated_ip_dir mig_7series_0 mig_7series_0.xci
]
if {[file exists $mig_xci]} {
    read_ip $mig_xci
} else {
    create_ip \
        -name mig_7series \
        -vendor xilinx.com \
        -library ip \
        -version 4.2 \
        -module_name mig_7series_0 \
        -dir $generated_ip_dir
}
set mig_ip [get_ips mig_7series_0]
file mkdir [get_property IP_OUTPUT_DIR $mig_ip]
set_property CONFIG.XML_INPUT_FILE [file normalize $mig_config_file] $mig_ip
generate_target synthesis $mig_ip

if {$flow ne "rtl"} {
    synth_ip $clock_ip
    synth_ip $mig_ip
}

set source_text [
    exec make \
        --no-print-directory \
        -s \
        -f $sources_makefile \
        print-platform-sources
]
set rtl_sources {}
foreach source [split $source_text "\n"] {
    if {$source ne ""} {
        lappend rtl_sources $source
    }
}
lappend rtl_sources $top_file

puts "OPENRV64_FPGA_FLOW=$flow"
puts "OPENRV64_FPGA_PART=$part"
puts "OPENRV64_FPGA_TOP=$top"
puts "OPENRV64_FPGA_SOURCE_COUNT=[llength $rtl_sources]"

read_verilog -sv $rtl_sources
read_xdc $constraints_file

proc report_board_ports {} {
    puts "OPENRV64_FPGA_SYS_CLK_PIN=[get_property PACKAGE_PIN \
        [get_ports sys_clk_p]]"
    puts "OPENRV64_FPGA_RESET_PIN=[get_property PACKAGE_PIN \
        [get_ports rst_n]]"
    puts "OPENRV64_FPGA_UART_RX_PIN=[get_property PACKAGE_PIN \
        [get_ports uart_rx_i]]"
    puts "OPENRV64_FPGA_UART_TX_PIN=[get_property PACKAGE_PIN \
        [get_ports uart_tx_o]]"
    puts "OPENRV64_FPGA_DDR3_DQ0_PIN=[get_property PACKAGE_PIN \
        [get_ports {ddr3_dq[0]}]]"
}

if {$flow eq "rtl"} {
    synth_design -rtl -top $top -part $part -include_dirs [list $rtl_root]
    report_board_ports
    puts "OPENRV64_FPGA_ELABORATION=PASS"
    exit 0
}

synth_design -top $top -part $part -include_dirs [list $rtl_root]
report_board_ports
write_checkpoint -force [file join $output_dir post_synth.dcp]
report_utilization -file [file join $output_dir post_synth_utilization.rpt]
report_timing_summary -file [file join $output_dir post_synth_timing.rpt]

if {$flow eq "synth"} {
    puts "OPENRV64_FPGA_SYNTHESIS=PASS"
    exit 0
}

opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force [file join $output_dir post_route.dcp]
report_utilization -file [file join $output_dir post_route_utilization.rpt]
report_timing_summary -file [file join $output_dir post_route_timing.rpt]
write_bitstream -force [file join $output_dir openrv64_myd_j7a100t.bit]

puts "OPENRV64_FPGA_BITSTREAM=PASS"
exit 0
