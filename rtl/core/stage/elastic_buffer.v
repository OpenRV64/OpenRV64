`timescale 1ns/1ps

// Two-entry elastic buffer with registered upstream capacity.
//
// Unlike a conventional fall-through skid buffer, in_clear_o does not depend
// on out_clear_i.  That deliberately breaks downstream combinational
// backpressure while the second entry preserves one-transfer-per-cycle
// throughput whenever occupancy remains below two.
module openrv64_elastic_buffer #(
    parameter WIDTH = 1
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             flush_i,

    input  wire             in_valid_i,
    output wire             in_clear_o,
    input  wire [WIDTH-1:0] in_data_i,

    output wire             out_valid_o,
    input  wire             out_clear_i,
    output wire [WIDTH-1:0] out_data_o
);

    reg [1:0] count_q;
    reg [WIDTH-1:0] head_q;
    reg [WIDTH-1:0] tail_q;

    assign in_clear_o = flush_i || (count_q != 2'd2);
    assign out_valid_o = (count_q != 2'd0);
    assign out_data_o = head_q;

    wire push = in_valid_i && in_clear_o && !flush_i;
    wire pop = out_valid_o && out_clear_i && !flush_i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count_q <= 2'd0;
            head_q <= {WIDTH{1'b0}};
            tail_q <= {WIDTH{1'b0}};
        end else if (flush_i) begin
            count_q <= 2'd0;
        end else begin
            case ({push, pop})
                2'b10: begin
                    if (count_q == 2'd0)
                        head_q <= in_data_i;
                    else
                        tail_q <= in_data_i;
                    count_q <= count_q + 2'd1;
                end
                2'b01: begin
                    if (count_q == 2'd2)
                        head_q <= tail_q;
                    count_q <= count_q - 2'd1;
                end
                2'b11: begin
                    // push and pop can coincide only at occupancy one because
                    // a full queue keeps in_clear_o low for the whole cycle.
                    head_q <= in_data_i;
                end
                default: begin
                    count_q <= count_q;
                end
            endcase
        end
    end

endmodule
