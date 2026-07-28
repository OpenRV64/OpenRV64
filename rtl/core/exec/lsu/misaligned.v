`timescale 1ns/1ps
`include "core/backend/backend-defs.v"
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"

// Component-serial engine for ordinary misaligned scalar loads and stores.
//
// The containing 3P LSU starts this engine only at ordered retirement with an
// otherwise empty LSQ. Each component is the largest naturally aligned 1-, 2-,
// or 4-byte access that fits in the remaining range, so an unaligned
// doubleword needs at most four requests. Each component gets its own
// translation and PMP check, including across a page boundary. Main-memory
// stores can therefore become partially visible before a later component
// faults, as permitted for decomposed misaligned stores.
module openrv64_lsu_misaligned #(
    parameter integer TAG_WIDTH = `OPENRV64_LSU_TAG_WIDTH,
    parameter [`RV64_XLEN-1:0] CACHEABLE_BASE = {`RV64_XLEN{1'b0}},
    parameter [`RV64_XLEN-1:0] CACHEABLE_SIZE = {`RV64_XLEN{1'b0}}
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         flush_i,

    input  wire                         start_valid_i,
    output wire                         start_ready_o,
    input  wire                         start_write_i,
    input  wire [`RV64_XLEN-1:0]        start_addr_i,
    input  wire [2:0]                   start_size_i,
    input  wire [`RV64_XLEN-1:0]        start_wdata_i,
    input  wire                         translation_bypass_i,

    output wire                         active_o,
    output wire                         result_valid_o,
    input  wire                         result_ready_i,
    output wire [`RV64_XLEN-1:0]        result_rdata_o,
    output wire                         result_access_fault_o,
    output wire                         result_page_fault_o,
    output wire [`RV64_XLEN-1:0]        result_fault_addr_o,

    output wire                         xlate_valid_o,
    input  wire                         xlate_ready_i,
    output wire [TAG_WIDTH-1:0]         xlate_tag_o,
    output wire                         xlate_write_o,
    output wire [`RV64_XLEN-1:0]        xlate_vaddr_o,
    input  wire                         xlate_resp_valid_i,
    output wire                         xlate_resp_ready_o,
    input  wire [TAG_WIDTH-1:0]         xlate_resp_tag_i,
    input  wire [`RV64_XLEN-1:0]        xlate_resp_paddr_i,
    input  wire                         xlate_resp_access_fault_i,
    input  wire                         xlate_resp_page_fault_i,

    output wire                         mem_valid_o,
    input  wire                         mem_ready_i,
    output wire [TAG_WIDTH-1:0]         mem_tag_o,
    output wire                         mem_write_o,
    output wire [`RV64_XLEN-1:0]        mem_addr_o,
    output wire [`RV64_XLEN-1:0]        mem_wdata_o,
    output wire [7:0]                   mem_wstrb_o,
    output wire [`RV64_XLEN-1:0]        mem_effective_addr_o,
    output wire [2:0]                   mem_size_o,
    input  wire                         mem_resp_valid_i,
    output wire                         mem_resp_ready_o,
    input  wire [TAG_WIDTH-1:0]         mem_resp_tag_i,
    input  wire [`RV64_XLEN-1:0]        mem_rdata_i,
    input  wire                         mem_error_i,
    input  wire                         mem_page_fault_i,
    input  wire                         mem_store_done_valid_i,
    output wire                         mem_store_done_ready_o,
    input  wire [TAG_WIDTH-1:0]         mem_store_done_tag_i
);

    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_XLATE = 2'd1;
    localparam [1:0] STATE_ACCESS = 2'd2;
    localparam [1:0] STATE_RESULT = 2'd3;

    reg [1:0] state_q;
    reg write_q;
    reg translation_bypass_q;
    reg [`RV64_XLEN-1:0] base_addr_q;
    // Stores consume this register; loads assemble their result into it.
    reg [`RV64_XLEN-1:0] data_q;
    reg [`RV64_XLEN-1:0] paddr_q;
    reg [2:0] byte_index_q;
    reg [2:0] last_byte_q;
    reg xlate_sent_q;
    reg access_sent_q;
    reg access_fault_q;
    reg page_fault_q;

    function automatic [2:0] access_last_byte;
        input [2:0] size;
        begin
            case (size)
                3'd1: access_last_byte = 3'd1;
                3'd2: access_last_byte = 3'd3;
                default: access_last_byte = 3'd7;
            endcase
        end
    endfunction

    wire [`RV64_XLEN-1:0] current_vaddr =
        base_addr_q + {{(`RV64_XLEN-3){1'b0}}, byte_index_q};
    wire [3:0] remaining_bytes =
        {1'b0, last_byte_q} + 1'b1 - {1'b0, byte_index_q};
    wire [2:0] component_size =
        (remaining_bytes >= 4 && current_vaddr[1:0] == 2'b00) ?
        3'd2 :
        (remaining_bytes >= 2 && current_vaddr[0] == 1'b0) ?
        3'd1 : 3'd0;
    wire [3:0] component_bytes =
        component_size == 3'd2 ? 4'd4 :
        component_size == 3'd1 ? 4'd2 : 4'd1;
    wire [3:0] next_byte_index =
        {1'b0, byte_index_q} + component_bytes;
    wire [`RV64_XLEN-1:0] paddr_offset = paddr_q - CACHEABLE_BASE;
    wire current_paddr_cacheable =
        (CACHEABLE_SIZE != {`RV64_XLEN{1'b0}}) &&
        (paddr_offset < CACHEABLE_SIZE) &&
        ({{(`RV64_XLEN-4){1'b0}}, component_bytes} <=
         (CACHEABLE_SIZE - paddr_offset));
    wire [5:0] paddr_byte_shift = {paddr_q[2:0], 3'b000};
    wire [5:0] result_byte_shift = {byte_index_q, 3'b000};
    wire [`RV64_XLEN-1:0] component_data_mask =
        component_size == 3'd2 ? 64'h0000_0000_ffff_ffff :
        component_size == 3'd1 ? 64'h0000_0000_0000_ffff :
                                 64'h0000_0000_0000_00ff;
    wire [7:0] component_strobe =
        component_size == 3'd2 ? 8'h0f :
        component_size == 3'd1 ? 8'h03 : 8'h01;
    wire [`RV64_XLEN-1:0] current_store_component =
        (data_q >> result_byte_shift) & component_data_mask;
    wire [`RV64_XLEN-1:0] response_load_component =
        (mem_rdata_i >> paddr_byte_shift) & component_data_mask;

    assign start_ready_o = state_q == STATE_IDLE;
    wire start_fire = start_valid_i && start_ready_o;
    assign active_o = state_q != STATE_IDLE;

    assign result_valid_o = state_q == STATE_RESULT;
    assign result_rdata_o = data_q;
    assign result_access_fault_o = access_fault_q;
    assign result_page_fault_o = page_fault_q;
    assign result_fault_addr_o = current_vaddr;
    wire result_fire = result_valid_o && result_ready_i;

    assign xlate_valid_o = (state_q == STATE_XLATE) && !xlate_sent_q;
    assign xlate_tag_o = {TAG_WIDTH{1'b0}};
    assign xlate_write_o = write_q;
    assign xlate_vaddr_o = current_vaddr;
    wire xlate_fire = xlate_valid_o && xlate_ready_i;
    assign xlate_resp_ready_o = state_q == STATE_XLATE;
    wire xlate_resp_fire = xlate_resp_valid_i &&
        xlate_resp_ready_o &&
        (xlate_resp_tag_i == {TAG_WIDTH{1'b0}}) &&
        (xlate_sent_q || xlate_fire);

    assign mem_valid_o = (state_q == STATE_ACCESS) &&
                         !access_sent_q &&
                         current_paddr_cacheable;
    assign mem_tag_o = {TAG_WIDTH{1'b0}};
    assign mem_write_o = write_q;
    assign mem_addr_o = paddr_q;
    assign mem_wdata_o = current_store_component << paddr_byte_shift;
    assign mem_wstrb_o = write_q ?
                         (component_strobe << paddr_q[2:0]) : 8'h00;
    assign mem_effective_addr_o = current_vaddr;
    assign mem_size_o = component_size;
    wire mem_fire = mem_valid_o && mem_ready_i;

    assign mem_resp_ready_o = state_q == STATE_ACCESS;
    wire mem_resp_fire = mem_resp_valid_i &&
        mem_resp_ready_o &&
        (mem_resp_tag_i == {TAG_WIDTH{1'b0}}) &&
        (access_sent_q || mem_fire);
    assign mem_store_done_ready_o = state_q == STATE_ACCESS;
    wire store_done_fire = write_q &&
        mem_store_done_valid_i &&
        mem_store_done_ready_o &&
        (mem_store_done_tag_i == {TAG_WIDTH{1'b0}}) &&
        (access_sent_q || mem_fire);
    wire component_done = mem_resp_fire || store_done_fire;
    wire component_fault = mem_resp_fire &&
                           (mem_error_i || mem_page_fault_i);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= STATE_IDLE;
            write_q <= 1'b0;
            translation_bypass_q <= 1'b0;
            base_addr_q <= {`RV64_XLEN{1'b0}};
            data_q <= {`RV64_XLEN{1'b0}};
            paddr_q <= {`RV64_XLEN{1'b0}};
            byte_index_q <= 3'd0;
            last_byte_q <= 3'd0;
            xlate_sent_q <= 1'b0;
            access_sent_q <= 1'b0;
            access_fault_q <= 1'b0;
            page_fault_q <= 1'b0;
        end else begin
            case (state_q)
                STATE_IDLE: begin
                    if (start_fire) begin
                        write_q <= start_write_i;
                        translation_bypass_q <= translation_bypass_i;
                        base_addr_q <= start_addr_i;
                        data_q <= start_write_i ? start_wdata_i :
                                  {`RV64_XLEN{1'b0}};
                        paddr_q <= translation_bypass_i ?
                                   start_addr_i :
                                   {`RV64_XLEN{1'b0}};
                        byte_index_q <= 3'd0;
                        last_byte_q <= access_last_byte(start_size_i);
                        xlate_sent_q <= 1'b0;
                        access_sent_q <= 1'b0;
                        access_fault_q <= 1'b0;
                        page_fault_q <= 1'b0;
                        state_q <= translation_bypass_i ?
                                   STATE_ACCESS : STATE_XLATE;
                    end
                end

                STATE_XLATE: begin
                    if (xlate_resp_fire) begin
                        xlate_sent_q <= 1'b0;
                        if (xlate_resp_access_fault_i ||
                            xlate_resp_page_fault_i) begin
                            access_fault_q <=
                                xlate_resp_access_fault_i;
                            page_fault_q <= xlate_resp_page_fault_i;
                            state_q <= STATE_RESULT;
                        end else begin
                            paddr_q <= xlate_resp_paddr_i;
                            state_q <= STATE_ACCESS;
                        end
                    end else if (xlate_fire) begin
                        xlate_sent_q <= 1'b1;
                    end
                end

                STATE_ACCESS: begin
                    if (!current_paddr_cacheable) begin
                        access_fault_q <= 1'b1;
                        page_fault_q <= 1'b0;
                        access_sent_q <= 1'b0;
                        state_q <= STATE_RESULT;
                    end else if (component_done) begin
                        access_sent_q <= 1'b0;
                        if (component_fault) begin
                            access_fault_q <= mem_error_i;
                            page_fault_q <= mem_page_fault_i;
                            state_q <= STATE_RESULT;
                        end else if (next_byte_index >
                                     {1'b0, last_byte_q}) begin
                            if (!write_q)
                                data_q <= data_q |
                                    (response_load_component
                                     << result_byte_shift);
                            state_q <= STATE_RESULT;
                        end else begin
                            if (!write_q)
                                data_q <= data_q |
                                    (response_load_component
                                     << result_byte_shift);
                            byte_index_q <= next_byte_index[2:0];
                            if (translation_bypass_q) begin
                                paddr_q <= paddr_q +
                                    {{(`RV64_XLEN-4){1'b0}},
                                      component_bytes};
                                state_q <= STATE_ACCESS;
                            end else begin
                                xlate_sent_q <= 1'b0;
                                state_q <= STATE_XLATE;
                            end
                        end
                    end else begin
                        if (mem_fire)
                            access_sent_q <= 1'b1;
                        // Redirect cancellation suppresses an ordinary load
                        // response below this block. Reissue that component
                        // after the old tag is released. Stores are not
                        // cancelled.
                        if (flush_i && !write_q && access_sent_q)
                            access_sent_q <= 1'b0;
                    end
                end

                default: begin
                    if (result_fire)
                        state_q <= STATE_IDLE;
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && start_fire &&
            ((start_size_i == 3'd0) || (start_size_i > 3'd3)))
            $fatal(1,
                "misaligned LSU started with invalid scalar size=%0d",
                start_size_i);
        if (rst_n && component_done && !access_sent_q && !mem_fire)
            $fatal(1, "misaligned LSU received an unexpected component response");
    end
`endif

endmodule
