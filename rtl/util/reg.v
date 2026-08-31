`timescale 1ns/1ps

// Base register definition intended to be inferrable for both synth and fpga.

module cmn_reg #(
    parameter integer REG_WIDTH = 64
) (
    input wire clk,
    input wire [REG_WIDTH-1:0] write_val_i,
    input wire write_en_i,
    output wire [REG_WIDTH-1:0] read_val_o,
    input wire read_en_i
);

    reg [REG_WIDTH-1:0] value;

    assign read_val_o = value;

    always @(posedge clk) begin
        if (write_en_i)
           value <= write_val_i;
    end

endmodule
