`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/br-defs.v"

// Three-pipe dispatch with a small decoded-instruction queue.  Frontend input
// is three-wide; the queue can present the oldest three entries to issue.  All
// issue/allocation is one strict program-order prefix.
module openrv64_dispatch_3p #(
    parameter integer QUEUE_DEPTH = 6,
    parameter integer RETIRE_SLOT_WIDTH = 3,
    parameter integer MAX_READS_PER_REG = 2,
    parameter integer RELAX_WAW = 1,
    parameter integer RELAX_HAZARDS = 0,
    parameter integer FREE_BRANCHES = 0,
    parameter integer ENABLE_EQ_BRANCH_PAIRING = 1,
    parameter integer COUNT_WIDTH = $clog2(QUEUE_DEPTH + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_frontend_i,

    input  wire [2:0]                   decode_valid_i,
    output wire [2:0]                   decode_ready_o,
    input  wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        decode_payload_i,
    input  wire [2:0]                   decode_uses_rs1_i,
    input  wire [2:0]                   decode_uses_rs2_i,

    output wire [6*`RV64_REG_ADDR_WIDTH-1:0] gpr_read_addr_o,
    input  wire [6*`RV64_XLEN-1:0]      gpr_read_data_i,

    input  wire                         allocation_ready_i,
    input  wire [3*64-1:0]              allocation_id_i,
    input  wire [3*RETIRE_SLOT_WIDTH-1:0] allocation_slot_i,
    output wire [2:0]                   allocation_valid_o,
    output wire [3*`OPENRV64_RETIRE_META_WIDTH-1:0] allocation_meta_o,

    input  wire [2:0]                   pipe_ready_i,
    input  wire [1:0]                   forward_valid_i,
    input  wire [2*`RV64_REG_ADDR_WIDTH-1:0] forward_rd_addr_i,
    input  wire [2:0]                   completion_forward_valid_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0]
                                        completion_forward_rd_addr_i,
    input  wire [3*`RV64_XLEN-1:0]      completion_forward_data_i,
    input  wire [2:0]                   branch_completion_forward_valid_i,
    input  wire [31:0]                  forward_map_valid_i,
    input  wire [32*`RV64_XLEN-1:0]     forward_map_data_i,
    output wire [2:0]                   pipe_valid_o,
    output wire [3*64-1:0]              pipe_id_o,
    output wire [3*RETIRE_SLOT_WIDTH-1:0] pipe_slot_o,
    output wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
                                        pipe_payload_o,

    input  wire [2:0]                   retire_valid_i,
    input  wire [2:0]                   retire_uses_rs1_i,
    input  wire [2:0]                   retire_uses_rs2_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rs1_addr_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rs2_addr_i,
    input  wire [2:0]                   retire_reg_write_i,
    input  wire [3*`RV64_REG_ADDR_WIDTH-1:0] retire_rd_addr_i,
    input  wire [2:0]                   retire_hard_i,

    output wire                         barrier_active_o,
    output wire [2:0]                   raw_hazard_o,
    output wire [2:0]                   waw_hazard_o,
    output wire [2:0]                   read_port_hazard_o,
    output wire [31:0]                  write_busy_o,
    output wire [COUNT_WIDTH-1:0]       queue_count_o
);

    reg [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        payload_q [0:QUEUE_DEPTH-1];
    reg uses_rs1_q [0:QUEUE_DEPTH-1];
    reg uses_rs2_q [0:QUEUE_DEPTH-1];
    reg [COUNT_WIDTH-1:0] count_q;

    wire [2:0] candidate_valid = {
        (count_q > 2),
        (count_q > 1),
        (count_q > 0)
    };
    wire [2:0] candidate_uses_rs1 = {
        (count_q > 2) ? uses_rs1_q[2] : 1'b0,
        (count_q > 1) ? uses_rs1_q[1] : 1'b0,
        (count_q > 0) ? uses_rs1_q[0] : 1'b0
    };
    wire [2:0] candidate_uses_rs2 = {
        (count_q > 2) ? uses_rs2_q[2] : 1'b0,
        (count_q > 1) ? uses_rs2_q[1] : 1'b0,
        (count_q > 0) ? uses_rs2_q[0] : 1'b0
    };

    reg [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] candidate_payload;
    integer payload_idx;
    integer completion_forward_idx;
    reg [`RV64_XLEN-1:0] forwarded_rs1_data;
    reg [`RV64_XLEN-1:0] forwarded_rs2_data;
    reg branch_forwarded_rs1;
    reg branch_forwarded_rs2;
    function automatic retiring_write_match;
        input [`RV64_REG_ADDR_WIDTH-1:0] source_addr;
        integer retire_lane;
        begin
            retiring_write_match = 1'b0;
            for (retire_lane = 0; retire_lane < 3;
                 retire_lane = retire_lane + 1) begin
                if (retire_valid_i[retire_lane] &&
                    retire_reg_write_i[retire_lane] &&
                    (retire_rd_addr_i[
                        retire_lane*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH] == source_addr) &&
                    (source_addr != `RV64_REG_X0))
                    retiring_write_match = 1'b1;
            end
        end
    endfunction

    always_comb begin
        candidate_payload =
            {3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
        forwarded_rs1_data = {`RV64_XLEN{1'b0}};
        forwarded_rs2_data = {`RV64_XLEN{1'b0}};
        branch_forwarded_rs1 = 1'b0;
        branch_forwarded_rs2 = 1'b0;
        completion_forward_idx = 0;
        for (payload_idx = 0; payload_idx < 3; payload_idx = payload_idx + 1) begin
            if (count_q > payload_idx) begin
                candidate_payload[
                    payload_idx*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] = payload_q[payload_idx];
                forwarded_rs1_data = gpr_read_data_i[
                    (payload_idx*2+0)*`RV64_XLEN +: `RV64_XLEN];
                forwarded_rs2_data = gpr_read_data_i[
                    (payload_idx*2+1)*`RV64_XLEN +: `RV64_XLEN];
                branch_forwarded_rs1 = 1'b0;
                branch_forwarded_rs2 = 1'b0;
                for (completion_forward_idx = 0;
                     completion_forward_idx < 3;
                     completion_forward_idx = completion_forward_idx + 1) begin
                    if (completion_forward_valid_i[completion_forward_idx] &&
                        (completion_forward_rd_addr_i[
                            completion_forward_idx*`RV64_REG_ADDR_WIDTH +:
                            `RV64_REG_ADDR_WIDTH] ==
                         payload_q[payload_idx][237 +:
                            `RV64_REG_ADDR_WIDTH]))
                        forwarded_rs1_data = completion_forward_data_i[
                            completion_forward_idx*`RV64_XLEN +:
                            `RV64_XLEN];
                    if (completion_forward_valid_i[completion_forward_idx] &&
                        (completion_forward_rd_addr_i[
                            completion_forward_idx*`RV64_REG_ADDR_WIDTH +:
                            `RV64_REG_ADDR_WIDTH] ==
                         payload_q[payload_idx][232 +:
                            `RV64_REG_ADDR_WIDTH]))
                        forwarded_rs2_data = completion_forward_data_i[
                            completion_forward_idx*`RV64_XLEN +:
                            `RV64_XLEN];
                end
                // Six selectors are packed rs1,rs2 for candidate 0, then 1,2.
                if (forward_map_valid_i[
                        payload_q[payload_idx][237 +: `RV64_REG_ADDR_WIDTH]])
                    forwarded_rs1_data = forward_map_data_i[
                        payload_q[payload_idx][237 +: `RV64_REG_ADDR_WIDTH] *
                        `RV64_XLEN +: `RV64_XLEN];
                if (forward_map_valid_i[
                        payload_q[payload_idx][232 +: `RV64_REG_ADDR_WIDTH]])
                    forwarded_rs2_data = forward_map_data_i[
                        payload_q[payload_idx][232 +: `RV64_REG_ADDR_WIDTH] *
                        `RV64_XLEN +: `RV64_XLEN];
                // The producer-slot-qualified branch path has final forwarding
                // priority.  An untagged general completion/map entry for an
                // older WAW producer must not overwrite the proven youngest
                // value.  In legal operation at most one qualified port can
                // match a given architectural source.
                for (completion_forward_idx = 0;
                     completion_forward_idx < 3;
                     completion_forward_idx = completion_forward_idx + 1) begin
                    if (payload_q[payload_idx][14] &&
                        branch_completion_forward_valid_i[
                            completion_forward_idx] &&
                        (completion_forward_rd_addr_i[
                            completion_forward_idx*`RV64_REG_ADDR_WIDTH +:
                            `RV64_REG_ADDR_WIDTH] ==
                         payload_q[payload_idx][237 +:
                            `RV64_REG_ADDR_WIDTH])) begin
                        forwarded_rs1_data = completion_forward_data_i[
                            completion_forward_idx*`RV64_XLEN +:
                            `RV64_XLEN];
                        branch_forwarded_rs1 = 1'b1;
                    end
                    if (payload_q[payload_idx][14] &&
                        branch_completion_forward_valid_i[
                            completion_forward_idx] &&
                        (completion_forward_rd_addr_i[
                            completion_forward_idx*`RV64_REG_ADDR_WIDTH +:
                            `RV64_REG_ADDR_WIDTH] ==
                         payload_q[payload_idx][232 +:
                            `RV64_REG_ADDR_WIDTH])) begin
                        forwarded_rs2_data = completion_forward_data_i[
                            completion_forward_idx*`RV64_XLEN +:
                            `RV64_XLEN];
                        branch_forwarded_rs2 = 1'b1;
                    end
                end
                // In the conservative mode, ordered same-cycle retirement is
                // the newest source the untagged rd map can prove.  Restore the
                // GPR's youngest-lane retirement bypass there.  In aggressive
                // mode a valid tagged map may describe an even younger live
                // producer, so that result correctly retains priority.
                if (retiring_write_match(
                        payload_q[payload_idx][237 +:
                            `RV64_REG_ADDR_WIDTH]) &&
                    ((RELAX_HAZARDS == 0) ||
                     !forward_map_valid_i[
                        payload_q[payload_idx][237 +:
                            `RV64_REG_ADDR_WIDTH]]) &&
                    !branch_forwarded_rs1)
                    forwarded_rs1_data = gpr_read_data_i[
                        (payload_idx*2+0)*`RV64_XLEN +: `RV64_XLEN];
                if (retiring_write_match(
                        payload_q[payload_idx][232 +:
                            `RV64_REG_ADDR_WIDTH]) &&
                    ((RELAX_HAZARDS == 0) ||
                     !forward_map_valid_i[
                        payload_q[payload_idx][232 +:
                            `RV64_REG_ADDR_WIDTH]]) &&
                    !branch_forwarded_rs2)
                    forwarded_rs2_data = gpr_read_data_i[
                        (payload_idx*2+1)*`RV64_XLEN +: `RV64_XLEN];
                candidate_payload[
                    payload_idx*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                    168 +: 64] = forwarded_rs1_data;
                candidate_payload[
                    payload_idx*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                    104 +: 64] = forwarded_rs2_data;
            end
        end
    end

    genvar read_lane;
    generate
        for (read_lane = 0; read_lane < 3; read_lane = read_lane + 1) begin : g_read_addr
            assign gpr_read_addr_o[
                (read_lane*2+0)*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH] = candidate_payload[
                read_lane*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 237 +:
                `RV64_REG_ADDR_WIDTH];
            assign gpr_read_addr_o[
                (read_lane*2+1)*`RV64_REG_ADDR_WIDTH +:
                `RV64_REG_ADDR_WIDTH] = candidate_payload[
                read_lane*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 232 +:
                `RV64_REG_ADDR_WIDTH];
        end
    endgenerate

    wire [3*`RV64_REG_ADDR_WIDTH-1:0] candidate_rs1_addr = {
        candidate_payload[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 237 +: 5],
        candidate_payload[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 237 +: 5],
        candidate_payload[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 237 +: 5]
    };
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] candidate_rs2_addr = {
        candidate_payload[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 232 +: 5],
        candidate_payload[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 232 +: 5],
        candidate_payload[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 232 +: 5]
    };
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] candidate_rd_addr = {
        candidate_payload[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 35 +: 5],
        candidate_payload[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 35 +: 5],
        candidate_payload[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 35 +: 5]
    };
    wire [2:0] candidate_branch = {
        candidate_payload[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 14],
        candidate_payload[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 14],
        candidate_payload[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 14]
    };
    wire [2:0] candidate_reg_write = {
        candidate_payload[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 17],
        candidate_payload[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 17],
        candidate_payload[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 17]
    };
    wire [2:0] candidate_hazard_free;
    wire [2:0] candidate_fire;

    function automatic [`OPENRV64_EXEC_PIPE_WIDTH-1:0] fixed_pipe;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            if (payload[16] || payload[15]) begin
                fixed_pipe = `OPENRV64_EXEC_PIPE_MEM;
            end else if (payload[10] || payload[9] || payload[8] ||
                         payload[7] || payload[6] || payload[5] ||
                         payload[4] || payload[14] || payload[13]) begin
                fixed_pipe = `OPENRV64_EXEC_PIPE_EX0;
            end else if (payload[34:32] == `RV64_ALU_EXT_M) begin
                fixed_pipe = `OPENRV64_EXEC_PIPE_EX1;
            end else begin
                fixed_pipe = 2'd3;
            end
        end
    endfunction

    function automatic [`OPENRV64_EXEC_PIPE_WIDTH-1:0] choose_base_pipe;
        input [2:0] used;
        input [`OPENRV64_EXEC_PIPE_WIDTH-1:0] next_fixed;
        input preferred_valid;
        input [`OPENRV64_EXEC_PIPE_WIDTH-1:0] preferred_pipe;
        begin
            if (preferred_valid) begin
                choose_base_pipe = preferred_pipe;
            end else if (!used[0] && !used[1]) begin
                if (next_fixed == `OPENRV64_EXEC_PIPE_EX0)
                    choose_base_pipe = `OPENRV64_EXEC_PIPE_EX1;
                else if (next_fixed == `OPENRV64_EXEC_PIPE_EX1)
                    choose_base_pipe = `OPENRV64_EXEC_PIPE_EX0;
                else
                    choose_base_pipe = `OPENRV64_EXEC_PIPE_EX0;
            end else if (!used[0]) begin
                choose_base_pipe = `OPENRV64_EXEC_PIPE_EX0;
            end else if (!used[1]) begin
                choose_base_pipe = `OPENRV64_EXEC_PIPE_EX1;
            end else begin
                choose_base_pipe = `OPENRV64_EXEC_PIPE_EX0;
            end
        end
    endfunction

    function automatic [1:0] forward_match;
        input uses_rs1;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs1_addr;
        input uses_rs2;
        input [`RV64_REG_ADDR_WIDTH-1:0] rs2_addr;
        input [1:0] forward_valid;
        input [2*`RV64_REG_ADDR_WIDTH-1:0] forward_rd_addr;
        integer forward_idx;
        reg [`RV64_REG_ADDR_WIDTH-1:0] forward_rd;
        begin
            forward_match = 2'b00;
            for (forward_idx = 0; forward_idx < 2;
                 forward_idx = forward_idx + 1) begin
                forward_rd = forward_rd_addr[
                    forward_idx*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH];
                if (forward_valid[forward_idx] &&
                    (forward_rd != `RV64_REG_X0) &&
                    ((uses_rs1 && (rs1_addr == forward_rd)) ||
                     (uses_rs2 && (rs2_addr == forward_rd)))) begin
                    forward_match[forward_idx] = 1'b1;
                end
            end
        end
    endfunction

    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload0 =
        candidate_payload[0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                          `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload1 =
        candidate_payload[1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                          `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload2 =
        candidate_payload[2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                          `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
    function automatic is_free_branch;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            is_free_branch = (FREE_BRANCHES != 0) &&
                payload[14] &&                  // conditional branch only
                !payload[8] &&                  // illegal
                !payload[5] &&                  // instruction access fault
                !payload[4];                    // instruction page fault
        end
    endfunction

    function automatic is_pairable_eq_branch;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        reg [`RV64_BR_OP_WIDTH-1:0] branch_op;
        begin
            branch_op = payload[18 +: `RV64_BR_OP_WIDTH];
            is_pairable_eq_branch =
                (ENABLE_EQ_BRANCH_PAIRING != 0) &&
                payload[14] &&                  // conditional branch only
                !payload[8] &&                  // illegal
                !payload[5] &&                  // instruction access fault
                !payload[4] &&                  // instruction page fault
                !payload[41] &&                 // direct target is aligned
                ((branch_op == `RV64_BR_OP_BEQ) ||
                 (branch_op == `RV64_BR_OP_BNE));
        end
    endfunction

    function automatic branch_taken;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        reg [`RV64_BR_OP_WIDTH-1:0] branch_op;
        reg [`RV64_XLEN-1:0] src1;
        reg [`RV64_XLEN-1:0] src2;
        begin
            branch_op = payload[18 +: `RV64_BR_OP_WIDTH];
            src1 = payload[168 +: `RV64_XLEN];
            src2 = payload[104 +: `RV64_XLEN];
            case (branch_op)
                `RV64_BR_OP_BEQ:  branch_taken = (src1 == src2);
                `RV64_BR_OP_BNE:  branch_taken = (src1 != src2);
                `RV64_BR_OP_BLT:  branch_taken =
                    ($signed(src1) < $signed(src2));
                `RV64_BR_OP_BGE:  branch_taken =
                    ($signed(src1) >= $signed(src2));
                `RV64_BR_OP_BLTU: branch_taken = (src1 < src2);
                `RV64_BR_OP_BGEU: branch_taken = (src1 >= src2);
                default:          branch_taken = 1'b0;
            endcase
        end
    endfunction

    // Free branches retain real operand hazards and real prediction.  A
    // correctly predicted branch does not claim a pipe or terminate the
    // group; a known misprediction suppresses its younger wrong-path lanes.
    wire free0 = candidate_valid[0] && is_free_branch(payload0);
    wire free1 = candidate_valid[1] && is_free_branch(payload1);
    wire free2 = candidate_valid[2] && is_free_branch(payload2);
    wire [2:0] candidate_free = {free2, free1, free0};
    wire free_mispredict0 = free0 &&
        (branch_taken(payload0) != payload0[12]);
    wire free_mispredict1 = free1 &&
        (branch_taken(payload1) != payload1[12]);
    // Equality branches are cheap enough to resolve once in dispatch.  When
    // that result proves the frontend prediction correct, waive only their
    // same-cycle barrier so predicted-path work may share the bundle.  The
    // branch itself remains a normal EX0 instruction and retirement entry.
    // A wrong prediction, non-equality branch, fault, or unresolved operand
    // retains the ordinary prefix barrier; strict candidate-fire chaining
    // prevents younger issue when this branch cannot itself issue.
    wire pair_eq0 = candidate_valid[0] && !free0 &&
        is_pairable_eq_branch(payload0) &&
        (branch_taken(payload0) == payload0[12]);
    wire pair_eq1 = candidate_valid[1] && !free1 &&
        is_pairable_eq_branch(payload1) &&
        (branch_taken(payload1) == payload1[12]);
    wire pair_eq2 = candidate_valid[2] && !free2 &&
        is_pairable_eq_branch(payload2) &&
        (branch_taken(payload2) == payload2[12]);
    wire [2:0] candidate_barrier_free = {pair_eq2, pair_eq1, pair_eq0};
    wire [2:0] reg_map_uses_rs1 = candidate_uses_rs1;
    wire [2:0] reg_map_uses_rs2 = candidate_uses_rs2;

    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] fixed0 = fixed_pipe(payload0);
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] fixed1 = fixed_pipe(payload1);
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] fixed2 = fixed_pipe(payload2);
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] routing_fixed0 = free0 ? 2'd3 : fixed0;
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] routing_fixed1 = free1 ? 2'd3 : fixed1;
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] routing_fixed2 = free2 ? 2'd3 : fixed2;
    wire [1:0] forward_match0 = forward_match(
        candidate_uses_rs1[0],
        candidate_rs1_addr[0*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH],
        candidate_uses_rs2[0],
        candidate_rs2_addr[0*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH],
        forward_valid_i, forward_rd_addr_i);
    wire [1:0] forward_match1 = forward_match(
        candidate_uses_rs1[1],
        candidate_rs1_addr[1*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH],
        candidate_uses_rs2[1],
        candidate_rs2_addr[1*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH],
        forward_valid_i, forward_rd_addr_i);
    wire [1:0] forward_match2 = forward_match(
        candidate_uses_rs1[2],
        candidate_rs1_addr[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH],
        candidate_uses_rs2[2],
        candidate_rs2_addr[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH],
        forward_valid_i, forward_rd_addr_i);
    wire forward_preferred0 = (forward_match0 == 2'b01) ||
                              (forward_match0 == 2'b10);
    wire forward_preferred1 = (forward_match1 == 2'b01) ||
                              (forward_match1 == 2'b10);
    wire forward_preferred2 = (forward_match2 == 2'b01) ||
                              (forward_match2 == 2'b10);
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] forward_pipe0 =
        forward_match0[1] ? `OPENRV64_EXEC_PIPE_EX1 :
                            `OPENRV64_EXEC_PIPE_EX0;
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] forward_pipe1 =
        forward_match1[1] ? `OPENRV64_EXEC_PIPE_EX1 :
                            `OPENRV64_EXEC_PIPE_EX0;
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] forward_pipe2 =
        forward_match2[1] ? `OPENRV64_EXEC_PIPE_EX1 :
                            `OPENRV64_EXEC_PIPE_EX0;
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] selected0 =
        (routing_fixed0 != 2'd3) ? routing_fixed0 :
        choose_base_pipe(3'b000, routing_fixed1,
                         forward_preferred0, forward_pipe0);
    wire [2:0] used0 = candidate_valid[0] && !free0 ?
        (3'b001 << selected0) : 3'b000;
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] selected1 =
        (routing_fixed1 != 2'd3) ? routing_fixed1 :
        choose_base_pipe(used0, routing_fixed2,
                         forward_preferred1, forward_pipe1);
    wire [2:0] used1 = used0 | (candidate_valid[1] && !free1 ?
        (3'b001 << selected1) : 3'b000);
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] selected2 =
        (routing_fixed2 != 2'd3) ? routing_fixed2 :
        choose_base_pipe(used1, 2'd3,
                         forward_preferred2, forward_pipe2);
    wire [3*`OPENRV64_EXEC_PIPE_WIDTH-1:0] candidate_pipe = {
        free2 ? 2'd3 : selected2,
        free1 ? 2'd3 : selected1,
        free0 ? 2'd3 : selected0
    };

    openrv64_dispatch_reg_map_3p #(
        .MAX_READS_PER_REG(MAX_READS_PER_REG),
        .RELAX_WAW(RELAX_WAW),
        .RELAX_HAZARDS(RELAX_HAZARDS)
    ) u_reg_map (
        .clk(clk),
        .rst_n(rst_n),
        .clear_i(flush_i),
        .candidate_valid_i(candidate_valid),
        .candidate_branch_i(candidate_branch),
        .candidate_uses_rs1_i(reg_map_uses_rs1),
        .candidate_uses_rs2_i(reg_map_uses_rs2),
        .candidate_rs1_addr_i(candidate_rs1_addr),
        .candidate_rs2_addr_i(candidate_rs2_addr),
        .candidate_reg_write_i(candidate_reg_write),
        .candidate_rd_addr_i(candidate_rd_addr),
        .candidate_pipe_i(candidate_pipe),
        .forward_valid_i(forward_valid_i),
        .forward_rd_addr_i(forward_rd_addr_i),
        .completion_forward_valid_i(completion_forward_valid_i),
        .completion_forward_rd_addr_i(completion_forward_rd_addr_i),
        .branch_completion_forward_valid_i(
            branch_completion_forward_valid_i),
        .forward_map_valid_i(forward_map_valid_i),
        .candidate_hazard_free_o(candidate_hazard_free),
        .raw_hazard_o(raw_hazard_o),
        .waw_hazard_o(waw_hazard_o),
        .read_port_hazard_o(read_port_hazard_o),
        .allocation_fire_i(candidate_fire),
        .retire_valid_i(retire_valid_i),
        .retire_reg_write_i(retire_reg_write_i),
        .retire_rd_addr_i(retire_rd_addr_i),
        .write_busy_o(write_busy_o)
    );

    wire [2:0] candidate_hard;
    wire [2:0] candidate_hazard_free_effective = {
        candidate_hazard_free[2] &&
            !free_mispredict0 && !free_mispredict1,
        candidate_hazard_free[1] && !free_mispredict0,
        candidate_hazard_free[0]
    };
    openrv64_dispatch_control_3p #(
        .RETIRE_SLOT_WIDTH(RETIRE_SLOT_WIDTH)
    ) u_control (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_i),
        .candidate_valid_i(candidate_valid),
        .candidate_free_i(candidate_free),
        .candidate_barrier_free_i(candidate_barrier_free),
        .candidate_hazard_free_i(candidate_hazard_free_effective),
        .candidate_pipe_i(candidate_pipe),
        .candidate_id_i(allocation_id_i),
        .candidate_slot_i(allocation_slot_i),
        .candidate_payload_i(candidate_payload),
        .allocation_ready_i(allocation_ready_i),
        .pipe_ready_i(pipe_ready_i),
        .retire_valid_i(retire_valid_i),
        .retire_hard_i(retire_hard_i),
        .candidate_hard_o(candidate_hard),
        .candidate_fire_o(candidate_fire),
        .barrier_active_o(barrier_active_o),
        .pipe_valid_o(pipe_valid_o),
        .pipe_id_o(pipe_id_o),
        .pipe_slot_o(pipe_slot_o),
        .pipe_payload_o(pipe_payload_o)
    );

    assign allocation_valid_o = candidate_fire;
    generate
        for (read_lane = 0; read_lane < 3; read_lane = read_lane + 1) begin : g_meta
            assign allocation_meta_o[
                read_lane*`OPENRV64_RETIRE_META_WIDTH +:
                `OPENRV64_RETIRE_META_WIDTH] = {
                candidate_hard[read_lane],
                reg_map_uses_rs2[read_lane],
                reg_map_uses_rs1[read_lane],
                candidate_payload[
                    read_lane*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]
            };
        end
    endgenerate

    wire [2:0] issue_count =
        {2'd0, candidate_fire[0]} +
        {2'd0, candidate_fire[1]} +
        {2'd0, candidate_fire[2]};
    wire [COUNT_WIDTH-1:0] remaining_count = count_q - issue_count;
    wire [COUNT_WIDTH:0] free_after_issue = QUEUE_DEPTH - remaining_count;
    assign decode_ready_o[0] = !flush_i && !squash_frontend_i &&
                               (free_after_issue >= 1);
    assign decode_ready_o[1] = !flush_i && !squash_frontend_i &&
                               (free_after_issue >= 2);
    assign decode_ready_o[2] = !flush_i && !squash_frontend_i &&
                               (free_after_issue >= 3);
    wire decode_fire0 = decode_valid_i[0] && decode_ready_o[0];
    wire decode_fire1 = decode_valid_i[1] && decode_ready_o[1] && decode_fire0;
    wire decode_fire2 = decode_valid_i[2] && decode_ready_o[2] && decode_fire1;
    wire [1:0] decode_count = {1'b0, decode_fire0} +
                              {1'b0, decode_fire1} +
                              {1'b0, decode_fire2};

    integer queue_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count_q <= {COUNT_WIDTH{1'b0}};
            for (queue_idx = 0; queue_idx < QUEUE_DEPTH;
                 queue_idx = queue_idx + 1) begin
                payload_q[queue_idx] <=
                    {`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
                uses_rs1_q[queue_idx] <= 1'b0;
                uses_rs2_q[queue_idx] <= 1'b0;
            end
        end else if (flush_i || squash_frontend_i) begin
            count_q <= {COUNT_WIDTH{1'b0}};
            for (queue_idx = 0; queue_idx < QUEUE_DEPTH;
                 queue_idx = queue_idx + 1) begin
                payload_q[queue_idx] <=
                    {`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
                uses_rs1_q[queue_idx] <= 1'b0;
                uses_rs2_q[queue_idx] <= 1'b0;
            end
        end else begin
            count_q <= remaining_count + decode_count;

            for (queue_idx = 0; queue_idx < QUEUE_DEPTH;
                 queue_idx = queue_idx + 1) begin
                if (queue_idx < remaining_count) begin
                    payload_q[queue_idx] <= payload_q[queue_idx + issue_count];
                    uses_rs1_q[queue_idx] <=
                        uses_rs1_q[queue_idx + issue_count];
                    uses_rs2_q[queue_idx] <=
                        uses_rs2_q[queue_idx + issue_count];
                end else if (decode_fire0 &&
                             (queue_idx == remaining_count)) begin
                    payload_q[queue_idx] <= decode_payload_i[
                        0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
                    uses_rs1_q[queue_idx] <= decode_uses_rs1_i[0];
                    uses_rs2_q[queue_idx] <= decode_uses_rs2_i[0];
                end else if (decode_fire1 &&
                             (queue_idx == (remaining_count + 1))) begin
                    payload_q[queue_idx] <= decode_payload_i[
                        1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
                    uses_rs1_q[queue_idx] <= decode_uses_rs1_i[1];
                    uses_rs2_q[queue_idx] <= decode_uses_rs2_i[1];
                end else if (decode_fire2 &&
                             (queue_idx == (remaining_count + 2))) begin
                    payload_q[queue_idx] <= decode_payload_i[
                        2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
                    uses_rs1_q[queue_idx] <= decode_uses_rs1_i[2];
                    uses_rs2_q[queue_idx] <= decode_uses_rs2_i[2];
                end else begin
                    payload_q[queue_idx] <=
                        {`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}};
                    uses_rs1_q[queue_idx] <= 1'b0;
                    uses_rs2_q[queue_idx] <= 1'b0;
                end
            end
        end
    end

    assign queue_count_o = count_q;
    wire unused_release_sources = |{
        retire_uses_rs1_i,
        retire_uses_rs2_i,
        retire_rs1_addr_i,
        retire_rs2_addr_i
    };

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && !flush_i && !squash_frontend_i) begin
            if ((decode_valid_i != 3'b000) &&
                (decode_valid_i != 3'b001) &&
                (decode_valid_i != 3'b011) &&
                (decode_valid_i != 3'b111))
                $fatal(1, "3p decode input must be a contiguous prefix");
            if ((count_q + decode_count - issue_count) > QUEUE_DEPTH)
                $fatal(1, "3p dispatch queue overflow");
        end
    end
`endif

endmodule
