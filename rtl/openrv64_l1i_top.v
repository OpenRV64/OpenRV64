`timescale 1ns/1ps
`include "complex/protocol/defs.v"
`include "core/isa/rv64-priv.v"

// Standalone 256-bit frontend boundary for the native-CCX L1 instruction
// cache.  Architectural demand translation remains outside this block: the
// frontend supplies a virtual lookup address and its translated physical tag
// address together.  Branch-prefetch and retirement-aging addresses are
// virtual and use the private translation service below.
//
// The request/response ports are decoupled and retain ordered multiple-demand
// concurrency through the L1 hit pipeline.
module openrv64_l1i_top #(
    parameter integer ENABLE = 1,
    parameter integer ADDR_WIDTH = 64,
    parameter integer CACHE_BYTES = 16 * 1024,
    parameter integer WAYS = 4,
    parameter integer PREFETCH_SLOTS = 8,
    parameter [`OPENRV64_CCX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_CCX_HART_ID_WIDTH{1'b0}}
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,

    input  wire                         fetch_req_valid_i,
    output wire                         fetch_req_ready_o,
    input  wire                         fetch_req_cacheable_i,
    input  wire [ADDR_WIDTH-1:0]        fetch_req_vaddr_i,
    input  wire [ADDR_WIDTH-1:0]        fetch_req_paddr_i,
    output wire                         fetch_resp_valid_o,
    input  wire                         fetch_resp_ready_i,
    output wire [255:0]                 fetch_resp_data_o,
    output wire                         fetch_resp_error_o,

    input  wire                         prefetch_valid_i,
    input  wire [ADDR_WIDTH-1:0]        prefetch_taken_vaddr_i,
    input  wire [ADDR_WIDTH-1:0]        prefetch_fallthrough_vaddr_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]  current_priv_i,
    input  wire [`RV64_SATP_MODE_WIDTH-1:0] current_vm_mode_i,
    input  wire [`RV64_SATP_ASID_WIDTH-1:0] current_asid_i,
    input  wire [`RV64_SATP_PPN_WIDTH-1:0] current_root_ppn_i,
    input  wire                         current_sum_i,
    input  wire                         current_mxr_i,
    input  wire [2:0]                   retire_age_valid_i,
    input  wire [3*ADDR_WIDTH-1:0]      retire_age_vaddr_i,
    input  wire                         prefetch_flush_i,

    output wire                         xlate_req_valid_o,
    input  wire                         xlate_req_ready_i,
    output wire [ADDR_WIDTH-1:0]        xlate_req_vaddr_o,
    output wire [`RV64_PRIV_WIDTH-1:0]  xlate_req_priv_o,
    output wire [`RV64_SATP_MODE_WIDTH-1:0] xlate_req_vm_mode_o,
    output wire [`RV64_SATP_ASID_WIDTH-1:0] xlate_req_asid_o,
    output wire [`RV64_SATP_PPN_WIDTH-1:0] xlate_req_root_ppn_o,
    output wire                         xlate_req_sum_o,
    output wire                         xlate_req_mxr_o,
    input  wire                         xlate_resp_valid_i,
    output wire                         xlate_resp_ready_o,
    input  wire [ADDR_WIDTH-1:0]        xlate_resp_paddr_i,
    input  wire                         xlate_resp_fault_i,

    input  wire                         invalidate_valid_i,
    output wire                         invalidate_ready_o,
    input  wire                         invalidate_all_i,
    input  wire [ADDR_WIDTH-1:0]        invalidate_paddr_i,

    output wire                         ccx_req_valid_o,
    input  wire                         ccx_req_ready_i,
    output wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_req_hart_id_o,
    output wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_req_source_id_o,
    output wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_req_txn_id_o,
    output wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op_o,
    output wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order_o,
    output wire [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind_o,
    output wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr_o,
    output wire [2:0]                   ccx_req_size_o,
    output wire [ADDR_WIDTH-1:0]        ccx_req_addr_o,
    output wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0]
                                        ccx_req_burst_len_o,

    input  wire                         ccx_resp_valid_i,
    output wire                         ccx_resp_ready_o,
    input  wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0]
                                        ccx_resp_hart_id_i,
    input  wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0]
                                        ccx_resp_source_id_i,
    input  wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0]
                                        ccx_resp_txn_id_i,
    input  wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0]
                                        ccx_resp_rdata_i,
    input  wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0]
                                        ccx_resp_beat_index_i,
    input  wire                         ccx_resp_last_i,
    input  wire                         ccx_resp_error_i,
    input  wire                         ccx_resp_sc_success_i
);

    wire l1i_demand_ready;
    wire l1i_response_valid;
    wire [255:0] l1i_demand_data;
    wire l1i_demand_error;

    assign fetch_req_ready_o = l1i_demand_ready;
    assign fetch_resp_valid_o = l1i_response_valid;
    assign fetch_resp_data_o = l1i_demand_data;
    assign fetch_resp_error_o = l1i_demand_error;

    openrv64_l1i_ccx #(
        .ENABLE(ENABLE),
        .ADDR_WIDTH(ADDR_WIDTH),
        .CACHE_BYTES(CACHE_BYTES),
        .WAYS(WAYS),
        .PREFETCH_SLOTS(PREFETCH_SLOTS),
        .HART_ID(HART_ID)
    ) u_l1i_ccx (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .req_valid_i(fetch_req_valid_i),
        .req_ready_o(l1i_demand_ready),
        .req_cacheable_i(fetch_req_cacheable_i),
        .req_addr_i(fetch_req_vaddr_i),
        .req_phys_addr_i(fetch_req_paddr_i),
        .resp_valid_o(l1i_response_valid),
        .resp_ready_i(fetch_resp_ready_i),
        .req_rdata_o(l1i_demand_data),
        .req_error_o(l1i_demand_error),
        .prefetch_valid_i(prefetch_valid_i),
        .prefetch_taken_addr_i(prefetch_taken_vaddr_i),
        .prefetch_fallthrough_addr_i(prefetch_fallthrough_vaddr_i),
        .prefetch_priv_i(current_priv_i),
        .prefetch_vm_mode_i(current_vm_mode_i),
        .prefetch_asid_i(current_asid_i),
        .prefetch_root_ppn_i(current_root_ppn_i),
        .prefetch_sum_i(current_sum_i),
        .prefetch_mxr_i(current_mxr_i),
        .retire_age_valid_i(retire_age_valid_i),
        .retire_age_addr_i(retire_age_vaddr_i),
        .prefetch_flush_i(prefetch_flush_i),
        .xlate_req_valid_o(xlate_req_valid_o),
        .xlate_req_ready_i(xlate_req_ready_i),
        .xlate_req_vaddr_o(xlate_req_vaddr_o),
        .xlate_req_priv_o(xlate_req_priv_o),
        .xlate_req_vm_mode_o(xlate_req_vm_mode_o),
        .xlate_req_asid_o(xlate_req_asid_o),
        .xlate_req_root_ppn_o(xlate_req_root_ppn_o),
        .xlate_req_sum_o(xlate_req_sum_o),
        .xlate_req_mxr_o(xlate_req_mxr_o),
        .xlate_resp_valid_i(xlate_resp_valid_i),
        .xlate_resp_ready_o(xlate_resp_ready_o),
        .xlate_resp_paddr_i(xlate_resp_paddr_i),
        .xlate_resp_fault_i(xlate_resp_fault_i),
        .invalidate_valid_i(invalidate_valid_i),
        .invalidate_ready_o(invalidate_ready_o),
        .invalidate_all_i(invalidate_all_i),
        .invalidate_addr_i(invalidate_paddr_i),
        .ccx_req_valid_o(ccx_req_valid_o),
        .ccx_req_ready_i(ccx_req_ready_i),
        .ccx_req_hart_id_o(ccx_req_hart_id_o),
        .ccx_req_source_id_o(ccx_req_source_id_o),
        .ccx_req_txn_id_o(ccx_req_txn_id_o),
        .ccx_req_op_o(ccx_req_op_o),
        .ccx_req_order_o(ccx_req_order_o),
        .ccx_req_kind_o(ccx_req_kind_o),
        .ccx_req_attr_o(ccx_req_attr_o),
        .ccx_req_size_o(ccx_req_size_o),
        .ccx_req_addr_o(ccx_req_addr_o),
        .ccx_req_burst_len_o(ccx_req_burst_len_o),
        .ccx_resp_valid_i(ccx_resp_valid_i),
        .ccx_resp_ready_o(ccx_resp_ready_o),
        .ccx_resp_hart_id_i(ccx_resp_hart_id_i),
        .ccx_resp_source_id_i(ccx_resp_source_id_i),
        .ccx_resp_txn_id_i(ccx_resp_txn_id_i),
        .ccx_resp_rdata_i(ccx_resp_rdata_i),
        .ccx_resp_beat_index_i(ccx_resp_beat_index_i),
        .ccx_resp_last_i(ccx_resp_last_i),
        .ccx_resp_error_i(ccx_resp_error_i),
        .ccx_resp_sc_success_i(ccx_resp_sc_success_i)
    );

endmodule
