// Compact cycle trace for the Tomasulo instruction-stream frontend.
//
// Only rv64_top_3p observation seams are sampled.  Boolean state is packed
// into flags and lane masks into lane_state; tools/frontend_trace.py expands
// both according to the documented v1 ABI.  This avoids the extreme Verilator
// code-generation cost of a 90-argument formatted write.
generate
    if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
        (BP_TYPE == `OPENRV64_BP_TAGE_BTB) &&
        (ENABLE_FRONTEND_TRACE != 0)) begin : g_frontend_trace
        localparam [7:0] FTRACE_PROGRESS              = 8'd0;
        localparam [7:0] FTRACE_HALT_OR_WFI           = 8'd1;
        localparam [7:0] FTRACE_CONTROL_FLUSH         = 8'd2;
        localparam [7:0] FTRACE_ARCH_RESTART          = 8'd3;
        localparam [7:0] FTRACE_BACKEND_REDIRECT      = 8'd4;
        localparam [7:0] FTRACE_TARGET_REDIRECT       = 8'd5;
        localparam [7:0] FTRACE_BP_PRELIM_REDIRECT    = 8'd6;
        localparam [7:0] FTRACE_BP_TAGE_RESTEER       = 8'd7;
        localparam [7:0] FTRACE_BP_DEFERRED_REDIRECT  = 8'd8;
        localparam [7:0] FTRACE_BP_OTHER_REDIRECT     = 8'd9;
        localparam [7:0] FTRACE_TRANSLATION_BARRIER   = 8'd10;
        localparam [7:0] FTRACE_BP_UNRESOLVED_TARGET  = 8'd11;
        localparam [7:0] FTRACE_BP_CAPACITY           = 8'd12;
        localparam [7:0] FTRACE_BP_LOOKUP              = 8'd13;
        localparam [7:0] FTRACE_BACKEND_BACKPRESSURE  = 8'd14;
        localparam [7:0] FTRACE_CONTROL_QUALIFICATION = 8'd15;
        localparam [7:0] FTRACE_CURRENT_BLOCK_PENDING = 8'd16;
        localparam [7:0] FTRACE_REFILL_PENDING        = 8'd17;
        localparam [7:0] FTRACE_FTQ_EMPTY             = 8'd18;
        localparam [7:0] FTRACE_BTB_QUEUE_FULL        = 8'd19;
        localparam [7:0] FTRACE_REQUEST_BLOCKED       = 8'd20;
        localparam [7:0] FTRACE_NO_PRESENTATION       = 8'd21;
        localparam [7:0] FTRACE_DECODE_EMPTY          = 8'd22;
        localparam [7:0] FTRACE_UNKNOWN               = 8'd255;

        integer ftrace_fd;
        reg [4095:0] ftrace_path;
        integer ftrace_start_cycle;
        reg [31:0] ftrace_cycle_count;
        integer ftrace_flush_cycles;
        reg ftrace_marker_mode;
        reg ftrace_capture_active;
        reg [31:0] ftrace_capture_start_cycle;
        reg [63:0] ftrace_rows;
        reg [31:0] ftrace_cycle;
        reg [7:0] ftrace_reason;
        reg ftrace_progress;
        reg [63:0] ftrace_flags;
        reg [63:0] ftrace_lane_state;

        initial begin
            ftrace_fd = 0;
            ftrace_start_cycle = -1;
            ftrace_cycle_count = 32'd0;
            ftrace_flush_cycles = 1024;
            ftrace_rows = 64'd0;
            if ($value$plusargs("frontend_trace_start=%d",
                                ftrace_start_cycle)) begin end
            if ($value$plusargs("frontend_trace_cycles=%d",
                                ftrace_cycle_count)) begin end
            if ($value$plusargs("frontend_trace_flush=%d",
                                ftrace_flush_cycles)) begin end
            ftrace_marker_mode = (ftrace_start_cycle < 0);
            ftrace_capture_active = 1'b0;
            ftrace_capture_start_cycle = 32'd0;
            if ($value$plusargs("frontend_trace=%s", ftrace_path)) begin
                ftrace_fd = $fopen(ftrace_path, "w");
                if (ftrace_fd == 0)
                    $fatal(1, "cannot open frontend trace: %0s",
                           ftrace_path);
                $fdisplay(ftrace_fd,
                    "schema,cycle,stall_reason,progress,stream_pc,next_pc,control_pc,successor_pc,tage_lookup_pc,bp_target,backend_target,backend_redirect_id,flags,lane_state,generation,ftq_count,btb_queue_count,tage_queue_count,dispatch_occupancy,rob_occupancy,req_addr,resp_addr");
                if (ftrace_marker_mode)
                    $display("FRONTEND_TRACE path=%0s start=START_TRACE cycles=%0d",
                             ftrace_path, ftrace_cycle_count);
                else
                    $display("FRONTEND_TRACE path=%0s start=%0d cycles=%0d",
                             ftrace_path, ftrace_start_cycle,
                             ftrace_cycle_count);
            end
        end

        always @(negedge clk) begin
            if ((ftrace_fd != 0) && rst_n) begin
                if (cycles < 0)
                    $fatal(1, "frontend trace observed a negative cycle");
                ftrace_cycle = cycles;
                if (!ftrace_capture_active) begin
                    if (ftrace_marker_mode && dut.backend_trace_start) begin
                        ftrace_capture_active = 1'b1;
                        ftrace_capture_start_cycle = ftrace_cycle;
                        $display("FRONTEND_TRACE_START cycle=%0d source=START_TRACE",
                                 ftrace_cycle);
                    end else if (!ftrace_marker_mode &&
                                 (ftrace_cycle >= ftrace_start_cycle)) begin
                        ftrace_capture_active = 1'b1;
                        ftrace_capture_start_cycle = ftrace_start_cycle;
                    end
                end

                if (ftrace_capture_active && ftrace_marker_mode &&
                    dut.backend_trace_end) begin
                    ftrace_capture_active = 1'b0;
                    $fflush(ftrace_fd);
                    $display("FRONTEND_TRACE_END cycle=%0d interval_cycles=%0d rows=%0d source=END_TRACE",
                             ftrace_cycle,
                             ftrace_cycle - ftrace_capture_start_cycle,
                             ftrace_rows);
                end else if (ftrace_capture_active &&
                    ((ftrace_cycle_count == 0) ||
                     ((ftrace_cycle - ftrace_capture_start_cycle) <
                      ftrace_cycle_count))) begin
                    ftrace_progress = (|dut.frontend_decode_fire) ||
                                      (dut.fetch3_consumed_halfwords != 0);
                    if (ftrace_progress)
                        ftrace_reason = FTRACE_PROGRESS;
                    else if (dut.halted_q || dut.wfi_sleep_q)
                        ftrace_reason = FTRACE_HALT_OR_WFI;
                    else if (dut.control_flush)
                        ftrace_reason = FTRACE_CONTROL_FLUSH;
                    else if (dut.bp_target_mispredict_effective)
                        ftrace_reason = FTRACE_TARGET_REDIRECT;
                    else if (dut.backend_redirect)
                        ftrace_reason = FTRACE_BACKEND_REDIRECT;
                    else if (dut.bp_tage_resteer)
                        ftrace_reason = FTRACE_BP_TAGE_RESTEER;
                    else if (dut.bp_preliminary_redirect)
                        ftrace_reason = FTRACE_BP_PRELIM_REDIRECT;
                    else if (dut.bp_deferred_predict_redirect_q)
                        ftrace_reason = FTRACE_BP_DEFERRED_REDIRECT;
                    else if (dut.bp_predict_redirect)
                        ftrace_reason = FTRACE_BP_OTHER_REDIRECT;
                    else if (dut.control_restart || dut.except_vector_valid)
                        ftrace_reason = FTRACE_ARCH_RESTART;
                    else if (dut.translation_barrier_busy)
                        ftrace_reason = FTRACE_TRANSLATION_BARRIER;
                    else if (dut.bp_unresolved_target_stall)
                        ftrace_reason = FTRACE_BP_UNRESOLVED_TARGET;
                    else if (dut.bp_capacity_stall)
                        ftrace_reason = FTRACE_BP_CAPACITY;
                    else if (dut.bp_decode_stall || dut.bp_fetch_stall)
                        ftrace_reason = FTRACE_BP_LOOKUP;
                    else if (dut.fetch_decode_valid != 0) begin
                        if (|(dut.backend_decode_valid &
                              ~dut.backend_decode_ready))
                            ftrace_reason = FTRACE_BACKEND_BACKPRESSURE;
                        else
                            ftrace_reason = FTRACE_CONTROL_QUALIFICATION;
                    end else if (!dut.fetch_observe_presentation_ready) begin
                        if (dut.fetch_observe_current_pending)
                            ftrace_reason = FTRACE_CURRENT_BLOCK_PENDING;
                        else if (dut.fetch_observe_pending_any)
                            ftrace_reason = FTRACE_REFILL_PENDING;
                        else if (dut.fetch3_ftq_count == 0)
                            ftrace_reason = FTRACE_FTQ_EMPTY;
                        else if (dut.fetch_observe_stream_btb_queue_full_stall)
                            ftrace_reason = FTRACE_BTB_QUEUE_FULL;
                        else
                            ftrace_reason = FTRACE_NO_PRESENTATION;
                    end else if (dut.fetch_pipe_req_valid &&
                                 !dut.fetch_pipe_req_ready)
                        ftrace_reason = FTRACE_REQUEST_BLOCKED;
                    else if (dut.fetch_observe_presentation_ready)
                        ftrace_reason = FTRACE_DECODE_EMPTY;
                    else
                        ftrace_reason = FTRACE_UNKNOWN;

                    ftrace_flags = 64'd0;
                    ftrace_flags[0] = dut.fetch3_istream_prediction_valid;
                    ftrace_flags[1] = dut.fetch3_istream_prediction_taken;
                    ftrace_flags[2] = dut.fetch3_istream_prediction_refined;
                    ftrace_flags[3] = dut.fetch3_istream_prediction_accept;
                    ftrace_flags[4] = dut.fetch3_istream_splice_valid;
                    ftrace_flags[5] = dut.fetch_observe_presentation_ready;
                    ftrace_flags[6] = dut.fetch_observe_current_pending;
                    ftrace_flags[7] = dut.fetch_observe_pending_any;
                    ftrace_flags[8] = dut.fetch_pipe_req_valid;
                    ftrace_flags[9] = dut.fetch_pipe_req_ready;
                    ftrace_flags[10] = dut.fetch_pipe_resp_valid;
                    ftrace_flags[11] = dut.fetch_pipe_resp_ready;
                    ftrace_flags[12] = dut.fetch_observe_stream_btb_lookup;
                    ftrace_flags[13] = dut.fetch_observe_stream_btb_response;
                    ftrace_flags[14] = dut.fetch_observe_stream_btb_hit;
                    ftrace_flags[15] = dut.fetch_observe_stream_btb_root_lookup;
                    ftrace_flags[16] = dut.fetch_observe_stream_btb_chain_lookup;
                    ftrace_flags[17] = dut.fetch_observe_stream_btb_queue_full_stall;
                    ftrace_flags[18] = dut.fetch_observe_stream_btb_queue_enqueue;
                    ftrace_flags[19] = dut.fetch_observe_stream_btb_queue_dequeue;
                    ftrace_flags[20] = dut.fetch_observe_stream_transfer;
                    ftrace_flags[21] = dut.fetch_observe_stream_reject;
                    ftrace_flags[22] = dut.fetch_observe_stream_btb_train;
                    ftrace_flags[23] = dut.fetch_observe_istream_tage_candidate;
                    ftrace_flags[24] = dut.istream_tage_lookup_valid;
                    ftrace_flags[25] = dut.istream_tage_lookup_accept;
                    ftrace_flags[26] = dut.fetch_observe_istream_tage_response;
                    ftrace_flags[27] = dut.fetch_observe_istream_tage_taken;
                    ftrace_flags[28] = dut.fetch_observe_istream_tage_busy_skip;
                    ftrace_flags[29] = dut.fetch_observe_istream_refinement_accept;
                    ftrace_flags[30] = dut.fetch_observe_istream_refinement_changed;
                    ftrace_flags[31] = dut.fetch_observe_istream_refinement_late;
                    ftrace_flags[32] = dut.fetch_observe_istream_tage_context_hit;
                    ftrace_flags[33] = dut.fetch_observe_istream_tage_context_claim;
                    ftrace_flags[34] = dut.fetch_observe_istream_tage_context_miss;
                    ftrace_flags[35] = dut.bp_fetch_stall;
                    ftrace_flags[36] = dut.bp_decode_stall;
                    ftrace_flags[37] = dut.bp_capacity_stall;
                    ftrace_flags[38] = dut.bp_unresolved_target_stall;
                    ftrace_flags[39] = dut.bp_preliminary_redirect;
                    ftrace_flags[40] = dut.bp_tage_resteer;
                    ftrace_flags[41] = dut.bp_deferred_predict_redirect_q;
                    ftrace_flags[42] = dut.bp_predict_redirect;
                    ftrace_flags[43] = dut.backend_redirect;
                    ftrace_flags[44] = dut.backend_memory_replay;
                    ftrace_flags[45] = dut.bp_target_mispredict_effective;
                    ftrace_flags[46] = dut.control_flush;
                    ftrace_flags[47] = dut.control_restart;
                    ftrace_flags[48] = dut.except_vector_valid;
                    ftrace_flags[49] = dut.translation_barrier_busy;
                    ftrace_flags[50] = dut.halted_q;
                    ftrace_flags[51] = dut.wfi_sleep_q;
                    ftrace_flags[52] = dut.frontend_decode_enable;
                    ftrace_flags[53] = dut.backend_decode_enable;
                    ftrace_flags[54] =
                        dut.u_bp.diag_tage_decode_direction_read;
                    ftrace_flags[55] =
                        dut.u_bp.diag_tage_early_direction_read;
                    ftrace_flags[56] =
                        dut.u_bp.diag_tage_dual_direction_read;
                    ftrace_flags[57] =
                        dut.u_bp.diag_tage_early_context_write;
                    ftrace_flags[58] =
                        dut.u_bp.diag_tage_coalesced_direction_read;
                    ftrace_flags[59] =
                        dut.u_bp.diag_tage_early_direction_blocked;

                    ftrace_lane_state = 64'd0;
                    ftrace_lane_state[2:0] = dut.fetch_decode_valid;
                    ftrace_lane_state[5:3] = dut.fetch_decode_ready;
                    ftrace_lane_state[8:6] = dut.frontend_decode_fire;
                    ftrace_lane_state[11:9] = dut.frontend_control_select;
                    ftrace_lane_state[14:12] = dut.frontend_prefix_allow;
                    ftrace_lane_state[17:15] = dut.bp_live_lane_allow;
                    ftrace_lane_state[20:18] = dut.backend_decode_ready;
                    ftrace_lane_state[24:21] = dut.fetch3_consumed_halfwords;
                    ftrace_lane_state[28:25] =
                        dut.fetch3_istream_splice_halfword;

                    $fdisplay(ftrace_fd,
                        "openrv64-frontend-cycle-v1,%0d,%0d,%0d,%016x,%016x,%016x,%016x,%016x,%016x,%016x,%03x,%016x,%016x,%0d,%0d,%0d,%0d,%0d,%0d,%016x,%016x",
                        ftrace_cycle, ftrace_reason, ftrace_progress,
                        dut.fetch3_stream_pc, dut.fetch3_next_pc,
                        dut.fetch3_istream_control_pc,
                        dut.fetch3_istream_prediction_successor,
                        dut.istream_tage_lookup_pc, dut.bp_predict_target,
                        dut.backend_redirect_target, dut.backend_redirect_id,
                        ftrace_flags, ftrace_lane_state,
                        dut.fetch3_stream_generation, dut.fetch3_ftq_count,
                        dut.fetch_observe_stream_btb_queue_count,
                        dut.fetch_observe_istream_tage_queue_count,
                        dut.backend_dispatch_occupancy,
                        dut.backend_retire_occupancy,
                        dut.fetch_pipe_req_addr, dut.fetch_pipe_resp_addr);
                    ftrace_rows = ftrace_rows + 64'd1;
                    if ((ftrace_flush_cycles > 0) &&
                        ((ftrace_cycle % ftrace_flush_cycles) == 0))
                        $fflush(ftrace_fd);
                end
            end
        end

        final begin
            if (ftrace_fd != 0) begin
                $fflush(ftrace_fd);
                $fclose(ftrace_fd);
                $display("FRONTEND_TRACE_DONE rows=%0d path=%0s",
                         ftrace_rows, ftrace_path);
            end
        end
    end else begin : g_no_frontend_trace
        initial begin
            if ($test$plusargs("frontend_trace"))
                $fatal(1,
                    "+frontend_trace requires Tomasulo BP9 and an ENABLE_FRONTEND_TRACE=1 build");
        end
    end
endgenerate
