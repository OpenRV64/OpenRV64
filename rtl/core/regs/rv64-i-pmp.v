`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"

module openrv64_rv64i_pmp (
    input  wire                             clk,
    input  wire                             rst_n,

    input  wire [`RV64_FUNCT12_WIDTH-1:0]  csr_addr_i,
    output reg  [`RV64_XLEN-1:0]           csr_rdata_o,
    output reg                              csr_match_o,
    output reg                              csr_writable_o,
    input  wire                             csr_write_i,
    input  wire [`RV64_XLEN-1:0]           csr_wdata_i,

    input  wire [`RV64_PRIV_WIDTH-1:0]     instr_priv_mode_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]     data_priv_mode_i,
    input  wire [`RV64_XLEN-1:0]           instr_addr_i,
    output wire                             instr_allow_o,
    input  wire                             data_valid_i,
    input  wire [`RV64_XLEN-1:0]           data_addr_i,
    input  wire [2:0]                       data_size_i,
    input  wire                             data_write_i,
    output wire                             data_allow_o,

    input  wire                             bus_valid_i,
    input  wire [`RV64_XLEN-1:0]           bus_addr_i,
    input  wire [2:0]                       bus_size_i,
    input  wire                             bus_write_i,
    input  wire                             bus_exec_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]     bus_priv_mode_i,
    output wire                             bus_allow_o
);

    // The privileged architecture permits 0, 16, or 64 entries.  This core
    // implements the minimum useful set.  RV64 PMP covers physical address
    // bits 55:2, and this implementation deliberately chooses page-sized
    // 4 KiB grain.  OFF and NAPOT are the only supported A-field values;
    // TOR and NA4 writes are WARL-coerced to OFF.
    localparam integer PMP_ENTRIES = 16;
    localparam integer PMP_CFG_BITS = PMP_ENTRIES * 8;
    localparam integer PMP_ADDR_WIDTH = 54;
    localparam integer PMP_GRAIN_LOG2 = 12;
    localparam integer PMP_GRAIN_G = PMP_GRAIN_LOG2 - 2;
    localparam integer PMP_NAPOT_FORCED_ONES = PMP_GRAIN_G - 1;
    localparam integer PMP_REGION_LOW_BITS = PMP_ENTRIES * 64;
    localparam integer PMP_REGION_HIGH_BITS = PMP_ENTRIES * 65;

    reg [PMP_CFG_BITS-1:0] pmpcfg_q;
    reg [PMP_ADDR_WIDTH-1:0] pmpaddr_q [0:PMP_ENTRIES-1];

    // Normalized [low, high) NAPOT bounds are generated only when pmpaddr is
    // written.  The request path consequently contains fixed comparisons and
    // first-match selection, not trailing-one scans or variable shifts.
    reg [63:0] pmp_region_low_q [0:PMP_ENTRIES-1];
    reg [64:0] pmp_region_high_q [0:PMP_ENTRIES-1];
    wire [PMP_REGION_LOW_BITS-1:0] pmp_region_low_state;
    wire [PMP_REGION_HIGH_BITS-1:0] pmp_region_high_state;

    integer i;
    integer read_entry;

    genvar state_entry;
    generate
        for (state_entry = 0;
             state_entry < PMP_ENTRIES;
             state_entry = state_entry + 1) begin : g_region_state
            assign pmp_region_low_state[(state_entry * 64) +: 64] =
                pmp_region_low_q[state_entry];
            assign pmp_region_high_state[(state_entry * 65) +: 65] =
                pmp_region_high_q[state_entry];
        end
    endgenerate

    function [7:0] pmpcfg_warl;
        input [7:0] cfg;
        reg [1:0] supported_mode;
        begin
            supported_mode =
                (cfg[`RV64_PMP_CFG_A_BITS] == `RV64_PMP_A_NAPOT) ?
                `RV64_PMP_A_NAPOT : `RV64_PMP_A_OFF;
            pmpcfg_warl = {
                cfg[`RV64_PMP_CFG_L_BIT],
                2'b00,
                supported_mode,
                cfg[`RV64_PMP_CFG_X_BIT],
                cfg[`RV64_PMP_CFG_W_BIT] &
                    cfg[`RV64_PMP_CFG_R_BIT],
                cfg[`RV64_PMP_CFG_R_BIT]
            };
        end
    endfunction

    function [`RV64_XLEN-1:0] pmpaddr_read_value;
        input [PMP_ADDR_WIDTH-1:0] addr;
        input [1:0] mode;
        reg [PMP_ADDR_WIDTH-1:0] value;
        begin
            value = addr;
            if (mode == `RV64_PMP_A_NAPOT)
                value[PMP_NAPOT_FORCED_ONES-1:0] =
                    {PMP_NAPOT_FORCED_ONES{1'b1}};
            else
                value[PMP_GRAIN_G-1:0] = {PMP_GRAIN_G{1'b0}};
            pmpaddr_read_value = {
                {(`RV64_XLEN-PMP_ADDR_WIDTH){1'b0}}, value
            };
        end
    endfunction

    wire [PMP_ADDR_WIDTH-1:0] csr_pmpaddr_value =
        csr_wdata_i[PMP_ADDR_WIDTH-1:0];
    wire [PMP_ADDR_WIDTH-1:0] csr_napot_encoded =
        csr_pmpaddr_value |
        {{(PMP_ADDR_WIDTH-PMP_NAPOT_FORCED_ONES){1'b0}},
         {PMP_NAPOT_FORCED_ONES{1'b1}}};
    wire [PMP_ADDR_WIDTH-1:0] csr_napot_changed =
        csr_napot_encoded ^
        (csr_napot_encoded +
         {{(PMP_ADDR_WIDTH-1){1'b0}}, 1'b1});
    wire [63:0] csr_napot_mask = {
        {(64-PMP_ADDR_WIDTH-2){1'b0}}, csr_napot_changed, 2'b11
    };
    wire [63:0] csr_napot_address = {
        {(64-PMP_ADDR_WIDTH-2){1'b0}}, csr_pmpaddr_value, 2'b00
    };
    wire [63:0] csr_napot_low =
        csr_napot_address & ~csr_napot_mask;
    wire [64:0] csr_napot_high =
        {1'b0, csr_napot_low} + {1'b0, csr_napot_mask} + 65'd1;

    function pmp_allow;
        input [`RV64_XLEN-1:0] access_addr;
        input [2:0] access_size;
        input access_write;
        input access_execute;
        input [`RV64_PRIV_WIDTH-1:0] access_priv;
        input [PMP_CFG_BITS-1:0] cfg_state;
        input [PMP_REGION_LOW_BITS-1:0] region_low_state;
        input [PMP_REGION_HIGH_BITS-1:0] region_high_state;
        reg [64:0] access_low;
        reg [64:0] access_high;
        reg [64:0] region_low;
        reg [64:0] region_high;
        reg [7:0] cfg;
        reg permitted;
        reg [PMP_ENTRIES-1:0] overlap;
        reg [PMP_ENTRIES-1:0] entry_allow;
        integer entry;
        begin
            access_low = {1'b0, access_addr};
            access_high =
                access_low + (65'd1 << access_size);
            overlap = {PMP_ENTRIES{1'b0}};
            entry_allow = {PMP_ENTRIES{1'b0}};

            for (entry = 0; entry < PMP_ENTRIES;
                 entry = entry + 1) begin
                cfg = cfg_state[(entry * 8) +: 8];
                region_low = {1'b0,
                    region_low_state[(entry * 64) +: 64]};
                region_high =
                    region_high_state[(entry * 65) +: 65];
                permitted =
                    access_execute ? cfg[`RV64_PMP_CFG_X_BIT] :
                    access_write ? cfg[`RV64_PMP_CFG_W_BIT] :
                                   cfg[`RV64_PMP_CFG_R_BIT];

                overlap[entry] =
                    (cfg[`RV64_PMP_CFG_A_BITS] ==
                     `RV64_PMP_A_NAPOT) &&
                    (access_low < region_high) &&
                    (access_high > region_low);
                entry_allow[entry] =
                    (access_low >= region_low) &&
                    (access_high <= region_high) &&
                    (((access_priv == `RV64_PRIV_M) &&
                      !cfg[`RV64_PMP_CFG_L_BIT]) ||
                     permitted);
            end

            // Lowest-numbered overlapping entry has architectural priority.
            // Explicit patterns prevent the request path from inheriting the
            // nested procedural "found" cascade used by the former checker.
            casez (overlap)
                16'b???????????????1: pmp_allow = entry_allow[0];
                16'b??????????????10: pmp_allow = entry_allow[1];
                16'b?????????????100: pmp_allow = entry_allow[2];
                16'b????????????1000: pmp_allow = entry_allow[3];
                16'b???????????10000: pmp_allow = entry_allow[4];
                16'b??????????100000: pmp_allow = entry_allow[5];
                16'b?????????1000000: pmp_allow = entry_allow[6];
                16'b????????10000000: pmp_allow = entry_allow[7];
                16'b???????100000000: pmp_allow = entry_allow[8];
                16'b??????1000000000: pmp_allow = entry_allow[9];
                16'b?????10000000000: pmp_allow = entry_allow[10];
                16'b????100000000000: pmp_allow = entry_allow[11];
                16'b???1000000000000: pmp_allow = entry_allow[12];
                16'b??10000000000000: pmp_allow = entry_allow[13];
                16'b?100000000000000: pmp_allow = entry_allow[14];
                16'b1000000000000000: pmp_allow = entry_allow[15];
                default:
                    pmp_allow = (access_priv == `RV64_PRIV_M);
            endcase
        end
    endfunction

    assign instr_allow_o =
        pmp_allow(instr_addr_i, 3'd2, 1'b0, 1'b1,
                  instr_priv_mode_i, pmpcfg_q,
                  pmp_region_low_state, pmp_region_high_state);
    assign data_allow_o =
        !data_valid_i ||
        pmp_allow(data_addr_i, data_size_i, data_write_i, 1'b0,
                  data_priv_mode_i, pmpcfg_q,
                  pmp_region_low_state, pmp_region_high_state);
    assign bus_allow_o =
        !bus_valid_i ||
        pmp_allow(bus_addr_i, bus_size_i, bus_write_i, bus_exec_i,
                  bus_priv_mode_i, pmpcfg_q,
                  pmp_region_low_state, pmp_region_high_state);

    always @* begin
        csr_rdata_o = {`RV64_XLEN{1'b0}};
        csr_match_o = 1'b1;
        csr_writable_o = 1'b1;

        case (csr_addr_i)
            `RV64_CSR_PMPCFG0:
                csr_rdata_o = pmpcfg_q[63:0];
            `RV64_CSR_PMPCFG2:
                csr_rdata_o = pmpcfg_q[127:64];
            default: begin
                csr_match_o = 1'b0;
                csr_writable_o = 1'b0;
                for (read_entry = 0; read_entry < PMP_ENTRIES;
                     read_entry = read_entry + 1) begin
                    if (csr_addr_i ==
                        (`RV64_CSR_PMPADDR0 + read_entry)) begin
                        csr_match_o = 1'b1;
                        csr_writable_o = 1'b1;
                        csr_rdata_o = pmpaddr_read_value(
                            pmpaddr_q[read_entry],
                            pmpcfg_q[(read_entry * 8) + 3 +: 2]);
                    end
                end
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pmpcfg_q <= {PMP_CFG_BITS{1'b0}};
            for (i = 0; i < PMP_ENTRIES; i = i + 1) begin
                pmpaddr_q[i] <= {PMP_ADDR_WIDTH{1'b0}};
                pmp_region_low_q[i] <= 64'd0;
                pmp_region_high_q[i] <= 65'd4096;
            end
        end else if (csr_write_i) begin
            if (csr_addr_i == `RV64_CSR_PMPCFG0) begin
                for (i = 0; i < 8; i = i + 1) begin
                    if (!pmpcfg_q[(i * 8) +
                                  `RV64_PMP_CFG_L_BIT])
                        pmpcfg_q[(i * 8) +: 8] <=
                            pmpcfg_warl(csr_wdata_i[(i * 8) +: 8]);
                end
            end else if (csr_addr_i == `RV64_CSR_PMPCFG2) begin
                for (i = 8; i < PMP_ENTRIES; i = i + 1) begin
                    if (!pmpcfg_q[(i * 8) +
                                  `RV64_PMP_CFG_L_BIT])
                        pmpcfg_q[(i * 8) +: 8] <=
                            pmpcfg_warl(
                                csr_wdata_i[((i - 8) * 8) +: 8]);
                end
            end

            for (i = 0; i < PMP_ENTRIES; i = i + 1) begin
                if ((csr_addr_i == (`RV64_CSR_PMPADDR0 + i)) &&
                    !pmpcfg_q[(i * 8) + `RV64_PMP_CFG_L_BIT]) begin
                    pmpaddr_q[i] <= csr_pmpaddr_value;
                    pmp_region_low_q[i] <= csr_napot_low;
                    pmp_region_high_q[i] <= csr_napot_high;
                end
            end
        end
    end

endmodule
