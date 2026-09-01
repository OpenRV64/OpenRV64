`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-a.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/br-defs.v"

// Optional producer-tagged three-pipe issue window.
//
// Unlike dispatch_3p, retirement identity is allocated when decode admits an
// instruction.  The assigned retirement slot is also the physical window
// index.  Entries remain resident through issue and are released only at
// retirement, which keeps program age, completion identity, and issue state
// in one bounded structure without adding a second reorder map.
//
// Decode writes registered entries; no newly admitted instruction can issue
// until the following cycle.  Source values are captured either from the
// architectural GPR, the youngest completed producer, or a matching tagged
// completion.  Up to one instruction per physical pipe is then selected from
// the ready entries.  Memory issue remains program ordered, but the oldest two
// unissued memory operations may enter MEM0 and MEM1 together when they target
// opposite lanes and both lanes accept the complete pair.  The optional
// speculation mode lets replayable work pass an older conditional branch that
// is still waiting for operands, and lets ordinary loads begin translation
// past unresolved control.  The physically addressed LSQ admits the later
// cache access only when translation classifies the result as cacheable RAM;
// device/non-RAM loads wait for ordered retirement.  Stores and atomics remain
// protected.  Legal aligned direct JALs are deterministic controls, so they do
// not form an issue barrier even before reaching the retirement head.
// Conditional branches themselves resolve in program order so a younger
// wrong-path branch cannot redirect or train before an older branch resolves.
module openrv64_dispatch_window_3p #(
    parameter integer ENABLE = 1,
    parameter integer ENABLE_SPECULATION = 0,
    parameter integer DEFER_GPR_READ = 0,
    parameter integer MAX_ISSUE_LANES = 4,
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
    input  wire                         translation_bypass_i,

    input  wire [2:0]                   decode_valid_i,
    output wire [2:0]                   decode_ready_o,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        decode_payload_i,
    input  wire [2:0]                   decode_uses_rs1_i,
    input  wire [2:0]                   decode_uses_rs2_i,

    output wire [6*`RV64_REG_ADDR_WIDTH-1:0] gpr_read_addr_o,
    input  wire [6*`RV64_XLEN-1:0]      gpr_read_data_i,

    input  wire                         allocation_ready_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] allocation_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] allocation_slot_i,
    output wire [2:0]                   allocation_valid_o,
    output wire [3*`OPENRV64_DISPATCH_META_WIDTH-1:0] allocation_meta_o,

    input  wire [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_ready_i,
    // Pre-handshake candidates and their age ranks.  The banked register-load
    // requester uses these stable sidebands to arbitrate six read addresses
    // without feeding register-file grants back into candidate generation.
    output reg  [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_candidate_valid_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*2-1:0] pipe_age_rank_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT-1:0] pipe_valid_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0] pipe_id_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH-1:0]
                                        pipe_slot_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        pipe_payload_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        pipe_uses_rs1_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        pipe_uses_rs2_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        pipe_src1_producer_valid_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0]
                                        pipe_src1_producer_id_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT-1:0]
                                        pipe_src2_producer_valid_o,
    output reg  [`OPENRV64_EXEC_PIPE_COUNT*
                 `OPENRV64_INSTR_ID_WIDTH-1:0]
                                        pipe_src2_producer_id_o,

    input  wire [2:0]                   completion_valid_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] completion_id_i,
    input  wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
                                        completion_payload_i,
    input  wire                         conditional_resolve_valid_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0]
                                        conditional_resolve_id_i,
    input  wire [RETIRE_SLOT_WIDTH-1:0]
                                        conditional_resolve_slot_i,

    input  wire [2:0]                   retire_valid_i,
    input  wire [3*`OPENRV64_INSTR_ID_WIDTH-1:0] retire_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] retire_slot_i,
    input  wire [2:0]                   retire_hard_i,
    input  wire [`OPENRV64_INSTR_ID_WIDTH-1:0] next_retire_id_i,
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
    localparam integer PAYLOAD_PREDICTED_TAKEN = 12;
    localparam integer PAYLOAD_JUMP = 13;
    localparam integer PAYLOAD_SYSTEM = 10;
    localparam integer PAYLOAD_FENCE = 9;
    localparam integer PAYLOAD_ILLEGAL = 8;
    localparam integer PAYLOAD_EBREAK = 7;
    localparam integer PAYLOAD_ECALL = 6;
    localparam integer PAYLOAD_INSTR_FAULT = 5;
    localparam integer PAYLOAD_INSTR_PAGE_FAULT = 4;
    localparam integer OPERAND_COUNT_WIDTH = $clog2((2 * DEPTH) + 1);
    localparam integer SPEC_CROSS_COUNT_WIDTH = COUNT_WIDTH + 2;

    reg                                 valid_q [0:DEPTH-1];
    reg                                 issued_q [0:DEPTH-1];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] id_q [0:DEPTH-1];
    reg [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        payload_q [0:DEPTH-1];
    reg                                 uses_rs1_q [0:DEPTH-1];
    reg                                 uses_rs2_q [0:DEPTH-1];
    reg                                 src1_ready_q [0:DEPTH-1];
    reg                                 src2_ready_q [0:DEPTH-1];
    reg                                 src1_producer_valid_q [0:DEPTH-1];
    reg                                 src2_producer_valid_q [0:DEPTH-1];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] src1_tag_q [0:DEPTH-1];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] src2_tag_q [0:DEPTH-1];
    reg                                 result_ready_q [0:DEPTH-1];
    reg [`RV64_XLEN-1:0]                result_data_q [0:DEPTH-1];
    reg [COUNT_WIDTH-1:0]               count_q;

    // Youngest architectural producer at decode admission.  Values are
    // retained after completion so a later decode does not wait for retire.
    reg [31:0]                          owner_valid_q;
    reg [31:0]                          owner_ready_q;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] owner_id_q [0:31];
    reg [`RV64_XLEN-1:0]                owner_data_q [0:31];

    // Retirement acceptance includes the retirement-record read and the
    // architectural exception/CSR checks.  Feeding that result directly back
    // into the owner update put the complete retirement-head cone in front of
    // every owner register.  Register only the producer IDs that ownership
    // needs.  Slot validity and occupancy still consume retirement
    // immediately below; ownership may remain visible for one extra cycle,
    // which is safe because a retiring producer is complete and retains the
    // same value that was written to the architectural GPR.  Exact ID matching
    // prevents the delayed release from clearing a younger WAW producer.
    reg [2:0] owner_release_valid_q;
    reg [3*`OPENRV64_INSTR_ID_WIDTH-1:0] owner_release_id_q;

    // A redirect must inhibit allocation and issue immediately, but the
    // depth-wide survivor/owner reconstruction does not need to complete on
    // that same edge.  Capture the recovery cut and run the existing cleanup
    // as a dedicated dispatch task on the following cycle.  If an older cut
    // arrives while cleanup is pending, it monotonically supersedes the first
    // cut; state discarded by the younger cut would also be discarded by the
    // older one, so the partial recovery never needs to be undone.
    reg recovery_pending_q;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] recovery_cut_id_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            owner_release_valid_q <= 3'b000;
        end else if (flush_i || squash_frontend_i) begin
            owner_release_valid_q <= 3'b000;
        end else begin
            owner_release_valid_q <= retire_valid_i;
            if (retire_valid_i != 3'b000)
                owner_release_id_q <= retire_id_i;
        end
    end

    function automatic is_hard;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
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
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
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
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_early_conditional_branch = payload[PAYLOAD_BRANCH] &&
                !payload[PAYLOAD_ILLEGAL] &&
                !payload[PAYLOAD_INSTR_FAULT] &&
                !payload[PAYLOAD_INSTR_PAGE_FAULT] &&
                !payload[PAYLOAD_IMM + 1];
        end
    endfunction

    function automatic may_speculate_past_unissued_control;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
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
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
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
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_mem = payload[PAYLOAD_MEM_READ] ||
                     payload[PAYLOAD_MEM_WRITE];
        end
    endfunction

    function automatic is_mem1_op;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        reg [`RV64_INSTR_WIDTH-1:0] payload_instr;
        begin
            payload_instr = payload[PAYLOAD_INSTR +: `RV64_INSTR_WIDTH];
            is_mem1_op = payload[PAYLOAD_MEM_WRITE] ||
                (`RV64_OPCODE(payload_instr) == `RV64_OPCODE_AMO);
        end
    endfunction

    function automatic is_speculative_load_candidate;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        input [`RV64_XLEN-1:0] issue_rs1_data;
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
                 ((CACHEABLE_SIZE != 0) &&
                  ((effective_addr - CACHEABLE_BASE) < CACHEABLE_SIZE)));
        end
    endfunction

    function automatic is_fixed_ex0;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_fixed_ex0 = !is_hard(payload) && !is_mem(payload) &&
                ((payload[PAYLOAD_ALU_EXT +: `RV64_ALU_EXT_WIDTH] ==
                  `RV64_ALU_EXT_M) ||
                 (payload[PAYLOAD_ALU_EXT +: `RV64_ALU_EXT_WIDTH] ==
                  `RV64_ALU_EXT_ZBB));
        end
    endfunction

    function automatic is_fixed_ex1;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_fixed_ex1 = is_hard(payload);
        end
    endfunction

    function automatic is_flexible_alu;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
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

    function automatic id_is_younger;
        input [`OPENRV64_INSTR_ID_WIDTH-1:0] candidate;
        input [`OPENRV64_INSTR_ID_WIDTH-1:0] reference;
        reg [`OPENRV64_INSTR_ID_WIDTH-1:0] distance;
        begin
            distance = candidate - reference;
            id_is_younger =
                (distance != {`OPENRV64_INSTR_ID_WIDTH{1'b0}}) &&
                !distance[`OPENRV64_INSTR_ID_WIDTH-1];
        end
    endfunction

    wire selective_recovery_request = squash_frontend_i &&
                                      (ENABLE_SPECULATION != 0);
    // id_is_younger(active, incoming) means the incoming cut is older.
    wire recovery_preempt = recovery_pending_q &&
                            selective_recovery_request &&
                            id_is_younger(recovery_cut_id_q, squash_id_i);
    wire selective_recovery_apply = recovery_pending_q &&
                                    !recovery_preempt;
    wire recovery_inhibit = selective_recovery_request ||
                            recovery_pending_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recovery_pending_q <= 1'b0;
            recovery_cut_id_q <=
                {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
        end else if (flush_i ||
                     (squash_frontend_i &&
                      (ENABLE_SPECULATION == 0))) begin
            recovery_pending_q <= 1'b0;
        end else if (!recovery_pending_q) begin
            if (selective_recovery_request) begin
                recovery_pending_q <= 1'b1;
                recovery_cut_id_q <= squash_id_i;
            end
        end else if (recovery_preempt) begin
            recovery_pending_q <= 1'b1;
            recovery_cut_id_q <= squash_id_i;
        end else begin
            recovery_pending_q <= 1'b0;
        end
    end

    // GPR values are sampled at decode admission.  Three same-cycle decode
    // lanes still see one another through the temporary owner view below.
    genvar read_lane;
    generate
        for (read_lane = 0; read_lane < 3; read_lane = read_lane + 1) begin : g_read
            assign gpr_read_addr_o[
                (read_lane*2+0)*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH] = decode_payload_i[
                read_lane*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                PAYLOAD_RS1_ADDR +: `RV64_REG_ADDR_WIDTH];
            assign gpr_read_addr_o[
                (read_lane*2+1)*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH] = decode_payload_i[
                read_lane*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                PAYLOAD_RS2_ADDR +: `RV64_REG_ADDR_WIDTH];
        end
    endgenerate

    wire [COUNT_WIDTH:0] free_count = DEPTH - count_q;
    assign decode_ready_o[0] = !flush_i && !recovery_inhibit &&
                               allocation_ready_i && (free_count >= 1);
    assign decode_ready_o[1] = (MAX_ISSUE_LANES > 1) &&
                               decode_ready_o[0] && (free_count >= 2);
    assign decode_ready_o[2] = (MAX_ISSUE_LANES > 2) &&
                               decode_ready_o[1] && (free_count >= 3);
    wire decode_fire0 = decode_valid_i[0] && decode_ready_o[0];
    wire decode_fire1 = decode_valid_i[1] && decode_ready_o[1] && decode_fire0;
    wire decode_fire2 = decode_valid_i[2] && decode_ready_o[2] && decode_fire1;
    wire [2:0] decode_fire = {decode_fire2, decode_fire1, decode_fire0};
    wire [1:0] decode_count = {1'b0, decode_fire0} +
                              {1'b0, decode_fire1} +
                              {1'b0, decode_fire2};
    assign allocation_valid_o = decode_fire;

    wire [1:0] retire_count = {1'b0, retire_valid_i[0]} +
                              {1'b0, retire_valid_i[1]} +
                              {1'b0, retire_valid_i[2]};

    reg [31:0] owner_valid_view;
    reg [31:0] owner_ready_view;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] owner_id_view [0:31];
    reg [`RV64_XLEN-1:0] owner_data_view [0:31];
    reg [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        admit_payload [0:2];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] admit_src1_tag [0:2];
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] admit_src2_tag [0:2];
    reg admit_src1_producer_valid [0:2];
    reg admit_src2_producer_valid [0:2];
    reg admit_src1_ready [0:2];
    reg admit_src2_ready [0:2];
    reg [`RV64_XLEN-1:0] admit_src1_data [0:2];
    reg [`RV64_XLEN-1:0] admit_src2_data [0:2];
    // WAW is deliberately relaxed in the issue-window owner map: a new
    // writer replaces the youngest owner without waiting for older writers to
    // retire.  The legacy waw_hazard_o output is therefore zero by
    // construction.  These simulation-visible counters expose the real WAW
    // opportunities and the older writers hidden behind the youngest owner.
    reg [COUNT_WIDTH-1:0] trace_waw_admit_count;
    reg [COUNT_WIDTH-1:0] trace_waw_admit_ready_count;
    reg [COUNT_WIDTH-1:0] trace_waw_admit_unready_count;
    reg [COUNT_WIDTH-1:0] trace_waw_admit_same_bundle_count;
    reg [COUNT_WIDTH-1:0] trace_waw_admit_resident_count;
    reg [COUNT_WIDTH-1:0] trace_waw_shadowed_writer_count;
    reg [COUNT_WIDTH-1:0] trace_waw_shadowed_ready_count;
    reg [31:0] admit_writer_hot;
    integer owner_idx;
    integer view_lane;
    integer view_port;
    integer waw_idx;
    reg [`RV64_REG_ADDR_WIDTH-1:0] view_rs1;
    reg [`RV64_REG_ADDR_WIDTH-1:0] view_rs2;
    reg [`RV64_REG_ADDR_WIDTH-1:0] view_rd;
    reg [`RV64_REG_ADDR_WIDTH-1:0] waw_rd;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] view_id;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] view_completion;

    always_comb begin
        owner_valid_view = owner_valid_q;
        owner_ready_view = owner_ready_q;
        trace_waw_admit_count = {COUNT_WIDTH{1'b0}};
        trace_waw_admit_ready_count = {COUNT_WIDTH{1'b0}};
        trace_waw_admit_unready_count = {COUNT_WIDTH{1'b0}};
        trace_waw_admit_same_bundle_count = {COUNT_WIDTH{1'b0}};
        trace_waw_admit_resident_count = {COUNT_WIDTH{1'b0}};
        admit_writer_hot = 32'b0;
        for (owner_idx = 0; owner_idx < 32; owner_idx = owner_idx + 1) begin
            owner_id_view[owner_idx] = owner_id_q[owner_idx];
            owner_data_view[owner_idx] = owner_data_q[owner_idx];
        end

        // Completion precedes retirement in the architectural age order.
        for (view_port = 0; view_port < 3; view_port = view_port + 1) begin
            view_id = completion_id_i[
                view_port*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH];
            view_completion = completion_payload_i[
                view_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
            view_rd = view_completion[
                `OPENRV64_COMPLETE_RD_LSB +: `RV64_REG_ADDR_WIDTH];
            if (completion_valid_i[view_port] &&
                completion_safe(view_completion) &&
                (view_rd != `RV64_REG_X0) && owner_valid_view[view_rd] &&
                (owner_id_view[view_rd] == view_id)) begin
                owner_ready_view[view_rd] = 1'b1;
                owner_data_view[view_rd] = view_completion[
                    `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
            end
        end

        for (view_lane = 0; view_lane < 3; view_lane = view_lane + 1) begin
            view_id = owner_release_id_q[
                view_lane*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH];
            for (owner_idx = 1; owner_idx < 32;
                 owner_idx = owner_idx + 1) begin
                if (owner_release_valid_q[view_lane] &&
                    owner_valid_view[owner_idx] &&
                    (owner_id_view[owner_idx] == view_id)) begin
                    owner_valid_view[owner_idx] = 1'b0;
                    owner_ready_view[owner_idx] = 1'b0;
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

            admit_src1_tag[view_lane] =
                {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            admit_src2_tag[view_lane] =
                {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            admit_src1_producer_valid[view_lane] = 1'b0;
            admit_src2_producer_valid[view_lane] = 1'b0;
            admit_src1_ready[view_lane] = 1'b1;
            admit_src2_ready[view_lane] = 1'b1;
            admit_src1_data[view_lane] = {`RV64_XLEN{1'b0}};
            admit_src2_data[view_lane] = {`RV64_XLEN{1'b0}};

            if (decode_uses_rs1_i[view_lane] &&
                (view_rs1 != `RV64_REG_X0)) begin
                if (owner_valid_view[view_rs1]) begin
                    admit_src1_producer_valid[view_lane] = 1'b1;
                    admit_src1_tag[view_lane] = owner_id_view[view_rs1];
                    admit_src1_ready[view_lane] = owner_ready_view[view_rs1];
                    admit_src1_data[view_lane] = owner_data_view[view_rs1];
                end else if (DEFER_GPR_READ == 0) begin
                    admit_src1_data[view_lane] = gpr_read_data_i[
                        (view_lane*2+0)*`RV64_XLEN +: `RV64_XLEN];
                end
            end
            if (decode_uses_rs2_i[view_lane] &&
                (view_rs2 != `RV64_REG_X0)) begin
                if (owner_valid_view[view_rs2]) begin
                    admit_src2_producer_valid[view_lane] = 1'b1;
                    admit_src2_tag[view_lane] = owner_id_view[view_rs2];
                    admit_src2_ready[view_lane] = owner_ready_view[view_rs2];
                    admit_src2_data[view_lane] = owner_data_view[view_rs2];
                end else if (DEFER_GPR_READ == 0) begin
                    admit_src2_data[view_lane] = gpr_read_data_i[
                        (view_lane*2+1)*`RV64_XLEN +: `RV64_XLEN];
                end
            end

            admit_payload[view_lane][PAYLOAD_RS1_DATA +: `RV64_XLEN] =
                admit_src1_data[view_lane];
            admit_payload[view_lane][PAYLOAD_RS2_DATA +: `RV64_XLEN] =
                admit_src2_data[view_lane];

            // Allocation is program ordered, so later lanes observe writers
            // allocated by earlier lanes in this same decode bundle.
            if (decode_fire[view_lane] &&
                admit_payload[view_lane][PAYLOAD_REG_WRITE] &&
                (view_rd != `RV64_REG_X0)) begin
                if (owner_valid_view[view_rd]) begin
                    trace_waw_admit_count = trace_waw_admit_count + 1'b1;
                    if (owner_ready_view[view_rd])
                        trace_waw_admit_ready_count =
                            trace_waw_admit_ready_count + 1'b1;
                    else
                        trace_waw_admit_unready_count =
                            trace_waw_admit_unready_count + 1'b1;
                    if (admit_writer_hot[view_rd])
                        trace_waw_admit_same_bundle_count =
                            trace_waw_admit_same_bundle_count + 1'b1;
                    else
                        trace_waw_admit_resident_count =
                            trace_waw_admit_resident_count + 1'b1;
                end
                admit_writer_hot[view_rd] = 1'b1;
                owner_valid_view[view_rd] = 1'b1;
                owner_ready_view[view_rd] = 1'b0;
                owner_id_view[view_rd] = allocation_id_i[
                    view_lane*`OPENRV64_INSTR_ID_WIDTH +:
                    `OPENRV64_INSTR_ID_WIDTH];
                owner_data_view[view_rd] = {`RV64_XLEN{1'b0}};
            end
        end
        owner_valid_view[`RV64_REG_X0] = 1'b0;
        owner_ready_view[`RV64_REG_X0] = 1'b0;
    end

    // Count resident writer entries that are no longer the architectural
    // youngest owner for their destination.  These are the older WAW writers
    // that a strict scoreboard would keep on the critical path.
    always_comb begin
        trace_waw_shadowed_writer_count = {COUNT_WIDTH{1'b0}};
        trace_waw_shadowed_ready_count = {COUNT_WIDTH{1'b0}};
        for (waw_idx = 0; waw_idx < DEPTH; waw_idx = waw_idx + 1) begin
            waw_rd = payload_q[waw_idx][
                PAYLOAD_RD +: `RV64_REG_ADDR_WIDTH];
            if (valid_q[waw_idx] &&
                payload_q[waw_idx][PAYLOAD_REG_WRITE] &&
                (waw_rd != `RV64_REG_X0) &&
                owner_valid_q[waw_rd] &&
                (owner_id_q[waw_rd] != id_q[waw_idx])) begin
                trace_waw_shadowed_writer_count =
                    trace_waw_shadowed_writer_count + 1'b1;
                if (result_ready_q[waw_idx])
                    trace_waw_shadowed_ready_count =
                        trace_waw_shadowed_ready_count + 1'b1;
            end
        end
    end

    generate
        for (read_lane = 0; read_lane < 3; read_lane = read_lane + 1) begin : g_meta
            assign allocation_meta_o[
                read_lane*`OPENRV64_DISPATCH_META_WIDTH +:
                `OPENRV64_DISPATCH_META_WIDTH] = {
                is_hard(admit_payload[read_lane]),
                decode_uses_rs2_i[read_lane],
                decode_uses_rs1_i[read_lane],
                admit_payload[read_lane]
            };
        end
    endgenerate

    reg src1_ready_now [0:DEPTH-1];
    reg src2_ready_now [0:DEPTH-1];
    reg src1_wakeup_now [0:DEPTH-1];
    reg src2_wakeup_now [0:DEPTH-1];
    reg [2:0] src1_wakeup_port_now [0:DEPTH-1];
    reg [2:0] src2_wakeup_port_now [0:DEPTH-1];
    reg [`RV64_XLEN-1:0] src1_data_now [0:DEPTH-1];
    reg [`RV64_XLEN-1:0] src2_data_now [0:DEPTH-1];
    integer ready_idx;
    integer ready_port;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] ready_id;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] ready_completion;

    always_comb begin
        for (ready_idx = 0; ready_idx < DEPTH; ready_idx = ready_idx + 1) begin
            src1_ready_now[ready_idx] = src1_ready_q[ready_idx];
            src2_ready_now[ready_idx] = src2_ready_q[ready_idx];
            src1_wakeup_now[ready_idx] = 1'b0;
            src2_wakeup_now[ready_idx] = 1'b0;
            src1_wakeup_port_now[ready_idx] = 3'b000;
            src2_wakeup_port_now[ready_idx] = 3'b000;
            src1_data_now[ready_idx] = payload_q[ready_idx][
                PAYLOAD_RS1_DATA +: `RV64_XLEN];
            src2_data_now[ready_idx] = payload_q[ready_idx][
                PAYLOAD_RS2_DATA +: `RV64_XLEN];
            for (ready_port = 0; ready_port < 3;
                 ready_port = ready_port + 1) begin
                ready_id = completion_id_i[
                    ready_port*`OPENRV64_INSTR_ID_WIDTH +:
                    `OPENRV64_INSTR_ID_WIDTH];
                ready_completion = completion_payload_i[
                    ready_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
                if (completion_valid_i[ready_port] &&
                    completion_safe(ready_completion) &&
                    !src1_ready_now[ready_idx] &&
                    (src1_tag_q[ready_idx] == ready_id)) begin
                    src1_ready_now[ready_idx] = 1'b1;
                    src1_wakeup_now[ready_idx] = 1'b1;
                    src1_wakeup_port_now[ready_idx][ready_port] = 1'b1;
                    src1_data_now[ready_idx] = ready_completion[
                        `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
                end
                if (completion_valid_i[ready_port] &&
                    completion_safe(ready_completion) &&
                    !src2_ready_now[ready_idx] &&
                    (src2_tag_q[ready_idx] == ready_id)) begin
                    src2_ready_now[ready_idx] = 1'b1;
                    src2_wakeup_now[ready_idx] = 1'b1;
                    src2_wakeup_port_now[ready_idx][ready_port] = 1'b1;
                    src2_data_now[ready_idx] = ready_completion[
                        `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
                end
            end
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
    // Directed performance evidence for non-speculative read-only loads that
    // are younger than completed control still resident in the window.  The
    // candidate count is independent of the selected completed-control policy;
    // the gate count records candidates actually held by older_live_control.
    reg [COUNT_WIDTH-1:0] trace_completed_control_load_candidate_count;
    reg [COUNT_WIDTH-1:0] trace_completed_control_load_gate_count;
    // Branch-specific speculation accounting.  LSQ "speculative" means
    // merely "not the ordered retirement head" and cannot establish that an
    // operation crossed an unresolved branch.  Keep that distinction exact
    // by tagging each resident entry with the number of older conditional
    // branches whose result has not resolved yet.
    reg [COUNT_WIDTH-1:0] trace_unresolved_conditional_count;
    reg [COUNT_WIDTH-1:0]
        trace_ready_behind_unresolved_conditional_count;
    reg [COUNT_WIDTH-1:0]
        trace_eligible_behind_unresolved_conditional_count;
    reg [COUNT_WIDTH-1:0]
        trace_unresolved_conditional_depth [0:DEPTH-1];
    reg [COUNT_WIDTH-1:0] trace_branch_spec_issue_count;
    reg [COUNT_WIDTH-1:0] trace_branch_spec_issue_alu_count;
    reg [COUNT_WIDTH-1:0] trace_branch_spec_issue_load_count;
    reg [COUNT_WIDTH-1:0] trace_branch_spec_issue_store_count;
    reg [COUNT_WIDTH-1:0] trace_branch_spec_issue_control_count;
    reg [SPEC_CROSS_COUNT_WIDTH-1:0]
        trace_branch_spec_issue_crossing_count;
    reg trace_conditional_resolve_valid;
    reg trace_conditional_resolve_predicted_taken;
    reg [COUNT_WIDTH-1:0] trace_resolve_younger_valid_count;
    reg [COUNT_WIDTH-1:0] trace_resolve_younger_issued_count;
    reg [COUNT_WIDTH-1:0] trace_resolve_younger_completed_count;
    reg [OPERAND_COUNT_WIDTH-1:0] trace_completion_wakeup_operand_count;
    reg [OPERAND_COUNT_WIDTH-1:0] trace_completion_wakeup_ex0_count;
    reg [OPERAND_COUNT_WIDTH-1:0] trace_completion_wakeup_ex1_count;
    reg [OPERAND_COUNT_WIDTH-1:0] trace_completion_wakeup_mem0_count;
    reg [COUNT_WIDTH-1:0] trace_completion_wakeup_entry_count;
    reg [COUNT_WIDTH-1:0] trace_completion_wakeup_eligible_count;
    reg [OPERAND_COUNT_WIDTH-1:0] trace_branch_wakeup_operand_count;
    reg [OPERAND_COUNT_WIDTH-1:0] trace_branch_wakeup_ex0_count;
    reg [OPERAND_COUNT_WIDTH-1:0] trace_branch_wakeup_ex1_count;
    reg [OPERAND_COUNT_WIDTH-1:0] trace_branch_wakeup_mem0_count;
    reg [COUNT_WIDTH-1:0] trace_branch_wakeup_entry_count;
    reg [COUNT_WIDTH-1:0] trace_branch_wakeup_eligible_count;
    reg [COUNT_WIDTH-1:0] trace_branch_wakeup_selected_count;
    reg [COUNT_WIDTH-1:0] trace_branch_wakeup_offer_count;
    reg [COUNT_WIDTH-1:0] trace_branch_wakeup_release_count;
    reg [OPERAND_COUNT_WIDTH-1:0]
        trace_branch_wakeup_release_operand_count;
    reg [OPERAND_COUNT_WIDTH-1:0]
        trace_branch_wakeup_release_ex0_count;
    reg [OPERAND_COUNT_WIDTH-1:0]
        trace_branch_wakeup_release_ex1_count;
    reg [OPERAND_COUNT_WIDTH-1:0]
        trace_branch_wakeup_release_mem0_count;
    reg [OPERAND_COUNT_WIDTH-1:0] trace_wait_unissued_load_count;
    reg [OPERAND_COUNT_WIDTH-1:0] trace_wait_unissued_other_count;
    reg [OPERAND_COUNT_WIDTH-1:0] trace_wait_inflight_load_count;
    reg [OPERAND_COUNT_WIDTH-1:0] trace_wait_inflight_other_count;
    reg [OPERAND_COUNT_WIDTH-1:0] trace_wait_completed_count;
    reg [OPERAND_COUNT_WIDTH-1:0] trace_wait_missing_count;
    integer eligible_idx;
    integer older_idx;
    integer wait_idx;
    integer producer_idx;
    reg wait_found;
    reg older_unissued_hard;
    reg older_persistent_hard;
    reg older_unissued_mem;
    reg older_live_control;
    reg older_completed_control;
    reg older_uncompleted_control;
    reg older_unresolved_conditional;

    always_comb begin
        barrier_active_o = 1'b0;
        raw_hazard_o = 3'b000;
        trace_unissued_count = {COUNT_WIDTH{1'b0}};
        trace_operand_ready_count = {COUNT_WIDTH{1'b0}};
        trace_eligible_count = {COUNT_WIDTH{1'b0}};
        trace_raw_block_count = {COUNT_WIDTH{1'b0}};
        trace_hard_block_count = {COUNT_WIDTH{1'b0}};
        trace_mem_order_block_count = {COUNT_WIDTH{1'b0}};
        trace_completed_control_load_candidate_count =
            {COUNT_WIDTH{1'b0}};
        trace_completed_control_load_gate_count = {COUNT_WIDTH{1'b0}};
        trace_unresolved_conditional_count = {COUNT_WIDTH{1'b0}};
        trace_ready_behind_unresolved_conditional_count =
            {COUNT_WIDTH{1'b0}};
        trace_eligible_behind_unresolved_conditional_count =
            {COUNT_WIDTH{1'b0}};
        trace_completion_wakeup_operand_count =
            {OPERAND_COUNT_WIDTH{1'b0}};
        trace_completion_wakeup_ex0_count =
            {OPERAND_COUNT_WIDTH{1'b0}};
        trace_completion_wakeup_ex1_count =
            {OPERAND_COUNT_WIDTH{1'b0}};
        trace_completion_wakeup_mem0_count =
            {OPERAND_COUNT_WIDTH{1'b0}};
        trace_completion_wakeup_entry_count = {COUNT_WIDTH{1'b0}};
        trace_completion_wakeup_eligible_count = {COUNT_WIDTH{1'b0}};
        trace_branch_wakeup_operand_count =
            {OPERAND_COUNT_WIDTH{1'b0}};
        trace_branch_wakeup_ex0_count = {OPERAND_COUNT_WIDTH{1'b0}};
        trace_branch_wakeup_ex1_count = {OPERAND_COUNT_WIDTH{1'b0}};
        trace_branch_wakeup_mem0_count = {OPERAND_COUNT_WIDTH{1'b0}};
        trace_branch_wakeup_entry_count = {COUNT_WIDTH{1'b0}};
        trace_branch_wakeup_eligible_count = {COUNT_WIDTH{1'b0}};
        for (eligible_idx = 0; eligible_idx < DEPTH;
             eligible_idx = eligible_idx + 1) begin
            trace_unresolved_conditional_depth[eligible_idx] =
                {COUNT_WIDTH{1'b0}};
            older_unissued_hard = 1'b0;
            older_persistent_hard = 1'b0;
            older_unissued_mem = 1'b0;
            older_live_control = 1'b0;
            older_completed_control = 1'b0;
            older_uncompleted_control = 1'b0;
            older_unresolved_conditional = 1'b0;
            for (older_idx = 0; older_idx < DEPTH;
                 older_idx = older_idx + 1) begin
                if (valid_q[older_idx] &&
                    id_is_younger(id_q[eligible_idx],
                                  id_q[older_idx])) begin
                    if (!issued_q[older_idx] &&
                        is_hard(payload_q[older_idx]) &&
                        !may_speculate_past_unissued_control(
                            payload_q[older_idx]))
                        older_unissued_hard = 1'b1;
                    if (is_persistent_hard(payload_q[older_idx]))
                        older_persistent_hard = 1'b1;
                    if (!issued_q[older_idx] && is_mem(payload_q[older_idx]))
                        older_unissued_mem = 1'b1;
                    if (!issued_q[older_idx] &&
                        is_early_conditional_branch(payload_q[older_idx]))
                        older_unresolved_conditional = 1'b1;
                    if (!result_ready_q[older_idx] &&
                        is_early_conditional_branch(payload_q[older_idx])) begin
                        trace_unresolved_conditional_depth[eligible_idx] =
                            trace_unresolved_conditional_depth[eligible_idx] +
                            1'b1;
                    end
                    if (payload_q[older_idx][PAYLOAD_BRANCH] ||
                        is_replayable_direct_jal(payload_q[older_idx])) begin
                        if (`OPENRV64_3P_RESULT_READY_CONTROL_RELEASE != 0)
                            older_live_control =
                                !result_ready_q[older_idx];
                        else
                            older_live_control = 1'b1;
                        if (result_ready_q[older_idx])
                            older_completed_control = 1'b1;
                        else
                            older_uncompleted_control = 1'b1;
                    end
                end
            end

            if (valid_q[eligible_idx] &&
                is_persistent_hard(payload_q[eligible_idx]))
                barrier_active_o = 1'b1;
            if (valid_q[eligible_idx] && !result_ready_q[eligible_idx] &&
                is_early_conditional_branch(payload_q[eligible_idx]))
                trace_unresolved_conditional_count =
                    trace_unresolved_conditional_count + 1'b1;

            eligible[eligible_idx] = valid_q[eligible_idx] &&
                !issued_q[eligible_idx] && src1_ready_now[eligible_idx] &&
                src2_ready_now[eligible_idx] && !older_unissued_hard &&
                !older_persistent_hard;
            if (is_persistent_hard(payload_q[eligible_idx]) &&
                (id_q[eligible_idx] != next_retire_id_i))
                eligible[eligible_idx] = 1'b0;
            // Data work may cross several predicted branches, but conditional
            // branches themselves resolve in program order.  This prevents a
            // younger wrong-path branch from redirecting or training the
            // predictor before an older unresolved branch is known correct.
            if ((ENABLE_SPECULATION != 0) &&
                is_early_conditional_branch(payload_q[eligible_idx]) &&
                older_unresolved_conditional)
                eligible[eligible_idx] = 1'b0;
            // Preserve all non-memory ordering and control checks separately
            // from the older-memory check.  The selector may use this view
            // only for the memory operation immediately following the oldest
            // selected memory operation in the same coupled issue bundle.
            mem_pair_eligible[eligible_idx] =
                eligible[eligible_idx] &&
                is_mem(payload_q[eligible_idx]);
            if (is_mem(payload_q[eligible_idx]) &&
                older_live_control &&
                !is_speculative_load_candidate(
                    payload_q[eligible_idx],
                    src1_data_now[eligible_idx])) begin
                eligible[eligible_idx] = 1'b0;
                mem_pair_eligible[eligible_idx] = 1'b0;
            end
            if (is_mem(payload_q[eligible_idx]) && older_unissued_mem)
                eligible[eligible_idx] = 1'b0;

            if (valid_q[eligible_idx] && !issued_q[eligible_idx] &&
                src1_ready_now[eligible_idx] &&
                src2_ready_now[eligible_idx] &&
                (trace_unresolved_conditional_depth[eligible_idx] != 0)) begin
                trace_ready_behind_unresolved_conditional_count =
                    trace_ready_behind_unresolved_conditional_count + 1'b1;
                if (eligible[eligible_idx])
                    trace_eligible_behind_unresolved_conditional_count =
                        trace_eligible_behind_unresolved_conditional_count +
                        1'b1;
            end

            if (valid_q[eligible_idx] && !issued_q[eligible_idx] &&
                src1_ready_now[eligible_idx] &&
                src2_ready_now[eligible_idx] &&
                payload_q[eligible_idx][PAYLOAD_MEM_READ] &&
                !payload_q[eligible_idx][PAYLOAD_MEM_WRITE] &&
                !is_speculative_load_candidate(
                    payload_q[eligible_idx],
                    src1_data_now[eligible_idx]) &&
                older_completed_control &&
                !older_uncompleted_control) begin
                trace_completed_control_load_candidate_count =
                    trace_completed_control_load_candidate_count + 1'b1;
                if (older_live_control)
                    trace_completed_control_load_gate_count =
                        trace_completed_control_load_gate_count + 1'b1;
            end

            if (valid_q[eligible_idx] && !issued_q[eligible_idx] &&
                (!src1_ready_now[eligible_idx] ||
                 !src2_ready_now[eligible_idx]))
                raw_hazard_o[0] = 1'b1;

            if (valid_q[eligible_idx] && !issued_q[eligible_idx]) begin
                if (src1_wakeup_now[eligible_idx] ||
                    src2_wakeup_now[eligible_idx]) begin
                    trace_completion_wakeup_entry_count =
                        trace_completion_wakeup_entry_count + 1'b1;
                    if (eligible[eligible_idx])
                        trace_completion_wakeup_eligible_count =
                            trace_completion_wakeup_eligible_count + 1'b1;
                end
                if (src1_wakeup_now[eligible_idx]) begin
                    trace_completion_wakeup_operand_count =
                        trace_completion_wakeup_operand_count + 1'b1;
                    if (src1_wakeup_port_now[eligible_idx][0])
                        trace_completion_wakeup_ex0_count =
                            trace_completion_wakeup_ex0_count + 1'b1;
                    if (src1_wakeup_port_now[eligible_idx][1])
                        trace_completion_wakeup_ex1_count =
                            trace_completion_wakeup_ex1_count + 1'b1;
                    if (src1_wakeup_port_now[eligible_idx][2])
                        trace_completion_wakeup_mem0_count =
                            trace_completion_wakeup_mem0_count + 1'b1;
                end
                if (src2_wakeup_now[eligible_idx]) begin
                    trace_completion_wakeup_operand_count =
                        trace_completion_wakeup_operand_count + 1'b1;
                    if (src2_wakeup_port_now[eligible_idx][0])
                        trace_completion_wakeup_ex0_count =
                            trace_completion_wakeup_ex0_count + 1'b1;
                    if (src2_wakeup_port_now[eligible_idx][1])
                        trace_completion_wakeup_ex1_count =
                            trace_completion_wakeup_ex1_count + 1'b1;
                    if (src2_wakeup_port_now[eligible_idx][2])
                        trace_completion_wakeup_mem0_count =
                            trace_completion_wakeup_mem0_count + 1'b1;
                end
                if (is_early_conditional_branch(
                        payload_q[eligible_idx])) begin
                    if (src1_wakeup_now[eligible_idx] ||
                        src2_wakeup_now[eligible_idx]) begin
                        trace_branch_wakeup_entry_count =
                            trace_branch_wakeup_entry_count + 1'b1;
                        if (eligible[eligible_idx])
                            trace_branch_wakeup_eligible_count =
                                trace_branch_wakeup_eligible_count + 1'b1;
                    end
                    if (src1_wakeup_now[eligible_idx]) begin
                        trace_branch_wakeup_operand_count =
                            trace_branch_wakeup_operand_count + 1'b1;
                        if (src1_wakeup_port_now[eligible_idx][0])
                            trace_branch_wakeup_ex0_count =
                                trace_branch_wakeup_ex0_count + 1'b1;
                        if (src1_wakeup_port_now[eligible_idx][1])
                            trace_branch_wakeup_ex1_count =
                                trace_branch_wakeup_ex1_count + 1'b1;
                        if (src1_wakeup_port_now[eligible_idx][2])
                            trace_branch_wakeup_mem0_count =
                                trace_branch_wakeup_mem0_count + 1'b1;
                    end
                    if (src2_wakeup_now[eligible_idx]) begin
                        trace_branch_wakeup_operand_count =
                            trace_branch_wakeup_operand_count + 1'b1;
                        if (src2_wakeup_port_now[eligible_idx][0])
                            trace_branch_wakeup_ex0_count =
                                trace_branch_wakeup_ex0_count + 1'b1;
                        if (src2_wakeup_port_now[eligible_idx][1])
                            trace_branch_wakeup_ex1_count =
                                trace_branch_wakeup_ex1_count + 1'b1;
                        if (src2_wakeup_port_now[eligible_idx][2])
                            trace_branch_wakeup_mem0_count =
                                trace_branch_wakeup_mem0_count + 1'b1;
                    end
                end
                trace_unissued_count = trace_unissued_count + 1'b1;
                if (src1_ready_now[eligible_idx] &&
                    src2_ready_now[eligible_idx])
                    trace_operand_ready_count =
                        trace_operand_ready_count + 1'b1;
                else
                    trace_raw_block_count = trace_raw_block_count + 1'b1;
                if (eligible[eligible_idx])
                    trace_eligible_count = trace_eligible_count + 1'b1;
                else if (src1_ready_now[eligible_idx] &&
                         src2_ready_now[eligible_idx]) begin
                    if ((is_mem(payload_q[eligible_idx]) &&
                         (older_unissued_mem ||
                         (older_live_control &&
                           !is_speculative_load_candidate(
                               payload_q[eligible_idx],
                               src1_data_now[eligible_idx])))))
                        trace_mem_order_block_count =
                            trace_mem_order_block_count + 1'b1;
                    else if (older_unissued_hard || older_persistent_hard ||
                             ((ENABLE_SPECULATION != 0) &&
                              is_early_conditional_branch(
                                  payload_q[eligible_idx]) &&
                              older_unresolved_conditional) ||
                             (is_persistent_hard(payload_q[eligible_idx]) &&
                              (id_q[eligible_idx] != next_retire_id_i)))
                        trace_hard_block_count =
                            trace_hard_block_count + 1'b1;
                end
            end
        end
    end

    // Snapshot each unavailable producer-tagged operand by producer phase.
    // A same-cycle completion is intentionally absent here because the
    // readiness view above has already woken that operand.
    always_comb begin
        trace_wait_unissued_load_count = {OPERAND_COUNT_WIDTH{1'b0}};
        trace_wait_unissued_other_count = {OPERAND_COUNT_WIDTH{1'b0}};
        trace_wait_inflight_load_count = {OPERAND_COUNT_WIDTH{1'b0}};
        trace_wait_inflight_other_count = {OPERAND_COUNT_WIDTH{1'b0}};
        trace_wait_completed_count = {OPERAND_COUNT_WIDTH{1'b0}};
        trace_wait_missing_count = {OPERAND_COUNT_WIDTH{1'b0}};
        wait_found = 1'b0;
        for (wait_idx = 0; wait_idx < DEPTH; wait_idx = wait_idx + 1) begin
            if (valid_q[wait_idx] && !issued_q[wait_idx] &&
                src1_producer_valid_q[wait_idx] &&
                !src1_ready_now[wait_idx]) begin
                wait_found = 1'b0;
                for (producer_idx = 0; producer_idx < DEPTH;
                     producer_idx = producer_idx + 1) begin
                    if (valid_q[producer_idx] &&
                        (id_q[producer_idx] == src1_tag_q[wait_idx])) begin
                        wait_found = 1'b1;
                        if (!issued_q[producer_idx]) begin
                            if (payload_q[producer_idx][PAYLOAD_MEM_READ])
                                trace_wait_unissued_load_count =
                                    trace_wait_unissued_load_count + 1'b1;
                            else
                                trace_wait_unissued_other_count =
                                    trace_wait_unissued_other_count + 1'b1;
                        end else if (!result_ready_q[producer_idx]) begin
                            if (payload_q[producer_idx][PAYLOAD_MEM_READ])
                                trace_wait_inflight_load_count =
                                    trace_wait_inflight_load_count + 1'b1;
                            else
                                trace_wait_inflight_other_count =
                                    trace_wait_inflight_other_count + 1'b1;
                        end else begin
                            trace_wait_completed_count =
                                trace_wait_completed_count + 1'b1;
                        end
                    end
                end
                if (!wait_found)
                    trace_wait_missing_count =
                        trace_wait_missing_count + 1'b1;
            end
            if (valid_q[wait_idx] && !issued_q[wait_idx] &&
                src2_producer_valid_q[wait_idx] &&
                !src2_ready_now[wait_idx]) begin
                wait_found = 1'b0;
                for (producer_idx = 0; producer_idx < DEPTH;
                     producer_idx = producer_idx + 1) begin
                    if (valid_q[producer_idx] &&
                        (id_q[producer_idx] == src2_tag_q[wait_idx])) begin
                        wait_found = 1'b1;
                        if (!issued_q[producer_idx]) begin
                            if (payload_q[producer_idx][PAYLOAD_MEM_READ])
                                trace_wait_unissued_load_count =
                                    trace_wait_unissued_load_count + 1'b1;
                            else
                                trace_wait_unissued_other_count =
                                    trace_wait_unissued_other_count + 1'b1;
                        end else if (!result_ready_q[producer_idx]) begin
                            if (payload_q[producer_idx][PAYLOAD_MEM_READ])
                                trace_wait_inflight_load_count =
                                    trace_wait_inflight_load_count + 1'b1;
                            else
                                trace_wait_inflight_other_count =
                                    trace_wait_inflight_other_count + 1'b1;
                        end else begin
                            trace_wait_completed_count =
                                trace_wait_completed_count + 1'b1;
                        end
                    end
                end
                if (!wait_found)
                    trace_wait_missing_count =
                        trace_wait_missing_count + 1'b1;
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
    reg select_ex0_admit;
    reg select_ex1_admit;
    reg select_mem_admit;
    reg select_mem2_admit;
    integer select_offset;
    integer select_slot;
    integer selected_idx;
    integer selected_mem_pipe;
    integer selected_mem2_pipe;
    integer selected_age_rank;
    integer select_ex0_rank;
    integer select_ex1_rank;
    integer select_mem_rank;
    integer select_mem2_rank;
    reg past_selected_mem;
    reg checked_next_mem;
    reg [2:0] trace_pipe_uses_rs1;
    reg [2:0] trace_pipe_uses_rs2;

    always_comb begin
        select_ex0_valid = 1'b0;
        select_ex1_valid = 1'b0;
        select_mem_valid = 1'b0;
        select_mem2_valid = 1'b0;
        select_ex0 = {RETIRE_SLOT_WIDTH{1'b0}};
        select_ex1 = {RETIRE_SLOT_WIDTH{1'b0}};
        select_mem = {RETIRE_SLOT_WIDTH{1'b0}};
        select_mem2 = {RETIRE_SLOT_WIDTH{1'b0}};
        select_ex0_admit = 1'b0;
        select_ex1_admit = 1'b0;
        select_mem_admit = 1'b0;
        select_mem2_admit = 1'b0;
        selected_idx = 0;
        selected_mem_pipe = `OPENRV64_EXEC_PIPE_MEM0;
        selected_mem2_pipe = `OPENRV64_EXEC_PIPE_MEM0;
        past_selected_mem = 1'b0;
        checked_next_mem = 1'b0;
        select_ex0_rank = 0;
        select_ex1_rank = 0;
        select_mem_rank = 0;
        select_mem2_rank = 0;

        // Reserve fixed-capability work first, in age order.
        for (select_offset = 0; select_offset < DEPTH;
             select_offset = select_offset + 1) begin
            select_slot = next_retire_slot_i + select_offset;
            if (select_slot >= DEPTH)
                select_slot = select_slot - DEPTH;
            if (!select_ex0_valid && eligible[select_slot] &&
                is_fixed_ex0(payload_q[select_slot])) begin
                select_ex0_valid = 1'b1;
                select_ex0 = select_slot[RETIRE_SLOT_WIDTH-1:0];
            end
            if (!select_ex1_valid && eligible[select_slot] &&
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
                        (is_mem1_op(payload_q[select_slot]) !=
                         is_mem1_op(payload_q[select_mem]))) begin
                        select_mem2_valid = 1'b1;
                        select_mem2 =
                            select_slot[RETIRE_SLOT_WIDTH-1:0];
                    end
                end
            end
        end

        // Ordinary loads route to MEM0; stores and every RV64A operation route
        // to MEM1.  Route both payloads before consulting ready so execution
        // capability checks cannot create a ready/fire/payload loop.
        if (select_mem_valid &&
            is_mem1_op(payload_q[select_mem]))
            selected_mem_pipe = `OPENRV64_EXEC_PIPE_MEM1;
        if (select_mem2_valid &&
            is_mem1_op(payload_q[select_mem2]))
            selected_mem2_pipe = `OPENRV64_EXEC_PIPE_MEM1;

        // The banked register-load interface has four operand read ports and
        // therefore accepts at most two two-source instructions per cycle.
        // Rank the already capability-selected packets by dynamic age rather
        // than by physical pipe so a continuously busy ALU cannot starve an
        // older memory operation.  The ordinary window keeps its four-packet
        // behavior through the default parameter value.
        selected_age_rank = 0;
        if (select_ex0_valid) begin
            selected_age_rank = 0;
            if (select_ex1_valid &&
                id_is_younger(id_q[select_ex0], id_q[select_ex1]))
                selected_age_rank = selected_age_rank + 1;
            if (select_mem_valid &&
                id_is_younger(id_q[select_ex0], id_q[select_mem]))
                selected_age_rank = selected_age_rank + 1;
            if (select_mem2_valid &&
                id_is_younger(id_q[select_ex0], id_q[select_mem2]))
                selected_age_rank = selected_age_rank + 1;
            select_ex0_rank = selected_age_rank;
            select_ex0_admit = selected_age_rank < MAX_ISSUE_LANES;
        end
        if (select_ex1_valid) begin
            selected_age_rank = 0;
            if (select_ex0_valid &&
                id_is_younger(id_q[select_ex1], id_q[select_ex0]))
                selected_age_rank = selected_age_rank + 1;
            if (select_mem_valid &&
                id_is_younger(id_q[select_ex1], id_q[select_mem]))
                selected_age_rank = selected_age_rank + 1;
            if (select_mem2_valid &&
                id_is_younger(id_q[select_ex1], id_q[select_mem2]))
                selected_age_rank = selected_age_rank + 1;
            select_ex1_rank = selected_age_rank;
            select_ex1_admit = selected_age_rank < MAX_ISSUE_LANES;
        end
        if (select_mem_valid) begin
            selected_age_rank = 0;
            if (select_ex0_valid &&
                id_is_younger(id_q[select_mem], id_q[select_ex0]))
                selected_age_rank = selected_age_rank + 1;
            if (select_ex1_valid &&
                id_is_younger(id_q[select_mem], id_q[select_ex1]))
                selected_age_rank = selected_age_rank + 1;
            if (select_mem2_valid &&
                id_is_younger(id_q[select_mem], id_q[select_mem2]))
                selected_age_rank = selected_age_rank + 1;
            select_mem_rank = selected_age_rank;
            select_mem_admit = selected_age_rank < MAX_ISSUE_LANES;
        end
        if (select_mem2_valid) begin
            selected_age_rank = 0;
            if (select_ex0_valid &&
                id_is_younger(id_q[select_mem2], id_q[select_ex0]))
                selected_age_rank = selected_age_rank + 1;
            if (select_ex1_valid &&
                id_is_younger(id_q[select_mem2], id_q[select_ex1]))
                selected_age_rank = selected_age_rank + 1;
            if (select_mem_valid &&
                id_is_younger(id_q[select_mem2], id_q[select_mem]))
                selected_age_rank = selected_age_rank + 1;
            select_mem2_rank = selected_age_rank;
            select_mem2_admit = selected_age_rank < MAX_ISSUE_LANES;
        end

        // A deferred-read control does not resolve on the selector edge.  Do
        // not let younger work enter the register-load stage beside it.  If a
        // control is not the oldest selected packet, defer that control; if it
        // is oldest, make it the sole accepted packet.  This makes a redirect
        // able to discard the stage without losing an older packet that the
        // window has already marked issued.
        if (DEFER_GPR_READ != 0) begin
            if (select_ex0_valid && is_hard(payload_q[select_ex0])) begin
                if (select_ex0_rank == 0) begin
                    select_ex1_admit = 1'b0;
                    select_mem_admit = 1'b0;
                    select_mem2_admit = 1'b0;
                end else begin
                    select_ex0_admit = 1'b0;
                end
            end
            if (select_ex1_valid && is_hard(payload_q[select_ex1])) begin
                if (select_ex1_rank == 0) begin
                    select_ex0_admit = 1'b0;
                    select_mem_admit = 1'b0;
                    select_mem2_admit = 1'b0;
                end else begin
                    select_ex1_admit = 1'b0;
                end
            end
            if (select_mem_valid && is_hard(payload_q[select_mem])) begin
                if (select_mem_rank == 0) begin
                    select_ex0_admit = 1'b0;
                    select_ex1_admit = 1'b0;
                    select_mem2_admit = 1'b0;
                end else begin
                    select_mem_admit = 1'b0;
                end
            end
            if (select_mem2_valid && is_hard(payload_q[select_mem2])) begin
                if (select_mem2_rank == 0) begin
                    select_ex0_admit = 1'b0;
                    select_ex1_admit = 1'b0;
                    select_mem_admit = 1'b0;
                end else begin
                    select_mem2_admit = 1'b0;
                end
            end
        end

        pipe_id_o =
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_INSTR_ID_WIDTH{1'b0}};
        pipe_slot_o =
            {`OPENRV64_EXEC_PIPE_COUNT*RETIRE_SLOT_WIDTH{1'b0}};
        pipe_payload_o =
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
        pipe_uses_rs1_o = {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        pipe_uses_rs2_o = {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        pipe_src1_producer_valid_o =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        pipe_src1_producer_id_o =
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_INSTR_ID_WIDTH{1'b0}};
        pipe_src2_producer_valid_o =
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        pipe_src2_producer_id_o =
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_INSTR_ID_WIDTH{1'b0}};
        trace_pipe_uses_rs1 = 3'b000;
        trace_pipe_uses_rs2 = 3'b000;

        if (select_ex0_valid) begin
            selected_idx = select_ex0;
            pipe_id_o[
                0*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = id_q[selected_idx];
            pipe_slot_o[0*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] =
                select_ex0;
            pipe_payload_o[
                0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] = payload_q[selected_idx];
            pipe_payload_o[
                0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + PAYLOAD_RS1_DATA +:
                `RV64_XLEN] = src1_data_now[selected_idx];
            pipe_payload_o[
                0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + PAYLOAD_RS2_DATA +:
                `RV64_XLEN] = src2_data_now[selected_idx];
            pipe_src1_producer_valid_o[0] =
                src1_producer_valid_q[selected_idx];
            pipe_src1_producer_id_o[
                0*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src1_tag_q[selected_idx];
            pipe_src2_producer_valid_o[0] =
                src2_producer_valid_q[selected_idx];
            pipe_src2_producer_id_o[
                0*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src2_tag_q[selected_idx];
            trace_pipe_uses_rs1[0] = uses_rs1_q[selected_idx];
            trace_pipe_uses_rs2[0] = uses_rs2_q[selected_idx];
            pipe_uses_rs1_o[0] = uses_rs1_q[selected_idx];
            pipe_uses_rs2_o[0] = uses_rs2_q[selected_idx];
        end
        if (select_ex1_valid) begin
            selected_idx = select_ex1;
            pipe_id_o[
                1*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = id_q[selected_idx];
            pipe_slot_o[1*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH] =
                select_ex1;
            pipe_payload_o[
                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] = payload_q[selected_idx];
            pipe_payload_o[
                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + PAYLOAD_RS1_DATA +:
                `RV64_XLEN] = src1_data_now[selected_idx];
            pipe_payload_o[
                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + PAYLOAD_RS2_DATA +:
                `RV64_XLEN] = src2_data_now[selected_idx];
            pipe_src1_producer_valid_o[1] =
                src1_producer_valid_q[selected_idx];
            pipe_src1_producer_id_o[
                1*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src1_tag_q[selected_idx];
            pipe_src2_producer_valid_o[1] =
                src2_producer_valid_q[selected_idx];
            pipe_src2_producer_id_o[
                1*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src2_tag_q[selected_idx];
            trace_pipe_uses_rs1[1] = uses_rs1_q[selected_idx];
            trace_pipe_uses_rs2[1] = uses_rs2_q[selected_idx];
            pipe_uses_rs1_o[1] = uses_rs1_q[selected_idx];
            pipe_uses_rs2_o[1] = uses_rs2_q[selected_idx];
        end
        if (select_mem_valid) begin
            pipe_id_o[
                selected_mem_pipe*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = id_q[select_mem];
            pipe_slot_o[
                selected_mem_pipe*RETIRE_SLOT_WIDTH +:
                RETIRE_SLOT_WIDTH] = select_mem;
            pipe_payload_o[
                selected_mem_pipe*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] = payload_q[select_mem];
            pipe_payload_o[
                selected_mem_pipe*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                PAYLOAD_RS1_DATA +: `RV64_XLEN] =
                src1_data_now[select_mem];
            pipe_payload_o[
                selected_mem_pipe*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                PAYLOAD_RS2_DATA +: `RV64_XLEN] =
                src2_data_now[select_mem];
            pipe_src1_producer_valid_o[selected_mem_pipe] =
                src1_producer_valid_q[select_mem];
            pipe_src1_producer_id_o[
                selected_mem_pipe*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src1_tag_q[select_mem];
            pipe_src2_producer_valid_o[selected_mem_pipe] =
                src2_producer_valid_q[select_mem];
            pipe_src2_producer_id_o[
                selected_mem_pipe*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src2_tag_q[select_mem];
            trace_pipe_uses_rs1[2] = uses_rs1_q[select_mem];
            trace_pipe_uses_rs2[2] = uses_rs2_q[select_mem];
            pipe_uses_rs1_o[selected_mem_pipe] = uses_rs1_q[select_mem];
            pipe_uses_rs2_o[selected_mem_pipe] = uses_rs2_q[select_mem];
        end
        if (select_mem2_valid) begin
            pipe_id_o[
                selected_mem2_pipe*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = id_q[select_mem2];
            pipe_slot_o[
                selected_mem2_pipe*RETIRE_SLOT_WIDTH +:
                RETIRE_SLOT_WIDTH] = select_mem2;
            pipe_payload_o[
                selected_mem2_pipe*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] = payload_q[select_mem2];
            pipe_payload_o[
                selected_mem2_pipe*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                PAYLOAD_RS1_DATA +: `RV64_XLEN] =
                src1_data_now[select_mem2];
            pipe_payload_o[
                selected_mem2_pipe*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                PAYLOAD_RS2_DATA +: `RV64_XLEN] =
                src2_data_now[select_mem2];
            pipe_src1_producer_valid_o[selected_mem2_pipe] =
                src1_producer_valid_q[select_mem2];
            pipe_src1_producer_id_o[
                selected_mem2_pipe*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src1_tag_q[select_mem2];
            pipe_src2_producer_valid_o[selected_mem2_pipe] =
                src2_producer_valid_q[select_mem2];
            pipe_src2_producer_id_o[
                selected_mem2_pipe*`OPENRV64_INSTR_ID_WIDTH +:
                `OPENRV64_INSTR_ID_WIDTH] = src2_tag_q[select_mem2];
            trace_pipe_uses_rs1[2] =
                uses_rs1_q[select_mem] | uses_rs1_q[select_mem2];
            trace_pipe_uses_rs2[2] =
                uses_rs2_q[select_mem] | uses_rs2_q[select_mem2];
            pipe_uses_rs1_o[selected_mem2_pipe] = uses_rs1_q[select_mem2];
            pipe_uses_rs2_o[selected_mem2_pipe] = uses_rs2_q[select_mem2];
        end
    end

    // Keep valid generation in a separate process from payload routing.
    // Execution readiness depends on the routed operation's capability; a
    // combined ready -> valid -> payload process forms a false combinational
    // loop in synthesis even though the payload selection itself is stable.
    always @* begin
        pipe_candidate_valid_o = {
            2'b00,
            select_ex1_admit,
            select_ex0_admit
        };
        pipe_age_rank_o =
            {`OPENRV64_EXEC_PIPE_COUNT*2{1'b0}};
        if (select_ex0_admit)
            pipe_age_rank_o[0*2 +: 2] = select_ex0_rank[1:0];
        if (select_ex1_admit)
            pipe_age_rank_o[1*2 +: 2] = select_ex1_rank[1:0];
        if (select_mem_admit)
            begin
                pipe_candidate_valid_o[selected_mem_pipe] = 1'b1;
                pipe_age_rank_o[selected_mem_pipe*2 +: 2] =
                    select_mem_rank[1:0];
            end
        if (select_mem2_admit && select_mem_admit) begin
            pipe_candidate_valid_o[selected_mem2_pipe] = 1'b1;
            pipe_age_rank_o[selected_mem2_pipe*2 +: 2] =
                select_mem2_rank[1:0];
        end

        if (recovery_pending_q) begin
            pipe_candidate_valid_o =
                {`OPENRV64_EXEC_PIPE_COUNT{1'b0}};
        end else if (selective_recovery_request) begin
            // EX1 may be the branch whose accepted issue is producing the raw
            // redirect.  Cancelling that handshake makes redirect and valid
            // combinationally negate one another.  Preserve only that exact
            // resolving branch; inhibit every unrelated issue immediately.
            pipe_candidate_valid_o[0] = 1'b0;
            pipe_candidate_valid_o[2] = 1'b0;
            pipe_candidate_valid_o[3] = 1'b0;
            if (!select_ex1_valid ||
                (id_q[select_ex1] != squash_id_i)) begin
                pipe_candidate_valid_o[1] = 1'b0;
            end
        end
    end

    // Candidate selection is ready-independent.  Keep the actual handshake
    // valid in a separate process because the secondary-memory contract reads
    // ready.  Combining these outputs in one process makes candidate valid
    // appear ready-dependent and closes a false RF request/ack loop.
    always @* begin
        pipe_valid_o = pipe_candidate_valid_o;
        // Coupled acceptance is required: allowing the younger operation to
        // enter its queue alone would hide the still-unissued older operation
        // from the cross-queue memory-order gate.
        if (select_mem2_admit && select_mem_admit &&
            !(pipe_ready_i[selected_mem_pipe] &&
              pipe_ready_i[selected_mem2_pipe]))
            pipe_valid_o[selected_mem2_pipe] = 1'b0;
    end

    wire issue_ex0 = pipe_valid_o[0] && pipe_ready_i[0];
    wire issue_ex1 = pipe_valid_o[1] && pipe_ready_i[1];
    wire issue_mem0 = pipe_valid_o[2] && pipe_ready_i[2];
    wire issue_mem1 = pipe_valid_o[3] && pipe_ready_i[3];
    wire issue_mem_primary = select_mem_valid &&
        (is_mem1_op(payload_q[select_mem]) ? issue_mem1 : issue_mem0);
    wire issue_mem_secondary = select_mem2_valid &&
        (is_mem1_op(payload_q[select_mem2]) ? issue_mem1 : issue_mem0);

    // A wakeup is genuine producer-to-branch forwarding: src*_data_now is
    // patched directly from the matching completion payload.  Count both all
    // resident branch wakeups and the subset whose branch leaves the scheduler
    // on that same edge.  In banked mode the latter is admission to regload,
    // not yet the EX1 execution edge.
    always_comb begin
        trace_branch_wakeup_selected_count = {COUNT_WIDTH{1'b0}};
        trace_branch_wakeup_offer_count = {COUNT_WIDTH{1'b0}};
        trace_branch_wakeup_release_count = {COUNT_WIDTH{1'b0}};
        trace_branch_wakeup_release_operand_count =
            {OPERAND_COUNT_WIDTH{1'b0}};
        trace_branch_wakeup_release_ex0_count =
            {OPERAND_COUNT_WIDTH{1'b0}};
        trace_branch_wakeup_release_ex1_count =
            {OPERAND_COUNT_WIDTH{1'b0}};
        trace_branch_wakeup_release_mem0_count =
            {OPERAND_COUNT_WIDTH{1'b0}};
        if (select_ex1_valid &&
            is_early_conditional_branch(payload_q[select_ex1]) &&
            (src1_wakeup_now[select_ex1] ||
             src2_wakeup_now[select_ex1])) begin
            trace_branch_wakeup_selected_count = 1'b1;
            if (pipe_valid_o[1])
                trace_branch_wakeup_offer_count = 1'b1;
            if (issue_ex1)
                trace_branch_wakeup_release_count = 1'b1;
        end
        if (issue_ex1 && select_ex1_valid &&
            is_early_conditional_branch(payload_q[select_ex1]) &&
            (src1_wakeup_now[select_ex1] ||
             src2_wakeup_now[select_ex1])) begin
            if (src1_wakeup_now[select_ex1]) begin
                trace_branch_wakeup_release_operand_count =
                    trace_branch_wakeup_release_operand_count + 1'b1;
                if (src1_wakeup_port_now[select_ex1][0])
                    trace_branch_wakeup_release_ex0_count =
                        trace_branch_wakeup_release_ex0_count + 1'b1;
                if (src1_wakeup_port_now[select_ex1][1])
                    trace_branch_wakeup_release_ex1_count =
                        trace_branch_wakeup_release_ex1_count + 1'b1;
                if (src1_wakeup_port_now[select_ex1][2])
                    trace_branch_wakeup_release_mem0_count =
                        trace_branch_wakeup_release_mem0_count + 1'b1;
            end
            if (src2_wakeup_now[select_ex1]) begin
                trace_branch_wakeup_release_operand_count =
                    trace_branch_wakeup_release_operand_count + 1'b1;
                if (src2_wakeup_port_now[select_ex1][0])
                    trace_branch_wakeup_release_ex0_count =
                        trace_branch_wakeup_release_ex0_count + 1'b1;
                if (src2_wakeup_port_now[select_ex1][1])
                    trace_branch_wakeup_release_ex1_count =
                        trace_branch_wakeup_release_ex1_count + 1'b1;
                if (src2_wakeup_port_now[select_ex1][2])
                    trace_branch_wakeup_release_mem0_count =
                        trace_branch_wakeup_release_mem0_count + 1'b1;
            end
        end
    end

    // Count scheduler-release handshakes whose selected resident entry is
    // younger than an unresolved conditional branch.  With deferred banked
    // reads this handshake transfers ownership to the register-load stage;
    // it is not necessarily an execution handshake.  Resolution snapshots
    // below separately count work that has actually completed.  The crossing
    // total counts relationships, so one release crossing two branches
    // contributes one event and two crossings.
    always_comb begin
        trace_branch_spec_issue_count = {COUNT_WIDTH{1'b0}};
        trace_branch_spec_issue_alu_count = {COUNT_WIDTH{1'b0}};
        trace_branch_spec_issue_load_count = {COUNT_WIDTH{1'b0}};
        trace_branch_spec_issue_store_count = {COUNT_WIDTH{1'b0}};
        trace_branch_spec_issue_control_count = {COUNT_WIDTH{1'b0}};
        trace_branch_spec_issue_crossing_count =
            {SPEC_CROSS_COUNT_WIDTH{1'b0}};

        if (issue_ex0 &&
            (trace_unresolved_conditional_depth[select_ex0] != 0)) begin
            trace_branch_spec_issue_count =
                trace_branch_spec_issue_count + 1'b1;
            trace_branch_spec_issue_crossing_count =
                trace_branch_spec_issue_crossing_count +
                trace_unresolved_conditional_depth[select_ex0];
            if (is_hard(payload_q[select_ex0]))
                trace_branch_spec_issue_control_count =
                    trace_branch_spec_issue_control_count + 1'b1;
            else
                trace_branch_spec_issue_alu_count =
                    trace_branch_spec_issue_alu_count + 1'b1;
        end
        if (issue_ex1 &&
            (trace_unresolved_conditional_depth[select_ex1] != 0)) begin
            trace_branch_spec_issue_count =
                trace_branch_spec_issue_count + 1'b1;
            trace_branch_spec_issue_crossing_count =
                trace_branch_spec_issue_crossing_count +
                trace_unresolved_conditional_depth[select_ex1];
            if (is_hard(payload_q[select_ex1]))
                trace_branch_spec_issue_control_count =
                    trace_branch_spec_issue_control_count + 1'b1;
            else
                trace_branch_spec_issue_alu_count =
                    trace_branch_spec_issue_alu_count + 1'b1;
        end
        if (issue_mem_primary &&
            (trace_unresolved_conditional_depth[select_mem] != 0)) begin
            trace_branch_spec_issue_count =
                trace_branch_spec_issue_count + 1'b1;
            trace_branch_spec_issue_crossing_count =
                trace_branch_spec_issue_crossing_count +
                trace_unresolved_conditional_depth[select_mem];
            if (payload_q[select_mem][PAYLOAD_MEM_WRITE])
                trace_branch_spec_issue_store_count =
                    trace_branch_spec_issue_store_count + 1'b1;
            else
                trace_branch_spec_issue_load_count =
                    trace_branch_spec_issue_load_count + 1'b1;
        end
        if (issue_mem_secondary &&
            (trace_unresolved_conditional_depth[select_mem2] != 0)) begin
            trace_branch_spec_issue_count =
                trace_branch_spec_issue_count + 1'b1;
            trace_branch_spec_issue_crossing_count =
                trace_branch_spec_issue_crossing_count +
                trace_unresolved_conditional_depth[select_mem2];
            if (payload_q[select_mem2][PAYLOAD_MEM_WRITE])
                trace_branch_spec_issue_store_count =
                    trace_branch_spec_issue_store_count + 1'b1;
            else
                trace_branch_spec_issue_load_count =
                    trace_branch_spec_issue_load_count + 1'b1;
        end
    end

    // Snapshot the work exposed to each resolving conditional.  Issued
    // younger entries are the speculative work preserved on a correct
    // prediction or discarded on a correction.  "Completed" deliberately
    // means the result was already resident before this resolve pulse; a
    // simultaneous younger completion may be counted one cycle late and is
    // therefore excluded from this conservative snapshot.
    integer trace_resolve_idx;
    always_comb begin
        trace_conditional_resolve_valid = conditional_resolve_valid_i &&
            valid_q[conditional_resolve_slot_i] &&
            (id_q[conditional_resolve_slot_i] ==
             conditional_resolve_id_i);
        trace_conditional_resolve_predicted_taken = 1'b0;
        trace_resolve_younger_valid_count = {COUNT_WIDTH{1'b0}};
        trace_resolve_younger_issued_count = {COUNT_WIDTH{1'b0}};
        trace_resolve_younger_completed_count = {COUNT_WIDTH{1'b0}};
        if (trace_conditional_resolve_valid) begin
            trace_conditional_resolve_predicted_taken =
                payload_q[conditional_resolve_slot_i]
                    [PAYLOAD_PREDICTED_TAKEN];
            for (trace_resolve_idx = 0; trace_resolve_idx < DEPTH;
                 trace_resolve_idx = trace_resolve_idx + 1) begin
                if (valid_q[trace_resolve_idx] &&
                    id_is_younger(id_q[trace_resolve_idx],
                                  conditional_resolve_id_i)) begin
                    trace_resolve_younger_valid_count =
                        trace_resolve_younger_valid_count + 1'b1;
                    if (issued_q[trace_resolve_idx])
                        trace_resolve_younger_issued_count =
                            trace_resolve_younger_issued_count + 1'b1;
                    if (result_ready_q[trace_resolve_idx])
                        trace_resolve_younger_completed_count =
                            trace_resolve_younger_completed_count + 1'b1;
                end
            end
        end
    end

    integer entry_idx;
    integer completion_port;
    integer retire_lane;
    integer allocation_lane;
    reg [RETIRE_SLOT_WIDTH-1:0] update_slot;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] update_id;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] update_completion;
    reg [31:0] survivor_owner_valid;
    reg [31:0] survivor_owner_ready;
    reg [`OPENRV64_INSTR_ID_WIDTH-1:0] survivor_owner_id [0:31];
    reg [`RV64_XLEN-1:0] survivor_owner_data [0:31];
    reg [COUNT_WIDTH-1:0] survivor_count;
    reg survivor_retiring;
    reg recover_retiring;
    reg survivor_result_ready;
    reg [`RV64_XLEN-1:0] survivor_result_data;
    reg [`RV64_REG_ADDR_WIDTH-1:0] survivor_rd;
    reg [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        survivor_completion;
    integer survivor_idx;
    integer survivor_lane;
    integer survivor_port;

    // Recovery rebuilds the rename/ownership view from the entries retained
    // through the mispredicted branch.  Per-entry completion data is kept for
    // exactly this purpose: a squashed younger WAW must reveal the older live
    // producer rather than the stale architectural GPR value.
    always @* begin
        survivor_owner_valid = 32'd0;
        survivor_owner_ready = 32'd0;
        survivor_count = {COUNT_WIDTH{1'b0}};
        for (owner_idx = 0; owner_idx < 32; owner_idx = owner_idx + 1) begin
            survivor_owner_id[owner_idx] =
                {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
            survivor_owner_data[owner_idx] = {`RV64_XLEN{1'b0}};
        end
        for (survivor_idx = 0; survivor_idx < DEPTH;
             survivor_idx = survivor_idx + 1) begin
            survivor_retiring = 1'b0;
            for (survivor_lane = 0; survivor_lane < 3;
                 survivor_lane = survivor_lane + 1) begin
                if (retire_valid_i[survivor_lane] &&
                    (retire_id_i[
                        survivor_lane*`OPENRV64_INSTR_ID_WIDTH +:
                        `OPENRV64_INSTR_ID_WIDTH] ==
                     id_q[survivor_idx]))
                    survivor_retiring = 1'b1;
            end
            if (valid_q[survivor_idx] && !survivor_retiring &&
                !id_is_younger(id_q[survivor_idx], recovery_cut_id_q)) begin
                survivor_count = survivor_count + 1'b1;
                survivor_rd = payload_q[survivor_idx][
                    PAYLOAD_RD +: `RV64_REG_ADDR_WIDTH];
                survivor_result_ready = result_ready_q[survivor_idx];
                survivor_result_data = result_data_q[survivor_idx];
                for (survivor_port = 0; survivor_port < 3;
                     survivor_port = survivor_port + 1) begin
                    survivor_completion = completion_payload_i[
                        survivor_port*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                        `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
                    if (completion_valid_i[survivor_port] &&
                        completion_safe(survivor_completion) &&
                        (completion_id_i[
                            survivor_port*`OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH] ==
                         id_q[survivor_idx])) begin
                        survivor_result_ready = 1'b1;
                        survivor_result_data = survivor_completion[
                            `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
                    end
                end
                if (payload_q[survivor_idx][PAYLOAD_REG_WRITE] &&
                    (survivor_rd != `RV64_REG_X0) &&
                    (!survivor_owner_valid[survivor_rd] ||
                     id_is_younger(
                         id_q[survivor_idx],
                         survivor_owner_id[survivor_rd]))) begin
                    survivor_owner_valid[survivor_rd] = 1'b1;
                    survivor_owner_ready[survivor_rd] =
                        survivor_result_ready;
                    survivor_owner_id[survivor_rd] = id_q[survivor_idx];
                    survivor_owner_data[survivor_rd] =
                        survivor_result_data;
                end
            end
        end
        survivor_owner_valid[`RV64_REG_X0] = 1'b0;
        survivor_owner_ready[`RV64_REG_X0] = 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count_q <= {COUNT_WIDTH{1'b0}};
            owner_valid_q <= 32'd0;
            owner_ready_q <= 32'd0;
            for (owner_idx = 0; owner_idx < 32; owner_idx = owner_idx + 1) begin
                owner_id_q[owner_idx] <=
                    {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
                owner_data_q[owner_idx] <= {`RV64_XLEN{1'b0}};
            end
            for (entry_idx = 0; entry_idx < DEPTH;
                 entry_idx = entry_idx + 1) begin
                valid_q[entry_idx] <= 1'b0;
                issued_q[entry_idx] <= 1'b0;
                id_q[entry_idx] <=
                    {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
                payload_q[entry_idx] <=
                    {`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
                uses_rs1_q[entry_idx] <= 1'b0;
                uses_rs2_q[entry_idx] <= 1'b0;
                src1_ready_q[entry_idx] <= 1'b0;
                src2_ready_q[entry_idx] <= 1'b0;
                src1_producer_valid_q[entry_idx] <= 1'b0;
                src2_producer_valid_q[entry_idx] <= 1'b0;
                src1_tag_q[entry_idx] <=
                    {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
                src2_tag_q[entry_idx] <=
                    {`OPENRV64_INSTR_ID_WIDTH{1'b0}};
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
            end
        end else if (selective_recovery_apply) begin
            count_q <= survivor_count;
            owner_valid_q <= survivor_owner_valid;
            owner_ready_q <= survivor_owner_ready;
            for (owner_idx = 0; owner_idx < 32;
                 owner_idx = owner_idx + 1) begin
                owner_id_q[owner_idx] <= survivor_owner_id[owner_idx];
                owner_data_q[owner_idx] <= survivor_owner_data[owner_idx];
            end

            // Preserve the resolving branch and all older work.  Any younger
            // completion already in flight is harmless because IDs are never
            // reused after recovery; its retirement-slot write will miss.
            for (entry_idx = 0; entry_idx < DEPTH;
                 entry_idx = entry_idx + 1) begin
                recover_retiring = 1'b0;
                for (retire_lane = 0; retire_lane < 3;
                     retire_lane = retire_lane + 1) begin
                    if (retire_valid_i[retire_lane] &&
                        (retire_id_i[
                            retire_lane*`OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH] ==
                         id_q[entry_idx]))
                        recover_retiring = 1'b1;
                end
                if (!valid_q[entry_idx] || recover_retiring ||
                    id_is_younger(id_q[entry_idx], recovery_cut_id_q)) begin
                    valid_q[entry_idx] <= 1'b0;
                    issued_q[entry_idx] <= 1'b0;
                    result_ready_q[entry_idx] <= 1'b0;
                end else begin
                    for (completion_port = 0; completion_port < 3;
                         completion_port = completion_port + 1) begin
                        update_id = completion_id_i[
                            completion_port*`OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH];
                        update_completion = completion_payload_i[
                            completion_port*
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
                        if (completion_valid_i[completion_port] &&
                            completion_safe(update_completion) &&
                            (update_id == id_q[entry_idx])) begin
                            result_ready_q[entry_idx] <= 1'b1;
                            result_data_q[entry_idx] <= update_completion[
                                `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
                        end
                        if (completion_valid_i[completion_port] &&
                            completion_safe(update_completion) &&
                            !src1_ready_q[entry_idx] &&
                            (src1_tag_q[entry_idx] == update_id)) begin
                            src1_ready_q[entry_idx] <= 1'b1;
                            payload_q[entry_idx][
                                PAYLOAD_RS1_DATA +: `RV64_XLEN] <=
                                update_completion[
                                    `OPENRV64_COMPLETE_DATA_LSB +:
                                    `RV64_XLEN];
                        end
                        if (completion_valid_i[completion_port] &&
                            completion_safe(update_completion) &&
                            !src2_ready_q[entry_idx] &&
                            (src2_tag_q[entry_idx] == update_id)) begin
                            src2_ready_q[entry_idx] <= 1'b1;
                            payload_q[entry_idx][
                                PAYLOAD_RS2_DATA +: `RV64_XLEN] <=
                                update_completion[
                                    `OPENRV64_COMPLETE_DATA_LSB +:
                                    `RV64_XLEN];
                        end
                    end
                end
            end

            // Conditional controls do not write a GPR, so their EX1 resolve
            // event is queued separately from the value-completion bus.  The
            // resolving branch survives selective recovery and becomes safe
            // for younger correct-path loads immediately after this edge.
            if (conditional_resolve_valid_i &&
                valid_q[conditional_resolve_slot_i] &&
                (id_q[conditional_resolve_slot_i] ==
                 conditional_resolve_id_i))
                result_ready_q[conditional_resolve_slot_i] <= 1'b1;

            if (issue_ex0 &&
                !id_is_younger(id_q[select_ex0], recovery_cut_id_q))
                issued_q[select_ex0] <= 1'b1;
            if (issue_ex1 &&
                !id_is_younger(id_q[select_ex1], recovery_cut_id_q))
                issued_q[select_ex1] <= 1'b1;
            if (issue_mem_primary &&
                !id_is_younger(id_q[select_mem], recovery_cut_id_q))
                issued_q[select_mem] <= 1'b1;
            if (issue_mem_secondary &&
                !id_is_younger(id_q[select_mem2], recovery_cut_id_q))
                issued_q[select_mem2] <= 1'b1;
        end else begin
            count_q <= count_q + decode_count - retire_count;
            owner_valid_q <= owner_valid_view;
            owner_ready_q <= owner_ready_view;
            for (owner_idx = 0; owner_idx < 32; owner_idx = owner_idx + 1) begin
                owner_id_q[owner_idx] <= owner_id_view[owner_idx];
                owner_data_q[owner_idx] <= owner_data_view[owner_idx];
            end

            // Persist completion wakeups so a one-cycle completion broadcast
            // is sufficient no matter how long the consumer waits to issue.
            for (entry_idx = 0; entry_idx < DEPTH;
                 entry_idx = entry_idx + 1) begin
                if (valid_q[entry_idx]) begin
                    for (completion_port = 0; completion_port < 3;
                         completion_port = completion_port + 1) begin
                        update_id = completion_id_i[
                            completion_port*`OPENRV64_INSTR_ID_WIDTH +:
                            `OPENRV64_INSTR_ID_WIDTH];
                        update_completion = completion_payload_i[
                            completion_port*
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                            `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH];
                        if (completion_valid_i[completion_port] &&
                            completion_safe(update_completion) &&
                            (id_q[entry_idx] == update_id)) begin
                            result_ready_q[entry_idx] <= 1'b1;
                            result_data_q[entry_idx] <= update_completion[
                                `OPENRV64_COMPLETE_DATA_LSB +: `RV64_XLEN];
                        end
                        if (completion_valid_i[completion_port] &&
                            completion_safe(update_completion) &&
                            !src1_ready_q[entry_idx] &&
                            (src1_tag_q[entry_idx] == update_id)) begin
                            src1_ready_q[entry_idx] <= 1'b1;
                            payload_q[entry_idx][
                                PAYLOAD_RS1_DATA +: `RV64_XLEN] <=
                                update_completion[
                                    `OPENRV64_COMPLETE_DATA_LSB +:
                                    `RV64_XLEN];
                        end
                        if (completion_valid_i[completion_port] &&
                            completion_safe(update_completion) &&
                            !src2_ready_q[entry_idx] &&
                            (src2_tag_q[entry_idx] == update_id)) begin
                            src2_ready_q[entry_idx] <= 1'b1;
                            payload_q[entry_idx][
                                PAYLOAD_RS2_DATA +: `RV64_XLEN] <=
                                update_completion[
                                    `OPENRV64_COMPLETE_DATA_LSB +:
                                    `RV64_XLEN];
                        end
                    end
                end
            end

            // EX1 publishes this on the branch-resolving issue edge.  Latch
            // it in the resident window entry so the one-cycle resolve pulse
            // remains visible until retirement.
            if (conditional_resolve_valid_i &&
                valid_q[conditional_resolve_slot_i] &&
                (id_q[conditional_resolve_slot_i] ==
                 conditional_resolve_id_i))
                result_ready_q[conditional_resolve_slot_i] <= 1'b1;

            if (issue_ex0)
                issued_q[select_ex0] <= 1'b1;
            if (issue_ex1)
                issued_q[select_ex1] <= 1'b1;
            if (issue_mem_primary)
                issued_q[select_mem] <= 1'b1;
            if (issue_mem_secondary)
                issued_q[select_mem2] <= 1'b1;

            for (retire_lane = 0; retire_lane < 3;
                 retire_lane = retire_lane + 1) begin
                update_slot = retire_slot_i[
                    retire_lane*RETIRE_SLOT_WIDTH +: RETIRE_SLOT_WIDTH];
                if (retire_valid_i[retire_lane]) begin
                    valid_q[update_slot] <= 1'b0;
                    issued_q[update_slot] <= 1'b0;
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
                    payload_q[update_slot] <= admit_payload[allocation_lane];
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
                    src1_tag_q[update_slot] <=
                        admit_src1_tag[allocation_lane];
                    src2_tag_q[update_slot] <=
                        admit_src2_tag[allocation_lane];
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
        if ((ENABLE != 0) &&
            (DEPTH >= (1 << (`OPENRV64_INSTR_ID_WIDTH - 1))))
            $fatal(1,
                   "issue-window depth must fit the modular ID half-range");
    end

    always @(posedge clk) begin
        if (rst_n && !flush_i && !recovery_inhibit) begin
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
                              "s1_ready=%0d s1_tag=%016x s1_data=%016x ",
                              "s2_ready=%0d s2_tag=%016x s2_data=%016x"},
                             debug_pc,
                             allocation_id_i[
                                 debug_lane*`OPENRV64_INSTR_ID_WIDTH +:
                                 `OPENRV64_INSTR_ID_WIDTH],
                             debug_slot,
                             admit_src1_ready[debug_lane],
                             admit_src1_tag[debug_lane],
                             admit_src1_data[debug_lane],
                             admit_src2_ready[debug_lane],
                             admit_src2_tag[debug_lane],
                             admit_src2_data[debug_lane]);
                end
            end
            for (debug_slot = 0; debug_slot < DEPTH;
                 debug_slot = debug_slot + 1) begin
                if (valid_q[debug_slot] &&
                    (payload_q[debug_slot][274 +: 64] == debug_pc) &&
                    ((issue_ex0 && (select_ex0 == debug_slot)) ||
                     (issue_ex1 && (select_ex1 == debug_slot)) ||
                     (issue_mem_primary &&
                      (select_mem == debug_slot)) ||
                     (issue_mem_secondary &&
                      (select_mem2 == debug_slot)))) begin
                    $display({"WINDOW_DEBUG_ISSUE pc=%016x id=%016x slot=%0d ",
                              "s1_ready=%0d s1_tag=%016x s1_data=%016x ",
                              "s2_ready=%0d s2_tag=%016x s2_data=%016x"},
                             debug_pc, id_q[debug_slot], debug_slot,
                             src1_ready_now[debug_slot],
                             src1_tag_q[debug_slot],
                             src1_data_now[debug_slot],
                             src2_ready_now[debug_slot],
                             src2_tag_q[debug_slot],
                             src2_data_now[debug_slot]);
                end
            end
        end
    end
`endif

endmodule
