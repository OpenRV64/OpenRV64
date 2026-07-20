`timescale 1ns/1ps
`include "core/bus/bus-defs.v"
`include "core/isa/rv64-i.v"
`include "soc/bus/mem_map.v"

// Testbench-only 256-bit AXI fabric.  RAM is a native 256-bit AXI target: one
// AR/R transfer fetches a complete 32-byte line and WSTRB directly controls
// all 32 RAM bytes.  Non-RAM addresses take the second fabric branch into the
// existing 64-bit SoC peripheral bus; LSU-sized MMIO is lane-adapted there.
module tb_axi256_soc_fabric #(
    parameter integer READ_QUEUE_DEPTH = 8,
    parameter integer RAM_BYTES = 16 * 1024 * 1024
) (
    input  wire        clk_i,
    input  wire        rst_ni,

    input  wire [`OPENRV64_AXI_ID_WIDTH-1:0]   s_axi_arid_i,
    input  wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] s_axi_araddr_i,
    input  wire [7:0]  s_axi_arlen_i,
    input  wire [2:0]  s_axi_arsize_i,
    input  wire [1:0]  s_axi_arburst_i,
    input  wire        s_axi_arvalid_i,
    output wire        s_axi_arready_o,

    output wire [`OPENRV64_AXI_ID_WIDTH-1:0]   s_axi_rid_o,
    output wire [`OPENRV64_AXI_DATA_WIDTH-1:0] s_axi_rdata_o,
    output wire [1:0]  s_axi_rresp_o,
    output wire        s_axi_rlast_o,
    output wire        s_axi_rvalid_o,
    input  wire        s_axi_rready_i,

    input  wire [`OPENRV64_AXI_ID_WIDTH-1:0]   s_axi_awid_i,
    input  wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] s_axi_awaddr_i,
    input  wire [7:0]  s_axi_awlen_i,
    input  wire [2:0]  s_axi_awsize_i,
    input  wire [1:0]  s_axi_awburst_i,
    input  wire        s_axi_awvalid_i,
    output wire        s_axi_awready_o,

    input  wire [`OPENRV64_AXI_DATA_WIDTH-1:0] s_axi_wdata_i,
    input  wire [`OPENRV64_AXI_STRB_WIDTH-1:0] s_axi_wstrb_i,
    input  wire        s_axi_wlast_i,
    input  wire        s_axi_wvalid_i,
    output wire        s_axi_wready_o,

    output wire [`OPENRV64_AXI_ID_WIDTH-1:0]   s_axi_bid_o,
    output wire [1:0]  s_axi_bresp_o,
    output wire        s_axi_bvalid_o,
    input  wire        s_axi_bready_i,

    output wire        mem_valid_o,
    input  wire        mem_ready_i,
    output wire        mem_write_o,
    output wire [63:0] mem_addr_o,
    output wire [63:0] mem_wdata_o,
    output wire [7:0]  mem_wstrb_o,
    input  wire [63:0] mem_rdata_i,
    input  wire        mem_error_i
);

    localparam integer READ_PTR_WIDTH = $clog2(READ_QUEUE_DEPTH);
    localparam integer RAM_LINE_COUNT = RAM_BYTES / 32;
    localparam integer RAM_LINE_INDEX_WIDTH = $clog2(RAM_LINE_COUNT);
    localparam [1:0] BUS_IDLE  = 2'd0;
    localparam [1:0] BUS_READ  = 2'd1;
    localparam [1:0] BUS_WRITE = 2'd2;

    reg [`OPENRV64_AXI_ID_WIDTH-1:0] read_id_q
        [0:READ_QUEUE_DEPTH-1];
    reg [`OPENRV64_AXI_ADDR_WIDTH-1:0] read_addr_q
        [0:READ_QUEUE_DEPTH-1];
    reg [READ_PTR_WIDTH-1:0] read_head_q;
    reg [READ_PTR_WIDTH-1:0] read_tail_q;
    reg [READ_PTR_WIDTH:0] read_count_q;

    reg [`OPENRV64_AXI_ID_WIDTH-1:0] current_read_id_q;
    reg [`OPENRV64_AXI_ADDR_WIDTH-1:0] current_read_addr_q;
    reg [`OPENRV64_AXI_DATA_WIDTH-1:0] ram_q [0:RAM_LINE_COUNT-1];

    reg aw_pending_q;
    reg [`OPENRV64_AXI_ID_WIDTH-1:0] aw_id_q;
    reg [`OPENRV64_AXI_ADDR_WIDTH-1:0] aw_addr_q;
    reg w_pending_q;
    reg [`OPENRV64_AXI_DATA_WIDTH-1:0] w_data_q;
    reg [`OPENRV64_AXI_STRB_WIDTH-1:0] w_strb_q;

    reg [1:0] bus_state_q;
    reg [`OPENRV64_AXI_ID_WIDTH-1:0] r_id_q;
    reg [`OPENRV64_AXI_DATA_WIDTH-1:0] r_data_q;
    reg [1:0] r_resp_q;
    reg r_valid_q;
    reg [`OPENRV64_AXI_ID_WIDTH-1:0] b_id_q;
    reg [1:0] b_resp_q;
    reg b_valid_q;
    integer ram_init_index;
    integer write_byte;

    wire ar_fire = s_axi_arvalid_i && s_axi_arready_o;
    wire aw_fire = s_axi_awvalid_i && s_axi_awready_o;
    wire w_fire = s_axi_wvalid_i && s_axi_wready_o;
    wire r_fire = s_axi_rvalid_o && s_axi_rready_i;
    wire b_fire = s_axi_bvalid_o && s_axi_bready_i;

    wire start_write = (bus_state_q == BUS_IDLE) && !b_valid_q &&
                       aw_pending_q && w_pending_q;
    wire start_read = (bus_state_q == BUS_IDLE) && !start_write &&
                      (!r_valid_q || r_fire) && (read_count_q != 0);

    wire [1:0] write_lane = aw_addr_q[4:3];
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] shifted_write_data =
        w_data_q >> {write_lane, 6'b000000};
    wire [`OPENRV64_AXI_STRB_WIDTH-1:0] shifted_write_strb =
        w_strb_q >> {write_lane, 3'b000};
    wire current_read_is_ram =
        (current_read_addr_q >= `OPENRV64_SOC_MEMORY_BASE) &&
        (current_read_addr_q < (`OPENRV64_SOC_MEMORY_BASE + RAM_BYTES));
    wire current_write_is_ram =
        (aw_addr_q >= `OPENRV64_SOC_MEMORY_BASE) &&
        (aw_addr_q < (`OPENRV64_SOC_MEMORY_BASE + RAM_BYTES));
    wire queued_read_is_ram =
        (read_addr_q[read_head_q] >= `OPENRV64_SOC_MEMORY_BASE) &&
        (read_addr_q[read_head_q] <
         (`OPENRV64_SOC_MEMORY_BASE + RAM_BYTES));
    wire [RAM_LINE_INDEX_WIDTH-1:0] queued_read_ram_index =
        read_addr_q[read_head_q][RAM_LINE_INDEX_WIDTH+4:5];
    wire [RAM_LINE_INDEX_WIDTH-1:0] current_write_ram_index =
        aw_addr_q[RAM_LINE_INDEX_WIDTH+4:5];

    initial begin
        for (ram_init_index = 0; ram_init_index < RAM_LINE_COUNT;
             ram_init_index = ram_init_index + 1)
            ram_q[ram_init_index] = {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
    end

    assign s_axi_arready_o = rst_ni &&
        (read_count_q < READ_QUEUE_DEPTH);
    assign s_axi_rid_o = r_id_q;
    assign s_axi_rdata_o = r_data_q;
    assign s_axi_rresp_o = r_resp_q;
    assign s_axi_rlast_o = 1'b1;
    assign s_axi_rvalid_o = r_valid_q;

    assign s_axi_awready_o = rst_ni && !aw_pending_q;
    assign s_axi_wready_o = rst_ni && !w_pending_q;
    assign s_axi_bid_o = b_id_q;
    assign s_axi_bresp_o = b_resp_q;
    assign s_axi_bvalid_o = b_valid_q;

    assign mem_valid_o = ((bus_state_q == BUS_READ) &&
                          !current_read_is_ram) ||
                         ((bus_state_q == BUS_WRITE) &&
                          !current_write_is_ram);
    assign mem_write_o = (bus_state_q == BUS_WRITE);
    assign mem_addr_o = (bus_state_q == BUS_READ) ?
                        current_read_addr_q : aw_addr_q;
    assign mem_wdata_o = shifted_write_data[63:0];
    assign mem_wstrb_o = shifted_write_strb[7:0];

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_head_q <= {READ_PTR_WIDTH{1'b0}};
            read_tail_q <= {READ_PTR_WIDTH{1'b0}};
            read_count_q <= {(READ_PTR_WIDTH+1){1'b0}};
            current_read_id_q <= {`OPENRV64_AXI_ID_WIDTH{1'b0}};
            current_read_addr_q <= {`OPENRV64_AXI_ADDR_WIDTH{1'b0}};
            aw_pending_q <= 1'b0;
            aw_id_q <= {`OPENRV64_AXI_ID_WIDTH{1'b0}};
            aw_addr_q <= {`OPENRV64_AXI_ADDR_WIDTH{1'b0}};
            w_pending_q <= 1'b0;
            w_data_q <= {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
            w_strb_q <= {`OPENRV64_AXI_STRB_WIDTH{1'b0}};
            bus_state_q <= BUS_IDLE;
            r_id_q <= {`OPENRV64_AXI_ID_WIDTH{1'b0}};
            r_data_q <= {`OPENRV64_AXI_DATA_WIDTH{1'b0}};
            r_resp_q <= 2'b00;
            r_valid_q <= 1'b0;
            b_id_q <= {`OPENRV64_AXI_ID_WIDTH{1'b0}};
            b_resp_q <= 2'b00;
            b_valid_q <= 1'b0;
        end else begin
            if (ar_fire) begin
                read_id_q[read_tail_q] <= s_axi_arid_i;
                read_addr_q[read_tail_q] <= s_axi_araddr_i;
                read_tail_q <= read_tail_q + 1'b1;

                if ((s_axi_arlen_i != 8'd0) ||
                    (s_axi_arburst_i != 2'b01) ||
                    (s_axi_arsize_i > 3'd5)) begin
                    $fatal(1, "unsupported AXI read geometry");
                end
            end

            case ({ar_fire, start_read})
                2'b10: read_count_q <= read_count_q + 1'b1;
                2'b01: read_count_q <= read_count_q - 1'b1;
                default: begin end
            endcase

            if (aw_fire) begin
                aw_pending_q <= 1'b1;
                aw_id_q <= s_axi_awid_i;
                aw_addr_q <= s_axi_awaddr_i;
                if ((s_axi_awlen_i != 8'd0) ||
                    (s_axi_awburst_i != 2'b01) ||
                    (s_axi_awsize_i > 3'd3)) begin
                    $fatal(1, "unsupported AXI write geometry");
                end
            end

            if (w_fire) begin
                if (!s_axi_wlast_i)
                    $fatal(1, "single-beat AXI write omitted WLAST");
                w_pending_q <= 1'b1;
                w_data_q <= s_axi_wdata_i;
                w_strb_q <= s_axi_wstrb_i;
            end

            if (r_fire)
                r_valid_q <= 1'b0;
            if (b_fire)
                b_valid_q <= 1'b0;

            if (start_write) begin
                bus_state_q <= BUS_WRITE;
            end else if (start_read) begin
                read_head_q <= read_head_q + 1'b1;
                if (queued_read_is_ram) begin
                    r_id_q <= read_id_q[read_head_q];
                    r_data_q <= ram_q[queued_read_ram_index];
                    r_resp_q <= 2'b00;
                    r_valid_q <= 1'b1;
                    bus_state_q <= BUS_IDLE;
                end else begin
                    current_read_id_q <= read_id_q[read_head_q];
                    current_read_addr_q <= read_addr_q[read_head_q];
                    bus_state_q <= BUS_READ;
                end
            end else if (bus_state_q == BUS_READ) begin
                if (mem_ready_i) begin
                    r_id_q <= current_read_id_q;
                    r_data_q <=
                        {{(`OPENRV64_AXI_DATA_WIDTH-64){1'b0}}, mem_rdata_i}
                        << {current_read_addr_q[4:3], 6'b000000};
                    r_resp_q <= mem_error_i ? 2'b10 : 2'b00;
                    r_valid_q <= 1'b1;
                    bus_state_q <= BUS_IDLE;
                end
            end else if (bus_state_q == BUS_WRITE) begin
                if (current_write_is_ram) begin
                    for (write_byte = 0; write_byte < 32;
                         write_byte = write_byte + 1) begin
                        if (w_strb_q[write_byte]) begin
                            ram_q[current_write_ram_index]
                                 [write_byte*8 +: 8] <=
                                w_data_q[write_byte*8 +: 8];
                        end
                    end
                    b_id_q <= aw_id_q;
                    b_resp_q <= 2'b00;
                    b_valid_q <= 1'b1;
                    aw_pending_q <= 1'b0;
                    w_pending_q <= 1'b0;
                    bus_state_q <= BUS_IDLE;
                end else if (mem_ready_i) begin
                    b_id_q <= aw_id_q;
                    b_resp_q <= mem_error_i ? 2'b10 : 2'b00;
                    b_valid_q <= 1'b1;
                    aw_pending_q <= 1'b0;
                    w_pending_q <= 1'b0;
                    bus_state_q <= BUS_IDLE;
                end
            end
        end
    end

endmodule

module tb_top_axi_3p #(
    parameter [`OPENRV64_BP_TYPE_WIDTH-1:0] BP_TYPE =
        `OPENRV64_BP_STALL,
    parameter integer BP_RAS_ENABLE = 1,
    parameter integer BP_RAS_DEPTH = 8,
    parameter integer BP_BIMODAL_ENTRIES = 32,
    parameter integer BP_BIMODAL_COUNTER_BITS = 3,
    parameter integer BP_BIMODAL_UPDATE_DEPTH = 4,
    parameter integer BP_GSHARE_ENTRIES = 256,
    parameter integer BP_GSHARE_COUNTER_BITS = 3,
    parameter integer BP_BTB_ENTRIES = 256,
    parameter integer BP_BTB_TAG_BITS = 16,
    parameter integer BP_INFLIGHT_DEPTH = 16,
    parameter integer RETIRE_DEPTH = 8,
    parameter [2:0] COMPLETION_FORWARD_MASK = 3'b000,
    parameter [2:0] BRANCH_FORWARD_MASK = 3'b111,
    parameter integer FULL_FORWARDING = 0,
    parameter integer RELAX_WAW = 1,
    parameter integer RELAX_HAZARDS = 0,
    parameter integer ISSUE_WINDOW = 0,
    parameter integer SPECULATION_WINDOW = 0,
    parameter integer POSTED_STORES = 1,
    parameter integer FREE_BRANCHES = 0,
    parameter integer EQ_BRANCH_PAIRING = 1,
    parameter integer ORACLE_BRANCHES = 0
);
    reg clk;
    reg rst_n;

    wire [`OPENRV64_AXI_ID_WIDTH-1:0] arid;
    wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] araddr;
    wire [7:0] arlen;
    wire [2:0] arsize;
    wire [1:0] arburst;
    wire arvalid;
    wire arready;
    wire [`OPENRV64_AXI_ID_WIDTH-1:0] rid;
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] rdata;
    wire [1:0] rresp;
    wire rlast;
    wire rvalid;
    wire rready;

    wire [`OPENRV64_AXI_ID_WIDTH-1:0] awid;
    wire [`OPENRV64_AXI_ADDR_WIDTH-1:0] awaddr;
    wire [7:0] awlen;
    wire [2:0] awsize;
    wire [1:0] awburst;
    wire awvalid;
    wire awready;
    wire [`OPENRV64_AXI_DATA_WIDTH-1:0] wdata;
    wire [`OPENRV64_AXI_STRB_WIDTH-1:0] wstrb;
    wire wlast;
    wire wvalid;
    wire wready;
    wire [`OPENRV64_AXI_ID_WIDTH-1:0] bid;
    wire [1:0] bresp;
    wire bvalid;
    wire bready;

    wire bus_valid;
    wire bus_ready;
    wire bus_write;
    wire [63:0] bus_addr;
    wire [63:0] bus_wdata;
    wire [7:0] bus_wstrb;
    wire [63:0] bus_rdata;
    wire bus_error;

    wire rom_valid;
    wire rom_ready;
    wire rom_write;
    wire [63:0] rom_addr;
    wire [63:0] rom_wdata;
    wire [7:0] rom_wstrb;
    wire [63:0] rom_rdata;

    wire memory_valid;
    wire memory_ready;
    wire memory_write;
    wire [63:0] memory_addr;
    wire [63:0] memory_wdata;
    wire [7:0] memory_wstrb;
    wire [63:0] memory_rdata;

    wire clint_valid;
    wire clint_ready;
    wire clint_write;
    wire [63:0] clint_addr;
    wire [63:0] clint_wdata;
    wire [7:0] clint_wstrb;
    wire [63:0] clint_rdata;

    wire plic_valid;
    wire plic_ready;
    wire plic_write;
    wire [63:0] plic_addr;
    wire [63:0] plic_wdata;
    wire [7:0] plic_wstrb;
    wire [63:0] plic_rdata;

    wire uart_valid;
    wire uart_ready;
    wire uart_write;
    wire [63:0] uart_addr;
    wire [63:0] uart_wdata;
    wire [7:0] uart_wstrb;
    wire [63:0] uart_rdata;

    wire gpio_valid;
    wire gpio_ready;
    wire gpio_write;
    wire [63:0] gpio_addr;
    wire [63:0] gpio_wdata;
    wire [7:0] gpio_wstrb;
    wire [63:0] gpio_rdata;

    wire timer_valid;
    wire timer_ready;
    wire timer_write;
    wire [63:0] timer_addr;
    wire [63:0] timer_wdata;
    wire [7:0] timer_wstrb;
    wire [63:0] timer_rdata;

    wire [0:0] clint_msip;
    wire [0:0] clint_mtip;
    wire [63:0] clint_mtime;
    wire [0:0] plic_meip;
    wire uart_irq;
    wire gpio_irq;
    wire timer_irq;
    wire [31:0] plic_sources =
        {29'd0, timer_irq, gpio_irq, uart_irq};
    wire uart_tx;
    wire uart_dtr_n;
    wire uart_rts_n;
    wire uart_out1_n;
    wire uart_out2_n;
    wire [31:0] gpio_out;

    wire [63:0] dbg_pc;
    wire [31:0] dbg_instr;
    wire dbg_halted;
    wire [63:0] core_trace_cycle;
    wire [4:0] core_trace_valid;
    wire [4:0] core_trace_stall;
    wire [4:0] core_trace_flush;
    wire [4:0] core_trace_advance;
    wire [319:0] core_trace_ids;
    wire [319:0] core_trace_pcs;
    wire [159:0] core_trace_instrs;
    wire [7:0] core_trace_events;
    wire [7:0] core_trace_stall_causes;
    wire core_trace_retire_valid;
    wire core_trace_retire_arch;
    wire core_trace_retire_exception;
    wire [4:0] core_trace_retire_cause;
    wire [63:0] core_trace_retire_next_pc;
    wire core_trace_retire_rd_write;
    wire [4:0] core_trace_retire_rd;
    wire [63:0] core_trace_retire_wdata;

    integer cycles;
    integer fetch_ar_before_first_r;
    reg first_r_seen;
    reg saw_ram_axi;
    reg saw_gpio_axi_read;
    reg saw_gpio_axi_write;
    reg saw_three_retire;
    reg external_image;
    reg external_done;
    reg done_pc_valid;
    reg expect_a0_valid;
    reg [63:0] done_pc;
    reg [63:0] expected_a0;
    integer max_cycles;
    integer perf_retired;
    integer perf_issued;
    integer retire_width_0;
    integer retire_width_1;
    integer retire_width_2;
    integer retire_width_3;
    integer issue_width_0;
    integer issue_width_1;
    integer issue_width_2;
    integer issue_width_3;
    integer axi_fetch_reads;
    integer axi_data_reads;
    integer axi_ram_reads;
    integer axi_mmio_reads;
    integer axi_ram_writes;
    integer axi_mmio_writes;
    integer bp_allocations;
    integer bp_taken_predictions;
    integer bp_resolutions;
    integer bp_corrections;
    integer eq_branch_pairings;
    integer branch_forward_issues;
    integer branch_forward_operands;
    integer loop_line_fetches;
    integer perf_block_none;
    integer perf_block_raw_pending;
    integer perf_block_raw_bundle;
    integer perf_block_raw_completed;
    integer perf_block_waw_pending;
    integer perf_block_waw_bundle;
    integer perf_block_waw_completed;
    integer perf_block_read_port;
    integer perf_block_barrier;
    integer perf_block_retire_capacity;
    integer perf_block_pipe_conflict;
    integer perf_block_pipe_busy;
    integer perf_block_invalid_pipe;
    integer perf_block_branch_redirect;
    integer perf_block_unknown;
    integer perf_retire_head_incomplete;
    integer perf_retire_completed_behind_head;
    integer perf_retire_control_block;
    integer perf_frontend_empty;
    integer perf_frontend_held;
    integer perf_frontend_request_wait;
    integer perf_frontend_redirect;
    integer perf_frontend_refill_wait;
    integer perf_frontend_no_line;
    integer perf_frontend_bp_stall;
    integer perf_frontend_control;
    integer perf_frontend_other_empty;
    integer perf_lsu_pipe_block;
    integer perf_lsu_request_wait;
    integer perf_lsu_outstanding;
    integer perf_lsu_order_block;
    localparam integer BLOCK_NONE = 0;
    localparam integer BLOCK_RAW_PENDING = 1;
    localparam integer BLOCK_RAW_BUNDLE = 2;
    localparam integer BLOCK_RAW_COMPLETED = 3;
    localparam integer BLOCK_WAW_PENDING = 4;
    localparam integer BLOCK_WAW_BUNDLE = 5;
    localparam integer BLOCK_WAW_COMPLETED = 6;
    localparam integer BLOCK_READ_PORT = 7;
    localparam integer BLOCK_BARRIER = 8;
    localparam integer BLOCK_RETIRE_CAPACITY = 9;
    localparam integer BLOCK_PIPE_CONFLICT = 10;
    localparam integer BLOCK_PIPE_BUSY = 11;
    localparam integer BLOCK_INVALID_PIPE = 12;
    localparam integer BLOCK_BRANCH_REDIRECT = 13;
    localparam integer BLOCK_UNKNOWN = 14;
    localparam integer BRANCH_ORACLE_DEPTH = 65536;
    reg [64:0] branch_oracle [0:BRANCH_ORACLE_DEPTH-1];
    reg branch_oracle_taken;
    reg [63:0] branch_oracle_target;
    integer branch_oracle_dump_fd;
    integer branch_oracle_dump_count;
    integer branch_oracle_consumed;
    integer branch_oracle_expected;
    integer branch_oracle_extra_allocations;
    string branch_oracle_dump_path;
    string branch_oracle_load_path;
    integer pipeline_trace_fd;
    integer pipeline_trace_cycle;
    string memh_path;
    string pipeline_trace_path;

    openrv64_top_3p #(
        .RESET_VECTOR(`OPENRV64_SOC_MEMORY_BASE),
        .ENABLE_RV64M(1'b1),
        .RETIRE_DEPTH(RETIRE_DEPTH),
        .COMPLETION_FORWARD_MASK(COMPLETION_FORWARD_MASK),
        .BRANCH_COMPLETION_FORWARD_MASK(BRANCH_FORWARD_MASK),
        .ENABLE_FULL_FORWARDING(FULL_FORWARDING),
        .RELAX_WAW(RELAX_WAW),
        .RELAX_HAZARDS(RELAX_HAZARDS),
        .FREE_BRANCHES(FREE_BRANCHES),
        .ENABLE_EQ_BRANCH_PAIRING(EQ_BRANCH_PAIRING),
        .ENABLE_ISSUE_WINDOW(ISSUE_WINDOW),
        .ENABLE_SPECULATION_WINDOW(SPECULATION_WINDOW),
        .ENABLE_POSTED_STORES(POSTED_STORES),
        .ENABLE_TRACE(1'b1),
        .BP_TYPE(BP_TYPE),
        .BP_RAS_ENABLE(BP_RAS_ENABLE),
        .BP_RAS_DEPTH(BP_RAS_DEPTH),
        .BP_BIMODAL_ENTRIES(BP_BIMODAL_ENTRIES),
        .BP_BIMODAL_COUNTER_BITS(BP_BIMODAL_COUNTER_BITS),
        .BP_BIMODAL_UPDATE_DEPTH(BP_BIMODAL_UPDATE_DEPTH),
        .BP_GSHARE_ENTRIES(BP_GSHARE_ENTRIES),
        .BP_GSHARE_COUNTER_BITS(BP_GSHARE_COUNTER_BITS),
        .BP_BTB_ENTRIES(BP_BTB_ENTRIES),
        .BP_BTB_TAG_BITS(BP_BTB_TAG_BITS),
        .BP_INFLIGHT_DEPTH(BP_INFLIGHT_DEPTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .m_axi_arid(arid),
        .m_axi_araddr(araddr),
        .m_axi_arlen(arlen),
        .m_axi_arsize(arsize),
        .m_axi_arburst(arburst),
        .m_axi_arlock(),
        .m_axi_arcache(),
        .m_axi_arprot(),
        .m_axi_arqos(),
        .m_axi_arvalid(arvalid),
        .m_axi_arready(arready),
        .m_axi_rid(rid),
        .m_axi_rdata(rdata),
        .m_axi_rresp(rresp),
        .m_axi_rlast(rlast),
        .m_axi_rvalid(rvalid),
        .m_axi_rready(rready),
        .m_axi_awid(awid),
        .m_axi_awaddr(awaddr),
        .m_axi_awlen(awlen),
        .m_axi_awsize(awsize),
        .m_axi_awburst(awburst),
        .m_axi_awlock(),
        .m_axi_awcache(),
        .m_axi_awprot(),
        .m_axi_awqos(),
        .m_axi_awvalid(awvalid),
        .m_axi_awready(awready),
        .m_axi_wdata(wdata),
        .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid),
        .m_axi_wready(wready),
        .m_axi_bid(bid),
        .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid),
        .m_axi_bready(bready),
        .irq_m_software(clint_msip[0]),
        .irq_m_timer(clint_mtip[0]),
        .irq_m_external(plic_meip[0]),
        .irq_s_software(1'b0),
        .irq_s_timer(1'b0),
        .irq_s_external(1'b0),
        .dbg_pc(dbg_pc),
        .dbg_instr(dbg_instr),
        .dbg_halted(dbg_halted),
        .trace_cycle(core_trace_cycle),
        .trace_valid(core_trace_valid),
        .trace_stall(core_trace_stall),
        .trace_flush(core_trace_flush),
        .trace_advance(core_trace_advance),
        .trace_ids(core_trace_ids),
        .trace_pcs(core_trace_pcs),
        .trace_instrs(core_trace_instrs),
        .trace_events(core_trace_events),
        .trace_stall_causes(core_trace_stall_causes),
        .trace_retire_valid(core_trace_retire_valid),
        .trace_retire_arch(core_trace_retire_arch),
        .trace_retire_exception(core_trace_retire_exception),
        .trace_retire_cause(core_trace_retire_cause),
        .trace_retire_next_pc(core_trace_retire_next_pc),
        .trace_retire_rd_write(core_trace_retire_rd_write),
        .trace_retire_rd(core_trace_retire_rd),
        .trace_retire_wdata(core_trace_retire_wdata)
    );

    // Testbench-only visibility into the program-ordered dispatch window.
    // These names deliberately do not become RTL ports: the CSV is a
    // simulation ABI, while the synthesizable trace interface remains small.
    wire [2:0] strict_trace_candidate_valid =
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.candidate_valid;
    wire [2:0] strict_trace_candidate_fire =
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.candidate_fire;
    wire [2:0] strict_trace_candidate_hazard_free =
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.candidate_hazard_free_effective;
    wire [2:0] strict_trace_candidate_free =
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.candidate_free;
    wire [2:0] trace_free_branch_complete =
        dut.u_core.u_backend.allocation_complete;
    wire trace_exec_branch_resolved =
        dut.u_core.u_backend.exec_branch_resolved;
    wire [3*`OPENRV64_EXEC_PIPE_WIDTH-1:0] strict_trace_candidate_pipe =
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.candidate_pipe;
    wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        strict_trace_candidate_payload =
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.candidate_payload;
    wire [2:0] strict_trace_candidate_uses_rs1 =
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.reg_map_uses_rs1;
    wire [2:0] strict_trace_candidate_uses_rs2 =
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.reg_map_uses_rs2;
    wire [2:0] strict_trace_candidate_reg_write =
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.candidate_reg_write;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] strict_trace_candidate_rs1 =
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.candidate_rs1_addr;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] strict_trace_candidate_rs2 =
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.candidate_rs2_addr;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] strict_trace_candidate_rd =
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.candidate_rd_addr;
    wire [2:0] trace_pipe_ready = dut.u_core.u_backend.pipe_ready;
    wire [2:0] trace_candidate_valid = (ISSUE_WINDOW != 0) ?
        dut.u_core.u_backend.pipe_valid : strict_trace_candidate_valid;
    wire [2:0] trace_candidate_fire = (ISSUE_WINDOW != 0) ?
        (dut.u_core.u_backend.pipe_valid & trace_pipe_ready) :
        strict_trace_candidate_fire;
    wire [2:0] trace_candidate_hazard_free = (ISSUE_WINDOW != 0) ?
        dut.u_core.u_backend.pipe_valid : strict_trace_candidate_hazard_free;
    wire [3*`OPENRV64_EXEC_PIPE_WIDTH-1:0] trace_candidate_pipe =
        (ISSUE_WINDOW != 0) ?
        {`OPENRV64_EXEC_PIPE_MEM, `OPENRV64_EXEC_PIPE_EX1,
         `OPENRV64_EXEC_PIPE_EX0} : strict_trace_candidate_pipe;
    wire [3*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH-1:0]
        trace_candidate_payload = (ISSUE_WINDOW != 0) ?
        dut.u_core.u_backend.pipe_payload : strict_trace_candidate_payload;
    wire [2:0] trace_candidate_uses_rs1 = (ISSUE_WINDOW != 0) ?
        dut.u_core.u_backend.u_dispatch.g_3p.u_window.trace_pipe_uses_rs1 :
        strict_trace_candidate_uses_rs1;
    wire [2:0] trace_candidate_uses_rs2 = (ISSUE_WINDOW != 0) ?
        dut.u_core.u_backend.u_dispatch.g_3p.u_window.trace_pipe_uses_rs2 :
        strict_trace_candidate_uses_rs2;
    wire [2:0] trace_candidate_reg_write = {
        trace_candidate_payload[
            2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 17],
        trace_candidate_payload[
            1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 17],
        trace_candidate_payload[
            0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 17]
    };
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] trace_candidate_rs1 =
        (ISSUE_WINDOW != 0) ? {
            trace_candidate_payload[
                2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 237 +: 5],
            trace_candidate_payload[
                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 237 +: 5],
            trace_candidate_payload[
                0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 237 +: 5]
        } : strict_trace_candidate_rs1;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] trace_candidate_rs2 =
        (ISSUE_WINDOW != 0) ? {
            trace_candidate_payload[
                2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 232 +: 5],
            trace_candidate_payload[
                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 232 +: 5],
            trace_candidate_payload[
                0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 232 +: 5]
        } : strict_trace_candidate_rs2;
    wire [3*`RV64_REG_ADDR_WIDTH-1:0] trace_candidate_rd =
        (ISSUE_WINDOW != 0) ? {
            trace_candidate_payload[
                2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 35 +: 5],
            trace_candidate_payload[
                1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 35 +: 5],
            trace_candidate_payload[
                0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 35 +: 5]
        } : strict_trace_candidate_rd;
    wire trace_allocation_ready = dut.u_core.u_backend.allocation_ready;
    wire [2:0] trace_barrier_allow =
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_control.barrier_allow;
    wire [2:0] trace_raw_existing = {
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.raw_existing2,
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.raw_existing1,
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.raw0
    };
    wire [2:0] trace_raw_bundle = {
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.raw_bundle2,
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.raw_bundle1,
        1'b0
    };
    wire [2:0] trace_raw_rs1 = {
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs12 &&
            ((dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.busy_after_retire[
                trace_candidate_rs1[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]] &&
              !dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.forward_rs12) ||
             dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot0[
                trace_candidate_rs1[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]] ||
             dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot1[
                trace_candidate_rs1[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]]),
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs11 &&
            ((dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.busy_after_retire[
                trace_candidate_rs1[1*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]] &&
              !dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.forward_rs11) ||
             dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot0[
                trace_candidate_rs1[1*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]]),
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs10 &&
            dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.busy_after_retire[
                trace_candidate_rs1[0*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]] &&
            !dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.forward_rs10
    };
    wire [2:0] trace_raw_rs2 = {
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs22 &&
            ((dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.busy_after_retire[
                trace_candidate_rs2[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]] &&
              !dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.forward_rs22) ||
             dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot0[
                trace_candidate_rs2[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]] ||
             dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot1[
                trace_candidate_rs2[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]]),
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs21 &&
            ((dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.busy_after_retire[
                trace_candidate_rs2[1*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]] &&
              !dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.forward_rs21) ||
             dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot0[
                trace_candidate_rs2[1*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]]),
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.reads_rs20 &&
            dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.busy_after_retire[
                trace_candidate_rs2[0*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]] &&
            !dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.forward_rs20
    };
    wire [2:0] trace_raw_completed = {
        dut.u_core.u_backend.raw_hazard[2] && !trace_raw_bundle[2] &&
            (!trace_raw_rs1[2] || dut.u_core.u_backend.full_forward_valid[
                trace_candidate_rs1[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]]) &&
            (!trace_raw_rs2[2] || dut.u_core.u_backend.full_forward_valid[
                trace_candidate_rs2[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]]),
        dut.u_core.u_backend.raw_hazard[1] && !trace_raw_bundle[1] &&
            (!trace_raw_rs1[1] || dut.u_core.u_backend.full_forward_valid[
                trace_candidate_rs1[1*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]]) &&
            (!trace_raw_rs2[1] || dut.u_core.u_backend.full_forward_valid[
                trace_candidate_rs2[1*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]]),
        dut.u_core.u_backend.raw_hazard[0] &&
            (!trace_raw_rs1[0] || dut.u_core.u_backend.full_forward_valid[
                trace_candidate_rs1[0*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]]) &&
            (!trace_raw_rs2[0] || dut.u_core.u_backend.full_forward_valid[
                trace_candidate_rs2[0*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]])
    };
    wire [2:0] trace_waw_completed = {
        dut.u_core.u_backend.waw_hazard[2] && trace_candidate_reg_write[2] &&
            dut.u_core.u_backend.full_forward_valid[
                trace_candidate_rd[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]],
        dut.u_core.u_backend.waw_hazard[1] && trace_candidate_reg_write[1] &&
            dut.u_core.u_backend.full_forward_valid[
                trace_candidate_rd[1*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]],
        dut.u_core.u_backend.waw_hazard[0] && trace_candidate_reg_write[0] &&
            dut.u_core.u_backend.full_forward_valid[
                trace_candidate_rd[0*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]]
    };
    wire [2:0] trace_waw_bundle = {
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.writes2 &&
            (dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot0[
                trace_candidate_rd[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]] ||
             dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot1[
                trace_candidate_rd[2*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]]),
        dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.writes1 &&
            dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.u_reg_map.write_hot0[
                trace_candidate_rd[1*`RV64_REG_ADDR_WIDTH +: `RV64_REG_ADDR_WIDTH]],
        1'b0
    };
    wire [2:0] trace_queue_retire_valid =
        dut.u_core.u_backend.queue_retire_valid;
    wire [RETIRE_DEPTH-1:0] trace_completed_entries =
        dut.u_core.u_backend.completed_entry_valid;
    wire [2:0] trace_lsu_slots = {
        dut.u_core.u_backend.u_exec.g_3p.u_exec.u_mem.slot_valid_q[2],
        dut.u_core.u_backend.u_exec.g_3p.u_exec.u_mem.slot_valid_q[1],
        dut.u_core.u_backend.u_exec.g_3p.u_exec.u_mem.slot_valid_q[0]
    };
    wire [2:0] trace_lsu_sent = {
        dut.u_core.u_backend.u_exec.g_3p.u_exec.u_mem.slot_sent_q[2],
        dut.u_core.u_backend.u_exec.g_3p.u_exec.u_mem.slot_sent_q[1],
        dut.u_core.u_backend.u_exec.g_3p.u_exec.u_mem.slot_sent_q[0]
    };
    wire trace_lsu_store_inflight =
        dut.u_core.u_backend.u_exec.g_3p.u_exec.u_mem.store_inflight_q;
    wire trace_lsu_order_block =
        dut.u_core.u_backend.u_exec.g_3p.u_exec.u_mem.request_slot_valid &&
        (dut.u_core.u_backend.u_exec.g_3p.u_exec.u_mem.pending_store_order_block ||
         (dut.u_core.u_backend.u_exec.g_3p.u_exec.u_mem.request_mem_write &&
          !dut.u_core.u_backend.u_exec.g_3p.u_exec.u_mem.request_order_match));
    wire [3:0] trace_fetch_lines = {
        dut.u_core.g_fetch_axi.u_fetch.line_valid_q[3],
        dut.u_core.g_fetch_axi.u_fetch.line_valid_q[2],
        dut.u_core.g_fetch_axi.u_fetch.line_valid_q[1],
        dut.u_core.g_fetch_axi.u_fetch.line_valid_q[0]
    };
    wire [3:0] trace_fetch_pending = {
        dut.u_core.g_fetch_axi.u_fetch.pending_valid_q[3],
        dut.u_core.g_fetch_axi.u_fetch.pending_valid_q[2],
        dut.u_core.g_fetch_axi.u_fetch.pending_valid_q[1],
        dut.u_core.g_fetch_axi.u_fetch.pending_valid_q[0]
    };
    wire [2:0] trace_fetch_bus_count =
        dut.u_core.u_bus.g_axi.u_bus.fetch_count_q;
    wire trace_fetch_consume_hit =
        dut.u_core.g_fetch_axi.u_fetch.consume_line_hit;
    wire trace_fetch_follow_hit =
        dut.u_core.g_fetch_axi.u_fetch.following_line_hit;
    wire trace_fetch_active = dut.u_core.g_fetch_axi.u_fetch.active_q;

    // The legacy candidate fields above describe the strict-prefix queue.
    // The selectable issue-window path has more than three candidates, so
    // aggregate its actual scan state explicitly instead of pretending that
    // the old three-lane hazard classification still applies.
    wire [4:0] trace_window_unissued = (ISSUE_WINDOW != 0) ?
        dut.u_core.u_backend.u_dispatch.g_3p.u_window.trace_unissued_count :
        5'd0;
    wire [4:0] trace_window_operand_ready = (ISSUE_WINDOW != 0) ?
        dut.u_core.u_backend.u_dispatch.g_3p.u_window.trace_operand_ready_count :
        5'd0;
    wire [4:0] trace_window_eligible = (ISSUE_WINDOW != 0) ?
        dut.u_core.u_backend.u_dispatch.g_3p.u_window.trace_eligible_count :
        5'd0;
    wire [4:0] trace_window_raw_block = (ISSUE_WINDOW != 0) ?
        dut.u_core.u_backend.u_dispatch.g_3p.u_window.trace_raw_block_count :
        5'd0;
    wire [4:0] trace_window_hard_block = (ISSUE_WINDOW != 0) ?
        dut.u_core.u_backend.u_dispatch.g_3p.u_window.trace_hard_block_count :
        5'd0;
    wire [4:0] trace_window_mem_order_block = (ISSUE_WINDOW != 0) ?
        dut.u_core.u_backend.u_dispatch.g_3p.u_window.trace_mem_order_block_count :
        5'd0;
    wire [1:0] trace_window_selected =
        {1'b0, dut.u_core.u_backend.pipe_valid[0]} +
        {1'b0, dut.u_core.u_backend.pipe_valid[1]} +
        {1'b0, dut.u_core.u_backend.pipe_valid[2]};
    wire [1:0] trace_window_issued =
        {1'b0, (dut.u_core.u_backend.pipe_valid[0] && trace_pipe_ready[0])} +
        {1'b0, (dut.u_core.u_backend.pipe_valid[1] && trace_pipe_ready[1])} +
        {1'b0, (dut.u_core.u_backend.pipe_valid[2] && trace_pipe_ready[2])};

    integer trace_block_lane;
    integer trace_block_reason;
    reg [`OPENRV64_EXEC_PIPE_WIDTH-1:0] trace_block_pipe;
    always @* begin
        trace_block_lane = 3;
        trace_block_reason = BLOCK_NONE;
        trace_block_pipe = {`OPENRV64_EXEC_PIPE_WIDTH{1'b0}};
        if (trace_candidate_valid[0] && !trace_candidate_fire[0]) begin
            trace_block_lane = 0;
        end else if (trace_candidate_valid[1] && trace_candidate_fire[0] &&
                     !trace_candidate_fire[1]) begin
            trace_block_lane = 1;
        end else if (trace_candidate_valid[2] && trace_candidate_fire[1] &&
                     !trace_candidate_fire[2]) begin
            trace_block_lane = 2;
        end

        if (trace_block_lane != 3) begin
            trace_block_pipe = trace_candidate_pipe[
                trace_block_lane*`OPENRV64_EXEC_PIPE_WIDTH +:
                `OPENRV64_EXEC_PIPE_WIDTH];
            if (dut.u_core.u_backend.raw_hazard[trace_block_lane]) begin
                if (trace_raw_bundle[trace_block_lane])
                    trace_block_reason = BLOCK_RAW_BUNDLE;
                else if (trace_raw_completed[trace_block_lane])
                    trace_block_reason = BLOCK_RAW_COMPLETED;
                else
                    trace_block_reason = BLOCK_RAW_PENDING;
            end else if (dut.u_core.u_backend.waw_hazard[trace_block_lane]) begin
                if (trace_waw_bundle[trace_block_lane])
                    trace_block_reason = BLOCK_WAW_BUNDLE;
                else if (trace_waw_completed[trace_block_lane])
                    trace_block_reason = BLOCK_WAW_COMPLETED;
                else
                    trace_block_reason = BLOCK_WAW_PENDING;
            end else if (dut.u_core.u_backend.read_port_hazard[trace_block_lane]) begin
                trace_block_reason = BLOCK_READ_PORT;
            end else if (!trace_barrier_allow[trace_block_lane]) begin
                trace_block_reason = BLOCK_BARRIER;
            end else if (!trace_allocation_ready) begin
                trace_block_reason = BLOCK_RETIRE_CAPACITY;
            end else if ((FREE_BRANCHES != 0) &&
                         dut.u_core.backend_redirect &&
                         (((trace_block_lane == 1) &&
                           strict_trace_candidate_free[0]) ||
                          ((trace_block_lane == 2) &&
                           (strict_trace_candidate_free[0] ||
                            strict_trace_candidate_free[1])))) begin
                // The free branch resolved as mispredicted while allocating;
                // younger wrong-path candidates are deliberately suppressed.
                trace_block_reason = BLOCK_BRANCH_REDIRECT;
            end else if ((trace_block_lane >= 1) &&
                         trace_candidate_fire[0] &&
                         !strict_trace_candidate_free[0] &&
                         (trace_block_pipe == trace_candidate_pipe[
                            0*`OPENRV64_EXEC_PIPE_WIDTH +:
                            `OPENRV64_EXEC_PIPE_WIDTH])) begin
                trace_block_reason = BLOCK_PIPE_CONFLICT;
            end else if ((trace_block_lane == 2) &&
                         trace_candidate_fire[1] &&
                         !strict_trace_candidate_free[1] &&
                         (trace_block_pipe == trace_candidate_pipe[
                            1*`OPENRV64_EXEC_PIPE_WIDTH +:
                            `OPENRV64_EXEC_PIPE_WIDTH])) begin
                trace_block_reason = BLOCK_PIPE_CONFLICT;
            end else if (trace_block_pipe > `OPENRV64_EXEC_PIPE_MEM) begin
                trace_block_reason = BLOCK_INVALID_PIPE;
            end else if (!trace_pipe_ready[trace_block_pipe]) begin
                trace_block_reason = BLOCK_PIPE_BUSY;
            end else begin
                trace_block_reason = BLOCK_UNKNOWN;
            end
        end
    end

    tb_axi256_soc_fabric #(
        .RAM_BYTES(16 * 1024 * 1024)
    ) u_axi_fabric (
        .clk_i(clk),
        .rst_ni(rst_n),
        .s_axi_arid_i(arid),
        .s_axi_araddr_i(araddr),
        .s_axi_arlen_i(arlen),
        .s_axi_arsize_i(arsize),
        .s_axi_arburst_i(arburst),
        .s_axi_arvalid_i(arvalid),
        .s_axi_arready_o(arready),
        .s_axi_rid_o(rid),
        .s_axi_rdata_o(rdata),
        .s_axi_rresp_o(rresp),
        .s_axi_rlast_o(rlast),
        .s_axi_rvalid_o(rvalid),
        .s_axi_rready_i(rready),
        .s_axi_awid_i(awid),
        .s_axi_awaddr_i(awaddr),
        .s_axi_awlen_i(awlen),
        .s_axi_awsize_i(awsize),
        .s_axi_awburst_i(awburst),
        .s_axi_awvalid_i(awvalid),
        .s_axi_awready_o(awready),
        .s_axi_wdata_i(wdata),
        .s_axi_wstrb_i(wstrb),
        .s_axi_wlast_i(wlast),
        .s_axi_wvalid_i(wvalid),
        .s_axi_wready_o(wready),
        .s_axi_bid_o(bid),
        .s_axi_bresp_o(bresp),
        .s_axi_bvalid_o(bvalid),
        .s_axi_bready_i(bready),
        .mem_valid_o(bus_valid),
        .mem_ready_i(bus_ready),
        .mem_write_o(bus_write),
        .mem_addr_o(bus_addr),
        .mem_wdata_o(bus_wdata),
        .mem_wstrb_o(bus_wstrb),
        .mem_rdata_i(bus_rdata),
        .mem_error_i(bus_error)
    );

    openrv64_soc_bus_decode u_bus (
        .mem_valid_i(bus_valid),
        .mem_ready_o(bus_ready),
        .mem_write_i(bus_write),
        .mem_addr_i(bus_addr),
        .mem_wdata_i(bus_wdata),
        .mem_wstrb_i(bus_wstrb),
        .mem_rdata_o(bus_rdata),
        .mem_error_o(bus_error),
        .rom_valid_o(rom_valid),
        .rom_ready_i(rom_ready),
        .rom_write_o(rom_write),
        .rom_addr_o(rom_addr),
        .rom_wdata_o(rom_wdata),
        .rom_wstrb_o(rom_wstrb),
        .rom_rdata_i(rom_rdata),
        .memory_valid_o(memory_valid),
        .memory_ready_i(memory_ready),
        .memory_write_o(memory_write),
        .memory_addr_o(memory_addr),
        .memory_wdata_o(memory_wdata),
        .memory_wstrb_o(memory_wstrb),
        .memory_rdata_i(memory_rdata),
        .clint_valid_o(clint_valid),
        .clint_ready_i(clint_ready),
        .clint_write_o(clint_write),
        .clint_addr_o(clint_addr),
        .clint_wdata_o(clint_wdata),
        .clint_wstrb_o(clint_wstrb),
        .clint_rdata_i(clint_rdata),
        .plic_valid_o(plic_valid),
        .plic_ready_i(plic_ready),
        .plic_write_o(plic_write),
        .plic_addr_o(plic_addr),
        .plic_wdata_o(plic_wdata),
        .plic_wstrb_o(plic_wstrb),
        .plic_rdata_i(plic_rdata),
        .uart_valid_o(uart_valid),
        .uart_ready_i(uart_ready),
        .uart_write_o(uart_write),
        .uart_addr_o(uart_addr),
        .uart_wdata_o(uart_wdata),
        .uart_wstrb_o(uart_wstrb),
        .uart_rdata_i(uart_rdata),
        .gpio_valid_o(gpio_valid),
        .gpio_ready_i(gpio_ready),
        .gpio_write_o(gpio_write),
        .gpio_addr_o(gpio_addr),
        .gpio_wdata_o(gpio_wdata),
        .gpio_wstrb_o(gpio_wstrb),
        .gpio_rdata_i(gpio_rdata),
        .timer_valid_o(timer_valid),
        .timer_ready_i(timer_ready),
        .timer_write_o(timer_write),
        .timer_addr_o(timer_addr),
        .timer_wdata_o(timer_wdata),
        .timer_wstrb_o(timer_wstrb),
        .timer_rdata_i(timer_rdata)
    );

    openrv64_soc_rom u_rom (
        .mem_valid_i(rom_valid),
        .mem_ready_o(rom_ready),
        .mem_write_i(rom_write),
        .mem_addr_i(rom_addr),
        .mem_wdata_i(rom_wdata),
        .mem_wstrb_i(rom_wstrb),
        .mem_rdata_o(rom_rdata)
    );

    // The AXI fabric consumes the 16 MiB RAM aperture before the peripheral
    // bus.  These defensive values make any accidental second decode visible
    // without placing a second RAM behind the same address window.
    assign memory_ready = 1'b1;
    assign memory_rdata = 64'd0;

    openrv64_clint #(
        .NUM_HARTS(1)
    ) u_clint (
        .clk_i(clk),
        .rst_ni(rst_n),
        .mtime_tick_i(1'b1),
        .mem_valid_i(clint_valid),
        .mem_ready_o(clint_ready),
        .mem_write_i(clint_write),
        .mem_addr_i(clint_addr),
        .mem_wdata_i(clint_wdata),
        .mem_wstrb_i(clint_wstrb),
        .mem_rdata_o(clint_rdata),
        .msip_o(clint_msip),
        .mtip_o(clint_mtip),
        .mtime_o(clint_mtime)
    );

    openrv64_plic #(
        .NUM_HARTS(1),
        .NUM_SOURCES(32),
        .PRIORITY_WIDTH(3)
    ) u_plic (
        .clk_i(clk),
        .rst_ni(rst_n),
        .irq_sources_i(plic_sources),
        .mem_valid_i(plic_valid),
        .mem_ready_o(plic_ready),
        .mem_write_i(plic_write),
        .mem_addr_i(plic_addr),
        .mem_wdata_i(plic_wdata),
        .mem_wstrb_i(plic_wstrb),
        .mem_rdata_o(plic_rdata),
        .meip_o(plic_meip)
    );

    openrv64_uart16550 u_uart (
        .clk_i(clk),
        .rst_ni(rst_n),
        .rx_i(1'b1),
        .tx_o(uart_tx),
        .cts_ni(1'b1),
        .dsr_ni(1'b1),
        .ri_ni(1'b1),
        .dcd_ni(1'b1),
        .dtr_no(uart_dtr_n),
        .rts_no(uart_rts_n),
        .out1_no(uart_out1_n),
        .out2_no(uart_out2_n),
        .mem_valid_i(uart_valid),
        .mem_ready_o(uart_ready),
        .mem_write_i(uart_write),
        .mem_addr_i(uart_addr),
        .mem_wdata_i(uart_wdata),
        .mem_wstrb_i(uart_wstrb),
        .mem_rdata_o(uart_rdata),
        .irq_o(uart_irq)
    );

    openrv64_gpio #(
        .NUM_PINS(32),
        .ENABLE_INTERRUPTS(1)
    ) u_gpio (
        .clk_i(clk),
        .rst_ni(rst_n),
        .gpio_in_i(32'd0),
        .gpio_out_o(gpio_out),
        .irq_o(gpio_irq),
        .mem_valid_i(gpio_valid),
        .mem_ready_o(gpio_ready),
        .mem_write_i(gpio_write),
        .mem_addr_i(gpio_addr),
        .mem_wdata_i(gpio_wdata),
        .mem_wstrb_i(gpio_wstrb),
        .mem_rdata_o(gpio_rdata)
    );

    openrv64_timer #(
        .ENABLE_INTERRUPTS(1)
    ) u_timer (
        .clk_i(clk),
        .rst_ni(rst_n),
        .irq_o(timer_irq),
        .mem_valid_i(timer_valid),
        .mem_ready_o(timer_ready),
        .mem_write_i(timer_write),
        .mem_addr_i(timer_addr),
        .mem_wdata_i(timer_wdata),
        .mem_wstrb_i(timer_wstrb),
        .mem_rdata_o(timer_rdata)
    );

    always #5 clk = ~clk;

    function automatic [31:0] enc_addi;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] immediate;
        begin
            enc_addi = {immediate, rs1, `RV64_FUNCT3_ADD_SUB,
                        rd, `RV64_OPCODE_OP_IMM};
        end
    endfunction

    function automatic [31:0] enc_lui;
        input [4:0] rd;
        input [19:0] immediate;
        begin
            enc_lui = {immediate, rd, `RV64_OPCODE_LUI};
        end
    endfunction

    function automatic [31:0] enc_auipc;
        input [4:0] rd;
        input [19:0] immediate;
        begin
            enc_auipc = {immediate, rd, `RV64_OPCODE_AUIPC};
        end
    endfunction

    function automatic [31:0] enc_add;
        input [4:0] rd;
        input [4:0] rs1;
        input [4:0] rs2;
        begin
            enc_add = {7'b0000000, rs2, rs1, `RV64_FUNCT3_ADD_SUB,
                       rd, `RV64_OPCODE_OP};
        end
    endfunction

    function automatic [31:0] enc_load;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] immediate;
        input [2:0] funct3;
        begin
            enc_load = {immediate, rs1, funct3, rd, `RV64_OPCODE_LOAD};
        end
    endfunction

    function automatic [31:0] enc_store;
        input [4:0] rs2;
        input [4:0] rs1;
        input [11:0] immediate;
        input [2:0] funct3;
        begin
            enc_store = {immediate[11:5], rs2, rs1, funct3,
                         immediate[4:0], `RV64_OPCODE_STORE};
        end
    endfunction

    function automatic [31:0] enc_branch;
        input [2:0] funct3;
        input [4:0] rs1;
        input [4:0] rs2;
        input [12:0] immediate;
        begin
            enc_branch = {immediate[12], immediate[10:5], rs2, rs1,
                          funct3, immediate[4:1], immediate[11],
                          `RV64_OPCODE_BRANCH};
        end
    endfunction

    function automatic branch_completion_match;
        input [4:0] source_addr;
        integer completion_lane;
        begin
            branch_completion_match = 1'b0;
            if (source_addr != `RV64_REG_X0) begin
                for (completion_lane = 0; completion_lane < 3;
                     completion_lane = completion_lane + 1) begin
                    if (dut.u_core.u_backend.
                            branch_completion_forward_valid[completion_lane] &&
                        (dut.u_core.u_backend.completion_forward_rd_addr[
                            completion_lane*`RV64_REG_ADDR_WIDTH +:
                            `RV64_REG_ADDR_WIDTH] == source_addr))
                        branch_completion_match = 1'b1;
                end
            end
        end
    endfunction

    task automatic put_instr;
        input integer byte_offset;
        input [31:0] instruction;
        integer line_index;
        integer bit_offset;
        begin
            line_index = byte_offset >> 5;
            bit_offset = (byte_offset & 31) * 8;
            u_axi_fabric.ram_q[line_index][bit_offset +: 32] = instruction;
        end
    endtask

    task automatic sample_performance;
        integer issued_this_cycle;
        integer branch_candidate_lane;
        reg branch_rs1_forwarded;
        reg branch_rs2_forwarded;
        begin
            perf_retired = perf_retired + dut.u_core.backend_retire_count;
            issued_this_cycle = dut.u_core.backend_issue_valid[0] +
                                dut.u_core.backend_issue_valid[1] +
                                dut.u_core.backend_issue_valid[2];
            perf_issued = perf_issued + issued_this_cycle;

            if (ISSUE_WINDOW == 0) begin
                for (branch_candidate_lane = 0;
                     branch_candidate_lane < 3;
                     branch_candidate_lane = branch_candidate_lane + 1) begin
                    branch_rs1_forwarded =
                        trace_candidate_uses_rs1[branch_candidate_lane] &&
                        branch_completion_match(trace_candidate_rs1[
                            branch_candidate_lane*`RV64_REG_ADDR_WIDTH +:
                            `RV64_REG_ADDR_WIDTH]);
                    branch_rs2_forwarded =
                        trace_candidate_uses_rs2[branch_candidate_lane] &&
                        branch_completion_match(trace_candidate_rs2[
                            branch_candidate_lane*`RV64_REG_ADDR_WIDTH +:
                            `RV64_REG_ADDR_WIDTH]);
                    if (trace_candidate_fire[branch_candidate_lane] &&
                        trace_candidate_payload[
                            branch_candidate_lane*
                            `OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 14] &&
                        (branch_rs1_forwarded || branch_rs2_forwarded)) begin
                        branch_forward_issues = branch_forward_issues + 1;
                        branch_forward_operands = branch_forward_operands +
                            branch_rs1_forwarded + branch_rs2_forwarded;
                    end
                end
            end

            case (dut.u_core.backend_retire_count)
                0: retire_width_0 = retire_width_0 + 1;
                1: retire_width_1 = retire_width_1 + 1;
                2: retire_width_2 = retire_width_2 + 1;
                3: retire_width_3 = retire_width_3 + 1;
            endcase
            case (issued_this_cycle)
                0: issue_width_0 = issue_width_0 + 1;
                1: issue_width_1 = issue_width_1 + 1;
                2: issue_width_2 = issue_width_2 + 1;
                3: issue_width_3 = issue_width_3 + 1;
            endcase

            case (trace_block_reason)
                BLOCK_NONE:
                    perf_block_none = perf_block_none + 1;
                BLOCK_RAW_PENDING:
                    perf_block_raw_pending = perf_block_raw_pending + 1;
                BLOCK_RAW_BUNDLE:
                    perf_block_raw_bundle = perf_block_raw_bundle + 1;
                BLOCK_RAW_COMPLETED:
                    perf_block_raw_completed = perf_block_raw_completed + 1;
                BLOCK_WAW_PENDING:
                    perf_block_waw_pending = perf_block_waw_pending + 1;
                BLOCK_WAW_BUNDLE:
                    perf_block_waw_bundle = perf_block_waw_bundle + 1;
                BLOCK_WAW_COMPLETED:
                    perf_block_waw_completed = perf_block_waw_completed + 1;
                BLOCK_READ_PORT:
                    perf_block_read_port = perf_block_read_port + 1;
                BLOCK_BARRIER:
                    perf_block_barrier = perf_block_barrier + 1;
                BLOCK_RETIRE_CAPACITY:
                    perf_block_retire_capacity =
                        perf_block_retire_capacity + 1;
                BLOCK_PIPE_CONFLICT:
                    perf_block_pipe_conflict = perf_block_pipe_conflict + 1;
                BLOCK_PIPE_BUSY:
                    perf_block_pipe_busy = perf_block_pipe_busy + 1;
                BLOCK_INVALID_PIPE:
                    perf_block_invalid_pipe = perf_block_invalid_pipe + 1;
                BLOCK_BRANCH_REDIRECT:
                    perf_block_branch_redirect =
                        perf_block_branch_redirect + 1;
                default:
                    perf_block_unknown = perf_block_unknown + 1;
            endcase

            if ((dut.u_core.backend_retire_occupancy != 0) &&
                !trace_queue_retire_valid[0]) begin
                perf_retire_head_incomplete =
                    perf_retire_head_incomplete + 1;
                if (trace_completed_entries != 0)
                    perf_retire_completed_behind_head =
                        perf_retire_completed_behind_head + 1;
            end
            if (trace_queue_retire_valid[0] &&
                !dut.u_core.u_backend.release_valid[0])
                perf_retire_control_block = perf_retire_control_block + 1;

            if (dut.u_core.fetch_decode_valid == 0)
                perf_frontend_empty = perf_frontend_empty + 1;
            if ((dut.u_core.fetch_decode_valid != 0) &&
                (dut.u_core.frontend_decode_fire == 0))
                perf_frontend_held = perf_frontend_held + 1;
            if (dut.u_core.fetch_pipe_req_valid &&
                !dut.u_core.fetch_pipe_req_ready)
                perf_frontend_request_wait =
                    perf_frontend_request_wait + 1;
            if (dut.u_core.control_redirect)
                perf_frontend_redirect = perf_frontend_redirect + 1;
            if (dut.u_core.fetch_decode_valid == 0) begin
                if (dut.u_core.control_flush || dut.u_core.control_redirect)
                    perf_frontend_control = perf_frontend_control + 1;
                else if (dut.u_core.bp_fetch_stall)
                    perf_frontend_bp_stall = perf_frontend_bp_stall + 1;
                else if (!trace_fetch_consume_hit &&
                         ((trace_fetch_pending != 0) ||
                          (trace_fetch_bus_count != 0)))
                    perf_frontend_refill_wait =
                        perf_frontend_refill_wait + 1;
                else if (!trace_fetch_consume_hit)
                    perf_frontend_no_line = perf_frontend_no_line + 1;
                else
                    perf_frontend_other_empty =
                        perf_frontend_other_empty + 1;
            end

            if ((trace_block_reason == BLOCK_PIPE_BUSY) &&
                (trace_block_pipe == `OPENRV64_EXEC_PIPE_MEM))
                perf_lsu_pipe_block = perf_lsu_pipe_block + 1;
            if (dut.u_core.backend_mem_valid &&
                !dut.u_core.backend_mem_ready)
                perf_lsu_request_wait = perf_lsu_request_wait + 1;
            if (trace_lsu_sent != 0)
                perf_lsu_outstanding = perf_lsu_outstanding + 1;
            if (trace_lsu_order_block)
                perf_lsu_order_block = perf_lsu_order_block + 1;

            if (arvalid && arready) begin
                if (arid[`OPENRV64_AXI_ID_WIDTH-1])
                    axi_data_reads = axi_data_reads + 1;
                else
                    axi_fetch_reads = axi_fetch_reads + 1;
                if ((araddr >= `OPENRV64_SOC_MEMORY_BASE) &&
                    (araddr < (`OPENRV64_SOC_MEMORY_BASE +
                               `OPENRV64_SOC_MEMORY_SIZE)))
                    axi_ram_reads = axi_ram_reads + 1;
                else
                    axi_mmio_reads = axi_mmio_reads + 1;
            end

            if (awvalid && awready) begin
                if ((awaddr >= `OPENRV64_SOC_MEMORY_BASE) &&
                    (awaddr < (`OPENRV64_SOC_MEMORY_BASE +
                               `OPENRV64_SOC_MEMORY_SIZE)))
                    axi_ram_writes = axi_ram_writes + 1;
                else
                    axi_mmio_writes = axi_mmio_writes + 1;
            end
        end
    endtask

    // Detailed three-wide trace.  The stage masks identify valid lanes; stale
    // payload fields on invalid lanes are intentionally retained so the CSV
    // stays fixed-width and cheap to generate.
    task automatic sample_pipeline_trace;
        begin
        if (rst_n && external_image && (pipeline_trace_fd != 0)) begin
            $fwrite(pipeline_trace_fd,
                "openrv64-3p-cycle-v2,%0d,%x,%x,%x,%x,%x,%x,%x,%x,%x,%0d,%0d,%0d,%x,%x,%x,%08x,%x,%x,%x,%x,%x,%x,%x,%x,%x,%x,%x,%x,%02x,",
                pipeline_trace_cycle,
                dut.u_core.fetch_decode_valid,
                dut.u_core.fetch_decode_ready,
                dut.u_core.frontend_decode_fire,
                dut.u_core.backend_decode_valid,
                dut.u_core.backend_decode_ready,
                dut.u_core.frontend_decode_fire,
                dut.u_core.backend_issue_valid,
                dut.u_core.backend_complete_valid,
                dut.u_core.u_backend.release_valid,
                dut.u_core.backend_retire_count,
                dut.u_core.backend_dispatch_occupancy,
                dut.u_core.backend_retire_occupancy,
                dut.u_core.u_backend.raw_hazard,
                dut.u_core.u_backend.waw_hazard,
                dut.u_core.u_backend.read_port_hazard,
                dut.u_core.backend_write_busy,
                dut.u_core.backend_barrier,
                dut.u_core.bp_branch_present,
                dut.u_core.bp_branch_allocate,
                dut.u_core.bp_prediction_taken,
                dut.u_core.bp_fetch_stall,
                dut.u_core.bp_decode_stall,
                dut.u_core.backend_redirect,
                dut.u_core.fetch_pipe_req_valid,
                dut.u_core.fetch_pipe_req_ready,
                dut.u_core.fetch_pipe_resp_valid,
                arvalid,
                arready,
                core_trace_stall_causes);
            $fwrite(pipeline_trace_fd,
                {"%x,%x,%x,%02x,%x,%x,%0d,%0d,%0d,",
                 "%x,%x,%x,%x,%x,%x,%x,%x,%x,%x,%04x,%04x,%04x,",
                 "%x,%02x,%0d,%0d,%0d,%x,%x,%0d,%0d,%0d,",
                 "%0d,%0d,%0d,%0d,%0d,",
                 {"%x,%x,%0d,%0d,%x,%04x,%048x,",
                  "%x,%016x,%016x,%02x,%x,%016x,"}},
                trace_candidate_valid,
                trace_candidate_fire,
                trace_candidate_hazard_free,
                trace_candidate_pipe,
                trace_pipe_ready,
                trace_barrier_allow,
                trace_allocation_ready,
                trace_block_lane,
                trace_block_reason,
                trace_raw_existing,
                trace_raw_bundle,
                trace_raw_completed,
                trace_raw_rs1,
                trace_raw_rs2,
                trace_waw_bundle,
                trace_waw_completed,
                trace_candidate_uses_rs1,
                trace_candidate_uses_rs2,
                trace_candidate_reg_write,
                trace_candidate_rs1,
                trace_candidate_rs2,
                trace_candidate_rd,
                trace_queue_retire_valid,
                trace_completed_entries,
                dut.u_core.control_flush,
                dut.u_core.control_redirect,
                trace_fetch_bus_count,
                trace_fetch_lines,
                trace_fetch_pending,
                trace_fetch_consume_hit,
                trace_fetch_follow_hit,
                trace_fetch_active,
                dut.u_core.backend_mem_valid,
                dut.u_core.backend_mem_ready,
                dut.u_core.backend_mem_resp_valid,
                dut.u_core.backend_mem_resp_ready,
                dut.u_core.backend_mem_write,
                trace_lsu_slots,
                trace_lsu_sent,
                trace_lsu_store_inflight,
                trace_lsu_order_block,
                dut.u_core.u_backend.gpr_write,
                dut.u_core.u_backend.gpr_write_addr,
                dut.u_core.u_backend.gpr_write_data,
                dut.u_core.backend_mem_tag,
                dut.u_core.backend_mem_addr,
                dut.u_core.backend_mem_wdata,
                dut.u_core.backend_mem_wstrb,
                dut.u_core.backend_mem_resp_tag,
                dut.u_core.backend_mem_rdata);
            $fwrite(pipeline_trace_fd,
                "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,",
                trace_window_unissued,
                trace_window_operand_ready,
                trace_window_eligible,
                trace_window_raw_block,
                trace_window_hard_block,
                trace_window_mem_order_block,
                trace_window_selected,
                trace_window_issued);
            $fdisplay(pipeline_trace_fd,
                {"%016x,%016x,%08x,%016x,%016x,%08x,%016x,%016x,%08x,",
                 "%016x,%016x,%08x,%016x,%016x,%08x,%016x,%016x,%08x,",
                 "%016x,%016x,%08x,%016x,%016x,%08x,%016x,%016x,%08x,",
                 "%016x,%016x,%08x,%016x,%016x,%08x,%016x,%016x,%08x,",
                 "%016x,%016x,%08x,%016x,%016x,%08x,%016x,%016x,%08x,",
                 "%016x,%016x,%08x,%016x,%016x,%08x,%016x,%016x,%08x"},
                dut.u_core.fetch_decode_trace[0*64 +: 64],
                dut.u_core.decode_pc0, dut.u_core.instr0,
                dut.u_core.fetch_decode_trace[1*64 +: 64],
                dut.u_core.decode_pc1, dut.u_core.instr1,
                dut.u_core.fetch_decode_trace[2*64 +: 64],
                dut.u_core.decode_pc2, dut.u_core.instr2,
                dut.u_core.fetch_decode_trace[0*64 +: 64],
                dut.u_core.decode_pc0, dut.u_core.instr0,
                dut.u_core.fetch_decode_trace[1*64 +: 64],
                dut.u_core.decode_pc1, dut.u_core.instr1,
                dut.u_core.fetch_decode_trace[2*64 +: 64],
                dut.u_core.decode_pc2, dut.u_core.instr2,
                trace_candidate_payload[
                    0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 338 +: 64],
                trace_candidate_payload[
                    0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 274 +: 64],
                trace_candidate_payload[
                    0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 242 +: 32],
                trace_candidate_payload[
                    1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 338 +: 64],
                trace_candidate_payload[
                    1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 274 +: 64],
                trace_candidate_payload[
                    1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 242 +: 32],
                trace_candidate_payload[
                    2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 338 +: 64],
                trace_candidate_payload[
                    2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 274 +: 64],
                trace_candidate_payload[
                    2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 242 +: 32],
                dut.u_core.u_backend.pipe_payload[
                    0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 338 +: 64],
                dut.u_core.u_backend.pipe_payload[
                    0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 274 +: 64],
                dut.u_core.u_backend.pipe_payload[
                    0*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 242 +: 32],
                dut.u_core.u_backend.pipe_payload[
                    1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 338 +: 64],
                dut.u_core.u_backend.pipe_payload[
                    1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 274 +: 64],
                dut.u_core.u_backend.pipe_payload[
                    1*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 242 +: 32],
                dut.u_core.u_backend.pipe_payload[
                    2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 338 +: 64],
                dut.u_core.u_backend.pipe_payload[
                    2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 274 +: 64],
                dut.u_core.u_backend.pipe_payload[
                    2*`OPENRV64_EXEC_ISSUE_PAYLOAD_WIDTH + 242 +: 32],
                dut.u_core.u_backend.complete_payload[
                    0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 393 +: 64],
                dut.u_core.u_backend.complete_payload[
                    0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 329 +: 64],
                dut.u_core.u_backend.complete_payload[
                    0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 233 +: 32],
                dut.u_core.u_backend.complete_payload[
                    1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 393 +: 64],
                dut.u_core.u_backend.complete_payload[
                    1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 329 +: 64],
                dut.u_core.u_backend.complete_payload[
                    1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 233 +: 32],
                dut.u_core.u_backend.complete_payload[
                    2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 393 +: 64],
                dut.u_core.u_backend.complete_payload[
                    2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 329 +: 64],
                dut.u_core.u_backend.complete_payload[
                    2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 233 +: 32],
                dut.u_core.u_backend.queue_retire_result[
                    0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 393 +: 64],
                dut.u_core.u_backend.queue_retire_result[
                    0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 329 +: 64],
                dut.u_core.u_backend.queue_retire_result[
                    0*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 233 +: 32],
                dut.u_core.u_backend.queue_retire_result[
                    1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 393 +: 64],
                dut.u_core.u_backend.queue_retire_result[
                    1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 329 +: 64],
                dut.u_core.u_backend.queue_retire_result[
                    1*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 233 +: 32],
                dut.u_core.u_backend.queue_retire_result[
                    2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 393 +: 64],
                dut.u_core.u_backend.queue_retire_result[
                    2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 329 +: 64],
                dut.u_core.u_backend.queue_retire_result[
                    2*`OPENRV64_EXEC_COMPLETE_PAYLOAD_WIDTH + 233 +: 32]);
            pipeline_trace_cycle = pipeline_trace_cycle + 1;
        end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            if (arvalid && arready) begin
                if (!first_r_seen &&
                    !arid[`OPENRV64_AXI_ID_WIDTH-1]) begin
                    fetch_ar_before_first_r <=
                        fetch_ar_before_first_r + 1;
                end
                if ((araddr >= `OPENRV64_SOC_MEMORY_BASE) &&
                    (araddr < (`OPENRV64_SOC_MEMORY_BASE +
                               `OPENRV64_SOC_MEMORY_SIZE))) begin
                    if (!arid[`OPENRV64_AXI_ID_WIDTH-1] &&
                        ((arsize != 3'd5) || (araddr[4:0] != 5'd0))) begin
                        $fatal(1,
                               "frontend RAM access was not one aligned 256-bit AXI beat");
                    end
                    saw_ram_axi <= 1'b1;
                end
                if ((araddr >= `OPENRV64_SOC_GPIO_BASE) &&
                    (araddr < (`OPENRV64_SOC_GPIO_BASE +
                               `OPENRV64_SOC_GPIO_SIZE))) begin
                    saw_gpio_axi_read <= 1'b1;
                end
                if (!arid[`OPENRV64_AXI_ID_WIDTH-1] &&
                    (araddr == (`OPENRV64_SOC_MEMORY_BASE + 64'h20)))
                    loop_line_fetches <= loop_line_fetches + 1;
            end
            if (rvalid && rready)
                first_r_seen <= 1'b1;
            if (awvalid && awready &&
                (awaddr >= `OPENRV64_SOC_GPIO_BASE) &&
                (awaddr < (`OPENRV64_SOC_GPIO_BASE +
                           `OPENRV64_SOC_GPIO_SIZE))) begin
                saw_gpio_axi_write <= 1'b1;
            end
            if (dut.u_core.backend_retire_count == 3)
                saw_three_retire <= 1'b1;
            if (dut.u_core.bp_branch_allocate) begin
                bp_allocations <= bp_allocations + 1;
                if (dut.u_core.bp_prediction_taken)
                    bp_taken_predictions <= bp_taken_predictions + 1;
            end
            if (FREE_BRANCHES != 0)
                bp_resolutions <= bp_resolutions +
                    {2'd0, trace_free_branch_complete[0]} +
                    {2'd0, trace_free_branch_complete[1]} +
                    {2'd0, trace_free_branch_complete[2]} +
                    trace_exec_branch_resolved;
            else if (dut.u_core.branch_resolved)
                bp_resolutions <= bp_resolutions + 1;
            if (dut.u_core.backend_redirect)
                bp_corrections <= bp_corrections + 1;
            if (ISSUE_WINDOW == 0)
                eq_branch_pairings <= eq_branch_pairings +
                    (dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.pair_eq0 &&
                     dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.candidate_fire[1]) +
                    (dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.pair_eq1 &&
                     dut.u_core.u_backend.u_dispatch.g_3p.u_dispatch.candidate_fire[2]);
            if ((branch_oracle_dump_fd != 0) &&
                dut.u_core.branch_resolved) begin
                $fwrite(branch_oracle_dump_fd, "%017h\n",
                        {dut.u_core.branch_taken,
                         dut.u_core.backend_redirect_target});
                branch_oracle_dump_count = branch_oracle_dump_count + 1;
            end
            if ((ORACLE_BRANCHES != 0) &&
                dut.u_core.bp_branch_allocate) begin
                if (branch_oracle_consumed < branch_oracle_expected) begin
                    branch_oracle_consumed = branch_oracle_consumed + 1;
                    if (branch_oracle_consumed < branch_oracle_expected) begin
                        branch_oracle_taken =
                            branch_oracle[branch_oracle_consumed][64];
                        branch_oracle_target =
                            branch_oracle[branch_oracle_consumed][63:0];
                    end
                end else begin
                    // The frontend can allocate controls younger than the
                    // terminating EBREAK. They never resolve and therefore
                    // correctly have no record in the oracle stream.
                    branch_oracle_extra_allocations =
                        branch_oracle_extra_allocations + 1;
                end
            end
            if (memory_valid)
                $fatal(1, "native AXI RAM request leaked into the 64-bit SoC bus");
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        fetch_ar_before_first_r = 0;
        first_r_seen = 1'b0;
        saw_ram_axi = 1'b0;
        saw_gpio_axi_read = 1'b0;
        saw_gpio_axi_write = 1'b0;
        saw_three_retire = 1'b0;
        external_image = 1'b0;
        external_done = 1'b0;
        done_pc_valid = 1'b0;
        expect_a0_valid = 1'b0;
        done_pc = 64'd0;
        expected_a0 = 64'd0;
        max_cycles = 20000;
        perf_retired = 0;
        perf_issued = 0;
        retire_width_0 = 0;
        retire_width_1 = 0;
        retire_width_2 = 0;
        retire_width_3 = 0;
        issue_width_0 = 0;
        issue_width_1 = 0;
        issue_width_2 = 0;
        issue_width_3 = 0;
        axi_fetch_reads = 0;
        axi_data_reads = 0;
        axi_ram_reads = 0;
        axi_mmio_reads = 0;
        axi_ram_writes = 0;
        axi_mmio_writes = 0;
        bp_allocations = 0;
        bp_taken_predictions = 0;
        bp_resolutions = 0;
        bp_corrections = 0;
        eq_branch_pairings = 0;
        branch_forward_issues = 0;
        branch_forward_operands = 0;
        loop_line_fetches = 0;
        perf_block_none = 0;
        perf_block_raw_pending = 0;
        perf_block_raw_bundle = 0;
        perf_block_raw_completed = 0;
        perf_block_waw_pending = 0;
        perf_block_waw_bundle = 0;
        perf_block_waw_completed = 0;
        perf_block_read_port = 0;
        perf_block_barrier = 0;
        perf_block_retire_capacity = 0;
        perf_block_pipe_conflict = 0;
        perf_block_pipe_busy = 0;
        perf_block_invalid_pipe = 0;
        perf_block_branch_redirect = 0;
        perf_block_unknown = 0;
        perf_retire_head_incomplete = 0;
        perf_retire_completed_behind_head = 0;
        perf_retire_control_block = 0;
        perf_frontend_empty = 0;
        perf_frontend_held = 0;
        perf_frontend_request_wait = 0;
        perf_frontend_redirect = 0;
        perf_frontend_refill_wait = 0;
        perf_frontend_no_line = 0;
        perf_frontend_bp_stall = 0;
        perf_frontend_control = 0;
        perf_frontend_other_empty = 0;
        perf_lsu_pipe_block = 0;
        perf_lsu_request_wait = 0;
        perf_lsu_outstanding = 0;
        perf_lsu_order_block = 0;
        branch_oracle_taken = 1'b0;
        branch_oracle_target = 64'd0;
        branch_oracle_dump_fd = 0;
        branch_oracle_dump_count = 0;
        branch_oracle_consumed = 0;
        branch_oracle_expected = 0;
        branch_oracle_extra_allocations = 0;
        pipeline_trace_fd = 0;
        pipeline_trace_cycle = 0;
        pipeline_trace_path = "sim/top-axi-3p-trace.csv";

        // Let the native 256-bit, 16 MiB AXI RAM finish zero initialization,
        // then load an external 256-bit image or install the directed test.
        #1;
        external_image = $value$plusargs("memh=%s", memh_path);
        done_pc_valid = $value$plusargs("done_pc=%h", done_pc);
        expect_a0_valid = $value$plusargs("expect_a0=%h", expected_a0);
        if (!$value$plusargs("max_cycles=%d", max_cycles))
            max_cycles = 20000;
        if ($value$plusargs("branch_oracle_dump=%s",
                            branch_oracle_dump_path)) begin
            branch_oracle_dump_fd = $fopen(branch_oracle_dump_path, "w");
            if (branch_oracle_dump_fd == 0)
                $fatal(1, "could not open branch oracle dump %0s",
                       branch_oracle_dump_path);
        end
        if (ORACLE_BRANCHES != 0) begin
            if (!$value$plusargs("branch_oracle_load=%s",
                                 branch_oracle_load_path))
                $fatal(1, "oracle run requires +branch_oracle_load=<path>");
            if (!$value$plusargs("branch_oracle_count=%d",
                                 branch_oracle_expected) ||
                (branch_oracle_expected <= 0) ||
                (branch_oracle_expected > BRANCH_ORACLE_DEPTH))
                $fatal(1, "oracle run requires a valid +branch_oracle_count");
            $readmemh(branch_oracle_load_path, branch_oracle,
                      0, branch_oracle_expected - 1);
            branch_oracle_taken = branch_oracle[0][64];
            branch_oracle_target = branch_oracle[0][63:0];
            force dut.u_core.bp_prediction_taken = branch_oracle_taken;
            force dut.u_core.bp_predict_target = branch_oracle_target;
            // The oracle replaces both direction and target prediction.  A
            // live RAS may otherwise compare its own outstanding target at
            // resolution and inject a target-mispredict redirect even though
            // the forced oracle target was correct.
            force dut.u_core.bp_target_mispredict = 1'b0;
            force dut.u_core.bp_fetch_stall = 1'b0;
            force dut.u_core.bp_decode_stall = 1'b0;
            $display("BRANCH_ORACLE load=%0s records=%0d",
                     branch_oracle_load_path, branch_oracle_expected);
        end
        if (external_image) begin
            if (!$value$plusargs("pipeline_trace=%s", pipeline_trace_path))
                pipeline_trace_path = "sim/top-axi-3p-trace.csv";
            pipeline_trace_fd = $fopen(pipeline_trace_path, "w");
            if (pipeline_trace_fd == 0)
                $fatal(1, "could not open 3P pipeline trace %0s",
                       pipeline_trace_path);
            $fdisplay(pipeline_trace_fd,
                {"schema,cycle,fetch_valid,fetch_ready,fetch_fire,decode_valid,decode_ready,decode_fire,issue_valid,complete_valid,retire_valid,retire_count,dispatch_q,retire_q,raw,waw,read_port,write_busy,barrier,bp_present,bp_allocate,bp_taken,bp_fetch_stall,bp_decode_stall,redirect,fetch_req_valid,fetch_req_ready,fetch_resp_valid,axi_arvalid,axi_arready,stall_causes,",
                 "queue_valid,candidate_fire,candidate_hazard_free,candidate_pipe,pipe_ready,barrier_allow,allocation_ready,block_lane,block_reason,raw_existing,raw_bundle,raw_completed,raw_rs1,raw_rs2,waw_bundle,waw_completed,candidate_uses_rs1,candidate_uses_rs2,candidate_reg_write,candidate_rs1,candidate_rs2,candidate_rd,queue_retire_valid,completed_entries,control_flush,control_redirect,fetch_bus_q,fetch_line_valid,fetch_pending,fetch_consume_hit,fetch_follow_hit,fetch_active,mem_req_valid,mem_req_ready,mem_resp_valid,mem_resp_ready,mem_write,lsu_slots,lsu_sent,lsu_store_inflight,lsu_order_block,retire_gpr_write,retire_gpr_rd,retire_gpr_data,mem_req_tag,mem_req_addr,mem_req_wdata,mem_req_wstrb,mem_resp_tag,mem_resp_rdata,",
                 "window_unissued,window_operand_ready,window_eligible,window_raw_block,window_hard_block,window_mem_order_block,window_selected,window_issued,",
                 "f0_uid,f0_pc,f0_instr,f1_uid,f1_pc,f1_instr,f2_uid,f2_pc,f2_instr,",
                 "d0_uid,d0_pc,d0_instr,d1_uid,d1_pc,d1_instr,d2_uid,d2_pc,d2_instr,",
                 "q0_uid,q0_pc,q0_instr,q1_uid,q1_pc,q1_instr,q2_uid,q2_pc,q2_instr,",
                 "i0_uid,i0_pc,i0_instr,i1_uid,i1_pc,i1_instr,i2_uid,i2_pc,i2_instr,",
                 "c0_uid,c0_pc,c0_instr,c1_uid,c1_pc,c1_instr,c2_uid,c2_pc,c2_instr,",
                 "r0_uid,r0_pc,r0_instr,r1_uid,r1_pc,r1_instr,r2_uid,r2_pc,r2_instr"});
            $display("TRACE pipeline=%0s", pipeline_trace_path);
            $readmemh(memh_path, u_axi_fabric.ram_q, 0, 2047);
        end else begin
            put_instr('h00, enc_auipc(5'd1, 20'h00000));
            put_instr('h04, enc_addi(5'd13, 5'd0, 12'd0));
            put_instr('h08, enc_addi(5'd14, 5'd0, 12'd0));
            put_instr('h0c, enc_load(5'd5, 5'd1, 12'h100,
                                      `RV64_FUNCT3_LD));
            put_instr('h10, enc_addi(5'd6, 5'd0, 12'd22));
            put_instr('h14, enc_addi(5'd8, 5'd0, 12'd1));
            put_instr('h18, enc_add(5'd7, 5'd5, 5'd6));
            put_instr('h1c, enc_addi(5'd13, 5'd0, 12'd3));
            put_instr('h20, enc_addi(5'd14, 5'd14, 12'd1));
            put_instr('h24, enc_addi(5'd13, 5'd13, 12'hfff));
            put_instr('h28, enc_branch(`RV64_FUNCT3_BNE, 5'd13, 5'd0,
                                        13'h1ff8));
            put_instr('h2c, enc_lui(5'd9, 20'h10010));
            put_instr('h30, enc_addi(5'd10, 5'd0, 12'h05a));
            put_instr('h34, enc_store(5'd10, 5'd9, 12'h008,
                                      `RV64_FUNCT3_SW));
            put_instr('h38, enc_load(5'd11, 5'd9, 12'h008,
                                     `RV64_FUNCT3_LW));
            put_instr('h3c, enc_store(5'd11, 5'd1, 12'h108,
                                      `RV64_FUNCT3_SD));
            put_instr('h40, enc_load(5'd12, 5'd1, 12'h108,
                                     `RV64_FUNCT3_LD));
            put_instr('h44, 32'h0010_0073); // EBREAK
            u_axi_fabric.ram_q[8][63:0] = 64'd11;
        end

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        if (external_image) begin
            for (cycles = 0; cycles < max_cycles && !external_done;
                 cycles = cycles + 1) begin
                @(posedge clk);
                #1;
                sample_performance();
                sample_pipeline_trace();
                if (dbg_halted)
                    external_done = 1'b1;
                if (done_pc_valid &&
                    (|dut.u_core.backend_retire_arch) &&
                    (dut.u_core.backend_retire_pc == done_pc))
                    external_done = 1'b1;
            end

            if (!external_done)
                $fatal(1,
                       "external AXI image timed out: cycles=%0d retired=%0d pc=%016x",
                       cycles, perf_retired, dbg_pc);
            if (expect_a0_valid &&
                (dut.u_core.u_backend.u_gpr.regs[10] != expected_a0))
                $fatal(1, "external image a0=%016x expected=%016x",
                       dut.u_core.u_backend.u_gpr.regs[10], expected_a0);

            $display("PERF cycles=%0d retired=%0d IPC=%0.4f issued=%0d issue_per_cycle=%0.4f a0=%016x halted=%b",
                     cycles, perf_retired,
                     $itor(perf_retired) / $itor(cycles), perf_issued,
                     $itor(perf_issued) / $itor(cycles),
                     dut.u_core.u_backend.u_gpr.regs[10], dbg_halted);
            $display("PERF_RETIRE_WIDTH w0=%0d w1=%0d w2=%0d w3=%0d",
                     retire_width_0, retire_width_1,
                     retire_width_2, retire_width_3);
            $display("PERF_ISSUE_WIDTH w0=%0d w1=%0d w2=%0d w3=%0d",
                     issue_width_0, issue_width_1,
                     issue_width_2, issue_width_3);
            $display("PERF_AXI fetch_reads=%0d data_reads=%0d ram_reads=%0d mmio_reads=%0d ram_writes=%0d mmio_writes=%0d",
                     axi_fetch_reads, axi_data_reads, axi_ram_reads,
                     axi_mmio_reads, axi_ram_writes, axi_mmio_writes);
            $display("PERF_BP allocations=%0d taken_predictions=%0d resolutions=%0d corrections=%0d update_overflow=%0d",
                     bp_allocations, bp_taken_predictions,
                     bp_resolutions, bp_corrections,
                     dut.u_core.bp_update_overflow);
            $display("PERF_BRANCH_PAIR useful=%0d", eq_branch_pairings);
            $display("PERF_BRANCH_FORWARD issues=%0d operands=%0d",
                     branch_forward_issues, branch_forward_operands);
            if (((BP_TYPE == `OPENRV64_BP_BIMODAL) ||
                 (BP_TYPE == `OPENRV64_BP_GSHARE_BTB)) &&
                dut.u_core.bp_update_overflow)
                $fatal(1, "branch predictor update/record queue overflowed");
            $display({"PERF_CONFIG retire_depth=%0d completion_mask=%03b ",
                      "branch_forward_mask=%03b ",
                      "full=%0d relax_waw=%0d relax_hazards=%0d ",
                      "issue_window=%0d speculation_window=%0d ",
                      "free_branches=%0d eq_pair=%0d"},
                     RETIRE_DEPTH, COMPLETION_FORWARD_MASK,
                     BRANCH_FORWARD_MASK,
                     FULL_FORWARDING, RELAX_WAW, RELAX_HAZARDS,
                     ISSUE_WINDOW, SPECULATION_WINDOW,
                     FREE_BRANCHES, EQ_BRANCH_PAIRING);
            $display({"PERF_BLOCK none=%0d raw_pending=%0d raw_bundle=%0d ",
                      "raw_completed=%0d waw_pending=%0d waw_bundle=%0d ",
                      "waw_completed=%0d ",
                      "read_port=%0d barrier=%0d retire_capacity=%0d ",
                      "pipe_conflict=%0d pipe_busy=%0d invalid_pipe=%0d ",
                      "branch_redirect=%0d unknown=%0d"},
                     perf_block_none,
                     perf_block_raw_pending,
                     perf_block_raw_bundle,
                     perf_block_raw_completed,
                     perf_block_waw_pending,
                     perf_block_waw_bundle,
                     perf_block_waw_completed,
                     perf_block_read_port,
                     perf_block_barrier,
                     perf_block_retire_capacity,
                     perf_block_pipe_conflict,
                     perf_block_pipe_busy,
                     perf_block_invalid_pipe,
                     perf_block_branch_redirect,
                     perf_block_unknown);
            $display("PERF_RETIRE_BLOCK head_incomplete=%0d completed_behind_head=%0d control_block=%0d",
                     perf_retire_head_incomplete,
                     perf_retire_completed_behind_head,
                     perf_retire_control_block);
            $display({"PERF_FRONTEND empty=%0d held=%0d request_wait=%0d ",
                      "redirect=%0d refill_wait=%0d no_line=%0d ",
                      "bp_stall=%0d control=%0d other_empty=%0d"},
                     perf_frontend_empty, perf_frontend_held,
                     perf_frontend_request_wait, perf_frontend_redirect,
                     perf_frontend_refill_wait, perf_frontend_no_line,
                     perf_frontend_bp_stall, perf_frontend_control,
                     perf_frontend_other_empty);
            $display("PERF_LSU pipe_block=%0d request_wait=%0d outstanding=%0d order_block=%0d",
                     perf_lsu_pipe_block, perf_lsu_request_wait,
                     perf_lsu_outstanding, perf_lsu_order_block);
            if (branch_oracle_dump_fd != 0) begin
                $fclose(branch_oracle_dump_fd);
                branch_oracle_dump_fd = 0;
                $display("PERF_BRANCH_ORACLE_DUMP path=%0s records=%0d",
                         branch_oracle_dump_path,
                         branch_oracle_dump_count);
            end
            if (ORACLE_BRANCHES != 0) begin
                if (branch_oracle_consumed != branch_oracle_expected)
                    $fatal(1,
                           "branch oracle consumed=%0d expected=%0d",
                           branch_oracle_consumed,
                           branch_oracle_expected);
                if ((bp_resolutions != branch_oracle_expected) ||
                    (bp_corrections != 0))
                    $fatal(1,
                           "branch oracle resolutions=%0d expected=%0d corrections=%0d",
                           bp_resolutions, branch_oracle_expected,
                           bp_corrections);
                $display("PERF_BRANCH_ORACLE consumed=%0d extra_unresolved_allocations=%0d",
                         branch_oracle_consumed,
                         branch_oracle_extra_allocations);
            end
            $fclose(pipeline_trace_fd);
            pipeline_trace_fd = 0;
            $display("PERF_TRACE pipeline=%0s", pipeline_trace_path);
            $finish;
        end

        for (cycles = 0; cycles < 3000 && !dbg_halted;
             cycles = cycles + 1) begin
            @(posedge clk);
            #1;
        end

        if (!dbg_halted)
            $fatal(1, "AXI/SoC 3P core did not halt, pc=%016x", dbg_pc);
        if (fetch_ar_before_first_r < 2)
            $fatal(1, "frontend did not pipeline AXI reads");
        if (!saw_ram_axi)
            $fatal(1, "core did not fetch from native 16 MiB AXI RAM");
        if (!saw_gpio_axi_write || !saw_gpio_axi_read)
            $fatal(1, "firmware did not traverse the AXI-to-SoC MMIO path");
        if (!saw_three_retire)
            $fatal(1, "AXI/SoC 3P core never retired three instructions");
        if (gpio_out != 32'h0000_005a)
            $fatal(1, "GPIO AXI write/readback mismatch: %08x", gpio_out);
        if (u_axi_fabric.ram_q[8][127:64] !=
            64'h0000_0000_0000_005a)
            $fatal(1, "16 MiB RAM AXI store mismatch: %016x",
                   u_axi_fabric.ram_q[8][127:64]);
        if (dut.u_core.u_backend.u_gpr.regs[5] != 64'd11 ||
            dut.u_core.u_backend.u_gpr.regs[6] != 64'd22 ||
            dut.u_core.u_backend.u_gpr.regs[7] != 64'd33 ||
            dut.u_core.u_backend.u_gpr.regs[8] != 64'd1 ||
            dut.u_core.u_backend.u_gpr.regs[13] != 64'd0 ||
            dut.u_core.u_backend.u_gpr.regs[14] != 64'd3 ||
            dut.u_core.u_backend.u_gpr.regs[11] != 64'h5a ||
            dut.u_core.u_backend.u_gpr.regs[12] != 64'h5a) begin
            $fatal(1, "AXI/SoC architectural GPR results are wrong");
        end

        if ((bp_allocations < 3) || (bp_resolutions != 3))
            $fatal(1,
                   "3P BP control count mismatch: allocated=%0d resolved=%0d",
                   bp_allocations, bp_resolutions);
        case (BP_TYPE)
            `OPENRV64_BP_ALWAYS_BRANCH: begin
                if ((bp_taken_predictions != bp_allocations) ||
                    (bp_corrections != 1))
                    $fatal(1, "always-taken 3P BP mismatch p=%0d c=%0d",
                           bp_taken_predictions, bp_corrections);
            end
            `OPENRV64_BP_BTFNT,
            `OPENRV64_BP_BIMODAL,
            `OPENRV64_BP_GSHARE_BTB: begin
                if ((bp_taken_predictions != bp_allocations) ||
                    (bp_corrections != 1))
                    $fatal(1, "BTFNT/bimodal 3P BP mismatch p=%0d c=%0d",
                           bp_taken_predictions, bp_corrections);
            end
            `OPENRV64_BP_REPEAT_LAST: begin
                if ((bp_taken_predictions != (bp_allocations - 1)) ||
                    (bp_corrections != 2))
                    $fatal(1, "repeat-last 3P BP mismatch p=%0d c=%0d",
                           bp_taken_predictions, bp_corrections);
            end
            default: begin
                if ((bp_taken_predictions != 0) || (bp_corrections != 2))
                    $fatal(1, "not-taken/stall 3P BP mismatch p=%0d c=%0d",
                           bp_taken_predictions, bp_corrections);
            end
        endcase
        if (loop_line_fetches != 1)
            $fatal(1, "resident 32-byte loop line was fetched %0d times",
                   loop_line_fetches);

        $display("PASS: AXI 3P BP type %0d used resident loop line once and completed SoC MMIO flow",
                 BP_TYPE);
        $finish;
    end

endmodule
