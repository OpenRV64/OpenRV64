`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/except/except-defs.v"

// Complete three-pipe backend.  Decode supplies up to three static packets per
// cycle; the dispatch queue may burst three old packets to EX0, EX1, and MEM.
// Operands are captured at issue, results may complete out of order, and the
// retirement queue exposes only the maximal contiguous in-order prefix.
module openrv64_backend_3p #(
    parameter integer RETIRE_DEPTH = 16,
    parameter integer DISPATCH_DEPTH = 6,
    parameter integer PHYS_REG_COUNT = `OPENRV64_PHYS_REG_COUNT,
    parameter integer PHYS_REG_ADDR_WIDTH =
        (PHYS_REG_COUNT < 1) ? 1 : $clog2(PHYS_REG_COUNT + 1),
    parameter integer MAX_READS_PER_REG = 2,
    parameter integer ENABLE_RV64M = 1,
    parameter integer ENABLE_RV64ZBB = 1,
    parameter integer ENABLE_TRACE = 1,
    parameter [2:0] COMPLETION_FORWARD_MASK = 3'b000,
    parameter [2:0] BRANCH_COMPLETION_FORWARD_MASK = 3'b001,
    parameter integer ENABLE_FULL_FORWARDING = 0,
    parameter integer RELAX_WAW = 1,
    parameter integer RELAX_HAZARDS = 0,
    parameter integer FREE_BRANCHES = 0,
    parameter integer ENABLE_EQ_BRANCH_PAIRING = 1,
    parameter integer ENABLE_ISSUE_WINDOW = 0,
    parameter integer ENABLE_SPECULATION_WINDOW = 0,
    parameter integer ISSUE_WINDOW_DEPTH = 16,
    parameter integer RENAME_MODE = 0,
    parameter integer ENABLE_POSTED_STORES = 1,
    parameter integer ENABLE_ZICCLSM = 1,
    parameter integer STORE_QUEUE_DEPTH = 4,
    parameter integer ENABLE_COHERENT_ATOMICS = 0,
    parameter integer BANKED_GPR = 0,
    parameter integer FPGA_GPR_LUTRAM = 0,
    parameter integer BANKED_GPR_READ_PORTS_PER_BANK = 2,
    parameter integer BANKED_GPR_NUM_BANKS = 4,
    parameter [`RV64_XLEN-1:0] STORE_FORWARD_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] STORE_FORWARD_SIZE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] CACHEABLE_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] CACHEABLE_SIZE = {`RV64_XLEN{1'b0}},
    parameter integer SLOT_WIDTH = $clog2(RETIRE_DEPTH),
    parameter integer RETIRE_COUNT_WIDTH = $clog2(RETIRE_DEPTH + 1),
    parameter integer DISPATCH_COUNT_WIDTH = $clog2(
        (((ENABLE_ISSUE_WINDOW != 0) ||
          (RENAME_MODE == `OPENRV64_RENAME_TOMASULO)) ?
         ISSUE_WINDOW_DEPTH : DISPATCH_DEPTH) + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_frontend_i,
    input  wire                         coherent_reservation_clear_i,
    input  wire                         translation_bypass_i,

    input  wire [2:0]                   decode_valid_i,
    output wire [2:0]                   decode_ready_o,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        decode_payload_i,
    input  wire [2:0]                   decode_uses_rs1_i,
    input  wire [2:0]                   decode_uses_rs2_i,
    output wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0]
                                        decode_allocation_id_o,
    output wire [3*SLOT_WIDTH-1:0]      decode_allocation_slot_o,

    output wire [`RV64_FUNCT12_WIDTH-1:0] csr_addr_o,
    input  wire [`RV64_XLEN-1:0]        csr_rdata_i,
    input  wire                         csr_valid_i,
    input  wire                         csr_writable_i,
    input  wire                         csr_write_ready_i,
    output wire                         csr_write_o,
    output wire [`RV64_FUNCT12_WIDTH-1:0] csr_write_addr_o,
    output wire [`RV64_FUNCT3_WIDTH-1:0] csr_op_o,
    output wire [`RV64_XLEN-1:0]        csr_wdata_o,

    output wire                         mem_valid_o,
    input  wire                         mem_ready_i,
    output wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_tag_o,
    output wire                         mem_xlate_only_o,
    output wire                         mem_physical_o,
    output wire                         mem_pmp_checked_o,
    input  wire                         mem_resp_valid_i,
    output wire                         mem_resp_ready_o,
    input  wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem_resp_tag_i,
    input  wire [`RV64_XLEN-1:0]        mem_resp_paddr_i,
    input  wire                         mem_error_i,
    input  wire                         mem_page_fault_i,
    input  wire                         mem_store_done_valid_i,
    output wire                         mem_store_done_ready_o,
    input  wire [`OPENRV64_LSU_TAG_WIDTH-1:0]
                                        mem_store_done_tag_i,
    output wire                         store_barrier_request_o,
    input  wire                         store_barrier_busy_i,
    input  wire                         mem_access_allowed_i,
    output wire                         mem_lock_o,
    output wire                         mem_write_o,
    output wire [`RV64_XLEN-1:0]        mem_addr_o,
    output wire [`RV64_XLEN-1:0]        mem_wdata_o,
    output wire [7:0]                   mem_wstrb_o,
    output wire                         mem_access_o,
    output wire [`RV64_XLEN-1:0]        mem_effective_addr_o,
    output wire [2:0]                   mem_size_o,
    input  wire [`RV64_XLEN-1:0]        mem_rdata_i,
    output wire                         mem_xlate_valid_o,
    input  wire                         mem_xlate_ready_i,
    output wire [`OPENRV64_LSU_XLATE_TAG_WIDTH-1:0]
                                        mem_xlate_tag_o,
    output wire                         mem_xlate_write_o,
    output wire [2:0]                   mem_xlate_size_o,
    output wire [`RV64_XLEN-1:0]        mem_xlate_vaddr_o,
    input  wire                         mem_xlate_resp_valid_i,
    output wire                         mem_xlate_resp_ready_o,
    input  wire [`OPENRV64_LSU_XLATE_TAG_WIDTH-1:0]
                                        mem_xlate_resp_tag_i,
    input  wire [`RV64_XLEN-1:0]        mem_xlate_resp_paddr_i,
    input  wire                         mem_xlate_resp_access_fault_i,
    input  wire                         mem_xlate_resp_page_fault_i,
    output wire                         mem1_valid_o,
    input  wire                         mem1_ready_i,
    output wire [`OPENRV64_LSU_TAG_WIDTH-1:0] mem1_tag_o,
    output wire                         mem1_lock_o,
    output wire                         mem1_write_o,
    output wire [`RV64_XLEN-1:0]        mem1_addr_o,
    output wire [`RV64_XLEN-1:0]        mem1_wdata_o,
    output wire [7:0]                   mem1_wstrb_o,
    output wire                         mem1_access_o,
    output wire [`RV64_XLEN-1:0]        mem1_effective_addr_o,
    output wire [2:0]                   mem1_size_o,

    input  wire                         irq_pending_i,
    input  wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] irq_cause_i,

    output wire                         redirect_valid_o,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] redirect_id_o,
    output wire [`RV64_XLEN-1:0]        redirect_target_o,
    output wire                         branch_resolved_o,
    output wire                         branch_conditional_o,
    output wire                         branch_taken_o,
    output wire [`RV64_XLEN-1:0]        branch_pc_o,
    output wire [`RV64_INSTR_WIDTH-1:0] branch_instr_o,
    output wire [`OPENRV64_INSTR_ID_WIDTH-1:0] branch_id_o,
    output wire [SLOT_WIDTH-1:0]        branch_slot_o,
    output wire [2:0]                   branch_train_valid_o,
    output wire [2:0]                   branch_train_conditional_o,
    output wire [2:0]                   branch_train_taken_o,
    output wire [3*`RV64_XLEN-1:0]      branch_train_pc_o,
    output wire [2:0]                   branch_retire_age_valid_o,
    output wire [3*`RV64_XLEN-1:0]      branch_retire_age_addr_o,

    output wire [2:0]                   retire_arch_o,
    output wire [1:0]                   retire_count_o,
    output wire                         exception_o,
    output wire                         halt_o,
    output wire                         irq_o,
    output wire                         mret_o,
    output wire                         sret_o,
    output wire                         fence_i_o,
    output wire                         sfence_vma_o,
    output wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] cause_o,
    output wire [`RV64_XLEN-1:0]        retire_pc_o,
    output wire [`RV64_XLEN-1:0]        retire_next_pc_o,
    output wire [`RV64_XLEN-1:0]        retire_tval_o,
    output wire [63:0]                  retire_trace_id_o,
    output wire [`RV64_INSTR_WIDTH-1:0] retire_instr_o,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] retire_rd_o,
    output wire [`RV64_XLEN-1:0]        retire_wdata_o,

    output wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] issue_valid_o,
    output wire [2:0]                   complete_valid_o,
    output wire [31:0]                  write_busy_o,
    output wire                         barrier_active_o,
    output wire [RETIRE_COUNT_WIDTH-1:0] retire_occupancy_o,
    output wire [DISPATCH_COUNT_WIDTH-1:0] dispatch_occupancy_o
);

    // Free branches complete at dispatch using dispatch-time operand data.
    // Banked mode deliberately defers real operand capture to regload, so the
    // two features cannot be composed without moving free-branch evaluation.
    generate
        if ((BANKED_GPR != 0) && (FREE_BRANCHES != 0)) begin :
                g_invalid_banked_free_branches
            initial begin
                $fatal(1,
                    "BANKED_GPR requires FREE_BRANCHES=0 until branch evaluation moves to regload");
            end
        end
    endgenerate
    localparam integer RETIRE_META_WIDTH =
        `OPENRV64_DISPATCH_META_WIDTH + 2*PHYS_REG_ADDR_WIDTH;
    localparam integer RETIRE_RECORD_WIDTH =
        `OPENRV64_RETIRE_ALLOC_FIXED_WIDTH + 2*PHYS_REG_ADDR_WIDTH;
    localparam integer RETIRE_RESULT_WIDTH =
        `OPENRV64_RETIRE_RESULT_WIDTH;

    wire [6*PHYS_REG_ADDR_WIDTH-1:0] gpr_read_addr;
    wire [6*PHYS_REG_ADDR_WIDTH-1:0] dispatch_gpr_read_addr;
    wire [5:0] dispatch_gpr_read_ready;
    wire [6*PHYS_REG_ADDR_WIDTH-1:0] gpr_storage_read_addr;
    wire [6*`RV64_XLEN-1:0] gpr_read_data;
    wire [6*`RV64_XLEN-1:0] dispatch_gpr_read_data;
    wire [5:0] gpr_read_req;
    wire [5:0] gpr_read_ack;
    wire [5:0] gpr_read_valid;
    wire [2:0] gpr_write;
    wire [2:0] gpr_write_ack;
    wire [2:0] gpr_write_ready;
    wire [7:0] gpr_trace_read_group_denied;
    wire [7:0] gpr_trace_read_group_partial;
    wire [7:0] gpr_trace_read_early_accept;
    wire banked_retire_write_pair_conflict;
    wire [3*PHYS_REG_ADDR_WIDTH-1:0] gpr_write_addr;
    wire [3*`RV64_XLEN-1:0] gpr_write_data;
    wire gpr_quiescent;
    wire [5:0] banked_legacy_read_req;
    wire [6*PHYS_REG_ADDR_WIDTH-1:0]
        banked_legacy_storage_read_addr;
    reg [6*PHYS_REG_ADDR_WIDTH-1:0]
        banked_independent_read_addr;
    wire [31:0] dispatch_write_busy;
    reg [31:0] banked_write_ack_hot;
    reg [PHYS_REG_ADDR_WIDTH-1:0] banked_write_ack_addr;
    integer banked_write_ack_lane;
    always @* begin
        banked_write_ack_hot = 32'd0;
        banked_write_ack_addr = {PHYS_REG_ADDR_WIDTH{1'b0}};
        for (banked_write_ack_lane = 0; banked_write_ack_lane < 2;
             banked_write_ack_lane = banked_write_ack_lane + 1) begin
            banked_write_ack_addr = gpr_write_addr[
                banked_write_ack_lane*PHYS_REG_ADDR_WIDTH +:
                PHYS_REG_ADDR_WIDTH];
            if ((RENAME_MODE == `OPENRV64_RENAME_IDENTITY) &&
                gpr_write[banked_write_ack_lane] &&
                gpr_write_ack[banked_write_ack_lane] &&
                (banked_write_ack_addr != {PHYS_REG_ADDR_WIDTH{1'b0}}))
                banked_write_ack_hot[banked_write_ack_addr] = 1'b1;
        end
    end

    // A banked write ack is the storage commit edge.  Publish that destination
    // as no longer busy in the same cycle; a simultaneous dependent read is
    // safe because the register file carries the accepted write data through
    // its registered read-response bypass.  Dispatch keeps its registered
    // retire feedback internally, so WAW allocation is not relaxed here.
    assign write_busy_o = ((BANKED_GPR != 0) &&
        (RENAME_MODE == `OPENRV64_RENAME_IDENTITY)) ?
        (dispatch_write_busy & ~banked_write_ack_hot) :
        dispatch_write_busy;
    wire gpr_access_pending = (|gpr_read_req) || (|gpr_write) ||
        !gpr_quiescent;
    reg banked_gpr_drain_q;

    wire allocation_ready;
    wire queue_allocation_ready;
    wire [2:0] allocation_valid;
    wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] allocation_id;
    wire [3*SLOT_WIDTH-1:0] allocation_slot;
    wire [3*RETIRE_META_WIDTH-1:0] allocation_meta;
    wire [1:0] rename_free_valid;
    wire [2*PHYS_REG_ADDR_WIDTH-1:0] rename_free_tag;
    wire [3*RETIRE_RECORD_WIDTH-1:0] allocation_record;
    wire [2:0] allocation_complete;
    wire [2:0] allocation_mispredict;
    wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        allocation_result;
    wire [3*RETIRE_RESULT_WIDTH-1:0] allocation_retire_result;
    wire [3*64-1:0] allocation_trace;

    assign decode_allocation_id_o = allocation_id;
    assign decode_allocation_slot_o = allocation_slot;

    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_ready;
    wire [1:0] base_alu_available;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*
          `OPENRV64_INSTR_ID_WIDTH-1:0] pipe_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT*SLOT_WIDTH-1:0] pipe_slot;
    wire [`OPENRV64_EXEC_PIPE_COUNT*
          `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] pipe_payload;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_src1_producer_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*
          `OPENRV64_INSTR_ID_WIDTH-1:0] pipe_src1_producer_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_src2_producer_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*
          `OPENRV64_INSTR_ID_WIDTH-1:0] pipe_src2_producer_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] dispatch_pipe_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        dispatch_pipe_candidate_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*2-1:0]
        dispatch_pipe_age_rank;
    wire [`OPENRV64_EXEC_PIPE_COUNT*
          `OPENRV64_INSTR_ID_WIDTH-1:0] dispatch_pipe_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT*SLOT_WIDTH-1:0]
        dispatch_pipe_slot;
    wire [`OPENRV64_EXEC_PIPE_COUNT*
          `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        dispatch_pipe_payload;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] dispatch_pipe_uses_rs1;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] dispatch_pipe_uses_rs2;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        dispatch_pipe_src1_producer_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*
          `OPENRV64_INSTR_ID_WIDTH-1:0]
        dispatch_pipe_src1_producer_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        dispatch_pipe_src2_producer_valid;
    wire [`OPENRV64_EXEC_PIPE_COUNT*
          `OPENRV64_INSTR_ID_WIDTH-1:0]
        dispatch_pipe_src2_producer_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH-1:0]
        dispatch_pipe_src1_phys;
    wire [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH-1:0]
        dispatch_pipe_src2_phys;
    wire [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH-1:0]
        dispatch_pipe_destination_phys;
    wire [32*PHYS_REG_ADDR_WIDTH-1:0] rename_committed_map;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_unsupported;

    wire [2:0] complete_valid;
    wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] complete_id;
    wire [3*SLOT_WIDTH-1:0] complete_slot;
    wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        complete_payload;
    wire [3*RETIRE_RESULT_WIDTH-1:0] complete_retire_result;
    wire [2:0] completion_prf_write_req;
    wire [3*PHYS_REG_ADDR_WIDTH-1:0] completion_prf_write_tag;
    wire [3*`RV64_XLEN-1:0] completion_prf_write_data;
    reg [2:0] completion_prf_sorted_req;
    reg [3*PHYS_REG_ADDR_WIDTH-1:0] completion_prf_sorted_tag;
    reg [3*`RV64_XLEN-1:0] completion_prf_sorted_data;
    reg [3*2-1:0] completion_prf_sorted_owner;
    reg [2:0] completion_prf_write_ack_r;
    wire [2:0] completion_writeback_fire;
    wire [2:0] exec_complete_ready;
    wire exec_redirect_valid;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] exec_redirect_id;
    wire [SLOT_WIDTH-1:0] exec_redirect_slot;
    wire [`RV64_XLEN-1:0] exec_redirect_target;
    wire exec_branch_resolved;
    wire exec_branch_conditional;
    wire exec_branch_taken;
    wire [`RV64_XLEN-1:0] exec_branch_pc;
    wire [`RV64_INSTR_WIDTH-1:0] exec_branch_instr;
    wire async_store_fault;
    wire async_store_page_fault;
    wire [`RV64_XLEN-1:0] async_store_fault_pc;
    wire [`RV64_XLEN-1:0] async_store_fault_addr;
    wire [63:0] async_store_fault_trace;
    wire [`RV64_INSTR_WIDTH-1:0] async_store_fault_instr;
    reg async_store_fault_pending_q;
    reg [`RV64_EXCEPT_CAUSE_WIDTH-1:0] async_store_fault_cause_q;
    reg [`RV64_XLEN-1:0] async_store_fault_addr_q;
    reg [`RV64_XLEN-1:0] async_store_fault_pc_q;
    reg [63:0] async_store_fault_trace_q;
    reg [`RV64_INSTR_WIDTH-1:0] async_store_fault_instr_q;
    reg [`RV64_XLEN-1:0] last_arch_next_pc_q;

    function automatic free_branch_taken;
        input [`RV64_BR_OP_WIDTH-1:0] branch_op;
        input [`RV64_XLEN-1:0] src1;
        input [`RV64_XLEN-1:0] src2;
        begin
            case (branch_op)
                `RV64_BR_OP_BEQ:  free_branch_taken = (src1 == src2);
                `RV64_BR_OP_BNE:  free_branch_taken = (src1 != src2);
                `RV64_BR_OP_BLT:  free_branch_taken =
                    ($signed(src1) < $signed(src2));
                `RV64_BR_OP_BGE:  free_branch_taken =
                    ($signed(src1) >= $signed(src2));
                `RV64_BR_OP_BLTU: free_branch_taken = (src1 < src2);
                `RV64_BR_OP_BGEU: free_branch_taken = (src1 >= src2);
                default:          free_branch_taken = 1'b0;
            endcase
        end
    endfunction

    // Free conditional branches retain their real operands and prediction,
    // but become completed retirement entries without occupying EX0.
    // JAL/JALR remain on the normal path so this experiment isolates branches.
    genvar free_lane;
    generate
        for (free_lane = 0; free_lane < 3;
             free_lane = free_lane + 1) begin : g_free_branch
            wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] alloc_payload =
                allocation_meta[
                    free_lane*RETIRE_META_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
            wire alloc_branch = alloc_payload[14];
            wire alloc_fault = alloc_payload[8] || alloc_payload[5] ||
                               alloc_payload[4];
            wire [`RV64_XLEN-1:0] alloc_pc = alloc_payload[274 +: 64];
            wire [`RV64_INSTR_WIDTH-1:0] alloc_instr =
                alloc_payload[242 +: 32];
            wire [`RV64_XLEN-1:0] alloc_rs1_data =
                alloc_payload[168 +: 64];
            wire [`RV64_XLEN-1:0] alloc_rs2_data =
                alloc_payload[104 +: 64];
            wire [`RV64_XLEN-1:0] alloc_imm = alloc_payload[40 +: 64];
            wire [`RV64_BR_OP_WIDTH-1:0] alloc_br_op =
                alloc_payload[18 +: `RV64_BR_OP_WIDTH];
            wire alloc_taken = free_branch_taken(
                alloc_br_op, alloc_rs1_data, alloc_rs2_data);
            wire [`RV64_XLEN-1:0] alloc_target = alloc_pc + alloc_imm;
            wire [`RV64_XLEN-1:0] alloc_next_pc = alloc_taken ?
                alloc_target : (alloc_pc + 64'd4);

            assign allocation_complete[free_lane] =
                (FREE_BRANCHES != 0) &&
                (ENABLE_ISSUE_WINDOW == 0) &&
                allocation_valid[free_lane] && alloc_branch && !alloc_fault;
            assign allocation_mispredict[free_lane] =
                allocation_complete[free_lane] &&
                (alloc_payload[12] != alloc_taken);
            assign allocation_result[
                free_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH] = {
                alloc_payload[338 +: 64], // trace ID
                alloc_pc,
                alloc_next_pc,
                alloc_instr,
                64'd0,
                alloc_payload[237 +: 5], // rs1
                alloc_payload[232 +: 5], // rs2
                alloc_payload[35 +: 5],  // rd
                alloc_payload[17],       // architectural register write
                1'b0,                    // illegal
                1'b0,                    // ebreak
                1'b0,                    // ecall
                1'b0,                    // exception
                1'b0,                    // halt
                5'd0,                    // cause
                64'd0,                   // tval
                1'b0,                    // mret
                1'b0,                    // sret
                1'b0,                    // csr write
                12'd0,                   // csr address
                64'd0                    // csr data
            };
        end
    endgenerate

    // Retirement stores one canonical compact record per slot.  Fields that
    // already exist at allocation are not echoed through completion.  Trace
    // state is a separate allocation-only debug bank and is absent when trace
    // support is disabled.
    genvar retire_record_lane;
    generate
        for (retire_record_lane = 0; retire_record_lane < 3;
             retire_record_lane = retire_record_lane + 1) begin :
                g_retire_record
            wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] issue_record =
                allocation_meta[
                    retire_record_lane*RETIRE_META_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
            wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                alloc_complete_record = allocation_result[
                    retire_record_lane*
                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
            wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                live_complete_record = complete_payload[
                    retire_record_lane*
                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];

            assign allocation_record[
                retire_record_lane*RETIRE_RECORD_WIDTH +:
                RETIRE_RECORD_WIDTH] = {
                allocation_meta[
                    retire_record_lane*RETIRE_META_WIDTH +
                    `OPENRV64_DISPATCH_META_WIDTH +
                    PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH],
                allocation_meta[
                    retire_record_lane*RETIRE_META_WIDTH +
                    `OPENRV64_DISPATCH_META_WIDTH +:
                    PHYS_REG_ADDR_WIDTH],
                issue_record[12], // predicted taken
                issue_record[13], // jump
                issue_record[14], // branch
                issue_record[15], // memory write
                issue_record[16], // memory read
                allocation_meta[
                    retire_record_lane*RETIRE_META_WIDTH +
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 2], // hard
                allocation_meta[
                    retire_record_lane*RETIRE_META_WIDTH +
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 1], // uses rs2
                allocation_meta[
                    retire_record_lane*RETIRE_META_WIDTH +
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH],     // uses rs1
                issue_record[17],                           // register write
                issue_record[35 +: `RV64_REG_ADDR_WIDTH],
                issue_record[232 +: `RV64_REG_ADDR_WIDTH],
                issue_record[237 +: `RV64_REG_ADDR_WIDTH],
                issue_record[242 +: `RV64_INSTR_WIDTH],
                issue_record[274 +: `RV64_XLEN]
            };
            assign allocation_trace[
                retire_record_lane*64 +: 64] =
                (ENABLE_TRACE != 0) ? issue_record[338 +: 64] : 64'd0;
            assign allocation_retire_result[
                retire_record_lane*RETIRE_RESULT_WIDTH +:
                RETIRE_RESULT_WIDTH] = {
                alloc_complete_record[265 +: `RV64_XLEN],
                alloc_complete_record[
                    `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN],
                alloc_complete_record[0 +: 153]
            };
            assign complete_retire_result[
                retire_record_lane*RETIRE_RESULT_WIDTH +:
                RETIRE_RESULT_WIDTH] = {
                live_complete_record[265 +: `RV64_XLEN],
                live_complete_record[
                    `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN],
                live_complete_record[0 +: 153]
            };
        end
    endgenerate

    wire [2:0] queue_retire_valid;
    wire [2:0] queue_retire_accept;
    wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] queue_retire_id;
    wire [3*RETIRE_RECORD_WIDTH-1:0] queue_retire_record;
    wire [3*RETIRE_RESULT_WIDTH-1:0] queue_retire_commit;
    wire [3*64-1:0] queue_retire_trace;
    wire [3*SLOT_WIDTH-1:0] queue_retire_slot;
    wire [2:0] queue_alloc_accept;
    wire [2:0] queue_complete_accept;
    wire [2:0] queue_complete_match;
    wire [3*RETIRE_RECORD_WIDTH-1:0] queue_complete_record;
    wire [2:0] completion_storage_ready;
    wire [2:0] completion_fire;

    function automatic completion_id_is_younger;
        input [`OPENRV64_INSTR_ID_WIDTH-1:0] candidate;
        input [`OPENRV64_INSTR_ID_WIDTH-1:0] reference;
        reg [`OPENRV64_INSTR_ID_WIDTH-1:0] distance;
        begin
            distance = candidate - reference;
            completion_id_is_younger =
                (distance != {`OPENRV64_INSTR_ID_WIDTH{1'b0}}) &&
                !distance[`OPENRV64_INSTR_ID_WIDTH-1];
        end
    endfunction

    // The physical completion ports are execution-resource lanes, not age
    // lanes.  Sort live PRF writes oldest-first before presenting them to the
    // fixed-priority bank arbiter, then return each grant to its originating
    // completion lane.  This preserves the architectural oldest-wins policy
    // without coupling unrelated banks or serializing the writeback fabric.
    integer completion_sort_rank;
    integer completion_sort_candidate;
    integer completion_sort_other;
    integer completion_sort_selected;
    reg [2:0] completion_sort_remaining;
    reg completion_sort_candidate_oldest;
    always @* begin
        completion_prf_sorted_req = 3'b000;
        completion_prf_sorted_tag =
            {3*PHYS_REG_ADDR_WIDTH{1'b0}};
        completion_prf_sorted_data = {3*`RV64_XLEN{1'b0}};
        completion_prf_sorted_owner = 6'b000000;
        completion_sort_remaining = completion_prf_write_req;
        completion_sort_selected = -1;
        completion_sort_candidate_oldest = 1'b0;
        for (completion_sort_rank = 0; completion_sort_rank < 3;
             completion_sort_rank = completion_sort_rank + 1) begin
            completion_sort_selected = -1;
            for (completion_sort_candidate = 0;
                 completion_sort_candidate < 3;
                 completion_sort_candidate = completion_sort_candidate + 1) begin
                completion_sort_candidate_oldest =
                    completion_sort_remaining[completion_sort_candidate];
                for (completion_sort_other = 0;
                     completion_sort_other < 3;
                     completion_sort_other = completion_sort_other + 1) begin
                    if (completion_sort_remaining[completion_sort_other] &&
                        (completion_sort_other != completion_sort_candidate) &&
                        completion_id_is_younger(
                            complete_id[
                                completion_sort_candidate*
                                `OPENRV64_INSTR_ID_WIDTH +:
                                `OPENRV64_INSTR_ID_WIDTH],
                            complete_id[
                                completion_sort_other*
                                `OPENRV64_INSTR_ID_WIDTH +:
                                `OPENRV64_INSTR_ID_WIDTH]))
                        completion_sort_candidate_oldest = 1'b0;
                end
                if ((completion_sort_selected < 0) &&
                    completion_sort_candidate_oldest)
                    completion_sort_selected = completion_sort_candidate;
            end
            if (completion_sort_selected >= 0) begin
                completion_prf_sorted_req[completion_sort_rank] = 1'b1;
                completion_prf_sorted_tag[
                    completion_sort_rank*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] = completion_prf_write_tag[
                        completion_sort_selected*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH];
                completion_prf_sorted_data[
                    completion_sort_rank*`RV64_XLEN +: `RV64_XLEN] =
                    completion_prf_write_data[
                        completion_sort_selected*`RV64_XLEN +:
                        `RV64_XLEN];
                completion_prf_sorted_owner[
                    completion_sort_rank*2 +: 2] =
                    completion_sort_selected[1:0];
                completion_sort_remaining[completion_sort_selected] = 1'b0;
            end
        end

        completion_prf_write_ack_r = 3'b000;
        for (completion_sort_rank = 0; completion_sort_rank < 3;
             completion_sort_rank = completion_sort_rank + 1) begin
            if (completion_prf_sorted_req[completion_sort_rank])
                completion_prf_write_ack_r[
                    completion_prf_sorted_owner[
                        completion_sort_rank*2 +: 2]] =
                    gpr_write_ack[completion_sort_rank];
        end
    end

    genvar completion_write_lane;
    generate
        for (completion_write_lane = 0; completion_write_lane < 3;
             completion_write_lane = completion_write_lane + 1) begin :
                g_completion_prf_write
            wire [RETIRE_RECORD_WIDTH-1:0] completion_record =
                queue_complete_record[
                    completion_write_lane*RETIRE_RECORD_WIDTH +:
                    RETIRE_RECORD_WIDTH];
            wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                completion_packet = complete_payload[
                    completion_write_lane*
                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
            assign completion_prf_write_tag[
                completion_write_lane*PHYS_REG_ADDR_WIDTH +:
                PHYS_REG_ADDR_WIDTH] = completion_record[
                    `OPENRV64_RETIRE_ALLOC_NEW_PHYS_LSB +:
                    PHYS_REG_ADDR_WIDTH];
            assign completion_prf_write_data[
                completion_write_lane*`RV64_XLEN +: `RV64_XLEN] =
                completion_packet[
                    `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
            assign completion_prf_write_req[completion_write_lane] =
                (RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
                complete_valid[completion_write_lane] &&
                queue_complete_match[completion_write_lane] &&
                completion_record[
                    `OPENRV64_RETIRE_ALLOC_REG_WRITE_BIT] &&
                (completion_prf_write_tag[
                    completion_write_lane*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] !=
                 {PHYS_REG_ADDR_WIDTH{1'b0}}) &&
                !completion_packet[`OPENRV64_COMPLETE_ILLEGAL_BIT] &&
                !completion_packet[`OPENRV64_COMPLETE_EXCEPTION_BIT];
            assign completion_storage_ready[completion_write_lane] =
                !completion_prf_write_req[completion_write_lane] ||
                completion_prf_write_ack_r[completion_write_lane];
            assign completion_fire[completion_write_lane] =
                complete_valid[completion_write_lane] &&
                completion_storage_ready[completion_write_lane];
            assign completion_writeback_fire[completion_write_lane] =
                completion_prf_write_req[completion_write_lane] &&
                completion_prf_write_ack_r[completion_write_lane];
            assign exec_complete_ready[completion_write_lane] =
                !complete_valid[completion_write_lane] ||
                !queue_complete_match[completion_write_lane] ||
                completion_storage_ready[completion_write_lane];
        end
    endgenerate
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] next_retire_id;
    wire [SLOT_WIDTH-1:0] next_retire_slot;
    wire queue_post_retire_valid;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] queue_post_retire_id;
    wire [SLOT_WIDTH-1:0] queue_post_retire_slot;
    wire [3*SLOT_WIDTH-1:0] window_retire_slot = queue_retire_slot;

    wire retire_exception;
    wire retire_halt;
    wire retire_irq;
    wire retire_mret;
    wire retire_sret;
    wire retire_fence_i;
    wire retire_sfence_vma;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] retire_cause;
    wire [`RV64_XLEN-1:0] retire_pc;
    wire [`RV64_XLEN-1:0] retire_next_pc;
    wire [`RV64_XLEN-1:0] retire_tval;
    wire [63:0] retire_trace_id;
    wire [`RV64_INSTR_WIDTH-1:0] retire_instr;

    wire [2:0] release_valid;
    wire [2:0] release_uses_rs1;
    wire [2:0] release_uses_rs2;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] release_rs1_addr;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] release_rs2_addr;
    wire [2:0] release_reg_write;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] release_rd_addr;
    wire [2:0] rename_commit_valid;
    wire [3*PHYS_REG_ADDR_WIDTH-1:0] rename_commit_phys;
    wire [2:0] retire_hard;
    genvar rename_commit_lane;
    generate
        for (rename_commit_lane = 0; rename_commit_lane < 3;
             rename_commit_lane = rename_commit_lane + 1) begin :
                g_rename_commit
            assign rename_commit_valid[rename_commit_lane] =
                (RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
                retire_arch_o[rename_commit_lane] &&
                release_reg_write[rename_commit_lane] &&
                (release_rd_addr[
                    rename_commit_lane*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH] != `RV64_REG_X0);
            assign rename_commit_phys[
                rename_commit_lane*PHYS_REG_ADDR_WIDTH +:
                PHYS_REG_ADDR_WIDTH] = queue_retire_record[
                    rename_commit_lane*RETIRE_RECORD_WIDTH +
                    `OPENRV64_RETIRE_ALLOC_NEW_PHYS_LSB +:
                    PHYS_REG_ADDR_WIDTH];
        end
    endgenerate
    reg [2:0] banked_dispatch_retire_valid_q;
    reg [3*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_dispatch_retire_id_q;
    reg [3*SLOT_WIDTH-1:0] banked_dispatch_retire_slot_q;
    reg [2:0] banked_dispatch_retire_uses_rs1_q;
    reg [2:0] banked_dispatch_retire_uses_rs2_q;
    reg [3*`RV64_REG_ADDR_WIDTH-1:0]
        banked_dispatch_retire_rs1_addr_q;
    reg [3*`RV64_REG_ADDR_WIDTH-1:0]
        banked_dispatch_retire_rs2_addr_q;
    reg [2:0] banked_dispatch_retire_reg_write_q;
    reg [3*`RV64_REG_ADDR_WIDTH-1:0]
        banked_dispatch_retire_rd_addr_q;
    reg [2:0] banked_dispatch_retire_hard_q;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_dispatch_next_retire_id_q;
    reg [SLOT_WIDTH-1:0] banked_dispatch_next_retire_slot_q;
    wire [2:0] raw_hazard;
    wire [2:0] waw_hazard;
    wire [2:0] read_port_hazard;

    // The legacy path deliberately clears scoreboard ownership in the same
    // cycle as retirement.  On the conservative banked path that creates a
    // long retire -> issue -> memory-ready -> retire combinational loop and
    // also permits a consumer to launch on the write-response edge.  Delay
    // only the feedback into dispatch by one cycle.  Architectural retirement
    // and all other retire side effects remain on their original edge.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_i) begin
            banked_dispatch_retire_valid_q <= 3'b000;
            banked_dispatch_retire_id_q <=
                {3*`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            banked_dispatch_retire_slot_q <= {3*SLOT_WIDTH{1'b0}};
            banked_dispatch_retire_uses_rs1_q <= 3'b000;
            banked_dispatch_retire_uses_rs2_q <= 3'b000;
            banked_dispatch_retire_rs1_addr_q <=
                {3*`RV64_REG_ADDR_WIDTH{1'b0}};
            banked_dispatch_retire_rs2_addr_q <=
                {3*`RV64_REG_ADDR_WIDTH{1'b0}};
            banked_dispatch_retire_reg_write_q <= 3'b000;
            banked_dispatch_retire_rd_addr_q <=
                {3*`RV64_REG_ADDR_WIDTH{1'b0}};
            banked_dispatch_retire_hard_q <= 3'b000;
            banked_dispatch_next_retire_id_q <=
                {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            banked_dispatch_next_retire_slot_q <=
                {SLOT_WIDTH{1'b0}};
        end else if (BANKED_GPR != 0) begin
            banked_dispatch_retire_valid_q <= release_valid;
            banked_dispatch_retire_id_q <= queue_retire_id;
            banked_dispatch_retire_slot_q <= window_retire_slot;
            banked_dispatch_retire_uses_rs1_q <= release_uses_rs1;
            banked_dispatch_retire_uses_rs2_q <= release_uses_rs2;
            banked_dispatch_retire_rs1_addr_q <= release_rs1_addr;
            banked_dispatch_retire_rs2_addr_q <= release_rs2_addr;
            banked_dispatch_retire_reg_write_q <= release_reg_write;
            banked_dispatch_retire_rd_addr_q <= release_rd_addr;
            banked_dispatch_retire_hard_q <= retire_hard;
            banked_dispatch_next_retire_id_q <= next_retire_id;
            banked_dispatch_next_retire_slot_q <= next_retire_slot;
        end else begin
            banked_dispatch_retire_valid_q <= 3'b000;
        end
    end

    wire [2:0] dispatch_retire_valid = (BANKED_GPR != 0) ?
        banked_dispatch_retire_valid_q : release_valid;
    wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] dispatch_retire_id =
        (BANKED_GPR != 0) ? banked_dispatch_retire_id_q : queue_retire_id;
    wire [3*SLOT_WIDTH-1:0] dispatch_retire_slot =
        (BANKED_GPR != 0) ? banked_dispatch_retire_slot_q :
        window_retire_slot;
    wire [2:0] dispatch_retire_uses_rs1 = (BANKED_GPR != 0) ?
        banked_dispatch_retire_uses_rs1_q : release_uses_rs1;
    wire [2:0] dispatch_retire_uses_rs2 = (BANKED_GPR != 0) ?
        banked_dispatch_retire_uses_rs2_q : release_uses_rs2;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] dispatch_retire_rs1_addr =
        (BANKED_GPR != 0) ? banked_dispatch_retire_rs1_addr_q :
        release_rs1_addr;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] dispatch_retire_rs2_addr =
        (BANKED_GPR != 0) ? banked_dispatch_retire_rs2_addr_q :
        release_rs2_addr;
    wire [2:0] dispatch_retire_reg_write = (BANKED_GPR != 0) ?
        banked_dispatch_retire_reg_write_q : release_reg_write;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] dispatch_retire_rd_addr =
        (BANKED_GPR != 0) ? banked_dispatch_retire_rd_addr_q :
        release_rd_addr;
    wire [2:0] dispatch_retire_hard = (BANKED_GPR != 0) ?
        banked_dispatch_retire_hard_q : retire_hard;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] dispatch_next_retire_id =
        (BANKED_GPR != 0) ? banked_dispatch_next_retire_id_q :
        next_retire_id;
    wire [SLOT_WIDTH-1:0] dispatch_next_retire_slot =
        (BANKED_GPR != 0) ? banked_dispatch_next_retire_slot_q :
        next_retire_slot;

    // The non-speculative issue window may execute conditional branches before
    // the retirement head, but publishes resolution only when the branch
    // retires.  The speculation-window path instead consumes EX0 resolution
    // immediately and selectively discards younger IDs below.  This retire-time
    // resolver remains the recovery path for the non-speculative window.
    localparam integer WINDOW_META_BRANCH =
        `OPENRV64_RETIRE_ALLOC_BRANCH_BIT;
    localparam integer WINDOW_META_JUMP =
        `OPENRV64_RETIRE_ALLOC_JUMP_BIT;
    localparam integer WINDOW_META_PREDICTED_TAKEN =
        `OPENRV64_RETIRE_ALLOC_PREDICTED_TAKEN_BIT;
    localparam integer WINDOW_RESULT_EXCEPTION =
        `OPENRV64_RETIRE_RESULT_EXCEPTION_BIT;
    localparam integer WINDOW_RESULT_NEXT_PC =
        `OPENRV64_RETIRE_RESULT_NEXT_PC_LSB;
    localparam integer COMPLETE_RESULT_INSTR = 233;
    localparam integer COMPLETE_RESULT_NEXT_PC = 265;
    localparam integer COMPLETE_RESULT_PC = 329;
    wire window_resolve0 = release_valid[0] &&
        !queue_retire_commit[
            0*RETIRE_RESULT_WIDTH +
            WINDOW_RESULT_EXCEPTION] &&
        (queue_retire_record[
             0*RETIRE_RECORD_WIDTH + WINDOW_META_BRANCH] ||
         queue_retire_record[
             0*RETIRE_RECORD_WIDTH + WINDOW_META_JUMP]);
    wire window_resolve1 = release_valid[1] &&
        !queue_retire_commit[
            1*RETIRE_RESULT_WIDTH +
            WINDOW_RESULT_EXCEPTION] &&
        (queue_retire_record[
             1*RETIRE_RECORD_WIDTH + WINDOW_META_BRANCH] ||
         queue_retire_record[
             1*RETIRE_RECORD_WIDTH + WINDOW_META_JUMP]);
    wire window_resolve2 = release_valid[2] &&
        !queue_retire_commit[
            2*RETIRE_RESULT_WIDTH +
            WINDOW_RESULT_EXCEPTION] &&
        (queue_retire_record[
             2*RETIRE_RECORD_WIDTH + WINDOW_META_BRANCH] ||
         queue_retire_record[
             2*RETIRE_RECORD_WIDTH + WINDOW_META_JUMP]);
    wire window_branch_resolved = window_resolve0 || window_resolve1 ||
                                  window_resolve2;
    wire [1:0] window_resolve_lane = window_resolve0 ? 2'd0 :
                                     window_resolve1 ? 2'd1 : 2'd2;
    wire [RETIRE_RECORD_WIDTH-1:0] window_resolve_meta =
        queue_retire_record[
            window_resolve_lane*RETIRE_RECORD_WIDTH +:
            RETIRE_RECORD_WIDTH];
    wire [RETIRE_RESULT_WIDTH-1:0]
        window_resolve_result = queue_retire_commit[
            window_resolve_lane*RETIRE_RESULT_WIDTH +:
            RETIRE_RESULT_WIDTH];
    wire [`RV64_XLEN-1:0] window_branch_pc = window_resolve_meta[
        `OPENRV64_RETIRE_ALLOC_PC_LSB +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] window_branch_next_pc = window_resolve_result[
        WINDOW_RESULT_NEXT_PC +: `RV64_XLEN];
    wire window_branch_taken =
        window_branch_next_pc != (window_branch_pc + 64'd4);
    wire window_branch_predicted_taken =
        window_resolve_meta[WINDOW_META_PREDICTED_TAKEN];
    wire window_direction_mispredict = window_branch_resolved &&
        (window_branch_predicted_taken != window_branch_taken);

    // The losing side of a conditional branch becomes cold only when that
    // branch retires.  Resolution can happen much earlier, so this sideband
    // is derived directly from the retirement prefix rather than from the
    // predictor-training or redirect paths.
    genvar retire_age_lane;
    generate
        for (retire_age_lane = 0; retire_age_lane < 3;
             retire_age_lane = retire_age_lane + 1) begin : g_retire_age
            wire [RETIRE_RECORD_WIDTH-1:0] age_meta =
                queue_retire_record[
                    retire_age_lane*RETIRE_RECORD_WIDTH +:
                    RETIRE_RECORD_WIDTH];
            wire [RETIRE_RESULT_WIDTH-1:0] age_result =
                queue_retire_commit[
                    retire_age_lane*RETIRE_RESULT_WIDTH +:
                    RETIRE_RESULT_WIDTH];
            wire [`RV64_XLEN-1:0] age_pc =
                age_meta[
                    `OPENRV64_RETIRE_ALLOC_PC_LSB +: `RV64_XLEN];
            wire [`RV64_XLEN-1:0] age_next_pc =
                age_result[WINDOW_RESULT_NEXT_PC +: `RV64_XLEN];
            wire [`RV64_INSTR_WIDTH-1:0] age_instr =
                age_meta[
                    `OPENRV64_RETIRE_ALLOC_INSTR_LSB +:
                    `RV64_INSTR_WIDTH];
            wire [`RV64_XLEN-1:0] age_fallthrough = age_pc + 64'd4;
            wire [`RV64_XLEN-1:0] age_target =
                age_pc + `RV64_IMM_B(age_instr);
            wire age_taken = age_next_pc != age_fallthrough;
            wire [`RV64_XLEN-1:0] age_loser =
                age_taken ? age_fallthrough : age_target;

            assign branch_retire_age_valid_o[retire_age_lane] =
                release_valid[retire_age_lane] &&
                age_meta[WINDOW_META_BRANCH] &&
                !age_result[WINDOW_RESULT_EXCEPTION] &&
                (age_target[`RV64_XLEN-1:6] !=
                 age_fallthrough[`RV64_XLEN-1:6]);
            assign branch_retire_age_addr_o[
                retire_age_lane*`RV64_XLEN +: `RV64_XLEN] = age_loser;
        end
    endgenerate

    wire free_branch_resolved = |allocation_complete;
    // Architectural completions may be multi-wide.  The existing predictor
    // update port observes the oldest branch; BTFNT itself is stateless.
    wire [1:0] free_branch_lane = allocation_complete[0] ? 2'd0 :
                                  allocation_complete[1] ? 2'd1 : 2'd2;
    wire [RETIRE_META_WIDTH-1:0] free_branch_meta =
        allocation_meta[
            free_branch_lane*RETIRE_META_WIDTH +:
            RETIRE_META_WIDTH];
    wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] free_branch_result =
        allocation_result[
            free_branch_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
    wire [`RV64_XLEN-1:0] free_branch_pc =
        free_branch_result[COMPLETE_RESULT_PC +: `RV64_XLEN];
    wire [`RV64_XLEN-1:0] free_branch_next_pc =
        free_branch_result[COMPLETE_RESULT_NEXT_PC +: `RV64_XLEN];
    wire free_branch_mispredict = |allocation_mispredict;
    wire [1:0] free_mispredict_lane = allocation_mispredict[0] ? 2'd0 :
                                      allocation_mispredict[1] ? 2'd1 : 2'd2;
    wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        free_mispredict_result = allocation_result[
            free_mispredict_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];

    wire speculative_window = (ENABLE_ISSUE_WINDOW != 0) &&
                              (ENABLE_SPECULATION_WINDOW != 0);
    assign redirect_valid_o = free_branch_mispredict ? 1'b1 :
        speculative_window ? exec_redirect_valid :
        (ENABLE_ISSUE_WINDOW != 0) ? window_direction_mispredict :
                                     exec_redirect_valid;
    assign redirect_id_o = free_branch_mispredict ?
        allocation_id[
            free_mispredict_lane*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH] :
        speculative_window ? exec_redirect_id :
        (ENABLE_ISSUE_WINDOW != 0) ?
            queue_retire_id[
                window_resolve_lane*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] : exec_redirect_id;
    assign redirect_target_o = free_branch_mispredict ?
        free_mispredict_result[COMPLETE_RESULT_NEXT_PC +: `RV64_XLEN] :
        speculative_window ? exec_redirect_target :
        (ENABLE_ISSUE_WINDOW != 0) ? window_branch_next_pc :
                                     exec_redirect_target;
    assign branch_resolved_o = free_branch_resolved ? 1'b1 :
        speculative_window ? exec_branch_resolved :
        (ENABLE_ISSUE_WINDOW != 0) ? window_branch_resolved :
                                     exec_branch_resolved;
    assign branch_conditional_o = free_branch_resolved ?
        free_branch_meta[WINDOW_META_BRANCH] :
        speculative_window ? exec_branch_conditional :
        (ENABLE_ISSUE_WINDOW != 0) ?
            window_resolve_meta[WINDOW_META_BRANCH] : exec_branch_conditional;
    assign branch_taken_o = free_branch_resolved ?
        (free_branch_next_pc != (free_branch_pc + 64'd4)) :
        speculative_window ? exec_branch_taken :
        (ENABLE_ISSUE_WINDOW != 0) ? window_branch_taken : exec_branch_taken;
    assign branch_pc_o = free_branch_resolved ? free_branch_pc :
        speculative_window ? exec_branch_pc :
        (ENABLE_ISSUE_WINDOW != 0) ? window_branch_pc : exec_branch_pc;
    assign branch_instr_o = free_branch_resolved ?
        free_branch_result[COMPLETE_RESULT_INSTR +: `RV64_INSTR_WIDTH] :
        speculative_window ? exec_branch_instr :
        (ENABLE_ISSUE_WINDOW != 0) ?
            window_resolve_meta[`OPENRV64_RETIRE_ALLOC_INSTR_LSB +:
                                  `RV64_INSTR_WIDTH] : exec_branch_instr;
    assign branch_id_o = free_branch_resolved ?
        allocation_id[
            free_branch_lane*`OPENRV64_INSTR_ID_WIDTH +:
            `OPENRV64_INSTR_ID_WIDTH] :
        speculative_window ? exec_redirect_id :
        (ENABLE_ISSUE_WINDOW != 0) ?
            queue_retire_id[
                window_resolve_lane*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] : exec_redirect_id;
    assign branch_slot_o = free_branch_resolved ?
        allocation_slot[free_branch_lane*SLOT_WIDTH +: SLOT_WIDTH] :
        speculative_window ? exec_redirect_slot :
        (ENABLE_ISSUE_WINDOW != 0) ?
            window_retire_slot[window_resolve_lane*SLOT_WIDTH +: SLOT_WIDTH] :
            exec_redirect_slot;

    // Predictor training is independent of the scalar redirect/diagnostic
    // resolution above.  Free branches and retirement-window controls can
    // resolve three-wide; the selected policy serializes these updates before
    // writing its direction table.
    wire [2:0] window_train_valid = {
        window_resolve2, window_resolve1, window_resolve0};
    genvar train_lane;
    generate
        for (train_lane = 0; train_lane < 3;
             train_lane = train_lane + 1) begin : g_branch_train
            wire [RETIRE_META_WIDTH-1:0] train_alloc_meta =
                allocation_meta[
                    train_lane*RETIRE_META_WIDTH +:
                    RETIRE_META_WIDTH];
            wire [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                train_alloc_result = allocation_result[
                    train_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
            wire [RETIRE_RECORD_WIDTH-1:0] train_window_meta =
                queue_retire_record[
                    train_lane*RETIRE_RECORD_WIDTH +:
                    RETIRE_RECORD_WIDTH];
            wire [RETIRE_RESULT_WIDTH-1:0]
                train_window_result = queue_retire_commit[
                    train_lane*RETIRE_RESULT_WIDTH +:
                    RETIRE_RESULT_WIDTH];
            wire [`RV64_XLEN-1:0] train_alloc_pc = train_alloc_result[
                COMPLETE_RESULT_PC +: `RV64_XLEN];
            wire [`RV64_XLEN-1:0] train_alloc_next_pc =
                train_alloc_result[COMPLETE_RESULT_NEXT_PC +: `RV64_XLEN];
            wire [`RV64_XLEN-1:0] train_window_pc = train_window_meta[
                `OPENRV64_RETIRE_ALLOC_PC_LSB +: `RV64_XLEN];
            wire [`RV64_XLEN-1:0] train_window_next_pc =
                train_window_result[WINDOW_RESULT_NEXT_PC +: `RV64_XLEN];

            assign branch_train_valid_o[train_lane] = free_branch_resolved ?
                allocation_complete[train_lane] :
                speculative_window ?
                    ((train_lane == 0) ? exec_branch_resolved : 1'b0) :
                (ENABLE_ISSUE_WINDOW != 0) ?
                    window_train_valid[train_lane] :
                    ((train_lane == 0) ? exec_branch_resolved : 1'b0);
            assign branch_train_conditional_o[train_lane] =
                free_branch_resolved ?
                    train_alloc_meta[WINDOW_META_BRANCH] :
                speculative_window ?
                    ((train_lane == 0) ? exec_branch_conditional : 1'b0) :
                (ENABLE_ISSUE_WINDOW != 0) ?
                    train_window_meta[WINDOW_META_BRANCH] :
                    ((train_lane == 0) ? exec_branch_conditional : 1'b0);
            assign branch_train_taken_o[train_lane] = free_branch_resolved ?
                (train_alloc_next_pc != (train_alloc_pc + 64'd4)) :
                speculative_window ?
                    ((train_lane == 0) ? exec_branch_taken : 1'b0) :
                (ENABLE_ISSUE_WINDOW != 0) ?
                    (train_window_next_pc != (train_window_pc + 64'd4)) :
                    ((train_lane == 0) ? exec_branch_taken : 1'b0);
            assign branch_train_pc_o[train_lane*`RV64_XLEN +: `RV64_XLEN] =
                free_branch_resolved ? train_alloc_pc :
                speculative_window ?
                    ((train_lane == 0) ? exec_branch_pc :
                                         {`RV64_XLEN{1'b0}}) :
                (ENABLE_ISSUE_WINDOW != 0) ? train_window_pc :
                    ((train_lane == 0) ? exec_branch_pc :
                                         {`RV64_XLEN{1'b0}});
        end
    endgenerate

    wire [RETIRE_DEPTH-1:0] completed_entry_valid;

    // Remember the youngest allocated producer of each architectural
    // register.  The compact retirement-slot tag qualifies the branch-only
    // live bypass.  RELAX_HAZARDS additionally uses the instruction ID,
    // ready bit, and retained data as its broad producer-result table.  This
    // is deliberately not a physical-register rename file: retirement is
    // still in order and the architectural GPR remains committed state.
    reg [31:0] youngest_owner_valid_q;
    reg [31:0] youngest_owner_ready_q;
    reg [31:0] youngest_owner_load_q;
    reg [32*`OPENRV64_INSTR_ID_WIDTH-1:0] youngest_owner_id_q;
    reg [32*SLOT_WIDTH-1:0] youngest_owner_slot_q;
    reg [32*`RV64_XLEN-1:0] youngest_owner_data_q;
    integer youngest_owner_lane;
    reg [`RV64_REG_ADDR_WIDTH-1:0] youngest_owner_rd;
    wire banked_deferred_pair_recovery;
    wire banked_deferred_follower_reg_write;
    wire [`RV64_REG_ADDR_WIDTH-1:0] banked_deferred_follower_rd;
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_deferred_follower_id;
    wire banked_regload_lane0_fire;
    wire banked_regload_branch_correct_now;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            youngest_owner_valid_q <= 32'd0;
            youngest_owner_ready_q <= 32'd0;
            youngest_owner_load_q <= 32'd0;
        end else if (flush_i ||
                     ((ENABLE_ISSUE_WINDOW != 0) && squash_frontend_i)) begin
            youngest_owner_valid_q <= 32'd0;
            youngest_owner_ready_q <= 32'd0;
            youngest_owner_load_q <= 32'd0;
        end else begin
            // Retirement clears ownership only when the retiring instruction's
            // live queue slot is still the youngest writer.  An older WAW
            // retirement leaves a younger live producer untouched.
            for (youngest_owner_lane = 0; youngest_owner_lane < 3;
                 youngest_owner_lane = youngest_owner_lane + 1) begin
                youngest_owner_rd = release_rd_addr[
                    youngest_owner_lane*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH];
                if (release_valid[youngest_owner_lane] &&
                    release_reg_write[youngest_owner_lane] &&
                    (youngest_owner_rd != `RV64_REG_X0) &&
                    youngest_owner_valid_q[youngest_owner_rd] &&
                    (youngest_owner_slot_q[
                         youngest_owner_rd*SLOT_WIDTH +: SLOT_WIDTH] ==
                     window_retire_slot[
                         youngest_owner_lane*SLOT_WIDTH +: SLOT_WIDTH])) begin
                    youngest_owner_valid_q[youngest_owner_rd] <= 1'b0;
                    youngest_owner_ready_q[youngest_owner_rd] <= 1'b0;
                    youngest_owner_load_q[youngest_owner_rd] <= 1'b0;
                end
            end

            // The deferred branch follower is allocated so its register
            // addresses can be gathered, but it is never offered to execute
            // until the branch prediction is proved.  A wrong prediction
            // therefore removes exactly this unexecuted owner.  Conservative
            // WAW exclusion guarantees there is no hidden older owner of the
            // same architectural destination to restore.
            if (banked_deferred_pair_recovery &&
                banked_deferred_follower_reg_write &&
                (banked_deferred_follower_rd != `RV64_REG_X0) &&
                youngest_owner_valid_q[banked_deferred_follower_rd] &&
                (youngest_owner_id_q[
                     banked_deferred_follower_rd*
                     `OPENRV64_INSTR_ID_WIDTH +:
                     `OPENRV64_INSTR_ID_WIDTH] ==
                 banked_deferred_follower_id)) begin
                youngest_owner_valid_q[banked_deferred_follower_rd] <= 1'b0;
                youngest_owner_ready_q[banked_deferred_follower_rd] <= 1'b0;
                youngest_owner_load_q[banked_deferred_follower_rd] <= 1'b0;
            end

            // A completion publishes only if it belongs to the youngest live
            // producer.  Stale completions from older WAW writers are ignored.
            for (youngest_owner_lane = 0; youngest_owner_lane < 3;
                 youngest_owner_lane = youngest_owner_lane + 1) begin
                youngest_owner_rd = complete_payload[
                    youngest_owner_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_RD_LSB +: `RV64_REG_ADDR_WIDTH];
                if (complete_valid[youngest_owner_lane] &&
                    complete_payload[
                        youngest_owner_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                        `OPENRV64_COMPLETE_REG_WRITE_BIT] &&
                    !complete_payload[
                        youngest_owner_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                        `OPENRV64_COMPLETE_ILLEGAL_BIT] &&
                    !complete_payload[
                        youngest_owner_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                        `OPENRV64_COMPLETE_EXCEPTION_BIT] &&
                    (youngest_owner_rd != `RV64_REG_X0) &&
                    youngest_owner_valid_q[youngest_owner_rd] &&
                    (youngest_owner_id_q[
                         youngest_owner_rd*`OPENRV64_INSTR_ID_WIDTH +:
                         `OPENRV64_INSTR_ID_WIDTH] ==
                     complete_id[
                         youngest_owner_lane*`OPENRV64_INSTR_ID_WIDTH +:
                         `OPENRV64_INSTR_ID_WIDTH])) begin
                    youngest_owner_ready_q[youngest_owner_rd] <= 1'b1;
                    youngest_owner_data_q[
                        youngest_owner_rd*`RV64_XLEN +: `RV64_XLEN] <=
                        complete_payload[
                            youngest_owner_lane*
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                            `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
                end
            end

            // Allocation is ordered youngest-last, so later lanes naturally
            // win if several instructions in one issue group write the same rd.
            for (youngest_owner_lane = 0; youngest_owner_lane < 3;
                 youngest_owner_lane = youngest_owner_lane + 1) begin
                youngest_owner_rd = allocation_meta[
                    youngest_owner_lane*RETIRE_META_WIDTH +
                    35 +: `RV64_REG_ADDR_WIDTH];
                if (allocation_valid[youngest_owner_lane] &&
                    allocation_meta[
                        youngest_owner_lane*RETIRE_META_WIDTH + 17] &&
                    (youngest_owner_rd != `RV64_REG_X0)) begin
                    youngest_owner_valid_q[youngest_owner_rd] <= 1'b1;
                    youngest_owner_ready_q[youngest_owner_rd] <= 1'b0;
                    youngest_owner_load_q[youngest_owner_rd] <=
                        allocation_meta[
                            youngest_owner_lane*RETIRE_META_WIDTH + 16];
                    youngest_owner_id_q[
                        youngest_owner_rd*`OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH] <= allocation_id[
                            youngest_owner_lane*
                            `OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH];
                    youngest_owner_slot_q[
                        youngest_owner_rd*SLOT_WIDTH +: SLOT_WIDTH] <=
                        allocation_slot[
                            youngest_owner_lane*SLOT_WIDTH +: SLOT_WIDTH];
                end
            end

            youngest_owner_valid_q[`RV64_REG_X0] <= 1'b0;
            youngest_owner_ready_q[`RV64_REG_X0] <= 1'b0;
            youngest_owner_load_q[`RV64_REG_X0] <= 1'b0;
        end
    end

    // Dispatch receives only enough metadata to route a dependent instruction
    // back to the completing ALU pipe.  The 64-bit values stay local to EX0 and
    // EX1 and feed their operand muxes directly.
    wire [1:0] local_forward_valid;
    wire [2*`RV64_REG_ADDR_WIDTH-1:0] local_forward_rd_addr;
    assign local_forward_valid[0] = complete_valid[0] &&
        complete_payload[0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                         `OPENRV64_COMPLETE_REG_WRITE_BIT] &&
        !complete_payload[0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_ILLEGAL_BIT] &&
        !complete_payload[0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_EXCEPTION_BIT] &&
        (complete_payload[0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_RD_LSB +:
                          `RV64_REG_ADDR_WIDTH] != `RV64_REG_X0);
    assign local_forward_valid[1] = complete_valid[1] &&
        complete_payload[1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                         `OPENRV64_COMPLETE_REG_WRITE_BIT] &&
        !complete_payload[1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_ILLEGAL_BIT] &&
        !complete_payload[1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_EXCEPTION_BIT] &&
        (complete_payload[1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                          `OPENRV64_COMPLETE_RD_LSB +:
                          `RV64_REG_ADDR_WIDTH] != `RV64_REG_X0);
    assign local_forward_rd_addr[0*`RV64_REG_ADDR_WIDTH +:
                                 `RV64_REG_ADDR_WIDTH] =
        complete_payload[0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                         `OPENRV64_COMPLETE_RD_LSB +:
                         `RV64_REG_ADDR_WIDTH];
    assign local_forward_rd_addr[1*`RV64_REG_ADDR_WIDTH +:
                                 `RV64_REG_ADDR_WIDTH] =
        complete_payload[1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                         `OPENRV64_COMPLETE_RD_LSB +:
                         `RV64_REG_ADDR_WIDTH];

    // Limited forwarding option.  EX0/EX1 values physically present on this
    // cycle's registered completion ports may bypass; a load on MEM0 is
    // captured into the one-entry stage below before it becomes an operand
    // source.  The source mask makes MEM-only (3'b100), ALU-only (3'b011), and
    // combined (3'b111) experiments possible without retaining any
    // retirement-queue result.  This is three tagged 64-bit sources, not the
    // 32-register completion map used by the full-forwarding upper bound.
    wire [2:0] completion_forward_valid_raw;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] completion_forward_rd_addr;
    wire [3*`RV64_XLEN-1:0] completion_forward_data;
    genvar completion_forward_lane;
    generate
        for (completion_forward_lane = 0; completion_forward_lane < 3;
             completion_forward_lane = completion_forward_lane + 1) begin :
                g_completion_forward
            assign completion_forward_valid_raw[completion_forward_lane] =
                complete_valid[completion_forward_lane] &&
                complete_payload[
                    completion_forward_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_REG_WRITE_BIT] &&
                !complete_payload[
                    completion_forward_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_ILLEGAL_BIT] &&
                !complete_payload[
                    completion_forward_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_EXCEPTION_BIT] &&
                (complete_payload[
                    completion_forward_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_RD_LSB +: `RV64_REG_ADDR_WIDTH] !=
                 `RV64_REG_X0);
            assign completion_forward_rd_addr[
                completion_forward_lane*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH] = complete_payload[
                    completion_forward_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_RD_LSB +: `RV64_REG_ADDR_WIDTH];
            assign completion_forward_data[
                completion_forward_lane*`RV64_XLEN +: `RV64_XLEN] =
                complete_payload[
                    completion_forward_lane*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
        end
    endgenerate
    wire [2:0] completion_forward_valid = !flush_i ?
        (completion_forward_valid_raw & COMPLETION_FORWARD_MASK) : 3'b000;
    wire [`RV64_REG_ADDR_WIDTH-1:0] banked_mem_complete_rd =
        completion_forward_rd_addr[
            2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH];
    wire banked_mem_complete_is_load =
        youngest_owner_valid_q[banked_mem_complete_rd] &&
        youngest_owner_load_q[banked_mem_complete_rd] &&
        (youngest_owner_id_q[
             banked_mem_complete_rd*`OPENRV64_INSTR_ID_WIDTH +:
             `OPENRV64_INSTR_ID_WIDTH] ==
         complete_id[2*`OPENRV64_INSTR_ID_WIDTH +:
                     `OPENRV64_INSTR_ID_WIDTH]);
    wire banked_mem_forward_capture = (BANKED_GPR != 0) &&
        !flush_i && !squash_frontend_i &&
        completion_forward_valid_raw[2] &&
        COMPLETION_FORWARD_MASK[2] && banked_mem_complete_is_load;

    // MEM0 completion is combinational with the tagged LSU response.  Feeding
    // that response directly back into strict dispatch can make a new memory
    // issue affect the response-ready path in the same active region.  Keep
    // EX0/EX1 live, but pipeline MEM0 by one cycle before presenting it as an
    // operand source.  This is a one-entry forwarding stage, not retirement
    // state: producer identity is rechecked against the current owner below.
    reg banked_mem_forward_valid_q;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] banked_mem_forward_id_q;
    reg [`RV64_REG_ADDR_WIDTH-1:0] banked_mem_forward_rd_q;
    reg [`RV64_XLEN-1:0] banked_mem_forward_data_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || (BANKED_GPR == 0)) begin
            banked_mem_forward_valid_q <= 1'b0;
            banked_mem_forward_id_q <=
                {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            banked_mem_forward_rd_q <= `RV64_REG_X0;
            banked_mem_forward_data_q <= {`RV64_XLEN{1'b0}};
        end else if (flush_i || squash_frontend_i) begin
            banked_mem_forward_valid_q <= 1'b0;
        end else if (banked_mem_forward_capture) begin
                banked_mem_forward_valid_q <= 1'b1;
                banked_mem_forward_id_q <= complete_id[
                    2*`OPENRV64_INSTR_ID_WIDTH +:
                    `OPENRV64_INSTR_ID_WIDTH];
                banked_mem_forward_rd_q <= completion_forward_rd_addr[
                    2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH];
                banked_mem_forward_data_q <= completion_forward_data[
                    2*`RV64_XLEN +: `RV64_XLEN];
        end else if (!youngest_owner_valid_q[banked_mem_forward_rd_q] ||
                     !youngest_owner_load_q[banked_mem_forward_rd_q] ||
                     (youngest_owner_id_q[
                          banked_mem_forward_rd_q*
                          `OPENRV64_INSTR_ID_WIDTH +:
                          `OPENRV64_INSTR_ID_WIDTH] !=
                      banked_mem_forward_id_q)) begin
            banked_mem_forward_valid_q <= 1'b0;
        end
    end

    wire [3:0] banked_read_mem_forward_valid;
    reg [3:0] banked_read_mem_forwarded_q;
    wire banked_mem_issue_phase =
        (|banked_read_mem_forward_valid) ||
        (|banked_read_mem_forwarded_q);

    // A banked operand may outlive the single cycle in which its producer is
    // present on an EXU completion port.  Qualify the architectural rd with
    // the exact youngest producer ID before the gather latch accepts it.  This
    // prevents a stale completion from an older WAW writer (or abandoned
    // redirect work) from satisfying the new head operands.
    wire [1:0] banked_exu_forward_valid;
    genvar banked_forward_lane;
    generate
        for (banked_forward_lane = 0; banked_forward_lane < 2;
             banked_forward_lane = banked_forward_lane + 1) begin :
                g_banked_completion_forward
            wire [`RV64_REG_ADDR_WIDTH-1:0] banked_forward_rd =
                completion_forward_rd_addr[
                    banked_forward_lane*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH];
            assign banked_exu_forward_valid[banked_forward_lane] =
                (BANKED_GPR != 0) && !squash_frontend_i &&
                !banked_mem_issue_phase &&
                completion_forward_valid[banked_forward_lane] &&
                youngest_owner_valid_q[banked_forward_rd] &&
                (youngest_owner_id_q[
                     banked_forward_rd*`OPENRV64_INSTR_ID_WIDTH +:
                     `OPENRV64_INSTR_ID_WIDTH] ==
                 complete_id[
                     banked_forward_lane*`OPENRV64_INSTR_ID_WIDTH +:
                     `OPENRV64_INSTR_ID_WIDTH]);
        end
    endgenerate
    // Keep MEM0 physically separate from the live EXU vector.  Combining the
    // registered load result with EXU valids lets Verilator regularize them as
    // one feedback signal and recreates the LSU issue/response active-region
    // cycle even though the MEM0 bit itself is registered.
    wire banked_mem_forward_valid = (BANKED_GPR != 0) &&
        banked_mem_forward_valid_q &&
        youngest_owner_valid_q[banked_mem_forward_rd_q] &&
        (youngest_owner_id_q[
             banked_mem_forward_rd_q*`OPENRV64_INSTR_ID_WIDTH +:
             `OPENRV64_INSTR_ID_WIDTH] == banked_mem_forward_id_q);

    // MEM0 is a registered banked-operand source below.  Do not feed it into
    // strict dispatch's live completion path: the LSU response-ready logic and
    // new memory issue decision otherwise share a combinational cycle.
    wire [2:0] dispatch_completion_forward_valid =
        (BANKED_GPR != 0) ?
            {1'b0, banked_exu_forward_valid} :
            completion_forward_valid;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0]
        dispatch_completion_forward_rd_addr =
            (BANKED_GPR != 0) ?
                {`RV64_REG_X0,
                 completion_forward_rd_addr[
                     0 +: 2*`RV64_REG_ADDR_WIDTH]} :
                completion_forward_rd_addr;
    wire [3*`RV64_XLEN-1:0] dispatch_completion_forward_data =
        (BANKED_GPR != 0) ?
            {{`RV64_XLEN{1'b0}},
             completion_forward_data[0 +: 2*`RV64_XLEN]} :
            completion_forward_data;

    // Cheap branch-only bypass.  Retain the youngest-owner check as the
    // qualification used by strict dispatch, whose same-cycle forwarding is
    // still architectural-register based.  The issue-window path additionally
    // carries the exact source-producer ID to EX1; that identity check rejects
    // a younger WAW completion even when this coarse owner check accepts it.
    wire [2:0] branch_completion_forward_valid;
    genvar branch_forward_lane;
    generate
        for (branch_forward_lane = 0; branch_forward_lane < 3;
             branch_forward_lane = branch_forward_lane + 1) begin :
                g_branch_completion_forward
            wire [`RV64_REG_ADDR_WIDTH-1:0] branch_forward_rd =
                completion_forward_rd_addr[
                    branch_forward_lane*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH];
            assign branch_completion_forward_valid[branch_forward_lane] =
                !flush_i &&
                BRANCH_COMPLETION_FORWARD_MASK[branch_forward_lane] &&
                completion_forward_valid_raw[branch_forward_lane] &&
                youngest_owner_valid_q[branch_forward_rd] &&
                (youngest_owner_slot_q[
                     branch_forward_rd*SLOT_WIDTH +: SLOT_WIDTH] ==
                 complete_slot[
                     branch_forward_lane*SLOT_WIDTH +: SLOT_WIDTH]);
        end
    endgenerate

    // The producer-tagged table is the canonical forwarding store.  Retaining
    // one value per architectural destination avoids the old depth-wide scan
    // of every 457-bit retirement result.  The live completion overlay removes
    // the state-update cycle and exact instruction IDs reject stale WAW data.
    reg [31:0] youngest_forward_valid_raw;
    reg [32*`RV64_XLEN-1:0] youngest_forward_data_raw;
    reg [`RV64_REG_ADDR_WIDTH-1:0] youngest_forward_rd;
    integer youngest_forward_port;
    always @* begin
        youngest_forward_valid_raw =
            youngest_owner_valid_q & youngest_owner_ready_q;
        youngest_forward_data_raw = youngest_owner_data_q;
        youngest_forward_rd = `RV64_REG_X0;

        for (youngest_forward_port = 0; youngest_forward_port < 3;
             youngest_forward_port = youngest_forward_port + 1) begin
            youngest_forward_rd = complete_payload[
                youngest_forward_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                `OPENRV64_COMPLETE_RD_LSB +: `RV64_REG_ADDR_WIDTH];
            if (complete_valid[youngest_forward_port] &&
                complete_payload[
                    youngest_forward_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_REG_WRITE_BIT] &&
                !complete_payload[
                    youngest_forward_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_ILLEGAL_BIT] &&
                !complete_payload[
                    youngest_forward_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                    `OPENRV64_COMPLETE_EXCEPTION_BIT] &&
                (youngest_forward_rd != `RV64_REG_X0) &&
                youngest_owner_valid_q[youngest_forward_rd] &&
                (youngest_owner_id_q[
                     youngest_forward_rd*`OPENRV64_INSTR_ID_WIDTH +:
                     `OPENRV64_INSTR_ID_WIDTH] ==
                 complete_id[
                     youngest_forward_port*`OPENRV64_INSTR_ID_WIDTH +:
                     `OPENRV64_INSTR_ID_WIDTH])) begin
                youngest_forward_valid_raw[youngest_forward_rd] = 1'b1;
                youngest_forward_data_raw[
                    youngest_forward_rd*`RV64_XLEN +: `RV64_XLEN] =
                    complete_payload[
                        youngest_forward_port*
                        `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +
                        `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
            end
        end
        youngest_forward_valid_raw[`RV64_REG_X0] = 1'b0;
    end

    wire [31:0] full_forward_valid =
        (ENABLE_FULL_FORWARDING != 0) && !flush_i ?
        youngest_forward_valid_raw : 32'd0;
    wire [32*`RV64_XLEN-1:0] full_forward_data =
        (ENABLE_FULL_FORWARDING != 0) && !flush_i ?
        youngest_forward_data_raw :
        {32*`RV64_XLEN{1'b0}};

    // The banked file accepts at most BANK_READ_PORTS reads per bank per cycle.
    // Ack marks the accepted address phase; data and valid return one cycle
    // later.  Hold only unacknowledged requests stable and qualify each
    // response with the requester's registered ack rather than treating a bare
    // valid as owned.  The legacy PRF remains combinational and bypasses this
    // state entirely.
    reg [3:0] banked_read_done_q;
    reg [3:0] banked_read_forwarded_q;
    reg [4*`RV64_XLEN-1:0] banked_read_data_q;
    reg [3:0] banked_read_pending_q;
    reg [4*PHYS_REG_ADDR_WIDTH-1:0] banked_read_addr_q;
    reg [3:0] banked_read_ack_q;
    reg [3:0] banked_read_response_to_input_q;
    reg [3:0] banked_read_response_to_regload_q;
    reg [3:0] banked_read_response_to_pending_q;
    wire [3:0] banked_read_ready;
    wire [3:0] banked_read_address_ready;
    wire [3:0] banked_read_forward_valid;
    wire [3:0] banked_read_exu_forward_valid;
    wire [4*`RV64_XLEN-1:0] banked_read_forward_data;
    wire [3:0] banked_read_waiting;
    wire [3:0] banked_read_blocked_by_write;
    wire [3:0] banked_read_write_ack_release;

    // The register-load stage decouples the address-gathering dispatch head
    // from the group consuming returned operands at execution.  The register
    // file itself is already pipelined; this state gives its per-port ack
    // pipeline somewhere stable to deliver data while dispatch advances to
    // the next independent group.
    reg banked_regload_valid_q;
    reg [1:0] banked_regload_lane_valid_q;
    reg [2*`OPENRV64_INSTR_ID_WIDTH-1:0] banked_regload_lane_id_q;
    reg [3:0] banked_regload_operand_done_q;
    reg [4*`RV64_XLEN-1:0] banked_regload_operand_data_q;
    reg [3:0] banked_regload_mem_forwarded_q;
    reg banked_regload_hard_q;
    reg banked_regload_control_q;
    reg banked_regload_branch_pair_q;
    reg banked_regload_branch_resolved_q;
    reg banked_regload_branch_correct_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0] banked_regload_pipe_valid_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_regload_pipe_id_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*SLOT_WIDTH-1:0]
        banked_regload_pipe_slot_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*
         `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        banked_regload_pipe_payload_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_src1_producer_valid_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_regload_src1_producer_id_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_src2_producer_valid_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_regload_src2_producer_id_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH-1:0]
        banked_regload_src1_phys_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH-1:0]
        banked_regload_src2_phys_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_pipe_uses_rs1_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_pipe_uses_rs2_q;

    // One queued group absorbs dispatch while the execution-facing regload
    // group is stalled.  This is a real credit buffer: allocation readiness
    // depends on this registered valid bit, never on combinational pipe ready.
    reg banked_regload_pending_valid_q;
    reg [1:0] banked_regload_pending_lane_valid_q;
    reg [2*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_regload_pending_lane_id_q;
    reg [3:0] banked_regload_pending_operand_done_q;
    reg [4*`RV64_XLEN-1:0] banked_regload_pending_operand_data_q;
    reg [3:0] banked_regload_pending_mem_forwarded_q;
    reg banked_regload_pending_hard_q;
    reg banked_regload_pending_control_q;
    reg banked_regload_pending_branch_pair_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_pending_pipe_valid_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_regload_pending_pipe_id_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*SLOT_WIDTH-1:0]
        banked_regload_pending_pipe_slot_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*
         `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        banked_regload_pending_pipe_payload_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_pending_src1_producer_valid_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_regload_pending_src1_producer_id_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_pending_src2_producer_valid_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_regload_pending_src2_producer_id_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH-1:0]
        banked_regload_pending_src1_phys_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*PHYS_REG_ADDR_WIDTH-1:0]
        banked_regload_pending_src2_phys_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_pending_pipe_uses_rs1_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_pending_pipe_uses_rs2_q;

    // Physical rename always uses the six-port, per-requester register-load
    // path.  The legacy four-port gather is coupled to architectural dispatch
    // allocation and cannot safely replace its context while a denied address
    // remains held.  Tomasulo allocation is deliberately decoupled from that
    // architectural gather, even when the issue window is configured strict.
    wire banked_window_regload = (BANKED_GPR != 0) &&
        ((ENABLE_ISSUE_WINDOW != 0) ||
         (RENAME_MODE == `OPENRV64_RENAME_TOMASULO));

    // Compact the issue window's at-most-two accepted physical-pipe packets
    // into the regload stage's two age-ordered lanes.  The full physical-pipe
    // vectors remain intact so execution routing does not need to be rebuilt.
    reg [1:0] banked_regload_ingress_lane_valid;
    reg [2*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_regload_ingress_lane_id;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_ingress_pipe_ready;
    wire banked_regload_ingress_capacity;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_regload_ingress_first_id;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_regload_ingress_second_id;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_regload_ingress_id_difference;
    integer banked_regload_ingress_pipe;
    always @* begin
        banked_regload_ingress_lane_valid = 2'b00;
        banked_regload_ingress_lane_id =
            {2*`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        banked_regload_ingress_first_id =
            {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        banked_regload_ingress_second_id =
            {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        banked_regload_ingress_id_difference =
            {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        for (banked_regload_ingress_pipe = 0;
             banked_regload_ingress_pipe < `OPENRV64_EXEC_PIPE_COUNT;
             banked_regload_ingress_pipe =
                 banked_regload_ingress_pipe + 1) begin
            if (dispatch_pipe_valid[banked_regload_ingress_pipe]) begin
                if (!banked_regload_ingress_lane_valid[0]) begin
                    banked_regload_ingress_lane_valid[0] = 1'b1;
                    banked_regload_ingress_first_id = dispatch_pipe_id[
                        banked_regload_ingress_pipe*
                        `OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH];
                end else begin
                    banked_regload_ingress_lane_valid[1] = 1'b1;
                    banked_regload_ingress_second_id = dispatch_pipe_id[
                        banked_regload_ingress_pipe*
                        `OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH];
                end
            end
        end
        // IDs are monotonically allocated and the live window is smaller than
        // half the ID space.  A positive modular first-minus-second distance
        // means the first collected packet is younger; swap in that case.
        banked_regload_ingress_id_difference =
            banked_regload_ingress_first_id -
            banked_regload_ingress_second_id;
        if (banked_regload_ingress_lane_valid[1] &&
            (banked_regload_ingress_id_difference !=
             {`OPENRV64_INSTR_ID_WIDTH{1'b0}}) &&
            !banked_regload_ingress_id_difference[
                `OPENRV64_INSTR_ID_WIDTH-1]) begin
            banked_regload_ingress_lane_id[
                0 +: `OPENRV64_INSTR_ID_WIDTH] =
                banked_regload_ingress_second_id;
            banked_regload_ingress_lane_id[
                `OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] =
                banked_regload_ingress_first_id;
        end else begin
            banked_regload_ingress_lane_id[
                0 +: `OPENRV64_INSTR_ID_WIDTH] =
                banked_regload_ingress_first_id;
            banked_regload_ingress_lane_id[
                `OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] =
                banked_regload_ingress_second_id;
        end
    end

    reg [4*PHYS_REG_ADDR_WIDTH-1:0]
        banked_regload_active_read_addr;
    reg [3:0] banked_regload_ingress_operand_done;
    reg [4*`RV64_XLEN-1:0]
        banked_regload_ingress_operand_data;
    integer banked_regload_operand_lane;
    integer banked_regload_operand_source;
    integer banked_regload_operand_pipe;
    reg banked_regload_operand_use;
    reg banked_regload_operand_producer;
    reg [PHYS_REG_ADDR_WIDTH-1:0] banked_regload_operand_addr;
    always @* begin
        banked_regload_active_read_addr =
            {4*PHYS_REG_ADDR_WIDTH{1'b0}};
        banked_regload_ingress_operand_done = 4'b1111;
        banked_regload_ingress_operand_data =
            {4*`RV64_XLEN{1'b0}};
        banked_regload_operand_lane = 0;
        banked_regload_operand_source = 0;
        banked_regload_operand_use = 1'b0;
        banked_regload_operand_producer = 1'b0;
        banked_regload_operand_addr =
            {PHYS_REG_ADDR_WIDTH{1'b0}};

        for (banked_regload_operand_lane = 0;
             banked_regload_operand_lane < 2;
             banked_regload_operand_lane =
                 banked_regload_operand_lane + 1) begin
            for (banked_regload_operand_source = 0;
                 banked_regload_operand_source < 2;
                 banked_regload_operand_source =
                     banked_regload_operand_source + 1) begin
                for (banked_regload_operand_pipe = 0;
                     banked_regload_operand_pipe <
                         `OPENRV64_EXEC_PIPE_COUNT;
                     banked_regload_operand_pipe =
                         banked_regload_operand_pipe + 1) begin
                    if (banked_regload_valid_q &&
                        banked_regload_lane_valid_q[
                            banked_regload_operand_lane] &&
                        banked_regload_pipe_valid_q[
                            banked_regload_operand_pipe] &&
                        (banked_regload_pipe_id_q[
                             banked_regload_operand_pipe*
                             `OPENRV64_INSTR_ID_WIDTH +:
                             `OPENRV64_INSTR_ID_WIDTH] ==
                         banked_regload_lane_id_q[
                             banked_regload_operand_lane*
                             `OPENRV64_INSTR_ID_WIDTH +:
                             `OPENRV64_INSTR_ID_WIDTH])) begin
                        banked_regload_operand_use =
                            (banked_regload_operand_source == 0) ?
                            banked_regload_pipe_uses_rs1_q[
                                banked_regload_operand_pipe] :
                            banked_regload_pipe_uses_rs2_q[
                                banked_regload_operand_pipe];
                        banked_regload_operand_producer =
                            (banked_regload_operand_source == 0) ?
                            banked_regload_src1_producer_valid_q[
                                banked_regload_operand_pipe] :
                            banked_regload_src2_producer_valid_q[
                                banked_regload_operand_pipe];
                        banked_regload_operand_addr =
                            (RENAME_MODE ==
                             `OPENRV64_RENAME_TOMASULO) ?
                            ((banked_regload_operand_source == 0) ?
                             banked_regload_src1_phys_q[
                                banked_regload_operand_pipe*
                                PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] :
                             banked_regload_src2_phys_q[
                                banked_regload_operand_pipe*
                                PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH]) :
                            banked_regload_pipe_payload_q[
                                banked_regload_operand_pipe*
                                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                                ((banked_regload_operand_source == 0) ?
                                 237 : 232) +:
                                PHYS_REG_ADDR_WIDTH];
                        if (banked_regload_operand_use &&
                            !banked_regload_operand_producer)
                            banked_regload_active_read_addr[
                                (banked_regload_operand_lane*2 +
                                 banked_regload_operand_source)*
                                PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] =
                                banked_regload_operand_addr;
                    end

                    if (banked_regload_ingress_lane_valid[
                            banked_regload_operand_lane] &&
                        dispatch_pipe_valid[
                            banked_regload_operand_pipe] &&
                        (dispatch_pipe_id[
                             banked_regload_operand_pipe*
                             `OPENRV64_INSTR_ID_WIDTH +:
                             `OPENRV64_INSTR_ID_WIDTH] ==
                         banked_regload_ingress_lane_id[
                             banked_regload_operand_lane*
                             `OPENRV64_INSTR_ID_WIDTH +:
                             `OPENRV64_INSTR_ID_WIDTH])) begin
                        banked_regload_operand_use =
                            (banked_regload_operand_source == 0) ?
                            dispatch_pipe_uses_rs1[
                                banked_regload_operand_pipe] :
                            dispatch_pipe_uses_rs2[
                                banked_regload_operand_pipe];
                        banked_regload_operand_producer =
                            (banked_regload_operand_source == 0) ?
                            dispatch_pipe_src1_producer_valid[
                                banked_regload_operand_pipe] :
                            dispatch_pipe_src2_producer_valid[
                                banked_regload_operand_pipe];
                        banked_regload_operand_addr =
                            (RENAME_MODE ==
                             `OPENRV64_RENAME_TOMASULO) ?
                            ((banked_regload_operand_source == 0) ?
                             dispatch_pipe_src1_phys[
                                banked_regload_operand_pipe*
                                PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] :
                             dispatch_pipe_src2_phys[
                                banked_regload_operand_pipe*
                                PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH]) :
                            dispatch_pipe_payload[
                                banked_regload_operand_pipe*
                                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                                ((banked_regload_operand_source == 0) ?
                                 237 : 232) +: PHYS_REG_ADDR_WIDTH];
                        if (banked_regload_operand_use &&
                            (banked_regload_operand_addr !=
                             {PHYS_REG_ADDR_WIDTH{1'b0}}) &&
                            !banked_regload_operand_producer) begin
                            banked_regload_ingress_operand_done[
                                banked_regload_operand_lane*2 +
                                banked_regload_operand_source] = 1'b0;
                        end else begin
                            banked_regload_ingress_operand_done[
                                banked_regload_operand_lane*2 +
                                banked_regload_operand_source] = 1'b1;
                            if (banked_regload_operand_producer)
                                banked_regload_ingress_operand_data[
                                    (banked_regload_operand_lane*2 +
                                     banked_regload_operand_source)*
                                    `RV64_XLEN +: `RV64_XLEN] =
                                    dispatch_pipe_payload[
                                        banked_regload_operand_pipe*
                                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                                        ((banked_regload_operand_source == 0) ?
                                         168 : 104) +:
                                        `RV64_XLEN];
                        end
                    end
                end
            end
        end
    end

    assign gpr_read_addr = banked_window_regload ?
        banked_independent_read_addr :
        dispatch_gpr_read_addr;

    reg banked_deferred_follower_reg_write_r;
    reg [`RV64_REG_ADDR_WIDTH-1:0] banked_deferred_follower_rd_r;
    integer banked_deferred_follower_pipe;
    always @* begin
        banked_deferred_follower_reg_write_r = 1'b0;
        banked_deferred_follower_rd_r = `RV64_REG_X0;
        for (banked_deferred_follower_pipe = 0;
             banked_deferred_follower_pipe < `OPENRV64_EXEC_PIPE_COUNT;
             banked_deferred_follower_pipe =
                 banked_deferred_follower_pipe + 1) begin
            if (banked_regload_pipe_valid_q[
                    banked_deferred_follower_pipe] &&
                (banked_regload_pipe_id_q[
                     banked_deferred_follower_pipe*
                     `OPENRV64_INSTR_ID_WIDTH +:
                     `OPENRV64_INSTR_ID_WIDTH] ==
                 banked_regload_lane_id_q[
                     `OPENRV64_INSTR_ID_WIDTH +:
                     `OPENRV64_INSTR_ID_WIDTH])) begin
                banked_deferred_follower_reg_write_r =
                    banked_regload_pipe_payload_q[
                        banked_deferred_follower_pipe*
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 17];
                banked_deferred_follower_rd_r =
                    banked_regload_pipe_payload_q[
                        banked_deferred_follower_pipe*
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 35 +:
                        `RV64_REG_ADDR_WIDTH];
            end
        end
    end
    assign banked_deferred_follower_reg_write =
        banked_deferred_follower_reg_write_r;
    assign banked_deferred_follower_rd =
        banked_deferred_follower_rd_r;
    assign banked_deferred_follower_id = banked_regload_lane_id_q[
        `OPENRV64_INSTR_ID_WIDTH +: `OPENRV64_INSTR_ID_WIDTH];
    assign banked_deferred_pair_recovery = (BANKED_GPR != 0) &&
        squash_frontend_i && banked_regload_valid_q &&
        banked_regload_lane_valid_q[1] &&
        banked_regload_branch_pair_q &&
        ((banked_regload_branch_resolved_q &&
          !banked_regload_branch_correct_q) ||
         (!banked_regload_branch_resolved_q &&
          banked_regload_lane0_fire &&
          !banked_regload_branch_correct_now));

    // Redirects stop new address phases.  The legacy grouped requester holds
    // an unacknowledged request until ack.  The issue-window requesters may
    // cancel an unaccepted candidate; accepted reads retain per-port owner
    // state and return one cycle later.  Stop issuing until the register file
    // itself is quiescent.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            banked_gpr_drain_q <= 1'b0;
        else if (BANKED_GPR == 0)
            banked_gpr_drain_q <= 1'b0;
        else if (flush_i || squash_frontend_i)
            banked_gpr_drain_q <= 1'b1;
        else if (banked_gpr_drain_q && !gpr_access_pending)
            banked_gpr_drain_q <= 1'b0;
    end

`ifdef OPENRV64_BANKED_GPR_MAGIC_READS
    // Experimental upper bound: the grant and data phase coincide.  Reads
    // retained at the dispatch input are captured there; reads allocated to
    // the stage or its pending credit are captured by the allocation edge.
    wire [3:0] banked_magic_response_now =
        gpr_read_ack[3:0] & gpr_read_valid[3:0];
    wire [3:0] banked_input_response_now = banked_magic_response_now &
        {4{!banked_window_regload && !(|allocation_valid) && !flush_i &&
            !squash_frontend_i && !banked_gpr_drain_q}};
    wire [3:0] banked_regload_response_now =
        banked_window_regload ? banked_magic_response_now : 4'b0000;
    wire [3:0] banked_regload_pending_response_now = 4'b0000;
`else
    wire [3:0] banked_input_response_now = banked_read_ack_q &
        gpr_read_valid[3:0] & banked_read_response_to_input_q;
    wire [3:0] banked_regload_response_now = banked_read_ack_q &
        gpr_read_valid[3:0] & banked_read_response_to_regload_q;
    wire [3:0] banked_regload_pending_response_now = banked_read_ack_q &
        gpr_read_valid[3:0] & banked_read_response_to_pending_q;
`endif

    genvar banked_read_port;
    generate
        for (banked_read_port = 0; banked_read_port < 4;
             banked_read_port = banked_read_port + 1) begin : g_banked_read
            wire [PHYS_REG_ADDR_WIDTH-1:0] read_addr =
                gpr_read_addr[
                    banked_read_port*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH];
            wire read_zero = read_addr == {PHYS_REG_ADDR_WIDTH{1'b0}};
            wire read_forward_valid;
            wire [`RV64_XLEN-1:0] read_forward_data;
            if (RENAME_MODE == `OPENRV64_RENAME_IDENTITY) begin :
                    g_arch_forward
                reg forward_valid_r;
                reg [`RV64_XLEN-1:0] forward_data_r;
                integer read_forward_lane;
                always @* begin
                    forward_valid_r = 1'b0;
                    forward_data_r = {`RV64_XLEN{1'b0}};
                    for (read_forward_lane = 0; read_forward_lane < 2;
                         read_forward_lane = read_forward_lane + 1) begin
                        if (!forward_valid_r && !banked_window_regload &&
                            banked_exu_forward_valid[read_forward_lane] &&
                            (completion_forward_rd_addr[
                                read_forward_lane*`RV64_REG_ADDR_WIDTH +:
                                `RV64_REG_ADDR_WIDTH] == read_addr)) begin
                            forward_valid_r = 1'b1;
                            forward_data_r = completion_forward_data[
                                read_forward_lane*`RV64_XLEN +:
                                `RV64_XLEN];
                        end
                    end
                end
                assign read_forward_valid = forward_valid_r;
                assign read_forward_data = forward_data_r;
            end else begin : g_phys_forward
                assign read_forward_valid = 1'b0;
                assign read_forward_data = {`RV64_XLEN{1'b0}};
            end
            reg read_write_ack_match;
            integer read_write_ack_lane;
            always @* begin
                read_write_ack_match = 1'b0;
                for (read_write_ack_lane = 0; read_write_ack_lane < 2;
                     read_write_ack_lane = read_write_ack_lane + 1) begin
                    if (gpr_write[read_write_ack_lane] &&
                        gpr_write_ack[read_write_ack_lane] &&
                        (gpr_write_addr[
                             read_write_ack_lane*PHYS_REG_ADDR_WIDTH +:
                             PHYS_REG_ADDR_WIDTH] == read_addr))
                        read_write_ack_match = 1'b1;
                end
            end
            wire read_mem_forward_valid =
                (RENAME_MODE == `OPENRV64_RENAME_IDENTITY) &&
                !banked_window_regload &&
                banked_mem_forward_valid &&
                (banked_mem_forward_rd_q == read_addr);
            wire [`RV64_XLEN-1:0] read_capture_data =
                read_forward_valid ? read_forward_data :
                banked_mem_forward_data_q;
            wire read_capture_valid = read_forward_valid ||
                                      read_mem_forward_valid;
            wire read_response_now =
`ifdef OPENRV64_BANKED_GPR_MAGIC_READS
                banked_magic_response_now[banked_read_port];
`else
                banked_input_response_now[banked_read_port];
`endif
            wire read_blocked = !banked_window_regload && !read_zero &&
                !banked_read_done_q[banked_read_port] &&
                !read_capture_valid && !read_write_ack_match &&
                (((RENAME_MODE == `OPENRV64_RENAME_IDENTITY) &&
                  write_busy_o[read_addr]) ||
                 ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
                  !dispatch_gpr_read_ready[banked_read_port]));
            wire read_start = (BANKED_GPR != 0) &&
                !flush_i && !squash_frontend_i && !banked_gpr_drain_q &&
                !read_zero && !read_blocked &&
                !read_capture_valid &&
                !banked_read_done_q[banked_read_port] &&
                !banked_read_pending_q[banked_read_port] &&
                !(banked_window_regload &&
                  banked_read_ack_q[banked_read_port]) &&
                !(banked_read_ack_q[banked_read_port] &&
                  banked_read_response_to_input_q[banked_read_port]);

            assign banked_read_forward_valid[banked_read_port] =
                read_forward_valid;
            assign banked_read_mem_forward_valid[banked_read_port] =
                read_mem_forward_valid;
            assign banked_read_forward_data[
                banked_read_port*`RV64_XLEN +: `RV64_XLEN] =
                read_capture_data;
            assign banked_read_blocked_by_write[banked_read_port] =
                read_blocked;
            assign banked_read_write_ack_release[banked_read_port] =
                read_write_ack_match && !read_zero &&
                !banked_read_done_q[banked_read_port] &&
                !read_capture_valid;
            assign banked_read_waiting[banked_read_port] =
                !read_zero && !read_blocked &&
                !banked_read_done_q[banked_read_port] &&
                !read_response_now && !read_capture_valid;

            assign banked_legacy_read_req[banked_read_port] =
                banked_read_pending_q[banked_read_port] || read_start;
            assign banked_legacy_storage_read_addr[
                banked_read_port*PHYS_REG_ADDR_WIDTH +:
                PHYS_REG_ADDR_WIDTH] =
                banked_read_pending_q[banked_read_port] ?
                banked_read_addr_q[
                    banked_read_port*PHYS_REG_ADDR_WIDTH +:
                    PHYS_REG_ADDR_WIDTH] : read_addr;
            assign banked_read_ready[banked_read_port] = read_zero ||
                banked_read_done_q[banked_read_port] ||
                read_response_now || read_forward_valid ||
                read_mem_forward_valid;
            assign banked_read_address_ready[banked_read_port] =
                banked_read_ready[banked_read_port] ||
                gpr_read_ack[banked_read_port];
            assign dispatch_gpr_read_data[
                banked_read_port*`RV64_XLEN +: `RV64_XLEN] =
                (BANKED_GPR == 0) ? gpr_read_data[
                    banked_read_port*`RV64_XLEN +: `RV64_XLEN] :
                banked_read_done_q[banked_read_port] ?
                    banked_read_data_q[
                        banked_read_port*`RV64_XLEN +: `RV64_XLEN] :
                read_response_now ?
                    gpr_read_data[
                        banked_read_port*`RV64_XLEN +: `RV64_XLEN] :
                read_capture_valid ? read_capture_data :
                {`RV64_XLEN{1'b0}};
        end
    endgenerate

    wire [3:0] banked_regload_operand_ready =
        banked_regload_operand_done_q | banked_regload_response_now;
    wire [1:0] banked_regload_lane_operands_ready = {
        &banked_regload_operand_ready[3:2],
        &banked_regload_operand_ready[1:0]
    };

    // Issue each independent lane as soon as its operands and selected pipe
    // are ready, rather than waiting for the whole captured group atomically.
    // Retirement still enforces architectural order, and dispatch has already
    // rejected same-group dependencies and control-barrier followers.  This is
    // also necessary when an ordered MEM lane is retained behind an older ALU:
    // making either lane's valid depend on the other's ready creates a
    // combinational ready/valid loop through the execution pipes.
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_lane0_pipe_mask;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_lane1_pipe_mask;
    genvar banked_regload_map_pipe;
    generate
        for (banked_regload_map_pipe = 0;
             banked_regload_map_pipe < `OPENRV64_EXEC_PIPE_COUNT;
             banked_regload_map_pipe =
                 banked_regload_map_pipe + 1) begin :
                g_banked_regload_pipe_map
            assign banked_regload_lane0_pipe_mask[
                banked_regload_map_pipe] =
                banked_regload_pipe_valid_q[banked_regload_map_pipe] &&
                (banked_regload_pipe_id_q[
                     banked_regload_map_pipe*
                     `OPENRV64_INSTR_ID_WIDTH +:
                     `OPENRV64_INSTR_ID_WIDTH] ==
                 banked_regload_lane_id_q[
                     0 +: `OPENRV64_INSTR_ID_WIDTH]);
            assign banked_regload_lane1_pipe_mask[
                banked_regload_map_pipe] =
                banked_regload_pipe_valid_q[banked_regload_map_pipe] &&
                (banked_regload_pipe_id_q[
                     banked_regload_map_pipe*
                     `OPENRV64_INSTR_ID_WIDTH +:
                     `OPENRV64_INSTR_ID_WIDTH] ==
                 banked_regload_lane_id_q[
                     `OPENRV64_INSTR_ID_WIDTH +:
                     `OPENRV64_INSTR_ID_WIDTH]);
        end
    endgenerate
    wire [1:0] banked_regload_lane_pipe_present = {
        |banked_regload_lane1_pipe_mask,
        |banked_regload_lane0_pipe_mask
    };
    // This is a registered valid/data boundary.  Do not make valid depend on
    // redirect or execution ready: a resolving branch would otherwise feed
    // its own redirect back into issue, and a MEM offer would feed LSU ready
    // back into valid.  Selective recovery poisons younger issued work on the
    // redirect edge, preserves older unissued lanes, and drains every
    // acknowledged or held RF request before any preserved context is reused.
    wire banked_regload_lane0_offer_eligible = (BANKED_GPR != 0) &&
        banked_regload_valid_q && banked_regload_lane_valid_q[0] &&
        banked_regload_lane_operands_ready[0] &&
        banked_regload_lane_pipe_present[0] &&
        !flush_i && !banked_gpr_drain_q;
    wire banked_regload_lane1_offer_eligible = (BANKED_GPR != 0) &&
        banked_regload_valid_q && banked_regload_lane_valid_q[1] &&
        banked_regload_lane_operands_ready[1] &&
        banked_regload_lane_pipe_present[1] &&
        !flush_i && !banked_gpr_drain_q;
    wire banked_regload_complete;
    wire banked_gather_addresses_ready = !banked_gpr_drain_q &&
        (&banked_read_address_ready);
    assign banked_regload_ingress_capacity =
        banked_window_regload && !banked_gpr_drain_q &&
        !banked_regload_pending_valid_q &&
        (!banked_regload_valid_q || !banked_regload_hard_q ||
         (banked_window_regload && banked_regload_control_q)) &&
        !flush_i && !squash_frontend_i;
    assign banked_regload_ingress_pipe_ready =
        {`OPENRV64_EXEC_PIPE_COUNT{banked_regload_ingress_capacity}};
    // The issue-window path is owned by the independent requester below.
    // Keep this legacy group state exclusively for the non-window backend.
    wire banked_regload_window_capture = 1'b0;
    wire banked_regload_capture_valid = banked_window_regload ?
        banked_regload_window_capture : (|allocation_valid);
    wire [1:0] banked_regload_capture_lane_valid =
        banked_window_regload ? banked_regload_ingress_lane_valid :
        allocation_valid[1:0];
    wire [2*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_regload_capture_lane_id = banked_window_regload ?
            banked_regload_ingress_lane_id :
            allocation_id[2*`OPENRV64_INSTR_ID_WIDTH-1:0];
    // Do not feed execution readiness back into dispatch admission.  A free
    // pending slot is the credit for one complete two-lane group.  The legacy
    // non-window path keeps hard operations strict; the speculative issue
    // window admits younger read-only operand gathers and poisons them on a
    // redirect.  Architectural GPR writes occur only at retirement.
    wire banked_dispatch_allocation_ready = allocation_ready &&
        !banked_regload_pending_valid_q &&
        (!banked_regload_valid_q || !banked_regload_hard_q) &&
        ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) ||
         banked_gather_addresses_ready) &&
        !flush_i && !squash_frontend_i;
    wire banked_regload_allocation_to_stage =
        banked_regload_capture_valid &&
        (!banked_regload_valid_q ||
         (banked_regload_complete &&
          (!banked_regload_hard_q ||
           (banked_window_regload && banked_regload_control_q))));
    wire banked_regload_allocation_to_pending =
        banked_regload_capture_valid &&
        !banked_regload_allocation_to_stage;
    wire banked_regload_promote_pending =
        banked_regload_pending_valid_q &&
        (!banked_regload_valid_q ||
         (banked_regload_complete &&
          (!banked_regload_hard_q ||
           (banked_window_regload && banked_regload_control_q))));
    wire banked_read_context_replace = banked_window_regload ?
        (banked_regload_allocation_to_stage ||
         banked_regload_promote_pending) :
        (|allocation_valid);

    wire [4*`RV64_XLEN-1:0] banked_regload_operand_data;
    genvar banked_regload_operand;
    generate
        for (banked_regload_operand = 0; banked_regload_operand < 4;
             banked_regload_operand = banked_regload_operand + 1) begin :
                g_banked_regload_operand
            assign banked_regload_operand_data[
                banked_regload_operand*`RV64_XLEN +: `RV64_XLEN] =
                banked_regload_operand_done_q[banked_regload_operand] ?
                banked_regload_operand_data_q[
                    banked_regload_operand*`RV64_XLEN +: `RV64_XLEN] :
                banked_regload_response_now[banked_regload_operand] ?
                gpr_read_data[
                    banked_regload_operand*`RV64_XLEN +: `RV64_XLEN] :
                {`RV64_XLEN{1'b0}};
        end
    endgenerate

    wire [3:0] banked_regload_pending_operand_ready =
        banked_regload_pending_operand_done_q |
        banked_regload_pending_response_now;
    wire [4*`RV64_XLEN-1:0] banked_regload_pending_operand_data;
    genvar banked_regload_pending_operand;
    generate
        for (banked_regload_pending_operand = 0;
             banked_regload_pending_operand < 4;
             banked_regload_pending_operand =
                 banked_regload_pending_operand + 1) begin :
                g_banked_regload_pending_operand
            assign banked_regload_pending_operand_data[
                banked_regload_pending_operand*`RV64_XLEN +:
                `RV64_XLEN] =
                banked_regload_pending_operand_done_q[
                    banked_regload_pending_operand] ?
                banked_regload_pending_operand_data_q[
                    banked_regload_pending_operand*`RV64_XLEN +:
                    `RV64_XLEN] :
                banked_regload_pending_response_now[
                    banked_regload_pending_operand] ?
                gpr_read_data[
                    banked_regload_pending_operand*`RV64_XLEN +:
                    `RV64_XLEN] :
                {`RV64_XLEN{1'b0}};
        end
    endgenerate

    reg [`OPENRV64_EXEC_PIPE_COUNT*
         `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        banked_regload_pipe_payload;
    integer banked_regload_patch_pipe;
    integer banked_regload_patch_lane;
    always @* begin
        banked_regload_pipe_payload = banked_regload_pipe_payload_q;
        for (banked_regload_patch_pipe = 0;
             banked_regload_patch_pipe < `OPENRV64_EXEC_PIPE_COUNT;
             banked_regload_patch_pipe = banked_regload_patch_pipe + 1) begin
            for (banked_regload_patch_lane = 0;
                 banked_regload_patch_lane < 2;
                 banked_regload_patch_lane =
                     banked_regload_patch_lane + 1) begin
                if (banked_regload_lane_valid_q[
                        banked_regload_patch_lane] &&
                    (banked_regload_pipe_id_q[
                         banked_regload_patch_pipe*
                         `OPENRV64_INSTR_ID_WIDTH +:
                         `OPENRV64_INSTR_ID_WIDTH] ==
                     banked_regload_lane_id_q[
                         banked_regload_patch_lane*
                         `OPENRV64_INSTR_ID_WIDTH +:
                         `OPENRV64_INSTR_ID_WIDTH])) begin
                    banked_regload_pipe_payload[
                        banked_regload_patch_pipe*
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 168 +:
                        `RV64_XLEN] = banked_regload_operand_data[
                            (banked_regload_patch_lane*2+0)*
                            `RV64_XLEN +: `RV64_XLEN];
                    banked_regload_pipe_payload[
                        banked_regload_patch_pipe*
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 104 +:
                        `RV64_XLEN] = banked_regload_operand_data[
                            (banked_regload_patch_lane*2+1)*
                            `RV64_XLEN +: `RV64_XLEN];
                end
            end
        end
    end

    // Dispatch chooses a provisional physical lane before the registered
    // operands return.  Once this stage owns the transaction, an ordinary
    // base ALU instruction can use either EX0 or EX1.  Retarget it when the
    // selected ALU has no base-operation capacity and the peer does.  The
    // separate availability sideband is payload-independent; pipe_ready is
    // not, and using pipe_ready for this decision would create a route ->
    // payload -> ready -> route combinational loop.
    function automatic banked_base_alu_payload;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            banked_base_alu_payload =
                (payload[34:32] == `RV64_ALU_EXT_BASE) &&
                (payload[31:27] != `RV64_ALU_OP_INVALID) &&
                !payload[16] && !payload[15] && !payload[14] &&
                !payload[13] && !payload[10] && !payload[9] &&
                !payload[8] && !payload[7] && !payload[6] &&
                !payload[5] && !payload[4];
        end
    endfunction

    function automatic banked_pairable_eq_payload;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        reg [`RV64_BR_OP_WIDTH-1:0] branch_op;
        begin
            branch_op = payload[18 +: `RV64_BR_OP_WIDTH];
            banked_pairable_eq_payload =
                (ENABLE_EQ_BRANCH_PAIRING != 0) &&
                payload[14] && !payload[8] && !payload[5] &&
                !payload[4] && !payload[41] &&
                ((branch_op == `RV64_BR_OP_BEQ) ||
                 (branch_op == `RV64_BR_OP_BNE));
        end
    endfunction

    function automatic banked_hard_payload;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            banked_hard_payload =
                payload[14] || payload[13] || payload[10] ||
                payload[9] || payload[8] || payload[7] ||
                payload[6] || payload[5] || payload[4];
        end
    endfunction

    function automatic banked_control_payload;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            banked_control_payload = payload[14] || payload[13];
        end
    endfunction

    // True when candidate is later than reference in the modular instruction
    // ID space.  The live backend is much smaller than half the namespace, so
    // the sign bit of candidate-reference disambiguates wraparound.
    function automatic banked_id_is_younger;
        input [`OPENRV64_INSTR_ID_WIDTH-1:0] candidate;
        input [`OPENRV64_INSTR_ID_WIDTH-1:0] reference;
        reg [`OPENRV64_INSTR_ID_WIDTH-1:0] distance;
        begin
            distance = candidate - reference;
            banked_id_is_younger =
                (distance != {`OPENRV64_INSTR_ID_WIDTH{1'b0}}) &&
                !distance[`OPENRV64_INSTR_ID_WIDTH-1];
        end
    endfunction

    // Independent issue-window register-load pipeline.
    //
    // Each selected instruction owns one atomic pair of logical RF ports for
    // its address phase.  The pair number is the selector's age rank, so up to
    // three instructions can arbitrate six reads without a shared group-valid
    // credit.  Once both required reads are granted, scheduler ready is the
    // instruction-level ack.  Metadata is retained per execution pipe while
    // the corresponding data returns one cycle later.  An occupied execution
    // pipe backpressures only a new instruction targeting that pipe.
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_valid_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_independent_id_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*SLOT_WIDTH-1:0]
        banked_independent_slot_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*
         `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        banked_independent_payload_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_src1_producer_valid_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_independent_src1_producer_id_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_src2_producer_valid_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_independent_src2_producer_id_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_uses_rs1_q;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_uses_rs2_q;
    reg [2*`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_operand_done_q;
    reg [2*`OPENRV64_EXEC_PIPE_COUNT*`RV64_XLEN-1:0]
        banked_independent_operand_data_q;

    // An accepted RF address carries its execution-pipe and instruction-ID
    // ownership through the delayed data phase.  ID qualification makes a
    // poisoned redirect response harmless even if its physical port is
    // immediately reused after the file becomes quiescent.
    reg [5:0] banked_independent_response_owner_valid_q;
    reg [6*2-1:0] banked_independent_response_owner_pipe_q;
    reg [6*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_independent_response_owner_id_q;
    reg [5:0] banked_independent_response_poison_q;

    // A withheld address phase is retained per atomic requester pair.  This
    // is a retry skid, not a global group lock: other pairs remain free to
    // accept one transaction per cycle.
    reg [2:0] banked_independent_held_valid_q;
    reg [5:0] banked_independent_held_req_q;
    reg [6*PHYS_REG_ADDR_WIDTH-1:0]
        banked_independent_held_addr_q;
    reg [3*2-1:0] banked_independent_held_pipe_q;
    reg [3*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_independent_held_id_q;

    reg [5:0] banked_independent_read_req;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_candidate_enabled;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_candidate_need_rs1;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_candidate_need_rs2;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_pipe_ready;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_pair_accepted;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_candidate_request_valid;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_candidate_from_held;
    reg [`OPENRV64_EXEC_PIPE_COUNT*2-1:0]
        banked_independent_candidate_group;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_accept = dispatch_pipe_valid &
                                    banked_independent_pipe_ready;

    reg [2*`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_response_now;
    reg [2*`OPENRV64_EXEC_PIPE_COUNT*`RV64_XLEN-1:0]
        banked_independent_response_data;
    wire [2*`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_operand_ready =
            banked_independent_operand_done_q |
            banked_independent_response_now;
    reg [2*`OPENRV64_EXEC_PIPE_COUNT*`RV64_XLEN-1:0]
        banked_independent_operand_data;
    reg [`OPENRV64_EXEC_PIPE_COUNT*
         `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        banked_independent_issue_payload;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_pipe_offer;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_pipe_fire =
            banked_independent_pipe_offer & pipe_ready;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_output_capacity =
            ~banked_independent_valid_q |
            banked_independent_pipe_fire;

    integer banked_independent_candidate_pipe;
    integer banked_independent_candidate_rank;
    integer banked_independent_candidate_group_scan;
    reg [PHYS_REG_ADDR_WIDTH-1:0]
        banked_independent_candidate_rs1;
    reg [PHYS_REG_ADDR_WIDTH-1:0]
        banked_independent_candidate_rs2;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_independent_candidate_id;
    always @* begin
        banked_independent_read_req = 6'b000000;
        banked_independent_read_addr =
            {6*PHYS_REG_ADDR_WIDTH{1'b0}};
        banked_independent_candidate_enabled =
            dispatch_pipe_candidate_valid;
        banked_independent_candidate_need_rs1 =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        banked_independent_candidate_need_rs2 =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        banked_independent_candidate_request_valid =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        banked_independent_candidate_from_held =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        banked_independent_candidate_group =
            {`OPENRV64_EXEC_PIPE_COUNT*2{1'b0}};
        banked_independent_candidate_rank = 0;
        banked_independent_candidate_rs1 =
            {PHYS_REG_ADDR_WIDTH{1'b0}};
        banked_independent_candidate_rs2 =
            {PHYS_REG_ADDR_WIDTH{1'b0}};
        banked_independent_candidate_id =
            {`OPENRV64_INSTR_ID_WIDTH{1'b0}};

        // Retained, unacknowledged transactions own their physical pair until
        // grant.  They continue through redirect drain; a killed transaction
        // is poisoned when its address is finally accepted.
        for (banked_independent_candidate_group_scan = 0;
             banked_independent_candidate_group_scan < 3;
             banked_independent_candidate_group_scan =
                 banked_independent_candidate_group_scan + 1) begin
            if (banked_independent_held_valid_q[
                    banked_independent_candidate_group_scan]) begin
                banked_independent_read_req[
                    banked_independent_candidate_group_scan*2 +: 2] =
                    banked_independent_held_req_q[
                        banked_independent_candidate_group_scan*2 +: 2];
                banked_independent_read_addr[
                    (banked_independent_candidate_group_scan*2)*
                    PHYS_REG_ADDR_WIDTH +: 2*PHYS_REG_ADDR_WIDTH] =
                    banked_independent_held_addr_q[
                        (banked_independent_candidate_group_scan*2)*
                        PHYS_REG_ADDR_WIDTH +: 2*PHYS_REG_ADDR_WIDTH];
            end
        end

        // The issue window's secondary-memory valid is intentionally coupled
        // to the primary memory ready.  Do not launch its RF transaction
        // speculatively; it becomes the primary candidate on the next cycle.
        // EX0, EX1, and one memory instruction still admit three-wide.
        if (dispatch_pipe_candidate_valid[`OPENRV64_EXEC_PIPE_MEM0] &&
            dispatch_pipe_candidate_valid[`OPENRV64_EXEC_PIPE_MEM1]) begin
            if (dispatch_pipe_age_rank[
                    `OPENRV64_EXEC_PIPE_MEM0*2 +: 2] <
                dispatch_pipe_age_rank[
                    `OPENRV64_EXEC_PIPE_MEM1*2 +: 2])
                banked_independent_candidate_enabled[
                    `OPENRV64_EXEC_PIPE_MEM1] = 1'b0;
            else
                banked_independent_candidate_enabled[
                    `OPENRV64_EXEC_PIPE_MEM0] = 1'b0;
        end

        // Drive address requests independently of their combinational grants.
        // This is what breaks the previous ready -> group-valid feedback loop.
        for (banked_independent_candidate_pipe = 0;
             banked_independent_candidate_pipe <
                 `OPENRV64_EXEC_PIPE_COUNT;
             banked_independent_candidate_pipe =
                 banked_independent_candidate_pipe + 1) begin
            banked_independent_candidate_rank = dispatch_pipe_age_rank[
                banked_independent_candidate_pipe*2 +: 2];
            banked_independent_candidate_id = dispatch_pipe_id[
                banked_independent_candidate_pipe*
                `OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH];
            banked_independent_candidate_group[
                banked_independent_candidate_pipe*2 +: 2] =
                banked_independent_candidate_rank[1:0];
            for (banked_independent_candidate_group_scan = 0;
                 banked_independent_candidate_group_scan < 3;
                 banked_independent_candidate_group_scan =
                     banked_independent_candidate_group_scan + 1) begin
                if (banked_independent_held_valid_q[
                        banked_independent_candidate_group_scan] &&
                    (banked_independent_held_id_q[
                         banked_independent_candidate_group_scan*
                         `OPENRV64_INSTR_ID_WIDTH +:
                         `OPENRV64_INSTR_ID_WIDTH] ==
                     banked_independent_candidate_id)) begin
                    banked_independent_candidate_from_held[
                        banked_independent_candidate_pipe] = 1'b1;
                    banked_independent_candidate_group[
                        banked_independent_candidate_pipe*2 +: 2] =
                        banked_independent_candidate_group_scan[1:0];
                end
            end
            banked_independent_candidate_rs1 =
                (RENAME_MODE == `OPENRV64_RENAME_TOMASULO) ?
                dispatch_pipe_src1_phys[
                    banked_independent_candidate_pipe*
                    PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] :
                dispatch_pipe_payload[
                    banked_independent_candidate_pipe*
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 237 +:
                    PHYS_REG_ADDR_WIDTH];
            banked_independent_candidate_rs2 =
                (RENAME_MODE == `OPENRV64_RENAME_TOMASULO) ?
                dispatch_pipe_src2_phys[
                    banked_independent_candidate_pipe*
                    PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] :
                dispatch_pipe_payload[
                    banked_independent_candidate_pipe*
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 232 +:
                    PHYS_REG_ADDR_WIDTH];

            if (banked_independent_candidate_enabled[
                    banked_independent_candidate_pipe] &&
                banked_independent_output_capacity[
                    banked_independent_candidate_pipe] &&
                !banked_gpr_drain_q && !flush_i &&
                !squash_frontend_i) begin
                if (banked_independent_candidate_from_held[
                        banked_independent_candidate_pipe]) begin
                    banked_independent_candidate_request_valid[
                        banked_independent_candidate_pipe] = 1'b1;
                end else if (!banked_independent_held_valid_q[
                                 banked_independent_candidate_rank]) begin
                    banked_independent_candidate_request_valid[
                        banked_independent_candidate_pipe] = 1'b1;
                    banked_independent_candidate_need_rs1[
                        banked_independent_candidate_pipe] =
                        dispatch_pipe_uses_rs1[
                            banked_independent_candidate_pipe] &&
                        !dispatch_pipe_src1_producer_valid[
                            banked_independent_candidate_pipe] &&
                        (banked_independent_candidate_rs1 !=
                         {PHYS_REG_ADDR_WIDTH{1'b0}});
                    banked_independent_candidate_need_rs2[
                        banked_independent_candidate_pipe] =
                        dispatch_pipe_uses_rs2[
                            banked_independent_candidate_pipe] &&
                        !dispatch_pipe_src2_producer_valid[
                            banked_independent_candidate_pipe] &&
                        (banked_independent_candidate_rs2 !=
                         {PHYS_REG_ADDR_WIDTH{1'b0}});
                    banked_independent_read_addr[
                        (banked_independent_candidate_rank*2+0)*
                        PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] =
                        banked_independent_candidate_rs1;
                    banked_independent_read_addr[
                        (banked_independent_candidate_rank*2+1)*
                        PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH] =
                        banked_independent_candidate_rs2;
                    banked_independent_read_req[
                        banked_independent_candidate_rank*2+0] =
                        banked_independent_candidate_need_rs1[
                            banked_independent_candidate_pipe];
                    banked_independent_read_req[
                        banked_independent_candidate_rank*2+1] =
                        banked_independent_candidate_need_rs2[
                            banked_independent_candidate_pipe];
                end
            end
        end

    end

    // Keep address presentation and grant consumption in separate
    // combinational processes.  The request process above must be wholly
    // independent of ack; otherwise an SRAM-style combinational grant creates
    // a request -> grant -> request cycle even when procedural ordering makes
    // the intended dataflow look feed-forward.
    integer banked_independent_ready_pipe;
    integer banked_independent_ready_rank;
    always @* begin
        banked_independent_pipe_ready =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        banked_independent_pair_accepted =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        banked_independent_ready_rank = 0;

        // The register file grants both requested members of a pair or
        // neither.  No-source and fully-forwarded instructions synthesize an
        // immediate address-phase ack without consuming a bank port.
        for (banked_independent_ready_pipe = 0;
             banked_independent_ready_pipe <
                 `OPENRV64_EXEC_PIPE_COUNT;
             banked_independent_ready_pipe =
                 banked_independent_ready_pipe + 1) begin
            banked_independent_ready_rank =
                banked_independent_candidate_group[
                    banked_independent_ready_pipe*2 +: 2];
            if (banked_independent_candidate_enabled[
                    banked_independent_ready_pipe] &&
                banked_independent_candidate_request_valid[
                    banked_independent_ready_pipe] &&
                banked_independent_output_capacity[
                    banked_independent_ready_pipe] &&
                !banked_gpr_drain_q && !flush_i &&
                !squash_frontend_i) begin
                banked_independent_pair_accepted[
                    banked_independent_ready_pipe] =
                    (!banked_independent_read_req[
                         banked_independent_ready_rank*2+0] ||
                     gpr_read_ack[
                         banked_independent_ready_rank*2+0]) &&
                    (!banked_independent_read_req[
                         banked_independent_ready_rank*2+1] ||
                     gpr_read_ack[
                         banked_independent_ready_rank*2+1]);
                banked_independent_pipe_ready[
                    banked_independent_ready_pipe] =
                    banked_independent_pair_accepted[
                        banked_independent_ready_pipe];
            end
        end
    end

    integer banked_independent_held_state_group;
    integer banked_independent_held_state_pipe;
    integer banked_independent_held_state_port;
    integer banked_independent_held_state_candidate_group;
    reg banked_independent_held_state_accepted;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || (BANKED_GPR == 0)) begin
            banked_independent_held_valid_q <= 3'b000;
            banked_independent_held_req_q <= 6'b000000;
            banked_independent_held_addr_q <=
                {6*PHYS_REG_ADDR_WIDTH{1'b0}};
            banked_independent_held_pipe_q <= 6'b000000;
            banked_independent_held_id_q <=
                {3*`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            banked_independent_response_poison_q <= 6'b000000;
        end else begin
            banked_independent_response_poison_q <=
                banked_independent_response_poison_q & ~gpr_read_valid;

            for (banked_independent_held_state_group = 0;
                 banked_independent_held_state_group < 3;
                 banked_independent_held_state_group =
                     banked_independent_held_state_group + 1) begin
                if (banked_independent_held_valid_q[
                        banked_independent_held_state_group]) begin
                    banked_independent_held_state_accepted = 1'b0;
                    for (banked_independent_held_state_pipe = 0;
                         banked_independent_held_state_pipe <
                             `OPENRV64_EXEC_PIPE_COUNT;
                         banked_independent_held_state_pipe =
                             banked_independent_held_state_pipe + 1) begin
                        if (banked_independent_accept[
                                banked_independent_held_state_pipe] &&
                            banked_independent_candidate_from_held[
                                banked_independent_held_state_pipe] &&
                            (banked_independent_candidate_group[
                                 banked_independent_held_state_pipe*2 +: 2] ==
                             banked_independent_held_state_group[1:0]))
                            banked_independent_held_state_accepted = 1'b1;
                    end
                    if ((banked_independent_held_req_q[
                             banked_independent_held_state_group*2 +: 2] !=
                         2'b00) &&
                        ((banked_independent_held_req_q[
                              banked_independent_held_state_group*2 +: 2] &
                          gpr_read_ack[
                              banked_independent_held_state_group*2 +: 2]) ==
                         banked_independent_held_req_q[
                             banked_independent_held_state_group*2 +: 2])) begin
                        banked_independent_held_valid_q[
                            banked_independent_held_state_group] <= 1'b0;
                        if (!banked_independent_held_state_accepted)
                            banked_independent_response_poison_q[
                                banked_independent_held_state_group*2 +: 2] <=
                                banked_independent_held_req_q[
                                    banked_independent_held_state_group*2 +: 2];
                    end
                end else begin
                    // Capture a newly withheld pair at the same edge that
                    // would otherwise allow the selector to change its port.
                    for (banked_independent_held_state_pipe = 0;
                         banked_independent_held_state_pipe <
                             `OPENRV64_EXEC_PIPE_COUNT;
                         banked_independent_held_state_pipe =
                             banked_independent_held_state_pipe + 1) begin
                        banked_independent_held_state_candidate_group =
                            banked_independent_candidate_group[
                                banked_independent_held_state_pipe*2 +: 2];
                        if (banked_independent_candidate_request_valid[
                                banked_independent_held_state_pipe] &&
                            !banked_independent_candidate_from_held[
                                banked_independent_held_state_pipe] &&
                            (banked_independent_held_state_candidate_group ==
                             banked_independent_held_state_group) &&
                            (banked_independent_read_req[
                                 banked_independent_held_state_group*2 +: 2] !=
                             2'b00) &&
                            !banked_independent_pair_accepted[
                                banked_independent_held_state_pipe]) begin
                            banked_independent_held_valid_q[
                                banked_independent_held_state_group] <= 1'b1;
                            banked_independent_held_req_q[
                                banked_independent_held_state_group*2 +: 2] <=
                                banked_independent_read_req[
                                    banked_independent_held_state_group*2 +: 2];
                            banked_independent_held_addr_q[
                                (banked_independent_held_state_group*2)*
                                PHYS_REG_ADDR_WIDTH +:
                                2*PHYS_REG_ADDR_WIDTH] <=
                                banked_independent_read_addr[
                                    (banked_independent_held_state_group*2)*
                                    PHYS_REG_ADDR_WIDTH +:
                                    2*PHYS_REG_ADDR_WIDTH];
                            banked_independent_held_pipe_q[
                                banked_independent_held_state_group*2 +: 2] <=
                                banked_independent_held_state_pipe[1:0];
                            banked_independent_held_id_q[
                                banked_independent_held_state_group*
                                `OPENRV64_INSTR_ID_WIDTH +:
                                `OPENRV64_INSTR_ID_WIDTH] <= dispatch_pipe_id[
                                    banked_independent_held_state_pipe*
                                    `OPENRV64_INSTR_ID_WIDTH +:
                                    `OPENRV64_INSTR_ID_WIDTH];
                        end
                    end
                end
            end
        end
    end

    integer banked_independent_response_port;
    integer banked_independent_response_pipe;
    integer banked_independent_response_operand;
    always @* begin
        banked_independent_response_now =
            {2*`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        banked_independent_response_data =
            {2*`OPENRV64_EXEC_PIPE_COUNT*`RV64_XLEN{1'b0}};
        banked_independent_response_pipe = 0;
        banked_independent_response_operand = 0;
        for (banked_independent_response_port = 0;
             banked_independent_response_port < 6;
             banked_independent_response_port =
                 banked_independent_response_port + 1) begin
            banked_independent_response_pipe =
                banked_independent_response_owner_pipe_q[
                    banked_independent_response_port*2 +: 2];
            banked_independent_response_operand =
                banked_independent_response_pipe*2 +
                (banked_independent_response_port & 1);
            if (gpr_read_valid[banked_independent_response_port] &&
                banked_independent_response_owner_valid_q[
                    banked_independent_response_port] &&
                banked_independent_valid_q[
                    banked_independent_response_pipe] &&
                (banked_independent_id_q[
                     banked_independent_response_pipe*
                     `OPENRV64_INSTR_ID_WIDTH +:
                     `OPENRV64_INSTR_ID_WIDTH] ==
                 banked_independent_response_owner_id_q[
                     banked_independent_response_port*
                     `OPENRV64_INSTR_ID_WIDTH +:
                     `OPENRV64_INSTR_ID_WIDTH])) begin
                banked_independent_response_now[
                    banked_independent_response_operand] = 1'b1;
                banked_independent_response_data[
                    banked_independent_response_operand*`RV64_XLEN +:
                    `RV64_XLEN] = gpr_read_data[
                        banked_independent_response_port*`RV64_XLEN +:
                        `RV64_XLEN];
            end
        end
    end

    integer banked_independent_data_operand;
    integer banked_independent_offer_pipe;
    always @* begin
        banked_independent_operand_data =
            banked_independent_operand_data_q;
        for (banked_independent_data_operand = 0;
             banked_independent_data_operand <
                 2*`OPENRV64_EXEC_PIPE_COUNT;
             banked_independent_data_operand =
                 banked_independent_data_operand + 1) begin
            if (!banked_independent_operand_done_q[
                    banked_independent_data_operand] &&
                banked_independent_response_now[
                    banked_independent_data_operand])
                banked_independent_operand_data[
                    banked_independent_data_operand*`RV64_XLEN +:
                    `RV64_XLEN] = banked_independent_response_data[
                        banked_independent_data_operand*`RV64_XLEN +:
                        `RV64_XLEN];
        end

        banked_independent_issue_payload =
            banked_independent_payload_q;
        banked_independent_pipe_offer =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        for (banked_independent_offer_pipe = 0;
             banked_independent_offer_pipe <
                 `OPENRV64_EXEC_PIPE_COUNT;
             banked_independent_offer_pipe =
                 banked_independent_offer_pipe + 1) begin
            banked_independent_issue_payload[
                banked_independent_offer_pipe*
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 168 +:
                `RV64_XLEN] = banked_independent_operand_data[
                    (banked_independent_offer_pipe*2+0)*`RV64_XLEN +:
                    `RV64_XLEN];
            banked_independent_issue_payload[
                banked_independent_offer_pipe*
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 104 +:
                `RV64_XLEN] = banked_independent_operand_data[
                    (banked_independent_offer_pipe*2+1)*`RV64_XLEN +:
                    `RV64_XLEN];
            banked_independent_pipe_offer[
                banked_independent_offer_pipe] =
                banked_independent_valid_q[
                    banked_independent_offer_pipe] &&
                banked_independent_operand_ready[
                    banked_independent_offer_pipe*2+0] &&
                banked_independent_operand_ready[
                    banked_independent_offer_pipe*2+1] &&
                !banked_gpr_drain_q && !flush_i;
        end
    end

    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_independent_redirect_survivor;
    genvar banked_independent_survivor_pipe;
    generate
        for (banked_independent_survivor_pipe = 0;
             banked_independent_survivor_pipe <
                 `OPENRV64_EXEC_PIPE_COUNT;
             banked_independent_survivor_pipe =
                 banked_independent_survivor_pipe + 1) begin :
                g_banked_independent_survivor
            wire [`OPENRV64_INSTR_ID_WIDTH-1:0] state_id =
                banked_independent_id_q[
                    banked_independent_survivor_pipe*
                    `OPENRV64_INSTR_ID_WIDTH +:
                    `OPENRV64_INSTR_ID_WIDTH];
            assign banked_independent_redirect_survivor[
                banked_independent_survivor_pipe] =
                banked_independent_valid_q[
                    banked_independent_survivor_pipe] &&
                !banked_independent_pipe_fire[
                    banked_independent_survivor_pipe] &&
                (state_id != exec_redirect_id) &&
                !banked_id_is_younger(state_id, exec_redirect_id);
        end
    endgenerate

    integer banked_independent_state_pipe;
    integer banked_independent_state_port;
    integer banked_independent_owner_port;
    integer banked_independent_state_operand;
    integer banked_independent_state_rank;
    reg [PHYS_REG_ADDR_WIDTH-1:0]
        banked_independent_state_source_addr;
    reg banked_independent_state_source_use;
    reg banked_independent_state_source_forwarded;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            banked_independent_valid_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_independent_operand_done_q <=
                {2*`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_independent_operand_data_q <=
                {2*`OPENRV64_EXEC_PIPE_COUNT*`RV64_XLEN{1'b0}};
            banked_independent_response_owner_valid_q <= 6'b000000;
        end else if ((BANKED_GPR == 0) || flush_i) begin
            banked_independent_valid_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_independent_operand_done_q <=
                {2*`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_independent_response_owner_valid_q <= 6'b000000;
        end else if (squash_frontend_i) begin
            banked_independent_valid_q <=
                banked_independent_redirect_survivor;
            for (banked_independent_state_pipe = 0;
                 banked_independent_state_pipe <
                     `OPENRV64_EXEC_PIPE_COUNT;
                 banked_independent_state_pipe =
                     banked_independent_state_pipe + 1) begin
                for (banked_independent_state_operand = 0;
                     banked_independent_state_operand < 2;
                     banked_independent_state_operand =
                         banked_independent_state_operand + 1) begin
                    if (banked_independent_redirect_survivor[
                            banked_independent_state_pipe]) begin
                        banked_independent_operand_done_q[
                            banked_independent_state_pipe*2 +
                            banked_independent_state_operand] <=
                            banked_independent_operand_ready[
                                banked_independent_state_pipe*2 +
                                banked_independent_state_operand];
                        if (banked_independent_response_now[
                                banked_independent_state_pipe*2 +
                                banked_independent_state_operand])
                            banked_independent_operand_data_q[
                                (banked_independent_state_pipe*2 +
                                 banked_independent_state_operand)*
                                `RV64_XLEN +: `RV64_XLEN] <=
                                banked_independent_response_data[
                                    (banked_independent_state_pipe*2 +
                                     banked_independent_state_operand)*
                                    `RV64_XLEN +: `RV64_XLEN];
                    end else begin
                        banked_independent_operand_done_q[
                            banked_independent_state_pipe*2 +
                            banked_independent_state_operand] <= 1'b0;
                    end
                end
            end
            for (banked_independent_state_port = 0;
                 banked_independent_state_port < 6;
                 banked_independent_state_port =
                     banked_independent_state_port + 1) begin
                if (gpr_read_valid[banked_independent_state_port] ||
                    (banked_independent_response_owner_id_q[
                         banked_independent_state_port*
                         `OPENRV64_INSTR_ID_WIDTH +:
                         `OPENRV64_INSTR_ID_WIDTH] == exec_redirect_id) ||
                    banked_id_is_younger(
                        banked_independent_response_owner_id_q[
                            banked_independent_state_port*
                            `OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH],
                        exec_redirect_id))
                    banked_independent_response_owner_valid_q[
                        banked_independent_state_port] <= 1'b0;
            end
        end else begin
            // Retain a returned operand if its execution pipe cannot consume
            // the instruction on the response cycle.
            for (banked_independent_state_operand = 0;
                 banked_independent_state_operand <
                     2*`OPENRV64_EXEC_PIPE_COUNT;
                 banked_independent_state_operand =
                     banked_independent_state_operand + 1) begin
                if (banked_independent_response_now[
                        banked_independent_state_operand]) begin
                    banked_independent_operand_done_q[
                        banked_independent_state_operand] <= 1'b1;
                    banked_independent_operand_data_q[
                        banked_independent_state_operand*`RV64_XLEN +:
                        `RV64_XLEN] <= banked_independent_response_data[
                            banked_independent_state_operand*`RV64_XLEN +:
                            `RV64_XLEN];
                end
            end

            for (banked_independent_state_pipe = 0;
                 banked_independent_state_pipe <
                     `OPENRV64_EXEC_PIPE_COUNT;
                 banked_independent_state_pipe =
                     banked_independent_state_pipe + 1) begin
                if (banked_independent_pipe_fire[
                        banked_independent_state_pipe]) begin
                    banked_independent_valid_q[
                        banked_independent_state_pipe] <= 1'b0;
                    banked_independent_operand_done_q[
                        banked_independent_state_pipe*2 +: 2] <= 2'b00;
                end

                if (banked_independent_accept[
                        banked_independent_state_pipe]) begin
                    banked_independent_valid_q[
                        banked_independent_state_pipe] <= 1'b1;
                    banked_independent_id_q[
                        banked_independent_state_pipe*
                        `OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH] <= dispatch_pipe_id[
                            banked_independent_state_pipe*
                            `OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH];
                    banked_independent_slot_q[
                        banked_independent_state_pipe*SLOT_WIDTH +:
                        SLOT_WIDTH] <= dispatch_pipe_slot[
                            banked_independent_state_pipe*SLOT_WIDTH +:
                            SLOT_WIDTH];
                    banked_independent_payload_q[
                        banked_independent_state_pipe*
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] <=
                        dispatch_pipe_payload[
                            banked_independent_state_pipe*
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
                    banked_independent_src1_producer_valid_q[
                        banked_independent_state_pipe] <=
                        dispatch_pipe_src1_producer_valid[
                            banked_independent_state_pipe];
                    banked_independent_src1_producer_id_q[
                        banked_independent_state_pipe*
                        `OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH] <=
                        dispatch_pipe_src1_producer_id[
                            banked_independent_state_pipe*
                            `OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH];
                    banked_independent_src2_producer_valid_q[
                        banked_independent_state_pipe] <=
                        dispatch_pipe_src2_producer_valid[
                            banked_independent_state_pipe];
                    banked_independent_src2_producer_id_q[
                        banked_independent_state_pipe*
                        `OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH] <=
                        dispatch_pipe_src2_producer_id[
                            banked_independent_state_pipe*
                            `OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH];
                    banked_independent_uses_rs1_q[
                        banked_independent_state_pipe] <=
                        dispatch_pipe_uses_rs1[
                            banked_independent_state_pipe];
                    banked_independent_uses_rs2_q[
                        banked_independent_state_pipe] <=
                        dispatch_pipe_uses_rs2[
                            banked_independent_state_pipe];

                    for (banked_independent_state_operand = 0;
                         banked_independent_state_operand < 2;
                         banked_independent_state_operand =
                             banked_independent_state_operand + 1) begin
                        banked_independent_state_source_addr =
                            (RENAME_MODE == `OPENRV64_RENAME_TOMASULO) ?
                            ((banked_independent_state_operand == 0) ?
                             dispatch_pipe_src1_phys[
                                banked_independent_state_pipe*
                                PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH] :
                             dispatch_pipe_src2_phys[
                                banked_independent_state_pipe*
                                PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH]) :
                            dispatch_pipe_payload[
                                banked_independent_state_pipe*
                                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                                ((banked_independent_state_operand == 0) ?
                                 237 : 232) +: PHYS_REG_ADDR_WIDTH];
                        banked_independent_state_source_use =
                            (banked_independent_state_operand == 0) ?
                            dispatch_pipe_uses_rs1[
                                banked_independent_state_pipe] :
                            dispatch_pipe_uses_rs2[
                                banked_independent_state_pipe];
                        banked_independent_state_source_forwarded =
                            (banked_independent_state_operand == 0) ?
                            dispatch_pipe_src1_producer_valid[
                                banked_independent_state_pipe] :
                            dispatch_pipe_src2_producer_valid[
                                banked_independent_state_pipe];
                        banked_independent_operand_done_q[
                            banked_independent_state_pipe*2 +
                            banked_independent_state_operand] <=
                            !banked_independent_state_source_use ||
                            banked_independent_state_source_forwarded ||
                            (banked_independent_state_source_addr ==
                             {PHYS_REG_ADDR_WIDTH{1'b0}});
                        banked_independent_operand_data_q[
                            (banked_independent_state_pipe*2 +
                             banked_independent_state_operand)*`RV64_XLEN +:
                            `RV64_XLEN] <=
                            banked_independent_state_source_forwarded ?
                            dispatch_pipe_payload[
                                banked_independent_state_pipe*
                                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                                ((banked_independent_state_operand == 0) ?
                                 168 : 104) +: `RV64_XLEN] :
                            {`RV64_XLEN{1'b0}};
                    end
                end
            end

            // Consume old responses and install same-cycle address ownership
            // for the next data phase.  The later assignment intentionally
            // wins when one port returns old data and accepts a new address.
            for (banked_independent_state_port = 0;
                 banked_independent_state_port < 6;
                 banked_independent_state_port =
                     banked_independent_state_port + 1) begin
                if (gpr_read_valid[banked_independent_state_port])
                    banked_independent_response_owner_valid_q[
                        banked_independent_state_port] <= 1'b0;
            end
            for (banked_independent_state_pipe = 0;
                 banked_independent_state_pipe <
                     `OPENRV64_EXEC_PIPE_COUNT;
                 banked_independent_state_pipe =
                     banked_independent_state_pipe + 1) begin
                if (banked_independent_accept[
                        banked_independent_state_pipe]) begin
                    banked_independent_state_rank =
                        banked_independent_candidate_group[
                            banked_independent_state_pipe*2 +: 2];
                    for (banked_independent_state_operand = 0;
                         banked_independent_state_operand < 2;
                         banked_independent_state_operand =
                             banked_independent_state_operand + 1) begin
                        banked_independent_owner_port =
                            banked_independent_state_rank*2 +
                            banked_independent_state_operand;
                        if (banked_independent_read_req[
                                banked_independent_owner_port] &&
                            gpr_read_ack[
                                banked_independent_owner_port]) begin
                            banked_independent_response_owner_valid_q[
                                banked_independent_owner_port] <= 1'b1;
                            banked_independent_response_owner_pipe_q[
                                banked_independent_owner_port*2 +: 2] <=
                                banked_independent_state_pipe[1:0];
                            banked_independent_response_owner_id_q[
                                banked_independent_owner_port*
                                `OPENRV64_INSTR_ID_WIDTH +:
                                `OPENRV64_INSTR_ID_WIDTH] <=
                                dispatch_pipe_id[
                                    banked_independent_state_pipe*
                                    `OPENRV64_INSTR_ID_WIDTH +:
                                    `OPENRV64_INSTR_ID_WIDTH];
                        end
                    end
                end
            end
        end
    end

    wire banked_regload_allocation_branch_pair =
        !banked_window_regload && allocation_valid[1] &&
        dispatch_pipe_valid[1] &&
        (dispatch_pipe_id[
             1*`OPENRV64_INSTR_ID_WIDTH +:
             `OPENRV64_INSTR_ID_WIDTH] ==
         allocation_id[0 +: `OPENRV64_INSTR_ID_WIDTH]) &&
        banked_pairable_eq_payload(dispatch_pipe_payload[
            1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]) &&
        // The barrier scoreboard is a single bit, not a hard-instruction
        // count.  Do not provisionally place a second hard operation behind
        // the branch; otherwise retiring the branch could release that
        // follower's persistent ordering state one cycle early.
        !banked_hard_payload(allocation_meta[
            1*RETIRE_META_WIDTH +:
            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]);

    reg banked_regload_window_capture_hard;
    reg banked_regload_window_capture_control;
    integer banked_regload_window_hard_pipe;
    always @* begin
        banked_regload_window_capture_hard = 1'b0;
        banked_regload_window_capture_control = 1'b0;
        for (banked_regload_window_hard_pipe = 0;
             banked_regload_window_hard_pipe <
                 `OPENRV64_EXEC_PIPE_COUNT;
             banked_regload_window_hard_pipe =
                 banked_regload_window_hard_pipe + 1) begin
            if (dispatch_pipe_valid[banked_regload_window_hard_pipe] &&
                banked_hard_payload(dispatch_pipe_payload[
                    banked_regload_window_hard_pipe*
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]))
                banked_regload_window_capture_hard = 1'b1;
            if (dispatch_pipe_valid[banked_regload_window_hard_pipe] &&
                banked_control_payload(dispatch_pipe_payload[
                    banked_regload_window_hard_pipe*
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]))
                banked_regload_window_capture_control = 1'b1;
        end
    end

    wire [1:0] banked_regload_lane_fire;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_pipe_fire_mask;

    // A redirect can split either two-lane group: an older instruction may
    // share it with the resolving branch or with younger speculative work.
    // Keep only older, not-already-issued lanes.  The resolving instruction
    // itself has fired in order to produce the redirect, so it must not be
    // replayed.  Register reads are speculative; architectural GPR writes
    // remain retirement-only.
    wire banked_regload_lane0_redirect_survivor =
        banked_regload_lane_valid_q[0] &&
        !banked_regload_lane_fire[0] &&
        (banked_regload_lane_id_q[
             0 +: `OPENRV64_INSTR_ID_WIDTH] != exec_redirect_id) &&
        !banked_id_is_younger(
            banked_regload_lane_id_q[
                0 +: `OPENRV64_INSTR_ID_WIDTH],
            exec_redirect_id);
    wire banked_regload_lane1_redirect_survivor =
        banked_regload_lane_valid_q[1] &&
        !banked_regload_lane_fire[1] &&
        (banked_regload_lane_id_q[
             `OPENRV64_INSTR_ID_WIDTH +:
             `OPENRV64_INSTR_ID_WIDTH] != exec_redirect_id) &&
        !banked_id_is_younger(
            banked_regload_lane_id_q[
                `OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH],
            exec_redirect_id);
    wire [1:0] banked_regload_redirect_lane_survivor = {
        banked_regload_lane1_redirect_survivor,
        banked_regload_lane0_redirect_survivor
    };
    wire [3:0] banked_regload_redirect_operand_survivor = {
        {2{banked_regload_lane1_redirect_survivor}},
        {2{banked_regload_lane0_redirect_survivor}}
    };

    wire banked_regload_pending_lane0_redirect_survivor =
        banked_regload_pending_lane_valid_q[0] &&
        (banked_regload_pending_lane_id_q[
             0 +: `OPENRV64_INSTR_ID_WIDTH] != exec_redirect_id) &&
        !banked_id_is_younger(
            banked_regload_pending_lane_id_q[
                0 +: `OPENRV64_INSTR_ID_WIDTH],
            exec_redirect_id);
    wire banked_regload_pending_lane1_redirect_survivor =
        banked_regload_pending_lane_valid_q[1] &&
        (banked_regload_pending_lane_id_q[
             `OPENRV64_INSTR_ID_WIDTH +:
             `OPENRV64_INSTR_ID_WIDTH] != exec_redirect_id) &&
        !banked_id_is_younger(
            banked_regload_pending_lane_id_q[
                `OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH],
            exec_redirect_id);
    wire [1:0] banked_regload_pending_redirect_lane_survivor = {
        banked_regload_pending_lane1_redirect_survivor,
        banked_regload_pending_lane0_redirect_survivor
    };
    wire [3:0] banked_regload_pending_redirect_operand_survivor = {
        {2{banked_regload_pending_lane1_redirect_survivor}},
        {2{banked_regload_pending_lane0_redirect_survivor}}
    };

    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_redirect_pipe_survivor;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_pending_redirect_pipe_survivor;
    genvar banked_regload_redirect_pipe;
    generate
        for (banked_regload_redirect_pipe = 0;
             banked_regload_redirect_pipe < `OPENRV64_EXEC_PIPE_COUNT;
             banked_regload_redirect_pipe =
                 banked_regload_redirect_pipe + 1) begin :
                g_banked_regload_redirect_pipe
            wire [`OPENRV64_INSTR_ID_WIDTH-1:0] active_id =
                banked_regload_pipe_id_q[
                    banked_regload_redirect_pipe*
                    `OPENRV64_INSTR_ID_WIDTH +:
                    `OPENRV64_INSTR_ID_WIDTH];
            wire [`OPENRV64_INSTR_ID_WIDTH-1:0] pending_id =
                banked_regload_pending_pipe_id_q[
                    banked_regload_redirect_pipe*
                    `OPENRV64_INSTR_ID_WIDTH +:
                    `OPENRV64_INSTR_ID_WIDTH];
            assign banked_regload_redirect_pipe_survivor[
                banked_regload_redirect_pipe] =
                banked_regload_pipe_valid_q[
                    banked_regload_redirect_pipe] &&
                !banked_regload_pipe_fire_mask[
                    banked_regload_redirect_pipe] &&
                (active_id != exec_redirect_id) &&
                !banked_id_is_younger(active_id, exec_redirect_id);
            assign banked_regload_pending_redirect_pipe_survivor[
                banked_regload_redirect_pipe] =
                banked_regload_pending_pipe_valid_q[
                    banked_regload_redirect_pipe] &&
                (pending_id != exec_redirect_id) &&
                !banked_id_is_younger(pending_id, exec_redirect_id);
        end
    endgenerate

    reg banked_regload_redirect_hard;
    reg banked_regload_redirect_control;
    reg banked_regload_pending_redirect_hard;
    reg banked_regload_pending_redirect_control;
    integer banked_regload_redirect_class_pipe;
    always @* begin
        banked_regload_redirect_hard = 1'b0;
        banked_regload_redirect_control = 1'b0;
        banked_regload_pending_redirect_hard = 1'b0;
        banked_regload_pending_redirect_control = 1'b0;
        for (banked_regload_redirect_class_pipe = 0;
             banked_regload_redirect_class_pipe <
                 `OPENRV64_EXEC_PIPE_COUNT;
             banked_regload_redirect_class_pipe =
                 banked_regload_redirect_class_pipe + 1) begin
            if (banked_regload_redirect_pipe_survivor[
                    banked_regload_redirect_class_pipe]) begin
                if (banked_hard_payload(banked_regload_pipe_payload_q[
                        banked_regload_redirect_class_pipe*
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]))
                    banked_regload_redirect_hard = 1'b1;
                if (banked_control_payload(banked_regload_pipe_payload_q[
                        banked_regload_redirect_class_pipe*
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]))
                    banked_regload_redirect_control = 1'b1;
            end
            if (banked_regload_pending_redirect_pipe_survivor[
                    banked_regload_redirect_class_pipe]) begin
                if (banked_hard_payload(
                        banked_regload_pending_pipe_payload_q[
                            banked_regload_redirect_class_pipe*
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]))
                    banked_regload_pending_redirect_hard = 1'b1;
                if (banked_control_payload(
                        banked_regload_pending_pipe_payload_q[
                            banked_regload_redirect_class_pipe*
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]))
                    banked_regload_pending_redirect_control = 1'b1;
            end
        end
    end

    wire banked_regload_lane0_flexible =
        (banked_regload_lane0_pipe_mask[0] &&
         banked_base_alu_payload(banked_regload_pipe_payload[
             0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
             `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH])) ||
        (banked_regload_lane0_pipe_mask[1] &&
         banked_base_alu_payload(banked_regload_pipe_payload[
             1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
             `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]));
    wire banked_regload_lane1_flexible =
        (banked_regload_lane1_pipe_mask[0] &&
         banked_base_alu_payload(banked_regload_pipe_payload[
             0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
             `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH])) ||
        (banked_regload_lane1_pipe_mask[1] &&
         banked_base_alu_payload(banked_regload_pipe_payload[
             1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
             `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]));
    wire [1:0] banked_regload_lane0_alu_source =
        banked_regload_lane0_pipe_mask[1:0];
    wire [1:0] banked_regload_lane1_alu_source =
        banked_regload_lane1_pipe_mask[1:0];
    wire [1:0] banked_regload_lane0_alu_alternate =
        {banked_regload_lane0_alu_source[0],
         banked_regload_lane0_alu_source[1]};
    wire [1:0] banked_regload_lane1_alu_alternate =
        {banked_regload_lane1_alu_source[0],
         banked_regload_lane1_alu_source[1]};
    wire banked_regload_lane0_reroute =
        banked_regload_lane0_offer_eligible &&
        banked_regload_lane0_flexible &&
        !(|(banked_regload_lane0_alu_source & base_alu_available)) &&
        (|(banked_regload_lane0_alu_alternate & base_alu_available));
    wire banked_regload_lane1_reroute =
        banked_regload_lane1_offer_eligible &&
        banked_regload_lane1_flexible &&
        !(|(banked_regload_lane1_alu_source & base_alu_available)) &&
        (|(banked_regload_lane1_alu_alternate & base_alu_available));
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_lane0_target_mask =
            banked_regload_lane0_reroute ?
                {{(`OPENRV64_EXEC_PIPE_COUNT-2){1'b0}},
                 banked_regload_lane0_alu_alternate} :
                banked_regload_lane0_pipe_mask;
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_lane1_target_mask =
            banked_regload_lane1_reroute ?
                {{(`OPENRV64_EXEC_PIPE_COUNT-2){1'b0}},
                 banked_regload_lane1_alu_alternate} :
                banked_regload_lane1_pipe_mask;

    wire [`RV64_BR_OP_WIDTH-1:0] banked_regload_branch_op =
        banked_regload_pipe_payload[
            1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 18 +:
            `RV64_BR_OP_WIDTH];
    wire banked_regload_branch_taken =
        (banked_regload_branch_op == `RV64_BR_OP_BEQ) ?
            (banked_regload_operand_data[0 +: `RV64_XLEN] ==
             banked_regload_operand_data[`RV64_XLEN +: `RV64_XLEN]) :
            (banked_regload_operand_data[0 +: `RV64_XLEN] !=
             banked_regload_operand_data[`RV64_XLEN +: `RV64_XLEN]);
    assign banked_regload_branch_correct_now =
        banked_regload_lane_operands_ready[0] &&
        (banked_regload_branch_taken ==
         banked_regload_pipe_payload[
             1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 12]);

    // Oldest lane wins if retargeting makes both lanes claim one ALU.  The
    // younger lane remains resident and retries after the older handshake.
    wire banked_regload_lane0_offer =
        banked_regload_lane0_offer_eligible;
    wire banked_regload_lane1_target_conflict =
        banked_regload_lane0_offer &&
        (|(banked_regload_lane0_target_mask &
           banked_regload_lane1_target_mask));
    // A branch-paired follower waits for the registered resolution.  Letting
    // it issue on the branch handshake makes its valid depend on lane0 ready;
    // a MEM follower then closes a ready/valid loop through LSU translation.
    wire banked_regload_branch_follower_allowed =
        !banked_regload_branch_pair_q ||
        (banked_regload_branch_resolved_q &&
         banked_regload_branch_correct_q);
    wire banked_regload_lane1_offer =
        banked_regload_lane1_offer_eligible &&
        !banked_regload_lane1_target_conflict &&
        banked_regload_branch_follower_allowed;
    assign banked_regload_lane0_fire = banked_regload_lane0_offer &&
        (|(banked_regload_lane0_target_mask & pipe_ready));
    wire banked_regload_lane1_fire = banked_regload_lane1_offer &&
        (|(banked_regload_lane1_target_mask & pipe_ready));
    assign banked_regload_lane_fire = {
        banked_regload_lane1_fire, banked_regload_lane0_fire
    };
    wire [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_pipe_offer_mask =
            (banked_regload_lane0_target_mask &
             {`OPENRV64_EXEC_PIPE_COUNT{banked_regload_lane0_offer}}) |
            (banked_regload_lane1_target_mask &
             {`OPENRV64_EXEC_PIPE_COUNT{banked_regload_lane1_offer}});
    // State is still stored under its provisional source pipe.  Clear that
    // source on a successful retargeted handshake, not the transient target.
    assign banked_regload_pipe_fire_mask =
            (banked_regload_lane0_pipe_mask &
             {`OPENRV64_EXEC_PIPE_COUNT{banked_regload_lane0_fire}}) |
            (banked_regload_lane1_pipe_mask &
             {`OPENRV64_EXEC_PIPE_COUNT{banked_regload_lane1_fire}});
    wire banked_regload_issue = |banked_regload_lane_fire;
    assign banked_regload_complete = banked_regload_valid_q &&
        (|(banked_regload_lane_valid_q)) &&
        ((banked_regload_lane_valid_q &
          ~banked_regload_lane_fire) == 2'b00);
    reg [`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_regload_issue_pipe_id;
    reg [`OPENRV64_EXEC_PIPE_COUNT*SLOT_WIDTH-1:0]
        banked_regload_issue_pipe_slot;
    reg [`OPENRV64_EXEC_PIPE_COUNT*
         `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        banked_regload_issue_pipe_payload;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_issue_src1_producer_valid;
    reg [`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_regload_issue_src1_producer_id;
    reg [`OPENRV64_EXEC_PIPE_COUNT-1:0]
        banked_regload_issue_src2_producer_valid;
    reg [`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH-1:0]
        banked_regload_issue_src2_producer_id;
    integer banked_regload_route_source;
    integer banked_regload_route_target;
    always @* begin
        banked_regload_issue_pipe_id =
            {`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        banked_regload_issue_pipe_slot =
            {`OPENRV64_EXEC_PIPE_COUNT*SLOT_WIDTH{1'b0}};
        banked_regload_issue_pipe_payload =
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
        banked_regload_issue_src1_producer_valid =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        banked_regload_issue_src1_producer_id =
            {`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        banked_regload_issue_src2_producer_valid =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        banked_regload_issue_src2_producer_id =
            {`OPENRV64_EXEC_PIPE_COUNT*`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        for (banked_regload_route_target = 0;
             banked_regload_route_target < `OPENRV64_EXEC_PIPE_COUNT;
             banked_regload_route_target =
                 banked_regload_route_target + 1) begin
            for (banked_regload_route_source = 0;
                 banked_regload_route_source < `OPENRV64_EXEC_PIPE_COUNT;
                 banked_regload_route_source =
                     banked_regload_route_source + 1) begin
                if ((banked_regload_lane0_target_mask[
                         banked_regload_route_target] &&
                     banked_regload_lane0_pipe_mask[
                         banked_regload_route_source]) ||
                    (banked_regload_lane1_target_mask[
                         banked_regload_route_target] &&
                     banked_regload_lane1_pipe_mask[
                         banked_regload_route_source] &&
                     !banked_regload_lane1_target_conflict)) begin
                    banked_regload_issue_pipe_id[
                        banked_regload_route_target*
                        `OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH] =
                        banked_regload_pipe_id_q[
                            banked_regload_route_source*
                            `OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH];
                    banked_regload_issue_pipe_slot[
                        banked_regload_route_target*SLOT_WIDTH +:
                        SLOT_WIDTH] = banked_regload_pipe_slot_q[
                            banked_regload_route_source*SLOT_WIDTH +:
                            SLOT_WIDTH];
                    banked_regload_issue_pipe_payload[
                        banked_regload_route_target*
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] =
                        banked_regload_pipe_payload[
                            banked_regload_route_source*
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
                    banked_regload_issue_src1_producer_valid[
                        banked_regload_route_target] =
                        banked_regload_src1_producer_valid_q[
                            banked_regload_route_source];
                    banked_regload_issue_src1_producer_id[
                        banked_regload_route_target*
                        `OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH] =
                        banked_regload_src1_producer_id_q[
                            banked_regload_route_source*
                            `OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH];
                    banked_regload_issue_src2_producer_valid[
                        banked_regload_route_target] =
                        banked_regload_src2_producer_valid_q[
                            banked_regload_route_source];
                    banked_regload_issue_src2_producer_id[
                        banked_regload_route_target*
                        `OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH] =
                        banked_regload_src2_producer_id_q[
                            banked_regload_route_source*
                            `OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH];
                end
            end
        end
    end

    assign pipe_valid = (BANKED_GPR != 0) ?
        (banked_window_regload ? banked_independent_pipe_offer :
         banked_regload_pipe_offer_mask) :
        dispatch_pipe_valid;
    assign pipe_id = (BANKED_GPR != 0) ?
                     (banked_window_regload ? banked_independent_id_q :
                      banked_regload_issue_pipe_id) :
                     dispatch_pipe_id;
    assign pipe_slot = (BANKED_GPR != 0) ?
                       (banked_window_regload ? banked_independent_slot_q :
                        banked_regload_issue_pipe_slot) :
                       dispatch_pipe_slot;
    assign pipe_payload = (BANKED_GPR != 0) ?
        (banked_window_regload ? banked_independent_issue_payload :
         banked_regload_issue_pipe_payload) : dispatch_pipe_payload;
    assign pipe_src1_producer_valid = (BANKED_GPR != 0) ?
        (banked_window_regload ?
         banked_independent_src1_producer_valid_q :
         banked_regload_issue_src1_producer_valid) :
        dispatch_pipe_src1_producer_valid;
    assign pipe_src1_producer_id = (BANKED_GPR != 0) ?
        (banked_window_regload ? banked_independent_src1_producer_id_q :
         banked_regload_issue_src1_producer_id) :
        dispatch_pipe_src1_producer_id;
    assign pipe_src2_producer_valid = (BANKED_GPR != 0) ?
        (banked_window_regload ?
         banked_independent_src2_producer_valid_q :
         banked_regload_issue_src2_producer_valid) :
        dispatch_pipe_src2_producer_valid;
    assign pipe_src2_producer_id = (BANKED_GPR != 0) ?
        (banked_window_regload ? banked_independent_src2_producer_id_q :
         banked_regload_issue_src2_producer_id) :
        dispatch_pipe_src2_producer_id;

    // Source-split simulation probes keep MEM0 load forwarding from being
    // reported as EXU forwarding in the performance harness.
    assign banked_read_exu_forward_valid = banked_read_forward_valid;

    // Performance probes split the register-gather delay by immediate cause.
    // Accepted address phases expose the fixed registered-read latency;
    // denied phases expose bank capacity.  Writer classes use the exact
    // youngest-owner record, so "ready" means the result has completed but
    // architectural ownership has not yet cleared at retirement.
    wire [3:0] banked_read_address_accept_wait =
        banked_read_waiting & gpr_read_req[3:0] & gpr_read_ack[3:0];
    wire [3:0] banked_read_address_conflict_wait =
        banked_read_waiting & gpr_read_req[3:0] & ~gpr_read_ack[3:0];
    reg [3:0] banked_writer_wait_load_incomplete;
    reg [3:0] banked_writer_wait_load_ready;
    reg [3:0] banked_writer_wait_other_incomplete;
    reg [3:0] banked_writer_wait_other_ready;
    reg [3:0] banked_writer_ready_write_not_active;
    reg [3:0] banked_writer_ready_write_granted;
    reg [3:0] banked_writer_ready_write_denied;
    reg [3:0] banked_mem_stage_wait_operand;
    integer banked_wait_class_port;
    integer banked_wait_write_port;
    always @* begin
        banked_writer_wait_load_incomplete = 4'b0000;
        banked_writer_wait_load_ready = 4'b0000;
        banked_writer_wait_other_incomplete = 4'b0000;
        banked_writer_wait_other_ready = 4'b0000;
        banked_writer_ready_write_not_active = 4'b0000;
        banked_writer_ready_write_granted = 4'b0000;
        banked_writer_ready_write_denied = 4'b0000;
        banked_mem_stage_wait_operand = 4'b0000;
        for (banked_wait_class_port = 0; banked_wait_class_port < 4;
             banked_wait_class_port = banked_wait_class_port + 1) begin
            if (banked_read_blocked_by_write[banked_wait_class_port]) begin
                if (youngest_owner_load_q[
                        gpr_read_addr[
                            banked_wait_class_port*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH]]) begin
                    if (youngest_owner_ready_q[
                            gpr_read_addr[
                                banked_wait_class_port*PHYS_REG_ADDR_WIDTH +:
                                PHYS_REG_ADDR_WIDTH]])
                        banked_writer_wait_load_ready[
                            banked_wait_class_port] = 1'b1;
                    else
                        banked_writer_wait_load_incomplete[
                            banked_wait_class_port] = 1'b1;
                end else if (youngest_owner_ready_q[
                                 gpr_read_addr[
                                     banked_wait_class_port*
                                     PHYS_REG_ADDR_WIDTH +:
                                     PHYS_REG_ADDR_WIDTH]]) begin
                    banked_writer_wait_other_ready[
                        banked_wait_class_port] = 1'b1;
                end else begin
                    banked_writer_wait_other_incomplete[
                        banked_wait_class_port] = 1'b1;
                end

                if (youngest_owner_ready_q[
                        gpr_read_addr[
                            banked_wait_class_port*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH]]) begin
                    banked_writer_ready_write_not_active[
                        banked_wait_class_port] = 1'b1;
                    for (banked_wait_write_port = 0;
                         banked_wait_write_port < 2;
                         banked_wait_write_port =
                             banked_wait_write_port + 1) begin
                        if (gpr_write[banked_wait_write_port] &&
                            (gpr_write_addr[
                                 banked_wait_write_port*
                                 PHYS_REG_ADDR_WIDTH +:
                                 PHYS_REG_ADDR_WIDTH] ==
                             gpr_read_addr[
                                 banked_wait_class_port*
                                 PHYS_REG_ADDR_WIDTH +:
                                 PHYS_REG_ADDR_WIDTH])) begin
                            banked_writer_ready_write_not_active[
                                banked_wait_class_port] = 1'b0;
                            if (gpr_write_ack[banked_wait_write_port])
                                banked_writer_ready_write_granted[
                                    banked_wait_class_port] = 1'b1;
                            else
                                banked_writer_ready_write_denied[
                                    banked_wait_class_port] = 1'b1;
                        end
                    end
                end

                // This is the precise exposed cycle introduced by registering
                // MEM0: the matching load completes now, but its operand value
                // cannot be selected until the forwarding latch updates.
                if (banked_mem_forward_capture &&
                    (gpr_read_addr[
                         banked_wait_class_port*PHYS_REG_ADDR_WIDTH +:
                         PHYS_REG_ADDR_WIDTH] == banked_mem_complete_rd))
                    banked_mem_stage_wait_operand[
                        banked_wait_class_port] = 1'b1;
            end
        end
    end

    wire [3:0] banked_mem_forward_issue_operand =
        banked_regload_mem_forwarded_q &
        {{2{banked_regload_lane1_fire}},
         {2{banked_regload_lane0_fire}}};
    wire banked_write_request = (BANKED_GPR != 0) && (|gpr_write[1:0]);
    wire [1:0] banked_write_accept =
        gpr_write[1:0] & gpr_write_ack[1:0];
    // Sliding retirement suppresses a known-losing younger same-bank request
    // before it reaches the register file.  Preserve that capacity event in
    // the performance view even though it is no longer a held transaction.
    wire [1:0] banked_write_denied =
        (gpr_write[1:0] & ~gpr_write_ack[1:0]) |
        {banked_retire_write_pair_conflict, 1'b0};

    assign banked_legacy_read_req[5:4] = 2'b00;
    assign banked_legacy_storage_read_addr[
        6*PHYS_REG_ADDR_WIDTH-1:4*PHYS_REG_ADDR_WIDTH] =
        gpr_read_addr[6*PHYS_REG_ADDR_WIDTH-1:4*PHYS_REG_ADDR_WIDTH];
    assign gpr_read_req = banked_window_regload ?
        banked_independent_read_req : banked_legacy_read_req;
    assign gpr_storage_read_addr = banked_window_regload ?
        banked_independent_read_addr : banked_legacy_storage_read_addr;

    assign dispatch_gpr_read_data[6*`RV64_XLEN-1:4*`RV64_XLEN] =
        (BANKED_GPR == 0) ?
            gpr_read_data[6*`RV64_XLEN-1:4*`RV64_XLEN] :
            {2*`RV64_XLEN{1'b0}};

    wire banked_operands_ready = !banked_gpr_drain_q &&
        !(|banked_read_pending_q) && (&banked_read_ready);
    // The queue head is stable until allocation.  These bits therefore name
    // exact candidate operands, not merely architectural registers.  Retained
    // values cover downstream backpressure after a one-cycle completion; the
    // registered MEM0 source becomes usable without re-entering LSU control.
    wire [5:0] banked_candidate_operand_ready = {
        2'b00, banked_read_forwarded_q | banked_read_mem_forward_valid
    };

    // Simulation performance probes.  A bank conflict is an address phase
    // withheld by finite per-bank port capacity.  A read/write conflict is a
    // same-word read and write accepted together and resolved by the register
    // file's write-data bypass.  The operand predicates are intentionally
    // non-exclusive: different operands can wait on storage and a producer in
    // the same cycle.
    wire banked_read_bank_conflict = (BANKED_GPR != 0) &&
        (|(gpr_read_req[3:0] & ~gpr_read_ack[3:0]));
    wire banked_write_bank_conflict = (BANKED_GPR != 0) &&
        (|banked_write_denied);
    wire banked_bank_conflict = banked_read_bank_conflict ||
        banked_write_bank_conflict;
    wire banked_blocked_on_reads = (BANKED_GPR != 0) &&
        !banked_gpr_drain_q && (dispatch_occupancy_o != 0) &&
        (|banked_read_waiting);
    wire banked_blocked_by_writes = (BANKED_GPR != 0) &&
        !banked_gpr_drain_q && (dispatch_occupancy_o != 0) &&
        (|banked_read_blocked_by_write);
    reg [7:0] banked_read_write_conflict_pairs;
    integer banked_conflict_read_port;
    integer banked_conflict_write_port;
    always @* begin
        banked_read_write_conflict_pairs = 8'd0;
        for (banked_conflict_read_port = 0;
             banked_conflict_read_port < 4;
             banked_conflict_read_port =
                 banked_conflict_read_port + 1) begin
            for (banked_conflict_write_port = 0;
                 banked_conflict_write_port < 2;
                 banked_conflict_write_port =
                     banked_conflict_write_port + 1) begin
                banked_read_write_conflict_pairs[
                    banked_conflict_read_port*2 +
                    banked_conflict_write_port] =
                    (BANKED_GPR != 0) &&
                    gpr_read_ack[banked_conflict_read_port] &&
                    gpr_write_ack[banked_conflict_write_port] &&
                    (gpr_storage_read_addr[
                        banked_conflict_read_port*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH] ==
                     gpr_write_addr[
                        banked_conflict_write_port*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH]);
            end
        end
    end
    wire banked_read_write_conflict =
        |banked_read_write_conflict_pairs;

    wire [1:0] banked_regload_allocation_hard;
    genvar banked_regload_hard_lane;
    generate
        for (banked_regload_hard_lane = 0;
             banked_regload_hard_lane < 2;
             banked_regload_hard_lane =
                 banked_regload_hard_lane + 1) begin :
                g_banked_regload_hard
            wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                allocation_payload = allocation_meta[
                    banked_regload_hard_lane*RETIRE_META_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
            assign banked_regload_allocation_hard[
                banked_regload_hard_lane] = allocation_valid[
                    banked_regload_hard_lane] &&
                banked_hard_payload(allocation_payload);
        end
    endgenerate
    wire banked_regload_capture_hard = banked_window_regload ?
        banked_regload_window_capture_hard :
        (|banked_regload_allocation_hard);
    wire banked_regload_capture_control = banked_window_regload &&
        banked_regload_window_capture_control;

    integer banked_response_port;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            banked_read_done_q <= 4'b0000;
            banked_read_forwarded_q <= 4'b0000;
            banked_read_mem_forwarded_q <= 4'b0000;
            banked_read_data_q <= {4*`RV64_XLEN{1'b0}};
            banked_read_pending_q <= 4'b0000;
            banked_read_addr_q <= {4*PHYS_REG_ADDR_WIDTH{1'b0}};
            banked_read_ack_q <= 4'b0000;
            banked_read_response_to_input_q <= 4'b0000;
            banked_read_response_to_regload_q <= 4'b0000;
            banked_read_response_to_pending_q <= 4'b0000;
        end else if (BANKED_GPR != 0) begin
`ifdef OPENRV64_BANKED_GPR_MAGIC_READS
            banked_read_ack_q <= 4'b0000;
            banked_read_response_to_input_q <= 4'b0000;
            banked_read_response_to_regload_q <= 4'b0000;
            banked_read_response_to_pending_q <= 4'b0000;
`else
            banked_read_ack_q <= gpr_read_ack[3:0];
            if (banked_window_regload) begin
                banked_read_response_to_input_q <= 4'b0000;
                banked_read_response_to_regload_q <= gpr_read_ack[3:0];
                banked_read_response_to_pending_q <= 4'b0000;
            end else begin
                banked_read_response_to_input_q <= gpr_read_ack[3:0] &
                    {4{!(|allocation_valid) && !flush_i &&
                        !squash_frontend_i && !banked_gpr_drain_q}};
                banked_read_response_to_regload_q <= gpr_read_ack[3:0] &
                    {{2{allocation_valid[1]}},
                     {2{allocation_valid[0]}}} &
                    {4{banked_regload_allocation_to_stage}};
                banked_read_response_to_pending_q <= gpr_read_ack[3:0] &
                    {{2{allocation_valid[1]}},
                     {2{allocation_valid[0]}}} &
                    {4{banked_regload_allocation_to_pending}};
            end
`endif

            if (flush_i || squash_frontend_i || banked_gpr_drain_q ||
                banked_read_context_replace) begin
                banked_read_done_q <= 4'b0000;
                banked_read_forwarded_q <= 4'b0000;
                banked_read_mem_forwarded_q <= 4'b0000;
                banked_read_data_q <= {4*`RV64_XLEN{1'b0}};
            end

            for (banked_response_port = 0; banked_response_port < 4;
                 banked_response_port = banked_response_port + 1) begin
                if (!(flush_i || squash_frontend_i || banked_gpr_drain_q ||
                      banked_read_context_replace) &&
                    banked_input_response_now[banked_response_port]) begin
                    banked_read_done_q[banked_response_port] <= 1'b1;
                    banked_read_forwarded_q[banked_response_port] <= 1'b0;
                    banked_read_mem_forwarded_q[
                        banked_response_port] <= 1'b0;
                    banked_read_data_q[
                        banked_response_port*`RV64_XLEN +: `RV64_XLEN] <=
                        gpr_read_data[
                            banked_response_port*`RV64_XLEN +: `RV64_XLEN];
                end

                // Completion forwarding has priority over an impossible but
                // defensively handled simultaneous stale storage response.
                if (!(flush_i || squash_frontend_i || banked_gpr_drain_q ||
                      banked_read_context_replace) &&
                    (banked_read_forward_valid[banked_response_port] ||
                     banked_read_mem_forward_valid[banked_response_port])) begin
                    banked_read_done_q[banked_response_port] <= 1'b1;
                    banked_read_forwarded_q[banked_response_port] <= 1'b1;
                    banked_read_mem_forwarded_q[
                        banked_response_port] <=
                        banked_read_mem_forward_valid[
                            banked_response_port];
                    banked_read_data_q[
                        banked_response_port*`RV64_XLEN +: `RV64_XLEN] <=
                        banked_read_forward_data[
                            banked_response_port*`RV64_XLEN +:
                            `RV64_XLEN];
                end

                if (banked_read_context_replace) begin
                    banked_read_pending_q[banked_response_port] <= 1'b0;
                end else if (gpr_read_ack[banked_response_port]) begin
                    banked_read_pending_q[banked_response_port] <= 1'b0;
                end else if (gpr_read_req[banked_response_port]) begin
                    banked_read_pending_q[banked_response_port] <= 1'b1;
                    banked_read_addr_q[
                        banked_response_port*PHYS_REG_ADDR_WIDTH +:
                        PHYS_REG_ADDR_WIDTH] <= gpr_storage_read_addr[
                            banked_response_port*PHYS_REG_ADDR_WIDTH +:
                            PHYS_REG_ADDR_WIDTH];
                end
            end
        end else begin
            banked_read_pending_q <= 4'b0000;
            banked_read_addr_q <= {4*PHYS_REG_ADDR_WIDTH{1'b0}};
            banked_read_ack_q <= 4'b0000;
            banked_read_response_to_input_q <= 4'b0000;
            banked_read_response_to_regload_q <= 4'b0000;
            banked_read_response_to_pending_q <= 4'b0000;
            banked_read_forwarded_q <= 4'b0000;
            banked_read_mem_forwarded_q <= 4'b0000;
        end
    end

    integer banked_regload_state_port;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            banked_regload_valid_q <= 1'b0;
            banked_regload_lane_valid_q <= 2'b00;
            banked_regload_lane_id_q <=
                {2*`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            banked_regload_operand_done_q <= 4'b0000;
            banked_regload_operand_data_q <= {4*`RV64_XLEN{1'b0}};
            banked_regload_mem_forwarded_q <= 4'b0000;
            banked_regload_hard_q <= 1'b0;
            banked_regload_control_q <= 1'b0;
            banked_regload_branch_pair_q <= 1'b0;
            banked_regload_branch_resolved_q <= 1'b0;
            banked_regload_branch_correct_q <= 1'b0;
            banked_regload_pipe_valid_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_regload_pipe_id_q <=
                {`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH{1'b0}};
            banked_regload_pipe_slot_q <=
                {`OPENRV64_EXEC_PIPE_COUNT*SLOT_WIDTH{1'b0}};
            banked_regload_pipe_payload_q <=
                {`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
            banked_regload_src1_producer_valid_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_regload_src1_producer_id_q <=
                {`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH{1'b0}};
            banked_regload_src2_producer_valid_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_regload_src2_producer_id_q <=
                {`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH{1'b0}};
            banked_regload_src1_phys_q <=
                {`OPENRV64_EXEC_PIPE_COUNT*
                 PHYS_REG_ADDR_WIDTH{1'b0}};
            banked_regload_src2_phys_q <=
                {`OPENRV64_EXEC_PIPE_COUNT*
                 PHYS_REG_ADDR_WIDTH{1'b0}};
            banked_regload_pipe_uses_rs1_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_regload_pipe_uses_rs2_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        end else if ((BANKED_GPR == 0) || flush_i ||
                     (squash_frontend_i &&
                      !banked_window_regload)) begin
            banked_regload_valid_q <= 1'b0;
            banked_regload_lane_valid_q <= 2'b00;
            banked_regload_operand_done_q <= 4'b0000;
            banked_regload_mem_forwarded_q <= 4'b0000;
            banked_regload_hard_q <= 1'b0;
            banked_regload_control_q <= 1'b0;
            banked_regload_branch_pair_q <= 1'b0;
            banked_regload_branch_resolved_q <= 1'b0;
            banked_regload_branch_correct_q <= 1'b0;
            banked_regload_pipe_valid_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_regload_pipe_uses_rs1_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_regload_pipe_uses_rs2_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        end else if (squash_frontend_i) begin
            banked_regload_valid_q <=
                |banked_regload_redirect_lane_survivor;
            banked_regload_lane_valid_q <=
                banked_regload_redirect_lane_survivor;
            banked_regload_operand_done_q <=
                banked_regload_operand_done_q &
                banked_regload_redirect_operand_survivor;
            banked_regload_mem_forwarded_q <=
                banked_regload_mem_forwarded_q &
                banked_regload_redirect_operand_survivor;
            banked_regload_hard_q <= banked_regload_redirect_hard;
            banked_regload_control_q <= banked_regload_redirect_control;
            banked_regload_branch_pair_q <= 1'b0;
            banked_regload_branch_resolved_q <= 1'b0;
            banked_regload_branch_correct_q <= 1'b0;
            banked_regload_pipe_valid_q <=
                banked_regload_redirect_pipe_survivor;
            banked_regload_src1_producer_valid_q <=
                banked_regload_src1_producer_valid_q &
                banked_regload_redirect_pipe_survivor;
            banked_regload_src2_producer_valid_q <=
                banked_regload_src2_producer_valid_q &
                banked_regload_redirect_pipe_survivor;
            banked_regload_pipe_uses_rs1_q <=
                banked_regload_pipe_uses_rs1_q &
                banked_regload_redirect_pipe_survivor;
            banked_regload_pipe_uses_rs2_q <=
                banked_regload_pipe_uses_rs2_q &
                banked_regload_redirect_pipe_survivor;
        end else begin
            if (banked_regload_branch_pair_q &&
                !banked_regload_branch_resolved_q &&
                banked_regload_lane0_fire) begin
                banked_regload_branch_resolved_q <= 1'b1;
                banked_regload_branch_correct_q <=
                    banked_regload_branch_correct_now;
            end

            // Capture a returned operand even if the older lane issues this
            // cycle and the younger lane remains under pipe backpressure.
            for (banked_regload_state_port = 0;
                 banked_regload_state_port < 4;
                 banked_regload_state_port =
                     banked_regload_state_port + 1) begin
                if (banked_regload_response_now[
                        banked_regload_state_port]) begin
                    banked_regload_operand_done_q[
                        banked_regload_state_port] <= 1'b1;
                    banked_regload_operand_data_q[
                        banked_regload_state_port*`RV64_XLEN +:
                        `RV64_XLEN] <= gpr_read_data[
                            banked_regload_state_port*`RV64_XLEN +:
                            `RV64_XLEN];
                end
            end

            if (banked_regload_issue) begin
                banked_regload_lane_valid_q <=
                    banked_regload_lane_valid_q &
                    ~banked_regload_lane_fire;
                banked_regload_pipe_valid_q <=
                    banked_regload_pipe_valid_q &
                    ~banked_regload_pipe_fire_mask;
            end

            if (banked_regload_complete) begin
                banked_regload_valid_q <= 1'b0;
                banked_regload_lane_valid_q <= 2'b00;
                banked_regload_operand_done_q <= 4'b0000;
                banked_regload_mem_forwarded_q <= 4'b0000;
                banked_regload_hard_q <= 1'b0;
                banked_regload_control_q <= 1'b0;
                banked_regload_branch_pair_q <= 1'b0;
                banked_regload_branch_resolved_q <= 1'b0;
                banked_regload_branch_correct_q <= 1'b0;
                banked_regload_pipe_valid_q <=
                    {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            end

            // Promotion has priority over clearing the group that leaves at
            // this edge.  Include a same-cycle pending response in the
            // promoted operand image.
            if (banked_regload_promote_pending) begin
                banked_regload_valid_q <= 1'b1;
                banked_regload_lane_valid_q <=
                    banked_regload_pending_lane_valid_q;
                banked_regload_lane_id_q <=
                    banked_regload_pending_lane_id_q;
                banked_regload_operand_done_q <=
                    banked_regload_pending_operand_ready;
                banked_regload_operand_data_q <=
                    banked_regload_pending_operand_data;
                banked_regload_mem_forwarded_q <=
                    banked_regload_pending_mem_forwarded_q;
                banked_regload_hard_q <=
                    banked_regload_pending_hard_q;
                banked_regload_control_q <=
                    banked_regload_pending_control_q;
                banked_regload_branch_pair_q <=
                    banked_regload_pending_branch_pair_q;
                banked_regload_branch_resolved_q <= 1'b0;
                banked_regload_branch_correct_q <= 1'b0;
                banked_regload_pipe_valid_q <=
                    banked_regload_pending_pipe_valid_q;
                banked_regload_pipe_id_q <=
                    banked_regload_pending_pipe_id_q;
                banked_regload_pipe_slot_q <=
                    banked_regload_pending_pipe_slot_q;
                banked_regload_pipe_payload_q <=
                    banked_regload_pending_pipe_payload_q;
                banked_regload_src1_producer_valid_q <=
                    banked_regload_pending_src1_producer_valid_q;
                banked_regload_src1_producer_id_q <=
                    banked_regload_pending_src1_producer_id_q;
                banked_regload_src2_producer_valid_q <=
                    banked_regload_pending_src2_producer_valid_q;
                banked_regload_src2_producer_id_q <=
                    banked_regload_pending_src2_producer_id_q;
                banked_regload_src1_phys_q <=
                    banked_regload_pending_src1_phys_q;
                banked_regload_src2_phys_q <=
                    banked_regload_pending_src2_phys_q;
                banked_regload_pipe_uses_rs1_q <=
                    banked_regload_pending_pipe_uses_rs1_q;
                banked_regload_pipe_uses_rs2_q <=
                    banked_regload_pending_pipe_uses_rs2_q;
            end

            // A new allocation may directly replace a non-hard group that
            // completes at this edge.  When the old group stalls, the same
            // allocation is captured by the pending-credit block below.
            if (banked_regload_allocation_to_stage) begin
                banked_regload_valid_q <= 1'b1;
                banked_regload_lane_valid_q <=
                    banked_regload_capture_lane_valid;
                banked_regload_lane_id_q <=
                    banked_regload_capture_lane_id;
                banked_regload_hard_q <= banked_regload_capture_hard;
                banked_regload_control_q <=
                    banked_regload_capture_control;
                banked_regload_branch_pair_q <=
                    banked_regload_allocation_branch_pair;
                banked_regload_branch_resolved_q <= 1'b0;
                banked_regload_branch_correct_q <= 1'b0;
                banked_regload_pipe_valid_q <= dispatch_pipe_valid;
                banked_regload_pipe_id_q <= dispatch_pipe_id;
                banked_regload_pipe_slot_q <= dispatch_pipe_slot;
                banked_regload_pipe_payload_q <= dispatch_pipe_payload;
                banked_regload_src1_producer_valid_q <=
                    dispatch_pipe_src1_producer_valid;
                banked_regload_src1_producer_id_q <=
                    dispatch_pipe_src1_producer_id;
                banked_regload_src2_producer_valid_q <=
                    dispatch_pipe_src2_producer_valid;
                banked_regload_src2_producer_id_q <=
                    dispatch_pipe_src2_producer_id;
                banked_regload_src1_phys_q <=
                    dispatch_pipe_src1_phys;
                banked_regload_src2_phys_q <=
                    dispatch_pipe_src2_phys;
                banked_regload_pipe_uses_rs1_q <=
                    dispatch_pipe_uses_rs1;
                banked_regload_pipe_uses_rs2_q <=
                    dispatch_pipe_uses_rs2;
                for (banked_regload_state_port = 0;
                     banked_regload_state_port < 4;
                     banked_regload_state_port =
                         banked_regload_state_port + 1) begin
                    if (banked_window_regload) begin
                        banked_regload_operand_done_q[
                            banked_regload_state_port] <=
                            banked_regload_ingress_operand_done[
                                banked_regload_state_port];
                        banked_regload_operand_data_q[
                            banked_regload_state_port*`RV64_XLEN +:
                            `RV64_XLEN] <=
                            banked_regload_ingress_operand_data[
                                banked_regload_state_port*`RV64_XLEN +:
                                `RV64_XLEN];
                        banked_regload_mem_forwarded_q[
                            banked_regload_state_port] <= 1'b0;
                    end else if (!allocation_valid[
                                     banked_regload_state_port / 2]) begin
                        banked_regload_operand_done_q[
                            banked_regload_state_port] <= 1'b1;
                        banked_regload_operand_data_q[
                            banked_regload_state_port*`RV64_XLEN +:
                            `RV64_XLEN] <= {`RV64_XLEN{1'b0}};
                        banked_regload_mem_forwarded_q[
                            banked_regload_state_port] <= 1'b0;
                    end else begin
                        banked_regload_operand_done_q[
                            banked_regload_state_port] <=
                            banked_read_ready[
                                banked_regload_state_port];
                        banked_regload_operand_data_q[
                            banked_regload_state_port*`RV64_XLEN +:
                            `RV64_XLEN] <= dispatch_gpr_read_data[
                                banked_regload_state_port*`RV64_XLEN +:
                                `RV64_XLEN];
                        banked_regload_mem_forwarded_q[
                            banked_regload_state_port] <=
                            banked_read_mem_forwarded_q[
                                banked_regload_state_port] ||
                            banked_read_mem_forward_valid[
                                banked_regload_state_port];
                    end
                end
            end
        end
    end

    integer banked_regload_pending_state_port;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            banked_regload_pending_valid_q <= 1'b0;
            banked_regload_pending_lane_valid_q <= 2'b00;
            banked_regload_pending_lane_id_q <=
                {2*`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            banked_regload_pending_operand_done_q <= 4'b0000;
            banked_regload_pending_operand_data_q <=
                {4*`RV64_XLEN{1'b0}};
            banked_regload_pending_mem_forwarded_q <= 4'b0000;
            banked_regload_pending_hard_q <= 1'b0;
            banked_regload_pending_control_q <= 1'b0;
            banked_regload_pending_branch_pair_q <= 1'b0;
            banked_regload_pending_pipe_valid_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_regload_pending_pipe_id_q <=
                {`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH{1'b0}};
            banked_regload_pending_pipe_slot_q <=
                {`OPENRV64_EXEC_PIPE_COUNT*SLOT_WIDTH{1'b0}};
            banked_regload_pending_pipe_payload_q <=
                {`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
            banked_regload_pending_src1_producer_valid_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_regload_pending_src1_producer_id_q <=
                {`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH{1'b0}};
            banked_regload_pending_src2_producer_valid_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_regload_pending_src2_producer_id_q <=
                {`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH{1'b0}};
            banked_regload_pending_src1_phys_q <=
                {`OPENRV64_EXEC_PIPE_COUNT*
                 PHYS_REG_ADDR_WIDTH{1'b0}};
            banked_regload_pending_src2_phys_q <=
                {`OPENRV64_EXEC_PIPE_COUNT*
                 PHYS_REG_ADDR_WIDTH{1'b0}};
            banked_regload_pending_pipe_uses_rs1_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_regload_pending_pipe_uses_rs2_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        end else if ((BANKED_GPR == 0) || flush_i ||
                     (squash_frontend_i &&
                      !banked_window_regload)) begin
            banked_regload_pending_valid_q <= 1'b0;
            banked_regload_pending_lane_valid_q <= 2'b00;
            banked_regload_pending_operand_done_q <= 4'b0000;
            banked_regload_pending_mem_forwarded_q <= 4'b0000;
            banked_regload_pending_hard_q <= 1'b0;
            banked_regload_pending_control_q <= 1'b0;
            banked_regload_pending_branch_pair_q <= 1'b0;
            banked_regload_pending_pipe_valid_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_regload_pending_pipe_uses_rs1_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            banked_regload_pending_pipe_uses_rs2_q <=
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        end else if (squash_frontend_i) begin
            banked_regload_pending_valid_q <=
                |banked_regload_pending_redirect_lane_survivor;
            banked_regload_pending_lane_valid_q <=
                banked_regload_pending_redirect_lane_survivor;
            banked_regload_pending_operand_done_q <=
                banked_regload_pending_operand_done_q &
                banked_regload_pending_redirect_operand_survivor;
            banked_regload_pending_mem_forwarded_q <=
                banked_regload_pending_mem_forwarded_q &
                banked_regload_pending_redirect_operand_survivor;
            banked_regload_pending_hard_q <=
                banked_regload_pending_redirect_hard;
            banked_regload_pending_control_q <=
                banked_regload_pending_redirect_control;
            banked_regload_pending_branch_pair_q <= 1'b0;
            banked_regload_pending_pipe_valid_q <=
                banked_regload_pending_redirect_pipe_survivor;
            banked_regload_pending_src1_producer_valid_q <=
                banked_regload_pending_src1_producer_valid_q &
                banked_regload_pending_redirect_pipe_survivor;
            banked_regload_pending_src2_producer_valid_q <=
                banked_regload_pending_src2_producer_valid_q &
                banked_regload_pending_redirect_pipe_survivor;
            banked_regload_pending_pipe_uses_rs1_q <=
                banked_regload_pending_pipe_uses_rs1_q &
                banked_regload_pending_redirect_pipe_survivor;
            banked_regload_pending_pipe_uses_rs2_q <=
                banked_regload_pending_pipe_uses_rs2_q &
                banked_regload_pending_redirect_pipe_survivor;
        end else begin
            for (banked_regload_pending_state_port = 0;
                 banked_regload_pending_state_port < 4;
                 banked_regload_pending_state_port =
                     banked_regload_pending_state_port + 1) begin
                if (banked_regload_pending_response_now[
                        banked_regload_pending_state_port]) begin
                    banked_regload_pending_operand_done_q[
                        banked_regload_pending_state_port] <= 1'b1;
                    banked_regload_pending_operand_data_q[
                        banked_regload_pending_state_port*`RV64_XLEN +:
                        `RV64_XLEN] <= gpr_read_data[
                            banked_regload_pending_state_port*`RV64_XLEN +:
                            `RV64_XLEN];
                end
            end

            if (banked_regload_promote_pending) begin
                banked_regload_pending_valid_q <= 1'b0;
                banked_regload_pending_lane_valid_q <= 2'b00;
                banked_regload_pending_operand_done_q <= 4'b0000;
                banked_regload_pending_mem_forwarded_q <= 4'b0000;
                banked_regload_pending_hard_q <= 1'b0;
                banked_regload_pending_control_q <= 1'b0;
                banked_regload_pending_branch_pair_q <= 1'b0;
                banked_regload_pending_pipe_valid_q <=
                    {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
            end

            if (banked_regload_allocation_to_pending) begin
                banked_regload_pending_valid_q <= 1'b1;
                banked_regload_pending_lane_valid_q <=
                    banked_regload_capture_lane_valid;
                banked_regload_pending_lane_id_q <=
                    banked_regload_capture_lane_id;
                banked_regload_pending_hard_q <=
                    banked_regload_capture_hard;
                banked_regload_pending_control_q <=
                    banked_regload_capture_control;
                banked_regload_pending_branch_pair_q <=
                    banked_regload_allocation_branch_pair;
                banked_regload_pending_pipe_valid_q <=
                    dispatch_pipe_valid;
                banked_regload_pending_pipe_id_q <= dispatch_pipe_id;
                banked_regload_pending_pipe_slot_q <= dispatch_pipe_slot;
                banked_regload_pending_pipe_payload_q <=
                    dispatch_pipe_payload;
                banked_regload_pending_src1_producer_valid_q <=
                    dispatch_pipe_src1_producer_valid;
                banked_regload_pending_src1_producer_id_q <=
                    dispatch_pipe_src1_producer_id;
                banked_regload_pending_src2_producer_valid_q <=
                    dispatch_pipe_src2_producer_valid;
                banked_regload_pending_src2_producer_id_q <=
                    dispatch_pipe_src2_producer_id;
                banked_regload_pending_src1_phys_q <=
                    dispatch_pipe_src1_phys;
                banked_regload_pending_src2_phys_q <=
                    dispatch_pipe_src2_phys;
                banked_regload_pending_pipe_uses_rs1_q <=
                    dispatch_pipe_uses_rs1;
                banked_regload_pending_pipe_uses_rs2_q <=
                    dispatch_pipe_uses_rs2;
                for (banked_regload_pending_state_port = 0;
                     banked_regload_pending_state_port < 4;
                     banked_regload_pending_state_port =
                         banked_regload_pending_state_port + 1) begin
                    if (banked_window_regload) begin
                        banked_regload_pending_operand_done_q[
                            banked_regload_pending_state_port] <=
                            banked_regload_ingress_operand_done[
                                banked_regload_pending_state_port];
                        banked_regload_pending_operand_data_q[
                            banked_regload_pending_state_port*`RV64_XLEN +:
                            `RV64_XLEN] <=
                            banked_regload_ingress_operand_data[
                                banked_regload_pending_state_port*`RV64_XLEN +:
                                `RV64_XLEN];
                        banked_regload_pending_mem_forwarded_q[
                            banked_regload_pending_state_port] <= 1'b0;
                    end else if (!allocation_valid[
                                     banked_regload_pending_state_port / 2]) begin
                        banked_regload_pending_operand_done_q[
                            banked_regload_pending_state_port] <= 1'b1;
                        banked_regload_pending_operand_data_q[
                            banked_regload_pending_state_port*`RV64_XLEN +:
                            `RV64_XLEN] <= {`RV64_XLEN{1'b0}};
                        banked_regload_pending_mem_forwarded_q[
                            banked_regload_pending_state_port] <= 1'b0;
                    end else begin
                        banked_regload_pending_operand_done_q[
                            banked_regload_pending_state_port] <=
                            banked_read_ready[
                                banked_regload_pending_state_port];
                        banked_regload_pending_operand_data_q[
                            banked_regload_pending_state_port*`RV64_XLEN +:
                            `RV64_XLEN] <= dispatch_gpr_read_data[
                                banked_regload_pending_state_port*`RV64_XLEN +:
                                `RV64_XLEN];
                        banked_regload_pending_mem_forwarded_q[
                            banked_regload_pending_state_port] <=
                            banked_read_mem_forwarded_q[
                                banked_regload_pending_state_port] ||
                            banked_read_mem_forward_valid[
                                banked_regload_pending_state_port];
                    end
                end
            end
        end
    end

    // Deliberately conservative capacity gate: issue resumes with room for a
    // complete issue group.  This breaks the alloc-valid/ready loop and
    // leaves exact-width admission as a later timing optimization.
    // Occupancy <= DEPTH-width proves room for the largest active decode group,
    // so consulting the queue's alloc-count-dependent ready here is redundant
    // and would recreate an alloc_valid <-> alloc_ready combinational loop.
    // The legacy banked dispatcher admits at most two lanes.  The independent
    // window/Tomasulo path admits three, even though register-load ownership is
    // transferred at at most two instructions per cycle.
    assign allocation_ready = (retire_occupancy_o <=
        RETIRE_DEPTH - (((BANKED_GPR != 0) && !banked_window_regload) ?
                        2 : 3));

    openrv64_dispatch #(
        .BACKEND_CONFIG(`OPENRV64_BACKEND_3P),
        .QUEUE_DEPTH_3P(DISPATCH_DEPTH),
        .RETIRE_SLOT_WIDTH_3P(SLOT_WIDTH),
        .MAX_READS_PER_REG_3P(MAX_READS_PER_REG),
        .MAX_ISSUE_LANES_3P((BANKED_GPR != 0) ? 2 : 3),
        .RELAX_WAW_3P(RELAX_WAW),
        .RELAX_HAZARDS_3P(RELAX_HAZARDS),
        .FREE_BRANCHES_3P(FREE_BRANCHES),
        .ENABLE_EQ_BRANCH_PAIRING_3P(ENABLE_EQ_BRANCH_PAIRING),
        // Banked dispatch admits a safe BEQ/BNE pair provisionally.  The
        // register-load stage compares the returned operands before it lets
        // the follower issue.
        .DEFER_EQ_BRANCH_PAIRING_3P(BANKED_GPR != 0),
        .ENABLE_ISSUE_WINDOW_3P(ENABLE_ISSUE_WINDOW),
        .ENABLE_SPECULATION_WINDOW_3P(ENABLE_SPECULATION_WINDOW),
        .DEFER_WINDOW_GPR_READ_3P(BANKED_GPR != 0),
        .MAX_WINDOW_ISSUE_LANES_3P((BANKED_GPR != 0) ? 3 : 4),
        .ISSUE_WINDOW_DEPTH_3P(ISSUE_WINDOW_DEPTH),
        .RENAME_MODE_3P(RENAME_MODE),
        .CACHEABLE_BASE_3P(CACHEABLE_BASE),
        .CACHEABLE_SIZE_3P(CACHEABLE_SIZE),
        .PHYS_REG_COUNT_3P(PHYS_REG_COUNT),
        .PHYS_REG_ADDR_WIDTH_3P(PHYS_REG_ADDR_WIDTH),
        .RETIRE_META_WIDTH_3P(RETIRE_META_WIDTH),
        .COUNT_WIDTH_3P(DISPATCH_COUNT_WIDTH)
    ) u_dispatch (
        .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
        .scoreboard_clear_1p_i(1'b0),
        .decode_valid_i(1'b0), .decode_pc_i(64'd0),
        .decode_instr_i(32'd0), .decode_imm_i(64'd0),
        .decode_uses_rs1_i(1'b0), .decode_uses_rs2_i(1'b0),
        .decode_rs1_addr_i(5'd0), .decode_rs2_addr_i(5'd0),
        .decode_rd_addr_i(5'd0),
        .decode_alu_ext_i({`RV64_ALU_EXT_WIDTH{1'b0}}),
        .decode_alu_op_i({`RV64_ALU_OP_WIDTH{1'b0}}),
        .decode_lsu_op_i({`RV64_LSU_OP_WIDTH{1'b0}}),
        .decode_br_op_i({`RV64_BR_OP_WIDTH{1'b0}}),
        .decode_reg_write_i(1'b0), .decode_mem_read_i(1'b0),
        .decode_mem_write_i(1'b0), .decode_branch_i(1'b0),
        .decode_jump_i(1'b0), .decode_predicted_taken_i(1'b0),
        .decode_word_op_i(1'b0), .decode_system_i(1'b0),
        .decode_fence_i(1'b0), .decode_illegal_i(1'b0),
        .decode_ebreak_i(1'b0), .decode_ecall_i(1'b0),
        .decode_instr_fault_i(1'b0),
        .decode_instr_page_fault_i(1'b0),
        .exec_clear_i(1'b0), .exec_alu_ready_i(1'b0),
        .exec_lsu_ready_i(1'b0), .exec_br_ready_i(1'b0),
        .exec_system_ready_i(1'b0), .forward_ex_valid_i(1'b0),
        .forward_ex_rd_addr_i(5'd0), .forward_mem_valid_i(1'b0),
        .forward_mem_rd_addr_i(5'd0),
        .retire_valid_i(1'b0), .retire_csr_i(1'b0),
        .retire_fence_i(1'b0), .retire_uses_rs1_i(1'b0),
        .retire_uses_rs2_i(1'b0), .retire_rs1_addr_i(5'd0),
        .retire_rs2_addr_i(5'd0), .retire_reg_write_i(1'b0),
        .retire_rd_addr_i(5'd0), .decode_trace_id_i(64'd0),
        .squash_frontend_3p_i(squash_frontend_i),
        .squash_id_3p_i(redirect_id_o),
        .squash_slot_3p_i(branch_slot_o),
        .translation_bypass_3p_i(translation_bypass_i),
        .decode_valid_3p_i(decode_valid_i),
        .decode_ready_3p_o(decode_ready_o),
        .decode_payload_3p_i(decode_payload_i),
        .decode_uses_rs1_3p_i(decode_uses_rs1_i),
        .decode_uses_rs2_3p_i(decode_uses_rs2_i),
        .gpr_read_addr_3p_o(dispatch_gpr_read_addr),
        .gpr_read_ready_3p_o(dispatch_gpr_read_ready),
        .gpr_read_data_3p_i(dispatch_gpr_read_data),
        .candidate_operand_ready_3p_i(
            (BANKED_GPR != 0) ? banked_candidate_operand_ready : 6'b000000),
        .candidate_address_ready_3p_i(
            (RENAME_MODE == `OPENRV64_RENAME_TOMASULO) ?
            {1'b0, &banked_read_address_ready[3:2],
             &banked_read_address_ready[1:0]} : 3'b111),
        .allocation_ready_3p_i(banked_window_regload ? allocation_ready :
            ((BANKED_GPR != 0) ? banked_dispatch_allocation_ready :
             allocation_ready)),
        .rename_free_valid_3p_i(rename_free_valid),
        .rename_free_tag_3p_i(rename_free_tag),
        .rename_write_valid_3p_i(completion_writeback_fire),
        .rename_write_tag_3p_i(completion_prf_write_tag),
        .rename_commit_valid_3p_i(rename_commit_valid),
        .rename_commit_arch_3p_i(release_rd_addr),
        .rename_commit_phys_3p_i(rename_commit_phys),
        .allocation_id_3p_i(allocation_id),
        .allocation_slot_3p_i(allocation_slot),
        .allocation_valid_3p_o(allocation_valid),
        .allocation_meta_3p_o(allocation_meta),
        .pipe_ready_3p_i(banked_window_regload ?
            banked_independent_pipe_ready :
            ((BANKED_GPR != 0) ?
             {`OPENRV64_EXEC_PIPE_COUNT{1'b1}} : pipe_ready)),
        .pipe_candidate_valid_3p_o(dispatch_pipe_candidate_valid),
        .pipe_age_rank_3p_o(dispatch_pipe_age_rank),
        .forward_valid_3p_i(local_forward_valid),
        .forward_rd_addr_3p_i(local_forward_rd_addr),
        .completion_forward_valid_3p_i(
            dispatch_completion_forward_valid),
        .completion_forward_rd_addr_3p_i(
            dispatch_completion_forward_rd_addr),
        .completion_forward_data_3p_i(
            dispatch_completion_forward_data),
        .branch_completion_forward_valid_3p_i(
            branch_completion_forward_valid),
        .forward_map_valid_3p_i(full_forward_valid),
        .forward_map_data_3p_i(full_forward_data),
        .completion_valid_3p_i(queue_complete_accept),
        .completion_id_3p_i(complete_id),
        .completion_payload_3p_i(complete_payload),
        .conditional_resolve_valid_3p_i(
            exec_branch_resolved && exec_branch_conditional),
        // exec_redirect_{id,slot} carry the issuing EX1 control identity even
        // when the prediction is correct and redirect_valid remains low.
        .conditional_resolve_id_3p_i(exec_redirect_id),
        .conditional_resolve_slot_3p_i(exec_redirect_slot),
        .pipe_valid_3p_o(dispatch_pipe_valid),
        .pipe_id_3p_o(dispatch_pipe_id),
        .pipe_slot_3p_o(dispatch_pipe_slot),
        .pipe_payload_3p_o(dispatch_pipe_payload),
        .pipe_uses_rs1_3p_o(dispatch_pipe_uses_rs1),
        .pipe_uses_rs2_3p_o(dispatch_pipe_uses_rs2),
        .pipe_src1_producer_valid_3p_o(
            dispatch_pipe_src1_producer_valid),
        .pipe_src1_producer_id_3p_o(dispatch_pipe_src1_producer_id),
        .pipe_src2_producer_valid_3p_o(
            dispatch_pipe_src2_producer_valid),
        .pipe_src2_producer_id_3p_o(dispatch_pipe_src2_producer_id),
        .pipe_src1_phys_3p_o(dispatch_pipe_src1_phys),
        .pipe_src2_phys_3p_o(dispatch_pipe_src2_phys),
        .pipe_destination_phys_3p_o(dispatch_pipe_destination_phys),
        .retire_valid_3p_i(dispatch_retire_valid),
        .retire_id_3p_i(dispatch_retire_id),
        .retire_slot_3p_i(dispatch_retire_slot),
        .retire_uses_rs1_3p_i(dispatch_retire_uses_rs1),
        .retire_uses_rs2_3p_i(dispatch_retire_uses_rs2),
        .retire_rs1_addr_3p_i(dispatch_retire_rs1_addr),
        .retire_rs2_addr_3p_i(dispatch_retire_rs2_addr),
        .retire_reg_write_3p_i(dispatch_retire_reg_write),
        .retire_rd_addr_3p_i(dispatch_retire_rd_addr),
        .retire_hard_3p_i(dispatch_retire_hard),
        .recovery_valid_3p_i(banked_deferred_pair_recovery),
        .recovery_reg_write_3p_i(
            banked_deferred_follower_reg_write),
        .recovery_rd_addr_3p_i(banked_deferred_follower_rd),
        .next_retire_id_3p_i(dispatch_next_retire_id),
        .next_retire_slot_3p_i(dispatch_next_retire_slot),
        .barrier_active_3p_o(barrier_active_o),
        .raw_hazard_3p_o(raw_hazard), .waw_hazard_3p_o(waw_hazard),
        .read_port_hazard_3p_o(read_port_hazard),
        .write_busy_3p_o(dispatch_write_busy),
        .queue_count_3p_o(dispatch_occupancy_o),
        .committed_map_3p_o(rename_committed_map)
    );

    openrv64_rv64i_gpr_3p #(
        .ALLOW_DUPLICATE_WRITES(RELAX_WAW),
        .BANKED(BANKED_GPR),
        .FPGA_LUTRAM(FPGA_GPR_LUTRAM),
        .BANKED_READ_PORTS_PER_BANK(BANKED_GPR_READ_PORTS_PER_BANK),
        .BANKED_NUM_BANKS(BANKED_GPR_NUM_BANKS),
        .NUM_REGS(PHYS_REG_COUNT),
        .REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH)
    ) u_gpr (
        .clk(clk), .rst_n(rst_n),
        .read_addr_i(gpr_storage_read_addr), .read_data_o(gpr_read_data),
        .read_req_i(gpr_read_req), .read_ack_o(gpr_read_ack),
        .read_valid_o(gpr_read_valid),
        .write_valid_i(gpr_write), .write_addr_i(gpr_write_addr),
        .write_data_i(gpr_write_data),
        .write_ack_o(gpr_write_ack),
        .write_ready_o(gpr_write_ready),
        .quiescent_o(gpr_quiescent),
        .trace_read_group_denied_o(gpr_trace_read_group_denied),
        .trace_read_group_partial_o(gpr_trace_read_group_partial),
        .trace_read_early_accept_o(gpr_trace_read_early_accept)
    );

    // Simulation-visible architectural a0.  Under physical renaming the
    // stable u_gpr.regs[10] alias names p10, not x10; software-result checks
    // must follow the committed RRAT mapping instead.
    wire [PHYS_REG_ADDR_WIDTH-1:0] debug_arch_a0_phys =
        rename_committed_map[
            10*PHYS_REG_ADDR_WIDTH +: PHYS_REG_ADDR_WIDTH];
`ifndef SYNTHESIS
    wire [`RV64_XLEN-1:0] debug_arch_a0 =
        (debug_arch_a0_phys == {PHYS_REG_ADDR_WIDTH{1'b0}}) ?
        {`RV64_XLEN{1'b0}} : u_gpr.prf_debug_regs[
            (debug_arch_a0_phys-1)*`RV64_XLEN +: `RV64_XLEN];
`else
    wire [`RV64_XLEN-1:0] debug_arch_a0 = {`RV64_XLEN{1'b0}};
`endif

    // The legacy path uses the combinational post-retirement head to recover
    // a cycle of ordered-memory bandwidth.  That selector depends on the
    // current retire accept.  In banked mode it closes a loop through
    // retire -> ordered head -> LSQ -> translation ready -> retire.
    //
    // Banked mode instead presents the queue's current registered head.  The
    // next ordered request waits until the cycle after its predecessor
    // retires.  This is deliberately conservative and also keeps a dependent
    // load consumer behind physical GPR storage and scoreboard release.
    wire banked_ordered_head_valid =
        (retire_occupancy_o != 0) || (dispatch_occupancy_o != 0);
    wire ordered_head_valid = !flush_i && ((BANKED_GPR != 0) ?
        banked_ordered_head_valid :
        (queue_post_retire_valid || (dispatch_occupancy_o != 0)));
    wire [`OPENRV64_INSTR_ID_WIDTH-1:0] ordered_head_id =
        (BANKED_GPR != 0) ? next_retire_id :
        (queue_post_retire_valid ? queue_post_retire_id :
         allocation_id[0 +: `OPENRV64_INSTR_ID_WIDTH]);
    wire [SLOT_WIDTH-1:0] ordered_head_slot = (BANKED_GPR != 0) ?
        next_retire_slot : (queue_post_retire_valid ?
        queue_post_retire_slot : allocation_slot[0 +: SLOT_WIDTH]);

    openrv64_exec_top #(
        .BACKEND_CONFIG(`OPENRV64_BACKEND_3P),
        .RETIRE_SLOT_WIDTH_3P(SLOT_WIDTH), .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_RV64ZBB_3P(ENABLE_RV64ZBB),
        .ENABLE_LOCAL_FORWARDING_3P(
            (BANKED_GPR == 0) && (ENABLE_ISSUE_WINDOW == 0)),
        .ENABLE_SPECULATIVE_JALR_3P(
            (RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
            (ENABLE_SPECULATION_WINDOW != 0)),
        .ENABLE_POSTED_STORES(ENABLE_POSTED_STORES),
        .ENABLE_ZICCLSM_3P(ENABLE_ZICCLSM),
        .STORE_QUEUE_DEPTH_3P(STORE_QUEUE_DEPTH),
        .ENABLE_COHERENT_ATOMICS_3P(ENABLE_COHERENT_ATOMICS),
        .STORE_FORWARD_BASE(STORE_FORWARD_BASE),
        .STORE_FORWARD_SIZE(STORE_FORWARD_SIZE),
        .CACHEABLE_BASE_3P(CACHEABLE_BASE),
        .CACHEABLE_SIZE_3P(CACHEABLE_SIZE)
    ) u_exec (
        .clk(clk), .rst_n(rst_n),
        // Selective speculation recovery leaves already-issued operations in
        // flight.  Their bounded-lifetime modular IDs cannot match reallocated
        // retirement entries, while the resolving EX1 branch must still
        // publish its own completion on the following cycle.
        .flush_3p_i(flush_i ||
                    ((RENAME_MODE == `OPENRV64_RENAME_IDENTITY) &&
                     (ENABLE_ISSUE_WINDOW != 0) &&
                     (ENABLE_SPECULATION_WINDOW == 0) &&
                     squash_frontend_i)),
        .squash_younger_3p_i(
            (speculative_window ||
             (RENAME_MODE == `OPENRV64_RENAME_TOMASULO)) &&
            squash_frontend_i),
        .squash_id_3p_i(redirect_id_o),
        .coherent_reservation_clear_3p_i(
            coherent_reservation_clear_i),
        .translation_bypass_3p_i(translation_bypass_i),
        .valid_i(1'b0), .flush_ex_mem_i(1'b0),
        .flush_mem_wb_i(1'b0), .pc_i(64'd0), .instr_i(32'd0),
        .rs1_addr_i(5'd0), .rs2_addr_i(5'd0), .rs1_data_i(64'd0),
        .rs2_data_i(64'd0), .imm_i(64'd0), .rd_addr_i(5'd0),
        .alu_ext_i({`RV64_ALU_EXT_WIDTH{1'b0}}),
        .alu_op_i({`RV64_ALU_OP_WIDTH{1'b0}}),
        .lsu_op_i({`RV64_LSU_OP_WIDTH{1'b0}}),
        .br_op_i({`RV64_BR_OP_WIDTH{1'b0}}),
        .reg_write_i(1'b0), .mem_read_i(1'b0), .mem_write_i(1'b0),
        .branch_i(1'b0), .jump_i(1'b0), .predicted_taken_i(1'b0),
        .word_op_i(1'b0), .system_i(1'b0), .fence_i(1'b0),
        .illegal_i(1'b0), .ebreak_i(1'b0), .ecall_i(1'b0),
        .instr_access_fault_i(1'b0), .instr_page_fault_i(1'b0),
        .priv_mode_i({`RV64_PRIV_WIDTH{1'b0}}),
        .sret_allowed_i(1'b0), .sfence_vma_allowed_i(1'b0),
        .wb_clear_i(1'b0), .trace_id_i(64'd0),
        .issue_valid_3p_i(pipe_valid), .issue_ready_3p_o(pipe_ready),
        .base_alu_available_3p_o(base_alu_available),
        .issue_unsupported_3p_o(pipe_unsupported),
        .issue_id_3p_i(pipe_id), .issue_slot_3p_i(pipe_slot),
        .issue_payload_3p_i(pipe_payload),
        .branch_forward_valid_3p_i((BANKED_GPR == 0) &&
            branch_completion_forward_valid[0]),
        .branch_forward_tag_3p_i(
            (BANKED_GPR == 0) ?
                complete_id[0 +: `OPENRV64_INSTR_ID_WIDTH] :
                {`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .branch_forward_rd_addr_3p_i(
            (BANKED_GPR == 0) ? completion_forward_rd_addr[
                0 +: `RV64_REG_ADDR_WIDTH] : `RV64_REG_X0),
        .branch_forward_data_3p_i(
            (BANKED_GPR == 0) ?
                completion_forward_data[0 +: `RV64_XLEN] :
                {`RV64_XLEN{1'b0}}),
        .issue_src1_producer_valid_3p_i(pipe_src1_producer_valid),
        .issue_src1_producer_tag_3p_i(pipe_src1_producer_id),
        .issue_src2_producer_valid_3p_i(pipe_src2_producer_valid),
        .issue_src2_producer_tag_3p_i(pipe_src2_producer_id),
        .ordered_head_valid_3p_i(ordered_head_valid),
        .ordered_head_id_3p_i(ordered_head_id),
        .ordered_head_slot_3p_i(ordered_head_slot),
        .store_barrier_request_3p_o(store_barrier_request_o),
        .store_barrier_busy_3p_i(store_barrier_busy_i),
        .complete_valid_3p_o(complete_valid),
        .complete_ready_3p_i(exec_complete_ready),
        .complete_id_3p_o(complete_id),
        .complete_slot_3p_o(complete_slot),
        .complete_payload_3p_o(complete_payload),
        .async_store_fault_3p_o(async_store_fault),
        .async_store_page_fault_3p_o(async_store_page_fault),
        .async_store_fault_pc_3p_o(async_store_fault_pc),
        .async_store_fault_addr_3p_o(async_store_fault_addr),
        .async_store_fault_trace_3p_o(async_store_fault_trace),
        .async_store_fault_instr_3p_o(async_store_fault_instr),
        .redirect_valid_o(exec_redirect_valid),
        .redirect_id_3p_o(exec_redirect_id),
        .redirect_slot_3p_o(exec_redirect_slot),
        .redirect_target_o(exec_redirect_target),
        .branch_resolved_o(exec_branch_resolved),
        .branch_conditional_o(exec_branch_conditional),
        .branch_taken_o(exec_branch_taken),
        .branch_pc_o(exec_branch_pc),
        .branch_instr_o(exec_branch_instr),
        .csr_addr_o(csr_addr_o), .csr_rdata_i(csr_rdata_i),
        .csr_valid_i(csr_valid_i), .csr_writable_i(csr_writable_i),
        .csr_busy_i(1'b0),
        .mem_valid_o(mem_valid_o), .mem_ready_i(mem_ready_i),
        .mem_tag_o(mem_tag_o), .mem_resp_valid_i(mem_resp_valid_i),
        .mem_xlate_only_o(mem_xlate_only_o),
        .mem_physical_o(mem_physical_o),
        .mem_pmp_checked_o(mem_pmp_checked_o),
        .mem_resp_ready_o(mem_resp_ready_o),
        .mem_resp_tag_i(mem_resp_tag_i),
        .mem_store_done_valid_i(mem_store_done_valid_i),
        .mem_store_done_ready_o(mem_store_done_ready_o),
        .mem_store_done_tag_i(mem_store_done_tag_i),
        .mem_resp_paddr_i(mem_resp_paddr_i),
        .mem_error_i(mem_error_i), .mem_page_fault_i(mem_page_fault_i),
        .mem_access_allowed_i(mem_access_allowed_i),
        .mem_lock_o(mem_lock_o),
        .mem_write_o(mem_write_o), .mem_addr_o(mem_addr_o),
        .mem_wdata_o(mem_wdata_o), .mem_wstrb_o(mem_wstrb_o),
        .mem_access_o(mem_access_o),
        .mem_effective_addr_o(mem_effective_addr_o),
        .mem_size_o(mem_size_o),
        .mem_xlate_valid_o(mem_xlate_valid_o),
        .mem_xlate_ready_i(mem_xlate_ready_i),
        .mem_xlate_tag_o(mem_xlate_tag_o),
        .mem_xlate_write_o(mem_xlate_write_o),
        .mem_xlate_size_o(mem_xlate_size_o),
        .mem_xlate_vaddr_o(mem_xlate_vaddr_o),
        .mem_xlate_resp_valid_i(mem_xlate_resp_valid_i),
        .mem_xlate_resp_ready_o(mem_xlate_resp_ready_o),
        .mem_xlate_resp_tag_i(mem_xlate_resp_tag_i),
        .mem_xlate_resp_paddr_i(mem_xlate_resp_paddr_i),
        .mem_xlate_resp_access_fault_i(mem_xlate_resp_access_fault_i),
        .mem_xlate_resp_page_fault_i(mem_xlate_resp_page_fault_i),
        .mem_rdata_i(mem_rdata_i),
        .mem1_valid_o(mem1_valid_o), .mem1_ready_i(mem1_ready_i),
        .mem1_tag_o(mem1_tag_o), .mem1_lock_o(mem1_lock_o),
        .mem1_write_o(mem1_write_o), .mem1_addr_o(mem1_addr_o),
        .mem1_wdata_o(mem1_wdata_o), .mem1_wstrb_o(mem1_wstrb_o),
        .mem1_access_o(mem1_access_o),
        .mem1_effective_addr_o(mem1_effective_addr_o),
        .mem1_size_o(mem1_size_o)
    );

    openrv64_retire_queue_3p #(
        .DEPTH(RETIRE_DEPTH),
        .ID_WIDTH(`OPENRV64_INSTR_ID_WIDTH),
        .INDEX_WIDTH(SLOT_WIDTH)
    ) u_retire_queue (
        .clk(clk), .rst_n(rst_n),
        .flush_i(flush_i ||
                 ((RENAME_MODE == `OPENRV64_RENAME_IDENTITY) &&
                  (ENABLE_ISSUE_WINDOW != 0) &&
                  (ENABLE_SPECULATION_WINDOW == 0) &&
                  squash_frontend_i)),
        .squash_younger_i(
            (((speculative_window ||
               (RENAME_MODE == `OPENRV64_RENAME_TOMASULO)) &&
              squash_frontend_i)) ||
            banked_deferred_pair_recovery),
        .squash_id_i(redirect_id_o),
        .squash_slot_i(branch_slot_o),
        .alloc_valid_i(allocation_valid),
        .alloc_ready_o(queue_allocation_ready),
        .alloc_accept_o(queue_alloc_accept),
        .alloc_complete_i(allocation_complete),
        .alloc_id_o(allocation_id),
        .alloc_slot_o(allocation_slot),
        .complete_valid_i(completion_fire), .complete_id_i(complete_id),
        .complete_slot_i(complete_slot),
        .complete_match_o(queue_complete_match),
        .complete_accept_o(queue_complete_accept),
        .extension_complete_valid_i(1'b0),
        .extension_complete_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .extension_complete_slot_i({SLOT_WIDTH{1'b0}}),
        .extension_complete_accept_o(),
        .retire_valid_o(queue_retire_valid),
        .retire_accept_i(queue_retire_accept),
        .retire_id_o(queue_retire_id),
        .retire_slot_o(queue_retire_slot),
        .completed_entry_valid_o(completed_entry_valid),
        .occupancy_o(retire_occupancy_o),
        .next_retire_id_o(next_retire_id),
        .next_retire_slot_o(next_retire_slot),
        .post_retire_valid_o(queue_post_retire_valid),
        .post_retire_id_o(queue_post_retire_id),
        .post_retire_slot_o(queue_post_retire_slot)
    );

    openrv64_retire_records_3p #(
        .DEPTH(RETIRE_DEPTH),
        .SLOT_WIDTH(SLOT_WIDTH),
        .ALLOC_WIDTH(RETIRE_RECORD_WIDTH),
        .RESULT_WIDTH(RETIRE_RESULT_WIDTH),
        .ENABLE_TRACE(ENABLE_TRACE)
    ) u_retire_records (
        .clk(clk),
        .alloc_valid_i(queue_alloc_accept),
        .alloc_slot_i(allocation_slot),
        .alloc_record_i(allocation_record),
        .alloc_complete_i(allocation_complete),
        .alloc_result_valid_i(allocation_complete),
        .alloc_result_i(allocation_retire_result),
        .alloc_trace_i(allocation_trace),
        .complete_valid_i(queue_complete_accept),
        .complete_slot_i(complete_slot),
        .complete_result_i(complete_retire_result),
        .read_slot_i(queue_retire_slot),
        .read_record_o(queue_retire_record),
        .read_result_o(queue_retire_commit),
        .read_trace_o(queue_retire_trace),
        .complete_read_slot_i(complete_slot),
        .complete_read_record_o(queue_complete_record)
    );

`ifndef SYNTHESIS
    // Simulation-only compatibility view for system benches and trace tools
    // that inspect the historical completion packet.  This is reconstructed
    // from the canonical record selected for each retire lane; no copy of this
    // 457-bit packet exists in synthesized retirement storage.
    wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        queue_retire_result;
    genvar debug_retire_lane;
    generate
        for (debug_retire_lane = 0; debug_retire_lane < 3;
             debug_retire_lane = debug_retire_lane + 1) begin :
                g_debug_retire_result
            reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                debug_result;
            always @* begin
                debug_result =
                    {`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH{1'b0}};
                debug_result[0 +: 153] = queue_retire_commit[
                    debug_retire_lane*RETIRE_RESULT_WIDTH +: 153];
                debug_result[153] = queue_retire_record[
                    debug_retire_lane*RETIRE_RECORD_WIDTH +
                    `OPENRV64_RETIRE_ALLOC_REG_WRITE_BIT];
                debug_result[154 +: `RV64_REG_ADDR_WIDTH] =
                    queue_retire_record[
                        debug_retire_lane*RETIRE_RECORD_WIDTH +
                        `OPENRV64_RETIRE_ALLOC_RD_LSB +:
                        `RV64_REG_ADDR_WIDTH];
                debug_result[159 +: `RV64_REG_ADDR_WIDTH] =
                    queue_retire_record[
                        debug_retire_lane*RETIRE_RECORD_WIDTH +
                        `OPENRV64_RETIRE_ALLOC_RS2_LSB +:
                        `RV64_REG_ADDR_WIDTH];
                debug_result[164 +: `RV64_REG_ADDR_WIDTH] =
                    queue_retire_record[
                        debug_retire_lane*RETIRE_RECORD_WIDTH +
                        `OPENRV64_RETIRE_ALLOC_RS1_LSB +:
                        `RV64_REG_ADDR_WIDTH];
                debug_result[169 +: `RV64_XLEN] = queue_retire_commit[
                    debug_retire_lane*RETIRE_RESULT_WIDTH +
                    `OPENRV64_RETIRE_RESULT_DATA_LSB +: `RV64_XLEN];
                debug_result[233 +: `RV64_INSTR_WIDTH] =
                    queue_retire_record[
                        debug_retire_lane*RETIRE_RECORD_WIDTH +
                        `OPENRV64_RETIRE_ALLOC_INSTR_LSB +:
                        `RV64_INSTR_WIDTH];
                debug_result[265 +: `RV64_XLEN] = queue_retire_commit[
                    debug_retire_lane*RETIRE_RESULT_WIDTH +
                    `OPENRV64_RETIRE_RESULT_NEXT_PC_LSB +: `RV64_XLEN];
                debug_result[329 +: `RV64_XLEN] = queue_retire_record[
                    debug_retire_lane*RETIRE_RECORD_WIDTH +
                    `OPENRV64_RETIRE_ALLOC_PC_LSB +: `RV64_XLEN];
                debug_result[393 +: 64] = queue_retire_trace[
                    debug_retire_lane*64 +: 64];
            end
            assign queue_retire_result[
                debug_retire_lane*
                `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH] = debug_result;
        end
    endgenerate
`endif

    // A delayed store failure is delivered alone at an architectural
    // boundary.  Holding the normal retirement inputs for this cycle avoids
    // consuming a precise exception or hard-order operation underneath the
    // imprecise abort.
    wire [2:0] retire_queue_valid = async_store_fault_pending_q ?
                                    3'b000 : queue_retire_valid;
    generate
        if (BANKED_GPR != 0) begin : g_banked_retire
            wire [1:0] banked_gpr_write;
            wire [2*PHYS_REG_ADDR_WIDTH-1:0] banked_gpr_write_addr;
            wire [2*`RV64_XLEN-1:0] banked_gpr_write_data;
            wire [1:0] banked_free_valid;
            wire [2*PHYS_REG_ADDR_WIDTH-1:0] banked_free_tag;

            assign gpr_write =
                (RENAME_MODE == `OPENRV64_RENAME_TOMASULO) ?
                completion_prf_sorted_req : {1'b0, banked_gpr_write};
            assign gpr_write_addr =
                (RENAME_MODE == `OPENRV64_RENAME_TOMASULO) ?
                completion_prf_sorted_tag : {
                    {PHYS_REG_ADDR_WIDTH{1'b0}}, banked_gpr_write_addr
                };
            assign gpr_write_data =
                (RENAME_MODE == `OPENRV64_RENAME_TOMASULO) ?
                completion_prf_sorted_data : {
                    {`RV64_XLEN{1'b0}}, banked_gpr_write_data
                };

            openrv64_retire_3p_banked #(
                .PHYS_REG_COUNT(PHYS_REG_COUNT),
                .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
                .META_WIDTH(RETIRE_RECORD_WIDTH),
                .RESULT_WIDTH(RETIRE_RESULT_WIDTH),
                .BYPASS_GPR_WRITE(
                    RENAME_MODE == `OPENRV64_RENAME_TOMASULO),
                .GPR_BANK_COUNT(BANKED_GPR_NUM_BANKS)
            ) u_retire (
                .clk(clk), .rst_n(rst_n), .flush_i(flush_i),
                .queue_valid_i(retire_queue_valid),
                .queue_meta_i(queue_retire_record),
                .queue_result_i(queue_retire_commit),
                .queue_trace_id_i(queue_retire_trace),
                .queue_accept_o(queue_retire_accept),
                .extension_ready_i(3'b111),
                .extension_gpr_result_valid_i(3'b000),
                .extension_gpr_result_i({3*`RV64_XLEN{1'b0}}),
                .extension_exception_i(3'b000),
                .extension_cause_i(
                    {3*`RV64_EXCEPT_CAUSE_WIDTH{1'b0}}),
                .extension_tval_i({3*`RV64_XLEN{1'b0}}),
                .csr_write_ready_i(csr_write_ready_i),
                .irq_pending_i(irq_pending_i),
                .irq_cause_i(irq_cause_i),
                .retire_arch_o(retire_arch_o),
                .retire_count_o(retire_count_o),
                .retire_hard_o(retire_hard),
                .release_valid_o(release_valid),
                .release_uses_rs1_o(release_uses_rs1),
                .release_uses_rs2_o(release_uses_rs2),
                .release_rs1_addr_o(release_rs1_addr),
                .release_rs2_addr_o(release_rs2_addr),
                .release_reg_write_o(release_reg_write),
                .release_rd_addr_o(release_rd_addr),
                .gpr_write_o(banked_gpr_write),
                .gpr_rd_addr_o(banked_gpr_write_addr),
                .gpr_rd_data_o(banked_gpr_write_data),
                .gpr_write_ack_i(gpr_write_ack[1:0]),
                .free_valid_o(banked_free_valid),
                .free_tag_o(banked_free_tag),
                .csr_write_o(csr_write_o),
                .csr_addr_o(csr_write_addr_o),
                .csr_op_o(csr_op_o), .csr_wdata_o(csr_wdata_o),
                .exception_o(retire_exception), .halt_o(retire_halt),
                .irq_o(retire_irq), .mret_o(retire_mret),
                .sret_o(retire_sret), .fence_i_o(retire_fence_i),
                .sfence_vma_o(retire_sfence_vma),
                .cause_o(retire_cause), .pc_o(retire_pc),
                .next_pc_o(retire_next_pc), .tval_o(retire_tval),
                .trace_id_o(retire_trace_id), .instr_o(retire_instr),
                .trace_rd_o(retire_rd_o),
                .trace_wdata_o(retire_wdata_o)
            );
            assign banked_retire_write_pair_conflict =
                u_retire.direct_write_pair_conflict;
            assign rename_free_valid = banked_free_valid;
            assign rename_free_tag = banked_free_tag;
        end else begin : g_legacy_retire
            assign banked_retire_write_pair_conflict = 1'b0;
            assign rename_free_valid = 2'b00;
            assign rename_free_tag =
                {2*PHYS_REG_ADDR_WIDTH{1'b0}};
            openrv64_retire_3p #(
                .PHYS_REG_COUNT(PHYS_REG_COUNT),
                .PHYS_REG_ADDR_WIDTH(PHYS_REG_ADDR_WIDTH),
                .META_WIDTH(RETIRE_RECORD_WIDTH),
                .RESULT_WIDTH(RETIRE_RESULT_WIDTH)
            ) u_retire (
                .queue_valid_i(retire_queue_valid),
                .queue_meta_i(queue_retire_record),
                .queue_result_i(queue_retire_commit),
                .queue_trace_id_i(queue_retire_trace),
                .queue_accept_o(queue_retire_accept),
                .extension_ready_i(3'b111),
                .extension_gpr_result_valid_i(3'b000),
                .extension_gpr_result_i({3*`RV64_XLEN{1'b0}}),
                .extension_exception_i(3'b000),
                .extension_cause_i(
                    {3*`RV64_EXCEPT_CAUSE_WIDTH{1'b0}}),
                .extension_tval_i({3*`RV64_XLEN{1'b0}}),
                .csr_write_ready_i(csr_write_ready_i),
                .irq_pending_i(irq_pending_i),
                .irq_cause_i(irq_cause_i),
                .retire_arch_o(retire_arch_o),
                .retire_count_o(retire_count_o),
                .retire_hard_o(retire_hard),
                .release_valid_o(release_valid),
                .release_uses_rs1_o(release_uses_rs1),
                .release_uses_rs2_o(release_uses_rs2),
                .release_rs1_addr_o(release_rs1_addr),
                .release_rs2_addr_o(release_rs2_addr),
                .release_reg_write_o(release_reg_write),
                .release_rd_addr_o(release_rd_addr),
                .gpr_write_o(gpr_write),
                .gpr_rd_addr_o(gpr_write_addr),
                .gpr_rd_data_o(gpr_write_data),
                .csr_write_o(csr_write_o),
                .csr_addr_o(csr_write_addr_o),
                .csr_op_o(csr_op_o), .csr_wdata_o(csr_wdata_o),
                .exception_o(retire_exception), .halt_o(retire_halt),
                .irq_o(retire_irq), .mret_o(retire_mret),
                .sret_o(retire_sret), .fence_i_o(retire_fence_i),
                .sfence_vma_o(retire_sfence_vma),
                .cause_o(retire_cause), .pc_o(retire_pc),
                .next_pc_o(retire_next_pc), .tval_o(retire_tval),
                .trace_id_o(retire_trace_id), .instr_o(retire_instr),
                .trace_rd_o(retire_rd_o),
                .trace_wdata_o(retire_wdata_o)
            );
        end
    endgenerate

`ifndef SYNTHESIS
    /*
     * Simulation-only speculative-memory outcome accounting.  The LSQ knows
     * whether an operation crossed its allocation boundary before becoming
     * the ordered head, while retirement owns the architectural outcome.
     * Retain that one bit in a shadow bank indexed by the retirement slot.
     */
    reg perf_mem_seen_q [0:RETIRE_DEPTH-1];
    reg perf_mem_spec_q [0:RETIRE_DEPTH-1];
    reg [63:0] perf_lsq_load_retired_q;
    reg [63:0] perf_lsq_load_spec_retired_q;
    reg [63:0] perf_lsq_load_ordered_retired_q;
    reg [63:0] perf_lsq_store_retired_q;
    reg [63:0] perf_lsq_store_spec_retired_q;
    reg [63:0] perf_lsq_store_ordered_retired_q;
    reg [63:0] perf_lsq_retired_untracked_q;
    integer perf_mem_slot;
    integer perf_mem_lane;
    integer perf_count_lane;
    integer perf_load_retired_count_r;
    integer perf_load_spec_retired_count_r;
    integer perf_load_ordered_retired_count_r;
    integer perf_store_retired_count_r;
    integer perf_store_spec_retired_count_r;
    integer perf_store_ordered_retired_count_r;
    integer perf_retired_untracked_count_r;
    reg [SLOT_WIDTH-1:0] perf_retire_slot_r;
    reg [SLOT_WIDTH-1:0] perf_count_slot_r;
    reg [RETIRE_RECORD_WIDTH-1:0] perf_count_record_r;

    always @* begin
        perf_load_retired_count_r = 0;
        perf_load_spec_retired_count_r = 0;
        perf_load_ordered_retired_count_r = 0;
        perf_store_retired_count_r = 0;
        perf_store_spec_retired_count_r = 0;
        perf_store_ordered_retired_count_r = 0;
        perf_retired_untracked_count_r = 0;
        perf_count_slot_r = {SLOT_WIDTH{1'b0}};
        perf_count_record_r = {RETIRE_RECORD_WIDTH{1'b0}};
        for (perf_count_lane = 0;
             perf_count_lane < 3;
             perf_count_lane = perf_count_lane + 1) begin
            perf_count_slot_r = queue_retire_slot[
                perf_count_lane*SLOT_WIDTH +: SLOT_WIDTH];
            perf_count_record_r = queue_retire_record[
                perf_count_lane*RETIRE_RECORD_WIDTH +:
                RETIRE_RECORD_WIDTH];
            if (retire_arch_o[perf_count_lane] &&
                perf_count_record_r[
                    `OPENRV64_RETIRE_ALLOC_MEM_WRITE_BIT]) begin
                perf_store_retired_count_r =
                    perf_store_retired_count_r + 1;
                if (perf_mem_seen_q[perf_count_slot_r] &&
                    perf_mem_spec_q[perf_count_slot_r])
                    perf_store_spec_retired_count_r =
                        perf_store_spec_retired_count_r + 1;
                else
                    perf_store_ordered_retired_count_r =
                        perf_store_ordered_retired_count_r + 1;
                if (!perf_mem_seen_q[perf_count_slot_r])
                    perf_retired_untracked_count_r =
                        perf_retired_untracked_count_r + 1;
            end else if (retire_arch_o[perf_count_lane] &&
                         perf_count_record_r[
                             `OPENRV64_RETIRE_ALLOC_MEM_READ_BIT]) begin
                perf_load_retired_count_r =
                    perf_load_retired_count_r + 1;
                if (perf_mem_seen_q[perf_count_slot_r] &&
                    perf_mem_spec_q[perf_count_slot_r])
                    perf_load_spec_retired_count_r =
                        perf_load_spec_retired_count_r + 1;
                else
                    perf_load_ordered_retired_count_r =
                        perf_load_ordered_retired_count_r + 1;
                if (!perf_mem_seen_q[perf_count_slot_r])
                    perf_retired_untracked_count_r =
                        perf_retired_untracked_count_r + 1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_lsq_load_retired_q <= 64'd0;
            perf_lsq_load_spec_retired_q <= 64'd0;
            perf_lsq_load_ordered_retired_q <= 64'd0;
            perf_lsq_store_retired_q <= 64'd0;
            perf_lsq_store_spec_retired_q <= 64'd0;
            perf_lsq_store_ordered_retired_q <= 64'd0;
            perf_lsq_retired_untracked_q <= 64'd0;
            for (perf_mem_slot = 0;
                 perf_mem_slot < RETIRE_DEPTH;
                 perf_mem_slot = perf_mem_slot + 1) begin
                perf_mem_seen_q[perf_mem_slot] <= 1'b0;
                perf_mem_spec_q[perf_mem_slot] <= 1'b0;
            end
        end else begin
            perf_lsq_load_retired_q <= perf_lsq_load_retired_q +
                perf_load_retired_count_r;
            perf_lsq_load_spec_retired_q <=
                perf_lsq_load_spec_retired_q +
                perf_load_spec_retired_count_r;
            perf_lsq_load_ordered_retired_q <=
                perf_lsq_load_ordered_retired_q +
                perf_load_ordered_retired_count_r;
            perf_lsq_store_retired_q <= perf_lsq_store_retired_q +
                perf_store_retired_count_r;
            perf_lsq_store_spec_retired_q <=
                perf_lsq_store_spec_retired_q +
                perf_store_spec_retired_count_r;
            perf_lsq_store_ordered_retired_q <=
                perf_lsq_store_ordered_retired_q +
                perf_store_ordered_retired_count_r;
            perf_lsq_retired_untracked_q <=
                perf_lsq_retired_untracked_q +
                perf_retired_untracked_count_r;
            for (perf_mem_lane = 0;
                 perf_mem_lane < 3;
                 perf_mem_lane = perf_mem_lane + 1) begin
                perf_retire_slot_r = queue_retire_slot[
                    perf_mem_lane*SLOT_WIDTH +: SLOT_WIDTH];
                if (queue_retire_accept[perf_mem_lane])
                    perf_mem_seen_q[perf_retire_slot_r] <= 1'b0;
            end

            // Clear every newly allocated slot, including non-memory work.
            // A later LSQ allocation below records the memory classification.
            for (perf_mem_lane = 0;
                 perf_mem_lane < 3;
                 perf_mem_lane = perf_mem_lane + 1) begin
                if (queue_alloc_accept[perf_mem_lane]) begin
                    perf_mem_seen_q[allocation_slot[
                        perf_mem_lane*SLOT_WIDTH +:
                        SLOT_WIDTH]] <= 1'b0;
                    perf_mem_spec_q[allocation_slot[
                        perf_mem_lane*SLOT_WIDTH +:
                        SLOT_WIDTH]] <= 1'b0;
                end
            end
            if (u_exec.g_3p.u_exec.u_lsu.u_lsq.load_alloc_fire) begin
                perf_mem_seen_q[
                    u_exec.g_3p.u_exec.u_lsu.u_lsq.load_alloc_slot_i] <=
                    1'b1;
                perf_mem_spec_q[
                    u_exec.g_3p.u_exec.u_lsu.u_lsq.load_alloc_slot_i] <=
                    !u_exec.g_3p.u_exec.u_lsu.u_lsq
                        .perf_load_alloc_order_match;
            end
            if (u_exec.g_3p.u_exec.u_lsu.u_lsq.store_alloc_fire) begin
                perf_mem_seen_q[
                    u_exec.g_3p.u_exec.u_lsu.u_lsq.store_alloc_slot_i] <=
                    1'b1;
                perf_mem_spec_q[
                    u_exec.g_3p.u_exec.u_lsu.u_lsq.store_alloc_slot_i] <=
                    !u_exec.g_3p.u_exec.u_lsu.u_lsq
                        .perf_store_alloc_order_match;
            end
            if (flush_i) begin
                for (perf_mem_slot = 0;
                     perf_mem_slot < RETIRE_DEPTH;
                     perf_mem_slot = perf_mem_slot + 1)
                    perf_mem_seen_q[perf_mem_slot] <= 1'b0;
            end
        end
    end
`endif

    // The store has already retired, so this is deliberately not a precise
    // replay point.  Trap at the next unretired architectural PC, retain the
    // original store address in tval, and retain its trace metadata for
    // diagnostics.
    wire [`RV64_XLEN-1:0] async_abort_pc =
        (last_arch_next_pc_q != {`RV64_XLEN{1'b0}}) ?
        last_arch_next_pc_q : (async_store_fault_pc_q + 64'd4);
    assign exception_o = async_store_fault_pending_q || retire_exception;
    assign halt_o = !async_store_fault_pending_q && retire_halt;
    assign irq_o = !async_store_fault_pending_q && retire_irq;
    assign mret_o = !async_store_fault_pending_q && retire_mret;
    assign sret_o = !async_store_fault_pending_q && retire_sret;
    assign fence_i_o = !async_store_fault_pending_q && retire_fence_i;
    assign sfence_vma_o = !async_store_fault_pending_q && retire_sfence_vma;
    assign cause_o = async_store_fault_pending_q ?
                     async_store_fault_cause_q : retire_cause;
    assign retire_pc_o = async_store_fault_pending_q ?
                         async_abort_pc : retire_pc;
    assign retire_next_pc_o = async_store_fault_pending_q ?
                              async_abort_pc : retire_next_pc;
    assign retire_tval_o = async_store_fault_pending_q ?
                           async_store_fault_addr_q : retire_tval;
    assign retire_trace_id_o = async_store_fault_pending_q ?
                               async_store_fault_trace_q : retire_trace_id;
    assign retire_instr_o = async_store_fault_pending_q ?
                            async_store_fault_instr_q : retire_instr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            async_store_fault_pending_q <= 1'b0;
            async_store_fault_cause_q <=
                `RV64_EXCEPT_CAUSE_STORE_ACCESS_FAULT;
            async_store_fault_addr_q <= {`RV64_XLEN{1'b0}};
            async_store_fault_pc_q <= {`RV64_XLEN{1'b0}};
            async_store_fault_trace_q <= 64'd0;
            async_store_fault_instr_q <= {`RV64_INSTR_WIDTH{1'b0}};
            last_arch_next_pc_q <= {`RV64_XLEN{1'b0}};
        end else begin
            if (|retire_arch_o)
                last_arch_next_pc_q <= retire_next_pc;

            // Capture wins over a simultaneous flush: the bus response is a
            // one-cycle event and must not disappear behind another redirect.
            if (async_store_fault) begin
                async_store_fault_pending_q <= 1'b1;
                async_store_fault_cause_q <= async_store_page_fault ?
                    `RV64_EXCEPT_CAUSE_STORE_PAGE_FAULT :
                    `RV64_EXCEPT_CAUSE_STORE_ACCESS_FAULT;
                async_store_fault_addr_q <= async_store_fault_addr;
                async_store_fault_pc_q <= async_store_fault_pc;
                async_store_fault_trace_q <= async_store_fault_trace;
                async_store_fault_instr_q <= async_store_fault_instr;
            end else if (flush_i || async_store_fault_pending_q) begin
                async_store_fault_pending_q <= 1'b0;
            end
        end
    end

    assign issue_valid_o = pipe_valid;
    assign complete_valid_o = complete_valid;

    wire unused_diagnostics = |{
        queue_retire_id, pipe_unsupported, raw_hazard, waw_hazard,
        read_port_hazard
    };

`ifndef SYNTHESIS
    localparam integer BANKED_GPR_ACCESS_TIMEOUT = 100;
    reg [6:0] banked_gpr_read_wait_q [0:5];
    reg [6:0] banked_gpr_write_wait_q [0:1];
    reg [6:0] banked_gpr_drain_wait_q;
    reg [5:0] banked_gpr_read_held_q;
    reg [6*PHYS_REG_ADDR_WIDTH-1:0] banked_gpr_read_held_addr_q;
    integer banked_read_watch_port;
    integer banked_write_watch_port;
    integer banked_hold_watch_port;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || (BANKED_GPR == 0) || flush_i ||
            squash_frontend_i) begin
            banked_gpr_read_held_q <= 6'b000000;
            banked_gpr_read_held_addr_q <=
                {6*PHYS_REG_ADDR_WIDTH{1'b0}};
        end else begin
            for (banked_hold_watch_port = 0;
                 banked_hold_watch_port < 6;
                 banked_hold_watch_port = banked_hold_watch_port + 1) begin
                if (banked_gpr_read_held_q[banked_hold_watch_port] &&
                    (!gpr_read_req[banked_hold_watch_port] ||
                     (gpr_storage_read_addr[
                          banked_hold_watch_port*PHYS_REG_ADDR_WIDTH +:
                          PHYS_REG_ADDR_WIDTH] !=
                      banked_gpr_read_held_addr_q[
                          banked_hold_watch_port*PHYS_REG_ADDR_WIDTH +:
                          PHYS_REG_ADDR_WIDTH])))
                    $fatal(1,
                           "banked 3P GPR read port %0d changed before address ack: prev_addr=%0d req=%b ack=%b addr=%0d",
                           banked_hold_watch_port,
                           banked_gpr_read_held_addr_q[
                               banked_hold_watch_port*PHYS_REG_ADDR_WIDTH +:
                               PHYS_REG_ADDR_WIDTH],
                           gpr_read_req[banked_hold_watch_port],
                           gpr_read_ack[banked_hold_watch_port],
                           gpr_storage_read_addr[
                               banked_hold_watch_port*PHYS_REG_ADDR_WIDTH +:
                               PHYS_REG_ADDR_WIDTH]);
            end
            banked_gpr_read_held_q <= gpr_read_req & ~gpr_read_ack;
            banked_gpr_read_held_addr_q <= gpr_storage_read_addr;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (banked_read_watch_port = 0;
                 banked_read_watch_port < 6;
                 banked_read_watch_port = banked_read_watch_port + 1)
                banked_gpr_read_wait_q[banked_read_watch_port] <= 7'd0;
            for (banked_write_watch_port = 0;
                 banked_write_watch_port < 2;
                 banked_write_watch_port = banked_write_watch_port + 1)
                banked_gpr_write_wait_q[banked_write_watch_port] <= 7'd0;
        end else if (BANKED_GPR != 0) begin
            for (banked_read_watch_port = 0;
                 banked_read_watch_port < 6;
                 banked_read_watch_port = banked_read_watch_port + 1) begin
                if (!gpr_read_req[banked_read_watch_port] ||
                    gpr_read_ack[banked_read_watch_port]) begin
                    banked_gpr_read_wait_q[banked_read_watch_port] <= 7'd0;
                end else if (banked_gpr_read_wait_q[
                                 banked_read_watch_port] ==
                             BANKED_GPR_ACCESS_TIMEOUT - 1) begin
                    $fatal(1,
                           "banked 3P GPR read port %0d timed out after %0d cycles (addr=%0d)",
                           banked_read_watch_port,
                           BANKED_GPR_ACCESS_TIMEOUT,
                           gpr_storage_read_addr[
                               banked_read_watch_port*
                               PHYS_REG_ADDR_WIDTH +:
                               PHYS_REG_ADDR_WIDTH]);
                end else begin
                    banked_gpr_read_wait_q[banked_read_watch_port] <=
                        banked_gpr_read_wait_q[banked_read_watch_port] +
                        7'd1;
                end
            end

            for (banked_write_watch_port = 0;
                 banked_write_watch_port < 2;
                 banked_write_watch_port = banked_write_watch_port + 1) begin
                if (!gpr_write[banked_write_watch_port] ||
                    gpr_write_ack[banked_write_watch_port]) begin
                    banked_gpr_write_wait_q[banked_write_watch_port] <=
                        7'd0;
                end else if (banked_gpr_write_wait_q[
                                 banked_write_watch_port] ==
                             BANKED_GPR_ACCESS_TIMEOUT - 1) begin
                    $fatal(1,
                           "banked 3P GPR write port %0d timed out after %0d cycles (addr=%0d)",
                           banked_write_watch_port,
                           BANKED_GPR_ACCESS_TIMEOUT,
                           gpr_write_addr[
                               banked_write_watch_port*
                               PHYS_REG_ADDR_WIDTH +:
                               PHYS_REG_ADDR_WIDTH]);
                end else begin
                    banked_gpr_write_wait_q[banked_write_watch_port] <=
                        banked_gpr_write_wait_q[banked_write_watch_port] +
                        7'd1;
                end
            end
        end else begin
            for (banked_read_watch_port = 0;
                 banked_read_watch_port < 6;
                 banked_read_watch_port = banked_read_watch_port + 1)
                banked_gpr_read_wait_q[banked_read_watch_port] <= 7'd0;
            for (banked_write_watch_port = 0;
                 banked_write_watch_port < 2;
                 banked_write_watch_port = banked_write_watch_port + 1)
                banked_gpr_write_wait_q[banked_write_watch_port] <= 7'd0;
        end
    end

    // The redirect drain bounds the whole abandoned group as well as the
    // per-port request watchdogs above.  It also covers the registered
    // response cycle after the final held request is acknowledged.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || (BANKED_GPR == 0) || !banked_gpr_drain_q ||
            !gpr_access_pending) begin
            banked_gpr_drain_wait_q <= 7'd0;
        end else if (banked_gpr_drain_wait_q ==
                     BANKED_GPR_ACCESS_TIMEOUT - 1) begin
            $fatal(1,
                   "banked 3P GPR redirect drain timed out after %0d cycles",
                   BANKED_GPR_ACCESS_TIMEOUT);
        end else begin
            banked_gpr_drain_wait_q <= banked_gpr_drain_wait_q + 7'd1;
        end
    end

    initial begin
        if ((FREE_BRANCHES != 0) &&
            (ENABLE_ISSUE_WINDOW != 0))
            $fatal(1, "free branches require strict dispatch path");
        if ((ENABLE_ISSUE_WINDOW != 0) &&
            (RENAME_MODE != `OPENRV64_RENAME_TOMASULO) &&
            (ISSUE_WINDOW_DEPTH != RETIRE_DEPTH))
            $fatal(1,
                   "identity issue-window depth must equal retirement depth");
        if ((ENABLE_SPECULATION_WINDOW != 0) &&
            (ENABLE_ISSUE_WINDOW == 0))
            $fatal(1, "speculation window requires issue window");
        if ((BANKED_GPR != 0) && (FREE_BRANCHES != 0))
            $fatal(1,
                   "banked 3P must resolve branches in the register-load stage");
        // The issue-window youngest-owner map already permits ordered WAW
        // writers.  The banked register file serializes conflicting write
        // address phases and retirement preserves program order, so only the
        // broader raw/read-hazard relaxation remains unsupported here.
        if ((BANKED_GPR != 0) && (RELAX_HAZARDS != 0))
            $fatal(1, "banked 3P requires conservative RAW/read hazards");
        if ((BANKED_GPR != 0) &&
            ((BRANCH_COMPLETION_FORWARD_MASK != 3'b000) ||
             (ENABLE_FULL_FORWARDING != 0)))
            $fatal(1,
                   "banked 3P supports live EX0/EX1 plus registered load-only MEM0 forwarding, not branch/full forwarding");
        if ((BANKED_GPR != 0) &&
            (RENAME_MODE == `OPENRV64_RENAME_IDENTITY) &&
            ((PHYS_REG_COUNT != 31) || (PHYS_REG_ADDR_WIDTH != 5)))
            $fatal(1, "identity banked 3P requires p0-p31 tags");
        if ((BANKED_GPR != 0) &&
            (RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
            ((PHYS_REG_COUNT != 63) || (PHYS_REG_ADDR_WIDTH != 6)))
            $fatal(1, "renamed banked 3P requires p0-p63 tags");
        if ((RENAME_MODE != `OPENRV64_RENAME_IDENTITY) &&
            (RENAME_MODE != `OPENRV64_RENAME_TOMASULO))
            $fatal(1, "unsupported integer rename mode");
    end

    always @(posedge clk) begin
        if (rst_n && (BANKED_GPR != 0) && banked_window_regload &&
`ifdef OPENRV64_BANKED_GPR_MAGIC_READS
            (gpr_read_ack != gpr_read_valid))
`else
            ((banked_independent_response_owner_valid_q |
              banked_independent_response_poison_q) != gpr_read_valid))
`endif
            $fatal(1,
                   "banked 3P GPR read response did not match the requester ack pipeline");
        if (rst_n && (BANKED_GPR != 0) && !banked_window_regload &&
`ifdef OPENRV64_BANKED_GPR_MAGIC_READS
            (gpr_read_ack[3:0] != gpr_read_valid[3:0]))
`else
            (banked_read_ack_q != gpr_read_valid[3:0]))
`endif
            $fatal(1,
                   "banked 3P legacy GPR response did not match the requester ack pipeline");
        if (rst_n && (BANKED_GPR != 0) && !banked_window_regload &&
            banked_gpr_drain_q &&
            (gpr_read_req[3:0] != banked_read_pending_q))
            $fatal(1,
                   "banked 3P GPR redirect drain started or dropped a read request");
        if (rst_n && !flush_i && free_branch_resolved &&
            exec_branch_resolved)
            $fatal(1, "free and EX1 branch resolutions collided");
        if (rst_n && (BANKED_GPR != 0) &&
            banked_regload_branch_pair_q &&
            banked_regload_lane1_fire &&
            !(banked_regload_branch_resolved_q ?
                  banked_regload_branch_correct_q :
                  (banked_regload_branch_correct_now &&
                   banked_regload_lane0_fire)))
            $fatal(1,
                   "banked 3P issued a deferred branch follower before proving the prediction");
    end
`endif

endmodule
