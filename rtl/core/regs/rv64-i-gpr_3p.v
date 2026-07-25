`include "core/isa/rv64-i.v"
`include "core/regs/prf.v"
`timescale 1ns/1ps

// Six-read, three-write integer PRF wrapper for the 3P backend.
//
// NUM_REGS counts writable storage entries and excludes hardwired p0.
// External physical tags remain p0 through pNUM_REGS; pN maps to storage
// entry N-1. Higher-numbered retirement ports retain the previous duplicate
// write and bypass priority.
module openrv64_rv64i_gpr_3p #(
    parameter RESET_REGS = 1,
    parameter READ_WRITE_BYPASS = 1,
    parameter ALLOW_DUPLICATE_WRITES = 0,
    parameter integer NUM_REGS = 31,
    parameter integer REG_ADDR_WIDTH =
        (NUM_REGS < 1) ? 1 : $clog2(NUM_REGS + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire [6*REG_ADDR_WIDTH-1:0]  read_addr_i,
    output wire [6*`RV64_XLEN-1:0]      read_data_o,

    input  wire [2:0]                   write_valid_i,
    input  wire [3*REG_ADDR_WIDTH-1:0]  write_addr_i,
    input  wire [3*`RV64_XLEN-1:0]      write_data_i
);

    wire [5:0] read_ready_unused;
    wire [2:0] write_ready_unused;
    wire [NUM_REGS*`RV64_XLEN-1:0] prf_debug_regs;
    wire [5:0] storage_read_valid;
    wire [6*REG_ADDR_WIDTH-1:0] storage_read_addr;
    wire [2:0] storage_write_valid;
    wire [3*REG_ADDR_WIDTH-1:0] storage_write_addr;

    genvar read_port;
    generate
        for (read_port = 0; read_port < 6;
             read_port = read_port + 1) begin : g_read_address
            wire [REG_ADDR_WIDTH-1:0] physical_tag =
                read_addr_i[
                    read_port*REG_ADDR_WIDTH +: REG_ADDR_WIDTH];
            assign storage_read_valid[read_port] = physical_tag != 0;
            assign storage_read_addr[
                read_port*REG_ADDR_WIDTH +: REG_ADDR_WIDTH] =
                physical_tag - REG_ADDR_WIDTH'(1);
        end
    endgenerate

    genvar write_port;
    generate
        for (write_port = 0; write_port < 3;
             write_port = write_port + 1) begin : g_write_address
            wire [REG_ADDR_WIDTH-1:0] physical_tag =
                write_addr_i[
                    write_port*REG_ADDR_WIDTH +: REG_ADDR_WIDTH];
            assign storage_write_valid[write_port] =
                write_valid_i[write_port] && (physical_tag != 0);
            assign storage_write_addr[
                write_port*REG_ADDR_WIDTH +: REG_ADDR_WIDTH] =
                physical_tag - REG_ADDR_WIDTH'(1);
        end
    endgenerate

    openrv64_prf #(
        .DATA_WIDTH(`RV64_XLEN),
        .NUM_REGS(NUM_REGS),
        .REG_ADDR_WIDTH(REG_ADDR_WIDTH),
        .NUM_SLICES(1),
        .SLICE_ADDR_WIDTH(1),
        .NUM_BANKS(1),
        .READ_PORTS(6),
        .WRITE_PORTS(3),
        .READ_PORTS_PER_BANK(6),
        .WRITE_PORTS_PER_BANK(3),
        .ZERO_REG_ENABLE(0),
        .RESET_REGS(RESET_REGS),
        .READ_WRITE_BYPASS(READ_WRITE_BYPASS),
        .ALLOW_DUPLICATE_WRITES(ALLOW_DUPLICATE_WRITES)
    ) u_prf (
        .clk(clk),
        .rst_n(rst_n),
        .read_valid_i(storage_read_valid),
        .read_ready_o(read_ready_unused),
        .read_addr_i(storage_read_addr),
        .read_slice_i(6'b00_0000),
        .read_data_o(read_data_o),
        .write_valid_i(storage_write_valid),
        .write_ready_o(write_ready_unused),
        .write_addr_i(storage_write_addr),
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
                (reg_alias-1)*`RV64_XLEN +: `RV64_XLEN];
        end
    endgenerate

`ifndef SYNTHESIS
    initial begin
        if (NUM_REGS < 31)
            $fatal(1, "3P identity PRF needs 31 writable registers");
        if ((1 << REG_ADDR_WIDTH) <= NUM_REGS)
            $fatal(1, "3P physical tag width cannot address pNUM_REGS");
    end
`endif

endmodule
