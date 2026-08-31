`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

// 1P architectural GPR adapter.  The banked implementation uses registered
// reads and therefore holds each dispatch operand until both are available.
// The legacy branch is retained for direct A/B comparison during bring-up.
module openrv64_rv64i_gpr_1p #(
    parameter BANKED = 1,
    parameter FPGA_LUTRAM = 0
) (
    input  wire                             clk,
    input  wire                             rst_n,

    input  wire                             read_valid_i,
    input  wire                             read_clear_i,
    input  wire                             read_flush_i,
    output wire                             read_ready_o,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr_i,
    output wire [`RV64_XLEN-1:0]           rs1_data_o,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr_i,
    output wire [`RV64_XLEN-1:0]           rs2_data_o,

    input  wire                             rd_write_i,
    input  wire                             rd_clear_i,
    output wire                             rd_ready_o,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr_i,
    input  wire [`RV64_XLEN-1:0]           rd_data_i
);

    // Existing 1P integration tests inspect u_gpr.regs[N].  Preserve that
    // simulation-only architectural view for both implementations.
`ifndef SYNTHESIS
    wire [`RV64_XLEN-1:0] regs [1:31];
`endif

    generate
        if (BANKED != 0) begin : g_banked
            wire [2*`RV64_REG_ADDR_WIDTH-1:0] read_addr;
            wire [2*`RV64_XLEN-1:0] read_data;
            wire [1:0] read_req;
            wire [1:0] read_valid;

            wire [`RV64_REG_ADDR_WIDTH-1:0] write_addr;
            wire [`RV64_XLEN-1:0] write_data;
            wire [0:0] write_req;
            wire [0:0] write_valid;

            reg rs1_done_q;
            reg rs2_done_q;
            reg [`RV64_XLEN-1:0] rs1_data_q;
            reg [`RV64_XLEN-1:0] rs2_data_q;
            reg write_done_q;

            wire rs1_zero = (rs1_addr_i == `RV64_REG_X0);
            wire rs2_zero = (rs2_addr_i == `RV64_REG_X0);
            wire rs1_ready = rs1_zero || rs1_done_q || read_valid[0];
            wire rs2_ready = rs2_zero || rs2_done_q || read_valid[1];
            wire write_required = rd_write_i &&
                                  (rd_addr_i != `RV64_REG_X0);

            assign read_addr[0*`RV64_REG_ADDR_WIDTH +:
                             `RV64_REG_ADDR_WIDTH] = rs1_addr_i;
            assign read_addr[1*`RV64_REG_ADDR_WIDTH +:
                             `RV64_REG_ADDR_WIDTH] = rs2_addr_i;
            assign read_req[0] = read_valid_i && !read_flush_i &&
                                 !rs1_zero && !rs1_done_q;
            assign read_req[1] = read_valid_i && !read_flush_i &&
                                 !rs2_zero && !rs2_done_q;

            assign read_ready_o = !read_flush_i &&
                                  rs1_ready && rs2_ready;
            assign rs1_data_o = rs1_zero ? {`RV64_XLEN{1'b0}} :
                                rs1_done_q ? rs1_data_q :
                                read_data[0*`RV64_XLEN +: `RV64_XLEN];
            assign rs2_data_o = rs2_zero ? {`RV64_XLEN{1'b0}} :
                                rs2_done_q ? rs2_data_q :
                                read_data[1*`RV64_XLEN +: `RV64_XLEN];

            assign write_addr = rd_addr_i;
            assign write_data = rd_data_i;
            assign write_req[0] = write_required && !write_done_q;
            assign rd_ready_o = !write_required ||
                                write_done_q || write_valid[0];

            cmn_reg_file #(
                .REG_WIDTH(`RV64_XLEN),
                .REG_COUNT(32),
                .READ_PORTS(2),
                .WRITE_PORTS(1),
                .BANK_SIZE(16),
                .NUM_BANKS(2),
                .FPGA_LUTRAM(FPGA_LUTRAM)
            ) u_reg_file (
                .clk(clk),
                .rst_n(rst_n),
                .rp_addr_i(read_addr),
                .rp_data_o(read_data),
                .rp_req_i(read_req),
                .rp_valid_o(read_valid),
                .wp_addr_i(write_addr),
                .wp_data_i(write_data),
                .wp_req_i(write_req),
                .wp_valid_o(write_valid),
                .quiescent_o()
            );

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rs1_done_q <= 1'b0;
                    rs2_done_q <= 1'b0;
                    rs1_data_q <= {`RV64_XLEN{1'b0}};
                    rs2_data_q <= {`RV64_XLEN{1'b0}};
                end else if (read_flush_i || read_clear_i) begin
                    rs1_done_q <= 1'b0;
                    rs2_done_q <= 1'b0;
                    rs1_data_q <= {`RV64_XLEN{1'b0}};
                    rs2_data_q <= {`RV64_XLEN{1'b0}};
                end else begin
                    if (read_valid[0]) begin
                        rs1_done_q <= 1'b1;
                        rs1_data_q <= read_data[
                            0*`RV64_XLEN +: `RV64_XLEN];
                    end

                    if (read_valid[1]) begin
                        rs2_done_q <= 1'b1;
                        rs2_data_q <= read_data[
                            1*`RV64_XLEN +: `RV64_XLEN];
                    end
                end
            end

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    write_done_q <= 1'b0;
                else if (rd_clear_i)
                    write_done_q <= 1'b0;
                else if (write_valid[0])
                    write_done_q <= 1'b1;
            end

`ifndef SYNTHESIS
            genvar architectural_reg;
            for (architectural_reg = 1; architectural_reg < 32;
                 architectural_reg = architectural_reg + 1) begin : g_reg_alias
                localparam integer REG_BANK = architectural_reg % 2;
                localparam integer REG_ROW = architectural_reg / 2;

                assign regs[architectural_reg] =
                    u_reg_file.g_banks[REG_BANK].bank.read_lines[REG_ROW];
            end
`endif
        end else begin : g_legacy
            openrv64_rv64i_gpr #(
                .FPGA_LUTRAM(FPGA_LUTRAM)
            ) u_legacy (
                .clk(clk),
                .rst_n(rst_n),
                .rs1_addr_i(rs1_addr_i),
                .rs1_data_o(rs1_data_o),
                .rs2_addr_i(rs2_addr_i),
                .rs2_data_o(rs2_data_o),
                .rd_write_i(rd_write_i),
                .rd_addr_i(rd_addr_i),
                .rd_data_i(rd_data_i)
            );

            assign read_ready_o = 1'b1;
            assign rd_ready_o = 1'b1;

`ifndef SYNTHESIS
            genvar legacy_reg;
            for (legacy_reg = 1; legacy_reg < 32;
                 legacy_reg = legacy_reg + 1) begin : g_reg_alias
                assign regs[legacy_reg] = u_legacy.regs[legacy_reg];
            end
`endif
        end
    endgenerate

endmodule
