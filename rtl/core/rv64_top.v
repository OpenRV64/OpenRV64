`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/isa/rv64-zifencei.v"
`include "core/fetch/fetch-defs.v"
`include "core/decode/defs/early-defs.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/exec/bp/defs.v"
`include "core/except/except-defs.v"
`include "core/trace/trace-defs.v"

module openrv64_rv64_top #(
    parameter [63:0] RESET_VECTOR = 64'h0000_0000_0000_0000,
    parameter PIPE_IF_ID = 1,
    parameter PIPE_ID_EX = 1,
    parameter PIPE_EX_MEM = 1,
    parameter PIPE_MEM_WB = 1,
    parameter ENABLE_RV64M = 0,
    parameter ENABLE_TRACE = 0,
    parameter [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE = `OPENRV64_BP_STALL
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
    input  wire        mem_error,

    input  wire        irq_m_software,
    input  wire        irq_m_timer,
    input  wire        irq_m_external,
    input  wire        irq_s_software,
    input  wire        irq_s_timer,
    input  wire        irq_s_external,

    output wire [63:0] dbg_pc,
    output wire [31:0] dbg_instr,
    output wire        dbg_halted,

    output wire [63:0]  trace_cycle,
    output wire [4:0]   trace_valid,
    output wire [4:0]   trace_stall,
    output wire [4:0]   trace_flush,
    output wire [4:0]   trace_advance,
    output wire [319:0] trace_ids,
    output wire [319:0] trace_pcs,
    output wire [159:0] trace_instrs,
    output wire [7:0]   trace_events,
    output wire [7:0]   trace_stall_causes,
    output wire         trace_retire_valid,
    output wire         trace_retire_arch,
    output wire         trace_retire_exception,
    output wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] trace_retire_cause,
    output wire [63:0]  trace_retire_next_pc,
    output wire         trace_retire_rd_write,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] trace_retire_rd,
    output wire [63:0]  trace_retire_wdata
);

    localparam TRACE_ID_WIDTH = 64;
    localparam IF_ID_WIDTH = `RV64_FETCH_DECODE_BUS_WIDTH + TRACE_ID_WIDTH;

    reg [`RV64_XLEN-1:0] pc_q;
    reg [`RV64_XLEN-1:0] dbg_pc_q;
    reg [`RV64_INSTR_WIDTH-1:0] dbg_instr_q;
    reg halted_q;
    reg halt_pending_q;
    reg reset_pending_q;
    reg redirect_dispatch_flush_q;
    reg [63:0] trace_cycle_q;
    reg [63:0] trace_next_id_q;

    wire fetch_pc_ready;
    wire fetch_pc_valid;
    wire fetch_mem_valid;
    wire fetch_mem_ready;
    wire fetch_mem_write;
    wire [`RV64_XLEN-1:0] fetch_mem_addr;
    wire [`RV64_XLEN-1:0] fetch_mem_exec_addr;
    wire [`RV64_XLEN-1:0] fetch_mem_wdata;
    wire [7:0] fetch_mem_wstrb;
    wire [`RV64_XLEN-1:0] fetch_mem_rdata;
    wire fetch_bus_ready;
    wire fetch_bus_access_fault;
    wire fetch_bus_page_fault;
    wire fetch_decode_valid;
    wire fetch_decode_clear;
    wire [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] fetch_decode_bus;
    wire [`RV64_XLEN-1:0] unused_fetch_decode_pc;
    wire [`RV64_INSTR_WIDTH-1:0] unused_fetch_decode_instr;
    wire unused_fetch_decode_fault;
    wire unused_fetch_decode_page_fault;
    wire fetch_mem_fault;
    wire fetch_mem_page_fault;
    wire [TRACE_ID_WIDTH-1:0] fetch_trace_id;

    wire if_id_in_clear;
    wire if_id_out_valid;
    wire if_id_out_clear;
    wire [IF_ID_WIDTH-1:0] if_id_out_data;
    wire [`RV64_XLEN-1:0] if_id_pc;
    wire [`RV64_INSTR_WIDTH-1:0] if_id_instr;
    wire if_id_instr_fault;
    wire if_id_instr_page_fault;
    wire [TRACE_ID_WIDTH-1:0] if_id_trace_id;

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
    wire decode_br_indirect;
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
    wire [`RV64_REG_ADDR_WIDTH-1:0] dispatch_exec_rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] dispatch_exec_rs2_addr;
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
    wire dispatch_exec_predicted_taken;
    wire dispatch_exec_word_op;
    wire dispatch_exec_system;
    wire dispatch_exec_fence;
    wire dispatch_exec_illegal;
    wire dispatch_exec_ebreak;
    wire dispatch_exec_ecall;
    wire dispatch_exec_instr_fault;
    wire dispatch_exec_instr_page_fault;
    wire dispatch_raw_hazard;
    wire dispatch_waw_hazard;
    wire dispatch_scoreboard_stall;
    wire dispatch_decode_valid;
    wire [TRACE_ID_WIDTH-1:0] dispatch_exec_trace_id;
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
    wire exec_branch_resolved;
    wire exec_branch_taken;
    wire [`RV64_FUNCT12_WIDTH-1:0] exec_csr_addr;
    wire [`RV64_XLEN-1:0] exec_csr_rdata;
    wire exec_csr_valid;
    wire exec_csr_writable;
    wire exec_csr_write;
    wire [`RV64_XLEN-1:0] exec_csr_wdata;
    wire exec_mem_valid;
    wire exec_mem_ready;
    wire exec_mem_error;
    wire exec_mem_write;
    wire [`RV64_XLEN-1:0] exec_mem_addr;
    wire [`RV64_XLEN-1:0] exec_mem_wdata;
    wire [7:0] exec_mem_wstrb;
    wire [`RV64_XLEN-1:0] exec_mem_rdata;
    wire exec_mem_access_fault;
    wire exec_mem_page_fault;
    wire exec_mem_access;
    wire [`RV64_XLEN-1:0] exec_mem_effective_addr;
    wire [2:0] exec_mem_size;
    wire exec_wb_valid;
    wire exec_wb_clear;
    wire [`RV64_XLEN-1:0] exec_wb_pc;
    wire [`RV64_XLEN-1:0] exec_wb_next_pc;
    wire [`RV64_INSTR_WIDTH-1:0] exec_wb_instr;
    wire [`RV64_XLEN-1:0] exec_wb_data;
    wire [`RV64_REG_ADDR_WIDTH-1:0] exec_wb_rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] exec_wb_rs2_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] exec_wb_rd_addr;
    wire exec_wb_reg_write;
    wire exec_wb_illegal;
    wire exec_wb_ebreak;
    wire exec_wb_ecall;
    wire exec_wb_exception;
    wire exec_wb_halt;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] exec_wb_cause;
    wire [`RV64_XLEN-1:0] exec_wb_tval;
    wire exec_wb_mret;
    wire exec_wb_sret;
    wire exec_trace_ex_advance;
    wire exec_trace_mem_valid;
    wire exec_trace_mem_clear;
    wire [TRACE_ID_WIDTH-1:0] exec_trace_mem_id;
    wire [`RV64_XLEN-1:0] exec_trace_mem_pc;
    wire [`RV64_INSTR_WIDTH-1:0] exec_trace_mem_instr;
    wire [TRACE_ID_WIDTH-1:0] exec_trace_wb_id;
    wire exec_trace_serializing;
    wire bp_branch_present;
    wire bp_branch_allocate;
    wire bp_branch_resolve;
    wire bp_prediction_taken;
    wire bp_predict_redirect;
    wire [`RV64_XLEN-1:0] bp_predict_target;
    wire bp_fetch_stall;
    wire bp_decode_stall;
    wire unused_exec_wb_context = |{
        exec_wb_illegal,
        exec_wb_ebreak,
        exec_wb_ecall
    };

    wire csr_irq_pending;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] csr_irq_cause;
    wire [`RV64_XLEN-1:0] csr_trap_vector;
    wire [`RV64_XLEN-1:0] csr_mepc;
    wire [`RV64_XLEN-1:0] csr_sepc;
    wire [`RV64_PRIV_WIDTH-1:0] csr_priv_mode;
    wire [`RV64_PRIV_WIDTH-1:0] csr_data_priv_mode;
    wire csr_sret_allowed;
    wire csr_sfence_vma_allowed;
    wire [`RV64_SATP_MODE_WIDTH-1:0] csr_satp_mode;
    wire [`RV64_SATP_ASID_WIDTH-1:0] csr_satp_asid;
    wire [`RV64_SATP_PPN_WIDTH-1:0] csr_satp_root_ppn;
    wire csr_status_sum;
    wire csr_status_mxr;
    wire csr_trap_to_s;
    wire csr_pmp_instr_allow;
    wire csr_pmp_data_allow;
    wire csr_pmp_bus_allow;
    wire unused_legacy_pmp_allow = csr_pmp_instr_allow &&
                                   csr_pmp_data_allow;
    wire core_mem_valid;
    wire core_mem_ready;
    wire core_mem_write;
    wire [`RV64_XLEN-1:0] core_mem_addr;
    wire [`RV64_XLEN-1:0] core_mem_pmp_addr;
    wire [`RV64_XLEN-1:0] core_mem_wdata;
    wire [7:0] core_mem_wstrb;
    wire [`RV64_PRIV_WIDTH-1:0] core_mem_priv;
    wire [2:0] core_mem_size;
    wire core_mem_exec;
    wire core_mem_error;
    wire core_mem_pmp_denied = core_mem_valid && !csr_pmp_bus_allow;
    wire except_vector_valid;
    wire [`RV64_XLEN-1:0] except_vector_target;

    wire retire_release_valid;
    wire retire_release_uses_rs1;
    wire retire_release_uses_rs2;
    wire [`RV64_REG_ADDR_WIDTH-1:0] retire_release_rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] retire_release_rs2_addr;
    wire retire_release_reg_write;
    wire [`RV64_REG_ADDR_WIDTH-1:0] retire_release_rd_addr;

    wire hard_flush_redirect_req;
    wire hard_flush_trap_req;
    wire hard_flush_irq_req;
    wire hard_flush_mret_req;
    wire hard_flush_sret_req;
    wire hard_flush_restart_req;
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

    wire retire_accept = exec_wb_valid && exec_wb_clear;
    wire retire_csr = retire_accept &&
                      (`RV64_OPCODE(exec_wb_instr) == `RV64_OPCODE_SYSTEM) &&
                      (`RV64_FUNCT3(exec_wb_instr) !=
                       `RV64_FUNCT3_SYSTEM_PRIV);
    wire retire_exception = retire_accept && exec_wb_exception;
    wire retire_mret = retire_accept && exec_wb_mret && !exec_wb_exception;
    wire retire_sret = retire_accept && exec_wb_sret && !exec_wb_exception;
    wire retire_arch = retire_accept && !exec_wb_exception;
    wire retire_fence = retire_accept &&
                        !exec_wb_exception &&
                        (`RV64_OPCODE(exec_wb_instr) ==
                         `RV64_OPCODE_MISC_MEM);
    wire retire_fence_i = retire_fence &&
                          (`RV64_FUNCT3(exec_wb_instr) ==
                           `RV64_ZIFENCEI_FUNCT3_FENCE_I);
    wire retire_sfence_vma = retire_accept &&
                             !exec_wb_exception &&
                             `RV64_IS_SFENCE_VMA(exec_wb_instr);
    wire irq_take = csr_irq_pending &&
                    retire_accept &&
                    !retire_exception &&
                    !exec_wb_halt &&
                    !retire_mret &&
                    !retire_sret;
    wire trap_enter = retire_exception || irq_take;
    wire trap_interrupt = irq_take;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] trap_cause =
        irq_take ? csr_irq_cause : exec_wb_cause;
    wire [`RV64_XLEN-1:0] trap_pc =
        irq_take ? exec_wb_next_pc : exec_wb_pc;
    wire [`RV64_XLEN-1:0] trap_tval =
        irq_take ? 64'd0 : exec_wb_tval;

    assign hard_flush_redirect_req = exec_redirect_valid;
    assign hard_flush_trap_req = retire_exception && !exec_wb_halt;
    assign hard_flush_irq_req = irq_take;
    assign hard_flush_mret_req = retire_mret;
    assign hard_flush_sret_req = retire_sret;
    assign hard_flush_restart_req = retire_fence_i || retire_sfence_vma;
    assign hard_flush_req = except_vector_valid;

    assign flush_if_id = hard_flush_req;
    assign flush_id_ex = hard_flush_trap_req ||
                         hard_flush_irq_req ||
                         hard_flush_mret_req ||
                         hard_flush_sret_req ||
                         hard_flush_restart_req ||
                         redirect_dispatch_flush_q;
    assign flush_ex_mem = hard_flush_trap_req ||
                          hard_flush_irq_req ||
                          hard_flush_mret_req ||
                          hard_flush_sret_req;
    assign flush_mem_wb = 1'b0;
    assign drain_fetch_req = decode_ebreak_accept || halted_q;
    assign flush_fetch = hard_flush_req ||
                         drain_fetch_req ||
                         bp_predict_redirect;

    assign fetch_pc_valid = fetch_pc_ready &&
                            !halted_q &&
                            !halt_pending_q &&
                            !decode_ebreak_accept &&
                            !bp_fetch_stall &&
                            !hard_flush_req;
    assign fetch_decode_clear = if_id_in_clear && !bp_fetch_stall;

    openrv64_fetch u_fetch (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_fetch),
        .pc_ready_o(fetch_pc_ready),
        .pc_valid_i(fetch_pc_valid),
        .pc_i(pc_q),
        .trace_id_i(ENABLE_TRACE ? trace_next_id_q : 64'd0),
        .mem_valid_o(fetch_mem_valid),
        .mem_ready_i(fetch_mem_ready),
        .mem_write_o(fetch_mem_write),
        .mem_addr_o(fetch_mem_addr),
        .mem_exec_addr_o(fetch_mem_exec_addr),
        .mem_wdata_o(fetch_mem_wdata),
        .mem_wstrb_o(fetch_mem_wstrb),
        .mem_rdata_i(fetch_mem_rdata),
        .mem_fault_i(fetch_mem_fault),
        .mem_page_fault_i(fetch_mem_page_fault),
        .decode_valid_o(fetch_decode_valid),
        .decode_ready_i(fetch_decode_clear),
        .decode_bus_o(fetch_decode_bus),
        .decode_pc_o(unused_fetch_decode_pc),
        .decode_instr_o(unused_fetch_decode_instr),
        .decode_fault_o(unused_fetch_decode_fault),
        .decode_page_fault_o(unused_fetch_decode_page_fault),
        .trace_id_o(fetch_trace_id)
    );

    assign if_id_out_clear = dispatch_decode_clear && !bp_decode_stall;

    openrv64_stage #(
        .WIDTH(IF_ID_WIDTH),
        .REGISTERED(PIPE_IF_ID)
    ) u_if_id (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_if_id),
        .in_valid_i(fetch_decode_valid && !bp_fetch_stall),
        .in_clear_o(if_id_in_clear),
        .in_data_i({fetch_trace_id, fetch_decode_bus}),
        .out_valid_o(if_id_out_valid),
        .out_clear_i(if_id_out_clear),
        .out_data_o(if_id_out_data)
    );

    assign {
        if_id_trace_id,
        if_id_instr_page_fault,
        if_id_instr_fault,
        if_id_pc,
        if_id_instr
    } = if_id_out_data;

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
        .br_indirect_o(decode_br_indirect),
        .subdecode_needed_o(unused_decode_subdecode_needed),
        .extension_decode_possible_o(unused_decode_extension_possible)
    );

    assign bp_branch_present = if_id_out_valid &&
                               !hard_flush_req &&
                               (decode_branch || decode_jump);
    assign bp_branch_allocate = bp_branch_present && if_id_out_clear;
    assign bp_branch_resolve = exec_branch_resolved;
    assign bp_predict_redirect = bp_branch_allocate &&
                                 bp_prediction_taken;
    assign bp_predict_target = if_id_pc + decode_imm;

    openrv64_exec_bp #(
        .BP_TYPE(BP_TYPE)
    ) u_bp (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(hard_flush_req),
        .lookup_valid_i(bp_branch_present),
        .lookup_branch_i(decode_branch),
        .lookup_jump_i(decode_jump),
        .lookup_indirect_i(decode_br_indirect),
        .lookup_allocate_i(bp_branch_allocate),
        .resolve_valid_i(bp_branch_resolve),
        .resolve_branch_i(dispatch_exec_branch),
        .resolve_taken_i(exec_branch_taken),
        .prediction_taken_o(bp_prediction_taken),
        .fetch_stall_o(bp_fetch_stall),
        .decode_stall_o(bp_decode_stall)
    );

    openrv64_rv64i_gpr u_gpr (
        .clk(clk),
        .rst_n(rst_n),
        .rs1_addr_i(dispatch_exec_rs1_addr),
        .rs1_data_o(gpr_rs1_data),
        .rs2_addr_i(dispatch_exec_rs2_addr),
        .rs2_data_o(gpr_rs2_data),
        .rd_write_i(wb_write),
        .rd_addr_i(wb_rd_addr),
        .rd_data_i(wb_rd_data)
    );

    openrv64_rv64i_csrs #(
        .ENABLE_RV64M(ENABLE_RV64M)
    ) u_csrs (
        .clk(clk),
        .rst_n(rst_n),
        .csr_addr_i(exec_csr_addr),
        .csr_rdata_o(exec_csr_rdata),
        .csr_valid_o(exec_csr_valid),
        .csr_writable_o(exec_csr_writable),
        .csr_write_i(exec_csr_write),
        .csr_wdata_i(exec_csr_wdata),
        .trap_enter_i(trap_enter),
        .trap_interrupt_i(trap_interrupt),
        .trap_cause_i(trap_cause),
        .trap_pc_i(trap_pc),
        .trap_tval_i(trap_tval),
        .mret_i(retire_mret),
        .sret_i(retire_sret),
        .retire_i(retire_arch),
        .irq_software_i(irq_m_software),
        .irq_timer_i(irq_m_timer),
        .irq_external_i(irq_m_external),
        .irq_s_software_i(irq_s_software),
        .irq_s_timer_i(irq_s_timer),
        .irq_s_external_i(irq_s_external),
        .irq_pending_o(csr_irq_pending),
        .irq_cause_o(csr_irq_cause),
        .trap_vector_o(csr_trap_vector),
        .trap_to_s_o(csr_trap_to_s),
        .mepc_o(csr_mepc),
        .sepc_o(csr_sepc),
        .priv_mode_o(csr_priv_mode),
        .data_priv_mode_o(csr_data_priv_mode),
        .sret_allowed_o(csr_sret_allowed),
        .sfence_vma_allowed_o(csr_sfence_vma_allowed),
        .satp_mode_o(csr_satp_mode),
        .satp_asid_o(csr_satp_asid),
        .satp_root_ppn_o(csr_satp_root_ppn),
        .status_sum_o(csr_status_sum),
        .status_mxr_o(csr_status_mxr),
        .pmp_instr_addr_i(fetch_mem_exec_addr),
        .pmp_instr_allow_o(csr_pmp_instr_allow),
        .pmp_data_valid_i(exec_mem_access),
        .pmp_data_addr_i(exec_mem_effective_addr),
        .pmp_data_size_i(exec_mem_size),
        .pmp_data_write_i(exec_mem_write),
        .pmp_data_allow_o(csr_pmp_data_allow),
        .pmp_bus_valid_i(core_mem_valid),
        .pmp_bus_addr_i(core_mem_pmp_addr),
        .pmp_bus_size_i(core_mem_size),
        .pmp_bus_write_i(core_mem_write),
        .pmp_bus_exec_i(core_mem_exec),
        .pmp_bus_priv_mode_i(core_mem_priv),
        .pmp_bus_allow_o(csr_pmp_bus_allow)
    );

    openrv64_except_vector #(
        .RESET_VECTOR(RESET_VECTOR)
    ) u_except_vector (
        .reset_i(reset_pending_q),
        .trap_i(hard_flush_trap_req),
        .irq_i(hard_flush_irq_req),
        .mret_i(hard_flush_mret_req),
        .sret_i(hard_flush_sret_req),
        .restart_i(hard_flush_restart_req),
        .redirect_i(hard_flush_redirect_req),
        .trap_vector_i(csr_trap_vector),
        .mepc_i(csr_mepc),
        .sepc_i(csr_sepc),
        .restart_target_i(exec_wb_next_pc),
        .redirect_target_i(exec_redirect_target),
        .vector_valid_o(except_vector_valid),
        .vector_target_o(except_vector_target)
    );

    assign dispatch_decode_valid = if_id_out_valid &&
                                   !bp_decode_stall &&
                                   !hard_flush_req;

    openrv64_dispatch #(
        .REGISTERED(PIPE_ID_EX)
    ) u_dispatch (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_id_ex),
        .decode_valid_i(dispatch_decode_valid),
        .decode_clear_o(dispatch_decode_clear),
        .decode_pc_i(if_id_pc),
        .decode_instr_i(if_id_instr),
        .decode_trace_id_i(if_id_trace_id),
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
        .decode_predicted_taken_i(bp_prediction_taken),
        .decode_word_op_i(decode_word_op),
        .decode_system_i(decode_system),
        .decode_fence_i(decode_fence),
        .decode_illegal_i(decode_illegal || !decode_valid),
        .decode_ebreak_i(decode_ebreak),
        .decode_ecall_i(decode_ecall),
        .decode_instr_fault_i(if_id_instr_fault),
        .decode_instr_page_fault_i(if_id_instr_page_fault),
        .exec_valid_o(dispatch_exec_valid),
        .exec_clear_i(exec_clear),
        .exec_alu_ready_i(exec_alu_ready),
        .exec_lsu_ready_i(exec_lsu_ready),
        .exec_br_ready_i(exec_br_ready),
        .exec_system_ready_i(exec_system_ready),
        .exec_pc_o(dispatch_exec_pc),
        .exec_instr_o(dispatch_exec_instr),
        .exec_trace_id_o(dispatch_exec_trace_id),
        .exec_rs1_addr_o(dispatch_exec_rs1_addr),
        .exec_rs2_addr_o(dispatch_exec_rs2_addr),
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
        .exec_predicted_taken_o(dispatch_exec_predicted_taken),
        .exec_word_op_o(dispatch_exec_word_op),
        .exec_system_o(dispatch_exec_system),
        .exec_fence_o(dispatch_exec_fence),
        .exec_illegal_o(dispatch_exec_illegal),
        .exec_ebreak_o(dispatch_exec_ebreak),
        .exec_ecall_o(dispatch_exec_ecall),
        .exec_instr_fault_o(dispatch_exec_instr_fault),
        .exec_instr_page_fault_o(dispatch_exec_instr_page_fault),
        .retire_valid_i(retire_release_valid),
        .retire_csr_i(retire_csr),
        .retire_fence_i(retire_fence),
        .retire_uses_rs1_i(retire_release_uses_rs1),
        .retire_uses_rs2_i(retire_release_uses_rs2),
        .retire_rs1_addr_i(retire_release_rs1_addr),
        .retire_rs2_addr_i(retire_release_rs2_addr),
        .retire_reg_write_i(retire_release_reg_write),
        .retire_rd_addr_i(retire_release_rd_addr),
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
        .trace_id_i(dispatch_exec_trace_id),
        .rs1_addr_i(dispatch_exec_rs1_addr),
        .rs2_addr_i(dispatch_exec_rs2_addr),
        .rs1_data_i(gpr_rs1_data),
        .rs2_data_i(gpr_rs2_data),
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
        .predicted_taken_i(dispatch_exec_predicted_taken),
        .word_op_i(dispatch_exec_word_op),
        .system_i(dispatch_exec_system),
        .fence_i(dispatch_exec_fence),
        .illegal_i(dispatch_exec_illegal),
        .ebreak_i(dispatch_exec_ebreak),
        .ecall_i(dispatch_exec_ecall),
        .instr_access_fault_i(dispatch_exec_instr_fault),
        .instr_page_fault_i(dispatch_exec_instr_page_fault),
        .priv_mode_i(csr_priv_mode),
        .sret_allowed_i(csr_sret_allowed),
        .sfence_vma_allowed_i(csr_sfence_vma_allowed),
        .redirect_valid_o(exec_redirect_valid),
        .redirect_target_o(exec_redirect_target),
        .branch_resolved_o(exec_branch_resolved),
        .branch_taken_o(exec_branch_taken),
        .csr_addr_o(exec_csr_addr),
        .csr_rdata_i(exec_csr_rdata),
        .csr_valid_i(exec_csr_valid),
        .csr_writable_i(exec_csr_writable),
        .csr_write_o(exec_csr_write),
        .csr_wdata_o(exec_csr_wdata),
        .mem_valid_o(exec_mem_valid),
        .mem_ready_i(exec_mem_ready),
        .mem_error_i(exec_mem_error),
        .mem_page_fault_i(exec_mem_page_fault),
        .mem_access_allowed_i(1'b1),
        .mem_write_o(exec_mem_write),
        .mem_addr_o(exec_mem_addr),
        .mem_wdata_o(exec_mem_wdata),
        .mem_wstrb_o(exec_mem_wstrb),
        .mem_access_o(exec_mem_access),
        .mem_effective_addr_o(exec_mem_effective_addr),
        .mem_size_o(exec_mem_size),
        .mem_rdata_i(exec_mem_rdata),
        .wb_valid_o(exec_wb_valid),
        .wb_clear_i(exec_wb_clear),
        .wb_pc_o(exec_wb_pc),
        .wb_next_pc_o(exec_wb_next_pc),
        .wb_instr_o(exec_wb_instr),
        .wb_data_o(exec_wb_data),
        .wb_rs1_addr_o(exec_wb_rs1_addr),
        .wb_rs2_addr_o(exec_wb_rs2_addr),
        .wb_rd_addr_o(exec_wb_rd_addr),
        .wb_reg_write_o(exec_wb_reg_write),
        .wb_illegal_o(exec_wb_illegal),
        .wb_ebreak_o(exec_wb_ebreak),
        .wb_ecall_o(exec_wb_ecall),
        .wb_exception_o(exec_wb_exception),
        .wb_halt_o(exec_wb_halt),
        .wb_cause_o(exec_wb_cause),
        .wb_tval_o(exec_wb_tval),
        .wb_mret_o(exec_wb_mret),
        .wb_sret_o(exec_wb_sret),
        .trace_ex_advance_o(exec_trace_ex_advance),
        .trace_mem_valid_o(exec_trace_mem_valid),
        .trace_mem_clear_o(exec_trace_mem_clear),
        .trace_mem_id_o(exec_trace_mem_id),
        .trace_mem_pc_o(exec_trace_mem_pc),
        .trace_mem_instr_o(exec_trace_mem_instr),
        .trace_wb_id_o(exec_trace_wb_id),
        .trace_serializing_o(exec_trace_serializing)
    );

    assign exec_wb_clear = 1'b1;

    openrv64_retire u_retire (
        .valid_i(exec_wb_valid),
        .clear_i(exec_wb_clear),
        .rs1_addr_i(exec_wb_rs1_addr),
        .rs2_addr_i(exec_wb_rs2_addr),
        .reg_write_i(exec_wb_reg_write),
        .rd_addr_i(exec_wb_rd_addr),
        .release_valid_o(retire_release_valid),
        .release_uses_rs1_o(retire_release_uses_rs1),
        .release_uses_rs2_o(retire_release_uses_rs2),
        .release_rs1_addr_o(retire_release_rs1_addr),
        .release_rs2_addr_o(retire_release_rs2_addr),
        .release_reg_write_o(retire_release_reg_write),
        .release_rd_addr_o(retire_release_rd_addr)
    );

    assign wb_write = exec_wb_valid &&
                      exec_wb_reg_write &&
                      !exec_wb_exception &&
                      !halted_q;
    assign wb_rd_addr = exec_wb_rd_addr;
    assign wb_rd_data = exec_wb_data;

    assign fetch_mem_ready = fetch_bus_ready;
    assign fetch_mem_fault = fetch_bus_access_fault;
    assign fetch_mem_page_fault = fetch_bus_page_fault;
    assign exec_mem_error = exec_mem_access_fault;

    assign core_mem_ready = core_mem_pmp_denied || mem_ready;
    assign core_mem_error = core_mem_pmp_denied || mem_error;
    assign mem_valid = core_mem_valid && csr_pmp_bus_allow;
    assign mem_write = core_mem_write;
    assign mem_addr = core_mem_addr;
    assign mem_wdata = core_mem_wdata;
    assign mem_wstrb = core_mem_wstrb;

    openrv64_core_bus u_core_bus (
        .clk(clk),
        .rst_n(rst_n),
        .fetch_valid_i(fetch_mem_valid),
        .fetch_cancel_i(flush_fetch),
        .fetch_addr_i(fetch_mem_exec_addr),
        .fetch_priv_i(csr_priv_mode),
        .fetch_vm_mode_i((csr_priv_mode == `RV64_PRIV_M) ?
                         `RV64_SATP_MODE_BARE : csr_satp_mode),
        .fetch_asid_i(csr_satp_asid),
        .fetch_root_ppn_i(csr_satp_root_ppn),
        .fetch_sum_i(csr_status_sum),
        .fetch_mxr_i(csr_status_mxr),
        .fetch_ready_o(fetch_bus_ready),
        .fetch_rdata_o(fetch_mem_rdata),
        .fetch_access_fault_o(fetch_bus_access_fault),
        .fetch_page_fault_o(fetch_bus_page_fault),
        .lsu_valid_i(exec_mem_valid),
        .lsu_write_i(exec_mem_write),
        .lsu_addr_i(exec_mem_addr),
        .lsu_wdata_i(exec_mem_wdata),
        .lsu_wstrb_i(exec_mem_wstrb),
        .lsu_size_i(exec_mem_size),
        .lsu_priv_i(csr_data_priv_mode),
        .lsu_vm_mode_i((csr_data_priv_mode == `RV64_PRIV_M) ?
                       `RV64_SATP_MODE_BARE : csr_satp_mode),
        .lsu_asid_i(csr_satp_asid),
        .lsu_root_ppn_i(csr_satp_root_ppn),
        .lsu_sum_i(csr_status_sum),
        .lsu_mxr_i(csr_status_mxr),
        .lsu_ready_o(exec_mem_ready),
        .lsu_rdata_o(exec_mem_rdata),
        .lsu_access_fault_o(exec_mem_access_fault),
        .lsu_page_fault_o(exec_mem_page_fault),
        .tlbi_i(retire_sfence_vma),
        .req_valid_o(core_mem_valid),
        .req_ready_i(core_mem_ready),
        .req_write_o(core_mem_write),
        .req_addr_o(core_mem_addr),
        .req_pmp_addr_o(core_mem_pmp_addr),
        .req_priv_o(core_mem_priv),
        .req_size_o(core_mem_size),
        .req_exec_o(core_mem_exec),
        .req_wdata_o(core_mem_wdata),
        .req_wstrb_o(core_mem_wstrb),
        .req_rdata_i(mem_rdata),
        .req_error_i(core_mem_error),
        .fetch_next_valid_i(fetch_pc_valid),
        .fetch_next_addr_i(pc_q)
    );

    assign dbg_pc = dbg_pc_q;
    assign dbg_instr = dbg_instr_q;
    assign dbg_halted = halted_q;

    // Trace slot order is fixed: 0=IF, 1=ID, 2=EX, 3=MEM, 4=WB.
    // Each packed vector uses the stage number as its element index, so the
    // IF element occupies the least-significant slice.
    wire trace_if_valid = fetch_mem_valid || fetch_decode_valid;
    wire [`RV64_XLEN-1:0] trace_if_pc = fetch_decode_valid ?
        unused_fetch_decode_pc : fetch_mem_exec_addr;
    wire [`RV64_INSTR_WIDTH-1:0] trace_if_instr = fetch_decode_valid ?
        unused_fetch_decode_instr : {`RV64_INSTR_WIDTH{1'b0}};
    wire trace_if_advance = fetch_decode_valid ? fetch_decode_clear :
                            (fetch_mem_valid && fetch_mem_ready);
    wire trace_id_advance = if_id_out_valid && if_id_out_clear;
    wire trace_mem_advance = exec_trace_mem_valid && exec_trace_mem_clear;
    wire [4:0] trace_valid_raw = {
        exec_wb_valid,
        exec_trace_mem_valid,
        dispatch_exec_valid,
        if_id_out_valid,
        trace_if_valid
    };
    wire [4:0] trace_advance_raw = {
        retire_accept,
        trace_mem_advance,
        exec_trace_ex_advance,
        trace_id_advance,
        trace_if_advance
    };
    wire [4:0] trace_flush_raw = {
        flush_mem_wb,
        flush_ex_mem,
        flush_id_ex,
        flush_if_id,
        flush_fetch
    };
    wire [4:0] trace_stall_raw = trace_valid_raw &
                                  ~trace_advance_raw &
                                  ~trace_flush_raw;
    wire [7:0] trace_events_raw;
    wire [7:0] trace_stall_causes_raw;

    assign trace_events_raw[`OPENRV64_TRACE_EVENT_REDIRECT] =
        hard_flush_redirect_req || bp_predict_redirect;
    assign trace_events_raw[`OPENRV64_TRACE_EVENT_TRAP] =
        hard_flush_trap_req;
    assign trace_events_raw[`OPENRV64_TRACE_EVENT_IRQ] =
        hard_flush_irq_req;
    assign trace_events_raw[`OPENRV64_TRACE_EVENT_MRET] =
        hard_flush_mret_req;
    assign trace_events_raw[`OPENRV64_TRACE_EVENT_SRET] =
        hard_flush_sret_req;
    assign trace_events_raw[`OPENRV64_TRACE_EVENT_RESTART] =
        hard_flush_restart_req;
    assign trace_events_raw[`OPENRV64_TRACE_EVENT_HALT] =
        retire_accept && exec_wb_halt;
    assign trace_events_raw[`OPENRV64_TRACE_EVENT_RESET] = reset_pending_q;

    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_RAW] =
        trace_stall_raw[`OPENRV64_TRACE_STAGE_ID] &&
        dispatch_raw_hazard;
    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_WAW] =
        trace_stall_raw[`OPENRV64_TRACE_STAGE_ID] &&
        dispatch_waw_hazard;
    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_SCOREBOARD] =
        trace_stall_raw[`OPENRV64_TRACE_STAGE_ID] &&
        dispatch_scoreboard_stall;
    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_IF_MEMORY] =
        trace_stall_raw[`OPENRV64_TRACE_STAGE_IF] &&
        !fetch_decode_valid &&
        fetch_mem_valid && !fetch_mem_ready;
    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_DATA_MEMORY] =
        trace_stall_raw[`OPENRV64_TRACE_STAGE_MEM] &&
        exec_mem_valid && !exec_mem_ready;
    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_EXECUTE] =
        trace_stall_raw[`OPENRV64_TRACE_STAGE_EX] &&
        dispatch_exec_valid && !exec_clear;
    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_FRONTEND_HELD] =
        trace_stall_raw[`OPENRV64_TRACE_STAGE_IF] &&
        fetch_decode_valid && !fetch_decode_clear;
    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_SERIALIZING] =
        (trace_stall_raw[`OPENRV64_TRACE_STAGE_ID] ||
         trace_stall_raw[`OPENRV64_TRACE_STAGE_EX]) &&
        exec_trace_serializing;

    assign trace_cycle = ENABLE_TRACE ? trace_cycle_q : 64'd0;
    assign trace_valid = ENABLE_TRACE ? trace_valid_raw : 5'd0;
    assign trace_stall = ENABLE_TRACE ? trace_stall_raw : 5'd0;
    assign trace_flush = ENABLE_TRACE ? trace_flush_raw : 5'd0;
    assign trace_advance = ENABLE_TRACE ? trace_advance_raw : 5'd0;
    assign trace_ids = ENABLE_TRACE ? {
        exec_wb_valid ? exec_trace_wb_id : 64'd0,
        exec_trace_mem_valid ? exec_trace_mem_id : 64'd0,
        dispatch_exec_valid ? dispatch_exec_trace_id : 64'd0,
        if_id_out_valid ? if_id_trace_id : 64'd0,
        trace_if_valid ? fetch_trace_id : 64'd0
    } : 320'd0;
    assign trace_pcs = ENABLE_TRACE ? {
        exec_wb_valid ? exec_wb_pc : 64'd0,
        exec_trace_mem_valid ? exec_trace_mem_pc : 64'd0,
        dispatch_exec_valid ? dispatch_exec_pc : 64'd0,
        if_id_out_valid ? if_id_pc : 64'd0,
        trace_if_valid ? trace_if_pc : 64'd0
    } : 320'd0;
    assign trace_instrs = ENABLE_TRACE ? {
        exec_wb_valid ? exec_wb_instr : 32'd0,
        exec_trace_mem_valid ? exec_trace_mem_instr : 32'd0,
        dispatch_exec_valid ? dispatch_exec_instr : 32'd0,
        if_id_out_valid ? if_id_instr : 32'd0,
        trace_if_valid ? trace_if_instr : 32'd0
    } : 160'd0;
    assign trace_events = ENABLE_TRACE ? trace_events_raw : 8'd0;
    assign trace_stall_causes = ENABLE_TRACE ? trace_stall_causes_raw : 8'd0;
    assign trace_retire_valid = ENABLE_TRACE && retire_accept;
    assign trace_retire_arch = ENABLE_TRACE && retire_arch;
    assign trace_retire_exception = ENABLE_TRACE && retire_exception;
    assign trace_retire_cause = ENABLE_TRACE ? exec_wb_cause :
                                {`RV64_EXCEPT_CAUSE_WIDTH{1'b0}};
    assign trace_retire_next_pc = ENABLE_TRACE ? exec_wb_next_pc : 64'd0;
    assign trace_retire_rd_write = ENABLE_TRACE && retire_arch &&
                                   exec_wb_reg_write &&
                                   (exec_wb_rd_addr != `RV64_REG_X0);
    assign trace_retire_rd = ENABLE_TRACE ? exec_wb_rd_addr :
                             {`RV64_REG_ADDR_WIDTH{1'b0}};
    assign trace_retire_wdata = ENABLE_TRACE ? exec_wb_data : 64'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            redirect_dispatch_flush_q <= 1'b0;
        end else begin
            redirect_dispatch_flush_q <= hard_flush_redirect_req;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trace_cycle_q <= 64'd0;
            trace_next_id_q <= 64'd1;
        end else if (ENABLE_TRACE) begin
            trace_cycle_q <= trace_cycle_q + 64'd1;

            if (fetch_pc_valid) begin
                trace_next_id_q <= trace_next_id_q +
                                   (pc_q[2] ? 64'd1 : 64'd2);
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_q           <= {`RV64_XLEN{1'b0}};
            dbg_pc_q       <= {`RV64_XLEN{1'b0}};
            dbg_instr_q    <= `RV64_INSTR_NOP;
            halted_q       <= 1'b0;
            halt_pending_q <= 1'b0;
            reset_pending_q <= 1'b1;
        end else begin
            if (except_vector_valid) begin
                pc_q <= except_vector_target;
            end else if (bp_predict_redirect) begin
                pc_q <= bp_predict_target;
            end else if (fetch_pc_valid) begin
                // A line-aligned request supplies two 32-bit instructions.  A
                // redirect into the upper half consumes only that half before
                // advancing to the next aligned line.
                pc_q <= pc_q + (pc_q[2] ? 64'd4 : 64'd8);
            end

            if (hard_flush_req) begin
                halt_pending_q <= 1'b0;
            end else if (decode_ebreak_accept) begin
                halt_pending_q <= 1'b1;
            end

            if (reset_pending_q) begin
                reset_pending_q <= 1'b0;
                dbg_pc_q        <= except_vector_target;
            end

            if (exec_wb_valid) begin
                dbg_pc_q    <= exec_wb_pc;
                dbg_instr_q <= exec_wb_instr;

                if (exec_wb_halt) begin
                    halted_q       <= 1'b1;
                    halt_pending_q <= 1'b0;
                end
            end
        end
    end

endmodule
