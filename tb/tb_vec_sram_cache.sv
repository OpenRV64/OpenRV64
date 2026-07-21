`timescale 1ns/1ps

module tb_vec_sram_cache;

    localparam integer CLIENTS = 2;
    localparam integer CLIENT_TAG_WIDTH = 8;
    localparam integer CLIENT_DATA_WIDTH = 256;
    localparam integer MEM_DATA_WIDTH = 64;
    localparam integer MEM_TAG_WIDTH = 8;
    localparam integer MEMORY_WORDS = 262144;

    reg clk;
    reg rst_n;
    reg [CLIENTS-1:0] client_req_valid;
    wire [CLIENTS-1:0] client_req_ready;
    reg [CLIENTS*CLIENT_TAG_WIDTH-1:0] client_req_tag;
    reg [CLIENTS-1:0] client_req_write;
    reg [CLIENTS*64-1:0] client_req_addr;
    reg [CLIENTS*CLIENT_DATA_WIDTH-1:0] client_req_wdata;
    reg [CLIENTS*(CLIENT_DATA_WIDTH/8)-1:0] client_req_wstrb;
    wire [CLIENTS-1:0] client_resp_valid;
    reg [CLIENTS-1:0] client_resp_ready;
    wire [CLIENTS*CLIENT_TAG_WIDTH-1:0] client_resp_tag;
    wire [CLIENTS*CLIENT_DATA_WIDTH-1:0] client_resp_rdata;
    wire [CLIENTS-1:0] client_resp_error;
    wire [CLIENTS-1:0] client_resp_retry;

    reg prefetch_valid;
    wire prefetch_ready;
    reg [63:0] prefetch_addr;
    reg [3:0] prefetch_count;
    reg prefetch_streaming;
    wire prefetch_busy;

    wire mem_req_valid;
    reg mem_req_ready;
    wire [MEM_TAG_WIDTH-1:0] mem_req_tag;
    wire mem_req_write;
    wire [63:0] mem_req_addr;
    wire [MEM_DATA_WIDTH-1:0] mem_req_wdata;
    wire [(MEM_DATA_WIDTH/8)-1:0] mem_req_wstrb;
    reg mem_resp_valid;
    wire mem_resp_ready;
    reg [MEM_TAG_WIDTH-1:0] mem_resp_tag;
    reg [MEM_DATA_WIDTH-1:0] mem_resp_rdata;
    reg mem_resp_error;
    reg mem_resp_retry;
    wire replay;
    wire busy;

    reg [63:0] memory [0:MEMORY_WORDS-1];
    reg retry_enable_q;
    reg retry_used_q;
    reg [63:0] retry_addr_q;
    integer external_request_count_q;
    integer external_write_count_q;
    integer replay_count_q;

    openrv64_vec_sram_cache #(
        .ADDR_WIDTH(64), .CLIENT_DATA_WIDTH(CLIENT_DATA_WIDTH),
        .MEM_DATA_WIDTH(MEM_DATA_WIDTH), .CLIENTS(CLIENTS),
        .CLIENT_TAG_WIDTH(CLIENT_TAG_WIDTH),
        .MEM_TAG_WIDTH(MEM_TAG_WIDTH),
        .CACHE_BYTES(256 * 1024), .LINE_BYTES(64), .WAYS(4),
        .MSHRS(8)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .client_req_valid_i(client_req_valid),
        .client_req_ready_o(client_req_ready),
        .client_req_tag_i(client_req_tag),
        .client_req_write_i(client_req_write),
        .client_req_addr_i(client_req_addr),
        .client_req_wdata_i(client_req_wdata),
        .client_req_wstrb_i(client_req_wstrb),
        .client_resp_valid_o(client_resp_valid),
        .client_resp_ready_i(client_resp_ready),
        .client_resp_tag_o(client_resp_tag),
        .client_resp_rdata_o(client_resp_rdata),
        .client_resp_error_o(client_resp_error),
        .client_resp_retry_o(client_resp_retry),
        .prefetch_valid_i(prefetch_valid),
        .prefetch_ready_o(prefetch_ready),
        .prefetch_addr_i(prefetch_addr),
        .prefetch_count_i(prefetch_count),
        .prefetch_streaming_i(prefetch_streaming),
        .prefetch_busy_o(prefetch_busy),
        .mem_req_valid_o(mem_req_valid),
        .mem_req_ready_i(mem_req_ready),
        .mem_req_tag_o(mem_req_tag),
        .mem_req_write_o(mem_req_write),
        .mem_req_addr_o(mem_req_addr),
        .mem_req_wdata_o(mem_req_wdata),
        .mem_req_wstrb_o(mem_req_wstrb),
        .mem_resp_valid_i(mem_resp_valid),
        .mem_resp_ready_o(mem_resp_ready),
        .mem_resp_tag_i(mem_resp_tag),
        .mem_resp_rdata_i(mem_resp_rdata),
        .mem_resp_error_i(mem_resp_error),
        .mem_resp_retry_i(mem_resp_retry),
        .replay_o(replay), .busy_o(busy)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_resp_valid <= 1'b0;
            mem_resp_tag <= {MEM_TAG_WIDTH{1'b0}};
            mem_resp_rdata <= {MEM_DATA_WIDTH{1'b0}};
            mem_resp_error <= 1'b0;
            mem_resp_retry <= 1'b0;
            retry_used_q <= 1'b0;
            external_request_count_q <= 0;
            external_write_count_q <= 0;
            replay_count_q <= 0;
        end else begin
            if ($test$plusargs("trace_vec_cache") &&
                dut.client_request_fire)
                $display("cache client=%0d %s addr=%x tag=%0d",
                    dut.selected_client,
                    dut.selected_write ? "write" : "read ",
                    dut.selected_addr, dut.selected_tag);
            if (replay)
                replay_count_q <= replay_count_q + 1;
            if (mem_resp_valid && mem_resp_ready)
                mem_resp_valid <= 1'b0;
            if (mem_req_valid && mem_req_ready) begin
                if ($test$plusargs("trace_vec_cache"))
                    $display("cache ext %s addr=%x tag=%0d",
                        mem_req_write ? "write" : "read ",
                        mem_req_addr, mem_req_tag);
                external_request_count_q <= external_request_count_q + 1;
                mem_resp_valid <= 1'b1;
                mem_resp_tag <= mem_req_tag;
                mem_resp_rdata <= memory[mem_req_addr[20:3]];
                mem_resp_error <= 1'b0;
                mem_resp_retry <= retry_enable_q && !retry_used_q &&
                                  (mem_req_addr == retry_addr_q);
                if (retry_enable_q && !retry_used_q &&
                    (mem_req_addr == retry_addr_q))
                    retry_used_q <= 1'b1;
                if (mem_req_write) begin
                    external_write_count_q <= external_write_count_q + 1;
                    if (mem_req_wstrb != 8'hff)
                        $fatal(1, "cache bypass store had partial strobe");
                    memory[mem_req_addr[20:3]] <= mem_req_wdata;
                end
            end
        end
    end

    task automatic init_line;
        input [63:0] base;
        input [63:0] seed;
        integer word_index;
        begin
            for (word_index = 0; word_index < 8;
                 word_index = word_index + 1)
                memory[(base >> 3) + word_index] = seed + word_index;
        end
    endtask

    task automatic issue_read;
        input integer client;
        input [63:0] address;
        input [CLIENT_TAG_WIDTH-1:0] tag;
        input [CLIENT_DATA_WIDTH-1:0] expected;
        integer timeout;
        begin
            @(negedge clk);
            client_req_addr[client*64 +: 64] = address;
            client_req_tag[client*CLIENT_TAG_WIDTH +:
                           CLIENT_TAG_WIDTH] = tag;
            client_req_write[client] = 1'b0;
            client_req_wdata[client*CLIENT_DATA_WIDTH +:
                             CLIENT_DATA_WIDTH] =
                {CLIENT_DATA_WIDTH{1'b0}};
            client_req_wstrb[client*(CLIENT_DATA_WIDTH/8) +:
                             (CLIENT_DATA_WIDTH/8)] =
                {(CLIENT_DATA_WIDTH/8){1'b0}};
            client_req_valid[client] = 1'b1;
            #1;
            timeout = 0;
            while (!client_req_ready[client] && timeout < 500) begin
                @(negedge clk);
                #1;
                timeout = timeout + 1;
            end
            if (!client_req_ready[client])
                $fatal(1,
                    "client %0d addr=%x read request timed out free=%0b hit=%0b busy=%0b victim=%0b valid=%0b meta=%0b%0b%0b%0b m=%0b%0b%0b%0b%0b%0b%0b%0b",
                    client, address, dut.free_mshr_found,
                    dut.client_hit_q[client],
                    dut.client_line_busy_q[client],
                    dut.client_victim_found_q[client],
                    client_req_valid[client], dut.valid_q[19],
                    dut.valid_q[18], dut.valid_q[17], dut.valid_q[16],
                    dut.mshr_valid_q[7], dut.mshr_valid_q[6],
                    dut.mshr_valid_q[5], dut.mshr_valid_q[4],
                    dut.mshr_valid_q[3], dut.mshr_valid_q[2],
                    dut.mshr_valid_q[1], dut.mshr_valid_q[0]);
            @(posedge clk);
            @(negedge clk);
            client_req_valid[client] = 1'b0;
            timeout = 0;
            while (!client_resp_valid[client] && timeout < 1000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!client_resp_valid[client])
                $fatal(1, "client %0d read response timed out", client);
            if (client_resp_tag[client*CLIENT_TAG_WIDTH +:
                                CLIENT_TAG_WIDTH] !== tag ||
                client_resp_error[client] || client_resp_retry[client] ||
                client_resp_rdata[client*CLIENT_DATA_WIDTH +:
                                  CLIENT_DATA_WIDTH] !== expected)
                $fatal(1,
                    "client %0d bad read response tag=%0d error=%0b data=%x",
                    client,
                    client_resp_tag[client*CLIENT_TAG_WIDTH +:
                                    CLIENT_TAG_WIDTH],
                    client_resp_error[client],
                    client_resp_rdata[client*CLIENT_DATA_WIDTH +:
                                      CLIENT_DATA_WIDTH]);
            @(posedge clk);
        end
    endtask

    task automatic issue_store;
        input integer client;
        input [63:0] address;
        input [CLIENT_TAG_WIDTH-1:0] tag;
        input [CLIENT_DATA_WIDTH-1:0] data;
        integer timeout;
        begin
            @(negedge clk);
            client_req_addr[client*64 +: 64] = address;
            client_req_tag[client*CLIENT_TAG_WIDTH +:
                           CLIENT_TAG_WIDTH] = tag;
            client_req_write[client] = 1'b1;
            client_req_wdata[client*CLIENT_DATA_WIDTH +:
                             CLIENT_DATA_WIDTH] = data;
            client_req_wstrb[client*(CLIENT_DATA_WIDTH/8) +:
                             (CLIENT_DATA_WIDTH/8)] =
                {(CLIENT_DATA_WIDTH/8){1'b1}};
            client_req_valid[client] = 1'b1;
            #1;
            timeout = 0;
            while (!client_req_ready[client] && timeout < 500) begin
                @(negedge clk);
                #1;
                timeout = timeout + 1;
            end
            if (!client_req_ready[client])
                $fatal(1, "client store request timed out");
            @(posedge clk);
            @(negedge clk);
            client_req_valid[client] = 1'b0;
            timeout = 0;
            while (!client_resp_valid[client] && timeout < 1000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!client_resp_valid[client] ||
                client_resp_tag[client*CLIENT_TAG_WIDTH +:
                                CLIENT_TAG_WIDTH] !== tag ||
                client_resp_error[client] || client_resp_retry[client])
                $fatal(1, "bad cache bypass-store response");
            @(posedge clk);
        end
    endtask

    task automatic issue_prefetch;
        input [63:0] address;
        input [3:0] count;
        input streaming;
        integer timeout;
        begin
            @(negedge clk);
            prefetch_addr = address;
            prefetch_count = count;
            prefetch_streaming = streaming;
            prefetch_valid = 1'b1;
            #1;
            timeout = 0;
            while (!prefetch_ready && timeout < 500) begin
                @(negedge clk);
                #1;
                timeout = timeout + 1;
            end
            if (!prefetch_ready)
                $fatal(1, "prefetch descriptor timed out");
            @(posedge clk);
            @(negedge clk);
            prefetch_valid = 1'b0;
            timeout = 0;
            while (prefetch_busy && timeout < 4000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (prefetch_busy)
                $fatal(1, "prefetch fill timed out");
        end
    endtask

    integer requests_before;
    integer writes_before;
    reg [255:0] expected;
    reg [255:0] replacement_data;
    initial begin
        client_req_valid = {CLIENTS{1'b0}};
        client_req_tag = {CLIENTS*CLIENT_TAG_WIDTH{1'b0}};
        client_req_write = {CLIENTS{1'b0}};
        client_req_addr = {CLIENTS*64{1'b0}};
        client_req_wdata = {CLIENTS*CLIENT_DATA_WIDTH{1'b0}};
        client_req_wstrb =
            {CLIENTS*(CLIENT_DATA_WIDTH/8){1'b0}};
        client_resp_ready = {CLIENTS{1'b1}};
        prefetch_valid = 1'b0;
        prefetch_addr = 64'd0;
        prefetch_count = 4'd0;
        prefetch_streaming = 1'b0;
        mem_req_ready = 1'b1;
        retry_enable_q = 1'b0;
        retry_addr_q = 64'd0;

        init_line(64'h100, 64'h1000);
        init_line(64'h200, 64'h2000);
        init_line(64'h300, 64'h3000);
        init_line(64'h400, 64'h4000);
        init_line(64'h440, 64'h4400);
        init_line(64'h1000, 64'h10000);
        init_line(64'h11000, 64'h110000);
        init_line(64'h21000, 64'h210000);
        init_line(64'h31000, 64'h310000);
        init_line(64'h41000, 64'h410000);
        init_line(64'h800, 64'h8000);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // A demand miss fetches a whole line and hides an external retry.
        retry_enable_q = 1'b1;
        retry_addr_q = 64'h108;
        requests_before = external_request_count_q;
        expected = {64'h1003, 64'h1002, 64'h1001, 64'h1000};
        issue_read(0, 64'h100, 8'h11, expected);
        retry_enable_q = 1'b0;
        if (!retry_used_q || replay_count_q == 0 ||
            (external_request_count_q != requests_before + 9))
            $fatal(1, "cache did not internally retry one fill beat");
        requests_before = external_request_count_q;
        expected = {64'h1007, 64'h1006, 64'h1005, 64'h1004};
        issue_read(1, 64'h120, 8'h82, expected);
        if (external_request_count_q != requests_before)
            $fatal(1, "second wide word in resident line missed");

        // Both client ports can own independent tagged demand fills.
        fork
            begin
                issue_read(0, 64'h200, 8'h23,
                    {64'h2003, 64'h2002, 64'h2001, 64'h2000});
            end
            begin
                issue_read(1, 64'h300, 8'h94,
                    {64'h3003, 64'h3002, 64'h3001, 64'h3000});
            end
        join

        // An aged two-line descriptor is nonblocking at its input and makes
        // both lines hit when later demanded.
        requests_before = external_request_count_q;
        issue_prefetch(64'h400, 4'd2, 1'b0);
        if (external_request_count_q != requests_before + 16)
            $fatal(1, "two-line prefetch did not fetch two complete lines");
        requests_before = external_request_count_q;
        issue_read(0, 64'h400, 8'h35,
            {64'h4003, 64'h4002, 64'h4001, 64'h4000});
        issue_read(1, 64'h440, 8'ha6,
            {64'h4403, 64'h4402, 64'h4401, 64'h4400});
        if (external_request_count_q != requests_before)
            $fatal(1, "prefetched aged lines were not resident");

        // Four addresses separated by SETS*LINE_BYTES share a set. Touching
        // the last wide word makes the streaming line youngest and
        // discard-next; the fifth fill must still evict it before older data.
        issue_prefetch(64'h1000, 4'd1, 1'b1);
        issue_read(0, 64'h11000, 8'h41,
            {64'h110003, 64'h110002, 64'h110001, 64'h110000});
        issue_read(0, 64'h21000, 8'h42,
            {64'h210003, 64'h210002, 64'h210001, 64'h210000});
        issue_read(0, 64'h31000, 8'h43,
            {64'h310003, 64'h310002, 64'h310001, 64'h310000});
        issue_read(0, 64'h1020, 8'h44,
            {64'h10007, 64'h10006, 64'h10005, 64'h10004});
        issue_read(0, 64'h41000, 8'h45,
            {64'h410003, 64'h410002, 64'h410001, 64'h410000});
        requests_before = external_request_count_q;
        issue_read(0, 64'h11000, 8'h46,
            {64'h110003, 64'h110002, 64'h110001, 64'h110000});
        if (external_request_count_q != requests_before)
            $fatal(1, "streaming replacement evicted an aged line");
        issue_read(0, 64'h1000, 8'h47,
            {64'h10003, 64'h10002, 64'h10001, 64'h10000});
        if (external_request_count_q != requests_before + 8)
            $fatal(1, "consumed streaming line was not discard-next");

        // Stores bypass the read array as four 64-bit writes and invalidate
        // the old line. A following read must refill and observe new data.
        issue_read(0, 64'h800, 8'h51,
            {64'h8003, 64'h8002, 64'h8001, 64'h8000});
        replacement_data = {
            64'hdddd_dddd_dddd_dddd, 64'hcccc_cccc_cccc_cccc,
            64'hbbbb_bbbb_bbbb_bbbb, 64'haaaa_aaaa_aaaa_aaaa};
        writes_before = external_write_count_q;
        issue_store(0, 64'h800, 8'h52, replacement_data);
        if (external_write_count_q != writes_before + 4)
            $fatal(1,
                "wide bypass store was not split into four beats delta=%0d",
                external_write_count_q - writes_before);
        requests_before = external_request_count_q;
        issue_read(1, 64'h800, 8'hd3, replacement_data);
        if (external_request_count_q != requests_before + 8)
            $fatal(1, "store did not invalidate the resident cache line");

        if (busy || prefetch_busy)
            $fatal(1, "vector cache remained busy after all responses");
        $display("PASS: shared 256-bit vector SRAM cache over 64-bit bus");
        $display("      external_requests=%0d external_writes=%0d replays=%0d",
                 external_request_count_q, external_write_count_q,
                 replay_count_q);
        $finish;
    end

endmodule
