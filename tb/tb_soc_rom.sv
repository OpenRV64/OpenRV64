`timescale 1ns/1ps

module tb_soc_rom;

    localparam integer ROM_BYTES = 64 * 1024;

    logic        mem_valid;
    logic        mem_ready;
    logic        mem_write;
    logic [63:0] mem_addr;
    logic [63:0] mem_wdata;
    logic [7:0]  mem_wstrb;
    logic [63:0] mem_rdata;

    openrv64_soc_rom #(
        .ROM_BYTES(ROM_BYTES)
    ) dut (
        .mem_valid_i(mem_valid),
        .mem_ready_o(mem_ready),
        .mem_write_i(mem_write),
        .mem_addr_i(mem_addr),
        .mem_wdata_i(mem_wdata),
        .mem_wstrb_i(mem_wstrb),
        .mem_rdata_o(mem_rdata)
    );

    task automatic expect_read;
        input logic [63:0] address;
        input logic [63:0] expected;
        input [8*56-1:0] label;
        begin
            mem_valid = 1'b1;
            mem_write = 1'b0;
            mem_addr = address;
            #1;
            if (!mem_ready || mem_rdata !== expected) begin
                $fatal(1, "%0s: read %016x, expected %016x",
                       label, mem_rdata, expected);
            end
            mem_valid = 1'b0;
            #1;
        end
    endtask

    initial begin
        mem_valid = 1'b0;
        mem_write = 1'b0;
        mem_addr = 64'h0;
        mem_wdata = 64'h0;
        mem_wstrb = 8'h00;

        #1;
        if (mem_ready || mem_rdata !== 64'h0) begin
            $fatal(1, "idle ROM produced a response");
        end

        expect_read(64'h0, 64'h01f0_9093_0010_0093,
                    "LI and SLLI boot instructions");
        expect_read(64'h4, 64'h01f0_9093_0010_0093,
                    "upper instruction uses containing word");
        expect_read(64'h8, 64'h0000_0000_0000_8067,
                    "JR boot instruction");
        expect_read(64'h10, 64'h0, "unused ROM is zero");
        expect_read(ROM_BYTES - 8, 64'h0, "final ROM word is zero");

        mem_valid = 1'b1;
        mem_write = 1'b1;
        mem_addr = 64'h0;
        mem_wdata = 64'hffff_ffff_ffff_ffff;
        mem_wstrb = 8'hff;
        #1;
        if (!mem_ready || mem_rdata !== 64'h0) begin
            $fatal(1, "ROM write response invalid");
        end
        mem_valid = 1'b0;
        #1;
        expect_read(64'h0, 64'h01f0_9093_0010_0093,
                    "ROM write was ignored");

        expect_read(ROM_BYTES, 64'h0, "out-of-range local request");

        $display("tb_soc_rom: PASS");
        $finish;
    end

endmodule
