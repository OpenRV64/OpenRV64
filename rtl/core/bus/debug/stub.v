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
    input wire lsu_pipe_req_ready /* verilator public_flat_rd */,
    input wire lsu_pipe_req_write /* verilator public_flat_rd */,
    input wire lsu_xlate_accept /* verilator public_flat_rd */,
    input wire lsu_xlate_write_accept /* verilator public_flat_rd */,
    input wire lsu_page_screen_accept /* verilator public_flat_rd */,
    input wire lsu_page_screen_write_accept
        /* verilator public_flat_rd */,
    input wire lsu_page_screen_fill /* verilator public_flat_rd */,
    input wire lsu_page_screen_invalidate /* verilator public_flat_rd */,
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
    input wire fetch_page_screen_fill /* verilator public_flat_rd */,
    input wire fetch_page_screen_invalidate /* verilator public_flat_rd */,
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
endmodule
/* verilator lint_on DECLFILENAME */
