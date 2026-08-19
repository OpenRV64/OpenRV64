`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"

module openrv64_rv64i_pmp #(
    parameter integer PMP_ACTIVE_ENTRIES = 8
) (
    input  wire                             clk,
    input  wire                             rst_n,

    input  wire [`RV64_FUNCT12_WIDTH-1:0]  csr_addr_i,
    output reg  [`RV64_XLEN-1:0]           csr_rdata_o,
    output reg                              csr_match_o,
    output reg                              csr_writable_o,
    input  wire                             csr_write_i,
    input  wire [`RV64_XLEN-1:0]           csr_wdata_i,
    output wire                             csr_write_ready_o,
    output wire                             csr_busy_o,

    input  wire                             bus_valid_i,
    input  wire [`RV64_XLEN-1:0]           bus_addr_i,
    input  wire [2:0]                       bus_size_i,
    input  wire                             bus_write_i,
    input  wire                             bus_exec_i,
    input  wire [`RV64_PRIV_WIDTH-1:0]     bus_priv_mode_i,
    output wire                             bus_allow_o
);

    // Sixteen PMP entries are architecturally visible.  Only the lowest
    // PMP_ACTIVE_ENTRIES have storage and comparators; all higher entry fields
    // are WARL read-only zero.  The core defaults to eight active entries and
    // resource-constrained targets may select fewer without changing the CSR
    // surface.  This implementation has a 39-bit byte physical-address space,
    // so pmpaddr implements PA[38:2] and WARL reads zero above it.  It chooses
    // 4 KiB grain and supports OFF and NAPOT; TOR and NA4 coerce to OFF.
    localparam integer PMP_ARCH_ENTRIES = 16;
    localparam integer PMP_CFG_BITS = PMP_ACTIVE_ENTRIES * 8;
    localparam integer PMP_PA_WIDTH = 39;
    localparam integer PMP_ADDR_WIDTH = PMP_PA_WIDTH - 2;
    localparam integer PMP_BOUND_WIDTH = PMP_PA_WIDTH + 1;
    localparam integer PMP_GRAIN_LOG2 = 12;
    localparam integer PMP_GRAIN_G = PMP_GRAIN_LOG2 - 2;
    localparam integer PMP_NAPOT_FORCED_ONES = PMP_GRAIN_G - 1;
    localparam integer PMP_REGION_LOW_BITS =
        PMP_ACTIVE_ENTRIES * PMP_PA_WIDTH;
    localparam integer PMP_REGION_HIGH_BITS =
        PMP_ACTIVE_ENTRIES * PMP_BOUND_WIDTH;

    reg [PMP_CFG_BITS-1:0] pmpcfg_q;
    reg [PMP_ADDR_WIDTH-1:0] pmpaddr_q [0:PMP_ACTIVE_ENTRIES-1];

    // Normalized [low, high) NAPOT bounds are generated only when pmpaddr is
    // written.  The request path consequently contains fixed comparisons and
    // first-match selection, not trailing-one scans or variable shifts.
    reg [PMP_PA_WIDTH-1:0] pmp_region_low_q [0:PMP_ACTIVE_ENTRIES-1];
    reg [PMP_BOUND_WIDTH-1:0] pmp_region_high_q [0:PMP_ACTIVE_ENTRIES-1];
    wire [PMP_REGION_LOW_BITS-1:0] pmp_region_low_state;
    wire [PMP_REGION_HIGH_BITS-1:0] pmp_region_high_state;

    // PMPADDR writes are intentionally glacial.  The trailing-one scan and
    // the high-bound increment each consume exactly one source bit per cycle.
    // The architectural address and normalized bounds remain unchanged until
    // the final increment bit commits all three arrays together.
    reg pmpaddr_busy_q;
    reg pmpaddr_add_phase_q;
    reg pmpaddr_done_q;
    reg [3:0] pmpaddr_entry_q;
    reg [PMP_ADDR_WIDTH-1:0] pmpaddr_pending_q;
    reg [PMP_ADDR_WIDTH-1:0] pmpaddr_scan_q;
    reg [$clog2(PMP_BOUND_WIDTH)-1:0] pmpaddr_bit_count_q;
    reg [PMP_PA_WIDTH-1:0] pmpaddr_address_q;
    reg [PMP_PA_WIDTH-1:0] pmpaddr_mask_q;
    reg [PMP_PA_WIDTH-1:0] pmpaddr_low_q;
    reg [PMP_BOUND_WIDTH-1:0] pmpaddr_add_source_q;
    reg [PMP_BOUND_WIDTH-1:0] pmpaddr_high_work_q;
    reg pmpaddr_add_carry_q;

    integer i;
    integer read_entry;

    genvar state_entry;
    generate
        for (state_entry = 0;
             state_entry < PMP_ACTIVE_ENTRIES;
             state_entry = state_entry + 1) begin : g_region_state
            assign pmp_region_low_state[
                (state_entry * PMP_PA_WIDTH) +: PMP_PA_WIDTH] =
                pmp_region_low_q[state_entry];
            assign pmp_region_high_state[
                (state_entry * PMP_BOUND_WIDTH) +: PMP_BOUND_WIDTH] =
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
    wire csr_pmpaddr_match =
        (csr_addr_i >= `RV64_CSR_PMPADDR0) &&
        (csr_addr_i < (`RV64_CSR_PMPADDR0 + PMP_ARCH_ENTRIES));
    wire [3:0] csr_pmpaddr_entry =
        csr_addr_i - `RV64_CSR_PMPADDR0;
    wire csr_pmpaddr_active = csr_pmpaddr_match &&
        (csr_pmpaddr_entry < PMP_ACTIVE_ENTRIES);
    reg csr_pmpaddr_locked;
    integer lock_entry;
    always @* begin
        csr_pmpaddr_locked = 1'b0;
        for (lock_entry = 0; lock_entry < PMP_ACTIVE_ENTRIES;
             lock_entry = lock_entry + 1)
            if (csr_pmpaddr_entry == lock_entry)
                csr_pmpaddr_locked = pmpcfg_q[(lock_entry * 8) +
                    `RV64_PMP_CFG_L_BIT];
    end
    wire pmpaddr_start = csr_write_i && csr_pmpaddr_active &&
        !csr_pmpaddr_locked && !pmpaddr_busy_q && !pmpaddr_done_q;
    wire [PMP_PA_WIDTH-1:0] pmpaddr_scan_mask_next =
        {pmpaddr_mask_q[PMP_PA_WIDTH-2:0], 1'b1};
    wire pmpaddr_add_sum =
        pmpaddr_add_source_q[0] ^ pmpaddr_add_carry_q;
    wire pmpaddr_add_carry_next =
        pmpaddr_add_source_q[0] & pmpaddr_add_carry_q;
    wire [PMP_BOUND_WIDTH-1:0] pmpaddr_high_next = {
        pmpaddr_add_sum,
        pmpaddr_high_work_q[PMP_BOUND_WIDTH-1:1]
    };

    assign csr_busy_o = pmpaddr_busy_q;
    // A held 3P retirement request becomes ready only after the atomic
    // commit.  Locked PMPADDR writes and ordinary PMPCFG writes complete
    // immediately.  The 1P pipeline separately uses csr_busy_o to hold WB.
    assign csr_write_ready_o =
        !csr_write_i ? 1'b1 :
        (csr_pmpaddr_active && !csr_pmpaddr_locked) ?
            pmpaddr_done_q :
            !pmpaddr_busy_q;

    function pmp_allow;
        input [`RV64_XLEN-1:0] access_addr;
        input [2:0] access_size;
        input access_write;
        input access_execute;
        input [`RV64_PRIV_WIDTH-1:0] access_priv;
        input [PMP_CFG_BITS-1:0] cfg_state;
        input [PMP_REGION_LOW_BITS-1:0] region_low_state;
        input [PMP_REGION_HIGH_BITS-1:0] region_high_state;
        reg [PMP_BOUND_WIDTH-1:0] access_low;
        reg [PMP_BOUND_WIDTH-1:0] access_high;
        reg [PMP_BOUND_WIDTH-1:0] region_low;
        reg [PMP_BOUND_WIDTH-1:0] region_high;
        reg access_representable;
        reg [7:0] cfg;
        reg permitted;
        // Keep the fixed 16-way priority form used by the normal core.  A
        // reduced implementation leaves the absent upper entries clear.
        reg [15:0] overlap;
        reg [15:0] entry_allow;
        integer entry;
        begin
            access_low = {1'b0, access_addr[PMP_PA_WIDTH-1:0]};
            access_high = access_low +
                ({{(PMP_BOUND_WIDTH-1){1'b0}}, 1'b1} << access_size);
            access_representable =
                !(|access_addr[`RV64_XLEN-1:PMP_PA_WIDTH]);
            overlap = 16'd0;
            entry_allow = 16'd0;

            for (entry = 0; entry < PMP_ACTIVE_ENTRIES;
                 entry = entry + 1) begin
                cfg = cfg_state[(entry * 8) +: 8];
                region_low = {1'b0, region_low_state[
                    (entry * PMP_PA_WIDTH) +: PMP_PA_WIDTH]};
                region_high = region_high_state[
                    (entry * PMP_BOUND_WIDTH) +: PMP_BOUND_WIDTH];
                permitted =
                    access_execute ? cfg[`RV64_PMP_CFG_X_BIT] :
                    access_write ? cfg[`RV64_PMP_CFG_W_BIT] :
                                   cfg[`RV64_PMP_CFG_R_BIT];

                overlap[entry] =
                    access_representable &&
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
            `RV64_CSR_PMPCFG0: begin
                csr_rdata_o = {`RV64_XLEN{1'b0}};
                for (read_entry = 0;
                     (read_entry < PMP_ACTIVE_ENTRIES) && (read_entry < 8);
                     read_entry = read_entry + 1)
                    csr_rdata_o[(read_entry * 8) +: 8] =
                        pmpcfg_q[(read_entry * 8) +: 8];
            end
            `RV64_CSR_PMPCFG2: begin
                csr_rdata_o = {`RV64_XLEN{1'b0}};
                for (read_entry = 8;
                     (read_entry < PMP_ACTIVE_ENTRIES) &&
                     (read_entry < PMP_ARCH_ENTRIES);
                     read_entry = read_entry + 1)
                    csr_rdata_o[((read_entry - 8) * 8) +: 8] =
                        pmpcfg_q[(read_entry * 8) +: 8];
            end
            default: begin
                csr_match_o = 1'b0;
                csr_writable_o = 1'b0;
                if (csr_pmpaddr_match) begin
                    csr_match_o = 1'b1;
                    csr_writable_o = 1'b1;
                    for (read_entry = 0;
                         read_entry < PMP_ACTIVE_ENTRIES;
                         read_entry = read_entry + 1)
                        if (csr_pmpaddr_entry == read_entry)
                            csr_rdata_o = pmpaddr_read_value(
                                pmpaddr_q[read_entry],
                                pmpcfg_q[(read_entry * 8) + 3 +: 2]);
                end
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pmpcfg_q <= {PMP_CFG_BITS{1'b0}};
            pmpaddr_busy_q <= 1'b0;
            pmpaddr_add_phase_q <= 1'b0;
            pmpaddr_done_q <= 1'b0;
            pmpaddr_entry_q <= 4'd0;
            pmpaddr_pending_q <= {PMP_ADDR_WIDTH{1'b0}};
            pmpaddr_scan_q <= {PMP_ADDR_WIDTH{1'b0}};
            pmpaddr_bit_count_q <= '0;
            pmpaddr_address_q <= '0;
            pmpaddr_mask_q <= '0;
            pmpaddr_low_q <= '0;
            pmpaddr_add_source_q <= '0;
            pmpaddr_high_work_q <= '0;
            pmpaddr_add_carry_q <= 1'b0;
            for (i = 0; i < PMP_ACTIVE_ENTRIES; i = i + 1) begin
                pmpaddr_q[i] <= {PMP_ADDR_WIDTH{1'b0}};
                pmp_region_low_q[i] <= '0;
                pmp_region_high_q[i] <= 40'd4096;
            end
        end else begin
            if (!csr_write_i || pmpaddr_done_q)
                pmpaddr_done_q <= 1'b0;

            if (pmpaddr_busy_q) begin
                if (!pmpaddr_add_phase_q) begin
                    // Include the first zero above the trailing-one run in
                    // the mask.  A full-width all-one value terminates at the
                    // implemented physical-address limit.
                    if (!pmpaddr_scan_q[0] ||
                        (pmpaddr_bit_count_q ==
                         (PMP_ADDR_WIDTH - 1))) begin
                        pmpaddr_low_q <= pmpaddr_address_q &
                                         ~pmpaddr_scan_mask_next;
                        pmpaddr_add_source_q <= {
                            1'b0,
                            pmpaddr_address_q |
                            pmpaddr_scan_mask_next
                        };
                        pmpaddr_high_work_q <= '0;
                        pmpaddr_add_carry_q <= 1'b1;
                        pmpaddr_bit_count_q <= '0;
                        pmpaddr_add_phase_q <= 1'b1;
                    end else begin
                        pmpaddr_scan_q <= {
                            1'b0, pmpaddr_scan_q[PMP_ADDR_WIDTH-1:1]
                        };
                        pmpaddr_mask_q <= pmpaddr_scan_mask_next;
                        pmpaddr_bit_count_q <= pmpaddr_bit_count_q + 1'b1;
                    end
                end else begin
                    pmpaddr_add_source_q <= {
                        1'b0,
                        pmpaddr_add_source_q[PMP_BOUND_WIDTH-1:1]
                    };
                    pmpaddr_high_work_q <= pmpaddr_high_next;
                    pmpaddr_add_carry_q <= pmpaddr_add_carry_next;
                    if (pmpaddr_bit_count_q ==
                        (PMP_BOUND_WIDTH - 1)) begin
                        pmpaddr_q[pmpaddr_entry_q] <= pmpaddr_pending_q;
                        pmp_region_low_q[pmpaddr_entry_q] <=
                            pmpaddr_low_q;
                        pmp_region_high_q[pmpaddr_entry_q] <=
                            pmpaddr_high_next;
                        pmpaddr_busy_q <= 1'b0;
                        pmpaddr_add_phase_q <= 1'b0;
                        pmpaddr_done_q <= 1'b1;
                    end else begin
                        pmpaddr_bit_count_q <= pmpaddr_bit_count_q + 1'b1;
                    end
                end
            end else if (pmpaddr_start) begin
                pmpaddr_busy_q <= 1'b1;
                pmpaddr_add_phase_q <= 1'b0;
                pmpaddr_entry_q <= csr_pmpaddr_entry;
                pmpaddr_pending_q <= csr_pmpaddr_value;
                pmpaddr_scan_q <=
                    csr_pmpaddr_value |
                    {{(PMP_ADDR_WIDTH-PMP_NAPOT_FORCED_ONES){1'b0}},
                     {PMP_NAPOT_FORCED_ONES{1'b1}}};
                pmpaddr_bit_count_q <= '0;
                pmpaddr_address_q <= {csr_pmpaddr_value, 2'b00};
                pmpaddr_mask_q <=
                    {{(PMP_PA_WIDTH-2){1'b0}}, 2'b11};
            end else if (csr_write_i && !pmpaddr_done_q &&
                         (csr_addr_i == `RV64_CSR_PMPCFG0)) begin
                for (i = 0;
                     (i < PMP_ACTIVE_ENTRIES) && (i < 8);
                     i = i + 1) begin
                    if (!pmpcfg_q[(i * 8) +
                                  `RV64_PMP_CFG_L_BIT])
                        pmpcfg_q[(i * 8) +: 8] <=
                            pmpcfg_warl(csr_wdata_i[(i * 8) +: 8]);
                end
            end else if (csr_write_i && !pmpaddr_done_q &&
                         (csr_addr_i == `RV64_CSR_PMPCFG2)) begin
                for (i = 8;
                     (i < PMP_ACTIVE_ENTRIES) &&
                     (i < PMP_ARCH_ENTRIES);
                     i = i + 1) begin
                    if (!pmpcfg_q[(i * 8) +
                                  `RV64_PMP_CFG_L_BIT])
                        pmpcfg_q[(i * 8) +: 8] <=
                            pmpcfg_warl(
                                csr_wdata_i[((i - 8) * 8) +: 8]);
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((PMP_ACTIVE_ENTRIES < 1) ||
            (PMP_ACTIVE_ENTRIES > PMP_ARCH_ENTRIES))
            $fatal(1,
                   "PMP_ACTIVE_ENTRIES must be between 1 and 16");
    end
`endif

endmodule
