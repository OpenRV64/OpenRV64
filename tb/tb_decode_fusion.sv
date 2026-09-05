`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/fusion-defs.v"

module tb_decode_fusion;

    localparam integer ID_WIDTH = 8;
    localparam integer PAYLOAD_WIDTH = 8;

    logic clk;
    logic rst_n;
    logic flush;

    logic candidate_valid;
    logic candidate_ready;
    logic [`OPENRV64_FUSION_CANDIDATE_WIDTH-1:0] candidate_class;
    logic [`RV64_XLEN-1:0] candidate_pc;
    logic [ID_WIDTH-1:0] candidate_id;
    logic [`RV64_INSTR_WIDTH-1:0] candidate_instr;
    logic [2:0] candidate_instr_bytes;
    logic [PAYLOAD_WIDTH-1:0] candidate_payload;

    logic successor_valid;
    logic successor_ready;
    logic [`RV64_XLEN-1:0] successor_pc;
    logic [ID_WIDTH-1:0] successor_id;
    logic [`RV64_INSTR_WIDTH-1:0] successor_instr;
    logic [2:0] successor_instr_bytes;
    logic [PAYLOAD_WIDTH-1:0] successor_payload;

    logic decision_valid;
    logic decision_ready;
    logic decision_fused;
    logic release_candidate;
    logic release_successor;
    logic squash_candidate;
    logic squash_successor;
    logic [`OPENRV64_FUSION_OP_WIDTH-1:0] fusion_op;
    logic [1:0] fused_instruction_count;
    logic [`RV64_XLEN-1:0] first_pc;
    logic [ID_WIDTH-1:0] first_id;
    logic [`RV64_INSTR_WIDTH-1:0] first_instr;
    logic [2:0] first_instr_bytes;
    logic [PAYLOAD_WIDTH-1:0] first_payload;
    logic [`RV64_XLEN-1:0] second_pc;
    logic [ID_WIDTH-1:0] second_id;
    logic [`RV64_INSTR_WIDTH-1:0] second_instr;
    logic [2:0] second_instr_bytes;
    logic [PAYLOAD_WIDTH-1:0] second_payload;
    logic [`RV64_XLEN-1:0] fused_pc_relative_offset;
    logic [`RV64_XLEN-1:0] fused_link_pc;
    logic [`RV64_REG_ADDR_WIDTH-1:0] fused_rd;
    logic candidate_pending;

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

    openrv64_decode_fusion #(
        .ID_WIDTH(ID_WIDTH),
        .PAYLOAD_WIDTH(PAYLOAD_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .candidate_valid_i(candidate_valid),
        .candidate_ready_o(candidate_ready),
        .candidate_class_i(candidate_class),
        .candidate_pc_i(candidate_pc),
        .candidate_id_i(candidate_id),
        .candidate_instr_i(candidate_instr),
        .candidate_instr_bytes_i(candidate_instr_bytes),
        .candidate_payload_i(candidate_payload),
        .successor_valid_i(successor_valid),
        .successor_ready_o(successor_ready),
        .successor_pc_i(successor_pc),
        .successor_id_i(successor_id),
        .successor_instr_i(successor_instr),
        .successor_instr_bytes_i(successor_instr_bytes),
        .successor_payload_i(successor_payload),
        .decision_valid_o(decision_valid),
        .decision_ready_i(decision_ready),
        .decision_fused_o(decision_fused),
        .release_candidate_o(release_candidate),
        .release_successor_o(release_successor),
        .squash_candidate_o(squash_candidate),
        .squash_successor_o(squash_successor),
        .fusion_op_o(fusion_op),
        .fused_instruction_count_o(fused_instruction_count),
        .first_pc_o(first_pc),
        .first_id_o(first_id),
        .first_instr_o(first_instr),
        .first_instr_bytes_o(first_instr_bytes),
        .first_payload_o(first_payload),
        .second_pc_o(second_pc),
        .second_id_o(second_id),
        .second_instr_o(second_instr),
        .second_instr_bytes_o(second_instr_bytes),
        .second_payload_o(second_payload),
        .fused_pc_relative_offset_o(fused_pc_relative_offset),
        .fused_link_pc_o(fused_link_pc),
        .fused_rd_o(fused_rd),
        .candidate_pending_o(candidate_pending)
    );

    always #5 clk = ~clk;

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic drive_candidate;
        input [19:0] upper;
        input [`RV64_REG_ADDR_WIDTH-1:0] rd;
        input [`RV64_XLEN-1:0] pc;
        input [ID_WIDTH-1:0] id;
        input [PAYLOAD_WIDTH-1:0] payload;
        begin
            candidate_valid = 1'b1;
            candidate_class = `OPENRV64_FUSION_CANDIDATE_PCREL_CALL;
            candidate_pc = pc;
            candidate_id = id;
            candidate_instr = make_auipc(upper, rd);
            candidate_instr_bytes = 3'd4;
            candidate_payload = payload;
        end
    endtask

    task automatic drive_successor;
        input [11:0] lower;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs1;
        input [`RV64_REG_ADDR_WIDTH-1:0] rd;
        input [`RV64_XLEN-1:0] pc;
        input [ID_WIDTH-1:0] id;
        input [PAYLOAD_WIDTH-1:0] payload;
        begin
            successor_valid = 1'b1;
            successor_pc = pc;
            successor_id = id;
            successor_instr = make_jalr(lower, rs1, rd);
            successor_instr_bytes = 3'd4;
            successor_payload = payload;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        candidate_valid = 1'b0;
        candidate_class = `OPENRV64_FUSION_CANDIDATE_NONE;
        candidate_pc = 64'd0;
        candidate_id = {ID_WIDTH{1'b0}};
        candidate_instr = `RV64_INSTR_NOP;
        candidate_instr_bytes = 3'd4;
        candidate_payload = {PAYLOAD_WIDTH{1'b0}};
        successor_valid = 1'b0;
        successor_pc = 64'd0;
        successor_id = {ID_WIDTH{1'b0}};
        successor_instr = `RV64_INSTR_NOP;
        successor_instr_bytes = 3'd4;
        successor_payload = {PAYLOAD_WIDTH{1'b0}};
        decision_ready = 1'b0;

        tick();
        rst_n = 1'b1;
        #1;

        // Same-bundle bypass: the pair remains stable while dispatch blocks.
        drive_candidate(20'h12345, 5'd5, 64'h4000_1000, 8'h10, 8'ha5);
        drive_successor(12'h011, 5'd5, 5'd5,
                        64'h4000_1004, 8'h11, 8'h5a);
        #1;
        if (!decision_valid || !decision_fused || candidate_ready ||
            successor_ready || !squash_candidate || !squash_successor ||
            release_candidate || release_successor ||
            (fusion_op != `OPENRV64_FUSION_OP_PCREL_CALL) ||
            (fused_instruction_count != 2'd2) ||
            (fused_pc_relative_offset != 64'h0000_0000_1234_5011) ||
            (fused_link_pc != 64'h4000_1008) || (fused_rd != 5'd5) ||
            (first_payload != 8'ha5) || (second_payload != 8'h5a)) begin
            $fatal(1, "same-bundle PC-relative call was not fused correctly");
        end

        // The odd low displacement is intentionally accepted here.  JALR
        // clears target bit zero in execution; fusion does not reject it.
        decision_ready = 1'b1;
        #1;
        if (!candidate_ready || !successor_ready)
            $fatal(1, "same-bundle fusion did not handshake");
        tick();
        candidate_valid = 1'b0;
        successor_valid = 1'b0;
        decision_ready = 1'b0;
        #1;
        if (candidate_pending)
            $fatal(1, "same-bundle bypass incorrectly retained candidate");

        // Cross-bundle path: retain the AUIPC, then match its successor.
        drive_candidate(20'hfffff, 5'd9, 64'h8000_0000, 8'h20, 8'hc3);
        #1;
        if (!candidate_ready || decision_valid)
            $fatal(1, "empty fusion buffer did not accept candidate");
        tick();
        candidate_valid = 1'b0;
        #1;
        if (!candidate_pending)
            $fatal(1, "cross-bundle candidate was not retained");

        drive_successor(12'hff0, 5'd9, 5'd9,
                        64'h8000_0004, 8'h21, 8'h3c);
        #1;
        if (!decision_valid || !decision_fused || successor_ready ||
            (first_id != 8'h20) || (second_id != 8'h21) ||
            (first_payload != 8'hc3) ||
            (fused_pc_relative_offset != 64'hffff_ffff_ffff_eff0)) begin
            $fatal(1, "buffered PC-relative call decision was incorrect");
        end
        decision_ready = 1'b1;
        #1;
        if (!successor_ready)
            $fatal(1, "buffered fusion did not accept successor");
        tick();
        successor_valid = 1'b0;
        decision_ready = 1'b0;
        #1;
        if (candidate_pending)
            $fatal(1, "accepted buffered candidate was not removed");

        // A register mismatch releases the candidate instead of fusing it.
        drive_candidate(20'h00001, 5'd6, 64'h9000_0000, 8'h30, 8'h66);
        tick();
        candidate_valid = 1'b0;
        drive_successor(12'h000, 5'd6, 5'd7,
                        64'h9000_0004, 8'h31, 8'h77);
        decision_ready = 1'b1;
        #1;
        if (!decision_valid || decision_fused || !release_candidate ||
            !release_successor ||
            squash_candidate || squash_successor ||
            (fusion_op != `OPENRV64_FUSION_OP_NONE) ||
            (first_id != 8'h30) || (second_id != 8'h31)) begin
            $fatal(1, "noncanonical destination pair was incorrectly fused");
        end
        tick();
        successor_valid = 1'b0;
        decision_ready = 1'b0;

        // Flush removes a boundary candidate without producing a decision.
        drive_candidate(20'h00002, 5'd8, 64'ha000_0000, 8'h40, 8'h88);
        tick();
        candidate_valid = 1'b0;
        if (!candidate_pending)
            $fatal(1, "flush test did not first retain candidate");
        flush = 1'b1;
        #1;
        if (decision_valid || candidate_ready || successor_ready)
            $fatal(1, "fusion buffer exposed a transaction during flush");
        tick();
        flush = 1'b0;
        #1;
        if (candidate_pending)
            $fatal(1, "flush did not clear fusion candidate");

        $display("PASS: decode fusion candidate buffer");
        $finish;
    end

endmodule
