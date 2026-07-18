`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/arith/prefix-addsub.v"

// Combinational cut of the two-set, four-way resident replay lookup.  The
// flattened tag and line inputs stand in for the Q outputs of the eight fetch
// line registers, making them explicit timing start points.
module openrv64_timing_fetch_replay_lookup (
    input  wire [`RV64_XLEN-1:0]        target_pc_i,
    input  wire [7:0]                   resident_i,
    input  wire [(8*60)-1:0]            line_tags_i,
    input  wire [(8*64)-1:0]            line_data_i,
    output wire                         hit_o,
    output wire [`RV64_INSTR_WIDTH-1:0] instr_o
);

    wire set_sel = target_pc_i[3];
    wire [`RV64_XLEN-1:4] target_tag = target_pc_i[`RV64_XLEN-1:4];

    wire resident0 = set_sel ? resident_i[1] : resident_i[0];
    wire resident1 = set_sel ? resident_i[3] : resident_i[2];
    wire resident2 = set_sel ? resident_i[5] : resident_i[4];
    wire resident3 = set_sel ? resident_i[7] : resident_i[6];

    wire [59:0] tag0 = set_sel ? line_tags_i[119:60] : line_tags_i[59:0];
    wire [59:0] tag1 = set_sel ? line_tags_i[239:180] : line_tags_i[179:120];
    wire [59:0] tag2 = set_sel ? line_tags_i[359:300] : line_tags_i[299:240];
    wire [59:0] tag3 = set_sel ? line_tags_i[479:420] : line_tags_i[419:360];

    wire [63:0] line0 = set_sel ? line_data_i[127:64] : line_data_i[63:0];
    wire [63:0] line1 = set_sel ? line_data_i[255:192] : line_data_i[191:128];
    wire [63:0] line2 = set_sel ? line_data_i[383:320] : line_data_i[319:256];
    wire [63:0] line3 = set_sel ? line_data_i[511:448] : line_data_i[447:384];

    wire hit0 = resident0 && (tag0 == target_tag);
    wire hit1 = resident1 && (tag1 == target_tag);
    wire hit2 = resident2 && (tag2 == target_tag);
    wire hit3 = resident3 && (tag3 == target_tag);

    wire [63:0] selected_line = hit0 ? line0 :
                                hit1 ? line1 :
                                hit2 ? line2 : line3;

    assign hit_o = hit0 || hit1 || hit2 || hit3;
    assign instr_o = hit_o ?
                     (target_pc_i[2] ? selected_line[63:32] :
                                           selected_line[31:0]) :
                     {`RV64_INSTR_WIDTH{1'b0}};

endmodule

// Current resident same-edge prediction cone for the always-taken policy:
// registered compact predecode metadata -> shared target adder ->
// two-set/four-way resident lookup -> replay instruction.
module openrv64_timing_frontend_replay (
    input  wire [`RV64_XLEN-1:0]        if_id_pc_i,
    input  wire [19:0]                  predecode_offset_i,
    input  wire                         predecode_valid_i,
    input  wire                         predecode_conditional_i,
    input  wire                         if_id_valid_i,
    input  wire                         decode_accept_i,
    input  wire [7:0]                   resident_i,
    input  wire [(8*60)-1:0]            line_tags_i,
    input  wire [(8*64)-1:0]            line_data_i,
    output wire                         replay_valid_o,
    output wire [`RV64_INSTR_WIDTH-1:0] replay_instr_o
);

    wire prediction_taken;
    openrv64_exec_bp_always_branch u_predict (
        .lookup_branch_i(predecode_conditional_i),
        .lookup_jump_i(!predecode_conditional_i),
        .lookup_indirect_i(1'b0),
        .prediction_taken_o(prediction_taken)
    );

    wire redirect = if_id_valid_i && decode_accept_i &&
                    predecode_valid_i && prediction_taken;
    wire [`RV64_XLEN-1:0] predecode_imm = {
        {43{predecode_offset_i[19]}}, predecode_offset_i, 1'b0
    };
    wire [`RV64_XLEN-1:0] target_pc;
    wire lookup_hit;
    wire [`RV64_INSTR_WIDTH-1:0] lookup_instr;

    openrv64_prefix_addsub u_target (
        .a_i(if_id_pc_i),
        .b_i(predecode_imm),
        .sub_i(1'b0),
        .result_o(target_pc)
    );

    openrv64_timing_fetch_replay_lookup u_lookup (
        .target_pc_i(target_pc),
        .resident_i(resident_i),
        .line_tags_i(line_tags_i),
        .line_data_i(line_data_i),
        .hit_o(lookup_hit),
        .instr_o(lookup_instr)
    );

    assign replay_valid_o = redirect && lookup_hit;
    assign replay_instr_o = replay_valid_o ? lookup_instr :
                                             {`RV64_INSTR_WIDTH{1'b0}};

endmodule

// Post-fill classification and displacement-encoding cut. Its compact output
// is registered with the resident line before it reaches same-edge replay.
module openrv64_timing_fetch_predecode_offset (
    input  wire [`RV64_INSTR_WIDTH-1:0] instr_i,
    output wire                         direct_valid_o,
    output wire                         conditional_o,
    output wire [19:0]                  offset_o
);

    wire is_branch = (`RV64_OPCODE(instr_i) == `RV64_OPCODE_BRANCH);
    wire is_jal = (`RV64_OPCODE(instr_i) == `RV64_OPCODE_JAL);
    wire legal_branch_funct3 =
        (`RV64_FUNCT3(instr_i) == `RV64_FUNCT3_BEQ) ||
        (`RV64_FUNCT3(instr_i) == `RV64_FUNCT3_BNE) ||
        (`RV64_FUNCT3(instr_i) == `RV64_FUNCT3_BLT) ||
        (`RV64_FUNCT3(instr_i) == `RV64_FUNCT3_BGE) ||
        (`RV64_FUNCT3(instr_i) == `RV64_FUNCT3_BLTU) ||
        (`RV64_FUNCT3(instr_i) == `RV64_FUNCT3_BGEU);
    wire [`RV64_XLEN-1:0] immediate = is_jal ?
        `RV64_IMM_J(instr_i) : `RV64_IMM_B(instr_i);

    assign direct_valid_o = is_jal || (is_branch && legal_branch_funct3);
    assign conditional_o = is_branch && legal_branch_funct3;
    assign offset_o = immediate[20:1];

endmodule
