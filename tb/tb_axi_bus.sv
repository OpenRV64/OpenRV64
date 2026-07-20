`timescale 1ns/1ps
`include "core/isa/rv64-i.v"
`include "core/isa/rv64-priv.v"
`include "core/bus/bus-defs.v"

module tb_axi_bus;
    logic clk;
    logic rst_n;
    logic fetch_req_valid;
    wire fetch_req_ready;
    logic [63:0] fetch_req_addr;
    logic fetch_cancel;
    wire fetch_resp_valid;
    logic fetch_resp_ready;
    wire [63:0] fetch_resp_addr;
    wire [255:0] fetch_resp_data;
    wire fetch_resp_access_fault;
    wire fetch_resp_page_fault;

    logic lsu_valid;
    logic lsu_write;
    logic [63:0] lsu_addr;
    logic [63:0] lsu_wdata;
    logic [7:0] lsu_wstrb;
    logic [2:0] lsu_size;
    wire lsu_ready;
    wire [63:0] lsu_rdata;
    wire lsu_access_fault;
    wire lsu_page_fault;

    logic pipe_req_valid;
    wire pipe_req_ready;
    logic [1:0] pipe_req_tag;
    logic pipe_req_write;
    logic [63:0] pipe_req_addr;
    logic [63:0] pipe_req_wdata;
    logic [7:0] pipe_req_wstrb;
    logic [2:0] pipe_req_size;
    logic [1:0] pipe_req_priv;
    logic [3:0] pipe_req_vm_mode;
    logic [43:0] pipe_req_root_ppn;
    logic pipe_cancel;
    wire pipe_resp_valid;
    logic pipe_resp_ready;
    wire [1:0] pipe_resp_tag;
    wire [63:0] pipe_resp_rdata;
    wire pipe_resp_access_fault;
    wire pipe_resp_page_fault;

    wire pmp_valid;
    wire [63:0] pmp_addr;
    wire [1:0] pmp_priv;
    wire [2:0] pmp_size;
    wire pmp_write;
    wire pmp_exec;
    logic pmp_allow;

    wire [2:0] arid;
    wire [63:0] araddr;
    wire [7:0] arlen;
    wire [2:0] arsize;
    wire [1:0] arburst;
    wire arvalid;
    logic arready;
    logic [2:0] rid;
    logic [255:0] rdata;
    logic [1:0] rresp;
    logic rlast;
    logic rvalid;
    wire rready;
    wire [2:0] awid;
    wire [63:0] awaddr;
    wire [2:0] awsize;
    wire awvalid;
    logic awready;
    wire [255:0] wdata;
    wire [31:0] wstrb;
    wire wlast;
    wire wvalid;
    logic wready;
    logic [2:0] bid;
    logic [1:0] bresp;
    logic bvalid;
    wire bready;

    integer ar_count;
    integer wait_count;
    reg [2:0] seen_id [0:15];
    reg [63:0] seen_addr [0:15];

    openrv64_core_axi_bus dut (
        .clk(clk), .rst_n(rst_n),
        .fetch_req_valid_i(fetch_req_valid),
        .fetch_req_ready_o(fetch_req_ready),
        .fetch_req_addr_i(fetch_req_addr),
        .fetch_req_priv_i(`RV64_PRIV_M),
        .fetch_req_vm_mode_i(`RV64_SATP_MODE_BARE),
        .fetch_req_asid_i(16'd0), .fetch_req_root_ppn_i(44'd0),
        .fetch_req_sum_i(1'b0), .fetch_req_mxr_i(1'b0),
        .fetch_cancel_i(fetch_cancel),
        .fetch_resp_valid_o(fetch_resp_valid),
        .fetch_resp_ready_i(fetch_resp_ready),
        .fetch_resp_addr_o(fetch_resp_addr),
        .fetch_resp_data_o(fetch_resp_data),
        .fetch_resp_access_fault_o(fetch_resp_access_fault),
        .fetch_resp_page_fault_o(fetch_resp_page_fault),
        .lsu_valid_i(lsu_valid), .lsu_write_i(lsu_write),
        .lsu_addr_i(lsu_addr), .lsu_wdata_i(lsu_wdata),
        .lsu_wstrb_i(lsu_wstrb), .lsu_size_i(lsu_size),
        .lsu_priv_i(`RV64_PRIV_M),
        .lsu_vm_mode_i(`RV64_SATP_MODE_BARE),
        .lsu_asid_i(16'd0), .lsu_root_ppn_i(44'd0),
        .lsu_sum_i(1'b0), .lsu_mxr_i(1'b0),
        .lsu_ready_o(lsu_ready), .lsu_rdata_o(lsu_rdata),
        .lsu_access_fault_o(lsu_access_fault),
        .lsu_page_fault_o(lsu_page_fault), .tlbi_i(1'b0),
        .lsu_pipe_req_valid_i(pipe_req_valid),
        .lsu_pipe_req_ready_o(pipe_req_ready),
        .lsu_pipe_req_tag_i(pipe_req_tag),
        .lsu_pipe_req_write_i(pipe_req_write),
        .lsu_pipe_req_addr_i(pipe_req_addr),
        .lsu_pipe_req_wdata_i(pipe_req_wdata),
        .lsu_pipe_req_wstrb_i(pipe_req_wstrb),
        .lsu_pipe_req_size_i(pipe_req_size),
        .lsu_pipe_req_priv_i(pipe_req_priv),
        .lsu_pipe_req_vm_mode_i(pipe_req_vm_mode),
        .lsu_pipe_req_asid_i(16'd0),
        .lsu_pipe_req_root_ppn_i(pipe_req_root_ppn),
        .lsu_pipe_req_sum_i(1'b0), .lsu_pipe_req_mxr_i(1'b0),
        .lsu_pipe_cancel_i(pipe_cancel),
        .lsu_pipe_resp_valid_o(pipe_resp_valid),
        .lsu_pipe_resp_ready_i(pipe_resp_ready),
        .lsu_pipe_resp_tag_o(pipe_resp_tag),
        .lsu_pipe_resp_rdata_o(pipe_resp_rdata),
        .lsu_pipe_resp_access_fault_o(pipe_resp_access_fault),
        .lsu_pipe_resp_page_fault_o(pipe_resp_page_fault),
        .pmp_valid_o(pmp_valid), .pmp_addr_o(pmp_addr),
        .pmp_priv_o(pmp_priv), .pmp_size_o(pmp_size),
        .pmp_write_o(pmp_write), .pmp_exec_o(pmp_exec),
        .pmp_allow_i(pmp_allow),
        .m_axi_arid_o(arid), .m_axi_araddr_o(araddr),
        .m_axi_arlen_o(arlen), .m_axi_arsize_o(arsize),
        .m_axi_arburst_o(arburst), .m_axi_arlock_o(),
        .m_axi_arcache_o(), .m_axi_arprot_o(), .m_axi_arqos_o(),
        .m_axi_arvalid_o(arvalid), .m_axi_arready_i(arready),
        .m_axi_rid_i(rid), .m_axi_rdata_i(rdata),
        .m_axi_rresp_i(rresp), .m_axi_rlast_i(rlast),
        .m_axi_rvalid_i(rvalid), .m_axi_rready_o(rready),
        .m_axi_awid_o(awid), .m_axi_awaddr_o(awaddr),
        .m_axi_awlen_o(), .m_axi_awsize_o(awsize),
        .m_axi_awburst_o(), .m_axi_awlock_o(), .m_axi_awcache_o(),
        .m_axi_awprot_o(), .m_axi_awqos_o(),
        .m_axi_awvalid_o(awvalid), .m_axi_awready_i(awready),
        .m_axi_wdata_o(wdata), .m_axi_wstrb_o(wstrb),
        .m_axi_wlast_o(wlast), .m_axi_wvalid_o(wvalid),
        .m_axi_wready_i(wready), .m_axi_bid_i(bid),
        .m_axi_bresp_i(bresp), .m_axi_bvalid_i(bvalid),
        .m_axi_bready_o(bready)
    );

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (rst_n && arvalid && arready) begin
            seen_id[ar_count] <= arid;
            seen_addr[ar_count] <= araddr;
            ar_count <= ar_count + 1;
        end
    end

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic push_fetch(input [63:0] addr);
        begin
            fetch_req_addr = addr;
            fetch_req_valid = 1'b1;
            while (!fetch_req_ready) tick();
            tick();
            fetch_req_valid = 1'b0;
        end
    endtask

    task automatic push_pipe_request(
        input [1:0] tag,
        input write,
        input [63:0] addr,
        input [63:0] write_data,
        input [7:0] write_strobe
    );
        integer wait_cycles;
        reg completed;
        begin
            pipe_req_tag = tag;
            pipe_req_write = write;
            pipe_req_addr = addr;
            pipe_req_wdata = write_data;
            pipe_req_wstrb = write_strobe;
            pipe_req_valid = 1'b1;
            wait_cycles = 0;
            completed = 1'b0;
            while (!completed && wait_cycles < 30) begin
                @(posedge clk);
                if (pipe_req_ready)
                    completed = 1'b1;
                #1;
                wait_cycles = wait_cycles + 1;
            end
            if (!completed)
                $fatal(1,
                    "tagged LSU request timeout tag=%0d fast=%b busy=%b local=%b pmp=%b ar=%b/%b",
                    tag, dut.pipe_fast_candidate, dut.pipe_req_tag_busy,
                    dut.pipe_local_resp_valid_q, pmp_allow,
                    arvalid, arready);
            pipe_req_valid = 1'b0;
        end
    endtask

    task automatic send_pipe_read_response(
        input [1:0] tag,
        input [255:0] response_data,
        input [63:0] expected_data
    );
        begin
            rid = {1'b1, tag};
            rdata = response_data;
            rresp = 2'b00;
            rlast = 1'b1;
            rvalid = 1'b1;
            #1;
            if (!rready || !pipe_resp_valid || pipe_resp_tag != tag ||
                pipe_resp_rdata != expected_data ||
                pipe_resp_access_fault || pipe_resp_page_fault)
                $fatal(1,
                    "tagged response mismatch tag=%0d got_tag=%0d data=%h ready=%b",
                    tag, pipe_resp_tag, pipe_resp_rdata, rready);
            tick();
            rvalid = 1'b0;
        end
    endtask

    task automatic send_read_response(
        input [2:0] response_id,
        input [255:0] response_data,
        input [1:0] response_code
    );
        integer wait_cycles;
        reg completed;
        begin
            rid = response_id;
            rdata = response_data;
            rresp = response_code;
            rlast = 1'b1;
            rvalid = 1'b1;
            wait_cycles = 0;
            completed = 1'b0;
            while (!completed && wait_cycles < 30) begin
                @(posedge clk);
                if (rready)
                    completed = 1'b1;
                #1;
                wait_cycles = wait_cycles + 1;
            end
            if (!completed)
                $fatal(1, "R channel timeout id=%0d phys=%0d slots=%0d/%0d/%0d/%0d",
                    response_id, dut.phys_state_q,
                    dut.fetch_state_q[0], dut.fetch_state_q[1],
                    dut.fetch_state_q[2], dut.fetch_state_q[3]);
            rvalid = 1'b0;
        end
    endtask

    task automatic expect_fetch(
        input [63:0] addr,
        input [255:0] data,
        input access_fault
    );
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!fetch_resp_valid && wait_cycles < 30) begin
                tick();
                wait_cycles = wait_cycles + 1;
            end
            if (!fetch_resp_valid)
                $fatal(1, "fetch response timeout head=%0d count=%0d slots=%0d/%0d/%0d/%0d",
                    dut.fetch_head_q, dut.fetch_count_q,
                    dut.fetch_state_q[0], dut.fetch_state_q[1],
                    dut.fetch_state_q[2], dut.fetch_state_q[3]);
            if (fetch_resp_addr != addr || fetch_resp_data != data ||
                fetch_resp_access_fault != access_fault ||
                fetch_resp_page_fault)
                $fatal(1, "fetch response mismatch addr=%h data=%h fault=%b",
                       fetch_resp_addr, fetch_resp_data,
                       fetch_resp_access_fault);
            tick();
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        fetch_req_valid = 0;
        fetch_req_addr = 0;
        fetch_cancel = 0;
        fetch_resp_ready = 1;
        lsu_valid = 0;
        lsu_write = 0;
        lsu_addr = 0;
        lsu_wdata = 0;
        lsu_wstrb = 0;
        lsu_size = 3;
        pipe_req_valid = 0;
        pipe_req_tag = 0;
        pipe_req_write = 0;
        pipe_req_addr = 0;
        pipe_req_wdata = 0;
        pipe_req_wstrb = 0;
        pipe_req_size = 3;
        pipe_req_priv = `RV64_PRIV_M;
        pipe_req_vm_mode = `RV64_SATP_MODE_BARE;
        pipe_req_root_ppn = 0;
        pipe_cancel = 0;
        pipe_resp_ready = 1;
        pmp_allow = 1;
        arready = 1;
        rid = 0;
        rdata = 0;
        rresp = 0;
        rlast = 1;
        rvalid = 0;
        awready = 1;
        wready = 1;
        bid = 3'b111;
        bresp = 0;
        bvalid = 0;
        ar_count = 0;
        repeat (3) tick();
        rst_n = 1;
        tick();

        // Fill all four fetch slots without returning data.  AR must continue
        // every cycle instead of waiting for the previous R response.
        push_fetch(64'h0000);
        push_fetch(64'h0020);
        push_fetch(64'h0040);
        push_fetch(64'h0060);
        repeat (3) tick();
        if (ar_count != 4)
            $fatal(1, "expected four pipelined AR requests, got %0d", ar_count);
        if (seen_addr[0] != 64'h0 || seen_addr[1] != 64'h20 ||
            seen_addr[2] != 64'h40 || seen_addr[3] != 64'h60 ||
            seen_id[0] != 0 || seen_id[1] != 1 ||
            seen_id[2] != 2 || seen_id[3] != 3)
            $fatal(1, "fetch AR address/ID sequence mismatch");
        if (arlen != 0 || arburst != 2'b01)
            $fatal(1, "AXI read must be a one-beat INCR transaction");

        // Return out of order.  The core captures by ID but exposes the
        // original request order to fetch.
        fetch_resp_ready = 0;
        send_read_response(3'd2, 256'h3333, 2'b00);
        send_read_response(3'd0, 256'h1111, 2'b00);
        send_read_response(3'd3, 256'h4444, 2'b00);
        send_read_response(3'd1, 256'h2222, 2'b00);
        fetch_resp_ready = 1;
        expect_fetch(64'h0, 256'h1111, 0);
        expect_fetch(64'h20, 256'h2222, 0);
        expect_fetch(64'h40, 256'h3333, 0);
        expect_fetch(64'h60, 256'h4444, 0);

        // PMP denial terminates locally and never launches AR.
        pmp_allow = 0;
        fetch_resp_ready = 0;
        push_fetch(64'h0080);
        repeat (2) tick();
        if (ar_count != 4 || !fetch_resp_valid ||
            !fetch_resp_access_fault || fetch_resp_addr != 64'h80)
            $fatal(1, "fetch PMP denial did not become a local fault");
        tick();
        fetch_resp_ready = 1;
        pmp_allow = 1;

        // Three independent LSU reads launch before any response and use AXI
        // IDs 4-6.  Responses may return out of order and retain their tags.
        push_pipe_request(2'd0, 1'b0, 64'h100, 64'd0, 8'd0);
        push_pipe_request(2'd1, 1'b0, 64'h108, 64'd0, 8'd0);
        push_pipe_request(2'd2, 1'b0, 64'h110, 64'd0, 8'd0);
        if (ar_count != 7 || seen_id[4] != 3'd4 ||
            seen_id[5] != 3'd5 || seen_id[6] != 3'd6 ||
            seen_addr[4] != 64'h100 || seen_addr[5] != 64'h108 ||
            seen_addr[6] != 64'h110)
            $fatal(1, "tagged LSU AR address/ID sequence mismatch");
        send_pipe_read_response(2'd2,
            {64'd0, 64'h3333_3333_3333_3333, 128'd0},
            64'h3333_3333_3333_3333);
        send_pipe_read_response(2'd0,
            {192'd0, 64'h1111_1111_1111_1111},
            64'h1111_1111_1111_1111);
        send_pipe_read_response(2'd1,
            {128'd0, 64'h2222_2222_2222_2222, 64'd0},
            64'h2222_2222_2222_2222);

        // A tagged store is accepted into the write holding register before
        // either AXI address or data channel is ready.  A younger redirect
        // cannot cancel the irrevocable write or hide its B error.  The two
        // AXI channels then handshake independently.
        awready = 0;
        wready = 0;
        pipe_resp_ready = 0;
        push_pipe_request(2'd1, 1'b1, 64'h114,
            64'haabb_ccdd_0000_0000, 8'hf0);
        pipe_cancel = 1'b1;
        tick();
        pipe_cancel = 1'b0;
        if (!awvalid || !wvalid || awid != 3'd5 || awaddr != 64'h114 ||
            awsize != 3 || wstrb != 32'h00f0_0000 ||
            wdata[191:128] != 64'haabb_ccdd_0000_0000)
            $fatal(1, "tagged store buffer/lane steering mismatch");
        awready = 1;
        tick();
        if (awvalid || !wvalid)
            $fatal(1, "tagged store AW/W handshakes were not independent");
        wready = 1;
        tick();
        bid = 3'd5;
        bresp = 2'b10;
        bvalid = 1;
        #1;
        if (bready || !pipe_resp_valid || pipe_resp_tag != 2'd1)
            $fatal(1, "tagged store response did not hold while stalled");
        pipe_resp_ready = 1;
        #1;
        if (!bready || !pipe_resp_valid || pipe_resp_tag != 2'd1 ||
            !pipe_resp_access_fault || pipe_resp_page_fault)
            $fatal(1, "tagged store B error was lost across cancel");
        tick();
        bvalid = 0;
        bresp = 0;
        bid = 3'b111;

        // Translated tagged traffic falls back to the precise PTW path and
        // returns the page fault under the original request tag.  An invalid
        // root PTE is sufficient to exercise the fallback without a full map.
        pipe_req_vm_mode = `RV64_SATP_MODE_SV39;
        pipe_req_priv = `RV64_PRIV_S;
        pipe_resp_ready = 0;
        push_pipe_request(2'd2, 1'b0, 64'h1000, 64'd0, 8'd0);
        wait_count = 0;
        while (!(arvalid && arready && arid == 3'b111) &&
               wait_count < 50) begin
            tick();
            wait_count = wait_count + 1;
        end
        if (wait_count == 50)
            $fatal(1,
                "translated PTW AR timeout lsu=%0d miss=%b phys=%0d fallback=%b",
                dut.lsu_state_q, dut.miss_active_q, dut.phys_state_q,
                dut.pipe_fallback_active_q);
        tick();
        send_read_response(3'b111, 256'd0, 2'b00);
        wait_count = 0;
        while (!pipe_resp_valid && wait_count < 50) begin
            tick();
            wait_count = wait_count + 1;
        end
        if (wait_count == 50)
            $fatal(1,
                "translated response timeout lsu=%0d miss=%b phys=%0d fallback=%b",
                dut.lsu_state_q, dut.miss_active_q, dut.phys_state_q,
                dut.pipe_fallback_active_q);
        if (pipe_resp_tag != 2'd2 || !pipe_resp_page_fault ||
            pipe_resp_access_fault)
            $fatal(1, "translated tagged LSU fallback mismatch");
        pipe_resp_ready = 1;
        tick();
        pipe_req_vm_mode = `RV64_SATP_MODE_BARE;
        pipe_req_priv = `RV64_PRIV_M;

        // Narrow LSU read: returned word is selected from its 64-bit lane in
        // the 256-bit AXI beat.
        lsu_addr = 64'h48;
        lsu_write = 0;
        lsu_size = 3;
        lsu_valid = 1;
        while (!(arvalid && arready && arid == 3'b111)) tick();
        if (araddr != 64'h48 || arsize != 3)
            $fatal(1, "LSU read AR mismatch");
        tick();
        send_read_response(3'b111,
            {128'd0, 64'hdead_beef_cafe_1234, 64'd0}, 2'b00);
        while (!lsu_ready) tick();
        if (lsu_rdata != 64'hdead_beef_cafe_1234 ||
            lsu_access_fault || lsu_page_fault)
            $fatal(1, "LSU read lane steering mismatch: %h", lsu_rdata);
        tick();
        lsu_valid = 0;
        tick();

        // LSU write: legacy 8-byte lane strobes are shifted into the proper
        // word of the 32-byte W channel.
        lsu_addr = 64'h54;
        lsu_write = 1;
        lsu_size = 2;
        lsu_wdata = 64'haabb_ccdd_0000_0000;
        lsu_wstrb = 8'hf0;
        lsu_valid = 1;
        while (!awvalid || !wvalid) tick();
        if (awid != 3'b111 || awaddr != 64'h54 || awsize != 2 ||
            !wlast || wstrb != 32'h00f0_0000 ||
            wdata[191:128] != 64'haabb_ccdd_0000_0000)
            $fatal(1, "LSU 256-bit write lane steering mismatch");
        tick();
        bvalid = 1;
        while (!bready) tick();
        tick();
        bvalid = 0;
        while (!lsu_ready) tick();
        if (lsu_access_fault) $fatal(1, "successful AXI write faulted");
        tick();
        lsu_valid = 0;

        $display("PASS: 256-bit AXI fetch plus tagged LSU reads, writes, and VM fallback");
        $finish;
    end
endmodule
