`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/early-defs.v"
`include "core/exec/vec/defs.v"
`include "core/exec/vec/instr-defs.v"

// Test-only core for running short scalar/vector instruction streams. Vector
// arithmetic dispatch is nonblocking and several commands may share the lane
// pipeline. The primary LSU remains blocking; a second read-only LSU may run
// one load in the background. Software uses VSYNC for explicit dependencies.
// Standard RV64I ALU/branch instructions reuse the production decoder and
// execution blocks. Custom instructions drive the isolated vector units.
module openrv64_vec_test_top #(
    parameter logic [63:0] RESET_VECTOR = 64'h0000_0000_0000_0100,
    parameter integer VLEN = 256,
    parameter integer DATAPATH_WIDTH = 64,
    parameter integer VEC_CACHE_DATA_WIDTH = 256,
    parameter integer VEC_CACHE_BYTES = 256 * 1024,
    parameter integer VEC_CACHE_LINE_BYTES = 64,
    parameter integer VEC_CACHE_WAYS = 4,
    parameter integer VEC_CACHE_MSHRS = 8,
    parameter integer TAG_WIDTH = 8,
    parameter integer MEM_TAG_WIDTH = 8,
    parameter integer VEC_INFLIGHT_DEPTH = 8
) (
    input  logic                          clk,
    input  logic                          rst_n,

    output logic                          ifetch_valid_o,
    input  logic                          ifetch_ready_i,
    output logic [63:0]                   ifetch_addr_o,
    input  logic [63:0]                   ifetch_rdata_i,
    input  logic                          ifetch_error_i,

    output logic                          vec_mem_req_valid_o,
    input  logic                          vec_mem_req_ready_i,
    output logic [MEM_TAG_WIDTH-1:0]      vec_mem_req_tag_o,
    output logic                          vec_mem_req_write_o,
    output logic [63:0]                   vec_mem_req_addr_o,
    output logic [DATAPATH_WIDTH-1:0]     vec_mem_req_wdata_o,
    output logic [(DATAPATH_WIDTH/8)-1:0] vec_mem_req_wstrb_o,

    input  logic                          vec_mem_resp_valid_i,
    output logic                          vec_mem_resp_ready_o,
    input  logic [MEM_TAG_WIDTH-1:0]      vec_mem_resp_tag_i,
    input  logic [DATAPATH_WIDTH-1:0]     vec_mem_resp_rdata_i,
    input  logic                          vec_mem_resp_error_i,
    input  logic                          vec_mem_resp_retry_i,

    output logic [63:0]                   dbg_pc_o,
    output logic [31:0]                   dbg_instr_o,
    output logic                          dbg_halted_o,
    output logic                          dbg_error_o,
    output logic                          dbg_vec_busy_o,
    output logic                          dbg_vec_replay_o,
    output logic [63:0]                   dbg_retired_o
);

    localparam integer REG_ADDR_WIDTH = 5;
    localparam integer MAX_LMUL = 8;
    localparam integer LMUL_WIDTH = 2;
    localparam integer LSU_MEM_TAG_WIDTH = TAG_WIDTH;
    localparam integer NUM_VEC_REGS = 32;
    localparam integer VEC_QUEUE_PTR_WIDTH =
        (VEC_INFLIGHT_DEPTH <= 1) ? 1 : $clog2(VEC_INFLIGHT_DEPTH);
    localparam integer SLICE_ADDR_WIDTH =
        ((VLEN / DATAPATH_WIDTH) <= 1) ? 1 :
        $clog2(VLEN / DATAPATH_WIDTH);

    localparam logic [2:0] STATE_FETCH = 3'd0;
    localparam logic [2:0] STATE_EXEC = 3'd1;
    localparam logic [2:0] STATE_VEC_COMPLETE = 3'd2;
    localparam logic [2:0] STATE_VEC_RETIRE = 3'd3;
    localparam logic [2:0] STATE_HALT = 3'd4;

    logic [2:0] state_q;
    logic [63:0] pc_q;
    logic [31:0] instr_q;
    logic [63:0] vtype_q;
    logic [TAG_WIDTH-1:0] next_tag_q;
    logic [TAG_WIDTH-1:0] active_vec_tag_q;
    logic active_vec_is_lsu_q;
    logic active_vec_error_q;
    logic active_vec_writes_q;
    logic [NUM_VEC_REGS-1:0] active_vec_write_mask_q;
    logic vec_read_active_q;
    logic vec_read_complete_q;
    logic vec_read_error_q;
    logic [TAG_WIDTH-1:0] vec_read_tag_q;
    logic [REG_ADDR_WIDTH-1:0] vec_read_vd_q;
    logic [LMUL_WIDTH-1:0] vec_read_lmul_q;
    logic [63:0] vec_read_retired_q;
    logic vec_alu_retire_pending_q;
    logic [TAG_WIDTH-1:0] vec_alu_retire_tag_q;
    logic vec_alu_retire_error_q;
    logic [63:0] vec_alu_retired_q;
    logic [NUM_VEC_REGS-1:0]
        vec_alu_write_mask_q [0:VEC_INFLIGHT_DEPTH-1];
    logic [TAG_WIDTH-1:0]
        vec_alu_write_tag_q [0:VEC_INFLIGHT_DEPTH-1];
    logic vec_alu_write_valid_q [0:VEC_INFLIGHT_DEPTH-1];
    logic [VEC_QUEUE_PTR_WIDTH-1:0] vec_alu_write_tail_q;
    logic [VEC_QUEUE_PTR_WIDTH-1:0] vec_alu_write_head_q;
    logic halted_q;
    logic error_q;
    logic [63:0] retired_q;

    assign ifetch_valid_o = state_q == STATE_FETCH;
    assign ifetch_addr_o = pc_q;
    assign dbg_pc_o = pc_q;
    assign dbg_instr_o = instr_q;
    assign dbg_halted_o = halted_q;
    assign dbg_error_o = error_q;
    assign dbg_retired_o = retired_q + vec_read_retired_q +
                           vec_alu_retired_q;

    function automatic logic [NUM_VEC_REGS-1:0] vec_group_mask;
        input logic [REG_ADDR_WIDTH-1:0] base;
        input logic [LMUL_WIDTH-1:0] lmul;
        integer mask_index;
        integer group_count;
        begin
            vec_group_mask = {NUM_VEC_REGS{1'b0}};
            group_count = 1 << lmul;
            for (mask_index = 0; mask_index < NUM_VEC_REGS;
                 mask_index = mask_index + 1)
                if ((mask_index >= base) &&
                    (mask_index < (base + group_count)))
                    vec_group_mask[mask_index] = 1'b1;
        end
    endfunction

    wire [`RV64_OPCODE_WIDTH-1:0] instr_opcode =
        `RV64_OPCODE(instr_q);
    wire [`RV64_FUNCT3_WIDTH-1:0] instr_funct3 =
        `RV64_FUNCT3(instr_q);
    wire [REG_ADDR_WIDTH-1:0] instr_rd = `RV64_RD(instr_q);
    wire [REG_ADDR_WIDTH-1:0] instr_rs1 = `RV64_RS1(instr_q);
    wire [REG_ADDR_WIDTH-1:0] instr_rs2 = `RV64_RS2(instr_q);
    wire instr_acc_select =
        instr_q[`OPENRV64_VEC_INSTR_ACC_SELECT_BIT];

    wire instr_is_vec_alu =
        instr_opcode == `OPENRV64_VEC_INSTR_OPCODE_ALU;
    wire instr_is_vec_acc =
        instr_opcode == `OPENRV64_VEC_INSTR_OPCODE_ACC;
    wire instr_is_vec_lsu =
        instr_opcode == `OPENRV64_VEC_INSTR_OPCODE_LSU;
    wire instr_is_vset = instr_is_vec_alu &&
        (instr_funct3 == `OPENRV64_VEC_INSTR_FUNCT3_VSET) &&
        (instr_rd == 0) && (instr_rs2 == 0) && (instr_q[31:25] == 0);
    wire instr_is_vsync = instr_is_vec_alu &&
        (instr_funct3 == `OPENRV64_VEC_INSTR_FUNCT3_VSYNC) &&
        (instr_rd == 0) && (instr_q[31:25] == 0);
    wire instr_is_vprfm =
        (instr_opcode == `OPENRV64_VEC_INSTR_OPCODE_PREFETCH) &&
        ((instr_funct3 == `OPENRV64_VEC_INSTR_FUNCT3_VPRFM_AGED) ||
         (instr_funct3 == `OPENRV64_VEC_INSTR_FUNCT3_VPRFM_STREAM)) &&
        (instr_rd == 0) && (instr_q[31:24] == 0);

    logic [`OPENRV64_VEC_OP_WIDTH-1:0] decoded_vec_op;
    logic decoded_vec_alu_valid;
    always_comb begin
        decoded_vec_op = `OPENRV64_VEC_OP_INVALID;
        decoded_vec_alu_valid = 1'b1;
        if (instr_is_vec_alu) begin
            case (instr_funct3)
                `OPENRV64_VEC_INSTR_FUNCT3_AND:
                    decoded_vec_op = `OPENRV64_VEC_OP_AND;
                `OPENRV64_VEC_INSTR_FUNCT3_OR:
                    decoded_vec_op = `OPENRV64_VEC_OP_OR;
                `OPENRV64_VEC_INSTR_FUNCT3_XOR:
                    decoded_vec_op = `OPENRV64_VEC_OP_XOR;
                `OPENRV64_VEC_INSTR_FUNCT3_NOT:
                    decoded_vec_op = `OPENRV64_VEC_OP_NOT;
                `OPENRV64_VEC_INSTR_FUNCT3_FADD:
                    decoded_vec_op = `OPENRV64_VEC_OP_FADD;
                `OPENRV64_VEC_INSTR_FUNCT3_FMUL:
                    decoded_vec_op = `OPENRV64_VEC_OP_FMUL;
                default: decoded_vec_alu_valid = 1'b0;
            endcase
        end else if (instr_is_vec_acc) begin
            case (instr_funct3)
                `OPENRV64_VEC_INSTR_FUNCT3_VLDA:
                    decoded_vec_op = `OPENRV64_VEC_OP_VLDA;
                `OPENRV64_VEC_INSTR_FUNCT3_VSTA:
                    decoded_vec_op = `OPENRV64_VEC_OP_VSTA;
                `OPENRV64_VEC_INSTR_FUNCT3_VMAC:
                    decoded_vec_op = `OPENRV64_VEC_OP_VMAC;
                default: decoded_vec_alu_valid = 1'b0;
            endcase
        end else begin
            decoded_vec_alu_valid = 1'b0;
        end
    end
    wire instr_vec_acc_fields_valid =
        ((decoded_vec_op == `OPENRV64_VEC_OP_VLDA) &&
         (instr_rd == 0) && (instr_rs2 == 0)) ||
        ((decoded_vec_op == `OPENRV64_VEC_OP_VSTA) &&
         (instr_rs1 == 0) && (instr_rs2 == 0)) ||
        ((decoded_vec_op == `OPENRV64_VEC_OP_VMAC) &&
         (instr_rd == 0));
    wire instr_is_vec_arith = decoded_vec_alu_valid &&
        ((instr_is_vec_alu && (instr_q[31:25] == 0) &&
          !instr_is_vset && !instr_is_vsync) ||
         (instr_is_vec_acc && (instr_q[31:26] == 0) &&
          instr_vec_acc_fields_valid));
    wire decoded_vec_writes_vreg =
        (decoded_vec_op != `OPENRV64_VEC_OP_VLDA) &&
        (decoded_vec_op != `OPENRV64_VEC_OP_VMAC);
    wire instr_is_vec_load = instr_is_vec_lsu &&
        (instr_funct3 == `OPENRV64_VEC_INSTR_FUNCT3_LOAD) &&
        (instr_rs2 == 0) && (instr_q[31:25] == 0);
    wire instr_is_vec_store = instr_is_vec_lsu &&
        (instr_funct3 == `OPENRV64_VEC_INSTR_FUNCT3_STORE) &&
        (instr_rd == 0) && (instr_q[31:25] == 0);

    wire scalar_decode_valid;
    wire scalar_decode_illegal;
    wire [`RV64_OPCODE_WIDTH-1:0] scalar_opcode;
    wire [`RV64_FUNCT3_WIDTH-1:0] scalar_funct3;
    wire [`RV64_FUNCT7_WIDTH-1:0] scalar_funct7;
    wire [`RV64_FUNCT12_WIDTH-1:0] scalar_funct12;
    wire [`RV64_EARLY_CLASS_WIDTH-1:0] scalar_class;
    wire [`RV64_EARLY_FORMAT_WIDTH-1:0] scalar_format;
    wire scalar_uses_rs1;
    wire scalar_uses_rs2;
    wire scalar_uses_rd;
    wire [REG_ADDR_WIDTH-1:0] scalar_rs1_addr;
    wire [REG_ADDR_WIDTH-1:0] scalar_rs2_addr;
    wire [REG_ADDR_WIDTH-1:0] scalar_rd_addr;
    wire scalar_reg_write;
    wire scalar_imm_valid;
    wire scalar_has_imm;
    wire [63:0] scalar_imm;
    wire scalar_mem_read;
    wire scalar_mem_write;
    wire scalar_branch;
    wire scalar_jump;
    wire scalar_word_op;
    wire scalar_system;
    wire scalar_fence;
    wire [`RV64_ALU_EXT_WIDTH-1:0] scalar_alu_ext;
    wire [`RV64_ALU_OP_WIDTH-1:0] scalar_alu_op;
    wire [`RV64_LSU_OP_WIDTH-1:0] scalar_lsu_op;
    wire [`RV64_LSU_SIZE_WIDTH-1:0] scalar_lsu_size;
    wire scalar_lsu_unsigned;
    wire [`RV64_BR_OP_WIDTH-1:0] scalar_br_op;
    wire scalar_br_link;
    wire scalar_br_indirect;
    wire scalar_subdecode;
    wire scalar_extension_decode;
    wire unused_scalar_decode = |{
        scalar_opcode, scalar_funct3, scalar_funct7, scalar_funct12,
        scalar_class, scalar_format, scalar_uses_rs1, scalar_uses_rs2,
        scalar_uses_rd, scalar_imm_valid, scalar_has_imm,
        scalar_lsu_op, scalar_lsu_size, scalar_lsu_unsigned,
        scalar_br_link, scalar_br_indirect, scalar_subdecode,
        scalar_extension_decode
    };

    openrv64_decode_top #(
        .ENABLE_RV64M(1'b0), .ENABLE_RV64A(1'b0)
    ) u_scalar_decode (
        .instr_i(instr_q),
        .extension_selected_i(1'b0),
        .extension_valid_i(1'b0),
        .extension_illegal_i(1'b0),
        .extension_class_sel_i({`RV64_EARLY_CLASS_WIDTH{1'b0}}),
        .extension_format_sel_i({`RV64_EARLY_FORMAT_WIDTH{1'b0}}),
        .extension_uses_rs1_i(1'b0),
        .extension_uses_rs2_i(1'b0),
        .extension_uses_rd_i(1'b0),
        .extension_rs1_addr_i({`RV64_REG_ADDR_WIDTH{1'b0}}),
        .extension_rs2_addr_i({`RV64_REG_ADDR_WIDTH{1'b0}}),
        .extension_rd_addr_i({`RV64_REG_ADDR_WIDTH{1'b0}}),
        .extension_reg_write_i(1'b0),
        .extension_imm_valid_i(1'b0),
        .extension_has_imm_i(1'b0),
        .extension_imm_i({`RV64_XLEN{1'b0}}),
        .extension_mem_read_i(1'b0),
        .extension_mem_write_i(1'b0),
        .extension_lsu_op_sel_i({`RV64_LSU_OP_WIDTH{1'b0}}),
        .extension_lsu_size_sel_i({`RV64_LSU_SIZE_WIDTH{1'b0}}),
        .extension_lsu_unsigned_i(1'b0),
        .extension_payload_i(1'b0),
        .valid_o(scalar_decode_valid), .illegal_o(scalar_decode_illegal),
        .opcode_o(scalar_opcode), .funct3_o(scalar_funct3),
        .funct7_o(scalar_funct7), .funct12_o(scalar_funct12),
        .class_sel_o(scalar_class), .format_sel_o(scalar_format),
        .uses_rs1_o(scalar_uses_rs1), .uses_rs2_o(scalar_uses_rs2),
        .uses_rd_o(scalar_uses_rd), .rs1_addr_o(scalar_rs1_addr),
        .rs2_addr_o(scalar_rs2_addr), .rd_addr_o(scalar_rd_addr),
        .reg_write_o(scalar_reg_write), .imm_valid_o(scalar_imm_valid),
        .has_imm_o(scalar_has_imm), .imm_o(scalar_imm),
        .mem_read_o(scalar_mem_read), .mem_write_o(scalar_mem_write),
        .branch_o(scalar_branch), .jump_o(scalar_jump),
        .word_op_o(scalar_word_op), .system_o(scalar_system),
        .fence_o(scalar_fence), .alu_ext_sel_o(scalar_alu_ext),
        .alu_op_sel_o(scalar_alu_op), .lsu_op_sel_o(scalar_lsu_op),
        .lsu_size_sel_o(scalar_lsu_size),
        .lsu_unsigned_o(scalar_lsu_unsigned),
        .br_op_sel_o(scalar_br_op), .br_link_o(scalar_br_link),
        .br_indirect_o(scalar_br_indirect),
        .subdecode_needed_o(scalar_subdecode),
        .extension_decode_possible_o(scalar_extension_decode)
    );

    wire custom_reads_scalar_rs1 = instr_is_vset || instr_is_vec_lsu ||
                                   instr_is_vprfm;
    wire vec_lsu_gpr_read_valid;
    wire vec_lsu_gpr_read_ready;
    wire [REG_ADDR_WIDTH-1:0] vec_lsu_gpr_read_addr;
    wire [63:0] vec_lsu_gpr_read_data;
    wire vec_read_gpr_read_valid;
    wire vec_read_gpr_read_ready;
    wire [REG_ADDR_WIDTH-1:0] vec_read_gpr_read_addr;
    wire [63:0] vec_read_gpr_read_data;
    wire [REG_ADDR_WIDTH-1:0] normal_gpr_rs1_addr =
        custom_reads_scalar_rs1 ? instr_rs1 : scalar_rs1_addr;
    wire [REG_ADDR_WIDTH-1:0] gpr_rs1_addr =
        vec_read_gpr_read_valid ? vec_read_gpr_read_addr :
        vec_lsu_gpr_read_valid ? vec_lsu_gpr_read_addr :
                                 normal_gpr_rs1_addr;
    wire [REG_ADDR_WIDTH-1:0] gpr_rs2_addr = scalar_rs2_addr;
    wire [63:0] gpr_rs1_data;
    wire [63:0] gpr_rs2_data;

    wire scalar_alu_selected = scalar_decode_valid &&
        !scalar_decode_illegal &&
        (scalar_alu_ext == `RV64_ALU_EXT_BASE) &&
        (scalar_alu_op != `RV64_ALU_OP_INVALID) &&
        !scalar_branch && !scalar_jump &&
        !scalar_mem_read && !scalar_mem_write &&
        !scalar_system && !scalar_fence;
    wire scalar_branch_selected = scalar_decode_valid &&
        !scalar_decode_illegal && (scalar_branch || scalar_jump);
    wire scalar_alu_uses_imm =
        (instr_opcode == `RV64_OPCODE_LUI) ||
        (instr_opcode == `RV64_OPCODE_AUIPC) ||
        (instr_opcode == `RV64_OPCODE_OP_IMM) ||
        (instr_opcode == `RV64_OPCODE_OP_IMM_32);
    wire [63:0] scalar_alu_src1 =
        (instr_opcode == `RV64_OPCODE_LUI) ? 64'd0 : gpr_rs1_data;
    wire [63:0] scalar_alu_src2 = scalar_alu_uses_imm ?
        scalar_imm : gpr_rs2_data;
    wire scalar_alu_valid;
    wire scalar_alu_illegal;
    wire [63:0] scalar_alu_result;

    openrv64_exec_alu_rv64i u_scalar_alu (
        .op_sel_i(scalar_alu_op), .word_op_i(scalar_word_op),
        .src1_i(scalar_alu_src1), .src2_i(scalar_alu_src2),
        .pc_i(pc_q), .valid_o(scalar_alu_valid),
        .illegal_o(scalar_alu_illegal), .result_o(scalar_alu_result)
    );

    wire scalar_br_valid;
    wire scalar_br_illegal;
    wire scalar_br_taken;
    wire [63:0] scalar_br_target;
    wire scalar_br_unit_link;
    wire [63:0] scalar_br_link_data;

    openrv64_exec_br u_scalar_branch (
        .op_sel_i(scalar_br_op), .pc_i(pc_q),
        .src1_i(gpr_rs1_data), .src2_i(gpr_rs2_data),
        .imm_i(scalar_imm), .valid_o(scalar_br_valid),
        .illegal_o(scalar_br_illegal), .taken_o(scalar_br_taken),
        .target_o(scalar_br_target), .link_o(scalar_br_unit_link),
        .link_data_o(scalar_br_link_data)
    );

    wire scalar_alu_commit = (state_q == STATE_EXEC) &&
        scalar_alu_selected && scalar_alu_valid && !scalar_alu_illegal;
    wire scalar_br_commit = (state_q == STATE_EXEC) &&
        scalar_branch_selected && scalar_br_valid && !scalar_br_illegal &&
        (!scalar_br_taken || (scalar_br_target[1:0] == 0));
    wire gpr_write =
        (scalar_alu_commit && scalar_reg_write) ||
        (scalar_br_commit && scalar_br_unit_link && scalar_reg_write);
    wire [REG_ADDR_WIDTH-1:0] gpr_write_addr = scalar_rd_addr;
    wire [63:0] gpr_write_data = scalar_br_commit ?
        scalar_br_link_data : scalar_alu_result;

    // The scalar path remains blocking, so the next scalar instruction cannot
    // need a same-cycle writeback bypass. Disabling it also prevents a
    // combinational loop when an instruction such as ADDI writes what it reads.
    openrv64_rv64i_gpr #(
        .READ_WRITE_BYPASS(0)
    ) u_scalar_regs (
        .clk(clk), .rst_n(rst_n),
        .rs1_addr_i(gpr_rs1_addr), .rs1_data_o(gpr_rs1_data),
        .rs2_addr_i(gpr_rs2_addr), .rs2_data_o(gpr_rs2_data),
        .rd_write_i(gpr_write), .rd_addr_i(gpr_write_addr),
        .rd_data_i(gpr_write_data)
    );
    // The background read LSU gets first use of the single custom GPR pointer
    // sideband. It holds a request until accepted, so the foreground LSU can
    // safely wait for the following cycle.
    assign vec_read_gpr_read_ready = vec_read_gpr_read_valid;
    assign vec_lsu_gpr_read_ready = !vec_read_gpr_read_valid;
    assign vec_lsu_gpr_read_data = gpr_rs1_data;
    assign vec_read_gpr_read_data = gpr_rs1_data;

    wire [1:0] vec_alu_rf_read_valid;
    wire [1:0] vec_alu_rf_read_ready;
    wire [2*REG_ADDR_WIDTH-1:0] vec_alu_rf_read_addr;
    wire [2*SLICE_ADDR_WIDTH-1:0] vec_alu_rf_read_slice;
    wire [2*DATAPATH_WIDTH-1:0] vec_alu_rf_read_data;
    wire vec_alu_rf_write_valid;
    wire vec_alu_rf_write_ready;
    wire [REG_ADDR_WIDTH-1:0] vec_alu_rf_write_addr;
    wire [SLICE_ADDR_WIDTH-1:0] vec_alu_rf_write_slice;
    wire [DATAPATH_WIDTH-1:0] vec_alu_rf_write_data;
    wire vec_alu_dispatch_ready;
    wire vec_alu_complete_valid;
    wire [TAG_WIDTH-1:0] vec_alu_complete_tag;
    wire vec_alu_complete_unsupported;
    wire vec_alu_retire_ready;
    wire vec_alu_replay;
    wire vec_alu_busy;

    wire vec_alu_dispatch_valid = (state_q == STATE_EXEC) &&
                                  instr_is_vec_arith;
    wire vec_alu_dispatch_fire = vec_alu_dispatch_valid &&
                                 vec_alu_dispatch_ready;
    wire vec_alu_complete_ready = !vec_alu_retire_pending_q;
    wire vec_alu_complete_fire = vec_alu_complete_valid &&
                                 vec_alu_complete_ready;
    wire vec_alu_retire_valid = vec_alu_retire_pending_q;
    wire vec_alu_retire_fire = vec_alu_retire_valid &&
                               vec_alu_retire_ready;

    openrv64_exec_vec #(
        .VLEN(VLEN), .DATAPATH_WIDTH(DATAPATH_WIDTH),
        .TAG_WIDTH(TAG_WIDTH), .MAX_LMUL(MAX_LMUL),
        .LMUL_WIDTH(LMUL_WIDTH),
        .INFLIGHT_DEPTH(VEC_INFLIGHT_DEPTH)
    ) u_vec_alu (
        .clk(clk), .rst_n(rst_n),
        .dispatch_valid_i(vec_alu_dispatch_valid),
        .dispatch_ready_o(vec_alu_dispatch_ready),
        .dispatch_tag_i(next_tag_q), .dispatch_op_i(decoded_vec_op),
        .dispatch_acc_i(instr_acc_select),
        .dispatch_vtype_i(vtype_q), .dispatch_vs1_i(instr_rs1),
        .dispatch_vs2_i(instr_rs2), .dispatch_vd_i(instr_rd),
        .rf_read_valid_o(vec_alu_rf_read_valid),
        .rf_read_ready_i(vec_alu_rf_read_ready),
        .rf_read_addr_o(vec_alu_rf_read_addr),
        .rf_read_slice_o(vec_alu_rf_read_slice),
        .rf_read_data_i(vec_alu_rf_read_data), .operands_ready_i(1'b1),
        .complete_valid_o(vec_alu_complete_valid),
        .complete_ready_i(vec_alu_complete_ready),
        .complete_tag_o(vec_alu_complete_tag),
        .complete_unsupported_o(vec_alu_complete_unsupported),
        .retire_valid_i(vec_alu_retire_valid),
        .retire_ready_o(vec_alu_retire_ready),
        .retire_tag_i(vec_alu_retire_tag_q), .retire_kill_i(1'b0),
        .rf_write_valid_o(vec_alu_rf_write_valid),
        .rf_write_ready_i(vec_alu_rf_write_ready),
        .rf_write_addr_o(vec_alu_rf_write_addr),
        .rf_write_slice_o(vec_alu_rf_write_slice),
        .rf_write_data_o(vec_alu_rf_write_data),
        .replay_o(vec_alu_replay), .busy_o(vec_alu_busy)
    );

    wire vec_lsu_rf_read_valid;
    wire vec_lsu_rf_read_ready;
    wire [REG_ADDR_WIDTH-1:0] vec_lsu_rf_read_addr;
    wire [SLICE_ADDR_WIDTH-1:0] vec_lsu_rf_read_slice;
    wire [DATAPATH_WIDTH-1:0] vec_lsu_rf_read_data;
    wire vec_lsu_rf_write_valid;
    wire vec_lsu_rf_write_ready;
    wire [REG_ADDR_WIDTH-1:0] vec_lsu_rf_write_addr;
    wire [SLICE_ADDR_WIDTH-1:0] vec_lsu_rf_write_slice;
    wire [DATAPATH_WIDTH-1:0] vec_lsu_rf_write_data;
    wire vec_lsu_dispatch_ready;
    wire vec_lsu_complete_valid;
    wire [TAG_WIDTH-1:0] vec_lsu_complete_tag;
    wire vec_lsu_complete_fault;
    wire [63:0] vec_lsu_complete_fault_addr;
    wire vec_lsu_complete_unsupported;
    wire vec_lsu_retire_ready;
    wire vec_lsu_replay;
    wire vec_lsu_busy;
    wire unused_vec_lsu_fault_addr = |vec_lsu_complete_fault_addr;

    wire vec_read_rf_read_valid;
    wire vec_read_rf_read_ready;
    wire [REG_ADDR_WIDTH-1:0] vec_read_rf_read_addr;
    wire [SLICE_ADDR_WIDTH-1:0] vec_read_rf_read_slice;
    wire [DATAPATH_WIDTH-1:0] vec_read_rf_read_data;
    wire vec_read_rf_write_valid;
    wire vec_read_rf_write_ready;
    wire [REG_ADDR_WIDTH-1:0] vec_read_rf_write_addr;
    wire [SLICE_ADDR_WIDTH-1:0] vec_read_rf_write_slice;
    wire [DATAPATH_WIDTH-1:0] vec_read_rf_write_data;
    wire vec_read_dispatch_ready;
    wire vec_read_complete_valid;
    wire [TAG_WIDTH-1:0] vec_read_complete_tag;
    wire vec_read_complete_fault;
    wire [63:0] vec_read_complete_fault_addr;
    wire vec_read_complete_unsupported;
    wire vec_read_retire_ready;
    wire vec_read_replay;
    wire vec_read_busy;
    wire unused_vec_read_fault_addr = |vec_read_complete_fault_addr;

    wire vec_read_mem_req_valid;
    wire vec_read_mem_req_ready;
    wire [LSU_MEM_TAG_WIDTH-1:0] vec_read_mem_req_tag;
    wire vec_read_mem_req_write;
    wire [63:0] vec_read_mem_req_addr;
    wire [VEC_CACHE_DATA_WIDTH-1:0] vec_read_mem_req_wdata;
    wire [(VEC_CACHE_DATA_WIDTH/8)-1:0] vec_read_mem_req_wstrb;
    wire vec_read_mem_resp_valid;
    wire vec_read_mem_resp_ready;
    wire [LSU_MEM_TAG_WIDTH-1:0] vec_read_mem_resp_tag;
    wire [VEC_CACHE_DATA_WIDTH-1:0] vec_read_mem_resp_rdata;
    wire vec_read_mem_resp_error;
    wire vec_read_mem_resp_retry;

    wire vec_lsu_mem_req_valid;
    wire vec_lsu_mem_req_ready;
    wire [LSU_MEM_TAG_WIDTH-1:0] vec_lsu_mem_req_tag;
    wire vec_lsu_mem_req_write;
    wire [63:0] vec_lsu_mem_req_addr;
    wire [VEC_CACHE_DATA_WIDTH-1:0] vec_lsu_mem_req_wdata;
    wire [(VEC_CACHE_DATA_WIDTH/8)-1:0] vec_lsu_mem_req_wstrb;
    wire vec_lsu_mem_resp_valid;
    wire vec_lsu_mem_resp_ready;
    wire [LSU_MEM_TAG_WIDTH-1:0] vec_lsu_mem_resp_tag;
    wire [VEC_CACHE_DATA_WIDTH-1:0] vec_lsu_mem_resp_rdata;
    wire vec_lsu_mem_resp_error;
    wire vec_lsu_mem_resp_retry;

    wire vec_read_available = !vec_read_active_q &&
                              vec_read_dispatch_ready;
    wire vec_read_dispatch_valid = (state_q == STATE_EXEC) &&
                                   instr_is_vec_load &&
                                   vec_read_available;
    wire vec_read_dispatch_fire = vec_read_dispatch_valid &&
                                  vec_read_dispatch_ready;
    wire vec_lsu_dispatch_valid = (state_q == STATE_EXEC) &&
        (instr_is_vec_store ||
         (instr_is_vec_load && !vec_read_available));
    wire vec_lsu_dispatch_fire = vec_lsu_dispatch_valid &&
                                 vec_lsu_dispatch_ready;
    wire vec_lsu_complete_ready =
        (state_q == STATE_VEC_COMPLETE) && active_vec_is_lsu_q;
    wire vec_lsu_retire_valid =
        (state_q == STATE_VEC_RETIRE) && active_vec_is_lsu_q;
    wire vec_lsu_retire_fire = vec_lsu_retire_valid &&
                               vec_lsu_retire_ready;
    wire vec_lsu_ordered_valid =
        ((state_q == STATE_VEC_COMPLETE) ||
         (state_q == STATE_VEC_RETIRE)) && active_vec_is_lsu_q;

    openrv64_exec_vec_lsu #(
        .VLEN(VLEN), .DATAPATH_WIDTH(DATAPATH_WIDTH),
        .TAG_WIDTH(TAG_WIDTH), .MEM_TAG_WIDTH(LSU_MEM_TAG_WIDTH),
        .MEM_DATA_WIDTH(VEC_CACHE_DATA_WIDTH),
        .QUEUE_DEPTH(1),
        .MAX_LMUL(MAX_LMUL), .LMUL_WIDTH(LMUL_WIDTH)
    ) u_vec_lsu (
        .clk(clk), .rst_n(rst_n),
        .dispatch_valid_i(vec_lsu_dispatch_valid),
        .dispatch_ready_o(vec_lsu_dispatch_ready),
        .dispatch_tag_i(next_tag_q),
        .dispatch_op_i(instr_is_vec_load ? `OPENRV64_VEC_LSU_LOAD :
                                           `OPENRV64_VEC_LSU_STORE),
        .dispatch_base_gpr_i(instr_rs1),
        .dispatch_vreg_i(instr_is_vec_load ? instr_rd : instr_rs2),
        .dispatch_vtype_i(vtype_q),
        .gpr_read_valid_o(vec_lsu_gpr_read_valid),
        .gpr_read_ready_i(vec_lsu_gpr_read_ready),
        .gpr_read_addr_o(vec_lsu_gpr_read_addr),
        .gpr_read_data_i(vec_lsu_gpr_read_data),
        .rf_read_valid_o(vec_lsu_rf_read_valid),
        .rf_read_ready_i(vec_lsu_rf_read_ready),
        .rf_read_addr_o(vec_lsu_rf_read_addr),
        .rf_read_slice_o(vec_lsu_rf_read_slice),
        .rf_read_data_i(vec_lsu_rf_read_data), .operands_ready_i(1'b1),
        .ordered_valid_i(vec_lsu_ordered_valid),
        .ordered_tag_i(active_vec_tag_q),
        .complete_valid_o(vec_lsu_complete_valid),
        .complete_ready_i(vec_lsu_complete_ready),
        .complete_tag_o(vec_lsu_complete_tag),
        .complete_fault_o(vec_lsu_complete_fault),
        .complete_fault_addr_o(vec_lsu_complete_fault_addr),
        .complete_unsupported_o(vec_lsu_complete_unsupported),
        .retire_valid_i(vec_lsu_retire_valid),
        .retire_ready_o(vec_lsu_retire_ready),
        .retire_tag_i(active_vec_tag_q), .retire_kill_i(1'b0),
        .rf_write_valid_o(vec_lsu_rf_write_valid),
        .rf_write_ready_i(vec_lsu_rf_write_ready),
        .rf_write_addr_o(vec_lsu_rf_write_addr),
        .rf_write_slice_o(vec_lsu_rf_write_slice),
        .rf_write_data_o(vec_lsu_rf_write_data),
        .mem_req_valid_o(vec_lsu_mem_req_valid),
        .mem_req_ready_i(vec_lsu_mem_req_ready),
        .mem_req_tag_o(vec_lsu_mem_req_tag),
        .mem_req_write_o(vec_lsu_mem_req_write),
        .mem_req_addr_o(vec_lsu_mem_req_addr),
        .mem_req_wdata_o(vec_lsu_mem_req_wdata),
        .mem_req_wstrb_o(vec_lsu_mem_req_wstrb),
        .mem_resp_valid_i(vec_lsu_mem_resp_valid),
        .mem_resp_ready_o(vec_lsu_mem_resp_ready),
        .mem_resp_tag_i(vec_lsu_mem_resp_tag),
        .mem_resp_rdata_i(vec_lsu_mem_resp_rdata),
        .mem_resp_error_i(vec_lsu_mem_resp_error),
        .mem_resp_retry_i(vec_lsu_mem_resp_retry),
        .replay_o(vec_lsu_replay), .busy_o(vec_lsu_busy)
    );

    // Preferred load path. Its store side is intentionally disabled; stores
    // always use the primary LSU above.
    wire vec_read_complete_ready = vec_read_active_q &&
                                   !vec_read_complete_q;
    wire vec_read_retire_valid = vec_read_active_q &&
                                 vec_read_complete_q;
    openrv64_exec_vec_lsu #(
        .VLEN(VLEN), .DATAPATH_WIDTH(DATAPATH_WIDTH),
        .TAG_WIDTH(TAG_WIDTH), .MEM_TAG_WIDTH(LSU_MEM_TAG_WIDTH),
        .MEM_DATA_WIDTH(VEC_CACHE_DATA_WIDTH),
        .QUEUE_DEPTH(1), .READ_ONLY(1),
        .MAX_LMUL(MAX_LMUL), .LMUL_WIDTH(LMUL_WIDTH)
    ) u_vec_read_lsu (
        .clk(clk), .rst_n(rst_n),
        .dispatch_valid_i(vec_read_dispatch_valid),
        .dispatch_ready_o(vec_read_dispatch_ready),
        .dispatch_tag_i(next_tag_q),
        .dispatch_op_i(`OPENRV64_VEC_LSU_LOAD),
        .dispatch_base_gpr_i(instr_rs1),
        .dispatch_vreg_i(instr_rd),
        .dispatch_vtype_i(vtype_q),
        .gpr_read_valid_o(vec_read_gpr_read_valid),
        .gpr_read_ready_i(vec_read_gpr_read_ready),
        .gpr_read_addr_o(vec_read_gpr_read_addr),
        .gpr_read_data_i(vec_read_gpr_read_data),
        .rf_read_valid_o(vec_read_rf_read_valid),
        .rf_read_ready_i(vec_read_rf_read_ready),
        .rf_read_addr_o(vec_read_rf_read_addr),
        .rf_read_slice_o(vec_read_rf_read_slice),
        .rf_read_data_i(vec_read_rf_read_data), .operands_ready_i(1'b1),
        .ordered_valid_i(1'b0), .ordered_tag_i({TAG_WIDTH{1'b0}}),
        .complete_valid_o(vec_read_complete_valid),
        .complete_ready_i(vec_read_complete_ready),
        .complete_tag_o(vec_read_complete_tag),
        .complete_fault_o(vec_read_complete_fault),
        .complete_fault_addr_o(vec_read_complete_fault_addr),
        .complete_unsupported_o(vec_read_complete_unsupported),
        .retire_valid_i(vec_read_retire_valid),
        .retire_ready_o(vec_read_retire_ready),
        .retire_tag_i(vec_read_tag_q), .retire_kill_i(1'b0),
        .rf_write_valid_o(vec_read_rf_write_valid),
        .rf_write_ready_i(vec_read_rf_write_ready),
        .rf_write_addr_o(vec_read_rf_write_addr),
        .rf_write_slice_o(vec_read_rf_write_slice),
        .rf_write_data_o(vec_read_rf_write_data),
        .mem_req_valid_o(vec_read_mem_req_valid),
        .mem_req_ready_i(vec_read_mem_req_ready),
        .mem_req_tag_o(vec_read_mem_req_tag),
        .mem_req_write_o(vec_read_mem_req_write),
        .mem_req_addr_o(vec_read_mem_req_addr),
        .mem_req_wdata_o(vec_read_mem_req_wdata),
        .mem_req_wstrb_o(vec_read_mem_req_wstrb),
        .mem_resp_valid_i(vec_read_mem_resp_valid),
        .mem_resp_ready_o(vec_read_mem_resp_ready),
        .mem_resp_tag_i(vec_read_mem_resp_tag),
        .mem_resp_rdata_i(vec_read_mem_resp_rdata),
        .mem_resp_error_i(vec_read_mem_resp_error),
        .mem_resp_retry_i(vec_read_mem_resp_retry),
        .replay_o(vec_read_replay), .busy_o(vec_read_busy)
    );

    // The two VLSUs use 256-bit cache-side beats while the exclusive external
    // stream remains DATAPATH_WIDTH wide. The cache owns line-fill tags,
    // external retries, and source routing; adding another VLSU only widens
    // these packed client vectors.
    wire [1:0] vec_cache_client_req_valid =
        {vec_read_mem_req_valid, vec_lsu_mem_req_valid};
    wire [1:0] vec_cache_client_req_ready;
    wire [2*LSU_MEM_TAG_WIDTH-1:0] vec_cache_client_req_tag =
        {vec_read_mem_req_tag, vec_lsu_mem_req_tag};
    wire [1:0] vec_cache_client_req_write =
        {vec_read_mem_req_write, vec_lsu_mem_req_write};
    wire [2*64-1:0] vec_cache_client_req_addr =
        {vec_read_mem_req_addr, vec_lsu_mem_req_addr};
    wire [2*VEC_CACHE_DATA_WIDTH-1:0] vec_cache_client_req_wdata =
        {vec_read_mem_req_wdata, vec_lsu_mem_req_wdata};
    wire [2*(VEC_CACHE_DATA_WIDTH/8)-1:0] vec_cache_client_req_wstrb =
        {vec_read_mem_req_wstrb, vec_lsu_mem_req_wstrb};
    wire [1:0] vec_cache_client_resp_valid;
    wire [1:0] vec_cache_client_resp_ready =
        {vec_read_mem_resp_ready, vec_lsu_mem_resp_ready};
    wire [2*LSU_MEM_TAG_WIDTH-1:0] vec_cache_client_resp_tag;
    wire [2*VEC_CACHE_DATA_WIDTH-1:0] vec_cache_client_resp_rdata;
    wire [1:0] vec_cache_client_resp_error;
    wire [1:0] vec_cache_client_resp_retry;
    wire vec_cache_prefetch_ready;
    wire vec_cache_prefetch_busy;
    wire vec_cache_replay;
    wire vec_cache_busy;

    assign vec_lsu_mem_req_ready = vec_cache_client_req_ready[0];
    assign vec_read_mem_req_ready = vec_cache_client_req_ready[1];
    assign vec_lsu_mem_resp_valid = vec_cache_client_resp_valid[0];
    assign vec_read_mem_resp_valid = vec_cache_client_resp_valid[1];
    assign vec_lsu_mem_resp_tag = vec_cache_client_resp_tag[
        0 +: LSU_MEM_TAG_WIDTH];
    assign vec_read_mem_resp_tag = vec_cache_client_resp_tag[
        LSU_MEM_TAG_WIDTH +: LSU_MEM_TAG_WIDTH];
    assign vec_lsu_mem_resp_rdata = vec_cache_client_resp_rdata[
        0 +: VEC_CACHE_DATA_WIDTH];
    assign vec_read_mem_resp_rdata = vec_cache_client_resp_rdata[
        VEC_CACHE_DATA_WIDTH +: VEC_CACHE_DATA_WIDTH];
    assign vec_lsu_mem_resp_error = vec_cache_client_resp_error[0];
    assign vec_read_mem_resp_error = vec_cache_client_resp_error[1];
    assign vec_lsu_mem_resp_retry = vec_cache_client_resp_retry[0];
    assign vec_read_mem_resp_retry = vec_cache_client_resp_retry[1];

    wire vec_cache_prefetch_valid = (state_q == STATE_EXEC) &&
        instr_is_vprfm && !vec_read_gpr_read_valid &&
        !vec_lsu_gpr_read_valid;

    openrv64_vec_sram_cache #(
        .ADDR_WIDTH(64),
        .CLIENT_DATA_WIDTH(VEC_CACHE_DATA_WIDTH),
        .MEM_DATA_WIDTH(DATAPATH_WIDTH),
        .CLIENTS(2), .CLIENT_TAG_WIDTH(LSU_MEM_TAG_WIDTH),
        .MEM_TAG_WIDTH(MEM_TAG_WIDTH),
        .CACHE_BYTES(VEC_CACHE_BYTES),
        .LINE_BYTES(VEC_CACHE_LINE_BYTES),
        .WAYS(VEC_CACHE_WAYS), .MSHRS(VEC_CACHE_MSHRS)
    ) u_vec_cache (
        .clk(clk), .rst_n(rst_n),
        .client_req_valid_i(vec_cache_client_req_valid),
        .client_req_ready_o(vec_cache_client_req_ready),
        .client_req_tag_i(vec_cache_client_req_tag),
        .client_req_write_i(vec_cache_client_req_write),
        .client_req_addr_i(vec_cache_client_req_addr),
        .client_req_wdata_i(vec_cache_client_req_wdata),
        .client_req_wstrb_i(vec_cache_client_req_wstrb),
        .client_resp_valid_o(vec_cache_client_resp_valid),
        .client_resp_ready_i(vec_cache_client_resp_ready),
        .client_resp_tag_o(vec_cache_client_resp_tag),
        .client_resp_rdata_o(vec_cache_client_resp_rdata),
        .client_resp_error_o(vec_cache_client_resp_error),
        .client_resp_retry_o(vec_cache_client_resp_retry),
        .prefetch_valid_i(vec_cache_prefetch_valid),
        .prefetch_ready_o(vec_cache_prefetch_ready),
        .prefetch_addr_i(gpr_rs1_data),
        .prefetch_count_i(instr_q[23:20]),
        .prefetch_streaming_i(
            instr_funct3 ==
            `OPENRV64_VEC_INSTR_FUNCT3_VPRFM_STREAM),
        .prefetch_busy_o(vec_cache_prefetch_busy),
        .mem_req_valid_o(vec_mem_req_valid_o),
        .mem_req_ready_i(vec_mem_req_ready_i),
        .mem_req_tag_o(vec_mem_req_tag_o),
        .mem_req_write_o(vec_mem_req_write_o),
        .mem_req_addr_o(vec_mem_req_addr_o),
        .mem_req_wdata_o(vec_mem_req_wdata_o),
        .mem_req_wstrb_o(vec_mem_req_wstrb_o),
        .mem_resp_valid_i(vec_mem_resp_valid_i),
        .mem_resp_ready_o(vec_mem_resp_ready_o),
        .mem_resp_tag_i(vec_mem_resp_tag_i),
        .mem_resp_rdata_i(vec_mem_resp_rdata_i),
        .mem_resp_error_i(vec_mem_resp_error_i),
        .mem_resp_retry_i(vec_mem_resp_retry_i),
        .replay_o(vec_cache_replay), .busy_o(vec_cache_busy)
    );

    wire [3:0] vec_rf_read_valid =
        {vec_read_rf_read_valid, vec_lsu_rf_read_valid,
         vec_alu_rf_read_valid};
    wire [3:0] vec_rf_read_ready;
    wire [4*REG_ADDR_WIDTH-1:0] vec_rf_read_addr =
        {vec_read_rf_read_addr, vec_lsu_rf_read_addr,
         vec_alu_rf_read_addr};
    wire [4*SLICE_ADDR_WIDTH-1:0] vec_rf_read_slice =
        {vec_read_rf_read_slice, vec_lsu_rf_read_slice,
         vec_alu_rf_read_slice};
    wire [4*DATAPATH_WIDTH-1:0] vec_rf_read_data;
    assign vec_alu_rf_read_ready = vec_rf_read_ready[1:0];
    assign vec_alu_rf_read_data =
        vec_rf_read_data[0 +: 2*DATAPATH_WIDTH];
    assign vec_lsu_rf_read_ready = vec_rf_read_ready[2];
    assign vec_lsu_rf_read_data =
        vec_rf_read_data[2*DATAPATH_WIDTH +: DATAPATH_WIDTH];
    assign vec_read_rf_read_ready = vec_rf_read_ready[3];
    assign vec_read_rf_read_data =
        vec_rf_read_data[3*DATAPATH_WIDTH +: DATAPATH_WIDTH];

    // Arithmetic writeback may now overlap a blocking primary load. The
    // primary LSU wins logical port zero so the frontend cannot be starved;
    // the arithmetic result context holds its slice until ready returns.
    // The background load owns port one, with the RF enforcing parity-bank
    // conflicts between the selected writes.
    wire vec_foreground_write_valid = vec_lsu_rf_write_valid ||
                                      vec_alu_rf_write_valid;
    wire [REG_ADDR_WIDTH-1:0] vec_foreground_write_addr =
        vec_lsu_rf_write_valid ? vec_lsu_rf_write_addr :
                                 vec_alu_rf_write_addr;
    wire [SLICE_ADDR_WIDTH-1:0] vec_foreground_write_slice =
        vec_lsu_rf_write_valid ? vec_lsu_rf_write_slice :
                                 vec_alu_rf_write_slice;
    wire [DATAPATH_WIDTH-1:0] vec_foreground_write_data =
        vec_lsu_rf_write_valid ? vec_lsu_rf_write_data :
                                 vec_alu_rf_write_data;
    wire [1:0] vec_rf_write_valid =
        {vec_read_rf_write_valid, vec_foreground_write_valid};
    wire [1:0] vec_rf_write_ready;
    wire [2*REG_ADDR_WIDTH-1:0] vec_rf_write_addr =
        {vec_read_rf_write_addr, vec_foreground_write_addr};
    wire [2*SLICE_ADDR_WIDTH-1:0] vec_rf_write_slice =
        {vec_read_rf_write_slice, vec_foreground_write_slice};
    wire [2*DATAPATH_WIDTH-1:0] vec_rf_write_data =
        {vec_read_rf_write_data, vec_foreground_write_data};
    assign vec_alu_rf_write_ready = !vec_lsu_rf_write_valid &&
                                    vec_rf_write_ready[0];
    assign vec_lsu_rf_write_ready = vec_rf_write_ready[0];
    assign vec_read_rf_write_ready = vec_rf_write_ready[1];

    openrv64_rv64i_vec #(
        .VLEN(VLEN), .SLICE_WIDTH(DATAPATH_WIDTH)
    ) u_vec_regs (
        .clk(clk), .rst_n(rst_n),
        .read_valid_i(vec_rf_read_valid),
        .read_ready_o(vec_rf_read_ready),
        .read_addr_i(vec_rf_read_addr),
        .read_slice_i(vec_rf_read_slice),
        .read_data_o(vec_rf_read_data),
        .write_valid_i(vec_rf_write_valid),
        .write_ready_o(vec_rf_write_ready),
        .write_addr_i(vec_rf_write_addr),
        .write_slice_i(vec_rf_write_slice),
        .write_data_i(vec_rf_write_data)
    );

    assign dbg_vec_busy_o = vec_alu_busy || vec_lsu_busy || vec_read_busy ||
                            vec_cache_busy;
    assign dbg_vec_replay_o = vec_alu_replay || vec_lsu_replay ||
                              vec_read_replay || vec_cache_replay;

    // Only the primary LSU uses the blocking complete/retire frontend states.
    // Arithmetic completion and writeback proceed independently below.
    wire selected_vec_complete_valid = vec_lsu_complete_valid;
    wire [TAG_WIDTH-1:0] selected_vec_complete_tag =
        vec_lsu_complete_tag;
    wire selected_vec_complete_error =
        vec_lsu_complete_fault || vec_lsu_complete_unsupported;
    wire selected_vec_retire_ready = vec_lsu_retire_ready;

    wire vec_read_complete_fire = vec_read_complete_valid &&
                                  vec_read_complete_ready;
    wire vec_read_retire_fire = vec_read_retire_valid &&
                                vec_read_retire_ready;
    logic [NUM_VEC_REGS-1:0] pending_vec_write_mask;
    integer pending_writer_index;
    always_comb begin
        pending_vec_write_mask = {NUM_VEC_REGS{1'b0}};
        if (vec_read_active_q)
            pending_vec_write_mask = pending_vec_write_mask |
                vec_group_mask(vec_read_vd_q, vec_read_lmul_q);
        if (active_vec_writes_q)
            pending_vec_write_mask = pending_vec_write_mask |
                                     active_vec_write_mask_q;
        for (pending_writer_index = 0;
             pending_writer_index < VEC_INFLIGHT_DEPTH;
             pending_writer_index = pending_writer_index + 1)
            if (vec_alu_write_valid_q[pending_writer_index])
                pending_vec_write_mask = pending_vec_write_mask |
                    vec_alu_write_mask_q[pending_writer_index];
    end
    wire vsync_wait = pending_vec_write_mask[instr_rs1] ||
                      pending_vec_write_mask[instr_rs2];

    integer vec_writer_reset_index;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vec_alu_retire_pending_q <= 1'b0;
            vec_alu_retire_tag_q <= {TAG_WIDTH{1'b0}};
            vec_alu_retire_error_q <= 1'b0;
            vec_alu_retired_q <= 64'd0;
            vec_alu_write_tail_q <= {VEC_QUEUE_PTR_WIDTH{1'b0}};
            vec_alu_write_head_q <= {VEC_QUEUE_PTR_WIDTH{1'b0}};
            for (vec_writer_reset_index = 0;
                 vec_writer_reset_index < VEC_INFLIGHT_DEPTH;
                 vec_writer_reset_index = vec_writer_reset_index + 1) begin
                vec_alu_write_valid_q[vec_writer_reset_index] <= 1'b0;
                vec_alu_write_mask_q[vec_writer_reset_index] <=
                    {NUM_VEC_REGS{1'b0}};
                vec_alu_write_tag_q[vec_writer_reset_index] <=
                    {TAG_WIDTH{1'b0}};
            end
        end else begin
            if (vec_alu_dispatch_fire) begin
                vec_alu_write_valid_q[vec_alu_write_tail_q] <= 1'b1;
                vec_alu_write_mask_q[vec_alu_write_tail_q] <=
                    decoded_vec_writes_vreg ?
                    vec_group_mask(instr_rd, vtype_q[
                        `OPENRV64_VEC_VTYPE_VLMUL_LSB +: LMUL_WIDTH]) :
                    {NUM_VEC_REGS{1'b0}};
                vec_alu_write_tag_q[vec_alu_write_tail_q] <= next_tag_q;
                vec_alu_write_tail_q <= vec_alu_write_tail_q + 1'b1;
            end
            if (vec_alu_complete_fire) begin
                vec_alu_retire_pending_q <= 1'b1;
                vec_alu_retire_tag_q <= vec_alu_complete_tag;
                vec_alu_retire_error_q <= vec_alu_complete_unsupported;
            end
            if (vec_alu_retire_fire) begin
                vec_alu_retire_pending_q <= 1'b0;
                vec_alu_retired_q <= vec_alu_retired_q + 64'd1;
                vec_alu_write_valid_q[vec_alu_write_head_q] <= 1'b0;
                vec_alu_write_head_q <= vec_alu_write_head_q + 1'b1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= STATE_FETCH;
            pc_q <= RESET_VECTOR;
            instr_q <= `RV64_INSTR_NOP;
            vtype_q <= 64'd0;
            next_tag_q <= {{(TAG_WIDTH-1){1'b0}}, 1'b1};
            active_vec_tag_q <= {TAG_WIDTH{1'b0}};
            active_vec_is_lsu_q <= 1'b0;
            active_vec_error_q <= 1'b0;
            active_vec_writes_q <= 1'b0;
            active_vec_write_mask_q <= {NUM_VEC_REGS{1'b0}};
            vec_read_active_q <= 1'b0;
            vec_read_complete_q <= 1'b0;
            vec_read_error_q <= 1'b0;
            vec_read_tag_q <= {TAG_WIDTH{1'b0}};
            vec_read_vd_q <= {REG_ADDR_WIDTH{1'b0}};
            vec_read_lmul_q <= {LMUL_WIDTH{1'b0}};
            vec_read_retired_q <= 64'd0;
            halted_q <= 1'b0;
            error_q <= 1'b0;
            retired_q <= 64'd0;
        end else begin
            if (vec_read_dispatch_fire) begin
                vec_read_active_q <= 1'b1;
                vec_read_complete_q <= 1'b0;
                vec_read_error_q <= 1'b0;
                vec_read_tag_q <= next_tag_q;
                vec_read_vd_q <= instr_rd;
                vec_read_lmul_q <= vtype_q[
                    `OPENRV64_VEC_VTYPE_VLMUL_LSB +: LMUL_WIDTH];
                next_tag_q <= next_tag_q + 1'b1;
            end
            if (vec_read_complete_fire) begin
                vec_read_complete_q <= 1'b1;
                vec_read_error_q <= vec_read_complete_fault ||
                                    vec_read_complete_unsupported;
            end
            if (vec_read_retire_fire) begin
                vec_read_active_q <= 1'b0;
                vec_read_complete_q <= 1'b0;
                vec_read_retired_q <= vec_read_retired_q + 64'd1;
            end
            if (vec_lsu_dispatch_fire) begin
                active_vec_writes_q <= instr_is_vec_load;
                active_vec_write_mask_q <= instr_is_vec_load ?
                    vec_group_mask(instr_rd, vtype_q[
                        `OPENRV64_VEC_VTYPE_VLMUL_LSB +: LMUL_WIDTH]) :
                    {NUM_VEC_REGS{1'b0}};
            end
            if (vec_lsu_retire_fire) begin
                active_vec_writes_q <= 1'b0;
                active_vec_write_mask_q <= {NUM_VEC_REGS{1'b0}};
            end

            case (state_q)
                STATE_FETCH: begin
                    if (ifetch_valid_o && ifetch_ready_i) begin
                        if (ifetch_error_i) begin
                            halted_q <= 1'b1;
                            error_q <= 1'b1;
                            state_q <= STATE_HALT;
                        end else begin
                            instr_q <= pc_q[2] ? ifetch_rdata_i[63:32] :
                                                ifetch_rdata_i[31:0];
                            state_q <= STATE_EXEC;
                        end
                    end
                end

                STATE_EXEC: begin
                    if (instr_q == `RV64_INSTR_EBREAK) begin
                        if (!dbg_vec_busy_o) begin
                            halted_q <= 1'b1;
                            state_q <= STATE_HALT;
                        end
                    end else if (instr_is_vset) begin
                        vtype_q <= gpr_rs1_data;
                        pc_q <= pc_q + 64'd4;
                        retired_q <= retired_q + 64'd1;
                        state_q <= STATE_FETCH;
                    end else if (instr_is_vsync) begin
                        if (!vsync_wait) begin
                            pc_q <= pc_q + 64'd4;
                            retired_q <= retired_q + 64'd1;
                            state_q <= STATE_FETCH;
                        end
                    end else if (instr_is_vprfm) begin
                        if (vec_cache_prefetch_valid &&
                            vec_cache_prefetch_ready) begin
                            pc_q <= pc_q + 64'd4;
                            retired_q <= retired_q + 64'd1;
                            state_q <= STATE_FETCH;
                        end
                    end else if (instr_is_vec_arith) begin
                        if (vec_alu_dispatch_ready) begin
                            next_tag_q <= next_tag_q + 1'b1;
                            pc_q <= pc_q + 64'd4;
                            state_q <= STATE_FETCH;
                        end
                    end else if (instr_is_vec_load || instr_is_vec_store) begin
                        if (vec_read_dispatch_fire) begin
                            pc_q <= pc_q + 64'd4;
                            state_q <= STATE_FETCH;
                        end else if (vec_lsu_dispatch_ready) begin
                            active_vec_tag_q <= next_tag_q;
                            next_tag_q <= next_tag_q + 1'b1;
                            active_vec_is_lsu_q <= 1'b1;
                            active_vec_error_q <= 1'b0;
                            state_q <= STATE_VEC_COMPLETE;
                        end
                    end else if (scalar_alu_selected) begin
                        if (!scalar_alu_valid || scalar_alu_illegal) begin
                            halted_q <= 1'b1;
                            error_q <= 1'b1;
                            state_q <= STATE_HALT;
                        end else begin
                            pc_q <= pc_q + 64'd4;
                            retired_q <= retired_q + 64'd1;
                            state_q <= STATE_FETCH;
                        end
                    end else if (scalar_branch_selected) begin
                        if (!scalar_br_valid || scalar_br_illegal ||
                            (scalar_br_taken &&
                             (scalar_br_target[1:0] != 0))) begin
                            halted_q <= 1'b1;
                            error_q <= 1'b1;
                            state_q <= STATE_HALT;
                        end else begin
                            pc_q <= scalar_br_target;
                            retired_q <= retired_q + 64'd1;
                            state_q <= STATE_FETCH;
                        end
                    end else begin
                        halted_q <= 1'b1;
                        error_q <= 1'b1;
                        state_q <= STATE_HALT;
                    end
                end

                STATE_VEC_COMPLETE: begin
                    if (selected_vec_complete_valid) begin
                        if (selected_vec_complete_tag != active_vec_tag_q) begin
                            halted_q <= 1'b1;
                            error_q <= 1'b1;
                            state_q <= STATE_HALT;
                        end else begin
                            active_vec_error_q <=
                                selected_vec_complete_error;
                            state_q <= STATE_VEC_RETIRE;
                        end
                    end
                end

                STATE_VEC_RETIRE: begin
                    if (selected_vec_retire_ready) begin
                        pc_q <= pc_q + 64'd4;
                        retired_q <= retired_q + 64'd1;
                        if (active_vec_error_q) begin
                            halted_q <= 1'b1;
                            error_q <= 1'b1;
                            state_q <= STATE_HALT;
                        end else begin
                            state_q <= STATE_FETCH;
                        end
                    end
                end

                default: begin
                    state_q <= STATE_HALT;
                end
            endcase

            if (vec_read_complete_fire &&
                (vec_read_complete_tag != vec_read_tag_q)) begin
                halted_q <= 1'b1;
                error_q <= 1'b1;
                state_q <= STATE_HALT;
            end else if (vec_read_retire_fire && vec_read_error_q) begin
                halted_q <= 1'b1;
                error_q <= 1'b1;
                state_q <= STATE_HALT;
            end else if (vec_alu_retire_fire &&
                         vec_alu_retire_error_q) begin
                halted_q <= 1'b1;
                error_q <= 1'b1;
                state_q <= STATE_HALT;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (DATAPATH_WIDTH != 64)
            $fatal(1, "initial vector test top requires 64-bit datapath");
        if ((VLEN < DATAPATH_WIDTH) ||
            ((VLEN % DATAPATH_WIDTH) != 0))
            $fatal(1, "VLEN must be a multiple of DATAPATH_WIDTH");
        if (VEC_CACHE_DATA_WIDTH < DATAPATH_WIDTH ||
            ((VEC_CACHE_DATA_WIDTH % DATAPATH_WIDTH) != 0))
            $fatal(1, "vector-cache width must contain whole RF slices");
        if (MEM_TAG_WIDTH < ((VEC_CACHE_MSHRS <= 1) ? 1 :
                            $clog2(VEC_CACHE_MSHRS)))
            $fatal(1, "external tag width is too narrow for cache MSHRs");
        if ((VEC_INFLIGHT_DEPTH < 2) ||
            ((VEC_INFLIGHT_DEPTH & (VEC_INFLIGHT_DEPTH - 1)) != 0))
            $fatal(1, "vector in-flight depth must be a power of two >= 2");
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (vec_read_mem_req_valid && vec_read_mem_req_write)
                $fatal(1, "read-only vector LSU attempted a store");
            if (vec_alu_dispatch_fire &&
                vec_alu_write_valid_q[vec_alu_write_tail_q])
                $fatal(1, "vector write-owner queue overflow");
            if (vec_alu_retire_fire &&
                (!vec_alu_write_valid_q[vec_alu_write_head_q] ||
                 (vec_alu_write_tag_q[vec_alu_write_head_q] !=
                  vec_alu_retire_tag_q)))
                $fatal(1, "vector write-owner retirement mismatch");
        end
    end
`endif

endmodule
