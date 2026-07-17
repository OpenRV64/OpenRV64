`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/except/except-defs.v"

module openrv64_except (
    input  wire                         illegal_instr_i,
    input  wire                         instr_misaligned_i,
    input  wire                         instr_access_fault_i,
    input  wire                         instr_page_fault_i,
    input  wire                         load_misaligned_i,
    input  wire                         load_access_fault_i,
    input  wire                         load_page_fault_i,
    input  wire                         store_misaligned_i,
    input  wire                         store_access_fault_i,
    input  wire                         store_page_fault_i,
    input  wire                         ecall_i,
    input  wire                         ebreak_i,
    input  wire [`RV64_PRIV_WIDTH-1:0] priv_mode_i,
    input  wire [`RV64_XLEN-1:0]        pc_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] instr_i,
    input  wire [`RV64_XLEN-1:0]        badaddr_i,

    output reg                          exception_o,
    output reg                          halt_o,
    output reg [`RV64_EXCEPT_CAUSE_WIDTH-1:0] cause_o,
    output reg [`RV64_XLEN-1:0]         tval_o
);

    always @* begin
        exception_o = 1'b0;
        halt_o      = 1'b0;
        cause_o     = `RV64_EXCEPT_CAUSE_INSTR_ADDR_MISALIGNED;
        tval_o      = {`RV64_XLEN{1'b0}};

        if (instr_misaligned_i) begin
            exception_o = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_INSTR_ADDR_MISALIGNED;
            tval_o      = pc_i;
        end else if (instr_access_fault_i) begin
            exception_o = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_INSTR_ACCESS_FAULT;
            tval_o      = pc_i;
        end else if (instr_page_fault_i) begin
            exception_o = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_INSTR_PAGE_FAULT;
            tval_o      = pc_i;
        end else if (illegal_instr_i) begin
            exception_o = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_ILLEGAL_INSTR;
            tval_o      = {{32{1'b0}}, instr_i};
        end else if (load_misaligned_i) begin
            exception_o = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_LOAD_ADDR_MISALIGNED;
            tval_o      = badaddr_i;
        end else if (load_access_fault_i) begin
            exception_o = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_LOAD_ACCESS_FAULT;
            tval_o      = badaddr_i;
        end else if (load_page_fault_i) begin
            exception_o = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_LOAD_PAGE_FAULT;
            tval_o      = badaddr_i;
        end else if (store_misaligned_i) begin
            exception_o = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_STORE_ADDR_MISALIGNED;
            tval_o      = badaddr_i;
        end else if (store_access_fault_i) begin
            exception_o = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_STORE_ACCESS_FAULT;
            tval_o      = badaddr_i;
        end else if (store_page_fault_i) begin
            exception_o = 1'b1;
            cause_o     = `RV64_EXCEPT_CAUSE_STORE_PAGE_FAULT;
            tval_o      = badaddr_i;
        end else if (ecall_i) begin
            exception_o = 1'b1;
            case (priv_mode_i)
                `RV64_PRIV_U: cause_o = `RV64_EXCEPT_CAUSE_ECALL_U;
                `RV64_PRIV_S: cause_o = `RV64_EXCEPT_CAUSE_ECALL_S;
                default:      cause_o = `RV64_EXCEPT_CAUSE_ECALL_M;
            endcase
        end else if (ebreak_i) begin
            exception_o = 1'b1;
            halt_o      = (priv_mode_i == `RV64_PRIV_M);
            cause_o     = `RV64_EXCEPT_CAUSE_BREAKPOINT;
        end
    end

endmodule
