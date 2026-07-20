`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/exec/bp/defs.v"

module tb_bp_context #(
    parameter logic [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE =
        `OPENRV64_BP_ALWAYS_BRANCH,
    parameter bit ENABLE_PREDECODE_TARGETS = 1'b1,
    parameter bit BP_RAS_ENABLE = 1'b1,
    parameter int unsigned BP_RAS_DEPTH = 8
);

    localparam logic [63:0] RESET_VECTOR = 64'h0000_0000_0000_0100;
    localparam int unsigned RESET_INSTR_INDEX = RESET_VECTOR >> 2;
    localparam int unsigned MEM_WORDS = 64;

    logic clk;
    logic rst_n;
    logic mem_valid;
    logic mem_ready;
    logic mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0] mem_wstrb;
    logic [63:0] mem_rdata;
    logic [63:0] dbg_pc;
    logic [31:0] dbg_instr;
    logic dbg_halted;
    logic [63:0] memory [0:MEM_WORDS-1];
    logic saw_result_store;
    integer prediction_count;
    integer correction_count;

    assign mem_ready = mem_valid;
    assign mem_rdata = (mem_valid &&
                        (mem_addr[63:3] < MEM_WORDS)) ?
                       memory[mem_addr[8:3]] : 64'd0;

    openrv64_top #(
        .RESET_VECTOR(RESET_VECTOR),
        .BP_TYPE(BP_TYPE),
        .BP_RAS_ENABLE(BP_RAS_ENABLE),
        .BP_RAS_DEPTH(BP_RAS_DEPTH),
        .ENABLE_PREDECODE_TARGETS(ENABLE_PREDECODE_TARGETS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .mem_valid(mem_valid),
        .mem_ready(mem_ready),
        .mem_write(mem_write),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .mem_error(1'b0),
        .irq_m_software(1'b0),
        .irq_m_timer(1'b0),
        .irq_m_external(1'b0),
        .irq_s_software(1'b0),
        .irq_s_timer(1'b0),
        .irq_s_external(1'b0),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic put_instr;
        input int unsigned instr_index;
        input logic [31:0] instr;
        begin
            if (instr_index[0]) begin
                memory[instr_index >> 1][63:32] = instr;
            end else begin
                memory[instr_index >> 1][31:0] = instr;
            end
        end
    endtask

    function automatic logic [31:0] enc_addi;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [11:0] imm;
        begin
            enc_addi = {imm, rs1, `RV64_FUNCT3_ADD_SUB,
                        rd, `RV64_OPCODE_OP_IMM};
        end
    endfunction

    function automatic logic [31:0] enc_branch;
        input logic [2:0] funct3;
        input logic [4:0] rs1;
        input logic [4:0] rs2;
        input logic [12:0] imm;
        begin
            enc_branch = {imm[12], imm[10:5], rs2, rs1, funct3,
                          imm[4:1], imm[11], `RV64_OPCODE_BRANCH};
        end
    endfunction

    function automatic logic [31:0] enc_sd;
        input logic [4:0] rs2;
        input logic [4:0] rs1;
        input logic [11:0] imm;
        begin
            enc_sd = {imm[11:5], rs2, rs1, `RV64_FUNCT3_SD,
                      imm[4:0], `RV64_OPCODE_STORE};
        end
    endfunction

    function automatic logic expected_prediction;
        input logic [63:0] pc;
        begin
            case (BP_TYPE)
                `OPENRV64_BP_ALWAYS_BRANCH: expected_prediction = 1'b1;
                `OPENRV64_BP_ALWAYS_DECLINE: expected_prediction = 1'b0;
                `OPENRV64_BP_REPEAT_LAST: begin
                    case (pc)
                        64'h104: expected_prediction = 1'b0;
                        64'h10c: expected_prediction = 1'b0;
                        64'h114: expected_prediction = 1'b1;
                        64'h11c: expected_prediction = 1'b1;
                        default: expected_prediction = 1'bx;
                    endcase
                end
                `OPENRV64_BP_BTFNT,
                `OPENRV64_BP_BIMODAL: begin
                    case (pc)
                        64'h104: expected_prediction = 1'b1;
                        64'h10c,
                        64'h114,
                        64'h11c: expected_prediction = 1'b0;
                        default: expected_prediction = 1'bx;
                    endcase
                end
                `OPENRV64_BP_GSHARE_BTB: begin
                    // At 0x11c, PC[9:2] XOR GHR aliases the weak-taken
                    // entry trained by 0x114.  This is intentional gshare
                    // behavior and makes the tiny context test exercise an
                    // actual history collision.
                    case (pc)
                        64'h104: expected_prediction = 1'b1;
                        64'h10c,
                        64'h114: expected_prediction = 1'b0;
                        64'h11c: expected_prediction = 1'b1;
                        default: expected_prediction = 1'bx;
                    endcase
                end
                default: expected_prediction = 1'bx;
            endcase
        end
    endfunction

    initial begin
        int i;

        for (i = 0; i < MEM_WORDS; i++) begin
            memory[i] = 64'd0;
        end

        put_instr(RESET_INSTR_INDEX + 0,
                  enc_addi(5'd1, `RV64_REG_X0, 12'd1));
        // Outcomes are N, T, T, N.  Repeat-last should predict N, N, T, T.
        put_instr(RESET_INSTR_INDEX + 1,
                  enc_branch(`RV64_FUNCT3_BNE, 5'd1, 5'd1, 13'h1ff8));
        put_instr(RESET_INSTR_INDEX + 2,
                  enc_addi(5'd2, `RV64_REG_X0, 12'd1));
        put_instr(RESET_INSTR_INDEX + 3,
                  enc_branch(`RV64_FUNCT3_BEQ, 5'd1, 5'd1, 13'h008));
        put_instr(RESET_INSTR_INDEX + 4,
                  enc_addi(5'd2, `RV64_REG_X0, 12'd99));
        put_instr(RESET_INSTR_INDEX + 5,
                  enc_branch(`RV64_FUNCT3_BEQ, 5'd1, 5'd1, 13'h008));
        put_instr(RESET_INSTR_INDEX + 6,
                  enc_addi(5'd2, `RV64_REG_X0, 12'd99));
        put_instr(RESET_INSTR_INDEX + 7,
                  enc_branch(`RV64_FUNCT3_BNE, 5'd1, 5'd1, 13'h008));
        put_instr(RESET_INSTR_INDEX + 8,
                  enc_addi(5'd2, 5'd2, 12'd1));
        put_instr(RESET_INSTR_INDEX + 9,
                  enc_sd(5'd2, `RV64_REG_X0, 12'h080));
        put_instr(RESET_INSTR_INDEX + 10, `RV64_INSTR_EBREAK);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            saw_result_store <= 1'b0;
            prediction_count <= 0;
            correction_count <= 0;
        end else begin
            if (dut.u_core.bp_branch_allocate) begin
                if (dut.u_core.if_id_pc == 64'h104 &&
                    (dut.u_core.bp_predict_target !== 64'hfc ||
                     (ENABLE_PREDECODE_TARGETS &&
                      dut.u_core.if_id_predecode_offset !== 20'hffffc))) begin
                    $fatal(1,
                           "BP type %0d negative target mismatch: offset=%05x target=%016x",
                           BP_TYPE, dut.u_core.if_id_predecode_offset,
                           dut.u_core.bp_predict_target);
                end
                if (dut.u_core.bp_prediction_taken !==
                    expected_prediction(dut.u_core.if_id_pc)) begin
                    $fatal(1,
                           "BP type %0d prediction mismatch at pc=%016x: got=%0b expected=%0b",
                           BP_TYPE, dut.u_core.if_id_pc,
                           dut.u_core.bp_prediction_taken,
                           expected_prediction(dut.u_core.if_id_pc));
                end
                prediction_count <= prediction_count + 1;
            end

            if (dut.u_core.hard_flush_redirect_req) begin
                correction_count <= correction_count + 1;
            end

            if (dut.u_core.bp_decode_stall) begin
                $fatal(1, "direct branch unexpectedly stalled in BP type %0d",
                       BP_TYPE);
            end

            if (mem_valid && mem_write) begin
                int lane;

                if (mem_addr != 64'h80 || mem_wstrb != 8'hff ||
                    mem_wdata != 64'd2) begin
                    $fatal(1,
                           "BP type %0d bad result store: addr=%016x strb=%02x data=%016x",
                           BP_TYPE, mem_addr, mem_wstrb, mem_wdata);
                end

                saw_result_store <= 1'b1;
                for (lane = 0; lane < 8; lane++) begin
                    if (mem_wstrb[lane]) begin
                        memory[mem_addr[8:3]][8*lane +: 8] <=
                            mem_wdata[8*lane +: 8];
                    end
                end
            end

            if (dbg_halted) begin
                if (!saw_result_store || prediction_count != 4 ||
                    correction_count !=
                        ((BP_TYPE == `OPENRV64_BP_GSHARE_BTB) ? 4 :
                         (((BP_TYPE == `OPENRV64_BP_BTFNT) ||
                           (BP_TYPE == `OPENRV64_BP_BIMODAL)) ? 3 : 2))) begin
                    $fatal(1,
                           "BP type %0d summary mismatch: store=%0b predictions=%0d corrections=%0d",
                           BP_TYPE, saw_result_store,
                           prediction_count, correction_count);
                end

                $display("PASS: BP type %0d predictions=%0d corrections=%0d result=%0d",
                         BP_TYPE, prediction_count, correction_count,
                         memory[16]);
                $finish;
            end
        end
    end

    initial begin
        repeat (300) @(posedge clk);
        $fatal(1, "timeout in BP type %0d", BP_TYPE);
    end

endmodule
