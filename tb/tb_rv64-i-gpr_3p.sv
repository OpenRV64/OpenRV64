`timescale 1ns/1ps
`include "core/isa/rv64-i.v"

module tb_rv64i_gpr_3p #(
    parameter integer ALLOW_DUPLICATE_WRITES = 0
);

    reg clk;
    reg rst_n;
    reg [6*`RV64_REG_ADDR_WIDTH-1:0] read_addr;
    wire [6*`RV64_XLEN-1:0] read_data;
    reg [2:0] write_valid;
    reg [3*`RV64_REG_ADDR_WIDTH-1:0] write_addr;
    reg [3*`RV64_XLEN-1:0] write_data;

    reg [6*`RV64_REG_ADDR_WIDTH-1:0] banked_read_addr;
    wire [6*`RV64_XLEN-1:0] banked_read_data;
    reg [5:0] banked_read_req;
    wire [5:0] banked_read_ack;
    wire [5:0] banked_read_valid;
    reg [2:0] banked_write_valid;
    reg [3*`RV64_REG_ADDR_WIDTH-1:0] banked_write_addr;
    reg [3*`RV64_XLEN-1:0] banked_write_data;
    wire [2:0] banked_write_ack;
    wire [2:0] banked_write_response;
    wire banked_quiescent;
    reg [5:0] grouped_seen;
    reg [5:0] grouped_ack;
    integer grouped_init;
    integer grouped_cycle;
    integer grouped_port;

    openrv64_rv64i_gpr_3p #(
        .ALLOW_DUPLICATE_WRITES(ALLOW_DUPLICATE_WRITES)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .read_req_i(6'b000000),
        .read_addr_i(read_addr),
        .read_data_o(read_data),
        .read_valid_o(),
        .write_valid_i(write_valid),
        .write_addr_i(write_addr),
        .write_data_i(write_data),
        .write_ready_o(),
        .quiescent_o()
    );

    openrv64_rv64i_gpr_3p #(
        .BANKED(1)
    ) banked_dut (
        .clk(clk),
        .rst_n(rst_n),
        .read_req_i(banked_read_req),
        .read_addr_i(banked_read_addr),
        .read_data_o(banked_read_data),
        .read_ack_o(banked_read_ack),
        .read_valid_o(banked_read_valid),
        .write_valid_i(banked_write_valid),
        .write_addr_i(banked_write_addr),
        .write_data_i(banked_write_data),
        .write_ack_o(banked_write_ack),
        .write_ready_o(banked_write_response),
        .quiescent_o(banked_quiescent)
    );

    always #5 clk = ~clk;

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic fail;
        input [8*96-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        read_addr = {6*`RV64_REG_ADDR_WIDTH{1'b0}};
        write_valid = 3'b000;
        write_addr = {3*`RV64_REG_ADDR_WIDTH{1'b0}};
        write_data = {3*`RV64_XLEN{1'b0}};
        banked_read_addr = {6*`RV64_REG_ADDR_WIDTH{1'b0}};
        banked_read_req = 6'b000000;
        banked_write_valid = 3'b000;
        banked_write_addr = {3*`RV64_REG_ADDR_WIDTH{1'b0}};
        banked_write_data = {3*`RV64_XLEN{1'b0}};

        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        write_valid = 3'b111;
        write_addr = {5'd9, 5'd7, 5'd5};
        write_data = {64'h99, 64'h77, 64'h55};
        read_addr = {5'd9, 5'd7, 5'd5, 5'd9, 5'd7, 5'd5};
        #1;
        if ((read_data[0*64 +: 64] != 64'h55) ||
            (read_data[1*64 +: 64] != 64'h77) ||
            (read_data[2*64 +: 64] != 64'h99) ||
            (read_data[3*64 +: 64] != 64'h55) ||
            (read_data[4*64 +: 64] != 64'h77) ||
            (read_data[5*64 +: 64] != 64'h99)) begin
            fail("three-write bypass did not feed all six selectors");
        end
        tick();

        write_valid = 3'b000;
        #1;
        if ((read_data[0*64 +: 64] != 64'h55) ||
            (read_data[1*64 +: 64] != 64'h77) ||
            (read_data[2*64 +: 64] != 64'h99)) begin
            fail("three retirement writes were not stored");
        end

        // p31 is the final stored default entry. p0 is not stored.
        write_valid = 3'b001;
        write_addr = {5'd0, 5'd0, 5'd31};
        write_data = {64'd0, 64'd0, 64'h3131};
        read_addr = {5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd31};
        #1;
        if ((read_data[0*64 +: 64] != 64'h3131) ||
            (read_data[1*64 +: 64] != 64'd0)) begin
            fail("compact p31 bypass or unstored p0 failed");
        end
        tick();
        write_valid = 3'b000;
        #1;
        if ((read_data[0*64 +: 64] != 64'h3131) ||
            (dut.regs[31] != 64'h3131)) begin
            fail("p31 did not map to final writable PRF entry");
        end

        // Suppressed x0 writes are not duplicate physical destinations.
        write_valid = 3'b111;
        write_addr = {5'd0, 5'd0, 5'd0};
        write_data = {64'h30, 64'h20, 64'h10};
        tick();
        write_valid = 3'b000;

        if (ALLOW_DUPLICATE_WRITES != 0) begin
            write_valid = 3'b111;
            write_addr = {5'd10, 5'd10, 5'd10};
            write_data = {64'h30, 64'h20, 64'h10};
            read_addr = {5'd10, 5'd10, 5'd10,
                         5'd10, 5'd10, 5'd10};
            #1;
            if (read_data[0*64 +: 64] != 64'h30)
                fail("duplicate-write bypass did not select youngest lane");
            tick();
            write_valid = 3'b000;
            #1;
            if (read_data[0*64 +: 64] != 64'h30)
                fail("duplicate retirement writes did not commit in order");
        end

        read_addr[0*5 +: 5] = 5'd0;
        #1;
        if (read_data[0*64 +: 64] != 64'd0)
            fail("x0 did not remain zero");

        // Write ports are independent across banks; unlike an atomic read
        // pair, one write requester must not gate the other's grant.
        @(negedge clk);
        banked_write_valid[1:0] = 2'b11;
        banked_write_addr[0*5 +: 5] = 5'd1;
        banked_write_addr[1*5 +: 5] = 5'd2;
        banked_write_data[0*64 +: 64] = 64'h1111;
        banked_write_data[1*64 +: 64] = 64'h2222;
        #1;
        if (banked_write_ack[1:0] != 2'b11)
            fail("different-bank write ports were not independently granted");
        @(posedge clk);
        #1;
        banked_write_valid[1:0] = 2'b00;

        // Same-bank retirement writes must serialize oldest first.  Port zero
        // is the older lane; granting port one here would unnecessarily hold
        // an otherwise-retirable older instruction behind its younger peer.
        @(negedge clk);
        banked_write_valid[1:0] = 2'b11;
        banked_write_addr[0*5 +: 5] = 5'd1;
        banked_write_addr[1*5 +: 5] = 5'd5;
        banked_write_data[0*64 +: 64] = 64'h1111;
        banked_write_data[1*64 +: 64] = 64'h5555;
        #1;
        if (banked_write_ack[1:0] != 2'b01)
            fail("same-bank write did not prioritize the older lane");
        @(posedge clk);
        #1;
        banked_write_valid[0] = 1'b0;
        #1;
        if (!banked_write_ack[1])
            fail("younger same-bank write did not advance after older ack");
        @(posedge clk);
        #1;
        banked_write_valid[1] = 1'b0;

        // The banked interface separates address ack from the following data
        // phase.  Exercise back-to-back nonzero/x0/nonzero transactions so
        // response data cannot accidentally follow the current address.
        @(negedge clk);
        banked_write_valid[0] = 1'b1;
        banked_write_addr[0*5 +: 5] = 5'd1;
        banked_write_data[0*64 +: 64] = 64'h1111_2222_3333_4444;
        #1;
        if (!banked_write_ack[0])
            fail("banked p1 write was not acknowledged");
        @(posedge clk);
        #1;
        banked_write_valid[0] = 1'b0;

        @(negedge clk);
        banked_read_req[0] = 1'b1;
        banked_read_addr[0*5 +: 5] = 5'd1;
        #1;
        if (!banked_read_ack[0])
            fail("banked p1 read was not acknowledged");
        @(posedge clk);
        #1;
        if (!banked_read_valid[0] ||
            (banked_read_data[0*64 +: 64] !==
             64'h1111_2222_3333_4444))
            fail("banked p1 data phase was incorrect");

        banked_read_addr[0*5 +: 5] = 5'd0;
        #1;
        if (!banked_read_ack[0])
            fail("banked p0 read was not acknowledged");
        @(posedge clk);
        #1;
        if (!banked_read_valid[0] ||
            (banked_read_data[0*64 +: 64] !== 64'd0))
            fail("banked p0 data phase was not zero");

        banked_read_addr[0*5 +: 5] = 5'd1;
        #1;
        if (!banked_read_ack[0])
            fail("second banked p1 read was not acknowledged");
        @(posedge clk);
        #1;
        if (!banked_read_valid[0] ||
            (banked_read_data[0*64 +: 64] !==
             64'h1111_2222_3333_4444))
            fail("banked p1 response after p0 was incorrect");
        banked_read_req[0] = 1'b0;
        @(posedge clk);
        #1;
        if (banked_read_valid[0] || !banked_quiescent)
            fail("banked read pipeline did not become quiescent");

        // Six logical read ports form three independent two-source
        // requesters.  Put every source in four-bank bank 0: only one complete
        // pair may be acknowledged per cycle, and no requester may be half
        // accepted.
        for (grouped_init = 0; grouped_init < 6;
             grouped_init = grouped_init + 1) begin
            @(negedge clk);
            banked_write_valid[0] = 1'b1;
            banked_write_addr[0*5 +: 5] = 5'(4 + grouped_init*4);
            banked_write_data[0*64 +: 64] = 64'h2000 + grouped_init;
            #1;
            if (!banked_write_ack[0])
                fail("grouped-read initialization write was not acknowledged");
            @(posedge clk);
            #1;
            banked_write_valid[0] = 1'b0;
        end

        @(negedge clk);
        for (grouped_port = 0; grouped_port < 6;
             grouped_port = grouped_port + 1)
            banked_read_addr[grouped_port*5 +: 5] =
                5'(4 + grouped_port*4);
        banked_read_req = 6'b111111;
        grouped_seen = 6'b000000;
        for (grouped_cycle = 0; grouped_cycle < 3;
             grouped_cycle = grouped_cycle + 1) begin
            #1;
            grouped_ack = banked_read_ack;
            if ((grouped_ack[0] != grouped_ack[1]) ||
                (grouped_ack[2] != grouped_ack[3]) ||
                (grouped_ack[4] != grouped_ack[5]) ||
                ((grouped_ack[0] + grouped_ack[1] +
                  grouped_ack[2] + grouped_ack[3] +
                  grouped_ack[4] + grouped_ack[5]) != 2))
                fail("six-port arbitration did not acknowledge one atomic pair");
            if (|(grouped_ack & grouped_seen))
                fail("six-port arbitration reacknowledged a completed pair");
            @(posedge clk);
            #1;
            if (banked_read_valid !== grouped_ack)
                fail("six-port response valid did not follow pair ack");
            for (grouped_port = 0; grouped_port < 6;
                 grouped_port = grouped_port + 1) begin
                if (grouped_ack[grouped_port] &&
                    (banked_read_data[grouped_port*64 +: 64] !==
                     (64'h2000 + grouped_port)))
                    fail("six-port pair response data was incorrect");
            end
            grouped_seen = grouped_seen | grouped_ack;
            banked_read_req = banked_read_req & ~grouped_ack;
            if (grouped_cycle != 2)
                @(negedge clk);
        end
        if (grouped_seen != 6'b111111)
            fail("six-port arbitration did not service all requester pairs");
        @(posedge clk);
        #1;
        if ((banked_read_valid != 6'b000000) || !banked_quiescent)
            fail("six-port read pipeline did not become quiescent");

        $display("PASS: six-read three-write GPR bank");
        $finish;
    end

endmodule
