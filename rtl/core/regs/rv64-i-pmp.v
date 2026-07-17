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

    localparam PMP_ENTRIES = 4;

    reg [`RV64_XLEN-1:0] pmpcfg0_q;
    reg [`RV64_XLEN-3:0] pmpaddr_q [0:PMP_ENTRIES-1];
    wire [(PMP_ENTRIES * (`RV64_XLEN-2))-1:0] pmpaddr_state;
    integer i;

    genvar state_entry;
    generate
        for (state_entry = 0;
             state_entry < PMP_ENTRIES;
             state_entry = state_entry + 1) begin : g_pmpaddr_state
            assign pmpaddr_state[
                (state_entry * (`RV64_XLEN-2)) +: (`RV64_XLEN-2)] =
                pmpaddr_q[state_entry];
        end
    endgenerate

    function pmp_allow;
        input [`RV64_XLEN-1:0] access_addr;
        input [2:0] access_size;
        input access_write;
        input access_execute;
        input [`RV64_PRIV_WIDTH-1:0] access_priv;
        input [`RV64_XLEN-1:0] cfg_state;
        input [(PMP_ENTRIES * (`RV64_XLEN-2))-1:0] addr_state;
        reg found;
        reg overlap;
        reg contained;
        reg permitted;
        reg [7:0] cfg;
        reg [1:0] mode;
        reg [64:0] access_low;
        reg [64:0] access_high;
        reg [64:0] region_low;
        reg [64:0] region_high;
        reg [64:0] region_size;
        reg [64:0] region_mask;
        reg [64:0] encoded_addr;
        integer entry;
        integer bit_index;
        integer trailing_ones;
        reg count_ones;
        begin
            access_low = {1'b0, access_addr};
            access_high = access_low + (65'd1 << access_size);
            found = 1'b0;
            pmp_allow = (access_priv == `RV64_PRIV_M);

            for (entry = 0; entry < PMP_ENTRIES; entry = entry + 1) begin
                if (!found) begin
                    cfg = cfg_state[(entry * 8) +: 8];
                    mode = cfg[`RV64_PMP_CFG_A_BITS];
                    region_low = 65'd0;
                    region_high = 65'd0;

                    case (mode)
                        `RV64_PMP_A_TOR: begin
                            region_low = 65'd0;
                            if (entry != 0) begin
                                region_low = {1'b0,
                                    addr_state[((entry - 1) *
                                                (`RV64_XLEN-2)) +:
                                               (`RV64_XLEN-2)],
                                    2'b00};
                            end
                            region_high = {1'b0,
                                addr_state[(entry * (`RV64_XLEN-2)) +:
                                           (`RV64_XLEN-2)],
                                2'b00};
                        end

                        `RV64_PMP_A_NA4: begin
                            region_low = {1'b0,
                                addr_state[(entry * (`RV64_XLEN-2)) +:
                                           (`RV64_XLEN-2)],
                                2'b00};
                            region_high = region_low + 65'd4;
                        end

                        `RV64_PMP_A_NAPOT: begin
                            trailing_ones = 0;
                            count_ones = 1'b1;
                            for (bit_index = 0;
                                 bit_index < (`RV64_XLEN-2);
                                 bit_index = bit_index + 1) begin
                                if (count_ones &&
                                    addr_state[(entry * (`RV64_XLEN-2)) +
                                               bit_index]) begin
                                    trailing_ones = trailing_ones + 1;
                                end else begin
                                    count_ones = 1'b0;
                                end
                            end

                            encoded_addr = {1'b0,
                                addr_state[(entry * (`RV64_XLEN-2)) +:
                                           (`RV64_XLEN-2)],
                                2'b00};

                            if (trailing_ones >= 61) begin
                                region_low = 65'd0;
                                region_high = {1'b1, 64'd0};
                            end else begin
                                region_size = 65'd1 << (trailing_ones + 3);
                                region_mask = region_size - 65'd1;
                                region_low = encoded_addr & ~region_mask;
                                region_high = region_low + region_size;
                            end
                        end

                        default: begin
                        end
                    endcase

                    overlap = (mode != `RV64_PMP_A_OFF) &&
                              (region_high > region_low) &&
                              (access_low < region_high) &&
                              (access_high > region_low);

                    if (overlap) begin
                        found = 1'b1;
                        contained = (access_low >= region_low) &&
                                    (access_high <= region_high);
                        permitted = access_execute ? cfg[`RV64_PMP_CFG_X_BIT] :
                                    access_write ? cfg[`RV64_PMP_CFG_W_BIT] :
                                                   cfg[`RV64_PMP_CFG_R_BIT];

                        if ((access_priv == `RV64_PRIV_M) &&
                            !cfg[`RV64_PMP_CFG_L_BIT]) begin
                            pmp_allow = contained;
                        end else begin
                            pmp_allow = contained && permitted;
                        end
                    end
                end
            end
        end
    endfunction

    assign instr_allow_o = pmp_allow(instr_addr_i, 3'd2, 1'b0, 1'b1,
                                     instr_priv_mode_i,
                                     pmpcfg0_q, pmpaddr_state);
    assign data_allow_o = !data_valid_i ||
                          pmp_allow(data_addr_i, data_size_i,
                                    data_write_i, 1'b0, data_priv_mode_i,
                                    pmpcfg0_q, pmpaddr_state);
    assign bus_allow_o = !bus_valid_i ||
                         pmp_allow(bus_addr_i, bus_size_i,
                                   bus_write_i, bus_exec_i, bus_priv_mode_i,
                                   pmpcfg0_q, pmpaddr_state);

    always @* begin
        csr_rdata_o = {`RV64_XLEN{1'b0}};
        csr_match_o = 1'b1;
        csr_writable_o = 1'b1;

        case (csr_addr_i)
            `RV64_CSR_PMPCFG0:  csr_rdata_o = pmpcfg0_q;
            `RV64_CSR_PMPADDR0: csr_rdata_o = {{2{1'b0}},
                pmpaddr_state[(0 * (`RV64_XLEN-2)) +: (`RV64_XLEN-2)]};
            `RV64_CSR_PMPADDR1: csr_rdata_o = {{2{1'b0}},
                pmpaddr_state[(1 * (`RV64_XLEN-2)) +: (`RV64_XLEN-2)]};
            `RV64_CSR_PMPADDR2: csr_rdata_o = {{2{1'b0}},
                pmpaddr_state[(2 * (`RV64_XLEN-2)) +: (`RV64_XLEN-2)]};
            `RV64_CSR_PMPADDR3: csr_rdata_o = {{2{1'b0}},
                pmpaddr_state[(3 * (`RV64_XLEN-2)) +: (`RV64_XLEN-2)]};
            default: begin
                csr_match_o = 1'b0;
                csr_writable_o = 1'b0;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pmpcfg0_q <= {`RV64_XLEN{1'b0}};
            for (i = 0; i < PMP_ENTRIES; i = i + 1) begin
                pmpaddr_q[i] <= {(`RV64_XLEN-2){1'b0}};
            end
        end else if (csr_write_i) begin
            if (csr_addr_i == `RV64_CSR_PMPCFG0) begin
                for (i = 0; i < PMP_ENTRIES; i = i + 1) begin
                    if (!pmpcfg0_q[(i * 8) + `RV64_PMP_CFG_L_BIT]) begin
                        pmpcfg0_q[(i * 8) +: 8] <= {
                            csr_wdata_i[(i * 8) + `RV64_PMP_CFG_L_BIT],
                            2'b00,
                            csr_wdata_i[(i * 8) + 4 -: 2],
                            csr_wdata_i[(i * 8) + `RV64_PMP_CFG_X_BIT],
                            csr_wdata_i[(i * 8) + `RV64_PMP_CFG_W_BIT] &
                                csr_wdata_i[(i * 8) + `RV64_PMP_CFG_R_BIT],
                            csr_wdata_i[(i * 8) + `RV64_PMP_CFG_R_BIT]
                        };
                    end
                end
            end

            for (i = 0; i < PMP_ENTRIES; i = i + 1) begin
                if ((csr_addr_i == (`RV64_CSR_PMPADDR0 + i)) &&
                    !pmpcfg0_q[(i * 8) + `RV64_PMP_CFG_L_BIT] &&
                    !(((i + 1) < PMP_ENTRIES) &&
                      pmpcfg0_q[((i + 1) * 8) + `RV64_PMP_CFG_L_BIT] &&
                      (pmpcfg0_q[((i + 1) * 8) + 4 -: 2] ==
                       `RV64_PMP_A_TOR))) begin
                    pmpaddr_q[i] <= csr_wdata_i[`RV64_XLEN-3:0];
                end
            end
        end
    end

endmodule
