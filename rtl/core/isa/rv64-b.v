`ifndef OPENRV64_RV64_B_V
`define OPENRV64_RV64_B_V

`include "core/isa/rv64-zba.v"
`include "core/isa/rv64-zbb.v"
`include "core/isa/rv64-zbs.v"

// The ratified scalar B extension is the aggregate of Zba, Zbb, and Zbs.
// Zbc is a separate bitmanip extension and is intentionally not included here.
`define RV64_B_HAS_ZBA 1
`define RV64_B_HAS_ZBB 1
`define RV64_B_HAS_ZBS 1

`endif
