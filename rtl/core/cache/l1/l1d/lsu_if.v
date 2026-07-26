`timescale 1ns/1ps

// Preserves LSU request-tag order for requests which complete through the
// resident-hit/direct-response path. Detached demand misses leave this stream
// at admission and complete through the MSHR waiter table.
module openrv64_l1d_lsu_order #(
    parameter integer TAG_WIDTH = 1,
    parameter integer DEPTH = 8
) (
    input  wire                 clk_i,
    input  wire                 rst_ni,
    input  wire                 push_i,
    input  wire [TAG_WIDTH-1:0] push_tag_i,
    input  wire                 pop_i,
    output wire                 full_o,
    output wire                 empty_o,
    output wire [TAG_WIDTH-1:0] head_tag_o,
    output wire [$clog2(DEPTH + 1)-1:0] count_o
);

    localparam integer INDEX_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    localparam integer COUNT_WIDTH = $clog2(DEPTH + 1);

    reg [TAG_WIDTH-1:0] tag_q [0:DEPTH-1];
    reg [INDEX_WIDTH-1:0] head_q;
    reg [INDEX_WIDTH-1:0] tail_q;
    reg [COUNT_WIDTH-1:0] count_q;
    integer reset_index;

    assign full_o = count_q == COUNT_WIDTH'(DEPTH);
    assign empty_o = count_q == {COUNT_WIDTH{1'b0}};
    assign head_tag_o = tag_q[head_q];
    assign count_o = count_q;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            head_q <= {INDEX_WIDTH{1'b0}};
            tail_q <= {INDEX_WIDTH{1'b0}};
            count_q <= {COUNT_WIDTH{1'b0}};
            for (reset_index = 0; reset_index < DEPTH;
                 reset_index = reset_index + 1)
                tag_q[reset_index] <= {TAG_WIDTH{1'b0}};
        end else begin
            if (push_i) begin
                tag_q[tail_q] <= push_tag_i;
                tail_q <= (tail_q == INDEX_WIDTH'(DEPTH - 1)) ?
                    {INDEX_WIDTH{1'b0}} : tail_q + 1'b1;
            end
            if (pop_i)
                head_q <= (head_q == INDEX_WIDTH'(DEPTH - 1)) ?
                    {INDEX_WIDTH{1'b0}} : head_q + 1'b1;

            case ({push_i, pop_i})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (rst_ni && push_i && full_o && !pop_i) begin
            $error("L1D LSU order queue overflow");
            $fatal;
        end
        if (rst_ni && pop_i && empty_o) begin
            $error("L1D LSU order queue underflow");
            $fatal;
        end
    end
`endif

endmodule
