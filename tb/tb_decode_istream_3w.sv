`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/fetch/fetch-defs.v"

module tb_decode_istream_3w;
    logic clk;
    logic rst_n;
    logic flush;
    logic istream_valid;
    logic [95:0] istream_data;
    logic [5:0] istream_halfword_valid;
    logic [5:0] istream_access_fault;
    logic [5:0] istream_page_fault;
    logic [63:0] stream_pc;
    wire istream_advance_half;
    wire [3:0] istream_consume_halfwords;
    wire [3:0] consumed_halfwords;
    wire [2:0] decode_valid;
    logic [2:0] decode_ready;
    wire [3*`RV64_FETCH_DECODE_BUS_WIDTH-1:0] decode_bus;
    wire [191:0] trace_id;

    wire [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] bus0 =
        decode_bus[0*`RV64_FETCH_DECODE_BUS_WIDTH +:
                   `RV64_FETCH_DECODE_BUS_WIDTH];
    wire [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] bus1 =
        decode_bus[1*`RV64_FETCH_DECODE_BUS_WIDTH +:
                   `RV64_FETCH_DECODE_BUS_WIDTH];
    wire [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] bus2 =
        decode_bus[2*`RV64_FETCH_DECODE_BUS_WIDTH +:
                   `RV64_FETCH_DECODE_BUS_WIDTH];

    openrv64_decode_istream_3w #(
        .ENABLE_TRACE(1),
        .ENABLE_PREDECODE_TARGETS(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .flush_i(flush),
        .istream_valid_i(istream_valid),
        .istream_data_i(istream_data),
        .istream_halfword_valid_i(istream_halfword_valid),
        .istream_access_fault_i(istream_access_fault),
        .istream_page_fault_i(istream_page_fault),
        .stream_pc_i(stream_pc),
        .istream_advance_half_o(istream_advance_half),
        .istream_consume_halfwords_o(istream_consume_halfwords),
        .consumed_halfwords_o(consumed_halfwords),
        .decode_valid_o(decode_valid),
        .decode_ready_i(decode_ready),
        .decode_bus_o(decode_bus),
        .trace_id_i(64'd40), .trace_id_o(trace_id)
    );

    always #5 clk = ~clk;

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic clear_inputs;
        begin
            flush = 1'b0;
            istream_valid = 1'b0;
            istream_data = 96'd0;
            istream_halfword_valid = 6'b000000;
            istream_access_fault = 6'b000000;
            istream_page_fault = 6'b000000;
            stream_pc = 64'd0;
            decode_ready = 3'b000;
        end
    endtask

    task automatic expect_lane(
        input integer lane,
        input [63:0] expected_pc,
        input [31:0] expected_instr
    );
        reg [`RV64_FETCH_DECODE_BUS_WIDTH-1:0] selected_bus;
        begin
            selected_bus = (lane == 0) ? bus0 :
                           (lane == 1) ? bus1 : bus2;
            if (!decode_valid[lane])
                $fatal(1, "lane %0d is not valid", lane);
            if (selected_bus[`RV64_FETCH_DECODE_BUS_PC_BITS] !==
                expected_pc)
                $fatal(1, "lane %0d pc got=%h expected=%h", lane,
                    selected_bus[`RV64_FETCH_DECODE_BUS_PC_BITS],
                    expected_pc);
            if (selected_bus[`RV64_FETCH_DECODE_BUS_INSTR_BITS] !==
                expected_instr)
                $fatal(1, "lane %0d instr got=%h expected=%h", lane,
                    selected_bus[`RV64_FETCH_DECODE_BUS_INSTR_BITS],
                    expected_instr);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        clear_inputs();
        repeat (2) tick();
        rst_n = 1'b1;

        // Three ordinary instructions consume all six raw parcels.
        istream_valid = 1'b1;
        istream_halfword_valid = 6'b111111;
        istream_data[31:0] = 32'h00100093;
        istream_data[63:32] = 32'h00200113;
        istream_data[95:64] = 32'h00300193;
        stream_pc = 64'h1000;
        decode_ready = 3'b111;
        #1;
        if (decode_valid !== 3'b111 || consumed_halfwords !== 4'd6 ||
            istream_advance_half ||
            istream_consume_halfwords !== 4'd6)
            $fatal(1, "three-wide 32-bit consumption mismatch");
        expect_lane(0, 64'h1000, 32'h00100093);
        expect_lane(1, 64'h1004, 32'h00200113);
        expect_lane(2, 64'h1008, 32'h00300193);
        if (trace_id !== {64'd42, 64'd41, 64'd40})
            $fatal(1, "trace IDs do not follow instruction lanes");

        // Three compressed parcels use the explicit half-advance fast path.
        istream_data = 96'd0;
        istream_data[15:0] = 16'h0001;
        istream_data[31:16] = 16'h0085;
        istream_data[47:32] = 16'h0109;
        istream_halfword_valid = 6'b000111;
        stream_pc = 64'h1800;
        #1;
        if (decode_valid !== 3'b111 || !istream_advance_half ||
            istream_consume_halfwords !== 4'd0 ||
            consumed_halfwords !== 4'd3)
            $fatal(1, "compressed half-advance mismatch");
        expect_lane(0, 64'h1800, 32'h00000001);
        expect_lane(1, 64'h1802, 32'h00000085);
        expect_lane(2, 64'h1804, 32'h00000109);

        // Acceptance remains an ordered prefix under lane backpressure.
        istream_data[31:0] = 32'h00100093;
        istream_data[63:32] = 32'h00200113;
        istream_data[95:64] = 32'h00300193;
        istream_halfword_valid = 6'b111111;
        decode_ready = 3'b101;
        #1;
        if (consumed_halfwords !== 4'd2 ||
            istream_consume_halfwords !== 4'd2)
            $fatal(1, "backpressured prefix consumed past lane 0");

        // Consume a lone lower parcel into the two-byte stash.
        istream_data = 96'd0;
        istream_data[15:0] = 16'h0093;
        istream_halfword_valid = 6'b000001;
        stream_pc = 64'h2000;
        decode_ready = 3'b111;
        #1;
        if (decode_valid !== 3'b000 || consumed_halfwords !== 4'd1 ||
            istream_consume_halfwords !== 4'd1)
            $fatal(1, "straddled lower parcel was not stashed");
        tick();

        // The next raw parcel completes the old instruction; parsing then
        // continues at the following halfword without losing a lane.
        istream_data = 96'd0;
        istream_data[15:0] = 16'h0010;
        istream_data[47:16] = 32'h00200113;
        istream_halfword_valid = 6'b000111;
        stream_pc = 64'h2002;
        #1;
        if (decode_valid !== 3'b011 || consumed_halfwords !== 4'd3)
            $fatal(1, "straddled instruction completion mismatch");
        expect_lane(0, 64'h2000, 32'h00100093);
        expect_lane(1, 64'h2004, 32'h00200113);
        tick();

        // Faulted data cannot be used to infer length or expose suffix lanes.
        istream_data = 96'd0;
        istream_halfword_valid = 6'b111111;
        istream_access_fault = 6'b000001;
        stream_pc = 64'h3000;
        #1;
        if (decode_valid !== 3'b001 || consumed_halfwords !== 4'd1 ||
            !bus0[`RV64_FETCH_DECODE_BUS_ACCESS_FAULT_BIT])
            $fatal(1, "fault prefix handling mismatch");
        expect_lane(0, 64'h3000, `RV64_INSTR_NOP);

        $display("PASS: istream decode aligns mixed parcels and stashes straddles");
        $finish;
    end
endmodule
