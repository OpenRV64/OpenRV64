`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"

module openrv64_bus_tlb #(
    parameter ENTRIES = 16,
    parameter ASID_WIDTH = 16
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         tlbi_i,
    input  wire                         prefer_asid_valid_i,
    input  wire [ASID_WIDTH-1:0]        prefer_asid_i,

    input  wire                         lookup_valid_i,
    input  wire [`RV64_XLEN-1:0]        lookup_vaddr_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] lookup_vm_mode_i,
    input  wire [ASID_WIDTH-1:0]        lookup_asid_i,
    input  wire [1:0]                   lookup_access_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  lookup_priv_i,
    input  wire                         lookup_sum_i,
    input  wire                         lookup_mxr_i,
    output reg                          lookup_hit_o,
    output reg  [`RV64_XLEN-1:0]        lookup_paddr_o,
    output reg                          lookup_page_fault_o,
    output reg                          lookup_global_o,
    output reg  [`RV64_PAGE_LEVEL_WIDTH-1:0] lookup_level_o,
    output reg                          lookup_readable_o,
    output reg                          lookup_writable_o,
    output reg                          lookup_executable_o,
    output reg                          lookup_user_o,
    output reg                          lookup_accessed_o,
    output reg                          lookup_dirty_o,

    input  wire                         fill_valid_i,
    input  wire [`RV64_XLEN-1:0]        fill_vaddr_i,
    input  wire [`RV64_XLEN-1:0]        fill_paddr_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] fill_vm_mode_i,
    input  wire [ASID_WIDTH-1:0]        fill_asid_i,
    input  wire                         fill_global_i,
    input  wire [`RV64_PAGE_LEVEL_WIDTH-1:0] fill_level_i,
    input  wire                         fill_readable_i,
    input  wire                         fill_writable_i,
    input  wire                         fill_executable_i,
    input  wire                         fill_user_i,
    input  wire                         fill_accessed_i,
    input  wire                         fill_dirty_i,
    output wire                         fill_evict_valid_o,
    output wire                         fill_evict_preferred_o
);

    localparam [1:0] ACCESS_READ = 2'd0;
    localparam [1:0] ACCESS_WRITE = 2'd1;
    localparam [1:0] ACCESS_EXEC = 2'd2;

    localparam INDEX_WIDTH = (ENTRIES <= 1) ? 1 : $clog2(ENTRIES);
    localparam VPN_WIDTH = `RV64_XLEN - 12;

    reg [ENTRIES-1:0] valid_q;
    reg [ENTRIES-1:0][VPN_WIDTH-1:0] vpn_q;
    reg [ENTRIES-1:0][VPN_WIDTH-1:0] ppn_q;
    reg [ENTRIES-1:0][`RV64_SATP_MODE_WIDTH-1:0] vm_mode_q;
    reg [ENTRIES-1:0][ASID_WIDTH-1:0] asid_q;
    reg [ENTRIES-1:0] global_q;
    reg [ENTRIES-1:0][`RV64_PAGE_LEVEL_WIDTH-1:0] level_q;
    reg [ENTRIES-1:0] readable_q;
    reg [ENTRIES-1:0] writable_q;
    reg [ENTRIES-1:0] executable_q;
    reg [ENTRIES-1:0] user_q;
    reg [ENTRIES-1:0] accessed_q;
    reg [ENTRIES-1:0] dirty_q;
    reg [INDEX_WIDTH-1:0] replace_q;

    reg [INDEX_WIDTH-1:0] fill_index;
    reg fill_match_found;
    reg fill_invalid_found;
    reg fill_cold_found;
    integer lookup_index;
    integer select_index;
    integer candidate_index;
    integer update_index;

    wire [VPN_WIDTH-1:0] lookup_vpn = lookup_vaddr_i[`RV64_XLEN-1:12];
    wire [VPN_WIDTH-1:0] fill_vpn = fill_vaddr_i[`RV64_XLEN-1:12];
    wire [VPN_WIDTH-1:0] fill_ppn = fill_paddr_i[`RV64_XLEN-1:12];

    function vpn_match;
        input [VPN_WIDTH-1:0] entry_vpn;
        input [VPN_WIDTH-1:0] request_vpn;
        input [`RV64_PAGE_LEVEL_WIDTH-1:0] level;
        begin
            case (level)
                `RV64_PAGE_LEVEL_1G:
                    vpn_match =
                        (entry_vpn[VPN_WIDTH-1:18] ==
                         request_vpn[VPN_WIDTH-1:18]);
                `RV64_PAGE_LEVEL_2M:
                    vpn_match =
                        (entry_vpn[VPN_WIDTH-1:9] ==
                         request_vpn[VPN_WIDTH-1:9]);
                default:
                    vpn_match = (entry_vpn == request_vpn);
            endcase
        end
    endfunction

    function [`RV64_XLEN-1:0] compose_paddr;
        input [VPN_WIDTH-1:0] ppn;
        input [`RV64_XLEN-1:0] vaddr;
        input [`RV64_PAGE_LEVEL_WIDTH-1:0] level;
        begin
            case (level)
                `RV64_PAGE_LEVEL_1G:
                    compose_paddr = {ppn[VPN_WIDTH-1:18], vaddr[29:0]};
                `RV64_PAGE_LEVEL_2M:
                    compose_paddr = {ppn[VPN_WIDTH-1:9], vaddr[20:0]};
                default:
                    compose_paddr = {ppn, vaddr[11:0]};
            endcase
        end
    endfunction

    function permission_ok;
        input readable;
        input writable;
        input executable;
        input user_page;
        input accessed;
        input dirty;
        input [1:0] access_kind;
        input [`RV64_PRIV_WIDTH-1:0] privilege;
        input sum;
        input mxr;
        reg access_allowed;
        reg privilege_allowed;
        begin
            access_allowed =
                (access_kind == ACCESS_EXEC) ? executable :
                (access_kind == ACCESS_WRITE) ? writable :
                (access_kind == ACCESS_READ) ?
                    (readable || (mxr && executable)) : 1'b0;
            privilege_allowed =
                (privilege == `RV64_PRIV_U) ? user_page :
                (privilege == `RV64_PRIV_S) ?
                    (!user_page ||
                     ((access_kind != ACCESS_EXEC) && sum)) : 1'b0;
            permission_ok = access_allowed && privilege_allowed && accessed &&
                            ((access_kind != ACCESS_WRITE) || dirty);
        end
    endfunction

    always @* begin
        lookup_hit_o = 1'b0;
        lookup_paddr_o = {`RV64_XLEN{1'b0}};
        lookup_page_fault_o = 1'b0;
        lookup_global_o = 1'b0;
        lookup_level_o = `RV64_PAGE_LEVEL_4K;
        lookup_readable_o = 1'b0;
        lookup_writable_o = 1'b0;
        lookup_executable_o = 1'b0;
        lookup_user_o = 1'b0;
        lookup_accessed_o = 1'b0;
        lookup_dirty_o = 1'b0;

        for (lookup_index = 0;
             lookup_index < ENTRIES;
             lookup_index = lookup_index + 1) begin
            if (!lookup_hit_o && lookup_valid_i && !tlbi_i &&
                valid_q[lookup_index] &&
                vpn_match(vpn_q[lookup_index], lookup_vpn,
                          level_q[lookup_index]) &&
                (vm_mode_q[lookup_index] == lookup_vm_mode_i) &&
                (global_q[lookup_index] ||
                 (asid_q[lookup_index] == lookup_asid_i))) begin
                lookup_hit_o = 1'b1;
                lookup_paddr_o = compose_paddr(
                    ppn_q[lookup_index], lookup_vaddr_i,
                    level_q[lookup_index]
                );
                lookup_page_fault_o = !permission_ok(
                    readable_q[lookup_index],
                    writable_q[lookup_index],
                    executable_q[lookup_index],
                    user_q[lookup_index],
                    accessed_q[lookup_index],
                    dirty_q[lookup_index],
                    lookup_access_i,
                    lookup_priv_i,
                    lookup_sum_i,
                    lookup_mxr_i
                );
                lookup_global_o = global_q[lookup_index];
                lookup_level_o = level_q[lookup_index];
                lookup_readable_o = readable_q[lookup_index];
                lookup_writable_o = writable_q[lookup_index];
                lookup_executable_o = executable_q[lookup_index];
                lookup_user_o = user_q[lookup_index];
                lookup_accessed_o = accessed_q[lookup_index];
                lookup_dirty_o = dirty_q[lookup_index];
            end
        end
    end

    always @* begin
        fill_index = replace_q;
        fill_match_found = 1'b0;
        fill_invalid_found = 1'b0;
        fill_cold_found = 1'b0;

        for (select_index = 0;
             select_index < ENTRIES;
             select_index = select_index + 1) begin
            if (!fill_match_found && valid_q[select_index] &&
                (level_q[select_index] == fill_level_i) &&
                vpn_match(vpn_q[select_index], fill_vpn, fill_level_i) &&
                (vm_mode_q[select_index] == fill_vm_mode_i) &&
                (global_q[select_index] || fill_global_i ||
                 (asid_q[select_index] == fill_asid_i))) begin
                fill_index = select_index[INDEX_WIDTH-1:0];
                fill_match_found = 1'b1;
            end
        end

        for (select_index = 0;
             select_index < ENTRIES;
             select_index = select_index + 1) begin
            if (!fill_match_found && !fill_invalid_found &&
                !valid_q[select_index]) begin
                fill_index = select_index[INDEX_WIDTH-1:0];
                fill_invalid_found = 1'b1;
            end
        end

        /*
         * The shared main-TLB superpage sidecar uses this tagged CAM. Avoid
         * evicting the active ASID (or a global entry) while an inactive-ASID
         * victim exists. If every entry belongs to the active context,
         * round-robin still guarantees forward progress.
         */
        for (select_index = 0;
             select_index < ENTRIES;
             select_index = select_index + 1) begin
            candidate_index = replace_q + select_index;
            if (candidate_index >= ENTRIES)
                candidate_index = candidate_index - ENTRIES;
            if (!fill_match_found && !fill_invalid_found &&
                !fill_cold_found && prefer_asid_valid_i &&
                valid_q[candidate_index] &&
                !global_q[candidate_index] &&
                (asid_q[candidate_index] != prefer_asid_i)) begin
                fill_index = candidate_index[INDEX_WIDTH-1:0];
                fill_cold_found = 1'b1;
            end
        end
    end

    assign fill_evict_valid_o =
        fill_valid_i && !tlbi_i && valid_q[fill_index] &&
        !fill_match_found;
    assign fill_evict_preferred_o =
        fill_evict_valid_o && prefer_asid_valid_i &&
        (global_q[fill_index] ||
         (asid_q[fill_index] == prefer_asid_i));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            replace_q <= {INDEX_WIDTH{1'b0}};
            for (update_index = 0;
                 update_index < ENTRIES;
                 update_index = update_index + 1) begin
                valid_q[update_index] <= 1'b0;
                vpn_q[update_index] <= {VPN_WIDTH{1'b0}};
                ppn_q[update_index] <= {VPN_WIDTH{1'b0}};
                vm_mode_q[update_index] <=
                    {`RV64_SATP_MODE_WIDTH{1'b0}};
                asid_q[update_index] <= {ASID_WIDTH{1'b0}};
                global_q[update_index] <= 1'b0;
                level_q[update_index] <= `RV64_PAGE_LEVEL_4K;
                readable_q[update_index] <= 1'b0;
                writable_q[update_index] <= 1'b0;
                executable_q[update_index] <= 1'b0;
                user_q[update_index] <= 1'b0;
                accessed_q[update_index] <= 1'b0;
                dirty_q[update_index] <= 1'b0;
            end
        end else if (tlbi_i) begin
            replace_q <= {INDEX_WIDTH{1'b0}};
            for (update_index = 0;
                 update_index < ENTRIES;
                 update_index = update_index + 1) begin
                valid_q[update_index] <= 1'b0;
            end
        end else if (fill_valid_i) begin
            for (update_index = 0;
                 update_index < ENTRIES;
                 update_index = update_index + 1) begin
                if (valid_q[update_index] &&
                    (level_q[update_index] == fill_level_i) &&
                    vpn_match(vpn_q[update_index], fill_vpn,
                              fill_level_i) &&
                    (vm_mode_q[update_index] == fill_vm_mode_i) &&
                    (global_q[update_index] || fill_global_i ||
                     (asid_q[update_index] == fill_asid_i))) begin
                    valid_q[update_index] <= 1'b0;
                end
            end

            valid_q[fill_index] <= 1'b1;
            vpn_q[fill_index] <= fill_vpn;
            ppn_q[fill_index] <= fill_ppn;
            vm_mode_q[fill_index] <= fill_vm_mode_i;
            asid_q[fill_index] <= fill_asid_i;
            global_q[fill_index] <= fill_global_i;
            level_q[fill_index] <= fill_level_i;
            readable_q[fill_index] <= fill_readable_i;
            writable_q[fill_index] <= fill_writable_i;
            executable_q[fill_index] <= fill_executable_i;
            user_q[fill_index] <= fill_user_i;
            accessed_q[fill_index] <= fill_accessed_i;
            dirty_q[fill_index] <= fill_dirty_i;

            if (fill_index == ENTRIES - 1) begin
                replace_q <= {INDEX_WIDTH{1'b0}};
            end else begin
                replace_q <= fill_index + 1'b1;
            end
        end
    end

endmodule
