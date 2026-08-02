`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

module tb_decode_rv64c;

    logic [31:0] instr_window;
    wire [31:0] canonical_instr;
    wire compressed;
    wire c_illegal;
    wire unsupported_length;
    wire [2:0] instr_bytes;

    wire decode_valid;
    wire decode_illegal;
    wire uses_rs1;
    wire uses_rs2;
    wire uses_rd;
    wire [4:0] rs1_addr;
    wire [4:0] rs2_addr;
    wire [4:0] rd_addr;
    wire [63:0] imm;
    wire mem_read;
    wire mem_write;
    wire branch;
    wire jump;
    wire system_instr;
    wire br_indirect;

    integer halfword;
    reg [31:0] first_canonical;
    reg first_illegal;
    reg first_unsupported;
    reg [2:0] first_bytes;

    openrv64_decode_rv64c dut (
        .instr_i(instr_window),
        .instr_o(canonical_instr),
        .compressed_o(compressed),
        .illegal_o(c_illegal),
        .unsupported_length_o(unsupported_length),
        .instr_bytes_o(instr_bytes)
    );

    openrv64_decode_top u_decode (
        .instr_i(canonical_instr),
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
        .valid_o(decode_valid),
        .illegal_o(decode_illegal),
        .uses_rs1_o(uses_rs1),
        .uses_rs2_o(uses_rs2),
        .uses_rd_o(uses_rd),
        .rs1_addr_o(rs1_addr),
        .rs2_addr_o(rs2_addr),
        .rd_addr_o(rd_addr),
        .imm_o(imm),
        .mem_read_o(mem_read),
        .mem_write_o(mem_write),
        .branch_o(branch),
        .jump_o(jump),
        .system_o(system_instr),
        .br_indirect_o(br_indirect)
    );

    task automatic check_expand;
        input [31:0] raw;
        input [31:0] expected;
        input expected_compressed;
        input expected_illegal;
        input expected_unsupported;
        input [2:0] expected_bytes;
        input [8*48-1:0] label;
        begin
            instr_window = raw;
            #1;
            if (canonical_instr !== expected ||
                compressed !== expected_compressed ||
                c_illegal !== expected_illegal ||
                unsupported_length !== expected_unsupported ||
                instr_bytes !== expected_bytes) begin
                $fatal(1,
                    "%0s: raw=%08x canonical=%08x/%08x compressed=%0b/%0b illegal=%0b/%0b unsupported=%0b/%0b bytes=%0d/%0d",
                    label,
                    raw,
                    canonical_instr,
                    expected,
                    compressed,
                    expected_compressed,
                    c_illegal,
                    expected_illegal,
                    unsupported_length,
                    expected_unsupported,
                    instr_bytes,
                    expected_bytes);
            end

            if ((c_illegal || decode_illegal) !== expected_illegal) begin
                $fatal(1,
                    "%0s: combined illegal=%0b expected=%0b (c=%0b base=%0b)",
                    label,
                    c_illegal || decode_illegal,
                    expected_illegal,
                    c_illegal,
                    decode_illegal);
            end

            if (!expected_illegal && (!decode_valid || decode_illegal)) begin
                $fatal(1,
                    "%0s: legal expansion rejected by base decoder: canonical=%08x valid=%0b illegal=%0b",
                    label,
                    canonical_instr,
                    decode_valid,
                    decode_illegal);
            end
        end
    endtask

    task automatic check_dispatch;
        input expected_rs1;
        input expected_rs2;
        input expected_rd;
        input [4:0] expected_rs1_addr;
        input [4:0] expected_rs2_addr;
        input [4:0] expected_rd_addr;
        input [63:0] expected_imm;
        input expected_mem_read;
        input expected_mem_write;
        input expected_branch;
        input expected_jump;
        input expected_system;
        input expected_indirect;
        input [8*48-1:0] label;
        begin
            if (uses_rs1 !== expected_rs1 ||
                uses_rs2 !== expected_rs2 ||
                uses_rd !== expected_rd ||
                rs1_addr !== expected_rs1_addr ||
                rs2_addr !== expected_rs2_addr ||
                rd_addr !== expected_rd_addr ||
                imm !== expected_imm ||
                mem_read !== expected_mem_read ||
                mem_write !== expected_mem_write ||
                branch !== expected_branch ||
                jump !== expected_jump ||
                system_instr !== expected_system ||
                br_indirect !== expected_indirect) begin
                $fatal(1,
                    "%0s dispatch: rs1=%0b:%0d/%0b:%0d rs2=%0b:%0d/%0b:%0d rd=%0b:%0d/%0b:%0d imm=%016x/%016x memr=%0b/%0b memw=%0b/%0b branch=%0b/%0b jump=%0b/%0b system=%0b/%0b indirect=%0b/%0b",
                    label,
                    uses_rs1,
                    rs1_addr,
                    expected_rs1,
                    expected_rs1_addr,
                    uses_rs2,
                    rs2_addr,
                    expected_rs2,
                    expected_rs2_addr,
                    uses_rd,
                    rd_addr,
                    expected_rd,
                    expected_rd_addr,
                    imm,
                    expected_imm,
                    mem_read,
                    expected_mem_read,
                    mem_write,
                    expected_mem_write,
                    branch,
                    expected_branch,
                    jump,
                    expected_jump,
                    system_instr,
                    expected_system,
                    br_indirect,
                    expected_indirect);
            end
        end
    endtask

    initial begin
        // Golden encodings were assembled independently with GNU binutils
        // 2.44 using -march=rv64ic and paired .option rvc/norvc blocks.
        check_expand(32'hbeef_0808, 32'h0101_0513, 1, 0, 0, 2,
                     "c.addi4spn a0,sp,16");
        check_dispatch(1, 0, 1, 5'd2, 5'd0, 5'd10, 64'd16,
                       0, 0, 0, 0, 0, 0, "c.addi4spn dispatch");

        check_expand(32'hbeef_454c, 32'h00c5_2583, 1, 0, 0, 2,
                     "c.lw a1,12(a0)");
        check_dispatch(1, 0, 1, 5'd10, 5'd0, 5'd11, 64'd12,
                       1, 0, 0, 0, 0, 0, "c.lw dispatch");

        check_expand(32'hbeef_6d10, 32'h0185_3603, 1, 0, 0, 2,
                     "c.ld a2,24(a0)");
        check_expand(32'hbeef_c54c, 32'h00b5_2623, 1, 0, 0, 2,
                     "c.sw a1,12(a0)");
        check_dispatch(1, 1, 0, 5'd10, 5'd11, 5'd0, 64'd12,
                       0, 1, 0, 0, 0, 0, "c.sw dispatch");

        check_expand(32'hbeef_ed10, 32'h00c5_3c23, 1, 0, 0, 2,
                     "c.sd a2,24(a0)");
        check_expand(32'hbeef_0001, 32'h0000_0013, 1, 0, 0, 2,
                     "c.nop");
        check_expand(32'hbeef_16fd, 32'hfff6_8693, 1, 0, 0, 2,
                     "c.addi a3,-1");
        check_expand(32'hbeef_36fd, 32'hfff6_869b, 1, 0, 0, 2,
                     "c.addiw a3,-1");
        check_expand(32'hbeef_577d, 32'hfff0_0713, 1, 0, 0, 2,
                     "c.li a4,-1");
        check_expand(32'hbeef_717d, 32'hff01_0113, 1, 0, 0, 2,
                     "c.addi16sp sp,-16");
        check_expand(32'hbeef_6785, 32'h0000_17b7, 1, 0, 0, 2,
                     "c.lui a5,1");
        check_expand(32'hbeef_9105, 32'h0215_5513, 1, 0, 0, 2,
                     "c.srli a0,33");
        check_expand(32'hbeef_9585, 32'h4215_d593, 1, 0, 0, 2,
                     "c.srai a1,33");
        check_expand(32'hbeef_9a7d, 32'hfff6_7613, 1, 0, 0, 2,
                     "c.andi a2,-1");
        check_expand(32'hbeef_8d0d, 32'h40b5_0533, 1, 0, 0, 2,
                     "c.sub a0,a1");
        check_expand(32'hbeef_8d2d, 32'h00b5_4533, 1, 0, 0, 2,
                     "c.xor a0,a1");
        check_expand(32'hbeef_8d4d, 32'h00b5_6533, 1, 0, 0, 2,
                     "c.or a0,a1");
        check_expand(32'hbeef_8d6d, 32'h00b5_7533, 1, 0, 0, 2,
                     "c.and a0,a1");
        check_expand(32'hbeef_9d0d, 32'h40b5_053b, 1, 0, 0, 2,
                     "c.subw a0,a1");
        check_expand(32'hbeef_9d2d, 32'h00b5_053b, 1, 0, 0, 2,
                     "c.addw a0,a1");

        check_expand(32'hbeef_a019, 32'h0060_006f, 1, 0, 0, 2,
                     "c.j +6");
        check_dispatch(0, 0, 1, 5'd0, 5'd0, 5'd0, 64'd6,
                       0, 0, 0, 1, 0, 0, "c.j dispatch");

        check_expand(32'hbeef_c111, 32'h0005_0263, 1, 0, 0, 2,
                     "c.beqz a0,+4");
        check_dispatch(1, 1, 0, 5'd10, 5'd0, 5'd0, 64'd4,
                       0, 0, 1, 0, 0, 0, "c.beqz dispatch");

        check_expand(32'hbeef_e109, 32'h0005_1163, 1, 0, 0, 2,
                     "c.bnez a0,+2");
        check_expand(32'hbeef_1686, 32'h0216_9693, 1, 0, 0, 2,
                     "c.slli a3,33");
        check_expand(32'hbeef_5576, 32'h07c1_2503, 1, 0, 0, 2,
                     "c.lwsp a0,124(sp)");
        check_expand(32'hbeef_75ee, 32'h0f81_3583, 1, 0, 0, 2,
                     "c.ldsp a1,248(sp)");
        check_expand(32'hbeef_8502, 32'h0005_0067, 1, 0, 0, 2,
                     "c.jr a0");
        check_dispatch(1, 0, 1, 5'd10, 5'd0, 5'd0, 64'd0,
                       0, 0, 0, 1, 0, 1, "c.jr dispatch");

        check_expand(32'hbeef_852e, 32'h00b0_0533, 1, 0, 0, 2,
                     "c.mv a0,a1");
        check_expand(32'hbeef_9002, 32'h0010_0073, 1, 0, 0, 2,
                     "c.ebreak");
        check_dispatch(0, 0, 0, 5'd0, 5'd0, 5'd0, 64'd1,
                       0, 0, 0, 0, 1, 0, "c.ebreak dispatch");

        check_expand(32'hbeef_9502, 32'h0005_00e7, 1, 0, 0, 2,
                     "c.jalr a0");
        check_expand(32'hbeef_952e, 32'h00b5_0533, 1, 0, 0, 2,
                     "c.add a0,a1");
        check_expand(32'hbeef_dfaa, 32'h0ea1_2e23, 1, 0, 0, 2,
                     "c.swsp a0,252(sp)");
        check_expand(32'hbeef_ffae, 32'h1eb1_3c23, 1, 0, 0, 2,
                     "c.sdsp a1,504(sp)");

        // Architectural HINT encodings remain legal no-state-effect base
        // instructions.  Reserved encodings do not.
        check_expand(32'hbeef_0005, 32'h0010_0013, 1, 0, 0, 2,
                     "c.addi x0,1 hint");
        check_expand(32'hbeef_4005, 32'h0010_0013, 1, 0, 0, 2,
                     "c.li x0,1 hint");
        check_expand(32'hbeef_6005, 32'h0000_1037, 1, 0, 0, 2,
                     "c.lui x0,1 hint");
        check_expand(32'hbeef_8006, 32'h0010_0033, 1, 0, 0, 2,
                     "c.mv x0,x1 hint");
        check_expand(32'hbeef_9006, 32'h0010_0033, 1, 0, 0, 2,
                     "c.add x0,x1 hint");
        check_expand(32'hbeef_0006, 32'h0010_1013, 1, 0, 0, 2,
                     "c.slli x0,1 hint");

        check_expand(32'h0000_0000, `RV64_INSTR_NOP, 1, 1, 0, 2,
                     "reserved c.addi4spn imm=0");
        check_expand(32'h0000_2000, `RV64_INSTR_NOP, 1, 1, 0, 2,
                     "unsupported c.fld");
        check_expand(32'h0000_8000, `RV64_INSTR_NOP, 1, 1, 0, 2,
                     "reserved quadrant-0");
        check_expand(32'h0000_a000, `RV64_INSTR_NOP, 1, 1, 0, 2,
                     "unsupported c.fsd");
        check_expand(32'h0000_2001, `RV64_INSTR_NOP, 1, 1, 0, 2,
                     "reserved c.addiw rd=x0");
        check_expand(32'h0000_6101, `RV64_INSTR_NOP, 1, 1, 0, 2,
                     "reserved c.addi16sp imm=0");
        check_expand(32'h0000_6181, `RV64_INSTR_NOP, 1, 1, 0, 2,
                     "reserved c.lui imm=0");
        check_expand(32'h0000_9c41, `RV64_INSTR_NOP, 1, 1, 0, 2,
                     "reserved rv64 ca subop 10");
        check_expand(32'h0000_9c61, `RV64_INSTR_NOP, 1, 1, 0, 2,
                     "reserved rv64 ca subop 11");
        check_expand(32'h0000_2002, `RV64_INSTR_NOP, 1, 1, 0, 2,
                     "unsupported c.fldsp");
        check_expand(32'h0000_4002, `RV64_INSTR_NOP, 1, 1, 0, 2,
                     "reserved c.lwsp rd=x0");
        check_expand(32'h0000_6002, `RV64_INSTR_NOP, 1, 1, 0, 2,
                     "reserved c.ldsp rd=x0");
        check_expand(32'h0000_8002, `RV64_INSTR_NOP, 1, 1, 0, 2,
                     "reserved c.jr rs1=x0");
        check_expand(32'h0000_a002, `RV64_INSTR_NOP, 1, 1, 0, 2,
                     "unsupported c.fsdsp");

        check_expand(`RV64_INSTR_NOP, `RV64_INSTR_NOP, 0, 0, 0, 4,
                     "ordinary 32-bit pass-through");
        check_expand(32'h0000_001f, `RV64_INSTR_NOP, 0, 1, 1, 0,
                     "48-bit-or-longer prefix");

        // Structural sweep over the complete 16-bit encoding space.  This
        // proves parcel classification, upper-window independence, canonical
        // 32-bit output, and acceptance of every claimed-legal expansion by
        // the existing decoder.  Directed goldens above prove semantics.
        for (halfword = 0; halfword < 65536; halfword = halfword + 1) begin
            if ((halfword & 3) != 3) begin
                instr_window = {16'h0000, halfword[15:0]};
                #1;
                if (!compressed || unsupported_length ||
                    instr_bytes != 3'd2) begin
                    $fatal(1,
                        "classification sweep failed raw=%04x compressed=%0b unsupported=%0b bytes=%0d",
                        halfword[15:0],
                        compressed,
                        unsupported_length,
                        instr_bytes);
                end
                if (!c_illegal &&
                    (canonical_instr[1:0] != 2'b11 ||
                     !decode_valid || decode_illegal)) begin
                    $fatal(1,
                        "legal sweep expansion failed raw=%04x canonical=%08x base_valid=%0b base_illegal=%0b",
                        halfword[15:0],
                        canonical_instr,
                        decode_valid,
                        decode_illegal);
                end
                if (c_illegal && canonical_instr != `RV64_INSTR_NOP) begin
                    $fatal(1,
                        "illegal sweep output was not nop raw=%04x canonical=%08x",
                        halfword[15:0],
                        canonical_instr);
                end

                first_canonical = canonical_instr;
                first_illegal = c_illegal;
                first_unsupported = unsupported_length;
                first_bytes = instr_bytes;
                instr_window = {16'hffff, halfword[15:0]};
                #1;
                if (canonical_instr !== first_canonical ||
                    c_illegal !== first_illegal ||
                    unsupported_length !== first_unsupported ||
                    instr_bytes !== first_bytes) begin
                    $fatal(1,
                        "compressed decode depends on next parcel raw=%04x",
                        halfword[15:0]);
                end
            end
        end

        $display("PASS: RV64C decompression, legality, length, and decode handoff");
        $finish;
    end

endmodule
