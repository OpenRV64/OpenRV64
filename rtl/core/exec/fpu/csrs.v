`ifndef OPENRV64_FPU_CSRS_V
`define OPENRV64_FPU_CSRS_V
`timescale 1ns/1ps

`include "core/isa/rv64-i.v"
`include "core/exec/fpu/isa/rv64-f.v"
`include "core/isa/rv64-priv.v"
`include "core/exec/fpu/defs.v"

// F/D-owned architectural CSR state.  The integer CSR block supplies only a
// generic, privilege-checked CSR client and disjoint misa/status overlays.
module openrv64_fpu_csrs #(
    parameter ENABLE_RV64F = 0,
    parameter ENABLE_RV64D = 0
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire [`RV64_FUNCT12_WIDTH-1:0] csr_addr_i,
    input  wire [`RV64_XLEN-1:0]        csr_wdata_i,
    input  wire                         csr_write_i,
    input  wire                         mstatus_write_i,
    input  wire                         sstatus_write_i,
    output wire                         csr_selected_o,
    output wire                         csr_valid_o,
    output wire                         csr_writable_o,
    output reg  [`RV64_XLEN-1:0]        csr_rdata_o,
    output wire                         csr_write_ready_o,

    input  wire                         retire_state_dirty_i,
    input  wire                         retire_fflags_valid_i,
    input  wire [4:0]                   retire_fflags_i,

    output wire [`RV64_XLEN-1:0]        misa_bits_o,
    output wire [`RV64_XLEN-1:0]        mstatus_bits_o,
    output wire [`RV64_XLEN-1:0]        sstatus_bits_o,
    output wire [1:0]                   state_o,
    output wire                         state_enabled_o,
    output wire [2:0]                   frm_o,
    output wire [4:0]                   fflags_o
);

    reg [1:0] state_q;
    reg [2:0] frm_q;
    reg [4:0] fflags_q;

    wire f_enabled = (ENABLE_RV64F != 0);
    wire state_enabled = f_enabled &&
                         (state_q != `RV64_MSTATUS_FS_OFF);
    wire state_dirty = f_enabled &&
                       (state_q == `RV64_MSTATUS_FS_DIRTY);
    wire fcsr_selected = (csr_addr_i == `RV64_FP_CSR_FFLAGS) ||
                         (csr_addr_i == `RV64_FP_CSR_FRM) ||
                         (csr_addr_i == `RV64_FP_CSR_FCSR);

    assign csr_selected_o = fcsr_selected;
    assign csr_valid_o = fcsr_selected && state_enabled;
    assign csr_writable_o = csr_valid_o;
    assign csr_write_ready_o = 1'b1;

    always @* begin
        csr_rdata_o = {`RV64_XLEN{1'b0}};
        case (csr_addr_i)
            `RV64_FP_CSR_FFLAGS: csr_rdata_o = {{59{1'b0}}, fflags_q};
            `RV64_FP_CSR_FRM: csr_rdata_o = {{61{1'b0}}, frm_q};
            `RV64_FP_CSR_FCSR: csr_rdata_o =
                {{56{1'b0}}, frm_q, fflags_q};
            default: csr_rdata_o = {`RV64_XLEN{1'b0}};
        endcase
        if (!csr_valid_o)
            csr_rdata_o = {`RV64_XLEN{1'b0}};
    end

    assign misa_bits_o = f_enabled ?
        ((64'd1 << 5) |
         ((ENABLE_RV64D != 0) ? (64'd1 << 3) : 64'd0)) : 64'd0;
    assign mstatus_bits_o = f_enabled ?
        (({{62{1'b0}}, state_q} << `RV64_MSTATUS_FS_SHIFT) |
         (state_dirty ? (64'd1 << `RV64_MSTATUS_SD_BIT) : 64'd0)) :
        64'd0;
    assign sstatus_bits_o = mstatus_bits_o;
    assign state_o = f_enabled ? state_q : `RV64_MSTATUS_FS_OFF;
    assign state_enabled_o = state_enabled;
    assign frm_o = f_enabled ? frm_q : `RV64_FP_RM_RNE;
    assign fflags_o = f_enabled ? fflags_q : 5'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= `RV64_MSTATUS_FS_OFF;
            frm_q <= `RV64_FP_RM_RNE;
            fflags_q <= 5'd0;
        end else begin
            if (mstatus_write_i || sstatus_write_i)
                state_q <= csr_wdata_i[`RV64_MSTATUS_FS_BITS];

            if (state_enabled &&
                (retire_state_dirty_i || retire_fflags_valid_i))
                state_q <= `RV64_MSTATUS_FS_DIRTY;

            if (state_enabled && retire_fflags_valid_i)
                fflags_q <= fflags_q | retire_fflags_i;

            if (csr_write_i && csr_valid_o && csr_writable_o) begin
                state_q <= `RV64_MSTATUS_FS_DIRTY;
                case (csr_addr_i)
                    `RV64_FP_CSR_FFLAGS: fflags_q <= csr_wdata_i[4:0];
                    `RV64_FP_CSR_FRM: frm_q <= csr_wdata_i[2:0];
                    `RV64_FP_CSR_FCSR: begin
                        fflags_q <= csr_wdata_i[4:0];
                        frm_q <= csr_wdata_i[7:5];
                    end
                    default: begin
                    end
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((ENABLE_RV64D != 0) && (ENABLE_RV64F == 0))
            $fatal(1, "RV64D requires RV64F");
    end

    always @(posedge clk) begin
        if (rst_n && f_enabled) begin
            if ((retire_state_dirty_i || retire_fflags_valid_i) &&
                !state_enabled)
                $fatal(1, "retired FPU state update while mstatus.FS is Off");
            if (retire_fflags_valid_i && csr_write_i)
                $fatal(1, "serialize FPU flags and FPU CSR retirement writes");
            if ((retire_state_dirty_i || retire_fflags_valid_i) &&
                (mstatus_write_i || sstatus_write_i))
                $fatal(1, "serialize FPU state updates and status writes");
            if (csr_write_i && (mstatus_write_i || sstatus_write_i))
                $fatal(1, "one CSR retirement cannot target two CSR clients");
        end
    end
`endif

endmodule

`endif
