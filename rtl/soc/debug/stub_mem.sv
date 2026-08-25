// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// FPGA-only executable M-mode debug workspace. Port A is a blocking CPU MMIO
// port and supports byte writes. Port B is a full-word USER1 JTAG upload and
// readback port paced through a request/acknowledgement toggle pair.
//
// The host must not modify the array while the CPU is executing from it. The
// software protocol reserves the final two words for a descriptor and writes
// its magic word last, making a partially uploaded image non-executable.

`timescale 1ns/1ps

module openrv64_soc_debug_retire_trace_mem (
    input  logic        clk_i,
    input  logic        write_i,
    input  logic [7:0]  write_addr_i,
    input  logic [63:0] write_data_i,
    input  logic        read_i,
    input  logic [7:0]  read_addr_i,
    output logic [63:0] read_data_o
);

    // Keep the memory in a conventional, resetless 1R1W synchronous shape.
    // This boundary is intentional: folding its read into the debug-stub
    // response mux prevents Yosys from finding a valid XC7 BRAM mapping.
    (* ram_style = "block" *) logic [63:0] mem_q [0:255];

    always_ff @(posedge clk_i) begin
        if (write_i)
            mem_q[write_addr_i] <= write_data_i;
        if (read_i)
            read_data_o <= mem_q[read_addr_i];
    end

endmodule

module openrv64_soc_debug_stub_mem #(
    parameter integer WORDS = 2048
) (
    input  logic         clk_i,
    input  logic         rst_ni,

    input  logic         mem_valid_i,
    output logic         mem_ready_o,
    input  logic         mem_write_i,
    input  logic         cpu_write_enable_i,
    input  logic [13:0]  mem_addr_i,
    input  logic [63:0]  mem_wdata_i,
    input  logic [7:0]   mem_wstrb_i,
    output logic [63:0]  mem_rdata_o,

    input  logic [10:0]  jtag_index_i,
    input  logic         jtag_write_i,
    input  logic         jtag_trace_read_i,
    input  logic [63:0]  jtag_wdata_i,
    input  logic         jtag_req_toggle_i,
    output logic         jtag_ack_toggle_o,
    output logic [63:0]  jtag_rdata_o,

    // Passive, non-architectural retirement history. One packed record is
    // written per retired instruction and the ring stops as soon as the JTAG
    // trigger reaches the core clock domain. The PC identifies the
    // instruction; the truncated result is sufficient to distinguish the
    // small strcmp return values involved in FPGA bring-up.
    input  logic         trace_valid_i,
    input  logic         trace_freeze_i,
    input  logic [63:0]  trace_pc_i,
    input  logic         trace_rd_write_i,
    input  logic [4:0]   trace_rd_i,
    input  logic [63:0]  trace_wdata_i
);

    (* ram_style = "block" *) logic [63:0] stub_mem [0:WORDS-1];
    logic [7:0] retire_trace_write_q;
    logic [63:0] retire_trace_count_q;
    logic [63:0] retire_trace_read_data;
    logic jtag_result_is_trace_q;
    logic jtag_result_is_trace_meta_q;
    logic [63:0] jtag_regular_read_data_q;
    logic [63:0] jtag_trace_meta_data_q;

    logic response_pending_q;
    logic [63:0] cpu_read_data_q;

    (* ASYNC_REG = "TRUE" *) logic jtag_req_meta_q;
    (* ASYNC_REG = "TRUE" *) logic jtag_req_sync_q;
    logic jtag_req_seen_q;
    logic [10:0] jtag_index_meta_q;
    logic [10:0] jtag_index_sync_q;
    logic jtag_write_meta_q;
    logic jtag_write_sync_q;
    logic jtag_trace_read_meta_q;
    logic jtag_trace_read_sync_q;
    logic [63:0] jtag_wdata_meta_q;
    logic [63:0] jtag_wdata_sync_q;
    logic jtag_pending_q;

    integer byte_index;

    wire cpu_access_accept = mem_valid_i && !response_pending_q &&
        (mem_addr_i[13:3] < WORDS);
    wire cpu_read_accept = cpu_access_accept && !mem_write_i;
    wire cpu_write_accept = cpu_access_accept && mem_write_i &&
        cpu_write_enable_i;
    wire jtag_access_accept = !jtag_pending_q &&
        (jtag_req_sync_q != jtag_req_seen_q) &&
        (jtag_index_sync_q < WORDS);
    wire retire_trace_read = jtag_access_accept &&
        !jtag_write_sync_q && jtag_trace_read_sync_q &&
        (jtag_index_sync_q < 11'd256);

    assign mem_ready_o = response_pending_q && mem_valid_i;
    assign mem_rdata_o = cpu_read_data_q;
    assign jtag_rdata_o = jtag_result_is_trace_q ?
        (jtag_result_is_trace_meta_q ? jtag_trace_meta_data_q :
         retire_trace_read_data) : jtag_regular_read_data_q;

    openrv64_soc_debug_retire_trace_mem u_retire_trace_mem (
        .clk_i(clk_i),
        .write_i(trace_valid_i && !trace_freeze_i),
        .write_addr_i(retire_trace_write_q),
        .write_data_i({trace_pc_i[31:0], trace_rd_write_i,
                       trace_rd_i, trace_wdata_i[25:0]}),
        .read_i(retire_trace_read),
        .read_addr_i(jtag_index_sync_q[7:0]),
        .read_data_o(retire_trace_read_data)
    );

    // CPU port A. Byte write enables allow uploaded code to use this region as
    // ordinary M-mode scratch storage after entry. The platform enables writes
    // only while the JTAG-triggered M-mode interrupt remains asserted;
    // otherwise S-mode could rewrite later M-mode instructions.
    always_ff @(posedge clk_i) begin
        if (cpu_write_accept) begin
            for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1)
                if (mem_wstrb_i[byte_index])
                    stub_mem[mem_addr_i[13:3]][byte_index*8 +: 8] <=
                        mem_wdata_i[byte_index*8 +: 8];
        end
        if (cpu_read_accept)
            cpu_read_data_q <= stub_mem[mem_addr_i[13:3]];
    end

    // JTAG port B. The input bundle is held stable from request until ack.
    always_ff @(posedge clk_i) begin
        if (jtag_access_accept) begin
            jtag_result_is_trace_q <= !jtag_write_sync_q &&
                                      jtag_trace_read_sync_q;
            jtag_result_is_trace_meta_q <= 1'b0;
            if (jtag_write_sync_q) begin
                stub_mem[jtag_index_sync_q] <= jtag_wdata_sync_q;
                jtag_result_is_trace_q <= 1'b0;
            end else if (jtag_trace_read_sync_q &&
                         (jtag_index_sync_q >= 11'd256)) begin
                jtag_result_is_trace_meta_q <= 1'b1;
                if (jtag_index_sync_q == 11'd256)
                    jtag_trace_meta_data_q <= retire_trace_count_q;
                else if (jtag_index_sync_q == 11'd257)
                    jtag_trace_meta_data_q <=
                        {55'd0, trace_freeze_i, retire_trace_write_q};
                else
                    jtag_trace_meta_data_q <= 64'd0;
            end else if (!jtag_trace_read_sync_q) begin
                jtag_regular_read_data_q <= stub_mem[jtag_index_sync_q];
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            retire_trace_write_q <= 8'd0;
            retire_trace_count_q <= 64'd0;
        end else if (trace_valid_i && !trace_freeze_i) begin
            retire_trace_write_q <= retire_trace_write_q + 8'd1;
            retire_trace_count_q <= retire_trace_count_q + 64'd1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            response_pending_q <= 1'b0;
        end else begin
            if (response_pending_q) begin
                if (mem_valid_i)
                    response_pending_q <= 1'b0;
            end else if (mem_valid_i) begin
                response_pending_q <= 1'b1;
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            jtag_req_meta_q <= 1'b0;
            jtag_req_sync_q <= 1'b0;
            jtag_req_seen_q <= 1'b0;
            jtag_index_meta_q <= 11'd0;
            jtag_index_sync_q <= 11'd0;
            jtag_write_meta_q <= 1'b0;
            jtag_write_sync_q <= 1'b0;
            jtag_trace_read_meta_q <= 1'b0;
            jtag_trace_read_sync_q <= 1'b0;
            jtag_wdata_meta_q <= 64'd0;
            jtag_wdata_sync_q <= 64'd0;
            jtag_pending_q <= 1'b0;
            jtag_ack_toggle_o <= 1'b0;
        end else begin
            jtag_req_meta_q <= jtag_req_toggle_i;
            jtag_req_sync_q <= jtag_req_meta_q;
            jtag_index_meta_q <= jtag_index_i;
            jtag_index_sync_q <= jtag_index_meta_q;
            jtag_write_meta_q <= jtag_write_i;
            jtag_write_sync_q <= jtag_write_meta_q;
            jtag_trace_read_meta_q <= jtag_trace_read_i;
            jtag_trace_read_sync_q <= jtag_trace_read_meta_q;
            jtag_wdata_meta_q <= jtag_wdata_i;
            jtag_wdata_sync_q <= jtag_wdata_meta_q;

            if (jtag_access_accept) begin
                jtag_req_seen_q <= jtag_req_sync_q;
                jtag_pending_q <= 1'b1;
            end else if (jtag_pending_q) begin
                jtag_pending_q <= 1'b0;
                jtag_ack_toggle_o <= jtag_req_seen_q;
            end
        end
    end

endmodule
