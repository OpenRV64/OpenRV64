`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-priv.v"
`include "core/decode/defs/lsu-defs.v"

// Passive, simulation-only visibility boundary for core instrumentation.
//
// Testbenches and generated Verilator harnesses must consume this interface
// instead of depending on private implementation hierarchy.  Inputs are
// intentionally marked public: otherwise Verilator may fold an observation
// point that has no functional fanout out of the generated model.
/* verilator lint_off DECLFILENAME */
module openrv64_core_debug_stub (
    input wire clk,
    input wire rst_n,
    input wire xlate_req_fire /* verilator public_flat_rd */,
    input wire store_alloc_fire /* verilator public_flat_rd */,
    input wire backend_mem_resp_ready /* verilator public_flat_rd */,
    input wire backend_mem_resp_valid /* verilator public_flat_rd */,
    input wire [`OPENRV64_LSU_TAG_WIDTH-1:0] backend_mem_resp_tag
        /* verilator public_flat_rd */,
    input wire [63:0] backend_mem_rdata /* verilator public_flat_rd */,
    input wire [`OPENRV64_LSU_XLATE_TAG_WIDTH-1:0]
        backend_mem_xlate_tag
        /* verilator public_flat_rd */,
    input wire backend_mem_xlate_write /* verilator public_flat_rd */,
    input wire [63:0] backend_mem_xlate_vaddr
        /* verilator public_flat_rd */,
    input wire backend_mem_xlate_resp_valid /* verilator public_flat_rd */,
    input wire backend_mem_xlate_resp_ready /* verilator public_flat_rd */,
    input wire [`OPENRV64_LSU_XLATE_TAG_WIDTH-1:0]
        backend_mem_xlate_resp_tag
        /* verilator public_flat_rd */,
    input wire [63:0] backend_mem_xlate_resp_paddr
        /* verilator public_flat_rd */,
    input wire backend_mem_xlate_resp_access_fault
        /* verilator public_flat_rd */,
    input wire backend_mem_xlate_resp_page_fault
        /* verilator public_flat_rd */,
    input wire backend_csr_write /* verilator public_flat_rd */,
    input wire [11:0] backend_csr_write_addr
        /* verilator public_flat_rd */,
    input wire [63:0] backend_csr_wdata /* verilator public_flat_rd */,
    input wire [4:0] backend_cause /* verilator public_flat_rd */,
    input wire backend_exception /* verilator public_flat_rd */,
    input wire [2:0] backend_retire_arch /* verilator public_flat_rd */,
    input wire [31:0] backend_retire_instr /* verilator public_flat_rd */,
    input wire [63:0] backend_retire_pc /* verilator public_flat_rd */,
    input wire backend_sfence_vma /* verilator public_flat_rd */,
    input wire backend_redirect /* verilator public_flat_rd */,
    input wire [63:0] backend_redirect_target /* verilator public_flat_rd */,
    input wire bp_branch_allocate /* verilator public_flat_rd */,
    input wire bp_branch_present /* verilator public_flat_rd */,
    input wire [1:0] bp_lane /* verilator public_flat_rd */,
    input wire bp_lookup_indirect /* verilator public_flat_rd */,
    input wire bp_lookup_rd_link /* verilator public_flat_rd */,
    input wire bp_predict_redirect /* verilator public_flat_rd */,
    input wire [63:0] bp_predict_target /* verilator public_flat_rd */,
    input wire bp_prediction_taken /* verilator public_flat_rd */,
    input wire [63:0] bp_prediction_target /* verilator public_flat_rd */,
    input wire bp_prediction_target_valid /* verilator public_flat_rd */,
    input wire [31:0] bp_selected_instr /* verilator public_flat_rd */,
    input wire [63:0] bp_selected_pc /* verilator public_flat_rd */,
    input wire bp_target_mispredict /* verilator public_flat_rd */,
    input wire [2:0] fetch_decode_valid /* verilator public_flat_rd */,
    input wire [2:0] fetch_decode_ready /* verilator public_flat_rd */,
    input wire [2:0] backend_decode_valid /* verilator public_flat_rd */,
    input wire [2:0] backend_decode_ready /* verilator public_flat_rd */,
    input wire [2:0] frontend_decode_fire /* verilator public_flat_rd */,
    input wire [2:0] decode_valid /* verilator public_flat_rd */,
    input wire [2:0] decode_illegal /* verilator public_flat_rd */,
    input wire [31:0] instr0 /* verilator public_flat_rd */,
    input wire [31:0] instr1 /* verilator public_flat_rd */,
    input wire [31:0] instr2 /* verilator public_flat_rd */,
    input wire [63:0] decode_pc0 /* verilator public_flat_rd */,
    input wire [63:0] decode_pc1 /* verilator public_flat_rd */,
    input wire [63:0] decode_pc2 /* verilator public_flat_rd */,
    input wire control_flush /* verilator public_flat_rd */,
    input wire control_redirect /* verilator public_flat_rd */,
    input wire fetch3_invalidate /* verilator public_flat_rd */,
    input wire fetch3_restart /* verilator public_flat_rd */,
    input wire [63:0] fetch3_restart_pc /* verilator public_flat_rd */,
    input wire [63:0] fetch_pipe_req_addr /* verilator public_flat_rd */,
    input wire fetch_pipe_req_demand /* verilator public_flat_rd */,
    input wire fetch_pipe_req_ready /* verilator public_flat_rd */,
    input wire fetch_pipe_req_stash /* verilator public_flat_rd */,
    input wire [63:0] pc_q /* verilator public_flat_rd */,
    input wire [`RV64_PRIV_WIDTH-1:0] csr_priv_mode
        /* verilator public_flat_rd */,
    input wire [`RV64_SATP_MODE_WIDTH-1:0] csr_satp_mode
        /* verilator public_flat_rd */,
    input wire [`RV64_SATP_ASID_WIDTH-1:0] csr_satp_asid
        /* verilator public_flat_rd */,
    input wire [`RV64_SATP_PPN_WIDTH-1:0] csr_satp_root_ppn
        /* verilator public_flat_rd */,
    input wire csr_trap_to_s /* verilator public_flat_rd */,
    input wire [63:0] csr_trap_vector /* verilator public_flat_rd */,
    input wire trap_enter /* verilator public_flat_rd */,
    input wire trap_interrupt /* verilator public_flat_rd */,
    input wire [4:0] trap_cause /* verilator public_flat_rd */,
    input wire [63:0] trap_pc /* verilator public_flat_rd */,
    input wire [3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0]
        queue_retire_result /* verilator public_flat_rd */,
    input wire [63:0] csr_mstatus /* verilator public_flat_rd */,
    input wire [63:0] csr_mepc /* verilator public_flat_rd */,
    input wire [63:0] csr_mcause /* verilator public_flat_rd */,
    input wire [63:0] csr_mtval /* verilator public_flat_rd */,
    input wire [63:0] csr_mip_sw /* verilator public_flat_rd */,
    input wire [63:0] csr_satp /* verilator public_flat_rd */,
    input wire [31*64-1:0] gpr_debug_regs
        /* verilator public_flat_rd */,
    input wire atomic_active /* verilator public_flat_rd */,
    input wire atomic_irrevocable /* verilator public_flat_rd */,
    input wire atomic_req_inflight /* verilator public_flat_rd */,
    input wire [2:0] atomic_state /* verilator public_flat_rd */,
    input wire [`RV64_LSU_OP_WIDTH-1:0] atomic_op
        /* verilator public_flat_rd */,
    input wire [63:0] atomic_addr /* verilator public_flat_rd */,
    input wire atomic_reservation_valid /* verilator public_flat_rd */,
    input wire atomic_store_response /* verilator public_flat_rd */,
    input wire atomic_store_success /* verilator public_flat_rd */,
    input wire [63:0] lsq_load_allocations /* verilator public_flat_rd */,
    input wire [63:0] lsq_load_alloc_wait_cycles
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_load_queue_full_cycles
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_load_xlate_requests
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_load_xlate_wait_cycles
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_load_access_requests
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_load_access_wait_cycles
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_load_responses /* verilator public_flat_rd */,
    input wire [63:0] lsq_load_completions /* verilator public_flat_rd */,
    input wire [63:0] lsq_load_dependency_block_cycles
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_load_dependency_block_entry_cycles
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_load_occupancy_cycles
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_load_max_occupancy
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_store_allocations /* verilator public_flat_rd */,
    input wire [63:0] lsq_store_alloc_wait_cycles
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_store_queue_full_cycles
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_store_xlate_requests
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_store_xlate_wait_cycles
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_store_access_requests
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_store_access_wait_cycles
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_store_done /* verilator public_flat_rd */,
    input wire [63:0] lsq_store_order_wait_cycles
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_store_order_wait_entry_cycles
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_store_occupancy_cycles
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_store_max_occupancy
        /* verilator public_flat_rd */,
    input wire [63:0] lsq_atomic_active_cycles
        /* verilator public_flat_rd */
);
    // Count completed atomic write attempts rather than architectural AMO
    // completions.  A failed coherent AMO write is retried internally and may
    // therefore produce several attempts for one retired instruction.
    reg [63:0] perf_atomic_store_success_q
        /* verilator public_flat_rd */;
    reg [63:0] perf_atomic_store_failed_q
        /* verilator public_flat_rd */;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_atomic_store_success_q <= 64'd0;
            perf_atomic_store_failed_q <= 64'd0;
        end else if (atomic_store_response) begin
            if (atomic_store_success)
                perf_atomic_store_success_q <=
                    perf_atomic_store_success_q + 1'b1;
            else
                perf_atomic_store_failed_q <=
                    perf_atomic_store_failed_q + 1'b1;
        end
    end
endmodule
/* verilator lint_on DECLFILENAME */
