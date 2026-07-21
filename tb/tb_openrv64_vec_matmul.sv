`timescale 1ns/1ps

module tb_openrv64_vec_matmul;

    localparam logic [63:0] RESET_VECTOR = 64'h100;
    localparam integer RESET_WORD = RESET_VECTOR >> 3;
    localparam integer MEM_WORDS = 256;
    localparam integer DATAPATH_WIDTH = 64;
    localparam integer MEM_TAG_WIDTH = 8;

    logic clk;
    logic rst_n;

    logic ifetch_valid;
    logic ifetch_ready;
    logic [63:0] ifetch_addr;
    logic [63:0] ifetch_rdata;
    logic ifetch_error;

    logic vec_mem_req_valid;
    logic vec_mem_req_ready;
    logic [MEM_TAG_WIDTH-1:0] vec_mem_req_tag;
    logic vec_mem_req_write;
    logic [63:0] vec_mem_req_addr;
    logic [DATAPATH_WIDTH-1:0] vec_mem_req_wdata;
    logic [(DATAPATH_WIDTH/8)-1:0] vec_mem_req_wstrb;
    logic vec_mem_resp_valid;
    logic vec_mem_resp_ready;
    logic [MEM_TAG_WIDTH-1:0] vec_mem_resp_tag;
    logic [DATAPATH_WIDTH-1:0] vec_mem_resp_rdata;
    logic vec_mem_resp_error;
    logic vec_mem_resp_retry;

    logic [63:0] dbg_pc;
    logic [31:0] dbg_instr;
    logic dbg_halted;
    logic dbg_error;
    logic dbg_vec_busy;
    logic dbg_vec_replay;
    logic [63:0] dbg_retired;

    logic [63:0] memory [0:MEM_WORDS-1];
    logic response_valid_q;
    logic [MEM_TAG_WIDTH-1:0] response_tag_q;
    logic [63:0] response_data_q;
    logic response_error_q;
    logic response_retry_q;
    logic retry_used_q;
    integer fetch_count_q;
    integer vec_request_count_q;
    integer vec_replay_count_q;

    wire ifetch_in_range = ifetch_addr[63:11] == 0;
    assign ifetch_ready = ifetch_valid;
    assign ifetch_rdata = ifetch_in_range ?
        memory[ifetch_addr[10:3]] : 64'd0;
    assign ifetch_error = ifetch_valid && !ifetch_in_range;

    assign vec_mem_req_ready = !response_valid_q || vec_mem_resp_ready;
    assign vec_mem_resp_valid = response_valid_q;
    assign vec_mem_resp_tag = response_tag_q;
    assign vec_mem_resp_rdata = response_data_q;
    assign vec_mem_resp_error = response_error_q;
    assign vec_mem_resp_retry = response_retry_q;

    openrv64_vec_test_top #(
        .RESET_VECTOR(RESET_VECTOR), .VLEN(256),
        .DATAPATH_WIDTH(DATAPATH_WIDTH),
        .MEM_TAG_WIDTH(MEM_TAG_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .ifetch_valid_o(ifetch_valid), .ifetch_ready_i(ifetch_ready),
        .ifetch_addr_o(ifetch_addr), .ifetch_rdata_i(ifetch_rdata),
        .ifetch_error_i(ifetch_error),
        .vec_mem_req_valid_o(vec_mem_req_valid),
        .vec_mem_req_ready_i(vec_mem_req_ready),
        .vec_mem_req_tag_o(vec_mem_req_tag),
        .vec_mem_req_write_o(vec_mem_req_write),
        .vec_mem_req_addr_o(vec_mem_req_addr),
        .vec_mem_req_wdata_o(vec_mem_req_wdata),
        .vec_mem_req_wstrb_o(vec_mem_req_wstrb),
        .vec_mem_resp_valid_i(vec_mem_resp_valid),
        .vec_mem_resp_ready_o(vec_mem_resp_ready),
        .vec_mem_resp_tag_i(vec_mem_resp_tag),
        .vec_mem_resp_rdata_i(vec_mem_resp_rdata),
        .vec_mem_resp_error_i(vec_mem_resp_error),
        .vec_mem_resp_retry_i(vec_mem_resp_retry),
        .dbg_pc_o(dbg_pc), .dbg_instr_o(dbg_instr),
        .dbg_halted_o(dbg_halted), .dbg_error_o(dbg_error),
        .dbg_vec_busy_o(dbg_vec_busy),
        .dbg_vec_replay_o(dbg_vec_replay),
        .dbg_retired_o(dbg_retired)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            response_valid_q <= 1'b0;
            response_tag_q <= {MEM_TAG_WIDTH{1'b0}};
            response_data_q <= 64'd0;
            response_error_q <= 1'b0;
            response_retry_q <= 1'b0;
            retry_used_q <= 1'b0;
            fetch_count_q <= 0;
            vec_request_count_q <= 0;
            vec_replay_count_q <= 0;
        end else begin
            if (ifetch_valid && ifetch_ready)
                fetch_count_q <= fetch_count_q + 1;
            if (dbg_vec_replay)
                vec_replay_count_q <= vec_replay_count_q + 1;

            if (response_valid_q && vec_mem_resp_ready)
                response_valid_q <= 1'b0;

            if (vec_mem_req_valid && vec_mem_req_ready) begin
                vec_request_count_q <= vec_request_count_q + 1;
                response_valid_q <= 1'b1;
                response_tag_q <= vec_mem_req_tag;
                response_data_q <= (vec_mem_req_addr[63:11] == 0) ?
                    memory[vec_mem_req_addr[10:3]] : 64'd0;
                response_error_q <= vec_mem_req_addr[63:11] != 0;
                response_retry_q <= !retry_used_q &&
                                    (vec_mem_req_addr == 64'h408);
                if (!retry_used_q && (vec_mem_req_addr == 64'h408))
                    retry_used_q <= 1'b1;

                if (vec_mem_req_write) begin
                    if (vec_mem_req_wstrb != 8'hff)
                        $fatal(1, "matmul vector store was not a full beat");
                    if (vec_mem_req_addr[63:11] != 0)
                        $fatal(1, "matmul vector store escaped memory");
                    memory[vec_mem_req_addr[10:3]] <= vec_mem_req_wdata;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && $test$plusargs("trace_vec_matmul")) begin
            if (ifetch_valid && ifetch_ready)
                $display("ifetch pc=%x instr=%x", ifetch_addr,
                         ifetch_addr[2] ? ifetch_rdata[63:32] :
                                           ifetch_rdata[31:0]);
            if (vec_mem_req_valid && vec_mem_req_ready)
                $display("vecmem %s addr=%x tag=%0d",
                         vec_mem_req_write ? "store" : "load",
                         vec_mem_req_addr, vec_mem_req_tag);
            if (dbg_vec_replay)
                $display("vec replay pc=%x", dbg_pc);
        end
    end

    string memh_path;
    integer init_index;
    integer timeout;
    initial begin
        for (init_index = 0; init_index < MEM_WORDS;
             init_index = init_index + 1)
            memory[init_index] = 64'd0;

        if (!$value$plusargs("memh=%s", memh_path))
            $fatal(1, "use +memh=<sw/vector/matmul.memh>");
        $readmemh(memh_path, memory, RESET_WORD, MEM_WORDS - 1);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        timeout = 0;
        while (!dbg_halted && timeout < 20000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        @(negedge clk);

        if (!dbg_halted || dbg_error)
            $fatal(1, "matmul failed halt=%0b error=%0b pc=%x instr=%x",
                   dbg_halted, dbg_error, dbg_pc, dbg_instr);
        if (dbg_pc != 64'h128 || dbg_instr != 32'h0010_0073)
            $fatal(1, "matmul halted at unexpected instruction");
        if (dbg_retired != 64'd181)
            $fatal(1, "matmul retired %0d instructions, expected 181",
                   dbg_retired);

        /* C row zero, forward and reversed eight-column blocks. */
        if (memory[8'ha0] !== 64'h4420_8000_43a0_8000 ||
            memory[8'ha1] !== 64'h44a0_8000_4470_c000 ||
            memory[8'ha2] !== 64'h44f0_c000_44c8_a000 ||
            memory[8'ha3] !== 64'h4520_8000_450c_7000 ||
            memory[8'ha4] !== 64'h450c_7000_4520_8000 ||
            memory[8'ha5] !== 64'h44c8_a000_44f0_c000 ||
            memory[8'ha6] !== 64'h4470_c000_44a0_8000 ||
            memory[8'ha7] !== 64'h43a0_8000_4420_8000)
            $fatal(1, "matmul C row zero mismatch");

        /* C row one, forward and reversed eight-column blocks. */
        if (memory[8'ha8] !== 64'h44a3_8000_4423_8000 ||
            memory[8'ha9] !== 64'h4523_8000_44f5_4000 ||
            memory[8'haa] !== 64'h4575_4000_454c_6000 ||
            memory[8'hab] !== 64'h45a3_8000_458f_1000 ||
            memory[8'hac] !== 64'h458f_1000_45a3_8000 ||
            memory[8'had] !== 64'h454c_6000_4575_4000 ||
            memory[8'hae] !== 64'h44f5_4000_4523_8000 ||
            memory[8'haf] !== 64'h4423_8000_44a3_8000)
            $fatal(1, "matmul C row one mismatch");

        if (!retry_used_q || (vec_replay_count_q == 0))
            $fatal(1, "matmul LSU did not replay the injected retry");
        if (vec_request_count_q != 89)
            $fatal(1, "matmul issued %0d vector beats, expected 89",
                   vec_request_count_q);
        if (dbg_vec_busy)
            $fatal(1, "vector unit remained busy after matmul halt");

        $display("PASS: assembled private-vector FP32 matmul");
        $display("      fetched=%0d retired=%0d vec_requests=%0d replays=%0d",
                 fetch_count_q, dbg_retired, vec_request_count_q,
                 vec_replay_count_q);
        $finish;
    end

endmodule
