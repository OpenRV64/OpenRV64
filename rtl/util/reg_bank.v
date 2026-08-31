`timescale 1ns/1ps
`include "util/reg.v"

// Register bank definition

module cmn_reg_bank #(
    parameter integer REG_WIDTH     = 64,
    parameter integer REG_NUM       = 16,
    parameter integer READ_PORTS    = 1,
    parameter integer WRITE_PORTS   = 1,
    parameter integer REG_SEL_WIDTH = $clog2(REG_NUM),
    parameter integer FPGA_LUTRAM   = 0
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
    genvar lutram_read_port;
    genvar reg_id;
    genvar reg_read_port;
    generate
        if (FPGA_LUTRAM != 0) begin : g_lutram
            (* ram_style = "distributed" *)
            reg [REG_WIDTH-1:0] regs_q [0:REG_NUM-1];

            always @(posedge clk) begin
                if (write_req_i[0])
                    regs_q[write_sel_i[0]] <= write_val_i[0];
            end

            for (lutram_read_port = 0;
                 lutram_read_port < READ_PORTS;
                 lutram_read_port = lutram_read_port + 1) begin : g_read
                always @(posedge clk) begin
                    if (read_req_i[lutram_read_port]) begin
                        read_val_o[lutram_read_port] <=
                            regs_q[read_sel_i[lutram_read_port]];
                    end
                end
            end

`ifndef SYNTHESIS
            // Preserve the simulation-only architectural register view.
            // Exposing every word in synthesis would add read ports and
            // prevent distributed-RAM inference.
            genvar lutram_reg_id;
            for (lutram_reg_id = 0;
                 lutram_reg_id < REG_NUM;
                 lutram_reg_id = lutram_reg_id + 1) begin : g_reg_alias
                assign read_lines[lutram_reg_id] = regs_q[lutram_reg_id];
            end
`endif
        end else begin : g_regs
            reg [REG_NUM-1:0] read_select;
            reg [REG_WIDTH-1:0] write_lines [REG_NUM-1:0];
            reg [REG_NUM-1:0] write_select;

            for (reg_id = 0; reg_id < REG_NUM;
                 reg_id = reg_id + 1) begin : g_reg
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

            for (reg_read_port = 0;
                 reg_read_port < READ_PORTS;
                 reg_read_port = reg_read_port + 1) begin : g_read
                wire [REG_SEL_WIDTH-1:0] read_sel;

                assign read_sel = read_sel_i[reg_read_port];

                always @(posedge clk) begin
                    if (read_req_i[reg_read_port]) begin
                        read_val_o[reg_read_port] <= read_lines[read_sel];
                    end
                end
            end

            // Set the register activate lines for read and write.
            integer reg_idx;
            integer sel_read_port;
            integer sel_write_port;
            always @* begin
                read_select = {REG_NUM{1'b0}};
                write_select = {REG_NUM{1'b0}};

                for (reg_idx = 0; reg_idx < REG_NUM;
                     reg_idx = reg_idx + 1) begin
                    write_lines[reg_idx] = {REG_WIDTH{1'b0}};
                end

                for (sel_read_port = 0;
                     sel_read_port < READ_PORTS;
                     sel_read_port = sel_read_port + 1) begin
                    if (read_req_i[sel_read_port]) begin
                        read_select[read_sel_i[sel_read_port]] = 1'b1;
                    end
                end

                for (sel_write_port = 0;
                     sel_write_port < WRITE_PORTS;
                     sel_write_port = sel_write_port + 1) begin
                    if (write_req_i[sel_write_port]) begin
                        write_select[write_sel_i[sel_write_port]] = 1'b1;
                        write_lines[write_sel_i[sel_write_port]] =
                            write_val_i[sel_write_port];
                    end
                end
            end
        end
    endgenerate

`ifndef SYNTHESIS
    initial begin
        if (REG_NUM < 2)
            $fatal(1, "cmn_reg_bank: REG_NUM too small.");
        if ((FPGA_LUTRAM != 0) && (WRITE_PORTS != 1)) begin
            $fatal(1,
                   "cmn_reg_bank: FPGA_LUTRAM requires one write port.");
        end
    end
`endif

endmodule
