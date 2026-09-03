`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-zicsr.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"
`timescale 1ns/1ps

module tb_dispatch;

    logic clk;
    logic rst_n;
    logic flush;
    logic scoreboard_clear;

    logic decode_valid;
    logic decode_clear;
    logic [`RV64_XLEN-1:0] decode_pc;
    logic [`RV64_INSTR_WIDTH-1:0] decode_instr;
    logic [`RV64_XLEN-1:0] decode_imm;
    logic decode_uses_rs1;
    logic decode_uses_rs2;
    logic [`RV64_REG_ADDR_WIDTH-1:0] decode_rs1_addr;
    logic [`RV64_REG_ADDR_WIDTH-1:0] decode_rs2_addr;
    logic [`RV64_REG_ADDR_WIDTH-1:0] decode_rd_addr;
    logic [`RV64_ALU_EXT_WIDTH-1:0] decode_alu_ext;
    logic [`RV64_ALU_OP_WIDTH-1:0] decode_alu_op;
    logic [`RV64_LSU_OP_WIDTH-1:0] decode_lsu_op;
    logic [`RV64_BR_OP_WIDTH-1:0] decode_br_op;
    logic decode_reg_write;
    logic decode_mem_read;
    logic decode_mem_write;
    logic decode_branch;
    logic decode_jump;
    logic decode_predicted_taken;
    logic decode_word_op;
    logic decode_system;
    logic decode_fence;
    logic decode_illegal;
    logic decode_ebreak;
    logic decode_ecall;
    logic decode_instr_fault;
    logic decode_instr_page_fault;

    logic exec_valid;
    logic exec_clear;
    logic exec_alu_ready;
    logic exec_lsu_ready;
    logic exec_br_ready;
    logic exec_system_ready;
    logic [`RV64_XLEN-1:0] exec_pc;
    logic [`RV64_INSTR_WIDTH-1:0] exec_instr;
    logic [63:0] exec_trace_id;
    logic [`RV64_REG_ADDR_WIDTH-1:0] exec_rs1_addr;
    logic [`RV64_REG_ADDR_WIDTH-1:0] exec_rs2_addr;
    logic [`RV64_XLEN-1:0] exec_imm;
    logic [`RV64_REG_ADDR_WIDTH-1:0] exec_rd_addr;
    logic [`RV64_ALU_EXT_WIDTH-1:0] exec_alu_ext;
    logic [`RV64_ALU_OP_WIDTH-1:0] exec_alu_op;
    logic [`RV64_LSU_OP_WIDTH-1:0] exec_lsu_op;
    logic [`RV64_BR_OP_WIDTH-1:0] exec_br_op;
    logic exec_reg_write;
    logic exec_mem_read;
    logic exec_mem_write;
    logic exec_branch;
    logic exec_jump;
    logic exec_predicted_taken;
    logic exec_word_op;
    logic exec_system;
    logic exec_fence;
    logic exec_illegal;
    logic exec_ebreak;
    logic exec_ecall;
    logic exec_instr_fault;
    logic exec_instr_page_fault;

    logic retire_valid;
    logic retire_csr;
    logic retire_fence;
    logic retire_uses_rs1;
    logic retire_uses_rs2;
    logic [`RV64_REG_ADDR_WIDTH-1:0] retire_rs1_addr;
    logic [`RV64_REG_ADDR_WIDTH-1:0] retire_rs2_addr;
    logic retire_reg_write;
    logic [`RV64_REG_ADDR_WIDTH-1:0] retire_rd_addr;
    logic raw_hazard;
    logic waw_hazard;
    logic scoreboard_stall;

    openrv64_dispatch dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .scoreboard_clear_1p_i(scoreboard_clear),
        .decode_valid_i(decode_valid),
        .decode_clear_o(decode_clear),
        .decode_pc_i(decode_pc),
        .decode_instr_i(decode_instr),
        .decode_trace_id_i(64'h1234_5678_9abc_def0),
        .decode_imm_i(decode_imm),
        .decode_uses_rs1_i(decode_uses_rs1),
        .decode_uses_rs2_i(decode_uses_rs2),
        .decode_rs1_addr_i(decode_rs1_addr),
        .decode_rs2_addr_i(decode_rs2_addr),
        .decode_rd_addr_i(decode_rd_addr),
        .decode_alu_ext_i(decode_alu_ext),
        .decode_alu_op_i(decode_alu_op),
        .decode_lsu_op_i(decode_lsu_op),
        .decode_br_op_i(decode_br_op),
        .decode_reg_write_i(decode_reg_write),
        .decode_mem_read_i(decode_mem_read),
        .decode_mem_write_i(decode_mem_write),
        .decode_branch_i(decode_branch),
        .decode_jump_i(decode_jump),
        .decode_predicted_taken_i(decode_predicted_taken),
        .decode_word_op_i(decode_word_op),
        .decode_system_i(decode_system),
        .decode_fence_i(decode_fence),
        .decode_illegal_i(decode_illegal),
        .decode_ebreak_i(decode_ebreak),
        .decode_ecall_i(decode_ecall),
        .decode_instr_fault_i(decode_instr_fault),
        .decode_instr_page_fault_i(decode_instr_page_fault),
        .exec_valid_o(exec_valid),
        .exec_clear_i(exec_clear),
        .exec_alu_ready_i(exec_alu_ready),
        .exec_lsu_ready_i(exec_lsu_ready),
        .exec_br_ready_i(exec_br_ready),
        .exec_system_ready_i(exec_system_ready),
        .forward_ex_valid_i(1'b0),
        .forward_ex_rd_addr_i(`RV64_REG_X0),
        .forward_mem_valid_i(1'b0),
        .forward_mem_rd_addr_i(`RV64_REG_X0),
        .exec_pc_o(exec_pc),
        .exec_instr_o(exec_instr),
        .exec_trace_id_o(exec_trace_id),
        .exec_rs1_addr_o(exec_rs1_addr),
        .exec_rs2_addr_o(exec_rs2_addr),
        .exec_imm_o(exec_imm),
        .exec_rd_addr_o(exec_rd_addr),
        .exec_alu_ext_o(exec_alu_ext),
        .exec_alu_op_o(exec_alu_op),
        .exec_lsu_op_o(exec_lsu_op),
        .exec_br_op_o(exec_br_op),
        .exec_reg_write_o(exec_reg_write),
        .exec_mem_read_o(exec_mem_read),
        .exec_mem_write_o(exec_mem_write),
        .exec_branch_o(exec_branch),
        .exec_jump_o(exec_jump),
        .exec_predicted_taken_o(exec_predicted_taken),
        .exec_word_op_o(exec_word_op),
        .exec_system_o(exec_system),
        .exec_fence_o(exec_fence),
        .exec_illegal_o(exec_illegal),
        .exec_ebreak_o(exec_ebreak),
        .exec_ecall_o(exec_ecall),
        .exec_instr_fault_o(exec_instr_fault),
        .exec_instr_page_fault_o(exec_instr_page_fault),
        .retire_valid_i(retire_valid),
        .retire_csr_i(retire_csr),
        .retire_fence_i(retire_fence),
        .retire_uses_rs1_i(retire_uses_rs1),
        .retire_uses_rs2_i(retire_uses_rs2),
        .retire_rs1_addr_i(retire_rs1_addr),
        .retire_rs2_addr_i(retire_rs2_addr),
        .retire_reg_write_i(retire_reg_write),
        .retire_rd_addr_i(retire_rd_addr),
        .raw_hazard_o(raw_hazard),
        .waw_hazard_o(waw_hazard),
        .scoreboard_stall_o(scoreboard_stall),
        .squash_frontend_3p_i(1'b0),
        .squash_inclusive_3p_i(1'b0),
        .decode_valid_3p_i(3'b000),
        .decode_payload_3p_i({3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}}),
        .decode_uses_rs1_3p_i(3'b000),
        .decode_uses_rs2_3p_i(3'b000),
        .gpr_read_data_3p_i({6*`RV64_XLEN{1'b0}}),
        .allocation_ready_3p_i(1'b0),
        .allocation_id_3p_i(
            {3*`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .allocation_slot_3p_i(9'd0),
        .pipe_ready_3p_i(
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}}),
        .forward_valid_3p_i(2'b00),
        .forward_rd_addr_3p_i({2*`RV64_REG_ADDR_WIDTH{1'b0}}),
        .forward_map_valid_3p_i(32'd0),
        .forward_map_data_3p_i({32*`RV64_XLEN{1'b0}}),
        .retire_valid_3p_i(3'b000),
        .retire_uses_rs1_3p_i(3'b000),
        .retire_uses_rs2_3p_i(3'b000),
        .retire_rs1_addr_3p_i({3*`RV64_REG_ADDR_WIDTH{1'b0}}),
        .retire_rs2_addr_3p_i({3*`RV64_REG_ADDR_WIDTH{1'b0}}),
        .retire_reg_write_3p_i(3'b000),
        .retire_rd_addr_3p_i({3*`RV64_REG_ADDR_WIDTH{1'b0}}),
        .retire_hard_3p_i(3'b000)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic clear_decode;
        begin
            decode_valid = 1'b0;
            decode_pc = 64'h0;
            decode_instr = `RV64_INSTR_NOP;
            decode_imm = 64'h0;
            decode_uses_rs1 = 1'b0;
            decode_uses_rs2 = 1'b0;
            decode_rs1_addr = `RV64_REG_X0;
            decode_rs2_addr = `RV64_REG_X0;
            decode_rd_addr = `RV64_REG_X0;
            decode_alu_ext = `RV64_ALU_EXT_INVALID;
            decode_alu_op = `RV64_ALU_OP_ADD;
            decode_lsu_op = `RV64_LSU_OP_INVALID;
            decode_br_op = `RV64_BR_OP_INVALID;
            decode_reg_write = 1'b0;
            decode_mem_read = 1'b0;
            decode_mem_write = 1'b0;
            decode_branch = 1'b0;
            decode_jump = 1'b0;
            decode_predicted_taken = 1'b0;
            decode_word_op = 1'b0;
            decode_system = 1'b0;
            decode_fence = 1'b0;
            decode_illegal = 1'b0;
            decode_ebreak = 1'b0;
            decode_ecall = 1'b0;
            decode_instr_fault = 1'b0;
            decode_instr_page_fault = 1'b0;
        end
    endtask

    task automatic check_exec_selectors;
        input [`RV64_REG_ADDR_WIDTH-1:0] exp_rs1;
        input [`RV64_REG_ADDR_WIDTH-1:0] exp_rs2;
        input [`RV64_REG_ADDR_WIDTH-1:0] exp_rd;
        input [8*48-1:0]                 label;
        begin
            #1;

            if (exec_rs1_addr !== exp_rs1 ||
                exec_rs2_addr !== exp_rs2 ||
                exec_rd_addr !== exp_rd ||
                exec_trace_id !== 64'h1234_5678_9abc_def0) begin
                $fatal(1,
                    "%0s: exec selectors rs1=%0d/%0d rs2=%0d/%0d rd=%0d/%0d",
                    label,
                    exec_rs1_addr, exp_rs1,
                    exec_rs2_addr, exp_rs2,
                    exec_rd_addr, exp_rd);
            end
        end
    endtask

    task automatic drive_alu_write;
        input [`RV64_REG_ADDR_WIDTH-1:0] rd;
        begin
            clear_decode();
            decode_valid = 1'b1;
            decode_pc = {59'h0, rd};
            decode_instr = {27'h0, rd};
            decode_rd_addr = rd;
            decode_reg_write = 1'b1;
            decode_alu_ext = `RV64_ALU_EXT_BASE;
            decode_alu_op = `RV64_ALU_OP_ADD;
        end
    endtask

    task automatic drive_alu_read;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs1;
        begin
            clear_decode();
            decode_valid = 1'b1;
            decode_pc = 64'h100;
            decode_instr = 32'h0000_0013;
            decode_uses_rs1 = 1'b1;
            decode_rs1_addr = rs1;
            decode_alu_ext = `RV64_ALU_EXT_BASE;
            decode_alu_op = `RV64_ALU_OP_ADD;
        end
    endtask

    task automatic drive_alu_read2;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs1;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs2;
        begin
            clear_decode();
            decode_valid = 1'b1;
            decode_pc = 64'h104;
            decode_instr = 32'h0000_0033;
            decode_uses_rs1 = 1'b1;
            decode_uses_rs2 = 1'b1;
            decode_rs1_addr = rs1;
            decode_rs2_addr = rs2;
            decode_alu_ext = `RV64_ALU_EXT_BASE;
            decode_alu_op = `RV64_ALU_OP_ADD;
        end
    endtask

    task automatic clear_retire;
        begin
            retire_valid = 1'b0;
            retire_csr = 1'b0;
            retire_fence = 1'b0;
            retire_uses_rs1 = 1'b0;
            retire_uses_rs2 = 1'b0;
            retire_rs1_addr = `RV64_REG_X0;
            retire_rs2_addr = `RV64_REG_X0;
            retire_reg_write = 1'b0;
            retire_rd_addr = `RV64_REG_X0;
        end
    endtask

    task automatic retire_write;
        input [`RV64_REG_ADDR_WIDTH-1:0] rd;
        begin
            clear_retire();
            retire_valid = 1'b1;
            retire_reg_write = 1'b1;
            retire_rd_addr = rd;
        end
    endtask

    task automatic retire_read;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs1;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs2;
        begin
            clear_retire();
            retire_valid = 1'b1;
            retire_uses_rs1 = (rs1 != `RV64_REG_X0);
            retire_uses_rs2 = (rs2 != `RV64_REG_X0);
            retire_rs1_addr = rs1;
            retire_rs2_addr = rs2;
        end
    endtask

    task automatic drive_lsu_op;
        begin
            clear_decode();
            decode_valid = 1'b1;
            decode_mem_read = 1'b1;
            decode_lsu_op = `RV64_LSU_OP_LD;
        end
    endtask

    task automatic drive_csr;
        begin
            clear_decode();
            decode_valid = 1'b1;
            decode_instr = {12'h300, 5'd0,
                            `RV64_ZICSR_FUNCT3_CSRRS, 5'd0,
                            `RV64_OPCODE_SYSTEM};
            decode_system = 1'b1;
        end
    endtask

    task automatic drive_fence;
        begin
            clear_decode();
            decode_valid = 1'b1;
            decode_instr = 32'h0000_000f;
            decode_fence = 1'b1;
        end
    endtask

    task automatic check_dispatch;
        input exp_decode_clear;
        input exp_exec_valid;
        input exp_raw;
        input exp_waw;
        input [8*48-1:0] label;
        begin
            #1;

            if (decode_clear !== exp_decode_clear ||
                exec_valid !== exp_exec_valid ||
                raw_hazard !== exp_raw ||
                waw_hazard !== exp_waw) begin
                $fatal(1,
                    "%0s: decode_clear=%0b/%0b exec_valid=%0b/%0b raw=%0b/%0b waw=%0b/%0b",
                    label,
                    decode_clear, exp_decode_clear,
                    exec_valid, exp_exec_valid,
                    raw_hazard, exp_raw,
                    waw_hazard, exp_waw);
            end
        end
    endtask

    initial begin
        flush = 1'b0;
        scoreboard_clear = 1'b0;
        exec_clear = 1'b1;
        exec_alu_ready = 1'b1;
        exec_lsu_ready = 1'b1;
        exec_br_ready = 1'b1;
        exec_system_ready = 1'b1;
        clear_retire();
        clear_decode();

        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        drive_alu_write(5'd1);
        check_dispatch(1'b1, 1'b0, 1'b0, 1'b0, "accept producer x1");
        @(posedge clk);
        @(negedge clk);
        check_exec_selectors(`RV64_REG_X0, `RV64_REG_X0, 5'd1, "producer x1 selectors");

        drive_alu_read(5'd1);
        check_dispatch(1'b0, 1'b1, 1'b1, 1'b0, "stall RAW x1");

        retire_write(5'd1);
        check_dispatch(1'b1, 1'b1, 1'b0, 1'b0, "same-cycle retire clears RAW");
        @(posedge clk);
        @(negedge clk);
        clear_retire();

        drive_alu_write(5'd1);
        check_dispatch(1'b0, 1'b1, 1'b0, 1'b0, "active read x1 blocks writer");
        retire_read(5'd1, `RV64_REG_X0);
        check_dispatch(1'b1, 1'b1, 1'b0, 1'b0, "retire read x1 clears writer");
        @(posedge clk);
        @(negedge clk);
        clear_retire();

        drive_alu_write(5'd2);
        check_dispatch(1'b1, 1'b1, 1'b0, 1'b0, "accept producer x2");
        @(posedge clk);
        @(negedge clk);

        drive_alu_write(5'd2);
        check_dispatch(1'b0, 1'b1, 1'b0, 1'b1, "stall WAW x2");

        retire_write(5'd2);
        check_dispatch(1'b1, 1'b1, 1'b0, 1'b0, "same-cycle retire clears WAW");
        @(posedge clk);
        @(negedge clk);
        clear_retire();

        drive_alu_read2(5'd4, 5'd4);
        check_dispatch(1'b1, 1'b1, 1'b0, 1'b0, "accept double read x4");
        @(posedge clk);
        @(negedge clk);

        drive_alu_read(5'd4);
        check_dispatch(1'b1, 1'b1, 1'b0, 1'b0, "accept parallel read x4");
        @(posedge clk);
        @(negedge clk);

        drive_alu_write(5'd4);
        check_dispatch(1'b0, 1'b1, 1'b0, 1'b0, "read count blocks write x4");
        retire_read(5'd4, 5'd4);
        check_dispatch(1'b0, 1'b1, 1'b0, 1'b0, "partial read retire still blocks x4");
        @(posedge clk);
        @(negedge clk);
        clear_retire();

        retire_read(5'd4, `RV64_REG_X0);
        check_dispatch(1'b1, 1'b0, 1'b0, 1'b0, "all reads retired clears x4 write");
        @(posedge clk);
        @(negedge clk);
        clear_retire();

        exec_lsu_ready = 1'b0;
        drive_lsu_op();
        check_dispatch(1'b0, 1'b1, 1'b0, 1'b0, "stall LSU unit not ready");
        exec_lsu_ready = 1'b1;
        check_dispatch(1'b1, 1'b1, 1'b0, 1'b0, "accept LSU when ready");
        @(posedge clk);
        @(negedge clk);

        drive_alu_write(5'd3);
        check_dispatch(1'b1, 1'b1, 1'b0, 1'b0, "accept held producer x3");
        @(posedge clk);
        @(negedge clk);
        exec_clear = 1'b0;

        drive_alu_read(5'd3);
        check_dispatch(1'b0, 1'b1, 1'b1, 1'b0, "held x3 blocks consumer");

        flush = 1'b1;
        check_dispatch(1'b1, 1'b1, 1'b0, 1'b0,
                       "flush inhibits without same-cycle valid change");
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;
        exec_clear = 1'b1;

        drive_alu_read(5'd3);
        check_dispatch(1'b1, 1'b0, 1'b0, 1'b0, "x3 clear after flush");
        @(posedge clk);
        @(negedge clk);

        flush = 1'b1;
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;

        // A normal branch/jump redirect rolls back the younger registered
        // dispatch entry, but an older producer may still be downstream.  In
        // particular, SUB a0 followed by RET must keep a0 busy until SUB
        // retires so the caller cannot observe the old return value.
        drive_alu_write(5'd10);
        check_dispatch(1'b1, 1'b0, 1'b0, 1'b0,
                       "accept older redirect producer x10");
        @(posedge clk);
        @(negedge clk);

        drive_alu_write(5'd11);
        check_dispatch(1'b1, 1'b1, 1'b0, 1'b0,
                       "accept younger redirect victim x11");
        @(posedge clk);
        @(negedge clk);

        clear_decode();
        flush = 1'b1;
        check_dispatch(1'b1, 1'b1, 1'b0, 1'b0,
                       "redirect holds current valid through flush edge");
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;

        drive_alu_read(5'd10);
        check_dispatch(1'b0, 1'b0, 1'b1, 1'b0,
                       "redirect preserves older x10 ownership");
        retire_write(5'd10);
        check_dispatch(1'b1, 1'b0, 1'b0, 1'b0,
                       "x10 consumer releases only at retirement");
        @(posedge clk);
        @(negedge clk);
        clear_retire();

        drive_alu_read(5'd11);
        check_dispatch(1'b1, 1'b1, 1'b0, 1'b0,
                       "redirect rolls back younger x11 ownership");
        @(posedge clk);
        @(negedge clk);

        clear_decode();
        scoreboard_clear = 1'b1;
        flush = 1'b1;
        @(posedge clk);
        @(negedge clk);
        scoreboard_clear = 1'b0;
        flush = 1'b0;

        drive_csr();
        check_dispatch(1'b1, 1'b0, 1'b0, 1'b0, "accept csr");
        @(posedge clk);
        @(negedge clk);

        drive_alu_read(5'd6);
        check_dispatch(1'b0, 1'b1, 1'b0, 1'b0, "csr active blocks dispatch");
        @(posedge clk);
        @(negedge clk);
        check_dispatch(1'b0, 1'b0, 1'b0, 1'b0, "csr retired slot remains blocked");

        clear_retire();
        retire_valid = 1'b1;
        retire_csr = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear_retire();
        check_dispatch(1'b1, 1'b0, 1'b0, 1'b0, "csr retire unblocks dispatch");

        drive_fence();
        check_dispatch(1'b1, 1'b0, 1'b0, 1'b0, "accept fence");
        @(posedge clk);
        @(negedge clk);

        drive_alu_read(5'd7);
        check_dispatch(1'b0, 1'b1, 1'b0, 1'b0, "fence active blocks dispatch");
        if (!exec_fence) begin
            $fatal(1, "accepted fence was not routed to execution");
        end
        @(posedge clk);
        @(negedge clk);
        check_dispatch(1'b0, 1'b0, 1'b0, 1'b0, "fence remains active after issue");

        clear_retire();
        retire_valid = 1'b1;
        retire_fence = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear_retire();
        check_dispatch(1'b1, 1'b0, 1'b0, 1'b0, "fence retire unblocks dispatch");

        $display("PASS: dispatch scoreboard and serializing interlocks");
        $finish;
    end

endmodule
