`timescale 1ns/1ps
`include "core/exec/lsu/rv64-a.v"

module tb_exec_lsu_rv64a;
    logic clk, rst_n, flush, valid, consume, clear_reservation;
    logic [`RV64_LSU_OP_WIDTH-1:0] op;
    logic [`RV64_LSU_SIZE_WIDTH-1:0] size_sel;
    logic [`RV64_XLEN-1:0] addr, store_data;
    logic mem_ready, mem_error, mem_page_fault, mem_access_allowed;
    logic [`RV64_XLEN-1:0] mem_rdata;
    logic complete, illegal, misaligned, access_fault, page_fault;
    logic [`RV64_XLEN-1:0] result;
    logic mem_valid, mem_write;
    logic [`RV64_XLEN-1:0] mem_addr, mem_wdata;
    logic [7:0] mem_wstrb;

    openrv64_exec_lsu_rv64a dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush), .valid_i(valid),
        .consume_i(consume), .clear_reservation_i(clear_reservation),
        .op_sel_i(op), .size_sel_i(size_sel), .addr_i(addr),
        .store_data_i(store_data), .mem_ready_i(mem_ready),
        .mem_error_i(mem_error), .mem_page_fault_i(mem_page_fault),
        .mem_access_allowed_i(mem_access_allowed), .mem_rdata_i(mem_rdata),
        .complete_o(complete), .illegal_o(illegal),
        .misaligned_o(misaligned), .access_fault_o(access_fault),
        .page_fault_o(page_fault), .result_o(result),
        .mem_valid_o(mem_valid), .mem_write_o(mem_write),
        .mem_addr_o(mem_addr), .mem_wdata_o(mem_wdata),
        .mem_wstrb_o(mem_wstrb)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic issue;
        input [`RV64_LSU_OP_WIDTH-1:0] in_op;
        input [`RV64_LSU_SIZE_WIDTH-1:0] in_size;
        input [`RV64_XLEN-1:0] in_addr;
        input [`RV64_XLEN-1:0] in_data;
        begin
            @(negedge clk);
            op = in_op; size_sel = in_size; addr = in_addr;
            store_data = in_data; valid = 1'b1;
        end
    endtask

    task automatic wait_request;
        input exp_write;
        input [`RV64_XLEN-1:0] exp_addr, exp_wdata;
        input [7:0] exp_wstrb;
        input [8*36-1:0] label;
        integer cycles;
        begin
            cycles = 0;
            while (!mem_valid && cycles < 16) begin
                @(negedge clk); cycles = cycles + 1;
            end
            if (!mem_valid) $fatal(1, "%0s: request timeout", label);
            if (mem_write !== exp_write || mem_addr !== exp_addr ||
                (exp_write && ((mem_wdata !== exp_wdata) ||
                               (mem_wstrb !== exp_wstrb)))) begin
                $fatal(1,
                    "%0s: write=%0b/%0b addr=%016x/%016x data=%016x/%016x strb=%02x/%02x",
                    label, mem_write, exp_write, mem_addr, exp_addr,
                    mem_wdata, exp_wdata, mem_wstrb, exp_wstrb);
            end
        end
    endtask

    task automatic respond;
        input [`RV64_XLEN-1:0] rdata;
        input error, fault;
        begin
            @(negedge clk);
            mem_rdata = rdata; mem_error = error;
            mem_page_fault = fault; mem_ready = 1'b1;
            @(negedge clk);
            mem_ready = 1'b0; mem_error = 1'b0;
            mem_page_fault = 1'b0; mem_rdata = 64'd0;
        end
    endtask

    task automatic expect_complete;
        input [`RV64_XLEN-1:0] exp_result;
        input exp_illegal, exp_misaligned, exp_access, exp_page;
        input [8*36-1:0] label;
        integer cycles;
        begin
            cycles = 0;
            while (!complete && cycles < 16) begin
                @(negedge clk); cycles = cycles + 1;
            end
            if (!complete || result !== exp_result || illegal !== exp_illegal ||
                misaligned !== exp_misaligned || access_fault !== exp_access ||
                page_fault !== exp_page || mem_valid) begin
                $fatal(1,
                    "%0s: complete=%0b result=%016x/%016x ill=%0b/%0b align=%0b/%0b access=%0b/%0b page=%0b/%0b mem=%0b",
                    label, complete, result, exp_result, illegal, exp_illegal,
                    misaligned, exp_misaligned, access_fault, exp_access,
                    page_fault, exp_page, mem_valid);
            end
        end
    endtask

    task automatic consume_result;
        begin
            @(negedge clk); consume = 1'b1;
            @(negedge clk); consume = 1'b0; valid = 1'b0;
        end
    endtask

    task automatic run_amo_d;
        input [`RV64_LSU_OP_WIDTH-1:0] in_op;
        input [`RV64_XLEN-1:0] old_value, operand, new_value;
        input [8*36-1:0] label;
        begin
            issue(in_op, `RV64_LSU_SIZE_DWORD, 64'h200, operand);
            wait_request(1'b0, 64'h200, 64'd0, 8'h00, label);
            respond(old_value, 1'b0, 1'b0);
            wait_request(1'b1, 64'h200, new_value, 8'hff, label);
            respond(64'd0, 1'b0, 1'b0);
            expect_complete(old_value, 1'b0, 1'b0, 1'b0, 1'b0, label);
            consume_result();
        end
    endtask

    initial begin
        rst_n = 1'b0; flush = 1'b0; valid = 1'b0; consume = 1'b0;
        clear_reservation = 1'b0; op = `RV64_LSU_OP_INVALID;
        size_sel = `RV64_LSU_SIZE_WORD; addr = 64'd0; store_data = 64'd0;
        mem_ready = 1'b0; mem_error = 1'b0; mem_page_fault = 1'b0;
        mem_access_allowed = 1'b1; mem_rdata = 64'd0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        issue(`RV64_LSU_OP_LR, `RV64_LSU_SIZE_WORD, 64'h104, 64'd0);
        wait_request(1'b0, 64'h104, 64'd0, 8'h00, "lr.w read");
        repeat (2) begin
            @(negedge clk);
            if (!mem_valid || mem_addr != 64'h104 || mem_write)
                $fatal(1, "lr.w request changed under backpressure");
        end
        respond(64'h8000_0001_dead_beef, 1'b0, 1'b0);
        expect_complete(64'hffff_ffff_8000_0001,
                        1'b0, 1'b0, 1'b0, 1'b0, "lr.w result");
        consume_result();

        issue(`RV64_LSU_OP_SC, `RV64_LSU_SIZE_WORD, 64'h104,
              64'h1234_5678_aabb_ccdd);
        wait_request(1'b1, 64'h104, 64'haabb_ccdd_0000_0000,
                     8'hf0, "sc.w success write");
        respond(64'd0, 1'b0, 1'b0);
        expect_complete(64'd0, 1'b0, 1'b0, 1'b0, 1'b0, "sc.w success");
        consume_result();
        issue(`RV64_LSU_OP_SC, `RV64_LSU_SIZE_WORD, 64'h104, 64'h55);
        expect_complete(64'd1, 1'b0, 1'b0, 1'b0, 1'b0, "sc.w consumed");
        consume_result();

        issue(`RV64_LSU_OP_LR, `RV64_LSU_SIZE_DWORD, 64'h208, 64'd0);
        wait_request(1'b0, 64'h208, 64'd0, 8'h00, "lr.d read");
        respond(64'h0123_4567_89ab_cdef, 1'b0, 1'b0);
        expect_complete(64'h0123_4567_89ab_cdef,
                        1'b0, 1'b0, 1'b0, 1'b0, "lr.d result");
        consume_result();
        @(negedge clk); clear_reservation = 1'b1;
        @(negedge clk); clear_reservation = 1'b0;
        issue(`RV64_LSU_OP_SC, `RV64_LSU_SIZE_DWORD, 64'h208, 64'h55);
        expect_complete(64'd1, 1'b0, 1'b0, 1'b0, 1'b0, "sc.d invalidated");
        consume_result();

        run_amo_d(`RV64_LSU_OP_AMOSWAP, 64'h11, 64'h80, 64'h80, "amoswap.d");
        run_amo_d(`RV64_LSU_OP_AMOADD, 64'h11, 64'h20, 64'h31, "amoadd.d");
        run_amo_d(`RV64_LSU_OP_AMOXOR, 64'hf0, 64'h5a, 64'haa, "amoxor.d");
        run_amo_d(`RV64_LSU_OP_AMOAND, 64'hf3, 64'h5a, 64'h52, "amoand.d");
        run_amo_d(`RV64_LSU_OP_AMOOR, 64'hf0, 64'h5a, 64'hfa, "amoor.d");
        run_amo_d(`RV64_LSU_OP_AMOMIN, 64'hffff_ffff_ffff_fffe,
                  64'd3, 64'hffff_ffff_ffff_fffe, "amomin.d");
        run_amo_d(`RV64_LSU_OP_AMOMAX, 64'hffff_ffff_ffff_fffe,
                  64'd3, 64'd3, "amomax.d");
        run_amo_d(`RV64_LSU_OP_AMOMINU, 64'hffff_ffff_ffff_fffe,
                  64'd3, 64'd3, "amominu.d");
        run_amo_d(`RV64_LSU_OP_AMOMAXU, 64'hffff_ffff_ffff_fffe,
                  64'd3, 64'hffff_ffff_ffff_fffe, "amomaxu.d");

        issue(`RV64_LSU_OP_AMOADD, `RV64_LSU_SIZE_WORD, 64'h204, 64'd2);
        wait_request(1'b0, 64'h204, 64'd0, 8'h00, "amoadd.w read");
        respond(64'hffff_ffff_1234_5678, 1'b0, 1'b0);
        wait_request(1'b1, 64'h204, 64'h0000_0001_0000_0000,
                     8'hf0, "amoadd.w write");
        respond(64'd0, 1'b0, 1'b0);
        expect_complete(64'hffff_ffff_ffff_ffff,
                        1'b0, 1'b0, 1'b0, 1'b0, "amoadd.w result");
        consume_result();

        issue(`RV64_LSU_OP_LR, `RV64_LSU_SIZE_DWORD, 64'h203, 64'd0);
        expect_complete(64'd0, 1'b0, 1'b1, 1'b0, 1'b0, "lr.d misaligned");
        consume_result();
        mem_access_allowed = 1'b0;
        issue(`RV64_LSU_OP_AMOADD, `RV64_LSU_SIZE_DWORD, 64'h200, 64'd1);
        expect_complete(64'd0, 1'b0, 1'b0, 1'b1, 1'b0, "amo denied");
        consume_result();
        mem_access_allowed = 1'b1;

        issue(`RV64_LSU_OP_AMOADD, `RV64_LSU_SIZE_DWORD, 64'h200, 64'd1);
        wait_request(1'b0, 64'h200, 64'd0, 8'h00, "amo read fault");
        respond(64'd0, 1'b1, 1'b0);
        expect_complete(64'd0, 1'b0, 1'b0, 1'b1, 1'b0, "amo read fault");
        consume_result();
        issue(`RV64_LSU_OP_AMOADD, `RV64_LSU_SIZE_DWORD, 64'h200, 64'd1);
        wait_request(1'b0, 64'h200, 64'd0, 8'h00, "amo page read");
        respond(64'd9, 1'b0, 1'b0);
        wait_request(1'b1, 64'h200, 64'd10, 8'hff, "amo page write");
        respond(64'd0, 1'b0, 1'b1);
        expect_complete(64'd9, 1'b0, 1'b0, 1'b0, 1'b1, "amo write page");
        consume_result();

        $display("PASS: serialized RV64A LSU");
        $finish;
    end
endmodule
