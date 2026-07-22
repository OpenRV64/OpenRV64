`timescale 1ns/1ps
`include "core/fetch/fetch-defs.v"

module tb_fetch_3w;
    logic clk;
    logic rst_n;
    logic restart;
    logic [63:0] restart_pc;
    logic invalidate;
    logic stall;
    logic flush;
    wire cancel;
    wire req_valid;
    logic req_ready;
    wire [63:0] req_addr;
    logic resp_valid;
    wire resp_ready;
    logic [63:0] resp_addr;
    logic [255:0] resp_data;
    logic resp_access_fault;
    logic resp_page_fault;
    wire [2:0] decode_valid;
    logic [2:0] decode_ready;
    wire [3*`RV64_FETCH_DECODE_BUS_WIDTH-1:0] decode_bus;
    wire [191:0] trace_id;
    wire [63:0] stream_pc;
    wire [1:0] line_count;

    integer request_count;
    integer restart_request_base;
    integer replay_request_base;
    reg [63:0] request_addr [0:15];

    openrv64_fetch_3w #(.ENABLE_TRACE(1)) dut (
        .clk(clk), .rst_n(rst_n), .restart_i(restart),
        .restart_pc_i(restart_pc), .invalidate_i(invalidate),
        .stall_i(stall), .flush_i(flush), .cancel_o(cancel),
        .req_valid_o(req_valid), .req_ready_i(req_ready),
        .req_addr_o(req_addr), .resp_valid_i(resp_valid),
        .resp_ready_o(resp_ready), .resp_addr_i(resp_addr),
        .resp_data_i(resp_data),
        .resp_access_fault_i(resp_access_fault),
        .resp_page_fault_i(resp_page_fault),
        .decode_valid_o(decode_valid), .decode_ready_i(decode_ready),
        .decode_bus_o(decode_bus), .trace_id_i(64'd100),
        .trace_id_o(trace_id), .stream_pc_o(stream_pc),
        .line_count_o(line_count)
    );

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (rst_n && req_valid && req_ready) begin
            request_addr[request_count] <= req_addr;
            request_count <= request_count + 1;
        end
    end

    function automatic [31:0] lane_instr(input integer lane);
        reg [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] bus;
        begin
            bus = decode_bus[lane*`RV64_FETCH_DECODE_BUS_WIDTH +:
                             `RV64_FETCH_DECODE_BUS_WIDTH];
            lane_instr = bus[`RV64_FETCH_DECODE_BUS_INSTR_BITS];
        end
    endfunction

    function automatic [63:0] lane_pc(input integer lane);
        reg [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] bus;
        begin
            bus = decode_bus[lane*`RV64_FETCH_DECODE_BUS_WIDTH +:
                             `RV64_FETCH_DECODE_BUS_WIDTH];
            lane_pc = bus[`RV64_FETCH_DECODE_BUS_PC_BITS];
        end
    endfunction

    function automatic [255:0] make_line(input integer base);
        integer word_index;
        begin
            make_line = 256'd0;
            for (word_index = 0; word_index < 8;
                 word_index = word_index + 1)
                make_line[word_index*32 +: 32] = base + word_index;
        end
    endfunction

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic return_line(input [63:0] addr, input integer base);
        begin
            resp_addr = addr;
            resp_data = make_line(base);
            resp_valid = 1;
            tick();
            resp_valid = 0;
        end
    endtask

    task automatic expect_bundle(
        input [63:0] pc0,
        input [31:0] instr0,
        input [31:0] instr1,
        input [31:0] instr2
    );
        integer cycles;
        begin
            cycles = 0;
            while (decode_valid != 3'b111 && cycles < 20) begin
                tick();
                cycles = cycles + 1;
            end
            if (decode_valid != 3'b111 || lane_pc(0) != pc0 ||
                lane_pc(1) != pc0 + 4 || lane_pc(2) != pc0 + 8 ||
                lane_instr(0) != instr0 || lane_instr(1) != instr1 ||
                lane_instr(2) != instr2)
                $fatal(1, "bundle mismatch pc=%h valid=%b insn=%h/%h/%h",
                    lane_pc(0), decode_valid, lane_instr(0), lane_instr(1),
                    lane_instr(2));
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        restart = 0;
        restart_pc = 0;
        invalidate = 0;
        stall = 0;
        flush = 0;
        req_ready = 1;
        resp_valid = 0;
        resp_addr = 0;
        resp_data = 0;
        resp_access_fault = 0;
        resp_page_fault = 0;
        decode_ready = 0;
        request_count = 0;
        repeat (3) tick();
        rst_n = 1;
        restart_pc = 64'h18;
        invalidate = 1;
        restart = 1;
        tick();
        if (!cancel) $fatal(1, "restart must cancel old bus requests");
        restart = 0;
        invalidate = 0;

        // Fetch issues only the current line and cannot launch another until
        // that response returns.  Once current is present it asks for exactly
        // one following line so a three-wide bundle can cross the boundary.
        while (request_count < 1) tick();
        if (request_addr[0] != 64'h0 || line_count != 1)
            $fatal(1, "fetch_3w current-line request mismatch");
        repeat (3) tick();
        if (request_count != 1)
            $fatal(1, "fetch_3w issued more than one request at a time");
        return_line(64'h0, 32'h100);
        while (request_count < 2) tick();
        if (request_addr[1] != 64'h20 || line_count != 2)
            $fatal(1, "fetch_3w did not request exactly one line ahead");
        repeat (3) tick();
        if (request_count != 2)
            $fatal(1, "fetch_3w requested beyond its one-line lookahead");
        return_line(64'h20, 32'h108);
        expect_bundle(64'h18, 32'h106, 32'h107, 32'h108);
        if (trace_id[63:0] != 100 || trace_id[127:64] != 101 ||
            trace_id[191:128] != 102)
            $fatal(1, "three-wide trace IDs are not consecutive");

        decode_ready = 3'b111;
        tick();
        expect_bundle(64'h24, 32'h109, 32'h10a, 32'h10b);

        // A non-ready second lane means only lane zero is consumed.
        decode_ready = 3'b001;
        tick();
        if (stream_pc != 64'h28)
            $fatal(1, "partial decode acceptance advanced by more than one");
        expect_bundle(64'h28, 32'h10a, 32'h10b, 32'h10c);

        // Redirects discard the fetch-side bridge registers.  The target is
        // requested again and is expected to hit in L1I in the integrated
        // design; fetch itself owns no loop-residency policy.
        decode_ready = 0;
        replay_request_base = request_count;
        restart_pc = 64'h18;
        restart = 1;
        tick();
        restart = 0;
        if (stream_pc != 64'h18)
            $fatal(1, "resident redirect did not restore target PC");
        while (request_count < replay_request_base + 1) tick();
        if (request_addr[replay_request_base] != 64'h0)
            $fatal(1, "redirect did not request its target line");
        return_line(64'h0, 32'h100);
        while (request_count < replay_request_base + 2) tick();
        if (request_addr[replay_request_base + 1] != 64'h20)
            $fatal(1, "redirect did not restore one-line lookahead");
        return_line(64'h20, 32'h108);
        expect_bundle(64'h18, 32'h106, 32'h107, 32'h108);

        // A context-changing restart follows the same one-at-a-time contract.
        restart_request_base = request_count;
        restart_pc = 64'h84;
        invalidate = 1;
        restart = 1;
        tick();
        restart = 0;
        invalidate = 0;
        if (stream_pc != 64'h84 || line_count != 0)
            $fatal(1, "invalidating restart did not reset fetch bridge lines");
        while (request_count < restart_request_base + 1) tick();
        repeat (3) tick();
        if (request_count != restart_request_base + 1 ||
            request_addr[restart_request_base] != 64'h80)
            $fatal(1, "restart request alignment mismatch");
        return_line(64'h80, 32'h120);
        while (request_count < restart_request_base + 2) tick();
        if (request_addr[restart_request_base + 1] != 64'ha0)
            $fatal(1, "restart lookahead alignment mismatch");

        $display("PASS: 3-wide current-line fetch with one-line lookahead");
        $finish;
    end
endmodule
