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
        input [8*32-1:0] label;
        begin
            csr_addr = addr;
            #1;
            if (!csr_match || !csr_writable || csr_rdata !== expected) begin
                $fatal(1, "%0s: match=%0b writable=%0b data=%016x/%016x",
                       label, csr_match, csr_writable, csr_rdata, expected);
            end
        end
    endtask

    task automatic check_data;
        input [`RV64_XLEN-1:0] addr;
        input [2:0] size;
        input is_write;
        input expected;
        input [8*32-1:0] label;
        begin
            data_valid = 1'b1;
            data_addr = addr;
            data_size = size;
            data_write = is_write;
            #1;
            if (data_allow !== expected) begin
                $fatal(1, "%0s: data allow=%0b/%0b", label,
                       data_allow, expected);
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
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;

        if (!instr_allow || !data_allow) begin
            $fatal(1, "M-mode default PMP policy denied access");
        end
        bus_valid = 1'b1;
        bus_addr = 64'h800;
        bus_size = 3'd3;
        #1;
        if (!bus_allow) begin
            $fatal(1, "M-mode physical requester was denied");
        end

        priv_mode = `RV64_PRIV_U;
        #1;
        if (instr_allow || data_allow) begin
            $fatal(1, "U-mode no-match PMP policy allowed access");
        end
        bus_priv_mode = `RV64_PRIV_U;
        #1;
        if (bus_allow) begin
            $fatal(1, "U-mode physical requester bypassed PMP");
        end

        priv_mode = `RV64_PRIV_M;
        check_csr(`RV64_CSR_PMPADDR7, 64'h0, "pmpaddr7 reset");
        write_csr(`RV64_CSR_PMPADDR7, 64'h12345);
        check_csr(`RV64_CSR_PMPADDR7, 64'h12345, "pmpaddr7 write");
        write_csr(`RV64_CSR_PMPCFG0, 64'h1b00_0000_0000_0000);
        check_csr(`RV64_CSR_PMPCFG0, 64'h1b00_0000_0000_0000,
                  "pmpcfg0 upper entries");
        csr_addr = 12'h3b8;
        #1;
        if (csr_match || csr_writable) begin
            $fatal(1, "ninth PMP entry was unexpectedly implemented");
        end

        write_csr(`RV64_CSR_PMPADDR0, 64'h400);
        write_csr(`RV64_CSR_PMPCFG0, 64'h0d);

        priv_mode = `RV64_PRIV_U;
        instr_addr = 64'h800;
        #1;
        if (!instr_allow) begin
            $fatal(1, "TOR execute permission was not applied");
        end
        check_data(64'h800, 3'd3, 1'b0, 1'b1, "TOR read");
        check_data(64'h800, 3'd3, 1'b1, 1'b0, "TOR write denied");
        check_data(64'hffc, 3'd3, 1'b0, 1'b0, "TOR partial overlap denied");

        priv_mode = `RV64_PRIV_M;
        check_data(64'h800, 3'd3, 1'b1, 1'b1, "unlocked M bypass");
        write_csr(`RV64_CSR_PMPCFG0, 64'h8d);
        check_data(64'h800, 3'd3, 1'b1, 1'b0, "locked M permission");

        write_csr(`RV64_CSR_PMPADDR0, 64'h800);
        check_csr(`RV64_CSR_PMPADDR0, 64'h400, "locked pmpaddr0");
        write_csr(`RV64_CSR_PMPCFG0, 64'h0f);
        check_csr(`RV64_CSR_PMPCFG0, 64'h8d, "locked pmpcfg0");

        write_csr(`RV64_CSR_PMPADDR1, 64'h800);
        write_csr(`RV64_CSR_PMPADDR2, 64'hc01);
        write_csr(`RV64_CSR_PMPCFG0, 64'h001b_118d);
        check_csr(`RV64_CSR_PMPCFG0, 64'h001b_118d,
                  "NA4 and NAPOT config");

        priv_mode = `RV64_PRIV_U;
        check_data(64'h2000, 3'd2, 1'b0, 1'b1, "NA4 read");
        check_data(64'h2004, 3'd0, 1'b0, 1'b0, "NA4 outside");
        check_data(64'h3008, 3'd3, 1'b0, 1'b1, "NAPOT read");
        check_data(64'h3008, 3'd3, 1'b1, 1'b1, "NAPOT write");
        instr_addr = 64'h3008;
        #1;
        if (instr_allow) begin
            $fatal(1, "NAPOT execute permission was incorrectly granted");
        end

        priv_mode = `RV64_PRIV_M;
        write_csr(`RV64_CSR_PMPADDR3, 64'hffff_ffff_ffff_ffff);
        write_csr(`RV64_CSR_PMPCFG0, 64'h1b1b_118d);
        priv_mode = `RV64_PRIV_U;
        check_data(64'hffff_ffff_ffff_fff8, 3'd3, 1'b1, 1'b1,
                   "full-range NAPOT");

        $display("PASS: RV64 PMP modes, priorities, and lock behavior");
        $finish;
    end

endmodule
