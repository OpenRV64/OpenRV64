`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-zicsr.v"
`include "core/except/except-defs.v"

module tb_retire_3p_banked;
    localparam integer META_WIDTH = `OPENRV64_RETIRE_ALLOC_WIDTH;
    localparam integer RESULT_WIDTH = `OPENRV64_RETIRE_RESULT_WIDTH;
    localparam integer PHYS_WIDTH = `OPENRV64_PHYS_REG_ADDR_WIDTH;

    reg clk;
    reg rst_n;
    reg flush;
    reg [2:0] queue_valid;
    reg [3*META_WIDTH-1:0] queue_meta;
    reg [3*RESULT_WIDTH-1:0] queue_result;
    reg [191:0] queue_trace;
    reg [2:0] extension_ready;
    reg [1:0] gpr_write_valid;
    reg csr_write_ready;

    wire [2:0] queue_accept;
    wire [2:0] retire_arch;
    wire [2:0] release_valid;
    wire [1:0] gpr_write;
    wire [2*PHYS_WIDTH-1:0] gpr_addr;
    wire [127:0] gpr_data;
    wire csr_write;
    wire [11:0] csr_addr;
    wire [`RV64_FUNCT3_WIDTH-1:0] csr_op;
    wire [63:0] csr_wdata;

    openrv64_retire_3p_banked dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .queue_valid_i(queue_valid),
        .queue_meta_i(queue_meta),
        .queue_result_i(queue_result),
        .queue_trace_id_i(queue_trace),
        .queue_accept_o(queue_accept),
        .extension_ready_i(extension_ready),
        .extension_gpr_result_valid_i(3'b000),
        .extension_gpr_result_i(192'd0),
        .extension_exception_i(3'b000),
        .extension_cause_i(
            {3*`RV64_EXCEPT_CAUSE_WIDTH{1'b0}}),
        .extension_tval_i(192'd0),
        .csr_write_ready_i(csr_write_ready),
        .irq_pending_i(1'b0),
        .irq_cause_i({`RV64_EXCEPT_CAUSE_WIDTH{1'b0}}),
        .retire_arch_o(retire_arch),
        .retire_count_o(),
        .retire_hard_o(),
        .release_valid_o(release_valid),
        .release_uses_rs1_o(),
        .release_uses_rs2_o(),
        .release_rs1_addr_o(),
        .release_rs2_addr_o(),
        .release_reg_write_o(),
        .release_rd_addr_o(),
        .gpr_write_o(gpr_write),
        .gpr_rd_addr_o(gpr_addr),
        .gpr_rd_data_o(gpr_data),
        .gpr_write_ack_i(gpr_write_valid),
        .csr_write_o(csr_write),
        .csr_addr_o(csr_addr),
        .csr_op_o(csr_op),
        .csr_wdata_o(csr_wdata),
        .exception_o(),
        .halt_o(),
        .irq_o(),
        .mret_o(),
        .sret_o(),
        .fence_i_o(),
        .sfence_vma_o(),
        .cause_o(),
        .pc_o(),
        .next_pc_o(),
        .tval_o(),
        .trace_id_o(),
        .instr_o(),
        .trace_rd_o(),
        .trace_wdata_o()
    );

    always #5 clk = ~clk;

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic set_csr_lane;
        input integer lane;
        input [4:0] rd;
        input [PHYS_WIDTH-1:0] phys;
        input [63:0] read_data;
        input [11:0] address;
        input [63:0] write_data;
        reg [META_WIDTH-1:0] meta;
        reg [RESULT_WIDTH-1:0] result_value;
        begin
            meta = {META_WIDTH{1'b0}};
            result_value = {RESULT_WIDTH{1'b0}};
            meta[`OPENRV64_RETIRE_ALLOC_REG_WRITE_BIT] = 1'b1;
            meta[`OPENRV64_RETIRE_ALLOC_HARD_BIT] = 1'b1;
            meta[`OPENRV64_RETIRE_ALLOC_RD_LSB +: 5] = rd;
            meta[`OPENRV64_RETIRE_ALLOC_NEW_PHYS_LSB +:
                 PHYS_WIDTH] = phys;
            meta[`OPENRV64_RETIRE_ALLOC_INSTR_LSB + 12 +:
                 `RV64_FUNCT3_WIDTH] = `RV64_ZICSR_FUNCT3_CSRRW;
            result_value[`OPENRV64_RETIRE_RESULT_DATA_LSB +: 64] =
                read_data;
            result_value[`OPENRV64_RETIRE_RESULT_CSR_WRITE_BIT] = 1'b1;
            result_value[`OPENRV64_RETIRE_RESULT_CSR_ADDR_LSB +: 12] =
                address;
            result_value[`OPENRV64_RETIRE_RESULT_CSR_WDATA_LSB +: 64] =
                write_data;
            queue_meta[lane*META_WIDTH +: META_WIDTH] = meta;
            queue_result[lane*RESULT_WIDTH +: RESULT_WIDTH] =
                result_value;
            queue_trace[lane*64 +: 64] = lane + 16;
        end
    endtask

    task automatic fail;
        input [8*120-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $display("queue=%b ready=%b accept=%b arch=%b release=%b write=%b addr0=%0d addr1=%0d data0=%h data1=%h active=%b retire_mask=%b write_mask=%b done=%b",
                     queue_valid, extension_ready, queue_accept,
                     retire_arch, release_valid, gpr_write,
                     gpr_addr[0 +: PHYS_WIDTH],
                     gpr_addr[PHYS_WIDTH +: PHYS_WIDTH],
                     gpr_data[0 +: 64], gpr_data[64 +: 64],
                     dut.write_active_q, dut.retire_mask_q,
                     dut.write_mask_q, dut.write_done_q);
            $fatal(1);
        end
    endtask

    task automatic set_lane;
        input integer lane;
        input [4:0] rd;
        input [PHYS_WIDTH-1:0] phys;
        input [63:0] data;
        reg [META_WIDTH-1:0] meta;
        reg [RESULT_WIDTH-1:0] result_value;
        begin
            meta = {META_WIDTH{1'b0}};
            result_value = {RESULT_WIDTH{1'b0}};
            meta[`OPENRV64_RETIRE_ALLOC_REG_WRITE_BIT] = 1'b1;
            meta[`OPENRV64_RETIRE_ALLOC_RD_LSB +: 5] = rd;
            meta[`OPENRV64_RETIRE_ALLOC_NEW_PHYS_LSB +:
                 PHYS_WIDTH] = phys;
            result_value[`OPENRV64_RETIRE_RESULT_DATA_LSB +: 64] = data;
            queue_meta[lane*META_WIDTH +: META_WIDTH] = meta;
            queue_result[lane*RESULT_WIDTH +: RESULT_WIDTH] =
                result_value;
            queue_trace[lane*64 +: 64] = lane + 1;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        flush = 1'b0;
        queue_valid = 3'b000;
        queue_meta = {3*META_WIDTH{1'b0}};
        queue_result = {3*RESULT_WIDTH{1'b0}};
        queue_trace = 192'd0;
        extension_ready = 3'b111;
        gpr_write_valid = 2'b00;
        csr_write_ready = 1'b1;

        tick();
        tick();
        rst_n = 1'b1;

        // Lane 0 is ready first. Lane 1 becomes ready while lane 0's banked
        // write is still pending. It must not join the captured retire group.
        set_lane(0, 5'd10, PHYS_WIDTH'(10), 64'h1111);
        set_lane(1, 5'd12, PHYS_WIDTH'(12), 64'h029a);
        queue_valid = 3'b001;
        #1;
        if (queue_accept != 3'b000)
            fail("unacknowledged direct write retired");
        if ((gpr_write != 2'b01) ||
            (gpr_addr[0 +: PHYS_WIDTH] != PHYS_WIDTH'(10)) ||
            (gpr_data[0 +: 64] != 64'h1111))
            fail("ready head did not drive a direct write request");
        tick();

        if ((gpr_write != 2'b01) ||
            (gpr_addr[0 +: PHYS_WIDTH] != PHYS_WIDTH'(10)) ||
            (gpr_data[0 +: 64] != 64'h1111))
            fail("first captured write group is incorrect");

        queue_valid = 3'b011;
        tick();
        if (queue_accept != 3'b000)
            fail("late-ready lane retired while the first write was pending");

        gpr_write_valid = 2'b01;
        #1;
        if ((queue_accept != 3'b001) ||
            (retire_arch != 3'b001) ||
            (release_valid != 3'b001))
            fail("captured group did not retire alone after its write response");
        tick();

        // Model the retirement queue shift. The former lane 1 is now the
        // head and must create a second, independent write transaction.
        queue_meta[0 +: META_WIDTH] =
            queue_meta[1*META_WIDTH +: META_WIDTH];
        queue_result[0 +: RESULT_WIDTH] =
            queue_result[1*RESULT_WIDTH +: RESULT_WIDTH];
        queue_trace[0 +: 64] = queue_trace[64 +: 64];
        queue_valid = 3'b001;
        gpr_write_valid = 2'b00;
        tick();

        if ((gpr_write != 2'b01) ||
            (gpr_addr[0 +: PHYS_WIDTH] != PHYS_WIDTH'(12)) ||
            (gpr_data[0 +: 64] != 64'h029a))
            fail("late-ready lane did not receive a separate write group");

        gpr_write_valid = 2'b01;
        #1;
        if ((queue_accept != 3'b001) || (retire_arch != 3'b001))
            fail("second write group did not retire after its response");
        tick();

        // A fully acknowledged head must retire directly without entering the
        // retry skid.  After the queue advances, its next head may present a
        // fresh request immediately in the following cycle.
        queue_valid = 3'b000;
        queue_meta = {3*META_WIDTH{1'b0}};
        queue_result = {3*RESULT_WIDTH{1'b0}};
        queue_trace = 192'd0;
        gpr_write_valid = 2'b01;
        set_lane(0, 5'd14, PHYS_WIDTH'(14), 64'h1414);
        queue_valid = 3'b001;
        #1;
        if ((gpr_write != 2'b01) || (queue_accept != 3'b001) ||
            (retire_arch != 3'b001) || dut.write_active_q)
            fail("fully acknowledged head did not retire directly");
        tick();

        queue_meta = {3*META_WIDTH{1'b0}};
        queue_result = {3*RESULT_WIDTH{1'b0}};
        queue_trace = 192'd0;
        set_lane(0, 5'd15, PHYS_WIDTH'(15), 64'h1515);
        queue_valid = 3'b001;
        #1;
        if ((gpr_write != 2'b01) ||
            (gpr_addr[0 +: PHYS_WIDTH] != PHYS_WIDTH'(15)) ||
            (queue_accept != 3'b001) || dut.write_active_q)
            fail("next ready head did not fill the following write cycle");
        tick();

        // A side-effecting CSR may flush the backend on its completion edge.
        // Its GPR result must therefore complete first; only then may the CSR
        // request become visible and be held until ready.
        queue_valid = 3'b000;
        queue_meta = {3*META_WIDTH{1'b0}};
        queue_result = {3*RESULT_WIDTH{1'b0}};
        queue_trace = 192'd0;
        gpr_write_valid = 2'b00;
        csr_write_ready = 1'b0;
        set_csr_lane(0, 5'd13, PHYS_WIDTH'(13), 64'hface,
                     12'h3b1, 64'h1234);
        queue_valid = 3'b001;
        #1;
        if (csr_write || (queue_accept != 3'b000) ||
            (gpr_write != 2'b01))
            fail("CSR request escaped before its direct GPR write completed");
        tick();

        if (csr_write || (gpr_write != 2'b01) ||
            (gpr_addr[0 +: PHYS_WIDTH] != PHYS_WIDTH'(13)) ||
            (gpr_data[0 +: 64] != 64'hface) ||
            (queue_accept != 3'b000))
            fail("banked GPR write did not precede the CSR request");
        tick();

        gpr_write_valid = 2'b01;
        #1;
        if (csr_write || (queue_accept != 3'b000))
            fail("CSR request bypassed its registered request boundary");
        tick();
        #1;
        if (!csr_write || (csr_addr != 12'h3b1) ||
            (csr_op != `RV64_ZICSR_FUNCT3_CSRRW) ||
            (csr_wdata != 64'h1234) || (queue_accept != 3'b000))
            fail("CSR request was not exposed after the GPR response");

        gpr_write_valid = 2'b00;
        if (!csr_write || (queue_accept != 3'b000))
            fail("CSR request was not held while its target was busy");

        csr_write_ready = 1'b1;
        #1;
        if (!csr_write || (queue_accept != 3'b000))
            fail("CSR response bypassed the registered retirement boundary");
        tick();
        #1;
        if (csr_write || (queue_accept != 3'b001) ||
            (retire_arch != 3'b001))
            fail("CSR entry did not retire after its registered response");
        tick();

        // Once a CSR request is visible, a redirect discards only its queue
        // association.  The request and payload must remain stable until the
        // target returns a response.
        queue_valid = 3'b000;
        queue_meta = {3*META_WIDTH{1'b0}};
        queue_result = {3*RESULT_WIDTH{1'b0}};
        queue_trace = 192'd0;
        csr_write_ready = 1'b0;
        set_csr_lane(0, 5'd0, PHYS_WIDTH'(0), 64'd0,
                     12'h180, 64'h55aa);
        queue_valid = 3'b001;
        tick();
        #1;
        if (!csr_write || (csr_addr != 12'h180) ||
            (csr_wdata != 64'h55aa))
            fail("redirect CSR probe did not latch its request");

        flush = 1'b1;
        tick();
        queue_valid = 3'b000;
        flush = 1'b0;
        #1;
        if (!csr_write || (csr_addr != 12'h180) ||
            (csr_wdata != 64'h55aa))
            fail("redirect canceled a held CSR request");

        csr_write_ready = 1'b1;
        tick();
        csr_write_ready = 1'b0;
        #1;
        if (csr_write || dut.csr_active_q || dut.csr_done_q)
            fail("redirected CSR request did not drain as discarded");

        // A redirect may arrive with one same-bank retirement write still
        // ungranted.  The queue association is discarded, but both storage
        // requests must remain stable until their individual responses.
        queue_valid = 3'b000;
        queue_meta = {3*META_WIDTH{1'b0}};
        queue_result = {3*RESULT_WIDTH{1'b0}};
        queue_trace = 192'd0;
        gpr_write_valid = 2'b00;
        csr_write_ready = 1'b0;
        set_lane(0, 5'd10, PHYS_WIDTH'(10), 64'h1010);
        set_lane(1, 5'd12, PHYS_WIDTH'(12), 64'h1212);
        queue_valid = 3'b011;
        tick();
        if ((gpr_write != 2'b11) ||
            (gpr_addr[0 +: PHYS_WIDTH] != PHYS_WIDTH'(10)) ||
            (gpr_addr[PHYS_WIDTH +: PHYS_WIDTH] != PHYS_WIDTH'(12)))
            fail("redirect write probe did not capture both requests");

        gpr_write_valid = 2'b01;
        flush = 1'b1;
        #1;
        if (gpr_write != 2'b11)
            fail("flush canceled a write before its response edge");
        tick();
        queue_valid = 3'b000;
        flush = 1'b0;
        gpr_write_valid = 2'b00;
        #1;
        if ((gpr_write != 2'b10) ||
            (gpr_addr[PHYS_WIDTH +: PHYS_WIDTH] != PHYS_WIDTH'(12)) ||
            (gpr_data[64 +: 64] != 64'h1212))
            fail("flush did not retain the delayed retirement write");
        tick();

        gpr_write_valid = 2'b10;
        #1;
        if (gpr_write != 2'b10)
            fail("delayed retirement write was not held through response");
        tick();
        gpr_write_valid = 2'b00;
        if (gpr_write != 2'b00 || dut.write_active_q)
            fail("redirected retirement write group did not drain");

        $display("PASS: banked 3P retirement isolates late-ready lanes and holds ordered GPR/CSR transactions");
        $finish;
    end

    initial begin
        #2000;
        $fatal(1, "tb_retire_3p_banked: timeout");
    end
endmodule
