`timescale 1ns/1ps
`include "core/fetch/fetch.v"
`timescale 1ns/1ps

module tb_fetch;

    logic                             clk;
    logic                             rst_n;
    logic                             flush;
    logic                             pc_ready;
    logic                             pc_valid;
    logic [`RV64_XLEN-1:0]            pc;
    logic                             mem_valid;
    logic                             mem_ready;
    logic                             mem_write;
    logic [`RV64_XLEN-1:0]            mem_addr;
    logic [`RV64_XLEN-1:0]            mem_wdata;
    logic [7:0]                       mem_wstrb;
    logic [`RV64_XLEN-1:0]            mem_rdata;
    logic                             decode_valid;
    logic                             decode_ready;
    logic [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] decode_bus;
    logic [`RV64_XLEN-1:0]            decode_pc;
    logic [`RV64_INSTR_WIDTH-1:0]     decode_instr;

    logic [`RV64_XLEN-1:0] memory [0:7];
    logic [`RV64_XLEN-1:0] pending_addr_q;
    logic                  pending_q;

    openrv64_fetch dut (
        .clk(clk),
        .rst_n(rst_n),
        .flush_i(flush),
        .pc_ready_o(pc_ready),
        .pc_valid_i(pc_valid),
        .pc_i(pc),
        .mem_valid_o(mem_valid),
        .mem_ready_i(mem_ready),
        .mem_write_o(mem_write),
        .mem_addr_o(mem_addr),
        .mem_wdata_o(mem_wdata),
        .mem_wstrb_o(mem_wstrb),
        .mem_rdata_i(mem_rdata),
        .decode_valid_o(decode_valid),
        .decode_ready_i(decode_ready),
        .decode_bus_o(decode_bus),
        .decode_pc_o(decode_pc),
        .decode_instr_o(decode_instr)
    );

    assign mem_ready = pending_q;
    assign mem_rdata = pending_q ? memory[pending_addr_q[5:3]] :
                                   {`RV64_XLEN{1'b0}};

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_q      <= 1'b0;
            pending_addr_q <= {`RV64_XLEN{1'b0}};
        end else if (pending_q) begin
            pending_q <= 1'b0;
        end else if (mem_valid) begin
            pending_q      <= 1'b1;
            pending_addr_q <= mem_addr;
        end
    end

    always @(posedge clk) begin
        if (rst_n && mem_valid) begin
            if (mem_write) begin
                $fatal(1, "fetch issued a write");
            end

            if (mem_wstrb != 8'h00) begin
                $fatal(1, "fetch write strobes nonzero: %02x", mem_wstrb);
            end

            if (mem_wdata != {`RV64_XLEN{1'b0}}) begin
                $fatal(1, "fetch write data nonzero: %016x", mem_wdata);
            end

            if (mem_addr[2:0] != 3'b000) begin
                $fatal(1, "fetch memory address not 64-bit aligned: %016x", mem_addr);
            end
        end
    end

    task automatic issue_pc;
        input [`RV64_XLEN-1:0] issue_addr;
        begin
            @(negedge clk);
            if (!pc_ready) begin
                $fatal(1, "pc not ready before issue");
            end
            pc = issue_addr;
            pc_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            pc_valid = 1'b0;
            pc = {`RV64_XLEN{1'b0}};
        end
    endtask

    task automatic expect_decode;
        input [`RV64_XLEN-1:0] exp_pc;
        input [`RV64_INSTR_WIDTH-1:0] exp_instr;
        input [8*32-1:0] label;
        begin
            wait (decode_valid);
            #1;
            if (decode_pc !== exp_pc ||
                decode_instr !== exp_instr ||
                decode_bus[`RV64_FETCH_DECODE_BUS_PC_BITS] !== exp_pc ||
                decode_bus[`RV64_FETCH_DECODE_BUS_INSTR_BITS] !== exp_instr) begin
                $fatal(1,
                    "%0s: decode pc=%016x instr=%08x bus=%024x expected pc=%016x instr=%08x",
                    label, decode_pc, decode_instr, decode_bus, exp_pc, exp_instr);
            end
        end
    endtask

    initial begin
        integer i;

        for (i = 0; i < 8; i = i + 1) begin
            memory[i] = {`RV64_XLEN{1'b0}};
        end

        memory[0] = {32'h1111_1111, 32'h2222_2222};
        memory[1] = {32'h3333_3333, 32'h4444_4444};

        rst_n = 1'b0;
        flush = 1'b0;
        pc_valid = 1'b0;
        pc = {`RV64_XLEN{1'b0}};
        decode_ready = 1'b0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        issue_pc(64'h0000_0000_0000_0000);
        expect_decode(64'h0000_0000_0000_0000, 32'h2222_2222, "lower instruction lane");

        repeat (2) @(posedge clk);
        #1;
        if (!decode_valid) begin
            $fatal(1, "decode output did not hold under backpressure");
        end

        @(negedge clk);
        decode_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        decode_ready = 1'b0;

        issue_pc(64'h0000_0000_0000_0004);
        expect_decode(64'h0000_0000_0000_0004, 32'h1111_1111, "upper instruction lane");

        @(negedge clk);
        decode_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        decode_ready = 1'b0;

        issue_pc(64'h0000_0000_0000_0008);
        expect_decode(64'h0000_0000_0000_0008, 32'h4444_4444, "next memory word");

        $display("PASS: fetch stage");
        $finish;
    end

endmodule
