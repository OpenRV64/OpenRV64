`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-a.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/except/except-defs.v"

module openrv64_exec_top_1p #(
    parameter PIPE_EX_MEM = 1,
    parameter PIPE_MEM_WB = 1,
    parameter ENABLE_RV64M = 0,
    parameter ENABLE_FORWARDING = 0,
    parameter ENABLE_LOAD_FORWARDING = 0
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
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr_i,
    input  wire [`RV64_XLEN-1:0]        rs1_data_i,
    input  wire [`RV64_XLEN-1:0]        rs2_data_i,
    input  wire [`RV64_XLEN-1:0]        imm_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr_i,
    input  wire [`RV64_ALU_EXT_WIDTH-1:0] alu_ext_i,
    input  wire [`RV64_ALU_OP_WIDTH-1:0] alu_op_i,
    input  wire [`RV64_LSU_OP_WIDTH-1:0] lsu_op_i,
    input  wire [`RV64_BR_OP_WIDTH-1:0] br_op_i,
    input  wire                         reg_write_i,
    input  wire                         mem_read_i,
    input  wire                         mem_write_i,
    input  wire                         branch_i,
    input  wire                         jump_i,
    input  wire                         predicted_taken_i,
    input  wire                         word_op_i,
    input  wire                         system_i,
    input  wire                         fence_i,
    input  wire                         illegal_i,
    input  wire                         ebreak_i,
    input  wire                         ecall_i,
    input  wire                         instr_access_fault_i,
    input  wire                         instr_page_fault_i,
    input  wire [`RV64_PRIV_WIDTH-1:0] priv_mode_i,
    input  wire                         sret_allowed_i,
    input  wire                         sfence_vma_allowed_i,

    output wire                         redirect_valid_o,
    output wire [`RV64_XLEN-1:0]        redirect_target_o,
    output wire                         branch_resolved_o,
    output wire                         branch_taken_o,

    output wire [`RV64_FUNCT12_WIDTH-1:0] csr_addr_o,
    input  wire [`RV64_XLEN-1:0]        csr_rdata_i,
    input  wire                         csr_valid_i,
    input  wire                         csr_writable_i,
    output wire                         csr_write_o,
    output wire [`RV64_XLEN-1:0]        csr_wdata_o,

    output wire                         mem_valid_o,
    input  wire                         mem_ready_i,
    input  wire                         mem_error_i,
    input  wire                         mem_page_fault_i,
    input  wire                         mem_access_allowed_i,
    output wire                         mem_lock_o,
    output wire                         mem_write_o,
    output wire [`RV64_XLEN-1:0]        mem_addr_o,
    output wire [`RV64_XLEN-1:0]        mem_wdata_o,
    output wire [7:0]                   mem_wstrb_o,
    output wire                         mem_access_o,
    output wire [`RV64_XLEN-1:0]        mem_effective_addr_o,
    output wire [2:0]                   mem_size_o,
    input  wire [`RV64_XLEN-1:0]        mem_rdata_i,

    output wire                         wb_valid_o,
    input  wire                         wb_clear_i,
    output wire [`RV64_XLEN-1:0]        wb_pc_o,
    output wire [`RV64_XLEN-1:0]        wb_next_pc_o,
    output wire [`RV64_INSTR_WIDTH-1:0] wb_instr_o,
    output wire [`RV64_XLEN-1:0]        wb_data_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] wb_rs1_addr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] wb_rs2_addr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] wb_rd_addr_o,
    output wire                         wb_reg_write_o,
    output wire                         wb_illegal_o,
    output wire                         wb_ebreak_o,
    output wire                         wb_ecall_o,
    output wire                         wb_exception_o,
    output wire                         wb_halt_o,
    output wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] wb_cause_o,
    output wire [`RV64_XLEN-1:0]        wb_tval_o,
    output wire                         wb_mret_o,
    output wire                         wb_sret_o,

    output wire                         forward_ex_valid_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] forward_ex_rd_addr_o,
    output wire                         forward_mem_valid_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] forward_mem_rd_addr_o,

    input  wire [63:0]                  trace_id_i,
    output wire                         trace_ex_advance_o,
    output wire                         trace_mem_valid_o,
    output wire                         trace_mem_clear_o,
    output wire [63:0]                  trace_mem_id_o,
    output wire [`RV64_XLEN-1:0]        trace_mem_pc_o,
    output wire [`RV64_INSTR_WIDTH-1:0] trace_mem_instr_o,
    output wire [63:0]                  trace_wb_id_o,
    output wire                         trace_serializing_o
);

    localparam EX_MEM_WIDTH = 581;
    localparam MEM_WB_WIDTH = 380;

    wire [`RV64_OPCODE_WIDTH-1:0] opcode = `RV64_OPCODE(instr_i);
    wire [`RV64_XLEN-1:0] forwarded_rs1_data;
    wire [`RV64_XLEN-1:0] forwarded_rs2_data;
    wire alu_uses_imm = (opcode == `RV64_OPCODE_LUI) ||
                        (opcode == `RV64_OPCODE_AUIPC) ||
                        (opcode == `RV64_OPCODE_OP_IMM) ||
                        (opcode == `RV64_OPCODE_OP_IMM_32);
    wire [`RV64_XLEN-1:0] alu_src1 = (opcode == `RV64_OPCODE_LUI) ?
                                     {`RV64_XLEN{1'b0}} :
                                     forwarded_rs1_data;
    wire [`RV64_XLEN-1:0] alu_src2 = alu_uses_imm ?
                                      imm_i : forwarded_rs2_data;

    wire alu_base_valid;
    wire alu_base_illegal;
    wire [`RV64_XLEN-1:0] alu_base_result;
    wire alu_m_ready;
    wire alu_m_busy;
    wire alu_m_result_valid;
    wire alu_m_result_ready;
    wire alu_m_illegal;
    wire [`RV64_XLEN-1:0] alu_m_result;
    wire unused_alu_m_busy = alu_m_busy;
    reg alu_m_issued_q;
    wire alu_ext_is_base = (alu_ext_i == `RV64_ALU_EXT_BASE);
    wire alu_ext_is_m = (alu_ext_i == `RV64_ALU_EXT_M);
    wire ex_m_selected = valid_i &&
                         alu_ext_is_m &&
                         ENABLE_RV64M &&
                         !illegal_i;
    wire alu_m_start;
    wire alu_valid = alu_ext_is_base ? alu_base_valid :
                     alu_ext_is_m ? (ENABLE_RV64M && alu_m_result_valid) :
                     1'b0;
    wire alu_illegal = alu_ext_is_base ? alu_base_illegal :
                       alu_ext_is_m ? (!ENABLE_RV64M ||
                                       (alu_m_result_valid && alu_m_illegal)) :
                       1'b1;
    wire [`RV64_XLEN-1:0] alu_result = alu_ext_is_base ? alu_base_result :
                                       alu_ext_is_m ? alu_m_result :
                                       {`RV64_XLEN{1'b0}};
    wire br_valid;
    wire br_illegal;
    wire br_taken;
    wire [`RV64_XLEN-1:0] br_target;
    wire br_link;
    wire [`RV64_XLEN-1:0] br_link_data;

    wire csr_ready;
    wire csr_illegal;
    wire csr_unit_write;
    wire [`RV64_FUNCT12_WIDTH-1:0] csr_unit_addr;
    wire [`RV64_XLEN-1:0] csr_unit_wdata;
    wire [`RV64_XLEN-1:0] csr_rd_data;
    wire [`RV64_FUNCT3_WIDTH-1:0] system_funct3 = `RV64_FUNCT3(instr_i);
    wire [`RV64_FUNCT12_WIDTH-1:0] system_csr_addr = `RV64_CSR(instr_i);
    wire ex_csr_selected = valid_i &&
                           system_i &&
                           (system_funct3 != `RV64_FUNCT3_SYSTEM_PRIV) &&
                           !illegal_i;
    wire ex_fence_selected = valid_i && fence_i && !illegal_i;
    wire ex_mret = valid_i && system_i && (instr_i == `RV64_INSTR_MRET);
    wire ex_sret = valid_i && system_i && (instr_i == `RV64_INSTR_SRET);
    wire ex_sfence_vma = valid_i && system_i && `RV64_IS_SFENCE_VMA(instr_i);
    wire ex_return_illegal =
        (ex_mret && (priv_mode_i != `RV64_PRIV_M)) ||
        (ex_sret && !sret_allowed_i) ||
        (ex_sfence_vma && !sfence_vma_allowed_i);

    wire ex_alu_selected = valid_i && (alu_op_i != `RV64_ALU_OP_INVALID);
    wire ex_br_selected = valid_i && (branch_i || jump_i);
    wire ex_target_misaligned = ex_br_selected &&
                                br_valid &&
                                br_taken &&
                                (|br_target[1:0]);
    wire ex_instr_misaligned = (|pc_i[1:0]) || ex_target_misaligned;
    wire [`RV64_XLEN-1:0] ex_instr_badaddr =
        ex_target_misaligned ? br_target : pc_i;
    wire ex_illegal = illegal_i ||
                      (ex_alu_selected && alu_illegal) ||
                      (ex_br_selected && br_illegal) ||
                      (ex_csr_selected && csr_illegal) ||
                      ex_return_illegal;
    wire [`RV64_XLEN-1:0] ex_wb_data = ex_csr_selected ? csr_rd_data :
                                       br_link ? br_link_data : alu_result;
    wire ex_control_transfer_taken = ex_br_selected &&
                                     br_valid &&
                                     br_taken &&
                                     !ex_instr_misaligned &&
                                     !ex_illegal;
    wire [`RV64_XLEN-1:0] ex_next_pc = ex_control_transfer_taken ?
                                       br_target : (pc_i + 64'd4);

    wire ex_mem_in_valid;
    wire ex_mem_in_clear;
    wire [EX_MEM_WIDTH-1:0] ex_mem_in_data;
    wire ex_mem_out_valid;
    wire ex_mem_out_clear;
    wire [EX_MEM_WIDTH-1:0] ex_mem_out_data;
    wire [`RV64_XLEN-1:0] ex_mem_pc;
    wire [63:0] ex_mem_trace_id;
    wire [`RV64_XLEN-1:0] ex_mem_next_pc;
    wire [`RV64_INSTR_WIDTH-1:0] ex_mem_instr;
    wire [`RV64_XLEN-1:0] ex_mem_wb_data;
    wire [`RV64_XLEN-1:0] ex_mem_lsu_base;
    wire [`RV64_XLEN-1:0] ex_mem_lsu_offset;
    wire [`RV64_XLEN-1:0] ex_mem_lsu_store_data;
    wire [`RV64_REG_ADDR_WIDTH-1:0] ex_mem_rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] ex_mem_rs2_addr;
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
    wire ex_mem_instr_misaligned;
    wire [`RV64_XLEN-1:0] ex_mem_instr_badaddr;
    wire ex_mem_mret;
    wire ex_mem_sret;
    wire [`RV64_PRIV_WIDTH-1:0] ex_mem_priv_mode;
    wire ex_mem_instr_access_fault;
    wire ex_mem_instr_page_fault;
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
    wire [`RV64_XLEN-1:0] lsu_badaddr = ex_mem_lsu_base + ex_mem_lsu_offset;
    wire [2:0] lsu_access_size = {1'b0, ex_mem_instr[13:12]};
    wire ex_mem_is_atomic =
        (`RV64_OPCODE(ex_mem_instr) == `RV64_OPCODE_AMO);
    wire lsu_mem_access = ex_mem_out_valid &&
                          (ex_mem_mem_read || ex_mem_mem_write) &&
                          !ex_mem_is_atomic &&
                          !ex_mem_illegal;
    wire lsu_pmp_denied = lsu_mem_access &&
                          lsu_valid &&
                          !lsu_misaligned &&
                          !mem_access_allowed_i;
    wire lsu_mem_valid = lsu_mem_access &&
                         lsu_valid &&
                         lsu_mem_valid_raw &&
                         mem_access_allowed_i;
    wire lsu_bus_error = lsu_mem_valid && mem_ready_i && mem_error_i;
    wire lsu_page_fault = lsu_mem_valid && mem_ready_i && mem_page_fault_i;
    wire atomic_mem_access = ex_mem_out_valid &&
                             ex_mem_is_atomic &&
                             (ex_mem_mem_read || ex_mem_mem_write) &&
                             !ex_mem_illegal;
    wire atomic_is_lr = (ex_mem_lsu_op == `RV64_LSU_OP_LR);
    wire atomic_complete;
    wire atomic_illegal;
    wire atomic_misaligned;
    wire atomic_access_fault;
    wire atomic_page_fault;
    wire [`RV64_XLEN-1:0] atomic_result;
    wire atomic_mem_valid;
    wire atomic_mem_lock;
    wire atomic_mem_write;
    wire [`RV64_XLEN-1:0] atomic_mem_addr;
    wire [`RV64_XLEN-1:0] atomic_mem_wdata;
    wire [7:0] atomic_mem_wstrb;
    wire clear_atomic_reservation = ex_mem_out_valid &&
                                    !ex_mem_is_atomic &&
                                    ex_mem_mem_write;
    wire exception_valid;
    wire exception_halt;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] exception_cause;
    wire [`RV64_XLEN-1:0] exception_tval;
    wire lsu_complete = !lsu_mem_access ||
                        !lsu_valid ||
                        lsu_misaligned ||
                        lsu_pmp_denied ||
                        (lsu_mem_valid && mem_ready_i);
    // EX/MEM is always the youngest older producer visible to the current EX
    // instruction, so it has priority over the register file's WB bypass.
    // Load-response bypass is optional because it extends the combinational
    // path from mem_rdata_i through load alignment into the next EX operation.
    wire mem_forward_valid = ENABLE_FORWARDING &&
                             ex_mem_out_valid &&
                             !ex_mem_is_atomic &&
                             ex_mem_reg_write &&
                             !ex_mem_mem_write &&
                             lsu_complete &&
                             !exception_valid;
    wire mem_bypass_valid = mem_forward_valid &&
                            (ENABLE_LOAD_FORWARDING ||
                             !ex_mem_mem_read);
    wire [`RV64_XLEN-1:0] mem_forward_data = ex_mem_mem_read ?
                                                lsu_load_data :
                                                ex_mem_wb_data;
    wire rs1_mem_forward = mem_bypass_valid &&
                           (rs1_addr_i != `RV64_REG_X0) &&
                           (rs1_addr_i == ex_mem_rd_addr);
    wire rs2_mem_forward = mem_bypass_valid &&
                           (rs2_addr_i != `RV64_REG_X0) &&
                           (rs2_addr_i == ex_mem_rd_addr);

    assign forwarded_rs1_data = rs1_mem_forward ?
                                mem_forward_data : rs1_data_i;
    assign forwarded_rs2_data = rs2_mem_forward ?
                                mem_forward_data : rs2_data_i;

    wire mem_wb_in_valid;
    wire mem_wb_in_clear;
    wire [MEM_WB_WIDTH-1:0] mem_wb_in_data;
    wire [MEM_WB_WIDTH-1:0] mem_wb_out_data;
    wire load_misaligned = (ex_mem_out_valid &&
                            !ex_mem_is_atomic &&
                            ex_mem_mem_read &&
                            lsu_misaligned) ||
                           (atomic_mem_access && atomic_is_lr &&
                            atomic_misaligned);
    wire store_misaligned = (ex_mem_out_valid &&
                             !ex_mem_is_atomic &&
                             ex_mem_mem_write &&
                             lsu_misaligned) ||
                            (atomic_mem_access && !atomic_is_lr &&
                             atomic_misaligned);
    wire load_access_fault = ex_mem_out_valid &&
                             ((!ex_mem_is_atomic && ex_mem_mem_read &&
                               (lsu_pmp_denied || lsu_bus_error)) ||
                              (ex_mem_is_atomic && atomic_is_lr &&
                               atomic_access_fault));
    wire store_access_fault = ex_mem_out_valid &&
                              ((!ex_mem_is_atomic && ex_mem_mem_write &&
                                (lsu_pmp_denied || lsu_bus_error)) ||
                               (ex_mem_is_atomic && !atomic_is_lr &&
                                atomic_access_fault));
    wire load_page_fault = ex_mem_out_valid &&
                           ((!ex_mem_is_atomic && ex_mem_mem_read &&
                             lsu_page_fault) ||
                            (ex_mem_is_atomic && atomic_is_lr &&
                             atomic_page_fault));
    wire store_page_fault = ex_mem_out_valid &&
                            ((!ex_mem_is_atomic && ex_mem_mem_write &&
                              lsu_page_fault) ||
                             (ex_mem_is_atomic && !atomic_is_lr &&
                              atomic_page_fault));
    reg serializing_q;
    wire ex_serializing = valid_i &&
                           ((system_i && !ex_csr_selected) ||
                            illegal_i ||
                            ebreak_i ||
                            ecall_i);
    wire ex_requires_drain = ex_serializing ||
                             ex_csr_selected ||
                             ex_fence_selected;
    wire pipeline_empty = !ex_mem_out_valid && !wb_valid_o;
    wire serial_issue_ready = pipeline_empty && !serializing_q;
    wire ex_ready = ex_mem_in_clear &&
                    !serializing_q &&
                    (!ex_requires_drain || serial_issue_ready) &&
                    (!ex_m_selected ||
                     (alu_m_issued_q && alu_m_result_valid));
    wire serial_issue = ex_mem_in_valid && ex_serializing;

    assign alu_m_start = ex_m_selected &&
                         !alu_m_issued_q &&
                         alu_m_ready &&
                         ex_mem_in_clear &&
                         !serializing_q;

    openrv64_exec_alu_rv64i u_alu_base_exec (
        .op_sel_i(alu_op_i),
        .word_op_i(word_op_i),
        .src1_i(alu_src1),
        .src2_i(alu_src2),
        .pc_i(pc_i),
        .valid_o(alu_base_valid),
        .illegal_o(alu_base_illegal),
        .result_o(alu_base_result)
    );

    openrv64_exec_rv64m u_rv64m_exec (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_ex_mem_i),
        .valid_i(alu_m_start),
        .ready_o(alu_m_ready),
        .busy_o(alu_m_busy),
        .op_sel_i(alu_op_i),
        .word_op_i(word_op_i),
        .src1_i(forwarded_rs1_data),
        .src2_i(forwarded_rs2_data),
        .result_valid_o(alu_m_result_valid),
        .result_ready_i(alu_m_result_ready),
        .illegal_o(alu_m_illegal),
        .result_o(alu_m_result)
    );

    openrv64_exec_br u_br_exec (
        .op_sel_i(br_op_i),
        .pc_i(pc_i),
        .src1_i(forwarded_rs1_data),
        .src2_i(forwarded_rs2_data),
        .imm_i(imm_i),
        .valid_o(br_valid),
        .illegal_o(br_illegal),
        .taken_o(br_taken),
        .target_o(br_target),
        .link_o(br_link),
        .link_data_o(br_link_data)
    );

    openrv64_exec_system_csr u_csr_exec (
        .valid_i(ex_csr_selected),
        .funct3_i(system_funct3),
        .csr_addr_i(system_csr_addr),
        .rs1_addr_i(rs1_addr_i),
        .rs1_data_i(forwarded_rs1_data),
        .zimm_i(`RV64_RS1(instr_i)),
        .csr_rdata_i(csr_rdata_i),
        .csr_valid_i(csr_valid_i),
        .csr_writable_i(csr_writable_i),
        .ready_o(csr_ready),
        .illegal_o(csr_illegal),
        .csr_write_o(csr_unit_write),
        .csr_addr_o(csr_unit_addr),
        .csr_wdata_o(csr_unit_wdata),
        .rd_data_o(csr_rd_data)
    );

    assign branch_resolved_o = ex_mem_in_valid &&
                               (branch_i || jump_i);
    assign branch_taken_o = branch_resolved_o &&
                            ex_control_transfer_taken;
    assign redirect_valid_o = branch_resolved_o &&
                              !ex_instr_misaligned &&
                              !ex_illegal &&
                              (predicted_taken_i !=
                               ex_control_transfer_taken);
    assign redirect_target_o = ex_control_transfer_taken ?
                               br_target : (pc_i + 64'd4);

    assign csr_addr_o = csr_unit_addr;
    assign csr_write_o = ex_mem_in_valid &&
                         ex_csr_selected &&
                         csr_ready &&
                         csr_unit_write;
    assign csr_wdata_o = csr_unit_wdata;

    assign clear_o = ex_ready;
    assign alu_ready_o = ex_mem_in_clear && alu_m_ready && !serializing_q;
    assign lsu_ready_o = ex_mem_in_clear && !serializing_q;
    assign br_ready_o = ex_mem_in_clear && !serializing_q;
    assign system_ready_o = ex_mem_in_clear && serial_issue_ready;
    assign alu_m_result_ready = ex_m_selected &&
                                alu_m_issued_q &&
                                alu_m_result_valid &&
                                ex_mem_in_clear &&
                                !serializing_q;
    assign ex_mem_in_valid = valid_i && ex_ready;
    assign forward_ex_valid_o = ENABLE_FORWARDING &&
                                ex_mem_in_valid &&
                                reg_write_i &&
                                !mem_write_i &&
                                (ENABLE_LOAD_FORWARDING || !mem_read_i) &&
                                !ex_illegal;
    assign forward_ex_rd_addr_o = rd_addr_i;
    // Advertise only values that the operand mux can actually select. A load
    // with response bypass disabled remains an owner, but not a forwarder.
    assign forward_mem_valid_o = mem_bypass_valid;
    assign forward_mem_rd_addr_o = ex_mem_rd_addr;
    assign ex_mem_in_data = {
        trace_id_i,
        pc_i,
        ex_next_pc,
        instr_i,
        ex_wb_data,
        forwarded_rs1_data,
        imm_i,
        forwarded_rs2_data,
        rs1_addr_i,
        rs2_addr_i,
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
        ecall_i,
        ex_instr_misaligned,
        ex_instr_badaddr,
        ex_mret,
        ex_sret,
        priv_mode_i,
        instr_access_fault_i,
        instr_page_fault_i
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alu_m_issued_q <= 1'b0;
        end else if (flush_ex_mem_i) begin
            alu_m_issued_q <= 1'b0;
        end else if (alu_m_result_ready) begin
            alu_m_issued_q <= 1'b0;
        end else if (!ex_m_selected) begin
            alu_m_issued_q <= 1'b0;
        end else if (alu_m_start) begin
            alu_m_issued_q <= 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            serializing_q <= 1'b0;
        end else if (flush_ex_mem_i) begin
            serializing_q <= 1'b0;
        end else if (serial_issue) begin
            serializing_q <= 1'b1;
        end else if (serializing_q && wb_valid_o && wb_clear_i) begin
            serializing_q <= 1'b0;
        end
    end

    assign {
        ex_mem_trace_id,
        ex_mem_pc,
        ex_mem_next_pc,
        ex_mem_instr,
        ex_mem_wb_data,
        ex_mem_lsu_base,
        ex_mem_lsu_offset,
        ex_mem_lsu_store_data,
        ex_mem_rs1_addr,
        ex_mem_rs2_addr,
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
        ex_mem_ecall,
        ex_mem_instr_misaligned,
        ex_mem_instr_badaddr,
        ex_mem_mret,
        ex_mem_sret,
        ex_mem_priv_mode,
        ex_mem_instr_access_fault,
        ex_mem_instr_page_fault
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

    openrv64_exec_lsu_rv64a u_lsu_atomic_exec (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_ex_mem_i),
        .valid_i(atomic_mem_access),
        .consume_i(ex_mem_out_clear && ex_mem_is_atomic),
        .clear_reservation_i(clear_atomic_reservation),
        .op_sel_i(ex_mem_lsu_op),
        .size_sel_i(lsu_access_size[`RV64_LSU_SIZE_WIDTH-1:0]),
        .addr_i(lsu_badaddr),
        .store_data_i(ex_mem_lsu_store_data),
        .mem_ready_i(mem_ready_i),
        .mem_error_i(mem_error_i),
        .mem_page_fault_i(mem_page_fault_i),
        .mem_access_allowed_i(mem_access_allowed_i),
        .mem_rdata_i(mem_rdata_i),
        .complete_o(atomic_complete),
        .illegal_o(atomic_illegal),
        .misaligned_o(atomic_misaligned),
        .access_fault_o(atomic_access_fault),
        .page_fault_o(atomic_page_fault),
        .result_o(atomic_result),
        .mem_valid_o(atomic_mem_valid),
        .mem_lock_o(atomic_mem_lock),
        .mem_write_o(atomic_mem_write),
        .mem_addr_o(atomic_mem_addr),
        .mem_wdata_o(atomic_mem_wdata),
        .mem_wstrb_o(atomic_mem_wstrb)
    );

    openrv64_except u_except (
        .illegal_instr_i(ex_mem_illegal),
        .instr_misaligned_i(ex_mem_instr_misaligned),
        .instr_access_fault_i(ex_mem_instr_access_fault),
        .instr_page_fault_i(ex_mem_instr_page_fault),
        .load_misaligned_i(load_misaligned),
        .load_access_fault_i(load_access_fault),
        .load_page_fault_i(load_page_fault),
        .store_misaligned_i(store_misaligned),
        .store_access_fault_i(store_access_fault),
        .store_page_fault_i(store_page_fault),
        .ecall_i(ex_mem_ecall),
        .ebreak_i(ex_mem_ebreak),
        .priv_mode_i(ex_mem_priv_mode),
        .pc_i(ex_mem_instr_misaligned ? ex_mem_instr_badaddr : ex_mem_pc),
        .instr_i(ex_mem_instr),
        .badaddr_i(lsu_badaddr),
        .exception_o(exception_valid),
        .halt_o(exception_halt),
        .cause_o(exception_cause),
        .tval_o(exception_tval)
    );

    assign mem_valid_o = ex_mem_is_atomic ? atomic_mem_valid : lsu_mem_valid;
    assign mem_lock_o = ex_mem_is_atomic ? atomic_mem_lock : 1'b0;
    assign mem_write_o = ex_mem_is_atomic ? atomic_mem_write : lsu_mem_write;
    assign mem_addr_o = ex_mem_is_atomic ? atomic_mem_addr : lsu_mem_addr;
    assign mem_wdata_o = ex_mem_is_atomic ? atomic_mem_wdata : lsu_mem_wdata;
    assign mem_wstrb_o = ex_mem_is_atomic ? atomic_mem_wstrb : lsu_mem_wstrb;
    assign mem_access_o = ex_mem_is_atomic ? atomic_mem_valid :
        (lsu_mem_access && lsu_valid && !lsu_misaligned);
    assign mem_effective_addr_o = lsu_badaddr;
    assign mem_size_o = lsu_access_size;

    wire memory_complete = ex_mem_is_atomic ? atomic_complete : lsu_complete;
    wire [`RV64_XLEN-1:0] memory_result = ex_mem_is_atomic ? atomic_result :
        (ex_mem_mem_read ? lsu_load_data : ex_mem_wb_data);

    assign ex_mem_out_clear = mem_wb_in_clear && memory_complete;
    assign mem_wb_in_valid = ex_mem_out_valid && memory_complete;
    assign mem_wb_in_data = {
        ex_mem_trace_id,
        ex_mem_pc,
        ex_mem_next_pc,
        ex_mem_instr,
        memory_result,
        ex_mem_rs1_addr,
        ex_mem_rs2_addr,
        ex_mem_rd_addr,
        ex_mem_reg_write && (!ex_mem_mem_write || ex_mem_is_atomic),
        ex_mem_illegal ||
            (lsu_mem_access && lsu_illegal) ||
            (atomic_mem_access && atomic_illegal),
        ex_mem_ebreak,
        ex_mem_ecall,
        exception_valid,
        exception_halt,
        exception_cause,
        exception_tval,
        ex_mem_mret,
        ex_mem_sret
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
        trace_wb_id_o,
        wb_pc_o,
        wb_next_pc_o,
        wb_instr_o,
        wb_data_o,
        wb_rs1_addr_o,
        wb_rs2_addr_o,
        wb_rd_addr_o,
        wb_reg_write_o,
        wb_illegal_o,
        wb_ebreak_o,
        wb_ecall_o,
        wb_exception_o,
        wb_halt_o,
        wb_cause_o,
        wb_tval_o,
        wb_mret_o,
        wb_sret_o
    } = mem_wb_out_data;

    assign trace_ex_advance_o = ex_mem_in_valid;
    assign trace_mem_valid_o = ex_mem_out_valid;
    assign trace_mem_clear_o = ex_mem_out_clear;
    assign trace_mem_id_o = ex_mem_trace_id;
    assign trace_mem_pc_o = ex_mem_pc;
    assign trace_mem_instr_o = ex_mem_instr;
    assign trace_serializing_o = serializing_q ||
                                 (valid_i && ex_requires_drain &&
                                  !serial_issue_ready);

endmodule
