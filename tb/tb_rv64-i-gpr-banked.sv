`timescale 1ns/1ps

module tb_rv64i_gpr_banked #(
    parameter FPGA_LUTRAM = 0
);

    reg clk;
    reg rst_n;

    reg read_valid;
    reg read_clear;
    reg read_flush;
    wire read_ready;
    reg [4:0] rs1_addr;
    reg [4:0] rs2_addr;
    wire [63:0] rs1_data;
    wire [63:0] rs2_data;

    reg rd_write;
    reg rd_clear;
    wire rd_ready;
    reg [4:0] rd_addr;
    reg [63:0] rd_data;

    openrv64_rv64i_gpr_1p #(
        .BANKED(1),
        .FPGA_LUTRAM(FPGA_LUTRAM)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .read_valid_i(read_valid),
        .read_clear_i(read_clear),
        .read_flush_i(read_flush),
        .read_ready_o(read_ready),
        .rs1_addr_i(rs1_addr),
        .rs1_data_o(rs1_data),
        .rs2_addr_i(rs2_addr),
        .rs2_data_o(rs2_data),
        .rd_write_i(rd_write),
        .rd_clear_i(rd_clear),
        .rd_ready_o(rd_ready),
        .rd_addr_i(rd_addr),
        .rd_data_i(rd_data)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic write_register;
        input [4:0] address;
        input [63:0] value;
        input integer hold_cycles;
        integer cycles;
        integer held;
        begin
            @(negedge clk);
            rd_write = 1'b1;
            rd_clear = 1'b0;
            rd_addr = address;
            rd_data = value;

            cycles = 0;
            #1;
            while (!rd_ready && (cycles < 4)) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end

            if (!rd_ready)
                $fatal(1, "write response timeout for x%0d", address);

            // Model a WB owner retained after the response, as happens while
            // a slow CSR sequencer blocks retirement.
            @(posedge clk);
            #1;
            for (held = 0; held < hold_cycles; held = held + 1) begin
                if (dut.g_banked.write_req[0] !== 1'b0)
                    $fatal(1, "completed write reissued while WB was held");
                @(posedge clk);
                #1;
            end

            @(negedge clk);
            rd_clear = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            rd_write = 1'b0;
            rd_clear = 1'b0;
        end
    endtask

    task automatic read_pair;
        input [4:0] address_1;
        input [4:0] address_2;
        input [63:0] expected_1;
        input [63:0] expected_2;
        input integer expected_cycles;
        input integer hold_cycles;
        integer cycles;
        integer held;
        begin
            @(negedge clk);
            rs1_addr = address_1;
            rs2_addr = address_2;
            read_valid = 1'b1;
            read_clear = 1'b0;

            cycles = 0;
            #1;
            while (!read_ready && (cycles < 6)) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end

            if (!read_ready)
                $fatal(1, "read response timeout for x%0d/x%0d",
                       address_1, address_2);
            if (cycles != expected_cycles)
                $fatal(1,
                       "read latency mismatch for x%0d/x%0d: got %0d expected %0d",
                       address_1, address_2, cycles, expected_cycles);
            if ((rs1_data !== expected_1) || (rs2_data !== expected_2))
                $fatal(1,
                       "read mismatch for x%0d/x%0d: %016x/%016x",
                       address_1, address_2, rs1_data, rs2_data);

            for (held = 0; held < hold_cycles; held = held + 1) begin
                @(posedge clk);
                #1;
                if (!read_ready ||
                    (rs1_data !== expected_1) ||
                    (rs2_data !== expected_2)) begin
                    $fatal(1, "captured operands did not remain stable");
                end
            end

            @(negedge clk);
            read_clear = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            read_valid = 1'b0;
            read_clear = 1'b0;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        read_valid = 1'b0;
        read_clear = 1'b0;
        read_flush = 1'b0;
        rs1_addr = 5'd0;
        rs2_addr = 5'd0;
        rd_write = 1'b0;
        rd_clear = 1'b0;
        rd_addr = 5'd0;
        rd_data = 64'd0;

        repeat (3) @(posedge clk);
        #1;
        rst_n = 1'b1;

        write_register(5'd1, 64'h1111_1111_1111_1111, 0);
        write_register(5'd2, 64'h2222_2222_2222_2222, 2);
        write_register(5'd4, 64'h4444_4444_4444_4444, 0);

        if ((dut.regs[1] !== 64'h1111_1111_1111_1111) ||
            (dut.regs[2] !== 64'h2222_2222_2222_2222) ||
            (dut.regs[4] !== 64'h4444_4444_4444_4444)) begin
            $fatal(1, "architectural debug aliases do not match storage");
        end

        // Odd/even addresses use different banks and return together.
        read_pair(5'd1, 5'd2,
                  64'h1111_1111_1111_1111,
                  64'h2222_2222_2222_2222, 1, 1);

        // Two even addresses share a bank; retain the first response while
        // the other port waits for the following cycle.
        read_pair(5'd2, 5'd4,
                  64'h2222_2222_2222_2222,
                  64'h4444_4444_4444_4444, 2, 0);

        read_pair(5'd0, 5'd1,
                  64'd0, 64'h1111_1111_1111_1111, 1, 0);
        read_pair(5'd0, 5'd0, 64'd0, 64'd0, 0, 0);

        // A flush cancels an active operand owner without modifying storage.
        @(negedge clk);
        rs1_addr = 5'd2;
        rs2_addr = 5'd4;
        read_valid = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        read_flush = 1'b1;
        #1;
        if (read_ready)
            $fatal(1, "flushed read reported ready");
        @(posedge clk);
        #1;
        @(negedge clk);
        read_flush = 1'b0;
        read_valid = 1'b0;

        $display("tb_rv64i_gpr_banked: PASS");
        $finish;
    end

    initial begin
        #5000;
        $fatal(1, "tb_rv64i_gpr_banked: timeout");
    end

endmodule
