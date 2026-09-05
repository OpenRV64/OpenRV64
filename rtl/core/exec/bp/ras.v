`ifndef OPENRV64_EXEC_BP_RAS_V
`define OPENRV64_EXEC_BP_RAS_V
`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

// Eight-entry return-address stack using the architectural RISC-V link
// register hints (x1 and x5).  The physical stack is committed in resolution
// order.  A tagged predictor supplies its surviving speculative actions in
// program order; lookup folds those actions over committed state.  Squash then
// requires only dropping younger actions from the predictor queue.
module openrv64_exec_bp_ras #(
    parameter integer DEPTH = 8,
    parameter integer ORDERED_DEPTH = 16,
    parameter integer INDEX_WIDTH = $clog2(DEPTH),
    parameter integer COUNT_WIDTH = $clog2(DEPTH + 1),
    parameter integer LOAD_SPECULATION_INHIBIT_CYCLES = 4,
    parameter integer INHIBIT_COUNT_WIDTH =
        (LOAD_SPECULATION_INHIBIT_CYCLES < 2) ? 1 :
        $clog2(LOAD_SPECULATION_INHIBIT_CYCLES + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,
    input  wire                         squash_i,

    input  wire                         lookup_valid_i,
    input  wire                         lookup_indirect_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] lookup_instr_i,
    input  wire                         lookup_allocate_i,

    input  wire                         resolve_valid_i,
    input  wire [`RV64_INSTR_WIDTH-1:0] resolve_instr_i,
    input  wire [`RV64_XLEN-1:0]        resolve_pc_i,

    input  wire                         ordered_update_enable_i,
    input  wire                         ordered_update_valid_i,
    input  wire [1:0]                   ordered_update_action_i,
    input  wire [`RV64_XLEN-1:0]        ordered_update_pc_i,
    input  wire [ORDERED_DEPTH-1:0]     ordered_spec_valid_i,
    input  wire [2*ORDERED_DEPTH-1:0]   ordered_spec_action_i,
    input  wire [ORDERED_DEPTH*`RV64_XLEN-1:0]
                                        ordered_spec_pc_i,

    output wire                         prediction_valid_o,
    output wire [`RV64_XLEN-1:0]        prediction_target_o,
    output wire                         inhibit_load_speculation_o
);

    reg [`RV64_XLEN-1:0] stack_q [0:DEPTH-1];
    reg [INDEX_WIDTH-1:0] sp_q;
    reg [COUNT_WIDTH-1:0] count_q;
    reg [COUNT_WIDTH-1:0] pending_calls_q;
    reg [INHIBIT_COUNT_WIDTH-1:0] inhibit_load_count_q;

    function automatic is_link_reg;
        input [`RV64_REG_ADDR_WIDTH-1:0] reg_addr;
        begin
            is_link_reg = (reg_addr == 5'd1) || (reg_addr == 5'd5);
        end
    endfunction

    wire lookup_is_jal =
        `RV64_OPCODE(lookup_instr_i) == `RV64_OPCODE_JAL;
    wire lookup_is_jalr =
        `RV64_OPCODE(lookup_instr_i) == `RV64_OPCODE_JALR;
    wire lookup_rd_link = is_link_reg(`RV64_RD(lookup_instr_i));
    wire lookup_rs1_link = is_link_reg(`RV64_RS1(lookup_instr_i));
    wire lookup_call = lookup_valid_i &&
                       (lookup_is_jal || lookup_is_jalr) &&
                       lookup_rd_link;
    wire lookup_return = lookup_valid_i && lookup_indirect_i &&
                         lookup_is_jalr && lookup_rs1_link &&
                         !lookup_rd_link;

    wire resolve_is_jal =
        `RV64_OPCODE(resolve_instr_i) == `RV64_OPCODE_JAL;
    wire resolve_is_jalr =
        `RV64_OPCODE(resolve_instr_i) == `RV64_OPCODE_JALR;
    wire resolve_rd_link = is_link_reg(`RV64_RD(resolve_instr_i));
    wire resolve_rs1_link = is_link_reg(`RV64_RS1(resolve_instr_i));
    wire resolve_push = resolve_valid_i &&
                        (resolve_is_jal || resolve_is_jalr) &&
                        resolve_rd_link;
    wire resolve_pop = resolve_valid_i && resolve_is_jalr &&
                       resolve_rs1_link &&
                       (!resolve_rd_link ||
                        (`RV64_RD(resolve_instr_i) !=
                         `RV64_RS1(resolve_instr_i)));
    // Use the same architectural hint as lookup_return.  Coroutine pop/push
    // JALRs update the stack but are not plain returns for this policy.
    wire resolve_return = resolve_valid_i && resolve_is_jalr &&
                          resolve_rs1_link && !resolve_rd_link;

    wire ordered_update_push = ordered_update_valid_i &&
                               ordered_update_action_i[0];
    wire ordered_update_pop = ordered_update_valid_i &&
                              ordered_update_action_i[1];
    wire ras_update_push = ordered_update_enable_i ?
                           ordered_update_push : resolve_push;
    wire ras_update_pop = ordered_update_enable_i ?
                          ordered_update_pop : resolve_pop;
    wire [`RV64_XLEN-1:0] ras_update_pc = ordered_update_enable_i ?
        ordered_update_pc_i : resolve_pc_i;
    wire [INDEX_WIDTH-1:0] top_index = sp_q - 1'b1;
    // Build the effective speculative return stack without changing durable
    // state.  This is deliberately read-before-enqueue: ordered_spec_* contains
    // only lookups accepted on earlier edges.  A return therefore observes the
    // older projected top, then contributes its pop for the following query.
    reg [`RV64_XLEN-1:0] projected_stack [0:DEPTH-1];
    reg [INDEX_WIDTH-1:0] projected_sp;
    reg [COUNT_WIDTH-1:0] projected_count;
    reg [INDEX_WIDTH-1:0] projected_top_index;
    reg [1:0] projected_action;
    reg [`RV64_XLEN-1:0] projected_pc;
    integer projection_stack_index;
    integer projection_action_index;
    always @* begin
        projected_sp = sp_q;
        projected_count = count_q;
        projected_top_index = sp_q - 1'b1;
        projected_action = 2'b00;
        projected_pc = {`RV64_XLEN{1'b0}};
        for (projection_stack_index = 0;
             projection_stack_index < DEPTH;
             projection_stack_index = projection_stack_index + 1)
            projected_stack[projection_stack_index] =
                stack_q[projection_stack_index];

        if (ordered_update_enable_i)
            for (projection_action_index = 0;
                 projection_action_index < ORDERED_DEPTH;
                 projection_action_index = projection_action_index + 1)
                if (ordered_spec_valid_i[projection_action_index]) begin
                    projected_action =
                        ordered_spec_action_i[2*projection_action_index +: 2];
                    projected_pc = ordered_spec_pc_i[
                        projection_action_index*`RV64_XLEN +: `RV64_XLEN];
                    projected_top_index = projected_sp - 1'b1;
                    case (projected_action)
                        2'b01: begin
                            projected_stack[projected_sp] =
                                projected_pc + 64'd4;
                            projected_sp = projected_sp + 1'b1;
                            if (projected_count != DEPTH)
                                projected_count = projected_count + 1'b1;
                        end
                        2'b10: begin
                            if (projected_count != 0) begin
                                projected_sp = projected_sp - 1'b1;
                                projected_count = projected_count - 1'b1;
                            end
                        end
                        2'b11: begin
                            if (projected_count != 0)
                                projected_stack[projected_top_index] =
                                    projected_pc + 64'd4;
                            else begin
                                projected_stack[projected_sp] =
                                    projected_pc + 64'd4;
                                projected_sp = projected_sp + 1'b1;
                                projected_count = projected_count + 1'b1;
                            end
                        end
                        default: begin
                        end
                    endcase
                end
        projected_top_index = projected_sp - 1'b1;
    end
    assign prediction_valid_o = lookup_return &&
        (projected_count != 0) &&
        (ordered_update_enable_i || (pending_calls_q == 0));
    assign prediction_target_o = projected_stack[projected_top_index];
    assign inhibit_load_speculation_o = |inhibit_load_count_q;

    wire pending_call_allocate = !ordered_update_enable_i &&
                                 lookup_allocate_i && lookup_call;
    wire pending_call_resolve = !ordered_update_enable_i && resolve_push &&
                                (pending_calls_q != 0);

    integer reset_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp_q <= {INDEX_WIDTH{1'b0}};
            count_q <= {COUNT_WIDTH{1'b0}};
            pending_calls_q <= {COUNT_WIDTH{1'b0}};
            inhibit_load_count_q <= {INHIBIT_COUNT_WIDTH{1'b0}};
            for (reset_index = 0; reset_index < DEPTH;
                 reset_index = reset_index + 1)
                stack_q[reset_index] <= {`RV64_XLEN{1'b0}};
        end else if (flush_i) begin
            // Architectural flushes can cross privilege or address-space
            // contexts.  A return target from the old context is not safe to
            // fetch in the new one, especially when the new context is BARE.
            sp_q <= {INDEX_WIDTH{1'b0}};
            count_q <= {COUNT_WIDTH{1'b0}};
            pending_calls_q <= {COUNT_WIDTH{1'b0}};
            inhibit_load_count_q <= {INHIBIT_COUNT_WIDTH{1'b0}};
        end else begin
            // A resolved return starts a short conservative interval for the
            // target stream.  It wins over squash because a mispredicted
            // return redirects to exactly the stream that needs the guard.
            // An unrelated squash invalidates a wrong-path interval.
            if (resolve_return)
                inhibit_load_count_q <= LOAD_SPECULATION_INHIBIT_CYCLES;
            else if (squash_i)
                inhibit_load_count_q <= {INHIBIT_COUNT_WIDTH{1'b0}};
            else if (inhibit_load_count_q != 0)
                inhibit_load_count_q <= inhibit_load_count_q - 1'b1;

            if (squash_i)
                pending_calls_q <= {COUNT_WIDTH{1'b0}};
            else begin
                case ({pending_call_allocate, pending_call_resolve})
                    2'b10: begin
                        if (pending_calls_q != DEPTH)
                            pending_calls_q <= pending_calls_q + 1'b1;
                    end
                    2'b01: pending_calls_q <= pending_calls_q - 1'b1;
                    default: begin
                    end
                endcase
            end

            case ({ras_update_push, ras_update_pop})
                2'b10: begin
                    stack_q[sp_q] <= ras_update_pc + 64'd4;
                    sp_q <= sp_q + 1'b1;
                    if (count_q != DEPTH)
                        count_q <= count_q + 1'b1;
                end
                2'b01: begin
                    if (count_q != 0) begin
                        sp_q <= sp_q - 1'b1;
                        count_q <= count_q - 1'b1;
                    end
                end
                2'b11: begin
                    // Coroutine hint: pop the old top, then push this link.
                    if (count_q != 0)
                        stack_q[top_index] <= ras_update_pc + 64'd4;
                    else begin
                        stack_q[sp_q] <= ras_update_pc + 64'd4;
                        sp_q <= sp_q + 1'b1;
                        count_q <= count_q + 1'b1;
                    end
                end
                default: begin
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    openrv64_ras_debug_stub #(
        .DEPTH(DEPTH),
        .INDEX_WIDTH(INDEX_WIDTH),
        .COUNT_WIDTH(COUNT_WIDTH)
    ) u_debug (
        .stack_q(stack_q),
        .sp_q(sp_q),
        .count_q(count_q),
        .pending_calls_q(pending_calls_q),
        .top_index(top_index),
        .resolve_push(ras_update_push),
        .resolve_pop(ras_update_pop),
        .pending_call_allocate(pending_call_allocate),
        .pending_call_resolve(pending_call_resolve)
    );

    initial begin
        if ((DEPTH < 2) || ((1 << INDEX_WIDTH) != DEPTH))
            $fatal(1, "RAS DEPTH must be a power of two >= 2");
    end
`endif

endmodule

`endif
