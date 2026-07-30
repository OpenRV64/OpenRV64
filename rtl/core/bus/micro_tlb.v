`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"

/*
 * Current-address-space translation lookaside.
 *
 * ASID, global, and VM-mode ownership live in the tagged main TLB.  This
 * structure is flushed whenever SATP is written, so retaining those fields
 * here would duplicate metadata without permitting useful cross-ASID
 * residency.
 */
module openrv64_bus_micro_tlb #(
    parameter integer ENTRIES = 16
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire                         lookup_valid_i,
    input  wire [`RV64_XLEN-1:0]        lookup_vaddr_i,
    input  wire [1:0]                   lookup_access_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  lookup_priv_i,
    input  wire                         lookup_sum_i,
    input  wire                         lookup_mxr_i,
    output reg                          lookup_hit_o,
    output reg  [`RV64_XLEN-1:0]        lookup_paddr_o,
    output reg                          lookup_page_fault_o,

    input  wire                         fill_valid_i,
    input  wire [`RV64_XLEN-1:0]        fill_vaddr_i,
    input  wire [`RV64_XLEN-1:0]        fill_paddr_i,
    input  wire [`RV64_PAGE_LEVEL_WIDTH-1:0] fill_level_i,
    input  wire                         fill_readable_i,
    input  wire                         fill_writable_i,
    input  wire                         fill_executable_i,
    input  wire                         fill_user_i,
    input  wire                         fill_accessed_i,
    input  wire                         fill_dirty_i
);

    localparam [1:0] ACCESS_READ = 2'd0;
    localparam [1:0] ACCESS_WRITE = 2'd1;
    localparam [1:0] ACCESS_EXEC = 2'd2;
    localparam integer INDEX_WIDTH = (ENTRIES <= 1) ? 1 : $clog2(ENTRIES);
    localparam integer VPN_WIDTH = `RV64_XLEN - 12;

    reg [ENTRIES-1:0] valid_q;
    reg [ENTRIES-1:0][VPN_WIDTH-1:0] vpn_q;
    reg [ENTRIES-1:0][VPN_WIDTH-1:0] ppn_q;
    reg [ENTRIES-1:0][`RV64_PAGE_LEVEL_WIDTH-1:0] level_q;
    reg [ENTRIES-1:0] readable_q;
    reg [ENTRIES-1:0] writable_q;
    reg [ENTRIES-1:0] executable_q;
    reg [ENTRIES-1:0] user_q;
    reg [ENTRIES-1:0] accessed_q;
    reg [ENTRIES-1:0] dirty_q;
    reg [INDEX_WIDTH-1:0] replace_q;

    reg [INDEX_WIDTH-1:0] fill_index_r;
    reg fill_match_found_r;
    reg fill_invalid_found_r;
    integer lookup_index;
    integer select_index;

    wire [VPN_WIDTH-1:0] lookup_vpn =
        lookup_vaddr_i[`RV64_XLEN-1:12];
    wire [VPN_WIDTH-1:0] fill_vpn =
        fill_vaddr_i[`RV64_XLEN-1:12];
    wire [VPN_WIDTH-1:0] fill_ppn =
        fill_paddr_i[`RV64_XLEN-1:12];

    function vpn_match;
        input [VPN_WIDTH-1:0] entry_vpn;
        input [VPN_WIDTH-1:0] request_vpn;
        input [`RV64_PAGE_LEVEL_WIDTH-1:0] level;
        begin
            case (level)
                `RV64_PAGE_LEVEL_1G:
                    vpn_match =
                        entry_vpn[VPN_WIDTH-1:18] ==
                        request_vpn[VPN_WIDTH-1:18];
                `RV64_PAGE_LEVEL_2M:
                    vpn_match =
                        entry_vpn[VPN_WIDTH-1:9] ==
                        request_vpn[VPN_WIDTH-1:9];
                default:
                    vpn_match = entry_vpn == request_vpn;
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

        for (lookup_index = 0; lookup_index < ENTRIES;
             lookup_index = lookup_index + 1) begin
            if (!lookup_hit_o && lookup_valid_i && !flush_i &&
                valid_q[lookup_index] &&
                vpn_match(vpn_q[lookup_index], lookup_vpn,
                          level_q[lookup_index])) begin
                lookup_hit_o = 1'b1;
                lookup_paddr_o = compose_paddr(
                    ppn_q[lookup_index], lookup_vaddr_i,
                    level_q[lookup_index]);
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
                    lookup_mxr_i);
            end
        end
    end

    always @* begin
        fill_index_r = replace_q;
        fill_match_found_r = 1'b0;
        fill_invalid_found_r = 1'b0;

        for (select_index = 0; select_index < ENTRIES;
             select_index = select_index + 1) begin
            if (!fill_match_found_r && valid_q[select_index] &&
                (level_q[select_index] == fill_level_i) &&
                vpn_match(vpn_q[select_index], fill_vpn, fill_level_i)) begin
                fill_index_r = select_index[INDEX_WIDTH-1:0];
                fill_match_found_r = 1'b1;
            end
        end

        for (select_index = 0; select_index < ENTRIES;
             select_index = select_index + 1) begin
            if (!fill_match_found_r && !fill_invalid_found_r &&
                !valid_q[select_index]) begin
                fill_index_r = select_index[INDEX_WIDTH-1:0];
                fill_invalid_found_r = 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_q <= {ENTRIES{1'b0}};
            replace_q <= {INDEX_WIDTH{1'b0}};
        end else if (flush_i) begin
            valid_q <= {ENTRIES{1'b0}};
            replace_q <= {INDEX_WIDTH{1'b0}};
        end else if (fill_valid_i) begin
            valid_q[fill_index_r] <= 1'b1;
            vpn_q[fill_index_r] <= fill_vpn;
            ppn_q[fill_index_r] <= fill_ppn;
            level_q[fill_index_r] <= fill_level_i;
            readable_q[fill_index_r] <= fill_readable_i;
            writable_q[fill_index_r] <= fill_writable_i;
            executable_q[fill_index_r] <= fill_executable_i;
            user_q[fill_index_r] <= fill_user_i;
            accessed_q[fill_index_r] <= fill_accessed_i;
            dirty_q[fill_index_r] <= fill_dirty_i;

            if (fill_index_r == ENTRIES - 1)
                replace_q <= {INDEX_WIDTH{1'b0}};
            else
                replace_q <= fill_index_r + 1'b1;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (ENTRIES < 1)
            $fatal(1, "micro-TLB requires at least one entry");
    end
`endif

endmodule
