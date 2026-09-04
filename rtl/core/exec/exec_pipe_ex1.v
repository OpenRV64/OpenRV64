`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/except/except-defs.v"

// EX1 owns base integer ALU operations and all control/system operations.
// Its completion register decouples single-cycle execution from a stalled
// retire queue completion port.
module openrv64_exec_pipe_ex1 #(
    parameter integer RETIRE_SLOT_WIDTH = 3,
    parameter integer PRODUCER_TAG_WIDTH = `OPENRV64_INSTR_ID_WIDTH,
    parameter integer ENABLE_LOCAL_FORWARDING = 1
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire                         issue_valid_i,
    output wire                         issue_ready_o,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] issue_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] issue_slot_i,
    input  wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] issue_payload_i,
    input  wire [1:0]                   chain_mask_i,
    input  wire                         branch_forward_valid_i,
    input  wire [PRODUCER_TAG_WIDTH-1:0] branch_forward_tag_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0]
                                        branch_forward_rd_addr_i,
    input  wire [`RV64_XLEN-1:0]        branch_forward_data_i,
    input  wire                         src1_producer_valid_i,
    input  wire [PRODUCER_TAG_WIDTH-1:0] src1_producer_tag_i,
    input  wire                         src2_producer_valid_i,
    input  wire [PRODUCER_TAG_WIDTH-1:0] src2_producer_tag_i,

    output wire                         complete_valid_o,
    input  wire                         complete_ready_i,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] complete_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0] complete_slot_o,
    output wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] complete_payload_o,

    output wire [`RV64_FUNCT12_WIDTH-1:0] csr_addr_o,
    input  wire [`RV64_XLEN-1:0]        csr_rdata_i,
    input  wire                         csr_valid_i,
    input  wire                         csr_writable_i,

    output wire                         branch_resolved_o,
    output wire                         branch_conditional_o,
    output wire                         branch_taken_o,
    output wire [`RV64_XLEN-1:0]        branch_pc_o,
    output wire [`RV64_INSTR_WIDTH-1:0] branch_instr_o,
    output wire                         redirect_valid_o,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] redirect_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0] redirect_slot_o,
    output wire [`RV64_XLEN-1:0]        redirect_target_o
);

    wire [63:0] trace_id;
    wire [`RV64_XLEN-1:0] pc;
    wire [`RV64_INSTR_WIDTH-1:0] instr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr;
    wire [`RV64_XLEN-1:0] rs1_data;
    wire [`RV64_XLEN-1:0] rs2_data;
    wire [`RV64_XLEN-1:0] imm;
    wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr;
    wire [`RV64_ALU_EXT_WIDTH-1:0] alu_ext;
    wire [`RV64_ALU_OP_WIDTH-1:0] alu_op;
    wire [`RV64_LSU_OP_WIDTH-1:0] lsu_op;
    wire [`RV64_BR_OP_WIDTH-1:0] br_op;
    wire reg_write;
    wire mem_read;
    wire mem_write;
    wire branch;
    wire jump;
    wire predicted_taken;
    wire word_op;
    wire system;
    wire fence;
    wire illegal;
    wire ebreak;
    wire ecall;
    wire instr_access_fault;
    wire instr_page_fault;
    wire [`RV64_PRIV_WIDTH-1:0] priv_mode;
    wire sret_allowed;
    wire sfence_vma_allowed;

    reg complete_valid_q;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] complete_id_q;
    reg [RETIRE_SLOT_WIDTH-1:0] complete_slot_q;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] complete_payload_q;
    reg hpm_pending_q;
    reg [1:0] hpm_count_q;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] hpm_id_q;
    reg [RETIRE_SLOT_WIDTH-1:0] hpm_slot_q;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] hpm_payload_q;

    assign {
        trace_id,
        pc,
        instr,
        rs1_addr,
        rs2_addr,
        rs1_data,
        rs2_data,
        imm,
        rd_addr,
        alu_ext,
        alu_op,
        lsu_op,
        br_op,
        reg_write,
        mem_read,
        mem_write,
        branch,
        jump,
        predicted_taken,
        word_op,
        system,
        fence,
        illegal,
        ebreak,
        ecall,
        instr_access_fault,
        instr_page_fault,
        priv_mode,
        sret_allowed,
        sfence_vma_allowed
    } = issue_payload_i;

    // The only result bypass in this first 3P implementation is local: an
    // instruction entering EX1 may consume EX1's completion from the previous
    // cycle.  No 64-bit result leaves the pipe or crosses to another pipe.
    wire retained_result_valid =
        complete_valid_q &&
        complete_payload_q[`OPENRV64_COMPLETE_REG_WRITE_BIT] &&
        !complete_payload_q[`OPENRV64_COMPLETE_ILLEGAL_BIT] &&
        !complete_payload_q[`OPENRV64_COMPLETE_EXCEPTION_BIT] &&
        (complete_payload_q[`OPENRV64_COMPLETE_RD_LSB +:
                            `RV64_REG_ADDR_WIDTH] != `RV64_REG_X0);
    wire local_forward_valid = (ENABLE_LOCAL_FORWARDING != 0) &&
        retained_result_valid;
    wire [`RV64_REG_ADDR_WIDTH-1:0] local_forward_rd =
        complete_payload_q[`OPENRV64_COMPLETE_RD_LSB +:
                           `RV64_REG_ADDR_WIDTH];
    wire [`RV64_XLEN-1:0] local_forward_data =
        complete_payload_q[`OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
    wire chain_rs1_match = chain_mask_i[0] && retained_result_valid &&
        src1_producer_valid_i &&
        (src1_producer_tag_i == complete_id_q);
    wire chain_rs2_match = chain_mask_i[1] && retained_result_valid &&
        src2_producer_valid_i &&
        (src2_producer_tag_i == complete_id_q);
    wire chain_sources_ready =
        (!chain_mask_i[0] || chain_rs1_match) &&
        (!chain_mask_i[1] || chain_rs2_match);
    // Architectural rd identifies a value's destination, not which dynamic
    // producer a branch consumes.  A younger WAW may complete before an older
    // branch in the issue-window backend, so cross-pipe forwarding must match
    // the producer tag captured with that specific source operand.  Dispatch
    // may use a global ID or a bounded retirement-slot dependency tag.
    wire branch_forward_rs1 = branch && branch_forward_valid_i &&
        src1_producer_valid_i &&
        (src1_producer_tag_i == branch_forward_tag_i) &&
        (rs1_addr == branch_forward_rd_addr_i);
    wire branch_forward_rs2 = branch && branch_forward_valid_i &&
        src2_producer_valid_i &&
        (src2_producer_tag_i == branch_forward_tag_i) &&
        (rs2_addr == branch_forward_rd_addr_i);
    wire [`RV64_XLEN-1:0] operand_rs1 = chain_rs1_match ?
        local_forward_data : branch_forward_rs1 ?
        branch_forward_data_i :
        (local_forward_valid && (rs1_addr == local_forward_rd) ?
         local_forward_data : rs1_data);
    wire [`RV64_XLEN-1:0] operand_rs2 = chain_rs2_match ?
        local_forward_data : branch_forward_rs2 ?
        branch_forward_data_i :
        (local_forward_valid && (rs2_addr == local_forward_rd) ?
         local_forward_data : rs2_data);

    wire [`RV64_OPCODE_WIDTH-1:0] opcode = `RV64_OPCODE(instr);
    wire alu_uses_imm = (opcode == `RV64_OPCODE_LUI) ||
                        (opcode == `RV64_OPCODE_AUIPC) ||
                        (opcode == `RV64_OPCODE_OP_IMM) ||
                        (opcode == `RV64_OPCODE_OP_IMM_32);
    wire [`RV64_XLEN-1:0] alu_src1 = (opcode == `RV64_OPCODE_LUI) ?
                                     {`RV64_XLEN{1'b0}} : operand_rs1;
    wire [`RV64_XLEN-1:0] alu_src2 = alu_uses_imm ? imm : operand_rs2;

    wire alu_valid;
    wire alu_illegal;
    wire [`RV64_XLEN-1:0] alu_result;
    openrv64_exec_alu_rv64i u_alu (
        .op_sel_i(alu_op),
        .word_op_i(word_op),
        .src1_i(alu_src1),
        .src2_i(alu_src2),
        .pc_i(pc),
        .valid_o(alu_valid),
        .illegal_o(alu_illegal),
        .result_o(alu_result)
    );

    wire br_valid;
    wire br_illegal;
    wire br_taken;
    wire [`RV64_XLEN-1:0] br_target;
    wire br_link;
    wire [`RV64_XLEN-1:0] br_link_data;
    openrv64_exec_br u_branch (
        .op_sel_i(br_op),
        .pc_i(pc),
        .src1_i(operand_rs1),
        .src2_i(operand_rs2),
        .imm_i(imm),
        .valid_o(br_valid),
        .illegal_o(br_illegal),
        .taken_o(br_taken),
        .target_o(br_target),
        .link_o(br_link),
        .link_data_o(br_link_data)
    );

    wire [`RV64_FUNCT3_WIDTH-1:0] system_funct3 = `RV64_FUNCT3(instr);
    wire [`RV64_FUNCT12_WIDTH-1:0] system_csr_addr = `RV64_CSR(instr);
    wire csr_selected = system &&
                        (system_funct3 != `RV64_FUNCT3_SYSTEM_PRIV) &&
                        !illegal;
    wire csr_hpm_selected = csr_selected && (
        (system_csr_addr == `RV64_CSR_SCOUNTEREN) ||
        (system_csr_addr == `RV64_CSR_MCOUNTEREN) ||
        (system_csr_addr == `RV64_CSR_MCOUNTINHIBIT) ||
        (system_csr_addr == `RV64_CSR_MCYCLE) ||
        (system_csr_addr == `RV64_CSR_MINSTRET) ||
        (system_csr_addr == `RV64_CSR_CYCLE) ||
        (system_csr_addr == `RV64_CSR_TIME) ||
        (system_csr_addr == `RV64_CSR_INSTRET) ||
        ((system_csr_addr >= `RV64_CSR_MHPMCOUNTER3) &&
         (system_csr_addr <= `RV64_CSR_MHPMCOUNTER31)) ||
        ((system_csr_addr >= `RV64_CSR_MHPMEVENT3) &&
         (system_csr_addr <= `RV64_CSR_MHPMEVENT31)) ||
        ((system_csr_addr >= `RV64_CSR_HPMCOUNTER3) &&
         (system_csr_addr <= `RV64_CSR_HPMCOUNTER31)));
    wire csr_ready;
    wire csr_illegal;
    wire csr_write;
    wire [`RV64_FUNCT12_WIDTH-1:0] csr_unit_addr;
    wire [`RV64_XLEN-1:0] csr_wdata;
    wire [`RV64_XLEN-1:0] csr_rdata;
    openrv64_exec_system_csr u_csr (
        .valid_i(issue_valid_i && csr_selected),
        .funct3_i(system_funct3),
        .csr_addr_i(system_csr_addr),
        .rs1_addr_i(rs1_addr),
        .rs1_data_i(operand_rs1),
        .zimm_i(`RV64_RS1(instr)),
        .csr_rdata_i(csr_rdata_i),
        .csr_valid_i(csr_valid_i),
        .csr_writable_i(csr_writable_i),
        .ready_o(csr_ready),
        .illegal_o(csr_illegal),
        .csr_write_o(csr_write),
        .csr_addr_o(csr_unit_addr),
        .csr_wdata_o(csr_wdata),
        .rd_data_o(csr_rdata)
    );

    wire ex_mret = system && (instr == `RV64_INSTR_MRET);
    wire ex_sret = system && (instr == `RV64_INSTR_SRET);
    wire ex_sfence_vma = system && `RV64_IS_SFENCE_VMA(instr);
    wire return_illegal =
        (ex_mret && (priv_mode != `RV64_PRIV_M)) ||
        (ex_sret && !sret_allowed) ||
        (ex_sfence_vma && !sfence_vma_allowed);

    wire alu_selected = (alu_ext == `RV64_ALU_EXT_BASE) &&
                         (alu_op != `RV64_ALU_OP_INVALID);
    wire br_selected = branch || jump;
    wire target_misaligned = br_selected && br_valid && br_taken &&
                             (|br_target[1:0]);
    wire instr_misaligned = (|pc[1:0]) || target_misaligned;
    wire [`RV64_XLEN-1:0] instr_badaddr = target_misaligned ? br_target : pc;
    wire result_illegal = illegal ||
                          (alu_selected && (!alu_valid || alu_illegal)) ||
                          (br_selected && (!br_valid || br_illegal)) ||
                          (csr_selected && (!csr_ready || csr_illegal)) ||
                          return_illegal;

    wire control_transfer_taken = br_selected && br_valid && br_taken &&
                                  !instr_misaligned && !result_illegal;
    wire [`RV64_XLEN-1:0] next_pc = control_transfer_taken ?
                                     br_target : (pc + 64'd4);
    wire [`RV64_XLEN-1:0] result_data = csr_selected ? csr_rdata :
                                          br_link ? br_link_data : alu_result;

    wire exception;
    wire halt;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] cause;
    wire [`RV64_XLEN-1:0] tval;
    openrv64_except u_except (
        .illegal_instr_i(result_illegal),
        .instr_misaligned_i(instr_misaligned),
        .instr_access_fault_i(instr_access_fault),
        .instr_page_fault_i(instr_page_fault),
        .load_misaligned_i(1'b0),
        .load_access_fault_i(1'b0),
        .load_page_fault_i(1'b0),
        .store_misaligned_i(1'b0),
        .store_access_fault_i(1'b0),
        .store_page_fault_i(1'b0),
        .ecall_i(ecall),
        .ebreak_i(ebreak),
        .priv_mode_i(priv_mode),
        .pc_i(instr_misaligned ? instr_badaddr : pc),
        .instr_i(instr),
        .badaddr_i({`RV64_XLEN{1'b0}}),
        .exception_o(exception),
        .halt_o(halt),
        .cause_o(cause),
        .tval_o(tval)
    );

    wire issue_fire = issue_valid_i && issue_ready_o;
    wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] completion_data = {
        trace_id,
        pc,
        next_pc,
        instr,
        result_data,
        rs1_addr,
        rs2_addr,
        rd_addr,
        reg_write,
        result_illegal,
        ebreak,
        ecall,
        exception,
        halt,
        cause,
        tval,
        ex_mret,
        ex_sret,
        csr_selected && csr_write && !exception,
        csr_unit_addr,
        csr_wdata
    };

    assign issue_ready_o = chain_sources_ready &&
        (!complete_valid_q || complete_ready_i) && !hpm_pending_q;

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && !flush_i && issue_valid_i && (|chain_mask_i)) begin
            if (csr_selected ||
                ((!alu_selected) && (!br_selected)) ||
                (alu_selected && br_selected))
                $fatal(1, "EX1 chain requested for unsupported operation id=%0d",
                       issue_id_i);
            if (!chain_sources_ready)
                $fatal(1,
                       "EX1 chain producer mismatch consumer=%0d retained=%0d mask=%b",
                       issue_id_i, complete_id_q, chain_mask_i);
        end
    end
`endif

    assign complete_valid_o = complete_valid_q;
    assign complete_id_o = complete_id_q;
    assign complete_slot_o = complete_slot_q;
    assign complete_payload_o = complete_payload_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            complete_valid_q <= 1'b0;
            complete_id_q <= {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            complete_slot_q <= {RETIRE_SLOT_WIDTH{1'b0}};
            complete_payload_q <=
                {`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH{1'b0}};
            hpm_pending_q <= 1'b0;
            hpm_count_q <= 2'd0;
            hpm_id_q <= {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            hpm_slot_q <= {RETIRE_SLOT_WIDTH{1'b0}};
            hpm_payload_q <=
                {`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH{1'b0}};
        end else if (flush_i) begin
            complete_valid_q <= 1'b0;
            hpm_pending_q <= 1'b0;
        end else begin
            if (complete_valid_q && complete_ready_i) begin
                complete_valid_q <= 1'b0;
            end

            if (hpm_pending_q) begin
                if (hpm_count_q == 2'd2) begin
                    complete_valid_q <= 1'b1;
                    complete_id_q <= hpm_id_q;
                    complete_slot_q <= hpm_slot_q;
                    complete_payload_q <= hpm_payload_q;
                    hpm_pending_q <= 1'b0;
                end else begin
                    hpm_count_q <= hpm_count_q + 1'b1;
                end
            end

            if (issue_fire && csr_hpm_selected) begin
                hpm_pending_q <= 1'b1;
                hpm_count_q <= 2'd0;
                hpm_id_q <= issue_id_i;
                hpm_slot_q <= issue_slot_i;
                hpm_payload_q <= completion_data;
            end else if (issue_fire) begin
                complete_valid_q <= 1'b1;
                complete_id_q <= issue_id_i;
                complete_slot_q <= issue_slot_i;
                complete_payload_q <= completion_data;
            end
        end
    end

    assign csr_addr_o = csr_unit_addr;
    assign branch_resolved_o = issue_fire && br_selected;
    assign branch_conditional_o = branch_resolved_o && branch;
    assign branch_taken_o = branch_resolved_o && control_transfer_taken;
    assign branch_pc_o = pc;
    assign branch_instr_o = instr;
    assign redirect_valid_o = branch_resolved_o &&
                              !instr_misaligned &&
                              !result_illegal &&
                              (predicted_taken != control_transfer_taken);
    assign redirect_id_o = issue_id_i;
    assign redirect_slot_o = issue_slot_i;
    assign redirect_target_o = control_transfer_taken ?
                               br_target : (pc + 64'd4);

    wire unused_controls = |{lsu_op, mem_read, mem_write, fence};

endmodule
