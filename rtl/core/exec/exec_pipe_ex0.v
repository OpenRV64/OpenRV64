`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/except/except-defs.v"

// EX0 owns a base integer ALU, the iterative RV64M/Zbb context, and a pipelined
// Zbb rotate datapath.  Base and rotate operations may overlap; iterative
// operations wait until the rotate pipeline is empty.
module openrv64_exec_pipe_ex0 #(
    parameter integer RETIRE_SLOT_WIDTH = 3,
    parameter integer ENABLE_RV64M = 1,
    parameter integer ENABLE_RV64ZBB = 1,
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

    output wire                         complete_valid_o,
    input  wire                         complete_ready_i,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] complete_id_o,
    output wire [RETIRE_SLOT_WIDTH-1:0] complete_slot_o,
    output wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] complete_payload_o
);

    localparam integer ROTATE_TAG_WIDTH =
        `OPENRV64_INSTR_ID_WIDTH + RETIRE_SLOT_WIDTH + 64 +
        `RV64_XLEN + `RV64_INSTR_WIDTH +
        3*`RV64_REG_ADDR_WIDTH + 1;

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

    // EX0 has a deliberately local previous-completion bypass.
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

    wire zbb_alu_request;
    wire [`RV64_ALU_OP_WIDTH-1:0] zbb_alu_op;
    wire zbb_alu_word;
    wire [`RV64_XLEN-1:0] zbb_alu_src1;
    wire [`RV64_XLEN-1:0] zbb_alu_src2;
    wire [`RV64_ALU_OP_WIDTH-1:0] shared_alu_op =
        zbb_alu_request ? zbb_alu_op : alu_op;
    wire shared_alu_word = zbb_alu_request ? zbb_alu_word : word_op;
    wire [`RV64_XLEN-1:0] shared_alu_src1 =
        zbb_alu_request ? zbb_alu_src1 : alu_src1;
    wire [`RV64_XLEN-1:0] shared_alu_src2 =
        zbb_alu_request ? zbb_alu_src2 : alu_src2;

    wire alu_valid;
    wire alu_illegal;
    wire [`RV64_XLEN-1:0] alu_result;
    openrv64_exec_alu_rv64i u_alu (
        .op_sel_i(shared_alu_op),
        .word_op_i(shared_alu_word),
        .src1_i(shared_alu_src1),
        .src2_i(shared_alu_src2),
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

    wire zbb_ready;
    wire zbb_busy;
    wire zbb_result_valid;
    wire zbb_result_ready;
    wire zbb_illegal;
    wire [`RV64_XLEN-1:0] zbb_result;
    wire zbb_start;
    wire rotate_ready;
    wire rotate_busy;
    wire rotate_result_valid;
    wire rotate_result_ready;
    wire [`RV64_XLEN-1:0] rotate_result;
    wire [ROTATE_TAG_WIDTH-1:0] rotate_result_tag;
    wire [ROTATE_TAG_WIDTH-1:0] rotate_input_tag = {
        issue_id_i,
        issue_slot_i,
        trace_id,
        pc,
        instr,
        rs1_addr,
        rs2_addr,
        rd_addr,
        reg_write
    };
    wire rotate_start;
    generate
        if (ENABLE_RV64ZBB != 0) begin : g_zbb
            openrv64_exec_ext_zbb u_zbb (
                .clk(clk),
                .rst_n(rst_n),
                .flush_i(flush_i),
                .valid_i(zbb_start),
                .ready_o(zbb_ready),
                .busy_o(zbb_busy),
                .op_sel_i(alu_op),
                .word_op_i(word_op),
                .src1_i(operand_rs1),
                .src2_i(alu_src2),
                .alu_request_o(zbb_alu_request),
                .alu_op_o(zbb_alu_op),
                .alu_word_o(zbb_alu_word),
                .alu_src1_o(zbb_alu_src1),
                .alu_src2_o(zbb_alu_src2),
                .alu_valid_i(alu_valid),
                .alu_result_i(alu_result),
                .result_valid_o(zbb_result_valid),
                .result_ready_i(zbb_result_ready),
                .illegal_o(zbb_illegal),
                .result_o(zbb_result)
            );

            openrv64_exec_zbb_rotate #(
                .TAG_WIDTH(ROTATE_TAG_WIDTH)
            ) u_zbb_rotate (
                .clk(clk),
                .rst_n(rst_n),
                .flush_i(flush_i),
                .valid_i(rotate_start),
                .ready_o(rotate_ready),
                .op_sel_i(alu_op),
                .word_op_i(word_op),
                .src_i(operand_rs1),
                .amount_i(alu_src2),
                .tag_i(rotate_input_tag),
                .busy_o(rotate_busy),
                .result_valid_o(rotate_result_valid),
                .result_ready_i(rotate_result_ready),
                .result_o(rotate_result),
                .result_tag_o(rotate_result_tag)
            );
        end else begin : g_no_zbb
            assign zbb_ready = 1'b0;
            assign zbb_busy = 1'b0;
            assign zbb_result_valid = 1'b0;
            assign zbb_illegal = 1'b0;
            assign zbb_result = {`RV64_XLEN{1'b0}};
            assign zbb_alu_request = 1'b0;
            assign zbb_alu_op = `RV64_ALU_OP_INVALID;
            assign zbb_alu_word = 1'b0;
            assign zbb_alu_src1 = {`RV64_XLEN{1'b0}};
            assign zbb_alu_src2 = {`RV64_XLEN{1'b0}};
            assign rotate_ready = 1'b0;
            assign rotate_busy = 1'b0;
            assign rotate_result_valid = 1'b0;
            assign rotate_result = {`RV64_XLEN{1'b0}};
            assign rotate_result_tag = {ROTATE_TAG_WIDTH{1'b0}};
        end
    endgenerate

    wire base_selected = (alu_ext == `RV64_ALU_EXT_BASE) &&
                          (alu_op != `RV64_ALU_OP_INVALID);
    wire m_selected = (alu_ext == `RV64_ALU_EXT_M) &&
                       (alu_op != `RV64_ALU_OP_INVALID);
    wire zbb_selected = (alu_ext == `RV64_ALU_EXT_ZBB) &&
                         (alu_op != `RV64_ALU_OP_INVALID);
    wire rotate_selected = zbb_selected &&
        ((alu_op == `RV64_ALU_OP_ZBB_ROL) ||
         (alu_op == `RV64_ALU_OP_ZBB_ROR));
    wire sequenced_zbb_selected = zbb_selected && !rotate_selected;
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

    reg worker_pending_q;
    reg worker_zbb_q;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] worker_id_q;
    reg [RETIRE_SLOT_WIDTH-1:0] worker_slot_q;
    reg [63:0] worker_trace_id_q;
    reg [`RV64_XLEN-1:0] worker_pc_q;
    reg [`RV64_INSTR_WIDTH-1:0] worker_instr_q;
    reg [`RV64_REG_ADDR_WIDTH-1:0] worker_rs1_addr_q;
    reg [`RV64_REG_ADDR_WIDTH-1:0] worker_rs2_addr_q;
    reg [`RV64_REG_ADDR_WIDTH-1:0] worker_rd_addr_q;
    reg worker_reg_write_q;

    wire worker_result_valid = worker_zbb_q ? zbb_result_valid :
                                             m_result_valid;
    wire worker_result_illegal = worker_zbb_q ? zbb_illegal : m_illegal;
    wire [`RV64_XLEN-1:0] worker_result = worker_zbb_q ? zbb_result :
                                                           m_result;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] worker_cause =
        worker_result_illegal ? `RV64_EXCEPT_CAUSE_ILLEGAL_INSTR :
                           {`RV64_EXCEPT_CAUSE_WIDTH{1'b0}};
    wire [`RV64_XLEN-1:0] worker_tval = worker_result_illegal ?
        {{32{1'b0}}, worker_instr_q} : {`RV64_XLEN{1'b0}};
    wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        worker_completion_data = {
        worker_trace_id_q,
        worker_pc_q,
        worker_pc_q + 64'd4,
        worker_instr_q,
        worker_result,
        worker_rs1_addr_q,
        worker_rs2_addr_q,
        worker_rd_addr_q,
        worker_reg_write_q,
        worker_result_illegal,
        1'b0,
        1'b0,
        worker_result_illegal,
        1'b0,
        worker_cause,
        worker_tval,
        1'b0,
        1'b0,
        1'b0,
        {`RV64_FUNCT12_WIDTH{1'b0}},
        {`RV64_XLEN{1'b0}}
    };

    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] rotate_id;
    wire [RETIRE_SLOT_WIDTH-1:0] rotate_slot;
    wire [63:0] rotate_trace_id;
    wire [`RV64_XLEN-1:0] rotate_pc;
    wire [`RV64_INSTR_WIDTH-1:0] rotate_instr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] rotate_rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] rotate_rs2_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] rotate_rd_addr;
    wire rotate_reg_write;
    assign {
        rotate_id,
        rotate_slot,
        rotate_trace_id,
        rotate_pc,
        rotate_instr,
        rotate_rs1_addr,
        rotate_rs2_addr,
        rotate_rd_addr,
        rotate_reg_write
    } = rotate_result_tag;
    wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        rotate_completion_data = {
        rotate_trace_id,
        rotate_pc,
        rotate_pc + 64'd4,
        rotate_instr,
        rotate_result,
        rotate_rs1_addr,
        rotate_rs2_addr,
        rotate_rd_addr,
        rotate_reg_write,
        1'b0,
        1'b0,
        1'b0,
        1'b0,
        1'b0,
        {`RV64_EXCEPT_CAUSE_WIDTH{1'b0}},
        {`RV64_XLEN{1'b0}},
        1'b0,
        1'b0,
        1'b0,
        {`RV64_FUNCT12_WIDTH{1'b0}},
        {`RV64_XLEN{1'b0}}
    };

    wire output_available = !complete_valid_q || complete_ready_i;
    assign issue_ready_o = !worker_pending_q &&
        ((base_selected && output_available && !rotate_result_valid) ||
         (rotate_selected && ENABLE_RV64ZBB && rotate_ready) ||
         (m_selected && ENABLE_RV64M && m_ready && !rotate_busy &&
          output_available) ||
         (sequenced_zbb_selected && ENABLE_RV64ZBB && zbb_ready &&
          !rotate_busy && output_available));
    wire issue_fire = issue_valid_i && issue_ready_o;
    wire base_fire = issue_fire && base_selected;
    assign m_start = issue_fire && m_selected && ENABLE_RV64M;
    assign zbb_start = issue_fire && sequenced_zbb_selected && ENABLE_RV64ZBB;
    assign rotate_start = issue_fire && rotate_selected && ENABLE_RV64ZBB;
    assign rotate_result_ready = output_available;
    assign m_result_ready = worker_pending_q && !worker_zbb_q &&
                            m_result_valid && output_available;
    assign zbb_result_ready = worker_pending_q && worker_zbb_q &&
                              zbb_result_valid && output_available;
    wire worker_result_ready = m_result_ready || zbb_result_ready;

    assign complete_valid_o = complete_valid_q;
    assign complete_id_o = complete_id_q;
    assign complete_slot_o = complete_slot_q;
    assign complete_payload_o = complete_payload_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            worker_pending_q <= 1'b0;
            worker_zbb_q <= 1'b0;
            worker_id_q <= {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            worker_slot_q <= {RETIRE_SLOT_WIDTH{1'b0}};
            worker_trace_id_q <= 64'd0;
            worker_pc_q <= {`RV64_XLEN{1'b0}};
            worker_instr_q <= {`RV64_INSTR_WIDTH{1'b0}};
            worker_rs1_addr_q <= {`RV64_REG_ADDR_WIDTH{1'b0}};
            worker_rs2_addr_q <= {`RV64_REG_ADDR_WIDTH{1'b0}};
            worker_rd_addr_q <= {`RV64_REG_ADDR_WIDTH{1'b0}};
            worker_reg_write_q <= 1'b0;
            complete_valid_q <= 1'b0;
            complete_id_q <= {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            complete_slot_q <= {RETIRE_SLOT_WIDTH{1'b0}};
            complete_payload_q <=
                {`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH{1'b0}};
        end else if (flush_i) begin
            worker_pending_q <= 1'b0;
            worker_zbb_q <= 1'b0;
            complete_valid_q <= 1'b0;
        end else begin
            if (complete_valid_q && complete_ready_i) begin
                complete_valid_q <= 1'b0;
            end

            if (m_start || zbb_start) begin
                worker_pending_q <= 1'b1;
                worker_zbb_q <= zbb_start;
                worker_id_q <= issue_id_i;
                worker_slot_q <= issue_slot_i;
                worker_trace_id_q <= trace_id;
                worker_pc_q <= pc;
                worker_instr_q <= instr;
                worker_rs1_addr_q <= rs1_addr;
                worker_rs2_addr_q <= rs2_addr;
                worker_rd_addr_q <= rd_addr;
                worker_reg_write_q <= reg_write;
            end

            if (rotate_result_valid && rotate_result_ready) begin
                complete_valid_q <= 1'b1;
                complete_id_q <= rotate_id;
                complete_slot_q <= rotate_slot;
                complete_payload_q <= rotate_completion_data;
            end else if (worker_result_ready) begin
                worker_pending_q <= 1'b0;
                complete_valid_q <= 1'b1;
                complete_id_q <= worker_id_q;
                complete_slot_q <= worker_slot_q;
                complete_payload_q <= worker_completion_data;
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
        m_busy,
        zbb_busy,
        worker_result_valid
    };

endmodule
