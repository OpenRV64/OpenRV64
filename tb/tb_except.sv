`timescale 1ns/1ps
`include "core/except/except.v"
`timescale 1ns/1ps

module tb_except;

    logic illegal_instr;
    logic instr_misaligned;
    logic load_misaligned;
    logic store_misaligned;
    logic ecall;
    logic ebreak;
    logic [`RV64_XLEN-1:0] pc;
    logic [`RV64_INSTR_WIDTH-1:0] instr;
    logic [`RV64_XLEN-1:0] badaddr;
    logic exception;
    logic halt;
    logic [`RV64_EXCEPT_CAUSE_WIDTH-1:0] cause;
    logic [`RV64_XLEN-1:0] tval;

    openrv64_except dut (
        .illegal_instr_i(illegal_instr),
        .instr_misaligned_i(instr_misaligned),
        .load_misaligned_i(load_misaligned),
        .store_misaligned_i(store_misaligned),
        .ecall_i(ecall),
        .ebreak_i(ebreak),
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
            load_misaligned = in_load_misaligned;
            store_misaligned = in_store_misaligned;
            ecall = in_ecall;
            ebreak = in_ebreak;
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
        check(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1,
              1'b1, 1'b1, `RV64_EXCEPT_CAUSE_BREAKPOINT, 64'h0, "ebreak halt");
        check(1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0,
              1'b1, 1'b0, `RV64_EXCEPT_CAUSE_INSTR_ADDR_MISALIGNED, 64'h1002, "priority");

        $display("PASS: exception aggregation");
        $finish;
    end

endmodule
