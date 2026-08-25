`timescale 1ns/1ps

module openrv64_plic #(
    parameter integer NUM_HARTS = 1,
    parameter integer NUM_SOURCES = 32,
    parameter integer PRIORITY_WIDTH = 3,
    // The base platform historically exposed only one S-mode context per
    // hart. FPGA machine-mode debug enables the conventional M,S pair.
    parameter integer M_CONTEXT_ENABLE = 0
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,

    // Active-high, level-sensitive platform interrupt inputs. Vector bit zero
    // is PLIC source ID 1; architectural source ID 0 does not exist.
    input  wire [NUM_SOURCES-1:0]       irq_sources_i,

    // Target-local side of the OpenRV64 blocking memory bus. The SoC decoder
    // removes the global PLIC base and presents offsets in mem_addr_i.
    input  wire                         mem_valid_i,
    output wire                         mem_ready_o,
    input  wire                         mem_write_i,
    input  wire [63:0]                  mem_addr_i,
    input  wire [63:0]                  mem_wdata_i,
    input  wire [7:0]                   mem_wstrb_i,
    output reg  [63:0]                  mem_rdata_o,

    // When M_CONTEXT_ENABLE is set, context 2*hart is machine mode and
    // context 2*hart+1 is supervisor mode. Otherwise context hart is S mode.
    output wire [NUM_HARTS-1:0]         meip_o,
    output wire [NUM_HARTS-1:0]         seip_o
);

    localparam [63:0] PRIORITY_OFFSET     = 64'h0000_0000_0000_0000;
    localparam [63:0] PENDING_OFFSET      = 64'h0000_0000_0000_1000;
    localparam [63:0] ENABLE_OFFSET       = 64'h0000_0000_0000_2000;
    localparam [63:0] ENABLE_STRIDE       = 64'h0000_0000_0000_0080;
    localparam [63:0] CONTEXT_OFFSET      = 64'h0000_0000_0020_0000;
    localparam [63:0] CONTEXT_STRIDE      = 64'h0000_0000_0000_1000;
    localparam [63:0] THRESHOLD_OFFSET    = 64'h0000_0000_0000_0000;
    localparam [63:0] CLAIM_OFFSET        = 64'h0000_0000_0000_0004;
    localparam integer CONTEXTS_PER_HART = M_CONTEXT_ENABLE ? 2 : 1;
    localparam integer NUM_CONTEXTS = NUM_HARTS * CONTEXTS_PER_HART;

    reg [(NUM_SOURCES*PRIORITY_WIDTH)-1:0] priority_q;
    reg [NUM_SOURCES-1:0] pending_q;
    reg [NUM_SOURCES-1:0] in_service_q;
    reg [(NUM_CONTEXTS*NUM_SOURCES)-1:0] enable_q;
    reg [(NUM_CONTEXTS*PRIORITY_WIDTH)-1:0] threshold_q;

    wire [63:0] addr_offset = mem_addr_i;
    wire read_accept = mem_valid_i && !mem_write_i;
    wire write_accept = mem_valid_i && mem_write_i;

    wire [(NUM_CONTEXTS*32)-1:0] selected_id;

    integer read_source_index;
    integer read_hart_index;
    integer write_source_index;
    integer write_hart_index;

    function [31:0] select_interrupt;
        input [NUM_SOURCES-1:0] pending;
        input [NUM_SOURCES-1:0] enabled;
        input [(NUM_SOURCES*PRIORITY_WIDTH)-1:0] priorities;
        input [PRIORITY_WIDTH-1:0] threshold;
        integer source_index;
        reg [PRIORITY_WIDTH-1:0] best_priority;
        reg [PRIORITY_WIDTH-1:0] source_priority;
        begin
            select_interrupt = 32'h0000_0000;
            best_priority = threshold;

            // Sources are visited in ascending ID order. Replacing the
            // winner only on a strictly higher priority implements the PLIC
            // rule that the lowest source ID wins a priority tie.
            for (source_index = 0;
                 source_index < NUM_SOURCES;
                 source_index = source_index + 1) begin
                source_priority =
                    priorities[PRIORITY_WIDTH*source_index +: PRIORITY_WIDTH];

                if (pending[source_index] &&
                    enabled[source_index] &&
                    (source_priority > best_priority)) begin
                    select_interrupt = source_index + 1;
                    best_priority = source_priority;
                end
            end
        end
    endfunction

    // Global range checking belongs to openrv64_soc_bus_decode. Reserved
    // local offsets read as zero and ignore writes.
    assign mem_ready_o = mem_valid_i;

    generate
        genvar target_index;
        for (target_index = 0;
             target_index < NUM_CONTEXTS;
             target_index = target_index + 1) begin : gen_targets
            assign selected_id[32*target_index +: 32] =
                select_interrupt(
                    pending_q,
                    enable_q[NUM_SOURCES*target_index +: NUM_SOURCES],
                    priority_q,
                    threshold_q[PRIORITY_WIDTH*target_index +:
                                PRIORITY_WIDTH]);
        end

        for (target_index = 0;
             target_index < NUM_HARTS;
             target_index = target_index + 1) begin : gen_hart_outputs
            if (M_CONTEXT_ENABLE != 0) begin : gen_machine_context
                assign meip_o[target_index] =
                    |selected_id[32*(2*target_index) +: 32];
                assign seip_o[target_index] =
                    |selected_id[32*((2*target_index)+1) +: 32];
            end else begin : gen_supervisor_only_context
                assign meip_o[target_index] = 1'b0;
                assign seip_o[target_index] =
                    |selected_id[32*target_index +: 32];
            end
        end
    endgenerate

    always @* begin
        mem_rdata_o = 64'h0000_0000_0000_0000;

        for (read_source_index = 0;
             read_source_index < NUM_SOURCES;
             read_source_index = read_source_index + 1) begin
            // Priority register for architectural source ID N is at 4*N.
            if (addr_offset[63:3] ==
                ((PRIORITY_OFFSET +
                  ((read_source_index + 1) * 4)) >> 3)) begin
                mem_rdata_o[((read_source_index + 1) % 2)*32 +: 32] =
                    {{(32-PRIORITY_WIDTH){1'b0}},
                     priority_q[PRIORITY_WIDTH*read_source_index +:
                                PRIORITY_WIDTH]};
            end

            // Pending and enable bit positions use architectural source IDs,
            // so bit zero remains the hardwired-zero source ID 0.
            if (addr_offset[63:3] ==
                ((PENDING_OFFSET +
                  (((read_source_index + 1) / 32) * 4)) >> 3)) begin
                mem_rdata_o[
                    ((((read_source_index + 1) / 32) % 2) * 32) +
                    ((read_source_index + 1) % 32)] =
                        pending_q[read_source_index];
            end
        end

        for (read_hart_index = 0;
             read_hart_index < NUM_CONTEXTS;
             read_hart_index = read_hart_index + 1) begin
            for (read_source_index = 0;
                 read_source_index < NUM_SOURCES;
                 read_source_index = read_source_index + 1) begin
                if (addr_offset[63:3] ==
                    ((ENABLE_OFFSET +
                      (read_hart_index * ENABLE_STRIDE) +
                      (((read_source_index + 1) / 32) * 4)) >> 3)) begin
                    mem_rdata_o[
                        ((((read_source_index + 1) / 32) % 2) * 32) +
                        ((read_source_index + 1) % 32)] =
                            enable_q[(read_hart_index*NUM_SOURCES) +
                                     read_source_index];
                end
            end

            // Threshold and claim/complete are adjacent 32-bit words.
            if (addr_offset[63:3] ==
                ((CONTEXT_OFFSET +
                  (read_hart_index * CONTEXT_STRIDE)) >> 3)) begin
                mem_rdata_o[31:0] =
                    {{(32-PRIORITY_WIDTH){1'b0}},
                     threshold_q[PRIORITY_WIDTH*read_hart_index +:
                                 PRIORITY_WIDTH]};
                mem_rdata_o[63:32] =
                    selected_id[32*read_hart_index +: 32];
            end
        end
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            priority_q <= {(NUM_SOURCES*PRIORITY_WIDTH){1'b0}};
            pending_q <= {NUM_SOURCES{1'b0}};
            in_service_q <= {NUM_SOURCES{1'b0}};
            enable_q <= {(NUM_CONTEXTS*NUM_SOURCES){1'b0}};
            threshold_q <= {(NUM_CONTEXTS*PRIORITY_WIDTH){1'b0}};
        end else begin
            // A level-sensitive gateway records one request and will not
            // forward the same source again until software completes it.
            for (write_source_index = 0;
                 write_source_index < NUM_SOURCES;
                 write_source_index = write_source_index + 1) begin
                if (irq_sources_i[write_source_index] &&
                    !pending_q[write_source_index] &&
                    !in_service_q[write_source_index]) begin
                    pending_q[write_source_index] <= 1'b1;
                end
            end

            // A claim read atomically returns and clears the selected pending
            // source, then prevents that gateway from re-pending until a
            // completion write is accepted.
            if (read_accept) begin
                for (write_hart_index = 0;
                     write_hart_index < NUM_CONTEXTS;
                     write_hart_index = write_hart_index + 1) begin
                    if (addr_offset[63:2] ==
                        ((CONTEXT_OFFSET +
                          (write_hart_index * CONTEXT_STRIDE) +
                          CLAIM_OFFSET) >> 2)) begin
                        for (write_source_index = 0;
                             write_source_index < NUM_SOURCES;
                             write_source_index = write_source_index + 1) begin
                            if (selected_id[32*write_hart_index +: 32] ==
                                (write_source_index + 1)) begin
                                pending_q[write_source_index] <= 1'b0;
                                in_service_q[write_source_index] <= 1'b1;
                            end
                        end
                    end
                end
            end

            if (write_accept) begin
                for (write_source_index = 0;
                     write_source_index < NUM_SOURCES;
                     write_source_index = write_source_index + 1) begin
                    if ((addr_offset[63:2] ==
                         ((PRIORITY_OFFSET +
                           ((write_source_index + 1) * 4)) >> 2)) &&
                        (&mem_wstrb_i[
                            ((write_source_index + 1) % 2)*4 +: 4])) begin
                        priority_q[PRIORITY_WIDTH*write_source_index +:
                                   PRIORITY_WIDTH] <=
                            mem_wdata_i[
                                ((write_source_index + 1) % 2)*32 +:
                                PRIORITY_WIDTH];
                    end
                end

                for (write_hart_index = 0;
                     write_hart_index < NUM_CONTEXTS;
                     write_hart_index = write_hart_index + 1) begin
                    for (write_source_index = 0;
                         write_source_index < NUM_SOURCES;
                         write_source_index = write_source_index + 1) begin
                        if ((addr_offset[63:2] ==
                             ((ENABLE_OFFSET +
                               (write_hart_index * ENABLE_STRIDE) +
                               (((write_source_index + 1) / 32) * 4)) >> 2)) &&
                            (&mem_wstrb_i[
                                ((((write_source_index + 1) / 32) % 2)*4) +:
                                4])) begin
                            enable_q[(write_hart_index*NUM_SOURCES) +
                                     write_source_index] <=
                                mem_wdata_i[
                                    ((((write_source_index + 1) / 32) % 2)*32) +
                                    ((write_source_index + 1) % 32)];
                        end
                    end

                    if ((addr_offset[63:2] ==
                         ((CONTEXT_OFFSET +
                           (write_hart_index * CONTEXT_STRIDE) +
                           THRESHOLD_OFFSET) >> 2)) &&
                        (&mem_wstrb_i[3:0])) begin
                        threshold_q[PRIORITY_WIDTH*write_hart_index +:
                                    PRIORITY_WIDTH] <=
                            mem_wdata_i[PRIORITY_WIDTH-1:0];
                    end

                    if ((addr_offset[63:2] ==
                         ((CONTEXT_OFFSET +
                           (write_hart_index * CONTEXT_STRIDE) +
                           CLAIM_OFFSET) >> 2)) &&
                        (&mem_wstrb_i[7:4])) begin
                        for (write_source_index = 0;
                             write_source_index < NUM_SOURCES;
                             write_source_index = write_source_index + 1) begin
                            // The PLIC specification permits completion when
                            // the source is enabled for the writing context;
                            // it does not require tracking the claiming hart.
                            if ((mem_wdata_i[63:32] ==
                                 (write_source_index + 1)) &&
                                enable_q[(write_hart_index*NUM_SOURCES) +
                                         write_source_index]) begin
                                in_service_q[write_source_index] <= 1'b0;
                            end
                        end
                    end
                end
            end
        end
    end

endmodule
