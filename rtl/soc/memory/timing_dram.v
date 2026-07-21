`timescale 1ns/1ps

// Common transaction-level DRAM timing engine.
//
// The controller-facing clock is independent of the selected DRAM speed bin.
// Technology wrappers describe physical DQ width, native burst length, DRAM
// tCK, geometry, and timings in DRAM clock cycles.  This engine converts the
// resulting command latency into controller-clock cycles.
//
// A command may cover more than one native DRAM burst.  The first burst pays
// row-hit/activate/precharge latency; each additional native burst pays tCCD.
// The model tracks one open row per bank and lazy all-bank refresh.  It remains
// deliberately single-command-at-a-time: isolated access latency is useful,
// but this fixture does not claim bank-parallel throughput accuracy.
module openrv64_timing_dram #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer DQ_WIDTH = 64,
    parameter integer BURST_LENGTH = 8,
    parameter integer BURST_CYCLES = 4,
    parameter integer BANK_BITS = 4,
    parameter integer ROW_BYTES = 8192,
    parameter integer CONTROLLER_TCK_PS = 1000,
    parameter integer DRAM_TCK_PS = 625,
    parameter integer T_RCD_RD = 22,
    parameter integer T_RCD_WR = 22,
    parameter integer T_RP = 22,
    parameter integer T_RAS = 52,
    parameter integer T_WR = 24,
    parameter integer T_CL = 22,
    parameter integer T_CWL = 16,
    parameter integer T_CCD = 8,
    parameter integer T_RFC = 560,
    parameter integer REFRESH_INTERVAL = 12480,
    parameter integer LATENCY_WIDTH = 16
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
    localparam integer REFRESH_INTERVAL_CONTROLLER_CYCLES =
        (REFRESH_INTERVAL == 0) ? 0 :
        ((REFRESH_INTERVAL * DRAM_TCK_PS + CONTROLLER_TCK_PS - 1) /
         CONTROLLER_TCK_PS);
    localparam integer T_RAS_CONTROLLER_CYCLES =
        (T_RAS * DRAM_TCK_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;
    localparam integer T_WR_CONTROLLER_CYCLES =
        (T_WR * DRAM_TCK_PS + CONTROLLER_TCK_PS - 1) /
        CONTROLLER_TCK_PS;

    reg busy_q;
    reg response_valid_q;
    reg [LATENCY_WIDTH-1:0] cycles_left_q;
    reg [31:0] refresh_age_q;
    reg [63:0] controller_cycle_q;
    reg open_valid_q [0:BANK_COUNT-1];
    reg [ROW_TAG_WIDTH-1:0] open_row_q [0:BANK_COUNT-1];
    reg [63:0] precharge_ready_cycle_q [0:BANK_COUNT-1];

    wire [BANK_BITS-1:0] command_bank =
        cmd_addr_i[ROW_OFFSET_BITS +: BANK_BITS];
    wire [ROW_TAG_WIDTH-1:0] command_row =
        cmd_addr_i[ADDR_WIDTH-1:ROW_OFFSET_BITS+BANK_BITS];
    wire refresh_due = (REFRESH_INTERVAL_CONTROLLER_CYCLES != 0) &&
        (refresh_age_q >= REFRESH_INTERVAL_CONTROLLER_CYCLES);
    wire row_hit = !refresh_due && open_valid_q[command_bank] &&
                   (open_row_q[command_bank] == command_row);
    wire command_fire = cmd_valid_i && cmd_ready_o;
    wire response_fire = resp_valid_o && resp_ready_i;

    integer command_byte_count;
    integer command_first_offset;
    integer command_native_bursts;
    integer command_dram_cycles;
    integer command_latency;
    integer command_precharge_wait;
    integer command_activation_delay;
    integer bank_index;
    integer scan_index;
    reg any_bank_open;
    reg [63:0] command_latency_ps;
    reg [63:0] command_new_precharge_ready;

    always @* begin
        command_byte_count = (cmd_bytes_i == 0) ? 1 : 32'(cmd_bytes_i);
        command_first_offset =
            32'(cmd_addr_i[NATIVE_BURST_OFFSET_BITS-1:0]);
        command_native_bursts =
            (command_first_offset + command_byte_count +
             NATIVE_BURST_BYTES - 1) / NATIVE_BURST_BYTES;

        command_precharge_wait = 0;
        any_bank_open = 0;
        if (refresh_due) begin
            for (scan_index = 0; scan_index < BANK_COUNT;
                 scan_index = scan_index + 1) begin
                if (open_valid_q[scan_index]) begin
                    any_bank_open = 1;
                    if ((precharge_ready_cycle_q[scan_index] >
                         controller_cycle_q) &&
                        ((precharge_ready_cycle_q[scan_index] -
                          controller_cycle_q) >
                         64'(command_precharge_wait)))
                        command_precharge_wait = 32'(
                            precharge_ready_cycle_q[scan_index] -
                            controller_cycle_q);
                end
            end
        end else if (open_valid_q[command_bank] && !row_hit &&
                     (precharge_ready_cycle_q[command_bank] >
                      controller_cycle_q)) begin
            command_precharge_wait = 32'(
                precharge_ready_cycle_q[command_bank] -
                controller_cycle_q);
        end

        command_dram_cycles = cmd_write_i ?
            (T_CWL + BURST_CYCLES) : (T_CL + BURST_CYCLES);
        if (command_native_bursts > 1)
            command_dram_cycles = command_dram_cycles +
                ((command_native_bursts - 1) * T_CCD);

        if (refresh_due) begin
            command_dram_cycles = command_dram_cycles +
                (any_bank_open ? T_RP : 0) + T_RFC +
                (cmd_write_i ? T_RCD_WR : T_RCD_RD);
        end else if (!row_hit) begin
            if (open_valid_q[command_bank])
                command_dram_cycles = command_dram_cycles + T_RP;
            command_dram_cycles = command_dram_cycles +
                (cmd_write_i ? T_RCD_WR : T_RCD_RD);
        end

        command_latency_ps = command_dram_cycles * DRAM_TCK_PS;
        command_latency_ps =
            (command_latency_ps + 64'(CONTROLLER_TCK_PS) - 1) /
            64'(CONTROLLER_TCK_PS);
        command_latency = 32'(command_latency_ps) +
                          command_precharge_wait;
        if (command_latency < 1)
            command_latency = 1;

        command_activation_delay = command_precharge_wait;
        if (refresh_due)
            command_activation_delay = command_activation_delay +
                (((T_RFC + (any_bank_open ? T_RP : 0)) * DRAM_TCK_PS +
                  CONTROLLER_TCK_PS - 1) / CONTROLLER_TCK_PS);
        else if (open_valid_q[command_bank] && !row_hit)
            command_activation_delay = command_activation_delay +
                ((T_RP * DRAM_TCK_PS + CONTROLLER_TCK_PS - 1) /
                 CONTROLLER_TCK_PS);

        if (refresh_due || !row_hit)
            command_new_precharge_ready = controller_cycle_q +
                64'(command_activation_delay) +
                64'(T_RAS_CONTROLLER_CYCLES);
        else
            command_new_precharge_ready =
                precharge_ready_cycle_q[command_bank];
        if (cmd_write_i &&
            ((controller_cycle_q + 64'(command_latency) +
              64'(T_WR_CONTROLLER_CYCLES)) >
             command_new_precharge_ready))
            command_new_precharge_ready = controller_cycle_q +
                64'(command_latency) + 64'(T_WR_CONTROLLER_CYCLES);
    end

    assign cmd_ready_o = rst_ni && !busy_q && !response_valid_q;
    assign resp_valid_o = response_valid_q;

    initial begin
        if ((ADDR_WIDTH < 16) || (ADDR_WIDTH > 64))
            $fatal(1, "DRAM timing address width must be 16 through 64");
        if ((DQ_WIDTH < 8) || ((DQ_WIDTH % 8) != 0))
            $fatal(1, "DRAM timing DQ width must contain complete bytes");
        if ((BURST_LENGTH < 1) ||
            ((NATIVE_BURST_BITS % 8) != 0) ||
            ((NATIVE_BURST_BYTES & (NATIVE_BURST_BYTES - 1)) != 0))
            $fatal(1, "DRAM timing native burst must be a power-of-two byte count");
        if (BURST_CYCLES < 1)
            $fatal(1, "DRAM timing burst occupancy must be positive");
        if ((BANK_BITS < 1) || (BANK_BITS > 6))
            $fatal(1, "DRAM timing bank bits must be 1 through 6");
        if ((ROW_BYTES < NATIVE_BURST_BYTES) ||
            ((ROW_BYTES & (ROW_BYTES - 1)) != 0))
            $fatal(1, "DRAM timing row size must be a power of two at least one native burst");
        if (ROW_TAG_WIDTH < 1)
            $fatal(1, "DRAM timing geometry consumes the complete address");
        if ((CONTROLLER_TCK_PS < 1) || (DRAM_TCK_PS < 1))
            $fatal(1, "DRAM and controller clock periods must be positive");
        if ((LATENCY_WIDTH < 1) || (LATENCY_WIDTH > 31))
            $fatal(1, "DRAM timing latency width must be 1 through 31");
        if ((T_RCD_RD < 0) || (T_RCD_WR < 0) || (T_RP < 0) ||
            (T_RAS < 0) || (T_WR < 0) ||
            (T_CL < 0) || (T_CWL < 0) || (T_CCD < 0) ||
            (T_RFC < 0) || (REFRESH_INTERVAL < 0))
            $fatal(1, "DRAM timing cycle counts cannot be negative");
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            busy_q <= 1'b0;
            response_valid_q <= 1'b0;
            cycles_left_q <= {LATENCY_WIDTH{1'b0}};
            refresh_age_q <= 32'd0;
            controller_cycle_q <= 64'd0;
            for (bank_index = 0; bank_index < BANK_COUNT;
                 bank_index = bank_index + 1) begin
                open_valid_q[bank_index] <= 1'b0;
                open_row_q[bank_index] <= {ROW_TAG_WIDTH{1'b0}};
                precharge_ready_cycle_q[bank_index] <= 64'd0;
            end
        end else begin
            controller_cycle_q <= controller_cycle_q + 1'b1;
            if ((REFRESH_INTERVAL_CONTROLLER_CYCLES != 0) &&
                (refresh_age_q < REFRESH_INTERVAL_CONTROLLER_CYCLES))
                refresh_age_q <= refresh_age_q + 1'b1;

            if (response_fire)
                response_valid_q <= 1'b0;

            if (command_fire) begin
                busy_q <= 1'b1;
                cycles_left_q <= command_latency[LATENCY_WIDTH-1:0];

                if (refresh_due) begin
                    refresh_age_q <= 32'd0;
                    for (bank_index = 0; bank_index < BANK_COUNT;
                         bank_index = bank_index + 1)
                        open_valid_q[bank_index] <= 1'b0;
                end
                open_valid_q[command_bank] <= 1'b1;
                open_row_q[command_bank] <= command_row;
                precharge_ready_cycle_q[command_bank] <=
                    command_new_precharge_ready;
            end else if (busy_q) begin
                if (cycles_left_q <= 1) begin
                    busy_q <= 1'b0;
                    cycles_left_q <= {LATENCY_WIDTH{1'b0}};
                    response_valid_q <= 1'b1;
                end else begin
                    cycles_left_q <= cycles_left_q - 1'b1;
                end
            end
        end
    end

endmodule
