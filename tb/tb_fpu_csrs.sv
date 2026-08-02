`timescale 1ns/1ps

`include "core/exec/fpu/csrs.v"

module tb_fpu_csrs;
    reg clk;
    reg rst_n;
    reg [`RV64_FUNCT12_WIDTH-1:0] csr_addr;
    reg [`RV64_XLEN-1:0] csr_wdata;
    reg csr_write;
    reg mstatus_write;
    reg sstatus_write;
    reg retire_state_dirty;
    reg retire_fflags_valid;
    reg [4:0] retire_fflags;

    wire csr_selected;
    wire csr_valid;
    wire csr_writable;
    wire [`RV64_XLEN-1:0] csr_rdata;
    wire csr_write_ready;
    wire [`RV64_XLEN-1:0] misa_bits;
    wire [`RV64_XLEN-1:0] mstatus_bits;
    wire [`RV64_XLEN-1:0] sstatus_bits;
    wire [1:0] state_value;
    wire state_enabled;
    wire [2:0] frm;
    wire [4:0] fflags;

    openrv64_fpu_csrs #(
        .ENABLE_RV64F(1),
        .ENABLE_RV64D(1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .csr_addr_i(csr_addr), .csr_wdata_i(csr_wdata),
        .csr_write_i(csr_write),
        .mstatus_write_i(mstatus_write),
        .sstatus_write_i(sstatus_write),
        .csr_selected_o(csr_selected), .csr_valid_o(csr_valid),
        .csr_writable_o(csr_writable), .csr_rdata_o(csr_rdata),
        .csr_write_ready_o(csr_write_ready),
        .retire_state_dirty_i(retire_state_dirty),
        .retire_fflags_valid_i(retire_fflags_valid),
        .retire_fflags_i(retire_fflags),
        .misa_bits_o(misa_bits), .mstatus_bits_o(mstatus_bits),
        .sstatus_bits_o(sstatus_bits), .state_o(state_value),
        .state_enabled_o(state_enabled), .frm_o(frm),
        .fflags_o(fflags)
    );

    always #5 clk = ~clk;

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic write_status;
        input use_sstatus;
        input [1:0] fs;
        begin
            csr_wdata = {{49{1'b0}}, fs, 13'd0};
            mstatus_write = !use_sstatus;
            sstatus_write = use_sstatus;
            tick();
            mstatus_write = 1'b0;
            sstatus_write = 1'b0;
        end
    endtask

    task automatic write_fcsr;
        input [`RV64_FUNCT12_WIDTH-1:0] addr;
        input [`RV64_XLEN-1:0] data;
        begin
            csr_addr = addr;
            csr_wdata = data;
            #1;
            if (!csr_selected || !csr_valid || !csr_writable ||
                !csr_write_ready)
                $fatal(1, "enabled FPU CSR was not writable");
            csr_write = 1'b1;
            tick();
            csr_write = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        csr_addr = `RV64_FP_CSR_FCSR;
        csr_wdata = 64'd0;
        csr_write = 1'b0;
        mstatus_write = 1'b0;
        sstatus_write = 1'b0;
        retire_state_dirty = 1'b0;
        retire_fflags_valid = 1'b0;
        retire_fflags = 5'd0;

        repeat (2) tick();
        rst_n = 1'b1;
        tick();

        if (!csr_selected || csr_valid || state_enabled ||
            (state_value != `RV64_MSTATUS_FS_OFF) ||
            (misa_bits != ((64'd1 << 5) | (64'd1 << 3))))
            $fatal(1, "FPU CSR reset or misa contribution was wrong");

        write_status(1'b0, `RV64_MSTATUS_FS_INITIAL);
        if (!state_enabled || !csr_valid || (csr_rdata != 64'd0))
            $fatal(1, "mstatus did not enable clean FPU CSR state");

        write_fcsr(`RV64_FP_CSR_FCSR,
                   {56'd0, `RV64_FP_RM_RDN, 5'b1_0101});
        if ((frm != `RV64_FP_RM_RDN) || (fflags != 5'b1_0101) ||
            (state_value != `RV64_MSTATUS_FS_DIRTY) ||
            !mstatus_bits[`RV64_MSTATUS_SD_BIT] ||
            !sstatus_bits[`RV64_MSTATUS_SD_BIT])
            $fatal(1, "FCSR write did not update FPU-owned state");

        retire_fflags_valid = 1'b1;
        retire_fflags = `RV64_FP_FFLAG_UF | `RV64_FP_FFLAG_NX;
        tick();
        retire_fflags_valid = 1'b0;
        if (fflags != 5'b1_0111)
            $fatal(1, "retired FPU flags did not accrue");

        write_status(1'b1, `RV64_MSTATUS_FS_CLEAN);
        if ((state_value != `RV64_MSTATUS_FS_CLEAN) ||
            mstatus_bits[`RV64_MSTATUS_SD_BIT])
            $fatal(1, "sstatus did not clean FPU state");

        retire_state_dirty = 1'b1;
        tick();
        retire_state_dirty = 1'b0;
        if (state_value != `RV64_MSTATUS_FS_DIRTY)
            $fatal(1, "retired FPR write did not dirty FPU state");

        write_status(1'b0, `RV64_MSTATUS_FS_OFF);
        if (csr_valid || state_enabled || (csr_rdata != 64'd0))
            $fatal(1, "FS Off did not disable FPU CSR access");

        $display("PASS: FPU-owned CSR state and generic status/misa overlays");
        $finish;
    end
endmodule
