`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/isa/rv64-i.v"

module tb_reg_map_3p;

    reg clk;
    reg rst_n;
    reg clear;
    reg [2:0] candidate_valid;
    reg [2:0] uses_rs1;
    reg [2:0] uses_rs2;
    reg [14:0] rs1_addr;
    reg [14:0] rs2_addr;
    reg [2:0] reg_write;
    reg [14:0] rd_addr;
    reg [5:0] candidate_pipe;
    reg [1:0] forward_valid;
    reg [9:0] forward_rd_addr;
    wire [2:0] hazard_free;
    wire [2:0] raw_hazard;
    wire [2:0] waw_hazard;
    wire [2:0] read_port_hazard;
    reg [2:0] allocation_fire;
    reg [2:0] retire_valid;
    reg [2:0] retire_reg_write;
    reg [14:0] retire_rd_addr;
    wire [31:0] write_busy;

    openrv64_dispatch_reg_map_3p #(
        .MAX_READS_PER_REG(2)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .clear_i(clear),
        .candidate_valid_i(candidate_valid),
        .candidate_uses_rs1_i(uses_rs1),
        .candidate_uses_rs2_i(uses_rs2),
        .candidate_rs1_addr_i(rs1_addr),
        .candidate_rs2_addr_i(rs2_addr),
        .candidate_reg_write_i(reg_write),
        .candidate_rd_addr_i(rd_addr),
        .candidate_pipe_i(candidate_pipe),
        .forward_valid_i(forward_valid),
        .forward_rd_addr_i(forward_rd_addr),
        .candidate_hazard_free_o(hazard_free),
        .raw_hazard_o(raw_hazard),
        .waw_hazard_o(waw_hazard),
        .read_port_hazard_o(read_port_hazard),
        .allocation_fire_i(allocation_fire),
        .retire_valid_i(retire_valid),
        .retire_reg_write_i(retire_reg_write),
        .retire_rd_addr_i(retire_rd_addr),
        .write_busy_o(write_busy)
    );

    always #5 clk = ~clk;

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic clear_inputs;
        begin
            candidate_valid = 3'b000;
            uses_rs1 = 3'b000;
            uses_rs2 = 3'b000;
            rs1_addr = 15'd0;
            rs2_addr = 15'd0;
            reg_write = 3'b000;
            rd_addr = 15'd0;
            candidate_pipe = {
                `OPENRV64_EXEC_PIPE_EX0,
                `OPENRV64_EXEC_PIPE_EX0,
                `OPENRV64_EXEC_PIPE_EX0
            };
            forward_valid = 2'b00;
            forward_rd_addr = 10'd0;
            allocation_fire = 3'b000;
            retire_valid = 3'b000;
            retire_reg_write = 3'b000;
            retire_rd_addr = 15'd0;
        end
    endtask

    task automatic fail;
        input [8*96-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        clear = 1'b0;
        clear_inputs();
        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        candidate_valid = 3'b001;
        reg_write = 3'b001;
        rd_addr[0 +: 5] = 5'd5;
        #1;
        if (!hazard_free[0]) fail("initial x5 writer was blocked");
        allocation_fire = 3'b001;
        tick();
        clear_inputs();
        if (!write_busy[5]) fail("x5 ownership was not allocated");

        candidate_valid = 3'b001;
        uses_rs1 = 3'b001;
        rs1_addr[0 +: 5] = 5'd5;
        #1;
        if (!raw_hazard[0] || hazard_free[0])
            fail("consumer issued while x5 writer remained outstanding");

        // A completion from a different pipe does not release the RAW.  The
        // same metadata does release it once dispatch selects the owner pipe.
        forward_valid = 2'b01;
        forward_rd_addr[0 +: 5] = 5'd5;
        candidate_pipe[0 +: 2] = `OPENRV64_EXEC_PIPE_EX1;
        #1;
        if (!raw_hazard[0] || hazard_free[0])
            fail("cross-pipe completion incorrectly released RAW");
        candidate_pipe[0 +: 2] = `OPENRV64_EXEC_PIPE_EX0;
        #1;
        if (raw_hazard[0] || !hazard_free[0])
            fail("same-pipe completion did not release RAW");
        forward_valid = 2'b00;
        forward_rd_addr = 10'd0;

        // Retirement release and GPR bypass permit same-cycle reuse.
        retire_valid = 3'b001;
        retire_reg_write = 3'b001;
        retire_rd_addr[0 +: 5] = 5'd5;
        #1;
        if (!hazard_free[0])
            fail("same-cycle retirement did not release x5 ownership");
        tick();
        clear_inputs();
        if (write_busy[5]) fail("x5 ownership did not retire");

        // A writer in candidate zero blocks its same-bundle consumer and all
        // still-younger candidates through prefix issue.
        candidate_valid = 3'b111;
        reg_write[0] = 1'b1;
        rd_addr[0 +: 5] = 5'd6;
        uses_rs1[1] = 1'b1;
        rs1_addr[1*5 +: 5] = 5'd6;
        forward_valid = 2'b01;
        forward_rd_addr[0 +: 5] = 5'd6;
        #1;
        if ((hazard_free != 3'b001) || !raw_hazard[1])
            fail("same-bundle RAW did not terminate allocation prefix");

        clear_inputs();
        candidate_valid = 3'b011;
        reg_write = 3'b011;
        rd_addr[0 +: 5] = 5'd8;
        rd_addr[1*5 +: 5] = 5'd8;
        #1;
        if ((hazard_free != 3'b001) || !waw_hazard[1])
            fail("same-bundle WAW was not rejected");

        // Two selectors may read one physical register; a third selector in
        // the same issue bundle stalls at its candidate.
        clear_inputs();
        candidate_valid = 3'b011;
        uses_rs1 = 3'b011;
        uses_rs2[0] = 1'b1;
        rs1_addr[0 +: 5] = 5'd10;
        rs2_addr[0 +: 5] = 5'd10;
        rs1_addr[1*5 +: 5] = 5'd10;
        #1;
        if (!hazard_free[0] || hazard_free[1] || !read_port_hazard[1])
            fail("two-read physical-register limit was not enforced");

        clear_inputs();
        candidate_valid = 3'b111;
        uses_rs1 = 3'b111;
        reg_write = 3'b111;
        rs1_addr = {5'd3, 5'd2, 5'd1};
        rd_addr = {5'd13, 5'd12, 5'd11};
        #1;
        if (hazard_free != 3'b111)
            fail("independent three-wide bundle was restricted");
        allocation_fire = 3'b111;
        tick();
        if (!write_busy[11] || !write_busy[12] || !write_busy[13])
            fail("three ownership bits were not allocated together");

        $display("PASS: 3p busy ownership, bundle hazards, and two-read limit");
        $finish;
    end

endmodule
