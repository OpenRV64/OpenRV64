# SPDX-License-Identifier: CERN-OHL-P-2.0

set script_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $script_dir ../../..]]
set output_dir [file join $repo_root build fpga xc7a100t opensbi-smoke]
set project_dir [file join $output_dir project]
set vendor_dir [file join $output_dir vendor]
set generated_ip_dir [file join $project_dir generated-ip]
set image_dir [file join $output_dir images]
set opensbi_build_dir [file join $repo_root build opensbi-fpga]
set opensbi_source_dir [file join $repo_root build opensbi src]
if {![file isdirectory $opensbi_source_dir]} {
    set opensbi_source_dir [file join $opensbi_build_dir src]
}
set opensbi_artifact_dir [file join $opensbi_build_dir artifacts]
set core_edif [file join $output_dir openrv64_fpga_core.edif]
set core_json [file join $output_dir openrv64_fpga_core.json]
set core_stub [file join $output_dir openrv64_fpga_core_stub.v]
set core_dcp [file join $output_dir openrv64_fpga_core.dcp]
set core_yosys_log [file join $output_dir yosys-core.log]
set loader_edif [file join $output_dir openrv64_fpga_loader_fixed.edif]
set loader_json [file join $output_dir openrv64_fpga_loader_fixed.json]
set loader_stub [file join $output_dir openrv64_fpga_loader_fixed_stub.v]
set loader_dcp [file join $output_dir openrv64_fpga_loader_fixed.dcp]
set loader_yosys_log [file join $output_dir yosys-loader.log]
set archive [file join $repo_root 07_ddr_test.zip]
set vendor_prj [file join $vendor_dir 07_ddr_test ddr_test.srcs sources_1 ip \
    mig_7series_0 mig_a.prj]
set generated_prj [file join $project_dir mig_a_xc7a100t_2.prj]
set top_name openrv64_myd_j7a100t_opensbi_top
set part_name xc7a100tfgg484-2
set output_bit [file join $output_dir ${top_name}.bit]

if {![file isfile $archive]} {
    error "required user-supplied MIG archive not found: $archive"
}

file mkdir $output_dir
file mkdir $image_dir
file delete -force $output_bit

# Build a single-hart, cacheless/one-pipe firmware description matching the
# exact 9.216 MHz FPGA platform clock. Reuse an existing pinned OpenSBI source
# checkout when present; build-opensbi.sh still verifies the v1.9 commit.
puts "Preparing FPGA OpenSBI firmware and compact boot ROM images"
set old_directory [pwd]
cd $repo_root
set opensbi_output [exec env \
    OPENSBI_BUILD_DIR=$opensbi_build_dir \
    OPENSBI_SOURCE_DIR=$opensbi_source_dir \
    OPENRV64_HART_COUNT=1 \
    OPENRV64_MEMORY_SIZE=0x10000000 \
    OPENRV64_TIMEBASE_FREQUENCY=9216000 \
    OPENRV64_UART_CLOCK_FREQUENCY=9216000 \
    OPENRV64_ZBB=0 \
    OPENRV64_ZICCLSM=1 \
    OPENRV64_PAYLOAD_SOURCE=sw/opensbi_payload_sv39.S \
    [file join $repo_root tools build-opensbi.sh] 2>@1]
cd $old_directory
puts $opensbi_output

# Vivado 2026.1 spends hours optimizing the monolithic core RTL before
# technology mapping.  Generate a fixed-profile Series-7 netlist with Yosys
# and let Vivado own board integration, timing, placement, routing, and bitgen.
puts "Synthesizing fixed OpenRV64 FPGA core EDIF"
set reuse_core [expr {
    (([info exists ::env(OPENRV64_REUSE_YOSYS_CORE)] &&
      ($::env(OPENRV64_REUSE_YOSYS_CORE) eq "1")) ||
     ([lsearch -exact $argv "--reuse-yosys-core"] >= 0)) &&
    [file isfile $core_edif] && [file isfile $core_json] &&
    [file isfile $core_stub]}]
if {$reuse_core} {
    puts "Reusing explicitly requested FPGA core EDIF"
} else {
    set old_directory [pwd]
    cd $repo_root
    set core_output [exec env \
        -u LD_LIBRARY_PATH -u PYTHONHOME -u PYTHONPATH \
        OUT_DIR=$output_dir \
        OUTPUT_EDIF=$core_edif \
        OUTPUT_JSON=$core_json \
        OUTPUT_STUB=$core_stub \
        OUTPUT_LOG=$core_yosys_log \
        [file join $script_dir build_yosys_opensbi_core.sh] 2>@1]
    cd $old_directory
    puts $core_output
}
if {![file isfile $core_edif] || ([file size $core_edif] == 0) ||
    ![file isfile $core_stub] || ([file size $core_stub] == 0)} {
    error "Yosys did not generate the fixed FPGA core EDIF and stub"
}

# Convert the flat EDIF into a compiled out-of-context checkpoint before the
# project is created.  Feeding the EDIF directly to top synthesis makes Vivado
# globally optimize tens of thousands of imported primitives for hours.
set rebuild_core_dcp [expr {
    ![file isfile $core_dcp] || ([file size $core_dcp] == 0) ||
    ([file mtime $core_dcp] < [file mtime $core_edif])}]
if {$rebuild_core_dcp} {
    puts "Linking fixed OpenRV64 FPGA core checkpoint"
    file delete -force $core_dcp
    read_edif $core_edif
    link_design -mode out_of_context -part $part_name \
        -top openrv64_fpga_core
    set unresolved_core_cells \
        [get_cells -quiet -hierarchical -filter {IS_BLACKBOX}]
    if {[llength $unresolved_core_cells] != 0} {
        error "core EDIF contains unresolved cells: $unresolved_core_cells"
    }
    set_property DONT_TOUCH true [get_cells -hierarchical *]
    report_utilization -file ${core_dcp}.utilization.rpt
    write_checkpoint -force $core_dcp
    close_design
} else {
    puts "Reusing source-matched OpenRV64 FPGA core checkpoint"
}
if {![file isfile $core_dcp] || ([file size $core_dcp] == 0)} {
    error "Vivado did not generate the fixed FPGA core checkpoint"
}

proc compact_image {repo_root source destination} {
    set byte_count [file size $source]
    set padded_bytes [expr {(($byte_count + 31) / 32) * 32}]
    set converter [file join $repo_root tools bin2mem.py]
    puts [exec python3 $converter $source $destination \
        --size $padded_bytes --word-bytes 32 2>@1]
    return [expr {$padded_bytes / 32}]
}

proc split_mem_image {source head_destination tail_destination head_words} {
    set source_file [open $source r]
    set lines [split [string trimright [read $source_file] "\n"] "\n"]
    close $source_file
    set total_words [llength $lines]
    if {$total_words <= $head_words} {
        error "firmware image has $total_words words; split needs more than $head_words"
    }
    set head_file [open $head_destination w]
    puts $head_file [join [lrange $lines 0 [expr {$head_words - 1}]] "\n"]
    close $head_file
    set tail_file [open $tail_destination w]
    puts $tail_file [join [lrange $lines $head_words end] "\n"]
    close $tail_file
}

set trampoline_mem [file join $image_dir trampoline-fpga.mem]
set firmware_full_mem [file join $image_dir fw_jump-fpga-full.mem]
set firmware_mem [file join $image_dir fw_jump-fpga-head.mem]
set firmware_tail_mem [file join $image_dir fw_jump-fpga-tail.mem]
set payload_mem [file join $image_dir payload-fpga.mem]
set fdt_mem [file join $image_dir openrv64-dtb-fpga.mem]
set trampoline_words [compact_image $repo_root \
    [file join $opensbi_artifact_dir trampoline.bin] $trampoline_mem]
set firmware_words [compact_image $repo_root \
    [file join $opensbi_artifact_dir fw_jump.bin] $firmware_full_mem]
split_mem_image $firmware_full_mem $firmware_mem $firmware_tail_mem 8192
set payload_words [compact_image $repo_root \
    [file join $opensbi_artifact_dir payload.bin] $payload_mem]
set fdt_words [compact_image $repo_root \
    [file join $opensbi_artifact_dir openrv64.dtb] $fdt_mem]

# Compile the fixed firmware images and the small DDR copy sequencer outside
# Vivado.  Vivado's XPM-backed ROM elaboration is pathologically slow for this
# 267 KiB image, while Yosys maps the same read-only storage directly to 68
# Series-7 BRAM tiles in under a minute.
puts "Synthesizing fixed OpenRV64 FPGA boot-loader EDIF"
set old_directory [pwd]
cd $repo_root
set loader_output [exec env \
    -u LD_LIBRARY_PATH -u PYTHONHOME -u PYTHONPATH \
    OUT_DIR=$output_dir \
    IMAGE_DIR=$image_dir \
    OUTPUT_EDIF=$loader_edif \
    OUTPUT_JSON=$loader_json \
    OUTPUT_STUB=$loader_stub \
    OUTPUT_LOG=$loader_yosys_log \
    [file join $script_dir build_yosys_opensbi_loader.sh] 2>@1]
cd $old_directory
puts $loader_output
if {![file isfile $loader_edif] || ([file size $loader_edif] == 0) ||
    ![file isfile $loader_stub] || ([file size $loader_stub] == 0)} {
    error "Yosys did not generate the fixed FPGA boot-loader EDIF and stub"
}

puts "Linking fixed OpenRV64 FPGA boot-loader checkpoint"
file delete -force $loader_dcp
read_edif $loader_edif
link_design -mode out_of_context -part $part_name \
    -top openrv64_fpga_loader_fixed
set unresolved_loader_cells \
    [get_cells -quiet -hierarchical -filter {IS_BLACKBOX}]
if {[llength $unresolved_loader_cells] != 0} {
    error "loader EDIF contains unresolved cells: $unresolved_loader_cells"
}
set_property DONT_TOUCH true [get_cells -hierarchical *]
report_utilization -file ${loader_dcp}.utilization.rpt
write_checkpoint -force $loader_dcp
close_design
if {![file isfile $loader_dcp] || ([file size $loader_dcp] == 0)} {
    error "Vivado did not generate the fixed FPGA boot-loader checkpoint"
}

if {![file isfile $vendor_prj]} {
    file mkdir $vendor_dir
    exec unzip -q $archive -d $vendor_dir
}

create_project -force opensbi_smoke $project_dir -part $part_name
set_param general.maxThreads 8
# The core is already structurally hierarchical. Flattening it together with
# the firmware XPMs causes Vivado 2026.1 to spend hours in RTL elaboration and
# grow beyond 12 GiB without reaching the mapping phase. The 9.216 MHz target
# has ample timing margin, so preserve hierarchy and keep synthesis tractable.
set_property strategy Flow_RuntimeOptimized [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none [get_runs synth_1]

# Regenerate rather than import the supplied locked -1-speed-grade MIG.
set source_file [open $vendor_prj r]
set prj_text [read $source_file]
close $source_file
set old_target "xc7a100t-fgg484/-1"
set new_target "xc7a100t-fgg484/-2"
if {[regexp -all $old_target $prj_text] != 1} {
    error "expected exactly one $old_target in supplied MIG project"
}
set prj_text [string map [list $old_target $new_target] $prj_text]
set generated_file [open $generated_prj w]
puts -nonewline $generated_file $prj_text
close $generated_file

file delete -force $generated_ip_dir
file mkdir $generated_ip_dir
create_ip -name mig_7series -vendor xilinx.com -library ip -version 4.2 \
    -module_name mig_7series_0 -dir $generated_ip_dir
set mig_ip [get_ips mig_7series_0]
set_property -dict [list CONFIG.XML_INPUT_FILE $generated_prj] $mig_ip
if {[get_property IS_LOCKED $mig_ip]} {
    error "newly generated MIG is unexpectedly locked"
}
generate_target all $mig_ip

# The fixed core is already in core_edif.  Give Vivado only the active 1P
# platform shell instead of making it parse every unused core, L1/L2, AXI,
# coherence, and timing-model source in the general manifests.
set rtl_files {}
foreach relative_source [list \
    rtl/soc/platform.sv \
    rtl/soc/reset_sequencer.v \
    rtl/soc/bus/decode.v \
    rtl/soc/bus/rom.v \
    rtl/soc/bus/memory.v \
    rtl/clint/clint.v \
    rtl/plic/plic.v \
    rtl/periph/uart/uart.v \
    rtl/periph/gpio/gpio.v \
    rtl/periph/timer/timer.v] {
    lappend rtl_files [file normalize [file join $repo_root $relative_source]]
}
add_files -norecurse $rtl_files
add_files -norecurse $core_stub
add_files -norecurse $loader_stub
set_property file_type SystemVerilog [get_files $rtl_files]
set_property include_dirs [list [file join $repo_root rtl]] [current_fileset]
set_property verilog_define [list OPENRV64_FPGA_CORE_NETLIST \
    OPENRV64_FPGA_LOADER_NETLIST] [current_fileset]

set fpga_files [list \
    [file join $script_dir uart_banner.sv] \
    [file join $script_dir mig_scalar_bridge.sv] \
    [file join $script_dir scalar_mem_cdc.sv] \
    [file join $script_dir scalar_icx_arbiter.sv] \
    [file join $script_dir opensbi_boot_uart_status.sv] \
    [file join $script_dir opensbi_system.sv] \
    [file join $script_dir ${top_name}.sv]]
add_files -norecurse $fpga_files
add_files -norecurse [list \
    $trampoline_mem $firmware_mem $firmware_tail_mem $payload_mem $fdt_mem]

set constraint_file [file join $script_dir opensbi_smoke.xdc]
add_files -fileset constrs_1 -norecurse $constraint_file
set_property PROCESSING_ORDER LATE [get_files $constraint_file]

set_property top $top_name [current_fileset]
set_property generic [list \
    TRAMPOLINE_INIT_FILE=[file tail $trampoline_mem] \
    FIRMWARE_INIT_FILE=[file tail $firmware_mem] \
    FIRMWARE_TAIL_INIT_FILE=[file tail $firmware_tail_mem] \
    PAYLOAD_INIT_FILE=[file tail $payload_mem] \
    FDT_INIT_FILE=[file tail $fdt_mem] \
    TRAMPOLINE_WORDS=$trampoline_words \
    FIRMWARE_WORDS=$firmware_words \
    PAYLOAD_WORDS=$payload_words \
    FDT_WORDS=$fdt_words] [current_fileset]
update_compile_order -fileset sources_1

create_ip_run $mig_ip
launch_runs mig_7series_0_synth_1 -jobs 8
wait_on_run mig_7series_0_synth_1
if {[get_property PROGRESS [get_runs mig_7series_0_synth_1]] ne "100%"} {
    error "MIG synthesis did not complete"
}

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "top-level synthesis did not complete"
}
open_run synth_1
# Top synthesis intentionally sees only the fixed core and boot loader Verilog
# stubs. Fill those exact black-box cells from their compiled checkpoints after
# synthesis, then replace the run checkpoint consumed by implementation.
set loader_cells [get_cells -quiet -hierarchical \
    -filter {REF_NAME == openrv64_fpga_loader_fixed}]
if {[llength $loader_cells] != 1} {
    error "expected one synthesized openrv64_fpga_loader_fixed cell, found: $loader_cells"
}
read_checkpoint -cell [lindex $loader_cells 0] $loader_dcp
if {[get_property IS_BLACKBOX [lindex $loader_cells 0]]} {
    error "OpenRV64 FPGA loader checkpoint did not resolve its synthesized cell"
}
set core_cells [get_cells -quiet -hierarchical \
    -filter {REF_NAME == openrv64_fpga_core}]
if {[llength $core_cells] != 1} {
    error "expected one synthesized openrv64_fpga_core cell, found: $core_cells"
}
read_checkpoint -cell [lindex $core_cells 0] $core_dcp
if {[get_property IS_BLACKBOX [lindex $core_cells 0]]} {
    error "OpenRV64 FPGA core checkpoint did not resolve its synthesized cell"
}
set linked_synth_dcp [file join $output_dir post_synth_linked.dcp]
set synth_run_dcp [file join [get_property DIRECTORY [get_runs synth_1]] \
    ${top_name}.dcp]
write_checkpoint -force $linked_synth_dcp
report_utilization -file [file join $output_dir post_synth_utilization.rpt]
close_design
file copy -force $linked_synth_dcp $synth_run_dcp

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "implementation did not complete"
}

open_run impl_1
report_route_status -file [file join $output_dir route_status.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file [file join $output_dir timing_summary.rpt]
report_clock_interaction -file [file join $output_dir clock_interaction.rpt]
report_utilization -file [file join $output_dir utilization.rpt]
report_drc -file [file join $output_dir drc.rpt]
report_methodology -file [file join $output_dir methodology.rpt]
report_cdc -file [file join $output_dir cdc.rpt]
report_io -file [file join $output_dir io.rpt]

set setup_path [get_timing_paths -quiet -delay_type max -max_paths 1]
set hold_path [get_timing_paths -quiet -delay_type min -max_paths 1]
if {([llength $setup_path] == 0) || ([llength $hold_path] == 0)} {
    error "missing setup or hold timing paths"
}
set setup_slack [get_property SLACK [lindex $setup_path 0]]
set hold_slack [get_property SLACK [lindex $hold_path 0]]
if {$setup_slack < 0.0} {
    error "setup timing failed: WNS=$setup_slack ns"
}
if {$hold_slack < 0.0} {
    error "hold timing failed: WHS=$hold_slack ns"
}

set run_bit [file join $project_dir opensbi_smoke.runs impl_1 ${top_name}.bit]
if {![file isfile $run_bit]} {
    error "implementation completed without bitstream: $run_bit"
}
file copy -force $run_bit $output_bit

puts "OPENRV64 MYD-J7A100T OPENSBI SMOKE BITSTREAM BUILD PASS"
puts "Setup WNS: $setup_slack ns"
puts "Hold WHS: $hold_slack ns"
puts "Bitstream: $output_bit"
