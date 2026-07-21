`timescale 1ns/1ps
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

`define OPENRV64_CCX_FIXED_MODULE openrv64_ccx_protocol_wrapper_4h
`define OPENRV64_CCX_FIXED_HARTS 4
`include "complex/protocol/wrapper_fixed_template.vh"
`undef OPENRV64_CCX_FIXED_HARTS
`undef OPENRV64_CCX_FIXED_MODULE
