`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/decode/lsu-defs.v"

module openrv64_exec_lsu_rv64i (
    input  wire [`RV64_LSU_OP_WIDTH-1:0]  op_sel_i,
    input  wire [`RV64_XLEN-1:0]          base_i,
    input  wire [`RV64_XLEN-1:0]          offset_i,
    input  wire [`RV64_XLEN-1:0]          store_data_i,
    input  wire [`RV64_XLEN-1:0]          mem_rdata_i,

    output reg                            valid_o,
    output reg                            illegal_o,
    output reg                            misaligned_o,
    output reg [`RV64_XLEN-1:0]           load_data_o,

    output reg                            mem_valid_o,
    output reg                            mem_write_o,
    output reg [`RV64_XLEN-1:0]           mem_addr_o,
    output reg [`RV64_XLEN-1:0]           mem_wdata_o,
    output reg [7:0]                      mem_wstrb_o
);

    wire [`RV64_XLEN-1:0] effective_addr = base_i + offset_i;
    wire [2:0] byte_offset = effective_addr[2:0];
    wire [5:0] byte_shift = {byte_offset, 3'b000};
    wire [`RV64_XLEN-1:0] shifted_rdata = mem_rdata_i >> byte_shift;

    function [`RV64_XLEN-1:0] sext8;
        input [7:0] value;
        begin
            sext8 = {{56{value[7]}}, value};
        end
    endfunction

    function [`RV64_XLEN-1:0] sext16;
        input [15:0] value;
        begin
            sext16 = {{48{value[15]}}, value};
        end
    endfunction

    function [`RV64_XLEN-1:0] sext32;
        input [31:0] value;
        begin
            sext32 = {{32{value[31]}}, value};
        end
    endfunction

    task automatic accept_load;
        input [`RV64_LSU_SIZE_WIDTH-1:0] size_sel;
        input [`RV64_XLEN-1:0] load_data;
        begin
            valid_o       = 1'b1;
            illegal_o     = 1'b0;
            misaligned_o  = access_misaligned(size_sel, byte_offset);
            load_data_o   = load_data;
            mem_valid_o   = !misaligned_o;
            mem_write_o   = 1'b0;
            mem_addr_o    = {effective_addr[`RV64_XLEN-1:3], 3'b000};
            mem_wdata_o   = {`RV64_XLEN{1'b0}};
            mem_wstrb_o   = 8'h00;
        end
    endtask

    task automatic accept_store;
        input [`RV64_LSU_SIZE_WIDTH-1:0] size_sel;
        input [`RV64_XLEN-1:0] write_data;
        input [7:0] write_strobe;
        begin
            valid_o       = 1'b1;
            illegal_o     = 1'b0;
            misaligned_o  = access_misaligned(size_sel, byte_offset);
            load_data_o   = {`RV64_XLEN{1'b0}};
            mem_valid_o   = !misaligned_o;
            mem_write_o   = !misaligned_o;
            mem_addr_o    = {effective_addr[`RV64_XLEN-1:3], 3'b000};
            mem_wdata_o   = misaligned_o ? {`RV64_XLEN{1'b0}} : write_data;
            mem_wstrb_o   = misaligned_o ? 8'h00 : write_strobe;
        end
    endtask

    function access_misaligned;
        input [`RV64_LSU_SIZE_WIDTH-1:0] size_sel;
        input [2:0] offset;
        begin
            case (size_sel)
                `RV64_LSU_SIZE_BYTE:  access_misaligned = 1'b0;
                `RV64_LSU_SIZE_HALF:  access_misaligned = offset[0];
                `RV64_LSU_SIZE_WORD:  access_misaligned = |offset[1:0];
                `RV64_LSU_SIZE_DWORD: access_misaligned = |offset;
                default:              access_misaligned = 1'b1;
            endcase
        end
    endfunction

    always @* begin
        valid_o      = 1'b0;
        illegal_o    = 1'b1;
        misaligned_o = 1'b0;
        load_data_o  = {`RV64_XLEN{1'b0}};
        mem_valid_o  = 1'b0;
        mem_write_o  = 1'b0;
        mem_addr_o   = {effective_addr[`RV64_XLEN-1:3], 3'b000};
        mem_wdata_o  = {`RV64_XLEN{1'b0}};
        mem_wstrb_o  = 8'h00;

        case (op_sel_i)
            `RV64_LSU_OP_LB: begin
                accept_load(`RV64_LSU_SIZE_BYTE, sext8(shifted_rdata[7:0]));
            end

            `RV64_LSU_OP_LH: begin
                accept_load(`RV64_LSU_SIZE_HALF, sext16(shifted_rdata[15:0]));
            end

            `RV64_LSU_OP_LW: begin
                accept_load(`RV64_LSU_SIZE_WORD, sext32(shifted_rdata[31:0]));
            end

            `RV64_LSU_OP_LD: begin
                accept_load(`RV64_LSU_SIZE_DWORD, shifted_rdata);
            end

            `RV64_LSU_OP_LBU: begin
                accept_load(`RV64_LSU_SIZE_BYTE, {{56{1'b0}}, shifted_rdata[7:0]});
            end

            `RV64_LSU_OP_LHU: begin
                accept_load(`RV64_LSU_SIZE_HALF, {{48{1'b0}}, shifted_rdata[15:0]});
            end

            `RV64_LSU_OP_LWU: begin
                accept_load(`RV64_LSU_SIZE_WORD, {{32{1'b0}}, shifted_rdata[31:0]});
            end

            `RV64_LSU_OP_SB: begin
                accept_store(`RV64_LSU_SIZE_BYTE,
                             {{56{1'b0}}, store_data_i[7:0]} << byte_shift,
                             8'h01 << byte_offset);
            end

            `RV64_LSU_OP_SH: begin
                accept_store(`RV64_LSU_SIZE_HALF,
                             {{48{1'b0}}, store_data_i[15:0]} << byte_shift,
                             8'h03 << byte_offset);
            end

            `RV64_LSU_OP_SW: begin
                accept_store(`RV64_LSU_SIZE_WORD,
                             {{32{1'b0}}, store_data_i[31:0]} << byte_shift,
                             8'h0f << byte_offset);
            end

            `RV64_LSU_OP_SD: begin
                accept_store(`RV64_LSU_SIZE_DWORD,
                             store_data_i,
                             8'hff);
            end

            default: begin
            end
        endcase
    end

endmodule
