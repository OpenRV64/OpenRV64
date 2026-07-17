`timescale 1ns/1ps
`include "core/isa/rv64-priv.v"

module tb_tlb;

    logic clk;
    logic rst_n;
    logic tlbi;

    logic lookup_valid;
    logic [63:0] lookup_vaddr;
    logic [3:0] lookup_vm_mode;
    logic [15:0] lookup_asid;
    logic [1:0] lookup_access;
    logic [1:0] lookup_priv;
    logic lookup_sum;
    logic lookup_mxr;
    wire lookup_hit;
    wire [63:0] lookup_paddr;
    wire lookup_page_fault;

    logic fill_valid;
    logic [63:0] fill_vaddr;
    logic [63:0] fill_paddr;
    logic [3:0] fill_vm_mode;
    logic [15:0] fill_asid;
    logic fill_global;
    logic [1:0] fill_level;
    logic fill_readable;
    logic fill_writable;
    logic fill_executable;
    logic fill_user;
    logic fill_accessed;
    logic fill_dirty;

    openrv64_bus_tlb #(
        .ENTRIES(4),
        .ASID_WIDTH(16)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .tlbi_i(tlbi),
        .lookup_valid_i(lookup_valid),
        .lookup_vaddr_i(lookup_vaddr),
        .lookup_vm_mode_i(lookup_vm_mode),
        .lookup_asid_i(lookup_asid),
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
        .fill_vm_mode_i(fill_vm_mode),
        .fill_asid_i(fill_asid),
        .fill_global_i(fill_global),
        .fill_level_i(fill_level),
        .fill_readable_i(fill_readable),
        .fill_writable_i(fill_writable),
        .fill_executable_i(fill_executable),
        .fill_user_i(fill_user),
        .fill_accessed_i(fill_accessed),
        .fill_dirty_i(fill_dirty)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic fill_entry;
        input [63:0] vaddr;
        input [63:0] paddr;
        input [3:0] vm_mode;
        input [15:0] asid;
        input global_entry;
        begin
            @(negedge clk);
            fill_valid = 1'b1;
            fill_vaddr = vaddr;
            fill_paddr = paddr;
            fill_vm_mode = vm_mode;
            fill_asid = asid;
            fill_global = global_entry;
            fill_level = `RV64_PAGE_LEVEL_4K;
            fill_readable = 1'b1;
            fill_writable = 1'b1;
            fill_executable = 1'b1;
            fill_user = 1'b0;
            fill_accessed = 1'b1;
            fill_dirty = 1'b1;
            @(posedge clk);
            @(negedge clk);
            fill_valid = 1'b0;
        end
    endtask

    task automatic fill_entry_attrs;
        input [63:0] vaddr;
        input [63:0] paddr;
        input [3:0] vm_mode;
        input [15:0] asid;
        input global_entry;
        input [1:0] level;
        input readable;
        input writable;
        input executable;
        input user_page;
        input accessed;
        input dirty;
        begin
            @(negedge clk);
            fill_valid = 1'b1;
            fill_vaddr = vaddr;
            fill_paddr = paddr;
            fill_vm_mode = vm_mode;
            fill_asid = asid;
            fill_global = global_entry;
            fill_level = level;
            fill_readable = readable;
            fill_writable = writable;
            fill_executable = executable;
            fill_user = user_page;
            fill_accessed = accessed;
            fill_dirty = dirty;
            @(posedge clk);
            @(negedge clk);
            fill_valid = 1'b0;
        end
    endtask

    task automatic expect_lookup;
        input [63:0] vaddr;
        input [3:0] vm_mode;
        input [15:0] asid;
        input expected_hit;
        input [63:0] expected_paddr;
        input [8*40-1:0] label;
        begin
            lookup_valid = 1'b1;
            lookup_vaddr = vaddr;
            lookup_vm_mode = vm_mode;
            lookup_asid = asid;
            #1;
            if (lookup_hit !== expected_hit ||
                (expected_hit &&
                 (lookup_paddr !== expected_paddr || lookup_page_fault))) begin
                $fatal(1, "%0s: hit/paddr=%b/%016x expected=%b/%016x",
                       label, lookup_hit, lookup_paddr,
                       expected_hit, expected_paddr);
            end
        end
    endtask

    task automatic expect_page_fault;
        input [63:0] vaddr;
        input [3:0] vm_mode;
        input [15:0] asid;
        input [8*40-1:0] label;
        begin
            lookup_valid = 1'b1;
            lookup_vaddr = vaddr;
            lookup_vm_mode = vm_mode;
            lookup_asid = asid;
            #1;
            if (!lookup_hit || !lookup_page_fault) begin
                $fatal(1, "%0s: expected TLB permission page fault", label);
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        tlbi = 1'b0;
        lookup_valid = 1'b0;
        lookup_vaddr = 64'd0;
        lookup_vm_mode = `RV64_SATP_MODE_SV39;
        lookup_asid = 16'd0;
        lookup_access = 2'd0;
        lookup_priv = `RV64_PRIV_S;
        lookup_sum = 1'b0;
        lookup_mxr = 1'b0;
        fill_valid = 1'b0;
        fill_vaddr = 64'd0;
        fill_paddr = 64'd0;
        fill_vm_mode = `RV64_SATP_MODE_SV39;
        fill_asid = 16'd0;
        fill_global = 1'b0;
        fill_level = `RV64_PAGE_LEVEL_4K;
        fill_readable = 1'b1;
        fill_writable = 1'b1;
        fill_executable = 1'b1;
        fill_user = 1'b0;
        fill_accessed = 1'b1;
        fill_dirty = 1'b1;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        expect_lookup(64'h0000_0000_0000_1abc,
                      `RV64_SATP_MODE_SV39, 16'd1,
                      1'b0, 64'd0, "reset miss");

        fill_entry(64'h0000_0000_0000_1000,
                   64'h0000_0000_8000_0000,
                   `RV64_SATP_MODE_SV39, 16'd1, 1'b0);
        expect_lookup(64'h0000_0000_0000_1abc,
                      `RV64_SATP_MODE_SV39, 16'd1,
                      1'b1, 64'h0000_0000_8000_0abc,
                      "ASID hit");
        expect_lookup(64'h0000_0000_0000_1abc,
                      `RV64_SATP_MODE_SV39, 16'd2,
                      1'b0, 64'd0, "ASID miss");
        expect_lookup(64'h0000_0000_0000_1abc, 4'd9, 16'd1,
                      1'b0, 64'd0, "VM mode miss");

        fill_entry(64'h0000_0000_0000_4000,
                   64'h0000_0000_9000_0000,
                   `RV64_SATP_MODE_SV39, 16'd3, 1'b1);
        expect_lookup(64'h0000_0000_0000_4123,
                      `RV64_SATP_MODE_SV39, 16'hffff,
                      1'b1, 64'h0000_0000_9000_0123,
                      "global hit");

        fill_entry(64'h0000_0000_0000_1000,
                   64'h0000_0000_a000_0000,
                   `RV64_SATP_MODE_SV39, 16'd1, 1'b0);
        expect_lookup(64'h0000_0000_0000_1555,
                      `RV64_SATP_MODE_SV39, 16'd1,
                      1'b1, 64'h0000_0000_a000_0555,
                      "duplicate refill");

        fill_entry(64'h0000_0000_0000_1000,
                   64'h0000_0000_b000_0000,
                   `RV64_SATP_MODE_SV39, 16'd2, 1'b0);
        expect_lookup(64'h0000_0000_0000_1666,
                      `RV64_SATP_MODE_SV39, 16'd1,
                      1'b1, 64'h0000_0000_a000_0666,
                      "parallel ASID one");
        expect_lookup(64'h0000_0000_0000_1666,
                      `RV64_SATP_MODE_SV39, 16'd2,
                      1'b1, 64'h0000_0000_b000_0666,
                      "parallel ASID two");

        fill_entry_attrs(64'h0000_0000_4000_0000,
                         64'h0000_0001_0000_0000,
                         `RV64_SATP_MODE_SV39, 16'd5, 1'b0,
                         `RV64_PAGE_LEVEL_1G,
                         1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1);
        expect_lookup(64'h0000_0000_5234_5678,
                      `RV64_SATP_MODE_SV39, 16'd5,
                      1'b1, 64'h0000_0001_1234_5678,
                      "1 GiB superpage");

        fill_entry_attrs(64'h0000_0000_0000_8000,
                         64'h0000_0000_c000_0000,
                         `RV64_SATP_MODE_SV39, 16'd6, 1'b0,
                         `RV64_PAGE_LEVEL_4K,
                         1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0);
        lookup_access = 2'd1;
        expect_page_fault(64'h8123, `RV64_SATP_MODE_SV39, 16'd6,
                          "dirty-bit write");
        lookup_access = 2'd0;
        expect_lookup(64'h8123, `RV64_SATP_MODE_SV39, 16'd6,
                      1'b1, 64'hc000_0123, "dirty-bit read");

        fill_entry_attrs(64'h0000_0000_0000_9000,
                         64'h0000_0000_d000_0000,
                         `RV64_SATP_MODE_SV39, 16'd7, 1'b0,
                         `RV64_PAGE_LEVEL_4K,
                         1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b1);
        lookup_sum = 1'b0;
        expect_page_fault(64'h9456, `RV64_SATP_MODE_SV39, 16'd7,
                          "supervisor user-page read without SUM");
        lookup_sum = 1'b1;
        expect_lookup(64'h9456, `RV64_SATP_MODE_SV39, 16'd7,
                      1'b1, 64'hd000_0456,
                      "supervisor user-page read with SUM");
        lookup_access = 2'd2;
        expect_page_fault(64'h9456, `RV64_SATP_MODE_SV39, 16'd7,
                          "supervisor user-page execute");
        lookup_access = 2'd0;
        lookup_sum = 1'b0;

        fill_entry_attrs(64'h0000_0000_0000_a000,
                         64'h0000_0000_e000_0000,
                         `RV64_SATP_MODE_SV39, 16'd8, 1'b0,
                         `RV64_PAGE_LEVEL_4K,
                         1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1);
        lookup_mxr = 1'b0;
        expect_page_fault(64'ha789, `RV64_SATP_MODE_SV39, 16'd8,
                          "execute-only read without MXR");
        lookup_mxr = 1'b1;
        expect_lookup(64'ha789, `RV64_SATP_MODE_SV39, 16'd8,
                      1'b1, 64'he000_0789,
                      "execute-only read with MXR");
        lookup_mxr = 1'b0;

        @(negedge clk);
        tlbi = 1'b1;
        #1;
        expect_lookup(64'h0000_0000_0000_1666,
                      `RV64_SATP_MODE_SV39, 16'd1,
                      1'b0, 64'd0, "TLBI immediate miss");
        @(posedge clk);
        @(negedge clk);
        tlbi = 1'b0;
        expect_lookup(64'h0000_0000_0000_4123,
                      `RV64_SATP_MODE_SV39, 16'hffff,
                      1'b0, 64'd0, "TLBI global shootdown");

        // Shootdown wins over a same-cycle refill.
        fill_valid = 1'b1;
        fill_vaddr = 64'h7000;
        fill_paddr = 64'hc000_0000;
        fill_vm_mode = `RV64_SATP_MODE_SV39;
        fill_asid = 16'd4;
        tlbi = 1'b1;
        @(posedge clk);
        @(negedge clk);
        fill_valid = 1'b0;
        tlbi = 1'b0;
        expect_lookup(64'h7123, `RV64_SATP_MODE_SV39, 16'd4,
                      1'b0, 64'd0,
                      "TLBI refill priority");

        $display("PASS: TLB CAM lookup, ASIDs, refill, and TLBI shootdown");
        $finish;
    end

endmodule
