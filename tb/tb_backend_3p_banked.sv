`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/isa/rv64-zbb.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/alu2-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"

module tb_backend_3p_banked #(
    parameter integer ISSUE_WINDOW = 0,
    parameter integer SPECULATION_WINDOW = ISSUE_WINDOW,
    parameter integer ENABLE_ALU_CHAINING = 0,
    parameter integer CHAIN_PROBE_ONLY = 0,
    parameter integer RENAME_MODE = 0,
    parameter integer RETIRE_DEPTH = 16,
    parameter integer SCHEDULER_DEPTH = RETIRE_DEPTH
);
    localparam integer IW = `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH;
    localparam integer SLOT_WIDTH = (RETIRE_DEPTH <= 1) ? 1 :
        $clog2(RETIRE_DEPTH);
    localparam integer RCW = $clog2(RETIRE_DEPTH + 1);
    localparam integer DCW = $clog2(
        (((ISSUE_WINDOW != 0) || (RENAME_MODE != 0)) ?
         SCHEDULER_DEPTH : 6) + 1);
    localparam integer INSTRUCTION_COUNT = 29;
    localparam integer PHYS_REG_COUNT = (RENAME_MODE != 0) ? 63 : 31;
    localparam integer PHYS_REG_ADDR_WIDTH =
        (PHYS_REG_COUNT < 1) ? 1 : $clog2(PHYS_REG_COUNT + 1);
    localparam integer RETIRE_META_WIDTH =
        `OPENRV64_RETIRE_ALLOC_FIXED_WIDTH + 2*PHYS_REG_ADDR_WIDTH;

    localparam integer I_PRIV = 2;
    localparam integer I_MEM_WRITE = 15;
    localparam integer I_MEM_READ = 16;
    localparam integer I_JUMP = 13;
    localparam integer I_PREDICTED = 12;
    localparam integer I_REG_WRITE = 17;
    localparam integer I_BR_OP = 18;
    localparam integer I_LSU_OP = 22;
    localparam integer I_ALU_OP = 27;
    localparam integer I_ALU_EXT = 32;
    localparam integer I_RD = 35;
    localparam integer I_IMM = 40;
    localparam integer I_RS1_DATA = 168;
    localparam integer I_RS2 = 232;
    localparam integer I_RS1 = 237;
    localparam integer I_INSTR = 242;
    localparam integer I_PC = 274;
    localparam integer I_TRACE = 338;

    reg clk;
    reg rst_n;
    reg flush;
    reg squash;
    reg inhibit_load_speculation;
    reg branch_target_mispredict;
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
    reg mem_resp_error;
    wire [63:0] mem_addr;
    wire mem_write;
    reg [63:0] mem_rdata;
    reg mem_store_done_valid;
    wire mem_store_done_ready;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_store_done_tag;
    wire mem_xlate_valid;
    wire [`OPENRV64_LSU_XLATE_TAG_WIDTH-1:0] mem_xlate_tag;
    wire [63:0] mem_xlate_vaddr;
    reg mem_xlate_resp_valid_q;
    wire mem_xlate_resp_ready;
    reg [`OPENRV64_LSU_XLATE_TAG_WIDTH-1:0] mem_xlate_resp_tag_q;
    reg [63:0] mem_xlate_resp_paddr_q;
    wire mem1_valid;
    wire redirect_valid;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] redirect_id;
    wire [63:0] redirect_target;
    wire redirect_tagged_recovery;
    wire [63:0] branch_target;
    wire [2:0] retire_arch;
    wire [2:0] retire_count;
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
        .PHYS_REG_COUNT(PHYS_REG_COUNT),
        .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
        .ENABLE_TRACE(1),
        .COMPLETION_FORWARD_MASK(3'b111),
        .BRANCH_COMPLETION_FORWARD_MASK(3'b000),
        .ENABLE_FULL_FORWARDING(0),
        .RELAX_WAW(1),
        .RELAX_HAZARDS(0),
        .ENABLE_ISSUE_WINDOW(ISSUE_WINDOW),
        .ENABLE_SPECULATION_WINDOW(SPECULATION_WINDOW),
        .ENABLE_ALU2(RENAME_MODE != 0),
        .ENABLE_ALU_CHAINING(ENABLE_ALU_CHAINING),
        .RENAME_MODE(RENAME_MODE),
        .ISSUE_WINDOW_DEPTH(SCHEDULER_DEPTH),
        .BANKED_GPR(1),
        .FPGA_GPR_LUTRAM(0),
        .CACHEABLE_BASE(64'd0),
        .CACHEABLE_SIZE(64'h1000)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .squash_frontend_i(squash),
        .coherent_reservation_clear_i(1'b0),
        .translation_bypass_i(1'b1),
        .inhibit_load_speculation_i(inhibit_load_speculation),
        .decode_valid_i(decode_valid),
        .decode_ready_o(decode_ready),
        .decode_payload_i(decode_payload),
        .decode_uses_rs1_i(decode_uses_rs1),
        .decode_uses_rs2_i(decode_uses_rs2),
        .decode_allocation_id_o(),
        .decode_allocation_slot_o(),
        .prediction_update_valid_i(1'b0),
        .prediction_update_id_i(0),
        .prediction_update_slot_i(0),
        .prediction_update_taken_i(1'b0),
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
        .mem_error_i(mem_resp_error),
        .mem_page_fault_i(1'b0),
        .mem_store_done_valid_i(mem_store_done_valid),
        .mem_store_done_ready_o(mem_store_done_ready),
        .mem_store_done_tag_i(mem_store_done_tag),
        .store_barrier_request_o(),
        .store_barrier_busy_i(1'b0),
        .mem_access_allowed_i(1'b1),
        .mem_lock_o(),
        .mem_write_o(mem_write),
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
        .branch_target_mispredict_i(branch_target_mispredict),
        .redirect_valid_o(redirect_valid),
        .redirect_id_o(redirect_id),
        .redirect_target_o(redirect_target),
        .redirect_memory_replay_o(),
        .redirect_tagged_recovery_o(redirect_tagged_recovery),
        .branch_resolved_o(),
        .branch_conditional_o(),
        .branch_taken_o(),
        .branch_pc_o(),
        .branch_instr_o(),
        .branch_target_o(branch_target),
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

    function automatic [IW-1:0] store_packet;
        input [63:0] trace;
        input [4:0] rs1;
        input [4:0] rs2;
        input [63:0] immediate;
        reg [IW-1:0] packet;
        begin
            packet = base_packet(
                trace,
                {immediate[11:5], rs2, rs1, 3'b011,
                 immediate[4:0], `RV64_OPCODE_STORE});
            packet[I_RS1 +: 5] = rs1;
            packet[I_RS2 +: 5] = rs2;
            packet[I_IMM +: 64] = immediate;
            packet[I_LSU_OP +: 5] = `RV64_LSU_OP_SD;
            packet[I_MEM_WRITE] = 1'b1;
            store_packet = packet;
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

    function automatic [IW-1:0] jalr_packet;
        input [63:0] trace;
        input [4:0] rs1;
        input [4:0] rd;
        input [63:0] immediate;
        reg [IW-1:0] packet;
        begin
            packet = base_packet(
                trace,
                {immediate[11:0], rs1, 3'b000, rd,
                 `RV64_OPCODE_JALR});
            packet[I_RS1 +: 5] = rs1;
            packet[I_RD +: 5] = rd;
            packet[I_IMM +: 64] = immediate;
            packet[I_BR_OP +: `RV64_BR_OP_WIDTH] = `RV64_BR_OP_JALR;
            packet[I_JUMP] = 1'b1;
            packet[I_PREDICTED] = 1'b1;
            packet[I_REG_WRITE] = (rd != 0);
            jalr_packet = packet;
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

    function automatic [IW-1:0] zbb_rotate_packet;
        input [63:0] trace;
        input [4:0] rs1;
        input [4:0] rs2;
        input [4:0] rd;
        input [`RV64_ALU_OP_WIDTH-1:0] operation;
        input word_op;
        reg [IW-1:0] packet;
        reg [2:0] funct3;
        reg [6:0] opcode;
        begin
            funct3 = (operation == `RV64_ALU_OP_ZBB_ROL) ?
                `RV64_ZBB_FUNCT3_ROL : `RV64_ZBB_FUNCT3_ROR;
            opcode = word_op ? `RV64_OPCODE_OP_32 : `RV64_OPCODE_OP;
            packet = base_packet(
                trace,
                {`RV64_ZBB_FUNCT7_ROTATE, rs2, rs1, funct3, rd, opcode});
            packet[I_RS1 +: 5] = rs1;
            packet[I_RS2 +: 5] = rs2;
            packet[I_RD +: 5] = rd;
            packet[I_ALU_EXT +: 3] = `RV64_ALU_EXT_ZBB;
            packet[I_ALU_OP +: 5] = operation;
            packet[I_REG_WRITE] = 1'b1;
            packet[9] = word_op;
            zbb_rotate_packet = packet;
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
    reg saw_alu2_issue;
    reg saw_alu2_zbb_rotate;
    reg saw_alu2_forward;
    reg saw_ex1_auipc;
    reg saw_ex1_slt;
    reg saw_ex1_sltu;
    reg prior_cycle_issued;
    reg memory_probe_active;
    integer memory_probe_retired;
    reg [4:0] memory_probe_last_rd;
    reg [63:0] memory_probe_last_wdata;
    reg saw_physical_free;
    reg saw_nonidentity_phys;
    reg saw_scheduler_release_before_retire;
    reg saw_scheduler_slot_reuse_before_retire;
    reg saw_jalr_resolve_before_head;
    reg saw_jalr_younger_issue;
    reg saw_jalr_resolve;
    reg tomasulo_forward_probe_active;
    reg saw_tomasulo_alu_forward_accept;
    reg saw_tomasulo_alu_forward_without_writeback;
    reg saw_tomasulo_alu_chain_issue;
    reg tomasulo_exu_mem_chain_probe_active;
    reg saw_tomasulo_exu_mem_chain_accept;
    reg saw_tomasulo_exu_mem_chain_issue;
    reg tomasulo_control_chain_probe_active;
    reg saw_tomasulo_control_chain_accept;
    reg saw_tomasulo_control_chain_issue;
    reg tomasulo_load_forward_probe_active;
    reg saw_tomasulo_load_forward_accept;
    reg saw_tomasulo_load_forward_without_writeback;
    reg memory_replay_probe_active;
    reg saw_memory_replay_store_sideband;
    integer replay_store_component_count;
    integer jalr_probe_pipe;
    integer ex1_assist_pipe;
    integer forward_probe_pipe;
    integer forward_probe_port;
    integer forward_probe_window;
    integer rename_monitor_lane;
    integer monitor_cycle;
    integer forward_producer_issue_cycle;
    integer exu_mem_producer_issue_cycle;
    integer exu_mem_producer_lane;
    integer exu_mem_accept_cycle;
    integer exu_mem_issue_cycle;
    integer control_chain_producer_issue_cycle;
    integer control_chain_accept_cycle;
    integer control_chain_issue_cycle;
    integer load_completion_cycle;
    wire [6:0] observed_rename_free_count;
    wire [PHYS_REG_COUNT:0] observed_phys_ready;

    generate
        if (RENAME_MODE == `OPENRV64_RENAME_TOMASULO) begin :
                g_observe_tomasulo
            assign observed_rename_free_count =
                dut.u_dispatch.g_3p.g_tomasulo.rename_free_count;
            assign observed_phys_ready =
                dut.u_dispatch.g_3p.g_tomasulo.u_rename.phys_ready_q;

            reg [RETIRE_DEPTH-1:0] scheduler_slot_seen;
            reg [$clog2(RETIRE_DEPTH)-1:0]
                prior_rob_slot [0:RETIRE_DEPTH-1];
            reg [`OPENRV64_INSTR_ID_WIDTH-1:0]
                prior_id [0:RETIRE_DEPTH-1];
            integer monitor_lane;
            integer monitor_slot;
            integer monitor_init;
            wire [2:0] monitor_decode_fire =
                dut.u_dispatch.g_3p
                    .u_tomasulo_window.u_window.decode_fire;
            wire [3:0] monitor_alloc_slot0 =
                dut.u_dispatch.g_3p
                    .u_tomasulo_window.u_window.scheduler_alloc_slot[0];
            wire [3:0] monitor_alloc_slot1 =
                dut.u_dispatch.g_3p
                    .u_tomasulo_window.u_window.scheduler_alloc_slot[1];
            wire [3:0] monitor_alloc_slot2 =
                dut.u_dispatch.g_3p
                    .u_tomasulo_window.u_window.scheduler_alloc_slot[2];
            wire [3*$clog2(RETIRE_DEPTH)-1:0] monitor_allocation_slot =
                dut.u_dispatch.g_3p
                    .u_tomasulo_window.u_window.allocation_slot_i;
            wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0]
                monitor_allocation_id =
                    dut.u_dispatch.g_3p
                        .u_tomasulo_window.u_window.allocation_id_i;

            always @(posedge clk) begin
                if (!rst_n || flush) begin
                    scheduler_slot_seen = {RETIRE_DEPTH{1'b0}};
                    for (monitor_init = 0; monitor_init < RETIRE_DEPTH;
                         monitor_init = monitor_init + 1) begin
                        prior_rob_slot[monitor_init] = 0;
                        prior_id[monitor_init] = 0;
                    end
                end else begin
                    if (retire_occupancy > dispatch_occupancy)
                        saw_scheduler_release_before_retire = 1'b1;
                    for (monitor_lane = 0; monitor_lane < 3;
                         monitor_lane = monitor_lane + 1) begin
                        if (monitor_decode_fire[monitor_lane]) begin
                            case (monitor_lane)
                                0: monitor_slot = monitor_alloc_slot0;
                                1: monitor_slot = monitor_alloc_slot1;
                                default: monitor_slot = monitor_alloc_slot2;
                            endcase
                            if (scheduler_slot_seen[monitor_slot] &&
                                dut.u_retire_queue.valid_q[
                                    prior_rob_slot[monitor_slot]] &&
                                (dut.u_retire_queue.id_q[
                                    prior_rob_slot[monitor_slot]] ==
                                 prior_id[monitor_slot]) &&
                                !((dut.queue_retire_accept[0] &&
                                   (dut.queue_retire_id[
                                      0*`OPENRV64_INSTR_ID_WIDTH +:
                                      `OPENRV64_INSTR_ID_WIDTH] ==
                                    prior_id[monitor_slot])) ||
                                  (dut.queue_retire_accept[1] &&
                                   (dut.queue_retire_id[
                                      1*`OPENRV64_INSTR_ID_WIDTH +:
                                      `OPENRV64_INSTR_ID_WIDTH] ==
                                    prior_id[monitor_slot])) ||
                                  (dut.queue_retire_accept[2] &&
                                   (dut.queue_retire_id[
                                      2*`OPENRV64_INSTR_ID_WIDTH +:
                                      `OPENRV64_INSTR_ID_WIDTH] ==
                                    prior_id[monitor_slot]))))
                                saw_scheduler_slot_reuse_before_retire = 1'b1;
                            scheduler_slot_seen[monitor_slot] = 1'b1;
                            prior_rob_slot[monitor_slot] =
                                monitor_allocation_slot[
                                    monitor_lane*$clog2(RETIRE_DEPTH) +:
                                    $clog2(RETIRE_DEPTH)];
                            prior_id[monitor_slot] =
                                monitor_allocation_id[
                                    monitor_lane*`OPENRV64_INSTR_ID_WIDTH +:
                                    `OPENRV64_INSTR_ID_WIDTH];
                        end
                    end
                end
            end
        end else begin : g_observe_identity
            assign observed_rename_free_count = 7'd0;
            assign observed_phys_ready =
                {(PHYS_REG_COUNT + 1){1'b1}};
        end
    endgenerate

    always @(negedge clk) begin
        if (!rst_n) begin
            monitor_cycle = 0;
            forward_producer_issue_cycle = -1;
            exu_mem_producer_issue_cycle = -1;
            exu_mem_producer_lane = -1;
            exu_mem_accept_cycle = -1;
            exu_mem_issue_cycle = -1;
            control_chain_producer_issue_cycle = -1;
            control_chain_accept_cycle = -1;
            control_chain_issue_cycle = -1;
            load_completion_cycle = -1;
        end else begin
            monitor_cycle = monitor_cycle + 1;
            issue_count = issue_valid[0] + issue_valid[1] +
                          issue_valid[2] + issue_valid[3];
            if (issue_count > (((ISSUE_WINDOW != 0) ||
                                (RENAME_MODE != 0)) ? 3 : 2))
                fail("banked backend exceeded register-load issue width");
            if (issue_count == 2)
                saw_two_wide_issue = 1'b1;
            for (ex1_assist_pipe = 0;
                 ex1_assist_pipe < `OPENRV64_EXEC_PIPE_COUNT;
                 ex1_assist_pipe = ex1_assist_pipe + 1) begin
                if (issue_valid[ex1_assist_pipe] &&
                    (dut.pipe_payload[
                        ex1_assist_pipe*IW + I_ALU_EXT +: 3] ==
                     `RV64_ALU_EXT_BASE) &&
                    ((dut.pipe_payload[
                          ex1_assist_pipe*IW + I_ALU_OP +: 5] ==
                      `RV64_ALU_OP_AUIPC) ||
                     (dut.pipe_payload[
                          ex1_assist_pipe*IW + I_ALU_OP +: 5] ==
                      `RV64_ALU_OP_SLT) ||
                     (dut.pipe_payload[
                          ex1_assist_pipe*IW + I_ALU_OP +: 5] ==
                      `RV64_ALU_OP_SLTU))) begin
                    if (ex1_assist_pipe != `OPENRV64_EXEC_PIPE_EX1)
                        fail("AUIPC/compare operation issued outside EX1");
                    case (dut.pipe_payload[
                              ex1_assist_pipe*IW + I_ALU_OP +: 5])
                        `RV64_ALU_OP_AUIPC: saw_ex1_auipc = 1'b1;
                        `RV64_ALU_OP_SLT:   saw_ex1_slt = 1'b1;
                        `RV64_ALU_OP_SLTU:  saw_ex1_sltu = 1'b1;
                    endcase
                end
            end
            if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
                issue_valid[`OPENRV64_EXEC_PIPE_MEM0] &&
                !dut.pipe_payload[
                    `OPENRV64_EXEC_PIPE_MEM0*IW + I_MEM_READ] &&
                !dut.pipe_payload[
                    `OPENRV64_EXEC_PIPE_MEM0*IW + I_MEM_WRITE]) begin
                if (!`OPENRV64_ALU2_OP_SUPPORTED(
                        dut.pipe_payload[
                            `OPENRV64_EXEC_PIPE_MEM0*IW + I_ALU_EXT +: 3],
                        dut.pipe_payload[
                            `OPENRV64_EXEC_PIPE_MEM0*IW + I_ALU_OP +: 5]))
                    fail("dispatch routed a disabled operation to ALU2");
                if ((dut.pipe_payload[
                         `OPENRV64_EXEC_PIPE_MEM0*IW + I_ALU_EXT +: 3] ==
                     `RV64_ALU_EXT_BASE) &&
                    ((dut.pipe_payload[
                          `OPENRV64_EXEC_PIPE_MEM0*IW + I_ALU_OP +: 5] ==
                      `RV64_ALU_OP_ADD) ||
                     (dut.pipe_payload[
                          `OPENRV64_EXEC_PIPE_MEM0*IW + I_ALU_OP +: 5] ==
                      `RV64_ALU_OP_SUB)))
                    fail("dispatch routed ADD/SUB to restricted ALU2");
                saw_alu2_issue = 1'b1;
                if ((dut.pipe_payload[
                         `OPENRV64_EXEC_PIPE_MEM0*IW + I_ALU_EXT +: 3] ==
                     `RV64_ALU_EXT_ZBB) &&
                    ((dut.pipe_payload[
                          `OPENRV64_EXEC_PIPE_MEM0*IW + I_ALU_OP +: 5] ==
                      `RV64_ALU_OP_ZBB_ROL) ||
                     (dut.pipe_payload[
                          `OPENRV64_EXEC_PIPE_MEM0*IW + I_ALU_OP +: 5] ==
                      `RV64_ALU_OP_ZBB_ROR)))
                    saw_alu2_zbb_rotate = 1'b1;
            end
            if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
                dut.tomasulo_alu2_forward_valid) begin
                if (!dut.dispatch_completion_forward_valid[2])
                    fail("ALU2 completion missed MEM0 forwarding path");
                saw_alu2_forward = 1'b1;
            end
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
            if (retire_count == 2)
                saw_two_wide_retire = 1'b1;

            // This is execution acceptance, not scheduler release.  The
            // directed probe below leaves an older load at the ROB head and
            // requires both the JALR and younger ALU packet to reach EX.
            for (jalr_probe_pipe = 0;
                 jalr_probe_pipe < `OPENRV64_EXEC_PIPE_COUNT;
                 jalr_probe_pipe = jalr_probe_pipe + 1) begin
                if (issue_valid[jalr_probe_pipe] &&
                    (dut.pipe_payload[
                        jalr_probe_pipe*IW + I_TRACE +: 64] == 64'd42))
                    saw_jalr_younger_issue = 1'b1;
            end
            if (dut.exec_branch_resolved &&
                (`RV64_OPCODE(dut.exec_branch_instr) ==
                 `RV64_OPCODE_JALR)) begin
                saw_jalr_resolve = 1'b1;
                if (dut.exec_redirect_id != dut.ordered_head_id)
                    saw_jalr_resolve_before_head = 1'b1;
            end
            if (memory_replay_probe_active &&
                dut.posted_store_complete_valid &&
                dut.posted_store_complete_accept)
                saw_memory_replay_store_sideband = 1'b1;

            // Address-phase acceptance of trace 61 must use the exact live
            // physical producer.  In chain mode it occurs in the producer's
            // issue cycle; otherwise the probe holds every PRF write ack low
            // to exercise ordinary registered-completion forwarding.
            if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
                tomasulo_forward_probe_active) begin
                for (forward_probe_pipe = 0;
                     forward_probe_pipe < `OPENRV64_EXEC_PIPE_COUNT;
                     forward_probe_pipe = forward_probe_pipe + 1) begin
                    if (issue_valid[forward_probe_pipe] &&
                        (dut.pipe_payload[
                            forward_probe_pipe*IW + I_TRACE +: 64] ==
                         64'd60)) begin
                        forward_producer_issue_cycle = monitor_cycle;
                        $display(
                            "ALU_CHAIN_PROBE producer_cycle=%0d lane=%0d chain_producer=%b ids=%h dispatch_valid=%b dispatch_chain=%b",
                            monitor_cycle, forward_probe_pipe,
                            dut.alu_chain_producer_valid,
                            dut.alu_chain_producer_id,
                            dut.dispatch_pipe_valid,
                            dut.dispatch_pipe_chain_mask);
                        for (forward_probe_window = 0;
                             forward_probe_window < SCHEDULER_DEPTH;
                             forward_probe_window = forward_probe_window + 1)
                            if (dut.u_dispatch.g_3p.u_tomasulo_window.u_window
                                    .valid_q[forward_probe_window] &&
                                (dut.u_dispatch.g_3p.u_tomasulo_window.u_window
                                     .payload_q[forward_probe_window]
                                     [I_TRACE +: 64] == 64'd61))
                                $display(
                                    "ALU_CHAIN_PROBE consumer_slot=%0d issued=%b src1_ready=%b tag=%0d elig0=%b elig1=%b mask0=%b mask1=%b",
                                    forward_probe_window,
                                    dut.u_dispatch.g_3p.u_tomasulo_window
                                        .u_window.issued_q[
                                            forward_probe_window],
                                    dut.u_dispatch.g_3p.u_tomasulo_window
                                        .u_window.src1_ready_now[
                                            forward_probe_window],
                                    dut.u_dispatch.g_3p.u_tomasulo_window
                                        .u_window.src1_tag_q[
                                            forward_probe_window],
                                    dut.u_dispatch.g_3p.u_tomasulo_window
                                        .u_window.chain_eligible_ex0[
                                            forward_probe_window],
                                    dut.u_dispatch.g_3p.u_tomasulo_window
                                        .u_window.chain_eligible_ex1[
                                            forward_probe_window],
                                    dut.u_dispatch.g_3p.u_tomasulo_window
                                        .u_window.chain_mask_ex0[
                                            forward_probe_window],
                                    dut.u_dispatch.g_3p.u_tomasulo_window
                                        .u_window.chain_mask_ex1[
                                            forward_probe_window]);
                    end
                    if ((ENABLE_ALU_CHAINING != 0) &&
                        issue_valid[forward_probe_pipe] &&
                        dut.pipe_ready[forward_probe_pipe] &&
                        (dut.pipe_payload[
                            forward_probe_pipe*IW + I_TRACE +: 64] ==
                         64'd61)) begin
                        if ((forward_probe_pipe > 1) ||
                            !(|dut.pipe_chain_mask[
                                forward_probe_pipe*2 +: 2]))
                            fail("ALU chain consumer issued without chain mask");
                        if (dut.pipe_src1_producer_id[
                                forward_probe_pipe*
                                `OPENRV64_INSTR_ID_WIDTH +:
                                `OPENRV64_INSTR_ID_WIDTH] !=
                            dut.complete_id[
                                forward_probe_pipe*
                                `OPENRV64_INSTR_ID_WIDTH +:
                                `OPENRV64_INSTR_ID_WIDTH])
                            fail("ALU chain consumed wrong retained producer");
                        saw_tomasulo_alu_chain_issue = 1'b1;
                    end
                    if (dut.dispatch_pipe_valid[forward_probe_pipe] &&
                        (dut.dispatch_pipe_payload[
                            forward_probe_pipe*IW + I_TRACE +: 64] ==
                         64'd61)) begin
                        if (dut.dispatch_pipe_src1_producer_valid[
                                forward_probe_pipe] !== 1'b1)
                            fail("ALU dependent did not mark forwarded rs1");
                        if ((ENABLE_ALU_CHAINING == 0) &&
                            (dut.dispatch_pipe_payload[
                                forward_probe_pipe*IW + I_RS1_DATA +: 64]
                             !== 64'd41))
                            fail("ALU dependent captured wrong forward data");
                        if (observed_phys_ready[
                                dut.dispatch_pipe_src1_phys[
                                    forward_probe_pipe*
                                    PHYS_REG_ADDR_WIDTH +:
                                    PHYS_REG_ADDR_WIDTH]] !== 1'b0)
                            fail("ALU forward incorrectly required PRF ready");
                        if (forward_producer_issue_cycle < 0)
                            fail("ALU dependent preceded producer issue");
                        if (monitor_cycle != forward_producer_issue_cycle +
                            ((ENABLE_ALU_CHAINING != 0) ? 0 : 1)) begin
                            $display({"ALU forward timing producer=%0d ",
                                      "dependent=%0d chain_producer=%b ",
                                      "chain_ids=%h dispatch_chain=%b ",
                                      "pipe_valid=%b pipe_ready=%b"},
                                     forward_producer_issue_cycle,
                                     monitor_cycle,
                                     dut.alu_chain_producer_valid,
                                     dut.alu_chain_producer_id,
                                     dut.dispatch_pipe_chain_mask,
                                     dut.pipe_valid, dut.pipe_ready);
                            fail("ALU dependent did not wake one cycle later");
                        end
                        if ((ENABLE_ALU_CHAINING != 0) &&
                            !(|dut.dispatch_pipe_chain_mask[
                                forward_probe_pipe*2 +: 2]))
                            fail("ALU dependent was not scheduler-chained");
                        // A chained consumer is released by the scheduler in
                        // the producer's issue cycle.  No producer completion
                        // or PRF writeback exists yet, so this same-cycle
                        // acceptance is the unambiguous latency proof.  The
                        // following-cycle EX check above separately proves
                        // that the exact retained producer result is used.
                        if (ENABLE_ALU_CHAINING != 0)
                            saw_tomasulo_alu_forward_without_writeback =
                                1'b1;
                        saw_tomasulo_alu_forward_accept = 1'b1;
                        for (forward_probe_port = 0;
                             forward_probe_port < 2;
                             forward_probe_port = forward_probe_port + 1) begin
                            if ((ENABLE_ALU_CHAINING == 0) &&
                                dut.tomasulo_alu_forward_valid[
                                    forward_probe_port] &&
                                !dut.completion_writeback_fire[
                                    forward_probe_port] &&
                                (dut.dispatch_pipe_src1_producer_id[
                                    forward_probe_pipe*
                                    `OPENRV64_INSTR_ID_WIDTH +:
                                    `OPENRV64_INSTR_ID_WIDTH] ==
                                 dut.complete_id[
                                    forward_probe_port*
                                    `OPENRV64_INSTR_ID_WIDTH +:
                                    `OPENRV64_INSTR_ID_WIDTH]))
                                saw_tomasulo_alu_forward_without_writeback =
                                    1'b1;
                        end
                    end
                end
            end

            if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
                tomasulo_exu_mem_chain_probe_active) begin
                for (forward_probe_pipe = 0;
                     forward_probe_pipe < `OPENRV64_EXEC_PIPE_COUNT;
                     forward_probe_pipe = forward_probe_pipe + 1) begin
                    if (issue_valid[forward_probe_pipe] &&
                        dut.pipe_ready[forward_probe_pipe] &&
                        (dut.pipe_payload[
                            forward_probe_pipe*IW + I_TRACE +: 64] ==
                         64'd62)) begin
                        if (forward_probe_pipe > 1)
                            fail("EXU-to-LSU producer did not use EX0/EX1");
                        exu_mem_producer_issue_cycle = monitor_cycle;
                        exu_mem_producer_lane = forward_probe_pipe;
                    end
                    if (dut.dispatch_pipe_valid[forward_probe_pipe] &&
                        dut.banked_independent_pipe_ready[
                            forward_probe_pipe] &&
                        (dut.dispatch_pipe_payload[
                            forward_probe_pipe*IW + I_TRACE +: 64] ==
                         64'd63)) begin
                        if (forward_probe_pipe !=
                            `OPENRV64_EXEC_PIPE_MEM0)
                            fail("EXU-to-LSU dependent was not a MEM0 load");
                        if (!dut.dispatch_pipe_chain_mask[
                                forward_probe_pipe*2+0])
                            fail("EXU-to-LSU load did not mark rs1 forwarding");
                        if (exu_mem_producer_issue_cycle < 0)
                            fail("EXU-to-LSU load preceded producer issue");
                        if (monitor_cycle != exu_mem_producer_issue_cycle)
                            fail("EXU-to-LSU load was not scheduled at N");
                        if (dut.dispatch_pipe_chain_select[
                                forward_probe_pipe*2+0] !=
                            (exu_mem_producer_lane == 1))
                            fail("EXU-to-LSU load selected the wrong EX lane");
                        exu_mem_accept_cycle = monitor_cycle;
                        saw_tomasulo_exu_mem_chain_accept = 1'b1;
                    end
                    if (issue_valid[forward_probe_pipe] &&
                        dut.pipe_ready[forward_probe_pipe] &&
                        (dut.pipe_payload[
                            forward_probe_pipe*IW + I_TRACE +: 64] ==
                         64'd63)) begin
                        if (forward_probe_pipe !=
                            `OPENRV64_EXEC_PIPE_MEM0)
                            fail("forwarded load entered the wrong LSU lane");
                        if (!dut.banked_independent_chain_response_valid[
                                forward_probe_pipe*2+0])
                            fail("forwarded load missed selected EX completion");
                        if (dut.pipe_payload[
                                forward_probe_pipe*IW + I_RS1_DATA +: 64] !==
                            64'h180)
                            fail("forwarded load received the wrong base value");
                        if ((exu_mem_producer_issue_cycle < 0) ||
                            (monitor_cycle !=
                             exu_mem_producer_issue_cycle + 1))
                            fail("EXU-to-LSU load did not enter LSU at N+1");
                        exu_mem_issue_cycle = monitor_cycle;
                        saw_tomasulo_exu_mem_chain_issue = 1'b1;
                    end
                end
            end

            if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
                tomasulo_control_chain_probe_active) begin
                for (forward_probe_pipe = 0;
                     forward_probe_pipe < `OPENRV64_EXEC_PIPE_COUNT;
                     forward_probe_pipe = forward_probe_pipe + 1) begin
                    if (issue_valid[forward_probe_pipe] &&
                        dut.pipe_ready[forward_probe_pipe] &&
                        (dut.pipe_payload[
                            forward_probe_pipe*IW + I_TRACE +: 64] ==
                         64'd64)) begin
                        if (forward_probe_pipe !=
                            `OPENRV64_EXEC_PIPE_EX1)
                            fail("AUIPC chain producer did not use EX1");
                        control_chain_producer_issue_cycle = monitor_cycle;
                    end
                    if (dut.dispatch_pipe_valid[forward_probe_pipe] &&
                        dut.banked_independent_pipe_ready[
                            forward_probe_pipe] &&
                        (dut.dispatch_pipe_payload[
                            forward_probe_pipe*IW + I_TRACE +: 64] ==
                         64'd65)) begin
                        if (forward_probe_pipe !=
                            `OPENRV64_EXEC_PIPE_EX1)
                            fail("chained JALR was not assigned to EX1");
                        if (!dut.dispatch_pipe_chain_mask[
                                forward_probe_pipe*2+0])
                            fail("AUIPC-to-JALR chain did not mark rs1");
                        if ((control_chain_producer_issue_cycle < 0) ||
                            (monitor_cycle !=
                             control_chain_producer_issue_cycle))
                            fail("JALR was not scheduled in AUIPC issue cycle");
                        control_chain_accept_cycle = monitor_cycle;
                        saw_tomasulo_control_chain_accept = 1'b1;
                    end
                    if (issue_valid[forward_probe_pipe] &&
                        dut.pipe_ready[forward_probe_pipe] &&
                        (dut.pipe_payload[
                            forward_probe_pipe*IW + I_TRACE +: 64] ==
                         64'd65)) begin
                        if ((forward_probe_pipe !=
                             `OPENRV64_EXEC_PIPE_EX1) ||
                            !dut.pipe_chain_mask[
                                forward_probe_pipe*2+0])
                            fail("JALR entered EX1 without retained chain");
                        if (dut.pipe_src1_producer_id[
                                forward_probe_pipe*
                                `OPENRV64_INSTR_ID_WIDTH +:
                                `OPENRV64_INSTR_ID_WIDTH] !=
                            dut.complete_id[
                                forward_probe_pipe*
                                `OPENRV64_INSTR_ID_WIDTH +:
                                `OPENRV64_INSTR_ID_WIDTH])
                            fail("JALR consumed the wrong EX1 producer");
                        if ((control_chain_producer_issue_cycle < 0) ||
                            (monitor_cycle !=
                             control_chain_producer_issue_cycle + 1))
                            fail("JALR did not execute one cycle after AUIPC");
                        if (!dut.exec_branch_resolved ||
                            !dut.exec_branch_taken ||
                            (dut.exec_redirect_target != 64'h3100))
                            fail("chained JALR resolved the wrong target");
                        control_chain_issue_cycle = monitor_cycle;
                        saw_tomasulo_control_chain_issue = 1'b1;
                    end
                end
            end

            // A load has variable issue-to-result latency.  Its dependent
            // must nevertheless be accepted in the first cycle that MEM0's
            // registered completion is live, even while the PRF write is
            // denied.  Trace 28/29 is the directed load-use pair below.
            if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
                tomasulo_load_forward_probe_active) begin
                if (dut.tomasulo_load_forward_valid &&
                    (load_completion_cycle < 0))
                    load_completion_cycle = monitor_cycle;
                for (forward_probe_pipe = 0;
                     forward_probe_pipe < `OPENRV64_EXEC_PIPE_COUNT;
                     forward_probe_pipe = forward_probe_pipe + 1) begin
                    if (dut.dispatch_pipe_valid[forward_probe_pipe] &&
                        (dut.dispatch_pipe_payload[
                            forward_probe_pipe*IW + I_TRACE +: 64] ==
                         64'd29)) begin
                        if (!dut.tomasulo_load_forward_valid)
                            fail("load dependent missed live MEM0 completion");
                        if (dut.dispatch_pipe_src1_producer_valid[
                                forward_probe_pipe] !== 1'b1)
                            fail("load dependent did not mark forwarded rs1");
                        if (dut.dispatch_pipe_payload[
                                forward_probe_pipe*IW + I_RS1_DATA +: 64]
                            !== 64'h1122_3344_5566_7788)
                            fail("load dependent captured wrong forward data");
                        if (observed_phys_ready[
                                dut.dispatch_pipe_src1_phys[
                                    forward_probe_pipe*
                                    PHYS_REG_ADDR_WIDTH +:
                                    PHYS_REG_ADDR_WIDTH]] !== 1'b0)
                            fail("load forward incorrectly required PRF ready");
                        if ((load_completion_cycle < 0) ||
                            (monitor_cycle != load_completion_cycle))
                            fail("load dependent did not wake with completion");
                        if (dut.dispatch_pipe_src1_producer_id[
                                forward_probe_pipe*
                                `OPENRV64_INSTR_ID_WIDTH +:
                                `OPENRV64_INSTR_ID_WIDTH] !=
                            dut.complete_id[
                                2*`OPENRV64_INSTR_ID_WIDTH +:
                                `OPENRV64_INSTR_ID_WIDTH])
                            fail("load dependent captured wrong producer ID");
                        saw_tomasulo_load_forward_accept = 1'b1;
                        if (!dut.completion_writeback_fire[2])
                            saw_tomasulo_load_forward_without_writeback =
                                1'b1;
                    end
                end
            end

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
                if (retire_wdata !== expected_result[expected_last_trace-1]) begin
                    $display("retire mismatch trace=%0d rd=%0d actual=%h expected=%h free=%0d",
                             retire_trace_id, retire_rd, retire_wdata,
                             expected_result[expected_last_trace-1],
                             observed_rename_free_count);
                    fail("retired arithmetic result was incorrect");
                end
                retired_total = expected_last_trace;
            end else if ((retire_count != 0) && memory_probe_active) begin
                memory_probe_retired = memory_probe_retired + retire_count;
                memory_probe_last_rd = retire_rd;
                memory_probe_last_wdata = retire_wdata;
            end

            if (RENAME_MODE != 0) begin
                if (|dut.rename_free_valid)
                    saw_physical_free = 1'b1;
                for (rename_monitor_lane = 0; rename_monitor_lane < 3;
                     rename_monitor_lane = rename_monitor_lane + 1) begin
                    if (dut.allocation_valid[rename_monitor_lane] &&
                        (dut.allocation_meta[
                            rename_monitor_lane*RETIRE_META_WIDTH +
                            `OPENRV64_RETIRE_ALLOC_NEW_PHYS_LSB +:
                            PHYS_REG_ADDR_WIDTH] > 31))
                        saw_nonidentity_phys = 1'b1;
                end
            end

            if (!memory_probe_active &&
                (mem_valid || mem_xlate_valid || mem1_valid))
                fail("non-memory instruction stream accessed memory");
            if ((redirect_valid && !memory_replay_probe_active) ||
                exception || halt || irq || mret || sret ||
                fence_i || sfence_vma)
                fail("non-control instruction stream raised a control event");
            if (write_busy[0])
                fail("x0 became busy");
            if ((dut.gpr_write[0] &&
                 (dut.gpr_write_addr[0 +: PHYS_REG_ADDR_WIDTH] ==
                  `RV64_REG_X0)) ||
                (dut.gpr_write[1] &&
                 (dut.gpr_write_addr[PHYS_REG_ADDR_WIDTH +:
                                     PHYS_REG_ADDR_WIDTH] ==
                  `RV64_REG_X0)))
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
            if ((RENAME_MODE == 0) &&
                ((dut.banked_read_forward_valid[0] &&
                 write_busy[dut.gpr_read_addr[0*5 +: 5]]) ||
                (dut.banked_read_forward_valid[1] &&
                 write_busy[dut.gpr_read_addr[1*5 +: 5]]) ||
                (dut.banked_read_forward_valid[2] &&
                 write_busy[dut.gpr_read_addr[2*5 +: 5]]) ||
                (dut.banked_read_forward_valid[3] &&
                 write_busy[dut.gpr_read_addr[3*5 +: 5]]))) begin
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
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] replay_head_load_tag;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] replay_wrong_load_tag;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] replay_store_tag;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] jalr_head_load_tag;
    reg [`OPENRV64_LSU_TAG_WIDTH-1:0] jalr_wrong_load_tag;
    reg [63:0] replay_watch_count_before;
    reg [63:0] replay_check_count_before;
    reg [63:0] replay_violation_count_before;
    reg [63:0] replay_count_before;
    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        squash = 1'b0;
        inhibit_load_speculation = 1'b0;
        branch_target_mispredict = 1'b0;
        decode_valid = 3'b000;
        decode_payload = {3*IW{1'b0}};
        decode_uses_rs1 = 3'b000;
        decode_uses_rs2 = 3'b000;
        mem_ready = 1'b0;
        mem_resp_valid = 1'b0;
        mem_resp_tag = {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
        mem_resp_error = 1'b0;
        mem_rdata = 64'd0;
        mem_store_done_valid = 1'b0;
        mem_store_done_tag = {`OPENRV64_LSU_TAG_WIDTH{1'b0}};
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
        saw_alu2_issue = 1'b0;
        saw_alu2_zbb_rotate = 1'b0;
        saw_alu2_forward = 1'b0;
        saw_ex1_auipc = 1'b0;
        saw_ex1_slt = 1'b0;
        saw_ex1_sltu = 1'b0;
        prior_cycle_issued = 1'b0;
        memory_probe_active = 1'b0;
        memory_probe_retired = 0;
        memory_probe_last_rd = 5'd0;
        memory_probe_last_wdata = 64'd0;
        saw_physical_free = 1'b0;
        saw_nonidentity_phys = 1'b0;
        saw_scheduler_release_before_retire = 1'b0;
        saw_scheduler_slot_reuse_before_retire = 1'b0;
        saw_jalr_resolve_before_head = 1'b0;
        saw_jalr_younger_issue = 1'b0;
        saw_jalr_resolve = 1'b0;
        tomasulo_forward_probe_active = 1'b0;
        saw_tomasulo_alu_forward_accept = 1'b0;
        saw_tomasulo_alu_forward_without_writeback = 1'b0;
        saw_tomasulo_alu_chain_issue = 1'b0;
        tomasulo_exu_mem_chain_probe_active = 1'b0;
        saw_tomasulo_exu_mem_chain_accept = 1'b0;
        saw_tomasulo_exu_mem_chain_issue = 1'b0;
        tomasulo_control_chain_probe_active = 1'b0;
        saw_tomasulo_control_chain_accept = 1'b0;
        saw_tomasulo_control_chain_issue = 1'b0;
        tomasulo_load_forward_probe_active = 1'b0;
        saw_tomasulo_load_forward_accept = 1'b0;
        saw_tomasulo_load_forward_without_writeback = 1'b0;
        memory_replay_probe_active = 1'b0;
        saw_memory_replay_store_sideband = 1'b0;

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
        // Two simultaneously ready Zbb rotates reserve EX0 for the older
        // operation and force the younger supported rotate onto ALU2.
        instruction_stream[27] = zbb_rotate_packet(
            28, 1, 1, 27, `RV64_ALU_OP_ZBB_ROR, 1'b0);
        instruction_stream[28] = zbb_rotate_packet(
            29, 2, 1, 28, `RV64_ALU_OP_ZBB_ROL, 1'b0);

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
        program_uses_rs2[27] = 1'b1;
        program_uses_rs2[28] = 1'b1;
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
        expected_result[27] = 64'h2800_0000_0000_0000;
        expected_result[28] = 64'h0000_0000_0000_0120;

        repeat (4) tick();
        rst_n = 1'b1;
        tick();

        // A younger register-load packet may already be resident at the
        // backend output when an older branch redirects.  It is legal to
        // handshake and discard that packet, but it must not allocate into
        // the LSQ on the redirect edge: the LSQ resident-state squash sees
        // only entries that existed before this edge.
        if ((ISSUE_WINDOW != 0) &&
            (RENAME_MODE == `OPENRV64_RENAME_TOMASULO)) begin
            dut.banked_independent_valid_q = 4'b0100;
            dut.banked_independent_id_q = {40{1'b0}};
            dut.banked_independent_id_q[
                `OPENRV64_EXEC_PIPE_MEM0*10 +: 10] = 10'd84;
            dut.banked_independent_slot_q = {4*4{1'b0}};
            dut.banked_independent_slot_q[
                `OPENRV64_EXEC_PIPE_MEM0*4 +: 4] = 4'd1;
            dut.banked_independent_payload_q = {4*IW{1'b0}};
            dut.banked_independent_payload_q[
                `OPENRV64_EXEC_PIPE_MEM0*IW +: IW] =
                load_packet(84, 0, 5, 0);
            dut.banked_independent_operand_done_q = 8'b00110000;
            force dut.u_exec.g_3p.u_exec.u_lsu.squash_younger_i = 1'b1;
            force dut.u_exec.g_3p.u_exec.u_lsu.squash_inclusive_i = 1'b0;
            force dut.u_exec.g_3p.u_exec.u_lsu.squash_id_i = 10'd81;
            #1;
            if (!issue_valid[`OPENRV64_EXEC_PIPE_MEM0] ||
                !dut.pipe_ready[`OPENRV64_EXEC_PIPE_MEM0])
                fail("redirected LSU packet was not consumable");
            if (dut.u_exec.g_3p.u_exec.u_lsu.u_lsq.load_alloc_fire)
                fail("redirected LSU packet allocated on squash edge");
            tick();
            release dut.u_exec.g_3p.u_exec.u_lsu.squash_younger_i;
            release dut.u_exec.g_3p.u_exec.u_lsu.squash_inclusive_i;
            release dut.u_exec.g_3p.u_exec.u_lsu.squash_id_i;
            if (dut.banked_independent_valid_q != 4'b0000)
                fail("redirected LSU output packet was not discarded");
            if (!dut.u_exec.g_3p.u_exec.u_lsu.u_lsq.empty_o)
                fail("redirected LSU packet escaped into the LSQ");

            // Retirement is independently held on the live redirect edge.
            // Do not clock this synthetic redirect: Tomasulo recovery requires
            // a real rename checkpoint, which this local boundary probe does
            // not construct.
            force dut.queue_retire_valid = 3'b001;
            squash = 1'b1;
            #1;
            if ((dut.queue_retire_accept != 3'b000) ||
                (retire_arch != 3'b000))
                fail("retirement was not frozen on redirect edge");
            squash = 1'b0;
            release dut.queue_retire_valid;
            #1;
            tick();
        end

        // An accepted address can return while a redirect is being resolved.
        // Keep the older lane and its response, but discard the younger lane
        // and its response owner.  This directly seeds only the independent
        // register-load state so the test does not depend on selector timing.
        if ((ISSUE_WINDOW != 0) &&
            (RENAME_MODE == `OPENRV64_RENAME_IDENTITY)) begin
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

        // A bank-conflicted address phase remains a live ready/valid
        // transaction even if recovery kills its scheduler candidate.  Force
        // a retained request to gain its grant on the redirect edge.  The
        // requester must keep it presented through ack, poison the following
        // data phase, and hold issue drained until that response disappears.
        if ((ISSUE_WINDOW != 0) &&
            (RENAME_MODE == `OPENRV64_RENAME_TOMASULO)) begin
            dut.banked_independent_held_valid_q = 3'b001;
            dut.banked_independent_held_req_q = 6'b000001;
            dut.banked_independent_held_addr_q =
                {6*PHYS_REG_ADDR_WIDTH{1'b0}};
            dut.banked_independent_held_addr_q[0 +:
                PHYS_REG_ADDR_WIDTH] = PHYS_REG_ADDR_WIDTH'(4);
            dut.banked_independent_held_pipe_q = 6'b000000;
            dut.banked_independent_held_id_q =
                {3*`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            dut.banked_independent_held_id_q[0 +:
                `OPENRV64_INSTR_ID_WIDTH] = 10'd84;
            flush = 1'b1;
            #1;
            if (!dut.gpr_read_req[0] || !dut.gpr_read_ack[0])
                fail("redirect-edge held read did not remain through ack");
            tick();
            flush = 1'b0;
            if (dut.banked_independent_held_valid_q[0] ||
                !dut.banked_independent_response_poison_q[0] ||
                !dut.gpr_read_valid[0])
                fail("redirect-edge held read did not become poison response");
            tick();
            if (dut.banked_independent_response_poison_q[0] ||
                dut.gpr_read_valid[0])
                fail("redirect-edge poison response did not drain");
            tick();
            if (dut.banked_gpr_drain_q || !dut.gpr_quiescent)
                fail("redirect-edge held read did not restore quiescence");
            tick();
        end

        // Put four same-bank operands behind the two-slot bank interface.
        // Redirect while the first two accepted reads are returning and the
        // oversubscribed reads are still presented.  The latter must remain
        // stable through ack; all delayed responses are poisoned and must not
        // allocate work.
        if ((ISSUE_WINDOW == 0) && (RENAME_MODE == 0)) begin
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
        if (!(|dut.u_gpr.g_banked.u_reg_file.read_grant)) begin
            $display("redirect grant state rename=%0d alloc=%b req=%b ack=%b addr=%h pending=%b drain=%b quiescent=%b free=%0d",
                     RENAME_MODE, dut.allocation_valid,
                     dut.gpr_read_req[3:0], dut.gpr_read_ack[3:0],
                     dut.gpr_read_addr[4*PHYS_REG_ADDR_WIDTH-1:0],
                     dut.banked_read_pending_q, dut.banked_gpr_drain_q,
                     dut.gpr_quiescent,
                     observed_rename_free_count);
            fail("redirect probe never obtained a GPR read grant");
        end

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
        if ((ISSUE_WINDOW == 0) && (RENAME_MODE == 0) &&
            !saw_read_bank_retry)
            fail("test never exercised a read-bank retry");
        if ((RENAME_MODE == 0) && !saw_write_bank_retry)
            fail("test never exercised a sliding same-bank write pair");
        if ((RENAME_MODE == `OPENRV64_RENAME_IDENTITY) &&
            !saw_dependency_wait)
            fail("test never observed conservative dependency waiting");
        if ((ISSUE_WINDOW == 0) && (RENAME_MODE == 0) &&
            !saw_exu_forward_while_busy)
            fail("test never consumed an EXU completion before retirement");
        if ((ISSUE_WINDOW == 0) && (RENAME_MODE == 0) &&
            !saw_write_ack_read_overlap)
            fail("test never overlapped a dependent read with write ack");
        if (!saw_regload_address_issue_overlap)
            fail("test never overlapped register address and issue phases");
        if (!saw_back_to_back_issue)
            fail("test never issued in back-to-back cycles");
        if ((RENAME_MODE != 0) &&
            (!saw_nonidentity_phys || !saw_physical_free))
            fail("renamed stream did not allocate and free physical tags");
        if ((RENAME_MODE != 0) &&
            (observed_rename_free_count != 32))
            fail("renamed stream did not restore free-tag conservation");
        if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
            !saw_scheduler_release_before_retire)
            fail("scheduler entries were not released before ROB retirement");
        if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
            !saw_scheduler_slot_reuse_before_retire)
            fail("scheduler slot was not reused before prior ROB retirement");
        if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
            !saw_alu2_issue)
            fail("renamed stream never issued an enabled operation on ALU2");
        if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
            (ENABLE_ALU_CHAINING == 0) &&
            !saw_alu2_zbb_rotate)
            fail("renamed stream never routed a Zbb rotate to ALU2");
        if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
            !saw_alu2_forward)
            fail("ALU2 never drove the MEM0 forwarding path");
        if (!saw_ex1_auipc || !saw_ex1_slt || !saw_ex1_sltu)
            fail("instruction stream missed EX1-only AUIPC/compare issue");

        // Without chaining, keep the producer resident on its completion port
        // by denying the PRF write and prove ordinary completion forwarding.
        // With chaining, leave completion flow unstalled: the scheduler must
        // release the dependent in the producer's issue cycle and EX must
        // consume the retained result in the following cycle.  A forced PRF
        // stall would also occupy EX's only output slot and is therefore an
        // unrelated structural block on the chained instruction itself.
        if (RENAME_MODE == `OPENRV64_RENAME_TOMASULO) begin
            memory_probe_active = 1'b1;
            memory_probe_retired = 0;
            memory_probe_last_rd = 5'd0;
            memory_probe_last_wdata = 64'd0;
            tomasulo_forward_probe_active = 1'b1;
            saw_tomasulo_alu_forward_accept = 1'b0;
            saw_tomasulo_alu_forward_without_writeback = 1'b0;
            saw_tomasulo_alu_chain_issue = 1'b0;
            forward_producer_issue_cycle = -1;
            if (ENABLE_ALU_CHAINING == 0)
                force dut.gpr_write_ack = 3'b000;

            decode_payload = {3*IW{1'b0}};
            decode_payload[0 +: IW] =
                addi_packet(60, 0, 27, 64'd41, 1'b0);
            decode_payload[IW +: IW] =
                addi_packet(61, 27, 28, 64'd1, 1'b0);
            decode_uses_rs1 = 3'b011;
            decode_uses_rs2 = 3'b000;
            decode_valid = 3'b011;
            while (decode_ready[1:0] != 2'b11)
                tick();
            tick();
            decode_valid = 3'b000;
            decode_payload = {3*IW{1'b0}};
            decode_uses_rs1 = 3'b000;

            for (cycles = 0;
                 (cycles < 30) &&
                 (!saw_tomasulo_alu_forward_accept ||
                  ((ENABLE_ALU_CHAINING != 0) &&
                   !saw_tomasulo_alu_chain_issue));
                 cycles = cycles + 1)
                tick();
            if (!saw_tomasulo_alu_forward_accept)
                fail("dependent ALU was not accepted from live completion");
            if (!saw_tomasulo_alu_forward_without_writeback)
                fail("dependent ALU waited for physical writeback ack");
            if ((ENABLE_ALU_CHAINING != 0) &&
                !saw_tomasulo_alu_chain_issue)
                fail("dependent ALU did not issue through retained chain");

            if (ENABLE_ALU_CHAINING == 0)
                release dut.gpr_write_ack;
            for (cycles = 0;
                 (cycles < 100) &&
                 ((memory_probe_retired < 2) ||
                  (dispatch_occupancy != 0) ||
                  (retire_occupancy != 0));
                 cycles = cycles + 1)
                tick();
            repeat (2) tick();
            if ((memory_probe_retired != 2) ||
                (memory_probe_last_rd != 5'd28) ||
                (memory_probe_last_wdata != 64'd42)) begin
                $display({"ALU forward retirement retired=%0d rd=%0d ",
                          "data=%h dispatch=%0d retire=%0d free=%0d"},
                         memory_probe_retired, memory_probe_last_rd,
                         memory_probe_last_wdata, dispatch_occupancy,
                         retire_occupancy, observed_rename_free_count);
                fail("forwarded ALU dependency retired wrong result");
            end
            if ((dispatch_occupancy != 0) || (retire_occupancy != 0) ||
                (observed_rename_free_count != 32))
                fail("ALU forwarding probe did not drain cleanly");
            tomasulo_forward_probe_active = 1'b0;
            memory_probe_active = 1'b0;
            memory_probe_retired = 0;
        end

        // Schedule a load behind a one-cycle ALU producer.  This checks the
        // promised timing directly: scheduler release in producer cycle N and
        // LSU acceptance with the selected result in cycle N+1.
        if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
            (ENABLE_ALU_CHAINING != 0)) begin
            memory_probe_active = 1'b1;
            memory_probe_retired = 0;
            memory_probe_last_rd = 5'd0;
            memory_probe_last_wdata = 64'd0;
            tomasulo_exu_mem_chain_probe_active = 1'b1;
            saw_tomasulo_exu_mem_chain_accept = 1'b0;
            saw_tomasulo_exu_mem_chain_issue = 1'b0;
            exu_mem_producer_issue_cycle = -1;
            exu_mem_producer_lane = -1;
            exu_mem_accept_cycle = -1;
            exu_mem_issue_cycle = -1;

            decode_payload = {3*IW{1'b0}};
            decode_payload[0 +: IW] =
                addi_packet(62, 0, 27, 64'h180, 1'b0);
            decode_payload[IW +: IW] =
                load_packet(63, 27, 28, 64'd0);
            decode_uses_rs1 = 3'b011;
            decode_uses_rs2 = 3'b000;
            decode_valid = 3'b011;
            while (decode_ready[1:0] != 2'b11)
                tick();
            tick();
            decode_valid = 3'b000;
            decode_payload = {3*IW{1'b0}};
            decode_uses_rs1 = 3'b000;

            for (cycles = 0;
                 (cycles < 30) &&
                 (!saw_tomasulo_exu_mem_chain_accept ||
                  !saw_tomasulo_exu_mem_chain_issue);
                 cycles = cycles + 1)
                tick();
            if (!saw_tomasulo_exu_mem_chain_accept)
                fail("EXU-to-LSU load was not released with its producer");
            if (!saw_tomasulo_exu_mem_chain_issue)
                fail("EXU-to-LSU load did not issue from selected result");
            if ((exu_mem_accept_cycle != exu_mem_producer_issue_cycle) ||
                (exu_mem_issue_cycle != exu_mem_producer_issue_cycle + 1))
                fail("EXU-to-LSU cycle contract was not N then N+1");

            for (cycles = 0; (cycles < 40) && !mem_valid;
                 cycles = cycles + 1)
                tick();
            if (!mem_valid || !mem_physical || (mem_addr != 64'h180))
                fail("EXU-forwarded load launched the wrong address");
            probe_load_tag = mem_tag;
            mem_ready = 1'b1;
            tick();
            mem_ready = 1'b0;

            mem_resp_tag = probe_load_tag;
            mem_rdata = 64'hfeed_face_cafe_1234;
            mem_resp_valid = 1'b1;
            for (cycles = 0; (cycles < 20) && !mem_resp_ready;
                 cycles = cycles + 1)
                tick();
            if (!mem_resp_ready)
                fail("EXU-forwarded load response was not accepted");
            tick();
            mem_resp_valid = 1'b0;

            for (cycles = 0;
                 (cycles < 100) &&
                 ((memory_probe_retired < 2) ||
                  (dispatch_occupancy != 0) ||
                  (retire_occupancy != 0));
                 cycles = cycles + 1)
                tick();
            repeat (2) tick();
            if ((memory_probe_retired != 2) ||
                (memory_probe_last_rd != 5'd28) ||
                (memory_probe_last_wdata != 64'hfeed_face_cafe_1234))
                fail("EXU-forwarded load retired the wrong result");
            if ((dispatch_occupancy != 0) || (retire_occupancy != 0) ||
                (observed_rename_free_count != 32))
                fail("EXU-to-LSU forwarding probe did not drain cleanly");
            $display(
                "EXU_MEM_CHAIN_CYCLES producer=%0d scheduler=%0d lsu=%0d",
                exu_mem_producer_issue_cycle, exu_mem_accept_cycle,
                exu_mem_issue_cycle);
            tomasulo_exu_mem_chain_probe_active = 1'b0;
            memory_probe_active = 1'b0;
            memory_probe_retired = 0;
        end

        // AUIPC and JALR remain separate dynamic instructions.  Pinning
        // AUIPC to EX1 lets the scheduler release the dependent JALR in the
        // producer's issue cycle N; EX1 must consume that exact retained
        // result and resolve the target in N+1.  Predicted-taken avoids an
        // unrelated direction-recovery event in this backend-only probe.
        if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
            (ENABLE_ALU_CHAINING != 0) &&
            (SPECULATION_WINDOW != 0)) begin
            memory_probe_active = 1'b1;
            memory_probe_retired = 0;
            memory_probe_last_rd = 5'd0;
            memory_probe_last_wdata = 64'd0;
            tomasulo_control_chain_probe_active = 1'b1;
            saw_tomasulo_control_chain_accept = 1'b0;
            saw_tomasulo_control_chain_issue = 1'b0;
            control_chain_producer_issue_cycle = -1;
            control_chain_accept_cycle = -1;
            control_chain_issue_cycle = -1;

            decode_payload = {3*IW{1'b0}};
            decode_payload[0 +: IW] =
                upper_packet(64, 27, 64'h2000, 1'b1);
            decode_payload[IW +: IW] =
                jalr_packet(65, 27, 0, 64'd0);
            decode_uses_rs1 = 3'b010;
            decode_uses_rs2 = 3'b000;
            decode_valid = 3'b011;
            while (decode_ready[1:0] != 2'b11)
                tick();
            tick();
            decode_valid = 3'b000;
            decode_payload = {3*IW{1'b0}};
            decode_uses_rs1 = 3'b000;

            for (cycles = 0;
                 (cycles < 30) &&
                 (!saw_tomasulo_control_chain_accept ||
                  !saw_tomasulo_control_chain_issue);
                 cycles = cycles + 1)
                tick();
            if (!saw_tomasulo_control_chain_accept)
                fail("AUIPC-to-JALR was not released with its producer");
            if (!saw_tomasulo_control_chain_issue)
                fail("JALR did not issue from the retained AUIPC result");
            if ((control_chain_accept_cycle !=
                 control_chain_producer_issue_cycle) ||
                (control_chain_issue_cycle !=
                 control_chain_producer_issue_cycle + 1))
                fail("AUIPC-to-JALR cycle contract was not N then N+1");

            for (cycles = 0;
                 (cycles < 100) &&
                 ((memory_probe_retired < 2) ||
                  (dispatch_occupancy != 0) ||
                  (retire_occupancy != 0));
                 cycles = cycles + 1)
                tick();
            repeat (2) tick();
            if (memory_probe_retired != 2)
                fail("AUIPC-to-JALR chain did not retire both packets");
            if ((dispatch_occupancy != 0) || (retire_occupancy != 0) ||
                (observed_rename_free_count != 32))
                fail("AUIPC-to-JALR chain did not drain cleanly");
            $display(
                "CONTROL_CHAIN_CYCLES producer=%0d scheduler=%0d ex1=%0d",
                control_chain_producer_issue_cycle,
                control_chain_accept_cycle, control_chain_issue_cycle);
            tomasulo_control_chain_probe_active = 1'b0;
            memory_probe_active = 1'b0;
            memory_probe_retired = 0;
        end

        if (CHAIN_PROBE_ONLY != 0) begin
            if (ENABLE_ALU_CHAINING == 0)
                fail("chain-only probe requires ALU chaining");
            $display({"PASS: banked backend ALU, LSU, and control chains ",
                      "released dependents in producer issue cycle N and ",
                      "consumed the selected result in N+1"});
            $display("PASS: banked 3p issue window processed post-selection register loads, ordered arithmetic, load/use, and held bank retries");
            $finish;
        end

        // Isolate the steering probe from the throughput/conflict coverage
        // above.  The normal ready signal is payload-qualified, so force only
        // the new structural-capacity sideband: EX0 unavailable, EX1 free.
        // Execution's real ready/valid handshake still checks and accepts the
        // retargeted packet.
        if ((ISSUE_WINDOW == 0) && (RENAME_MODE == 0)) begin
        memory_probe_active = 1'b1;
        memory_probe_retired = 0;
        memory_probe_last_rd = 5'd0;
        memory_probe_last_wdata = 64'd0;
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
            (memory_probe_last_rd != 5'd29) ||
            (memory_probe_last_wdata != 64'd42) ||
            ((RENAME_MODE == 0) && (dut.u_gpr.regs[29] !== 64'd42)))
            fail("retargeted base ALU did not retire the correct result");
        memory_probe_active = 1'b0;
        memory_probe_retired = 0;
        end

        // A returned load occupies MEM0's completion lane.  Keep its direct
        // consumer waiting on x27 until the tagged response arrives; the
        // registered forwarding stage must supply it before retirement writes
        // x27.
        memory_probe_active = 1'b1;
        memory_probe_retired = 0;
        memory_probe_last_rd = 5'd0;
        memory_probe_last_wdata = 64'd0;
        if (RENAME_MODE == `OPENRV64_RENAME_TOMASULO) begin
            tomasulo_load_forward_probe_active = 1'b1;
            saw_tomasulo_load_forward_accept = 1'b0;
            saw_tomasulo_load_forward_without_writeback = 1'b0;
            load_completion_cycle = -1;
        end
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
        if (RENAME_MODE == `OPENRV64_RENAME_TOMASULO)
            force dut.gpr_write_ack = 3'b000;
        mem_resp_valid = 1'b1;
        for (cycles = 0; (cycles < 20) && !mem_resp_ready;
             cycles = cycles + 1)
            tick();
        if (!mem_resp_ready)
            fail("MEM0 forwarding probe response was not accepted");
        tick();
        mem_resp_valid = 1'b0;

        if (RENAME_MODE == `OPENRV64_RENAME_TOMASULO) begin
            for (cycles = 0;
                 (cycles < 20) && !saw_tomasulo_load_forward_accept;
                 cycles = cycles + 1)
                tick();
            if (!saw_tomasulo_load_forward_accept)
                fail("dependent ALU was not accepted from load completion");
            if (!saw_tomasulo_load_forward_without_writeback)
                fail("load dependent waited for physical writeback ack");
            release dut.gpr_write_ack;
        end

        for (cycles = 0;
             (cycles < 100) && ((memory_probe_retired < 2) ||
                                (dispatch_occupancy != 0) ||
                                (retire_occupancy != 0));
             cycles = cycles + 1)
            tick();
        repeat (2) tick();
        if (memory_probe_retired != 2)
            fail("MEM0 forwarding probe did not retire both instructions");
        if ((ISSUE_WINDOW == 0) && (RENAME_MODE == 0) &&
            !saw_mem_forward_while_busy)
            fail("load result was not consumed from MEM0 completion");
        if ((memory_probe_last_rd != 5'd28) ||
            (memory_probe_last_wdata != 64'h1122_3344_5566_7789))
            fail("load consumer retired an incorrect renamed result");
        if ((dispatch_occupancy != 0) || (retire_occupancy != 0) ||
            (write_busy != 0))
            fail("MEM0 forwarding probe did not drain cleanly");
        tomasulo_load_forward_probe_active = 1'b0;
        memory_probe_active = 1'b0;

        // Tomasulo JALR is a recoverable speculative cut, not a retirement
        // barrier.  Keep an older load incomplete, then require the JALR to
        // resolve before the ROB head and a younger independent ALU packet to
        // enter execution.  A predicted-taken packet avoids manufacturing a
        // direction redirect in this backend-only test.
        if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
            (SPECULATION_WINDOW != 0)) begin
            memory_probe_active = 1'b1;
            memory_probe_retired = 0;
            memory_probe_last_rd = 5'd0;
            memory_probe_last_wdata = 64'd0;
            saw_jalr_resolve_before_head = 1'b0;
            saw_jalr_younger_issue = 1'b0;
            saw_jalr_resolve = 1'b0;

            decode_payload = {3*IW{1'b0}};
            decode_payload[0 +: IW] =
                load_packet(40, 0, 30, 64'h180);
            decode_payload[IW +: IW] =
                jalr_packet(41, 0, 31, 64'h200);
            decode_payload[2*IW +: IW] =
                addi_packet(42, 0, 29, 64'd99, 1'b0);
            decode_uses_rs1 = 3'b111;
            decode_uses_rs2 = 3'b000;
            decode_valid = 3'b111;
            while (decode_ready != 3'b111)
                tick();
            tick();
            decode_valid = 3'b000;
            decode_payload = {3*IW{1'b0}};
            decode_uses_rs1 = 3'b000;

            for (cycles = 0;
                 (cycles < 80) &&
                 (!mem_valid || !saw_jalr_resolve ||
                  !saw_jalr_younger_issue);
                 cycles = cycles + 1)
                tick();
            if (!mem_valid || !mem_physical || (mem_addr != 64'h180))
                fail("JALR speculation probe did not hold its older load");
            if (!saw_jalr_resolve)
                fail("JALR speculation probe never resolved the JALR");
            if (!saw_jalr_resolve_before_head)
                fail("JALR did not resolve before the older ROB head");
            if (!saw_jalr_younger_issue)
                fail("younger ALU work did not execute across unresolved JALR");

            probe_load_tag = mem_tag;
            mem_ready = 1'b1;
            tick();
            mem_ready = 1'b0;
            mem_resp_tag = probe_load_tag;
            mem_rdata = 64'h55;
            mem_resp_valid = 1'b1;
            for (cycles = 0; (cycles < 20) && !mem_resp_ready;
                 cycles = cycles + 1)
                tick();
            if (!mem_resp_ready)
                fail("JALR speculation probe load response was not accepted");
            tick();
            mem_resp_valid = 1'b0;

            for (cycles = 0;
                 (cycles < 100) &&
                 ((memory_probe_retired < 3) ||
                  (dispatch_occupancy != 0) ||
                  (retire_occupancy != 0));
                 cycles = cycles + 1)
                tick();
            repeat (2) tick();
            if (memory_probe_retired != 3)
                fail("JALR speculation probe did not retire all packets");
            if ((memory_probe_last_rd != 5'd29) ||
                (memory_probe_last_wdata != 64'd99))
                fail("JALR speculation probe retired incorrect younger data");
            if ((dispatch_occupancy != 0) || (retire_occupancy != 0) ||
                (write_busy != 0) || barrier_active)
                fail("JALR speculation probe did not drain cleanly");
            memory_probe_active = 1'b0;
        end

        // A predicted-not-taken JALR may leave a cacheable wrong-path load
        // in flight while the JALR waits on an older load for its target.
        // Recovery must kill the younger LSQ owner, accept its eventual bus
        // error, and retire neither the error nor the wrong-path load.  This
        // is the backend form of an M-mode RET falling through into adjacent
        // code before its restored return address becomes available.
        if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
            (SPECULATION_WINDOW != 0)) begin
            memory_probe_active = 1'b1;
            memory_replay_probe_active = 1'b1;
            saw_memory_replay_store_sideband = 1'b0;
            memory_probe_retired = 0;
            memory_probe_last_rd = 5'd0;
            memory_probe_last_wdata = 64'd0;

            decode_payload = {3*IW{1'b0}};
            decode_payload[0 +: IW] =
                load_packet(43, 0, 31, 64'h180);
            decode_payload[IW +: IW] =
                jalr_packet(44, 31, 0, 64'd0);
            decode_payload[IW + I_PREDICTED] = 1'b0;
            decode_payload[2*IW +: IW] =
                load_packet(45, 0, 28, 64'h300);
            decode_uses_rs1 = 3'b111;
            decode_uses_rs2 = 3'b000;
            decode_valid = 3'b111;
            while (decode_ready != 3'b111)
                tick();
            tick();
            decode_valid = 3'b000;
            decode_payload = {3*IW{1'b0}};
            decode_uses_rs1 = 3'b000;

            for (cycles = 0; (cycles < 80) && !mem_valid;
                 cycles = cycles + 1)
                tick();
            if (!mem_valid || !mem_physical || mem_write ||
                (mem_addr != 64'h180))
                fail("JALR recovery probe did not launch target load");
            jalr_head_load_tag = mem_tag;
            mem_ready = 1'b1;
            tick();
            mem_ready = 1'b0;

            for (cycles = 0;
                 (cycles < 80) && !mem_valid && !redirect_valid;
                 cycles = cycles + 1)
                tick();
            if (redirect_valid)
                fail("JALR resolved before younger wrong-path load issued");
            if (!mem_valid || !mem_physical || mem_write ||
                (mem_addr != 64'h300))
                fail("cacheable load did not speculate past blocked JALR");
            jalr_wrong_load_tag = mem_tag;
            mem_ready = 1'b1;
            tick();
            mem_ready = 1'b0;

            mem_resp_tag = jalr_head_load_tag;
            mem_rdata = 64'h200;
            mem_resp_valid = 1'b1;
            while (!mem_resp_ready)
                tick();
            tick();
            mem_resp_valid = 1'b0;

            for (cycles = 0; (cycles < 80) && !redirect_valid;
                 cycles = cycles + 1)
                tick();
            if (!redirect_valid || (redirect_target != 64'h200))
                fail("predicted-not-taken JALR did not redirect");
            squash = 1'b1;
            tick();
            squash = 1'b0;

            mem_resp_tag = jalr_wrong_load_tag;
            mem_rdata = 64'd0;
            mem_resp_error = 1'b1;
            mem_resp_valid = 1'b1;
            for (cycles = 0; (cycles < 40) && !mem_resp_ready;
                 cycles = cycles + 1)
                tick();
            if (!mem_resp_ready)
                fail("squashed wrong-path load did not drain bus error");
            tick();
            mem_resp_valid = 1'b0;
            mem_resp_error = 1'b0;

            for (cycles = 0;
                 (cycles < 120) &&
                 ((memory_probe_retired < 2) ||
                  (dispatch_occupancy != 0) ||
                  (retire_occupancy != 0));
                 cycles = cycles + 1)
                tick();
            repeat (2) tick();
            if (memory_probe_retired != 2)
                fail("wrong-path load or error reached retirement");
            if ((dispatch_occupancy != 0) || (retire_occupancy != 0) ||
                (write_busy != 0) || barrier_active)
                fail("JALR wrong-path load recovery did not drain cleanly");
            memory_replay_probe_active = 1'b0;
            memory_probe_active = 1'b0;
        end

        // Let a younger load pass an older store whose address is still
        // waiting on an outstanding load.  The younger load deliberately
        // consumes stale data.  When the store's base wakes and translation
        // resolves to the same physical 8-byte granule, selective recovery
        // must preserve the store and independent ALU work between it and the
        // violating load, discard that load and its executed dependent, and
        // redirect to the load itself.
        if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
            (SPECULATION_WINDOW != 0)) begin
            memory_probe_active = 1'b1;
            memory_replay_probe_active = 1'b1;
            saw_memory_replay_store_sideband = 1'b0;
            memory_probe_retired = 0;
            memory_probe_last_rd = 5'd0;
            memory_probe_last_wdata = 64'd0;
            replay_watch_count_before = dut.perf_memory_load_watches_q;
            replay_check_count_before =
                dut.perf_memory_store_address_checks_q;
            replay_violation_count_before =
                dut.perf_memory_store_violations_q;
            replay_count_before = dut.perf_memory_replays_q;

            decode_payload = {3*IW{1'b0}};
            decode_payload[0 +: IW] =
                load_packet(70, 0, 27, 64'h280);
            decode_payload[IW +: IW] =
                store_packet(71, 27, 0, 64'h0);
            decode_payload[2*IW +: IW] =
                addi_packet(72, 0, 29, 64'd99, 1'b0);
            decode_uses_rs1 = 3'b111;
            decode_uses_rs2 = 3'b010;
            decode_valid = 3'b111;
            while (decode_ready != 3'b111)
                tick();
            tick();
            decode_valid = 3'b000;
            decode_payload = {3*IW{1'b0}};
            decode_uses_rs1 = 3'b000;
            decode_uses_rs2 = 3'b000;

            for (cycles = 0; (cycles < 40) && !mem_valid;
                 cycles = cycles + 1)
                tick();
            if (!mem_valid || mem_write || !mem_physical ||
                (mem_addr != 64'h280))
                fail("replay probe did not launch its oldest load first");
            replay_head_load_tag = mem_tag;
            mem_ready = 1'b1;
            tick();
            mem_ready = 1'b0;

            // The return-driven policy is intentionally narrower than a
            // global load stop: it only restores the unresolved-store guard.
            inhibit_load_speculation = 1'b1;
            repeat (2) begin
                #1;
                if (mem_valid)
                    fail("load passed unresolved store while inhibited");
                tick();
            end
            inhibit_load_speculation = 1'b0;

            decode_payload[0 +: IW] =
                load_packet(73, 0, 28, 64'h200);
            decode_payload[IW +: IW] =
                addi_packet(74, 28, 30, 64'd1, 1'b0);
            decode_uses_rs1 = 3'b011;
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
            if (!mem_valid || mem_write || !mem_physical ||
                (mem_addr != 64'h200)) begin
                $display({"memory replay bypass valid=%b write=%b addr=%h ",
                          "dispatch=%0d retire=%0d issue=%b"},
                         mem_valid, mem_write, mem_addr,
                         dispatch_occupancy, retire_occupancy, issue_valid);
                fail("younger load did not pass the address-blocked store");
            end
            replay_wrong_load_tag = mem_tag;
            mem_ready = 1'b1;
            tick();
            mem_ready = 1'b0;

            mem_resp_tag = replay_wrong_load_tag;
            mem_rdata = 64'h1111_1111_1111_1111;
            mem_resp_valid = 1'b1;
            for (cycles = 0; (cycles < 20) && !mem_resp_ready;
                 cycles = cycles + 1)
                tick();
            if (!mem_resp_ready)
                fail("speculative stale load response was not accepted");
            tick();
            mem_resp_valid = 1'b0;
            // Give the stale load value time to wake and execute its younger
            // dependent before the older store reveals the violation.
            repeat (2) tick();

            // Supplying the older producer wakes the store's address operand.
            // Its now-successful translation must find the retained younger
            // physical-load watch and request selective replay.
            mem_resp_tag = replay_head_load_tag;
            mem_rdata = 64'h200;
            mem_resp_valid = 1'b1;
            for (cycles = 0; (cycles < 20) && !mem_resp_ready;
                 cycles = cycles + 1)
                tick();
            if (!mem_resp_ready)
                fail("replay probe head-load response was not accepted");
            tick();
            mem_resp_valid = 1'b0;

            for (cycles = 0; (cycles < 60) && !redirect_valid;
                 cycles = cycles + 1)
                tick();
            if (!redirect_valid)
                fail("physical store/load collision did not request replay");
            if (redirect_target != (64'h1000 + (64'd73 << 2))) begin
                $display("memory replay id=%0d target=%h",
                         redirect_id, redirect_target);
                fail("memory collision replay did not target the violating load");
            end
            if ((dut.perf_memory_store_address_checks_q !=
                 replay_check_count_before + 1'b1) ||
                (dut.perf_memory_store_violations_q !=
                 replay_violation_count_before + 1'b1))
                fail("memory replay event counters did not classify collision");

            squash = 1'b1;
            tick();
            squash = 1'b0;

            for (cycles = 0; (cycles < 60) && !mem_valid;
                 cycles = cycles + 1)
                tick();
            if (!mem_valid || !mem_write || !mem_physical ||
                (mem_addr != 64'h200))
                fail("selective replay did not preserve the older store");
            replay_store_tag = mem_tag;
            mem_ready = 1'b1;
            #1;
            if (!(saw_memory_replay_store_sideband ||
                  (dut.posted_store_complete_valid &&
                   dut.posted_store_complete_accept))) begin
                $display({"store sideband state valid=%b accept=%b ",
                          "id=%0d slot=%0d head_id=%0d head_slot=%0d ",
                          "full_complete=%b"},
                         dut.posted_store_complete_valid,
                         dut.posted_store_complete_accept,
                         dut.posted_store_complete_id,
                         dut.posted_store_complete_slot,
                         dut.ordered_head_id, dut.ordered_head_slot,
                         dut.completion_fire);
                fail("replay store missed ROB identity completion");
            end
            tick();
            mem_ready = 1'b0;

            mem_store_done_tag = replay_store_tag;
            mem_store_done_valid = 1'b1;
            for (cycles = 0; (cycles < 20) && !mem_store_done_ready;
                 cycles = cycles + 1)
                tick();
            if (!mem_store_done_ready)
                fail("replay probe store-done tag was not accepted");
            tick();
            mem_store_done_valid = 1'b0;

            // Model the refetch at the violating load and return the value
            // written by the preserved store.  The original stale physical
            // destination must not be architecturally visible.
            decode_payload = {3*IW{1'b0}};
            decode_payload[0 +: IW] =
                load_packet(73, 0, 28, 64'h200);
            decode_payload[IW +: IW] =
                addi_packet(74, 28, 30, 64'd1, 1'b0);
            decode_uses_rs1 = 3'b011;
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
            if (!mem_valid || mem_write || (mem_addr != 64'h200))
                fail("replayed load did not relaunch after the store");
            probe_load_tag = mem_tag;
            mem_ready = 1'b1;
            tick();
            mem_ready = 1'b0;
            mem_resp_tag = probe_load_tag;
            mem_rdata = 64'h0;
            mem_resp_valid = 1'b1;
            for (cycles = 0; (cycles < 20) && !mem_resp_ready;
                 cycles = cycles + 1)
                tick();
            if (!mem_resp_ready)
                fail("replayed load response was not accepted");
            tick();
            mem_resp_valid = 1'b0;

            for (cycles = 0;
                 (cycles < 120) &&
                 ((memory_probe_retired < 5) ||
                  (dispatch_occupancy != 0) ||
                  (retire_occupancy != 0));
                 cycles = cycles + 1)
                tick();
            repeat (2) tick();
            if ((memory_probe_retired != 5) ||
                (memory_probe_last_rd != 5'd30) ||
                (memory_probe_last_wdata != 64'h1))
                fail("memory replay retired stale or incomplete state");
            if (dut.perf_memory_replays_q != replay_count_before + 1'b1)
                fail("memory replay counter did not record redirect");
            if (dut.perf_memory_load_watches_q <
                replay_watch_count_before + 3)
                fail("memory replay did not retain all physical load accesses");
            if ((dut.perf_memory_replay_preserved_entries_q != 1) ||
                (dut.perf_memory_replay_distance_2_q != 1))
                fail("memory replay did not preserve the store-to-load gap");
            if ((dispatch_occupancy != 0) || (retire_occupancy != 0) ||
                (write_busy != 0) || barrier_active)
                fail("memory replay probe did not drain cleanly");
            memory_replay_probe_active = 1'b0;
            memory_probe_active = 1'b0;
        end

        // The same recovery contract must cover an address-blocked store
        // later found to be misaligned.  Its component engine reports each
        // accepted physical 8-byte granule; the component overlapping the
        // speculative load must cause exactly one replay.
        if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
            (SPECULATION_WINDOW != 0)) begin
            memory_probe_active = 1'b1;
            memory_replay_probe_active = 1'b1;
            memory_probe_retired = 0;
            memory_probe_last_rd = 5'd0;
            memory_probe_last_wdata = 64'd0;
            replay_store_component_count = 0;
            replay_watch_count_before = dut.perf_memory_load_watches_q;
            replay_check_count_before =
                dut.perf_memory_store_address_checks_q;
            replay_violation_count_before =
                dut.perf_memory_store_violations_q;
            replay_count_before = dut.perf_memory_replays_q;

            decode_payload = {3*IW{1'b0}};
            decode_payload[0 +: IW] =
                load_packet(73, 0, 27, 64'h300);
            decode_payload[IW +: IW] =
                store_packet(74, 27, 0, 64'h0);
            decode_payload[2*IW +: IW] =
                load_packet(75, 0, 28, 64'h208);
            decode_uses_rs1 = 3'b111;
            decode_uses_rs2 = 3'b010;
            decode_valid = 3'b111;
            while (decode_ready != 3'b111)
                tick();
            tick();
            decode_valid = 3'b000;
            decode_payload = {3*IW{1'b0}};
            decode_uses_rs1 = 3'b000;
            decode_uses_rs2 = 3'b000;

            for (cycles = 0; (cycles < 40) && !mem_valid;
                 cycles = cycles + 1)
                tick();
            if (!mem_valid || mem_write || (mem_addr != 64'h300))
                fail("misaligned replay probe did not launch base load");
            replay_head_load_tag = mem_tag;
            mem_ready = 1'b1;
            tick();
            mem_ready = 1'b0;

            for (cycles = 0; (cycles < 40) && !mem_valid;
                 cycles = cycles + 1)
                tick();
            if (!mem_valid || mem_write || (mem_addr != 64'h208))
                fail("load did not pass address-unknown misaligned store");
            replay_wrong_load_tag = mem_tag;
            mem_ready = 1'b1;
            tick();
            mem_ready = 1'b0;

            mem_resp_tag = replay_wrong_load_tag;
            mem_rdata = 64'h5555_5555_5555_5555;
            mem_resp_valid = 1'b1;
            while (!mem_resp_ready)
                tick();
            tick();
            mem_resp_valid = 1'b0;

            // Wake the store base with a deliberately misaligned address.
            mem_resp_tag = replay_head_load_tag;
            mem_rdata = 64'h203;
            mem_resp_valid = 1'b1;
            while (!mem_resp_ready)
                tick();
            tick();
            mem_resp_valid = 1'b0;

            // SD at 0x203 decomposes into 1B@203, 4B@204, 2B@208,
            // and 1B@20a.  The third component first overlaps the watched
            // 0x208 load granule.
            for (replay_store_component_count = 0;
                 replay_store_component_count < 4;
                 replay_store_component_count =
                    replay_store_component_count + 1) begin
                for (cycles = 0; (cycles < 80) && !mem_valid;
                     cycles = cycles + 1)
                    tick();
                if (!mem_valid || !mem_write)
                    fail("misaligned replay store component did not launch");
                case (replay_store_component_count)
                    0: if (mem_addr != 64'h203)
                           fail("wrong first misaligned store component");
                    1: if (mem_addr != 64'h204)
                           fail("wrong second misaligned store component");
                    2: if (mem_addr != 64'h208)
                           fail("wrong third misaligned store component");
                    default: if (mem_addr != 64'h20a)
                           fail("wrong fourth misaligned store component");
                endcase
                replay_store_tag = mem_tag;
                mem_ready = 1'b1;
                tick();
                mem_ready = 1'b0;

                if (replay_store_component_count == 2) begin
                    if (!redirect_valid)
                        fail("misaligned physical collision did not replay");
                    if (redirect_target !=
                        (64'h1000 + (64'd75 << 2)))
                        fail("misaligned replay targeted wrong instruction");
                    squash = 1'b1;
                end else if (redirect_valid) begin
                    fail("nonoverlapping misaligned component replayed load");
                end

                mem_store_done_tag = replay_store_tag;
                mem_store_done_valid = 1'b1;
                while (!mem_store_done_ready)
                    tick();
                tick();
                mem_store_done_valid = 1'b0;
                squash = 1'b0;
            end

            if ((dut.perf_memory_store_address_checks_q !=
                replay_check_count_before + 4) ||
                (dut.perf_memory_store_violations_q !=
                 replay_violation_count_before + 1) ||
                (dut.perf_memory_replays_q != replay_count_before + 1)) begin
                $display({"misaligned replay counters checks=%0d->%0d ",
                          "violations=%0d->%0d replays=%0d->%0d"},
                         replay_check_count_before,
                         dut.perf_memory_store_address_checks_q,
                         replay_violation_count_before,
                         dut.perf_memory_store_violations_q,
                         replay_count_before,
                         dut.perf_memory_replays_q);
                fail("misaligned replay counters classified components wrong");
            end

            decode_payload = {3*IW{1'b0}};
            decode_payload[0 +: IW] =
                load_packet(75, 0, 28, 64'h208);
            decode_uses_rs1 = 3'b001;
            decode_valid = 3'b001;
            while (!decode_ready[0])
                tick();
            tick();
            decode_valid = 3'b000;
            decode_payload = {3*IW{1'b0}};
            decode_uses_rs1 = 3'b000;

            for (cycles = 0; (cycles < 40) && !mem_valid;
                 cycles = cycles + 1)
                tick();
            if (!mem_valid || mem_write || (mem_addr != 64'h208))
                fail("load did not relaunch after misaligned store replay");
            probe_load_tag = mem_tag;
            mem_ready = 1'b1;
            tick();
            mem_ready = 1'b0;
            mem_resp_tag = probe_load_tag;
            mem_rdata = 64'h0;
            mem_resp_valid = 1'b1;
            while (!mem_resp_ready)
                tick();
            tick();
            mem_resp_valid = 1'b0;

            for (cycles = 0;
                 (cycles < 160) &&
                 ((memory_probe_retired < 3) ||
                  (dispatch_occupancy != 0) ||
                  (retire_occupancy != 0));
                 cycles = cycles + 1)
                tick();
            repeat (2) tick();
            if ((memory_probe_retired != 3) ||
                (memory_probe_last_rd != 5'd28) ||
                (memory_probe_last_wdata != 64'h0))
                fail("misaligned replay retired stale state");
            if (dut.perf_memory_load_watches_q <
                replay_watch_count_before + 3)
                fail("misaligned replay lost physical load watches");
            if ((dispatch_occupancy != 0) || (retire_occupancy != 0) ||
                (write_busy != 0) || barrier_active)
                fail("misaligned replay probe did not drain cleanly");
            memory_replay_probe_active = 1'b0;
            memory_probe_active = 1'b0;
        end

        // Ordered-issue replay may bypass an older incomplete control to
        // break MEM-input age inversion.  If that control redirects in the
        // replay cycle, the replay is visible first and the older one-shot
        // redirect must be retained for the following cycle.
        if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
            (SPECULATION_WINDOW != 0)) begin
            memory_replay_probe_active = 1'b1;
            dut.memory_replay_pending_q = 1'b1;
            dut.memory_replay_ordered_issue_q = 1'b1;
            dut.memory_replay_id_q = `OPENRV64_INSTR_ID_WIDTH'(100);
            dut.memory_replay_slot_q = SLOT_WIDTH'(10);
            dut.memory_replay_target_q = 64'h0000_0000_0000_1900;
            force dut.exec_redirect_valid = 1'b1;
            force dut.exec_redirect_id =
                `OPENRV64_INSTR_ID_WIDTH'(90);
            force dut.exec_redirect_slot = SLOT_WIDTH'(9);
            force dut.exec_redirect_target = 64'h0000_0000_0000_1800;
            #1;
            if (!redirect_valid ||
                !dut.redirect_memory_replay_o ||
                !redirect_tagged_recovery ||
                (redirect_id != `OPENRV64_INSTR_ID_WIDTH'(100)) ||
                (redirect_target != 64'h0000_0000_0000_1900))
                fail("ordered replay did not own initial redirect cycle");
            squash = 1'b1;
            tick();
            squash = 1'b0;
            release dut.exec_redirect_valid;
            release dut.exec_redirect_id;
            release dut.exec_redirect_slot;
            release dut.exec_redirect_target;
            #1;
            if (!redirect_valid ||
                dut.redirect_memory_replay_o ||
                !redirect_tagged_recovery ||
                (redirect_id != `OPENRV64_INSTR_ID_WIDTH'(90)) ||
                (redirect_target != 64'h0000_0000_0000_1800) ||
                !dut.memory_replay_deferred_redirect_valid_q)
                fail("older EX redirect was lost behind ordered replay");
            // A younger ordered-input report can still be present while the
            // saved older cut is published.  It belongs to the discarded
            // suffix and must not seed another replay after this redirect.
            force dut.exec_ordered_issue_replay_valid = 1'b1;
            force dut.exec_ordered_issue_replay_id =
                `OPENRV64_INSTR_ID_WIDTH'(110);
            force dut.exec_ordered_issue_replay_slot = SLOT_WIDTH'(11);
            force dut.exec_ordered_issue_replay_pc =
                64'h0000_0000_0000_1a00;
            squash = 1'b1;
            tick();
            squash = 1'b0;
            release dut.exec_ordered_issue_replay_valid;
            release dut.exec_ordered_issue_replay_id;
            release dut.exec_ordered_issue_replay_slot;
            release dut.exec_ordered_issue_replay_pc;
            #1;
            if (dut.memory_replay_deferred_redirect_valid_q)
                fail("saved EX redirect did not drain after publication");
            if (dut.memory_replay_pending_q)
                fail("saved EX redirect retained a younger ordered replay");

            // A target-mispredict pulse is separate from the execution
            // pipe's direction-mispredict pulse.  When its branch is older
            // than an ordered replay, publish the branch cut immediately;
            // replaying first cannot remove the intervening wrong-path work.
            dut.memory_replay_pending_q = 1'b1;
            dut.memory_replay_ordered_issue_q = 1'b1;
            dut.memory_replay_id_q = `OPENRV64_INSTR_ID_WIDTH'(100);
            dut.memory_replay_slot_q = SLOT_WIDTH'(10);
            dut.memory_replay_target_q = 64'h0000_0000_0000_1900;
            force dut.exec_redirect_valid = 1'b0;
            force dut.exec_redirect_id =
                `OPENRV64_INSTR_ID_WIDTH'(90);
            force dut.exec_redirect_slot = SLOT_WIDTH'(9);
            force dut.exec_redirect_target = 64'h0000_0000_0000_1800;
            force dut.exec_branch_resolved = 1'b1;
            branch_target_mispredict = 1'b1;
            #1;
            if (!redirect_valid ||
                dut.redirect_memory_replay_o ||
                redirect_tagged_recovery ||
                (redirect_id != `OPENRV64_INSTR_ID_WIDTH'(90)) ||
                (redirect_target != 64'h0000_0000_0000_1800) ||
                (branch_target != 64'h0000_0000_0000_1800))
                fail("older target correction lost behind ordered replay");
            squash = 1'b1;
            tick();
            squash = 1'b0;
            branch_target_mispredict = 1'b0;
            release dut.exec_redirect_valid;
            release dut.exec_redirect_id;
            release dut.exec_redirect_slot;
            release dut.exec_redirect_target;
            release dut.exec_branch_resolved;
            #1;
            if (dut.memory_replay_pending_q)
                fail("target correction retained a younger ordered replay");

            // If a younger ordered-head blockage arrives while an older
            // normal replay is waiting for a control, keep the older cut but
            // promote it to ordered.  The older inclusive cut also removes
            // the younger blocked packet.  Replacing it loses the oldest
            // recovery; leaving it normal can deadlock when the watched
            // control depends on an older load hidden behind that packet.
            dut.memory_replay_pending_q = 1'b1;
            dut.memory_replay_ordered_issue_q = 1'b0;
            dut.memory_replay_id_q = `OPENRV64_INSTR_ID_WIDTH'(120);
            dut.memory_replay_slot_q = SLOT_WIDTH'(12);
            dut.memory_replay_target_q = 64'h0000_0000_0000_1b00;
            dut.memory_control_watch_valid_q[0] = 1'b1;
            dut.memory_control_watch_id_q[0] =
                `OPENRV64_INSTR_ID_WIDTH'(115);
            force dut.exec_ordered_issue_replay_valid = 1'b1;
            force dut.exec_ordered_issue_replay_id =
                `OPENRV64_INSTR_ID_WIDTH'(130);
            force dut.exec_ordered_issue_replay_slot = SLOT_WIDTH'(13);
            force dut.exec_ordered_issue_replay_pc =
                64'h0000_0000_0000_1c00;
            #1;
            if (dut.memory_replay_valid)
                fail("normal replay ignored control before promotion");
            tick();
            release dut.exec_ordered_issue_replay_valid;
            release dut.exec_ordered_issue_replay_id;
            release dut.exec_ordered_issue_replay_slot;
            release dut.exec_ordered_issue_replay_pc;
            #1;
            if (!dut.memory_replay_pending_q ||
                !dut.memory_replay_ordered_issue_q ||
                (dut.memory_replay_id_q !=
                 `OPENRV64_INSTR_ID_WIDTH'(120)) ||
                (dut.memory_replay_slot_q != SLOT_WIDTH'(12)) ||
                (dut.memory_replay_target_q !=
                 64'h0000_0000_0000_1b00))
                fail("younger ordered blockage did not promote older replay");
            if (!dut.memory_replay_valid ||
                (redirect_id != `OPENRV64_INSTR_ID_WIDTH'(120)) ||
                (redirect_target != 64'h0000_0000_0000_1b00))
                fail("promoted older replay did not bypass control wait");
            squash = 1'b1;
            tick();
            squash = 1'b0;
            #1;
            if (dut.memory_replay_pending_q)
                fail("promoted older replay did not drain");
            dut.memory_control_watch_valid_q[0] = 1'b0;

            // A normal collision replay waits behind an older unresolved
            // control.  That pending state must not suppress retirement of
            // the older prefix, which is what eventually resolves the wait.
            dut.memory_replay_pending_q = 1'b1;
            dut.memory_replay_ordered_issue_q = 1'b0;
            dut.memory_replay_id_q = `OPENRV64_INSTR_ID_WIDTH'(120);
            dut.memory_control_watch_valid_q[0] = 1'b1;
            dut.memory_control_watch_id_q[0] =
                `OPENRV64_INSTR_ID_WIDTH'(115);
            force dut.queue_retire_valid = 3'b111;
            force dut.queue_retire_id = {
                `OPENRV64_INSTR_ID_WIDTH'(112),
                `OPENRV64_INSTR_ID_WIDTH'(111),
                `OPENRV64_INSTR_ID_WIDTH'(110)
            };
            #1;
            if (dut.memory_replay_valid)
                fail("normal replay ignored older unresolved control");
            if (dut.retire_queue_valid != 3'b111)
                fail("pending replay blocked retirement of older prefix");
            force dut.queue_retire_id = {
                `OPENRV64_INSTR_ID_WIDTH'(120),
                `OPENRV64_INSTR_ID_WIDTH'(119),
                `OPENRV64_INSTR_ID_WIDTH'(110)
            };
            #1;
            if (dut.retire_queue_valid != 3'b011)
                fail("pending replay retired its cut or younger suffix");

            // The same age rule applies to the store authorization window.
            // A replay waiting behind an older control must not prevent an
            // even older head store from completing; otherwise retirement of
            // that store and issue of the replay wait on each other forever.
            force dut.g_ordered_store_window[0].ordinary_store = 1'b1;
            force dut.g_ordered_store_window[1].ordinary_store = 1'b1;
            force dut.g_ordered_store_window[2].ordinary_store = 1'b1;
            force dut.queue_head_id = {
                `OPENRV64_INSTR_ID_WIDTH'(112),
                `OPENRV64_INSTR_ID_WIDTH'(111),
                `OPENRV64_INSTR_ID_WIDTH'(110)
            };
            #1;
            if (dut.ordered_store_window_valid != 3'b111)
                fail("pending replay blocked older store window");
            force dut.queue_head_id = {
                `OPENRV64_INSTR_ID_WIDTH'(121),
                `OPENRV64_INSTR_ID_WIDTH'(120),
                `OPENRV64_INSTR_ID_WIDTH'(110)
            };
            #1;
            if (dut.ordered_store_window_valid != 3'b001)
                fail("pending replay authorized its cut or younger store");
            release dut.g_ordered_store_window[0].ordinary_store;
            release dut.g_ordered_store_window[1].ordinary_store;
            release dut.g_ordered_store_window[2].ordinary_store;
            release dut.queue_head_id;
            release dut.queue_retire_valid;
            release dut.queue_retire_id;
            dut.memory_replay_pending_q = 1'b0;
            dut.memory_control_watch_valid_q[0] = 1'b0;
            memory_replay_probe_active = 1'b0;
        end

        if ((RENAME_MODE == 0) &&
            (dut.u_gpr.regs[1] !== 64'd5 ||
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
                                    64'd42 : -64'd4)))
            fail("final architectural register state was incorrect");

        if (ISSUE_WINDOW != 0)
            $display("PASS: banked 3p issue window processed post-selection register loads, ordered arithmetic, load/use, and held bank retries");
        else if (RENAME_MODE != 0)
            $display("PASS: banked 3p backend instruction stream allocated, executed, retired, and freed physical registers");
        else
            $display("PASS: banked 3p backend processed ordered arithmetic plus a MEM0-forwarded load/use with held bank retries and conservative dependencies");
        $finish;
    end

    initial begin
        #100000;
        $display("timeout state reset=%b flush=%b squash=%b decode_valid=%b decode_ready=%b dispatch=%0d retire=%0d issue=%b complete=%b alloc=%b alloc_ready=%b rename_ready=%b recovery=%b window_count=%0d window_free=%0d regload_valid=%b independent_valid=%b independent_done=%h read_req=%b read_ack=%b read_valid=%b drain=%b free=%0d",
                 rst_n, flush, squash, decode_valid, decode_ready,
                 dispatch_occupancy,
                 retire_occupancy, issue_valid, complete_valid,
                 dut.allocation_valid, dut.allocation_ready,
                 dut.u_dispatch.g_3p.rename_allocation_ready,
                 dut.u_dispatch.g_3p.u_tomasulo_window.u_window.recovery_inhibit,
                 dut.u_dispatch.g_3p.u_tomasulo_window.u_window.count_q,
                 dut.u_dispatch.g_3p.u_tomasulo_window.u_window.free_count,
                 dut.banked_regload_valid_q,
                 dut.banked_independent_valid_q,
                 dut.banked_independent_operand_done_q,
                 dut.gpr_read_req, dut.gpr_read_ack, dut.gpr_read_valid,
                 dut.banked_gpr_drain_q, observed_rename_free_count);
        $fatal(1, "tb_backend_3p_banked: timeout");
    end
endmodule
