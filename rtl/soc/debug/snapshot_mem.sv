// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// FPGA-only machine-mode snapshot storage. The CPU port is a blocking,
// one-response-at-a-time MMIO target. The second read port is manually paced
// from USER1 JTAG through a request/acknowledgement toggle pair.

`timescale 1ns/1ps

module openrv64_soc_debug_snapshot_mem #(
    parameter integer WORDS = 512
) (
    input  logic         clk_i,
    input  logic         rst_ni,

    input  logic         mem_valid_i,
    output logic         mem_ready_o,
    input  logic         mem_write_i,
    input  logic [11:0]  mem_addr_i,
    input  logic [63:0]  mem_wdata_i,
    input  logic [7:0]   mem_wstrb_i,
    output logic [63:0]  mem_rdata_o,

    input  logic [8:0]   jtag_read_index_i,
    input  logic         jtag_read_req_toggle_i,
    output logic         jtag_read_ack_toggle_o,
    output logic [63:0]  jtag_read_data_o,
    input  logic         jtag_resume_toggle_i,

    input  logic         trigger_active_i,
    output logic         trigger_ack_o,
    output logic         resume_pending_o
);

    localparam logic [11:0] STATUS_OFFSET  = 12'hff0;
    localparam logic [11:0] CONTROL_OFFSET = 12'hff8;

    (* ram_style = "block" *) logic [63:0] snapshot_mem [0:WORDS-1];

    logic response_pending_q;
    logic response_is_memory_q;
    logic [63:0] mem_rdata_q;
    logic [63:0] cpu_mem_read_data_q;

    (* ASYNC_REG = "TRUE" *) logic jtag_read_req_meta_q;
    (* ASYNC_REG = "TRUE" *) logic jtag_read_req_sync_q;
    logic jtag_read_req_seen_q;
    logic [8:0] jtag_read_index_meta_q;
    logic [8:0] jtag_read_index_sync_q;
    logic jtag_read_pending_q;

    (* ASYNC_REG = "TRUE" *) logic jtag_resume_meta_q;
    (* ASYNC_REG = "TRUE" *) logic jtag_resume_sync_q;
    logic jtag_resume_seen_q;

    wire mem_addr_is_register = (mem_addr_i == STATUS_OFFSET) ||
        (mem_addr_i == CONTROL_OFFSET);
    wire control_ack_write = mem_valid_i && !response_pending_q &&
        mem_write_i && (mem_addr_i == CONTROL_OFFSET) && mem_wstrb_i[0] &&
        mem_wdata_i[0];
    wire cpu_mem_write_accept = mem_valid_i && !response_pending_q &&
        mem_write_i && !mem_addr_is_register &&
        (mem_addr_i[11:3] < WORDS) &&
        (mem_wstrb_i == 8'hff);
    wire cpu_mem_read_accept = mem_valid_i && !response_pending_q &&
        !mem_write_i && !mem_addr_is_register &&
        (mem_addr_i[11:3] < WORDS);
    wire jtag_read_accept = !jtag_read_pending_q &&
        (jtag_read_req_sync_q != jtag_read_req_seen_q);

    assign mem_ready_o = response_pending_q && mem_valid_i;
    assign mem_rdata_o = response_is_memory_q ?
        cpu_mem_read_data_q : mem_rdata_q;

    // Port A is the CPU's mutually exclusive read/write port. Keeping the
    // memory itself out of resettable control processes is required for Yosys
    // and Vivado to retain it as synchronous block RAM.
    always_ff @(posedge clk_i) begin
        if (cpu_mem_write_accept)
            snapshot_mem[mem_addr_i[11:3]] <= mem_wdata_i;
        if (cpu_mem_read_accept)
            cpu_mem_read_data_q <= snapshot_mem[mem_addr_i[11:3]];
    end

    // Port B is read-only and paced by the synchronized USER1 toggle.
    always_ff @(posedge clk_i) begin
        if (jtag_read_accept)
            jtag_read_data_o <= snapshot_mem[jtag_read_index_sync_q];
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            response_pending_q <= 1'b0;
            response_is_memory_q <= 1'b0;
            mem_rdata_q <= 64'd0;
            trigger_ack_o <= 1'b0;
        end else begin
            trigger_ack_o <= 1'b0;

            if (response_pending_q) begin
                if (mem_valid_i)
                    response_pending_q <= 1'b0;
            end else if (mem_valid_i) begin
                response_pending_q <= 1'b1;
                response_is_memory_q <= !mem_write_i &&
                    !mem_addr_is_register &&
                    (mem_addr_i[11:3] < WORDS);

                if (mem_write_i) begin
                    if (mem_addr_i == CONTROL_OFFSET) begin
                        if (mem_wstrb_i[0] && mem_wdata_i[0])
                            trigger_ack_o <= 1'b1;
                    end
                    mem_rdata_q <= 64'd0;
                end else if (mem_addr_i == STATUS_OFFSET) begin
                    mem_rdata_q <= {62'd0, trigger_active_i,
                                    resume_pending_o};
                end else begin
                    mem_rdata_q <= 64'd0;
                end
            end
        end
    end

    // Both request index and request toggle originate in the USER1 domain.
    // The index is held stable before the toggle and until acknowledgement.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            jtag_read_req_meta_q <= 1'b0;
            jtag_read_req_sync_q <= 1'b0;
            jtag_read_req_seen_q <= 1'b0;
            jtag_read_index_meta_q <= 9'd0;
            jtag_read_index_sync_q <= 9'd0;
            jtag_read_pending_q <= 1'b0;
            jtag_read_ack_toggle_o <= 1'b0;
        end else begin
            jtag_read_req_meta_q <= jtag_read_req_toggle_i;
            jtag_read_req_sync_q <= jtag_read_req_meta_q;
            jtag_read_index_meta_q <= jtag_read_index_i;
            jtag_read_index_sync_q <= jtag_read_index_meta_q;

            if (jtag_read_accept) begin
                jtag_read_req_seen_q <= jtag_read_req_sync_q;
                jtag_read_pending_q <= 1'b1;
            end else if (jtag_read_pending_q) begin
                jtag_read_pending_q <= 1'b0;
                jtag_read_ack_toggle_o <= jtag_read_req_seen_q;
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            jtag_resume_meta_q <= 1'b0;
            jtag_resume_sync_q <= 1'b0;
            jtag_resume_seen_q <= 1'b0;
            resume_pending_o <= 1'b0;
        end else begin
            jtag_resume_meta_q <= jtag_resume_toggle_i;
            jtag_resume_sync_q <= jtag_resume_meta_q;

            if (jtag_resume_sync_q != jtag_resume_seen_q) begin
                jtag_resume_seen_q <= jtag_resume_sync_q;
                resume_pending_o <= 1'b1;
            end else if (control_ack_write) begin
                resume_pending_o <= 1'b0;
            end
        end
    end

endmodule
