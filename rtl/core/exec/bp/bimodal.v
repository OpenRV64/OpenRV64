`ifndef OPENRV64_EXEC_BP_BIMODAL_V
`define OPENRV64_EXEC_BP_BIMODAL_V
`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

// Small PC-indexed direction predictor.  Invalid entries use BTFNT, so the
// table never makes cold prediction worse than the static policy it replaces.
// Resolutions arrive up to three wide from the 3P backend and are serialized
// through a short FIFO, keeping the counter table single-write-port.
module openrv64_exec_bp_bimodal #(
    parameter integer ENTRIES = 32,
    parameter integer COUNTER_BITS = 3,
    parameter integer UPDATE_DEPTH = 4,
    parameter integer INDEX_WIDTH = $clog2(ENTRIES),
    parameter integer UPDATE_PTR_WIDTH = $clog2(UPDATE_DEPTH),
    parameter integer UPDATE_COUNT_WIDTH = $clog2(UPDATE_DEPTH + 1)
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         lookup_branch_i,
    input  wire                         lookup_jump_i,
    input  wire                         lookup_indirect_i,
    input  wire                         lookup_backward_i,
    input  wire [`RV64_XLEN-1:0]        lookup_pc_i,

    input  wire [2:0]                   train_valid_i,
    input  wire [2:0]                   train_branch_i,
    input  wire [2:0]                   train_taken_i,
    input  wire [3*`RV64_XLEN-1:0]      train_pc_i,

    output wire                         prediction_taken_o,
    output wire                         update_overflow_o
);

    reg [ENTRIES-1:0] valid_q;
    reg [COUNTER_BITS-1:0] counter_q [0:ENTRIES-1];

    reg [INDEX_WIDTH-1:0] update_index_q [0:UPDATE_DEPTH-1];
    reg update_taken_q [0:UPDATE_DEPTH-1];
    reg [UPDATE_PTR_WIDTH-1:0] update_head_q;
    reg [UPDATE_PTR_WIDTH-1:0] update_tail_q;
    reg [UPDATE_COUNT_WIDTH-1:0] update_count_q;
    reg update_overflow_q;

    wire [INDEX_WIDTH-1:0] lookup_index =
        lookup_pc_i[INDEX_WIDTH+1:2];
    wire learned_prediction = counter_q[lookup_index][COUNTER_BITS-1];
    wire conditional_prediction = valid_q[lookup_index] ?
        learned_prediction : lookup_backward_i;

    assign prediction_taken_o =
        (lookup_branch_i && conditional_prediction) ||
        (lookup_jump_i && !lookup_indirect_i);
    assign update_overflow_o = update_overflow_q;

    wire [INDEX_WIDTH-1:0] update_index =
        update_index_q[update_head_q];
    wire [COUNTER_BITS-1:0] counter_max =
        {COUNTER_BITS{1'b1}};
    wire [COUNTER_BITS-1:0] weak_taken =
        {1'b1, {(COUNTER_BITS-1){1'b0}}};
    wire [COUNTER_BITS-1:0] weak_not_taken =
        {1'b0, {(COUNTER_BITS-1){1'b1}}};

    integer reset_index;
    integer enqueue_lane;
    reg [UPDATE_PTR_WIDTH-1:0] tail_work;
    reg [UPDATE_COUNT_WIDTH-1:0] count_work;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_q <= {ENTRIES{1'b0}};
            update_head_q <= {UPDATE_PTR_WIDTH{1'b0}};
            update_tail_q <= {UPDATE_PTR_WIDTH{1'b0}};
            update_count_q <= {UPDATE_COUNT_WIDTH{1'b0}};
            update_overflow_q <= 1'b0;
            for (reset_index = 0; reset_index < ENTRIES;
                 reset_index = reset_index + 1)
                counter_q[reset_index] <= {COUNTER_BITS{1'b0}};
        end else begin
            tail_work = update_tail_q;
            count_work = update_count_q;

            if (update_count_q != 0) begin
                if (!valid_q[update_index]) begin
                    valid_q[update_index] <= 1'b1;
                    counter_q[update_index] <= update_taken_q[update_head_q] ?
                        weak_taken : weak_not_taken;
                end else if (update_taken_q[update_head_q]) begin
                    if (counter_q[update_index] != counter_max)
                        counter_q[update_index] <=
                            counter_q[update_index] + 1'b1;
                end else if (counter_q[update_index] != 0) begin
                    counter_q[update_index] <=
                        counter_q[update_index] - 1'b1;
                end

                update_head_q <= update_head_q + 1'b1;
                count_work = update_count_q - 1'b1;
            end

            for (enqueue_lane = 0; enqueue_lane < 3;
                 enqueue_lane = enqueue_lane + 1) begin
                if (train_valid_i[enqueue_lane] &&
                    train_branch_i[enqueue_lane]) begin
                    if (count_work < UPDATE_DEPTH) begin
                        update_index_q[tail_work] <= train_pc_i[
                            enqueue_lane*`RV64_XLEN + 2 +: INDEX_WIDTH];
                        update_taken_q[tail_work] <=
                            train_taken_i[enqueue_lane];
                        tail_work = tail_work + 1'b1;
                        count_work = count_work + 1'b1;
                    end else begin
                        update_overflow_q <= 1'b1;
                    end
                end
            end

            update_tail_q <= tail_work;
            update_count_q <= count_work;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((ENTRIES < 2) || ((1 << INDEX_WIDTH) != ENTRIES))
            $fatal(1, "bimodal ENTRIES must be a power of two >= 2");
        if (COUNTER_BITS < 2)
            $fatal(1, "bimodal COUNTER_BITS must be >= 2");
        if ((UPDATE_DEPTH < 2) ||
            ((1 << UPDATE_PTR_WIDTH) != UPDATE_DEPTH))
            $fatal(1, "bimodal UPDATE_DEPTH must be a power of two >= 2");
    end
`endif

endmodule

`endif
