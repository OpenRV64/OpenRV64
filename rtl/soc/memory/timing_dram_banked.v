`timescale 1ns/1ps

// Bank-parallel transaction-level DRAM timing engine.
//
// Commands enter a tagged scheduling queue.  An idle bank may begin row
// preparation independently of every other bank.  Once a bank reaches its
// column/data phase, native DRAM bursts arbitrate onto one shared data bus.
// Multi-burst commands therefore consume explicit bus slots rather than
// folding tCCD into one aggregate command delay.  Adjacent same-row,
// same-direction commands may join an active bank run and issue their first
// burst at tCCD spacing, but retain independent tagged completion responses.
// Banks may prepare work while another bank transfers data, and completions
// may return out of command-acceptance order.
//
// This is still a transaction-level controller fixture: it does not model
// command/address bus occupancy or rank switching.  It models dependency-safe
// read/write reordering, open-row grouping, independent bank progress, and
// serialized native-burst data transfer.
module openrv64_timing_dram_banked #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer TAG_WIDTH = 8,
    parameter integer DQ_WIDTH = 64,
    parameter integer BURST_LENGTH = 8,
    parameter integer BURST_CYCLES = 4,
    parameter integer BANK_BITS = 3,
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
    parameter integer T_RFC = 208,
    parameter integer REFRESH_INTERVAL = 6240,
    parameter integer COMMAND_QUEUE_DEPTH = 16
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
    localparam integer ROW_OFFSET_BITS = $clog2(ROW_BYTES);
    localparam integer ROW_TAG_WIDTH =
        ADDR_WIDTH - ROW_OFFSET_BITS - BANK_BITS;
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
    localparam integer REFRESH_INTERVAL_CONTROLLER_CYCLES =
        (REFRESH_INTERVAL == 0) ? 0 :
        ((REFRESH_INTERVAL * DRAM_TCK_PS + CONTROLLER_TCK_PS - 1) /
         CONTROLLER_TCK_PS);

    reg command_valid_q [0:COMMAND_QUEUE_DEPTH-1];
    reg command_assigned_q [0:COMMAND_QUEUE_DEPTH-1];
    reg command_complete_q [0:COMMAND_QUEUE_DEPTH-1];
    reg command_reported_q [0:COMMAND_QUEUE_DEPTH-1];
    reg command_write_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [TAG_WIDTH-1:0] command_tag_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [ADDR_WIDTH-1:0] command_addr_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [15:0] command_bytes_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [BANK_BITS-1:0] command_bank_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [ROW_TAG_WIDTH-1:0] command_row_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [15:0] command_bursts_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [QUEUE_PTR_WIDTH-1:0] command_head_q;
    reg [QUEUE_PTR_WIDTH-1:0] command_tail_q;
    reg [QUEUE_COUNT_WIDTH-1:0] command_count_q;
    reg response_hold_valid_q;
    reg [QUEUE_PTR_WIDTH-1:0] response_hold_slot_q;

    reg bank_busy_q [0:BANK_COUNT-1];
    reg [QUEUE_PTR_WIDTH-1:0] bank_slot_q [0:BANK_COUNT-1];
    reg [15:0] bank_bursts_left_q [0:BANK_COUNT-1];
    reg [63:0] bank_burst_ready_cycle_q [0:BANK_COUNT-1];
    reg [QUEUE_COUNT_WIDTH-1:0] bank_group_count_q [0:BANK_COUNT-1];
    reg [QUEUE_COUNT_WIDTH-1:0] bank_group_index_q [0:BANK_COUNT-1];
    reg [QUEUE_PTR_WIDTH-1:0]
        bank_group_slot_q [0:BANK_COUNT-1][0:COMMAND_QUEUE_DEPTH-1];
    reg bank_group_write_q [0:BANK_COUNT-1];
    reg [ROW_TAG_WIDTH-1:0] bank_group_row_q [0:BANK_COUNT-1];
    reg [ADDR_WIDTH-1:0] bank_group_next_addr_q [0:BANK_COUNT-1];
    reg open_valid_q [0:BANK_COUNT-1];
    reg [ROW_TAG_WIDTH-1:0] open_row_q [0:BANK_COUNT-1];
    reg [63:0] precharge_ready_cycle_q [0:BANK_COUNT-1];

    reg bus_busy_q;
    reg [31:0] bus_cycles_left_q;
    reg [BANK_BITS-1:0] bus_bank_q;
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
`endif

    wire [BANK_BITS-1:0] incoming_bank =
        cmd_addr_i[ROW_OFFSET_BITS +: BANK_BITS];
    wire [ROW_TAG_WIDTH-1:0] incoming_row =
        cmd_addr_i[ADDR_WIDTH-1:ROW_OFFSET_BITS+BANK_BITS];
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
    reg [COMMAND_QUEUE_DEPTH-1:0] command_eligible;
    integer eligible_offset;
    integer eligible_slot;
    integer older_offset;
    integer older_slot;
    always @* begin
        command_eligible = {COMMAND_QUEUE_DEPTH{1'b0}};
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
                command_eligible[eligible_slot] = 1'b1;
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
                        command_eligible[eligible_slot] = 1'b0;
                end
            end
        end
    end

    reg [BANK_COUNT-1:0] dispatch_valid;
    integer dispatch_slot [0:BANK_COUNT-1];
    integer dispatch_latency [0:BANK_COUNT-1];
    reg [63:0] dispatch_precharge_ready [0:BANK_COUNT-1];
    integer dispatch_bank;
    integer dispatch_offset;
    integer dispatch_scan_slot;
    integer dispatch_precharge_wait;
    integer dispatch_dram_cycles;
    integer dispatch_activation_delay;
    reg dispatch_found;
    reg dispatch_row_hit;
    always @* begin
        dispatch_valid = {BANK_COUNT{1'b0}};
        dispatch_precharge_wait = 0;
        dispatch_dram_cycles = 0;
        dispatch_activation_delay = 0;
        dispatch_row_hit = 1'b0;
        for (dispatch_bank = 0; dispatch_bank < BANK_COUNT;
             dispatch_bank = dispatch_bank + 1) begin
            dispatch_slot[dispatch_bank] = 0;
            dispatch_latency[dispatch_bank] = 1;
            dispatch_precharge_ready[dispatch_bank] =
                precharge_ready_cycle_q[dispatch_bank];
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
                    (command_bank_q[dispatch_scan_slot] ==
                     BANK_BITS'(dispatch_bank))) begin
                    dispatch_found = 1'b1;
                    dispatch_valid[dispatch_bank] = 1'b1;
                    dispatch_slot[dispatch_bank] = dispatch_scan_slot;
                end
            end

            if (dispatch_valid[dispatch_bank]) begin
                dispatch_row_hit = open_valid_q[dispatch_bank] &&
                    (open_row_q[dispatch_bank] ==
                     command_row_q[dispatch_slot[dispatch_bank]]);
                dispatch_precharge_wait = 0;
                if (open_valid_q[dispatch_bank] && !dispatch_row_hit &&
                    (precharge_ready_cycle_q[dispatch_bank] >
                     controller_cycle_q))
                    dispatch_precharge_wait = 32'(
                        precharge_ready_cycle_q[dispatch_bank] -
                        controller_cycle_q);

                dispatch_dram_cycles =
                    command_write_q[dispatch_slot[dispatch_bank]] ?
                    T_CWL : T_CL;
                dispatch_activation_delay = dispatch_precharge_wait;
                if (!dispatch_row_hit) begin
                    if (open_valid_q[dispatch_bank]) begin
                        dispatch_dram_cycles =
                            dispatch_dram_cycles + T_RP;
                        dispatch_activation_delay =
                            dispatch_activation_delay +
                            dram_to_controller_cycles(T_RP);
                    end
                    dispatch_dram_cycles = dispatch_dram_cycles +
                        (command_write_q[dispatch_slot[dispatch_bank]] ?
                         T_RCD_WR : T_RCD_RD);
                end
                dispatch_latency[dispatch_bank] =
                    dispatch_precharge_wait +
                    dram_to_controller_cycles(dispatch_dram_cycles);
                if (dispatch_latency[dispatch_bank] < 1)
                    dispatch_latency[dispatch_bank] = 1;

                if (!dispatch_row_hit)
                    dispatch_precharge_ready[dispatch_bank] =
                        controller_cycle_q +
                        64'(dispatch_activation_delay) +
                        64'(T_RAS_CONTROLLER_CYCLES);
            end
        end
    end

    // While a bank is preparing or transferring one command, absorb queued
    // commands that continue the same native-burst run.  Each queue entry
    // remains independently complete/retired; only row/column scheduling is
    // coalesced.  Unrelated commands may intervene in acceptance order; the
    // dependency mask above prevents grouping across an overlapping write.
    reg [BANK_COUNT-1:0] append_valid;
    integer append_slot [0:BANK_COUNT-1];
    integer append_bank;
    integer append_offset;
    integer append_scan_slot;
    integer append_total;
    integer append_read_total;
    integer append_write_total;
    integer append_group_total;
    reg append_found;
    always @* begin
        append_valid = {BANK_COUNT{1'b0}};
        append_total = 0;
        append_read_total = 0;
        append_write_total = 0;
        append_group_total = 0;
        for (append_bank = 0; append_bank < BANK_COUNT;
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
                        (command_bank_q[append_scan_slot] ==
                         BANK_BITS'(append_bank)) &&
                        (command_row_q[append_scan_slot] ==
                         bank_group_row_q[append_bank]) &&
                        (command_write_q[append_scan_slot] ==
                         bank_group_write_q[append_bank]) &&
                        (command_addr_q[append_scan_slot] ==
                         bank_group_next_addr_q[append_bank])) begin
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

    reg bus_select_valid;
    integer bus_select_bank;
    integer bus_offset;
    integer bus_scan_slot;
    integer bus_scan_bank;
    reg bus_select_found;
    always @* begin
        bus_select_valid = 1'b0;
        bus_select_bank = 0;
        bus_select_found = 1'b0;
        for (bus_offset = 0; bus_offset < COMMAND_QUEUE_DEPTH;
             bus_offset = bus_offset + 1) begin
            bus_scan_slot = command_head_q + bus_offset;
            if (bus_scan_slot >= COMMAND_QUEUE_DEPTH)
                bus_scan_slot = bus_scan_slot - COMMAND_QUEUE_DEPTH;
            for (bus_scan_bank = 0; bus_scan_bank < BANK_COUNT;
                 bus_scan_bank = bus_scan_bank + 1) begin
                if (!bus_select_found &&
                    bank_busy_q[bus_scan_bank] &&
                    (bank_slot_q[bus_scan_bank] ==
                     QUEUE_PTR_WIDTH'(bus_scan_slot)) &&
                    (bank_burst_ready_cycle_q[bus_scan_bank] <=
                     controller_cycle_q)) begin
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
                !command_reported_q[response_scan_slot]) begin
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

    reg all_banks_idle;
    reg any_bank_open;
    integer refresh_scan_bank;
    integer refresh_precharge_wait;
    integer refresh_latency;
    always @* begin
        all_banks_idle = 1'b1;
        any_bank_open = 1'b0;
        refresh_precharge_wait = 0;
        for (refresh_scan_bank = 0; refresh_scan_bank < BANK_COUNT;
             refresh_scan_bank = refresh_scan_bank + 1) begin
            if (bank_busy_q[refresh_scan_bank])
                all_banks_idle = 1'b0;
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
            bus_bank_q <= {BANK_BITS{1'b0}};
            bus_burst_start_cycle_q <= 64'd0;
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
                command_row_q[reset_slot] <= {ROW_TAG_WIDTH{1'b0}};
                command_bursts_q[reset_slot] <= 16'd0;
            end
            for (bank_index = 0; bank_index < BANK_COUNT;
                 bank_index = bank_index + 1) begin
                bank_busy_q[bank_index] <= 1'b0;
                bank_slot_q[bank_index] <= {QUEUE_PTR_WIDTH{1'b0}};
                bank_bursts_left_q[bank_index] <= 16'd0;
                bank_burst_ready_cycle_q[bank_index] <= 64'd0;
                bank_group_count_q[bank_index] <=
                    {QUEUE_COUNT_WIDTH{1'b0}};
                bank_group_index_q[bank_index] <=
                    {QUEUE_COUNT_WIDTH{1'b0}};
                bank_group_write_q[bank_index] <= 1'b0;
                bank_group_row_q[bank_index] <=
                    {ROW_TAG_WIDTH{1'b0}};
                bank_group_next_addr_q[bank_index] <=
                    {ADDR_WIDTH{1'b0}};
                open_valid_q[bank_index] <= 1'b0;
                open_row_q[bank_index] <= {ROW_TAG_WIDTH{1'b0}};
                precharge_ready_cycle_q[bank_index] <= 64'd0;
                for (reset_group_slot = 0;
                     reset_group_slot < COMMAND_QUEUE_DEPTH;
                     reset_group_slot = reset_group_slot + 1)
                    bank_group_slot_q[bank_index][reset_group_slot] <=
                        {QUEUE_PTR_WIDTH{1'b0}};
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
                command_row_q[command_tail_q] <= incoming_row;
                command_bursts_q[command_tail_q] <=
                    16'(incoming_native_bursts);
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
                for (bank_index = 0; bank_index < BANK_COUNT;
                     bank_index = bank_index + 1)
                    open_valid_q[bank_index] <= 1'b0;
            end

            if (!refresh_due && !refresh_busy_q) begin
                for (bank_index = 0; bank_index < BANK_COUNT;
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
                        end
                        precharge_ready_cycle_q[bank_index] <=
                            dispatch_precharge_ready[bank_index];
                    end
                end
            end

            for (bank_index = 0; bank_index < BANK_COUNT;
                 bank_index = bank_index + 1) begin
                if (append_valid[bank_index]) begin
                    bank_group_slot_q[bank_index][
                        bank_group_count_q[bank_index]] <=
                            QUEUE_PTR_WIDTH'(append_slot[bank_index]);
                    bank_group_count_q[bank_index] <=
                        bank_group_count_q[bank_index] + 1'b1;
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
                bus_bank_q <= BANK_BITS'(bus_select_bank);
                bus_burst_start_cycle_q <= controller_cycle_q;
            end else if (bus_busy_q) begin
                if (bus_cycles_left_q <= 1) begin
                    bus_busy_q <= 1'b0;
                    bus_cycles_left_q <= 32'd0;
                    if (bank_bursts_left_q[bus_bank_q] <= 1) begin
                        command_complete_q[
                            bank_slot_q[bus_bank_q]] <= 1'b1;
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
        if ((ROW_BYTES < NATIVE_BURST_BYTES) ||
            ((ROW_BYTES & (ROW_BYTES - 1)) != 0))
            $fatal(1, "banked DRAM row size must contain complete bursts");
        if (ROW_TAG_WIDTH < 1)
            $fatal(1, "banked DRAM geometry consumes the complete address");
        if ((COMMAND_QUEUE_DEPTH < 2) ||
            ((COMMAND_QUEUE_DEPTH & (COMMAND_QUEUE_DEPTH - 1)) != 0))
            $fatal(1, "banked DRAM command queue must be power-of-two >= 2");
        if ((CONTROLLER_TCK_PS < 1) || (DRAM_TCK_PS < 1))
            $fatal(1, "banked DRAM clock periods must be positive");
    end

endmodule
