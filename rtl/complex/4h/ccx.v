`timescale 1ns/1ps
`include "complex/coherent/protocol/defs.v"

// Fixed four-hart coherence-control variant.  This is not yet the complete
// CCX request/L2 datapath; it provides the directory and probe contract on
// which that datapath will be built.
`define OPENRV64_CCX_COHERENT_FIXED_MODULE openrv64_ccx_4h_control
`define OPENRV64_CCX_COHERENT_FIXED_HARTS 4
`include "complex/coherent/wrapper_fixed_template.vh"
`undef OPENRV64_CCX_COHERENT_FIXED_HARTS
`undef OPENRV64_CCX_COHERENT_FIXED_MODULE
