`include "core/isa/rv64-i.v"
`include "core/regs/prf.v"
`timescale 1ns/1ps

// Six-read, three-write architectural GPR compatibility wrapper for the 3P
// backend.  Higher-numbered retirement ports retain the previous duplicate
// write and bypass priority.
module openrv64_rv64i_gpr_3p #(
    parameter RESET_REGS = 1,
    parameter READ_WRITE_BYPASS = 1,
    parameter ALLOW_DUPLICATE_WRITES = 0
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire [6*`RV64_REG_ADDR_WIDTH-1:0] read_addr_i,
    output wire [6*`RV64_XLEN-1:0]      read_data_o,

    input  wire [2:0]                   write_valid_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] write_addr_i,
    input  wire [3*`RV64_XLEN-1:0]      write_data_i
);

    wire [5:0] read_ready_unused;
    wire [2:0] write_ready_unused;
    wire [32*`RV64_XLEN-1:0] prf_debug_regs;

    openrv64_prf #(
        .DATA_WIDTH(`RV64_XLEN),
        .NUM_REGS(32),
        .REG_ADDR_WIDTH(`RV64_REG_ADDR_WIDTH),
        .NUM_SLICES(1),
        .SLICE_ADDR_WIDTH(1),
        .NUM_BANKS(1),
        .READ_PORTS(6),
        .WRITE_PORTS(3),
        .READ_PORTS_PER_BANK(6),
        .WRITE_PORTS_PER_BANK(3),
        .ZERO_REG_ENABLE(1),
        .ZERO_REG_INDEX(`RV64_REG_X0),
        .RESET_REGS(RESET_REGS),
        .READ_WRITE_BYPASS(READ_WRITE_BYPASS),
        .ALLOW_DUPLICATE_WRITES(ALLOW_DUPLICATE_WRITES)
    ) u_prf (
        .clk(clk),
        .rst_n(rst_n),
        .read_valid_i(6'b11_1111),
        .read_ready_o(read_ready_unused),
        .read_addr_i(read_addr_i),
        .read_slice_i(6'b00_0000),
        .read_data_o(read_data_o),
        .write_valid_i(write_valid_i),
        .write_ready_o(write_ready_unused),
        .write_addr_i(write_addr_i),
        .write_slice_i(3'b000),
        .write_data_i(write_data_i),
        .debug_regs_o(prf_debug_regs)
    );

    // Stable hierarchy-visible architectural view used by existing tests.
    wire [`RV64_XLEN-1:0] regs [1:31];
    genvar reg_alias;
    generate
        for (reg_alias = 1; reg_alias < 32;
             reg_alias = reg_alias + 1) begin : g_reg_alias
            assign regs[reg_alias] = prf_debug_regs[
                reg_alias*`RV64_XLEN +: `RV64_XLEN];
        end
    endgenerate

endmodule
