`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-zicsr.v"

module openrv64_exec_system_csr (
    input  wire                         valid_i,
    input  wire [`RV64_FUNCT3_WIDTH-1:0] funct3_i,
    input  wire [`RV64_FUNCT12_WIDTH-1:0] csr_addr_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr_i,
    input  wire [`RV64_XLEN-1:0]        rs1_data_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] zimm_i,
    input  wire [`RV64_XLEN-1:0]        csr_rdata_i,
    input  wire                         csr_valid_i,
    input  wire                         csr_writable_i,

    output wire                         ready_o,
    output wire                         illegal_o,
    output wire                         csr_write_o,
    output wire [`RV64_FUNCT12_WIDTH-1:0] csr_addr_o,
    output wire [`RV64_XLEN-1:0]        csr_wdata_o,
    output wire [`RV64_XLEN-1:0]        rd_data_o
);

    assign ready_o     = 1'b1;
    assign csr_addr_o  = valid_i ? csr_addr_i : {`RV64_FUNCT12_WIDTH{1'b0}};

    reg op_valid;
    reg write_required;
    reg [`RV64_XLEN-1:0] write_value;

    always @* begin
        op_valid      = 1'b1;
        write_required = 1'b0;
        write_value   = csr_rdata_i;

        case (funct3_i)
            `RV64_ZICSR_FUNCT3_CSRRW: begin
                write_required = 1'b1;
                write_value    = rs1_data_i;
            end

            `RV64_ZICSR_FUNCT3_CSRRS: begin
                write_required = (rs1_addr_i != `RV64_REG_X0);
                write_value    = csr_rdata_i | rs1_data_i;
            end

            `RV64_ZICSR_FUNCT3_CSRRC: begin
                write_required = (rs1_addr_i != `RV64_REG_X0);
                write_value    = csr_rdata_i & ~rs1_data_i;
            end

            `RV64_ZICSR_FUNCT3_CSRRWI: begin
                write_required = 1'b1;
                write_value    = {{(`RV64_XLEN-`RV64_REG_ADDR_WIDTH){1'b0}}, zimm_i};
            end

            `RV64_ZICSR_FUNCT3_CSRRSI: begin
                write_required = (zimm_i != `RV64_REG_X0);
                write_value    = csr_rdata_i |
                                 {{(`RV64_XLEN-`RV64_REG_ADDR_WIDTH){1'b0}}, zimm_i};
            end

            `RV64_ZICSR_FUNCT3_CSRRCI: begin
                write_required = (zimm_i != `RV64_REG_X0);
                write_value    = csr_rdata_i &
                                 ~{{(`RV64_XLEN-`RV64_REG_ADDR_WIDTH){1'b0}}, zimm_i};
            end

            default: begin
                op_valid       = 1'b0;
                write_required = 1'b0;
                write_value    = {`RV64_XLEN{1'b0}};
            end
        endcase
    end

    assign illegal_o = valid_i &&
                       (!op_valid ||
                        !csr_valid_i ||
                        (write_required && !csr_writable_i));
    assign csr_write_o = valid_i &&
                         op_valid &&
                         csr_valid_i &&
                         csr_writable_i &&
                         write_required;
    assign csr_wdata_o = csr_write_o ? write_value : {`RV64_XLEN{1'b0}};
    assign rd_data_o = (valid_i && op_valid && csr_valid_i) ?
                       csr_rdata_i : {`RV64_XLEN{1'b0}};

endmodule
