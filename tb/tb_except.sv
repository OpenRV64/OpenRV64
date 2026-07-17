`timescale 1ns/1ps
`include "core/except/except.v"
`timescale 1ns/1ps

module tb_except;

    logic illegal_instr;
    logic instr_misaligned;
    logic instr_access_fault;
    logic instr_page_fault;
    logic load_misaligned;
    logic load_access_fault;
    logic load_page_fault;
    logic store_misaligned;
    logic store_access_fault;
    logic store_page_fault;
    logic ecall;
    logic ebreak;
    logic [`RV64_XLEN-1:0] pc;
    logic [`RV64_INSTR_WIDTH-1:0] instr;
    logic [`RV64_XLEN-1:0] badaddr;
    logic [`RV64_PRIV_WIDTH-1:0] priv_mode;
    logic exception;
    logic halt;
    logic [`RV64_EXCEPT_CAUSE_WIDTH-1:0] cause;
    logic [`RV64_XLEN-1:0] tval;

    openrv64_except dut (
        .illegal_instr_i(illegal_instr),
        .instr_misaligned_i(instr_misaligned),
        .instr_access_fault_i(instr_access_fault),
        .instr_page_fault_i(instr_page_fault),
        .load_misaligned_i(load_misaligned),
        .load_access_fault_i(load_access_fault),
        .load_page_fault_i(load_page_fault),
        .store_misaligned_i(store_misaligned),
        .store_access_fault_i(store_access_fault),
        .store_page_fault_i(store_page_fault),
        .ecall_i(ecall),
        .ebreak_i(ebreak),
        .priv_mode_i(priv_mode),
        .pc_i(pc),
        .instr_i(instr),
        .badaddr_i(badaddr),
        .exception_o(exception),
        .halt_o(halt),
        .cause_o(cause),
        .tval_o(tval)
    );

    task automatic check;
        input in_illegal_instr;
        input in_instr_misaligned;
        input in_load_misaligned;
        input in_store_misaligned;
        input in_ecall;
        input in_ebreak;
        input exp_exception;
        input exp_halt;
        input [`RV64_EXCEPT_CAUSE_WIDTH-1:0] exp_cause;
        input [`RV64_XLEN-1:0] exp_tval;
        input [8*32-1:0] label;
        begin
            illegal_instr = in_illegal_instr;
            instr_misaligned = in_instr_misaligned;
            instr_access_fault = 1'b0;
            instr_page_fault = 1'b0;
            load_misaligned = in_load_misaligned;
            load_access_fault = 1'b0;
            load_page_fault = 1'b0;
            store_misaligned = in_store_misaligned;
            store_access_fault = 1'b0;
            store_page_fault = 1'b0;
            ecall = in_ecall;
            ebreak = in_ebreak;
            priv_mode = `RV64_PRIV_M;
            pc = 64'h0000_0000_0000_1002;
            instr = 32'hdead_beef;
            badaddr = 64'h0000_0000_0000_2003;
            #1;

            if (exception !== exp_exception ||
                halt !== exp_halt ||
                cause !== exp_cause ||
                tval !== exp_tval) begin
                $fatal(1,
                    "%0s: exception=%0b/%0b halt=%0b/%0b cause=%0d/%0d tval=%016x/%016x",
                    label, exception, exp_exception, halt, exp_halt, cause, exp_cause, tval, exp_tval);
            end
        end
    endtask

    initial begin
        check(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0,
              1'b0, 1'b0, `RV64_EXCEPT_CAUSE_INSTR_ADDR_MISALIGNED, 64'h0, "none");
        check(1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0,
              1'b1, 1'b0, `RV64_EXCEPT_CAUSE_INSTR_ADDR_MISALIGNED, 64'h1002, "instruction misaligned");
        check(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0,
              1'b1, 1'b0, `RV64_EXCEPT_CAUSE_ILLEGAL_INSTR, 64'h0000_0000_dead_beef, "illegal instruction");
        check(1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0,
              1'b1, 1'b0, `RV64_EXCEPT_CAUSE_LOAD_ADDR_MISALIGNED, 64'h2003, "load misaligned");
        check(1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0,
              1'b1, 1'b0, `RV64_EXCEPT_CAUSE_STORE_ADDR_MISALIGNED, 64'h2003, "store misaligned");
        check(1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0,
              1'b1, 1'b0, `RV64_EXCEPT_CAUSE_ECALL_M, 64'h0, "ecall");

        priv_mode = `RV64_PRIV_U;
        #1;
        if (!exception || cause != `RV64_EXCEPT_CAUSE_ECALL_U) begin
            $fatal(1, "U-mode ECALL cause mismatch");
        end

        priv_mode = `RV64_PRIV_S;
        #1;
        if (!exception || cause != `RV64_EXCEPT_CAUSE_ECALL_S) begin
            $fatal(1, "S-mode ECALL cause mismatch");
        end

        priv_mode = `RV64_PRIV_M;
        check(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1,
              1'b1, 1'b1, `RV64_EXCEPT_CAUSE_BREAKPOINT, 64'h0, "ebreak halt");

        priv_mode = `RV64_PRIV_U;
        #1;
        if (!exception || halt || cause != `RV64_EXCEPT_CAUSE_BREAKPOINT) begin
            $fatal(1, "U-mode EBREAK did not remain a trap");
        end

        priv_mode = `RV64_PRIV_S;
        #1;
        if (!exception || halt || cause != `RV64_EXCEPT_CAUSE_BREAKPOINT) begin
            $fatal(1, "S-mode EBREAK did not remain a trap");
        end

        priv_mode = `RV64_PRIV_M;
        check(1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0,
              1'b1, 1'b0, `RV64_EXCEPT_CAUSE_INSTR_ADDR_MISALIGNED, 64'h1002, "priority");

        instr_misaligned = 1'b0;
        illegal_instr = 1'b0;
        load_misaligned = 1'b0;
        store_misaligned = 1'b0;
        ecall = 1'b0;
        ebreak = 1'b0;
        instr_access_fault = 1'b1;
        #1;
        if (!exception || cause != `RV64_EXCEPT_CAUSE_INSTR_ACCESS_FAULT ||
            tval != 64'h1002) begin
            $fatal(1, "instruction access fault mismatch");
        end

        instr_access_fault = 1'b0;
        load_access_fault = 1'b1;
        #1;
        if (!exception || cause != `RV64_EXCEPT_CAUSE_LOAD_ACCESS_FAULT ||
            tval != 64'h2003) begin
            $fatal(1, "load access fault mismatch");
        end

        load_access_fault = 1'b0;
        store_access_fault = 1'b1;
        #1;
        if (!exception || cause != `RV64_EXCEPT_CAUSE_STORE_ACCESS_FAULT ||
            tval != 64'h2003) begin
            $fatal(1, "store access fault mismatch");
        end

        store_access_fault = 1'b0;
        instr_page_fault = 1'b1;
        #1;
        if (!exception || cause != `RV64_EXCEPT_CAUSE_INSTR_PAGE_FAULT ||
            tval != 64'h1002) begin
            $fatal(1, "instruction page fault mismatch");
        end

        instr_page_fault = 1'b0;
        load_page_fault = 1'b1;
        #1;
        if (!exception || cause != `RV64_EXCEPT_CAUSE_LOAD_PAGE_FAULT ||
            tval != 64'h2003) begin
            $fatal(1, "load page fault mismatch");
        end

        load_page_fault = 1'b0;
        store_page_fault = 1'b1;
        #1;
        if (!exception || cause != `RV64_EXCEPT_CAUSE_STORE_PAGE_FAULT ||
            tval != 64'h2003) begin
            $fatal(1, "store page fault mismatch");
        end

        $display("PASS: exception aggregation");
        $finish;
    end

endmodule
