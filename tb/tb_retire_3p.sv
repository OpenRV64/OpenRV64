`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/except/except-defs.v"

module tb_retire_3p;

    localparam integer META_WIDTH = `OPENRV64_RETIRE_ALLOC_WIDTH;
    localparam integer RESULT_WIDTH = `OPENRV64_RETIRE_RESULT_WIDTH;

    reg [2:0] queue_valid;
    reg [3*META_WIDTH-1:0] queue_meta;
    reg [3*RESULT_WIDTH-1:0] queue_result;
    reg [191:0] queue_trace;
    wire [2:0] queue_accept;
    reg irq_pending;
    reg [`RV64_EXCEPT_CAUSE_WIDTH-1:0] irq_cause;
    reg csr_write_ready;
    wire [2:0] retire_arch;
    wire [1:0] retire_count;
    wire [2:0] retire_hard;
    wire [2:0] release_valid;
    wire [2:0] release_uses_rs1;
    wire [2:0] release_uses_rs2;
    wire [14:0] release_rs1_addr;
    wire [14:0] release_rs2_addr;
    wire [2:0] release_reg_write;
    wire [14:0] release_rd_addr;
    wire [2:0] gpr_write;
    wire [3*`OPENRV64_PHYS_REG_ADDR_WIDTH-1:0] gpr_rd_addr;
    wire [191:0] gpr_rd_data;
    wire csr_write;
    wire [11:0] csr_addr;
    wire [63:0] csr_wdata;
    wire exception;
    wire halt;
    wire irq;
    wire mret;
    wire sret;
    wire fence_i;
    wire sfence_vma;
    wire [`RV64_EXCEPT_CAUSE_WIDTH-1:0] cause;
    wire [63:0] pc;
    wire [63:0] next_pc;
    wire [63:0] tval;
    wire [63:0] trace_id;
    wire [31:0] instr;
    wire [4:0] trace_rd;
    wire [63:0] trace_wdata;

    openrv64_retire_3p dut (
        .queue_valid_i(queue_valid),
        .queue_meta_i(queue_meta),
        .queue_result_i(queue_result),
        .queue_trace_id_i(queue_trace),
        .queue_accept_o(queue_accept),
        .csr_write_ready_i(csr_write_ready),
        .irq_pending_i(irq_pending),
        .irq_cause_i(irq_cause),
        .retire_arch_o(retire_arch),
        .retire_count_o(retire_count),
        .retire_hard_o(retire_hard),
        .release_valid_o(release_valid),
        .release_uses_rs1_o(release_uses_rs1),
        .release_uses_rs2_o(release_uses_rs2),
        .release_rs1_addr_o(release_rs1_addr),
        .release_rs2_addr_o(release_rs2_addr),
        .release_reg_write_o(release_reg_write),
        .release_rd_addr_o(release_rd_addr),
        .gpr_write_o(gpr_write),
        .gpr_rd_addr_o(gpr_rd_addr),
        .gpr_rd_data_o(gpr_rd_data),
        .csr_write_o(csr_write),
        .csr_addr_o(csr_addr),
        .csr_wdata_o(csr_wdata),
        .exception_o(exception),
        .halt_o(halt),
        .irq_o(irq),
        .mret_o(mret),
        .sret_o(sret),
        .fence_i_o(fence_i),
        .sfence_vma_o(sfence_vma),
        .cause_o(cause),
        .pc_o(pc),
        .next_pc_o(next_pc),
        .tval_o(tval),
        .trace_id_o(trace_id),
        .instr_o(instr),
        .trace_rd_o(trace_rd),
        .trace_wdata_o(trace_wdata)
    );

    task automatic fail;
        input [8*96-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    task automatic set_meta;
        input integer lane;
        input hard_order;
        input uses1;
        input uses2;
        input reg_write;
        input [4:0] rd;
        reg [META_WIDTH-1:0] value;
        begin
            value = {META_WIDTH{1'b0}};
            value[`OPENRV64_RETIRE_ALLOC_HARD_BIT] = hard_order;
            value[`OPENRV64_RETIRE_ALLOC_USES_RS2_BIT] = uses2;
            value[`OPENRV64_RETIRE_ALLOC_USES_RS1_BIT] = uses1;
            value[`OPENRV64_RETIRE_ALLOC_NEW_PHYS_LSB +:
                  `OPENRV64_PHYS_REG_ADDR_WIDTH] =
                {{(`OPENRV64_PHYS_REG_ADDR_WIDTH-5){1'b0}}, rd};
            value[`OPENRV64_RETIRE_ALLOC_NEW_PHYS_LSB +
                  `OPENRV64_PHYS_REG_ADDR_WIDTH +:
                  `OPENRV64_PHYS_REG_ADDR_WIDTH] =
                {{(`OPENRV64_PHYS_REG_ADDR_WIDTH-5){1'b0}}, rd};
            value[`OPENRV64_RETIRE_ALLOC_REG_WRITE_BIT] = reg_write;
            value[`OPENRV64_RETIRE_ALLOC_RD_LSB +: 5] = rd;
            queue_meta[lane*META_WIDTH +: META_WIDTH] = value;
        end
    endtask

    task automatic set_result;
        input integer lane;
        input [63:0] trace;
        input [63:0] pc_value;
        input [63:0] next_pc_value;
        input [31:0] instr_value;
        input [63:0] data;
        input [4:0] rs1;
        input [4:0] rs2;
        input [4:0] rd;
        input reg_write;
        input exception_value;
        input halt_value;
        input [`RV64_EXCEPT_CAUSE_WIDTH-1:0] cause_value;
        input [63:0] tval_value;
        input csr_write_value;
        input [11:0] csr_addr_value;
        input [63:0] csr_data_value;
        reg [RESULT_WIDTH-1:0] value;
        begin
            value = {RESULT_WIDTH{1'b0}};
            value[0 +: 64] = csr_data_value;
            value[64 +: 12] = csr_addr_value;
            value[76] = csr_write_value;
            value[79 +: 64] = tval_value;
            value[143 +: `RV64_EXCEPT_CAUSE_WIDTH] = cause_value;
            value[148] = halt_value;
            value[149] = exception_value;
            value[`OPENRV64_RETIRE_RESULT_DATA_LSB +: 64] = data;
            value[`OPENRV64_RETIRE_RESULT_NEXT_PC_LSB +: 64] =
                next_pc_value;
            queue_result[lane*RESULT_WIDTH +: RESULT_WIDTH] = value;
            queue_meta[
                lane*META_WIDTH + `OPENRV64_RETIRE_ALLOC_PC_LSB +: 64] =
                pc_value;
            queue_meta[
                lane*META_WIDTH + `OPENRV64_RETIRE_ALLOC_INSTR_LSB +: 32] =
                instr_value;
            queue_meta[
                lane*META_WIDTH + `OPENRV64_RETIRE_ALLOC_RS1_LSB +: 5] =
                rs1;
            queue_meta[
                lane*META_WIDTH + `OPENRV64_RETIRE_ALLOC_RS2_LSB +: 5] =
                rs2;
            queue_meta[
                lane*META_WIDTH + `OPENRV64_RETIRE_ALLOC_RD_LSB +: 5] = rd;
            queue_meta[
                lane*META_WIDTH +
                `OPENRV64_RETIRE_ALLOC_REG_WRITE_BIT] = reg_write;
            queue_trace[lane*64 +: 64] = trace;
        end
    endtask

    initial begin
        queue_valid = 3'b000;
        queue_meta = {3*META_WIDTH{1'b0}};
        queue_result = {3*RESULT_WIDTH{1'b0}};
        queue_trace = 192'd0;
        irq_pending = 1'b0;
        irq_cause = 5'd0;
        csr_write_ready = 1'b1;

        set_meta(0, 0, 1, 0, 1, 5'd5);
        set_meta(1, 0, 1, 1, 1, 5'd6);
        set_meta(2, 0, 0, 0, 1, 5'd7);
        // The physical destination is allocation-time state.  Deliberately
        // make it differ from architectural rd to catch re-derivation here.
        queue_meta[1*META_WIDTH + `OPENRV64_RETIRE_ALLOC_NEW_PHYS_LSB +:
                   `OPENRV64_PHYS_REG_ADDR_WIDTH] = 5'd30;
        set_result(0, 64'd10, 64'h100, 64'h104, 32'h1,
                   64'h55, 5'd1, 5'd0, 5'd5, 1, 0, 0, 5'd0, 0, 0, 0, 0);
        set_result(1, 64'd11, 64'h104, 64'h108, 32'h2,
                   64'h66, 5'd2, 5'd3, 5'd6, 1, 0, 0, 5'd0, 0, 0, 0, 0);
        set_result(2, 64'd12, 64'h108, 64'h10c, 32'h3,
                   64'h77, 5'd0, 5'd0, 5'd7, 1, 0, 0, 5'd0, 0, 0, 0, 0);
        queue_valid = 3'b111;
        #1;
        if ((queue_accept != 3'b111) || (retire_arch != 3'b111) ||
            (retire_count != 2'd3) || (gpr_write != 3'b111)) begin
            fail("three normal instructions did not retire together");
        end
        if ((gpr_rd_data[0*64 +: 64] != 64'h55) ||
            (gpr_rd_data[1*64 +: 64] != 64'h66) ||
            (gpr_rd_data[2*64 +: 64] != 64'h77)) begin
            fail("three retirement write values were reordered");
        end
        if ((gpr_rd_addr[0*`OPENRV64_PHYS_REG_ADDR_WIDTH +:
                           `OPENRV64_PHYS_REG_ADDR_WIDTH] != 6'd5) ||
            (gpr_rd_addr[1*`OPENRV64_PHYS_REG_ADDR_WIDTH +:
                           `OPENRV64_PHYS_REG_ADDR_WIDTH] != 5'd30) ||
            (gpr_rd_addr[2*`OPENRV64_PHYS_REG_ADDR_WIDTH +:
                           `OPENRV64_PHYS_REG_ADDR_WIDTH] != 6'd7)) begin
            fail("retirement did not use captured physical destinations");
        end

        // Exception in position one commits position zero, consumes the fault,
        // and leaves position two for the subsequent squash.
        queue_result[1*RESULT_WIDTH + 149] = 1'b1;
        queue_result[1*RESULT_WIDTH + 143 +: 5] =
            `RV64_EXCEPT_CAUSE_ILLEGAL_INSTR;
        queue_result[1*RESULT_WIDTH + 79 +: 64] = 64'hbad;
        #1;
        if ((queue_accept != 3'b011) || (retire_arch != 3'b001) ||
            (gpr_write != 3'b001) || !exception) begin
            fail("exception did not terminate retirement after older commit");
        end
        if ((cause != `RV64_EXCEPT_CAUSE_ILLEGAL_INSTR) ||
            (pc != 64'h104) || (tval != 64'hbad)) begin
            fail("exception context selected wrong retirement entry");
        end
        if ((release_valid != 3'b011) ||
            (release_reg_write != 3'b011)) begin
            fail("exception entry did not release its ownership");
        end

        // Restore lane one and mark it hard.  The hard instruction retires but
        // terminates the group even though lane two is ready.
        queue_result[1*RESULT_WIDTH + 149] = 1'b0;
        queue_meta[
            1*META_WIDTH + `OPENRV64_RETIRE_ALLOC_HARD_BIT] = 1'b1;
        #1;
        if ((queue_accept != 3'b011) || (retire_arch != 3'b011) ||
            (retire_hard != 3'b010)) begin
            fail("hard-order retirement did not terminate ready prefix");
        end

        // IRQ is taken after the youngest normal instruction accepted in the
        // group, not after the oldest lane.
        queue_meta[
            1*META_WIDTH + `OPENRV64_RETIRE_ALLOC_HARD_BIT] = 1'b0;
        irq_pending = 1'b1;
        irq_cause = 5'd11;
        #1;
        if (!irq || exception || (next_pc != 64'h10c) ||
            (cause != 5'd11) || (trace_id != 64'd12)) begin
            fail("IRQ boundary did not follow last three-wide retirement");
        end

        irq_pending = 1'b0;
        queue_valid = 3'b001;
        queue_result[0*RESULT_WIDTH + 76] = 1'b1;
        queue_result[0*RESULT_WIDTH + 64 +: 12] = 12'h305;
        queue_result[0*RESULT_WIDTH + 0 +: 64] = 64'h1234;
        csr_write_ready = 1'b0;
        #1;
        if (!csr_write || (csr_addr != 12'h305) ||
            (csr_wdata != 64'h1234)) begin
            fail("retirement did not hold CSR write request");
        end
        if ((queue_accept != 3'b000) || (retire_arch != 3'b000) ||
            (gpr_write != 3'b000)) begin
            fail("unready CSR write retired before completion");
        end
        csr_write_ready = 1'b1;
        #1;
        if ((queue_accept != 3'b001) || (retire_arch != 3'b001) ||
            !csr_write) begin
            fail("ready CSR write did not retire");
        end

        $display("PASS: 3p commit prefix, exception boundary, IRQ, and held CSR request");
        $finish;
    end

    wire unused = |{
        release_uses_rs1,
        release_uses_rs2,
        release_rs1_addr,
        release_rs2_addr,
        release_rd_addr,
        gpr_rd_addr,
        halt,
        mret,
        sret,
        fence_i,
        sfence_vma,
        instr,
        trace_rd,
        trace_wdata
    };

endmodule
