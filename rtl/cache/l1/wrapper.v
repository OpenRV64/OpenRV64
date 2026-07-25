`timescale 1ns/1ps

// Compile-time cache/bypass selector.  The external pinout is unchanged when
// ENABLE is zero, allowing a platform to retain cache maintenance wiring while
// sending every request directly to memory.
module openrv64_l1 #(
    parameter integer ENABLE = 1,
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 64,
    parameter integer REFILL_DATA_WIDTH = DATA_WIDTH,
    parameter integer REQ_TAG_WIDTH = 1,
    parameter integer DETACH_READ_MISSES = 0,
    parameter integer CACHE_BYTES = 16 * 1024,
    parameter integer LINE_BYTES = 64,
    parameter integer WAYS = 8,
    parameter integer WRITEBACK_TIMEOUT_CYCLES = 128,
    parameter integer DIRTY_TIMESTAMP_WIDTH =
        (WRITEBACK_TIMEOUT_CYCLES < 2) ? 1 :
        $clog2(WRITEBACK_TIMEOUT_CYCLES + 1)
) (
    input  wire                      clk_i,
    input  wire                      rst_ni,
    input  wire                      req_valid_i,
    output wire                      req_ready_o,
    input  wire [REQ_TAG_WIDTH-1:0]  req_tag_i,
    input  wire                      req_write_i,
    input  wire                      req_cacheable_i,
    input  wire [ADDR_WIDTH-1:0]     req_addr_i,
    input  wire [ADDR_WIDTH-1:0]     req_phys_addr_i,
    input  wire                      req_prefetch_i,
    input  wire                      req_aged_i,
    input  wire [DATA_WIDTH-1:0]     req_wdata_i,
    input  wire [DATA_WIDTH/8-1:0]   req_wstrb_i,
    output wire                      resp_valid_o,
    input  wire                      resp_ready_i,
    output wire [REQ_TAG_WIDTH-1:0]  resp_tag_o,
    output wire [DATA_WIDTH-1:0]     req_rdata_o,
    output wire                      req_error_o,
    output wire                      miss_valid_o,
    input  wire                      miss_ready_i,
    output wire [REQ_TAG_WIDTH-1:0]  miss_tag_o,
    output wire [ADDR_WIDTH-1:0]     miss_addr_o,
    output wire                      miss_aged_o,
    input  wire                      fill_valid_i,
    output wire                      fill_ready_o,
    input  wire [ADDR_WIDTH-1:0]     fill_addr_i,
    input  wire [REFILL_DATA_WIDTH-1:0] fill_data_i,
    input  wire                      fill_aged_i,
    input  wire                      invalidate_valid_i,
    output wire                      invalidate_ready_o,
    input  wire                      invalidate_all_i,
    input  wire [ADDR_WIDTH-1:0]     invalidate_addr_i,
    input  wire [3:0]                age_valid_i,
    input  wire [4*ADDR_WIDTH-1:0]   age_addr_i,
    output wire                      mem_valid_o,
    input  wire                      mem_ready_i,
    output wire                      mem_write_o,
    output wire [ADDR_WIDTH-1:0]     mem_addr_o,
    output wire [DATA_WIDTH-1:0]     mem_wdata_o,
    output wire [DATA_WIDTH/8-1:0]   mem_wstrb_o,
    input  wire [REFILL_DATA_WIDTH-1:0] mem_rdata_i,
    input  wire                      mem_error_i
);

    generate
        if (ENABLE != 0) begin : g_cache
            openrv64_l1_cache #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH),
                .REFILL_DATA_WIDTH(REFILL_DATA_WIDTH),
                .REQ_TAG_WIDTH(REQ_TAG_WIDTH),
                .DETACH_READ_MISSES(DETACH_READ_MISSES),
                .CACHE_BYTES(CACHE_BYTES),
                .LINE_BYTES(LINE_BYTES),
                .WAYS(WAYS),
                .WRITEBACK_TIMEOUT_CYCLES(WRITEBACK_TIMEOUT_CYCLES),
                .DIRTY_TIMESTAMP_WIDTH(DIRTY_TIMESTAMP_WIDTH)
            ) u_cache (
                .clk_i(clk_i),
                .rst_ni(rst_ni),
                .req_valid_i(req_valid_i),
                .req_ready_o(req_ready_o),
                .req_tag_i(req_tag_i),
                .req_write_i(req_write_i),
                .req_cacheable_i(req_cacheable_i),
                .req_addr_i(req_addr_i),
                .req_phys_addr_i(req_phys_addr_i),
                .req_prefetch_i(req_prefetch_i),
                .req_aged_i(req_aged_i),
                .req_wdata_i(req_wdata_i),
                .req_wstrb_i(req_wstrb_i),
                .resp_valid_o(resp_valid_o),
                .resp_ready_i(resp_ready_i),
                .resp_tag_o(resp_tag_o),
                .req_rdata_o(req_rdata_o),
                .req_error_o(req_error_o),
                .miss_valid_o(miss_valid_o),
                .miss_ready_i(miss_ready_i),
                .miss_tag_o(miss_tag_o),
                .miss_addr_o(miss_addr_o),
                .miss_aged_o(miss_aged_o),
                .fill_valid_i(fill_valid_i),
                .fill_ready_o(fill_ready_o),
                .fill_addr_i(fill_addr_i),
                .fill_data_i(fill_data_i),
                .fill_aged_i(fill_aged_i),
                .invalidate_valid_i(invalidate_valid_i),
                .invalidate_ready_o(invalidate_ready_o),
                .invalidate_all_i(invalidate_all_i),
                .invalidate_addr_i(invalidate_addr_i),
                .age_valid_i(age_valid_i),
                .age_addr_i(age_addr_i),
                .mem_valid_o(mem_valid_o),
                .mem_ready_i(mem_ready_i),
                .mem_write_o(mem_write_o),
                .mem_addr_o(mem_addr_o),
                .mem_wdata_o(mem_wdata_o),
                .mem_wstrb_o(mem_wstrb_o),
                .mem_rdata_i(mem_rdata_i),
                .mem_error_i(mem_error_i)
            );
        end else begin : g_bypass
            reg request_valid_q;
            reg [REQ_TAG_WIDTH-1:0] request_tag_q;
            reg request_write_q;
            reg [ADDR_WIDTH-1:0] request_addr_q;
            reg [DATA_WIDTH-1:0] request_wdata_q;
            reg [DATA_WIDTH/8-1:0] request_wstrb_q;
            reg response_valid_q;
            reg [REQ_TAG_WIDTH-1:0] response_tag_q;
            reg [DATA_WIDTH-1:0] response_data_q;
            reg response_error_q;

            assign req_ready_o = !request_valid_q &&
                                 (!response_valid_q || resp_ready_i);
            assign resp_valid_o = response_valid_q;
            assign resp_tag_o = response_tag_q;
            assign req_rdata_o = response_data_q;
            assign req_error_o = response_error_q;
            assign miss_valid_o = 1'b0;
            assign miss_tag_o = {REQ_TAG_WIDTH{1'b0}};
            assign miss_addr_o = {ADDR_WIDTH{1'b0}};
            assign miss_aged_o = 1'b0;
            assign fill_ready_o = 1'b0;
            assign invalidate_ready_o = !request_valid_q &&
                                        !response_valid_q;
            assign mem_valid_o = request_valid_q;
            assign mem_write_o = request_write_q;
            assign mem_addr_o = request_addr_q;
            assign mem_wdata_o = request_wdata_q;
            assign mem_wstrb_o = request_wstrb_q;

            always @(posedge clk_i or negedge rst_ni) begin
                if (!rst_ni) begin
                    request_valid_q <= 1'b0;
                    request_tag_q <= {REQ_TAG_WIDTH{1'b0}};
                    request_write_q <= 1'b0;
                    request_addr_q <= {ADDR_WIDTH{1'b0}};
                    request_wdata_q <= {DATA_WIDTH{1'b0}};
                    request_wstrb_q <= {DATA_WIDTH/8{1'b0}};
                    response_valid_q <= 1'b0;
                    response_tag_q <= {REQ_TAG_WIDTH{1'b0}};
                    response_data_q <= {DATA_WIDTH{1'b0}};
                    response_error_q <= 1'b0;
                end else begin
                    if (response_valid_q && resp_ready_i)
                        response_valid_q <= 1'b0;
                    if (req_valid_i && req_ready_o) begin
                        request_valid_q <= 1'b1;
                        request_tag_q <= req_tag_i;
                        request_write_q <= req_write_i;
                        request_addr_q <= req_phys_addr_i;
                        request_wdata_q <= req_wdata_i;
                        request_wstrb_q <= req_wstrb_i;
                    end
                    if (request_valid_q && mem_ready_i) begin
                        request_valid_q <= 1'b0;
                        response_valid_q <= 1'b1;
                        response_tag_q <= request_tag_q;
                        response_data_q <= mem_rdata_i[
                            DATA_WIDTH-1:0];
                        response_error_q <= mem_error_i;
                    end
                end
            end
        end
    endgenerate

endmodule
