`timescale 1ns/1ps
`include "util/reg.v"

// Register bank definition

module cmn_reg_bank #(
    parameter integer REG_WIDTH     = 64,
    parameter integer REG_NUM       = 16,
    parameter integer READ_PORTS    = 1,
    parameter integer WRITE_PORTS   = 1,
    parameter integer REG_SEL_WIDTH = $clog2(REG_NUM)
) (
    input  wire                         clk,

    output reg  [READ_PORTS-1:0][REG_WIDTH-1:0]     read_val_o,
    input  wire [READ_PORTS-1:0][REG_SEL_WIDTH-1:0] read_sel_i,
    input  wire [READ_PORTS-1:0]                    read_req_i,

    input  wire [WRITE_PORTS-1:0][REG_WIDTH-1:0]     write_val_i,
    input  wire [WRITE_PORTS-1:0][REG_SEL_WIDTH-1:0] write_sel_i,
    input  wire [WRITE_PORTS-1:0]                    write_req_i
);

    wire [REG_WIDTH-1:0] read_lines [REG_NUM-1:0];
    reg  [REG_NUM-1:0]   read_select;

    reg [REG_WIDTH-1:0] write_lines [REG_NUM-1:0];
    reg [REG_NUM-1:0]   write_select;

    genvar reg_id;
    genvar read_port;
    generate
        for (reg_id = 0; reg_id < REG_NUM; reg_id = reg_id + 1) begin
            cmn_reg #(
                .REG_WIDTH(REG_WIDTH)
            ) regs (
                .clk(clk),
                .write_val_i(write_lines[reg_id]),
                .write_en_i(write_select[reg_id]),
                .read_val_o(read_lines[reg_id]),
                .read_en_i(read_select[reg_id])
            );
        end

        for (read_port = 0; read_port < READ_PORTS; read_port = read_port + 1) begin
            wire [REG_SEL_WIDTH-1:0] read_sel;

            assign read_sel = read_sel_i[read_port];

            always @(posedge clk) begin
                if (read_req_i[read_port]) begin
                    read_val_o[read_port] <= read_lines[read_sel];
                end
            end
        end
    endgenerate

    initial begin
        if (REG_NUM < 2)
            $fatal(1, "cmn_reg_bank: REG_NUM too small.");
    end

    // Set the register activate lines for read and write
    integer reg_idx;
    integer sel_read_port;
    integer sel_write_port;
    always @* begin
        read_select = {REG_NUM{1'b0}};
        write_select = {REG_NUM{1'b0}};

        for (reg_idx = 0; reg_idx < REG_NUM; reg_idx = reg_idx + 1)
            write_lines[reg_idx] = {REG_WIDTH{1'b0}};

        for (sel_read_port = 0; sel_read_port < READ_PORTS; sel_read_port = sel_read_port + 1) begin
            if (read_req_i[sel_read_port])
                read_select[read_sel_i[sel_read_port]] = 1'b1;
        end

        for (sel_write_port = 0; sel_write_port < WRITE_PORTS; sel_write_port = sel_write_port + 1) begin
            if (write_req_i[sel_write_port]) begin
                write_select[write_sel_i[sel_write_port]] = 1'b1;
                write_lines[write_sel_i[sel_write_port]] = write_val_i[sel_write_port];
            end
        end
    end

endmodule
