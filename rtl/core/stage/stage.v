`timescale 1ns/1ps

module openrv64_stage #(
    parameter WIDTH = 1,
    parameter REGISTERED = 1
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

    generate
        if (REGISTERED != 0) begin : g_registered
            reg             active_q;
            reg [WIDTH-1:0] data_q;

            assign in_clear_o = !active_q || out_clear_i;
            // A registered stage flush is a clock-edge operation.  Do not
            // poison the current-cycle payload or validity combinationally;
            // control-event logic inhibits irreversible issue during that
            // cycle, and active_q becomes clear after the edge.
            assign out_valid_o = active_q;
            assign out_data_o = data_q;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    active_q <= 1'b0;
                    data_q   <= {WIDTH{1'b0}};
                end else if (flush_i) begin
                    active_q <= 1'b0;
                end else if (in_clear_o) begin
                    active_q <= in_valid_i;

                    if (in_valid_i) begin
                        data_q <= in_data_i;
                    end
                end
            end
        end else begin : g_bypass
            assign in_clear_o = flush_i || out_clear_i;
            assign out_valid_o = in_valid_i && !flush_i;
            assign out_data_o = out_valid_o ? in_data_i : {WIDTH{1'b0}};
        end
    endgenerate

endmodule
