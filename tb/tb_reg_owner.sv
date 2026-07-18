`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

module tb_reg_owner;

    logic clk;
    logic rst_n;
    logic clear;
    logic alloc_valid;
    logic alloc_fire;
    logic alloc_uses_rs1;
    logic alloc_uses_rs2;
    logic [4:0] alloc_rs1_addr;
    logic [4:0] alloc_rs2_addr;
    logic alloc_reg_write;
    logic [4:0] alloc_rd_addr;
    logic [31:0] forward_ex_write_hot;
    logic [31:0] forward_mem_write_hot;
    logic retire_valid;
    logic retire_uses_rs1;
    logic retire_uses_rs2;
    logic [4:0] retire_rs1_addr;
    logic [4:0] retire_rs2_addr;
    logic retire_reg_write;
    logic [4:0] retire_rd_addr;
    logic rollback_valid;
    logic rollback_uses_rs1;
    logic rollback_uses_rs2;
    logic [4:0] rollback_rs1_addr;
    logic [4:0] rollback_rs2_addr;
    logic rollback_reg_write;
    logic [4:0] rollback_rd_addr;
    logic [31:0] alloc_read_hot;
    logic raw_hazard;
    logic war_hazard;
    logic waw_hazard;
    logic read_full_hazard;
    logic can_allocate;

    openrv64_dispatch_reg_map #(
        .ENABLE_FORWARDING(1)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .clear_i(clear),
        .alloc_valid_i(alloc_valid),
        .alloc_fire_i(alloc_fire),
        .alloc_uses_rs1_i(alloc_uses_rs1),
        .alloc_uses_rs2_i(alloc_uses_rs2),
        .alloc_rs1_addr_i(alloc_rs1_addr),
        .alloc_rs2_addr_i(alloc_rs2_addr),
        .alloc_reg_write_i(alloc_reg_write),
        .alloc_rd_addr_i(alloc_rd_addr),
        .alloc_read_hot_i(32'h0),
        .forward_ex_write_hot_i(forward_ex_write_hot),
        .forward_mem_write_hot_i(forward_mem_write_hot),
        .alloc_read_hot_o(alloc_read_hot),
        .retire_valid_i(retire_valid),
        .retire_uses_rs1_i(retire_uses_rs1),
        .retire_uses_rs2_i(retire_uses_rs2),
        .retire_rs1_addr_i(retire_rs1_addr),
        .retire_rs2_addr_i(retire_rs2_addr),
        .retire_reg_write_i(retire_reg_write),
        .retire_rd_addr_i(retire_rd_addr),
        .rollback_valid_i(rollback_valid),
        .rollback_uses_rs1_i(rollback_uses_rs1),
        .rollback_uses_rs2_i(rollback_uses_rs2),
        .rollback_rs1_addr_i(rollback_rs1_addr),
        .rollback_rs2_addr_i(rollback_rs2_addr),
        .rollback_reg_write_i(rollback_reg_write),
        .rollback_rd_addr_i(rollback_rd_addr),
        .raw_hazard_o(raw_hazard),
        .war_hazard_o(war_hazard),
        .waw_hazard_o(waw_hazard),
        .read_full_hazard_o(read_full_hazard),
        .can_allocate_o(can_allocate)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic clear_inputs;
        begin
            clear = 1'b0;
            alloc_valid = 1'b0;
            alloc_fire = 1'b0;
            alloc_uses_rs1 = 1'b0;
            alloc_uses_rs2 = 1'b0;
            alloc_rs1_addr = 5'd0;
            alloc_rs2_addr = 5'd0;
            alloc_reg_write = 1'b0;
            alloc_rd_addr = 5'd0;
            forward_ex_write_hot = 32'h0;
            forward_mem_write_hot = 32'h0;
            retire_valid = 1'b0;
            retire_uses_rs1 = 1'b0;
            retire_uses_rs2 = 1'b0;
            retire_rs1_addr = 5'd0;
            retire_rs2_addr = 5'd0;
            retire_reg_write = 1'b0;
            retire_rd_addr = 5'd0;
            rollback_valid = 1'b0;
            rollback_uses_rs1 = 1'b0;
            rollback_uses_rs2 = 1'b0;
            rollback_rs1_addr = 5'd0;
            rollback_rs2_addr = 5'd0;
            rollback_reg_write = 1'b0;
            rollback_rd_addr = 5'd0;
        end
    endtask

    task automatic allocate_writer;
        input logic [4:0] rd;
        begin
            @(negedge clk);
            clear_inputs();
            alloc_valid = 1'b1;
            alloc_fire = 1'b1;
            alloc_reg_write = 1'b1;
            alloc_rd_addr = rd;
            @(posedge clk);
            #1;
            clear_inputs();
        end
    endtask

    task automatic drive_reader;
        input logic [4:0] rs1;
        begin
            alloc_valid = 1'b1;
            alloc_uses_rs1 = 1'b1;
            alloc_rs1_addr = rs1;
        end
    endtask

    task automatic expect_raw;
        input logic expected;
        input [8*56-1:0] label;
        begin
            #1;
            if ((raw_hazard !== expected) ||
                (can_allocate !== !expected)) begin
                $fatal(1, "%0s: raw=%b can_allocate=%b",
                       label, raw_hazard, can_allocate);
            end
        end
    endtask

    initial begin
        clear_inputs();
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        allocate_writer(5'd5);

        drive_reader(5'd5);
        expect_raw(1'b1, "unmarked sole writer stalls");

        forward_ex_write_hot = 32'h1 << 5;
        expect_raw(1'b0, "sole EX owner forwards");

        forward_mem_write_hot = 32'h1 << 5;
        expect_raw(1'b1, "colliding EX and MEM marks stall");

        clear_inputs();
        allocate_writer(5'd5);

        drive_reader(5'd5);
        forward_ex_write_hot = 32'h1 << 5;
        expect_raw(1'b1, "one of two owners cannot forward");

        forward_mem_write_hot = 32'h1 << 5;
        expect_raw(1'b1, "two marked owners still collide");

        // Same-cycle retirement leaves exactly one owner. Its unique EX mark
        // may then release the consumer without an extra bubble.
        forward_mem_write_hot = 32'h0;
        retire_valid = 1'b1;
        retire_reg_write = 1'b1;
        retire_rd_addr = 5'd5;
        expect_raw(1'b0, "retirement exposes sole EX owner");
        @(posedge clk);
        #1;
        retire_valid = 1'b0;
        retire_reg_write = 1'b0;
        expect_raw(1'b0, "sole remaining EX owner forwards");

        // Once the final writer retires, no forwarding mark is required.
        forward_ex_write_hot = 32'h0;
        retire_valid = 1'b1;
        retire_reg_write = 1'b1;
        retire_rd_addr = 5'd5;
        expect_raw(1'b0, "final retirement clears ownership");

        $display("PASS: unique one-hot register ownership gates forwarding");
        $finish;
    end

endmodule
