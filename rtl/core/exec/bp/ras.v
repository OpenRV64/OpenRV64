`ifndef OPENRV64_EXEC_BP_RAS_V
`define OPENRV64_EXEC_BP_RAS_V
`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

// Eight-entry return-address stack using the architectural RISC-V link
// register hints (x1 and x5).  State changes only when a control transfer
// resolves, so wrong-path fetch never requires stack rollback.  A pending
// unresolved call suppresses return prediction until its address is pushed.
module openrv64_exec_bp_ras #(
    parameter integer DEPTH = 8,
    parameter integer INDEX_WIDTH = $clog2(DEPTH),
    parameter integer COUNT_WIDTH = $clog2(DEPTH + 1)
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

    output wire                         prediction_valid_o,
    output wire [`RV64_XLEN-1:0]        prediction_target_o
);

    reg [`RV64_XLEN-1:0] stack_q [0:DEPTH-1];
    reg [INDEX_WIDTH-1:0] sp_q;
    reg [COUNT_WIDTH-1:0] count_q;
    reg [COUNT_WIDTH-1:0] pending_calls_q;

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

    wire [INDEX_WIDTH-1:0] top_index = sp_q - 1'b1;
    assign prediction_valid_o = lookup_return && (count_q != 0) &&
                                (pending_calls_q == 0);
    assign prediction_target_o = stack_q[top_index];

    wire pending_call_allocate = lookup_allocate_i && lookup_call;
    wire pending_call_resolve = resolve_push && (pending_calls_q != 0);

    integer reset_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp_q <= {INDEX_WIDTH{1'b0}};
            count_q <= {COUNT_WIDTH{1'b0}};
            pending_calls_q <= {COUNT_WIDTH{1'b0}};
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
        end else begin
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

            case ({resolve_push, resolve_pop})
                2'b10: begin
                    stack_q[sp_q] <= resolve_pc_i + 64'd4;
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
                        stack_q[top_index] <= resolve_pc_i + 64'd4;
                    else begin
                        stack_q[sp_q] <= resolve_pc_i + 64'd4;
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
    initial begin
        if ((DEPTH < 2) || ((1 << INDEX_WIDTH) != DEPTH))
            $fatal(1, "RAS DEPTH must be a power of two >= 2");
    end
`endif

endmodule

`endif
