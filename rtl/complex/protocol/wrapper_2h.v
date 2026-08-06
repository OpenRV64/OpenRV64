`timescale 1ns/1ps
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

`define OPENRV64_ICX_FIXED_MODULE openrv64_icx_protocol_wrapper_2h
`define OPENRV64_ICX_FIXED_HARTS 2
`include "complex/protocol/wrapper_fixed_template.vh"
`undef OPENRV64_ICX_FIXED_HARTS
`undef OPENRV64_ICX_FIXED_MODULE
