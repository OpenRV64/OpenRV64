`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"

module tb_tlb_l2;

    reg clk;
    reg rst_n;
    reg tlbi;
    reg [`RV64_SATP_ASID_WIDTH-1:0] current_asid;
    reg lookup_valid;
    reg [`RV64_XLEN-1:0] lookup_vaddr;
    reg [`RV64_SATP_MODE_WIDTH-1:0] lookup_vm_mode;
    reg [`RV64_SATP_ASID_WIDTH-1:0] lookup_asid;
    reg [1:0] lookup_access;
    reg [`RV64_PRIV_WIDTH-1:0] lookup_priv;
    reg lookup_sum;
    reg lookup_mxr;
    wire lookup_hit;
    wire [`RV64_XLEN-1:0] lookup_paddr;
    wire lookup_page_fault;
    wire lookup_global;
    wire [`RV64_PAGE_LEVEL_WIDTH-1:0] lookup_level;
    wire lookup_readable;
    wire lookup_writable;
    wire lookup_executable;
    wire lookup_user;
    wire lookup_accessed;
    wire lookup_dirty;

    reg fill_valid;
    reg [`RV64_XLEN-1:0] fill_vaddr;
    reg [`RV64_XLEN-1:0] fill_paddr;
    reg [`RV64_SATP_MODE_WIDTH-1:0] fill_vm_mode;
    reg [`RV64_SATP_ASID_WIDTH-1:0] fill_asid;
    reg fill_global;
    reg [`RV64_PAGE_LEVEL_WIDTH-1:0] fill_level;
    reg fill_readable;
    reg fill_writable;
    reg fill_executable;
    reg fill_user;
    reg fill_accessed;
    reg fill_dirty;
    wire fill_evict_current;
    integer superpage_index;

    openrv64_bus_tlb_l2 #(
        .ENTRIES(256),
        .WAYS(4),
        .ASID_WIDTH(`RV64_SATP_ASID_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .tlbi_i(tlbi),
        .current_asid_i(current_asid),
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
        .lookup_global_o(lookup_global),
        .lookup_level_o(lookup_level),
        .lookup_readable_o(lookup_readable),
        .lookup_writable_o(lookup_writable),
        .lookup_executable_o(lookup_executable),
        .lookup_user_o(lookup_user),
        .lookup_accessed_o(lookup_accessed),
        .lookup_dirty_o(lookup_dirty),
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
        .fill_dirty_i(fill_dirty),
        .fill_evict_current_o(fill_evict_current)
    );

    always #5 clk = ~clk;

    task automatic install_4k;
        input [`RV64_XLEN-1:0] vaddr;
        input [`RV64_XLEN-1:0] paddr;
        input [`RV64_SATP_ASID_WIDTH-1:0] asid;
        input global_entry;
        input readable;
        input writable;
        input executable;
        input user_page;
        begin
            @(negedge clk);
            fill_valid = 1'b1;
            fill_vaddr = vaddr;
            fill_paddr = paddr;
            fill_vm_mode = `RV64_SATP_MODE_SV39;
            fill_asid = asid;
            fill_global = global_entry;
            fill_level = `RV64_PAGE_LEVEL_4K;
            fill_readable = readable;
            fill_writable = writable;
            fill_executable = executable;
            fill_user = user_page;
            fill_accessed = 1'b1;
            fill_dirty = 1'b1;
            @(negedge clk);
            fill_valid = 1'b0;
        end
    endtask

    task automatic expect_lookup;
        input [`RV64_XLEN-1:0] vaddr;
        input [`RV64_SATP_ASID_WIDTH-1:0] asid;
        input [1:0] access_kind;
        input [`RV64_PRIV_WIDTH-1:0] privilege;
        input sum;
        input expected_hit;
        input expected_fault;
        input [`RV64_XLEN-1:0] expected_paddr;
        input [255:0] label;
        begin
            lookup_valid = 1'b1;
            lookup_vaddr = vaddr;
            lookup_vm_mode = `RV64_SATP_MODE_SV39;
            lookup_asid = asid;
            lookup_access = access_kind;
            lookup_priv = privilege;
            lookup_sum = sum;
            lookup_mxr = 1'b0;
            #1;
            if (lookup_hit !== expected_hit)
                $fatal(1, "%0s: hit=%b expected=%b",
                       label, lookup_hit, expected_hit);
            if (expected_hit &&
                ((lookup_page_fault !== expected_fault) ||
                 (lookup_paddr !== expected_paddr)))
                $fatal(1,
                    "%0s: fault=%b paddr=%016x expected fault=%b paddr=%016x",
                    label, lookup_page_fault, lookup_paddr,
                    expected_fault, expected_paddr);
            lookup_valid = 1'b0;
            #1;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        tlbi = 1'b0;
        current_asid = 16'd0;
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
        fill_readable = 1'b0;
        fill_writable = 1'b0;
        fill_executable = 1'b0;
        fill_user = 1'b0;
        fill_accessed = 1'b0;
        fill_dirty = 1'b0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        install_4k(64'h0000_0000_0000_1000,
                   64'h0000_0000_4000_1000,
                   16'h0011, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0);
        expect_lookup(64'h0000_0000_0000_1123, 16'h0011, 2'd0,
                      `RV64_PRIV_S, 1'b0, 1'b1, 1'b0,
                      64'h0000_0000_4000_1123, "ASID translation hit");
        expect_lookup(64'h0000_0000_0000_1123, 16'h0022, 2'd0,
                      `RV64_PRIV_S, 1'b0, 1'b0, 1'b0, 64'd0,
                      "ASID mismatch");

        install_4k(64'h0000_0000_0000_2000,
                   64'h0000_0000_5000_2000,
                   16'h0011, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0);
        expect_lookup(64'h0000_0000_0000_2040, 16'h0022, 2'd0,
                      `RV64_PRIV_S, 1'b0, 1'b1, 1'b0,
                      64'h0000_0000_5000_2040, "global translation");
        expect_lookup(64'h0000_0000_0000_2040, 16'h0022, 2'd1,
                      `RV64_PRIV_S, 1'b0, 1'b1, 1'b1,
                      64'h0000_0000_5000_2040, "permission fault");

        // Five VPNs separated by 64 pages map to one of the 64 sets.  The
        // fifth install must evict the first but preserve the other ways.
        install_4k(64'h0000_0000_0000_3000, 64'h6000_3000,
                   16'h0033, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0);
        install_4k(64'h0000_0000_0004_3000, 64'h6004_3000,
                   16'h0033, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0);
        install_4k(64'h0000_0000_0008_3000, 64'h6008_3000,
                   16'h0033, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0);
        install_4k(64'h0000_0000_000c_3000, 64'h600c_3000,
                   16'h0033, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0);
        install_4k(64'h0000_0000_0010_3000, 64'h6010_3000,
                   16'h0033, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0);
        expect_lookup(64'h0000_0000_0000_3008, 16'h0033, 2'd0,
                      `RV64_PRIV_S, 1'b0, 1'b0, 1'b0, 64'd0,
                      "four-way eviction");
        expect_lookup(64'h0000_0000_0004_3008, 16'h0033, 2'd0,
                      `RV64_PRIV_S, 1'b0, 1'b1, 1'b0,
                      64'h0000_0000_6004_3008, "surviving way");

        @(negedge clk);
        fill_valid = 1'b1;
        fill_vaddr = 64'h0000_0000_0040_0000;
        fill_paddr = 64'h0000_0000_7000_0000;
        fill_vm_mode = `RV64_SATP_MODE_SV39;
        fill_asid = 16'h0044;
        fill_global = 1'b0;
        fill_level = `RV64_PAGE_LEVEL_2M;
        fill_readable = 1'b1;
        fill_writable = 1'b1;
        fill_executable = 1'b1;
        fill_user = 1'b0;
        fill_accessed = 1'b1;
        fill_dirty = 1'b1;
        @(negedge clk);
        if (!dut.diag_superpage_fill)
            $fatal(1, "superpage fill was not classified");
        fill_valid = 1'b0;
        expect_lookup(64'h0000_0000_0040_1000, 16'h0044, 2'd0,
                      `RV64_PRIV_S, 1'b0, 1'b1, 1'b0,
                      64'h0000_0000_7000_1000,
                      "superpage sidecar");
        lookup_valid = 1'b1;
        lookup_vaddr = 64'h0000_0000_0040_1000;
        lookup_asid = 16'h0044;
        #1;
        if (lookup_level !== `RV64_PAGE_LEVEL_2M)
            $fatal(1, "superpage level was not returned");
        lookup_valid = 1'b0;

        /*
         * Active-ASID and global entries are the protected replacement class.
         * Fill one set with three protected entries and one inactive-ASID
         * entry. The next fill must consume the inactive entry without asking
         * the caller to flush its current-context micro-TLBs.
         */
        current_asid = 16'h0055;
        install_4k(64'h0000_0000_0000_5000, 64'h6100_5000,
                   16'h0055, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0);
        install_4k(64'h0000_0000_0004_5000, 64'h6104_5000,
                   16'h0066, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0);
        install_4k(64'h0000_0000_0008_5000, 64'h6108_5000,
                   16'h0055, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0);
        install_4k(64'h0000_0000_000c_5000, 64'h610c_5000,
                   16'h0000, 1'b1, 1'b1, 1'b1, 1'b0, 1'b0);

        @(negedge clk);
        fill_valid = 1'b1;
        fill_vaddr = 64'h0000_0000_0010_5000;
        fill_paddr = 64'h6110_5000;
        fill_vm_mode = `RV64_SATP_MODE_SV39;
        fill_asid = 16'h0055;
        fill_global = 1'b0;
        fill_level = `RV64_PAGE_LEVEL_4K;
        fill_readable = 1'b1;
        fill_writable = 1'b1;
        fill_executable = 1'b0;
        fill_user = 1'b0;
        fill_accessed = 1'b1;
        fill_dirty = 1'b1;
        @(posedge clk);
        #1;
        if (fill_evict_current)
            $fatal(1, "inactive-ASID victim requested micro-TLB flush");
        @(negedge clk);
        fill_valid = 1'b0;
        expect_lookup(64'h0000_0000_0004_5008, 16'h0066, 2'd0,
                      `RV64_PRIV_S, 1'b0, 1'b0, 1'b0, 64'd0,
                      "inactive-ASID preferred victim");
        expect_lookup(64'h0000_0000_0000_5008, 16'h0055, 2'd0,
                      `RV64_PRIV_S, 1'b0, 1'b1, 1'b0,
                      64'h6100_5008, "active-ASID survivor");
        expect_lookup(64'h0000_0000_000c_5008, 16'h7777, 2'd0,
                      `RV64_PRIV_S, 1'b0, 1'b1, 1'b0,
                      64'h610c_5008, "global survivor");

        /*
         * The set now contains only active-ASID/global entries. Forward
         * progress permits replacement, but it must request a full
         * current-context micro-TLB flush after the replacement edge.
         */
        @(negedge clk);
        fill_valid = 1'b1;
        fill_vaddr = 64'h0000_0000_0014_5000;
        fill_paddr = 64'h6114_5000;
        fill_asid = 16'h0055;
        @(posedge clk);
        #1;
        if (!fill_evict_current)
            $fatal(1, "forced active-ASID victim did not request flush");
        @(negedge clk);
        fill_valid = 1'b0;

        @(negedge clk);
        tlbi = 1'b1;
        @(negedge clk);
        tlbi = 1'b0;
        expect_lookup(64'h0000_0000_0004_3008, 16'h0033, 2'd0,
                      `RV64_PRIV_S, 1'b0, 1'b0, 1'b0, 64'd0,
                      "global invalidation");

        // Invalidation has priority over both a visible lookup hit and a
        // same-edge fill.  This is the critical PTW-response/SFENCE race:
        // the old entry must disappear combinationally when TLBI rises, and
        // the incoming translation must not be installed on the edge.
        install_4k(64'h0000_0000_0000_6000,
                   64'h0000_0000_7100_6000,
                   16'h0066, 1'b0, 1'b1, 1'b1, 1'b1, 1'b0);
        lookup_valid = 1'b1;
        lookup_vaddr = 64'h0000_0000_0000_6040;
        lookup_vm_mode = `RV64_SATP_MODE_SV39;
        lookup_asid = 16'h0066;
        lookup_access = 2'd0;
        lookup_priv = `RV64_PRIV_S;
        lookup_sum = 1'b0;
        lookup_mxr = 1'b0;
        #1;
        if (!lookup_hit)
            $fatal(1, "TLBI race setup did not produce an L2 hit");

        @(negedge clk);
        fill_valid = 1'b1;
        fill_vaddr = 64'h0000_0000_0000_7000;
        fill_paddr = 64'h0000_0000_7200_7000;
        fill_vm_mode = `RV64_SATP_MODE_SV39;
        fill_asid = 16'h0077;
        fill_global = 1'b0;
        fill_level = `RV64_PAGE_LEVEL_4K;
        fill_readable = 1'b1;
        fill_writable = 1'b1;
        fill_executable = 1'b1;
        fill_user = 1'b0;
        fill_accessed = 1'b1;
        fill_dirty = 1'b1;
        tlbi = 1'b1;
        #1;
        if (lookup_hit || dut.diag_lookup || dut.diag_fill)
            $fatal(1, "TLBI did not suppress lookup/fill immediately");
        @(negedge clk);
        tlbi = 1'b0;
        fill_valid = 1'b0;
        lookup_valid = 1'b0;
        expect_lookup(64'h0000_0000_0000_6040, 16'h0066, 2'd0,
                      `RV64_PRIV_S, 1'b0, 1'b0, 1'b0, 64'd0,
                      "TLBI removed resident entry");
        expect_lookup(64'h0000_0000_0000_7040, 16'h0077, 2'd0,
                      `RV64_PRIV_S, 1'b0, 1'b0, 1'b0, 64'd0,
                      "TLBI rejected same-edge fill");

        // Apply the same active-ASID preference and forced-flush contract to
        // the fully associative superpage sidecar.
        current_asid = 16'h0088;
        for (superpage_index = 0; superpage_index < 8;
             superpage_index = superpage_index + 1) begin
            @(negedge clk);
            fill_valid = 1'b1;
            fill_vaddr = superpage_index * 64'h20_0000;
            fill_paddr = 64'h8000_0000 +
                         superpage_index * 64'h20_0000;
            fill_vm_mode = `RV64_SATP_MODE_SV39;
            fill_asid = (superpage_index == 1) ?
                        16'h0099 : 16'h0088;
            fill_global = 1'b0;
            fill_level = `RV64_PAGE_LEVEL_2M;
            fill_readable = 1'b1;
            fill_writable = 1'b1;
            fill_executable = 1'b1;
            fill_user = 1'b0;
            fill_accessed = 1'b1;
            fill_dirty = 1'b1;
            @(negedge clk);
            fill_valid = 1'b0;
        end
        @(negedge clk);
        fill_valid = 1'b1;
        fill_vaddr = 64'h0100_0000;
        fill_paddr = 64'h9000_0000;
        fill_asid = 16'h0088;
        @(posedge clk);
        #1;
        if (fill_evict_current)
            $fatal(1,
                "superpage inactive-ASID victim requested micro flush");
        @(negedge clk);
        fill_valid = 1'b0;

        @(negedge clk);
        fill_valid = 1'b1;
        fill_vaddr = 64'h0120_0000;
        fill_paddr = 64'h9020_0000;
        @(posedge clk);
        #1;
        if (!fill_evict_current)
            $fatal(1,
                "forced current-ASID superpage victim did not request flush");
        @(negedge clk);
        fill_valid = 1'b0;

        $display("PASS: 256-entry four-way shared L2 TLB");
        $finish;
    end

endmodule
