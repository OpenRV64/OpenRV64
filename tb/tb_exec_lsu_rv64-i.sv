`timescale 1ns/1ps
`include "core/exec/lsu/rv64-i.v"
`timescale 1ns/1ps

module tb_exec_lsu_rv64i;

    logic [`RV64_LSU_OP_WIDTH-1:0] op_sel;
    logic [`RV64_XLEN-1:0]         base;
    logic [`RV64_XLEN-1:0]         offset;
    logic [`RV64_XLEN-1:0]         store_data;
    logic [`RV64_XLEN-1:0]         mem_rdata;
    logic                          valid;
    logic                          illegal;
    logic                          misaligned;
    logic [`RV64_XLEN-1:0]         load_data;
    logic                          mem_valid;
    logic                          mem_write;
    logic [`RV64_XLEN-1:0]         mem_addr;
    logic [`RV64_XLEN-1:0]         mem_wdata;
    logic [7:0]                    mem_wstrb;

    openrv64_exec_lsu_rv64i dut (
        .op_sel_i(op_sel),
        .base_i(base),
        .offset_i(offset),
        .store_data_i(store_data),
        .mem_rdata_i(mem_rdata),
        .valid_o(valid),
        .illegal_o(illegal),
        .misaligned_o(misaligned),
        .load_data_o(load_data),
        .mem_valid_o(mem_valid),
        .mem_write_o(mem_write),
        .mem_addr_o(mem_addr),
        .mem_wdata_o(mem_wdata),
        .mem_wstrb_o(mem_wstrb)
    );

    task automatic check;
        input [`RV64_LSU_OP_WIDTH-1:0] in_op_sel;
        input [`RV64_XLEN-1:0]         in_base;
        input [`RV64_XLEN-1:0]         in_offset;
        input [`RV64_XLEN-1:0]         in_store_data;
        input [`RV64_XLEN-1:0]         in_mem_rdata;
        input                          exp_valid;
        input                          exp_illegal;
        input                          exp_misaligned;
        input [`RV64_XLEN-1:0]         exp_load_data;
        input                          exp_mem_valid;
        input                          exp_mem_write;
        input [`RV64_XLEN-1:0]         exp_mem_addr;
        input [`RV64_XLEN-1:0]         exp_mem_wdata;
        input [7:0]                    exp_mem_wstrb;
        input [8*40-1:0]               label;
        begin
            op_sel = in_op_sel;
            base = in_base;
            offset = in_offset;
            store_data = in_store_data;
            mem_rdata = in_mem_rdata;
            #1;

            if (valid !== exp_valid ||
                illegal !== exp_illegal ||
                misaligned !== exp_misaligned ||
                load_data !== exp_load_data ||
                mem_valid !== exp_mem_valid ||
                mem_write !== exp_mem_write ||
                mem_addr !== exp_mem_addr ||
                mem_wdata !== exp_mem_wdata ||
                mem_wstrb !== exp_mem_wstrb) begin
                $fatal(1,
                    "%0s: valid=%0b/%0b illegal=%0b/%0b misaligned=%0b/%0b load=%016x/%016x mem_valid=%0b/%0b mem_write=%0b/%0b addr=%016x/%016x wdata=%016x/%016x wstrb=%02x/%02x",
                    label, valid, exp_valid, illegal, exp_illegal,
                    misaligned, exp_misaligned, load_data, exp_load_data,
                    mem_valid, exp_mem_valid, mem_write, exp_mem_write,
                    mem_addr, exp_mem_addr, mem_wdata, exp_mem_wdata,
                    mem_wstrb, exp_mem_wstrb);
            end
        end
    endtask

    initial begin
        check(`RV64_LSU_OP_LB,
              64'h0000_0000_0000_1007, 64'h0, 64'h0, 64'h8877_6655_4433_2211,
              1'b1, 1'b0, 1'b0, 64'hffff_ffff_ffff_ff88,
              1'b1, 1'b0, 64'h0000_0000_0000_1000, 64'h0, 8'h00, "lb sign extend");

        check(`RV64_LSU_OP_LBU,
              64'h0000_0000_0000_1007, 64'h0, 64'h0, 64'h8877_6655_4433_2211,
              1'b1, 1'b0, 1'b0, 64'h0000_0000_0000_0088,
              1'b1, 1'b0, 64'h0000_0000_0000_1000, 64'h0, 8'h00, "lbu zero extend");

        check(`RV64_LSU_OP_LH,
              64'h0000_0000_0000_1006, 64'h0, 64'h0, 64'h8877_6655_4433_2211,
              1'b1, 1'b0, 1'b0, 64'hffff_ffff_ffff_8877,
              1'b1, 1'b0, 64'h0000_0000_0000_1000, 64'h0, 8'h00, "lh sign extend");

        check(`RV64_LSU_OP_LHU,
              64'h0000_0000_0000_1006, 64'h0, 64'h0, 64'h8877_6655_4433_2211,
              1'b1, 1'b0, 1'b0, 64'h0000_0000_0000_8877,
              1'b1, 1'b0, 64'h0000_0000_0000_1000, 64'h0, 8'h00, "lhu zero extend");

        check(`RV64_LSU_OP_LW,
              64'h0000_0000_0000_1004, 64'h0, 64'h0, 64'h8877_6655_4433_2211,
              1'b1, 1'b0, 1'b0, 64'hffff_ffff_8877_6655,
              1'b1, 1'b0, 64'h0000_0000_0000_1000, 64'h0, 8'h00, "lw sign extend");

        check(`RV64_LSU_OP_LWU,
              64'h0000_0000_0000_1004, 64'h0, 64'h0, 64'h8877_6655_4433_2211,
              1'b1, 1'b0, 1'b0, 64'h0000_0000_8877_6655,
              1'b1, 1'b0, 64'h0000_0000_0000_1000, 64'h0, 8'h00, "lwu zero extend");

        check(`RV64_LSU_OP_LD,
              64'h0000_0000_0000_1000, 64'h0, 64'h0, 64'h8877_6655_4433_2211,
              1'b1, 1'b0, 1'b0, 64'h8877_6655_4433_2211,
              1'b1, 1'b0, 64'h0000_0000_0000_1000, 64'h0, 8'h00, "ld");

        check(`RV64_LSU_OP_SB,
              64'h0000_0000_0000_1005, 64'h0, 64'h0000_0000_0000_00aa, 64'h0,
              1'b1, 1'b0, 1'b0, 64'h0,
              1'b1, 1'b1, 64'h0000_0000_0000_1000, 64'h0000_aa00_0000_0000, 8'h20, "sb");

        check(`RV64_LSU_OP_SH,
              64'h0000_0000_0000_1004, 64'h0, 64'h0000_0000_0000_beef, 64'h0,
              1'b1, 1'b0, 1'b0, 64'h0,
              1'b1, 1'b1, 64'h0000_0000_0000_1000, 64'h0000_beef_0000_0000, 8'h30, "sh");

        check(`RV64_LSU_OP_SW,
              64'h0000_0000_0000_1004, 64'h0, 64'h0000_0000_dead_beef, 64'h0,
              1'b1, 1'b0, 1'b0, 64'h0,
              1'b1, 1'b1, 64'h0000_0000_0000_1000, 64'hdead_beef_0000_0000, 8'hf0, "sw");

        check(`RV64_LSU_OP_SD,
              64'h0000_0000_0000_1000, 64'h0, 64'h0123_4567_89ab_cdef, 64'h0,
              1'b1, 1'b0, 1'b0, 64'h0,
              1'b1, 1'b1, 64'h0000_0000_0000_1000, 64'h0123_4567_89ab_cdef, 8'hff, "sd");

        check(`RV64_LSU_OP_LH,
              64'h0000_0000_0000_1001, 64'h0, 64'h0, 64'h8877_6655_4433_2211,
              1'b1, 1'b0, 1'b1, 64'h0000_0000_0000_3322,
              1'b0, 1'b0, 64'h0000_0000_0000_1000, 64'h0, 8'h00, "misaligned lh");

        check(`RV64_LSU_OP_SW,
              64'h0000_0000_0000_1002, 64'h0, 64'h0000_0000_dead_beef, 64'h0,
              1'b1, 1'b0, 1'b1, 64'h0,
              1'b0, 1'b0, 64'h0000_0000_0000_1000, 64'h0, 8'h00, "misaligned sw");

        check(`RV64_LSU_OP_INVALID,
              64'h0000_0000_0000_1000, 64'h0, 64'h0, 64'h0,
              1'b0, 1'b1, 1'b0, 64'h0,
              1'b0, 1'b0, 64'h0000_0000_0000_1000, 64'h0, 8'h00, "invalid op");

        $display("PASS: RV64I LSU execute");
        $finish;
    end

endmodule
