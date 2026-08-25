`timescale 1ns/1ps
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-priv.v"

// Passive simulation visibility boundary for the core memory-system adapter.
/* verilator lint_off DECLFILENAME */
module openrv64_bus_debug_stub #(
    parameter integer FETCH_OUTSTANDING = 4,
    parameter integer FETCH_SLOT_WIDTH = $clog2(FETCH_OUTSTANDING),
    parameter integer L1D_REQ_TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH
) (
    input wire clk,
    input wire rst_n,
    input wire lsu_pipe_req_ready /* verilator public_flat_rd */,
    input wire lsu_pipe_req_write /* verilator public_flat_rd */,
    input wire lsu_xlate_accept /* verilator public_flat_rd */,
    input wire lsu_xlate_write_accept /* verilator public_flat_rd */,
    input wire lsu_page_screen_accept /* verilator public_flat_rd */,
    input wire lsu_page_screen_hit_cursor
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_write_accept
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_fill /* verilator public_flat_rd */,
    input wire lsu_page_screen_fill_update
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_evict /* verilator public_flat_rd */,
    input wire lsu_page_screen_evict_writable
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_evict_read_only
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_invalidate /* verilator public_flat_rd */,
    input wire lsu_page_screen_lookup /* verilator public_flat_rd */,
    input wire lsu_page_screen_miss /* verilator public_flat_rd */,
    input wire lsu_page_screen_miss_disabled
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_miss_invalidate
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_miss_cross_page
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_miss_permission
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_miss_empty
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_miss_partial
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_miss_full
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_read_lookup
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_write_lookup
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_flush /* verilator public_flat_rd */,
    input wire [2:0] lsu_page_screen_flush_entries
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_flush_sfence
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_flush_satp
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_flush_pmp
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_flush_csr
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_flush_context
        /* verilator public_flat_rd */,
    input wire pipe_fast_request_fire /* verilator public_flat_rd */,
    input wire pipe_fallback_candidate /* verilator public_flat_rd */,
    input wire fetch_cancelled_q [0:FETCH_OUTSTANDING-1]
        /* verilator public_flat_rd */,
    input wire fetch_demand_q [0:FETCH_OUTSTANDING-1]
        /* verilator public_flat_rd */,
    input wire fetch_free_found_r /* verilator public_flat_rd */,
    input wire [FETCH_SLOT_WIDTH-1:0] fetch_free_slot_r
        /* verilator public_flat_rd */,
    input wire [FETCH_SLOT_WIDTH-1:0] fetch_head_q
        /* verilator public_flat_rd */,
    input wire fetch_l1i_launch /* verilator public_flat_rd */,
    input wire fetch_l1i_inflight_q [0:FETCH_OUTSTANDING-1]
        /* verilator public_flat_rd */,
    input wire fetch_pmp_resp_valid /* verilator public_flat_rd */,
    input wire fetch_page_screen_accept /* verilator public_flat_rd */,
    input wire fetch_page_screen_hit_cursor
        /* verilator public_flat_rd */,
    input wire fetch_page_screen_fill /* verilator public_flat_rd */,
    input wire fetch_page_screen_fill_duplicate
        /* verilator public_flat_rd */,
    input wire fetch_page_screen_evict /* verilator public_flat_rd */,
    input wire fetch_page_screen_evict_duplicate
        /* verilator public_flat_rd */,
    input wire fetch_page_screen_evict_unique
        /* verilator public_flat_rd */,
    input wire fetch_page_screen_invalidate /* verilator public_flat_rd */,
    input wire fetch_page_screen_lookup /* verilator public_flat_rd */,
    input wire fetch_page_screen_miss /* verilator public_flat_rd */,
    input wire fetch_page_screen_miss_disabled
        /* verilator public_flat_rd */,
    input wire fetch_page_screen_miss_invalidate
        /* verilator public_flat_rd */,
    input wire fetch_page_screen_miss_empty
        /* verilator public_flat_rd */,
    input wire fetch_page_screen_miss_partial
        /* verilator public_flat_rd */,
    input wire fetch_page_screen_miss_full
        /* verilator public_flat_rd */,
    input wire fetch_page_screen_flush /* verilator public_flat_rd */,
    input wire [2:0] fetch_page_screen_flush_entries
        /* verilator public_flat_rd */,
    input wire fetch_page_screen_flush_sfence
        /* verilator public_flat_rd */,
    input wire fetch_page_screen_flush_satp
        /* verilator public_flat_rd */,
    input wire fetch_page_screen_flush_pmp
        /* verilator public_flat_rd */,
    input wire fetch_page_screen_flush_csr
        /* verilator public_flat_rd */,
    input wire fetch_page_screen_flush_context
        /* verilator public_flat_rd */,
    input wire fetch_page_screen_launch /* verilator public_flat_rd */,
    input wire fetch_page_screen_resp_bypass
        /* verilator public_flat_rd */,
    input wire [`RV64_PRIV_WIDTH-1:0]
        fetch_priv_q [0:FETCH_OUTSTANDING-1]
        /* verilator public_flat_rd */,
    input wire fetch_stash_q [0:FETCH_OUTSTANDING-1]
        /* verilator public_flat_rd */,
    input wire [2:0] fetch_state_q [0:FETCH_OUTSTANDING-1]
        /* verilator public_flat_rd */,
    input wire [FETCH_SLOT_WIDTH-1:0] fetch_tail_q
        /* verilator public_flat_rd */,
    input wire [63:0] fetch_vaddr_q [0:FETCH_OUTSTANDING-1]
        /* verilator public_flat_rd */,
    input wire [`RV64_SATP_MODE_WIDTH-1:0]
        fetch_vm_mode_q [0:FETCH_OUTSTANDING-1]
        /* verilator public_flat_rd */,
    input wire fetch_xlate_found_r /* verilator public_flat_rd */,
    input wire [FETCH_SLOT_WIDTH-1:0] fetch_xlate_slot_r
        /* verilator public_flat_rd */,
    input wire icx_cmd_grant_valid_q /* verilator public_flat_rd */,
    input wire [1:0] icx_cmd_grant_client_q
        /* verilator public_flat_rd */,
    input wire [1:0] icx_cmd_last_client_q
        /* verilator public_flat_rd */,
    input wire l1d_icx_req_valid /* verilator public_flat_rd */,
    input wire [63:0] l1d_req_addr /* verilator public_flat_rd */,
    input wire [63:0] l1d_req_rdata /* verilator public_flat_rd */,
    input wire [2:0] l1d_req_size /* verilator public_flat_rd */,
    input wire [L1D_REQ_TAG_WIDTH-1:0] l1d_req_tag
        /* verilator public_flat_rd */,
    input wire l1d_req_write /* verilator public_flat_rd */,
    input wire l1d_request_fire /* verilator public_flat_rd */,
    input wire l1i_icx_req_valid /* verilator public_flat_rd */,
    input wire l1i_req_active_q /* verilator public_flat_rd */,
    input wire l1i_req_fire /* verilator public_flat_rd */,
    input wire [63:0] l1i_req_paddr_q /* verilator public_flat_rd */,
    input wire [63:0] l1i_req_vaddr /* verilator public_flat_rd */,
    input wire l1i_req_valid /* verilator public_flat_rd */,
    input wire [FETCH_SLOT_WIDTH-1:0] l1i_resp_tag
        /* verilator public_flat_rd */,
    input wire l1i_resp_valid /* verilator public_flat_rd */,
    input wire ptw_icx_req_valid /* verilator public_flat_rd */
);

    reg [63:0] perf_fetch_page_screen_lookup_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_hit_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_hit_cursor_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_fill_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_fill_duplicate_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_evict_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_evict_duplicate_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_evict_unique_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_miss_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_miss_disabled_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_miss_invalidate_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_miss_empty_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_miss_partial_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_miss_full_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_flush_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_flush_entries_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_flush_sfence_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_flush_satp_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_flush_pmp_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_flush_csr_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_fetch_page_screen_flush_context_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_lookup_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_read_lookup_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_write_lookup_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_hit_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_hit_cursor_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_read_hit_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_write_hit_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_fill_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_fill_update_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_evict_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_evict_writable_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_evict_read_only_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_miss_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_miss_disabled_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_miss_invalidate_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_miss_cross_page_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_miss_permission_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_miss_empty_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_miss_partial_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_miss_full_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_flush_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_flush_entries_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_flush_sfence_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_flush_satp_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_flush_pmp_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_flush_csr_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_lsu_page_screen_flush_context_q
        /* verilator public_flat_rd */;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_fetch_page_screen_lookup_q <= 64'd0;
            perf_fetch_page_screen_hit_q <= 64'd0;
            perf_fetch_page_screen_hit_cursor_q <= 64'd0;
            perf_fetch_page_screen_fill_q <= 64'd0;
            perf_fetch_page_screen_fill_duplicate_q <= 64'd0;
            perf_fetch_page_screen_evict_q <= 64'd0;
            perf_fetch_page_screen_evict_duplicate_q <= 64'd0;
            perf_fetch_page_screen_evict_unique_q <= 64'd0;
            perf_fetch_page_screen_miss_q <= 64'd0;
            perf_fetch_page_screen_miss_disabled_q <= 64'd0;
            perf_fetch_page_screen_miss_invalidate_q <= 64'd0;
            perf_fetch_page_screen_miss_empty_q <= 64'd0;
            perf_fetch_page_screen_miss_partial_q <= 64'd0;
            perf_fetch_page_screen_miss_full_q <= 64'd0;
            perf_fetch_page_screen_flush_q <= 64'd0;
            perf_fetch_page_screen_flush_entries_q <= 64'd0;
            perf_fetch_page_screen_flush_sfence_q <= 64'd0;
            perf_fetch_page_screen_flush_satp_q <= 64'd0;
            perf_fetch_page_screen_flush_pmp_q <= 64'd0;
            perf_fetch_page_screen_flush_csr_q <= 64'd0;
            perf_fetch_page_screen_flush_context_q <= 64'd0;
            perf_lsu_page_screen_lookup_q <= 64'd0;
            perf_lsu_page_screen_read_lookup_q <= 64'd0;
            perf_lsu_page_screen_write_lookup_q <= 64'd0;
            perf_lsu_page_screen_hit_q <= 64'd0;
            perf_lsu_page_screen_hit_cursor_q <= 64'd0;
            perf_lsu_page_screen_read_hit_q <= 64'd0;
            perf_lsu_page_screen_write_hit_q <= 64'd0;
            perf_lsu_page_screen_fill_q <= 64'd0;
            perf_lsu_page_screen_fill_update_q <= 64'd0;
            perf_lsu_page_screen_evict_q <= 64'd0;
            perf_lsu_page_screen_evict_writable_q <= 64'd0;
            perf_lsu_page_screen_evict_read_only_q <= 64'd0;
            perf_lsu_page_screen_miss_q <= 64'd0;
            perf_lsu_page_screen_miss_disabled_q <= 64'd0;
            perf_lsu_page_screen_miss_invalidate_q <= 64'd0;
            perf_lsu_page_screen_miss_cross_page_q <= 64'd0;
            perf_lsu_page_screen_miss_permission_q <= 64'd0;
            perf_lsu_page_screen_miss_empty_q <= 64'd0;
            perf_lsu_page_screen_miss_partial_q <= 64'd0;
            perf_lsu_page_screen_miss_full_q <= 64'd0;
            perf_lsu_page_screen_flush_q <= 64'd0;
            perf_lsu_page_screen_flush_entries_q <= 64'd0;
            perf_lsu_page_screen_flush_sfence_q <= 64'd0;
            perf_lsu_page_screen_flush_satp_q <= 64'd0;
            perf_lsu_page_screen_flush_pmp_q <= 64'd0;
            perf_lsu_page_screen_flush_csr_q <= 64'd0;
            perf_lsu_page_screen_flush_context_q <= 64'd0;
        end else begin
            perf_fetch_page_screen_lookup_q <=
                perf_fetch_page_screen_lookup_q +
                fetch_page_screen_lookup;
            perf_fetch_page_screen_hit_q <=
                perf_fetch_page_screen_hit_q +
                fetch_page_screen_accept;
            perf_fetch_page_screen_hit_cursor_q <=
                perf_fetch_page_screen_hit_cursor_q +
                fetch_page_screen_hit_cursor;
            perf_fetch_page_screen_fill_q <=
                perf_fetch_page_screen_fill_q +
                fetch_page_screen_fill;
            perf_fetch_page_screen_fill_duplicate_q <=
                perf_fetch_page_screen_fill_duplicate_q +
                fetch_page_screen_fill_duplicate;
            perf_fetch_page_screen_evict_q <=
                perf_fetch_page_screen_evict_q +
                fetch_page_screen_evict;
            perf_fetch_page_screen_evict_duplicate_q <=
                perf_fetch_page_screen_evict_duplicate_q +
                fetch_page_screen_evict_duplicate;
            perf_fetch_page_screen_evict_unique_q <=
                perf_fetch_page_screen_evict_unique_q +
                fetch_page_screen_evict_unique;
            perf_fetch_page_screen_miss_q <=
                perf_fetch_page_screen_miss_q + fetch_page_screen_miss;
            perf_fetch_page_screen_miss_disabled_q <=
                perf_fetch_page_screen_miss_disabled_q +
                fetch_page_screen_miss_disabled;
            perf_fetch_page_screen_miss_invalidate_q <=
                perf_fetch_page_screen_miss_invalidate_q +
                fetch_page_screen_miss_invalidate;
            perf_fetch_page_screen_miss_empty_q <=
                perf_fetch_page_screen_miss_empty_q +
                fetch_page_screen_miss_empty;
            perf_fetch_page_screen_miss_partial_q <=
                perf_fetch_page_screen_miss_partial_q +
                fetch_page_screen_miss_partial;
            perf_fetch_page_screen_miss_full_q <=
                perf_fetch_page_screen_miss_full_q +
                fetch_page_screen_miss_full;
            perf_fetch_page_screen_flush_q <=
                perf_fetch_page_screen_flush_q +
                fetch_page_screen_flush;
            perf_fetch_page_screen_flush_entries_q <=
                perf_fetch_page_screen_flush_entries_q +
                (fetch_page_screen_flush ?
                 fetch_page_screen_flush_entries : 3'd0);
            perf_fetch_page_screen_flush_sfence_q <=
                perf_fetch_page_screen_flush_sfence_q +
                fetch_page_screen_flush_sfence;
            perf_fetch_page_screen_flush_satp_q <=
                perf_fetch_page_screen_flush_satp_q +
                fetch_page_screen_flush_satp;
            perf_fetch_page_screen_flush_pmp_q <=
                perf_fetch_page_screen_flush_pmp_q +
                fetch_page_screen_flush_pmp;
            perf_fetch_page_screen_flush_csr_q <=
                perf_fetch_page_screen_flush_csr_q +
                fetch_page_screen_flush_csr;
            perf_fetch_page_screen_flush_context_q <=
                perf_fetch_page_screen_flush_context_q +
                fetch_page_screen_flush_context;

            perf_lsu_page_screen_lookup_q <=
                perf_lsu_page_screen_lookup_q +
                lsu_page_screen_lookup;
            perf_lsu_page_screen_read_lookup_q <=
                perf_lsu_page_screen_read_lookup_q +
                lsu_page_screen_read_lookup;
            perf_lsu_page_screen_write_lookup_q <=
                perf_lsu_page_screen_write_lookup_q +
                lsu_page_screen_write_lookup;
            perf_lsu_page_screen_hit_q <=
                perf_lsu_page_screen_hit_q +
                lsu_page_screen_accept;
            perf_lsu_page_screen_hit_cursor_q <=
                perf_lsu_page_screen_hit_cursor_q +
                lsu_page_screen_hit_cursor;
            perf_lsu_page_screen_read_hit_q <=
                perf_lsu_page_screen_read_hit_q +
                (lsu_page_screen_accept &&
                 !lsu_page_screen_write_accept);
            perf_lsu_page_screen_write_hit_q <=
                perf_lsu_page_screen_write_hit_q +
                lsu_page_screen_write_accept;
            perf_lsu_page_screen_fill_q <=
                perf_lsu_page_screen_fill_q +
                lsu_page_screen_fill;
            perf_lsu_page_screen_fill_update_q <=
                perf_lsu_page_screen_fill_update_q +
                lsu_page_screen_fill_update;
            perf_lsu_page_screen_evict_q <=
                perf_lsu_page_screen_evict_q +
                lsu_page_screen_evict;
            perf_lsu_page_screen_evict_writable_q <=
                perf_lsu_page_screen_evict_writable_q +
                lsu_page_screen_evict_writable;
            perf_lsu_page_screen_evict_read_only_q <=
                perf_lsu_page_screen_evict_read_only_q +
                lsu_page_screen_evict_read_only;
            perf_lsu_page_screen_miss_q <=
                perf_lsu_page_screen_miss_q + lsu_page_screen_miss;
            perf_lsu_page_screen_miss_disabled_q <=
                perf_lsu_page_screen_miss_disabled_q +
                lsu_page_screen_miss_disabled;
            perf_lsu_page_screen_miss_invalidate_q <=
                perf_lsu_page_screen_miss_invalidate_q +
                lsu_page_screen_miss_invalidate;
            perf_lsu_page_screen_miss_cross_page_q <=
                perf_lsu_page_screen_miss_cross_page_q +
                lsu_page_screen_miss_cross_page;
            perf_lsu_page_screen_miss_permission_q <=
                perf_lsu_page_screen_miss_permission_q +
                lsu_page_screen_miss_permission;
            perf_lsu_page_screen_miss_empty_q <=
                perf_lsu_page_screen_miss_empty_q +
                lsu_page_screen_miss_empty;
            perf_lsu_page_screen_miss_partial_q <=
                perf_lsu_page_screen_miss_partial_q +
                lsu_page_screen_miss_partial;
            perf_lsu_page_screen_miss_full_q <=
                perf_lsu_page_screen_miss_full_q +
                lsu_page_screen_miss_full;
            perf_lsu_page_screen_flush_q <=
                perf_lsu_page_screen_flush_q +
                lsu_page_screen_flush;
            perf_lsu_page_screen_flush_entries_q <=
                perf_lsu_page_screen_flush_entries_q +
                (lsu_page_screen_flush ?
                 lsu_page_screen_flush_entries : 3'd0);
            perf_lsu_page_screen_flush_sfence_q <=
                perf_lsu_page_screen_flush_sfence_q +
                lsu_page_screen_flush_sfence;
            perf_lsu_page_screen_flush_satp_q <=
                perf_lsu_page_screen_flush_satp_q +
                lsu_page_screen_flush_satp;
            perf_lsu_page_screen_flush_pmp_q <=
                perf_lsu_page_screen_flush_pmp_q +
                lsu_page_screen_flush_pmp;
            perf_lsu_page_screen_flush_csr_q <=
                perf_lsu_page_screen_flush_csr_q +
                lsu_page_screen_flush_csr;
            perf_lsu_page_screen_flush_context_q <=
                perf_lsu_page_screen_flush_context_q +
                lsu_page_screen_flush_context;
        end
    end
endmodule
/* verilator lint_on DECLFILENAME */
