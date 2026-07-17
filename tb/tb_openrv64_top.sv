`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-m.v"

module tb_openrv64_top;

    localparam logic [63:0] RESET_VECTOR = 64'h0000_0000_0000_0000;
    localparam int unsigned MEM_WORDS = 64;

    logic        clk;
    logic        rst_n;
    logic        mem_valid;
    logic        mem_ready;
    logic        mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0]  mem_wstrb;
    logic [63:0] mem_rdata;
    logic [63:0] dbg_pc;
    logic [31:0] dbg_instr;
    logic        dbg_halted;

    logic [63:0] memory [0:MEM_WORDS-1];
    logic        saw_jal_link_store;
    logic        saw_jalr_link_store;
    logic        saw_mul_store;
    logic        mem_addr_in_range;

    assign mem_addr_in_range = (mem_addr[63:3] < MEM_WORDS);
    assign mem_ready = mem_valid;
    assign mem_rdata = (mem_valid && mem_addr_in_range) ?
                       memory[mem_addr[8:3]] :
                       64'h0000_0000_0000_0000;

    openrv64_top #(
        .RESET_VECTOR(RESET_VECTOR),
        .ENABLE_RV64M(1'b1)
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
            enc_addi = {imm, rs1, `RV64_FUNCT3_ADD_SUB, rd, `RV64_OPCODE_OP_IMM};
        end
    endfunction

    function automatic logic [31:0] enc_sd;
        input logic [4:0] rs2;
        input logic [4:0] rs1;
        input logic [11:0] imm;
        begin
            enc_sd = {imm[11:5], rs2, rs1, `RV64_FUNCT3_SD, imm[4:0], `RV64_OPCODE_STORE};
        end
    endfunction

    function automatic logic [31:0] enc_jal;
        input logic [4:0] rd;
        input logic [20:0] imm;
        begin
            enc_jal = {imm[20], imm[10:1], imm[11], imm[19:12], rd, `RV64_OPCODE_JAL};
        end
    endfunction

    function automatic logic [31:0] enc_jalr;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [11:0] imm;
        begin
            enc_jalr = {imm, rs1, `RV64_FUNCT3_JALR, rd, `RV64_OPCODE_JALR};
        end
    endfunction

    function automatic logic [31:0] enc_mul;
        input logic [4:0] rd;
        input logic [4:0] rs1;
        input logic [4:0] rs2;
        begin
            enc_mul = {`RV64_M_FUNCT7, rs2, rs1, `RV64_M_FUNCT3_MUL, rd, `RV64_OPCODE_OP};
        end
    endfunction

    initial begin
        int i;

        for (i = 0; i < MEM_WORDS; i++) begin
            memory[i] = 64'h0000_0000_0000_0000;
        end

        put_instr(0,  enc_jal(5'd4, 21'h00010));           // jal  x4, +0x10
        put_instr(1,  `RV64_INSTR_EBREAK);                 // skipped by JAL
        put_instr(2,  `RV64_INSTR_NOP);
        put_instr(3,  `RV64_INSTR_NOP);
        put_instr(4,  enc_addi(5'd5, `RV64_REG_X0, 12'h030)); // addi x5, x0, 0x30
        put_instr(5,  enc_jalr(5'd6, 5'd5, 12'h000));      // jalr x6, 0(x5)
        put_instr(6,  `RV64_INSTR_EBREAK);                 // skipped by JALR
        put_instr(7,  `RV64_INSTR_NOP);
        put_instr(8,  `RV64_INSTR_NOP);
        put_instr(9,  `RV64_INSTR_NOP);
        put_instr(10, `RV64_INSTR_NOP);
        put_instr(11, `RV64_INSTR_NOP);
        put_instr(12, enc_sd(5'd4, `RV64_REG_X0, 12'h080)); // sd x4, 0x80(x0)
        put_instr(13, enc_sd(5'd6, `RV64_REG_X0, 12'h088)); // sd x6, 0x88(x0)
        put_instr(14, enc_addi(5'd7, `RV64_REG_X0, 12'd6)); // addi x7, x0, 6
        put_instr(15, enc_addi(5'd8, `RV64_REG_X0, 12'd7)); // addi x8, x0, 7
        put_instr(16, enc_mul(5'd9, 5'd7, 5'd8));           // mul x9, x7, x8
        put_instr(17, enc_sd(5'd9, `RV64_REG_X0, 12'h090)); // sd x9, 0x90(x0)
        put_instr(18, `RV64_INSTR_EBREAK);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            saw_jal_link_store <= 1'b0;
            saw_jalr_link_store <= 1'b0;
            saw_mul_store <= 1'b0;
        end else if (mem_valid && mem_write) begin
            int lane;

            if (mem_addr == 64'h0000_0000_0000_0080) begin
                saw_jal_link_store <= 1'b1;
            end else if (mem_addr == 64'h0000_0000_0000_0088) begin
                saw_jalr_link_store <= 1'b1;
            end else if (mem_addr == 64'h0000_0000_0000_0090) begin
                saw_mul_store <= 1'b1;
            end

            for (lane = 0; lane < 8; lane++) begin
                if (mem_wstrb[lane]) begin
                    memory[mem_addr[8:3]][8*lane +: 8] <=
                        mem_wdata[8*lane +: 8];
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && mem_valid) begin
            if (!mem_write && mem_wstrb != 8'h00) begin
                $fatal(1, "unexpected read strobes: %02x", mem_wstrb);
            end

            if (mem_write) begin
                if (mem_wstrb != 8'hff) begin
                    $fatal(1, "unexpected write strobes: %02x", mem_wstrb);
                end

                case (mem_addr)
                    64'h0000_0000_0000_0080: begin
                        if (mem_wdata != 64'h0000_0000_0000_0004) begin
                            $fatal(1, "unexpected JAL link data: %016x", mem_wdata);
                        end
                    end

                    64'h0000_0000_0000_0088: begin
                        if (mem_wdata != 64'h0000_0000_0000_0018) begin
                            $fatal(1, "unexpected JALR link data: %016x", mem_wdata);
                        end
                    end

                    64'h0000_0000_0000_0090: begin
                        if (mem_wdata != 64'h0000_0000_0000_002a) begin
                            $fatal(1, "unexpected MUL data: %016x", mem_wdata);
                        end
                    end

                    default: begin
                        $fatal(1, "unexpected write address: %016x", mem_addr);
                    end
                endcase
            end

            if (mem_addr[2:0] != 3'b000) begin
                $fatal(1, "unaligned memory address: %016x", mem_addr);
            end

            if (mem_addr[63:3] >= MEM_WORDS) begin
                $fatal(1, "memory address out of range: %016x", mem_addr);
            end
        end

        if (rst_n && dbg_halted) begin
            if (dbg_pc != 64'h0000_0000_0000_0048) begin
                $fatal(1, "halt pc mismatch: %016x", dbg_pc);
            end

            if (dbg_instr != `RV64_INSTR_EBREAK) begin
                $fatal(1, "halt instruction mismatch: %08x", dbg_instr);
            end

            #1;

            if (!saw_jal_link_store) begin
                $fatal(1, "JAL link store never reached memory bus");
            end

            if (!saw_jalr_link_store) begin
                $fatal(1, "JALR link store never reached memory bus");
            end

            if (!saw_mul_store) begin
                $fatal(1, "MUL result store never reached memory bus");
            end

            if (memory[16] != 64'h0000_0000_0000_0004) begin
                $fatal(1, "JAL link store mismatch: %016x", memory[16]);
            end

            if (memory[17] != 64'h0000_0000_0000_0018) begin
                $fatal(1, "JALR link store mismatch: %016x", memory[17]);
            end

            if (memory[18] != 64'h0000_0000_0000_002a) begin
                $fatal(1, "MUL result store mismatch: %016x", memory[18]);
            end

            $display("PASS: halted at pc=%016x instr=%08x jal_link=%016x jalr_link=%016x mul=%016x",
                     dbg_pc, dbg_instr, memory[16], memory[17], memory[18]);
            $finish;
        end
    end

    initial begin
        repeat (256) @(posedge clk);
        $fatal(1, "timeout waiting for halt");
    end

endmodule
