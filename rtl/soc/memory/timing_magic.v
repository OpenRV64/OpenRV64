`timescale 1ns/1ps

// Idealized one-cycle memory timing backend.
//
// A command accepted in cycle N produces a registered response in cycle N+1.
// The single elastic response slot permits one command per cycle when the
// consumer is ready and holds RESP_VALID stable under backpressure.  Address,
// direction, and byte count deliberately have no timing effect.
module openrv64_timing_magic #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer TAG_WIDTH = 8
) (
    input  wire                  clk_i,
    input  wire                  rst_ni,

    input  wire                  cmd_valid_i,
    output wire                  cmd_ready_o,
    input  wire                  cmd_write_i,
    input  wire [ADDR_WIDTH-1:0] cmd_addr_i,
    input  wire [15:0]           cmd_bytes_i,
    input  wire [TAG_WIDTH-1:0]  cmd_tag_i,

    output wire                  resp_valid_o,
    output wire [TAG_WIDTH-1:0]  resp_tag_o,
    input  wire                  resp_ready_i
);

    reg response_valid_q;
    reg [TAG_WIDTH-1:0] response_tag_q;

    assign cmd_ready_o = rst_ni &&
                         (!response_valid_q || resp_ready_i);
    assign resp_valid_o = response_valid_q;
    assign resp_tag_o = response_tag_q;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            response_valid_q <= 1'b0;
            response_tag_q <= {TAG_WIDTH{1'b0}};
        end else if (cmd_ready_o) begin
            response_valid_q <= cmd_valid_i;
            if (cmd_valid_i)
                response_tag_q <= cmd_tag_i;
        end
    end

    wire unused_command = ^{cmd_write_i, cmd_addr_i, cmd_bytes_i};

endmodule
