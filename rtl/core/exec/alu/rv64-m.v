`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"

module openrv64_exec_rv64m (
    input  wire [`RV64_ALU_OP_WIDTH-1:0] op_sel_i,
    input  wire                          word_op_i,
    input  wire [`RV64_XLEN-1:0]         src1_i,
    input  wire [`RV64_XLEN-1:0]         src2_i,

    output reg                           valid_o,
    output reg                           illegal_o,
    output reg [`RV64_XLEN-1:0]          result_o
);

    wire signed [127:0] mul_ss_lhs = {{64{src1_i[63]}}, src1_i};
    wire signed [127:0] mul_ss_rhs = {{64{src2_i[63]}}, src2_i};
    wire signed [127:0] mul_su_lhs = {{64{src1_i[63]}}, src1_i};
    wire signed [127:0] mul_su_rhs = {64'h0000_0000_0000_0000, src2_i};
    wire [127:0]        mul_uu_lhs = {64'h0000_0000_0000_0000, src1_i};
    wire [127:0]        mul_uu_rhs = {64'h0000_0000_0000_0000, src2_i};

    wire signed [127:0] mul_ss_result = mul_ss_lhs * mul_ss_rhs;
    wire signed [127:0] mul_su_result = mul_su_lhs * mul_su_rhs;
    wire [127:0]        mul_uu_result = mul_uu_lhs * mul_uu_rhs;

    function [`RV64_XLEN-1:0] sext_word;
        input [31:0] value;
        begin
            sext_word = {{32{value[31]}}, value};
        end
    endfunction

    function [`RV64_XLEN-1:0] signed_div_xlen;
        input signed [`RV64_XLEN-1:0] dividend;
        input signed [`RV64_XLEN-1:0] divisor;
        begin
            if (divisor == 64'sd0) begin
                signed_div_xlen = {`RV64_XLEN{1'b1}};
            end else if ((dividend == 64'sh8000_0000_0000_0000) &&
                         (divisor == -64'sd1)) begin
                signed_div_xlen = 64'h8000_0000_0000_0000;
            end else begin
                signed_div_xlen = dividend / divisor;
            end
        end
    endfunction

    function [`RV64_XLEN-1:0] signed_rem_xlen;
        input signed [`RV64_XLEN-1:0] dividend;
        input signed [`RV64_XLEN-1:0] divisor;
        begin
            if (divisor == 64'sd0) begin
                signed_rem_xlen = dividend;
            end else if ((dividend == 64'sh8000_0000_0000_0000) &&
                         (divisor == -64'sd1)) begin
                signed_rem_xlen = {`RV64_XLEN{1'b0}};
            end else begin
                signed_rem_xlen = dividend % divisor;
            end
        end
    endfunction

    function [`RV64_XLEN-1:0] unsigned_div_xlen;
        input [`RV64_XLEN-1:0] dividend;
        input [`RV64_XLEN-1:0] divisor;
        begin
            if (divisor == {`RV64_XLEN{1'b0}}) begin
                unsigned_div_xlen = {`RV64_XLEN{1'b1}};
            end else begin
                unsigned_div_xlen = dividend / divisor;
            end
        end
    endfunction

    function [`RV64_XLEN-1:0] unsigned_rem_xlen;
        input [`RV64_XLEN-1:0] dividend;
        input [`RV64_XLEN-1:0] divisor;
        begin
            if (divisor == {`RV64_XLEN{1'b0}}) begin
                unsigned_rem_xlen = dividend;
            end else begin
                unsigned_rem_xlen = dividend % divisor;
            end
        end
    endfunction

    function [31:0] signed_div_word;
        input signed [31:0] dividend;
        input signed [31:0] divisor;
        begin
            if (divisor == 32'sd0) begin
                signed_div_word = 32'hffff_ffff;
            end else if ((dividend == 32'sh8000_0000) &&
                         (divisor == -32'sd1)) begin
                signed_div_word = 32'h8000_0000;
            end else begin
                signed_div_word = dividend / divisor;
            end
        end
    endfunction

    function [31:0] signed_rem_word;
        input signed [31:0] dividend;
        input signed [31:0] divisor;
        begin
            if (divisor == 32'sd0) begin
                signed_rem_word = dividend;
            end else if ((dividend == 32'sh8000_0000) &&
                         (divisor == -32'sd1)) begin
                signed_rem_word = 32'h0000_0000;
            end else begin
                signed_rem_word = dividend % divisor;
            end
        end
    endfunction

    function [31:0] unsigned_div_word;
        input [31:0] dividend;
        input [31:0] divisor;
        begin
            if (divisor == 32'h0000_0000) begin
                unsigned_div_word = 32'hffff_ffff;
            end else begin
                unsigned_div_word = dividend / divisor;
            end
        end
    endfunction

    function [31:0] unsigned_rem_word;
        input [31:0] dividend;
        input [31:0] divisor;
        begin
            if (divisor == 32'h0000_0000) begin
                unsigned_rem_word = dividend;
            end else begin
                unsigned_rem_word = dividend % divisor;
            end
        end
    endfunction

    task automatic accept_xlen;
        input [`RV64_XLEN-1:0] value;
        begin
            valid_o   = 1'b1;
            illegal_o = 1'b0;
            result_o  = value;
        end
    endtask

    task automatic accept_word;
        input [31:0] value;
        begin
            accept_xlen(sext_word(value));
        end
    endtask

    always @* begin
        valid_o   = 1'b0;
        illegal_o = 1'b1;
        result_o  = {`RV64_XLEN{1'b0}};

        case (op_sel_i)
            `RV64_ALU_OP_MUL: begin
                if (word_op_i) begin
                    accept_word(src1_i[31:0] * src2_i[31:0]);
                end else begin
                    accept_xlen(mul_uu_result[63:0]);
                end
            end

            `RV64_ALU_OP_MULH: begin
                if (!word_op_i) begin
                    accept_xlen(mul_ss_result[127:64]);
                end
            end

            `RV64_ALU_OP_MULHSU: begin
                if (!word_op_i) begin
                    accept_xlen(mul_su_result[127:64]);
                end
            end

            `RV64_ALU_OP_MULHU: begin
                if (!word_op_i) begin
                    accept_xlen(mul_uu_result[127:64]);
                end
            end

            `RV64_ALU_OP_DIV: begin
                if (word_op_i) begin
                    accept_word(signed_div_word(src1_i[31:0], src2_i[31:0]));
                end else begin
                    accept_xlen(signed_div_xlen(src1_i, src2_i));
                end
            end

            `RV64_ALU_OP_DIVU: begin
                if (word_op_i) begin
                    accept_word(unsigned_div_word(src1_i[31:0], src2_i[31:0]));
                end else begin
                    accept_xlen(unsigned_div_xlen(src1_i, src2_i));
                end
            end

            `RV64_ALU_OP_REM: begin
                if (word_op_i) begin
                    accept_word(signed_rem_word(src1_i[31:0], src2_i[31:0]));
                end else begin
                    accept_xlen(signed_rem_xlen(src1_i, src2_i));
                end
            end

            `RV64_ALU_OP_REMU: begin
                if (word_op_i) begin
                    accept_word(unsigned_rem_word(src1_i[31:0], src2_i[31:0]));
                end else begin
                    accept_xlen(unsigned_rem_xlen(src1_i, src2_i));
                end
            end

            default: begin
            end
        endcase
    end

endmodule
