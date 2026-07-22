`timescale 1ns/1ps
`include "core/regs/rv64-i-csrs.v"
`timescale 1ns/1ps

module tb_rv64i_csrs;

    logic clk;
    logic rst_n;
    logic [`RV64_FUNCT12_WIDTH-1:0] csr_addr;
    logic [`RV64_XLEN-1:0] csr_rdata;
    logic csr_valid;
    logic csr_writable;
    logic csr_write;
    logic [`RV64_XLEN-1:0] csr_wdata;
    logic trap_enter;
    logic trap_interrupt;
    logic [`RV64_EXCEPT_CAUSE_WIDTH-1:0] trap_cause;
    logic [`RV64_XLEN-1:0] trap_pc;
    logic [`RV64_XLEN-1:0] trap_tval;
    logic mret;
    logic sret;
    logic [1:0] retire_count;
    logic irq_software;
    logic irq_timer;
    logic irq_external;
    logic irq_s_software;
    logic irq_s_timer;
    logic irq_s_external;
    logic irq_pending;
    logic [`RV64_EXCEPT_CAUSE_WIDTH-1:0] irq_cause;
    logic [`RV64_XLEN-1:0] trap_vector;
    logic [`RV64_XLEN-1:0] mepc;
    logic [`RV64_XLEN-1:0] sepc;
    logic trap_to_s;
    logic [`RV64_PRIV_WIDTH-1:0] priv_mode;
    logic [`RV64_PRIV_WIDTH-1:0] data_priv_mode;
    logic sret_allowed;
    logic sfence_vma_allowed;
    logic [`RV64_SATP_MODE_WIDTH-1:0] satp_mode;
    logic [`RV64_SATP_ASID_WIDTH-1:0] satp_asid;
    logic [`RV64_SATP_PPN_WIDTH-1:0] satp_root_ppn;
    logic status_sum;
    logic status_mxr;
    logic [`RV64_XLEN-1:0] pmp_instr_addr;
    logic pmp_instr_allow;
    logic pmp_data_valid;
    logic [`RV64_XLEN-1:0] pmp_data_addr;
    logic [2:0] pmp_data_size;
    logic pmp_data_write;
    logic pmp_data_allow;
    logic pmp_bus_valid;
    logic [`RV64_XLEN-1:0] pmp_bus_addr;
    logic [2:0] pmp_bus_size;
    logic pmp_bus_write;
    logic pmp_bus_exec;
    logic [`RV64_PRIV_WIDTH-1:0] pmp_bus_priv_mode;
    logic pmp_bus_allow;
    logic [`RV64_XLEN-1:0] counter_snapshot;

    openrv64_rv64i_csrs #(
        .ENABLE_RV64M(1'b1),
        .HART_ID(64'd3)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .csr_addr_i(csr_addr),
        .csr_rdata_o(csr_rdata),
        .csr_valid_o(csr_valid),
        .csr_writable_o(csr_writable),
        .csr_write_i(csr_write),
        .csr_wdata_i(csr_wdata),
        .trap_enter_i(trap_enter),
        .trap_interrupt_i(trap_interrupt),
        .trap_cause_i(trap_cause),
        .trap_pc_i(trap_pc),
        .trap_tval_i(trap_tval),
        .mret_i(mret),
        .sret_i(sret),
        .retire_count_i(retire_count),
        .irq_software_i(irq_software),
        .irq_timer_i(irq_timer),
        .irq_external_i(irq_external),
        .irq_s_software_i(irq_s_software),
        .irq_s_timer_i(irq_s_timer),
        .irq_s_external_i(irq_s_external),
        .irq_pending_o(irq_pending),
        .irq_cause_o(irq_cause),
        .trap_vector_o(trap_vector),
        .trap_to_s_o(trap_to_s),
        .mepc_o(mepc),
        .sepc_o(sepc),
        .priv_mode_o(priv_mode),
        .data_priv_mode_o(data_priv_mode),
        .sret_allowed_o(sret_allowed),
        .sfence_vma_allowed_o(sfence_vma_allowed),
        .satp_mode_o(satp_mode),
        .satp_asid_o(satp_asid),
        .satp_root_ppn_o(satp_root_ppn),
        .status_sum_o(status_sum),
        .status_mxr_o(status_mxr),
        .pmp_instr_addr_i(pmp_instr_addr),
        .pmp_instr_allow_o(pmp_instr_allow),
        .pmp_data_valid_i(pmp_data_valid),
        .pmp_data_addr_i(pmp_data_addr),
        .pmp_data_size_i(pmp_data_size),
        .pmp_data_write_i(pmp_data_write),
        .pmp_data_allow_o(pmp_data_allow),
        .pmp_bus_valid_i(pmp_bus_valid),
        .pmp_bus_addr_i(pmp_bus_addr),
        .pmp_bus_size_i(pmp_bus_size),
        .pmp_bus_write_i(pmp_bus_write),
        .pmp_bus_exec_i(pmp_bus_exec),
        .pmp_bus_priv_mode_i(pmp_bus_priv_mode),
        .pmp_bus_allow_o(pmp_bus_allow)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic check_csr;
        input [`RV64_FUNCT12_WIDTH-1:0] addr;
        input exp_valid;
        input exp_writable;
        input [`RV64_XLEN-1:0] exp_data;
        input [8*40-1:0] label;
        begin
            csr_addr = addr;
            #1;

            if (csr_valid !== exp_valid ||
                csr_writable !== exp_writable ||
                csr_rdata !== exp_data) begin
                $fatal(1,
                    "%0s: valid=%0b/%0b writable=%0b/%0b data=%016x/%016x",
                    label, csr_valid, exp_valid, csr_writable, exp_writable,
                    csr_rdata, exp_data);
            end
        end
    endtask

    task automatic write_csr;
        input [`RV64_FUNCT12_WIDTH-1:0] addr;
        input [`RV64_XLEN-1:0] data;
        begin
            @(negedge clk);
            csr_addr = addr;
            csr_wdata = data;
            csr_write = 1'b1;
            @(posedge clk);
            @(negedge clk);
            csr_write = 1'b0;
        end
    endtask

    task automatic pulse_trap;
        begin
            @(negedge clk);
            trap_enter = 1'b1;
            @(posedge clk);
            @(negedge clk);
            trap_enter = 1'b0;
        end
    endtask

    task automatic pulse_mret;
        begin
            @(negedge clk);
            mret = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mret = 1'b0;
        end
    endtask

    task automatic pulse_sret;
        begin
            @(negedge clk);
            sret = 1'b1;
            @(posedge clk);
            @(negedge clk);
            sret = 1'b0;
        end
    endtask

    task automatic pulse_retire;
        begin
            @(negedge clk);
            retire_count = 2'd1;
            @(posedge clk);
            @(negedge clk);
            retire_count = 2'd0;
        end
    endtask

    task automatic pulse_retire_count;
        input [1:0] count;
        begin
            @(negedge clk);
            retire_count = count;
            @(posedge clk);
            @(negedge clk);
            retire_count = 2'd0;
        end
    endtask

    initial begin
        csr_addr = 12'h000;
        csr_write = 1'b0;
        csr_wdata = 64'h0;
        trap_enter = 1'b0;
        trap_interrupt = 1'b0;
        trap_cause = 5'd0;
        trap_pc = 64'h0;
        trap_tval = 64'h0;
        mret = 1'b0;
        sret = 1'b0;
        retire_count = 2'd0;
        irq_software = 1'b0;
        irq_timer = 1'b0;
        irq_external = 1'b0;
        irq_s_software = 1'b0;
        irq_s_timer = 1'b0;
        irq_s_external = 1'b0;
        pmp_instr_addr = 64'h0;
        pmp_data_valid = 1'b0;
        pmp_data_addr = 64'h0;
        pmp_data_size = 3'd0;
        pmp_data_write = 1'b0;
        pmp_bus_valid = 1'b0;
        pmp_bus_addr = 64'h0;
        pmp_bus_size = 3'd0;
        pmp_bus_write = 1'b0;
        pmp_bus_exec = 1'b0;
        pmp_bus_priv_mode = `RV64_PRIV_M;

        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        check_csr(`RV64_CSR_MSTATUS, 1'b1, 1'b1,
                  64'h0000_000a_0000_1800, "mstatus reset");
        check_csr(`RV64_CSR_MISA, 1'b1, 1'b0,
                  64'h8000_0000_0014_1101, "misa rv64aimsu");
        check_csr(`RV64_CSR_MHARTID, 1'b1, 1'b0, 64'd3, "mhartid");
        check_csr(`RV64_CSR_PMPCFG0, 1'b1, 1'b1, 64'h0, "pmpcfg0 reset");
        check_csr(12'hfff, 1'b0, 1'b0, 64'h0, "unimplemented csr");

        if (priv_mode != `RV64_PRIV_M || !pmp_instr_allow) begin
            $fatal(1, "reset privilege/PMP state mismatch");
        end

        csr_addr = `RV64_CSR_MCYCLE;
        #1;
        counter_snapshot = csr_rdata;
        repeat (3) @(posedge clk);
        #1;
        if (csr_rdata <= counter_snapshot) begin
            $fatal(1, "mcycle did not increment");
        end

        write_csr(`RV64_CSR_MCOUNTINHIBIT,
                  64'd1 << `RV64_MCOUNTER_CY_BIT);
        csr_addr = `RV64_CSR_MCYCLE;
        #1;
        counter_snapshot = csr_rdata;
        repeat (3) @(posedge clk);
        #1;
        if (csr_rdata != counter_snapshot) begin
            $fatal(1, "mcycle incremented while inhibited");
        end

        write_csr(`RV64_CSR_MCYCLE, 64'd100);
        check_csr(`RV64_CSR_MCYCLE, 1'b1, 1'b1, 64'd100,
                  "mcycle write");
        check_csr(`RV64_CSR_TIME, 1'b1, 1'b0, 64'd100,
                  "limited time alias");
        write_csr(`RV64_CSR_MCOUNTEREN, 64'hffff_ffff_ffff_ffff);
        check_csr(`RV64_CSR_MCOUNTEREN, 1'b1, 1'b1, 64'd7,
                  "mcounteren WARL mask");

        write_csr(`RV64_CSR_MIP, 64'hffff_ffff_ffff_ffff);
        check_csr(`RV64_CSR_MIP, 1'b1, 1'b1,
                  (64'd1 << `RV64_MIP_SSIP_BIT) |
                  (64'd1 << `RV64_MIP_MSIP_BIT) |
                  (64'd1 << `RV64_MIP_STIP_BIT),
                  "M-mode software-writable MIP bits");
        write_csr(`RV64_CSR_MIP, 64'd0);

        write_csr(`RV64_CSR_MINSTRET, 64'd20);
        @(negedge clk);
        retire_count = 2'd3;
        check_csr(`RV64_CSR_MINSTRET, 1'b1, 1'b1, 64'd23,
                  "minstret same-cycle retirement forwarding");
        @(posedge clk);
        @(negedge clk);
        retire_count = 2'd0;
        check_csr(`RV64_CSR_MINSTRET, 1'b1, 1'b1, 64'd23,
                  "minstret forwarded retirement committed");
        write_csr(`RV64_CSR_MINSTRET, 64'd20);
        pulse_retire();
        check_csr(`RV64_CSR_MINSTRET, 1'b1, 1'b1, 64'd21,
                  "minstret retirement increment");
        pulse_retire_count(2'd3);
        check_csr(`RV64_CSR_MINSTRET, 1'b1, 1'b1, 64'd24,
                  "minstret three-wide retirement increment");
        write_csr(`RV64_CSR_MCOUNTINHIBIT,
                  (64'd1 << `RV64_MCOUNTER_CY_BIT) |
                  (64'd1 << `RV64_MCOUNTER_IR_BIT));
        pulse_retire();
        check_csr(`RV64_CSR_MINSTRET, 1'b1, 1'b1, 64'd24,
                  "minstret inhibit");

        write_csr(`RV64_CSR_MTVEC, 64'h0000_0000_0000_0105);
        check_csr(`RV64_CSR_MTVEC, 1'b1, 1'b1,
                  64'h0000_0000_0000_0105, "mtvec vectored");

        write_csr(`RV64_CSR_MSTATUS, 64'h8);
        write_csr(`RV64_CSR_MIE, 64'h800);
        irq_external = 1'b1;
        #1;
        if (!irq_pending || irq_cause != `RV64_IRQ_CAUSE_MACHINE_EXTERNAL) begin
            $fatal(1, "machine external interrupt was not published");
        end

        trap_interrupt = 1'b1;
        trap_cause = `RV64_IRQ_CAUSE_MACHINE_EXTERNAL;
        trap_pc = 64'h0000_0000_0000_0123;
        trap_tval = 64'hfeed_face_dead_beef;
        #1;
        if (trap_vector != 64'h0000_0000_0000_0130) begin
            $fatal(1, "vectored trap target mismatch: %016x", trap_vector);
        end

        pulse_trap();
        if (priv_mode != `RV64_PRIV_M) begin
            $fatal(1, "trap did not enter M-mode");
        end
        #1;
        if (irq_pending) begin
            $fatal(1,
                   "active machine interrupt remained eligible after trap entry cleared MIE");
        end
        trap_interrupt = 1'b0;
        irq_external = 1'b0;
        check_csr(`RV64_CSR_MEPC, 1'b1, 1'b1,
                  64'h0000_0000_0000_0120, "trap mepc");
        check_csr(`RV64_CSR_MCAUSE, 1'b1, 1'b1,
                  64'h8000_0000_0000_000b, "trap mcause");
        check_csr(`RV64_CSR_MTVAL, 1'b1, 1'b1,
                  64'hfeed_face_dead_beef, "trap mtval");
        check_csr(`RV64_CSR_MSTATUS, 1'b1, 1'b1,
                  64'h0000_000a_0000_1880, "trap mstatus");

        pulse_mret();
        if (priv_mode != `RV64_PRIV_M) begin
            $fatal(1, "M-mode-only mret changed privilege");
        end
        check_csr(`RV64_CSR_MSTATUS, 1'b1, 1'b1,
                  64'h0000_000a_0000_0088, "mret mstatus");

        write_csr(`RV64_CSR_MEDELEG,
                  64'd1 << `RV64_EXCEPT_CAUSE_ECALL_U);
        write_csr(`RV64_CSR_STVEC, 64'h0000_0000_0000_0201);
        write_csr(`RV64_CSR_MCOUNTEREN,
                  (64'd1 << `RV64_MCOUNTER_CY_BIT) |
                  (64'd1 << `RV64_MCOUNTER_TM_BIT) |
                  (64'd1 << `RV64_MCOUNTER_IR_BIT));
        write_csr(`RV64_CSR_SCOUNTEREN,
                  (64'd1 << `RV64_MCOUNTER_CY_BIT) |
                  (64'd1 << `RV64_MCOUNTER_TM_BIT) |
                  (64'd1 << `RV64_MCOUNTER_IR_BIT));
        write_csr(`RV64_CSR_MEPC, 64'h0000_0000_0000_0400);
        write_csr(`RV64_CSR_MSTATUS,
                  64'd1 << `RV64_MSTATUS_SIE_BIT);
        pulse_mret();

        if (priv_mode != `RV64_PRIV_U || mepc != 64'h400) begin
            $fatal(1, "MRET did not enter U-mode at MEPC");
        end
        check_csr(`RV64_CSR_MSTATUS, 1'b0, 1'b0, 64'h0,
                  "U-mode machine CSR denied");
        check_csr(`RV64_CSR_SSTATUS, 1'b0, 1'b0, 64'h0,
                  "U-mode supervisor CSR denied");
        check_csr(`RV64_CSR_CYCLE, 1'b1, 1'b0, 64'd100,
                  "U-mode cycle access");
        check_csr(`RV64_CSR_TIME, 1'b1, 1'b0, 64'd100,
                  "U-mode time access");
        check_csr(`RV64_CSR_SATP, 1'b0, 1'b0, 64'h0,
                  "U-mode satp denied");

        trap_interrupt = 1'b0;
        trap_cause = `RV64_EXCEPT_CAUSE_ECALL_U;
        trap_pc = 64'h0000_0000_0000_0423;
        trap_tval = 64'h0;
        #1;
        if (!trap_to_s || trap_vector != 64'h0000_0000_0000_0200) begin
            $fatal(1, "U-mode ECALL was not delegated to stvec");
        end
        pulse_trap();

        if (priv_mode != `RV64_PRIV_S || sepc != 64'h420) begin
            $fatal(1, "delegated trap did not enter S-mode/save SEPC");
        end
        check_csr(`RV64_CSR_SCAUSE, 1'b1, 1'b1,
                  64'd8, "delegated scause");
        check_csr(`RV64_CSR_STVAL, 1'b1, 1'b1,
                  64'd0, "delegated stval");
        check_csr(`RV64_CSR_SSTATUS, 1'b1, 1'b1,
                  64'h0000_0002_0000_0020, "delegated sstatus");
        check_csr(`RV64_CSR_MSTATUS, 1'b0, 1'b0, 64'h0,
                  "S-mode machine CSR denied");
        check_csr(`RV64_CSR_SATP, 1'b1, 1'b1, 64'h0,
                  "S-mode bare satp");
        if (!sfence_vma_allowed || data_priv_mode != `RV64_PRIV_S) begin
            $fatal(1, "S-mode translation controls mismatch");
        end

        write_csr(`RV64_CSR_SATP, 64'h8123_4000_00ab_cdef);
        check_csr(`RV64_CSR_SATP, 1'b1, 1'b1,
                  64'h8123_4000_00ab_cdef, "S-mode Sv39 satp");
        if (satp_mode != `RV64_SATP_MODE_SV39 ||
            satp_asid != 16'h1234 ||
            satp_root_ppn != 44'h00000ab_cdef) begin
            $fatal(1, "satp context outputs mismatch");
        end

        write_csr(`RV64_CSR_SATP, 64'h9123_4000_00de_ad00);
        check_csr(`RV64_CSR_SATP, 1'b1, 1'b1,
                  64'h8123_4000_00ab_cdef, "unsupported satp mode ignored");
        write_csr(`RV64_CSR_SATP, 64'h0000_0000_0000_0000);

        write_csr(`RV64_CSR_SEPC, 64'h0000_0000_0000_0503);
        if (!sret_allowed) begin
            $fatal(1, "SRET unexpectedly disallowed in S-mode");
        end
        pulse_sret();
        if (priv_mode != `RV64_PRIV_U || sepc != 64'h500) begin
            $fatal(1, "SRET did not return to U-mode at SEPC");
        end

        trap_cause = `RV64_EXCEPT_CAUSE_ILLEGAL_INSTR;
        trap_pc = 64'h0000_0000_0000_0507;
        trap_tval = 64'hdead_beef;
        #1;
        if (trap_to_s || trap_vector != 64'h0000_0000_0000_0104) begin
            $fatal(1, "nondelegated U trap did not select mtvec");
        end
        pulse_trap();
        if (priv_mode != `RV64_PRIV_M || mepc != 64'h504) begin
            $fatal(1, "nondelegated trap did not enter M-mode/save MEPC");
        end
        check_csr(`RV64_CSR_MCAUSE, 1'b1, 1'b1,
                  64'd2, "nondelegated mcause");
        check_csr(`RV64_CSR_MTVAL, 1'b1, 1'b1,
                  64'hdead_beef, "nondelegated mtval");

        write_csr(`RV64_CSR_MEPC, 64'h0000_0000_0000_0600);
        write_csr(`RV64_CSR_MSTATUS,
                  (64'd1 << `RV64_MSTATUS_TSR_BIT) | 64'h800);
        pulse_mret();
        if (priv_mode != `RV64_PRIV_S || sret_allowed) begin
            $fatal(1, "TSR did not prohibit SRET in S-mode");
        end

        trap_cause = `RV64_EXCEPT_CAUSE_ILLEGAL_INSTR;
        trap_pc = 64'h0000_0000_0000_0600;
        trap_tval = `RV64_INSTR_SRET;
        pulse_trap();
        if (priv_mode != `RV64_PRIV_M) begin
            $fatal(1, "TSR test trap did not return to M-mode");
        end

        write_csr(`RV64_CSR_MEPC, 64'h0000_0000_0000_0680);
        write_csr(`RV64_CSR_MSTATUS, 64'h800);
        pulse_mret();
        write_csr(`RV64_CSR_SSTATUS,
                  64'd1 << `RV64_MSTATUS_SPP_BIT);
        write_csr(`RV64_CSR_SEPC, 64'h0000_0000_0000_0703);
        pulse_sret();
        if (priv_mode != `RV64_PRIV_S || sepc != 64'h700) begin
            $fatal(1, "SRET with SPP=1 did not remain in S-mode");
        end

        trap_interrupt = 1'b0;
        trap_cause = `RV64_EXCEPT_CAUSE_ILLEGAL_INSTR;
        trap_pc = 64'h0000_0000_0000_0700;
        trap_tval = 64'h0;
        pulse_trap();
        if (priv_mode != `RV64_PRIV_M) begin
            $fatal(1, "supervisor test cleanup did not enter M-mode");
        end

        write_csr(`RV64_CSR_MIDELEG,
                  64'd1 << `RV64_MIP_SEIP_BIT);
        write_csr(`RV64_CSR_MIE,
                  64'd1 << `RV64_MIP_SEIP_BIT);
        write_csr(`RV64_CSR_MEPC, 64'h0000_0000_0000_0800);
        write_csr(`RV64_CSR_MSTATUS, 64'h0);
        pulse_mret();
        irq_s_external = 1'b1;
        #1;
        if (!irq_pending ||
            irq_cause != `RV64_IRQ_CAUSE_SUPERVISOR_EXTERNAL) begin
            $fatal(1, "delegated supervisor interrupt was not published");
        end

        trap_interrupt = 1'b1;
        trap_cause = irq_cause;
        trap_pc = 64'h0000_0000_0000_0804;
        #1;
        if (!trap_to_s || trap_vector != 64'h0000_0000_0000_0224) begin
            $fatal(1, "delegated interrupt did not select vectored stvec");
        end
        pulse_trap();
        irq_s_external = 1'b0;
        trap_interrupt = 1'b0;
        if (priv_mode != `RV64_PRIV_S || sepc != 64'h804) begin
            $fatal(1, "delegated interrupt did not enter S-mode/save SEPC");
        end
        check_csr(`RV64_CSR_SCAUSE, 1'b1, 1'b1,
                  64'h8000_0000_0000_0009,
                  "delegated interrupt scause");

        $display("PASS: RV64 M/S/U CSR state, STIP injection, and context updates");
        $finish;
    end

endmodule
