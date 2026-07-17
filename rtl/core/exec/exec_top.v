`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"

module openrv64_exec_top #(
    parameter PIPE_EX_MEM = 1,
    parameter PIPE_MEM_WB = 1
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         valid_i,
    output wire                         clear_o,
    output wire                         alu_ready_o,
    output wire                         lsu_ready_o,
    output wire                         br_ready_o,
    output wire                         system_ready_o,
    input  wire                         flush_ex_mem_i,
    input  wire                         flush_mem_wb_i,
    input  wire [`RV64_XLEN-1:0]        pc_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] instr_i,
    input  wire [`RV64_XLEN-1:0]        rs1_data_i,
    input  wire [`RV64_XLEN-1:0]        rs2_data_i,
    input  wire [`RV64_XLEN-1:0]        imm_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr_i,
    input  wire [`RV64_ALU_OP_WIDTH-1:0] alu_op_i,
    input  wire [`RV64_LSU_OP_WIDTH-1:0] lsu_op_i,
    input  wire [`RV64_BR_OP_WIDTH-1:0] br_op_i,
    input  wire                         reg_write_i,
    input  wire                         mem_read_i,
    input  wire                         mem_write_i,
    input  wire                         branch_i,
    input  wire                         jump_i,
    input  wire                         word_op_i,
    input  wire                         system_i,
    input  wire                         fence_i,
    input  wire                         illegal_i,
    input  wire                         ebreak_i,
    input  wire                         ecall_i,

    output wire                         redirect_valid_o,
    output wire [`RV64_XLEN-1:0]        redirect_target_o,

    output wire                         mem_valid_o,
    input  wire                         mem_ready_i,
    output wire                         mem_write_o,
    output wire [`RV64_XLEN-1:0]        mem_addr_o,
    output wire [`RV64_XLEN-1:0]        mem_wdata_o,
    output wire [7:0]                   mem_wstrb_o,
    input  wire [`RV64_XLEN-1:0]        mem_rdata_i,

    output wire                         wb_valid_o,
    input  wire                         wb_clear_i,
    output wire [`RV64_XLEN-1:0]        wb_pc_o,
    output wire [`RV64_INSTR_WIDTH-1:0] wb_instr_o,
    output wire [`RV64_XLEN-1:0]        wb_data_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] wb_rd_addr_o,
    output wire                         wb_reg_write_o,
    output wire                         wb_illegal_o,
    output wire                         wb_ebreak_o,
    output wire                         wb_ecall_o
);

    localparam EX_MEM_WIDTH = 371;
    localparam MEM_WB_WIDTH = 169;

    wire [`RV64_OPCODE_WIDTH-1:0] opcode = `RV64_OPCODE(instr_i);
    wire alu_uses_imm = (opcode == `RV64_OPCODE_LUI) ||
                        (opcode == `RV64_OPCODE_AUIPC) ||
                        (opcode == `RV64_OPCODE_OP_IMM) ||
                        (opcode == `RV64_OPCODE_OP_IMM_32);
    wire [`RV64_XLEN-1:0] alu_src1 = (opcode == `RV64_OPCODE_LUI) ?
                                     {`RV64_XLEN{1'b0}} :
                                     rs1_data_i;
    wire [`RV64_XLEN-1:0] alu_src2 = alu_uses_imm ? imm_i : rs2_data_i;

    wire alu_valid;
    wire alu_illegal;
    wire [`RV64_XLEN-1:0] alu_result;
    wire br_valid;
    wire br_illegal;
    wire br_taken;
    wire [`RV64_XLEN-1:0] br_target;
    wire br_link;
    wire [`RV64_XLEN-1:0] br_link_data;

    wire ex_alu_selected = valid_i && (alu_op_i != `RV64_ALU_OP_INVALID);
    wire ex_br_selected = valid_i && (branch_i || jump_i);
    wire ex_illegal = illegal_i ||
                      (ex_alu_selected && alu_illegal) ||
                      (ex_br_selected && br_illegal);
    wire [`RV64_XLEN-1:0] ex_wb_data = br_link ? br_link_data : alu_result;

    wire ex_mem_in_valid;
    wire ex_mem_in_clear;
    wire [EX_MEM_WIDTH-1:0] ex_mem_in_data;
    wire ex_mem_out_valid;
    wire ex_mem_out_clear;
    wire [EX_MEM_WIDTH-1:0] ex_mem_out_data;
    wire [`RV64_XLEN-1:0] ex_mem_pc;
    wire [`RV64_INSTR_WIDTH-1:0] ex_mem_instr;
    wire [`RV64_XLEN-1:0] ex_mem_wb_data;
    wire [`RV64_XLEN-1:0] ex_mem_lsu_base;
    wire [`RV64_XLEN-1:0] ex_mem_lsu_offset;
    wire [`RV64_XLEN-1:0] ex_mem_lsu_store_data;
    wire [`RV64_REG_ADDR_WIDTH-1:0] ex_mem_rd_addr;
    wire [`RV64_LSU_OP_WIDTH-1:0] ex_mem_lsu_op;
    wire ex_mem_reg_write;
    wire ex_mem_mem_read;
    wire ex_mem_mem_write;
    wire ex_mem_branch;
    wire ex_mem_jump;
    wire ex_mem_system;
    wire ex_mem_fence;
    wire ex_mem_illegal;
    wire ex_mem_ebreak;
    wire ex_mem_ecall;
    wire unused_ex_mem_control = |{ex_mem_branch, ex_mem_jump, ex_mem_system, ex_mem_fence};

    wire lsu_valid;
    wire lsu_illegal;
    wire lsu_misaligned;
    wire [`RV64_XLEN-1:0] lsu_load_data;
    wire lsu_mem_valid_raw;
    wire lsu_mem_write;
    wire [`RV64_XLEN-1:0] lsu_mem_addr;
    wire [`RV64_XLEN-1:0] lsu_mem_wdata;
    wire [7:0] lsu_mem_wstrb;
    wire lsu_mem_access = ex_mem_out_valid &&
                          (ex_mem_mem_read || ex_mem_mem_write) &&
                          !ex_mem_illegal;
    wire lsu_mem_valid = lsu_mem_access && lsu_valid && lsu_mem_valid_raw;
    wire lsu_complete = !lsu_mem_access ||
                        lsu_misaligned ||
                        (lsu_mem_valid && mem_ready_i);

    wire mem_wb_in_valid;
    wire mem_wb_in_clear;
    wire [MEM_WB_WIDTH-1:0] mem_wb_in_data;
    wire [MEM_WB_WIDTH-1:0] mem_wb_out_data;

    openrv64_exec_alu_rv64i u_alu_exec (
        .op_sel_i(alu_op_i),
        .word_op_i(word_op_i),
        .src1_i(alu_src1),
        .src2_i(alu_src2),
        .pc_i(pc_i),
        .valid_o(alu_valid),
        .illegal_o(alu_illegal),
        .result_o(alu_result)
    );

    openrv64_exec_br u_br_exec (
        .op_sel_i(br_op_i),
        .pc_i(pc_i),
        .src1_i(rs1_data_i),
        .src2_i(rs2_data_i),
        .imm_i(imm_i),
        .valid_o(br_valid),
        .illegal_o(br_illegal),
        .taken_o(br_taken),
        .target_o(br_target),
        .link_o(br_link),
        .link_data_o(br_link_data)
    );

    assign redirect_valid_o = valid_i &&
                              ex_mem_in_clear &&
                              !illegal_i &&
                              (branch_i || jump_i) &&
                              br_valid &&
                              br_taken;
    assign redirect_target_o = br_target;

    assign clear_o = ex_mem_in_clear;
    assign alu_ready_o = ex_mem_in_clear;
    assign lsu_ready_o = ex_mem_in_clear;
    assign br_ready_o = ex_mem_in_clear;
    assign system_ready_o = ex_mem_in_clear;
    assign ex_mem_in_valid = valid_i;
    assign ex_mem_in_data = {
        pc_i,
        instr_i,
        ex_wb_data,
        rs1_data_i,
        imm_i,
        rs2_data_i,
        rd_addr_i,
        lsu_op_i,
        reg_write_i,
        mem_read_i,
        mem_write_i,
        branch_i,
        jump_i,
        system_i,
        fence_i,
        ex_illegal,
        ebreak_i,
        ecall_i
    };

    openrv64_stage #(
        .WIDTH(EX_MEM_WIDTH),
        .REGISTERED(PIPE_EX_MEM)
    ) u_ex_mem (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_ex_mem_i),
        .in_valid_i(ex_mem_in_valid),
        .in_clear_o(ex_mem_in_clear),
        .in_data_i(ex_mem_in_data),
        .out_valid_o(ex_mem_out_valid),
        .out_clear_i(ex_mem_out_clear),
        .out_data_o(ex_mem_out_data)
    );

    assign {
        ex_mem_pc,
        ex_mem_instr,
        ex_mem_wb_data,
        ex_mem_lsu_base,
        ex_mem_lsu_offset,
        ex_mem_lsu_store_data,
        ex_mem_rd_addr,
        ex_mem_lsu_op,
        ex_mem_reg_write,
        ex_mem_mem_read,
        ex_mem_mem_write,
        ex_mem_branch,
        ex_mem_jump,
        ex_mem_system,
        ex_mem_fence,
        ex_mem_illegal,
        ex_mem_ebreak,
        ex_mem_ecall
    } = ex_mem_out_data;

    openrv64_exec_lsu_rv64i u_lsu_exec (
        .op_sel_i(ex_mem_lsu_op),
        .base_i(ex_mem_lsu_base),
        .offset_i(ex_mem_lsu_offset),
        .store_data_i(ex_mem_lsu_store_data),
        .mem_rdata_i(mem_rdata_i),
        .valid_o(lsu_valid),
        .illegal_o(lsu_illegal),
        .misaligned_o(lsu_misaligned),
        .load_data_o(lsu_load_data),
        .mem_valid_o(lsu_mem_valid_raw),
        .mem_write_o(lsu_mem_write),
        .mem_addr_o(lsu_mem_addr),
        .mem_wdata_o(lsu_mem_wdata),
        .mem_wstrb_o(lsu_mem_wstrb)
    );

    assign mem_valid_o = lsu_mem_valid;
    assign mem_write_o = lsu_mem_write;
    assign mem_addr_o = lsu_mem_addr;
    assign mem_wdata_o = lsu_mem_wdata;
    assign mem_wstrb_o = lsu_mem_wstrb;

    assign ex_mem_out_clear = mem_wb_in_clear && lsu_complete;
    assign mem_wb_in_valid = ex_mem_out_valid && lsu_complete;
    assign mem_wb_in_data = {
        ex_mem_pc,
        ex_mem_instr,
        ex_mem_mem_read ? lsu_load_data : ex_mem_wb_data,
        ex_mem_rd_addr,
        ex_mem_reg_write && !ex_mem_mem_write,
        ex_mem_illegal || (lsu_mem_access && (lsu_illegal || lsu_misaligned)),
        ex_mem_ebreak,
        ex_mem_ecall
    };

    openrv64_stage #(
        .WIDTH(MEM_WB_WIDTH),
        .REGISTERED(PIPE_MEM_WB)
    ) u_mem_wb (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_mem_wb_i),
        .in_valid_i(mem_wb_in_valid),
        .in_clear_o(mem_wb_in_clear),
        .in_data_i(mem_wb_in_data),
        .out_valid_o(wb_valid_o),
        .out_clear_i(wb_clear_i),
        .out_data_o(mem_wb_out_data)
    );

    assign {
        wb_pc_o,
        wb_instr_o,
        wb_data_o,
        wb_rd_addr_o,
        wb_reg_write_o,
        wb_illegal_o,
        wb_ebreak_o,
        wb_ecall_o
    } = mem_wb_out_data;

endmodule
