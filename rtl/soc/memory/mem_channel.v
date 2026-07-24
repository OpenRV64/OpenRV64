`timescale 1ns/1ps

// Testbench AXI4 memory channel with a replaceable timing backend.
//
// The northbound boundary is an AXI4 slave, not the OpenRV64 internal memory
// handshake.  AR, R, AW, W, and B remain independent; address descriptors are
// queued; IDs and bursts are preserved; and response payloads remain stable
// under backpressure.  One active read burst and one active write burst may
// both have complete-burst commands outstanding to the timing backend.
// Queued transactions are returned in acceptance order, which is legal AXI
// ordering for all IDs.
//
// The southbound timing port is intentionally data-free.  A timing model
// accepts one complete AXI burst, its byte count, and acknowledges when the
// backing-memory access may begin returning or committing data.
// openrv64_timing_ddr3,
// openrv64_timing_ddr4, openrv64_timing_gddr6, and
// openrv64_timing_hbm2 implement this contract and can be swapped without
// changing this module.
//
// This module is a behavioral fixture.  The backing array and initialization
// loop are not intended for synthesis.
module openrv64_mem_channel #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 256,
    parameter integer ID_WIDTH = 4,
    parameter [ADDR_WIDTH-1:0] MEM_BASE = {ADDR_WIDTH{1'b0}},
    parameter integer MEM_BYTES = 16 * 1024 * 1024,
    parameter integer READ_QUEUE_DEPTH = 8,
    parameter integer WRITE_QUEUE_DEPTH = 8,
    parameter integer ZERO_INIT_WORDS = MEM_BYTES / (DATA_WIDTH / 8),
    parameter INIT_FILE = ""
) (
    input  wire                      clk_i,
    input  wire                      rst_ni,

    input  wire [ID_WIDTH-1:0]       s_axi_arid_i,
    input  wire [ADDR_WIDTH-1:0]     s_axi_araddr_i,
    input  wire [7:0]                s_axi_arlen_i,
    input  wire [2:0]                s_axi_arsize_i,
    input  wire [1:0]                s_axi_arburst_i,
    input  wire                      s_axi_arlock_i,
    input  wire [3:0]                s_axi_arcache_i,
    input  wire [2:0]                s_axi_arprot_i,
    input  wire [3:0]                s_axi_arqos_i,
    input  wire                      s_axi_arvalid_i,
    output wire                      s_axi_arready_o,

    output wire [ID_WIDTH-1:0]       s_axi_rid_o,
    output wire [DATA_WIDTH-1:0]     s_axi_rdata_o,
    output wire [1:0]                s_axi_rresp_o,
    output wire                      s_axi_rlast_o,
    output wire                      s_axi_rvalid_o,
    input  wire                      s_axi_rready_i,

    input  wire [ID_WIDTH-1:0]       s_axi_awid_i,
    input  wire [ADDR_WIDTH-1:0]     s_axi_awaddr_i,
    input  wire [7:0]                s_axi_awlen_i,
    input  wire [2:0]                s_axi_awsize_i,
    input  wire [1:0]                s_axi_awburst_i,
    input  wire                      s_axi_awlock_i,
    input  wire [3:0]                s_axi_awcache_i,
    input  wire [2:0]                s_axi_awprot_i,
    input  wire [3:0]                s_axi_awqos_i,
    input  wire                      s_axi_awvalid_i,
    output wire                      s_axi_awready_o,

    input  wire [DATA_WIDTH-1:0]     s_axi_wdata_i,
    input  wire [DATA_WIDTH/8-1:0]   s_axi_wstrb_i,
    input  wire                      s_axi_wlast_i,
    input  wire                      s_axi_wvalid_i,
    output wire                      s_axi_wready_o,

    output wire [ID_WIDTH-1:0]       s_axi_bid_o,
    output wire [1:0]                s_axi_bresp_o,
    output wire                      s_axi_bvalid_o,
    input  wire                      s_axi_bready_i,

    output wire                      timing_cmd_valid_o,
    input  wire                      timing_cmd_ready_i,
    output wire                      timing_cmd_write_o,
    output wire [ADDR_WIDTH-1:0]     timing_cmd_addr_o,
    output wire [15:0]               timing_cmd_bytes_o,
    input  wire                      timing_resp_valid_i,
    output wire                      timing_resp_ready_o
);

    localparam integer DATA_BYTES = DATA_WIDTH / 8;
    localparam integer DATA_BYTE_BITS = $clog2(DATA_BYTES);
    localparam integer WORD_COUNT = MEM_BYTES / DATA_BYTES;
    localparam integer WORD_INDEX_WIDTH =
        (WORD_COUNT > 1) ? $clog2(WORD_COUNT) : 1;
    localparam integer READ_PTR_WIDTH =
        (READ_QUEUE_DEPTH > 1) ? $clog2(READ_QUEUE_DEPTH) : 1;
    localparam integer WRITE_PTR_WIDTH =
        (WRITE_QUEUE_DEPTH > 1) ? $clog2(WRITE_QUEUE_DEPTH) : 1;
    localparam [2:0] AXI_MAX_SIZE = 3'(DATA_BYTE_BITS);
    localparam [READ_PTR_WIDTH:0] READ_QUEUE_CAPACITY =
        (READ_PTR_WIDTH + 1)'(READ_QUEUE_DEPTH);
    localparam [READ_PTR_WIDTH-1:0] READ_LAST_PTR =
        READ_PTR_WIDTH'(READ_QUEUE_DEPTH - 1);
    localparam [WRITE_PTR_WIDTH:0] WRITE_QUEUE_CAPACITY =
        (WRITE_PTR_WIDTH + 1)'(WRITE_QUEUE_DEPTH);
    localparam [WRITE_PTR_WIDTH-1:0] WRITE_LAST_PTR =
        WRITE_PTR_WIDTH'(WRITE_QUEUE_DEPTH - 1);

    localparam [1:0] AXI_RESP_OKAY = 2'b00;
    localparam [1:0] AXI_RESP_SLVERR = 2'b10;
    localparam [1:0] AXI_RESP_DECERR = 2'b11;
    localparam [1:0] AXI_BURST_FIXED = 2'b00;
    localparam [1:0] AXI_BURST_INCR = 2'b01;
    localparam [1:0] AXI_BURST_WRAP = 2'b10;

    reg [DATA_WIDTH-1:0] memory_q [0:WORD_COUNT-1];

    reg [ID_WIDTH-1:0] read_id_fifo_q [0:READ_QUEUE_DEPTH-1];
    reg [ADDR_WIDTH-1:0] read_addr_fifo_q [0:READ_QUEUE_DEPTH-1];
    reg [7:0] read_len_fifo_q [0:READ_QUEUE_DEPTH-1];
    reg [2:0] read_size_fifo_q [0:READ_QUEUE_DEPTH-1];
    reg [1:0] read_burst_fifo_q [0:READ_QUEUE_DEPTH-1];
    reg [1:0] read_resp_fifo_q [0:READ_QUEUE_DEPTH-1];
    reg [READ_PTR_WIDTH-1:0] read_head_q;
    reg [READ_PTR_WIDTH-1:0] read_tail_q;
    reg [READ_PTR_WIDTH:0] read_count_q;

    reg [ID_WIDTH-1:0] write_id_fifo_q [0:WRITE_QUEUE_DEPTH-1];
    reg [ADDR_WIDTH-1:0] write_addr_fifo_q [0:WRITE_QUEUE_DEPTH-1];
    reg [7:0] write_len_fifo_q [0:WRITE_QUEUE_DEPTH-1];
    reg [2:0] write_size_fifo_q [0:WRITE_QUEUE_DEPTH-1];
    reg [1:0] write_burst_fifo_q [0:WRITE_QUEUE_DEPTH-1];
    reg [1:0] write_resp_fifo_q [0:WRITE_QUEUE_DEPTH-1];
    reg [WRITE_PTR_WIDTH-1:0] write_head_q;
    reg [WRITE_PTR_WIDTH-1:0] write_tail_q;
    reg [WRITE_PTR_WIDTH:0] write_count_q;

    reg read_active_q;
    reg [ID_WIDTH-1:0] read_id_q;
    reg [ADDR_WIDTH-1:0] read_addr_q;
    reg [7:0] read_len_q;
    reg [2:0] read_size_q;
    reg [1:0] read_burst_q;
    reg [7:0] read_beat_q;
    reg [1:0] read_request_resp_q;
    reg read_timing_done_q;

    reg write_active_q;
    reg [ID_WIDTH-1:0] write_id_q;
    reg [ADDR_WIDTH-1:0] write_addr_q;
    reg [7:0] write_len_q;
    reg [2:0] write_size_q;
    reg [1:0] write_burst_q;
    reg [7:0] write_beat_q;
    reg [1:0] write_request_resp_q;
    reg write_timing_done_q;

    reg write_data_valid_q;
    reg [DATA_WIDTH-1:0] write_data_q;
    reg [DATA_BYTES-1:0] write_strb_q;
    reg write_last_q;

    reg [ID_WIDTH-1:0] read_response_id_q;
    reg [DATA_WIDTH-1:0] read_response_data_q;
    reg [1:0] read_response_resp_q;
    reg read_response_last_q;
    reg read_response_valid_q;

    reg [ID_WIDTH-1:0] write_response_id_q;
    reg [1:0] write_response_resp_q;
    reg write_response_valid_q;

    reg read_timing_submitted_q;
    reg write_timing_submitted_q;
    reg timing_owner_fifo_q [0:1];
    reg timing_owner_head_q;
    reg timing_owner_tail_q;
    reg [1:0] timing_owner_count_q;
    reg prefer_write_q;

    integer init_index;
    integer write_byte;

    function [ADDR_WIDTH:0] transfer_bytes_of;
        input [2:0] size_value;
        begin
            transfer_bytes_of = {{ADDR_WIDTH{1'b0}}, 1'b1} << size_value;
        end
    endfunction

    function [ADDR_WIDTH-1:0] next_burst_address;
        input [ADDR_WIDTH-1:0] current_address;
        input [7:0] burst_len;
        input [2:0] burst_size;
        input [1:0] burst_type;
        reg [ADDR_WIDTH:0] beat_bytes;
        reg [ADDR_WIDTH:0] burst_bytes;
        reg [ADDR_WIDTH:0] next_address;
        reg [ADDR_WIDTH:0] wrap_base;
        begin
            beat_bytes = transfer_bytes_of(burst_size);
            next_address = {1'b0, current_address} + beat_bytes;
            if (burst_type == AXI_BURST_FIXED) begin
                next_burst_address = current_address;
            end else if (burst_type == AXI_BURST_WRAP) begin
                burst_bytes = beat_bytes *
                    ({{(ADDR_WIDTH-8){1'b0}}, 1'b0, burst_len} + 1'b1);
                wrap_base = {1'b0, current_address} & ~(burst_bytes - 1'b1);
                if (next_address >= (wrap_base + burst_bytes))
                    next_burst_address = wrap_base[ADDR_WIDTH-1:0];
                else
                    next_burst_address = next_address[ADDR_WIDTH-1:0];
            end else begin
                next_burst_address = next_address[ADDR_WIDTH-1:0];
            end
        end
    endfunction

    function [1:0] request_response;
        input [ADDR_WIDTH-1:0] request_address;
        input [7:0] request_len;
        input [2:0] request_size;
        input [1:0] request_burst;
        input request_lock;
        reg [ADDR_WIDTH:0] beat_bytes;
        reg [ADDR_WIDTH:0] burst_bytes;
        reg [ADDR_WIDTH:0] first_byte;
        reg [ADDR_WIDTH:0] last_byte;
        reg [ADDR_WIDTH:0] wrap_base;
        reg [ADDR_WIDTH:0] memory_first;
        reg [ADDR_WIDTH:0] memory_limit;
        begin
            request_response = AXI_RESP_OKAY;
            beat_bytes = transfer_bytes_of(request_size);
            burst_bytes = beat_bytes *
                ({{(ADDR_WIDTH-8){1'b0}}, 1'b0, request_len} + 1'b1);
            first_byte = {1'b0, request_address};
            last_byte = first_byte + beat_bytes - 1'b1;
            wrap_base = first_byte & ~(burst_bytes - 1'b1);
            memory_first = {1'b0, MEM_BASE};
            memory_limit = memory_first + MEM_BYTES;

            if (request_lock || (request_size > AXI_MAX_SIZE) ||
                (request_burst == 2'b11)) begin
                request_response = AXI_RESP_DECERR;
            end else if ((first_byte & (beat_bytes - 1'b1)) != 0) begin
                // The fixture intentionally rejects unaligned transfers rather
                // than guessing at cross-lane narrow-transfer semantics.
                request_response = AXI_RESP_DECERR;
            end else begin
                case (request_burst)
                    AXI_BURST_FIXED: begin
                        if (request_len > 8'd15)
                            request_response = AXI_RESP_DECERR;
                        last_byte = first_byte + beat_bytes - 1'b1;
                    end
                    AXI_BURST_INCR:
                        last_byte = first_byte + burst_bytes - 1'b1;
                    AXI_BURST_WRAP: begin
                        if (!((request_len == 8'd1) ||
                              (request_len == 8'd3) ||
                              (request_len == 8'd7) ||
                              (request_len == 8'd15)))
                            request_response = AXI_RESP_DECERR;
                        last_byte = wrap_base + burst_bytes - 1'b1;
                    end
                    default:
                        request_response = AXI_RESP_DECERR;
                endcase

                if ((first_byte < memory_first) ||
                    (last_byte >= memory_limit) ||
                    (first_byte[ADDR_WIDTH:12] !=
                     last_byte[ADDR_WIDTH:12]))
                    request_response = AXI_RESP_DECERR;
            end
        end
    endfunction

    function [DATA_BYTES-1:0] transfer_lane_mask;
        input [ADDR_WIDTH-1:0] transfer_address;
        input [2:0] transfer_size;
        integer lane_index;
        integer first_lane;
        integer lane_count;
        begin
            transfer_lane_mask = {DATA_BYTES{1'b0}};
            first_lane = transfer_address & (DATA_BYTES - 1);
            lane_count = 1 << transfer_size;
            for (lane_index = 0; lane_index < DATA_BYTES;
                 lane_index = lane_index + 1) begin
                if ((lane_index >= first_lane) &&
                    (lane_index < (first_lane + lane_count)))
                    transfer_lane_mask[lane_index] = 1'b1;
            end
        end
    endfunction

    function [WORD_INDEX_WIDTH-1:0] memory_index_of;
        input [ADDR_WIDTH-1:0] byte_address;
        reg [ADDR_WIDTH-1:0] local_address;
        begin
            local_address = byte_address - MEM_BASE;
            memory_index_of =
                local_address[DATA_BYTE_BITS +: WORD_INDEX_WIDTH];
        end
    endfunction

    wire [1:0] incoming_read_resp = request_response(
        s_axi_araddr_i, s_axi_arlen_i, s_axi_arsize_i,
        s_axi_arburst_i, s_axi_arlock_i);
    wire [1:0] incoming_write_resp = request_response(
        s_axi_awaddr_i, s_axi_awlen_i, s_axi_awsize_i,
        s_axi_awburst_i, s_axi_awlock_i);

    wire read_address_fire = s_axi_arvalid_i && s_axi_arready_o;
    wire write_address_fire = s_axi_awvalid_i && s_axi_awready_o;
    wire write_data_fire = s_axi_wvalid_i && s_axi_wready_o;
    wire read_response_fire = s_axi_rvalid_o && s_axi_rready_i;
    wire write_response_fire = s_axi_bvalid_o && s_axi_bready_i;

    wire activate_read = !read_active_q &&
                         (read_count_q != 0);
    wire activate_write = !write_active_q && !write_response_valid_q &&
                          (write_count_q != 0);

    wire read_command_pending = read_active_q &&
        !read_response_valid_q &&
        !read_timing_submitted_q &&
        !read_timing_done_q &&
        (read_request_resp_q == AXI_RESP_OKAY);
    wire write_command_pending = write_active_q && write_data_valid_q &&
        !write_timing_submitted_q &&
        !write_timing_done_q &&
        (write_request_resp_q == AXI_RESP_OKAY);
    wire select_write_command = write_command_pending &&
        (!read_command_pending || prefer_write_q);
    wire timing_command_fire = timing_cmd_valid_o && timing_cmd_ready_i;
    wire timing_response_fire = timing_resp_valid_i &&
                                timing_resp_ready_o;
    wire timing_response_owner_write =
        timing_owner_fifo_q[timing_owner_head_q];
    wire current_write_last = write_last_q ||
                              (write_beat_q == write_len_q);

    assign s_axi_arready_o = rst_ni &&
        (read_count_q < READ_QUEUE_CAPACITY);
    assign s_axi_awready_o = rst_ni &&
        (write_count_q < WRITE_QUEUE_CAPACITY);
    assign s_axi_wready_o = rst_ni && write_active_q &&
        !write_data_valid_q && !write_response_valid_q;

    assign s_axi_rid_o = read_response_id_q;
    assign s_axi_rdata_o = read_response_data_q;
    assign s_axi_rresp_o = read_response_resp_q;
    assign s_axi_rlast_o = read_response_last_q;
    assign s_axi_rvalid_o = read_response_valid_q;

    assign s_axi_bid_o = write_response_id_q;
    assign s_axi_bresp_o = write_response_resp_q;
    assign s_axi_bvalid_o = write_response_valid_q;

    assign timing_cmd_valid_o = rst_ni && (timing_owner_count_q < 2) &&
        (read_command_pending || write_command_pending);
    assign timing_cmd_write_o = select_write_command;
    assign timing_cmd_addr_o = select_write_command ? write_addr_q :
                                                      read_addr_q;
    wire [15:0] read_burst_bytes =
        ({8'd0, read_len_q} + 16'd1) << read_size_q;
    wire [15:0] write_burst_bytes =
        ({8'd0, write_len_q} + 16'd1) << write_size_q;
    assign timing_cmd_bytes_o = select_write_command ?
        write_burst_bytes : read_burst_bytes;
    assign timing_resp_ready_o = (timing_owner_count_q != 0);

    // These AXI attributes do not alter behavioral storage or timing yet.
    wire unused_axi_attributes = ^{s_axi_arcache_i, s_axi_arprot_i,
        s_axi_arqos_i, s_axi_awcache_i, s_axi_awprot_i, s_axi_awqos_i};

    initial begin
        if ((ADDR_WIDTH < 16) || (ADDR_WIDTH > 64))
            $fatal(1, "memory-channel AXI address width must be 16 through 64");
        if ((DATA_WIDTH < 32) || (DATA_WIDTH > 512) ||
            ((DATA_WIDTH & (DATA_WIDTH - 1)) != 0))
            $fatal(1, "memory-channel AXI data width must be 32, 64, 128, 256, or 512");
        if (ID_WIDTH < 1)
            $fatal(1, "memory-channel AXI ID width must be positive");
        if ((MEM_BYTES < DATA_BYTES) || ((MEM_BYTES % DATA_BYTES) != 0))
            $fatal(1, "memory-channel capacity must contain complete data beats");
        if ((MEM_BASE & (DATA_BYTES - 1)) != 0)
            $fatal(1, "memory-channel base must be data-beat aligned");
        if ((READ_QUEUE_DEPTH < 1) || (WRITE_QUEUE_DEPTH < 1))
            $fatal(1, "memory-channel queue depths must be positive");
        if ((ZERO_INIT_WORDS < 0) || (ZERO_INIT_WORDS > WORD_COUNT))
            $fatal(1, "memory-channel zero-init count exceeds capacity");

        for (init_index = 0; init_index < ZERO_INIT_WORDS;
             init_index = init_index + 1)
            memory_q[init_index] = {DATA_WIDTH{1'b0}};
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, memory_q);
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_head_q <= {READ_PTR_WIDTH{1'b0}};
            read_tail_q <= {READ_PTR_WIDTH{1'b0}};
            read_count_q <= {(READ_PTR_WIDTH+1){1'b0}};
            write_head_q <= {WRITE_PTR_WIDTH{1'b0}};
            write_tail_q <= {WRITE_PTR_WIDTH{1'b0}};
            write_count_q <= {(WRITE_PTR_WIDTH+1){1'b0}};

            read_active_q <= 1'b0;
            read_id_q <= {ID_WIDTH{1'b0}};
            read_addr_q <= {ADDR_WIDTH{1'b0}};
            read_len_q <= 8'd0;
            read_size_q <= 3'd0;
            read_burst_q <= AXI_BURST_INCR;
            read_beat_q <= 8'd0;
            read_request_resp_q <= AXI_RESP_OKAY;
            read_timing_done_q <= 1'b0;
            read_timing_submitted_q <= 1'b0;

            write_active_q <= 1'b0;
            write_id_q <= {ID_WIDTH{1'b0}};
            write_addr_q <= {ADDR_WIDTH{1'b0}};
            write_len_q <= 8'd0;
            write_size_q <= 3'd0;
            write_burst_q <= AXI_BURST_INCR;
            write_beat_q <= 8'd0;
            write_request_resp_q <= AXI_RESP_OKAY;
            write_timing_done_q <= 1'b0;
            write_timing_submitted_q <= 1'b0;
            write_data_valid_q <= 1'b0;
            write_data_q <= {DATA_WIDTH{1'b0}};
            write_strb_q <= {DATA_BYTES{1'b0}};
            write_last_q <= 1'b0;

            read_response_id_q <= {ID_WIDTH{1'b0}};
            read_response_data_q <= {DATA_WIDTH{1'b0}};
            read_response_resp_q <= AXI_RESP_OKAY;
            read_response_last_q <= 1'b0;
            read_response_valid_q <= 1'b0;
            write_response_id_q <= {ID_WIDTH{1'b0}};
            write_response_resp_q <= AXI_RESP_OKAY;
            write_response_valid_q <= 1'b0;

            timing_owner_fifo_q[0] <= 1'b0;
            timing_owner_fifo_q[1] <= 1'b0;
            timing_owner_head_q <= 1'b0;
            timing_owner_tail_q <= 1'b0;
            timing_owner_count_q <= 2'd0;
            prefer_write_q <= 1'b0;
        end else begin
            if (read_address_fire) begin
                read_id_fifo_q[read_tail_q] <= s_axi_arid_i;
                read_addr_fifo_q[read_tail_q] <= s_axi_araddr_i;
                read_len_fifo_q[read_tail_q] <= s_axi_arlen_i;
                read_size_fifo_q[read_tail_q] <= s_axi_arsize_i;
                read_burst_fifo_q[read_tail_q] <= s_axi_arburst_i;
                read_resp_fifo_q[read_tail_q] <= incoming_read_resp;
                if (read_tail_q == READ_LAST_PTR)
                    read_tail_q <= {READ_PTR_WIDTH{1'b0}};
                else
                    read_tail_q <= read_tail_q + 1'b1;
            end

            if (activate_read) begin
                read_active_q <= 1'b1;
                read_id_q <= read_id_fifo_q[read_head_q];
                read_addr_q <= read_addr_fifo_q[read_head_q];
                read_len_q <= read_len_fifo_q[read_head_q];
                read_size_q <= read_size_fifo_q[read_head_q];
                read_burst_q <= read_burst_fifo_q[read_head_q];
                read_beat_q <= 8'd0;
                read_request_resp_q <= read_resp_fifo_q[read_head_q];
                read_timing_done_q <= 1'b0;
                read_timing_submitted_q <= 1'b0;
                if (read_head_q == READ_LAST_PTR)
                    read_head_q <= {READ_PTR_WIDTH{1'b0}};
                else
                    read_head_q <= read_head_q + 1'b1;
            end

            case ({read_address_fire, activate_read})
                2'b10: read_count_q <= read_count_q + 1'b1;
                2'b01: read_count_q <= read_count_q - 1'b1;
                default: begin end
            endcase

            if (write_address_fire) begin
                write_id_fifo_q[write_tail_q] <= s_axi_awid_i;
                write_addr_fifo_q[write_tail_q] <= s_axi_awaddr_i;
                write_len_fifo_q[write_tail_q] <= s_axi_awlen_i;
                write_size_fifo_q[write_tail_q] <= s_axi_awsize_i;
                write_burst_fifo_q[write_tail_q] <= s_axi_awburst_i;
                write_resp_fifo_q[write_tail_q] <= incoming_write_resp;
                if (write_tail_q == WRITE_LAST_PTR)
                    write_tail_q <= {WRITE_PTR_WIDTH{1'b0}};
                else
                    write_tail_q <= write_tail_q + 1'b1;
            end

            if (activate_write) begin
                write_active_q <= 1'b1;
                write_id_q <= write_id_fifo_q[write_head_q];
                write_addr_q <= write_addr_fifo_q[write_head_q];
                write_len_q <= write_len_fifo_q[write_head_q];
                write_size_q <= write_size_fifo_q[write_head_q];
                write_burst_q <= write_burst_fifo_q[write_head_q];
                write_beat_q <= 8'd0;
                write_request_resp_q <= write_resp_fifo_q[write_head_q];
                write_timing_done_q <= 1'b0;
                write_timing_submitted_q <= 1'b0;
                if (write_head_q == WRITE_LAST_PTR)
                    write_head_q <= {WRITE_PTR_WIDTH{1'b0}};
                else
                    write_head_q <= write_head_q + 1'b1;
            end

            case ({write_address_fire, activate_write})
                2'b10: write_count_q <= write_count_q + 1'b1;
                2'b01: write_count_q <= write_count_q - 1'b1;
                default: begin end
            endcase

            if (write_data_fire) begin
                write_data_valid_q <= 1'b1;
                write_data_q <= s_axi_wdata_i;
                write_strb_q <= s_axi_wstrb_i;
                write_last_q <= s_axi_wlast_i;
                if ((s_axi_wlast_i != (write_beat_q == write_len_q)) ||
                    |(s_axi_wstrb_i &
                      ~transfer_lane_mask(write_addr_q, write_size_q)))
                    write_request_resp_q <= AXI_RESP_SLVERR;
            end

            if (read_response_fire) begin
                read_response_valid_q <= 1'b0;
                if (read_response_last_q) begin
                    read_active_q <= 1'b0;
                end else begin
                    read_beat_q <= read_beat_q + 1'b1;
                    read_addr_q <= next_burst_address(
                        read_addr_q, read_len_q, read_size_q,
                        read_burst_q);
                end
            end

            if (write_response_fire)
                write_response_valid_q <= 1'b0;

            if (timing_command_fire) begin
                timing_owner_fifo_q[timing_owner_tail_q] <=
                    select_write_command;
                timing_owner_tail_q <= !timing_owner_tail_q;
                if (select_write_command)
                    write_timing_submitted_q <= 1'b1;
                else
                    read_timing_submitted_q <= 1'b1;
                prefer_write_q <= !select_write_command;
            end

            if (timing_response_fire) begin
                timing_owner_head_q <= !timing_owner_head_q;
                if (timing_response_owner_write) begin
                    write_timing_submitted_q <= 1'b0;
                    write_timing_done_q <= 1'b1;
                    for (write_byte = 0; write_byte < DATA_BYTES;
                         write_byte = write_byte + 1) begin
                        if (write_strb_q[write_byte])
                            memory_q[memory_index_of(write_addr_q)]
                                    [8*write_byte +: 8] <=
                                write_data_q[8*write_byte +: 8];
                    end
                    write_data_valid_q <= 1'b0;
                    if (current_write_last) begin
                        write_active_q <= 1'b0;
                        write_timing_done_q <= 1'b0;
                        write_response_id_q <= write_id_q;
                        write_response_resp_q <= write_request_resp_q;
                        write_response_valid_q <= 1'b1;
                    end else begin
                        write_beat_q <= write_beat_q + 1'b1;
                        write_addr_q <= next_burst_address(
                            write_addr_q, write_len_q, write_size_q,
                            write_burst_q);
                    end
                end else begin
                    read_timing_submitted_q <= 1'b0;
                    read_timing_done_q <= 1'b1;
                    read_response_id_q <= read_id_q;
                    read_response_data_q <=
                        memory_q[memory_index_of(read_addr_q)];
                    read_response_resp_q <= AXI_RESP_OKAY;
                    read_response_last_q <= (read_beat_q == read_len_q);
                    read_response_valid_q <= 1'b1;
                end
            end

            case ({timing_command_fire, timing_response_fire})
                2'b10:
                    timing_owner_count_q <= timing_owner_count_q + 1'b1;
                2'b01:
                    timing_owner_count_q <= timing_owner_count_q - 1'b1;
                default: begin end
            endcase

            // DRAM schedules the complete burst once.  After that completion,
            // AXI data beats drain at the controller interface rate without
            // charging row/column timing again for each bus-width fragment.
            if (read_active_q && read_timing_done_q &&
                !read_response_valid_q &&
                (read_request_resp_q == AXI_RESP_OKAY)) begin
                read_response_id_q <= read_id_q;
                read_response_data_q <=
                    memory_q[memory_index_of(read_addr_q)];
                read_response_resp_q <= AXI_RESP_OKAY;
                read_response_last_q <= (read_beat_q == read_len_q);
                read_response_valid_q <= 1'b1;
            end

            if (write_active_q && write_timing_done_q &&
                write_data_valid_q &&
                (write_request_resp_q == AXI_RESP_OKAY)) begin
                for (write_byte = 0; write_byte < DATA_BYTES;
                     write_byte = write_byte + 1) begin
                    if (write_strb_q[write_byte])
                        memory_q[memory_index_of(write_addr_q)]
                                [8*write_byte +: 8] <=
                            write_data_q[8*write_byte +: 8];
                end
                write_data_valid_q <= 1'b0;
                if (current_write_last) begin
                    write_active_q <= 1'b0;
                    write_timing_done_q <= 1'b0;
                    write_response_id_q <= write_id_q;
                    write_response_resp_q <= write_request_resp_q;
                    write_response_valid_q <= 1'b1;
                end else begin
                    write_beat_q <= write_beat_q + 1'b1;
                    write_addr_q <= next_burst_address(
                        write_addr_q, write_len_q, write_size_q,
                        write_burst_q);
                end
            end

            // Decode/protocol errors still obey AXI burst cardinality, but do
            // not consume DRAM timing or touch the backing store.
            if (read_active_q && !read_response_valid_q &&
                (read_request_resp_q != AXI_RESP_OKAY)) begin
                read_response_id_q <= read_id_q;
                read_response_data_q <= {DATA_WIDTH{1'b0}};
                read_response_resp_q <= read_request_resp_q;
                read_response_last_q <= (read_beat_q == read_len_q);
                read_response_valid_q <= 1'b1;
            end

            if (write_active_q && write_data_valid_q &&
                (write_request_resp_q != AXI_RESP_OKAY)) begin
                write_data_valid_q <= 1'b0;
                if (current_write_last) begin
                    write_active_q <= 1'b0;
                    write_response_id_q <= write_id_q;
                    write_response_resp_q <= write_request_resp_q;
                    write_response_valid_q <= 1'b1;
                end else begin
                    write_beat_q <= write_beat_q + 1'b1;
                    write_addr_q <= next_burst_address(
                        write_addr_q, write_len_q, write_size_q,
                        write_burst_q);
                end
            end

            if (timing_resp_valid_i && (timing_owner_count_q == 0))
                $fatal(1, "memory-channel timing backend produced an unsolicited response");
        end
    end

endmodule
