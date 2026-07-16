`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/fetch/fetch.v"
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

    logic [63:0] pc_q;
    logic [63:0] dbg_pc_q;
    logic [31:0] instr_q;
    logic        halted_q;

    wire                             fetch_pc_ready;
    wire                             fetch_pc_valid;
    wire                             fetch_decode_valid;
    wire [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] fetch_decode_bus;
    wire [63:0]                      fetch_decode_pc;
    wire [31:0]                      fetch_decode_instr;

    assign fetch_pc_valid = fetch_pc_ready && !halted_q;

    openrv64_fetch u_fetch (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(1'b0),
        .pc_ready_o(fetch_pc_ready),
        .pc_valid_i(fetch_pc_valid),
        .pc_i(pc_q),
        .mem_valid_o(mem_valid),
        .mem_ready_i(mem_ready),
        .mem_write_o(mem_write),
        .mem_addr_o(mem_addr),
        .mem_wdata_o(mem_wdata),
        .mem_wstrb_o(mem_wstrb),
        .mem_rdata_i(mem_rdata),
        .decode_valid_o(fetch_decode_valid),
        .decode_ready_i(1'b1),
        .decode_bus_o(fetch_decode_bus),
        .decode_pc_o(fetch_decode_pc),
        .decode_instr_o(fetch_decode_instr)
    );

    wire unused_fetch_decode_bus = |fetch_decode_bus;

    assign dbg_pc     = dbg_pc_q;
    assign dbg_instr  = instr_q;
    assign dbg_halted = halted_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_q      <= RESET_VECTOR;
            dbg_pc_q  <= RESET_VECTOR;
            instr_q   <= `RV64_INSTR_NOP;
            halted_q  <= 1'b0;
        end else begin
            if (fetch_decode_valid) begin
                dbg_pc_q <= fetch_decode_pc;
                instr_q  <= fetch_decode_instr;

                if (fetch_decode_instr == `RV64_INSTR_EBREAK) begin
                    halted_q <= 1'b1;
                end else begin
                    pc_q <= fetch_decode_pc + 64'd4;
                end
            end
        end
    end

endmodule
