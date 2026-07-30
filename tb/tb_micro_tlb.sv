`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"

module tb_micro_tlb;

    reg clk;
    reg rst_n;
    reg flush;
    reg lookup_valid;
    reg [`RV64_XLEN-1:0] lookup_vaddr;
    reg [1:0] lookup_access;
    reg [`RV64_PRIV_WIDTH-1:0] lookup_priv;
    reg lookup_sum;
    reg lookup_mxr;
    wire lookup_hit;
    wire [`RV64_XLEN-1:0] lookup_paddr;
    wire lookup_page_fault;
    reg fill_valid;
    reg [`RV64_XLEN-1:0] fill_vaddr;
    reg [`RV64_XLEN-1:0] fill_paddr;
    reg [`RV64_PAGE_LEVEL_WIDTH-1:0] fill_level;
    reg fill_readable;
    reg fill_writable;
    reg fill_executable;
    reg fill_user;
    reg fill_accessed;
    reg fill_dirty;

    openrv64_bus_micro_tlb #(.ENTRIES(4)) dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .lookup_valid_i(lookup_valid),
        .lookup_vaddr_i(lookup_vaddr),
        .lookup_access_i(lookup_access),
        .lookup_priv_i(lookup_priv),
        .lookup_sum_i(lookup_sum),
        .lookup_mxr_i(lookup_mxr),
        .lookup_hit_o(lookup_hit),
        .lookup_paddr_o(lookup_paddr),
        .lookup_page_fault_o(lookup_page_fault),
        .fill_valid_i(fill_valid),
        .fill_vaddr_i(fill_vaddr),
        .fill_paddr_i(fill_paddr),
        .fill_level_i(fill_level),
        .fill_readable_i(fill_readable),
        .fill_writable_i(fill_writable),
        .fill_executable_i(fill_executable),
        .fill_user_i(fill_user),
        .fill_accessed_i(fill_accessed),
        .fill_dirty_i(fill_dirty)
    );

    always #5 clk = ~clk;

    task automatic install;
        input [`RV64_XLEN-1:0] vaddr;
        input [`RV64_XLEN-1:0] paddr;
        input [`RV64_PAGE_LEVEL_WIDTH-1:0] level;
        input writable;
        begin
            @(negedge clk);
            fill_valid = 1'b1;
            fill_vaddr = vaddr;
            fill_paddr = paddr;
            fill_level = level;
            fill_readable = 1'b1;
            fill_writable = writable;
            fill_executable = 1'b1;
            fill_user = 1'b0;
            fill_accessed = 1'b1;
            fill_dirty = writable;
            @(negedge clk);
            fill_valid = 1'b0;
        end
    endtask

    task automatic expect_lookup;
        input [`RV64_XLEN-1:0] vaddr;
        input expected_hit;
        input expected_fault;
        input [`RV64_XLEN-1:0] expected_paddr;
        input [8*40-1:0] label;
        begin
            lookup_valid = 1'b1;
            lookup_vaddr = vaddr;
            #1;
            if ((lookup_hit !== expected_hit) ||
                (expected_hit &&
                 ((lookup_page_fault !== expected_fault) ||
                  (lookup_paddr !== expected_paddr))))
                $fatal(1,
                    "%0s hit/fault/paddr=%b/%b/%h expected=%b/%b/%h",
                    label, lookup_hit, lookup_page_fault, lookup_paddr,
                    expected_hit, expected_fault, expected_paddr);
            lookup_valid = 1'b0;
            #1;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        lookup_valid = 1'b0;
        lookup_vaddr = 64'd0;
        lookup_access = 2'd0;
        lookup_priv = `RV64_PRIV_S;
        lookup_sum = 1'b0;
        lookup_mxr = 1'b0;
        fill_valid = 1'b0;
        fill_vaddr = 64'd0;
        fill_paddr = 64'd0;
        fill_level = `RV64_PAGE_LEVEL_4K;
        fill_readable = 1'b1;
        fill_writable = 1'b1;
        fill_executable = 1'b1;
        fill_user = 1'b0;
        fill_accessed = 1'b1;
        fill_dirty = 1'b1;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        expect_lookup(64'h1234, 1'b0, 1'b0, 64'd0, "reset miss");

        install(64'h1000, 64'h8000_0000, `RV64_PAGE_LEVEL_4K, 1'b1);
        expect_lookup(64'h1234, 1'b1, 1'b0, 64'h8000_0234, "4K hit");

        install(64'h0040_0000, 64'h9000_0000,
                `RV64_PAGE_LEVEL_2M, 1'b1);
        expect_lookup(64'h0041_2345, 1'b1, 1'b0, 64'h9001_2345,
                      "2M hit");

        install(64'h3000, 64'ha000_0000, `RV64_PAGE_LEVEL_4K, 1'b0);
        lookup_access = 2'd1;
        expect_lookup(64'h3456, 1'b1, 1'b1, 64'ha000_0456,
                      "write permission");
        lookup_access = 2'd0;

        // A current-context flush suppresses a visible hit immediately and
        // wins over a same-edge refill.
        lookup_valid = 1'b1;
        lookup_vaddr = 64'h1234;
        #1;
        if (!lookup_hit)
            $fatal(1, "flush setup did not hit");
        @(negedge clk);
        fill_valid = 1'b1;
        fill_vaddr = 64'h5000;
        fill_paddr = 64'hb000_0000;
        flush = 1'b1;
        #1;
        if (lookup_hit)
            $fatal(1, "flush did not suppress lookup immediately");
        @(negedge clk);
        flush = 1'b0;
        fill_valid = 1'b0;
        lookup_valid = 1'b0;
        expect_lookup(64'h1234, 1'b0, 1'b0, 64'd0,
                      "flush removed old");
        expect_lookup(64'h5123, 1'b0, 1'b0, 64'd0,
                      "flush rejected refill");

        $display("PASS: untagged current-context micro-TLB");
        $finish;
    end

endmodule
