`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/exec/bp/defs.v"
`include "core/isa/rv64-i.v"

module tb_top_3p_banked;
    localparam integer INSTRUCTION_COUNT = 70;

    reg clk;
    reg rst_n;
    wire mem_valid;
    reg mem_ready;
    wire mem_write;
    wire [63:0] mem_addr;
    wire [63:0] mem_wdata;
    wire [7:0] mem_wstrb;
    reg [63:0] mem_rdata;
    reg mem_error;
    wire [63:0] dbg_pc;
    wire [31:0] dbg_instr;
    wire dbg_halted;
    wire icx_req_valid;
    wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id;
    wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id;
    wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id;
    wire icx_resp_ready;
    reg icx_resp_valid_q;
    reg [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id_q;
    reg [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id_q;
    reg [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id_q;

    reg [63:0] memory [0:127];
    reg pending_q;
    reg [63:0] pending_addr_q;
    integer byte_index;
    integer retired_total;
    integer issue_count;
    integer initialize_index;
    integer cycles;
    reg saw_two_decode;
    reg saw_two_issue;
    reg saw_two_retire;
    reg saw_read_bank_retry;
    reg saw_write_bank_retry;
    reg saw_dependency_wait;
    reg saw_redirect_drain;

    openrv64_top #(
        .RESET_VECTOR(64'd0),
        .BACKEND_CONFIG(`OPENRV64_BACKEND_3P),
        .ENABLE_RV64M(1),
        .ENABLE_RV64ZBB(1),
        .ENABLE_TRACE(1),
        .BANKED_GPR_3P(1),
        .FPGA_GPR_LUTRAM_3P(0),
        .COMPLETION_FORWARD_MASK_3P(3'b000),
        .BRANCH_COMPLETION_FORWARD_MASK_3P(3'b000),
        .ENABLE_FULL_FORWARDING_3P(0),
        .RELAX_WAW_3P(0),
        .RELAX_HAZARDS_3P(0),
        .ENABLE_ISSUE_WINDOW(0),
        .ENABLE_SPECULATION_WINDOW(0),
        .ENABLE_L1I(0),
        .ENABLE_L1D(0)
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
        .mem_error(mem_error),
        .m_axi_arready(1'b0),
        .m_axi_rid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
        .m_axi_rdata({`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
        .m_axi_rresp(2'b00),
        .m_axi_rlast(1'b0),
        .m_axi_rvalid(1'b0),
        .m_axi_awready(1'b0),
        .m_axi_wready(1'b0),
        .m_axi_bid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
        .m_axi_bresp(2'b00),
        .m_axi_bvalid(1'b0),
        .icx_req_valid(icx_req_valid),
        .icx_req_ready(1'b1),
        .icx_req_hart_id(icx_req_hart_id),
        .icx_req_txn_id(icx_req_txn_id),
        .icx_req_source_id(icx_req_source_id),
        .icx_wdata_ready(1'b1),
        .icx_resp_valid(icx_resp_valid_q),
        .icx_resp_ready(icx_resp_ready),
        .icx_resp_hart_id(icx_resp_hart_id_q),
        .icx_resp_txn_id(icx_resp_txn_id_q),
        .icx_resp_source_id(icx_resp_source_id_q),
        .icx_resp_beat_index(
            {`OPENRV64_ICX_BEAT_INDEX_WIDTH{1'b0}}),
        .icx_resp_last(1'b1),
        .icx_resp_rdata({`OPENRV64_ICX_LINE_DATA_WIDTH{1'b0}}),
        .icx_resp_error(1'b0),
        .icx_resp_sc_success(1'b0),
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

    always #5 clk = ~clk;

    always @* begin
        mem_ready = pending_q;
        mem_rdata = pending_q ? memory[pending_addr_q[9:3]] : 64'd0;
        mem_error = 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_q <= 1'b0;
            pending_addr_q <= 64'd0;
        end else if (pending_q) begin
            if (mem_write) begin
                for (byte_index = 0; byte_index < 8;
                     byte_index = byte_index + 1) begin
                    if (mem_wstrb[byte_index]) begin
                        memory[pending_addr_q[9:3]][byte_index*8 +: 8] <=
                            mem_wdata[byte_index*8 +: 8];
                    end
                end
            end
            pending_q <= 1'b0;
        end else if (mem_valid) begin
            pending_q <= 1'b1;
            pending_addr_q <= mem_addr;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            icx_resp_valid_q <= 1'b0;
            icx_resp_hart_id_q <=
                {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}};
            icx_resp_txn_id_q <=
                {`OPENRV64_ICX_TXN_ID_WIDTH{1'b0}};
            icx_resp_source_id_q <=
                {`OPENRV64_ICX_SOURCE_ID_WIDTH{1'b0}};
        end else begin
            if (icx_resp_valid_q && icx_resp_ready)
                icx_resp_valid_q <= 1'b0;
            if (icx_req_valid) begin
                icx_resp_valid_q <= 1'b1;
                icx_resp_hart_id_q <= icx_req_hart_id;
                icx_resp_txn_id_q <= icx_req_txn_id;
                icx_resp_source_id_q <= icx_req_source_id;
            end
        end
    end

    function automatic [31:0] encode_i;
        input [11:0] immediate;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            encode_i = {immediate, rs1, funct3, rd, opcode};
        end
    endfunction

    function automatic [31:0] encode_r;
        input [6:0] funct7;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            encode_r = {funct7, rs2, rs1, funct3, rd, opcode};
        end
    endfunction

    function automatic [31:0] encode_s;
        input [11:0] immediate;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [6:0] opcode;
        begin
            encode_s = {immediate[11:5], rs2, rs1, funct3,
                        immediate[4:0], opcode};
        end
    endfunction

    function automatic [31:0] encode_b;
        input [12:0] immediate;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        begin
            encode_b = {immediate[12], immediate[10:5], rs2, rs1,
                        funct3, immediate[4:1], immediate[11],
                        `RV64_OPCODE_BRANCH};
        end
    endfunction

    task automatic put_instruction;
        input integer instruction_index;
        input [31:0] instruction;
        begin
            if (instruction_index[0])
                memory[instruction_index >> 1][63:32] = instruction;
            else
                memory[instruction_index >> 1][31:0] = instruction;
        end
    endtask

    task automatic fail;
        input [8*120-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $display("pc=%h instr=%h retired=%0d fetch_mem=%b data_mem=%b dq=%0d rq=%0d busy=%h",
                     dbg_pc, dbg_instr, retired_total, mem_valid,
                     dut.g_backend_3p.u_core_3p.backend_mem_valid,
                     dut.g_backend_3p.u_core_3p
                         .backend_dispatch_occupancy,
                     dut.g_backend_3p.u_core_3p.backend_retire_occupancy,
                     dut.g_backend_3p.u_core_3p.backend_write_busy);
            $fatal(1);
        end
    endtask

    always @(negedge clk) begin
        if (rst_n && !dbg_halted) begin
            issue_count =
                dut.g_backend_3p.u_core_3p.backend_issue_valid[0] +
                dut.g_backend_3p.u_core_3p.backend_issue_valid[1] +
                dut.g_backend_3p.u_core_3p.backend_issue_valid[2] +
                dut.g_backend_3p.u_core_3p.backend_issue_valid[3];
            if (issue_count > 2)
                fail("banked core issued more than two instructions");
            if (issue_count == 2)
                saw_two_issue = 1'b1;
            if ((dut.g_backend_3p.u_core_3p.backend_decode_valid[1:0] ==
                 2'b11) &&
                (dut.g_backend_3p.u_core_3p.backend_decode_ready[1:0] ==
                 2'b11))
                saw_two_decode = 1'b1;
            if (dut.g_backend_3p.u_core_3p.backend_retire_count == 2)
                saw_two_retire = 1'b1;
            retired_total = retired_total +
                dut.g_backend_3p.u_core_3p.backend_retire_count;

            if (dut.g_backend_3p.u_core_3p.backend_write_busy[0])
                fail("x0 became busy");

            if (|(dut.g_backend_3p.u_core_3p.u_backend.gpr_read_req[3:0] &
                  ~dut.g_backend_3p.u_core_3p.u_backend.gpr_read_ack[3:0]))
                saw_read_bank_retry = 1'b1;
            if ((dut.g_backend_3p.u_core_3p.u_backend.gpr_write == 2'b11) &&
                ((dut.g_backend_3p.u_core_3p.u_backend.gpr_write_ack[1:0] ==
                  2'b01) ||
                 (dut.g_backend_3p.u_core_3p.u_backend.gpr_write_ack[1:0] ==
                  2'b10)))
                saw_write_bank_retry = 1'b1;
            if ((dut.g_backend_3p.u_core_3p
                     .backend_dispatch_occupancy != 0) &&
                (dut.g_backend_3p.u_core_3p.backend_write_busy != 0) &&
                (issue_count == 0))
                saw_dependency_wait = 1'b1;
            if (dut.g_backend_3p.u_core_3p.u_backend.banked_gpr_drain_q) begin
                saw_redirect_drain = 1'b1;
            end
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        pending_q = 1'b0;
        retired_total = 0;
        saw_two_decode = 1'b0;
        saw_two_issue = 1'b0;
        saw_two_retire = 1'b0;
        saw_read_bank_retry = 1'b0;
        saw_write_bank_retry = 1'b0;
        saw_dependency_wait = 1'b0;
        saw_redirect_drain = 1'b0;
        for (initialize_index = 0; initialize_index < 128;
             initialize_index = initialize_index + 1)
            memory[initialize_index] = 64'h0000_0013_0000_0013;

        put_instruction(0, encode_i(12'd5, 0, 3'b000, 1,
                                    `RV64_OPCODE_OP_IMM));
        put_instruction(1, encode_i(12'hffc, 0, 3'b000, 3,
                                    `RV64_OPCODE_OP_IMM));
        put_instruction(2, encode_i(12'd9, 0, 3'b000, 2,
                                    `RV64_OPCODE_OP_IMM));
        put_instruction(3, encode_r(7'b0000000, 2, 1, 3'b000, 4,
                                    `RV64_OPCODE_OP));
        put_instruction(4, encode_r(7'b0100000, 1, 2, 3'b000, 5,
                                    `RV64_OPCODE_OP));
        put_instruction(5, encode_r(7'b0000000, 5, 4, 3'b100, 6,
                                    `RV64_OPCODE_OP));
        put_instruction(6, encode_r(7'b0000000, 5, 4, 3'b110, 7,
                                    `RV64_OPCODE_OP));
        put_instruction(7, encode_r(7'b0000000, 6, 4, 3'b111, 8,
                                    `RV64_OPCODE_OP));
        put_instruction(8, encode_r(7'b0000000, 5, 1, 3'b001, 9,
                                    `RV64_OPCODE_OP));
        put_instruction(9, encode_r(7'b0000000, 1, 9, 3'b101, 10,
                                    `RV64_OPCODE_OP));
        put_instruction(10, encode_r(7'b0100000, 1, 3, 3'b101, 11,
                                     `RV64_OPCODE_OP));
        put_instruction(11, encode_r(7'b0000000, 1, 3, 3'b010, 12,
                                     `RV64_OPCODE_OP));
        put_instruction(12, encode_r(7'b0000000, 1, 3, 3'b011, 13,
                                     `RV64_OPCODE_OP));
        put_instruction(13, encode_i(12'd123, 13, 3'b000, 14,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(14, encode_r(7'b0000000, 1, 14, 3'b000, 15,
                                     `RV64_OPCODE_OP));
        put_instruction(15, encode_i(12'd77, 0, 3'b000, 0,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(16, encode_i(12'd16, 0, 3'b000, 16,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(17, encode_i(12'd17, 0, 3'b000, 17,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(18, encode_r(7'b0000000, 3, 1, 3'b000, 18,
                                     `RV64_OPCODE_OP));
        put_instruction(19, encode_r(7'b0000000, 4, 2, 3'b000, 19,
                                     `RV64_OPCODE_OP));
        put_instruction(20, encode_r(7'b0000000, 19, 18, 3'b000, 20,
                                     `RV64_OPCODE_OP));
        put_instruction(21, {20'h12345, 5'd21, `RV64_OPCODE_LUI});
        put_instruction(22, {20'h00002, 5'd22, `RV64_OPCODE_AUIPC});
        put_instruction(23, encode_r(7'b0000000, 22, 21, 3'b000, 23,
                                     `RV64_OPCODE_OP));
        put_instruction(24, encode_i(12'd1, 3, 3'b000, 24,
                                     `RV64_OPCODE_OP_IMM_32));
        put_instruction(25, encode_r(7'b0000000, 3, 21, 3'b000, 25,
                                     `RV64_OPCODE_OP_32));
        put_instruction(26, encode_r(7'b0100000, 1, 3, 3'b101, 26,
                                     `RV64_OPCODE_OP_32));
        put_instruction(27, encode_i(12'h200, 0, 3'b000, 27,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(28, encode_i(12'h055, 0, 3'b000, 28,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(29, encode_s(12'd0, 28, 27, 3'b011,
                                     `RV64_OPCODE_STORE));
        put_instruction(30, encode_i(12'd0, 27, 3'b011, 29,
                                     `RV64_OPCODE_LOAD));
        put_instruction(31, encode_i(12'd1, 29, 3'b000, 30,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(32, encode_s(12'd8, 30, 27, 3'b011,
                                     `RV64_OPCODE_STORE));
        put_instruction(33, encode_i(12'd8, 27, 3'b011, 31,
                                     `RV64_OPCODE_LOAD));
        put_instruction(34, encode_i(12'd5, 0, 3'b000, 31,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(35, encode_i(12'd0, 0, 3'b000, 30,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(36, encode_i(12'd1, 30, 3'b000, 30,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(37, encode_i(12'hfff, 31, 3'b000, 31,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(38, encode_b(13'h1ff8, 0, 31, 3'b001));
        put_instruction(39, encode_i(12'd7, 0, 3'b000, 28,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(40, encode_i(12'd9, 0, 3'b000, 29,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(41, encode_r(7'b0000001, 29, 28, 3'b000, 30,
                                     `RV64_OPCODE_OP));
        put_instruction(42, encode_r(7'b0000001, 29, 28, 3'b001, 31,
                                     `RV64_OPCODE_OP));
        put_instruction(43, encode_i(12'd2000, 0, 3'b000, 28,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(44, {20'h000cd, 5'd29, `RV64_OPCODE_LUI});
        put_instruction(45, encode_i(12'hccd, 29, 3'b000, 29,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(46, encode_i(12'h020, 28, 3'b001, 28,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(47, encode_i(12'h00c, 29, 3'b001, 29,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(48, encode_i(12'hccd, 29, 3'b000, 29,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(49, encode_i(12'h020, 28, 3'b101, 28,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(50, encode_r(7'b0000001, 29, 28, 3'b000, 28,
                                     `RV64_OPCODE_OP));
        put_instruction(51, encode_i(12'h024, 28, 3'b101, 28,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(52, encode_i(12'hffe, 28, 3'b000, 28,
                                     `RV64_OPCODE_OP_IMM_32));
        put_instruction(53, encode_i(12'd2000, 0, 3'b000, 28,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(54, encode_i(12'd3, 0, 3'b000, 29,
                                     `RV64_OPCODE_OP_IMM));
        put_instruction(55, encode_r(7'b0000001, 29, 28, 3'b101, 30,
                                     `RV64_OPCODE_OP_32));
        put_instruction(56, encode_s(12'd16, 30, 27, 3'b010,
                                     `RV64_OPCODE_STORE));
        put_instruction(57, encode_i(12'd16, 27, 3'b010, 29,
                                     `RV64_OPCODE_LOAD));
        put_instruction(58, 32'h0010_0073);

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        for (cycles = 0; cycles < 1200 && !dbg_halted;
             cycles = cycles + 1) begin
            @(posedge clk);
            #1;
        end
        if (!dbg_halted)
            fail("banked 3P core did not reach EBREAK");
        if ((dbg_pc != 64'he8) || (dbg_instr != 32'h0010_0073))
            fail("banked 3P core halted at the wrong instruction");
        repeat (3) @(posedge clk);

        if (retired_total != INSTRUCTION_COUNT)
            fail("not all arithmetic instructions retired before EBREAK");
        if (!saw_two_decode || !saw_two_issue || !saw_two_retire)
            fail("end-to-end program did not exercise multi-lane flow");
        if (!saw_read_bank_retry || !saw_write_bank_retry)
            fail("end-to-end program did not exercise both bank retries");
        if (!saw_dependency_wait)
            fail("end-to-end program did not wait for a dependency");
        if (!saw_redirect_drain)
            fail("branch redirect did not enter the GPR drain state");
        if (dut.g_backend_3p.u_core_3p.backend_write_busy != 0)
            fail("banked core halted with an outstanding register writer");

        if (dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[1] !== 64'd5 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[2] !== 64'd9 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[3] !== -64'd4 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[4] !== 64'd14 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[5] !== 64'd4 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[6] !== 64'd10 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[7] !== 64'd14 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[8] !== 64'd10 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[9] !== 64'd80 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[10] !== 64'd2 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[11] !==
                {64{1'b1}} ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[12] !== 64'd1 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[13] !== 64'd0 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[14] !== 64'd123 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[15] !== 64'd128 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[16] !== 64'd16 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[17] !== 64'd17 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[18] !== 64'd1 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[19] !== 64'd23 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[20] !== 64'd24 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[21] !==
                64'h0000_0000_1234_5000 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[22] !==
                64'h0000_0000_0000_2058 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[23] !==
                64'h0000_0000_1234_7058 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[24] !==
                64'hffff_ffff_ffff_fffd ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[25] !==
                64'h0000_0000_1234_4ffc ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[26] !==
                {64{1'b1}} ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[27] !==
                64'h0000_0000_0000_0200 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[28] !==
                64'h0000_0000_0000_07d0 ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[29] !==
                64'h0000_0000_0000_029a ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[30] !==
                64'h0000_0000_0000_029a ||
            dut.g_backend_3p.u_core_3p.u_backend.u_gpr.regs[31] !==
                64'h0000_0000_0000_0000 ||
            memory[64] !== 64'h0000_0000_0000_0055 ||
            memory[65] !== 64'h0000_0000_0000_0056 ||
            memory[66] !== 64'h0000_0013_0000_029a)
            fail("end-to-end architectural register state was incorrect");

        $display("PASS: banked 3P top processed arithmetic, memory, and dependent branch loop end to end");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "tb_top_3p_banked: timeout");
    end
endmodule
