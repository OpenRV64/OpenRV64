// Tomasulo Linux/platform harness.
//
// Keep the coherent platform, DDR3 model, boot ROM, devices, and checkpoint
// hierarchy source-identical to tb_4h_3p.  The separate source/model identity
// prevents Tomasulo-only diagnostics and build geometry from contaminating
// the baseline Linux simulator.
`define OPENRV64_TOMASULO_HARNESS
`include "tb/tb_4h_3p.sv"
