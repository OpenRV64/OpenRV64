# SPDX-License-Identifier: CERN-OHL-P-2.0

if {$argc != 2} {
    error "usage: report_dispatch_rename_breakdown.tcl <checkpoint.dcp> <output-dir>"
}

set checkpoint [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]

if {![file isfile $checkpoint] || ([file size $checkpoint] == 0)} {
    error "synthesis checkpoint not found: $checkpoint"
}

file mkdir $output_dir
open_checkpoint $checkpoint

report_utilization -hierarchical -hierarchical_depth 8 \
    -file [file join $output_dir utilization_hierarchical_depth8.rpt]

set inventory_path [file join $output_dir dispatch_rename_cells.tsv]
set inventory [open $inventory_path w]
puts $inventory "scope\tref_name\tcell_name"

set scopes [list \
    [list scheduler "u_core/u_backend/u_dispatch/g_3p.u_tomasulo_window"] \
    [list rename "u_core/u_backend/u_dispatch/g_3p.g_tomasulo.u_rename"]]

foreach scope_spec $scopes {
    lassign $scope_spec scope_name scope_root
    set scope_pattern "${scope_root}/*"
    foreach cell [get_cells -quiet -hierarchical \
            -filter "NAME =~ $scope_pattern"] {
        if {[get_property IS_PRIMITIVE $cell]} {
            puts $inventory [join [list $scope_name \
                [get_property REF_NAME $cell] $cell] "\t"]
        }
    }
}
close $inventory

puts "OPENRV64 XC7K480T DISPATCH RENAME BREAKDOWN PASS report=[file join $output_dir utilization_hierarchical_depth8.rpt] inventory=$inventory_path"
