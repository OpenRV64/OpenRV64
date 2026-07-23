`timescale 1ns/1ps

// Bank-parallel transaction-level DRAM timing engine.
//
// Commands enter an in-order response queue.  An idle bank may begin row
// preparation independently of every other bank.  Once a bank reaches its
// column/data phase, native DRAM bursts arbitrate onto one shared data bus.
// Multi-burst commands therefore consume explicit bus slots rather than
// folding tCCD into one aggregate command delay.  Banks may prepare work while
// another bank transfers data, but responses remain in command-acceptance
// order because this data-free timing contract carries no response tag.
//
// This is still a transaction-level controller fixture: it does not model
// command/address bus occupancy, rank switching, write draining, or a
// FR-FCFS policy.  It does model the two effects needed by the benchmark seam:
// independent bank progress and serialized native-burst data transfer.
module openrv64_timing_dram_banked #(
    parameter integer ADDR_WIDTH = 64,
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
    input  wire [7:0]            cmd_bytes_i,

    output wire                  resp_valid_o,
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
    reg command_write_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [BANK_BITS-1:0] command_bank_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [ROW_TAG_WIDTH-1:0] command_row_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [8:0] command_bursts_q [0:COMMAND_QUEUE_DEPTH-1];
    reg [QUEUE_PTR_WIDTH-1:0] command_head_q;
    reg [QUEUE_PTR_WIDTH-1:0] command_tail_q;
    reg [QUEUE_COUNT_WIDTH-1:0] command_count_q;

    reg bank_busy_q [0:BANK_COUNT-1];
    reg [QUEUE_PTR_WIDTH-1:0] bank_slot_q [0:BANK_COUNT-1];
    reg [8:0] bank_bursts_left_q [0:BANK_COUNT-1];
    reg [63:0] bank_burst_ready_cycle_q [0:BANK_COUNT-1];
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
                    command_valid_q[dispatch_scan_slot] &&
                    !command_assigned_q[dispatch_scan_slot] &&
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
    assign resp_valid_o = rst_ni && (command_count_q != 0) &&
        command_valid_q[command_head_q] &&
        command_complete_q[command_head_q];

    integer reset_slot;
    integer bank_index;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            command_head_q <= {QUEUE_PTR_WIDTH{1'b0}};
            command_tail_q <= {QUEUE_PTR_WIDTH{1'b0}};
            command_count_q <= {QUEUE_COUNT_WIDTH{1'b0}};
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
                command_write_q[reset_slot] <= 1'b0;
                command_bank_q[reset_slot] <= {BANK_BITS{1'b0}};
                command_row_q[reset_slot] <= {ROW_TAG_WIDTH{1'b0}};
                command_bursts_q[reset_slot] <= 9'd0;
            end
            for (bank_index = 0; bank_index < BANK_COUNT;
                 bank_index = bank_index + 1) begin
                bank_busy_q[bank_index] <= 1'b0;
                bank_slot_q[bank_index] <= {QUEUE_PTR_WIDTH{1'b0}};
                bank_bursts_left_q[bank_index] <= 9'd0;
                bank_burst_ready_cycle_q[bank_index] <= 64'd0;
                open_valid_q[bank_index] <= 1'b0;
                open_row_q[bank_index] <= {ROW_TAG_WIDTH{1'b0}};
                precharge_ready_cycle_q[bank_index] <= 64'd0;
            end
        end else begin
            controller_cycle_q <= controller_cycle_q + 1'b1;
            if ((REFRESH_INTERVAL_CONTROLLER_CYCLES != 0) &&
                !refresh_due && !refresh_busy_q)
                refresh_age_q <= refresh_age_q + 1'b1;

            case ({command_fire, response_fire})
                2'b10: command_count_q <= command_count_q + 1'b1;
                2'b01: command_count_q <= command_count_q - 1'b1;
                default: begin end
            endcase

            if (command_fire) begin
                command_valid_q[command_tail_q] <= 1'b1;
                command_assigned_q[command_tail_q] <= 1'b0;
                command_complete_q[command_tail_q] <= 1'b0;
                command_write_q[command_tail_q] <= cmd_write_i;
                command_bank_q[command_tail_q] <= incoming_bank;
                command_row_q[command_tail_q] <= incoming_row;
                command_bursts_q[command_tail_q] <=
                    9'(incoming_native_bursts);
                command_tail_q <= next_queue_ptr(command_tail_q);
            end

            if (response_fire) begin
                command_valid_q[command_head_q] <= 1'b0;
                command_assigned_q[command_head_q] <= 1'b0;
                command_complete_q[command_head_q] <= 1'b0;
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
                        bank_busy_q[bus_bank_q] <= 1'b0;
                        bank_bursts_left_q[bus_bank_q] <= 9'd0;
                        if (command_write_q[
                            bank_slot_q[bus_bank_q]] &&
                            ((controller_cycle_q +
                              64'(T_WR_CONTROLLER_CYCLES)) >
                             precharge_ready_cycle_q[bus_bank_q]))
                            precharge_ready_cycle_q[bus_bank_q] <=
                                controller_cycle_q +
                                64'(T_WR_CONTROLLER_CYCLES);
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

    initial begin
        if ((ADDR_WIDTH < 16) || (ADDR_WIDTH > 64))
            $fatal(1, "banked DRAM timing address width must be 16 through 64");
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
