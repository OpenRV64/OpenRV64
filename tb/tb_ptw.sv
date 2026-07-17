`timescale 1ns/1ps
`include "core/isa/rv64-priv.v"

module tb_ptw;

    localparam [1:0] ACCESS_READ = 2'd0;
    localparam [1:0] ACCESS_WRITE = 2'd1;
    localparam [1:0] ACCESS_EXEC = 2'd2;

    logic clk;
    logic rst_n;

    logic req_valid;
    wire req_ready;
    logic [63:0] req_vaddr;
    logic [1:0] req_access;
    logic [1:0] req_priv;
    logic [3:0] req_vm_mode;
    logic [15:0] req_asid;
    logic [43:0] req_root_ppn;
    logic req_sum;
    logic req_mxr;

    wire resp_valid;
    logic resp_ready;
    wire [63:0] resp_paddr;
    wire resp_page_fault;
    wire resp_access_fault;
    wire resp_global;
    wire [1:0] resp_level;
    wire resp_readable;
    wire resp_writable;
    wire resp_executable;
    wire resp_user;
    wire resp_accessed;
    wire resp_dirty;

    wire mem_valid;
    wire mem_ready;
    wire mem_write;
    wire [63:0] mem_addr;
    wire [63:0] mem_wdata;
    wire [7:0] mem_wstrb;
    wire [63:0] mem_rdata;
    wire mem_error;

    reg [63:0] page_memory [0:8191];
    logic inject_mem_error;
    logic [63:0] mem_error_addr;
    integer memory_index;

    assign mem_ready = mem_valid;
    assign mem_rdata = page_memory[mem_addr[15:3]];
    assign mem_error = mem_valid && inject_mem_error &&
                       (mem_addr == mem_error_addr);

    openrv64_bus_ptw dut (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_vaddr_i(req_vaddr),
        .req_access_i(req_access),
        .req_priv_i(req_priv),
        .req_vm_mode_i(req_vm_mode),
        .req_asid_i(req_asid),
        .req_root_ppn_i(req_root_ppn),
        .req_sum_i(req_sum),
        .req_mxr_i(req_mxr),
        .resp_valid_o(resp_valid),
        .resp_ready_i(resp_ready),
        .resp_paddr_o(resp_paddr),
        .resp_page_fault_o(resp_page_fault),
        .resp_access_fault_o(resp_access_fault),
        .resp_global_o(resp_global),
        .resp_level_o(resp_level),
        .resp_readable_o(resp_readable),
        .resp_writable_o(resp_writable),
        .resp_executable_o(resp_executable),
        .resp_user_o(resp_user),
        .resp_accessed_o(resp_accessed),
        .resp_dirty_o(resp_dirty),
        .mem_valid_o(mem_valid),
        .mem_ready_i(mem_ready),
        .mem_write_o(mem_write),
        .mem_addr_o(mem_addr),
        .mem_wdata_o(mem_wdata),
        .mem_wstrb_o(mem_wstrb),
        .mem_rdata_i(mem_rdata),
        .mem_error_i(mem_error)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic [63:0] make_pte;
        input [43:0] ppn;
        input valid;
        input readable;
        input writable;
        input executable;
        input user_page;
        input global_entry;
        input accessed;
        input dirty;
        begin
            make_pte = 64'd0;
            make_pte[`RV64_PTE_PPN_BITS] = ppn;
            make_pte[`RV64_PTE_V_BIT] = valid;
            make_pte[`RV64_PTE_R_BIT] = readable;
            make_pte[`RV64_PTE_W_BIT] = writable;
            make_pte[`RV64_PTE_X_BIT] = executable;
            make_pte[`RV64_PTE_U_BIT] = user_page;
            make_pte[`RV64_PTE_G_BIT] = global_entry;
            make_pte[`RV64_PTE_A_BIT] = accessed;
            make_pte[`RV64_PTE_D_BIT] = dirty;
        end
    endfunction

    task automatic write_pte;
        input [43:0] table_ppn;
        input [8:0] vpn;
        input [63:0] pte;
        integer index;
        begin
            index = (table_ppn * 512) + vpn;
            page_memory[index] = pte;
        end
    endtask

    task automatic map_4k;
        input [63:0] vaddr;
        input [43:0] root_ppn;
        input [43:0] level1_ppn;
        input [43:0] level0_ppn;
        input [43:0] leaf_ppn;
        input readable;
        input writable;
        input executable;
        input user_page;
        input accessed;
        input dirty;
        input parent_global;
        begin
            write_pte(root_ppn, vaddr[38:30],
                      make_pte(level1_ppn, 1'b1, 1'b0, 1'b0, 1'b0,
                               1'b0, parent_global, 1'b0, 1'b0));
            write_pte(level1_ppn, vaddr[29:21],
                      make_pte(level0_ppn, 1'b1, 1'b0, 1'b0, 1'b0,
                               1'b0, 1'b0, 1'b0, 1'b0));
            write_pte(level0_ppn, vaddr[20:12],
                      make_pte(leaf_ppn, 1'b1, readable, writable,
                               executable, user_page, 1'b0,
                               accessed, dirty));
        end
    endtask

    task automatic issue_request;
        input [63:0] vaddr;
        input [1:0] access_kind;
        input [1:0] privilege;
        input [3:0] vm_mode;
        input [43:0] root_ppn;
        input sum;
        input mxr;
        input [63:0] expected_paddr;
        input expected_page_fault;
        input expected_access_fault;
        input [1:0] expected_level;
        input expected_global;
        input [8*48-1:0] label;
        integer cycles;
        begin
            @(negedge clk);
            if (!req_ready) begin
                $fatal(1, "%0s: PTW was not ready", label);
            end
            req_vaddr = vaddr;
            req_access = access_kind;
            req_priv = privilege;
            req_vm_mode = vm_mode;
            req_root_ppn = root_ppn;
            req_sum = sum;
            req_mxr = mxr;
            req_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;

            cycles = 0;
            while (!resp_valid && cycles < 12) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            #1;
            if (!resp_valid ||
                resp_page_fault !== expected_page_fault ||
                resp_access_fault !== expected_access_fault ||
                (!expected_page_fault && !expected_access_fault &&
                 (resp_paddr !== expected_paddr ||
                  resp_level !== expected_level ||
                  resp_global !== expected_global))) begin
                $fatal(1,
                    "%0s: paddr/pf/af/level/global=%016x/%b/%b/%0d/%b",
                    label, resp_paddr, resp_page_fault,
                    resp_access_fault, resp_level, resp_global);
            end

            resp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            resp_ready = 1'b0;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        req_valid = 1'b0;
        req_vaddr = 64'd0;
        req_access = ACCESS_READ;
        req_priv = `RV64_PRIV_S;
        req_vm_mode = `RV64_SATP_MODE_SV39;
        req_asid = 16'h1234;
        req_root_ppn = 44'd1;
        req_sum = 1'b0;
        req_mxr = 1'b0;
        resp_ready = 1'b0;
        inject_mem_error = 1'b0;
        mem_error_addr = 64'd0;

        for (memory_index = 0;
             memory_index < 8192;
             memory_index = memory_index + 1) begin
            page_memory[memory_index] = 64'd0;
        end

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        map_4k(64'h0000_0000_1234_5678,
               44'd1, 44'd2, 44'd3, 44'h80000,
               1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1);
        issue_request(64'h0000_0000_1234_5678,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'h0000_0000_8000_0678,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b1,
                      "4 KiB translation and inherited global");

        write_pte(44'd2, 9'h100,
                  make_pte(44'h90000, 1'b1,
                           1'b1, 1'b0, 1'b0, 1'b0,
                           1'b0, 1'b1, 1'b1));
        issue_request(64'h0000_0000_2000_1234,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'h0000_0000_9000_1234,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_2M, 1'b1,
                      "2 MiB superpage");

        write_pte(44'd1, 9'h001,
                  make_pte(44'h100000, 1'b1,
                           1'b1, 1'b0, 1'b1, 1'b0,
                           1'b0, 1'b1, 1'b1));
        issue_request(64'h0000_0000_4000_1234,
                      ACCESS_EXEC, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'h0000_0001_0000_1234,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_1G, 1'b0,
                      "1 GiB superpage");

        write_pte(44'd1, 9'h002,
                  make_pte(44'h100001, 1'b1,
                           1'b1, 1'b0, 1'b0, 1'b0,
                           1'b0, 1'b1, 1'b1));
        issue_request(64'h0000_0000_8000_0000,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'd0, 1'b1, 1'b0,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "misaligned superpage fault");

        issue_request(64'h0000_0080_0000_0000,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'd0, 1'b1, 1'b0,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "noncanonical virtual address");

        map_4k(64'h0000_0000_3000_0456,
               44'd1, 44'd2, 44'd3, 44'ha0000,
               1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b1, 1'b0);
        issue_request(64'h0000_0000_3000_0456,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'd0, 1'b1, 1'b0,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "SUM blocks supervisor user-page load");
        issue_request(64'h0000_0000_3000_0456,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b1, 1'b0,
                      64'h0000_0000_a000_0456,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b0,
                      "SUM permits supervisor user-page load");
        issue_request(64'h0000_0000_3000_0456,
                      ACCESS_EXEC, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b1, 1'b0,
                      64'd0, 1'b1, 1'b0,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "SUM never permits supervisor user-page execute");

        map_4k(64'h0000_0000_3200_0789,
               44'd1, 44'd2, 44'd3, 44'hb0000,
               1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 1'b0);
        issue_request(64'h0000_0000_3200_0789,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'd0, 1'b1, 1'b0,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "MXR disabled on execute-only page");
        issue_request(64'h0000_0000_3200_0789,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b1,
                      64'h0000_0000_b000_0789,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b0,
                      "MXR enabled on execute-only page");

        map_4k(64'h0000_0000_3400_0123,
               44'd1, 44'd2, 44'd3, 44'hc0000,
               1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0);
        issue_request(64'h0000_0000_3400_0123,
                      ACCESS_WRITE, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'd0, 1'b1, 1'b0,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "dirty-bit write fault");
        issue_request(64'h0000_0000_3400_0123,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'h0000_0000_c000_0123,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b0,
                      "dirty-bit read succeeds");

        mem_error_addr = 64'h0000_0000_0000_1000;
        inject_mem_error = 1'b1;
        issue_request(64'h0000_0000_1234_5678,
                      ACCESS_READ, `RV64_PRIV_S,
                      `RV64_SATP_MODE_SV39, 44'd1, 1'b0, 1'b0,
                      64'd0, 1'b0, 1'b1,
                      `RV64_PAGE_LEVEL_4K, 1'b0,
                      "PTE physical access fault");
        inject_mem_error = 1'b0;

        issue_request(64'hdead_beef_cafe_0123,
                      ACCESS_READ, `RV64_PRIV_M,
                      `RV64_SATP_MODE_BARE, 44'd0, 1'b0, 1'b0,
                      64'hdead_beef_cafe_0123,
                      1'b0, 1'b0, `RV64_PAGE_LEVEL_4K, 1'b1,
                      "Bare identity translation");

        $display("PASS: Sv39 PTW walk, permissions, superpages, and faults");
        $finish;
    end

    wire unused_memory_request = |{mem_write, mem_wdata, mem_wstrb};
    wire unused_leaf_attrs = |{
        resp_readable, resp_writable, resp_executable,
        resp_user, resp_accessed, resp_dirty
    };

endmodule
