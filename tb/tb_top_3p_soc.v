`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/exec/bp/defs.v"
`include "soc/bus/mem_map.v"
`include "complex/protocol/defs.v"
`include "complex/bus/defs.v"

// Burst-capable 256-bit AXI SRAM used behind the production CCX/L2 hierarchy.
// The 16 MiB aperture is sparse in Verilator so the generated model does not
// materialize half a million empty 256-bit words.
module tb_axi256_burst_sram #(
    parameter integer RAM_BYTES = 16 * 1024 * 1024
) (
    input  wire clk_i,
    input  wire rst_ni,

    input  wire [`OPENRV64_AXI_ID_WIDTH-1:0] arid_i,
    input  wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] araddr_i,
    input  wire [7:0] arlen_i,
    input  wire [2:0] arsize_i,
    input  wire [1:0] arburst_i,
    input  wire arvalid_i,
    output wire arready_o,
    output wire [`OPENRV64_AXI_ID_WIDTH-1:0] rid_o,
    output wire [`OPENRV64_AXI_DATA_WIDTH-1:0] rdata_o,
    output wire [1:0] rresp_o,
    output wire rlast_o,
    output wire rvalid_o,
    input  wire rready_i,

    input  wire [`OPENRV64_AXI_ID_WIDTH-1:0] awid_i,
    input  wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] awaddr_i,
    input  wire [7:0] awlen_i,
    input  wire [2:0] awsize_i,
    input  wire [1:0] awburst_i,
    input  wire awvalid_i,
    output wire awready_o,
    input  wire [`OPENRV64_AXI_DATA_WIDTH-1:0] wdata_i,
    input  wire [`OPENRV64_AXI_STRB_WIDTH-1:0] wstrb_i,
    input  wire wlast_i,
    input  wire wvalid_i,
    output wire wready_o,
    output wire [`OPENRV64_AXI_ID_WIDTH-1:0] bid_o,
    output wire [1:0] bresp_o,
    output wire bvalid_o,
    input  wire bready_i
);
    localparam [63:0] RAM_BASE = `OPENRV64_SOC_MEMORY_BASE;
    localparam integer AXI_BYTES = `OPENRV64_AXI_DATA_WIDTH / 8;

    reg [`OPENRV64_AXI_DATA_WIDTH-1:0] ram_q [longint unsigned];

    reg read_active_q;
    reg [`OPENRV64_AXI_ID_WIDTH-1:0] read_id_q;
    reg [63:0] read_addr_q;
    reg [8:0] read_beats_q;
    reg [2:0] read_size_q;
    reg [`OPENRV64_AXI_ID_WIDTH-1:0] rid_q;
    reg [`OPENRV64_AXI_DATA_WIDTH-1:0] rdata_q;
    reg [1:0] rresp_q;
    reg rlast_q;
    reg rvalid_q;

    reg write_active_q;
    reg [`OPENRV64_AXI_ID_WIDTH-1:0] write_id_q;
    reg [63:0] write_addr_q;
    reg [8:0] write_beats_q;
    reg [2:0] write_size_q;
    reg write_error_q;
    reg [`OPENRV64_AXI_ID_WIDTH-1:0] bid_q;
    reg [1:0] bresp_q;
    reg bvalid_q;

    integer read_transactions;
    integer read_beats;
    integer write_transactions;
    integer write_beats;
    integer write_byte;
    reg [`OPENRV64_AXI_DATA_WIDTH-1:0] merged_write;

    wire ar_fire = arvalid_i && arready_o;
    wire r_fire = rvalid_o && rready_i;
    wire aw_fire = awvalid_i && awready_o;
    wire w_fire = wvalid_i && wready_o;
    wire b_fire = bvalid_o && bready_i;

    function automatic in_range;
        input [63:0] addr;
        begin
            in_range = (addr >= RAM_BASE) &&
                       (addr < (RAM_BASE + RAM_BYTES));
        end
    endfunction

    function automatic longint unsigned word_index;
        input [63:0] addr;
        begin
            word_index = (addr - RAM_BASE) >> $clog2(AXI_BYTES);
        end
    endfunction

    function automatic [`OPENRV64_AXI_DATA_WIDTH-1:0] read_word;
        input [63:0] addr;
        longint unsigned index;
        begin
            index = word_index(addr);
            if (in_range(addr) && ram_q.exists(index))
                read_word = ram_q[index];
            else
                read_word = {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
        end
    endfunction

    assign arready_o = rst_ni && !read_active_q;
    assign rid_o = rid_q;
    assign rdata_o = rdata_q;
    assign rresp_o = rresp_q;
    assign rlast_o = rlast_q;
    assign rvalid_o = rvalid_q;
    assign awready_o = rst_ni && !write_active_q && !bvalid_q;
    assign wready_o = rst_ni && write_active_q && !bvalid_q;
    assign bid_o = bid_q;
    assign bresp_o = bresp_q;
    assign bvalid_o = bvalid_q;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_active_q <= 1'b0;
            read_id_q <= 0;
            read_addr_q <= 0;
            read_beats_q <= 0;
            read_size_q <= 0;
            rid_q <= 0;
            rdata_q <= 0;
            rresp_q <= 2'b00;
            rlast_q <= 1'b0;
            rvalid_q <= 1'b0;
            write_active_q <= 1'b0;
            write_id_q <= 0;
            write_addr_q <= 0;
            write_beats_q <= 0;
            write_size_q <= 0;
            write_error_q <= 1'b0;
            bid_q <= 0;
            bresp_q <= 2'b00;
            bvalid_q <= 1'b0;
            read_transactions <= 0;
            read_beats <= 0;
            write_transactions <= 0;
            write_beats <= 0;
        end else begin
            if (r_fire)
                rvalid_q <= 1'b0;
            if (b_fire)
                bvalid_q <= 1'b0;

            if (ar_fire) begin
                if (arburst_i != 2'b01)
                    $fatal(1, "full-CCX SRAM requires AXI INCR reads");
                if (arsize_i > $clog2(AXI_BYTES))
                    $fatal(1, "full-CCX SRAM read beat is too wide");
                read_active_q <= 1'b1;
                read_id_q <= arid_i;
                read_addr_q <= araddr_i;
                read_beats_q <= {1'b0, arlen_i} + 1'b1;
                read_size_q <= arsize_i;
                read_transactions <= read_transactions + 1;
            end

            if (read_active_q && (!rvalid_q || rready_i)) begin
                rid_q <= read_id_q;
                rdata_q <= read_word(read_addr_q);
                rresp_q <= in_range(read_addr_q) ? 2'b00 : 2'b10;
                rlast_q <= (read_beats_q == 1);
                rvalid_q <= 1'b1;
                read_beats <= read_beats + 1;
                if (read_beats_q == 1) begin
                    read_active_q <= 1'b0;
                    read_beats_q <= 0;
                end else begin
                    read_addr_q <= read_addr_q +
                        (64'd1 << read_size_q);
                    read_beats_q <= read_beats_q - 1'b1;
                end
            end

            if (aw_fire) begin
                if (awburst_i != 2'b01)
                    $fatal(1, "full-CCX SRAM requires AXI INCR writes");
                if (awsize_i > $clog2(AXI_BYTES))
                    $fatal(1, "full-CCX SRAM write beat is too wide");
                write_active_q <= 1'b1;
                write_id_q <= awid_i;
                write_addr_q <= awaddr_i;
                write_beats_q <= {1'b0, awlen_i} + 1'b1;
                write_size_q <= awsize_i;
                write_error_q <= 1'b0;
                write_transactions <= write_transactions + 1;
            end

            if (w_fire) begin
                if (wlast_i != (write_beats_q == 1))
                    $fatal(1, "full-CCX SRAM observed malformed WLAST");
                merged_write = read_word(write_addr_q);
                for (write_byte = 0;
                     write_byte < `OPENRV64_AXI_STRB_WIDTH;
                     write_byte = write_byte + 1) begin
                    if (wstrb_i[write_byte])
                        merged_write[write_byte*8 +: 8] =
                            wdata_i[write_byte*8 +: 8];
                end
                if (in_range(write_addr_q))
                    ram_q[word_index(write_addr_q)] = merged_write;
                else
                    write_error_q <= 1'b1;
                write_beats <= write_beats + 1;
                if (write_beats_q == 1) begin
                    write_active_q <= 1'b0;
                    write_beats_q <= 0;
                    bid_q <= write_id_q;
                    bresp_q <= (write_error_q ||
                                !in_range(write_addr_q)) ?
                               2'b10 : 2'b00;
                    bvalid_q <= 1'b1;
                end else begin
                    write_addr_q <= write_addr_q +
                        (64'd1 << write_size_q);
                    write_beats_q <= write_beats_q - 1'b1;
                end
            end
        end
    end
endmodule

// Performance harness:
//   3P core + private L1I/L1D -> native one-hart CCX -> shared L2
//       -> 512-to-256-bit generic bus adapter -> 16 MiB AXI SRAM.
module tb_top_3p_soc #(
    parameter integer FETCH_ALT_LOOKASIDE = 3,
    parameter integer FETCH_ALT_CONFIDENCE_GATE = 0,
    parameter integer FETCH_ALT_PAIR_STACK_DEPTH = 2,
    parameter [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE =
        `OPENRV64_BP_GSHARE_BTB,
    parameter [2:0] COMPLETION_FORWARD_MASK = 3'b000,
    parameter [2:0] BRANCH_COMPLETION_FORWARD_MASK = 3'b001,
    parameter integer ENABLE_FULL_FORWARDING = 0,
    parameter integer RELAX_WAW = 1,
    parameter integer RELAX_HAZARDS = 0,
    parameter integer ISSUE_WINDOW = 0,
    parameter integer SPECULATION_WINDOW = 0,
    parameter integer RAM_BYTES = 16 * 1024 * 1024,
    parameter integer L1I_CACHE_BYTES = 16 * 1024,
    parameter integer L1D_CACHE_BYTES = 16 * 1024,
    parameter integer L2_BYTES = 256 * 1024,
    parameter integer L2_WAYS = 8,
    parameter integer L1D_PREFETCH_ENABLE = 1,
    parameter integer L1D_PREFETCH_STREAMS = 2,
    parameter integer L1D_PREFETCH_ADAPTIVE_ENABLE = 1,
    parameter integer L1D_PREFETCH_MAX_DISTANCE = 4,
    parameter integer L1D_PREFETCH_QUEUE_LINES = 4,
    parameter integer L1D_PREFETCH_OUTSTANDING = 4,
    parameter integer L1D_PREFETCH_DEMAND_RESERVE = 2
);
    reg clk;
    reg rst_n;

    wire core_axi_arvalid;
    wire core_axi_awvalid;
    wire core_axi_wvalid;

    wire ccx_req_valid;
    wire ccx_req_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_req_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_req_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source_id;
    wire [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op;
    wire ccx_req_lock;
    wire [`OPENRV64_CCX_ORDER_WIDTH-1:0] ccx_req_order;
    wire [`OPENRV64_CCX_KIND_WIDTH-1:0] ccx_req_kind;
    wire [`OPENRV64_CCX_ATTR_WIDTH-1:0] ccx_req_attr;
    wire [2:0] ccx_req_size;
    wire [63:0] ccx_req_addr;
    wire [`OPENRV64_CCX_BURST_LEN_WIDTH-1:0] ccx_req_burst_len;
    wire ccx_wdata_valid;
    wire ccx_wdata_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_wdata_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_wdata_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_wdata_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_wdata_beat_index;
    wire ccx_wdata_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_wdata;
    wire [`OPENRV64_CCX_LINE_STRB_WIDTH-1:0] ccx_wstrb;
    wire ccx_resp_valid;
    wire ccx_resp_ready;
    wire [`OPENRV64_CCX_HART_ID_WIDTH-1:0] ccx_resp_hart_id;
    wire [`OPENRV64_CCX_TXN_ID_WIDTH-1:0] ccx_resp_txn_id;
    wire [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_resp_source_id;
    wire [`OPENRV64_CCX_BEAT_INDEX_WIDTH-1:0] ccx_resp_beat_index;
    wire ccx_resp_last;
    wire [`OPENRV64_CCX_LINE_DATA_WIDTH-1:0] ccx_resp_rdata;
    wire ccx_resp_error;
    wire ccx_resp_sc_success;

    wire [`OPENRV64_AXI_ID_WIDTH-1:0] ram_arid;
    wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] ram_araddr;
    wire [7:0] ram_arlen;
    wire [2:0] ram_arsize;
    wire [1:0] ram_arburst;
    wire ram_arvalid;
    wire ram_arready;
    wire [`OPENRV64_AXI_ID_WIDTH-1:0] ram_rid;
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] ram_rdata;
    wire [1:0] ram_rresp;
    wire ram_rlast;
    wire ram_rvalid;
    wire ram_rready;
    wire [`OPENRV64_AXI_ID_WIDTH-1:0] ram_awid;
    wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] ram_awaddr;
    wire [7:0] ram_awlen;
    wire [2:0] ram_awsize;
    wire [1:0] ram_awburst;
    wire ram_awvalid;
    wire ram_awready;
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] ram_wdata;
    wire [`OPENRV64_AXI_STRB_WIDTH-1:0] ram_wstrb;
    wire ram_wlast;
    wire ram_wvalid;
    wire ram_wready;
    wire [`OPENRV64_AXI_ID_WIDTH-1:0] ram_bid;
    wire [1:0] ram_bresp;
    wire ram_bvalid;
    wire ram_bready;

    wire [63:0] dbg_pc;
    wire [31:0] dbg_instr;
    wire dbg_halted;

    integer cycles;
    integer max_cycles;
    integer retired;
    integer ccx_requests;
    integer ccx_fetch_reads;
    integer ccx_data_reads;
    integer ccx_data_writes;
    integer direction_corrections;
    integer target_corrections;
    integer lookaside_restart_hits;
    integer lookaside_eligible_restarts;
    integer lookaside_pair_replacements;
    integer lookaside_pair_stack_overflows;
    integer lookaside_pair_stack_max_saved;
    integer lookaside_store_fills;
    integer lookaside_store_duplicate_fills;
    integer lookaside_store_free_fills;
    integer lookaside_store_evictions;
    integer lookaside_full_branch_allocations;
    integer lookaside_sector_allocations;
    integer lookaside_sector_predicted_free;
    integer lookaside_sector_unpredicted_free;
    integer lookaside_sector_response_taps;
    integer lookaside_sector_predicted_taps;
    integer lookaside_sector_unpredicted_taps;
    integer lookaside_sector_background_requests;
    integer lookaside_sector_background_deferred;
    integer l1d_prefetch_issued;
    integer l1d_prefetch_useful;
    integer l1d_prefetch_late;
    integer l1d_prefetch_dropped;
    integer l1d_prefetch_useless;
    integer l1d_prefetch_max_depth;
    integer issued;
    integer decoded;
    integer issued_this_cycle;
    integer decoded_this_cycle;
    integer issue_width_0;
    integer issue_width_1;
    integer issue_width_2;
    integer issue_width_3;
    integer issue_width_4;
    integer decode_width_0;
    integer decode_width_1;
    integer decode_width_2;
    integer decode_width_3;
    integer retire_width_0;
    integer retire_width_1;
    integer retire_width_2;
    integer retire_width_3;
    integer dispatch_nonempty;
    integer dispatch_nonempty_no_issue;
    integer dispatch_full;
    integer raw_hazard_cycles;
    integer raw_first_block_cycles;
    integer raw_first_pending_cycles;
    integer raw_first_bundle_cycles;
    integer raw_first_completed_cycles;
    integer raw_secondary_only_cycles;
    integer raw_first_rs1_cycles;
    integer raw_first_rs2_cycles;
    integer raw_first_both_sources_cycles;
    integer raw_first_lane0_cycles;
    integer raw_first_lane1_cycles;
    integer raw_first_lane2_cycles;
    integer raw_first_blocked_alu;
    integer raw_first_blocked_branch;
    integer raw_first_blocked_jump;
    integer raw_first_blocked_load;
    integer raw_first_blocked_store;
    integer window_nonempty_cycles;
    integer window_no_eligible_cycles;
    integer window_raw_stall_cycles;
    integer window_hard_stall_cycles;
    integer window_mem_order_stall_cycles;
    integer window_unissued_entry_cycles;
    integer window_operand_ready_entry_cycles;
    integer window_eligible_entry_cycles;
    integer window_raw_block_entry_cycles;
    integer window_hard_block_entry_cycles;
    integer window_mem_order_block_entry_cycles;
    integer waw_hazard_cycles;
    integer read_port_hazard_cycles;
    integer write_busy_cycles;
    integer barrier_cycles;
    integer retire_nonempty;
    integer retire_nonempty_no_retire;
    integer retire_head_incomplete;
    integer retire_completed_behind_head;
    integer frontend_empty;
    integer frontend_held;
    integer frontend_request_wait;
    integer frontend_control_empty;
    integer frontend_refill_wait;
    integer frontend_no_line;
    integer frontend_bp_stall;
    integer frontend_other_empty;
    integer frontend_empty_backend_ready;
    integer frontend_empty_dispatch_empty;
    integer frontend_empty_dispatch_empty_backend_ready;
    integer frontend_empty_dispatch_empty_retire_empty;
    integer frontend_empty_dispatch_nonempty;
    integer frontend_empty_dispatch_full;
    integer frontend_empty_l1i_external_miss;
    integer frontend_empty_pending_no_external_miss;
    integer stash_trace_episodes;
    integer stash_trace_completed;
    integer stash_trace_interrupted;
    integer stash_trace_requested;
    integer stash_trace_stalled;
    integer stash_trace_completed_stalled;
    integer stash_trace_interrupted_stalled;
    integer stash_trace_exposed_stall_cycles;
    integer stash_trace_completed_stall_cycles;
    integer stash_trace_interrupted_stall_cycles;
    integer stash_trace_same_line_stall_cycles;
    integer stash_trace_next_line_stall_cycles;
    integer stash_trace_preview_instructions;
    integer stash_trace_request_delay_sum;
    integer stash_trace_request_delay_max;
    integer stash_trace_response_delay_sum;
    integer stash_trace_response_delay_max;
    integer stash_trace_refill_latency_sum;
    integer stash_trace_refill_latency_max;
    integer stash_trace_printed;
    integer stash_trace_offset_hits [0:3];
    integer stash_trace_offset_stalled [0:3];
    integer stash_trace_offset_stall_cycles [0:3];
    integer stash_trace_sector_hits [0:1];
    integer stash_trace_sector_stalled [0:1];
    integer stash_trace_sector_stall_cycles [0:1];
    reg stash_trace_active;
    reg stash_trace_request_seen;
    reg [63:0] stash_trace_pc;
    reg [63:0] stash_trace_line;
    integer stash_trace_sector;
    integer stash_trace_offset;
    integer stash_trace_start_cycle;
    integer stash_trace_request_cycle;
    integer stash_trace_episode_stall_cycles;
    integer stash_trace_episode_same_line_stalls;
    integer stash_trace_episode_next_line_stalls;
    integer stash_trace_episode_preview_instructions;
    integer stash_trace_cycle;
    integer stash_trace_reset_index;
    integer stash_trace_delay;
    integer lsu_request_wait;
    integer lsu_outstanding_cycles;
    integer branch_resolutions;
    integer conditional_branch_resolutions;
    integer pipe_conflicts;
    integer pipe_conflicts_ex0;
    integer pipe_conflicts_ex1;
    integer pipe_conflicts_mem;
    integer conflict_blocked_alu;
    integer conflict_blocked_branch;
    integer conflict_blocked_jump;
    integer conflict_blocked_load;
    integer conflict_blocked_store;
    integer conflict_pair_branch_alu;
    integer conflict_pair_alu_branch;
    integer conflict_pair_branch_branch;
    integer conflict_pair_alu_alu;
    integer conflict_pair_load_load;
    integer conflict_pair_store_load;
    integer conflict_pair_store_store;
    integer conflict_pair_other;
    integer memh_words;
    string memh_path;
    reg [63:0] expected_a0;
    reg expected_a0_valid;
    real ipc;

    localparam integer PERF_OP_ALU = 0;
    localparam integer PERF_OP_BRANCH = 1;
    localparam integer PERF_OP_JUMP = 2;
    localparam integer PERF_OP_LOAD = 3;
    localparam integer PERF_OP_STORE = 4;

    function automatic [2:0] perf_op_class;
        input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
        begin
            if (payload[14])
                perf_op_class = PERF_OP_BRANCH;
            else if (payload[13])
                perf_op_class = PERF_OP_JUMP;
            else if (payload[16] && !payload[15])
                perf_op_class = PERF_OP_LOAD;
            else if (payload[15])
                perf_op_class = PERF_OP_STORE;
            else
                perf_op_class = PERF_OP_ALU;
        end
    endfunction

    wire [2:0] trace_candidate_valid =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_valid;
    wire [2:0] trace_candidate_fire =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_fire;
    wire [2:0] trace_candidate_hazard_free =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_hazard_free;
    wire [2:0] trace_candidate_free =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_free;
    wire [3*`OPENRV64_EXEC_PIPE_WIDTH-1:0] trace_candidate_pipe =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_pipe;
    wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        trace_candidate_payload =
            dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_payload;
    wire [2:0] trace_candidate_uses_rs1 =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.reg_map_uses_rs1;
    wire [2:0] trace_candidate_uses_rs2 =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.reg_map_uses_rs2;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] trace_candidate_rs1 =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_rs1_addr;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] trace_candidate_rs2 =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.candidate_rs2_addr;
    wire [2:0] trace_raw_bundle = {
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.raw_bundle2,
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.raw_bundle1,
        1'b0
    };
    wire [2:0] trace_raw_rs1 = {
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs12 &&
            ((dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                busy_after_retire[
                    trace_candidate_rs1[
                        2*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH]] &&
              !dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                forward_rs12) ||
             dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot0[
                trace_candidate_rs1[
                    2*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]] ||
             dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot1[
                trace_candidate_rs1[
                    2*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]),
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs11 &&
            ((dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                busy_after_retire[
                    trace_candidate_rs1[
                        1*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH]] &&
              !dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                forward_rs11) ||
             dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot0[
                trace_candidate_rs1[
                    1*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]),
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs10 &&
            dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                busy_after_retire[
                    trace_candidate_rs1[
                        0*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH]] &&
            !dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.forward_rs10
    };
    wire [2:0] trace_raw_rs2 = {
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs22 &&
            ((dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                busy_after_retire[
                    trace_candidate_rs2[
                        2*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH]] &&
              !dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                forward_rs22) ||
             dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot0[
                trace_candidate_rs2[
                    2*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]] ||
             dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot1[
                trace_candidate_rs2[
                    2*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]),
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs21 &&
            ((dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                busy_after_retire[
                    trace_candidate_rs2[
                        1*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH]] &&
              !dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                forward_rs21) ||
             dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot0[
                trace_candidate_rs2[
                    1*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]),
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs20 &&
            dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.
                busy_after_retire[
                    trace_candidate_rs2[
                        0*`RV64_REG_ADDR_WIDTH +:
                        `RV64_REG_ADDR_WIDTH]] &&
            !dut.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.forward_rs20
    };
    wire [31:0] trace_youngest_ready =
        dut.u_backend.youngest_forward_valid_raw;
    wire [2:0] trace_raw_completed = {
        dut.u_backend.raw_hazard[2] && !trace_raw_bundle[2] &&
            (!trace_raw_rs1[2] || trace_youngest_ready[
                trace_candidate_rs1[
                    2*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]) &&
            (!trace_raw_rs2[2] || trace_youngest_ready[
                trace_candidate_rs2[
                    2*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]),
        dut.u_backend.raw_hazard[1] && !trace_raw_bundle[1] &&
            (!trace_raw_rs1[1] || trace_youngest_ready[
                trace_candidate_rs1[
                    1*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]) &&
            (!trace_raw_rs2[1] || trace_youngest_ready[
                trace_candidate_rs2[
                    1*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]),
        dut.u_backend.raw_hazard[0] &&
            (!trace_raw_rs1[0] || trace_youngest_ready[
                trace_candidate_rs1[
                    0*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]]) &&
            (!trace_raw_rs2[0] || trace_youngest_ready[
                trace_candidate_rs2[
                    0*`RV64_REG_ADDR_WIDTH +:
                    `RV64_REG_ADDR_WIDTH]])
    };
    wire raw_first_lane0 = trace_candidate_valid[0] &&
                           !trace_candidate_fire[0];
    wire raw_first_lane1 = !raw_first_lane0 &&
                           trace_candidate_valid[1] &&
                           trace_candidate_fire[0] &&
                           !trace_candidate_fire[1];
    wire raw_first_lane2 = !raw_first_lane0 && !raw_first_lane1 &&
                           trace_candidate_valid[2] &&
                           trace_candidate_fire[1] &&
                           !trace_candidate_fire[2];
    wire [2:0] raw_first_lane =
        {raw_first_lane2, raw_first_lane1, raw_first_lane0};
    wire raw_first_block = |(raw_first_lane & dut.u_backend.raw_hazard);
    wire raw_first_bundle = |(raw_first_lane & trace_raw_bundle);
    wire raw_first_completed = |(raw_first_lane & trace_raw_completed);
    wire raw_first_rs1 = |(raw_first_lane & trace_raw_rs1);
    wire raw_first_rs2 = |(raw_first_lane & trace_raw_rs2);
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        raw_first_payload = raw_first_lane0 ?
            trace_candidate_payload[
                0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] :
            raw_first_lane1 ?
            trace_candidate_payload[
                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] :
            trace_candidate_payload[
                2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
    wire [2:0] raw_first_op = perf_op_class(raw_first_payload);
    wire [4:0] trace_window_unissued = (ISSUE_WINDOW != 0) ?
        dut.u_backend.u_dispatch.g_3p.u_window.trace_unissued_count :
        5'd0;
    wire [4:0] trace_window_operand_ready = (ISSUE_WINDOW != 0) ?
        dut.u_backend.u_dispatch.g_3p.u_window.trace_operand_ready_count :
        5'd0;
    wire [4:0] trace_window_eligible = (ISSUE_WINDOW != 0) ?
        dut.u_backend.u_dispatch.g_3p.u_window.trace_eligible_count :
        5'd0;
    wire [4:0] trace_window_raw_block = (ISSUE_WINDOW != 0) ?
        dut.u_backend.u_dispatch.g_3p.u_window.trace_raw_block_count :
        5'd0;
    wire [4:0] trace_window_hard_block = (ISSUE_WINDOW != 0) ?
        dut.u_backend.u_dispatch.g_3p.u_window.trace_hard_block_count :
        5'd0;
    wire [4:0] trace_window_mem_order_block = (ISSUE_WINDOW != 0) ?
        dut.u_backend.u_dispatch.g_3p.u_window.trace_mem_order_block_count :
        5'd0;
    wire [2:0] trace_barrier_allow =
        dut.u_backend.u_dispatch.g_3p.u_dispatch.u_control.barrier_allow;
    wire trace_allocation_ready = dut.u_backend.allocation_ready;
    wire trace_conflict1 =
        trace_candidate_valid[1] && trace_candidate_fire[0] &&
        !trace_candidate_fire[1] && trace_candidate_hazard_free[1] &&
        trace_barrier_allow[1] && trace_allocation_ready &&
        !trace_candidate_free[0] &&
        (trace_candidate_pipe[1*`OPENRV64_EXEC_PIPE_WIDTH +:
                              `OPENRV64_EXEC_PIPE_WIDTH] ==
         trace_candidate_pipe[0*`OPENRV64_EXEC_PIPE_WIDTH +:
                              `OPENRV64_EXEC_PIPE_WIDTH]);
    wire trace_conflict2 =
        trace_candidate_valid[2] && trace_candidate_fire[1] &&
        !trace_candidate_fire[2] && trace_candidate_hazard_free[2] &&
        trace_barrier_allow[2] && trace_allocation_ready &&
        !trace_candidate_free[1] &&
        ((trace_candidate_pipe[2*`OPENRV64_EXEC_PIPE_WIDTH +:
                               `OPENRV64_EXEC_PIPE_WIDTH] ==
          trace_candidate_pipe[0*`OPENRV64_EXEC_PIPE_WIDTH +:
                               `OPENRV64_EXEC_PIPE_WIDTH]) ||
         (trace_candidate_pipe[2*`OPENRV64_EXEC_PIPE_WIDTH +:
                               `OPENRV64_EXEC_PIPE_WIDTH] ==
          trace_candidate_pipe[1*`OPENRV64_EXEC_PIPE_WIDTH +:
                               `OPENRV64_EXEC_PIPE_WIDTH]));
    wire trace_pipe_conflict = trace_conflict1 || trace_conflict2;
    wire [`OPENRV64_EXEC_PIPE_WIDTH-1:0] trace_conflict_pipe =
        trace_conflict1 ?
            trace_candidate_pipe[1*`OPENRV64_EXEC_PIPE_WIDTH +:
                                 `OPENRV64_EXEC_PIPE_WIDTH] :
            trace_candidate_pipe[2*`OPENRV64_EXEC_PIPE_WIDTH +:
                                 `OPENRV64_EXEC_PIPE_WIDTH];
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        trace_conflict_blocked_payload = trace_conflict1 ?
            trace_candidate_payload[
                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] :
            trace_candidate_payload[
                2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH];
    wire [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        trace_conflict_older_payload = trace_conflict1 ?
            trace_candidate_payload[
                0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] :
            ((trace_candidate_pipe[
                  2*`OPENRV64_EXEC_PIPE_WIDTH +:
                  `OPENRV64_EXEC_PIPE_WIDTH] ==
              trace_candidate_pipe[
                  1*`OPENRV64_EXEC_PIPE_WIDTH +:
                  `OPENRV64_EXEC_PIPE_WIDTH]) ?
                trace_candidate_payload[
                    1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH] :
                trace_candidate_payload[
                    0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH]);
    wire [2:0] trace_conflict_blocked_op =
        perf_op_class(trace_conflict_blocked_payload);
    wire [2:0] trace_conflict_older_op =
        perf_op_class(trace_conflict_older_payload);

    wire [`OPENRV64_LSU_OUTSTANDING-1:0] trace_lsu_sent;
    genvar trace_lsu_index;
    generate
        for (trace_lsu_index = 0;
             trace_lsu_index < `OPENRV64_LSU_OUTSTANDING;
             trace_lsu_index = trace_lsu_index + 1) begin : g_trace_lsu
            if (trace_lsu_index < 4) begin : g_mem0
                assign trace_lsu_sent[trace_lsu_index] =
                    dut.u_backend.u_exec.g_3p.u_exec.u_mem0.slot_sent_q[
                        trace_lsu_index];
            end else begin : g_mem1
                assign trace_lsu_sent[trace_lsu_index] =
                    dut.u_backend.u_exec.g_3p.u_exec.u_mem1.slot_sent_q[
                        trace_lsu_index - 4];
            end
        end
    endgenerate

    openrv64_rv64_top_3p #(
        .RESET_VECTOR(`OPENRV64_SOC_MEMORY_BASE),
        .BUS_CONFIG(`OPENRV64_BUS_AXI),
        .ENABLE_RV64M(1'b1),
        .COMPLETION_FORWARD_MASK(COMPLETION_FORWARD_MASK),
        .BRANCH_COMPLETION_FORWARD_MASK(
            BRANCH_COMPLETION_FORWARD_MASK),
        .ENABLE_FULL_FORWARDING(ENABLE_FULL_FORWARDING),
        .RELAX_WAW(RELAX_WAW),
        .RELAX_HAZARDS(RELAX_HAZARDS),
        .ENABLE_ISSUE_WINDOW(ISSUE_WINDOW),
        .ENABLE_SPECULATION_WINDOW(SPECULATION_WINDOW),
        .SPEC_LOAD_BASE(`OPENRV64_SOC_MEMORY_BASE),
        .SPEC_LOAD_SIZE(RAM_BYTES),
        .ENABLE_L1I(1'b1),
        .ENABLE_L1D(1'b1),
        .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
        .L1D_CACHE_BYTES(L1D_CACHE_BYTES),
        .L1D_PREFETCH_ENABLE(L1D_PREFETCH_ENABLE),
        .L1D_PREFETCH_STREAMS(L1D_PREFETCH_STREAMS),
        .L1D_PREFETCH_ADAPTIVE_ENABLE(
            L1D_PREFETCH_ADAPTIVE_ENABLE),
        .L1D_PREFETCH_MAX_DISTANCE(L1D_PREFETCH_MAX_DISTANCE),
        .L1D_PREFETCH_QUEUE_LINES(L1D_PREFETCH_QUEUE_LINES),
        .L1D_PREFETCH_OUTSTANDING(L1D_PREFETCH_OUTSTANDING),
        .L1D_PREFETCH_DEMAND_RESERVE(
            L1D_PREFETCH_DEMAND_RESERVE),
        .ENABLE_MAGIC_MEMORY(1'b0),
        .ENABLE_TRACE(1'b0),
        .ENABLE_FETCH_ALT_LOOKASIDE(FETCH_ALT_LOOKASIDE),
        .ENABLE_FETCH_ALT_CONFIDENCE_GATE(
            FETCH_ALT_CONFIDENCE_GATE),
        .FETCH_ALT_PAIR_STACK_DEPTH(FETCH_ALT_PAIR_STACK_DEPTH),
        .BP_TYPE(BP_TYPE),
        .BP_RAS_ENABLE(1'b1),
        .BP_RAS_DEPTH(8),
        .BP_BIMODAL_ENTRIES(32),
        .BP_BIMODAL_COUNTER_BITS(3),
        .BP_BIMODAL_UPDATE_DEPTH(4),
        .BP_GSHARE_ENTRIES(256),
        .BP_GSHARE_COUNTER_BITS(3),
        .BP_BTB_ENTRIES(256),
        .BP_BTB_TAG_BITS(16),
        .BP_INFLIGHT_DEPTH(16)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .mem_ready(1'b0),
        .mem_rdata(64'd0),
        .mem_error(1'b0),
        .pair512_req_valid(),
        .pair512_req_ready(1'b0),
        .pair512_req_predicted_addr(),
        .pair512_req_unpredicted_addr(),
        .pair512_resp_valid(1'b0),
        .pair512_resp_predicted_addr(64'd0),
        .pair512_resp_predicted_data(
            {`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
        .pair512_resp_unpredicted_addr(64'd0),
        .pair512_resp_unpredicted_data(
            {`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
        .pair1024_req_valid(),
        .pair1024_req_ready(1'b0),
        .pair1024_req_predicted_addr(),
        .pair1024_req_unpredicted_addr(),
        .pair1024_resp_valid(1'b0),
        .pair1024_resp_predicted_addr(64'd0),
        .pair1024_resp_predicted_data(
            {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}}),
        .pair1024_resp_unpredicted_addr(64'd0),
        .pair1024_resp_unpredicted_data(
            {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}}),
        .m_axi_arvalid(core_axi_arvalid),
        .m_axi_arready(1'b0),
        .m_axi_rid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
        .m_axi_rdata({`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
        .m_axi_rresp(2'b00),
        .m_axi_rlast(1'b1),
        .m_axi_rvalid(1'b0),
        .m_axi_awvalid(core_axi_awvalid),
        .m_axi_awready(1'b0),
        .m_axi_wvalid(core_axi_wvalid),
        .m_axi_wready(1'b0),
        .m_axi_bid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
        .m_axi_bresp(2'b00),
        .m_axi_bvalid(1'b0),
        .ccx_req_valid(ccx_req_valid),
        .ccx_req_ready(ccx_req_ready),
        .ccx_req_hart_id(ccx_req_hart_id),
        .ccx_req_txn_id(ccx_req_txn_id),
        .ccx_req_source_id(ccx_req_source_id),
        .ccx_req_op(ccx_req_op),
        .ccx_req_lock(ccx_req_lock),
        .ccx_req_order(ccx_req_order),
        .ccx_req_kind(ccx_req_kind),
        .ccx_req_attr(ccx_req_attr),
        .ccx_req_size(ccx_req_size),
        .ccx_req_addr(ccx_req_addr),
        .ccx_req_burst_len(ccx_req_burst_len),
        .ccx_wdata_valid(ccx_wdata_valid),
        .ccx_wdata_ready(ccx_wdata_ready),
        .ccx_wdata_hart_id(ccx_wdata_hart_id),
        .ccx_wdata_txn_id(ccx_wdata_txn_id),
        .ccx_wdata_source_id(ccx_wdata_source_id),
        .ccx_wdata_beat_index(ccx_wdata_beat_index),
        .ccx_wdata_last(ccx_wdata_last),
        .ccx_wdata(ccx_wdata),
        .ccx_wstrb(ccx_wstrb),
        .ccx_resp_valid(ccx_resp_valid),
        .ccx_resp_ready(ccx_resp_ready),
        .ccx_resp_hart_id(ccx_resp_hart_id),
        .ccx_resp_txn_id(ccx_resp_txn_id),
        .ccx_resp_source_id(ccx_resp_source_id),
        .ccx_resp_beat_index(ccx_resp_beat_index),
        .ccx_resp_last(ccx_resp_last),
        .ccx_resp_rdata(ccx_resp_rdata),
        .ccx_resp_error(ccx_resp_error),
        .ccx_resp_sc_success(ccx_resp_sc_success),
        .irq_m_software(1'b0),
        .irq_m_timer(1'b0),
        .irq_m_external(1'b0),
        .irq_s_software(1'b0),
        .irq_s_timer(1'b0),
        .irq_s_external(1'b0),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted)
    );

    openrv64_core_complex_nh #(
        .NUM_HARTS(1),
        .HART_ID_BASE(0),
        .L2_BYTES(L2_BYTES),
        .L2_LINE_BYTES(64),
        .L2_WAYS(L2_WAYS),
        .L2_MERGE_ENTRIES(8),
        .L2_WAITERS_PER_MSHR(8),
        .L2_COMMAND_ENTRIES(16),
        .L2_RESPONSE_ENTRIES(16),
        .L2_BUS_DATA_WIDTH(512),
        .BUS_TYPE(`OPENRV64_COMPLEX_BUS_AXI),
        .BUS_ADDR_WIDTH(`OPENRV64_AXI_ADDR_WIDTH),
        .BUS_DATA_WIDTH(`OPENRV64_AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(`OPENRV64_AXI_ID_WIDTH),
        .AXI_ID({`OPENRV64_AXI_ID_WIDTH{1'b1}})
    ) u_complex (
        .clk_i(clk),
        .rst_ni(rst_n),
        .ccx_req_valid_i(ccx_req_valid),
        .ccx_req_ready_o(ccx_req_ready),
        .ccx_req_hart_id_i(ccx_req_hart_id),
        .ccx_req_txn_id_i(ccx_req_txn_id),
        .ccx_req_source_id_i(ccx_req_source_id),
        .ccx_req_op_i(ccx_req_op),
        .ccx_req_lock_i(ccx_req_lock),
        .ccx_req_order_i(ccx_req_order),
        .ccx_req_kind_i(ccx_req_kind),
        .ccx_req_attr_i(ccx_req_attr),
        .ccx_req_size_i(ccx_req_size),
        .ccx_req_addr_i(ccx_req_addr),
        .ccx_req_burst_len_i(ccx_req_burst_len),
        .ccx_wdata_valid_i(ccx_wdata_valid),
        .ccx_wdata_ready_o(ccx_wdata_ready),
        .ccx_wdata_hart_id_i(ccx_wdata_hart_id),
        .ccx_wdata_txn_id_i(ccx_wdata_txn_id),
        .ccx_wdata_source_id_i(ccx_wdata_source_id),
        .ccx_wdata_beat_index_i(ccx_wdata_beat_index),
        .ccx_wdata_last_i(ccx_wdata_last),
        .ccx_wdata_i(ccx_wdata),
        .ccx_wstrb_i(ccx_wstrb),
        .ccx_resp_valid_o(ccx_resp_valid),
        .ccx_resp_ready_i(ccx_resp_ready),
        .ccx_resp_hart_id_o(ccx_resp_hart_id),
        .ccx_resp_txn_id_o(ccx_resp_txn_id),
        .ccx_resp_source_id_o(ccx_resp_source_id),
        .ccx_resp_beat_index_o(ccx_resp_beat_index),
        .ccx_resp_last_o(ccx_resp_last),
        .ccx_resp_rdata_o(ccx_resp_rdata),
        .ccx_resp_error_o(ccx_resp_error),
        .ccx_resp_sc_success_o(ccx_resp_sc_success),
        .m_axi_arid_o(ram_arid),
        .m_axi_araddr_o(ram_araddr),
        .m_axi_arlen_o(ram_arlen),
        .m_axi_arsize_o(ram_arsize),
        .m_axi_arburst_o(ram_arburst),
        .m_axi_arvalid_o(ram_arvalid),
        .m_axi_arready_i(ram_arready),
        .m_axi_rid_i(ram_rid),
        .m_axi_rdata_i(ram_rdata),
        .m_axi_rresp_i(ram_rresp),
        .m_axi_rlast_i(ram_rlast),
        .m_axi_rvalid_i(ram_rvalid),
        .m_axi_rready_o(ram_rready),
        .m_axi_awid_o(ram_awid),
        .m_axi_awaddr_o(ram_awaddr),
        .m_axi_awlen_o(ram_awlen),
        .m_axi_awsize_o(ram_awsize),
        .m_axi_awburst_o(ram_awburst),
        .m_axi_awvalid_o(ram_awvalid),
        .m_axi_awready_i(ram_awready),
        .m_axi_wdata_o(ram_wdata),
        .m_axi_wstrb_o(ram_wstrb),
        .m_axi_wlast_o(ram_wlast),
        .m_axi_wvalid_o(ram_wvalid),
        .m_axi_wready_i(ram_wready),
        .m_axi_bid_i(ram_bid),
        .m_axi_bresp_i(ram_bresp),
        .m_axi_bvalid_i(ram_bvalid),
        .m_axi_bready_o(ram_bready),
        .wb_stall_i(1'b0),
        .wb_ack_i(1'b0),
        .wb_err_i(1'b0),
        .wb_rty_i(1'b0),
        .wb_dat_i({`OPENRV64_AXI_DATA_WIDTH{1'b0}})
    );

    tb_axi256_burst_sram #(
        .RAM_BYTES(RAM_BYTES)
    ) u_ram (
        .clk_i(clk),
        .rst_ni(rst_n),
        .arid_i(ram_arid),
        .araddr_i(ram_araddr),
        .arlen_i(ram_arlen),
        .arsize_i(ram_arsize),
        .arburst_i(ram_arburst),
        .arvalid_i(ram_arvalid),
        .arready_o(ram_arready),
        .rid_o(ram_rid),
        .rdata_o(ram_rdata),
        .rresp_o(ram_rresp),
        .rlast_o(ram_rlast),
        .rvalid_o(ram_rvalid),
        .rready_i(ram_rready),
        .awid_i(ram_awid),
        .awaddr_i(ram_awaddr),
        .awlen_i(ram_awlen),
        .awsize_i(ram_awsize),
        .awburst_i(ram_awburst),
        .awvalid_i(ram_awvalid),
        .awready_o(ram_awready),
        .wdata_i(ram_wdata),
        .wstrb_i(ram_wstrb),
        .wlast_i(ram_wlast),
        .wvalid_i(ram_wvalid),
        .wready_o(ram_wready),
        .bid_o(ram_bid),
        .bresp_o(ram_bresp),
        .bvalid_o(ram_bvalid),
        .bready_i(ram_bready)
    );

    always #5 clk = ~clk;

    // A sector lookaside hit is only useful until the completing 256-bit
    // demand returns.  Track that interval at the handshake edges so the
    // diagnostic distinguishes an exposed instruction starvation from a
    // frontend-empty cycle caused by backend pressure or branch control.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stash_trace_episodes = 0;
            stash_trace_completed = 0;
            stash_trace_interrupted = 0;
            stash_trace_requested = 0;
            stash_trace_stalled = 0;
            stash_trace_completed_stalled = 0;
            stash_trace_interrupted_stalled = 0;
            stash_trace_exposed_stall_cycles = 0;
            stash_trace_completed_stall_cycles = 0;
            stash_trace_interrupted_stall_cycles = 0;
            stash_trace_same_line_stall_cycles = 0;
            stash_trace_next_line_stall_cycles = 0;
            stash_trace_preview_instructions = 0;
            stash_trace_request_delay_sum = 0;
            stash_trace_request_delay_max = 0;
            stash_trace_response_delay_sum = 0;
            stash_trace_response_delay_max = 0;
            stash_trace_refill_latency_sum = 0;
            stash_trace_refill_latency_max = 0;
            stash_trace_printed = 0;
            stash_trace_active = 1'b0;
            stash_trace_request_seen = 1'b0;
            stash_trace_pc = 64'd0;
            stash_trace_line = 64'd0;
            stash_trace_sector = 0;
            stash_trace_offset = 0;
            stash_trace_start_cycle = 0;
            stash_trace_request_cycle = 0;
            stash_trace_episode_stall_cycles = 0;
            stash_trace_episode_same_line_stalls = 0;
            stash_trace_episode_next_line_stalls = 0;
            stash_trace_episode_preview_instructions = 0;
            stash_trace_cycle = 0;
            stash_trace_delay = 0;
            for (stash_trace_reset_index = 0;
                 stash_trace_reset_index < 4;
                 stash_trace_reset_index =
                     stash_trace_reset_index + 1) begin
                stash_trace_offset_hits[stash_trace_reset_index] = 0;
                stash_trace_offset_stalled[stash_trace_reset_index] = 0;
                stash_trace_offset_stall_cycles[
                    stash_trace_reset_index] = 0;
                if (stash_trace_reset_index < 2) begin
                    stash_trace_sector_hits[stash_trace_reset_index] = 0;
                    stash_trace_sector_stalled[
                        stash_trace_reset_index] = 0;
                    stash_trace_sector_stall_cycles[
                        stash_trace_reset_index] = 0;
                end
            end
        end else begin
            stash_trace_cycle = stash_trace_cycle + 1;

            if (stash_trace_active) begin
                stash_trace_episode_preview_instructions =
                    stash_trace_episode_preview_instructions +
                    dut.frontend_decode_fire[0] +
                    dut.frontend_decode_fire[1] +
                    dut.frontend_decode_fire[2];
                stash_trace_preview_instructions =
                    stash_trace_preview_instructions +
                    dut.frontend_decode_fire[0] +
                    dut.frontend_decode_fire[1] +
                    dut.frontend_decode_fire[2];

                if (!stash_trace_request_seen &&
                    dut.g_fetch_axi.u_fetch.req_fire &&
                    dut.g_fetch_axi.u_fetch.req_demand_o &&
                    (dut.g_fetch_axi.u_fetch.req_addr_o[63:5] ==
                     stash_trace_line[63:5])) begin
                    stash_trace_request_seen = 1'b1;
                    stash_trace_request_cycle = stash_trace_cycle;
                    stash_trace_requested = stash_trace_requested + 1;
                    stash_trace_delay = stash_trace_cycle -
                                        stash_trace_start_cycle;
                    stash_trace_request_delay_sum =
                        stash_trace_request_delay_sum + stash_trace_delay;
                    if (stash_trace_delay >
                        stash_trace_request_delay_max)
                        stash_trace_request_delay_max = stash_trace_delay;
                end

                if ((dut.fetch_decode_valid == 0) &&
                    dut.backend_decode_ready[0] &&
                    dut.frontend_decode_enable &&
                    !dut.control_flush &&
                    !dut.control_redirect &&
                    !dut.bp_fetch_stall &&
                    !dut.g_fetch_axi.u_fetch.consume_line_hit &&
                    dut.g_fetch_axi.u_fetch.pending_valid_q &&
                    (dut.g_fetch_axi.u_fetch.pending_addr_q[63:5] ==
                     stash_trace_line[63:5])) begin
                    if (stash_trace_episode_stall_cycles == 0) begin
                        stash_trace_stalled = stash_trace_stalled + 1;
                        stash_trace_offset_stalled[
                            stash_trace_offset] =
                                stash_trace_offset_stalled[
                                    stash_trace_offset] + 1;
                        stash_trace_sector_stalled[
                            stash_trace_sector] =
                                stash_trace_sector_stalled[
                                    stash_trace_sector] + 1;
                    end
                    stash_trace_episode_stall_cycles =
                        stash_trace_episode_stall_cycles + 1;
                    stash_trace_exposed_stall_cycles =
                        stash_trace_exposed_stall_cycles + 1;
                    stash_trace_offset_stall_cycles[
                        stash_trace_offset] =
                            stash_trace_offset_stall_cycles[
                                stash_trace_offset] + 1;
                    stash_trace_sector_stall_cycles[
                        stash_trace_sector] =
                            stash_trace_sector_stall_cycles[
                                stash_trace_sector] + 1;
                    if (dut.g_fetch_axi.u_fetch.consume_pc_q[63:5] ==
                        stash_trace_line[63:5]) begin
                        stash_trace_episode_same_line_stalls =
                            stash_trace_episode_same_line_stalls + 1;
                        stash_trace_same_line_stall_cycles =
                            stash_trace_same_line_stall_cycles + 1;
                    end else begin
                        stash_trace_episode_next_line_stalls =
                            stash_trace_episode_next_line_stalls + 1;
                        stash_trace_next_line_stall_cycles =
                            stash_trace_next_line_stall_cycles + 1;
                    end
                end

                // Any new frontend restart abandons the old preview episode.
                // A simultaneous response is not useful to that old path.
                if (dut.fetch3_restart || dut.control_flush) begin
                    stash_trace_interrupted =
                        stash_trace_interrupted + 1;
                    if (stash_trace_episode_stall_cycles != 0)
                        stash_trace_interrupted_stalled =
                            stash_trace_interrupted_stalled + 1;
                    stash_trace_interrupted_stall_cycles =
                        stash_trace_interrupted_stall_cycles +
                        stash_trace_episode_stall_cycles;
                    stash_trace_active = 1'b0;
                end else if (stash_trace_request_seen &&
                             dut.fetch_pipe_resp_valid &&
                             dut.fetch_pipe_resp_demand &&
                             (dut.fetch_pipe_resp_addr[63:5] ==
                              stash_trace_line[63:5])) begin
                    stash_trace_completed = stash_trace_completed + 1;
                    if (stash_trace_episode_stall_cycles != 0)
                        stash_trace_completed_stalled =
                            stash_trace_completed_stalled + 1;
                    stash_trace_completed_stall_cycles =
                        stash_trace_completed_stall_cycles +
                        stash_trace_episode_stall_cycles;
                    stash_trace_delay = stash_trace_cycle -
                                        stash_trace_start_cycle;
                    stash_trace_response_delay_sum =
                        stash_trace_response_delay_sum + stash_trace_delay;
                    if (stash_trace_delay >
                        stash_trace_response_delay_max)
                        stash_trace_response_delay_max = stash_trace_delay;
                    stash_trace_delay = stash_trace_cycle -
                                        stash_trace_request_cycle;
                    stash_trace_refill_latency_sum =
                        stash_trace_refill_latency_sum + stash_trace_delay;
                    if (stash_trace_delay >
                        stash_trace_refill_latency_max)
                        stash_trace_refill_latency_max = stash_trace_delay;
                    if (($test$plusargs("trace_stash_stall") ||
                         $test$plusargs("trace_stash_stall_all")) &&
                        (stash_trace_episode_stall_cycles != 0) &&
                        ($test$plusargs("trace_stash_stall_all") ||
                         (stash_trace_printed < 16))) begin
                        $display(
                            "TRACE_STASH_STALL pc=%016h line=%016h sector=%0d offset=%0d request_delay=%0d refill_latency=%0d hit_to_fill=%0d preview_instr=%0d exposed_stall=%0d same_line=%0d next_line=%0d",
                            stash_trace_pc, stash_trace_line,
                            stash_trace_sector, stash_trace_offset,
                            stash_trace_request_cycle -
                                stash_trace_start_cycle,
                            stash_trace_cycle -
                                stash_trace_request_cycle,
                            stash_trace_cycle -
                                stash_trace_start_cycle,
                            stash_trace_episode_preview_instructions,
                            stash_trace_episode_stall_cycles,
                            stash_trace_episode_same_line_stalls,
                            stash_trace_episode_next_line_stalls);
                        stash_trace_printed = stash_trace_printed + 1;
                    end
                    stash_trace_active = 1'b0;
                end
            end

            if ((FETCH_ALT_LOOKASIDE == 3) &&
                dut.fetch_alt_restart_hit) begin
                stash_trace_active = 1'b1;
                stash_trace_request_seen = 1'b0;
                stash_trace_pc = dut.fetch3_restart_pc;
                stash_trace_line = {dut.fetch3_restart_pc[63:5], 5'b00000};
                stash_trace_sector = dut.fetch3_restart_pc[4];
                stash_trace_offset = dut.fetch3_restart_pc[3:2];
                stash_trace_start_cycle = stash_trace_cycle;
                stash_trace_request_cycle = 0;
                stash_trace_episode_stall_cycles = 0;
                stash_trace_episode_same_line_stalls = 0;
                stash_trace_episode_next_line_stalls = 0;
                stash_trace_episode_preview_instructions = 0;
                stash_trace_episodes = stash_trace_episodes + 1;
                stash_trace_offset_hits[
                    dut.fetch3_restart_pc[3:2]] =
                        stash_trace_offset_hits[
                            dut.fetch3_restart_pc[3:2]] + 1;
                stash_trace_sector_hits[
                    dut.fetch3_restart_pc[4]] =
                        stash_trace_sector_hits[
                            dut.fetch3_restart_pc[4]] + 1;
            end
        end
    end

    initial begin
        if (!$value$plusargs("memh=%s", memh_path))
            $fatal(1, "full-CCX test requires +memh=<256-bit image>");
        if (!$value$plusargs("memh_words=%d", memh_words))
            $fatal(1, "full-CCX test requires +memh_words=<count>");
        $readmemh(memh_path, u_ram.ram_q, 0, memh_words - 1);
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        max_cycles = 250000;
        expected_a0 = 0;
        expected_a0_valid = 1'b0;
        retired = 0;
        ccx_requests = 0;
        ccx_fetch_reads = 0;
        ccx_data_reads = 0;
        ccx_data_writes = 0;
        direction_corrections = 0;
        target_corrections = 0;
        lookaside_restart_hits = 0;
        lookaside_eligible_restarts = 0;
        lookaside_pair_replacements = 0;
        lookaside_pair_stack_overflows = 0;
        lookaside_pair_stack_max_saved = 0;
        lookaside_store_fills = 0;
        lookaside_store_duplicate_fills = 0;
        lookaside_store_free_fills = 0;
        lookaside_store_evictions = 0;
        lookaside_full_branch_allocations = 0;
        lookaside_sector_allocations = 0;
        lookaside_sector_predicted_free = 0;
        lookaside_sector_unpredicted_free = 0;
        lookaside_sector_response_taps = 0;
        lookaside_sector_predicted_taps = 0;
        lookaside_sector_unpredicted_taps = 0;
        lookaside_sector_background_requests = 0;
        lookaside_sector_background_deferred = 0;
        l1d_prefetch_issued = 0;
        l1d_prefetch_useful = 0;
        l1d_prefetch_late = 0;
        l1d_prefetch_dropped = 0;
        l1d_prefetch_useless = 0;
        l1d_prefetch_max_depth = 0;
        issued = 0;
        decoded = 0;
        issued_this_cycle = 0;
        decoded_this_cycle = 0;
        issue_width_0 = 0;
        issue_width_1 = 0;
        issue_width_2 = 0;
        issue_width_3 = 0;
        issue_width_4 = 0;
        decode_width_0 = 0;
        decode_width_1 = 0;
        decode_width_2 = 0;
        decode_width_3 = 0;
        retire_width_0 = 0;
        retire_width_1 = 0;
        retire_width_2 = 0;
        retire_width_3 = 0;
        dispatch_nonempty = 0;
        dispatch_nonempty_no_issue = 0;
        dispatch_full = 0;
        raw_hazard_cycles = 0;
        raw_first_block_cycles = 0;
        raw_first_pending_cycles = 0;
        raw_first_bundle_cycles = 0;
        raw_first_completed_cycles = 0;
        raw_secondary_only_cycles = 0;
        raw_first_rs1_cycles = 0;
        raw_first_rs2_cycles = 0;
        raw_first_both_sources_cycles = 0;
        raw_first_lane0_cycles = 0;
        raw_first_lane1_cycles = 0;
        raw_first_lane2_cycles = 0;
        raw_first_blocked_alu = 0;
        raw_first_blocked_branch = 0;
        raw_first_blocked_jump = 0;
        raw_first_blocked_load = 0;
        raw_first_blocked_store = 0;
        window_nonempty_cycles = 0;
        window_no_eligible_cycles = 0;
        window_raw_stall_cycles = 0;
        window_hard_stall_cycles = 0;
        window_mem_order_stall_cycles = 0;
        window_unissued_entry_cycles = 0;
        window_operand_ready_entry_cycles = 0;
        window_eligible_entry_cycles = 0;
        window_raw_block_entry_cycles = 0;
        window_hard_block_entry_cycles = 0;
        window_mem_order_block_entry_cycles = 0;
        waw_hazard_cycles = 0;
        read_port_hazard_cycles = 0;
        write_busy_cycles = 0;
        barrier_cycles = 0;
        retire_nonempty = 0;
        retire_nonempty_no_retire = 0;
        retire_head_incomplete = 0;
        retire_completed_behind_head = 0;
        frontend_empty = 0;
        frontend_held = 0;
        frontend_request_wait = 0;
        frontend_control_empty = 0;
        frontend_refill_wait = 0;
        frontend_no_line = 0;
        frontend_bp_stall = 0;
        frontend_other_empty = 0;
        frontend_empty_backend_ready = 0;
        frontend_empty_dispatch_empty = 0;
        frontend_empty_dispatch_empty_backend_ready = 0;
        frontend_empty_dispatch_empty_retire_empty = 0;
        frontend_empty_dispatch_nonempty = 0;
        frontend_empty_dispatch_full = 0;
        frontend_empty_l1i_external_miss = 0;
        frontend_empty_pending_no_external_miss = 0;
        lsu_request_wait = 0;
        lsu_outstanding_cycles = 0;
        branch_resolutions = 0;
        conditional_branch_resolutions = 0;
        pipe_conflicts = 0;
        pipe_conflicts_ex0 = 0;
        pipe_conflicts_ex1 = 0;
        pipe_conflicts_mem = 0;
        conflict_blocked_alu = 0;
        conflict_blocked_branch = 0;
        conflict_blocked_jump = 0;
        conflict_blocked_load = 0;
        conflict_blocked_store = 0;
        conflict_pair_branch_alu = 0;
        conflict_pair_alu_branch = 0;
        conflict_pair_branch_branch = 0;
        conflict_pair_alu_alu = 0;
        conflict_pair_load_load = 0;
        conflict_pair_store_load = 0;
        conflict_pair_store_store = 0;
        conflict_pair_other = 0;
        if (!$value$plusargs("max_cycles=%d", max_cycles))
            max_cycles = 250000;
        if ($value$plusargs("expect_a0=%h", expected_a0))
            expected_a0_valid = 1'b1;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        for (cycles = 0; (cycles < max_cycles) && !dbg_halted;
             cycles = cycles + 1) begin
            @(posedge clk);
            #1;
            retired = retired + dut.backend_retire_count;
            issued_this_cycle =
                dut.backend_issue_valid[0] +
                dut.backend_issue_valid[1] +
                dut.backend_issue_valid[2] +
                dut.backend_issue_valid[3];
            decoded_this_cycle =
                dut.frontend_decode_fire[0] +
                dut.frontend_decode_fire[1] +
                dut.frontend_decode_fire[2];
            issued = issued + issued_this_cycle;
            decoded = decoded + decoded_this_cycle;
            case (issued_this_cycle)
                0: issue_width_0 = issue_width_0 + 1;
                1: issue_width_1 = issue_width_1 + 1;
                2: issue_width_2 = issue_width_2 + 1;
                3: issue_width_3 = issue_width_3 + 1;
                4: issue_width_4 = issue_width_4 + 1;
            endcase
            case (decoded_this_cycle)
                0: decode_width_0 = decode_width_0 + 1;
                1: decode_width_1 = decode_width_1 + 1;
                2: decode_width_2 = decode_width_2 + 1;
                3: decode_width_3 = decode_width_3 + 1;
            endcase
            case (dut.backend_retire_count)
                0: retire_width_0 = retire_width_0 + 1;
                1: retire_width_1 = retire_width_1 + 1;
                2: retire_width_2 = retire_width_2 + 1;
                3: retire_width_3 = retire_width_3 + 1;
            endcase
            if (dut.backend_dispatch_occupancy != 0) begin
                dispatch_nonempty = dispatch_nonempty + 1;
                if (issued_this_cycle == 0)
                    dispatch_nonempty_no_issue =
                        dispatch_nonempty_no_issue + 1;
            end
            if (dut.backend_dispatch_occupancy == 6)
                dispatch_full = dispatch_full + 1;
            if (dut.u_backend.raw_hazard != 0)
                raw_hazard_cycles = raw_hazard_cycles + 1;
            if ((ISSUE_WINDOW == 0) && raw_first_block) begin
                raw_first_block_cycles = raw_first_block_cycles + 1;
                if (raw_first_bundle)
                    raw_first_bundle_cycles =
                        raw_first_bundle_cycles + 1;
                else if (raw_first_completed)
                    raw_first_completed_cycles =
                        raw_first_completed_cycles + 1;
                else
                    raw_first_pending_cycles =
                        raw_first_pending_cycles + 1;
                if (raw_first_rs1 && raw_first_rs2)
                    raw_first_both_sources_cycles =
                        raw_first_both_sources_cycles + 1;
                else if (raw_first_rs1)
                    raw_first_rs1_cycles = raw_first_rs1_cycles + 1;
                else if (raw_first_rs2)
                    raw_first_rs2_cycles = raw_first_rs2_cycles + 1;
                if (raw_first_lane0)
                    raw_first_lane0_cycles =
                        raw_first_lane0_cycles + 1;
                else if (raw_first_lane1)
                    raw_first_lane1_cycles =
                        raw_first_lane1_cycles + 1;
                else
                    raw_first_lane2_cycles =
                        raw_first_lane2_cycles + 1;
                case (raw_first_op)
                    PERF_OP_BRANCH:
                        raw_first_blocked_branch =
                            raw_first_blocked_branch + 1;
                    PERF_OP_JUMP:
                        raw_first_blocked_jump =
                            raw_first_blocked_jump + 1;
                    PERF_OP_LOAD:
                        raw_first_blocked_load =
                            raw_first_blocked_load + 1;
                    PERF_OP_STORE:
                        raw_first_blocked_store =
                            raw_first_blocked_store + 1;
                    default:
                        raw_first_blocked_alu =
                            raw_first_blocked_alu + 1;
                endcase
            end else if ((ISSUE_WINDOW == 0) &&
                         (dut.u_backend.raw_hazard != 0)) begin
                raw_secondary_only_cycles =
                    raw_secondary_only_cycles + 1;
            end
            if (ISSUE_WINDOW != 0) begin
                window_unissued_entry_cycles =
                    window_unissued_entry_cycles +
                    trace_window_unissued;
                window_operand_ready_entry_cycles =
                    window_operand_ready_entry_cycles +
                    trace_window_operand_ready;
                window_eligible_entry_cycles =
                    window_eligible_entry_cycles +
                    trace_window_eligible;
                window_raw_block_entry_cycles =
                    window_raw_block_entry_cycles +
                    trace_window_raw_block;
                window_hard_block_entry_cycles =
                    window_hard_block_entry_cycles +
                    trace_window_hard_block;
                window_mem_order_block_entry_cycles =
                    window_mem_order_block_entry_cycles +
                    trace_window_mem_order_block;
                if (trace_window_unissued != 0) begin
                    window_nonempty_cycles =
                        window_nonempty_cycles + 1;
                    if (trace_window_eligible == 0) begin
                        window_no_eligible_cycles =
                            window_no_eligible_cycles + 1;
                        if (trace_window_raw_block != 0)
                            window_raw_stall_cycles =
                                window_raw_stall_cycles + 1;
                        if (trace_window_hard_block != 0)
                            window_hard_stall_cycles =
                                window_hard_stall_cycles + 1;
                        if (trace_window_mem_order_block != 0)
                            window_mem_order_stall_cycles =
                                window_mem_order_stall_cycles + 1;
                    end
                end
            end
            if (dut.u_backend.waw_hazard != 0)
                waw_hazard_cycles = waw_hazard_cycles + 1;
            if (dut.u_backend.read_port_hazard != 0)
                read_port_hazard_cycles = read_port_hazard_cycles + 1;
            if (dut.backend_write_busy != 0)
                write_busy_cycles = write_busy_cycles + 1;
            if (dut.backend_barrier)
                barrier_cycles = barrier_cycles + 1;
            if (dut.backend_retire_occupancy != 0) begin
                retire_nonempty = retire_nonempty + 1;
                if (dut.backend_retire_count == 0)
                    retire_nonempty_no_retire =
                        retire_nonempty_no_retire + 1;
                if (!dut.u_backend.queue_retire_valid[0]) begin
                    retire_head_incomplete = retire_head_incomplete + 1;
                    if (dut.u_backend.completed_entry_valid != 0)
                        retire_completed_behind_head =
                            retire_completed_behind_head + 1;
                end
            end
            if (dut.fetch_decode_valid == 0)
                frontend_empty = frontend_empty + 1;
            if ((dut.fetch_decode_valid != 0) &&
                (dut.frontend_decode_fire == 0))
                frontend_held = frontend_held + 1;
            if (dut.fetch_pipe_req_valid && !dut.fetch_pipe_req_ready)
                frontend_request_wait = frontend_request_wait + 1;
            if (dut.fetch_decode_valid == 0) begin
                if (dut.backend_decode_ready[0] &&
                    dut.frontend_decode_enable)
                    frontend_empty_backend_ready =
                        frontend_empty_backend_ready + 1;
                if (dut.backend_dispatch_occupancy == 0) begin
                    frontend_empty_dispatch_empty =
                        frontend_empty_dispatch_empty + 1;
                    if (dut.backend_decode_ready[0] &&
                        dut.frontend_decode_enable)
                        frontend_empty_dispatch_empty_backend_ready =
                            frontend_empty_dispatch_empty_backend_ready + 1;
                    if (dut.backend_retire_occupancy == 0)
                        frontend_empty_dispatch_empty_retire_empty =
                            frontend_empty_dispatch_empty_retire_empty + 1;
                end else begin
                    frontend_empty_dispatch_nonempty =
                        frontend_empty_dispatch_nonempty + 1;
                end
                if (dut.backend_dispatch_occupancy == 6)
                    frontend_empty_dispatch_full =
                        frontend_empty_dispatch_full + 1;
                if (dut.u_bus.g_ccx.u_bus.u_l1i.backend_state_q != 0)
                    frontend_empty_l1i_external_miss =
                        frontend_empty_l1i_external_miss + 1;
                else if (!dut.g_fetch_axi.u_fetch.consume_line_hit &&
                         (dut.g_fetch_axi.u_fetch.pending_valid_q ||
                          (dut.u_bus.g_ccx.u_bus.fetch_count_q != 0)))
                    frontend_empty_pending_no_external_miss =
                        frontend_empty_pending_no_external_miss + 1;
                if (dut.control_flush || dut.control_redirect)
                    frontend_control_empty = frontend_control_empty + 1;
                else if (dut.bp_fetch_stall)
                    frontend_bp_stall = frontend_bp_stall + 1;
                else if (!dut.g_fetch_axi.u_fetch.consume_line_hit &&
                         (dut.g_fetch_axi.u_fetch.pending_valid_q ||
                          (dut.u_bus.g_ccx.u_bus.fetch_count_q != 0)))
                    frontend_refill_wait = frontend_refill_wait + 1;
                else if (!dut.g_fetch_axi.u_fetch.consume_line_hit)
                    frontend_no_line = frontend_no_line + 1;
                else
                    frontend_other_empty = frontend_other_empty + 1;
            end
            if (dut.backend_mem_valid && !dut.backend_mem_ready)
                lsu_request_wait = lsu_request_wait + 1;
            if (trace_lsu_sent != 0)
                lsu_outstanding_cycles = lsu_outstanding_cycles + 1;
            if (dut.branch_resolved)
                branch_resolutions = branch_resolutions + 1;
            if (dut.branch_resolved && dut.branch_conditional)
                conditional_branch_resolutions =
                    conditional_branch_resolutions + 1;
            if (trace_pipe_conflict) begin
                pipe_conflicts = pipe_conflicts + 1;
                case (trace_conflict_pipe)
                    `OPENRV64_EXEC_PIPE_EX0:
                        pipe_conflicts_ex0 = pipe_conflicts_ex0 + 1;
                    `OPENRV64_EXEC_PIPE_EX1:
                        pipe_conflicts_ex1 = pipe_conflicts_ex1 + 1;
                    `OPENRV64_EXEC_PIPE_MEM:
                        pipe_conflicts_mem = pipe_conflicts_mem + 1;
                    `OPENRV64_EXEC_PIPE_MEM1:
                        pipe_conflicts_mem = pipe_conflicts_mem + 1;
                endcase
                case (trace_conflict_blocked_op)
                    PERF_OP_BRANCH:
                        conflict_blocked_branch =
                            conflict_blocked_branch + 1;
                    PERF_OP_JUMP:
                        conflict_blocked_jump =
                            conflict_blocked_jump + 1;
                    PERF_OP_LOAD:
                        conflict_blocked_load =
                            conflict_blocked_load + 1;
                    PERF_OP_STORE:
                        conflict_blocked_store =
                            conflict_blocked_store + 1;
                    default:
                        conflict_blocked_alu =
                            conflict_blocked_alu + 1;
                endcase
                if (((trace_conflict_older_op == PERF_OP_BRANCH) ||
                     (trace_conflict_older_op == PERF_OP_JUMP)) &&
                    (trace_conflict_blocked_op == PERF_OP_ALU))
                    conflict_pair_branch_alu =
                        conflict_pair_branch_alu + 1;
                else if ((trace_conflict_older_op == PERF_OP_ALU) &&
                         ((trace_conflict_blocked_op == PERF_OP_BRANCH) ||
                          (trace_conflict_blocked_op == PERF_OP_JUMP)))
                    conflict_pair_alu_branch =
                        conflict_pair_alu_branch + 1;
                else if (((trace_conflict_older_op == PERF_OP_BRANCH) ||
                          (trace_conflict_older_op == PERF_OP_JUMP)) &&
                         ((trace_conflict_blocked_op == PERF_OP_BRANCH) ||
                          (trace_conflict_blocked_op == PERF_OP_JUMP)))
                    conflict_pair_branch_branch =
                        conflict_pair_branch_branch + 1;
                else if ((trace_conflict_older_op == PERF_OP_ALU) &&
                         (trace_conflict_blocked_op == PERF_OP_ALU))
                    conflict_pair_alu_alu =
                        conflict_pair_alu_alu + 1;
                else if ((trace_conflict_older_op == PERF_OP_LOAD) &&
                         (trace_conflict_blocked_op == PERF_OP_LOAD))
                    conflict_pair_load_load =
                        conflict_pair_load_load + 1;
                else if ((trace_conflict_older_op == PERF_OP_STORE) &&
                         (trace_conflict_blocked_op == PERF_OP_LOAD))
                    conflict_pair_store_load =
                        conflict_pair_store_load + 1;
                else if ((trace_conflict_older_op == PERF_OP_STORE) &&
                         (trace_conflict_blocked_op == PERF_OP_STORE))
                    conflict_pair_store_store =
                        conflict_pair_store_store + 1;
                else
                    conflict_pair_other = conflict_pair_other + 1;
            end
            if (core_axi_arvalid || core_axi_awvalid || core_axi_wvalid)
                $fatal(1,
                    "physical CoreMark unexpectedly used residual core AXI");
            if (ccx_req_valid && ccx_req_ready) begin
                ccx_requests = ccx_requests + 1;
                if (ccx_req_source_id == `OPENRV64_CCX_SOURCE_ICACHE)
                    ccx_fetch_reads = ccx_fetch_reads + 1;
                else if (ccx_req_op == `OPENRV64_CCX_OP_READ)
                    ccx_data_reads = ccx_data_reads + 1;
                else if (ccx_req_op == `OPENRV64_CCX_OP_WRITE)
                    ccx_data_writes = ccx_data_writes + 1;
            end
            if (dut.backend_redirect)
                direction_corrections = direction_corrections + 1;
            if (dut.bp_target_mispredict)
                target_corrections = target_corrections + 1;
            if (dut.fetch_alt_restart_hit)
                lookaside_restart_hits = lookaside_restart_hits + 1;
            if (dut.fetch3_restart &&
                dut.g_fetch_axi.u_fetch.alt_restart_eligible_i)
                lookaside_eligible_restarts =
                    lookaside_eligible_restarts + 1;
            if (dut.icache_prefetch_valid &&
                (dut.g_fetch_axi.u_fetch.pair_predicted_valid_q ||
                 dut.g_fetch_axi.u_fetch.pair_unpredicted_valid_q))
                lookaside_pair_replacements =
                    lookaside_pair_replacements + 1;
            if (dut.g_fetch_axi.u_fetch.pair_stack_overflow)
                lookaside_pair_stack_overflows =
                    lookaside_pair_stack_overflows + 1;
            if ((FETCH_ALT_LOOKASIDE == 3) &&
                dut.icache_prefetch_valid &&
                !dut.g_fetch_axi.u_fetch.branch_sector_context_match_r) begin
                lookaside_sector_allocations =
                    lookaside_sector_allocations + 1;
                if (dut.g_fetch_axi.u_fetch.
                        branch_predicted_sector_source_valid_r)
                    lookaside_sector_predicted_free =
                        lookaside_sector_predicted_free + 1;
                if (dut.g_fetch_axi.u_fetch.
                        branch_unpredicted_sector_source_valid_r)
                    lookaside_sector_unpredicted_free =
                        lookaside_sector_unpredicted_free + 1;
            end
            if ((FETCH_ALT_LOOKASIDE == 3) &&
                dut.g_fetch_axi.u_fetch.alt_sector_response_tap_r)
                lookaside_sector_response_taps =
                    lookaside_sector_response_taps + 1;
            if ((FETCH_ALT_LOOKASIDE == 3) &&
                dut.g_fetch_axi.u_fetch.alt_sector_predicted_tap_r)
                lookaside_sector_predicted_taps =
                    lookaside_sector_predicted_taps + 1;
            if ((FETCH_ALT_LOOKASIDE == 3) &&
                dut.g_fetch_axi.u_fetch.alt_sector_unpredicted_tap_r)
                lookaside_sector_unpredicted_taps =
                    lookaside_sector_unpredicted_taps + 1;
            if ((FETCH_ALT_LOOKASIDE == 3) &&
                dut.g_fetch_axi.u_fetch.pair_req_fire)
                lookaside_sector_background_requests =
                    lookaside_sector_background_requests + 1;
            if ((FETCH_ALT_LOOKASIDE == 3) &&
                dut.g_fetch_axi.u_fetch.alt_sector_background_deferred)
                lookaside_sector_background_deferred =
                    lookaside_sector_background_deferred + 1;
            if (dut.g_fetch_axi.u_fetch.pair_saved_count >
                lookaside_pair_stack_max_saved)
                lookaside_pair_stack_max_saved =
                    dut.g_fetch_axi.u_fetch.pair_saved_count;
            if (dut.icache_prefetch_valid &&
                dut.g_fetch_axi.u_fetch.alt_valid_q[0] &&
                dut.g_fetch_axi.u_fetch.alt_valid_q[1] &&
                !dut.g_fetch_axi.u_fetch.branch_predicted_stashed_r &&
                !dut.g_fetch_axi.u_fetch.branch_unpredicted_stashed_r)
                lookaside_full_branch_allocations =
                    lookaside_full_branch_allocations + 1;
            if (dut.fetch_pipe_resp_valid &&
                dut.fetch_pipe_resp_stash &&
                !dut.fetch_pipe_resp_access_fault &&
                !dut.fetch_pipe_resp_page_fault &&
                !dut.g_fetch_axi.u_fetch.alt_prefetch_aged_r) begin
                lookaside_store_fills = lookaside_store_fills + 1;
                if (dut.g_fetch_axi.u_fetch.alt_fill_match_r)
                    lookaside_store_duplicate_fills =
                        lookaside_store_duplicate_fills + 1;
                else if (dut.g_fetch_axi.u_fetch.alt_free_found_r)
                    lookaside_store_free_fills =
                        lookaside_store_free_fills + 1;
                else
                    lookaside_store_evictions =
                        lookaside_store_evictions + 1;
            end
            if (dut.u_bus.g_ccx.u_bus.u_l1d.prefetch_issued_o)
                l1d_prefetch_issued = l1d_prefetch_issued + 1;
            if (dut.u_bus.g_ccx.u_bus.u_l1d.prefetch_useful_o)
                l1d_prefetch_useful = l1d_prefetch_useful + 1;
            if (dut.u_bus.g_ccx.u_bus.u_l1d.prefetch_late_o)
                l1d_prefetch_late = l1d_prefetch_late + 1;
            if (dut.u_bus.g_ccx.u_bus.u_l1d.prefetch_dropped_o)
                l1d_prefetch_dropped = l1d_prefetch_dropped + 1;
            if (dut.u_bus.g_ccx.u_bus.u_l1d.prefetch_useless_o)
                l1d_prefetch_useless = l1d_prefetch_useless + 1;
            if (dut.u_bus.g_ccx.u_bus.u_l1d.prefetch_depth_o >
                l1d_prefetch_max_depth)
                l1d_prefetch_max_depth =
                    dut.u_bus.g_ccx.u_bus.u_l1d.prefetch_depth_o;
        end

        if (!dbg_halted)
            $fatal(1,
                "full-CCX CoreMark timeout pc=%h instr=%h retired=%0d",
                dbg_pc, dbg_instr, retired);
        if (expected_a0_valid &&
            (dut.u_backend.u_gpr.regs[10] != expected_a0))
            $fatal(1, "full-CCX a0=%h expected=%h",
                dut.u_backend.u_gpr.regs[10], expected_a0);
        ipc = (cycles != 0) ? $itor(retired) / $itor(cycles) : 0.0;
        $display(
            "PERF_CCX_L2 mode=%0d confidence_gate=%0d bp=%0d completion_forward_mask=%0d branch_forward_mask=%0d full_forwarding=%0d relax_waw=%0d relax_hazards=%0d issue_window=%0d speculation_window=%0d cycles=%0d retired=%0d IPC=%0.4f a0=%016h l1i_bytes=%0d l1d_bytes=%0d l2_bytes=%0d l2_ways=%0d ram_bytes=%0d",
            FETCH_ALT_LOOKASIDE, FETCH_ALT_CONFIDENCE_GATE, BP_TYPE,
            COMPLETION_FORWARD_MASK, BRANCH_COMPLETION_FORWARD_MASK,
            ENABLE_FULL_FORWARDING, RELAX_WAW, RELAX_HAZARDS,
            ISSUE_WINDOW, SPECULATION_WINDOW,
            cycles, retired, ipc,
            dut.u_backend.u_gpr.regs[10], L1I_CACHE_BYTES,
            L1D_CACHE_BYTES, L2_BYTES, L2_WAYS, RAM_BYTES);
        $display(
            "PERF_CCX_L2_TRAFFIC ccx_requests=%0d fetch_reads=%0d data_reads=%0d data_writes=%0d l2_axi_reads=%0d l2_axi_read_beats=%0d l2_axi_writes=%0d l2_axi_write_beats=%0d",
            ccx_requests, ccx_fetch_reads, ccx_data_reads,
            ccx_data_writes, u_ram.read_transactions,
            u_ram.read_beats, u_ram.write_transactions,
            u_ram.write_beats);
        $display(
            "PERF_CCX_L2_FRONTEND direction_corrections=%0d target_corrections=%0d lookaside_restart_hits=%0d",
            direction_corrections, target_corrections,
            lookaside_restart_hits);
        $display(
            "PERF_CCX_L2_LOOKASIDE pair_stack_depth=%0d eligible_restarts=%0d hits=%0d pair_overlaps=%0d pair_stack_overflows=%0d pair_stack_max_saved=%0d fills=%0d duplicate_fills=%0d free_fills=%0d evictions=%0d full_branch_allocations=%0d",
            FETCH_ALT_PAIR_STACK_DEPTH,
            lookaside_eligible_restarts, lookaside_restart_hits,
            lookaside_pair_replacements, lookaside_pair_stack_overflows,
            lookaside_pair_stack_max_saved, lookaside_store_fills,
            lookaside_store_duplicate_fills, lookaside_store_free_fills,
            lookaside_store_evictions, lookaside_full_branch_allocations);
        $display(
            "PERF_CCX_L2_SECTOR allocations=%0d predicted_free=%0d unpredicted_free=%0d response_taps=%0d predicted_taps=%0d unpredicted_taps=%0d background_requests=%0d background_deferred_cycles=%0d",
            lookaside_sector_allocations,
            lookaside_sector_predicted_free,
            lookaside_sector_unpredicted_free,
            lookaside_sector_response_taps,
            lookaside_sector_predicted_taps,
            lookaside_sector_unpredicted_taps,
            lookaside_sector_background_requests,
            lookaside_sector_background_deferred);
        $display(
            "PERF_CCX_L2_STASH_STALL episodes=%0d completed=%0d interrupted=%0d active=%0d requested=%0d stalled=%0d completed_stalled=%0d interrupted_stalled=%0d exposed_cycles=%0d completed_stall_cycles=%0d interrupted_stall_cycles=%0d same_line_cycles=%0d next_line_cycles=%0d preview_instr=%0d request_delay_sum=%0d request_delay_max=%0d response_delay_sum=%0d response_delay_max=%0d refill_latency_sum=%0d refill_latency_max=%0d",
            stash_trace_episodes, stash_trace_completed,
            stash_trace_interrupted, stash_trace_active,
            stash_trace_requested, stash_trace_stalled,
            stash_trace_completed_stalled,
            stash_trace_interrupted_stalled,
            stash_trace_exposed_stall_cycles,
            stash_trace_completed_stall_cycles,
            stash_trace_interrupted_stall_cycles,
            stash_trace_same_line_stall_cycles,
            stash_trace_next_line_stall_cycles,
            stash_trace_preview_instructions,
            stash_trace_request_delay_sum,
            stash_trace_request_delay_max,
            stash_trace_response_delay_sum,
            stash_trace_response_delay_max,
            stash_trace_refill_latency_sum,
            stash_trace_refill_latency_max);
        $display(
            "PERF_CCX_L2_STASH_OFFSET hits=%0d,%0d,%0d,%0d stalled=%0d,%0d,%0d,%0d stall_cycles=%0d,%0d,%0d,%0d",
            stash_trace_offset_hits[0], stash_trace_offset_hits[1],
            stash_trace_offset_hits[2], stash_trace_offset_hits[3],
            stash_trace_offset_stalled[0],
            stash_trace_offset_stalled[1],
            stash_trace_offset_stalled[2],
            stash_trace_offset_stalled[3],
            stash_trace_offset_stall_cycles[0],
            stash_trace_offset_stall_cycles[1],
            stash_trace_offset_stall_cycles[2],
            stash_trace_offset_stall_cycles[3]);
        $display(
            "PERF_CCX_L2_STASH_SECTOR hits=%0d,%0d stalled=%0d,%0d stall_cycles=%0d,%0d",
            stash_trace_sector_hits[0], stash_trace_sector_hits[1],
            stash_trace_sector_stalled[0],
            stash_trace_sector_stalled[1],
            stash_trace_sector_stall_cycles[0],
            stash_trace_sector_stall_cycles[1]);
        $display(
            "PERF_CCX_L2_PREFETCH enabled=%0d streams=%0d adaptive=%0d max_depth_cfg=%0d max_depth_seen=%0d outstanding=%0d reserve=%0d issued=%0d useful=%0d late=%0d dropped=%0d useless=%0d",
            L1D_PREFETCH_ENABLE, L1D_PREFETCH_STREAMS,
            L1D_PREFETCH_ADAPTIVE_ENABLE,
            L1D_PREFETCH_MAX_DISTANCE, l1d_prefetch_max_depth,
            L1D_PREFETCH_OUTSTANDING, L1D_PREFETCH_DEMAND_RESERVE,
            l1d_prefetch_issued,
            l1d_prefetch_useful, l1d_prefetch_late,
            l1d_prefetch_dropped, l1d_prefetch_useless);
        $display(
            "PERF_CCX_L2_WIDTH issued=%0d decoded=%0d issue_w0=%0d issue_w1=%0d issue_w2=%0d issue_w3=%0d issue_w4=%0d decode_w0=%0d decode_w1=%0d decode_w2=%0d decode_w3=%0d retire_w0=%0d retire_w1=%0d retire_w2=%0d retire_w3=%0d",
            issued, decoded,
            issue_width_0, issue_width_1, issue_width_2, issue_width_3,
            issue_width_4,
            decode_width_0, decode_width_1, decode_width_2, decode_width_3,
            retire_width_0, retire_width_1, retire_width_2, retire_width_3);
        $display(
            "PERF_CCX_L2_BACKEND dispatch_nonempty=%0d dispatch_nonempty_no_issue=%0d dispatch_full=%0d raw_hazard=%0d waw_hazard=%0d read_port_hazard=%0d write_busy=%0d barrier=%0d",
            dispatch_nonempty, dispatch_nonempty_no_issue, dispatch_full,
            raw_hazard_cycles, waw_hazard_cycles, read_port_hazard_cycles,
            write_busy_cycles, barrier_cycles);
        $display(
            "PERF_CCX_L2_RAW first_block=%0d pending=%0d bundle=%0d completed=%0d secondary_only=%0d rs1=%0d rs2=%0d both=%0d lane0=%0d lane1=%0d lane2=%0d blocked_alu=%0d blocked_branch=%0d blocked_jump=%0d blocked_load=%0d blocked_store=%0d",
            raw_first_block_cycles, raw_first_pending_cycles,
            raw_first_bundle_cycles, raw_first_completed_cycles,
            raw_secondary_only_cycles, raw_first_rs1_cycles,
            raw_first_rs2_cycles, raw_first_both_sources_cycles,
            raw_first_lane0_cycles, raw_first_lane1_cycles,
            raw_first_lane2_cycles, raw_first_blocked_alu,
            raw_first_blocked_branch, raw_first_blocked_jump,
            raw_first_blocked_load, raw_first_blocked_store);
        $display(
            "PERF_CCX_L2_WINDOW enabled=%0d speculation=%0d nonempty_cycles=%0d no_eligible_cycles=%0d raw_stall_cycles=%0d hard_stall_cycles=%0d mem_order_stall_cycles=%0d unissued_entry_cycles=%0d operand_ready_entry_cycles=%0d eligible_entry_cycles=%0d raw_block_entry_cycles=%0d hard_block_entry_cycles=%0d mem_order_block_entry_cycles=%0d",
            ISSUE_WINDOW, SPECULATION_WINDOW, window_nonempty_cycles,
            window_no_eligible_cycles, window_raw_stall_cycles,
            window_hard_stall_cycles, window_mem_order_stall_cycles,
            window_unissued_entry_cycles,
            window_operand_ready_entry_cycles,
            window_eligible_entry_cycles,
            window_raw_block_entry_cycles,
            window_hard_block_entry_cycles,
            window_mem_order_block_entry_cycles);
        $display(
            "PERF_CCX_L2_RETIRE nonempty=%0d nonempty_no_retire=%0d head_incomplete=%0d completed_behind_head=%0d",
            retire_nonempty, retire_nonempty_no_retire,
            retire_head_incomplete, retire_completed_behind_head);
        $display(
            "PERF_CCX_L2_FETCH empty=%0d held=%0d request_wait=%0d control_empty=%0d refill_wait=%0d no_line=%0d bp_stall=%0d other_empty=%0d",
            frontend_empty, frontend_held, frontend_request_wait,
            frontend_control_empty, frontend_refill_wait, frontend_no_line,
            frontend_bp_stall, frontend_other_empty);
        $display(
            "PERF_CCX_L2_FETCH_CAUSAL empty_backend_ready=%0d empty_dispatch_empty=%0d empty_dispatch_empty_backend_ready=%0d empty_dispatch_empty_retire_empty=%0d empty_dispatch_nonempty=%0d empty_dispatch_full=%0d empty_l1i_external_miss=%0d empty_pending_no_external_miss=%0d",
            frontend_empty_backend_ready, frontend_empty_dispatch_empty,
            frontend_empty_dispatch_empty_backend_ready,
            frontend_empty_dispatch_empty_retire_empty,
            frontend_empty_dispatch_nonempty, frontend_empty_dispatch_full,
            frontend_empty_l1i_external_miss,
            frontend_empty_pending_no_external_miss);
        $display(
            "PERF_CCX_L2_LSU request_wait=%0d outstanding=%0d branch_resolutions=%0d conditional_branch_resolutions=%0d",
            lsu_request_wait, lsu_outstanding_cycles,
            branch_resolutions, conditional_branch_resolutions);
        $display(
            "PERF_CCX_L2_CONFLICT total=%0d ex0=%0d ex1=%0d mem=%0d blocked_alu=%0d blocked_branch=%0d blocked_jump=%0d blocked_load=%0d blocked_store=%0d",
            pipe_conflicts, pipe_conflicts_ex0, pipe_conflicts_ex1,
            pipe_conflicts_mem, conflict_blocked_alu,
            conflict_blocked_branch, conflict_blocked_jump,
            conflict_blocked_load, conflict_blocked_store);
        $display(
            "PERF_CCX_L2_CONFLICT_PAIR branch_alu=%0d alu_branch=%0d branch_branch=%0d alu_alu=%0d load_load=%0d store_load=%0d store_store=%0d other=%0d",
            conflict_pair_branch_alu, conflict_pair_alu_branch,
            conflict_pair_branch_branch, conflict_pair_alu_alu,
            conflict_pair_load_load, conflict_pair_store_load,
            conflict_pair_store_store, conflict_pair_other);
        $display("PASS: 3P L1I/L1D -> CCX -> L2 -> 16 MiB AXI SRAM");
        $finish;
    end
endmodule
