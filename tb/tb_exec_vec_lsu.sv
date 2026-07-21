`timescale 1ns/1ps
`include "core/exec/vec/defs.v"

module tb_exec_vec_lsu;

    localparam integer VLEN = 256;
    localparam integer MAX_LMUL = 8;
    localparam integer LMUL_WIDTH = 2;
    localparam integer GROUP_WIDTH = VLEN * MAX_LMUL;
    localparam integer DATAPATH_WIDTH = 64;
    localparam integer SLICE_ADDR_WIDTH = 2;
    localparam integer SLICES_PER_REG = VLEN / DATAPATH_WIDTH;
    localparam integer MEM_ADDR_LSB = $clog2(DATAPATH_WIDTH / 8);
    localparam integer REG_ADDR_WIDTH = 5;
    localparam integer TAG_WIDTH = 8;
    localparam integer MEM_TAG_WIDTH = 8;
    localparam [63:0] VTYPE_M1 = 64'h000;
    localparam [63:0] VTYPE_M2 = 64'h001;

    reg clk;
    reg rst_n;
    reg dispatch_valid;
    wire dispatch_ready;
    reg [TAG_WIDTH-1:0] dispatch_tag;
    reg [`OPENRV64_VEC_LSU_OP_WIDTH-1:0] dispatch_op;
    reg [REG_ADDR_WIDTH-1:0] dispatch_base_gpr;
    reg [REG_ADDR_WIDTH-1:0] dispatch_vreg;
    reg [63:0] dispatch_vtype;
    wire gpr_read_valid;
    reg gpr_read_ready;
    wire [REG_ADDR_WIDTH-1:0] gpr_read_addr;
    reg [63:0] gpr_read_data;
    wire lsu_read_valid;
    wire lsu_read_ready;
    wire [REG_ADDR_WIDTH-1:0] lsu_read_addr;
    wire [SLICE_ADDR_WIDTH-1:0] lsu_read_slice;
    wire [DATAPATH_WIDTH-1:0] lsu_read_data;
    reg operands_ready;
    reg ordered_valid;
    reg [TAG_WIDTH-1:0] ordered_tag;
    wire complete_valid;
    reg complete_ready;
    wire [TAG_WIDTH-1:0] complete_tag;
    wire complete_fault;
    wire [63:0] complete_fault_addr;
    wire complete_unsupported;
    reg retire_valid;
    wire retire_ready;
    reg [TAG_WIDTH-1:0] retire_tag;
    reg retire_kill;
    wire lsu_write_valid;
    wire lsu_write_ready;
    wire [REG_ADDR_WIDTH-1:0] lsu_write_addr;
    wire [SLICE_ADDR_WIDTH-1:0] lsu_write_slice;
    wire [DATAPATH_WIDTH-1:0] lsu_write_data;

    wire mem_req_valid;
    wire mem_req_ready;
    wire [MEM_TAG_WIDTH-1:0] mem_req_tag;
    wire mem_req_write;
    wire [63:0] mem_req_addr;
    wire [DATAPATH_WIDTH-1:0] mem_req_wdata;
    wire [(DATAPATH_WIDTH/8)-1:0] mem_req_wstrb;
    wire mem_resp_valid;
    wire mem_resp_ready;
    wire [MEM_TAG_WIDTH-1:0] mem_resp_tag;
    wire [DATAPATH_WIDTH-1:0] mem_resp_rdata;
    wire mem_resp_error;
    wire mem_resp_retry;
    wire replay;
    wire busy;

    reg [REG_ADDR_WIDTH-1:0] test_read_addr;
    reg [SLICE_ADDR_WIDTH-1:0] test_read_slice;
    reg test_read_valid;
    wire [3:0] rf_read_valid =
        {lsu_read_valid, 2'b00, test_read_valid};
    wire [3:0] rf_read_ready;
    wire [4*REG_ADDR_WIDTH-1:0] rf_read_addr =
        {lsu_read_addr, {2*REG_ADDR_WIDTH{1'b0}}, test_read_addr};
    wire [4*SLICE_ADDR_WIDTH-1:0] rf_read_slice =
        {lsu_read_slice, {2*SLICE_ADDR_WIDTH{1'b0}},
         test_read_slice};
    wire [4*DATAPATH_WIDTH-1:0] rf_read_data;
    assign lsu_read_ready = rf_read_ready[3];
    assign lsu_read_data =
        rf_read_data[3*DATAPATH_WIDTH +: DATAPATH_WIDTH];
    reg test_write_valid;
    reg [REG_ADDR_WIDTH-1:0] test_write_addr;
    reg [SLICE_ADDR_WIDTH-1:0] test_write_slice;
    reg [DATAPATH_WIDTH-1:0] test_write_data;
    wire [1:0] rf_write_valid = {lsu_write_valid, test_write_valid};
    wire [1:0] rf_write_ready;
    wire [2*REG_ADDR_WIDTH-1:0] rf_write_addr =
        {lsu_write_addr, test_write_addr};
    wire [2*SLICE_ADDR_WIDTH-1:0] rf_write_slice =
        {lsu_write_slice, test_write_slice};
    wire [2*DATAPATH_WIDTH-1:0] rf_write_data =
        {lsu_write_data, test_write_data};
    assign lsu_write_ready = rf_write_ready[1];

    openrv64_rv64i_vec #(
        .VLEN(VLEN), .SLICE_WIDTH(DATAPATH_WIDTH),
        .REG_ADDR_WIDTH(REG_ADDR_WIDTH)
    ) u_regs (
        .clk(clk), .rst_n(rst_n),
        .read_valid_i(rf_read_valid), .read_ready_o(rf_read_ready),
        .read_addr_i(rf_read_addr), .read_slice_i(rf_read_slice),
        .read_data_o(rf_read_data),
        .write_valid_i(rf_write_valid), .write_ready_o(rf_write_ready),
        .write_addr_i(rf_write_addr), .write_slice_i(rf_write_slice),
        .write_data_i(rf_write_data)
    );

    openrv64_exec_vec_lsu #(
        .VLEN(VLEN), .DATAPATH_WIDTH(DATAPATH_WIDTH),
        .REG_ADDR_WIDTH(REG_ADDR_WIDTH), .TAG_WIDTH(TAG_WIDTH),
        .MEM_TAG_WIDTH(MEM_TAG_WIDTH), .QUEUE_DEPTH(4),
        .MAX_LMUL(MAX_LMUL), .LMUL_WIDTH(LMUL_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .dispatch_valid_i(dispatch_valid),
        .dispatch_ready_o(dispatch_ready),
        .dispatch_tag_i(dispatch_tag), .dispatch_op_i(dispatch_op),
        .dispatch_base_gpr_i(dispatch_base_gpr),
        .dispatch_vreg_i(dispatch_vreg),
        .dispatch_vtype_i(dispatch_vtype),
        .gpr_read_valid_o(gpr_read_valid),
        .gpr_read_ready_i(gpr_read_ready),
        .gpr_read_addr_o(gpr_read_addr),
        .gpr_read_data_i(gpr_read_data),
        .rf_read_valid_o(lsu_read_valid),
        .rf_read_ready_i(lsu_read_ready),
        .rf_read_addr_o(lsu_read_addr),
        .rf_read_slice_o(lsu_read_slice),
        .rf_read_data_i(lsu_read_data),
        .operands_ready_i(operands_ready),
        .ordered_valid_i(ordered_valid), .ordered_tag_i(ordered_tag),
        .complete_valid_o(complete_valid),
        .complete_ready_i(complete_ready), .complete_tag_o(complete_tag),
        .complete_fault_o(complete_fault),
        .complete_fault_addr_o(complete_fault_addr),
        .complete_unsupported_o(complete_unsupported),
        .retire_valid_i(retire_valid), .retire_ready_o(retire_ready),
        .retire_tag_i(retire_tag), .retire_kill_i(retire_kill),
        .rf_write_valid_o(lsu_write_valid),
        .rf_write_ready_i(lsu_write_ready),
        .rf_write_addr_o(lsu_write_addr),
        .rf_write_slice_o(lsu_write_slice),
        .rf_write_data_o(lsu_write_data),
        .mem_req_valid_o(mem_req_valid), .mem_req_ready_i(mem_req_ready),
        .mem_req_tag_o(mem_req_tag), .mem_req_write_o(mem_req_write),
        .mem_req_addr_o(mem_req_addr), .mem_req_wdata_o(mem_req_wdata),
        .mem_req_wstrb_o(mem_req_wstrb),
        .mem_resp_valid_i(mem_resp_valid),
        .mem_resp_ready_o(mem_resp_ready), .mem_resp_tag_i(mem_resp_tag),
        .mem_resp_rdata_i(mem_resp_rdata),
        .mem_resp_error_i(mem_resp_error),
        .mem_resp_retry_i(mem_resp_retry),
        .replay_o(replay), .busy_o(busy)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    reg [DATAPATH_WIDTH-1:0] memory [0:127];
    reg response_valid_q;
    reg [MEM_TAG_WIDTH-1:0] response_tag_q;
    reg [DATAPATH_WIDTH-1:0] response_data_q;
    reg response_error_q;
    reg response_retry_q;
    reg retry_enable;
    reg retry_used;
    reg [63:0] retry_addr;
    reg error_enable;
    reg [63:0] error_addr;
    integer request_count;
    integer replay_count;
    integer cycle_count;
    integer first_pipeline_cycle;
    integer second_pipeline_cycle;
    integer memory_index;

    assign mem_req_ready = !response_valid_q || mem_resp_ready;
    assign mem_resp_valid = response_valid_q;
    assign mem_resp_tag = response_tag_q;
    assign mem_resp_rdata = response_data_q;
    assign mem_resp_error = response_error_q;
    assign mem_resp_retry = response_retry_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            response_valid_q <= 1'b0;
            response_tag_q <= {MEM_TAG_WIDTH{1'b0}};
            response_data_q <= {DATAPATH_WIDTH{1'b0}};
            response_error_q <= 1'b0;
            response_retry_q <= 1'b0;
            retry_used <= 1'b0;
            request_count <= 0;
            replay_count <= 0;
            cycle_count <= 0;
            first_pipeline_cycle <= -1;
            second_pipeline_cycle <= -1;
        end else begin
            cycle_count <= cycle_count + 1;
            if (replay)
                replay_count <= replay_count + 1;

            if (response_valid_q && mem_resp_ready)
                response_valid_q <= 1'b0;

            if (mem_req_valid && mem_req_ready) begin
                request_count <= request_count + 1;
                response_valid_q <= 1'b1;
                response_tag_q <= mem_req_tag;
                response_data_q <=
                    memory[mem_req_addr[MEM_ADDR_LSB +: 7]];
                response_error_q <= error_enable &&
                                    (mem_req_addr == error_addr);
                response_retry_q <= retry_enable && !retry_used &&
                                    (mem_req_addr == retry_addr);
                if (retry_enable && !retry_used &&
                    (mem_req_addr == retry_addr))
                    retry_used <= 1'b1;
                if (mem_req_write) begin
                    if (mem_req_wstrb !==
                        {(DATAPATH_WIDTH/8){1'b1}})
                        $fatal(1, "vector store did not drive full byte strobes");
                    memory[mem_req_addr[MEM_ADDR_LSB +: 7]] <=
                        mem_req_wdata;
                end
                if (mem_req_addr == 64'h180)
                    first_pipeline_cycle <= cycle_count;
                if (mem_req_addr == 64'h188)
                    second_pipeline_cycle <= cycle_count;
            end
        end
    end

    task automatic write_group;
        input [REG_ADDR_WIDTH-1:0] addr;
        input [LMUL_WIDTH-1:0] lmul;
        input [GROUP_WIDTH-1:0] data;
        integer slice;
        integer slice_count;
        begin
            slice_count = SLICES_PER_REG << lmul;
            for (slice = 0; slice < slice_count; slice = slice + 1) begin
                @(negedge clk);
                test_write_addr = addr + (slice / SLICES_PER_REG);
                test_write_slice = slice % SLICES_PER_REG;
                test_write_data = data[slice*DATAPATH_WIDTH +:
                                       DATAPATH_WIDTH];
                test_write_valid = 1'b1;
                #1;
                while (!rf_write_ready[0]) begin
                    @(posedge clk);
                    @(negedge clk);
                    #1;
                end
                @(posedge clk);
            end
            @(negedge clk);
            test_write_valid = 1'b0;
        end
    endtask

    task automatic write_vec;
        input [REG_ADDR_WIDTH-1:0] addr;
        input [VLEN-1:0] data;
        reg [GROUP_WIDTH-1:0] group_data;
        begin
            group_data = {GROUP_WIDTH{1'b0}};
            group_data[VLEN-1:0] = data;
            write_group(addr, 2'd0, group_data);
        end
    endtask

    task automatic check_group;
        input [REG_ADDR_WIDTH-1:0] addr;
        input [LMUL_WIDTH-1:0] lmul;
        input [GROUP_WIDTH-1:0] expected;
        input [8*40-1:0] label;
        integer slice;
        integer slice_count;
        begin
            slice_count = SLICES_PER_REG << lmul;
            test_read_valid = 1'b1;
            for (slice = 0; slice < slice_count; slice = slice + 1) begin
                test_read_addr = addr + (slice / SLICES_PER_REG);
                test_read_slice = slice % SLICES_PER_REG;
                #1;
                if (!rf_read_ready[0])
                    $fatal(1, "%0s: test RF read blocked", label);
                if (rf_read_data[0*DATAPATH_WIDTH +: DATAPATH_WIDTH] !==
                    expected[slice*DATAPATH_WIDTH +: DATAPATH_WIDTH])
                    $fatal(1, "%0s: slice %0d mismatch", label, slice);
            end
            test_read_valid = 1'b0;
        end
    endtask

    task automatic check_vec;
        input [REG_ADDR_WIDTH-1:0] addr;
        input [VLEN-1:0] expected;
        input [8*40-1:0] label;
        reg [GROUP_WIDTH-1:0] group_data;
        begin
            group_data = {GROUP_WIDTH{1'b0}};
            group_data[VLEN-1:0] = expected;
            check_group(addr, 2'd0, group_data, label);
        end
    endtask

    task automatic send;
        input [TAG_WIDTH-1:0] tag;
        input [`OPENRV64_VEC_LSU_OP_WIDTH-1:0] op;
        input [63:0] addr;
        input [REG_ADDR_WIDTH-1:0] vreg;
        input [63:0] vtype;
        begin
            while (!dispatch_ready) begin
                @(posedge clk);
                @(negedge clk);
            end
            dispatch_tag = tag;
            dispatch_op = op;
            dispatch_base_gpr = 5'd1;
            gpr_read_data = addr;
            dispatch_vreg = vreg;
            dispatch_vtype = vtype;
            dispatch_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            dispatch_valid = 1'b0;
        end
    endtask

    task automatic finish_command;
        input [TAG_WIDTH-1:0] tag;
        input expected_fault;
        input [63:0] expected_fault_addr;
        integer timeout;
        begin
            timeout = 0;
            while (!complete_valid && timeout < 100) begin
                @(posedge clk);
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!complete_valid)
                $fatal(1, "LSU tag %0d completion timeout", tag);
            if (complete_tag !== tag || complete_fault !== expected_fault ||
                complete_unsupported ||
                (expected_fault &&
                 (complete_fault_addr !== expected_fault_addr)))
                $fatal(1,
                    "LSU tag %0d bad completion tag=%0d fault=%0b addr=%x unsupported=%0b",
                    tag, complete_tag, complete_fault, complete_fault_addr,
                    complete_unsupported);

            complete_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            complete_ready = 1'b0;

            retire_tag = tag;
            retire_kill = 1'b0;
            retire_valid = 1'b1;
            timeout = 0;
            #1;
            while (!retire_ready && timeout < 200) begin
                @(posedge clk);
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!retire_ready)
                $fatal(1, "LSU tag %0d retirement timed out", tag);
            @(posedge clk);
            @(negedge clk);
            retire_valid = 1'b0;
        end
    endtask

    integer init_index;
    integer requests_before_store;
    integer replays_before_gpr_stall;
    reg [GROUP_WIDTH-1:0] expected_group;
    initial begin
        dispatch_valid = 1'b0;
        dispatch_tag = 8'd0;
        dispatch_op = `OPENRV64_VEC_LSU_INVALID;
        dispatch_base_gpr = 5'd1;
        dispatch_vreg = 5'd0;
        dispatch_vtype = VTYPE_M1;
        gpr_read_ready = 1'b1;
        gpr_read_data = 64'd0;
        operands_ready = 1'b1;
        ordered_valid = 1'b0;
        ordered_tag = 8'd0;
        complete_ready = 1'b0;
        retire_valid = 1'b0;
        retire_tag = 8'd0;
        retire_kill = 1'b0;
        test_read_addr = 5'd0;
        test_read_slice = 2'd0;
        test_read_valid = 1'b0;
        test_write_valid = 1'b0;
        test_write_addr = 5'd0;
        test_write_slice = 2'd0;
        test_write_data = 64'd0;
        retry_enable = 1'b0;
        retry_addr = 64'd0;
        error_enable = 1'b0;
        error_addr = 64'd0;
        expected_group = {GROUP_WIDTH{1'b0}};
        for (init_index = 0; init_index < 128;
             init_index = init_index + 1)
            memory[init_index] = 64'd0;

        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        write_vec(5'd1, {4{64'h0123_4567_89ab_cdef}});
        requests_before_store = request_count;
        send(8'd1, `OPENRV64_VEC_LSU_STORE, 64'h100, 5'd1,
             VTYPE_M1);
        repeat (4) @(posedge clk);
        @(negedge clk);
        if (request_count != requests_before_store)
            $fatal(1, "speculative vector store escaped before ordering");
        ordered_tag = 8'd1;
        ordered_valid = 1'b1;
        finish_command(8'd1, 1'b0, 64'd0);
        ordered_valid = 1'b0;
        if ({memory[35], memory[34], memory[33], memory[32]} !==
            {4{64'h0123_4567_89ab_cdef}})
            $fatal(1, "ordered vector store wrote incorrect data");

        send(8'd2, `OPENRV64_VEC_LSU_LOAD, 64'h100, 5'd2,
             VTYPE_M1);
        while (!complete_valid) begin
            @(posedge clk);
            @(negedge clk);
        end
        check_vec(5'd2, 256'd0, "load before retirement");
        finish_command(8'd2, 1'b0, 64'd0);
        check_vec(5'd2, {4{64'h0123_4567_89ab_cdef}},
                  "load retirement");

        for (init_index = 36; init_index < 40;
             init_index = init_index + 1)
            memory[init_index] = 64'hfeed_face_cafe_beef;
        retry_enable = 1'b1;
        retry_used = 1'b0;
        retry_addr = 64'h120;
        requests_before_store = request_count;
        send(8'd3, `OPENRV64_VEC_LSU_LOAD, 64'h120, 5'd3,
             VTYPE_M1);
        finish_command(8'd3, 1'b0, 64'd0);
        retry_enable = 1'b0;
        check_vec(5'd3, {4{64'hfeed_face_cafe_beef}},
                  "internally replayed load");
        if (!retry_used || replay_count == 0 ||
            request_count != requests_before_store + 5)
            $fatal(1,
                "load retry was not internal retry_used=%0b replay=%0d req_delta=%0d",
                retry_used, replay_count,
                request_count - requests_before_store);

        // Two accepted loads keep the 64-bit request port occupied on
        // consecutive cycles after queue startup.
        for (init_index = 48; init_index < 52;
             init_index = init_index + 1)
            memory[init_index] = 64'h4444_4444_4444_4444;
        for (init_index = 52; init_index < 56;
             init_index = init_index + 1)
            memory[init_index] = 64'h5555_5555_5555_5555;
        send(8'd4, `OPENRV64_VEC_LSU_LOAD, 64'h180, 5'd4,
             VTYPE_M1);
        finish_command(8'd4, 1'b0, 64'd0);
        send(8'd5, `OPENRV64_VEC_LSU_LOAD, 64'h1a0, 5'd5,
             VTYPE_M1);
        finish_command(8'd5, 1'b0, 64'd0);
        check_vec(5'd4, {4{64'h4444_4444_4444_4444}},
                  "pipelined load zero");
        check_vec(5'd5, {4{64'h5555_5555_5555_5555}},
                  "pipelined load one");
        if ((first_pipeline_cycle < 0) ||
            (second_pipeline_cycle != first_pipeline_cycle + 1))
            $fatal(1, "vector LSU requests were not back-to-back: %0d %0d",
                   first_pipeline_cycle, second_pipeline_cycle);

        requests_before_store = request_count;
        send(8'd6, `OPENRV64_VEC_LSU_LOAD, 64'h191, 5'd6,
             VTYPE_M1);
        finish_command(8'd6, 1'b1, 64'h191);
        if (request_count != requests_before_store)
            $fatal(1, "misaligned vector load reached memory");
        check_vec(5'd6, 256'd0, "faulting load isolation");

        // LMUL=2 transfers v8:v9 as eight consecutive 64-bit beats. Loaded
        // data remains private until retirement, just as it does for m1.
        for (init_index = 64; init_index < 68;
             init_index = init_index + 1)
            memory[init_index] = 64'h8888_0000_1111_2222;
        for (init_index = 68; init_index < 72;
             init_index = init_index + 1)
            memory[init_index] = 64'h9999_3333_4444_5555;
        expected_group = {GROUP_WIDTH{1'b0}};
        expected_group[0*VLEN +: VLEN] =
            {4{64'h8888_0000_1111_2222}};
        expected_group[1*VLEN +: VLEN] =
            {4{64'h9999_3333_4444_5555}};
        requests_before_store = request_count;
        send(8'd7, `OPENRV64_VEC_LSU_LOAD, 64'h200, 5'd8,
             VTYPE_M2);
        finish_command(8'd7, 1'b0, 64'd0);
        check_group(5'd8, 2'd1, expected_group, "m2 load");
        if (request_count != requests_before_store + 8)
            $fatal(1, "m2 load did not issue exactly eight beats");

        requests_before_store = request_count;
        send(8'd8, `OPENRV64_VEC_LSU_STORE, 64'h240, 5'd8,
             VTYPE_M2);
        repeat (3) @(posedge clk);
        @(negedge clk);
        if (request_count != requests_before_store)
            $fatal(1, "m2 store escaped before ordered retirement head");
        ordered_tag = 8'd8;
        ordered_valid = 1'b1;
        finish_command(8'd8, 1'b0, 64'd0);
        ordered_valid = 1'b0;
        if (({memory[75], memory[74], memory[73], memory[72]} !==
             expected_group[0*VLEN +: VLEN]) ||
            ({memory[79], memory[78], memory[77], memory[76]} !==
             expected_group[1*VLEN +: VLEN]))
            $fatal(1, "m2 store wrote incorrect register-group data");

        // The scalar sideband is read-only and is part of the LSU-owned
        // replay domain. A blocked pointer read must neither reach memory nor
        // require the scalar dispatcher to resend the vector instruction.
        for (init_index = 80; init_index < 84;
             init_index = init_index + 1)
            memory[init_index] = 64'haaaa_bbbb_cccc_dddd;
        requests_before_store = request_count;
        replays_before_gpr_stall = replay_count;
        gpr_read_ready = 1'b0;
        send(8'd9, `OPENRV64_VEC_LSU_LOAD, 64'h280, 5'd10,
             VTYPE_M1);
        #1;
        if (!gpr_read_valid || gpr_read_addr !== 5'd1 || !replay)
            $fatal(1,
                "blocked GPR pointer read did not hold valid/address/replay");
        repeat (2) @(posedge clk);
        @(negedge clk);
        if (request_count != requests_before_store)
            $fatal(1, "blocked GPR pointer read reached vector memory");
        gpr_read_ready = 1'b1;
        finish_command(8'd9, 1'b0, 64'd0);
        check_vec(5'd10, {4{64'haaaa_bbbb_cccc_dddd}},
                  "GPR sideband replayed load");
        if (replay_count <= replays_before_gpr_stall)
            $fatal(1, "GPR sideband stall was not reported as replay");

        $display("PASS: vtype/LMUL vector LSU, ordering and replay");
        $finish;
    end

endmodule
