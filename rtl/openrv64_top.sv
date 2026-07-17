`timescale 1ns/1ps

module openrv64_top #(
    parameter logic [63:0] RESET_VECTOR = 64'h0000_0000_0000_0000
) (
    input  logic        clk,
    input  logic        rst_n,

    // Simple blocking memory bus. The core holds mem_valid and all request
    // fields stable until the memory target raises mem_ready for one cycle.
    output logic        mem_valid,
    input  logic        mem_ready,
    output logic        mem_write,
    output logic [63:0] mem_addr,
    output logic [63:0] mem_wdata,
    output logic [7:0]  mem_wstrb,
    input  logic [63:0] mem_rdata,

    output logic [63:0] dbg_pc,
    output logic [31:0] dbg_instr,
    output logic        dbg_halted
);

    openrv64_rv64_top #(
        .RESET_VECTOR(RESET_VECTOR)
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
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted)
    );

endmodule
