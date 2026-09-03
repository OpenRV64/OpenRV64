`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/isa/rv64-zicsr.v"
`include "core/isa/rv64-zifencei.v"
`include "core/fetch/fetch-defs.v"
`include "core/decode/defs/early-defs.v"
`include "core/decode/defs/alu-defs.v"
`include "core/decode/defs/lsu-defs.v"
`include "core/decode/defs/br-defs.v"
`include "core/exec/bp/defs.v"
`include "core/except/except-defs.v"
`include "core/trace/trace-defs.v"
`include "core/cmu/defs.v"
`include "core/arith/prefix-addsub.v"
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

module openrv64_rv64_top #(
    parameter [63:0] RESET_VECTOR = 64'h0000_0000_0000_0000,
    parameter [`OPENRV64_BACKEND_CONFIG_WIDTH-1:0] BACKEND_CONFIG =
        `OPENRV64_BACKEND_1P,
    parameter PIPE_IF_ID = 1,
    parameter PIPE_ID_EX = 1,
    parameter PIPE_EX_MEM = 1,
    parameter PIPE_MEM_WB = 1,
    parameter ENABLE_RV64M = 0,
    parameter ENABLE_RV64A = 1,
    parameter integer HPM_COUNTERS = 8,
    parameter integer PMP_ACTIVE_ENTRIES = 8,
    parameter ENABLE_FORWARDING = 1,
    parameter ENABLE_LOAD_FORWARDING = 0,
    parameter PIPE_1P_MEM_4_STAGE = 0,
    parameter PIPE_1P_DECODE_QUEUE = 0,
    parameter BANKED_GPR = 1,
    parameter FPGA_GPR_LUTRAM = 0,
    parameter DEBUG_SERIALIZE_ALL_1P = 0,
    parameter integer TLB_ENTRIES = 16,
    parameter integer PTW_PTE_CACHE_ENTRIES = 64,
    parameter integer PTW_ICX_TIMEOUT_CYCLES = 65536,
    parameter [`OPENRV64_ICX_HART_ID_WIDTH-1:0] HART_ID =
        {`OPENRV64_ICX_HART_ID_WIDTH{1'b0}},
    parameter ENABLE_TRACE = 0,
    parameter ENABLE_PREDECODE_TARGETS = 1,
    parameter [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE = `OPENRV64_BP_DEFAULT,
    parameter BP_RAS_ENABLE = 1,
    parameter integer BP_RAS_DEPTH = 8,
    parameter integer BP_BIMODAL_ENTRIES = 32,
    parameter integer BP_BIMODAL_COUNTER_BITS = 3,
    parameter integer BP_BIMODAL_UPDATE_DEPTH = 4,
    parameter integer BP_GSHARE_ENTRIES = 256,
    parameter integer BP_GSHARE_COUNTER_BITS = 3,
    parameter integer BP_BTB_ENTRIES = 256,
    parameter integer BP_BTB_TAG_BITS = 16,
    parameter integer BP_INFLIGHT_DEPTH = 16
) (
    input  wire        clk,
    input  wire        rst_n,

    output wire        mem_valid,
    input  wire        mem_ready,
    output wire        mem_write,
    output wire [63:0] mem_addr,
    output wire [63:0] mem_wdata,
    output wire [7:0]  mem_wstrb,
    input  wire [63:0] mem_rdata,
    input  wire        mem_error,

    // Native line interface used by the PTW. Page-table traffic never uses
    // the scalar memory port above.
    output wire        icx_req_valid,
    input  wire        icx_req_ready,
    output wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_req_hart_id,
    output wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_req_txn_id,
    output wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_req_source_id,
    output wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op,
    output wire        icx_req_lock,
    output wire [`OPENRV64_ICX_ORDER_WIDTH-1:0] icx_req_order,
    output wire [`OPENRV64_ICX_KIND_WIDTH-1:0] icx_req_kind,
    output wire [`OPENRV64_ICX_ATTR_WIDTH-1:0] icx_req_attr,
    output wire [2:0]  icx_req_size,
    output wire [63:0] icx_req_addr,
    output wire [`OPENRV64_ICX_BURST_LEN_WIDTH-1:0] icx_req_burst_len,
    output wire        icx_wdata_valid,
    input  wire        icx_wdata_ready,
    output wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_wdata_hart_id,
    output wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_wdata_txn_id,
    output wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_wdata_source_id,
    output wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0]
                       icx_wdata_beat_index,
    output wire        icx_wdata_last,
    output wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_wdata,
    output wire [`OPENRV64_ICX_LINE_STRB_WIDTH-1:0] icx_wstrb,
    input  wire        icx_resp_valid,
    output wire        icx_resp_ready,
    input  wire [`OPENRV64_ICX_HART_ID_WIDTH-1:0] icx_resp_hart_id,
    input  wire [`OPENRV64_ICX_TXN_ID_WIDTH-1:0] icx_resp_txn_id,
    input  wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0] icx_resp_source_id,
    input  wire [`OPENRV64_ICX_BEAT_INDEX_WIDTH-1:0] icx_resp_beat_index,
    input  wire        icx_resp_last,
    input  wire [`OPENRV64_ICX_LINE_DATA_WIDTH-1:0] icx_resp_rdata,
    input  wire        icx_resp_error,
    input  wire        icx_resp_sc_success,

    input  wire        irq_m_software,
    input  wire        irq_m_timer,
    input  wire        irq_m_external,
    input  wire        irq_s_software,
    input  wire        irq_s_timer,
    input  wire        irq_s_external,

    output wire [63:0] dbg_pc,
    output wire [31:0] dbg_instr,
    output wire [63:0] dbg_rs1_data,
    output wire [63:0] dbg_rs2_data,
    output wire        dbg_halted,
    output wire        wfi_sleep_o,

    output wire [63:0]  trace_cycle,
    output wire [4:0]   trace_valid,
    output wire [4:0]   trace_stall,
    output wire [4:0]   trace_flush,
    output wire [4:0]   trace_advance,
    output wire [319:0] trace_ids,
    output wire [319:0] trace_pcs,
    output wire [159:0] trace_instrs,
    output wire [7:0]   trace_events,
    output wire [7:0]   trace_stall_causes,
    output wire         trace_retire_valid,
    output wire         trace_retire_arch,
    output wire         trace_retire_exception,
    output wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] trace_retire_cause,
    output wire [63:0]  trace_retire_next_pc,
    output wire         trace_retire_rd_write,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] trace_retire_rd,
    output wire [63:0]  trace_retire_wdata,
    output wire         trace_fetch_valid,
    output wire [63:0]  trace_fetch_pc,
    output wire [63:0]  trace_fetch_data,
    output wire         trace_load_valid,
    output wire [63:0]  trace_load_pc,
    output wire [63:0]  trace_load_addr,
    output wire [`RV64_REG_ADDR_WIDTH-1:0] trace_load_rd,
    output wire [63:0]  trace_load_data,
    output wire         trace_store_valid,
    output wire [63:0]  trace_store_pc,
    output wire [63:0]  trace_store_addr,
    output wire [63:0]  trace_store_data,
    output wire [7:0]   trace_store_wstrb
);

    localparam TRACE_ID_WIDTH = 64;
    localparam IF_ID_WIDTH = `RV64_FETCH_DECODE_BUS_WIDTH + TRACE_ID_WIDTH;
    // The initial banked bring-up waits for architectural writeback rather
    // than trying to extend the old one-cycle bypass paths across a read
    // response.  Fast predecode-target replay likewise cannot yet tolerate
    // the new dispatch backpressure.
    localparam GPR_FORWARDING = ENABLE_FORWARDING && !BANKED_GPR;
    localparam GPR_PREDECODE_TARGETS =
        ENABLE_PREDECODE_TARGETS && !BANKED_GPR;

`ifndef SYNTHESIS
    initial begin
        if (BANKED_GPR && !PIPE_ID_EX)
            $fatal(1, "Banked 1P GPR requires registered dispatch.");
    end
`endif

    reg [`RV64_XLEN-1:0] pc_q;
    reg [`RV64_XLEN-1:0] dbg_pc_q;
    reg [`RV64_INSTR_WIDTH-1:0] dbg_instr_q;
    reg [`RV64_XLEN-1:0] dbg_rs1_data_q;
    reg [`RV64_XLEN-1:0] dbg_rs2_data_q;
    reg halted_q;
    reg wfi_sleep_q;
    reg halt_pending_q;
    reg reset_pending_q;
    reg redirect_pending_q;
    reg redirect_direction_pending_q;
    reg redirect_target_mispredict_pending_q;
    reg [`RV64_XLEN-1:0] redirect_target_q;
    reg csr_serial_busy_q;
    reg restart_fetch_q;
    reg global_issue_inhibit_q;
    reg debug_serial_inflight_q;
    reg debug_serial_retired_q;
    reg serial_control_inflight_q;
    reg store_inflight_q;
    reg sfence_vma_inflight_q;
    reg satp_write_inflight_q;
    reg pmp_write_inflight_q;
    reg translation_invalidate_q;
    reg icache_invalidate_q;
    reg pmp_invalidate_q;
    reg [63:0] trace_cycle_q;
    reg [63:0] trace_next_id_q;

    wire fetch_pc_ready;
    wire fetch_pc_valid;
    wire translation_barrier_busy;
    wire fetch_redirect_replay;
    wire fetch_mem_valid;
    wire fetch_mem_next_valid;
    wire fetch_mem_ready;
    wire fetch_mem_write;
    wire [`RV64_XLEN-1:0] fetch_mem_addr;
    wire [`RV64_XLEN-1:0] fetch_mem_exec_addr;
    wire [`RV64_XLEN-1:0] fetch_mem_wdata;
    wire [7:0] fetch_mem_wstrb;
    wire [`RV64_XLEN-1:0] fetch_mem_rdata;
    wire fetch_bus_ready;
    wire fetch_bus_access_fault;
    wire fetch_bus_page_fault;
    wire debug_gen_pipe_event_valid;
    wire [1:0] debug_gen_pipe_event_stage;
    wire [`RV64_XLEN-1:0] debug_gen_pipe_event_addr;
    wire [`RV64_XLEN-1:0] debug_gen_pipe_event_data;
    wire debug_gen_pipe_cancel_now;
    wire debug_gen_pipe_cancelled;
    wire [1:0] debug_gen_state;
    wire debug_gen_owner_fetch;
    wire [`RV64_XLEN-1:0] debug_gen_pipe_vaddr;
    wire fetch_decode_valid;
    wire fetch_decode_clear;
    wire [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] fetch_decode_bus;
    wire [`RV64_XLEN-1:0] unused_fetch_decode_pc;
    wire [`RV64_INSTR_WIDTH-1:0] unused_fetch_decode_instr;
    wire unused_fetch_decode_fault;
    wire unused_fetch_decode_page_fault;
    wire fetch_mem_fault;
    wire fetch_mem_page_fault;
    wire [TRACE_ID_WIDTH-1:0] fetch_trace_id;

    wire if_id_in_clear;
    wire if_id_out_valid;
    wire if_id_out_clear;
    wire [IF_ID_WIDTH-1:0] if_id_out_data;
    wire [`RV64_XLEN-1:0] if_id_pc;
    wire [`RV64_INSTR_WIDTH-1:0] if_id_instr;
    wire if_id_instr_fault;
    wire if_id_instr_page_fault;
    wire [19:0] if_id_predecode_offset;
    wire if_id_predecode_valid;
    wire if_id_predecode_conditional;
    wire [TRACE_ID_WIDTH-1:0] if_id_trace_id;

    wire decode_valid;
    wire decode_illegal;
    wire [`RV64_EARLY_CLASS_WIDTH-1:0] decode_class_sel;
    wire [`RV64_EARLY_FORMAT_WIDTH-1:0] decode_format_sel;
    wire decode_uses_rs1;
    wire decode_uses_rs2;
    wire decode_uses_rd;
    wire [`RV64_REG_ADDR_WIDTH-1:0] decode_rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] decode_rs2_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] decode_rd_addr;
    wire decode_reg_write;
    wire decode_has_imm;
    wire [`RV64_XLEN-1:0] decode_imm;
    wire decode_mem_read;
    wire decode_mem_write;
    wire decode_branch;
    wire decode_jump;
    wire decode_word_op;
    wire decode_system;
    wire decode_fence;
    wire [`RV64_ALU_OP_WIDTH-1:0] decode_alu_op;
    wire [`RV64_LSU_OP_WIDTH-1:0] decode_lsu_op;
    wire [`RV64_BR_OP_WIDTH-1:0] decode_br_op;
    wire unused_decode_imm_valid;
    wire [`RV64_OPCODE_WIDTH-1:0] unused_decode_opcode;
    wire [`RV64_FUNCT3_WIDTH-1:0] unused_decode_funct3;
    wire [`RV64_FUNCT7_WIDTH-1:0] unused_decode_funct7;
    wire [`RV64_FUNCT12_WIDTH-1:0] unused_decode_funct12;
    wire [`RV64_ALU_EXT_WIDTH-1:0] decode_alu_ext;
    wire [`RV64_LSU_SIZE_WIDTH-1:0] unused_decode_lsu_size;
    wire unused_decode_lsu_unsigned;
    wire unused_decode_br_link;
    wire decode_br_indirect;
    wire unused_decode_subdecode_needed;
    wire unused_decode_extension_possible;
    wire unused_decode_compressed;
    wire [2:0] unused_decode_instr_bytes;
    wire unused_decode_summary = |{
        decode_class_sel,
        decode_format_sel,
        decode_uses_rs1,
        decode_uses_rs2,
        decode_uses_rd,
        decode_has_imm,
        unused_decode_imm_valid,
        unused_decode_opcode,
        unused_decode_funct3,
        unused_decode_funct7,
        unused_decode_funct12,
        unused_decode_lsu_size,
        unused_decode_lsu_unsigned,
        unused_decode_br_link,
        unused_decode_subdecode_needed,
        unused_decode_extension_possible,
        unused_decode_compressed,
        unused_decode_instr_bytes
    };

    wire [`RV64_XLEN-1:0] gpr_rs1_data;
    wire [`RV64_XLEN-1:0] gpr_rs2_data;
    wire gpr_read_ready;
    wire gpr_write_ready;
    wire wb_write;
    wire [`RV64_REG_ADDR_WIDTH-1:0] wb_rd_addr;
    wire [`RV64_XLEN-1:0] wb_rd_data;

    wire dispatch_decode_clear;
    wire dispatch_exec_valid;
    wire [`RV64_XLEN-1:0] dispatch_exec_pc;
    wire [`RV64_INSTR_WIDTH-1:0] dispatch_exec_instr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] dispatch_exec_rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] dispatch_exec_rs2_addr;
    wire [`RV64_XLEN-1:0] dispatch_exec_imm;
    wire [`RV64_REG_ADDR_WIDTH-1:0] dispatch_exec_rd_addr;
    wire [`RV64_ALU_EXT_WIDTH-1:0] dispatch_exec_alu_ext;
    wire [`RV64_ALU_OP_WIDTH-1:0] dispatch_exec_alu_op;
    wire [`RV64_LSU_OP_WIDTH-1:0] dispatch_exec_lsu_op;
    wire [`RV64_BR_OP_WIDTH-1:0] dispatch_exec_br_op;
    wire dispatch_exec_reg_write;
    wire dispatch_exec_mem_read;
    wire dispatch_exec_mem_write;
    wire dispatch_exec_branch;
    wire dispatch_exec_jump;
    wire dispatch_exec_predicted_taken;
    wire dispatch_exec_word_op;
    wire dispatch_exec_system;
    wire dispatch_exec_fence;
    wire dispatch_exec_illegal;
    wire dispatch_exec_ebreak;
    wire dispatch_exec_ecall;
    wire dispatch_exec_instr_fault;
    wire dispatch_exec_instr_page_fault;
    wire dispatch_raw_hazard;
    wire dispatch_waw_hazard;
    wire dispatch_scoreboard_stall;
    wire dispatch_scoreboard_clear;
    wire dispatch_decode_valid;
    wire [TRACE_ID_WIDTH-1:0] dispatch_exec_trace_id;
    wire unused_dispatch_hazards = |{
        dispatch_raw_hazard,
        dispatch_waw_hazard,
        dispatch_scoreboard_stall
    };


    wire exec_clear;
    wire exec_alu_ready;
    wire exec_lsu_ready;
    wire exec_br_ready;
    wire exec_system_ready;
    wire exec_forward_ex_valid;
    wire [`RV64_REG_ADDR_WIDTH-1:0] exec_forward_ex_rd_addr;
    wire exec_forward_mem_valid;
    wire [`RV64_REG_ADDR_WIDTH-1:0] exec_forward_mem_rd_addr;
    wire exec_redirect_valid;
    wire [`RV64_XLEN-1:0] exec_redirect_target;
    wire exec_branch_resolved;
    wire exec_branch_taken;
    wire [`RV64_FUNCT12_WIDTH-1:0] exec_csr_addr;
    wire [`RV64_XLEN-1:0] exec_csr_rdata;
    wire exec_csr_valid;
    wire exec_csr_writable;
    wire exec_csr_write;
    wire [`RV64_XLEN-1:0] exec_csr_wdata;
    wire exec_mem_valid;
    wire exec_mem_ready;
    wire exec_mem_bus_ready;
    wire exec_mem_error;
    wire exec_mem_lock;
    wire exec_mem_write;
    wire [`RV64_XLEN-1:0] exec_mem_addr;
    wire [`RV64_XLEN-1:0] exec_mem_wdata;
    wire [7:0] exec_mem_wstrb;
    wire [`RV64_XLEN-1:0] exec_mem_rdata;
    wire exec_mem_access_fault;
    wire exec_mem_page_fault;
    wire exec_mem_access;
    wire [`RV64_XLEN-1:0] exec_mem_effective_addr;
    wire [2:0] exec_mem_size;
    wire exec_wb_valid;
    wire exec_wb_clear;
    wire [`RV64_XLEN-1:0] exec_wb_pc;
    wire [`RV64_XLEN-1:0] exec_wb_next_pc;
    wire [`RV64_INSTR_WIDTH-1:0] exec_wb_instr;
    wire [`RV64_XLEN-1:0] exec_wb_data;
    wire [`RV64_XLEN-1:0] exec_wb_rs1_data;
    wire [`RV64_XLEN-1:0] exec_wb_rs2_data;
    wire [`RV64_REG_ADDR_WIDTH-1:0] exec_wb_rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] exec_wb_rs2_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] exec_wb_rd_addr;
    wire exec_wb_reg_write;
    wire exec_wb_illegal;
    wire exec_wb_ebreak;
    wire exec_wb_ecall;
    wire exec_wb_exception;
    wire exec_wb_halt;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] exec_wb_cause;
    wire [`RV64_XLEN-1:0] exec_wb_tval;
    wire exec_wb_mret;
    wire exec_wb_sret;
    wire exec_trace_ex_advance;
    wire exec_trace_mem_valid;
    wire exec_trace_mem_clear;
    wire [TRACE_ID_WIDTH-1:0] exec_trace_mem_id;
    wire [`RV64_XLEN-1:0] exec_trace_mem_pc;
    wire [`RV64_INSTR_WIDTH-1:0] exec_trace_mem_instr;
    wire [TRACE_ID_WIDTH-1:0] exec_trace_wb_id;
    wire exec_trace_serializing;
    wire exec_trace_load_valid;
    wire [`RV64_XLEN-1:0] exec_trace_load_pc;
    wire [`RV64_XLEN-1:0] exec_trace_load_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] exec_trace_load_rd;
    wire [`RV64_XLEN-1:0] exec_trace_load_data;
    wire exec_trace_store_valid;
    wire [`RV64_XLEN-1:0] exec_trace_store_pc;
    wire [`RV64_XLEN-1:0] exec_trace_store_addr;
    wire [`RV64_XLEN-1:0] exec_trace_store_data;
    wire [7:0] exec_trace_store_wstrb;
    wire bp_branch_present;
    wire bp_branch_allocate;
    wire bp_branch_resolve;
    wire bp_prediction_taken;
    wire bp_prediction_taken_effective;
    wire bp_prediction_weak;
    wire bp_prediction_target_valid;
    wire [`RV64_XLEN-1:0] bp_prediction_target;
    wire bp_target_mispredict;
    wire bp_update_overflow;
    wire bp_predict_redirect;
    wire bp_fast_predict_redirect;
    wire [`RV64_XLEN-1:0] bp_predict_target;
    wire [`RV64_XLEN-1:0] bp_fallback_target;
    wire [`RV64_XLEN-1:0] bp_predecode_imm = {
        {43{if_id_predecode_offset[19]}},
        if_id_predecode_offset,
        1'b0
    };
    wire bp_lookup_branch;
    wire bp_lookup_jump;
    wire bp_lookup_indirect;
    wire bp_fetch_stall;
    wire bp_decode_stall;
    wire unused_exec_wb_context = |{
        exec_wb_illegal,
        exec_wb_ebreak,
        exec_wb_ecall
    };

    wire csr_irq_pending;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] csr_irq_cause;
    wire csr_wfi_wake;
    wire [`RV64_XLEN-1:0] csr_trap_vector;
    wire [`RV64_XLEN-1:0] csr_mepc;
    wire [`RV64_XLEN-1:0] csr_sepc;
    wire [`RV64_PRIV_WIDTH-1:0] csr_priv_mode;
    wire [`RV64_PRIV_WIDTH-1:0] csr_data_priv_mode;
    wire csr_sret_allowed;
    wire csr_sfence_vma_allowed;
    wire [`RV64_SATP_MODE_WIDTH-1:0] csr_satp_mode;
    wire [`RV64_SATP_ASID_WIDTH-1:0] csr_satp_asid;
    wire [`RV64_SATP_PPN_WIDTH-1:0] csr_satp_root_ppn;
    wire csr_status_sum;
    wire csr_status_mxr;
    wire csr_trap_to_s;
    wire csr_pmp_bus_allow;
    wire csr_pmp_busy;
    wire csr_satp_busy;
    wire csr_hpm_busy;
    wire csr_serial_busy_raw =
        csr_pmp_busy || csr_satp_busy || csr_hpm_busy;
    wire core_mem_valid;
    wire core_mem_ready;
    wire core_mem_write;
    wire [`RV64_XLEN-1:0] core_mem_addr;
    wire [`RV64_XLEN-1:0] core_mem_pmp_addr;
    wire [`RV64_XLEN-1:0] core_mem_wdata;
    wire [7:0] core_mem_wstrb;
    wire [`RV64_PRIV_WIDTH-1:0] core_mem_priv;
    wire [2:0] core_mem_size;
    wire core_mem_exec;
    wire core_mem_error;
    wire core_pmp_valid;
    wire [`RV64_XLEN-1:0] core_pmp_addr;
    wire [`RV64_PRIV_WIDTH-1:0] core_pmp_priv;
    wire [2:0] core_pmp_size;
    wire core_pmp_write;
    wire core_pmp_exec;
    wire except_vector_valid;
    wire [`RV64_XLEN-1:0] except_vector_target;

    wire retire_release_valid;
    wire retire_release_uses_rs1;
    wire retire_release_uses_rs2;
    wire [`RV64_REG_ADDR_WIDTH-1:0] retire_release_rs1_addr;
    wire [`RV64_REG_ADDR_WIDTH-1:0] retire_release_rs2_addr;
    wire retire_release_reg_write;
    wire [`RV64_REG_ADDR_WIDTH-1:0] retire_release_rd_addr;

    wire hard_flush_redirect_req;
    wire hard_flush_trap_req;
    wire hard_flush_irq_req;
    wire hard_flush_mret_req;
    wire hard_flush_sret_req;
    wire hard_flush_restart_req;
    wire hard_flush_req;
    wire redirect_decision_req;
    wire redirect_capture_req;
    wire flush_fetch;
    wire restart_fetch_req;
    wire invalidate_fetch;
    wire redirect_fetch;
    wire flush_if_id;
    wire flush_id_ex;
    wire flush_ex_mem;
    wire flush_mem_wb;
    wire drain_fetch_req;
    wire control_event_inhibit;
    wire issue_inhibit_immediate;
    wire issue_inhibit_latch_set;
    wire issue_inhibit_owner_active;
    wire debug_serial_issue_block;
    wire global_issue_inhibit;
    wire dispatch_exec_issue_valid;
    wire dispatch_exec_clear;
    wire exec_mem_issue_valid;
    wire instruction_issue_fire;
    wire serial_control_issue;
    wire store_issue;
    wire sfence_vma_issue;
    wire satp_write_issue;
    wire pmp_write_issue;
    wire store_memory_complete;
    wire maintenance_invalidate_event;
    wire maintenance_invalidate_active;

    wire decode_ebreak = (if_id_instr == `RV64_INSTR_EBREAK);
    wire decode_ecall = (if_id_instr == `RV64_INSTR_ECALL);
    wire decode_ebreak_accept = if_id_out_valid &&
                                if_id_out_clear &&
                                decode_ebreak &&
                                !hard_flush_req;

    wire retire_accept = exec_wb_valid && exec_wb_clear;
    wire retire_csr = retire_accept &&
                      (`RV64_OPCODE(exec_wb_instr) == `RV64_OPCODE_SYSTEM) &&
                      (`RV64_FUNCT3(exec_wb_instr) !=
                       `RV64_FUNCT3_SYSTEM_PRIV);
    wire retire_exception = retire_accept && exec_wb_exception;
    wire retire_mret = retire_accept && exec_wb_mret && !exec_wb_exception;
    wire retire_sret = retire_accept && exec_wb_sret && !exec_wb_exception;
    wire retire_arch = retire_accept && !exec_wb_exception;
    wire retire_wfi = retire_arch &&
                      (exec_wb_instr == `RV64_INSTR_WFI);
    wire retire_fence = retire_accept &&
                        !exec_wb_exception &&
                        (`RV64_OPCODE(exec_wb_instr) ==
                         `RV64_OPCODE_MISC_MEM);
    wire retire_fence_i = retire_fence &&
                          (`RV64_FUNCT3(exec_wb_instr) ==
                           `RV64_ZIFENCEI_FUNCT3_FENCE_I);
    // Translation-control instructions already drain the 1P pipe before
    // issue.  Classify them once at that boundary and retain the result while
    // execute's serializing state prevents younger issue.  Retirement then
    // consumes a registered bit instead of decoding the full WB instruction
    // through the frontend-restart cone.
    assign instruction_issue_fire = dispatch_exec_issue_valid && exec_clear;
    assign serial_control_issue = instruction_issue_fire &&
                                  (dispatch_exec_system ||
                                   dispatch_exec_fence ||
                                   dispatch_exec_illegal ||
                                   dispatch_exec_instr_fault ||
                                   dispatch_exec_instr_page_fault);
    assign store_issue = instruction_issue_fire &&
                         dispatch_exec_mem_write;
    assign sfence_vma_issue = instruction_issue_fire &&
                              dispatch_exec_system &&
                              `RV64_IS_SFENCE_VMA(dispatch_exec_instr);
    assign satp_write_issue = exec_csr_write &&
                              (exec_csr_addr == `RV64_CSR_SATP);
    assign pmp_write_issue = exec_csr_write &&
        (((exec_csr_addr == `RV64_CSR_PMPCFG0) ||
          (exec_csr_addr == `RV64_CSR_PMPCFG2)) ||
         ((exec_csr_addr >= `RV64_CSR_PMPADDR0) &&
          (exec_csr_addr <= `RV64_CSR_PMPADDR15)));
    wire retire_sfence_vma = retire_arch && sfence_vma_inflight_q;
    wire retire_satp_write = retire_arch && satp_write_inflight_q;
    wire retire_pmp_write = retire_arch && pmp_write_inflight_q;
    wire retire_translation_fence =
        retire_sfence_vma || retire_satp_write;
    // All explicit maintenance invalidations use the same registered flow.
    // Trap/return and branch redirects are control transfers, not maintenance
    // invalidations, and retain their lower-latency paths.
    assign maintenance_invalidate_event =
        retire_translation_fence || retire_fence_i || retire_pmp_write;
    assign maintenance_invalidate_active =
        translation_invalidate_q || icache_invalidate_q ||
        pmp_invalidate_q;
    // The owning STORE/AMO is the only instruction allowed into EX/MEM while
    // store_inflight_q is set.  Release on that stage's completion handshake,
    // after translation, PMP, memory response, and fault classification have
    // all completed.  This avoids both an unsafe arbitrary-retire release and
    // a redundant WB opcode decode.
    assign store_memory_complete = store_inflight_q &&
                                   exec_trace_mem_valid &&
                                   exec_trace_mem_clear;
    wire wfi_irq_take = wfi_sleep_q && csr_irq_pending;
    wire irq_take = wfi_irq_take ||
                    (csr_irq_pending &&
                     retire_accept &&
                     !retire_exception &&
                     !exec_wb_halt &&
                     !retire_mret &&
                     !retire_sret);
    wire trap_enter = retire_exception || irq_take;
    wire trap_interrupt = irq_take;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] trap_cause =
        irq_take ? csr_irq_cause : exec_wb_cause;
    wire [`RV64_XLEN-1:0] trap_pc =
        wfi_irq_take ? pc_q :
        irq_take ? exec_wb_next_pc : exec_wb_pc;
    wire [`RV64_XLEN-1:0] trap_tval =
        irq_take ? 64'd0 : exec_wb_tval;

    assign hard_flush_trap_req = retire_exception && !exec_wb_halt;
    assign hard_flush_irq_req = irq_take;
    assign hard_flush_mret_req = retire_mret;
    assign hard_flush_sret_req = retire_sret;
    assign hard_flush_restart_req =
        maintenance_invalidate_event || retire_wfi;
    assign hard_flush_req = except_vector_valid;

    // Retirement control events become architectural flushes at the clock
    // edge.  During the decision cycle, inhibit younger execution and memory
    // launch without combinationally changing registered pipeline payloads.
    assign control_event_inhibit = hard_flush_trap_req ||
                                   hard_flush_irq_req ||
                                   hard_flush_mret_req ||
                                   hard_flush_sret_req ||
                                   hard_flush_restart_req;
    // Resolve locally in execute, then perform the global redirect one cycle
    // later.  An older retirement control event supersedes the younger branch
    // correction instead of leaving a stale redirect pending behind it.
    assign redirect_decision_req = exec_redirect_valid ||
                                   bp_target_mispredict;
    assign redirect_capture_req = redirect_decision_req &&
                                  !control_event_inhibit;
    // The all-instruction serializer deliberately delays a resolved redirect
    // until the retiring control instruction has also vacated WB.  Otherwise
    // the redirected fetch response can be flushed while dispatch remains
    // backpressured, losing the first target instruction.
    assign hard_flush_redirect_req = redirect_pending_q &&
        (!DEBUG_SERIALIZE_ALL_1P || !debug_serial_issue_block);
    // One owned latch is the scalar issue choke point.  System/fence/faulting
    // controls and stores acquire it when they issue.  Controls release at
    // retirement; stores release only after EX/MEM has classified the memory
    // result.  Redirect, CSR, and translation owners keep the same latch set
    // until their registered work completes.  Only traps and interrupts are
    // truly sudden retirement events; they acquire the latch immediately and
    // retain one conservative tail cycle.
    //
    // Do not gate the LSU request with this latch: a store owns the latch
    // precisely so translation, PMP, and the memory response can run while no
    // younger instruction issues.
    // Slow CSR busy is deliberately absent here.  The issuing serial control
    // sets global_issue_inhibit_q at the edge, then raw/registered CSR busy
    // may only retain that flop.  This removes the PMP/CSR sequencer from the
    // same-cycle issue-clear cone.
    assign issue_inhibit_immediate = hard_flush_trap_req ||
                                     hard_flush_irq_req;
    assign issue_inhibit_latch_set = serial_control_issue ||
                                     store_issue ||
                                     redirect_capture_req;
    assign issue_inhibit_owner_active =
        serial_control_inflight_q ||
        store_inflight_q ||
        redirect_pending_q ||
        csr_serial_busy_raw ||
        csr_serial_busy_q ||
        translation_barrier_busy ||
        maintenance_invalidate_active;
    assign debug_serial_issue_block = DEBUG_SERIALIZE_ALL_1P &&
                                      debug_serial_inflight_q;
    assign global_issue_inhibit = issue_inhibit_immediate ||
                                  global_issue_inhibit_q;
    assign dispatch_exec_issue_valid = dispatch_exec_valid &&
                                       gpr_read_ready &&
                                       !global_issue_inhibit &&
                                       !debug_serial_issue_block;
    assign dispatch_exec_clear = exec_clear &&
                                 gpr_read_ready &&
                                 !global_issue_inhibit &&
                                 !debug_serial_issue_block;
    assign exec_mem_issue_valid = exec_mem_valid &&
                                  !translation_barrier_busy &&
                                  !control_event_inhibit;

    // The retirement redirect clears IF/ID first.  Keep it empty while the
    // registered maintenance invalidation and delayed fetch restart drain any
    // speculative response that was already in flight.
    assign flush_if_id = hard_flush_req ||
                         redirect_fetch ||
                         maintenance_invalidate_active ||
                         restart_fetch_q;
    assign flush_id_ex = hard_flush_trap_req ||
                         hard_flush_irq_req ||
                         hard_flush_mret_req ||
                         hard_flush_sret_req ||
                         hard_flush_restart_req ||
                         redirect_pending_q;
    // Ordinary control-flow redirects discard only younger frontend and
    // dispatch state.  Clearing the complete 1P scoreboard here would also
    // release older EX/MEM and MEM/WB producers (notably strcmp's result just
    // before RET).  Only architectural pipeline flushes discard every owner.
    assign dispatch_scoreboard_clear = hard_flush_trap_req ||
                                       hard_flush_irq_req ||
                                       hard_flush_mret_req ||
                                       hard_flush_sret_req ||
                                       hard_flush_restart_req;
    assign flush_ex_mem = hard_flush_trap_req ||
                          hard_flush_irq_req ||
                          hard_flush_mret_req ||
                          hard_flush_sret_req;
    // MEM/WB still presents and retires the current instruction in the event
    // cycle.  Synchronous flush prevents a younger EX/MEM entry from replacing
    // it at the edge.
    assign flush_mem_wb = control_event_inhibit;
    assign drain_fetch_req = decode_ebreak_accept || halted_q;
    // Control-flow redirects normally discard only the unread fetch stream.
    // The all-instruction FPGA diagnostic invalidates resident lines as an
    // A/B check for stale redirect-target replay; normal 1P operation keeps
    // the address-matched resident replay path.  Context-changing events and
    // FENCE.I/SFENCE.VMA still invalidate the complete window.
    // Maintenance invalidation is presented for one full registered cycle.
    // Fetch restart follows on the next cycle.  WFI has no cache/TLB state to
    // invalidate and therefore retains its direct registered restart.
    assign restart_fetch_req = maintenance_invalidate_active || retire_wfi;
    // Serial restart events inhibit issue immediately.  Fetch is speculative
    // and may be replayed, so delay only that restart cancellation by one
    // cycle.  Reset, trap, interrupt, and privilege-return cancellation remain
    // immediate; they are not part of the slow-CSR completion cone.
    assign invalidate_fetch = reset_pending_q ||
                              drain_fetch_req ||
                              hard_flush_trap_req ||
                              hard_flush_irq_req ||
                              hard_flush_mret_req ||
                              hard_flush_sret_req ||
                              restart_fetch_q ||
                              (DEBUG_SERIALIZE_ALL_1P &&
                               hard_flush_redirect_req);
    assign redirect_fetch = hard_flush_redirect_req ||
                            bp_predict_redirect;
    assign flush_fetch = invalidate_fetch || redirect_fetch;

    assign fetch_pc_valid = fetch_pc_ready &&
                            !halted_q &&
                            !wfi_sleep_q &&
                            !halt_pending_q &&
                            !decode_ebreak_accept &&
                            !bp_fetch_stall &&
                            !hard_flush_req &&
                            !maintenance_invalidate_active &&
                            !translation_barrier_busy;
    assign fetch_decode_clear = if_id_in_clear && !bp_fetch_stall;

    openrv64_fetch #(
        .ENABLE_TRACE(ENABLE_TRACE),
        .ENABLE_PREDECODE_TARGETS(GPR_PREDECODE_TARGETS)
    ) u_fetch (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(invalidate_fetch),
        .redirect_i(redirect_fetch),
        .redirect_replay_i(bp_fast_predict_redirect),
        .redirect_pc_i(bp_predict_target),
        .redirect_replay_o(fetch_redirect_replay),
        .pc_ready_o(fetch_pc_ready),
        .pc_valid_i(fetch_pc_valid),
        .pc_i(pc_q),
        .trace_id_i(ENABLE_TRACE ? trace_next_id_q : 64'd0),
        .mem_valid_o(fetch_mem_valid),
        .mem_next_valid_o(fetch_mem_next_valid),
        .mem_ready_i(fetch_mem_ready),
        .mem_write_o(fetch_mem_write),
        .mem_addr_o(fetch_mem_addr),
        .mem_exec_addr_o(fetch_mem_exec_addr),
        .mem_wdata_o(fetch_mem_wdata),
        .mem_wstrb_o(fetch_mem_wstrb),
        .mem_rdata_i(fetch_mem_rdata),
        .mem_fault_i(fetch_mem_fault),
        .mem_page_fault_i(fetch_mem_page_fault),
        .decode_valid_o(fetch_decode_valid),
        .decode_ready_i(fetch_decode_clear),
        .decode_bus_o(fetch_decode_bus),
        .decode_pc_o(unused_fetch_decode_pc),
        .decode_instr_o(unused_fetch_decode_instr),
        .decode_fault_o(unused_fetch_decode_fault),
        .decode_page_fault_o(unused_fetch_decode_page_fault),
        .decode_ready1_i(1'b0),
        .trace_id_o(fetch_trace_id)
    );

    assign if_id_out_clear = dispatch_decode_clear && !bp_decode_stall;

    generate
        if (PIPE_1P_DECODE_QUEUE != 0) begin : g_if_id_elastic
            openrv64_elastic_buffer #(
                .WIDTH(IF_ID_WIDTH)
            ) u_if_id (
                .clk(clk),
                .rst_n(rst_n),
                .flush_i(flush_if_id),
                .in_valid_i(fetch_decode_valid && !bp_fetch_stall),
                .in_clear_o(if_id_in_clear),
                .in_data_i({fetch_trace_id, fetch_decode_bus}),
                .out_valid_o(if_id_out_valid),
                .out_clear_i(if_id_out_clear),
                .out_data_o(if_id_out_data)
            );
        end else begin : g_if_id_stage
            openrv64_stage #(
                .WIDTH(IF_ID_WIDTH),
                .REGISTERED(PIPE_IF_ID)
            ) u_if_id (
                .clk(clk),
                .rst_n(rst_n),
                .flush_i(flush_if_id),
                .in_valid_i(fetch_decode_valid && !bp_fetch_stall),
                .in_clear_o(if_id_in_clear),
                .in_data_i({fetch_trace_id, fetch_decode_bus}),
                .out_valid_o(if_id_out_valid),
                .out_clear_i(if_id_out_clear),
                .out_data_o(if_id_out_data)
            );
        end
    endgenerate

    assign {
        if_id_trace_id,
        if_id_predecode_conditional,
        if_id_predecode_valid,
        if_id_predecode_offset,
        if_id_instr_page_fault,
        if_id_instr_fault,
        if_id_pc,
        if_id_instr
    } = if_id_out_data;

    openrv64_decode_top #(
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_RV64A(ENABLE_RV64A)
    ) u_decode (
        .instr_i(if_id_instr),
        .extension_selected_i(1'b0),
        .extension_valid_i(1'b0),
        .extension_illegal_i(1'b0),
        .extension_class_sel_i({`RV64_EARLY_CLASS_WIDTH{1'b0}}),
        .extension_format_sel_i({`RV64_EARLY_FORMAT_WIDTH{1'b0}}),
        .extension_uses_rs1_i(1'b0),
        .extension_uses_rs2_i(1'b0),
        .extension_uses_rd_i(1'b0),
        .extension_rs1_addr_i({`RV64_REG_ADDR_WIDTH{1'b0}}),
        .extension_rs2_addr_i({`RV64_REG_ADDR_WIDTH{1'b0}}),
        .extension_rd_addr_i({`RV64_REG_ADDR_WIDTH{1'b0}}),
        .extension_reg_write_i(1'b0),
        .extension_imm_valid_i(1'b0),
        .extension_has_imm_i(1'b0),
        .extension_imm_i({`RV64_XLEN{1'b0}}),
        .extension_mem_read_i(1'b0),
        .extension_mem_write_i(1'b0),
        .extension_lsu_op_sel_i({`RV64_LSU_OP_WIDTH{1'b0}}),
        .extension_lsu_size_sel_i({`RV64_LSU_SIZE_WIDTH{1'b0}}),
        .extension_lsu_unsigned_i(1'b0),
        .extension_payload_i(1'b0),
        .valid_o(decode_valid),
        .illegal_o(decode_illegal),
        .opcode_o(unused_decode_opcode),
        .funct3_o(unused_decode_funct3),
        .funct7_o(unused_decode_funct7),
        .funct12_o(unused_decode_funct12),
        .class_sel_o(decode_class_sel),
        .format_sel_o(decode_format_sel),
        .compressed_o(unused_decode_compressed),
        .instr_bytes_o(unused_decode_instr_bytes),
        .uses_rs1_o(decode_uses_rs1),
        .uses_rs2_o(decode_uses_rs2),
        .uses_rd_o(decode_uses_rd),
        .rs1_addr_o(decode_rs1_addr),
        .rs2_addr_o(decode_rs2_addr),
        .rd_addr_o(decode_rd_addr),
        .reg_write_o(decode_reg_write),
        .imm_valid_o(unused_decode_imm_valid),
        .has_imm_o(decode_has_imm),
        .imm_o(decode_imm),
        .mem_read_o(decode_mem_read),
        .mem_write_o(decode_mem_write),
        .branch_o(decode_branch),
        .jump_o(decode_jump),
        .word_op_o(decode_word_op),
        .system_o(decode_system),
        .fence_o(decode_fence),
        .alu_ext_sel_o(decode_alu_ext),
        .alu_op_sel_o(decode_alu_op),
        .lsu_op_sel_o(decode_lsu_op),
        .lsu_size_sel_o(unused_decode_lsu_size),
        .lsu_unsigned_o(unused_decode_lsu_unsigned),
        .br_op_sel_o(decode_br_op),
        .br_link_o(unused_decode_br_link),
        .br_indirect_o(decode_br_indirect),
        .subdecode_needed_o(unused_decode_subdecode_needed),
        .extension_decode_possible_o(unused_decode_extension_possible)
    );

    assign bp_lookup_branch = if_id_predecode_valid ?
                              if_id_predecode_conditional : decode_branch;
    assign bp_lookup_jump = if_id_predecode_valid ?
                            !if_id_predecode_conditional : decode_jump;
    assign bp_lookup_indirect = if_id_predecode_valid ?
                                1'b0 : decode_br_indirect;
    assign bp_branch_present = if_id_out_valid &&
                               !hard_flush_req &&
                               !wfi_sleep_q &&
                               (if_id_predecode_valid ||
                                decode_branch || decode_jump);
    assign bp_branch_allocate = bp_branch_present && if_id_out_clear;
    assign bp_branch_resolve = exec_branch_resolved;
    // Debug serialization uses the resolved-control path exclusively.  A
    // speculative predictor redirect can arrive while the sole issued branch
    // still owns the pipe and is intentionally not replay-safe under this
    // diagnostic mode.
    assign bp_prediction_taken_effective = DEBUG_SERIALIZE_ALL_1P ?
                                           1'b0 : bp_prediction_taken;
    assign bp_predict_redirect = bp_branch_allocate &&
                                 bp_prediction_taken_effective;
    assign bp_fast_predict_redirect = bp_predict_redirect &&
                                      if_id_predecode_valid;
    assign bp_predict_target = bp_prediction_target_valid ?
                               bp_prediction_target : bp_fallback_target;

    // Predecoded direct controls carry a compact signed displacement and reuse
    // the normal target adder. Cold controls and JALR use the decoder output.
    openrv64_prefix_addsub u_bp_fallback_target (
        .a_i(if_id_pc),
        .b_i(if_id_predecode_valid ? bp_predecode_imm : decode_imm),
        .sub_i(1'b0),
        .result_o(bp_fallback_target)
    );

    openrv64_exec_bp #(
        .BP_TYPE(BP_TYPE),
        .ENABLE_RAS(BP_RAS_ENABLE),
        .RAS_DEPTH(BP_RAS_DEPTH),
        .BIMODAL_ENTRIES(BP_BIMODAL_ENTRIES),
        .BIMODAL_COUNTER_BITS(BP_BIMODAL_COUNTER_BITS),
        .BIMODAL_UPDATE_DEPTH(BP_BIMODAL_UPDATE_DEPTH),
        .GSHARE_ENTRIES(BP_GSHARE_ENTRIES),
        .GSHARE_COUNTER_BITS(BP_GSHARE_COUNTER_BITS),
        .BTB_ENTRIES(BP_BTB_ENTRIES),
        .BTB_TAG_BITS(BP_BTB_TAG_BITS),
        .INFLIGHT_DEPTH(BP_INFLIGHT_DEPTH)
    ) u_bp (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(hard_flush_req),
        .squash_i(1'b0),
        .recovery_i(1'b0),
        .recovery_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .ras_context_flush_i(hard_flush_trap_req ||
                             hard_flush_irq_req ||
                             hard_flush_mret_req ||
                             hard_flush_sret_req ||
                             hard_flush_restart_req),
        .lookup_valid_i(bp_branch_present),
        .lookup_branch_i(bp_lookup_branch),
        .lookup_jump_i(bp_lookup_jump),
        .lookup_indirect_i(bp_lookup_indirect),
        .lookup_backward_i(
            if_id_predecode_valid ? bp_predecode_imm[63] : decode_imm[63]),
        .lookup_instr_i(if_id_instr),
        .lookup_pc_i(if_id_pc),
        .lookup_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .lookup_allocate_i(bp_branch_allocate),
        .resolve_valid_i(bp_branch_resolve),
        .resolve_branch_i(dispatch_exec_branch),
        .resolve_taken_i(exec_branch_taken),
        .resolve_instr_i(dispatch_exec_instr),
        .resolve_pc_i(dispatch_exec_pc),
        .resolve_target_i(exec_redirect_target),
        .resolve_id_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .train_valid_i({2'b00, bp_branch_resolve}),
        .train_branch_i({2'b00, dispatch_exec_branch}),
        .train_taken_i({2'b00, exec_branch_taken}),
        .train_pc_i({128'd0, dispatch_exec_pc}),
        .prediction_taken_o(bp_prediction_taken),
        .prediction_weak_o(bp_prediction_weak),
        .prediction_target_valid_o(bp_prediction_target_valid),
        .prediction_target_o(bp_prediction_target),
        .target_mispredict_o(bp_target_mispredict),
        .update_overflow_o(bp_update_overflow),
        .fetch_stall_o(bp_fetch_stall),
        .decode_stall_o(bp_decode_stall),
        .background_stall_o(),
        .capacity_stall_o(),
        .unresolved_target_stall_o()
    );

    openrv64_rv64i_gpr_1p #(
        .BANKED(BANKED_GPR),
        .FPGA_LUTRAM(FPGA_GPR_LUTRAM)
    ) u_gpr (
        .clk(clk),
        .rst_n(rst_n),
        .read_valid_i(dispatch_exec_valid),
        .read_clear_i(instruction_issue_fire),
        .read_flush_i(flush_id_ex),
        .read_ready_o(gpr_read_ready),
        .rs1_addr_i(dispatch_exec_rs1_addr),
        .rs1_data_o(gpr_rs1_data),
        .rs2_addr_i(dispatch_exec_rs2_addr),
        .rs2_data_o(gpr_rs2_data),
        .rd_write_i(wb_write),
        .rd_clear_i(retire_accept),
        .rd_ready_o(gpr_write_ready),
        .rd_addr_i(wb_rd_addr),
        .rd_data_i(wb_rd_data)
    );

    wire cmu_issue_fire = dispatch_exec_issue_valid && exec_clear;
    wire cmu_fetch_fire = fetch_mem_valid && fetch_mem_ready;
    wire cmu_lsu_fire = exec_mem_valid && exec_mem_ready;
    wire [`OPENRV64_CMU_EVENT_COUNT-1:0] cmu_perf_events = {
        1'b0,                                      // 37 lost issue slot 2
        1'b0,                                      // 36 lost issue slot 1
        1'b0,                                      // 35 lost issue slot 0
        1'b0,                                      // 34 completed behind head
        1'b0,                                      // 33 retire head incomplete
        cmu_lsu_fire && exec_mem_write,             // 32 store request
        1'b0,                                      // 31 L1D load miss
        1'b0,                                      // 30 L1D load hit
        1'b0,                                      // 29 demand waits prefetch
        1'b0,                                      // 28 useful L1I prefetch
        1'b0,                                      // 27 L1I prefetch launch
        1'b0,                                      // 26 L1I demand miss
        1'b0,                                      // 25 L1I demand hit
        exec_mem_valid,                            // 24 LSU outstanding
        exec_mem_valid && !exec_mem_ready,         // 23 LSU request wait
        cmu_lsu_fire,                              // 22 LSU response
        cmu_lsu_fire,                              // 21 LSU request
        flush_fetch,                               // 20 fetch cancellation
        cmu_fetch_fire,                            // 19 fetch response
        cmu_fetch_fire,                            // 18 fetch request
        redirect_target_mispredict_pending_q,      // 17 target mispredict
        redirect_direction_pending_q,              // 16 direction mispredict
        1'b0,                                      // 15 redirect recovery
        hard_flush_redirect_req,                   // 14 redirect
        dispatch_exec_valid && !exec_clear,        // 13 pipe busy stall
        translation_barrier_busy && dispatch_exec_valid,
                                                    // 12 barrier stall
        dispatch_scoreboard_stall,                 // 11 RAW stall
        !dispatch_exec_valid,                      // 10 dispatch empty
        !fetch_decode_valid,                       //  9 frontend empty
        !retire_arch,                              //  8 zero retire
        !cmu_issue_fire,                           //  7 zero issue
        1'b0,                                      //  6 retire lane 2
        1'b0,                                      //  5 retire lane 1
        retire_arch,                               //  4 retire lane 0
        1'b0,                                      //  3 issue lane 2
        1'b0,                                      //  2 issue lane 1
        cmu_issue_fire,                            //  1 issue lane 0
        1'b0                                       //  0 cycle (CMU-owned)
    };

    openrv64_rv64i_csrs #(
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_RV64A(ENABLE_RV64A),
        .HPM_COUNTERS(HPM_COUNTERS),
        .PMP_ACTIVE_ENTRIES(PMP_ACTIVE_ENTRIES)
    ) u_csrs (
        .clk(clk),
        .rst_n(rst_n),
        .csr_addr_i(exec_csr_addr),
        .csr_rdata_o(exec_csr_rdata),
        .csr_valid_o(exec_csr_valid),
        .csr_writable_o(exec_csr_writable),
        .csr_write_i(exec_csr_write),
        .csr_op_i(`RV64_FUNCT3(dispatch_exec_instr)),
        .csr_wdata_i(exec_csr_wdata),
        .csr_write_ready_o(),
        .csr_pmp_busy_o(csr_pmp_busy),
        .csr_satp_busy_o(csr_satp_busy),
        .csr_hpm_busy_o(csr_hpm_busy),
        .extension_csr_selected_i(1'b0),
        .extension_csr_valid_i(1'b0),
        .extension_csr_writable_i(1'b0),
        .extension_csr_rdata_i({`RV64_XLEN{1'b0}}),
        .extension_csr_write_ready_i(1'b1),
        .extension_csr_write_o(),
        .extension_csr_wdata_o(),
        .extension_mstatus_write_o(),
        .extension_sstatus_write_o(),
        .extension_misa_bits_i({`RV64_XLEN{1'b0}}),
        .extension_mstatus_bits_i({`RV64_XLEN{1'b0}}),
        .extension_sstatus_bits_i({`RV64_XLEN{1'b0}}),
        .trap_enter_i(trap_enter),
        .trap_interrupt_i(trap_interrupt),
        .trap_cause_i(trap_cause),
        .trap_pc_i(trap_pc),
        .trap_tval_i(trap_tval),
        .mret_i(retire_mret),
        .sret_i(retire_sret),
        .retire_count_i({1'b0, retire_arch}),
        .perf_events_i(cmu_perf_events),
        .irq_software_i(irq_m_software),
        .irq_timer_i(irq_m_timer),
        .irq_external_i(irq_m_external),
        .irq_s_software_i(irq_s_software),
        .irq_s_timer_i(irq_s_timer),
        .irq_s_external_i(irq_s_external),
        .irq_pending_o(csr_irq_pending),
        .irq_cause_o(csr_irq_cause),
        .wfi_wake_o(csr_wfi_wake),
        .trap_vector_o(csr_trap_vector),
        .trap_to_s_o(csr_trap_to_s),
        .mepc_o(csr_mepc),
        .sepc_o(csr_sepc),
        .priv_mode_o(csr_priv_mode),
        .data_priv_mode_o(csr_data_priv_mode),
        .sret_allowed_o(csr_sret_allowed),
        .sfence_vma_allowed_o(csr_sfence_vma_allowed),
        .satp_mode_o(csr_satp_mode),
        .satp_asid_o(csr_satp_asid),
        .satp_root_ppn_o(csr_satp_root_ppn),
        .status_sum_o(csr_status_sum),
        .status_mxr_o(csr_status_mxr),
        .data_access_context_change_o(),
        .pmp_bus_valid_i(core_pmp_valid),
        .pmp_bus_addr_i(core_pmp_addr),
        .pmp_bus_size_i(core_pmp_size),
        .pmp_bus_write_i(core_pmp_write),
        .pmp_bus_exec_i(core_pmp_exec),
        .pmp_bus_priv_mode_i(core_pmp_priv),
        .pmp_bus_allow_o(csr_pmp_bus_allow)
    );

    openrv64_except_vector #(
        .RESET_VECTOR(RESET_VECTOR)
    ) u_except_vector (
        .reset_i(reset_pending_q),
        .trap_i(hard_flush_trap_req),
        .irq_i(hard_flush_irq_req),
        .mret_i(hard_flush_mret_req),
        .sret_i(hard_flush_sret_req),
        .restart_i(hard_flush_restart_req),
        .redirect_i(hard_flush_redirect_req),
        .trap_vector_i(csr_trap_vector),
        .mepc_i(csr_mepc),
        .sepc_i(csr_sepc),
        .restart_target_i(exec_wb_next_pc),
        .redirect_target_i(redirect_target_q),
        .vector_valid_o(except_vector_valid),
        .vector_target_o(except_vector_target)
    );

    assign dispatch_decode_valid = if_id_out_valid &&
                                   !bp_decode_stall &&
                                   !hard_flush_req;

    openrv64_dispatch #(
        .BACKEND_CONFIG(BACKEND_CONFIG),
        .REGISTERED(PIPE_ID_EX),
        .ENABLE_FORWARDING(GPR_FORWARDING),
        .DECODE_STAGE_1P(PIPE_1P_DECODE_QUEUE)
    ) u_dispatch (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush_id_ex),
        .scoreboard_clear_1p_i(dispatch_scoreboard_clear),
        .decode_valid_i(dispatch_decode_valid),
        .decode_clear_o(dispatch_decode_clear),
        .decode_pc_i(if_id_pc),
        .decode_instr_i(if_id_instr),
        .decode_trace_id_i(if_id_trace_id),
        .decode_imm_i(decode_imm),
        .decode_uses_rs1_i(decode_uses_rs1),
        .decode_uses_rs2_i(decode_uses_rs2),
        .decode_rs1_addr_i(decode_rs1_addr),
        .decode_rs2_addr_i(decode_rs2_addr),
        .decode_rd_addr_i(decode_rd_addr),
        .decode_alu_ext_i(decode_alu_ext),
        .decode_alu_op_i(decode_alu_op),
        .decode_lsu_op_i(decode_lsu_op),
        .decode_br_op_i(decode_br_op),
        .decode_reg_write_i(decode_reg_write),
        .decode_mem_read_i(decode_mem_read),
        .decode_mem_write_i(decode_mem_write),
        .decode_branch_i(decode_branch),
        .decode_jump_i(decode_jump),
        .decode_predicted_taken_i(bp_prediction_taken_effective),
        .decode_word_op_i(decode_word_op),
        .decode_system_i(decode_system),
        .decode_fence_i(decode_fence),
        .decode_illegal_i(decode_illegal || !decode_valid),
        .decode_ebreak_i(decode_ebreak),
        .decode_ecall_i(decode_ecall),
        .decode_instr_fault_i(if_id_instr_fault),
        .decode_instr_page_fault_i(if_id_instr_page_fault),
        .conditional_resolve_valid_3p_i(1'b0),
        .conditional_resolve_id_3p_i(
            {`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .conditional_resolve_slot_3p_i(3'd0),
        .candidate_operand_ready_3p_i(6'b000000),
        .candidate_address_ready_3p_i(3'b111),
        .exec_valid_o(dispatch_exec_valid),
        .exec_clear_i(dispatch_exec_clear),
        .exec_alu_ready_i(exec_alu_ready),
        .exec_lsu_ready_i(exec_lsu_ready),
        .exec_br_ready_i(exec_br_ready),
        .exec_system_ready_i(exec_system_ready),
        .forward_ex_valid_i(exec_forward_ex_valid),
        .forward_ex_rd_addr_i(exec_forward_ex_rd_addr),
        .forward_mem_valid_i(exec_forward_mem_valid),
        .forward_mem_rd_addr_i(exec_forward_mem_rd_addr),
        .exec_pc_o(dispatch_exec_pc),
        .exec_instr_o(dispatch_exec_instr),
        .exec_trace_id_o(dispatch_exec_trace_id),
        .exec_rs1_addr_o(dispatch_exec_rs1_addr),
        .exec_rs2_addr_o(dispatch_exec_rs2_addr),
        .exec_imm_o(dispatch_exec_imm),
        .exec_rd_addr_o(dispatch_exec_rd_addr),
        .exec_alu_ext_o(dispatch_exec_alu_ext),
        .exec_alu_op_o(dispatch_exec_alu_op),
        .exec_lsu_op_o(dispatch_exec_lsu_op),
        .exec_br_op_o(dispatch_exec_br_op),
        .exec_reg_write_o(dispatch_exec_reg_write),
        .exec_mem_read_o(dispatch_exec_mem_read),
        .exec_mem_write_o(dispatch_exec_mem_write),
        .exec_branch_o(dispatch_exec_branch),
        .exec_jump_o(dispatch_exec_jump),
        .exec_predicted_taken_o(dispatch_exec_predicted_taken),
        .exec_word_op_o(dispatch_exec_word_op),
        .exec_system_o(dispatch_exec_system),
        .exec_fence_o(dispatch_exec_fence),
        .exec_illegal_o(dispatch_exec_illegal),
        .exec_ebreak_o(dispatch_exec_ebreak),
        .exec_ecall_o(dispatch_exec_ecall),
        .exec_instr_fault_o(dispatch_exec_instr_fault),
        .exec_instr_page_fault_o(dispatch_exec_instr_page_fault),
        .retire_valid_i(retire_release_valid),
        .retire_csr_i(retire_csr),
        .retire_fence_i(retire_fence),
        .retire_uses_rs1_i(retire_release_uses_rs1),
        .retire_uses_rs2_i(retire_release_uses_rs2),
        .retire_rs1_addr_i(retire_release_rs1_addr),
        .retire_rs2_addr_i(retire_release_rs2_addr),
        .retire_reg_write_i(retire_release_reg_write),
        .retire_rd_addr_i(retire_release_rd_addr),
        .raw_hazard_o(dispatch_raw_hazard),
        .waw_hazard_o(dispatch_waw_hazard),
        .scoreboard_stall_o(dispatch_scoreboard_stall),
        .squash_frontend_3p_i(1'b0),
        .squash_inclusive_3p_i(1'b0),
        .squash_id_3p_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .squash_slot_3p_i(3'd0),
        .translation_bypass_3p_i(1'b0),
        .decode_valid_3p_i(3'b000),
        .decode_payload_3p_i({3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}}),
        .decode_uses_rs1_3p_i(3'b000),
        .decode_uses_rs2_3p_i(3'b000),
        .gpr_read_data_3p_i({6*`RV64_XLEN{1'b0}}),
        .allocation_ready_3p_i(1'b0),
        .rename_free_valid_3p_i(3'b000),
        .rename_free_tag_3p_i(
            {3*`OPENRV64_PHYS_REG_ADDR_WIDTH{1'b0}}),
        .rename_write_valid_3p_i(3'b000),
        .rename_write_tag_3p_i(
            {3*`OPENRV64_PHYS_REG_ADDR_WIDTH{1'b0}}),
        .rename_commit_valid_3p_i(3'b000),
        .rename_commit_arch_3p_i(
            {3*`RV64_REG_ADDR_WIDTH{1'b0}}),
        .rename_commit_phys_3p_i(
            {3*`OPENRV64_PHYS_REG_ADDR_WIDTH{1'b0}}),
        .allocation_id_3p_i(
            {3*`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .allocation_slot_3p_i(9'd0),
        .pipe_ready_3p_i(
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}}),
        .forward_valid_3p_i(2'b00),
        .forward_rd_addr_3p_i({2*`RV64_REG_ADDR_WIDTH{1'b0}}),
        .completion_forward_valid_3p_i(3'b000),
        .branch_completion_forward_valid_3p_i(3'b000),
        .completion_forward_rd_addr_3p_i(
            {3*`RV64_REG_ADDR_WIDTH{1'b0}}),
        .completion_forward_data_3p_i({3*`RV64_XLEN{1'b0}}),
        .forward_map_valid_3p_i(32'd0),
        .forward_map_data_3p_i({32*`RV64_XLEN{1'b0}}),
        .completion_valid_3p_i(3'b000),
        .completion_id_3p_i(
            {3*`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .completion_payload_3p_i(
            {3*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH{1'b0}}),
        .retire_valid_3p_i(3'b000),
        .retire_id_3p_i(
            {3*`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .retire_slot_3p_i(9'd0),
        .retire_uses_rs1_3p_i(3'b000),
        .retire_uses_rs2_3p_i(3'b000),
        .retire_rs1_addr_3p_i({3*`RV64_REG_ADDR_WIDTH{1'b0}}),
        .retire_rs2_addr_3p_i({3*`RV64_REG_ADDR_WIDTH{1'b0}}),
        .retire_reg_write_3p_i(3'b000),
        .retire_rd_addr_3p_i({3*`RV64_REG_ADDR_WIDTH{1'b0}}),
        .retire_hard_3p_i(3'b000),
        .recovery_valid_3p_i(1'b0),
        .recovery_reg_write_3p_i(1'b0),
        .recovery_rd_addr_3p_i(`RV64_REG_X0),
        .next_retire_id_3p_i(
            {`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .next_retire_slot_3p_i(3'd0)
    );

    openrv64_exec_top #(
        .BACKEND_CONFIG(BACKEND_CONFIG),
        .PIPE_EX_MEM(PIPE_EX_MEM),
        .PIPE_MEM_WB(PIPE_MEM_WB),
        .ENABLE_RV64M(ENABLE_RV64M),
        .ENABLE_FORWARDING(GPR_FORWARDING),
        .ENABLE_LOAD_FORWARDING(ENABLE_LOAD_FORWARDING)
    ) u_exec (
        .clk(clk),
        .rst_n(rst_n),
        .valid_i(dispatch_exec_issue_valid),
        .clear_o(exec_clear),
        .alu_ready_o(exec_alu_ready),
        .lsu_ready_o(exec_lsu_ready),
        .br_ready_o(exec_br_ready),
        .system_ready_o(exec_system_ready),
        .flush_ex_mem_i(flush_ex_mem),
        .flush_mem_wb_i(flush_mem_wb),
        .pc_i(dispatch_exec_pc),
        .instr_i(dispatch_exec_instr),
        .trace_id_i(dispatch_exec_trace_id),
        .rs1_addr_i(dispatch_exec_rs1_addr),
        .rs2_addr_i(dispatch_exec_rs2_addr),
        .rs1_data_i(gpr_rs1_data),
        .rs2_data_i(gpr_rs2_data),
        .imm_i(dispatch_exec_imm),
        .rd_addr_i(dispatch_exec_rd_addr),
        .alu_ext_i(dispatch_exec_alu_ext),
        .alu_op_i(dispatch_exec_alu_op),
        .lsu_op_i(dispatch_exec_lsu_op),
        .br_op_i(dispatch_exec_br_op),
        .reg_write_i(dispatch_exec_reg_write),
        .mem_read_i(dispatch_exec_mem_read),
        .mem_write_i(dispatch_exec_mem_write),
        .branch_i(dispatch_exec_branch),
        .jump_i(dispatch_exec_jump),
        .predicted_taken_i(dispatch_exec_predicted_taken),
        .word_op_i(dispatch_exec_word_op),
        .system_i(dispatch_exec_system),
        .fence_i(dispatch_exec_fence),
        .illegal_i(dispatch_exec_illegal),
        .ebreak_i(dispatch_exec_ebreak),
        .ecall_i(dispatch_exec_ecall),
        .instr_access_fault_i(dispatch_exec_instr_fault),
        .instr_page_fault_i(dispatch_exec_instr_page_fault),
        .priv_mode_i(csr_priv_mode),
        .sret_allowed_i(csr_sret_allowed),
        .sfence_vma_allowed_i(csr_sfence_vma_allowed),
        .redirect_valid_o(exec_redirect_valid),
        .redirect_target_o(exec_redirect_target),
        .branch_resolved_o(exec_branch_resolved),
        .branch_taken_o(exec_branch_taken),
        .csr_addr_o(exec_csr_addr),
        .csr_rdata_i(exec_csr_rdata),
        .csr_valid_i(exec_csr_valid),
        .csr_writable_i(exec_csr_writable),
        // Slow CSR sequencers are owned by the global issue inhibit and the
        // WB retirement hold.  Execute does not need a second copy of the
        // interlock in every local ready path.
        .csr_busy_i(1'b0),
        .csr_write_o(exec_csr_write),
        .csr_wdata_o(exec_csr_wdata),
        .mem_valid_o(exec_mem_valid),
        .mem_ready_i(exec_mem_ready),
        .mem_tag_o(),
        .mem_xlate_only_o(),
        .mem_physical_o(),
        .mem_resp_valid_i(1'b0),
        .mem_resp_ready_o(),
        .mem_resp_tag_i({`OPENRV64_LSU_TAG_WIDTH{1'b0}}),
        .mem_resp_paddr_i({`RV64_XLEN{1'b0}}),
        .mem_store_done_valid_i(1'b0),
        .mem_store_done_ready_o(),
        .mem_store_done_tag_i(
            {`OPENRV64_LSU_TAG_WIDTH{1'b0}}),
        .mem_error_i(exec_mem_error),
        .mem_page_fault_i(exec_mem_page_fault),
        .mem_access_allowed_i(1'b1),
        .mem_lock_o(exec_mem_lock),
        .mem_write_o(exec_mem_write),
        .mem_addr_o(exec_mem_addr),
        .mem_wdata_o(exec_mem_wdata),
        .mem_wstrb_o(exec_mem_wstrb),
        .mem_access_o(exec_mem_access),
        .mem_effective_addr_o(exec_mem_effective_addr),
        .mem_size_o(exec_mem_size),
        .mem_rdata_i(exec_mem_rdata),
        .mem_xlate_valid_o(),
        .mem_xlate_ready_i(1'b0),
        .mem_xlate_tag_o(),
        .mem_xlate_write_o(),
        .mem_xlate_vaddr_o(),
        .mem_xlate_resp_valid_i(1'b0),
        .mem_xlate_resp_ready_o(),
        .mem_xlate_resp_tag_i(
            {`OPENRV64_LSU_XLATE_TAG_WIDTH{1'b0}}),
        .mem_xlate_resp_paddr_i({`RV64_XLEN{1'b0}}),
        .mem_xlate_resp_access_fault_i(1'b0),
        .mem_xlate_resp_page_fault_i(1'b0),
        .mem1_valid_o(), .mem1_ready_i(1'b0), .mem1_tag_o(),
        .mem1_lock_o(), .mem1_write_o(), .mem1_addr_o(),
        .mem1_wdata_o(), .mem1_wstrb_o(), .mem1_access_o(),
        .mem1_effective_addr_o(), .mem1_size_o(),
        .wb_valid_o(exec_wb_valid),
        .wb_clear_i(exec_wb_clear),
        .wb_pc_o(exec_wb_pc),
        .wb_next_pc_o(exec_wb_next_pc),
        .wb_instr_o(exec_wb_instr),
        .wb_data_o(exec_wb_data),
        .wb_rs1_data_o(exec_wb_rs1_data),
        .wb_rs2_data_o(exec_wb_rs2_data),
        .wb_rs1_addr_o(exec_wb_rs1_addr),
        .wb_rs2_addr_o(exec_wb_rs2_addr),
        .wb_rd_addr_o(exec_wb_rd_addr),
        .wb_reg_write_o(exec_wb_reg_write),
        .wb_illegal_o(exec_wb_illegal),
        .wb_ebreak_o(exec_wb_ebreak),
        .wb_ecall_o(exec_wb_ecall),
        .wb_exception_o(exec_wb_exception),
        .wb_halt_o(exec_wb_halt),
        .wb_cause_o(exec_wb_cause),
        .wb_tval_o(exec_wb_tval),
        .wb_mret_o(exec_wb_mret),
        .wb_sret_o(exec_wb_sret),
        .forward_ex_valid_o(exec_forward_ex_valid),
        .forward_ex_rd_addr_o(exec_forward_ex_rd_addr),
        .forward_mem_valid_o(exec_forward_mem_valid),
        .forward_mem_rd_addr_o(exec_forward_mem_rd_addr),
        .trace_ex_advance_o(exec_trace_ex_advance),
        .trace_mem_valid_o(exec_trace_mem_valid),
        .trace_mem_clear_o(exec_trace_mem_clear),
        .trace_mem_id_o(exec_trace_mem_id),
        .trace_mem_pc_o(exec_trace_mem_pc),
        .trace_mem_instr_o(exec_trace_mem_instr),
        .trace_wb_id_o(exec_trace_wb_id),
        .trace_serializing_o(exec_trace_serializing),
        .trace_load_valid_o(exec_trace_load_valid),
        .trace_load_pc_o(exec_trace_load_pc),
        .trace_load_addr_o(exec_trace_load_addr),
        .trace_load_rd_o(exec_trace_load_rd),
        .trace_load_data_o(exec_trace_load_data),
        .trace_store_valid_o(exec_trace_store_valid),
        .trace_store_pc_o(exec_trace_store_pc),
        .trace_store_addr_o(exec_trace_store_addr),
        .trace_store_data_o(exec_trace_store_data),
        .trace_store_wstrb_o(exec_trace_store_wstrb),
        .flush_3p_i(1'b0),
        .squash_younger_3p_i(1'b0),
        .squash_inclusive_3p_i(1'b0),
        .squash_id_3p_i({`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .coherent_reservation_clear_3p_i(1'b0),
        .translation_bypass_3p_i(1'b0),
        .inhibit_load_speculation_3p_i(1'b0),
        .issue_valid_3p_i(
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}}),
        .issue_id_3p_i(
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .issue_slot_3p_i(
            {`OPENRV64_EXEC_PIPE_COUNT*3{1'b0}}),
        .issue_payload_3p_i(
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH{1'b0}}),
        .branch_forward_valid_3p_i(1'b0),
        .branch_forward_tag_3p_i(
            {`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .branch_forward_rd_addr_3p_i(
            {`RV64_REG_ADDR_WIDTH{1'b0}}),
        .branch_forward_data_3p_i({`RV64_XLEN{1'b0}}),
        .issue_src1_producer_valid_3p_i(
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}}),
        .issue_src1_producer_tag_3p_i(
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .issue_src2_producer_valid_3p_i(
            {`OPENRV64_EXEC_PIPE_COUNT{1'b0}}),
        .issue_src2_producer_tag_3p_i(
            {`OPENRV64_EXEC_PIPE_COUNT*
             `OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .ordered_head_valid_3p_i(1'b0),
        .ordered_head_id_3p_i(
            {`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .ordered_head_slot_3p_i(3'd0),
        .ordered_store_window_valid_3p_i(3'b000),
        .ordered_store_window_complete_3p_i(3'b000),
        .ordered_store_window_id_3p_i(
            {3*`OPENRV64_INSTR_ID_WIDTH{1'b0}}),
        .ordered_store_window_slot_3p_i(9'd0),
        .store_barrier_busy_3p_i(1'b0),
        .complete_ready_3p_i(3'b000)
    );

    // Deliberately slow PMPADDR and SATP writes have already left execute when
    // their sequencers start.  Hold retirement and younger issue until their
    // atomic commits complete.
    assign exec_wb_clear = !csr_serial_busy_q && gpr_write_ready;

    openrv64_retire u_retire (
        .valid_i(exec_wb_valid),
        .clear_i(exec_wb_clear),
        .rs1_addr_i(exec_wb_rs1_addr),
        .rs2_addr_i(exec_wb_rs2_addr),
        .reg_write_i(exec_wb_reg_write),
        .rd_addr_i(exec_wb_rd_addr),
        .release_valid_o(retire_release_valid),
        .release_uses_rs1_o(retire_release_uses_rs1),
        .release_uses_rs2_o(retire_release_uses_rs2),
        .release_rs1_addr_o(retire_release_rs1_addr),
        .release_rs2_addr_o(retire_release_rs2_addr),
        .release_reg_write_o(retire_release_reg_write),
        .release_rd_addr_o(retire_release_rd_addr)
    );

    assign wb_write = exec_wb_valid &&
                      exec_wb_reg_write &&
                      !exec_wb_exception &&
                      !halted_q;
    assign wb_rd_addr = exec_wb_rd_addr;
    assign wb_rd_data = exec_wb_data;

    assign fetch_mem_ready = fetch_bus_ready;
    assign fetch_mem_fault = fetch_bus_access_fault;
    assign fetch_mem_page_fault = fetch_bus_page_fault;
    assign exec_mem_error = exec_mem_access_fault;

    assign core_mem_ready = mem_ready;
    assign core_mem_error = mem_error;
    assign mem_valid = core_mem_valid;
    assign mem_write = core_mem_write;
    assign mem_addr = core_mem_addr;
    assign mem_wdata = core_mem_wdata;
    assign mem_wstrb = core_mem_wstrb;

    openrv64_core_bus #(
        .PIPE_GEN_MEM_4_STAGE(PIPE_1P_MEM_4_STAGE),
        .ENABLE_FETCH_PAGE_SCREEN(0),
        .ENABLE_LSU_PAGE_SCREEN(0),
        .ENABLE_L1D_COHERENCE_PROBES(1'b0),
        .ENABLE_COHERENT_ATOMICS(1'b0),
        .TLB_ENTRIES(TLB_ENTRIES),
        .PTW_PTE_CACHE_ENTRIES(PTW_PTE_CACHE_ENTRIES),
        .PTW_ICX_TIMEOUT_CYCLES(PTW_ICX_TIMEOUT_CYCLES),
        .HART_ID(HART_ID)
    ) u_core_bus (
        .clk(clk),
        .rst_n(rst_n),
        .fetch_valid_i(fetch_mem_valid),
        .fetch_cancel_i(flush_fetch),
        .fetch_addr_i(fetch_mem_exec_addr),
        .fetch_priv_i(csr_priv_mode),
        .fetch_vm_mode_i((csr_priv_mode == `RV64_PRIV_M) ?
                         `RV64_SATP_MODE_BARE : csr_satp_mode),
        .fetch_asid_i(csr_satp_asid),
        .fetch_root_ppn_i(csr_satp_root_ppn),
        .fetch_sum_i(csr_status_sum),
        .fetch_mxr_i(csr_status_mxr),
        .fetch_ready_o(fetch_bus_ready),
        .fetch_rdata_o(fetch_mem_rdata),
        .fetch_access_fault_o(fetch_bus_access_fault),
        .fetch_page_fault_o(fetch_bus_page_fault),
        .fetch_pipe_req_valid_i(1'b0),
        .fetch_pipe_req_addr_i(64'd0),
        .fetch_pipe_req_stash_i(1'b0),
        .fetch_pipe_req_demand_i(1'b0),
        .fetch_pipe_req_priv_i(`RV64_PRIV_M),
        .fetch_pipe_req_vm_mode_i(`RV64_SATP_MODE_BARE),
        .fetch_pipe_req_asid_i({`RV64_SATP_ASID_WIDTH{1'b0}}),
        .fetch_pipe_req_root_ppn_i({`RV64_SATP_PPN_WIDTH{1'b0}}),
        .fetch_pipe_req_sum_i(1'b0), .fetch_pipe_req_mxr_i(1'b0),
        .fetch_pipe_resp_ready_i(1'b0),
        .fetch_pipe_cancel_stash_i(1'b1),
        .lsu_valid_i(exec_mem_issue_valid),
        .lsu_lock_i(exec_mem_lock),
        .lsu_write_i(exec_mem_write),
        .lsu_addr_i(exec_mem_addr),
        .lsu_wdata_i(exec_mem_wdata),
        .lsu_wstrb_i(exec_mem_wstrb),
        .lsu_size_i(exec_mem_size),
        .lsu_priv_i(csr_data_priv_mode),
        .lsu_vm_mode_i((csr_data_priv_mode == `RV64_PRIV_M) ?
                       `RV64_SATP_MODE_BARE : csr_satp_mode),
        .lsu_asid_i(csr_satp_asid),
        .lsu_root_ppn_i(csr_satp_root_ppn),
        .lsu_sum_i(csr_status_sum),
        .lsu_mxr_i(csr_status_mxr),
        .lsu_ready_o(exec_mem_bus_ready),
        .lsu_rdata_o(exec_mem_rdata),
        .lsu_access_fault_o(exec_mem_access_fault),
        .lsu_page_fault_o(exec_mem_page_fault),
        .lsu_pipe_req_valid_i(1'b0),
        .lsu_pipe_req_tag_i({`OPENRV64_LSU_TAG_WIDTH{1'b0}}),
        .lsu_pipe_req_xlate_only_i(1'b0),
        .lsu_pipe_req_physical_i(1'b0),
        .lsu_pipe_req_pmp_checked_i(1'b0),
        .lsu_pipe_req_lock_i(1'b0),
        .lsu_pipe_req_write_i(1'b0), .lsu_pipe_req_addr_i(64'd0),
        .lsu_pipe_req_wdata_i(64'd0), .lsu_pipe_req_wstrb_i(8'd0),
        .lsu_pipe_req_size_i(3'd0),
        .lsu_pipe_req_priv_i(`RV64_PRIV_M),
        .lsu_pipe_req_vm_mode_i(`RV64_SATP_MODE_BARE),
        .lsu_pipe_req_asid_i({`RV64_SATP_ASID_WIDTH{1'b0}}),
        .lsu_pipe_req_root_ppn_i({`RV64_SATP_PPN_WIDTH{1'b0}}),
        .lsu_pipe_req_sum_i(1'b0), .lsu_pipe_req_mxr_i(1'b0),
        .lsu_pipe_req_translation_hit_o(),
        .lsu_pipe_req_translation_paddr_o(),
        .lsu_pipe_req_translation_page_fault_o(),
        .lsu_pipe_cancel_i(1'b0), .lsu_pipe_resp_ready_i(1'b0),
        .lsu_pipe_store_done_ready_i(1'b1),
        .lsu_xlate_req_valid_i(1'b0),
        .lsu_xlate_req_tag_i(
            {`OPENRV64_LSU_XLATE_TAG_WIDTH{1'b0}}),
        .lsu_xlate_req_write_i(1'b0),
        .lsu_xlate_req_size_i(3'd0),
        .lsu_xlate_req_vaddr_i(64'd0),
        .lsu_xlate_req_priv_i(`RV64_PRIV_M),
        .lsu_xlate_req_vm_mode_i(`RV64_SATP_MODE_BARE),
        .lsu_xlate_req_asid_i({`RV64_SATP_ASID_WIDTH{1'b0}}),
        .lsu_xlate_req_root_ppn_i({`RV64_SATP_PPN_WIDTH{1'b0}}),
        .lsu_xlate_req_sum_i(1'b0),
        .lsu_xlate_req_mxr_i(1'b0),
        .lsu_xlate_resp_ready_i(1'b1),
        // All 1P translation-context changes use one fixed local sequence:
        // retirement latches the request, the following cycle invalidates the
        // TLB/PTW state, one inhibited restart cycle follows, then issue may
        // resume.  There is no coherent ICX shootdown in this bus mode.
        .tlbi_i(translation_invalidate_q),
        .context_flush_i(1'b0),
        .fetch_context_change_i(1'b0),
        .page_screen_csr_clear_i(1'b0),
        .pmp_update_i(pmp_invalidate_q),
        .tlbi_busy_o(translation_barrier_busy),
        .store_barrier_i(1'b0),
        .icache_invalidate_i(icache_invalidate_q),
        .icache_prefetch_valid_i(1'b0),
        .icache_prefetch_taken_addr_i(64'd0),
        .icache_prefetch_fallthrough_addr_i(64'd0),
        .icache_age_valid_i(3'b000),
        .icache_age_addr_i(192'd0),
        .l1d_probe_valid_i(1'b0),
        .l1d_probe_ready_o(),
        .l1d_probe_addr_i(64'd0),
        .l1d_sleep_i(wfi_sleep_q),
        .l1d_probe_hit_o(),
        .req_valid_o(core_mem_valid),
        .req_ready_i(core_mem_ready),
        .req_write_o(core_mem_write),
        .req_addr_o(core_mem_addr),
        .req_pmp_addr_o(core_mem_pmp_addr),
        .req_priv_o(core_mem_priv),
        .req_size_o(core_mem_size),
        .req_exec_o(core_mem_exec),
        .req_wdata_o(core_mem_wdata),
        .req_wstrb_o(core_mem_wstrb),
        .req_rdata_i(mem_rdata),
        .req_error_i(core_mem_error),
        .fetch_next_valid_i(fetch_mem_next_valid),
        .fetch_next_addr_i(pc_q),
        .debug_gen_pipe_event_valid_o(debug_gen_pipe_event_valid),
        .debug_gen_pipe_event_stage_o(debug_gen_pipe_event_stage),
        .debug_gen_pipe_event_addr_o(debug_gen_pipe_event_addr),
        .debug_gen_pipe_event_data_o(debug_gen_pipe_event_data),
        .debug_gen_pipe_cancel_now_o(debug_gen_pipe_cancel_now),
        .debug_gen_pipe_cancelled_o(debug_gen_pipe_cancelled),
        .debug_gen_state_o(debug_gen_state),
        .debug_gen_owner_fetch_o(debug_gen_owner_fetch),
        .debug_gen_pipe_vaddr_o(debug_gen_pipe_vaddr),
        .pmp_valid_o(core_pmp_valid), .pmp_addr_o(core_pmp_addr),
        .pmp_priv_o(core_pmp_priv), .pmp_size_o(core_pmp_size),
        .pmp_write_o(core_pmp_write), .pmp_exec_o(core_pmp_exec),
        .pmp_allow_i(csr_pmp_bus_allow),
        .icx_req_valid_o(icx_req_valid),
        .icx_req_ready_i(icx_req_ready),
        .icx_req_hart_id_o(icx_req_hart_id),
        .icx_req_txn_id_o(icx_req_txn_id),
        .icx_req_source_id_o(icx_req_source_id),
        .icx_req_op_o(icx_req_op),
        .icx_req_lock_o(icx_req_lock),
        .icx_req_order_o(icx_req_order),
        .icx_req_kind_o(icx_req_kind),
        .icx_req_attr_o(icx_req_attr),
        .icx_req_size_o(icx_req_size),
        .icx_req_addr_o(icx_req_addr),
        .icx_req_burst_len_o(icx_req_burst_len),
        .icx_wdata_valid_o(icx_wdata_valid),
        .icx_wdata_ready_i(icx_wdata_ready),
        .icx_wdata_hart_id_o(icx_wdata_hart_id),
        .icx_wdata_txn_id_o(icx_wdata_txn_id),
        .icx_wdata_source_id_o(icx_wdata_source_id),
        .icx_wdata_beat_index_o(icx_wdata_beat_index),
        .icx_wdata_last_o(icx_wdata_last),
        .icx_wdata_o(icx_wdata),
        .icx_wstrb_o(icx_wstrb),
        .icx_resp_valid_i(icx_resp_valid),
        .icx_resp_ready_o(icx_resp_ready),
        .icx_resp_hart_id_i(icx_resp_hart_id),
        .icx_resp_txn_id_i(icx_resp_txn_id),
        .icx_resp_source_id_i(icx_resp_source_id),
        .icx_resp_beat_index_i(icx_resp_beat_index),
        .icx_resp_last_i(icx_resp_last),
        .icx_resp_rdata_i(icx_resp_rdata),
        .icx_resp_error_i(icx_resp_error),
        .icx_resp_sc_success_i(icx_resp_sc_success),
        .m_axi_arready_i(1'b0),
        .m_axi_rid_i({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
        .m_axi_rdata_i({`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
        .m_axi_rresp_i(2'd0), .m_axi_rlast_i(1'b0),
        .m_axi_rvalid_i(1'b0), .m_axi_awready_i(1'b0),
        .m_axi_wready_i(1'b0),
        .m_axi_bid_i({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
        .m_axi_bresp_i(2'd0), .m_axi_bvalid_i(1'b0)
    );

    assign exec_mem_ready =
        exec_mem_bus_ready && !translation_barrier_busy;

    assign dbg_pc = dbg_pc_q;
    assign dbg_instr = dbg_instr_q;
    assign dbg_rs1_data = dbg_rs1_data_q;
    assign dbg_rs2_data = dbg_rs2_data_q;
    assign dbg_halted = halted_q;
    assign wfi_sleep_o = wfi_sleep_q;

    // Trace slot order is fixed: 0=IF, 1=ID, 2=EX, 3=MEM, 4=WB.
    // Each packed vector uses the stage number as its element index, so the
    // IF element occupies the least-significant slice.
    wire trace_if_valid = fetch_mem_valid || fetch_decode_valid;
    wire [`RV64_XLEN-1:0] trace_if_pc = fetch_decode_valid ?
        unused_fetch_decode_pc : fetch_mem_exec_addr;
    wire [`RV64_INSTR_WIDTH-1:0] trace_if_instr = fetch_decode_valid ?
        unused_fetch_decode_instr : {`RV64_INSTR_WIDTH{1'b0}};
    wire trace_if_advance = fetch_decode_valid ? fetch_decode_clear :
                            (fetch_mem_valid && fetch_mem_ready);
    wire trace_id_advance = if_id_out_valid && if_id_out_clear;
    wire trace_mem_advance = exec_trace_mem_valid && exec_trace_mem_clear;
    wire [4:0] trace_valid_raw = {
        exec_wb_valid,
        exec_trace_mem_valid,
        dispatch_exec_valid,
        if_id_out_valid,
        trace_if_valid
    };
    wire [4:0] trace_advance_raw = {
        retire_accept,
        trace_mem_advance,
        exec_trace_ex_advance,
        trace_id_advance,
        trace_if_advance
    };
    wire [4:0] trace_flush_raw = {
        flush_mem_wb,
        flush_ex_mem,
        flush_id_ex,
        flush_if_id,
        flush_fetch && !fetch_redirect_replay
    };
    wire [4:0] trace_stall_raw = trace_valid_raw &
                                  ~trace_advance_raw &
                                  ~trace_flush_raw;
    wire [7:0] trace_events_raw;
    wire [7:0] trace_stall_causes_raw;

    assign trace_events_raw[`OPENRV64_TRACE_EVENT_REDIRECT] =
        hard_flush_redirect_req || bp_predict_redirect;
    assign trace_events_raw[`OPENRV64_TRACE_EVENT_TRAP] =
        hard_flush_trap_req;
    assign trace_events_raw[`OPENRV64_TRACE_EVENT_IRQ] =
        hard_flush_irq_req;
    assign trace_events_raw[`OPENRV64_TRACE_EVENT_MRET] =
        hard_flush_mret_req;
    assign trace_events_raw[`OPENRV64_TRACE_EVENT_SRET] =
        hard_flush_sret_req;
    assign trace_events_raw[`OPENRV64_TRACE_EVENT_RESTART] =
        hard_flush_restart_req;
    assign trace_events_raw[`OPENRV64_TRACE_EVENT_HALT] =
        retire_accept && exec_wb_halt;
    assign trace_events_raw[`OPENRV64_TRACE_EVENT_RESET] = reset_pending_q;

    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_RAW] =
        trace_stall_raw[`OPENRV64_TRACE_STAGE_ID] &&
        dispatch_raw_hazard;
    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_WAW] =
        trace_stall_raw[`OPENRV64_TRACE_STAGE_ID] &&
        dispatch_waw_hazard;
    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_SCOREBOARD] =
        trace_stall_raw[`OPENRV64_TRACE_STAGE_ID] &&
        dispatch_scoreboard_stall;
    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_IF_MEMORY] =
        trace_stall_raw[`OPENRV64_TRACE_STAGE_IF] &&
        !fetch_decode_valid &&
        fetch_mem_valid && !fetch_mem_ready;
    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_DATA_MEMORY] =
        trace_stall_raw[`OPENRV64_TRACE_STAGE_MEM] &&
        exec_mem_valid && !exec_mem_ready;
    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_EXECUTE] =
        trace_stall_raw[`OPENRV64_TRACE_STAGE_EX] &&
        dispatch_exec_valid && !exec_clear;
    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_FRONTEND_HELD] =
        trace_stall_raw[`OPENRV64_TRACE_STAGE_IF] &&
        fetch_decode_valid && !fetch_decode_clear;
    assign trace_stall_causes_raw[`OPENRV64_TRACE_STALL_SERIALIZING] =
        (trace_stall_raw[`OPENRV64_TRACE_STAGE_ID] ||
         trace_stall_raw[`OPENRV64_TRACE_STAGE_EX]) &&
        exec_trace_serializing;

    assign trace_cycle = ENABLE_TRACE ? trace_cycle_q : 64'd0;
    assign trace_valid = ENABLE_TRACE ? trace_valid_raw : 5'd0;
    assign trace_stall = ENABLE_TRACE ? trace_stall_raw : 5'd0;
    assign trace_flush = ENABLE_TRACE ? trace_flush_raw : 5'd0;
    assign trace_advance = ENABLE_TRACE ? trace_advance_raw : 5'd0;
    assign trace_ids = ENABLE_TRACE ? {
        exec_wb_valid ? exec_trace_wb_id : 64'd0,
        exec_trace_mem_valid ? exec_trace_mem_id : 64'd0,
        dispatch_exec_valid ? dispatch_exec_trace_id : 64'd0,
        if_id_out_valid ? if_id_trace_id : 64'd0,
        trace_if_valid ? fetch_trace_id : 64'd0
    } : 320'd0;
    assign trace_pcs = ENABLE_TRACE ? {
        exec_wb_valid ? exec_wb_pc : 64'd0,
        exec_trace_mem_valid ? exec_trace_mem_pc : 64'd0,
        dispatch_exec_valid ? dispatch_exec_pc : 64'd0,
        if_id_out_valid ? if_id_pc : 64'd0,
        trace_if_valid ? trace_if_pc : 64'd0
    } : 320'd0;
    assign trace_instrs = ENABLE_TRACE ? {
        exec_wb_valid ? exec_wb_instr : 32'd0,
        exec_trace_mem_valid ? exec_trace_mem_instr : 32'd0,
        dispatch_exec_valid ? dispatch_exec_instr : 32'd0,
        if_id_out_valid ? if_id_instr : 32'd0,
        trace_if_valid ? trace_if_instr : 32'd0
    } : 160'd0;
    assign trace_events = ENABLE_TRACE ? trace_events_raw : 8'd0;
    assign trace_stall_causes = ENABLE_TRACE ? trace_stall_causes_raw : 8'd0;
    assign trace_retire_valid = ENABLE_TRACE && retire_accept;
    assign trace_retire_arch = ENABLE_TRACE && retire_arch;
    assign trace_retire_exception = ENABLE_TRACE && retire_exception;
    assign trace_retire_cause = ENABLE_TRACE ? exec_wb_cause :
                                {`RV64_EXCEPT_CAUSE_WIDTH{1'b0}};
    assign trace_retire_next_pc = ENABLE_TRACE ? exec_wb_next_pc : 64'd0;
    assign trace_retire_rd_write = ENABLE_TRACE && retire_arch &&
                                   exec_wb_reg_write &&
                                   (exec_wb_rd_addr != `RV64_REG_X0);
    assign trace_retire_rd = ENABLE_TRACE ? exec_wb_rd_addr :
                             {`RV64_REG_ADDR_WIDTH{1'b0}};
    assign trace_retire_wdata = ENABLE_TRACE ? exec_wb_data : 64'd0;
    // Capture the exact fetch response accepted by the fetch unit.  The
    // execution address is the request's virtual PC; rdata is the complete
    // 64-bit bus response presented on the same completion edge.
    assign trace_fetch_valid = ENABLE_TRACE &&
        (flush_fetch || debug_gen_pipe_event_valid ||
         (fetch_mem_valid && fetch_mem_ready));
    // Debug pipeline records are self-identifying: b055 in bits 63:48,
    // current/latched cancellation in bits 47:46, stage in bits 45:44,
    // and an address in bits 43:0. Stages 0..2 report the physical request;
    // stage 3 reports the gen-bus logical address at the response handoff.
    // They share the existing fetch ring only in large-trace FPGA builds.
    assign trace_fetch_pc = ENABLE_TRACE ?
        (flush_fetch ?
         {16'hb057, debug_gen_state, debug_gen_owner_fetch,
          debug_gen_pipe_cancelled, debug_gen_pipe_vaddr[43:0]} :
         debug_gen_pipe_event_valid ?
         {16'hb055, debug_gen_pipe_cancel_now, debug_gen_pipe_cancelled,
          debug_gen_pipe_event_stage,
          (debug_gen_pipe_event_stage == 2'd3 ?
           debug_gen_pipe_vaddr[43:0] : debug_gen_pipe_event_addr[43:0])} :
         fetch_mem_exec_addr) : 64'd0;
    assign trace_fetch_data = ENABLE_TRACE ?
        (flush_fetch ? fetch_mem_exec_addr :
         debug_gen_pipe_event_valid ? debug_gen_pipe_event_data :
                                      fetch_mem_rdata) : 64'd0;
    assign trace_load_valid = ENABLE_TRACE && exec_trace_load_valid;
    assign trace_load_pc = ENABLE_TRACE ? exec_trace_load_pc : 64'd0;
    assign trace_load_addr = ENABLE_TRACE ? exec_trace_load_addr : 64'd0;
    assign trace_load_rd = ENABLE_TRACE ? exec_trace_load_rd :
                           {`RV64_REG_ADDR_WIDTH{1'b0}};
    assign trace_load_data = ENABLE_TRACE ? exec_trace_load_data : 64'd0;
    assign trace_store_valid = ENABLE_TRACE && exec_trace_store_valid;
    assign trace_store_pc = ENABLE_TRACE ? exec_trace_store_pc : 64'd0;
    assign trace_store_addr = ENABLE_TRACE ? exec_trace_store_addr : 64'd0;
    assign trace_store_data = ENABLE_TRACE ? exec_trace_store_data : 64'd0;
    assign trace_store_wstrb = ENABLE_TRACE ? exec_trace_store_wstrb : 8'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_serial_busy_q <= 1'b0;
            restart_fetch_q <= 1'b0;
            global_issue_inhibit_q <= 1'b0;
            debug_serial_inflight_q <= 1'b0;
            debug_serial_retired_q <= 1'b0;
            serial_control_inflight_q <= 1'b0;
            store_inflight_q <= 1'b0;
            sfence_vma_inflight_q <= 1'b0;
            satp_write_inflight_q <= 1'b0;
            pmp_write_inflight_q <= 1'b0;
            translation_invalidate_q <= 1'b0;
            icache_invalidate_q <= 1'b0;
            pmp_invalidate_q <= 1'b0;
        end else begin
            csr_serial_busy_q <= csr_serial_busy_raw;
            restart_fetch_q <= restart_fetch_req;
            // Latch each maintenance kind at retirement.  All kinds share
            // the issue-inhibit, one-cycle invalidation, and following-cycle
            // fetch-restart sequence.
            translation_invalidate_q <= retire_translation_fence;
            icache_invalidate_q <= retire_fence_i;
            pmp_invalidate_q <= retire_pmp_write;
            global_issue_inhibit_q <= issue_inhibit_latch_set ||
                issue_inhibit_immediate ||
                (global_issue_inhibit_q && issue_inhibit_owner_active);
            if (DEBUG_SERIALIZE_ALL_1P) begin
                // A WB payload may remain valid after its first acceptance.
                // Do not release younger issue on retire_accept itself: wait
                // until the accepted payload has visibly left WB, creating a
                // complete empty boundary between debug-serialized
                // instructions.
                if (instruction_issue_fire) begin
                    debug_serial_inflight_q <= 1'b1;
                    debug_serial_retired_q <= 1'b0;
                end else if (debug_serial_inflight_q) begin
                    if (retire_accept)
                        debug_serial_retired_q <= 1'b1;
                    if (debug_serial_retired_q && !exec_wb_valid) begin
                        debug_serial_inflight_q <= 1'b0;
                        debug_serial_retired_q <= 1'b0;
                    end
                end else begin
                    debug_serial_retired_q <= 1'b0;
                end
            end else begin
                debug_serial_inflight_q <= 1'b0;
                debug_serial_retired_q <= 1'b0;
            end
            if (retire_accept) begin
                serial_control_inflight_q <= 1'b0;
                sfence_vma_inflight_q <= 1'b0;
                satp_write_inflight_q <= 1'b0;
                pmp_write_inflight_q <= 1'b0;
            end
            if (store_memory_complete || flush_ex_mem)
                store_inflight_q <= 1'b0;
            if (serial_control_issue)
                serial_control_inflight_q <= 1'b1;
            if (store_issue)
                store_inflight_q <= 1'b1;
            if (sfence_vma_issue)
                sfence_vma_inflight_q <= 1'b1;
            if (satp_write_issue)
                satp_write_inflight_q <= 1'b1;
            if (pmp_write_issue)
                pmp_write_inflight_q <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && sfence_vma_issue && satp_write_issue)
            $fatal(1, "one instruction classified as SFENCE.VMA and SATP write");
        if (rst_n &&
            (serial_control_inflight_q || store_inflight_q) &&
            dispatch_exec_issue_valid)
            $fatal(1, "younger issue escaped owned issue inhibit");
        if (rst_n && translation_invalidate_q &&
            !global_issue_inhibit_q)
            $fatal(1, "translation invalidation lost serial issue ownership");
        if (rst_n && icache_invalidate_q &&
            !global_issue_inhibit_q)
            $fatal(1, "instruction-cache invalidation lost serial issue ownership");
        if (rst_n && pmp_invalidate_q &&
            !global_issue_inhibit_q)
            $fatal(1, "PMP invalidation lost serial issue ownership");
        if (rst_n && maintenance_invalidate_active && invalidate_fetch)
            $fatal(1, "maintenance invalidation and fetch restart overlapped");
    end
`endif

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            redirect_pending_q <= 1'b0;
            redirect_direction_pending_q <= 1'b0;
            redirect_target_mispredict_pending_q <= 1'b0;
            redirect_target_q <= {`RV64_XLEN{1'b0}};
        end else begin
            if (DEBUG_SERIALIZE_ALL_1P) begin
                if (redirect_pending_q && debug_serial_issue_block)
                    redirect_pending_q <= 1'b1;
                else
                    redirect_pending_q <= redirect_capture_req;
                if (redirect_capture_req) begin
                    redirect_direction_pending_q <= exec_redirect_valid;
                    redirect_target_mispredict_pending_q <=
                        bp_target_mispredict;
                    redirect_target_q <= exec_redirect_target;
                end else if (hard_flush_redirect_req) begin
                    redirect_direction_pending_q <= 1'b0;
                    redirect_target_mispredict_pending_q <= 1'b0;
                end
            end else begin
                redirect_pending_q <= redirect_capture_req;
                redirect_direction_pending_q <= exec_redirect_valid &&
                                                !control_event_inhibit;
                redirect_target_mispredict_pending_q <=
                    bp_target_mispredict && !control_event_inhibit;
                // Avoid making the correction decision a 64-way clock enable.
                // The target is ignored unless redirect_pending_q is asserted.
                redirect_target_q <= exec_redirect_target;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trace_cycle_q <= 64'd0;
            trace_next_id_q <= 64'd1;
        end else if (ENABLE_TRACE) begin
            trace_cycle_q <= trace_cycle_q + 64'd1;

            if (fetch_pc_valid) begin
                trace_next_id_q <= trace_next_id_q +
                                   (pc_q[2] ? 64'd1 : 64'd2);
            end else if (fetch_redirect_replay) begin
                trace_next_id_q <= trace_next_id_q +
                                   (bp_predict_target[2] ? 64'd1 : 64'd2);
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_q           <= {`RV64_XLEN{1'b0}};
            dbg_pc_q       <= {`RV64_XLEN{1'b0}};
            dbg_instr_q    <= `RV64_INSTR_NOP;
            dbg_rs1_data_q <= {`RV64_XLEN{1'b0}};
            dbg_rs2_data_q <= {`RV64_XLEN{1'b0}};
            halted_q       <= 1'b0;
            wfi_sleep_q    <= 1'b0;
            halt_pending_q <= 1'b0;
            reset_pending_q <= 1'b1;
        end else begin
            if (wfi_sleep_q) begin
                if (csr_wfi_wake)
                    wfi_sleep_q <= 1'b0;
            end else if (retire_wfi && !csr_wfi_wake) begin
                wfi_sleep_q <= 1'b1;
            end
            if (except_vector_valid) begin
                pc_q <= except_vector_target;
            end else if (bp_predict_redirect) begin
                pc_q <= fetch_redirect_replay ?
                        bp_predict_target +
                        (bp_predict_target[2] ? 64'd4 : 64'd8) :
                        bp_predict_target;
            end else if (fetch_pc_valid) begin
                // A line-aligned request supplies two 32-bit instructions.  A
                // redirect into the upper half consumes only that half before
                // advancing to the next aligned line.
                pc_q <= pc_q + (pc_q[2] ? 64'd4 : 64'd8);
            end

            if (hard_flush_req) begin
                halt_pending_q <= 1'b0;
            end else if (decode_ebreak_accept) begin
                halt_pending_q <= 1'b1;
            end

            if (reset_pending_q) begin
                reset_pending_q <= 1'b0;
                dbg_pc_q        <= except_vector_target;
            end

            if (exec_wb_valid) begin
                dbg_pc_q    <= exec_wb_pc;
                dbg_instr_q <= exec_wb_instr;
                dbg_rs1_data_q <= exec_wb_rs1_data;
                dbg_rs2_data_q <= exec_wb_rs2_data;

                if (exec_wb_halt) begin
                    halted_q       <= 1'b1;
                    halt_pending_q <= 1'b0;
                end
            end
        end
    end

endmodule
