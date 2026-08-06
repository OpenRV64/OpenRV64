`timescale 1ns/1ps
`include "complex/protocol/defs.v"

// SoC/core-complex performance events and a small configurable counter bank.
//
// NUM_COUNTERS defaults to eight 64-bit wrapping registers.  Each register
// receives a 40-bit route mask through counter_event_mask_i and increments by
// the number of selected event pulses asserted in a cycle.  The same pulse
// vector remains visible for an external cycle trace.
//
// Arbitration and L2 policy decisions are explicit inputs.  This block must
// not guess why valid/ready backpressure occurred when the arbiter, lock
// manager, and L2 controller can report the exact cause.
//
// event_pulses_o and route-mask bit assignments:
//
//   0 cycle                       20 L2 blocked by another line
//   1 ICX request accepted        21 L2 merge full
//   2 I-cache request             22 L2 lock blocked
//   3 D-cache request             23 L2 refill line
//   4 PTW request                 24 L2 writeback line
//   5 ICX read                    25 clean eviction
//   6 ICX write                   26 dirty eviction
//   7 ICX atomic                  27 L2 miss active
//   8 ICX fence                   28 L2 merge queue occupied
//   9 arbitration wait            29 L2 response backpressure
//  10 downstream wait             30 lock held
//  11 lock wait                   31 external-bus request
//  12 credit wait                 32 external-bus response
//  13 ICX response backpressure   33 external-bus read
//  14 ICX outstanding             34 external-bus write
//  15 L2 access                   35 external request wait
//  16 L2 hit                      36 external response wait
//  17 L2 miss                     37 external response backpressure
//  18 L2 bypass                   38 external-bus error
//  19 same-line merge             39 ICX response error
module openrv64_soc_trace #(
    parameter integer COUNTER_WIDTH = 64,
    parameter integer NUM_COUNTERS = 8,
    parameter integer COUNTER_INDEX_WIDTH =
        (NUM_COUNTERS > 1) ? $clog2(NUM_COUNTERS) : 1
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,
    input  wire                         enable_i,
    input  wire                         clear_i,

    input  wire                         icx_req_valid_i,
    input  wire                         icx_req_ready_i,
    input  wire [`OPENRV64_ICX_SOURCE_ID_WIDTH-1:0]
                                             icx_req_source_i,
    input  wire [`OPENRV64_ICX_OP_WIDTH-1:0] icx_req_op_i,
    input  wire                         icx_req_arb_wait_i,
    input  wire                         icx_req_downstream_wait_i,
    input  wire                         icx_req_lock_wait_i,
    input  wire                         icx_req_credit_wait_i,
    input  wire                         icx_outstanding_i,
    input  wire                         icx_resp_valid_i,
    input  wire                         icx_resp_ready_i,
    input  wire                         icx_resp_error_i,

    input  wire                         l2_access_i,
    input  wire                         l2_hit_i,
    input  wire                         l2_miss_i,
    input  wire                         l2_bypass_i,
    input  wire                         l2_merge_i,
    input  wire                         l2_block_other_line_i,
    input  wire                         l2_merge_full_i,
    input  wire                         l2_lock_block_i,
    input  wire                         l2_refill_line_i,
    input  wire                         l2_writeback_line_i,
    input  wire                         l2_clean_evict_i,
    input  wire                         l2_dirty_evict_i,
    input  wire                         l2_miss_active_i,
    input  wire [4:0]                   l2_merge_occupancy_i,
    input  wire                         l2_resp_backpressure_i,
    input  wire                         l2_lock_active_i,

    input  wire                         bus_req_valid_i,
    input  wire                         bus_req_ready_i,
    input  wire                         bus_req_write_i,
    input  wire                         bus_outstanding_i,
    input  wire                         bus_resp_valid_i,
    input  wire                         bus_resp_ready_i,
    input  wire                         bus_resp_error_i,

    input  wire [NUM_COUNTERS*40-1:0]  counter_event_mask_i,
    input  wire [COUNTER_INDEX_WIDTH-1:0] counter_select_i,
    output reg  [COUNTER_WIDTH-1:0]     counter_value_o,
    output wire [39:0]                  event_pulses_o
);

    localparam integer EVENT_COUNT = 40;
    localparam integer INCREMENT_WIDTH = 6;

    reg [COUNTER_WIDTH-1:0] counter_q [0:NUM_COUNTERS-1];
    wire [EVENT_COUNT-1:0] event_pulses_raw;

    wire icx_req_fire = icx_req_valid_i && icx_req_ready_i;
    wire icx_resp_fire = icx_resp_valid_i && icx_resp_ready_i;
    wire icx_req_atomic = icx_req_fire &&
        (icx_req_op_i >= `OPENRV64_ICX_OP_LR) &&
        (icx_req_op_i <= `OPENRV64_ICX_OP_AMOMAXU);
    wire bus_req_fire = bus_req_valid_i && bus_req_ready_i;
    wire bus_resp_fire = bus_resp_valid_i && bus_resp_ready_i;
    wire bus_response_wait = bus_outstanding_i && !bus_resp_valid_i;

    assign event_pulses_raw = {
        (icx_resp_fire && icx_resp_error_i),       // 39
        (bus_resp_fire && bus_resp_error_i),       // 38
        (bus_resp_valid_i && !bus_resp_ready_i),   // 37
        bus_response_wait,                         // 36
        (bus_req_valid_i && !bus_req_ready_i),     // 35
        (bus_req_fire && bus_req_write_i),         // 34
        (bus_req_fire && !bus_req_write_i),        // 33
        bus_resp_fire,                             // 32
        bus_req_fire,                              // 31
        l2_lock_active_i,                          // 30
        l2_resp_backpressure_i,                    // 29
        (l2_merge_occupancy_i != 0),               // 28
        l2_miss_active_i,                          // 27
        l2_dirty_evict_i,                          // 26
        l2_clean_evict_i,                          // 25
        l2_writeback_line_i,                       // 24
        l2_refill_line_i,                          // 23
        l2_lock_block_i,                           // 22
        l2_merge_full_i,                           // 21
        l2_block_other_line_i,                     // 20
        l2_merge_i,                                // 19
        l2_bypass_i,                               // 18
        l2_miss_i,                                 // 17
        l2_hit_i,                                  // 16
        l2_access_i,                               // 15
        icx_outstanding_i,                         // 14
        (icx_resp_valid_i && !icx_resp_ready_i),   // 13
        icx_req_credit_wait_i,                     // 12
        icx_req_lock_wait_i,                       // 11
        icx_req_downstream_wait_i,                 // 10
        icx_req_arb_wait_i,                        // 9
        (icx_req_fire &&
         (icx_req_op_i == `OPENRV64_ICX_OP_FENCE)), // 8
        icx_req_atomic,                            // 7
        (icx_req_fire &&
         (icx_req_op_i == `OPENRV64_ICX_OP_WRITE)), // 6
        (icx_req_fire &&
         (icx_req_op_i == `OPENRV64_ICX_OP_READ)), // 5
        (icx_req_fire &&
         (icx_req_source_i == `OPENRV64_ICX_SOURCE_PTW)), // 4
        (icx_req_fire &&
         (icx_req_source_i == `OPENRV64_ICX_SOURCE_DCACHE)), // 3
        (icx_req_fire &&
         (icx_req_source_i == `OPENRV64_ICX_SOURCE_ICACHE)), // 2
        icx_req_fire,                              // 1
        1'b1                                       // 0
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

`ifndef SYNTHESIS
    initial begin
        if (NUM_COUNTERS < 1)
            $fatal(1, "SoC trace requires at least one counter");
        if (COUNTER_WIDTH < INCREMENT_WIDTH)
            $fatal(1, "SoC trace COUNTER_WIDTH is too small");
    end
`endif

endmodule
