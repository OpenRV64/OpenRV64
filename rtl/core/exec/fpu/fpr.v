`ifndef OPENRV64_RV64FD_FPR_V
`define OPENRV64_RV64FD_FPR_V

`include "core/exec/fpu/isa/rv64-d.v"
`include "core/regs/prf.v"
`timescale 1ns/1ps

// FPU-owned architectural RV64F/RV64D floating-point register file.
//
// The FPRs remain identity-mapped architectural state: there is no rename
// table, free list, or physical readiness state here.  Three reads cover the
// rs1/rs2/rs3 operands required by fused operations, while the single write
// port matches ordered architectural writeback.  Unlike the integer file,
// f0 is an ordinary writable register.
//
// Values are stored bit-for-bit.  Producers of binary32 results are
// responsible for architectural NaN boxing before writeback.
module openrv64_rv64fd_fpr #(
    parameter integer FLEN = 64,
    parameter integer RESET_REGS = 1,
    parameter integer READ_WRITE_BYPASS = 1
) (
    input  wire                             clk,
    input  wire                             rst_n,

    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr_i,
    output wire [FLEN-1:0]                 rs1_data_o,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr_i,
    output wire [FLEN-1:0]                 rs2_data_o,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs3_addr_i,
    output wire [FLEN-1:0]                 rs3_data_o,

    input  wire                             rd_write_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr_i,
    input  wire [FLEN-1:0]                 rd_data_i
);

    localparam integer NUM_FPRS = 32;

    wire [3*`RV64_REG_ADDR_WIDTH-1:0] read_addr =
        {rs3_addr_i, rs2_addr_i, rs1_addr_i};
    wire [3*FLEN-1:0] read_data;
    wire [2:0] read_ready_unused;
    wire write_ready_unused;
    wire [NUM_FPRS*FLEN-1:0] prf_debug_regs;

    openrv64_prf #(
        .DATA_WIDTH(FLEN),
        .NUM_REGS(NUM_FPRS),
        .REG_ADDR_WIDTH(`RV64_REG_ADDR_WIDTH),
        .NUM_SLICES(1),
        .SLICE_ADDR_WIDTH(1),
        .NUM_BANKS(1),
        .READ_PORTS(3),
        .WRITE_PORTS(1),
        .READ_PORTS_PER_BANK(3),
        .WRITE_PORTS_PER_BANK(1),
        .ZERO_REG_ENABLE(0),
        .RESET_REGS(RESET_REGS),
        .READ_WRITE_BYPASS(READ_WRITE_BYPASS),
        .ALLOW_DUPLICATE_WRITES(0)
    ) u_prf (
        .clk(clk),
        .rst_n(rst_n),
        .read_valid_i(3'b111),
        .read_ready_o(read_ready_unused),
        .read_addr_i(read_addr),
        .read_slice_i(3'b000),
        .read_data_o(read_data),
        .write_valid_i(rd_write_i),
        .write_ready_o(write_ready_unused),
        .write_addr_i(rd_addr_i),
        .write_slice_i(1'b0),
        .write_data_i(rd_data_i),
        .debug_regs_o(prf_debug_regs)
    );

    assign rs1_data_o = read_data[0*FLEN +: FLEN];
    assign rs2_data_o = read_data[1*FLEN +: FLEN];
    assign rs3_data_o = read_data[2*FLEN +: FLEN];

    // Read-only hierarchy-visible view, matching the existing integer GPR
    // compatibility seam.  All 32 FPRs are present because f0 is writable.
    wire [FLEN-1:0] regs [0:NUM_FPRS-1];
    genvar reg_alias;
    generate
        for (reg_alias = 0; reg_alias < NUM_FPRS;
             reg_alias = reg_alias + 1) begin : g_reg_alias
            assign regs[reg_alias] = prf_debug_regs[
                reg_alias*FLEN +: FLEN];
        end
    endgenerate

`ifndef SYNTHESIS
    initial begin
        if ((FLEN != 32) && (FLEN != 64))
            $fatal(1, "FPR FLEN must be 32 or 64");
    end
`endif

endmodule

`endif
