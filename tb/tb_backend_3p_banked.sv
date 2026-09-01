`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"

module tb_backend_3p_banked #(
    parameter integer ISSUE_WINDOW = 0,
    parameter integer SPECULATION_WINDOW = ISSUE_WINDOW
);
    localparam integer RETIRE_DEPTH = 16;
    localparam integer IW = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;
    localparam integer RCW = $clog2(RETIRE_DEPTH + 1);
    localparam integer DCW = $clog2(
        ((ISSUE_WINDOW != 0) ? RETIRE_DEPTH : 6) + 1);
    localparam integer INSTRUCTION_COUNT = 27;

    localparam integer I_PRIV = 2;
    localparam integer I_MEM_READ = 16;
    localparam integer I_REG_WRITE = 17;
    localparam integer I_LSU_OP = 22;
    localparam integer I_ALU_OP = 27;
    localparam integer I_ALU_EXT = 32;
    localparam integer I_RD = 35;
    localparam integer I_IMM = 40;
    localparam integer I_RS2 = 232;
    localparam integer I_RS1 = 237;
    localparam integer I_INSTR = 242;
    localparam integer I_PC = 274;
    localparam integer I_TRACE = 338;

    reg clk;
    reg rst_n;
    reg flush;
    reg squash;
    reg [2:0] decode_valid;
    wire [2:0] decode_ready;
    reg [3*IW-1:0] decode_payload;
    reg [2:0] decode_uses_rs1;
    reg [2:0] decode_uses_rs2;

    wire mem_valid;
    reg mem_ready;
    wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_tag;
    wire mem_physical;
    reg mem_resp_valid;
    wire mem_resp_ready;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_resp_tag;
    wire [63:0] mem_addr;
    reg [63:0] mem_rdata;
    wire mem_xlate_valid;
    wire [`OPENRV64_LSU_XLATE_TAG_WIDTH-1:0] mem_xlate_tag;
    wire [63:0] mem_xlate_vaddr;
    reg mem_xlate_resp_valid_q;
    wire mem_xlate_resp_ready;
    reg [`OPENRV64_LSU_XLATE_TAG_WIDTH-1:0] mem_xlate_resp_tag_q;
    reg [63:0] mem_xlate_resp_paddr_q;
    wire mem1_valid;
    wire redirect_valid;
    wire [2:0] retire_arch;
    wire [1:0] retire_count;
    wire exception;
    wire halt;
    wire irq;
    wire mret;
    wire sret;
    wire fence_i;
    wire sfence_vma;
    wire [63:0] retire_trace_id;
    wire [31:0] retire_instr;
    wire [4:0] retire_rd;
    wire [63:0] retire_wdata;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] issue_valid;
    wire [2:0] complete_valid;
    wire [31:0] write_busy;
    wire barrier_active;
    wire [RCW-1:0] retire_occupancy;
    wire [DCW-1:0] dispatch_occupancy;

    openrv64_backend_3p #(
        .RETIRE_DEPTH(RETIRE_DEPTH),
        .DISPATCH_DEPTH(6),
        .PHYS_REG_COUNT(31),
        .PHYS_REG_ADDR_WIDTH(5),
        .ENABLE_TRACE(1),
        .COMPLETION_FORWARD_MASK(3'b111),
        .BRANCH_COMPLETION_FORWARD_MASK(3'b000),
        .ENABLE_FULL_FORWARDING(0),
        .RELAX_WAW(1),
        .RELAX_HAZARDS(0),
        .ENABLE_ISSUE_WINDOW(ISSUE_WINDOW),
        .ENABLE_SPECULATION_WINDOW(SPECULATION_WINDOW),
        .ISSUE_WINDOW_DEPTH(RETIRE_DEPTH),
        .BANKED_GPR(1),
        .FPGA_GPR_LUTRAM(0)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .squash_frontend_i(squash),
        .coherent_reservation_clear_i(1'b0),
        .translation_bypass_i(1'b1),
        .decode_valid_i(decode_valid),
        .decode_ready_o(decode_ready),
        .decode_payload_i(decode_payload),
        .decode_uses_rs1_i(decode_uses_rs1),
        .decode_uses_rs2_i(decode_uses_rs2),
        .decode_allocation_id_o(),
        .decode_allocation_slot_o(),
        .csr_addr_o(),
        .csr_rdata_i(64'd0),
        .csr_valid_i(1'b1),
        .csr_writable_i(1'b1),
        .csr_write_ready_i(1'b1),
        .csr_write_o(),
        .csr_write_addr_o(),
        .csr_op_o(),
        .csr_wdata_o(),
        .mem_valid_o(mem_valid),
        .mem_ready_i(mem_ready),
        .mem_tag_o(mem_tag),
        .mem_xlate_only_o(),
        .mem_physical_o(mem_physical),
        .mem_pmp_checked_o(),
        .mem_resp_valid_i(mem_resp_valid),
        .mem_resp_ready_o(mem_resp_ready),
        .mem_resp_tag_i(mem_resp_tag),
        .mem_resp_paddr_i(64'd0),
        .mem_error_i(1'b0),
        .mem_page_fault_i(1'b0),
        .mem_store_done_valid_i(1'b0),
        .mem_store_done_ready_o(),
        .mem_store_done_tag_i({`OPENRV64_LSU_TAG_WIDTH{1'b0}}),
        .store_barrier_request_o(),
        .store_barrier_busy_i(1'b0),
        .mem_access_allowed_i(1'b1),
        .mem_lock_o(),
        .mem_write_o(),
        .mem_addr_o(mem_addr),
        .mem_wdata_o(),
        .mem_wstrb_o(),
        .mem_access_o(),
        .mem_effective_addr_o(),
        .mem_size_o(),
        .mem_rdata_i(mem_rdata),
        .mem_xlate_valid_o(mem_xlate_valid),
        .mem_xlate_ready_i(1'b1),
        .mem_xlate_tag_o(mem_xlate_tag),
        .mem_xlate_write_o(),
        .mem_xlate_size_o(),
        .mem_xlate_vaddr_o(mem_xlate_vaddr),
        .mem_xlate_resp_valid_i(mem_xlate_resp_valid_q),
        .mem_xlate_resp_ready_o(mem_xlate_resp_ready),
        .mem_xlate_resp_tag_i(mem_xlate_resp_tag_q),
        .mem_xlate_resp_paddr_i(mem_xlate_resp_paddr_q),
        .mem_xlate_resp_access_fault_i(1'b0),
        .mem_xlate_resp_page_fault_i(1'b0),
        .mem1_valid_o(mem1_valid),
        .mem1_ready_i(1'b0),
        .mem1_tag_o(),
        .mem1_lock_o(),
        .mem1_write_o(),
        .mem1_addr_o(),
        .mem1_wdata_o(),
        .mem1_wstrb_o(),
        .mem1_access_o(),
        .mem1_effective_addr_o(),
        .mem1_size_o(),
        .irq_pending_i(1'b0),
        .irq_cause_i({`RV64_EXCEPT_CAUSE_WIDTH{1'b0}}),
        .redirect_valid_o(redirect_valid),
        .redirect_id_o(),
        .redirect_target_o(),
        .branch_resolved_o(),
        .branch_conditional_o(),
        .branch_taken_o(),
        .branch_pc_o(),
        .branch_instr_o(),
        .branch_id_o(),
        .branch_slot_o(),
        .branch_train_valid_o(),
        .branch_train_conditional_o(),
        .branch_train_taken_o(),
        .branch_train_pc_o(),
        .branch_retire_age_valid_o(),
        .branch_retire_age_addr_o(),
        .retire_arch_o(retire_arch),
        .retire_count_o(retire_count),
        .exception_o(exception),
        .halt_o(halt),
        .irq_o(irq),
        .mret_o(mret),
        .sret_o(sret),
        .fence_i_o(fence_i),
        .sfence_vma_o(sfence_vma),
        .cause_o(),
        .retire_pc_o(),
        .retire_next_pc_o(),
        .retire_tval_o(),
        .retire_trace_id_o(retire_trace_id),
        .retire_instr_o(retire_instr),
        .retire_rd_o(retire_rd),
        .retire_wdata_o(retire_wdata),
        .issue_valid_o(issue_valid),
        .complete_valid_o(complete_valid),
        .write_busy_o(write_busy),
        .barrier_active_o(barrier_active),
        .retire_occupancy_o(retire_occupancy),
        .dispatch_occupancy_o(dispatch_occupancy)
    );

    always #5 clk = ~clk;

    // Tagged one-cycle Bare-translation model.  The LSQ still uses the
    // translation response to carry PMP/access status when address bypass is
    // enabled.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_xlate_resp_valid_q <= 1'b0;
            mem_xlate_resp_tag_q <=
                {`OPENRV64_LSU_XLATE_TAG_WIDTH{1'b0}};
            mem_xlate_resp_paddr_q <= 64'd0;
        end else begin
            if (mem_xlate_resp_valid_q && mem_xlate_resp_ready)
                mem_xlate_resp_valid_q <= 1'b0;
            if (mem_xlate_valid) begin
                if (mem_xlate_resp_valid_q && !mem_xlate_resp_ready)
                    $fatal(1, "banked backend translation model overflow");
                mem_xlate_resp_valid_q <= 1'b1;
                mem_xlate_resp_tag_q <= mem_xlate_tag;
                mem_xlate_resp_paddr_q <= mem_xlate_vaddr;
            end
        end
    end

    function automatic [IW-1:0] base_packet;
        input [63:0] trace;
        input [31:0] instr;
        reg [IW-1:0] packet;
        begin
            packet = {IW{1'b0}};
            packet[I_TRACE +: 64] = trace;
            packet[I_PC +: 64] = 64'h1000 + (trace << 2);
            packet[I_INSTR +: 32] = instr;
            packet[I_PRIV +: 2] = `RV64_PRIV_M;
            base_packet = packet;
        end
    endfunction

    function automatic [IW-1:0] load_packet;
        input [63:0] trace;
        input [4:0] rs1;
        input [4:0] rd;
        input [63:0] immediate;
        reg [IW-1:0] packet;
        begin
            packet = base_packet(
                trace,
                {immediate[11:0], rs1, 3'b011, rd, `RV64_OPCODE_LOAD});
            packet[I_RS1 +: 5] = rs1;
            packet[I_RD +: 5] = rd;
            packet[I_IMM +: 64] = immediate;
            packet[I_LSU_OP +: 5] = `RV64_LSU_OP_LD;
            packet[I_MEM_READ] = 1'b1;
            packet[I_REG_WRITE] = 1'b1;
            load_packet = packet;
        end
    endfunction

    function automatic [IW-1:0] addi_packet;
        input [63:0] trace;
        input [4:0] rs1;
        input [4:0] rd;
        input [63:0] immediate;
        input word_op;
        reg [IW-1:0] packet;
        reg [6:0] opcode;
        begin
            opcode = word_op ? `RV64_OPCODE_OP_IMM_32 :
                               `RV64_OPCODE_OP_IMM;
            packet = base_packet(
                trace, {immediate[11:0], rs1, 3'b000, rd, opcode});
            packet[I_RS1 +: 5] = rs1;
            packet[I_RD +: 5] = rd;
            packet[I_IMM +: 64] = immediate;
            packet[I_ALU_EXT +: 3] = `RV64_ALU_EXT_BASE;
            packet[I_ALU_OP +: 5] = `RV64_ALU_OP_ADD;
            packet[I_REG_WRITE] = 1'b1;
            packet[9] = word_op;
            addi_packet = packet;
        end
    endfunction

    function automatic [IW-1:0] reg_packet;
        input [63:0] trace;
        input [4:0] rs1;
        input [4:0] rs2;
        input [4:0] rd;
        input [`RV64_ALU_OP_WIDTH-1:0] operation;
        input word_op;
        reg [IW-1:0] packet;
        reg [2:0] funct3;
        reg [6:0] funct7;
        reg [6:0] opcode;
        begin
            funct3 = 3'b000;
            funct7 = 7'b0000000;
            case (operation)
                `RV64_ALU_OP_SUB: begin
                    funct3 = 3'b000;
                    funct7 = 7'b0100000;
                end
                `RV64_ALU_OP_SLL:  funct3 = 3'b001;
                `RV64_ALU_OP_SLT:  funct3 = 3'b010;
                `RV64_ALU_OP_SLTU: funct3 = 3'b011;
                `RV64_ALU_OP_XOR:  funct3 = 3'b100;
                `RV64_ALU_OP_SRL:  funct3 = 3'b101;
                `RV64_ALU_OP_SRA: begin
                    funct3 = 3'b101;
                    funct7 = 7'b0100000;
                end
                `RV64_ALU_OP_OR:   funct3 = 3'b110;
                `RV64_ALU_OP_AND:  funct3 = 3'b111;
                default:           funct3 = 3'b000;
            endcase
            opcode = word_op ? `RV64_OPCODE_OP_32 : `RV64_OPCODE_OP;
            packet = base_packet(
                trace, {funct7, rs2, rs1, funct3, rd, opcode});
            packet[I_RS1 +: 5] = rs1;
            packet[I_RS2 +: 5] = rs2;
            packet[I_RD +: 5] = rd;
            packet[I_ALU_EXT +: 3] = `RV64_ALU_EXT_BASE;
            packet[I_ALU_OP +: 5] = operation;
            packet[I_REG_WRITE] = 1'b1;
            packet[9] = word_op;
            reg_packet = packet;
        end
    endfunction

    function automatic [IW-1:0] upper_packet;
        input [63:0] trace;
        input [4:0] rd;
        input [63:0] immediate;
        input auipc;
        reg [IW-1:0] packet;
        reg [6:0] opcode;
        begin
            opcode = auipc ? `RV64_OPCODE_AUIPC : `RV64_OPCODE_LUI;
            packet = base_packet(
                trace, {immediate[31:12], rd, opcode});
            packet[I_RD +: 5] = rd;
            packet[I_IMM +: 64] = immediate;
            packet[I_ALU_EXT +: 3] = `RV64_ALU_EXT_BASE;
            packet[I_ALU_OP +: 5] = auipc ?
                `RV64_ALU_OP_AUIPC : `RV64_ALU_OP_LUI;
            packet[I_REG_WRITE] = 1'b1;
            upper_packet = packet;
        end
    endfunction

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic fail;
        input [8*120-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    reg [IW-1:0] instruction_stream [0:INSTRUCTION_COUNT-1];
    reg program_uses_rs1 [0:INSTRUCTION_COUNT-1];
    reg program_uses_rs2 [0:INSTRUCTION_COUNT-1];
    reg [4:0] expected_rd [0:INSTRUCTION_COUNT-1];
    reg [63:0] expected_result [0:INSTRUCTION_COUNT-1];

    integer retired_total;
    integer issue_count;
    integer expected_last_trace;
    reg saw_three_wide_input;
    reg saw_two_wide_issue;
    reg saw_two_wide_retire;
    reg saw_read_bank_retry;
    reg saw_write_bank_retry;
    reg saw_dependency_wait;
    reg saw_exu_forward_while_busy;
    reg saw_mem_forward_while_busy;
    reg saw_write_ack_read_overlap;
    reg saw_regload_address_issue_overlap;
    reg saw_back_to_back_issue;
    reg saw_base_alu_reroute;
    reg prior_cycle_issued;
    reg memory_probe_active;
    integer memory_probe_retired;

    always @(negedge clk) begin
        if (rst_n) begin
            issue_count = issue_valid[0] + issue_valid[1] +
                          issue_valid[2] + issue_valid[3];
            if (issue_count > ((ISSUE_WINDOW != 0) ? 3 : 2))
                fail("banked backend exceeded register-load issue width");
            if (issue_count == 2)
                saw_two_wide_issue = 1'b1;
            if ((issue_count != 0) && prior_cycle_issued)
                saw_back_to_back_issue = 1'b1;
            prior_cycle_issued = (issue_count != 0);
            if ((issue_count != 0) && (|dut.gpr_read_ack[5:0]))
                saw_regload_address_issue_overlap = 1'b1;
            if (dut.banked_regload_lane0_reroute ||
                dut.banked_regload_lane1_reroute)
                saw_base_alu_reroute = 1'b1;
            if (decode_valid == 3'b111 && decode_ready == 3'b111)
                saw_three_wide_input = 1'b1;
            if (retire_arch[2])
                fail("banked backend retired a third lane");
            if (retire_count == 2)
                saw_two_wide_retire = 1'b1;

            if ((retire_count != 0) && !memory_probe_active) begin
                expected_last_trace = retired_total + retire_count;
                if (retire_trace_id !== expected_last_trace)
                    fail("instructions retired out of order");
                if (retire_instr !== instruction_stream[
                                         expected_last_trace-1]
                                         [I_INSTR +: 32])
                    fail("retired instruction did not match its trace ID");
                if (retire_rd !== expected_rd[expected_last_trace-1])
                    fail("retired destination register was incorrect");
                if (retire_wdata !== expected_result[expected_last_trace-1])
                    fail("retired arithmetic result was incorrect");
                retired_total = expected_last_trace;
            end else if ((retire_count != 0) && memory_probe_active) begin
                memory_probe_retired = memory_probe_retired + retire_count;
            end

            if (!memory_probe_active &&
                (mem_valid || mem_xlate_valid || mem1_valid))
                fail("non-memory instruction stream accessed memory");
            if (redirect_valid || exception || halt || irq || mret || sret ||
                fence_i || sfence_vma)
                fail("non-control instruction stream raised a control event");
            if (write_busy[0])
                fail("x0 became busy");
            if ((dut.gpr_write[0] &&
                 (dut.gpr_write_addr[0 +: 5] == `RV64_REG_X0)) ||
                (dut.gpr_write[1] &&
                 (dut.gpr_write_addr[5 +: 5] == `RV64_REG_X0)))
                fail("retirement sent an x0 write to the register file");

            if (|(dut.gpr_read_req[5:0] & ~dut.gpr_read_ack[5:0]))
                saw_read_bank_retry = 1'b1;
            if (dut.g_banked_retire.u_retire
                    .direct_write_pair_conflict &&
                (dut.gpr_write[1:0] == 2'b01) &&
                dut.gpr_write_ack[0])
                saw_write_bank_retry = 1'b1;
            if ((dispatch_occupancy != 0) && (write_busy != 0) &&
                (issue_count == 0))
                saw_dependency_wait = 1'b1;
            if ((dut.banked_read_forward_valid[0] &&
                 write_busy[dut.gpr_read_addr[0*5 +: 5]]) ||
                (dut.banked_read_forward_valid[1] &&
                 write_busy[dut.gpr_read_addr[1*5 +: 5]]) ||
                (dut.banked_read_forward_valid[2] &&
                 write_busy[dut.gpr_read_addr[2*5 +: 5]]) ||
                (dut.banked_read_forward_valid[3] &&
                 write_busy[dut.gpr_read_addr[3*5 +: 5]])) begin
                // Forwarded operands are accepted while architectural
                // ownership remains busy.  The gather's write-block vector
                // excludes the qualified completion by construction.
                saw_exu_forward_while_busy = 1'b1;
            end
            if (dut.banked_mem_forward_valid &&
                (|dut.banked_read_mem_forward_valid)) begin
                // Direct retirement may acknowledge the producer's write in
                // this same cycle.  That clears public write_busy
                // combinationally, while the exact owner-qualified MEM0 value
                // remains a valid operand source until the retirement edge.
                if (!write_busy[dut.banked_mem_forward_rd_q] &&
                    !dut.banked_write_ack_hot[
                        dut.banked_mem_forward_rd_q])
                    fail("MEM0 forwarding bypassed an unowned producer");
                saw_mem_forward_while_busy = 1'b1;
            end
            if (|(dut.banked_read_write_ack_release &
                  dut.gpr_read_ack[3:0]))
                saw_write_ack_read_overlap = 1'b1;
        end
    end

    integer next_instruction;
    integer lane;
    integer lane_count;
    integer cycles;
    reg [2:0] send_mask;
    reg [3:0] redirect_delayed_reads;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] probe_load_tag;
    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        squash = 1'b0;
        decode_valid = 3'b000;
        decode_payload = {3*IW{1'b0}};
        decode_uses_rs1 = 3'b000;
        decode_uses_rs2 = 3'b000;
        mem_ready = 1'b0;
        mem_resp_valid = 1'b0;
        mem_resp_tag = {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
        mem_rdata = 64'd0;
        retired_total = 0;
        saw_three_wide_input = 1'b0;
        saw_two_wide_issue = 1'b0;
        saw_two_wide_retire = 1'b0;
        saw_read_bank_retry = 1'b0;
        saw_write_bank_retry = 1'b0;
        saw_dependency_wait = 1'b0;
        saw_exu_forward_while_busy = 1'b0;
        saw_mem_forward_while_busy = 1'b0;
        saw_write_ack_read_overlap = 1'b0;
        saw_regload_address_issue_overlap = 1'b0;
        saw_back_to_back_issue = 1'b0;
        saw_base_alu_reroute = 1'b0;
        prior_cycle_issued = 1'b0;
        memory_probe_active = 1'b0;
        memory_probe_retired = 0;

        instruction_stream[0] = addi_packet(1, 0, 1, 64'd5, 1'b0);
        // p1 and p29 share four-bank bank 1.  These two independent leading
        // writes deliberately exercise oldest-first sliding retirement.
        instruction_stream[1] = addi_packet(2, 0, 29, -64'd4, 1'b0);
        instruction_stream[2] = addi_packet(3, 0, 2, 64'd9, 1'b0);
        instruction_stream[3] = reg_packet(
            4, 1, 2, 4, `RV64_ALU_OP_ADD, 1'b0);
        instruction_stream[4] = reg_packet(
            5, 2, 1, 5, `RV64_ALU_OP_SUB, 1'b0);
        instruction_stream[5] = reg_packet(
            6, 4, 5, 6, `RV64_ALU_OP_XOR, 1'b0);
        instruction_stream[6] = reg_packet(
            7, 4, 5, 7, `RV64_ALU_OP_OR, 1'b0);
        instruction_stream[7] = reg_packet(
            8, 4, 6, 8, `RV64_ALU_OP_AND, 1'b0);
        instruction_stream[8] = reg_packet(
            9, 1, 5, 9, `RV64_ALU_OP_SLL, 1'b0);
        instruction_stream[9] = reg_packet(
            10, 9, 1, 10, `RV64_ALU_OP_SRL, 1'b0);
        instruction_stream[10] = reg_packet(
            11, 29, 1, 11, `RV64_ALU_OP_SRA, 1'b0);
        instruction_stream[11] = reg_packet(
            12, 29, 1, 12, `RV64_ALU_OP_SLT, 1'b0);
        instruction_stream[12] = reg_packet(
            13, 29, 1, 13, `RV64_ALU_OP_SLTU, 1'b0);
        instruction_stream[13] = addi_packet(
            14, 13, 14, 64'd123, 1'b0);
        instruction_stream[14] = reg_packet(
            15, 14, 1, 15, `RV64_ALU_OP_ADD, 1'b0);
        instruction_stream[15] = addi_packet(16, 0, 0, 64'd77, 1'b0);
        instruction_stream[16] = addi_packet(17, 0, 16, 64'd16, 1'b0);
        instruction_stream[17] = addi_packet(18, 0, 17, 64'd17, 1'b0);
        instruction_stream[18] = reg_packet(
            19, 1, 29, 18, `RV64_ALU_OP_ADD, 1'b0);
        instruction_stream[19] = reg_packet(
            20, 2, 4, 19, `RV64_ALU_OP_ADD, 1'b0);
        instruction_stream[20] = reg_packet(
            21, 18, 19, 20, `RV64_ALU_OP_ADD, 1'b0);
        instruction_stream[21] = upper_packet(
            22, 21, 64'h1234_5000, 1'b0);
        instruction_stream[22] = upper_packet(
            23, 22, 64'h0000_2000, 1'b1);
        instruction_stream[23] = reg_packet(
            24, 21, 22, 23, `RV64_ALU_OP_ADD, 1'b0);
        instruction_stream[24] = addi_packet(25, 29, 24, 64'd1, 1'b1);
        instruction_stream[25] = reg_packet(
            26, 21, 29, 25, `RV64_ALU_OP_ADD, 1'b1);
        instruction_stream[26] = reg_packet(
            27, 29, 1, 26, `RV64_ALU_OP_SRA, 1'b1);

        for (lane = 0; lane < INSTRUCTION_COUNT; lane = lane + 1) begin
            program_uses_rs1[lane] = 1'b1;
            program_uses_rs2[lane] = 1'b0;
            expected_rd[lane] = instruction_stream[lane][I_RD +: 5];
            expected_result[lane] = 64'd0;
        end
        for (lane = 3; lane <= 12; lane = lane + 1)
            program_uses_rs2[lane] = 1'b1;
        program_uses_rs2[14] = 1'b1;
        program_uses_rs2[18] = 1'b1;
        program_uses_rs2[19] = 1'b1;
        program_uses_rs2[20] = 1'b1;
        program_uses_rs2[23] = 1'b1;
        program_uses_rs2[25] = 1'b1;
        program_uses_rs2[26] = 1'b1;
        program_uses_rs1[21] = 1'b0;
        program_uses_rs1[22] = 1'b0;

        expected_result[0] = 64'd5;
        expected_result[1] = -64'd4;
        expected_result[2] = 64'd9;
        expected_result[3] = 64'd14;
        expected_result[4] = 64'd4;
        expected_result[5] = 64'd10;
        expected_result[6] = 64'd14;
        expected_result[7] = 64'd10;
        expected_result[8] = 64'd80;
        expected_result[9] = 64'd2;
        expected_result[10] = {64{1'b1}};
        expected_result[11] = 64'd1;
        expected_result[12] = 64'd0;
        expected_result[13] = 64'd123;
        expected_result[14] = 64'd128;
        expected_result[15] = 64'd77;
        expected_result[16] = 64'd16;
        expected_result[17] = 64'd17;
        expected_result[18] = 64'd1;
        expected_result[19] = 64'd23;
        expected_result[20] = 64'd24;
        expected_result[21] = 64'h0000_0000_1234_5000;
        expected_result[22] = 64'h0000_0000_0000_305c;
        expected_result[23] = 64'h0000_0000_1234_805c;
        expected_result[24] = 64'hffff_ffff_ffff_fffd;
        expected_result[25] = 64'h0000_0000_1234_4ffc;
        expected_result[26] = {64{1'b1}};

        repeat (4) tick();
        rst_n = 1'b1;
        tick();

        // An accepted address can return while a redirect is being resolved.
        // Keep the older lane and its response, but discard the younger lane
        // and its response owner.  This directly seeds only the independent
        // register-load state so the test does not depend on selector timing.
        if (ISSUE_WINDOW != 0) begin
            dut.banked_independent_valid_q = 4'b0011;
            dut.banked_independent_id_q = {40{1'b0}};
            dut.banked_independent_id_q[0 +: 10] = 10'd79;
            dut.banked_independent_id_q[10 +: 10] = 10'd84;
            dut.banked_independent_operand_done_q = 8'b00000000;
            dut.banked_independent_response_owner_valid_q = 6'b000101;
            dut.banked_independent_response_owner_pipe_q = 12'b0;
            dut.banked_independent_response_owner_pipe_q[0 +: 2] = 2'd0;
            dut.banked_independent_response_owner_pipe_q[4 +: 2] = 2'd1;
            dut.banked_independent_response_owner_id_q = {60{1'b0}};
            dut.banked_independent_response_owner_id_q[0 +: 10] = 10'd79;
            dut.banked_independent_response_owner_id_q[20 +: 10] = 10'd84;
            // The selective-squash contract requires the redirecting ID and
            // slot to name a live retirement entry.
            dut.u_retire_queue.valid_q[0] = 1'b1;
            dut.u_retire_queue.complete_q[0] = 1'b0;
            dut.u_retire_queue.id_q[0] = 10'd81;
            force dut.exec_redirect_id = 10'd81;
            force dut.exec_redirect_slot = 4'd0;
            force dut.pipe_ready = 4'b0000;
            force dut.gpr_read_valid = 6'b000101;
            force dut.gpr_read_data = {
                64'd0, 64'd0, 64'd0, 64'h8484, 64'd0, 64'h7979
            };
            squash = 1'b1;
            tick();
            release dut.exec_redirect_id;
            release dut.exec_redirect_slot;
            release dut.pipe_ready;
            release dut.gpr_read_valid;
            release dut.gpr_read_data;
            squash = 1'b0;
            if ((dut.banked_independent_valid_q != 4'b0001) ||
                !dut.banked_independent_operand_done_q[0] ||
                (dut.banked_independent_operand_data_q[0 +: 64] !=
                 64'h7979) ||
                (dut.banked_independent_response_owner_valid_q != 6'b0))
                fail("redirect did not preserve only the older returned lane");

            flush = 1'b1;
            tick();
            flush = 1'b0;
            for (cycles = 0;
                 (cycles < 10) && dut.banked_gpr_drain_q;
                 cycles = cycles + 1)
                tick();
            if (dut.banked_gpr_drain_q ||
                (dut.banked_independent_valid_q != 4'b0000))
                fail("selective-recovery probe did not flush cleanly");
        end

        // Put four same-bank operands behind the two-slot bank interface.
        // Redirect while the first two accepted reads are returning and the
        // oversubscribed reads are still presented.  The latter must remain
        // stable through ack; all delayed responses are poisoned and must not
        // allocate work.
        if (ISSUE_WINDOW == 0) begin
        decode_payload = {3*IW{1'b0}};
        decode_payload[0 +: IW] = reg_packet(
            0, 4, 8, 31, `RV64_ALU_OP_ADD, 1'b0);
        decode_payload[IW +: IW] = reg_packet(
            0, 12, 16, 30, `RV64_ALU_OP_ADD, 1'b0);
        decode_uses_rs1 = 3'b011;
        decode_uses_rs2 = 3'b011;
        decode_valid = 3'b011;
        while (decode_ready[1:0] != 2'b11)
            tick();
        tick();
        decode_valid = 3'b000;
        decode_payload = {3*IW{1'b0}};
        decode_uses_rs1 = 3'b000;
        decode_uses_rs2 = 3'b000;

        for (cycles = 0;
             (cycles < 20) &&
             !(|dut.u_gpr.g_banked.u_reg_file.read_grant);
             cycles = cycles + 1)
            tick();
        if (!(|dut.u_gpr.g_banked.u_reg_file.read_grant))
            fail("redirect probe never obtained a GPR read grant");

        // Accept the combinational grants first.  Their data returns now,
        // while the same-bank losers remain held address-phase requests.  The
        // redirect asserted below may coincide with the registered output
        // offer.  Selective recovery, not combinational valid suppression,
        // poisons that packet while the RF requester drains its context.
        tick();
        if (!(|dut.gpr_read_valid[3:0]))
            fail("redirect probe grant did not produce a delayed response");
        if (dut.banked_read_ack_q != dut.gpr_read_valid[3:0])
            fail("read response was not associated with the ack pipeline");
        redirect_delayed_reads = dut.banked_read_pending_q;
        if (!(|redirect_delayed_reads))
            fail("redirect probe did not leave a bank-conflicting read pending");

        squash = 1'b1;
        #1;
        if ((dut.gpr_read_req[3:0] & redirect_delayed_reads) !=
            redirect_delayed_reads)
            fail("redirect dropped an unacknowledged read request");
        // These synthetic packets have no resolving control identity, so they
        // cannot drive the issue window's selective-recovery ID contract.
        // After checking the held request above, use a whole-backend flush to
        // abandon their state while exercising the same GPR drain.
        if (ISSUE_WINDOW != 0) begin
            squash = 1'b0;
            flush = 1'b1;
        end
        tick();
        if (!dut.banked_gpr_drain_q ||
            (dut.banked_read_done_q != 4'b0000))
            fail("redirect drain reused a stale GPR response");
        squash = 1'b0;
        flush = 1'b0;

        for (cycles = 0;
             (cycles < 10) && dut.banked_gpr_drain_q;
             cycles = cycles + 1)
            tick();
        if (dut.banked_gpr_drain_q || !dut.gpr_quiescent ||
            (dispatch_occupancy != 0) || (retire_occupancy != 0)) begin
            $display("redirect drain state drain=%b quiescent=%b pending=%b req=%b ack=%b valid=%b dispatch=%0d retire=%0d regload=%b",
                     dut.banked_gpr_drain_q, dut.gpr_quiescent,
                     dut.banked_read_pending_q, dut.gpr_read_req[3:0],
                     dut.gpr_read_ack[3:0], dut.gpr_read_valid[3:0],
                     dispatch_occupancy, retire_occupancy,
                     dut.banked_regload_valid_q);
            fail("redirected GPR access did not drain cleanly");
        end
        end

        next_instruction = 0;
        while (next_instruction < INSTRUCTION_COUNT) begin
            lane_count = INSTRUCTION_COUNT - next_instruction;
            if (lane_count > 3)
                lane_count = 3;
            send_mask = (1 << lane_count) - 1;
            while ((decode_ready & send_mask) != send_mask)
                tick();

            decode_payload = {3*IW{1'b0}};
            decode_uses_rs1 = 3'b000;
            decode_uses_rs2 = 3'b000;
            for (lane = 0; lane < lane_count; lane = lane + 1) begin
                decode_payload[lane*IW +: IW] =
                    instruction_stream[next_instruction + lane];
                decode_uses_rs1[lane] =
                    program_uses_rs1[next_instruction + lane];
                decode_uses_rs2[lane] =
                    program_uses_rs2[next_instruction + lane];
            end
            decode_valid = send_mask;
            tick();
            decode_valid = 3'b000;
            decode_payload = {3*IW{1'b0}};
            decode_uses_rs1 = 3'b000;
            decode_uses_rs2 = 3'b000;
            next_instruction = next_instruction + lane_count;
        end

        for (cycles = 0;
             (cycles < 600) && (retired_total < INSTRUCTION_COUNT);
             cycles = cycles + 1)
            tick();
        repeat (3) tick();

        if (retired_total != INSTRUCTION_COUNT)
            fail("instruction stream did not fully retire");
        if ((retire_occupancy != 0) || (dispatch_occupancy != 0) ||
            (write_busy != 0) || barrier_active)
            fail("banked backend did not drain cleanly");
        if ((ISSUE_WINDOW == 0) && !saw_three_wide_input)
            fail("test never exercised three-wide decode acceptance");
        if (!saw_two_wide_issue)
            fail("test never exercised two-wide issue");
        if (!saw_two_wide_retire)
            fail("test never exercised two-wide retirement");
        if ((ISSUE_WINDOW == 0) && !saw_read_bank_retry)
            fail("test never exercised a read-bank retry");
        if (!saw_write_bank_retry)
            fail("test never exercised a sliding same-bank write pair");
        if (!saw_dependency_wait)
            fail("test never observed conservative dependency waiting");
        if ((ISSUE_WINDOW == 0) && !saw_exu_forward_while_busy)
            fail("test never consumed an EXU completion before retirement");
        if ((ISSUE_WINDOW == 0) && !saw_write_ack_read_overlap)
            fail("test never overlapped a dependent read with write ack");
        if (!saw_regload_address_issue_overlap)
            fail("test never overlapped register address and issue phases");
        if (!saw_back_to_back_issue)
            fail("test never issued in back-to-back cycles");

        // Isolate the steering probe from the throughput/conflict coverage
        // above.  The normal ready signal is payload-qualified, so force only
        // the new structural-capacity sideband: EX0 unavailable, EX1 free.
        // Execution's real ready/valid handshake still checks and accepts the
        // retargeted packet.
        if (ISSUE_WINDOW == 0) begin
        memory_probe_active = 1'b1;
        memory_probe_retired = 0;
        force dut.base_alu_available = 2'b10;
        decode_payload = {3*IW{1'b0}};
        decode_payload[0 +: IW] = addi_packet(28, 0, 29, 64'd42, 1'b0);
        decode_uses_rs1 = 3'b001;
        decode_valid = 3'b001;
        while (!decode_ready[0])
            tick();
        tick();
        decode_valid = 3'b000;
        decode_payload = {3*IW{1'b0}};
        decode_uses_rs1 = 3'b000;
        for (cycles = 0;
             (cycles < 20) && (!saw_base_alu_reroute ||
                               (memory_probe_retired == 0));
             cycles = cycles + 1)
            tick();
        release dut.base_alu_available;
        if (!saw_base_alu_reroute)
            fail("base ALU did not retarget from unavailable EX0 to EX1");
        if ((memory_probe_retired != 1) ||
            (dut.u_gpr.regs[29] !== 64'd42))
            fail("retargeted base ALU did not retire the correct result");
        memory_probe_active = 1'b0;
        memory_probe_retired = 0;
        end

        // A returned load occupies MEM0's completion lane.  Keep its direct
        // consumer waiting on x27 until the tagged response arrives; the
        // registered forwarding stage must supply it before retirement writes
        // x27.
        memory_probe_active = 1'b1;
        decode_payload = {3*IW{1'b0}};
        decode_payload[0 +: IW] = load_packet(28, 0, 27, 64'h100);
        decode_payload[IW +: IW] =
            addi_packet(29, 27, 28, 64'd1, 1'b0);
        decode_uses_rs1 = 3'b011;
        decode_uses_rs2 = 3'b000;
        decode_valid = 3'b011;
        while (decode_ready[1:0] != 2'b11)
            tick();
        tick();
        decode_valid = 3'b000;
        decode_payload = {3*IW{1'b0}};
        decode_uses_rs1 = 3'b000;

        for (cycles = 0; (cycles < 40) && !mem_valid;
             cycles = cycles + 1)
            tick();
        if (!mem_valid || !mem_physical || (mem_addr != 64'h100)) begin
            $display("MEM0 probe state: valid=%0b physical=%0b addr=%h dispatch=%0d retire=%0d busy27=%0b issue=%b",
                     mem_valid, mem_physical, mem_addr,
                     dispatch_occupancy, retire_occupancy,
                     write_busy[27], issue_valid);
            fail("MEM0 forwarding probe did not launch its load");
        end
        probe_load_tag = mem_tag;
        mem_ready = 1'b1;
        tick();
        mem_ready = 1'b0;

        mem_resp_tag = probe_load_tag;
        mem_rdata = 64'h1122_3344_5566_7788;
        mem_resp_valid = 1'b1;
        for (cycles = 0; (cycles < 20) && !mem_resp_ready;
             cycles = cycles + 1)
            tick();
        if (!mem_resp_ready)
            fail("MEM0 forwarding probe response was not accepted");
        tick();
        mem_resp_valid = 1'b0;

        for (cycles = 0;
             (cycles < 100) && ((memory_probe_retired < 2) ||
                                (dispatch_occupancy != 0) ||
                                (retire_occupancy != 0));
             cycles = cycles + 1)
            tick();
        repeat (2) tick();
        if (memory_probe_retired != 2)
            fail("MEM0 forwarding probe did not retire both instructions");
        if ((ISSUE_WINDOW == 0) && !saw_mem_forward_while_busy)
            fail("load result was not consumed from MEM0 completion");
        if ((dispatch_occupancy != 0) || (retire_occupancy != 0) ||
            (write_busy != 0))
            fail("MEM0 forwarding probe did not drain cleanly");
        memory_probe_active = 1'b0;

        if (dut.u_gpr.regs[1] !== 64'd5 ||
            dut.u_gpr.regs[2] !== 64'd9 ||
            dut.u_gpr.regs[4] !== 64'd14 ||
            dut.u_gpr.regs[5] !== 64'd4 ||
            dut.u_gpr.regs[6] !== 64'd10 ||
            dut.u_gpr.regs[7] !== 64'd14 ||
            dut.u_gpr.regs[8] !== 64'd10 ||
            dut.u_gpr.regs[9] !== 64'd80 ||
            dut.u_gpr.regs[10] !== 64'd2 ||
            dut.u_gpr.regs[11] !== {64{1'b1}} ||
            dut.u_gpr.regs[12] !== 64'd1 ||
            dut.u_gpr.regs[13] !== 64'd0 ||
            dut.u_gpr.regs[14] !== 64'd123 ||
            dut.u_gpr.regs[15] !== 64'd128 ||
            dut.u_gpr.regs[16] !== 64'd16 ||
            dut.u_gpr.regs[17] !== 64'd17 ||
            dut.u_gpr.regs[18] !== 64'd1 ||
            dut.u_gpr.regs[19] !== 64'd23 ||
            dut.u_gpr.regs[20] !== 64'd24 ||
            dut.u_gpr.regs[21] !== 64'h0000_0000_1234_5000 ||
            dut.u_gpr.regs[22] !== 64'h0000_0000_0000_305c ||
            dut.u_gpr.regs[23] !== 64'h0000_0000_1234_805c ||
            dut.u_gpr.regs[24] !== 64'hffff_ffff_ffff_fffd ||
            dut.u_gpr.regs[25] !== 64'h0000_0000_1234_4ffc ||
            dut.u_gpr.regs[26] !== {64{1'b1}} ||
            dut.u_gpr.regs[27] !== 64'h1122_3344_5566_7788 ||
            dut.u_gpr.regs[28] !== 64'h1122_3344_5566_7789 ||
            dut.u_gpr.regs[29] !== ((ISSUE_WINDOW == 0) ?
                                    64'd42 : -64'd4))
            fail("final architectural register state was incorrect");

        if (ISSUE_WINDOW != 0)
            $display("PASS: banked 3p issue window processed post-selection register loads, ordered arithmetic, load/use, and held bank retries");
        else
            $display("PASS: banked 3p backend processed ordered arithmetic plus a MEM0-forwarded load/use with held bank retries and conservative dependencies");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "tb_backend_3p_banked: timeout");
    end
endmodule
