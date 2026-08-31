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
    parameter BANKED = 0,
    parameter FPGA_LUTRAM = 0,
    parameter integer NUM_REGS = 31,
    parameter integer REG_ADDR_WIDTH =
        (NUM_REGS < 1) ? 1 : $clog2(NUM_REGS + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire [6*REG_ADDR_WIDTH-1:0]  read_addr_i,
    output wire [6*`RV64_XLEN-1:0]      read_data_o,
    input  wire [5:0]                   read_req_i,
    output wire [5:0]                   read_valid_o,

    input  wire [2:0]                   write_valid_i,
    input  wire [3*REG_ADDR_WIDTH-1:0]  write_addr_i,
    input  wire [3*`RV64_XLEN-1:0]      write_data_i,
    output wire [2:0]                   write_ready_o,
    output wire                         quiescent_o
);

    wire [NUM_REGS*`RV64_XLEN-1:0] prf_debug_regs;
    generate
        if (BANKED != 0) begin : g_banked
            wire [3:0] banked_read_valid;
            wire [1:0] banked_write_valid;
            wire [3:0] banked_read_req;
            wire [1:0] banked_write_req;
            wire [3:0] banked_read_zero;
            wire [1:0] banked_write_zero;
            wire [4*`RV64_XLEN-1:0] banked_read_data_raw;
            wire [4*`RV64_XLEN-1:0] banked_read_data;

            genvar banked_read_port;
            for (banked_read_port = 0; banked_read_port < 4;
                 banked_read_port = banked_read_port + 1) begin : g_read_zero
                assign banked_read_zero[banked_read_port] =
                    read_addr_i[
                        banked_read_port*REG_ADDR_WIDTH +:
                        REG_ADDR_WIDTH] == {REG_ADDR_WIDTH{1'b0}};
                assign banked_read_req[banked_read_port] =
                    read_req_i[banked_read_port] &&
                    !banked_read_zero[banked_read_port];
                assign banked_read_data[
                    banked_read_port*`RV64_XLEN +: `RV64_XLEN] =
                    banked_read_zero[banked_read_port] ?
                    {`RV64_XLEN{1'b0}} : banked_read_data_raw[
                        banked_read_port*`RV64_XLEN +: `RV64_XLEN];
            end

            genvar banked_write_port;
            for (banked_write_port = 0; banked_write_port < 2;
                 banked_write_port = banked_write_port + 1) begin : g_write_zero
                assign banked_write_zero[banked_write_port] =
                    write_addr_i[
                        banked_write_port*REG_ADDR_WIDTH +:
                        REG_ADDR_WIDTH] == {REG_ADDR_WIDTH{1'b0}};
                assign banked_write_req[banked_write_port] =
                    write_valid_i[banked_write_port] &&
                    !banked_write_zero[banked_write_port];
            end

            cmn_reg_file #(
                .REG_WIDTH(`RV64_XLEN),
                .REG_COUNT(32),
                .READ_PORTS(4),
                .WRITE_PORTS(2),
                .BANK_SIZE(16),
                .NUM_BANKS(2),
                .FPGA_LUTRAM(FPGA_LUTRAM)
            ) u_reg_file (
                .clk(clk),
                .rst_n(rst_n),
                .rp_addr_i(read_addr_i[4*REG_ADDR_WIDTH-1:0]),
                .rp_data_o(banked_read_data_raw),
                .rp_req_i(banked_read_req),
                .rp_valid_o(banked_read_valid),
                .wp_addr_i(write_addr_i[2*REG_ADDR_WIDTH-1:0]),
                .wp_data_i(write_data_i[2*`RV64_XLEN-1:0]),
                .wp_req_i(banked_write_req),
                .wp_valid_o(banked_write_valid),
                .quiescent_o(quiescent_o)
            );

            assign read_data_o = {
                {2*`RV64_XLEN{1'b0}}, banked_read_data
            };
            assign read_valid_o = {
                2'b00, banked_read_valid
            };
            assign write_ready_o = {
                1'b0,
                banked_write_valid |
                    (write_valid_i[1:0] & banked_write_zero)
            };

`ifndef SYNTHESIS
            assign prf_debug_regs = u_reg_file.prf_debug_regs;
`else
            assign prf_debug_regs = {NUM_REGS*`RV64_XLEN{1'b0}};
`endif
        end else begin : g_legacy
            wire [5:0] read_ready_unused;
            wire [2:0] write_ready_unused;
            wire [5:0] storage_read_valid;
            wire [6*REG_ADDR_WIDTH-1:0] storage_read_addr;
            wire [2:0] storage_write_valid;
            wire [3*REG_ADDR_WIDTH-1:0] storage_write_addr;

            genvar read_port;
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

            genvar write_port;
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

            assign read_valid_o = 6'b11_1111;
            assign write_ready_o = 3'b111;
            assign quiescent_o = 1'b1;
        end
    endgenerate

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
        if ((BANKED != 0) &&
            ((NUM_REGS != 31) || (REG_ADDR_WIDTH != 5)))
            $fatal(1, "banked 3P GPR requires architectural p0-p31 tags");
    end
`endif

endmodule
