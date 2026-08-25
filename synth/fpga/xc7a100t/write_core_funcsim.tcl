if {$argc != 2} {
    error "usage: vivado -mode batch -source write_core_funcsim.tcl -tclargs INPUT_DCP OUTPUT_VERILOG"
}

set input_dcp [file normalize [lindex $argv 0]]
set output_verilog [file normalize [lindex $argv 1]]

open_checkpoint $input_dcp
write_verilog -force -mode funcsim $output_verilog
close_design
