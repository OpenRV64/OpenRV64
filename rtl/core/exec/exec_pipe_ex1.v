`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/except/except-defs.v"

// EX1 owns a second base integer ALU and the single iterative RV64M worker.
// Only the M worker needs instruction context storage; base operations write
// the completion register directly on issue.
module openrv64_exec_pipe_ex1 #(
    parameter integer RETIRE_SLOT_WIDTH = 3,
    parameter integer ENABLE_RV64M = 1,
    parameter integer ENABLE_LOCAL_FORWARDING = 1
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire                         issue_valid_i,
    output wire                         issue_ready_o,
    input  wire [63:0]                  issue_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] issue_slot_i,
    input  wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] issue_payload_i,

    output wire                         complete_valid_o,
    input  wire                         complete_ready_i,
    output wire [63:0]                  complete_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0] complete_slot_o,
    output wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] complete_payload_o
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
    reg [63:0] complete_id_q;
    reg [RETIRE_SLOT_WIDTH-1:0] complete_slot_q;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] complete_payload_q;

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

    // EX1 has the same deliberately local previous-completion bypass as EX0.
    // Dispatch is responsible for routing a qualified consumer back here.
    wire local_forward_valid = (ENABLE_LOCAL_FORWARDING != 0) &&
        complete_valid_q &&
        complete_payload_q[`OPENRV64_COMPLETE_REG_WRITE_BIT] &&
        !complete_payload_q[`OPENRV64_COMPLETE_ILLEGAL_BIT] &&
        !complete_payload_q[`OPENRV64_COMPLETE_EXCEPTION_BIT] &&
        (complete_payload_q[`OPENRV64_COMPLETE_RD_LSB +:
                            `RV64_REG_ADDR_WIDTH] != `RV64_REG_X0);
    wire [`RV64_REG_ADDR_WIDTH-1:0] local_forward_rd =
        complete_payload_q[`OPENRV64_COMPLETE_RD_LSB +:
                           `RV64_REG_ADDR_WIDTH];
    wire [`RV64_XLEN-1:0] local_forward_data =
        complete_payload_q[`OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] operand_rs1 =
        local_forward_valid && (rs1_addr == local_forward_rd) ?
        local_forward_data : rs1_data;
    wire [`RV64_XLEN-1:0] operand_rs2 =
        local_forward_valid && (rs2_addr == local_forward_rd) ?
        local_forward_data : rs2_data;

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

    wire m_ready;
    wire m_busy;
    wire m_result_valid;
    wire m_result_ready;
    wire m_illegal;
    wire [`RV64_XLEN-1:0] m_result;
    wire m_start;
    openrv64_exec_rv64m u_rv64m (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i),
        .valid_i(m_start),
        .ready_o(m_ready),
        .busy_o(m_busy),
        .op_sel_i(alu_op),
        .word_op_i(word_op),
        .src1_i(operand_rs1),
        .src2_i(operand_rs2),
        .result_valid_o(m_result_valid),
        .result_ready_i(m_result_ready),
        .illegal_o(m_illegal),
        .result_o(m_result)
    );

    wire base_selected = (alu_ext == `RV64_ALU_EXT_BASE) &&
                          (alu_op != `RV64_ALU_OP_INVALID);
    wire m_selected = (alu_ext == `RV64_ALU_EXT_M) &&
                       (alu_op != `RV64_ALU_OP_INVALID);
    wire base_result_illegal = illegal || !alu_valid || alu_illegal;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] base_cause =
        base_result_illegal ? `RV64_EXCEPT_CAUSE_ILLEGAL_INSTR :
                              {`RV64_EXCEPT_CAUSE_WIDTH{1'b0}};
    wire [`RV64_XLEN-1:0] base_tval = base_result_illegal ?
        {{32{1'b0}}, instr} : {`RV64_XLEN{1'b0}};
    wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] base_completion_data = {
        trace_id,
        pc,
        pc + 64'd4,
        instr,
        alu_result,
        rs1_addr,
        rs2_addr,
        rd_addr,
        reg_write,
        base_result_illegal,
        1'b0,
        1'b0,
        base_result_illegal,
        1'b0,
        base_cause,
        base_tval,
        1'b0,
        1'b0,
        1'b0,
        {`RV64_FUNCT12_WIDTH{1'b0}},
        {`RV64_XLEN{1'b0}}
    };

    reg m_pending_q;
    reg [63:0] m_id_q;
    reg [RETIRE_SLOT_WIDTH-1:0] m_slot_q;
    reg [63:0] m_trace_id_q;
    reg [`RV64_XLEN-1:0] m_pc_q;
    reg [`RV64_INSTR_WIDTH-1:0] m_instr_q;
    reg [`RV64_REG_ADDR_WIDTH-1:0] m_rs1_addr_q;
    reg [`RV64_REG_ADDR_WIDTH-1:0] m_rs2_addr_q;
    reg [`RV64_REG_ADDR_WIDTH-1:0] m_rd_addr_q;
    reg m_reg_write_q;

    wire m_result_illegal = m_illegal;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] m_cause =
        m_result_illegal ? `RV64_EXCEPT_CAUSE_ILLEGAL_INSTR :
                           {`RV64_EXCEPT_CAUSE_WIDTH{1'b0}};
    wire [`RV64_XLEN-1:0] m_tval = m_result_illegal ?
        {{32{1'b0}}, m_instr_q} : {`RV64_XLEN{1'b0}};
    wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] m_completion_data = {
        m_trace_id_q,
        m_pc_q,
        m_pc_q + 64'd4,
        m_instr_q,
        m_result,
        m_rs1_addr_q,
        m_rs2_addr_q,
        m_rd_addr_q,
        m_reg_write_q,
        m_result_illegal,
        1'b0,
        1'b0,
        m_result_illegal,
        1'b0,
        m_cause,
        m_tval,
        1'b0,
        1'b0,
        1'b0,
        {`RV64_FUNCT12_WIDTH{1'b0}},
        {`RV64_XLEN{1'b0}}
    };

    wire output_available = !complete_valid_q || complete_ready_i;
    assign issue_ready_o = !m_pending_q && output_available &&
                           (base_selected ||
                            (m_selected && ENABLE_RV64M && m_ready));
    wire issue_fire = issue_valid_i && issue_ready_o;
    wire base_fire = issue_fire && base_selected;
    assign m_start = issue_fire && m_selected && ENABLE_RV64M;
    assign m_result_ready = m_pending_q && m_result_valid && output_available;

    assign complete_valid_o = complete_valid_q;
    assign complete_id_o = complete_id_q;
    assign complete_slot_o = complete_slot_q;
    assign complete_payload_o = complete_payload_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_pending_q <= 1'b0;
            m_id_q <= 64'd0;
            m_slot_q <= {RETIRE_SLOT_WIDTH{1'b0}};
            m_trace_id_q <= 64'd0;
            m_pc_q <= {`RV64_XLEN{1'b0}};
            m_instr_q <= {`RV64_INSTR_WIDTH{1'b0}};
            m_rs1_addr_q <= {`RV64_REG_ADDR_WIDTH{1'b0}};
            m_rs2_addr_q <= {`RV64_REG_ADDR_WIDTH{1'b0}};
            m_rd_addr_q <= {`RV64_REG_ADDR_WIDTH{1'b0}};
            m_reg_write_q <= 1'b0;
            complete_valid_q <= 1'b0;
            complete_id_q <= 64'd0;
            complete_slot_q <= {RETIRE_SLOT_WIDTH{1'b0}};
            complete_payload_q <=
                {`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH{1'b0}};
        end else if (flush_i) begin
            m_pending_q <= 1'b0;
            complete_valid_q <= 1'b0;
        end else begin
            if (complete_valid_q && complete_ready_i) begin
                complete_valid_q <= 1'b0;
            end

            if (m_start) begin
                m_pending_q <= 1'b1;
                m_id_q <= issue_id_i;
                m_slot_q <= issue_slot_i;
                m_trace_id_q <= trace_id;
                m_pc_q <= pc;
                m_instr_q <= instr;
                m_rs1_addr_q <= rs1_addr;
                m_rs2_addr_q <= rs2_addr;
                m_rd_addr_q <= rd_addr;
                m_reg_write_q <= reg_write;
            end

            if (m_result_ready) begin
                m_pending_q <= 1'b0;
                complete_valid_q <= 1'b1;
                complete_id_q <= m_id_q;
                complete_slot_q <= m_slot_q;
                complete_payload_q <= m_completion_data;
            end else if (base_fire) begin
                complete_valid_q <= 1'b1;
                complete_id_q <= issue_id_i;
                complete_slot_q <= issue_slot_i;
                complete_payload_q <= base_completion_data;
            end
        end
    end

    wire unused_controls = |{
        lsu_op,
        br_op,
        mem_read,
        mem_write,
        branch,
        jump,
        predicted_taken,
        system,
        fence,
        ebreak,
        ecall,
        instr_access_fault,
        instr_page_fault,
        priv_mode,
        sret_allowed,
        sfence_vma_allowed,
        m_busy
    };

endmodule
