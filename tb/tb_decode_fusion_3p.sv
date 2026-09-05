`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/decode/defs/br-defs.v"
`include "core/decode/defs/fusion-defs.v"

module tb_decode_fusion_3p;

    localparam integer PAYLOAD_WIDTH =
        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;

    logic clk;
    logic rst_n;
    logic flush;
    logic [2:0] input_valid;
    wire [2:0] input_ready;
    logic [3*PAYLOAD_WIDTH-1:0] input_payload;
    logic [2:0] input_uses_rs1;
    logic [2:0] input_uses_rs2;
    logic [2:0] input_candidate;
    logic [3*`OPENRV64_FUSION_CANDIDATE_WIDTH-1:0]
        input_candidate_class;
    wire [2:0] output_valid;
    logic [2:0] output_ready;
    wire [3*PAYLOAD_WIDTH-1:0] output_payload;
    wire [2:0] output_uses_rs1;
    wire [2:0] output_uses_rs2;
    wire [2:0] output_fused;
    wire [2:0] input_output_valid;
    wire [5:0] input_output_lane;
    wire [1:0] candidate_accept_count;
    wire [1:0] pcrel_candidate_accept_count;
    wire [1:0] li_candidate_accept_count;
    wire [1:0] fused_accept_count;
    wire [1:0] pcrel_fused_accept_count;
    wire [1:0] li_fused_accept_count;
    wire candidate_pending;

    function automatic [`RV64_INSTR_WIDTH-1:0] make_auipc;
        input [19:0] upper;
        input [`RV64_REG_ADDR_WIDTH-1:0] rd;
        begin
            make_auipc = {upper, rd, `RV64_OPCODE_AUIPC};
        end
    endfunction

    function automatic [`RV64_INSTR_WIDTH-1:0] make_jalr;
        input [11:0] lower;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs1;
        input [`RV64_REG_ADDR_WIDTH-1:0] rd;
        begin
            make_jalr = {lower, rs1, `RV64_FUNCT3_JALR, rd,
                         `RV64_OPCODE_JALR};
        end
    endfunction

    function automatic [`RV64_INSTR_WIDTH-1:0] make_addi;
        input [11:0] immediate;
        input [`RV64_REG_ADDR_WIDTH-1:0] rd;
        begin
            make_addi = {immediate, `RV64_REG_X0,
                         `RV64_FUNCT3_ADD_SUB, rd,
                         `RV64_OPCODE_OP_IMM};
        end
    endfunction

    function automatic [`RV64_INSTR_WIDTH-1:0] make_branch;
        input [12:0] immediate;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs2;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs1;
        input [`RV64_FUNCT3_WIDTH-1:0] funct3;
        begin
            make_branch = {immediate[12], immediate[10:5], rs2, rs1,
                           funct3, immediate[4:1], immediate[11],
                           `RV64_OPCODE_BRANCH};
        end
    endfunction

    openrv64_decode_fusion_3p dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .input_valid_i(input_valid), .input_ready_o(input_ready),
        .input_payload_i(input_payload),
        .input_uses_rs1_i(input_uses_rs1),
        .input_uses_rs2_i(input_uses_rs2),
        .input_candidate_i(input_candidate),
        .input_candidate_class_i(input_candidate_class),
        .output_valid_o(output_valid), .output_ready_i(output_ready),
        .output_payload_o(output_payload),
        .output_uses_rs1_o(output_uses_rs1),
        .output_uses_rs2_o(output_uses_rs2),
        .output_fused_o(output_fused),
        .input_output_valid_o(input_output_valid),
        .input_output_lane_o(input_output_lane),
        .candidate_accept_count_o(candidate_accept_count),
        .pcrel_candidate_accept_count_o(
            pcrel_candidate_accept_count),
        .li_candidate_accept_count_o(li_candidate_accept_count),
        .fused_accept_count_o(fused_accept_count),
        .pcrel_fused_accept_count_o(pcrel_fused_accept_count),
        .li_fused_accept_count_o(li_fused_accept_count),
        .candidate_pending_o(candidate_pending)
    );

    always #5 clk = ~clk;

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic set_full_lane;
        input integer lane;
        input [`RV64_XLEN-1:0] pc;
        input [`RV64_INSTR_WIDTH-1:0] instruction;
        input [`RV64_XLEN-1:0] immediate;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs1;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs2;
        input [`RV64_REG_ADDR_WIDTH-1:0] rd;
        input [`RV64_XLEN-1:0] rs1_data;
        input [`RV64_XLEN-1:0] rs2_data;
        input [`RV64_BR_OP_WIDTH-1:0] br_op;
        input uses_rs1;
        input uses_rs2;
        input [`OPENRV64_FUSION_CANDIDATE_WIDTH-1:0]
            candidate_class;
        reg [PAYLOAD_WIDTH-1:0] payload;
        begin
            payload = {PAYLOAD_WIDTH{1'b0}};
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_PC_LSB +:
                    `RV64_XLEN] = pc;
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +:
                    `RV64_INSTR_WIDTH] = instruction;
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_IMM_LSB +:
                    `RV64_XLEN] = immediate;
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_RS1_LSB +:
                    `RV64_REG_ADDR_WIDTH] = rs1;
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_RS2_LSB +:
                    `RV64_REG_ADDR_WIDTH] = rs2;
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_RS1_DATA_LSB +:
                    `RV64_XLEN] = rs1_data;
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_RS2_DATA_LSB +:
                    `RV64_XLEN] = rs2_data;
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_RD_LSB +:
                    `RV64_REG_ADDR_WIDTH] = rd;
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_BR_OP_LSB +:
                    `RV64_BR_OP_WIDTH] = br_op;
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_REG_WRITE_BIT] =
                `RV64_INSTR_IS_ADDI(instruction) &&
                (rd != `RV64_REG_X0);
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_BRANCH_BIT] =
                (`RV64_OPCODE(instruction) == `RV64_OPCODE_BRANCH);
            input_payload[lane*PAYLOAD_WIDTH +: PAYLOAD_WIDTH] = payload;
            input_uses_rs1[lane] = uses_rs1;
            input_uses_rs2[lane] = uses_rs2;
            input_candidate[lane] =
                (candidate_class != `OPENRV64_FUSION_CANDIDATE_NONE);
            input_candidate_class[
                lane*`OPENRV64_FUSION_CANDIDATE_WIDTH +:
                `OPENRV64_FUSION_CANDIDATE_WIDTH] = candidate_class;
        end
    endtask

    task automatic clear_inputs;
        begin
            input_valid = 3'b000;
            input_payload = {3*PAYLOAD_WIDTH{1'b0}};
            input_uses_rs1 = 3'b000;
            input_uses_rs2 = 3'b000;
            input_candidate = 3'b000;
            input_candidate_class =
                {3*`OPENRV64_FUSION_CANDIDATE_WIDTH{1'b0}};
        end
    endtask

    task automatic set_lane;
        input integer lane;
        input [`RV64_XLEN-1:0] pc;
        input [`RV64_INSTR_WIDTH-1:0] instruction;
        input [`RV64_XLEN-1:0] immediate;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs1;
        input [`RV64_REG_ADDR_WIDTH-1:0] rd;
        input uses_rs1;
        input candidate;
        reg [PAYLOAD_WIDTH-1:0] payload;
        begin
            payload = {PAYLOAD_WIDTH{1'b0}};
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_PC_LSB +:
                    `RV64_XLEN] = pc;
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +:
                    `RV64_INSTR_WIDTH] = instruction;
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_IMM_LSB +:
                    `RV64_XLEN] = immediate;
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_RS1_LSB +:
                    `RV64_REG_ADDR_WIDTH] = rs1;
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_RD_LSB +:
                    `RV64_REG_ADDR_WIDTH] = rd;
            payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_BR_OP_LSB +:
                    `RV64_BR_OP_WIDTH] = `RV64_INSTR_IS_JALR(instruction) ?
                    `RV64_BR_OP_JALR : `RV64_BR_OP_INVALID;
            // Both AUIPC and JALR write rd in the source stream.
            payload[17] = (rd != `RV64_REG_X0);
            payload[13] = `RV64_INSTR_IS_JALR(instruction);
            input_payload[lane*PAYLOAD_WIDTH +: PAYLOAD_WIDTH] = payload;
            input_uses_rs1[lane] = uses_rs1;
            input_candidate[lane] = candidate;
            input_candidate_class[
                lane*`OPENRV64_FUSION_CANDIDATE_WIDTH +:
                `OPENRV64_FUSION_CANDIDATE_WIDTH] = candidate ?
                `OPENRV64_FUSION_CANDIDATE_PCREL_CALL :
                `OPENRV64_FUSION_CANDIDATE_NONE;
        end
    endtask

    task automatic fail;
        input [8*112-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    reg [PAYLOAD_WIDTH-1:0] producer_payload;
    reg [PAYLOAD_WIDTH-1:0] fused_payload;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        output_ready = 3'b111;
        clear_inputs();
        tick();
        rst_n = 1'b1;

        // Same-bundle fusion preserves all three PCs and the AUIPC producer.
        input_valid = 3'b111;
        set_lane(0, 64'h0ffc, `RV64_INSTR_NOP, 64'd0,
                 `RV64_REG_X0, `RV64_REG_X0, 1'b0, 1'b0);
        set_lane(1, 64'h1000, make_auipc(20'h12345, 5'd5),
                 64'h1234_5000, `RV64_REG_X0, 5'd5, 1'b0, 1'b1);
        set_lane(2, 64'h1004, make_jalr(12'h011, 5'd5, 5'd5),
                 64'h11, 5'd5, 5'd5, 1'b1, 1'b0);
        #1;
        producer_payload = output_payload[1*PAYLOAD_WIDTH +: PAYLOAD_WIDTH];
        fused_payload = output_payload[2*PAYLOAD_WIDTH +: PAYLOAD_WIDTH];
        if ((input_ready != 3'b111) || (output_valid != 3'b111) ||
            (output_fused != 3'b100) ||
            (candidate_accept_count != 2'd1) ||
            (pcrel_candidate_accept_count != 2'd1) ||
            (fused_accept_count != 2'd1))
            fail("same-bundle pair did not emit producer and macro");
        if (!producer_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_FUSED_BIT] ||
            (producer_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_PC_LSB +: 64] !=
             64'h1000) ||
            (producer_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +: 32] !=
             make_auipc(20'h12345, 5'd5)) ||
            !producer_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_REG_WRITE_BIT] ||
            (producer_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_RD_LSB +: 5] !=
             5'd5) ||
            output_uses_rs1[1] || output_uses_rs2[1])
            fail("same-bundle fusion did not preserve AUIPC producer");
        if (!fused_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_FUSED_BIT] ||
            (fused_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_PC_LSB +: 64] !=
             64'h1004) ||
            (fused_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +: 32] !=
             make_jalr(12'h011, 5'd5, 5'd5)) ||
            (fused_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_RS1_LSB +: 5] !=
             5'd5) || output_uses_rs1[2] ||
            (fused_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_BR_OP_LSB +:
                           `RV64_BR_OP_WIDTH] != `RV64_BR_OP_JAL) ||
            (fused_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_IMM_LSB +: 64] !=
             64'h1234_500c))
            fail("same-bundle fused payload is incorrect");
        if ((input_output_valid != 3'b111) ||
            (input_output_lane != {2'd2, 2'd1, 2'd0}))
            fail("same-bundle predictor lane map is incorrect");
        tick();
        clear_inputs();

        // Boundary case: two normals pass while the trailing candidate is
        // consumed into the buffer.  Its successor produces a producer/macro
        // on the next cycle.
        input_valid = 3'b111;
        set_lane(0, 64'h2000, `RV64_INSTR_NOP, 64'd0,
                 5'd0, 5'd0, 1'b0, 1'b0);
        set_lane(1, 64'h2004, `RV64_INSTR_NOP, 64'd0,
                 5'd0, 5'd0, 1'b0, 1'b0);
        set_lane(2, 64'h2008, make_auipc(20'h00001, 5'd9),
                 64'h1000, 5'd0, 5'd9, 1'b0, 1'b1);
        #1;
        if ((input_ready != 3'b111) || (output_valid != 3'b011) ||
            (candidate_accept_count != 2'd1) ||
            (fused_accept_count != 2'd0))
            fail("trailing candidate was not accepted behind normal outputs");
        tick();
        clear_inputs();
        #1;
        if (!candidate_pending)
            fail("trailing candidate did not enter the boundary buffer");

        input_valid = 3'b011;
        set_lane(0, 64'h200c, make_jalr(12'h001, 5'd9, 5'd9),
                 64'h1, 5'd9, 5'd9, 1'b1, 1'b0);
        set_lane(1, 64'h2010, `RV64_INSTR_NOP, 64'd0,
                 5'd0, 5'd0, 1'b0, 1'b0);
        #1;
        if ((input_ready != 3'b011) || (output_valid != 3'b111) ||
            (output_fused != 3'b010) ||
            (fused_accept_count != 2'd1) ||
            (input_output_valid != 3'b011) ||
            (input_output_lane[0 +: 2] != 2'd1) ||
            (input_output_lane[2 +: 2] != 2'd2))
            fail("cross-bundle pair did not emit producer and macro");
        tick();
        clear_inputs();
        #1;
        if (candidate_pending)
            fail("accepted cross-bundle candidate remained pending");

        // A second pair can begin after two emitted records only when a
        // prior buffered candidate occupies sequence slot zero.  Do not emit
        // its producer in output lane two; buffer that candidate and leave its
        // successor unaccepted for a two-lane retry.
        input_valid = 3'b001;
        set_lane(0, 64'h2800, make_auipc(20'h00001, 5'd7),
                 64'h1000, 5'd0, 5'd7, 1'b0, 1'b1);
        #1;
        if ((input_ready != 3'b001) || (output_valid != 3'b000))
            fail("setup candidate did not enter boundary buffer");
        tick();
        clear_inputs();

        input_valid = 3'b111;
        set_lane(0, 64'h3000, `RV64_INSTR_NOP, 64'd0,
                 5'd0, 5'd0, 1'b0, 1'b0);
        set_lane(1, 64'h3004, make_auipc(20'h00001, 5'd8),
                 64'h1000, 5'd0, 5'd8, 1'b0, 1'b1);
        set_lane(2, 64'h3008, make_jalr(12'h000, 5'd8, 5'd8),
                 64'd0, 5'd8, 5'd8, 1'b1, 1'b0);
        #1;
        if ((output_valid != 3'b011) || (input_ready != 3'b011) ||
            output_payload[2*PAYLOAD_WIDTH +
                `OPENRV64_EXEC_ISSUE_PAYLOAD_FUSED_BIT])
            fail("lane-two fusion producer was exposed without its macro");
        tick();
        clear_inputs();
        #1;
        if (!candidate_pending)
            fail("lane-two pair candidate was not buffered");

        input_valid = 3'b001;
        set_lane(0, 64'h3008, make_jalr(12'h000, 5'd8, 5'd8),
                 64'd0, 5'd8, 5'd8, 1'b1, 1'b0);
        #1;
        if ((output_valid != 3'b011) || (input_ready != 3'b001) ||
            (output_fused != 3'b010))
            fail("lane-two deferred pair did not retry as producer plus macro");
        tick();
        clear_inputs();

        // JALR bit zero is architecturally cleared.  Fusion must preserve that
        // behavior when it converts the pair to a direct jump.
        input_valid = 3'b011;
        set_lane(0, 64'h3000, make_auipc(20'h00000, 5'd10),
                 64'd0, 5'd0, 5'd10, 1'b0, 1'b1);
        set_lane(1, 64'h3004, make_jalr(12'h005, 5'd10, 5'd10),
                 64'd5, 5'd10, 5'd10, 1'b1, 1'b0);
        #1;
        fused_payload = output_payload[1*PAYLOAD_WIDTH +: PAYLOAD_WIDTH];
        if (!output_fused[1] ||
            (fused_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_IMM_LSB +: 64] !=
             64'd0))
            fail("fused direct target did not apply JALR bit-zero clearing");
        tick();
        clear_inputs();

        // A destination mismatch is not a fusion.  Both original records pass.
        input_valid = 3'b011;
        set_lane(0, 64'h4000, make_auipc(20'h00001, 5'd6),
                 64'h1000, 5'd0, 5'd6, 1'b0, 1'b1);
        set_lane(1, 64'h4004, make_jalr(12'h000, 5'd6, 5'd7),
                 64'd0, 5'd6, 5'd7, 1'b1, 1'b0);
        #1;
        if ((output_valid != 3'b011) || (output_fused != 3'b000) ||
            (fused_accept_count != 2'd0))
            fail("noncanonical AUIPC/JALR pair was incorrectly fused");
        tick();
        clear_inputs();

        // LI in rs2: preserve the LI producer, remove only its consumed
        // dependency, and embed the constant in the fused compare.
        input_valid = 3'b011;
        set_full_lane(0, 64'h5000, make_addi(12'hff9, 5'd9),
                      64'hffff_ffff_ffff_fff9, 5'd0, 5'd0, 5'd9,
                      64'd0, 64'd0, `RV64_BR_OP_INVALID,
                      1'b0, 1'b0,
                      `OPENRV64_FUSION_CANDIDATE_LI_BRANCH);
        set_full_lane(1, 64'h5004,
                      make_branch(13'd8, 5'd9, 5'd8,
                                  `RV64_FUNCT3_BLT),
                      64'd8, 5'd8, 5'd9, 5'd0,
                      64'd17, 64'hdead_beef, `RV64_BR_OP_BLT,
                      1'b1, 1'b1, `OPENRV64_FUSION_CANDIDATE_NONE);
        #1;
        producer_payload = output_payload[0 +: PAYLOAD_WIDTH];
        fused_payload = output_payload[1*PAYLOAD_WIDTH +: PAYLOAD_WIDTH];
        if ((output_valid != 3'b011) || (output_fused != 3'b010) ||
            (candidate_accept_count != 2'd1) ||
            (li_candidate_accept_count != 2'd1) ||
            (pcrel_candidate_accept_count != 2'd0) ||
            (fused_accept_count != 2'd1) ||
            (li_fused_accept_count != 2'd1) ||
            (pcrel_fused_accept_count != 2'd0))
            fail("same-bundle LI/branch pair did not emit producer and macro");
        if (!producer_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_FUSED_BIT] ||
            (producer_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_PC_LSB +: 64] !=
             64'h5000) ||
            (producer_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +: 32] !=
             make_addi(12'hff9, 5'd9)) ||
            !producer_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_REG_WRITE_BIT] ||
            (producer_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_RD_LSB +: 5] !=
             5'd9))
            fail("LI/branch fusion did not preserve LI producer");
        if (!fused_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_FUSED_BIT] ||
            (fused_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_PC_LSB +: 64] !=
             64'h5004) ||
            (fused_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +: 32] !=
             make_branch(13'd8, 5'd9, 5'd8, `RV64_FUNCT3_BLT)) ||
            (fused_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_IMM_LSB +: 64] !=
             64'd8) ||
            (fused_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_RD_LSB +: 5] !=
             5'd9) ||
            fused_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_REG_WRITE_BIT] ||
            (fused_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_RS2_DATA_LSB +: 64] !=
             64'hffff_ffff_ffff_fff9) ||
            !output_uses_rs1[1] || output_uses_rs2[1])
            fail("LI/branch rs2 compound payload is incorrect");
        tick();
        clear_inputs();

        // LI in rs1 must work without condition inversion.  The execution
        // pipe compares in the original operand order while the separate LI
        // record owns the architectural write.
        input_valid = 3'b011;
        set_full_lane(0, 64'h5100, make_addi(12'd9, 5'd10),
                      64'd9, 5'd0, 5'd0, 5'd10,
                      64'd0, 64'd0, `RV64_BR_OP_INVALID,
                      1'b0, 1'b0,
                      `OPENRV64_FUSION_CANDIDATE_LI_BRANCH);
        set_full_lane(1, 64'h5104,
                      make_branch(13'd12, 5'd8, 5'd10,
                                  `RV64_FUNCT3_BGEU),
                      64'd12, 5'd10, 5'd8, 5'd0,
                      64'hdead_beef, 64'd7, `RV64_BR_OP_BGEU,
                      1'b1, 1'b1, `OPENRV64_FUSION_CANDIDATE_NONE);
        #1;
        fused_payload = output_payload[1*PAYLOAD_WIDTH +: PAYLOAD_WIDTH];
        if (!output_fused[1] || output_uses_rs1[1] ||
            !output_uses_rs2[1] ||
            (fused_payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_RS1_DATA_LSB +: 64] !=
             64'd9))
            fail("LI/branch rs1 compound payload is incorrect");
        tick();
        clear_inputs();

        // A branch that does not consume the LI destination is not fusible.
        input_valid = 3'b011;
        set_full_lane(0, 64'h5200, make_addi(12'd3, 5'd11),
                      64'd3, 5'd0, 5'd0, 5'd11,
                      64'd0, 64'd0, `RV64_BR_OP_INVALID,
                      1'b0, 1'b0,
                      `OPENRV64_FUSION_CANDIDATE_LI_BRANCH);
        set_full_lane(1, 64'h5204,
                      make_branch(13'd8, 5'd13, 5'd12,
                                  `RV64_FUNCT3_BEQ),
                      64'd8, 5'd12, 5'd13, 5'd0,
                      64'd3, 64'd3, `RV64_BR_OP_BEQ,
                      1'b1, 1'b1, `OPENRV64_FUSION_CANDIDATE_NONE);
        #1;
        if ((output_valid != 3'b011) || (output_fused != 3'b000) ||
            (li_fused_accept_count != 2'd0))
            fail("non-consuming LI/branch pair was incorrectly fused");
        tick();
        clear_inputs();

        // If the branch's known target is not IALIGN=32 compatible, its trap
        // must remain a separate instruction after LI has committed.
        input_valid = 3'b011;
        set_full_lane(0, 64'h5300, make_addi(12'd1, 5'd14),
                      64'd1, 5'd0, 5'd0, 5'd14,
                      64'd0, 64'd0, `RV64_BR_OP_INVALID,
                      1'b0, 1'b0,
                      `OPENRV64_FUSION_CANDIDATE_LI_BRANCH);
        set_full_lane(1, 64'h5304,
                      make_branch(13'd2, 5'd14, 5'd12,
                                  `RV64_FUNCT3_BEQ),
                      64'd2, 5'd12, 5'd14, 5'd0,
                      64'd1, 64'd1, `RV64_BR_OP_BEQ,
                      1'b1, 1'b1, `OPENRV64_FUSION_CANDIDATE_NONE);
        #1;
        if ((output_valid != 3'b011) || (output_fused != 3'b000))
            fail("misaligned-target LI/branch pair was incorrectly fused");
        tick();
        clear_inputs();

        $display("PASS: live 3p AUIPC and LI/branch two-record fusion");
        $finish;
    end

endmodule
