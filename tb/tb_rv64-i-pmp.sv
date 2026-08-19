`timescale 1ns/1ps
`include "core/regs/rv64-i-pmp.v"
`timescale 1ns/1ps

module tb_rv64i_pmp #(
    parameter integer PMP_ACTIVE_ENTRIES = 8
);

    logic clk;
    logic rst_n;
    logic [`RV64_FUNCT12_WIDTH-1:0] csr_addr;
    logic [`RV64_XLEN-1:0] csr_rdata;
    logic csr_match;
    logic csr_writable;
    logic csr_write;
    logic [`RV64_XLEN-1:0] csr_wdata;
    logic csr_write_ready;
    logic csr_busy;
    logic [`RV64_PRIV_WIDTH-1:0] priv_mode;
    logic bus_valid;
    logic [`RV64_XLEN-1:0] bus_addr;
    logic [2:0] bus_size;
    logic bus_write;
    logic bus_exec;
    logic [`RV64_PRIV_WIDTH-1:0] bus_priv_mode;
    logic bus_allow;
    logic [`RV64_FUNCT12_WIDTH-1:0] last_active_pmpaddr_csr;
    logic [`RV64_FUNCT12_WIDTH-1:0] last_active_pmpcfg_csr;
    logic [`RV64_XLEN-1:0] last_active_pmpcfg_value;
    logic [`RV64_FUNCT12_WIDTH-1:0] first_inactive_pmpaddr_csr;
    logic [`RV64_FUNCT12_WIDTH-1:0] first_inactive_pmpcfg_csr;
    logic [`RV64_XLEN-1:0] first_inactive_pmpcfg_value;

    openrv64_rv64i_pmp #(
        .PMP_ACTIVE_ENTRIES(PMP_ACTIVE_ENTRIES)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .csr_addr_i(csr_addr),
        .csr_rdata_o(csr_rdata),
        .csr_match_o(csr_match),
        .csr_writable_o(csr_writable),
        .csr_write_i(csr_write),
        .csr_wdata_i(csr_wdata),
        .csr_write_ready_o(csr_write_ready),
        .csr_busy_o(csr_busy),
        .bus_valid_i(bus_valid),
        .bus_addr_i(bus_addr),
        .bus_size_i(bus_size),
        .bus_write_i(bus_write),
        .bus_exec_i(bus_exec),
        .bus_priv_mode_i(bus_priv_mode),
        .bus_allow_o(bus_allow)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic apply_reset;
        begin
            rst_n = 1'b0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            #1;
        end
    endtask

    task automatic write_csr_timed;
        input [`RV64_FUNCT12_WIDTH-1:0] addr;
        input [`RV64_XLEN-1:0] data;
        output integer busy_cycles;
        begin
            @(negedge clk);
            csr_addr = addr;
            csr_wdata = data;
            csr_write = 1'b1;
            @(posedge clk);
            @(negedge clk);
            csr_write = 1'b0;
            busy_cycles = 0;
            while (csr_busy) begin
                @(negedge clk);
                busy_cycles = busy_cycles + 1;
            end
        end
    endtask

    task automatic write_csr;
        input [`RV64_FUNCT12_WIDTH-1:0] addr;
        input [`RV64_XLEN-1:0] data;
        integer ignored_busy_cycles;
        begin
            write_csr_timed(addr, data, ignored_busy_cycles);
        end
    endtask

    task automatic check_csr;
        input [`RV64_FUNCT12_WIDTH-1:0] addr;
        input [`RV64_XLEN-1:0] expected;
        input [8*48-1:0] label;
        begin
            csr_addr = addr;
            #1;
            if (!csr_match || !csr_writable || csr_rdata !== expected) begin
                $fatal(1, "%0s: match=%0b writable=%0b data=%016x/%016x",
                       label, csr_match, csr_writable, csr_rdata, expected);
            end
        end
    endtask

    task automatic check_unimplemented_csr;
        input [`RV64_FUNCT12_WIDTH-1:0] addr;
        input [8*48-1:0] label;
        begin
            csr_addr = addr;
            #1;
            if (csr_match || csr_writable) begin
                $fatal(1, "%0s: match=%0b writable=%0b",
                       label, csr_match, csr_writable);
            end
        end
    endtask

    task automatic check_instr;
        input [`RV64_XLEN-1:0] addr;
        input expected;
        input [8*48-1:0] label;
        begin
            bus_valid = 1'b1;
            bus_addr = addr;
            bus_size = 3'd2;
            bus_write = 1'b0;
            bus_exec = 1'b1;
            bus_priv_mode = priv_mode;
            #1;
            if (bus_allow !== expected) begin
                $fatal(1, "%0s: instruction allow=%0b/%0b",
                       label, bus_allow, expected);
            end
        end
    endtask

    task automatic check_data;
        input [`RV64_XLEN-1:0] addr;
        input [2:0] size;
        input is_write;
        input expected;
        input [8*48-1:0] label;
        begin
            bus_valid = 1'b1;
            bus_addr = addr;
            bus_size = size;
            bus_write = is_write;
            bus_exec = 1'b0;
            bus_priv_mode = priv_mode;
            #1;
            if (bus_allow !== expected) begin
                $fatal(1, "%0s: data allow=%0b/%0b",
                       label, bus_allow, expected);
            end
        end
    endtask

    task automatic check_bus;
        input [`RV64_XLEN-1:0] addr;
        input [2:0] size;
        input is_write;
        input is_exec;
        input [`RV64_PRIV_WIDTH-1:0] access_priv;
        input expected;
        input [8*48-1:0] label;
        begin
            bus_valid = 1'b1;
            bus_addr = addr;
            bus_size = size;
            bus_write = is_write;
            bus_exec = is_exec;
            bus_priv_mode = access_priv;
            #1;
            if (bus_allow !== expected) begin
                $fatal(1, "%0s: bus allow=%0b/%0b",
                       label, bus_allow, expected);
            end
        end
    endtask

    initial begin
        integer busy_cycles;
        csr_addr = 12'h000;
        csr_write = 1'b0;
        csr_wdata = 64'h0;
        priv_mode = `RV64_PRIV_M;
        bus_valid = 1'b0;
        bus_addr = 64'h0;
        bus_size = 3'd0;
        bus_write = 1'b0;
        bus_exec = 1'b0;
        bus_priv_mode = `RV64_PRIV_M;
        last_active_pmpaddr_csr =
            `RV64_CSR_PMPADDR0 + PMP_ACTIVE_ENTRIES - 1;
        last_active_pmpcfg_csr = (PMP_ACTIVE_ENTRIES > 8) ?
            `RV64_CSR_PMPCFG2 : `RV64_CSR_PMPCFG0;
        last_active_pmpcfg_value = 64'h1d <<
            (((PMP_ACTIVE_ENTRIES - 1) % 8) * 8);
        first_inactive_pmpaddr_csr =
            `RV64_CSR_PMPADDR0 + PMP_ACTIVE_ENTRIES;
        first_inactive_pmpcfg_csr = (PMP_ACTIVE_ENTRIES >= 8) ?
            `RV64_CSR_PMPCFG2 : `RV64_CSR_PMPCFG0;
        first_inactive_pmpcfg_value = 64'h1d <<
            ((PMP_ACTIVE_ENTRIES % 8) * 8);
        rst_n = 1'b0;

        apply_reset();

        check_instr(64'h800, 1'b1, "M-mode default instruction");
        check_data(64'h800, 3'd3, 1'b0, 1'b1,
                   "M-mode default data");
        check_bus(64'h800, 3'd3, 1'b0, 1'b0, `RV64_PRIV_M, 1'b1,
                  "M-mode default physical request");

        priv_mode = `RV64_PRIV_U;
        check_instr(64'h800, 1'b0, "U-mode no-match instruction");
        check_data(64'h800, 3'd3, 1'b0, 1'b0,
                   "U-mode no-match data");
        check_bus(64'h800, 3'd3, 1'b0, 1'b0, `RV64_PRIV_U, 1'b0,
                  "U-mode no-match physical request");

        // The architectural CSR surface always exposes 16 entries.  Fields
        // above the active hardware prefix are WARL read-only zero.
        priv_mode = `RV64_PRIV_M;
        check_csr(`RV64_CSR_PMPCFG0, 64'h0, "pmpcfg0 reset");
        check_csr(`RV64_CSR_PMPCFG2, 64'h0, "pmpcfg2 reset");
        check_unimplemented_csr(12'h3a1, "RV64 odd pmpcfg1");
        check_csr(`RV64_CSR_PMPADDR15, 64'h0,
                  "architectural pmpaddr15 reset");
        check_unimplemented_csr(12'h3c0, "seventeenth PMP entry");
        if (PMP_ACTIVE_ENTRIES < 16) begin
            write_csr_timed(first_inactive_pmpaddr_csr,
                            64'hffff_ffff_ffff_ffff, busy_cycles);
            if (busy_cycles != 0)
                $fatal(1, "inactive PMPADDR entered serial sequencer");
            check_csr(first_inactive_pmpaddr_csr, 64'h0,
                      "inactive pmpaddr remains zero");
            write_csr(first_inactive_pmpcfg_csr,
                      first_inactive_pmpcfg_value);
            check_csr(first_inactive_pmpcfg_csr, 64'h0,
                      "inactive pmpcfg remains zero");
        end
        check_csr(last_active_pmpaddr_csr, 64'h0,
                  "last active pmpaddr reset");

        // OFF-mode address reads expose 4 KiB grain by forcing
        // pmpaddr[9:0] to zero. The final active entry is then enabled as a
        // 4 KiB RX NAPOT region.
        write_csr(last_active_pmpaddr_csr, 64'h11ff);
        check_csr(last_active_pmpaddr_csr, 64'h1000,
                  "last active pmpaddr OFF grain readback");
        write_csr(last_active_pmpcfg_csr, last_active_pmpcfg_value);
        check_csr(last_active_pmpcfg_csr, last_active_pmpcfg_value,
                  "last active pmpcfg entry");
        check_csr(last_active_pmpaddr_csr, 64'h11ff,
                  "last active pmpaddr NAPOT readback");
        priv_mode = `RV64_PRIV_U;
        check_instr(64'h4000, 1'b1, "last entry execute");
        check_data(64'h4000, 3'd3, 1'b0, 1'b1,
                   "last entry read");
        check_data(64'h4000, 3'd3, 1'b1, 1'b0,
                   "last entry write denied");
        check_data(64'h5000, 3'd3, 1'b0, 1'b0,
                   "last entry outside");

        // OpenSBI probes granularity with A=OFF and an all-ones pmpaddr.
        apply_reset();
        write_csr_timed(`RV64_CSR_PMPADDR0,
                        64'hffff_ffff_ffff_ffff, busy_cycles);
        if (busy_cycles != 77)
            $fatal(1, "all-one serial PMPADDR latency=%0d/77",
                   busy_cycles);
        check_csr(`RV64_CSR_PMPADDR0, 64'h0000_001f_ffff_fc00,
                  "OpenSBI 39-bit address and 4 KiB grain probe");

        // Unsupported TOR and NA4 encodings deterministically coerce A to
        // OFF. R/W/X remain WARL-visible; no region becomes active.
        write_csr(`RV64_CSR_PMPCFG0, 64'h0f);
        check_csr(`RV64_CSR_PMPCFG0, 64'h07,
                  "TOR coerced to OFF");
        write_csr(`RV64_CSR_PMPCFG0, 64'h17);
        check_csr(`RV64_CSR_PMPCFG0, 64'h07,
                  "NA4 coerced to OFF");
        priv_mode = `RV64_PRIV_U;
        check_data(64'h0, 3'd0, 1'b0, 1'b0,
                   "unsupported mode remains inactive");

        // Minimum-grain NAPOT region: 0x2000-0x2fff, read/write but not
        // execute. A partially overlapping access fails even in M-mode.
        apply_reset();
        write_csr(`RV64_CSR_PMPADDR0, 64'h9ff);
        write_csr(`RV64_CSR_PMPCFG0, 64'h1b);
        check_csr(`RV64_CSR_PMPADDR0, 64'h9ff,
                  "minimum-grain NAPOT readback");
        priv_mode = `RV64_PRIV_U;
        check_data(64'h2000, 3'd3, 1'b0, 1'b1,
                   "NAPOT first word read");
        check_data(64'h2ff8, 3'd3, 1'b1, 1'b1,
                   "NAPOT last word write");
        check_data(64'h2ffc, 3'd3, 1'b0, 1'b0,
                   "NAPOT partial overlap");
        check_data(64'h3000, 3'd0, 1'b0, 1'b0,
                   "NAPOT outside");
        check_instr(64'h2000, 1'b0, "NAPOT execute denied");
        priv_mode = `RV64_PRIV_M;
        check_instr(64'h2000, 1'b1, "unlocked M execute bypass");
        check_data(64'h2ffc, 3'd3, 1'b0, 1'b0,
                   "unlocked M partial overlap denied");

        // Lowest-numbered overlap wins. Entry 0 denies its 4 KiB region;
        // entry 1 grants the complete implemented 39-bit physical space.
        apply_reset();
        write_csr(`RV64_CSR_PMPADDR0, 64'h9ff);
        write_csr(`RV64_CSR_PMPADDR1, 64'hffff_ffff_ffff_ffff);
        write_csr(`RV64_CSR_PMPCFG0, 64'h1f18);
        priv_mode = `RV64_PRIV_U;
        check_data(64'h2000, 3'd3, 1'b0, 1'b0,
                   "lower entry deny priority");
        check_data(64'h4000, 3'd3, 1'b1, 1'b1,
                   "full-range fallback allow");
        check_data(64'h0000_007f_ffff_fff8, 3'd3, 1'b0, 1'b1,
                   "full-range top word");
        check_data(64'h0000_0080_0000_0000, 3'd0, 1'b0, 1'b0,
                   "outside implemented physical address");
        check_bus(64'h0000_0080_0000_0000, 3'd0, 1'b0, 1'b0,
                  `RV64_PRIV_M, 1'b1, "M-mode no-match above PA width");

        // Locked NAPOT entries apply permissions to M-mode and reject both
        // configuration and address writes until reset.
        apply_reset();
        write_csr(`RV64_CSR_PMPADDR0, 64'h9ff);
        write_csr(`RV64_CSR_PMPCFG0, 64'h99);
        priv_mode = `RV64_PRIV_U;
        check_data(64'h2000, 3'd3, 1'b0, 1'b1,
                   "locked U read");
        check_data(64'h2000, 3'd3, 1'b1, 1'b0,
                   "locked U write denied");
        priv_mode = `RV64_PRIV_M;
        check_data(64'h2000, 3'd3, 1'b1, 1'b0,
                   "locked M write denied");
        write_csr_timed(`RV64_CSR_PMPADDR0, 64'h11ff, busy_cycles);
        if (busy_cycles != 0)
            $fatal(1, "locked PMPADDR write entered serial sequencer");
        check_csr(`RV64_CSR_PMPADDR0, 64'h9ff,
                  "locked pmpaddr");
        write_csr(`RV64_CSR_PMPCFG0, 64'h1f);
        check_csr(`RV64_CSR_PMPCFG0, 64'h99,
                  "locked pmpcfg");

        // An unlocked address write spends ten cycles scanning the minimum
        // 4 KiB NAPOT encoding and 40 cycles adding the exclusive bound.
        // Readback and permissions must expose the old tuple throughout.
        apply_reset();
        write_csr(`RV64_CSR_PMPADDR0, 64'h9ff);
        write_csr(`RV64_CSR_PMPCFG0, 64'h1b);
        priv_mode = `RV64_PRIV_U;
        check_data(64'h2000, 3'd3, 1'b0, 1'b1,
                   "pre-normalization-write region");
        priv_mode = `RV64_PRIV_M;
        @(negedge clk);
        csr_addr = `RV64_CSR_PMPADDR0;
        csr_wdata = 64'h11ff;
        csr_write = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (!csr_busy || csr_write_ready)
            $fatal(1, "serial PMPADDR request did not enter busy");
        csr_write = 1'b0;
        #1;
        if (csr_rdata !== 64'h9ff)
            $fatal(1, "PMPADDR readback changed before atomic commit");
        priv_mode = `RV64_PRIV_U;
        check_data(64'h2000, 3'd3, 1'b0, 1'b1,
                   "old region retained while serial write busy");
        check_data(64'h4000, 3'd3, 1'b0, 1'b0,
                   "new region hidden while serial write busy");
        busy_cycles = 0;
        while (csr_busy) begin
            @(negedge clk);
            busy_cycles = busy_cycles + 1;
        end
        if (busy_cycles != 50)
            $fatal(1, "minimum serial PMPADDR latency=%0d/50",
                   busy_cycles);
        priv_mode = `RV64_PRIV_U;
        check_data(64'h2000, 3'd3, 1'b0, 1'b0,
                   "old normalized region removed");
        check_data(64'h4000, 3'd3, 1'b0, 1'b1,
                   "new normalized region active");

        $display("PASS: 16-entry CSR surface, %0d active single-port 39-bit serial 4 KiB OFF/NAPOT PMP, 1-bit scan/add, atomic bounds, WARL, priorities, and locks",
                 PMP_ACTIVE_ENTRIES);
        $finish;
    end

endmodule
