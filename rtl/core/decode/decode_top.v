`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/early-defs.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"

module openrv64_decode_top #(
    parameter ENABLE_RV64M = 1,
    parameter ENABLE_RV64ZBB = 0,
    parameter ENABLE_RV64A = 1,
    parameter ENABLE_RV64C = 0,
    parameter ENABLE_EXTENSION = 0,
    parameter integer EXTENSION_PAYLOAD_WIDTH = 1
) (
    input  wire [`RV64_INSTR_WIDTH-1:0] instr_i,

    // Optional extension response.  The instruction remains illegal unless
    // an enabled extension decoder claims the generic candidate.
    input  wire                         extension_selected_i,
    input  wire                         extension_valid_i,
    input  wire                         extension_illegal_i,
    input  wire [`RV64_EARLY_CLASS_WIDTH-1:0] extension_class_sel_i,
    input  wire [`RV64_EARLY_FORMAT_WIDTH-1:0] extension_format_sel_i,
    input  wire                         extension_uses_rs1_i,
    input  wire                         extension_uses_rs2_i,
    input  wire                         extension_uses_rd_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] extension_rs1_addr_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] extension_rs2_addr_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0] extension_rd_addr_i,
    input  wire                         extension_reg_write_i,
    input  wire                         extension_imm_valid_i,
    input  wire                         extension_has_imm_i,
    input  wire [`RV64_XLEN-1:0]        extension_imm_i,
    input  wire                         extension_mem_read_i,
    input  wire                         extension_mem_write_i,
    input  wire [`RV64_LSU_OP_WIDTH-1:0] extension_lsu_op_sel_i,
    input  wire [`RV64_LSU_SIZE_WIDTH-1:0] extension_lsu_size_sel_i,
    input  wire                         extension_lsu_unsigned_i,
    input  wire [EXTENSION_PAYLOAD_WIDTH-1:0] extension_payload_i,

    output wire                         valid_o,
    output wire                         illegal_o,
    output wire [`RV64_OPCODE_WIDTH-1:0] opcode_o,
    output wire [`RV64_FUNCT3_WIDTH-1:0] funct3_o,
    output wire [`RV64_FUNCT7_WIDTH-1:0] funct7_o,
    output wire [`RV64_FUNCT12_WIDTH-1:0] funct12_o,
    output wire [`RV64_EARLY_CLASS_WIDTH-1:0] class_sel_o,
    output wire [`RV64_EARLY_FORMAT_WIDTH-1:0] format_sel_o,

    // Every field of the decode result describes the canonical 32-bit
    // instruction.  When ENABLE_RV64C expands a compressed parcel, the
    // consumer must carry compressed_o/instr_bytes_o with the result:
    // sequential PCs and link values advance by the parcel length, not
    // by the canonical instruction's four bytes.
    output wire                         compressed_o,
    output wire [2:0]                   instr_bytes_o,

    output wire                         uses_rs1_o,
    output wire                         uses_rs2_o,
    output wire                         uses_rd_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] rd_addr_o,
    output wire                         reg_write_o,

    output wire                         imm_valid_o,
    output wire                         has_imm_o,
    output wire [`RV64_XLEN-1:0]        imm_o,

    output wire                         mem_read_o,
    output wire                         mem_write_o,
    output wire                         branch_o,
    output wire                         jump_o,
    output wire                         word_op_o,
    output wire                         system_o,
    output wire                         fence_o,

    output wire [`RV64_ALU_EXT_WIDTH-1:0] alu_ext_sel_o,
    output wire [`RV64_ALU_OP_WIDTH-1:0] alu_op_sel_o,
    output wire [`RV64_LSU_OP_WIDTH-1:0] lsu_op_sel_o,
    output wire [`RV64_LSU_SIZE_WIDTH-1:0] lsu_size_sel_o,
    output wire                         lsu_unsigned_o,
    output wire [`RV64_BR_OP_WIDTH-1:0] br_op_sel_o,
    output wire                         br_link_o,
    output wire                         br_indirect_o,

    output wire                         subdecode_needed_o,
    output wire                         extension_decode_possible_o,
    output wire                         extension_candidate_o,
    output wire                         extension_instr_o,
    output wire [EXTENSION_PAYLOAD_WIDTH-1:0] extension_payload_o
);

    wire early_valid;
    wire [`RV64_EARLY_CLASS_WIDTH-1:0] early_class_sel;
    wire [`RV64_EARLY_FORMAT_WIDTH-1:0] early_format_sel;
    wire early_uses_rs1;
    wire early_uses_rs2;
    wire early_uses_rd;
    wire early_reg_write;
    wire early_mem_read;
    wire early_mem_write;
    wire early_branch;
    wire early_jump;
    wire early_word_op;
    wire early_subdecode_needed;
    wire early_extension_decode_possible;

    // Early flags a compressed parcel with the C format on the raw opcode.
    // That flag routes decode through the RVC expander: the canonical word
    // is classified by a second early pass and feeds every subdecoder, so
    // nothing below this point knows about compressed encodings.
    wire rvc_candidate = early_valid &&
                         (early_format_sel == `RV64_EARLY_FORMAT_C);
    wire rvc_selected = (ENABLE_RV64C != 0) && rvc_candidate;

    wire [`RV64_INSTR_WIDTH-1:0] rvc_canonical;
    wire rvc_compressed;
    wire rvc_illegal;
    wire [2:0] rvc_instr_bytes;
    wire rvc_early_valid;
    wire [`RV64_EARLY_CLASS_WIDTH-1:0] rvc_class_sel;
    wire [`RV64_EARLY_FORMAT_WIDTH-1:0] rvc_format_sel;
    wire rvc_uses_rs1;
    wire rvc_uses_rs2;
    wire rvc_uses_rd;
    wire rvc_reg_write;
    wire rvc_mem_read;
    wire rvc_mem_write;
    wire rvc_branch;
    wire rvc_jump;
    wire rvc_word_op;
    wire rvc_subdecode_needed;

    // The expander's illegal report also covers 48-bit-or-longer prefixes,
    // which it rejects because ILEN is 32.
    wire rvc_reject = (ENABLE_RV64C != 0) && rvc_illegal;

    wire [`RV64_INSTR_WIDTH-1:0] canonical_instr = rvc_selected ?
                                                   rvc_canonical : instr_i;

    wire eff_valid = rvc_selected ? rvc_early_valid :
                     (early_valid && !rvc_candidate);
    wire [`RV64_EARLY_CLASS_WIDTH-1:0] eff_class_sel =
        rvc_selected ? rvc_class_sel : early_class_sel;
    wire [`RV64_EARLY_FORMAT_WIDTH-1:0] eff_format_sel =
        rvc_selected ? rvc_format_sel : early_format_sel;
    wire eff_uses_rs1 = rvc_selected ? rvc_uses_rs1 : early_uses_rs1;
    wire eff_uses_rs2 = rvc_selected ? rvc_uses_rs2 : early_uses_rs2;
    wire eff_uses_rd = rvc_selected ? rvc_uses_rd : early_uses_rd;
    wire eff_reg_write = rvc_selected ? rvc_reg_write : early_reg_write;
    wire eff_mem_read = rvc_selected ? rvc_mem_read : early_mem_read;
    wire eff_mem_write = rvc_selected ? rvc_mem_write : early_mem_write;
    wire eff_branch = rvc_selected ? rvc_branch : early_branch;
    wire eff_jump = rvc_selected ? rvc_jump : early_jump;
    wire eff_word_op = rvc_selected ? rvc_word_op : early_word_op;
    wire eff_subdecode_needed = rvc_selected ? rvc_subdecode_needed :
                                early_subdecode_needed;
    // Expanded parcels are always base RV64I, and extension decoders see the
    // raw instruction word, so a routed parcel is never offered to them.
    wire eff_extension_decode_possible = !rvc_selected &&
                                         early_extension_decode_possible;

    wire [`RV64_OPCODE_WIDTH-1:0] opcode = `RV64_OPCODE(canonical_instr);
    wire [`RV64_FUNCT3_WIDTH-1:0] funct3 = `RV64_FUNCT3(canonical_instr);
    wire [`RV64_FUNCT7_WIDTH-1:0] funct7 = `RV64_FUNCT7(canonical_instr);
    wire [`RV64_FUNCT12_WIDTH-1:0] funct12 = `RV64_FUNCT12(canonical_instr);

    wire imm_decode_valid;
    wire imm_decode_has_imm;
    wire [`RV64_XLEN-1:0] imm_decode_value;
    wire [`RV64_XLEN-1:0] unused_imm_i;
    wire [`RV64_XLEN-1:0] unused_imm_s;
    wire [`RV64_XLEN-1:0] unused_imm_b;
    wire [`RV64_XLEN-1:0] unused_imm_u;
    wire [`RV64_XLEN-1:0] unused_imm_j;

    wire alu_valid;
    wire alu_illegal;
    wire [`RV64_ALU_EXT_WIDTH-1:0] alu_ext_sel;
    wire [`RV64_ALU_OP_WIDTH-1:0] alu_op_sel;
    wire alu_word_op;

    wire lsu_valid;
    wire lsu_illegal;
    wire [`RV64_LSU_OP_WIDTH-1:0] lsu_op_sel;
    wire [`RV64_LSU_SIZE_WIDTH-1:0] lsu_size_sel;
    wire lsu_load;
    wire lsu_store;
    wire lsu_unsigned;

    wire br_valid;
    wire br_illegal;
    wire [`RV64_BR_OP_WIDTH-1:0] br_op_sel;
    wire br_branch;
    wire br_jump;
    wire br_link;
    wire br_indirect;

    wire system_valid;
    wire system_illegal;
    wire system_csr;
    wire system_ecall;
    wire system_ebreak;
    wire system_sret;
    wire system_mret;

    wire fence_valid;
    wire fence_illegal;

    wire reg_alu_valid;
    wire reg_alu_uses_rs1;
    wire reg_alu_uses_rs2;
    wire reg_alu_uses_rd;
    wire [`RV64_REG_ADDR_WIDTH-1:0] reg_alu_rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] reg_alu_rs2_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] reg_alu_rd_addr;

    wire reg_lsu_valid;
    wire reg_lsu_uses_rs1;
    wire reg_lsu_uses_rs2;
    wire reg_lsu_uses_rd;
    wire [`RV64_REG_ADDR_WIDTH-1:0] reg_lsu_rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] reg_lsu_rs2_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] reg_lsu_rd_addr;

    wire reg_system_valid;
    wire reg_system_uses_rs1;
    wire reg_system_uses_rs2;
    wire reg_system_uses_rd;
    wire [`RV64_REG_ADDR_WIDTH-1:0] reg_system_rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] reg_system_rs2_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] reg_system_rd_addr;
    wire unused_system_decode = |{
        system_csr,
        system_ecall,
        system_ebreak,
        system_sret,
        system_mret
    };

    wire class_is_alu = (eff_class_sel == `RV64_EARLY_CLASS_ALU);
    wire class_is_mem = (eff_class_sel == `RV64_EARLY_CLASS_MEM);
    wire class_is_branch = (eff_class_sel == `RV64_EARLY_CLASS_BRANCH);
    wire class_is_jump = (eff_class_sel == `RV64_EARLY_CLASS_JUMP);
    wire class_is_brjump = class_is_branch || class_is_jump;
    wire class_is_system = (eff_class_sel == `RV64_EARLY_CLASS_SYSTEM);
    wire class_is_fence = (eff_class_sel == `RV64_EARLY_CLASS_FENCE);
    wire extension_candidate = eff_valid &&
                               eff_extension_decode_possible &&
                               !rvc_reject;
    wire extension_selected = (ENABLE_EXTENSION != 0) ?
        (extension_candidate && extension_selected_i) : 1'b0;

    reg selected_decode_valid;
    reg selected_decode_illegal;
    reg selected_reg_valid;
    reg selected_uses_rs1;
    reg selected_uses_rs2;
    reg selected_uses_rd;
    reg [`RV64_REG_ADDR_WIDTH-1:0] selected_rs1_addr;
    reg [`RV64_REG_ADDR_WIDTH-1:0] selected_rs2_addr;
    reg [`RV64_REG_ADDR_WIDTH-1:0] selected_rd_addr;

    openrv64_decode_early u_early (
        .opcode_i(`RV64_OPCODE(instr_i)),
        .valid_o(early_valid),
        .class_sel_o(early_class_sel),
        .format_sel_o(early_format_sel),
        .uses_rs1_o(early_uses_rs1),
        .uses_rs2_o(early_uses_rs2),
        .uses_rd_o(early_uses_rd),
        .reg_write_o(early_reg_write),
        .mem_read_o(early_mem_read),
        .mem_write_o(early_mem_write),
        .branch_o(early_branch),
        .jump_o(early_jump),
        .word_op_o(early_word_op),
        .subdecode_needed_o(early_subdecode_needed),
        .extension_decode_possible_o(early_extension_decode_possible)
    );

    generate
        if (ENABLE_RV64C != 0) begin : g_rvc
            wire rvc_unsupported_length;
            wire rvc_extension_decode_possible;
            // instr_bytes_o already reports an unsupported length as zero
            // bytes, and the expander folds it into its illegal report.
            wire unused_rvc = |{
                rvc_unsupported_length,
                rvc_extension_decode_possible
            };

            openrv64_decode_rv64c u_rvc (
                .instr_i(instr_i),
                .instr_o(rvc_canonical),
                .compressed_o(rvc_compressed),
                .illegal_o(rvc_illegal),
                .unsupported_length_o(rvc_unsupported_length),
                .instr_bytes_o(rvc_instr_bytes)
            );

            openrv64_decode_early u_early_rvc (
                .opcode_i(`RV64_OPCODE(rvc_canonical)),
                .valid_o(rvc_early_valid),
                .class_sel_o(rvc_class_sel),
                .format_sel_o(rvc_format_sel),
                .uses_rs1_o(rvc_uses_rs1),
                .uses_rs2_o(rvc_uses_rs2),
                .uses_rd_o(rvc_uses_rd),
                .reg_write_o(rvc_reg_write),
                .mem_read_o(rvc_mem_read),
                .mem_write_o(rvc_mem_write),
                .branch_o(rvc_branch),
                .jump_o(rvc_jump),
                .word_op_o(rvc_word_op),
                .subdecode_needed_o(rvc_subdecode_needed),
                .extension_decode_possible_o(rvc_extension_decode_possible)
            );
        end else begin : g_no_rvc
            assign rvc_canonical = instr_i;
            assign rvc_compressed = 1'b0;
            assign rvc_illegal = 1'b0;
            assign rvc_instr_bytes = 3'd4;
            assign rvc_early_valid = 1'b0;
            assign rvc_class_sel = `RV64_EARLY_CLASS_INVALID;
            assign rvc_format_sel = `RV64_EARLY_FORMAT_INVALID;
            assign rvc_uses_rs1 = 1'b0;
            assign rvc_uses_rs2 = 1'b0;
            assign rvc_uses_rd = 1'b0;
            assign rvc_reg_write = 1'b0;
            assign rvc_mem_read = 1'b0;
            assign rvc_mem_write = 1'b0;
            assign rvc_branch = 1'b0;
            assign rvc_jump = 1'b0;
            assign rvc_word_op = 1'b0;
            assign rvc_subdecode_needed = 1'b0;
        end
    endgenerate

    openrv64_decode_imm u_imm (
        .instr_i(canonical_instr),
        .format_sel_i(eff_format_sel),
        .valid_o(imm_decode_valid),
        .has_imm_o(imm_decode_has_imm),
        .imm_o(imm_decode_value),
        .imm_i_o(unused_imm_i),
        .imm_s_o(unused_imm_s),
        .imm_b_o(unused_imm_b),
        .imm_u_o(unused_imm_u),
        .imm_j_o(unused_imm_j)
    );

    openrv64_decode_alu #(
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_RV64ZBB(ENABLE_RV64ZBB)
    ) u_alu (
        .opcode_i(opcode),
        .funct3_i(funct3),
        .funct7_i(funct7),
        .funct12_i(funct12),
        .valid_o(alu_valid),
        .illegal_o(alu_illegal),
        .ext_sel_o(alu_ext_sel),
        .op_sel_o(alu_op_sel),
        .word_op_o(alu_word_op)
    );

    openrv64_decode_lsu #(
        .ENABLE_RV64A(ENABLE_RV64A)
    ) u_lsu (
        .instr_i(canonical_instr),
        .valid_o(lsu_valid),
        .illegal_o(lsu_illegal),
        .op_sel_o(lsu_op_sel),
        .size_sel_o(lsu_size_sel),
        .load_o(lsu_load),
        .store_o(lsu_store),
        .unsigned_o(lsu_unsigned)
    );

    openrv64_decode_br u_br (
        .opcode_i(opcode),
        .funct3_i(funct3),
        .valid_o(br_valid),
        .illegal_o(br_illegal),
        .op_sel_o(br_op_sel),
        .branch_o(br_branch),
        .jump_o(br_jump),
        .link_o(br_link),
        .indirect_o(br_indirect)
    );

    openrv64_decode_system u_system (
        .instr_i(canonical_instr),
        .valid_o(system_valid),
        .illegal_o(system_illegal),
        .csr_o(system_csr),
        .ecall_o(system_ecall),
        .ebreak_o(system_ebreak),
        .sret_o(system_sret),
        .mret_o(system_mret)
    );

    openrv64_decode_fence u_fence (
        .opcode_i(opcode),
        .funct3_i(funct3),
        .valid_o(fence_valid),
        .illegal_o(fence_illegal)
    );

    openrv64_decode_reg_alu u_reg_alu (
        .instr_i(canonical_instr),
        .valid_o(reg_alu_valid),
        .uses_rs1_o(reg_alu_uses_rs1),
        .uses_rs2_o(reg_alu_uses_rs2),
        .uses_rd_o(reg_alu_uses_rd),
        .rs1_addr_o(reg_alu_rs1_addr),
        .rs2_addr_o(reg_alu_rs2_addr),
        .rd_addr_o(reg_alu_rd_addr)
    );

    openrv64_decode_reg_lsu u_reg_lsu (
        .instr_i(canonical_instr),
        .valid_o(reg_lsu_valid),
        .uses_rs1_o(reg_lsu_uses_rs1),
        .uses_rs2_o(reg_lsu_uses_rs2),
        .uses_rd_o(reg_lsu_uses_rd),
        .rs1_addr_o(reg_lsu_rs1_addr),
        .rs2_addr_o(reg_lsu_rs2_addr),
        .rd_addr_o(reg_lsu_rd_addr)
    );

    openrv64_decode_reg_system u_reg_system (
        .instr_i(canonical_instr),
        .valid_o(reg_system_valid),
        .uses_rs1_o(reg_system_uses_rs1),
        .uses_rs2_o(reg_system_uses_rs2),
        .uses_rd_o(reg_system_uses_rd),
        .rs1_addr_o(reg_system_rs1_addr),
        .rs2_addr_o(reg_system_rs2_addr),
        .rd_addr_o(reg_system_rd_addr)
    );

    always @* begin
        selected_decode_valid   = 1'b1;
        selected_decode_illegal = 1'b0;
        selected_reg_valid      = 1'b1;
        selected_uses_rs1       = eff_uses_rs1;
        selected_uses_rs2       = eff_uses_rs2;
        selected_uses_rd        = eff_uses_rd;
        selected_rs1_addr       = eff_uses_rs1 ?
                                  `RV64_RS1(canonical_instr) : `RV64_REG_X0;
        selected_rs2_addr       = eff_uses_rs2 ?
                                  `RV64_RS2(canonical_instr) : `RV64_REG_X0;
        selected_rd_addr        = eff_uses_rd ?
                                  `RV64_RD(canonical_instr) : `RV64_REG_X0;

        if (class_is_alu) begin
            selected_decode_valid   = alu_valid;
            selected_decode_illegal = alu_illegal;
            selected_reg_valid      = reg_alu_valid;
            selected_uses_rs1       = reg_alu_uses_rs1;
            selected_uses_rs2       = reg_alu_uses_rs2;
            selected_uses_rd        = reg_alu_uses_rd;
            selected_rs1_addr       = reg_alu_rs1_addr;
            selected_rs2_addr       = reg_alu_rs2_addr;
            selected_rd_addr        = reg_alu_rd_addr;
        end else if (class_is_mem) begin
            selected_decode_valid   = lsu_valid;
            selected_decode_illegal = lsu_illegal;
            selected_reg_valid      = reg_lsu_valid;
            selected_uses_rs1       = reg_lsu_uses_rs1;
            selected_uses_rs2       = reg_lsu_uses_rs2;
            selected_uses_rd        = reg_lsu_uses_rd;
            selected_rs1_addr       = reg_lsu_rs1_addr;
            selected_rs2_addr       = reg_lsu_rs2_addr;
            selected_rd_addr        = reg_lsu_rd_addr;
        end else if (class_is_brjump) begin
            selected_decode_valid   = br_valid;
            selected_decode_illegal = br_illegal;
        end else if (class_is_system) begin
            selected_decode_valid   = system_valid;
            selected_decode_illegal = system_illegal;
            selected_reg_valid      = reg_system_valid;
            selected_uses_rs1       = reg_system_uses_rs1;
            selected_uses_rs2       = reg_system_uses_rs2;
            selected_uses_rd        = reg_system_uses_rd;
            selected_rs1_addr       = reg_system_rs1_addr;
            selected_rs2_addr       = reg_system_rs2_addr;
            selected_rd_addr        = reg_system_rd_addr;
        end else if (class_is_fence) begin
            selected_decode_valid   = fence_valid;
            selected_decode_illegal = fence_illegal;
        end
    end

    assign opcode_o = opcode;
    assign funct3_o = funct3;
    assign funct7_o = funct7;
    assign funct12_o = funct12;
    assign class_sel_o = extension_selected ? extension_class_sel_i :
                         eff_class_sel;
    assign format_sel_o = extension_selected ? extension_format_sel_i :
                          eff_format_sel;

    assign compressed_o = rvc_compressed;
    assign instr_bytes_o = rvc_instr_bytes;

    assign imm_valid_o = extension_selected ? extension_imm_valid_i :
                         (eff_valid && imm_decode_valid);
    assign illegal_o = rvc_reject ||
                       (extension_selected ? extension_illegal_i :
                        (!eff_valid ||
                         !imm_decode_valid ||
                         !selected_decode_valid ||
                         selected_decode_illegal ||
                         !selected_reg_valid));
    assign valid_o = !rvc_reject &&
                     (extension_selected ?
                      (extension_valid_i && !extension_illegal_i) :
                      (eff_valid && imm_decode_valid && !illegal_o));

    assign uses_rs1_o = valid_o &&
                        (extension_selected ? extension_uses_rs1_i :
                         selected_uses_rs1);
    assign uses_rs2_o = valid_o &&
                        (extension_selected ? extension_uses_rs2_i :
                         selected_uses_rs2);
    assign uses_rd_o  = valid_o &&
                        (extension_selected ? extension_uses_rd_i :
                         selected_uses_rd);
    assign rs1_addr_o = uses_rs1_o ?
                        (extension_selected ? extension_rs1_addr_i :
                         selected_rs1_addr) :
                        `RV64_REG_X0;
    assign rs2_addr_o = uses_rs2_o ?
                        (extension_selected ? extension_rs2_addr_i :
                         selected_rs2_addr) :
                        `RV64_REG_X0;
    assign rd_addr_o  = uses_rd_o ?
                        (extension_selected ? extension_rd_addr_i :
                         selected_rd_addr) :
                        `RV64_REG_X0;
    assign reg_write_o = valid_o &&
                         (extension_selected ? extension_reg_write_i :
                          (class_is_system ? reg_system_uses_rd : eff_reg_write));

    assign has_imm_o = imm_valid_o &&
                       (extension_selected ? extension_has_imm_i :
                        imm_decode_has_imm);
    assign imm_o = imm_valid_o ?
                   (extension_selected ? extension_imm_i :
                    imm_decode_value) :
                   {`RV64_XLEN{1'b0}};

    assign mem_read_o  = valid_o &&
                         (extension_selected ? extension_mem_read_i :
                          (class_is_mem && lsu_load && eff_mem_read));
    assign mem_write_o = valid_o &&
                         (extension_selected ? extension_mem_write_i :
                          (class_is_mem && lsu_store && eff_mem_write));
    assign branch_o    = valid_o && !extension_selected && class_is_branch &&
                         br_branch && eff_branch;
    assign jump_o      = valid_o && !extension_selected && class_is_jump &&
                         br_jump && eff_jump;
    assign word_op_o   = valid_o && !extension_selected && class_is_alu &&
                         alu_word_op && eff_word_op;
    assign system_o    = valid_o && !extension_selected && class_is_system;
    assign fence_o     = valid_o && !extension_selected && class_is_fence;

    assign alu_ext_sel_o = (valid_o && !extension_selected && class_is_alu) ?
                           alu_ext_sel : `RV64_ALU_EXT_INVALID;
    assign alu_op_sel_o  = (valid_o && !extension_selected && class_is_alu) ?
                           alu_op_sel : `RV64_ALU_OP_INVALID;
    assign lsu_op_sel_o = (valid_o && extension_selected) ?
                          extension_lsu_op_sel_i :
                          ((valid_o && class_is_mem) ? lsu_op_sel :
                           `RV64_LSU_OP_INVALID);
    assign lsu_size_sel_o = (valid_o && extension_selected) ?
                            extension_lsu_size_sel_i :
                            ((valid_o && class_is_mem) ? lsu_size_sel :
                             `RV64_LSU_SIZE_BYTE);
    assign lsu_unsigned_o = valid_o &&
                            (extension_selected ? extension_lsu_unsigned_i :
                             (class_is_mem && lsu_unsigned));
    assign br_op_sel_o = (valid_o && !extension_selected && class_is_brjump) ?
                         br_op_sel : `RV64_BR_OP_INVALID;
    assign br_link_o = valid_o && !extension_selected && class_is_brjump &&
                       br_link;
    assign br_indirect_o = valid_o && !extension_selected &&
                           class_is_brjump && br_indirect;

    assign subdecode_needed_o = extension_selected ? 1'b1 :
                                (eff_valid && eff_subdecode_needed);
    assign extension_decode_possible_o = extension_candidate;
    assign extension_candidate_o = extension_candidate;
    assign extension_instr_o = valid_o && extension_selected;
    assign extension_payload_o = extension_instr_o ? extension_payload_i :
        {EXTENSION_PAYLOAD_WIDTH{1'b0}};

endmodule
