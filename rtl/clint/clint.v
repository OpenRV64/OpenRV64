`timescale 1ns/1ps

module openrv64_clint #(
    parameter integer NUM_HARTS = 1
) (
    input  wire                   clk_i,
    input  wire                   rst_ni,
    input  wire                   mtime_tick_i,

    // Target-local side of the OpenRV64 blocking memory bus. The SoC decoder
    // removes the global CLINT base and presents offsets in mem_addr_i.
    input  wire                   mem_valid_i,
    output wire                   mem_ready_o,
    input  wire                   mem_write_i,
    input  wire [63:0]            mem_addr_i,
    input  wire [63:0]            mem_wdata_i,
    input  wire [7:0]             mem_wstrb_i,
    output reg  [63:0]            mem_rdata_o,

    output wire [NUM_HARTS-1:0]   msip_o,
    output wire [NUM_HARTS-1:0]   mtip_o,
    output wire [63:0]            mtime_o
);

    // SiFive CLINT-compatible unified register map. ACLINT describes the
    // same layout as adjacent MSWI and MTIMER regions.
    localparam [63:0] MSIP_OFFSET      = 64'h0000_0000_0000_0000;
    localparam [63:0] MTIMECMP_OFFSET  = 64'h0000_0000_0000_4000;
    localparam [63:0] MTIME_OFFSET     = 64'h0000_0000_0000_bff8;

    reg [NUM_HARTS-1:0] msip_q;
    reg [(NUM_HARTS*64)-1:0] mtimecmp_q;
    reg [63:0] mtime_q;

    wire [63:0] addr_offset = mem_addr_i;
    wire write_accept = mem_valid_i && mem_write_i;

    integer read_hart_index;
    integer write_hart_index;

    function [63:0] merge_write_data;
        input [63:0] old_value;
        input [63:0] new_value;
        input [7:0]  write_strobe;
        integer byte_index;
        begin
            merge_write_data = old_value;
            for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1) begin
                if (write_strobe[byte_index]) begin
                    merge_write_data[8*byte_index +: 8] =
                        new_value[8*byte_index +: 8];
                end
            end
        end
    endfunction

    // Global range checking belongs to openrv64_soc_bus_decode. Every request
    // delivered here is a CLINT transaction; reserved local offsets read zero
    // and ignore writes.
    assign mem_ready_o = mem_valid_i;

    assign msip_o = msip_q;
    assign mtime_o = mtime_q;

    generate
        genvar mtip_index;
        for (mtip_index = 0;
             mtip_index < NUM_HARTS;
             mtip_index = mtip_index + 1) begin : gen_mtip
            assign mtip_o[mtip_index] =
                (mtime_q >= mtimecmp_q[64*mtip_index +: 64]);
        end
    endgenerate

    always @* begin
        mem_rdata_o = 64'h0000_0000_0000_0000;

        // Two 32-bit MSIP registers can share one 64-bit bus word.
        // Only bit zero of each register is implemented.
        for (read_hart_index = 0;
             read_hart_index < NUM_HARTS;
             read_hart_index = read_hart_index + 1) begin
            if (addr_offset[63:3] ==
                ((MSIP_OFFSET + (read_hart_index * 4)) >> 3)) begin
                mem_rdata_o[(read_hart_index % 2)*32 +: 32] =
                    {31'b0, msip_q[read_hart_index]};
            end

            if (addr_offset[63:3] ==
                ((MTIMECMP_OFFSET + (read_hart_index * 8)) >> 3)) begin
                mem_rdata_o =
                    mtimecmp_q[64*read_hart_index +: 64];
            end
        end

        if (addr_offset[63:3] == (MTIME_OFFSET >> 3)) begin
            mem_rdata_o = mtime_q;
        end
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            msip_q <= {NUM_HARTS{1'b0}};
            mtime_q <= 64'h0000_0000_0000_0000;

            // The specification leaves MTIMECMP reset state unspecified.
            // All ones is deterministic and prevents a timer interrupt at
            // reset until software programs a deadline.
            mtimecmp_q <= {NUM_HARTS{64'hffff_ffff_ffff_ffff}};
        end else begin
            if (mtime_tick_i) begin
                mtime_q <= mtime_q + 64'd1;
            end

            if (write_accept) begin
                for (write_hart_index = 0;
                     write_hart_index < NUM_HARTS;
                     write_hart_index = write_hart_index + 1) begin
                    if (addr_offset[63:3] ==
                        ((MSIP_OFFSET + (write_hart_index * 4)) >> 3)) begin
                        // The implemented bit occupies the first byte of
                        // each 32-bit MSIP register. Other bits are WARL zero.
                        if (mem_wstrb_i[(write_hart_index % 2)*4]) begin
                            msip_q[write_hart_index] <=
                                mem_wdata_i[(write_hart_index % 2)*32];
                        end
                    end

                    if (addr_offset[63:3] ==
                        ((MTIMECMP_OFFSET + (write_hart_index * 8)) >> 3)) begin
                        mtimecmp_q[64*write_hart_index +: 64] <=
                            merge_write_data(
                                mtimecmp_q[64*write_hart_index +: 64],
                                mem_wdata_i,
                                mem_wstrb_i);
                    end
                end

                // A software write takes priority over a simultaneous tick.
                if (addr_offset[63:3] == (MTIME_OFFSET >> 3)) begin
                    mtime_q <= merge_write_data(mtime_q,
                                                mem_wdata_i,
                                                mem_wstrb_i);
                end
            end
        end
    end

endmodule
