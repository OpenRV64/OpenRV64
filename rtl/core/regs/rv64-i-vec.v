`include "core/regs/prf.v"
`timescale 1ns/1ps

// Private vector register-file compatibility wrapper.  Every port moves one
// SLICE_WIDTH chunk; LMUL affects address sequencing in the execution units
// and never widens this interface.  The default physical organization is two
// parity-interleaved banks, each with two read slots and one write slot.
module openrv64_rv64i_vec #(
    parameter integer VLEN = 256,
    parameter integer SLICE_WIDTH = 64,
    parameter integer NUM_REGS = 32,
    parameter integer REG_ADDR_WIDTH = 5,
    parameter integer SLICE_ADDR_WIDTH =
        ((VLEN / SLICE_WIDTH) <= 1) ? 1 : $clog2(VLEN / SLICE_WIDTH),
    parameter integer NUM_BANKS = 2,
    parameter integer READ_PORTS_PER_BANK = 2,
    parameter integer WRITE_PORTS_PER_BANK = 1,
    parameter integer RESET_REGS = 1,
    parameter integer READ_WRITE_BYPASS = 1
) (
    input  wire                              clk,
    input  wire                              rst_n,

    input  wire [3:0]                        read_valid_i,
    output wire [3:0]                        read_ready_o,
    input  wire [4*REG_ADDR_WIDTH-1:0]       read_addr_i,
    input  wire [4*SLICE_ADDR_WIDTH-1:0]     read_slice_i,
    output wire [4*SLICE_WIDTH-1:0]          read_data_o,

    input  wire [1:0]                        write_valid_i,
    output wire [1:0]                        write_ready_o,
    input  wire [2*REG_ADDR_WIDTH-1:0]       write_addr_i,
    input  wire [2*SLICE_ADDR_WIDTH-1:0]     write_slice_i,
    input  wire [2*SLICE_WIDTH-1:0]          write_data_i
);

    localparam integer NUM_SLICES = VLEN / SLICE_WIDTH;

    openrv64_prf #(
        .DATA_WIDTH(SLICE_WIDTH),
        .NUM_REGS(NUM_REGS),
        .REG_ADDR_WIDTH(REG_ADDR_WIDTH),
        .NUM_SLICES(NUM_SLICES),
        .SLICE_ADDR_WIDTH(SLICE_ADDR_WIDTH),
        .NUM_BANKS(NUM_BANKS),
        .READ_PORTS(4),
        .WRITE_PORTS(2),
        .READ_PORTS_PER_BANK(READ_PORTS_PER_BANK),
        .WRITE_PORTS_PER_BANK(WRITE_PORTS_PER_BANK),
        .ZERO_REG_ENABLE(0),
        .RESET_REGS(RESET_REGS),
        .READ_WRITE_BYPASS(READ_WRITE_BYPASS),
        .ALLOW_DUPLICATE_WRITES(0)
    ) u_prf (
        .clk(clk),
        .rst_n(rst_n),
        .read_valid_i(read_valid_i),
        .read_ready_o(read_ready_o),
        .read_addr_i(read_addr_i),
        .read_slice_i(read_slice_i),
        .read_data_o(read_data_o),
        .write_valid_i(write_valid_i),
        .write_ready_o(write_ready_o),
        .write_addr_i(write_addr_i),
        .write_slice_i(write_slice_i),
        .write_data_i(write_data_i),
        .debug_regs_o()
    );

`ifndef SYNTHESIS
    initial begin
        if ((VLEN <= 0) || (SLICE_WIDTH <= 0) ||
            ((VLEN % SLICE_WIDTH) != 0))
            $fatal(1, "VLEN must be a positive multiple of SLICE_WIDTH");
    end
`endif

endmodule
