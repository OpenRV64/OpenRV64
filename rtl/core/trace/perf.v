`timescale 1ns/1ps
`include "core/cmu/defs.v"

// Core-local performance events and a small configurable counter bank.
//
// NUM_COUNTERS defaults to eight 64-bit wrapping registers.  Each counter has
// a 38-bit route mask in counter_event_mask_i.  A counter adds the number of
// selected event pulses asserted in the current cycle.  This permits one
// counter to select all three issue-lane pulses and count issued instructions,
// while another selects a cycle-level condition such as frontend empty.
// Selecting overlapping semantic events is legal and intentionally counts
// each selected pulse; software or integration logic owns the route masks.
//
// event_pulses_o and route-mask bit assignments:
//
//   0 cycle                         19 fetch response
//   1 issue lane 0                  20 fetch cancellation
//   2 issue lane 1                  21 LSU request
//   3 issue lane 2                  22 LSU response
//   4 retire lane 0                 23 LSU request wait
//   5 retire lane 1                 24 LSU outstanding
//   6 retire lane 2                 25 L1I demand hit
//   7 zero issue                    26 L1I demand miss
//   8 zero retire                   27 L1I prefetch launch
//   9 frontend empty                28 useful L1I prefetch
//  10 dispatch empty                29 demand blocked by prefetch
//  11 RAW stall                     30 L1D load hit
//  12 barrier stall                 31 L1D load miss
//  13 pipe busy                     32 store request accepted
//  14 redirect                      33 retire head incomplete
//  15 redirect recovery             34 completed behind head
//  16 direction mispredict          35 lost issue slot 0
//  17 target mispredict             36 lost issue slot 1
//  18 fetch request                 37 lost issue slot 2
module openrv64_core_perf #(
    parameter integer COUNTER_WIDTH = 64,
    parameter integer NUM_COUNTERS = 8,
    parameter integer COUNTER_INDEX_WIDTH =
        (NUM_COUNTERS > 1) ? $clog2(NUM_COUNTERS) : 1
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,
    input  wire                         enable_i,
    input  wire                         clear_i,

    input  wire [1:0]                   issue_count_i,
    input  wire [1:0]                   retire_count_i,
    input  wire                         frontend_empty_i,
    input  wire                         frontend_valid_i,
    input  wire                         dispatch_empty_i,
    input  wire                         raw_stall_i,
    input  wire                         barrier_stall_i,
    input  wire                         pipe_busy_stall_i,
    input  wire                         redirect_i,
    input  wire                         branch_direction_miss_i,
    input  wire                         branch_target_miss_i,
    input  wire                         fetch_req_fire_i,
    input  wire                         fetch_resp_fire_i,
    input  wire                         fetch_cancel_i,
    input  wire                         lsu_req_fire_i,
    input  wire                         lsu_resp_fire_i,
    input  wire                         lsu_req_wait_i,
    input  wire                         lsu_outstanding_i,
    input  wire                         l1i_demand_hit_i,
    input  wire                         l1i_demand_miss_i,
    input  wire                         l1i_prefetch_launch_i,
    input  wire                         l1i_prefetch_useful_i,
    input  wire                         l1i_demand_wait_prefetch_i,
    input  wire                         l1d_load_hit_i,
    input  wire                         l1d_load_miss_i,
    input  wire                         l1d_store_i,
    input  wire                         retire_head_incomplete_i,
    input  wire                         retire_completed_behind_i,
    input  wire [1:0]                   issue_slots_lost_i,

    input  wire [NUM_COUNTERS*`OPENRV64_CMU_EVENT_COUNT-1:0]
                                             counter_event_mask_i,
    input  wire [COUNTER_INDEX_WIDTH-1:0] counter_select_i,
    output reg  [COUNTER_WIDTH-1:0]     counter_value_o,
    output wire [`OPENRV64_CMU_EVENT_COUNT-1:0] event_pulses_o
);

    localparam integer EVENT_COUNT = `OPENRV64_CMU_EVENT_COUNT;
    localparam integer INCREMENT_WIDTH = 6;

    reg [COUNTER_WIDTH-1:0] counter_q [0:NUM_COUNTERS-1];
    reg redirect_recovery_q;
    wire [EVENT_COUNT-1:0] event_pulses_raw;

    wire redirect_recovery_cycle = redirect_recovery_q &&
                                   frontend_empty_i;

    assign event_pulses_raw = {
        (issue_slots_lost_i >= 2'd3),            // 37
        (issue_slots_lost_i >= 2'd2),            // 36
        (issue_slots_lost_i >= 2'd1),            // 35
        retire_completed_behind_i,                // 34
        retire_head_incomplete_i,                 // 33
        l1d_store_i,                              // 32
        l1d_load_miss_i,                          // 31
        l1d_load_hit_i,                           // 30
        l1i_demand_wait_prefetch_i,               // 29
        l1i_prefetch_useful_i,                    // 28
        l1i_prefetch_launch_i,                    // 27
        l1i_demand_miss_i,                        // 26
        l1i_demand_hit_i,                         // 25
        lsu_outstanding_i,                        // 24
        lsu_req_wait_i,                           // 23
        lsu_resp_fire_i,                          // 22
        lsu_req_fire_i,                           // 21
        fetch_cancel_i,                           // 20
        fetch_resp_fire_i,                        // 19
        fetch_req_fire_i,                         // 18
        branch_target_miss_i,                     // 17
        branch_direction_miss_i,                  // 16
        redirect_recovery_cycle,                  // 15
        redirect_i,                               // 14
        pipe_busy_stall_i,                        // 13
        barrier_stall_i,                          // 12
        raw_stall_i,                              // 11
        dispatch_empty_i,                         // 10
        frontend_empty_i,                         // 9
        (retire_count_i == 0),                    // 8
        (issue_count_i == 0),                     // 7
        (retire_count_i >= 2'd3),                 // 6
        (retire_count_i >= 2'd2),                 // 5
        (retire_count_i >= 2'd1),                 // 4
        (issue_count_i >= 2'd3),                  // 3
        (issue_count_i >= 2'd2),                  // 2
        (issue_count_i >= 2'd1),                  // 1
        1'b1                                      // 0
    };
    assign event_pulses_o = event_pulses_raw & {EVENT_COUNT{rst_ni}};

    function [INCREMENT_WIDTH-1:0] count_events;
        input [EVENT_COUNT-1:0] events;
        integer event_index;
        begin
            count_events = {INCREMENT_WIDTH{1'b0}};
            for (event_index = 0; event_index < EVENT_COUNT;
                 event_index = event_index + 1)
                count_events = count_events + events[event_index];
        end
    endfunction

    genvar counter_index;
    generate
        for (counter_index = 0; counter_index < NUM_COUNTERS;
             counter_index = counter_index + 1) begin : g_counter
            wire [EVENT_COUNT-1:0] selected_events = event_pulses_o &
                counter_event_mask_i[counter_index*EVENT_COUNT +:
                                     EVENT_COUNT];
            wire [INCREMENT_WIDTH-1:0] increment =
                count_events(selected_events);

            always @(posedge clk_i or negedge rst_ni) begin
                if (!rst_ni)
                    counter_q[counter_index] <= {COUNTER_WIDTH{1'b0}};
                else if (clear_i)
                    counter_q[counter_index] <= {COUNTER_WIDTH{1'b0}};
                else if (enable_i && (increment != 0))
                    counter_q[counter_index] <=
                        counter_q[counter_index] + increment;
            end
        end
    endgenerate

    always @* begin
        if (counter_select_i < NUM_COUNTERS)
            counter_value_o = counter_q[counter_select_i];
        else
            counter_value_o = {COUNTER_WIDTH{1'b0}};
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            redirect_recovery_q <= 1'b0;
        else if (clear_i)
            redirect_recovery_q <= 1'b0;
        else if (redirect_i)
            redirect_recovery_q <= 1'b1;
        else if (frontend_valid_i)
            redirect_recovery_q <= 1'b0;
    end

`ifndef SYNTHESIS
    initial begin
        if (NUM_COUNTERS < 1)
            $fatal(1, "core perf requires at least one counter");
        if (COUNTER_WIDTH < INCREMENT_WIDTH)
            $fatal(1, "core perf COUNTER_WIDTH is too small");
    end
`endif

endmodule
