`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/fetch/fetch-defs.v"
`include "core/decode/defs/early-defs.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"

module openrv64_rv64_top #(
    parameter [63:0] RESET_VECTOR = 64'h0000_0000_0000_0000,
    parameter PIPE_IF_ID = 1,
    parameter PIPE_ID_EX = 1,
    parameter PIPE_EX_MEM = 1,
    parameter PIPE_MEM_WB = 1,
    parameter ENABLE_RV64M = 0
) (
    input  wire        clk,
    input  wire        rst_n,

    output wire        mem_valid,
    input  wire        mem_ready,
    output wire        mem_write,
    output wire [63:0] mem_addr,
    output wire [63:0] mem_wdata,
    output wire [7:0]  mem_wstrb,
    input  wire [63:0] mem_rdata,

    output wire [63:0] dbg_pc,
    output wire [31:0] dbg_instr,
    output wire        dbg_halted
);

    localparam IF_ID_WIDTH = `RV64_FETCH_DECODE_BUS_WIDTH;

    reg [`RV64_XLEN-1:0] pc_q;
    reg [`RV64_XLEN-1:0] dbg_pc_q;
    reg [`RV64_INSTR_WIDTH-1:0] dbg_instr_q;
    reg halted_q;
    reg halt_pending_q;

    wire fetch_pc_ready;
    wire fetch_pc_valid;
    wire fetch_mem_valid;
    wire fetch_mem_ready;
    wire fetch_mem_write;
    wire [`RV64_XLEN-1:0] fetch_mem_addr;
    wire [`RV64_XLEN-1:0] fetch_mem_wdata;
    wire [7:0] fetch_mem_wstrb;
    wire fetch_decode_valid;
    wire fetch_decode_clear;
    wire [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] fetch_decode_bus;
    wire [`RV64_XLEN-1:0] unused_fetch_decode_pc;
    wire [`RV64_INSTR_WIDTH-1:0] unused_fetch_decode_instr;

    wire if_id_in_clear;
    wire if_id_out_valid;
    wire if_id_out_clear;
    wire [IF_ID_WIDTH-1:0] if_id_out_data;
    wire [`RV64_XLEN-1:0] if_id_pc;
    wire [`RV64_INSTR_WIDTH-1:0] if_id_instr;

    wire decode_valid;
    wire decode_illegal;
    wire [`RV64_EARLY_CLASS_WIDTH-1:0] decode_class_sel;
    wire [`RV64_EARLY_FORMAT_WIDTH-1:0] decode_format_sel;
    wire decode_uses_rs1;
    wire decode_uses_rs2;
    wire decode_uses_rd;
    wire [`RV64_REG_ADDR_WIDTH-1:0] decode_rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] decode_rs2_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] decode_rd_addr;
    wire decode_reg_write;
    wire decode_has_imm;
    wire [`RV64_XLEN-1:0] decode_imm;
    wire decode_mem_read;
    wire decode_mem_write;
    wire decode_branch;
    wire decode_jump;
    wire decode_word_op;
    wire decode_system;
    wire decode_fence;
    wire [`RV64_ALU_OP_WIDTH-1:0] decode_alu_op;
    wire [`RV64_LSU_OP_WIDTH-1:0] decode_lsu_op;
    wire [`RV64_BR_OP_WIDTH-1:0] decode_br_op;
    wire unused_decode_imm_valid;
    wire [`RV64_OPCODE_WIDTH-1:0] unused_decode_opcode;
    wire [`RV64_FUNCT3_WIDTH-1:0] unused_decode_funct3;
    wire [`RV64_FUNCT7_WIDTH-1:0] unused_decode_funct7;
    wire [`RV64_FUNCT12_WIDTH-1:0] unused_decode_funct12;
    wire [`RV64_ALU_EXT_WIDTH-1:0] decode_alu_ext;
    wire [`RV64_LSU_SIZE_WIDTH-1:0] unused_decode_lsu_size;
    wire unused_decode_lsu_unsigned;
    wire unused_decode_br_link;
    wire unused_decode_br_indirect;
    wire unused_decode_subdecode_needed;
    wire unused_decode_extension_possible;
    wire unused_decode_summary = |{
        decode_class_sel,
        decode_format_sel,
        decode_uses_rs1,
        decode_uses_rs2,
        decode_uses_rd,
        decode_has_imm,
        unused_decode_imm_valid,
        unused_decode_opcode,
        unused_decode_funct3,
        unused_decode_funct7,
        unused_decode_funct12,
        unused_decode_lsu_size,
        unused_decode_lsu_unsigned,
        unused_decode_br_link,
        unused_decode_br_indirect,
        unused_decode_subdecode_needed,
        unused_decode_extension_possible
    };

    wire [`RV64_XLEN-1:0] gpr_rs1_data;
    wire [`RV64_XLEN-1:0] gpr_rs2_data;
    wire wb_write;
    wire [`RV64_REG_ADDR_WIDTH-1:0] wb_rd_addr;
    wire [`RV64_XLEN-1:0] wb_rd_data;

    wire dispatch_decode_clear;
    wire dispatch_exec_valid;
    wire [`RV64_XLEN-1:0] dispatch_exec_pc;
    wire [`RV64_INSTR_WIDTH-1:0] dispatch_exec_instr;
    wire [`RV64_XLEN-1:0] dispatch_exec_rs1_data;
    wire [`RV64_XLEN-1:0] dispatch_exec_rs2_data;
    wire [`RV64_XLEN-1:0] dispatch_exec_imm;
    wire [`RV64_REG_ADDR_WIDTH-1:0] dispatch_exec_rd_addr;
    wire [`RV64_ALU_EXT_WIDTH-1:0] dispatch_exec_alu_ext;
    wire [`RV64_ALU_OP_WIDTH-1:0] dispatch_exec_alu_op;
    wire [`RV64_LSU_OP_WIDTH-1:0] dispatch_exec_lsu_op;
    wire [`RV64_BR_OP_WIDTH-1:0] dispatch_exec_br_op;
    wire dispatch_exec_reg_write;
    wire dispatch_exec_mem_read;
    wire dispatch_exec_mem_write;
    wire dispatch_exec_branch;
    wire dispatch_exec_jump;
    wire dispatch_exec_word_op;
    wire dispatch_exec_system;
    wire dispatch_exec_fence;
    wire dispatch_exec_illegal;
    wire dispatch_exec_ebreak;
    wire dispatch_exec_ecall;
    wire dispatch_raw_hazard;
    wire dispatch_waw_hazard;
    wire dispatch_scoreboard_stall;
    wire unused_dispatch_hazards = |{
        dispatch_raw_hazard,
        dispatch_waw_hazard,
        dispatch_scoreboard_stall
    };


    wire exec_clear;
    wire exec_alu_ready;
    wire exec_lsu_ready;
    wire exec_br_ready;
    wire exec_system_ready;
    wire exec_redirect_valid;
    wire [`RV64_XLEN-1:0] exec_redirect_target;
    wire exec_mem_valid;
    wire exec_mem_ready;
    wire exec_mem_write;
    wire [`RV64_XLEN-1:0] exec_mem_addr;
    wire [`RV64_XLEN-1:0] exec_mem_wdata;
    wire [7:0] exec_mem_wstrb;
    wire exec_wb_valid;
    wire exec_wb_clear;
    wire [`RV64_XLEN-1:0] exec_wb_pc;
    wire [`RV64_INSTR_WIDTH-1:0] exec_wb_instr;
    wire [`RV64_XLEN-1:0] exec_wb_data;
    wire [`RV64_REG_ADDR_WIDTH-1:0] exec_wb_rd_addr;
    wire exec_wb_reg_write;
    wire exec_wb_illegal;
    wire exec_wb_ebreak;
    wire exec_wb_ecall;
    wire unused_exec_wb_ecall = exec_wb_ecall;

    wire hard_flush_redirect_req;
    wire hard_flush_trap_req;
    wire hard_flush_irq_req;
    wire hard_flush_req;
    wire flush_fetch;
    wire flush_if_id;
    wire flush_id_ex;
    wire flush_ex_mem;
    wire flush_mem_wb;
    wire drain_fetch_req;

    wire decode_ebreak = (if_id_instr == `RV64_INSTR_EBREAK);
    wire decode_ecall = (if_id_instr == `RV64_INSTR_ECALL);
    wire decode_ebreak_accept = if_id_out_valid &&
                                if_id_out_clear &&
                                decode_ebreak &&
                                !hard_flush_req;

    assign hard_flush_redirect_req = exec_redirect_valid;
    assign hard_flush_trap_req = 1'b0;
    assign hard_flush_irq_req = 1'b0;
    assign hard_flush_req = hard_flush_redirect_req ||
                            hard_flush_trap_req ||
                            hard_flush_irq_req;

    // Redirect kills only younger work. Trap/IRQ policy will widen these lines
    // once the exception controller can provide precise flush targets.
    assign flush_if_id = hard_flush_req;
    assign flush_id_ex = hard_flush_trap_req || hard_flush_irq_req;
    assign flush_ex_mem = 1'b0;
    assign flush_mem_wb = 1'b0;
    assign drain_fetch_req = decode_ebreak_accept || halted_q;
    assign flush_fetch = hard_flush_req || drain_fetch_req;

    assign fetch_pc_valid = fetch_pc_ready &&
                            !halted_q &&
                            !halt_pending_q &&
                            !decode_ebreak_accept &&
                            !hard_flush_req;
    assign fetch_decode_clear = if_id_in_clear;

    openrv64_fetch u_fetch (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_fetch),
        .pc_ready_o(fetch_pc_ready),
        .pc_valid_i(fetch_pc_valid),
        .pc_i(pc_q),
        .mem_valid_o(fetch_mem_valid),
        .mem_ready_i(fetch_mem_ready),
        .mem_write_o(fetch_mem_write),
        .mem_addr_o(fetch_mem_addr),
        .mem_wdata_o(fetch_mem_wdata),
        .mem_wstrb_o(fetch_mem_wstrb),
        .mem_rdata_i(mem_rdata),
        .decode_valid_o(fetch_decode_valid),
        .decode_ready_i(fetch_decode_clear),
        .decode_bus_o(fetch_decode_bus),
        .decode_pc_o(unused_fetch_decode_pc),
        .decode_instr_o(unused_fetch_decode_instr)
    );

    assign if_id_out_clear = dispatch_decode_clear;

    openrv64_stage #(
        .WIDTH(IF_ID_WIDTH),
        .REGISTERED(PIPE_IF_ID)
    ) u_if_id (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_if_id),
        .in_valid_i(fetch_decode_valid),
        .in_clear_o(if_id_in_clear),
        .in_data_i(fetch_decode_bus),
        .out_valid_o(if_id_out_valid),
        .out_clear_i(if_id_out_clear),
        .out_data_o(if_id_out_data)
    );

    assign {if_id_pc, if_id_instr} = if_id_out_data;

    openrv64_decode_top #(
        .ENABLE_RV64M(ENABLE_RV64M)
    ) u_decode (
        .instr_i(if_id_instr),
        .valid_o(decode_valid),
        .illegal_o(decode_illegal),
        .opcode_o(unused_decode_opcode),
        .funct3_o(unused_decode_funct3),
        .funct7_o(unused_decode_funct7),
        .funct12_o(unused_decode_funct12),
        .class_sel_o(decode_class_sel),
        .format_sel_o(decode_format_sel),
        .uses_rs1_o(decode_uses_rs1),
        .uses_rs2_o(decode_uses_rs2),
        .uses_rd_o(decode_uses_rd),
        .rs1_addr_o(decode_rs1_addr),
        .rs2_addr_o(decode_rs2_addr),
        .rd_addr_o(decode_rd_addr),
        .reg_write_o(decode_reg_write),
        .imm_valid_o(unused_decode_imm_valid),
        .has_imm_o(decode_has_imm),
        .imm_o(decode_imm),
        .mem_read_o(decode_mem_read),
        .mem_write_o(decode_mem_write),
        .branch_o(decode_branch),
        .jump_o(decode_jump),
        .word_op_o(decode_word_op),
        .system_o(decode_system),
        .fence_o(decode_fence),
        .alu_ext_sel_o(decode_alu_ext),
        .alu_op_sel_o(decode_alu_op),
        .lsu_op_sel_o(decode_lsu_op),
        .lsu_size_sel_o(unused_decode_lsu_size),
        .lsu_unsigned_o(unused_decode_lsu_unsigned),
        .br_op_sel_o(decode_br_op),
        .br_link_o(unused_decode_br_link),
        .br_indirect_o(unused_decode_br_indirect),
        .subdecode_needed_o(unused_decode_subdecode_needed),
        .extension_decode_possible_o(unused_decode_extension_possible)
    );

    openrv64_rv64i_gpr u_gpr (
        .clk(clk),
        .rst_n(rst_n),
        .rs1_addr_i(decode_rs1_addr),
        .rs1_data_o(gpr_rs1_data),
        .rs2_addr_i(decode_rs2_addr),
        .rs2_data_o(gpr_rs2_data),
        .rd_write_i(wb_write),
        .rd_addr_i(wb_rd_addr),
        .rd_data_i(wb_rd_data)
    );

    openrv64_dispatch #(
        .REGISTERED(PIPE_ID_EX)
    ) u_dispatch (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_id_ex),
        .decode_valid_i(if_id_out_valid),
        .decode_clear_o(dispatch_decode_clear),
        .decode_pc_i(if_id_pc),
        .decode_instr_i(if_id_instr),
        .decode_rs1_data_i(gpr_rs1_data),
        .decode_rs2_data_i(gpr_rs2_data),
        .decode_imm_i(decode_imm),
        .decode_uses_rs1_i(decode_uses_rs1),
        .decode_uses_rs2_i(decode_uses_rs2),
        .decode_rs1_addr_i(decode_rs1_addr),
        .decode_rs2_addr_i(decode_rs2_addr),
        .decode_rd_addr_i(decode_rd_addr),
        .decode_alu_ext_i(decode_alu_ext),
        .decode_alu_op_i(decode_alu_op),
        .decode_lsu_op_i(decode_lsu_op),
        .decode_br_op_i(decode_br_op),
        .decode_reg_write_i(decode_reg_write),
        .decode_mem_read_i(decode_mem_read),
        .decode_mem_write_i(decode_mem_write),
        .decode_branch_i(decode_branch),
        .decode_jump_i(decode_jump),
        .decode_word_op_i(decode_word_op),
        .decode_system_i(decode_system),
        .decode_fence_i(decode_fence),
        .decode_illegal_i(decode_illegal || !decode_valid),
        .decode_ebreak_i(decode_ebreak),
        .decode_ecall_i(decode_ecall),
        .exec_valid_o(dispatch_exec_valid),
        .exec_clear_i(exec_clear),
        .exec_alu_ready_i(exec_alu_ready),
        .exec_lsu_ready_i(exec_lsu_ready),
        .exec_br_ready_i(exec_br_ready),
        .exec_system_ready_i(exec_system_ready),
        .exec_pc_o(dispatch_exec_pc),
        .exec_instr_o(dispatch_exec_instr),
        .exec_rs1_data_o(dispatch_exec_rs1_data),
        .exec_rs2_data_o(dispatch_exec_rs2_data),
        .exec_imm_o(dispatch_exec_imm),
        .exec_rd_addr_o(dispatch_exec_rd_addr),
        .exec_alu_ext_o(dispatch_exec_alu_ext),
        .exec_alu_op_o(dispatch_exec_alu_op),
        .exec_lsu_op_o(dispatch_exec_lsu_op),
        .exec_br_op_o(dispatch_exec_br_op),
        .exec_reg_write_o(dispatch_exec_reg_write),
        .exec_mem_read_o(dispatch_exec_mem_read),
        .exec_mem_write_o(dispatch_exec_mem_write),
        .exec_branch_o(dispatch_exec_branch),
        .exec_jump_o(dispatch_exec_jump),
        .exec_word_op_o(dispatch_exec_word_op),
        .exec_system_o(dispatch_exec_system),
        .exec_fence_o(dispatch_exec_fence),
        .exec_illegal_o(dispatch_exec_illegal),
        .exec_ebreak_o(dispatch_exec_ebreak),
        .exec_ecall_o(dispatch_exec_ecall),
        .wb_valid_i(exec_wb_valid),
        .wb_reg_write_i(exec_wb_reg_write),
        .wb_rd_addr_i(exec_wb_rd_addr),
        .raw_hazard_o(dispatch_raw_hazard),
        .waw_hazard_o(dispatch_waw_hazard),
        .scoreboard_stall_o(dispatch_scoreboard_stall)
    );

    openrv64_exec_top #(
        .PIPE_EX_MEM(PIPE_EX_MEM),
        .PIPE_MEM_WB(PIPE_MEM_WB),
        .ENABLE_RV64M(ENABLE_RV64M)
    ) u_exec (
        .clk(clk),
        .rst_n(rst_n),
        .valid_i(dispatch_exec_valid),
        .clear_o(exec_clear),
        .alu_ready_o(exec_alu_ready),
        .lsu_ready_o(exec_lsu_ready),
        .br_ready_o(exec_br_ready),
        .system_ready_o(exec_system_ready),
        .flush_ex_mem_i(flush_ex_mem),
        .flush_mem_wb_i(flush_mem_wb),
        .pc_i(dispatch_exec_pc),
        .instr_i(dispatch_exec_instr),
        .rs1_data_i(dispatch_exec_rs1_data),
        .rs2_data_i(dispatch_exec_rs2_data),
        .imm_i(dispatch_exec_imm),
        .rd_addr_i(dispatch_exec_rd_addr),
        .alu_ext_i(dispatch_exec_alu_ext),
        .alu_op_i(dispatch_exec_alu_op),
        .lsu_op_i(dispatch_exec_lsu_op),
        .br_op_i(dispatch_exec_br_op),
        .reg_write_i(dispatch_exec_reg_write),
        .mem_read_i(dispatch_exec_mem_read),
        .mem_write_i(dispatch_exec_mem_write),
        .branch_i(dispatch_exec_branch),
        .jump_i(dispatch_exec_jump),
        .word_op_i(dispatch_exec_word_op),
        .system_i(dispatch_exec_system),
        .fence_i(dispatch_exec_fence),
        .illegal_i(dispatch_exec_illegal),
        .ebreak_i(dispatch_exec_ebreak),
        .ecall_i(dispatch_exec_ecall),
        .redirect_valid_o(exec_redirect_valid),
        .redirect_target_o(exec_redirect_target),
        .mem_valid_o(exec_mem_valid),
        .mem_ready_i(exec_mem_ready),
        .mem_write_o(exec_mem_write),
        .mem_addr_o(exec_mem_addr),
        .mem_wdata_o(exec_mem_wdata),
        .mem_wstrb_o(exec_mem_wstrb),
        .mem_rdata_i(mem_rdata),
        .wb_valid_o(exec_wb_valid),
        .wb_clear_i(exec_wb_clear),
        .wb_pc_o(exec_wb_pc),
        .wb_instr_o(exec_wb_instr),
        .wb_data_o(exec_wb_data),
        .wb_rd_addr_o(exec_wb_rd_addr),
        .wb_reg_write_o(exec_wb_reg_write),
        .wb_illegal_o(exec_wb_illegal),
        .wb_ebreak_o(exec_wb_ebreak),
        .wb_ecall_o(exec_wb_ecall)
    );

    assign exec_wb_clear = 1'b1;
    assign exec_mem_ready = exec_mem_valid && mem_ready;

    assign wb_write = exec_wb_valid &&
                      exec_wb_reg_write &&
                      !exec_wb_illegal &&
                      !exec_wb_ebreak &&
                      !halted_q;
    assign wb_rd_addr = exec_wb_rd_addr;
    assign wb_rd_data = exec_wb_data;

    assign mem_valid = exec_mem_valid ? 1'b1 : fetch_mem_valid;
    assign mem_write = exec_mem_valid ? exec_mem_write : fetch_mem_write;
    assign mem_addr = exec_mem_valid ? exec_mem_addr : fetch_mem_addr;
    assign mem_wdata = exec_mem_valid ? exec_mem_wdata : fetch_mem_wdata;
    assign mem_wstrb = exec_mem_valid ? exec_mem_wstrb : fetch_mem_wstrb;
    assign fetch_mem_ready = !exec_mem_valid && mem_ready;

    assign dbg_pc = dbg_pc_q;
    assign dbg_instr = dbg_instr_q;
    assign dbg_halted = halted_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_q           <= RESET_VECTOR;
            dbg_pc_q       <= RESET_VECTOR;
            dbg_instr_q    <= `RV64_INSTR_NOP;
            halted_q       <= 1'b0;
            halt_pending_q <= 1'b0;
        end else begin
            if (hard_flush_redirect_req) begin
                pc_q <= exec_redirect_target;
            end else if (fetch_pc_valid) begin
                pc_q <= pc_q + 64'd4;
            end

            if (decode_ebreak_accept) begin
                halt_pending_q <= 1'b1;
            end

            if (exec_wb_valid) begin
                dbg_pc_q    <= exec_wb_pc;
                dbg_instr_q <= exec_wb_instr;

                if (exec_wb_ebreak || exec_wb_illegal) begin
                    halted_q <= 1'b1;
                end
            end
        end
    end

endmodule
