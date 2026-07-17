`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/defs/alu-defs.v"

module openrv64_exec_alu_rv64i (
    input  wire [`RV64_ALU_OP_WIDTH-1:0] op_sel_i,
    input  wire                          word_op_i,
    input  wire [`RV64_XLEN-1:0]         src1_i,
    input  wire [`RV64_XLEN-1:0]         src2_i,
    input  wire [`RV64_XLEN-1:0]         pc_i,

    output reg                           valid_o,
    output reg                           illegal_o,
    output reg [`RV64_XLEN-1:0]          result_o
);

    function [`RV64_XLEN-1:0] sext_word;
        input [31:0] value;
        begin
            sext_word = {{32{value[31]}}, value};
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
            `RV64_ALU_OP_ADD: begin
                if (word_op_i) begin
                    accept_word(src1_i[31:0] + src2_i[31:0]);
                end else begin
                    accept_xlen(src1_i + src2_i);
                end
            end

            `RV64_ALU_OP_SUB: begin
                if (word_op_i) begin
                    accept_word(src1_i[31:0] - src2_i[31:0]);
                end else begin
                    accept_xlen(src1_i - src2_i);
                end
            end

            `RV64_ALU_OP_SLL: begin
                if (word_op_i) begin
                    accept_word(src1_i[31:0] << src2_i[4:0]);
                end else begin
                    accept_xlen(src1_i << src2_i[5:0]);
                end
            end

            `RV64_ALU_OP_SLT: begin
                if (!word_op_i) begin
                    accept_xlen(($signed(src1_i) < $signed(src2_i)) ?
                                {{(`RV64_XLEN-1){1'b0}}, 1'b1} :
                                {`RV64_XLEN{1'b0}});
                end
            end

            `RV64_ALU_OP_SLTU: begin
                if (!word_op_i) begin
                    accept_xlen((src1_i < src2_i) ?
                                {{(`RV64_XLEN-1){1'b0}}, 1'b1} :
                                {`RV64_XLEN{1'b0}});
                end
            end

            `RV64_ALU_OP_XOR: begin
                if (!word_op_i) begin
                    accept_xlen(src1_i ^ src2_i);
                end
            end

            `RV64_ALU_OP_SRL: begin
                if (word_op_i) begin
                    accept_word(src1_i[31:0] >> src2_i[4:0]);
                end else begin
                    accept_xlen(src1_i >> src2_i[5:0]);
                end
            end

            `RV64_ALU_OP_SRA: begin
                if (word_op_i) begin
                    accept_word($signed(src1_i[31:0]) >>> src2_i[4:0]);
                end else begin
                    accept_xlen($signed(src1_i) >>> src2_i[5:0]);
                end
            end

            `RV64_ALU_OP_OR: begin
                if (!word_op_i) begin
                    accept_xlen(src1_i | src2_i);
                end
            end

            `RV64_ALU_OP_AND: begin
                if (!word_op_i) begin
                    accept_xlen(src1_i & src2_i);
                end
            end

            `RV64_ALU_OP_LUI: begin
                if (!word_op_i) begin
                    accept_xlen(src2_i);
                end
            end

            `RV64_ALU_OP_AUIPC: begin
                if (!word_op_i) begin
                    accept_xlen(pc_i + src2_i);
                end
            end

            default: begin
            end
        endcase
    end

endmodule
