`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-a.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/exec/fpu/defs.v"

// Four-pipe integer-plus-F/D issue window.
//
// Unlike dispatch_3p, retirement identity is allocated when decode admits an
// instruction.  The assigned retirement slot is also the physical window
// index.  Entries remain resident through issue and are released only at
// retirement, which keeps program age, completion identity, and issue state
// in one bounded structure without adding a second reorder map.
//
// Decode writes registered static metadata; no newly admitted instruction can
// issue until the following cycle.  Sources retain only compact producer-slot
// dependencies.  Operand values are read from the producer result bank or the
// architectural GPR after a ready entry is selected.  Up to one instruction
// per physical pipe is then issued.  Memory issue remains program ordered and
// is currently
// limited to one operation per cycle; paired issue requires a registered
// acceptance boundary rather than a combinational cross-lane contract.  The optional
// speculation mode lets replayable work pass an older conditional branch that
// is still waiting for operands, and lets ordinary loads begin translation
// past unresolved control.  The physically addressed LSQ admits the later
// cache access only when translation classifies the result as cacheable RAM;
// device/non-RAM loads wait for ordered retirement.  Stores and atomics remain
// protected.  Legal aligned direct JALs are deterministic controls, so they do
// not form an issue barrier even before reaching the retirement head.
// Conditional branches themselves resolve in program order so a younger
// wrong-path branch cannot redirect or train before an older branch resolves.
module openrv64_dispatch_window_4pf #(
    parameter integer ENABLE = 1,
    parameter integer ENABLE_SPECULATION = 0,
    parameter integer ENABLE_TRACE = 0,
    parameter integer REGISTER_ISSUE_SELECT = 0,
    parameter integer DEPTH = 16,
    parameter [`RV64_XLEN-1:0] CACHEABLE_BASE =
        {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] CACHEABLE_SIZE =
        {`RV64_XLEN{1'b0}},
    parameter integer RETIRE_SLOT_WIDTH = $clog2(DEPTH),
    parameter integer COUNT_WIDTH = $clog2(DEPTH + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_frontend_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] squash_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] squash_slot_i,
    input  wire                         translation_bypass_i,

    input  wire [2:0]                   decode_valid_i,
    output wire [2:0]                   decode_ready_o,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        decode_payload_i,
    input  wire [2:0]                   decode_uses_rs1_i,
    input  wire [2:0]                   decode_uses_rs2_i,
    input  wire [2:0]                   decode_extension_valid_i,
    input  wire [3*`OPENRV64_FPU_DECODE_PAYLOAD_WIDTH-1:0]
                                        decode_extension_payload_i,

    output reg  [6*`RV64_REG_ADDR_WIDTH-1:0] gpr_read_addr_o,
    input  wire [6*`RV64_XLEN-1:0]      gpr_read_data_i,

    input  wire                         allocation_ready_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] allocation_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] allocation_slot_i,
    output wire [2:0]                   allocation_valid_o,
    output wire [3*`OPENRV64_DISPATCH_META_WIDTH-1:0] allocation_meta_o,
    output wire [2:0]                   allocation_extension_valid_o,
    output wire [3*`OPENRV64_FPU_DECODE_PAYLOAD_WIDTH-1:0]
                                        allocation_extension_payload_o,
    output wire [3*`OPENRV64_EXTENSION_BRANCH_COUNT-1:0]
                                        allocation_branch_mask_o,

    // Scheduling seam to the F/D sidecar.  The scalar window owns age,
    // integer dependencies, memory order and physical retirement slots; the
    // sidecar owns FPR dependencies and selects the fourth (FPU) pipe.
    input  wire [DEPTH-1:0]             extension_entry_valid_i,
    input  wire [DEPTH-1:0]             extension_entry_compute_i,
    input  wire [DEPTH-1:0]             extension_entry_load_i,
    input  wire [DEPTH-1:0]             extension_entry_store_i,
    input  wire [DEPTH-1:0]             extension_operand_ready_i,
    input  wire [DEPTH*`RV64_XLEN-1:0]  extension_entry_store_data_i,
    input  wire                         extension_load_issue_ready_i,
    output reg  [DEPTH-1:0]             extension_window_eligible_o,
    output reg  [DEPTH-1:0]             extension_window_issued_o,
    input  wire                         extension_scalar_read_valid_i,
    input  wire [`RV64_REG_ADDR_WIDTH-1:0]
                                        extension_scalar_read_addr_i,
    output reg                          extension_scalar_read_ready_o,
    output reg  [`RV64_XLEN-1:0]        extension_scalar_read_data_o,
    input  wire                         extension_issue_fire_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] extension_issue_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] extension_issue_slot_i,

    output reg                          extension_mem_issue_valid_o,
    output reg                          extension_mem_issue_fire_o,
    output reg                          extension_mem_issue_is_load_o,
    output reg  [`OPENRV64_INSTR_ID_WIDTH-1:0]
                                        extension_mem_issue_id_o,
    output reg  [RETIRE_SLOT_WIDTH-1:0] extension_mem_issue_slot_o,

    input  wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_ready_i,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_valid_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0] pipe_id_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH-1:0]
                                        pipe_slot_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        pipe_payload_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        pipe_src1_producer_valid_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*
                 RETIRE_SLOT_WIDTH-1:0]
                                        pipe_src1_producer_slot_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        pipe_src2_producer_valid_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*
                 RETIRE_SLOT_WIDTH-1:0]
                                        pipe_src2_producer_slot_o,

    input  wire [2:0]                   completion_valid_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] completion_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] completion_slot_i,
    input  wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                                        completion_payload_i,

    input  wire [2:0]                   retire_valid_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] retire_slot_i,
    input  wire [2:0]                   retire_hard_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0] next_retire_slot_i,

    output reg                          barrier_active_o,
    output reg  [2:0]                   raw_hazard_o,
    output wire [2:0]                   waw_hazard_o,
    output wire [2:0]                   read_port_hazard_o,
    output wire [31:0]                  write_busy_o,
    output wire [COUNT_WIDTH-1:0]       queue_count_o
);

    localparam integer PAYLOAD_RS1_ADDR = 237;
    localparam integer PAYLOAD_RS2_ADDR = 232;
    localparam integer PAYLOAD_RS1_DATA = 168;
    localparam integer PAYLOAD_RS2_DATA = 104;
    localparam integer PAYLOAD_INSTR = 242;
    localparam integer PAYLOAD_IMM = 40;
    localparam integer PAYLOAD_RD = 35;
    localparam integer PAYLOAD_ALU_EXT = 32;
    localparam integer PAYLOAD_REG_WRITE = 17;
    localparam integer PAYLOAD_BR_OP = 18;
    localparam integer PAYLOAD_MEM_READ = 16;
    localparam integer PAYLOAD_MEM_WRITE = 15;
    localparam integer PAYLOAD_BRANCH = 14;
    localparam integer PAYLOAD_JUMP = 13;
    localparam integer PAYLOAD_SYSTEM = 10;
    localparam integer PAYLOAD_FENCE = 9;
    localparam integer PAYLOAD_ILLEGAL = 8;
    localparam integer PAYLOAD_EBREAK = 7;
    localparam integer PAYLOAD_ECALL = 6;
    localparam integer PAYLOAD_INSTR_FAULT = 5;
    localparam integer PAYLOAD_INSTR_PAGE_FAULT = 4;

    // The resident window does not need operand values or the optional trace
    // identity.  Keep the static issue fields above the operand pair and below
    // it as one compact record, then reconstruct the legacy execution packet
    // only after a slot has been selected.
    localparam integer PAYLOAD_TRACE = 338;
    localparam integer PAYLOAD_STATIC_UPPER_LSB = 232;
    localparam integer PAYLOAD_STATIC_UPPER_WIDTH = 106;
    localparam integer PAYLOAD_STATIC_LOWER_WIDTH = 104;
    localparam integer WINDOW_PAYLOAD_WIDTH =
        PAYLOAD_STATIC_UPPER_WIDTH + PAYLOAD_STATIC_LOWER_WIDTH;
    localparam integer WINDOW_RS2_ADDR = 104;
    localparam integer WINDOW_RS1_ADDR = 109;
    localparam integer WINDOW_INSTR = 114;
    localparam integer WINDOW_PC = 146;

    function automatic [WINDOW_PAYLOAD_WIDTH-1:0] compact_payload;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            compact_payload = {
                payload[PAYLOAD_STATIC_UPPER_LSB +:
                        PAYLOAD_STATIC_UPPER_WIDTH],
                payload[0 +: PAYLOAD_STATIC_LOWER_WIDTH]
            };
        end
    endfunction

    function automatic [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        expand_payload;
        input [WINDOW_PAYLOAD_WIDTH-1:0] payload;
        input [`RV64_XLEN-1:0] trace_id;
        input [`RV64_XLEN-1:0] src1_data;
        input [`RV64_XLEN-1:0] src2_data;
        reg [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] expanded;
        begin
            expanded = {`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
            expanded[PAYLOAD_TRACE +: `RV64_XLEN] =
                (ENABLE_TRACE != 0) ? trace_id : {`RV64_XLEN{1'b0}};
            expanded[PAYLOAD_STATIC_UPPER_LSB +:
                     PAYLOAD_STATIC_UPPER_WIDTH] =
                payload[PAYLOAD_STATIC_LOWER_WIDTH +:
                        PAYLOAD_STATIC_UPPER_WIDTH];
            expanded[PAYLOAD_RS1_DATA +: `RV64_XLEN] = src1_data;
            expanded[PAYLOAD_RS2_DATA +: `RV64_XLEN] = src2_data;
            expanded[0 +: PAYLOAD_STATIC_LOWER_WIDTH] =
                payload[0 +: PAYLOAD_STATIC_LOWER_WIDTH];
            expand_payload = expanded;
        end
    endfunction

    reg                                 valid_q [0:DEPTH-1];
    reg                                 issued_q [0:DEPTH-1];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] id_q [0:DEPTH-1];
    reg [WINDOW_PAYLOAD_WIDTH-1:0]
                                        payload_q [0:DEPTH-1];
    reg [`RV64_XLEN-1:0]                trace_id_q [0:DEPTH-1];
    reg                                 extension_valid_q [0:DEPTH-1];
    reg                                 uses_rs1_q [0:DEPTH-1];
    reg                                 uses_rs2_q [0:DEPTH-1];
    reg                                 src1_ready_q [0:DEPTH-1];
    reg                                 src2_ready_q [0:DEPTH-1];
    reg                                 src1_producer_valid_q [0:DEPTH-1];
    reg                                 src2_producer_valid_q [0:DEPTH-1];
    reg [RETIRE_SLOT_WIDTH-1:0] src1_dependency_slot_q [0:DEPTH-1];
    reg [RETIRE_SLOT_WIDTH-1:0] src2_dependency_slot_q [0:DEPTH-1];
    reg                                 result_ready_q [0:DEPTH-1];
    reg [`RV64_XLEN-1:0]                result_data_q [0:DEPTH-1];
    reg [COUNT_WIDTH-1:0]               count_q;

    // Youngest architectural producer at decode admission.  The owner map is
    // tag-only: completed values remain once in result_data_q at their producer
    // slot instead of being duplicated per architectural destination.
    reg [31:0]                          owner_valid_q;
    reg [31:0]                          owner_ready_q;
    reg [RETIRE_SLOT_WIDTH-1:0]         owner_slot_q [0:31];

    function automatic is_hard;
        input [WINDOW_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_hard = payload[PAYLOAD_BRANCH] ||
                      payload[PAYLOAD_JUMP] ||
                      payload[PAYLOAD_SYSTEM] ||
                      payload[PAYLOAD_FENCE] ||
                      payload[PAYLOAD_ILLEGAL] ||
                      payload[PAYLOAD_EBREAK] ||
                      payload[PAYLOAD_ECALL] ||
                      payload[PAYLOAD_INSTR_FAULT] ||
                      payload[PAYLOAD_INSTR_PAGE_FAULT];
        end
    endfunction

    function automatic is_replayable_direct_jal;
        input [WINDOW_PAYLOAD_WIDTH-1:0] payload;
        begin
            // PC is 32-bit aligned and JAL's immediate is PC-relative, so
            // imm[1]==0 proves the target cannot raise an alignment exception.
            // Its target is known at decode and its link write remains in the
            // retirement queue, making younger side-effect-free work safe.
            is_replayable_direct_jal = payload[PAYLOAD_JUMP] &&
                (payload[PAYLOAD_BR_OP +: `RV64_BR_OP_WIDTH] ==
                 `RV64_BR_OP_JAL) &&
                !payload[PAYLOAD_ILLEGAL] &&
                !payload[PAYLOAD_INSTR_FAULT] &&
                !payload[PAYLOAD_INSTR_PAGE_FAULT] &&
                !payload[PAYLOAD_IMM + 1];
        end
    endfunction

    function automatic is_early_conditional_branch;
        input [WINDOW_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_early_conditional_branch = payload[PAYLOAD_BRANCH] &&
                !payload[PAYLOAD_ILLEGAL] &&
                !payload[PAYLOAD_INSTR_FAULT] &&
                !payload[PAYLOAD_INSTR_PAGE_FAULT] &&
                !payload[PAYLOAD_IMM + 1];
        end
    endfunction

    function automatic may_speculate_past_unissued_control;
        input [WINDOW_PAYLOAD_WIDTH-1:0] payload;
        begin
            // Direct JAL is deterministic.  Conditional branches require the
            // selective recovery machinery because their compare operands may
            // arrive after younger replayable instructions have executed.
            may_speculate_past_unissued_control =
                is_replayable_direct_jal(payload) ||
                ((ENABLE_SPECULATION != 0) &&
                 is_early_conditional_branch(payload));
        end
    endfunction

    function automatic is_persistent_hard;
        input [WINDOW_PAYLOAD_WIDTH-1:0] payload;
        begin
            // Aligned decoded conditional branches and deterministic direct
            // JALs may execute before the retirement head.  The optional
            // speculation window handles conditional redirect recovery; JAL
            // has no direction or target uncertainty once decoded.
            is_persistent_hard = is_hard(payload) &&
                !is_early_conditional_branch(payload) &&
                !is_replayable_direct_jal(payload);
        end
    endfunction

    function automatic is_mem;
        input [WINDOW_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_mem = payload[PAYLOAD_MEM_READ] ||
                     payload[PAYLOAD_MEM_WRITE];
        end
    endfunction

    function automatic is_mem1_op;
        input [WINDOW_PAYLOAD_WIDTH-1:0] payload;
        reg [`RV64_INSTR_WIDTH-1:0] payload_instr;
        begin
            payload_instr = payload[WINDOW_INSTR +: `RV64_INSTR_WIDTH];
            is_mem1_op = payload[PAYLOAD_MEM_WRITE] ||
                (`RV64_OPCODE(payload_instr) == `RV64_OPCODE_AMO);
        end
    endfunction

    function automatic is_speculative_load_candidate;
        input [WINDOW_PAYLOAD_WIDTH-1:0] payload;
        input [`RV64_XLEN-1:0] issue_rs1_data;
        input issue_rs1_data_valid;
        reg [`RV64_XLEN-1:0] effective_addr;
        begin
            effective_addr = issue_rs1_data +
                             payload[PAYLOAD_IMM +: `RV64_XLEN];
            // A virtual address cannot establish PMA/cacheability. Permit an
            // ordinary load to reach translation; the LSQ waits for the
            // translated physical address and suppresses device/non-RAM
            // access until the instruction is the ordered retirement head. In
            // Bare/M-mode the effective address is already physical, so keep
            // non-RAM loads behind the unresolved control at dispatch too.
            // AMOs assert MEM_WRITE as well as MEM_READ and remain excluded.
            is_speculative_load_candidate =
                (ENABLE_SPECULATION != 0) &&
                payload[PAYLOAD_MEM_READ] &&
                !payload[PAYLOAD_MEM_WRITE] &&
                (!translation_bypass_i ||
                 (issue_rs1_data_valid && (CACHEABLE_SIZE != 0) &&
                  ((effective_addr - CACHEABLE_BASE) < CACHEABLE_SIZE)));
        end
    endfunction

    function automatic is_fixed_ex0;
        input [WINDOW_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_fixed_ex0 = !is_hard(payload) && !is_mem(payload) &&
                (payload[PAYLOAD_ALU_EXT +: `RV64_ALU_EXT_WIDTH] ==
                 `RV64_ALU_EXT_M);
        end
    endfunction

    function automatic is_fixed_ex1;
        input [WINDOW_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_fixed_ex1 = is_hard(payload);
        end
    endfunction

    function automatic is_flexible_alu;
        input [WINDOW_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_flexible_alu = !is_hard(payload) && !is_mem(payload) &&
                (payload[PAYLOAD_ALU_EXT +: `RV64_ALU_EXT_WIDTH] ==
                 `RV64_ALU_EXT_BASE);
        end
    endfunction

    function automatic completion_safe;
        input [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] payload;
        begin
            completion_safe = payload[`OPENRV64_COMPLETE_REG_WRITE_BIT] &&
                !payload[`OPENRV64_COMPLETE_ILLEGAL_BIT] &&
                !payload[`OPENRV64_COMPLETE_EXCEPTION_BIT];
        end
    endfunction

    // Completions carry both their physical retirement slot and their global
    // instruction ID.  The slot directly addresses the producer; the single
    // ID comparison at that slot rejects late responses after squash/reuse.
    reg [2:0] completion_current;
    integer completion_current_port;
    integer completion_current_slot;
    always_comb begin
        completion_current = 3'b000;
        for (completion_current_port = 0; completion_current_port < 3;
             completion_current_port = completion_current_port + 1) begin
            completion_current_slot = completion_slot_i[
                completion_current_port*RETIRE_SLOT_WIDTH +:
                RETIRE_SLOT_WIDTH];
            completion_current[completion_current_port] =
                completion_valid_i[completion_current_port] &&
                valid_q[completion_current_slot] &&
                (id_q[completion_current_slot] == completion_id_i[
                    completion_current_port*`OPENRV64_INSTR_ID_WIDTH +:
                    `OPENRV64_INSTR_ID_WIDTH]);
        end
    end

    wire [COUNT_WIDTH:0] free_count = DEPTH - count_q;
    assign decode_ready_o[0] = !flush_i && !squash_frontend_i &&
                               allocation_ready_i && (free_count >= 1);
    assign decode_ready_o[1] = decode_ready_o[0] && (free_count >= 2);
    assign decode_ready_o[2] = decode_ready_o[1] && (free_count >= 3);
    wire decode_fire0 = decode_valid_i[0] && decode_ready_o[0];
    wire decode_fire1 = decode_valid_i[1] && decode_ready_o[1] && decode_fire0;
    wire decode_fire2 = decode_valid_i[2] && decode_ready_o[2] && decode_fire1;
    wire [2:0] decode_fire = {decode_fire2, decode_fire1, decode_fire0};
    wire [1:0] decode_count = {1'b0, decode_fire0} +
                              {1'b0, decode_fire1} +
                              {1'b0, decode_fire2};
    assign allocation_valid_o = decode_fire;
    assign allocation_extension_valid_o =
        decode_fire & decode_extension_valid_i;
    assign allocation_extension_payload_o = decode_extension_payload_i;

    // Four speculative-control tag bits accompany extension work.  Exact
    // instruction ID remains authoritative for recovery, so modulo-four tag
    // reuse cannot corrupt state; the mask is an early kill hint only.
    reg [3*`OPENRV64_EXTENSION_BRANCH_COUNT-1:0]
        allocation_branch_mask_r;
    reg [`OPENRV64_EXTENSION_BRANCH_COUNT-1:0] branch_mask_view;
    integer branch_scan_slot;
    integer branch_lane;
    integer branch_token;
    always_comb begin
        branch_token = 0;
        branch_mask_view = {`OPENRV64_EXTENSION_BRANCH_COUNT{1'b0}};
        for (branch_scan_slot = 0; branch_scan_slot < DEPTH;
             branch_scan_slot = branch_scan_slot + 1) begin
            if (valid_q[branch_scan_slot] &&
                (payload_q[branch_scan_slot][PAYLOAD_BRANCH] ||
                 payload_q[branch_scan_slot][PAYLOAD_JUMP])) begin
                branch_token = branch_scan_slot %
                    `OPENRV64_EXTENSION_BRANCH_COUNT;
                branch_mask_view[branch_token] = 1'b1;
            end
        end
        allocation_branch_mask_r =
            {3*`OPENRV64_EXTENSION_BRANCH_COUNT{1'b0}};
        for (branch_lane = 0; branch_lane < 3;
             branch_lane = branch_lane + 1) begin
            allocation_branch_mask_r[
                branch_lane*`OPENRV64_EXTENSION_BRANCH_COUNT +:
                `OPENRV64_EXTENSION_BRANCH_COUNT] = branch_mask_view;
            if (decode_fire[branch_lane] &&
                (decode_payload_i[
                    branch_lane*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                    PAYLOAD_BRANCH] ||
                 decode_payload_i[
                    branch_lane*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                    PAYLOAD_JUMP])) begin
                branch_token = allocation_slot_i[
                    branch_lane*RETIRE_SLOT_WIDTH +:
                    RETIRE_SLOT_WIDTH] %
                    `OPENRV64_EXTENSION_BRANCH_COUNT;
                branch_mask_view[branch_token] = 1'b1;
            end
        end
    end
    assign allocation_branch_mask_o = allocation_branch_mask_r;

    wire [1:0] retire_count = {1'b0, retire_valid_i[0]} +
                              {1'b0, retire_valid_i[1]} +
                              {1'b0, retire_valid_i[2]};

    reg [31:0] owner_valid_view;
    reg [31:0] owner_ready_view;
    reg [RETIRE_SLOT_WIDTH-1:0] owner_slot_view [0:31];
    reg [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        admit_payload [0:2];
    reg [RETIRE_SLOT_WIDTH-1:0] admit_src1_dependency_slot [0:2];
    reg [RETIRE_SLOT_WIDTH-1:0] admit_src2_dependency_slot [0:2];
    reg admit_src1_producer_valid [0:2];
    reg admit_src2_producer_valid [0:2];
    reg admit_src1_ready [0:2];
    reg admit_src2_ready [0:2];
    integer owner_view_idx;
    integer view_lane;
    integer view_port;
    reg [`RV64_REG_ADDR_WIDTH-1:0] view_rs1;
    reg [`RV64_REG_ADDR_WIDTH-1:0] view_rs2;
    reg [`RV64_REG_ADDR_WIDTH-1:0] view_rd;
    reg [RETIRE_SLOT_WIDTH-1:0] view_slot;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] view_completion;

    always_comb begin
        owner_valid_view = owner_valid_q;
        owner_ready_view = owner_ready_q;
        for (owner_view_idx = 0; owner_view_idx < 32;
             owner_view_idx = owner_view_idx + 1) begin
            owner_slot_view[owner_view_idx] = owner_slot_q[owner_view_idx];
        end

        // Completion precedes retirement in the architectural age order.
        for (view_port = 0; view_port < 3; view_port = view_port + 1) begin
            view_slot = completion_slot_i[
                view_port*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH];
            view_completion = completion_payload_i[
                view_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
            view_rd = view_completion[
                `OPENRV64_COMPLETE_RD_LSB +: `RV64_REG_ADDR_WIDTH];
            if (completion_current[view_port] &&
                completion_safe(view_completion) &&
                (view_rd != `RV64_REG_X0) && owner_valid_view[view_rd] &&
                (owner_slot_view[view_rd] == view_slot)) begin
                owner_ready_view[view_rd] = 1'b1;
            end
        end

        for (view_lane = 0; view_lane < 3; view_lane = view_lane + 1) begin
            view_slot = retire_slot_i[
                view_lane*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH];
            for (owner_view_idx = 1; owner_view_idx < 32;
                 owner_view_idx = owner_view_idx + 1) begin
                if (retire_valid_i[view_lane] &&
                    owner_valid_view[owner_view_idx] &&
                    (owner_slot_view[owner_view_idx] == view_slot)) begin
                    owner_valid_view[owner_view_idx] = 1'b0;
                    owner_ready_view[owner_view_idx] = 1'b0;
                end
            end
        end

        for (view_lane = 0; view_lane < 3; view_lane = view_lane + 1) begin
            admit_payload[view_lane] = decode_payload_i[
                view_lane*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
            view_rs1 = admit_payload[view_lane][
                PAYLOAD_RS1_ADDR +: `RV64_REG_ADDR_WIDTH];
            view_rs2 = admit_payload[view_lane][
                PAYLOAD_RS2_ADDR +: `RV64_REG_ADDR_WIDTH];
            view_rd = admit_payload[view_lane][
                PAYLOAD_RD +: `RV64_REG_ADDR_WIDTH];

            admit_src1_dependency_slot[view_lane] =
                {RETIRE_SLOT_WIDTH{1'b0}};
            admit_src2_dependency_slot[view_lane] =
                {RETIRE_SLOT_WIDTH{1'b0}};
            admit_src1_producer_valid[view_lane] = 1'b0;
            admit_src2_producer_valid[view_lane] = 1'b0;
            admit_src1_ready[view_lane] = 1'b1;
            admit_src2_ready[view_lane] = 1'b1;

            if (decode_uses_rs1_i[view_lane] &&
                (view_rs1 != `RV64_REG_X0)) begin
                if (owner_valid_view[view_rs1]) begin
                    admit_src1_producer_valid[view_lane] = 1'b1;
                    admit_src1_dependency_slot[view_lane] =
                        owner_slot_view[view_rs1];
                    admit_src1_ready[view_lane] = owner_ready_view[view_rs1];
                end
            end
            if (decode_uses_rs2_i[view_lane] &&
                (view_rs2 != `RV64_REG_X0)) begin
                if (owner_valid_view[view_rs2]) begin
                    admit_src2_producer_valid[view_lane] = 1'b1;
                    admit_src2_dependency_slot[view_lane] =
                        owner_slot_view[view_rs2];
                    admit_src2_ready[view_lane] = owner_ready_view[view_rs2];
                end
            end

            // Allocation is program ordered, so later lanes observe writers
            // allocated by earlier lanes in this same decode bundle.
            if (decode_fire[view_lane] &&
                admit_payload[view_lane][PAYLOAD_REG_WRITE] &&
                (view_rd != `RV64_REG_X0)) begin
                owner_valid_view[view_rd] = 1'b1;
                owner_ready_view[view_rd] = 1'b0;
                owner_slot_view[view_rd] = allocation_slot_i[
                    view_lane*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH];
            end
        end
        owner_valid_view[`RV64_REG_X0] = 1'b0;
        owner_ready_view[`RV64_REG_X0] = 1'b0;
    end

    genvar read_lane;
    generate
        for (read_lane = 0; read_lane < 3; read_lane = read_lane + 1) begin : g_meta
            assign allocation_meta_o[
                read_lane*`OPENRV64_DISPATCH_META_WIDTH +:
                `OPENRV64_DISPATCH_META_WIDTH] = {
                is_hard(compact_payload(admit_payload[read_lane])),
                decode_uses_rs2_i[read_lane],
                decode_uses_rs1_i[read_lane],
                admit_payload[read_lane]
            };
        end
    endgenerate

    reg src1_ready_now [0:DEPTH-1];
    reg src2_ready_now [0:DEPTH-1];
    reg [`RV64_XLEN-1:0] src1_data_now [0:DEPTH-1];
    reg [`RV64_XLEN-1:0] src2_data_now [0:DEPTH-1];
    reg src1_value_valid_now [0:DEPTH-1];
    reg src2_value_valid_now [0:DEPTH-1];
    integer ready_idx;

    // Optional issue-selection boundary.  A selected integer/LSU slot is held
    // here until its execution pipe accepts it.  The F/D sidecar retains its
    // own direct selector.  The resident entry remains unissued, so barriers
    // and memory ordering retain their normal meaning; the held slot is
    // excluded explicitly from reselection below.  Consequently, consecutive
    // memory selections retain a bubble while the held operation becomes
    // issued.  This mode is an area/timing probe rather than the default.
    reg issue_select_ex0_valid_q;
    reg issue_select_ex1_valid_q;
    reg issue_select_mem_valid_q;
    reg [RETIRE_SLOT_WIDTH-1:0] issue_select_ex0_q;
    reg [RETIRE_SLOT_WIDTH-1:0] issue_select_ex1_q;
    reg [RETIRE_SLOT_WIDTH-1:0] issue_select_mem_q;

    // Completion wakeup is deliberately registered below.  Feeding a
    // combinational completion directly into eligibility creates a physical
    // issue -> execute -> complete -> wakeup -> issue loop.  A dependent may
    // therefore issue on the cycle after its producer completes, using the
    // producer slot's single result_data_q entry.
    always_comb begin
        for (ready_idx = 0; ready_idx < DEPTH; ready_idx = ready_idx + 1) begin
            src1_ready_now[ready_idx] = src1_ready_q[ready_idx];
            src2_ready_now[ready_idx] = src2_ready_q[ready_idx];
            src1_data_now[ready_idx] = src1_producer_valid_q[ready_idx] ?
                result_data_q[src1_dependency_slot_q[ready_idx]] :
                {`RV64_XLEN{1'b0}};
            src2_data_now[ready_idx] = src2_producer_valid_q[ready_idx] ?
                result_data_q[src2_dependency_slot_q[ready_idx]] :
                {`RV64_XLEN{1'b0}};
            src1_value_valid_now[ready_idx] =
                !uses_rs1_q[ready_idx] ||
                (payload_q[ready_idx][WINDOW_RS1_ADDR +:
                                         `RV64_REG_ADDR_WIDTH] ==
                 `RV64_REG_X0) ||
                (src1_producer_valid_q[ready_idx] &&
                 src1_ready_now[ready_idx]);
            src2_value_valid_now[ready_idx] =
                !uses_rs2_q[ready_idx] ||
                (payload_q[ready_idx][WINDOW_RS2_ADDR +:
                                         `RV64_REG_ADDR_WIDTH] ==
                 `RV64_REG_X0) ||
                (src2_producer_valid_q[ready_idx] &&
                 src2_ready_now[ready_idx]);
        end
    end

    reg eligible [0:DEPTH-1];
    reg mem_pair_eligible [0:DEPTH-1];
    // Simulation-visible aggregate state.  These are deliberately kept as
    // named internal signals instead of architectural ports; the cycle trace
    // uses them to distinguish an empty window from RAW, ordering, and
    // capability pressure when the selectable window path is active.
    reg [COUNT_WIDTH-1:0] trace_unissued_count;
    reg [COUNT_WIDTH-1:0] trace_operand_ready_count;
    reg [COUNT_WIDTH-1:0] trace_eligible_count;
    reg [COUNT_WIDTH-1:0] trace_raw_block_count;
    reg [COUNT_WIDTH-1:0] trace_hard_block_count;
    reg [COUNT_WIDTH-1:0] trace_mem_order_block_count;
    integer eligible_idx;
    integer age_offset;
    integer age_slot;
    reg older_unissued_hard;
    reg older_persistent_hard;
    reg older_unissued_mem;
    reg older_live_control;
    reg older_unresolved_conditional;
    reg issue_slot_reserved;

    always_comb begin
        barrier_active_o = 1'b0;
        raw_hazard_o = 3'b000;
        extension_window_eligible_o = {DEPTH{1'b0}};
        extension_window_issued_o = {DEPTH{1'b0}};
        trace_unissued_count = {COUNT_WIDTH{1'b0}};
        trace_operand_ready_count = {COUNT_WIDTH{1'b0}};
        trace_eligible_count = {COUNT_WIDTH{1'b0}};
        trace_raw_block_count = {COUNT_WIDTH{1'b0}};
        trace_hard_block_count = {COUNT_WIDTH{1'b0}};
        trace_mem_order_block_count = {COUNT_WIDTH{1'b0}};

        // Initialize the physical-slot views once.  Scheduling decisions below
        // walk from the retirement head, so the accumulated blocker state is
        // exactly the state of older live instructions.
        for (eligible_idx = 0; eligible_idx < DEPTH;
             eligible_idx = eligible_idx + 1) begin
            eligible[eligible_idx] = 1'b0;
            mem_pair_eligible[eligible_idx] = 1'b0;
            extension_window_issued_o[eligible_idx] = issued_q[eligible_idx];
        end

        older_unissued_hard = 1'b0;
        older_persistent_hard = 1'b0;
        older_unissued_mem = 1'b0;
        older_live_control = 1'b0;
        older_unresolved_conditional = 1'b0;

        // Entries occupy retirement slots until commit.  Circular slot order
        // from next_retire_slot_i therefore is program age; no pairwise global
        // instruction-ID subtraction is required.
        for (age_offset = 0; age_offset < DEPTH;
             age_offset = age_offset + 1) begin
            age_slot = next_retire_slot_i + age_offset;
            if (age_slot >= DEPTH)
                age_slot = age_slot - DEPTH;

            if (valid_q[age_slot] &&
                is_persistent_hard(payload_q[age_slot]))
                barrier_active_o = 1'b1;

            issue_slot_reserved = (REGISTER_ISSUE_SELECT != 0) &&
                ((issue_select_ex0_valid_q &&
                  (issue_select_ex0_q == age_slot)) ||
                 (issue_select_ex1_valid_q &&
                  (issue_select_ex1_q == age_slot)) ||
                 (issue_select_mem_valid_q &&
                  (issue_select_mem_q == age_slot)));
            eligible[age_slot] = valid_q[age_slot] &&
                !issued_q[age_slot] && !issue_slot_reserved &&
                src1_ready_now[age_slot] &&
                src2_ready_now[age_slot] && !older_unissued_hard &&
                !older_persistent_hard;
            if (extension_valid_q[age_slot])
                eligible[age_slot] = eligible[age_slot] &&
                    extension_entry_valid_i[age_slot] &&
                    extension_operand_ready_i[age_slot];
            if (is_persistent_hard(payload_q[age_slot]) &&
                (age_slot != next_retire_slot_i))
                eligible[age_slot] = 1'b0;
            // Data work may cross several predicted branches, but conditional
            // branches themselves resolve in program order.  This prevents a
            // younger wrong-path branch from redirecting or training the
            // predictor before an older unresolved branch is known correct.
            if ((ENABLE_SPECULATION != 0) &&
                is_early_conditional_branch(payload_q[age_slot]) &&
                older_unresolved_conditional)
                eligible[age_slot] = 1'b0;
            // Preserve all non-memory ordering and control checks separately
            // from the older-memory check.  The selector may use this view
            // only for the memory operation immediately following the oldest
            // selected memory operation in the same coupled issue bundle.
            mem_pair_eligible[age_slot] =
                eligible[age_slot] && is_mem(payload_q[age_slot]);
            if (is_mem(payload_q[age_slot]) &&
                older_live_control &&
                !is_speculative_load_candidate(
                    payload_q[age_slot], src1_data_now[age_slot],
                    src1_value_valid_now[age_slot])) begin
                eligible[age_slot] = 1'b0;
                mem_pair_eligible[age_slot] = 1'b0;
            end
            if (is_mem(payload_q[age_slot]) && older_unissued_mem)
                eligible[age_slot] = 1'b0;

            extension_window_eligible_o[age_slot] = eligible[age_slot];

            if (valid_q[age_slot] && !issued_q[age_slot] &&
                (!src1_ready_now[age_slot] || !src2_ready_now[age_slot]))
                raw_hazard_o[0] = 1'b1;

            if (valid_q[age_slot] && !issued_q[age_slot]) begin
                trace_unissued_count = trace_unissued_count + 1'b1;
                if (src1_ready_now[age_slot] && src2_ready_now[age_slot])
                    trace_operand_ready_count =
                        trace_operand_ready_count + 1'b1;
                else
                    trace_raw_block_count = trace_raw_block_count + 1'b1;
                if (eligible[age_slot])
                    trace_eligible_count = trace_eligible_count + 1'b1;
                else if (src1_ready_now[age_slot] &&
                         src2_ready_now[age_slot]) begin
                    if ((is_mem(payload_q[age_slot]) &&
                         (older_unissued_mem ||
                         (older_live_control &&
                           !is_speculative_load_candidate(
                               payload_q[age_slot],
                               src1_data_now[age_slot],
                               src1_value_valid_now[age_slot])))))
                        trace_mem_order_block_count =
                            trace_mem_order_block_count + 1'b1;
                    else if (older_unissued_hard || older_persistent_hard ||
                             ((ENABLE_SPECULATION != 0) &&
                              is_early_conditional_branch(
                                  payload_q[age_slot]) &&
                              older_unresolved_conditional) ||
                             (is_persistent_hard(payload_q[age_slot]) &&
                              (age_slot != next_retire_slot_i)))
                        trace_hard_block_count =
                            trace_hard_block_count + 1'b1;
                end
            end

            // Update prefix state only after evaluating the current slot, so
            // it affects younger slots and never the instruction itself.
            if (valid_q[age_slot]) begin
                if (!issued_q[age_slot] && is_hard(payload_q[age_slot]) &&
                    !may_speculate_past_unissued_control(
                        payload_q[age_slot]))
                    older_unissued_hard = 1'b1;
                if (is_persistent_hard(payload_q[age_slot]))
                    older_persistent_hard = 1'b1;
                if (!issued_q[age_slot] && is_mem(payload_q[age_slot]))
                    older_unissued_mem = 1'b1;
                if (!issued_q[age_slot] &&
                    is_early_conditional_branch(payload_q[age_slot]))
                    older_unresolved_conditional = 1'b1;
                if (payload_q[age_slot][PAYLOAD_BRANCH] ||
                    is_replayable_direct_jal(payload_q[age_slot]))
                    older_live_control = 1'b1;
            end
        end
    end

    reg select_ex0_valid;
    reg select_ex1_valid;
    reg select_mem_valid;
    reg select_mem2_valid;
    reg [RETIRE_SLOT_WIDTH-1:0] select_ex0;
    reg [RETIRE_SLOT_WIDTH-1:0] select_ex1;
    reg [RETIRE_SLOT_WIDTH-1:0] select_mem;
    reg [RETIRE_SLOT_WIDTH-1:0] select_mem2;
    wire issue_select_ex0_valid = (REGISTER_ISSUE_SELECT != 0) ?
        issue_select_ex0_valid_q : select_ex0_valid;
    wire issue_select_ex1_valid = (REGISTER_ISSUE_SELECT != 0) ?
        issue_select_ex1_valid_q : select_ex1_valid;
    wire issue_select_mem_valid = (REGISTER_ISSUE_SELECT != 0) ?
        issue_select_mem_valid_q : select_mem_valid;
    wire issue_select_mem2_valid = (REGISTER_ISSUE_SELECT != 0) ?
        1'b0 : select_mem2_valid;
    wire [RETIRE_SLOT_WIDTH-1:0] issue_select_ex0 =
        (REGISTER_ISSUE_SELECT != 0) ? issue_select_ex0_q : select_ex0;
    wire [RETIRE_SLOT_WIDTH-1:0] issue_select_ex1 =
        (REGISTER_ISSUE_SELECT != 0) ? issue_select_ex1_q : select_ex1;
    wire [RETIRE_SLOT_WIDTH-1:0] issue_select_mem =
        (REGISTER_ISSUE_SELECT != 0) ? issue_select_mem_q : select_mem;
    wire [RETIRE_SLOT_WIDTH-1:0] issue_select_mem2 = select_mem2;
    integer select_offset;
    integer select_slot;
    integer selected_idx;
    integer selected_mem_pipe;
    integer selected_mem2_pipe;
    reg past_selected_mem;
    reg checked_next_mem;
    reg [2:0] trace_pipe_uses_rs1;
    reg [2:0] trace_pipe_uses_rs2;

    // Resolve architectural operands only for selected instructions.  A source
    // with a live dependency reads the producer's single slot-indexed result;
    // an independent source consumes one of the existing six GPR read ports.
    // The F/D sidecar requests its rare scalar source after selecting an FPU
    // slot and receives a spare port or explicit backpressure.
    reg [`RV64_XLEN-1:0] select_ex0_src1_data;
    reg [`RV64_XLEN-1:0] select_ex0_src2_data;
    reg [`RV64_XLEN-1:0] select_ex1_src1_data;
    reg [`RV64_XLEN-1:0] select_ex1_src2_data;
    reg [`RV64_XLEN-1:0] select_mem_src1_data;
    reg [`RV64_XLEN-1:0] select_mem_src2_data;
    reg [5:0] gpr_read_port_used;
    reg extension_scalar_port_found;
    reg [2:0] extension_scalar_selected_port;
    integer extension_scalar_port;
    integer extension_scalar_slot;

    always_comb begin
        gpr_read_addr_o = {6*`RV64_REG_ADDR_WIDTH{1'b0}};
        gpr_read_port_used = 6'b000000;
        extension_scalar_port_found = 1'b0;
        extension_scalar_selected_port = 3'd0;
        extension_scalar_port = 0;
        extension_scalar_slot = extension_issue_slot_i;

        if (issue_select_ex0_valid) begin
            if (uses_rs1_q[issue_select_ex0] &&
                !src1_producer_valid_q[issue_select_ex0] &&
                (payload_q[issue_select_ex0][WINDOW_RS1_ADDR +:
                                          `RV64_REG_ADDR_WIDTH] !=
                 `RV64_REG_X0)) begin
                gpr_read_addr_o[0*`RV64_REG_ADDR_WIDTH +:
                                `RV64_REG_ADDR_WIDTH] =
                    payload_q[issue_select_ex0][WINDOW_RS1_ADDR +:
                                             `RV64_REG_ADDR_WIDTH];
                gpr_read_port_used[0] = 1'b1;
            end
            if (uses_rs2_q[issue_select_ex0] &&
                !src2_producer_valid_q[issue_select_ex0] &&
                (payload_q[issue_select_ex0][WINDOW_RS2_ADDR +:
                                          `RV64_REG_ADDR_WIDTH] !=
                 `RV64_REG_X0)) begin
                gpr_read_addr_o[1*`RV64_REG_ADDR_WIDTH +:
                                `RV64_REG_ADDR_WIDTH] =
                    payload_q[issue_select_ex0][WINDOW_RS2_ADDR +:
                                             `RV64_REG_ADDR_WIDTH];
                gpr_read_port_used[1] = 1'b1;
            end
        end

        if (issue_select_ex1_valid) begin
            if (uses_rs1_q[issue_select_ex1] &&
                !src1_producer_valid_q[issue_select_ex1] &&
                (payload_q[issue_select_ex1][WINDOW_RS1_ADDR +:
                                          `RV64_REG_ADDR_WIDTH] !=
                 `RV64_REG_X0)) begin
                gpr_read_addr_o[2*`RV64_REG_ADDR_WIDTH +:
                                `RV64_REG_ADDR_WIDTH] =
                    payload_q[issue_select_ex1][WINDOW_RS1_ADDR +:
                                             `RV64_REG_ADDR_WIDTH];
                gpr_read_port_used[2] = 1'b1;
            end
            if (uses_rs2_q[issue_select_ex1] &&
                !src2_producer_valid_q[issue_select_ex1] &&
                (payload_q[issue_select_ex1][WINDOW_RS2_ADDR +:
                                          `RV64_REG_ADDR_WIDTH] !=
                 `RV64_REG_X0)) begin
                gpr_read_addr_o[3*`RV64_REG_ADDR_WIDTH +:
                                `RV64_REG_ADDR_WIDTH] =
                    payload_q[issue_select_ex1][WINDOW_RS2_ADDR +:
                                             `RV64_REG_ADDR_WIDTH];
                gpr_read_port_used[3] = 1'b1;
            end
        end

        if (issue_select_mem_valid) begin
            if (uses_rs1_q[issue_select_mem] &&
                !src1_producer_valid_q[issue_select_mem] &&
                (payload_q[issue_select_mem][WINDOW_RS1_ADDR +:
                                          `RV64_REG_ADDR_WIDTH] !=
                 `RV64_REG_X0)) begin
                gpr_read_addr_o[4*`RV64_REG_ADDR_WIDTH +:
                                `RV64_REG_ADDR_WIDTH] =
                    payload_q[issue_select_mem][WINDOW_RS1_ADDR +:
                                             `RV64_REG_ADDR_WIDTH];
                gpr_read_port_used[4] = 1'b1;
            end
            if (uses_rs2_q[issue_select_mem] &&
                !src2_producer_valid_q[issue_select_mem] &&
                (payload_q[issue_select_mem][WINDOW_RS2_ADDR +:
                                          `RV64_REG_ADDR_WIDTH] !=
                 `RV64_REG_X0)) begin
                gpr_read_addr_o[5*`RV64_REG_ADDR_WIDTH +:
                                `RV64_REG_ADDR_WIDTH] =
                    payload_q[issue_select_mem][WINDOW_RS2_ADDR +:
                                             `RV64_REG_ADDR_WIDTH];
                gpr_read_port_used[5] = 1'b1;
            end
        end

        if (extension_scalar_read_valid_i &&
            !src1_producer_valid_q[extension_scalar_slot] &&
            (extension_scalar_read_addr_i != `RV64_REG_X0)) begin
            for (extension_scalar_port = 0;
                 extension_scalar_port < 6;
                 extension_scalar_port = extension_scalar_port + 1) begin
                if (!extension_scalar_port_found &&
                    !gpr_read_port_used[extension_scalar_port]) begin
                    extension_scalar_port_found = 1'b1;
                    extension_scalar_selected_port =
                        extension_scalar_port[2:0];
                    gpr_read_addr_o[
                        extension_scalar_port*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH] = extension_scalar_read_addr_i;
                end
            end
        end
    end

    // PRF read data is deliberately consumed in a separate process from read
    // address generation.  Combining them makes synthesis and event-driven
    // simulation conservatively infer a read-data -> read-address loop.
    always_comb begin
        select_ex0_src1_data = src1_data_now[issue_select_ex0];
        select_ex0_src2_data = src2_data_now[issue_select_ex0];
        select_ex1_src1_data = src1_data_now[issue_select_ex1];
        select_ex1_src2_data = src2_data_now[issue_select_ex1];
        select_mem_src1_data = src1_data_now[issue_select_mem];
        select_mem_src2_data = src2_data_now[issue_select_mem];
        extension_scalar_read_ready_o = 1'b0;
        extension_scalar_read_data_o = {`RV64_XLEN{1'b0}};

        if (issue_select_ex0_valid && gpr_read_port_used[0])
            select_ex0_src1_data = gpr_read_data_i[
                0*`RV64_XLEN +: `RV64_XLEN];
        if (issue_select_ex0_valid && gpr_read_port_used[1])
            select_ex0_src2_data = gpr_read_data_i[
                1*`RV64_XLEN +: `RV64_XLEN];
        if (issue_select_ex1_valid && gpr_read_port_used[2])
            select_ex1_src1_data = gpr_read_data_i[
                2*`RV64_XLEN +: `RV64_XLEN];
        if (issue_select_ex1_valid && gpr_read_port_used[3])
            select_ex1_src2_data = gpr_read_data_i[
                3*`RV64_XLEN +: `RV64_XLEN];
        if (issue_select_mem_valid && gpr_read_port_used[4])
            select_mem_src1_data = gpr_read_data_i[
                4*`RV64_XLEN +: `RV64_XLEN];
        if (issue_select_mem_valid && gpr_read_port_used[5])
            select_mem_src2_data = gpr_read_data_i[
                5*`RV64_XLEN +: `RV64_XLEN];

        if (extension_scalar_read_valid_i) begin
            if (src1_producer_valid_q[extension_scalar_slot]) begin
                extension_scalar_read_ready_o =
                    src1_ready_now[extension_scalar_slot];
                extension_scalar_read_data_o =
                    src1_data_now[extension_scalar_slot];
            end else if (extension_scalar_read_addr_i == `RV64_REG_X0) begin
                extension_scalar_read_ready_o = 1'b1;
            end else if (extension_scalar_port_found) begin
                extension_scalar_read_ready_o = 1'b1;
                extension_scalar_read_data_o = gpr_read_data_i[
                    extension_scalar_selected_port*`RV64_XLEN +:
                    `RV64_XLEN];
            end
        end
    end

    always_comb begin
        select_ex0_valid = 1'b0;
        select_ex1_valid = 1'b0;
        select_mem_valid = 1'b0;
        select_mem2_valid = 1'b0;
        select_ex0 = {RETIRE_SLOT_WIDTH{1'b0}};
        select_ex1 = {RETIRE_SLOT_WIDTH{1'b0}};
        select_mem = {RETIRE_SLOT_WIDTH{1'b0}};
        select_mem2 = {RETIRE_SLOT_WIDTH{1'b0}};
        past_selected_mem = 1'b0;
        checked_next_mem = 1'b0;

        // Reserve fixed-capability work first, in age order.
        for (select_offset = 0; select_offset < DEPTH;
             select_offset = select_offset + 1) begin
            select_slot = next_retire_slot_i + select_offset;
            if (select_slot >= DEPTH)
                select_slot = select_slot - DEPTH;
            if (!select_ex0_valid && eligible[select_slot] &&
                !extension_valid_q[select_slot] &&
                is_fixed_ex0(payload_q[select_slot])) begin
                select_ex0_valid = 1'b1;
                select_ex0 = select_slot[RETIRE_SLOT_WIDTH-1:0];
            end
            if (!select_ex1_valid && eligible[select_slot] &&
                !extension_valid_q[select_slot] &&
                is_fixed_ex1(payload_q[select_slot])) begin
                select_ex1_valid = 1'b1;
                select_ex1 = select_slot[RETIRE_SLOT_WIDTH-1:0];
            end
            if (!select_mem_valid && eligible[select_slot] &&
                is_mem(payload_q[select_slot])) begin
                select_mem_valid = 1'b1;
                select_mem = select_slot[RETIRE_SLOT_WIDTH-1:0];
            end
        end

        // Flexible base-ALU instructions consume remaining EX lanes oldest
        // first.  A slot is never selected twice.
        for (select_offset = 0; select_offset < DEPTH;
             select_offset = select_offset + 1) begin
            select_slot = next_retire_slot_i + select_offset;
            if (select_slot >= DEPTH)
                select_slot = select_slot - DEPTH;
            if (!select_ex0_valid && eligible[select_slot] &&
                !extension_valid_q[select_slot] &&
                is_flexible_alu(payload_q[select_slot]) &&
                (!select_ex1_valid ||
                 (select_ex1 != select_slot[RETIRE_SLOT_WIDTH-1:0]))) begin
                select_ex0_valid = 1'b1;
                select_ex0 = select_slot[RETIRE_SLOT_WIDTH-1:0];
            end
        end
        for (select_offset = 0; select_offset < DEPTH;
             select_offset = select_offset + 1) begin
            select_slot = next_retire_slot_i + select_offset;
            if (select_slot >= DEPTH)
                select_slot = select_slot - DEPTH;
            if (!select_ex1_valid && eligible[select_slot] &&
                !extension_valid_q[select_slot] &&
                is_flexible_alu(payload_q[select_slot]) &&
                (!select_ex0_valid ||
                 (select_ex0 != select_slot[RETIRE_SLOT_WIDTH-1:0]))) begin
                select_ex1_valid = 1'b1;
                select_ex1 = select_slot[RETIRE_SLOT_WIDTH-1:0];
            end
        end

        // The first candidate is the oldest eligible memory operation.  Scan
        // forward to exactly the next unissued memory operation; do not skip
        // an unready or same-lane operation to manufacture a pair.
        if (select_mem_valid) begin
            for (select_offset = 0; select_offset < DEPTH;
                 select_offset = select_offset + 1) begin
                select_slot = next_retire_slot_i + select_offset;
                if (select_slot >= DEPTH)
                    select_slot = select_slot - DEPTH;
                if (!past_selected_mem &&
                    (select_slot[RETIRE_SLOT_WIDTH-1:0] == select_mem)) begin
                    past_selected_mem = 1'b1;
                end else if (past_selected_mem && !checked_next_mem &&
                             valid_q[select_slot] &&
                             !issued_q[select_slot] &&
                             is_mem(payload_q[select_slot])) begin
                    checked_next_mem = 1'b1;
                    if (mem_pair_eligible[select_slot] &&
                        !extension_valid_q[select_mem] &&
                        !extension_valid_q[select_slot] &&
                        (is_mem1_op(payload_q[select_slot]) !=
                         is_mem1_op(payload_q[select_mem]))) begin
                        select_mem2_valid = 1'b1;
                        select_mem2 =
                            select_slot[RETIRE_SLOT_WIDTH-1:0];
                    end
                end
            end
        end

    end

    // Ordinary loads route to MEM0; stores and every RV64A operation route to
    // MEM1.  In registered mode this must use the held slot, not the next slot
    // being considered by the scheduler.
    always_comb begin
        selected_mem_pipe = `OPENRV64_EXEC_PIPE_MEM0;
        selected_mem2_pipe = `OPENRV64_EXEC_PIPE_MEM0;
        if (issue_select_mem_valid &&
            is_mem1_op(payload_q[issue_select_mem]))
            selected_mem_pipe = `OPENRV64_EXEC_PIPE_MEM1;
        if (issue_select_mem2_valid &&
            is_mem1_op(payload_q[issue_select_mem2]))
            selected_mem2_pipe = `OPENRV64_EXEC_PIPE_MEM1;
    end

    // Materialize the legacy execution payload only after selection.  Keeping
    // this out of the selector process prevents operand data returned by the
    // PRF from entering the selector's inferred sensitivity cone.
    always_comb begin
        selected_idx = 0;
        pipe_id_o =
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_INSTR_ID_WIDTH{1'b0}};
        pipe_slot_o =
            {`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH{1'b0}};
        pipe_payload_o =
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
        pipe_src1_producer_valid_o =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        pipe_src1_producer_slot_o =
            {`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH{1'b0}};
        pipe_src2_producer_valid_o =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        pipe_src2_producer_slot_o =
            {`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH{1'b0}};
        trace_pipe_uses_rs1 = 3'b000;
        trace_pipe_uses_rs2 = 3'b000;

        if (issue_select_ex0_valid) begin
            selected_idx = issue_select_ex0;
            pipe_id_o[
                0*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = id_q[selected_idx];
            pipe_slot_o[0*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] =
                issue_select_ex0;
            pipe_payload_o[
                0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] = expand_payload(
                    payload_q[selected_idx], trace_id_q[selected_idx],
                    select_ex0_src1_data,
                    select_ex0_src2_data);
            pipe_src1_producer_valid_o[0] =
                src1_producer_valid_q[selected_idx];
            pipe_src1_producer_slot_o[
                0*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] =
                src1_dependency_slot_q[selected_idx];
            pipe_src2_producer_valid_o[0] =
                src2_producer_valid_q[selected_idx];
            pipe_src2_producer_slot_o[
                0*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] =
                src2_dependency_slot_q[selected_idx];
            trace_pipe_uses_rs1[0] = uses_rs1_q[selected_idx];
            trace_pipe_uses_rs2[0] = uses_rs2_q[selected_idx];
        end
        if (issue_select_ex1_valid) begin
            selected_idx = issue_select_ex1;
            pipe_id_o[
                1*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = id_q[selected_idx];
            pipe_slot_o[1*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] =
                issue_select_ex1;
            pipe_payload_o[
                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] = expand_payload(
                    payload_q[selected_idx], trace_id_q[selected_idx],
                    select_ex1_src1_data,
                    select_ex1_src2_data);
            pipe_src1_producer_valid_o[1] =
                src1_producer_valid_q[selected_idx];
            pipe_src1_producer_slot_o[
                1*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] =
                src1_dependency_slot_q[selected_idx];
            pipe_src2_producer_valid_o[1] =
                src2_producer_valid_q[selected_idx];
            pipe_src2_producer_slot_o[
                1*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] =
                src2_dependency_slot_q[selected_idx];
            trace_pipe_uses_rs1[1] = uses_rs1_q[selected_idx];
            trace_pipe_uses_rs2[1] = uses_rs2_q[selected_idx];
        end
        if (issue_select_mem_valid) begin
            pipe_id_o[
                selected_mem_pipe*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = id_q[issue_select_mem];
            pipe_slot_o[
                selected_mem_pipe*RETIRE_SLOT_WIDTH +:
                RETIRE_SLOT_WIDTH] = issue_select_mem;
            pipe_payload_o[
                selected_mem_pipe*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] = expand_payload(
                    payload_q[issue_select_mem], trace_id_q[issue_select_mem],
                    select_mem_src1_data,
                    select_mem_src2_data);
            if (extension_entry_store_i[issue_select_mem])
                pipe_payload_o[
                    selected_mem_pipe*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                    PAYLOAD_RS2_DATA +: `RV64_XLEN] =
                    extension_entry_store_data_i[
                        issue_select_mem*`RV64_XLEN +: `RV64_XLEN];
            pipe_src1_producer_valid_o[selected_mem_pipe] =
                src1_producer_valid_q[issue_select_mem];
            pipe_src1_producer_slot_o[
                selected_mem_pipe*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] =
                src1_dependency_slot_q[issue_select_mem];
            pipe_src2_producer_valid_o[selected_mem_pipe] =
                src2_producer_valid_q[issue_select_mem];
            pipe_src2_producer_slot_o[
                selected_mem_pipe*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] =
                src2_dependency_slot_q[issue_select_mem];
            trace_pipe_uses_rs1[2] = uses_rs1_q[issue_select_mem];
            trace_pipe_uses_rs2[2] = uses_rs2_q[issue_select_mem];
        end
        if (issue_select_mem2_valid) begin
            pipe_id_o[
                selected_mem2_pipe*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = id_q[issue_select_mem2];
            pipe_slot_o[
                selected_mem2_pipe*RETIRE_SLOT_WIDTH +:
                RETIRE_SLOT_WIDTH] = issue_select_mem2;
            pipe_payload_o[
                selected_mem2_pipe*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] = expand_payload(
                    payload_q[issue_select_mem2],
                    trace_id_q[issue_select_mem2],
                    src1_data_now[issue_select_mem2],
                    src2_data_now[issue_select_mem2]);
            pipe_src1_producer_valid_o[selected_mem2_pipe] =
                src1_producer_valid_q[issue_select_mem2];
            pipe_src1_producer_slot_o[
                selected_mem2_pipe*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] =
                src1_dependency_slot_q[issue_select_mem2];
            pipe_src2_producer_valid_o[selected_mem2_pipe] =
                src2_producer_valid_q[issue_select_mem2];
            pipe_src2_producer_slot_o[
                selected_mem2_pipe*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] =
                src2_dependency_slot_q[issue_select_mem2];
            trace_pipe_uses_rs1[2] =
                uses_rs1_q[issue_select_mem] |
                uses_rs1_q[issue_select_mem2];
            trace_pipe_uses_rs2[2] =
                uses_rs2_q[issue_select_mem] |
                uses_rs2_q[issue_select_mem2];
        end
    end

    // Keep valid generation in a separate process from payload routing.
    // Execution readiness depends on the routed operation's capability; a
    // combined ready -> valid -> payload process forms a false combinational
    // loop in synthesis even though the payload selection itself is stable.
    always @* begin
        pipe_valid_o = {
            2'b00,
            issue_select_ex1_valid,
            issue_select_ex0_valid
        };
        extension_mem_issue_valid_o = issue_select_mem_valid &&
            extension_valid_q[issue_select_mem];
        extension_mem_issue_is_load_o = 1'b0;
        extension_mem_issue_id_o =
            {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        extension_mem_issue_slot_o =
            {RETIRE_SLOT_WIDTH{1'b0}};
        if (extension_mem_issue_valid_o) begin
            extension_mem_issue_is_load_o =
                extension_entry_load_i[issue_select_mem];
            extension_mem_issue_id_o = id_q[issue_select_mem];
            extension_mem_issue_slot_o = issue_select_mem;
        end
        if (issue_select_mem_valid &&
            (!extension_valid_q[issue_select_mem] ||
             !extension_entry_load_i[issue_select_mem] ||
             extension_load_issue_ready_i))
            pipe_valid_o[selected_mem_pipe] = 1'b1;
        // This variant still issues at most one memory operation per cycle.
        // Restoring the 3P paired-valid equation here creates a zero-time loop
        // through the 4PF execution wrapper.  That wrapper needs an explicit
        // registered/skid acceptance boundary before integer pairing is safe.
    end

    always @* begin
        extension_mem_issue_fire_o = extension_mem_issue_valid_o &&
            pipe_valid_o[selected_mem_pipe] &&
            pipe_ready_i[selected_mem_pipe];
    end

    wire issue_ex0 = pipe_valid_o[0] && pipe_ready_i[0];
    wire issue_ex1 = pipe_valid_o[1] && pipe_ready_i[1];
    wire issue_mem0 = pipe_valid_o[2] && pipe_ready_i[2];
    wire issue_mem1 = pipe_valid_o[3] && pipe_ready_i[3];
    wire issue_mem_primary = issue_select_mem_valid &&
        (is_mem1_op(payload_q[issue_select_mem]) ? issue_mem1 : issue_mem0);
    wire issue_mem_secondary = issue_select_mem2_valid &&
        (is_mem1_op(payload_q[issue_select_mem2]) ? issue_mem1 : issue_mem0);

    integer entry_idx;
    integer completion_port;
    integer retire_lane;
    integer allocation_lane;
    reg [RETIRE_SLOT_WIDTH-1:0] update_slot;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] update_completion;
    reg [31:0] survivor_owner_valid;
    reg [31:0] survivor_owner_ready;
    reg [RETIRE_SLOT_WIDTH-1:0] survivor_owner_slot [0:31];
    reg [DEPTH-1:0] survivor_window_valid;
    reg [COUNT_WIDTH-1:0] survivor_count;
    reg survivor_retiring;
    reg survivor_result_ready;
    reg [`RV64_REG_ADDR_WIDTH-1:0] survivor_rd;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        survivor_completion;
    integer survivor_offset;
    integer survivor_slot;
    integer squash_distance;
    integer survivor_lane;
    integer survivor_port;
    integer survivor_owner_idx;
    integer owner_seq_idx;

    wire selective_squash = squash_frontend_i &&
        (ENABLE_SPECULATION != 0) && valid_q[squash_slot_i] &&
        (id_q[squash_slot_i] == squash_id_i);

    // Recovery rebuilds the rename/ownership view from the entries retained
    // through the mispredicted branch.  Per-entry completion data is kept for
    // exactly this purpose: a squashed younger WAW must reveal the older live
    // producer rather than the stale architectural GPR value.
    always @* begin
        survivor_owner_valid = 32'd0;
        survivor_owner_ready = 32'd0;
        survivor_window_valid = {DEPTH{1'b0}};
        survivor_count = {COUNT_WIDTH{1'b0}};
        survivor_result_ready = 1'b0;
        survivor_rd = {`RV64_REG_ADDR_WIDTH{1'b0}};
        survivor_completion =
            {`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH{1'b0}};
        if (squash_slot_i >= next_retire_slot_i)
            squash_distance = squash_slot_i - next_retire_slot_i;
        else
            squash_distance = DEPTH + squash_slot_i - next_retire_slot_i;
        for (survivor_owner_idx = 0; survivor_owner_idx < 32;
             survivor_owner_idx = survivor_owner_idx + 1) begin
            survivor_owner_slot[survivor_owner_idx] =
                {RETIRE_SLOT_WIDTH{1'b0}};
        end
        // Rebuild oldest to youngest.  A later surviving writer simply
        // overwrites the architectural owner selected by an older writer.
        for (survivor_offset = 0; survivor_offset < DEPTH;
             survivor_offset = survivor_offset + 1) begin
            survivor_slot = next_retire_slot_i + survivor_offset;
            if (survivor_slot >= DEPTH)
                survivor_slot = survivor_slot - DEPTH;
            survivor_retiring = 1'b0;
            for (survivor_lane = 0; survivor_lane < 3;
                 survivor_lane = survivor_lane + 1) begin
                if (retire_valid_i[survivor_lane] &&
                    (retire_slot_i[
                        survivor_lane*RETIRE_SLOT_WIDTH +:
                        RETIRE_SLOT_WIDTH] == survivor_slot))
                    survivor_retiring = 1'b1;
            end
            if ((survivor_offset <= squash_distance) &&
                valid_q[survivor_slot] && !survivor_retiring) begin
                survivor_window_valid[survivor_slot] = 1'b1;
                survivor_count = survivor_count + 1'b1;
                survivor_rd = payload_q[survivor_slot][
                    PAYLOAD_RD +: `RV64_REG_ADDR_WIDTH];
                survivor_result_ready = result_ready_q[survivor_slot];
                for (survivor_port = 0; survivor_port < 3;
                     survivor_port = survivor_port + 1) begin
                    survivor_completion = completion_payload_i[
                        survivor_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                        `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
                    if (completion_current[survivor_port] &&
                        completion_safe(survivor_completion) &&
                        (completion_slot_i[
                            survivor_port*RETIRE_SLOT_WIDTH +:
                            RETIRE_SLOT_WIDTH] == survivor_slot)) begin
                        survivor_result_ready = 1'b1;
                    end
                end
                if (payload_q[survivor_slot][PAYLOAD_REG_WRITE] &&
                    (survivor_rd != `RV64_REG_X0)) begin
                    survivor_owner_valid[survivor_rd] = 1'b1;
                    survivor_owner_ready[survivor_rd] =
                        survivor_result_ready;
                    survivor_owner_slot[survivor_rd] =
                        survivor_slot[RETIRE_SLOT_WIDTH-1:0];
                end
            end
        end
        survivor_owner_valid[`RV64_REG_X0] = 1'b0;
        survivor_owner_ready[`RV64_REG_X0] = 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_select_ex0_valid_q <= 1'b0;
            issue_select_ex1_valid_q <= 1'b0;
            issue_select_mem_valid_q <= 1'b0;
            issue_select_ex0_q <= {RETIRE_SLOT_WIDTH{1'b0}};
            issue_select_ex1_q <= {RETIRE_SLOT_WIDTH{1'b0}};
            issue_select_mem_q <= {RETIRE_SLOT_WIDTH{1'b0}};
        end else if (flush_i ||
                     (squash_frontend_i &&
                      (ENABLE_SPECULATION == 0)) ||
                     (REGISTER_ISSUE_SELECT == 0)) begin
            issue_select_ex0_valid_q <= 1'b0;
            issue_select_ex1_valid_q <= 1'b0;
            issue_select_mem_valid_q <= 1'b0;
            issue_select_ex0_q <= {RETIRE_SLOT_WIDTH{1'b0}};
            issue_select_ex1_q <= {RETIRE_SLOT_WIDTH{1'b0}};
            issue_select_mem_q <= {RETIRE_SLOT_WIDTH{1'b0}};
        end else if (selective_squash) begin
            if (issue_ex0 ||
                !survivor_window_valid[issue_select_ex0_q])
                issue_select_ex0_valid_q <= 1'b0;
            if (issue_ex1 ||
                !survivor_window_valid[issue_select_ex1_q])
                issue_select_ex1_valid_q <= 1'b0;
            if (issue_mem_primary ||
                !survivor_window_valid[issue_select_mem_q])
                issue_select_mem_valid_q <= 1'b0;
        end else begin
            if (!issue_select_ex0_valid_q || issue_ex0) begin
                issue_select_ex0_valid_q <= select_ex0_valid;
                if (select_ex0_valid)
                    issue_select_ex0_q <= select_ex0;
            end
            if (!issue_select_ex1_valid_q || issue_ex1) begin
                issue_select_ex1_valid_q <= select_ex1_valid;
                if (select_ex1_valid)
                    issue_select_ex1_q <= select_ex1;
            end
            if (!issue_select_mem_valid_q || issue_mem_primary) begin
                issue_select_mem_valid_q <= select_mem_valid;
                if (select_mem_valid)
                    issue_select_mem_q <= select_mem;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count_q <= {COUNT_WIDTH{1'b0}};
            owner_valid_q <= 32'd0;
            owner_ready_q <= 32'd0;
            for (owner_seq_idx = 0; owner_seq_idx < 32;
                 owner_seq_idx = owner_seq_idx + 1) begin
                owner_slot_q[owner_seq_idx] <=
                    {RETIRE_SLOT_WIDTH{1'b0}};
            end
            for (entry_idx = 0; entry_idx < DEPTH;
                 entry_idx = entry_idx + 1) begin
                valid_q[entry_idx] <= 1'b0;
                issued_q[entry_idx] <= 1'b0;
                id_q[entry_idx] <=
                    {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
                payload_q[entry_idx] <=
                    {WINDOW_PAYLOAD_WIDTH{1'b0}};
                trace_id_q[entry_idx] <= {`RV64_XLEN{1'b0}};
                extension_valid_q[entry_idx] <= 1'b0;
                uses_rs1_q[entry_idx] <= 1'b0;
                uses_rs2_q[entry_idx] <= 1'b0;
                src1_ready_q[entry_idx] <= 1'b0;
                src2_ready_q[entry_idx] <= 1'b0;
                src1_producer_valid_q[entry_idx] <= 1'b0;
                src2_producer_valid_q[entry_idx] <= 1'b0;
                src1_dependency_slot_q[entry_idx] <=
                    {RETIRE_SLOT_WIDTH{1'b0}};
                src2_dependency_slot_q[entry_idx] <=
                    {RETIRE_SLOT_WIDTH{1'b0}};
                result_ready_q[entry_idx] <= 1'b0;
                result_data_q[entry_idx] <= {`RV64_XLEN{1'b0}};
            end
        end else if (flush_i ||
                     (squash_frontend_i &&
                      (ENABLE_SPECULATION == 0))) begin
            count_q <= {COUNT_WIDTH{1'b0}};
            owner_valid_q <= 32'd0;
            owner_ready_q <= 32'd0;
            for (entry_idx = 0; entry_idx < DEPTH;
                 entry_idx = entry_idx + 1) begin
                valid_q[entry_idx] <= 1'b0;
                issued_q[entry_idx] <= 1'b0;
                extension_valid_q[entry_idx] <= 1'b0;
            end
        end else if (selective_squash) begin
            count_q <= survivor_count;
            owner_valid_q <= survivor_owner_valid;
            owner_ready_q <= survivor_owner_ready;
            for (owner_seq_idx = 0; owner_seq_idx < 32;
                 owner_seq_idx = owner_seq_idx + 1) begin
                owner_slot_q[owner_seq_idx] <=
                    survivor_owner_slot[owner_seq_idx];
            end

            // Preserve the resolving branch and all older work.  A late
            // completion is accepted only when both its slot and global ID
            // still identify the current slot occupant.
            for (entry_idx = 0; entry_idx < DEPTH;
                 entry_idx = entry_idx + 1) begin
                if (!survivor_window_valid[entry_idx]) begin
                    valid_q[entry_idx] <= 1'b0;
                    issued_q[entry_idx] <= 1'b0;
                    extension_valid_q[entry_idx] <= 1'b0;
                    result_ready_q[entry_idx] <= 1'b0;
                end else begin
                    for (completion_port = 0; completion_port < 3;
                         completion_port = completion_port + 1) begin
                        update_slot = completion_slot_i[
                            completion_port*RETIRE_SLOT_WIDTH +:
                            RETIRE_SLOT_WIDTH];
                        update_completion = completion_payload_i[
                            completion_port*
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
                        if (completion_current[completion_port] &&
                            completion_safe(update_completion) &&
                            (update_slot == entry_idx)) begin
                            result_ready_q[entry_idx] <= 1'b1;
                            result_data_q[entry_idx] <= update_completion[
                                `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
                        end
                        if (completion_current[completion_port] &&
                            completion_safe(update_completion) &&
                            !src1_ready_q[entry_idx] &&
                            (src1_dependency_slot_q[entry_idx] ==
                             update_slot)) begin
                            src1_ready_q[entry_idx] <= 1'b1;
                        end
                        if (completion_current[completion_port] &&
                            completion_safe(update_completion) &&
                            !src2_ready_q[entry_idx] &&
                            (src2_dependency_slot_q[entry_idx] ==
                             update_slot)) begin
                            src2_ready_q[entry_idx] <= 1'b1;
                        end
                    end
                    for (retire_lane = 0; retire_lane < 3;
                         retire_lane = retire_lane + 1) begin
                        update_slot = retire_slot_i[
                            retire_lane*RETIRE_SLOT_WIDTH +:
                            RETIRE_SLOT_WIDTH];
                        if (retire_valid_i[retire_lane] &&
                            src1_producer_valid_q[entry_idx] &&
                            (src1_dependency_slot_q[entry_idx] ==
                             update_slot)) begin
                            src1_producer_valid_q[entry_idx] <= 1'b0;
                            src1_ready_q[entry_idx] <= 1'b1;
                        end
                        if (retire_valid_i[retire_lane] &&
                            src2_producer_valid_q[entry_idx] &&
                            (src2_dependency_slot_q[entry_idx] ==
                             update_slot)) begin
                            src2_producer_valid_q[entry_idx] <= 1'b0;
                            src2_ready_q[entry_idx] <= 1'b1;
                        end
                    end
                end
            end

            if (issue_ex0 && survivor_window_valid[issue_select_ex0])
                issued_q[issue_select_ex0] <= 1'b1;
            if (issue_ex1 && survivor_window_valid[issue_select_ex1])
                issued_q[issue_select_ex1] <= 1'b1;
            if (issue_mem_primary &&
                survivor_window_valid[issue_select_mem])
                issued_q[issue_select_mem] <= 1'b1;
            if (issue_mem_secondary &&
                survivor_window_valid[issue_select_mem2])
                issued_q[issue_select_mem2] <= 1'b1;
            if (extension_issue_fire_i &&
                valid_q[extension_issue_slot_i] &&
                (id_q[extension_issue_slot_i] == extension_issue_id_i) &&
                survivor_window_valid[extension_issue_slot_i])
                issued_q[extension_issue_slot_i] <= 1'b1;
        end else begin
            count_q <= count_q + decode_count - retire_count;
            owner_valid_q <= owner_valid_view;
            owner_ready_q <= owner_ready_view;
            for (owner_seq_idx = 0; owner_seq_idx < 32;
                 owner_seq_idx = owner_seq_idx + 1) begin
                owner_slot_q[owner_seq_idx] <=
                    owner_slot_view[owner_seq_idx];
            end

            // Persist completion wakeups so a one-cycle completion broadcast
            // is sufficient no matter how long the consumer waits to issue.
            for (entry_idx = 0; entry_idx < DEPTH;
                 entry_idx = entry_idx + 1) begin
                if (valid_q[entry_idx]) begin
                    for (completion_port = 0; completion_port < 3;
                         completion_port = completion_port + 1) begin
                        update_slot = completion_slot_i[
                            completion_port*RETIRE_SLOT_WIDTH +:
                            RETIRE_SLOT_WIDTH];
                        update_completion = completion_payload_i[
                            completion_port*
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
                        if (completion_current[completion_port] &&
                            completion_safe(update_completion) &&
                            (entry_idx == update_slot)) begin
                            result_ready_q[entry_idx] <= 1'b1;
                            result_data_q[entry_idx] <= update_completion[
                                `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
                        end
                        if (completion_current[completion_port] &&
                            completion_safe(update_completion) &&
                            !src1_ready_q[entry_idx] &&
                            (src1_dependency_slot_q[entry_idx] ==
                             update_slot)) begin
                            src1_ready_q[entry_idx] <= 1'b1;
                        end
                        if (completion_current[completion_port] &&
                            completion_safe(update_completion) &&
                            !src2_ready_q[entry_idx] &&
                            (src2_dependency_slot_q[entry_idx] ==
                             update_slot)) begin
                            src2_ready_q[entry_idx] <= 1'b1;
                        end
                    end
                    for (retire_lane = 0; retire_lane < 3;
                         retire_lane = retire_lane + 1) begin
                        update_slot = retire_slot_i[
                            retire_lane*RETIRE_SLOT_WIDTH +:
                            RETIRE_SLOT_WIDTH];
                        if (retire_valid_i[retire_lane] &&
                            src1_producer_valid_q[entry_idx] &&
                            (src1_dependency_slot_q[entry_idx] ==
                             update_slot)) begin
                            src1_producer_valid_q[entry_idx] <= 1'b0;
                            src1_ready_q[entry_idx] <= 1'b1;
                        end
                        if (retire_valid_i[retire_lane] &&
                            src2_producer_valid_q[entry_idx] &&
                            (src2_dependency_slot_q[entry_idx] ==
                             update_slot)) begin
                            src2_producer_valid_q[entry_idx] <= 1'b0;
                            src2_ready_q[entry_idx] <= 1'b1;
                        end
                    end
                end
            end

            if (issue_ex0)
                issued_q[issue_select_ex0] <= 1'b1;
            if (issue_ex1)
                issued_q[issue_select_ex1] <= 1'b1;
            if (issue_mem_primary)
                issued_q[issue_select_mem] <= 1'b1;
            if (issue_mem_secondary)
                issued_q[issue_select_mem2] <= 1'b1;
            if (extension_issue_fire_i &&
                valid_q[extension_issue_slot_i] &&
                (id_q[extension_issue_slot_i] == extension_issue_id_i))
                issued_q[extension_issue_slot_i] <= 1'b1;

            for (retire_lane = 0; retire_lane < 3;
                 retire_lane = retire_lane + 1) begin
                update_slot = retire_slot_i[
                    retire_lane*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH];
                if (retire_valid_i[retire_lane]) begin
                    valid_q[update_slot] <= 1'b0;
                    issued_q[update_slot] <= 1'b0;
                    extension_valid_q[update_slot] <= 1'b0;
                    result_ready_q[update_slot] <= 1'b0;
                end
            end

            for (allocation_lane = 0; allocation_lane < 3;
                 allocation_lane = allocation_lane + 1) begin
                update_slot = allocation_slot_i[
                    allocation_lane*RETIRE_SLOT_WIDTH +:
                    RETIRE_SLOT_WIDTH];
                if (decode_fire[allocation_lane]) begin
                    valid_q[update_slot] <= 1'b1;
                    issued_q[update_slot] <= 1'b0;
                    id_q[update_slot] <= allocation_id_i[
                        allocation_lane*`OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH];
                    payload_q[update_slot] <=
                        compact_payload(admit_payload[allocation_lane]);
                    trace_id_q[update_slot] <= admit_payload[allocation_lane][
                        PAYLOAD_TRACE +: `RV64_XLEN];
                    extension_valid_q[update_slot] <=
                        decode_extension_valid_i[allocation_lane];
                    uses_rs1_q[update_slot] <=
                        decode_uses_rs1_i[allocation_lane];
                    uses_rs2_q[update_slot] <=
                        decode_uses_rs2_i[allocation_lane];
                    src1_ready_q[update_slot] <=
                        admit_src1_ready[allocation_lane];
                    src2_ready_q[update_slot] <=
                        admit_src2_ready[allocation_lane];
                    src1_producer_valid_q[update_slot] <=
                        admit_src1_producer_valid[allocation_lane];
                    src2_producer_valid_q[update_slot] <=
                        admit_src2_producer_valid[allocation_lane];
                    src1_dependency_slot_q[update_slot] <=
                        admit_src1_dependency_slot[allocation_lane];
                    src2_dependency_slot_q[update_slot] <=
                        admit_src2_dependency_slot[allocation_lane];
                    result_ready_q[update_slot] <= 1'b0;
                    result_data_q[update_slot] <= {`RV64_XLEN{1'b0}};
                end
            end
        end
    end

    assign waw_hazard_o = 3'b000;
    assign read_port_hazard_o = 3'b000;
    assign write_busy_o = owner_valid_q;
    assign queue_count_o = count_q;

    wire unused_retire_hard = |retire_hard_i;

`ifndef SYNTHESIS
    reg debug_window;
    reg [63:0] debug_pc;
    integer debug_lane;
    integer debug_slot;
    initial begin
        debug_window = $value$plusargs("issue_window_debug_pc=%h", debug_pc);
    end

    initial begin
        if ((ENABLE != 0) && (DEPTH != (1 << RETIRE_SLOT_WIDTH)))
            $fatal(1, "issue-window depth must be a power of two");
    end

    always @(posedge clk) begin
        if (rst_n && !flush_i && !squash_frontend_i) begin
            if ((decode_valid_i != 3'b000) &&
                (decode_valid_i != 3'b001) &&
                (decode_valid_i != 3'b011) &&
                (decode_valid_i != 3'b111))
                $fatal(1, "window decode input must be a contiguous prefix");
            if ((count_q + decode_count - retire_count) > DEPTH)
                $fatal(1, "issue window overflow");
        end
    end

    always @(negedge clk) begin
        if (rst_n && debug_window) begin
            for (debug_lane = 0; debug_lane < 3;
                 debug_lane = debug_lane + 1) begin
                if (decode_fire[debug_lane] &&
                    (admit_payload[debug_lane][274 +: 64] == debug_pc)) begin
                    debug_slot = allocation_slot_i[
                        debug_lane*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH];
                    $display({"WINDOW_DEBUG_ALLOC pc=%016x id=%016x slot=%0d ",
                              "s1_ready=%0d s1_dep_slot=%0d ",
                              "s2_ready=%0d s2_dep_slot=%0d"},
                             debug_pc,
                             allocation_id_i[
                                 debug_lane*`OPENRV64_INSTR_ID_WIDTH +:
                                 `OPENRV64_INSTR_ID_WIDTH],
                             debug_slot,
                             admit_src1_ready[debug_lane],
                             admit_src1_dependency_slot[debug_lane],
                             admit_src2_ready[debug_lane],
                             admit_src2_dependency_slot[debug_lane]);
                end
            end
            for (debug_slot = 0; debug_slot < DEPTH;
                 debug_slot = debug_slot + 1) begin
                if (valid_q[debug_slot] &&
                    (payload_q[debug_slot][WINDOW_PC +: 64] == debug_pc) &&
                    ((issue_ex0 && (select_ex0 == debug_slot)) ||
                     (issue_ex1 && (select_ex1 == debug_slot)) ||
                     (issue_mem_primary &&
                      (select_mem == debug_slot)) ||
                     (issue_mem_secondary &&
                      (select_mem2 == debug_slot)))) begin
                    $display({"WINDOW_DEBUG_ISSUE pc=%016x id=%016x slot=%0d ",
                              "s1_ready=%0d s1_dep_slot=%0d s1_data=%016x ",
                              "s2_ready=%0d s2_dep_slot=%0d s2_data=%016x"},
                             debug_pc, id_q[debug_slot], debug_slot,
                             src1_ready_now[debug_slot],
                             src1_dependency_slot_q[debug_slot],
                             src1_data_now[debug_slot],
                             src2_ready_now[debug_slot],
                             src2_dependency_slot_q[debug_slot],
                             src2_data_now[debug_slot]);
                end
            end
        end
    end
`endif

endmodule
