`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "complex/protocol/defs.v"

module tb_top_4pf #(
    parameter integer RETIRE_DEPTH = 16
);
    localparam [63:0] RESET_VECTOR = 64'h0000_0000_8000_0000;
    localparam [63:0] DAXPY_PASS = 64'h4441_5850_595f_4f4b;
    localparam [63:0] FMADD32_PASS = 64'h464d_3332_5f4f_4b21;
    localparam [63:0] FPFAULT_PASS = 64'h4650_464c_545f_4f4b;
    localparam integer DAXPY_ELEMENTS = 256;

    reg clk;
    reg rst_n;
    wire mem_valid;
    reg mem_ready;
    wire mem_write;
    wire [63:0] mem_addr;
    wire [63:0] mem_wdata;
    wire [7:0] mem_wstrb;
    reg [63:0] mem_rdata;
    reg mem_error;
    wire [63:0] dbg_pc;
    wire [31:0] dbg_instr;
    wire dbg_halted;
    wire wfi_sleep;
    wire trace_retire_exception;
    wire [4:0] trace_retire_cause;

    reg [255:0] image [0:2047];
    reg [63:0] memory [0:8191];
    reg pending_q;
    reg pending_write_q;
    reg [63:0] pending_addr_q;
    reg [63:0] pending_wdata_q;
    reg [7:0] pending_wstrb_q;
    integer i;
    integer cycles;
    integer test_cycle;
    integer fpu_requests [0:3];
    integer fpu_results [0:3];
    integer fpu_outstanding [0:3];
    integer fpu_max_outstanding [0:3];
    integer fp_transfer_max_occupancy [0:3];
    integer trace_phase_cycles [0:3];
    integer trace_fpu_issue_cycles [0:3];
    integer trace_fpu_no_candidate_cycles [0:3];
    integer trace_fpu_forwardable_cycles [0:3];
    integer trace_fpu_producer_pending_cycles [0:3];
    integer trace_fpu_global_block_cycles [0:3];
    integer trace_fpu_backpressure_cycles [0:3];
    integer trace_fpu_other_idle_cycles [0:3];
    integer trace_frontend_empty_cycles [0:3];
    integer trace_window_full_cycles [0:3];
    integer trace_mem_accept_cycles [0:3];
    integer trace_mem_wait_cycles [0:3];
    integer trace_mem_order_block_cycles [0:3];
    integer trace_retire_zero_nonempty_cycles [0:3];
    integer trace_retire_head_incomplete_cycles [0:3];
    integer trace_retire_head_fp_load_cycles [0:3];
    integer trace_retire_head_fp_compute_cycles [0:3];
    integer trace_retire_head_fp_store_cycles [0:3];
    integer trace_retire_head_other_cycles [0:3];
    integer trace_completed_behind_head_cycles [0:3];
    integer trace_retire_ready_block_cycles [0:3];
    integer trace_store_source_block_cycles [0:3];
    integer trace_store_source_forwardable_cycles [0:3];
    integer fpu_first_request_cycle [0:3];
    integer fpu_last_request_cycle [0:3];
    integer fpu_phase;
    integer fpu_reset_index;
    integer perf_index;
    integer perf_unroll;
    integer perf_word;
    reg [63:0] perf_cycles_value;
    reg [63:0] perf_instret_value;
    integer image_line;
    integer image_word;
    reg [1023:0] image_path;
    reg fault_mode;
    reg fmadd32_mode;
    reg [63:0] expected_marker;
    reg saw_illegal;
    reg saw_load_access;
    reg saw_store_access;

    openrv64_rv64_top_4pf #(
        .RESET_VECTOR(RESET_VECTOR),
        .RETIRE_DEPTH(RETIRE_DEPTH),
        .BUS_CONFIG(`OPENRV64_BUS_GEN),
        .ENABLE_RV64M(1),
        .ENABLE_RV64F(1),
        .ENABLE_RV64D(1),
        .ENABLE_RV64A(1),
        .ENABLE_ISSUE_WINDOW(1),
        .ENABLE_SPECULATION_WINDOW(1),
        .ENABLE_POSTED_STORES(0),
        .ENABLE_L1I(0),
        .ENABLE_L1D(0),
        .L1D_CACHEABLE_BASE(RESET_VECTOR),
        .L1D_CACHEABLE_SIZE(64'h0000_0000_0001_0000),
        .ENABLE_TRACE(1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .mem_valid(mem_valid), .mem_ready(mem_ready),
        .mem_write(mem_write), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata), .mem_error(mem_error),
        .pair512_req_ready(1'b0), .pair512_resp_valid(1'b0),
        .pair512_resp_predicted_addr(64'd0),
        .pair512_resp_predicted_data({`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
        .pair512_resp_unpredicted_addr(64'd0),
        .pair512_resp_unpredicted_data({`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
        .pair1024_req_ready(1'b0), .pair1024_resp_valid(1'b0),
        .pair1024_resp_predicted_addr(64'd0),
        .pair1024_resp_predicted_data(
            {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}}),
        .pair1024_resp_unpredicted_addr(64'd0),
        .pair1024_resp_unpredicted_data(
            {`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}}),
        .m_axi_arready(1'b0),
        .m_axi_rid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
        .m_axi_rdata({`OPENRV64_AXI_DATA_WIDTH{1'b0}}),
        .m_axi_rresp(2'b00), .m_axi_rlast(1'b0), .m_axi_rvalid(1'b0),
        .m_axi_awready(1'b0), .m_axi_wready(1'b0),
        .m_axi_bid({`OPENRV64_AXI_ID_WIDTH{1'b0}}),
        .m_axi_bresp(2'b00), .m_axi_bvalid(1'b0),
        .ccx_req_ready(1'b1), .ccx_wdata_ready(1'b1),
        .ccx_resp_valid(1'b0),
        .ccx_resp_hart_id({`OPENRV64_CCX_HART_ID_WIDTH{1'b0}}),
        .ccx_resp_txn_id({`OPENRV64_CCX_TXN_ID_WIDTH{1'b0}}),
        .ccx_resp_source_id({`OPENRV64_CCX_SOURCE_ID_WIDTH{1'b0}}),
        .ccx_resp_beat_index({`OPENRV64_CCX_BEAT_INDEX_WIDTH{1'b0}}),
        .ccx_resp_last(1'b0),
        .ccx_resp_rdata({`OPENRV64_CCX_LINE_DATA_WIDTH{1'b0}}),
        .ccx_resp_error(1'b0), .ccx_resp_sc_success(1'b0),
        .coherent_reservation_clear_i(1'b0),
        .l1d_probe_valid_i(1'b0),
        .l1d_probe_addr_i(64'd0),
        .irq_m_software(1'b0), .irq_m_timer(1'b0),
        .irq_m_external(1'b0), .irq_s_software(1'b0),
        .irq_s_timer(1'b0), .irq_s_external(1'b0),
        .dbg_pc(dbg_pc), .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted), .wfi_sleep_o(wfi_sleep),
        .trace_retire_exception(trace_retire_exception),
        .trace_retire_cause(trace_retire_cause)
    );

    always #5 clk = ~clk;

    wire [12:0] pending_word = pending_addr_q[15:3];
    always @* begin
        mem_ready = pending_q;
        mem_rdata = pending_q ? memory[pending_word] : 64'd0;
        mem_error = pending_q &&
                    (pending_addr_q[63:16] != RESET_VECTOR[63:16]);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_q <= 1'b0;
            pending_write_q <= 1'b0;
            pending_addr_q <= 64'd0;
            pending_wdata_q <= 64'd0;
            pending_wstrb_q <= 8'd0;
        end else begin
            if (pending_q) begin
                if (pending_write_q && !mem_error) begin
                    for (i = 0; i < 8; i = i + 1)
                        if (pending_wstrb_q[i])
                            memory[pending_word][i*8 +: 8] <=
                                pending_wdata_q[i*8 +: 8];
                end
                pending_q <= 1'b0;
            end else if (mem_valid) begin
                pending_q <= 1'b1;
                pending_write_q <= mem_write;
                pending_addr_q <= mem_addr;
                pending_wdata_q <= mem_wdata;
                pending_wstrb_q <= mem_wstrb;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && (|dut.u_backend.pipe_unsupported))
            $display("4PF unsupported route valid=%b unsupported=%b pc0=%016x instr0=%08x pc1=%016x instr1=%08x pc2=%016x instr2=%08x pc3=%016x instr3=%08x",
                     dut.u_backend.pipe_valid,
                     dut.u_backend.pipe_unsupported,
                     dut.u_backend.pipe_payload[274 +: 64],
                     dut.u_backend.pipe_payload[242 +: 32],
                     dut.u_backend.pipe_payload[402 + 274 +: 64],
                     dut.u_backend.pipe_payload[402 + 242 +: 32],
                     dut.u_backend.pipe_payload[2*402 + 274 +: 64],
                     dut.u_backend.pipe_payload[2*402 + 242 +: 32],
                     dut.u_backend.pipe_payload[3*402 + 274 +: 64],
                     dut.u_backend.pipe_payload[3*402 + 242 +: 32]);
    end

    /* Measure actual accepted/completed computational FPU traffic. */
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            test_cycle <= 0;
            fpu_phase = -1;
            for (fpu_reset_index = 0; fpu_reset_index < 4;
                 fpu_reset_index = fpu_reset_index + 1) begin
                fpu_requests[fpu_reset_index] <= 0;
                fpu_results[fpu_reset_index] <= 0;
                fpu_outstanding[fpu_reset_index] <= 0;
                fpu_max_outstanding[fpu_reset_index] <= 0;
                fp_transfer_max_occupancy[fpu_reset_index] <= 0;
                trace_phase_cycles[fpu_reset_index] <= 0;
                trace_fpu_issue_cycles[fpu_reset_index] <= 0;
                trace_fpu_no_candidate_cycles[fpu_reset_index] <= 0;
                trace_fpu_forwardable_cycles[fpu_reset_index] <= 0;
                trace_fpu_producer_pending_cycles[fpu_reset_index] <= 0;
                trace_fpu_global_block_cycles[fpu_reset_index] <= 0;
                trace_fpu_backpressure_cycles[fpu_reset_index] <= 0;
                trace_fpu_other_idle_cycles[fpu_reset_index] <= 0;
                trace_frontend_empty_cycles[fpu_reset_index] <= 0;
                trace_window_full_cycles[fpu_reset_index] <= 0;
                trace_mem_accept_cycles[fpu_reset_index] <= 0;
                trace_mem_wait_cycles[fpu_reset_index] <= 0;
                trace_mem_order_block_cycles[fpu_reset_index] <= 0;
                trace_retire_zero_nonempty_cycles[fpu_reset_index] <= 0;
                trace_retire_head_incomplete_cycles[fpu_reset_index] <= 0;
                trace_retire_head_fp_load_cycles[fpu_reset_index] <= 0;
                trace_retire_head_fp_compute_cycles[fpu_reset_index] <= 0;
                trace_retire_head_fp_store_cycles[fpu_reset_index] <= 0;
                trace_retire_head_other_cycles[fpu_reset_index] <= 0;
                trace_completed_behind_head_cycles[fpu_reset_index] <= 0;
                trace_retire_ready_block_cycles[fpu_reset_index] <= 0;
                trace_store_source_block_cycles[fpu_reset_index] <= 0;
                trace_store_source_forwardable_cycles[fpu_reset_index] <= 0;
                fpu_first_request_cycle[fpu_reset_index] <= 0;
                fpu_last_request_cycle[fpu_reset_index] <= 0;
            end
        end else begin
            test_cycle <= test_cycle + 1;
            fpu_phase = dut.u_backend.u_gpr.regs[20] - 1;
            if ((fpu_phase >= 0) && (fpu_phase < 4)) begin
                trace_phase_cycles[fpu_phase] <=
                    trace_phase_cycles[fpu_phase] + 1;
                if (dut.u_backend.fp_transfer_count >
                    fp_transfer_max_occupancy[fpu_phase])
                        fp_transfer_max_occupancy[fpu_phase] <=
                        dut.u_backend.fp_transfer_count;

                if (dut.u_backend.fpu_valid && dut.u_backend.fpu_ready)
                    trace_fpu_issue_cycles[fpu_phase] <=
                        trace_fpu_issue_cycles[fpu_phase] + 1;
                else if (dut.u_backend.u_fp_dispatch.trace_compute_unissued_count == 0)
                    trace_fpu_no_candidate_cycles[fpu_phase] <=
                        trace_fpu_no_candidate_cycles[fpu_phase] + 1;
                else if (dut.u_backend.u_fp_dispatch.trace_compute_eligible_count != 0) begin
                    if (dut.u_backend.fpu_valid &&
                        !dut.u_backend.fpu_ready)
                        trace_fpu_backpressure_cycles[fpu_phase] <=
                            trace_fpu_backpressure_cycles[fpu_phase] + 1;
                    else
                        trace_fpu_other_idle_cycles[fpu_phase] <=
                            trace_fpu_other_idle_cycles[fpu_phase] + 1;
                end else if (dut.u_backend.u_fp_dispatch.trace_compute_operand_ready_count != 0)
                    trace_fpu_global_block_cycles[fpu_phase] <=
                        trace_fpu_global_block_cycles[fpu_phase] + 1;
                else if (dut.u_backend.u_fp_dispatch.trace_compute_forwardable_count != 0)
                    trace_fpu_forwardable_cycles[fpu_phase] <=
                        trace_fpu_forwardable_cycles[fpu_phase] + 1;
                else
                    trace_fpu_producer_pending_cycles[fpu_phase] <=
                        trace_fpu_producer_pending_cycles[fpu_phase] + 1;

                if (!(|dut.fetch_decode_valid))
                    trace_frontend_empty_cycles[fpu_phase] <=
                        trace_frontend_empty_cycles[fpu_phase] + 1;
                if (dut.u_backend.dispatch_occupancy_o == RETIRE_DEPTH)
                    trace_window_full_cycles[fpu_phase] <=
                        trace_window_full_cycles[fpu_phase] + 1;
                if (dut.backend_mem_valid && dut.backend_mem_ready)
                    trace_mem_accept_cycles[fpu_phase] <=
                        trace_mem_accept_cycles[fpu_phase] + 1;
                if (dut.backend_mem_valid && !dut.backend_mem_ready)
                    trace_mem_wait_cycles[fpu_phase] <=
                        trace_mem_wait_cycles[fpu_phase] + 1;
                if (dut.u_backend.u_dispatch.trace_mem_order_block_count != 0)
                    trace_mem_order_block_cycles[fpu_phase] <=
                        trace_mem_order_block_cycles[fpu_phase] + 1;

                if ((dut.u_backend.retire_occupancy_o != 0) &&
                    (dut.u_backend.retire_count_o == 0))
                    trace_retire_zero_nonempty_cycles[fpu_phase] <=
                        trace_retire_zero_nonempty_cycles[fpu_phase] + 1;
                if ((dut.u_backend.retire_occupancy_o != 0) &&
                    !dut.u_backend.queue_retire_valid[0]) begin
                    trace_retire_head_incomplete_cycles[fpu_phase] <=
                        trace_retire_head_incomplete_cycles[fpu_phase] + 1;
                    if (dut.u_backend.fp_entry_load[
                            dut.u_backend.next_retire_slot])
                        trace_retire_head_fp_load_cycles[fpu_phase] <=
                            trace_retire_head_fp_load_cycles[fpu_phase] + 1;
                    else if (dut.u_backend.fp_entry_compute[
                                 dut.u_backend.next_retire_slot])
                        trace_retire_head_fp_compute_cycles[fpu_phase] <=
                            trace_retire_head_fp_compute_cycles[fpu_phase] + 1;
                    else if (dut.u_backend.fp_entry_store[
                                 dut.u_backend.next_retire_slot])
                        trace_retire_head_fp_store_cycles[fpu_phase] <=
                            trace_retire_head_fp_store_cycles[fpu_phase] + 1;
                    else
                        trace_retire_head_other_cycles[fpu_phase] <=
                            trace_retire_head_other_cycles[fpu_phase] + 1;
                    if (|dut.u_backend.completed_entry_valid)
                        trace_completed_behind_head_cycles[fpu_phase] <=
                            trace_completed_behind_head_cycles[fpu_phase] + 1;
                end
                if (dut.u_backend.queue_retire_valid[0] &&
                    !dut.u_backend.queue_retire_accept[0])
                    trace_retire_ready_block_cycles[fpu_phase] <=
                        trace_retire_ready_block_cycles[fpu_phase] + 1;
                if (dut.u_backend.u_fp_dispatch.trace_store_source_block_count != 0)
                    trace_store_source_block_cycles[fpu_phase] <=
                        trace_store_source_block_cycles[fpu_phase] + 1;
                if (dut.u_backend.u_fp_dispatch.trace_store_source_forwardable_count != 0)
                    trace_store_source_forwardable_cycles[fpu_phase] <=
                        trace_store_source_forwardable_cycles[fpu_phase] + 1;
                if (dut.u_backend.fpu_valid && dut.u_backend.fpu_ready) begin
                    if (fpu_requests[fpu_phase] == 0)
                        fpu_first_request_cycle[fpu_phase] <= test_cycle;
                    fpu_last_request_cycle[fpu_phase] <= test_cycle;
                    fpu_requests[fpu_phase] <=
                        fpu_requests[fpu_phase] + 1;
                end
                if (dut.u_backend.fpu_result_valid &&
                    dut.u_backend.fpu_result_ready)
                    fpu_results[fpu_phase] <= fpu_results[fpu_phase] + 1;

                case ({dut.u_backend.fpu_valid && dut.u_backend.fpu_ready,
                       dut.u_backend.fpu_result_valid &&
                           dut.u_backend.fpu_result_ready})
                    2'b10: begin
                        fpu_outstanding[fpu_phase] <=
                            fpu_outstanding[fpu_phase] + 1;
                        if ((fpu_outstanding[fpu_phase] + 1) >
                            fpu_max_outstanding[fpu_phase])
                            fpu_max_outstanding[fpu_phase] <=
                                fpu_outstanding[fpu_phase] + 1;
                    end
                    2'b01: fpu_outstanding[fpu_phase] <=
                                fpu_outstanding[fpu_phase] - 1;
                    default: fpu_outstanding[fpu_phase] <=
                                 fpu_outstanding[fpu_phase];
                endcase
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            saw_illegal <= 1'b0;
            saw_load_access <= 1'b0;
            saw_store_access <= 1'b0;
        end else if (trace_retire_exception) begin
            if (trace_retire_cause == 5'd2)
                saw_illegal <= 1'b1;
            if (trace_retire_cause == 5'd5)
                saw_load_access <= 1'b1;
            if (trace_retire_cause == 5'd7)
                saw_store_access <= 1'b1;
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        pending_q = 1'b0;
        fault_mode = $test$plusargs("faults");
        fmadd32_mode = $test$plusargs("fmadd32");
        if (fault_mode && fmadd32_mode)
            $fatal(1, "4PF test modes faults and fmadd32 are exclusive");
        image_path = "sim/fp-daxpy.memh";
        if (!$value$plusargs("memh=%s", image_path)) begin
            if (fault_mode)
                image_path = "sim/fp-faults.memh";
            else if (fmadd32_mode)
                image_path = "sim/fp-fmadd32.memh";
        end
        for (i = 0; i < 8192; i = i + 1)
            memory[i] = 64'd0;
        $readmemh(image_path, image);
        for (image_line = 0; image_line < 2048;
             image_line = image_line + 1)
            for (image_word = 0; image_word < 4;
                 image_word = image_word + 1)
                memory[image_line*4 + image_word] = image[image_line][
                    image_word*64 +: 64];

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        for (cycles = 0; cycles < 100000 && !dbg_halted;
             cycles = cycles + 1)
            @(posedge clk);

        if (!dbg_halted)
            $fatal(1, "4PF DAXPY timed out pc=%016x instr=%08x", dbg_pc,
                   dbg_instr);
        expected_marker = fault_mode ? FPFAULT_PASS :
                          (fmadd32_mode ? FMADD32_PASS : DAXPY_PASS);
        if (dut.u_backend.u_gpr.regs[10] !== expected_marker)
            $fatal(1, "4PF payload marker=%016x expected=%016x phase=%0d a1=%016x a2=%016x a3=%016x a4=%016x mcause=%016x mtval=%016x mepc=%016x seen=%b%b%b",
                   dut.u_backend.u_gpr.regs[10],
                   expected_marker,
                   dut.u_backend.u_gpr.regs[8],
                   dut.u_backend.u_gpr.regs[11],
                   dut.u_backend.u_gpr.regs[12],
                   dut.u_backend.u_gpr.regs[13],
                   dut.u_backend.u_gpr.regs[14],
                   dut.u_csrs.mcause_q,
                   dut.u_csrs.mtval_q, dut.u_csrs.mepc_q,
                   saw_load_access, saw_store_access, saw_illegal);
        if (dut.u_fp_csrs.fflags_q !== 5'd0)
            $fatal(1, "4PF unexpected fflags=%02x",
                   dut.u_fp_csrs.fflags_q);
        if (fault_mode &&
            !(saw_load_access && saw_store_access && saw_illegal))
            $fatal(1, "4PF fault coverage load=%b store=%b illegal=%b",
                   saw_load_access, saw_store_access, saw_illegal);

        if (fault_mode)
            $display("PASS: 4PF FP load/store faults and unsupported standard illegal trap");
        else if (fmadd32_mode) begin
            perf_word = (dut.u_backend.u_gpr.regs[11] >> 3) & 13'h1fff;
            perf_cycles_value = memory[perf_word];
            perf_instret_value = memory[perf_word + 1];
            if (perf_cycles_value == 0)
                $fatal(1, "4PF FMADD32 returned zero cycles");
            if ((fpu_requests[0] != dut.u_backend.u_gpr.regs[13]) ||
                (fpu_results[0] != dut.u_backend.u_gpr.regs[13]))
                $fatal(1, "4PF FMADD32 handshakes requests=%0d results=%0d expected=%0d",
                       fpu_requests[0], fpu_results[0],
                       dut.u_backend.u_gpr.regs[13]);
            $display("PERF: FMADD32 loops=%0d fmadds=%0d cycles=%0d instret=%0d cycles_per_fmadd_x1000=%0d ipc_x1000=%0d fpu_requests=%0d fpu_results=%0d max_inflight=%0d average_request_interval_x1000=%0d",
                     dut.u_backend.u_gpr.regs[12],
                     dut.u_backend.u_gpr.regs[13],
                     perf_cycles_value, perf_instret_value,
                     (perf_cycles_value * 1000) /
                         dut.u_backend.u_gpr.regs[13],
                     (perf_instret_value * 1000) / perf_cycles_value,
                     fpu_requests[0], fpu_results[0],
                     fpu_max_outstanding[0],
                     ((fpu_last_request_cycle[0] -
                       fpu_first_request_cycle[0]) * 1000) /
                         (fpu_requests[0] - 1));
            $display("STALL: FMADD32 phase_cycles=%0d fpu_issue=%0d no_compute_candidate=%0d forwarding_ready=%0d producer_pending=%0d global_block=%0d fpu_backpressure=%0d other=%0d frontend_empty=%0d window_full=%0d retire_head_incomplete=%0d",
                     trace_phase_cycles[0], trace_fpu_issue_cycles[0],
                     trace_fpu_no_candidate_cycles[0],
                     trace_fpu_forwardable_cycles[0],
                     trace_fpu_producer_pending_cycles[0],
                     trace_fpu_global_block_cycles[0],
                     trace_fpu_backpressure_cycles[0],
                     trace_fpu_other_idle_cycles[0],
                     trace_frontend_empty_cycles[0],
                     trace_window_full_cycles[0],
                     trace_retire_head_incomplete_cycles[0]);
            $display("PASS: 4PF full-core same-register FMADD32 pipeline test");
        end
        else begin
            perf_word = (dut.u_backend.u_gpr.regs[11] >> 3) & 13'h1fff;
            for (perf_index = 0; perf_index < 4;
                 perf_index = perf_index + 1) begin
                case (perf_index)
                    0: perf_unroll = 1;
                    1: perf_unroll = 4;
                    2: perf_unroll = 16;
                    default: perf_unroll = 32;
                endcase
                perf_cycles_value = memory[perf_word + perf_index*2];
                perf_instret_value = memory[perf_word + perf_index*2 + 1];
                if (perf_cycles_value == 0)
                    $fatal(1, "4PF DAXPY u%0d returned zero cycles",
                           perf_unroll);
                $display("PERF: DAXPY unroll=%0d elements=%0d cycles=%0d instret=%0d cycles_per_element_x1000=%0d ipc_x1000=%0d fpu_requests=%0d fpu_results=%0d max_inflight=%0d max_transfer_occupancy=%0d average_request_interval_x1000=%0d",
                         perf_unroll, DAXPY_ELEMENTS,
                         perf_cycles_value, perf_instret_value,
                         (perf_cycles_value * 1000) / DAXPY_ELEMENTS,
                         (perf_instret_value * 1000) / perf_cycles_value,
                         fpu_requests[perf_index], fpu_results[perf_index],
                         fpu_max_outstanding[perf_index],
                         fp_transfer_max_occupancy[perf_index],
                         ((fpu_last_request_cycle[perf_index] -
                           fpu_first_request_cycle[perf_index]) * 1000) /
                             (fpu_requests[perf_index] - 1));
                $display("STALL: DAXPY unroll=%0d phase_cycles=%0d fpu_issue=%0d no_compute_candidate=%0d forwarding_ready=%0d producer_pending=%0d global_block=%0d fpu_backpressure=%0d other=%0d frontend_empty=%0d window_full=%0d",
                         perf_unroll, trace_phase_cycles[perf_index],
                         trace_fpu_issue_cycles[perf_index],
                         trace_fpu_no_candidate_cycles[perf_index],
                         trace_fpu_forwardable_cycles[perf_index],
                         trace_fpu_producer_pending_cycles[perf_index],
                         trace_fpu_global_block_cycles[perf_index],
                         trace_fpu_backpressure_cycles[perf_index],
                         trace_fpu_other_idle_cycles[perf_index],
                         trace_frontend_empty_cycles[perf_index],
                         trace_window_full_cycles[perf_index]);
                $display("STALL: DAXPY unroll=%0d mem_accept=%0d mem_wait=%0d mem_order_block=%0d retire_zero_nonempty=%0d retire_head_incomplete=%0d head_fp_load=%0d head_fp_compute=%0d head_fp_store=%0d head_other=%0d completed_behind_head=%0d retire_ready_block=%0d store_source_block=%0d store_source_forwardable=%0d",
                         perf_unroll,
                         trace_mem_accept_cycles[perf_index],
                         trace_mem_wait_cycles[perf_index],
                         trace_mem_order_block_cycles[perf_index],
                         trace_retire_zero_nonempty_cycles[perf_index],
                         trace_retire_head_incomplete_cycles[perf_index],
                         trace_retire_head_fp_load_cycles[perf_index],
                         trace_retire_head_fp_compute_cycles[perf_index],
                         trace_retire_head_fp_store_cycles[perf_index],
                         trace_retire_head_other_cycles[perf_index],
                         trace_completed_behind_head_cycles[perf_index],
                         trace_retire_ready_block_cycles[perf_index],
                         trace_store_source_block_cycles[perf_index],
                         trace_store_source_forwardable_cycles[perf_index]);
            end
            $display("PERF: DAXPY total_test_cycles=%0d", cycles);
            $display("PASS: 4PF full-core DAXPY window/decode/FPU/LSU/retirement");
        end
        $finish;
    end
endmodule
