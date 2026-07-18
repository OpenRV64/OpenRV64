`timescale 1ns/1ps

// Reset conditioner and release sequencer for the single-clock OpenRV64 SoC.
//
// The board reset asserts both generated resets asynchronously.  Deassertion
// is synchronized to clk_i, then the platform/peripheral reset is released
// first.  The core remains reset for CORE_DELAY_CYCLES additional rising
// edges so no CPU request can reach partially reset platform state.
module openrv64_reset_sequencer #(
    parameter integer SOC_HOLD_CYCLES = 4,
    parameter integer CORE_DELAY_CYCLES = 2
) (
    input  wire clk_i,
    input  wire rst_ni,
    output reg  soc_rst_no,
    output reg  core_rst_no
);

    localparam integer SOC_COUNT_WIDTH =
        (SOC_HOLD_CYCLES <= 1) ? 1 : $clog2(SOC_HOLD_CYCLES);
    localparam integer CORE_COUNT_WIDTH =
        (CORE_DELAY_CYCLES <= 1) ? 1 : $clog2(CORE_DELAY_CYCLES);

    // The first stage may see metastability when rst_ni is released.  Only
    // the second stage qualifies the counters and generated reset outputs.
    reg [1:0] release_sync_q;
    reg [SOC_COUNT_WIDTH-1:0] soc_count_q;
    reg [CORE_COUNT_WIDTH-1:0] core_count_q;

    initial begin
        if (SOC_HOLD_CYCLES < 1) begin
            $error("SOC_HOLD_CYCLES must be at least one");
        end
        if (CORE_DELAY_CYCLES < 1) begin
            $error("CORE_DELAY_CYCLES must be at least one");
        end
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            release_sync_q <= 2'b00;
        end else begin
            release_sync_q <= {release_sync_q[0], 1'b1};
        end
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            soc_rst_no <= 1'b0;
            core_rst_no <= 1'b0;
            soc_count_q <= {SOC_COUNT_WIDTH{1'b0}};
            core_count_q <= {CORE_COUNT_WIDTH{1'b0}};
        end else if (!release_sync_q[1]) begin
            soc_rst_no <= 1'b0;
            core_rst_no <= 1'b0;
            soc_count_q <= {SOC_COUNT_WIDTH{1'b0}};
            core_count_q <= {CORE_COUNT_WIDTH{1'b0}};
        end else if (!soc_rst_no) begin
            core_rst_no <= 1'b0;
            core_count_q <= {CORE_COUNT_WIDTH{1'b0}};

            if (soc_count_q == (SOC_HOLD_CYCLES - 1)) begin
                soc_rst_no <= 1'b1;
                soc_count_q <= {SOC_COUNT_WIDTH{1'b0}};
            end else begin
                soc_count_q <= soc_count_q + 1'b1;
            end
        end else if (!core_rst_no) begin
            if (core_count_q == (CORE_DELAY_CYCLES - 1)) begin
                core_rst_no <= 1'b1;
                core_count_q <= {CORE_COUNT_WIDTH{1'b0}};
            end else begin
                core_count_q <= core_count_q + 1'b1;
            end
        end
    end

endmodule
