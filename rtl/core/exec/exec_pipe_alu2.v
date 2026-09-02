`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/alu2-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/except/except-defs.v"

// A deliberately restricted, single-cycle integer lane.  The shared ALU2
// class defines normally retain only shifts, rotates, and logical operations;
// add/sub, compare, upper-immediate, M, and complex Zbb operations stay out of
// this datapath.  Its one-entry completion latch is elastic.
module openrv64_exec_pipe_alu2 #(
    parameter integer RETIRE_SLOT_WIDTH = 3,
    parameter integer ENABLE_RV64ZBB = 1
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
    output wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                                        complete_payload_o
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

    wire [`RV64_OPCODE_WIDTH-1:0] opcode = `RV64_OPCODE(instr);
    wire alu_uses_imm = (opcode == `RV64_OPCODE_LUI) ||
                        (opcode == `RV64_OPCODE_AUIPC) ||
                        (opcode == `RV64_OPCODE_OP_IMM) ||
                        (opcode == `RV64_OPCODE_OP_IMM_32);
    wire [`RV64_XLEN-1:0] alu_src1 = (opcode == `RV64_OPCODE_LUI) ?
                                     {`RV64_XLEN{1'b0}} : rs1_data;
    wire [`RV64_XLEN-1:0] alu_src2 = alu_uses_imm ? imm : rs2_data;

    wire operation_supported =
        `OPENRV64_ALU2_OP_SUPPORTED(alu_ext, alu_op) &&
        ((alu_ext != `RV64_ALU_EXT_ZBB) || (ENABLE_RV64ZBB != 0));

    wire [5:0] shift_amount = alu_src2[5:0];
    wire [5:0] inverse_shift_amount = -shift_amount;
    wire [4:0] word_shift_amount = alu_src2[4:0];
    wire [4:0] inverse_word_shift_amount = -word_shift_amount;
    wire [63:0] rotate_left_result =
        (alu_src1 << shift_amount) |
        (alu_src1 >> inverse_shift_amount);
    wire [63:0] rotate_right_result =
        (alu_src1 >> shift_amount) |
        (alu_src1 << inverse_shift_amount);
    wire [31:0] rotate_left_word_result =
        (alu_src1[31:0] << word_shift_amount) |
        (alu_src1[31:0] >> inverse_word_shift_amount);
    wire [31:0] rotate_right_word_result =
        (alu_src1[31:0] >> word_shift_amount) |
        (alu_src1[31:0] << inverse_word_shift_amount);
    wire [31:0] add_word_result = alu_src1[31:0] + alu_src2[31:0];
    wire [31:0] sub_word_result = alu_src1[31:0] - alu_src2[31:0];
    wire [31:0] sll_word_result =
        alu_src1[31:0] << word_shift_amount;
    wire [31:0] srl_word_result =
        alu_src1[31:0] >> word_shift_amount;
    wire [31:0] sra_word_result =
        $signed(alu_src1[31:0]) >>> word_shift_amount;

    reg alu_valid;
    reg [`RV64_XLEN-1:0] alu_result;
    always @* begin
        alu_valid = 1'b0;
        alu_result = {`RV64_XLEN{1'b0}};

        if ((alu_ext == `RV64_ALU_EXT_BASE) &&
            `OPENRV64_ALU2_BASE_OP_SUPPORTED(alu_op)) begin
            case (alu_op)
                `RV64_ALU_OP_ADD: begin
                    if (`OPENRV64_ALU2_ENABLE_ADD_SUB != 0) begin
                        alu_valid = 1'b1;
                        if (word_op)
                            alu_result = {{32{add_word_result[31]}},
                                          add_word_result};
                        else
                            alu_result = alu_src1 + alu_src2;
                    end
                end
                `RV64_ALU_OP_SUB: begin
                    if (`OPENRV64_ALU2_ENABLE_ADD_SUB != 0) begin
                        alu_valid = 1'b1;
                        if (word_op)
                            alu_result = {{32{sub_word_result[31]}},
                                          sub_word_result};
                        else
                            alu_result = alu_src1 - alu_src2;
                    end
                end
                `RV64_ALU_OP_SLL: begin
                    alu_valid = 1'b1;
                    if (word_op)
                        alu_result = {{32{sll_word_result[31]}},
                                      sll_word_result};
                    else
                        alu_result = alu_src1 << shift_amount;
                end
                `RV64_ALU_OP_SLT: begin
                    if (`OPENRV64_ALU2_ENABLE_COMPARE != 0 && !word_op) begin
                        alu_valid = 1'b1;
                        alu_result = ($signed(alu_src1) <
                                      $signed(alu_src2)) ? 64'd1 : 64'd0;
                    end
                end
                `RV64_ALU_OP_SLTU: begin
                    if (`OPENRV64_ALU2_ENABLE_COMPARE != 0 && !word_op) begin
                        alu_valid = 1'b1;
                        alu_result = (alu_src1 < alu_src2) ? 64'd1 : 64'd0;
                    end
                end
                `RV64_ALU_OP_XOR: begin
                    if (!word_op) begin
                        alu_valid = 1'b1;
                        alu_result = alu_src1 ^ alu_src2;
                    end
                end
                `RV64_ALU_OP_SRL: begin
                    alu_valid = 1'b1;
                    if (word_op)
                        alu_result = {{32{srl_word_result[31]}},
                                      srl_word_result};
                    else
                        alu_result = alu_src1 >> shift_amount;
                end
                `RV64_ALU_OP_SRA: begin
                    alu_valid = 1'b1;
                    if (word_op)
                        alu_result = {{32{sra_word_result[31]}},
                                      sra_word_result};
                    else
                        alu_result = $signed(alu_src1) >>> shift_amount;
                end
                `RV64_ALU_OP_OR: begin
                    if (!word_op) begin
                        alu_valid = 1'b1;
                        alu_result = alu_src1 | alu_src2;
                    end
                end
                `RV64_ALU_OP_AND: begin
                    if (!word_op) begin
                        alu_valid = 1'b1;
                        alu_result = alu_src1 & alu_src2;
                    end
                end
                `RV64_ALU_OP_LUI: begin
                    if (`OPENRV64_ALU2_ENABLE_UPPER != 0 && !word_op) begin
                        alu_valid = 1'b1;
                        alu_result = alu_src2;
                    end
                end
                `RV64_ALU_OP_AUIPC: begin
                    if (`OPENRV64_ALU2_ENABLE_UPPER != 0 && !word_op) begin
                        alu_valid = 1'b1;
                        alu_result = pc + alu_src2;
                    end
                end
                default: begin
                end
            endcase
        end else if ((ENABLE_RV64ZBB != 0) &&
                     (alu_ext == `RV64_ALU_EXT_ZBB) &&
                     `OPENRV64_ALU2_ZBB_OP_SUPPORTED(alu_op)) begin
            case (alu_op)
                `RV64_ALU_OP_ZBB_ANDN: begin
                    if (!word_op) begin
                        alu_valid = 1'b1;
                        alu_result = alu_src1 & ~alu_src2;
                    end
                end
                `RV64_ALU_OP_ZBB_ORN: begin
                    if (!word_op) begin
                        alu_valid = 1'b1;
                        alu_result = alu_src1 | ~alu_src2;
                    end
                end
                `RV64_ALU_OP_ZBB_XNOR: begin
                    if (!word_op) begin
                        alu_valid = 1'b1;
                        alu_result = ~(alu_src1 ^ alu_src2);
                    end
                end
                `RV64_ALU_OP_ZBB_ROL: begin
                    alu_valid = 1'b1;
                    alu_result = word_op ?
                        {{32{rotate_left_word_result[31]}},
                         rotate_left_word_result} : rotate_left_result;
                end
                `RV64_ALU_OP_ZBB_ROR: begin
                    alu_valid = 1'b1;
                    alu_result = word_op ?
                        {{32{rotate_right_word_result[31]}},
                         rotate_right_word_result} : rotate_right_result;
                end
                default: begin
                end
            endcase
        end
    end

    wire result_illegal = illegal || !operation_supported || !alu_valid;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] result_cause =
        result_illegal ? `RV64_EXCEPT_CAUSE_ILLEGAL_INSTR :
                         {`RV64_EXCEPT_CAUSE_WIDTH{1'b0}};
    wire [`RV64_XLEN-1:0] result_tval = result_illegal ?
        {{32{1'b0}}, instr} : {`RV64_XLEN{1'b0}};
    wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] completion_data = {
        trace_id,
        pc,
        pc + 64'd4,
        instr,
        alu_result,
        rs1_addr,
        rs2_addr,
        rd_addr,
        reg_write,
        result_illegal,
        1'b0,
        1'b0,
        result_illegal,
        1'b0,
        result_cause,
        result_tval,
        1'b0,
        1'b0,
        1'b0,
        {`RV64_FUNCT12_WIDTH{1'b0}},
        {`RV64_XLEN{1'b0}}
    };

    reg complete_valid_q;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] complete_id_q;
    reg [RETIRE_SLOT_WIDTH-1:0] complete_slot_q;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] complete_payload_q;

    wire output_available = !complete_valid_q || complete_ready_i;
    assign issue_ready_o = operation_supported && alu_valid &&
                           output_available;
    wire issue_fire = issue_valid_i && issue_ready_o;

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
        end else if (flush_i) begin
            complete_valid_q <= 1'b0;
        end else begin
            if (complete_valid_q && complete_ready_i)
                complete_valid_q <= 1'b0;
            if (issue_fire) begin
                complete_valid_q <= 1'b1;
                complete_id_q <= issue_id_i;
                complete_slot_q <= issue_slot_i;
                complete_payload_q <= completion_data;
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
        sfence_vma_allowed
    };

endmodule
