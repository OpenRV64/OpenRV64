`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"

// Constant-operation wrappers let synthesis remove the ALU case mux and report
// each datapath independently. The integrated ALU is reported separately.
`define OPENRV64_RV64I_TIMING_WRAPPER(module_name, operation, is_word) \
module module_name ( \
    input  wire [`RV64_XLEN-1:0] src1_i, \
    input  wire [`RV64_XLEN-1:0] src2_i, \
    input  wire [`RV64_XLEN-1:0] pc_i, \
    output wire                  valid_o, \
    output wire                  illegal_o, \
    output wire [`RV64_XLEN-1:0] result_o \
); \
    openrv64_exec_alu_rv64i u_alu ( \
        .op_sel_i(operation), \
        .word_op_i(is_word), \
        .src1_i(src1_i), \
        .src2_i(src2_i), \
        .pc_i(pc_i), \
        .valid_o(valid_o), \
        .illegal_o(illegal_o), \
        .result_o(result_o) \
    ); \
endmodule

`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_add,
                                `RV64_ALU_OP_ADD, 1'b0)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_addw,
                                `RV64_ALU_OP_ADD, 1'b1)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_sub,
                                `RV64_ALU_OP_SUB, 1'b0)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_subw,
                                `RV64_ALU_OP_SUB, 1'b1)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_sll,
                                `RV64_ALU_OP_SLL, 1'b0)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_sllw,
                                `RV64_ALU_OP_SLL, 1'b1)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_slt,
                                `RV64_ALU_OP_SLT, 1'b0)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_sltu,
                                `RV64_ALU_OP_SLTU, 1'b0)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_xor,
                                `RV64_ALU_OP_XOR, 1'b0)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_srl,
                                `RV64_ALU_OP_SRL, 1'b0)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_srlw,
                                `RV64_ALU_OP_SRL, 1'b1)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_sra,
                                `RV64_ALU_OP_SRA, 1'b0)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_sraw,
                                `RV64_ALU_OP_SRA, 1'b1)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_or,
                                `RV64_ALU_OP_OR, 1'b0)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_and,
                                `RV64_ALU_OP_AND, 1'b0)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_lui,
                                `RV64_ALU_OP_LUI, 1'b0)
`OPENRV64_RV64I_TIMING_WRAPPER(openrv64_timing_alu_rv64i_auipc,
                                `RV64_ALU_OP_AUIPC, 1'b0)

`undef OPENRV64_RV64I_TIMING_WRAPPER
