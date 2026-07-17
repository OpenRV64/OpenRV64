`timescale 1ns/1ps
`include "core/dispatch/dispatch.v"
`timescale 1ns/1ps

module tb_dispatch;

    logic clk;
    logic rst_n;
    logic flush;

    logic decode_valid;
    logic decode_clear;
    logic [`RV64_XLEN-1:0] decode_pc;
    logic [`RV64_INSTR_WIDTH-1:0] decode_instr;
    logic [`RV64_XLEN-1:0] decode_rs1_data;
    logic [`RV64_XLEN-1:0] decode_rs2_data;
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
    logic decode_word_op;
    logic decode_system;
    logic decode_fence;
    logic decode_illegal;
    logic decode_ebreak;
    logic decode_ecall;

    logic exec_valid;
    logic exec_clear;
    logic exec_alu_ready;
    logic exec_lsu_ready;
    logic exec_br_ready;
    logic exec_system_ready;
    logic [`RV64_XLEN-1:0] exec_pc;
    logic [`RV64_INSTR_WIDTH-1:0] exec_instr;
    logic [`RV64_XLEN-1:0] exec_rs1_data;
    logic [`RV64_XLEN-1:0] exec_rs2_data;
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
    logic exec_word_op;
    logic exec_system;
    logic exec_fence;
    logic exec_illegal;
    logic exec_ebreak;
    logic exec_ecall;

    logic wb_valid;
    logic wb_reg_write;
    logic [`RV64_REG_ADDR_WIDTH-1:0] wb_rd_addr;
    logic raw_hazard;
    logic waw_hazard;
    logic scoreboard_stall;

    openrv64_dispatch dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .decode_valid_i(decode_valid),
        .decode_clear_o(decode_clear),
        .decode_pc_i(decode_pc),
        .decode_instr_i(decode_instr),
        .decode_rs1_data_i(decode_rs1_data),
        .decode_rs2_data_i(decode_rs2_data),
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
        .decode_word_op_i(decode_word_op),
        .decode_system_i(decode_system),
        .decode_fence_i(decode_fence),
        .decode_illegal_i(decode_illegal),
        .decode_ebreak_i(decode_ebreak),
        .decode_ecall_i(decode_ecall),
        .exec_valid_o(exec_valid),
        .exec_clear_i(exec_clear),
        .exec_alu_ready_i(exec_alu_ready),
        .exec_lsu_ready_i(exec_lsu_ready),
        .exec_br_ready_i(exec_br_ready),
        .exec_system_ready_i(exec_system_ready),
        .exec_pc_o(exec_pc),
        .exec_instr_o(exec_instr),
        .exec_rs1_data_o(exec_rs1_data),
        .exec_rs2_data_o(exec_rs2_data),
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
        .exec_word_op_o(exec_word_op),
        .exec_system_o(exec_system),
        .exec_fence_o(exec_fence),
        .exec_illegal_o(exec_illegal),
        .exec_ebreak_o(exec_ebreak),
        .exec_ecall_o(exec_ecall),
        .wb_valid_i(wb_valid),
        .wb_reg_write_i(wb_reg_write),
        .wb_rd_addr_i(wb_rd_addr),
        .raw_hazard_o(raw_hazard),
        .waw_hazard_o(waw_hazard),
        .scoreboard_stall_o(scoreboard_stall)
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
            decode_rs1_data = 64'h0;
            decode_rs2_data = 64'h0;
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
            decode_word_op = 1'b0;
            decode_system = 1'b0;
            decode_fence = 1'b0;
            decode_illegal = 1'b0;
            decode_ebreak = 1'b0;
            decode_ecall = 1'b0;
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

    task automatic drive_lsu_op;
        begin
            clear_decode();
            decode_valid = 1'b1;
            decode_mem_read = 1'b1;
            decode_lsu_op = `RV64_LSU_OP_LD;
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
        exec_clear = 1'b1;
        exec_alu_ready = 1'b1;
        exec_lsu_ready = 1'b1;
        exec_br_ready = 1'b1;
        exec_system_ready = 1'b1;
        wb_valid = 1'b0;
        wb_reg_write = 1'b0;
        wb_rd_addr = `RV64_REG_X0;
        clear_decode();

        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        drive_alu_write(5'd1);
        check_dispatch(1'b1, 1'b0, 1'b0, 1'b0, "accept producer x1");
        @(posedge clk);
        @(negedge clk);

        drive_alu_read(5'd1);
        check_dispatch(1'b0, 1'b1, 1'b1, 1'b0, "stall RAW x1");

        wb_valid = 1'b1;
        wb_reg_write = 1'b1;
        wb_rd_addr = 5'd1;
        check_dispatch(1'b1, 1'b1, 1'b0, 1'b0, "same-cycle WB clears RAW");
        @(posedge clk);
        @(negedge clk);
        wb_valid = 1'b0;
        wb_reg_write = 1'b0;
        wb_rd_addr = `RV64_REG_X0;

        drive_alu_write(5'd2);
        check_dispatch(1'b1, 1'b1, 1'b0, 1'b0, "accept producer x2");
        @(posedge clk);
        @(negedge clk);

        drive_alu_write(5'd2);
        check_dispatch(1'b0, 1'b1, 1'b0, 1'b1, "stall WAW x2");

        wb_valid = 1'b1;
        wb_reg_write = 1'b1;
        wb_rd_addr = 5'd2;
        check_dispatch(1'b1, 1'b1, 1'b0, 1'b0, "same-cycle WB clears WAW");
        @(posedge clk);
        @(negedge clk);
        wb_valid = 1'b0;
        wb_reg_write = 1'b0;
        wb_rd_addr = `RV64_REG_X0;

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
        check_dispatch(1'b1, 1'b0, 1'b0, 1'b0, "flush clears active dispatch");
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;
        exec_clear = 1'b1;

        drive_alu_read(5'd3);
        check_dispatch(1'b1, 1'b0, 1'b0, 1'b0, "x3 clear after flush");
        @(posedge clk);
        @(negedge clk);

        $display("PASS: dispatch scoreboard and unit readiness");
        $finish;
    end

endmodule
