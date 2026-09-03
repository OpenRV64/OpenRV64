# SPDX-License-Identifier: CERN-OHL-P-2.0

if {$argc != 5} {
    error "usage: synth_vivado_3p_core.tcl <source-list> <constraints.xdc> <output-dir> <part> <repo-root>"
}

set source_list [file normalize [lindex $argv 0]]
set xdc_path [file normalize [lindex $argv 1]]
set output_dir [file normalize [lindex $argv 2]]
set part_name [lindex $argv 3]
set repo_root [file normalize [lindex $argv 4]]

if {[llength [get_parts -quiet $part_name]] == 0} {
    error "Vivado installation does not contain part: $part_name"
}
if {![file isfile $source_list] || ([file size $source_list] == 0)} {
    error "3P RTL source list not found: $source_list"
}
if {![file isfile $xdc_path] || ([file size $xdc_path] == 0)} {
    error "3P constraint file not found: $xdc_path"
}

set source_handle [open $source_list r]
set rtl_sources {}
foreach source [split [read $source_handle] "\n"] {
    if {$source ne ""} {
        lappend rtl_sources [file normalize $source]
    }
}
close $source_handle

file mkdir $output_dir
create_project -in_memory -part $part_name
set_property include_dirs [list [file join $repo_root rtl]] [current_fileset]
set_property verilog_define [list SYNTHESIS] [current_fileset]
read_verilog -sv $rtl_sources
read_xdc $xdc_path

set generics [list \
    RESET_VECTOR=2147483648 \
    ENABLE_RV64M=1 \
    ENABLE_RV64ZBB=1 \
    HPM_COUNTERS=8 \
    RETIRE_DEPTH=$::env(OPENRV64_SYNTH_RETIRE_DEPTH) \
    ISSUE_WINDOW_DEPTH=$::env(OPENRV64_SYNTH_ISSUE_WINDOW_DEPTH) \
    PHYS_REG_COUNT=$::env(OPENRV64_SYNTH_PHYS_REG_COUNT) \
    RENAME_MODE=$::env(OPENRV64_SYNTH_RENAME_MODE) \
    BANKED_GPR=$::env(OPENRV64_SYNTH_BANKED_GPR) \
    FPGA_GPR_LUTRAM=$::env(OPENRV64_SYNTH_FPGA_GPR_LUTRAM) \
    COMPLETION_FORWARD_MASK=0 \
    BRANCH_COMPLETION_FORWARD_MASK=$::env(OPENRV64_SYNTH_BRANCH_COMPLETION_FORWARD_MASK) \
    ENABLE_FULL_FORWARDING=0 \
    RELAX_WAW=$::env(OPENRV64_SYNTH_RELAX_WAW) \
    RELAX_HAZARDS=0 \
    FREE_BRANCHES=0 \
    ENABLE_EQ_BRANCH_PAIRING=1 \
    ENABLE_ISSUE_WINDOW=$::env(OPENRV64_SYNTH_ISSUE_WINDOW) \
    ENABLE_SPECULATION_WINDOW=$::env(OPENRV64_SYNTH_SPECULATION_WINDOW) \
    ENABLE_POSTED_STORES=1 \
    ENABLE_ZICCLSM=1 \
    STORE_QUEUE_DEPTH=4 \
    ENABLE_RV64A=1 \
    ENABLE_L1I=$::env(OPENRV64_SYNTH_ENABLE_L1I) \
    ENABLE_L1D=$::env(OPENRV64_SYNTH_ENABLE_L1D) \
    L1D_RETIRED_STORE_MSHR_CANONICAL=$::env(OPENRV64_SYNTH_L1D_RETIRED_STORE_MSHR_CANONICAL) \
    L2_TLB_ENTRIES=256 \
    L2_TLB_WAYS=4 \
    PTW_PTE_CACHE_ENTRIES=64 \
    ENABLE_TRACE=0 \
    ENABLE_PREDECODE_TARGETS=1 \
    ENABLE_FETCH_CAROUSEL=1 \
    ENABLE_FETCH_ALT_LOOKASIDE=3 \
    ENABLE_FETCH_ALT_CONFIDENCE_GATE=1 \
    BP_TYPE=8 \
    BP_RAS_ENABLE=1 \
    BP_RAS_DEPTH=8 \
    BP_BIMODAL_ENTRIES=32 \
    BP_BIMODAL_COUNTER_BITS=3 \
    BP_BIMODAL_UPDATE_DEPTH=4 \
    BP_GSHARE_ENTRIES=256 \
    BP_GSHARE_COUNTER_BITS=3 \
    BP_BTB_ENTRIES=256 \
    BP_BTB_TAG_BITS=16 \
    BP_INFLIGHT_DEPTH=16]

set synth_args [list -top openrv64_top_3p -part $part_name \
    -mode out_of_context -flatten_hierarchy none -generic $generics]
if {$::env(OPENRV64_SYNTH_NO_TIMING_DRIVEN) != 0} {
    lappend synth_args -no_timing_driven
}
synth_design {*}$synth_args

set unresolved_cells [get_cells -quiet -hierarchical -filter {IS_BLACKBOX}]
if {[llength $unresolved_cells] != 0} {
    error "3P synthesis contains unresolved cells: $unresolved_cells"
}

report_utilization -file [file join $output_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 \
    -file [file join $output_dir utilization_hierarchical.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $output_dir timing_synth.rpt]
write_checkpoint -force [file join $output_dir openrv64_core_3p.dcp]

puts "OPENRV64 XC7K480T 3P VIVADO RTL SYNTHESIS PASS part=$part_name report=[file join $output_dir utilization.rpt]"
