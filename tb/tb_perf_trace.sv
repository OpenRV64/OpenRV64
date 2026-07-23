`timescale 1ns/1ps
`include "complex/protocol/defs.v"

module tb_perf_trace;
    localparam int NUM_COUNTERS = 8;

    logic clk;
    logic rst_n;
    logic enable;
    logic clear;

    logic [1:0] issue_count;
    logic [1:0] retire_count;
    logic frontend_empty;
    logic frontend_valid;
    logic redirect;
    logic fetch_cancel;
    logic [1:0] issue_slots_lost;
    logic [NUM_COUNTERS*38-1:0] core_masks;
    logic [2:0] core_select;
    wire [63:0] core_value;
    wire [37:0] core_events;

    logic ccx_req_valid;
    logic ccx_req_ready;
    logic [`OPENRV64_CCX_SOURCE_ID_WIDTH-1:0] ccx_req_source;
    logic [`OPENRV64_CCX_OP_WIDTH-1:0] ccx_req_op;
    logic ccx_resp_valid;
    logic ccx_resp_ready;
    logic ccx_resp_error;
    logic l2_hit;
    logic l2_miss;
    logic l2_bypass;
    logic l2_block_other_line;
    logic l2_merge_full;
    logic l2_lock_block;
    logic bus_req_valid;
    logic bus_req_ready;
    logic bus_req_write;
    logic bus_resp_valid;
    logic bus_resp_ready;
    logic bus_resp_error;
    logic [NUM_COUNTERS*40-1:0] soc_masks;
    logic [2:0] soc_select;
    wire [63:0] soc_value;
    wire [39:0] soc_events;

    openrv64_core_perf #(
        .NUM_COUNTERS(NUM_COUNTERS)
    ) u_core_perf (
        .clk_i(clk), .rst_ni(rst_n), .enable_i(enable), .clear_i(clear),
        .issue_count_i(issue_count), .retire_count_i(retire_count),
        .frontend_empty_i(frontend_empty),
        .frontend_valid_i(frontend_valid),
        .dispatch_empty_i(1'b0), .raw_stall_i(1'b0),
        .barrier_stall_i(1'b0), .pipe_busy_stall_i(1'b0),
        .redirect_i(redirect), .branch_direction_miss_i(1'b0),
        .branch_target_miss_i(1'b0), .fetch_req_fire_i(1'b0),
        .fetch_resp_fire_i(1'b0), .fetch_cancel_i(fetch_cancel),
        .lsu_req_fire_i(1'b0), .lsu_resp_fire_i(1'b0),
        .lsu_req_wait_i(1'b0), .lsu_outstanding_i(1'b0),
        .l1i_demand_hit_i(1'b0), .l1i_demand_miss_i(1'b0),
        .l1i_prefetch_launch_i(1'b0), .l1i_prefetch_useful_i(1'b0),
        .l1i_demand_wait_prefetch_i(1'b0), .l1d_load_hit_i(1'b0),
        .l1d_load_miss_i(1'b0), .l1d_store_i(1'b0),
        .retire_head_incomplete_i(1'b0),
        .retire_completed_behind_i(1'b0),
        .issue_slots_lost_i(issue_slots_lost),
        .counter_event_mask_i(core_masks),
        .counter_select_i(core_select), .counter_value_o(core_value),
        .event_pulses_o(core_events)
    );

    openrv64_soc_trace #(
        .NUM_COUNTERS(NUM_COUNTERS)
    ) u_soc_trace (
        .clk_i(clk), .rst_ni(rst_n), .enable_i(enable), .clear_i(clear),
        .ccx_req_valid_i(ccx_req_valid), .ccx_req_ready_i(ccx_req_ready),
        .ccx_req_source_i(ccx_req_source), .ccx_req_op_i(ccx_req_op),
        .ccx_req_arb_wait_i(1'b0), .ccx_req_downstream_wait_i(1'b0),
        .ccx_req_lock_wait_i(1'b0), .ccx_req_credit_wait_i(1'b0),
        .ccx_outstanding_i(1'b0), .ccx_resp_valid_i(ccx_resp_valid),
        .ccx_resp_ready_i(ccx_resp_ready),
        .ccx_resp_error_i(ccx_resp_error), .l2_access_i(1'b1),
        .l2_hit_i(l2_hit), .l2_miss_i(l2_miss),
        .l2_bypass_i(l2_bypass), .l2_merge_i(1'b0),
        .l2_block_other_line_i(l2_block_other_line),
        .l2_merge_full_i(l2_merge_full), .l2_lock_block_i(l2_lock_block),
        .l2_refill_line_i(1'b0), .l2_writeback_line_i(1'b0),
        .l2_clean_evict_i(1'b0), .l2_dirty_evict_i(1'b0),
        .l2_miss_active_i(1'b0), .l2_merge_occupancy_i(5'd0),
        .l2_resp_backpressure_i(1'b0), .l2_lock_active_i(1'b0),
        .bus_req_valid_i(bus_req_valid), .bus_req_ready_i(bus_req_ready),
        .bus_req_write_i(bus_req_write), .bus_outstanding_i(1'b0),
        .bus_resp_valid_i(bus_resp_valid),
        .bus_resp_ready_i(bus_resp_ready),
        .bus_resp_error_i(bus_resp_error),
        .counter_event_mask_i(soc_masks),
        .counter_select_i(soc_select), .counter_value_o(soc_value),
        .event_pulses_o(soc_events)
    );

    always #5 clk = ~clk;

    task automatic check_core;
        input integer index;
        input [63:0] expected;
        begin
            core_select = index[2:0];
            #1;
            if (core_value !== expected)
                $fatal(1, "core counter %0d got %0d expected %0d",
                       index, core_value, expected);
        end
    endtask

    task automatic check_soc;
        input integer index;
        input [63:0] expected;
        begin
            soc_select = index[2:0];
            #1;
            if (soc_value !== expected)
                $fatal(1, "SoC counter %0d got %0d expected %0d",
                       index, soc_value, expected);
        end
    endtask

    task automatic drive_idle;
        begin
            issue_count = 0;
            retire_count = 0;
            frontend_empty = 0;
            frontend_valid = 0;
            redirect = 0;
            fetch_cancel = 0;
            issue_slots_lost = 0;
            ccx_req_valid = 0;
            ccx_req_ready = 0;
            ccx_req_source = `OPENRV64_CCX_SOURCE_ICACHE;
            ccx_req_op = `OPENRV64_CCX_OP_READ;
            ccx_resp_valid = 0;
            ccx_resp_ready = 0;
            ccx_resp_error = 0;
            l2_hit = 0;
            l2_miss = 0;
            l2_bypass = 0;
            l2_block_other_line = 0;
            l2_merge_full = 0;
            l2_lock_block = 0;
            bus_req_valid = 0;
            bus_req_ready = 0;
            bus_req_write = 0;
            bus_resp_valid = 0;
            bus_resp_ready = 0;
            bus_resp_error = 0;
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        enable = 0;
        clear = 0;
        core_select = 0;
        soc_select = 0;
        core_masks = '0;
        soc_masks = '0;
        drive_idle();

        // Core: cycles, issued, retired, frontend empty, redirects,
        // redirect recovery, cancellations, and lost issue slots.
        core_masks[0*38 + 0] = 1'b1;
        core_masks[1*38 + 1 +: 3] = 3'b111;
        core_masks[2*38 + 4 +: 3] = 3'b111;
        core_masks[3*38 + 9] = 1'b1;
        core_masks[4*38 + 14] = 1'b1;
        core_masks[5*38 + 15] = 1'b1;
        core_masks[6*38 + 20] = 1'b1;
        core_masks[7*38 + 35 +: 3] = 3'b111;

        // SoC: cycles, CCX accepts, source classes, operation classes,
        // L2 outcomes, L2 blocking, bus transfers, and transport errors.
        soc_masks[0*40 + 0] = 1'b1;
        soc_masks[1*40 + 1] = 1'b1;
        soc_masks[2*40 + 2 +: 3] = 3'b111;
        soc_masks[3*40 + 5 +: 4] = 4'b1111;
        soc_masks[4*40 + 16 +: 3] = 3'b111;
        soc_masks[5*40 + 20 +: 3] = 3'b111;
        soc_masks[6*40 + 31 +: 2] = 2'b11;
        soc_masks[7*40 + 38 +: 2] = 2'b11;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        enable = 1;

        // Measurement cycle one.
        issue_count = 3;
        retire_count = 2;
        frontend_empty = 1;
        redirect = 1;
        issue_slots_lost = 1;
        ccx_req_valid = 1;
        ccx_req_ready = 1;
        ccx_req_source = `OPENRV64_CCX_SOURCE_ICACHE;
        ccx_req_op = `OPENRV64_CCX_OP_READ;
        l2_hit = 1;
        bus_req_valid = 1;
        bus_req_ready = 1;
        bus_req_write = 0;
        @(posedge clk);
        #1;

        // Measurement cycle two.  Recovery is now active.
        @(negedge clk);
        drive_idle();
        issue_count = 1;
        frontend_empty = 1;
        fetch_cancel = 1;
        issue_slots_lost = 3;
        ccx_req_valid = 1;
        ccx_req_ready = 1;
        ccx_req_source = `OPENRV64_CCX_SOURCE_DCACHE;
        ccx_req_op = `OPENRV64_CCX_OP_WRITE;
        ccx_resp_valid = 1;
        ccx_resp_ready = 1;
        ccx_resp_error = 1;
        l2_miss = 1;
        l2_block_other_line = 1;
        bus_req_valid = 1;
        bus_req_ready = 1;
        bus_req_write = 1;
        bus_resp_valid = 1;
        bus_resp_ready = 1;
        bus_resp_error = 1;
        @(posedge clk);
        #1;

        // Measurement cycle three ends recovery with a valid frontend.
        @(negedge clk);
        drive_idle();
        retire_count = 1;
        frontend_valid = 1;
        ccx_req_valid = 1;
        ccx_req_ready = 1;
        ccx_req_source = `OPENRV64_CCX_SOURCE_PTW;
        ccx_req_op = `OPENRV64_CCX_OP_AMOADD;
        l2_bypass = 1;
        l2_merge_full = 1;
        l2_lock_block = 1;
        @(posedge clk);
        #1;
        enable = 0;

        check_core(0, 3);
        check_core(1, 4);
        check_core(2, 3);
        check_core(3, 2);
        check_core(4, 1);
        check_core(5, 1);
        check_core(6, 1);
        check_core(7, 4);

        check_soc(0, 3);
        check_soc(1, 3);
        check_soc(2, 3);
        check_soc(3, 3);
        check_soc(4, 3);
        check_soc(5, 3);
        check_soc(6, 3);
        check_soc(7, 2);

        // Clear wins over live events, and disabled counters hold zero.
        @(negedge clk);
        clear = 1;
        @(posedge clk);
        #1;
        clear = 0;
        check_core(0, 0);
        check_soc(0, 0);

        @(negedge clk);
        enable = 0;
        issue_count = 3;
        ccx_req_valid = 1;
        ccx_req_ready = 1;
        @(posedge clk);
        #1;
        check_core(0, 0);
        check_core(1, 0);
        check_soc(0, 0);
        check_soc(1, 0);

        $display("PASS: configurable core and SoC performance counters");
        $finish;
    end
endmodule
