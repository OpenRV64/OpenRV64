`timescale 1ns/1ps
`include "core/regs/rv64-i-pmp.v"
`timescale 1ns/1ps

module tb_rv64i_pmp;

    logic clk;
    logic rst_n;
    logic [`RV64_FUNCT12_WIDTH-1:0] csr_addr;
    logic [`RV64_XLEN-1:0] csr_rdata;
    logic csr_match;
    logic csr_writable;
    logic csr_write;
    logic [`RV64_XLEN-1:0] csr_wdata;
    logic [`RV64_PRIV_WIDTH-1:0] priv_mode;
    logic [`RV64_XLEN-1:0] instr_addr;
    logic instr_allow;
    logic data_valid;
    logic [`RV64_XLEN-1:0] data_addr;
    logic [2:0] data_size;
    logic data_write;
    logic data_allow;
    logic bus_valid;
    logic [`RV64_XLEN-1:0] bus_addr;
    logic [2:0] bus_size;
    logic bus_write;
    logic bus_exec;
    logic [`RV64_PRIV_WIDTH-1:0] bus_priv_mode;
    logic bus_allow;

    openrv64_rv64i_pmp dut (
        .clk(clk),
        .rst_n(rst_n),
        .csr_addr_i(csr_addr),
        .csr_rdata_o(csr_rdata),
        .csr_match_o(csr_match),
        .csr_writable_o(csr_writable),
        .csr_write_i(csr_write),
        .csr_wdata_i(csr_wdata),
        .instr_priv_mode_i(priv_mode),
        .data_priv_mode_i(priv_mode),
        .instr_addr_i(instr_addr),
        .instr_allow_o(instr_allow),
        .data_valid_i(data_valid),
        .data_addr_i(data_addr),
        .data_size_i(data_size),
        .data_write_i(data_write),
        .data_allow_o(data_allow),
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
            instr_addr = addr;
            #1;
            if (instr_allow !== expected) begin
                $fatal(1, "%0s: instruction allow=%0b/%0b",
                       label, instr_allow, expected);
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
            data_valid = 1'b1;
            data_addr = addr;
            data_size = size;
            data_write = is_write;
            #1;
            if (data_allow !== expected) begin
                $fatal(1, "%0s: data allow=%0b/%0b",
                       label, data_allow, expected);
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
        csr_addr = 12'h000;
        csr_write = 1'b0;
        csr_wdata = 64'h0;
        priv_mode = `RV64_PRIV_M;
        instr_addr = 64'h800;
        data_valid = 1'b1;
        data_addr = 64'h800;
        data_size = 3'd3;
        data_write = 1'b0;
        bus_valid = 1'b0;
        bus_addr = 64'h0;
        bus_size = 3'd0;
        bus_write = 1'b0;
        bus_exec = 1'b0;
        bus_priv_mode = `RV64_PRIV_M;
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

        // The implemented CSR surface is exactly 16 entries: pmpcfg0,
        // pmpcfg2, and pmpaddr0 through pmpaddr15.
        priv_mode = `RV64_PRIV_M;
        check_csr(`RV64_CSR_PMPCFG0, 64'h0, "pmpcfg0 reset");
        check_csr(`RV64_CSR_PMPCFG2, 64'h0, "pmpcfg2 reset");
        check_csr(`RV64_CSR_PMPADDR15, 64'h0, "pmpaddr15 reset");
        check_unimplemented_csr(12'h3a1, "RV64 odd pmpcfg1");
        check_unimplemented_csr(12'h3c0, "seventeenth PMP entry");

        // OFF-mode address reads expose 4 KiB grain by forcing pmpaddr[9:0]
        // to zero. Entry 15 is then enabled as a 4 KiB RX NAPOT region.
        write_csr(`RV64_CSR_PMPADDR15, 64'h11ff);
        check_csr(`RV64_CSR_PMPADDR15, 64'h1000,
                  "pmpaddr15 OFF grain readback");
        write_csr(`RV64_CSR_PMPCFG2, 64'h1d00_0000_0000_0000);
        check_csr(`RV64_CSR_PMPCFG2, 64'h1d00_0000_0000_0000,
                  "pmpcfg2 entry 15");
        check_csr(`RV64_CSR_PMPADDR15, 64'h11ff,
                  "pmpaddr15 NAPOT readback");
        priv_mode = `RV64_PRIV_U;
        check_instr(64'h4000, 1'b1, "entry 15 execute");
        check_data(64'h4000, 3'd3, 1'b0, 1'b1,
                   "entry 15 read");
        check_data(64'h4000, 3'd3, 1'b1, 1'b0,
                   "entry 15 write denied");
        check_data(64'h5000, 3'd3, 1'b0, 1'b0,
                   "entry 15 outside");

        // OpenSBI probes granularity with A=OFF and an all-ones pmpaddr.
        apply_reset();
        write_csr(`RV64_CSR_PMPADDR0, 64'hffff_ffff_ffff_ffff);
        check_csr(`RV64_CSR_PMPADDR0, 64'h003f_ffff_ffff_fc00,
                  "OpenSBI 56-bit address and 4 KiB grain probe");

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
        // entry 1 grants the complete implemented 56-bit physical space.
        apply_reset();
        write_csr(`RV64_CSR_PMPADDR0, 64'h9ff);
        write_csr(`RV64_CSR_PMPADDR1, 64'hffff_ffff_ffff_ffff);
        write_csr(`RV64_CSR_PMPCFG0, 64'h1f18);
        priv_mode = `RV64_PRIV_U;
        check_data(64'h2000, 3'd3, 1'b0, 1'b0,
                   "lower entry deny priority");
        check_data(64'h4000, 3'd3, 1'b1, 1'b1,
                   "full-range fallback allow");
        check_data(64'h00ff_ffff_ffff_fff8, 3'd3, 1'b0, 1'b1,
                   "full-range top word");
        check_data(64'h0100_0000_0000_0000, 3'd0, 1'b0, 1'b0,
                   "outside implemented physical address");
        check_bus(64'h0100_0000_0000_0000, 3'd0, 1'b0, 1'b0,
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
        write_csr(`RV64_CSR_PMPADDR0, 64'h11ff);
        check_csr(`RV64_CSR_PMPADDR0, 64'h9ff,
                  "locked pmpaddr");
        write_csr(`RV64_CSR_PMPCFG0, 64'h1f);
        check_csr(`RV64_CSR_PMPCFG0, 64'h99,
                  "locked pmpcfg");

        // An unlocked address write atomically moves the normalized bounds.
        apply_reset();
        write_csr(`RV64_CSR_PMPADDR0, 64'h9ff);
        write_csr(`RV64_CSR_PMPCFG0, 64'h1b);
        priv_mode = `RV64_PRIV_U;
        check_data(64'h2000, 3'd3, 1'b0, 1'b1,
                   "pre-normalization-write region");
        priv_mode = `RV64_PRIV_M;
        write_csr(`RV64_CSR_PMPADDR0, 64'h11ff);
        priv_mode = `RV64_PRIV_U;
        check_data(64'h2000, 3'd3, 1'b0, 1'b0,
                   "old normalized region removed");
        check_data(64'h4000, 3'd3, 1'b0, 1'b1,
                   "new normalized region active");

        $display("PASS: 16-entry 4 KiB OFF/NAPOT PMP, WARL modes, priorities, bounds, and locks");
        $finish;
    end

endmodule
