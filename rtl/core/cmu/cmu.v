`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/cmu/defs.v"

// Core control and management unit.
//
// Initially this block owns the standard RISC-V hardware performance monitor:
// mcycle/minstret, mhpmcounter3..31, mhpmevent3..31, mcountinhibit, and the
// counter-access controls.  General CSR privilege and trap state remain in the
// architectural CSR block; the CMU publishes a small CSR sub-interface.
module openrv64_cmu #(
    parameter integer HPM_COUNTERS = 8
) (
    input  wire                             clk,
    input  wire                             rst_n,

    input  wire [`RV64_FUNCT12_WIDTH-1:0]  csr_addr_i,
    input  wire                             csr_write_i,
    input  wire [`RV64_XLEN-1:0]           csr_wdata_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]     priv_mode_i,
    output reg  [`RV64_XLEN-1:0]           csr_rdata_o,
    output reg                              csr_match_o,
    output reg                              csr_valid_o,
    output reg                              csr_writable_o,

    input  wire [1:0]                       retire_count_i,
    input  wire [`OPENRV64_CMU_EVENT_COUNT-1:0] event_pulses_i
);

    localparam integer EVENT_COUNT = `OPENRV64_CMU_EVENT_COUNT;
    localparam integer EVENT_INCREMENT_WIDTH = $clog2(EVENT_COUNT + 1);
    localparam integer HPM_STORAGE_COUNTERS =
        (HPM_COUNTERS > 0) ? HPM_COUNTERS : 1;
    localparam [`RV64_XLEN-1:0] HPM_EVENT_MASK =
        (64'h1 << EVENT_COUNT) - 64'h1;
    localparam [`RV64_XLEN-1:0] HPM_COUNTER_MASK =
        ((64'h1 << HPM_COUNTERS) - 64'h1) << 3;
    localparam [`RV64_XLEN-1:0] COUNTER_ENABLE_MASK =
        (64'h1 << `RV64_MCOUNTER_CY_BIT) |
        (64'h1 << `RV64_MCOUNTER_TM_BIT) |
        (64'h1 << `RV64_MCOUNTER_IR_BIT) |
        HPM_COUNTER_MASK;
    localparam [`RV64_XLEN-1:0] COUNTINHIBIT_MASK =
        (64'h1 << `RV64_MCOUNTER_CY_BIT) |
        (64'h1 << `RV64_MCOUNTER_IR_BIT) |
        HPM_COUNTER_MASK;

    reg [`RV64_XLEN-1:0] mcounteren_q;
    reg [`RV64_XLEN-1:0] scounteren_q;
    reg [`RV64_XLEN-1:0] mcountinhibit_q;
    reg [`RV64_XLEN-1:0] mcycle_q;
    reg [`RV64_XLEN-1:0] minstret_q;
    reg [`RV64_XLEN-1:0]
        mhpmcounter_q [0:HPM_STORAGE_COUNTERS-1];
    reg [`RV64_XLEN-1:0]
        mhpmevent_q [0:HPM_STORAGE_COUNTERS-1];

    wire csr_is_mhpmcounter =
        (csr_addr_i >= `RV64_CSR_MHPMCOUNTER3) &&
        (csr_addr_i <= `RV64_CSR_MHPMCOUNTER31);
    wire csr_is_mhpmevent =
        (csr_addr_i >= `RV64_CSR_MHPMEVENT3) &&
        (csr_addr_i <= `RV64_CSR_MHPMEVENT31);
    wire csr_is_hpmcounter =
        (csr_addr_i >= `RV64_CSR_HPMCOUNTER3) &&
        (csr_addr_i <= `RV64_CSR_HPMCOUNTER31);
    wire [4:0] csr_counter_number = csr_addr_i[4:0];
    wire [4:0] csr_hpm_index = csr_counter_number - 5'd3;
    wire csr_hpm_implemented =
        (csr_counter_number >= 5'd3) &&
        (csr_counter_number < (HPM_COUNTERS + 3));
    wire selected_machine_counter_enabled =
        mcounteren_q[csr_counter_number];
    wire selected_supervisor_counter_enabled =
        scounteren_q[csr_counter_number];
    wire counter_alias_access_ok =
        (priv_mode_i == `RV64_PRIV_M) ||
        ((priv_mode_i == `RV64_PRIV_S) &&
         selected_machine_counter_enabled) ||
        ((priv_mode_i == `RV64_PRIV_U) &&
         selected_machine_counter_enabled &&
         selected_supervisor_counter_enabled);

    // Cycle is a defined event even when the integration supplies no other
    // performance pulses.
    wire [EVENT_COUNT-1:0] active_event_pulses =
        event_pulses_i |
        {{(EVENT_COUNT-1){1'b0}}, 1'b1};

    wire [`RV64_XLEN-1:0] minstret_read_value = minstret_q +
        (mcountinhibit_q[`RV64_MCOUNTER_IR_BIT] ?
         {`RV64_XLEN{1'b0}} :
         {{(`RV64_XLEN-2){1'b0}}, retire_count_i});

    function [EVENT_INCREMENT_WIDTH-1:0] count_events;
        input [EVENT_COUNT-1:0] events;
        integer event_index;
        begin
            count_events = {EVENT_INCREMENT_WIDTH{1'b0}};
            for (event_index = 0; event_index < EVENT_COUNT;
                 event_index = event_index + 1)
                count_events = count_events + events[event_index];
        end
    endfunction

    wire [EVENT_INCREMENT_WIDTH-1:0]
        hpm_increment [0:HPM_STORAGE_COUNTERS-1];
    wire [`RV64_XLEN-1:0]
        hpm_read_value [0:HPM_STORAGE_COUNTERS-1];

    genvar counter_index;
    generate
        for (counter_index = 0; counter_index < HPM_COUNTERS;
             counter_index = counter_index + 1) begin : g_hpm_counter
            assign hpm_increment[counter_index] = count_events(
                active_event_pulses &
                mhpmevent_q[counter_index][EVENT_COUNT-1:0]);
            assign hpm_read_value[counter_index] =
                mhpmcounter_q[counter_index] +
                (mcountinhibit_q[counter_index + 3] ?
                 {`RV64_XLEN{1'b0}} :
                 {{(`RV64_XLEN-EVENT_INCREMENT_WIDTH){1'b0}},
                  hpm_increment[counter_index]});
        end
    endgenerate

    always @* begin
        csr_rdata_o = {`RV64_XLEN{1'b0}};
        csr_match_o = 1'b1;
        csr_valid_o = 1'b1;
        csr_writable_o = 1'b0;

        case (csr_addr_i)
            `RV64_CSR_SCOUNTEREN: begin
                csr_rdata_o = scounteren_q;
                csr_valid_o = (priv_mode_i >= `RV64_PRIV_S);
                csr_writable_o = csr_valid_o;
            end
            `RV64_CSR_MCOUNTEREN: begin
                csr_rdata_o = mcounteren_q;
                csr_valid_o = (priv_mode_i == `RV64_PRIV_M);
                csr_writable_o = csr_valid_o;
            end
            `RV64_CSR_MCOUNTINHIBIT: begin
                csr_rdata_o = mcountinhibit_q;
                csr_valid_o = (priv_mode_i == `RV64_PRIV_M);
                csr_writable_o = csr_valid_o;
            end
            `RV64_CSR_MCYCLE: begin
                csr_rdata_o = mcycle_q;
                csr_valid_o = (priv_mode_i == `RV64_PRIV_M);
                csr_writable_o = csr_valid_o;
            end
            `RV64_CSR_MINSTRET: begin
                csr_rdata_o = minstret_read_value;
                csr_valid_o = (priv_mode_i == `RV64_PRIV_M);
                csr_writable_o = csr_valid_o;
            end
            `RV64_CSR_CYCLE: begin
                csr_rdata_o = mcycle_q;
                csr_valid_o = counter_alias_access_ok;
            end
            `RV64_CSR_TIME: begin
                // Limited platform timebase: one tick per core clock.  A
                // future SoC integration should supply mtime directly.
                csr_rdata_o = mcycle_q;
                csr_valid_o = counter_alias_access_ok;
            end
            `RV64_CSR_INSTRET: begin
                csr_rdata_o = minstret_read_value;
                csr_valid_o = counter_alias_access_ok;
            end
            default: begin
                if (csr_is_mhpmcounter) begin
                    csr_valid_o = (priv_mode_i == `RV64_PRIV_M);
                    csr_writable_o = csr_valid_o &&
                                     csr_hpm_implemented;
                    if (csr_hpm_implemented)
                        csr_rdata_o = hpm_read_value[csr_hpm_index];
                end else if (csr_is_mhpmevent) begin
                    csr_valid_o = (priv_mode_i == `RV64_PRIV_M);
                    csr_writable_o = csr_valid_o &&
                                     csr_hpm_implemented;
                    if (csr_hpm_implemented)
                        csr_rdata_o = mhpmevent_q[csr_hpm_index];
                end else if (csr_is_hpmcounter) begin
                    csr_valid_o = counter_alias_access_ok;
                    if (csr_hpm_implemented)
                        csr_rdata_o = hpm_read_value[csr_hpm_index];
                end else begin
                    csr_match_o = 1'b0;
                    csr_valid_o = 1'b0;
                end
            end
        endcase
    end

    wire csr_write_accept =
        csr_write_i && csr_match_o && csr_valid_o && csr_writable_o;

    integer reset_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mcounteren_q <= {`RV64_XLEN{1'b0}};
            scounteren_q <= {`RV64_XLEN{1'b0}};
            mcountinhibit_q <= {`RV64_XLEN{1'b0}};
            mcycle_q <= {`RV64_XLEN{1'b0}};
            minstret_q <= {`RV64_XLEN{1'b0}};
            for (reset_index = 0; reset_index < HPM_COUNTERS;
                 reset_index = reset_index + 1) begin
                mhpmcounter_q[reset_index] <= {`RV64_XLEN{1'b0}};
                mhpmevent_q[reset_index] <= {`RV64_XLEN{1'b0}};
            end
        end else begin
            if (!mcountinhibit_q[`RV64_MCOUNTER_CY_BIT])
                mcycle_q <= mcycle_q + 64'd1;
            if ((retire_count_i != 2'd0) &&
                !mcountinhibit_q[`RV64_MCOUNTER_IR_BIT])
                minstret_q <= minstret_q +
                    {{(`RV64_XLEN-2){1'b0}}, retire_count_i};

            for (reset_index = 0; reset_index < HPM_COUNTERS;
                 reset_index = reset_index + 1)
                if (!mcountinhibit_q[reset_index + 3] &&
                    (hpm_increment[reset_index] != 0))
                    mhpmcounter_q[reset_index] <=
                        mhpmcounter_q[reset_index] +
                        {{(`RV64_XLEN-EVENT_INCREMENT_WIDTH){1'b0}},
                         hpm_increment[reset_index]};

            if (csr_write_accept) begin
                case (csr_addr_i)
                    `RV64_CSR_SCOUNTEREN:
                        scounteren_q <= csr_wdata_i &
                                        COUNTER_ENABLE_MASK;
                    `RV64_CSR_MCOUNTEREN:
                        mcounteren_q <= csr_wdata_i &
                                        COUNTER_ENABLE_MASK;
                    `RV64_CSR_MCOUNTINHIBIT:
                        mcountinhibit_q <= csr_wdata_i &
                                           COUNTINHIBIT_MASK;
                    `RV64_CSR_MCYCLE: mcycle_q <= csr_wdata_i;
                    `RV64_CSR_MINSTRET: minstret_q <= csr_wdata_i;
                    default: begin
                        if (csr_is_mhpmcounter &&
                            csr_hpm_implemented)
                            mhpmcounter_q[csr_hpm_index] <= csr_wdata_i;
                        else if (csr_is_mhpmevent &&
                                 csr_hpm_implemented)
                            mhpmevent_q[csr_hpm_index] <=
                                csr_wdata_i & HPM_EVENT_MASK;
                    end
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((HPM_COUNTERS < 0) || (HPM_COUNTERS > 29))
            $fatal(1, "CMU HPM_COUNTERS must be in the range 0..29");
    end
`endif

endmodule
