`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

// Six combinational read selectors and three ordered retirement write ports.
// Duplicate destinations are optional; when enabled, ascending nonblocking
// assignments and youngest-first bypass priority make the youngest retirement
// lane the final architectural value.
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

    reg [`RV64_XLEN-1:0] regs [1:31];

    wire [`RV64_REG_ADDR_WIDTH-1:0] write_addr0 =
        write_addr_i[0*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH];
    wire [`RV64_REG_ADDR_WIDTH-1:0] write_addr1 =
        write_addr_i[1*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH];
    wire [`RV64_REG_ADDR_WIDTH-1:0] write_addr2 =
        write_addr_i[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH];
    wire write0 = write_valid_i[0] && (write_addr0 != `RV64_REG_X0);
    wire write1 = write_valid_i[1] && (write_addr1 != `RV64_REG_X0);
    wire write2 = write_valid_i[2] && (write_addr2 != `RV64_REG_X0);

    genvar read_idx;
    generate
        for (read_idx = 0; read_idx < 6; read_idx = read_idx + 1) begin : g_read
            wire [`RV64_REG_ADDR_WIDTH-1:0] read_addr =
                read_addr_i[read_idx*`RV64_REG_ADDR_WIDTH +:
                            `RV64_REG_ADDR_WIDTH];
            wire bypass0 = READ_WRITE_BYPASS && write0 &&
                           (read_addr == write_addr0);
            wire bypass1 = READ_WRITE_BYPASS && write1 &&
                           (read_addr == write_addr1);
            wire bypass2 = READ_WRITE_BYPASS && write2 &&
                           (read_addr == write_addr2);

            assign read_data_o[read_idx*`RV64_XLEN +: `RV64_XLEN] =
                (read_addr == `RV64_REG_X0) ? {`RV64_XLEN{1'b0}} :
                bypass2 ? write_data_i[2*`RV64_XLEN +: `RV64_XLEN] :
                bypass1 ? write_data_i[1*`RV64_XLEN +: `RV64_XLEN] :
                bypass0 ? write_data_i[0*`RV64_XLEN +: `RV64_XLEN] :
                regs[read_addr];
        end
    endgenerate

    integer reg_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if (RESET_REGS) begin
                for (reg_idx = 1; reg_idx < 32; reg_idx = reg_idx + 1) begin
                    regs[reg_idx] <= {`RV64_XLEN{1'b0}};
                end
            end
        end else begin
            if (write0) begin
                regs[write_addr0] <=
                    write_data_i[0*`RV64_XLEN +: `RV64_XLEN];
            end
            if (write1) begin
                regs[write_addr1] <=
                    write_data_i[1*`RV64_XLEN +: `RV64_XLEN];
            end
            if (write2) begin
                regs[write_addr2] <=
                    write_data_i[2*`RV64_XLEN +: `RV64_XLEN];
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n) begin
            if ((ALLOW_DUPLICATE_WRITES == 0) &&
                ((write0 && write1 && (write_addr0 == write_addr1)) ||
                (write0 && write2 && (write_addr0 == write_addr2)) ||
                 (write1 && write2 && (write_addr1 == write_addr2)))) begin
                $fatal(1, "3p retirement attempted duplicate GPR writes");
            end
        end
    end
`endif

endmodule
