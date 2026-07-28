`timescale 1ns/1ps

// Bank-parallel transaction-level DRAM timing engine.
//
// Commands enter a tagged scheduling queue.  An idle bank may begin row
// preparation independently of every other bank.  Once a bank reaches its
// column/data phase, native DRAM bursts arbitrate onto one shared data bus.
// Multi-burst commands therefore consume explicit bus slots rather than
// folding tCCD into one aggregate command delay.  Adjacent same-row,
// same-direction commands may join an active bank run and issue their first
// burst at tCCD spacing.  Every independently accepted command pays the
// configured controller frontend/backend latency; northbound packetization
// does not erase those delays.  Tags remain independent so completions fan
// back out to their original transport requests.
// Banks may prepare work while another bank transfers data, and completions
// may return out of command-acceptance order.
//
// This is still a transaction-level controller fixture, not a pin-level DRAM
// model.  It models dependency-safe read/write reordering, RoRaBaCo rank/bank
// mapping, rank turnarounds, activation spacing, open-row grouping, independent
// bank progress, and serialized native-burst data transfer.  Optional frontend
// and backend delays model controller/PHY pipelines without occupying a bank
// or the shared data bus, so multiple commands may remain in flight through
// both.
module openrv64_timing_dram_banked #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer TAG_WIDTH = 8,
    parameter integer DQ_WIDTH = 64,
    parameter integer BURST_LENGTH = 8,
    parameter integer BURST_CYCLES = 4,
    parameter integer BANK_BITS = 3,
    parameter integer BANK_ROW_SWIZZLE = 0,
    parameter integer RANKS = 1,
    parameter integer ROW_BYTES = 8192,
    parameter integer CONTROLLER_TCK_PS = 1000,
    parameter integer DRAM_TCK_PS = 1250,
    parameter integer T_RCD_RD = 11,
    parameter integer T_RCD_WR = 11,
    parameter integer T_RP = 11,
    parameter integer T_RAS = 28,
    parameter integer T_WR = 12,
    parameter integer T_CL = 11,
    parameter integer T_CWL = 11,
    parameter integer T_CCD = 4,
    parameter integer T_RTP_PS = 0,
    parameter integer T_WTR_PS = 0,
    parameter integer T_RTW_PS = 0,
    parameter integer T_CS_PS = 0,
    parameter integer T_RRD_PS = 0,
    parameter integer T_XAW_PS = 0,
    parameter integer ACTIVATION_LIMIT = 0,
    parameter integer T_RFC = 208,
    parameter integer REFRESH_INTERVAL = 6240,
    parameter integer FRONTEND_LATENCY_PS = 0,
    parameter integer BACKEND_LATENCY_PS = 0,
    parameter integer COMMAND_QUEUE_DEPTH = 16,
    parameter integer MAX_BURST_TRAIN_BURSTS = 8,
    parameter integer MAX_ACCESSES_PER_ROW = 0,
    parameter integer MIN_READS_PER_SWITCH = 0,
    parameter integer MIN_WRITES_PER_SWITCH = 0
) (
    input  wire                  clk_i,
    input  wire                  rst_ni,

    input  wire                  cmd_valid_i,
    output wire                  cmd_ready_o,
    input  wire                  cmd_write_i,
    input  wire [ADDR_WIDTH-1:0] cmd_addr_i,
    input  wire [15:0]           cmd_bytes_i,
    input  wire [TAG_WIDTH-1:0]  cmd_tag_i,

    output wire                  resp_valid_o,
    output wire [TAG_WIDTH-1:0]  resp_tag_o,
    input  wire                  resp_ready_i
);

    localparam integer BANK_COUNT = 1 << BANK_BITS;
    localparam integer RANK_ADDRESS_BITS =
        (RANKS > 1) ? $clog2(RANKS) : 0;
    localparam integer RANK_INDEX_WIDTH =
        (RANKS > 1) ? $clog2(RANKS) : 1;
    localparam integer BANK_MACHINE_COUNT = BANK_COUNT * RANKS;
    localparam integer BANK_MACHINE_INDEX_WIDTH =
        (BANK_MACHINE_COUNT > 1) ? $clog2(BANK_MACHINE_COUNT) : 1;
    localparam integer ROW_OFFSET_BITS = $clog2(ROW_BYTES);
    localparam integer ROW_TAG_WIDTH =
        ADDR_WIDTH - ROW_OFFSET_BITS - BANK_BITS - RANK_ADDRESS_BITS;
    localparam integer NATIVE_BURST_BITS = DQ_WIDTH * BURST_LENGTH;
    localparam integer NATIVE_BURST_BYTES = NATIVE_BURST_BITS / 8;
    localparam integer NATIVE_BURST_OFFSET_BITS =
        $clog2(NATIVE_BURST_BYTES);
    localparam integer QUEUE_PTR_WIDTH =
        (COMMAND_QUEUE_DEPTH > 1) ? $clog2(COMMAND_QUEUE_DEPTH) : 1;
    localparam integer QUEUE_COUNT_WIDTH =
        $clog2(COMMAND_QUEUE_DEPTH + 1);
    localparam integer BURST_OCCUPANCY_CYCLES =
        (BURST_CYCLES * DRAM_TCK_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;
    localparam integer T_CCD_CONTROLLER_CYCLES =
        (T_CCD * DRAM_TCK_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;
    localparam integer T_RAS_CONTROLLER_CYCLES =
        (T_RAS * DRAM_TCK_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;
    localparam integer T_WR_CONTROLLER_CYCLES =
        (T_WR * DRAM_TCK_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;
    localparam integer T_CL_CONTROLLER_CYCLES =
        (T_CL * DRAM_TCK_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;
    localparam integer T_CWL_CONTROLLER_CYCLES =
        (T_CWL * DRAM_TCK_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;
    localparam integer T_RP_CONTROLLER_CYCLES =
        (T_RP * DRAM_TCK_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;
    localparam integer T_RTP_CONTROLLER_CYCLES =
        (T_RTP_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;
    localparam integer T_WTR_CONTROLLER_CYCLES =
        (T_WTR_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;
    localparam integer T_RTW_CONTROLLER_CYCLES =
        (T_RTW_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;
    localparam integer T_CS_CONTROLLER_CYCLES =
        (T_CS_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;
    localparam integer T_RRD_CONTROLLER_CYCLES =
        (T_RRD_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;
    localparam integer T_XAW_CONTROLLER_CYCLES =
        (T_XAW_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;
    localparam integer READ_TO_WRITE_DATA_CYCLES_RAW =
        BURST_OCCUPANCY_CYCLES + T_RTW_CONTROLLER_CYCLES +
        T_CWL_CONTROLLER_CYCLES - T_CL_CONTROLLER_CYCLES;
    localparam integer WRITE_TO_READ_DATA_CYCLES =
        BURST_OCCUPANCY_CYCLES + T_WTR_CONTROLLER_CYCLES +
        T_CL_CONTROLLER_CYCLES;
    localparam integer READ_TO_WRITE_DATA_CYCLES =
        (READ_TO_WRITE_DATA_CYCLES_RAW < BURST_OCCUPANCY_CYCLES) ?
        BURST_OCCUPANCY_CYCLES : READ_TO_WRITE_DATA_CYCLES_RAW;
    localparam integer READ_TO_OTHER_RANK_DATA_CYCLES =
        BURST_OCCUPANCY_CYCLES + T_CS_CONTROLLER_CYCLES;
    localparam integer READ_TO_OTHER_RANK_WRITE_DATA_CYCLES_RAW =
        READ_TO_OTHER_RANK_DATA_CYCLES +
        T_CWL_CONTROLLER_CYCLES - T_CL_CONTROLLER_CYCLES;
    localparam integer READ_TO_OTHER_RANK_WRITE_DATA_CYCLES =
        (READ_TO_OTHER_RANK_WRITE_DATA_CYCLES_RAW <
         BURST_OCCUPANCY_CYCLES) ?
        BURST_OCCUPANCY_CYCLES :
        READ_TO_OTHER_RANK_WRITE_DATA_CYCLES_RAW;
    localparam integer WRITE_TO_OTHER_RANK_READ_DATA_CYCLES_RAW =
        READ_TO_OTHER_RANK_DATA_CYCLES +
        T_CL_CONTROLLER_CYCLES - T_CWL_CONTROLLER_CYCLES;
    localparam integer WRITE_TO_OTHER_RANK_READ_DATA_CYCLES =
        (WRITE_TO_OTHER_RANK_READ_DATA_CYCLES_RAW <
         BURST_OCCUPANCY_CYCLES) ?
        BURST_OCCUPANCY_CYCLES :
        WRITE_TO_OTHER_RANK_READ_DATA_CYCLES_RAW;
    localparam integer REFRESH_INTERVAL_CONTROLLER_CYCLES =
        (REFRESH_INTERVAL == 0) ? 0 :
        ((REFRESH_INTERVAL * DRAM_TCK_PS + CONTROLLER_TCK_PS - 1) /
         CONTROLLER_TCK_PS);
    localparam integer FRONTEND_LATENCY_CYCLES =
        (FRONTEND_LATENCY_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;
    localparam integer BACKEND_LATENCY_CYCLES =
        (BACKEND_LATENCY_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;

    reg command_valid_q [0:COMMAND_QUEUE_DEPTH-1];
    reg command_assigned_q [0:COMMAND_QUEUE_DEPTH-1];
    reg command_complete_q [0:COMMAND_QUEUE_DEPTH-1];
    reg command_reported_q [0:COMMAND_QUEUE_DEPTH-1];
    reg command_write_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [TAG_WIDTH-1:0] command_tag_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [ADDR_WIDTH-1:0] command_addr_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [15:0] command_bytes_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [BANK_BITS-1:0] command_bank_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [RANK_INDEX_WIDTH-1:0] command_rank_q
        [0:COMMAND_QUEUE_DEPTH-1];
    reg [BANK_MACHINE_INDEX_WIDTH-1:0] command_bank_machine_q
        [0:COMMAND_QUEUE_DEPTH-1];
    reg [ROW_TAG_WIDTH-1:0] command_row_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [15:0] command_bursts_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [63:0] command_frontend_ready_cycle_q
        [0:COMMAND_QUEUE_DEPTH-1];
    reg [63:0] command_backend_ready_cycle_q
        [0:COMMAND_QUEUE_DEPTH-1];
    reg [QUEUE_PTR_WIDTH-1:0] command_head_q;
    reg [QUEUE_PTR_WIDTH-1:0] command_tail_q;
    reg [QUEUE_COUNT_WIDTH-1:0] command_count_q;
    reg response_hold_valid_q;
    reg [QUEUE_PTR_WIDTH-1:0] response_hold_slot_q;

    reg bank_busy_q [0:BANK_MACHINE_COUNT-1];
    reg [QUEUE_PTR_WIDTH-1:0] bank_slot_q [0:BANK_MACHINE_COUNT-1];
    reg [15:0] bank_bursts_left_q [0:BANK_MACHINE_COUNT-1];
    reg [63:0] bank_burst_ready_cycle_q [0:BANK_MACHINE_COUNT-1];
    reg [QUEUE_COUNT_WIDTH-1:0]
        bank_group_count_q [0:BANK_MACHINE_COUNT-1];
    reg [QUEUE_COUNT_WIDTH-1:0]
        bank_group_index_q [0:BANK_MACHINE_COUNT-1];
    reg [15:0] bank_group_native_bursts_q [0:BANK_MACHINE_COUNT-1];
    reg [QUEUE_PTR_WIDTH-1:0]
        bank_group_slot_q
        [0:BANK_MACHINE_COUNT-1][0:COMMAND_QUEUE_DEPTH-1];
    reg bank_group_write_q [0:BANK_MACHINE_COUNT-1];
    reg [ROW_TAG_WIDTH-1:0] bank_group_row_q [0:BANK_MACHINE_COUNT-1];
    reg [ADDR_WIDTH-1:0] bank_group_next_addr_q
        [0:BANK_MACHINE_COUNT-1];
    reg open_valid_q [0:BANK_MACHINE_COUNT-1];
    reg [ROW_TAG_WIDTH-1:0] open_row_q [0:BANK_MACHINE_COUNT-1];
    reg [63:0] precharge_ready_cycle_q [0:BANK_MACHINE_COUNT-1];
    reg [63:0] activate_allowed_cycle_q [0:BANK_MACHINE_COUNT-1];
    reg [15:0] row_accesses_q [0:BANK_MACHINE_COUNT-1];
    reg [15:0] bank_group_start_row_accesses_q
        [0:BANK_MACHINE_COUNT-1];
    reg bank_auto_precharge_q [0:BANK_MACHINE_COUNT-1];

    reg [63:0] rank_read_data_allowed_cycle_q [0:RANKS-1];
    reg [63:0] rank_write_data_allowed_cycle_q [0:RANKS-1];
    reg [63:0] rank_activate_allowed_cycle_q [0:RANKS-1];
    reg [63:0] rank_activate_ticks_q [0:RANKS-1][0:3];
    reg bus_direction_valid_q;
    reg bus_direction_write_q;
    reg [15:0] bus_direction_bursts_q;

    reg bus_busy_q;
    reg [31:0] bus_cycles_left_q;
    reg [BANK_MACHINE_INDEX_WIDTH-1:0] bus_bank_q;
    reg [63:0] bus_burst_start_cycle_q;

    reg refresh_busy_q;
    reg [31:0] refresh_cycles_left_q;
    reg [31:0] refresh_age_q;
    reg [63:0] controller_cycle_q;

`ifndef SYNTHESIS
    reg [63:0] perf_commands_coalesced_q;
    reg [63:0] perf_read_commands_coalesced_q;
    reg [63:0] perf_write_commands_coalesced_q;
    reg [63:0] perf_coalesced_groups_q;
    reg [63:0] perf_active_cycles_q;
    reg [63:0] perf_command_queue_entry_cycles_q;
    reg [63:0] perf_command_queue_full_cycles_q;
    reg [63:0] perf_command_input_wait_cycles_q;
    reg [63:0] perf_command_refresh_wait_cycles_q;
    reg [63:0] perf_bus_busy_cycles_q;
    reg [63:0] perf_bus_read_cycles_q;
    reg [63:0] perf_bus_write_cycles_q;
    reg [63:0] perf_bus_launches_q;
    reg [63:0] perf_bus_read_launches_q;
    reg [63:0] perf_bus_write_launches_q;
    reg [63:0] perf_bus_bank_wait_cycles_q;
    reg [63:0] perf_bus_queue_wait_cycles_q;
    reg [63:0] perf_bank_busy_entry_cycles_q;
    reg [63:0] perf_max_busy_banks_q;
    reg [63:0] perf_row_hit_commands_q;
    reg [63:0] perf_row_miss_commands_q;
    reg [63:0] perf_row_conflict_commands_q;
    reg [63:0] perf_row_empty_commands_q;
    reg [63:0] perf_native_bursts_q;
    reg [63:0] perf_full_native_commands_q;
    reg [63:0] perf_partial_native_commands_q;
    reg [63:0] perf_multi_native_commands_q;
    reg [63:0] perf_burst_trains_q;
    reg [63:0] perf_single_burst_trains_q;
    reg [63:0] perf_two_burst_trains_q;
    reg [63:0] perf_three_burst_trains_q;
    reg [63:0] perf_four_burst_trains_q;
    reg [63:0] perf_five_burst_trains_q;
    reg [63:0] perf_six_burst_trains_q;
    reg [63:0] perf_seven_burst_trains_q;
    reg [63:0] perf_eight_burst_trains_q;
    reg [63:0] perf_long_burst_trains_q;
    reg [63:0] perf_direction_switches_q;
    reg [63:0] perf_refresh_cycles_q;
    reg [63:0] perf_refresh_events_q;
    reg [63:0] perf_refresh_deferred_cycles_q;
    reg perf_last_launch_valid_q;
    reg perf_last_launch_write_q;
`endif

    wire [BANK_BITS-1:0] incoming_bank_raw =
        cmd_addr_i[ROW_OFFSET_BITS +: BANK_BITS];
    wire [ROW_TAG_WIDTH-1:0] incoming_row =
        cmd_addr_i[
            ADDR_WIDTH-1:
            ROW_OFFSET_BITS+BANK_BITS+RANK_ADDRESS_BITS];
    // Hash low row bits into the timing bank index without changing the
    // address used by storage.
    wire [BANK_BITS-1:0] incoming_bank =
        (BANK_ROW_SWIZZLE != 0)
            ? (incoming_bank_raw ^ incoming_row[BANK_BITS-1:0])
            : incoming_bank_raw;
    wire [RANK_INDEX_WIDTH-1:0] incoming_rank;
    generate
        if (RANKS > 1) begin : g_incoming_rank
            assign incoming_rank =
                cmd_addr_i[ROW_OFFSET_BITS+BANK_BITS
                           +: RANK_INDEX_WIDTH];
        end else begin : g_single_rank
            assign incoming_rank = {RANK_INDEX_WIDTH{1'b0}};
        end
    endgenerate
    wire [BANK_MACHINE_INDEX_WIDTH-1:0] incoming_bank_machine =
        BANK_MACHINE_INDEX_WIDTH'(
            (32'(incoming_rank) * BANK_COUNT) + 32'(incoming_bank));
    wire command_fire = cmd_valid_i && cmd_ready_o;
    wire response_fire = resp_valid_o && resp_ready_i;
    wire refresh_due = (REFRESH_INTERVAL_CONTROLLER_CYCLES != 0) &&
        (refresh_age_q >= REFRESH_INTERVAL_CONTROLLER_CYCLES);

    integer incoming_byte_count;
    integer incoming_first_offset;
    integer incoming_native_bursts;
    always @* begin
        incoming_byte_count = (cmd_bytes_i == 0) ? 1 : 32'(cmd_bytes_i);
        incoming_first_offset =
            32'(cmd_addr_i[NATIVE_BURST_OFFSET_BITS-1:0]);
        incoming_native_bursts =
            (incoming_first_offset + incoming_byte_count +
             NATIVE_BURST_BYTES - 1) / NATIVE_BURST_BYTES;
    end

    function automatic [QUEUE_PTR_WIDTH-1:0] next_queue_ptr;
        input [QUEUE_PTR_WIDTH-1:0] ptr;
        begin
            if (ptr == COMMAND_QUEUE_DEPTH - 1)
                next_queue_ptr = {QUEUE_PTR_WIDTH{1'b0}};
            else
                next_queue_ptr = ptr + 1'b1;
        end
    endfunction

    function automatic integer dram_to_controller_cycles;
        input integer dram_cycles;
        begin
            dram_to_controller_cycles =
                (dram_cycles * DRAM_TCK_PS + CONTROLLER_TCK_PS - 1) /
                CONTROLLER_TCK_PS;
        end
    endfunction

    function automatic ranges_overlap;
        input [ADDR_WIDTH-1:0] left_addr;
        input [15:0] left_bytes;
        input [ADDR_WIDTH-1:0] right_addr;
        input [15:0] right_bytes;
        reg [ADDR_WIDTH:0] left_end;
        reg [ADDR_WIDTH:0] right_end;
        begin
            left_end = {1'b0, left_addr} + left_bytes;
            right_end = {1'b0, right_addr} + right_bytes;
            ranges_overlap =
                ({1'b0, left_addr} < right_end) &&
                ({1'b0, right_addr} < left_end);
        end
    endfunction

    // A queued command may bypass older commands only when doing so cannot
    // change memory semantics.  Read/read pairs never conflict.  Any overlap
    // involving a write preserves acceptance order (RAW, WAR, and WAW).
    reg [COMMAND_QUEUE_DEPTH-1:0] command_dependency_eligible;
    reg [COMMAND_QUEUE_DEPTH-1:0] command_eligible;
    integer eligible_offset;
    integer eligible_slot;
    integer older_offset;
    integer older_slot;
    always @* begin
        command_dependency_eligible = {COMMAND_QUEUE_DEPTH{1'b0}};
        command_eligible = {COMMAND_QUEUE_DEPTH{1'b0}};
        older_slot = 0;
        for (eligible_offset = 0;
             eligible_offset < COMMAND_QUEUE_DEPTH;
             eligible_offset = eligible_offset + 1) begin
            eligible_slot = command_head_q + eligible_offset;
            if (eligible_slot >= COMMAND_QUEUE_DEPTH)
                eligible_slot = eligible_slot - COMMAND_QUEUE_DEPTH;
            if (command_valid_q[eligible_slot] &&
                !command_assigned_q[eligible_slot] &&
                !command_complete_q[eligible_slot] &&
                !command_reported_q[eligible_slot]) begin
                command_dependency_eligible[eligible_slot] = 1'b1;
                for (older_offset = 0;
                     older_offset < eligible_offset;
                     older_offset = older_offset + 1) begin
                    older_slot = command_head_q + older_offset;
                    if (older_slot >= COMMAND_QUEUE_DEPTH)
                        older_slot = older_slot - COMMAND_QUEUE_DEPTH;
                    if (command_valid_q[older_slot] &&
                        !command_reported_q[older_slot] &&
                        (command_write_q[eligible_slot] ||
                         command_write_q[older_slot]) &&
                        ranges_overlap(
                            command_addr_q[eligible_slot],
                            command_bytes_q[eligible_slot],
                            command_addr_q[older_slot],
                            command_bytes_q[older_slot]))
                        command_dependency_eligible[eligible_slot] = 1'b0;
                end
                if (command_dependency_eligible[eligible_slot] &&
                    (command_frontend_ready_cycle_q[eligible_slot] <=
                     controller_cycle_q))
                    command_eligible[eligible_slot] = 1'b1;
            end
        end
    end

    reg [BANK_MACHINE_COUNT-1:0] dispatch_valid;
    reg [BANK_MACHINE_COUNT-1:0] dispatch_activation;
    integer dispatch_slot [0:BANK_MACHINE_COUNT-1];
    integer dispatch_latency [0:BANK_MACHINE_COUNT-1];
    reg [63:0] dispatch_precharge_ready [0:BANK_MACHINE_COUNT-1];
    reg [63:0] dispatch_activation_cycle [0:BANK_MACHINE_COUNT-1];
    integer dispatch_bank;
    integer dispatch_rank;
    integer dispatch_offset;
    integer dispatch_scan_slot;
    integer dispatch_row_hit_total;
    integer dispatch_row_miss_total;
    integer dispatch_row_conflict_total;
    integer dispatch_row_empty_total;
    reg dispatch_found;
    reg dispatch_row_hit;
    reg [RANKS-1:0] dispatch_rank_activation_used;
    reg [63:0] dispatch_column_cycle;
    reg [63:0] dispatch_act_cycle;
    reg [63:0] dispatch_candidate_cycle;
    always @* begin
        dispatch_valid = {BANK_MACHINE_COUNT{1'b0}};
        dispatch_activation = {BANK_MACHINE_COUNT{1'b0}};
        dispatch_rank_activation_used = {RANKS{1'b0}};
        dispatch_row_hit_total = 0;
        dispatch_row_miss_total = 0;
        dispatch_row_conflict_total = 0;
        dispatch_row_empty_total = 0;
        dispatch_row_hit = 1'b0;
        dispatch_column_cycle = 64'd0;
        dispatch_act_cycle = 64'd0;
        dispatch_candidate_cycle = 64'd0;
        for (dispatch_bank = 0; dispatch_bank < BANK_MACHINE_COUNT;
             dispatch_bank = dispatch_bank + 1) begin
            dispatch_rank = dispatch_bank / BANK_COUNT;
            dispatch_slot[dispatch_bank] = 0;
            dispatch_latency[dispatch_bank] = 1;
            dispatch_precharge_ready[dispatch_bank] =
                precharge_ready_cycle_q[dispatch_bank];
            dispatch_activation_cycle[dispatch_bank] = 64'd0;
            dispatch_found = 1'b0;
            for (dispatch_offset = 0;
                 dispatch_offset < COMMAND_QUEUE_DEPTH;
                 dispatch_offset = dispatch_offset + 1) begin
                dispatch_scan_slot = command_head_q + dispatch_offset;
                if (dispatch_scan_slot >= COMMAND_QUEUE_DEPTH)
                    dispatch_scan_slot =
                        dispatch_scan_slot - COMMAND_QUEUE_DEPTH;
                if (!dispatch_found &&
                    command_eligible[dispatch_scan_slot] &&
                    (command_bank_machine_q[dispatch_scan_slot] ==
                     BANK_MACHINE_INDEX_WIDTH'(dispatch_bank))) begin
                    dispatch_found = 1'b1;
                    dispatch_valid[dispatch_bank] = 1'b1;
                    dispatch_slot[dispatch_bank] = dispatch_scan_slot;
                end
            end

            if (dispatch_valid[dispatch_bank] &&
                !bank_busy_q[dispatch_bank] &&
                !refresh_due && !refresh_busy_q) begin
                dispatch_row_hit = open_valid_q[dispatch_bank] &&
                    (open_row_q[dispatch_bank] ==
                     command_row_q[dispatch_slot[dispatch_bank]]);
                if (!dispatch_row_hit) begin
                    // Only one ACT is scheduled per rank in a controller
                    // cycle.  Future ACT times are reserved immediately, so
                    // later scheduling observes tRRD/tXAW.
                    if (dispatch_rank_activation_used[dispatch_rank])
                        dispatch_valid[dispatch_bank] = 1'b0;
                    else begin
                        dispatch_rank_activation_used[dispatch_rank] = 1'b1;
                        dispatch_activation[dispatch_bank] = 1'b1;
                    end
                end

                if (dispatch_valid[dispatch_bank]) begin
                    if (dispatch_row_hit) begin
                        dispatch_row_hit_total =
                            dispatch_row_hit_total + 1;
                        dispatch_column_cycle = controller_cycle_q;
                    end else begin
                        dispatch_row_miss_total =
                            dispatch_row_miss_total + 1;
                        if (open_valid_q[dispatch_bank]) begin
                            dispatch_row_conflict_total =
                                dispatch_row_conflict_total + 1;
                            dispatch_candidate_cycle =
                                precharge_ready_cycle_q[dispatch_bank];
                            if (dispatch_candidate_cycle <
                                controller_cycle_q)
                                dispatch_candidate_cycle =
                                    controller_cycle_q;
                            dispatch_act_cycle =
                                dispatch_candidate_cycle +
                                64'(T_RP_CONTROLLER_CYCLES);
                        end else begin
                            dispatch_row_empty_total =
                                dispatch_row_empty_total + 1;
                            dispatch_act_cycle =
                                activate_allowed_cycle_q[dispatch_bank];
                            if (dispatch_act_cycle < controller_cycle_q)
                                dispatch_act_cycle = controller_cycle_q;
                        end
                        if (dispatch_act_cycle <
                            rank_activate_allowed_cycle_q[dispatch_rank])
                            dispatch_act_cycle =
                                rank_activate_allowed_cycle_q[dispatch_rank];
                        if ((ACTIVATION_LIMIT == 4) &&
                            (rank_activate_ticks_q[dispatch_rank][3] != 0) &&
                            (dispatch_act_cycle <
                             (rank_activate_ticks_q[dispatch_rank][3] +
                              64'(T_XAW_CONTROLLER_CYCLES))))
                            dispatch_act_cycle =
                                rank_activate_ticks_q[dispatch_rank][3] +
                                64'(T_XAW_CONTROLLER_CYCLES);
                        dispatch_activation_cycle[dispatch_bank] =
                            dispatch_act_cycle;
                        dispatch_column_cycle = dispatch_act_cycle +
                            64'(dram_to_controller_cycles(
                                command_write_q[
                                    dispatch_slot[dispatch_bank]] ?
                                T_RCD_WR : T_RCD_RD));
                        dispatch_precharge_ready[dispatch_bank] =
                            dispatch_act_cycle +
                            64'(T_RAS_CONTROLLER_CYCLES);
                    end

                    dispatch_candidate_cycle =
                        dispatch_column_cycle +
                        64'(command_write_q[
                            dispatch_slot[dispatch_bank]] ?
                            T_CWL_CONTROLLER_CYCLES :
                            T_CL_CONTROLLER_CYCLES);
                    dispatch_latency[dispatch_bank] = 32'(
                        dispatch_candidate_cycle - controller_cycle_q);
                    if (dispatch_latency[dispatch_bank] < 1)
                        dispatch_latency[dispatch_bank] = 1;
                end
            end
        end
    end

    // While a bank is preparing or transferring one command, absorb queued
    // commands that continue the same native-burst run.  Each queue entry
    // remains independently complete/retired; only row/column scheduling is
    // coalesced.  Unrelated commands may intervene in acceptance order; the
    // dependency mask above prevents grouping across an overlapping write.
    reg [BANK_MACHINE_COUNT-1:0] append_valid;
    integer append_slot [0:BANK_MACHINE_COUNT-1];
    integer append_bank;
    integer append_offset;
    integer append_scan_slot;
    integer append_total;
    integer append_read_total;
    integer append_write_total;
    integer append_group_total;
    reg append_found;
    always @* begin
        append_valid = {BANK_MACHINE_COUNT{1'b0}};
        append_scan_slot = 0;
        append_total = 0;
        append_read_total = 0;
        append_write_total = 0;
        append_group_total = 0;
        for (append_bank = 0; append_bank < BANK_MACHINE_COUNT;
             append_bank = append_bank + 1) begin
            append_slot[append_bank] = 0;
            append_found = 1'b0;
            if (bank_busy_q[append_bank] &&
                (bank_group_count_q[append_bank] <
                 COMMAND_QUEUE_DEPTH)) begin
                for (append_offset = 0;
                     append_offset < COMMAND_QUEUE_DEPTH;
                     append_offset = append_offset + 1) begin
                    append_scan_slot = command_head_q + append_offset;
                    if (append_scan_slot >= COMMAND_QUEUE_DEPTH)
                        append_scan_slot =
                            append_scan_slot - COMMAND_QUEUE_DEPTH;
                    if (!append_found &&
                        command_eligible[append_scan_slot] &&
                        (command_bank_machine_q[append_scan_slot] ==
                         BANK_MACHINE_INDEX_WIDTH'(append_bank)) &&
                        (command_row_q[append_scan_slot] ==
                         bank_group_row_q[append_bank]) &&
                        (command_write_q[append_scan_slot] ==
                         bank_group_write_q[append_bank]) &&
                        (command_addr_q[append_scan_slot] ==
                         bank_group_next_addr_q[append_bank]) &&
                        ((32'(bank_group_native_bursts_q[append_bank]) +
                          32'(command_bursts_q[append_scan_slot])) <=
                         MAX_BURST_TRAIN_BURSTS) &&
                        ((MAX_ACCESSES_PER_ROW == 0) ||
                         ((32'(
                             bank_group_start_row_accesses_q[append_bank]) +
                           32'(bank_group_native_bursts_q[append_bank]) +
                           32'(command_bursts_q[append_scan_slot])) <=
                          MAX_ACCESSES_PER_ROW))) begin
                        append_found = 1'b1;
                        append_valid[append_bank] = 1'b1;
                        append_slot[append_bank] = append_scan_slot;
                        append_total = append_total + 1;
                        if (bank_group_write_q[append_bank])
                            append_write_total =
                                append_write_total + 1;
                        else
                            append_read_total =
                                append_read_total + 1;
                        if (bank_group_count_q[append_bank] == 1)
                            append_group_total =
                                append_group_total + 1;
                    end
                end
            end
        end
    end

    // gem5's open_adaptive policy closes an open row when a different row in
    // the same rank/bank is queued and no further hit to the current row is
    // visible.  Decide this when the native burst is selected, then retain
    // the decision until its data phase completes.
    reg [BANK_MACHINE_COUNT-1:0] open_adaptive_close;
    integer adaptive_bank;
    integer adaptive_slot;
    reg adaptive_more_hits;
    reg adaptive_bank_conflict;
    always @* begin
        open_adaptive_close = {BANK_MACHINE_COUNT{1'b0}};
        adaptive_more_hits = 1'b0;
        adaptive_bank_conflict = 1'b0;
        for (adaptive_bank = 0;
             adaptive_bank < BANK_MACHINE_COUNT;
             adaptive_bank = adaptive_bank + 1) begin
            adaptive_more_hits =
                (bank_bursts_left_q[adaptive_bank] > 1) ||
                ((bank_group_index_q[adaptive_bank] + 1'b1) <
                 bank_group_count_q[adaptive_bank]) ||
                append_valid[adaptive_bank];
            adaptive_bank_conflict = 1'b0;
            for (adaptive_slot = 0;
                 adaptive_slot < COMMAND_QUEUE_DEPTH;
                 adaptive_slot = adaptive_slot + 1) begin
                if (command_valid_q[adaptive_slot] &&
                    !command_assigned_q[adaptive_slot] &&
                    !command_complete_q[adaptive_slot] &&
                    !command_reported_q[adaptive_slot] &&
                    (command_bank_machine_q[adaptive_slot] ==
                     BANK_MACHINE_INDEX_WIDTH'(adaptive_bank))) begin
                    if (command_row_q[adaptive_slot] ==
                        bank_group_row_q[adaptive_bank])
                        adaptive_more_hits = 1'b1;
                    else
                        adaptive_bank_conflict = 1'b1;
                end
            end
            if (bank_busy_q[adaptive_bank] &&
                !adaptive_more_hits && adaptive_bank_conflict)
                open_adaptive_close[adaptive_bank] = 1'b1;
        end
    end

    reg bus_select_valid;
    integer bus_select_bank;
    integer bus_offset;
    integer bus_scan_slot;
    integer bus_scan_bank;
    integer bus_scan_rank;
    integer bus_minimum_before_switch;
    reg bus_select_found;
    reg bus_ready_read_found;
    reg bus_ready_write_found;
    reg bus_target_write;
    reg bus_candidate_ready;
    always @* begin
        bus_select_valid = 1'b0;
        bus_select_bank = 0;
        bus_select_found = 1'b0;
        bus_ready_read_found = 1'b0;
        bus_ready_write_found = 1'b0;
        bus_target_write = 1'b0;
        bus_candidate_ready = 1'b0;
        bus_minimum_before_switch = 0;

        for (bus_scan_bank = 0;
             bus_scan_bank < BANK_MACHINE_COUNT;
             bus_scan_bank = bus_scan_bank + 1) begin
            bus_scan_rank = bus_scan_bank / BANK_COUNT;
            bus_candidate_ready =
                bank_busy_q[bus_scan_bank] &&
                (bank_burst_ready_cycle_q[bus_scan_bank] <=
                 controller_cycle_q) &&
                (bank_group_write_q[bus_scan_bank] ?
                 (rank_write_data_allowed_cycle_q[bus_scan_rank] <=
                  controller_cycle_q) :
                 (rank_read_data_allowed_cycle_q[bus_scan_rank] <=
                  controller_cycle_q));
            if (bus_candidate_ready && bank_group_write_q[bus_scan_bank])
                bus_ready_write_found = 1'b1;
            if (bus_candidate_ready && !bank_group_write_q[bus_scan_bank])
                bus_ready_read_found = 1'b1;
        end

        if (!bus_direction_valid_q)
            bus_target_write =
                !bus_ready_read_found && bus_ready_write_found;
        else begin
            bus_minimum_before_switch = bus_direction_write_q ?
                MIN_WRITES_PER_SWITCH : MIN_READS_PER_SWITCH;
            if (bus_direction_write_q) begin
                if (bus_ready_write_found &&
                    ((bus_direction_bursts_q <
                      bus_minimum_before_switch) ||
                     !bus_ready_read_found))
                    bus_target_write = 1'b1;
                else
                    bus_target_write = 1'b0;
            end else begin
                if (bus_ready_read_found &&
                    ((bus_direction_bursts_q <
                      bus_minimum_before_switch) ||
                     !bus_ready_write_found))
                    bus_target_write = 1'b0;
                else
                    bus_target_write = 1'b1;
            end
        end

        for (bus_offset = 0; bus_offset < COMMAND_QUEUE_DEPTH;
             bus_offset = bus_offset + 1) begin
            bus_scan_slot = command_head_q + bus_offset;
            if (bus_scan_slot >= COMMAND_QUEUE_DEPTH)
                bus_scan_slot = bus_scan_slot - COMMAND_QUEUE_DEPTH;
            for (bus_scan_bank = 0;
                 bus_scan_bank < BANK_MACHINE_COUNT;
                 bus_scan_bank = bus_scan_bank + 1) begin
                bus_scan_rank = bus_scan_bank / BANK_COUNT;
                if (!bus_select_found &&
                    bank_busy_q[bus_scan_bank] &&
                    (bank_slot_q[bus_scan_bank] ==
                     QUEUE_PTR_WIDTH'(bus_scan_slot)) &&
                    (bank_burst_ready_cycle_q[bus_scan_bank] <=
                     controller_cycle_q) &&
                    (bank_group_write_q[bus_scan_bank] ==
                     bus_target_write) &&
                    (bank_group_write_q[bus_scan_bank] ?
                     (rank_write_data_allowed_cycle_q[bus_scan_rank] <=
                      controller_cycle_q) :
                     (rank_read_data_allowed_cycle_q[bus_scan_rank] <=
                      controller_cycle_q))) begin
                    bus_select_found = 1'b1;
                    bus_select_valid = 1'b1;
                    bus_select_bank = bus_scan_bank;
                end
            end
        end
    end

    reg response_candidate_valid;
    integer response_candidate_slot;
    integer response_offset;
    integer response_scan_slot;
    reg response_candidate_found;
    always @* begin
        response_candidate_valid = 1'b0;
        response_candidate_slot = 0;
        response_candidate_found = 1'b0;
        for (response_offset = 0;
             response_offset < COMMAND_QUEUE_DEPTH;
             response_offset = response_offset + 1) begin
            response_scan_slot = command_head_q + response_offset;
            if (response_scan_slot >= COMMAND_QUEUE_DEPTH)
                response_scan_slot =
                    response_scan_slot - COMMAND_QUEUE_DEPTH;
            if (!response_candidate_found &&
                command_valid_q[response_scan_slot] &&
                command_complete_q[response_scan_slot] &&
                !command_reported_q[response_scan_slot] &&
                (command_backend_ready_cycle_q[response_scan_slot] != 0) &&
                (command_backend_ready_cycle_q[response_scan_slot] <=
                 controller_cycle_q)) begin
                response_candidate_found = 1'b1;
                response_candidate_valid = 1'b1;
                response_candidate_slot = response_scan_slot;
            end
        end
    end

    wire response_selected_valid =
        response_hold_valid_q || response_candidate_valid;
    wire [QUEUE_PTR_WIDTH-1:0] response_selected_slot =
        response_hold_valid_q ?
        response_hold_slot_q :
        QUEUE_PTR_WIDTH'(response_candidate_slot);
    wire command_reclaim = (command_count_q != 0) &&
        command_valid_q[command_head_q] &&
        command_reported_q[command_head_q];
    wire bus_launch =
        !bus_busy_q && !refresh_busy_q && bus_select_valid;
    wire bus_burst_train_end = bus_busy_q &&
        (bus_cycles_left_q <= 1) &&
        (bank_bursts_left_q[bus_bank_q] <= 1) &&
        !((bank_group_index_q[bus_bank_q] + 1'b1) <
          bank_group_count_q[bus_bank_q]) &&
        !append_valid[bus_bank_q];

    reg all_banks_idle;
    reg any_bank_open;
    integer busy_bank_count;
    integer refresh_scan_bank;
    integer refresh_precharge_wait;
    integer refresh_latency;
    always @* begin
        all_banks_idle = 1'b1;
        any_bank_open = 1'b0;
        busy_bank_count = 0;
        refresh_precharge_wait = 0;
        for (refresh_scan_bank = 0;
             refresh_scan_bank < BANK_MACHINE_COUNT;
             refresh_scan_bank = refresh_scan_bank + 1) begin
            if (bank_busy_q[refresh_scan_bank]) begin
                all_banks_idle = 1'b0;
                busy_bank_count = busy_bank_count + 1;
            end
            if (open_valid_q[refresh_scan_bank])
                any_bank_open = 1'b1;
            if ((precharge_ready_cycle_q[refresh_scan_bank] >
                 controller_cycle_q) &&
                ((precharge_ready_cycle_q[refresh_scan_bank] -
                  controller_cycle_q) > 64'(refresh_precharge_wait)))
                refresh_precharge_wait = 32'(
                    precharge_ready_cycle_q[refresh_scan_bank] -
                    controller_cycle_q);
        end
        refresh_latency = refresh_precharge_wait +
            dram_to_controller_cycles(
                T_RFC + (any_bank_open ? T_RP : 0));
        if (refresh_latency < 1)
            refresh_latency = 1;
    end

    assign cmd_ready_o = rst_ni && !refresh_busy_q &&
        (command_count_q < COMMAND_QUEUE_DEPTH);
    assign resp_valid_o = rst_ni && response_selected_valid;
    assign resp_tag_o = command_tag_q[response_selected_slot];

    integer reset_slot;
    integer bank_index;
    integer rank_index;
    integer activation_tick_index;
    integer reset_group_slot;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            command_head_q <= {QUEUE_PTR_WIDTH{1'b0}};
            command_tail_q <= {QUEUE_PTR_WIDTH{1'b0}};
            command_count_q <= {QUEUE_COUNT_WIDTH{1'b0}};
            response_hold_valid_q <= 1'b0;
            response_hold_slot_q <= {QUEUE_PTR_WIDTH{1'b0}};
            bus_busy_q <= 1'b0;
            bus_cycles_left_q <= 32'd0;
            bus_bank_q <= {BANK_MACHINE_INDEX_WIDTH{1'b0}};
            bus_burst_start_cycle_q <= 64'd0;
            bus_direction_valid_q <= 1'b0;
            bus_direction_write_q <= 1'b0;
            bus_direction_bursts_q <= 16'd0;
            refresh_busy_q <= 1'b0;
            refresh_cycles_left_q <= 32'd0;
            refresh_age_q <= 32'd0;
            controller_cycle_q <= 64'd0;
            for (reset_slot = 0; reset_slot < COMMAND_QUEUE_DEPTH;
                 reset_slot = reset_slot + 1) begin
                command_valid_q[reset_slot] <= 1'b0;
                command_assigned_q[reset_slot] <= 1'b0;
                command_complete_q[reset_slot] <= 1'b0;
                command_reported_q[reset_slot] <= 1'b0;
                command_write_q[reset_slot] <= 1'b0;
                command_tag_q[reset_slot] <= {TAG_WIDTH{1'b0}};
                command_addr_q[reset_slot] <= {ADDR_WIDTH{1'b0}};
                command_bytes_q[reset_slot] <= 16'd0;
                command_bank_q[reset_slot] <= {BANK_BITS{1'b0}};
                command_rank_q[reset_slot] <=
                    {RANK_INDEX_WIDTH{1'b0}};
                command_bank_machine_q[reset_slot] <=
                    {BANK_MACHINE_INDEX_WIDTH{1'b0}};
                command_row_q[reset_slot] <= {ROW_TAG_WIDTH{1'b0}};
                command_bursts_q[reset_slot] <= 16'd0;
                command_frontend_ready_cycle_q[reset_slot] <= 64'd0;
                command_backend_ready_cycle_q[reset_slot] <= 64'd0;
            end
            for (bank_index = 0; bank_index < BANK_MACHINE_COUNT;
                 bank_index = bank_index + 1) begin
                bank_busy_q[bank_index] <= 1'b0;
                bank_slot_q[bank_index] <= {QUEUE_PTR_WIDTH{1'b0}};
                bank_bursts_left_q[bank_index] <= 16'd0;
                bank_burst_ready_cycle_q[bank_index] <= 64'd0;
                bank_group_count_q[bank_index] <=
                    {QUEUE_COUNT_WIDTH{1'b0}};
                bank_group_index_q[bank_index] <=
                    {QUEUE_COUNT_WIDTH{1'b0}};
                bank_group_native_bursts_q[bank_index] <= 16'd0;
                bank_group_write_q[bank_index] <= 1'b0;
                bank_group_row_q[bank_index] <=
                    {ROW_TAG_WIDTH{1'b0}};
                bank_group_next_addr_q[bank_index] <=
                    {ADDR_WIDTH{1'b0}};
                open_valid_q[bank_index] <= 1'b0;
                open_row_q[bank_index] <= {ROW_TAG_WIDTH{1'b0}};
                precharge_ready_cycle_q[bank_index] <= 64'd0;
                activate_allowed_cycle_q[bank_index] <= 64'd0;
                row_accesses_q[bank_index] <= 16'd0;
                bank_group_start_row_accesses_q[bank_index] <= 16'd0;
                bank_auto_precharge_q[bank_index] <= 1'b0;
                for (reset_group_slot = 0;
                     reset_group_slot < COMMAND_QUEUE_DEPTH;
                     reset_group_slot = reset_group_slot + 1)
                    bank_group_slot_q[bank_index][reset_group_slot] <=
                        {QUEUE_PTR_WIDTH{1'b0}};
            end
            for (rank_index = 0; rank_index < RANKS;
                 rank_index = rank_index + 1) begin
                rank_read_data_allowed_cycle_q[rank_index] <= 64'd0;
                rank_write_data_allowed_cycle_q[rank_index] <= 64'd0;
                rank_activate_allowed_cycle_q[rank_index] <= 64'd0;
                for (activation_tick_index = 0;
                     activation_tick_index < 4;
                     activation_tick_index = activation_tick_index + 1)
                    rank_activate_ticks_q[
                        rank_index][activation_tick_index] <= 64'd0;
            end
        end else begin
            controller_cycle_q <= controller_cycle_q + 1'b1;
            if ((REFRESH_INTERVAL_CONTROLLER_CYCLES != 0) &&
                !refresh_due && !refresh_busy_q)
                refresh_age_q <= refresh_age_q + 1'b1;

            case ({command_fire, command_reclaim})
                2'b10: command_count_q <= command_count_q + 1'b1;
                2'b01: command_count_q <= command_count_q - 1'b1;
                default: begin end
            endcase

            if (command_fire) begin
                command_valid_q[command_tail_q] <= 1'b1;
                command_assigned_q[command_tail_q] <= 1'b0;
                command_complete_q[command_tail_q] <= 1'b0;
                command_reported_q[command_tail_q] <= 1'b0;
                command_write_q[command_tail_q] <= cmd_write_i;
                command_tag_q[command_tail_q] <= cmd_tag_i;
                command_addr_q[command_tail_q] <= cmd_addr_i;
                command_bytes_q[command_tail_q] <=
                    16'(incoming_byte_count);
                command_bank_q[command_tail_q] <= incoming_bank;
                command_rank_q[command_tail_q] <= incoming_rank;
                command_bank_machine_q[command_tail_q] <=
                    incoming_bank_machine;
                command_row_q[command_tail_q] <= incoming_row;
                command_bursts_q[command_tail_q] <=
                    16'(incoming_native_bursts);
                command_frontend_ready_cycle_q[command_tail_q] <=
                    controller_cycle_q + 64'd1 +
                    64'(FRONTEND_LATENCY_CYCLES);
                command_backend_ready_cycle_q[command_tail_q] <= 64'd0;
                command_tail_q <= next_queue_ptr(command_tail_q);
            end

            if (!response_hold_valid_q && resp_valid_o &&
                !resp_ready_i) begin
                response_hold_valid_q <= 1'b1;
                response_hold_slot_q <= response_selected_slot;
            end

            if (response_fire) begin
                command_reported_q[response_selected_slot] <= 1'b1;
                if (response_hold_valid_q)
                    response_hold_valid_q <= 1'b0;
            end

            if (command_reclaim) begin
                command_valid_q[command_head_q] <= 1'b0;
                command_assigned_q[command_head_q] <= 1'b0;
                command_complete_q[command_head_q] <= 1'b0;
                command_reported_q[command_head_q] <= 1'b0;
                command_frontend_ready_cycle_q[command_head_q] <= 64'd0;
                command_backend_ready_cycle_q[command_head_q] <= 64'd0;
                command_head_q <= next_queue_ptr(command_head_q);
            end

            if (refresh_busy_q) begin
                if (refresh_cycles_left_q <= 1) begin
                    refresh_busy_q <= 1'b0;
                    refresh_cycles_left_q <= 32'd0;
                    refresh_age_q <= 32'd0;
                end else begin
                    refresh_cycles_left_q <= refresh_cycles_left_q - 1'b1;
                end
            end else if (refresh_due && all_banks_idle && !bus_busy_q) begin
                refresh_busy_q <= 1'b1;
                refresh_cycles_left_q <= 32'(refresh_latency);
                for (bank_index = 0;
                     bank_index < BANK_MACHINE_COUNT;
                     bank_index = bank_index + 1)
                    open_valid_q[bank_index] <= 1'b0;
            end

            if (!refresh_due && !refresh_busy_q) begin
                for (bank_index = 0;
                     bank_index < BANK_MACHINE_COUNT;
                     bank_index = bank_index + 1) begin
                    if (!bank_busy_q[bank_index] &&
                        dispatch_valid[bank_index]) begin
                        bank_busy_q[bank_index] <= 1'b1;
                        bank_slot_q[bank_index] <= QUEUE_PTR_WIDTH'(
                            dispatch_slot[bank_index]);
                        bank_bursts_left_q[bank_index] <=
                            command_bursts_q[dispatch_slot[bank_index]];
                        bank_group_count_q[bank_index] <=
                            QUEUE_COUNT_WIDTH'(1);
                        bank_group_index_q[bank_index] <=
                            {QUEUE_COUNT_WIDTH{1'b0}};
                        bank_group_native_bursts_q[bank_index] <=
                            command_bursts_q[dispatch_slot[bank_index]];
                        bank_group_start_row_accesses_q[bank_index] <=
                            dispatch_activation[bank_index] ?
                            16'd0 : row_accesses_q[bank_index];
                        bank_auto_precharge_q[bank_index] <= 1'b0;
                        bank_group_slot_q[bank_index][0] <=
                            QUEUE_PTR_WIDTH'(
                                dispatch_slot[bank_index]);
                        bank_group_write_q[bank_index] <=
                            command_write_q[
                                dispatch_slot[bank_index]];
                        bank_group_row_q[bank_index] <=
                            command_row_q[
                                dispatch_slot[bank_index]];
                        bank_group_next_addr_q[bank_index] <=
                            command_addr_q[
                                dispatch_slot[bank_index]] +
                            command_bytes_q[
                                dispatch_slot[bank_index]];
                        bank_burst_ready_cycle_q[bank_index] <=
                            controller_cycle_q +
                            64'(dispatch_latency[bank_index]);
                        command_assigned_q[dispatch_slot[bank_index]] <=
                            1'b1;
                        if (!open_valid_q[bank_index] ||
                            (open_row_q[bank_index] !=
                             command_row_q[dispatch_slot[bank_index]])) begin
                            open_valid_q[bank_index] <= 1'b1;
                            open_row_q[bank_index] <=
                                command_row_q[dispatch_slot[bank_index]];
                            row_accesses_q[bank_index] <= 16'd0;
                        end
                        precharge_ready_cycle_q[bank_index] <=
                            dispatch_precharge_ready[bank_index];
                        if (dispatch_activation[bank_index]) begin
                            rank_activate_allowed_cycle_q[
                                bank_index / BANK_COUNT] <=
                                dispatch_activation_cycle[bank_index] +
                                64'(T_RRD_CONTROLLER_CYCLES);
                            rank_activate_ticks_q[
                                bank_index / BANK_COUNT][3] <=
                                rank_activate_ticks_q[
                                    bank_index / BANK_COUNT][2];
                            rank_activate_ticks_q[
                                bank_index / BANK_COUNT][2] <=
                                rank_activate_ticks_q[
                                    bank_index / BANK_COUNT][1];
                            rank_activate_ticks_q[
                                bank_index / BANK_COUNT][1] <=
                                rank_activate_ticks_q[
                                    bank_index / BANK_COUNT][0];
                            rank_activate_ticks_q[
                                bank_index / BANK_COUNT][0] <=
                                dispatch_activation_cycle[bank_index];
                        end
                    end
                end
            end

            for (bank_index = 0; bank_index < BANK_MACHINE_COUNT;
                 bank_index = bank_index + 1) begin
                if (append_valid[bank_index]) begin
                    bank_group_slot_q[bank_index][
                        bank_group_count_q[bank_index]] <=
                            QUEUE_PTR_WIDTH'(append_slot[bank_index]);
                    bank_group_count_q[bank_index] <=
                        bank_group_count_q[bank_index] + 1'b1;
                    bank_group_native_bursts_q[bank_index] <=
                        bank_group_native_bursts_q[bank_index] +
                        command_bursts_q[append_slot[bank_index]];
                    bank_group_next_addr_q[bank_index] <=
                        bank_group_next_addr_q[bank_index] +
                        command_bytes_q[append_slot[bank_index]];
                    command_assigned_q[append_slot[bank_index]] <=
                        1'b1;
                end
            end

            if (!bus_busy_q && !refresh_busy_q && bus_select_valid) begin
                bus_busy_q <= 1'b1;
                bus_cycles_left_q <= 32'(BURST_OCCUPANCY_CYCLES);
                bus_bank_q <= BANK_MACHINE_INDEX_WIDTH'(bus_select_bank);
                bus_burst_start_cycle_q <= controller_cycle_q;
                row_accesses_q[bus_select_bank] <=
                    row_accesses_q[bus_select_bank] + 1'b1;
                bank_auto_precharge_q[bus_select_bank] <=
                    open_adaptive_close[bus_select_bank];
                if (!bus_direction_valid_q ||
                    (bus_direction_write_q !=
                     bank_group_write_q[bus_select_bank])) begin
                    bus_direction_valid_q <= 1'b1;
                    bus_direction_write_q <=
                        bank_group_write_q[bus_select_bank];
                    bus_direction_bursts_q <= 16'd1;
                end else begin
                    bus_direction_bursts_q <=
                        bus_direction_bursts_q + 1'b1;
                end

                // gem5 expresses these constraints at column-command time.
                // This model arbitrates the data phase, so translate them to
                // equivalent data-start limits (CL/CWL included).
                for (rank_index = 0; rank_index < RANKS;
                     rank_index = rank_index + 1) begin
                    if (rank_index == (bus_select_bank / BANK_COUNT)) begin
                        if (bank_group_write_q[bus_select_bank]) begin
                            if ((controller_cycle_q +
                                 64'(BURST_OCCUPANCY_CYCLES)) >
                                rank_write_data_allowed_cycle_q[rank_index])
                                rank_write_data_allowed_cycle_q[rank_index] <=
                                    controller_cycle_q +
                                    64'(BURST_OCCUPANCY_CYCLES);
                            if ((controller_cycle_q +
                                 64'(WRITE_TO_READ_DATA_CYCLES)) >
                                rank_read_data_allowed_cycle_q[rank_index])
                                rank_read_data_allowed_cycle_q[rank_index] <=
                                    controller_cycle_q +
                                    64'(WRITE_TO_READ_DATA_CYCLES);
                        end else begin
                            if ((controller_cycle_q +
                                 64'(BURST_OCCUPANCY_CYCLES)) >
                                rank_read_data_allowed_cycle_q[rank_index])
                                rank_read_data_allowed_cycle_q[rank_index] <=
                                    controller_cycle_q +
                                    64'(BURST_OCCUPANCY_CYCLES);
                            if ((controller_cycle_q +
                                 64'(READ_TO_WRITE_DATA_CYCLES)) >
                                rank_write_data_allowed_cycle_q[rank_index])
                                rank_write_data_allowed_cycle_q[rank_index] <=
                                    controller_cycle_q +
                                    64'(READ_TO_WRITE_DATA_CYCLES);
                        end
                    end else if (bank_group_write_q[bus_select_bank]) begin
                        if ((controller_cycle_q +
                             64'(READ_TO_OTHER_RANK_DATA_CYCLES)) >
                            rank_write_data_allowed_cycle_q[rank_index])
                            rank_write_data_allowed_cycle_q[rank_index] <=
                                controller_cycle_q +
                                64'(READ_TO_OTHER_RANK_DATA_CYCLES);
                        if ((controller_cycle_q +
                             64'(WRITE_TO_OTHER_RANK_READ_DATA_CYCLES)) >
                            rank_read_data_allowed_cycle_q[rank_index])
                            rank_read_data_allowed_cycle_q[rank_index] <=
                                controller_cycle_q +
                                64'(WRITE_TO_OTHER_RANK_READ_DATA_CYCLES);
                    end else begin
                        if ((controller_cycle_q +
                             64'(READ_TO_OTHER_RANK_DATA_CYCLES)) >
                            rank_read_data_allowed_cycle_q[rank_index])
                            rank_read_data_allowed_cycle_q[rank_index] <=
                                controller_cycle_q +
                                64'(READ_TO_OTHER_RANK_DATA_CYCLES);
                        if ((controller_cycle_q +
                             64'(READ_TO_OTHER_RANK_WRITE_DATA_CYCLES)) >
                            rank_write_data_allowed_cycle_q[rank_index])
                            rank_write_data_allowed_cycle_q[rank_index] <=
                                controller_cycle_q +
                                64'(READ_TO_OTHER_RANK_WRITE_DATA_CYCLES);
                    end
                end
                if (!bank_group_write_q[bus_select_bank] &&
                    ((controller_cycle_q -
                      64'(T_CL_CONTROLLER_CYCLES) +
                      64'(T_RTP_CONTROLLER_CYCLES)) >
                     precharge_ready_cycle_q[bus_select_bank]))
                    precharge_ready_cycle_q[bus_select_bank] <=
                        controller_cycle_q -
                        64'(T_CL_CONTROLLER_CYCLES) +
                        64'(T_RTP_CONTROLLER_CYCLES);
            end else if (bus_busy_q) begin
                if (bus_cycles_left_q <= 1) begin
                    bus_busy_q <= 1'b0;
                    bus_cycles_left_q <= 32'd0;
                    if (bank_bursts_left_q[bus_bank_q] <= 1) begin
                        command_complete_q[
                            bank_slot_q[bus_bank_q]] <= 1'b1;
                        // The backend/PHY is one pipeline behind the physical
                        // burst train.  Each independently tagged portion
                        // emerges after the same pipeline offset, preserving
                        // the train's tCCD spacing rather than waiting for the
                        // final portion.
                        command_backend_ready_cycle_q[
                            bank_slot_q[bus_bank_q]] <=
                            controller_cycle_q + 64'd1 +
                            64'(BACKEND_LATENCY_CYCLES);
                        if (command_write_q[
                            bank_slot_q[bus_bank_q]] &&
                            ((controller_cycle_q +
                              64'(T_WR_CONTROLLER_CYCLES)) >
                             precharge_ready_cycle_q[bus_bank_q]))
                            precharge_ready_cycle_q[bus_bank_q] <=
                                controller_cycle_q +
                                64'(T_WR_CONTROLLER_CYCLES);
                        if ((bank_group_index_q[bus_bank_q] + 1'b1) <
                            bank_group_count_q[bus_bank_q]) begin
                            bank_group_index_q[bus_bank_q] <=
                                bank_group_index_q[bus_bank_q] + 1'b1;
                            bank_slot_q[bus_bank_q] <=
                                bank_group_slot_q[bus_bank_q][
                                    bank_group_index_q[bus_bank_q] +
                                    1'b1];
                            bank_bursts_left_q[bus_bank_q] <=
                                command_bursts_q[
                                    bank_group_slot_q[bus_bank_q][
                                        bank_group_index_q[bus_bank_q] +
                                        1'b1]];
                            bank_burst_ready_cycle_q[bus_bank_q] <=
                                bus_burst_start_cycle_q +
                                64'(T_CCD_CONTROLLER_CYCLES);
                        end else if (append_valid[bus_bank_q]) begin
                            // The append and final-burst events share this
                            // edge.  Continue directly with the newly
                            // appended command rather than dropping the bank
                            // idle for a cycle.
                            bank_group_index_q[bus_bank_q] <=
                                bank_group_index_q[bus_bank_q] + 1'b1;
                            bank_slot_q[bus_bank_q] <=
                                QUEUE_PTR_WIDTH'(
                                    append_slot[bus_bank_q]);
                            bank_bursts_left_q[bus_bank_q] <=
                                command_bursts_q[
                                    append_slot[bus_bank_q]];
                            bank_burst_ready_cycle_q[bus_bank_q] <=
                                bus_burst_start_cycle_q +
                                64'(T_CCD_CONTROLLER_CYCLES);
                        end else begin
                            bank_busy_q[bus_bank_q] <= 1'b0;
                            bank_bursts_left_q[bus_bank_q] <= 16'd0;
                            bank_group_count_q[bus_bank_q] <=
                                {QUEUE_COUNT_WIDTH{1'b0}};
                            bank_group_index_q[bus_bank_q] <=
                                {QUEUE_COUNT_WIDTH{1'b0}};
                            bank_group_native_bursts_q[bus_bank_q] <=
                                16'd0;
                            if (((MAX_ACCESSES_PER_ROW != 0) &&
                                 (row_accesses_q[bus_bank_q] >=
                                  MAX_ACCESSES_PER_ROW)) ||
                                bank_auto_precharge_q[bus_bank_q]) begin
                                open_valid_q[bus_bank_q] <= 1'b0;
                                row_accesses_q[bus_bank_q] <= 16'd0;
                                bank_auto_precharge_q[bus_bank_q] <= 1'b0;
                                if (command_write_q[
                                    bank_slot_q[bus_bank_q]]) begin
                                    activate_allowed_cycle_q[
                                        bus_bank_q] <=
                                        controller_cycle_q +
                                        64'(T_WR_CONTROLLER_CYCLES) +
                                        64'(T_RP_CONTROLLER_CYCLES);
                                end else begin
                                    // Read auto-precharge may legally begin
                                    // at max(ACT+tRAS, RD+tRTP), before the
                                    // read data/backend response completes.
                                    activate_allowed_cycle_q[
                                        bus_bank_q] <=
                                        precharge_ready_cycle_q[bus_bank_q] +
                                        64'(T_RP_CONTROLLER_CYCLES);
                                end
                            end
                        end
                    end else begin
                        bank_bursts_left_q[bus_bank_q] <=
                            bank_bursts_left_q[bus_bank_q] - 1'b1;
                        if ((bus_burst_start_cycle_q +
                             64'(T_CCD_CONTROLLER_CYCLES)) >
                            controller_cycle_q)
                            bank_burst_ready_cycle_q[bus_bank_q] <=
                                bus_burst_start_cycle_q +
                                64'(T_CCD_CONTROLLER_CYCLES);
                        else
                            bank_burst_ready_cycle_q[bus_bank_q] <=
                                controller_cycle_q;
                    end
                end else begin
                    bus_cycles_left_q <= bus_cycles_left_q - 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            perf_commands_coalesced_q <= 64'd0;
            perf_read_commands_coalesced_q <= 64'd0;
            perf_write_commands_coalesced_q <= 64'd0;
            perf_coalesced_groups_q <= 64'd0;
            perf_active_cycles_q <= 64'd0;
            perf_command_queue_entry_cycles_q <= 64'd0;
            perf_command_queue_full_cycles_q <= 64'd0;
            perf_command_input_wait_cycles_q <= 64'd0;
            perf_command_refresh_wait_cycles_q <= 64'd0;
            perf_bus_busy_cycles_q <= 64'd0;
            perf_bus_read_cycles_q <= 64'd0;
            perf_bus_write_cycles_q <= 64'd0;
            perf_bus_launches_q <= 64'd0;
            perf_bus_read_launches_q <= 64'd0;
            perf_bus_write_launches_q <= 64'd0;
            perf_bus_bank_wait_cycles_q <= 64'd0;
            perf_bus_queue_wait_cycles_q <= 64'd0;
            perf_bank_busy_entry_cycles_q <= 64'd0;
            perf_max_busy_banks_q <= 64'd0;
            perf_row_hit_commands_q <= 64'd0;
            perf_row_miss_commands_q <= 64'd0;
            perf_row_conflict_commands_q <= 64'd0;
            perf_row_empty_commands_q <= 64'd0;
            perf_native_bursts_q <= 64'd0;
            perf_full_native_commands_q <= 64'd0;
            perf_partial_native_commands_q <= 64'd0;
            perf_multi_native_commands_q <= 64'd0;
            perf_burst_trains_q <= 64'd0;
            perf_single_burst_trains_q <= 64'd0;
            perf_two_burst_trains_q <= 64'd0;
            perf_three_burst_trains_q <= 64'd0;
            perf_four_burst_trains_q <= 64'd0;
            perf_five_burst_trains_q <= 64'd0;
            perf_six_burst_trains_q <= 64'd0;
            perf_seven_burst_trains_q <= 64'd0;
            perf_eight_burst_trains_q <= 64'd0;
            perf_long_burst_trains_q <= 64'd0;
            perf_direction_switches_q <= 64'd0;
            perf_refresh_cycles_q <= 64'd0;
            perf_refresh_events_q <= 64'd0;
            perf_refresh_deferred_cycles_q <= 64'd0;
            perf_last_launch_valid_q <= 1'b0;
            perf_last_launch_write_q <= 1'b0;
        end else begin
            perf_commands_coalesced_q <=
                perf_commands_coalesced_q + 64'(append_total);
            perf_read_commands_coalesced_q <=
                perf_read_commands_coalesced_q +
                64'(append_read_total);
            perf_write_commands_coalesced_q <=
                perf_write_commands_coalesced_q +
                64'(append_write_total);
            perf_coalesced_groups_q <=
                perf_coalesced_groups_q + 64'(append_group_total);
            if ((command_count_q != 0) || !all_banks_idle || bus_busy_q)
                perf_active_cycles_q <= perf_active_cycles_q + 64'd1;
            perf_command_queue_entry_cycles_q <=
                perf_command_queue_entry_cycles_q + command_count_q;
            if (command_count_q == COMMAND_QUEUE_DEPTH)
                perf_command_queue_full_cycles_q <=
                    perf_command_queue_full_cycles_q + 64'd1;
            if (cmd_valid_i && !cmd_ready_o) begin
                perf_command_input_wait_cycles_q <=
                    perf_command_input_wait_cycles_q + 64'd1;
                if (refresh_busy_q)
                    perf_command_refresh_wait_cycles_q <=
                        perf_command_refresh_wait_cycles_q + 64'd1;
            end
            if (bus_busy_q) begin
                perf_bus_busy_cycles_q <=
                    perf_bus_busy_cycles_q + 64'd1;
                if (command_write_q[bank_slot_q[bus_bank_q]])
                    perf_bus_write_cycles_q <=
                        perf_bus_write_cycles_q + 64'd1;
                else
                    perf_bus_read_cycles_q <=
                        perf_bus_read_cycles_q + 64'd1;
            end else if (!refresh_busy_q && !bus_select_valid) begin
                if (!all_banks_idle)
                    perf_bus_bank_wait_cycles_q <=
                        perf_bus_bank_wait_cycles_q + 64'd1;
                else if (command_count_q != 0)
                    perf_bus_queue_wait_cycles_q <=
                        perf_bus_queue_wait_cycles_q + 64'd1;
            end
            if (bus_launch) begin
                perf_bus_launches_q <= perf_bus_launches_q + 64'd1;
                if (command_write_q[
                        bank_slot_q[
                            BANK_MACHINE_INDEX_WIDTH'(bus_select_bank)]])
                    perf_bus_write_launches_q <=
                        perf_bus_write_launches_q + 64'd1;
                else
                    perf_bus_read_launches_q <=
                        perf_bus_read_launches_q + 64'd1;
                if (perf_last_launch_valid_q &&
                    (perf_last_launch_write_q !=
                     command_write_q[
                         bank_slot_q[
                             BANK_MACHINE_INDEX_WIDTH'(bus_select_bank)]]))
                    perf_direction_switches_q <=
                        perf_direction_switches_q + 64'd1;
                perf_last_launch_valid_q <= 1'b1;
                perf_last_launch_write_q <=
                    command_write_q[
                        bank_slot_q[
                            BANK_MACHINE_INDEX_WIDTH'(bus_select_bank)]];
            end
            perf_bank_busy_entry_cycles_q <=
                perf_bank_busy_entry_cycles_q + 64'(busy_bank_count);
            if (busy_bank_count > perf_max_busy_banks_q)
                perf_max_busy_banks_q <= 64'(busy_bank_count);
            perf_row_hit_commands_q <=
                perf_row_hit_commands_q +
                64'(dispatch_row_hit_total + append_total);
            perf_row_miss_commands_q <=
                perf_row_miss_commands_q +
                64'(dispatch_row_miss_total);
            perf_row_conflict_commands_q <=
                perf_row_conflict_commands_q +
                64'(dispatch_row_conflict_total);
            perf_row_empty_commands_q <=
                perf_row_empty_commands_q +
                64'(dispatch_row_empty_total);
            if (command_fire) begin
                perf_native_bursts_q <= perf_native_bursts_q +
                    64'(incoming_native_bursts);
                if ((incoming_first_offset == 0) &&
                    (incoming_byte_count == NATIVE_BURST_BYTES))
                    perf_full_native_commands_q <=
                        perf_full_native_commands_q + 64'd1;
                else
                    perf_partial_native_commands_q <=
                        perf_partial_native_commands_q + 64'd1;
                if (incoming_native_bursts > 1)
                    perf_multi_native_commands_q <=
                        perf_multi_native_commands_q + 64'd1;
            end
            if (bus_burst_train_end) begin
                perf_burst_trains_q <= perf_burst_trains_q + 64'd1;
                if (bank_group_native_bursts_q[bus_bank_q] == 1)
                    perf_single_burst_trains_q <=
                        perf_single_burst_trains_q + 64'd1;
                else if (bank_group_native_bursts_q[bus_bank_q] == 2)
                    perf_two_burst_trains_q <=
                        perf_two_burst_trains_q + 64'd1;
                else if (bank_group_native_bursts_q[bus_bank_q] == 3)
                    perf_three_burst_trains_q <=
                        perf_three_burst_trains_q + 64'd1;
                else if (bank_group_native_bursts_q[bus_bank_q] == 4)
                    perf_four_burst_trains_q <=
                        perf_four_burst_trains_q + 64'd1;
                else if (bank_group_native_bursts_q[bus_bank_q] == 5)
                    perf_five_burst_trains_q <=
                        perf_five_burst_trains_q + 64'd1;
                else if (bank_group_native_bursts_q[bus_bank_q] == 6)
                    perf_six_burst_trains_q <=
                        perf_six_burst_trains_q + 64'd1;
                else if (bank_group_native_bursts_q[bus_bank_q] == 7)
                    perf_seven_burst_trains_q <=
                        perf_seven_burst_trains_q + 64'd1;
                else if (bank_group_native_bursts_q[bus_bank_q] == 8)
                    perf_eight_burst_trains_q <=
                        perf_eight_burst_trains_q + 64'd1;
                else
                    perf_long_burst_trains_q <=
                        perf_long_burst_trains_q + 64'd1;
            end
            if (refresh_busy_q)
                perf_refresh_cycles_q <= perf_refresh_cycles_q + 64'd1;
            if (!refresh_busy_q && refresh_due &&
                all_banks_idle && !bus_busy_q)
                perf_refresh_events_q <= perf_refresh_events_q + 64'd1;
            if (refresh_due && !refresh_busy_q &&
                (!all_banks_idle || bus_busy_q))
                perf_refresh_deferred_cycles_q <=
                    perf_refresh_deferred_cycles_q + 64'd1;
        end
    end
`endif

    initial begin
        if ((ADDR_WIDTH < 16) || (ADDR_WIDTH > 64))
            $fatal(1, "banked DRAM timing address width must be 16 through 64");
        if (TAG_WIDTH < 1)
            $fatal(1, "banked DRAM timing tag width must be positive");
        if ((DQ_WIDTH < 8) || ((DQ_WIDTH % 8) != 0))
            $fatal(1, "banked DRAM timing DQ width must contain complete bytes");
        if ((BURST_LENGTH < 1) ||
            ((NATIVE_BURST_BITS % 8) != 0) ||
            ((NATIVE_BURST_BYTES & (NATIVE_BURST_BYTES - 1)) != 0))
            $fatal(1, "banked DRAM native burst must be power-of-two bytes");
        if ((BURST_OCCUPANCY_CYCLES < 1) ||
            (T_CCD_CONTROLLER_CYCLES < 1))
            $fatal(1, "banked DRAM burst scheduling intervals must be positive");
        if ((BANK_BITS < 1) || (BANK_BITS > 6))
            $fatal(1, "banked DRAM bank bits must be 1 through 6");
        if ((BANK_ROW_SWIZZLE != 0) && (BANK_ROW_SWIZZLE != 1))
            $fatal(1, "bank-row swizzle must be disabled (0) or enabled (1)");
        if ((BANK_ROW_SWIZZLE != 0) && (ROW_TAG_WIDTH < BANK_BITS))
            $fatal(1, "bank-row swizzle requires at least BANK_BITS row bits");
        if ((ROW_BYTES < NATIVE_BURST_BYTES) ||
            ((ROW_BYTES & (ROW_BYTES - 1)) != 0))
            $fatal(1, "banked DRAM row size must contain complete bursts");
        if (ROW_TAG_WIDTH < 1)
            $fatal(1, "banked DRAM geometry consumes the complete address");
        if ((COMMAND_QUEUE_DEPTH < 2) ||
            ((COMMAND_QUEUE_DEPTH & (COMMAND_QUEUE_DEPTH - 1)) != 0))
            $fatal(1, "banked DRAM command queue must be power-of-two >= 2");
        if ((MAX_BURST_TRAIN_BURSTS < 1) ||
            (MAX_BURST_TRAIN_BURSTS > COMMAND_QUEUE_DEPTH))
            $fatal(1,
                "banked DRAM burst train limit must be 1 through command queue depth");
        if ((CONTROLLER_TCK_PS < 1) || (DRAM_TCK_PS < 1))
            $fatal(1, "banked DRAM clock periods must be positive");
        if ((FRONTEND_LATENCY_PS < 0) || (BACKEND_LATENCY_PS < 0))
            $fatal(1, "banked DRAM controller latencies cannot be negative");
    end

endmodule
