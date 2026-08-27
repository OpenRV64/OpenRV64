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

module openrv64_soc_debug_retire_trace_mem #(
    parameter integer DEPTH = 8192,
    parameter integer ADDR_WIDTH = $clog2(DEPTH)
) (
    input  logic        clk_i,
    input  logic        write_i,
    input  logic [ADDR_WIDTH-1:0] write_addr_i,
    input  logic [63:0] write_data_i,
    input  logic        read_i,
    input  logic [ADDR_WIDTH-1:0] read_addr_i,
    output logic [63:0] read_data_o
);

    // Keep the memory in a conventional, resetless 1R1W synchronous shape.
    // This boundary is intentional: folding its read into the debug-stub
    // response mux prevents Yosys from finding a valid XC7 BRAM mapping.
    (* ram_style = "block" *) logic [63:0] mem_q [0:DEPTH-1];

    always_ff @(posedge clk_i) begin
        if (write_i)
            mem_q[write_addr_i] <= write_data_i;
        if (read_i)
            read_data_o <= mem_q[read_addr_i];
    end

endmodule

module openrv64_soc_debug_load_trace_mem #(
    parameter integer DEPTH = 4096,
    parameter integer ADDR_WIDTH = $clog2(DEPTH)
) (
    input  logic         clk_i,
    input  logic         write_i,
    input  logic [ADDR_WIDTH-1:0] write_addr_i,
    input  logic [63:0]  write_vaddr_i,
    input  logic [63:0]  write_paddr_i,
    input  logic [63:0]  write_data_i,
    input  logic         read_i,
    input  logic [ADDR_WIDTH-1:0] read_addr_i,
    input  logic         read_word_i,
    output logic [63:0]  read_data_o
);

    // The retirement ring supplies instruction identity. Keep both sides of
    // address translation here; the complete returned value remains intact.
    logic [63:0] read_meta;
    logic [63:0] read_data;

    openrv64_soc_debug_retire_trace_mem #(
        .DEPTH(DEPTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_meta (
        .clk_i(clk_i), .write_i(write_i), .write_addr_i(write_addr_i),
        .write_data_i({write_paddr_i[31:0], write_vaddr_i[31:0]}),
        .read_i(read_i), .read_addr_i(read_addr_i),
        .read_data_o(read_meta)
    );
    openrv64_soc_debug_retire_trace_mem #(
        .DEPTH(DEPTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_data (
        .clk_i(clk_i), .write_i(write_i), .write_addr_i(write_addr_i),
        .write_data_i(write_data_i), .read_i(read_i),
        .read_addr_i(read_addr_i), .read_data_o(read_data)
    );

    assign read_data_o = read_word_i ? read_data : read_meta;

endmodule

module openrv64_soc_debug_store_trace_mem #(
    parameter integer DEPTH = 4096,
    parameter integer ADDR_WIDTH = $clog2(DEPTH)
) (
    input  logic         clk_i,
    input  logic         write_i,
    input  logic [ADDR_WIDTH-1:0] write_addr_i,
    input  logic [63:0]  write_vaddr_i,
    input  logic [63:0]  write_paddr_i,
    input  logic [63:0]  write_data_i,
    input  logic         read_i,
    input  logic [ADDR_WIDTH-1:0] read_addr_i,
    input  logic         read_word_i,
    output logic [63:0]  read_data_o
);

    logic [63:0] read_meta;
    logic [63:0] read_data;

    openrv64_soc_debug_retire_trace_mem #(
        .DEPTH(DEPTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_meta (
        .clk_i(clk_i), .write_i(write_i), .write_addr_i(write_addr_i),
        .write_data_i({write_paddr_i[31:0], write_vaddr_i[31:0]}),
        .read_i(read_i), .read_addr_i(read_addr_i),
        .read_data_o(read_meta)
    );
    openrv64_soc_debug_retire_trace_mem #(
        .DEPTH(DEPTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_data (
        .clk_i(clk_i), .write_i(write_i), .write_addr_i(write_addr_i),
        .write_data_i(write_data_i), .read_i(read_i),
        .read_addr_i(read_addr_i), .read_data_o(read_data)
    );

    assign read_data_o = read_word_i ? read_data : read_meta;

endmodule

module openrv64_soc_debug_stub_mem #(
    parameter integer WORDS = 2048,
    parameter integer RETIRE_TRACE_DEPTH = 8192,
    parameter integer LOAD_TRACE_DEPTH = 4096,
    parameter integer STORE_TRACE_DEPTH = 4096,
    parameter integer FETCH_TRACE_DEPTH = 2048,
    parameter integer WAVE_TRACE_DEPTH = 1024,
    parameter integer WAVE_POST_TRIGGER_CYCLES = 768
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

    input  logic [15:0]  jtag_index_i,
    input  logic         jtag_write_i,
    input  logic         jtag_trace_read_i,
    input  logic         jtag_wave_burst_i,
    input  logic [63:0]  jtag_wdata_i,
    input  logic         jtag_req_toggle_i,
    output logic         jtag_ack_toggle_o,
    output logic [63:0]  jtag_rdata_o,
    output logic [255:0] jtag_wave_rdata_o,

    // Passive, non-architectural retirement history. One packed record is
    // written per retired instruction and the ring stops as soon as the JTAG
    // trigger reaches the core clock domain. The PC identifies the
    // instruction; the truncated result is sufficient to distinguish the
    // small strcmp return values involved in FPGA bring-up.
    input  logic         trace_valid_i,
    input  logic         trace_freeze_i,
    input  logic [63:0]  trace_pc_i,
    input  logic [31:0]  trace_instr_i,
    input  logic [63:0]  trace_next_pc_i,
    input  logic         trace_rd_write_i,
    input  logic [63:0]  trace_wdata_i,
    input  logic         fetch_trace_valid_i,
    input  logic [63:0]  fetch_trace_pc_i,
    input  logic [63:0]  fetch_trace_data_i,
    input  logic         load_trace_valid_i,
    input  logic [63:0]  load_trace_pc_i,
    input  logic [63:0]  load_trace_addr_i,
    input  logic [63:0]  load_trace_paddr_i,
    input  logic [4:0]   load_trace_rd_i,
    input  logic [63:0]  load_trace_data_i,
    input  logic         store_trace_valid_i,
    input  logic [63:0]  store_trace_pc_i,
    input  logic [63:0]  store_trace_addr_i,
    input  logic [63:0]  store_trace_paddr_i,
    input  logic [63:0]  store_trace_data_i,
    input  logic [7:0]   store_trace_wstrb_i,
    input  logic         wave_trace_trigger_i,
    input  logic [255:0] wave_trace_data_i
);

    (* ram_style = "block" *) logic [63:0] stub_mem [0:WORDS-1];
    localparam integer RETIRE_ADDR_WIDTH = $clog2(RETIRE_TRACE_DEPTH);
    localparam integer LOAD_ADDR_WIDTH = $clog2(LOAD_TRACE_DEPTH);
    localparam integer STORE_ADDR_WIDTH = $clog2(STORE_TRACE_DEPTH);
    localparam integer FETCH_ADDR_WIDTH = $clog2(FETCH_TRACE_DEPTH);
    localparam integer WAVE_ADDR_WIDTH = $clog2(WAVE_TRACE_DEPTH);
    localparam integer RETIRE_META_BASE = 2 * RETIRE_TRACE_DEPTH;
    localparam integer LOAD_TRACE_BASE = RETIRE_META_BASE + 2;
    localparam integer LOAD_META_BASE =
        LOAD_TRACE_BASE + 2 * LOAD_TRACE_DEPTH;
    localparam integer STORE_TRACE_BASE = LOAD_META_BASE + 2;
    localparam integer STORE_META_BASE =
        STORE_TRACE_BASE + 2 * STORE_TRACE_DEPTH;
    localparam integer FETCH_TRACE_BASE = STORE_META_BASE + 2;
    localparam integer FETCH_META_BASE =
        FETCH_TRACE_BASE + 2 * FETCH_TRACE_DEPTH;
    localparam integer WAVE_TRACE_BASE = FETCH_META_BASE + 2;
    localparam integer WAVE_META_BASE =
        WAVE_TRACE_BASE + 4 * WAVE_TRACE_DEPTH;

`ifdef OPENRV64_FPGA_LARGE_TRACE
    logic [RETIRE_ADDR_WIDTH-1:0] retire_trace_write_q;
    logic [63:0] retire_trace_count_q;
    logic [63:0] retire_trace_read_record;
    logic [63:0] retire_trace_read_wdata;
    logic [LOAD_ADDR_WIDTH-1:0] load_trace_write_q;
    logic [63:0] load_trace_count_q;
    logic [63:0] load_trace_read_data;
    logic [STORE_ADDR_WIDTH-1:0] store_trace_write_q;
    logic [63:0] store_trace_count_q;
    logic [63:0] store_trace_read_data;
    logic [FETCH_ADDR_WIDTH-1:0] fetch_trace_write_q;
    logic [63:0] fetch_trace_count_q;
    logic [63:0] fetch_trace_read_pc;
    logic [63:0] fetch_trace_read_data;
`else
    wire [RETIRE_ADDR_WIDTH-1:0] retire_trace_write_q = '0;
    wire [63:0] retire_trace_count_q = 64'd0;
    wire [63:0] retire_trace_read_record = 64'd0;
    wire [63:0] retire_trace_read_wdata = 64'd0;
    wire [LOAD_ADDR_WIDTH-1:0] load_trace_write_q = '0;
    wire [63:0] load_trace_count_q = 64'd0;
    wire [63:0] load_trace_read_data = 64'd0;
    wire [STORE_ADDR_WIDTH-1:0] store_trace_write_q = '0;
    wire [63:0] store_trace_count_q = 64'd0;
    wire [63:0] store_trace_read_data = 64'd0;
    wire [FETCH_ADDR_WIDTH-1:0] fetch_trace_write_q = '0;
    wire [63:0] fetch_trace_count_q = 64'd0;
    wire [63:0] fetch_trace_read_pc = 64'd0;
    wire [63:0] fetch_trace_read_data = 64'd0;
`endif
    logic [63:0] retire_trace_read_data;
    logic jtag_result_is_trace_q;
    logic jtag_result_is_load_trace_q;
    logic jtag_result_is_store_trace_q;
    logic jtag_result_is_fetch_trace_q;
    logic jtag_result_is_trace_meta_q;
    logic [63:0] jtag_regular_read_data_q;
    logic [63:0] jtag_trace_meta_data_q;
    logic jtag_result_is_wave_trace_q;

    logic response_pending_q;
    logic [63:0] cpu_read_data_q;

    (* ASYNC_REG = "TRUE" *) logic jtag_req_meta_q;
    (* ASYNC_REG = "TRUE" *) logic jtag_req_sync_q;
    logic jtag_req_seen_q;
    logic [15:0] jtag_index_meta_q;
    logic [15:0] jtag_index_sync_q;
    logic jtag_write_meta_q;
    logic jtag_write_sync_q;
    logic jtag_trace_read_meta_q;
    logic jtag_trace_read_sync_q;
    logic jtag_wave_burst_meta_q;
    logic jtag_wave_burst_sync_q;
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
        (jtag_req_sync_q != jtag_req_seen_q);
    wire retire_trace_read = jtag_access_accept &&
        !jtag_write_sync_q && jtag_trace_read_sync_q &&
        (jtag_index_sync_q < RETIRE_META_BASE);
    wire load_trace_read = jtag_access_accept &&
        !jtag_write_sync_q && jtag_trace_read_sync_q &&
        (jtag_index_sync_q >= LOAD_TRACE_BASE) &&
        (jtag_index_sync_q < LOAD_META_BASE);
    wire [15:0] load_trace_linear_index =
        jtag_index_sync_q - LOAD_TRACE_BASE;
    wire store_trace_read = jtag_access_accept &&
        !jtag_write_sync_q && jtag_trace_read_sync_q &&
        (jtag_index_sync_q >= STORE_TRACE_BASE) &&
        (jtag_index_sync_q < STORE_META_BASE);
    wire [15:0] store_trace_linear_index =
        jtag_index_sync_q - STORE_TRACE_BASE;
    wire fetch_trace_read = jtag_access_accept &&
        !jtag_write_sync_q && jtag_trace_read_sync_q &&
        (jtag_index_sync_q >= FETCH_TRACE_BASE) &&
        (jtag_index_sync_q < FETCH_META_BASE);
    wire [15:0] fetch_trace_linear_index =
        jtag_index_sync_q - FETCH_TRACE_BASE;
    wire wave_trace_read = jtag_access_accept &&
        !jtag_write_sync_q && jtag_trace_read_sync_q &&
        !jtag_wave_burst_sync_q &&
        (jtag_index_sync_q >= WAVE_TRACE_BASE) &&
        (jtag_index_sync_q < WAVE_META_BASE);
    wire [15:0] wave_trace_linear_index =
        jtag_index_sync_q - WAVE_TRACE_BASE;
    wire wave_trace_burst_read = jtag_access_accept &&
        !jtag_write_sync_q && jtag_wave_burst_sync_q;
    wire trace_is_conditional_branch =
        trace_instr_i[6:0] == 7'b1100011;
    wire trace_branch_taken = trace_is_conditional_branch &&
        (trace_next_pc_i != trace_pc_i + 64'd4);

    assign mem_ready_o = response_pending_q && mem_valid_i;
    assign mem_rdata_o = cpu_read_data_q;
    assign retire_trace_read_data = jtag_index_sync_q[0] ?
        retire_trace_read_wdata : retire_trace_read_record;
    assign jtag_rdata_o = jtag_result_is_trace_q ?
        (jtag_result_is_trace_meta_q ? jtag_trace_meta_data_q :
         (jtag_result_is_load_trace_q ? load_trace_read_data :
          (jtag_result_is_store_trace_q ? store_trace_read_data :
           (jtag_result_is_fetch_trace_q ?
            (jtag_index_sync_q[0] ? fetch_trace_read_data :
             fetch_trace_read_pc) :
            (jtag_result_is_wave_trace_q ?
             jtag_wave_rdata_o[jtag_index_sync_q[1:0]*64 +: 64] :
             retire_trace_read_data))))) :
        jtag_regular_read_data_q;

`ifdef OPENRV64_FPGA_LARGE_TRACE
    openrv64_soc_debug_retire_trace_mem #(
        .DEPTH(RETIRE_TRACE_DEPTH), .ADDR_WIDTH(RETIRE_ADDR_WIDTH)
    ) u_retire_trace_record_mem (
        .clk_i(clk_i),
        .write_i(trace_valid_i && !trace_freeze_i),
        .write_addr_i(retire_trace_write_q),
        .write_data_i({trace_pc_i[31:1], trace_branch_taken,
                       trace_instr_i}),
        .read_i(retire_trace_read),
        .read_addr_i(jtag_index_sync_q[RETIRE_ADDR_WIDTH:1]),
        .read_data_o(retire_trace_read_record)
    );
    openrv64_soc_debug_retire_trace_mem #(
        .DEPTH(RETIRE_TRACE_DEPTH), .ADDR_WIDTH(RETIRE_ADDR_WIDTH)
    ) u_retire_trace_wdata_mem (
        .clk_i(clk_i),
        .write_i(trace_valid_i && !trace_freeze_i),
        .write_addr_i(retire_trace_write_q),
        .write_data_i(trace_rd_write_i ? trace_wdata_i : 64'd0),
        .read_i(retire_trace_read),
        .read_addr_i(jtag_index_sync_q[RETIRE_ADDR_WIDTH:1]),
        .read_data_o(retire_trace_read_wdata)
    );

    openrv64_soc_debug_load_trace_mem #(
        .DEPTH(LOAD_TRACE_DEPTH), .ADDR_WIDTH(LOAD_ADDR_WIDTH)
    ) u_load_trace_mem (
        .clk_i(clk_i),
        .write_i(load_trace_valid_i && !trace_freeze_i),
        .write_addr_i(load_trace_write_q),
        .write_vaddr_i(load_trace_addr_i),
        .write_paddr_i(load_trace_paddr_i),
        .write_data_i(load_trace_data_i),
        .read_i(load_trace_read),
        .read_addr_i(load_trace_linear_index[LOAD_ADDR_WIDTH:1]),
        .read_word_i(load_trace_linear_index[0]),
        .read_data_o(load_trace_read_data)
    );

    openrv64_soc_debug_store_trace_mem #(
        .DEPTH(STORE_TRACE_DEPTH), .ADDR_WIDTH(STORE_ADDR_WIDTH)
    ) u_store_trace_mem (
        .clk_i(clk_i),
        .write_i(store_trace_valid_i && !trace_freeze_i),
        .write_addr_i(store_trace_write_q),
        .write_vaddr_i(store_trace_addr_i),
        .write_paddr_i(store_trace_paddr_i),
        .write_data_i(store_trace_data_i),
        .read_i(store_trace_read),
        .read_addr_i(store_trace_linear_index[STORE_ADDR_WIDTH:1]),
        .read_word_i(store_trace_linear_index[0]),
        .read_data_o(store_trace_read_data)
    );

    openrv64_soc_debug_retire_trace_mem #(
        .DEPTH(FETCH_TRACE_DEPTH), .ADDR_WIDTH(FETCH_ADDR_WIDTH)
    ) u_fetch_trace_pc_mem (
        .clk_i(clk_i),
        .write_i(fetch_trace_valid_i && !trace_freeze_i),
        .write_addr_i(fetch_trace_write_q),
        .write_data_i(fetch_trace_pc_i),
        .read_i(fetch_trace_read),
        .read_addr_i(fetch_trace_linear_index[FETCH_ADDR_WIDTH:1]),
        .read_data_o(fetch_trace_read_pc)
    );
    openrv64_soc_debug_retire_trace_mem #(
        .DEPTH(FETCH_TRACE_DEPTH), .ADDR_WIDTH(FETCH_ADDR_WIDTH)
    ) u_fetch_trace_data_mem (
        .clk_i(clk_i),
        .write_i(fetch_trace_valid_i && !trace_freeze_i),
        .write_addr_i(fetch_trace_write_q),
        .write_data_i(fetch_trace_data_i),
        .read_i(fetch_trace_read),
        .read_addr_i(fetch_trace_linear_index[FETCH_ADDR_WIDTH:1]),
        .read_data_o(fetch_trace_read_data)
    );
`endif

`ifdef OPENRV64_FPGA_WAVE_TRACE
    logic [WAVE_ADDR_WIDTH-1:0] wave_trace_write_q;
    logic [WAVE_ADDR_WIDTH-1:0] wave_trigger_index_q;
    logic [WAVE_ADDR_WIDTH-1:0] wave_read_addr;
    logic [WAVE_ADDR_WIDTH-1:0] wave_post_count_q;
    logic [63:0] wave_trace_count_q;
    logic wave_triggered_q;
    logic wave_frozen_q;
    logic [63:0] wave_read_word0;
    logic [63:0] wave_read_word1;
    logic [63:0] wave_read_word2;
    logic [63:0] wave_read_word3;

    assign wave_read_addr = jtag_wave_burst_sync_q ?
        jtag_index_sync_q[WAVE_ADDR_WIDTH-1:0] :
        wave_trace_linear_index[WAVE_ADDR_WIDTH+1:2];
    assign jtag_wave_rdata_o = {
        wave_read_word3, wave_read_word2, wave_read_word1, wave_read_word0
    };

    openrv64_soc_debug_retire_trace_mem #(
        .DEPTH(WAVE_TRACE_DEPTH), .ADDR_WIDTH(WAVE_ADDR_WIDTH)
    ) u_wave_trace_word0_mem (
        .clk_i(clk_i), .write_i(!wave_frozen_q),
        .write_addr_i(wave_trace_write_q),
        .write_data_i(wave_trace_data_i[63:0]),
        .read_i(wave_trace_read || wave_trace_burst_read),
        .read_addr_i(wave_read_addr), .read_data_o(wave_read_word0)
    );
    openrv64_soc_debug_retire_trace_mem #(
        .DEPTH(WAVE_TRACE_DEPTH), .ADDR_WIDTH(WAVE_ADDR_WIDTH)
    ) u_wave_trace_word1_mem (
        .clk_i(clk_i), .write_i(!wave_frozen_q),
        .write_addr_i(wave_trace_write_q),
        .write_data_i(wave_trace_data_i[127:64]),
        .read_i(wave_trace_read || wave_trace_burst_read),
        .read_addr_i(wave_read_addr), .read_data_o(wave_read_word1)
    );
    openrv64_soc_debug_retire_trace_mem #(
        .DEPTH(WAVE_TRACE_DEPTH), .ADDR_WIDTH(WAVE_ADDR_WIDTH)
    ) u_wave_trace_word2_mem (
        .clk_i(clk_i), .write_i(!wave_frozen_q),
        .write_addr_i(wave_trace_write_q),
        .write_data_i(wave_trace_data_i[191:128]),
        .read_i(wave_trace_read || wave_trace_burst_read),
        .read_addr_i(wave_read_addr), .read_data_o(wave_read_word2)
    );
    openrv64_soc_debug_retire_trace_mem #(
        .DEPTH(WAVE_TRACE_DEPTH), .ADDR_WIDTH(WAVE_ADDR_WIDTH)
    ) u_wave_trace_word3_mem (
        .clk_i(clk_i), .write_i(!wave_frozen_q),
        .write_addr_i(wave_trace_write_q),
        .write_data_i(wave_trace_data_i[255:192]),
        .read_i(wave_trace_read || wave_trace_burst_read),
        .read_addr_i(wave_read_addr), .read_data_o(wave_read_word3)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            wave_trace_write_q <= '0;
            wave_trigger_index_q <= '0;
            wave_post_count_q <= '0;
            wave_trace_count_q <= 64'd0;
            wave_triggered_q <= 1'b0;
            wave_frozen_q <= 1'b0;
        end else if (!wave_frozen_q) begin
            wave_trace_write_q <= wave_trace_write_q + 1'b1;
            wave_trace_count_q <= wave_trace_count_q + 64'd1;
            if (!wave_triggered_q && wave_trace_trigger_i) begin
                wave_triggered_q <= 1'b1;
                wave_trigger_index_q <= wave_trace_write_q;
                wave_post_count_q <= '0;
            end else if (wave_triggered_q) begin
                if (wave_post_count_q == WAVE_POST_TRIGGER_CYCLES - 1) begin
                    wave_frozen_q <= 1'b1;
                end else begin
                    wave_post_count_q <= wave_post_count_q + 1'b1;
                end
            end
        end
    end
`else
    wire [WAVE_ADDR_WIDTH-1:0] wave_trace_write_q = '0;
    wire [WAVE_ADDR_WIDTH-1:0] wave_trigger_index_q = '0;
    wire [WAVE_ADDR_WIDTH-1:0] wave_post_count_q = '0;
    wire [63:0] wave_trace_count_q = 64'd0;
    wire wave_triggered_q = 1'b0;
    wire wave_frozen_q = 1'b0;
    assign jtag_wave_rdata_o = 256'd0;
`endif

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
            jtag_result_is_load_trace_q <= load_trace_read;
            jtag_result_is_store_trace_q <= store_trace_read;
            jtag_result_is_fetch_trace_q <= fetch_trace_read;
            jtag_result_is_wave_trace_q <= wave_trace_read;
            jtag_result_is_trace_meta_q <= 1'b0;
            if (jtag_write_sync_q && (jtag_index_sync_q < WORDS)) begin
                stub_mem[jtag_index_sync_q] <= jtag_wdata_sync_q;
                jtag_result_is_trace_q <= 1'b0;
            end else if (jtag_trace_read_sync_q &&
                         !retire_trace_read && !load_trace_read &&
                         !store_trace_read && !fetch_trace_read &&
                         !wave_trace_read && !jtag_wave_burst_sync_q) begin
                jtag_result_is_trace_meta_q <= 1'b1;
                if (jtag_index_sync_q == RETIRE_META_BASE)
                    jtag_trace_meta_data_q <= retire_trace_count_q;
                else if (jtag_index_sync_q == RETIRE_META_BASE + 1)
                    jtag_trace_meta_data_q <=
                        {50'd0, trace_freeze_i, retire_trace_write_q};
                else if (jtag_index_sync_q == LOAD_META_BASE)
                    jtag_trace_meta_data_q <= load_trace_count_q;
                else if (jtag_index_sync_q == LOAD_META_BASE + 1)
                    jtag_trace_meta_data_q <=
                        {51'd0, trace_freeze_i, load_trace_write_q};
                else if (jtag_index_sync_q == STORE_META_BASE)
                    jtag_trace_meta_data_q <= store_trace_count_q;
                else if (jtag_index_sync_q == STORE_META_BASE + 1)
                    jtag_trace_meta_data_q <=
                        {51'd0, trace_freeze_i, store_trace_write_q};
                else if (jtag_index_sync_q == FETCH_META_BASE)
                    jtag_trace_meta_data_q <= fetch_trace_count_q;
                else if (jtag_index_sync_q == FETCH_META_BASE + 1)
                    jtag_trace_meta_data_q <=
                        {52'd0, trace_freeze_i, fetch_trace_write_q};
                else if (jtag_index_sync_q == WAVE_META_BASE)
                    jtag_trace_meta_data_q <= wave_trace_count_q;
                else if (jtag_index_sync_q == WAVE_META_BASE + 1)
                    jtag_trace_meta_data_q <=
                        {32'd0, wave_post_count_q, wave_frozen_q,
                         wave_triggered_q, wave_trigger_index_q,
                         wave_trace_write_q};
                else
                    jtag_trace_meta_data_q <= 64'd0;
            end else if (!jtag_trace_read_sync_q &&
                         (jtag_index_sync_q < WORDS)) begin
                jtag_regular_read_data_q <= stub_mem[jtag_index_sync_q];
            end
        end
    end

`ifdef OPENRV64_FPGA_LARGE_TRACE
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            retire_trace_write_q <= '0;
            retire_trace_count_q <= 64'd0;
            load_trace_write_q <= '0;
            load_trace_count_q <= 64'd0;
            store_trace_write_q <= '0;
            store_trace_count_q <= 64'd0;
            fetch_trace_write_q <= '0;
            fetch_trace_count_q <= 64'd0;
        end else begin
            if (trace_valid_i && !trace_freeze_i) begin
                retire_trace_write_q <= retire_trace_write_q + 1'b1;
                retire_trace_count_q <= retire_trace_count_q + 64'd1;
            end
            if (load_trace_valid_i && !trace_freeze_i) begin
                load_trace_write_q <= load_trace_write_q + 1'b1;
                load_trace_count_q <= load_trace_count_q + 64'd1;
            end
            if (store_trace_valid_i && !trace_freeze_i) begin
                store_trace_write_q <= store_trace_write_q + 1'b1;
                store_trace_count_q <= store_trace_count_q + 64'd1;
            end
            if (fetch_trace_valid_i && !trace_freeze_i) begin
                fetch_trace_write_q <= fetch_trace_write_q + 1'b1;
                fetch_trace_count_q <= fetch_trace_count_q + 64'd1;
            end
        end
    end
`endif

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
            jtag_index_meta_q <= 16'd0;
            jtag_index_sync_q <= 16'd0;
            jtag_write_meta_q <= 1'b0;
            jtag_write_sync_q <= 1'b0;
            jtag_trace_read_meta_q <= 1'b0;
            jtag_trace_read_sync_q <= 1'b0;
            jtag_wave_burst_meta_q <= 1'b0;
            jtag_wave_burst_sync_q <= 1'b0;
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
            jtag_wave_burst_meta_q <= jtag_wave_burst_i;
            jtag_wave_burst_sync_q <= jtag_wave_burst_meta_q;
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
