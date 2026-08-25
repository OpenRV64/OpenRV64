// SPDX-License-Identifier: CERN-OHL-P-2.0
//
// FPGA-only rolling capture of characters accepted by the platform UART
// transmitter. Bytes are accumulated into a full 64-bit word before a BRAM
// write. A JTAG request performs four sequential BRAM reads internally and
// returns one 256-bit, 32-byte burst.

`timescale 1ns/1ps

module openrv64_soc_debug_uart_trace_mem #(
    parameter integer WORDS = 2048
) (
    input  logic         clk_i,
    input  logic         rst_ni,

    input  logic         uart_byte_valid_i,
    input  logic [7:0]   uart_byte_i,

    input  logic [10:0]  jtag_index_i,
    input  logic         jtag_req_toggle_i,
    output logic         jtag_ack_toggle_o,
    output logic [255:0] jtag_rdata_o,
    output logic [63:0]  jtag_byte_count_o
);

    (* ram_style = "block" *) logic [63:0] uart_trace_mem [0:WORDS-1];
    logic [63:0] byte_count_q;
    logic [63:0] uart_word_staging_q;

    (* ASYNC_REG = "TRUE" *) logic jtag_req_meta_q;
    (* ASYNC_REG = "TRUE" *) logic jtag_req_sync_q;
    logic jtag_req_ready_q;
    logic jtag_req_seen_q;
    logic [10:0] jtag_index_meta_q;
    logic [10:0] jtag_index_sync_q;

    logic [2:0] jtag_read_state_q;
    logic [10:0] jtag_read_base_q;
    logic [63:0] jtag_bram_rdata_q;
    logic [191:0] jtag_gather_q;
    logic jtag_partial_valid_q;
    logic [1:0] jtag_partial_lane_q;
    logic [2:0] jtag_partial_bytes_q;
    logic [63:0] jtag_partial_data_q;
    logic [63:0] jtag_partial_mask;
    logic [255:0] jtag_completed_burst;

    wire jtag_read_accept = (jtag_read_state_q == 3'd0) &&
        (jtag_req_ready_q != jtag_req_seen_q) &&
        (jtag_index_sync_q < WORDS) &&
        (jtag_index_sync_q[1:0] == 2'b00);
    wire jtag_bram_read = (jtag_read_state_q >= 3'd1) &&
                          (jtag_read_state_q <= 3'd4);
    wire [10:0] jtag_bram_addr = jtag_read_base_q +
                                 {8'd0, jtag_read_state_q} - 11'd1;

    // The total count is intentionally wider than the ring address. UART
    // writes are converted to full-word writes so the implementation does not
    // depend on RAMB36E1 byte-enable inference.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            byte_count_q <= 64'd0;
            uart_word_staging_q <= 64'd0;
        end else if (uart_byte_valid_i) begin
            uart_word_staging_q[byte_count_q[2:0]*8 +: 8] <= uart_byte_i;
            byte_count_q <= byte_count_q + 64'd1;
        end
    end

    always_ff @(posedge clk_i) begin
        if (uart_byte_valid_i && (byte_count_q[2:0] == 3'd7))
            uart_trace_mem[byte_count_q[13:3]] <=
                {uart_byte_i, uart_word_staging_q[55:0]};
    end

    // One conventional synchronous read port. Four consecutive cycles fill
    // the JTAG burst buffer; this is still one external USER1 transaction.
    always_ff @(posedge clk_i) begin
        if (jtag_bram_read)
            jtag_bram_rdata_q <= uart_trace_mem[jtag_bram_addr];
    end

    // Merge a partially filled current word after all four BRAM reads. This
    // logic is deliberately outside the memory read process so BRAM inference
    // sees only one full-word write and one registered read port.
    always_comb begin
        case (jtag_partial_bytes_q)
            3'd1: jtag_partial_mask = 64'h0000_0000_0000_00ff;
            3'd2: jtag_partial_mask = 64'h0000_0000_0000_ffff;
            3'd3: jtag_partial_mask = 64'h0000_0000_00ff_ffff;
            3'd4: jtag_partial_mask = 64'h0000_0000_ffff_ffff;
            3'd5: jtag_partial_mask = 64'h0000_00ff_ffff_ffff;
            3'd6: jtag_partial_mask = 64'h0000_ffff_ffff_ffff;
            3'd7: jtag_partial_mask = 64'h00ff_ffff_ffff_ffff;
            default: jtag_partial_mask = 64'd0;
        endcase
        jtag_completed_burst = {jtag_bram_rdata_q, jtag_gather_q};
        if (jtag_partial_valid_q) begin
            case (jtag_partial_lane_q)
                2'd0: jtag_completed_burst[63:0] =
                    (jtag_completed_burst[63:0] & ~jtag_partial_mask) |
                    (jtag_partial_data_q & jtag_partial_mask);
                2'd1: jtag_completed_burst[127:64] =
                    (jtag_completed_burst[127:64] & ~jtag_partial_mask) |
                    (jtag_partial_data_q & jtag_partial_mask);
                2'd2: jtag_completed_burst[191:128] =
                    (jtag_completed_burst[191:128] & ~jtag_partial_mask) |
                    (jtag_partial_data_q & jtag_partial_mask);
                default: jtag_completed_burst[255:192] =
                    (jtag_completed_burst[255:192] & ~jtag_partial_mask) |
                    (jtag_partial_data_q & jtag_partial_mask);
            endcase
        end
    end

    // The request toggle has one extra settling stage beyond the synchronized
    // index bundle. States 1..4 issue the four reads; states 2..5 consume the
    // corresponding registered BRAM results.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            jtag_req_meta_q <= 1'b0;
            jtag_req_sync_q <= 1'b0;
            jtag_req_ready_q <= 1'b0;
            jtag_req_seen_q <= 1'b0;
            jtag_index_meta_q <= 11'd0;
            jtag_index_sync_q <= 11'd0;
            jtag_read_state_q <= 3'd0;
            jtag_read_base_q <= 11'd0;
            jtag_ack_toggle_o <= 1'b0;
            jtag_partial_valid_q <= 1'b0;
            jtag_partial_lane_q <= 2'd0;
            jtag_partial_bytes_q <= 3'd0;
            jtag_partial_data_q <= 64'd0;
        end else begin
            jtag_req_meta_q <= jtag_req_toggle_i;
            jtag_req_sync_q <= jtag_req_meta_q;
            jtag_req_ready_q <= jtag_req_sync_q;
            jtag_index_meta_q <= jtag_index_i;
            jtag_index_sync_q <= jtag_index_meta_q;

            if (jtag_read_accept) begin
                jtag_req_seen_q <= jtag_req_ready_q;
                jtag_read_state_q <= 3'd1;
                jtag_read_base_q <= jtag_index_sync_q;
                jtag_byte_count_o <= byte_count_q;
                jtag_partial_valid_q <= (byte_count_q[2:0] != 3'd0) &&
                    (byte_count_q[13:5] == jtag_index_sync_q[10:2]);
                jtag_partial_lane_q <= byte_count_q[4:3];
                jtag_partial_bytes_q <= byte_count_q[2:0];
                jtag_partial_data_q <= uart_word_staging_q;
            end else begin
                case (jtag_read_state_q)
                    3'd1: jtag_read_state_q <= 3'd2;
                    3'd2: begin
                        jtag_gather_q[63:0] <= jtag_bram_rdata_q;
                        jtag_read_state_q <= 3'd3;
                    end
                    3'd3: begin
                        jtag_gather_q[127:64] <= jtag_bram_rdata_q;
                        jtag_read_state_q <= 3'd4;
                    end
                    3'd4: begin
                        jtag_gather_q[191:128] <= jtag_bram_rdata_q;
                        jtag_read_state_q <= 3'd5;
                    end
                    3'd5: begin
                        jtag_rdata_o <= jtag_completed_burst;
                        jtag_ack_toggle_o <= jtag_req_seen_q;
                        jtag_read_state_q <= 3'd0;
                    end
                    default: jtag_read_state_q <= 3'd0;
                endcase
            end
        end
    end
endmodule
