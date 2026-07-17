`timescale 1ns/1ps
`include "soc/bus/mem_map.v"
`include "core/exec/bp/defs.v"

module openrv64_top #(
    parameter logic [63:0] RESET_VECTOR = `OPENRV64_SOC_RESET_VECTOR,
    parameter bit ENABLE_RV64M = 1'b0,
    parameter bit ENABLE_FORWARDING = 1'b1,
    parameter bit ENABLE_LOAD_FORWARDING = 1'b0,
    parameter bit ENABLE_TRACE = 1'b0,
    parameter logic [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE =
        `OPENRV64_BP_STALL
) (
    input  logic        clk,
    input  logic        rst_n,

    // Simple blocking memory bus. The core holds mem_valid and all request
    // fields stable through a mem_ready completion. mem_error marks an access
    // fault on that completion.
    output logic        mem_valid,
    input  logic        mem_ready,
    output logic        mem_write,
    output logic [63:0] mem_addr,
    output logic [63:0] mem_wdata,
    output logic [7:0]  mem_wstrb,
    input  logic [63:0] mem_rdata,
    input  logic        mem_error,

    input  logic        irq_m_software,
    input  logic        irq_m_timer,
    input  logic        irq_m_external,
    input  logic        irq_s_software,
    input  logic        irq_s_timer,
    input  logic        irq_s_external,

    output logic [63:0] dbg_pc,
    output logic [31:0] dbg_instr,
    output logic        dbg_halted,

    // Optional, synthesizable cycle trace. Packed stage order is
    // 0=IF, 1=ID, 2=EX, 3=MEM, 4=WB (least to most significant slice).
    output logic [63:0]  trace_cycle,
    output logic [4:0]   trace_valid,
    output logic [4:0]   trace_stall,
    output logic [4:0]   trace_flush,
    output logic [4:0]   trace_advance,
    output logic [319:0] trace_ids,
    output logic [319:0] trace_pcs,
    output logic [159:0] trace_instrs,
    output logic [7:0]   trace_events,
    output logic [7:0]   trace_stall_causes,
    output logic         trace_retire_valid,
    output logic         trace_retire_arch,
    output logic         trace_retire_exception,
    output logic [4:0]   trace_retire_cause,
    output logic [63:0]  trace_retire_next_pc,
    output logic         trace_retire_rd_write,
    output logic [4:0]   trace_retire_rd,
    output logic [63:0]  trace_retire_wdata
);

    openrv64_rv64_top #(
        .RESET_VECTOR(RESET_VECTOR),
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_FORWARDING(ENABLE_FORWARDING),
        .ENABLE_LOAD_FORWARDING(ENABLE_LOAD_FORWARDING),
        .ENABLE_TRACE(ENABLE_TRACE),
        .BP_TYPE(BP_TYPE)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .mem_valid(mem_valid),
        .mem_ready(mem_ready),
        .mem_write(mem_write),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .mem_error(mem_error),
        .irq_m_software(irq_m_software),
        .irq_m_timer(irq_m_timer),
        .irq_m_external(irq_m_external),
        .irq_s_software(irq_s_software),
        .irq_s_timer(irq_s_timer),
        .irq_s_external(irq_s_external),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted),
        .trace_cycle(trace_cycle),
        .trace_valid(trace_valid),
        .trace_stall(trace_stall),
        .trace_flush(trace_flush),
        .trace_advance(trace_advance),
        .trace_ids(trace_ids),
        .trace_pcs(trace_pcs),
        .trace_instrs(trace_instrs),
        .trace_events(trace_events),
        .trace_stall_causes(trace_stall_causes),
        .trace_retire_valid(trace_retire_valid),
        .trace_retire_arch(trace_retire_arch),
        .trace_retire_exception(trace_retire_exception),
        .trace_retire_cause(trace_retire_cause),
        .trace_retire_next_pc(trace_retire_next_pc),
        .trace_retire_rd_write(trace_retire_rd_write),
        .trace_retire_rd(trace_retire_rd),
        .trace_retire_wdata(trace_retire_wdata)
    );

endmodule
