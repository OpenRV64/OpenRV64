`include "core/isa/rv64-i.v"
`include "core/regs/prf.v"
`timescale 1ns/1ps

// Architectural two-read, one-write GPR compatibility wrapper.  Storage and
// bypass behavior live in the parameterized physical register file.
module openrv64_rv64i_gpr #(
    parameter RESET_REGS = 1,
    parameter READ_WRITE_BYPASS = 1
) (
    input  wire                             clk,
    input  wire                             rst_n,

    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr_i,
    output wire [`RV64_XLEN-1:0]           rs1_data_o,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr_i,
    output wire [`RV64_XLEN-1:0]           rs2_data_o,

    input  wire                             rd_write_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr_i,
    input  wire [`RV64_XLEN-1:0]           rd_data_i
);

    wire [2*`RV64_REG_ADDR_WIDTH-1:0] read_addr =
        {rs2_addr_i, rs1_addr_i};
    wire [2*`RV64_XLEN-1:0] read_data;
    wire [1:0] read_ready_unused;
    wire write_ready_unused;
    wire [32*`RV64_XLEN-1:0] prf_debug_regs;

    openrv64_prf #(
        .DATA_WIDTH(`RV64_XLEN),
        .NUM_REGS(32),
        .REG_ADDR_WIDTH(`RV64_REG_ADDR_WIDTH),
        .NUM_SLICES(1),
        .SLICE_ADDR_WIDTH(1),
        .NUM_BANKS(1),
        .READ_PORTS(2),
        .WRITE_PORTS(1),
        .READ_PORTS_PER_BANK(2),
        .WRITE_PORTS_PER_BANK(1),
        .ZERO_REG_ENABLE(1),
        .ZERO_REG_INDEX(`RV64_REG_X0),
        .RESET_REGS(RESET_REGS),
        .READ_WRITE_BYPASS(READ_WRITE_BYPASS),
        .ALLOW_DUPLICATE_WRITES(0)
    ) u_prf (
        .clk(clk),
        .rst_n(rst_n),
        .read_valid_i(2'b11),
        .read_ready_o(read_ready_unused),
        .read_addr_i(read_addr),
        .read_slice_i(2'b00),
        .read_data_o(read_data),
        .write_valid_i(rd_write_i),
        .write_ready_o(write_ready_unused),
        .write_addr_i(rd_addr_i),
        .write_slice_i(1'b0),
        .write_data_i(rd_data_i),
        .debug_regs_o(prf_debug_regs)
    );

    assign rs1_data_o = read_data[0*`RV64_XLEN +: `RV64_XLEN];
    assign rs2_data_o = read_data[1*`RV64_XLEN +: `RV64_XLEN];

    // Existing integration tests inspect u_gpr.regs[N].  Keep that stable as
    // a read-only compatibility view while the actual state lives in u_prf.
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
