// Optional long-form Tomasulo resident-state trace for tb_top_3p_soc.
//
// Enable with +pipeline_state_trace=<path>.  This include deliberately lives
// in the testbench rather than the synthesizable core interface: it snapshots
// internal component state without adding architectural ports or fanout.
generate
    if ((RENAME_MODE == `OPENRV64_RENAME_TOMASULO) &&
        (ENABLE_PIPELINE_STATE_TRACE != 0)) begin :
            g_tomasulo_pipeline_state_trace
        localparam integer TTRACE_LSQ_LOAD_DEPTH = 4;
        localparam integer TTRACE_LSQ_STORE_DEPTH = 4;
        localparam integer TTRACE_LSQ_META_WIDTH = 180;
        localparam integer TTRACE_LSQ_META_INSTR = 20;
        localparam integer TTRACE_LSQ_META_PC = 52;
        localparam integer TTRACE_LSQ_META_TRACE = 116;

        integer ttrace_fd;
        reg [1023:0] ttrace_path;
        reg [31:0] ttrace_start_cycle;
        reg [31:0] ttrace_cycle_count;
        integer ttrace_flush_cycles;
        reg [63:0] ttrace_rows;
        integer ttrace_lane;
        integer ttrace_slot;
        integer ttrace_pipe;
        reg [31:0] ttrace_cycle;
        reg [7:0] ttrace_reason;
        reg [7:0] ttrace_state;
        reg [63:0] ttrace_flags;
        reg [63:0] ttrace_detail0;
        reg [63:0] ttrace_detail1;
        reg [63:0] ttrace_uid;
        reg [63:0] ttrace_blocker_uid;
        reg [63:0] ttrace_payload;
        reg [`OPENRV64_INSTR_ID_WIDTH-1:0] ttrace_core_id;

        function automatic [63:0] ttrace_uid_for_core_id;
            input [`OPENRV64_INSTR_ID_WIDTH-1:0] core_id;
            integer lookup_slot;
            begin
                ttrace_uid_for_core_id = 64'd0;
                for (lookup_slot = 0; lookup_slot < RETIRE_DEPTH;
                     lookup_slot = lookup_slot + 1)
                    if (dut.u_backend.u_retire_queue.valid_q[lookup_slot] &&
                        (dut.u_backend.u_retire_queue.id_q[lookup_slot] ==
                         core_id))
                        ttrace_uid_for_core_id = dut.u_backend
                            .u_retire_records.g_trace.trace_q[lookup_slot];
            end
        endfunction

        task automatic ttrace_emit;
            input [63:0] uid;
            input [`OPENRV64_INSTR_ID_WIDTH-1:0] core_id;
            input [63:0] pc;
            input [31:0] instr;
            input [7:0] stage;
            input integer slot;
            input integer lane;
            input [7:0] state_code;
            input [7:0] reason_code;
            input [63:0] blocker_uid;
            input [63:0] flags;
            input [63:0] detail0;
            input [63:0] detail1;
            begin
                if (uid == 64'd0)
                    $fatal(1,
                        "Tomasulo trace found zero UID at cycle %0d stage %0d",
                        ttrace_cycle, stage);
                if (uid[63:32] != 32'd0)
                    $fatal(1,
                        "openrv64-pipeline-state-v2 UID overflow: %016h",
                        uid);
                if (blocker_uid[63:32] != 32'd0)
                    $fatal(1,
                        "openrv64-pipeline-state-v2 blocker overflow: %016h",
                        blocker_uid);
                $fdisplay(ttrace_fd,
                    "openrv64-pipeline-state-v2,%0d,%08x,%03x,%016x,%08x,%0d,%0d,%0d,%0d,%0d,%08x,%016x,%016x,%016x",
                    ttrace_cycle, uid[31:0], core_id, pc, instr, stage,
                    slot, lane, state_code, reason_code, blocker_uid[31:0],
                    flags, detail0, detail1);
                ttrace_rows = ttrace_rows + 64'd1;
            end
        endtask

        task automatic ttrace_emit_lsq_meta;
            input [TTRACE_LSQ_META_WIDTH-1:0] payload;
            input [`OPENRV64_INSTR_ID_WIDTH-1:0] core_id;
            input [7:0] stage;
            input integer slot;
            input integer lane;
            input [7:0] state_code;
            input [7:0] reason_code;
            input [63:0] blocker_uid;
            input [63:0] flags;
            input [63:0] detail0;
            input [63:0] detail1;
            begin
                ttrace_emit(payload[TTRACE_LSQ_META_TRACE +: 64], core_id,
                    payload[TTRACE_LSQ_META_PC +: 64],
                    payload[TTRACE_LSQ_META_INSTR +: 32], stage, slot,
                    lane, state_code, reason_code, blocker_uid, flags,
                    detail0, detail1);
            end
        endtask

        task automatic ttrace_emit_issue_payload;
            input [`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0] payload;
            input [`OPENRV64_INSTR_ID_WIDTH-1:0] core_id;
            input [7:0] stage;
            input integer slot;
            input integer lane;
            input [7:0] state_code;
            input [7:0] reason_code;
            input [63:0] blocker_uid;
            input [63:0] flags;
            input [63:0] detail0;
            input [63:0] detail1;
            begin
                ttrace_emit(payload[
                        `OPENRV64_EXEC_ISSUE_PAYLOAD_TRACE_ID_LSB +: 64],
                    core_id,
                    payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_PC_LSB +: 64],
                    payload[`OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +: 32],
                    stage, slot,
                    lane, state_code, reason_code, blocker_uid, flags,
                    detail0, detail1);
            end
        endtask

        task automatic ttrace_emit_complete_payload;
            input [`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH-1:0] payload;
            input [`OPENRV64_INSTR_ID_WIDTH-1:0] core_id;
            input [7:0] stage;
            input integer slot;
            input integer lane;
            input [7:0] state_code;
            input [7:0] reason_code;
            input [63:0] flags;
            begin
                ttrace_emit(payload[393 +: 64], core_id,
                    payload[329 +: 64], payload[233 +: 32], stage, slot,
                    lane, state_code, reason_code, 64'd0, flags,
                    payload[`OPENRV64_COMPLETE_DATA_LSB +: 64],
                    payload[265 +: 64]);
            end
        endtask

        initial begin
            ttrace_fd = 0;
            ttrace_start_cycle = 32'd0;
            ttrace_cycle_count = 32'd0;
            ttrace_flush_cycles = 1024;
            ttrace_rows = 64'd0;
            if ($value$plusargs("pipeline_state_trace_start=%d",
                                ttrace_start_cycle)) begin end
            if ($value$plusargs("pipeline_state_trace_cycles=%d",
                                ttrace_cycle_count)) begin end
            if ($value$plusargs("pipeline_state_trace_flush=%d",
                                ttrace_flush_cycles)) begin end
            if ($value$plusargs("pipeline_state_trace=%s", ttrace_path)) begin
                ttrace_fd = $fopen(ttrace_path, "w");
                if (ttrace_fd == 0)
                    $fatal(1, "cannot open Tomasulo pipeline trace: %0s",
                           ttrace_path);
                $fdisplay(ttrace_fd,
                    "schema,cycle,insn_id,core_id,pc,instr,stage,slot,lane,state,reason,blocker_id,flags,detail0,detail1");
                $display("PIPELINE_STATE_TRACE path=%0s start=%0d cycles=%0d",
                         ttrace_path, ttrace_start_cycle,
                         ttrace_cycle_count);
            end
        end

        always @(negedge clk) begin
            if ((ttrace_fd != 0) && rst_n) begin
                if (dut.trace_cycle_q[63:32] != 32'd0)
                    $fatal(1,
                        "openrv64-pipeline-state-v2 cycle overflow: %016h",
                        dut.trace_cycle_q);
                ttrace_cycle = dut.trace_cycle_q[31:0];
                if ((ttrace_cycle >= ttrace_start_cycle) &&
                    ((ttrace_cycle_count == 0) ||
                     ((ttrace_cycle - ttrace_start_cycle) <
                      ttrace_cycle_count))) begin
                    // Fetch output and combinational decode/admission gate.
                    for (ttrace_lane = 0; ttrace_lane < 3;
                         ttrace_lane = ttrace_lane + 1) begin
                        if (dut.fetch_decode_valid[ttrace_lane]) begin
                            ttrace_payload = dut.fetch_decode_trace[
                                ttrace_lane*64 +: 64];
                            ttrace_emit(ttrace_payload,
                                dut.backend_decode_allocation_id[
                                    0 +: `OPENRV64_INSTR_ID_WIDTH] +
                                    ((BP_TYPE == `OPENRV64_BP_TAGE_BTB) ?
                                        dut.bp_stage_output_count : 2'd0) +
                                    ttrace_lane,
                                dut.frontend_decode_payload[
                                    ttrace_lane*
                                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                                    `OPENRV64_EXEC_ISSUE_PAYLOAD_PC_LSB +:
                                    64],
                                dut.frontend_decode_payload[
                                    ttrace_lane*
                                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                                    `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +:
                                    32],
                                `OPENRV64_TTRACE_STAGE_FETCH, -1,
                                ttrace_lane, `OPENRV64_TTRACE_STATE_PRESENT,
                                `OPENRV64_TTRACE_REASON_NONE, 64'd0,
                                {60'd0, dut.fetch_decode_ready[ttrace_lane],
                                 dut.backend_decode_ready[ttrace_lane],
                                 dut.backend_decode_valid[ttrace_lane],
                                 dut.fetch_decode_valid[ttrace_lane]},
                                64'd0, 64'd0);

                            if (((BP_TYPE == `OPENRV64_BP_TAGE_BTB) &&
                                 dut.frontend_decode_fire[ttrace_lane]) ||
                                ((BP_TYPE != `OPENRV64_BP_TAGE_BTB) &&
                                 dut.backend_decode_valid[ttrace_lane] &&
                                 dut.backend_decode_ready[ttrace_lane])) begin
                                ttrace_reason =
                                    `OPENRV64_TTRACE_REASON_NONE;
                                ttrace_state =
                                    `OPENRV64_TTRACE_STATE_FIRE;
                            end else begin
                                ttrace_state =
                                    `OPENRV64_TTRACE_STATE_WAIT;
                                if (dut.halted_q || dut.wfi_sleep_q)
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_HALT_OR_WFI;
                                else if (dut.bp_unresolved_target_stall)
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_BP_TARGET;
                                else if (dut.bp_capacity_stall)
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_BP_CAPACITY;
                                else if (dut.translation_barrier_busy)
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_TRANSLATION_BARRIER;
                                else if (dut.control_flush ||
                                         dut.control_redirect ||
                                         !dut.frontend_prefix_allow[
                                             ttrace_lane])
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_FRONTEND_CONTROL;
                                else if (dut.u_backend.u_dispatch.g_3p
                                             .g_tomasulo.rename_free_count ==
                                         0)
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_RENAME_TAG;
                                else if (!dut.u_backend.allocation_ready)
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_ROB_CAPACITY;
                                else if (dut.backend_dispatch_occupancy ==
                                         ISSUE_WINDOW_DEPTH)
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_SCHED_CAPACITY;
                                else
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_DECODE_DOWNSTREAM;
                            end
                            ttrace_detail0 = 64'd0;
                            ttrace_detail0[15:0] = dut.u_backend.u_dispatch
                                .g_3p.g_tomasulo.rename_free_count;
                            ttrace_detail1 = 64'd0;
                            ttrace_detail1[15:0] =
                                dut.backend_retire_occupancy;
                            ttrace_detail1[31:16] =
                                dut.backend_dispatch_occupancy;
                            ttrace_emit(ttrace_payload,
                                dut.backend_decode_allocation_id[
                                    0 +: `OPENRV64_INSTR_ID_WIDTH] +
                                    ((BP_TYPE == `OPENRV64_BP_TAGE_BTB) ?
                                        dut.bp_stage_output_count : 2'd0) +
                                    ttrace_lane,
                                dut.frontend_decode_payload[
                                    ttrace_lane*
                                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                                    `OPENRV64_EXEC_ISSUE_PAYLOAD_PC_LSB +:
                                    64],
                                dut.frontend_decode_payload[
                                    ttrace_lane*
                                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                                    `OPENRV64_EXEC_ISSUE_PAYLOAD_INSTR_LSB +:
                                    32],
                                `OPENRV64_TTRACE_STAGE_DECODE, -1,
                                ttrace_lane, ttrace_state, ttrace_reason,
                                64'd0,
                                {60'd0, dut.fetch_decode_ready[ttrace_lane],
                                 dut.backend_decode_ready[ttrace_lane],
                                 dut.backend_decode_valid[ttrace_lane],
                                 dut.frontend_decode_fire[ttrace_lane]},
                                ttrace_detail0, ttrace_detail1);
                        end
                    end

                    // BP9's synchronous direction lookup resides in the
                    // elastic dispatch boundary, not in combinational decode.
                    // Emit that residency separately so a lookup wait cannot
                    // be misreported as a decode-stage stall.
                    if (BP_TYPE == `OPENRV64_BP_TAGE_BTB) begin
                        for (ttrace_lane = 0; ttrace_lane < 3;
                             ttrace_lane = ttrace_lane + 1) begin
                            if (dut.bp_dispatch_valid_q[ttrace_lane]) begin
                                ttrace_payload = dut.backend_decode_payload[
                                    ttrace_lane*
                                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +
                                    `OPENRV64_EXEC_ISSUE_PAYLOAD_TRACE_ID_LSB +:
                                    64];
                                if (dut.backend_decode_fire[ttrace_lane]) begin
                                    ttrace_state =
                                        `OPENRV64_TTRACE_STATE_FIRE;
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_NONE;
                                end else begin
                                    ttrace_state =
                                        `OPENRV64_TTRACE_STATE_WAIT;
                                    if (dut.bp_unresolved_target_stall)
                                        ttrace_reason =
                                            `OPENRV64_TTRACE_REASON_BP_TARGET;
                                    else if (dut.bp_capacity_stall)
                                        ttrace_reason =
                                            `OPENRV64_TTRACE_REASON_BP_CAPACITY;
                                    else if (dut.bp_decode_stall)
                                        ttrace_reason =
                                            `OPENRV64_TTRACE_REASON_BP_LOOKUP;
                                    else if (dut.translation_barrier_busy)
                                        ttrace_reason =
                                            `OPENRV64_TTRACE_REASON_TRANSLATION_BARRIER;
                                    else if (dut.u_backend.u_dispatch.g_3p
                                                 .g_tomasulo
                                                 .rename_free_count == 0)
                                        ttrace_reason =
                                            `OPENRV64_TTRACE_REASON_RENAME_TAG;
                                    else if (!dut.u_backend.allocation_ready)
                                        ttrace_reason =
                                            `OPENRV64_TTRACE_REASON_ROB_CAPACITY;
                                    else if (dut.backend_dispatch_occupancy ==
                                             ISSUE_WINDOW_DEPTH)
                                        ttrace_reason =
                                            `OPENRV64_TTRACE_REASON_SCHED_CAPACITY;
                                    else
                                        ttrace_reason =
                                            `OPENRV64_TTRACE_REASON_DECODE_DOWNSTREAM;
                                end
                                ttrace_detail0 = 64'd0;
                                ttrace_detail0[15:0] =
                                    dut.u_backend.u_dispatch.g_3p.g_tomasulo
                                        .rename_free_count;
                                ttrace_detail1 = 64'd0;
                                ttrace_detail1[15:0] =
                                    dut.backend_retire_occupancy;
                                ttrace_detail1[31:16] =
                                    dut.backend_dispatch_occupancy;
                                ttrace_emit_issue_payload(
                                    dut.backend_decode_payload[
                                        ttrace_lane*
                                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH],
                                    dut.backend_decode_allocation_id[
                                        ttrace_lane*
                                        `OPENRV64_INSTR_ID_WIDTH +:
                                        `OPENRV64_INSTR_ID_WIDTH],
                                    `OPENRV64_TTRACE_STAGE_DISPATCH, -1,
                                    ttrace_lane, ttrace_state, ttrace_reason,
                                    64'd0,
                                    {60'd0,
                                     dut.bp_dispatch_control_select_q[
                                         ttrace_lane],
                                     dut.backend_decode_ready[ttrace_lane],
                                     dut.backend_decode_valid[ttrace_lane],
                                     dut.backend_decode_fire[ttrace_lane]},
                                    ttrace_detail0, ttrace_detail1);
                            end
                        end
                    end

                    // Tomasulo scheduler: one row for every live scheduler
                    // entry.  The same instruction also has a ROB row below.
                    for (ttrace_slot = 0;
                         ttrace_slot < ISSUE_WINDOW_DEPTH;
                         ttrace_slot = ttrace_slot + 1) begin
                        if (dut.u_backend.u_dispatch.g_3p
                                .u_tomasulo_window.u_window
                                .valid_q[ttrace_slot]) begin
                            ttrace_core_id = dut.u_backend.u_dispatch.g_3p
                                .u_tomasulo_window.u_window.id_q[ttrace_slot];
                            if (dut.u_backend.u_dispatch.g_3p
                                    .u_tomasulo_window.u_window
                                    .trace_entry_blocker_valid[ttrace_slot])
                                ttrace_blocker_uid =
                                    ttrace_uid_for_core_id(
                                        dut.u_backend.u_dispatch.g_3p
                                        .u_tomasulo_window.u_window
                                        .trace_entry_blocker_id[
                                            ttrace_slot]);
                            else
                                ttrace_blocker_uid = 64'd0;
                            ttrace_flags = {
                                55'd0,
                                dut.u_backend.u_dispatch.g_3p
                                    .u_tomasulo_window.u_window
                                    .trace_entry_blocker_valid[ttrace_slot],
                                dut.u_backend.u_dispatch.g_3p
                                    .u_tomasulo_window.u_window
                                    .result_ready_q[ttrace_slot],
                                dut.u_backend.u_dispatch.g_3p
                                    .u_tomasulo_window.u_window
                                    .uses_rs2_q[ttrace_slot],
                                dut.u_backend.u_dispatch.g_3p
                                    .u_tomasulo_window.u_window
                                    .uses_rs1_q[ttrace_slot],
                                dut.u_backend.u_dispatch.g_3p
                                    .u_tomasulo_window.u_window
                                    .src2_ready_now[ttrace_slot],
                                dut.u_backend.u_dispatch.g_3p
                                    .u_tomasulo_window.u_window
                                    .src1_ready_now[ttrace_slot],
                                dut.u_backend.u_dispatch.g_3p
                                    .u_tomasulo_window.u_window
                                    .eligible[ttrace_slot],
                                dut.u_backend.u_dispatch.g_3p
                                    .u_tomasulo_window.u_window
                                    .issued_q[ttrace_slot],
                                1'b1};
                            ttrace_detail0 = 64'd0;
                            ttrace_detail0[15:0] = dut.u_backend.u_dispatch
                                .g_3p.u_tomasulo_window.u_window
                                .src1_tag_q[ttrace_slot];
                            ttrace_detail0[31:16] = dut.u_backend.u_dispatch
                                .g_3p.u_tomasulo_window.u_window
                                .src2_tag_q[ttrace_slot];
                            ttrace_detail1 = 64'd0;
                            ttrace_detail1[7:0] = dut.u_backend.u_dispatch
                                .g_3p.u_tomasulo_window.u_window
                                .rob_slot_q[ttrace_slot];
                            ttrace_detail1[15:8] = dut.u_backend.u_dispatch
                                .g_3p.u_tomasulo_window.u_window
                                .src1_phys_q[ttrace_slot];
                            ttrace_detail1[23:16] = dut.u_backend.u_dispatch
                                .g_3p.u_tomasulo_window.u_window
                                .src2_phys_q[ttrace_slot];
                            ttrace_detail1[31:24] = dut.u_backend.u_dispatch
                                .g_3p.u_tomasulo_window.u_window
                                .destination_phys_q[ttrace_slot];
                            ttrace_emit_issue_payload(
                                dut.u_backend.u_dispatch.g_3p
                                    .u_tomasulo_window.u_window
                                    .payload_q[ttrace_slot],
                                ttrace_core_id,
                                `OPENRV64_TTRACE_STAGE_SCHED,
                                ttrace_slot,
                                dut.u_backend.u_dispatch.g_3p
                                    .u_tomasulo_window.u_window
                                    .trace_entry_pipe[ttrace_slot],
                                (dut.u_backend.u_dispatch.g_3p
                                     .u_tomasulo_window.u_window
                                     .trace_entry_block_reason[
                                         ttrace_slot] ==
                                 `OPENRV64_TTRACE_REASON_NONE) ?
                                    `OPENRV64_TTRACE_STATE_READY :
                                    `OPENRV64_TTRACE_STATE_WAIT,
                                dut.u_backend.u_dispatch.g_3p
                                    .u_tomasulo_window.u_window
                                    .trace_entry_block_reason[ttrace_slot],
                                ttrace_blocker_uid, ttrace_flags,
                                ttrace_detail0, ttrace_detail1);
                        end
                    end

                    // Deferred physical-register operand gather.  Active and
                    // pending groups are distinct storage components.
                    for (ttrace_pipe = 0;
                         ttrace_pipe < `OPENRV64_EXEC_PIPE_COUNT;
                         ttrace_pipe = ttrace_pipe + 1) begin
                        if (dut.u_backend.banked_regload_pipe_valid_q[
                                ttrace_pipe]) begin
                            ttrace_core_id = dut.u_backend
                                .banked_regload_pipe_id_q[
                                    ttrace_pipe*
                                    `OPENRV64_INSTR_ID_WIDTH +:
                                    `OPENRV64_INSTR_ID_WIDTH];
                            if (dut.u_backend
                                    .banked_regload_lane_id_q[
                                        0 +:
                                        `OPENRV64_INSTR_ID_WIDTH] ==
                                ttrace_core_id)
                                ttrace_lane = 0;
                            else
                                ttrace_lane = 1;
                            if (!dut.u_backend
                                    .banked_regload_lane_operands_ready[
                                        ttrace_lane])
                                ttrace_reason =
                                    `OPENRV64_TTRACE_REASON_REGREAD_PORT;
                            else if (!dut.u_backend.pipe_ready[ttrace_pipe])
                                ttrace_reason =
                                    `OPENRV64_TTRACE_REASON_PIPE_BUSY;
                            else
                                ttrace_reason =
                                    `OPENRV64_TTRACE_REASON_NONE;
                            ttrace_emit_issue_payload(
                                dut.u_backend.banked_regload_pipe_payload_q[
                                    ttrace_pipe*
                                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH],
                                ttrace_core_id,
                                `OPENRV64_TTRACE_STAGE_REGREAD,
                                dut.u_backend.banked_regload_pipe_slot_q[
                                    ttrace_pipe*$clog2(RETIRE_DEPTH) +:
                                    $clog2(RETIRE_DEPTH)],
                                ttrace_pipe,
                                `OPENRV64_TTRACE_STATE_ACTIVE,
                                ttrace_reason, 64'd0,
                                {53'd0,
                                 dut.u_backend
                                    .banked_regload_operand_ready,
                                 dut.u_backend
                                    .banked_regload_pipe_fire_mask,
                                 dut.u_backend
                                    .banked_regload_lane_valid_q,
                                 dut.u_backend.banked_regload_valid_q},
                                dut.u_backend
                                    .banked_regload_operand_done_q,
                                dut.u_backend
                                    .banked_regload_response_now);
                        end
                        if (dut.u_backend
                                .banked_regload_pending_pipe_valid_q[
                                    ttrace_pipe]) begin
                            ttrace_core_id = dut.u_backend
                                .banked_regload_pending_pipe_id_q[
                                    ttrace_pipe*
                                    `OPENRV64_INSTR_ID_WIDTH +:
                                    `OPENRV64_INSTR_ID_WIDTH];
                            if (dut.u_backend
                                    .banked_regload_pending_lane_id_q[
                                        0 +:
                                        `OPENRV64_INSTR_ID_WIDTH] ==
                                ttrace_core_id)
                                ttrace_lane = 0;
                            else
                                ttrace_lane = 1;
                            ttrace_emit_issue_payload(
                                dut.u_backend
                                    .banked_regload_pending_pipe_payload_q[
                                        ttrace_pipe*
                                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                                        `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH],
                                ttrace_core_id,
                                `OPENRV64_TTRACE_STAGE_REGREAD,
                                dut.u_backend
                                    .banked_regload_pending_pipe_slot_q[
                                        ttrace_pipe*$clog2(RETIRE_DEPTH) +:
                                        $clog2(RETIRE_DEPTH)],
                                ttrace_pipe,
                                `OPENRV64_TTRACE_STATE_PENDING,
                                `OPENRV64_TTRACE_REASON_REGREAD_BUFFER,
                                64'd0,
                                {57'd0,
                                 dut.u_backend
                                    .banked_regload_pending_operand_ready,
                                 dut.u_backend
                                    .banked_regload_pending_lane_valid_q,
                                 dut.u_backend
                                    .banked_regload_pending_valid_q},
                                dut.u_backend
                                    .banked_regload_pending_operand_done_q,
                                64'd0);
                        end
                    end

                    // Execution offers and the explicit multi-cycle EX0
                    // worker.  Single-cycle operations move into a completion
                    // register, which is emitted separately below.
                    for (ttrace_pipe = 0;
                         ttrace_pipe < `OPENRV64_EXEC_PIPE_COUNT;
                         ttrace_pipe = ttrace_pipe + 1) begin
                        if (dut.u_backend.pipe_valid[ttrace_pipe]) begin
                            ttrace_reason =
                                dut.u_backend.pipe_ready[ttrace_pipe] ?
                                `OPENRV64_TTRACE_REASON_NONE :
                                `OPENRV64_TTRACE_REASON_PIPE_BUSY;
                            ttrace_emit_issue_payload(
                                dut.u_backend.pipe_payload[
                                    ttrace_pipe*
                                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH +:
                                    `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH],
                                dut.u_backend.pipe_id[
                                    ttrace_pipe*
                                    `OPENRV64_INSTR_ID_WIDTH +:
                                    `OPENRV64_INSTR_ID_WIDTH],
                                `OPENRV64_TTRACE_STAGE_EXEC,
                                dut.u_backend.pipe_slot[
                                    ttrace_pipe*$clog2(RETIRE_DEPTH) +:
                                    $clog2(RETIRE_DEPTH)],
                                ttrace_pipe,
                                dut.u_backend.pipe_ready[ttrace_pipe] ?
                                    `OPENRV64_TTRACE_STATE_FIRE :
                                    `OPENRV64_TTRACE_STATE_WAIT,
                                ttrace_reason, 64'd0,
                                {62'd0,
                                 dut.u_backend.pipe_ready[ttrace_pipe],
                                 dut.u_backend.pipe_valid[ttrace_pipe]},
                                64'd0, 64'd0);
                        end
                    end
                    if (dut.u_backend.u_exec.g_3p.u_exec.u_ex0
                            .worker_pending_q)
                        ttrace_emit(
                            dut.u_backend.u_exec.g_3p.u_exec.u_ex0
                                .worker_trace_id_q,
                            dut.u_backend.u_exec.g_3p.u_exec.u_ex0
                                .worker_id_q,
                            dut.u_backend.u_exec.g_3p.u_exec.u_ex0
                                .worker_pc_q,
                            dut.u_backend.u_exec.g_3p.u_exec.u_ex0
                                .worker_instr_q,
                            `OPENRV64_TTRACE_STAGE_EXEC,
                            dut.u_backend.u_exec.g_3p.u_exec.u_ex0
                                .worker_slot_q,
                            0, `OPENRV64_TTRACE_STATE_WORKER,
                            `OPENRV64_TTRACE_REASON_EXEC_WORKER, 64'd0,
                            {63'd0,
                             dut.u_backend.u_exec.g_3p.u_exec.u_ex0
                                .worker_zbb_q},
                            64'd0, 64'd0);

                    for (ttrace_lane = 0; ttrace_lane < 3;
                         ttrace_lane = ttrace_lane + 1) begin
                        if (dut.u_backend.complete_valid[ttrace_lane]) begin
                            ttrace_reason = dut.u_backend
                                .exec_complete_ready[ttrace_lane] ?
                                `OPENRV64_TTRACE_REASON_NONE :
                                `OPENRV64_TTRACE_REASON_COMPLETION_BACKPRESSURE;
                            ttrace_emit_complete_payload(
                                dut.u_backend.complete_payload[
                                    ttrace_lane*
                                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH],
                                dut.u_backend.complete_id[
                                    ttrace_lane*
                                    `OPENRV64_INSTR_ID_WIDTH +:
                                    `OPENRV64_INSTR_ID_WIDTH],
                                `OPENRV64_TTRACE_STAGE_COMPLETE,
                                dut.u_backend.complete_slot[
                                    ttrace_lane*$clog2(RETIRE_DEPTH) +:
                                    $clog2(RETIRE_DEPTH)],
                                ttrace_lane,
                                dut.u_backend.exec_complete_ready[
                                    ttrace_lane] ?
                                    `OPENRV64_TTRACE_STATE_FIRE :
                                    `OPENRV64_TTRACE_STATE_WAIT,
                                ttrace_reason,
                                {62'd0,
                                 dut.u_backend.exec_complete_ready[
                                     ttrace_lane],
                                 dut.u_backend.complete_valid[ttrace_lane]});
                        end
                    end

                    // LSQ load transactions and store guards.  Address and
                    // transaction phase are sufficient to reconstruct the
                    // memory-side instruction residency of this current cut.
                    for (ttrace_slot = 0;
                         ttrace_slot < TTRACE_LSQ_LOAD_DEPTH;
                         ttrace_slot = ttrace_slot + 1) begin
                        if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                .load_valid_q[ttrace_slot]) begin
                            if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .load_killed_q[ttrace_slot])
                                ttrace_reason =
                                    `OPENRV64_TTRACE_REASON_REDIRECT_SQUASH;
                            else if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.load_immediate_q[
                                             ttrace_slot] ||
                                     dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.load_xlate_fault[
                                             ttrace_slot]) begin
                                if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                        .u_lsq.local_found_r &&
                                    !dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                        .u_lsq.local_store_r &&
                                    (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.local_load_array_index ==
                                     ttrace_slot))
                                    ttrace_reason = dut.u_backend.u_exec.g_3p
                                        .u_exec.u_lsu.u_lsq.result_ready_i ?
                                        `OPENRV64_TTRACE_REASON_NONE :
                                        `OPENRV64_TTRACE_REASON_COMPLETION_BACKPRESSURE;
                                else
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_RESULT_ARBITRATION;
                            end
                            else if (!dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.load_xlate_done_q[
                                             ttrace_slot]) begin
                                if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                        .u_lsq.xlate_resp_valid_i &&
                                    (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.xlate_resp_tag_i ==
                                     ttrace_slot))
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_NONE;
                                else if (dut.u_backend.u_exec.g_3p.u_exec
                                             .u_lsu.u_lsq
                                             .load_xlate_sent_q[ttrace_slot])
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_XLATE_RESPONSE;
                                else if (dut.u_backend.u_exec.g_3p.u_exec
                                             .u_lsu.u_lsq.xlate_req_valid_o &&
                                         !dut.u_backend.u_exec.g_3p.u_exec
                                             .u_lsu.u_lsq.xlate_req_write_o &&
                                         (dut.u_backend.u_exec.g_3p.u_exec
                                              .u_lsu.u_lsq.xlate_req_tag_o ==
                                          ttrace_slot) &&
                                         dut.u_backend.u_exec.g_3p.u_exec
                                             .u_lsu.u_lsq.xlate_req_ready_i)
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_NONE;
                                else
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_XLATE_ARBITRATION;
                            end
                            else if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.load_forward_ready_r[
                                             ttrace_slot] ||
                                     (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                          .u_lsq.forward_valid_q &&
                                      (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                           .u_lsq.forward_load_index_q ==
                                       ttrace_slot))) begin
                                if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                        .u_lsq.result_select_forward &&
                                    (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.forward_load_index_q ==
                                     ttrace_slot))
                                    ttrace_reason = dut.u_backend.u_exec.g_3p
                                        .u_exec.u_lsu.u_lsq.result_ready_i ?
                                        `OPENRV64_TTRACE_REASON_NONE :
                                        `OPENRV64_TTRACE_REASON_COMPLETION_BACKPRESSURE;
                                else
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_RESULT_ARBITRATION;
                            end
                            else if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.load_guard_block_r[
                                             ttrace_slot])
                                ttrace_reason =
                                    `OPENRV64_TTRACE_REASON_STORE_GUARD;
                            else if (!dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.load_access_sent_q[
                                             ttrace_slot] &&
                                     !dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.load_cacheable[
                                             ttrace_slot] &&
                                     !dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.load_order_match[
                                             ttrace_slot])
                                ttrace_reason =
                                    `OPENRV64_TTRACE_REASON_MEMORY_ORDER;
                            else if (!dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.load_access_sent_q[
                                             ttrace_slot]) begin
                                if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                        .u_lsq.req_valid_o &&
                                    !dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                        .u_lsq.req_write_o &&
                                    (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.req_tag_o == ttrace_slot) &&
                                    dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                        .u_lsq.req_ready_i)
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_NONE;
                                else
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_MEMORY_PORT;
                            end else if (dut.u_backend.u_exec.g_3p.u_exec
                                              .u_lsu.u_lsq.resp_valid_i &&
                                         (dut.u_backend.u_exec.g_3p.u_exec
                                              .u_lsu.u_lsq.resp_tag_i ==
                                          ttrace_slot))
                                ttrace_reason = dut.u_backend.u_exec.g_3p
                                    .u_exec.u_lsu.u_lsq.resp_ready_o ?
                                    `OPENRV64_TTRACE_REASON_NONE :
                                    `OPENRV64_TTRACE_REASON_COMPLETION_BACKPRESSURE;
                            else
                                ttrace_reason =
                                    `OPENRV64_TTRACE_REASON_MEMORY_RESPONSE;
                            ttrace_emit_lsq_meta(
                                dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .load_meta_q[ttrace_slot],
                                dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .load_id_q[ttrace_slot],
                                `OPENRV64_TTRACE_STAGE_LSQ, ttrace_slot, 2,
                                `OPENRV64_TTRACE_STATE_LOAD, ttrace_reason,
                                64'd0,
                                {55'd0,
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .load_forward_r[ttrace_slot],
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .load_order_match[ttrace_slot],
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .load_guard_block_r[ttrace_slot],
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .load_killed_q[ttrace_slot],
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .load_access_sent_q[ttrace_slot],
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .load_xlate_done_q[ttrace_slot],
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .load_xlate_sent_q[ttrace_slot],
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .load_immediate_q[ttrace_slot], 1'b1},
                                dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .load_vaddr_q[ttrace_slot],
                                dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .load_paddr_q[ttrace_slot]);
                        end
                    end
                    for (ttrace_slot = 0;
                         ttrace_slot < TTRACE_LSQ_STORE_DEPTH;
                         ttrace_slot = ttrace_slot + 1) begin
                        if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                .store_valid_q[ttrace_slot]) begin
                            if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .store_killed_q[ttrace_slot])
                                ttrace_reason =
                                    `OPENRV64_TTRACE_REASON_REDIRECT_SQUASH;
                            else if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.store_atomic_q[
                                             ttrace_slot]) begin
                                if (!dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.store_order_match[
                                             ttrace_slot])
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_MEMORY_ORDER;
                                else if (dut.u_backend.u_exec.g_3p.u_exec
                                             .u_lsu.u_lsq
                                             .atomic_start_valid_o &&
                                         (dut.u_backend.u_exec.g_3p.u_exec
                                              .u_lsu.u_lsq
                                              .atomic_start_tag_o ==
                                          TTRACE_LSQ_LOAD_DEPTH +
                                          ttrace_slot))
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_NONE;
                                else
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_ATOMIC_UNIT;
                            end else if (dut.u_backend.u_exec.g_3p.u_exec
                                              .u_lsu.u_lsq
                                              .store_immediate_q[
                                                  ttrace_slot] ||
                                         dut.u_backend.u_exec.g_3p.u_exec
                                             .u_lsu.u_lsq.store_xlate_fault[
                                                 ttrace_slot]) begin
                                if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                        .u_lsq.local_found_r &&
                                    dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                        .u_lsq.local_store_r &&
                                    (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.local_store_array_index ==
                                     ttrace_slot))
                                    ttrace_reason = dut.u_backend.u_exec.g_3p
                                        .u_exec.u_lsu.u_lsq.result_ready_i ?
                                        `OPENRV64_TTRACE_REASON_NONE :
                                        `OPENRV64_TTRACE_REASON_COMPLETION_BACKPRESSURE;
                                else
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_RESULT_ARBITRATION;
                            end
                            else if (!dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.store_xlate_done_q[
                                             ttrace_slot]) begin
                                if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                        .u_lsq.xlate_resp_valid_i &&
                                    (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.xlate_resp_tag_i ==
                                     TTRACE_LSQ_LOAD_DEPTH + ttrace_slot))
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_NONE;
                                else if (dut.u_backend.u_exec.g_3p.u_exec
                                             .u_lsu.u_lsq
                                             .store_xlate_sent_q[ttrace_slot])
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_XLATE_RESPONSE;
                                else if (dut.u_backend.u_exec.g_3p.u_exec
                                             .u_lsu.u_lsq.xlate_req_valid_o &&
                                         dut.u_backend.u_exec.g_3p.u_exec
                                             .u_lsu.u_lsq.xlate_req_write_o &&
                                         (dut.u_backend.u_exec.g_3p.u_exec
                                              .u_lsu.u_lsq.xlate_req_tag_o ==
                                          TTRACE_LSQ_LOAD_DEPTH +
                                          ttrace_slot) &&
                                         dut.u_backend.u_exec.g_3p.u_exec
                                             .u_lsu.u_lsq.xlate_req_ready_i)
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_NONE;
                                else
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_XLATE_ARBITRATION;
                            end
                            else if (!dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.store_access_sent_q[
                                             ttrace_slot] &&
                                     !dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.store_order_match[
                                             ttrace_slot])
                                ttrace_reason =
                                    `OPENRV64_TTRACE_REASON_MEMORY_ORDER;
                            else if (!dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.store_access_sent_q[
                                             ttrace_slot]) begin
                                if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                        .u_lsq.req_valid_o &&
                                    dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                        .u_lsq.req_write_o &&
                                    (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.req_tag_o ==
                                     TTRACE_LSQ_LOAD_DEPTH + ttrace_slot) &&
                                    dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                        .u_lsq.req_ready_i)
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_NONE;
                                else
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_MEMORY_PORT;
                            end else if (dut.u_backend.u_exec.g_3p.u_exec
                                              .u_lsu.u_lsq
                                              .store_cacheable[
                                                  ttrace_slot] &&
                                         !dut.u_backend.u_exec.g_3p.u_exec
                                              .u_lsu.u_lsq
                                              .store_result_sent_q[
                                                  ttrace_slot]) begin
                                if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                        .u_lsq.local_found_r &&
                                    dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                        .u_lsq.local_store_r &&
                                    (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.local_store_array_index ==
                                     ttrace_slot))
                                    ttrace_reason = dut.u_backend.u_exec.g_3p
                                        .u_exec.u_lsu.u_lsq.result_ready_i ?
                                        `OPENRV64_TTRACE_REASON_NONE :
                                        `OPENRV64_TTRACE_REASON_COMPLETION_BACKPRESSURE;
                                else
                                    ttrace_reason =
                                        `OPENRV64_TTRACE_REASON_RESULT_ARBITRATION;
                            end else if (dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.store_result_sent_q[
                                             ttrace_slot] &&
                                     !dut.u_backend.u_exec.g_3p.u_exec.u_lsu
                                         .u_lsq.store_access_done_q[
                                             ttrace_slot])
                                ttrace_reason =
                                    `OPENRV64_TTRACE_REASON_POSTED_STORE_ACK;
                            else if (dut.u_backend.u_exec.g_3p.u_exec
                                              .u_lsu.u_lsq.resp_valid_i &&
                                         (dut.u_backend.u_exec.g_3p.u_exec
                                              .u_lsu.u_lsq.resp_tag_i ==
                                          TTRACE_LSQ_LOAD_DEPTH +
                                          ttrace_slot))
                                ttrace_reason = dut.u_backend.u_exec.g_3p
                                    .u_exec.u_lsu.u_lsq.resp_ready_o ?
                                    `OPENRV64_TTRACE_REASON_NONE :
                                    `OPENRV64_TTRACE_REASON_COMPLETION_BACKPRESSURE;
                            else
                                ttrace_reason =
                                    `OPENRV64_TTRACE_REASON_MEMORY_RESPONSE;
                            ttrace_emit_lsq_meta(
                                dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .store_meta_q[ttrace_slot],
                                dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .store_id_q[ttrace_slot],
                                `OPENRV64_TTRACE_STAGE_LSQ, ttrace_slot, 3,
                                `OPENRV64_TTRACE_STATE_STORE, ttrace_reason,
                                64'd0,
                                {54'd0,
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .store_atomic_q[ttrace_slot],
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .store_order_match[ttrace_slot],
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .store_killed_q[ttrace_slot],
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .store_access_done_q[ttrace_slot],
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .store_result_sent_q[ttrace_slot],
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .store_access_sent_q[ttrace_slot],
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .store_xlate_done_q[ttrace_slot],
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .store_xlate_sent_q[ttrace_slot],
                                 dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .store_immediate_q[ttrace_slot], 1'b1},
                                dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .store_vaddr_q[ttrace_slot],
                                dut.u_backend.u_exec.g_3p.u_exec.u_lsu.u_lsq
                                    .store_paddr_q[ttrace_slot]);
                        end
                    end

                    // ROB is an independent residency component.  It remains
                    // present from allocation through ordered retirement.
                    for (ttrace_slot = 0; ttrace_slot < RETIRE_DEPTH;
                         ttrace_slot = ttrace_slot + 1) begin
                        if (dut.u_backend.u_retire_queue.valid_q[
                                ttrace_slot]) begin
                            ttrace_uid = dut.u_backend.u_retire_records
                                .g_trace.trace_q[ttrace_slot];
                            ttrace_detail0 = 64'd0;
                            ttrace_detail0[4:0] = dut.u_backend
                                .u_retire_records.alloc_q[ttrace_slot][
                                    `OPENRV64_RETIRE_ALLOC_RS1_LSB +: 5];
                            ttrace_detail0[12:8] = dut.u_backend
                                .u_retire_records.alloc_q[ttrace_slot][
                                    `OPENRV64_RETIRE_ALLOC_RS2_LSB +: 5];
                            ttrace_detail0[20:16] = dut.u_backend
                                .u_retire_records.alloc_q[ttrace_slot][
                                    `OPENRV64_RETIRE_ALLOC_RD_LSB +: 5];
                            ttrace_detail0[24] = dut.u_backend
                                .u_retire_records.alloc_q[ttrace_slot][
                                    `OPENRV64_RETIRE_ALLOC_REG_WRITE_BIT];
                            ttrace_detail0[25] = dut.u_backend
                                .u_retire_records.alloc_q[ttrace_slot][
                                    `OPENRV64_RETIRE_ALLOC_USES_RS1_BIT];
                            ttrace_detail0[26] = dut.u_backend
                                .u_retire_records.alloc_q[ttrace_slot][
                                    `OPENRV64_RETIRE_ALLOC_USES_RS2_BIT];
                            ttrace_detail0[27] = dut.u_backend
                                .u_retire_records.alloc_q[ttrace_slot][
                                    `OPENRV64_RETIRE_ALLOC_HARD_BIT];
                            ttrace_detail0[28] = dut.u_backend
                                .u_retire_records.alloc_q[ttrace_slot][
                                    `OPENRV64_RETIRE_ALLOC_MEM_READ_BIT];
                            ttrace_detail0[29] = dut.u_backend
                                .u_retire_records.alloc_q[ttrace_slot][
                                    `OPENRV64_RETIRE_ALLOC_MEM_WRITE_BIT];
                            ttrace_detail0[30] = dut.u_backend
                                .u_retire_records.alloc_q[ttrace_slot][
                                    `OPENRV64_RETIRE_ALLOC_BRANCH_BIT];
                            ttrace_detail0[31] = dut.u_backend
                                .u_retire_records.alloc_q[ttrace_slot][
                                    `OPENRV64_RETIRE_ALLOC_JUMP_BIT];
                            ttrace_detail0[32] = dut.u_backend
                                .u_retire_records.alloc_q[ttrace_slot][
                                    `OPENRV64_RETIRE_ALLOC_PREDICTED_TAKEN_BIT];
                            ttrace_detail0[47:40] = dut.u_backend
                                .u_retire_records.alloc_q[ttrace_slot][
                                    `OPENRV64_RETIRE_ALLOC_NEW_PHYS_LSB +:
                                    $clog2(PHYS_REG_COUNT + 1)];
                            if (!dut.u_backend.u_retire_queue.complete_q[
                                    ttrace_slot]) begin
                                ttrace_state =
                                    `OPENRV64_TTRACE_STATE_INCOMPLETE;
                                ttrace_reason =
                                    `OPENRV64_TTRACE_REASON_ROB_INCOMPLETE;
                            end else if (ttrace_slot ==
                                         dut.u_backend.u_retire_queue.head_q) begin
                                ttrace_state =
                                    `OPENRV64_TTRACE_STATE_HEAD;
                                ttrace_reason = dut.u_backend
                                    .queue_retire_accept[0] ?
                                    `OPENRV64_TTRACE_REASON_NONE :
                                    `OPENRV64_TTRACE_REASON_RETIRE_BACKPRESSURE;
                            end else begin
                                ttrace_state =
                                    `OPENRV64_TTRACE_STATE_COMPLETE;
                                ttrace_reason =
                                    `OPENRV64_TTRACE_REASON_ROB_ORDER;
                            end
                            ttrace_emit(ttrace_uid,
                                dut.u_backend.u_retire_queue.id_q[
                                    ttrace_slot],
                                dut.u_backend.u_retire_records.alloc_q[
                                    ttrace_slot][
                                        `OPENRV64_RETIRE_ALLOC_PC_LSB +: 64],
                                dut.u_backend.u_retire_records.alloc_q[
                                    ttrace_slot][
                                        `OPENRV64_RETIRE_ALLOC_INSTR_LSB +:
                                        32],
                                `OPENRV64_TTRACE_STAGE_ROB, ttrace_slot,
                                -1, ttrace_state, ttrace_reason, 64'd0,
                                {60'd0,
                                 (ttrace_slot ==
                                  dut.u_backend.u_retire_queue.head_q),
                                 dut.u_backend.u_retire_queue.complete_q[
                                     ttrace_slot],
                                 dut.u_backend.u_retire_queue.valid_q[
                                     ttrace_slot], 1'b1},
                                ttrace_detail0,
                                dut.u_backend.u_retire_records.result_q[
                                    ttrace_slot][
                                        `OPENRV64_RETIRE_RESULT_DATA_LSB +:
                                        64]);
                        end
                    end

                    // Ordered retirement candidates.  FIRE names the exact
                    // lanes accepted on the next rising edge of this cycle.
                    for (ttrace_lane = 0; ttrace_lane < 3;
                         ttrace_lane = ttrace_lane + 1) begin
                        if (dut.u_backend.queue_retire_valid[ttrace_lane]) begin
                            ttrace_reason = dut.u_backend
                                .queue_retire_accept[ttrace_lane] ?
                                `OPENRV64_TTRACE_REASON_NONE :
                                `OPENRV64_TTRACE_REASON_RETIRE_BACKPRESSURE;
                            ttrace_emit_complete_payload(
                                dut.u_backend.queue_retire_result[
                                    ttrace_lane*
                                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH +:
                                    `OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH],
                                dut.u_backend.queue_retire_id[
                                    ttrace_lane*
                                    `OPENRV64_INSTR_ID_WIDTH +:
                                    `OPENRV64_INSTR_ID_WIDTH],
                                `OPENRV64_TTRACE_STAGE_RETIRE,
                                dut.u_backend.queue_retire_slot[
                                    ttrace_lane*$clog2(RETIRE_DEPTH) +:
                                    $clog2(RETIRE_DEPTH)],
                                ttrace_lane,
                                dut.u_backend.queue_retire_accept[
                                    ttrace_lane] ?
                                    `OPENRV64_TTRACE_STATE_FIRE :
                                    `OPENRV64_TTRACE_STATE_WAIT,
                                ttrace_reason,
                                {62'd0,
                                 dut.u_backend.queue_retire_accept[
                                     ttrace_lane],
                                 dut.u_backend.queue_retire_valid[
                                     ttrace_lane]});
                        end
                    end

                    if ((ttrace_flush_cycles > 0) &&
                        ((ttrace_cycle % ttrace_flush_cycles) == 0))
                        $fflush(ttrace_fd);
                end
            end
        end

        final begin
            if (ttrace_fd != 0) begin
                $fflush(ttrace_fd);
                $fclose(ttrace_fd);
                $display("PIPELINE_STATE_TRACE_DONE rows=%0d path=%0s",
                         ttrace_rows, ttrace_path);
            end
        end
    end else begin : g_no_tomasulo_pipeline_state_trace
        initial begin
            if ($test$plusargs("pipeline_state_trace"))
                $fatal(1,
                    "+pipeline_state_trace requires Tomasulo mode and an ENABLE_PIPELINE_STATE_TRACE=1 build");
        end
    end
endgenerate
